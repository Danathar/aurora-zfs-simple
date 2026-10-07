#!/usr/bin/env bash
#
# docs/agent-boundaries.md, against the gates it lists.
#
# The page sorts the limits on an agent into two kinds: the ones a tool
# enforces (a structural gate) and the ones that are only asked. Its value is
# that sorting, and every row of it is a claim about a file the page does not
# own. A deny rule added to .claude/settings.json, a second required check, a
# `packages: write` grant on the agent job, or a CODEOWNERS file would each leave
# the page telling an agent something false while every other test stayed green.
#
# So the claims that can be decided offline are recomputed from the tree:
#
#   * the "Holds for" column: a row naming a file under .claude/ or the runner
#     .claude/settings.json allow-lists is a Claude Code gate and must say so,
#     and no other row may, because that is the distinction the page exists to
#     draw;
#   * every file a gate row links, and every test file it names, exists;
#   * the ruleset: no bypass actors, no approval, no code-owner review, and
#     `Shell tests` the only required check, run by exactly the two workflows
#     the row names and needed by `build_push`;
#   * build.yml runs on a push to `main` only, its publishing-step `if:`
#     conditions are listed as asked rather than as a gate (a same-repository
#     pull request runs its own copy of build.yml), and ai-fix.yml's agent job
#     holds no `packages` scope and reads no `SIGNING_SECRET`;
#   * .claude/settings.json: every deny and ask rule is named in the settings
#     row, the three commands the hook row names are allow rules, the runner is
#     allow-listed beside its `_note_run_tests` key, and no rule covers
#     `gh pr merge`, which the page says is asked, not denied;
#   * agent-audit.yml runs on a schedule, and the page's CODEOWNERS section
#     stands only while no CODEOWNERS file exists where GitHub reads one.

set -uo pipefail

TEST_NAME="test-agent-boundaries-doc"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

PAGE="${REPO_ROOT}/docs/agent-boundaries.md"
WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

missing=0
for required in "${PAGE}" "${REPO_ROOT}/.github/rulesets/main.json" \
    "${REPO_ROOT}/.claude/settings.json" "${REPO_ROOT}/.github/workflows/ai-fix.yml" \
    "${REPO_ROOT}/.github/workflows/build.yml" "${REPO_ROOT}/docs/multi-agent.md"; do
    if [[ ! -e "${required}" ]]; then
        _fail "$(basename "${required}") exists" "no such path: ${required}"
        missing=1
    fi
done
if [[ "${missing}" -ne 0 ]]; then
    finish
    exit 1
fi

# The workflow facts are read with PyYAML; a missing parser must fail, not skip.
if ! "${WORKFLOW_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    _fail "the agent-boundaries checker requires Python 3 with PyYAML" \
        "install python3-yaml (Debian/Ubuntu) or python3-pyyaml (Fedora)," \
        "or install PyYAML in the interpreter selected by WORKFLOW_PYTHON"
    finish
    exit 1
fi

# --- checker ----------------------------------------------------------------
#
# Prints one line per assertion: `ok<TAB>description` or
# `FAIL<TAB>description<TAB>detail...`, as test-multi-agent-doc.sh's does.

CHECKER="${TMP_ROOT}/check.py"
cat >"${CHECKER}" <<'PY'
"""Join docs/agent-boundaries.md to the gates it lists."""

import glob
import json
import os
import re
import sys

import yaml

root, page_path = sys.argv[1:3]
out = []


def check(description, ok, *detail):
    if ok:
        out.append(f"ok\t{description}")
    else:
        out.append("\t".join(["FAIL", description, *[str(d) for d in detail]]))


def squash(text):
    return re.sub(r"\s+", " ", text).strip()


def section(text, heading):
    """The body under `## heading`, up to the next `## `."""
    match = re.search(rf"^## {re.escape(heading)}\n(.*?)(?=^## |\Z)", text, re.M | re.S)
    return match.group(1) if match else ""


def workflow(name):
    with open(os.path.join(root, ".github/workflows", name), encoding="utf-8") as handle:
        doc = yaml.safe_load(handle)
    # PyYAML reads the bare key `on` as the boolean True.
    doc["on"] = doc.pop(True, doc.get("on"))
    return doc


def rule_command(rule):
    """`Bash(git push --force:*)` -> `git push --force`; None for a non-Bash rule."""
    match = re.fullmatch(r"Bash\((.*?)(:\*)?\)", rule)
    return match.group(1) if match else None


page = open(page_path, encoding="utf-8").read()
ruleset = json.load(open(os.path.join(root, ".github/rulesets/main.json"), encoding="utf-8"))
settings = json.load(open(os.path.join(root, ".claude/settings.json"), encoding="utf-8"))
perms = settings["permissions"]

GATES = "The gates"
ASKED = "What is asked, not enforced"
NO_CODEOWNERS = "Why there is no CODEOWNERS file"
for title in (GATES, ASKED, NO_CODEOWNERS):
    check(f"§{title} exists and is not empty", bool(section(page, title).strip()))

# --- the gate table ---------------------------------------------------------

rows = []
for line in section(page, GATES).splitlines():
    if not line.startswith("|") or re.match(r"^\|\s*-", line):
        continue
    cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
    if cells[0] == "Gate":
        continue
    rows.append(cells)
check("the gate table has rows of four cells", rows and all(len(r) == 4 for r in rows),
      *[r[0] for r in rows if len(r) != 4])
rows = [r for r in rows if len(r) == 4]


def row_for(needle):
    found = [r for r in rows if needle in r[0]]
    check(f"the gate table has a row for {needle}", len(found) == 1, f"{len(found)} rows")
    return found[0] if found else ["", "", "", ""]


HOLDERS = {"every agent and every person", "the agent `ai-fix.yml` starts", "Claude Code sessions only"}
CLAUDE_ONLY = "Claude Code sessions only"
for gate, stops, holds, where in rows:
    label = squash(re.sub(r"\]\([^)]*\)", "]", gate))
    check(f"'{label}' says who it holds for in the page's words", holds in HOLDERS, holds)
    # The settings file and its hook bind only a Claude Code session, and the
    # runner is a gate only because that file allow-lists it.
    claude_side = ".claude/" in gate or "tests/run-tests.sh" in gate
    check(f"'{label}' holds for Claude Code sessions only exactly when it is Claude Code's",
          (holds == CLAUDE_ONLY) == claude_side, holds)
    for target in re.findall(r"\]\(([^)#]+)(?:#[^)]*)?\)", gate + " " + where):
        path = os.path.normpath(os.path.join(root, "docs", target))
        check(f"'{label}' links a file that exists: {target}", os.path.exists(path))
    for named in re.findall(r"`(tests/[^`]+\.sh)`", stops):
        check(f"'{label}' names a test that exists: {named}", os.path.isfile(os.path.join(root, named)))

# --- the ruleset and the required check -------------------------------------

check("the ruleset has no bypass actors, as the ruleset row says",
      ruleset.get("bypass_actors") == [], ruleset.get("bypass_actors"))
pr_rule = next((r.get("parameters", {}) for r in ruleset["rules"] if r["type"] == "pull_request"), {})
check("the ruleset needs no approval, as §What is asked says",
      pr_rule.get("required_approving_review_count") == 0, pr_rule.get("required_approving_review_count"))
check("the ruleset sets require_code_owner_review to false, as §Why there is no CODEOWNERS file says",
      pr_rule.get("require_code_owner_review") is False, pr_rule.get("require_code_owner_review"))
required = sorted(
    c["context"]
    for r in ruleset["rules"] if r["type"] == "required_status_checks"
    for c in r["parameters"]["required_status_checks"]
)
check("Shell tests is the only required check, so nothing requires a signature or a sign-off",
      required == ["Shell tests"], required)

shell_row = row_for("`Shell tests`")
named_workflows = sorted(re.findall(r"\(\.\./\.github/workflows/([^)]+)\)", shell_row[0]))
running = sorted(
    os.path.basename(path)
    for path in glob.glob(os.path.join(root, ".github/workflows/*.yml"))
    if any(job.get("name") == "Shell tests" for job in (workflow(os.path.basename(path)).get("jobs") or {}).values())
)
check("the Shell tests row names exactly the workflows with a Shell tests job",
      named_workflows == running, f"row: {named_workflows}", f"tree: {running}")

build = workflow("build.yml")
tests_job = next((jid for jid, job in build["jobs"].items() if job.get("name") == "Shell tests"), None)
needs = build["jobs"].get("build_push", {}).get("needs")
needs = [needs] if isinstance(needs, str) else (needs or [])
check("build_push needs the Shell tests job, so a red suite publishes nothing",
      tests_job is not None and tests_job in needs, f"needs: {needs}")

# --- build.yml and ai-fix.yml -----------------------------------------------

check("build.yml runs on a push to main only, so an ai-fix/* branch push starts no build",
      (build["on"].get("push") or {}).get("branches") == ["main"], build["on"].get("push"))
guard = "github.event_name != 'pull_request' && github.ref == format('refs/heads/{0}', github.event.repository.default_branch)"
guarded = [s for s in build["jobs"]["build_push"].get("steps", []) if s.get("if") == guard]
check("build.yml still guards publishing steps on non-pull-request runs of the default branch",
      bool(guarded))
# A same-repository pull request runs its own copy of build.yml, so those
# conditions are only as strong as review of the file: they are asked, not a gate.
check("no gate row claims the publishing-step if: conditions as a gate",
      not [r for r in rows if "`if:` conditions" in r[0]])
check("§What is asked lists the publishing-step if: conditions and says a pull request runs its own copy",
      "The `if:` conditions on the publishing steps" in squash(section(page, ASKED))
      and "pull request's own copy of `build.yml`" in squash(section(page, ASKED)))

ai_fix = workflow("ai-fix.yml")
fix = ai_fix["jobs"].get("fix", {})
check("ai-fix.yml has the preflight job the row names, and the agent job needs it",
      "preflight" in ai_fix["jobs"] and fix.get("needs") == "preflight", fix.get("needs"))
check("ai-fix.yml's agent job holds no packages scope",
      "packages" not in (fix.get("permissions") or {}), fix.get("permissions"))
code = [line for line in open(os.path.join(root, ".github/workflows/ai-fix.yml"), encoding="utf-8")
        if not line.lstrip().startswith("#")]
check("ai-fix.yml reads no SIGNING_SECRET outside its comments",
      not any("SIGNING_SECRET" in line for line in code))

# --- .claude/settings.json and its hook -------------------------------------

settings_row = row_for("[`.claude/settings.json`]")[1]
for rule in perms["deny"]:
    if rule.startswith("Read("):
        target = re.fullmatch(r"Read\(\./(.*)\)", rule)
        check(f"the settings row names the denied read {rule}",
              bool(target) and f"`{target.group(1)}`" in settings_row, settings_row)
        continue
    command = rule_command(rule)
    if command and command.split()[0] in ("podman", "buildah"):
        check(f"{rule} is one of the prune and remove-all commands the settings row summarises",
              "prune and remove-all" in settings_row
              and ("prune" in command or command.endswith((" -a", " --all"))), command)
    else:
        check(f"the settings row names the denied command {rule}",
              bool(command) and f"`{command}`" in settings_row, command)
for rule in perms["ask"]:
    command = rule_command(rule)
    check(f"the settings row names the asked command {rule}",
          bool(command) and f"`{command}`" in settings_row, command)

allowed = {rule_command(rule) for rule in perms["allow"]}
hook_row = row_for("gate-git-diff.sh")[1]
for command in ("git diff", "shellcheck", "gh pr view"):
    check(f"the hook row's example `{command}` is an allow rule",
          command in allowed and f"`{command}" in hook_row, sorted(c for c in allowed if c))

check("the runner is allow-listed with any arguments, which is what makes it a gate",
      "./tests/run-tests.sh" in allowed and "Bash(./tests/run-tests.sh:*)" in perms["allow"])
check("the runner row's reference, _note_run_tests, is a key of the settings file",
      "_note_run_tests" in settings and "_note_run_tests" in row_for("tests/run-tests.sh")[3])

merge_rules = [rule for kind in ("allow", "deny") for rule in perms[kind]
               if (command := rule_command(rule)) and "gh pr merge".startswith(command)]
check("no allow or deny rule covers gh pr merge, so it is asked, not denied, as §What is asked says",
      not merge_rules, *merge_rules)
check("§What is asked says gh pr merge is asked first and not denied",
      "`gh pr merge` is not on the settings file's allow list" in squash(section(page, ASKED)))

# --- the record, CODEOWNERS, and reachability -------------------------------

audit = workflow("agent-audit.yml")
check("agent-audit.yml runs on a schedule, after the merge rather than before it",
      bool(audit["on"].get("schedule")), audit["on"])

present = [p for p in ("CODEOWNERS", ".github/CODEOWNERS", "docs/CODEOWNERS")
           if os.path.exists(os.path.join(root, p))]
check("no CODEOWNERS file exists while the page says there is none", not present, *present,
      "update §Why there is no CODEOWNERS file and the gate table in the same change")

multi = open(os.path.join(root, "docs/multi-agent.md"), encoding="utf-8").read()
check("docs/multi-agent.md links to the page", "](agent-boundaries.md)" in multi)

print("\n".join(out))
PY

results="${TMP_ROOT}/results.tsv"
if ! "${WORKFLOW_PYTHON}" -B "${CHECKER}" "${REPO_ROOT}" "${PAGE}" \
    >"${results}" 2>"${TMP_ROOT}/check.err"; then
    _fail "the agent-boundaries checker ran" "$(cat "${TMP_ROOT}/check.err")"
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
