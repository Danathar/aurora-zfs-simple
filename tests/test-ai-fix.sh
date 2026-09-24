#!/usr/bin/env bash
#
# Covers .github/workflows/ai-fix.yml — the one workflow in this repository that
# grants `contents: write` to a job an outside event can start, and the only one
# no test referenced at all.
#
# Two things are checked here, because the file has two failure modes and they
# are not the same shape.
#
# 1. The `preflight` step's script decides whether an agent runs. It is 65 lines
#    of shell living inside a YAML string, so nothing in this repository ever
#    executed it: not the shell suite (it is not a *.sh file), not shellcheck,
#    not `bash -n`. Its four outcomes — bot sender, no credentials, fork head,
#    hand off — are the access-control decision, and the wrong one is silent in
#    both directions. `run=no` where `yes` belongs looks like a quiet workflow;
#    `run=yes` where `no` belongs starts an agent with push access on an event
#    the header says must never start one.
#
#    So the script is extracted from the YAML and run, with a stub `gh` and the
#    step's `env:` block supplied case by case. What is asserted is the pair the
#    workflow actually uses: the `run=` output the `fix` job gates on, and the
#    run-summary text that is a human's only explanation of a skip.
#
#    The plain-issue case is asserted as a contract rather than as a shape. The
#    script's own comment explains the nested `if` on `ISSUE_IS_PR` as a `set -e`
#    guard, on the reasoning that `[ ... ] && pr=...` would end the step when the
#    test is false. Measured, that is not what bash does in this position: a
#    failing command in an `&&` list is exempt from errexit, and the list sits
#    inside an `if` body with code after it, so the terse form would behave
#    identically here. What is asserted below is therefore the behaviour the
#    `fix` job depends on — a comment on a plain issue consults no API, hands
#    off, and exits 0 — which catches the error that does bite, namely treating
#    an ordinary issue as a pull request and then refusing it as a fork.
#
#    Ordering is asserted too. The bot check runs before the credentials check,
#    so a bot-triggered run reports that it was a bot rather than that the
#    repository is unconfigured. Reversed, the summary sends a maintainer to set
#    the secrets — after which every `danathar-atomic-hive[bot]` label event
#    starts an agent — and the `run=no` output is identical either way, so
#    nothing but the summary text can tell the two apart.
#
# 2. The permissions, triggers and action inputs are the security invariants the
#    header argues for at length. Prose does not fail. The header explains that
#    `pull_request_review` and `pull_request_review_comment` were removed because
#    they run the *head branch's* copy of the workflow, so a pull request could
#    edit its own trigger and reach a job holding `contents: write`; that
#    reasoning is load-bearing and nothing stopped either trigger from being
#    added back. Same for `allowed_bots: ''` (a bot finding is a claim, not an
#    instruction), for the absence of `packages: write` (nothing here can push an
#    image), and for `needs.preflight.outputs.run == 'yes'` (delete that line and
#    every check in section A stops mattering, while all of them still pass).
#
# The YAML is read with PyYAML rather than by hand: the values that matter here
# are block scalars, quoted empty strings and a boolean, and an indentation
# parser distinguishing `allowed_bots: ''` from an absent key is the kind of
# thing that fails open. The `on:` key is the known trap — YAML 1.1 reads a bare
# `on` as the boolean true — so the normalizer renames it back and is checked
# against a fixture with a known answer before it is trusted on the real file.

set -uo pipefail

TEST_NAME="test-ai-fix"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

AI_FIX_WF="${REPO_ROOT}/.github/workflows/ai-fix.yml"
WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

if [[ ! -f "${AI_FIX_WF}" ]]; then
    _fail "ai-fix.yml exists" \
        "no such file: ${AI_FIX_WF}" \
        "if the workflow was removed on purpose, delete this test with it"
    finish
    exit 1
fi

# This checks a security invariant; a missing parser must fail rather than skip,
# including when the file is invoked directly instead of through run-tests.sh.
if ! "${WORKFLOW_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    _fail "the ai-fix.yml checker requires Python 3 with PyYAML" \
        "install python3-yaml (Debian/Ubuntu) or python3-pyyaml (Fedora)," \
        "or install PyYAML in the interpreter selected by WORKFLOW_PYTHON"
    finish
    exit 1
fi

# --- normalizer -------------------------------------------------------------

NORMALIZER="${TMP_ROOT}/normalize.py"
cat >"${NORMALIZER}" <<'PY'
"""Print one workflow file as JSON, with the `on:` key readable by name.

YAML 1.1 — which is what PyYAML implements, and what Actions accepts — reads a
bare `on` as the boolean true, so `doc["on"]` raises KeyError on every workflow
ever written. Renaming it here keeps that quirk in one place instead of in
every jq path below.
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

# --- the normalizer is tested before it is trusted --------------------------

fixture="${TMP_ROOT}/fixture.yml"
cat >"${fixture}" <<'YAML'
---
name: Fixture
on:
  issues:
    types:
      - labeled
jobs:
  demo:
    permissions:
      contents: read
    steps:
      - id: check
        run: |
          echo marker
YAML

fixture_json="${TMP_ROOT}/fixture.json"
if "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${fixture}" >"${fixture_json}" 2>"${TMP_ROOT}/fixture.err"; then
    assert_eq "the normalizer reads a fixture's trigger by name" \
        "labeled" "$(jq -r '.on.issues.types[0]' <"${fixture_json}")"
    assert_eq "the normalizer reads a fixture's block-scalar run: body" \
        "echo marker" "$(jq -r '.jobs.demo.steps[0].run' <"${fixture_json}")"
    assert_eq "the normalizer reads a fixture's permissions block" \
        "read" "$(jq -r '.jobs.demo.permissions.contents' <"${fixture_json}")"
else
    _fail "the normalizer parses a fixture workflow" "$(cat "${TMP_ROOT}/fixture.err")"
fi

# --- the real file ----------------------------------------------------------

WF_JSON="${TMP_ROOT}/ai-fix.json"
if ! "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${AI_FIX_WF}" >"${WF_JSON}" 2>"${TMP_ROOT}/wf.err"; then
    _fail "ai-fix.yml parses as YAML" "$(cat "${TMP_ROOT}/wf.err")"
    finish
    exit 1
fi
_pass "ai-fix.yml parses as YAML"

# wf <jq expression> — one value out of the parsed workflow.
wf() {
    jq -r "$1" <"${WF_JSON}"
}

# =============================================================================
# A. the preflight script, executed
# =============================================================================

PREFLIGHT="${TMP_ROOT}/preflight.sh"
wf '.jobs.preflight.steps[] | select(.id == "check") | .run' >"${PREFLIGHT}"

# An empty extraction would make every case below pass vacuously: the script
# would be an empty file that exits 0, writes no summary and no output, and the
# assertions would then be measuring nothing.
if [[ ! -s "${PREFLIGHT}" ]] || ! grep -q 'run=' "${PREFLIGHT}"; then
    _fail "the preflight decision script was extracted from ai-fix.yml" \
        "expected the 'check' step of the preflight job to carry a run: body" \
        "that writes run=; extracted $(wc -c <"${PREFLIGHT}") byte(s)" \
        "the id or job name probably changed — update this test to match"
    finish
    exit 1
fi
_pass "the preflight decision script was extracted from ai-fix.yml"

TEST_REPO="Danathar/aurora-zfs-simple"
TEST_ISSUE="42"
BOT_SENDER="danathar-atomic-hive[bot]"
HUMAN_SENDER="a-maintainer"

# preflight <event> <sender type> <API_KEY> <OAUTH_TOKEN> <ISSUE_IS_PR> <gh head repo>
#
# Runs the extracted script with the step's `env:` block supplied, and a stub
# `gh` first on PATH that records its arguments and prints the head repository
# the real `gh api ... --jq '.head.repo.full_name // ""'` would print. The empty
# string is a real answer there, not a stub artifact: that is what the `// ""`
# yields when the head repository is gone or unreadable.
#
# Sets PF_RUN, PF_SUMMARY, PF_GH, PF_STDERR and PF_STATUS.
preflight() {
    local event=$1 sender_type=$2 api_key=$3 oauth=$4 issue_is_pr=$5 head_repo=$6
    local dir sender summary_file output_file calls_file

    dir="$(mktemp -d "${TMP_ROOT}/case.XXXXXX")"
    calls_file="${dir}/gh-calls"
    summary_file="${dir}/summary"
    output_file="${dir}/output"
    : >"${calls_file}"
    : >"${summary_file}"
    : >"${output_file}"

    sender="${HUMAN_SENDER}"
    if [[ "${sender_type}" == "Bot" ]]; then
        sender="${BOT_SENDER}"
    fi

    mkdir -p "${dir}/bin"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "%%s\\n" "$*" >> %q\n' "${calls_file}"
        printf 'printf "%%s\\n" %q\n' "${head_repo}"
    } >"${dir}/bin/gh"
    chmod +x "${dir}/bin/gh"

    PF_STDERR="$(
        PATH="${dir}/bin:${PATH}" \
            GH_TOKEN="not-a-real-token" \
            REPO="${TEST_REPO}" \
            EVENT="${event}" \
            SENDER_TYPE="${sender_type}" \
            SENDER="${sender}" \
            API_KEY="${api_key}" \
            OAUTH_TOKEN="${oauth}" \
            ISSUE_NUMBER="${TEST_ISSUE}" \
            ISSUE_IS_PR="${issue_is_pr}" \
            GITHUB_STEP_SUMMARY="${summary_file}" \
            GITHUB_OUTPUT="${output_file}" \
            bash "${PREFLIGHT}" 2>&1 >/dev/null
    )"
    PF_STATUS=$?

    PF_SUMMARY="$(cat "${summary_file}")"
    PF_GH="$(cat "${calls_file}")"
    PF_RUN="$(sed -n 's/^run=//p' "${output_file}")"
}

# --- A1. the hand-off path --------------------------------------------------

preflight issues User "sk-ant-fixture" "" "false" ""
assert_eq "a labelled issue from a human with an API key hands off" "yes" "${PF_RUN}"
assert_contains "the hand-off summary says the agent does not merge" \
    "${PF_SUMMARY}" "It opens a pull request; it does not merge one."
assert_eq "the issues path never calls the GitHub API" "" "${PF_GH}"
assert_eq "the preflight step exits 0 on the hand-off path" "0" "${PF_STATUS}"
assert_eq "the preflight step writes nothing to stderr on the hand-off path" "" "${PF_STDERR}"

# The credentials test is an OR over two secrets. With only the first arm
# covered, deleting `|| [ -n "${OAUTH_TOKEN}" ]` still passes, and a repository
# configured the OAuth way silently reports itself unconfigured.
preflight issues User "" "oauth-fixture" "false" ""
assert_eq "an OAuth token alone also counts as configured" "yes" "${PF_RUN}"

# --- A2. no credentials -----------------------------------------------------

preflight issues User "" "" "false" ""
assert_eq "an unconfigured repository does not hand off" "no" "${PF_RUN}"
assert_contains "the skip names the secrets that would enable it" \
    "${PF_SUMMARY}" "Set \`ANTHROPIC_API_KEY\` or \`CLAUDE_CODE_OAUTH_TOKEN\`"
# "inert, not broken": a red workflow nobody can act on trains people to ignore
# red workflows, so the skip must succeed.
assert_eq "an unconfigured repository succeeds rather than failing" "0" "${PF_STATUS}"

# --- A3. a bot sender -------------------------------------------------------

preflight issues Bot "sk-ant-fixture" "" "false" ""
assert_eq "a bot-triggered run does not hand off" "no" "${PF_RUN}"
assert_contains "the skip names the bot that triggered it" "${PF_SUMMARY}" "${BOT_SENDER}"
assert_eq "a bot-triggered run succeeds rather than failing" "0" "${PF_STATUS}"

# Order matters, and only this case can see it. The bot branch is first, so an
# ACMM label event on a repository with no credentials reports the reason that
# will still apply after the secrets are set — rather than an explanation that
# would send a maintainer to configure the repository and start the agent on
# every hive-labelled issue.
preflight issues Bot "" "" "false" ""
assert_eq "a bot sender is refused before the credentials check" "no" "${PF_RUN}"
assert_contains "an unconfigured bot event is reported as a bot event" \
    "${PF_SUMMARY}" "which is a bot"
assert_not_contains "an unconfigured bot event does not blame the missing secrets" \
    "${PF_SUMMARY}" "no agent credentials are configured"

# --- A4. issue comments -----------------------------------------------------

# A comment on a plain issue must not consult the pull-requests API, and must
# hand off. Reaching the API here is the error that matters: the stub's answer
# for a non-pull-request is the empty string, which the fork branch treats as
# "not this repository", so an ordinary issue comment would be refused as a
# fork. See the header on the `set -e` claim in the script's own comment.
preflight issue_comment User "sk-ant-fixture" "" "false" ""
assert_eq "an @claude comment on a plain issue hands off" "yes" "${PF_RUN}"
assert_eq "a comment on a plain issue never calls the GitHub API" "" "${PF_GH}"
assert_eq "a comment on a plain issue does not end the step" "0" "${PF_STATUS}"

preflight issue_comment User "sk-ant-fixture" "" "true" "${TEST_REPO}"
assert_eq "an @claude comment on a same-repo pull request hands off" "yes" "${PF_RUN}"
assert_contains "the head repository is read for the commented-on pull request" \
    "${PF_GH}" "repos/${TEST_REPO}/pulls/${TEST_ISSUE}"

# --- A5. fork pull requests -------------------------------------------------

preflight issue_comment User "sk-ant-fixture" "" "true" "someone-else/aurora-zfs-simple"
assert_eq "an @claude comment on a fork pull request does not hand off" "no" "${PF_RUN}"
assert_contains "the fork skip names the pull request" \
    "${PF_SUMMARY}" "pull request #${TEST_ISSUE} comes from a fork"
assert_eq "a fork pull request succeeds rather than failing" "0" "${PF_STATUS}"

# `--jq '.head.repo.full_name // ""'` yields the empty string when the head
# repository has been deleted or is not readable with this token. Unknown must
# fall on the refusing side of the comparison, not the permissive one.
preflight issue_comment User "sk-ant-fixture" "" "true" ""
assert_eq "an unreadable head repository is treated as a fork" "no" "${PF_RUN}"

# =============================================================================
# B. the invariants the header argues for
# =============================================================================

# --- B1. triggers -----------------------------------------------------------

assert_eq "ai-fix.yml triggers on exactly issues and issue_comment" \
    "issue_comment,issues" "$(wf '.on | keys | sort | join(",")')"

# Named individually because the reason differs per event and the failure text
# is where it gets explained. Each of these runs the *head branch's* copy of the
# workflow file, so a pull request could add its own trigger and reach the `fix`
# job's contents: write in the same pull request — which is what the header
# describes finding, and why the triggers went rather than the permissions.
for event in pull_request pull_request_target pull_request_review pull_request_review_comment; do
    if [[ "$(wf ".on.\"${event}\"")" == "null" ]]; then
        _pass "ai-fix.yml does not trigger on ${event}"
    else
        _fail "ai-fix.yml does not trigger on ${event}" \
            "this event runs the head branch's copy of the workflow, so a pull" \
            "request can edit its own trigger and reach a job holding contents: write;" \
            "see the header of ai-fix.yml and docs/SECURITY-AI.md"
    fi
done

assert_eq "the issues trigger fires only on labeled" \
    "labeled" "$(wf '.on.issues.types | join(",")')"
assert_eq "the issue_comment trigger fires only on created" \
    "created" "$(wf '.on.issue_comment.types | join(",")')"

preflight_if="$(wf '.jobs.preflight.if')"
assert_contains "the cheap event filter still gates on the ai-fix-requested label" \
    "${preflight_if}" "ai-fix-requested"
assert_contains "the cheap event filter still gates on the @claude phrase" \
    "${preflight_if}" "@claude"

# --- B2. the gate between the two jobs --------------------------------------

assert_eq "preflight exports the check step's decision" \
    "\${{ steps.check.outputs.run }}" "$(wf '.jobs.preflight.outputs.run')"
assert_eq "the fix job waits for preflight" "preflight" "$(wf '.jobs.fix.needs')"
# Compared, not searched for: `always() || needs.preflight.outputs.run == 'yes'`
# contains the fragment and runs the agent on every event preflight refused.
assert_eq "the fix job runs only on preflight's yes" \
    "needs.preflight.outputs.run == 'yes'" "$(wf '.jobs.fix.if')"

# --- B3. permissions --------------------------------------------------------

perms() {
    wf ".jobs.${1}.permissions | to_entries | sort_by(.key) | map(\"\(.key)=\(.value)\") | join(\" \")"
}

# Read-only, and it stays read-only: preflight is the job an outside event
# reaches first, and it runs before anything has decided the sender is allowed.
assert_eq "the preflight job holds no write scope" \
    "contents=read pull-requests=read" "$(perms preflight)"

# Enumerated rather than spot-checked. A grant added here is invisible to any
# assertion that only names the ones already present, and widening a
# permissions: block is on the list of things the workflow's own prompt tells an
# agent to stop and ask about.
assert_eq "the fix job holds exactly the five scopes it documents" \
    "actions=read contents=write id-token=write issues=write pull-requests=write" \
    "$(perms fix)"

# Called out separately because it is the specific pair that bounds the
# contents: write grant — nothing here can push an image or sign one.
assert_eq "the fix job cannot push a package" "null" "$(wf '.jobs.fix.permissions.packages')"
assert_eq "the workflow can reach exactly the two agent secrets" \
    "secrets.ANTHROPIC_API_KEY,secrets.CLAUDE_CODE_OAUTH_TOKEN" \
    "$(grep -oE 'secrets\.[A-Za-z_][A-Za-z0-9_]*' "${WF_JSON}" | sort -u | paste -sd, -)"

# --- B4. the action's own inputs --------------------------------------------

action_input() {
    wf ".jobs.fix.steps[] | select(.uses | startswith(\"anthropics/claude-code-action\")) | .with.${1} | tostring"
}

# '' and an absent key are different things and only one of them is safe, which
# is why these are read from parsed YAML rather than grepped. Absent means the
# action's default applies, and a default is not a decision this file made.
assert_eq "no bot may start the agent" "" "$(action_input allowed_bots)"
assert_eq "no non-write user may start the agent" "" "$(action_input allowed_non_write_users)"
assert_eq "the agent branches from main" "main" "$(action_input base_branch)"
assert_eq "the agent pushes only ai-fix/* branches" "ai-fix/" "$(action_input branch_prefix)"
assert_eq "the label trigger matches the job-level filter" \
    "ai-fix-requested" "$(action_input label_trigger)"
assert_eq "the comment trigger matches the job-level filter" \
    "@claude" "$(action_input trigger_phrase)"

# --- B5. pinning ------------------------------------------------------------
#
# This job runs third-party code with contents: write. A moving tag is a
# supply-chain input that can change under the grant without any commit here.

uses_count=0
while IFS= read -r uses; do
    [[ -z "${uses}" ]] && continue
    uses_count=$((uses_count + 1))
    if [[ "${uses}" =~ @[0-9a-f]{40}$ ]]; then
        _pass "ai-fix.yml pins ${uses%%@*} to a commit SHA"
    else
        _fail "ai-fix.yml pins ${uses%%@*} to a commit SHA" \
            "found: ${uses}" \
            "a tag or branch can be repointed at other code without a commit here," \
            "and this step runs with contents: write"
    fi
done < <(wf '.jobs | to_entries[] | (.value.steps // [])[] | .uses // empty')

if [[ "${uses_count}" -gt 0 ]]; then
    _pass "ai-fix.yml declares at least one action to check"
else
    _fail "ai-fix.yml declares at least one action to check" \
        "no uses: values were extracted; the pinning check above asserted nothing"
fi

# --- B6. concurrency --------------------------------------------------------

assert_eq "one agent at a time per issue or pull request" \
    "ai-fix-\${{ github.event.issue.number }}" "$(wf '.concurrency.group')"
# A run that is already pushing commits should finish rather than leave a
# half-written branch behind.
assert_eq "an in-flight agent run is not cancelled" \
    "false" "$(wf '.concurrency["cancel-in-progress"]')"

# --- B7. the ruleset that keeps the grant off main --------------------------
#
# contents: write is bounded by the publish gate in build.yml only while this
# job has to go through a pull request. Nothing in the workflow makes it: main
# had no branch protection and no ruleset (issue #242), so the token could push
# to main directly and the next scheduled build would sign the result. The
# ruleset is repository configuration a pull request cannot apply, so what is
# checked here is the committed definition an admin applies from, and
# docs/branch-protection.md says how to check the live one.

RULESET="${REPO_ROOT}/.github/rulesets/main.json"

rs() {
    jq -r "$1" <"${RULESET}"
}

if jq -e . <"${RULESET}" >/dev/null 2>&1; then
    _pass "the main ruleset is committed and parses as JSON"

    assert_eq "the ruleset is enforced, not evaluated" "active" "$(rs '.enforcement')"
    assert_eq "the ruleset targets the default branch" \
        "~DEFAULT_BRANCH" "$(rs '.conditions.ref_name.include | join(",")')"
    # A bypass for Actions or an App gives back the direct push this exists to
    # stop, and it is the obvious fix to reach for when a workflow's push fails.
    assert_eq "nothing may bypass the ruleset" "0" "$(rs '.bypass_actors | length')"
    assert_eq "the ruleset carries the four rules docs/branch-protection.md explains" \
        "deletion,non_fast_forward,pull_request,required_status_checks" \
        "$(rs '[.rules[].type] | sort | join(",")')"
    # One approval on a single-maintainer repository means nothing can merge.
    assert_eq "a pull request needs no approval a sole maintainer cannot give" \
        "0" "$(rs '.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count')"

    # A required check that some pull requests never get leaves them waiting
    # forever. Every required context must be a job name in both build.yml and
    # coverage-gate.yml, whose path filters between them cover every change.
    required=$(rs '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context')
    if [[ -n "${required}" ]]; then
        _pass "the ruleset requires at least one check"
    else
        _fail "the ruleset requires at least one check" \
            "no required_status_checks context was extracted; the loop below asserts nothing"
    fi
    for gate in build coverage-gate; do
        gate_json="${TMP_ROOT}/${gate}.json"
        if ! "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${REPO_ROOT}/.github/workflows/${gate}.yml" \
            >"${gate_json}" 2>"${TMP_ROOT}/${gate}.err"; then
            _fail "${gate}.yml parses as YAML" "$(cat "${TMP_ROOT}/${gate}.err")"
            continue
        fi
        assert_eq "${gate}.yml runs on pull requests to main" \
            "main" "$(jq -r '.on.pull_request.branches | join(",")' <"${gate_json}")"
        names=$(jq -r '.jobs[].name // empty' <"${gate_json}")
        while IFS= read -r context; do
            [[ -z "${context}" ]] && continue
            if grep -qxF -- "${context}" <<<"${names}"; then
                _pass "required check '${context}' is a job in ${gate}.yml"
            else
                _fail "required check '${context}' is a job in ${gate}.yml" \
                    "jobs found: ${names//$'\n'/, }" \
                    "a pull request that only runs ${gate}.yml would never get this check"
            fi
        done <<<"${required}"
    done
else
    _fail "the main ruleset is committed and parses as JSON" \
        "missing or not JSON: ${RULESET}" \
        "see docs/branch-protection.md and issue #242"
fi

finish
