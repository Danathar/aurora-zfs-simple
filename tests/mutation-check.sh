#!/usr/bin/env bash
set -euo pipefail

# Mutation check for the lines a change touches in the shipped scripts.
#
# The shell suite proves a script's tests pass. It cannot tell whether any test
# would notice a given line being wrong: a branch can run in every test and
# still have no assertion that depends on it (the four relocation arms of the
# file-read gate in .claude/hooks/gate-git-diff.sh were broken that way with
# the suite green; issue #505). This script asks that question, for changed
# lines only.
#
# For each line that differs from the base revision in a shipped script (every
# tracked *.sh outside tests/, the same set tests/test-coverage.sh declares),
# it writes one small edit at a time into a copy of the checkout -- a
# comparison flipped, `&&` swapped for `||`, an exit status changed, the line
# replaced by `:` -- and runs the test files that name that script. A test file
# failing (or timing out) means the edit was caught. An edit no test catches is
# a survivor, and the run fails unless that exact edit is listed in
# tests/mutation-survivors.txt with the reason it changes nothing a test could
# observe.
#
# Edits that `bash -n` rejects are dropped before anything runs: they say
# nothing about the tests.
#
# Which test files run for which script is the TESTS_FOR table below, not a
# search: several tests quote script paths in their fixtures, and running every
# one of them for every edit would spend the budget on files that test
# something else. A changed script with no row stops the run, so a new script
# cannot be skipped silently.
#
# Before any edit, the script's own test files run once on the unedited copy.
# If they fail there, every edit would look caught, so the run stops instead.
#
# EXCLUDED_TARGETS are the scripts the shell suite cannot reach at all: they do
# their work at the top level inside an image build (tests/test-coverage.sh
# records each as UNCOVERED, with the reason). No test could catch an edit to
# them, so editing them would only list every line as a survivor.
#
# Usage: tests/mutation-check.sh [BASE_REF]   (default: origin/main)
#   MUTATION_TIMEOUT  seconds one test file may run before the edit counts as
#                     caught (default 300)
#   MUTATION_BUDGET   seconds for the whole run; edits left when it runs out
#                     are reported and the run fails (default 2400)
#
# Exit status: 0 every edit was caught or is listed, 1 an unlisted survivor,
# 2 the check could not run or ran out of budget.

EXCLUDED_TARGETS=(
    "build_files/build.sh"
    "build_files/kernel-akmods.sh"
    "build_files/zfs.sh"
)

# Script -> the test files (space separated, relative to the root) that run it.
declare -A TESTS_FOR=(
    [".claude/hooks/gate-git-diff.sh"]="tests/test-claude-settings.sh tests/test-gate-refusal-corpus.sh tests/test-gate-refusal-docs.sh"
    ["build_files/post-check.sh"]="tests/test-post-check.sh tests/test-post-check-checks.sh"
    ["ci/boot-test.sh"]="tests/test-boot-test.sh"
    ["ci/write-badges.sh"]="tests/test-write-badges.sh"
)

# from<TAB>to: the first occurrence of `from` on the line becomes `to`. Each
# pair is one edit; a line with several operators gets one edit per pair.
OPERATORS=(
    $' == \t != '
    $' != \t == '
    $' -eq \t -ne '
    $' -ne \t -eq '
    $' -lt \t -ge '
    $' -ge \t -lt '
    $' -gt \t -le '
    $' -le \t -gt '
    $' && \t || '
    $' || \t && '
    $'[[ -z \t[[ -n '
    $'[[ -n \t[[ -z '
    $'[[ ! \t[[ '
    $'if ! \tif '
    $'exit 0\texit 1'
    $'exit 1\texit 0'
    $'return 0\treturn 1'
    $'return 1\treturn 0'
)

die() {
    printf 'mutation-check: %s\n' "$*" >&2
    exit 2
}

BASE_REF="${1:-origin/main}"
TIMEOUT="${MUTATION_TIMEOUT:-300}"
BUDGET="${MUTATION_BUDGET:-2400}"
[[ "${TIMEOUT}" =~ ^[1-9][0-9]*$ ]] || die "MUTATION_TIMEOUT must be a positive integer, got '${TIMEOUT}'"
[[ "${BUDGET}" =~ ^[1-9][0-9]*$ ]] || die "MUTATION_BUDGET must be a positive integer, got '${BUDGET}'"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git checkout"
cd -- "${REPO_ROOT}" || die "cannot enter ${REPO_ROOT}"
LEDGER="${REPO_ROOT}/tests/mutation-survivors.txt"
git rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null || die "base revision '${BASE_REF}' does not exist"
mapfile -t targets < <(git ls-files '*.sh' | grep -v '^tests/' | sort) || die "cannot list the tracked scripts"
((${#targets[@]} > 0)) || die "git ls-files found no shipped shell scripts"

# Ledger entries: file<TAB>from<TAB>original line, trimmed. Keyed by text rather
# than line number so an unrelated edit above a listed line does not unlist it.
declare -A accepted=()
if [[ -f "${LEDGER}" ]]; then
    while IFS= read -r entry; do
        [[ -z "${entry}" || "${entry}" == \#* ]] && continue
        [[ "${entry}" == *$'\t'*$'\t'* ]] || die "ledger line is not file<TAB>operator<TAB>line: ${entry}"
        accepted["${entry}"]=1
    done <"${LEDGER}"
fi

WORK_DIR="$(mktemp -d)" || die "mktemp failed"
trap 'rm -rf -- "${WORK_DIR}"' EXIT
COPY="${WORK_DIR}/copy"
cp -a -- "${REPO_ROOT}" "${COPY}" || die "cannot copy the checkout"

trim() {
    local text="$1"
    text="${text#"${text%%[![:space:]]*}"}"
    printf '%s' "${text%"${text##*[![:space:]]}"}"
}

# changed_lines <file>: line numbers in the working tree that differ from the base.
changed_lines() {
    git diff --no-color --unified=0 "${BASE_REF}" -- "$1" |
        sed -nE 's/^@@ -[0-9,]+ \+([0-9]+)(,([0-9]+))? @@.*/\1 \3/p' |
        while read -r start count; do
            count="${count:-1}"
            for ((n = start; n < start + count; n++)); do
                printf '%s\n' "${n}"
            done
        done
}

# Lines whose removal only breaks the syntax, or that do nothing to remove.
STRUCTURE_ONLY_RE='^(fi|then|else|do|done|esac|;;|[{}()]|EOF)$'
OPENS_BLOCK_RE='^(if|elif|while|until|for|case|select)[[:space:]]'
CONTINUES_RE='([[:space:]]in|[\\{(|]|&&)$'
not_deletable() {
    local text="$1"
    [[ -z "${text}" || "${text}" == \#* ]] && return 0
    [[ "${text}" =~ ${STRUCTURE_ONLY_RE} ]] && return 0
    [[ "${text}" =~ ${OPENS_BLOCK_RE} ]] && return 0
    [[ "${text}" =~ ${CONTINUES_RE} ]] && return 0
    return 1
}

# run_tests: 0 when every test file naming the target passes.
run_tests() {
    local test_file
    for test_file in "${target_tests[@]}"; do
        (cd -- "${COPY}" && timeout "${TIMEOUT}" "${BASH}" "${test_file}") >/dev/null 2>&1 || return 1
    done
    return 0
}

started=${SECONDS}
caught=0
listed=0
survived=0
skipped_budget=0
invalid=0
survivor_report=""

for target in "${targets[@]}"; do
    for excluded in "${EXCLUDED_TARGETS[@]}"; do
        [[ "${target}" == "${excluded}" ]] && continue 2
    done
    # A script the change deleted is still listed by git until the deletion is
    # staged; it has no lines to edit.
    [[ -f "${target}" ]] || continue
    mapfile -t lines < <(changed_lines "${target}")
    ((${#lines[@]} > 0)) || continue

    [[ -n "${TESTS_FOR[${target}]+set}" ]] || die "${target} changed, but TESTS_FOR in $0 has no row for it"
    read -r -a target_tests <<<"${TESTS_FOR[${target}]}"
    for test_file in "${target_tests[@]}"; do
        [[ -f "${test_file}" ]] || die "TESTS_FOR names ${test_file} for ${target}, and it does not exist"
    done
    run_tests || die "the tests for ${target} fail before any edit (${target_tests[*]}); fix them or the host first"

    mapfile -t original <"${target}"
    for line_number in "${lines[@]}"; do
        text="${original[line_number - 1]-}"
        trimmed="$(trim "${text}")"
        [[ -z "${trimmed}" || "${trimmed}" == \#* ]] && continue

        edits=()
        for operator in "${OPERATORS[@]}"; do
            from="${operator%%$'\t'*}"
            to="${operator#*$'\t'}"
            [[ "${text}" == *"${from}"* ]] && edits+=("$(trim "${from}")"$'\t'"${text/"${from}"/"${to}"}")
        done
        if ! not_deletable "${trimmed}"; then
            edits+=($'delete\t'"${text%%[![:space:]]*}:")
        fi

        for edit in "${edits[@]}"; do
            operator_name="${edit%%$'\t'*}"
            mutated="${edit#*$'\t'}"
            key="${target}"$'\t'"${operator_name}"$'\t'"${trimmed}"
            if ((SECONDS - started >= BUDGET)); then
                skipped_budget=$((skipped_budget + 1))
                continue
            fi
            mutant=("${original[@]}")
            mutant[line_number - 1]="${mutated}"
            printf '%s\n' "${mutant[@]}" >"${COPY}/${target}"
            if ! "${BASH}" -n "${COPY}/${target}" 2>/dev/null; then
                invalid=$((invalid + 1))
            elif ! run_tests; then
                caught=$((caught + 1))
            elif [[ -n "${accepted[${key}]+set}" ]]; then
                listed=$((listed + 1))
            else
                survived=$((survived + 1))
                survivor_report+="SURVIVED ${target}:${line_number} [${operator_name}] $(trim "${mutated}")"$'\n'
                survivor_report+="    ledger line if it is equivalent: ${key//$'\t'/<TAB>}"$'\n'
            fi
            cp -p -- "${target}" "${COPY}/${target}" || die "cannot restore ${target} in the copy"
        done
    done
done

printf 'mutation-check: %d caught, %d listed as equivalent, %d survived, %d not valid bash, %d not run (budget %ss)\n' \
    "${caught}" "${listed}" "${survived}" "${invalid}" "${skipped_budget}" "${BUDGET}"
if ((survived > 0)); then
    printf '%s' "${survivor_report}"
    echo "Add a test that fails on each survivor, or list it in tests/mutation-survivors.txt with the reason no test can tell." >&2
    exit 1
fi
if ((skipped_budget > 0)); then
    echo "mutation-check: ran out of budget with ${skipped_budget} edits unchecked; raise MUTATION_BUDGET or split the change." >&2
    exit 2
fi
exit 0
