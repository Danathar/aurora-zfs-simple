#!/usr/bin/env bash
#
# Holds every section of the documentation pages to a row in
# docs/section-map.txt.
#
# The pages here state facts about the automation -- what a workflow does, what
# .claude/settings.json denies, what the command gate refuses, what the ruleset
# requires -- and those facts go stale when the machine changes. #234, #258 and
# #273 were each a section no test read, each found by hand and fixed with its
# own join test. The cause they share is that leaving a section unchecked was
# the silent default: nothing in a diff said a new section had no test.
#
# The map gives every `##` and `###` heading of each tracked page either
# `joined:` and the test that reads it, or `prose:` and a reason, with
# `prose: unchecked:` marking a section of machine claims that no test reads.
# tests/test_docs_section_map.py fails when
#
#   * a tracked page has no block in the map, or the map has one for a page
#     that is not tracked;
#   * a page has a heading with no row, or a row names a heading the page no
#     longer has;
#   * a `joined:` row names a file that is not under tests/, does not exist,
#     never names the page outside a comment or docstring, or is this check.
#
# Each of those rules is first run against a small fixture repository, so a
# rule that stopped firing fails here rather than passing on the real tree.
#
# It does not prove any sentence true, and it does not decide whether a joined
# test reads the section it is joined to: that is the reviewer's call when the
# row is written.

set -uo pipefail

TEST_NAME="test-docs-section-map"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

if output="$(python3 -B "${TEST_DIR}/test_docs_section_map.py" 2>&1)"; then
    _pass "every section of every tracked page has a row in docs/section-map.txt, and every join holds"
else
    _fail "every section of every tracked page has a row in docs/section-map.txt, and every join holds" \
        "${output}"
fi

finish
