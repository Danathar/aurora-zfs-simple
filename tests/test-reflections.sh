#!/usr/bin/env bash
#
# Joins docs/reflections/** to the files its entries make claims about.
#
# docs/reflections/README.md says these entries exist to be acted on: durable
# lessons, written down so the next session starts with them instead of
# rediscovering them. Every one of them restates facts that live somewhere
# else -- a step name and its position in .github/workflows/build.yml, the
# numbers in AGENTS.md's Chunkah diagnosis, which document sends a reader to
# which -- and before this file no test opened any of them. `grep -rF` over
# tests/ found two hits and neither read a claim: tests/test-editorconfig.sh
# uses docs/reflections/README.md as bytes to classify indentation, and
# tests/test-quality-docs.sh names an entry in a comment. tests/test-docs-paths.sh
# resolves the `](path)` links in every tracked *.md, so the links are checked;
# nothing else is.
#
# That matters more here than for ordinary prose. docs/risk-tiers.md puts
# load-bearing prose above self-checking test code because a reflection that
# has drifted fails nothing -- it misleads the next reader about why a step in
# the publish band exists, and the entries that explain an invariant are
# exactly the ones a later simplification would consult before removing it.
#
# So nothing here is typed in twice where it can be computed. The tag set is
# read out of the `Image Metadata` step, the step order out of the job, the
# Chunkah numbers out of the rechunk step's own comment, the tier order out of
# docs/risk-tiers.md's table, and each is compared with what the entry says --
# both directions where a set is named, so a field added to one copy and not
# the other fails. Extractions refuse to verify an empty set: a renamed step or
# a deleted heading fails here rather than passing vacuously. `require_claim`
# holds the sentences the joins hang off, so deleting a claim fails instead of
# quietly turning its assertion into a check on the tree alone.
#
# Scope: the format spec the directory's README states, applied to every
# entry; the claims that name something in this repository; and every
# docs/reflections/<file> cited from a non-Markdown file. Judgements ("the fix
# is smaller than the bug") are not checkable and are left alone. Links are
# tests/test-docs-paths.sh's and are not re-resolved here.

set -uo pipefail

TEST_NAME="test-reflections"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=tests/lib/markdown.sh
source "${TEST_DIR}/lib/markdown.sh"

REFLECTIONS_DIR="${REPO_ROOT}/docs/reflections"
REFLECTIONS_README="${REFLECTIONS_DIR}/README.md"
TAGS_ENTRY="${REFLECTIONS_DIR}/2026-07-02-one-manifest-many-tags.md"
CHUNKAH_ENTRY="${REFLECTIONS_DIR}/2026-08-25-large-json-through-the-environment.md"
PROSE_ENTRY="${REFLECTIONS_DIR}/2026-09-03-prose-an-agent-is-told-to-trust.md"
BUILD_WF="${REPO_ROOT}/.github/workflows/build.yml"
NIGHTLY_WF="${REPO_ROOT}/.github/workflows/nightly-compliance.yml"
COVERAGE_WF="${REPO_ROOT}/.github/workflows/coverage-gate.yml"
AGENTS="${REPO_ROOT}/AGENTS.md"
README="${REPO_ROOT}/README.md"
RISK_TIERS="${REPO_ROOT}/docs/risk-tiers.md"
DOCS_PATHS_TEST="${TEST_DIR}/test-docs-paths.sh"
WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

missing=0
for required in \
    "${REFLECTIONS_README}" "${TAGS_ENTRY}" "${CHUNKAH_ENTRY}" "${PROSE_ENTRY}" \
    "${BUILD_WF}" "${NIGHTLY_WF}" "${COVERAGE_WF}" "${AGENTS}" "${README}" \
    "${RISK_TIERS}" "${DOCS_PATHS_TEST}"; do
    if [[ -f "${required}" ]]; then
        continue
    fi
    _fail "${required#"${REPO_ROOT}"/} is present" "no such file"
    missing=1
done

if [[ "${missing}" -ne 0 ]]; then
    finish
    exit
fi

# --- extraction helpers -----------------------------------------------------

# A file with its line breaks collapsed. Prose wraps, so every sentence below
# is matched against this form: a claim that has to be found at one particular
# wrap point is a claim a reflow can silently delete. A blockquote's `> ` and a
# shell comment's `# ` are line decoration, not words, and are dropped first so
# a sentence that wraps inside one still reads as a sentence.
flattened() {
    sed -E 's/^[[:space:]]*(> ?|# ?)//' "$1" | tr '\n' ' ' | tr -s '[:space:]' ' '
}

# A claim this file goes on to verify has to still be in the document.
require_claim() {
    local file=$1 description=$2 needle=$3
    if [[ "$(flattened "${file}")" == *"${needle}"* ]]; then
        _pass "${file#"${REPO_ROOT}"/} still claims ${description}"
        return 0
    fi
    _fail "${file#"${REPO_ROOT}"/} still claims ${description}" \
        "the sentence this test verifies is gone: ${needle}" \
        "either restore it or drop the assertions that depend on it"
    return 1
}

# An extraction that matched nothing is not a passing check, it is an
# unverified document.
require_nonempty() {
    local description=$1 content=$2
    if [[ -n "${content//[[:space:]]/}" ]]; then
        _pass "still has ${description}"
        return 0
    fi
    _fail "still has ${description}" \
        "nothing was extracted, so the checks over it verify nothing"
    return 1
}

# The code spans in a chunk of text, one per line, in order.
code_spans() {
    # SC2016: the backticks delimit Markdown code spans, not a command
    # substitution, so they stay literal.
    # shellcheck disable=SC2016
    grep -oE '`[^`]+`' <<<"$1" | tr -d '`'
}

# The body of one `##` section of a Markdown file, verbatim.
doc_section() {
    local file=$1 heading=$2
    awk -v heading="${heading}" '
        $0 == heading { in_section = 1; next }
        /^## /        { in_section = 0 }
        in_section
    ' "${file}"
}

# The data rows of the first Markdown table in a chunk of text.
table_rows() {
    awk '
        /^\|/ {
            if ($0 ~ /^\|[[:space:]:|-]+\|[[:space:]:|-]*$/) { seen_rule = 1; next }
            if (seen_rule) { print }
            next
        }
        seen_rule && NF == 0 { seen_rule = 0 }
    '
}

# One cell of a `| a | b |` row, 1-indexed, trimmed, emphasis and code-span
# markers dropped.
cell() {
    local row=$1 index=$2 value
    value="$(awk -F'|' -v n="${index}" '{ print $(n + 1) }' <<<"${row}")"
    value="${value//\*/}"
    value="${value//\`/}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

# Sorted, space-joined, so two lists can be compared as sets.
as_set() {
    LC_ALL=C sort -u | tr '\n' ' '
}

# The text that follows a phrase in a flattened document, up to `n` characters.
# Used to read a short list out of the sentence that introduces it, so the set
# being compared is the one the prose actually names and not every code span
# in the file.
after_phrase() {
    local text=$1 phrase=$2 n=$3
    [[ "${text}" == *"${phrase}"* ]] || return 0
    printf '%s' "${text#*"${phrase}"}" | cut -c1-"${n}"
}

# --- helper case tables -----------------------------------------------------
#
# Every join below is only as good as these extractors.

# SC2016 here and below: the single quotes hold Markdown and shell text this
# test looks for literally, not expressions it wants expanded.
# shellcheck disable=SC2016
assert_eq "code_spans returns each span in order" \
    "a b " "$(code_spans 'text `a` and `b` here' | tr '\n' ' ')"
# shellcheck disable=SC2016
assert_eq "cell trims and drops emphasis and code spans" \
    "1 — Load-bearing prose" "$(cell '| **1 — Load-bearing prose** | `x` |' 1)"
assert_eq "as_set sorts and deduplicates" \
    "a b " "$(printf 'b\na\nb\n' | as_set)"
assert_eq "after_phrase reads the text following a phrase" \
    " x, y and" "$(after_phrase 'carries x, y and z' 'carries' 9)"
assert_eq "after_phrase yields nothing for a phrase that is absent" \
    "" "$(after_phrase 'carries x' 'holds' 9)"
assert_eq "table_rows drops the header and the separator" \
    "2" "$(printf '| A | B |\n| - | - |\n| 1 | 2 |\n| 3 | 4 |\n' | table_rows | grep -c '^|')"

# =============================================================================
# 1. The directory's own format spec, applied to every entry
# =============================================================================
#
# docs/reflections/README.md is the spec: one file per lesson, named
# `YYYY-MM-DD-short-slug.md`, dated when the lesson was learned, three headings
# in a stated order. Nothing checked an entry against it, so a fourth entry
# could arrive in any shape and the README would still describe a convention
# the directory had stopped following.

# SC2016 on the claims below: the backticks are the documents' own Markdown
# code spans, matched literally.
# shellcheck disable=SC2016
require_claim "${REFLECTIONS_README}" "the filename shape" \
    'named `YYYY-MM-DD-short-slug.md`'
require_claim "${REFLECTIONS_README}" "the three headings" \
    "Three headings: what happened, what changed, what to carry forward."
require_claim "${REFLECTIONS_README}" "that the incident log is AGENTS.md's" \
    'already has an **incident log**'

mapfile -t ENTRIES < <(
    cd "${REPO_ROOT}" && git ls-files 'docs/reflections/*.md' | grep -v '/README\.md$'
)
require_nonempty "at least one tracked reflection entry" "${ENTRIES[*]:-}"

# The three headings, in the order the README states them, as GitHub slugs, so
# the comparison is against the same form a link would have to use.
EXPECTED_HEADINGS="what-happened what-changed what-to-carry-forward"

for entry in "${ENTRIES[@]}"; do
    path="${REPO_ROOT}/${entry}"
    name="${entry##*/}"

    if [[ "${name}" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})-[a-z0-9]+(-[a-z0-9]+)*\.md$ ]]; then
        _pass "${name} is named YYYY-MM-DD-short-slug.md"
        file_date="${BASH_REMATCH[1]}"
    else
        _fail "${name} is named YYYY-MM-DD-short-slug.md" \
            "the README's format is a date, a hyphen, a lower-case hyphenated slug"
        continue
    fi

    if date -u -d "${file_date}" +%F >/dev/null 2>&1; then
        _pass "${name}'s date is a real calendar date"
    else
        _fail "${name}'s date is a real calendar date" "date -d rejected ${file_date}"
    fi

    # An entry opens with a title, then a bold date stamp: `**YYYY-MM-DD** —
    # topics`. The stamp is the date the lesson was learned, and the README
    # says the filename carries that same date.
    assert_eq "${name} opens with a level-one title" \
        "# " "$(head -c 2 "${path}")"
    stamp="$(sed -nE 's/^\*\*([0-9]{4}-[0-9]{2}-[0-9]{2})\*\* — .*$/\1/p' "${path}" | head -1)"
    if [[ -z "${stamp}" ]]; then
        _fail "${name} carries a **YYYY-MM-DD** — topics stamp" "no stamp line found"
    else
        assert_eq "${name}'s stamp matches its filename date" "${file_date}" "${stamp}"
    fi

    headings="$(outside_fences "${path}" |
        sed -nE 's/^## (.*[^[:space:]])[[:space:]]*$/\1/p' |
        while IFS= read -r heading; do slugify "${heading}"; printf '\n'; done |
        tr '\n' ' ' | sed 's/ $//')"
    assert_eq "${name} has the README's three headings, in order" \
        "${EXPECTED_HEADINGS}" "${headings}"
done

# The README's example of what the incident log answers names one of its
# entries. If that heading is renamed the example points at nothing.
incident_log="$(doc_section "${AGENTS}" "## Incident log")"
require_nonempty "an '## Incident log' section in AGENTS.md" "${incident_log}"
incident_example="$(after_phrase "$(flattened "${REFLECTIONS_README}")" 'incident log | ' 200 |
    grep -oE 'Fedora kernel [0-9.]+ vs OpenZFS [0-9.]+')"
require_nonempty "an incident-log example naming a kernel/ZFS pair in the README" "${incident_example}" &&
    assert_contains "the README's incident-log example is an entry AGENTS.md has" \
        "$(grep -E '^### ' <<<"${incident_log}")" "${incident_example}"

# =============================================================================
# 2. 2026-07-02 -- one manifest, many tags: the publish band of build.yml
# =============================================================================
#
# This entry is the document that explains why the single push, the
# server-side copy and the digest verification may not be simplified away.
# Each of its claims is a property of build.yml, recomputed here.

if ! "${WORKFLOW_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    _fail "reading the workflows requires Python 3 with PyYAML" \
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

normalize() {
    local file=$1 out=$2
    if ! "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${file}" >"${out}" 2>"${TMP_ROOT}/normalize.err"; then
        _fail "${file#"${REPO_ROOT}"/} parses" "$(cat "${TMP_ROOT}/normalize.err")"
        finish
        exit 1
    fi
    _pass "${file#"${REPO_ROOT}"/} parses"
}

BUILD_JSON="${TMP_ROOT}/build.json"
NIGHTLY_JSON="${TMP_ROOT}/nightly.json"
normalize "${BUILD_WF}" "${BUILD_JSON}"
normalize "${NIGHTLY_WF}" "${NIGHTLY_JSON}"

step_names() {
    jq -r --arg job "$2" '.jobs[$job].steps[] | .name // empty' <"$1"
}

step_index() {
    step_names "$1" "$2" | grep -nxF "$3" | head -1 | cut -d: -f1
}

step_field() {
    local json=$1 job=$2 name=$3 field=$4
    jq -r --arg job "${job}" --arg name "${name}" --arg field "${field}" \
        '.jobs[$job].steps[] | select(.name == $name) | .[$field] // empty' <"${json}"
}

step_with() {
    local json=$1 job=$2 name=$3 key=$4
    jq -r --arg job "${job}" --arg name "${name}" --arg key "${key}" \
        '.jobs[$job].steps[] | select(.name == $name) | .with[$key] // empty' <"${json}"
}

PUBLISH_JOB="build_push"
METADATA_STEP="Image Metadata"
PUSH_STEP="Push To GHCR"
PROPAGATE_STEP="Propagate tags from the pushed digest"
VERIFY_STEP="Verify pushed tags share one digest"
SIGN_STEP="Sign container image"
RECHUNK_STEP="Rechunk Image with Chunkah"

# shellcheck disable=SC2016
require_claim "${TAGS_ENTRY}" "the single push and the server-side copy" \
    'Push exactly one tag, then copy that manifest server-side to the others with `skopeo copy --preserve-digests`'
# shellcheck disable=SC2016
require_claim "${TAGS_ENTRY}" "the verification before signing" \
    'before signing, assert the property outright: `Verify pushed tags share one digest`'
require_claim "${TAGS_ENTRY}" "that signing operates on one digest" \
    'signing operates on **one digest**'
# shellcheck disable=SC2016
require_claim "${TAGS_ENTRY}" "the nightly re-check" \
    '`.github/workflows/nightly-compliance.yml` now re-checks this against the *published* registry'

# --- 2a. the tag set ----------------------------------------------------------
#
# "The workflow pushed the same local image once per tag: `latest`,
# `latest.YYYYMMDD`, `YYYYMMDD`." The published set is the `type=raw` lines of
# the metadata step with the workflow's own DEFAULT_TAG substituted; every other
# line has to be gated to pull requests, or the set the entry names is short.

default_tag="$(jq -r '.env.DEFAULT_TAG // empty' <"${BUILD_JSON}")"
require_nonempty "a DEFAULT_TAG in build.yml's env" "${default_tag}"

metadata_tags="$(step_with "${BUILD_JSON}" "${PUBLISH_JOB}" "${METADATA_STEP}" tags)"
require_nonempty "a tags: list on the '${METADATA_STEP}' step" "${metadata_tags}"

published_tags="$(
    grep -E '^type=raw,' <<<"${metadata_tags}" |
        sed -E 's/^type=raw,value=//' |
        sed -e "s/\${{ env.DEFAULT_TAG }}/${default_tag}/g" \
            -e "s/{{date 'YYYYMMDD'}}/YYYYMMDD/g"
)"
require_nonempty "type=raw tag lines on the '${METADATA_STEP}' step" "${published_tags}"

entry_tags="$(code_spans "$(after_phrase "$(flattened "${TAGS_ENTRY}")" 'once per tag:' 60)")"
require_nonempty "the tag list in the entry's opening sentence" "${entry_tags}"
assert_eq "the entry names exactly the tags the metadata step publishes" \
    "$(as_set <<<"${published_tags}")" "$(as_set <<<"${entry_tags}")"
assert_eq "the entry's 'three names' is the count of published tags" \
    "3" "$(grep -c . <<<"${published_tags}")"

other_tags="$(grep -vE '^type=raw,' <<<"${metadata_tags}" | grep -v '^$')"
while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    if [[ "${line}" == *"event=pr"* || "${line}" == *"github.event_name == 'pull_request'"* ]]; then
        _pass "non-raw tag line is pull-request only: ${line}"
    else
        _fail "non-raw tag line is pull-request only: ${line}" \
            "a tag published on main that the entry does not name"
    fi
done <<<"${other_tags}"

# --- 2b. one push, copies by digest, verified before the signature ------------

push_tags="$(step_with "${BUILD_JSON}" "${PUBLISH_JOB}" "${PUSH_STEP}" tags)"
require_nonempty "a tags: value on the '${PUSH_STEP}' step" "${push_tags}"
# An Actions expression carries spaces of its own, so it is folded to one token
# before the value is split into tags.
push_tag_count="$(sed -E 's/\$\{\{[^}]*\}\}/EXPR/g; s/[ ,]+/\n/g' <<<"${push_tags}" | grep -c .)"
assert_eq "'${PUSH_STEP}' pushes exactly one tag" "1" "${push_tag_count}"
assert_eq "and that tag is the default tag every other tag is copied from" \
    "\${{ env.DEFAULT_TAG }}" "${push_tags}"

propagate_body="$(step_field "${BUILD_JSON}" "${PUBLISH_JOB}" "${PROPAGATE_STEP}" run)"
require_nonempty "a run: body on the '${PROPAGATE_STEP}' step" "${propagate_body}"
assert_contains "the copy is skopeo copy --preserve-digests, in command position" \
    "$(grep -E '^[[:space:]]*skopeo copy --preserve-digests' <<<"${propagate_body}")" \
    "skopeo copy --preserve-digests"
# shellcheck disable=SC2016
assert_contains "the copy's source is the pushed digest, not a tag" \
    "${propagate_body}" '@${digest}'

push_idx="$(step_index "${BUILD_JSON}" "${PUBLISH_JOB}" "${PUSH_STEP}")"
propagate_idx="$(step_index "${BUILD_JSON}" "${PUBLISH_JOB}" "${PROPAGATE_STEP}")"
verify_idx="$(step_index "${BUILD_JSON}" "${PUBLISH_JOB}" "${VERIFY_STEP}")"
sign_idx="$(step_index "${BUILD_JSON}" "${PUBLISH_JOB}" "${SIGN_STEP}")"

if [[ -z "${push_idx}" || -z "${propagate_idx}" || -z "${verify_idx}" || -z "${sign_idx}" ]]; then
    _fail "build.yml still has the four publish-band steps the entry names" \
        "'${PUSH_STEP}' -> '${push_idx:-missing}', '${PROPAGATE_STEP}' -> '${propagate_idx:-missing}'," \
        "'${VERIFY_STEP}' -> '${verify_idx:-missing}', '${SIGN_STEP}' -> '${sign_idx:-missing}'"
else
    if [[ "${push_idx}" -lt "${propagate_idx}" && "${propagate_idx}" -lt "${verify_idx}" && "${verify_idx}" -lt "${sign_idx}" ]]; then
        _pass "the band runs push, copy, verify, sign -- the verification is before signing"
    else
        _fail "the band runs push, copy, verify, sign -- the verification is before signing" \
            "steps ${push_idx}, ${propagate_idx}, ${verify_idx}, ${sign_idx} are not ascending"
    fi
fi

verify_body="$(step_field "${BUILD_JSON}" "${PUBLISH_JOB}" "${VERIFY_STEP}" run)"
require_nonempty "a run: body on the '${VERIFY_STEP}' step" "${verify_body}"
# shellcheck disable=SC2016
assert_contains "the verification resolves every published tag" \
    "${verify_body}" 'for tag in ${TAGS}'
assert_contains "and compares each tag's digest" "${verify_body}" "{{.Digest}}"
assert_contains "against the digest the push step exposed" \
    "$(step_field "${BUILD_JSON}" "${PUBLISH_JOB}" "${VERIFY_STEP}" env)" \
    "steps.push.outputs.digest"
assert_eq "the verification's tag list is the metadata step's, so no tag is skipped" \
    "$(jq -r --arg job "${PUBLISH_JOB}" --arg name "${VERIFY_STEP}" \
        '.jobs[$job].steps[] | select(.name == $name) | .env.TAGS // empty' <"${BUILD_JSON}")" \
    "\${{ steps.metadata.outputs.tags }}"

sign_body="$(step_field "${BUILD_JSON}" "${PUBLISH_JOB}" "${SIGN_STEP}" run)"
require_nonempty "a run: body on the '${SIGN_STEP}' step" "${sign_body}"
# shellcheck disable=SC2016
assert_contains "cosign signs the pushed digest" "${sign_body}" '@${DIGEST}'
assert_not_contains "and not a tag" "${sign_body}" ":\${DEFAULT_TAG}"
assert_contains "the digest it signs is the one the verification checked" \
    "$(step_field "${BUILD_JSON}" "${PUBLISH_JOB}" "${SIGN_STEP}" env)" \
    "steps.push.outputs.digest"

# --- 2c. the nightly re-check against the published registry ----------------

NIGHTLY_JOB="published_image"
NIGHTLY_VERIFY_STEP="Verify the date tags still share that digest"
nightly_body="$(step_field "${NIGHTLY_JSON}" "${NIGHTLY_JOB}" "${NIGHTLY_VERIFY_STEP}" run)"
require_nonempty "a run: body on the nightly '${NIGHTLY_VERIFY_STEP}' step" "${nightly_body}"
assert_contains "the nightly re-check reads the published registry" \
    "${nightly_body}" "skopeo inspect"
assert_contains "and compares digests" "${nightly_body}" "{{.Digest}}"
assert_contains "against the digest :latest resolves to" \
    "$(step_field "${NIGHTLY_JSON}" "${NIGHTLY_JOB}" "${NIGHTLY_VERIFY_STEP}" env)" \
    "steps.latest.outputs.digest"

# =============================================================================
# 3. 2026-08-25 -- large JSON through the environment: the Chunkah numbers
# =============================================================================
#
# The same numbers and field names are written in three places: this entry,
# AGENTS.md's diagnosis, and the rechunk step's own comment in build.yml.
# Nothing held the copies equal. Each set is read out of all three and compared,
# and the arithmetic in the cap is checked rather than trusted.

require_claim "${CHUNKAH_ENTRY}" "the .Config read" \
    "The step now passes \`--format '{{json .Config}}'\`"
# shellcheck disable=SC2016
require_claim "${CHUNKAH_ENTRY}" "the environment variable" \
    '`CHUNKAH_CONFIG_STR`, an environment variable'
require_claim "${CHUNKAH_ENTRY}" "the three per-layer fields" \
    'embeds per-layer data three times over'
# shellcheck disable=SC2016
require_claim "${CHUNKAH_ENTRY}" "the cap" 'caps a single argv/env string at `MAX_ARG_STRLEN`'

# shellcheck disable=SC2016
chunkah_section="$(doc_section "${AGENTS}" '### Chunkah rechunk: `Argument list too long` (exit 126)')"
require_nonempty "the Chunkah diagnosis section in AGENTS.md" "${chunkah_section}"

rechunk_body="$(step_field "${BUILD_JSON}" "${PUBLISH_JOB}" "${RECHUNK_STEP}" run)"
require_nonempty "a run: body on the '${RECHUNK_STEP}' step" "${rechunk_body}"

# shellcheck disable=SC2016
config_assignment="$(grep -F 'CHUNKAH_CONFIG_STR="$(' <<<"${rechunk_body}")"
require_nonempty "the rechunk step's CHUNKAH_CONFIG_STR assignment" "${config_assignment}" &&
    assert_contains "the rechunk step reads .Config, as the entry says" \
        "${config_assignment}" "--format '{{json .Config}}'"
assert_contains "and hands it to podman as an environment variable" \
    "${rechunk_body}" "-e CHUNKAH_CONFIG_STR"

entry_flat="$(flattened "${CHUNKAH_ENTRY}")"
agents_flat="$(flattened <(printf '%s\n' "${chunkah_section}"))"
rechunk_flat="$(flattened <(printf '%s\n' "${rechunk_body}"))"

# The three fields: the entry and AGENTS.md list them as code spans right after
# "three times over"; the workflow comment lists them as prose after "also
# carries". Compared as sets, both directions.
entry_fields="$(code_spans "$(after_phrase "${entry_flat}" 'three times over' 80)" | as_set)"
agents_fields="$(code_spans "$(after_phrase "${agents_flat}" 'three times over' 80)" | as_set)"
workflow_fields="$(after_phrase "${rechunk_flat}" 'also carries ' 80 |
    sed -E 's/, all of which.*$//' | sed -E 's/,? and /\n/g; s/, /\n/g' | as_set)"
require_nonempty "the entry's field list" "${entry_fields}"
require_nonempty "AGENTS.md's field list" "${agents_fields}"
require_nonempty "the workflow comment's field list" "${workflow_fields}"
assert_eq "the entry's three fields are AGENTS.md's" "${agents_fields}" "${entry_fields}"
assert_eq "and the workflow comment's" "${workflow_fields}" "${entry_fields}"
assert_eq "and there are three of them" "3" "$(wc -w <<<"${entry_fields}")"

# The cap, with its arithmetic: N pages = M KiB has to hold at 4 KiB pages.
entry_cap="$(grep -oE '[0-9]+ pages = [0-9]+ KiB' <<<"${entry_flat}" | head -1)"
agents_cap="$(grep -oE '[0-9]+ pages = [0-9]+ KiB' <<<"${agents_flat}" | head -1)"
workflow_cap="$(grep -oE '[0-9]+ pages = [0-9]+ KiB' <<<"${rechunk_flat}" | head -1)"
require_nonempty "the entry's 'N pages = M KiB' cap" "${entry_cap}"
assert_eq "AGENTS.md states the same cap" "${entry_cap}" "${agents_cap}"
assert_eq "and so does the rechunk step's comment" "${entry_cap}" "${workflow_cap}"
if [[ "${entry_cap}" =~ ^([0-9]+)\ pages\ =\ ([0-9]+)\ KiB$ ]]; then
    assert_eq "${entry_cap} is arithmetically right at 4 KiB pages" \
        "$((BASH_REMATCH[1] * 4))" "${BASH_REMATCH[2]}"
fi

# The layer growth and the .Config size the entry credits the fix with.
entry_layers="$(grep -oE 'from [0-9]+ to [0-9]+ layers' <<<"${entry_flat}" | head -1)"
agents_layers="$(grep -oE 'from [0-9]+ to [0-9]+ layers' <<<"${agents_flat}" | head -1)"
workflow_layers="$(grep -oE 'from [0-9]+ to [0-9]+ layers' <<<"${rechunk_flat}" | head -1)"
require_nonempty "the entry's layer growth" "${entry_layers}"
assert_eq "AGENTS.md records the same layer growth" "${entry_layers}" "${agents_layers}"
assert_eq "and so does the rechunk step's comment" "${entry_layers}" "${workflow_layers}"

entry_config="$(grep -oE '(around|~)[[:space:]]?[0-9.]+ KiB' <<<"${entry_flat}" | grep -oE '[0-9.]+ KiB' | head -1)"
agents_config="$(grep -oE '(around|~)[[:space:]]?[0-9.]+ KiB' <<<"${agents_flat}" | grep -oE '[0-9.]+ KiB' | head -1)"
workflow_config="$(grep -oE '(around|~)[[:space:]]?[0-9.]+ KiB' <<<"${rechunk_flat}" | grep -oE '[0-9.]+ KiB' | head -1)"
require_nonempty "the entry's .Config size" "${entry_config}"
assert_eq "AGENTS.md gives the same .Config size" "${entry_config}" "${agents_config}"
assert_eq "and so does the rechunk step's comment" "${entry_config}" "${workflow_config}"

# The symptom the entry quotes is the one AGENTS.md's heading names.
assert_contains "the entry quotes the exit code AGENTS.md's heading carries" \
    "$(fenced_text="$(awk '/^```/ { fenced = !fenced; next } fenced' "${CHUNKAH_ENTRY}")"; printf '%s' "${fenced_text}")" \
    "exit code 126"
assert_contains "and the step name the diagnosis is filed under" \
    "${entry_flat}" "\`${RECHUNK_STEP}\`"

# =============================================================================
# 4. 2026-09-03 -- prose an agent is told to trust
# =============================================================================
#
# The entry carries a dated correction: the README.md / AGENTS.md relationship
# was recorded backwards. The corrected direction is true today with nothing
# asserting it, so both halves are asserted here. The historical wrong path is
# quoted on purpose and is only a historical record while it stays absent.

# shellcheck disable=SC2016
require_claim "${PROSE_ENTRY}" "the corrected direction" \
    '`README.md` is the entry document and directs readers with a failed build to `AGENTS.md`'
# shellcheck disable=SC2016
require_claim "${PROSE_ENTRY}" "that AGENTS.md does not point back" \
    '`AGENTS.md` has never pointed to `README.md`'
# shellcheck disable=SC2016
require_claim "${PROSE_ENTRY}" "the historical wrong path" \
    '`README.md` advertised a Renovate config at `.github/renovate.json5`'
# shellcheck disable=SC2016
require_claim "${PROSE_ENTRY}" "where the file actually is" \
    'The file was `renovate.json`, at the repo root'
require_claim "${PROSE_ENTRY}" "the tier ordering" \
    'puts load-bearing prose above self-checking test code'

readme_flat="$(flattened <(outside_fences "${README}"))"
assert_contains "README.md links a reader with a failed build to AGENTS.md" \
    "$(grep -oE 'failed[^)]*\]\(AGENTS\.md[^)]*\)' <<<"${readme_flat}" | head -1)" \
    "](AGENTS.md"
assert_eq "AGENTS.md does not point back at README.md" \
    "" "$(outside_fences "${AGENTS}" | grep -F 'README.md' || true)"

assert_file_missing "the historical path .github/renovate.json5 stays absent" \
    "${REPO_ROOT}/.github/renovate.json5"
assert_file_exists "renovate.json is at the repo root" "${REPO_ROOT}/renovate.json"

# What the entry says tests/test-docs-paths.sh does.
docs_paths_text="$(cat "${DOCS_PATHS_TEST}")"
assert_contains "test-docs-paths.sh reads README.md's Repository Layout block" \
    "${docs_paths_text}" "Repository Layout"
assert_contains "and anchors its filter on git ls-files" \
    "${docs_paths_text}" "git ls-files"

# The trigger gap: build.yml ignores README.md and docs/**, and the coverage
# gate triggers on that complement.
build_ignores="$(jq -r '.on.pull_request["paths-ignore"][]? // empty' <"${BUILD_JSON}" | as_set)"
require_nonempty "a paths-ignore on build.yml's pull_request trigger" "${build_ignores}"
assert_contains "build.yml ignores README.md on pull requests" "${build_ignores}" "README.md"
assert_contains "and docs/**" "${build_ignores}" "docs/**"
COVERAGE_JSON="${TMP_ROOT}/coverage.json"
normalize "${COVERAGE_WF}" "${COVERAGE_JSON}"
coverage_paths="$(jq -r '.on.pull_request.paths[]? // empty' <"${COVERAGE_JSON}" | as_set)"
require_nonempty "a paths list on coverage-gate.yml's pull_request trigger" "${coverage_paths}"
assert_contains "coverage-gate.yml triggers on README.md" "${coverage_paths}" "README.md"
assert_contains "and on docs/**" "${coverage_paths}" "docs/**"

# docs/risk-tiers.md: load-bearing prose sits above self-checking test code.
tier_rows="$(table_rows <"${RISK_TIERS}")"
require_nonempty "a tier table in docs/risk-tiers.md" "${tier_rows}"
prose_row=""
selfcheck_row=""
row_no=0
while IFS= read -r row; do
    [[ -z "${row}" ]] && continue
    row_no=$((row_no + 1))
    first="$(cell "${row}" 1)"
    case "${first}" in
    *"Load-bearing prose"*) prose_row="${row_no}" ;;
    *"Self-checking"*) selfcheck_row="${row_no}" ;;
    *) ;;
    esac
done <<<"${tier_rows}"
if [[ -z "${prose_row}" || -z "${selfcheck_row}" ]]; then
    _fail "the tier table still has a load-bearing prose tier and a self-checking tier" \
        "prose row: '${prose_row:-missing}', self-checking row: '${selfcheck_row:-missing}'"
elif [[ "${prose_row}" -lt "${selfcheck_row}" ]]; then
    _pass "load-bearing prose is ranked above self-checking test code"
else
    _fail "load-bearing prose is ranked above self-checking test code" \
        "prose is row ${prose_row}, self-checking is row ${selfcheck_row}"
fi
assert_contains "and docs/** is what the prose tier covers" \
    "$(sed -n "${prose_row:-0}p" <<<"$(grep -v '^$' <<<"${tier_rows}")")" 'docs/**'
assert_contains "while tests/** is what the self-checking tier covers" \
    "$(sed -n "${selfcheck_row:-0}p" <<<"$(grep -v '^$' <<<"${tier_rows}")")" 'tests/**'

# =============================================================================
# 5. Every docs/reflections/<file> cited from a non-Markdown file exists
# =============================================================================
#
# .github/workflows/auto-qa.yml cites an entry by path in a comment, and so do
# tests. tests/test-docs-paths.sh only reads Markdown, so a cite from a
# workflow or a test that outlives a rename pointed nowhere with nothing
# noticing. A path that wraps across two lines cannot be resolved by anyone
# and counts as broken.

# Only something shaped like an entry counts as a cite: README.md or a dated
# YYYY-MM-DD-slug.md. That excludes globs, the <file> placeholder in prose,
# and this test's own pattern, and because a match must end in .md the
# sentence's trailing period never rides along.
cited="$(cd "${REPO_ROOT}" && git grep -ohE 'docs/reflections/(README|[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9-]+)\.md' -- ':!*.md' |
    as_set)"
require_nonempty "citations of docs/reflections/ from non-Markdown files" "${cited}"
for cite in ${cited}; do
    if (cd "${REPO_ROOT}" && git ls-files --error-unmatch "${cite}" >/dev/null 2>&1); then
        _pass "${cite} is a tracked file"
    else
        _fail "${cite} is a tracked file" \
            "cited from a non-Markdown file, which nothing else resolves"
    fi
done

finish
