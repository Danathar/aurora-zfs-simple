#!/usr/bin/env bash
#
# Joins README.md to the machine it describes.
#
# README.md is the page a user reads before rebasing a machine onto this image.
# Several tests read it as a *source* — test-docs-paths.sh checks that the paths
# it names exist, test-signing-key.sh its install, policy and switch commands,
# test-renovate.sh its Chunkah pin paragraph, test-quality-docs.sh the build
# badge, test-agent-prompts.sh the meaning of `blocked` — and not one of them
# reads the rest of it as a *subject*. Every claim they do not happen to quote
# was unchecked.
#
# It had already drifted, by omission. "## Build-Time Validation" lists what
# `build_files/post-check.sh` verifies, and the list stopped at the six checks
# the script had before fc50467 added `check_module_signatures` — the check that
# `spl.ko` and `zfs.ko` are signed by the certificate the image installs, whose
# failure is otherwise only visible after the rebase, as a Secure Boot host that
# will not load zfs.ko. A reader deciding whether this image is safe to enroll a
# MOK key for was told the list was complete.
#
# What is checked here, recomputed from the tree rather than restated:
#
#   * the post-check list against `main()` in `build_files/post-check.sh`: a
#     manifest ties every bullet to the check function that implements it and to
#     a line in that function's body, every check `main()` calls must be claimed
#     by a bullet, and every bullet must be claimed by a check — so a new check
#     that the page does not mention fails, which is the failure above;
#   * the script's own "Execution order" header against `main()`;
#   * "What It Uses" against the `Containerfile`'s `FROM` repositories and the
#     workflow's `CHUNKAH_IMAGE`, in both directions;
#   * the `ARG` snippets under "Important Design Detail" against the
#     `Containerfile`'s lines, and the Fedora guard it says exists;
#   * the kernel-pin example against the stages it would replace: the same
#     repositories and stage names, one tag shared by both lines, of the shape
#     the unpinned tag takes once a kernel is spliced in;
#   * the weekly schedule sentence against `build.yml`'s cron;
#   * the badge counts and the build workflow's name against the badges and
#     `build.yml`, and the step name and Chunkah example tag the build section
#     quotes against `build.yml`;
#   * the "Repository Layout" block against the tree, in the direction
#     test-docs-paths.sh does not check: for the directories the block
#     enumerates file by file — `.github/workflows/`, `build_files/`, `ci/`
#     and `docs/` — every tracked entry there has a line.
#
# The `nvidia-legacy` branch and tag, the upstream discussion link and the
# disclaimer are claims about things outside this checkout, and are left alone.
#
# The bullet reader runs against a fixture first. Markdown wraps, so a bullet
# is a first line plus indented continuation lines; a reader that kept only the
# first line would pass every "matches one bullet" assertion on a truncated
# phrase and fail nothing.

# Most of what this file matches is shell source and Markdown code spans —
# `${KERNEL}` as post-check.sh writes it, a backtick class for a code span —
# which has to reach the matcher unexpanded, so the single quotes are the point
# and SC2016 is off for the file rather than repeated above each.
# shellcheck disable=SC2016

set -uo pipefail

TEST_NAME="test-readme"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

README_MD="${REPO_ROOT}/README.md"
POST_CHECK="${REPO_ROOT}/build_files/post-check.sh"
CONTAINERFILE="${REPO_ROOT}/Containerfile"
BUILD_YML="${REPO_ROOT}/.github/workflows/build.yml"

for required in "${README_MD}" "${POST_CHECK}" "${CONTAINERFILE}" "${BUILD_YML}"; do
    assert_file_exists "$(basename "${required}") is present" "${required}"
done
if [[ ! -f "${README_MD}" || ! -f "${POST_CHECK}" || ! -f "${CONTAINERFILE}" || ! -f "${BUILD_YML}" ]]; then
    finish
    exit 1
fi

# --- helpers ------------------------------------------------------------------

# The body of a `## ` section of a Markdown file, up to the next `## `.
section_body() {
    awk -v want="$1" '
        $0 == want { inside = 1; next }
        inside && /^## / { exit }
        inside
    ' "$2"
}

# One line per `- ` bullet of the list that follows the line equal to $1 in the
# text on stdin, continuation lines folded in and runs of whitespace squashed.
# The list ends at the first line that is neither a bullet nor indented.
bullets_after() {
    awk -v lead="$1" '
        !started && $0 == lead { started = 1; next }
        !started { next }
        /^- / {
            if (item != "") print item
            item = substr($0, 3); inlist = 1; next
        }
        inlist && /^[ \t]+[^ \t]/ { sub(/^[ \t]+/, ""); item = item " " $0; next }
        inlist { exit }
        END { if (item != "") print item }
    ' | sed -E 's/[[:space:]]+/ /g; s/ $//'
}

# The body of a shell function in $2, from `name() {` to the closing `}` at
# column 0, with whole-line comments removed so a comment cannot satisfy a
# search for code.
function_body() {
    awk -v name="$1" '
        $0 == name "() {" { inside = 1; next }
        inside && /^}/ { exit }
        inside && !/^[ \t]*#/
    ' "$2"
}

# The contents of the first fenced block in the text on stdin.
first_fence() {
    awk '
        /^```/ { fence++; next }
        fence == 1 { print }
        fence == 2 { exit }
    '
}

# Number words as the README writes them.
word_to_number() {
    case "${1,,}" in
        one) echo 1 ;; two) echo 2 ;; three) echo 3 ;; four) echo 4 ;;
        five) echo 5 ;; six) echo 6 ;; seven) echo 7 ;; eight) echo 8 ;;
        *) echo "unparsed:$1" ;;
    esac
}

# --- 0. the bullet reader, against a fixture ----------------------------------

fixture_bullets="$(bullets_after 'The list:' <<'EOF'
prose before
The list:

- first item
- second item that wraps
  onto a second line
  and a third
- third item

A paragraph after, which is not a bullet.
- a later list that is not this one
EOF
)"
assert_eq "the bullet reader folds wrapped bullets and stops at the list's end" \
    "first item|second item that wraps onto a second line and a third|third item" \
    "$(paste -sd'|' <<<"${fixture_bullets}")"

# --- 1. the post-check list against main() ------------------------------------

VALIDATION="$(section_body '## Build-Time Validation' "${README_MD}")"
if [[ -z "${VALIDATION}" ]]; then
    _fail "README.md still has a Build-Time Validation section" "the heading is gone"
else
    _pass "README.md still has a Build-Time Validation section"
fi

POST_CHECK_BULLETS="$(bullets_after 'The post-check verifies:' <<<"${VALIDATION}")"
bullet_count=0
[[ -n "${POST_CHECK_BULLETS}" ]] && bullet_count=$(wc -l <<<"${POST_CHECK_BULLETS}")
if [[ "${bullet_count}" -gt 0 ]]; then
    _pass "the section lists what the post-check verifies (${bullet_count} bullets)"
else
    _fail "the section lists what the post-check verifies" \
        "no bullets after 'The post-check verifies:'"
fi

MAIN_CHECKS="$(function_body main "${POST_CHECK}" |
    sed -nE 's/^[[:space:]]+(check_[a-z_]+)[[:space:]]*$/\1/p')"
HEADER_ORDER="$(sed -nE 's/^# [0-9]+\. (check_[a-z_]+)$/\1/p' "${POST_CHECK}")"

if [[ -n "${MAIN_CHECKS}" ]]; then
    _pass "main() in post-check.sh calls check functions: $(paste -sd' ' <<<"${MAIN_CHECKS}")"
else
    _fail "main() in post-check.sh calls check functions" "none were read out of main()"
fi
assert_eq "post-check.sh's Execution order header is the order main() runs the checks in" \
    "${MAIN_CHECKS}" "${HEADER_ORDER}"

# function | ERE matched against the flattened bullets | fixed string that has
#            to be in that function's (comment-free) body
#
# A function written `check>helper` is the check the bullet is tied to and the
# helper whose body carries the needle, for a claim the check delegates.
#
# Each row says: this bullet is a claim this function makes good. A bullet may
# be claimed by more than one function — the "are present" bullet lists
# packages and userspace files, and two checks own those — but every bullet
# needs one, and every check main() runs needs one.
POST_CHECK_CLAIMS=(
    'check_kernel_tree|exactly one kernel module tree exists under /usr/lib/modules|find /usr/lib/modules -maxdepth 1 -mindepth 1 -type d'
    'check_kernel_tree|kernel RPM and module tree agree on the selected kernel version|%{VERSION}-%{RELEASE}.%{ARCH}'
    'check_zfs_packages|^ZFS RPMs, userspace commands,|require_rpm "kmod-zfs"'
    'check_zfs_userspace|^ZFS RPMs, userspace commands, shared libraries, systemd units, udev rules, and module-load config are present$|require_ldd_resolved'
    'check_zfs_userspace|systemd units, udev rules|/usr/lib/udev/rules.d/90-zfs.rules'
    'check_zfs_userspace|module-load config|/usr/lib/modules-load.d/zfs.conf'
    'check_zfs_packages|one OpenZFS version/release|require_single_rpm_version "ZFS"'
    'check_zfs_modules|^spl.ko and zfs.ko exist for the selected kernel$|require_glob "spl kernel module"'
    'check_zfs_modules|modinfo -k <kernel> spl and modinfo -k <kernel> zfs work after depmod|depmod -a "${KERNEL}"'
    'check_zfs_modules|module vermagic matches the selected kernel|-F vermagic'
    'check_module_signatures|signed by the certificate the image installs|require_module_signed "${KERNEL}"'
    'check_initramfs|initramfs contains zfs.ko and spl.ko|lsinitrd'
    'check_rpm_payloads|RPM payload files are not missing or content-modified|verify_rpm_payload "kmod-zfs"'
    'check_rpm_payloads>verify_rpm_payload|ownership/group/timestamp normalization is ignored$|payload_flags="${flags:0:5}${flags:8:1}"'
)

# Backticks are Markdown here, not part of the claim.
FLAT_BULLETS="$(tr -d '`' <<<"${POST_CHECK_BULLETS}")"

declare -A claimed_check=()
declare -A claimed_bullet=()
for row in "${POST_CHECK_CLAIMS[@]}"; do
    IFS='|' read -r fn pattern needle <<<"${row}"
    body_fn="${fn#*>}"
    fn="${fn%%>*}"
    claimed_check["${fn}"]=1

    if ! grep -qxF "${fn}" <<<"${MAIN_CHECKS}"; then
        _fail "the claim manifest names only checks main() runs: ${fn}" \
            "${fn} is not called from main(); drop its rows or restore the call"
        continue
    fi

    matches="$(grep -nE -- "${pattern}" <<<"${FLAT_BULLETS}" || true)"
    match_count=0
    [[ -n "${matches}" ]] && match_count=$(wc -l <<<"${matches}")
    if [[ "${match_count}" -eq 1 ]]; then
        _pass "README.md's post-check list states it: ${pattern}"
        claimed_bullet["${matches%%:*}"]=1
    else
        _fail "README.md's post-check list states it exactly once: ${pattern}" \
            "matched ${match_count} bullet(s)"
    fi

    body="$(function_body "${body_fn}" "${POST_CHECK}")"
    assert_contains "and ${body_fn} does it: ${needle}" "${body}" "${needle}"
done

while IFS= read -r check; do
    [[ -z "${check}" ]] && continue
    if [[ -n "${claimed_check[${check}]:-}" ]]; then
        _pass "README.md's post-check list accounts for ${check}"
    else
        _fail "README.md's post-check list accounts for ${check}" \
            "main() runs ${check} and no bullet in 'The post-check verifies:' is tied to it" \
            "add a bullet saying what it verifies, and a row to POST_CHECK_CLAIMS"
    fi
done <<<"${MAIN_CHECKS}"

line_no=0
while IFS= read -r bullet; do
    line_no=$((line_no + 1))
    if [[ -n "${claimed_bullet[${line_no}]:-}" ]]; then
        _pass "post-check bullet ${line_no} is tied to a check"
    else
        _fail "post-check bullet ${line_no} is tied to a check" \
            "no check in post-check.sh's main() is recorded as verifying: ${bullet}"
    fi
done <<<"${FLAT_BULLETS}"

# The signature bullet names the certificate by path; it has to be the one the
# check reads, or the reader enrolls a different key than the modules carry.
signature_bullet="$(grep -E 'signed by the certificate' <<<"${POST_CHECK_BULLETS}" || true)"
bullet_cert="$(grep -oE '`/etc/pki/[^`]+`' <<<"${signature_bullet}" | tr -d '`')"
script_cert="$(function_body check_module_signatures "${POST_CHECK}" |
    sed -nE 's/^[[:space:]]+local cert="([^"]+)"$/\1/p')"
if [[ -n "${script_cert}" ]]; then
    _pass "check_module_signatures names its certificate: ${script_cert}"
else
    _fail "check_module_signatures names its certificate" "no local cert=\"...\" line"
fi
assert_eq "the signature bullet names the certificate the check reads" \
    "${script_cert}" "${bullet_cert}"

# --- 2. What It Uses against the Containerfile and the Chunkah pin ------------

USES="$(section_body '## What It Uses' "${README_MD}")"
uses_images="$(grep -oE '`[a-z0-9.-]+\.io/[^`]+`' <<<"${USES}" | tr -d '`' |
    grep -v '^quay.io/coreos/chunkah' | sort -u)"

cf_arg() {
    sed -nE "s/^ARG $1=(.*)$/\1/p" "${CONTAINERFILE}" | head -1
}
AURORA_IMAGE="$(cf_arg AURORA_IMAGE)"
AURORA_TAG="$(cf_arg AURORA_TAG)"
FEDORA_VERSION="$(cf_arg FEDORA_VERSION)"

# Every image the Containerfile pulls, as the README would write it: the base
# with its tag resolved, the akmods stages as bare repositories (their tags are
# templated on FEDORA_VERSION, which the section does not restate).
cf_images="$(
    printf '%s:%s\n' "${AURORA_IMAGE}" "${AURORA_TAG}"
    sed -nE 's/^FROM (ghcr\.io\/[^:]+):.* AS akmods(-zfs)?$/\1/p' "${CONTAINERFILE}"
)"
cf_images="$(sort -u <<<"${cf_images}")"
if [[ "$(wc -l <<<"${cf_images}")" -eq 3 ]]; then
    _pass "the Containerfile's pulled images were read: $(paste -sd' ' <<<"${cf_images}")"
else
    _fail "the Containerfile's pulled images were read" "got: ${cf_images}"
fi
assert_eq "What It Uses names exactly the images the Containerfile pulls" \
    "${cf_images}" "${uses_images}"

assert_contains "What It Uses gives the base image as the base image" \
    "$(grep -F 'base image:' <<<"${USES}")" "\`${AURORA_IMAGE}:${AURORA_TAG}\`"
assert_contains "and the kernel RPMs as the akmods stage" \
    "$(grep -F 'kernel RPMs:' <<<"${USES}")" \
    "\`$(sed -nE 's/^FROM (ghcr\.io\/[^:]+):.* AS akmods$/\1/p' "${CONTAINERFILE}")\`"
assert_contains "and the ZFS RPMs as the akmods-zfs stage" \
    "$(grep -F 'ZFS RPMs:' <<<"${USES}")" \
    "\`$(sed -nE 's/^FROM (ghcr\.io\/[^:]+):.* AS akmods-zfs$/\1/p' "${CONTAINERFILE}")\`"

CHUNKAH_IMAGE="$(sed -nE 's/^[[:space:]]+CHUNKAH_IMAGE:[[:space:]]*([^[:space:]#]+).*$/\1/p' "${BUILD_YML}")"
if [[ "$(wc -l <<<"${CHUNKAH_IMAGE}")" -eq 1 && -n "${CHUNKAH_IMAGE}" ]]; then
    _pass "build.yml sets CHUNKAH_IMAGE once: ${CHUNKAH_IMAGE}"
else
    _fail "build.yml sets CHUNKAH_IMAGE once" "got: ${CHUNKAH_IMAGE}"
fi
chunkah_repo="${CHUNKAH_IMAGE%%:*}"
assert_contains "What It Uses links the upstream of the image build.yml runs" \
    "$(grep -F 'content-based image layering' <<<"${USES}")" \
    "https://github.com/${chunkah_repo#quay.io/}"

# The one statement about what is absent: no NVIDIA input anywhere it pulls.
assert_not_contains "and, as it says, no NVIDIA image among them" \
    "${cf_images,,}" "nvidia"

# --- 3. Important Design Detail against the Containerfile ---------------------

DESIGN="$(section_body '## Important Design Detail' "${README_MD}")"
design_args="$(awk '/^```Dockerfile/ { f = 1; next } /^```/ { f = 0 } f' <<<"${DESIGN}")"
if [[ -n "${design_args}" ]]; then
    _pass "Important Design Detail quotes Containerfile lines"
else
    _fail "Important Design Detail quotes Containerfile lines" "no Dockerfile fence found"
fi
while IFS= read -r quoted; do
    [[ -z "${quoted}" ]] && continue
    if grep -qxF -- "${quoted}" "${CONTAINERFILE}"; then
        _pass "the Containerfile has the line README.md quotes: ${quoted}"
    else
        _fail "the Containerfile has the line README.md quotes: ${quoted}" \
            "no line in the Containerfile reads exactly that"
    fi
done <<<"${design_args}"

assert_contains "README.md says the Containerfile guards the base's Fedora release" \
    "$(tr '\n' ' ' <<<"${DESIGN}")" "has a guard that fails the build if the stable base"
assert_eq "and the Containerfile compares the base's %fedora to FEDORA_VERSION" "1" \
    "$(grep -cF 'test "$(rpm -E %fedora)" = "${FEDORA_VERSION}"' "${CONTAINERFILE}")"

# --- 4. the kernel pin example against the stages it replaces -----------------

PIN="$(section_body '## Pinning The Kernel If Needed' "${README_MD}")"
pin_lines="$(awk '/^```Dockerfile/ { f = 1; next } /^```/ { f = 0 } f' <<<"${PIN}")"
cf_akmods_lines="$(grep -E '^FROM ghcr\.io/.* AS akmods(-zfs)?$' "${CONTAINERFILE}")"

stage_of() { sed -nE 's/^FROM [^ ]+ AS ([a-z-]+)$/\1/p'; }
repo_of() { sed -nE 's/^FROM ([^:]+):.*$/\1/p'; }
tag_of() { sed -nE 's/^FROM [^:]+:([^ ]+) AS .*$/\1/p'; }

assert_eq "the pin example rewrites exactly the akmods stages, by name" \
    "$(stage_of <<<"${cf_akmods_lines}" | sort)" "$(stage_of <<<"${pin_lines}" | sort)"
assert_eq "and from the same repositories" \
    "$(repo_of <<<"${cf_akmods_lines}" | sort)" "$(repo_of <<<"${pin_lines}" | sort)"

pin_tags="$(tag_of <<<"${pin_lines}" | sort -u)"
assert_eq "both pinned lines carry one tag, as 'Pin both inputs together' says" \
    "1" "$(grep -c . <<<"${pin_tags}")"

# The unpinned tag is coreos-stable-"${FEDORA_VERSION}"-x86_64; a pinned one is
# that with the full kernel release spliced in before the arch.
cf_tag_template="$(tag_of <<<"${cf_akmods_lines}" | sort -u | tr -d '"')"
assert_eq "the Containerfile's two akmods stages share one tag template" \
    'coreos-stable-${FEDORA_VERSION}-x86_64' "${cf_tag_template}"
tag_shape="^coreos-stable-${FEDORA_VERSION}-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.fc${FEDORA_VERSION}\.x86_64$"
if [[ "${pin_tags}" =~ ${tag_shape} ]]; then
    _pass "the pinned tag is the template with a Fedora ${FEDORA_VERSION} kernel spliced in: ${pin_tags}"
else
    _fail "the pinned tag is the template with a Fedora ${FEDORA_VERSION} kernel spliced in" \
        "expected to match: ${tag_shape}" "actual: ${pin_tags}"
fi

# --- 5. the schedule sentence against build.yml's cron ------------------------

crons="$(sed -nE "s/^[[:space:]]+- cron: '([^']+)'.*$/\1/p" "${BUILD_YML}")"
assert_eq "build.yml has one schedule" "1" "$(grep -c . <<<"${crons}")"
read -r cron_min cron_hour cron_dom cron_mon cron_dow <<<"${crons}"
days=(Sunday Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
assert_eq "the cron fires on one weekday every week (day-of-month and month are *)" \
    "* *" "${cron_dom} ${cron_mon}"
if [[ "${cron_dow}" =~ ^[0-7]$ && "${cron_min}" =~ ^[0-9]+$ && "${cron_hour}" =~ ^[0-9]+$ ]]; then
    schedule_phrase="$(printf 'weekly on %s morning at %02d:%02d UTC' \
        "${days[cron_dow]}" "$((10#${cron_hour}))" "$((10#${cron_min}))")"
    assert_contains "README.md states the schedule build.yml runs on" \
        "$(tr '\n' ' ' <"${README_MD}" | sed -E 's/[[:space:]]+/ /g')" "${schedule_phrase}"
else
    _fail "the cron's fields are plain numbers" "got: ${crons}"
fi

# --- 6. badges and the build section against build.yml ------------------------

badge_lines="$(grep -E '^\[!\[' "${README_MD}")"
workflow_badges="$(grep -cE 'actions/workflows/[a-z-]+\.yml/badge\.svg' <<<"${badge_lines}")"
endpoint_badges="$(grep -cF 'img.shields.io/endpoint' <<<"${badge_lines}")"
intro="$(tr '\n' ' ' <"${README_MD}" | sed -E 's/[[:space:]]+/ /g')"

said_workflow="$(grep -oE 'The [a-z]+ workflow badges' <<<"${intro}" | awk '{ print $2 }')"
assert_eq "'The N workflow badges' counts the workflow badges" \
    "${workflow_badges}" "$(word_to_number "${said_workflow}")"
said_beside="$(grep -oE 'the [a-z]+ badges beside it' <<<"${intro}" | awk '{ print $2 }')"
assert_eq "'the N badges beside it' counts the status-branch badges" \
    "${endpoint_badges}" "$(word_to_number "${said_beside}")"

while IFS= read -r wf; do
    [[ -z "${wf}" ]] && continue
    assert_file_exists "the badged workflow exists: ${wf}" "${REPO_ROOT}/.github/workflows/${wf}"
done < <(grep -oE 'actions/workflows/[a-z-]+\.yml/badge' <<<"${badge_lines}" |
    sed -E 's#actions/workflows/(.*)/badge#\1#')

build_name="$(sed -nE 's/^name: (.*)$/\1/p' "${BUILD_YML}" | head -1)"
assert_contains "the build badge's description names build.yml's workflow" \
    "${intro}" "**${build_name}** is the one that decides"
assert_contains "and its alt text does too" \
    "$(sed -n 3p "${README_MD}")" "[![${build_name}](https://github.com/"

BUILD="$(section_body '## Build And Publish' "${README_MD}")"
assert_contains "Build And Publish quotes the Chunkah pin build.yml carries" \
    "${BUILD}" "\`${CHUNKAH_IMAGE}\`"
step_names="$(sed -nE 's/^[[:space:]]+- name: (.*)$/\1/p' "${BUILD_YML}")"
quoted_steps="$(grep -oE '`[A-Z][a-z]+( [a-z]+)+`' <<<"${BUILD}" | tr -d '`')"
if [[ -n "${quoted_steps}" ]]; then
    _pass "Build And Publish quotes build.yml step names"
else
    _fail "Build And Publish quotes build.yml step names" "no backticked step name was read"
fi
while IFS= read -r step; do
    [[ -z "${step}" ]] && continue
    if grep -qxF -- "${step}" <<<"${step_names}"; then
        _pass "Build And Publish names a real build.yml step: ${step}"
    else
        _fail "Build And Publish names a real build.yml step: ${step}" \
            "build.yml has no step with that name"
    fi
done <<<"${quoted_steps}"
assert_contains "the manual run it shows is one build.yml accepts" \
    "$(sed -n '/^on:/,/^[a-z]/p' "${BUILD_YML}")" "workflow_dispatch:"

# --- 7. Repository Layout, the direction test-docs-paths.sh does not check ---

LAYOUT="$(section_body '## Repository Layout' "${README_MD}" | first_fence)"
layout_paths="$(awk 'NF { print $1 }' <<<"${LAYOUT}")"
if [[ -n "${layout_paths}" ]]; then
    _pass "the Repository Layout block was read ($(wc -l <<<"${layout_paths}") entries)"
else
    _fail "the Repository Layout block was read" "no entries"
fi

# The directories the block enumerates one entry at a time. `tests/` and
# `.github/` itself are summarised by a line each, so they are not held to it.
for dir in .github/workflows build_files ci docs; do
    tracked="$(cd "${REPO_ROOT}" && git ls-files -- "${dir}/" |
        sed -E "s#^(${dir}/[^/]+/).*#\1#" | sort -u)"
    listed="$(grep -E "^${dir//./\\.}/[^/]+/?$" <<<"${layout_paths}" | sort -u)"
    missing="$(comm -23 <(echo "${tracked}") <(echo "${listed}") | paste -sd' ')"
    if [[ -n "${tracked}" && -z "${missing}" ]]; then
        _pass "Repository Layout lists every tracked entry of ${dir}/"
    else
        _fail "Repository Layout lists every tracked entry of ${dir}/" \
            "tracked but not listed: ${missing:-<${dir}/ has no tracked entries>}"
    fi
done

finish
