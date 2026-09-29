#!/usr/bin/env bash
#
# End-to-end verification: build the real image and check the real artifact.
#
# The rest of tests/ runs against stubs on the host in seconds. This does not.
# It runs podman, builds the whole Containerfile, and takes tens of minutes and
# a lot of disk. It is deliberately not part of ./tests/run-tests.sh — that
# runner globs tests/test-*.sh at maxdepth 1, so nothing here is picked up by
# accident.
#
# WHAT IT ADDS OVER CI
#
# The `Build container image` workflow already builds the image on every pull
# request, and build_files/post-check.sh runs inside that build. So a plain
# --build-only run here is a local rehearsal of something CI does anyway.
#
# The --rechunk mode is the part CI does not do. post-check.sh and `bootc
# container lint` are RUN steps in the Containerfile, so they validate the image
# *before* the workflow hands it to Chunkah. Chunkah then re-layers it, and the
# archive that comes back out is loaded, tagged, pushed and signed with neither
# check running again. `Verify pushed tags share one digest` proves every tag
# resolves to one manifest; it says nothing about what that manifest contains.
#
# --rechunk closes that loop locally: rechunk exactly as the workflow does, then
# run post-check.sh again inside the result. If Chunkah ever drops or mangles
# something on the way through, this is what notices.
#
# STORAGE
#
# Every image this creates is tagged under one unique, timestamped name, and
# --clean removes only those exact tags. Nothing here prunes, and nothing here
# touches an image it did not create.
#
#   ./tests/e2e/run-e2e.sh                 # build, then verify
#   ./tests/e2e/run-e2e.sh --rechunk       # build, rechunk, verify the rechunked image
#   ./tests/e2e/run-e2e.sh --clean         # also remove the images it made
#   ./tests/e2e/run-e2e.sh --keep-going    # report every failed check, not just the first
#
# E2E_ARCHIVE_DIR overrides where the --rechunk archive is written, and where
# `podman load` is pointed to unpack it. Both default to podman's storage
# filesystem rather than TMPDIR: Aurora is a Fedora Atomic desktop, so /tmp is
# tmpfs, and both of these are measured in gigabytes. /var/tmp is the other
# sensible choice on such a host.

set -euo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${E2E_DIR}/../.." && pwd)"

# Matches the workflow's pin. Renovate's regex manager tracks both this file
# and the workflow (see renovate.json), so this stays in sync automatically.
CHUNKAH_IMAGE="${CHUNKAH_IMAGE:-quay.io/coreos/chunkah:v0.7.0}"

RECHUNK=0
CLEAN=0
KEEP_GOING=0

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --rechunk) RECHUNK=1 ;;
        --clean) CLEAN=1 ;;
        --keep-going) KEEP_GOING=1 ;;
        -h | --help)
            # Print the whole leading comment block, however long it is. A
            # fixed line range silently truncated the header once it grew past
            # the range's end -- mid-sentence, in the E2E_ARCHIVE_DIR
            # explanation -- so the end is found by shape, not by number:
            # print from line 2 until the first line that is not a comment.
            sed -n '2,${/^#/!q;p;}' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            printf 'run-e2e: unknown option: %s\n' "$1" >&2
            exit 2
            ;;
    esac
    shift
done

STAMP="$(date -u +%Y%m%d-%H%M%S)"
BUILD_TAG="localhost/aurora-zfs-simple-e2e:${STAMP}"
CHUNKED_TAG="localhost/aurora-zfs-simple-e2e:${STAMP}-chunked"
CREATED_TAGS=()
# Both are read by the EXIT trap below, which is installed before either is
# given its real value. Under `set -u` an unset name there is a hard error, so
# a failed prerequisite check would die inside cleanup instead of printing its
# own message and exiting 1.
ARCHIVE=""
LOAD_TMPDIR=""

FAILURES=0
CHECKS=0

pass() {
    CHECKS=$((CHECKS + 1))
    printf '  ok   %s\n' "$1"
}

fail() {
    CHECKS=$((CHECKS + 1))
    FAILURES=$((FAILURES + 1))
    printf '  FAIL %s\n' "$1"
    shift
    local detail
    for detail in "$@"; do
        printf '       %s\n' "${detail}"
    done
    if [[ "${KEEP_GOING}" -eq 0 ]]; then
        printf '\nStopping at first failure. Re-run with --keep-going to see them all.\n' >&2
        exit 1
    fi
}

step() { printf '\n==> %s\n' "$1"; }

cleanup() {
    # The archive is this script's own temp file and can be several GB. It goes
    # unconditionally, --clean or not: `set -e` aborts the moment chunkah or
    # `podman load` fails, and stranding it in TMPDIR would compound the
    # disk-space exhaustion that is the most likely reason they failed.
    if [[ -n "${ARCHIVE}" && -e "${ARCHIVE}" ]]; then
        printf '\n==> Removing temporary archive %s\n' "${ARCHIVE}"
        rm -f "${ARCHIVE}"
    fi
    if [[ -n "${LOAD_TMPDIR}" && -d "${LOAD_TMPDIR}" ]]; then
        rm -rf "${LOAD_TMPDIR}"
    fi

    # Images are only removed when asked, and only the exact tags this run made.
    [[ "${CLEAN}" -eq 1 ]] || return 0
    [[ "${#CREATED_TAGS[@]}" -gt 0 ]] || return 0
    step "Removing only the images this run created"
    local tag
    for tag in "${CREATED_TAGS[@]}"; do
        printf '  rmi %s\n' "${tag}"
        podman rmi -f "${tag}" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

# --- prerequisites ----------------------------------------------------------

step "Checking prerequisites"

if ! command -v podman >/dev/null 2>&1; then
    printf 'run-e2e: podman is required\n' >&2
    exit 1
fi
printf '  podman %s\n' "$(podman --version | awk '{print $3}')"

# The checkout is not where the bytes land. The image goes into podman's graph
# root and, under --rechunk, the archive goes to TMPDIR. Those are routinely on
# different filesystems from the repo, so checking only the repo would let this
# pass its own up-front check and then die tens of minutes later with a full
# disk. Check each distinct filesystem that actually receives data.
graph_root="$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null || true)"
[[ -n "${graph_root}" ]] || graph_root="${HOME}/.local/share/containers/storage"

# TMPDIR is the wrong default here, and specifically wrong for this project's
# audience. Aurora is a Fedora Atomic desktop, where /tmp is tmpfs — on the
# machine this was written on, /tmp is 31G of RAM while /var/tmp and podman's
# storage share 532G of disk. A multi-gigabyte archive sent to /tmp would fail
# on a host with hundreds of free gigabytes.
#
# Default beside podman's storage instead, which is by definition sized for
# images. The workflow puts archive and storage on separate disks because a
# GitHub runner has two; a workstation generally has one filesystem with room.
ARCHIVE_DIR="${E2E_ARCHIVE_DIR:-$(dirname "${graph_root}")}"

# `podman load` unpacks the archive into TMPDIR before applying it, so the load
# needs the same treatment as the archive — this is why the workflow runs it as
# `TMPDIR=/mnt/tmp podman load`. Without this the archive lands correctly and
# the load still tries to expand it in tmpfs.
LOAD_TMPDIR="${ARCHIVE_DIR}/e2e-load-tmp.$$"

targets=("${graph_root}")
[[ "${RECHUNK}" -eq 1 ]] && targets+=("${ARCHIVE_DIR}")

# Two paths on one filesystem must not be asked for 40G each; dedupe by device.
declare -A seen=()
short=0
for target in "${targets[@]}"; do
    # Walk up to the nearest existing ancestor: podman's graph root may not
    # exist yet on a machine that has never pulled an image.
    probe="${target}"
    while [[ ! -d "${probe}" && "${probe}" != "/" ]]; do
        probe="$(dirname "${probe}")"
    done

    device="$(df -Pk "${probe}" | awk 'NR==2 {print $1}')"
    [[ -n "${seen[${device}]:-}" ]] && continue
    seen["${device}"]=1

    avail_kb="$(df -Pk "${probe}" | awk 'NR==2 {print $4}')"
    if [[ "${avail_kb}" -lt 41943040 ]]; then
        printf 'run-e2e: %s (%s) has %sG free; want at least 40G\n' \
            "${probe}" "${device}" "$((avail_kb / 1048576))" >&2
        short=1
    else
        printf '  %-40s %sG free\n' "${probe}" "$((avail_kb / 1048576))"
    fi
done

if [[ "${short}" -eq 1 ]]; then
    printf 'run-e2e: the base image, akmods layers and the built image will not fit\n' >&2
    exit 1
fi

# --- build ------------------------------------------------------------------

step "Building ${BUILD_TAG}"
printf '  this is the whole Containerfile: expect tens of minutes\n'

CREATED_TAGS+=("${BUILD_TAG}")
podman build --tag "${BUILD_TAG}" --file "${REPO_ROOT}/Containerfile" "${REPO_ROOT}"

# A green build already means post-check.sh and `bootc container lint` passed,
# since both are RUN steps. Say so rather than implying this script proved it.
pass "Containerfile built, so its in-build post-check.sh and bootc lint passed"

# --- rechunk, if asked ------------------------------------------------------

TARGET="${BUILD_TAG}"

if [[ "${RECHUNK}" -eq 1 ]]; then
    step "Rechunking with ${CHUNKAH_IMAGE}"

    # Same --config-str workaround the workflow documents: a full inspect
    # carries RootFS.Layers and History, which scale with the base image's layer
    # count and blow past MAX_ARG_STRLEN once it is large enough.
    export CHUNKAH_CONFIG_STR
    CHUNKAH_CONFIG_STR="$(podman inspect --format '{{json .Config}}' "${BUILD_TAG}")"

    # Assigned to the trap-tracked global before the long-running step, so a
    # failure between here and the load still cleans up after itself.
    mkdir -p "${ARCHIVE_DIR}"
    ARCHIVE="$(mktemp "${ARCHIVE_DIR}/chunkah-e2e-XXXXXX.tar")"
    podman run --rm \
        --mount=type=image,src="${BUILD_TAG}",target=/chunkah \
        -e CHUNKAH_CONFIG_STR \
        "${CHUNKAH_IMAGE}" build \
        --verbose \
        --compressed \
        --max-layers 128 \
        --prune /sysroot/ \
        --label ostree.commit- \
        --label ostree.final-diffid- \
        --tag "${CHUNKED_TAG}" >"${ARCHIVE}"

    CREATED_TAGS+=("${CHUNKED_TAG}")
    mkdir -p "${LOAD_TMPDIR}"
    TMPDIR="${LOAD_TMPDIR}" podman load -i "${ARCHIVE}"
    rm -rf "${LOAD_TMPDIR}"
    rm -f "${ARCHIVE}"
    ARCHIVE=""
    LOAD_TMPDIR=""

    TARGET="${CHUNKED_TAG}"
    pass "Chunkah produced a loadable image"
fi

# --- verify the artifact ----------------------------------------------------
#
# Re-running post-check.sh here is the point of --rechunk: it is the only place
# the re-layered image is checked at all. It is not copied into the image, so
# mount it in read-only and run it.

step "Verifying ${TARGET}"

if podman run --rm \
    -v "${REPO_ROOT}/build_files/post-check.sh:/post-check.sh:ro" \
    "${TARGET}" /post-check.sh; then
    pass "post-check.sh passes against the final image"
else
    fail "post-check.sh passes against the final image" \
        "image: ${TARGET}" \
        "if this failed only with --rechunk, the rechunk changed the image"
fi

# A handful of assertions post-check.sh does not make, about the shape of the
# thing a user would actually rebase onto.

# The gap this script exists to cover is both Containerfile checks, not one of
# them. post-check.sh looks at kernel and ZFS content; bootc container lint
# checks filesystem invariants a re-layering could plausibly disturb. Running
# only the first would report a fully passing rechunk that bootc would reject.
if podman run --rm "${TARGET}" bootc container lint; then
    pass "bootc container lint passes against the final image"
else
    fail "bootc container lint passes against the final image" \
        "image: ${TARGET}" \
        "if this failed only with --rechunk, the rechunk broke a bootc invariant"
fi

kernel_count="$(podman run --rm "${TARGET}" sh -c 'ls -1 /usr/lib/modules | wc -l')"
if [[ "${kernel_count}" == "1" ]]; then
    pass "exactly one kernel module tree is present"
else
    fail "exactly one kernel module tree is present" "found ${kernel_count}"
fi

if podman run --rm "${TARGET}" sh -c 'command -v zpool && command -v zfs' >/dev/null; then
    pass "zpool and zfs are on PATH"
else
    fail "zpool and zfs are on PATH" "ZFS userspace missing from the final image"
fi

bootc_label="$(podman inspect --format '{{ index .Labels "containers.bootc" }}' "${TARGET}" 2>/dev/null || true)"
if [[ "${bootc_label}" == "1" ]]; then
    pass "containers.bootc=1 label survived"
else
    # The workflow applies this label at build time via docker/metadata-action,
    # so a local podman build legitimately will not have it. Only meaningful as
    # a rechunk regression check.
    if [[ "${RECHUNK}" -eq 1 ]]; then
        printf '  note containers.bootc label is %s; set by the workflow, not by a local build\n' \
            "${bootc_label:-unset}"
    fi
fi

# --- report -----------------------------------------------------------------

printf '\n'
if [[ "${FAILURES}" -gt 0 ]]; then
    printf 'e2e: %d check(s), %d failure(s)\n' "${CHECKS}" "${FAILURES}"
    exit 1
fi
printf 'e2e: %d check(s), all passed (%s)\n' "${CHECKS}" "${TARGET}"
if [[ "${CLEAN}" -eq 0 ]]; then
    printf 'e2e: images kept. Remove with: podman rmi %s\n' "${CREATED_TAGS[*]}"
fi
