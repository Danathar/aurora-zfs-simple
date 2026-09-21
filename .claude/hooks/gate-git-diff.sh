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
# Seven things this gate has to get right, each of them a spelling an earlier
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
#      while git receives `--output=FILE`. Command substitution and process
#      substitution supply operands this scan never counted at all. Those
#      characters are refused inside a git invocation rather than expanded --
#      every `$`, backtick and `<(`, and a brace bash would expand; one it
#      would not, git's own `HEAD@{1}` or `main@{upstream}`, is left alone.
#      The brace test reads the words *as typed*, quotes and all: `{a';',b}`
#      is one word to bash and two paths after expansion, and a test run on
#      the quote-stripped words saw `{a` and `,b}` and passed both. See
#      `raw_words`, `brace_would_expand` and `EXPAND_MSG`.
#   7. A git invocation ends where bash ends it, and only there. Every
#      unquoted `&` once counted as a command separator, so `git log 2>&1
#      --outpu{t,t}=FILE` closed the brace scope at the `&` of its
#      redirection and `git diff 2>&1 /dev/null ./cosign.key` reset the
#      operand count there; `>|` did the same as a pipe and `<(` as a
#      subshell. The split now reads redirections and process substitution
#      as bash does. See the split below `brace_would_expand`.
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
# The shell has its own spelling of the same write, and it is the older one:
# `git diff HEAD >cosign.pub` truncates the file before git starts, and
# `>>`, `>|`, `&>`, `&>>`, `2>err`, `>&file` and `<>file` each open a path
# for writing the same way, wherever in the command they are written --
# `>cosign.pub git diff HEAD` is the same command as `git diff HEAD
# >cosign.pub`. Nothing in the allow rule sees it -- the rule
# matches a `git diff` prefix -- and the operand scan must not, because a
# redirection's target is the shell's word, not git's (counting it refused
# `git diff HEAD 2>&1`). So an output redirection inside a git invocation is
# refused outright, whatever it targets, on the same ground as `--output`:
# these commands print to stdout, and that is what to read. `>&N`, `N>&M`
# and `>&-` name a descriptor rather than a path and are not refused; nor is
# any input redirection (`<`, `<<`, `<<<`, `<&`); nor is a redirection on
# some other command of the same string (`echo x >out; git diff HEAD`).
#
# So this looks at the operands git would actually receive, and refuses the
# two-operand form unless every operand resolves as a revision -- which is what
# separates `git diff main feature` from `git diff /dev/null ./cosign.key`.
# After a bare `--` no word can be a revision, so there the test is git's own:
# two or more words where any one lies outside the working tree. The write
# primitive needs none of that machinery: `--output` anywhere in a git
# invocation is refused outright.
#
# One more rewrite sits between the typed word and the path git opens: an
# unquoted leading `~` is `$HOME` to bash and a literal `~` to a scan of the
# typed words, and `realpath -m -s` resolved that literal to `<checkout>/~/...`,
# an inside path. So `git diff -- ~/.aws/credentials ~/.bashrc` counted two
# operands, found both inside the working tree, and exited 0, and bash then
# handed git two files from the home directory, which it printed. The
# ShellCheck operand scan below already refuses that word (see
# `word_bash_would_rewrite`); the git scope now does the same. A word of a
# git invocation that begins with an unquoted `~` (`~/...`, `~user/...`, `~`
# alone) is refused rather than expanded (see `TILDE_MSG`), and
# `path_inside_worktree` counts a leading `~` as outside as well, so neither
# operand scan can be talked into the same answer by another route. A
# quoted or escaped tilde (`'~/x'`, `\~/x`) is a literal to bash and is not
# refused; nor is a tilde inside a word (`HEAD~1`). The containment test is
# stricter than that on purpose: it never resolves a leading `~` inside the
# tree, quoted or not, so two quoted tildes after a `--` (`git diff -- '~/x'
# '~/y'`) are refused as the plain-file form although bash would hand git two
# literal paths. Nothing here is named `~`, and the alternative is a
# containment test that has to know how each word was quoted.
#
# Git is not the only allow-listed command that opens a file it is pointed at.
# `Bash(shellcheck:*)` is allowed with no prompt as well, and ShellCheck prints
# the *source line* above every diagnostic it reports -- so it prints back
# whatever it is aimed at. `shellcheck ./.env` echoes every unexported
# `NAME=value` line of a file `Read(./.env)` refuses, values included, and a
# PEM-shaped file gives up its `-----BEGIN/END-----` lines and its trailing
# base64 line. It is a lossy read rather than `cat` -- an exported assignment
# draws no SC2034 and a key's interior lines draw nothing at all -- and for the
# `.env` shape the deny rules name, the loss is nothing that matters.
#
# No permission pattern closes it, for the same reason as above: patterns match
# by prefix, so `Bash(shellcheck tests/:*)` still matches
# `shellcheck tests/run-tests.sh /home/me/.aws/credentials`, and an exact rule
# per tracked script stops `shellcheck a.sh b.sh` working at all. So a
# `shellcheck` invocation gets the same operand treatment as a `git` one: every
# operand must resolve inside the working tree -- reusing `path_inside_worktree`
# below, `..` climb-outs and all -- and must not be one of the secret-shaped
# names the deny rules list. Linting this repository's own scripts is
# unaffected. `bash -n`, the other allowed linter, is not the same case: it
# echoes at most the one line of a syntax error, and the key and `.env` shapes
# parse cleanly and print nothing.
#
# Not every operand arrives in the argv, either. `SHELLCHECK_OPTS` is not a
# list of options despite the name: shellcheck splits it and prepends it to its
# own arguments, operands included, so `SHELLCHECK_OPTS=./.env shellcheck
# tests/run-tests.sh` lints the `.env` too and prints its lines back while the
# argv this gate scans names no such path. The assignment is written before the
# command name, so no scope is open when it is read; it is refused wherever it
# stands, and nothing in this repository sets the variable.
#
# The write primitive is not git's alone, either. Eleven other allow rows in
# `.claude/settings.json` carry a trailing `:*` -- "this command with any
# arguments" -- and a shell output redirection is part of the string that
# rule matches, so the shell opened the target before the command ran and
# nothing prompted: `shellcheck tests/run-tests.sh >cosign.pub` truncated
# the trust anchor before a line was linted (the file is emptied even when
# the command then fails), and `gh run view 1 --log >.claude/settings.json`
# overwrote the file holding these rules. Those commands are named in
# `GATED_PREFIXES` below, and an output redirection inside any of them is
# refused the way one inside a git invocation is; descriptor forms, input
# redirections, pipes and a command no allow rule covers are left alone.
# One of them also carries a flag that undoes the read: `bash -n` parses a
# script without running it, and a later `+n` or `+o noexec` on the same
# command line turns that back off, so `bash -n +n -c 'cat ./cosign.key'`
# ran the command under the linter's allow rule. A word beginning with `+`
# in a `bash -n` invocation is refused, and so is a brace, a glob, a `$` or
# a backtick in one of its words, since `{+,+}n` reaches bash as `+n` and so
# does `?n` beside a file of that name.
#
# What it still cannot see, stated rather than implied: a command that hides a
# git invocation behind another interpreter (`sh -c ...`), one that changes
# directory out of the repository first, and anything a command reads or writes
# once it has started. A `shellcheck -x` run whose target file names an outside
# file in a `source` directive is in that last category -- the operands are
# checked, what the tool then opens on their behalf is not, and `.shellcheckrc`
# sets `external-sources=true` repository-wide. A git argument built at runtime
# is no longer waved through -- the expansion characters that build it are
# refused -- but that is a refusal, not an inspection. This re-gates the
# pre-approved commands that reach past the deny list; it is not a sandbox.

set -uo pipefail

refuse() {
  printf '%s\n' "$1" >&2
  exit 2
}

DIFF_MSG='blocked: this git diff would compare paths as plain files (git'"'"'s --no-index mode, which needs no flag once two operands are given), so it prints any file on disk -- cosign.key, a .env, a private key outside this repository -- past the Read(...) deny rules in .claude/settings.json. Describe such a file with ls -l or wc -c instead.'

# shellcheck disable=SC2016 # the message quotes shell spellings as literal
# text -- $'\x74' and $(...) are what the reader has to see, not what this
# script should expand.
EXPAND_MSG='blocked: bash expands braces, ANSI-C quotes and substitutions before git sees the words, and this gate reads the words as typed, so four characters rebuild both spellings it refuses: `git diff {/dev/null,./cosign.key}` passes the operand scan as one word and reaches git as two operands (the plain-file read), `--outpu{t,t}=FILE` and `--outpu$'"'"'\x74'"'"'=FILE` match no word here and reach git as --output=FILE, and `git diff $(...)` or `git diff <(...)` supplies operands this scan never saw. Expanding them correctly means reimplementing bash inside a hook, so a brace bash could expand -- a { followed, anywhere later in the word, by a comma or a .. and then a } -- and every $, backtick and process substitution are refused instead. Write the command out in full. A brace with neither, such as HEAD@{1} or main@{upstream}, is a literal to bash and is not refused; a .. between two reflog entries (HEAD@{2}..HEAD@{1}) has the refused shape, so write HEAD~2..HEAD~1. Only words of a git invocation are affected: awk and jq programs elsewhere in the string are not.'

# shellcheck disable=SC2016 # the backticks quote command spellings for the reader
REDIRECT_MSG='blocked: an output redirection (>, >>, >|, &>, &>>, N>, >&FILE, <>) inside a git invocation makes the shell open its target for writing before git runs -- `git diff HEAD >cosign.pub` truncates the trust anchor, and `>> .claude/settings.json` or `2> .claude/hooks/gate-git-diff.sh` reach any file this uid can write -- and the allow rule for git diff, git log and git show sees none of it. These commands print to stdout; read that instead. Descriptor forms (2>&1, >&2, >&-) and input redirections (<, <<, <<<, <&) are not affected, and a redirection on another command of the same string is that command'"'"'s own.'

# shellcheck disable=SC2016 # the literal $HOME is what the reader has to see
TILDE_MSG='blocked: an unquoted leading ~ is $HOME to bash and a literal directory inside this checkout to this gate, so the path checked here is not the path git would open: `git diff -- ~/.aws/credentials ~/.bashrc` resolved both operands inside the working tree and printed both files out of the home directory as a plain-file diff, past the Read(...) deny rules in .claude/settings.json. A word of a git invocation that begins with an unquoted ~ (~/..., ~user/..., or ~ alone) is refused rather than expanded. Spell the path out in full, relative to the checkout. A tilde inside a word (HEAD~1) and a quoted or escaped one are literals to bash and are not refused by this rule.'

# shellcheck disable=SC2016 # the literal $G and $(...) are what the reader has to see
CMD_MSG='blocked: the name of a command in this string is not spelled literally -- it is built by an expansion (`$G diff ...`, `$(printf git) diff ...`, a backtick in command position), by a brace (`{,git} diff ...`), or by a glob (`g?t`, `/usr/bin/g[i]t`) -- so neither this gate nor the allow rule that matched the string'"'"'s literal prefix can tell which command bash will run, and `G=git; $G diff /dev/null ./cosign.key` runs the plain-file read this gate exists to refuse. Spell every command name literally, and drop a variable assignment that only exists to build one. After a wrapper such as command, env, exec, timeout or xargs the same holds for every word of that command, since the wrapper'"'"'s own options are not modelled here. A literal name after an assignment (`FOO=bar git diff HEAD`) is fine, and a literal path to git (`/usr/bin/git diff`) is read as git. env -S (--split-string) splits a quoted string into a command this gate never sees and is refused outright.'

SHELLCHECK_MSG='blocked: shellcheck prints the source line above every diagnostic it reports, so pointing it at this path prints that file back -- every unexported NAME=value line of a .env, the BEGIN/END lines of a key -- past the Read(...) deny rules in .claude/settings.json, which gate the Read tool and say nothing about what an allow-listed Bash command opens. Operands must be inside the working tree and must not be one of the secret-shaped names those rules list (cosign.key, .env, .env.*, *.pem, *.p12, id_rsa, id_ed25519). Linting this repository'"'"'s own scripts is unaffected. Describe such a file with ls -l or wc -c instead.'

SHELLCHECK_OPTS_MSG='blocked: SHELLCHECK_OPTS is not a list of options -- shellcheck splits it and prepends it to its own argv, operands included, so SHELLCHECK_OPTS=./.env shellcheck tests/run-tests.sh lints the .env as well and prints its lines back, with no path in the argv this gate scans. Nothing in this repository sets the variable, so it is refused outright. Pass options after the command name instead.'

# shellcheck disable=SC2016 # the literal $HOME is what the reader has to see
SHELLCHECK_EXPAND_MSG='blocked: bash rewrites this word before shellcheck sees it, and this gate reads the words as typed, so the path checked here is not the path shellcheck would open: shellcheck {tests/run-tests.sh,/etc/shadow} is one word to the operand scan here and two files to shellcheck -- the second of which it would print back; an unquoted leading ~ is $HOME to bash and a literal directory inside this checkout to the gate (shellcheck ~/.aws/credentials); an unquoted glob character (*, ? or a bracket) is what bash expands into files this gate never saw (shellcheck .env*); and a $, a backtick or a process substitution supplies operands at runtime. Expanding them correctly means reimplementing bash inside a hook, so they are refused instead. Spell every path out in full, relative to the checkout.'

OUT_MSG='blocked: git --output=FILE (and the space form) writes this diff or log to the path it names instead of stdout, overwriting any file this uid can reach -- cosign.pub, .claude/settings.json, this hook, ~/.ssh/authorized_keys -- with no Read(...) deny rule in its way. git diff, git log and git show print to stdout; read that instead. --output-indicator-* is a different flag and is unaffected.'

# shellcheck disable=SC2016 # the message quotes shell spellings as literal text
GATED_REDIRECT_MSG='blocked: an output redirection (>, >>, >|, &>, &>>, N>, >&FILE, <>) inside an allow-listed command makes the shell open its target for writing before the command runs, and the allow rule matches a command prefix while the redirection is the rest of the string, so nothing prompts: `shellcheck tests/run-tests.sh >cosign.pub` truncates the trust anchor before a line is linted, and `gh run view 1 --log >.claude/settings.json` overwrites the file holding these rules. It is the same write .claude/hooks/gate-git-diff.sh already refuses for `git diff HEAD >cosign.pub`. These commands print to stdout; read that, or pipe it. Descriptor forms (2>&1, >&2, >&-) and input redirections (<, <<, <<<, <&) are not affected, and a command no allow rule covers is left alone -- that one prompts on its own.'

# shellcheck disable=SC2016 # the backticks quote a command spelling for the reader
BASH_NOEXEC_MSG='blocked: `bash -n` is allow-listed because -n reads a script without running it, and a later +n or +o noexec on the same command line turns that off again, so `bash -n +n -c COMMAND` and `bash -n +o noexec script.sh` run whatever they name under the linter'"'"'s allow rule with no prompt. A word beginning with + in a bash -n invocation is refused. Check syntax with bash -n FILE and nothing else; to run a script, run it as itself so the permission rules see it.'

# shellcheck disable=SC2016 # the literal ${VAR} and $(...) are what the reader has to see
BASH_EXPAND_MSG='blocked: a brace bash could expand, an unquoted glob character (*, ? or a bracket), an unquoted leading ~, a $, a backtick or a process substitution in a word of a bash -n invocation is refused rather than expanded, for the reason EXPAND_MSG gives for git: bash rewrites the words before the inner bash sees them, so `{+,+}n` matches no spelling here and reaches bash as +n, which turns noexec off, `?n` does the same when a file named +n exists in the working directory, and $(...), ${VAR} and a backtick supply a word this gate never saw. Write the command out in full.'

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

# The shape of every brace expansion bash performs: a `{`, then a `,` or a
# `..` somewhere after it, then a `}` somewhere after that. Bash pairs a `{`
# with the last `}` it can, so `{a},b}` expands (to `a}` and `b}`) and a test
# that closed the brace at the first `}` missed the comma; no nesting or
# matching is tracked here, on purpose, and every refinement toward bash's
# real rule is a chance to disagree with it in some other direction. What
# this never does is call a word literal that bash would rewrite. Git's own
# `HEAD@{1}`, `main@{upstream}`, `@{-1}` and `@{2.days.ago}` have neither
# inside the braces and pass; so does a `{` that never closes, which bash
# leaves alone. `HEAD@{2}..HEAD@{1}` is refused although bash would not
# expand it -- the over-refusal is the safe direction, and EXPAND_MSG names
# the `HEAD~2..HEAD~1` spelling. `${VAR}` is refused as well, as a
# runtime-built argument this hook cannot inspect.
#
# It is applied to the word as typed, quotes and backslashes included. A
# quoted comma or operator is still part of the word bash expands --
# `{a",",b}` and `{a';',b}` both become two words -- and a test on the
# quote-stripped spelling, cut at its `;`, saw `{a` and `,b}` and waved both
# through. A fully quoted `"{a,b}"`, which bash leaves alone, is refused as
# the price of that.
brace_would_expand() {
  # shellcheck disable=SC2016 # the literal `${` is what is being looked for
  [[ "$1" == *'${'* || "$1" == *'{'*','*'}'* || "$1" == *'{'*..*'}'* ]]
}

# The command's words as bash would delimit them, split once and read by both
# scans below. Each word is kept in two spellings: as typed, with every quote
# mark and backslash in place, because bash brace-expands exactly that form
# and `brace_would_expand` has to see it; and with the quotes and backslashes
# removed, which is the word git receives and what the operand scan compares.
# Alongside them is what kind of thing each entry is: a `word` of a command, a
# `sep` (an unquoted command separator: `;`, `&`, `&&`, `|`, `||`, `|&`, `(`,
# `)`, a newline, a backtick), or the `target` of a redirection.
#
# The separators are the only things that end a command, and the list has to
# be exactly bash's, in both directions. An earlier version of this split
# treated every unquoted `&` as a separator and reset the git scope at it, so
# `git log 2>&1 --outpu{t,t}=cosign.pub -1` passed: the `&` in `2>&1` closed
# the scope before the brace was seen, then bash expanded the flag and git
# overwrote the file. The same `&` reset the operand scan, and `git diff 2>&1
# /dev/null ./cosign.key` printed the key with neither operand counted. `>&`,
# `<&`, `&>` and `&>>` are redirections, and so is `>|` (the noclobber form),
# where the `|` is not a pipe. `|&` is a pipe and stays a separator. A `(`
# behind an unquoted `<` or `>` is a process substitution rather than a
# subshell: `git diff <(true) ./cosign.key` hands git a `/dev/fd/N` operand
# the way `$(...)` would, so it is refused in a git invocation as `$(...)` is
# (see `raw_in_git` below) instead of resetting the scope at its `(`.
#
# A redirection is `[n]op word` -- an optional descriptor number written hard
# against the operator, one of `<`, `>`, `>>`, `<<`, `<<<`, `<>`, `>&`, `<&`,
# `>|`, `&>`, `&>>`, and the target word. None of it is a word git receives:
# the number is dropped, the target is kept as `target` so that the operand
# scan can skip it, and the operator is kept beside the target in
# `redirects`, because which operator it was decides whether the shell opens
# the target for writing (see `redirection_writes_a_path`). `git diff HEAD
# 2>&1` is a one-operand diff; counting `2` and `1` refused it. A heredoc's
# body lines are read as words of the command that opened it, which can only
# over-refuse.
#
# No real word is ever empty in the as-typed spelling: a typed `""` keeps its
# quotes. An unquoted `\` followed by a newline is a line continuation, which
# bash removes before anything else, and it is removed here.
raw_words=()
words=()
kinds=()
redirects=() # the operator, for a `target`; empty for anything else
raw_word=''
raw_quote=''
raw_escaped=0
redirect_pending=0 # the next word is the target of a redirection
redirect_op=''     # the operator of that redirection, as typed
after_redirect=0   # the previous unquoted character was `<` or `>`
subst_depth=0      # open `$(` substitutions, whose `)` is not a subshell's

push_word() {
  raw_words+=("${raw_word}")
  words+=("${raw_word//[\'\"\\]/}")
  kinds+=("$1")
  redirects+=("${2-}")
  raw_word=''
}
end_word() {
  [[ -n "${raw_word}" ]] || return 0
  if ((redirect_pending)); then
    push_word target "${redirect_op}"
    redirect_pending=0
    redirect_op=''
  else
    push_word word
  fi
}
push_sep() {
  end_word
  raw_words+=('')
  words+=("$1")
  kinds+=(sep)
  redirects+=('')
  redirect_pending=0
  redirect_op=''
}

for ((i = 0; i < ${#command_string}; i++)); do
  ch="${command_string:i:1}"
  next="${command_string:i+1:1}"
  prev_redirect="${after_redirect}"
  after_redirect=0
  if ((raw_escaped)); then
    raw_escaped=0
    if [[ "${ch}" == $'\n' ]]; then
      raw_word="${raw_word%\\}"
    else
      raw_word+="${ch}"
    fi
    continue
  fi
  if [[ -n "${raw_quote}" ]]; then
    raw_word+="${ch}"
    if [[ "${ch}" == "${raw_quote}" ]]; then
      raw_quote=''
    elif [[ "${raw_quote}" == '"' && "${ch}" == $'\\' ]]; then
      raw_escaped=1
    fi
    continue
  fi
  case "${ch}" in
  $'\\')
    raw_escaped=1
    raw_word+="${ch}"
    ;;
  "'" | '"')
    raw_quote="${ch}"
    raw_word+="${ch}"
    ;;
  ' ' | $'\t')
    end_word
    ;;
  '<' | '>')
    # `2>` and `10<`: the digits are the descriptor, not a word, and so is
    # bash's `{name}>` form, which allocates a descriptor into the variable.
    if ((!redirect_pending)) && [[ "${raw_word}" =~ ^([0-9]+|\{[A-Za-z_][A-Za-z0-9_]*\})$ ]]; then
      raw_word=''
    else
      end_word
    fi
    if [[ "${next}" == '(' ]]; then
      # Process substitution. Kept as a word spelled `<(` or `>(` so the
      # brace scan can refuse it inside a git invocation; its body is a
      # command of its own and is split as one. Written where a
      # redirection's target goes (`df -T > >(cat >victim)`), it is that
      # target: bash connects the command's output to the substitution,
      # which writes wherever it likes, so it is kept as a `target` of that
      # operator and `redirection_writes_a_path` reads it as the write it
      # is (review on arch-bootc#322).
      raw_word="${ch}("
      if ((redirect_pending)); then
        push_word target "${redirect_op}"
        redirect_pending=0
        redirect_op=''
      else
        push_word word
      fi
      push_sep '('
      ((i++))
      continue
    fi
    # A second `>` or `<` while the target is still to come extends the
    # operator (`>>`, `<<`, `<<<`, `<>`); after a target it opens a new one
    # (`>x>y`), and `end_word` above has already emptied `redirect_op`.
    redirect_op+="${ch}"
    redirect_pending=1
    after_redirect=1
    ;;
  '&')
    if ((prev_redirect)); then
      redirect_op+='&' # `>&` or `<&`: the operator continues and its target follows.
    elif [[ "${next}" == '>' ]]; then
      end_word # `&>` and `&>>`: the `>` that follows opens the redirection.
      redirect_op='&'
    else
      push_sep '&'
    fi
    ;;
  '|')
    if ((prev_redirect)); then
      redirect_op+='|' # `>|`: noclobber redirection, not a pipe.
    else
      push_sep '|'
    fi
    ;;
  $'\n') push_sep ';' ;;
  '(')
    # `$(`: a command substitution, not a subshell. It is a nested command,
    # so it is split as one, but the command around it goes on afterwards:
    # `>$(printf cosign.pub) git diff HEAD` is git's redirection, and a
    # scope that reset at the `(` had forgotten the target by the time it
    # reached `git`. The `$(` and `$)` separators let the scans below save
    # and restore the outer command's state instead of resetting it.
    if [[ "${raw_word}" == *'$' && "${raw_word}" != *'\$' ]]; then
      end_word
      # shellcheck disable=SC2016 # the literal `$(` is the separator's name
      push_sep '$('
      ((subst_depth++))
    else
      push_sep '('
    fi
    ;;
  ')')
    if ((subst_depth > 0)); then
      ((subst_depth--))
      push_sep '$)'
    else
      push_sep ')'
    fi
    ;;
  ';' | '`') push_sep "${ch}" ;;
  *) raw_word+="${ch}" ;;
  esac
done
end_word

# Every scan below looks for a literal `git` word to open its scope, and the
# allow rules in .claude/settings.json match a literal `git diff`/`git log`
# prefix. Both are blind to a command whose *name* is not that word: in
# `git status; G=git; $G diff /dev/null ./cosign.key` the string is allowed
# on its `git status` prefix, `$G` is not the word `git`, so no scope opens
# and the hook exits 0 -- and bash runs the plain-file read (review on
# #205). `$(printf git) diff ...` and a backtick in command position
# are the same thing spelled differently; so are `{,git} diff ...`, which
# bash brace-expands to `git`, and `g?t` or `/usr/bin/g[i]t`, which pathname
# expansion resolves to it; and so is the plain `/usr/bin/git diff ...`,
# which needs no expansion at all. Whether the permission layer would prompt
# for the second command on its own is not this gate's to assume.
#
# So the word that names each command has to be literal, and a literal path
# to git has to count as git. The name is the first word after a separator
# (or of the string) that is not a variable assignment (`FOO=bar git diff
# HEAD` names git) and not a shell keyword that takes a command (`{`, `!`,
# `if`, `then`, `time`, ...). After a wrapper that runs its arguments
# (`command`, `exec`, `env`, `nohup`, `xargs`, `timeout`, ...) the name is
# somewhere among the words that follow, behind options this gate does not
# model -- `command -- $G` -- so every remaining word of that command is
# held to the test. A word in that position carrying a `$`, a backtick, a
# `*` or `?`, a `[` (other than the `[` and `[[` commands themselves), or a
# brace bash would expand is refused, and so is an unquoted backtick opening
# there, whose output would be the name. A literal name whose last path
# component is `git` is rewritten to `git`, so `/usr/bin/git diff` opens
# every scope that `git diff` does. A redirection's target is never the
# name. One wrapper option is modelled, because it is not an option but an
# interpreter: `env -S 'git diff /dev/null ./cosign.key'` (GNU and uutils
# `--split-string`) splits its quoted string into a command this scan never
# sees as words, so any `-S`, clustered (`-iS`) or long, after `env` is
# refused outright. `sh -c ...` and `eval` remain the interpreters the
# header says this hook does not see behind.
#
# The cost is a backtick assignment (`X=\`date\``): the split ends the word
# `X=` at the backtick, and the backtick then opens in command position. The
# `$(...)` spelling of the same assignment is not affected. A glob or a `$`
# in an argument after a wrapper (`timeout 60 find . -name '*.sh'`) is
# refused too; without the wrapper it is not.
command_word_pending=1 # the next word of this command may be its name
after_wrapper=0        # a wrapper ran: every remaining word may be the name
command_names=()       # 1 at each index that names, or may name, a command
wrapper_name=''
in_backtick=0
name_stack=() # the outer command's state, while a `$(...)` is being read
for ((idx = 0; idx < ${#words[@]}; idx++)); do
  case "${kinds[idx]}" in
  sep)
    # A `$(...)` substitution is a nested command: its own words are held
    # to the rule, and the command around it resumes where it left off, so
    # `>$(printf x) git diff HEAD` still finds its name at `git` and
    # `echo $(date) *.sh` does not read `*.sh` as a name.
    # shellcheck disable=SC2016 # the literal `$(` is the separator's name
    if [[ "${words[idx]}" == '$(' ]]; then
      name_stack+=("${command_word_pending} ${after_wrapper} ${wrapper_name}")
      command_word_pending=1
      after_wrapper=0
      wrapper_name=''
      continue
    fi
    if [[ "${words[idx]}" == '$)' ]] && ((${#name_stack[@]})); then
      read -r command_word_pending after_wrapper wrapper_name <<<"${name_stack[-1]}"
      unset 'name_stack[-1]'
      continue
    fi
    if [[ "${words[idx]}" == '`' ]]; then
      if ((in_backtick)); then
        # Closing: the command that contained the substitution has its name.
        in_backtick=0
        command_word_pending=0
        after_wrapper=0
        wrapper_name=''
        continue
      fi
      ((command_word_pending)) && refuse "${CMD_MSG}"
      in_backtick=1
    fi
    command_word_pending=1
    after_wrapper=0
    wrapper_name=''
    continue
    ;;
  target) continue ;;
  *) ;;
  esac
  ((command_word_pending)) || continue
  raw_word="${raw_words[idx]}"
  word="${words[idx]}"
  if [[ "${raw_word}" =~ ^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?= ]]; then
    continue # an assignment; the name is still to come
  fi
  case "${word}" in
  '{' | '}' | '!' | if | then | else | elif | fi | do | done | while | until | time | coproc)
    continue # a keyword; the name is still to come
    ;;
  command | builtin | exec | env | nohup | nice | xargs | timeout | stdbuf | sudo | doas)
    after_wrapper=1
    wrapper_name="${word}"
    continue
    ;;
  *) ;;
  esac
  if [[ "${wrapper_name}" == env ]] &&
    [[ "${raw_word}" =~ ^-[^-]*S || "${raw_word}" == --split-string* ]]; then
    refuse "${CMD_MSG}"
  fi
  if [[ "${raw_word}" == *'$'* || "${raw_word}" == *'`'* ||
    "${raw_word}" == *'*'* || "${raw_word}" == *'?'* ]] ||
    brace_would_expand "${raw_word}" ||
    { [[ "${raw_word}" == *'['* ]] && [[ "${word}" != '[' && "${word}" != '[[' ]]; }; then
    refuse "${CMD_MSG}"
  fi
  if [[ "${word}" == */git ]]; then
    words[idx]=git
    raw_words[idx]=git
  fi
  command_names[idx]=1
  ((after_wrapper)) || command_word_pending=0
done

# Whether the shell opens a redirection's target for writing. Every operator
# with a `>` in it does -- `>`, `>>`, `>|`, `&>`, `&>>`, and `<>`, which
# opens read-write and creates the file -- and so does `>&` when its target
# is a path: `>&file` is bash's older spelling of `&>file`. The exception is
# a target that names a descriptor: `>&1`, `2>&1` and `>&-` duplicate or
# close a descriptor and touch no path. `2>&file` is an "ambiguous redirect"
# error in bash and writes nothing, and is refused anyway -- the rule is the
# operator and the target's shape, not a model of bash's error paths. `<`,
# `<<`, `<<<` and `<&` open nothing for writing.
redirection_writes_a_path() {
  local op="$1" target="$2"
  [[ "${op}" == *'>'* ]] || return 1
  if [[ "${op}" == *'&' ]]; then
    [[ "${target}" =~ ^[0-9]+$ || "${target}" == '-' ]] && return 1
  fi
  return 0
}

# From a `git` word to the end of *that command*: the scope opens at `git`
# and closes at the next separator, so `git diff HEAD | jq '{a,b}'` leaves
# the jq program alone while `git log -1; git diff {a,b}` and `echo x | git
# diff {a,b}` are each refused at their own `git`. A redirection does not
# close it: `git log 2>&1 --outpu{t,t}=FILE` is one command, and the brace
# in it is git's. This is narrower than the `in_git` latch below, which holds
# to the end of the string, and can be: that latch guards the `$` and
# `--output` tests, which are kept wide on purpose. The word is compared with
# its quotes removed so `'git'` opens the scope as `git` does; a `git`
# assembled from an expansion (`g{i,i}t`) matches no allow rule and prompts on
# its own.
#
# The same scope decides the output redirections: bash attaches a redirection
# to the simple command it is written in, so `git diff HEAD >cosign.pub` is
# git's and `echo x >out; git diff HEAD` and `git diff HEAD | jq . >out` are
# not -- those are decided by whatever rule covers `echo` and `jq`, the way
# `git diff HEAD | tee cosign.pub` already is. Bash also lets a redirection
# *precede* the command name -- `>cosign.pub git diff HEAD` is the same
# command as `git diff HEAD >cosign.pub`, and `git status; >cosign.pub git
# diff HEAD` truncated the trust anchor while a scope that opened at the
# `git` word had not yet seen the target (review on arch-bootc#317). So a
# writing target seen before any `git` word of its command is carried until
# the command's name is known, and refused if that name turns out to be git;
# it is dropped at the next separator, so `>out echo x; git diff HEAD` is
# still echo's own, and it is taken only by a `git` the command-name scan
# above marked as naming its command, so `>out printf %s git` is printf's. A brace or expansion found anywhere in the string wins
# the refusal: it means the words here are not the words git would receive,
# and that message is the one to act on first.
#
# The git scope also refuses a word that begins with an unquoted `~`: bash
# expands it to `$HOME` before git runs, and the operand scan below, which
# reads the quote-stripped spelling, resolved the literal `~` inside the
# checkout and let `git diff -- ~/.aws/credentials ~/.bashrc` through. The
# test is on the word as typed, so `'~/x'` and `\~/x`, which bash leaves
# alone, are not refused. A redirection's target is not a word of git's and
# is decided above.
#
# A `shellcheck` invocation is scoped the same way and for the same reason:
# its operands are checked below as the words they are typed as, and
# `shellcheck {tests/run-tests.sh,/etc/shadow}` is one word here and two files
# at shellcheck -- the second one printed back. The `$`, backtick and process
# substitution cases build an operand this scan never saw, so they are refused
# here too rather than in a latch that holds to the end of the string: unlike
# `--output`, there is no wide test to guard, and a `$` in some later command
# of the string is that command's own. Two more rewrites turned a checked
# operand into a different file (review on #207): an unquoted leading `~` is
# $HOME to bash and a literal `~` to the gate, which `realpath -m -s` resolved
# to `<checkout>/~/...` -- an inside path -- so `shellcheck ~/.aws/credentials`
# passed; and an unquoted `*`, `?` or `[` is a glob bash expands into files
# the gate never saw, so `shellcheck .env*` was one word here and the .env to
# bash. See `word_bash_would_rewrite`.

# Whether bash would rewrite this word, as typed, into something other than
# the quote-stripped spelling the operand scan checks: an unquoted `~` at the
# start (tilde expansion) or an unquoted `*`, `?` or `[` anywhere (pathname
# expansion). Quote state is tracked so that `'tests/*.sh'` and `tests/\*.sh`
# are the literal words bash would pass; a `~` that does not lead the word is
# a character in a filename.
word_bash_would_rewrite() {
  local raw="$1" quote='' escaped=0 i ch
  for ((i = 0; i < ${#raw}; i++)); do
    ch="${raw:i:1}"
    if ((escaped)); then
      escaped=0
      continue
    fi
    if [[ -n "${quote}" ]]; then
      if [[ "${ch}" == "${quote}" ]]; then
        quote=''
      elif [[ "${quote}" == '"' && "${ch}" == $'\\' ]]; then
        escaped=1
      fi
      continue
    fi
    case "${ch}" in
    $'\\') escaped=1 ;;
    "'" | '"') quote="${ch}" ;;
    '~') ((i == 0)) && return 0 ;;
    '*' | '?' | '[') return 0 ;;
    *) ;;
    esac
  done
  return 1
}

raw_in_git=0
raw_in_shellcheck=0
writing_redirect=0
prefix_writing_redirect=0 # a writing target seen before this command's git word
scope_stack=()            # the outer command's state, while a `$(...)` is being read
for ((idx = 0; idx < ${#raw_words[@]}; idx++)); do
  if [[ "${kinds[idx]}" == sep ]]; then
    # A backtick is split as a separator rather than kept in its word, so the
    # word test below never sees it: `shellcheck \`ls\`` ends the scope here
    # and hands shellcheck an operand built from the substitution's output.
    # The git side is covered by the `in_git` latch, which reads the separator
    # words too; this scope closes at the separator, so it is checked here.
    if ((raw_in_shellcheck)) && [[ "${words[idx]}" == '`' ]]; then
      refuse "${SHELLCHECK_EXPAND_MSG}"
    fi
    # A `$(...)` substitution is a nested command; the scope of the command
    # around it, and a writing target waiting for that command's name, are
    # saved at the `$(` and restored at its `)` rather than reset.
    # shellcheck disable=SC2016 # the literal `$(` is the separator's name
    if [[ "${words[idx]}" == '$(' ]]; then
      scope_stack+=("${raw_in_git} ${raw_in_shellcheck} ${prefix_writing_redirect}")
    elif [[ "${words[idx]}" == '$)' ]] && ((${#scope_stack[@]})); then
      read -r raw_in_git raw_in_shellcheck prefix_writing_redirect <<<"${scope_stack[-1]}"
      unset 'scope_stack[-1]'
      continue
    fi
    raw_in_git=0
    raw_in_shellcheck=0
    prefix_writing_redirect=0
    continue
  fi
  # Refused wherever it stands, and not only inside a shellcheck scope: the
  # assignment is written *before* the command name, so no scope is open yet
  # when it is read, and shellcheck reads the variable however it was set.
  [[ "${words[idx]}" == SHELLCHECK_OPTS=* ]] && refuse "${SHELLCHECK_OPTS_MSG}"
  raw_word="${raw_words[idx]}"
  if ((raw_in_git)); then
    if brace_would_expand "${raw_word}" ||
      [[ "${raw_word}" == '<(' || "${raw_word}" == '>(' ]]; then
      refuse "${EXPAND_MSG}"
    fi
    if [[ "${kinds[idx]}" == word && "${raw_word}" == '~'* ]]; then
      refuse "${TILDE_MSG}"
    fi
    if [[ "${kinds[idx]}" == target ]] &&
      redirection_writes_a_path "${redirects[idx]}" "${words[idx]}"; then
      writing_redirect=1
    fi
  elif [[ "${kinds[idx]}" == target ]] &&
    redirection_writes_a_path "${redirects[idx]}" "${words[idx]}"; then
    prefix_writing_redirect=1
  fi
  if ((raw_in_shellcheck)) && [[ "${kinds[idx]}" == word ]]; then
    if brace_would_expand "${raw_word}" ||
      [[ "${raw_word}" == '<(' || "${raw_word}" == '>(' ||
      "${raw_word}" == *'$'* || "${raw_word}" == *'`'* ]] ||
      word_bash_would_rewrite "${raw_word}"; then
      refuse "${SHELLCHECK_EXPAND_MSG}"
    fi
  fi
  if [[ "${kinds[idx]}" == word && "${words[idx]}" == "git" ]]; then
    raw_in_git=1
    ((prefix_writing_redirect)) && ((${command_names[idx]:-0})) && writing_redirect=1
  fi
  [[ "${kinds[idx]}" == word && "${words[idx]}" == "shellcheck" ]] && raw_in_shellcheck=1
done
((writing_redirect)) && refuse "${REDIRECT_MSG}"

# The same write, reached by the allow-listed commands that are not git.
#
# Everything above is scoped to a `git` word (and the operand tests to a
# `shellcheck` one), and the write primitive is not git's alone.
# `.claude/settings.json` allows eleven other command prefixes with a trailing
# `:*` -- "this command with any arguments" -- and an output redirection is
# part of the string that rule matches, so the shell opens the target before
# the command runs and nothing prompts: `shellcheck tests/run-tests.sh
# >cosign.pub` truncates the trust anchor before a line is linted, and the
# file stays empty when shellcheck then fails; `gh run view 1 --log
# >.claude/settings.json` overwrites the file that holds these rules. The
# `Read(...)` deny rows gate the Read tool and say nothing about it, exactly
# as they say nothing about `git diff HEAD >cosign.pub`.
#
# One of those commands also carries a flag that undoes its read-only mode.
# `bash -n` is allowed because `-n` reads a script without running it, and
# bash lets a later `+n` (or `+o noexec`) on the same command line turn the
# option back off, so `bash -n +n -c 'cat ./cosign.key'` ran the command --
# the allow rule matches the `bash -n` prefix and the `+n` is the rest of the
# string. A word beginning with `+` in a `bash -n` invocation is refused, and
# so is a brace, a glob, a `$` or a backtick in one of its words, because
# `{+,+}n` is the rebuild that reopened the git half of this gate twice and
# `?n` beside a file named `+n` is the same rebuild by pathname expansion.
#
# The prefixes below are the allow rows with a trailing `:*` other than git's,
# which the scan above already covers (an output redirection is refused in
# every git invocation, `git status` and `git ls-files` included). The exact
# `Bash(./tests/run-tests.sh)` row is absent on purpose: it carries no `:*`,
# so a redirection makes the string match only the `:*` row beside it, which
# is listed. tests/test-claude-settings.sh derives this list from the
# settings file rather than restating it, so a rule added there fails that
# test until it is listed here.
GATED_PREFIXES=(
  './tests/run-tests.sh'
  'shellcheck'
  'bash -n'
  'gh run list'
  'gh run view'
  'gh pr list'
  'gh pr view'
  'skopeo inspect'
  'podman ps'
  'podman images'
  'podman inspect'
)

command_is_gated() {
  local joined="$1" prefix
  for prefix in "${GATED_PREFIXES[@]}"; do
    [[ "${joined}" == "${prefix}" ]] && return 0
  done
  return 1
}

# The command that just ended. Only two facts about it are kept -- whether its
# leading words matched one of the prefixes above, and whether a redirection
# in it opens a path -- because a redirection can be written before the name
# (`>cosign.pub shellcheck tests/run-tests.sh` is the same command as
# `shellcheck tests/run-tests.sh >cosign.pub`), so neither fact is complete
# until the command ends.
check_gated_command() {
  ((cmd_gated && cmd_writes)) && refuse "${GATED_REDIRECT_MSG}"
  return 0
}

reset_command() {
  cmd_prefix=''
  cmd_writes=0
  cmd_bash=0
  cmd_named=0
  cmd_gated=0
}

# The words of a command from its *name* onward: a leading assignment
# (`FOO=bar shellcheck ...`) is not part of the prefix an allow rule matches,
# and neither is a redirection's target, which is the shell's word rather
# than the command's. `command_names` above marks the name, and every word
# after it belongs to the same command until a separator.
cmd_prefix='' # the words so far, space-joined, while a prefix is still possible
cmd_writes=0  # a redirection in this command opens a path for writing
cmd_bash=0    # its name is bash, so the +n and expansion rules apply once gated
cmd_named=0   # the name has been seen; every later word belongs to it
cmd_gated=0   # its leading words matched one of GATED_PREFIXES
cmd_stack=()  # the outer command's state, while a `$(...)` is being read
reset_command
for ((idx = 0; idx < ${#words[@]}; idx++)); do
  case "${kinds[idx]}" in
  sep)
    # A `$(...)` or a backtick inside a gated bash invocation builds a word
    # this gate never saw, the way one inside a git invocation does.
    # shellcheck disable=SC2016 # the literal `$(` is the separator's name
    if ((cmd_bash && cmd_gated)) && [[ "${words[idx]}" == '$(' || "${words[idx]}" == *'`'* ]]; then
      refuse "${BASH_EXPAND_MSG}"
    fi
    # A `$(...)` substitution is a nested command: it is decided on its own,
    # and the command around it -- including a redirection of its own already
    # seen -- resumes at the `)` rather than starting over, so
    # `shellcheck $(git ls-files '*.sh') >cosign.pub` is still that command's
    # write.
    # shellcheck disable=SC2016 # the literal `$(` is the separator's name
    if [[ "${words[idx]}" == '$(' ]]; then
      cmd_stack+=("${cmd_writes} ${cmd_bash} ${cmd_named} ${cmd_gated} ${cmd_prefix}")
      reset_command
      continue
    fi
    if [[ "${words[idx]}" == '$)' ]] && ((${#cmd_stack[@]})); then
      check_gated_command
      read -r cmd_writes cmd_bash cmd_named cmd_gated cmd_prefix <<<"${cmd_stack[-1]}"
      unset 'cmd_stack[-1]'
      continue
    fi
    check_gated_command
    reset_command
    continue
    ;;
  target)
    redirection_writes_a_path "${redirects[idx]}" "${words[idx]}" && cmd_writes=1
    continue
    ;;
  *) ;;
  esac
  ((cmd_named)) || ((${command_names[idx]:-0})) || continue
  if ((cmd_named == 0)); then
    cmd_named=1
    [[ "${words[idx]}" == "bash" ]] && cmd_bash=1
  fi
  if ((cmd_gated == 0)); then
    cmd_prefix="${cmd_prefix:+${cmd_prefix} }${words[idx]}"
    command_is_gated "${cmd_prefix}" && cmd_gated=1
  fi
  ((cmd_bash && cmd_gated)) || continue
  [[ "${words[idx]}" == '+'* ]] && refuse "${BASH_NOEXEC_MSG}"
  # A glob is the third rebuild: with a file named `+n` in the working
  # directory, `?n` and `[+]n` reach bash as `+n` (review on
  # aurora-zfs-simple#211), so the rewrite test the shellcheck operands are
  # held to applies here as well.
  if brace_would_expand "${raw_words[idx]}" || [[ "${raw_words[idx]}" == *'$'* ]] ||
    [[ "${raw_words[idx]}" == '<(' || "${raw_words[idx]}" == '>(' ]] ||
    word_bash_would_rewrite "${raw_words[idx]}"; then
    refuse "${BASH_EXPAND_MSG}"
  fi
done
check_gated_command

# The whole string with quoting removed, for the one test that is a substring
# match rather than a word: the shell removes quotes and backslashes on the
# way to git, so `--no-'index'` and `--no-\index` both reach it as
# `--no-index`.
normalized="${command_string//[\'\"\\]/}"

case "${normalized}" in
*--no-index*) refuse "${DIFF_MSG}" ;;
*) ;;
esac

# Git's path_inside_repo, which decides on the *spelling* rather than on where
# the path ends up. That distinction is the whole of this function, and folding
# `..` before the comparison gets it backwards: `git diff --
# ../<checkout>/cosign.key -` names a file inside this repository by a route
# that leaves it and comes back, git's test calls that outside and enters the
# plain-file mode, and a gate that resolved the path first saw a tidy in-tree
# path and allowed it -- reading a denied path with two operands that both look
# local. So an absolute path, any `..` component, and the stdin operand `-` each
# count as outside here, and only a plain relative path is resolved at all. So
# does a leading `~`: to bash that is a home directory, never a path under
# this checkout, and resolving the literal put `~/.aws/credentials` inside
# the tree. Anything this cannot decide -- no working tree, no realpath on
# the host -- counts as outside too, so the gate refuses rather than guesses.
path_inside_worktree() {
  local candidate toplevel
  case "$1" in
  - | /* | '~'*) return 1 ;;
  ../* | */../* | */..) return 1 ;;
  ..) return 1 ;;
  *) ;;
  esac
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  candidate="$(realpath -m -s -- "$1" 2>/dev/null)" || return 1
  [[ "${candidate}" == "${toplevel}" || "${candidate}" == "${toplevel}"/* ]]
}

# The shapes `.claude/settings.json` denies the Read tool. Inside the working
# tree is not enough on its own: `cosign.key` and a `.env` live there, and they
# are the two files those rules exist for. The key and certificate suffixes are
# not in the deny list today; they are here because a rule that only listed
# what is checked in would go quiet the moment someone dropped a `.pem` beside
# it.
denied_read_shape() {
  case "${1##*/}" in
  cosign.key | .env | .env.* | *.pem | *.p12 | id_rsa | id_ed25519) return 0 ;;
  *) return 1 ;;
  esac
}

seen_git=0
in_git=0
in_diff=0
operands=0
unresolved=0
after_dashdash=0
skip_git_option_value=0
in_shellcheck=0
skip_shellcheck_option_value=0

for ((idx = 0; idx < ${#words[@]}; idx++)); do
  word="${words[idx]}"
  kind="${kinds[idx]}"
  # Checked before the command-boundary case below, because a backtick is one
  # of the separators and that case consumes it.
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
  # brace test is `brace_would_expand`: a comma or `..` somewhere after a
  # `{` and before a `}`, which every expansion bash performs must have, and
  # nothing bash would leave alone needs. That test ran above, on the words
  # as typed, because the words here have had their quotes removed and a
  # quote is what keeps `{a';',b}` one word. `$` and a backtick stay refused
  # here: neither has a literal form git relies on.
  #
  # The brace test is scoped to the git invocation's own words (see
  # `raw_in_git` above), so `jq '{a:1}'` is untouched before, after, or
  # without a git command in the same string. The `$` and backtick test here
  # is scoped to `in_git`, the same latch `--output` uses, which holds to the
  # end of the string: `awk '{print $1}'` is untouched in a command string
  # that never invokes git, and refused after one that does.
  # A brace or a `$` *before* the first `git` word is not checked and does not
  # need to be: the allow rules in .claude/settings.json match a literal
  # `git diff`/`git log` prefix, so an invocation assembled out of expansions
  # (`{git,:} diff ...`, `g{i,i}t diff ...`, `$GIT diff ...`) matches no allow
  # rule and prompts on its own. The `$(` and `$)` separators are the
  # split's own names for a substitution's edges, not words; the `$` word
  # that opened the substitution was refused on its own.
  if ((in_git)) && [[ "${kind}" != sep || "${word}" == '`' ]]; then
    case "${word}" in
    *['$`']*) refuse "${EXPAND_MSG}" ;;
    *) ;;
    esac
  fi

  if [[ "${kind}" == sep ]]; then
    # The operand scan starts over at each command boundary. `in_git` does not:
    # it latches for the rest of the command string, so an `--output` in any
    # later command of the same string -- `git log --grep=a|b
    # --output=cosign.pub -1` is `git log --grep=a` piped into `b --output=...`
    # -- is refused rather than handed back unwatched. The cost is refusing an
    # `--output` that belongs to some later non-git command; the alternative
    # is a bypass spelled with one pipe.
    seen_git=0
    in_diff=0
    skip_git_option_value=0
    # Unlike `in_git`, this does not latch past a command boundary. The
    # refusal below is about one command's own operands, so a path belonging
    # to some later command of the string is not its business.
    in_shellcheck=0
    skip_shellcheck_option_value=0
    continue
  fi

  # The target of a redirection is the shell's, not git's: `git diff HEAD
  # 2>&1` has one operand, and the `1` is neither a revision nor a path. The
  # targets the shell would open for writing were refused above, `git diff
  # HEAD > $f` among them, before the `$` test could see it.
  [[ "${kind}" == target ]] && continue

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

  # The operand scan for the other allow-listed command that opens a file it
  # is pointed at. Everything here is refused by default: a word this does not
  # recognise as an option is treated as a path and checked, so an option
  # forgotten here costs a refused lint run rather than an unwatched read.
  if ((in_shellcheck)); then
    if ((skip_shellcheck_option_value)); then
      skip_shellcheck_option_value=0
      continue
    fi
    case "${word}" in
    # The eight short options that take a value, and the long options in the
    # space spelling Haskell's getOpt accepts (`--shell bash`). The attached
    # spellings (`-sbash`, `--shell=bash`) need no entry: they are one
    # dash-prefixed word and fall through to the catch-all below.
    #
    # `--rcfile` is deliberately absent, so the path in its space spelling is
    # checked like any other operand. It is not a read primitive of its own --
    # a malformed rc file draws SC1134, which names the file and the line
    # number but prints no line from it -- and an rc file outside the tree is
    # not something a lint run here needs, so the refusal costs nothing. The
    # attached spelling `--rcfile=PATH` is one dash-prefixed word and is not
    # checked, which is the same conclusion reached the other way round.
    #
    # `-C` is absent too, because its argument is optional and must be
    # attached -- shellcheck reads `-C always` as the flag plus a file named
    # `always`, and so does this.
    -i | -e | -f | -o | -P | -s | -S | -W | \
      --include | --exclude | --format | --enable | --source-path | \
      --shell | --severity | --wiki-link-count)
      skip_shellcheck_option_value=1
      continue
      ;;
    # Stdin, not a file on disk.
    -) continue ;;
    -*) continue ;;
    *) ;;
    esac
    if ! path_inside_worktree "${word}" || denied_read_shape "${word}"; then
      refuse "${SHELLCHECK_MSG}"
    fi
    continue
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

  # The bare word, for the same reason the `git` latch above matches the bare
  # word: .claude/settings.json allows the literal `shellcheck` prefix, so
  # `/usr/bin/shellcheck ...` matches no allow rule and prompts on its own
  # account. Position is not required either -- `SHELLCHECK_OPTS=... shellcheck
  # ./.env` puts the word second -- and the cost of that is an outside path
  # named after the word in some command that is not shellcheck at all
  # (`echo shellcheck /etc/passwd`), refused where it would otherwise have
  # prompted.
  if [[ "${word}" == "shellcheck" ]]; then
    in_shellcheck=1
    skip_shellcheck_option_value=0
  fi
done

exit 0
