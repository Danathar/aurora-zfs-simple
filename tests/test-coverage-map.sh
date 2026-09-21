#!/usr/bin/env bash
#
# Joins tests/README.md to the suite it maps.
#
# That file is where a contributor looks to decide whether something is already
# tested and, if it is not, whether leaving it untested was a decision or an
# oversight. It answers both from two structures: a table under
# "## What is covered" with one row per tests/test-*.sh, and a list under
# "## Not covered" naming the repository paths this suite deliberately does not
# reach. Nothing joined either structure to the tree, and both had already
# drifted:
#
#   * tests/test-agent-prompts.sh and tests/test-containerfile.sh existed with
#     no row, so neither was discoverable from the map -- and the second is the
#     file that argues why the three build_files scripts stay UNCOVERED;
#   * the "Not covered" prose claimed .github/copilot-instructions.md was
#     unchecked while tests/test-copilot-instructions.sh sat in the same file's
#     own coverage table, twenty lines above.
#
# The second is the worse failure, and it is the one a gaps document has: a
# reader trusts it to say where the holes are and stops looking. Understating
# coverage sends somebody to write a test that already exists; overstating it
# leaves a hole nobody checks. Either way the document reads as authoritative
# right up to the moment it is wrong, because prose does not fail.
#
# So both structures are parsed and compared against something that moves on its
# own:
#
#   * the table's first column against `git ls-files 'tests/test-*.sh'`, in both
#     directions -- a test file added without a row fails, and a row left behind
#     by a rename fails;
#   * the "Not covered" list against tests/test-coverage.sh's UNCOVERED column,
#     in both directions -- a path that has since acquired a covering test fails
#     rather than sitting in the list, and a script recorded as UNCOVERED there
#     but missing here fails too.
#
# The second join is made against that manifest rather than against a `grep` of
# the suite, because being *named* by a test is not being *covered* by one.
# `grep -rl build_files/zfs.sh tests/` matches nine files -- test-coverage.sh
# records it as UNCOVERED, test-containerfile.sh checks its mount contract,
# test-agent-prompts.sh and test-cursorrules.sh read its `kmod-zfs` glob, the
# rest classify the path -- and not one of them executes a line of it. A
# name-based rule would fail on the entry the list most needs to keep. This
# repository already keeps a machine-readable record of that difference, so this
# file reads that record instead of inventing a second one.
#
# Scope: the two structures. The reasoning paragraphs around them -- why a
# pinned third-party action has no shell of this repository's to run, what needs
# a real image build -- are judgement rather than claims about the tree, and
# nothing here tries to check them. Both extractors are run against a fixture
# with known answers first, because an extractor that quietly returned nothing
# would make every assertion below vacuously true.

# The awk programs below are single-quoted so that `$0`, `$1` and the backticks
# in their patterns reach awk rather than the shell. That is the point of the
# quoting, so SC2016 is off for the file rather than repeated above each one.
# shellcheck disable=SC2016

set -uo pipefail

TEST_NAME="test-coverage-map"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

TESTS_README="${TEST_DIR}/README.md"
COVERAGE_TEST="${TEST_DIR}/test-coverage.sh"

assert_file_exists "tests/README.md is present" "${TESTS_README}"
assert_file_exists "tests/test-coverage.sh is present" "${COVERAGE_TEST}"
if [[ ! -f "${TESTS_README}" || ! -f "${COVERAGE_TEST}" ]]; then
    finish
    exit
fi

# An extraction that matched nothing is an unchecked document, not a pass.
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

# --- extractors --------------------------------------------------------------

# The coverage table's rows, as `file<TAB>covers`. Bounded by its own heading so
# a table added later under another one cannot join the set, and anchored on a
# backticked `test-*.sh` in the first cell so the header row and the `| --- |`
# separator drop out without being named.
table_rows() {
    awk '
        /^## What is covered$/ { in_section = 1; next }
        in_section && /^## /   { exit }
        in_section && /^\|[[:space:]]*`test-[^`]*\.sh`[[:space:]]*\|/ {
            line = $0
            sub(/^\|/, "", line)
            sub(/\|[[:space:]]*$/, "", line)
            cut = index(line, "|")
            name = substr(line, 1, cut - 1)
            covers = substr(line, cut + 1)
            gsub(/^[[:space:]]*`|`[[:space:]]*$/, "", name)
            sub(/^[[:space:]]+/, "", covers)
            sub(/[[:space:]]+$/, "", covers)
            print name "\t" covers
        }
    ' "$1"
}

# The repository paths the "Not covered" section claims are unreached: the list
# entries whose whole item is one backticked span. The paragraphs around them
# name plenty of other paths -- the test that retired an entry, the workflow
# whose `run:` bodies are now executed -- and those are prose about coverage
# rather than claims of its absence, so only the list shape is read.
not_covered_paths() {
    awk '
        /^## Not covered$/    { in_section = 1; next }
        in_section && /^## /  { exit }
        in_section && /^-[[:space:]]+`[^`]+`[[:space:]]*$/ {
            path = $0
            sub(/^-[[:space:]]+`/, "", path)
            sub(/`[[:space:]]*$/, "", path)
            print path
        }
    ' "$1"
}

# --- the extractors, against known answers -----------------------------------
#
# Both are shape-sensitive in ways a reader cannot see: a row whose first cell
# is not a backticked span, or a list entry carrying a trailing clause, is
# skipped rather than reported. A fixture makes that visible here rather than as
# a silent pass over the real file.

FIXTURE_DIR=$(mktemp -d)
trap 'rm -rf "${FIXTURE_DIR}"' EXIT

cat >"${FIXTURE_DIR}/fixture.md" <<'EOF'
# Fixture

## What is covered

| File               | Covers                          |
| ------------------ | ------------------------------- |
| `test-alpha.sh`    | `alpha.sh`, with `foo` stubbed  |
| `test-beta.sh`     | beta | and a pipe in the cell    |
| not-a-row          | ignored, the name is not a span |

## Elsewhere

| `test-gamma.sh`    | under another heading, ignored  |

## Not covered

`prose/path.sh` is named in a sentence rather than listed, so it is not an entry.

- `left/alone.sh`
- `also/alone.sh`
- `carries/a.sh` — a trailing clause, so not a bare path entry

## After

- `after/the.sh`
EOF

assert_eq "the table extractor reads the rows under its own heading" \
    "$(printf 'test-alpha.sh\t`alpha.sh`, with `foo` stubbed\ntest-beta.sh\tbeta | and a pipe in the cell')" \
    "$(table_rows "${FIXTURE_DIR}/fixture.md")"

assert_eq "the not-covered extractor reads only the bare path entries" \
    "$(printf 'left/alone.sh\nalso/alone.sh')" \
    "$(not_covered_paths "${FIXTURE_DIR}/fixture.md")"

# --- the coverage table against the tests/test-*.sh glob ---------------------

# The set has to be the runner's set, which tests/run-tests.sh builds with
# `find "${TEST_DIR}" -maxdepth 1 -name 'test-*.sh' -type f`: immediate children
# of tests/ only. A git pathspec is not a shell glob -- its `*` matches `/` as
# well, so `tests/test-*.sh` also lists a tracked tests/test-fixtures/helper.sh
# (see the pathspec entry in gitglossary(7)). Left as-is, a helper parked under
# such a directory is not a test the runner ever executes, yet this gate would
# demand a coverage-table row for it. `NF == 2` keeps the two-component paths,
# which is the same set `-maxdepth 1` reaches.
TRACKED_TESTS=$(
    cd "${REPO_ROOT}" && git ls-files 'tests/test-*.sh' |
        awk -F/ 'NF == 2' | sed 's#^tests/##' | sort
)
if ! require_nonempty "a tracked tests/test-*.sh set to compare the table with" "${TRACKED_TESTS}"; then
    finish
    exit
fi

ROWS=$(table_rows "${TESTS_README}")
if ! require_nonempty "a coverage table under '## What is covered'" "${ROWS}"; then
    finish
    exit
fi

TABLE_FILES=$(cut -f1 <<<"${ROWS}" | sort)

# A row that says nothing is a row a reader cannot act on; and a file listed
# twice would satisfy the set comparison below while hiding which of the two
# rows is the stale one.
while IFS=$'\t' read -r name covers; do
    [[ -z "${name}" ]] && continue

    if [[ -n "${covers//[[:space:]]/}" ]]; then
        _pass "the row for ${name} says what it covers"
    else
        _fail "the row for ${name} says what it covers" "its Covers cell is empty"
    fi

    count=$(grep -cxF "${name}" <<<"${TABLE_FILES}")
    if [[ "${count}" -eq 1 ]]; then
        _pass "${name} has exactly one row"
    else
        _fail "${name} has exactly one row" "the table lists it ${count} times"
    fi
done <<<"${ROWS}"

# Both directions. Either alone leaves half the drift undetectable: a test file
# with no row is invisible to a reader deciding where to add one, and a row with
# no file points at nothing after a rename.
while IFS= read -r file; do
    [[ -z "${file}" ]] && continue
    if grep -qxF "${file}" <<<"${TABLE_FILES}"; then
        _pass "the coverage table has a row for ${file}"
    else
        _fail "the coverage table has a row for ${file}" \
            "add a row under '## What is covered' in tests/README.md saying what it covers"
    fi
done <<<"${TRACKED_TESTS}"

while IFS= read -r file; do
    [[ -z "${file}" ]] && continue
    if grep -qxF "${file}" <<<"${TRACKED_TESTS}"; then
        _pass "the row for ${file} still names a tracked test file"
    else
        _fail "the row for ${file} still names a tracked test file" \
            "no tracked tests/${file}; the row is stale, remove or rename it"
    fi
done <<<"${TABLE_FILES}"

# --- the "Not covered" list against the coverage gate's own record -----------

NOT_COVERED=$(not_covered_paths "${TESTS_README}")
if ! require_nonempty "a path list under '## Not covered'" "${NOT_COVERED}"; then
    finish
    exit
fi

# tests/test-coverage.sh's manifest is a heredoc of tab-separated
# `path`/`covering test or UNCOVERED`/`reason` lines. Only the UNCOVERED ones
# are read here: those are the gaps that file has already recorded, and they are
# what this list restates.
MANIFEST_UNCOVERED=$(
    awk -F'\t' '$1 ~ /^[^[:space:]#]/ && $2 == "UNCOVERED" { print $1 }' "${COVERAGE_TEST}" | sort
)
if ! require_nonempty "UNCOVERED entries in tests/test-coverage.sh's manifest" "${MANIFEST_UNCOVERED}"; then
    finish
    exit
fi

TRACKED=$(cd "${REPO_ROOT}" && git ls-files)

while IFS= read -r path; do
    [[ -z "${path}" ]] && continue

    if grep -qxF "${path}" <<<"${TRACKED}"; then
        _pass "the not-covered entry ${path} is a tracked file"
    else
        _fail "the not-covered entry ${path} is a tracked file" \
            "git ls-files does not list it; the entry is stale"
        continue
    fi

    # The join that makes the claim mean something. UNCOVERED is this
    # repository's own record that no test reaches the script, held in both
    # directions by tests/test-coverage.sh -- so a path that acquires a covering
    # test leaves that column and fails here, which is the drift this file
    # exists to catch.
    if grep -qxF "${path}" <<<"${MANIFEST_UNCOVERED}"; then
        _pass "${path} is still UNCOVERED in tests/test-coverage.sh's manifest"
    else
        _fail "${path} is still UNCOVERED in tests/test-coverage.sh's manifest" \
            "it is either covered there now or absent from it; a path this" \
            "section claims is unreached has to be recorded as a gap there too"
    fi

    # The naming convention is regular enough here to be worth asserting on its
    # own: a covering test for X is tests/test-<X's stem>.sh. That is the shape
    # the .github/copilot-instructions.md claim drifted into -- the section
    # named a path while tests/test-copilot-instructions.sh sat in the table
    # above it, and the manifest above says nothing about files that are not
    # shipped shell.
    stem=${path##*/}
    stem=${stem%.*}
    if [[ -e "${TEST_DIR}/test-${stem}.sh" ]]; then
        _fail "no test file is named after ${path}" \
            "tests/test-${stem}.sh exists, so ${path} is covered rather than a gap"
    else
        _pass "no test file is named after ${path}"
    fi
done <<<"${NOT_COVERED}"

# The other direction: a gap the coverage gate records has to reach the document
# a contributor reads. Without this, dropping an entry from the list silently
# narrows what the document admits to while every check above still passes.
while IFS= read -r path; do
    [[ -z "${path}" ]] && continue
    if grep -qxF "${path}" <<<"${NOT_COVERED}"; then
        _pass "'## Not covered' lists the UNCOVERED script ${path}"
    else
        _fail "'## Not covered' lists the UNCOVERED script ${path}" \
            "tests/test-coverage.sh records it as UNCOVERED; add it to the list" \
            "under '## Not covered' in tests/README.md"
    fi
done <<<"${MANIFEST_UNCOVERED}"

finish
