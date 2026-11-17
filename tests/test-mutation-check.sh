#!/usr/bin/env bash
# shellcheck disable=SC2016  # fixture script text and sed edits are written unexpanded on purpose
set -uo pipefail

# Exercise tests/mutation-check.sh against a throwaway git repository.
#
# The fixture has the layout the check reads -- tracked shell scripts, a script
# named in its TESTS_FOR table, and that script's test file -- but the script is
# a few lines long and its test runs in milliseconds, so each case here is a
# real run of the check, edits and all. What is worth testing is the verdict:
# an edit a test notices passes, one nothing notices fails until the ledger
# lists it, and anything that would make every edit look caught (a red
# baseline, a missing row, a bad base) stops the run instead of passing it.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${SCRIPT_DIR}/mutation-check.sh"

failures=0
tests_run=0

WORK_DIR="$(mktemp -d)"
cleanup() {
    [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]] && rm -rf -- "${WORK_DIR}"
}
trap cleanup EXIT

pass() { printf 'ok - %s\n' "$*"; }
fail() {
    printf 'not ok - %s\n' "$*" >&2
    failures=$((failures + 1))
}
check() {
    local description="$1" result="$2"
    shift 2
    tests_run=$((tests_run + 1))
    if [[ "${result}" == "0" ]]; then
        pass "${description}"
    else
        fail "${description}${*:+: $*}"
    fi
}
assert_status() {
    local description="$1" expected="$2" actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then
        check "${description}" 0
    else
        check "${description}" 1 "expected exit ${expected}, got ${actual}"
    fi
}
assert_contains() {
    local description="$1" haystack="$2" needle="$3"
    if [[ "${haystack}" == *"${needle}"* ]]; then
        check "${description}" 0
    else
        check "${description}" 1 "output did not contain '${needle}'"
    fi
}

# new_fixture <dir>: a committed repository whose boot-test.sh test catches
# every edit of the base script. Cases then change the script on top of it.
new_fixture() {
    local dir="$1"
    mkdir -p "${dir}/ci" "${dir}/tests" "${dir}/build_files"
    cp -- "${CHECK}" "${dir}/tests/mutation-check.sh"
    # In EXCLUDED_TARGETS: tracked, but never edited.
    printf '#!/usr/bin/env bash\necho build\n' >"${dir}/build_files/build.sh"
    cat >"${dir}/ci/boot-test.sh" <<'SCRIPT'
#!/usr/bin/env bash
answer=no
if [[ "${1:-}" == yes ]]; then
    answer=yes
fi
echo "${answer}"
SCRIPT
    cat >"${dir}/tests/test-boot-test.sh" <<'TEST'
#!/usr/bin/env bash
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "$(bash "${root}/ci/boot-test.sh" yes)" == yes ]] || exit 1
[[ "$(bash "${root}/ci/boot-test.sh" no)" == no ]] || exit 1
TEST
    git -C "${dir}" init -q -b main
    commit_fixture "${dir}"
}

commit_fixture() {
    git -C "$1" -c user.name=fixture -c user.email=fixture@example.invalid add -A
    git -C "$1" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m base
}

# run_check <dir> [VAR=value...]: run the fixture's copy against main, output on stdout.
run_check() {
    local dir="$1"
    shift
    (cd -- "${dir}" && env "$@" "${BASH}" tests/mutation-check.sh main 2>&1)
}

# --- An unchanged script gives nothing to edit -------------------------------
new_fixture "${WORK_DIR}/same"
output="$(run_check "${WORK_DIR}/same")"
assert_status "nothing changed: exit 0" 0 "$?"
assert_contains "nothing changed: no edits counted" "${output}" "0 caught, 0 listed as equivalent, 0 survived"

# --- A changed line the test notices ------------------------------------------
new_fixture "${WORK_DIR}/caught"
sed -i 's/== yes ]]/== yes ]] || [[ "${1:-}" == y ]]/' "${WORK_DIR}/caught/ci/boot-test.sh"
cat >>"${WORK_DIR}/caught/tests/test-boot-test.sh" <<'TEST'
[[ "$(bash "${root}/ci/boot-test.sh" y)" == yes ]] || exit 1
TEST
output="$(run_check "${WORK_DIR}/caught")"
assert_status "every edit of the changed line caught: exit 0" 0 "$?"
assert_contains "the first == flipped and the || swapped are both caught" "${output}" "2 caught, 0 listed as equivalent, 0 survived"

# --- Lines that give no edit to run -----------------------------------------
new_fixture "${WORK_DIR}/comment"
printf '# answer == yes only when asked, exit 0 either way\n' >>"${WORK_DIR}/comment/ci/boot-test.sh"
output="$(run_check "${WORK_DIR}/comment")"
assert_status "a changed comment: exit 0" 0 "$?"
assert_contains "a comment is not edited, though it holds operators" "${output}" "0 caught, 0 listed as equivalent, 0 survived, 0 not valid bash"

new_fixture "${WORK_DIR}/invalid"
cat >"${WORK_DIR}/invalid/ci/boot-test.sh" <<'SCRIPT'
#!/usr/bin/env bash
{
    echo "${1:-no}"
} | cat
SCRIPT
commit_fixture "${WORK_DIR}/invalid"
sed -i 's/^} | cat$/} | cat -/' "${WORK_DIR}/invalid/ci/boot-test.sh"
output="$(run_check "${WORK_DIR}/invalid")"
assert_status "an edit bash cannot parse is not a verdict: exit 0" 0 "$?"
assert_contains "deleting a group's closing line is counted as not valid bash, not as caught" "${output}" "0 caught, 0 listed as equivalent, 0 survived, 1 not valid bash"

# --- Each edit is undone before the next script's tests run ------------------
new_fixture "${WORK_DIR}/two"
printf '#!/usr/bin/env bash\necho state\n' >"${WORK_DIR}/two/ci/write-badges.sh"
cat >"${WORK_DIR}/two/tests/test-write-badges.sh" <<'TEST'
#!/usr/bin/env bash
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "$(bash "${root}/ci/write-badges.sh")" == state ]] || exit 1
[[ "$(bash "${root}/ci/boot-test.sh" yes)" == yes ]] || exit 1
TEST
commit_fixture "${WORK_DIR}/two"
sed -i 's/^    answer=yes$/    answer="yes"/' "${WORK_DIR}/two/ci/boot-test.sh"
sed -i 's/^echo state$/echo "state"/' "${WORK_DIR}/two/ci/write-badges.sh"
output="$(run_check "${WORK_DIR}/two")"
assert_status "the second script's tests run against the first script as it was" 0 "$?"
assert_contains "one edit per changed line, both caught" "${output}" "2 caught, 0 listed as equivalent, 0 survived"

# --- A changed line nothing checks --------------------------------------------
new_fixture "${WORK_DIR}/survives"
sed -i 's/^echo "${answer}"$/echo "${answer}"\necho "checked ${answer}" >\&2/' "${WORK_DIR}/survives/ci/boot-test.sh"
output="$(run_check "${WORK_DIR}/survives")"
assert_status "an edit no test notices fails the run" 1 "$?"
assert_contains "the survivor is named with its line and the edit" "${output}" "SURVIVED ci/boot-test.sh:7 [delete] :"
assert_contains "the ledger line to add is printed" "${output}" 'ci/boot-test.sh<TAB>delete<TAB>echo "checked ${answer}" >&2'

printf '# stderr is for people\nci/boot-test.sh\tdelete\techo "checked ${answer}" >&2\n' \
    >"${WORK_DIR}/survives/tests/mutation-survivors.txt"
output="$(run_check "${WORK_DIR}/survives")"
assert_status "the same survivor listed in the ledger passes" 0 "$?"
assert_contains "a listed survivor is counted as listed" "${output}" "0 caught, 1 listed as equivalent, 0 survived"

printf 'ci/boot-test.sh delete echo\n' >"${WORK_DIR}/survives/tests/mutation-survivors.txt"
output="$(run_check "${WORK_DIR}/survives")"
assert_status "a ledger line without its two tabs stops the run" 2 "$?"
assert_contains "the malformed ledger line is quoted" "${output}" "ledger line is not file<TAB>operator<TAB>line"

# --- An edit that hangs the test counts as caught -----------------------------
new_fixture "${WORK_DIR}/hangs"
cat >"${WORK_DIR}/hangs/ci/boot-test.sh" <<'SCRIPT'
#!/usr/bin/env bash
i=0
while [[ "${i}" -lt 3 ]]; do
    i=$((i + 1))
done
echo "${1:-no}"
SCRIPT
commit_fixture "${WORK_DIR}/hangs"
sed -i 's/i=$((i + 1))/i=$(( i + 1 ))/' "${WORK_DIR}/hangs/ci/boot-test.sh"
hang_started=${SECONDS}
output="$(run_check "${WORK_DIR}/hangs" MUTATION_TIMEOUT=2)"
assert_status "a loop that never ends under an edit is caught by the time limit" 0 "$?"
assert_contains "deleting the loop's step is counted as caught" "${output}" "1 caught, 0 listed as equivalent, 0 survived"
check "the time limit is MUTATION_TIMEOUT's, not the default" \
    "$((SECONDS - hang_started < 60 ? 0 : 1))" "took $((SECONDS - hang_started))s"

# --- Runs that cannot give a verdict ------------------------------------------
new_fixture "${WORK_DIR}/red"
printf 'exit 1\n' >>"${WORK_DIR}/red/tests/test-boot-test.sh"
printf 'echo extra\n' >>"${WORK_DIR}/red/ci/boot-test.sh"
output="$(run_check "${WORK_DIR}/red")"
assert_status "a test that fails before any edit stops the run" 2 "$?"
assert_contains "the failing baseline is named" "${output}" "the tests for ci/boot-test.sh fail before any edit"

new_fixture "${WORK_DIR}/norow"
printf '#!/usr/bin/env bash\necho new\n' >"${WORK_DIR}/norow/ci/new-tool.sh"
# In CI the new file is committed; here, telling git about it is enough.
git -C "${WORK_DIR}/norow" add --intent-to-add ci/new-tool.sh
output="$(run_check "${WORK_DIR}/norow")"
assert_status "a changed script with no TESTS_FOR row stops the run" 2 "$?"
assert_contains "the missing row is named" "${output}" "ci/new-tool.sh changed, but TESTS_FOR"

new_fixture "${WORK_DIR}/nobase"
output="$(cd -- "${WORK_DIR}/nobase" && "${BASH}" tests/mutation-check.sh no-such-ref 2>&1)"
assert_status "a base revision that does not exist stops the run" 2 "$?"
assert_contains "the missing base is named" "${output}" "base revision 'no-such-ref' does not exist"

new_fixture "${WORK_DIR}/budget"
printf 'sleep 2\n' >>"${WORK_DIR}/budget/tests/test-boot-test.sh"
sed -i 's/^echo "${answer}"$/echo "${answer}"\necho done >\&2/' "${WORK_DIR}/budget/ci/boot-test.sh"
sed -i 's/== yes ]]/== yes ]] || [[ "${1:-}" == y ]]/' "${WORK_DIR}/budget/ci/boot-test.sh"
output="$(run_check "${WORK_DIR}/budget" MUTATION_BUDGET=1)"
assert_status "edits left unchecked when the budget runs out fail the run" 2 "$?"
assert_contains "the unchecked edits are counted" "${output}" "ran out of budget"

# --- A script the change deleted has nothing to edit --------------------------
new_fixture "${WORK_DIR}/deleted"
rm -- "${WORK_DIR}/deleted/ci/boot-test.sh"
output="$(run_check "${WORK_DIR}/deleted")"
assert_status "a deleted script runs no edits" 0 "$?"
assert_contains "the deleted script's lines are not edited" "${output}" "0 caught, 0 listed as equivalent, 0 survived"

# --- Scripts only an image build runs are left out ---------------------------
new_fixture "${WORK_DIR}/excluded"
printf 'exit 0\n' >>"${WORK_DIR}/excluded/build_files/build.sh"
output="$(run_check "${WORK_DIR}/excluded")"
assert_status "a change to an image-build-only script runs no edits" 0 "$?"
assert_contains "its changed line is not edited" "${output}" "0 caught, 0 listed as equivalent, 0 survived"

# --- The table names real files, and the gate hook is a target ---------------
# The fixture above cannot see the real table, so read it from the script: every
# test file a row names must exist here, and the hook must have a row rather
# than an exclusion (its own tests did not pin every arm; issue #505).
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
table="$(sed -n '/^declare -A TESTS_FOR=(/,/^)/p' "${CHECK}")"
assert_contains "the file-read gate hook has a TESTS_FOR row" "${table}" '[".claude/hooks/gate-git-diff.sh"]='
excluded="$(sed -n '/^EXCLUDED_TARGETS=(/,/^)/p' "${CHECK}")"
if [[ "${excluded}" == *gate-git-diff.sh* ]]; then
    check "the file-read gate hook is not excluded" 1 "EXCLUDED_TARGETS names it"
else
    check "the file-read gate hook is not excluded" 0
fi
missing=""
while IFS= read -r named; do
    [[ -f "${REPO_ROOT}/${named}" ]] || missing+="${named} "
done < <(grep -oE 'tests/test-[A-Za-z0-9_-]+\.sh' <<<"${table}" | sort -u)
if [[ -z "${missing}" ]]; then
    check "every test file the TESTS_FOR table names exists" 0
else
    check "every test file the TESTS_FOR table names exists" 1 "missing: ${missing}"
fi

printf '1..%d\n' "${tests_run}"
if ((failures > 0)); then
    printf 'FAILED %d of %d assertion(s)\n' "${failures}" "${tests_run}" >&2
    exit 1
fi
printf 'All %d assertion(s) passed.\n' "${tests_run}"
