#!/usr/bin/env bash
#
# Exercises the Chunkah custom manager against both checked-in pin syntaxes.
# Renovate uses RE2's JavaScript-style named captures; Python's equivalent is
# substituted below so the repository's existing Python dependency can run the
# same expression without requiring a Renovate installation.

set -uo pipefail

TEST_NAME="test-renovate"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

CONFIG="${REPO_ROOT}/renovate.json"

if jq empty "${CONFIG}" >/dev/null 2>&1; then
    _pass "renovate.json is valid JSON"
else
    _fail "renovate.json is valid JSON" "jq could not parse ${CONFIG}"
    finish
    exit
fi

analysis=""
if analysis=$(python3 - "${CONFIG}" "${REPO_ROOT}" <<'PY'
import json
import pathlib
import re
import sys

config_path = pathlib.Path(sys.argv[1])
repo_root = pathlib.Path(sys.argv[2])
config = json.loads(config_path.read_text())

managers = [
    manager
    for manager in config.get("customManagers", [])
    if manager.get("customType") == "regex"
    and manager.get("description") == "Track stable Chunkah container releases"
]
if len(managers) != 1:
    raise SystemExit(f"expected one Chunkah regex manager, found {len(managers)}")

manager = managers[0]
match_strings = manager.get("matchStrings", [])
if len(match_strings) != 1:
    raise SystemExit(f"expected one Chunkah match string, found {len(match_strings)}")

# Python and JavaScript spell named capture groups differently. The rest of
# this expression uses syntax common to Python's re and Renovate's RE2 engine.
expression = re.sub(
    r"\(\?<([A-Za-z][A-Za-z0-9_]*)>",
    r"(?P<\1>",
    match_strings[0],
)
matcher = re.compile(expression)

file_patterns = []
for raw_pattern in manager.get("managerFilePatterns", []):
    if len(raw_pattern) < 2 or not raw_pattern.startswith("/") or not raw_pattern.endswith("/"):
        raise SystemExit(f"unsupported manager file pattern: {raw_pattern!r}")
    file_patterns.append(re.compile(raw_pattern[1:-1]))

files = (
    (".github/workflows/build.yml", "CHUNKAH_IMAGE: quay.io/coreos/chunkah:v9.8.7"),
    (
        "tests/e2e/run-e2e.sh",
        'CHUNKAH_IMAGE="${CHUNKAH_IMAGE:-quay.io/coreos/chunkah:v9.8.7}"',
    ),
)

for relative_path, expected_replacement in files:
    text = (repo_root / relative_path).read_text()
    matches = list(matcher.finditer(text))
    eligible = any(pattern.search(relative_path) for pattern in file_patterns)
    values = ",".join(match.group("currentValue") for match in matches)

    def replace_version(match):
        start, end = match.span("currentValue")
        return match.group(0)[: start - match.start()] + "v9.8.7" + match.group(0)[end - match.start() :]

    updated = matcher.sub(replace_version, text)
    replacement_preserved_syntax = expected_replacement in updated
    print(
        relative_path,
        str(eligible).lower(),
        len(matches),
        values,
        str(replacement_preserved_syntax).lower(),
        sep="\t",
    )
PY
); then
    _pass "Chunkah manager can be evaluated"
else
    _fail "Chunkah manager can be evaluated" "failed to load or compile its configuration"
    finish
    exit
fi

mapfile -t rows <<<"${analysis}"
assert_eq "both Chunkah pin files were analyzed" "2" "${#rows[@]}"

IFS=$'\t' read -r workflow_path workflow_eligible workflow_matches workflow_value workflow_replaced <<<"${rows[0]}"
assert_eq "first result is the workflow pin" ".github/workflows/build.yml" "${workflow_path}"
assert_eq "workflow path is selected by managerFilePatterns" "true" "${workflow_eligible}"
assert_eq "workflow contains exactly one Chunkah match" "1" "${workflow_matches}"
assert_eq "workflow replacement changes only the version capture" "true" "${workflow_replaced}"

IFS=$'\t' read -r script_path script_eligible script_matches script_value script_replaced <<<"${rows[1]}"
assert_eq "second result is the e2e script pin" "tests/e2e/run-e2e.sh" "${script_path}"
assert_eq "e2e script path is selected by managerFilePatterns" "true" "${script_eligible}"
assert_eq "e2e script contains exactly one Chunkah match" "1" "${script_matches}"
assert_eq "e2e replacement preserves Bash parameter expansion" "true" "${script_replaced}"
assert_eq "workflow and e2e Chunkah pins agree" "${workflow_value}" "${script_value}"

finish
