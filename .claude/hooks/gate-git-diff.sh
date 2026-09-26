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
# `<<`, `<<<` or `<&`; nor is a redirection on some other command of the same
# string (`echo x >out; git diff HEAD`). A bare `<` is held to a read test of
# its own: `git log --stdin <.env` prints the file's first line back (see
# `GIT_STDIN_MSG`).
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
# unaffected. `bash -n`, the other allowed linter, reads the same way and is
# held to the same test (issue #233): it prints the line a syntax error
# stands on, so `bash -n .env` prints a `NAME=value` line whose value holds a
# `(`, and its options print, or copy, far more -- see the paragraph on it
# below.
#
# An operand is not the only way to aim it at a file. ShellCheck reads standard
# input when its operand is `-`, so `shellcheck - < .env` printed the file back
# exactly as `shellcheck ./.env` did, and the operand scan never saw the path
# because it sat behind the `<` (#212). The target of every bare `<` in such an
# invocation -- with or without a descriptor (`<f`, `0<f`), and in the form
# written before the command name (`< .env shellcheck -`) -- is therefore held
# to what an operand is held to: inside the working tree, none of the deny
# shapes, and spelled out with no brace, leading `~` or glob.
# `/dev/null` stays allowed, since there is nothing to print back and
# `</dev/null` is how a session says "no stdin". `<<` and `<<<` carry a
# delimiter or content rather than a path and need no check, and `<&` and `<>`
# are already decided by the redirection rules.
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
# does `?n` beside a file of that name. And `-n` stops bash running the
# script, not printing it (issue #233): `-v` prints every line bash reads,
# so `bash -n -v ./cosign.key` printed the key. The options that print or
# copy what bash reads are refused in a `bash -n` invocation, read the way
# bash reads its own options (`-nv` is `-n -v`, `-no verbose` is `-n -o
# verbose`), and its operands and a file on its stdin are held to the test
# the shellcheck operands are held to above.
#
# Everything above was written one spelling at a time, and each fix found the
# next. Issue #222 decided the corpus in one pass instead, across the six
# repositories that carry a hook of this kind, and added the rules those five
# shapes still had open here. Two more spellings of an environment assignment:
# `env 'GIT_EXTERNAL_DIFF'=prog git diff HEAD~1`, where env parses its own argv
# after bash has removed the quotes so the as-typed word begins with a quote
# mark rather than a name, and `export GIT_EXTERNAL_DIFF;
# GIT_EXTERNAL_DIFF=prog; git diff HEAD~1`, where the export carries no value
# and the assignment carries no export -- `set -a` being the same arming with
# no name written anywhere. The glob, which is the rewrite that grows the
# operand count: `git diff /etc/passwd*` is one operand here and two plain
# files at git, which prints the diff between them. Git's config options, which
# are `GIT_EXTERNAL_DIFF` spelled as an option: `git -c diff.external=prog diff
# HEAD~1` runs a program once per changed path and `-c` was on the list of
# options whose value this scan stepped over. And the move, which makes a
# containment test answer about the wrong file rather than run a program: `git
# -C /home/dev diff -- .bashrc .profile` printed two home-directory files with
# both operands resolving inside this checkout, so git's relocating options, a
# `cd` or `pushd` before the command, and `env -C` are decided rather than
# folded away. `tests/test-claude-settings.sh` holds the whole corpus as a
# table of (command, expected) rows and mutates each of these rules to prove
# the row it exists for flips; `_note_command_corpus` in
# `.claude/settings.json` records the decision for every shape, the ones this
# repository cannot reach included.
#
# Two wrappers were still read wrong after that pass. Claude Code 2.1.267's
# permission matcher steps over `noglob` before it matches an allow row, the
# way it steps over `timeout` and `nohup`, and this gate did not: `noglob
# podman ps >out` matched `Bash(podman ps:*)` and emptied `out` -- bash opens
# the target before it finds no command called `noglob`, and zsh runs the
# command -- while the gated-prefix scan read `noglob` as the name and never
# saw `podman ps`. It is in the wrapper list now. `xargs` was in that list,
# and a wrapper is the wrong model of it: xargs appends words it reads from
# standard input, or from the file its `-a` option names, to the command it
# runs, so the operands git or shellcheck receive are not in the string at
# all. `printf '%s\n' /dev/null ./cosign.key | xargs git diff` is the
# two-operand plain-file read with a one-word git invocation, and the same
# matcher accepts `xargs git diff` for `Bash(git diff:*)` as readily as `git
# diff`, so nothing prompted. An `xargs` in front of git or an allow-listed
# command is refused outright, wherever it stands among the other wrappers
# (see `XARGS_MSG`); in front of any other command it is left alone, since
# that command matches no allow row and prompts on its own. The command xargs
# runs is the first word after xargs's own options, so `git ls-files | xargs
# rg shellcheck` runs rg and is left alone. A path to a wrapper is cut at its
# last `/` or `\`, as the matcher cuts it: `/usr/bin/NAME` and `/bin/NAME`
# are that wrapper, and any other path to one (`./shim/nohup`) is refused,
# since the file at that path is what runs (see `WRAPPER_PATH_MSG`).
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
REDIRECT_MSG='blocked: an output redirection (>, >>, >|, &>, &>>, N>, >&FILE, <>) inside a git invocation makes the shell open its target for writing before git runs -- `git diff HEAD >cosign.pub` truncates the trust anchor, and `>> .claude/settings.json` or `2> .claude/hooks/gate-git-diff.sh` reach any file this uid can write -- and the allow rule for git diff, git log and git show sees none of it. These commands print to stdout; read that instead. Descriptor forms (2>&1, >&2, >&-), here-documents, here-strings and <&N are not affected (a bare < has a read test of its own), and a redirection on another command of the same string is that command'"'"'s own.'

# shellcheck disable=SC2016 # the literal $HOME is what the reader has to see
TILDE_MSG='blocked: an unquoted leading ~ is $HOME to bash and a literal directory inside this checkout to this gate, so the path checked here is not the path git would open: `git diff -- ~/.aws/credentials ~/.bashrc` resolved both operands inside the working tree and printed both files out of the home directory as a plain-file diff, past the Read(...) deny rules in .claude/settings.json. A word of a git invocation that begins with an unquoted ~ (~/..., ~user/..., or ~ alone) is refused rather than expanded. Spell the path out in full, relative to the checkout. A tilde inside a word (HEAD~1) and a quoted or escaped one are literals to bash and are not refused by this rule.'

# shellcheck disable=SC2016 # the literal $G and $(...) are what the reader has to see
CMD_MSG='blocked: the name of a command in this string is not spelled literally -- it is built by an expansion (`$G diff ...`, `$(printf git) diff ...`, a backtick in command position), by a brace (`{,git} diff ...`), or by a glob (`g?t`, `/usr/bin/g[i]t`) -- so neither this gate nor the allow rule that matched the string'"'"'s literal prefix can tell which command bash will run, and `G=git; $G diff /dev/null ./cosign.key` runs the plain-file read this gate exists to refuse. Spell every command name literally, and drop a variable assignment that only exists to build one. After a wrapper such as command, env, exec, timeout or xargs the same holds for every word of that command, since the wrapper'"'"'s own options are not modelled here. A literal name after an assignment is not what this rule refuses -- the assignment has a refusal of its own -- and a literal path to git (`/usr/bin/git diff`) is read as git. env -S (--split-string) splits a quoted string into a command this gate never sees and is refused outright.'

SHELLCHECK_MSG='blocked: shellcheck prints the source line above every diagnostic it reports, so pointing it at this path prints that file back -- every unexported NAME=value line of a .env, the BEGIN/END lines of a key -- past the Read(...) deny rules in .claude/settings.json, which gate the Read tool and say nothing about what an allow-listed Bash command opens. Operands must be inside the working tree and must not be one of the secret-shaped names those rules list (cosign.key, .env, .env.*, *.pem, *.p12, id_rsa, id_ed25519). Linting this repository'"'"'s own scripts is unaffected. Describe such a file with ls -l or wc -c instead.'

SHELLCHECK_OPTS_MSG='blocked: SHELLCHECK_OPTS is not a list of options -- shellcheck splits it and prepends it to its own argv, operands included, so SHELLCHECK_OPTS=./.env shellcheck tests/run-tests.sh lints the .env as well and prints its lines back, with no path in the argv this gate scans. The += append spelling sets it just the same, since appending to an unset variable creates it. Nothing in this repository sets the variable, so it is refused outright. Pass options after the command name instead.'

# shellcheck disable=SC2016 # the literal $HOME is what the reader has to see
SHELLCHECK_EXPAND_MSG='blocked: bash rewrites this word before shellcheck sees it, and this gate reads the words as typed, so the path checked here is not the path shellcheck would open: shellcheck {tests/run-tests.sh,/etc/shadow} is one word to the operand scan here and two files to shellcheck -- the second of which it would print back; an unquoted leading ~ is $HOME to bash and a literal directory inside this checkout to the gate (shellcheck ~/.aws/credentials); an unquoted glob character (*, ? or a bracket) is what bash expands into files this gate never saw (shellcheck .env*); and a $, a backtick or a process substitution supplies operands at runtime. Expanding them correctly means reimplementing bash inside a hook, so they are refused instead. Spell every path out in full, relative to the checkout.'

# shellcheck disable=SC2016 # the backticks quote command spellings for the reader
SHELLCHECK_READ_MSG='blocked: shellcheck reads standard input when its operand is `-`, and it prints the source line above every diagnostic it reports, so `shellcheck - < .env` prints the file back exactly as `shellcheck ./.env` does -- and the operand scan says nothing, because the path sits behind the `<` rather than in the argv. The target of a bare `<` on a shellcheck invocation is checked the way an operand is: it must be inside the working tree, must not be one of the secret-shaped names the Read(...) deny rules in .claude/settings.json list (cosign.key, .env, .env.*, *.pem, *.p12, id_rsa, id_ed25519), and must be spelled out -- no brace, no leading ~, no glob, since those are words bash rewrites before shellcheck opens anything. Redirecting from a script inside the checkout is unaffected, and so is </dev/null. Describe such a file with ls -l or wc -c instead.'

# shellcheck disable=SC2016 # the backticks quote command spellings for the reader
GIT_STDIN_MSG='blocked: git log, git show and git diff take revisions from standard input under --stdin, one per line, and the first line that is not a revision ends the run with fatal: bad revision followed by that line, so `git log --stdin <.env` prints the first line of the file back past the Read(...) deny rules in .claude/settings.json. The target of a bare < on a git invocation is therefore checked the way a shellcheck one is: it must be inside the working tree, must not be one of the secret-shaped names those rules list (cosign.key, .env, .env.*, *.pem, *.p12, id_rsa, id_ed25519), and must be spelled out -- no brace, no leading ~, no glob. Put the revisions in a file inside the checkout (`git log --stdin <revs.txt`), or name them on the command line. </dev/null, here-strings and <&N are unaffected.'

OUT_MSG='blocked: git --output=FILE (and the space form) writes this diff or log to the path it names instead of stdout, overwriting any file this uid can reach -- cosign.pub, .claude/settings.json, this hook, ~/.ssh/authorized_keys -- with no Read(...) deny rule in its way. git diff, git log and git show print to stdout; read that instead. --output-indicator-* is a different flag and is unaffected.'

# shellcheck disable=SC2016 # the message quotes shell spellings as literal text
GATED_REDIRECT_MSG='blocked: an output redirection (>, >>, >|, &>, &>>, N>, >&FILE, <>) inside an allow-listed command makes the shell open its target for writing before the command runs, and the allow rule matches a command prefix while the redirection is the rest of the string, so nothing prompts: `shellcheck tests/run-tests.sh >cosign.pub` truncates the trust anchor before a line is linted, and `gh run view 1 --log >.claude/settings.json` overwrites the file holding these rules. It is the same write .claude/hooks/gate-git-diff.sh already refuses for `git diff HEAD >cosign.pub`. These commands print to stdout; read that, or pipe it. Descriptor forms (2>&1, >&2, >&-) and input redirections (<, <<, <<<, <&) open nothing for writing and are not refused by this rule -- the target of a bare < on a shellcheck run is checked by a rule of its own, because that command prints back what it reads -- and a command no allow rule covers is left alone: that one prompts on its own.'

# shellcheck disable=SC2016 # the literal $(...) and <( are what the reader has to see
GATED_SUBST_MSG='blocked: a substitution or an expansion -- `$(...)`, a backtick, `$VAR`, `<(...)` or `>(...)`, quoted or not, in a word or a redirection target -- in an allow-listed command runs a command or supplies a word as part of a string the allow rule approved on its prefix alone, and neither is held to any rule: `df -T >(cat >cosign.pub)` and `podman images $(printf x >cosign.pub)` truncate the trust anchor from inside the substitution while the command prints as usual. It is refused in these commands the way it is in a git or shellcheck invocation. Write the inner command as a command of its own.'

# shellcheck disable=SC2016 # the literal $(...) and <<EOF are what the reader has to see
GATED_HEREDOC_MSG='blocked: a here-document with an unquoted delimiter (`<<EOF`) on an allow-listed command is expanded by bash before the command runs, so a `$(...)` or a backtick on any line of its body runs as part of the string the allow rule approved on its prefix, and this gate reads those lines as commands of their own: `df -T <<EOF` followed by a `$(printf x >cosign.pub)` line writes the file while df prints as usual. Quote the delimiter (`<<'"'"'EOF'"'"'`) so the body is literal, or pass the input another way.'

# shellcheck disable=SC2016 # the literal NAME=value spellings are what the reader has to see
GATED_ENV_MSG='blocked: an assignment before an allow-listed command (`NAME=value cmd ...`) is an environment the command runs under, and for these commands that changes what runs or where it goes: `LD_PRELOAD=x.so shellcheck f` loads code before a line is linted, `BASH_ENV=f bash -n x` names a file for bash to read, `GH_HOST=other gh pr list` sends the token elsewhere, `CONTAINERS_CONF=f podman ps` re-points podman. A git invocation is held to the same rule (issue #218): `GIT_EXTERNAL_DIFF=prog git diff HEAD~1` runs prog once per changed path, `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=diff.external GIT_CONFIG_VALUE_0=prog` reaches that same driver under another name, and `PATH=dir git diff HEAD~1` runs a different git -- each of them arbitrary code from a string the allow rows match on their git prefix. A deny list of variable names is the wrong shape for this, since GIT_DIR, GIT_INDEX_FILE, LD_PRELOAD and PATH all matter and the list would have to track git'"'"'s own. Run the command without the assignment.'

# shellcheck disable=SC2016 # the literal builtin spellings are what the reader has to see
EXPORT_ENV_MSG='blocked: an assignment made by the export family (`export NAME=value`, `declare -x`, `typeset -x`, `readonly`) reaches a later command of the same string exactly as a leading `NAME=value` does, and this string arms one and then runs an allow-listed command or git: `export GIT_EXTERNAL_DIFF=prog; git diff HEAD~1` runs prog once per changed path while no word of the git invocation carries an assignment at all, and `export LD_PRELOAD=x.so; shellcheck f` loads code before a line is linted. The builtin is refused rather than its options read, because the flag that exports has several spellings (-x, -gx, an earlier `declare -x NAME` with a plain `NAME=value` after it) and a half-modelled option list is a gate that disagrees with bash in some other direction. A bare name is refused for that reason too: `export GIT_EXTERNAL_DIFF; GIT_EXTERNAL_DIFF=prog; git diff HEAD~1` exports the variable first and assigns to it afterwards, in a command bash reads as an assignment of its own, and the value lands in git'"'"'s environment just the same. `set -a` (and `set -o allexport`) is the same arming with no name in it at all -- from there bash exports every assignment it performs -- so a word of `set` that carries an `a` arms it as well. Only a string that also runs one of those commands is refused; an export on its own is not this gate'"'"'s business. Residual, stated rather than implied: bash keeps an exported variable across Bash calls, so an export approved in an earlier call is outside what a PreToolUse hook reading one command string can see, and so is a variable exported by a file the string sources.'

# shellcheck disable=SC2016 # the config keys are spellings the reader has to see
GIT_CONFIG_MSG='blocked: `git -c NAME=VALUE`, `--config-env=NAME=VAR`, `--exec-path`, `--upload-pack` and `--receive-pack` each hand git a setting or a program to load, and several of those settings name a program git then runs: `git -c diff.external=prog diff HEAD~1` runs prog once per changed path, and `git --config-env=diff.external=VAR diff HEAD~1` reaches the same driver with the value held in a variable -- the same code execution this gate refuses for `GIT_EXTERNAL_DIFF=prog git diff HEAD~1`, spelled as an option instead of as an environment. A list of which config keys run a program is the wrong shape for the refusal: diff.external, diff.*.command, difftool.*.cmd, core.pager, pager.*, core.editor, core.sshCommand, core.hooksPath, core.fsmonitor, alias.*, filter.*.clean, uploadpack.packObjectsHook and credential.helper all do, and git keeps adding them -- so the option is refused whatever it carries. Set the value in the repository config, which is a command of its own and prompts on its own, or run git without it.'

# shellcheck disable=SC2016 # the glob spellings are what the reader has to see
GIT_GLOB_MSG='blocked: an unquoted glob character (*, ? or a bracket) in a word of a git invocation is expanded by bash before git sees it, so the operands this gate counted are not the operands git receives: `git diff /etc/passwd*` is one word here and two plain files at git, which prints the diff between them, and `git diff .env*` is that same read of two untracked files inside the checkout -- the plain-file mode reached with one operand written and no flag anywhere. Expanding it correctly means reimplementing bash inside a hook, so it is refused instead, as it already is in a shellcheck and a bash -n invocation. Quote the pathspec (`git diff -- '"'"'tests/*.sh'"'"'`), which is the spelling git expands itself, or write the paths out.'

# shellcheck disable=SC2016 # the option spellings are what the reader has to see
MOVED_MSG='blocked: this string changes the directory the paths in it are resolved against -- a `cd` or `pushd` before the command, `env -C DIR`, or git'"'"'s own -C, --git-dir, --work-tree, --namespace, --super-prefix or --attr-source -- and the containment test here runs against this checkout while the command opens paths under the new directory. So every operand looked local and none was: `git -C /home/dev diff -- .bashrc .profile` printed two files out of the home directory as a plain-file diff, and `cd /home/dev && shellcheck .bashrc` printed one back through the source line it echoes. Operands are undecidable once the directory moves, so the two-operand diff, a shellcheck or bash -n operand and a file on the stdin of either are refused there. Run the command from the checkout with its paths spelled relative to it.'

# shellcheck disable=SC2016 # the option spellings are what the reader has to see
WRAPPER_SHELL_MSG='blocked: `flock -c COMMAND` (and `--command=COMMAND`) hands the string to a shell rather than passing it as an ordinary command word -- `flock --help` documents `-c, --command <command>` as running a single command string through the shell -- so `git status; flock /tmp/l -c '"'"'cat ./cosign.key'"'"'` runs the read past the Read(./cosign.key) deny rule with `git status` alone matching the allow row this string is judged against. This scan reads words, not a nested shell program inside one, so that string is never re-parsed for a gated name hiding in it; the option is refused outright, the way env -S is. Run the command flock would run as a command of its own.'

# shellcheck disable=SC2016 # the backticks quote command spellings for the reader
WRAPPER_PATH_MSG='blocked: a wrapper (nohup, timeout, nice, env, xargs, ...) is written here as something other than its bare name, /usr/bin/NAME or /bin/NAME -- a path, a quote or a backslash in it -- and the file that spelling names is what runs, or nothing runs and only the redirection happens (/usr/bin\timeout is /usr/bintimeout to bash): `./shim/nohup git diff HEAD` runs whatever ./shim/nohup is -- a file an agent can write -- while Claude Code'"'"'s permission matcher cuts the word at its last / or \, takes it for the nohup it steps over, and matches the allow rule against the words after it alone, so nothing prompts. Write the bare name (nohup git diff HEAD) or its /usr/bin path.'

# shellcheck disable=SC2016 # the backticks quote a command spelling for the reader
BASH_NOEXEC_MSG='blocked: `bash -n` is allow-listed because -n reads a script without running it, and a later +n or +o noexec on the same command line turns that off again, so `bash -n +n -c COMMAND` and `bash -n +o noexec script.sh` run whatever they name under the linter'"'"'s allow rule with no prompt. A word beginning with + in a bash -n invocation is refused. Check syntax with bash -n FILE and nothing else; to run a script, run it as itself so the permission rules see it.'

# shellcheck disable=SC2016 # the literal ${VAR} and $(...) are what the reader has to see
BASH_EXPAND_MSG='blocked: a brace bash could expand, an unquoted glob character (*, ? or a bracket), an unquoted leading ~, a $ or a backtick in a word of a bash -n invocation is refused rather than expanded (a process substitution is refused by GATED_SUBST_MSG), for the reason EXPAND_MSG gives for git: bash rewrites the words before the inner bash sees them, so `{+,+}n` matches no spelling here and reaches bash as +n, which turns noexec off, `?n` does the same when a file named +n exists in the working directory, and $(...), ${VAR} and a backtick supply a word this gate never saw. Write the command out in full.'

# shellcheck disable=SC2016 # the backticks quote command spellings for the reader
BASH_ECHO_MSG='blocked: this bash -n invocation carries an option that makes bash print or copy what it reads, and -n stops bash running a script, not printing it: -v (and -o verbose) prints every line as bash reads it, so `bash -n -v ./cosign.key` prints the whole key past the Read(...) deny rules in .claude/settings.json; -D prints every $"..." string in the script; -o history and -i copy every line into ~/.bash_history when bash exits; -i and -l read ~/.bashrc and the login profiles and print the line a syntax error in them stands on, and so does a login shell started without -l: exec -l, or exec -a / env -a (--argv0) naming a zeroth argument that begins with -. -x (and -o xtrace) prints what bash runs, which under -n is nothing; it is refused with the rest because a syntax check has no use for it. bash reads a cluster of letters as separate options (-nv is -n -v) and takes the value of -o from the next word (-no verbose is -n -o verbose), and so does this gate. Check syntax with bash -n FILE and nothing else.'

# shellcheck disable=SC2016 # the backticks quote command spellings for the reader
BASH_READ_MSG='blocked: bash -n prints the line a syntax error stands on, so pointing it at a file prints that line back -- `bash -n .env` prints a NAME=value line whose value holds a ( -- past the Read(...) deny rules in .claude/settings.json, which gate the Read tool and say nothing about what an allow-listed Bash command opens. bash reads the script from standard input when no file is named, so `bash -n - < .env` is the same read. Every operand of a bash -n invocation, and the target of a bare < on it, must be inside the working tree and must not be one of the secret-shaped names those rules list (cosign.key, .env, .env.*, *.pem, *.p12, id_rsa, id_ed25519); </dev/null stays allowed. Check the syntax of this repository'"'"'s own scripts.'

# shellcheck disable=SC2016 # the backticks quote command spellings for the reader
XARGS_MSG='blocked: xargs adds words it reads from standard input (or from the file its -a option names) to the command it runs, so the operands git or the linter receive are not in this string and cannot be checked here: `printf '"'"'%s\n'"'"' /dev/null ./cosign.key | xargs git diff` hands git the two-operand plain-file read of the key while the git invocation this gate reads has no operand at all, and `xargs -a list.txt shellcheck` prints back whatever list.txt names. And Claude Code matches `xargs git diff` against the `Bash(git diff:*)` allow rule as readily as `git diff`, so nothing prompts either. xargs in front of git or an allow-listed command is refused, wherever it stands among other wrappers (`timeout 5 xargs git diff`); in front of any other command it is left to the permission rules. Name the operands in the command itself instead.'

# shellcheck disable=SC2016 # the option spellings are what the reader has to see
PODMAN_PROFILE_MSG='blocked: podman --cpu-profile FILE and --memory-profile FILE (and their =FILE forms) are persistent global options podman accepts after the subcommand too, so `podman images --cpu-profile cosign.pub` matches the Bash(podman ps:*), Bash(podman images:*) and Bash(podman inspect:*) allow rows on their subcommand prefix while podman opens the path for writing and dumps a pprof profile into it -- it truncates the trust anchor, .claude/settings.json, this hook or any file this uid can reach, and truncates the target even when the command then fails, with no Read(...) deny rule in its way. It is the write .claude/hooks/gate-git-diff.sh already refuses for `git --output` and for a `>` redirection on these commands, spelled as a podman option instead. These allow-listed podman verbs only read state; drop the flag. Profile podman under a verb that prompts on its own.'

# shellcheck disable=SC2016 # the spellings are what the reader has to see
PODMAN_EXPAND_MSG='blocked: bash rewrites this word of a podman invocation before podman sees it, and the profile-option check above reads words as typed, so it cannot tell whether the result is --cpu-profile or --memory-profile: `podman images --cpu-pro{f..f}ile cosign.pub` is a brace bash expands to --cpu-profile with no file needed, and `podman images --cpu-profil*` becomes --cpu-profile=cosign.pub as soon as a file of that name exists in the working directory -- either way podman dumps a pprof profile over cosign.pub with no prompt. An expanding brace, an unquoted glob character (*, ? or a bracket) or an unquoted leading ~ in a word of a gated podman command is refused rather than expanded. Quote a pattern podman should see literally (`podman images '"'"'fedora*'"'"'`), or write the words out.'

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
  '#')
    # A `#` that begins a word after whitespace starts a comment, which bash
    # drops through the end of the line, so `shellcheck tests/run-tests.sh
    # # output > file` opens nothing (review on aurora-zfs-simple#211). Only
    # that spelling is dropped here: a `#` inside a word (`HEAD^#x`) is a
    # character of it, and one straight after an operator (`;#`, `>#`) is
    # kept as a word, which can only over-refuse.
    if [[ -z "${raw_word}" ]] && { ((i == 0)) || [[ "${command_string:i-1:1}" == [$' \t\n'] ]]; }; then
      while ((i + 1 < ${#command_string})) && [[ "${command_string:i+1:1}" != $'\n' ]]; do
        ((i++))
      done
    else
      raw_word+="${ch}"
    fi
    ;;
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
# (`command`, `exec`, `env`, `nohup`, `noglob`, `xargs`, `timeout`, ...) the
# name is somewhere among the words that follow, behind options this gate
# does not model -- `command -- $G` -- so every remaining word of that
# command is held to the test. A word in that position carrying a `$`, a
# backtick, a `*` or `?`, a `[` (other than the `[` and `[[` commands
# themselves), or a brace bash would expand is refused, and so is an
# unquoted backtick opening there, whose output would be the name. A literal
# name whose last path component is `git` is rewritten to `git`, so
# `/usr/bin/git diff` opens every scope that `git diff` does. A
# redirection's target is never the name. One wrapper option is modelled,
# because it is not an option but an
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
#
# `noglob` is one of those wrappers because Claude Code's permission matcher
# steps over it before matching an allow row, as it steps over `nohup` and
# `timeout`: read as the name, it hid `podman ps` in `noglob podman ps >out`
# from the gated-prefix scan below, which decides the write from the name.
# `xargs` is recorded as well as stepped over, in `xargs_names`: it is the
# one wrapper that adds words to the command it runs, so that scan refuses
# it in front of git or an allow-listed command (see `XARGS_MSG`). Its own
# options are read, too, so that the command it runs is known and the words
# after that command are its arguments rather than names (see below).
#
# Whether a word in a name position is spelled literally: no `$`, backtick,
# `*` or `?`, no `[` other than the `[` and `[[` commands themselves, and no
# brace bash would expand.
name_is_literal() {
  local raw="$1" word="$2"
  [[ "${raw}" == *'$'* || "${raw}" == *'`'* || "${raw}" == *'*'* || "${raw}" == *'?'* ]] && return 1
  brace_would_expand "${raw}" && return 1
  [[ "${raw}" == *'['* && "${word}" != '[' && "${word}" != '[[' ]] && return 1
  return 0
}

# The word as bash hands it to the command, into `unquoted`: quotes removed,
# and a backslash dropped where it escapes the next character -- anywhere
# outside quotes, and inside double quotes only before $, a backtick, " or \
# -- but kept where it is literal, as it is inside single quotes. `words`
# drops every backslash, which is not the word a path is cut at:
# `'./shim\nohup'` is `./shim\nohup` to the command and `./shimnohup` in
# `words`. A `$` never reaches this, since the literal test refuses it first.
unquote_word() {
  local raw="$1" quote='' escaped=0 i ch
  unquoted=''
  for ((i = 0; i < ${#raw}; i++)); do
    ch="${raw:i:1}"
    if ((escaped)); then
      escaped=0
      if [[ "${quote}" == '"' ]]; then
        case "${ch}" in
        '$' | '`' | '"' | $'\\') ;;
        *) unquoted+=$'\\' ;;
        esac
      fi
      unquoted+="${ch}"
    elif [[ "${quote}" == "'" ]]; then
      if [[ "${ch}" == "'" ]]; then quote=''; else unquoted+="${ch}"; fi
    elif [[ "${ch}" == $'\\' ]]; then
      escaped=1
    elif [[ "${ch}" == '"' ]]; then
      if [[ "${quote}" == '"' ]]; then quote=''; else quote='"'; fi
    elif [[ "${ch}" == "'" && -z "${quote}" ]]; then
      quote="'"
    else
      unquoted+="${ch}"
    fi
  done
}

# GNU findutils' and uutils' xargs short options, clustered the way getopt
# allows (`-0rn1`). Returns non-zero at a letter it does not know, and at an
# optional-value letter (`-e`, `-i`, `-l`) with no value attached, which the
# two implementations read differently. Sets `xargs_optarg` when a letter
# that takes a value ends the word, so the value is the next word.
xargs_short_options() {
  local cluster="${1#-}" i
  for ((i = 0; i < ${#cluster}; i++)); do
    case "${cluster:i:1}" in
    0 | o | p | r | t | x) ;;
    a | d | E | I | L | n | P | s)
      ((i + 1 < ${#cluster})) || xargs_optarg=1
      return 0
      ;;
    e | i | l)
      ((i + 1 < ${#cluster}))
      return
      ;;
    *) return 1 ;;
    esac
  done
  return 0
}
command_word_pending=1 # the next word of this command may be its name
after_time=0           # the last name-position word was `time`, whose -p may follow
after_wrapper=0        # a wrapper ran: every remaining word may be the name
command_names=()       # 1 at each index that names, or may name, a command
name_assignments=()    # 1 at each assignment this scan skipped before a name
moves_dir=()           # 1 at each name that moves the shell's working directory
xargs_names=()         # 1 at each `xargs` in a position a command's name may take
argv0_words=()         # 1 at each exec/env option that sets the zeroth argument
xargs_state=0          # 1: xargs's own options are being read; 2: after its `--`
xargs_optarg=0         # the next word is the value of an xargs option
xargs_command_idx=-1   # the word xargs runs, once its options are read
worktree_moved=0       # a name above has moved it, for the scans that follow
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
      name_stack+=("${command_word_pending} ${after_wrapper} ${xargs_state} ${xargs_optarg} ${wrapper_name}")
      command_word_pending=1
      after_wrapper=0
      wrapper_name=''
      xargs_state=0
      xargs_optarg=0
      continue
    fi
    if [[ "${words[idx]}" == '$)' ]] && ((${#name_stack[@]})); then
      read -r command_word_pending after_wrapper xargs_state xargs_optarg wrapper_name <<<"${name_stack[-1]}"
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
        xargs_state=0
        xargs_optarg=0
        continue
      fi
      ((command_word_pending)) && refuse "${CMD_MSG}"
      in_backtick=1
    fi
    command_word_pending=1
    after_wrapper=0
    after_time=0
    wrapper_name=''
    xargs_state=0
    xargs_optarg=0
    continue
    ;;
  target) continue ;;
  *) ;;
  esac
  ((command_word_pending)) || continue
  raw_word="${raw_words[idx]}"
  word="${words[idx]}"
  # xargs's own options and their values, read so that the command xargs
  # runs is known: it is the first word after them, and the words after it
  # are that command's arguments rather than names -- `git ls-files | xargs
  # rg shellcheck` runs rg with `shellcheck` as its pattern, and read as a
  # chain of name candidates it was refused as a shellcheck run (review on
  # #224). Read here, before the assignment and keyword tests below, which
  # would take the value in `-I if` or `-I A=1` for a word of their own and
  # hand the value's slot to the command after it. Held to the literal test
  # all the same: bash splits an unquoted `$X` in `-n$X` into more words. An
  # option GNU findutils and uutils do not both read the same way, or that
  # neither has (`-J`), or an abbreviated long option, leaves the older
  # reading in place: every later word may be the name.
  if ((xargs_optarg)); then
    name_is_literal "${raw_word}" "${word}" || refuse "${CMD_MSG}"
    xargs_optarg=0
    continue
  fi
  if ((xargs_state == 1)) && [[ "${word}" == -?* ]]; then
    name_is_literal "${raw_word}" "${word}" || refuse "${CMD_MSG}"
    case "${word}" in
    --)
      xargs_state=2
      continue
      ;;
    --arg-file | --delimiter | --max-args | --max-procs | --max-chars | --process-slot-var)
      xargs_optarg=1
      continue
      ;;
    --arg-file=* | --delimiter=* | --max-args=* | --max-procs=* | --max-chars=* | \
      --process-slot-var=* | --eof=* | --replace=* | --max-lines=* | --null | \
      --open-tty | --interactive | --no-run-if-empty | --verbose | --exit | --show-limits)
      continue
      ;;
    --*) ;;
    *) xargs_short_options "${word}" && continue ;;
    esac
    xargs_state=0 # not an option this reads: every later word may be the name
  fi
  if ((xargs_state)); then
    xargs_state=0
    xargs_command_idx=${idx}
  fi
  if ((after_time)) && [[ "${word}" == '-p' || "${word}" == '--' ]]; then
    continue # time's own option (review on arch-bootc#322); the name is still to come
  fi
  after_time=0
  if [[ "${raw_word}" =~ ^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?= ||
    "${word}" =~ ^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?= ]]; then
    # An assignment; the name is still to come. Recorded, because this scan
    # is the only one that knows the word stands before a name: a wrapper's
    # own option is a name candidate, so `env -u X GIT_EXTERNAL_DIFF=prog git
    # diff` left the word loop below believing the name had already been seen
    # (issue #218).
    #
    # Tested on the quote-stripped spelling as well as on the word as typed,
    # because `env` parses its own arguments and the quotes are gone by then:
    # `env 'GIT_EXTERNAL_DIFF'=prog git diff HEAD~1` runs prog once per
    # changed path, and the as-typed word begins with a quote mark rather than
    # a name, so the pattern above found no assignment. Bash itself does not
    # read a quoted name as an assignment -- `'FOO'=1 cmd` looks for a command
    # called `FOO=1` -- so the bare form is over-refused here, which costs a
    # command nothing runs.
    name_assignments[idx]=1
    continue
  fi
  case "${word}" in
  time)
    after_time=1 # `time -p CMD`: the option is time's, not the name
    continue
    ;;
  '{' | '}' | '!' | if | then | else | elif | fi | do | done | while | until | coproc)
    continue # a keyword; the name is still to come
    ;;
  *) ;;
  esac
  if [[ "${wrapper_name}" == env ]] &&
    [[ "${raw_word}" =~ ^-[^-]*S || "${raw_word}" == --split-string* ]]; then
    refuse "${CMD_MSG}"
  fi
  # env's other option that is not an option: -C DIR (--chdir) runs the
  # command from another directory, so the paths in it resolve somewhere this
  # gate never looked -- `env -C /home/dev git diff -- .bashrc .profile`
  # printed two home-directory files as a plain-file diff with both operands
  # looking local. The git and shellcheck operand scans below refuse a moved
  # directory rather than guess at it; this spelling is refused here, where
  # the wrapper is already known.
  if [[ "${wrapper_name}" == env ]] &&
    [[ "${raw_word}" =~ ^-[^-]*C || "${raw_word}" == --chdir* ]]; then
    refuse "${MOVED_MSG}"
  fi
  # flock's -c/--command hands its argument to a shell rather than passing
  # it as a word of the command flock runs, so the operand and gated-prefix
  # scans below -- which read words, not a nested shell program hiding
  # inside one -- never see a gated name written there: `flock /tmp/l -c
  # 'cat ./cosign.key'` reads the key past the deny rule with `flock`'s own
  # words looking like an ordinary, harmless invocation. Refused outright,
  # the way env -S is.
  if [[ "${wrapper_name}" == flock ]] &&
    [[ "${raw_word}" =~ ^-[^-]*c || "${raw_word}" == --command* ]]; then
    refuse "${WRAPPER_SHELL_MSG}"
  fi
  # bash starts as a login shell when its zeroth argument begins with `-`,
  # which is what exec's -l puts there, and what exec -a and env -a
  # (--argv0) can set: `exec -l bash -n tests/run-tests.sh` and `exec -a
  # -bash bash -n ...` read ~/.bash_profile and print the line a syntax
  # error in it stands on, the read `bash -n -l` is refused for, with no
  # `-l` among bash's own words (review on #237). Marked here, where the
  # wrapper is known, and refused in front of a gated bash below. Any exec
  # option carrying an `l` or an `a` counts, whatever the value: `exec -a
  # bash` sets no dash, and refusing it costs a spelling nobody needs.
  # Claude Code does not step over exec or env before it matches an allow
  # row, so these spellings prompt today; they are refused so that this
  # gate does not rest on that.
  if [[ "${wrapper_name}" == exec && "${raw_word}" =~ ^-[^-]*[al] ]] ||
    [[ "${wrapper_name}" == env && ("${raw_word}" =~ ^-[^-]*a || "${raw_word}" == --argv0*) ]]; then
    argv0_words[idx]=1
  fi
  name_is_literal "${raw_word}" "${word}" || refuse "${CMD_MSG}"
  # A wrapper, matched on its last path component once the word is known to
  # be literal. Claude Code's permission matcher cuts a word at its last `/`
  # or `\` (`replace(/^.*[\\/]/, "")`) and steps over what is left when it
  # names a wrapper it strips (`nohup`, `timeout`, `nice`, ...), so any path
  # to one -- including one to a file an agent wrote, `./shim/nohup git diff
  # HEAD` or `'./shim\nohup' git diff HEAD` -- has the allow rule matched
  # against the words after it, while bash runs the file at that path
  # (review on atomic-image-builder#438).
  # Read as the name here instead, `git status; /usr/bin/xargs git diff` hid
  # the git behind it from every scan (review on zfs-kinoite-complex#235). So
  # the component is cut on both separators, and it is tried on two
  # spellings: the word as typed, quote marks dropped but every backslash
  # kept, which is the text the matcher cuts (`/usr/bin\timeout` is
  # `/usr/bintimeout` to bash, command-not-found, and still `timeout` to the
  # matcher, which auto-allows `/usr/bin\timeout 5 podman ps >out` while bash
  # truncates `out`; review on sensi#259), and the word as bash hands it on.
  # Only the typed spellings `NAME`, `/usr/bin/NAME` and `/bin/NAME` are
  # stepped over as the wrapper they name; any other spelling of a wrapper is
  # refused outright (see `WRAPPER_PATH_MSG`). Checked after the literal test
  # so that `$D/env git diff HEAD` is still refused as a name built at
  # runtime.
  unquote_word "${raw_word}"
  typed_base="${raw_word//[\'\"]/}"
  typed_base="${typed_base##*[/\\]}"
  for wrapper_base in "${typed_base}" "${unquoted##*[/\\]}"; do
    case "${wrapper_base}" in
    command | builtin | exec | env | nohup | noglob | nice | xargs | timeout | stdbuf | sudo | doas | \
      setsid | ionice | chrt | taskset | unshare | flock)
      case "${raw_word}" in
      "${wrapper_base}" | /usr/bin/"${wrapper_base}" | /bin/"${wrapper_base}") ;;
      *) refuse "${WRAPPER_PATH_MSG}" ;;
      esac
      after_wrapper=1
      wrapper_name="${wrapper_base}"
      if [[ "${wrapper_name}" == xargs ]]; then
        xargs_names[idx]=1
        xargs_state=1
      fi
      continue 2
      ;;
    *) ;;
    esac
  done
  # A literal path to a gated tool reaches the same tool. `/usr/bin/git diff`
  # is rewritten so every scope `git diff` opens is opened for it too, and
  # `/usr/bin/shellcheck ./.env` is rewritten for the same reason: it prints
  # the source line back exactly as the bare spelling does, and reading the
  # gate's coverage off whether an allow rule would have matched the prefix is
  # what CMD_MSG says this gate does not assume.
  if [[ "${word}" == */git ]]; then
    words[idx]=git
    raw_words[idx]=git
  elif [[ "${word}" == */shellcheck ]]; then
    words[idx]=shellcheck
    raw_words[idx]=shellcheck
  fi
  # A builtin that moves the directory every relative path in the rest of the
  # string is resolved against. `path_inside_worktree` resolves one against
  # this checkout, so `cd /home/dev && git diff -- .bashrc .profile` counted
  # two inside operands and git printed two home-directory files, and
  # `cd /home/dev && shellcheck .bashrc` printed one back through the source
  # line it echoes. Marked here, where a name position is known -- `echo cd`
  # moves nothing -- and read by the two scans below.
  case "${word}" in
  cd | pushd | popd) moves_dir[idx]=1 ;;
  *) ;;
  esac
  command_names[idx]=1
  # The command xargs runs, when it is not a wrapper, keyword or assignment
  # (each of which went on above): the words after it are its arguments.
  ((idx == xargs_command_idx)) && after_wrapper=0
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
#
# Defined here rather than beside the operand scan that was its first caller:
# the redirection scan below reaches it too, and a bash function has to exist
# before the line that calls it runs.
# Also outside, and for the same reason: a string that has moved the working
# directory before the command runs. This resolves a relative path against the
# directory the hook runs in, which is the checkout, so `cd /home/dev && git
# diff -- .bashrc .profile` and `cd /home/dev && shellcheck .bashrc` presented
# operands that looked local and were not, and git printed two home-directory
# files while shellcheck echoed one back. Where the path lands is undecidable
# once the directory moves, and this function's contract is that undecidable
# counts as outside. `worktree_moved` is the latch the scans below set when
# they reach the `cd`; `env -C` is refused outright above, since there the
# wrapper is already known.
path_inside_worktree() {
  local candidate toplevel
  ((worktree_moved)) && return 1
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

# Whether this redirection hands shellcheck a file it would print back. Only a
# bare `<` opens a path for reading -- the descriptor in `0<f` is dropped by
# the split above, so the operator arrives as `<` either way. `<<` reads a
# here-document and `<<<` a here-string, whose word is content rather than a
# path and cannot name a file without a substitution, which is refused before
# this runs; `<&` duplicates a descriptor and `<>` is decided by
# `redirection_writes_a_path`. `/dev/null` is exempt: there is nothing to
# print back, and `</dev/null` is how a session says "no stdin".
#
# The target is judged on both spellings, as an operand is: the word as typed
# for the rewrites bash performs before shellcheck opens anything, and the
# quote-stripped word for where the path lands.
redirection_reads_a_denied_path() {
  local op="$1" word="$2" raw="$3"
  [[ "${op}" == '<' ]] || return 1
  [[ "${word}" == '/dev/null' ]] && return 1
  brace_would_expand "${raw}" && return 0
  word_bash_would_rewrite "${raw}" && return 0
  path_inside_worktree "${word}" || return 0
  denied_read_shape "${word}"
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
  # Both spellings of the assignment. `+=` is not a narrower case of `=`:
  # appending to an unset variable creates it, so `SHELLCHECK_OPTS+=./.env`
  # sets it exactly as `SHELLCHECK_OPTS=./.env` does. It reached the linter
  # past both rules that look at it -- this one matched the `=` spelling only,
  # and the leading-assignment rule below stands aside for this variable so
  # that the refusal naming what shellcheck reads out of it is the one shown
  # (issue #222; the same spelling was atomic-image-builder#425).
  [[ "${words[idx]}" == SHELLCHECK_OPTS=* || "${words[idx]}" == SHELLCHECK_OPTS+=* ]] &&
    refuse "${SHELLCHECK_OPTS_MSG}"
  raw_word="${raw_words[idx]}"
  if ((raw_in_git)); then
    if brace_would_expand "${raw_word}" ||
      [[ "${raw_word}" == '<(' || "${raw_word}" == '>(' ]]; then
      refuse "${EXPAND_MSG}"
    fi
    if [[ "${kinds[idx]}" == word && "${raw_word}" == '~'* ]]; then
      refuse "${TILDE_MSG}"
    fi
    # The third rewrite, after the brace and the tilde: an unquoted glob is
    # expanded into however many files match, so one word here is any number
    # of operands at git. `git diff /etc/passwd*` matched two files and git
    # printed the diff between them, with a single operand written and no
    # flag anywhere -- the plain-file read this gate exists for, reached past
    # an operand count of one. `git diff .env*` is the same read of two
    # untracked files inside the checkout. The tilde is checked first because
    # `word_bash_would_rewrite` covers it too and TILDE_MSG names the home
    # directory; what is left here is the glob.
    if [[ "${kinds[idx]}" == word ]] && word_bash_would_rewrite "${raw_word}"; then
      refuse "${GIT_GLOB_MSG}"
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
# And `-n` stops bash running the script, not reading it out (issue #233).
# `bash -n -v ./cosign.key` printed the key: `-v` prints every line bash
# reads, and nothing about `-n` stops it. So the options that print or copy
# what bash reads are refused in a `bash -n` invocation, read the way bash
# reads its own, and the script it opens -- an operand, or its stdin when
# none is named -- is held to the shellcheck operand test. The option scan
# at the end of the loop below says which options and why.
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

# Whether the words so far can still grow into one of the prefixes above:
# `bash` can (`bash -n`), `-p` cannot. After a wrapper such as `command`
# every following word may be the name, and the wrapper's own options come
# first (`command -p bash -n +n -c ...`, review on arch-bootc#322), so a
# prefix that can no longer match is dropped when the next candidate name
# arrives rather than kept as a name that was never one.
prefix_could_match() {
  local joined="$1" rule
  for rule in "${GATED_PREFIXES[@]}"; do
    [[ "${rule}" == "${joined} "* ]] && return 0
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
  # xargs in front of the command: the words it reads from stdin or from `-a
  # FILE` are operands no scan here reads, and the allow rule matches `xargs
  # git diff` as it matches `git diff`. Git counts, whichever subcommand.
  ((cmd_xargs && (cmd_gated || cmd_git))) && refuse "${XARGS_MSG}"
  ((cmd_gated && cmd_writes)) && refuse "${GATED_REDIRECT_MSG}"
  # podman's --cpu-profile/--memory-profile are the same write by an option
  # rather than a redirection: persistent globals podman takes after the
  # subcommand too, so `podman images --cpu-profile cosign.pub` matches the
  # `podman ps`/`images`/`inspect` allow row on its prefix and dumps a profile
  # over the path, truncating it even when the run then fails.
  ((cmd_gated && cmd_podman_profile == 1)) && refuse "${PODMAN_PROFILE_MSG}"
  # A word bash rewrites could become either option after this scan has read
  # it: a brace (`--cpu-pro{f..f}ile`) with no precondition, a glob
  # (`--cpu-profil*`) once a file of that name exists.
  ((cmd_gated && cmd_podman_profile == 2)) && refuse "${PODMAN_EXPAND_MSG}"
  # A shellcheck invocation has its own scan for this, with the message that
  # names the operand; that one is left to say it.
  ((cmd_gated && cmd_subst)) && { [[ "${cmd_prefix}" != shellcheck* ]] || ((cmd_subst == 2)); } && refuse "${GATED_SUBST_MSG}"
  ((cmd_gated && cmd_heredoc)) && refuse "${GATED_HEREDOC_MSG}"
  # A `SHELLCHECK_OPTS=` assignment has a refusal of its own, which names what
  # the linter reads out of it; that one is left to say it.
  ((cmd_gated && cmd_assign)) && [[ "${cmd_prefix}" != shellcheck* || "${cmd_assign_name}" != SHELLCHECK_OPTS ]] && refuse "${GATED_ENV_MSG}"
  # Git is held to the same rule. It was exempt until issue #218, on the
  # reading that a git invocation is decided by the operand scan above; that
  # scan reads words, and an assignment is not one. Git's environment carries
  # both primitives this gate refuses elsewhere: `GIT_EXTERNAL_DIFF=prog git
  # diff HEAD~1` runs `prog` once per changed path, `GIT_CONFIG_COUNT=1
  # GIT_CONFIG_KEY_0=diff.external GIT_CONFIG_VALUE_0=prog` reaches the same
  # driver under another name, and `PATH=dir git diff HEAD~1` picks a
  # different git altogether -- each of them an unprompted string the allow
  # rows match on their `git diff` prefix.
  ((cmd_git && cmd_assign)) && refuse "${GATED_ENV_MSG}"
  # Scoped to shellcheck and bash -n rather than to every gated prefix, and
  # decided here rather than at the redirection, because bash lets the
  # redirection precede the command name -- `< .env shellcheck -` is the same
  # command as `shellcheck - < .env`, and the name is not known until the
  # command ends. bash -n reads its script from stdin when no file is named
  # and prints the line a syntax error stands on, so `bash -n - < .env` is
  # `bash -n .env` by another route (issue #233). The other gated commands
  # print their own output rather than what they are fed, so a file on their
  # stdin is not read back out.
  ((cmd_gated && cmd_reads)) && [[ "${cmd_prefix}" == shellcheck* ]] && refuse "${SHELLCHECK_READ_MSG}"
  ((cmd_gated && cmd_reads && cmd_bash)) && refuse "${BASH_READ_MSG}"
  # Git's half of the same read: under --stdin, log, show and diff take
  # revisions from standard input and name the first line that is not one in
  # their error, so `git log --stdin <.env` prints that line back (issue #239).
  # Decided on `cmd_git`, which is set only where the name stands, so
  # `grep git <notes.txt` is not read as a git invocation.
  ((cmd_git && cmd_reads)) && refuse "${GIT_STDIN_MSG}"
  return 0
}

reset_command() {
  cmd_prefix=''
  cmd_writes=0
  cmd_reads=0
  cmd_subst=0
  cmd_heredoc=0
  cmd_assign=0
  cmd_assign_name=''
  cmd_bash=0
  cmd_named=0
  cmd_gated=0
  cmd_git=0
  cmd_podman_profile=0
  cmd_export=0
  cmd_export_idx=-1
  cmd_xargs=0
  bash_options=0
  bash_optvals=''
  cmd_argv0=0
}

# The words of a command from its *name* onward: a leading assignment
# (`FOO=bar shellcheck ...`) is not part of the prefix an allow rule matches,
# and neither is a redirection's target, which is the shell's word rather
# than the command's. `command_names` above marks the name, and every word
# after it belongs to the same command until a separator.
cmd_prefix='' # the words so far, space-joined, while a prefix is still possible
cmd_writes=0  # a redirection in this command opens a path for writing
cmd_reads=0   # a bare `<` in it feeds shellcheck, bash -n or git a file it would print back
cmd_subst=0   # a substitution stands in this command, or in a target of it
cmd_heredoc=0 # this command reads a here-document bash expands
cmd_assign=0  # an assignment stands before this command's name
cmd_assign_name='' # the variable that assignment sets
cmd_bash=0    # its name is bash, so the +n and expansion rules apply once gated
cmd_named=0   # the name has been seen; every later word belongs to it
cmd_gated=0   # its leading words matched one of GATED_PREFIXES
cmd_git=0     # its name is git, which the allow rows cover with their own `*`
cmd_podman_profile=0 # a --cpu-profile/--memory-profile option stands in this podman command
cmd_export=0  # 1: its name is export/declare/typeset/readonly, whose own words
              # assign; 2: it is `set`, whose -a arms every later assignment
cmd_export_idx=-1 # the word that named it, so the name is not read as its own
cmd_xargs=0   # an `xargs` stood in a name position before the name was gated
bash_options=0 # a gated bash is still reading option words, as bash itself does
bash_optvals='' # one letter per -o/-O still waiting for its value, in order
cmd_argv0=0   # an exec/env option before the name set bash's zeroth argument
cmd_stack=()  # the outer command's state, while a `$(...)` is being read
export_idx=-1 # the first word at which an export-family command arms a variable
gate_idx=-1   # the last word at which a gated command or git is running
reset_command
# Each scan sets this latch as it reaches the `cd` rather than reading a value
# left by the scan before it, so a `cd` written *after* the command it cannot
# reach is not held against it: `shellcheck f; cd /home/dev` is f's own lint.
# `cd`'s effect on this scan is scoped to the subshell or substitution it
# runs in, the way bash itself scopes it: `(cd /etc); shellcheck
# tests/run-tests.sh` moves nothing bash would call the working directory
# once the `)` closes, because a `(...)` subshell's cd cannot reach the
# shell around it, and a `$(...)` or backtick command substitution is the
# same kind of subshell. Read before this latch existed, `worktree_moved`
# had no notion of a boundary at all, so a `cd` inside either one stayed
# set for the rest of the string and refused an unrelated later command
# that runs from the checkout, exactly as it was typed. `worktree_stack`
# saves the value at each `(` and `$(` and restores it at the matching
# `)`/`$)`, alongside the command state `cmd_stack` already saves there.
worktree_moved=0
worktree_stack=()
# A backtick substitution is a subshell too, and its own `cd` cannot reach
# the shell around it either, but bash spells its open and close with the
# same character -- there is no `` `) `` token the way there is a `$)` --
# so the push/pop above cannot key on the word alone. This toggles: the
# first backtick of a pair pushes, the second pops, the way `in_backtick`
# already does for the name scan above.
worktree_in_backtick=0
for ((idx = 0; idx < ${#words[@]}; idx++)); do
  ((${moves_dir[idx]:-0})) && worktree_moved=1
  case "${kinds[idx]}" in
  sep)
    # shellcheck disable=SC2016 # the literal `$(` is the separator's name
    if [[ "${words[idx]}" == '$(' || "${words[idx]}" == '(' ]]; then
      worktree_stack+=("${worktree_moved}")
    elif [[ "${words[idx]}" == '$)' || "${words[idx]}" == ')' ]] && ((${#worktree_stack[@]})); then
      worktree_moved="${worktree_stack[-1]}"
      unset 'worktree_stack[-1]'
    elif [[ "${words[idx]}" == '`' ]]; then
      if ((worktree_in_backtick)); then
        worktree_in_backtick=0
        if ((${#worktree_stack[@]})); then
          worktree_moved="${worktree_stack[-1]}"
          unset 'worktree_stack[-1]'
        fi
      else
        worktree_in_backtick=1
        worktree_stack+=("${worktree_moved}")
      fi
    fi
    # A `$(...)` or a backtick inside a gated command runs the command
    # inside it as part of the approved string, with no rule on that inner
    # command (`df -T $(touch cosign.pub)`, review on arch-bootc#322), the
    # way a process substitution does; a gated bash invocation says so in
    # its own words, since there the substitution also rebuilds `+n`.
    # shellcheck disable=SC2016 # the literal `$(` is the separator's name
    if ((cmd_gated)) && [[ "${words[idx]}" == '$(' || "${words[idx]}" == *'`'* ]]; then
      ((cmd_bash)) && refuse "${BASH_EXPAND_MSG}"
      # A shellcheck invocation has its own scan for this, whose message
      # names the operand; that one is left to say it.
      [[ "${cmd_prefix}" == shellcheck* ]] || refuse "${GATED_SUBST_MSG}"
    fi
    # A `$(...)` substitution is a nested command: it is decided on its own,
    # and the command around it -- including a redirection of its own already
    # seen -- resumes at the `)` rather than starting over, so
    # `shellcheck $(git ls-files '*.sh') >cosign.pub` is still that command's
    # write.
    # A process substitution's body is split as a command of its own behind
    # a `(` separator; the command around it is saved there and restored at
    # the `)`, like a `$(...)`, so `>(cat >cosign.pub) df -T` still reaches
    # its name with the substitution remembered.
    # shellcheck disable=SC2016 # the literal `$(` is the separator's name
    if [[ "${words[idx]}" == '$(' ]] ||
      { [[ "${words[idx]}" == '(' ]] && ((idx > 0)) && [[ "${kinds[idx - 1]}" != sep ]] &&
        [[ "${words[idx - 1]}" == '<(' || "${words[idx - 1]}" == '>(' ]]; }; then
      cmd_stack+=("${cmd_writes} ${cmd_reads} ${cmd_subst} ${cmd_heredoc} ${cmd_assign} ${cmd_bash} ${cmd_named} ${cmd_gated} ${cmd_git} ${cmd_export} ${cmd_export_idx} ${cmd_xargs} ${cmd_prefix}")
      reset_command
      continue
    fi
    if [[ "${words[idx]}" == '$)' || "${words[idx]}" == ')' ]] && ((${#cmd_stack[@]})); then
      check_gated_command
      read -r cmd_writes cmd_reads cmd_subst cmd_heredoc cmd_assign cmd_bash cmd_named cmd_gated cmd_git cmd_export cmd_export_idx cmd_xargs cmd_prefix <<<"${cmd_stack[-1]}"
      unset 'cmd_stack[-1]'
      # The command that resumes here contains a substitution, whether or
      # not its name has been seen yet (`$(touch cosign.pub) df -T`).
      ((cmd_subst)) || cmd_subst=1
      continue
    fi
    check_gated_command
    reset_command
    continue
    ;;
  target)
    redirection_writes_a_path "${redirects[idx]}" "${words[idx]}" && cmd_writes=1
    # ShellCheck reads standard input when its operand is `-` and prints the
    # source line above every diagnostic, so `shellcheck - < .env` printed the
    # file back exactly as `shellcheck ./.env` did while the operand scan --
    # which skips a redirection's target -- saw nothing (#212). Recorded for
    # the command rather than refused here, because the redirection may be
    # written before the name.
    redirection_reads_a_denied_path "${redirects[idx]}" "${words[idx]}" "${raw_words[idx]}" && cmd_reads=1
    # `df -T < <(printf x >cosign.pub)`: the substitution is a target, and
    # its body still runs (review on arch-bootc#322). So does one quoted
    # into the target of an input redirection or a here-string
    # (`gh pr list <"$(printf x >cosign.pub)"`, review on
    # aurora-zfs-simple#211): bash expands the target before the command.
    # (Recorded as 2: a shellcheck invocation's own scan covers its operand
    # words, never its targets, so the exemption below does not apply.)
    [[ "${words[idx]}" == '<(' || "${words[idx]}" == '>(' ]] && cmd_subst=2
    [[ "${raw_words[idx]}" == *'$'* || "${raw_words[idx]}" == *'`'* ]] && cmd_subst=2
    # A here-document with an unquoted delimiter is expanded before the
    # command runs, and its body lies on the lines after this one, which
    # the scan reads as commands of their own: `df -T <<EOF` followed by a
    # `$(printf x >cosign.pub)` line writes the file (review on
    # arch-bootc#322). One with a quoted delimiter (`<<'EOF'`) is literal.
    if [[ "${redirects[idx]}" == '<<' && "${raw_words[idx]}" != *[\'\"\\]* ]]; then
      cmd_heredoc=1
    fi
    continue
    ;;
  *) ;;
  esac
  # A `<(` or `>(` is the substitution's opening, not a word of the prefix:
  # it is remembered for the command and its body follows behind a `(`.
  if [[ "${words[idx]}" == '<(' || "${words[idx]}" == '>(' ]]; then
    cmd_subst=1
    continue
  fi
  # An assignment before the name is an environment the command runs under,
  # and for these commands that is a way in: `PYTEST_ADDOPTS`, `PYTHONPATH`,
  # `GH_HOST`, `LD_PRELOAD` each change what the command does or where it
  # sends what it has (review on sensi#244). A git invocation is refused it
  # too (issue #218): `GIT_EXTERNAL_DIFF` names a program git runs per changed
  # path, and the operand scan above reads words, which an assignment is not.
  # The quote-stripped spelling as well as the word as typed, because `env`
  # parses its own arguments after bash has removed the quotes: `env
  # 'GIT_EXTERNAL_DIFF'=prog git diff HEAD~1` sets the variable and the
  # as-typed word begins with a quote mark rather than with a name. The name
  # captured for `cmd_assign_name` is the stripped one for the same reason --
  # `'SHELLCHECK_OPTS'=./.env` is that variable.
  if ((${name_assignments[idx]:-0})) &&
    { [[ "${words[idx]}" =~ ^([A-Za-z_][A-Za-z0-9_]*)(\[[^]]*\])?\+?= ]] ||
      [[ "${raw_words[idx]}" =~ ^([A-Za-z_][A-Za-z0-9_]*)(\[[^]]*\])?\+?= ]]; }; then
    cmd_assign=1
    cmd_assign_name="${BASH_REMATCH[1]}"
    continue
  fi
  # An `xargs` the command-name scan found where a name may stand runs the
  # command after it with words this string does not contain, so it is kept
  # until the command's name is known and `check_gated_command` decides it.
  # One after a gated name is that command's argument (`timeout 5 podman ps
  # xargs`), and is not.
  ((${xargs_names[idx]:-0})) && ((cmd_gated == 0 && cmd_git == 0)) && cmd_xargs=1
  # An exec or env option that sets the zeroth argument, before the name: a
  # dash there makes bash a login shell (see `argv0_words` above).
  ((${argv0_words[idx]:-0})) && ((cmd_gated == 0)) && cmd_argv0=1
  ((cmd_named)) || ((${command_names[idx]:-0})) || continue
  cmd_named=1
  if ((cmd_gated == 0)); then
    # The words so far cannot grow into a gated prefix and this word may
    # still be the name (a wrapper's option came first): start over here.
    if [[ -n "${cmd_prefix}" ]] && ((cmd_git == 0)) && ((${command_names[idx]:-0})) && ! prefix_could_match "${cmd_prefix}"; then
      cmd_prefix=''
      cmd_bash=0
    fi
    # The name, decided here rather than at the first word of the command,
    # because a wrapper's own option comes first and is a name candidate of
    # its own (`env -u X git diff`). The command-name scan above rewrote a
    # path spelling (`/usr/bin/git`) to `git`, so this one test covers both.
    # Once it is git the restart above stops: after a wrapper every later
    # word is a name candidate too, and `git`, `diff` and `HEAD` each took
    # their turn as the name until the invocation no longer looked like git's
    # (issue #218). No gated prefix begins with git, so nothing is missed.
    [[ -z "${cmd_prefix}" && "${words[idx]}" == "git" ]] && cmd_git=1
    [[ -z "${cmd_prefix}" && "${words[idx]}" == "bash" ]] && cmd_bash=1
    # The export family. Its assignments stand *after* the name rather than
    # before it, so the scan that records a leading `NAME=value` never sees
    # them, and bash applies them to every later command of the string.
    # `set` is the same arming with no name in it: `set -a` (allexport) makes
    # bash export every assignment it performs from there on, so a plain
    # `GIT_EXTERNAL_DIFF=prog` -- a command of its own, which the
    # leading-assignment scan reads and lets through -- lands in the
    # environment of the git invocation after it.
    if [[ -z "${cmd_prefix}" ]]; then
      case "${words[idx]}" in
      export | declare | typeset | readonly)
        cmd_export=1
        cmd_export_idx=${idx}
        ;;
      set)
        cmd_export=2
        cmd_export_idx=${idx}
        ;;
      *) ;;
      esac
    fi
    cmd_prefix="${cmd_prefix:+${cmd_prefix} }${words[idx]}"
    command_is_gated "${cmd_prefix}" && cmd_gated=1
    # `bash -nv ./cosign.key` is `bash -n -v` to bash. Claude Code's
    # documented matcher keeps the space after `-n` in the allow row, so that
    # spelling prompts today; it is gated here anyway, so this gate does not
    # rest on where the matcher draws a word boundary. A first option word
    # that begins `-n` completes the prefix, and the option scan at the end
    # of this loop reads the rest of it; the refusal blocks a spelling a
    # syntax check never needs.
    ((cmd_bash)) && [[ "${cmd_prefix}" == 'bash -n'?* ]] && cmd_gated=1
    ((cmd_bash && cmd_gated)) && bash_options=1
    ((cmd_bash && cmd_gated && cmd_argv0)) && refuse "${BASH_ECHO_MSG}"
  fi
  # The last word position at which this string runs something the gate
  # covers. Compared against the first exported assignment below, so that an
  # export written *after* the command it cannot reach is left alone.
  ((cmd_gated || cmd_git)) && gate_idx=${idx}
  # podman's profile-writing globals, checked at each word rather than at the
  # prefix because they stand after the subcommand `podman ps`/`images`/
  # `inspect` the allow row matches (`podman images --cpu-profile cosign.pub`).
  # `cmd_prefix` holds only the matched prefix, so the flag word is read here.
  if ((cmd_gated)) && [[ "${cmd_prefix}" == podman\ * ]]; then
    case "${words[idx]}" in
    --cpu-profile | --cpu-profile=* | --memory-profile | --memory-profile=*)
      cmd_podman_profile=1
      ;;
    *) ;;
    esac
    # The literal comparison reads the word as typed; a word bash rebuilds
    # before podman runs can turn into either option afterwards.
    if ((cmd_podman_profile == 0)) && { brace_would_expand "${raw_words[idx]}" ||
      word_bash_would_rewrite "${raw_words[idx]}"; }; then
      cmd_podman_profile=2
    fi
  fi
  # A substitution or an expansion quoted into a word (`df -T "$(printf x
  # >cosign.pub)"`, `podman images $X`) is one the split above never opened,
  # and bash performs it all the same (review on arch-bootc#322).
  if ((cmd_gated)) && [[ "${raw_words[idx]}" == *'$'* || "${raw_words[idx]}" == *'`'* ]]; then
    ((cmd_subst)) || cmd_subst=1
  fi
  # A word of an export-family command that arms a variable for a later one.
  # `export FOO=1` and `declare -x FOO=1` put FOO in the environment of every
  # command bash runs after them in this string, which is the same reach as
  # `FOO=1 cmd` by a spelling the leading-assignment scan is not looking at
  # (issue #218). So does a *bare name*: `export GIT_EXTERNAL_DIFF;
  # GIT_EXTERNAL_DIFF=prog; git diff HEAD~1` exports the variable in one
  # command and assigns to it in the next -- a command with an assignment and
  # no name, which the leading-assignment scan records for a command that
  # never comes and then drops at the separator -- and git ran prog once per
  # changed path. Reading the option list instead is the road EXPORT_ENV_MSG
  # declines to take, so any word that is not an option arms it, which leaves
  # `export`, `export -p` and `declare -p` alone and over-refuses `export -n
  # FOO`. A `set` word carrying an `a` is `set -a` or `set -o allexport`,
  # whose arming has no name at all.
  if ((export_idx < 0)) && ((idx > cmd_export_idx)); then
    if ((cmd_export == 1)) && [[ "${words[idx]}" != -* ]]; then
      export_idx=${idx}
    elif ((cmd_export == 2)) &&
      [[ "${words[idx]}" == -[!-]* && "${words[idx]}" == *a* ||
      "${words[idx]}" == allexport ]]; then
      export_idx=${idx}
    fi
  fi
  ((cmd_bash && cmd_gated)) || continue
  [[ "${words[idx]}" == '+'* ]] && refuse "${BASH_NOEXEC_MSG}"
  # A glob is the third rebuild: with a file named `+n` in the working
  # directory, `?n` and `[+]n` reach bash as `+n` (review on
  # aurora-zfs-simple#211), so the rewrite test the shellcheck operands are
  # held to applies here as well.
  if brace_would_expand "${raw_words[idx]}" || [[ "${raw_words[idx]}" == *'$'* ]] ||
    word_bash_would_rewrite "${raw_words[idx]}"; then
    refuse "${BASH_EXPAND_MSG}"
  fi
  # What the inner bash reads and prints, decided the way bash reads its own
  # command line (issue #233). `-n` stops bash running the script, not
  # printing it: `-v` (`-o verbose`) prints every line bash reads, `-D`
  # every `$"..."` string in it, `-o history` and `-i` copy every line into
  # ~/.bash_history when bash exits, and `-i` and `-l` read ~/.bashrc and
  # the login profiles, whose syntax errors print a line of them. `-x` (`-o
  # xtrace`) prints what bash runs, which under `-n` is nothing; it goes with
  # the rest because a syntax check has no use for it. Every other option
  # letter, `-o` name and `-O` name was run under `-n` (bash 5.3) against a
  # script holding a marker, and put none of it in the output or in HOME.
  #
  # bash's own parser (shell.c, parse_shell_options) takes a word beginning
  # with `-` as options until the first word that does not, or a lone `-` or
  # `--`, which it consumes. Each letter of such a word is an option of its
  # own, so `-nv` is `-n -v`, and each `o` or `O` among them takes the next
  # unread word as its value, in order, so `-no verbose` and `-oo noexec
  # verbose` both turn verbose on. A `--word` there is not a long option --
  # bash reads those only before the first short one, and the allow row puts
  # `-n` first -- so bash rejects it and exits; one carrying a refused letter
  # (`--verbose`) is refused here all the same. The first word that is not an
  # option, and every word after it, is the script (or the `-c` string) and
  # its arguments, held to the shellcheck operand test: bash prints the line
  # a syntax error stands on, so `bash -n .env` printed a `NAME=value` line
  # whose value held a `(`.
  if [[ -n "${bash_optvals}" ]]; then
    if [[ "${bash_optvals:0:1}" == o ]]; then
      case "${words[idx]}" in
      verbose | xtrace | history) refuse "${BASH_ECHO_MSG}" ;;
      *) ;;
      esac
    fi
    bash_optvals="${bash_optvals:1}"
  elif ((bash_options)) && [[ "${words[idx]}" == - || "${words[idx]}" == -- ]]; then
    bash_options=0
  elif ((bash_options)) && [[ "${words[idx]}" == -* ]]; then
    [[ "${words[idx]}" == -*[vxilD]* ]] && refuse "${BASH_ECHO_MSG}"
    bash_optvals+="${words[idx]//[!oO]/}"
  else
    bash_options=0
    ((worktree_moved)) && refuse "${MOVED_MSG}"
    if ! path_inside_worktree "${words[idx]}" || denied_read_shape "${words[idx]}"; then
      refuse "${BASH_READ_MSG}"
    fi
  fi
done
check_gated_command
# Decided once, over the whole string: the export may be written before the
# command it arms, and only then does it reach it.
((export_idx >= 0 && gate_idx > export_idx)) && refuse "${EXPORT_ENV_MSG}"

# The whole string with quoting removed, for the one test that is a substring
# match rather than a word: the shell removes quotes and backslashes on the
# way to git, so `--no-'index'` and `--no-\index` both reach it as
# `--no-index`.
normalized="${command_string//[\'\"\\]/}"

case "${normalized}" in
*--no-index*) refuse "${DIFF_MSG}" ;;
*) ;;
esac

seen_git=0
in_git=0
in_diff=0
operands=0
unresolved=0
after_dashdash=0
skip_git_option_value=0
in_shellcheck=0
skip_shellcheck_option_value=0
diff_relocated=0 # a git global option has moved this invocation's own paths
# `cd`'s effect here is scoped the way bash itself scopes it: a `(...)`
# subshell's or a `$(...)`/backtick substitution's own `cd` cannot reach
# the shell around it, so `worktree_stack` saves `worktree_moved` at each
# `(`/`$(` and restores it at the matching `)`/`$)`, the way MOVED_MSG's
# doc comment on path_inside_worktree() already promises for "the scans
# below" (review on aurora-zfs-simple#223).
worktree_moved=0
worktree_stack=()
worktree_in_backtick=0

for ((idx = 0; idx < ${#words[@]}; idx++)); do
  word="${words[idx]}"
  kind="${kinds[idx]}"
  ((${moves_dir[idx]:-0})) && worktree_moved=1
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
    # shellcheck disable=SC2016 # the literal `$(` is the separator's name
    if [[ "${words[idx]}" == '$(' || "${words[idx]}" == '(' ]]; then
      worktree_stack+=("${worktree_moved}")
    elif [[ "${words[idx]}" == '$)' || "${words[idx]}" == ')' ]] && ((${#worktree_stack[@]})); then
      worktree_moved="${worktree_stack[-1]}"
      unset 'worktree_stack[-1]'
    elif [[ "${words[idx]}" == '`' ]]; then
      if ((worktree_in_backtick)); then
        worktree_in_backtick=0
        if ((${#worktree_stack[@]})); then
          worktree_moved="${worktree_stack[-1]}"
          unset 'worktree_stack[-1]'
        fi
      else
        worktree_in_backtick=1
        worktree_stack+=("${worktree_moved}")
      fi
    fi
    seen_git=0
    in_diff=0
    skip_git_option_value=0
    # A git global option belongs to the invocation it was written in, not to
    # a later one: `git -C sub status; git diff a b` is two commands.
    diff_relocated=0
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
    # A moved working directory makes every operand undecidable rather than
    # outside, and the message that names the `cd` is the one to act on.
    ((worktree_moved)) && refuse "${MOVED_MSG}"
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
      { ((diff_relocated)) || ! path_inside_worktree "${word}"; } && unresolved=1
      if ((operands >= 2 && unresolved)); then
        ((diff_relocated || worktree_moved)) && refuse "${MOVED_MSG}"
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
    # `rev-parse` runs in this checkout, which is the repository git was
    # pointed away from, so its answer is about the wrong revisions once a
    # relocating option has been seen.
    { ((diff_relocated)) ||
      ! git rev-parse --verify --quiet "${word}^{commit}" >/dev/null 2>&1; } && unresolved=1
    if ((operands >= 2 && unresolved)); then
      ((diff_relocated || worktree_moved)) && refuse "${MOVED_MSG}"
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
    # The third primitive, beside the read and the write: a git-level option
    # that hands git a setting or a program to load. `git -c
    # diff.external=prog diff HEAD~1` runs prog once per changed path, and
    # `git --config-env=diff.external=VAR diff HEAD~1` reaches the same driver
    # with the value held in a variable -- both verified against a real
    # program in a throwaway repository. That is the code execution the
    # leading `GIT_EXTERNAL_DIFF=prog` spelling is refused for, written as an
    # option instead of as an environment, and `-c` was on the skip list below
    # so its value went by as a word the scan stepped over.
    #
    # Refused here, in the words between `git` and its subcommand, rather than
    # in the `in_git` latch that `--output` uses: `-c` is only the config
    # option in this position -- after a subcommand it is git's combined-diff
    # flag (`git show -c`) -- and a latch that held to the end of the string
    # would refuse the `-c` of `bash -c` in a later command of it.
    # `--exec-path`, `--upload-pack` and `--receive-pack` name a program
    # outright; no allow-listed subcommand reaches the last two today, and
    # they are refused with the family rather than left for the rule that adds
    # one.
    -c | --config-env | --config-env=* | --exec-path | --exec-path=* | \
      --upload-pack | --upload-pack=* | --receive-pack | --receive-pack=*)
      refuse "${GIT_CONFIG_MSG}"
      ;;
    # The options that move the paths this invocation opens. They do not move
    # the shell's directory, so they are kept apart from `worktree_moved`.
    # git loads config from the repository it is pointed at before it reads
    # a single operand: `diff.external` there runs once per changed path
    # whether the invocation names zero, one or two of them, the same
    # program the leading `GIT_EXTERNAL_DIFF=` and `-c diff.external=`
    # spellings are refused for. Waiting for the two-operand plain-file
    # mode to also decide this left `git -C /tmp/evil diff HEAD~1` --  one
    # operand, which cannot reach that mode -- to load and run that
    # program from a repository this gate never looked at. So the whole
    # invocation is refused as soon as `diff` is reached, not only once its
    # operands turn out unresolved; `path_inside_worktree` and the
    # two-operand test below still run for a plain relocation-free
    # `git diff` that later turns out unresolved some other way.
    -C | --git-dir | --work-tree | --namespace | --super-prefix | --attr-source)
      diff_relocated=1
      skip_git_option_value=1
      continue
      ;;
    --git-dir=* | --work-tree=* | --namespace=* | --super-prefix=* | --attr-source=*)
      diff_relocated=1
      continue
      ;;
    *) ;;
    esac
    # git-level options such as --no-pager sit between `git` and the subcommand.
    [[ "${word}" == -* ]] && continue
    if [[ "${word}" == "diff" ]]; then
      ((diff_relocated)) && refuse "${MOVED_MSG}"
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
