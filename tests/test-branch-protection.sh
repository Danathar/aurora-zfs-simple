#!/usr/bin/env bash
#
# docs/branch-protection.md, against the ruleset it explains.
#
# The page says what keeps `main` behind a pull request, explains each rule in
# .github/rulesets/main.json, and tells a reader how to check that GitHub is
# enforcing it. docs/SECURITY-AI.md leans on it: the `contents: write` grant in
# ai-fix.yml is bounded only because the ruleset exists.
#
# Nothing read it as a document. test-ai-fix.sh checks the shape of main.json
# and test-docs-paths.sh resolves the page's links, but the explanation itself
# was a second copy of the JSON that nothing compared to the first. It drifted
# on the day it was written: the page said "`main` has no branch protection and
# no ruleset" and the ruleset was applied 38 minutes after that commit, while
# the page, docs/SECURITY-AI.md (twice), README.md's file map and
# tests/README.md all went on saying `main` was unprotected (issue #245).
#
# So the page's rule bullets are parsed and joined to the JSON both ways, the
# jobs a pull request gets are classified as required or named as deliberately
# not required, and the Status section's ruleset name and id are joined to the
# JSON and to the update command. The live ruleset is repository configuration
# no offline test can read; what is asserted here is that no document claims it
# is missing, because it is not, and the page carries the commands that show it.

set -uo pipefail

TEST_NAME="test-branch-protection"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

PAGE="${REPO_ROOT}/docs/branch-protection.md"
RULESET="${REPO_ROOT}/.github/rulesets/main.json"
WORKFLOWS="${REPO_ROOT}/.github/workflows"
WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

missing=0
for required in "${PAGE}" "${RULESET}"; do
    if [[ ! -f "${required}" ]]; then
        _fail "$(basename "${required}") exists" "no such file: ${required}"
        missing=1
    fi
done
if [[ "${missing}" -ne 0 ]]; then
    finish
    exit 1
fi

# The job classification reads every workflow; a missing parser must fail, not
# skip, or the check that no pull request waits forever asserts nothing.
if ! "${WORKFLOW_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    _fail "the branch-protection checker requires Python 3 with PyYAML" \
        "install python3-yaml (Debian/Ubuntu) or python3-pyyaml (Fedora)," \
        "or install PyYAML in the interpreter selected by WORKFLOW_PYTHON"
    finish
    exit 1
fi

# --- checker ----------------------------------------------------------------
#
# Prints one line per assertion: `ok<TAB>description` or
# `FAIL<TAB>description<TAB>detail...`. Kept in Python because the page is
# parsed into sections and bullets and the workflows into jobs, and doing either
# in sed is where a check quietly stops matching.

CHECKER="${TMP_ROOT}/check.py"
cat >"${CHECKER}" <<'PY'
"""Join docs/branch-protection.md to .github/rulesets/main.json."""

import glob
import json
import os
import re
import subprocess
import sys

import yaml

root, page_path, ruleset_path, workflows = sys.argv[1:5]
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


def bullets(body):
    """Top-level `- ` bullets with their continuation lines, squashed."""
    items, current = [], None
    for line in body.splitlines():
        if line.startswith("- "):
            if current is not None:
                items.append(squash(current))
            current = line[2:]
        elif current is not None and line.startswith("  "):
            current += " " + line
        elif current is not None:
            items.append(squash(current))
            current = None
    if current is not None:
        items.append(squash(current))
    return items


page = open(page_path, encoding="utf-8").read()
ruleset = json.load(open(ruleset_path, encoding="utf-8"))
prose = outside_fences(page)

rules = {rule["type"]: rule.get("parameters", {}) for rule in ruleset["rules"]}
contexts = [
    check_["context"]
    for check_ in rules.get("required_status_checks", {}).get("required_status_checks", [])
]

# --- the rule bullets, joined to the JSON both ways --------------------------

items = bullets(section(prose, "The ruleset"))
check("§The ruleset has rule bullets to read", len(items) >= 5,
      f"found {len(items)} bullet(s); the parser or the page changed shape")

leads = {}
for item in items:
    match = re.match(r"\*\*(.+?)\*\*", item)
    check(f"bullet opens with a bold lead: {item[:50]}...", bool(match),
          "every rule bullet names what it explains in bold first")
    if match:
        leads[match.group(1)] = item


def lead(pattern):
    found = [(k, v) for k, v in leads.items() if re.search(pattern, k, re.I)]
    return found[0] if len(found) == 1 else (None, None)


# Rule types the page explains: the ones it spells in a bold lead, plus
# required_status_checks for the lead that is about required checks, since the
# page names that rule by its effect rather than its JSON spelling.
named = set()
for key in leads:
    named |= {tok for tok in re.findall(r"`([^`]+)`", key) if re.fullmatch(r"[a-z_]+", tok)}
    if re.search(r"\brequired checks?\b", key, re.I):
        named.add("required_status_checks")
check("every rule the page explains is in main.json",
      named <= set(rules), f"explained but not in the ruleset: {sorted(named - set(rules))}")
check("every rule in main.json is explained on the page",
      set(rules) <= named, f"in the ruleset but not explained: {sorted(set(rules) - named)}")

key, _ = lead(r"^Targets ")
target = re.findall(r"`([^`]+)`", key or "")
check("the target the page names is the ruleset's",
      target == ruleset["conditions"]["ref_name"]["include"],
      f"page: {target}", f"ruleset: {ruleset['conditions']['ref_name']['include']}")
check("the ruleset excludes no ref the page does not mention",
      ruleset["conditions"]["ref_name"].get("exclude", []) == [],
      f"exclude: {ruleset['conditions']['ref_name'].get('exclude')}")

key, _ = lead(r"bypass")
check("the page states the bypass list", key is not None, f"leads: {sorted(leads)}")
if key is not None:
    says_none = bool(re.match(r"No bypass actors", key))
    check("'No bypass actors' is what main.json says",
          says_none == (len(ruleset.get("bypass_actors", [])) == 0),
          f"lead: {key}", f"bypass_actors: {ruleset.get('bypass_actors')}")

key, _ = lead(r"`pull_request`")
approvals = re.search(r"with (\d+) approvals?", key or "")
check("the page states the pull_request approval count", approvals is not None, f"lead: {key}")
if approvals:
    actual = rules.get("pull_request", {}).get("required_approving_review_count")
    check("the approval count the page states is the ruleset's",
          int(approvals.group(1)) == actual, f"page: {approvals.group(1)}", f"ruleset: {actual}")

NUMBERS = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5}
key, body = lead(r"required checks?")
check("the page has one bullet about required checks", key is not None, f"leads: {sorted(leads)}")
if key is not None:
    count = re.match(r"(\w+) required checks?", key, re.I)
    stated = NUMBERS.get(count.group(1).lower()) if count else None
    check("the number of required checks the page states is the ruleset's",
          stated == len(contexts), f"lead: {key}", f"contexts: {contexts}")
    lead_names = re.findall(r"`([^`]+)`", key)
    check("the required checks the page names are the ruleset's",
          sorted(lead_names) == sorted(contexts), f"page: {lead_names}", f"ruleset: {contexts}")

    ids = {c.get("integration_id") for c in
           rules["required_status_checks"]["required_status_checks"]}
    stated_ids = {int(n) for n in re.findall(r"`integration_id` (\d+)", body)}
    check("the integration_id the page explains is the one the ruleset pins",
          stated_ids == ids and len(ids) == 1, f"page: {sorted(stated_ids)}", f"ruleset: {sorted(ids)}")

    # Every job a pull request can get is either required or named in this
    # bullet as deliberately not required, and every job name the bullet
    # mentions is a real one. A new pull_request job that nobody classified is
    # exactly the one that would be missed when the required set is revisited.
    pr_jobs, job_files = set(), {}
    for path in sorted(glob.glob(os.path.join(workflows, "*.yml"))):
        doc = yaml.safe_load(open(path, encoding="utf-8"))
        on = doc.get(True, doc.get("on", {}))
        triggers = set(on) if isinstance(on, dict) else set(on if isinstance(on, list) else [on])
        for job_id, job in doc.get("jobs", {}).items():
            name = job.get("name", job_id)
            job_files.setdefault(name, set()).add(os.path.basename(path))
            if triggers & {"pull_request", "pull_request_target"}:
                pr_jobs.add(name)
    mentioned = {tok for tok in re.findall(r"`([^`]+)`", body) if tok in job_files}
    unclassified = pr_jobs - set(contexts) - mentioned
    check("every job a pull request gets is required or named as not required",
          not unclassified, f"unclassified: {sorted(unclassified)}")
    not_jobs = {tok for tok in re.findall(r"`([^`]+)`", body)
                if " " in tok and tok not in job_files}
    check("every job name the required-check bullet uses is a real job",
          not not_jobs, f"not a job in any workflow: {sorted(not_jobs)}")

    # The workflows the bullet says run the required check must be exactly the
    # ones whose jobs carry that name.
    wf_named = set(re.findall(r"`([\w-]+\.yml)`", body))
    for context in contexts:
        check(f"the workflows the page says run '{context}' are the ones that do",
              wf_named == job_files.get(context, set()),
              f"page: {sorted(wf_named)}", f"workflows: {sorted(job_files.get(context, set()))}")

key, body = lead(r"`deletion`")
if key is not None:
    status_wf = open(os.path.join(workflows, "status-badges.yml"), encoding="utf-8").read()
    check("the page names the `status` branch it leaves uncovered",
          "`status` branch that `status-badges.yml` pushes to" in squash(prose),
          "the phrase this check joins to status-badges.yml is gone; update both")
    check("status-badges.yml pushes to the `status` branch the page exempts",
          bool(re.search(r"git push \S+ HEAD:status\b", status_wf)),
          "the page says status-badges.yml pushes to `status`; it no longer does")

# --- the Status section, joined to the JSON and the update command ----------

status = squash(section(prose, "Status"))
check("the Status section tells a reader which ruleset name to look for",
      f"lists `{ruleset['name']}`" in status,
      f"expected 'lists `{ruleset['name']}`'", f"section: {status[:200]}")
status_ids = set(re.findall(r"ruleset `(\d+)`", status))
check("the Status section records the live ruleset's id", len(status_ids) == 1,
      f"found: {sorted(status_ids)}")
update = re.findall(r"--method PUT repos/[\w.-]+/[\w.-]+/rulesets/(\S+)", page)
check("the update command names the ruleset the Status section records",
      len(update) == 1 and set(update) == status_ids,
      f"PUT targets: {update}", f"Status id: {sorted(status_ids)}")
for verb in ("POST", "PUT"):
    inputs = re.findall(rf"--method {verb} .*?\\\n\s*--input (\S+)", page)
    check(f"the {verb} command reads the committed ruleset",
          inputs == [".github/rulesets/main.json"], f"--input: {inputs}")

slugs = set(re.findall(r"gh api (?:--method \w+ )?repos/([\w.-]+/[\w.-]+)/", page))
readme = open(os.path.join(root, "README.md"), encoding="utf-8").read()
check("every gh api call on the page names this repository",
      len(slugs) == 1 and f"github.com/{next(iter(slugs))}/" in readme,
      f"slugs: {sorted(slugs)}")

# --- no document says the ruleset is missing -------------------------------
#
# It was applied on 2026-09-24 (issue #242). The phrasings below are the ones
# that survived that day in four files; a document that needs to say `main` is
# unprotected again should first be sure it is, and then change this list.

STALE = [
    r"`main` has no branch protection",
    r"`main` is unprotected(?! again)",
    r"not yet\s+applied",
    r"for an admin to apply",
    r"until the ruleset\b.*?\bis applied",
    r"which no file in the tree can assert",
]
tracked = subprocess.run(["git", "-C", root, "ls-files", "*.md"],
                         capture_output=True, text=True, check=True).stdout.split()
check("tracked Markdown was listed", len(tracked) > 10, f"found {len(tracked)}")
hits = []
for rel in tracked:
    text = squash(open(os.path.join(root, rel), encoding="utf-8").read())
    for pattern in STALE:
        for match in re.finditer(pattern, text):
            hits.append(f"{rel}: ...{text[max(0, match.start() - 40):match.end() + 20]}...")
check("no document says the ruleset on main is missing or unapplied", not hits, *hits)

print("\n".join(out))
PY

results="${TMP_ROOT}/results.tsv"
if ! "${WORKFLOW_PYTHON}" -B "${CHECKER}" "${REPO_ROOT}" "${PAGE}" "${RULESET}" "${WORKFLOWS}" \
    >"${results}" 2>"${TMP_ROOT}/check.err"; then
    _fail "the branch-protection checker ran" "$(cat "${TMP_ROOT}/check.err")"
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
