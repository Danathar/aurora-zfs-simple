# Strategy

Where this project is trying to get to, and the commands that say whether it is
on the way. Open it before deciding what to work on next, or before pointing an
agent at something.

Like [`docs/metrics.md`](metrics.md), this page quotes no numbers. Each answer is
one command against data the repository already keeps, so the page cannot go out
of date: run the command for today's answer. Every command names
`Danathar/aurora-zfs-simple`, because this repository is a fork and a bare `gh`
in a clone can read the parent's issues and runs instead. The goal is written
once, in the README, and this page reads it rather than copying it.

## The goal

There is no roadmap file here, and this page does not invent one. The goal is
what the README already commits to, in three places:

- **About.** The README opens with what the image is for: ZFS on Aurora, built
  from upstream Universal Blue akmods, for people who already understand ZFS and
  kernel-module matching. Upstream Aurora is dropping ZFS, so this repository is
  one of the places those users are being pointed to.
- **[Project Continuity & Trust](../README.md#project-continuity--trust).** The
  repository answers the question of why anyone should depend on a
  single-maintainer image ([#304](https://github.com/Danathar/aurora-zfs-simple/issues/304)
  asked it). It says what is promised: the published `:latest` image keeps being
  refreshed, and the **last good build** badge is the signal a user is told to
  watch. If that badge stops advancing, the README tells them to leave.
- **[Maintained with Hive (ACMM L6)](../README.md#maintained-with-hive-acmm-l6).**
  Agents propose work. Their pull requests merge once checks pass, except
  outreach pull requests and paths that always need a human, which wait for a
  human's approval.

So "on track" has two halves: the image keeps being built and refreshed, and the
work that gets merged is about that, with the decisions only a person can make
not left waiting. The commands below read both.

## Is the image being built?

**Scheduled builds.** Each one is a refresh of the image, and the weekly
schedule means a lost build is a week of missed Aurora and security updates. This
counts the consecutive scheduled runs, newest first, that did not succeed. A run
still in progress has no conclusion yet and is left out. `0` is healthy. A value
equal to `--limit` means "at least that many".

```bash
gh run list --repo Danathar/aurora-zfs-simple --workflow build.yml --event schedule --limit 20 \
  --json conclusion -q '[.[] | select(.conclusion != "") | .conclusion] | (index("success") // length)'
```

**Upstream kernel/ZFS skew.** The state behind the README's **OpenZFS/kernel**
badge, read from the file the badge renders. It says `in sync` when the two
akmods images the `Containerfile` pulls agree on a kernel, and `blocked` when
they do not, which is the usual cause of a red build here. The badge is
refreshed daily by `status-badges.yml`.

```bash
gh api "repos/Danathar/aurora-zfs-simple/contents/akmods-badge.json?ref=status" \
  --jq '.content | gsub("\n"; "") | @base64d | fromjson | .message'
```

Read the two together. Lost builds while this says `blocked` are upstream skew,
and nothing in this repository fixes them; the response is the pin-or-wait
decision in [`AGENTS.md`](../AGENTS.md#dominant-failure-mode-kernel--zfs-akmod-skew).
Lost builds while it says `in sync` are the ones worth investigating. How old
the published image is, and what a pass rate does and does not mean, is in
[metrics.md](metrics.md#build-health).

## Is the work going there?

**What is waiting on a human.** Issues an agent stopped on because the next step
is a person's decision carry `needs-human`. Outreach pull requests the agents
open carry `hold`, which keeps them from merging until a maintainer reviews
them. Nothing under either moves until a person acts. These are only read here:
the page never recommends applying either label.

```bash
gh issue list --repo Danathar/aurora-zfs-simple --label needs-human --state open --limit 1000
gh pr list --repo Danathar/aurora-zfs-simple --label hold --state open --limit 1000
```

**What has merged since a date**, grouped by the first part of the branch name.
Pick `<date>` as `YYYY-MM-DD`, for example the day of the last review of this
page. The prefix is the nearest thing to "what kind of work" the history records,
and no list of prefixes is defined anywhere in the repository, so read the
output rather than a list. Dependabot's `dependabot` is dependency upkeep, not
direction.

```bash
gh pr list --repo Danathar/aurora-zfs-simple --state merged --limit 1000 \
  --search "merged:>=<date>" --json headRefName \
  --jq 'map(.headRefName | split("/")[0]) | group_by(.) | map({prefix: .[0], count: length})'
```

The question to ask of that output is whether the work is about the goal above:
the build, the ZFS and kernel matching, the signing and the continuity promises.
A long run of merges that is all about the repository's own process, with the
builds above unhealthy or the waiting list growing, is the pattern to notice.

## Why there is no report job

The ACMM L6 check looks for a scheduled `strategy-report` workflow as one way to
satisfy "strategic dashboard". This page is commands instead, for the reason
[metrics.md](metrics.md) gives for having no collector: a scheduled job adds a
moving part, here a workflow with a token that has to be scoped and kept in
[`.github/policies/`](../.github/policies/workflow-permissions.json), whose output
nobody reads weekly on a repository with one maintainer. The two signals that
matter most already have a dashboard that refreshes without one: the README's
badges. Everything else is a question asked when a decision is about to be made,
and a command answers it fresh.
