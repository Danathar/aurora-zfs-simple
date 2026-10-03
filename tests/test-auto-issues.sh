#!/usr/bin/env bash
#
# Covers .github/workflows/auto-issues.yml: the one `run:` body that decides
# whether a failed unattended workflow becomes an issue, a comment on an issue,
# or nothing, and the shape of the workflow that bounds the token it holds.
#
# The step is shell inside a YAML string, so run-tests.sh does not find it,
# test-shell-syntax.sh does not `bash -n` it and shellcheck never sees it. This
# extracts it with PyYAML (as test-auto-qa-run.sh does, and for the same reason:
# re-deriving a block scalar's indentation with sed is a second implementation
# that can disagree with the one Actions uses) and runs it as a real subprocess
# against a recording `gh` stub. The `jq` in the body is the real one, so the
# filter that decides "is there already an open issue" is load-bearing.
#
# What each half guards:
#
#   1. The decision. A first failure opens one issue; a failure while that issue
#      is open comments on it; and a green, cancelled, pull-request, dispatched,
#      non-default-branch or fork run does nothing at all, not even a read. If
#      the dedupe broke, a red nightly run would open a new issue every day. If
#      the guards broke, every pull request's red build would.
#
#   2. No label, ever. `gh issue create --label` is how this would start handing
#      an issue the authority an external system reads from labels
#      (docs/SECURITY-AI.md, "Labels carry authority"), so every call the stub
#      ever sees is checked for a label flag, and the issue text for the
#      `ai-fix-requested` trigger and for any @-mention.
#
#   3. What it watches. The list of workflows is joined to the tree, not to a
#      copy: every name must be a real workflow's `name:`, and every workflow
#      with a `schedule:` trigger must be either watched or listed here as
#      deliberately unwatched with a reason. A new scheduled workflow therefore
#      fails this test until someone decides, instead of going unwatched.
#
#   4. The token. `issues: write` and `actions: read` and nothing else, no
#      checkout, and no Actions expression inside a `run:` body.

set -uo pipefail

TEST_NAME="test-auto-issues"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

WORKFLOWS_DIR="${REPO_ROOT}/.github/workflows"
AUTO_ISSUES_WF="${WORKFLOWS_DIR}/auto-issues.yml"
WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

# Scheduled workflows this one deliberately does not watch, and why. Anything
# scheduled and in neither this list nor the workflow's own list fails below.
UNWATCHED=(
    "status-badges.yml"  # republishes two JSON files; a failure is a stale badge and nothing else
    "auto-qa.yml"        # goes red on purpose to report a timeout; the finding is in its run summary
)

if [[ ! -f "${AUTO_ISSUES_WF}" ]]; then
    _fail "auto-issues.yml exists" \
        "no such file: ${AUTO_ISSUES_WF}" \
        "if the workflow was removed on purpose, delete this test with it"
    finish
    exit 1
fi

if ! "${WORKFLOW_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    _fail "the auto-issues.yml check requires Python 3 with PyYAML" \
        "install python3-yaml (Debian/Ubuntu) or python3-pyyaml (Fedora)," \
        "or install PyYAML in the interpreter selected by WORKFLOW_PYTHON"
    finish
    exit 1
fi

# --- normalizer -------------------------------------------------------------

NORMALIZER="${TMP_ROOT}/normalize.py"
cat >"${NORMALIZER}" <<'PY'
"""Print one workflow file as JSON, with the `on:` key readable by name.

YAML 1.1 reads a bare `on` as the boolean true, so `doc["on"]` raises KeyError
on every workflow ever written. Renaming it here keeps that quirk in one place.
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

WF_JSON="${TMP_ROOT}/auto-issues.json"
if ! "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${AUTO_ISSUES_WF}" >"${WF_JSON}" 2>"${TMP_ROOT}/wf.err"; then
    _fail "auto-issues.yml parses as YAML" "$(cat "${TMP_ROOT}/wf.err")"
    finish
    exit 1
fi
_pass "auto-issues.yml parses as YAML"

wf() {
    jq -r "$1" <"${WF_JSON}"
}

# --- the trigger, joined to the tree ----------------------------------------

assert_eq "it runs on workflow_run completion and on no other event" \
    "workflow_run" "$(wf '.on | keys | join(",")')"
assert_eq "and only once the watched run has completed" \
    "completed" "$(wf '.on.workflow_run.types | join(",")')"

# name, file and whether it has a schedule, for every workflow in the tree.
TREE="${TMP_ROOT}/tree.jsonl"
: >"${TREE}"
for file in "${WORKFLOWS_DIR}"/*.yml; do
    "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${file}" |
        jq -c --arg file "$(basename "${file}")" \
            '{file: $file, name: .name, scheduled: (.on | has("schedule"))}' >>"${TREE}"
done

WATCHED="$(wf '.on.workflow_run.workflows[]')"

missing=""
while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    if ! jq -e --arg n "${name}" 'select(.name == $n)' <"${TREE}" >/dev/null; then
        missing+="${name}; "
    fi
done <<<"${WATCHED}"
assert_eq "every watched name is the name: of a workflow in the tree" "" "${missing}"

assert_eq "a workflow does not watch itself" \
    "" "$(grep -Fx "$(wf '.name')" <<<"${WATCHED}")"

undecided=""
while IFS= read -r file; do
    name="$(jq -r --arg f "${file}" 'select(.file == $f) | .name' <"${TREE}")"
    if grep -Fxq -- "${name}" <<<"${WATCHED}"; then
        continue
    fi
    listed=0
    for entry in "${UNWATCHED[@]}"; do
        [[ "${entry}" == "${file}" ]] && listed=1
    done
    [[ "${listed}" -eq 1 ]] || undecided+="${file}; "
done < <(jq -r 'select(.scheduled) | .file' <"${TREE}")
assert_eq "every scheduled workflow is watched or listed as deliberately unwatched" \
    "" "${undecided}"

stale=""
for entry in "${UNWATCHED[@]}"; do
    if ! jq -e --arg f "${entry}" 'select(.file == $f and .scheduled)' <"${TREE}" >/dev/null; then
        stale+="${entry}; "
    fi
    name="$(jq -r --arg f "${entry}" 'select(.file == $f) | .name' <"${TREE}")"
    if [[ -n "${name}" ]] && grep -Fxq -- "${name}" <<<"${WATCHED}"; then
        stale+="${entry} (also watched); "
    fi
done
assert_eq "the unwatched list names only scheduled workflows that are not watched" "" "${stale}"

# --- the token --------------------------------------------------------------

assert_eq "the job's token holds issues: write and actions: read and nothing else" \
    '{"actions":"read","issues":"write"}' "$(wf '.jobs.report.permissions | to_entries | sort_by(.key) | from_entries | tojson')"
assert_eq "there is exactly one job" "report" "$(wf '.jobs | keys | join(",")')"
assert_eq "the workflow has no top-level permissions block to widen the job's" \
    "null" "$(wf '.permissions')"
assert_eq "no step checks out the repository or runs an action" \
    "0" "$(wf '[.jobs.report.steps[] | select(has("uses"))] | length')"
assert_eq "the job is bounded by a timeout" \
    "5" "$(wf '.jobs.report["timeout-minutes"]')"

STEP_NAME="Open or update the issue for this failure"
STEP="${TMP_ROOT}/report.sh"
wf ".jobs.report.steps[] | select(.name == \"${STEP_NAME}\") | .run // \"\"" >"${STEP}"
if [[ ! -s "${STEP}" ]] || ! grep -q -- 'gh issue create' "${STEP}"; then
    _fail "the '${STEP_NAME}' script was extracted from auto-issues.yml" \
        "expected a run: body that calls gh issue create; extracted" \
        "$(wc -c <"${STEP}") byte(s) from the report job" \
        "the step name probably changed — update this test to match"
    finish
    exit 1
fi
_pass "the '${STEP_NAME}' script was extracted from auto-issues.yml"

# shellcheck disable=SC2016 # looking for the literal characters of an expression
assert_eq "the step's run: body holds no Actions expression" \
    "0" "$(grep -c '\${{' "${STEP}")"

# Every field the step reads must be wired from the event through env:, so a
# variable the body uses but the workflow never sets cannot pass by luck here.
unwired=""
for var in GH_TOKEN REPO SERVER_URL DEFAULT_BRANCH WORKFLOW_NAME CONCLUSION RUN_EVENT \
    HEAD_BRANCH HEAD_REPO HEAD_SHA RUN_ID RUN_ATTEMPT RUN_URL; do
    if ! jq -e --arg v "${var}" --arg s "${STEP_NAME}" \
        '.jobs.report.steps[] | select(.name == $s) | .env | has($v)' <"${WF_JSON}" >/dev/null; then
        unwired+="${var}; "
    fi
done
assert_eq "every variable the step reads is set from the event in env:" "" "${unwired}"

# shellcheck disable=SC2016 # Actions expressions, compared as literal text
assert_eq "the token is the job's own github.token" \
    '${{ github.token }}' \
    "$(wf ".jobs.report.steps[] | select(.name == \"${STEP_NAME}\") | .env.GH_TOKEN")"

if bash -n "${STEP}" 2>"${TMP_ROOT}/syntax.err"; then
    _pass "the step is valid bash"
else
    _fail "the step is valid bash" "$(cat "${TMP_ROOT}/syntax.err")"
fi

# --- the stub ---------------------------------------------------------------

# make_gh <case dir> — a recording `gh`. It serves the jobs lookup and the
# open-issue listing from files in the case directory and records everything
# else. It refuses a listing that does not ask for open issues, so a body that
# stopped restricting to open would fail instead of matching a closed issue.
make_gh() {
    local dir=$1
    mkdir -p "${dir}/bin"
    : >"${dir}/gh-calls"
    echo '[]' >"${dir}/issues.json"
    echo '{"jobs":[]}' >"${dir}/jobs.json"

    cat >"${dir}/bin/gh" <<STUB
#!/usr/bin/env bash
dir=${dir@Q}
printf '%s\n' "\$*" >>"\${dir}/gh-calls"

case "\$1 \$2" in
    "api repos/"*)
        if [ -e "\${dir}/jobs-fail" ]; then
            exit 1
        fi
        filter=""
        args=("\$@")
        for i in "\${!args[@]}"; do
            if [ "\${args[\$i]}" = "--jq" ]; then
                filter=\${args[\$((i + 1))]}
            fi
        done
        printf '%s\n' "\$2" >"\${dir}/api-url"
        if [ -n "\${filter}" ]; then
            jq -r "\${filter}" <"\${dir}/jobs.json"
        else
            cat "\${dir}/jobs.json"
        fi
        ;;
    "issue list")
        case " \$* " in
            *" --state open "*) cat "\${dir}/issues.json" ;;
            *) printf 'gh stub: issue list without --state open\n' >&2; exit 1 ;;
        esac
        ;;
    "issue create")
        cat >"\${dir}/create-body"
        printf 'https://github.com/example/repo/issues/999\n'
        ;;
    "issue comment")
        cat >"\${dir}/comment-body"
        ;;
    *)
        printf 'gh stub: unexpected call: %s\n' "\$*" >&2
        exit 1
        ;;
esac
STUB
    chmod +x "${dir}/bin/gh"
}

# run_step <case dir> [VAR=value]... — the step with a failed scheduled build on
# the default branch of this repository, any variable overridden by argument.
run_step() {
    local dir=$1
    shift
    env -i PATH="${dir}/bin:${PATH}" HOME="${TMP_ROOT}" \
        GH_TOKEN="stub-token" \
        REPO="Danathar/aurora-zfs-simple" \
        SERVER_URL="https://github.com" \
        DEFAULT_BRANCH="main" \
        WORKFLOW_NAME="Build container image" \
        CONCLUSION="failure" \
        RUN_EVENT="schedule" \
        HEAD_BRANCH="main" \
        HEAD_REPO="Danathar/aurora-zfs-simple" \
        HEAD_SHA="0123456789abcdef0123456789abcdef01234567" \
        RUN_ID="4242" \
        RUN_ATTEMPT="1" \
        RUN_URL="https://github.com/Danathar/aurora-zfs-simple/actions/runs/4242" \
        "$@" \
        bash "${STEP}" >"${dir}/out" 2>"${dir}/err"
    echo $? >"${dir}/status"
}

CASES=0
new_case() {
    CASES=$((CASES + 1))
    local dir="${TMP_ROOT}/case-${CASES}-$1"
    make_gh "${dir}"
    printf '%s' "${dir}"
}

calls() {
    grep -c -- "^$2" "$1/gh-calls"
}

# --- first failure opens an issue -------------------------------------------

dir="$(new_case first-failure)"
jq -n '{jobs: [
    {name: "Shell tests", conclusion: "success"},
    {name: "Build and push image", conclusion: "failure"},
    {name: "Cancelled sibling", conclusion: "cancelled"}
]}' >"${dir}/jobs.json"
run_step "${dir}"
assert_eq "a first failure exits cleanly" "0" "$(cat "${dir}/status")"
assert_eq "it opens exactly one issue" "1" "$(calls "${dir}" 'issue create')"
assert_eq "and comments on nothing" "0" "$(calls "${dir}" 'issue comment')"
assert_contains "the title is the exact per-workflow title" \
    "$(grep '^issue create' "${dir}/gh-calls")" "--title Unattended run failed: Build container image"
assert_contains "it names this repository explicitly" \
    "$(grep '^issue create' "${dir}/gh-calls")" "--repo Danathar/aurora-zfs-simple"
assert_contains "it reads the jobs of this run and attempt" \
    "$(cat "${dir}/api-url")" "repos/Danathar/aurora-zfs-simple/actions/runs/4242/attempts/1/jobs"
body="$(cat "${dir}/create-body")"
assert_contains "the body carries the hidden dedupe marker" \
    "${body}" "<!-- auto-issues:workflow=Build container image -->"
assert_contains "the body links the run" \
    "${body}" "https://github.com/Danathar/aurora-zfs-simple/actions/runs/4242"
assert_contains "the body names the commit" \
    "${body}" "0123456789abcdef0123456789abcdef01234567"
assert_contains "the body lists the job that failed" \
    "${body}" "- Build and push image"
assert_not_contains "and not a job that succeeded" "${body}" "- Shell tests"
assert_not_contains "and not a job that was merely cancelled" "${body}" "- Cancelled sibling"
assert_contains "for the build, the first step is AGENTS.md's akmod skew section" \
    "${body}" "/blob/main/AGENTS.md#dominant-failure-mode-kernel--zfs-akmod-skew"
assert_contains "and it says pinning needs a maintainer decision" \
    "${body}" "needs a maintainer decision"
assert_contains "the pointer to CONTRIBUTING.md is a link" \
    "${body}" "/blob/main/CONTRIBUTING.md"

# The section the body links to must exist, under the heading the anchor spells.
assert_eq "AGENTS.md has the section the build issue links to" \
    "1" "$(grep -c '^## Dominant failure mode: kernel / ZFS akmod skew$' "${REPO_ROOT}/AGENTS.md")"

# --- timed_out is a failure too ---------------------------------------------

dir="$(new_case timed-out)"
run_step "${dir}" CONCLUSION=timed_out
assert_eq "a timed-out run opens an issue" "1" "$(calls "${dir}" 'issue create')"

# --- a push to the default branch counts ------------------------------------

dir="$(new_case push)"
run_step "${dir}" RUN_EVENT=push
assert_eq "a failed push-triggered run opens an issue" "1" "$(calls "${dir}" 'issue create')"

# --- the second failure comments --------------------------------------------

dir="$(new_case second-failure)"
jq -n '[
    {number: 31, title: "Unattended run failed: Nightly compliance",
     body: "<!-- auto-issues:workflow=Nightly compliance -->\nother workflow"},
    {number: 52, title: "Unattended run failed: Build container image",
     body: "<!-- auto-issues:workflow=Build container image -->\nfirst failure"}
]' >"${dir}/issues.json"
run_step "${dir}"
assert_eq "a failure while its issue is open exits cleanly" "0" "$(cat "${dir}/status")"
assert_eq "it opens no second issue" "0" "$(calls "${dir}" 'issue create')"
assert_eq "it comments once" "1" "$(calls "${dir}" 'issue comment')"
assert_contains "on the issue for this workflow, not the other one" \
    "$(grep '^issue comment' "${dir}/gh-calls")" "issue comment 52 "
assert_contains "the comment carries the run link" \
    "$(cat "${dir}/comment-body")" "https://github.com/Danathar/aurora-zfs-simple/actions/runs/4242"
assert_contains "and the commit" \
    "$(cat "${dir}/comment-body")" "0123456789abcdef0123456789abcdef01234567"

# An issue whose title a person edited is still found by its marker.
dir="$(new_case renamed-issue)"
jq -n '[{number: 77, title: "build is red again",
         body: "<!-- auto-issues:workflow=Build container image -->\nx"}]' >"${dir}/issues.json"
run_step "${dir}"
assert_contains "an issue retitled by a person is still found by its marker" \
    "$(grep '^issue comment' "${dir}/gh-calls")" "issue comment 77 "
assert_eq "and no second issue is opened" "0" "$(calls "${dir}" 'issue create')"

# Only another workflow's issue is open: this one still needs its own.
dir="$(new_case other-workflow-open)"
jq -n '[{number: 31, title: "Unattended run failed: Nightly compliance",
         body: "<!-- auto-issues:workflow=Nightly compliance -->"}]' >"${dir}/issues.json"
run_step "${dir}"
assert_eq "another workflow's open issue does not stand in for this one" \
    "1" "$(calls "${dir}" 'issue create')"

# --- the nightly workflow gets its own first step ---------------------------

dir="$(new_case nightly)"
run_step "${dir}" WORKFLOW_NAME="Nightly compliance"
body="$(cat "${dir}/create-body")"
assert_contains "a nightly failure gets its own title" \
    "$(grep '^issue create' "${dir}/gh-calls")" "--title Unattended run failed: Nightly compliance"
assert_contains "and its own marker" \
    "${body}" "<!-- auto-issues:workflow=Nightly compliance -->"
assert_contains "and points at that workflow's header" \
    "${body}" "/blob/main/.github/workflows/nightly-compliance.yml"
assert_not_contains "and not at the akmod skew section" "${body}" "akmod-skew"

# --- the jobs lookup failing does not lose the report -----------------------

dir="$(new_case jobs-lookup-fails)"
touch "${dir}/jobs-fail"
run_step "${dir}"
assert_eq "a failed jobs lookup still opens the issue" "1" "$(calls "${dir}" 'issue create')"
assert_contains "and says the list could not be read" \
    "$(cat "${dir}/create-body")" "could not be read"

# --- everything else does nothing, not even a read ---------------------------

expect_nothing() {
    local description=$1
    shift
    local dir
    dir="$(new_case "nothing-$1")"
    run_step "${dir}" "$@"
    assert_eq "${description}: exits cleanly" "0" "$(cat "${dir}/status")"
    assert_eq "${description}: makes no gh call at all" "0" "$(wc -l <"${dir}/gh-calls")"
}

expect_nothing "a successful run" CONCLUSION=success
expect_nothing "a cancelled run" CONCLUSION=cancelled
expect_nothing "a skipped run" CONCLUSION=skipped
expect_nothing "a pull request run" RUN_EVENT=pull_request
expect_nothing "a manually dispatched run" RUN_EVENT=workflow_dispatch
expect_nothing "a run on a pull request's branch" HEAD_BRANCH=feature/x
expect_nothing "a run from a fork" HEAD_REPO=someone/aurora-zfs-simple

# --- no label, no mention, no close -----------------------------------------

all_calls="$(cat "${TMP_ROOT}"/case-*/gh-calls)"
all_text="$(cat "${TMP_ROOT}"/case-*/create-body "${TMP_ROOT}"/case-*/comment-body 2>/dev/null)"

label_flags="$(grep -E -- '(^| )(--label|-l|--add-label|--remove-label)( |$)' <<<"${all_calls}" || true)"
assert_eq "no gh call in any case passes a label flag" "" "${label_flags}"
assert_not_contains "no issue text mentions the ai-fix-requested trigger" \
    "${all_text}" "ai-fix-requested"
assert_eq "no issue text contains an @-mention" "" \
    "$(grep -E '(^|[^A-Za-z0-9._-])@[A-Za-z]' <<<"${all_text}" || true)"
assert_eq "no case closes, edits or reopens an issue" "" \
    "$(grep -E '^issue (close|edit|reopen|delete|lock)' <<<"${all_calls}" || true)"
assert_eq "the step's body never writes a label or a close, nor names the agent trigger" "" \
    "$(grep -E -- '--label|--add-label|issue close|issue edit|ai-fix-requested' "${STEP}" || true)"

finish
