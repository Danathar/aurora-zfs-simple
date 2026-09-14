#!/usr/bin/env bash
#
# Static checks over every shell script in the repository.
#
# `bash -n` is always run: it costs nothing and catches the class of typo that
# would otherwise only surface halfway through a 40-minute image build, or on
# the daily badge run where nobody is watching.
#
# The shellcheck pass runs when the tool is installed and is skipped otherwise,
# so the suite stays usable on a machine without it. Making it a hard
# requirement belongs in CI, not here.
#
# Which files those checks run over is decided by one filename pattern, and the
# last section here is what keeps that pattern from being a way around them.

set -uo pipefail

TEST_NAME="test-shell-syntax"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

scripts=()
while IFS= read -r file; do
    scripts+=("${file}")
done < <(
    find "${REPO_ROOT}" -path "${REPO_ROOT}/.git" -prune -o -name '*.sh' -type f -print | sort
)

if [[ "${#scripts[@]}" -eq 0 ]]; then
    _fail "found shell scripts to check" "no *.sh files under ${REPO_ROOT}"
    finish
    exit
fi

for script in "${scripts[@]}"; do
    rel="${script#"${REPO_ROOT}"/}"
    output="$(bash -n "${script}" 2>&1)"
    assert_eq "bash -n accepts ${rel}" "" "${output}"
done

# Every executed script needs an interpreter line; the Containerfile runs the
# build_files scripts by path, and the workflow runs ci/write-badges.sh by path.
for script in "${scripts[@]}"; do
    rel="${script#"${REPO_ROOT}"/}"
    [[ "${rel}" == tests/lib/* ]] && continue # sourced, never executed
    assert_contains "${rel} starts with a shebang" "$(head -1 "${script}")" "#!"
    if [[ -x "${script}" ]]; then
        _pass "${rel} is executable"
    else
        _fail "${rel} is executable" "chmod +x ${rel}"
    fi
done

if command -v shellcheck >/dev/null 2>&1; then
    for script in "${scripts[@]}"; do
        rel="${script#"${REPO_ROOT}"/}"
        output="$(cd "${REPO_ROOT}" && shellcheck -x "${rel}" 2>&1)"
        assert_eq "shellcheck is clean for ${rel}" "" "${output}"
    done
else
    printf '  skip shellcheck (not installed)\n'
fi

# --- the filename is load-bearing, so assert that it is ---------------------
#
# Everything above selects with `-name '*.sh'`, and that is not the only place
# the suffix decides whether a file is checked at all:
#
#   * tests/test-coverage.sh selects `git ls-files '*.sh'` before requiring a
#     covered-or-UNCOVERED decision for each shipped script;
#   * the PostToolUse hook in .claude/settings.json selects `case "$f" in *.sh)`
#     before running shellcheck on a file an agent has just written.
#
# Those three agree with each other, which is what tests/README.md records. What
# none of them checks is that the set they agree on is every shell script in the
# tree. A script named without the suffix -- build_files/lib/common, ci/publish
# -- is outside all three at once: never `bash -n`'d, never shellchecked, never
# required to declare a coverage decision, and never linted at write time.
# Nothing fails, and both positions that reaches are privileged: build_files/
# runs as root inside the image build, ci/ runs in a contents: write job.
#
# The set of tracked files with a shell shebang, the set with the executable
# bit, and the set matching *.sh are identical today. This is what keeps them
# that way, rather than leaving it to convention.
#
# A shebang naming another interpreter is not a finding -- a Python helper has
# no business being called *.sh. An executable with no interpreter line at all
# is, because this repo ships no binaries and should not gain one silently.
SHELL_SHEBANG='^#!.*[[:space:]/](bash|sh|dash|zsh|ksh)([[:space:]]|$)'

# Tracked files only: an untracked scratch file in someone's working tree is
# not something this repo ships, and failing on it would be noise.
tracked=()
while IFS= read -r file; do
    tracked+=("${file}")
done < <(cd "${REPO_ROOT}" && git ls-files)

if [[ "${#tracked[@]}" -eq 0 ]]; then
    # Not a skip: an empty list would make the assertion below trivially true,
    # which is the failure mode this whole section exists to rule out.
    _fail "git lists the tracked files" \
        "git ls-files returned nothing under ${REPO_ROOT}, so the suffix" \
        "invariant cannot be checked and must not be reported as holding"
else
    unsuffixed=""
    for rel in "${tracked[@]}"; do
        [[ "${rel}" == *.sh ]] && continue
        [[ -f "${REPO_ROOT}/${rel}" ]] || continue

        first_line="$(head -1 "${REPO_ROOT}/${rel}" 2>/dev/null)"
        if [[ "${first_line}" =~ ${SHELL_SHEBANG} ]]; then
            unsuffixed+="${rel} (shell shebang) "
        elif [[ -x "${REPO_ROOT}/${rel}" && "${first_line}" != '#!'* ]]; then
            unsuffixed+="${rel} (executable, no interpreter line) "
        fi
    done
    assert_eq "every shell script in the tree is named *.sh" "" "${unsuffixed% }"
fi

finish
