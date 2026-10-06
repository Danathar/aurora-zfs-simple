#!/usr/bin/env bash
#
# Covers .github/workflows/agent-audit.yml — the one `run:` body that reads
# back, after the merge, the record an agent-written pull request is supposed
# to leave: a `— hive:` signature line in its description and a Signed-off-by
# trailer on every commit.
#
# Nothing else checks that record. `Shell tests` is the only required status
# check in .github/rulesets/main.json, and an omp-backed run pushes under the
# maintainer's own login, so the author cannot say which merged pull requests an
# agent wrote. The body is shell and jq inside a YAML string, so run-tests.sh
# does not find it, test-shell-syntax.sh does not `bash -n` it and shellcheck
# never sees it. What it decides, and how each half fails quietly:
#
#   1. Which pull requests are an agent's. The Hive app's by author; an
#      omp-backed one only by its signature line; Dependabot and Renovate are
#      bots but not agents. Drop the second clause and every omp-backed pull
#      request leaves the audit; widen the first to "any bot" and every
#      dependency bump is reported as an agent with no signature.
#   2. What turns the run red: a Hive-app pull request without a signature
#      line, and an agent pull request with an unsigned commit, merged on or
#      after the enforcement date. A miss before that date is listed and does
#      not fail, so a manual run over an older window is not red for history.
#   3. That a window which fills the `gh pr list` cap is refused, not audited
#      in part, and that a malformed date is refused before any query.
#
# The step is extracted from the workflow with PyYAML and run as a real
# subprocess against a recording `gh` stub that serves staged JSON, with the
# real jq doing the classification. The `on:` key is the known YAML 1.1 trap
# (a bare `on` is the boolean true), so the normalizer renames it and is
# checked against a fixture before it is trusted on the real file.

set -uo pipefail

TEST_NAME="test-agent-audit"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

AUDIT_WF="${REPO_ROOT}/.github/workflows/agent-audit.yml"
POLICY="${REPO_ROOT}/.github/policies/workflow-permissions.json"
WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"
STEP_NAME="Audit merged agent pull requests"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

if [[ ! -f "${AUDIT_WF}" ]]; then
    _fail "agent-audit.yml exists" \
        "no such file: ${AUDIT_WF}" \
        "if the workflow was removed on purpose, delete this test with it"
    finish
    exit 1
fi

# The audit decides whether a pull request left its record; a missing parser
# must fail rather than skip.
if ! "${WORKFLOW_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    _fail "the agent-audit.yml step check requires Python 3 with PyYAML" \
        "install python3-yaml (Debian/Ubuntu) or python3-pyyaml (Fedora)," \
        "or install PyYAML in the interpreter selected by WORKFLOW_PYTHON"
    finish
    exit 1
fi

# --- normalizer, tested before it is trusted --------------------------------

NORMALIZER="${TMP_ROOT}/normalize.py"
cat >"${NORMALIZER}" <<'PY'
"""Print one workflow file as JSON, with the `on:` key readable by name."""

import json
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = yaml.safe_load(handle)

if isinstance(doc, dict) and True in doc:
    doc["on"] = doc.pop(True)

json.dump(doc, sys.stdout)
PY

fixture="${TMP_ROOT}/fixture.yml"
cat >"${fixture}" <<'YAML'
---
name: Fixture
on:
  schedule:
    - cron: '23 5 1 * *'
jobs:
  demo:
    steps:
      - name: Named step
        run: |
          echo marker
YAML

fixture_json="${TMP_ROOT}/fixture.json"
if "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${fixture}" >"${fixture_json}" 2>"${TMP_ROOT}/fixture.err"; then
    assert_eq "the normalizer reads a fixture's schedule by name" \
        "23 5 1 * *" "$(jq -r '.on.schedule[0].cron' <"${fixture_json}")"
    assert_eq "the normalizer reads a fixture's block-scalar run: body" \
        "echo marker" "$(jq -r '.jobs.demo.steps[0].run' <"${fixture_json}")"
else
    _fail "the normalizer parses a fixture workflow" "$(cat "${TMP_ROOT}/fixture.err")"
fi

# --- the real file ----------------------------------------------------------

WF_JSON="${TMP_ROOT}/audit.json"
if ! "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${AUDIT_WF}" >"${WF_JSON}" 2>"${TMP_ROOT}/wf.err"; then
    _fail "agent-audit.yml parses as YAML" "$(cat "${TMP_ROOT}/wf.err")"
    finish
    exit 1
fi
_pass "agent-audit.yml parses as YAML"

wf() {
    jq -r "$1" <"${WF_JSON}"
}

STEP="${TMP_ROOT}/audit-step.sh"
wf ".jobs[].steps[] | select(.name == \"${STEP_NAME}\") | .run" >"${STEP}"
if [[ ! -s "${STEP}" ]] || ! grep -q 'gh pr list' "${STEP}"; then
    _fail "the '${STEP_NAME}' script was extracted from agent-audit.yml" \
        "expected a run: body containing 'gh pr list'; extracted $(wc -c <"${STEP}") byte(s)" \
        "the step name probably changed — update this test to match"
    finish
    exit 1
fi
_pass "the '${STEP_NAME}' script was extracted from agent-audit.yml"

# --- what the workflow is allowed to be -------------------------------------
#
# The policy file and test-workflow-permissions.sh already pin the token; what
# is checked here is the claim the header and docs/SECURITY-AI.md make beyond
# it: nothing is checked out and no action runs, so there is no `uses:` to pin.

assert_eq "the job's token is contents: read and pull-requests: read, as the policy records" \
    "$(jq -cS '.workflows["agent-audit.yml"].jobs.audit' "${POLICY}")" \
    "$(wf '.jobs.audit.permissions' | jq -cS .)"
assert_eq "the workflow declares no top-level token block" "null" "$(wf '.permissions')"
assert_eq "the job runs no action and checks nothing out" "0" \
    "$(wf '[.jobs[].steps[] | select(has("uses"))] | length')"
assert_eq "it runs on a schedule and on demand, and on nothing else" \
    "schedule,workflow_dispatch" "$(wf '.on | keys | join(",")')"
assert_eq "the date reaches the step through env, not through the shell text" \
    "\${{ inputs.since }}" "$(wf ".jobs.audit.steps[] | select(.name == \"${STEP_NAME}\") | .env.SINCE")"

# --- fixtures and the runner ------------------------------------------------

REPO_NAME="Danathar/aurora-zfs-simple"
APP="app/danathar-atomic-hive"
SIG="— hive: backend=omp model=anthropic/claude-opus-5-5 effort=high"
SIGNED="Summary

Signed-off-by: Danathar <Danathar@users.noreply.github.com>"

# pr <number> <author login> <merged date> <signature: yes|no>  — one `gh pr list` element.
pr() {
    local number=$1 author=$2 merged=$3 signed=$4 body="## Why

A change."
    if [[ "${signed}" == "yes" ]]; then
        body+="

${SIG}"
    fi
    jq -n --argjson n "${number}" --arg a "${author}" --arg d "${merged}" --arg b "${body}" --arg r "${REPO_NAME}" '{
        number: $n, title: "fix: thing \($n)", body: $b,
        url: "https://github.com/\($r)/pull/\($n)",
        mergedAt: "\($d)T12:00:00Z", mergedBy: {login: "Danathar"},
        author: {login: $a, is_bot: ($a | startswith("app/"))}
    }'
}

# detail <number> <message body>...  — `gh pr view --json number,commits`.
detail() {
    local number=$1 index=0 body commits='[]'
    shift
    for body in "$@"; do
        commits="$(jq -c --arg b "${body}" --arg o "$(printf '%03d%04d%033d' "${number}" "${index}" 0)" \
            '. + [{oid: $o, messageBody: $b}]' <<<"${commits}")"
        index=$((index + 1))
    done
    jq -n --argjson n "${number}" --argjson c "${commits}" '{number: $n, commits: $c}'
}

# run_audit <since> — runs the extracted step in a fresh directory against the
# staged $CASE_DIR/merged.json and $CASE_DIR/pr-N.json. Sets A_STATUS, A_OUT,
# A_SUMMARY and A_CALLS.
run_audit() {
    local since=$1
    mkdir -p "${CASE_DIR}/bin" "${CASE_DIR}/work"
    cat >"${CASE_DIR}/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_LOG}"
case "$1 $2" in
    "pr list") cat "${STUB_DIR}/merged.json" ;;
    "pr view") cat "${STUB_DIR}/pr-$3.json" ;;
    "api repos/"*) cat "${STUB_DIR}/parents-${2##*/}" 2>/dev/null || printf '1\n' ;;
    *) echo "gh stub: unexpected command: $*" >&2; exit 97 ;;
esac
STUB
    chmod +x "${CASE_DIR}/bin/gh"
    : >"${CASE_DIR}/summary.md"
    : >"${CASE_DIR}/calls"
    A_OUT="$(
        cd "${CASE_DIR}/work" &&
            PATH="${CASE_DIR}/bin:${PATH}" \
                STUB_DIR="${CASE_DIR}" STUB_LOG="${CASE_DIR}/calls" \
                GH_TOKEN="not-a-real-token" REPO="${REPO_NAME}" SINCE="${since}" \
                GITHUB_STEP_SUMMARY="${CASE_DIR}/summary.md" \
                bash "${STEP}" 2>&1
    )"
    A_STATUS=$?
    A_SUMMARY="$(cat "${CASE_DIR}/summary.md")"
    A_CALLS="$(cat "${CASE_DIR}/calls")"
}

new_case() {
    CASE_DIR="$(mktemp -d "${TMP_ROOT}/case.XXXXXX")"
}

# stage_list <pr json>...  — writes merged.json.
stage_list() {
    jq -s . <<<"$*" >"${CASE_DIR}/merged.json"
}

# stage_detail <number> <message body>...
stage_detail() {
    local number=$1
    shift
    detail "${number}" "$@" >"${CASE_DIR}/pr-${number}.json"
}

# =============================================================================
# A. A clean window
# =============================================================================

new_case
stage_list "$(pr 10 "${APP}" 2026-10-02 yes)" \
    "$(pr 11 Danathar 2026-10-02 yes)" \
    "$(pr 12 Danathar 2026-10-02 no)" \
    "$(pr 13 app/dependabot 2026-10-02 no)" \
    "$(pr 14 app/renovate 2026-10-02 no)"
stage_detail 10 "${SIGNED}"
stage_detail 11 "${SIGNED}" "${SIGNED}"
run_audit 2026-10-01
assert_eq "a window where every record is complete exits 0" "0" "${A_STATUS}"
assert_contains "the summary counts the agent pull requests against the window" \
    "${A_SUMMARY}" "2 of the 5 pull requests merged in the window were written by an agent."
assert_contains "a Hive-app pull request is listed with its backend and model" \
    "${A_SUMMARY}" "| ${APP} | Danathar | backend=omp model=anthropic/claude-opus-5-5 effort=high | 1 | all |"
assert_contains "a maintainer-login pull request is listed by its signature line alone" \
    "${A_SUMMARY}" "[#11](https://github.com/${REPO_NAME}/pull/11)"
assert_not_contains "a maintainer's unsigned pull request is not an agent's" "${A_SUMMARY}" "#12"
assert_not_contains "Dependabot is not an agent" "${A_SUMMARY}" "#13"
assert_not_contains "Renovate is not an agent" "${A_SUMMARY}" "#14"
assert_not_contains "a clean window has no findings" "${A_SUMMARY}" "#### Findings"
assert_not_contains "only agent pull requests have their commits fetched" "${A_CALLS}" "pr view 12"
assert_contains "the query asks for merged pull requests since the date" \
    "${A_CALLS}" "--state merged --limit 500 --search merged:>=2026-10-01"
assert_contains "the query is scoped to the repository" "${A_CALLS}" "--repo ${REPO_NAME}"
assert_eq "the table is also printed to the log" "${A_SUMMARY}" "${A_OUT}"

# =============================================================================
# B. A Hive-app pull request with no signature line
# =============================================================================

new_case
stage_list "$(pr 20 "${APP}" 2026-10-02 no)" "$(pr 21 "${APP}" 2026-10-02 yes)"
stage_detail 20 "${SIGNED}"
stage_detail 21 "${SIGNED}"
run_audit 2026-10-01
assert_eq "a Hive-app pull request without a signature line exits 1" "1" "${A_STATUS}"
assert_contains "the row shows the signature as missing" "${A_SUMMARY}" "| **missing** |"
assert_contains "the finding names the pull request" \
    "${A_SUMMARY}" "- #20: opened by the Hive app with no \`— hive:\` signature line"
assert_not_contains "the signed pull request is not a finding" "${A_SUMMARY}" "- #21:"
assert_contains "the failure is annotated as an error" "${A_OUT}" "::error::1 finding(s)"

# A maintainer-login pull request has no signature line to be missing: it is
# only in the audit because it has one.

# =============================================================================
# C. An unsigned commit
# =============================================================================

new_case
stage_list "$(pr 30 Danathar 2026-10-02 yes)"
stage_detail 30 "${SIGNED}" "no trailer here" "${SIGNED}"
run_audit 2026-10-01
assert_eq "an agent pull request with an unsigned commit exits 1" "1" "${A_STATUS}"
assert_contains "the finding names the unsigned commit" \
    "${A_SUMMARY}" "- #30: commit(s) 0300001 carry no Signed-off-by trailer"
assert_contains "the row says how many commits are signed off" "${A_SUMMARY}" "| 3 | **2 of 3** |"

new_case
stage_list "$(pr 31 "${APP}" 2026-10-02 yes)"
stage_detail 31 "" "Signed-off-by-not: x"
run_audit 2026-10-01
assert_eq "an empty message and a near-miss trailer both count as unsigned" "1" "${A_STATUS}"
assert_contains "both unsigned commits are named together" \
    "${A_SUMMARY}" "commit(s) 0310000, 0310001 carry no Signed-off-by trailer"

# A merge commit carries no trailer: docs/multi-agent.md asks for a pull
# request to be updated from `main`, and GitHub's "Update branch" writes a
# merge with none. It is told apart by its parent count, which `gh pr view`
# does not return, so the step asks `gh api` for each untrailered commit.
new_case
stage_list "$(pr 32 "${APP}" 2026-10-02 yes)"
stage_detail 32 "${SIGNED}" ""
printf '2\n' >"${CASE_DIR}/parents-0320001$(printf '%033d' 0)"
run_audit 2026-10-01
assert_eq "a merge commit with no trailer does not fail the run" "0" "${A_STATUS}"
assert_contains "and the row reads as all signed off" "${A_SUMMARY}" "| 2 | all |"
assert_eq "parents are asked only for the commit that lacks a trailer" \
    "api repos/${REPO_NAME}/commits/0320001$(printf '%033d' 0) --jq .parents | length" \
    "$(grep '^api' <<<"${A_CALLS}")"

new_case
stage_list "$(pr 33 "${APP}" 2026-10-02 yes)"
stage_detail 33 "" "Merge branch 'main' into docs/x"
printf '2\n' >"${CASE_DIR}/parents-0330000$(printf '%033d' 0)"
run_audit 2026-10-01
assert_eq "an unsigned commit with one parent still fails the run" "1" "${A_STATUS}"
assert_contains "the finding names it and not the merge, whatever the headline says" \
    "${A_SUMMARY}" "- #33: commit(s) 0330001 carry no Signed-off-by trailer"

# =============================================================================
# D. History before the enforcement date is reported, not failed
# =============================================================================

enforce_from="$(grep -m1 '^ *enforce_from=' "${STEP}" | cut -d'"' -f2)"
if [[ ! "${enforce_from}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    _fail "the step declares its enforcement date as enforce_from=\"YYYY-MM-DD\"" "found: ${enforce_from:-nothing}"
    enforce_from="2026-09-29"
fi
day_before="$(date -u -d "${enforce_from} - 1 day" +%F)"

new_case
stage_list "$(pr 40 "${APP}" "${day_before}" no)" "$(pr 41 Danathar "${day_before}" yes)"
stage_detail 40 "${SIGNED}"
stage_detail 41 "no trailer"
run_audit 2026-09-01
assert_eq "misses merged before the enforcement date do not fail the run" "0" "${A_STATUS}"
assert_contains "they are still listed, under their own heading" \
    "${A_SUMMARY}" "#### Before enforcement"
assert_contains "the missing signature is among them" \
    "${A_SUMMARY}" "- #40: opened by the Hive app with no \`— hive:\` signature line"
assert_contains "the unsigned commit is among them" \
    "${A_SUMMARY}" "- #41: commit(s) 0410000 carry no Signed-off-by trailer"
assert_not_contains "they are not listed as findings" "${A_SUMMARY}" "#### Findings"

new_case
stage_list "$(pr 42 "${APP}" "${enforce_from}" no)"
stage_detail 42 "${SIGNED}"
run_audit 2026-09-01
assert_eq "a miss merged on the enforcement date fails the run" "1" "${A_STATUS}"
assert_contains "and is a finding" "${A_SUMMARY}" "#### Findings"

# =============================================================================
# E. The cap, and a bad date
# =============================================================================

new_case
jq -n '[range(0; 500) | {number: ., title: "t", body: "", url: "u", mergedAt: "2026-10-01T00:00:00Z", mergedBy: {login: "x"}, author: {login: "x", is_bot: false}}]' \
    >"${CASE_DIR}/merged.json"
run_audit 2026-10-01
assert_eq "a window that fills the cap is refused with exit 2" "2" "${A_STATUS}"
assert_contains "the refusal says why" "${A_OUT}" "::error::500 pull requests merged since 2026-10-01 reached the 500 cap"
assert_eq "a refused window writes nothing to the summary" "" "${A_SUMMARY}"

new_case
stage_list "$(pr 50 Danathar 2026-10-02 yes)"
run_audit "last month"
assert_eq "a malformed date exits 2" "2" "${A_STATUS}"
assert_contains "it is annotated as an error" "${A_OUT}" "::error::since must be YYYY-MM-DD, got 'last month'"
assert_eq "gh is not called with a malformed date" "" "${A_CALLS}"

new_case
stage_list
run_audit ""
assert_eq "a blank date means the last 31 days and an empty window passes" "0" "${A_STATUS}"
assert_contains "the default window starts 31 days back" \
    "${A_CALLS}" "--search merged:>=$(date -u -d '31 days ago' +%F)"
assert_contains "an empty window is reported as such" \
    "${A_SUMMARY}" "0 of the 0 pull requests merged in the window were written by an agent."

# =============================================================================
# F. Near misses: text that looks like the record but is not
# =============================================================================
#
# A pull request about this audit says "— hive:" in its prose, and a commit
# message can quote a trailer mid-line. Only a line that STARTS with the
# signature, and a trailer that starts its own line, count. Each case below
# was a surviving mutant of the step before it was added.

# pr_with <number> <author> <title> <body> [merged-by login or "null"]
pr_with() {
    local by=${5:-Danathar}
    jq -n --argjson n "$1" --arg a "$2" --arg t "$3" --arg b "$4" --arg by "${by}" --arg r "${REPO_NAME}" '{
        number: $n, title: $t, body: $b,
        url: "https://github.com/\($r)/pull/\($n)",
        mergedAt: "2026-10-02T12:00:00Z",
        mergedBy: (if $by == "null" then null else {login: $by} end),
        author: {login: $a, is_bot: ($a | startswith("app/"))}
    }'
}

PROSE="Every agent pull request ends with a \`— hive:\` line naming its model."

new_case
stage_list "$(pr_with 60 Danathar "docs: explain the audit" "${PROSE}")" \
    "$(pr_with 61 "${APP}" "fix: prose only" "${PROSE}")" \
    "$(pr_with 62 "${APP}" "fix: prose then signature" "${PROSE}

${SIG}")"
stage_detail 61 "${SIGNED}"
stage_detail 62 "${SIGNED}"
run_audit 2026-10-01
assert_not_contains "a maintainer pull request that mentions '— hive:' mid-line is not an agent's" \
    "${A_SUMMARY}" "#60"
assert_not_contains "so its commits are not fetched" "${A_CALLS}" "pr view 60"
assert_contains "a Hive-app pull request whose only '— hive:' is mid-line has no signature" \
    "${A_SUMMARY}" "- #61: opened by the Hive app with no \`— hive:\` signature line"
assert_contains "the backend is read from the line that starts with the signature, not from prose" \
    "${A_SUMMARY}" "| ${APP} | Danathar | backend=omp model=anthropic/claude-opus-5-5 effort=high | 1 | all |"
assert_not_contains "no prose line is reported as a backend" "${A_SUMMARY}" "naming its model"
assert_eq "the prose-only Hive-app pull request fails the run" "1" "${A_STATUS}"
assert_not_contains "a window with only enforced rows has no history section" \
    "${A_SUMMARY}" "#### Before enforcement"

new_case
stage_list "$(pr 63 "${APP}" 2026-10-02 yes)"
stage_detail 63 "Reverts a change that was Signed-off-by: someone else"
run_audit 2026-10-01
assert_eq "a trailer quoted mid-line does not sign the commit off" "1" "${A_STATUS}"
assert_contains "and the commit is named" "${A_SUMMARY}" "- #63: commit(s) 0630000 carry no Signed-off-by trailer"

# =============================================================================
# G. The table: cells, dates, and an absent merger
# =============================================================================

new_case
stage_list "$(pr_with 70 "${APP}" "fix(ci): a | b" "${SIG}" null)"
stage_detail 70 "${SIGNED}"
run_audit 2026-10-01
assert_eq "a title with a pipe and no merger still audits cleanly" "0" "${A_STATUS}"
assert_contains "a pipe in a title is escaped so it does not split the row" \
    "${A_SUMMARY}" "fix(ci): a \\| b |"
assert_contains "the merge date is the day, and a missing merger is 'unknown'" \
    "${A_SUMMARY}" "| 2026-10-02 | ${APP} | unknown |"

new_case
stage_list
run_audit 2026-10-01
assert_not_contains "an empty window prints no table header" "${A_SUMMARY}" "| PR | Merged |"

# =============================================================================
# H. A commit list that could not be fetched is an error, not zero commits
# =============================================================================
#
# A `gh pr view` that fails partway through the loop must stop the run: under
# errexit and pipefail the loop's failure is the pipeline's. Audited instead,
# the pull request would reach the row builder with nothing fetched -- which
# refuses it by name as a second line of defence.

new_case
stage_list "$(pr 80 "${APP}" 2026-10-02 yes)" "$(pr 81 "${APP}" 2026-10-02 yes)" \
    "$(pr 82 "${APP}" 2026-10-02 yes)"
stage_detail 80 "${SIGNED}"
stage_detail 82 "${SIGNED}"
run_audit 2026-10-01
assert_eq "a pull request whose commits could not be fetched fails the run" "1" "${A_STATUS}"
assert_not_contains "it is not audited as signed" "${A_OUT}" "No finding"
assert_eq "nothing is written to the summary" "" "${A_SUMMARY}"

new_case
stage_list "$(pr 90 Danathar 2026-10-02 yes)"
run_audit "2026-10-1"
assert_eq "a date with a one-digit day is refused" "2" "${A_STATUS}"
assert_eq "and gh is not called" "" "${A_CALLS}"

finish
