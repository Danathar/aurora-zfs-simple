#!/usr/bin/env bash
#
# Tests for ci/write-badges.sh.
#
# The script is exercised end to end as a subprocess. Its two external inputs
# are a Containerfile (a plain file, so a fixture is enough) and `skopeo
# inspect` (replaced by a stub earlier on PATH that replays canned JSON and
# records how it was called). Everything else the script touches -- OUT_DIR,
# GITHUB_OUTPUT, IMAGE_REF -- is already environment-driven.
#
# The properties worth pinning down are the ones the script's own comments call
# deliberate: an unreadable input must leave the corresponding badge file
# untouched rather than overwrite it with a guess, and the kernel refs must come
# from the Containerfile's FROM lines so a pin edit is reflected in the badge.

set -uo pipefail

TEST_NAME="test-write-badges"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${REPO_ROOT}/ci/write-badges.sh"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "${WORK_ROOT}"' EXIT

case_dir=""
STATUS=0
STDOUT=""
GITHUB_OUTPUT_CONTENT=""
SKOPEO_CALLS=""

# Fresh sandbox per case: its own OUT_DIR, GITHUB_OUTPUT, Containerfile and
# skopeo stub, so no case can observe another's leftovers.
new_case() {
    local name=$1
    case_dir="${WORK_ROOT}/${name}"
    mkdir -p "${case_dir}/out" "${case_dir}/bin" "${case_dir}/responses" \
        "${case_dir}/authfile"

    cat >"${case_dir}/bin/skopeo" <<'STUB'
#!/usr/bin/env bash
# Stub skopeo: replays a canned inspect payload per image reference.
#
# It also records what an --authfile argument pointed at *while the inspect was
# running*: the path, its mode, and its contents. Checking any of that after
# the script has exited is impossible by design -- the file is meant to be gone
# by then -- so the observation has to happen from inside the call.
printf '%s\n' "$*" >>"${STUB_CALLS}"
ref=""
prev=""
for arg in "$@"; do
    case "${arg}" in
    docker://*) ref="${arg#docker://}" ;;
    esac
    if [[ "${prev}" == "--authfile" ]]; then
        printf '%s\n' "${arg}" >>"${STUB_AUTH_DIR}/path"
        stat -c '%a' "${arg}" >>"${STUB_AUTH_DIR}/mode"
        cat "${arg}" >>"${STUB_AUTH_DIR}/body"
    fi
    prev="${arg}"
done
response="${STUB_RESPONSES}/$(printf '%s' "${ref}" | tr '/:' '__').json"
if [[ -f "${response}" ]]; then
    cat "${response}"
    exit 0
fi
# Mirrors a registry error: no output, non-zero. The script maps this to
# "leave the badge alone".
echo "stub skopeo: no canned response for ${ref}" >&2
exit 1
STUB
    chmod +x "${case_dir}/bin/skopeo"
    : >"${case_dir}/skopeo-calls.log"
    : >"${case_dir}/github-output"
}

# Register the `ostree.linux` label an image reference should report.
stub_kernel() {
    local ref=$1 kernel=$2
    jq -n --arg k "${kernel}" '{Labels: {"ostree.linux": $k}}' \
        >"${case_dir}/responses/$(printf '%s' "${ref}" | tr '/:' '__').json"
}

# Register the Created timestamp an image reference should report.
stub_created() {
    local ref=$1 created=$2
    jq -n --arg c "${created}" '{Created: $c}' \
        >"${case_dir}/responses/$(printf '%s' "${ref}" | tr '/:' '__').json"
}

write_containerfile() {
    cat >"${case_dir}/Containerfile"
}

# Run the script under test with the sandbox's paths and a caller-supplied
# environment. Captures exit status, combined output, GITHUB_OUTPUT and the
# stub's call log into globals the assertions read.
run_badges() {
    local out
    out="$(
        env -i \
            PATH="${case_dir}/bin:${PATH}" \
            HOME="${HOME}" \
            STUB_RESPONSES="${case_dir}/responses" \
            STUB_CALLS="${case_dir}/skopeo-calls.log" \
            STUB_AUTH_DIR="${case_dir}/authfile" \
            OUT_DIR="${case_dir}/out" \
            CONTAINERFILE="${case_dir}/Containerfile" \
            GITHUB_OUTPUT="${case_dir}/github-output" \
            "$@" \
            bash "${SCRIPT}" 2>&1
    )"
    STATUS=$?
    STDOUT="${out}"
    GITHUB_OUTPUT_CONTENT="$(cat "${case_dir}/github-output")"
    SKOPEO_CALLS="$(cat "${case_dir}/skopeo-calls.log")"
}

# A Containerfile with both stages the badge script reads, in the same shape as
# the real one (quoted ARG interpolation included).
standard_containerfile() {
    write_containerfile <<'EOF'
ARG FEDORA_VERSION=44
ARG AURORA_TAG=stable

FROM scratch AS ctx
COPY build_files /

FROM ghcr.io/ublue-os/akmods:coreos-stable-"${FEDORA_VERSION}"-x86_64 AS akmods

FROM ghcr.io/ublue-os/akmods-zfs:coreos-stable-"${FEDORA_VERSION}"-x86_64 AS akmods-zfs

FROM ghcr.io/ublue-os/aurora-dx:stable AS base
EOF
}

AKMODS_REF='ghcr.io/ublue-os/akmods:coreos-stable-44-x86_64'
AKMODS_ZFS_REF='ghcr.io/ublue-os/akmods-zfs:coreos-stable-44-x86_64'
LATEST_REF='ghcr.io/danathar/aurora-zfs-simple:latest'

days_ago() { date -u -d "$1 days ago" +%F; }

# ---------------------------------------------------------------------------
# Kernel refs are resolved from the Containerfile, not reconstructed
# ---------------------------------------------------------------------------

new_case reads-refs-from-containerfile
standard_containerfile
stub_kernel "${AKMODS_REF}" '7.1.4-200.fc44.x86_64'
stub_kernel "${AKMODS_ZFS_REF}" '7.1.4-200.fc44.x86_64'
stub_created "${LATEST_REF}" "$(days_ago 0)T06:04:15.123456789Z"
run_badges IMAGE_REF="${LATEST_REF}"

assert_eq "in-sync run exits 0" 0 "${STATUS}"
assert_contains "resolves the akmods ref with FEDORA_VERSION interpolated" \
    "${STDOUT}" "akmods ref:     ${AKMODS_REF}"
assert_contains "resolves the akmods-zfs ref with FEDORA_VERSION interpolated" \
    "${STDOUT}" "akmods-zfs ref: ${AKMODS_ZFS_REF}"
assert_contains "inspects the quote-stripped, interpolated akmods ref" \
    "${SKOPEO_CALLS}" "docker://${AKMODS_REF}"
assert_contains "inspects the quote-stripped, interpolated akmods-zfs ref" \
    "${SKOPEO_CALLS}" "docker://${AKMODS_ZFS_REF}"

# ---------------------------------------------------------------------------
# Badge 1: matching kernels
# ---------------------------------------------------------------------------

assert_file_exists "writes the akmods badge when both kernels are readable" \
    "${case_dir}/out/akmods-badge.json"
badge="$(cat "${case_dir}/out/akmods-badge.json")"
assert_eq "akmods badge uses the shields endpoint schema" \
    1 "$(jq -r '.schemaVersion' <<<"${badge}")"
assert_eq "akmods badge is labelled openzfs/kernel" \
    "openzfs/kernel" "$(jq -r '.label' <<<"${badge}")"
assert_eq "matching kernels report in sync with the shortened kernel" \
    "in sync (7.1.4-200)" "$(jq -r '.message' <<<"${badge}")"
assert_eq "in-sync badge is green" "brightgreen" "$(jq -r '.color' <<<"${badge}")"
assert_contains "reports akmods_updated=true" "${GITHUB_OUTPUT_CONTENT}" "akmods_updated=true"

# ---------------------------------------------------------------------------
# Badge 2: age of the published :latest image
# ---------------------------------------------------------------------------

assert_file_exists "writes the last-good-build badge when Created is readable" \
    "${case_dir}/out/last-good-build-badge.json"
badge="$(cat "${case_dir}/out/last-good-build-badge.json")"
assert_eq "last-good-build badge is labelled" \
    "last good build" "$(jq -r '.label' <<<"${badge}")"
assert_eq "an image built today reads 'today'" \
    "$(days_ago 0) (today)" "$(jq -r '.message' <<<"${badge}")"
assert_contains "reports last_good_updated=true" "${GITHUB_OUTPUT_CONTENT}" "last_good_updated=true"

new_case age-one-day
standard_containerfile
stub_created "${LATEST_REF}" "$(days_ago 1)T23:59:59Z"
run_badges IMAGE_REF="${LATEST_REF}"
assert_eq "a one-day-old image is singular, not '1 days ago'" \
    "$(days_ago 1) (1 day ago)" \
    "$(jq -r '.message' <"${case_dir}/out/last-good-build-badge.json")"

new_case age-many-days
standard_containerfile
stub_created "${LATEST_REF}" "$(days_ago 9)T00:00:00Z"
run_badges IMAGE_REF="${LATEST_REF}"
assert_eq "an older image reports whole days in UTC" \
    "$(days_ago 9) (9 days ago)" \
    "$(jq -r '.message' <"${case_dir}/out/last-good-build-badge.json")"

# ---------------------------------------------------------------------------
# Badge 1: kernel skew, the failure this repo exists to make visible
# ---------------------------------------------------------------------------

new_case kernel-skew
standard_containerfile
stub_kernel "${AKMODS_REF}" '7.1.5-200.fc44.x86_64'
stub_kernel "${AKMODS_ZFS_REF}" '7.1.3-200.fc44.x86_64'
stub_created "${LATEST_REF}" "$(days_ago 2)T06:00:00Z"
run_badges IMAGE_REF="${LATEST_REF}"

assert_eq "a skewed build still exits 0 so the badge gets published" 0 "${STATUS}"
badge="$(cat "${case_dir}/out/akmods-badge.json")"
assert_eq "skew names both kernels" \
    "blocked: kernel 7.1.5-200, ZFS kmod 7.1.3-200" "$(jq -r '.message' <<<"${badge}")"
assert_eq "skew badge is red" "red" "$(jq -r '.color' <<<"${badge}")"
assert_contains "skew still counts as an akmods update" \
    "${GITHUB_OUTPUT_CONTENT}" "akmods_updated=true"

# ---------------------------------------------------------------------------
# Refusing to guess: unreadable inputs must not overwrite a good badge
# ---------------------------------------------------------------------------

new_case akmods-unreadable
standard_containerfile
# Only the ZFS side answers; the akmods inspect fails like a registry blip.
stub_kernel "${AKMODS_ZFS_REF}" '7.1.4-200.fc44.x86_64'
stub_created "${LATEST_REF}" "$(days_ago 3)T06:00:00Z"
printf 'previous badge\n' >"${case_dir}/out/akmods-badge.json"
run_badges IMAGE_REF="${LATEST_REF}"

assert_eq "one unreadable akmods input is not a hard failure" 0 "${STATUS}"
assert_eq "an unreadable kernel input leaves the existing badge byte-identical" \
    "previous badge" "$(cat "${case_dir}/out/akmods-badge.json")"
assert_contains "reports akmods_updated=false" "${GITHUB_OUTPUT_CONTENT}" "akmods_updated=false"
assert_contains "the last-good-build badge is still written" \
    "$(jq -r '.message' <"${case_dir}/out/last-good-build-badge.json")" "3 days ago"

new_case latest-unreadable
standard_containerfile
stub_kernel "${AKMODS_REF}" '7.1.4-200.fc44.x86_64'
stub_kernel "${AKMODS_ZFS_REF}" '7.1.4-200.fc44.x86_64'
printf 'previous badge\n' >"${case_dir}/out/last-good-build-badge.json"
run_badges IMAGE_REF="${LATEST_REF}"

assert_eq "an unreadable :latest is not a hard failure" 0 "${STATUS}"
assert_eq "an unreadable :latest leaves the existing badge byte-identical" \
    "previous badge" "$(cat "${case_dir}/out/last-good-build-badge.json")"
assert_contains "reports last_good_updated=false" "${GITHUB_OUTPUT_CONTENT}" "last_good_updated=false"
assert_contains "the akmods badge is still written" \
    "$(jq -r '.message' <"${case_dir}/out/akmods-badge.json")" "in sync"

new_case created-unparseable
standard_containerfile
stub_created "${LATEST_REF}" "not-a-timestamp"
run_badges IMAGE_REF="${LATEST_REF}"
assert_file_missing "a Created value date(1) cannot parse writes no badge" \
    "${case_dir}/out/last-good-build-badge.json"
assert_contains "an unparseable Created reports last_good_updated=false" \
    "${GITHUB_OUTPUT_CONTENT}" "last_good_updated=false"

# ---------------------------------------------------------------------------
# Containerfile parsing
# ---------------------------------------------------------------------------

new_case missing-fedora-version
write_containerfile <<'EOF'
FROM ghcr.io/ublue-os/akmods:coreos-stable-44-x86_64 AS akmods
EOF
run_badges IMAGE_REF="${LATEST_REF}"
assert_eq "a Containerfile with no ARG FEDORA_VERSION fails loudly" 1 "${STATUS}"
assert_contains "names the file it could not read the version from" \
    "${STDOUT}" "Could not read ARG FEDORA_VERSION"
assert_file_missing "a failed version read writes no badge" \
    "${case_dir}/out/akmods-badge.json"

new_case fedora-version-override
standard_containerfile
stub_kernel 'ghcr.io/ublue-os/akmods:coreos-stable-45-x86_64' '7.2.0-100.fc45.x86_64'
stub_kernel 'ghcr.io/ublue-os/akmods-zfs:coreos-stable-45-x86_64' '7.2.0-100.fc45.x86_64'
stub_created "${LATEST_REF}" "$(days_ago 0)T06:00:00Z"
run_badges IMAGE_REF="${LATEST_REF}" FEDORA_VERSION=45
assert_contains "FEDORA_VERSION from the environment overrides the Containerfile" \
    "${STDOUT}" "ghcr.io/ublue-os/akmods:coreos-stable-45-x86_64"
assert_eq "the override still produces an in-sync badge" \
    "in sync (7.2.0-100)" "$(jq -r '.message' <"${case_dir}/out/akmods-badge.json")"

new_case pinned-from-line
# The documented outage workaround edits the FROM lines to fully pinned tags.
# The badge must follow the pin rather than keep inspecting floating tags.
write_containerfile <<'EOF'
ARG FEDORA_VERSION=44
FROM ghcr.io/ublue-os/akmods:coreos-stable-44-7.1.3-200.fc44.x86_64 AS akmods
FROM ghcr.io/ublue-os/akmods-zfs:coreos-testing-44-7.1.3-200.fc44.x86_64 AS akmods-zfs
EOF
stub_kernel 'ghcr.io/ublue-os/akmods:coreos-stable-44-7.1.3-200.fc44.x86_64' '7.1.3-200.fc44.x86_64'
stub_kernel 'ghcr.io/ublue-os/akmods-zfs:coreos-testing-44-7.1.3-200.fc44.x86_64' '7.1.3-200.fc44.x86_64'
stub_created "${LATEST_REF}" "$(days_ago 0)T06:00:00Z"
run_badges IMAGE_REF="${LATEST_REF}"
assert_contains "a pinned akmods FROM line is inspected as pinned" \
    "${STDOUT}" "akmods ref:     ghcr.io/ublue-os/akmods:coreos-stable-44-7.1.3-200.fc44.x86_64"
assert_eq "a mixed-stream pin that shares one kernel reads in sync" \
    "in sync (7.1.3-200)" "$(jq -r '.message' <"${case_dir}/out/akmods-badge.json")"

new_case stage-absent
write_containerfile <<'EOF'
ARG FEDORA_VERSION=44
FROM ghcr.io/ublue-os/akmods:coreos-stable-"${FEDORA_VERSION}"-x86_64 AS akmods
EOF
stub_created "${LATEST_REF}" "$(days_ago 0)T06:00:00Z"
run_badges IMAGE_REF="${LATEST_REF}"
assert_eq "a Containerfile with no akmods-zfs stage is not a hard failure" 0 "${STATUS}"
assert_contains "reports the missing stage" "${STDOUT}" "akmods-zfs ref: <not found>"
assert_file_missing "a missing stage writes no akmods badge" \
    "${case_dir}/out/akmods-badge.json"
assert_not_contains "a missing stage skips the upstream inspects entirely" \
    "${SKOPEO_CALLS}" "akmods"

# The repo's own Containerfile must keep the two stage names the badge reads.
# This is the case that fails if a future refactor renames or drops a stage.
new_case real-containerfile
cp "${REPO_ROOT}/Containerfile" "${case_dir}/Containerfile"
fedora="$(sed -n 's/^ARG FEDORA_VERSION=\([0-9][0-9]*\).*/\1/p' "${REPO_ROOT}/Containerfile" | head -1)"
stub_kernel "ghcr.io/ublue-os/akmods:coreos-stable-${fedora}-x86_64" '7.1.4-200.fc44.x86_64'
stub_kernel "ghcr.io/ublue-os/akmods-zfs:coreos-stable-${fedora}-x86_64" '7.1.4-200.fc44.x86_64'
stub_created "${LATEST_REF}" "$(days_ago 0)T06:00:00Z"
run_badges IMAGE_REF="${LATEST_REF}"
assert_eq "the checked-in Containerfile still declares ARG FEDORA_VERSION" 0 "${STATUS}"
assert_not_contains "the checked-in Containerfile still has both akmods stages" \
    "${STDOUT}" "<not found>"
assert_file_exists "the checked-in Containerfile yields an akmods badge" \
    "${case_dir}/out/akmods-badge.json"

# ---------------------------------------------------------------------------
# Image reference construction and credentials
# ---------------------------------------------------------------------------

new_case image-ref-from-parts
standard_containerfile
stub_created 'ghcr.io/danathar/aurora-zfs-simple:latest' "$(days_ago 0)T06:00:00Z"
run_badges GITHUB_REPOSITORY_OWNER=Danathar IMAGE_NAME=Aurora-ZFS-Simple
assert_contains "owner and image name are lowercased into the ghcr reference" \
    "${SKOPEO_CALLS}" "docker://ghcr.io/danathar/aurora-zfs-simple:latest"
assert_file_exists "the derived reference produces a badge" \
    "${case_dir}/out/last-good-build-badge.json"

new_case image-ref-missing-parts
standard_containerfile
run_badges
assert_eq "neither IMAGE_REF nor the owner/name pair is a hard failure" 1 "${STATUS}"
assert_contains "says which variables were required" \
    "${STDOUT}" "GITHUB_REPOSITORY_OWNER or IMAGE_REF required"

# The credential must reach skopeo through a 0600 file, never through the
# command line: /proc/<pid>/cmdline is mode 0444, so an argv token is readable
# by every uid on the runner for as long as the inspect runs, and is printed by
# any `ps` added while debugging a hung one. build.yml already refuses the same
# exposure for the signing key (`--key env://`, tests/test-build-publish.sh).
new_case credentials-passed
standard_containerfile
stub_created "${LATEST_REF}" "$(days_ago 0)T06:00:00Z"
run_badges IMAGE_REF="${LATEST_REF}" REGISTRY_ACTOR=someone REGISTRY_TOKEN=s3cret
assert_contains "the :latest inspect is authenticated through a file" \
    "${SKOPEO_CALLS}" "--authfile "
assert_not_contains "the token never appears in skopeo's argv" \
    "${SKOPEO_CALLS}" "s3cret"
assert_not_contains "and neither does the actor:token pair --creds took" \
    "${SKOPEO_CALLS}" "--creds"
assert_not_contains "credentials are not sent to the public upstream inspects" \
    "$(grep 'akmods' "${case_dir}/skopeo-calls.log")" "--authfile"
assert_eq "the file skopeo is handed is readable only by its owner" \
    "600" "$(cat "${case_dir}/authfile/mode")"
assert_eq "it carries the pair under the reference's registry host" \
    "someone:s3cret" \
    "$(jq -r '.auths["ghcr.io"].auth' "${case_dir}/authfile/body" | base64 -d)"
assert_file_missing "and is removed when the script exits" \
    "$(cat "${case_dir}/authfile/path")"

# A bare `owner/name` is a Docker Hub shorthand, not a host -- keying the entry
# on `owner` would leave skopeo with no credential for the reference it was
# given and silently turn the inspect anonymous.
new_case credentials-bare-reference
standard_containerfile
stub_created 'someone/private-image:latest' "$(days_ago 0)T06:00:00Z"
run_badges IMAGE_REF='someone/private-image:latest' \
    REGISTRY_ACTOR=someone REGISTRY_TOKEN=s3cret
assert_eq "a reference with no registry host is keyed on docker.io" \
    "someone:s3cret" \
    "$(jq -r '.auths["docker.io"].auth' "${case_dir}/authfile/body" | base64 -d)"

new_case credentials-partial
standard_containerfile
stub_created "${LATEST_REF}" "$(days_ago 0)T06:00:00Z"
run_badges IMAGE_REF="${LATEST_REF}" REGISTRY_ACTOR=someone
assert_not_contains "an actor with no token sends no credentials at all" \
    "${SKOPEO_CALLS}" "--authfile"
assert_file_exists "an anonymous inspect still writes the badge" \
    "${case_dir}/out/last-good-build-badge.json"

# ---------------------------------------------------------------------------
# Environment defaults
# ---------------------------------------------------------------------------

new_case no-github-output
standard_containerfile
stub_created "${LATEST_REF}" "$(days_ago 0)T06:00:00Z"
out="$(
    env -i PATH="${case_dir}/bin:${PATH}" HOME="${HOME}" \
        STUB_RESPONSES="${case_dir}/responses" \
        STUB_CALLS="${case_dir}/skopeo-calls.log" \
        OUT_DIR="${case_dir}/out" \
        CONTAINERFILE="${case_dir}/Containerfile" \
        IMAGE_REF="${LATEST_REF}" \
        bash "${SCRIPT}" 2>&1
)"
assert_eq "running outside Actions, with no GITHUB_OUTPUT, still succeeds" 0 "$?"
assert_contains "and still writes the badge" "${out}" "last-good-build-badge.json"

new_case creates-out-dir
standard_containerfile
rm -rf "${case_dir}/out"
stub_created "${LATEST_REF}" "$(days_ago 0)T06:00:00Z"
run_badges IMAGE_REF="${LATEST_REF}"
assert_file_exists "a missing OUT_DIR is created rather than failing" \
    "${case_dir}/out/last-good-build-badge.json"

finish
