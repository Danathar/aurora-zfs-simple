#!/usr/bin/env bash
#
# Runs every tests/test-*.sh and exits non-zero if any of them fails.
#
#   ./tests/run-tests.sh                   # all tests
#   ./tests/run-tests.sh test-write-badges # one test in this directory, by name or path
#
# Requirements: bash 4+, jq, coreutils date, sed; the workflow expression check
# also requires Python 3 with PyYAML. No third-party test framework is needed.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

missing=()
for tool in bash jq date sed; do
    command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
done
if [[ "${#missing[@]}" -gt 0 ]]; then
    printf 'run-tests: missing required tool(s): %s\n' "${missing[*]}" >&2
    exit 1
fi

# Resolves one selection argument -- a bare name, a file name, or a path -- to a
# test file in this directory, and to nothing else.
#
# The restriction is load-bearing rather than tidy. `.claude/settings.json` puts
# this runner on the agent permission table's `allow` list as
# `Bash(./tests/run-tests.sh:*)`, which means "this command with any arguments",
# so a path this function accepts is a path that gets `bash`ed with no permission
# prompt. Resolving any readable path would make the runner a general-purpose
# interpreter and every `ask` and `deny` rule beside it -- `cosign sign`,
# `git push --force`, `Read(./cosign.key)` -- one file away from irrelevant.
#
# A file the agent writes at tests/test-*.sh is still executed by the next run;
# that residual is inherent to allow-listing a test runner at all, and it lands
# on the surface shellcheck, test-shell-syntax.sh and review already cover.
resolve_test() {
    local arg=$1 candidate dir base
    for candidate in "${arg}" "${TEST_DIR}/${arg}" "${TEST_DIR}/${arg}.sh"; do
        [[ -f "${candidate}" ]] || continue
        dir="$(cd -- "$(dirname -- "${candidate}")" >/dev/null 2>&1 && pwd)" || continue
        base="$(basename -- "${candidate}")"
        [[ "${dir}" == "${TEST_DIR}" ]] || continue
        [[ "${base}" == test-*.sh ]] || continue
        printf '%s\n' "${dir}/${base}"
        return 0
    done
    return 1
}

files=()
if [[ "$#" -gt 0 ]]; then
    for arg in "$@"; do
        if resolved="$(resolve_test "${arg}")"; then
            files+=("${resolved}")
        elif [[ -f "${arg}" || -f "${TEST_DIR}/${arg}" || -f "${TEST_DIR}/${arg}.sh" ]]; then
            # It exists, so "no such test" would send the reader looking for a
            # typo that is not there.
            printf 'run-tests: not a test file in %s: %s\n' "${TEST_DIR}" "${arg}" >&2
            exit 1
        else
            printf 'run-tests: no such test: %s\n' "${arg}" >&2
            exit 1
        fi
    done
else
    while IFS= read -r file; do
        files+=("${file}")
    done < <(find "${TEST_DIR}" -maxdepth 1 -name 'test-*.sh' -type f | sort)
fi

if [[ "${#files[@]}" -eq 0 ]]; then
    printf 'run-tests: no tests found in %s\n' "${TEST_DIR}" >&2
    exit 1
fi

failed=()
for file in "${files[@]}"; do
    printf '\n== %s\n' "$(basename "${file}")"
    if ! bash "${file}"; then
        failed+=("$(basename "${file}")")
    fi
done

printf '\n'
if [[ "${#failed[@]}" -gt 0 ]]; then
    printf 'FAILED: %s\n' "${failed[*]}"
    exit 1
fi
printf 'All %d test file(s) passed.\n' "${#files[@]}"
