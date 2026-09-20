#!/usr/bin/env bash
# PreToolUse gate on the Bash tool.
#
# .claude/settings.json denies the Read tool this repository's secret-shaped
# paths -- cosign.key, a .env -- and allows `git diff`, `git log`, `git show`
# and `git ls-files` with no prompt. Those are rules on different tools: a deny
# rule on Read says nothing about what an allowed Bash command opens or writes,
# and this family of commands carries one primitive of each kind.
#
# The read primitive: `git diff` in its two-path mode compares operands as
# plain files rather than as repository content, so it prints any file this uid
# can read -- untracked, gitignored, or outside the checkout entirely -- and
# never consults the deny list. `cat ./cosign.key` prompts; the diff form did
# not.
#
# Five things this gate has to get right, each of them a spelling an earlier
# version of it missed:
#
#   1. The mode has no required flag. `git diff /dev/null ./cosign.key` prints
#      the file with no `--no-index` anywhere in the command, because git
#      enters that mode on its own when two operands are given and either one
#      is not repository content. Matching the flag string alone missed this
#      entirely.
#   2. The shell rewrites the command before git sees it. `--no-'index'` and
#      `--no-\index` both reach git as `--no-index` while a substring test on
#      the typed spelling finds neither.
#   3. `--` does not end the mode. `git diff -- /dev/null ./cosign.key` prints
#      the file: git's own scan (builtin/diff.c, cmd_diff) consumes a leading
#      `--` and then applies the same two-operand test to whatever follows.
#      Only an operand *before* the `--` stops that scan, which is why
#      `git diff HEAD -- path` can never be a plain-file read but
#      `git diff -- a b` can.
#   4. A lone `-` is an operand, not a flag. Git diff reads it as stdin and
#      counts it toward the same two-operand test, so `git diff ./cosign.key -`
#      prints the file. Skipping every dash-prefixed word -- which is right for
#      `--stat`, `-U0` and the rest, since git rejects an unknown one -- leaves
#      the operand count one short of the refusal.
#   5. Git decides inside-or-outside on the spelling, not on where the path
#      lands. `git diff -- ../<checkout>/cosign.key -` names a file inside this
#      repository by a route that leaves it and comes back; git calls that
#      outside and prints the file, while a test that folds `..` first sees a
#      tidy in-tree path and allows it. See `path_inside_worktree` below.
#   6. Bash rewrites the words before git sees them, and this scan reads them
#      as typed. A brace turns one word into two -- `git diff
#      {/dev/null,./cosign.key}` passes the operand scan as a single operand
#      and reaches git as two -- and it splits a flag name so that no word
#      here matches it: `--outpu{t,t}=FILE` arrives at git as `--output=FILE`.
#      ANSI-C quoting does the same to the flag, since the quote and backslash
#      stripping below leaves `--outpu$'\x74'=FILE` as `--outpu$x74=FILE`
#      while git receives `--output=FILE`. Command substitution supplies
#      operands this scan never counted at all. Those characters are refused
#      inside a git invocation rather than expanded -- every `$` and
#      backtick, and a brace bash would expand; one it would not, git's own
#      `HEAD@{1}` or `main@{upstream}`, is left alone. See
#      `brace_would_expand` and `EXPAND_MSG`.
#
# The write primitive: `--output=FILE` sends the diff git would have printed to
# a path instead of stdout, so an allow-listed, unprompted call overwrites any
# file this uid can reach -- `cosign.pub`, which is the signature trust anchor
# committed here and the one README tells consumers to verify against;
# `.claude/settings.json`; this hook; `~/.ssh/authorized_keys`. The deny rules
# are no help, because they gate the Read tool and say nothing about what an
# allowed Bash command writes. The operand scan below cannot see it either: it
# skips every dash-prefixed word, and it stops tracking git at the subcommand,
# while `git log -p --output=FILE` and `git show --output=FILE` are allow-listed
# and reach the same primitive. `git show` refuses the flag only for a
# *combined* diff -- a merge commit -- and writes an ordinary commit's diff in
# full, so "git show rejects --output" is not a reason to leave it out.
#
# The written content is diff-framed rather than byte-clean, which matters less
# than it sounds: the `+` lines carry whatever the caller committed, and for a
# trust anchor or a config file corruption alone is the event. Nothing
# legitimate needs the flag -- diff, log and show print to stdout, which the
# agent already reads -- so the refusal is the whole git invocation rather than
# one subcommand. `--output-indicator-new` and its siblings change the marker
# character rather than the destination and stay permitted.
#
# So this looks at the operands git would actually receive, and refuses the
# two-operand form unless every operand resolves as a revision -- which is what
# separates `git diff main feature` from `git diff /dev/null ./cosign.key`.
# After a bare `--` no word can be a revision, so there the test is git's own:
# two or more words where any one lies outside the working tree. The write
# primitive needs none of that machinery: `--output` anywhere in a git
# invocation is refused outright.
#
# What it still cannot see, stated rather than implied: a command that hides a
# git invocation behind another interpreter (`sh -c ...`), one that changes
# directory out of the repository first, and anything a command reads or writes
# once it has started. A git argument built at runtime is no longer waved
# through -- the expansion characters that build it are refused -- but that is
# a refusal, not an inspection. This re-gates the pre-approved commands that
# reach past the deny list; it is not a sandbox.

set -uo pipefail

refuse() {
  printf '%s\n' "$1" >&2
  exit 2
}

DIFF_MSG='blocked: this git diff would compare paths as plain files (git'"'"'s --no-index mode, which needs no flag once two operands are given), so it prints any file on disk -- cosign.key, a .env, a private key outside this repository -- past the Read(...) deny rules in .claude/settings.json. Describe such a file with ls -l or wc -c instead.'

# shellcheck disable=SC2016 # the message quotes shell spellings as literal
# text -- $'\x74' and $(...) are what the reader has to see, not what this
# script should expand.
EXPAND_MSG='blocked: bash expands braces, ANSI-C quotes and substitutions before git sees the words, and this gate reads the words as typed, so four characters rebuild both spellings it refuses: `git diff {/dev/null,./cosign.key}` passes the operand scan as one word and reaches git as two operands (the plain-file read), `--outpu{t,t}=FILE` and `--outpu$'"'"'\x74'"'"'=FILE` match no word here and reach git as --output=FILE, and `git diff $(...)` supplies operands this scan never saw. Expanding them correctly means reimplementing bash inside a hook, so a brace bash would expand -- one holding a comma or a .. range -- and every $ and backtick are refused instead. Write the command out in full. A brace with neither, such as HEAD@{1} or main@{upstream}, is a literal to bash and is not refused. Only words of a git invocation are affected: awk and jq programs elsewhere in the string are not.'

OUT_MSG='blocked: git --output=FILE (and the space form) writes this diff or log to the path it names instead of stdout, overwriting any file this uid can reach -- cosign.pub, .claude/settings.json, this hook, ~/.ssh/authorized_keys -- with no Read(...) deny rule in its way. git diff, git log and git show print to stdout; read that instead. --output-indicator-* is a different flag and is unaffected.'

# Fail closed. This gate stands in front of the pre-approved commands that can
# read a denied path, so a missing dependency must not quietly disable it:
# AGENTS.md requires that setup of this kind fail closed, and a hook that lets
# calls through uninspected when jq is absent is exactly that requirement
# broken by accident.
command -v jq >/dev/null 2>&1 ||
  refuse 'blocked: this PreToolUse hook needs jq to inspect the command and jq is not on PATH. It gates the pre-approved commands that can read a denied path, so it refuses rather than letting calls through uninspected. Install jq.'

payload="$(cat)"
command_string="$(printf '%s' "${payload}" | jq -r '.tool_input.command // empty')" ||
  refuse 'blocked: this PreToolUse hook could not parse the tool payload as JSON, so it cannot tell whether the call reads a denied path. It refuses rather than letting the call through uninspected.'

[[ -n "${command_string}" ]] || exit 0

cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || true

# Match the word git receives, not the spelling typed: the shell removes
# quoting and backslashes on the way.
normalized="${command_string//[\'\"\\]/}"
normalized="${normalized//$'\n'/ }"
normalized="${normalized//$'\t'/ }"

case "${normalized}" in
*--no-index*) refuse "${DIFF_MSG}" ;;
*) ;;
esac

# Shell operators need no whitespace around them, and this scan splits on
# whitespace alone. `ls&&git diff /dev/null ./cosign.key` tokenizes as `ls&&git`,
# which is not the word `git`, so the command would never be recognized as a git
# invocation and every test below would stay switched off for it -- the hook
# exits 0 while the signing key is printed. The write half has the same hole:
# `true;git log -p --output=cosign.pub -1`. Give each operator character
# whitespace of its own, so a command written hard against one is still a
# command here.
for operator_char in '(' ')' ';' '&' '|' '`'; do
  normalized="${normalized//"${operator_char}"/ ${operator_char} }"
done

read -r -a words <<<"${normalized}"

# Git's path_inside_repo, which decides on the *spelling* rather than on where
# the path ends up. That distinction is the whole of this function, and folding
# `..` before the comparison gets it backwards: `git diff --
# ../<checkout>/cosign.key -` names a file inside this repository by a route
# that leaves it and comes back, git's test calls that outside and enters the
# plain-file mode, and a gate that resolved the path first saw a tidy in-tree
# path and allowed it -- reading a denied path with two operands that both look
# local. So an absolute path, any `..` component, and the stdin operand `-` each
# count as outside here, and only a plain relative path is resolved at all.
# Anything this cannot decide -- no working tree, no realpath on the host --
# counts as outside too, so the gate refuses rather than guesses.
path_inside_worktree() {
  local candidate toplevel
  case "$1" in
  - | /*) return 1 ;;
  ../* | */../* | */..) return 1 ;;
  ..) return 1 ;;
  *) ;;
  esac
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  candidate="$(realpath -m -s -- "$1" 2>/dev/null)" || return 1
  [[ "${candidate}" == "${toplevel}" || "${candidate}" == "${toplevel}"/* ]]
}

# Bash's own rule, and only the half of it that matters here: a brace is
# expanded when a comma or a `..` sequence sits inside it -- `{a,b}`, `{1..9}`,
# `a{,b}`, `{{a,b}}` -- and is a literal otherwise, which is what git's
# `HEAD@{1}`, `main@{upstream}` and `@{-1}` rely on. This expands nothing; it
# asks whether bash would, and it errs toward yes. The comma or `..` is looked
# for at any depth, since `{{a,b}}` is `{a} {b}` to bash; a `{` that never
# closes counts; a quoted brace bash would leave alone was unquoted by the
# normalization above and counts too; and `${VAR}` counts, though the `$` in
# it is refused on its own below. Every one of those over-counts is a refusal.
# What it never does is call a word literal that bash would rewrite: every
# expansion bash performs has a comma or `..` between a `{` and a `}`.
brace_would_expand() {
  local text="$1" depth=0 i
  for ((i = 0; i < ${#text}; i++)); do
    case "${text:i:1}" in
    '{') depth=$((depth + 1)) ;;
    '}') ((depth > 0)) && depth=$((depth - 1)) ;;
    ',') ((depth > 0)) && return 0 ;;
    '.') ((depth > 0)) && [[ "${text:i+1:1}" == "." ]] && return 0 ;;
    '$') [[ "${text:i+1:1}" == "{" ]] && return 0 ;;
    *) ;;
    esac
  done
  return 1
}

seen_git=0
in_git=0
in_diff=0
operands=0
unresolved=0
after_dashdash=0
skip_git_option_value=0

for word in "${words[@]+"${words[@]}"}"; do
  # Checked before the command-boundary case below, because a backtick is one
  # of the characters refused here and that case consumes it.
  #
  # Every test in this scan reads the word as typed, and bash rewrites the
  # words before git receives them. A brace makes one word into two, so
  # `git diff {/dev/null,./cosign.key}` is a single operand here and two
  # operands at git -- one short of the refusal. A brace inside a flag name
  # makes the flag unrecognizable here and whole at git: `--outpu{t,t}=FILE`
  # arrives as `--output=FILE`. `$'\x74'` does the same by another route, and
  # `$(...)`, `${x}`, `$x` and a backtick each supply words this scan never
  # saw. Four characters rebuild both refusals.
  #
  # They are refused rather than expanded. Correct expansion means
  # reimplementing bash in a hook -- nesting, `{1..9}` sequences, quoting,
  # word splitting on $IFS -- and a half-right expansion is a gate that
  # disagrees with the shell in some other direction. A refusal cannot be
  # half-right, and a git argument built at runtime was already outside what
  # this hook can vouch for, so refusing it turns a silent pass into a
  # visible refusal. It is not every brace, though: bash leaves a brace alone
  # unless a comma or a `..` range sits inside it, and git's own `@{...}`
  # revision syntax -- `HEAD@{1}`, `main@{upstream}`, `@{-1}`,
  # `@{2.days.ago}` -- is spelled with exactly that literal form. Refusing it
  # blocks the ordinary diff against the previous commit for no gain, so the
  # brace test is `brace_would_expand`: a comma or `..` somewhere inside a
  # brace, which every expansion bash performs must have, and nothing bash
  # would leave alone needs. `$` and a backtick stay refused as typed: neither
  # has a literal form git relies on.
  #
  # Scoped to `in_git`, the same latch `--output` uses, so `awk '{print $1}'`
  # and `jq '{a:1}'` are untouched in a command string that never invokes git.
  # A brace or a `$` *before* the first `git` word is not checked and does not
  # need to be: the allow rules in .claude/settings.json match a literal
  # `git diff`/`git log` prefix, so an invocation assembled out of expansions
  # (`{git,:} diff ...`, `g{i,i}t diff ...`, `$GIT diff ...`) matches no allow
  # rule and prompts on its own.
  if ((in_git)); then
    case "${word}" in
    *['$`']*) refuse "${EXPAND_MSG}" ;;
    *[{}]*)
      if brace_would_expand "${word}"; then
        refuse "${EXPAND_MSG}"
      fi
      ;;
    *) ;;
    esac
  fi

  case "${word}" in
  ';' | '&&' | '||' | '|' | '&' | '(' | ')' | '`')
    # The operand scan starts over at each command boundary. `in_git` does not:
    # it latches for the rest of the command string. Splitting on operator
    # characters above means one sitting inside an argument -- `git log
    # --grep=a|b --output=cosign.pub -1` -- would otherwise end the git
    # invocation as far as this scan is concerned and hand the write primitive
    # back unwatched. The cost is refusing an `--output` that belongs to some
    # later non-git command in the same string; the alternative is a bypass
    # spelled with one pipe.
    seen_git=0
    in_diff=0
    skip_git_option_value=0
    continue
    ;;
  *) ;;
  esac

  # Scoped to the git invocation as a whole, and checked before anything below
  # skips a dash-prefixed word: the write primitive belongs to the
  # diff-generation machinery rather than to one subcommand, so `git log -p
  # --output=FILE` and `git show --output=FILE` reach it without the word
  # `diff` appearing anywhere. `--output=x` and a bare `--output` (the space
  # form, whose path is the next word) are the two spellings; the pattern is
  # anchored so `--output-indicator-new=%` does not match it.
  #
  # This is deliberately wider than the allow list: a `git commit -m` whose
  # message happens to contain the word --output is refused too. That costs a
  # rephrased commit message; the alternative is a list of which git
  # subcommands accept the flag, and the subcommand this hook forgot is the
  # hole.
  if ((in_git)); then
    case "${word}" in
    --output | --output=*) refuse "${OUT_MSG}" ;;
    *) ;;
    esac
  fi

  if ((in_diff)); then
    if [[ "${word}" == "--" ]]; then
      if ((operands > 0)); then
        # A revision or path already stopped git's scan, so what follows is a
        # pathspec resolved against the repository, never a plain file.
        seen_git=0
        in_diff=0
      else
        # Nothing preceded the `--`: git consumes it and applies the
        # two-operand test to the words after it. Count those instead.
        after_dashdash=1
      fi
      continue
    fi
    if ((after_dashdash)); then
      # Git does not parse options here: `-x` after `--` is a path named -x.
      ((operands++))
      path_inside_worktree "${word}" || unresolved=1
      if ((operands >= 2 && unresolved)); then
        refuse "${DIFF_MSG}"
      fi
      continue
    fi
    # `-` is not an option here. Git diff reads it as the stdin operand and
    # counts it toward the same two-operand test, so `git diff ./cosign.key -`
    # prints the file with one flagless operand and one dash -- while a scan
    # that skips every dash-prefixed word sees a single operand and never
    # reaches the refusal. It is the one word git treats as an operand and a
    # loop like this one would treat as an option: every other `-x` is a flag
    # git would reject if it were not one.
    [[ "${word}" == -* && "${word}" != "-" ]] && continue
    ((operands++))
    git rev-parse --verify --quiet "${word}^{commit}" >/dev/null 2>&1 || unresolved=1
    if ((operands >= 2 && unresolved)); then
      refuse "${DIFF_MSG}"
    fi
    continue
  fi

  if ((seen_git)); then
    if ((skip_git_option_value)); then
      # The value half of a two-token git global option. Without this the
      # directory or setting is read as the subcommand, git is forgotten, and
      # the operand scan never starts at all: `git -C / diff /dev/null
      # ./cosign.key` would go through uninspected -- and `/` is not a
      # repository, so git implies --no-index there and prints the file by a
      # second route. No allow rule matches that spelling today, so it prompts
      # -- but a gate whose coverage depends on an allow rule's exact prefix is
      # one allow-list edit from silence.
      skip_git_option_value=0
      continue
    fi
    case "${word}" in
    -C | -c | --git-dir | --work-tree | --namespace | --super-prefix | --config-env | --attr-source)
      skip_git_option_value=1
      continue
      ;;
    *) ;;
    esac
    # git-level options such as --no-pager sit between `git` and the subcommand.
    [[ "${word}" == -* ]] && continue
    if [[ "${word}" == "diff" ]]; then
      in_diff=1
      operands=0
      unresolved=0
      after_dashdash=0
      continue
    fi
    seen_git=0
  fi

  if [[ "${word}" == "git" ]]; then
    seen_git=1
    in_git=1
  fi
done

exit 0
