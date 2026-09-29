#!/usr/bin/env bash
#
# Joins docs/SECURITY-AI.md's list of the gate hook's refusal categories (the
# bullets after "Categories worth knowing") to the hook that implements them,
# .claude/hooks/gate-git-diff.sh.
#
# The list grew from four bullets to thirteen over two days (#272, #279, #280,
# #284), and one of its examples was wrong for a day: `git diff cosign.key
# .env` was given as the plain-file mode when git reads two in-tree paths as
# pathspecs and prints nothing (b817423). Nothing read the list against the
# hook, so a renamed message, a dropped refusal or a new category the hook
# grew would all have left the page describing a gate that no longer exists.
#
# Every example the list gives is run through the hook here instead of trusted:
#
#   1. each bullet is claimed by the manifest below and each manifest lead is a
#      bullet on the page, so a bullet added or renamed without a row fails;
#   2. each refused row's needle is in its bullet, and the hook exits 2 on its
#      command with exactly the named *_MSG on stderr -- not merely some
#      refusal, since a category the page names under one message and the hook
#      refuses under another is the drift this file exists to catch;
#   3. each "unaffected" spelling the page promises (a tilde inside a word, a
#      quoted or escaped extglob) exits 0 with nothing on stderr;
#   4. every *_MSG the hook defines is either named by a refused row or listed
#      in NOT_LISTED, both directions, so a message the hook adds forces a
#      decision here rather than going unmentioned.
#
# A placeholder the page writes in capitals (FILE, COMMAND, DIR) is kept as
# typed where the hook refuses it that way, and replaced by a secret-shaped
# path (.env, cosign.pub) where the refusal depends on the path.

# The awk programs below are single-quoted so that `$0` reaches awk rather than
# the shell, and the manifest quotes shell spellings as literal text. SC2016 is
# off for the file rather than repeated.
# shellcheck disable=SC2016

set -uo pipefail

TEST_NAME="test-gate-refusal-docs"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

SECURITY_MD="${REPO_ROOT}/docs/SECURITY-AI.md"
HOOK="${REPO_ROOT}/.claude/hooks/gate-git-diff.sh"
LIST_START="Categories worth knowing"
LIST_END="Never, under any circumstances"

for required in "${SECURITY_MD}" "${HOOK}"; do
    assert_file_exists "${required#"${REPO_ROOT}/"} is present" "${required}"
done

# --- the manifest ------------------------------------------------------------

# lead | message | needle in that bullet | command run through the hook
REFUSED="$(
    cat <<'EOF'
a write hidden in an option.|PODMAN_PROFILE_MSG|`podman --cpu-profile FILE`|podman images --cpu-profile FILE
a write hidden in an option.|PODMAN_PROFILE_MSG|`--memory-profile FILE`|podman ps --memory-profile FILE
a write hidden in an option.|PODMAN_PROFILE_MSG|their `=FILE` forms|podman inspect --cpu-profile=FILE x
an allow-listed check re-enabling execution.|BASH_NOEXEC_MSG|`bash -n +n -c COMMAND`|bash -n +n -c COMMAND
an allow-listed check re-enabling execution.|BASH_NOEXEC_MSG|`+o noexec`|bash -n +o noexec tests/run-tests.sh
a git command driven to run a program via config or environment.|GATED_ENV_MSG|`GIT_EXTERNAL_DIFF=prog git diff HEAD~1`|GIT_EXTERNAL_DIFF=prog git diff HEAD~1
a git command driven to run a program via config or environment.|GIT_CONFIG_MSG|`git -c diff.external=prog diff`|git -c diff.external=prog diff
a git command driven to run a program via config or environment.|GIT_CONFIG_MSG|`--config-env=...`|git --config-env=diff.external=V diff HEAD~1
a git command driven to run a program via config or environment.|GIT_CONFIG_MSG|`--exec-path`|git --exec-path=/tmp diff HEAD~1
a git command driven to run a program via config or environment.|GIT_CONFIG_MSG|`--upload-pack`|git --upload-pack=prog log
a git command driven to run a program via config or environment.|GIT_CONFIG_MSG|`--receive-pack`|git --receive-pack=prog log
a git command driven to run a program via config or environment.|GIT_CONFIG_MSG|`core.sshCommand`|git -c core.sshCommand=prog log
a git command driven to run a program via config or environment.|GIT_CONFIG_MSG|`core.hooksPath`|git -c core.hooksPath=/tmp show
a git command driven to run a program via config or environment.|GIT_CONFIG_MSG|`uploadpack.packObjectsHook`|git -c uploadpack.packObjectsHook=prog log
a git command driven to run a program via config or environment.|GIT_CONFIG_MSG|`credential.helper`|git -c credential.helper=prog log
a wrapper command that hands its argument to a shell.|WRAPPER_SHELL_MSG|`flock -c COMMAND`|flock -c COMMAND
a wrapper command that hands its argument to a shell.|WRAPPER_SHELL_MSG|`--command=COMMAND`|flock /tmp/l --command=COMMAND
a wrapper command that hands its argument to a shell.|WRAPPER_SHELL_MSG|`flock /tmp/l -c 'cat ./cosign.key'`|flock /tmp/l -c 'cat ./cosign.key'
`git diff`'s plain-file mode.|DIFF_MSG|`git diff cosign.key /dev/null`|git diff cosign.key /dev/null
an unquoted leading `~`.|TILDE_MSG|`git diff -- ~/.aws/credentials ~/.bashrc`|git diff -- ~/.aws/credentials ~/.bashrc
shellcheck echoing the file it lints.|SHELLCHECK_MSG|secret-shaped path — directly|shellcheck .env
shellcheck echoing the file it lints.|SHELLCHECK_READ_MSG|`shellcheck - < FILE`|shellcheck - < .env
shellcheck echoing the file it lints.|SHELLCHECK_SOURCED_MSG|`--check-sourced`|shellcheck --check-sourced tests/run-tests.sh
shellcheck echoing the file it lints.|SHELLCHECK_SOURCED_MSG|`-a`|shellcheck -a tests/run-tests.sh
`bash -n` echoing the line it stops on.|BASH_READ_MSG|`bash -n .env`|bash -n .env
a redirection into a gated read.|GIT_STDIN_MSG|`git log`/`show`/`diff --stdin < FILE`|git log --stdin < .env
a redirection into a gated read.|GIT_STDIN_MSG|`git log`/`show`/`diff --stdin < FILE`|git show --stdin < .env
a redirection into a gated read.|GIT_STDIN_MSG|`git log`/`show`/`diff --stdin < FILE`|git diff --stdin < .env
a redirection into a gated read.|BASH_READ_MSG|`bash -n - < FILE`|bash -n - < .env
a gh filter reading the environment.|GH_JQ_ENV_MSG|`gh pr view 1 --json number --jq env`|gh pr view 1 --json number --jq env
a gh filter reading the environment.|GH_JQ_ENV_MSG|(`-q`)|gh run list -q env
a gh filter reading the environment.|GH_JQ_ENV_MSG|`{e,}nv`|gh run view 1 --jq {e,}nv
`git --output=FILE`.|OUT_MSG|`git --output=FILE`|git --output=cosign.pub diff HEAD
`git --output=FILE`.|OUT_MSG|Writes the diff or log|git log --output=cosign.pub
moving the directory operands resolve against.|MOVED_MSG|A `cd`/`pushd` before|cd /tmp && git diff -- .bashrc .profile
moving the directory operands resolve against.|MOVED_MSG|A `cd`/`pushd` before|pushd /home && shellcheck .bashrc
moving the directory operands resolve against.|MOVED_MSG|`env -C DIR`|env -C /tmp git diff HEAD
moving the directory operands resolve against.|MOVED_MSG|git's own `-C`|git -C /tmp diff -- .bashrc .profile
moving the directory operands resolve against.|MOVED_MSG|`--git-dir`|git --git-dir=/tmp/x diff -- a b
moving the directory operands resolve against.|MOVED_MSG|`--work-tree`|git --work-tree=/tmp diff -- a b
moving the directory operands resolve against.|MOVED_MSG|`--namespace`|git --namespace=x diff -- a b
moving the directory operands resolve against.|MOVED_MSG|`--super-prefix`|git --super-prefix=x diff -- a b
moving the directory operands resolve against.|MOVED_MSG|`--attr-source`|git --attr-source=x diff -- a b
an extglob pattern standing in for a path.|SHELLCHECK_EXPAND_MSG|`shellcheck @(.env)`|shellcheck @(.env)
an extglob pattern standing in for a path.|SHELLCHECK_EXPAND_MSG|`+(...)`|shellcheck +(.env)
an extglob pattern standing in for a path.|SHELLCHECK_EXPAND_MSG|`?(...)`|shellcheck ?(.env)
an extglob pattern standing in for a path.|SHELLCHECK_EXPAND_MSG|`*(...)`|shellcheck *(.env)
an extglob pattern standing in for a path.|SHELLCHECK_EXPAND_MSG|`!(...)`|shellcheck !(.env)
an extglob pattern standing in for a path.|SHELLCHECK_READ_MSG|`shellcheck - < @(.env)`|shellcheck - < @(.env)
an extglob pattern standing in for a path.|GIT_STDIN_MSG|`git log --stdin < @(.env)`|git log --stdin < @(.env)
an extglob pattern standing in for a path.|BASH_EXPAND_MSG|`bash -n @(+n) -c COMMAND`|bash -n @(+n) -c COMMAND
an extglob pattern standing in for a path.|PODMAN_EXPAND_MSG|`podman images @(--cpu-profile=cosign.pub)`|podman images @(--cpu-profile=cosign.pub)
EOF
)"

# lead | needle in that bullet | command the page says the hook lets through
ALLOWED="$(
    cat <<'EOF'
a gh filter reading the environment.|(`--jq .title`) is unaffected|gh pr view 1 --json title --jq .title
an unquoted leading `~`.|a tilde inside a word (`HEAD~1`)|git diff HEAD~1
an unquoted leading `~`.|or a quoted one is a literal|git diff HEAD -- '~/.bashrc'
an extglob pattern standing in for a path.|a quoted (`'@(x)'`)|shellcheck '@(x)'
an extglob pattern standing in for a path.|or escaped (`\@(x)`)|shellcheck \@(x)
EOF
)"

# Messages the hook defines that no bullet describes today. The list is
# "worth knowing", not exhaustive; naming them here makes leaving one out a
# decision rather than an accident.
NOT_LISTED="BASH_ECHO_MSG CMD_MSG EXPAND_MSG EXPORT_ENV_MSG GATED_HEREDOC_MSG GATED_REDIRECT_MSG GATED_SUBST_MSG GIT_GLOB_MSG REDIRECT_MSG SHELLCHECK_OPTS_MSG WRAPPER_PATH_MSG XARGS_MSG"

# --- helpers -----------------------------------------------------------------

# The refusal-category list: the lines after the one naming LIST_START, up to
# the line that begins LIST_END.
category_list() {
    awk -v start="$1" -v end="$2" '
        index($0, start) { inside = 1; next }
        inside && index($0, end) == 1 { exit }
        inside
    ' "$3"
}

# One line per bullet on stdin: "lead<TAB>whole bullet, whitespace squashed".
# A bullet is a `- **lead**` line and the indented lines after it, so a phrase
# Markdown wrapped across two lines still matches as one.
bullets() {
    awk '
        function emit() { if (lead != "") { gsub(/[ \t]+/, " ", text); print lead "\t" text } }
        /^- \*\*/ {
            emit()
            rest = substr($0, 5)
            lead = substr(rest, 1, index(rest, "**") - 1)
            text = $0
            next
        }
        /^  / && lead != "" { text = text " " $0; next }
        { emit(); lead = ""; text = "" }
        END { emit() }
    '
}

# Sorted, de-duplicated, one per line, so two sets compare as two strings.
as_set() {
    sort -u | grep -v '^$'
}

require_nonempty() {
    local description=$1 value=$2
    if [[ -n "${value}" ]]; then
        _pass "${description} is not empty"
        return 0
    fi
    _fail "${description} is not empty" "the extractor returned nothing"
    return 1
}

# Run the hook on a Bash tool call the way Claude Code does: JSON on stdin,
# the checkout as CLAUDE_PROJECT_DIR. Sets hook_rc and hook_err.
run_hook() {
    local payload
    payload="$(jq -nc --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}')"
    hook_err="$(printf '%s' "${payload}" | CLAUDE_PROJECT_DIR="${REPO_ROOT}" bash "${HOOK}" 2>&1 >/dev/null)"
    hook_rc=$?
}

# --- 0. the extractors, against a fixture ------------------------------------

fixture_file="$(mktemp)"
trap 'rm -f "${fixture_file}"' EXIT
printf '%s\n' '- **not listed.** before the list' 'Categories worth knowing, say:' '' \
    '- **one.** first `a` and' '  wrapped   `b`.' '- **`two`.** second' 'prose ends the bullet' \
    '  - **nested.** not a bullet' 'Never, under any circumstances:' '- **after.** x' >"${fixture_file}"
assert_eq "fixture: bullets reads only the list, joins wrapped lines and squashes whitespace" \
    $'one.\t- **one.** first `a` and wrapped `b`.\n`two`.\t- **`two`.** second' \
    "$(category_list "${LIST_START}" "${LIST_END}" "${fixture_file}" | bullets)"

# --- 1. the page's bullets against the manifest's leads ----------------------

LIST="$(category_list "${LIST_START}" "${LIST_END}" "${SECURITY_MD}")"
require_nonempty "docs/SECURITY-AI.md's refusal-category list" "${LIST}" || {
    finish
    exit
}
BULLETS="$(bullets <<<"${LIST}")"
require_nonempty "the list's bullets" "${BULLETS}"

assert_eq "every bullet on the page has a manifest row, and every manifest lead is a bullet" \
    "$(cut -f1 <<<"${BULLETS}" | as_set)" \
    "$(printf '%s\n%s\n' "${REFUSED}" "${ALLOWED}" | cut -d'|' -f1 | as_set)"

bullet_text() {
    awk -F'\t' -v want="$1" '$1 == want { print $2 }' <<<"${BULLETS}"
}

# --- 2. the hook's messages ---------------------------------------------------

# The assignments are single-quoted literals (a quote inside one is spelled
# '"'"'), so evaluating those lines alone yields exactly what `refuse` prints.
MSG_ASSIGNMENTS="$(grep -E "^[A-Z_]+_MSG='" "${HOOK}")"
eval "${MSG_ASSIGNMENTS}"
HOOK_MSGS="$(sed -E 's/=.*//' <<<"${MSG_ASSIGNMENTS}" | as_set)"
require_nonempty "the hook's *_MSG assignments" "${HOOK_MSGS}"

while IFS= read -r name; do
    if [[ "${!name}" == blocked:* ]]; then
        _pass "${name} evaluates to a refusal message"
    else
        _fail "${name} evaluates to a refusal message" "got: ${!name:0:80}"
    fi
done <<<"${HOOK_MSGS}"

LISTED_MSGS="$(cut -d'|' -f2 <<<"${REFUSED}" | as_set)"
assert_eq "every *_MSG the hook defines is described by a bullet or named in NOT_LISTED" \
    "${HOOK_MSGS}" \
    "$(printf '%s\n' "${LISTED_MSGS}" "${NOT_LISTED// /$'\n'}" | as_set)"
assert_eq "no message is both described by a bullet and named in NOT_LISTED" \
    "" "$(comm -12 <(printf '%s\n' "${LISTED_MSGS}") <(tr ' ' '\n' <<<"${NOT_LISTED}" | as_set))"

# --- 3. each refused example -------------------------------------------------

while IFS='|' read -r lead msg needle command; do
    assert_contains "bullet '${lead}' names ${needle}" "$(bullet_text "${lead}")" "${needle}"
    run_hook "${command}"
    if [[ "${hook_rc}" -eq 2 && "${hook_err}" == "${!msg-}" ]]; then
        _pass "the hook refuses '${command}' with ${msg}"
    else
        _fail "the hook refuses '${command}' with ${msg}" \
            "exit ${hook_rc}, stderr: ${hook_err:0:120}"
    fi
done <<<"${REFUSED}"

# --- 4. each spelling the page says is unaffected ----------------------------

while IFS='|' read -r lead needle command; do
    assert_contains "bullet '${lead}' names ${needle}" "$(bullet_text "${lead}")" "${needle}"
    run_hook "${command}"
    if [[ "${hook_rc}" -eq 0 && -z "${hook_err}" ]]; then
        _pass "the hook lets '${command}' through"
    else
        _fail "the hook lets '${command}' through" "exit ${hook_rc}, stderr: ${hook_err:0:120}"
    fi
done <<<"${ALLOWED}"

finish
