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

# The block of one `- name:` step in a workflow file: from the step that
# contains ${needle} up to the next step at the same indent. `if:` lives inside
# that block, so a guard that moved to a different step is not counted here.
step_block() {
    local file=$1 needle=$2
    awk -v needle="${needle}" '
        /^[[:space:]]+- (name|uses):/ { if (found) exit; buf = ""; collecting = 1 }
        collecting { buf = buf $0 "\n"; if (index($0, needle)) found = 1 }
        END { if (found) printf "%s", buf }
    ' "${file}"
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

# Both directions: every workflow that runs the suite runs it under the name the
# template gives, and at least one does, so a rename cannot pass vacuously.
suite_workflows="$(cd "${WORKFLOW_DIR}" &&
    grep -lE '^[[:space:]]+run:[[:space:]]*\./tests/run-tests\.sh[[:space:]]*$' ./*.yml |
    sed 's|^\./||' | as_set)"
require_nonempty "workflow steps that run the shell suite" "${suite_workflows}"

# A `run:` step that reaches the suite by any other spelling -- an argument, a
# `|| true`, a wrapper -- is a workflow whose green does not mean what the
# checkbox says it means, so the loose match and the exact one have to agree.
loose_suite_workflows="$(cd "${WORKFLOW_DIR}" &&
    grep -lE '^[[:space:]]+run:.*run-tests\.sh' ./*.yml | sed 's|^\./||' | as_set)"
assert_eq "every workflow step that reaches the suite runs it as the template writes it" \
    "${loose_suite_workflows}" "${suite_workflows}"

# --- 3. the shellcheck caveat -----------------------------------------------

require_claim "the shellcheck pass is skipped when the tool is absent" \
    'so its pass was enforced and not skipped (CI installs it; a developer machine may not have it)'

syntax_test_body="$(cat "${SYNTAX_TEST}")"
assert_contains "test-shell-syntax.sh gates its shellcheck pass on the tool being present" \
    "${syntax_test_body}" 'if command -v shellcheck >/dev/null 2>&1; then'
assert_contains "and says so rather than failing when it is not" \
    "${syntax_test_body}" 'skip shellcheck (not installed)'

# "CI installs it" is a claim about every job that runs the suite, not about one
# of them. test-ci-workflows.sh asserts this for the three workflows it names;
# discovering them here is what keeps the template's sentence true when a fourth
# workflow starts running the suite.
for wf in ${suite_workflows}; do
    if grep -q 'apt-get install -y shellcheck' "${WORKFLOW_DIR}/${wf}"; then
        _pass "${wf} installs shellcheck, as the template says CI does"
    else
        _fail "${wf} installs shellcheck, as the template says CI does" \
            "it runs ./tests/run-tests.sh with no shellcheck install in the file" \
            "the shellcheck pass would skip silently and the job would still be green"
    fi
done

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
manifest_uncovered="$(grep -P '\tUNCOVERED\t' "${COVERAGE_TEST}" | cut -f1 | as_set)"
require_nonempty "UNCOVERED entries in test-coverage.sh's manifest" "${manifest_uncovered}"

# shellcheck disable=SC2016
template_build_scripts="$(grep -oE '`build_files/[a-z0-9-]+\.sh`' "${TEMPLATE}" |
    tr -d '`' | as_set)"
require_nonempty "build_files scripts named by ${TEMPLATE_REL}" "${template_build_scripts}"

# Both directions in one comparison: a script that gains a test and stays in the
# template fails, and a fourth uncovered script the template does not name fails.
assert_eq "the scripts the template calls unreachable are exactly the UNCOVERED ones" \
    "${manifest_uncovered}" "${template_build_scripts}"

manifest_post_check="$(grep -P '^build_files/post-check\.sh\t' "${COVERAGE_TEST}" | cut -f2)"
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

named_build_wf="$(cd "${WORKFLOW_DIR}" &&
    grep -lE "^name: Build container image[[:space:]]*$" ./*.yml | sed 's|^\./||' | as_set)"
assert_eq "exactly one workflow is named the way the template names it" \
    "build.yml" "${named_build_wf}"

build_wf_body="$(cat "${BUILD_WF}")"
if awk '/^on:/ { in_on = 1; next } /^[a-z]/ { in_on = 0 } in_on && /^  pull_request:/ { found = 1 }
        END { exit !found }' "${BUILD_WF}"; then
    _pass "build.yml still triggers on pull_request, so there is a run to point at"
else
    _fail "build.yml still triggers on pull_request, so there is a run to point at" \
        "the template tells a contributor a run on this PR is the strongest evidence"
fi

# Every step that publishes or signs has to carry the guard. The markers are the
# actions and commands themselves, not the step names, so renaming a step does
# not slip one past this list.
PR_GUARD="github.event_name != 'pull_request'"
for marker in \
    'docker/login-action' \
    'redhat-actions/push-to-registry' \
    'Propagate tags from the pushed digest' \
    'Verify pushed tags share one digest' \
    'sigstore/cosign-installer' \
    'cosign sign -y --key env://COSIGN_PRIVATE_KEY'; do
    if [[ "${build_wf_body}" != *"${marker}"* ]]; then
        _fail "build.yml still has the step containing '${marker}'" \
            "if the publish band changed shape, this list must be updated with it"
        continue
    fi
    block="$(step_block "${BUILD_WF}" "${marker}")"
    if require_nonempty "a step block around '${marker}'" "${block}"; then
        assert_contains "'${marker}' does not run from a pull request" \
            "${block}" "${PR_GUARD}"
    fi
done

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
