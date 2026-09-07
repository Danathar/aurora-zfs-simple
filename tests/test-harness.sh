#!/usr/bin/env bash
#
# Tests for the test harness itself: tests/lib/assert.sh and tests/run-tests.sh.
#
# Every other file here asserts something about the repository. Nothing asserts
# anything about the two files that decide what "the suite passed" means, and
# both fail in the quiet direction. `_fail` is the only place `TESTS_FAILED` is
# incremented and `finish` is the only place it is read; disarm either and every
# test file in this directory reports a clean run while asserting nothing.
# `run-tests.sh` is the same one level up: it collects each file's exit status
# into `failed` and turns that into its own status, so a broken collection
# leaves CI green on a red suite.
#
# That is the reasoning test-ci-workflows.sh applies to the workflows — a check
# that stops checking does not go red, it goes quiet — pointed at the harness
# those tests run inside.
#
# Which is also why this is the one file in tests/ that does not source
# lib/assert.sh. A test of the assertion helpers cannot report its verdict
# through those helpers: an assert.sh that has stopped counting failures would
# swallow this file's failures too, and the run that proves the breakage would
# be the run that hides it. So the checks below are self-contained, deliberately
# simple, and print in the same format the rest of the suite does.
#
# Both files are exercised as real subprocesses. assert.sh is sourced by a
# throwaway script whose output and exit status are the thing under test, and
# run-tests.sh is copied into a sandbox directory holding fake `test-*.sh` files
# that pass or fail on command. The copy is what makes the runner testable: it
# resolves its test directory from `BASH_SOURCE`, so a copy in a temp directory
# globs that directory rather than this one.

set -uo pipefail

TEST_NAME="test-harness"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "${WORK_ROOT}"' EXIT

CHECKS=0
FAILURES=0

_ok() {
    CHECKS=$((CHECKS + 1))
    printf '  ok   %s\n' "$1"
}

_no() {
    CHECKS=$((CHECKS + 1))
    FAILURES=$((FAILURES + 1))
    printf '  FAIL %s\n' "$1"
    shift
    local detail
    for detail in "$@"; do
        printf '       %s\n' "${detail}"
    done
}

expect_eq() {
    local description=$1 expected=$2 actual=$3
    if [[ "${expected}" == "${actual}" ]]; then
        _ok "${description}"
    else
        _no "${description}" "expected: ${expected}" "actual:   ${actual}"
    fi
}

expect_contains() {
    local description=$1 haystack=$2 needle=$3
    if [[ "${haystack}" == *"${needle}"* ]]; then
        _ok "${description}"
    else
        _no "${description}" "expected to contain: ${needle}" "actual: ${haystack}"
    fi
}

expect_absent() {
    local description=$1 haystack=$2 needle=$3
    if [[ "${haystack}" != *"${needle}"* ]]; then
        _ok "${description}"
    else
        _no "${description}" "expected NOT to contain: ${needle}" "actual: ${haystack}"
    fi
}

expect_ran() {
    local description=$1 path=$2
    if [[ -f "${path}" ]]; then
        _ok "${description}"
    else
        _no "${description}" "no marker at ${path}: that file never ran"
    fi
}

expect_not_ran() {
    local description=$1 path=$2
    if [[ ! -e "${path}" ]]; then
        _ok "${description}"
    else
        _no "${description}" "marker at ${path}: that file ran and should not have"
    fi
}

report() {
    printf '%s: %d check(s), %d failure(s)\n' "${TEST_NAME}" "${CHECKS}" "${FAILURES}"
    [[ "${FAILURES}" -eq 0 ]]
}

STATUS=0
STDOUT=""
case_dir=""

# --- lib/assert.sh -----------------------------------------------------------

# Run a snippet against a freshly sourced assert.sh in a child bash. The body
# arrives on stdin so each case reads as the test file it stands in for.
# `finish` is appended, so STATUS is the verdict assert.sh would hand the runner.
probe() {
    local name=$1 body
    body="$(cat)"
    local script="${WORK_ROOT}/probe-${name}.sh"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -uo pipefail'
        printf 'source %q\n' "${REPO_ROOT}/tests/lib/assert.sh"
        printf '%s\n' "${body}"
        printf '%s\n' 'finish'
    } >"${script}"
    STDOUT="$(bash "${script}" 2>&1)"
    STATUS=$?
}

probe eq-pass <<'BODY'
TEST_NAME=probe
assert_eq "values match" same same
BODY
expect_eq "a satisfied assertion exits 0" 0 "${STATUS}"
expect_contains "and prints it as ok" "${STDOUT}" "  ok   values match"
expect_contains "and tallies it as a passing assertion" "${STDOUT}" \
    "probe: 1 assertion(s), 0 failure(s)"

probe eq-fail <<'BODY'
TEST_NAME=probe
assert_eq "values match" wanted "got something else"
BODY
expect_eq "a broken assertion exits non-zero" 1 "${STATUS}"
expect_contains "and prints it as FAIL" "${STDOUT}" "  FAIL values match"
expect_contains "and shows what was expected" "${STDOUT}" "       expected: wanted"
expect_contains "and what it actually got" "${STDOUT}" \
    "       actual:   got something else"
expect_contains "and counts the failure in the tally" "${STDOUT}" \
    "probe: 1 assertion(s), 1 failure(s)"

# The tally is the only thing between a silently disarmed assertion and a green
# run, so check that both halves of it move, and that the exit status follows
# the failure count rather than the last assertion's verdict.
probe tally <<'BODY'
TEST_NAME=probe
assert_eq "first" a a
assert_eq "second" a b
assert_eq "third" a b
assert_eq "fourth" a a
BODY
expect_contains "the tally counts every assertion and every failure" "${STDOUT}" \
    "probe: 4 assertion(s), 2 failure(s)"
expect_eq "a run ending in a pass still fails on an earlier failure" 1 "${STATUS}"
expect_contains "a failure does not stop the assertions behind it" "${STDOUT}" \
    "  ok   fourth"

probe unnamed <<'BODY'
assert_eq "values match" same same
BODY
expect_contains "an unset TEST_NAME reports as test" "${STDOUT}" \
    "test: 1 assertion(s), 0 failure(s)"

probe no-assertions <<'BODY'
TEST_NAME=probe
BODY
expect_eq "a file that asserted nothing still exits 0" 0 "${STATUS}"
expect_contains "and says so" "${STDOUT}" "probe: 0 assertion(s), 0 failure(s)"

probe contains <<'BODY'
TEST_NAME=probe
assert_contains "haystack holds it" "alpha beta gamma" beta
assert_contains "haystack holds the other" "alpha beta gamma" delta
BODY
expect_contains "a present substring passes" "${STDOUT}" "  ok   haystack holds it"
expect_contains "an absent substring fails" "${STDOUT}" \
    "  FAIL haystack holds the other"
expect_contains "and names the substring it wanted" "${STDOUT}" \
    "       expected to contain: delta"
expect_contains "and prints the haystack it searched" "${STDOUT}" \
    "       actual: alpha beta gamma"

probe not-contains <<'BODY'
TEST_NAME=probe
assert_not_contains "kept out" "alpha beta" delta
assert_not_contains "leaked in" "alpha beta" beta
BODY
expect_contains "an absent substring passes assert_not_contains" "${STDOUT}" \
    "  ok   kept out"
expect_contains "a present one fails it" "${STDOUT}" "  FAIL leaked in"
expect_contains "and says which substring should have been absent" "${STDOUT}" \
    "       expected NOT to contain: beta"

# An assertion that matched everything would be worse than no assertion at all:
# assert_contains has to reject a needle that is only nearly there, and
# assert_not_contains has to accept one, so pair them on the same haystack.
probe substring-edges <<'BODY'
TEST_NAME=probe
assert_contains "empty needle is trivially present" "alpha" ""
assert_contains "a needle longer than the haystack is absent" "alpha" "alphabet"
assert_not_contains "a case-different needle counts as absent" "alpha" "ALPHA"
BODY
expect_contains "an empty needle passes" "${STDOUT}" \
    "  ok   empty needle is trivially present"
expect_contains "an over-long needle fails" "${STDOUT}" \
    "  FAIL a needle longer than the haystack is absent"
expect_contains "matching is case-sensitive" "${STDOUT}" \
    "  ok   a case-different needle counts as absent"

printf 'present\n' >"${WORK_ROOT}/present.txt"
mkdir -p "${WORK_ROOT}/a-directory"

# assert_file_exists tests -f, so a directory left where a file was expected is
# a failure rather than a pass.
probe file-exists <<BODY
TEST_NAME=probe
assert_file_exists "the file is there" "${WORK_ROOT}/present.txt"
assert_file_exists "the missing file is there" "${WORK_ROOT}/absent.txt"
assert_file_exists "the directory is a file" "${WORK_ROOT}/a-directory"
BODY
expect_contains "an existing file passes assert_file_exists" "${STDOUT}" \
    "  ok   the file is there"
expect_contains "a missing one fails" "${STDOUT}" "  FAIL the missing file is there"
expect_contains "and names the path it looked for" "${STDOUT}" \
    "       no such file: ${WORK_ROOT}/absent.txt"
expect_contains "a directory does not satisfy assert_file_exists" "${STDOUT}" \
    "  FAIL the directory is a file"

# assert_file_missing tests -e rather than -f, which is what a cleanup
# assertion needs: anything at all left at the path is a failure.
probe file-missing <<BODY
TEST_NAME=probe
assert_file_missing "nothing at that path" "${WORK_ROOT}/absent.txt"
assert_file_missing "the file was removed" "${WORK_ROOT}/present.txt"
assert_file_missing "the directory was removed" "${WORK_ROOT}/a-directory"
BODY
expect_contains "an absent path passes assert_file_missing" "${STDOUT}" \
    "  ok   nothing at that path"
expect_contains "an existing file fails it" "${STDOUT}" "  FAIL the file was removed"
expect_contains "and names the path that should have been gone" "${STDOUT}" \
    "       file should not exist: ${WORK_ROOT}/present.txt"
expect_contains "an existing directory fails it too" "${STDOUT}" \
    "  FAIL the directory was removed"

# _fail takes an arbitrary number of detail lines and every one of them has to
# survive: a failure that prints only its first reason sends the reader
# somewhere else, and _pass and _fail have to share the one run counter.
probe fail-details <<'BODY'
TEST_NAME=probe
_fail "three reasons" "first reason" "second reason" "third reason"
_fail "no reasons at all"
_pass "a bare pass"
BODY
expect_eq "_fail alone is enough to fail the file" 1 "${STATUS}"
expect_contains "the first detail line is printed" "${STDOUT}" "       first reason"
expect_contains "the second is too" "${STDOUT}" "       second reason"
expect_contains "and the last" "${STDOUT}" "       third reason"
expect_contains "a detail-less failure still prints its description" "${STDOUT}" \
    "  FAIL no reasons at all"
expect_contains "_pass and _fail share one counter" "${STDOUT}" \
    "probe: 3 assertion(s), 2 failure(s)"

# --- run-tests.sh ------------------------------------------------------------

# A sandbox holding a copy of the runner and nothing else. Fake tests write a
# marker when they run, so "did not fail" and "never ran" stay distinguishable.
runner_case() {
    local name=$1
    case_dir="${WORK_ROOT}/runner-${name}"
    mkdir -p "${case_dir}/marks"
    cp "${REPO_ROOT}/tests/run-tests.sh" "${case_dir}/run-tests.sh"
}

fake_test() {
    local name=$1 status=$2
    cat >"${case_dir}/${name}" <<STUB
#!/usr/bin/env bash
: >"\${MARKS}/${name}"
printf 'inside %s\n' "${name}"
exit ${status}
STUB
}

run_runner() {
    STDOUT="$(MARKS="${case_dir}/marks" bash "${case_dir}/run-tests.sh" "$@" 2>&1)"
    STATUS=$?
}

runner_case all-pass
fake_test test-alpha.sh 0
fake_test test-beta.sh 0
run_runner
expect_eq "a suite of passing files exits 0" 0 "${STATUS}"
expect_contains "and counts the files it ran" "${STDOUT}" "All 2 test file(s) passed."
expect_contains "each file gets a header" "${STDOUT}" "== test-alpha.sh"
expect_contains "the second one too" "${STDOUT}" "== test-beta.sh"
expect_contains "and its output is passed through" "${STDOUT}" "inside test-beta.sh"
expect_absent "nothing is reported as failed" "${STDOUT}" "FAILED:"

# The whole job of the runner: one red file turns the run red, without
# swallowing the files behind it.
runner_case one-fails
fake_test test-alpha.sh 0
fake_test test-beta.sh 1
fake_test test-gamma.sh 0
run_runner
expect_eq "one failing file fails the run" 1 "${STATUS}"
expect_contains "and is named in the summary" "${STDOUT}" "FAILED: test-beta.sh"
expect_absent "a passing file is not named alongside it" "${STDOUT}" \
    "FAILED: test-alpha.sh"
expect_absent "no all-passed line is printed" "${STDOUT}" "test file(s) passed."
expect_ran "the file after the failure still ran" "${case_dir}/marks/test-gamma.sh"

runner_case several-fail
fake_test test-alpha.sh 1
fake_test test-beta.sh 0
fake_test test-gamma.sh 3
run_runner
expect_eq "several failures still exit 1" 1 "${STATUS}"
expect_contains "every failing file is listed, whatever its exit status" \
    "${STDOUT}" "FAILED: test-alpha.sh test-gamma.sh"

# A file outside the test-*.sh glob is not a test, and neither is a directory
# that happens to match it: the runner filters on -type f.
runner_case discovery
fake_test test-alpha.sh 0
fake_test helper.sh 1
mkdir -p "${case_dir}/test-directory.sh"
run_runner
expect_eq "a file outside the test-*.sh glob is not run" 0 "${STATUS}"
expect_contains "only the matching file counts" "${STDOUT}" "All 1 test file(s) passed."
expect_not_ran "the non-test file never ran" "${case_dir}/marks/helper.sh"

# Selection by argument, in each of the three forms the runner accepts.
runner_case select-name
fake_test test-alpha.sh 0
fake_test test-beta.sh 1
run_runner test-alpha
expect_eq "a bare name selects that file alone" 0 "${STATUS}"
expect_contains "and only it is counted" "${STDOUT}" "All 1 test file(s) passed."
expect_not_ran "the unselected file did not run" "${case_dir}/marks/test-beta.sh"

runner_case select-suffix
fake_test test-alpha.sh 0
fake_test test-beta.sh 1
run_runner test-alpha.sh
expect_eq "a name with the .sh suffix works too" 0 "${STATUS}"
expect_not_ran "and still selects only that file" "${case_dir}/marks/test-beta.sh"

runner_case select-path
fake_test test-alpha.sh 0
fake_test test-beta.sh 1
run_runner "${case_dir}/test-alpha.sh"
expect_eq "so does a path to the file" 0 "${STATUS}"
expect_not_ran "and it selects only that file" "${case_dir}/marks/test-beta.sh"

runner_case select-many
fake_test test-alpha.sh 0
fake_test test-beta.sh 1
fake_test test-gamma.sh 0
run_runner test-alpha test-gamma
expect_eq "two names select two files" 0 "${STATUS}"
expect_contains "and both are counted" "${STDOUT}" "All 2 test file(s) passed."
expect_not_ran "the file named by neither did not run" "${case_dir}/marks/test-beta.sh"

# A typo in a test name must not be reported as a clean run of nothing.
runner_case unknown-name
fake_test test-alpha.sh 0
run_runner test-alfa
expect_eq "an unknown test name exits 1" 1 "${STATUS}"
expect_contains "and says which name it could not find" "${STDOUT}" \
    "run-tests: no such test: test-alfa"
expect_not_ran "and runs nothing at all" "${case_dir}/marks/test-alpha.sh"

# The same typo next to a name that does resolve. Reporting it and then running
# the rest would be the worse failure: an exit status that says something went
# wrong, over output that looks like a suite ran.
runner_case unknown-among-known
fake_test test-alpha.sh 0
run_runner test-alpha test-alfa
expect_eq "one unknown name among known ones still exits 1" 1 "${STATUS}"
expect_contains "and names the one it could not find" "${STDOUT}" \
    "run-tests: no such test: test-alfa"
expect_not_ran "the resolvable name is not run either" "${case_dir}/marks/test-alpha.sh"

# An empty directory is the shape a bad move leaves behind — the test files
# relocated, the runner left pointing at nothing. Exiting 0 there would
# announce a passing suite that does not exist.
runner_case empty
run_runner
expect_eq "a directory with no tests exits 1" 1 "${STATUS}"
expect_contains "and names the directory it searched" "${STDOUT}" \
    "run-tests: no tests found in ${case_dir}"

# The dependency preflight. `command -v` answers from PATH, so an empty PATH is
# the one way to make every required tool absent at once; the runner is started
# through an absolute interpreter so it still gets to run and report.
runner_case missing-tools
fake_test test-alpha.sh 0
mkdir -p "${case_dir}/empty-bin"
STDOUT="$(PATH="${case_dir}/empty-bin" MARKS="${case_dir}/marks" \
    "${BASH}" "${case_dir}/run-tests.sh" 2>&1)"
STATUS=$?
expect_eq "a missing dependency exits 1 before any test runs" 1 "${STATUS}"
expect_contains "and reports the missing tools" "${STDOUT}" \
    "run-tests: missing required tool(s):"
expect_contains "naming jq among them" "${STDOUT}" "jq"
expect_not_ran "no test file was executed" "${case_dir}/marks/test-alpha.sh"
# It has to stop *there*. Reporting the missing tools and carrying on reaches
# discovery, which needs `find` and so fails for a second, misleading reason.
expect_absent "and it stops at the preflight rather than carrying on" "${STDOUT}" \
    "no tests found in"

report
