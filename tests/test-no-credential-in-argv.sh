#!/usr/bin/env bash
#
# Asserts that no command CI runs takes a token or password on its command line.
#
# On Linux, /proc/<pid>/cmdline is mode 0444: every uid on the runner can read a
# process's arguments for as long as it runs, and any ps capture taken while
# debugging prints them. /proc/<pid>/environ is 0600, and a file can be 0600 too.
# So a credential belongs in the environment, in a file, or on stdin -- never in
# argv. This repository broke that twice, and each fix covered only its own
# site: #150 (`skopeo --creds` in ci/write-badges.sh and nightly-compliance.yml)
# and #155 (the token in status-badges.yml's git remote URL). The sister
# repositories broke it seven more times between them
# (Danathar/zfs-aurora-complex#283). This check fails on the next site where it
# is written instead of waiting for someone to find it.
#
# Scope: every tracked workflow under .github/workflows/, every
# .github/actions/*/action.yml, and every tracked *.sh. Workflows are read
# whole rather than run: block by run: block. Everything the rules below match
# in a workflow is shell, and reading the whole file keeps line numbers exact.
# tests/fixtures/credential-argv/ is left out of the scan, because its files
# hold the bad shapes on purpose.
#
# A finding is a secret-bearing value -- a variable whose name contains TOKEN,
# PASSWORD or SECRET in any case, `${{ github.token }}` or `${{ secrets.* }}` --
# that is either
#
#   * the value of -p, --password, --creds or --registry-password, or
#   * the password in a `user:<secret>@` URL.
#
# The one exception is printf writing to a pipe or a file (`printf ... |` or
# `printf ... > file`). printf is a shell builtin, so no new process is started
# with the token in its argv. Anything else that consumes printf's output, such
# as a command substitution passed as an argument, still counts.
#
# Commands are read as logical lines, with backslash-newline continuations
# joined, because the #150 site split its flags across lines. Comment lines are
# skipped. A flag's value is read as one shell word, quoted parts included, so
# `"${{ github.token }}"` and `"$(cat "${token_file}")"` are each one value.

set -uo pipefail

TEST_NAME="test-no-credential-in-argv"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
FIXTURES="${TEST_DIR}/fixtures/credential-argv"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

# any_case <word> -- a bracket expression per letter, so the regexes below
# match the word in any case without changing shell options.
any_case() {
    local word=$1 out="" char i
    for ((i = 0; i < ${#word}; i++)); do
        char=${word:i:1}
        out+="[${char,,}${char^^}]"
    done
    printf '%s' "${out}"
}

SECRET_NAME="[A-Za-z0-9_]*($(any_case token)|$(any_case password)|$(any_case secret))[A-Za-z0-9_]*"
# A reference to a secret-bearing shell variable: $NAME or ${NAME.
SECRET_REF="[\$][{]?${SECRET_NAME}"
# An Actions expression naming one value, such as ${{ github.token }}.
EXPR_RE='[$][{][{][[:space:]]*([A-Za-z0-9_]+)[.]([A-Za-z0-9_]+)[[:space:]]*[}][}]'
# A credential flag and the shell word after it.
FLAG_RE="(^|[[:space:]\"'(])(-p|--password|--creds|--registry-password)([[:space:]]+|=)((\"[^\"]*\"|'[^']*'|[^[:space:]\"']+)+)"
# A secret as the password part of a URL.
URL_RE="[^[:space:]/@:\"']+:${SECRET_REF}[}]?@"
# The text of the command a match sits in, before and after it.
LAST_CMD_RE='([^|;&(]*)$'
NEXT_CMD_RE='^([^|;&)]*)(.?.?)'
PRINTF_RE='^[[:space:]]*printf([[:space:]]|$)'

# logical_lines <file> -- print "<file>:<first line>:<text>" for each logical
# line, with backslash-newline continuations joined.
logical_lines() {
    awk '
        buf == "" { start = FNR }
        /\\$/ { buf = buf substr($0, 1, length($0) - 1) " "; next }
        { print FILENAME ":" start ":" buf $0; buf = "" }
        END { if (buf != "") print FILENAME ":" start ":" buf }
    ' "$1"
}

# printf_writes <text before the match> <text after it> -- succeed when the
# match is an argument of printf and printf's output goes to a pipe or a file.
printf_writes() {
    local head tail next
    [[ "$1" =~ ${LAST_CMD_RE} ]]
    head=${BASH_REMATCH[1]}
    [[ "${head}" =~ ${PRINTF_RE} ]] || return 1
    [[ "$2" =~ ${NEXT_CMD_RE} ]]
    tail=${BASH_REMATCH[1]}
    next=${BASH_REMATCH[2]}
    [[ "${head}${tail}" == *'>'* ]] && return 0
    [[ "${next}" == '|'* && "${next}" != '||' ]]
}

# report <where> <kind> <match> <text before> <text after> -- print one site,
# as "printf" when printf_writes allows it and as <kind> otherwise.
report() {
    if printf_writes "$4" "$5"; then
        printf '%s:printf:%s\n' "$1" "$3"
    else
        printf '%s:%s:%s\n' "$1" "$2" "$3"
    fi
}

# credential_sites <file>... -- print "<file>:<line>:<kind>:<match>" for every
# secret on a command line outside a comment line. <kind> is flag or url for a
# finding, and printf for a site the printf exception allows.
credential_sites() {
    local file entry where text rest seen match flag value before after placeholder
    for file in "$@"; do
        while IFS= read -r entry; do
            # Tracked paths here carry no colon, so the first two fields are
            # the file and the line, and the rest is the command text.
            text=${entry#*:*:}
            where=${entry%":${text}"}
            [[ "${text}" =~ ^[[:space:]]*# ]] && continue

            # ${{ github.token }} becomes $EXPR_github_token: one word, and a
            # name the secret pattern recognises.
            while [[ "${text}" =~ ${EXPR_RE} ]]; do
                placeholder="\$EXPR_${BASH_REMATCH[1]}_${BASH_REMATCH[2]}"
                text=${text/"${BASH_REMATCH[0]}"/"${placeholder}"}
            done

            rest=${text} seen=""
            while [[ "${rest}" =~ ${FLAG_RE} ]]; do
                match=${BASH_REMATCH[0]}
                flag=${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}
                value=${BASH_REMATCH[4]}
                before=${seen}${rest%%"${match}"*}
                after=${rest#*"${match}"}
                seen=${before}${match}
                rest=${after}
                [[ "${value}" =~ ${SECRET_REF} ]] || continue
                report "${where}" flag "${flag}" "${before}" "${after}"
            done

            rest=${text} seen=""
            while [[ "${rest}" =~ ${URL_RE} ]]; do
                match=${BASH_REMATCH[0]}
                before=${seen}${rest%%"${match}"*}
                after=${rest#*"${match}"}
                seen=${before}${match}
                rest=${after}
                report "${where}" url "${match}" "${before}" "${after}"
            done
        done < <(logical_lines "${file}")
    done
}

# --- the detector against known answers ------------------------------------

# Each fixture's verdicts as "<line>:<kind>", one per site, in order.
verdicts() {
    credential_sites "$1" | cut -d: -f2,3
}

assert_eq "#150: both skopeo --creds sites in nightly-compliance.yml are flagged" \
    "$(printf '%s\n' 15:flag 27:flag)" "$(verdicts "${FIXTURES}/150-nightly-compliance.yml")"

assert_eq "#150: write-badges.sh's --creds array is flagged" \
    "8:flag" "$(verdicts "${FIXTURES}/150-write-badges.txt")"

assert_eq "#155: the token in status-badges.yml's git remote URL is flagged" \
    "17:url" "$(verdicts "${FIXTURES}/155-status-badges.yml")"

assert_eq "the other spellings are each flagged" \
    "$(printf '%s\n' 5:flag 7:flag 9:flag 11:flag 13:url 16:url)" \
    "$(verdicts "${FIXTURES}/other-shapes.txt")"

# The allowed file passes because of the printf exception, not because the
# detector missed its URLs: both printf writes are seen and allowed.
assert_eq "stdin, files, the environment and printf into a pipe or a file pass" \
    "$(printf '%s\n' 23:printf 24:printf)" "$(verdicts "${FIXTURES}/allowed.yml")"

# --- the tree ----------------------------------------------------------------

mapfile -t SCANNED < <(
    cd "${REPO_ROOT}" &&
        git ls-files -- '.github/workflows/*.yml' '.github/workflows/*.yaml' \
            '.github/actions/*/action.yml' '.github/actions/*/action.yaml' '*.sh' \
            ':(exclude)tests/fixtures/credential-argv' |
        sed "s|^|${REPO_ROOT}/|"
)

# A scan that reads nothing passes everything, so the files #150 and #155 were
# found in must still be read, and the fixtures must not be.
SCANNED_LIST=$(printf '%s\n' "${SCANNED[@]}")
for expected in .github/workflows/nightly-compliance.yml .github/workflows/status-badges.yml \
    ci/write-badges.sh tests/test-no-credential-in-argv.sh; do
    assert_contains "the scan reads ${expected}" "${SCANNED_LIST}" "${REPO_ROOT}/${expected}"
done
assert_not_contains "the scan skips the fixtures" "${SCANNED_LIST}" "${FIXTURES}/"

FINDINGS=$(credential_sites "${SCANNED[@]}" | grep -v '^[^:]*:[0-9]*:printf:' | sed "s|^${REPO_ROOT}/||")
if [[ -z "${FINDINGS}" ]]; then
    _pass "no command CI runs takes a token or password on its command line"
else
    _fail "no command CI runs takes a token or password on its command line" \
        "pass the secret on stdin, in a 0600 file or in the environment instead:" \
        "${FINDINGS}"
fi

finish
