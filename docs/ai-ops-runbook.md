# AI operations runbook

What to do when something automated here goes red or looks wrong: a workflow, a
badge, an agent run, a refusal from the gate hook, or an agent's pull request or
issue. Each entry says what the signal means, the first thing to do, and which
page has the detail.

The other pages say what a signal is, not what to do about it.
[quality.md](quality.md) says what each badge and gate is worth.
[AGENTS.md](../AGENTS.md) diagnoses a failed build. [risk-tiers.md](risk-tiers.md)
and [SECURITY-AI.md](SECURITY-AI.md) say what an agent may touch. This page
points at them rather than restating them. It holds no claim about the current
state of the repository: anything that changes on its own is a command to run,
not a sentence to trust.

Re-running, cancelling or dispatching a workflow, and commenting on or closing
anything, are the maintainer's calls. An agent reading this page takes a step
that does one only when it has been told to.

## Start here

```bash
gh run list --repo Danathar/aurora-zfs-simple --branch main -L 10
gh run list --repo Danathar/aurora-zfs-simple --workflow nightly-compliance.yml -L 7
gh run list --repo Danathar/aurora-zfs-simple --workflow status-badges.yml -L 7
gh pr list --repo Danathar/aurora-zfs-simple --state open --label hold
gh issue list --repo Danathar/aurora-zfs-simple --state open --label ai-fix-requested
```

Read the README badges first: **build**, **last good build** and
**OpenZFS/kernel** together tell you whether red means upstream moved or this
repository broke ([quality.md](quality.md#the-badges)). A run that should be in
those lists and is not is a signal too. See
[A scheduled run is missing](#a-scheduled-run-is-missing).

## `main` is red

Two pull requests that each passed alone can fail together, and a scheduled
build runs on `main` with no pull request at all. Find which job is red, then:

| Red job                                           | Means                                                                                                                                      | First thing                                                                                                                                                                                                                                   |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Shell tests`                                     | This repository broke, or the runner's shellcheck changed under it.                                                                        | Run the failing test locally with `./tests/run-tests.sh <name>`, with shellcheck installed.                                                                                                                                                   |
| `Build and push image`                            | Upstream skew when the OpenZFS/kernel badge says `blocked`; else a break here.                                                             | Read the badge before the log, then follow [AGENTS.md](../AGENTS.md#dominant-failure-mode-kernel--zfs-akmod-skew).                                                                                                                            |
| A step after `Build Image`                        | Rechunk or registry login failed, so nothing was pushed. If the red step is `Push To GHCR` or later, read the next row instead.            | Match the step against [Other failure modes](../AGENTS.md#other-failure-modes).                                                                                                                                                               |
| A step after `Login to GitHub Container Registry` | The push or a step after it failed. The push may already have moved `:latest`, so it may name an unsigned image and the date tags may lag. | Treat the published image as suspect: run the `cosign verify` in [the README](../README.md#signature-verification), then dispatch `nightly-compliance.yml` (see [A scheduled run is missing](#a-scheduled-run-is-missing)) for the tag check. |

`Shell tests` is the only check the ruleset requires, and it comes from
`build.yml` or `coverage-gate.yml` depending on what a change touched
([branch-protection.md](branch-protection.md#the-ruleset)). `Build and push
image` is not required, so a pull request can merge with it red. A red `Shell
tests` on `main` makes the same check on every open pull request mean nothing
until it is fixed, so fix it before reviewing anything else, in a pull request of
its own, and say which two merges collided.

## Each workflow

One row per file in `.github/workflows/`. The detail column is where the
explanation lives; the first thing to do is what to try before reading a log.

| Workflow                 | Red or odd means                                                                                                                                     | First thing                                                                                       | Detail                                                                                  |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| `agent-audit.yml`        | An agent pull request merged since the enforcement date lacks its `— hive:` line or a sign-off; or the window hit the cap, or `since` was malformed. | Read the run summary: it names each pull request and commit. Merged history is not rewritten.     | [SECURITY-AI.md](SECURITY-AI.md#reading-the-record-back)                                |
| `ai-fix.yml`             | A maintainer-requested agent run failed, or stopped at `preflight`.                                                                                  | Read the run summary: [An `ai-fix.yml` run did nothing](#an-ai-fixyml-run-did-nothing-or-failed). | [SECURITY-AI.md](SECURITY-AI.md#agent-authored-pull-requests)                           |
| `auto-issues.yml`        | The failure issue was not opened or commented on. The failure it was reporting still happened.                                                       | Open the watched workflow's latest run yourself.                                                  | [SECURITY-AI.md](SECURITY-AI.md#failure-issues-hold-issues-write)                       |
| `auto-qa.yml`            | A job was killed at its timeout, or its slowest run is close to it.                                                                                  | Open the run summary table for the job and its slowest run.                                       | [quality.md](quality.md#the-gates), `.github/auto-qa-tuning.json`                       |
| `build.yml`              | See [`main` is red](#main-is-red).                                                                                                                   | Check the OpenZFS/kernel badge.                                                                   | [AGENTS.md](../AGENTS.md), [quality.md](quality.md#reading-a-red-build)                 |
| `coverage-gate.yml`      | The shell suite failed on a change `build.yml` ignores, or on a workflow edit.                                                                       | Run the failing test locally.                                                                     | [risk-tiers.md](risk-tiers.md#evidence-by-tier)                                         |
| `labeler.yml`            | The `area/*` labelling failed. It classifies a change and checks nothing.                                                                            | Re-run it; do not apply a label by hand.                                                          | [SECURITY-AI.md](SECURITY-AI.md#labels-carry-authority--automation-must-not-apply-them) |
| `nightly-compliance.yml` | The shell suite or the published image's signature or tags failed.                                                                                   | Compare the failing commit with the last green night.                                             | [Nightly compliance failed](#nightly-compliance-failed)                                 |
| `status-badges.yml`      | The badge files on the `status` branch were not refreshed.                                                                                           | Check whether the badge moved: it keeps its last value when an input cannot be read.              | [quality.md](quality.md#the-badges)                                                     |

An issue titled `Unattended run failed: <workflow>` comes from `auto-issues.yml`
when the image build on `main` (scheduled or after a push) or the nightly check
fails. Its body names the run and the first step to take; while it is open,
later failures add comments to it. Close it by hand once the cause is fixed.

## Nightly compliance failed

The job checks properties of the published image that are only true after the
push, and can stop being true later. Its own header says a red run means the
world changed, not that someone pushed, so compare commits first:

```bash
gh run list --repo Danathar/aurora-zfs-simple --workflow nightly-compliance.yml -L 7 --json headSha,conclusion,createdAt
```

The same commit as a green night means the cause is outside the repository. A
new commit means treat it as [`main` is red](#main-is-red). Then read which step
failed:

| Step                                         | Failing on an unchanged commit means                                                                                                         |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Run shell test suite                         | The runner changed under the suite, most often its shellcheck version.                                                                       |
| Resolve the published :latest                | `:latest` cannot be read (`could not be inspected` in the log): it was deleted or repointed, or the registry or credentials are not working. |
| Verify the published signature               | The image no longer verifies against `cosign.pub`.                                                                                           |
| Verify the date tags still share that digest | A date tag was repointed or removed after the push.                                                                                          |

A run that finds no image published at all passes with a note; every other
failure to read the image is fatal on purpose. What the job does not cover, the
contents of the image after the rechunk, is in
[quality.md](quality.md#what-each-one-does-not-cover). Signing keys and who may
touch them are in [SECURITY-AI.md](SECURITY-AI.md#signing-keys-and-secrets).

## A scheduled run is missing

A dropped scheduled run produces no failure, so nothing tells you. These
workflows run on a schedule; the list is checked against the files.

- `build.yml`
- `status-badges.yml`
- `nightly-compliance.yml`
- `auto-qa.yml`
- `agent-audit.yml`

1. Read the `cron:` line in the workflow and compare it with the dates the run
   list shows:

   ```bash
   gh run list --repo Danathar/aurora-zfs-simple --workflow nightly-compliance.yml --event schedule -L 7
   ```

2. GitHub delays or drops scheduled runs under load, and disables a public
   repository's scheduled workflows after 60 days with no repository activity.
   Open the workflow in the **Actions** tab: a disabled one says so and offers
   **Enable workflow**.
3. To get a reading now, dispatch it: `gh workflow run nightly-compliance.yml
   --repo Danathar/aurora-zfs-simple`.

A badge that has not moved is not proof its workflow is running, and a stale
**last good build** is the signal [README.md](../README.md) tells a reader to
watch.

## A badge looks wrong

- **build is red, last good build is recent, OpenZFS/kernel says `blocked`.**
  Expected during upstream skew; the published image still works.
  [AGENTS.md](../AGENTS.md#60-second-diagnosis) confirms it.
- **build is red and OpenZFS/kernel is not blocked.** Something here broke. Go
  to [`main` is red](#main-is-red).
- **A badge has not changed.** `status-badges.yml` leaves a badge at its last
  value rather than guess. Check its run, then the `status` branch.
  [quality.md](quality.md#the-badges) has the reasoning.

## An `ai-fix.yml` run did nothing, or failed

A run that stops at `preflight` succeeds and says why in its summary. These are
not failures:

- `Skipped: no agent credentials are configured on this repository.` The
  workflow is inert without a repository secret by design. Decide whether you
  want it on; nothing is broken.
- `which is a bot` in the summary. A bot, including the one that opens ACMM
  issues and applies `ai-fix-requested`, cannot start an agent. A maintainer
  relays a request with a `@claude` comment.
- `comes from a fork.` The job's token cannot push to a fork. Pull the branch
  and run the agent yourself.

A red `fix` job is the agent failing partway. Open the log, check whether it
pushed an `ai-fix/*` branch, and treat anything it opened as an agent pull
request ([below](#an-agent-pull-request-looks-wrong)). Why the workflow holds
`contents: write` and what bounds that grant is in
[SECURITY-AI.md](SECURITY-AI.md#agent-authored-pull-requests) and
[branch-protection.md](branch-protection.md#why-it-matters-here).

## A gate hook refused a command

`.claude/hooks/gate-git-diff.sh` runs before an agent's Bash commands, exits 2
and prints a `blocked:` message on stderr when it refuses. The message names
the spelling it refused and what to do instead. The refusal is the answer: do
not retry the command in another spelling, because the other spellings are what
the hook exists to catch.

If a rule blocks work that is genuinely needed, change the hook in a reviewed
pull request. It is Tier 3 in [risk-tiers.md](risk-tiers.md#the-tiers). The
list of what it refuses, and why each is there, is in
[SECURITY-AI.md](SECURITY-AI.md#what-an-agent-may-do-unattended), and
`tests/test-gate-refusal-docs.sh` runs each example on that list through the
hook.

## An agent pull request looks wrong

Every agent pull request is held for a person and nothing merges on its own
([README.md](../README.md#maintained-with-hive-acmm-l5)), so leaving it
unmerged is always safe. Comment with what is wrong, or close it.

- **Read what it says about itself.** An agent pull request states that an
  agent wrote it and what evidence exists
  ([SECURITY-AI.md](SECURITY-AI.md#agent-authored-pull-requests)). A body with
  no evidence is a reason to send it back.
- **Classify it.** It takes the highest tier of any path it touches
  ([risk-tiers.md](risk-tiers.md#the-tiers)); the evidence it needs follows
  from that ([evidence by tier](risk-tiers.md#evidence-by-tier)).
- **Read the review bot's comments.** They are inline, so
  `gh pr view <N> --comments --repo Danathar/aurora-zfs-simple` does not show them; the commands are in
  [AGENTS.md](../AGENTS.md#pull-request-review).
- **Check it against the rubric.** [review-rubric.md](review-rubric.md) says
  what a review here should ask.
- **Do not apply a label to move it along.** Several ordinary-looking labels
  are read by an outside system as approval to auto-merge
  ([SECURITY-AI.md](SECURITY-AI.md#labels-carry-authority--automation-must-not-apply-them)).

## An issue asks for work that is already done

Issues filed by the ACMM evaluation test whether a named file exists, not
whether the capability does, so one can ask for a file when the repository
already has the capability under another name, or when an open pull request is
already adding it.

1. Search `main` for the capability, not only the filename:
   `git grep -il '<topic>'`, and read the issue's own list of accepted paths.
2. Search open and merged pull requests:
   `gh pr list --repo Danathar/aurora-zfs-simple --state all --search '<topic>'`.
3. If it exists, say where in a comment and close the issue; if only the
   filename is missing, write a page worth having that points at what exists.
   An empty file that only satisfies the check is not one.

## Everything else

- **Which agents run, or pausing one,** is configured in Hive, outside this
  repository. [README.md](../README.md#maintained-with-hive-acmm-l5) links to it.
- **What a number is worth,** as opposed to what to do about it, is in
  [quality.md](quality.md) and [metrics.md](metrics.md).
- **Before a Fedora major-release bump,** the checks to run first are in
  [manual-input-check.md](manual-input-check.md).
- **Something touches a secret or a signing key.** Stop and read
  [SECURITY-AI.md](SECURITY-AI.md#signing-keys-and-secrets) before doing
  anything else.
