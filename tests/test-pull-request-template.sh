#!/usr/bin/env bash
#
# Joins .github/pull_request_template.md to the tree its checklist describes.
#
# Before this file nothing in tests/ opened it. `grep -rn pull_request_template
# tests/` returned one hit and it was prose: tests/README.md's "Not covered"
# paragraph, which put the template beside .github/prompts/** and
# copilot-instructions.md as "read by a human or an agent, not parsed", with
# its relative links left to test-docs-paths.sh's third pass. Neither half held
# for this file. That pass resolves `](path)` targets and the template has none,
# so it was a no-op here; the pass that checks inline code spans runs over
# README.md and AGENTS.md only. Net coverage was zero assertions.
#
# The template is also the wrong document to leave unchecked. Nearly every
# sentence in it restates a fact that lives somewhere else -- the command CI
# runs, which build scripts no test can reach, what a pull request build does
# not do -- and it is the one document every contributor and every ai-fix/*
# pull request body is written against. A claim that has drifted fails nothing;
# it is copied into the next PR description by a reader with no reason to doubt
# it, which is exactly the tier-1 "misleads a human or an agent mid-incident"
# failure docs/risk-tiers.md describes.
#
# So nothing here is typed in twice where it can be computed. The uncovered
# build scripts come out of tests/test-coverage.sh's manifest, the suite command
# out of the workflow steps that run it, the workflow name out of its own
# `name:`, the publish guard out of the steps it guards. Set claims are checked
# in both directions, so a script that gains a test, or a fourth one that does
# not, fails here rather than in a reader's head. Extractions refuse to verify
# an empty set, so a renamed step fails instead of passing vacuously, and every
# verified sentence is held by `require_claim` -- delete the sentence and this
# file fails rather than quietly checking the tree against nothing.
#
# Scope: the claims that name something in this repository, and the structure
# GitHub needs to render the file at all. Judgements ("the strongest evidence")
# and the prompts in the HTML comments are for a human and are left alone.
# Link targets remain test-docs-paths.sh's and are not re-resolved here.

set -uo pipefail

TEST_NAME="test-pull-request-template"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=tests/lib/markdown.sh
source "${TEST_DIR}/lib/markdown.sh"

TEMPLATE_REL=".github/pull_request_template.md"
TEMPLATE="${REPO_ROOT}/${TEMPLATE_REL}"
COVERAGE_TEST="${TEST_DIR}/test-coverage.sh"
SYNTAX_TEST="${TEST_DIR}/test-shell-syntax.sh"
POST_CHECK="${REPO_ROOT}/build_files/post-check.sh"
CONTAINERFILE="${REPO_ROOT}/Containerfile"
BUILD_WF="${REPO_ROOT}/.github/workflows/build.yml"
AGENTS="${REPO_ROOT}/AGENTS.md"
README="${REPO_ROOT}/README.md"
RISK_TIERS="${REPO_ROOT}/docs/risk-tiers.md"
WORKFLOW_DIR="${REPO_ROOT}/.github/workflows"
WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

missing=0
for required in \
    "${TEMPLATE}" "${COVERAGE_TEST}" "${SYNTAX_TEST}" "${POST_CHECK}" \
    "${CONTAINERFILE}" "${BUILD_WF}" "${AGENTS}" "${README}" "${RISK_TIERS}"; do
    [[ -f "${required}" ]] && continue
    _fail "${required#"${REPO_ROOT}"/} is present" "no such file"
    missing=1
done

if [[ "${missing}" -ne 0 ]]; then
    finish
    exit
fi

# --- helpers ----------------------------------------------------------------

# A file with its line breaks collapsed. Prose wraps, so every sentence below is
# matched against this form: a claim that has to be found at one particular wrap
# point is a claim a reflow can silently delete.
flattened() {
    tr '\n' ' ' <"$1" | tr -s '[:space:]' ' '
}

TEMPLATE_FLAT="$(flattened "${TEMPLATE}")"

# A claim this file goes on to verify has to still be in the document.
require_claim() {
    local description=$1 needle=$2
    if [[ "${TEMPLATE_FLAT}" == *"${needle}"* ]]; then
        _pass "${TEMPLATE_REL} still claims ${description}"
        return 0
    fi
    _fail "${TEMPLATE_REL} still claims ${description}" \
        "the sentence this test verifies is gone: ${needle}" \
        "either restore it or drop the assertions that depend on it"
    return 1
}

# An extraction that matched nothing is not a passing check, it is an
# unverified document.
require_nonempty() {
    local description=$1 content=$2
    if [[ -n "${content//[[:space:]]/}" ]]; then
        _pass "still has ${description}"
        return 0
    fi
    _fail "still has ${description}" \
        "nothing was extracted, so the checks over it verify nothing"
    return 1
}

as_set() {
    tr ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# --- 1. the file GitHub actually reads --------------------------------------

tracked_templates="$(cd "${REPO_ROOT}" &&
    git ls-files | grep -iE '(^|/)pull_request_template\.md$|(^|/)PULL_REQUEST_TEMPLATE(/|\.md$)' |
    as_set)"
assert_eq "exactly one pull request template is tracked, at the path GitHub reads" \
    "${TEMPLATE_REL}" "${tracked_templates}"

# A second template under .github/PULL_REQUEST_TEMPLATE/ would make GitHub
# offer a chooser instead of prefilling this body, so the assertion above is
# about behaviour, not tidiness.

headings="$(heading_slugs "${TEMPLATE}" | as_set)"
require_nonempty "headings in ${TEMPLATE_REL}" "${headings}"
for required_heading in what-this-changes why checks if-this-touches-the-image-build notes-for-review; do
    if [[ " ${headings} " == *" ${required_heading} "* ]]; then
        _pass "${TEMPLATE_REL} still has the '${required_heading}' section"
    else
        _fail "${TEMPLATE_REL} still has the '${required_heading}' section" \
            "sections found: ${headings}" \
            "this test reads claims out of these sections; a renamed one hides them"
    fi
done

# Every box ships unchecked. A pre-ticked box is a claim the author never made,
# and it renders as satisfied in the pull request body.
boxes="$(grep -cE '^[[:space:]]*- \[ \] ' "${TEMPLATE}")"
prechecked="$(grep -cE '^[[:space:]]*- \[[^ ]\] ' "${TEMPLATE}")"
if [[ "${boxes}" -gt 0 ]]; then
    _pass "${TEMPLATE_REL} has ${boxes} checklist item(s)"
else
    _fail "${TEMPLATE_REL} has checklist items" \
        "no '- [ ]' line found; the Checks section is what the rest of this test joins"
fi
assert_eq "no checklist item ships pre-ticked" "0" "${prechecked}"

# --- 2. the command the checklist names is the command CI runs --------------

# SC2016 here and below: the backticks delimit Markdown code spans in a quoted
# sentence, not a command substitution, so they stay literal.
# shellcheck disable=SC2016
require_claim "the suite is run as ./tests/run-tests.sh" \
    '- [ ] `./tests/run-tests.sh` passes locally'

assert_file_exists "the runner the template names exists" "${REPO_ROOT}/tests/run-tests.sh"
if [[ -x "${REPO_ROOT}/tests/run-tests.sh" ]]; then
    _pass "tests/run-tests.sh is executable, so the command as written runs"
else
    _fail "tests/run-tests.sh is executable, so the command as written runs" \
        "the template tells a contributor to run ./tests/run-tests.sh directly"
fi

# Every step, in every workflow, whose `run:` body reaches the suite. The bodies
# are read through the YAML parser rather than grepped for a `run:` line: the
# block form `run: |` puts the command on the line after the key, so a
# line-anchored pattern never sees a workflow written that way, and a workflow
# this discovery cannot see is one that can run the suite with no shellcheck
# install and pass every check below. PyYAML is already a requirement of the
# suite (CONTRIBUTING.md); a missing parser fails here rather than skips.
if ! "${WORKFLOW_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    _fail "reading the workflows requires Python 3 with PyYAML" \
        "install python3-yaml (Debian/Ubuntu) or python3-pyyaml (Fedora)," \
        "or install PyYAML in the interpreter selected by WORKFLOW_PYTHON"
    finish
    exit 1
fi

NORMALIZER="${TMP_ROOT}/normalize.py"
cat >"${NORMALIZER}" <<'PY'
"""Print one workflow file as JSON, with the `on:` key readable by name.

PyYAML implements YAML 1.1, where a bare `on` is the boolean true, so
doc["on"] raises KeyError on every workflow ever written.
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

JSON_DIR="${TMP_ROOT}/json"
mkdir -p "${JSON_DIR}"

# normalize <workflow>: writes ${JSON_DIR}/<basename>.json, or ends the run --
# a workflow that does not parse leaves nothing below worth reading.
normalize() {
    local file=$1 out
    out="${JSON_DIR}/$(basename "${file}").json"
    if ! "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${file}" >"${out}" 2>"${TMP_ROOT}/normalize.err"; then
        _fail "$(basename "${file}") parses" "$(cat "${TMP_ROOT}/normalize.err")"
        finish
        exit 1
    fi
}

# steps_of <workflow>: every step of every job, one JSON object per line, in
# the job's order. A key that is absent comes out as "" and one that is
# present as its text, so `if: false` reads "false" rather than as no `if:`
# at all -- the difference between a step that runs and one that is skipped.
# The job's own `if:` and `continue-on-error:` ride along, because a job that
# is skipped or allowed to fail takes every step with it. The shell is the
# effective one: the step's own, else the job's `defaults.run.shell`, else the
# workflow's, which is how GitHub resolves it. A run: body is trimmed, so a
# block scalar's trailing newline does not spoil an exact comparison.
steps_of() {
    jq -c --arg file "$(basename "$1")" '
        def field($k): if has($k) then (.[$k] | tostring) else "" end;
        def default_shell: ((.defaults // {}) | (.run // {}) | field("shell"));
        default_shell as $wf_shell
        | (.jobs // {}) | to_entries[] | .key as $job | .value as $j
        | ($j | field("if")) as $job_if
        | ($j | field("continue-on-error")) as $job_coe
        | ($j | default_shell) as $job_shell
        | (($j.steps // []) | to_entries[]) | .key as $index | .value
        | { file: $file, job: $job, position: ($index + 1),
            name: (if has("name") then (.name | tostring) else "<unnamed>" end),
            if: field("if"), continue_on_error: field("continue-on-error"),
            job_if: $job_if, job_continue_on_error: $job_coe,
            shell: (if field("shell") != "" then field("shell")
                    elif $job_shell != "" then $job_shell
                    else $wf_shell end),
            uses: field("uses"),
            run: (field("run") | sub("^\\s+"; "") | sub("\\s+$"; "")) }
    ' "${JSON_DIR}/$(basename "$1").json"
}

# jobs_of <workflow>: every job of a workflow, one JSON object per line. A job
# that calls a reusable workflow carries a job-level `uses:` and no `steps:`,
# so steps_of emits nothing for it and a check that reads only steps never
# sees it -- while the call itself can carry `permissions:` and
# `secrets: inherit` and publish. step_count is what separates the two job
# shapes; an absent key comes out as "", as it does for a step.
jobs_of() {
    jq -c --arg file "$(basename "$1")" '
        def field($k): if has($k) then (.[$k] | tostring) else "" end;
        (.jobs // {}) | to_entries[]
        | { file: $file, job: .key,
            if: (.value | field("if")),
            uses: (.value | field("uses")),
            step_count: ((.value.steps // []) | length) }
    ' "${JSON_DIR}/$(basename "$1").json"
}

# field <key> <step>: one value out of a step object.
field() {
    jq -r --arg k "$1" '.[$k]' <<<"$2"
}

# steps_where <jq filter> [jq --arg ...]: the steps, out of every workflow,
# that the filter selects.
steps_where() {
    local filter=$1
    shift
    jq -c "$@" "select(${filter})" <<<"${STEPS}"
}

# A step runs under GitHub's default shell, `bash -eo pipefail`, unless it or
# a `defaults.run.shell` above it says otherwise, and `-e` is what makes a
# failing command a failing step. `shell: bash` keeps that; anything else --
# `sh`, a custom template without -e, another language -- is not the path
# this test reasons about. The value read is the effective one, so a shell
# inherited from the job or the workflow is judged the same as one on the
# step.
runs_under_bash_e() {
    local label=$1 step=$2 shell
    shell="$(field shell "${step}")"
    if [[ -z "${shell}" || "${shell}" == "bash" ]]; then
        _pass "${label} runs under bash -e, so a failing command fails the step"
    else
        _fail "${label} runs under bash -e, so a failing command fails the step" \
            "effective shell: ${shell}"
    fi
}

# A step that can be skipped or fail quietly is not one the checkbox can
# point at. Its own `if:` and `continue-on-error:` do that, and so do the
# same two keys on the job around it.
runs_unconditionally() {
    local label=$1 step=$2
    assert_eq "${label} has no if: that could skip it" "" "$(field if "${step}")"
    assert_eq "${label} does not continue on error" "" "$(field continue_on_error "${step}")"
    assert_eq "${label} is in a job with no if: that could skip it" "" "$(field job_if "${step}")"
    assert_eq "${label} is in a job that does not continue on error" "" \
        "$(field job_continue_on_error "${step}")"
}

# The extractor is only worth trusting if it sees the block form, counts a
# step with no run: body so positions stay the job's, keeps `if:` and
# `continue-on-error:` from both the step and its job as the text they carry,
# and resolves the shell the way GitHub does: step, then job, then workflow.
# The fixture has all of it.
FIXTURE_WF="${TMP_ROOT}/fixture.yml"
cat >"${FIXTURE_WF}" <<'YAML'
name: fixture
on: push
defaults:
  run:
    shell: bash
jobs:
  block:
    runs-on: ubuntu-24.04
    steps:
      - name: Install shellcheck
        run: |
          sudo apt-get install -y shellcheck
      - name: Suite in a block scalar
        run: |
          ./tests/run-tests.sh
  loose:
    runs-on: ubuntu-24.04
    if: false
    continue-on-error: true
    defaults:
      run:
        shell: sh
    steps:
      - uses: actions/checkout@v4
      - name: Softened install
        if: false
        continue-on-error: true
        shell: bash
        run: sudo apt-get install -y shellcheck || true
      - name: Suite with a suffix
        run: ./tests/run-tests.sh || true
  called:
    uses: ./.github/workflows/reusable.yml
    permissions:
      packages: write
    secrets: inherit
YAML
normalize "${FIXTURE_WF}"
assert_eq "the step extractor sees block scalars, counts every step, keeps step and job conditions, and resolves the shell" \
    "$(printf '%s\n' \
        $'block\t1\tInstall shellcheck\t\t\t\t\tbash\t\tsudo apt-get install -y shellcheck' \
        $'block\t2\tSuite in a block scalar\t\t\t\t\tbash\t\t./tests/run-tests.sh' \
        $'loose\t1\t<unnamed>\t\t\tfalse\ttrue\tsh\tactions/checkout@v4\t' \
        $'loose\t2\tSoftened install\tfalse\ttrue\tfalse\ttrue\tbash\t\tsudo apt-get install -y shellcheck || true' \
        $'loose\t3\tSuite with a suffix\t\t\tfalse\ttrue\tsh\t\t./tests/run-tests.sh || true')" \
    "$(steps_of "${FIXTURE_WF}" |
        jq -r '[.job, .position, .name, .if, .continue_on_error, .job_if, .job_continue_on_error,
                .shell, .uses, .run] | @tsv')"

# The same fixture read as jobs: the reusable-workflow call contributes no
# step at all above, and here it is a job like any other, with its `uses:`
# and a step count of zero.
assert_eq "the job extractor sees every job, including a reusable-workflow call with no steps" \
    "$(printf '%s\n' \
        $'block\t\t\t2' \
        $'called\t\t./.github/workflows/reusable.yml\t0' \
        $'loose\tfalse\t\t3')" \
    "$(jobs_of "${FIXTURE_WF}" | jq -r '[.job, .if, .uses, .step_count] | @tsv' | LC_ALL=C sort)"

# GitHub reads both extensions, so a suite step in a .yaml file is as much a
# claim about CI as one in a .yml file, and a glob on one of them is a hole.
mapfile -t WORKFLOW_FILES < <(find "${WORKFLOW_DIR}" -maxdepth 1 -type f \
    \( -name '*.yml' -o -name '*.yaml' \) | sort)
if [[ "${#WORKFLOW_FILES[@]}" -eq 0 ]]; then
    _fail "still has workflow files under .github/workflows" \
        "nothing to read the suite steps from"
    finish
    exit 1
fi
_pass "still has workflow files under .github/workflows"

STEPS=""
for wf_path in "${WORKFLOW_FILES[@]}"; do
    normalize "${wf_path}"
    STEPS+="$(steps_of "${wf_path}")"$'\n'
done

suite_steps="$(steps_where '.run | contains("run-tests.sh")')"
require_nonempty "workflow steps that run the shell suite" "${suite_steps}"

# The value is compared, not searched for. `./tests/run-tests.sh || true`
# contains the command and returns success from a failing suite; an argument
# runs only part of it; a wrapper runs something else. An `if:` or a
# `continue-on-error:` on the step or on its job leaves the workflow green
# with the suite skipped or red. Each is a workflow whose green does not mean
# what the checkbox says.
while IFS= read -r step; do
    [[ -n "${step}" ]] || continue
    label="$(field file "${step}"): '$(field name "${step}")' in job '$(field job "${step}")'"
    assert_eq "${label} runs the suite as the template writes it" \
        "./tests/run-tests.sh" "$(field run "${step}")"
    runs_unconditionally "${label}" "${step}"
    runs_under_bash_e "${label}" "${step}"
done <<<"${suite_steps}"

# --- 3. the shellcheck caveat -----------------------------------------------

require_claim "the shellcheck pass is skipped when the tool is absent" \
    'so its pass was enforced and not skipped (CI installs it; a developer machine may not have it)'

syntax_test_body="$(cat "${SYNTAX_TEST}")"
assert_contains "test-shell-syntax.sh gates its shellcheck pass on the tool being present" \
    "${syntax_test_body}" 'if command -v shellcheck >/dev/null 2>&1; then'
assert_contains "and says so rather than failing when it is not" \
    "${syntax_test_body}" 'skip shellcheck (not installed)'

# "CI installs it" is a claim about every job that runs the suite, and about
# the step that does the installing: it has to come before the suite step in
# the same job, it cannot carry an `if:` or a `continue-on-error:` that lets
# it skip or fail quietly, and its body has to run the install on a straight
# path. Any of those leaves test-shell-syntax.sh's pass skipped in exactly the
# job whose green the checkbox points at. test-ci-workflows.sh asserts this for
# the three workflows it names; discovering the jobs here is what keeps the
# template's sentence true when a fourth starts running the suite.
#
# "A straight path" is decided by reading the body line by line: every line
# has to be one of three shapes -- the index refresh, the install itself, the
# version print -- and one of them has to be the install. Finding the install
# on a line of its own is not enough: `if false; then` above it and `fi` below
# leave it never run, `|| true` on it installs nothing on failure, and an echo
# of it installs nothing at all. None of those lines has an accepted shape, so
# each fails here. A step that needs another line changes this list in the
# open. GitHub runs the step under bash -e (checked below), so a failing
# install is a failing step.
INSTALL_STEP_LINES=(
    '^(sudo )?apt-get update$'
    '^(sudo )?apt-get install -y shellcheck( [A-Za-z0-9._+-]+)*$'
    '^shellcheck --version$'
)
install_is_straight() {
    local body=$1 line shape matched installs=0
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -n "${line}" ]] || continue
        matched=0
        for shape in "${INSTALL_STEP_LINES[@]}"; do
            if [[ "${line}" =~ ${shape} ]]; then
                matched=1
                break
            fi
        done
        [[ "${matched}" -eq 1 ]] || return 1
        if [[ "${line}" =~ ${INSTALL_STEP_LINES[1]} ]]; then
            installs=1
        fi
    done <<<"${body}"
    [[ "${installs}" -eq 1 ]]
}

# The rule is only as good as these cases.
assert_eq "install_is_straight accepts the refresh, install and version print" "0" \
    "$(install_is_straight $'sudo apt-get update\nsudo apt-get install -y shellcheck python3-yaml\nshellcheck --version'; echo $?)"
assert_eq "install_is_straight accepts the bare install" "0" \
    "$(install_is_straight 'apt-get install -y shellcheck'; echo $?)"
assert_eq "install_is_straight rejects || true on the install" "1" \
    "$(install_is_straight 'sudo apt-get install -y shellcheck || true'; echo $?)"
assert_eq "install_is_straight rejects an install inside if false; then ... fi" "1" \
    "$(install_is_straight $'if false; then\n  sudo apt-get install -y shellcheck\nfi'; echo $?)"
assert_eq "install_is_straight rejects an echo of the install" "1" \
    "$(install_is_straight 'echo sudo apt-get install -y shellcheck'; echo $?)"
assert_eq "install_is_straight rejects a body with no install in it" "1" \
    "$(install_is_straight $'sudo apt-get update\nshellcheck --version'; echo $?)"

while IFS= read -r step; do
    [[ -n "${step}" ]] || continue
    wf="$(field file "${step}")"
    job="$(field job "${step}")"
    suite_position="$(field position "${step}")"
    label="${wf}: job '${job}'"
    # shellcheck disable=SC2016 # $wf and $job are jq variables, bound by --arg
    install="$(steps_where '.file == $wf and .job == $job and (.run | contains("apt-get install -y shellcheck"))' \
        --arg wf "${wf}" --arg job "${job}" | head -1)"
    if [[ -z "${install}" ]]; then
        _fail "${label} installs shellcheck before running the suite, as the template says CI does" \
            "no step in this job runs apt-get install -y shellcheck" \
            "the shellcheck pass would skip silently and the job would still be green"
        continue
    fi
    install_name="$(field name "${install}")"
    install_position="$(field position "${install}")"
    if [[ "${install_position}" -lt "${suite_position}" ]]; then
        _pass "${label} installs shellcheck before running the suite, as the template says CI does"
    else
        _fail "${label} installs shellcheck before running the suite, as the template says CI does" \
            "'${install_name}' is step ${install_position}; the suite is step ${suite_position}"
    fi
    runs_unconditionally "${label}: '${install_name}'" "${install}"
    runs_under_bash_e "${label}: '${install_name}'" "${install}"
    if install_is_straight "$(field run "${install}")"; then
        _pass "${label}: '${install_name}' runs the install on a straight path"
    else
        _fail "${label}: '${install_name}' runs the install on a straight path" \
            "every line has to be apt-get update, the install, or shellcheck --version, and one the install;" \
            "control flow, a '|| true', or an echo around the install leaves it not run"
    fi
done <<<"${suite_steps}"

# --- 4. the documents a contributor is told are load-bearing ----------------

require_claim "README.md and AGENTS.md are incident-response inputs" \
    'README.md and AGENTS.md are load-bearing incident-response inputs'

# Where that status is actually recorded. docs/risk-tiers.md is the file that
# assigns it, so the template is repeating a decision rather than making one.
risk_tier_row="$(grep -F 'Load-bearing prose' "${RISK_TIERS}" | head -1)"
require_nonempty "docs/risk-tiers.md's load-bearing prose row" "${risk_tier_row}"
# shellcheck disable=SC2016
assert_contains "docs/risk-tiers.md still puts README.md in that tier" \
    "${risk_tier_row}" '`README.md`'
# shellcheck disable=SC2016
assert_contains "docs/risk-tiers.md still puts AGENTS.md in that tier" \
    "${risk_tier_row}" '`AGENTS.md`'
assert_contains "and still says a wrong change there misleads a reader mid-incident" \
    "${risk_tier_row}" 'misleads a human or an agent mid-incident'

# --- 5. the build scripts the shell suite cannot reach ----------------------

# shellcheck disable=SC2016
require_claim "which files only run inside a full image build" \
    '`build_files/build.sh`, `build_files/kernel-akmods.sh`, `build_files/zfs.sh` and the `Containerfile` only really run inside a full image build, which the shell suite cannot reach.'
# shellcheck disable=SC2016
require_claim "that post-check.sh is the exception" \
    '(`post-check.sh` has sourceable helpers.)'

# The manifest in test-coverage.sh is where the decision is recorded: every
# shipped script is either covered by a named test or UNCOVERED with a reason.
# Its fields are tab-separated and read with awk, whose -F takes a literal tab
# everywhere; a `\t` in a grep pattern needs GNU grep's -P, which nothing else
# in the suite requires.
manifest_uncovered="$(awk -F'\t' '$2 == "UNCOVERED" { print $1 }' "${COVERAGE_TEST}" | as_set)"
require_nonempty "UNCOVERED entries in test-coverage.sh's manifest" "${manifest_uncovered}"

# shellcheck disable=SC2016
template_build_scripts="$(grep -oE '`build_files/[a-z0-9-]+\.sh`' "${TEMPLATE}" |
    tr -d '`' | as_set)"
require_nonempty "build_files scripts named by ${TEMPLATE_REL}" "${template_build_scripts}"

# Both directions in one comparison: a script that gains a test and stays in the
# template fails, and a fourth uncovered script the template does not name fails.
assert_eq "the scripts the template calls unreachable are exactly the UNCOVERED ones" \
    "${manifest_uncovered}" "${template_build_scripts}"

manifest_post_check="$(awk -F'\t' '$1 == "build_files/post-check.sh" { print $2 }' "${COVERAGE_TEST}")"
assert_eq "post-check.sh is covered by the test the manifest names" \
    "tests/test-post-check.sh" "${manifest_post_check}"
# shellcheck disable=SC2016 # the guard is matched as text, not expanded
assert_contains "post-check.sh still has the BASH_SOURCE guard that makes sourcing it safe" \
    "$(cat "${POST_CHECK}")" 'if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then'

# "only really run inside a full image build" is a claim about the Containerfile
# too: each of those scripts has to be invoked by it.
containerfile_body="$(cat "${CONTAINERFILE}")"
for script in ${template_build_scripts}; do
    assert_contains "the Containerfile runs ${script} inside the image build" \
        "${containerfile_body}" "/ctx/$(basename "${script}")"
done

# --- 6. what a pull request build is, and is not ----------------------------

# shellcheck disable=SC2016
require_claim "a green build on the pull request is the evidence to point at" \
    'A green `Build container image` run on this PR is the strongest evidence.'
require_claim "that a pull request build publishes and signs nothing" \
    'Note that it does not publish or sign anything from a PR.'

BUILD_WF_NAME="$(basename "${BUILD_WF}")"
named_build_wf=""
for wf_path in "${WORKFLOW_FILES[@]}"; do
    if [[ "$(jq -r '.name // ""' "${JSON_DIR}/$(basename "${wf_path}").json")" == "Build container image" ]]; then
        named_build_wf+="$(basename "${wf_path}") "
    fi
done
assert_eq "exactly one workflow is named the way the template names it" \
    "${BUILD_WF_NAME}" "$(as_set <<<"${named_build_wf}")"

if jq -e '.on | objects | has("pull_request")' "${JSON_DIR}/${BUILD_WF_NAME}.json" >/dev/null; then
    _pass "build.yml still triggers on pull_request, so there is a run to point at"
else
    _fail "build.yml still triggers on pull_request, so there is a run to point at" \
        "the template tells a contributor a run on this PR is the strongest evidence"
fi

# "It does not publish or sign anything from a PR" is a claim about every
# step of build.yml, so every step of build.yml gets a decision recorded here,
# the way test-coverage.sh records one per shipped script: either the step is
# safe to run on a pull request, or it is guarded. A step this manifest does
# not name fails, so a new push, copy or sign step -- by whatever mechanism,
# `podman push` as much as the push-to-registry action -- cannot arrive
# without being classified in the open; a manifest row with no step fails, so
# the list cannot rot after a rename or a removal.
#
# The two classifications are checked differently. A GUARDED step's `if:` has
# to exclude pull requests (below). A PR_SAFE step's action and body have to
# be free of the publish and sign mechanisms this repository knows: a safe
# step that grows a push is reclassified, not waved through.
PUBLISH_MANIFEST=$(
    cat <<'EOF'
tests	Checkout	PR_SAFE
tests	Install shellcheck	PR_SAFE
tests	Run shell test suite	PR_SAFE
build_push	Prepare environment	PR_SAFE
build_push	Checkout	PR_SAFE
build_push	Maximize build space	PR_SAFE
build_push	Update Podman	PR_SAFE
build_push	Move container storage to the large runner disk	PR_SAFE
build_push	Get current date	PR_SAFE
build_push	Image Metadata	PR_SAFE
build_push	Build Image	PR_SAFE
build_push	Rechunk Image with Chunkah	PR_SAFE
build_push	Login to GitHub Container Registry	GUARDED
build_push	Push To GHCR	GUARDED
build_push	Propagate tags from the pushed digest	GUARDED
build_push	Verify pushed tags share one digest	GUARDED
build_push	Install Cosign	GUARDED
build_push	Sign container image	GUARDED
EOF
)

# What a step that publishes or signs looks like: the actions that log in,
# push or install a signer, and the commands that push, copy or sign. The
# patterns are matched against the `uses:` reference and every line of the
# `run:` body, and a PR_SAFE step may match none of them.
PUBLISH_USES=(
    'push-to-registry'
    'login-action'
    'build-push-action'
    'cosign-installer'
    'sigstore/'
)
PUBLISH_COMMANDS=(
    '(^|[^A-Za-z0-9_-])(podman|buildah|docker|crane|oras) +(manifest +)?push([^A-Za-z0-9_-]|$)'
    '(^|[^A-Za-z0-9_-])skopeo +copy([^A-Za-z0-9_-]|$)'
    '(^|[^A-Za-z0-9_-])(podman|docker|buildah|skopeo) +login([^A-Za-z0-9_-]|$)'
    '(^|[^A-Za-z0-9_-])cosign +(sign|attest|attach)([^A-Za-z0-9_-]|$)'
    '(^|[^A-Za-z0-9_-])gh +release([^A-Za-z0-9_-]|$)'
)
publishes() {
    local step=$1 uses run pattern
    uses="$(field uses "${step}")"
    run="$(field run "${step}")"
    for pattern in "${PUBLISH_USES[@]}"; do
        [[ "${uses}" == *"${pattern}"* ]] && return 0
    done
    for pattern in "${PUBLISH_COMMANDS[@]}"; do
        grep -qE "${pattern}" <<<"${run}" && return 0
    done
    return 1
}

# The condition is judged whole, not searched for the guard's text: the guard
# followed by `|| github.event_name == 'pull_request'` contains it and runs on
# every pull request, and so does `!(false && guard)`. A condition excludes
# pull requests when it has no `||` at all -- so it is one `&&` chain, false
# as soon as any operand is -- no `!` other than the guard's own `!=`, so
# nothing in it is negated, every operand carries balanced parentheses, so no
# operand is a fragment of a group spanning the `&&` beside it, and the guard
# is one of those operands, whole. A safe form this rule cannot read, such as
# `(guard) && x`, fails here and is written in the accepted form instead.
PR_GUARD="github.event_name != 'pull_request'"
excludes_pull_requests() {
    local condition operand opens closes found=0
    condition="$(tr -s '[:space:]' ' ' <<<"$1")"
    condition="${condition# }"
    condition="${condition% }"
    condition="${condition#\$\{\{}"
    condition="${condition%\}\}}"
    condition="${condition# }"
    condition="${condition% }"
    [[ -n "${condition}" && "${condition}" != *"||"* ]] || return 1
    [[ "${condition//!=/}" != *"!"* ]] || return 1
    while IFS= read -r operand; do
        opens="${operand//[^(]/}"
        closes="${operand//[^)]/}"
        [[ "${#opens}" -eq "${#closes}" ]] || return 1
        [[ "${operand}" == "${PR_GUARD}" ]] && found=1
    done <<<"${condition// && /$'\n'}"
    [[ "${found}" -eq 1 ]]
}

# The rules are only as good as these cases.
assert_eq "excludes_pull_requests accepts the guard alone" "0" \
    "$(excludes_pull_requests "${PR_GUARD}"; echo $?)"
assert_eq "excludes_pull_requests accepts the guard and a second operand" "0" \
    "$(excludes_pull_requests "${PR_GUARD} && github.ref == format('refs/heads/{0}', github.event.repository.default_branch)"; echo $?)"
assert_eq "excludes_pull_requests accepts the guard as the second operand" "0" \
    "$(excludes_pull_requests "github.ref == 'refs/heads/main' && ${PR_GUARD}"; echo $?)"
assert_eq "excludes_pull_requests accepts the guard inside \${{ }}" "0" \
    "$(excludes_pull_requests "\${{ ${PR_GUARD} && x }}"; echo $?)"
assert_eq "excludes_pull_requests rejects a guard undone by ||" "1" \
    "$(excludes_pull_requests "${PR_GUARD} && x || github.event_name == 'pull_request'"; echo $?)"
assert_eq "excludes_pull_requests rejects a negated guard" "1" \
    "$(excludes_pull_requests "!(${PR_GUARD})"; echo $?)"
assert_eq "excludes_pull_requests rejects a negation around the whole chain" "1" \
    "$(excludes_pull_requests "\${{ !(false && ${PR_GUARD} && true) }}"; echo $?)"
assert_eq "excludes_pull_requests rejects a guard regrouped by parentheses" "1" \
    "$(excludes_pull_requests "(x && ${PR_GUARD}) == false"; echo $?)"
assert_eq "excludes_pull_requests rejects no condition at all" "1" \
    "$(excludes_pull_requests ""; echo $?)"
assert_eq "publishes sees a push action" "0" \
    "$(publishes '{"uses":"redhat-actions/push-to-registry@v2","run":""}'; echo $?)"
assert_eq "publishes sees a podman push inside a run body" "0" \
    "$(publishes '{"uses":"","run":"set -e\npodman push localhost/x ghcr.io/x"}'; echo $?)"
assert_eq "publishes sees a cosign sign" "0" \
    "$(publishes '{"uses":"","run":"cosign sign -y x"}'; echo $?)"
assert_eq "publishes does not mistake podman tag, load or inspect for a push" "1" \
    "$(publishes '{"uses":"","run":"podman tag a b\npodman load -i x\npodman inspect --format x y\npodman image prune -af"}'; echo $?)"
assert_eq "publishes does not mistake a build action for a push" "1" \
    "$(publishes '{"uses":"redhat-actions/buildah-build@v2","run":""}'; echo $?)"

# shellcheck disable=SC2016 # $file is a jq variable, bound by --arg
build_steps="$(steps_where '.file == $file' --arg file "${BUILD_WF_NAME}")"
require_nonempty "steps in build.yml" "${build_steps}"

# Every step has a decision, and every decision has a step.
manifest_keys="$(cut -f1,2 <<<"${PUBLISH_MANIFEST}" | LC_ALL=C sort)"
step_keys="$(jq -r '[.job, .name] | @tsv' <<<"${build_steps}" | LC_ALL=C sort)"
assert_eq "no step in build.yml is unnamed, so each can be classified" \
    "" "$(grep -F '<unnamed>' <<<"${step_keys}" || true)"
assert_eq "no job in build.yml names two steps alike, so each classification is unambiguous" \
    "" "$(uniq -d <<<"${step_keys}")"
while IFS=$'\t' read -r job name; do
    [[ -n "${job}" ]] || continue
    if grep -qxF "${job}	${name}" <<<"${manifest_keys}"; then
        _pass "build.yml: '${name}' in job '${job}' is classified"
    else
        _fail "build.yml: '${name}' in job '${job}' is classified" \
            "add it to PUBLISH_MANIFEST in tests/test-pull-request-template.sh" \
            "as PR_SAFE (it publishes and signs nothing) or GUARDED (it carries the pull_request guard)"
    fi
done <<<"${step_keys}"

while IFS=$'\t' read -r job name classification; do
    [[ -n "${job}" ]] || continue
    # shellcheck disable=SC2016 # $file, $job and $name are jq variables, bound by --arg
    step="$(steps_where '.file == $file and .job == $job and .name == $name' \
        --arg file "${BUILD_WF_NAME}" --arg job "${job}" --arg name "${name}" | head -1)"
    if [[ -z "${step}" ]]; then
        _fail "build.yml still has '${name}' in job '${job}'" \
            "no such step; remove the stale PUBLISH_MANIFEST row or update its name"
        continue
    fi
    case "${classification}" in
    GUARDED)
        condition="$(field if "${step}")"
        if excludes_pull_requests "${condition}"; then
            _pass "build.yml: '${name}' does not run from a pull request"
        else
            _fail "build.yml: '${name}' does not run from a pull request" \
                "if: ${condition:-<none>}" \
                "expected one && chain with '${PR_GUARD}' as a whole operand, no || and no negation"
        fi
        ;;
    PR_SAFE)
        if publishes "${step}"; then
            _fail "build.yml: '${name}' publishes and signs nothing, as its PR_SAFE row says" \
                "its action or body carries a push, copy, login or sign mechanism;" \
                "reclassify it GUARDED and guard it, or take the publish out"
        else
            _pass "build.yml: '${name}' publishes and signs nothing, as its PR_SAFE row says"
        fi
        ;;
    *)
        _fail "PUBLISH_MANIFEST classifies '${name}' as PR_SAFE or GUARDED" \
            "found: ${classification}"
        ;;
    esac
done <<<"${PUBLISH_MANIFEST}"

# Steps are not the only shape a publish can arrive in. A job with a
# job-level `uses:` calls a reusable workflow: it has no steps of its own, so
# the manifest above never reaches it, while the call can carry
# `permissions: packages: write` and `secrets: inherit` and push from a pull
# request. So the jobs are classified too, the same way, both directions.
#
# STEPS is a job whose own steps the manifest above decides -- it must have
# steps and no job-level `uses:`. GUARDED is a reusable-workflow call that
# cannot run from a pull request: what the called workflow does is not
# readable here (it may live in another repository, behind a ref that moves),
# so the guard on the call is the whole claim, and it is read by the same
# rule as a step's. A job that is neither -- a call classified STEPS, a call
# with no guard, a job with neither steps nor a `uses:` -- fails.
JOB_MANIFEST=$(
    cat <<'EOF'
tests	STEPS
build_push	STEPS
EOF
)

build_jobs="$(jobs_of "${BUILD_WF}")"
require_nonempty "jobs in build.yml" "${build_jobs}"

# Both directions in one comparison: a new job fails until it is classified,
# and a row left behind by a rename or a removal fails too.
assert_eq "the jobs JOB_MANIFEST classifies are exactly the jobs build.yml has" \
    "$(cut -f1 <<<"${JOB_MANIFEST}" | LC_ALL=C sort)" \
    "$(jq -r '.job' <<<"${build_jobs}" | LC_ALL=C sort)"

while IFS=$'\t' read -r job classification; do
    [[ -n "${job}" ]] || continue
    # shellcheck disable=SC2016 # $job is a jq variable, bound by --arg
    entry="$(jq -c --arg job "${job}" 'select(.job == $job)' <<<"${build_jobs}" | head -1)"
    # A row with no job is already a failure of the comparison above.
    [[ -n "${entry}" ]] || continue
    job_uses="$(field uses "${entry}")"
    job_steps="$(field step_count "${entry}")"
    job_condition="$(field if "${entry}")"
    case "${classification}" in
    STEPS)
        if [[ -z "${job_uses}" && "${job_steps}" -gt 0 ]]; then
            _pass "build.yml: job '${job}' runs steps of its own, as its STEPS row says"
        else
            _fail "build.yml: job '${job}' runs steps of its own, as its STEPS row says" \
                "uses: ${job_uses:-<none>}, steps: ${job_steps}" \
                "a job that calls a reusable workflow has no steps for PUBLISH_MANIFEST to classify;" \
                "reclassify it GUARDED and guard the call"
        fi
        ;;
    GUARDED)
        if [[ -z "${job_uses}" ]]; then
            _fail "build.yml: job '${job}' calls a reusable workflow, as its GUARDED row says" \
                "no job-level uses:; classify it STEPS so PUBLISH_MANIFEST reads its steps"
        elif excludes_pull_requests "${job_condition}"; then
            _pass "build.yml: job '${job}' does not run from a pull request"
        else
            _fail "build.yml: job '${job}' does not run from a pull request" \
                "if: ${job_condition:-<none>}" \
                "expected one && chain with '${PR_GUARD}' as a whole operand, no || and no negation"
        fi
        ;;
    *)
        _fail "JOB_MANIFEST classifies '${job}' as STEPS or GUARDED" \
            "found: ${classification}"
        ;;
    esac
done <<<"${JOB_MANIFEST}"

# --- 7. the diagnosis the template sends a reviewer to ----------------------

require_claim "a reviewer should link AGENTS.md's skew diagnosis" \
    "than this change, say so and link AGENTS.md's diagnosis."

agents_slugs="$(heading_slugs "${AGENTS}" | as_set)"
require_nonempty "headings in AGENTS.md" "${agents_slugs}"
for required_heading in dominant-failure-mode-kernel--zfs-akmod-skew 60-second-diagnosis; do
    if [[ " ${agents_slugs} " == *" ${required_heading} "* ]]; then
        _pass "AGENTS.md still has the '${required_heading}' section to link"
    else
        _fail "AGENTS.md still has the '${required_heading}' section to link" \
            "the template sends a reviewer with a red build there" \
            "headings found: ${agents_slugs}"
    fi
done

# --- 8. the paths the template names in code spans --------------------------

# test-docs-paths.sh's second pass does this for README.md and AGENTS.md only.
# The same failure -- a renamed file leaving a document pointing at nothing --
# is what the template's image-build section is made of.
spans_checked=0
# shellcheck disable=SC2016
while IFS= read -r span; do
    [[ -n "${span}" ]] || continue
    candidate="${span#./}"
    if [[ "${candidate}" == */* ]]; then
        if (cd "${REPO_ROOT}" && git ls-files --error-unmatch "${candidate}" >/dev/null 2>&1); then
            _pass "${TEMPLATE_REL} names an existing path: ${span}"
        else
            _fail "${TEMPLATE_REL} names an existing path: ${span}" \
                "no tracked file at ${candidate}"
        fi
    else
        matches="$(cd "${REPO_ROOT}" && git ls-files | grep -cE "(^|/)${candidate}$")"
        if [[ "${matches}" -ge 1 ]]; then
            _pass "${TEMPLATE_REL} names an existing file: ${span}"
        else
            _fail "${TEMPLATE_REL} names an existing file: ${span}" \
                "no tracked file is named ${candidate}"
        fi
    fi
    spans_checked=$((spans_checked + 1))
done < <(outside_fences "${TEMPLATE}" |
    grep -oE '`[^` ]+`' | tr -d '`' |
    grep -E '(^|/)[A-Za-z0-9._-]+\.(sh|md|yml|json)$|^\.?/?Containerfile$|/' |
    sort -u)

if [[ "${spans_checked}" -gt 0 ]]; then
    _pass "${TEMPLATE_REL} yielded ${spans_checked} path reference(s) to check"
else
    _fail "${TEMPLATE_REL} yielded path references to check" \
        "the filter matched nothing, so this pass verified nothing"
fi

finish
