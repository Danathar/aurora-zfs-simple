#!/usr/bin/env bash
#
# Every workflow's token permissions, against .github/policies/workflow-permissions.json.
#
# A workflow's `permissions:` block decides what its GITHUB_TOKEN can do: push a
# branch, open a pull request, publish to the registry. Until this file, the only
# record of what each workflow is *supposed* to hold was the workflow itself, so
# widening a token was one line inside a file a reviewer may skim for the step
# that changed. docs/SECURITY-AI.md says a new `contents: write` or
# `packages: write` needs a human decision; nothing made that decision visible.
#
# The policy file is the second record, and this test holds the two against each
# other in both directions:
#
#   * every workflow is listed in the policy, and every entry is a real workflow;
#   * each workflow's top-level block is exactly what the policy says, and a
#     workflow the policy marks null declares none;
#   * the jobs that declare their own block are exactly the jobs the policy
#     lists, each with exactly the permissions listed;
#   * no job is left on the repository's default token, which would make "no
#     block, policy says null" agree while granting whatever the default is;
#   * the policy names only scopes and levels GitHub accepts, because Actions
#     ignores a misspelt scope instead of refusing it.
#
# So a workflow that asks for one more scope fails here until the policy is
# edited in the same pull request, and that second edit is the one a reviewer
# cannot miss. docs/risk-tiers.md puts .github/policies/** in Tier 3.
#
# The workflows are read with PyYAML, as test-branch-protection.sh reads them;
# the policy and the comparison are jq. The last section widens a copy of two
# workflows and checks the comparison notices, so a parser that stopped seeing
# the blocks fails here instead of reading both sides as "nothing".

set -uo pipefail

TEST_NAME="test-workflow-permissions"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

POLICY="${REPO_ROOT}/.github/policies/workflow-permissions.json"
WORKFLOWS="${REPO_ROOT}/.github/workflows"
WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

if [[ ! -f "${POLICY}" ]]; then
    _fail "workflow-permissions.json exists" "no such file: ${POLICY}"
    finish
    exit 1
fi

if ! jq -e '.workflows | type == "object"' "${POLICY}" >/dev/null 2>&1; then
    _fail "the policy is JSON with a workflows object" "jq could not read .workflows from ${POLICY}"
    finish
    exit 1
fi
_pass "the policy is JSON with a workflows object"

# Reading the workflows needs a YAML parser; a missing one must fail, not skip,
# or every comparison below passes against nothing.
if ! "${WORKFLOW_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    _fail "the workflow reader requires Python 3 with PyYAML" \
        "install python3-yaml (Debian/Ubuntu) or python3-pyyaml (Fedora)," \
        "or install PyYAML in the interpreter selected by WORKFLOW_PYTHON"
    finish
    exit 1
fi

# --- reader -----------------------------------------------------------------
#
# Prints one JSON object keyed by workflow file name: the top-level
# `permissions` value (null when absent), the job-level values of the jobs that
# declare one, and every job's name.

READER="${TMP_ROOT}/read_permissions.py"
cat >"${READER}" <<'PY'
"""Print each workflow's declared permissions as JSON."""

import json
import os
import sys

import yaml

directory = sys.argv[1]
out = {}
for name in sorted(os.listdir(directory)):
    if not name.endswith((".yml", ".yaml")):
        continue
    with open(os.path.join(directory, name), encoding="utf-8") as handle:
        doc = yaml.safe_load(handle)
    jobs = doc.get("jobs") if isinstance(doc, dict) else None
    if not isinstance(jobs, dict):
        sys.exit(f"{name}: no jobs mapping")
    out[name] = {
        "workflow": doc.get("permissions"),
        "jobs": {job: body["permissions"] for job, body in jobs.items()
                 if isinstance(body, dict) and "permissions" in body},
        "job_names": list(jobs),
    }
print(json.dumps(out))
PY

# Reads the workflows in $1 into $2; the reader's stderr goes to $2.err.
read_workflows() {
    "${WORKFLOW_PYTHON}" -B "${READER}" "$1" >"$2" 2>"$2.err"
}

# Prints one line per disagreement between declared permissions ($1) and the
# policy: `workflow<TAB>where<TAB>declared<TAB>allowed`. Workflows missing from
# the policy are reported by the set comparison instead.
mismatches() {
    jq -r --slurpfile policy "${POLICY}" '
        $policy[0].workflows as $allowed
        | to_entries[]
        | .key as $w | .value as $d
        | select($allowed | has($w))
        | $allowed[$w] as $p
        | (if $d.workflow != $p.workflow
           then [$w, "top-level", ($d.workflow | tojson), ($p.workflow | tojson)]
           else empty end),
          ((($d.jobs | keys) + ($p.jobs | keys)) | unique[] as $j
           | select($d.jobs[$j] != $p.jobs[$j])
           | [$w, "job \($j)", ($d.jobs[$j] | tojson), ($p.jobs[$j] | tojson)])
        | @tsv
    ' "$1"
}

DECLARED="${TMP_ROOT}/declared.json"
if ! read_workflows "${WORKFLOWS}" "${DECLARED}"; then
    _fail "every workflow parses" "$(cat "${DECLARED}.err")"
    finish
    exit 1
fi

# --- every workflow is listed, and every entry is a workflow ----------------

present=$(jq -r 'keys[]' "${DECLARED}" | LC_ALL=C sort)
listed=$(jq -r '.workflows | keys[]' "${POLICY}" | LC_ALL=C sort)
require_nonempty() {
    if [[ -n "$2" ]]; then _pass "$1"; else _fail "$1" "found nothing"; fi
}
require_nonempty "workflow files under .github/workflows" "${present}"

unlisted=$(LC_ALL=C comm -23 <(printf '%s\n' "${present}") <(printf '%s\n' "${listed}"))
stale=$(LC_ALL=C comm -13 <(printf '%s\n' "${present}") <(printf '%s\n' "${listed}"))
assert_eq "every workflow has an entry in the policy" "" "${unlisted}"
assert_eq "every policy entry is a workflow that exists" "" "${stale}"

# --- each workflow declares exactly what the policy allows ------------------

found=$(mismatches "${DECLARED}")
while IFS= read -r workflow; do
    [[ -z "${workflow}" ]] && continue
    grep -qxF "${workflow}" <<<"${listed}" || continue
    lines=$(awk -F '\t' -v w="${workflow}" '$1 == w' <<<"${found}")
    if [[ -z "${lines}" ]]; then
        _pass "${workflow} declares exactly the permissions the policy allows"
        continue
    fi
    details=()
    while IFS=$'\t' read -r _ where declared allowed; do
        details+=("${where}: the workflow declares ${declared}; the policy allows ${allowed}")
    done <<<"${lines}"
    details+=("change the workflow and the policy in the same pull request, or neither")
    _fail "${workflow} declares exactly the permissions the policy allows" "${details[@]}"
done <<<"${present}"

# --- no job runs on the repository's default token --------------------------
#
# A workflow with no top-level block leaves every job without its own block on
# whatever the repository default is. The policy would record that as null and
# agree with it, which is a match that grants something nobody wrote down.

unscoped=$(jq -r '
    to_entries[]
    | select(.value.workflow == null)
    | .key as $w
    | .value.job_names - (.value.jobs | keys)
    | .[] | "\($w): \(.)"
' "${DECLARED}")
assert_eq "every job's token is scoped by a block in its workflow" "" "${unscoped}"

# --- the policy names only real scopes and levels ---------------------------

SCOPES='["actions","attestations","checks","contents","deployments","discussions","id-token","issues","models","packages","pages","pull-requests","repository-projects","security-events","statuses"]'
bad_entries=$(jq -r --argjson scopes "${SCOPES}" '
    .workflows | to_entries[]
    | .key as $w
    | ([["top-level", .value.workflow]] + (.value.jobs | to_entries | map(["job \(.key)", .value])))[]
    | .[0] as $where | .[1] as $block
    | if $block == null then empty
      elif ($block | type) == "string" then
          (if ($block | IN("read-all", "write-all")) then empty
           else "\($w) \($where): \($block | tojson) is not read-all or write-all" end)
      elif ($block | type) == "object" then
          ($block | to_entries[]
           | if (.key | IN($scopes[])) | not then "\($w) \($where): \(.key) is not a GitHub token scope"
             elif (.value | IN("read", "write", "none")) | not then "\($w) \($where): \(.key) has level \(.value | tojson)"
             else empty end)
      else "\($w) \($where): \($block | tojson) is not a permissions block" end
' "${POLICY}")
assert_eq "the policy names only GitHub token scopes and levels" "" "${bad_entries}"

# --- a widened workflow is caught -------------------------------------------
#
# The regression this file exists for, replayed on a copy: one more scope at
# the top level of status-badges.yml and one more in the first job-level block
# of coverage-gate.yml. Each must be reported against its own workflow, and
# nothing else may appear that the unwidened tree did not already report, so a
# real mismatch above is not reported a second time here.

WIDENED="${TMP_ROOT}/widened"
cp -R "${WORKFLOWS}" "${WIDENED}"
sed -i '/^permissions:$/a\  actions: write' "${WIDENED}/status-badges.yml"
sed -i '0,/^    permissions:$/{/^    permissions:$/a\      pull-requests: write
}' "${WIDENED}/coverage-gate.yml"

for workflow in status-badges.yml coverage-gate.yml; do
    if cmp -s "${WORKFLOWS}/${workflow}" "${WIDENED}/${workflow}"; then
        _fail "the self-check widened ${workflow}" "sed matched no permissions block to widen"
    fi
done

if read_workflows "${WIDENED}" "${TMP_ROOT}/widened.json"; then
    caught=$(LC_ALL=C comm -13 <(LC_ALL=C sort <<<"${found}") \
        <(mismatches "${TMP_ROOT}/widened.json" | LC_ALL=C sort) | cut -f1,2)
    assert_eq "a widened workflow is reported, and only that workflow" \
        "$(printf '%s\t%s\n%s\t%s' coverage-gate.yml 'job tests' status-badges.yml top-level)" \
        "${caught}"
else
    _fail "the widened copies parse" "$(cat "${TMP_ROOT}/widened.json.err")"
fi

finish
