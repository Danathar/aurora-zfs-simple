#!/usr/bin/env bash
#
# Tests for everything tests/e2e/run-e2e.sh does *after* the build.
#
# test-e2e-preflight.sh stops the script at `podman build`, on the reasoning
# that the build is the expensive part. That is true of the build, and not true
# of anything downstream of it: the rechunk, the four checks against the built
# image and the report are all `podman` and nothing else, and `podman` is
# already resolved through PATH. Once the stub *succeeds* the build instead of
# failing it, the whole second half of the script runs on the host in
# milliseconds, against an image that never existed.
#
# That second half is where the script's own accounting lives, and it is the
# part with no coverage at all today:
#
#   * --keep-going is the difference between one reported failure and all of
#     them; without it a failed check exits 1 on the spot
#   * the exit status and the check tally come from FAILURES/CHECKS, which only
#     the checks increment, so a check that silently stops counting reports a
#     clean run
#   * --rechunk has to invoke chunkah with the flags the workflow uses, retag
#     to CHUNKED_TAG, and then verify *that* image rather than the built one --
#     verifying the pre-rechunk image would make the mode assert nothing
#   * the archive is this script's own multi-gigabyte temp file, removed on
#     every exit path, and CHUNKED_TAG has to reach CREATED_TAGS or --clean
#     leaves the larger of the two images behind
#   * the containers.bootc label is legitimately absent from a local build and
#     is only a regression signal under --rechunk, so it must not fail a plain
#     run
#
# What is still not covered here is what the checks actually inspect: a real
# image is the only thing that can answer whether ZFS userspace is present.
# This covers how the script reacts to the answers, not the answers.

set -uo pipefail

TEST_NAME="test-e2e-verify"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${REPO_ROOT}/tests/e2e/run-e2e.sh"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "${WORK_ROOT}"' EXIT

case_dir=""
STATUS=0
STDOUT=""
PODMAN_CALLS=""
E2E_ENV=()

# Comfortably past the script's 40G (41943040 KB) threshold, so the preflight
# never decides a case for us. The free-space reasoning itself is asserted in
# test-e2e-preflight.sh.
ROOMY_KB=99614720 # 95G

# Fresh sandbox per case: its own stub bin, call log, graph root and HOME.
new_case() {
    local name=$1
    case_dir="${WORK_ROOT}/${name}"
    mkdir -p "${case_dir}/bin" "${case_dir}/graph" "${case_dir}/home"

    cat >"${case_dir}/bin/podman" <<'STUB'
#!/usr/bin/env bash
# Stub podman that succeeds the build, so the script runs on into the half
# under test. Each `run` is identified by the command it was asked to execute,
# and each check's answer is set by an environment variable, defaulting to the
# answer a healthy image would give.
printf '%s\n' "$*" >>"${STUB_CALLS}"

# The container command follows the image reference; the flags before it differ
# per call site, so match on the whole argv rather than on a position.
argv="$*"

case "$1" in
--version)
    echo "podman version 5.0.0-stub"
    exit 0
    ;;
info)
    printf '%s\n' "${STUB_GRAPH_ROOT}"
    exit 0
    ;;
build)
    exit "${STUB_BUILD_STATUS:-0}"
    ;;
load)
    exit "${STUB_LOAD_STATUS:-0}"
    ;;
rmi)
    exit 0
    ;;
inspect)
    if [[ "${argv}" == *"json .Config"* ]]; then
        printf '%s\n' '{"Cmd":["/sbin/init"]}'
    else
        # An absent label is an empty line, which is what podman prints.
        printf '%s\n' "${STUB_BOOTC_LABEL-1}"
    fi
    exit 0
    ;;
run) ;;
*) exit 0 ;;
esac

# --- podman run --------------------------------------------------------------
if [[ "${argv}" == *"--mount=type=image"* ]]; then
    # chunkah: its stdout is the archive, so it has to write something.
    [[ -n "${STUB_CHUNKAH_FAILS:-}" ]] && exit 3
    printf 'stub-archive-bytes\n'
    exit 0
fi
if [[ "${argv}" == *"/post-check.sh"* ]]; then
    exit "${STUB_POSTCHECK_STATUS:-0}"
fi
if [[ "${argv}" == *"bootc container lint"* ]]; then
    # Like bootc: an image with only warnings lints clean (exit 0) unless the
    # call asks for --fatal-warnings.
    if [[ -n "${STUB_LINT_WARNINGS:-}" && " ${argv} " == *" --fatal-warnings "* ]]; then
        exit 1
    fi
    exit "${STUB_LINT_STATUS:-0}"
fi
if [[ "${argv}" == *"/usr/lib/modules"* ]]; then
    printf '%s\n' "${STUB_KERNEL_COUNT:-1}"
    exit 0
fi
if [[ "${argv}" == *"command -v zpool"* ]]; then
    [[ -n "${STUB_ZFS_MISSING:-}" ]] && exit 1
    printf '/usr/sbin/zpool\n/usr/sbin/zfs\n'
    exit 0
fi
exit 0
STUB

    cat >"${case_dir}/bin/df" <<'STUB'
#!/usr/bin/env bash
# Stub df: every filesystem is roomy. The free-space reasoning is asserted in
# test-e2e-preflight.sh; here it only has to get out of the way.
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/stub-default 0 0 %s 1%% /stub\n' "${STUB_DF_DEFAULT_KB}"
STUB

    chmod +x "${case_dir}/bin/podman" "${case_dir}/bin/df"
    : >"${case_dir}/podman-calls.log"
    E2E_ENV=()
}

# Run the script with the sandbox's PATH and a caller-supplied environment.
# Captures exit status, combined output and the podman call log into globals.
run_e2e() {
    local out
    out="$(
        env -i \
            PATH="${case_dir}/bin:${PATH}" \
            HOME="${case_dir}/home" \
            STUB_CALLS="${case_dir}/podman-calls.log" \
            STUB_GRAPH_ROOT="${case_dir}/graph" \
            STUB_DF_DEFAULT_KB="${ROOMY_KB}" \
            ${E2E_ENV[@]+"${E2E_ENV[@]}"} \
            bash "${SCRIPT}" "$@" 2>&1
    )"
    STATUS=$?
    STDOUT="${out}"
    PODMAN_CALLS="$(cat "${case_dir}/podman-calls.log")"
}

# The recorded calls of one verb, one per line.
calls_for() {
    grep "^$1 " <<<"${PODMAN_CALLS}" || true
}

# The tag a recorded call was pointed at. The two tags this script creates share
# a timestamped prefix and differ by the -chunked suffix, so which one a check
# ran against is observable.
tag_in() {
    tr ' ' '\n' <<<"$1" | grep '^localhost/aurora-zfs-simple-e2e:' | head -1
}

# --- a clean run reports every check and keeps its images -------------------

new_case all_pass
run_e2e
assert_eq "a run whose checks all pass exits 0" 0 "${STATUS}"
# Six checks: the build itself, post-check.sh, bootc lint, the kernel tree
# count, ZFS userspace and the containers.bootc label. A check that stops
# counting is a check that stopped running, and the tally is where that shows.
assert_contains "and counts every check it made" "${STDOUT}" "e2e: 6 check(s), all passed"
assert_contains "and names the image it verified" \
    "${STDOUT}" "$(tag_in "$(calls_for build)")"
assert_contains "the green build is reported as covering the in-build checks" \
    "${STDOUT}" "so its in-build post-check.sh and bootc lint passed"
# Without --clean the images stay, and the message has to be a command the
# reader can paste: the tags are timestamped and not guessable.
assert_contains "a run without --clean says how to remove what it kept" \
    "${STDOUT}" "podman rmi $(tag_in "$(calls_for build)")"
assert_eq "and removes nothing itself" "" "$(calls_for rmi)"
assert_eq "a run without --rechunk loads no archive" "" "$(calls_for load)"

# --- a failed check stops the run, unless asked not to ----------------------

new_case first_failure_stops
E2E_ENV=(STUB_LINT_STATUS=1 STUB_KERNEL_COUNT=3)
run_e2e
assert_eq "a failed check exits 1" 1 "${STATUS}"
assert_contains "and names the check that failed" \
    "${STDOUT}" "FAIL bootc container lint passes against the final image"
assert_contains "and says how to see the rest" \
    "${STDOUT}" "Re-run with --keep-going"
# Stopping at the first failure means the later checks never ran at all, not
# merely that they went unreported.
assert_not_contains "and does not report the checks after it" \
    "${STDOUT}" "exactly one kernel module tree"
assert_not_contains "and does not run them either" \
    "${PODMAN_CALLS}" "/usr/lib/modules"

new_case keep_going
E2E_ENV=(STUB_LINT_STATUS=1 STUB_KERNEL_COUNT=3 STUB_ZFS_MISSING=1)
run_e2e --keep-going
assert_eq "--keep-going still exits 1 when a check failed" 1 "${STATUS}"
assert_contains "--keep-going reports the first failure" \
    "${STDOUT}" "FAIL bootc container lint passes against the final image"
assert_contains "--keep-going reports a later failure too" \
    "${STDOUT}" "FAIL exactly one kernel module tree is present"
assert_contains "and shows the count it actually found" "${STDOUT}" "found 3"
assert_contains "--keep-going reports the last failure too" \
    "${STDOUT}" "FAIL zpool and zfs are on PATH"
assert_contains "and totals them rather than stopping at one" \
    "${STDOUT}" "e2e: 6 check(s), 3 failure(s)"
assert_not_contains "a --keep-going run does not suggest --keep-going" \
    "${STDOUT}" "Re-run with --keep-going"

new_case post_check_failure
E2E_ENV=(STUB_POSTCHECK_STATUS=1)
run_e2e
assert_eq "a failing post-check.sh exits 1" 1 "${STATUS}"
assert_contains "and names the image it ran against" \
    "${STDOUT}" "image: $(tag_in "$(calls_for build)")"
# The rechunk is the only thing that changes the image between the in-build
# post-check.sh and this one, so the hint is the diagnosis.
assert_contains "and points at the rechunk as the difference" \
    "${STDOUT}" "the rechunk changed the image"

# --- a lint warning fails the run, as it fails the build -------------------

# The Containerfile lints with --fatal-warnings because without it a warning
# exits 0. This lint is the only one after the rechunk, so a warning the rechunk
# leaves behind is exactly what it is here to catch.
new_case lint_warning_only
E2E_ENV=(STUB_LINT_WARNINGS=1)
run_e2e
assert_eq "an image whose lint finds only warnings exits 1" 1 "${STATUS}"
assert_contains "and names the lint as the failed check" \
    "${STDOUT}" "FAIL bootc container lint passes against the final image"

# Same arguments as the Containerfile's lint, both ways: a flag added to one and
# not the other means the image is held to a different standard after the
# rechunk than before it.
lint_args() {
    sed -n 's/.*bootc container lint\(.*\)$/\1/p' <<<"$1" |
        sed -E 's/;.*$//; s/[[:space:]]+/ /g; s/^ //; s/ $//' | head -1
}
containerfile_lint="$(lint_args "$(grep -E '^RUN .*bootc container lint' "${REPO_ROOT}/Containerfile")")"
e2e_lint="$(lint_args "$(grep -E 'podman run .*bootc container lint' "${SCRIPT}")")"
assert_contains "the Containerfile's lint has --fatal-warnings" \
    " ${containerfile_lint} " " --fatal-warnings "
assert_eq "the e2e lint passes the Containerfile's lint arguments" \
    "${containerfile_lint}" "${e2e_lint}"

# --- the checks are pointed at the image, mounting the script in ------------

new_case check_wiring
run_e2e
post_check_call="$(grep -- '/post-check.sh' <<<"${PODMAN_CALLS}" | head -1)"
# post-check.sh is not copied into the image, so it can only be checked against
# a built image by being mounted in; a read-only mount of the repo's own copy is
# what makes this the same script the build ran.
assert_contains "post-check.sh is mounted in from the repo, read-only" \
    "${post_check_call}" "${REPO_ROOT}/build_files/post-check.sh:/post-check.sh:ro"
assert_contains "and is what the container is asked to run" \
    "${post_check_call}" " /post-check.sh"
assert_contains "bootc container lint is run against the image" \
    "${PODMAN_CALLS}" "bootc container lint"
assert_contains "the kernel module trees are counted, not sampled" \
    "${PODMAN_CALLS}" "ls -1 /usr/lib/modules | wc -l"
assert_contains "both ZFS commands are required, not just one" \
    "${PODMAN_CALLS}" "command -v zpool && command -v zfs"

# --- the containers.bootc label is a rechunk signal, not a build check ------

new_case label_absent_locally
E2E_ENV=(STUB_BOOTC_LABEL=)
run_e2e
# docker/metadata-action applies this label in the workflow, so a local build
# legitimately does not have it. Failing on that would make every local run red.
assert_eq "a local build with no containers.bootc label still exits 0" 0 "${STATUS}"
assert_not_contains "and the label is not reported as a failure" \
    "${STDOUT}" "FAIL containers.bootc"
assert_not_contains "and is not remarked on outside --rechunk" \
    "${STDOUT}" "containers.bootc label is"

new_case label_present
run_e2e
assert_contains "a label of 1 is reported as having survived" \
    "${STDOUT}" "ok   containers.bootc=1 label survived"

new_case label_absent_after_rechunk
E2E_ENV=(STUB_BOOTC_LABEL=)
run_e2e --rechunk
# Under --rechunk the label is a regression signal: the build put it there (or
# did not), and a re-layering that drops it is worth saying out loud. It is
# still not a failure, because a local build never had it to lose.
assert_eq "a rechunk that lost the label still exits 0" 0 "${STATUS}"
assert_contains "but says the label is unset" \
    "${STDOUT}" "note containers.bootc label is unset"
assert_not_contains "and does not count it as a check" \
    "${STDOUT}" "e2e: 7 check(s)"

# --- --clean removes exactly the tags this run created ----------------------

new_case clean_plain
run_e2e --clean
assert_eq "--clean exits 0 on a clean run" 0 "${STATUS}"
assert_eq "--clean removes the one tag it built" \
    "$(tag_in "$(calls_for build)")" "$(tag_in "$(calls_for rmi)")"
assert_eq "and removes nothing else" 1 "$(calls_for rmi | wc -l)"

# --- --rechunk re-layers, then verifies the result --------------------------

new_case rechunk
run_e2e --rechunk
assert_eq "--rechunk exits 0 when every check passes" 0 "${STATUS}"
built_tag="$(tag_in "$(calls_for build)")"
chunked_tag="${built_tag}-chunked"
chunkah_call="$(grep -- '--mount=type=image' <<<"${PODMAN_CALLS}" | head -1)"

assert_contains "chunkah is given the built image as its source" \
    "${chunkah_call}" "--mount=type=image,src=${built_tag},target=/chunkah"
assert_contains "chunkah runs the pinned image the workflow pins" \
    "${chunkah_call}" "quay.io/coreos/chunkah:"
# These are the workflow's own flags. A local rechunk that differs from the
# workflow's is not a rehearsal of anything, and the drift would be silent.
assert_contains "with the workflow's layer cap" "${chunkah_call}" "--max-layers 128"
assert_contains "with the workflow's prune path" "${chunkah_call}" "--prune /sysroot/"
assert_contains "dropping the ostree.commit label" \
    "${chunkah_call}" "--label ostree.commit-"
assert_contains "dropping the ostree.final-diffid label" \
    "${chunkah_call}" "--label ostree.final-diffid-"
assert_contains "and tagging the result separately from the build" \
    "${chunkah_call}" "--tag ${chunked_tag}"
# The config is passed as a string because a full inspect carries RootFS.Layers
# and History and can exceed MAX_ARG_STRLEN. Reading anything wider than
# .Config would reintroduce that.
assert_contains "the config is read narrowly, not as a full inspect" \
    "${PODMAN_CALLS}" "inspect --format {{json .Config}} ${built_tag}"
assert_contains "and handed to chunkah through the environment" \
    "${chunkah_call}" "-e CHUNKAH_CONFIG_STR"

# Verifying the pre-rechunk image would make --rechunk assert nothing: the
# in-build checks already passed against it.
assert_contains "the archive is loaded back" "${PODMAN_CALLS}" "load -i "
assert_contains "post-check.sh is re-run against the rechunked image" \
    "${chunked_tag}" "$(tag_in "$(grep -- '/post-check.sh' <<<"${PODMAN_CALLS}" | head -1)")"
assert_contains "and the final report names the rechunked image" \
    "${STDOUT}" "all passed (${chunked_tag})"
assert_contains "the rechunk is reported as a check of its own" \
    "${STDOUT}" "ok   Chunkah produced a loadable image"
assert_contains "so the tally grows by it" "${STDOUT}" "e2e: 7 check(s)"

new_case rechunk_clean
run_e2e --rechunk --clean
built_tag="$(tag_in "$(calls_for build)")"
# Both tags exist by the end, and the chunked one is the larger. A CREATED_TAGS
# append missed after the rechunk would leave it behind with --clean passed.
assert_eq "--clean after a rechunk removes both tags it created" \
    2 "$(calls_for rmi | wc -l)"
assert_contains "including the built image" "${PODMAN_CALLS}" "rmi -f ${built_tag}"
assert_contains "and the rechunked one" "${PODMAN_CALLS}" "rmi -f ${built_tag}-chunked"

# --- the archive is this script's own temp file and never outlives it -------

new_case archive_location
E2E_ENV=(E2E_ARCHIVE_DIR="${WORK_ROOT}/archive_location/archive" TMPDIR="${WORK_ROOT}/archive_location/tmp")
mkdir -p "${WORK_ROOT}/archive_location/tmp"
run_e2e --rechunk
assert_eq "E2E_ARCHIVE_DIR is honoured for the archive" 0 "${STATUS}"
# The directory is created rather than required: the default sits beside
# podman's storage, which need not have this subdirectory yet.
archive_dir_kind="missing"
[[ -d "${WORK_ROOT}/archive_location/archive" ]] && archive_dir_kind="directory"
assert_eq "and the directory is created if absent" "directory" "${archive_dir_kind}"
assert_eq "a successful rechunk leaves no archive behind" \
    "" "$(find "${WORK_ROOT}/archive_location/archive" -name 'chunkah-e2e-*' -print -quit)"
assert_eq "and none in TMPDIR either" \
    "" "$(find "${WORK_ROOT}/archive_location/tmp" -name 'chunkah-e2e-*' -print -quit)"

new_case archive_removed_on_failure
E2E_ENV=(STUB_LOAD_STATUS=1 E2E_ARCHIVE_DIR="${WORK_ROOT}/archive_removed_on_failure/archive")
run_e2e --rechunk
# `set -e` aborts on the failed load, which is exactly when a multi-gigabyte
# archive is most damaging to strand: the likeliest reason the load failed is
# that the disk is full.
assert_eq "a failed load aborts the run" 1 "${STATUS}"
assert_contains "and the EXIT trap says it is removing the archive" \
    "${STDOUT}" "==> Removing temporary archive"
assert_eq "and the archive is gone" \
    "" "$(find "${WORK_ROOT}/archive_removed_on_failure/archive" -name 'chunkah-e2e-*' -print -quit)"
# The archive goes on every exit path; --clean governs images only.
assert_eq "a failure without --clean still keeps the images" "" "$(calls_for rmi)"

new_case rechunk_failure_cleans_up
E2E_ENV=(STUB_CHUNKAH_FAILS=1 E2E_ARCHIVE_DIR="${WORK_ROOT}/rechunk_failure_cleans_up/archive")
run_e2e --rechunk --clean
# chunkah's own status is what comes back, so a rechunk that failed is
# distinguishable from a check that failed, which exits 1.
assert_eq "a failed chunkah aborts the run with chunkah's status" 3 "${STATUS}"
assert_eq "and no archive is left in the archive directory" \
    "" "$(find "${WORK_ROOT}/rechunk_failure_cleans_up/archive" -name 'chunkah-e2e-*' -print -quit)"
# CREATED_TAGS holds only the build tag at this point, and --clean must not
# reach for a chunked image that was never loaded.
assert_contains "--clean removes the image that does exist" \
    "${PODMAN_CALLS}" "rmi -f $(tag_in "$(calls_for build)")"
assert_eq "and does not reach for the one that never loaded" \
    1 "$(calls_for rmi | wc -l)"

# --- a failed build is reported as a build failure, not a check failure -----

new_case build_failure
E2E_ENV=(STUB_BUILD_STATUS=7)
run_e2e
assert_eq "a failed build propagates its status" 7 "${STATUS}"
# `set -e` aborts before any check runs, so there is no tally to print and
# nothing may claim the image was verified.
assert_not_contains "and reports no check tally" "${STDOUT}" "check(s)"
assert_not_contains "and verifies nothing" "${STDOUT}" "==> Verifying"

finish
