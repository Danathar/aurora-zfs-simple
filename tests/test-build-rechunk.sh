#!/usr/bin/env bash
#
# Covers the build band of .github/workflows/build.yml's `build_push` job — the
# three `run:` bodies that prepare the runner and re-layer the built image:
#
#   Update Podman                             cross-release toolchain pin
#   Move container storage to the large disk   relocates podman's store to /mnt
#   Rechunk Image with Chunkah                 the rechunk itself
#
# tests/README.md's own "Not covered" section names these three as executed by
# nothing, and they are: they are shell inside YAML strings, so run-tests.sh
# does not find them, test-shell-syntax.sh does not `bash -n` them, and the
# linter never sees them either. test-ci-workflows.sh reads build.yml only
# structurally. test-build-publish.sh covers the four `run:` bodies *after*
# these. tests/e2e/run-e2e.sh re-implements a rechunk of its own — its own
# `podman run ... chunkah`, its own `TMPDIR` load — against a locally built
# image; it never executes this workflow's shell, so the two can drift without
# anything noticing.
#
# What these bodies decide, and how each fails:
#
#   1. `Update Podman` exists because Ubuntu 24.04's podman drops Chunkah's
#      layer annotations on push. It pins crun/buildah/podman/skopeo to the
#      `resolute` pocket with --allow-downgrades, and it is written to retire
#      itself once the hosted runner ships podman >= 5. Both sides matter: lose
#      the skip and the job keeps doing a cross-release apt install forever;
#      lose the `/resolute` suffixes and apt installs the runner's own podman
#      again, which is the bug the step exists for — and the build still
#      succeeds, just with the annotations gone.
#
#   2. `Move container storage` replaces $HOME/.local/share/containers with a
#      symlink to /mnt/containers, because / cannot hold the built image and the
#      re-layered copy at once. The load-bearing line is the `rm -rf` before the
#      `ln -s`: against a pre-existing store, `ln -s` without it creates
#      `containers/containers` instead, podman keeps using /, and the step still
#      exits 0. The failure surfaces much later as an out-of-disk mid-rechunk.
#
#   3. `Rechunk Image with Chunkah` carries two fixes its own comments record.
#      `podman inspect --format '{{json .Config}}'` is deliberate: the full
#      inspect grows with the base image's layer count, and at 256 layers it
#      crossed MAX_ARG_STRLEN and exec failed with E2BIG. And the
#      buffer-to-archive / `podman image prune -af` / `TMPDIR=/mnt/tmp podman
#      load` sequence is what keeps two unpacked copies of the image off one
#      disk. The ordering is a safety property, not a style: the prune deletes
#      the source image, so it must not run when the chunkah container failed.
#      The `export CHUNKAH_CONFIG_STR` on its own line is load-bearing too —
#      folded into the assignment, `export X="$(podman inspect ...)"` would
#      return export's status and a failed inspect would sail on into the run.
#      The final `for tag in ${TAGS}` is unquoted on purpose: the metadata
#      action emits space-separated tags.
#
# Each body is extracted from the YAML and executed as a real subprocess with
# the step's env, against recording `podman`, `sudo`, `apt-get` and `df` stubs
# and a redirected HOME. The `sudo` stub records and returns — it never execs —
# so nothing here writes to /etc or /mnt on the machine running the suite.
#
# The YAML is read with PyYAML rather than by hand, as test-build-publish.sh,
# test-ai-fix.sh and test-nightly-compliance.sh do: these are block scalars, and
# re-deriving their indentation with sed is a second implementation that can
# disagree with the one Actions uses. The `on:` key is the known trap — YAML 1.1
# reads a bare `on` as the boolean true — so the normalizer renames it back and
# is checked against a fixture with a known answer before it is trusted.

set -uo pipefail

TEST_NAME="test-build-rechunk"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

BUILD_WF="${REPO_ROOT}/.github/workflows/build.yml"
WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

if [[ ! -f "${BUILD_WF}" ]]; then
    _fail "build.yml exists" \
        "no such file: ${BUILD_WF}" \
        "if the workflow was removed on purpose, delete this test with it"
    finish
    exit 1
fi

# This decides how the published image is re-layered; a missing parser must fail
# rather than skip, including when the file is invoked directly instead of
# through run-tests.sh.
if ! "${WORKFLOW_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    _fail "the build.yml rechunk check requires Python 3 with PyYAML" \
        "install python3-yaml (Debian/Ubuntu) or python3-pyyaml (Fedora)," \
        "or install PyYAML in the interpreter selected by WORKFLOW_PYTHON"
    finish
    exit 1
fi

# --- normalizer -------------------------------------------------------------

NORMALIZER="${TMP_ROOT}/normalize.py"
cat >"${NORMALIZER}" <<'PY'
"""Print one workflow file as JSON, with the `on:` key readable by name.

YAML 1.1 -- which is what PyYAML implements, and what Actions accepts -- reads a
bare `on` as the boolean true, so `doc["on"]` raises KeyError on every workflow
ever written. Renaming it here keeps that quirk in one place instead of in
every jq path below.
"""

import json
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = yaml.safe_load(handle)

if isinstance(doc, dict) and True in doc:
    doc["on"] = doc.pop(True)

json.dump(doc, sys.stdout)
PY

# --- the normalizer is tested before it is trusted --------------------------

fixture="${TMP_ROOT}/fixture.yml"
cat >"${fixture}" <<'YAML'
---
name: Fixture
on:
  push:
    branches:
      - main
env:
  IMAGE_NAME: fixture-image
jobs:
  demo:
    steps:
      - name: Named step
        env:
          TAGS: ${{ steps.metadata.outputs.tags }}
        run: |
          echo marker
YAML

fixture_json="${TMP_ROOT}/fixture.json"
if "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${fixture}" >"${fixture_json}" 2>"${TMP_ROOT}/fixture.err"; then
    assert_eq "the normalizer reads a fixture's push branches by name" \
        "main" "$(jq -r '.on.push.branches[0]' <"${fixture_json}")"
    assert_eq "the normalizer reads a fixture's workflow-level env" \
        "fixture-image" "$(jq -r '.env.IMAGE_NAME' <"${fixture_json}")"
    assert_eq "the normalizer reads a fixture's block-scalar run: body" \
        "echo marker" "$(jq -r '.jobs.demo.steps[0].run' <"${fixture_json}")"
    # shellcheck disable=SC2016 # an Actions expression, compared as literal text
    assert_eq "the normalizer reads a fixture step's env: block" \
        '${{ steps.metadata.outputs.tags }}' \
        "$(jq -r '.jobs.demo.steps[] | select(.name == "Named step") | .env.TAGS' <"${fixture_json}")"
else
    _fail "the normalizer parses a fixture workflow" "$(cat "${TMP_ROOT}/fixture.err")"
fi

# --- the real file ----------------------------------------------------------

WF_JSON="${TMP_ROOT}/build.json"
if ! "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${BUILD_WF}" >"${WF_JSON}" 2>"${TMP_ROOT}/wf.err"; then
    _fail "build.yml parses as YAML" "$(cat "${TMP_ROOT}/wf.err")"
    finish
    exit 1
fi
_pass "build.yml parses as YAML"

# wf <jq expression> — one value out of the parsed workflow.
wf() {
    jq -r "$1" <"${WF_JSON}"
}

# step_field <step name> <field> — one field of one build_push step, or "".
step_field() {
    wf ".jobs.build_push.steps[] | select(.name == \"$1\") | .$2 // \"\""
}

# extract <destination> <step name> <marker> — pull a run: body out and refuse
# to continue with an empty or unrecognisable one. Without this, a renamed step
# would leave every case below running an empty file: exit 0, no output, no
# recorded calls, and assertions that pass while measuring nothing.
extract() {
    local dest=$1 name=$2 marker=$3
    step_field "${name}" "run" >"${dest}"
    if [[ ! -s "${dest}" ]] || ! grep -q -- "${marker}" "${dest}"; then
        _fail "the '${name}' script was extracted from build.yml" \
            "expected a run: body containing ${marker}; extracted" \
            "$(wc -c <"${dest}") byte(s) from the build_push job" \
            "the step name probably changed — update this test to match"
        finish
        exit 1
    fi
    _pass "the '${name}' script was extracted from build.yml"
}

# The workflow-level IMAGE_NAME is an Actions expression, and `Prepare
# environment` — the job's first step — lower-cases it into GITHUB_ENV before
# any of the steps below run. `Danathar/Aurora-ZFS-Simple` carries capitals,
# which are not legal in a registry reference and would also produce a
# `localhost/Aurora-ZFS-Simple:latest` the build step never created. So the
# value the rechunk sees is taken from that step rather than hand-written, the
# same way test-build-publish.sh does it for the publish band.
# shellcheck disable=SC2016 # an Actions expression, compared as literal text
assert_eq "the workflow still derives the image name from the repository" \
    '${{ github.event.repository.name }}' "$(wf '.env.IMAGE_NAME')"

PREPARE="${TMP_ROOT}/prepare.sh"
extract "${PREPARE}" "Prepare environment" 'GITHUB_ENV'

prepare_dir="$(mktemp -d "${TMP_ROOT}/prepare.XXXXXX")"
: >"${prepare_dir}/env"
IMAGE_REGISTRY="ghcr.io/Danathar" \
    IMAGE_NAME="Aurora-ZFS-Simple" \
    GITHUB_ENV="${prepare_dir}/env" \
    bash "${PREPARE}" >/dev/null 2>&1

IMAGE_NAME="$(grep -m1 '^IMAGE_NAME=' "${prepare_dir}/env" | cut -d= -f2-)"
DEFAULT_TAG="$(wf '.env.DEFAULT_TAG')"

assert_eq "the name the later steps address the image by is lower-cased" \
    "aurora-zfs-simple" "${IMAGE_NAME}"
assert_eq "the workflow still defines the DEFAULT_TAG the rechunk sources from" \
    "latest" "${DEFAULT_TAG}"

# --- shared stubs -----------------------------------------------------------

# make_sudo <dir> — a recording `sudo` that never execs.
#
# The real step writes an apt sources list under /etc and creates directories
# under /mnt. Running that for real would need root and would change the machine
# running the suite, so the stub records the argv instead and, for `tee`, writes
# the piped content into <dir>/root/<path>. That keeps the one thing worth
# observing — what would have been written where — without the privilege.
make_sudo() {
    local dir=$1
    mkdir -p "${dir}/bin" "${dir}/root"
    : >"${dir}/sudo-calls"

    cat >"${dir}/bin/sudo" <<PY
#!/usr/bin/env bash
dir=${dir@Q}
printf '%s\n' "\$*" >>"\${dir}/sudo-calls"

if [ "\$1" = "tee" ]; then
    target="\${dir}/root\$2"
    mkdir -p "\$(dirname "\${target}")"
    tee "\${target}"
    exit 0
fi
exit 0
PY
    chmod +x "${dir}/bin/sudo"
}

# make_df <dir> — `df` reports on / and /mnt in these steps. /mnt does not
# exist on most machines running this suite and real df exits non-zero for a
# missing path, which `set -e` would turn into a failure of the step rather than
# of the thing under test. Record the call and return.
make_df() {
    local dir=$1
    mkdir -p "${dir}/bin"
    : >"${dir}/df-calls"

    cat >"${dir}/bin/df" <<PY
#!/usr/bin/env bash
dir=${dir@Q}
printf '%s\n' "\$*" >>"\${dir}/df-calls"
exit 0
PY
    chmod +x "${dir}/bin/df"
}

# calls_of <file> — the recorded argv lines as one string, for assert_contains.
calls_of() {
    cat "$1"
}

# =============================================================================
# A. "Update Podman" — the cross-release pin, and the skip that retires it
# =============================================================================

UPDATE_PODMAN="${TMP_ROOT}/update-podman.sh"
extract "${UPDATE_PODMAN}" "Update Podman" 'allow-downgrades'

# run_update_podman <case dir> <podman --version output>
run_update_podman() {
    local dir=$1 version=$2
    mkdir -p "${dir}/bin"
    make_sudo "${dir}"
    : >"${dir}/apt-calls"

    cat >"${dir}/bin/podman" <<PY
#!/usr/bin/env bash
printf '%s\n' ${version@Q}
exit 0
PY
    chmod +x "${dir}/bin/podman"

    # apt-get is reached only through sudo, but a stub on PATH keeps a mutant
    # that dropped the sudo from failing for the wrong reason.
    cat >"${dir}/bin/apt-get" <<PY
#!/usr/bin/env bash
dir=${dir@Q}
printf '%s\n' "\$*" >>"\${dir}/apt-calls"
exit 0
PY
    chmod +x "${dir}/bin/apt-get"

    PATH="${dir}/bin:${PATH}" bash "${UPDATE_PODMAN}" >"${dir}/out" 2>"${dir}/err"
    printf '%s' "$?" >"${dir}/status"
}

# A1. a runner that already ships podman 5 — the step must retire itself
skip_dir="$(mktemp -d "${TMP_ROOT}/podman-skip.XXXXXX")"
run_update_podman "${skip_dir}" "podman version 5.4.0"

assert_eq "the podman update succeeds on a runner that already has podman 5" \
    "0" "$(cat "${skip_dir}/status")"
assert_contains "it says it is skipping the cross-release install" \
    "$(cat "${skip_dir}/out")" "skipping cross-release install"
assert_eq "it runs no sudo at all when podman is new enough" \
    "" "$(calls_of "${skip_dir}/sudo-calls")"
assert_eq "it runs no apt-get at all when podman is new enough" \
    "" "$(calls_of "${skip_dir}/apt-calls")"
assert_file_missing "it writes no resolute sources list when it skips" \
    "${skip_dir}/root/etc/apt/sources.list.d/resolute.list"

# A2. the boundary. `-ge 5` is what makes the step retire on the first hosted
# image that ships podman 5.0 rather than one release later.
boundary_dir="$(mktemp -d "${TMP_ROOT}/podman-boundary.XXXXXX")"
run_update_podman "${boundary_dir}" "podman version 5.0.0"

assert_eq "podman 5.0.0 is treated as new enough, not one release short" \
    "" "$(calls_of "${boundary_dir}/apt-calls")"
assert_contains "podman 5.0.0 takes the skip path" \
    "$(cat "${boundary_dir}/out")" "skipping cross-release install"

# A3. Ubuntu 24.04's own podman — the install path
install_dir="$(mktemp -d "${TMP_ROOT}/podman-install.XXXXXX")"
run_update_podman "${install_dir}" "podman version 4.9.3"

sudo_calls="$(calls_of "${install_dir}/sudo-calls")"
assert_eq "the podman update succeeds on a runner with podman 4" \
    "0" "$(cat "${install_dir}/status")"
assert_not_contains "podman 4.9.3 does not take the skip path" \
    "$(cat "${install_dir}/out")" "skipping cross-release install"
assert_file_exists "it writes an apt sources list for the resolute pocket" \
    "${install_dir}/root/etc/apt/sources.list.d/resolute.list"
assert_eq "the sources list names the resolute pocket's universe and main" \
    "deb http://azure.archive.ubuntu.com/ubuntu resolute universe main" \
    "$(cat "${install_dir}/root/etc/apt/sources.list.d/resolute.list" 2>/dev/null)"
assert_contains "it refreshes the package lists before installing" \
    "${sudo_calls}" "apt-get update"

# The four packages are pinned to the resolute pocket by name. Without the
# suffixes apt resolves the runner's own release, which is the podman that drops
# Chunkah's layer annotations — and the build still succeeds.
for pkg in crun buildah podman skopeo; do
    assert_contains "it installs ${pkg} pinned to the resolute pocket" \
        "${sudo_calls}" "${pkg}/resolute"
done
assert_contains "it allows the downgrade the cross-release pin needs" \
    "${sudo_calls}" "--allow-downgrades"

# apt-get update has to precede the install, or the resolute pocket is not in
# the lists yet and the pinned versions are unresolvable.
update_line="$(grep -n 'apt-get update' "${install_dir}/sudo-calls" | head -n 1 | cut -d: -f1)"
install_line="$(grep -n 'apt-get install' "${install_dir}/sudo-calls" | head -n 1 | cut -d: -f1)"
if [[ -n "${update_line}" && -n "${install_line}" && "${update_line}" -lt "${install_line}" ]]; then
    _pass "it refreshes the lists before installing from the new pocket"
else
    _fail "it refreshes the lists before installing from the new pocket" \
        "recorded sudo calls:" "${sudo_calls}"
fi

# =============================================================================
# B. "Move container storage to the large runner disk"
# =============================================================================
#
# The rechunk needs room for the built image and its re-layered copy. This step
# is what puts podman's store on /mnt (~66G) instead of / — and it runs on a
# hosted runner where $HOME/.local/share/containers already exists with content
# in it.

MOVE_STORAGE="${TMP_ROOT}/move-storage.sh"
extract "${MOVE_STORAGE}" "Move container storage to the large runner disk" \
    '/mnt/containers'

move_dir="$(mktemp -d "${TMP_ROOT}/move-storage.XXXXXX")"
make_sudo "${move_dir}"
make_df "${move_dir}"
move_home="${move_dir}/home"

# The pre-existing store the hosted image ships. If the `rm -rf` were dropped,
# `ln -s` would put the link *inside* this directory and podman would go on
# using /.
mkdir -p "${move_home}/.local/share/containers/storage"
: >"${move_home}/.local/share/containers/storage/pre-existing"

PATH="${move_dir}/bin:${PATH}" HOME="${move_home}" \
    bash "${MOVE_STORAGE}" >"${move_dir}/out" 2>"${move_dir}/err"
move_status=$?

assert_eq "the storage move succeeds" "0" "${move_status}"

store="${move_home}/.local/share/containers"
if [[ -L "${store}" ]]; then
    _pass "podman's store is left as a symlink, not a directory"
    assert_eq "the store points at the large disk" \
        "/mnt/containers" "$(readlink "${store}")"
else
    _fail "podman's store is left as a symlink, not a directory" \
        "the rm -rf before the ln -s is what makes this hold against the" \
        "pre-existing store on a hosted runner; without it the link is" \
        "created inside the existing directory and podman keeps using /"
fi
assert_file_missing "the link is not nested inside the old store" \
    "${move_home}/.local/share/containers/containers"
assert_file_missing "the old store's content is gone rather than left on /" \
    "${move_home}/.local/share/containers/storage/pre-existing"

move_sudo="$(calls_of "${move_dir}/sudo-calls")"
assert_contains "it creates the target directory on the large disk" \
    "${move_sudo}" "mkdir -p /mnt/containers"
# /mnt is root-owned on the hosted runners, so an unprivileged podman can only
# write there after this chown. It has to name the running user, not root.
assert_contains "it hands the target to the unprivileged build user" \
    "${move_sudo}" "chown $(id -u):$(id -g) /mnt/containers"
assert_contains "it reports the free space on both disks it is balancing" \
    "$(calls_of "${move_dir}/df-calls")" "-h / /mnt"

# =============================================================================
# C. "Rechunk Image with Chunkah"
# =============================================================================

RECHUNK="${TMP_ROOT}/rechunk.sh"
extract "${RECHUNK}" "Rechunk Image with Chunkah" 'chunkah'

# The step's own env: block. CHUNKAH_IMAGE is a literal, so the cases below run
# against the pinned image the workflow really uses; TAGS is an Actions
# expression, so the value is supplied here and the wiring is asserted instead.
CHUNKAH_IMAGE="$(step_field "Rechunk Image with Chunkah" 'env.CHUNKAH_IMAGE')"
# shellcheck disable=SC2016 # an Actions expression, compared as literal text
assert_eq "the rechunk still takes its tag list from the metadata step" \
    '${{ steps.metadata.outputs.tags }}' \
    "$(step_field "Rechunk Image with Chunkah" 'env.TAGS')"
assert_contains "the rechunk still pins the Chunkah image by tag" \
    "${CHUNKAH_IMAGE}" "quay.io/coreos/chunkah:"

# The archive path is a literal /tmp/chunkah-oci.tar inside the step, so the
# cases below write there for real. Refuse to run against a file this test did
# not create rather than deleting somebody else's.
ARCHIVE=/tmp/chunkah-oci.tar
if [[ -e "${ARCHIVE}" ]]; then
    _fail "the rechunk cases can use the step's archive path" \
        "${ARCHIVE} already exists and this test will not remove a file it" \
        "did not create; remove it by hand and re-run"
    finish
    exit 1
fi
trap 'rm -rf "${TMP_ROOT}" "${ARCHIVE}"' EXIT

# make_podman <dir> — a recording podman that behaves enough like the real one
# for the sequence under test.
#
# Records every argv into <dir>/calls, one line per call, so the order the
# archive/prune/load band runs in can be asserted. `inspect` prints a config
# document; `run` writes the fake archive to stdout, which the step redirects to
# a file; `load` records the TMPDIR it was given and the archive's content.
make_podman() {
    local dir=$1
    mkdir -p "${dir}/bin"
    : >"${dir}/calls"
    : >"${dir}/run-config"
    : >"${dir}/load-tmpdir"
    : >"${dir}/load-payload"

    cat >"${dir}/bin/podman" <<PY
#!/usr/bin/env bash
dir=${dir@Q}
printf '%s\n' "\$*" >>"\${dir}/calls"

case \$1 in
inspect)
    if [ -e "\${dir}/inspect-fails" ]; then
        echo "Error: no such object" >&2
        exit 125
    fi
    # The format string is honoured rather than ignored, so asking for the
    # whole document gets the whole document: RootFS.Layers, History and
    # GraphDriver.Data.LowerDir are the parts that scale with the base image's
    # layer count and blew past MAX_ARG_STRLEN at 256 layers.
    config='{"Env":["PATH=/usr/bin"],"Cmd":["/bin/bash"],"Labels":{"containers.bootc":"1"}}'
    case " \$* " in
    *".Config"*) printf '%s\n' "\${config}" ;;
    *) printf '%s\n' "{\"Config\":\${config},\"RootFS\":{\"Layers\":[\"sha256:aaa\",\"sha256:bbb\"]},\"History\":[{\"created_by\":\"RUN true\"}]}" ;;
    esac
    ;;
run)
    printf '%s' "\${CHUNKAH_CONFIG_STR-}" >"\${dir}/run-config"
    if [ -e "\${dir}/run-fails" ]; then
        echo "Error: chunkah exited 1" >&2
        exit 1
    fi
    printf 'FAKE-OCI-ARCHIVE\n'
    ;;
load)
    printf '%s' "\${TMPDIR-}" >"\${dir}/load-tmpdir"
    shift
    while [ "\$#" -gt 0 ]; do
        if [ "\$1" = "-i" ]; then
            cat "\$2" >"\${dir}/load-payload" 2>/dev/null
            break
        fi
        shift
    done
    ;;
*) ;;
esac
exit 0
PY
    chmod +x "${dir}/bin/podman"
}

# run_rechunk <case dir> <tags> — execute the step with the workflow's env.
run_rechunk() {
    local dir=$1 tags=$2
    make_podman "${dir}"
    make_sudo "${dir}"
    make_df "${dir}"
    [[ -e "${dir}/fail-run" ]] && : >"${dir}/run-fails"
    [[ -e "${dir}/fail-inspect" ]] && : >"${dir}/inspect-fails"

    PATH="${dir}/bin:${PATH}" \
        IMAGE_NAME="${IMAGE_NAME}" \
        DEFAULT_TAG="${DEFAULT_TAG}" \
        CHUNKAH_IMAGE="${CHUNKAH_IMAGE}" \
        TAGS="${tags}" \
        bash "${RECHUNK}" >"${dir}/out" 2>"${dir}/err"
    printf '%s' "$?" >"${dir}/status"
}

# nth_call <dir> <index> — the argv of the nth recorded podman call.
nth_call() {
    sed -n "$2p" "$1/calls"
}

# C1. the whole band, on the happy path.
#
# The tag list is space-separated because the metadata step sets
# `sep-tags: " "`, and the loop that consumes it is deliberately unquoted.
TAG_LIST="latest latest.20260909 20260909"
ok_dir="$(mktemp -d "${TMP_ROOT}/rechunk-ok.XXXXXX")"
run_rechunk "${ok_dir}" "${TAG_LIST}"

assert_eq "the rechunk succeeds" "0" "$(cat "${ok_dir}/status")"

# The config is read as `.Config` alone. The full inspect grows with the base
# image's layer count; at 256 layers it crossed MAX_ARG_STRLEN and podman's exec
# failed with E2BIG, so this format string is the fix and not a preference.
inspect_call="$(grep -m1 '^inspect ' "${ok_dir}/calls")"
assert_contains "it inspects only the .Config element of the source image" \
    "${inspect_call}" "--format {{json .Config}}"
assert_contains "it inspects the image the build step produced" \
    "${inspect_call}" "localhost/${IMAGE_NAME}:${DEFAULT_TAG}"

# The value reaches the container as an exported environment variable, which is
# the same MAX_ARG_STRLEN budget — so what it holds matters as much as how.
config_seen="$(cat "${ok_dir}/run-config")"
assert_contains "the config document is exported to the chunkah container" \
    "${config_seen}" '"containers.bootc"'
assert_not_contains "the exported config carries no per-layer content" \
    "${config_seen}" "RootFS"

run_call="$(grep -m1 '^run ' "${ok_dir}/calls")"
assert_contains "it mounts the built image into the chunkah container" \
    "${run_call}" "--mount=type=image,src=localhost/${IMAGE_NAME}:${DEFAULT_TAG},target=/chunkah"
assert_contains "it passes the config through the environment, not the argv" \
    "${run_call}" "-e CHUNKAH_CONFIG_STR"
assert_contains "it runs the pinned chunkah image" \
    "${run_call}" "${CHUNKAH_IMAGE}"
assert_contains "it caps the layer count so the result stays pullable" \
    "${run_call}" "--max-layers 128"
assert_contains "it prunes /sysroot/ out of the re-layered image" \
    "${run_call}" "--prune /sysroot/"
assert_contains "it drops the inherited ostree.commit label" \
    "${run_call}" "--label ostree.commit-"
assert_contains "it drops the inherited ostree.final-diffid label" \
    "${run_call}" "--label ostree.final-diffid-"
assert_contains "it asks chunkah for a compressed archive" \
    "${run_call}" "--compressed"
assert_contains "it tags the chunked result locally" \
    "${run_call}" "--tag localhost/${IMAGE_NAME}:chunkah"

# The ordering is the disk-space fix: buffer the archive, delete every image in
# the store, and only then unpack. Anything else keeps two copies of the root
# filesystem alive at once, which is what exhausted / intermittently.
assert_contains "the first call reads the source image's config" \
    "$(nth_call "${ok_dir}" 1)" "inspect"
assert_contains "the second call is the chunkah run that writes the archive" \
    "$(nth_call "${ok_dir}" 2)" "run"
assert_eq "the third call empties container storage, tagged images included" \
    "image prune -af" "$(nth_call "${ok_dir}" 3)"
assert_contains "the fourth call loads the buffered archive back" \
    "$(nth_call "${ok_dir}" 4)" "load -i /tmp/chunkah-oci.tar"

# podman unpacks the archive into TMPDIR before applying it. Left on /var/tmp
# that lands on the same disk the prune just freed, which is the disk the load's
# own output needs.
assert_eq "the load unpacks on the large disk, not under /var/tmp" \
    "/mnt/tmp" "$(cat "${ok_dir}/load-tmpdir")"
assert_eq "the load is handed the archive the chunkah run produced" \
    "FAKE-OCI-ARCHIVE" "$(cat "${ok_dir}/load-payload")"

rechunk_sudo="$(calls_of "${ok_dir}/sudo-calls")"
assert_contains "it creates the unpack directory on the large disk" \
    "${rechunk_sudo}" "mkdir -p /mnt/tmp"
assert_contains "it hands the unpack directory to the unprivileged build user" \
    "${rechunk_sudo}" "chown $(id -u):$(id -g) /mnt/tmp"

# Every published tag has to end up on the chunked image; the loop splits TAGS
# on whitespace, so quoting it would produce one ref named after all three.
for tag in ${TAG_LIST}; do
    assert_contains "it tags the chunked image as ${tag}" \
        "$(calls_of "${ok_dir}/calls")" "tag localhost/${IMAGE_NAME}:chunkah ${IMAGE_NAME}:${tag}"
done
assert_eq "it tags the chunked image once per space-separated tag" \
    "3" "$(grep -c "^tag " "${ok_dir}/calls")"

# The archive is the largest thing on / at this point and the job goes on to
# push, so it is removed once it has been loaded.
assert_file_missing "the buffered archive is removed after the load" "${ARCHIVE}"

# C2. a failed rechunk must not delete the source image.
#
# `podman image prune -af` removes the built image, the Aurora base and the
# akmods images. If it ran after a failed chunkah run, the job would have
# nothing left to retry with and nothing to push — and the `set -euo pipefail`
# at the top of the step is the whole of what prevents that.
fail_dir="$(mktemp -d "${TMP_ROOT}/rechunk-fail.XXXXXX")"
: >"${fail_dir}/fail-run"
run_rechunk "${fail_dir}" "${TAG_LIST}"

if [[ "$(cat "${fail_dir}/status")" != "0" ]]; then
    _pass "a failed chunkah run fails the step"
else
    _fail "a failed chunkah run fails the step" \
        "the step exited 0 after chunkah returned 1"
fi
assert_not_contains "a failed chunkah run does not empty container storage" \
    "$(calls_of "${fail_dir}/calls")" "image prune"
assert_not_contains "a failed chunkah run loads nothing" \
    "$(calls_of "${fail_dir}/calls")" "load -i"
assert_eq "a failed chunkah run tags nothing" \
    "0" "$(grep -c "^tag " "${fail_dir}/calls")"
rm -f "${ARCHIVE}"

# C3. a failed inspect must not reach the chunkah run either.
#
# This is what the separate `export CHUNKAH_CONFIG_STR` line buys: folded into
# the assignment, `export X="$(podman inspect ...)"` returns export's status,
# `set -e` sees success, and the container runs with an empty config — producing
# an image whose Env/Cmd/Labels are silently gone.
inspect_fail_dir="$(mktemp -d "${TMP_ROOT}/rechunk-inspect.XXXXXX")"
: >"${inspect_fail_dir}/fail-inspect"
run_rechunk "${inspect_fail_dir}" "${TAG_LIST}"

if [[ "$(cat "${inspect_fail_dir}/status")" != "0" ]]; then
    _pass "a failed inspect fails the step instead of running with no config"
else
    _fail "a failed inspect fails the step instead of running with no config" \
        "the step exited 0; an assignment that swallows the inspect's status" \
        "would rechunk with an empty CHUNKAH_CONFIG_STR"
fi
assert_not_contains "a failed inspect never starts the chunkah container" \
    "$(calls_of "${inspect_fail_dir}/calls")" "--mount=type=image"
rm -f "${ARCHIVE}"

finish
