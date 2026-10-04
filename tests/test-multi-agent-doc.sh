#!/usr/bin/env bash
#
# docs/multi-agent.md, against the ruleset, workflows and files it describes.
#
# The page says how several agents share this repository: who they are, how an
# issue reaches one, what stops two of them undoing each other, who merges, and
# what the repository deliberately does not run. Almost all of that is a claim
# about machinery the page does not own: the `main` ruleset, `ai-fix.yml`, the
# permissions each workflow's token holds, and README.md's account of the hold
# label. Nothing else reads the page, so a ruleset made strict, an agent
# workflow added, or a renamed trigger label would leave it telling the next
# agent something false while every other test stayed green.
#
# So the claims that can be decided offline are recomputed from the tree:
#
#   * the ruleset values the page states in code spans, against main.json, and
#     that the required check is a real job name in a workflow;
#   * the only workflow that runs an agent, the only workflow whose token could
#     open a pull request, and that nothing dispatches another workflow, so
#     "there is no dispatcher" fails the day one is added;
#   * ai-fix.yml's triggers, trigger label, branch prefix and `allowed_bots`
#     against what the intake section says;
#   * README.md's Maintained with Hive section still saying what the page
#     quotes it for;
#   * every repository path the page names in a code span, and that every `gh`
#     command on it names this repository and none applies a label;
#   * the roster's signature column has one well-formed signature per role.
#
# Commit identities, branch prefixes and merged-by logins come from pull request
# history the checkout does not carry (CI clones with depth 1), so the page
# gives the commands that read them and they are not asserted here.

set -uo pipefail

TEST_NAME="test-multi-agent-doc"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

PAGE="${REPO_ROOT}/docs/multi-agent.md"
RULESET="${REPO_ROOT}/.github/rulesets/main.json"
WORKFLOWS="${REPO_ROOT}/.github/workflows"
README="${REPO_ROOT}/README.md"
WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

missing=0
for required in "${PAGE}" "${RULESET}" "${README}" "${WORKFLOWS}/ai-fix.yml"; do
    if [[ ! -e "${required}" ]]; then
        _fail "$(basename "${required}") exists" "no such path: ${required}"
        missing=1
    fi
done
if [[ "${missing}" -ne 0 ]]; then
    finish
    exit 1
fi

# The workflow facts are read with PyYAML; a missing parser must fail, not skip,
# or "no workflow dispatches another" would assert nothing.
if ! "${WORKFLOW_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    _fail "the multi-agent checker requires Python 3 with PyYAML" \
        "install python3-yaml (Debian/Ubuntu) or python3-pyyaml (Fedora)," \
        "or install PyYAML in the interpreter selected by WORKFLOW_PYTHON"
    finish
    exit 1
fi

# --- checker ----------------------------------------------------------------
#
# Prints one line per assertion: `ok<TAB>description` or
# `FAIL<TAB>description<TAB>detail...`. Python because the page is split into
# sections and a table and the workflows into triggers, jobs and steps, and
# doing either in sed is where a check quietly stops matching.

CHECKER="${TMP_ROOT}/check.py"
cat >"${CHECKER}" <<'PY'
"""Join docs/multi-agent.md to the ruleset, workflows and files it describes."""

import glob
import json
import os
import re
import subprocess
import sys

import yaml

root, page_path, ruleset_path, workflows_dir, readme_path = sys.argv[1:6]
SLUG = "Danathar/aurora-zfs-simple"
out = []


def check(description, ok, *detail):
    if ok:
        out.append(f"ok\t{description}")
    else:
        out.append("\t".join(["FAIL", description, *[str(d) for d in detail]]))


def squash(text):
    return re.sub(r"\s+", " ", text).strip()


def outside_fences(text):
    kept, fenced = [], False
    for line in text.splitlines():
        if re.match(r"^\s*(```|~~~)", line):
            fenced = not fenced
            continue
        if not fenced:
            kept.append(line)
    return "\n".join(kept)


def section(text, heading):
    """The body under `## heading`, up to the next `## `."""
    match = re.search(rf"^## {re.escape(heading)}\n(.*?)(?=^## |\Z)", text, re.M | re.S)
    return match.group(1) if match else ""


page = open(page_path, encoding="utf-8").read()
prose = outside_fences(page)
ruleset = json.load(open(ruleset_path, encoding="utf-8"))
readme = open(readme_path, encoding="utf-8").read()

# The headings the assertions below scope to. Named, not discovered: a renamed
# section must fail here rather than make the assertions under it read "".
ROSTER = "Who works here"
INTAKE = "How work reaches an agent"
OVERLAP = "Staying out of each other's way"
MERGES = "Who merges"
NOT_RUN = "What this repository does not run"
for title in (ROSTER, INTAKE, OVERLAP, MERGES, NOT_RUN):
    check(f"§{title} exists and is not empty", bool(section(page, title).strip()))

# --- workflows, read once ---------------------------------------------------

workflows = {}
for path in sorted(glob.glob(os.path.join(workflows_dir, "*.yml")) + glob.glob(os.path.join(workflows_dir, "*.yaml"))):
    doc = yaml.safe_load(open(path, encoding="utf-8"))
    if isinstance(doc, dict) and True in doc:  # YAML 1.1 reads a bare `on` as true
        doc["on"] = doc.pop(True)
    workflows[os.path.basename(path)] = doc
check("workflows were read", len(workflows) >= 5, f"found {sorted(workflows)}")


def triggers(doc):
    on = doc.get("on", {})
    if isinstance(on, dict):
        return set(on)
    return set(on) if isinstance(on, list) else {on}


def steps(doc):
    for job in doc.get("jobs", {}).values():
        yield from job.get("steps", [])


# --- the ruleset values the page states, against main.json ------------------

rules = {rule["type"]: rule.get("parameters", {}) for rule in ruleset["rules"]}
checks = rules.get("required_status_checks", {})
contexts = [c["context"] for c in checks.get("required_status_checks", [])]

strict = re.findall(r"`strict_required_status_checks_policy` is `(true|false)`", squash(prose))
check("the page states strict_required_status_checks_policy once", len(strict) == 1, f"found {strict}")
if strict:
    actual = checks.get("strict_required_status_checks_policy")
    check("the strictness the page states is the ruleset's",
          (strict[0] == "true") == actual, f"page: {strict[0]}", f"ruleset: {actual}")
    # The page's warning that two green pull requests can be red together is
    # true only while the check is not strict; the section must carry it then.
    check("the page warns about a non-strict check exactly when the ruleset is not strict",
          ("red together" in squash(section(page, OVERLAP))) == (actual is False),
          f"strict: {actual}")

approvals = re.findall(r"`required_approving_review_count` is `(\d+)`", squash(prose))
check("the page states the approval count once", len(approvals) == 1, f"found {approvals}")
if approvals:
    actual = rules.get("pull_request", {}).get("required_approving_review_count")
    check("the approval count the page states is the ruleset's",
          int(approvals[0]) == actual, f"page: {approvals[0]}", f"ruleset: {actual}")

bypass = re.findall(r"`bypass_actors` lists `(\d+)` actors", squash(prose))
check("the page states the bypass actor count once", len(bypass) == 1, f"found {bypass}")
if bypass:
    check("the bypass actor count the page states is the ruleset's",
          int(bypass[0]) == len(ruleset.get("bypass_actors", [])),
          f"page: {bypass[0]}", f"ruleset: {len(ruleset.get('bypass_actors', []))}")

spans = set(re.findall(r"`([^`\n]+)`", prose))
job_names = {job.get("name", job_id)
             for doc in workflows.values() for job_id, job in doc.get("jobs", {}).items()}
check("the ruleset requires at least one check", len(contexts) >= 1, f"contexts: {contexts}")
for context in contexts:
    check(f"the page names the required check '{context}'", context in spans,
          f"code spans: {sorted(s for s in spans if ' ' in s)}")
    check(f"'{context}' is a job name in a workflow", context in job_names,
          f"jobs: {sorted(job_names)}")

# --- who can run an agent, who can open a pull request, who dispatches ------

AGENT_ACTION = re.compile(r"^(anthropics/claude|openai/codex|github/copilot)", re.I)
runners = sorted(name for name, doc in workflows.items()
                 if any(AGENT_ACTION.match(str(step.get("uses", ""))) for step in steps(doc)))
check("exactly one workflow runs an agent action", runners == ["ai-fix.yml"], f"found {runners}")
for name in runners:
    check(f"the page names {name}, the workflow that runs an agent",
          f".github/workflows/{name}" in spans)


def effective_permissions(doc, job):
    block = job.get("permissions", doc.get("permissions"))
    return block if isinstance(block, dict) else {}


openers = sorted(
    name
    for name, doc in workflows.items()
    for job in doc.get("jobs", {}).values()
    if effective_permissions(doc, job).get("contents") == "write"
    and effective_permissions(doc, job).get("pull-requests") == "write"
)
check("only ai-fix.yml has a job whose token can both push a branch and open a pull request",
      openers == ["ai-fix.yml"], f"found {openers}")

dispatchers = []
for name, doc in workflows.items():
    if triggers(doc) & {"repository_dispatch", "workflow_call"}:
        dispatchers.append(f"{name}: triggered by dispatch")
    for step in steps(doc):
        if re.search(r"gh\s+workflow\s+run|createWorkflowDispatch|/dispatches\b", str(step.get("run", "")) + str(step.get("with", ""))):
            dispatchers.append(f"{name}: starts another workflow")
check("no workflow dispatches another or is a reusable one", not dispatchers, *dispatchers)

named = [f".github/workflows/{n}" for n in ("dispatcher.yml", "orchestrate.yml")] + [
    "orchestrator", ".github/orchestrator"]
present = [p for p in named if os.path.exists(os.path.join(root, p))]
check("the dispatcher and orchestrator files the page says are absent are absent", not present,
      f"present: {present}", "if one was added on purpose, rewrite the page's 'does not run' section")

# --- ai-fix.yml, against the intake section ---------------------------------

ai_fix = workflows.get("ai-fix.yml", {})
on = ai_fix.get("on", {})
check("ai-fix.yml runs only on issue labeling and issue comments",
      triggers(ai_fix) == {"issues", "issue_comment"}, f"triggers: {sorted(triggers(ai_fix))}")
check("ai-fix.yml's issues trigger is `labeled`",
      (on.get("issues") or {}).get("types") == ["labeled"], f"{on.get('issues')}")
check("ai-fix.yml's comment trigger is `created`",
      (on.get("issue_comment") or {}).get("types") == ["created"], f"{on.get('issue_comment')}")

action = [s for s in steps(ai_fix) if AGENT_ACTION.match(str(s.get("uses", "")))]
inputs = (action[0].get("with") or {}) if action else {}
intake = squash(section(page, INTAKE))
label = inputs.get("label_trigger")
check("the label the intake section names is ai-fix.yml's label_trigger",
      bool(label) and f"`{label}`" in intake, f"label_trigger: {label}")
preflight_if = squash(str(ai_fix.get("jobs", {}).get("preflight", {}).get("if", "")))
check("the preflight filter fires on that same label",
      bool(label) and f"github.event.label.name == '{label}'" in preflight_if, preflight_if)
prefix = inputs.get("branch_prefix")
check("the branch prefix the intake section names is ai-fix.yml's branch_prefix",
      bool(prefix) and f"`{prefix}`" in intake, f"branch_prefix: {prefix}")
check("ai-fix.yml allows no bot to start it, as the intake section says",
      inputs.get("allowed_bots") == "", f"allowed_bots: {inputs.get('allowed_bots')!r}")
check("ai-fix.yml still guards on a bot sender before doing anything",
      'SENDER_TYPE}" = "Bot"' in json.dumps(ai_fix).replace('\\"', '"'))

# --- README.md still says what the page quotes it for -----------------------

hive = squash(section(readme, "Maintained with Hive (ACMM L5)"))
check("README's Maintained with Hive section exists", bool(hive))
for term in ("`hold`", "reviewer agent", "architect agent", "strategist agent"):
    check(f"README's Maintained with Hive section still mentions {term}", term in hive)
check("the page links to that section",
      "(../README.md#maintained-with-hive-acmm-l5)" in squash(page).replace("\n", " "))

# --- the roster ---------------------------------------------------------------

rows = [line for line in section(page, ROSTER).splitlines() if line.startswith("|")]
cells = [[c.strip() for c in row.strip("|").split("|")] for row in rows[2:]]
check("the roster has rows", len(cells) >= 6, f"found {len(cells)}")
signatures = []
for row in cells:
    ok = bool(re.fullmatch(r"`agent=[a-z-]+`|no `agent=` field|none, opens none", row[1]))
    check(f"roster signature for {row[0]} is well formed", ok, row[1])
    found = re.findall(r"agent=([a-z-]+)", row[1])
    signatures += found
check("no two roster rows share a signature", len(signatures) == len(set(signatures)),
      f"signatures: {signatures}")
check("the reviewer row says it opens no pull request and never merges",
      any(r[0] == "reviewer" and r[2] == "none" and "Never merges" in r[4] for r in cells))

# --- every repository path the page names exists -----------------------------

tracked = set(subprocess.run(
    ["git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard"],
    capture_output=True, text=True, check=True).stdout.split("\n")) - {""}
paths = []
for span in sorted(set(re.findall(r"`([^`\s]+)`", page))):
    in_dir = span.startswith((".github/", ".claude/", "docs/", "tests/"))
    root_file = "/" not in span and re.search(r"\.(md|yml|json)$", span)
    if in_dir or root_file:
        paths.append(span)
        prefix_dir = span.rstrip("/") + "/"
        check(f"{span} exists",
              span in tracked or any(t.startswith(prefix_dir) for t in tracked),
              f"docs/multi-agent.md names {span}, which is not in the tree")
check("the page names more than five repository paths", len(paths) > 5, f"found {paths}")

# --- commands: this repository only, and no label applied -------------------

joined = re.sub(r"\\\n\s*", " ", page)
commands = [line for line in joined.splitlines() if re.match(r"^\s*gh\s", line)]
check("the page carries gh commands", len(commands) >= 4, f"found {len(commands)}")
for command in commands:
    check(f"gh command names --repo {SLUG}: {command.strip()[:48]}...",
          f"--repo {SLUG}" in command, command)
applies = [line for line in joined.splitlines()
           if re.search(r"--add-label|--label-add|gh\s+(issue|pr)\s+edit", line)]
check("no command on the page applies a label", not applies, *applies,
      "labels such as agent/*, hive/* and quality read as auto-merge approval; see docs/SECURITY-AI.md")

print("\n".join(out))
PY

results="${TMP_ROOT}/results.tsv"
if ! "${WORKFLOW_PYTHON}" -B "${CHECKER}" "${REPO_ROOT}" "${PAGE}" "${RULESET}" \
    "${WORKFLOWS}" "${README}" >"${results}" 2>"${TMP_ROOT}/check.err"; then
    _fail "the multi-agent checker ran" "$(cat "${TMP_ROOT}/check.err")"
fi

while IFS=$'\t' read -r verdict description rest; do
    case "${verdict}" in
    ok) _pass "${description}" ;;
    FAIL)
        details=()
        IFS=$'\t' read -r -a details <<<"${rest}"
        _fail "${description}" "${details[@]}"
        ;;
    *) _fail "the checker printed only ok/FAIL lines" "unexpected: ${verdict}" ;;
    esac
done <"${results}"

finish
