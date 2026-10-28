#!/usr/bin/env bash
#
# Runs the fleet's shared refusal corpus against this repository's Bash gate,
# .claude/hooks/gate-git-diff.sh.
#
# Six repositories each carry their own copy of the PreToolUse hook that keeps
# allow-listed commands such as `git diff` and `gh pr view` from reading `.env`
# or writing a file. The copies are separate code, in bash and Python, so a
# bypass fixed in one repository says nothing about the other five
# (Danathar/atomic-image-builder#609). tests/fixtures/gate-refusal-corpus.json
# is the one table they share: each row is a command, the verdict every gate
# has to reach, and the command prefixes the row depends on. This file runs the
# rows this repository's allow list makes reachable, so a newly found bypass is
# one new row, and every repository that allows the command fails until its
# gate refuses it.
#
# The canonical copy lives in Danathar/atomic-image-builder, whose
# docs/gate-refusal-corpus.md documents the row format. The copy here is pinned
# by SHA-256 below: change a row there, then copy the file here and update the
# pin.
#
# The hook is run the way Claude Code runs it, through the command
# .claude/settings.json registers, so a registration that stops pointing at the
# gate fails here as well. Exit 2, or a "deny" decision on stdout, is a refusal;
# exit 0 with no decision is an allow.

set -uo pipefail

TEST_NAME="test-gate-refusal-corpus"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

CORPUS="${REPO_ROOT}/tests/fixtures/gate-refusal-corpus.json"
SETTINGS="${REPO_ROOT}/.claude/settings.json"

# SHA-256 of the canonical tests/fixtures/gate-refusal-corpus.json in
# Danathar/atomic-image-builder. Copy the file from there; never edit it here.
CANONICAL_SHA256="4478c969cb74cadb73fddf71d56cb90b0b1c986a20efae5adf8720f134caf565"

for required in "${CORPUS}" "${SETTINGS}"; do
    assert_file_exists "${required#"${REPO_ROOT}/"} is present" "${required}"
done

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# The command prefix each wildcard Bash(...) allow rule covers, one per line.
# The fleet spells a prefix rule three ways (`git diff:*`, `git diff *`,
# `git diff*`); all three cover `git diff` and what follows it. A rule with no
# wildcard allows one exact command and covers no prefix.
allow_prefixes() {
    jq -r '
        .permissions.allow // [] | .[]
        | select(startswith("Bash(") and endswith(")"))
        | .[5:-1]
        | if endswith(":*") then .[:-2]
          elif endswith(" *") then .[:-2]
          elif endswith("*") then .[:-1]
          else empty end
    '
}

# covered PREFIX PREFIXES: a prefix rule covers PREFIX at a word boundary.
covered() {
    local prefix=$1 rule
    while IFS= read -r rule; do
        [[ -n "${rule}" ]] || continue
        if [[ "${prefix}" == "${rule}" || "${prefix}" == "${rule} "* ]]; then
            return 0
        fi
    done <<<"$2"
    return 1
}

# --- the table's shape -------------------------------------------------------

assert_eq "the copy matches the pinned canonical corpus" \
    "${CANONICAL_SHA256}" "$(sha256 "${CORPUS}")"

assert_eq "the schema version is one this file reads" \
    "1" "$(jq -r '.schema' "${CORPUS}")"

# shape_problems FILE / wrap_problems FILE print the id of every row that
# breaks the table's shape, or "row N" when the row has no string id. Each
# field's type is checked before anything reads it as that type: jq stops at
# the first error and prints nothing more, so a check that ran gsub over a
# null `command` would hide every bad row after it and pass on an empty
# answer. A filter that errors anyway prints "jq failed", never nothing.
shape_problems() {
    jq -r '
        .rows | to_entries[] | .key as $i | .value
        | select(
            (type != "object")
            or ((keys - ["wraps"]) != ["class", "command", "id", "requires", "verdict", "why"])
            or ([.id, .class, .command, .why] | any(type != "string"))
            or ((.requires | type) != "array")
            or any(.requires[]; type != "string")
            or ((.verdict == "refuse" or .verdict == "allow") | not)
            or ((.requires | length) == 0)
            or any(.requires[]; . != (. | gsub("^\\s+|\\s+$"; "")))
            or ((.command | gsub("\\s"; "")) == "")
            or ((.why | gsub("\\s"; "")) == "")
          )
        | if type == "object" and (.id | type) == "string" then .id else "row \($i)" end
    ' "$1" || echo "jq failed"
}

# `wraps` (optional) names a wrapper no allow rule covers, such as `flock` in
# `flock /tmp/l git diff ...`. It is the command's first word, and never the
# first word of a prefix the row requires, or the row would run only where the
# wrapper itself is allowed. A row without it is read as before. Rows
# shape_problems reports are skipped here: it has already named them.
wrap_problems() {
    jq -r '
        .rows | to_entries[] | .key as $i | .value
        | select(type == "object" and has("wraps"))
        | select((.command | type) == "string" and (.requires | type) == "array")
        | .wraps as $w
        | select(
            ($w | type) != "string"
            or ($w | test("^\\S+$") | not)
            or (.command | startswith($w + " ") | not)
            or any(.requires[]; type == "string" and split(" ")[0] == $w)
          )
        | if (.id | type) == "string" then .id else "row \($i)" end
    ' "$1" || echo "jq failed"
}

assert_eq "every row has exactly the documented fields" "" "$(shape_problems "${CORPUS}")"
assert_eq "every wrapped row starts with the wrapper it names" "" "$(wrap_problems "${CORPUS}")"
assert_eq "the corpus has wrapped rows for the check above to read" \
    "true" "$(jq -r '[.rows[] | select(has("wraps"))] | length > 0' "${CORPUS}")"

# The canonical table is well formed, so the two checks above pass on it
# whatever they test. Each bad row below must be reported by id, and the row
# after it too, so a check that stops early, or forgets a field's type, fails
# here instead of on the next copy of the table.
good_row='{"class": "c", "command": "git diff x", "id": "good", "requires": ["git diff"], "verdict": "refuse", "why": "w"}'
wrap_row='{"class": "c", "command": "flock /tmp/l git diff x", "id": "good", "requires": ["git diff"], "verdict": "refuse", "why": "w", "wraps": "flock"}'
# check_bad_row LABEL CHECK BASE PATCH: BASE with PATCH merged in, as id "bad",
# followed by a row with an empty command, id "next".
check_bad_row() {
    local label=$1 check=$2 base=$3 patch=$4 table got want
    table="$(mktemp)"
    jq -n --argjson g "${good_row}" --argjson b "${base}" --argjson p "${patch}" '
        {schema: 1, rows: [$g, ($b + {id: "bad"} + $p), ($g + {id: "next", command: " "})]}
    ' >"${table}"
    got="$("${check}" "${table}" | tr '\n' ' ')"
    rm -f "${table}"
    want="bad "
    [[ "${check}" == shape_problems ]] && want="bad next "
    assert_eq "${check} reports ${label}" "${want}" "${got}"
}
check_bad_row "a null command" shape_problems "${good_row}" '{"command": null}'
check_bad_row "a numeric command" shape_problems "${good_row}" '{"command": 5}'
check_bad_row "a null why" shape_problems "${good_row}" '{"why": null}'
check_bad_row "a numeric class" shape_problems "${good_row}" '{"class": 1}'
check_bad_row "requires as a string" shape_problems "${good_row}" '{"requires": "git diff"}'
check_bad_row "a numeric prefix in requires" shape_problems "${good_row}" '{"requires": [5]}'
check_bad_row "empty requires" shape_problems "${good_row}" '{"requires": []}'
check_bad_row "a padded prefix" shape_problems "${good_row}" '{"requires": [" git diff"]}'
check_bad_row "an unknown verdict" shape_problems "${good_row}" '{"verdict": "warn"}'
check_bad_row "a blank why" shape_problems "${good_row}" '{"why": "  "}'
check_bad_row "an extra field" shape_problems "${good_row}" '{"extra": 1}'
check_bad_row "a numeric wraps" wrap_problems "${wrap_row}" '{"wraps": 3}'
check_bad_row "a two-word wraps" wrap_problems "${wrap_row}" '{"wraps": "flock -n", "command": "flock -n /tmp/l git diff x"}'
check_bad_row "a wraps the command does not start with" wrap_problems "${wrap_row}" '{"wraps": "timeout"}'
check_bad_row "a wraps that only prefixes the first word" wrap_problems "${wrap_row}" '{"command": "flockx /tmp/l git diff x"}'
check_bad_row "a wraps a required prefix starts with" wrap_problems "${wrap_row}" '{"requires": ["flock /tmp/l"]}'

numeric_id="$(mktemp)"
jq -n --argjson g "${good_row}" '{schema: 1, rows: [$g, ($g + {id: 7}), "not a row"]}' >"${numeric_id}"
assert_eq "shape_problems names a row without a string id by its index" \
    "row 1 row 2 " "$(shape_problems "${numeric_id}" | tr '\n' ' ')"
rm -f "${numeric_id}"
assert_eq "shape_problems says so when jq cannot read the table" \
    "jq failed" "$(echo '{"rows": 1}' | shape_problems /dev/stdin 2>/dev/null)"
assert_eq "wrap_problems says so when jq cannot read the table" \
    "jq failed" "$(echo '{"rows": 1}' | wrap_problems /dev/stdin 2>/dev/null)"
assert_eq "shape_problems passes a well-formed row" "" \
    "$(jq -n --argjson g "${good_row}" '{schema: 1, rows: [$g]}' | shape_problems /dev/stdin)"
assert_eq "wrap_problems passes a well-formed wrapped row" "" \
    "$(jq -n --argjson w "${wrap_row}" '{schema: 1, rows: [$w]}' | wrap_problems /dev/stdin)"

assert_eq "row ids are unique" \
    "$(jq -r '.rows | length' "${CORPUS}")" \
    "$(jq -r '[.rows[].id] | unique | length' "${CORPUS}")"

# Refusals alone would pass a gate that refuses everything, and a gate that
# refuses everything gets switched off.
assert_eq "both verdicts are present" \
    "allow refuse" "$(jq -r '[.rows[].verdict] | unique | join(" ")' "${CORPUS}")"

# --- how an allow rule is read -----------------------------------------------

for rule in 'Bash(git diff:*)' 'Bash(git diff *)' 'Bash(git diff*)'; do
    prefixes="$(jq -n --arg r "${rule}" '{permissions: {allow: [$r]}}' | allow_prefixes)"
    if covered "git diff" "${prefixes}"; then
        _pass "${rule} covers git diff"
    else
        _fail "${rule} covers git diff" "prefixes: ${prefixes}"
    fi
done

prefixes="$(jq -n '{permissions: {allow: ["Bash(ruff check)"]}}' | allow_prefixes)"
if covered "ruff check" "${prefixes}"; then
    _fail "an exact rule covers no prefix"
else
    _pass "an exact rule covers no prefix"
fi

prefixes="$(jq -n '{permissions: {allow: ["Bash(gh pr:*)"]}}' | allow_prefixes)"
if covered "gh pr view" "${prefixes}" && ! covered "gh prx view" "${prefixes}"; then
    _pass "a prefix is covered only at a word boundary"
else
    _fail "a prefix is covered only at a word boundary"
fi

# --- every reachable row through the registered hook -------------------------

prefixes="$(allow_prefixes <"${SETTINGS}")"
hook="$(jq -r '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[0].command][0] // empty' "${SETTINGS}")"
if [[ -n "${hook}" ]]; then
    _pass ".claude/settings.json registers a PreToolUse hook for Bash"
else
    _fail ".claude/settings.json registers a PreToolUse hook for Bash"
fi

# The rows run in a scratch repository with two commits and a copy of .claude/,
# not in this checkout. CI checks this repository out at depth 1, where HEAD~1
# names no commit, so the gate reads `git diff HEAD~1 HEAD` as two plain-file
# operands and refuses it -- correctly for that checkout, but it fails the
# allow-diff-range row, whose verdict assumes the history an agent's working
# clone has.
project="$(mktemp -d)"
cp -R "${REPO_ROOT}/.claude" "${project}/.claude"
(
    cd "${project}" || exit 1
    git init -q . &&
        git -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m first &&
        git -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m second
) </dev/null >/dev/null 2>&1
if [[ "$(git -C "${project}" rev-list --count HEAD 2>/dev/null)" == 2 ]]; then
    _pass "the scratch repository the rows run in has a HEAD~1"
else
    _fail "the scratch repository the rows run in has a HEAD~1"
fi

applied=0
while IFS= read -r row; do
    id="$(jq -r '.id' <<<"${row}")"
    verdict="$(jq -r '.verdict' <<<"${row}")"
    command="$(jq -r '.command' <<<"${row}")"
    why="$(jq -r '.why' <<<"${row}")"

    reachable=1
    while IFS= read -r prefix; do
        covered "${prefix}" "${prefixes}" || reachable=0
    done < <(jq -r '.requires[]' <<<"${row}")
    [[ "${reachable}" -eq 1 ]] || continue
    applied=$((applied + 1))

    out_file="$(mktemp)"
    err_file="$(mktemp)"
    jq -cn --arg c "${command}" '{tool_name: "Bash", tool_input: {command: $c}}' |
        (cd "${project}" && CLAUDE_PROJECT_DIR="${project}" bash -c "${hook}") \
            >"${out_file}" 2>"${err_file}"
    rc=$?
    stdout="$(cat "${out_file}")"
    stderr="$(cat "${err_file}")"
    rm -f "${out_file}" "${err_file}"

    if [[ "${rc}" -ne 0 && "${rc}" -ne 2 ]]; then
        _fail "row ${id}: the hook exits 0 or 2" "exit ${rc}, stderr: ${stderr:0:200}"
        continue
    fi
    if [[ "${rc}" -eq 2 || "${stdout}" == *'"deny"'* ]]; then
        got=refuse
    else
        got=allow
    fi
    if [[ "${got}" == "${verdict}" ]]; then
        _pass "row ${id}: ${verdict} ${command}"
    else
        _fail "row ${id}: ${verdict} ${command}" "the gate reached ${got}: ${why}"
    fi
done < <(jq -c '.rows[]' "${CORPUS}")
rm -rf "${project}"

# If the allow list stopped covering `git diff`, every row would be skipped and
# the verdict checks above would pass on nothing.
if [[ "${applied}" -ge 20 ]]; then
    _pass "enough rows apply here to mean something (${applied})"
else
    _fail "enough rows apply here to mean something" "only ${applied} rows apply"
fi

finish
