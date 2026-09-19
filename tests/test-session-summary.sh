#!/usr/bin/env bash
#
# Joins .claude/session-summary.md to the machine it describes.
#
# That file is written for an agent that has read nothing else: it says which
# branch is maintained, which inputs are pinned, what CI does *not* check, and
# which badge to distrust. Its own opening paragraph sets the bar -- "a stale
# entry here is worse than an empty file, because the next agent will act on
# it" -- and until this file existed nothing opened it. `grep -rl
# 'session-summary' tests/` returned nothing, tests/test-coverage.sh sees only
# shipped `*.sh`, tests/test-docs-paths.sh resolves paths named by README.md and
# AGENTS.md, and tests/test-editorconfig.sh reads the document as bytes to
# classify its indentation, not as claims.
#
# The claims here are unusually load-bearing for prose because they are all
# negative or procedural: "neither akmods input is pinned", "nothing validates
# the image after Chunkah", "the badge can outlive the skew it described", "run
# this snippet before acting". A reader who believes any of those after it stops
# being true does the wrong thing and has no reason to doubt it -- that is the
# failure mode the document warns about, aimed at itself.
#
# So every literal below is computed from the file the claim is about -- the
# Containerfile, .github/workflows/build.yml, ci/write-badges.sh,
# tests/e2e/run-e2e.sh, renovate.json, README.md -- and compared with what the
# document says. Editing one side alone is a red suite. Extractions refuse to
# verify an empty set: a renamed step, a deleted `FROM` line or a rewritten
# badge branch fails here rather than passing vacuously.
#
# Scope: claims that name something in this repository. The judgements -- which
# work is worth doing, whether the maintainer wants a tradeoff changed -- are
# not checkable and are left alone. Two properties tests/test-memory-corrections.sh
# also holds, the Containerfile's trailing check order and the rechunk's
# position in build.yml, are reached here from the other side: that test asks
# what `.claude/memory/corrections.md` recorded about an incident, this one asks
# whether the "Open threads" section still describes today's pipeline, and
# neither stands in for the other.

set -uo pipefail

TEST_NAME="test-session-summary"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

DOC="${REPO_ROOT}/.claude/session-summary.md"
CONTAINERFILE="${REPO_ROOT}/Containerfile"
BUILD_WF="${REPO_ROOT}/.github/workflows/build.yml"
BADGES="${REPO_ROOT}/ci/write-badges.sh"
E2E="${REPO_ROOT}/tests/e2e/run-e2e.sh"
RENOVATE="${REPO_ROOT}/renovate.json"
README="${REPO_ROOT}/README.md"
AGENTS="${REPO_ROOT}/AGENTS.md"
WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

assert_file_exists ".claude/session-summary.md is present" "${DOC}"

for required in "${DOC}" "${CONTAINERFILE}" "${BUILD_WF}" "${BADGES}" "${E2E}" \
    "${RENOVATE}" "${README}" "${AGENTS}"; do
    [[ -f "${required}" ]] && continue
    _fail "every file the summary describes is present" \
        "no such file: ${required#"${REPO_ROOT}"/}" \
        "if it was removed on purpose, the claim about it is now wrong"
    finish
    exit 1
done

DOC_TEXT="$(cat "${DOC}")"
BADGES_TEXT="$(cat "${BADGES}")"
E2E_TEXT="$(cat "${E2E}")"
README_TEXT="$(cat "${README}")"

# --- 1. the shape the document asks of itself -------------------------------
#
# "Rewrite it at the end of a session that changes the answer" only means
# something if a reader can tell when it was last rewritten, and the document
# hands the rest of the job to AGENTS.md rather than repeating it. Both are
# structure, not prose, so both are asserted.

LAST_UPDATED="$(grep -oE '^\*\*Last updated:\*\* [0-9]{4}-[0-9]{2}-[0-9]{2}$' "${DOC}" | head -1)"
if [[ -z "${LAST_UPDATED}" ]]; then
    _fail "the summary carries an ISO 'Last updated:' date" \
        "no '**Last updated:** YYYY-MM-DD' line found;" \
        "without it a reader cannot tell how far behind the document is"
else
    _pass "the summary carries an ISO 'Last updated:' date (${LAST_UPDATED##* })"
fi

# shellcheck disable=SC2016 # a Markdown code span, compared as literal text
assert_contains "the summary sends a reader to AGENTS.md for how the repo works" \
    "${DOC_TEXT}" '`AGENTS.md`'

for heading in "## Where things stand" "## In flight" \
    "## Open threads worth knowing about" "## Before you start anything"; do
    assert_contains "the summary still has its '${heading#\#\# }' section" \
        "${DOC_TEXT}" "${heading}"
done

# --- 2. every repository path the summary names still exists ----------------
#
# A summary that cites a path that moved sends its reader looking for a file
# that is not there, which is the "stale is worse than empty" failure in its
# cheapest form. What counts as a citation is computed from the tree rather
# than listed, so a citation cannot escape by being renamed to something a list
# never mentioned: a backticked token is a path when it has a directory
# component, when it is `Containerfile`, when its suffix is one this repository
# tracks, or when its stem names a tracked file. Tokens that only look like
# paths -- `ostree.linux`, `FEDORA_VERSION` -- match none of the four and stay
# out of it. Directory citations (`docs/`, `tests/e2e/`) resolve as directories.

TRACKED="$(cd "${REPO_ROOT}" && git ls-files)"
if [[ -z "${TRACKED}" ]]; then
    _fail "the tracked file list was read" "git ls-files produced none"
    finish
    exit 1
fi

TRACKED_NAMES=""
TRACKED_SUFFIXES=""
TRACKED_STEMS=""
while IFS= read -r tracked_path; do
    tracked_name="${tracked_path##*/}"
    TRACKED_NAMES+="${tracked_name}"$'\n'
    if [[ "${tracked_name}" =~ ^(.*)\.([A-Za-z0-9]{1,8})$ ]]; then
        TRACKED_STEMS+="${BASH_REMATCH[1]}"$'\n'
        TRACKED_SUFFIXES+="${BASH_REMATCH[2]}"$'\n'
    else
        TRACKED_STEMS+="${tracked_name}"$'\n'
    fi
done <<<"${TRACKED}"
TRACKED_NAMES="$(sort -u <<<"${TRACKED_NAMES%$'\n'}")"
TRACKED_SUFFIXES="$(sort -u <<<"${TRACKED_SUFFIXES%$'\n'}")"
TRACKED_STEMS="$(sort -u <<<"${TRACKED_STEMS%$'\n'}")"

if [[ -z "${TRACKED_SUFFIXES}" || -z "${TRACKED_STEMS}" ]]; then
    _fail "the tracked file names were read" "git ls-files produced no usable names"
    finish
    exit 1
fi

looks_like_a_path() {
    local token=$1 base suffix stem
    [[ "${token}" == */* ]] && return 0
    [[ "${token}" == Containerfile ]] && return 0
    base="${token##*/}"
    [[ "${base}" == *.* ]] || return 1
    suffix="${base##*.}"
    stem="${base%.*}"
    [[ -n "${stem}" ]] || return 1
    grep -qxF "${suffix}" <<<"${TRACKED_SUFFIXES}" && return 0
    grep -qxF "${stem}" <<<"${TRACKED_STEMS}" && return 0
    return 1
}

path_checks=0
while IFS= read -r token; do
    [[ -z "${token}" ]] && continue
    candidate="${token#./}"
    looks_like_a_path "${candidate}" || continue
    path_checks=$((path_checks + 1))
    if [[ "${candidate}" == */ ]]; then
        if [[ -d "${REPO_ROOT}/${candidate%/}" ]]; then
            _pass "the summary cites a directory that exists: ${candidate}"
        else
            _fail "the summary cites a directory that exists: ${candidate}" \
                "no such directory; the entry points at something that moved"
        fi
    elif grep -qxF "${candidate}" <<<"${TRACKED}"; then
        _pass "the summary cites a tracked path: ${candidate}"
    elif grep -qxF "${candidate}" <<<"${TRACKED_NAMES}"; then
        _pass "the summary cites a tracked file by name: ${candidate}"
    else
        _fail "the summary cites a tracked path: ${candidate}" \
            "git tracks no such file; the entry cites something that moved"
    fi
done < <(
    # shellcheck disable=SC2016 # a backtick is the delimiter being matched, not a command
    grep -o '`[^`]*`' "${DOC}" |
        tr -d '`' |
        grep -E '^\.?/?[A-Za-z0-9][A-Za-z0-9._/-]*/?$' |
        sort -u
)

if [[ "${path_checks}" -eq 0 ]]; then
    _fail "the summary cites repository paths" \
        "no backticked path matched; the resolver above verified nothing"
fi

# --- 3. "Where things stand" ------------------------------------------------

# --- 3a. the maintained branch and the retired one --------------------------
#
# README.md is the public statement of the same fact, so the two are compared
# against each other rather than against a literal typed twice. The branch name
# and tag are read out of README.md: renaming either there without rewriting
# this section fails, which is the only way the summary stays joined to the
# repository's own account of itself.

LEGACY_BRANCH="$(grep -oE '/tree/[A-Za-z0-9._/-]+\)' "${README}" | head -1 | sed 's#^/tree/##; s#)$##')"
# shellcheck disable=SC2016 # a backtick is the delimiter being matched, not a command
LEGACY_TAG="$(grep -oE '`nvidia-last-known-good-[0-9]{4}-[0-9]{2}-[0-9]{2}`' "${README}" | head -1 | tr -d '`')"

if [[ -z "${LEGACY_BRANCH}" ]]; then
    _fail "README.md still names the retired NVIDIA branch" \
        "no /tree/<branch> link found; the summary's claim has nothing to agree with"
else
    assert_contains "the summary names the same retired branch README.md links (${LEGACY_BRANCH})" \
        "${DOC_TEXT}" "\`${LEGACY_BRANCH}\`"
fi

if [[ -z "${LEGACY_TAG}" ]]; then
    _fail "README.md still names the last-known-good tag" \
        "no 'nvidia-last-known-good-<date>' found in README.md"
else
    assert_contains "the summary names the same tag README.md does (${LEGACY_TAG})" \
        "${DOC_TEXT}" "\`${LEGACY_TAG}\`"
fi

assert_contains "README.md still calls main the maintained AMD/non-NVIDIA branch" \
    "${README_TEXT}" "maintained AMD/non-NVIDIA branch"
assert_contains "and the summary says the same" \
    "${DOC_TEXT}" "maintained AMD/non-NVIDIA branch"

# --- 3b. "Neither akmods input is pinned. FEDORA_VERSION is 44." ------------
#
# Both halves are read out of the Containerfile. The Fedora major is compared
# as a number rather than matched as text, so bumping the ARG without touching
# this file is a failure here instead of a reader believing 44.

FEDORA_VERSION="$(sed -n 's/^ARG FEDORA_VERSION=\([0-9][0-9]*\).*/\1/p' "${CONTAINERFILE}" | head -1)"
if [[ -z "${FEDORA_VERSION}" ]]; then
    _fail "the Containerfile still declares ARG FEDORA_VERSION" "no numeric value found"
else
    # shellcheck disable=SC2016 # a Markdown code span, compared as literal text
    assert_contains "the summary states the Containerfile's Fedora major (${FEDORA_VERSION})" \
        "${DOC_TEXT}" '`FEDORA_VERSION` is '"${FEDORA_VERSION}"
fi

mapfile -t AKMODS_FROM < <(grep -E '^FROM ghcr\.io/ublue-os/akmods(-zfs)?:' "${CONTAINERFILE}")
if [[ "${#AKMODS_FROM[@]}" -ne 2 ]]; then
    _fail "the Containerfile still has both akmods FROM lines" \
        "found ${#AKMODS_FROM[@]}; the summary's 'neither input' claim has no subject"
else
    for line in "${AKMODS_FROM[@]}"; do
        stage="${line##* AS }"
        assert_not_contains "the ${stage} input is not pinned to a digest" "${line}" "@sha256:"
        assert_contains "the ${stage} input still floats on FEDORA_VERSION" \
            "${line}" "FEDORA_VERSION"
    done
fi

# --- 4. "docs/ is in build.yml's paths-ignore" ------------------------------
#
# The claim is why a docs-only branch can show no checks at all, which is the
# difference between "CI is broken" and "CI was not asked". Every trigger that
# filters paths has to still ignore docs/ for that to hold; one that stopped
# would make the summary's reassurance wrong in the direction that costs an
# agent a diagnosis.

if ! "${WORKFLOW_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    _fail "reading build.yml requires Python 3 with PyYAML" \
        "install python3-yaml (Debian/Ubuntu) or python3-pyyaml (Fedora)," \
        "or install PyYAML in the interpreter selected by WORKFLOW_PYTHON"
    finish
    exit 1
fi

NORMALIZER="${TMP_ROOT}/normalize.py"
cat >"${NORMALIZER}" <<'PY'
"""Print one workflow file as JSON, with the `on:` key readable by name.

PyYAML implements YAML 1.1, where a bare `on` is the boolean true, so
doc["on"] raises KeyError on every workflow ever written.
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

BUILD_JSON="${TMP_ROOT}/build.json"
if ! "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${BUILD_WF}" >"${BUILD_JSON}" 2>"${TMP_ROOT}/normalize.err"; then
    _fail "build.yml parses" "$(cat "${TMP_ROOT}/normalize.err")"
    finish
    exit 1
fi
_pass "build.yml parses"

mapfile -t FILTERED_TRIGGERS < <(
    jq -r '.on | to_entries[] | select(.value | type == "object")
           | select(.value["paths-ignore"] != null) | .key' <"${BUILD_JSON}"
)
if [[ "${#FILTERED_TRIGGERS[@]}" -eq 0 ]]; then
    _fail "build.yml still filters any trigger by path" \
        "no trigger carries paths-ignore; a docs-only branch would now run the build," \
        "and the summary tells a reader to expect no checks"
else
    for trigger in "${FILTERED_TRIGGERS[@]}"; do
        ignored="$(jq -r --arg t "${trigger}" '.on[$t]["paths-ignore"][]' <"${BUILD_JSON}")"
        assert_contains "build.yml's ${trigger} trigger still ignores docs/" \
            "${ignored}" "docs/**"
    done
fi

# --- 5. "Nothing validates the image after Chunkah" -------------------------
#
# The whole open thread is an ordering: both Containerfile checks are RUN
# steps, so they run inside the build, and everything the workflow does from
# the rechunk onward happens to an image neither has seen. Asserting the order
# is asserting the claim; asserting the two step names alone would not.

mapfile -t RUN_BLOCKS < <(
    awk '
        /^RUN / { if (block != "") print block; block = $0; prev = $0; next }
        block != "" {
            if (prev ~ /\\[[:space:]]*$/) { block = block " " $0 }
            else { print block; block = "" }
        }
        { prev = $0 }
        END { if (block != "") print block }
    ' "${CONTAINERFILE}"
)

if [[ "${#RUN_BLOCKS[@]}" -lt 2 ]]; then
    _fail "the Containerfile still ends in two RUN checks" \
        "found ${#RUN_BLOCKS[@]} RUN instruction(s)"
else
    last="${RUN_BLOCKS[$((${#RUN_BLOCKS[@]} - 1))]}"
    second_last="${RUN_BLOCKS[$((${#RUN_BLOCKS[@]} - 2))]}"
    assert_contains "the Containerfile's last RUN is the image lint the summary names" \
        "${last}" "bootc container lint"
    assert_contains "the RUN before it is post-check.sh" \
        "${second_last}" "/ctx/post-check.sh"
fi

step_names() {
    jq -r --arg job "$1" '.jobs[$job].steps[] | .name // empty' <"${BUILD_JSON}"
}

step_index() {
    local job=$1 name=$2
    step_names "${job}" | grep -nxF "${name}" | head -1 | cut -d: -f1
}

BUILD_IMAGE_STEP="Build Image"
RECHUNK_STEP="Rechunk Image with Chunkah"

build_idx="$(step_index build_push "${BUILD_IMAGE_STEP}")"
rechunk_idx="$(step_index build_push "${RECHUNK_STEP}")"

if [[ -z "${build_idx}" || -z "${rechunk_idx}" ]]; then
    _fail "build.yml still has the steps the open thread describes" \
        "'${BUILD_IMAGE_STEP}' -> '${build_idx:-missing}'," \
        "'${RECHUNK_STEP}' -> '${rechunk_idx:-missing}'"
elif [[ "${build_idx}" -ge "${rechunk_idx}" ]]; then
    _fail "the Containerfile's checks run before the rechunk, as the summary says" \
        "step ${build_idx} is not before step ${rechunk_idx}"
else
    _pass "the Containerfile's checks run before the rechunk, as the summary says"

    # "loaded, tagged, pushed and signed unchecked": everything from the
    # rechunk onward, names and bodies together.
    after_rechunk="$(jq -r --argjson i "$((rechunk_idx - 1))" \
        '.jobs.build_push.steps[$i:][] | (.name // "") + "\n" + (.run // "")' <"${BUILD_JSON}")"
    if [[ -z "${after_rechunk//[[:space:]]/}" ]]; then
        _fail "the steps from the rechunk onward were read" "the slice was empty"
    else
        assert_not_contains "nothing from the rechunk onward re-runs post-check.sh" \
            "${after_rechunk}" "post-check.sh"
        assert_not_contains "nothing from the rechunk onward re-runs the image lint" \
            "${after_rechunk}" "bootc container lint"
        for expected in "Push To GHCR" "Sign container image"; do
            assert_contains "the unchecked image is still handled by '${expected}'" \
                "${after_rechunk}" "${expected}"
        done
    fi
fi

# --- 5a. "tests/e2e/run-e2e.sh --rechunk closes this loop locally" ----------
#
# The summary offers exactly one remedy for the gap above, so the remedy has to
# still exist and still do both halves: the flag is accepted, and the image it
# checks is the rechunked one rather than the built one. A --rechunk that
# verified the pre-rechunk image would leave the summary recommending a no-op.

# shellcheck disable=SC2016 # the script's own case arm, compared as literal text
assert_contains "run-e2e.sh still accepts --rechunk" \
    "${E2E_TEXT}" '--rechunk) RECHUNK=1'
assert_contains "and --rechunk re-runs post-check.sh against the final image" \
    "${E2E_TEXT}" "post-check.sh passes against the final image"
assert_contains "and re-runs the image lint the Containerfile ran before the rechunk" \
    "${E2E_TEXT}" "bootc container lint passes against the final image"
# shellcheck disable=SC2016 # a shell expansion, compared as literal text
assert_contains "the image those checks run against is the rechunked tag" \
    "${E2E_TEXT}" 'TARGET="${CHUNKED_TAG}"'

# --- 6. "The Chunkah pin is a semver tag, not a digest" ---------------------
#
# Both halves are read out of the files rather than restated: the pin's shape
# comes from build.yml, and the deliberate exclusion comes from renovate.json's
# own rule. The image name is the join between them -- a rename on one side
# that left the other behind would silently stop the rule from applying, and a
# reader told "deliberately" would not look.

CHUNKAH_IMAGE="$(grep -oE 'CHUNKAH_IMAGE:[[:space:]]*[^[:space:]]+' "${BUILD_WF}" |
    head -1 | sed 's/^CHUNKAH_IMAGE:[[:space:]]*//')"
if [[ -z "${CHUNKAH_IMAGE}" ]]; then
    _fail "build.yml still pins a Chunkah image" "no CHUNKAH_IMAGE assignment found"
else
    assert_not_contains "the Chunkah pin is not a digest, as the summary says" \
        "${CHUNKAH_IMAGE}" "@sha256:"
    if [[ "${CHUNKAH_IMAGE}" =~ ^(.+):v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        _pass "the Chunkah pin is a semver tag (${CHUNKAH_IMAGE##*:})"
        CHUNKAH_NAME="${BASH_REMATCH[1]}"
    else
        _fail "the Chunkah pin is a semver tag" \
            "not v<major>.<minor>.<patch>: ${CHUNKAH_IMAGE}"
        CHUNKAH_NAME=""
    fi

    if [[ -n "${CHUNKAH_NAME}" ]]; then
        # The rule renovate.json disables has to name the image build.yml pins,
        # cover digest updates, and be off.
        disabled="$(jq -r --arg img "${CHUNKAH_NAME}" '
            .packageRules[]
            | select((.matchPackageNames // []) | index($img))
            | select((.matchUpdateTypes // []) | index("digest"))
            | .enabled' "${RENOVATE}")"
        assert_eq "renovate.json disables digest updates for ${CHUNKAH_NAME}" \
            "false" "${disabled}"
    fi
fi

# --- 7. "Check the OpenZFS/kernel badge" ------------------------------------
#
# The badge is named by the script that writes it, so the summary is compared
# against that name rather than against a spelling typed here. Case is not the
# claim; the badge identity is.

mapfile -t BADGE_NAMES < <(grep -oE '"[a-z]+/[a-z]+"' "${BADGES}" | tr -d '"' | sort -u)
if [[ "${#BADGE_NAMES[@]}" -eq 0 ]]; then
    _fail "ci/write-badges.sh still names the badges it writes" "no badge name found"
else
    kernel_badge=""
    for name in "${BADGE_NAMES[@]}"; do
        [[ "${name}" == *kernel* ]] && kernel_badge="${name}"
    done
    if [[ -z "${kernel_badge}" ]]; then
        _fail "ci/write-badges.sh still writes a kernel badge" \
            "none of ${BADGE_NAMES[*]} names a kernel"
    else
        doc_lower="$(tr '[:upper:]' '[:lower:]' <<<"${DOC_TEXT}")"
        assert_contains "the summary sends a reader to the badge the script writes (${kernel_badge})" \
            "${doc_lower}" "${kernel_badge}"
    fi
fi

# "If it says blocked" -- the value the summary tells a reader to react to has
# to be one the script can actually produce.
assert_contains "ci/write-badges.sh can still produce the 'blocked' value the summary reacts to" \
    "${BADGES_TEXT}" '"blocked: kernel'

# "ci/write-badges.sh deliberately leaves a badge at its last value when it
# cannot read an input" -- the warning the whole "confirm it" paragraph rests
# on. Both the degrade-to-nothing read and the leave-alone branch are asserted,
# because either one alone would let the badge start guessing.
# shellcheck disable=SC2016 # the script's own line, compared as literal text
assert_contains "an unreadable image still degrades to empty rather than failing" \
    "${BADGES_TEXT}" 'skopeo inspect "$@" "docker://${ref}" 2>/dev/null || true'
assert_contains "and an unread input still leaves the badge at its last value" \
    "${BADGES_TEXT}" "leaving the openzfs/kernel badge as-is"

# --- 8. the snippet the summary tells a reader to run -----------------------
#
# This is the one block in the document a reader executes rather than believes,
# and it hard-codes three things that live elsewhere: how FEDORA_VERSION is
# read out of the Containerfile, which two images carry the labels, and how
# their references are spelled. Each is checked against the Containerfile
# itself, so a `FROM` line edited during an outage -- the documented
# workaround -- cannot leave the snippet inspecting images the build no longer
# pulls, which is exactly the trap ci/write-badges.sh's own comments describe.

SNIPPET="$(awk '/^```bash$/ { grab = 1; next } /^```$/ { grab = 0 } grab' "${DOC}")"
if [[ -z "${SNIPPET//[[:space:]]/}" ]]; then
    _fail "the summary still carries its label-comparison snippet" \
        "no fenced bash block found; the checks below would verify nothing"
    finish
    exit 1
fi
_pass "the summary still carries its label-comparison snippet"

# 8a. The extraction line, run for real against the Containerfile.
# shellcheck disable=SC2016 # the snippet's own assignment, compared as literal text
SED_LINE="$(grep -F 'FEDORA_VERSION=$(sed' <<<"${SNIPPET}" | head -1)"
if [[ -z "${SED_LINE}" ]]; then
    _fail "the snippet still reads FEDORA_VERSION out of the Containerfile" \
        "no sed assignment found"
else
    snippet_fedora="$(cd "${REPO_ROOT}" && eval "${SED_LINE}" && printf '%s' "${FEDORA_VERSION}")"
    assert_eq "the snippet's sed extracts the Containerfile's Fedora major" \
        "${FEDORA_VERSION}" "${snippet_fedora}"
fi

# 8b. The two images it loops over are the two the Containerfile pulls.
LOOP_IMAGES="$(grep -oE '^for img in .*; do' <<<"${SNIPPET}" | head -1 |
    sed 's/^for img in //; s/; do$//')"
CONTAINERFILE_IMAGES=""
for line in "${AKMODS_FROM[@]}"; do
    ref="${line#FROM }"
    ref="${ref%% *}"
    ref="${ref%%:*}"
    CONTAINERFILE_IMAGES+="${ref##*/} "
done
assert_eq "the snippet loops over the images the Containerfile pulls" \
    "${CONTAINERFILE_IMAGES% }" "${LOOP_IMAGES}"

# 8c. The reference it builds, expanded, is the reference the build uses.
REF_TEMPLATE="$(grep -oE '"docker://[^"]+"' <<<"${SNIPPET}" | head -1 | tr -d '"')"
REF_TEMPLATE="${REF_TEMPLATE#docker://}"
if [[ -z "${REF_TEMPLATE}" ]]; then
    _fail "the snippet still builds a docker:// reference" "no reference found"
else
    for line in "${AKMODS_FROM[@]}"; do
        expected="${line#FROM }"
        expected="${expected%% *}"
        expected="${expected//\"/}"
        expected="${expected//\$\{FEDORA_VERSION\}/${FEDORA_VERSION}}"
        img="${expected%%:*}"
        img="${img##*/}"
        actual="$(FEDORA_VERSION="${FEDORA_VERSION}" img="${img}" eval "printf '%s' \"${REF_TEMPLATE}\"")"
        assert_eq "the snippet inspects the reference the build pulls for ${img}" \
            "${expected}" "${actual}"
    done
fi

# 8d. The label it reads is the label the badge script compares.
assert_contains "the snippet reads the label ci/write-badges.sh compares" \
    "${SNIPPET}" "ostree.linux"
assert_contains "and ci/write-badges.sh still compares that label" \
    "${BADGES_TEXT}" 'ostree.linux'

finish
