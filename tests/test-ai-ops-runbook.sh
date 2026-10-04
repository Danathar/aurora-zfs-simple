#!/usr/bin/env bash
#
# Joins docs/ai-ops-runbook.md to the workflows, messages and commands it tells
# a maintainer to act on.
#
# A runbook is read when something is already wrong, which is the worst moment
# to find it describing a workflow that was renamed, a message nothing prints
# any more, or a `gh workflow run` that no longer exists. No other test reads
# this page as a subject, and a workflow change that leaves it stale stays
# green. What is checked, recomputed from the tree rather than restated:
#
#   1. the "Each workflow" table has one row per file in .github/workflows/, in
#      both directions, and every `*.yml` the page names is a workflow;
#   2. the workflows the "scheduled run is missing" section lists are exactly
#      the ones whose `on:` block has a `schedule:`;
#   3. the nightly step table is the nightly job's checking steps, in order,
#      by their step names, and the `Shell tests` / `Build and push image`
#      names in the "main is red" table are job names in build.yml, with the
#      first one the ruleset's required check;
#   4. every message the page quotes is still printed by the file that prints
#      it, and the gate hook still exits 2 with a `blocked:` message;
#   5. every `gh` command names this repository, every `gh workflow run` and
#      `--workflow` names a workflow that exists, and every `-f` input is one
#      the workflow declares under `workflow_dispatch`;
#   6. the page applies no label, and names none of the labels SECURITY-AI.md
#      says Hive reads as approval to auto-merge;
#   7. every relative link resolves, and every `#anchor` is a heading.
#
# Nothing here pins the page's wording beyond the quoted messages.

# The page quotes Markdown code spans, and so do the patterns that find them;
# those backticks are literal text, not command substitution.
# shellcheck disable=SC2016

set -uo pipefail

TEST_NAME="test-ai-ops-runbook"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=tests/lib/markdown.sh
source "${TEST_DIR}/lib/markdown.sh"

RUNBOOK="${REPO_ROOT}/docs/ai-ops-runbook.md"
WORKFLOW_DIR="${REPO_ROOT}/.github/workflows"
NIGHTLY="${WORKFLOW_DIR}/nightly-compliance.yml"
BUILD_YML="${WORKFLOW_DIR}/build.yml"
AI_FIX="${WORKFLOW_DIR}/ai-fix.yml"
HOOK="${REPO_ROOT}/.claude/hooks/gate-git-diff.sh"
RULESET="${REPO_ROOT}/.github/rulesets/main.json"
SECURITY_MD="${REPO_ROOT}/docs/SECURITY-AI.md"
REPO_SLUG="Danathar/aurora-zfs-simple"

# Steps of the nightly jobs that set the runner up rather than check anything.
# Every other step has to be a row, so a new check cannot be left out of the
# table; each is asserted present, so a renamed setup step fails instead of
# quietly becoming a check the table is missing.
NIGHTLY_SETUP_STEPS=$'Checkout\nInstall shellcheck\nPrepare environment\nEnsure skopeo is present\nInstall Cosign\nLog in to GitHub Container Registry\nSummarize'

for required in "${RUNBOOK}" "${NIGHTLY}" "${BUILD_YML}" "${AI_FIX}" "${HOOK}" "${RULESET}" "${SECURITY_MD}"; do
    if [[ -f "${required}" ]]; then
        _pass "${required#"${REPO_ROOT}"/} is present"
    else
        _fail "${required#"${REPO_ROOT}"/} is present" "no such file"
        finish
        exit 1
    fi
done

# --- helpers ------------------------------------------------------------------

# The body of the `## ` section of $2 whose heading is exactly $1.
section_body() {
    awk -v want="$1" '
        $0 == want { inside = 1; next }
        inside && /^## / { exit }
        inside
    ' "$2"
}

# The first cell of every body row of the first table on stdin, backticks
# dropped, one per line.
first_column() {
    awk -F'|' '
        /^\|/ { row++; if (row > 2) { c = $2; gsub(/^ +| +$/, "", c); gsub(/`/, "", c); print c } next }
        row { exit }
    '
}

# Text with line breaks and runs of spaces collapsed, so a phrase Markdown
# wrapped across two lines still matches.
flatten() {
    tr '\n' ' ' | tr -s ' '
}

# Step names of a workflow in file order, each once.
step_names() {
    sed -nE 's/^      - name: (.*[^[:space:]])[[:space:]]*$/\1/p' "$1" | awk '!seen[$0]++'
}

# Sorted, one per line, so two sets compare as two strings.
as_set() {
    sort -u | grep -v '^$'
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

DOC_FLAT="$(flatten <"${RUNBOOK}")"

# --- 0. the extractors, against a fixture --------------------------------------

fixture="$(mktemp)"
trap 'rm -f "${fixture}"' EXIT
printf '%s\n' '| A | B |' '| - | - |' '| `one` | x |' '| two | y |' '' 'after' '| `ignored` | z |' >"${fixture}"
assert_eq "fixture: first_column reads the first table's body rows, backticks dropped" \
    $'one\ntwo' "$(first_column <"${fixture}")"
printf '%s\n' '## One' 'a' '## Two' 'b' 'c' '## Three' 'd' >"${fixture}"
assert_eq "fixture: section_body stops at the next ## heading" $'b\nc' "$(section_body '## Two' "${fixture}")"

# --- 1. every workflow, in both directions -----------------------------------

# GitHub runs .yaml files from this directory as well as .yml ones.
ON_DISK="$(find "${WORKFLOW_DIR}" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) -printf '%f\n' | as_set)"
require_nonempty "the workflows on disk" "${ON_DISK}"

TABLE="$(section_body '## Each workflow' "${RUNBOOK}" | first_column)"
assert_eq "the 'Each workflow' table has one row per file in .github/workflows/" \
    "${ON_DISK}" "$(as_set <<<"${TABLE}")"

NAMED="$(grep -oE '\b[a-z][a-z0-9-]*\.yml\b' "${RUNBOOK}" | as_set)"
assert_eq "every *.yml the page names is a workflow that exists" \
    "" "$(comm -13 <(printf '%s\n' "${ON_DISK}") <(printf '%s\n' "${NAMED}"))"

# --- 2. the scheduled workflows ----------------------------------------------

SCHEDULED="$(find "${WORKFLOW_DIR}" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) \
    -exec grep -lE '^  schedule:' {} + | sed 's|.*/||' | as_set)"
require_nonempty "the scheduled workflows" "${SCHEDULED}"
LISTED="$(section_body '## A scheduled run is missing' "${RUNBOOK}" |
    sed -nE 's/^- `([a-z0-9-]+\.yml)`$/\1/p' | as_set)"
assert_eq "the 'scheduled run is missing' list is the workflows that have a schedule:" \
    "${SCHEDULED}" "${LISTED}"

# --- 3. step and job names ----------------------------------------------------

NIGHTLY_STEPS="$(step_names "${NIGHTLY}")"
require_nonempty "the nightly job's steps" "${NIGHTLY_STEPS}"
while IFS= read -r setup; do
    assert_contains "nightly-compliance.yml still has the setup step '${setup}'" \
        "${NIGHTLY_STEPS}" "${setup}"
done <<<"${NIGHTLY_SETUP_STEPS}"
CHECKS="$(grep -vxFf <(printf '%s\n' "${NIGHTLY_SETUP_STEPS}") <<<"${NIGHTLY_STEPS}")"
assert_eq "the nightly step table is the job's checking steps, in order" \
    "${CHECKS}" "$(section_body '## Nightly compliance failed' "${RUNBOOK}" | first_column)"

MAIN_RED="$(section_body '## `main` is red' "${RUNBOOK}" | first_column)"
require_nonempty "the 'main is red' table" "${MAIN_RED}"
build_jobs="$(sed -nE 's/^    name: (.*[^[:space:]])[[:space:]]*$/\1/p' "${BUILD_YML}")"
build_steps="$(step_names "${BUILD_YML}")"
while IFS= read -r red; do
    if [[ "${red}" == "A step after "* ]]; then
        step="${red#A step after }"
        assert_contains "build.yml has the step '${step}' the table counts from" "${build_steps}" "${step}"
    else
        assert_contains "build.yml has a job named '${red}'" "${build_jobs}" "${red}"
    fi
done <<<"${MAIN_RED}"

required_checks="$(jq -r '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context' "${RULESET}")"
assert_contains "the page's required check is the ruleset's" "${required_checks}" "Shell tests"
assert_contains "the page says Shell tests is the one required check" \
    "${DOC_FLAT}" '`Shell tests` is the only check the ruleset requires'
assert_eq "the ruleset requires exactly one check" "1" "$(wc -l <<<"${required_checks}" | tr -d ' ')"
assert_contains "coverage-gate.yml also runs a job named Shell tests" \
    "$(sed -nE 's/^    name: (.*)$/\1/p' "${WORKFLOW_DIR}/coverage-gate.yml")" "Shell tests"

# --- 4. quoted messages -------------------------------------------------------

# message|file that prints it
QUOTED="$(
    cat <<'EOF'
Skipped: no agent credentials are configured on this repository.|.github/workflows/ai-fix.yml
which is a bot|.github/workflows/ai-fix.yml
comes from a fork.|.github/workflows/ai-fix.yml
could not be inspected|.github/workflows/nightly-compliance.yml
EOF
)"
while IFS='|' read -r message file; do
    assert_contains "the page quotes '${message}'" "${DOC_FLAT}" "\`${message}\`"
    assert_contains "${file} still prints '${message}'" "$(flatten <"${REPO_ROOT}/${file}")" "${message}"
done <<<"${QUOTED}"

assert_contains "the page says the hook prints a blocked: message" "${DOC_FLAT}" 'prints a `blocked:` message'
hook_err="$(
    printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git diff cosign.key /dev/null"}}' |
        CLAUDE_PROJECT_DIR="${REPO_ROOT}" bash "${HOOK}" 2>&1 >/dev/null
)"
hook_rc=$?
assert_eq "the hook exits 2 on a refused command" "2" "${hook_rc}"
assert_eq "the hook's refusal starts with 'blocked:'" "blocked:" "${hook_err%% *}"

# --- 5. gh commands -----------------------------------------------------------

# Fenced lines that start a gh command, and inline spans that do.
COMMANDS="$(
    {
        awk '/^```/ { fenced = !fenced; next } fenced && /^gh / { print }' "${RUNBOOK}"
        grep -oE '`gh [^`]+`' <<<"${DOC_FLAT}" | tr -d '`'
    } | as_set
)"
require_nonempty "the gh commands" "${COMMANDS}"
while IFS= read -r command; do
    if [[ "${command}" == *"--repo ${REPO_SLUG}"* || "${command}" == *"repos/${REPO_SLUG}"* ]]; then
        _pass "names this repository: ${command}"
    else
        _fail "names this repository: ${command}" "add --repo ${REPO_SLUG}; this repository is a fork"
    fi
done <<<"${COMMANDS}"

while read -r workflow; do
    [[ -n "${workflow}" ]] || continue
    assert_file_exists "--workflow ${workflow} names a workflow" "${WORKFLOW_DIR}/${workflow}"
done < <(grep -oE -- '--workflow [a-z0-9-]+\.yml' <<<"${COMMANDS}" | cut -d' ' -f2 | as_set)

dispatches=0
while IFS= read -r command; do
    [[ "${command}" == "gh workflow run "* ]] || continue
    dispatches=$((dispatches + 1))
    workflow="$(cut -d' ' -f4 <<<"${command}")"
    assert_file_exists "${command}: ${workflow} exists" "${WORKFLOW_DIR}/${workflow}"
    if grep -qE '^  workflow_dispatch:' "${WORKFLOW_DIR}/${workflow}" 2>/dev/null; then
        _pass "${workflow} can be dispatched"
    else
        _fail "${workflow} can be dispatched" "no workflow_dispatch: trigger"
    fi
    while read -r input; do
        [[ -n "${input}" ]] || continue
        if grep -qE "^      ${input}:" "${WORKFLOW_DIR}/${workflow}"; then
            _pass "${workflow} takes the input '${input}'"
        else
            _fail "${workflow} takes the input '${input}'" "no such input under workflow_dispatch"
        fi
    done < <(grep -oE -- ' -f [A-Za-z0-9_-]+=' <<<"${command}" | sed -E 's/^ -f //; s/=$//')
done <<<"${COMMANDS}"
assert_eq "the page dispatches at least one workflow, so the checks above ran" "yes" \
    "$([[ "${dispatches}" -gt 0 ]] && echo yes || echo no)"

# --- 6. labels ----------------------------------------------------------------

assert_not_contains "the page applies no label" "${DOC_FLAT}" "--add-label"
APPROVAL_LABELS="$(awk '/^## Labels carry authority/ { in_section = 1 } in_section && /^```text$/ { fenced = 1; next } fenced && /^```$/ { exit } fenced { print }' "${SECURITY_MD}" | tr -s ' ' '\n' | as_set)"
require_nonempty "SECURITY-AI.md's approval-label list" "${APPROVAL_LABELS}"
while IFS= read -r label; do
    assert_not_contains "the page never passes --label ${label}" "${DOC_FLAT}" "--label ${label}"
done <<<"${APPROVAL_LABELS}"

# --- 7. links and anchors -----------------------------------------------------

LINKS="$(outside_fences "${RUNBOOK}" | grep -oE '\]\([^) ]+\)' | sed -E 's/^\]\(//; s/\)$//' | as_set)"
require_nonempty "the page's links" "${LINKS}"
while IFS= read -r target; do
    case "${target}" in
        http://* | https://* | mailto:*) continue ;;
        *) ;;
    esac
    path_part="${target%%#*}"
    fragment=""
    [[ "${target}" == *"#"* ]] && fragment="${target#*#}"
    if [[ -z "${path_part}" ]]; then
        file="${RUNBOOK}"
    else
        file="$(cd "$(dirname "${RUNBOOK}")" && realpath -m "${path_part}")"
    fi
    if [[ ! -e "${file}" ]]; then
        _fail "link ${target} resolves" "no such path: ${file#"${REPO_ROOT}"/}"
        continue
    fi
    if [[ -z "${fragment}" ]]; then
        _pass "link ${target} resolves"
    elif [[ "${file}" == *.md && -f "${file}" ]] && grep -qxF -- "${fragment}" <<<"$(heading_slugs "${file}")"; then
        _pass "link ${target} resolves to a heading"
    else
        _fail "link ${target} resolves to a heading" "${file#"${REPO_ROOT}"/} has no heading that slugs to ${fragment}"
    fi
done <<<"${LINKS}"

finish
