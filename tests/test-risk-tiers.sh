#!/usr/bin/env bash
#
# docs/risk-tiers.md, against the tree it classifies.
#
# The document is the repository's shared vocabulary for "how dangerous is this
# change": four tiers, a path set per tier, and a statement of what CI does and
# does not prove at each one. It is load-bearing prose by its own table -- a
# reviewer who reads it decides what evidence to ask for, and .github/workflows/
# and docs/SECURITY-AI.md both cite it when they explain why something needs a
# human.
#
# Nothing checked it as a document. test-docs-paths.sh resolves its Markdown
# *links* (and their #anchors), and two other tests reach in for one row each --
# test-reflections.sh for the tier order, test-pull-request-template.sh for the
# tier 1 row naming README.md and AGENTS.md. The parts that decide what the
# document means were unverified:
#
#   * the Paths column, whose entries are globs and therefore invisible to the
#     code-span pass in test-docs-paths.sh (which is deliberately conservative
#     and skips globs, and only reads README.md and AGENTS.md anyway),
#   * the rule "a change takes the highest tier it touches", stated with a
#     worked example that nothing replayed,
#   * the per-tier evidence claims about what `Build container image` runs, what
#     it skips, and which pull requests start it at all, and
#   * the closing claim that the classification is advisory -- that no
#     automation stamps a tier on a pull request.
#
# A path set that drifts is the failure this repository has already had once
# (issue #70, README.md advertising a renovate path that had moved). Here it
# fails quieter: a tier row whose glob matches nothing still reads as a rule,
# and the change it was meant to catch merges on green CI.
#
# So the tiers are parsed out of the table and replayed rather than restated. A
# restated rule is a second copy that drifts; a parsed one fails when the
# document changes under it, which is the point.

set -uo pipefail

TEST_NAME="test-risk-tiers"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=tests/lib/markdown.sh
source "${TEST_DIR}/lib/markdown.sh"

RISK_TIERS="${REPO_ROOT}/docs/risk-tiers.md"
BUILD_WF="${REPO_ROOT}/.github/workflows/build.yml"
AUTO_QA_WF="${REPO_ROOT}/.github/workflows/auto-qa.yml"
LABELER_CONFIG="${REPO_ROOT}/.github/labeler.yml"
CONTAINERFILE="${REPO_ROOT}/Containerfile"
QUALITY="${REPO_ROOT}/docs/quality.md"
SECURITY_AI="${REPO_ROOT}/docs/SECURITY-AI.md"
CONTRIBUTING="${REPO_ROOT}/CONTRIBUTING.md"
E2E_RUNNER="${REPO_ROOT}/tests/e2e/run-e2e.sh"

missing=0
for required in \
    "${RISK_TIERS}" "${BUILD_WF}" "${AUTO_QA_WF}" "${LABELER_CONFIG}" \
    "${CONTAINERFILE}" "${QUALITY}" "${SECURITY_AI}" "${CONTRIBUTING}" \
    "${E2E_RUNNER}"; do
    [[ -f "${required}" ]] && continue
    _fail "${required#"${REPO_ROOT}"/} is present" "no such file"
    missing=1
done

if [[ "${missing}" -ne 0 ]]; then
    finish
    exit
fi

# --- helpers ----------------------------------------------------------------

# A file with its line breaks collapsed, so a claim is matched as a sentence
# rather than at whatever column the prose happened to wrap at. The `> ` and
# `# ` line decorations are stripped first for the same reason.
flattened() {
    sed -E 's/^[[:space:]]*(> ?|# ?)//' "$1" | tr '\n' ' ' | tr -s '[:space:]' ' '
}

# A sentence this file goes on to verify has to still be in the document. If it
# is gone, the assertions below are checking the tree against nothing.
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

# An extraction that matched nothing is an unverified document, not a pass.
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

# Every backtick span on stdin, one per line, backticks stripped.
code_spans() {
    grep -o "\`[^\`]*\`" | sed -e "s/^\`//" -e "s/\`$//"
}

# The document's globs are written the way .github/labeler.yml and a workflow
# `paths:` list write them, so they are translated the same way: `**` crosses
# directory separators, a lone `*` does not, and a trailing slash means "this
# directory and everything under it". Everything else is a literal.
glob_to_regex() {
    local glob=$1 out='' char
    [[ "${glob}" == */ ]] && glob="${glob}**"
    while [[ -n "${glob}" ]]; do
        if [[ "${glob}" == '**'* ]]; then
            out+='.*'
            glob=${glob:2}
            continue
        fi
        char=${glob:0:1}
        glob=${glob:1}
        case "${char}" in
            '*') out+='[^/]*' ;;
            '.' | '+' | '(' | ')' | '[' | ']' | '{' | '}' | '^' | '$' | '|' | '?' | \\) out+="\\${char}" ;;
            *) out+="${char}" ;;
        esac
    done
    printf '^%s$' "${out}"
}

TRACKED="$(cd "${REPO_ROOT}" && git ls-files)"

# How many tracked files a glob claims. Zero is the drift this file exists to
# catch: a rule about paths that are no longer there.
tracked_match_count() {
    grep -cE -- "$(glob_to_regex "$1")" <<<"${TRACKED}"
}

glob_matches_tracked() {
    [[ "$(tracked_match_count "$1")" -gt 0 ]]
}

require_nonempty "a tracked file list to resolve the tiers against" "${TRACKED}"

# --- the tier table ---------------------------------------------------------
#
# Bounded by its own heading, so a second table added later under a different
# heading does not silently join the tier set.

table_rows=$(
    awk '
        /^## The tiers$/ { in_section = 1; next }
        in_section && /^## /        { exit }
        in_section && /^\| \*\*[0-9]/ { print }
    ' "${RISK_TIERS}"
)

if ! require_nonempty "a tier table under '## The tiers'" "${table_rows}"; then
    finish
    exit
fi

# tier number -> the row's three remaining cells, kept in parallel arrays
# because the Paths cell is consulted from several checks below.
declare -A TIER_LABEL=() TIER_BLAST=() TIER_PATHS=() TIER_MERGE=()
tier_order=()

while IFS= read -r row; do
    [[ -z "${row}" ]] && continue
    # | **3 — Published artifact** | blast radius | paths | merge answer |
    body=${row#\|}
    body=${body%\|}
    IFS='|' read -r c_tier c_blast c_paths c_merge <<<"${body}"

    tier_field=$(sed -E 's/^[[:space:]]*\*\*//; s/\*\*[[:space:]]*$//' <<<"${c_tier}")
    number=$(sed -E 's/^([0-9]+).*/\1/' <<<"${tier_field}")

    if [[ ! "${number}" =~ ^[0-9]+$ ]]; then
        _fail "tier row starts with a tier number" "unparsed row: ${row}"
        continue
    fi

    tier_order+=("${number}")
    TIER_LABEL["${number}"]="${tier_field}"
    TIER_BLAST["${number}"]="${c_blast}"
    TIER_PATHS["${number}"]="${c_paths}"
    TIER_MERGE["${number}"]="$(sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//' <<<"${c_merge}")"
done <<<"${table_rows}"

assert_eq "the table lists four tiers" "4" "${#tier_order[@]}"

# Descending, because every relational claim in the prose below -- "tier 1 sits
# above tier 0", "only below tier 2", "it takes the highest tier it touches" --
# reads the table as an ordering rather than a set of labels.
assert_eq "the tiers run highest blast radius first" \
    "3 2 1 0" "${tier_order[*]}"

for tier in "${tier_order[@]}"; do
    # "3 — Published artifact": the number alone is not a vocabulary, and the
    # name is what a pull request description actually says.
    require_nonempty "a name for tier ${tier}" "${TIER_LABEL[${tier}]#"${tier}"}"
    require_nonempty "a blast radius for tier ${tier}" "${TIER_BLAST[${tier}]}"
    require_nonempty "a path set for tier ${tier}" "${TIER_PATHS[${tier}]}"
    require_nonempty "a merge answer for tier ${tier}" "${TIER_MERGE[${tier}]}"
done

# --- the Paths column names paths that exist --------------------------------
#
# Each cell is a comma-separated list of prose and backticked globs; the globs
# are the claim. A glob matching nothing tracked is a rule that has quietly
# stopped applying to anything.

declare -A TIER_GLOBS=()

for tier in "${tier_order[@]}"; do
    globs=$(code_spans <<<"${TIER_PATHS[${tier}]}")
    require_nonempty "at least one path in the tier ${tier} row" "${globs}"
    TIER_GLOBS["${tier}"]="${globs}"

    while IFS= read -r glob; do
        [[ -z "${glob}" ]] && continue
        count=$(tracked_match_count "${glob}")
        if [[ "${count}" -gt 0 ]]; then
            _pass "tier ${tier} path matches ${count} tracked file(s): ${glob}"
        else
            _fail "tier ${tier} path matches a tracked file: ${glob}" \
                "no tracked path matches it; the tier row classifies nothing"
        fi
    done <<<"${globs}"
done

# --- "it takes the highest tier it touches" ---------------------------------
#
# The rule replayed against the parsed table rather than restated. classify()
# is the document's own procedure: take every tier whose path set matches, keep
# the highest.

classify() {
    local path=$1 tier glob best=''
    for tier in "${tier_order[@]}"; do
        while IFS= read -r glob; do
            [[ -z "${glob}" ]] && continue
            if [[ "${path}" =~ $(glob_to_regex "${glob}") ]]; then
                if [[ -z "${best}" || "${tier}" -gt "${best}" ]]; then
                    best="${tier}"
                fi
            fi
        done <<<"${TIER_GLOBS[${tier}]}"
    done
    printf '%s' "${best}"
}

assert_eq "a shipped build script is the published-artifact tier" \
    "3" "$(classify build_files/zfs.sh)"
assert_eq "a test file is the self-checking tier" \
    "0" "$(classify tests/run-tests.sh)"
assert_eq "a document is the load-bearing-prose tier" \
    "1" "$(classify docs/quality.md)"
assert_eq "a dependency pin is the pipeline tier" \
    "2" "$(classify renovate.json)"

# The agent permission boundary. Both files match the tier 1 `.claude/**` glob
# as well, so these two assertions are also the highest-tier rule doing its job:
# if the top row stops naming them, they fall back to prose and the table says a
# widened allow rule merges on a green doc suite.
assert_eq "the permission table is the published-artifact tier" \
    "3" "$(classify .claude/settings.json)"
assert_eq "the PreToolUse gate is the published-artifact tier" \
    "3" "$(classify .claude/hooks/gate-git-diff.sh)"
# The rest of .claude/ is prose and stays there; a tier that swallowed the whole
# directory would make every session-summary edit need a human.
assert_eq "a session summary is still the load-bearing-prose tier" \
    "1" "$(classify .claude/session-summary.md)"

# The worked example, taken from the sentence rather than from this file's
# memory of it: both paths it names are classified, and the stated answer has to
# be the higher of the two.
mixed_claim="A pull request that edits \`tests/\` and one line of \`build_files/\` is Tier 3."
if require_claim "${RISK_TIERS}" "a change spanning tiers takes the highest" "${mixed_claim}"; then
    stated_tier=$(sed -E 's/.*is Tier ([0-9]+)\..*/\1/' <<<"${mixed_claim}")
    example_best=''
    example_tiers=()
    while IFS= read -r span; do
        [[ -z "${span}" ]] && continue
        got=$(classify "${span}x")
        example_tiers+=("${got}")
        if [[ -n "${got}" && ( -z "${example_best}" || "${got}" -gt "${example_best}" ) ]]; then
            example_best="${got}"
        fi
    done < <(code_spans <<<"${mixed_claim}")

    assert_eq "the example names two paths" "2" "${#example_tiers[@]}"
    # If both landed in the same tier the example would not exercise the rule.
    if [[ "${#example_tiers[@]}" -eq 2 ]]; then
        if [[ "${example_tiers[0]}" != "${example_tiers[1]}" ]]; then
            _pass "the example spans two different tiers"
        else
            _fail "the example spans two different tiers" \
                "both paths classify as tier ${example_tiers[0]}, so it demonstrates nothing"
        fi
    fi
    assert_eq "the highest tier the example touches is the tier it states" \
        "${stated_tier}" "${example_best}"
fi

# --- the merge column, against docs/SECURITY-AI.md --------------------------
#
# The column answers "merge on green CI alone?", and docs/SECURITY-AI.md answers
# the same question for an agent in its own words. They have to agree, because
# the security document is the one an agent is told to obey and this table is the
# one a human reads.

merge_answer() {
    local tier=$1
    case "${TIER_MERGE[${tier}]}" in
        Yes*) printf 'Yes' ;;
        '**No.**'* | No*) printf 'No' ;;
        *) printf 'unparsed' ;;
    esac
}

assert_eq "docs are mergeable on a green suite" "Yes" "$(merge_answer "$(classify docs/quality.md)")"
assert_eq "tests are mergeable on a green suite" "Yes" "$(merge_answer "$(classify tests/run-tests.sh)")"
assert_eq "the Containerfile is not" "No" "$(merge_answer "$(classify Containerfile)")"
assert_eq "the signing key's public half is not" "No" "$(merge_answer "$(classify cosign.pub)")"
assert_eq "the permission table is not" "No" "$(merge_answer "$(classify .claude/settings.json)")"
assert_eq "the PreToolUse gate is not" "No" "$(merge_answer "$(classify .claude/hooks/gate-git-diff.sh)")"

security_free=$(
    awk '
        /^## What an agent may do unattended$/ { in_section = 1; next }
        in_section && /^Requires a human decision first/ { exit }
        in_section
    ' "${SECURITY_AI}"
)
if require_nonempty "docs/SECURITY-AI.md's free-to-do list" "${security_free}"; then
    assert_contains "docs/SECURITY-AI.md lets an agent edit docs unattended" \
        "${security_free}" "docs"
    assert_contains "docs/SECURITY-AI.md lets an agent edit tests unattended" \
        "${security_free}" "tests"
fi

# The middle list: what needs a human first. The two boundary files are in the
# top tier of the table above, and a tier answer no agent-facing document
# repeats is one an agent never reads, so the claim is checked on both sides.
security_human=$(
    awk '
        /^Requires a human decision first/ { in_section = 1; next }
        in_section && /^Never, under any circumstances/ { exit }
        in_section
    ' "${SECURITY_AI}"
)
if require_nonempty "docs/SECURITY-AI.md's human-decision list" "${security_human}"; then
    assert_contains "it names the permission table" \
        "${security_human}" ".claude/settings.json"
    assert_contains "it names the PreToolUse gate" \
        "${security_human}" ".claude/hooks/gate-git-diff.sh"
fi

security_never=$(
    awk '
        /^Never, under any circumstances/ { in_section = 1; next }
        in_section && /^## /              { exit }
        in_section
    ' "${SECURITY_AI}"
)
if require_nonempty "docs/SECURITY-AI.md's never-unattended list" "${security_never}"; then
    # The overlap the document calls "not a coincidence": the thing an agent may
    # never do unattended is the thing the top tier is drawn around.
    assert_contains "signing is what docs/SECURITY-AI.md forbids unattended" \
        "${security_never}" "sign"
    assert_contains "and the published-artifact tier is drawn around signing" \
        "${TIER_PATHS[3]}" "sign"
fi

# --- the published-artifact tier names real steps in build.yml --------------
#
# The tier 3 cell does not claim the whole workflow: it claims the push, verify
# and sign steps of it. Those three verbs are read out of the cell, matched to
# real step names, and each matching step has to carry the guard that keeps it
# off a pull request -- which is the reason the tier exists.

verbs=$(sed -E 's#.*the ([a-z/]+) steps of.*#\1#' <<<"${TIER_PATHS[3]}" | tr '/' ' ')
require_nonempty "a list of the build.yml steps the top tier covers" "${verbs}"

build_guard="github.event_name != 'pull_request'"

for verb in ${verbs}; do
    steps=$(grep -nE "^      - name: .*" "${BUILD_WF}" | grep -iE "name: .*${verb}")
    if [[ -z "${steps}" ]]; then
        _fail "build.yml has a ${verb} step" \
            "the tier 3 row names '${verb}' steps of build.yml; none is there"
        continue
    fi
    _pass "build.yml has a ${verb} step"

    while IFS= read -r step; do
        [[ -z "${step}" ]] && continue
        line=${step%%:*}
        name=$(sed -E 's/^[0-9]+:[[:space:]]*- name:[[:space:]]*//' <<<"${step}")
        # The step's own body: from its name line to the next step's.
        body=$(awk -v start="${line}" 'NR > start { if ($0 ~ /^      - name:/) exit; print }' "${BUILD_WF}")
        if [[ "${body}" == *"${build_guard}"* ]]; then
            _pass "the ${verb} step is off on a pull request: ${name}"
        else
            _fail "the ${verb} step is off on a pull request: ${name}" \
                "no ${build_guard} guard, so a pull request reaches a tier 3 action"
        fi
    done <<<"${steps}"
done

# --- what a green build does and does not prove -----------------------------

assert_eq "the workflow the evidence section names is build.yml's" \
    "Build container image" "$(sed -nE 's/^name: (.*)$/\1/p' "${BUILD_WF}" | head -1)"

# "it builds the whole image and runs build_files/post-check.sh and `bootc
# container lint` inside it" -- inside meaning RUN steps in the Containerfile,
# not workflow steps, which is what makes them run on a pull request too.
runs_claim="it builds the whole image and runs \`build_files/post-check.sh\` and \`bootc container lint\` inside it"
if require_claim "${RISK_TIERS}" "the build runs post-check and the bootc lint inside the image" "${runs_claim}"; then
    containerfile_body=$(flattened "${CONTAINERFILE}")
    assert_contains "the Containerfile runs post-check.sh" \
        "${containerfile_body}" "post-check.sh"
    assert_contains "the Containerfile runs the bootc lint" \
        "${containerfile_body}" "RUN bootc container lint"
fi

# "it does not validate the artifact on the far side of the Chunkah rechunk."
# The negative is the load-bearing half, so it is checked as a negative: after
# the rechunk step, nothing runs either check again.
after_rechunk=$(awk '/^      - name: Rechunk Image with Chunkah$/ { found = 1; next } found' "${BUILD_WF}")
if require_nonempty "steps after the rechunk step in build.yml" "${after_rechunk}"; then
    assert_not_contains "nothing re-runs post-check.sh after the rechunk" \
        "${after_rechunk}" "post-check.sh"
    assert_not_contains "nothing re-runs the bootc lint after the rechunk" \
        "${after_rechunk}" "bootc container lint"
fi

# docs/quality.md is cited as the blunt version of the same gap, so it has to
# still say it.
assert_contains "docs/quality.md still states the gap the tier 3 evidence defers to" \
    "$(flattened "${QUALITY}")" "There is no automated check on the far side of the rechunk."

# The local run offered in its place has to be a real mode of the runner, not a
# flag it silently ignores.
rechunk_claim="a local \`tests/e2e/run-e2e.sh --rechunk\` run"
if require_claim "${RISK_TIERS}" "a local rechunk run is the way to cover that gap" "${rechunk_claim}"; then
    if grep -qE '^[[:space:]]*--rechunk\)' "${E2E_RUNNER}"; then
        _pass "tests/e2e/run-e2e.sh parses --rechunk as an option"
    else
        _fail "tests/e2e/run-e2e.sh parses --rechunk as an option" \
            "no --rechunk) case arm; the documented command does nothing extra"
    fi
    assert_contains "and --rechunk turns the rechunk mode on" \
        "$(flattened "${E2E_RUNNER}")" "RECHUNK=1"
fi

# --- the tier 1 evidence claim about paths-ignore ---------------------------
#
# "A docs-only pull request starts no `Build container image` run at all --
# `build.yml` sets `paths-ignore` for `README.md` and `docs/**`". The two paths
# are read out of the sentence and checked against the workflow's real
# pull_request filter, then the consequence is replayed: a docs-only change
# matches the filter, a Containerfile change does not.

ignore_claim="\`build.yml\` sets \`paths-ignore\` for \`README.md\` and \`docs/**\`"
pr_ignores=$(
    awk '
        /^  pull_request:/   { in_pr = 1; next }
        in_pr && /^  [a-z_]+:/ { exit }
        in_pr && /^    paths-ignore:/ { in_list = 1; next }
        in_list && /^      - / { gsub(/^      - .|.$/, ""); print; next }
        in_list { exit }
    ' "${BUILD_WF}"
)

if require_nonempty "a pull_request paths-ignore list in build.yml" "${pr_ignores}" &&
    require_claim "${RISK_TIERS}" "build.yml ignores README.md and docs/**" "${ignore_claim}"; then
    while IFS= read -r claimed; do
        [[ -z "${claimed}" ]] && continue
        [[ "${claimed}" == "build.yml" || "${claimed}" == "paths-ignore" ]] && continue
        if grep -qxF "${claimed}" <<<"${pr_ignores}"; then
            _pass "build.yml's pull_request filter really ignores ${claimed}"
        else
            _fail "build.yml's pull_request filter really ignores ${claimed}" \
                "not in paths-ignore: ${pr_ignores//$'\n'/, }"
        fi
    done < <(code_spans <<<"${ignore_claim}")

    # The consequence, replayed against the filter as GitHub applies it: a pull
    # request whose every path is ignored starts no run.
    starts_build() {
        local path ignored
        for path in "$@"; do
            ignored=0
            while IFS= read -r pattern; do
                [[ -z "${pattern}" ]] && continue
                if [[ "${path}" =~ $(glob_to_regex "${pattern}") ]]; then
                    ignored=1
                    break
                fi
            done <<<"${pr_ignores}"
            [[ "${ignored}" -eq 0 ]] && return 0
        done
        return 1
    }

    if ! starts_build docs/risk-tiers.md docs/quality.md; then
        _pass "a docs-only pull request starts no Build container image run"
    else
        _fail "a docs-only pull request starts no Build container image run" \
            "a docs-only change is not fully covered by paths-ignore"
    fi

    if starts_build docs/risk-tiers.md Containerfile; then
        _pass "a pull request touching the Containerfile still starts one"
    else
        _fail "a pull request touching the Containerfile still starts one" \
            "paths-ignore swallows a tier 3 change"
    fi
fi

# --- "the classification is advisory" ---------------------------------------
#
# The closing section says no bot stamps a tier on a pull request and this file
# does not create one. That is an absence, so it is checked as one: no label
# this repository applies is named for a tier, in the labeler's rule set or in
# any workflow that adds labels.

advisory_claim='There is no bot that stamps a tier on a pull request, and this file does not create one.'
if require_claim "${RISK_TIERS}" "the classification is advisory" "${advisory_claim}"; then
    labeler_labels=$(sed -nE "s/^'([^']+)':.*/\1/p" "${LABELER_CONFIG}")
    if require_nonempty "labels in .github/labeler.yml" "${labeler_labels}"; then
        while IFS= read -r label; do
            [[ -z "${label}" ]] && continue
            if [[ "${label,,}" == *tier* ]]; then
                _fail "no applied label is named for a tier: ${label}" \
                    "the labeler would stamp a tier the document says nothing stamps"
            else
                _pass "not a tier label: ${label}"
            fi
        done <<<"${labeler_labels}"
    fi

    # And behaviourally: run a file from every tier through the labeler's rules
    # the way actions/labeler matches them, and none of the labels that come
    # back may name a tier.
    labels_for() {
        local path=$1 label='' pattern
        while IFS= read -r line; do
            if [[ "${line}" =~ ^\'([^\']+)\': ]]; then
                label="${BASH_REMATCH[1]}"
                continue
            fi
            if [[ "${line}" =~ ^[[:space:]]+-[[:space:]]+\'(.+)\'$ ]]; then
                pattern="${BASH_REMATCH[1]}"
                if [[ -n "${label}" && "${path}" =~ $(glob_to_regex "${pattern}") ]]; then
                    printf '%s\n' "${label}"
                    label=''
                fi
            fi
        done <"${LABELER_CONFIG}"
    }

    for sample in Containerfile renovate.json docs/risk-tiers.md tests/run-tests.sh; do
        got=$(labels_for "${sample}")
        if [[ "${got,,}" == *tier* ]]; then
            _fail "a change to ${sample} is labelled without a tier" \
                "the labeler returned: ${got//$'\n'/, }"
        else
            _pass "a change to ${sample} is labelled without a tier"
        fi
    done

    # The same absence one level up: no workflow adds a tier label either.
    tier_labels_in_workflows=$(grep -rniE -- "--add-label[= ]*[\"']?[a-z/-]*tier|labels:.*tier" "${REPO_ROOT}/.github/workflows" || true)
    if [[ -z "${tier_labels_in_workflows}" ]]; then
        _pass "no workflow applies a tier label"
    else
        _fail "no workflow applies a tier label" "${tier_labels_in_workflows}"
    fi
fi

# The one place a workflow does state a tier is a comment in auto-qa.yml, which
# calls its own file Tier 2. That is a claim about this table, so the table has
# to agree.
if require_claim "${AUTO_QA_WF}" "a workflow file is tier 2" "changing a Tier 2 file unattended (docs/risk-tiers.md)"; then
    assert_eq "the table puts .github/workflows/auto-qa.yml in that tier" \
        "2" "$(classify .github/workflows/auto-qa.yml)"
fi

# --- every path the prose names, outside the table --------------------------
#
# The table is checked above; this is the rest of the document. Only spans that
# are unambiguously repo paths are resolved -- they contain a `/` and no
# whitespace -- because a false positive here would make the suite lie about a
# document whose whole job is to be trusted.

expected_absent=('.github/renovate.json5')

is_expected_absent() {
    local candidate=$1 absent
    for absent in "${expected_absent[@]}"; do
        [[ "${candidate}" == "${absent}" ]] && return 0
    done
    return 1
}

prose_only=$(outside_fences "${RISK_TIERS}" | grep -v '^|')
require_nonempty "prose outside the tier table" "${prose_only}"

checked_any=0
while IFS= read -r span; do
    [[ -z "${span}" ]] && continue
    # `tests/e2e/run-e2e.sh --rechunk` is a command; its first field is the path.
    candidate=${span%% *}
    candidate=${candidate#./}
    [[ "${candidate}" != */* ]] && continue
    [[ "${candidate}" == /* ]] && continue
    [[ "${candidate}" == *://* ]] && continue

    checked_any=1
    if is_expected_absent "${candidate}"; then
        # Named as history -- the path README.md advertised before issue #70.
        # If it ever comes back, the sentence telling that story is wrong.
        if glob_matches_tracked "${candidate}"; then
            _fail "${candidate} is still the absent path the prose describes" \
                "it exists now, so the paragraph about issue #70 no longer holds"
        else
            _pass "${candidate} is still the absent path the prose describes"
        fi
        continue
    fi

    if glob_matches_tracked "${candidate}"; then
        _pass "prose path exists: ${candidate}"
    else
        _fail "prose path exists: ${candidate}" "no tracked path matches it"
    fi
done < <(code_spans <<<"${prose_only}")

assert_eq "the prose names repo paths at all" "1" "${checked_any}"

# --- the two documents the closing section hands the reader to --------------

conversation_section=$(
    awk '
        /^## Changes that need a conversation first$/ { in_section = 1; next }
        in_section && /^## / { exit }
        in_section
    ' "${CONTRIBUTING}"
)
if require_nonempty "CONTRIBUTING.md's conversation-first section" "${conversation_section}"; then
    assert_contains "it is about opening an issue before the work starts" \
        "${conversation_section}" "issue"
fi

finish
