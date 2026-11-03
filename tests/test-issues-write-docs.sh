#!/usr/bin/env bash
#
# Joins the two pages that describe who holds `issues: write` to the workflows
# and the policy file that grant it.
#
# docs/SECURITY-AI.md's "Failure issues hold `issues: write`" says what
# auto-issues.yml watches, which runs it acts on, what its token holds and what
# it never does. docs/risk-tiers.md's "Why `.github/policies/**` is Tier 3"
# says which workflows hold the scope, what auto-issues.yml's token is, and
# which tier a change to each file lands in. tests/test-auto-issues.sh runs the
# step and tests/test-workflow-permissions.sh holds the scopes, but neither
# reads either page, so docs/section-map.txt marked both sections
# `prose: unchecked:`. A workflow that gained `issues: write`, or an
# auto-issues.yml that started watching another workflow or calling
# `gh issue close`, left both pages green and wrong.
#
#   1. both sections are present;
#   2. the workflows that grant `issues: write`, read from the YAML and from the
#      policy file, are auto-issues.yml and ai-fix.yml, and both pages say so;
#   3. auto-issues.yml's token is `issues: write` and `actions: read` and
#      nothing else, with no checkout, and both pages name exactly that grant;
#   4. the workflows it watches are the ones the page lists, by phrase;
#   5. the conclusions and events its step accepts are the ones the page lists;
#   6. its step calls only `gh api`, `gh issue list`, `gh issue comment` and
#      `gh issue create`, applies no label and puts no `${{ }}` in `run:`;
#   7. the tests each page names exist and read what the page says they hold;
#   8. the risk-tiers paragraph's links resolve, the human-decision list on
#      SECURITY-AI.md names the scopes the paragraph quotes, and
#      .claude/risk-config.json puts the two files in the tiers it says.
#
# Markdown wraps, so each section is squashed to single spaces before a phrase
# is matched.

# The needles below are single-quoted so that `${{` reaches grep rather than
# the shell. SC2016 is off for the file rather than repeated.
# shellcheck disable=SC2016

set -uo pipefail

TEST_NAME="test-issues-write-docs"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

SECURITY_MD="${REPO_ROOT}/docs/SECURITY-AI.md"
RISK_MD="${REPO_ROOT}/docs/risk-tiers.md"
WORKFLOWS="${REPO_ROOT}/.github/workflows"
AUTO_ISSUES="${WORKFLOWS}/auto-issues.yml"
POLICY="${REPO_ROOT}/.github/policies/workflow-permissions.json"
RISK_CONFIG="${REPO_ROOT}/.claude/risk-config.json"
SECURITY_HEADING='## Failure issues hold `issues: write`'
RISK_HEADING='## Why `.github/policies/**` is Tier 3'
STEP_NAME="Open or update the issue for this failure"
WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"

for required in "${SECURITY_MD}" "${RISK_MD}" "${AUTO_ISSUES}" "${POLICY}" "${RISK_CONFIG}"; do
    assert_file_exists "${required#"${REPO_ROOT}/"} is present" "${required}"
done

if ! "${WORKFLOW_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    _fail "reading the workflows requires Python 3 with PyYAML" \
        "install python3-yaml (Debian/Ubuntu) or python3-pyyaml (Fedora)," \
        "or install PyYAML in the interpreter selected by WORKFLOW_PYTHON"
    finish
    exit 1
fi

# Prints the body of the `## ` section headed $1 in $2, squashed to one line.
section() {
    awk -v heading="$1" '
        $0 == heading { inside = 1; next }
        inside && /^## / { exit }
        inside { print }
    ' "$2" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g'
}

SECURITY="$(section "${SECURITY_HEADING}" "${SECURITY_MD}")"
RISK="$(section "${RISK_HEADING}" "${RISK_MD}")"

# --- 1. the sections ---------------------------------------------------------

assert_contains "docs/SECURITY-AI.md still has the failure-issues section" "${SECURITY:+present}" "present"
assert_contains "docs/risk-tiers.md still has the policies section" "${RISK:+present}" "present"

# --- 2. who holds issues: write ----------------------------------------------

# Every workflow file, top-level and per job, as JSON keyed by file name.
WORKFLOW_JSON="$("${WORKFLOW_PYTHON}" -B -c '
import json, os, sys, yaml
out = {}
for name in sorted(os.listdir(sys.argv[1])):
    if name.endswith((".yml", ".yaml")):
        with open(os.path.join(sys.argv[1], name), encoding="utf-8") as handle:
            out[name] = yaml.safe_load(handle)
print(json.dumps(out))
' "${WORKFLOWS}")"
assert_contains "the workflows parse" "${WORKFLOW_JSON:+parsed}" "parsed"

# PyYAML reads the bare key `on` as true.
holders_yaml="$(jq -r '
    to_entries[]
    | select(([.value.permissions] + [.value.jobs[]?.permissions])
             | any(type == "object" and .issues == "write"))
    | .key
' <<<"${WORKFLOW_JSON}" | LC_ALL=C sort)"
assert_eq "the workflows that grant issues: write are ai-fix.yml and auto-issues.yml" \
    $'ai-fix.yml\nauto-issues.yml' "${holders_yaml}"

holders_policy="$(jq -r '
    .workflows | to_entries[]
    | select(([.value.workflow] + [.value.jobs[]])
             | any(type == "object" and .issues == "write"))
    | .key
' "${POLICY}" | LC_ALL=C sort)"
assert_eq "and the policy file lists the same two" "${holders_yaml}" "${holders_policy}"

assert_contains "SECURITY-AI.md says auto-issues.yml is the only one besides ai-fix.yml" "${SECURITY}" \
    'It is the only workflow besides `ai-fix.yml` with `issues: write`'
assert_contains "risk-tiers.md says only those two hold it" "${RISK}" \
    'The same applies to `issues: write`, which only [`.github/workflows/auto-issues.yml`](../.github/workflows/auto-issues.yml) and `ai-fix.yml` hold.'

# --- 3. auto-issues.yml's token ------------------------------------------------

auto() { jq -c "$1" <<<"${WORKFLOW_JSON}"; }

assert_eq "auto-issues.yml declares no top-level permissions" "null" \
    "$(auto '."auto-issues.yml".permissions')"
assert_eq "its one job is report" '["report"]' "$(auto '."auto-issues.yml".jobs | keys')"
GRANT="$(auto '."auto-issues.yml".jobs.report.permissions | to_entries | map("\(.key): \(.value)") | sort')"
assert_eq "report holds issues: write and actions: read and nothing else" \
    '["actions: read","issues: write"]' "${GRANT}"
assert_eq "the policy file gives auto-issues.yml the same grant" "${GRANT}" \
    "$(jq -c '.workflows."auto-issues.yml".jobs.report | to_entries | map("\(.key): \(.value)") | sort' "${POLICY}")"

# The scopes a page quotes as `scope: level`, sorted, as a JSON array.
quoted_scopes() {
    grep -oE '`[a-z-]+: (read|write)`' <<<"$1" | tr -d '`' | LC_ALL=C sort -u | jq -R . | jq -sc .
}

grant_bullet="$(grep -oE '\- the token holds [^;]*;' <<<"${SECURITY}")"
assert_contains "SECURITY-AI.md has the bullet on the token" "${grant_bullet:+present}" "present"
assert_eq "the bullet names exactly the grant report holds" "${GRANT}" "$(quoted_scopes "${grant_bullet}")"
assert_contains "and says it holds nothing else and has no checkout" "${grant_bullet}" \
    'and nothing else, with no checkout,'

widen_sentence="$(grep -oE "widens \`auto-issues\.yml\`'s token beyond [^,]*," <<<"${RISK}")"
assert_contains "risk-tiers.md has the sentence on widening the token" "${widen_sentence:+present}" "present"
assert_eq "the sentence names exactly the grant report holds" "${GRANT}" "$(quoted_scopes "${widen_sentence}")"

assert_eq "no step of auto-issues.yml checks out the repository" "[]" \
    "$(auto '[."auto-issues.yml".jobs[].steps[] | .uses // empty | select(startswith("actions/checkout"))]')"

SCRIPT="$(jq -r --arg step "${STEP_NAME}" \
    '."auto-issues.yml".jobs.report.steps[] | select(.name == $step) | .run' <<<"${WORKFLOW_JSON}")"
assert_contains "auto-issues.yml still has the '${STEP_NAME}' step" "${SCRIPT:+present}" "present"
assert_eq "and it is the job's only step" "1" "$(auto '."auto-issues.yml".jobs.report.steps | length')"
assert_eq "the step runs no git command" "" "$(grep -E '(^|[[:space:];|&(])git[[:space:]]' <<<"${SCRIPT}")"

# --- 4. what it watches --------------------------------------------------------

# Each watched workflow by file name, and the phrase the page names it by.
declare -A WATCHED_PHRASE=(
    ["build.yml"]='the image build on `main`, scheduled or after a push,'
    ["nightly-compliance.yml"]='the nightly compliance check,'
    ["boot-test.yml"]='the boot test that a build of `main` starts'
)

watched="$(jq -r '
    . as $all
    | ."auto-issues.yml".true.workflow_run.workflows[] as $name
    | ($all | to_entries[] | select(.value.name == $name) | .key) // "unknown: \($name)"
' <<<"${WORKFLOW_JSON}" | LC_ALL=C sort)"
assert_eq "the workflows auto-issues.yml watches are the ones the page lists" \
    "$(printf '%s\n' "${!WATCHED_PHRASE[@]}" | LC_ALL=C sort)" "${watched}"
assert_eq "it runs on their completion only" '{"workflow_run":{"types":["completed"]}}' \
    "$(auto '."auto-issues.yml".true | map_values(del(.workflows))')"

opener="$(sed -E 's/ It is the only workflow.*//' <<<"${SECURITY}")"
for file in "${!WATCHED_PHRASE[@]}"; do
    assert_contains "the page's opening sentence names ${file}" "${opener}" "${WATCHED_PHRASE[${file}]}"
done

boot_trigger="$(auto '."boot-test.yml".true.workflow_run.workflows')"
assert_eq "the boot test is started by the image build, as the page says" '["Build container image"]' \
    "${boot_trigger}"

# --- 5. which runs it acts on --------------------------------------------------

# Prints the patterns of the `case` on $1 in the step, one per line.
case_arms() {
    awk -v head="case \"\${$1}\" in" '
        index($0, head) { inside = 1; next }
        inside && /^[[:space:]]*esac/ { exit }
        inside && /^[[:space:]]*[a-z_|*]+\)/ {
            sub(/^[[:space:]]*/, ""); sub(/\).*/, ""); print
        }
    ' <<<"${SCRIPT}" | tr '|' '\n' | grep -vxF '*' | LC_ALL=C sort
}

assert_eq "the step reports a failed or timed-out run" $'failure\ntimed_out' "$(case_arms CONCLUSION)"
assert_eq "and the job-level filter lets the same two through" \
    "github.event.workflow_run.conclusion == 'failure' || github.event.workflow_run.conclusion == 'timed_out'" \
    "$(auto '."auto-issues.yml".jobs.report.if' | jq -r .)"

# Each accepted event, and how the page names it.
declare -A EVENT_PHRASE=(
    ["schedule"]="started by a schedule"
    ["push"]="or a push"
    ["workflow_run"]="or, for the boot test alone, by a build's completion"
)
assert_eq "the events the step accepts are the ones the page lists" \
    "$(printf '%s\n' "${!EVENT_PHRASE[@]}" | LC_ALL=C sort)" "$(case_arms RUN_EVENT)"

scope_bullet="$(grep -oE '\- it acts only on [^;]*;' <<<"${SECURITY}")"
assert_contains "SECURITY-AI.md has the bullet on which runs it acts on" "${scope_bullet:+present}" "present"
assert_contains "the bullet says failed or timed-out, on the default branch" "${scope_bullet}" \
    "it acts only on a failed or timed-out run on the default branch"
for event in "${!EVENT_PHRASE[@]}"; do
    assert_contains "the bullet names the ${event} event" "${scope_bullet}" "${EVENT_PHRASE[${event}]}"
done
assert_contains "the step takes a build's completion for the boot test alone" "${SCRIPT}" \
    'if [ "${WORKFLOW_NAME}" != "Boot test" ]; then'
assert_contains "and refuses another branch" "${SCRIPT}" 'if [ "${HEAD_BRANCH}" != "${DEFAULT_BRANCH}" ]; then'
assert_contains "and another repository's run" "${SCRIPT}" 'if [ "${HEAD_REPO}" != "${REPO}" ]; then'

# --- 6. what it never does -----------------------------------------------------

assert_eq "the step calls only gh api, gh issue list, gh issue comment and gh issue create" \
    $'gh api\ngh issue comment\ngh issue create\ngh issue list' \
    "$(grep -oE '(^|[^a-z_-])gh [a-z]+( [a-z]+)?' <<<"${SCRIPT}" | sed -E 's/^[^g]//; s/^(gh api).*/\1/' | LC_ALL=C sort -u)"
assert_eq "and applies no label" "" "$(grep -E -- '--(add-)?label' <<<"${SCRIPT}")"
assert_contains "SECURITY-AI.md says it never closes, edits or labels an issue" "${SECURITY}" \
    "it never closes, edits or labels an issue"

assert_eq "no \${{ }} expression appears in the step's run:" "" "$(grep -F '${{' <<<"${SCRIPT}")"
assert_contains "the step's env: carries the run's fields" \
    "$(auto '."auto-issues.yml".jobs.report.steps[0].env | keys')" '"HEAD_BRANCH"'
assert_contains "SECURITY-AI.md says the fields reach the shell through env: only" "${SECURITY}" \
    "the run's fields reach the shell through \`env:\` only."

# --- 7. the tests the pages name -----------------------------------------------

# Prints $1 with comment lines dropped.
code_of() { grep -v '^[[:space:]]*#' "$1"; }

assert_contains "SECURITY-AI.md names the two tests that hold the workflow" "${SECURITY}" \
    '`tests/test-auto-issues.sh` executes the step to hold the behaviour, and `tests/test-workflow-permissions.sh` holds the scopes.'
assert_contains "test-auto-issues.sh reads auto-issues.yml" \
    "$(code_of "${TEST_DIR}/test-auto-issues.sh")" 'auto-issues.yml"'
assert_contains "and extracts the step the page says it executes" \
    "$(code_of "${TEST_DIR}/test-auto-issues.sh")" "${STEP_NAME}"
assert_contains "test-workflow-permissions.sh reads the policy file" \
    "$(code_of "${TEST_DIR}/test-workflow-permissions.sh")" '/.github/policies/workflow-permissions.json"'
assert_contains "and replays a widened workflow, the failure risk-tiers.md describes" \
    "$(code_of "${TEST_DIR}/test-workflow-permissions.sh")" 'a widened workflow is reported, and only that workflow'
assert_contains "risk-tiers.md says what that test fails on" "${RISK}" \
    "fails when a workflow's \`permissions:\` block asks for anything the file does not list."

# --- 8. risk-tiers.md: links, the human-decision list, the tiers ---------------

# Both pages sit in docs/, so their relative links resolve from there.
links_of() { grep -oE '\]\([^)#]+\)' <<<"$1" | sed -E 's/^\]\(//; s/\)$//' | LC_ALL=C sort -u; }

assert_eq "SECURITY-AI.md's section links auto-issues.yml" "../.github/workflows/auto-issues.yml" \
    "$(links_of "${SECURITY}")"
mapfile -t LINKS < <(links_of "${RISK}")
assert_eq "risk-tiers.md's paragraph links the policy file, auto-issues.yml, the test and SECURITY-AI.md" \
    $'../.github/policies/workflow-permissions.json\n../.github/workflows/auto-issues.yml\n../tests/test-workflow-permissions.sh\nSECURITY-AI.md' \
    "$(printf '%s\n' "${LINKS[@]}")"
for link in "${LINKS[@]}"; do
    assert_file_exists "the link ${link} resolves" "${REPO_ROOT}/docs/${link}"
done

decision_bullet="$(awk '
    /^Requires a human decision first/ { inside = 1; next }
    inside && /^- \*\*granting any new workflow/ { found = 1 }
    found && /^- / && !/^- \*\*granting/ { exit }
    found { print }
' "${SECURITY_MD}" | tr '\n' ' ')"
for scope in 'contents: write' 'packages: write'; do
    assert_contains "risk-tiers.md quotes \`${scope}\` as a decision for a human" "${RISK}" "\`${scope}\`"
    assert_contains "and SECURITY-AI.md's human-decision list names it" "${decision_bullet}" "\`${scope}\`"
done

# The highest tier whose paths match $1, as .claude/risk-config.json writes them.
tier_of() {
    local path=$1 best="" tier glob
    while IFS=$'\t' read -r tier glob; do
        # shellcheck disable=SC2053 # the glob is the pattern
        if [[ "${path}" == ${glob} ]] && [[ -z "${best}" || "${tier}" -gt "${best}" ]]; then
            best="${tier}"
        fi
    done < <(jq -r '.tiers[] | .tier as $t | .paths[] | "\($t)\t\(.)"' "${RISK_CONFIG}")
    printf '%s' "${best}"
}

assert_eq "risk-config.json puts the policy file in Tier 3" "3" \
    "$(tier_of .github/policies/workflow-permissions.json)"
assert_eq "and auto-issues.yml in Tier 2" "2" "$(tier_of .github/workflows/auto-issues.yml)"
assert_contains "risk-tiers.md says the same" "${RISK}" \
    "touches the policy file and is Tier 3; the workflow file alone is Tier 2."

finish
