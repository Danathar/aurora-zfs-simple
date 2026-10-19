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
#      first one the ruleset's required check, and the section's opening
#      claim that a pull request has to be up to date with `main` is present
#      exactly while the ruleset's required check is strict;
#   4. every message the page quotes is still printed by the file that prints
#      it, and the gate hook still exits 2 with a `blocked:` message;
#   5. every `gh` command names this repository, every `gh workflow run` and
#      `--workflow` names a workflow that exists, and every `-f` input is one
#      the workflow declares under `workflow_dispatch`;
#   6. the page applies no label, and names none of the labels SECURITY-AI.md
#      says Hive reads as approval to auto-merge;
#   7. every relative link resolves, and every `#anchor` is a heading;
#   8. every name the page gives another file is still that file's: the
#      ai-fix jobs, label, trigger phrase, branch prefix and grant; the
#      failure issue's title and the workflows it is opened for; the build
#      step the "main is red" table hands to its next row; the badge branch;
#      the nightly key; agent-audit.yml's signature line and date input; and
#      every repository path in a code span.
#
# Nothing here pins the page's wording beyond the quoted messages and the
# up-to-date clause in item 3.

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

# The section opens by saying two pull requests that each passed cannot land
# untested together. That holds only while the required check is strict, so
# the clause is held to the ruleset's value. `jq -c`, not `-r`: a string
# "true" must not read as the boolean.
strict="$(jq -c '.rules[] | select(.type == "required_status_checks") | .parameters.strict_required_status_checks_policy' "${RULESET}")"
MAIN_RED_FLAT="$(section_body '## `main` is red' "${RUNBOOK}" | flatten)"
for clause in 'A pull request has to be up to date with `main` before it merges' \
    'cannot land untested together'; do
    if [[ "${strict}" == "true" ]]; then
        assert_contains "the 'main is red' section says '${clause}' while the check is strict" \
            "${MAIN_RED_FLAT}" "${clause}"
    else
        assert_not_contains "the 'main is red' section drops '${clause}' once the check is not strict (strict: ${strict})" \
            "${MAIN_RED_FLAT}" "${clause}"
    fi
done
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

# --- 8. names the page gives other files ---------------------------------------

# The tables and the ai-fix section name jobs, a label, a phrase, a branch, a
# step, a key file and an issue title that live in other files. Each is read
# back out of the page (the first span after a fixed phrase) and looked up
# where it is defined, so renaming one there leaves this page red, not wrong.

# The first backticked span in the flattened page that follows $1.
span_after() {
    local escaped
    escaped="$(sed -E 's/[][\.*^$/]/\\&/g' <<<"$1")"
    sed -nE "s/.*${escaped} \`([^\`]+)\`.*/\1/p" <<<"${DOC_FLAT}"
}

# One `with:` value of ai-fix.yml's agent step, quotes dropped.
ai_fix_input() {
    sed -nE "s/^          $1: '?([^']*[^' ])'?[[:space:]]*\$/\1/p" "${AI_FIX}"
}

AI_FIX_JOBS="$(awk '/^jobs:/ { inside = 1; next } inside && /^[^ #]/ { exit } inside' "${AI_FIX}" |
    sed -nE 's/^  ([a-z0-9_-]+):[[:space:]]*$/\1/p')"
require_nonempty "ai-fix.yml's job ids" "${AI_FIX_JOBS}"

stops_at="$(span_after 'A run that stops at')"
require_nonempty "the job a run 'stops at'" "${stops_at}" &&
    assert_contains "ai-fix.yml has the job '${stops_at}' a quiet run stops at" "${AI_FIX_JOBS}" "${stops_at}"
assert_contains "the workflow table's ai-fix row names that same job" \
    "${DOC_FLAT}" "stopped at \`${stops_at}\`"

red_job="$(sed -nE 's/.*A red `([a-z0-9_-]+)` job is the agent.*/\1/p' <<<"${DOC_FLAT}")"
require_nonempty "the job 'A red ... job' names" "${red_job}" &&
    assert_contains "ai-fix.yml has the job '${red_job}' that runs the agent" "${AI_FIX_JOBS}" "${red_job}"
assert_contains "and that job is the one that needs ${stops_at}" \
    "$(awk -v job="  ${red_job}:" '$0 == job { inside = 1; next } inside && /^  [a-z]/ { exit } inside' "${AI_FIX}")" \
    "needs: ${stops_at}"

label="$(span_after 'issues and applies')"
require_nonempty "the label a bot applies" "${label}" &&
    assert_eq "the label the page says a bot applies is ai-fix.yml's label_trigger" \
        "$(ai_fix_input label_trigger)" "${label}"
assert_contains "and the ${stops_at} job's event filter reads that label" \
    "$(cat "${AI_FIX}")" "github.event.label.name == '${label}'"

phrase="$(span_after 'relays a request with a')"
require_nonempty "the phrase a maintainer relays with" "${phrase}" &&
    assert_eq "the phrase the page says a maintainer uses is ai-fix.yml's trigger_phrase" \
        "$(ai_fix_input trigger_phrase)" "${phrase}"
assert_contains "and the ${stops_at} job's event filter reads that phrase" \
    "$(cat "${AI_FIX}")" "contains(github.event.comment.body, '${phrase}')"

branch_glob="$(span_after 'check whether it pushed an')"
require_nonempty "the branch an agent pushes" "${branch_glob}" &&
    assert_eq "the branch the page says the agent pushes is ai-fix.yml's branch_prefix" \
        "$(ai_fix_input branch_prefix)*" "${branch_glob}"

grant="$(span_after 'Why the workflow holds')"
require_nonempty "the grant the page explains" "${grant}" &&
    assert_contains "the ${red_job} job holds the grant the page explains (${grant})" \
        "$(awk -v job="  ${red_job}:" '$0 == job { inside = 1; next } inside && /^  [a-z]/ { exit } inside' "${AI_FIX}" |
            sed -nE 's/^      ([a-z-]+: [a-z]+).*/\1/p')" "${grant}"

# The failure issue: the title the page says to look for is the one
# auto-issues.yml creates, with its workflow name as the placeholder.
AUTO_ISSUES="${WORKFLOW_DIR}/auto-issues.yml"
page_title="$(sed -nE 's/.*An issue titled `([^`]+)` comes from `auto-issues\.yml`.*/\1/p' <<<"${DOC_FLAT}")"
require_nonempty "the failure issue title on the page" "${page_title}" &&
    assert_eq "the failure issue title is the one auto-issues.yml creates" \
        "$(sed -nE 's/^ *title="(.*)\$\{WORKFLOW_NAME\}"$/\1<workflow>/p' "${AUTO_ISSUES}")" "${page_title}"

# The same paragraph says the issue comes from the image build, the nightly
# check or the boot test. auto-issues.yml watches by workflow `name:`, so
# resolve each to a file.
watched_files="$(
    awk '/^    workflows:/ { inside = 1; next } inside && !/^      - / { exit } inside' "${AUTO_ISSUES}" |
        sed -nE 's/^      - "?([^"]*)"?$/\1/p' |
        while IFS= read -r name; do
            grep -lxF "name: ${name}" "${WORKFLOW_DIR}"/*.yml | sed 's|.*/||'
        done | as_set
)"
assert_eq "the failure issue is opened for the image build, the nightly check and the boot test, as the page says" \
    $'boot-test.yml\nbuild.yml\nnightly-compliance.yml' "${watched_files}"

# "If the red step is `Push To GHCR` or later, read the next row": that step
# has to come after the step the next row counts from, or the reader is sent
# to a row that does not cover it.
push_step="$(span_after 'If the red step is')"
require_nonempty "the step the 'main is red' table hands to the next row" "${push_step}" &&
    assert_contains "build.yml has the step '${push_step}'" "${build_steps}" "${push_step}"
next_row_step="$(grep -E '^A step after ' <<<"${MAIN_RED}" | tail -n1)"
next_row_step="${next_row_step#A step after }"
push_at="$(grep -nxF -- "${push_step}" <<<"${build_steps}" | cut -d: -f1)"
next_at="$(grep -nxF -- "${next_row_step}" <<<"${build_steps}" | cut -d: -f1)"
if [[ -n "${push_at}" && -n "${next_at}" && "${next_at}" -lt "${push_at}" ]]; then
    _pass "'${push_step}' comes after '${next_row_step}', the step the next row counts from"
else
    _fail "'${push_step}' comes after '${next_row_step}', the step the next row counts from" \
        "got ${push_step}=${push_at:-none} ${next_row_step}=${next_at:-none}"
fi

# The badges live on the branch status-badges.yml pushes to.
badge_branch="$(sed -nE 's/.*The badge files on the `([^`]+)` branch.*/\1/p' <<<"${DOC_FLAT}")"
require_nonempty "the badge branch on the page" "${badge_branch}" &&
    assert_contains "status-badges.yml pushes to the branch the page names (${badge_branch})" \
        "$(cat "${WORKFLOW_DIR}/status-badges.yml")" "git push origin HEAD:${badge_branch}"
assert_contains "the stale-badge advice names that same branch" \
    "${DOC_FLAT}" "then the \`${badge_branch}\` branch"

# The nightly signature row names the key the step verifies against.
nightly_key="$(span_after 'The image no longer verifies against')"
require_nonempty "the key the nightly signature row names" "${nightly_key}" &&
    assert_contains "nightly-compliance.yml verifies against ${nightly_key}" \
        "$(cat "${NIGHTLY}")" "cosign verify --key ${nightly_key} "
assert_file_exists "${nightly_key} is committed" "${REPO_ROOT}/${nightly_key}"

# The agent-audit row: the signature line it looks for and its date input.
AGENT_AUDIT="${WORKFLOW_DIR}/agent-audit.yml"
signature="$(span_after 'enforcement date lacks its')"
require_nonempty "the signature line the agent-audit row names" "${signature}" &&
    assert_contains "agent-audit.yml looks for the '${signature}' line" \
        "$(cat "${AGENT_AUDIT}")" "startswith(\"${signature}\")"
audit_input="$(sed -nE 's/.*the window hit the cap, or `([a-z_]+)` was malformed.*/\1/p' <<<"${DOC_FLAT}")"
require_nonempty "the agent-audit input the row names" "${audit_input}" &&
    if awk '/^  workflow_dispatch:/ { inside = 1; next } inside && /^  [a-z]/ { exit } inside' "${AGENT_AUDIT}" |
        grep -qE "^      ${audit_input}:"; then
        _pass "agent-audit.yml takes the input '${audit_input}'"
    else
        _fail "agent-audit.yml takes the input '${audit_input}'" "no such input under workflow_dispatch"
    fi

# Every repository path the page puts in a code span exists. Same filter as
# test-docs-paths.sh's inline pass, which reads only README.md and AGENTS.md:
# a span with a `/` is a path only when its first segment is a top-level entry.
top_level="$(cd "${REPO_ROOT}" && git ls-files | cut -d/ -f1 | as_set)"
named_paths=0
while IFS= read -r span; do
    [[ "${span}" =~ ^[A-Za-z0-9_.][A-Za-z0-9_./-]*/[A-Za-z0-9_./-]*$ ]] || continue
    grep -qxF -- "${span%%/*}" <<<"${top_level}" || continue
    named_paths=$((named_paths + 1))
    if [[ -e "${REPO_ROOT}/${span%/}" ]]; then
        _pass "the page names an existing path: ${span}"
    else
        _fail "the page names an existing path: ${span}" "no such path in the repository"
    fi
done < <(outside_fences "${RUNBOOK}" | grep -oE '`[^`]+`' | tr -d '`' | as_set)
assert_eq "the page's code spans yielded paths to check" "yes" \
    "$([[ "${named_paths}" -gt 0 ]] && echo yes || echo no)"

finish
