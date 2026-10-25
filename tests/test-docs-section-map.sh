#!/usr/bin/env bash
#
# Runs tests/test_docs_section_map.py, which holds every `##` and `###` section
# of the documentation pages to a row in docs/section-map.txt.
#
# Whether a section of a page is read by a test was recorded only in that
# test's header comment, so a new section was unchecked by default and no diff
# ever showed it. Quality passes found that three times on this repository
# (#234, #258, #273), and nine more times on atomic-image-builder, whose owner
# approved this check there for both repositories (#805 there, #437 here). The
# map makes the classification part of the change that adds the section:
# `joined:` and the test that reads it, or `prose:` and the reason none does.
#
# The checks are Python because they read the test files as well as the pages:
# a `joined:` test has to name the page outside a comment, and in a Python test
# outside a docstring, which needs the `ast` module. The runner only executes
# tests/test-*.sh, so this file is how it gets run. It needs no PyYAML; the
# interpreter is the one the other Python checks here use.

set -uo pipefail

TEST_NAME="test-docs-section-map"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"

if "${WORKFLOW_PYTHON}" -B "${TEST_DIR}/test_docs_section_map.py"; then
    _pass "every section of every tracked documentation page is classified in docs/section-map.txt"
else
    _fail "every section of every tracked documentation page is classified in docs/section-map.txt" \
        "see the unittest output above"
fi

finish
