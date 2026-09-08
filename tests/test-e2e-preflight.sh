#!/usr/bin/env bash
#
# Tests for tests/e2e/run-e2e.sh's option parsing, preflight and cleanup.
#
# run-e2e.sh builds the real image, so run-tests.sh deliberately does not glob
# it: tens of minutes and about 40G is not a unit test. What that leaves with no
# coverage at all is everything the script decides *before* the build -- which
# options it accepts, which filesystems it demands 40G on, and which images it
# removes on the way out. Those decisions are reached in milliseconds, and the
# only external commands involved are `podman` and `df`, both resolved through
# PATH. So this replaces both with stubs and lets the script run into `podman
# build`, which the stub fails.
#
# The properties pinned down here are the ones run-e2e.sh's own comments and
# tests/e2e/README.md argue for, each of which would be silent if it regressed:
#
#   * the free-space check probes the filesystems that actually receive data --
#     podman's graph root, and the archive directory under --rechunk -- rather
#     than the checkout, and deduplicates by device so one filesystem is never
#     asked for 40G twice
#   * a graph root that does not exist yet is probed at its nearest existing
#     ancestor instead of failing the check
#   * the archive directory defaults beside podman's storage rather than to
#     TMPDIR, because /tmp is tmpfs on the Atomic desktop this targets
#   * --clean removes exactly the tags this run created, by name
#   * an unmet prerequisite prints its own message and exits, rather than dying
#     under `set -u` inside the EXIT trap that is installed before ARCHIVE and
#     LOAD_TMPDIR have real values

set -uo pipefail

TEST_NAME="test-e2e-preflight"
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

# 40G is 41943040 KB, the threshold the script compares against. These two sit
# either side of it by a wide margin so the reported whole-gigabyte figure is
# unambiguous in the assertions below.
ROOMY_KB=99614720 # 95G
CRAMPED_KB=1048576 #  1G

# Fresh sandbox per case: its own stub bin, call log, df table, graph root and
# HOME, so no case can observe another's leftovers.
new_case() {
    local name=$1
    case_dir="${WORK_ROOT}/${name}"
    mkdir -p "${case_dir}/bin" "${case_dir}/graph" "${case_dir}/home"

    cat >"${case_dir}/bin/podman" <<'STUB'
#!/usr/bin/env bash
# Stub podman: records how it was called, answers the two preflight queries,
# and refuses to build so the script stops at the boundary under test.
printf '%s\n' "$*" >>"${STUB_CALLS}"
case "$1" in
--version)
    echo "podman version 5.0.0-stub"
    ;;
info)
    # The script maps a failure here to its HOME-based default.
    [[ -n "${STUB_INFO_FAILS:-}" ]] && exit 1
    printf '%s\n' "${STUB_GRAPH_ROOT}"
    ;;
build)
    echo "stub podman: refusing to build" >&2
    exit 7
    ;;
*) ;;
esac
exit 0
STUB

    cat >"${case_dir}/bin/df" <<'STUB'
#!/usr/bin/env bash
# Stub df: answers from a table of "path<TAB>device<TAB>available-KB" lines, so
# a case can place two probes on one device or on two. Unlisted paths get the
# defaults. Only -Pk output is produced, which is all the script parses.
target="${*: -1}"
device="/dev/stub-default"
avail="${STUB_DF_DEFAULT_KB}"
while IFS=$'\t' read -r path dev kb; do
    [[ -n "${path}" ]] || continue
    if [[ "${target}" == "${path}" ]]; then
        device="${dev}"
        avail="${kb}"
    fi
done <"${STUB_DF_TABLE}"
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '%s 0 0 %s 1%% /stub\n' "${device}" "${avail}"
STUB

    chmod +x "${case_dir}/bin/podman" "${case_dir}/bin/df"
    : >"${case_dir}/podman-calls.log"
    : >"${case_dir}/df-table"
    E2E_ENV=()
}

# Place a probe path on a named device with a given amount free.
stub_filesystem() {
    local path=$1 device=$2 available_kb=$3
    printf '%s\t%s\t%s\n' "${path}" "${device}" "${available_kb}" >>"${case_dir}/df-table"
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
            STUB_DF_TABLE="${case_dir}/df-table" \
            STUB_DF_DEFAULT_KB="${ROOMY_KB}" \
            ${E2E_ENV[@]+"${E2E_ENV[@]}"} \
            bash "${SCRIPT}" "$@" 2>&1
    )"
    STATUS=$?
    STDOUT="${out}"
    PODMAN_CALLS="$(cat "${case_dir}/podman-calls.log")"
}

# The free-space report prints one padded line per distinct device, so counting
# them is how "deduplicated by device" is observed from outside.
free_space_lines() {
    grep -c 'G free$' <<<"${STDOUT}"
}

# The tag out of a recorded `build`/`rmi` call, so the two can be compared.
tag_from_call() {
    local verb=$1
    grep "^${verb} " <<<"${PODMAN_CALLS}" |
        head -1 |
        tr ' ' '\n' |
        grep '^localhost/aurora-zfs-simple-e2e:'
}

# --- options are parsed before anything is required -------------------------

new_case help
run_e2e --help
assert_eq "--help exits 0" 0 "${STATUS}"
assert_contains "--help documents the plain invocation" \
    "${STDOUT}" "./tests/e2e/run-e2e.sh                 # build, then verify"
assert_contains "--help documents --rechunk" "${STDOUT}" "run-e2e.sh --rechunk"
assert_contains "--help documents --clean" "${STDOUT}" "run-e2e.sh --clean"
assert_contains "--help documents --keep-going" "${STDOUT}" "run-e2e.sh --keep-going"
assert_contains "--help documents E2E_ARCHIVE_DIR" "${STDOUT}" "E2E_ARCHIVE_DIR"
# The E2E_ARCHIVE_DIR paragraph is the last one in the header, and a fixed
# sed range once cut it mid-sentence -- after "Both default to podman's
# storage", before the line naming /var/tmp. Asserting the alternative and
# that the final line ends a sentence keeps the help honest about however
# long the header grows.
assert_contains "--help reaches the /var/tmp alternative" "${STDOUT}" "/var/tmp is the other"
help_last_line="$(printf '%s\n' "${STDOUT}" | sed -e 's/[[:space:]]*$//' -e '/^$/d' | tail -n 1)"
assert_eq "--help's last line ends a sentence" "." "${help_last_line: -1}"
assert_eq "--help runs no podman" "" "${PODMAN_CALLS}"

new_case unknown_option
run_e2e --nope
assert_eq "an unknown option exits 2" 2 "${STATUS}"
assert_contains "and names the option it rejected" "${STDOUT}" "run-e2e: unknown option: --nope"
assert_eq "and runs no podman" "" "${PODMAN_CALLS}"

# --- an unmet prerequisite reports itself rather than dying in the trap ------

new_case no_podman
mkdir -p "${case_dir}/minbin"
# Only what the script reaches before the podman check: bash to run it, dirname
# to resolve E2E_DIR, date to stamp the tag. A PATH built from the real one
# would find a runner's podman.
#
# Keep this list in step with run-e2e.sh's preamble. A missing entry does not
# announce itself the same way on every bash: through 5.2, `dirname` absent
# left `cd "$(dirname ...)"` doing nothing and the script walked on to the
# podman check, so this case passed while proving nothing about it; 5.3 rejects
# `cd ""` as a null directory and `set -e` takes the script out before the
# check it exists to exercise. The assertion below refuses both readings.
ln -s "$(command -v bash)" "${case_dir}/minbin/bash"
ln -s "$(command -v dirname)" "${case_dir}/minbin/dirname"
ln -s "$(command -v date)" "${case_dir}/minbin/date"
STDOUT="$(
    env -i PATH="${case_dir}/minbin" HOME="${case_dir}/home" \
        bash "${SCRIPT}" 2>&1
)"
STATUS=$?
assert_eq "a missing podman exits 1" 1 "${STATUS}"
assert_contains "and says what is missing" "${STDOUT}" "run-e2e: podman is required"
# The exit status above is 1 whether podman was reported missing or the script
# died on a binary this sandbox forgot to provide. Name the second reading so a
# future preamble command fails here, saying which one, on every bash.
assert_not_contains "and reached the check with every binary it needs" \
    "${STDOUT}" "command not found"
# ARCHIVE and LOAD_TMPDIR are seeded empty for exactly this path: the EXIT trap
# is installed before either has a real value, and `set -u` would otherwise turn
# a reported prerequisite failure into an error inside cleanup.
assert_not_contains "and the EXIT trap does not fail under set -u" \
    "${STDOUT}" "unbound variable"

# --- the free-space check probes what receives data -------------------------

new_case roomy_graph_root
run_e2e
assert_contains "the graph root is the filesystem probed" "${STDOUT}" "${case_dir}/graph"
assert_contains "and its free space is reported" "${STDOUT}" "95G free"
assert_eq "without --rechunk exactly one filesystem is probed" 1 "$(free_space_lines)"
assert_not_contains "the checkout is not probed" "${STDOUT}" "${REPO_ROOT} "
assert_contains "and the build proceeds past preflight" "${PODMAN_CALLS}" \
    "build --tag localhost/aurora-zfs-simple-e2e:"
assert_contains "building the repository's own Containerfile" "${PODMAN_CALLS}" \
    "--file ${REPO_ROOT}/Containerfile ${REPO_ROOT}"

new_case cramped_graph_root
stub_filesystem "${case_dir}/graph" /dev/stub-graph "${CRAMPED_KB}"
run_e2e
assert_eq "a graph root short of 40G exits 1" 1 "${STATUS}"
assert_contains "naming the path, its device and what is free" "${STDOUT}" \
    "run-e2e: ${case_dir}/graph (/dev/stub-graph) has 1G free; want at least 40G"
assert_contains "and saying why that is not enough" "${STDOUT}" \
    "run-e2e: the base image, akmods layers and the built image will not fit"
assert_not_contains "the build is never started" "${PODMAN_CALLS}" "build --tag"

# A graph root is created by the first pull, so a machine that has never pulled
# an image has none. Probing the nearest existing ancestor is what keeps that
# from reading as a missing filesystem.
new_case unpulled_graph_root
E2E_ENV=(STUB_GRAPH_ROOT="${case_dir}/graph/never/created")
run_e2e
assert_contains "an absent graph root is probed at its nearest ancestor" \
    "${STDOUT}" "${case_dir}/graph "
assert_not_contains "not at the path that does not exist" "${STDOUT}" "never/created"
assert_eq "and the check still passes" 1 "$(free_space_lines)"

# `podman info` failing is not a reason to skip the check; the script falls back
# to the documented default location.
new_case podman_info_fails
E2E_ENV=(STUB_INFO_FAILS=1)
run_e2e
assert_contains "a failed podman info falls back to the HOME default" \
    "${STDOUT}" "${case_dir}/home"
assert_eq "and one filesystem is still probed" 1 "$(free_space_lines)"

# --- --rechunk adds the archive directory, deduplicated by device -----------

new_case rechunk_second_device
stub_filesystem "${case_dir}/graph" /dev/stub-graph "${ROOMY_KB}"
stub_filesystem "${case_dir}/archive" /dev/stub-archive "${ROOMY_KB}"
mkdir -p "${case_dir}/archive"
E2E_ENV=(E2E_ARCHIVE_DIR="${case_dir}/archive")
run_e2e --rechunk
assert_eq "--rechunk on two devices probes both" 2 "$(free_space_lines)"
assert_contains "the graph root among them" "${STDOUT}" "${case_dir}/graph "
assert_contains "and the archive directory" "${STDOUT}" "${case_dir}/archive "

new_case rechunk_one_device
stub_filesystem "${case_dir}/graph" /dev/stub-shared "${ROOMY_KB}"
stub_filesystem "${case_dir}/archive" /dev/stub-shared "${ROOMY_KB}"
mkdir -p "${case_dir}/archive"
E2E_ENV=(E2E_ARCHIVE_DIR="${case_dir}/archive")
run_e2e --rechunk
assert_eq "two paths on one device are asked for 40G once" 1 "$(free_space_lines)"

new_case rechunk_cramped_archive
stub_filesystem "${case_dir}/graph" /dev/stub-graph "${ROOMY_KB}"
stub_filesystem "${case_dir}/archive" /dev/stub-archive "${CRAMPED_KB}"
mkdir -p "${case_dir}/archive"
E2E_ENV=(E2E_ARCHIVE_DIR="${case_dir}/archive")
run_e2e --rechunk
assert_eq "a short archive directory fails the run" 1 "${STATUS}"
assert_contains "even though the graph root has room" "${STDOUT}" \
    "run-e2e: ${case_dir}/archive (/dev/stub-archive) has 1G free"
assert_not_contains "and no build is started" "${PODMAN_CALLS}" "build --tag"

new_case rechunk_cramped_archive_without_rechunk
stub_filesystem "${case_dir}/graph" /dev/stub-graph "${ROOMY_KB}"
stub_filesystem "${case_dir}/archive" /dev/stub-archive "${CRAMPED_KB}"
mkdir -p "${case_dir}/archive"
E2E_ENV=(E2E_ARCHIVE_DIR="${case_dir}/archive")
run_e2e
assert_contains "without --rechunk the archive directory is not probed" \
    "${PODMAN_CALLS}" "build --tag"
assert_not_contains "so its free space is never reported" "${STDOUT}" "/dev/stub-archive"

# The archive is measured in gigabytes and /tmp is tmpfs on a Fedora Atomic
# desktop, which is what this project's readers run. Defaulting to TMPDIR would
# fail on a host with hundreds of free gigabytes.
new_case archive_dir_default
stub_filesystem "${case_dir}/graph" /dev/stub-graph "${ROOMY_KB}"
stub_filesystem "${case_dir}" /dev/stub-parent "${ROOMY_KB}"
E2E_ENV=(TMPDIR="${case_dir}/tmpfs")
mkdir -p "${case_dir}/tmpfs"
run_e2e --rechunk
assert_contains "the archive defaults beside podman's storage" "${STDOUT}" "${case_dir} "
assert_not_contains "not to TMPDIR" "${STDOUT}" "${case_dir}/tmpfs"

# --- cleanup removes only what this run created -----------------------------

new_case clean_removes_its_own_tags
run_e2e --clean
assert_contains "--clean says what it is removing" "${STDOUT}" \
    "Removing only the images this run created"
assert_eq "and removes exactly the tag it built" \
    "$(tag_from_call build)" "$(tag_from_call rmi)"
assert_contains "by name, forced" "${PODMAN_CALLS}" "rmi -f localhost/aurora-zfs-simple-e2e:"
assert_eq "removing one image and no more" 1 "$(grep -c '^rmi ' <<<"${PODMAN_CALLS}")"
assert_not_contains "nothing is pruned" "${PODMAN_CALLS}" "prune"

new_case no_clean_removes_nothing
run_e2e
assert_contains "a run without --clean still built" "${PODMAN_CALLS}" "build --tag"
assert_not_contains "and removed no image" "${PODMAN_CALLS}" "rmi"

finish
