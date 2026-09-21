#!/usr/bin/env bash
#
# Joins cosign.pub -- the signature trust anchor -- to the machine that produces
# signatures and to the instructions that tell a consumer to trust it.
#
# Before this file nothing opened the key. `grep -rF cosign.pub tests/` returned
# a dozen hits and not one of them read a byte of it: tests/test-claude-settings.sh
# uses the path as the payload an output redirection would truncate
# (`git diff HEAD >cosign.pub`), and tests/test-risk-tiers.sh classifies the path
# through docs/risk-tiers.md's table. The file's contents, and the README section
# that tells a user to install them into a host signature policy, were checked by
# nothing.
#
# That is the worst place in this repository to have no test. docs/risk-tiers.md
# puts `cosign.pub` in tier 3 -- "a wrong change ships signed bytes, or a host
# that will not boot" -- and docs/SECURITY-AI.md ranks the key material above
# every other secret here. The failure modes are quiet ones:
#
#   * the private half committed by accident, which is unrecoverable once
#     pushed and looks like an ordinary file in a diff;
#   * the public half replaced or truncated, which no build notices because
#     `build.yml` signs with `env://COSIGN_PRIVATE_KEY` and never reads this
#     file -- only the nightly re-verification and a consumer's host would, and
#     the nightly one is stubbed in tests/test-nightly-compliance.sh;
#   * a rename or an owner change that leaves README.md's policy entry pinning
#     a repository the workflow no longer publishes to, which fails *open*: a
#     host with a stale `signedIdentity` entry accepts nothing, or accepts the
#     wrong thing, and the user finds out at `bootc upgrade`.
#
# So the key's own bytes are decoded rather than described, the private half is
# hunted for rather than assumed absent, and every instruction that names the
# key is held against the workflow that publishes the image. The published
# reference is derived once, from the repository slug README.md's own badges
# link to, and the derivation is grounded in `build.yml`'s `IMAGE_REGISTRY` and
# `IMAGE_NAME` expressions -- so a fork that renames the repository moves every
# assertion below with it rather than failing on this repository's name.
#
# Scope: cosign.pub, the absence of its private counterpart, README.md's
# "Trusting The Signing Key", "Switching To This Image" and "Signature
# Verification" sections, and the claims in docs/SECURITY-AI.md's signing
# section that name something here. The behaviour of the signing step is
# tests/test-build-publish.sh's, the behaviour of the nightly re-check is
# tests/test-nightly-compliance.sh's, and neither is repeated here -- this file
# checks that the documents and the key agree with them.

# Most needles here are literals that have to reach a file's text unexpanded --
# `${{ github.repository_owner }}`, `${IMAGE_REF}`, a backtick inside a grep
# pattern. The single quotes are the point, so SC2016 is off for the file rather
# than repeated above a dozen lines.
# shellcheck disable=SC2016

set -uo pipefail

TEST_NAME="test-signing-key"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

PUB_KEY="${REPO_ROOT}/cosign.pub"
README_MD="${REPO_ROOT}/README.md"
SECURITY_MD="${REPO_ROOT}/docs/SECURITY-AI.md"
GITIGNORE="${REPO_ROOT}/.gitignore"
SETTINGS_JSON="${REPO_ROOT}/.claude/settings.json"
BUILD_YML="${REPO_ROOT}/.github/workflows/build.yml"
NIGHTLY_YML="${REPO_ROOT}/.github/workflows/nightly-compliance.yml"
CONTAINERFILE="${REPO_ROOT}/Containerfile"

for required in "${PUB_KEY}" "${README_MD}" "${SECURITY_MD}" "${GITIGNORE}" \
    "${SETTINGS_JSON}" "${BUILD_YML}" "${NIGHTLY_YML}" "${CONTAINERFILE}"; do
    assert_file_exists "${required#"${REPO_ROOT}/"} is present" "${required}"
done

# --- helpers -----------------------------------------------------------------

# Prose with hard wraps flattened and inline markup dropped, so a claim the
# author wrapped across two lines still matches as one string.
flattened_prose() {
    tr '\n' ' ' <"$1" | tr -d '`*' | sed -e 's/[[:space:]]\+/ /g'
}

README_PROSE="$(flattened_prose "${README_MD}")"
SECURITY_PROSE="$(flattened_prose "${SECURITY_MD}")"

# A claim the assertions below hang off. Deleting the sentence has to fail here
# rather than quietly turning its join into a check on the tree alone.
require_claim() {
    local description=$1 haystack=$2 claim=$3
    assert_contains "${description}" "${haystack}" "${claim}"
}

# The body of a `## ` section of a Markdown file, up to the next `## `.
section_body() {
    awk -v want="$1" '
        $0 == want { inside = 1; next }
        inside && /^## / { exit }
        inside
    ' "$2"
}

# Everything inside fenced code blocks of the text on stdin, with an optional
# info string filter -- the runnable snippets, as opposed to the prose about
# them.
fenced_content() {
    local want=${1:-}
    awk -v want="${want}" '
        /^[ \t]*(```|~~~)/ {
            if (fenced) { fenced = 0; next }
            fenced = 1
            info = $0
            sub(/^[ \t]*(```|~~~)/, "", info)
            emit = (want == "" || info == want)
            next
        }
        fenced && emit
    '
}

# --- 1. the committed half is a public key, and the shape cosign makes -------
#
# Read as bytes, not described. A truncated or replaced anchor is the failure
# no build notices.

PEM_BEGIN="-----BEGIN PUBLIC KEY-----"
PEM_END="-----END PUBLIC KEY-----"

key_text="$(cat "${PUB_KEY}")"
assert_contains "cosign.pub opens with a PUBLIC KEY PEM header" "${key_text}" "${PEM_BEGIN}"
assert_contains "cosign.pub closes it" "${key_text}" "${PEM_END}"
assert_eq "cosign.pub holds exactly one PEM block" "1" \
    "$(grep -cF -- "${PEM_BEGIN}" "${PUB_KEY}")"

# Nothing outside the block. A key with a second block, or a stray line, is a
# file someone edited by hand.
assert_eq "cosign.pub is the PEM block and nothing else" "" \
    "$(sed -e "/${PEM_BEGIN}/,/${PEM_END}/d" "${PUB_KEY}" | tr -d '[:space:]')"

key_b64="$(awk -v begin="${PEM_BEGIN}" -v end="${PEM_END}" '
    $0 == begin { inside = 1; next }
    $0 == end   { inside = 0 }
    inside
' "${PUB_KEY}" | tr -d '[:space:]')"
if [[ -z "${key_b64}" ]]; then
    _fail "cosign.pub carries a base64 body" "the PEM block is empty"
    key_hex=""
else
    _pass "cosign.pub carries a base64 body"
    key_hex="$(printf '%s' "${key_b64}" | base64 -d 2>/dev/null | od -An -v -tx1 | tr -d ' \n')"
fi

if [[ -z "${key_hex}" ]]; then
    _fail "the body decodes as base64" "base64 -d produced nothing"
else
    _pass "the body decodes as base64"
fi

# A P-256 SubjectPublicKeyInfo is 91 bytes: a 19-byte AlgorithmIdentifier
# carrying the two OIDs, then a 66-byte BIT STRING holding the uncompressed
# point. Each part is asserted by name so a failure says which one moved.
assert_eq "the key is a 91-byte SubjectPublicKeyInfo" "91" "$((${#key_hex} / 2))"
assert_contains "it is a DER SEQUENCE of 89 content bytes" "${key_hex:0:4}" "3059"
assert_contains "its algorithm is id-ecPublicKey (1.2.840.10045.2.1)" \
    "${key_hex}" "06072a8648ce3d0201"
assert_contains "on curve prime256v1 (1.2.840.10045.3.1.7), which is what cosign generates" \
    "${key_hex}" "06082a8648ce3d030107"
assert_contains "and the point is stored uncompressed in a 66-byte BIT STRING" \
    "${key_hex}" "03420004"
assert_eq "cosign.pub is tracked, not merely present" "cosign.pub" \
    "$(cd "${REPO_ROOT}" && git ls-files -- cosign.pub)"
assert_eq "and is tracked as a non-executable file" "100644" \
    "$(cd "${REPO_ROOT}" && git ls-files -s -- cosign.pub | awk '{print $1}')"

# --- 2. the private half is nowhere in the tree ------------------------------
#
# docs/SECURITY-AI.md calls a SIGNING_SECRET leak the highest severity in the
# repo. A committed private key is that leak with no revocation path.

# Spelled in two pieces so this file is not itself a hit for the scan below.
PRIVATE_MARKER="$(printf '%s%s' 'PRI' 'VATE KEY-----')"

private_hits="$(cd "${REPO_ROOT}" && git grep -l -F -e "${PRIVATE_MARKER}" -- . 2>/dev/null)"
assert_eq "no tracked file carries a private key PEM marker" "" "${private_hits}"

assert_contains ".gitignore still ignores the private half" \
    "$(cat "${GITIGNORE}")" "cosign.key"

# The paths .claude/settings.json refuses to Read are the repository's own list
# of secret-shaped names. Read it from there rather than restating it, so a name
# added to the deny rules is swept here too.
deny_reads="$(sed -nE 's/^[[:space:]]*"Read\(\.\/(.+)\)",?$/\1/p' "${SETTINGS_JSON}")"
if [[ -z "${deny_reads}" ]]; then
    _fail ".claude/settings.json still denies reading secret-shaped paths" \
        "no Read(./...) deny rule found"
else
    _pass ".claude/settings.json still denies reading secret-shaped paths"
fi

tracked_files="$(cd "${REPO_ROOT}" && git ls-files)"
while IFS= read -r pattern; do
    [[ -z "${pattern}" ]] && continue
    matched=""
    while IFS= read -r tracked; do
        # shellcheck disable=SC2053  # the pattern is the point
        if [[ "${tracked}" == ${pattern} ]]; then
            matched="${matched} ${tracked}"
        fi
    done <<<"${tracked_files}"
    assert_eq "nothing tracked matches the denied path ${pattern}" "" "${matched}"
done <<<"${deny_reads}"

# --- 3. the reference the instructions pin -----------------------------------
#
# Derived once. README.md's badges are the only place a checkout states its own
# slug, and build.yml builds the published reference out of that same slug.

assert_contains "build.yml still derives the registry from the repository owner" \
    "$(cat "${BUILD_YML}")" 'IMAGE_REGISTRY: "ghcr.io/${{ github.repository_owner }}"'
assert_contains "and the image name from the repository name" \
    "$(cat "${BUILD_YML}")" 'IMAGE_NAME: "${{ github.event.repository.name }}"'
assert_contains "and lowercases both before pushing, which is why the slug below is lowercased" \
    "$(cat "${BUILD_YML}")" 'IMAGE_REGISTRY=${IMAGE_REGISTRY,,}'

OWN_SLUG="$(grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/workflows/build\.yml' \
    "${README_MD}" | head -1 | sed -E 's#https://github\.com/([^/]+/[^/]+)/actions.*#\1#')"
if [[ -z "${OWN_SLUG}" ]]; then
    _fail "README.md still states the repository slug in its build badge" \
        "no github.com/<owner>/<repo>/actions/workflows/build.yml link found"
else
    _pass "README.md still states the repository slug in its build badge: ${OWN_SLUG}"
fi

REPO_NAME="${OWN_SLUG##*/}"
PUBLISHED_REF="ghcr.io/${OWN_SLUG,,}"

DEFAULT_TAG="$(sed -nE 's/^[[:space:]]+DEFAULT_TAG: "(.+)"[[:space:]]*$/\1/p' "${BUILD_YML}" | head -1)"
assert_eq "build.yml still publishes a default tag" "latest" "${DEFAULT_TAG}"

# Every concrete ghcr.io reference in README.md is either this repository's
# published image or an upstream one the Containerfile actually pulls. The
# placeholder forms (ghcr.io/<owner>/<repo>) carry characters this pattern does
# not match and are left to the fork instructions they belong to.
AURORA_IMAGE="$(sed -nE 's/^ARG[[:space:]]+AURORA_IMAGE=(.+)$/\1/p' "${CONTAINERFILE}" | head -1)"
upstream_refs="$(grep -oE '^FROM[[:space:]]+ghcr\.io/[a-zA-Z0-9._/-]+' "${CONTAINERFILE}" |
    sed -E 's/^FROM[[:space:]]+//')"
if [[ -z "${AURORA_IMAGE}" || -z "${upstream_refs}" ]]; then
    _fail "the Containerfile still names the images it pulls" \
        "AURORA_IMAGE='${AURORA_IMAGE}' upstream='${upstream_refs}'"
else
    _pass "the Containerfile still names the images it pulls"
fi

allowed_refs="$(printf '%s\n%s\n%s\n' "${upstream_refs}" "${AURORA_IMAGE}" "${PUBLISHED_REF}" |
    grep -v '^$' | sort -u)"
readme_refs="$(grep -oE 'ghcr\.io/[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+' "${README_MD}" | sort -u)"
assert_eq "every concrete ghcr.io reference in README.md is this image or one the Containerfile pulls" \
    "${allowed_refs}" "${readme_refs}"
assert_contains "and the published image is one of them" "${readme_refs}" "${PUBLISHED_REF}"

# --- 4. "Trusting The Signing Key" -------------------------------------------

TRUST_SECTION="$(section_body '## Trusting The Signing Key' "${README_MD}")"
if [[ -z "${TRUST_SECTION}" ]]; then
    _fail "README.md still has a Trusting The Signing Key section" "the heading is gone"
else
    _pass "README.md still has a Trusting The Signing Key section"
fi

require_claim "it still says the published images are signed with this key's other half" \
    "${README_PROSE}" \
    'signed with the key whose public half is committed here as cosign.pub'
require_claim "and that the nightly workflow re-verifies :latest against it" \
    "${README_PROSE}" \
    'the nightly compliance workflow re-verifies the published :latest against it'
require_claim "and that the policy file is added to, not replaced" \
    "${README_PROSE}" \
    'add to the existing map rather than replacing the file'
require_claim "and it names the file a host reads that map from" \
    "${README_PROSE}" '/etc/containers/policy.json'
require_claim "and it tells a fork to use its own key" \
    "${README_PROSE}" "use your own repository's path and your own cosign.pub"

install_cmd="$(printf '%s\n' "${TRUST_SECTION}" | fenced_content bash | grep -E '\binstall\b' | head -1)"
if [[ -z "${install_cmd}" ]]; then
    _fail "the section still ships an install command for the key" \
        "no install line in its bash fence"
    install_mode=""
    install_src=""
    install_dest=""
else
    _pass "the section still ships an install command for the key"
    install_mode="$(sed -E 's/.*-D?m([0-7]+).*/\1/' <<<"${install_cmd}")"
    install_src="$(awk '{print $(NF - 1)}' <<<"${install_cmd}")"
    install_dest="$(awk '{print $NF}' <<<"${install_cmd}")"
fi

assert_eq "it installs the key committed here" "cosign.pub" "${install_src}"
assert_eq "at the mode the file is tracked with" "0644" "0${install_mode#0}"
assert_contains "into the directory a container policy reads keys from" \
    "${install_dest}" "/etc/pki/containers/"
assert_eq "under a name derived from this repository" \
    "${REPO_NAME,,}.pub" "${install_dest##*/}"
assert_contains "and it creates the directory, since a fresh host has no such path" \
    "${install_cmd}" "-D"

policy_snippet="$(printf '%s\n' "${TRUST_SECTION}" | fenced_content json)"
if [[ -z "${policy_snippet}" ]]; then
    _fail "the section still ships a policy.json entry" "no json fence in the section"
    policy_json=""
else
    _pass "the section still ships a policy.json entry"
    # The snippet is one member of the `docker` transport map, so it only parses
    # wrapped. Parsing it is the point: a trailing comma or an unquoted key
    # produces an entry a host silently ignores.
    policy_json="$(printf '{%s}' "${policy_snippet}" | jq -c . 2>/dev/null)"
fi

if [[ -z "${policy_json}" ]]; then
    _fail "the policy entry parses as JSON" "jq rejected the snippet"
else
    _pass "the policy entry parses as JSON"
    assert_eq "it keys exactly one image" "1" "$(jq -r 'keys | length' <<<"${policy_json}")"
    assert_eq "and that image is the one this repository publishes" \
        "${PUBLISHED_REF}" "$(jq -r 'keys[0]' <<<"${policy_json}")"
    assert_eq "with exactly one requirement" "1" "$(jq -r '.[] | length' <<<"${policy_json}")"
    assert_eq "the requirement is a sigstore signature" "sigstoreSigned" \
        "$(jq -r '.[][0].type' <<<"${policy_json}")"
    assert_eq "checked against the key the install command writes" "${install_dest}" \
        "$(jq -r '.[][0].keyPath' <<<"${policy_json}")"
    assert_eq "and bound to the repository, so a signature for another image does not satisfy it" \
        "matchRepository" "$(jq -r '.[][0].signedIdentity.type' <<<"${policy_json}")"
fi

# --- 5. the two commands that use the key ------------------------------------

VERIFY_SECTION="$(section_body '## Signature Verification' "${README_MD}")"
verify_cmd="$(printf '%s\n' "${VERIFY_SECTION}" | fenced_content bash | grep -E 'cosign verify' | head -1)"
if [[ -z "${verify_cmd}" ]]; then
    _fail "README.md still documents a one-shot verification command" \
        "no cosign verify line in the Signature Verification section"
else
    _pass "README.md still documents a one-shot verification command"
fi
assert_contains "it verifies against the committed key, not a key fetched at run time" \
    "${verify_cmd}" "--key cosign.pub"
assert_eq "and it names this repository's published :latest" \
    "${PUBLISHED_REF}:${DEFAULT_TAG}" "$(awk '{print $NF}' <<<"${verify_cmd}")"

SWITCH_SECTION="$(section_body '## Switching To This Image' "${README_MD}")"
switch_cmd="$(printf '%s\n' "${SWITCH_SECTION}" | fenced_content bash |
    grep -F 'enforce-container-sigpolicy' | grep -F "${PUBLISHED_REF}" | head -1)"
if [[ -z "${switch_cmd}" ]]; then
    _fail "README.md still shows the concrete rebase for this repository" \
        "no --enforce-container-sigpolicy line naming ${PUBLISHED_REF}"
else
    _pass "README.md still shows the concrete rebase for this repository"
fi
assert_eq "and it rebases onto the same tag the verification command checks" \
    "${PUBLISHED_REF}:${DEFAULT_TAG}" "$(awk '{print $NF}' <<<"${switch_cmd}")"
assert_contains "with the flag that makes the policy entry above load-bearing" \
    "${switch_cmd}" "--enforce-container-sigpolicy"

# --- 6. the nightly re-check README.md promises ------------------------------
#
# The step's behaviour is tests/test-nightly-compliance.sh's. What is checked
# here is that the workflow README.md points at still runs on a schedule and
# still verifies against this file.

nightly_text="$(cat "${NIGHTLY_YML}")"
assert_contains "the nightly workflow still runs on a schedule" "${nightly_text}" "schedule:"
assert_contains "it still resolves the published :latest" "${nightly_text}" '${IMAGE_REF}:latest'
assert_contains "and verifies it against the committed key" \
    "${nightly_text}" "cosign verify --key cosign.pub"
assert_contains "by the digest it resolved, not by the tag it read" \
    "${nightly_text}" '"${IMAGE_REF}@${DIGEST}"'

# --- 7. docs/SECURITY-AI.md's claims about the private half ------------------

require_claim "SECURITY-AI.md still says where the private half comes from and how far it reaches" \
    "${SECURITY_PROSE}" \
    'COSIGN_PRIVATE_KEY is supplied from the SIGNING_SECRET repository secret and exists only in the signing step of build.yml'
require_claim "and that rotating the key invalidates every published signature" \
    "${SECURITY_PROSE}" \
    'cosign.pub is committed and consumers pin it, so rotating the key invalidates every published signature'

# "exists only in the signing step of build.yml", computed.
secret_workflows="$(cd "${REPO_ROOT}" && grep -l 'secrets\.SIGNING_SECRET' .github/workflows/*.yml | sort)"
assert_eq "exactly one workflow is handed SIGNING_SECRET" \
    ".github/workflows/build.yml" "${secret_workflows}"
assert_eq "and it is handed to exactly one step there" "1" \
    "$(grep -c 'secrets\.SIGNING_SECRET' "${BUILD_YML}")"

sign_step="$(awk '
    /^      - name: Sign container image$/ { inside = 1; print; next }
    inside && /^      - name: / { exit }
    inside
' "${BUILD_YML}")"
if [[ -z "${sign_step}" ]]; then
    _fail "build.yml still has a step named Sign container image" \
        "the secret inventory names that step"
else
    _pass "build.yml still has a step named Sign container image"
fi
assert_contains "and that is the step holding the secret" \
    "${sign_step}" 'COSIGN_PRIVATE_KEY: ${{ secrets.SIGNING_SECRET }}'

# The secret inventory table's "Used by" cell, parsed rather than restated.
used_by="$(grep -E '^\|[[:space:]]*`SIGNING_SECRET`' "${SECURITY_MD}" | head -1 |
    awk -F'|' '{print $3}')"
if [[ -z "${used_by}" ]]; then
    _fail "the secret inventory still has a SIGNING_SECRET row" "no such row"
else
    _pass "the secret inventory still has a SIGNING_SECRET row"
fi
assert_contains "whose Used by cell names the step that actually holds it" \
    "${used_by}" 'Sign container image'
assert_contains "in the workflow that actually holds it" "${used_by}" 'build.yml'
assert_contains "and whose leak consequence names the anchor it would defeat" \
    "$(grep -E '^\|[[:space:]]*`SIGNING_SECRET`' "${SECURITY_MD}" | head -1)" 'cosign.pub'

# The recipe for confirming a private key matches the committed half must name
# the path .gitignore ignores and .claude/settings.json refuses to read -- a
# rename on one side and not the others is how a private key becomes trackable.
derive_cmd="$(fenced_content bash <"${SECURITY_MD}" | grep -F 'cosign public-key' | head -1)"
if [[ -z "${derive_cmd}" ]]; then
    _fail "SECURITY-AI.md still shows how to derive the public half instead of reading the private one" \
        "no cosign public-key line"
else
    _pass "SECURITY-AI.md still shows how to derive the public half instead of reading the private one"
fi
assert_contains "it reads the private path .gitignore ignores" "${derive_cmd}" "cosign.key"
assert_contains "which is also the path the agent permission table refuses to Read" \
    "${deny_reads}" "cosign.key"
assert_contains "and it sends the reader to the committed half to compare" \
    "${derive_cmd}" "cosign.pub"

# The `gh secret set` example names a repository by slug. A fork that copies the
# line unedited pushes its key to this repository's secret store.
secret_set_cmd="$(fenced_content bash <"${SECURITY_MD}" | grep -F 'gh secret set SIGNING_SECRET -R ' |
    grep -vF ' -R ...' | head -1)"
if [[ -z "${secret_set_cmd}" ]]; then
    _fail "SECURITY-AI.md still shows the redirect form of gh secret set" "no such line"
else
    _pass "SECURITY-AI.md still shows the redirect form of gh secret set"
fi
assert_eq "and it names this repository" "${OWN_SLUG}" \
    "$(sed -E 's/.*-R[[:space:]]+([^[:space:]]+).*/\1/' <<<"${secret_set_cmd}")"
assert_contains "passing the key by redirection, so the bytes never enter a transcript" \
    "${secret_set_cmd}" "< cosign.key"

finish
