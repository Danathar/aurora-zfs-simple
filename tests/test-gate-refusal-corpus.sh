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
CANONICAL_SHA256="8a4bf0f7118af630f2549633cb91d33a324312d5750bbc83e0f0a8489700cf71"

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

bad_rows="$(jq -r '
    .rows[]
    | select(
        (keys != ["class", "command", "id", "requires", "verdict", "why"])
        or ((.verdict == "refuse" or .verdict == "allow") | not)
        or ((.requires | length) == 0)
        or any(.requires[]; . != (. | gsub("^\\s+|\\s+$"; "")))
        or ((.command | gsub("\\s"; "")) == "")
        or ((.why | gsub("\\s"; "")) == "")
      )
    | .id
' "${CORPUS}")"
assert_eq "every row has exactly the documented fields" "" "${bad_rows}"

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
