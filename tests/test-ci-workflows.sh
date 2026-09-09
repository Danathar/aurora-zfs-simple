#!/usr/bin/env bash
#
# Asserts that CI still runs the shell suite, and that nothing it gates has
# quietly stopped being gated.
#
# Every host-side guarantee this repo makes rests on five facts about
# .github/workflows/, and until this file none of them was checked by anything:
#
#   1. build.yml's `Shell tests` job runs ./tests/run-tests.sh
#   2. coverage-gate.yml runs the same suite on the complement of build.yml's
#      paths-ignore, so a docs-only change is verified by something
#   3. both jobs install shellcheck *before* running the suite, which is what
#      makes test-shell-syntax.sh's shellcheck pass enforced rather than
#      skipped (that test skips it when the tool is absent, by design)
#   4. build_push has `needs: tests`, so a red suite blocks the image build
#   5. every action any workflow uses names immutable code, so nothing running
#      beside `packages: write` and the signing key can change after review
#
# Delete the tests job, drop `needs: tests`, drop the shellcheck install, or add
# a path to paths-ignore without adding it to coverage-gate.yml, and the suite
# stays green while the gate stops gating. test-coverage.sh does not catch it:
# it asserts a coverage *decision* exists for every shipped script, not that the
# decision is enforced anywhere.
#
# The path filters are the sharp case. A workflow that stops running is not a
# workflow that fails — the run that would have gone red is the run that no
# longer starts — so a paths-ignore that grows a third entry produces a green CI
# result on the very change that stopped covering that path.
#
# Only one direction of the path relation is asserted: every path build.yml
# ignores must appear in coverage-gate.yml for the same event. The reverse does
# not hold and should not. coverage-gate.yml also triggers on '**/README.md',
# which build.yml ignores on push but not on pull_request, so a pull request
# touching only tests/README.md runs the suite twice. Both workflows' comments
# call that trade deliberate, so the assertion is a superset check rather than
# equality.
#
# What runs this test matters as much as what it asserts. A `pull_request` run
# executes the *head* branch's copy of a workflow file — measured on this repo
# and written up in docs/SECURITY-AI.md — so a pull request that deletes the
# `Shell tests` job from build.yml is checked by the build.yml that no longer
# has it. The suite that would have gone red is the suite that no longer runs,
# and build_push proceeds. A test living inside the workflow it polices cannot
# close that on its own.
#
# So coverage-gate.yml triggers on '.github/workflows/**' as well, and this file
# asserts that it does. Any workflow edit is then checked by a workflow the pull
# request did not touch, and the two files police each other: build.yml runs the
# suite on a change to coverage-gate.yml, and coverage-gate.yml runs it on a
# change to build.yml. Disabling the gate takes an edit to both in one pull
# request rather than one line in one file. The last step — making that
# impossible rather than merely conspicuous — is a required status check in
# branch protection, which no file in the tree can assert.
#
# The topology checks below use indentation-anchored extractors, with known
# fixture answers and nonempty-result assertions. The expression check in
# section 6 uses PyYAML: quoted continuations, aliases and escaped characters
# must have the same meaning here that they have when Actions reads the file.

set -uo pipefail

TEST_NAME="test-ci-workflows"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

BUILD_WF="${REPO_ROOT}/.github/workflows/build.yml"
COVERAGE_WF="${REPO_ROOT}/.github/workflows/coverage-gate.yml"
BADGES_WF="${REPO_ROOT}/.github/workflows/status-badges.yml"
NIGHTLY_WF="${REPO_ROOT}/.github/workflows/nightly-compliance.yml"
WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"

# This check guards a security invariant; a missing parser must fail, including
# when this test is invoked directly instead of through run-tests.sh.
if ! "${WORKFLOW_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    _fail "the workflow checker requires Python 3 with PyYAML" \
        "install python3-yaml (Debian/Ubuntu) or python3-pyyaml (Fedora)," \
        "or install PyYAML in the interpreter selected by WORKFLOW_PYTHON"
    finish
    exit 1
fi

# --- parser -----------------------------------------------------------------
#
# Two extractors, both anchored on indentation. The workflows are written with
# two-space indents throughout, so an event key sits at column 2, its `paths:`
# style keys at column 4, and their list items at column 6.

# event_paths <file> <event> <key>
#
# Prints one path per line from `on: <event>: <key>:`. Quotes are stripped;
# order is preserved.
event_paths() {
    local file=$1 event=$2 key=$3
    awk -v event="${event}" -v key="${key}" '
        # Top-level "on:" opens the trigger block; any other column-0 key ends it.
        # YAML ignores comment indentation, so a comment must never look like a
        # structural key. build.yml has comment blocks at two spaces, exactly
        # where an event name sits.
        /^[[:space:]]*#/    { next }
        /^on:[[:space:]]*$/ { in_on = 1; next }
        /^[^[:space:]#]/    { in_on = 0 }

        !in_on { next }

        # A column-2 key is an event name: enter the one we were asked for,
        # and leave whichever we were in.
        /^  [^[:space:]]/ {
            in_event = ($0 ~ "^  " event ":[[:space:]]*$")
            in_key = 0
            next
        }

        !in_event { next }

        # A column-4 key under that event, likewise.
        /^    [^[:space:]]/ {
            in_key = ($0 ~ "^    " key ":[[:space:]]*$")
            next
        }

        # A column-6 list item under the key we want.
        in_key && /^      - / {
            line = $0
            sub(/^      - /, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            sub(/[[:space:]]+#.*$/, "", line)
            print line
        }
    ' "${file}"
}

# event_has_key <file> <event> <key>
#
# True if `on: <event>:` declares <key> at all, in any YAML style. event_paths
# reads block sequences only, so an inline `types: [closed]` extracts nothing
# and is indistinguishable from an absent key — which matters wherever *absence*
# is the passing condition.
event_has_key() {
    local file=$1 event=$2 key=$3
    awk -v event="${event}" -v key="${key}" '
        # YAML ignores comment indentation, so a comment must never look like a
        # structural key. build.yml has comment blocks at two spaces, exactly
        # where an event name sits.
        /^[[:space:]]*#/    { next }
        /^on:[[:space:]]*$/ { in_on = 1; next }
        /^[^[:space:]#]/    { in_on = 0 }
        !in_on { next }
        /^  [^[:space:]]/ {
            in_event = ($0 ~ "^  " event ":[[:space:]]*$")
            next
        }
        # Quoted keys are valid YAML and mean the same thing. This matters here
        # and not in event_paths, because absence is the passing condition: a
        # spelling this cannot see reads as "not declared". The single quote is
        # written as \047 because this awk program is inside a single-quoted
        # shell string, where a literal one would end the program early.
        in_event && $0 ~ ("^    [\"\047]?" key "[\"\047]?[[:space:]]*:") { found = 1 }
        END { exit !found }
    ' "${file}"
}

# job_block <file> <job>
#
# Prints the body of one entry under the top-level `jobs:` key.
job_block() {
    local file=$1 job=$2
    awk -v job="${job}" '
        /^[[:space:]]*#/      { next }
        /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
        /^[^[:space:]#]/      { in_jobs = 0 }

        !in_jobs { next }

        /^  [^[:space:]]/ {
            in_job = ($0 ~ "^  " job ":[[:space:]]*$")
            next
        }

        in_job { print }
    ' "${file}"
}

# --- the parser is tested before it is trusted ------------------------------
#
# An extractor that silently returns nothing would make every assertion below
# pass vacuously, so both are run against a fixture whose answer is known.

fixture=$(mktemp)
trap 'rm -f "${fixture}"' EXIT
cat >"${fixture}" <<'FIXTURE'
---
name: Fixture
on:
  pull_request:
    branches:
      - main
    paths-ignore:
      - 'alpha.md'
      - 'beta/**'
  push:
    branches:
      - main
    paths-ignore:
      - 'gamma.md'
  workflow_dispatch:

jobs:
  first:
    name: First
    steps:
      - name: Marker
        run: ./first-marker.sh
  second:
    needs: first
    steps:
      - name: Marker
        run: ./second-marker.sh
FIXTURE

assert_eq "parser reads a two-item paths-ignore list" \
    "alpha.md beta/**" "$(event_paths "${fixture}" pull_request paths-ignore | tr '\n' ' ' | sed 's/ $//')"
assert_eq "parser keeps events separate" \
    "gamma.md" "$(event_paths "${fixture}" push paths-ignore | tr '\n' ' ' | sed 's/ $//')"
assert_eq "parser returns nothing for an absent key" \
    "" "$(event_paths "${fixture}" pull_request paths)"
assert_contains "parser reads a job body" \
    "$(job_block "${fixture}" first)" "./first-marker.sh"
assert_not_contains "parser stops at the next job" \
    "$(job_block "${fixture}" first)" "./second-marker.sh"
assert_contains "parser reads the second job" \
    "$(job_block "${fixture}" second)" "needs: first"

# --- 1. both workflows run the suite, with shellcheck installed first -------

check_runs_suite() {
    local label=$1 file=$2 job=${3:-tests}
    local block
    block=$(job_block "${file}" "${job}")

    if [[ -z "${block}" ]]; then
        _fail "${label} has a tests job" \
            "no '${job}:' job found under jobs: in ${file#"${REPO_ROOT}"/}" \
            "if the job was renamed, this test must be updated with it"
        return
    fi
    _pass "${label} has a tests job"

    # The value is compared, not searched for. `run: ./tests/run-tests.sh || true`
    # contains the command, passes a substring test and the continue-on-error
    # check, and still returns success from a failing suite. Arguments are
    # refused for the same reason: run-tests.sh takes a subset of the files.
    suite_line=$(grep -E '^[[:space:]]+["'"'"']?run["'"'"']?[[:space:]]*:' <<<"${block}" |
        grep -F 'run-tests.sh' | head -1)
    suite_cmd=${suite_line#*:}
    suite_cmd=${suite_cmd#"${suite_cmd%%[![:space:]]*}"}
    suite_cmd=${suite_cmd%"${suite_cmd##*[![:space:]]}"}
    if [[ "${suite_cmd}" == "./tests/run-tests.sh" ]]; then
        _pass "${label} runs the shell suite"
    else
        _fail "${label} runs the shell suite" \
            "expected the step to run exactly ./tests/run-tests.sh" \
            "found: ${suite_cmd:-<no run: step invoking run-tests.sh>}" \
            "a suffix such as '|| true' returns success from a failing suite;" \
            "an argument runs only part of it"
    fi
    assert_contains "${label} installs shellcheck" "${block}" "apt-get install -y shellcheck"
    assert_contains "${label} installs PyYAML for the workflow checker" \
        "${block}" "apt-get install -y shellcheck python3-yaml"
    assert_contains "${label} uses the Python where apt installs PyYAML" \
        "${block}" "WORKFLOW_PYTHON: /usr/bin/python3"

    # Running the suite is not the same as being gated by it. `continue-on-error`
    # leaves a red suite in a green job, and an `if:` on the step or the job can
    # skip it outright — both leave every assertion above satisfied.
    if grep -qE '^[[:space:]]+["'"'"']?continue-on-error["'"'"']?[[:space:]]*:' <<<"${block}"; then
        _fail "${label}'s tests job fails when the suite fails" \
            "continue-on-error is set somewhere in the job; a red suite would leave it green"
    else
        _pass "${label}'s tests job fails when the suite fails"
    fi

    if grep -qE '^[[:space:]]+["'"'"']?if["'"'"']?[[:space:]]*:' <<<"${block}"; then
        _fail "${label}'s tests job is unconditional" \
            "an if: condition appears in the job; the suite can be skipped without failing" \
            "if the condition is deliberate, update this test to say so"
    else
        _pass "${label}'s tests job is unconditional"
    fi

    # Order matters: installing shellcheck after the suite has run would leave
    # test-shell-syntax.sh's shellcheck pass skipped, and skipping is silent.
    local install_line run_line
    install_line=$(grep -n 'apt-get install -y shellcheck' <<<"${block}" | head -1 | cut -d: -f1)
    run_line=$(grep -n './tests/run-tests.sh' <<<"${block}" | head -1 | cut -d: -f1)
    if [[ -n "${install_line}" && -n "${run_line}" && "${install_line}" -lt "${run_line}" ]]; then
        _pass "${label} installs shellcheck before running the suite"
    else
        _fail "${label} installs shellcheck before running the suite" \
            "install step at line ${install_line:-none}, suite at line ${run_line:-none} (job-relative)"
    fi
}

check_runs_suite "build.yml" "${BUILD_WF}"
check_runs_suite "coverage-gate.yml" "${COVERAGE_WF}"
check_runs_suite "nightly-compliance.yml" "${NIGHTLY_WF}" suite

# --- 2. a red suite still blocks the image build ----------------------------

build_push=$(job_block "${BUILD_WF}" build_push)
if [[ -z "${build_push}" ]]; then
    _fail "build.yml has a build_push job" "no 'build_push:' job found in build.yml"
else
    _pass "build.yml has a build_push job"

    # Parsed rather than substring-matched: "needs: tests" is a prefix of
    # "needs: tests_bypass", and a commented-out line contains it too. Both
    # spellings GitHub accepts are read — a scalar and a list — because the
    # assertion is about the dependency, not about how it is written.
    needs_line=$(grep -m1 -E '^    ["'"'"']?needs["'"'"']?[[:space:]]*:' <<<"${build_push}")
    needs_deps=""
    if [[ -z "${needs_line}" ]]; then
        _fail "build_push needs the tests job" \
            "build_push declares no needs: at all; a red suite would not block the build"
    else
        needs_value=${needs_line#*:}
        needs_value=${needs_value#"${needs_value%%[![:space:]]*}"}
        if [[ -z "${needs_value}" ]]; then
            # Block list: the entries follow on their own lines.
            needs_deps=$(sed -n '/^    ["'"'"']\?needs["'"'"']\?[[:space:]]*:[[:space:]]*$/,/^    [^ ]/p' <<<"${build_push}" |
                sed -nE 's/^      -[[:space:]]+["'"'"']?([A-Za-z0-9_-]+)["'"'"']?[[:space:]]*$/\1/p')
        else
            # Scalar or inline flow list.
            needs_deps=$(tr -d '[]"'"'"'' <<<"${needs_value}" | tr ',' '\n' |
                sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | grep -v '^$')
        fi

        if grep -qxF 'tests' <<<"${needs_deps}"; then
            _pass "build_push needs the tests job"
        else
            _fail "build_push needs the tests job" \
                "parsed dependencies: ${needs_deps//$'\n'/, }" \
                "'tests' is not among them, so a red suite would not block the build"
        fi
    fi

    # `needs:` alone is not a gate. A job-level `if:` — always() being the usual
    # one — makes a job run even when the job it needs failed.
    if grep -qE '^    ["'"'"']?if["'"'"']?[[:space:]]*:' <<<"${build_push}"; then
        _fail "build_push has no job-level if: overriding needs" \
            "a job-level if: can run build_push even when tests failed (e.g. always());" \
            "step-level if: is fine and not what this checks"
    else
        _pass "build_push has no job-level if: overriding needs"
    fi
fi

# --- 3. every path build.yml ignores is covered by coverage-gate.yml --------
#
# Per event, because the two triggers do not ignore the same spellings.

for event in pull_request push; do
    ignored=$(event_paths "${BUILD_WF}" "${event}" paths-ignore)
    covered=$(event_paths "${COVERAGE_WF}" "${event}" paths)

    # GitHub evaluates path patterns in order, and a later '!' pattern removes
    # paths an earlier one matched. The membership check below cannot reason
    # about that: 'docs/**' followed by '!docs/private/**' would still satisfy
    # it while a docs/private-only change is claimed by neither workflow. So a
    # negation is refused outright rather than silently mis-read. If one is ever
    # wanted, this test has to evaluate the ordered set instead.
    if negated=$(grep -- '^!' <<<"${ignored}${covered:+$'\n'}${covered}"); then
        _fail "${event}: path filters use no '!' negation" \
            "found: ${negated//$'\n'/, }" \
            "order-dependent negation makes the membership check below unsound;" \
            "teach this test to evaluate the ordered pattern set before adding one"
        continue
    fi
    _pass "${event}: path filters use no '!' negation"

    if [[ -z "${ignored}" ]]; then
        _fail "build.yml declares paths-ignore on ${event}" \
            "extracted nothing; either the filter was removed (in which case the" \
            "suite now runs on every change and this test should be updated) or" \
            "the parser can no longer follow the file"
        continue
    fi
    _pass "build.yml declares paths-ignore on ${event}"

    if [[ -z "${covered}" ]]; then
        _fail "coverage-gate.yml declares paths on ${event}" \
            "extracted nothing; a docs-only ${event} would be verified by neither workflow"
        continue
    fi
    _pass "coverage-gate.yml declares paths on ${event}"

    # The trigger that makes the two workflows check each other. Without it a
    # pull request editing only build.yml is checked by the build.yml it edited
    # — a pull_request run executes the head branch's copy — so the assertions
    # above would never execute on the change that breaks them.
    if grep -qxF '.github/workflows/**' <<<"${covered}"; then
        _pass "${event}: coverage-gate.yml triggers on workflow changes"
    else
        _fail "${event}: coverage-gate.yml triggers on workflow changes" \
            "without '.github/workflows/**' in its ${event} paths, a pull request" \
            "that removes the suite from build.yml runs only the build.yml it just" \
            "edited, and nothing in this file executes"
    fi

    while IFS= read -r path; do
        [[ -z "${path}" ]] && continue
        if grep -qxF "${path}" <<<"${covered}"; then
            _pass "${event}: '${path}' is ignored by build.yml and picked up by coverage-gate.yml"
        else
            _fail "${event}: '${path}' is ignored by build.yml and picked up by coverage-gate.yml" \
                "build.yml skips it, coverage-gate.yml does not claim it," \
                "so a ${event} touching only that path runs no shell suite at all"
        fi
    done <<<"${ignored}"
done

# --- 4. the filters that decide whether any of the above runs at all --------
#
# Every assertion above reasons about path filters, and none of them notices if
# a workflow stops matching the *branch* or the *activity* instead. The two are
# not interchangeable: point build.yml's pull_request at another branch and it
# no longer runs on pull requests to main, while coverage-gate.yml keeps running
# (the change touches .github/workflows/**, which it triggers on) and every
# assertion here still passes. Merge that and a source-only pull request — one
# touching neither docs nor workflows — runs no suite at all, which is the same
# hole the path checks exist to close, reached by a different door.
#
# 'main' must appear rather than be the whole list: adding a second branch
# widens what is covered and breaks nothing. Removing the filter entirely also
# widens it, but it reads identically to a parser failure here, so it fails and
# says so rather than being guessed at.

check_triggers() {
    local label=$1 file=$2 event
    for event in pull_request push; do
        local branches
        branches=$(event_paths "${file}" "${event}" branches)
        # Ordered negation applies here exactly as it does to paths: `- main`
        # followed by `- '!main'` leaves main excluded, and a membership test
        # sees only the positive entry.
        if negated=$(grep -- '^!' <<<"${branches}"); then
            _fail "${label}: ${event} branch filter uses no '!' negation" \
                "found: ${negated//$'\n'/, }" \
                "GitHub applies these in order, so a later negation can exclude main" \
                "while the membership check below still sees it"
            continue
        fi
        _pass "${label}: ${event} branch filter uses no '!' negation"
        if grep -qxF 'main' <<<"${branches}"; then
            _pass "${label}: ${event} still targets main"
        else
            _fail "${label}: ${event} still targets main" \
                "extracted branches: ${branches//$'\n'/, }" \
                "if the filter was widened or removed on purpose, update this test;" \
                "if it was narrowed, this workflow no longer runs on ${event} to main"
        fi
    done

    # No `types:` means the pull_request defaults — opened, synchronize,
    # reopened — which is what makes the suite run on a pull request and again
    # on every push to it. A narrower list is not necessarily wrong, but it is a
    # decision about when the gate applies, so it should not arrive silently.
    #
    # Tested for key *presence*, not for an empty extraction: `types: [closed]`
    # is valid YAML that event_paths cannot read, and treating that silence as
    # "no types declared" would turn the narrowest possible filter into a pass.
    if event_has_key "${file}" pull_request types; then
        _fail "${label}: pull_request uses the default activity types" \
            "a types: key is declared; confirm 'opened' and 'synchronize' are" \
            "still among them, then update this test"
    else
        _pass "${label}: pull_request uses the default activity types"
    fi
}

check_triggers "build.yml" "${BUILD_WF}"
check_triggers "coverage-gate.yml" "${COVERAGE_WF}"

# --- 5. status-badges.yml still skips pull requests -------------------------
#
# This is why build.yml's tests job exists at all: ci/write-badges.sh is
# executed by no other trigger on a pull request. If Status badges started
# running on PRs, the reasoning in build.yml's comment would be stale — and it
# must not start, because it pushes to the status branch.

badges=$(job_block "${BADGES_WF}" badges)
if [[ -z "${badges}" ]]; then
    _fail "status-badges.yml has a badges job" "no 'badges:' job found in status-badges.yml"
else
    _pass "status-badges.yml has a badges job"

    # The job-level condition is compared, not searched for. Broadening it to
    # `always() || github.event.workflow_run.event != 'pull_request'` still
    # contains the fragment while running the job after pull-request builds —
    # and this job holds contents: write and pushes to the status branch.
    badges_if=$(grep -m1 -E '^    ["'"'"']?if["'"'"']?[[:space:]]*:' <<<"${badges}")
    badges_cond=${badges_if#*:}
    badges_cond=${badges_cond#"${badges_cond%%[![:space:]]*}"}
    badges_cond=${badges_cond%"${badges_cond##*[![:space:]]}"}
    if [[ "${badges_cond}" == "github.event.workflow_run.event != 'pull_request'" ]]; then
        _pass "status-badges.yml still skips pull requests"
    else
        _fail "status-badges.yml still skips pull requests" \
            "expected exactly: github.event.workflow_run.event != 'pull_request'" \
            "found: ${badges_cond:-<no job-level if:>}" \
            "build.yml's tests job documents this skip as the reason it runs" \
            "write-badges.sh on every pull request; a broadened condition also lets" \
            "a job with contents: write push to the status branch from a PR build"
    fi
fi

# --- 6. parsed run/shell values contain no Actions expressions --------------
#
# Expressions are expanded before the script starts. Read decoded YAML scalar
# values: a raw-text opener count misses, for example, "\x24{{ ... }}".
# The Python regressions exercise the same checker the real workflow scan uses.

if "${WORKFLOW_PYTHON}" -B "${TEST_DIR}/test_workflow_expressions.py"; then
    _pass "the workflow expression checker passes its regression cases"
else
    _fail "the workflow expression checker passes its regression cases"
fi

if expression_check=$("${WORKFLOW_PYTHON}" -B \
    "${TEST_DIR}/lib/workflow_expressions.py" "${REPO_ROOT}/.github/workflows" 2>&1); then
    _pass "${expression_check}"
else
    _fail "workflow run/shell values contain no Actions expressions" "${expression_check}"
fi

# --- 7. every action every workflow uses is pinned to immutable code --------
#
# A `uses:` value is the one input to a job that can change after review without
# a commit here: `owner/repo@v1` runs whatever that tag points at when the run
# starts.
#
# Two tests already assert this, and both are scoped to one file.
# test-ai-fix.sh walks ai-fix.yml because that job holds `contents: write`, and
# test-labeler.sh checks labeler.yml's single action because that one holds
# `pull-requests: write` on an event any outside contributor can trigger. Both
# are worth keeping -- they assert more than pinning about those files -- but
# between them they leave build.yml unchecked, and build.yml's `build_push` job
# holds `packages: write`, runs six third-party actions, and hands
# `secrets.SIGNING_SECRET` to `cosign sign`. The grant the two existing checks
# were written for is strictly smaller than the one nothing checked.
#
# So the rule is applied to the directory rather than to a file, which also
# covers status-badges.yml (`contents: write`, pushes the status branch),
# nightly-compliance.yml, coverage-gate.yml and auto-qa.yml, and covers a
# workflow added later without anyone remembering to add a test for it.
#
# This section is why coverage-gate.yml triggers on '.github/workflows/**':
# section 3 asserts that trigger, and it is what makes a pull request unable to
# unpin an action in the same workflow that would have caught it.

if "${WORKFLOW_PYTHON}" -B "${TEST_DIR}/test_workflow_pins.py"; then
    _pass "the action pinning checker passes its regression cases"
else
    _fail "the action pinning checker passes its regression cases"
fi

if pin_check=$("${WORKFLOW_PYTHON}" -B \
    "${TEST_DIR}/lib/workflow_pins.py" "${REPO_ROOT}/.github/workflows" 2>&1); then
    _pass "${pin_check}"
else
    _fail "every workflow uses: is pinned to immutable code" "${pin_check}"
fi

finish
