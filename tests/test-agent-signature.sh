#!/usr/bin/env bash
#
# Covers .github/workflows/agent-signature.yml -- the advisory check that an
# open agent pull request's description carries the `— hive:` signature line
# agent-audit.yml reads back after the merge.
#
# The point of the workflow is to catch, before the merge, exactly what the
# audit would fail after it. Two copies of one rule drift apart quietly: edit
# the audit's test and the pull request check keeps passing descriptions the
# audit will fail, or the reverse. So three things are held here:
#
#   1. Drift. The workflow's `def signature:` lines are agent-audit.yml's,
#      character for character once leading spaces are dropped, and the audit
#      still has exactly one such definition for this to compare against.
#   2. Shape. `pull_request` with the four activity types and nothing else
#      (never `pull_request_target`); the job's `if:` naming the Hive app's
#      webhook login and the `ai-fix/` prefix; a token with no scope, as the
#      policy file records; no checkout and no action; the description passed
#      through `env:`, never written into the script; and closed key sets on
#      the job and its one step, so no `continue-on-error` can paint a miss
#      green unnoticed.
#   3. Behaviour. The step is extracted with PyYAML and run as a real
#      subprocess with the real jq, against descriptions with and without the
#      line; each verdict is also compared with the audit's own definition run
#      on the same text, so the two agree in effect and not only in spelling.
#
# The `on:` key is the YAML 1.1 trap (a bare `on` is the boolean true), so the
# normalizer renames it and is checked against a fixture before it is trusted.

set -uo pipefail

TEST_NAME="test-agent-signature"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

SIGNATURE_WF="${REPO_ROOT}/.github/workflows/agent-signature.yml"
AUDIT_WF="${REPO_ROOT}/.github/workflows/agent-audit.yml"
POLICY="${REPO_ROOT}/.github/policies/workflow-permissions.json"
WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"
STEP_NAME="Check the description for the signature line"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

for file in "${SIGNATURE_WF}" "${AUDIT_WF}"; do
    if [[ ! -f "${file}" ]]; then
        _fail "$(basename "${file}") exists" \
            "no such file: ${file}" \
            "if a workflow was removed on purpose, delete this test with it"
        finish
        exit 1
    fi
done

if ! "${WORKFLOW_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    _fail "the agent-signature.yml check requires Python 3 with PyYAML" \
        "install python3-yaml (Debian/Ubuntu) or python3-pyyaml (Fedora)," \
        "or install PyYAML in the interpreter selected by WORKFLOW_PYTHON"
    finish
    exit 1
fi

# --- 1. the same test as the audit -------------------------------------------

# def_lines <file> -- every `def signature:` line and the line after it, with
# leading spaces dropped (the two files nest the jq program differently).
def_lines() {
    grep -A1 -E '^[[:space:]]*def signature:' "$1" | sed -E 's/^[[:space:]]+//'
}

AUDIT_DEF="$(def_lines "${AUDIT_WF}")"
CHECK_DEF="$(def_lines "${SIGNATURE_WF}")"

assert_eq "agent-audit.yml has exactly one two-line def signature" \
    "2" "$(printf '%s\n' "${AUDIT_DEF}" | grep -c .)"
assert_contains "the audit's definition is a line starting with the signature" \
    "${AUDIT_DEF}" 'map(select(startswith("— hive:")))'
assert_eq "agent-signature.yml runs agent-audit.yml's def signature, character for character" \
    "${AUDIT_DEF}" "${CHECK_DEF}"

# --- normalizer, tested before it is trusted ---------------------------------

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
  pull_request:
    types: [opened, edited]
jobs:
  demo:
    steps:
      - name: Named step
        run: |
          echo marker
YAML

fixture_json="${TMP_ROOT}/fixture.json"
if "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${fixture}" >"${fixture_json}" 2>"${TMP_ROOT}/fixture.err"; then
    assert_eq "the normalizer reads a fixture's pull_request types by name" \
        "opened,edited" "$(jq -r '.on.pull_request.types | join(",")' <"${fixture_json}")"
    assert_eq "the normalizer reads a fixture's block-scalar run: body" \
        "echo marker" "$(jq -r '.jobs.demo.steps[0].run' <"${fixture_json}")"
else
    _fail "the normalizer parses a fixture workflow" "$(cat "${TMP_ROOT}/fixture.err")"
fi

# --- the real file -------------------------------------------------------------

WF_JSON="${TMP_ROOT}/signature.json"
if ! "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${SIGNATURE_WF}" >"${WF_JSON}" 2>"${TMP_ROOT}/wf.err"; then
    _fail "agent-signature.yml parses as YAML" "$(cat "${TMP_ROOT}/wf.err")"
    finish
    exit 1
fi
_pass "agent-signature.yml parses as YAML"

wf() {
    jq -r "$1" <"${WF_JSON}"
}

# --- 2. what the workflow is allowed to be -------------------------------------

assert_eq "it runs on pull_request and on nothing else, so never on pull_request_target" \
    "pull_request" "$(wf '.on | keys | join(",")')"
assert_eq "it runs when a pull request is opened, edited, reopened or pushed to" \
    "opened,edited,reopened,synchronize" "$(wf '.on.pull_request.types | join(",")')"
assert_eq "the workflow declares no top-level token block" "null" "$(wf '.permissions')"
assert_eq "the workflow has exactly one job, signature" "signature" "$(wf '.jobs | keys | join(",")')"
assert_eq "the job has only the keys it needs, so nothing can soften its failure" \
    "if,permissions,runs-on,steps,timeout-minutes" "$(wf '.jobs.signature | keys | join(",")')"
assert_eq "the job's token holds no scope" "{}" "$(wf '.jobs.signature.permissions | tojson')"
assert_eq "and that is what the policy file records" \
    "$(jq -cS '.workflows["agent-signature.yml"].jobs.signature' "${POLICY}")" \
    "$(wf '.jobs.signature.permissions' | jq -cS .)"
assert_eq "the job runs no action and checks nothing out" "0" \
    "$(wf '[.jobs[].steps[] | select(has("uses"))] | length')"
assert_eq "the job has exactly one step" "1" "$(wf '.jobs.signature.steps | length')"
assert_eq "the step has only name, env and run, so a miss fails the job" \
    "env,name,run" "$(wf '.jobs.signature.steps[0] | keys | join(",")')"
assert_eq "the one step is the check" "${STEP_NAME}" "$(wf '.jobs.signature.steps[0].name')"
assert_eq "the description reaches the step through env, not through the shell text" \
    "\${{ github.event.pull_request.body }}" "$(wf '.jobs.signature.steps[0].env.PR_BODY')"

# The audit counts a pull request as an agent's when `gh` names the Hive app as
# its author; the event names the same app by its webhook login.
assert_contains "agent-audit.yml names the Hive app as gh spells it" \
    "$(cat "${AUDIT_WF}")" '"app/danathar-atomic-hive"'
assert_eq "the job runs for the Hive app's pull requests and for ai-fix/ branches only" \
    "github.event.pull_request.user.login == 'danathar-atomic-hive[bot]' || startsWith(github.event.pull_request.head.ref, 'ai-fix/')" \
    "$(wf '.jobs.signature.if')"

STEP="${TMP_ROOT}/signature-step.sh"
wf ".jobs.signature.steps[] | select(.name == \"${STEP_NAME}\") | .run" >"${STEP}"
if [[ ! -s "${STEP}" ]] || ! grep -q 'def signature:' "${STEP}"; then
    _fail "the '${STEP_NAME}' script was extracted from agent-signature.yml" \
        "expected a run: body containing 'def signature:'; extracted $(wc -c <"${STEP}") byte(s)" \
        "the step name probably changed -- update this test to match"
    finish
    exit 1
fi
_pass "the '${STEP_NAME}' script was extracted from agent-signature.yml"
assert_not_contains "the script holds no Actions expression" "$(cat "${STEP}")" "\${{"

# --- 3. what it decides ----------------------------------------------------------

# run_step <description> -- runs the extracted step with PR_BODY set to the
# description. Sets S_STATUS and S_OUT.
run_step() {
    S_OUT="$(PR_BODY="$1" bash "${STEP}" 2>&1)"
    S_STATUS=$?
}

# audit_verdict <description> -- 0 when the audit's own definition finds a
# signature line in the description, 1 when it does not.
audit_verdict() {
    local found
    # The jq program is meant to see `$b` literally.
    # shellcheck disable=SC2016
    found="$(jq -nr --arg b "$1" "${AUDIT_DEF}"$'\n''{body: $b} | signature // empty')"
    if [[ -n "${found}" ]]; then echo 0; else echo 1; fi
}

# check <expected status> <label> <description>
check() {
    local expected=$1 label=$2 body=$3
    run_step "${body}"
    assert_eq "${label}" "${expected}" "${S_STATUS}"
    assert_eq "the audit's definition agrees: ${label}" "${expected}" "$(audit_verdict "${body}")"
    if [[ "${expected}" == "1" ]]; then
        assert_contains "the miss is an error annotation: ${label}" "${S_OUT}" "::error::"
    fi
}

check 0 "a Hive description ending in its signature line passes" \
    $'**Summary:** a change.\n\n---\n\nRefs Danathar/aurora-zfs-simple#1\n\n— hive: agent=scanner backend=claude model=claude-opus-5-5'
check 0 "an omp-style line with no agent= key passes, as the audit lists it" \
    $'A change.\n\n— hive: backend=omp model=anthropic/claude-opus-5-5 effort=high'
check 0 "a description with Windows line endings passes" \
    $'A change.\r\n\r\n— hive: agent=scanner backend=claude\r\n'
check 1 "a description with a Filed-by footer and no signature fails" \
    $'A change.\n\nFiled by the scanner agent'
check 1 "an empty description fails" ""
check 1 "the signature text in the middle of a line fails" \
    $'This ends with — hive: agent=scanner as prose.'
check 1 "an indented signature fails, as the audit would fail it" \
    $'A change.\n\n  — hive: agent=scanner'
check 1 "an ASCII hyphen is not the signature's dash" \
    $'A change.\n\n- hive: agent=scanner'

run_step $'::warning::injected\n\n— hive: agent=scanner'
assert_not_contains "the description is never echoed into the log" "${S_OUT}" "injected"
run_step $'::warning::injected'
assert_not_contains "not even when the check fails" "${S_OUT}" "injected"

S_OUT="$(env -u PR_BODY bash "${STEP}" 2>&1)"
S_STATUS=$?
assert_eq "a step with no PR_BODY at all fails rather than passes" "1" "${S_STATUS}"

finish
