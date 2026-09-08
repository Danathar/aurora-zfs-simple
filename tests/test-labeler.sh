#!/usr/bin/env bash
#
# Covers the pull request labeler: `.github/labeler.yml` and the workflow that
# applies it, `.github/workflows/labeler.yml`.
#
# Two directory-scanning checks already touch the workflow -- test-auto-qa-tuning.sh
# asserts its job declares a timeout and is declared to the manifest, and
# test-ci-workflows.sh's expression pass reads every file in .github/workflows/
# -- but nothing reads either file for what it actually says, and nothing at all
# reads the config. That leaves the labeler the one piece of automation here
# holding a write token whose shape is unasserted.
#
# The shape is the point. This job runs on `pull_request_target`, which means
# the *base* branch's copy of the workflow runs with a token that can write to
# the pull request, on an event a stranger triggers by opening one. That is safe
# for exactly as long as the job never puts the head branch's contents anywhere
# near itself: add an `actions/checkout` of the head ref, or a `run:` body that
# executes something the pull request supplied, and an outside contributor is
# running code with `pull-requests: write`. docs/SECURITY-AI.md and the
# workflow's own header both say so; until this file, neither statement failed
# anything.
#
# The config carries a second, unrelated boundary. This repository is connected
# to an external system that treats `ci`, `testing`, `quality`, `security`,
# `hive/*` and `agent/*` as an approval to auto-merge on green CI -- and `ci` and
# `testing` are precisely what a path-based labeler would attach to a change
# under `.github/workflows/` or `tests/`. Applying one would hand a pull request
# an approval no human gave it. `.github/labeler.yml` avoids that by keeping
# every label in an `area/*` namespace, and says so at length in its own
# comments. A comment is not a check: adding `testing:` to that file is one line
# and nothing goes red. So the namespace rule is asserted here, both as a rule
# (`area/` prefix) and against the label list docs/SECURITY-AI.md publishes, so
# the doc and the config cannot drift apart silently.
#
# The globs are asserted by evaluating them, not by reading them back. A
# path-to-labels table over real repository files is the only form that catches
# the failure that matters: `tests/*` instead of `tests/**` still parses, still
# looks right in review, and silently stops labeling everything below the first
# level. Since that evaluation needs a matcher, the matcher is run against a
# fixture config with known answers before it is trusted against the real one --
# an under-matching matcher would turn every case below into a vacuous pass.
#
# The workflow is read with PyYAML through the same normalizer idiom as
# test-ai-fix.sh, for the same reason: `on:` is the YAML 1.1 boolean true, and
# the properties asserted here are security properties, so a missing parser
# fails rather than skips.

set -uo pipefail

TEST_NAME="test-labeler"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

LABELER_WF="${REPO_ROOT}/.github/workflows/labeler.yml"
LABELER_CONFIG="${REPO_ROOT}/.github/labeler.yml"
SECURITY_DOC="${REPO_ROOT}/docs/SECURITY-AI.md"
WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

for required in "${LABELER_WF}" "${LABELER_CONFIG}" "${SECURITY_DOC}"; do
    if [[ ! -f "${required}" ]]; then
        _fail "${required#"${REPO_ROOT}/"} exists" \
            "no such file: ${required}" \
            "if the labeler was removed on purpose, delete this test with it"
        finish
        exit 1
    fi
done

# These are security invariants; a missing parser must fail rather than skip,
# including when this file is invoked directly instead of through run-tests.sh.
if ! "${WORKFLOW_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    _fail "the labeler checker requires Python 3 with PyYAML" \
        "install python3-yaml (Debian/Ubuntu) or python3-pyyaml (Fedora)," \
        "or install PyYAML in the interpreter selected by WORKFLOW_PYTHON"
    finish
    exit 1
fi

# =============================================================================
# A. the matcher, tested before it is trusted
# =============================================================================

MATCHER="${TMP_ROOT}/labels.py"
cat >"${MATCHER}" <<'PY'
"""Print the labels a labeler config gives each path named on the command line.

Implements the subset of actions/labeler v5 that .github/labeler.yml uses:
`changed-files` -> `any-glob-to-any-file` -> a list of globs. Any other
construct is an error rather than a silent no-match, because a config this
cannot read is a config whose labels are not being checked at all.

Glob semantics follow minimatch as the action calls it: `**` stands for zero or
more path segments, `*` and `?` match within one segment, and a leading dot is
matched like any other character (`dot: true` is the action's default, and the
config's own comment relies on it).
"""

import fnmatch
import sys

import yaml


def matches(pattern_parts, path_parts):
    if not pattern_parts:
        return not path_parts
    head, rest = pattern_parts[0], pattern_parts[1:]
    if head == "**":
        # Zero segments included: '**/*.md' has to match a top-level *.md file.
        return any(matches(rest, path_parts[i:]) for i in range(len(path_parts) + 1))
    if not path_parts:
        return False
    if not fnmatch.fnmatchcase(path_parts[0], head):
        return False
    return matches(rest, path_parts[1:])


def globs_for(label, spec):
    if not isinstance(spec, list):
        raise SystemExit(f"{label}: expected a list of match rules, got {type(spec).__name__}")
    patterns = []
    for rule in spec:
        for key, clauses in rule.items():
            if key != "changed-files":
                raise SystemExit(f"{label}: unsupported match key {key!r}")
            for clause in clauses:
                for kind, values in clause.items():
                    if kind != "any-glob-to-any-file":
                        raise SystemExit(f"{label}: unsupported match kind {kind!r}")
                    patterns.extend(values)
    if not patterns:
        raise SystemExit(f"{label}: no globs")
    return patterns


def main(argv):
    with open(argv[0], encoding="utf-8") as handle:
        config = yaml.safe_load(handle)
    if not isinstance(config, dict) or not config:
        raise SystemExit(f"{argv[0]}: expected a non-empty mapping of labels")
    rules = {label: globs_for(label, spec) for label, spec in config.items()}
    for path in argv[1:]:
        path_parts = path.split("/")
        hit = sorted(
            label
            for label, patterns in rules.items()
            if any(matches(pattern.split("/"), path_parts) for pattern in patterns)
        )
        print(f"{path}\t{','.join(hit)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PY

FIXTURE_CONFIG="${TMP_ROOT}/fixture-labeler.yml"
cat >"${FIXTURE_CONFIG}" <<'YAML'
---
'area/deep':
  - changed-files:
      - any-glob-to-any-file:
          - 'deep/**'
'area/markdown':
  - changed-files:
      - any-glob-to-any-file:
          - '**/*.md'
'area/exact':
  - changed-files:
      - any-glob-to-any-file:
          - 'Exactfile'
          - '.dotfile'
YAML

# labels_for <config> <path> — the comma-joined labels the config gives one path.
labels_for() {
    "${WORKFLOW_PYTHON}" -B "${MATCHER}" "$1" "$2" 2>"${TMP_ROOT}/matcher.err" | cut -f2-
}

# Only file paths appear here. The action matches a changed-file list, which
# never contains a bare directory, and whether `deep/**` matches the string
# `deep` is a minimatch corner this repo does not depend on either way.
fixture_ok=1
for case in \
    'deep/one.txt|area/deep' \
    'deep/a/b/c/one.txt|area/deep' \
    'deeper/one.txt|' \
    'top.md|area/markdown' \
    'deep/nested/top.md|area/deep,area/markdown' \
    'Exactfile|area/exact' \
    '.dotfile|area/exact' \
    'sub/Exactfile|'; do
    path="${case%%|*}"
    want="${case#*|}"
    got="$(labels_for "${FIXTURE_CONFIG}" "${path}")"
    if [[ "${got}" != "${want}" ]]; then
        _fail "the matcher labels the fixture path ${path} as [${want}]" \
            "got [${got}]" \
            "$(cat "${TMP_ROOT}/matcher.err")"
        fixture_ok=0
    fi
done
if [[ "${fixture_ok}" -eq 1 ]]; then
    _pass "the matcher reproduces every fixture answer, including ** across and at zero depth"
fi
if [[ "${fixture_ok}" -eq 0 ]]; then
    _fail "the matcher is trusted against the real config" \
        "the fixture answers above are wrong, so every case below would be" \
        "measuring the matcher rather than .github/labeler.yml"
    finish
    exit 1
fi

# =============================================================================
# B. .github/labeler.yml: the labels it may name
# =============================================================================

CONFIG_LABELS="${TMP_ROOT}/labels.txt"
if ! "${WORKFLOW_PYTHON}" -B -c '
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as handle:
    config = yaml.safe_load(handle)
for label in sorted(config):
    print(label)
' "${LABELER_CONFIG}" >"${CONFIG_LABELS}" 2>"${TMP_ROOT}/config.err"; then
    _fail ".github/labeler.yml parses as YAML" "$(cat "${TMP_ROOT}/config.err")"
    finish
    exit 1
fi
_pass ".github/labeler.yml parses as YAML"

if [[ ! -s "${CONFIG_LABELS}" ]]; then
    _fail ".github/labeler.yml defines at least one label" \
        "the file parsed to an empty mapping, so every assertion below is vacuous"
    finish
    exit 1
fi

off_namespace="$(grep -cv '^area/' <"${CONFIG_LABELS}")"
assert_eq "every label in .github/labeler.yml is in the area/ namespace" \
    "0" "${off_namespace}"

# The authority list is read from the doc rather than copied here, so a label
# added to one and not the other is a failure rather than a divergence nobody
# notices. The doc calls the list a snapshot of an externally owned set; that is
# an argument for re-reading it, not for hardcoding it.
AUTHORITY="${TMP_ROOT}/authority.txt"
awk '
    /^## Labels carry authority/ { in_section = 1; next }
    in_section && /^## /         { in_section = 0 }
    !in_section                  { next }
    /^```/                       { in_block = !in_block; next }
    in_block                     { for (i = 1; i <= NF; i++) print $i }
' "${SECURITY_DOC}" | sort -u >"${AUTHORITY}"

authority_count="$(wc -l <"${AUTHORITY}")"
if [[ "${authority_count}" -lt 2 ]]; then
    _fail "docs/SECURITY-AI.md still publishes the auto-merge label list" \
        "extracted ${authority_count} label(s) from the 'Labels carry authority'" \
        "section; the heading or its fenced block probably moved, and the" \
        "overlap check below would pass against an empty list"
else
    _pass "docs/SECURITY-AI.md still publishes the auto-merge label list (${authority_count} labels)"
    overlap="$(comm -12 "${AUTHORITY}" <(sort -u "${CONFIG_LABELS}") | tr '\n' ' ')"
    assert_eq "no label the labeler applies carries auto-merge authority" \
        "" "${overlap% }"
fi

# =============================================================================
# C. .github/labeler.yml: the globs, evaluated against real repository paths
# =============================================================================
#
# Every path below is a file that exists in this tree, checked as such, so the
# table cannot quietly become a statement about paths nobody ships any more.

REAL_CASES=(
    'Containerfile|area/build'
    'build_files/post-check.sh|area/build'
    '.github/workflows/build.yml|area/ci'
    '.github/labeler.yml|area/ci'
    '.github/dependabot.yml|area/ci'
    '.github/auto-qa-tuning.json|area/ci'
    'ci/write-badges.sh|area/ci'
    'renovate.json|area/ci'
    'README.md|area/docs'
    'docs/SECURITY-AI.md|area/docs'
    'tests/run-tests.sh|area/tests'
    'tests/lib/assert.sh|area/tests'
    'tests/e2e/run-e2e.sh|area/tests'
    'tests/README.md|area/docs,area/tests'
    '.shellcheckrc|area/tests'
    'AGENTS.md|area/agents,area/docs'
    'CLAUDE.md|area/agents,area/docs'
    '.claude/settings.json|area/agents'
    '.cursorrules|area/agents'
    '.github/copilot-instructions.md|area/agents,area/docs'
)

paths=()
for case in "${REAL_CASES[@]}"; do
    paths+=("${case%%|*}")
done

missing=()
for path in "${paths[@]}"; do
    [[ -e "${REPO_ROOT}/${path}" ]] || missing+=("${path}")
done
assert_eq "every path in the label table still exists in the tree" \
    "" "${missing[*]-}"

ACTUAL="${TMP_ROOT}/actual.tsv"
if ! "${WORKFLOW_PYTHON}" -B "${MATCHER}" "${LABELER_CONFIG}" "${paths[@]}" \
    >"${ACTUAL}" 2>"${TMP_ROOT}/real.err"; then
    _fail ".github/labeler.yml is readable by the matcher" "$(cat "${TMP_ROOT}/real.err")"
    finish
    exit 1
fi

for case in "${REAL_CASES[@]}"; do
    path="${case%%|*}"
    want="${case#*|}"
    got="$(awk -F'\t' -v p="${path}" '$1 == p { print $2 }' "${ACTUAL}")"
    assert_eq "${path} is labelled [${want}]" "${want}" "${got}"
done

# =============================================================================
# D. .github/workflows/labeler.yml: the shape that makes the write token safe
# =============================================================================

NORMALIZER="${TMP_ROOT}/normalize.py"
cat >"${NORMALIZER}" <<'PY'
"""Print one workflow file as JSON, with the `on:` key readable by name.

YAML 1.1 -- which is what PyYAML implements, and what Actions accepts -- reads a
bare `on` as the boolean true, so `doc["on"]` raises KeyError on every workflow
ever written. Renaming it here keeps that quirk in one place instead of in every
jq path below.
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

fixture_wf="${TMP_ROOT}/fixture-wf.yml"
cat >"${fixture_wf}" <<'YAML'
---
name: Fixture
on:
  pull_request_target:
    types:
      - opened
jobs:
  demo:
    permissions:
      contents: read
    steps:
      - uses: some/action@0000000000000000000000000000000000000000
        with:
          sync-labels: false
YAML

fixture_json="${TMP_ROOT}/fixture-wf.json"
if "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${fixture_wf}" >"${fixture_json}" 2>"${TMP_ROOT}/fixwf.err"; then
    assert_eq "the normalizer reads a fixture's trigger by name" \
        "opened" "$(jq -r '.on.pull_request_target.types[0]' <"${fixture_json}")"
    assert_eq "the normalizer reads a fixture's step inputs" \
        "false" "$(jq -r '.jobs.demo.steps[0].with["sync-labels"] | tostring' <"${fixture_json}")"
else
    _fail "the normalizer parses a fixture workflow" "$(cat "${TMP_ROOT}/fixwf.err")"
fi

WF_JSON="${TMP_ROOT}/labeler-wf.json"
if ! "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${LABELER_WF}" >"${WF_JSON}" 2>"${TMP_ROOT}/wf.err"; then
    _fail ".github/workflows/labeler.yml parses as YAML" "$(cat "${TMP_ROOT}/wf.err")"
    finish
    exit 1
fi
_pass ".github/workflows/labeler.yml parses as YAML"

wf() {
    jq -r "$1" <"${WF_JSON}"
}

assert_eq "labeler.yml triggers on exactly pull_request_target" \
    "pull_request_target" "$(wf '.on | keys | sort | join(",")')"

# Narrowed to the three events that change the file list. `edited` would re-run
# the job on a title change, and `labeled` would re-run it on the job's own
# write.
assert_eq "the trigger fires only on the events that change the file list" \
    "opened,reopened,synchronize" "$(wf '.on.pull_request_target.types | sort | join(",")')"

# Enumerated, not spot-checked: under pull_request_target these grants come from
# the base branch and are handed to a run an outside contributor started, so a
# scope added here is invisible to any test that only asks whether the ones it
# knows about are still right.
assert_eq "the label job holds exactly the two scopes it needs" \
    "contents=read pull-requests=write" \
    "$(wf '.jobs.label.permissions | to_entries | sort_by(.key) | map("\(.key)=\(.value)") | join(" ")')"

# The whole safety argument for the elevated token is that the pull request's
# code never arrives. A checkout is how it would arrive; `run:` is how it would
# execute. Both are absent, and both are asserted, because either one added
# later reads as an ordinary convenience in review.
assert_eq "the label job checks out no repository" \
    "0" "$(wf '[.jobs.label.steps[] | select(.uses != null) | select(.uses | startswith("actions/checkout@"))] | length')"
assert_eq "the label job runs no shell" \
    "0" "$(wf '[.jobs.label.steps[] | select(.run != null)] | length')"

# One step, so "the labeler action" and "everything this job does" are the same
# sentence; the two assertions above only bound what is there now.
assert_eq "the label job has exactly one step" "1" "$(wf '.jobs.label.steps | length')"

# Selected by name rather than by index, so a step inserted above it makes the
# count assertion fail on its own instead of dragging every input assertion
# below with it.
step() {
    wf "[.jobs.label.steps[] | select(.uses != null) | select(.uses | startswith(\"actions/labeler@\"))][0] | $1"
}

labeler_uses="$(step '.uses')"
assert_contains "the job applies labels with actions/labeler" "${labeler_uses}" "actions/labeler@"

# A tag is mutable, and this is the one job in the repo that would resolve it
# with a write token on a stranger's event.
if [[ "${labeler_uses}" =~ ^actions/labeler@[0-9a-f]{40}$ ]]; then
    _pass "actions/labeler is pinned to a full commit SHA"
else
    _fail "actions/labeler is pinned to a full commit SHA" \
        "got: ${labeler_uses}" \
        "a tag or short SHA can be repointed after review, and this step holds" \
        "pull-requests: write on an event any outside contributor can trigger"
fi

# false, not absent: the action's own default is to remove labels that no longer
# match, which would strip a label a human applied by hand.
assert_eq "sync-labels is off, so the action only ever adds" \
    "false" "$(step '.with["sync-labels"] | tostring')"

# No `configuration-path`, so the action reads .github/labeler.yml -- the file
# section B and C assert. Pointed elsewhere, those two sections would be
# checking a file nothing loads.
assert_eq "the step names no configuration-path, so it reads .github/labeler.yml" \
    "null" "$(step '.with["configuration-path"] // "null"')"

finish
