#!/usr/bin/env bash
#
# Covers ci/boot-test.sh against stubbed skopeo, podman and bcvk, and the
# shape of .github/workflows/boot-test.yml that runs it.
#
# The script's job is a verdict on a boot nobody watches: pass only when the VM
# logged in and every check ran and passed, and retry only a boot that reported
# nothing. What is worth testing is that verdict, the digest it boots, and that
# the check script it hands the guest actually runs.
#
# No network, no VM: skopeo, podman and bcvk are shadowed on PATH. In "guest"
# mode the bcvk stub runs the generated check script itself, against stub
# systemctl, rpm, zpool and zfs commands and a stand-in for /sys/module/zfs, so
# a quoting mistake in the script the real guest would run fails here. In
# "canned" mode it prints a fixed SSH session, for the cases a real guest would
# only produce by misbehaving.
#
# What it cannot reach: whether bcvk, QEMU and the runner actually boot the
# image. Only the workflow's hosted run says that.

set -uo pipefail

TEST_NAME="test-boot-test"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

SCRIPT="${REPO_ROOT}/ci/boot-test.sh"
BOOT_WF="${REPO_ROOT}/.github/workflows/boot-test.yml"
WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT
STUB_DIR="${TMP_ROOT}/bin"
GUEST_DIR="${TMP_ROOT}/guest"
CALLS="${TMP_ROOT}/calls"
CANNED="${TMP_ROOT}/canned"
mkdir -p "${STUB_DIR}" "${GUEST_DIR}"

DIGEST="sha256:$(printf '%064d' 7 | tr 0 a)"
REVISION="0123456789abcdef0123456789abcdef01234567"
IMAGE="ghcr.io/danathar/aurora-zfs-simple"

# skopeo answers `inspect --format` with the digest and revision the test set.
cat >"${STUB_DIR}/skopeo" <<'STUB'
#!/usr/bin/env bash
printf 'skopeo %s\n' "$*" >>"${STUB_CALLS}"
if [[ -n "${SKOPEO_FAIL:-}" ]]; then
    echo "manifest unknown" >&2
    exit 1
fi
printf '%s %s\n' "${SKOPEO_DIGEST}" "${SKOPEO_REVISION-}"
STUB

cat >"${STUB_DIR}/podman" <<'STUB'
#!/usr/bin/env bash
printf 'podman %s\n' "$*" >>"${STUB_CALLS}"
if [[ "$1" == "pull" && -n "${PODMAN_PULL_FAIL:-}" ]]; then
    exit 125
fi
STUB

# bcvk: record the call, then either run the command after `--` the way the
# guest would, or print the canned session. ssh joins the command's words with
# spaces and hands the string to the remote shell, so the stub does the same.
#
# The one change it makes on the way: the check script reads the module at
# /sys/module/zfs, which here is the host's. The stub decodes the script, points
# that path at a scratch directory the case lays out (GUEST_SYS), and encodes it
# again, so the transport and every other word of the script are what run.
cat >"${STUB_DIR}/bcvk" <<'STUB'
#!/usr/bin/env bash
printf 'bcvk %s\n' "$*" >>"${STUB_CALLS}"
if [[ "${BCVK_MODE}" == "canned" ]]; then
    cat "${BCVK_CANNED}"
    exit "${BCVK_EXIT:-0}"
fi
while (($# > 0)) && [[ "$1" != "--" ]]; do
    shift
done
shift
command="$*"
if [[ ! "${command}" =~ ^echo\ ([A-Za-z0-9+/=]+)\ \|\ base64\ -d\ \|\ bash$ ]]; then
    echo "bcvk stub: unexpected guest command: ${command}" >&2
    exit 99
fi
script="$(base64 -d <<<"${BASH_REMATCH[1]}" | sed "s#/sys/module/zfs#${GUEST_SYS}/module/zfs#g")"
# A login shell's terminal query ahead of the first marker, on the same line.
printf '\033[?2004h'
PATH="${GUEST_PATH}:${PATH}" bash -c "echo $(base64 -w0 <<<"${script}") | base64 -d | bash"
STUB

# The guest. GUEST_STATE is what is-system-running reports; GUEST_MISSING names
# packages rpm does not know. GUEST_SYS stands in for /sys: LOADED_SYS has the
# zfs module in it, UNLOADED_SYS does not.
cat >"${GUEST_DIR}/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    is-system-running)
        echo "${GUEST_STATE:-running}"
        [[ "${GUEST_STATE:-running}" == running ]]
        ;;
    --failed)
        for unit in ${GUEST_FAILED_UNITS:-}; do
            printf '%s loaded failed failed Some unit\n' "${unit}"
        done
        ;;
    *) ;;
esac
STUB
cat >"${GUEST_DIR}/rpm" <<'STUB'
#!/usr/bin/env bash
package="${*: -1}"
for missing in ${GUEST_MISSING:-}; do
    if [[ "${missing}" == "${package}" ]]; then
        echo "package ${package} is not installed"
        exit 1
    fi
done
echo "${package}-2.4.3-1.fc44.x86_64"
STUB
# zpool records that it ran, so the order of the module check before it is
# observable: zpool loads the module on a real system.
cat >"${GUEST_DIR}/zpool" <<'STUB'
#!/usr/bin/env bash
echo "zpool $*" >>"${STUB_CALLS}"
if [[ -n "${GUEST_ZPOOL_BROKEN:-}" ]]; then
    echo "The ZFS modules cannot be auto-loaded."
    exit 1
fi
echo "no pools available"
STUB
cat >"${GUEST_DIR}/zfs" <<'STUB'
#!/usr/bin/env bash
echo "zfs $*" >>"${STUB_CALLS}"
printf 'zfs-2.4.3-1\nzfs-kmod-2.4.3-1\n'
STUB
chmod +x "${STUB_DIR}"/* "${GUEST_DIR}"/*

LOADED_SYS="${TMP_ROOT}/sys-loaded"
UNLOADED_SYS="${TMP_ROOT}/sys-unloaded"
mkdir -p "${LOADED_SYS}/module/zfs" "${UNLOADED_SYS}/module"
echo "2.4.3-1" >"${LOADED_SYS}/module/zfs/version"

# run_boot [VAR=value]... -- [script argument]...
run_boot() {
    local work="${TMP_ROOT}/work"
    local -a envs=()
    while (($# > 0)) && [[ "$1" != "--" ]]; do
        envs+=("$1")
        shift
    done
    shift
    rm -rf -- "${work}"
    : >"${CALLS}"
    : >"${TMP_ROOT}/step-summary"
    env PATH="${STUB_DIR}:${PATH}" \
        STUB_CALLS="${CALLS}" \
        SKOPEO_DIGEST="${DIGEST}" \
        SKOPEO_REVISION="${REVISION}" \
        BCVK_MODE=guest \
        BCVK_CANNED="${CANNED}" \
        GUEST_PATH="${GUEST_DIR}" \
        GUEST_SYS="${LOADED_SYS}" \
        GITHUB_STEP_SUMMARY="${TMP_ROOT}/step-summary" \
        "${envs[@]}" \
        bash "${SCRIPT}" --work "${work}" "$@" 2>&1
}

result() {
    jq -r "$1" "${TMP_ROOT}/work/result.json"
}

bcvk_calls() {
    grep -c '^bcvk ' "${CALLS}"
}

LATEST=(--image "${IMAGE}:latest")

# --- arguments ----------------------------------------------------------------

output="$(run_boot -- --help)"
assert_eq "--help exits 0" "0" "$?"
assert_contains "--help explains the exit codes" "${output}" "Exit status:"

output="$(run_boot --)"
assert_eq "a missing --image is a usage error" "2" "$?"
assert_contains "the missing image is named" "${output}" "--image is required"

output="$(run_boot -- --bogus)"
assert_eq "an unknown argument is a usage error" "2" "$?"

output="$(run_boot -- --image)"
assert_eq "--image with no value is a usage error" "2" "$?"
assert_contains "and says so" "${output}" "--image needs a value"

# --- resolving and pulling ----------------------------------------------------

output="$(run_boot SKOPEO_FAIL=1 -- "${LATEST[@]}")"
assert_eq "an image that does not resolve is a setup error" "2" "$?"
assert_eq "nothing boots when the image does not resolve" "0" "$(bcvk_calls)"

output="$(run_boot SKOPEO_DIGEST=latest -- "${LATEST[@]}")"
assert_eq "an answer that is not a digest is a setup error" "2" "$?"
assert_contains "the bad answer is named" "${output}" "which is not a digest"

output="$(run_boot PODMAN_PULL_FAIL=1 -- "${LATEST[@]}")"
assert_eq "a failed pull is a setup error" "2" "$?"
assert_eq "nothing boots when the pull failed" "0" "$(bcvk_calls)"

# --- a passing boot -------------------------------------------------------------

output="$(run_boot GUEST_STATE=degraded GUEST_FAILED_UNITS=rpm-ostreed-automatic.service -- "${LATEST[@]}")"
assert_eq "the image passes when every check passes" "0" "$?"
assert_eq "result.json records the pass" "true" "$(result .passed)"
assert_eq "every ZFS check runs, the module check before zpool" \
    "boot:finished package:zfs package:kmod-zfs module:zfs zpool:list" \
    "$(result '[.report.checks[].name] | join(" ")')"
assert_eq "the loaded module's version is the module check's detail" "2.4.3-1" \
    "$(result '.report.checks[] | select(.name == "module:zfs") | .detail')"
assert_eq "zpool with no pool to import passes" "pass no pools available" \
    "$(result '.report.checks[] | select(.name == "zpool:list") | "\(.status) \(.detail)"')"
assert_eq "the tag is replaced by the digest it resolved to" \
    "${IMAGE}@${DIGEST}" "$(result .booted)"
assert_contains "bcvk boots the digest, not the tag" \
    "$(grep '^bcvk ' "${CALLS}")" " ${IMAGE}@${DIGEST} -- "
assert_contains "the digest is what is pulled" \
    "$(grep '^podman pull' "${CALLS}")" "${IMAGE}@${DIGEST}"
assert_eq "the revision label is recorded" "${REVISION}" "$(result .revision)"
assert_eq "degraded counts as a finished boot" "pass degraded" \
    "$(result '.report.checks[] | select(.name == "boot:finished") | "\(.status) \(.detail)"')"
assert_eq "failed units are recorded" "rpm-ostreed-automatic.service" \
    "$(result '.report.failed_units | join(" ")')"
# shellcheck disable=SC2016 # the backticks are the summary's own markup
assert_contains "failed units are listed as not judged" "${output}" \
    'Failed units (not judged): `rpm-ostreed-automatic.service`'
assert_eq "the kernel is read back from the guest" "$(uname -r)" "$(result .report.kernel)"
assert_eq "the zfs version is read back after the checks" "zfs-2.4.3-1 zfs-kmod-2.4.3-1" \
    "$(result '.report.zfs_version | join(" ")')"
# OpenZFS loads the module from any zfs or zpool command, so the only commands
# of theirs allowed to run are the ones after module:zfs.
assert_eq "no zfs or zpool command runs before the module check" "zpool list zfs version" \
    "$(grep -E '^(zpool|zfs) ' "${CALLS}" | xargs)"
assert_eq "one boot is enough when it reports" "1" "$(bcvk_calls)"
assert_contains "the VM container is removed after the boot" \
    "$(grep '^podman rm' "${CALLS}")" "--force --ignore aurora-zfs-simple-boot-test-"
assert_contains "the summary reaches the job summary" \
    "$(cat "${TMP_ROOT}/step-summary")" "## Boot test"
# bcvk installs the directory as-is, so a unit without its wants link is a unit
# that never runs, and then the login it exists for fails on a real VM.
units="${TMP_ROOT}/work/units/system"
assert_file_exists "the roothome unit is injected" "${units}/aurora-zfs-simple-roothome.service"
assert_eq "and wanted by default.target" "../aurora-zfs-simple-roothome.service" \
    "$(readlink "${units}/default.target.wants/aurora-zfs-simple-roothome.service")"
assert_eq "sshd is wanted by default.target whether or not the image enables it" \
    "/usr/lib/systemd/system/sshd.service" "$(readlink "${units}/default.target.wants/sshd.service")"
assert_contains "the roothome unit runs before tmpfiles writes the key" \
    "$(cat "${units}/aurora-zfs-simple-roothome.service")" "Before=systemd-tmpfiles-setup.service"
assert_contains "bcvk is handed the units directory by absolute path" \
    "$(grep '^bcvk ' "${CALLS}")" "--systemd-units ${TMP_ROOT}/work/units "
assert_file_exists "the check script the guest ran is kept for the artifact" \
    "${TMP_ROOT}/work/checks/checks.sh"

# Untagged, so the only colon is the registry's port: a script that stripped
# from the last colon of the whole reference would cut the port off.
output="$(run_boot -- --image localhost:5000/aurora-zfs-simple)"
assert_eq "a registry with a port boots" "0" "$?"
assert_eq "a registry port is not taken for a tag" \
    "localhost:5000/aurora-zfs-simple@${DIGEST}" "$(result .booted)"

output="$(run_boot -- --image localhost:5000/aurora-zfs-simple@sha256:0000)"
assert_eq "an image given by digest boots the digest it resolves to" \
    "localhost:5000/aurora-zfs-simple@${DIGEST}" "$(result .booted)"

output="$(run_boot SKOPEO_REVISION= -- "${LATEST[@]}")"
assert_eq "a missing revision label is recorded as unknown" "unknown" "$(result .revision)"

# --- failing checks -------------------------------------------------------------

output="$(run_boot GUEST_SYS="${UNLOADED_SYS}" -- "${LATEST[@]}")"
assert_eq "a module that did not load at boot fails the boot test" "1" "$?"
assert_eq "result.json records the failure" "false" "$(result .passed)"
assert_contains "the failed check is named" "$(result .summary)" "failed checks: module:zfs"
assert_eq "a boot whose checks ran is not retried" "1" "$(bcvk_calls)"
assert_contains "the error line names the booted digest" "${output}" \
    "error: boot test failed for ${IMAGE}@${DIGEST}"

output="$(run_boot GUEST_MISSING=kmod-zfs -- "${LATEST[@]}")"
assert_eq "a missing kmod-zfs fails" "1" "$?"
assert_eq "rpm's own output is kept as the detail" "package kmod-zfs is not installed" \
    "$(result '.report.checks[] | select(.name == "package:kmod-zfs") | .detail')"

output="$(run_boot GUEST_ZPOOL_BROKEN=1 -- "${LATEST[@]}")"
assert_eq "a zpool that cannot reach the module fails" "1" "$?"
assert_contains "zpool:list is named" "$(result .summary)" "zpool:list"

output="$(run_boot GUEST_STATE=starting -- "${LATEST[@]}")"
assert_eq "a boot that never finished starting fails" "1" "$?"
assert_contains "the unfinished boot is named" "$(result .summary)" "boot:finished"

output="$(run_boot GUEST_STATE=maintenance -- "${LATEST[@]}")"
assert_eq "a boot that dropped to maintenance fails" "1" "$?"

# A session that never reports the module check: the check list is the
# script's, not whatever the guest happened to print.
printf '%s\n' \
    "AZS-BOOT-STATE running" \
    "AZS-BOOT-CHECK boot:finished pass running" \
    "AZS-BOOT-CHECK package:zfs pass zfs-2.4.3-1.fc44.x86_64" \
    "AZS-BOOT-CHECK package:kmod-zfs pass kmod-zfs-2.4.3-1.fc44.x86_64" \
    "AZS-BOOT-CHECK zpool:list pass no pools available" \
    "AZS-BOOT-DONE" >"${CANNED}"
output="$(run_boot BCVK_MODE=canned -- "${LATEST[@]}")"
assert_eq "a missing check fails even when every reported one passed" "1" "$?"
assert_contains "the missing check is named" "$(result .summary)" "checks with no result: module:zfs"

# A failed check, then a hang before DONE. The boot reported, so it is the
# answer: a second boot could pass and hide the failure.
printf '%s\n' \
    "AZS-BOOT-STATE running" \
    "AZS-BOOT-CHECK boot:finished pass running" \
    "AZS-BOOT-CHECK package:zfs fail package zfs is not installed" >"${CANNED}"
output="$(run_boot BCVK_MODE=canned BCVK_EXIT=255 -- "${LATEST[@]}")"
assert_eq "a failed check cut off before DONE fails" "1" "$?"
assert_eq "a failed check cut off before DONE is not retried" "1" "$(bcvk_calls)"
assert_contains "the cut-off boot is reported as unfinished" "$(result .summary)" "never reached the point"

# Nothing from the guest at all: the one case a second boot is for.
printf '%s\n' "Error: SSH connection timed out after 240s" >"${CANNED}"
output="$(run_boot BCVK_MODE=canned BCVK_EXIT=1 -- "${LATEST[@]}")"
assert_eq "a boot that never reported fails" "1" "$?"
assert_eq "a boot that never reported is retried once" "2" "$(bcvk_calls)"
assert_eq "both boots are counted" "2" "$(result .attempts)"
assert_eq "every boot's VM container is removed" "2" "$(grep -c '^podman rm' "${CALLS}")"
assert_contains "the failure shows bcvk's own output" "${output}" "SSH connection timed out"

# --- the workflow that runs it ----------------------------------------------------

if ! "${WORKFLOW_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    _fail "the boot-test.yml check requires Python 3 with PyYAML" \
        "install python3-yaml (Debian/Ubuntu) or python3-pyyaml (Fedora)," \
        "or install PyYAML in the interpreter selected by WORKFLOW_PYTHON"
    finish
    exit 1
fi

# YAML 1.1 reads a bare `on` as the boolean true; rename it so jq can read it.
WF_JSON="${TMP_ROOT}/boot-test.json"
if ! "${WORKFLOW_PYTHON}" -B -c '
import json, sys, yaml
with open(sys.argv[1], encoding="utf-8") as handle:
    doc = yaml.safe_load(handle)
if isinstance(doc, dict) and True in doc:
    doc["on"] = doc.pop(True)
json.dump(doc, sys.stdout)
' "${BOOT_WF}" >"${WF_JSON}" 2>"${TMP_ROOT}/wf.err"; then
    _fail "boot-test.yml parses as YAML" "$(cat "${TMP_ROOT}/wf.err")"
    finish
    exit 1
fi

wf() {
    jq -r "$1" <"${WF_JSON}"
}

# auto-issues.yml reports this workflow's runs by its name, and only the ones a
# build's completion started.
assert_eq "the workflow is named as auto-issues.yml watches it" "Boot test" "$(wf '.name')"
assert_eq "it starts on a build's completion or by hand, on nothing else" \
    "workflow_dispatch,workflow_run" "$(wf '.on | keys | join(",")')"
assert_eq "the build it follows is build.yml's" "Build container image" \
    "$(wf '.on.workflow_run.workflows | join(",")')"
assert_eq "and the build's name is build.yml's name:" "Build container image" \
    "$(grep -m1 '^name:' "${REPO_ROOT}/.github/workflows/build.yml" | sed 's/^name:[[:space:]]*//')"
assert_eq "only once that build has completed" "completed" "$(wf '.on.workflow_run.types | join(",")')"

# A pull request's build pushes nothing, so booting `:latest` after it would
# blame that pull request for an image it did not make; a fork's build is not
# ours. Each term is one of the conditions the job needs.
job_if="$(wf '.jobs.boot.if')"
for term in \
    "github.event_name == 'workflow_dispatch'" \
    "github.event.workflow_run.event != 'pull_request'" \
    "github.event.workflow_run.head_branch == github.event.repository.default_branch" \
    "github.event.workflow_run.head_repository.full_name == github.repository" \
    "github.event.workflow_run.conclusion != 'cancelled'"; do
    assert_contains "the job's if: has ${term}" "${job_if}" "${term}"
done

assert_eq "the job's token can only read the repository" '{"contents":"read"}' \
    "$(wf '.jobs.boot.permissions | tojson')"
assert_eq "no step reads a secret" "0" "$(grep -c 'secrets\.' "${BOOT_WF}")"
assert_eq "the checkout keeps no credential" "false" \
    "$(wf '[.jobs.boot.steps[] | select((.uses // "") | startswith("actions/checkout@"))][0].with["persist-credentials"] | tojson')"

boot_step="$(wf '.jobs.boot.steps[] | select(.run // "" | contains("ci/boot-test.sh"))')"
assert_contains "the step boots this repository's :latest" \
    "$(jq -r '.env.IMAGE' <<<"${boot_step}")" \
    "ghcr.io/\${{ github.repository_owner }}/\${{ github.event.repository.name }}:latest"
# shellcheck disable=SC2016 # a shell expansion, compared as literal text
assert_contains "lowercased, as the registry requires" \
    "$(jq -r '.run' <<<"${boot_step}")" '--image "${IMAGE,,}"'

# bcvk runs the image's kernel on the runner; an unverified download would be
# the one unreviewed program in the job.
install_step="$(wf '.jobs.boot.steps[] | select(.run // "" | contains("bcvk/releases"))  | .run')"
assert_contains "the bcvk download is checked against a sha256 before use" \
    "${install_step}" "sha256sum -c -"

timeout_minutes="$(wf '.jobs.boot["timeout-minutes"]')"
boot_seconds="$(grep -E '^BOOT_TIMEOUT_SECONDS=' "${SCRIPT}" | sed -E 's/.*\(\(([0-9]+) \* 60\)\).*/\1/')"
attempts="$(grep -E '^BOOT_ATTEMPTS=' "${SCRIPT}" | cut -d= -f2)"
if [[ "${timeout_minutes}" =~ ^[0-9]+$ && "${boot_seconds}" =~ ^[0-9]+$ && "${attempts}" =~ ^[0-9]+$ ]] &&
    ((timeout_minutes > boot_seconds * attempts)); then
    _pass "the job's timeout outlasts every boot the script may take"
else
    _fail "the job's timeout outlasts every boot the script may take" \
        "timeout-minutes ${timeout_minutes}, ${attempts} boot(s) of ${boot_seconds} minute(s)"
fi

finish
