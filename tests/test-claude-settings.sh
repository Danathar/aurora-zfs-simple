#!/usr/bin/env bash
#
# Tests for `.claude/settings.json`.
#
# That file is not documentation. It holds two things that run:
#
#   1. a `PostToolUse` hook -- a shell one-liner that lints every `*.sh` an
#      agent writes and, by exiting 2, blocks the edit from being accepted; and
#   2. a permission table whose `deny` list is the only thing standing between
#      an agent and `cosign.key`, `podman system prune` and `git push --force`.
#
# Both fail open, and both fail silently:
#
#   * a settings file that does not parse as JSON is ignored in full, so a
#     stray comma takes every `deny` rule with it and nothing says so;
#   * a misspelled event name (`PostToolUSe`) or tool name registers a hook
#     that is never dispatched;
#   * the hook's `cd "$CLAUDE_PROJECT_DIR"` is load-bearing. `shellcheck -x`
#     resolves a `# shellcheck source=tests/lib/assert.sh` directive relative to
#     the working directory, so without the `cd` every tests/*.sh edit comes
#     back as SC1091 plus a cascade of SC2034s -- a blocking failure on a file
#     CI calls clean. Drop the `-x` instead and the same thing happens;
#   * drop the `|| exit 0` shellcheck-presence guard and every edit fails on a
#     machine without shellcheck.
#
# None of that shows up in a review of the diff, because the diff is one long
# line of JSON-escaped shell. So this file extracts that command and *runs* it,
# against a recording `shellcheck` stub: the stub's exit code is propagated, its
# argv and working directory are asserted, and the cases where it must not be
# invoked at all check that it was not.
#
# The band that needs the real tool -- the `source=` resolution the `cd` exists
# for -- runs only when shellcheck is installed, the same skip
# tests/test-shell-syntax.sh takes.
#
# Vacuity guard: if the extraction returned nothing, `bash -c ''` would exit 0
# and the "a finding blocks the edit" case would fail. It is asserted directly
# as well.

set -uo pipefail

TEST_NAME="test-claude-settings"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

SETTINGS="${REPO_ROOT}/.claude/settings.json"

assert_file_exists "the repo ships .claude/settings.json" "${SETTINGS}"
if [[ ! -f "${SETTINGS}" ]]; then
    finish
    exit
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# --- 1. the file parses, and every key it uses is a key that is read ---------
#
# Claude Code ignores a settings file it cannot parse, and ignores individual
# keys it does not recognise, in both cases without a message. A typo therefore
# reads exactly like a working configuration.

if jq -e . "${SETTINGS}" >/dev/null 2>&1; then
    _pass "settings.json is valid JSON"
else
    _fail "settings.json is valid JSON" \
        "jq: $(jq . "${SETTINGS}" 2>&1 | head -1)" \
        "an unparseable settings file is ignored in full, deny rules included"
    finish
    exit
fi

# Known top-level keys, plus the `_note_*` convention this file uses to carry
# the reasoning behind two of its rules.
unknown_top=""
while IFS= read -r key; do
    case "${key}" in
    \$schema | permissions | hooks | env | model | statusLine | _note_*) ;;
    *) unknown_top+="${key} " ;;
    esac
done < <(jq -r 'keys[]' "${SETTINGS}")
assert_eq "every top-level key is one Claude Code reads" "" "${unknown_top% }"

unknown_perm=""
while IFS= read -r key; do
    case "${key}" in
    allow | ask | deny | additionalDirectories | defaultMode) ;;
    *) unknown_perm+="${key} " ;;
    esac
done < <(jq -r '.permissions | keys[]' "${SETTINGS}")
assert_eq "and every permissions key is one Claude Code reads" "" "${unknown_perm% }"

unknown_event=""
while IFS= read -r key; do
    case "${key}" in
    PreToolUse | PostToolUse | UserPromptSubmit | Notification | Stop | \
        SubagentStop | PreCompact | SessionStart | SessionEnd) ;;
    *) unknown_event+="${key} " ;;
    esac
done < <(jq -r '.hooks | keys[]' "${SETTINGS}")
assert_eq "and every hook event name is one Claude Code dispatches" \
    "" "${unknown_event% }"

# --- 2. the permission table --------------------------------------------

rules() { jq -r --arg list "$1" '.permissions[$list][]' "${SETTINGS}"; }

ALLOW="$(rules allow)"
ASK="$(rules ask)"
DENY="$(rules deny)"

for list in ALLOW ASK DENY; do
    count="$(grep -c . <<<"${!list}")"
    if [[ "${count}" -gt 0 ]]; then
        _pass "the ${list,,} list is not empty (${count} rules)"
    else
        _fail "the ${list,,} list is not empty" \
            "an empty list makes every rule assertion below vacuous"
    fi
done

# A rule Claude Code cannot parse is dropped, so the shape is part of the
# contract, not a style preference.
malformed=""
while IFS= read -r rule; do
    [[ -z "${rule}" ]] && continue
    [[ "${rule}" =~ ^(Bash|Read|Edit|Write|WebFetch|WebSearch|Glob|Grep|Task|NotebookEdit|MultiEdit|mcp__[A-Za-z0-9_]+)\(.+\)$ ]] ||
        malformed+="${rule} "
done <<<"${ALLOW}"$'\n'"${ASK}"$'\n'"${DENY}"
assert_eq "every rule is Tool(pattern) with a tool name Claude Code knows" \
    "" "${malformed% }"

# The same string in two lists is a contradiction whose winner depends on
# precedence rules nobody reading this file should have to know.
dup="$(printf '%s\n%s\n%s\n' "${ALLOW}" "${ASK}" "${DENY}" | grep . | sort | uniq -d | tr '\n' ' ')"
assert_eq "no rule appears in two lists" "" "${dup% }"

# The command prefix a `Bash(cmd:*)` rule matches, or the whole command for an
# exact rule.
bash_prefix() {
    local rule=$1 inner
    [[ "${rule}" == Bash\(*\) ]] || return 1
    inner="${rule#Bash(}"
    inner="${inner%)}"
    printf '%s\n' "${inner%:\*}"
}

# An `allow` rule that covers a gated command silently un-gates it: the agent
# stops being asked before `podman rmi` because someone allowed `podman`.
shadowed=""
while IFS= read -r allow_rule; do
    [[ -z "${allow_rule}" ]] && continue
    allow_cmd="$(bash_prefix "${allow_rule}")" || continue
    [[ -n "${allow_cmd}" ]] || continue
    while IFS= read -r gated_rule; do
        [[ -z "${gated_rule}" ]] && continue
        gated_cmd="$(bash_prefix "${gated_rule}")" || continue
        if [[ "${gated_cmd}" == "${allow_cmd}" || "${gated_cmd}" == "${allow_cmd} "* ]]; then
            shadowed+="${allow_rule} covers ${gated_rule}; "
        fi
    done <<<"${ASK}"$'\n'"${DENY}"
done <<<"${ALLOW}"
assert_eq "no allow rule covers a command the ask or deny list gates" \
    "" "${shadowed}"

# The two `_note_*` keys record decisions that are invisible in the rule list
# itself. Each is asserted against the rules it describes, so the note and the
# table cannot drift apart.
assert_contains "the gh api decision is written down" \
    "$(jq -r '._note_gh_api // ""' "${SETTINGS}")" "never \`allow\`"
assert_not_contains "and gh api is in no allow rule" "${ALLOW}" "Bash(gh api"
assert_contains "gh api is in ask" "${ASK}" "Bash(gh api:*)"
assert_contains "and so is the workflow-dispatch verb the note names" \
    "${ASK}" "Bash(gh workflow run:*)"

assert_contains "the podman ps decision is written down" \
    "$(jq -r '._note_podman_ps // ""' "${SETTINGS}")" "--sync"
assert_contains "podman ps is allowed, as that note says" \
    "${ALLOW}" "Bash(podman ps:*)"
for verb in "podman build" "podman rmi" "podman run"; do
    assert_contains "the note's \"gated separately\" holds for ${verb}" \
        "${ASK}" "Bash(${verb}:*)"
done
for verb in "podman image prune" "podman system prune" "podman rmi -a" \
    "podman rmi --all" "buildah rmi --all" "buildah rm --all"; do
    assert_contains "and ${verb} is denied outright" "${DENY}" "Bash(${verb}:*)"
done

# `git diff` stays allowed -- it is the most common read here -- and the one
# form of it that reads arbitrary files is gated by the hook exercised in
# section 7 rather than by a rule. The note carries that reasoning; assert both
# ends so neither can move without the other.
GIT_DIFF_NOTE="$(jq -r '._note_git_diff // ""' "${SETTINGS}")"
assert_contains "the git diff decision is written down" \
    "${GIT_DIFF_NOTE}" "--no-index"
assert_contains "git diff is allowed, as that note says" \
    "${ALLOW}" "Bash(git diff:*)"
# A prefix rule for the flag would read like a control and gate one flag
# ordering, which is the note's whole argument against writing one.
assert_not_contains "and no deny rule claims to gate that flag by prefix" \
    "${DENY}" "git diff --no-index"

# --- 3. the deny rules that name files, held against the tree ---------------

assert_contains "reading the signing key is denied" "${DENY}" "Read(./cosign.key)"
assert_contains "and signing with it is denied" "${DENY}" "Bash(cosign sign:*)"

tracked="$(cd "${REPO_ROOT}" && git ls-files)"
for secret in cosign.key .env; do
    if grep -qx -- "${secret}" <<<"${tracked}"; then
        _fail "${secret} is not tracked" \
            "the Read deny rule is the second line of defence, not the first"
    else
        _pass "${secret} is not tracked"
    fi
done

# .gitignore is the first line; the deny rule only matters because a key can
# exist in the worktree without being tracked.
ignored="$(cat "${REPO_ROOT}/.gitignore" 2>/dev/null)"
assert_contains "cosign.key is gitignored as well as read-denied" \
    "${ignored}" "cosign.key"

# The public half is tracked, which is what makes the private half something
# this repo can actually have on disk.
assert_file_exists "the repo tracks the public verification key" \
    "${REPO_ROOT}/cosign.pub"

# The one allow rule that names a repo path has to keep naming a real one.
runner="$(sed -E 's/^Bash\((.*)\)$/\1/' <<<"$(grep -F 'run-tests.sh)' <<<"${ALLOW}" | head -1)")"
assert_eq "the allow list names this suite's entry point" \
    "./tests/run-tests.sh" "${runner}"
if [[ -x "${REPO_ROOT}/tests/run-tests.sh" ]]; then
    _pass "and that entry point exists and is executable"
else
    _fail "and that entry point exists and is executable" \
        "allowing a path that moved turns every suite run back into a prompt"
fi

# Allowing a script is allowing whatever that script runs. Every other rule here
# gates the Bash tool's argv; none of them gates what an approved command then
# executes, so the runner's own argument handling is part of this table whether
# it is written here or not. It is asserted by running it: a path outside
# tests/ has to be refused rather than executed.
assert_contains "the run-tests allow rule's reach is written down" \
    "$(jq -r '._note_run_tests // ""' "${SETTINGS}")" "argv"

PAYLOAD="${WORK}/payload-marker"
PAYLOAD_SH="${WORK}/test-payload.sh"
cat >"${PAYLOAD_SH}" <<PAYLOAD_STUB
#!/usr/bin/env bash
: >"${PAYLOAD}"
exit 0
PAYLOAD_STUB
chmod +x "${PAYLOAD_SH}"

runner_out="$("${REPO_ROOT}/tests/run-tests.sh" "${PAYLOAD_SH}" 2>&1)"
runner_status=$?
assert_eq "the runner refuses a path outside its own directory" \
    "1" "${runner_status}"
assert_contains "and says why" "${runner_out}" "not a test file in"
assert_file_missing "and never executes it" "${PAYLOAD}"

# --- 4. the PostToolUse hook: wiring ----------------------------------------

assert_eq "exactly one PostToolUse matcher is registered" \
    "1" "$(jq -r '.hooks.PostToolUse | length' "${SETTINGS}")"
assert_eq "with exactly one hook on it" \
    "1" "$(jq -r '.hooks.PostToolUse[0].hooks | length' "${SETTINGS}")"
assert_eq "and it is a command hook" \
    "command" "$(jq -r '.hooks.PostToolUse[0].hooks[0].type' "${SETTINGS}")"

MATCHER="$(jq -r '.hooks.PostToolUse[0].matcher' "${SETTINGS}")"
# The matcher is a regex over tool names. Every tool that can put a *.sh file
# on disk has to be in it, or that edit is linted by nothing.
for tool in Edit Write; do
    if [[ "${tool}" =~ ^(${MATCHER})$ ]]; then
        _pass "the matcher selects ${tool}, which writes files"
    else
        _fail "the matcher selects ${tool}, which writes files" \
            "matcher: ${MATCHER}"
    fi
done
if [[ "Read" =~ ^(${MATCHER})$ ]]; then
    _fail "and does not select a read-only tool" "matcher: ${MATCHER}"
else
    _pass "and does not select a read-only tool"
fi

HOOK_COMMAND="$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "${SETTINGS}")"
if [[ -n "${HOOK_COMMAND}" && "${HOOK_COMMAND}" == *shellcheck* ]]; then
    _pass "the hook command was extracted and runs shellcheck"
else
    _fail "the hook command was extracted and runs shellcheck" \
        "extracted: ${HOOK_COMMAND:-<empty>}" \
        "every execution case below would pass vacuously on an empty command"
    finish
    exit
fi

# --- 5. the hook, executed against a recording shellcheck stub --------------

STUB_DIR="${WORK}/bin"
mkdir -p "${STUB_DIR}"

# `$RECORD` is written by the stub only when the hook actually invokes it, so
# its absence is the assertion for the cases that must not lint.
RECORD="${WORK}/shellcheck.record"

# `$3` picks the stream the canned output goes to: shellcheck writes findings
# to stdout but its own errors -- an unreadable file, a bad flag -- to stderr.
write_stub() {
    local exit_code=$1 output=$2 stream=${3-1}
    cat >"${STUB_DIR}/shellcheck" <<STUB
#!/usr/bin/env bash
{
    printf 'cwd\t%s\n' "\$PWD"
    printf 'argv\t%s\n' "\$*"
} >>"${RECORD}"
[[ -n "${output}" ]] && printf '%s\n' "${output}" >&${stream}
exit ${exit_code}
STUB
    chmod +x "${STUB_DIR}/shellcheck"
}

HOOK_OUT=""
HOOK_ERR=""
HOOK_STATUS=0

# Runs the hook with `$1` as the JSON payload on stdin and `$2` as
# CLAUDE_PROJECT_DIR. `$3`, when given, replaces PATH.
run_hook() {
    local payload=$1 project=$2 path=${3-"${STUB_DIR}:${PATH}"}
    rm -f "${RECORD}"
    HOOK_OUT="${WORK}/out"
    HOOK_ERR="${WORK}/err"
    # Run from a directory that is not the repo, so the `cd` in the hook is the
    # only thing that can put shellcheck in the right place.
    printf '%s' "${payload}" |
        (cd "${WORK}" && env PATH="${path}" CLAUDE_PROJECT_DIR="${project}" \
            bash -c "${HOOK_COMMAND}") >"${HOOK_OUT}" 2>"${HOOK_ERR}"
    HOOK_STATUS=$?
    HOOK_OUT="$(cat "${HOOK_OUT}")"
    HOOK_ERR="$(cat "${HOOK_ERR}")"
}

payload_for() { jq -nc --arg p "$1" '{tool_input: {file_path: $p}}'; }

recorded() { grep -F "$1" "${RECORD}" 2>/dev/null | head -1 | cut -f2-; }

# 5a. a clean script: the stub exits 0, so the edit is accepted silently.
write_stub 0 ""
run_hook "$(payload_for "${REPO_ROOT}/build_files/post-check.sh")" "${REPO_ROOT}"
assert_eq "a clean *.sh edit is accepted" "0" "${HOOK_STATUS}"
assert_eq "and says nothing" "" "${HOOK_ERR}${HOOK_OUT}"
assert_eq "shellcheck was invoked with -x and the edited path" \
    "-x ${REPO_ROOT}/build_files/post-check.sh" "$(recorded argv)"
assert_eq "and was invoked from the project directory" \
    "${REPO_ROOT}" "$(recorded cwd)"

# 5b. a finding: exit 2 is what Claude Code reads as "block and show stderr".
write_stub 1 "In x.sh line 2:
ls \$UNQUOTED
   ^------^ SC2086 (info): Double quote to prevent globbing and word splitting."
run_hook "$(payload_for "${WORK}/dirty.sh")" "${REPO_ROOT}"
assert_eq "a shellcheck finding blocks the edit" "2" "${HOOK_STATUS}"
assert_contains "and the finding is relayed on stderr, where the agent reads it" \
    "${HOOK_ERR}" "SC2086"
assert_eq "and nothing is written to stdout" "" "${HOOK_OUT}"

# 5c. shellcheck reports findings on stdout but its own failures -- a file it
# cannot read, an option it does not know -- on stderr. The hook has to capture
# both, or those come back as a blocked edit with no message attached.
write_stub 1 "shellcheck: ${WORK}/dirty.sh: openBinaryFile: does not exist" 2
run_hook "$(payload_for "${WORK}/dirty.sh")" "${REPO_ROOT}"
assert_eq "a shellcheck error on stderr blocks the edit too" "2" "${HOOK_STATUS}"
assert_contains "and that error reaches the agent" \
    "${HOOK_ERR}" "openBinaryFile"

write_stub 1 ""
run_hook "$(payload_for "${WORK}/dirty.sh")" "${REPO_ROOT}"
assert_eq "a silent non-zero exit still blocks" "2" "${HOOK_STATUS}"

# 5d. files the repo's shellcheck gate does not cover must not be linted.
# tests/test-shell-syntax.sh selects `-name '*.sh'`; the hook's `case` has to
# select the same set or the two disagree about what "clean" means.
write_stub 1 "should never run"
for path in "${REPO_ROOT}/README.md" "${REPO_ROOT}/renovate.json" \
    "${REPO_ROOT}/Containerfile" "${REPO_ROOT}/.claude/settings.json"; do
    run_hook "$(payload_for "${path}")" "${REPO_ROOT}"
    assert_eq "editing $(basename "${path}") is accepted" "0" "${HOOK_STATUS}"
    assert_file_missing "and shellcheck is not invoked for it" "${RECORD}"
done

# 5e. a payload with no file_path at all -- PostToolUse fires for every
# matched tool, and `jq // empty` is what keeps a Bash result from linting "".
for payload in '{}' '{"tool_input":{}}' '{"tool_input":{"file_path":""}}'; do
    run_hook "${payload}" "${REPO_ROOT}"
    assert_eq "a payload without a file path is accepted (${payload})" \
        "0" "${HOOK_STATUS}"
    assert_file_missing "and lints nothing (${payload})" "${RECORD}"
done

# 5f. a path with a space in it: unquoted, the stub would be handed two args.
write_stub 0 ""
spaced="${WORK}/a dir/with space.sh"
mkdir -p "$(dirname "${spaced}")"
: >"${spaced}"
run_hook "$(payload_for "${spaced}")" "${REPO_ROOT}"
assert_eq "a path containing a space is passed as one argument" \
    "-x ${spaced}" "$(recorded argv)"

# 5g. no shellcheck on PATH: the hook skips rather than failing every edit on a
# machine that does not have the tool -- the same choice test-shell-syntax.sh
# makes. The PATH still carries `jq`, which the hook needs to read its payload.
# `env` resolves `bash` through the PATH it is given, so that has to be there
# too; nothing else is.
JQ_ONLY="${WORK}/jq-only"
mkdir -p "${JQ_ONLY}"
ln -sf "$(command -v jq)" "${JQ_ONLY}/jq"
ln -sf "$(command -v bash)" "${JQ_ONLY}/bash"
write_stub 1 "should never run"
run_hook "$(payload_for "${WORK}/dirty.sh")" "${REPO_ROOT}" "${JQ_ONLY}"
assert_eq "an edit is accepted when shellcheck is not installed" \
    "0" "${HOOK_STATUS}"
assert_file_missing "and nothing is recorded" "${RECORD}"

# 5h. an unusable CLAUDE_PROJECT_DIR. The `|| exit 0` is inside the command
# substitution, so it ends the subshell, not the hook: the edit is accepted and
# nothing is linted. That is the fail-open direction, and it is deliberate --
# pinned here so a change to it is a decision rather than a side effect.
write_stub 1 "should never run"
run_hook "$(payload_for "${WORK}/dirty.sh")" "${WORK}/no-such-dir"
assert_eq "an unusable project directory skips the lint rather than blocking" \
    "0" "${HOOK_STATUS}"
assert_file_missing "and shellcheck is never reached" "${RECORD}"

# --- 6. the band that needs the real tool -----------------------------------
#
# 5a asserts that the hook runs shellcheck *from the project directory*. This
# is why that matters: `-x` resolves a `source=` directive relative to the
# working directory, so the same file is clean from the repo root and a
# blocking failure from anywhere else.

if command -v shellcheck >/dev/null 2>&1; then
    subject="${REPO_ROOT}/tests/test-post-check.sh"
    directive="$(grep -m1 '^# shellcheck source=' "${subject}")"
    assert_eq "the subject file carries a repo-root-relative source directive" \
        "# shellcheck source=tests/lib/assert.sh" "${directive}"

    run_hook "$(payload_for "${subject}")" "${REPO_ROOT}" "${PATH}"
    assert_eq "the real shellcheck accepts a committed test file" \
        "0" "${HOOK_STATUS}"
    assert_eq "and reports nothing" "" "${HOOK_ERR}${HOOK_OUT}"

    run_hook "$(payload_for "${subject}")" "${WORK}" "${PATH}"
    assert_eq "the same file fails when linted from anywhere else" \
        "2" "${HOOK_STATUS}"
    assert_contains "because the sourced file stops resolving" \
        "${HOOK_ERR}" "SC1091"

    # The hook's verdict has to agree with the gate CI enforces, or a file the
    # hook blocks still lands and a file it accepts still fails the suite.
    cat >"${WORK}/gate.sh" <<'DIRTY'
#!/usr/bin/env bash
ls $UNQUOTED_PATH
DIRTY
    run_hook "$(payload_for "${WORK}/gate.sh")" "${REPO_ROOT}" "${PATH}"
    gate_output="$(cd "${REPO_ROOT}" && shellcheck -x "${WORK}/gate.sh" 2>&1)"
    assert_eq "the hook blocks what test-shell-syntax.sh's gate rejects" \
        "2" "${HOOK_STATUS}"
    if [[ -n "${gate_output}" ]]; then
        _pass "and that gate does reject it"
    else
        _fail "and that gate does reject it" \
            "shellcheck -x produced no output for the dirty fixture"
    fi
else
    printf '  skip real-shellcheck band (not installed)\n'
fi

# --- 7. the PreToolUse hook: the one allowed command that reads any file -----
#
# `Bash(git diff:*)` is on the allow list, so `git diff` runs with any arguments
# and no prompt. `--no-index` makes git compare two paths as plain files rather
# than as repository content, which turns that pre-approved command into a
# reader of anything this uid can open -- including `cosign.key` and a `.env`,
# whose `Read(...)` deny rules gate the Read tool and say nothing about Bash.
#
# No rule in the table closes it: patterns match by prefix and flags may appear
# in any order, so a narrower allow admits the flag anyway and a deny for it
# catches one spelling of the command. A hook can, because it is handed the
# whole command string. So the block below is asserted the way section 5 asserts
# the other hook -- by running it.

# The capability first, against a fixture rather than a claim, so the rest of
# this section is visibly about something real. `--no-index` exits 1 when the
# files differ, which is the normal case here.
NO_INDEX_FIXTURE="${WORK}/decoy-secret"
printf 'DECOY-SECRET-BYTES\n' >"${NO_INDEX_FIXTURE}"
no_index_out="$(git diff --no-index -- /dev/null "${NO_INDEX_FIXTURE}" 2>&1 || true)"
assert_contains "git diff --no-index prints the contents of a file git does not track" \
    "${no_index_out}" "DECOY-SECRET-BYTES"

# And with no flag at all. Git enters the same mode on its own once two
# operands are given and one of them is not repository content, which is the
# form the first version of this hook did not see.
implicit_out="$(cd "${REPO_ROOT}" && git diff /dev/null "${NO_INDEX_FIXTURE}" 2>&1 || true)"
assert_contains "and prints them with no --no-index flag present" \
    "${implicit_out}" "DECOY-SECRET-BYTES"

assert_eq "exactly one PreToolUse matcher is registered" \
    "1" "$(jq -r '.hooks.PreToolUse | length' "${SETTINGS}")"
assert_eq "with exactly one hook on it" \
    "1" "$(jq -r '.hooks.PreToolUse[0].hooks | length' "${SETTINGS}")"
assert_eq "and it is a command hook" \
    "command" "$(jq -r '.hooks.PreToolUse[0].hooks[0].type' "${SETTINGS}")"

PRE_MATCHER="$(jq -r '.hooks.PreToolUse[0].matcher' "${SETTINGS}")"
if [[ "Bash" =~ ^(${PRE_MATCHER})$ ]]; then
    _pass "the matcher selects Bash, which is where the command runs"
else
    _fail "the matcher selects Bash, which is where the command runs" \
        "matcher: ${PRE_MATCHER}"
fi

PRE_COMMAND="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "${SETTINGS}")"
if [[ -n "${PRE_COMMAND}" && "${PRE_COMMAND}" == *gate-git-diff.sh* ]]; then
    _pass "the hook command was extracted and names the gate it runs"
else
    _fail "the hook command was extracted and names the gate it runs" \
        "extracted: ${PRE_COMMAND:-<empty>}" \
        "every execution case below would pass vacuously on an empty command"
    finish
    exit
fi

# The settings entry names a file. A path that does not exist, or one nothing
# can execute, leaves every case below asserting a gate that never runs.
assert_file_exists "the gate the settings entry names is in the tree" \
    "${REPO_ROOT}/.claude/hooks/gate-git-diff.sh"
if [[ -x "${REPO_ROOT}/.claude/hooks/gate-git-diff.sh" ]]; then
    _pass "and it is executable"
else
    _fail "and it is executable" \
        "Claude Code cannot run it, so Bash calls go uninspected"
fi

PRE_OUT=""
PRE_ERR=""
PRE_STATUS=0

# Runs the PreToolUse hook with `$1` as the JSON payload on stdin.
run_pre() {
    local payload=$1
    PRE_OUT="${WORK}/pre-out"
    PRE_ERR="${WORK}/pre-err"
    printf '%s' "${payload}" |
        (cd "${REPO_ROOT}" && CLAUDE_PROJECT_DIR="${REPO_ROOT}" \
            bash -c "${PRE_COMMAND}") >"${PRE_OUT}" 2>"${PRE_ERR}"
    PRE_STATUS=$?
    PRE_OUT="$(cat "${PRE_OUT}")"
    PRE_ERR="$(cat "${PRE_ERR}")"
}

pre_payload_for() { jq -nc --arg c "$1" '{tool_input: {command: $c}}'; }

# 7a. the command from the finding. Exit 2 is what Claude Code reads as "refuse
# the call and show stderr to the agent", the same convention section 5 relies
# on for the lint hook.
run_pre "$(pre_payload_for "git diff --no-index -- /dev/null ./cosign.key")"
assert_eq "reading the signing key through git diff is refused" "2" "${PRE_STATUS}"
assert_contains "and the refusal says why, where the agent reads it" \
    "${PRE_ERR}" "--no-index"
assert_eq "and nothing is written to stdout" "" "${PRE_OUT}"

# 7b. the flag behind another flag. This is the case a `Bash(git diff
# --no-index:*)` deny rule would not match, and the reason this is a hook.
for variant in "git diff --stat --no-index a b" \
    "git diff --no-index /etc/shadow /dev/null" \
    "git grep --no-index -e x ./.env" \
    "git --no-pager diff --no-index /dev/null ./.env.local"; do
    run_pre "$(pre_payload_for "${variant}")"
    assert_eq "refused wherever the flag appears: ${variant}" "2" "${PRE_STATUS}"
done

# 7b'. and wherever the flag does not appear. Each of these reaches the same
# mode: the first three by giving git two operands that are not revisions, the
# last two by a spelling the shell rewrites into --no-index on the way.
for flagless in "git diff /dev/null ./cosign.key" \
    "git diff /dev/null /etc/shadow" \
    "git diff cosign.key .env" \
    "ls -l && git diff /dev/null ./cosign.key" \
    "git diff --no-'index' -- /dev/null ./cosign.key" \
    'git diff --no-\index -- /dev/null ./cosign.key'; do
    run_pre "$(pre_payload_for "${flagless}")"
    assert_eq "refused with no literal flag to match: ${flagless}" \
        "2" "${PRE_STATUS}"
    assert_eq "and the refusal reaches the agent: ${flagless}" \
        "0" "$([[ -n "${PRE_ERR}" ]] && printf 0 || printf 1)"
done

# 7c. the reads the allow rule exists for keep working. A hook that turned
# `git diff` back into a prompt would be traded for the one it replaced.
# Two operands are the plain-file form unless both resolve as revisions, so
# `git diff HEAD HEAD` must stay silent -- HEAD twice rather than HEAD~1 or a
# branch name, since CI checks out at depth 1 and neither of those resolves
# there.
for ordinary in "git diff" "git diff --stat" "git diff HEAD~1 -- build_files/" \
    "git diff HEAD HEAD" "git diff ./README.md" "git diff -- ./cosign.key" \
    "grep diff a.txt b.txt" \
    "git status --short" "./tests/run-tests.sh test-post-check"; do
    run_pre "$(pre_payload_for "${ordinary}")"
    assert_eq "still allowed without a prompt: ${ordinary}" "0" "${PRE_STATUS}"
    assert_eq "and silent: ${ordinary}" "" "${PRE_ERR}${PRE_OUT}"
done

# 7d. PreToolUse fires for every Bash call, so a payload shaped differently from
# the one expected must not block every command in the session. `jq // empty` is
# what keeps that from happening.
for payload in '{}' '{"tool_input":{}}' '{"tool_input":{"command":""}}'; do
    run_pre "${payload}"
    assert_eq "a payload without a command is allowed (${payload})" \
        "0" "${PRE_STATUS}"
    assert_eq "and says nothing (${payload})" "" "${PRE_ERR}${PRE_OUT}"
done

# 7e. and a payload it cannot read at all is the opposite case: the hook cannot
# tell what the call does, so it must not decide that it is safe. The first
# version read the command with jq and never checked for jq, so on a host
# without it the substitution left the variable empty and execution fell
# through to the hook's own `exit 0` -- a missing dependency silently disabling
# the only gate on this route. These settings run wherever a contributor runs
# Claude Code, not only on the CI runner.
run_pre 'not json at all'
assert_eq "an unparseable payload is refused, not waved through" "2" "${PRE_STATUS}"
assert_contains "and says why" "${PRE_ERR}" "parse"

NOJQ="${WORK}/nojq-path"
mkdir -p "${NOJQ}"
for tool in bash env git cat; do
    tool_path="$(command -v "${tool}" 2>/dev/null)" || continue
    ln -sf "${tool_path}" "${NOJQ}/${tool}"
done
nojq_err="${WORK}/nojq-err"
printf '%s' "$(pre_payload_for "git diff --no-index -- /dev/null ./cosign.key")" |
    (cd "${REPO_ROOT}" && PATH="${NOJQ}" CLAUDE_PROJECT_DIR="${REPO_ROOT}" \
        bash -c "${PRE_COMMAND}") >/dev/null 2>"${nojq_err}"
nojq_status=$?
assert_eq "a host without jq gets a refusal, not an unchecked call" \
    "2" "${nojq_status}"
assert_contains "and is told what is missing" "$(cat "${nojq_err}")" "jq"

finish
