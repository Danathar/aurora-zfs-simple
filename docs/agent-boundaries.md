# Agent boundaries

Which limits on an AI agent working here are enforced by a tool, and which are
only asked of it.

Most of what this repository tells an agent is a request: one concern per pull
request, never push to `main`, never apply an approval label. A **structural
gate** is different. It is a setting, a check or a refusal that stops the
action whatever the agent decides, so a mistaken or misled agent is stopped
rather than trusted.

This page lists the gates, says what each one stops, and links the page that
explains it. It restates none of them; the linked page is the reference. What
an agent is *allowed* to do is [`SECURITY-AI.md`](SECURITY-AI.md). How much
review a change needs is [`risk-tiers.md`](risk-tiers.md).

## The gates

| Gate | What it stops | Holds for | Explained in |
| --- | --- | --- | --- |
| [`.github/rulesets/main.json`](../.github/rulesets/main.json) | Any change reaching `main` except as a pull request merge. Deleting or rewriting `main`. It has no bypass actors. | every agent and every person | [branch-protection.md](branch-protection.md#the-ruleset) |
| The required `Shell tests` check, in [`build.yml`](../.github/workflows/build.yml) and [`coverage-gate.yml`](../.github/workflows/coverage-gate.yml) | Merging a pull request whose shell suite fails. Many tests read the documents, so a page that drifts from the files it describes fails here too. In `build.yml`, `build_push` needs it, so a red suite also publishes nothing. | every agent and every person | [quality.md](quality.md#the-gates) |
| [`.github/policies/workflow-permissions.json`](../.github/policies/workflow-permissions.json) | A workflow's `GITHUB_TOKEN` gaining a scope the policy file does not grant. `tests/test-workflow-permissions.sh` fails, inside `Shell tests`, until the same pull request changes both files. | every agent and every person | [SECURITY-AI.md](SECURITY-AI.md#what-this-policy-does-not-cover) |
| The `preflight` job in [`ai-fix.yml`](../.github/workflows/ai-fix.yml) | An agent started by a bot, for a fork's pull request, or with no credentials set. The `fix` job it starts has no `packages: write` and no `SIGNING_SECRET`. | the agent `ai-fix.yml` starts | [SECURITY-AI.md](SECURITY-AI.md#agent-authored-pull-requests) |
| [`.claude/settings.json`](../.claude/settings.json) | Reading `cosign.key`, `.env` or `.env.*`. `cosign sign`, `git push --force` and `git push -f`, and the `podman` and `buildah` prune and remove-all commands. It asks before `git push`, `gh api`, `gh workflow run`, `podman build`, `podman run` and `podman rmi`. | Claude Code sessions only | [SECURITY-AI.md](SECURITY-AI.md#what-an-agent-may-do-unattended) |
| [`.claude/hooks/gate-git-diff.sh`](../.claude/hooks/gate-git-diff.sh) | An allow-listed command, such as `git diff`, `shellcheck` or `gh pr view --jq`, spelled so it reads a file the deny rules protect, writes over a file, runs a program, or prints the environment. | Claude Code sessions only | [SECURITY-AI.md](SECURITY-AI.md#what-an-agent-may-do-unattended) |
| [`tests/run-tests.sh`](../tests/run-tests.sh) | The one test command that runs with no prompt running anything but a `test-*.sh` file in `tests/`. | Claude Code sessions only | [`.claude/settings.json`](../.claude/settings.json), its `_note_run_tests` key |

"Claude Code sessions only" matters. The settings file and its hook are Claude
Code's format, and an agent on another backend does not read them. The runner
is a gate only because the settings file allows it with no prompt. The gates
that hold for every agent are the ones on GitHub's side, as
[`multi-agent.md`](multi-agent.md#what-every-agent-shares) says.

## What is asked, not enforced

These are real rules, and nothing mechanical stops an agent breaking them.
Review is what catches it.

- **A person merges.** The ruleset needs no approval, because a sole maintainer
  cannot approve their own pull request. So a token that can write contents
  could merge a green pull request through the API. `gh pr merge` is not on the
  settings file's allow list, so a Claude Code session is asked first; it is
  not denied. [`multi-agent.md`](multi-agent.md#who-merges) says who merges.
- **No approval labels from automation.** Some labels here are read as approval
  to merge. Nothing denies adding one.
  [`SECURITY-AI.md`](SECURITY-AI.md#labels-carry-authority--automation-must-not-apply-them)
  has the list.
- **Evidence in proportion to reach.** [`risk-tiers.md`](risk-tiers.md) says a
  Tier 3 change needs a human and stated evidence. The `area/*` labels describe
  a change; they do not block a merge.
- **No publishing from a pull request.** The `if:` conditions on the
  publishing steps of [`build.yml`](../.github/workflows/build.yml) stop a pull
  request's build from pushing or signing an image, and `build.yml` runs on a
  push to `main` only, so pushing an `ai-fix/*` branch starts no build. They are
  not a gate, though: for a pull request from a branch of this repository,
  GitHub runs the pull request's own copy of `build.yml`, with
  `packages: write` and the repository's secrets. A pull request that edits the
  conditions away could publish before anyone merges it. Review of every change
  to `build.yml` is what catches that.
- **The signature line and the sign-off.** Nothing in the ruleset requires
  either. [`agent-audit.yml`](../.github/workflows/agent-audit.yml) reads them
  back once a month and fails its own run on a miss, after the merge.
  [`SECURITY-AI.md`](SECURITY-AI.md#reading-the-record-back) says what it checks.
- **Changes that need a conversation first**, such as pinning the akmods inputs
  or moving `FEDORA_VERSION`.
  [`CONTRIBUTING.md`](../CONTRIBUTING.md#changes-that-need-a-conversation-first)
  lists them.

## Why there is no CODEOWNERS file

A `CODEOWNERS` file is the usual way to put a gate on part of a repository, and
here it would gate nothing. The ruleset sets `require_code_owner_review` to
`false` and needs no approval, for the reason above. A `CODEOWNERS` file would
only ask the one maintainer to review every pull request, which is already what
happens.

When there is a second reviewer,
[`branch-protection.md`](branch-protection.md#when-there-is-a-second-reviewer)
is where the ruleset changes. Code-owner review belongs in the same change,
with a `CODEOWNERS` file naming the Tier 3 paths.
