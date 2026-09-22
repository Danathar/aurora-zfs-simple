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
implicit_out="$(cd "${REPO_ROOT}" && git diff /dev/null "${NO_INDEX_FIXTURE}" 2>&1)" || true
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

# 7b''. the spellings that carry no flag and no second revision either. Each of
# these reached the plain-file mode past the first version of this gate, which
# ended its operand scan at any `--`, skipped every dash-prefixed word, split on
# whitespace alone, and read the value half of a two-token git option as the
# subcommand. They are asserted one per line rather than as a family because
# each is a separate way for the scan to stop matching what git does.
for reach in "git diff -- /dev/null ./cosign.key" \
    "git diff -- /dev/null ./.env" \
    "git diff ./cosign.key -" \
    "git diff - ./cosign.key" \
    "ls&&git diff /dev/null ./cosign.key" \
    "true;git diff /dev/null ./cosign.key" \
    "git -C / diff /dev/null ./cosign.key" \
    "git -c core.pager=cat diff /dev/null ./cosign.key" \
    "git --git-dir=/tmp/x diff /dev/null ./cosign.key"; do
    run_pre "$(pre_payload_for "${reach}")"
    assert_eq "refused with no flag and no whitespace to match: ${reach}" \
        "2" "${PRE_STATUS}"
done

# A `..` that leaves the checkout and comes back names a file inside this
# repository, and git's own inside-or-outside test reads the spelling, so it
# enters the plain-file mode anyway. A gate that resolved the path first would
# see a tidy in-tree path and allow it, which is why the test in the hook is
# lexical. Built from the checkout's own directory name, since where a clone
# lands is not fixed.
climbed="../$(basename "${REPO_ROOT}")/cosign.key"
for climb in "git diff -- ${climbed} -" \
    "git diff -- ${climbed} ./README.md" \
    "git diff -- /dev/null ${climbed}"; do
    run_pre "$(pre_payload_for "${climb}")"
    assert_eq "a path that climbs out and back is still outside: ${climb}" \
        "2" "${PRE_STATUS}"
done

# 7b'''. the write half. `--output=FILE` sends the diff to the path it names
# instead of to stdout, so it overwrites any file this uid can reach -- and it
# belongs to the diff-generation machinery rather than to one subcommand, so
# `git log` and `git show`, both allow-listed here, reach it with the word
# `diff` nowhere in the command. No Read(...) deny rule gates a write.
for writer in "git diff --output=cosign.pub HEAD" \
    "git log -p --output=cosign.pub -1" \
    "git show --output=.claude/settings.json HEAD" \
    "git log --output cosign.pub -1" \
    "git log --grep=a|b --output=cosign.pub -1" \
    "git log -1 && git log -p --output=cosign.pub -1"; do
    run_pre "$(pre_payload_for "${writer}")"
    assert_eq "writing a file through an allow-listed git command is refused: ${writer}" \
        "2" "${PRE_STATUS}"
    assert_contains "and the refusal names the flag: ${writer}" \
        "${PRE_ERR}" "--output=FILE"
done

# 7b''''. the same two primitives, spelled so that the words the gate reads are
# not the words git receives. Bash expands braces, ANSI-C quotes and
# substitutions first, so four characters rebuild both refusals above: a brace
# makes one word into two operands, and it splits a flag name so no word here
# matches `--output` while git still gets `--output=FILE`. These are asserted
# against bash itself first, so the section is about what the shell does rather
# than about a claim.
brace_words=({/dev/null,./cosign.key})
assert_eq "bash turns one braced word into two before git sees them" \
    "2" "${#brace_words[@]}"
brace_flag=(--outpu{t,t}"=FILE")
assert_eq "and a brace inside a flag name rebuilds the flag" \
    "--output=FILE" "${brace_flag[0]}"
assert_eq "an ANSI-C quote rebuilds it too" "--output=FILE" \
    --outpu$'\x74'=FILE

for expanded in "git diff {/dev/null,./cosign.key}" \
    "git diff -- {/dev/null,./cosign.key}" \
    "git diff {,}/dev/null ./cosign.key" \
    "git log -p --outpu{t,t}=cosign.pub -1" \
    "git show --outpu{t,t}=.claude/settings.json HEAD" \
    "git log -p --outpu\$'\x74'=cosign.pub -1" \
    "git diff \$(printf '/dev/null ./cosign.key')" \
    "git diff \`printf '/dev/null ./cosign.key'\`" \
    "git diff \${OPERANDS}"; do
    run_pre "$(pre_payload_for "${expanded}")"
    assert_eq "a word the shell would rewrite is refused: ${expanded}" \
        "2" "${PRE_STATUS}"
    assert_contains "and the refusal says the shell rewrites it: ${expanded}" \
        "${PRE_ERR}" "before git sees the words"
done

# The brace half of that refusal is drawn where bash draws it. Bash expands a
# brace only when a comma or a `..` range sits inside it; any other brace is
# a literal, and git's own `@{...}` revision syntax is spelled with exactly
# that. `git diff HEAD@{1}` is the ordinary diff against the previous commit
# and touches neither primitive, so a gate that refused it was a false
# positive with a real cost. Asserted against bash first, as above. One
# operand each, so nothing here depends on the reflog this checkout happens
# to have; the last case pins that a `{` which never closes is a literal too.
# shellcheck disable=SC1083 # the literal brace is the fact being asserted
literal_words=(HEAD@{1})
assert_eq "bash leaves a brace with no comma and no range alone" \
    "HEAD@{1}" "${literal_words[0]}"
for literal in "git diff HEAD@{1}" \
    "git diff HEAD@{1} -- README.md" \
    "git log main@{upstream} -1" \
    "git rev-parse @{-1}" \
    "git log @{2.days.ago} -1" \
    "git log HEAD@{1 -1"; do
    run_pre "$(pre_payload_for "${literal}")"
    assert_eq "a brace bash would not expand is left alone: ${literal}" \
        "0" "${PRE_STATUS}"
    assert_eq "and silent: ${literal}" "" "${PRE_ERR}${PRE_OUT}"
done

# And the line errs toward refusing. `@{1,2}` reads as revision syntax and is
# two words to bash; `{x..x}` is a one-element sequence that rebuilds the
# flag; a comma nested one level down still expands (`{{a,b}}` is `{a} {b}`);
# and `${VAR}` is a runtime-built argument the hook cannot inspect, refused
# as before. Then the two spellings found in review on #200: bash pairs a `{`
# with the last `}` it can, so `{a},b}` expands to `a}` and `b}` and a depth
# counter that closed at the first `}` never saw the comma; and a quoted `;`
# inside the brace is part of the word bash expands, while the hook's
# operator split cut the word in two before the brace test saw it. Last, a
# `..` between two reflog entries has the refused shape and is refused,
# though bash would leave it alone; the message names the spelling to use.
for expanded in "git diff HEAD@{1,2}" \
    "git diff --no-inde{x..x} /dev/null ./LICENSE" \
    "git diff {{/dev/null,./cosign.key}}" \
    "git diff \${SECRET} HEAD" \
    "git diff {--src-prefix=x},--no-index} /dev/null ./cosign.key" \
    "git log {--format=%h},--output=cosign.pub} -1" \
    "git diff {/tmp/reference';',./cosign.key}" \
    "git log -p --outpu{t,'t '}=cosign.pub -1" \
    "git log HEAD@{2}..HEAD@{1}"; do
    run_pre "$(pre_payload_for "${expanded}")"
    assert_eq "a brace bash would expand is still refused: ${expanded}" \
        "2" "${PRE_STATUS}"
    assert_contains "and the refusal says the shell rewrites it: ${expanded}" \
        "${PRE_ERR}" "before git sees the words"
done
run_pre "$(pre_payload_for "git log HEAD@{2}..HEAD@{1}")"
assert_contains "the reflog-range refusal names the spelling to use" \
    "${PRE_ERR}" "HEAD~2..HEAD~1"

# The refusal is scoped to a git invocation, so a brace or a `$` in some other
# command is none of this gate's business.
for unaffected in "awk '{print \$1}' a.txt" "jq '{a:1}' x.json" \
    "jq '{a: .x, b: .y}' x.json" \
    "printf '%s\n' \${HOME}" "ls /tmp/{a,b}"; do
    run_pre "$(pre_payload_for "${unaffected}")"
    assert_eq "a brace outside a git invocation is untouched: ${unaffected}" \
        "0" "${PRE_STATUS}"
done

# The git invocation ends where bash ends it: at an unquoted `;`, `&`, `|`,
# `(`, `)`, newline or backtick. A jq or awk program in a later command of the
# same string is not a word git receives, and a hook that kept the brace scope
# open from the first `git` to the end of the string refused
# `git diff ... | jq '{a: .x, b: .y}'`, which is the ordinary way to read a
# diff into a filter. A brace before the git command is not in its scope
# either. The scope reopens at the next `git` word, so a second git command in
# the string is held to the same rule as the first, and one that is piped into
# is not excused by the command in front of it.
for later in "git diff HEAD -- docs/SECURITY-AI.md | jq '{a: .x, b: .y}'" \
    "git diff HEAD@{1} | jq '{a,b}'" \
    "git diff HEAD | awk '{print}'" \
    "jq '{a,b}' < f | git diff --stat"; do
    run_pre "$(pre_payload_for "${later}")"
    assert_eq "a brace in another command of the string is untouched: ${later}" \
        "0" "${PRE_STATUS}"
done
# shellcheck disable=SC2016 # the literal backtick is the separator under test
for second in "git log -1; git diff {a,b}" "echo x | git diff {a,b}" \
    "git log -1 && (git diff {a,b})" $'git log -1\ngit diff {a,b}' \
    'git log -1 `git diff {a,b}`'; do
    run_pre "$(pre_payload_for "${second}")"
    assert_eq "a brace in a second git command is still refused: ${second}" \
        "2" "${PRE_STATUS}"
    assert_contains "and the refusal says the shell rewrites it: ${second}" \
        "${PRE_ERR}" "before git sees the words"
done
# The scope ends only where bash ends the command. A redirection is not a
# separator, and an earlier version of the split treated every unquoted `&`
# as one: `git log 2>&1 --outpu{t,t}=cosign.pub -1` closed the brace scope at
# the `&` of `2>&1`, bash expanded the flag, and git overwrote the file
# (review on #201). `>&`, `<&`, `&>`, `&>>` and `>|` are all redirections;
# `|&` is a pipe and still ends the command. The same split feeds the operand
# scan, which counted the words of `2>&1` as diff operands and refused every
# `git diff ... 2>&1`; a redirection's descriptor and target are the shell's
# and are not counted.
for redirected in "git diff HEAD@{1} 2>&1 | jq '{a,b}'" \
    "git diff HEAD |& jq '{a,b}'" \
    "git diff HEAD 2>&1" "git diff HEAD </dev/null" "git diff HEAD < /dev/null" \
    "git diff --stat HEAD -- README.md 2>&1 | head"; do
    run_pre "$(pre_payload_for "${redirected}")"
    assert_eq "a redirection is not a separator and not an operand: ${redirected}" \
        "0" "${PRE_STATUS}"
done
for through in "git log 2>&1 --outpu{t,t}=cosign.pub -1" \
    "git diff &>/dev/null {a,b}" \
    "git diff &>>/dev/null {a,b}" \
    "git diff <&0 {a,b}" \
    "git diff 2>&1 {/dev/null,./cosign.key}" \
    "git log -1 >| out --outpu{t,t}=cosign.pub"; do
    run_pre "$(pre_payload_for "${through}")"
    assert_eq "a brace after a redirection is still git's: ${through}" \
        "2" "${PRE_STATUS}"
    assert_contains "and the refusal says the shell rewrites it: ${through}" \
        "${PRE_ERR}" "before git sees the words"
done
run_pre "$(pre_payload_for "git log -1 |& git diff {a,b}")"
assert_eq "|& is a pipe, so the second git command is its own scope" \
    "2" "${PRE_STATUS}"

# The operand scan reset at the same `&`, so `git diff 2>&1 /dev/null
# ./cosign.key` printed the key with neither operand counted. A `(` behind an
# unquoted `<` or `>` is a process substitution, not a subshell: it hands git
# a /dev/fd path as an operand, the way `$(...)` would, and reset the scan at
# its `(` instead. It is refused in a git invocation as `$(...)` is, and left
# alone in any other command.
for reset in "git diff 2>&1 /dev/null ./cosign.key" \
    "git diff /dev/null ./cosign.key 2>&1"; do
    run_pre "$(pre_payload_for "${reset}")"
    assert_eq "a redirection does not reset the operand count: ${reset}" \
        "2" "${PRE_STATUS}"
    assert_contains "and the refusal is the plain-file one: ${reset}" \
        "${PRE_ERR}" "--no-index"
done
for procsub in "git diff <(true) ./cosign.key" \
    "git diff -- ./cosign.key <(true)" \
    "cat <(git diff {a,b})"; do
    run_pre "$(pre_payload_for "${procsub}")"
    assert_eq "a process substitution in a git invocation is refused: ${procsub}" \
        "2" "${PRE_STATUS}"
done
for elsewhere in "git log -1; cat <(true)" "cat <(git log -1)" \
    "diff <(git log -1) <(git log -2)"; do
    run_pre "$(pre_payload_for "${elsewhere}")"
    assert_eq "a process substitution outside a git invocation is untouched: ${elsewhere}" \
        "0" "${PRE_STATUS}"
done

# 7b'''''. the write half again, in the shell's own spelling. Skipping a
# redirection's target (so that `2>&1` is not two operands) let `git diff HEAD
# >cosign.pub` through: bash truncates the target before git runs, and `git
# diff:*` is allow-listed without a prompt (review on zfs-kinoite-complex#215,
# the same hook; #201 merged the same split here). It is the older spelling
# of `--output=FILE` and is refused on the same ground, whatever the target:
# `>`, `>>`, `>|`, `&>`, `&>>`, `N>`, `>&FILE` (bash's older `&>FILE`) and
# `<>` (read-write, creates the file). A target that names a descriptor
# touches no path and stays allowed; so does every input redirection; so does
# a redirection on another command of the same string, which is that
# command's own.
for writer in "git diff HEAD >cosign.pub" \
    "git diff HEAD > cosign.pub" \
    "git log -1 >> out" \
    "git diff 2>err" \
    "git diff &>/dev/null" \
    "git diff &>>/dev/null" \
    "git show HEAD >| x" \
    "git diff HEAD > .claude/settings.json" \
    "git diff HEAD > .claude/hooks/gate-git-diff.sh" \
    "git diff HEAD >&cosign.pub" \
    "git diff HEAD >& cosign.pub" \
    "git diff HEAD <>cosign.pub" \
    "git diff HEAD 2>&1 >cosign.pub" \
    "git log -1; git diff HEAD >cosign.pub" \
    "echo x | git diff HEAD >cosign.pub" \
    "git diff HEAD 2>&1 | jq . ; git log -1 >out"; do
    run_pre "$(pre_payload_for "${writer}")"
    assert_eq "an output redirection in a git invocation is refused: ${writer}" \
        "2" "${PRE_STATUS}"
    assert_contains "and the refusal says to read stdout instead: ${writer}" \
        "${PRE_ERR}" "read that instead"
done
for harmless in "git diff HEAD 2>&1" \
    "git diff HEAD 2>&1 | jq '{a,b}'" \
    "git diff HEAD >&2" \
    "git diff HEAD 1>&2" \
    "git diff HEAD >&-" \
    "git diff HEAD 2>&-" \
    "git diff < /dev/null" \
    "git diff HEAD </dev/null" \
    "git diff HEAD <&0" \
    "git diff HEAD <<<''" \
    "git diff HEAD@{1}" \
    "echo x > out; git diff HEAD" \
    "echo x >> out && git diff HEAD" \
    "git diff HEAD | jq . > out"; do
    run_pre "$(pre_payload_for "${harmless}")"
    assert_eq "a redirection that writes no path, or is not git's, is allowed: ${harmless}" \
        "0" "${PRE_STATUS}"
done
# An expansion means the words here are not the words git would receive, so
# its message comes first; the redirection is refused once it is gone.
run_pre "$(pre_payload_for "git diff HEAD >cosign.{pub,key}")"
assert_contains "an expansion in the target is reported before the redirection" \
    "${PRE_ERR}" "before git sees the words"

# 7b''''''. bash lets a redirection precede the command name, and the two
# spellings are the same command: `>cosign.pub git diff HEAD` truncates the
# file exactly as `git diff HEAD >cosign.pub` does. A scope that opened at
# the `git` word had not yet seen the target, so `git status; >cosign.pub git
# diff HEAD` -- allowed on its `git status` prefix -- went through (fixed
# first in arch-bootc, review on #317). Shown first, against a stand-in in a
# throwaway repository: the prefix form really truncates the file.
PREFIX_REPO="${WORK}/prefix-redirect"
git init -q "${PREFIX_REPO}"
printf 'ORIGINAL-CONTENT\n' >"${PREFIX_REPO}/victim"
(cd "${PREFIX_REPO}" || exit 1; bash --norc --noprofile -c \
    'git status --short >/dev/null; >victim git diff HEAD HEAD' >/dev/null 2>&1 </dev/null || true)
assert_not_contains "a redirection written before the git word truncates the file it names" \
    "$(cat "${PREFIX_REPO}/victim")" "ORIGINAL-CONTENT"
# shellcheck disable=SC2016 # the substitutions are spellings handed to the hook, not run here
for prefixed in ">cosign.pub git diff HEAD" \
    "git status; >cosign.pub git diff HEAD" \
    "2>err git log -1" \
    ">> out git show HEAD" \
    "FOO=bar >out git diff HEAD" \
    "git status; >cosign.pub /usr/bin/git diff HEAD" \
    "> .claude/settings.json git diff HEAD" \
    "git status; {fd}>cosign.pub git diff HEAD" \
    "git diff HEAD {fd}>cosign.pub" \
    'git status; >$(printf cosign.pub) git diff HEAD' \
    '>$(printf cosign.pub) git diff HEAD'; do
    run_pre "$(pre_payload_for "${prefixed}")"
    assert_eq "a redirection written before the git word is refused: ${prefixed}" \
        "2" "${PRE_STATUS}"
    assert_contains "and the refusal says to read stdout instead: ${prefixed}" \
        "${PRE_ERR}" "read that instead"
done
# shellcheck disable=SC2016 # the substitutions are spellings handed to the hook, not run here
for harmless in "</dev/null git diff HEAD" \
    "2>&1 git diff HEAD" \
    ">&2 git diff HEAD" \
    ">out echo x; git diff HEAD" \
    ">out cat f | git diff --stat" \
    "echo x > out; git diff HEAD" \
    "git status; >out printf %s git" \
    ">out echo git; git diff HEAD" \
    '>$(printf out) echo x; git diff HEAD' \
    "{fd}>out echo x; git diff HEAD" \
    'x=$(date); git diff HEAD' \
    'echo $(date) *.sh; git status' \
    'echo $(git log -1) | git diff HEAD'; do
    run_pre "$(pre_payload_for "${harmless}")"
    assert_eq "a prefix redirection that writes no path, or belongs to another command, is allowed: ${harmless}" \
        "0" "${PRE_STATUS}"
done

# 7b'''''''. an unquoted leading `~` is $HOME to bash and a literal `~` to the
# gate, which `realpath -m -s` resolved to `<checkout>/~/...`, an inside path.
# So `git diff -- ~/.aws/credentials ~/.bashrc` counted two operands, found
# both inside the working tree, and exited 0, and bash then handed git two
# files from the home directory, which it printed as a plain-file diff. The
# ShellCheck operand scan in 8b'' already refused the word; the git scope now does
# the same. Shown first, against a throwaway HOME of this test's own -- never
# the real one.
TILDE_HOME="${WORK}/tilde-home"
mkdir -p "${TILDE_HOME}/.aws"
printf 'AWS_SECRET_ACCESS_KEY=NOT-A-REAL-KEY-GIT-TILDE-42\n' >"${TILDE_HOME}/.aws/credentials"
printf 'export FIXTURE=1\n' >"${TILDE_HOME}/.bashrc"
git_tilde_out="$(cd "${REPO_ROOT}" || exit 1; HOME="${TILDE_HOME}" bash --norc --noprofile -c \
    'git diff -- ~/.aws/credentials ~/.bashrc' 2>&1 </dev/null || true)"
assert_contains "git diff -- ~/path ~/path prints the files under \$HOME, not the literal ~ the gate resolves" \
    "${git_tilde_out}" "AWS_SECRET_ACCESS_KEY=NOT-A-REAL-KEY-GIT-TILDE-42"
for tilded in "git diff -- ~/.aws/credentials ~/.bashrc" \
    "git diff ~/.bashrc ~/.aws/credentials" \
    "git diff -- ~ ~/.bashrc" \
    "git diff -- ~root/.bashrc ./cosign.pub" \
    "git log -p -- ~/.ssh/config" \
    "git show HEAD -- ~/.ssh/config" \
    "git diff HEAD -- ~/.bashrc" \
    "git status; git diff -- ~/.aws/credentials ~/.bashrc" \
    "echo x | git diff -- ~/.aws/credentials ~/.bashrc"; do
    run_pre "$(pre_payload_for "${tilded}")"
    assert_eq "a word with an unquoted leading ~ is refused in a git invocation: ${tilded}" \
        "2" "${PRE_STATUS}"
    assert_contains "and the refusal names the tilde: ${tilded}" \
        "${PRE_ERR}" "unquoted leading ~"
done
for literal in "git diff HEAD@{1}" \
    "git diff HEAD~1" \
    "git diff -- 'lit~eral'" \
    "git diff -- '~/x'" \
    "git diff -- \"~/x\"" \
    "git diff -- \\~/x" \
    "git diff HEAD -- x~" \
    "git show HEAD:~/x" \
    "ls ~/.bashrc; git diff HEAD" \
    "echo x > out; git diff HEAD"; do
    run_pre "$(pre_payload_for "${literal}")"
    assert_eq "a quoted, escaped or non-leading ~ is the literal word: ${literal}" \
        "0" "${PRE_STATUS}"
done
# The containment test never resolves a leading `~` inside the tree, quoted
# or not, so two quoted tildes after a `--` are refused as the plain-file form
# although bash would hand git two literal paths: the stricter direction,
# taken on purpose (review on zfs-kinoite-complex#220, the same hook).
run_pre "$(pre_payload_for "git diff -- '~/x' '~/y'")"
assert_eq "two quoted tildes after -- are refused as the plain-file form" "2" "${PRE_STATUS}"
assert_contains "and the refusal is the operand scan's" "${PRE_ERR}" "--no-index"
# The tilde rule's corpus, checked against bash the way the brace corpus is:
# every word bash rewrites must be refused, every word of the literal set
# must be allowed, and a word in neither class is only held to the first
# rule. Each word is inserted verbatim into a bash script under a HOME that
# does not exist, which changes nothing about whether bash expands it.
tilde_literal_set=(
    "'~/x'"
    '"~/x"'
    '\~/x'
    'HEAD~1'
    'HEAD~2..HEAD~1'
    'lit~eral'
    'x~'
)
# shellcheck disable=SC2088 # the quoted tildes are corpus words, not paths this test opens
tilde_corpus=(
    "${tilde_literal_set[@]}"
    '~'
    '~/.aws/credentials'
    '~/.bashrc'
    '~root/.bashrc'
    '~/'
)
bash_rewrites_word() {
    local typed stripped
    typed="$(HOME=/nonexistent-home bash --norc --noprofile -c 'printf "%s" '"$1" 2>/dev/null)"
    stripped="${1//[\'\"\\]/}"
    [[ "${typed}" != "${stripped}" ]]
}
corpus_rewritten=0
for word in "${tilde_corpus[@]}"; do
    if bash_rewrites_word "${word}"; then
        corpus_rewritten=$((corpus_rewritten + 1))
        run_pre "$(pre_payload_for "git diff -- ${word} ./cosign.pub")"
        assert_eq "bash rewrites it, so it is refused: ${word}" "2" "${PRE_STATUS}"
        assert_contains "and the refusal names the tilde: ${word}" \
            "${PRE_ERR}" "unquoted leading ~"
    fi
done
assert_eq "bash rewrote at least 4 corpus words, so the check was not vacuous" \
    "0" "$(((corpus_rewritten >= 4) ? 0 : 1))"
for word in "${tilde_literal_set[@]}"; do
    assert_eq "bash leaves the literal word alone: ${word}" \
        "1" "$(bash_rewrites_word "${word}" && echo 0 || echo 1)"
    run_pre "$(pre_payload_for "git log -1 -- ${word}")"
    assert_eq "and so does the hook: ${word}" "0" "${PRE_STATUS}"
done

# 7b''''''. the word that names a command has to be literal. Every scope
# above opens at a literal `git` word, and the allow rule matched the string
# on its literal prefix; `git status; G=git; $G diff /dev/null ./cosign.key`
# was invisible to both in zfs-kinoite-complex#216 (the same hook). Here the
# `$` latch to the end of the string already caught that spelling once a
# `git` word had been seen, and left `$G diff ...` and `G=git; $G diff ...`
# with no git word ahead of them to the permission layer. The name is the
# first word after a separator (or of the string) that is not an assignment
# or a keyword that takes a command; one carrying a `$` or a backtick, or an
# unquoted backtick opening there, is refused wherever it stands. So is a
# brace bash would expand or a glob there -- `{,git}`, `g?t`,
# `/usr/bin/g[i]t` all reach git (review on #205) -- and after a wrapper
# that runs its arguments (`command`, `env`, `timeout`, ...) every remaining
# word of the command is held to the test, because `command -- $G` put a
# literal `--` where the first version of this rule stopped looking. `[` and
# `[[` are commands, not globs. An assignment before a literal name is fine.
for built in "git status; G=git; \$G diff /dev/null ./cosign.key" \
    "git status; \$(printf git) diff /dev/null ./cosign.key" \
    "git status; \`echo git\` diff x" \
    "\`echo git\` diff x" \
    "\$G diff /dev/null ./cosign.key" \
    "G=git; \$G diff /dev/null ./cosign.key" \
    "git status && \"\$(printf git)\" diff x" \
    "git status; { \$G diff x; }" \
    "git status; exec \$G diff x" \
    "git status; env G=git \$G diff x" \
    "git status | \$G diff x" \
    "git status; {,git} diff /dev/null ./cosign.key" \
    "git status; g?t diff /dev/null ./cosign.key" \
    "git status; gi* diff /dev/null ./cosign.key" \
    "git status; /usr/bin/g[i]t diff /dev/null ./cosign.key" \
    "shellcheck --version; G=git; command -- \$G diff /dev/null ./cosign.key" \
    "git status; env -u X \$G diff /dev/null ./cosign.key" \
    "git status; timeout -s KILL 5 \$G diff x"; do
    run_pre "$(pre_payload_for "${built}")"
    assert_eq "a command name built by an expansion is refused: ${built}" \
        "2" "${PRE_STATUS}"
    assert_contains "and the refusal says to spell the name literally: ${built}" \
        "${PRE_ERR}" "Spell every command name literally"
done
# `env -S` is not an option but an interpreter: it splits its quoted string
# into a command this scan never sees as words (review on
# zfs-kinoite-complex#217). Any -S after env, clustered or long, is refused;
# the other env options are not.
for split in "git status; env -S 'git diff /dev/null ./cosign.key'" \
    "env -iS 'git diff /dev/null ./cosign.key'" \
    "git status; env --split-string='git diff x'" \
    "git status; env --split-string 'git diff x'" \
    "git status; env -u X -S 'git diff x'"; do
    run_pre "$(pre_payload_for "${split}")"
    assert_eq "env -S is refused: ${split}" "2" "${PRE_STATUS}"
    assert_contains "and the refusal names it: ${split}" "${PRE_ERR}" "env -S"
done
for literal in "git status; git diff HEAD@{1}" \
    "X=\$(date); git diff HEAD" \
    "echo \$HOME; git diff HEAD" \
    "echo \`date\`; git diff HEAD" \
    "if [ -n \"\$x\" ]; then git diff HEAD; fi" \
    "ls > out; git status" \
    "[[ -n \"\$x\" ]] && git diff HEAD" \
    "git status; [ -f cosign.pub ]" \
    "env -u X git diff HEAD" \
    "timeout 60 git diff HEAD" \
    "git status; timeout -s KILL 5 git diff HEAD" \
    "xargs -I{} echo {} < list" \
    "command -v shellcheck" \
    "find . -name '*.sh'"; do
    run_pre "$(pre_payload_for "${literal}")"
    assert_eq "a literal command name is left alone: ${literal}" \
        "0" "${PRE_STATUS}"
done
# `/usr/bin/git diff /dev/null ./cosign.key` needs no expansion and opened
# no scope, because every scan compared the word to `git`. A literal name
# whose last component is git is rewritten to git before any scan runs, so
# each refusal reaches it.
for pathed in "git status; /usr/bin/git diff /dev/null ./cosign.key" \
    "/usr/bin/git diff /dev/null ./cosign.key" \
    "git status; ~/bin/git diff /dev/null ./cosign.key" \
    "git status; command /usr/bin/git diff /dev/null ./cosign.key"; do
    run_pre "$(pre_payload_for "${pathed}")"
    assert_eq "a literal path to git is git: ${pathed}" "2" "${PRE_STATUS}"
    assert_contains "and the refusal is the plain-file one: ${pathed}" \
        "${PRE_ERR}" "--no-index"
done
run_pre "$(pre_payload_for "/usr/bin/git log -1 --output=cosign.pub")"
assert_contains "and --output is refused behind a path to git" \
    "${PRE_ERR}" "--output=FILE"
run_pre "$(pre_payload_for "git status; /usr/bin/git diff HEAD >cosign.pub")"
assert_contains "and a redirection is refused behind a path to git" \
    "${PRE_ERR}" "read that instead"
run_pre "$(pre_payload_for "/usr/bin/git diff HEAD")"
assert_eq "and the ordinary diff behind a path to git is allowed" "0" "${PRE_STATUS}"

# The `$` test is the one refusal that still reads to the end of the string:
# it runs on the normalized words, whose quotes are gone, and `in_git` holds
# there so a quoted `|` inside an argument cannot end the invocation early.
# `git diff HEAD | awk '{print $1}'` is refused for its `$`, not its brace.
run_pre "$(pre_payload_for "git diff HEAD | awk '{print \$1}'")"
assert_eq "a \$ in a later command of the string is still refused" \
    "2" "${PRE_STATUS}"

# 7b-corpus. The brace rule checked against bash itself rather than against a
# hand-written label. Each word below is inserted verbatim into a bash script
# -- the corpus is this file's, and the point is to hand bash the spelling an
# agent would type -- and the NUL-separated results are counted. A word bash
# turns into more than one is one the hook must refuse; the literal set,
# git's `@{...}` revision syntax, must be allowed. Words in neither class are
# only held to the first rule, so an over-refusal there is not a failure.
# `OPERANDS` is set so `${OPERANDS}` splits into two words the way a
# runtime-built argument would. The corpus: the literal set, the ordinary
# expansions, the two review bypasses, quoted and escaped commas, nesting,
# ranges, `${VAR}`, mismatched forms in both directions, braces after
# --output, and quoted jq/awk programs that bash leaves alone.
brace_literal_set=(
    'HEAD@{1}'
    'main@{upstream}'
    '@{-1}'
    '@{2.days.ago}'
    'HEAD@{1'
)
# shellcheck disable=SC2016 # the unexpanded ${OPERANDS} is the corpus word
brace_corpus=(
    "${brace_literal_set[@]}"
    'HEAD@{2}..HEAD@{1}'
    '{a,b}'
    '{1..3}'
    'x{1..3}y'
    'a{,b}'
    '{{a,b}}'
    '--no-inde{x,x}'
    '--outpu{t,t}=FILE'
    'HEAD@{1,2}'
    '{--src-prefix=x},--no-index}'
    '{a},b}'
    "{/tmp/reference';',./cosign.key}"
    '{a",",b}'
    '{a\,b,c}'
    '"{a,b}"'
    "'{a,b}'"
    '{a,b'
    '{a,b}}'
    '{{a,b}'
    '${OPERANDS}'
    '--output={a,b}'
    '--output=x{,}'
    "'{print \$1}'"
    "'{a:1}'"
    "'{a: .x, b: .y}'"
)
bash_word_count() {
    OPERANDS='/dev/null ./cosign.key' bash --norc --noprofile -c \
        'printf "%s\0" '"$1" 2>/dev/null | tr -cd '\0' | wc -c
}
assert_eq "the brace corpus holds at least 25 words" \
    "0" "$(((${#brace_corpus[@]} >= 25) ? 0 : 1))"
corpus_expanding=0
for word in "${brace_corpus[@]}"; do
    count="$(bash_word_count "${word}")"
    if ((count > 1)); then
        corpus_expanding=$((corpus_expanding + 1))
        run_pre "$(pre_payload_for "git diff ${word}")"
        assert_eq "bash expands it into ${count} words, so it is refused: ${word}" \
            "2" "${PRE_STATUS}"
        assert_contains "and the refusal says the shell rewrites it: ${word}" \
            "${PRE_ERR}" "before git sees the words"
    fi
done
assert_eq "bash expanded at least 15 corpus words, so the check was not vacuous" \
    "0" "$(((corpus_expanding >= 15) ? 0 : 1))"
for word in "${brace_literal_set[@]}"; do
    assert_eq "bash leaves the literal word alone: ${word}" \
        "1" "$(bash_word_count "${word}")"
    run_pre "$(pre_payload_for "git log ${word} -1")"
    assert_eq "and so does the hook: ${word}" "0" "${PRE_STATUS}"
    assert_eq "silently: ${word}" "" "${PRE_ERR}${PRE_OUT}"
done

# 7c. the reads the allow rule exists for keep working. A hook that turned
# `git diff` back into a prompt would be traded for the one it replaced.
# Two operands are the plain-file form unless both resolve as revisions, so
# `git diff HEAD HEAD` must stay silent -- HEAD twice rather than HEAD~1 or a
# branch name, since CI checks out at depth 1 and neither of those resolves
# there.
for ordinary in "git diff" "git diff --stat" "git diff HEAD~1 -- build_files/" \
    "git diff HEAD HEAD" "git diff ./README.md" "git diff -- ./cosign.key" \
    "git diff -- cosign.pub README.md" \
    "git log --output-indicator-new=% -1" \
    "git diff --output-indicator-old=- HEAD HEAD" \
    "git diff --output-indicator-frag=@ HEAD HEAD" \
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

# --- 8. the other allow-listed command that opens a file it is pointed at ---
#
# `Bash(shellcheck:*)` is allowed with no prompt as well, and ShellCheck prints
# the *source line* above every diagnostic it reports. So it prints back
# whatever it is aimed at: `shellcheck ./.env` echoes every unexported
# `NAME=value` line of a file `Read(./.env)` refuses, values included, and a
# PEM-shaped file gives up its `-----BEGIN/END-----` lines and its trailing
# base64 line. The shape is section 7's exactly -- those rules gate the *Read*
# tool, this is Bash, and nothing consulted them.
#
# No permission pattern closes it either: patterns match by prefix, so
# `Bash(shellcheck tests/:*)` still matches
# `shellcheck tests/run-tests.sh /home/me/.aws/credentials`, and an exact rule
# per tracked script stops `shellcheck a.sh b.sh` working at all. So the hook
# checks the operands: inside the working tree, and not one of the
# secret-shaped names.
#
# Demonstrated before it is asserted. The demonstration is skipped when
# ShellCheck is absent, the way tests/test-shell-syntax.sh skips its own pass;
# the assertions below do not need the tool, because they exercise the hook.
SC_WORK="${WORK}/shellcheck-exposure"
mkdir -p "${SC_WORK}"
printf 'AWS_SECRET_ACCESS_KEY=NOT-A-REAL-KEY-0123456789\n' >"${SC_WORK}/dotenv"
if command -v shellcheck >/dev/null 2>&1; then
    sc_out="$(shellcheck "${SC_WORK}/dotenv" 2>&1 || true)"
    assert_contains "shellcheck prints the source line of the file it is given" \
        "${sc_out}" "AWS_SECRET_ACCESS_KEY=NOT-A-REAL-KEY-0123456789"
else
    printf '  skip the shellcheck exposure demo (not installed)\n'
fi

# 8a. the read the finding is about, and the spellings around it. A path
# outside the working tree, a `..` route that leaves and comes back, and a
# secret-shaped name inside the tree are each refused; `path_inside_worktree`
# decides the first two and `denied_read_shape` the third, because `cosign.key`
# and a `.env` live in the tree and are the two files the deny rules exist for.
sc_repo_name="${REPO_ROOT##*/}"
for leak in "shellcheck ./.env" \
    "shellcheck .env" \
    "shellcheck ./cosign.key" \
    "shellcheck ./.env.local" \
    "shellcheck /etc/passwd" \
    "shellcheck ${WORK}/outside.sh" \
    "shellcheck ../${sc_repo_name}/cosign.key" \
    "shellcheck -x tests/run-tests.sh /etc/shadow" \
    "shellcheck -e SC2034 ./.env" \
    "shellcheck -f gcc ./.env" \
    "shellcheck -sbash ./.env" \
    "shellcheck --format=gcc ./.env" \
    "shellcheck keys/server.pem" \
    "shellcheck /home/someone/.ssh/id_ed25519" \
    "shellcheck -- ./.env" \
    "git status; shellcheck ./.env" \
    "echo x | shellcheck ./.env"; do
    run_pre "$(pre_payload_for "${leak}")"
    assert_eq "an operand outside the tree or secret-shaped is refused: ${leak}" \
        "2" "${PRE_STATUS}"
    assert_contains "and the refusal says what shellcheck prints: ${leak}" \
        "${PRE_ERR}" "source line above every diagnostic"
done

# 8b. the same four characters that rebuild a git operand rebuild a shellcheck
# one, and for the same reason: this scan reads the words as typed and bash
# rewrites them first. `shellcheck {tests/run-tests.sh,/etc/shadow}` is one
# word here and two files at shellcheck.
for rebuilt in "shellcheck {tests/run-tests.sh,/etc/shadow}" \
    "shellcheck tests/{run-tests.sh,../../etc/shadow}" \
    "shellcheck \$f" \
    "shellcheck \${SECRET}" \
    "shellcheck \$(ls /etc/shadow)" \
    "shellcheck \`ls\`" \
    "shellcheck <(cat /etc/shadow)"; do
    run_pre "$(pre_payload_for "${rebuilt}")"
    assert_eq "an expansion in a shellcheck operand is refused: ${rebuilt}" \
        "2" "${PRE_STATUS}"
done

# 8b''. two more rewrites bash performs turned a checked operand into a
# different file. A leading unquoted `~` is $HOME to bash and a literal `~` to
# the gate -- which `realpath -m -s` resolved to `<checkout>/~/...`, an inside
# path -- so `shellcheck ~/.aws/credentials` passed, and the `~/.ssh/id_ed25519`
# case in 8a was refused only by its basename. An unquoted `*`, `?` or `[` is
# a glob bash expands into files the gate never saw as words: `shellcheck
# .env*` is one word here and the .env to bash. Both shown first, against a
# throwaway HOME and a temporary directory of this test's own -- never the
# real $HOME. A quoted or escaped glob character is the literal word bash
# would pass, and a `~` that does not lead the word is a filename character.
if command -v shellcheck >/dev/null 2>&1; then
    SC_HOME="${WORK}/shellcheck-home"
    mkdir -p "${SC_HOME}/.aws"
    printf 'AWS_SECRET_ACCESS_KEY=NOT-A-REAL-KEY-TILDE-42\n' >"${SC_HOME}/.aws/credentials"
    sc_tilde_out="$(HOME="${SC_HOME}" bash --norc --noprofile -c 'shellcheck ~/.aws/credentials' 2>&1 </dev/null || true)"
    assert_contains "shellcheck ~/path reads the file under \$HOME, not the literal ~ the gate resolves" \
        "${sc_tilde_out}" "AWS_SECRET_ACCESS_KEY=NOT-A-REAL-KEY-TILDE-42"
    SC_GLOB="${WORK}/shellcheck-glob"
    mkdir -p "${SC_GLOB}"
    printf 'AWS_SECRET_ACCESS_KEY=NOT-A-REAL-KEY-GLOB-42\n' >"${SC_GLOB}/.env"
    sc_glob_out="$(cd "${SC_GLOB}" || exit 1; bash --norc --noprofile -c 'shellcheck .env*' 2>&1 </dev/null || true)"
    assert_contains "shellcheck .env* reads the file the glob expands to, which the gate never saw as a word" \
        "${sc_glob_out}" "AWS_SECRET_ACCESS_KEY=NOT-A-REAL-KEY-GLOB-42"
fi
for rewritten in "shellcheck ~/.aws/credentials" \
    "shellcheck ~" \
    "shellcheck ~someone/.bashrc" \
    "shellcheck .env*" \
    "shellcheck cosign.ke?" \
    "shellcheck .en[v]" \
    "shellcheck ./.*" \
    "shellcheck tests/*.sh" \
    "shellcheck -x tests/run-tests.sh ~/.netrc" \
    "shellcheck ~/.ssh/id_ed25519" \
    "git log -1 && shellcheck ~/.aws/credentials"; do
    run_pre "$(pre_payload_for "${rewritten}")"
    assert_eq "a tilde or glob in a shellcheck operand is refused: ${rewritten}" \
        "2" "${PRE_STATUS}"
    assert_contains "and the refusal says bash rewrites it: ${rewritten}" \
        "${PRE_ERR}" "bash rewrites this word"
done
for literal in "shellcheck 'tests/*.sh'" \
    "shellcheck \"tests/*.sh\"" \
    "shellcheck tests/\\*.sh" \
    "shellcheck tests/run-tests.sh~" \
    "shellcheck 'tests/run-tests.sh'"; do
    run_pre "$(pre_payload_for "${literal}")"
    assert_eq "a quoted glob or a non-leading ~ is the literal word: ${literal}" \
        "0" "${PRE_STATUS}"
done

# 8b'. the operands do not all arrive in the argv. SHELLCHECK_OPTS is split and
# prepended to shellcheck's own arguments, operands included, so
# `SHELLCHECK_OPTS=./.env shellcheck tests/run-tests.sh` lints the .env too and
# prints its lines back while the argv this gate scans names no such path. The
# assignment is written before the command name, so the refusal cannot be
# scoped to a shellcheck invocation; nothing in this repository sets the
# variable.
if command -v shellcheck >/dev/null 2>&1; then
    sc_env_out="$(SHELLCHECK_OPTS="${SC_WORK}/dotenv" shellcheck \
        "${REPO_ROOT}/tests/run-tests.sh" 2>&1 || true)"
    assert_contains "SHELLCHECK_OPTS adds an operand shellcheck prints back" \
        "${sc_env_out}" "AWS_SECRET_ACCESS_KEY=NOT-A-REAL-KEY-0123456789"
fi
for opts in "SHELLCHECK_OPTS=./.env shellcheck tests/run-tests.sh" \
    "SHELLCHECK_OPTS='./.env' shellcheck tests/run-tests.sh" \
    "SHELLCHECK_OPTS=-e2034 shellcheck ./.env" \
    "export SHELLCHECK_OPTS=/etc/shadow" \
    "SHELLCHECK_OPTS=/etc/shadow shellcheck -x tests/run-tests.sh"; do
    run_pre "$(pre_payload_for "${opts}")"
    assert_eq "a SHELLCHECK_OPTS assignment is refused: ${opts}" \
        "2" "${PRE_STATUS}"
    assert_contains "and the refusal says why: ${opts}" \
        "${PRE_ERR}" "prepends it to its own argv"
done

# 8c. and the lint runs this repository actually performs are untouched. These
# are the invocations in tests/test-shell-syntax.sh and in the PostToolUse hook
# in .claude/settings.json, plus the option spellings around them. A `-` is
# stdin rather than a file. `-C always` is the one option whose argument is
# optional and must be attached, so shellcheck reads `always` as a file name
# and so does the hook -- it is inside the tree, so it passes either way.
for lint in "shellcheck --version" \
    "shellcheck -x tests/run-tests.sh" \
    "shellcheck -x build_files/post-check.sh" \
    "shellcheck ci/write-badges.sh tests/test-harness.sh" \
    "shellcheck -e SC2034 -x ci/write-badges.sh" \
    "shellcheck -f gcc -x tests/test-harness.sh" \
    "shellcheck --format=gcc tests/test-harness.sh" \
    "shellcheck --severity error tests/test-harness.sh" \
    "shellcheck -o all tests/run-tests.sh" \
    "shellcheck -s bash tests/run-tests.sh" \
    "shellcheck -P SCRIPTDIR -x tests/run-tests.sh" \
    "shellcheck -" \
    "shellcheck -C always" \
    "echo x; shellcheck tests/run-tests.sh" \
    "shellcheck tests/run-tests.sh && git diff HEAD"; do
    run_pre "$(pre_payload_for "${lint}")"
    assert_eq "the repository's own lint run is unaffected: ${lint}" \
        "0" "${PRE_STATUS}"
    assert_eq "and silent: ${lint}" "" "${PRE_ERR}${PRE_OUT}"
done

# 8d. the scope does not leak in either direction. A path outside the tree
# belonging to some *other* command of the string is not shellcheck's operand,
# and a `git` invocation after a shellcheck one is still scanned as git's.
for scoped in "shellcheck tests/run-tests.sh; wc -c /etc/shadow" \
    "shellcheck tests/run-tests.sh && ls /etc" \
    "cat /etc/hostname | shellcheck -"; do
    run_pre "$(pre_payload_for "${scoped}")"
    assert_eq "another command's path is not a shellcheck operand: ${scoped}" \
        "0" "${PRE_STATUS}"
done
run_pre "$(pre_payload_for "shellcheck tests/run-tests.sh; git diff /dev/null ./cosign.key")"
assert_eq "and a git invocation after one is still scanned as git's" \
    "2" "${PRE_STATUS}"
assert_contains "with git's own refusal" "${PRE_ERR}" "--no-index"

# 8d'. the operand is not the only way in. ShellCheck reads standard input when
# its operand is `-`, and it prints the source line above every diagnostic
# either way, so `shellcheck - < .env` printed the file back exactly as
# `shellcheck ./.env` did in 8a -- and the operand scan never saw the path,
# because 8a's scan skips a redirection's target (#212). The target of a bare
# `<` is now held to the operand test: inside the tree, no deny shape, and
# spelled out. Shown first, the way the operand exposure is shown above.
if command -v shellcheck >/dev/null 2>&1; then
    sc_stdin_out="$(shellcheck - <"${SC_WORK}/dotenv" 2>&1 || true)"
    assert_contains "shellcheck - prints back the file on its standard input" \
        "${sc_stdin_out}" "AWS_SECRET_ACCESS_KEY=NOT-A-REAL-KEY-0123456789"
fi
# The descriptor, the attached operator, the prefix form bash allows before the
# command name, and the four rewrites 8b and 8b'' cover, each on the target.
for fed in "shellcheck - < .env" \
    "shellcheck - <.env" \
    "shellcheck -s bash - <./cosign.key" \
    "shellcheck - 0< ./.env.local" \
    "shellcheck - < keys/server.pem" \
    "shellcheck - < /etc/shadow" \
    "shellcheck - < ${WORK}/outside.sh" \
    "shellcheck - < ../${sc_repo_name}/cosign.key" \
    "shellcheck - < ~/.aws/credentials" \
    "shellcheck - < {tests/run-tests.sh,.env}" \
    "shellcheck - < .env*" \
    "shellcheck -x tests/run-tests.sh < ./.env" \
    "shellcheck - < './.env'" \
    "< .env shellcheck -" \
    "command -p shellcheck - < .env" \
    "git status; shellcheck - < .env"; do
    run_pre "$(pre_payload_for "${fed}")"
    assert_eq "a file fed to shellcheck on stdin is refused: ${fed}" \
        "2" "${PRE_STATUS}"
    assert_contains "and the refusal names the redirection: ${fed}" \
        "${PRE_ERR}" "reads standard input"
done
# `/dev/null` has nothing to print back, a script inside the checkout is the
# ordinary lint run, and the operators that carry no path are untouched: `<<`
# takes a delimiter, `<<<` takes content, and `<&` duplicates a descriptor.
# A redirection on some *other* command of the string is that command's own.
for fedok in "shellcheck - < tests/run-tests.sh" \
    "shellcheck -s bash - <tests/run-tests.sh" \
    "shellcheck tests/run-tests.sh < /dev/null" \
    "shellcheck - </dev/null" \
    "shellcheck - <<< 'echo hi'" \
    "shellcheck - <&3" \
    "shellcheck - < 'tests/*.sh'" \
    "cat .env | shellcheck -" \
    "gh pr list < .env" \
    "echo x < .env; shellcheck tests/run-tests.sh"; do
    run_pre "$(pre_payload_for "${fedok}")"
    assert_eq "a harmless input redirection is left alone: ${fedok}" \
        "0" "${PRE_STATUS}"
done
# A here-document's delimiter is not a path, and the rule above must not read
# it as one. The quoted spelling is the one section 9 leaves alone; the
# unquoted one is refused there for its body, not for this.
run_pre "$(pre_payload_for "$(printf "shellcheck - <<'EOF'\necho hi\nEOF\n")")"
assert_eq "a here-document delimiter is not a path" "0" "${PRE_STATUS}"

# 8e. the settings file records the decision, next to the one for git diff.
SHELLCHECK_NOTE="$(jq -r '._note_shellcheck // ""' "${SETTINGS}")"
assert_contains "the note names what shellcheck prints" \
    "${SHELLCHECK_NOTE}" "source line"
assert_contains "and that no permission pattern closes it" \
    "${SHELLCHECK_NOTE}" "match by prefix"
assert_contains "and the residual it does not cover" \
    "${SHELLCHECK_NOTE}" "external-sources"
assert_contains "and the redirection that feeds it a file the operands do not name" \
    "${SHELLCHECK_NOTE}" "standard input"

# --- 9. the same write, in the allow-listed commands that are not git -------
#
# Sections 7 and 8 gate two commands by name. The write half of section 7 is
# not git's alone: a rule ending in `:*` means "this command with any
# arguments", and a shell output redirection is part of the string that rule
# matches, so `shellcheck tests/run-tests.sh >cosign.pub` truncated the trust
# anchor before a line was linted and `gh run view 1 --log
# >.claude/settings.json` overwrote the file holding these rules -- neither
# prompted (review on zfs-kinoite-complex#224, the same hook). The hook now
# decides every simple command in the string against the allow rows that
# carry a `:*`, other than git's, which section 7 already covers.
#
# 9a. the exposure, shown rather than asserted, against a stand-in in a
# throwaway directory of this test's own: bash opens the target before the
# command runs, so the file is emptied even when the command then fails.
# `bash -n` is used because it is always present; shellcheck may not be.
GATED_WORK="${WORK}/gated-redirect"
mkdir -p "${GATED_WORK}"
printf 'ORIGINAL-CONTENT\n' >"${GATED_WORK}/victim"
(cd "${GATED_WORK}" || exit 1; bash --norc --noprofile -c \
    'bash -n ./no-such-script.sh >victim' >/dev/null 2>&1 </dev/null || true)
assert_not_contains "an output redirection on an allow-listed non-git command truncates the file it names" \
    "$(cat "${GATED_WORK}/victim")" "ORIGINAL-CONTENT"
# And the flag form: `-n` reads a script without running it, and a later `+n`
# on the same command line turns that back off, so the linter's allow rule
# runs whatever follows.
noexec_out="$(cd "${GATED_WORK}" || exit 1; bash --norc --noprofile -c \
    "bash -n +n -c 'printf RAN-UNDER-BASH-N'" 2>/dev/null </dev/null || true)"
assert_eq "bash -n +n -c COMMAND runs the command the -n was meant to keep from running" \
    "RAN-UNDER-BASH-N" "${noexec_out}"
# And a process substitution as the redirection's target: bash connects the
# command's output to a command of its own, which writes wherever it likes
# (review on arch-bootc#322, the same hook).
printf 'ORIGINAL-CONTENT\n' >"${GATED_WORK}/victim2"
(cd "${GATED_WORK}" || exit 1; bash --norc --noprofile -c \
    'bash -n ./no-such-script.sh 2> >(cat >victim2); wait' >/dev/null 2>&1 </dev/null || true)
assert_not_contains "a redirection onto a process substitution writes the file the substitution names" \
    "$(cat "${GATED_WORK}/victim2")" "ORIGINAL-CONTENT"
# A process substitution as an ordinary argument runs its body as part of the
# approved string, and the body is held to no rule; and a wrapper's option
# before the name (`command -p bash -n +n ...`) is still that command
# (review on arch-bootc#322, the same hook).
printf 'ORIGINAL-CONTENT\n' >"${GATED_WORK}/victim3"
(cd "${GATED_WORK}" || exit 1; bash --norc --noprofile -c \
    'bash -n ./no-such-script.sh >(cat >victim3); wait' >/dev/null 2>&1 </dev/null || true)
assert_not_contains "a process substitution argument writes the file its body names" \
    "$(cat "${GATED_WORK}/victim3")" "ORIGINAL-CONTENT"
wrapper_out="$(cd "${GATED_WORK}" || exit 1; bash --norc --noprofile -c \
    "command -p bash -n +n -c 'printf RAN-BEHIND-WRAPPER'" 2>/dev/null </dev/null || true)"
assert_eq "command -p bash -n +n -c COMMAND runs the command behind the wrapper's option" \
    "RAN-BEHIND-WRAPPER" "${wrapper_out}"
time_out="$(cd "${GATED_WORK}" || exit 1; bash --norc --noprofile -c \
    "time -p bash -n +n -c 'printf RAN-BEHIND-TIME'" 2>/dev/null </dev/null || true)"
assert_eq "time -p bash -n +n -c COMMAND runs the command behind time's option" \
    "RAN-BEHIND-TIME" "${time_out}"
printf 'ORIGINAL-CONTENT\n' >"${GATED_WORK}/victim4"
(cd "${GATED_WORK}" || exit 1; bash --norc --noprofile -c \
    'bash -n ./no-such-script.sh $(printf x >victim4)' >/dev/null 2>&1 </dev/null || true)
assert_not_contains "a command substitution argument writes the file its body names" \
    "$(cat "${GATED_WORK}/victim4")" "ORIGINAL-CONTENT"
# A here-document with an unquoted delimiter is expanded before the command
# runs, so a substitution on a body line runs under the prefix (review on
# arch-bootc#322 and #211).
printf 'ORIGINAL-CONTENT\n' >"${GATED_WORK}/victim5"
(cd "${GATED_WORK}" || exit 1; bash --norc --noprofile -c \
    $'bash -n <<EOF\n$(printf x >victim5)\nEOF' >/dev/null 2>&1 </dev/null || true)
assert_not_contains "a substitution on the body line of an unquoted heredoc writes the file it names" \
    "$(cat "${GATED_WORK}/victim5")" "ORIGINAL-CONTENT"
# shellcheck disable=SC2016 # the substitutions are spellings handed to the hook, not run here
for heredoc in $'podman images <<EOF\necho $(printf x >cosign.pub)\nEOF' \
    $'gh pr list <<EOF\nplain text\nEOF' \
    $'bash -n <<-EOF\n\tx\nEOF' \
    $'git status; skopeo inspect docker://x <<EOF\nx\nEOF'; do
    run_pre "$(pre_payload_for "${heredoc}")"
    assert_eq "an unquoted here-document on an allow-listed command is refused: ${heredoc//$'\n'/ | }" \
        "2" "${PRE_STATUS}"
    assert_contains "and the refusal says to quote the delimiter: ${heredoc//$'\n'/ | }" \
        "${PRE_ERR}" "Quote the delimiter"
done
# An assignment before the name is an environment the command runs under,
# and for these commands that changes what runs or where it goes (review on
# sensi#244, the Python twin of this hook). Git was exempt until issue #218,
# on the reading that a git invocation is decided by the operand scan; that
# scan reads words, and an assignment is not one. Shown first in a temporary
# repository: `GIT_EXTERNAL_DIFF` names a program git runs once per changed
# path, so an allow-listed `git diff` string runs it with no prompt.
gitenv_dir="$(mktemp -d)"
(
    cd "${gitenv_dir}" || exit 0
    printf '#!/bin/sh\nprintf RAN-AS-EXTERNAL-DIFF >"%s/ran"\n' "${gitenv_dir}" >prog
    chmod +x prog
    git init -q . >/dev/null 2>&1 || exit 0
    git -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m first >/dev/null 2>&1
    printf 'one\n' >tracked
    git add tracked >/dev/null 2>&1
    git -c user.email=t@example.invalid -c user.name=t commit -q -m second >/dev/null 2>&1
    GIT_EXTERNAL_DIFF="${gitenv_dir}/prog" git diff HEAD~1 >/dev/null 2>&1
) </dev/null
gitenv_ran="$(cat "${gitenv_dir}/ran" 2>/dev/null)"
rm -rf "${gitenv_dir}"
assert_eq "GIT_EXTERNAL_DIFF=prog git diff runs prog, so an assignment before git is code execution" \
    "RAN-AS-EXTERNAL-DIFF" "${gitenv_ran}"
for assigned in "LD_PRELOAD=x.so shellcheck tests/run-tests.sh" \
    "BASH_ENV=f bash -n tests/run-tests.sh" \
    "GH_HOST=other gh pr list" \
    "CONTAINERS_CONF=f podman ps" \
    "FOO=1 ./tests/run-tests.sh test-harness" \
    "git status; FOO=1 skopeo inspect docker://x" \
    "GIT_EXTERNAL_DIFF=/tmp/prog git diff HEAD~1" \
    "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=diff.external GIT_CONFIG_VALUE_0=/tmp/prog git diff HEAD~1" \
    "PATH=/tmp/bin git diff HEAD~1" \
    "FOO=bar git diff HEAD" \
    "PAGER=cat git log -1" \
    "GIT_DIR=/tmp/other git ls-files" \
    "git status; FOO=1 git log -1" \
    "env FOO=bar git diff HEAD" \
    "env -u X GIT_EXTERNAL_DIFF=/tmp/prog git diff HEAD~1" \
    "env -i PATH=/tmp/bin git diff HEAD~1" \
    "env -u X LD_PRELOAD=x.so shellcheck tests/run-tests.sh" \
    "timeout 60 FOO=1 git diff HEAD" \
    "command FOO=1 git diff HEAD"; do
    run_pre "$(pre_payload_for "${assigned}")"
    assert_eq "an assignment before an allow-listed command is refused: ${assigned}" \
        "2" "${PRE_STATUS}"
    assert_contains "and the refusal names the assignment: ${assigned}" \
        "${PRE_ERR}" "assignment before"
done
# A wrapper's own option is a name candidate too, so the scan that decides
# `the name has been seen` saw one before the assignment and let it through
# (issue #218). These are the same invocations without the assignment, and
# they stay unprompted.
for assigned in "FOO=1 echo x; podman images" \
    "x=1; podman images" \
    "FOO=1 echo x; git diff HEAD" \
    "echo FOO=bar; git status" \
    "env -u X git diff HEAD" \
    "env -i git diff HEAD" \
    "timeout 60 git diff HEAD"; do
    run_pre "$(pre_payload_for "${assigned}")"
    assert_eq "an assignment on another command of the string, or no assignment at all, is left alone: ${assigned}" \
        "0" "${PRE_STATUS}"
done
# The export family is the same environment written after the name instead of
# before it. `export NAME=value`, `declare -x` and `typeset -x` put the
# variable in the environment of every command bash runs later in the same
# string, so the leading-assignment scan above -- which only ever looks at a
# word standing *before* a name -- saw nothing to record and the git
# invocation that followed carried no assignment of its own. Shown first in a
# temporary repository, the way the leading form is: the program named by an
# exported GIT_EXTERNAL_DIFF runs once per changed path just the same.
exportenv_dir="$(mktemp -d)"
(
    cd "${exportenv_dir}" || exit 0
    printf '#!/bin/sh\nprintf RAN-AFTER-EXPORT >"%s/ran"\n' "${exportenv_dir}" >prog
    chmod +x prog
    git init -q . >/dev/null 2>&1 || exit 0
    git -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m first >/dev/null 2>&1
    printf 'one\n' >tracked
    git add tracked >/dev/null 2>&1
    git -c user.email=t@example.invalid -c user.name=t commit -q -m second >/dev/null 2>&1
    export GIT_EXTERNAL_DIFF="${exportenv_dir}/prog"
    git diff HEAD~1 >/dev/null 2>&1
) </dev/null
exportenv_ran="$(cat "${exportenv_dir}/ran" 2>/dev/null)"
rm -rf "${exportenv_dir}"
assert_eq "an exported GIT_EXTERNAL_DIFF reaches a later git diff of the same string" \
    "RAN-AFTER-EXPORT" "${exportenv_ran}"
for exported in "export GIT_EXTERNAL_DIFF=/tmp/prog; git diff HEAD~1" \
    "declare -x GIT_EXTERNAL_DIFF=/tmp/prog; git diff HEAD~1" \
    "typeset -x GIT_EXTERNAL_DIFF=/tmp/prog; git diff HEAD~1" \
    "readonly GIT_EXTERNAL_DIFF=/tmp/prog; git diff HEAD~1" \
    "export PATH=/tmp/bin; git diff HEAD~1" \
    "export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=diff.external; git diff HEAD~1" \
    "export LD_PRELOAD=x.so; shellcheck tests/run-tests.sh" \
    "export BASH_ENV=f; bash -n tests/run-tests.sh" \
    "export GH_HOST=other; gh pr list" \
    "export CONTAINERS_CONF=f && podman ps" \
    "export FOO=1; ./tests/run-tests.sh test-harness" \
    $'export GIT_EXTERNAL_DIFF=/tmp/prog\ngit diff HEAD~1' \
    "export FOO=1; git status; git diff HEAD"; do
    run_pre "$(pre_payload_for "${exported}")"
    assert_eq "an export-family assignment that reaches a gated command is refused: ${exported//$'\n'/ | }" \
        "2" "${PRE_STATUS}"
    assert_contains "and the refusal names the export family: ${exported//$'\n'/ | }" \
        "${PRE_ERR}" "export family"
done
# An export bash cannot carry to one of these commands. The variable reaches
# what runs *after* it and nothing earlier, and an export with no gated
# command anywhere in the string is not this gate's business at all -- such a
# command carries no allow row and prompts on its own.
for exported in "export FOO=1" \
    "export GIT_EXTERNAL_DIFF=/tmp/prog" \
    "export FOO=1; echo hi" \
    "declare -x FOO=1; echo hi" \
    "git diff HEAD; export GIT_EXTERNAL_DIFF=/tmp/prog" \
    "git status && export FOO=1" \
    "echo export FOO=1; git diff HEAD" \
    "git log --grep=export -1" \
    "export; git diff HEAD" \
    "declare -p; git diff HEAD"; do
    run_pre "$(pre_payload_for "${exported}")"
    assert_eq "an export that reaches no gated command is left alone: ${exported//$'\n'/ | }" \
        "0" "${PRE_STATUS}"
done
for heredoc in $'bash -n <<\'EOF\'\necho hi\nEOF' \
    $'bash -n <<"EOF"\necho $(id)\nEOF' \
    $'cat <<EOF\nplain\nEOF; gh pr list' \
    "podman images <in"; do
    run_pre "$(pre_payload_for "${heredoc}")"
    assert_eq "a quoted here-document, or one on another command, is left alone: ${heredoc//$'\n'/ | }" \
        "0" "${PRE_STATUS}"
done
# shellcheck disable=SC2016 # the substitution is a spelling handed to the hook, not run here
for substituted in "podman images >(cat >cosign.pub)" \
    ">(cat >cosign.pub) podman images" \
    "gh pr list <(true)" \
    "bash -n <(printf x >written)" \
    "bash -n >(cat) tests/run-tests.sh" \
    "git status; skopeo inspect docker://x >(tee cosign.pub)" \
    'echo $(podman images >(cat >cosign.pub))' \
    'podman images $(printf x >cosign.pub)' \
    'podman images `printf x >cosign.pub`' \
    'gh run view 1 --log $(date) >cosign.pub' \
    'podman images < <(printf x >cosign.pub)' \
    'podman images <"$(printf x >cosign.pub)"' \
    'gh pr list <<<"$(printf x >cosign.pub)"' \
    'podman images <`printf in`' \
    'shellcheck tests/run-tests.sh <"$(printf x >cosign.pub)"' \
    'shellcheck tests/run-tests.sh < <(printf x >cosign.pub)' \
    'podman images "$(printf x >cosign.pub)"' \
    'podman images $X' \
    'gh pr list "$FLAGS"' \
    "podman images 'a \$b'"; do
    run_pre "$(pre_payload_for "${substituted}")"
    assert_eq "a substitution in an allow-listed command is refused: ${substituted}" \
        "2" "${PRE_STATUS}"
    assert_contains "and the refusal names the substitution: ${substituted}" \
        "${PRE_ERR}" "substitution"
done

# 9b. the list of gated commands lives in the hook; this is what keeps it from
# drifting. The commands are derived from the settings file rather than
# restated, so an allow rule added there with a trailing `:*` fails here until
# the hook lists it. The exact `Bash(./tests/run-tests.sh)` row carries no
# `:*`, so a redirection makes the string match only the `:*` row beside it.
gated_rows=0
while IFS= read -r allow_rule; do
    [[ "${allow_rule}" == "Bash("*":*)" ]] || continue
    allow_cmd="$(bash_prefix "${allow_rule}")"
    [[ "${allow_cmd}" == "git "* ]] && continue
    gated_rows=$((gated_rows + 1))
    run_pre "$(pre_payload_for "${allow_cmd} >cosign.pub")"
    assert_eq "every allow rule with arguments is refused a writing redirection: ${allow_cmd} >cosign.pub" \
        "2" "${PRE_STATUS}"
    assert_contains "and the refusal names the allow-listed command: ${allow_cmd}" \
        "${PRE_ERR}" "allow-listed command"
done <<<"${ALLOW}"
if ((gated_rows >= 11)); then
    _pass "the settings file still carries the allow rows this section gates (${gated_rows})"
else
    _fail "the settings file still carries the allow rows this section gates" \
        "found ${gated_rows} Bash(...:*) rows other than git's; expected at least 11"
fi

# 9c. every operator that opens a path, in every position bash accepts it: after
# the command, before its name, after an assignment or `time`, and carried
# across a `$(...)` in the same command, which is a command of its own.
# shellcheck disable=SC2016 # the substitutions are spellings handed to the hook, not run here
for writer in "shellcheck tests/run-tests.sh >cosign.pub" \
    "shellcheck tests/run-tests.sh >> out" \
    "shellcheck tests/run-tests.sh 2>.claude/settings.json" \
    "./tests/run-tests.sh >| cosign.pub" \
    "./tests/run-tests.sh test-harness &>cosign.pub" \
    "bash -n tests/run-tests.sh &>>cosign.pub" \
    "gh run view 1 --log >.claude/settings.json" \
    "gh run list --limit 5 >&cosign.pub" \
    "gh pr view 1 <>cosign.pub" \
    "gh pr list {fd}>cosign.pub" \
    "skopeo inspect docker://ghcr.io/x:latest >/dev/null" \
    "podman images >cosign.pub" \
    "podman ps -a > .claude/hooks/gate-git-diff.sh" \
    "podman inspect x 2>&1 >cosign.pub" \
    ">cosign.pub shellcheck tests/run-tests.sh" \
    "git status; >cosign.pub gh run view 1 --log" \
    "FOO=bar shellcheck tests/run-tests.sh >cosign.pub" \
    "FOO=bar >cosign.pub shellcheck tests/run-tests.sh" \
    "time shellcheck tests/run-tests.sh >cosign.pub" \
    "command podman images >cosign.pub" \
    'echo $(gh run view 1 --log >cosign.pub)' \
    "ls | podman images >cosign.pub" \
    "shellcheck tests/run-tests.sh 2>&1 | tee x; gh pr list >out" \
    "shellcheck tests/run-tests.sh > >(cat >cosign.pub)" \
    "podman images >>(tee cosign.pub)" \
    "gh pr list 2> >(cat >cosign.pub)" \
    "shellcheck tests/run-tests.sh >cosign.pub # a comment after the write" \
    "shellcheck tests/run-tests.sh '#' >cosign.pub" \
    "command -p shellcheck tests/run-tests.sh >cosign.pub"; do
    run_pre "$(pre_payload_for "${writer}")"
    assert_eq "an output redirection inside an allow-listed command is refused: ${writer}" \
        "2" "${PRE_STATUS}"
    assert_contains "and the refusal says to read stdout instead: ${writer}" \
        "${PRE_ERR}" "read that"
done

# 9d. the refusal is the operator that opens a path for writing. A pipe, a
# descriptor form and an input redirection open none, and AGENTS.md tells a
# session to run the second of these.
for harmless in "shellcheck tests/run-tests.sh 2>&1 | tail -5" \
    "gh run view 123 --log-failed | grep -E 'KERNEL=|Failed to access RPM|Error: building'" \
    "gh run view 123 --log-failed 2>&1 | sed 's/x/y/'" \
    "skopeo inspect docker://ghcr.io/x:latest | jq .Digest" \
    "shellcheck tests/run-tests.sh <tests/run-tests.sh" \
    "gh pr view 1 >&2" \
    "podman images 2>&-" \
    "./tests/run-tests.sh test-harness </dev/null" \
    "shellcheck -x tests/run-tests.sh" \
    "bash -n tests/run-tests.sh" \
    "gh pr view 1 --json title -q .title" \
    "podman ps --sync" \
    "skopeo inspect --format '{{.Digest}}' docker://ghcr.io/ublue-os/akmods:coreos-stable-45-x86_64"; do
    run_pre "$(pre_payload_for "${harmless}")"
    assert_eq "reading the output of an allow-listed command still works: ${harmless}" \
        "0" "${PRE_STATUS}"
    assert_eq "and silently: ${harmless}" "" "${PRE_ERR}${PRE_OUT}"
done

# 9e. the hook re-gates what the permission rules wave through. A command no
# allow rule covers prompts on its own, and refusing it here would be the hook
# deciding a question the settings file already decides; a redirection on
# another command of the same string is that command's own.
# The last two are decided by Claude Code itself: a redirection on a brace
# group or a subshell is refused by the Bash tool before any rule or hook
# sees it ("does not accept compound statements with redirection", 2.1.267),
# so the hook does not restate that refusal.
# shellcheck disable=SC2016 # the substitutions are spellings handed to the hook, not run here
for unlisted in "echo x >cosign.pub" \
    "cat tests/run-tests.sh >cosign.pub" \
    "python3 tests/some_script.py >cosign.pub" \
    "echo x >out; shellcheck tests/run-tests.sh" \
    "shellcheck tests/run-tests.sh | tee out" \
    ">out echo x; gh pr list" \
    "bash -n tests/run-tests.sh; { bash -n missing.sh; } >cosign.pub" \
    "(shellcheck tests/run-tests.sh) >cosign.pub" \
    "echo x > >(cat >cosign.pub)" \
    "cat < <(gh pr list)" \
    "cat <(podman images)" \
    "command -v shellcheck" \
    "time -p ls" \
    'x=$(podman images); echo $x' \
    'echo $(podman images)' \
    'podman images --format "{{.ID}}"' \
    'gh pr list --json title -q ".[].title"' \
    "shellcheck tests/run-tests.sh # output > file" \
    "bash -n tests/run-tests.sh # +n" \
    "git diff HEAD # > cosign.pub"; do
    run_pre "$(pre_payload_for "${unlisted}")"
    assert_eq "a redirection on a command no allow rule covers is left alone: ${unlisted}" \
        "0" "${PRE_STATUS}"
done

# 9f. the flag that undoes `bash -n`. `+n` and `+o noexec` turn execution back
# on for the rest of the command line, so a word beginning with `+` in a
# `bash -n` invocation is refused, along with the spellings bash rebuilds --
# a brace, a `$` or a backtick -- since `{+,+}n` reaches bash as `+n`.
# shellcheck disable=SC2016 # the substitutions are spellings handed to the hook, not run here
for noexec in "bash -n +n -c 'cat ./cosign.key'" \
    "bash -n +o noexec tests/run-tests.sh" \
    "bash -n tests/run-tests.sh +n" \
    "bash -n +nv -c 'id'" \
    'bash -n "+n" -c id' \
    "git status; bash -n +n -c id" \
    "git status; command -p bash -n +n -c id" \
    "command -- bash -n +n -c id" \
    "git status; time -p bash -n +n -c id"; do
    run_pre "$(pre_payload_for "${noexec}")"
    assert_eq "a + word in a bash -n invocation is refused: ${noexec}" \
        "2" "${PRE_STATUS}"
    assert_contains "and the refusal names the flag: ${noexec}" \
        "${PRE_ERR}" "+n"
done
# A glob is the third rebuild (review on #211): beside a file named `+n`,
# `?n` reaches bash as `+n`. Shown first, in the throwaway directory.
touch "${GATED_WORK}/+n"
glob_out="$(cd "${GATED_WORK}" || exit 1; bash --norc --noprofile -c \
    "bash -n ?n -c 'printf RAN-VIA-GLOB'" 2>/dev/null </dev/null || true)"
assert_eq "bash -n ?n -c COMMAND runs the command when a file named +n exists" \
    "RAN-VIA-GLOB" "${glob_out}"
# shellcheck disable=SC2016 # the substitutions are spellings handed to the hook, not run here
for rebuilt in "bash -n {+,+}n -c id" \
    'bash -n $X tests/run-tests.sh' \
    'bash -n $(printf +n) -c id' \
    'bash -n `printf +n` -c id' \
    "bash -n --norc {+,+}n -c id" \
    "bash -n ?n -c id" \
    "bash -n [+]n -c id" \
    "bash -n tests/*.sh"; do
    run_pre "$(pre_payload_for "${rebuilt}")"
    assert_eq "an expansion in a bash -n invocation is refused: ${rebuilt}" \
        "2" "${PRE_STATUS}"
    assert_contains "and the refusal names the rebuild: ${rebuilt}" \
        "${PRE_ERR}" "+n"
done
# shellcheck disable=SC2016 # the $x is a spelling handed to the hook, not expanded here
for plain in "bash -n tests/run-tests.sh" \
    "bash -n build_files/post-check.sh tests/run-tests.sh" \
    "bash -n -- tests/run-tests.sh" \
    "bash -n '?n'" \
    "bash +n -c id" \
    'echo $x; bash -n tests/run-tests.sh'; do
    run_pre "$(pre_payload_for "${plain}")"
    assert_eq "a syntax check, and a bash no allow rule covers, are left alone: ${plain}" \
        "0" "${PRE_STATUS}"
done

# 9g. the settings file records the decision, next to the ones for git diff
# and shellcheck, and says where the list is checked.
GATED_NOTE="$(jq -r '._note_gated_writes // ""' "${SETTINGS}")"
assert_contains "the note names the redirection the allow rules cannot see" \
    "${GATED_NOTE}" ">cosign.pub"
assert_contains "and the bash -n flag that undoes the read" \
    "${GATED_NOTE}" "+n"
assert_contains "and the test that derives the gated list from this file" \
    "${GATED_NOTE}" "tests/test-claude-settings.sh"

# --- 10. the corpus: every way a command reaches a tool past an allow rule ---
#
# Sections 7 to 9 were written one spelling at a time, and each one found the
# next: an operand, then a tilde in an operand, then the target of an input
# redirection, then `SHELLCHECK_OPTS`, then its `+=` append, then a leading
# `NAME=value`, then the export family. Issue #222 names the corpus once
# instead, across the six repositories that carry a hook of this kind, so this
# section is that corpus as *data* rather than as prose: one row per shape,
#
#     corpus_row <refuse|allow> <shape> <command>
#
# read by one loop below. A shape found in any of those repositories is one row
# here, and a shape this repository cannot reach is an `allow` row with the
# reason written beside it rather than a shape left undecided. The five shapes
# are the ones the issue names: an environment assignment that reaches the
# tool, a redirection, a word bash rewrites before the tool sees it, the
# command name itself, and an option that loads or writes.
#
# What this does not restate: the cases above, which are asserted with the
# messages they must produce and the exposures they follow from. A row here
# asserts the decision -- refused or not -- and the mutation block at the end
# asserts that each rule added for this corpus is what produces it.

CORPUS=()
corpus_row() { CORPUS+=("$1"$'\t'"$2"$'\t'"$3"); }

# 10a. shape 1: an environment assignment reaching the tool. None of these
# appears inside the string an allow rule matches, and each one changes what
# the command runs or where it sends what it has. `+=` is not a narrower case
# of `=`: appending to an unset variable creates it.
corpus_row refuse "1 env: leading assignment" \
    "GIT_EXTERNAL_DIFF=/tmp/prog git diff HEAD~1"
corpus_row refuse "1 env: leading append" \
    "GIT_EXTERNAL_DIFF+=/tmp/prog git diff HEAD~1"
corpus_row refuse "1 env: env NAME=value" \
    "env GIT_EXTERNAL_DIFF=/tmp/prog git diff HEAD~1"
corpus_row refuse "1 env: env -i NAME=value" \
    "env -i GIT_EXTERNAL_DIFF=/tmp/prog git diff HEAD~1"
# env parses its own argv after bash has removed the quotes, so a quoted name
# is an assignment to env and not to bash. The as-typed word begins with a
# quote mark rather than with a name, which is how it passed.
corpus_row refuse "1 env: env with a quoted name" \
    "env 'GIT_EXTERNAL_DIFF'=/tmp/prog git diff HEAD~1"
corpus_row refuse "1 env: env with a double-quoted name" \
    "env \"GIT_EXTERNAL_DIFF\"=/tmp/prog git diff HEAD~1"
corpus_row refuse "1 env: env with a quote inside the name" \
    "env GIT_EXTERNAL'_DIFF'=/tmp/prog git diff HEAD~1"
corpus_row refuse "1 env: env -S" \
    "env -S'GIT_EXTERNAL_DIFF=/tmp/prog git diff HEAD~1'"
corpus_row refuse "1 env: env --split-string" \
    "env --split-string='GIT_EXTERNAL_DIFF=/tmp/prog git diff HEAD~1'"
corpus_row refuse "1 env: export" \
    "export GIT_EXTERNAL_DIFF=/tmp/prog; git diff HEAD~1"
corpus_row refuse "1 env: export append" \
    "export GIT_EXTERNAL_DIFF+=/tmp/prog; git diff HEAD~1"
corpus_row refuse "1 env: declare -x" \
    "declare -x GIT_EXTERNAL_DIFF=/tmp/prog; git diff HEAD~1"
corpus_row refuse "1 env: typeset -x" \
    "typeset -x GIT_EXTERNAL_DIFF=/tmp/prog; git diff HEAD~1"
corpus_row refuse "1 env: readonly" \
    "readonly GIT_EXTERNAL_DIFF=/tmp/prog; git diff HEAD~1"
# The export and the assignment in two commands: `export NAME` marks the
# variable exported and the plain `NAME=value` after it supplies the value, so
# neither command carries an assignment the leading-assignment scan can use and
# the variable is in git's environment all the same.
corpus_row refuse "1 env: export NAME then a plain assignment" \
    "export GIT_EXTERNAL_DIFF; GIT_EXTERNAL_DIFF=/tmp/prog; git diff HEAD~1"
corpus_row refuse "1 env: declare -x NAME then a plain assignment" \
    "declare -x GIT_EXTERNAL_DIFF; GIT_EXTERNAL_DIFF=/tmp/prog; git diff HEAD~1"
# allexport: the same arming with no name in it at all.
corpus_row refuse "1 env: set -a" \
    "set -a; GIT_EXTERNAL_DIFF=/tmp/prog; git diff HEAD~1"
corpus_row refuse "1 env: set -o allexport" \
    "set -o allexport; GIT_EXTERNAL_DIFF=/tmp/prog; git diff HEAD~1"
corpus_row refuse "1 env: set -ao" \
    "set -ao; GIT_EXTERNAL_DIFF=/tmp/prog; git diff HEAD~1"
corpus_row refuse "1 env: a newline as the separator" \
    $'export GIT_EXTERNAL_DIFF=/tmp/prog\ngit diff HEAD~1'
# Which variables matter is per repo and per tool. These are this repository's:
# git's diff driver under its other name, its pager and its transport; the
# linter's option string; the loader's; the runner's interpreter, which
# CONTRIBUTING documents; and the two tools whose configuration is a file path.
corpus_row refuse "1 env: GIT_CONFIG_* triple" \
    "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=diff.external GIT_CONFIG_VALUE_0=/tmp/prog git diff HEAD~1"
corpus_row refuse "1 env: GIT_CONFIG_GLOBAL" \
    "GIT_CONFIG_GLOBAL=/tmp/c git diff HEAD~1"
corpus_row refuse "1 env: GIT_PAGER" "GIT_PAGER=/tmp/prog git log -1"
corpus_row refuse "1 env: GIT_SSH_COMMAND" "GIT_SSH_COMMAND=/tmp/prog git ls-files"
corpus_row refuse "1 env: PATH" "PATH=/tmp/bin git diff HEAD~1"
corpus_row refuse "1 env: SHELLCHECK_OPTS" \
    "SHELLCHECK_OPTS=./.env shellcheck tests/run-tests.sh"
corpus_row refuse "1 env: SHELLCHECK_OPTS append" \
    "SHELLCHECK_OPTS+=./.env shellcheck tests/run-tests.sh"
corpus_row refuse "1 env: LD_PRELOAD" "LD_PRELOAD=x.so shellcheck tests/run-tests.sh"
corpus_row refuse "1 env: LD_LIBRARY_PATH" "LD_LIBRARY_PATH=/tmp podman images"
corpus_row refuse "1 env: BASH_ENV" "BASH_ENV=f bash -n tests/run-tests.sh"
corpus_row refuse "1 env: WORKFLOW_PYTHON" \
    "WORKFLOW_PYTHON=/tmp/prog ./tests/run-tests.sh"
corpus_row refuse "1 env: PYTHONPATH" \
    "PYTHONPATH=/tmp ./tests/run-tests.sh test-harness"
corpus_row refuse "1 env: PYTHONSTARTUP" \
    "PYTHONSTARTUP=/tmp/x ./tests/run-tests.sh test-harness"
corpus_row refuse "1 env: PYTEST_ADDOPTS" \
    "PYTEST_ADDOPTS=-p/tmp/x ./tests/run-tests.sh test-harness"
corpus_row refuse "1 env: GH_HOST" "GH_HOST=other gh pr list"
corpus_row refuse "1 env: CONTAINERS_CONF" "CONTAINERS_CONF=f podman ps"

# Allowed, with the reason: an assignment bash cannot carry to one of these
# commands. A leading assignment belongs to the command it precedes; a
# standalone one sets a shell variable, which is not an environment; an export
# with nothing gated after it reaches nothing this gate covers; and `set -e` or
# `set -x` carries no `a`, so it exports nothing.
corpus_row allow "1 env: the assignment is another command's" \
    "FOO=1 echo x; git diff HEAD"
corpus_row allow "1 env: a shell variable, not an environment" "x=1; podman images"
corpus_row allow "1 env: an assignment-shaped argument" "echo FOO=bar; git status"
corpus_row allow "1 env: export with no name" "export; git diff HEAD"
corpus_row allow "1 env: declare -p" "declare -p; git diff HEAD"
corpus_row allow "1 env: the export comes after" \
    "git diff HEAD; export GIT_EXTERNAL_DIFF=/tmp/prog"
corpus_row allow "1 env: env -u removes one" "env -u X git diff HEAD"
corpus_row allow "1 env: env -i sets none" "env -i git diff HEAD"
corpus_row allow "1 env: set -e is not allexport" "set -e; git diff HEAD"
corpus_row allow "1 env: set -x is not allexport" "set -x; git status"

# 10b. shape 2: a redirection. Every operator with a `>` in it opens its target
# for writing before the command runs, `<>` included; a bare `<` hands the
# linter a file it prints back through the source line it echoes. A descriptor
# form names no path, and `<<`/`<<<` carry a delimiter or content.
corpus_row refuse "2 redirect: >" "git diff HEAD >cosign.pub"
corpus_row refuse "2 redirect: >>" "git diff HEAD >>cosign.pub"
corpus_row refuse "2 redirect: >|" "git diff HEAD >|cosign.pub"
corpus_row refuse "2 redirect: &>" "git diff HEAD &>cosign.pub"
corpus_row refuse "2 redirect: &>>" "git diff HEAD &>>cosign.pub"
corpus_row refuse "2 redirect: N>" "git diff HEAD 2>cosign.pub"
corpus_row refuse "2 redirect: >&FILE" "git diff HEAD >&cosign.pub"
corpus_row refuse "2 redirect: <>" "git diff HEAD <>cosign.pub"
corpus_row refuse "2 redirect: before the command name" ">cosign.pub git diff HEAD"
corpus_row refuse "2 redirect: on a gated non-git command" \
    "shellcheck tests/run-tests.sh >cosign.pub"
corpus_row refuse "2 redirect: over these settings" \
    "gh run view 1 --log >.claude/settings.json"
corpus_row refuse "2 redirect: the rule is the operator, not the target" \
    "podman images >/dev/null"
corpus_row refuse "2 redirect: a file on shellcheck's stdin" "shellcheck - < .env"
corpus_row refuse "2 redirect: written before the name" "< .env shellcheck -"
corpus_row refuse "2 redirect: with a descriptor" "shellcheck - 0<.env"
corpus_row allow "2 redirect: 2>&1 names a descriptor" "git diff HEAD 2>&1"
corpus_row allow "2 redirect: >&2 names a descriptor" "git diff HEAD >&2"
corpus_row allow "2 redirect: >&- closes one" "podman images 2>&-"
corpus_row allow "2 redirect: reading /dev/null" "git diff HEAD </dev/null"
corpus_row allow "2 redirect: shellcheck reading /dev/null" "shellcheck - </dev/null"
corpus_row allow "2 redirect: reading a script in the tree" \
    "shellcheck tests/run-tests.sh <tests/run-tests.sh"
corpus_row allow "2 redirect: a here-string carries content" "gh pr list <<<x"
corpus_row allow "2 redirect: a pipe opens nothing" \
    "shellcheck tests/run-tests.sh 2>&1 | tail -5"
corpus_row allow "2 redirect: no allow rule covers echo" "echo x >cosign.pub"

# 10c. shape 3: a word bash rewrites before the tool sees it. A brace is two
# words to bash and one to a scanner, an unquoted leading `~` is a home
# directory, a glob is however many files match, and a substitution builds the
# word at runtime. They are refused rather than expanded, because a half-right
# expansion is a gate that disagrees with the shell in some other direction.
corpus_row refuse "3 rewrite: a brace makes two operands" \
    "git diff {/dev/null,./cosign.key}"
corpus_row refuse "3 rewrite: a brace rebuilds a flag" \
    "git log -p --outpu{t,t}=cosign.pub -1"
corpus_row refuse "3 rewrite: a leading tilde" \
    "git diff -- ~/.aws/credentials ~/.bashrc"
# A glob grows one written operand into the two git needs for the plain-file
# mode: `/etc/passwd*` matches `passwd` and `passwd-` on any Fedora host and
# git printed the diff between them.
corpus_row refuse "3 rewrite: a glob grows the operand count" "git diff /etc/passwd*"
corpus_row refuse "3 rewrite: a glob after a bare --" "git diff -- /etc/passwd*"
corpus_row refuse "3 rewrite: a glob over two denied shapes" "git diff .env*"
corpus_row refuse "3 rewrite: a question mark in an operand" "git diff ./cosign.ke?"
corpus_row refuse "3 rewrite: a bracket rebuilds a flag" \
    "git log -p --outpu[t]=cosign.pub -1"
corpus_row refuse "3 rewrite: a brace in a shellcheck operand" \
    "shellcheck {tests/run-tests.sh,/etc/shadow}"
corpus_row refuse "3 rewrite: a glob in a shellcheck operand" "shellcheck .env*"
corpus_row refuse "3 rewrite: a tilde in a shellcheck operand" "shellcheck ~/.bashrc"
corpus_row refuse "3 rewrite: a brace rebuilds +n" "bash -n {+,+}n -c id"
corpus_row refuse "3 rewrite: a glob rebuilds +n" "bash -n ?n -c id"
# shellcheck disable=SC2016 # the substitutions are spellings handed to the hook
corpus_row refuse "3 rewrite: a command substitution" \
    'git diff $(printf "/dev/null ./cosign.key")'
# shellcheck disable=SC2016 # the spelling handed to the hook is the point, not its value
corpus_row refuse "3 rewrite: a backtick" 'git diff `printf /dev/null` ./cosign.key'
corpus_row refuse "3 rewrite: a process substitution operand" \
    "git diff <(true) ./cosign.key"
corpus_row refuse "3 rewrite: a process substitution as a target" \
    "podman images >(cat >cosign.pub)"
# Allowed, with the reason: bash expands none of these. Git's own `@{...}`
# revision syntax has neither a comma nor a `..` inside the braces, a quoted
# glob is the pathspec git expands itself, and a brace or a `$` in a command no
# allow rule covers is that command's own business.
corpus_row allow "3 rewrite: git's reflog syntax" "git diff HEAD@{1}"
corpus_row allow "3 rewrite: an upstream revision" "git diff 'HEAD@{upstream}'"
corpus_row allow "3 rewrite: a quoted pathspec" "git ls-files 'tests/test-*.sh'"
corpus_row allow "3 rewrite: a quoted pathspec after --" "git diff -- 'tests/*.sh'"
corpus_row allow "3 rewrite: a quoted glob for shellcheck" "shellcheck 'tests/*.sh'"
# shellcheck disable=SC2016 # the awk program is a spelling handed to the hook
corpus_row allow "3 rewrite: a brace in another command's program" \
    'awk "{print \$1}" tests/run-tests.sh'

# 10d. shape 4: the command name. A path, a wrapper and a name bash assembles
# all reach the same tool while spelling the name differently. The read
# primitives are latched on the bare tool word wherever it stands, so a
# wrapper that only runs the command cannot hide one; the write primitive is
# decided from the name, so a wrapper is modelled there. `noglob` is one of
# those wrappers: Claude Code's permission matcher steps over it the way it
# steps over `nohup`, so `noglob podman ps >out` matched `Bash(podman ps:*)`
# while this gate read `noglob` as the name.
#
# `xargs` is the wrapper that does hide a read. It adds the words it reads
# from standard input, or from the file `-a` names, to the command it runs, so
# the git scope latches on `git` and counts no operand while git receives two,
# and the matcher accepts `xargs git diff` for `Bash(git diff:*)` as readily
# as `git diff`. So it is refused outright in front of git or an allow-listed
# command, wherever it stands among the other wrappers. Shown first, against a
# stand-in in a throwaway repository of this test's own: git prints the file
# xargs named for it. And the `noglob` write is real under bash too, where
# `noglob` is no command at all: bash opens the target before it looks.
XARGS_REPO="${WORK}/xargs-operands"
git init -q "${XARGS_REPO}"
printf 'NOT-A-REAL-KEY-XARGS-42\n' >"${XARGS_REPO}/cosign.pub"
xargs_out="$(cd "${XARGS_REPO}" || exit 1; bash --norc --noprofile -c \
    "printf '%s\n' /dev/null ./cosign.pub | xargs git diff" 2>&1 </dev/null || true)"
assert_contains "xargs hands git diff two operands the string never names, and git prints the file" \
    "${xargs_out}" "NOT-A-REAL-KEY-XARGS-42"
printf 'ORIGINAL-CONTENT\n' >"${XARGS_REPO}/victim"
(cd "${XARGS_REPO}" || exit 1; bash --norc --noprofile -c \
    'noglob git diff HEAD >victim' >/dev/null 2>&1 </dev/null || true)
assert_not_contains "noglob is no command to bash, and the redirection still empties its target" \
    "$(cat "${XARGS_REPO}/victim")" "ORIGINAL-CONTENT"
corpus_row refuse "4 name: a path to git" "/usr/bin/git diff /dev/null ./cosign.key"
corpus_row refuse "4 name: a path to shellcheck" "/usr/bin/shellcheck ./.env"
corpus_row refuse "4 name: a brace builds the name" \
    "{,git} diff /dev/null ./cosign.key"
corpus_row refuse "4 name: a glob builds the name" "g?t diff /dev/null ./cosign.key"
# shellcheck disable=SC2016 # the variable is a spelling handed to the hook
corpus_row refuse "4 name: an expansion builds the name" \
    'G=git; $G diff /dev/null ./cosign.key'
corpus_row refuse "4 name: command" "command git diff /dev/null ./cosign.key"
corpus_row refuse "4 name: env" "env git diff /dev/null ./cosign.key"
corpus_row refuse "4 name: builtin" "builtin git diff /dev/null ./cosign.key"
corpus_row refuse "4 name: exec" "exec git diff /dev/null ./cosign.key"
corpus_row refuse "4 name: nohup" "nohup git diff /dev/null ./cosign.key"
corpus_row refuse "4 name: nice" "nice git diff /dev/null ./cosign.key"
corpus_row refuse "4 name: time" "time git diff /dev/null ./cosign.key"
corpus_row refuse "4 name: timeout" "timeout 60 git diff /dev/null ./cosign.key"
corpus_row refuse "4 name: setsid" "setsid podman images >cosign.pub"
corpus_row refuse "4 name: ionice" "ionice -c2 podman images >cosign.pub"
corpus_row refuse "4 name: chrt" "chrt -f 1 podman images >cosign.pub"
corpus_row refuse "4 name: taskset" "taskset -c 0 podman images >cosign.pub"
corpus_row refuse "4 name: unshare" "unshare podman images >cosign.pub"
corpus_row refuse "4 name: flock" "flock /tmp/l podman images >cosign.pub"
corpus_row refuse "4 name: noglob" "noglob shellcheck tests/run-tests.sh >out"
corpus_row refuse "4 name: noglob before a gated prefix" "noglob podman ps >out"
corpus_row refuse "4 name: noglob behind a redirection" ">cosign.pub noglob git diff HEAD"
corpus_row refuse "4 name: xargs git diff reading a pipe" \
    "printf '%s\n' /dev/null ./cosign.key | xargs git diff"
corpus_row refuse "4 name: xargs shellcheck reading a pipe" \
    "printf '%s\n' ./.env | xargs shellcheck"
corpus_row refuse "4 name: xargs reading a file on stdin" "xargs git diff <list.txt"
corpus_row refuse "4 name: xargs -a FILE" "xargs -a list.txt git diff"
corpus_row refuse "4 name: xargs -a FILE before shellcheck" "xargs -a list.txt shellcheck"
corpus_row refuse "4 name: xargs -I" "xargs -I{} shellcheck {} <list.txt"
corpus_row refuse "4 name: xargs options before git" "xargs -r -0 git diff <list.txt"
corpus_row refuse "4 name: a wrapper before xargs" "timeout 5 xargs git diff"
corpus_row refuse "4 name: xargs behind nice" "nice xargs shellcheck <list.txt"
corpus_row refuse "4 name: xargs before bash -n" "xargs bash -n <list.txt"
corpus_row refuse "4 name: xargs before a gated prefix" "xargs podman inspect <ids.txt"
corpus_row refuse "4 name: xargs before any git subcommand" "xargs git log <list.txt"
# shellcheck disable=SC2016 # the substitution is a spelling handed to the hook
corpus_row refuse "4 name: xargs inside a substitution" 'echo $(xargs git diff <list.txt)'
# A literal path to a wrapper is that wrapper, as a literal path to git is
# git (review on zfs-kinoite-complex#235), and only once the word is literal:
# `$D/env` runs whatever `$D` holds, so it is a name built at runtime.
corpus_row refuse "4 name: a path to xargs" "git status; /usr/bin/xargs git diff"
corpus_row refuse "4 name: a path to a wrapper before a gated write" \
    "git status; /usr/bin/nohup podman ps >out"
corpus_row refuse "4 name: a path to timeout before shellcheck" \
    "/usr/bin/timeout 5 shellcheck tests/run-tests.sh >out"
# shellcheck disable=SC2016 # the variable is a spelling handed to the hook
corpus_row refuse "4 name: a wrapper path built at runtime" 'git status; $D/env git diff HEAD'
# The command xargs runs is the first word after xargs's own options, read
# the way GNU findutils and uutils read them; an option the two read
# differently, or one neither has, leaves every later word a possible name.
corpus_row refuse "4 name: an xargs option's value in the next word" \
    "xargs -n 1 git diff <list.txt"
corpus_row refuse "4 name: an xargs long option's value in the next word" \
    "xargs --max-args 1 git diff <list.txt"
corpus_row refuse "4 name: -- ends xargs's options" "xargs -- git diff <list.txt"
corpus_row refuse "4 name: an xargs option's value spelled as a keyword" \
    "xargs -I if git diff <list.txt"
corpus_row refuse "4 name: xargs running a wrapper" "xargs timeout 5 git diff <list.txt"
corpus_row refuse "4 name: an xargs option read two ways" \
    "xargs --max-lines 1 git diff <list.txt"
corpus_row refuse "4 name: an xargs option this does not read" \
    "xargs -J % git diff <list.txt"
# Allowed, with the reason: a literal name, with or without the quoting bash
# strips off it, is the name the allow rule matched and the name this gate
# reads.
corpus_row allow "4 name: the literal name" "git diff HEAD"
corpus_row allow "4 name: a quoted name" "'git' diff HEAD"
corpus_row allow "4 name: an escaped name" "\\git diff HEAD"
# xargs in front of a command no allow rule covers prompts on its own
# account, and a word `xargs` that is not in a name position is an argument.
corpus_row allow "4 name: xargs before an ungated command" \
    "git diff --name-only | xargs echo"
corpus_row allow "4 name: xargs before wc" "git ls-files | xargs wc -l"
corpus_row allow "4 name: xargs as a word of git's" "git log --grep=xargs -1"
corpus_row allow "4 name: xargs as an argument after a gated prefix" \
    "timeout 5 podman ps xargs"
corpus_row allow "4 name: noglob before an ordinary diff" "noglob git diff HEAD"
# The words after the command xargs runs are that command's arguments, not
# names (review on #224).
corpus_row allow "4 name: xargs runs rg, and shellcheck is its argument" \
    "git ls-files | xargs rg shellcheck"
corpus_row allow "4 name: xargs runs grep, and git is its argument" \
    "git ls-files | xargs grep -l git"
corpus_row allow "4 name: an xargs option's attached value" \
    "git ls-files | xargs -n1 rg shellcheck"

# 10e. shape 5: an option that loads or writes. Git's config layer runs
# programs -- `diff.external` is `GIT_EXTERNAL_DIFF` by another name -- and its
# relocating options move the paths every containment test here is run against.
corpus_row refuse "5 option: git -c" "git -c diff.external=/tmp/prog diff HEAD~1"
corpus_row refuse "5 option: git -c core.pager" "git -c core.pager=/tmp/prog log -1"
corpus_row refuse "5 option: git --config-env=" \
    "git --config-env=diff.external=CFG diff HEAD~1"
corpus_row refuse "5 option: git --config-env in its space form" \
    "git --config-env diff.external=CFG diff HEAD~1"
corpus_row refuse "5 option: git --exec-path" "git --exec-path=/tmp/bin diff HEAD~1"
corpus_row refuse "5 option: git --upload-pack" \
    "git --upload-pack=/tmp/prog ls-files"
corpus_row refuse "5 option: git -C" "git -C /etc diff -- passwd shadow"
corpus_row refuse "5 option: git --git-dir" "git --git-dir=/tmp/x diff -- a b"
corpus_row refuse "5 option: git --work-tree" \
    "git --work-tree=/etc diff -- passwd shadow"
corpus_row refuse "5 option: env -C" "env -C /etc git diff -- passwd shadow"
corpus_row refuse "5 option: git -C reaches config with one operand" \
    "git -C /etc diff HEAD~1"
corpus_row refuse "5 option: flock -c hands its argument to a shell" \
    "flock /tmp/l -c 'cat ./cosign.key'"
corpus_row refuse "5 option: flock --command= is the same option" \
    "flock /tmp/l --command='cat ./cosign.key'"
corpus_row refuse "5 option: cd before the command" \
    "cd /etc && git diff -- passwd shadow"
corpus_row refuse "5 option: cd before a shellcheck operand" \
    "cd /etc; shellcheck passwd"
corpus_row refuse "5 option: cd before a file on shellcheck's stdin" \
    "cd /etc; shellcheck - < passwd"
corpus_row refuse "5 option: pushd before the command" \
    "pushd /etc; git diff -- passwd shadow"
corpus_row refuse "5 option: git --output" "git diff --output=cosign.pub HEAD"
corpus_row refuse "5 option: git --output on log" "git log -p --output=cosign.pub -1"
corpus_row refuse "5 option: git --output on show" \
    "git show --output=.claude/settings.json HEAD"
corpus_row refuse "5 option: bash +n undoes -n" "bash -n +n -c id"
corpus_row refuse "5 option: bash +o noexec" "bash -n +o noexec tests/run-tests.sh"
corpus_row refuse "5 option: a shellcheck value option is stepped over" \
    "shellcheck -e SC1091 ./.env"
corpus_row refuse "5 option: shellcheck --rcfile is not one" \
    "shellcheck --rcfile /etc/shadow tests/run-tests.sh"
corpus_row refuse "5 option: shellcheck -C takes no separate value" \
    "shellcheck -C always ./.env"
# Allowed, with the reason: `-c` is the config option only between `git` and
# its subcommand -- after one it is the combined-diff flag, and in a later
# command of the string it is that command's own -- the value options the
# linter really has are stepped over so the operand after them is still
# reached, and `--output-indicator-*` changes a marker character rather than a
# destination.
corpus_row allow "5 option: -c after the subcommand" "git show -c HEAD"
corpus_row allow "5 option: the -c of another command" \
    "git log -1 && bash -c 'echo hi'"
corpus_row allow "5 option: shellcheck -s takes a value" \
    "shellcheck -s bash tests/run-tests.sh"
corpus_row allow "5 option: shellcheck --severity attached" \
    "shellcheck --severity=error tests/run-tests.sh"
corpus_row allow "5 option: --output-indicator-new is a marker" \
    "git diff --output-indicator-new=% HEAD"
corpus_row allow "5 option: a git option that loads nothing" \
    "git --no-pager diff HEAD"
# A `(...)` subshell's `cd` cannot reach the shell around it, so it must not
# taint a command outside the subshell either -- the bug this pair pins:
# `worktree_moved` used to latch for the rest of the string once a `cd`
# anywhere inside a subshell was seen, refusing a later command that in fact
# still runs from the checkout.
corpus_row allow "5 option: a subshell's cd does not escape it" \
    "(cd /etc); shellcheck tests/run-tests.sh"
corpus_row allow "5 option: nor does it taint a later git diff" \
    "(cd /etc); git diff -- README.md build_files/build.sh"

# The table, driven. One loop, so a new shape is one row above and nothing
# here.
corpus_refused=0
corpus_allowed=0
for corpus_entry in "${CORPUS[@]}"; do
    corpus_expected="${corpus_entry%%$'\t'*}"
    corpus_rest="${corpus_entry#*$'\t'}"
    corpus_shape="${corpus_rest%%$'\t'*}"
    corpus_command="${corpus_rest#*$'\t'}"
    case "${corpus_expected}" in
    refuse)
        corpus_want=2
        corpus_refused=$((corpus_refused + 1))
        ;;
    allow)
        corpus_want=0
        corpus_allowed=$((corpus_allowed + 1))
        ;;
    *)
        _fail "every corpus row states refuse or allow" \
            "row: ${corpus_entry//$'\t'/ | }"
        continue
        ;;
    esac
    run_pre "$(pre_payload_for "${corpus_command}")"
    assert_eq "corpus [${corpus_shape}] ${corpus_expected}: ${corpus_command//$'\n'/ | }" \
        "${corpus_want}" "${PRE_STATUS}"
    if [[ "${corpus_expected}" == refuse ]]; then
        assert_eq "and the refusal reaches the agent: ${corpus_command//$'\n'/ | }" \
            "0" "$([[ -n "${PRE_ERR}" ]] && printf 0 || printf 1)"
    else
        assert_eq "and silently: ${corpus_command//$'\n'/ | }" "" "${PRE_ERR}${PRE_OUT}"
    fi
done
# A vacuity guard of the same kind section 7 uses on the extracted command: a
# table that lost its rows would pass every assertion above by running none.
if ((corpus_refused >= 100 && corpus_allowed >= 20)); then
    _pass "the corpus carries its rows (${corpus_refused} refuse, ${corpus_allowed} allow)"
else
    _fail "the corpus carries its rows" \
        "found ${corpus_refused} refuse and ${corpus_allowed} allow rows" \
        "expected at least 100 and 20; a shrunken table passes vacuously"
fi

# 10f. the shapes the corpus names that this repository cannot reach, recorded
# rather than left undecided. The issue lists `-p`, `-W`, `--pdbcls` and
# `--doctest-modules` for pytest and `-c`/`-m` for python, and the variables
# that go with them. No allow rule here names an interpreter, so an invocation
# of one prompts on its own account and the options are unreachable past the
# table -- and `PYTHONPATH`, `PYTHONSTARTUP`, `PYTEST_ADDOPTS` and
# `WORKFLOW_PYTHON` are *not* in that category, because `./tests/run-tests.sh`
# is allow-listed and runs python3 for the workflow checks; those are rows
# above. This is the assertion that keeps the "not reachable" half true: adding
# an interpreter to the allow list fails here until its options are decided.
interpreter_rules=""
while IFS= read -r allow_rule; do
    case "$(bash_prefix "${allow_rule}")" in
    python | python3 | python3.* | pytest | pip | pip3 | ruby | perl | node | npm | npx)
        interpreter_rules+="${allow_rule} "
        ;;
    *) ;;
    esac
done <<<"${ALLOW}"
assert_eq "no allow rule names an interpreter, so its loading options are out of reach" \
    "" "${interpreter_rules% }"

# 10g. the mutation check. A corpus is only as good as the rules behind it: a
# row can pass because some *other* rule refuses the same command, which is how
# a gate grows a rule that does nothing. So each rule added for this corpus is
# disabled in a copy of the hook and the row it exists for has to flip to
# allowed. The copy is made by string replacement rather than by a patch, so a
# rule that is edited into a different spelling fails here instead of being
# silently skipped.
#
#     mutation <what it disables> <find> <replace> <witness>
#
# The witness has to be a `refuse` row of the table above, which is asserted
# too -- a witness outside the corpus would let a rule be checked against a
# command no row covers.
MUTATIONS=()
mutation() { MUTATIONS+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"); }

# shellcheck disable=SC2016 # the find string is the hook's own source text
mutation "the glob refusal inside a git invocation" \
    'refuse "${GIT_GLOB_MSG}"' ':' \
    "git diff /etc/passwd*"
# shellcheck disable=SC2016 # the find string is the hook's own source text
mutation "the refusal of git's config and program options" \
    'refuse "${GIT_CONFIG_MSG}"' ':' \
    "git -c diff.external=/tmp/prog diff HEAD~1"
# shellcheck disable=SC2016 # the find string is the hook's own source text
mutation "reading an assignment on its quote-stripped spelling" \
    '[[ "${words[idx]}" =~ ^([A-Za-z_][A-Za-z0-9_]*)(\[[^]]*\])?\+?= ]] ||' 'false ||' \
    "env 'GIT_EXTERNAL_DIFF'=/tmp/prog git diff HEAD~1"
# shellcheck disable=SC2016 # the find string is the hook's own source text
mutation "the export family's bare-name spelling" \
    '((cmd_export == 1)) && [[ "${words[idx]}" != -* ]]' '((cmd_export == 1)) && false' \
    "export GIT_EXTERNAL_DIFF; GIT_EXTERNAL_DIFF=/tmp/prog; git diff HEAD~1"
mutation "set -a, which exports every later assignment" \
    '((cmd_export == 2)) &&' '((cmd_export == 9)) &&' \
    "set -a; GIT_EXTERNAL_DIFF=/tmp/prog; git diff HEAD~1"
mutation "noticing a cd or pushd before the command" \
    'moves_dir[idx]=1' 'moves_dir[idx]=0' \
    "cd /etc; shellcheck passwd"
mutation "treating containment as undecidable once the directory moves" \
    '((worktree_moved)) && return 1' ':' \
    "cd /etc; shellcheck - < passwd"
mutation "git's own relocating options" \
    'diff_relocated=1' 'diff_relocated=0' \
    "git -C /etc diff -- passwd shadow"
# shellcheck disable=SC2016 # the find string is the hook's own source text
mutation "env -C, which relocates the command rather than git" \
    '[[ "${raw_word}" =~ ^-[^-]*C || "${raw_word}" == --chdir* ]]' 'false' \
    "env -C /etc git diff -- passwd shadow"
# shellcheck disable=SC2016 # the find string is the hook's own source text
mutation "reading a path to shellcheck as shellcheck" \
    'elif [[ "${word}" == */shellcheck ]]; then' 'elif false; then' \
    "/usr/bin/shellcheck ./.env"
# shellcheck disable=SC2016 # the find string is the hook's own source text
mutation "the += spelling of the SHELLCHECK_OPTS assignment" \
    '"${words[idx]}" == SHELLCHECK_OPTS+=*' '"${words[idx]}" == SHELLCHECK_OPTSxx+=*' \
    "SHELLCHECK_OPTS+=./.env shellcheck tests/run-tests.sh"
mutation "the process wrappers a gated command can sit behind" \
    'setsid | ionice | chrt | taskset | unshare | flock)' \
    'setsidx | ionicex | chrtx | tasksetx | unsharex | flockx)' \
    "setsid podman images >cosign.pub"
# shellcheck disable=SC2016 # the find string is the hook's own source text
mutation "flock's -c/--command handing its argument to a shell" \
    'refuse "${WRAPPER_SHELL_MSG}"' ':' \
    "flock /tmp/l -c 'cat ./cosign.key'"
# shellcheck disable=SC2016 # the find string is the hook's own source text
mutation "refusing a relocated diff before its operands are counted" \
    '((diff_relocated)) && refuse "${MOVED_MSG}"' 'false' \
    "git -C /etc diff HEAD~1"
mutation "noglob among the wrappers Claude Code's matcher steps over" \
    'nohup | noglob | nice' 'nohup | nice' \
    "noglob podman ps >out"
# shellcheck disable=SC2016 # the find string is the hook's own source text
mutation "refusing xargs in front of git or an allow-listed command" \
    'refuse "${XARGS_MSG}"' ':' \
    "printf '%s\n' /dev/null ./cosign.key | xargs git diff"
# shellcheck disable=SC2016 # the find string is the hook's own source text
mutation "a literal path to a wrapper read as that wrapper" \
    'case "${word##*/}" in' 'case "${word}" in' \
    "git status; /usr/bin/xargs git diff"
mutation "reading the next word as the value of an xargs option" \
    'xargs_optarg=1' 'xargs_optarg=0' \
    "xargs -n 1 git diff <list.txt"
mutation "every later word a possible name after an xargs option this does not read" \
    'xargs_state=0 # not an option this reads' 'continue # not an option this reads' \
    "xargs -J % git diff <list.txt"

HOOK_SRC="$(cat "${REPO_ROOT}/.claude/hooks/gate-git-diff.sh")"
MUTANT="${WORK}/gate-mutant.sh"

# Runs the payload `$2` through the hook at `$1` rather than the one the
# settings file names, so a mutated copy is held to the same corpus.
run_pre_hook() {
    local hook=$1 payload=$2
    PRE_OUT="${WORK}/pre-out"
    PRE_ERR="${WORK}/pre-err"
    printf '%s' "${payload}" |
        (cd "${REPO_ROOT}" && CLAUDE_PROJECT_DIR="${REPO_ROOT}" bash "${hook}") \
        >"${PRE_OUT}" 2>"${PRE_ERR}"
    PRE_STATUS=$?
    PRE_OUT="$(cat "${PRE_OUT}")"
    PRE_ERR="$(cat "${PRE_ERR}")"
}

# The unmutated copy first, so the runner itself is not what a flip below is
# measuring.
printf '%s\n' "${HOOK_SRC}" >"${MUTANT}"
run_pre_hook "${MUTANT}" "$(pre_payload_for "git diff /dev/null ./cosign.key")"
assert_eq "an unmutated copy of the hook still refuses the finding" "2" "${PRE_STATUS}"
run_pre_hook "${MUTANT}" "$(pre_payload_for "git diff HEAD")"
assert_eq "and still leaves an ordinary diff alone" "0" "${PRE_STATUS}"

for mutation_entry in "${MUTATIONS[@]}"; do
    mutation_what="${mutation_entry%%$'\t'*}"
    mutation_rest="${mutation_entry#*$'\t'}"
    mutation_find="${mutation_rest%%$'\t'*}"
    mutation_rest="${mutation_rest#*$'\t'}"
    mutation_replace="${mutation_rest%%$'\t'*}"
    mutation_witness="${mutation_rest#*$'\t'}"

    if [[ "${HOOK_SRC}" == *"${mutation_find}"* ]]; then
        _pass "the rule for ${mutation_what} is in the hook"
    else
        _fail "the rule for ${mutation_what} is in the hook" \
            "not found: ${mutation_find}" \
            "a mutation that matches nothing disables nothing and proves nothing"
        continue
    fi

    witness_in_corpus=1
    for corpus_entry in "${CORPUS[@]}"; do
        [[ "${corpus_entry}" == "refuse"$'\t'*$'\t'"${mutation_witness}" ]] || continue
        witness_in_corpus=0
        break
    done
    assert_eq "and its witness is a refuse row of the corpus: ${mutation_witness}" \
        "0" "${witness_in_corpus}"

    printf '%s\n' "${HOOK_SRC//"${mutation_find}"/"${mutation_replace}"}" >"${MUTANT}"
    if bash -n "${MUTANT}" 2>/dev/null; then
        _pass "and the copy with ${mutation_what} disabled still parses"
    else
        _fail "and the copy with ${mutation_what} disabled still parses" \
            "bash -n: $(bash -n "${MUTANT}" 2>&1 | head -1)" \
            "a mutant that cannot run refuses everything and flips nothing"
        continue
    fi

    run_pre_hook "${MUTANT}" "$(pre_payload_for "${mutation_witness}")"
    assert_eq "and disabling it lets the row through: ${mutation_witness}" \
        "0" "${PRE_STATUS}"
done

# 10h. the settings file records the decision, beside the ones for the two
# commands gated by name and for the gated writes.
CORPUS_NOTE="$(jq -r '._note_command_corpus // ""' "${SETTINGS}")"
assert_contains "the note names the issue that decided the corpus in one pass" \
    "${CORPUS_NOTE}" "#222"
assert_contains "and the assignment spelling env parses and bash does not" \
    "${CORPUS_NOTE}" "env 'GIT_EXTERNAL_DIFF'=prog"
assert_contains "and the export spelling that carries no assignment" \
    "${CORPUS_NOTE}" "set -a"
assert_contains "and the glob that grows one operand into two" \
    "${CORPUS_NOTE}" "/etc/passwd*"
assert_contains "and git's config option that runs a program" \
    "${CORPUS_NOTE}" "diff.external"
assert_contains "and the move that makes a containment test undecidable" \
    "${CORPUS_NOTE}" "worktree_moved"
assert_contains "and the literal path to a wrapper, read as that wrapper" \
    "${CORPUS_NOTE}" "/usr/bin/xargs git diff"
assert_contains "and the wrapper the matcher steps over that this gate did not" \
    "${CORPUS_NOTE}" "noglob podman ps >out"
assert_contains "and the wrapper that hands git operands the string never names" \
    "${CORPUS_NOTE}" "| xargs git diff"
assert_contains "and the residual it cannot close" \
    "${CORPUS_NOTE}" "across Bash"
assert_contains "and the test that holds the corpus to it" \
    "${CORPUS_NOTE}" "tests/test-claude-settings.sh"

finish
