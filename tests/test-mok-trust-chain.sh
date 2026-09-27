#!/usr/bin/env bash
#
# Joins docs/SECURITY-AI.md's "Kernel-module signing trust chain (Secure Boot /
# MOK)" section to the build that implements it.
#
# The section was written on 2026-09-26 and described check_module_signatures
# as a name comparison: the certificate's commonName against each module's
# `modinfo -F signer`. That was the check as fc50467 wrote it. 5b6fb34 had
# already replaced it two weeks earlier with a binding to the signing KEY --
# the certificate's serial number and subject key identifier against
# `modinfo -F sig_key` -- because a name is exactly what survives an upstream
# key rotation. The page therefore told a reader that a module signed by a
# different key under the same name would pass the build, which it would not,
# and nothing read the section to notice.
#
# Every literal the section copies out of the build is read back out of the
# build here instead of restated:
#
#   1. the `modinfo -F <field>` set the section names against the set
#      require_module_signed queries, both directions, and every key identifier
#      check_module_signatures reads off the certificate named in the section;
#   2. the certificate path against the cpio member and install destination in
#      build_files/kernel-akmods.sh, post-check.sh's `cert=`, and the operand of
#      the section's own `mokutil --import` command;
#   3. the RPM name against kernel-akmods.sh's `find -name` pattern, and the two
#      images against the FROM lines of the Containerfile stages whose mounts
#      supply the addons RPM and kmod-zfs -- which must be two different stages,
#      since that separation is the section's whole argument;
#   4. the post-check function names against post-check.sh and its main(), and
#      the `*.ko` set against the module loop in check_module_signatures.
#
# Each extractor runs against a fixture with a known answer first, because one
# that quietly returned nothing would make every set comparison below vacuous.

# The awk and sed programs below are single-quoted so that `$0` and the
# backticks in their patterns reach awk/sed rather than the shell. That is the
# point of the quoting, so SC2016 is off for the file rather than repeated.
# shellcheck disable=SC2016

set -uo pipefail

TEST_NAME="test-mok-trust-chain"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

SECURITY_MD="${REPO_ROOT}/docs/SECURITY-AI.md"
KERNEL_AKMODS="${REPO_ROOT}/build_files/kernel-akmods.sh"
POST_CHECK="${REPO_ROOT}/build_files/post-check.sh"
CONTAINERFILE="${REPO_ROOT}/Containerfile"
SECTION_HEADING="## Kernel-module signing trust chain (Secure Boot / MOK)"

for required in "${SECURITY_MD}" "${KERNEL_AKMODS}" "${POST_CHECK}" "${CONTAINERFILE}"; do
    assert_file_exists "${required#"${REPO_ROOT}/"} is present" "${required}"
done

# --- helpers -----------------------------------------------------------------

# The body of a `## ` section of a Markdown file, up to the next `## `.
section_body() {
    awk -v want="$1" '
        $0 == want { inside = 1; next }
        inside && /^## / { exit }
        inside
    ' "$2"
}

# The body of a top-level shell function, from `name() {` to the closing `}`
# in column one.
function_body() {
    awk -v want="$1() {" '
        $0 == want { inside = 1; next }
        inside && /^}/ { exit }
        inside
    ' "$2"
}

# Every inline code span on stdin, one per line. Fenced blocks are skipped: a
# fence line is three backticks and would otherwise pair with a span.
code_spans() {
    awk '/^[ \t]*```/ { fenced = !fenced; next } !fenced' |
        grep -o '`[^`]*`' | tr -d '`'
}

# The fields `modinfo -F <field>` is asked for on stdin. Matched on the command
# rather than on the field's name, so prose that mentions a field without
# spelling the query does not count.
modinfo_fields() {
    grep -oE 'modinfo( -k "[^"]*")? -F [a-z_]+' | awk '{ print $NF }' | sort -u
}

# Sorted, de-duplicated, space-joined, so two sets compare as two strings.
as_set() {
    sort -u | grep -v '^$' | tr '\n' ' ' | sed 's/ $//'
}

require_nonempty() {
    local description=$1 value=$2
    if [[ -n "${value}" ]]; then
        _pass "${description} is not empty"
        return 0
    fi
    _fail "${description} is not empty" "the extractor returned nothing"
    return 1
}

# --- 0. the extractors, against fixtures -------------------------------------

fixture_doc=$'## Kept\n\nSee `a.ko` and `modinfo -F signer`.\n\n```bash\nnot `a span`\n```\n\nThen `modinfo -F sig_key`.\n## Next\n\n`b.ko`\n'
fixture_file="$(mktemp)"
trap 'rm -f "${fixture_file}"' EXIT
printf '%s' "${fixture_doc}" >"${fixture_file}"

assert_eq "fixture: section_body stops at the next heading and code_spans skips fences" \
    "a.ko modinfo -F sig_key modinfo -F signer" \
    "$(section_body "## Kept" "${fixture_file}" | code_spans | as_set)"
assert_eq "fixture: modinfo_fields reads both the -k and the bare form" \
    "sig_key signer" \
    "$(printf '%s\n' 'x=$(modinfo -k "${k}" -F signer "${m}")' '# the vermagic field' 'modinfo -F sig_key m' | modinfo_fields | as_set)"
printf '%s\n' 'f() {' '    for module in one two; do' '    done' '}' 'g() {' '    for module in three; do' '}' >"${fixture_file}"
assert_eq "fixture: function_body stops at the function's closing brace" \
    "    for module in one two; do" \
    "$(function_body f "${fixture_file}" | grep 'for module')"

# --- the section -------------------------------------------------------------

SECTION="$(section_body "${SECTION_HEADING}" "${SECURITY_MD}")"
require_nonempty "docs/SECURITY-AI.md's MOK trust chain section" "${SECTION}" || {
    finish
    exit
}
SECTION_SPANS="$(code_spans <<<"${SECTION}")"

# The bullet that says what the build-time check compares. The field, key
# identifier and module claims are read from it rather than from the whole
# section: the section's opening paragraph also says `spl.ko`/`zfs.ko`, and a
# section-wide match would let the bullet drop one while the intro kept it.
BUILD_BULLET="$(awk '
    /^- \*\*Verification at build time\.\*\*/ { inside = 1; print; next }
    inside && /^(- |$)/ { exit }
    inside
' <<<"${SECTION}")"
require_nonempty "the section's \"Verification at build time\" bullet" "${BUILD_BULLET}"
BUILD_SPANS="$(code_spans <<<"${BUILD_BULLET}")"
BUILD_PROSE="$(tr '\n' ' ' <<<"${BUILD_BULLET}" | tr -d '`*' | sed -e 's/[[:space:]]\+/ /g')"

SIGNATURES_BODY="$(function_body check_module_signatures "${POST_CHECK}")"
REQUIRE_SIGNED_BODY="$(function_body require_module_signed "${POST_CHECK}")"
require_nonempty "post-check.sh's check_module_signatures" "${SIGNATURES_BODY}"
require_nonempty "post-check.sh's require_module_signed" "${REQUIRE_SIGNED_BODY}"

# --- 1. what the build-time check compares -----------------------------------
#
# The claim that was wrong. A field the code queries and the page does not name
# is a check the page hides; a field the page names and the code does not query
# is a check the page invents.

code_fields="$(grep -v '^[[:space:]]*#' <<<"${REQUIRE_SIGNED_BODY}" | modinfo_fields | as_set)"
doc_fields="$(modinfo_fields <<<"${BUILD_SPANS}" | as_set)"
require_nonempty "the modinfo fields require_module_signed queries" "${code_fields}"
assert_eq "the build-time bullet names every modinfo field require_module_signed compares, and no other" \
    "${code_fields}" "${doc_fields}"

# What `sig_key` is compared against. Each identifier check_module_signatures
# reads off the certificate maps to the words a reader would look for; an
# openssl read with no entry in the map fails rather than passing unexamined.
declare -A IDENTIFIER_PHRASE=(
    ["-serial"]="serial number"
    ["subjectKeyIdentifier"]="subject key identifier"
    ["-subject"]="commonName"
)
openssl_reads="$(grep -v '^[[:space:]]*#' <<<"${SIGNATURES_BODY}" |
    grep -oE 'openssl x509 [^|)]*' |
    grep -oE -- '-ext [A-Za-z]+|-(serial|subject)\b' | sed 's/^-ext //' | as_set)"
require_nonempty "the certificate fields check_module_signatures reads" "${openssl_reads}"
for read_field in ${openssl_reads}; do
    phrase="${IDENTIFIER_PHRASE[${read_field}]:-}"
    if [[ -z "${phrase}" ]]; then
        _fail "check_module_signatures's openssl ${read_field} read is classified" \
            "add it to IDENTIFIER_PHRASE with the words the section must use for it"
        continue
    fi
    assert_contains "the build-time bullet says the check reads the certificate's ${phrase} (openssl ${read_field})" \
        "${BUILD_PROSE}" "${phrase}"
done

# --- 2. the certificate path, everywhere it is written -----------------------

doc_cert_paths="$(grep -oE '/etc/pki/[^ `]+\.der' <<<"${SECTION}" | as_set)"
assert_eq "the section names exactly one certificate path" \
    "1" "$(wc -w <<<"${doc_cert_paths}" | tr -d ' ')"

cpio_member="$(grep -E '^[^#]*cpio ' "${KERNEL_AKMODS}" | grep -oE '\./etc/pki/[^ )]+\.der' | sed 's#^\.##')"
install_dest="$(grep -E '^install -D' "${KERNEL_AKMODS}" | awk '{ print $NF }')"
post_check_cert="$(sed -n 's/^[[:space:]]*local cert="\([^"]*\)"$/\1/p' <<<"${SIGNATURES_BODY}")"
mokutil_operand="$(awk '/^[ \t]*```/ { fenced = !fenced; next } fenced' <<<"${SECTION}" |
    sed -n 's/.*mokutil --import[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p')"

require_nonempty "kernel-akmods.sh's cpio member" "${cpio_member}"
require_nonempty "kernel-akmods.sh's install destination" "${install_dest}"
require_nonempty "post-check.sh's cert=" "${post_check_cert}"
require_nonempty "the section's mokutil --import operand" "${mokutil_operand}"
assert_eq "the section's certificate path is the one kernel-akmods.sh extracts from the RPM" \
    "${cpio_member}" "${doc_cert_paths}"
assert_eq "the section's certificate path is where kernel-akmods.sh installs it" \
    "${install_dest}" "${doc_cert_paths}"
assert_eq "the section's certificate path is the one post-check.sh verifies against" \
    "${post_check_cert}" "${doc_cert_paths}"
assert_eq "the section's mokutil command enrolls the certificate the image installs" \
    "${install_dest}" "${mokutil_operand}"

# --- 3. where the certificate and the modules come from ----------------------

addons_rpm="$(sed -n "s/.*-name '\([a-z0-9-]*\)-\*\.rpm'.*/\1/p" "${KERNEL_AKMODS}")"
require_nonempty "kernel-akmods.sh's addons RPM pattern" "${addons_rpm}"
assert_eq "the section names the RPM kernel-akmods.sh extracts the certificate from, and no other ublue-os RPM" \
    "${addons_rpm}" "$(grep -E '^ublue-os-[a-z-]+$' <<<"${SECTION_SPANS}" | as_set)"

# The stage a mount comes from, by its source directory, and that stage's image
# with the tag dropped.
stage_for_src() {
    grep -oE "from=[a-z0-9-]+,src=$1," "${CONTAINERFILE}" | sed 's/^from=//; s/,src=.*//' | sort -u
}
image_for_stage() {
    awk -v stage="$1" '$1 == "FROM" && $NF == stage { print $2 }' "${CONTAINERFILE}" | sed 's/:.*//'
}

addons_stage="$(stage_for_src /rpms/ublue-os)"
zfs_stage="$(stage_for_src /rpms/kmods/zfs)"
require_nonempty "the Containerfile stage mounting /rpms/ublue-os" "${addons_stage}"
require_nonempty "the Containerfile stage mounting /rpms/kmods/zfs" "${zfs_stage}"
if [[ -n "${addons_stage}" && "${addons_stage}" == "${zfs_stage}" ]]; then
    _fail "the certificate and kmod-zfs come from different stages, as the section argues" \
        "both mounts come from ${addons_stage}; the section's 'separate image' claim no longer holds"
else
    _pass "the certificate and kmod-zfs come from different stages, as the section argues"
fi

addons_image="$(image_for_stage "${addons_stage}")"
zfs_image="$(image_for_stage "${zfs_stage}")"
require_nonempty "the FROM image of stage ${addons_stage}" "${addons_image}"
require_nonempty "the FROM image of stage ${zfs_stage}" "${zfs_image}"
assert_contains "the section names the image the addons RPM is mounted from" \
    "${SECTION_SPANS}" "${addons_image}"
assert_contains "the section names the image kmod-zfs is mounted from" \
    "${SECTION_SPANS}" "${zfs_image##*/}"
assert_eq "every ghcr.io image the section names is the addons RPM's" \
    "${addons_image}" "$(grep -E '^ghcr\.io/' <<<"${SECTION_SPANS}" | as_set)"

# --- 4. the check the section cites, and what it checks ----------------------

main_body="$(function_body main "${POST_CHECK}")"
doc_checks="$(grep -E '^check_[a-z_]+$' <<<"${SECTION_SPANS}" | as_set)"
require_nonempty "the post-check functions the section cites" "${doc_checks}"
for check in ${doc_checks}; do
    if grep -qx "${check}() {" "${POST_CHECK}"; then
        _pass "${check} is defined in post-check.sh"
    else
        _fail "${check} is defined in post-check.sh" "the section cites a function that does not exist"
    fi
    if grep -qx "[[:space:]]*${check}" <<<"${main_body}"; then
        _pass "${check} runs from post-check.sh's main()"
    else
        _fail "${check} runs from post-check.sh's main()" "defined but never called, so it gates nothing"
    fi
done

code_modules="$(sed -n 's/^[[:space:]]*for module in \(.*\); do$/\1/p' <<<"${SIGNATURES_BODY}" |
    tr ' ' '\n' | sed 's/$/.ko/' | as_set)"
require_nonempty "check_module_signatures's module loop" "${code_modules}"
assert_eq "the build-time bullet's signed-module set is the set check_module_signatures checks" \
    "${code_modules}" "$(tr '/' '\n' <<<"${BUILD_SPANS}" | grep -E '^[a-z0-9_]+\.ko$' | as_set)"

finish
