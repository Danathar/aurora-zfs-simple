# Multi-agent work

Several AI agents work on this repository at the same time, each with one job:
one writes tests, one looks for bugs, one looks for security problems, one
fixes the issues the others file, and so on. They are scheduled and run by
[Hive](https://github.com/hivecommons/hive), outside this repository; the Hive
instance for this repository is `hive-wild-mole`, the name in the
`hive/hive-wild-mole` label. This page is the repository's side of that
arrangement: who the agents are, how work reaches each one, what keeps two of
them from undoing each other, and who decides what lands.

Nothing here tells an agent how the code works. That is
[`.github/copilot-instructions.md`](../.github/copilot-instructions.md) and
[`AGENTS.md`](../AGENTS.md). Like the other pages under `docs/`, this one holds
no current-state counts: anything that changes on its own is a command, under
[What is in flight right now](#what-is-in-flight-right-now).

## Who works here

An agent signs the pull requests it writes with a `— hive:` line, and that line
is the only reliable key to the role. Branch prefixes and commit identities
follow the role but are not unique to it: the table is what the merged pull
requests showed when it was written, and the commands that regenerate it are
in the next section.

| Role        | Signature          | Branch prefixes          | Commit identity seen                                                          | What it does                                                                      |
| ----------- | ------------------ | ------------------------ | ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| quality     | `agent=quality`    | `quality/`, `test/`      | `quality@hive.kubestellar.io`                                                 | Finds behaviour no test pins, files it, and adds the test.                        |
| scanner     | `agent=scanner`    | `scanner/`               | `danathar-atomic-hive[bot]`, or `Danathar` with a `claude` co-author          | Finds bugs, files them, and fixes some.                                           |
| security    | `agent=sec-check`  | `sec/`                   | `sec-check@users.noreply.github.com`, or `Danathar` with a `claude` co-author | Finds security problems, files them, and fixes some.                              |
| architect   | `agent=architect`  | `arch/`, `architect/`    | `architect@hive.kubestellar.io`                                               | Proposes RFCs and structural refactors.                                           |
| strategist  | `agent=strategist` | `strategy/`              | `strategist@hive.kubestellar.io`                                              | Keeps the roadmap and coordinates the other agents.                               |
| guide       | `agent=guide`      | `guide/`                 | `Danathar` with a `claude` co-author                                          | Documents behaviour that exists but is not written down.                          |
| contributor | no `agent=` field  | `fix/`, `docs/`, `feat/` | `Danathar`                                                                    | Works one issue end to end, with a `Hive-Run:` trailer naming the issue.          |
| reviewer    | none, opens none   | none                     | none                                                                          | Comments on open pull requests with file:line evidence. Never merges or approves. |

Three more kinds of author appear that are not part of the Hive fleet:
`dependabot/` and `renovate/` branches (dependency bumps, configured in
[`.github/dependabot.yml`](../.github/dependabot.yml) and
[`renovate.json`](../renovate.json)) and `copilot/` or `codex/` branches from
the code-review and coding assistants GitHub offers. The Hive pull requests are
opened by the `danathar-atomic-hive` GitHub App, so the PR author is the app
even when the commits inside carry a role's identity or `Danathar`.

An issue an agent files starts with its role in brackets, such as `[quality]`,
and carries an `agent/<role>` provenance label, so the issue list answers "who
found this" the way the branch answers "who changed this".

### Reading it back

```bash
# Who opened what: branch prefix, PR author, and the signature line
gh pr list --repo Danathar/aurora-zfs-simple --state merged --limit 60 \
  --json number,headRefName,author,body \
  --jq '.[] | "#\(.number) \(.headRefName) \(.author.login) \(.body | split("\n") | map(select(startswith("— hive"))) | join(""))"'

# Which commit identities have written to the repository
git log --format='%an <%ae>' | sort | uniq -c | sort -rn

# Commits made for a specific issue by a contributor agent
git log --format='%h %(trailers:key=Hive-Run,valueonly,separator=)' | awk 'NF == 2'
```

## How work reaches an agent

There is no dispatcher in this repository. Hive decides which agent runs when
and on what; the repository only shapes what an agent finds when it gets
there.

1. An issue is opened: by a person, by one of the finding agents above, by
   Hive's maturity evaluation, whose issues are titled `[ACMM Lx]` and carry the
   `acmm` and `ai-fix-requested` labels, or by
   [`.github/workflows/auto-issues.yml`](../.github/workflows/auto-issues.yml)
   when an unattended build or nightly check fails. That workflow applies no
   label and starts no agent.
2. The `ai-fix-requested` label is the repository's own hand-off.
   [`.github/workflows/ai-fix.yml`](../.github/workflows/ai-fix.yml) runs on
   `issues` `labeled` and on `issue_comment` `created` (`@claude`), and starts
   Claude Code to open a pull request from an `ai-fix/` branch. As
   [`docs/SECURITY-AI.md`](SECURITY-AI.md) records, it starts nothing while no
   agent credentials are set on this repository, and every run then stops at
   its `preflight` job. A bot cannot trigger it either, and
   `danathar-atomic-hive[bot]` is the one that applies the label to ACMM
   issues, so those are picked up by Hive instead.
3. The issue is worked on a branch of its own and arrives as one pull request.
   The README's [*Maintained with
   Hive*](../README.md#maintained-with-hive-acmm-l5) section says every pull
   request an agent opens gets a `hold` label.

Issue labels that say the issue is already taken, which an agent reads before
starting:

- `hive/covered-by-pr`: Hive verified that an open pull request references or
  claims the issue.
- `hive/likely-done`: a merged pull request does, pending a person's check.
- `needs-human`: it waits on a maintainer's decision.

`hive-pause/hive-wild-mole` is the dashboard's own switch: agents do not act on
an item that carries it until an operator removes it. Do not add any of these
by hand to steer an agent; [`docs/SECURITY-AI.md`](SECURITY-AI.md#labels-carry-authority--automation-must-not-apply-them)
explains why labels here carry authority.

## Staying out of each other's way

Two agents can be working at once on files that one test joins together.
There is no lock. Three things keep that from going wrong.

**One issue, one branch, one pull request.** The `Hive-Run:` trailer and the
`Closes #N` line tie a pull request to the issue it answers, and
`hive/covered-by-pr` tells the next agent to leave that issue alone. Check what
is open before starting:

```bash
gh pr list --repo Danathar/aurora-zfs-simple --state open --search "<issue> in:body"
gh pr list --repo Danathar/aurora-zfs-simple --state open --json number,headRefName,files \
  --jq '.[] | select(any(.files[]; .path == "<path>")) | "#\(.number) \(.headRefName)"'
```

**Say which files the pull request owns.** Naming the files and tests a change
touches in the pull request body lets the next agent see an overlap without
reading the diff. Nothing enforces it.

**Expect two green pull requests to be red together.** The `main` ruleset
requires `Shell tests`, but `strict_required_status_checks_policy` is `false`
in [`.github/rulesets/main.json`](../.github/rulesets/main.json): a pull
request does not have to be tested against the latest `main` before it merges.
Two pull requests that each pass can therefore land one after the other and
leave `main` red, for instance one that adds a workflow and one that adds a
test counting the workflows. When two open pull requests touch the same
document, or a document and the test that reads it, update the second from
`main` before it merges so that `Shell tests` runs on the pair.

## Who merges

A person. The README's *Maintained with Hive* section states the policy:
nothing an agent opens lands without a maintainer's approval, and held pull
requests are reviewed in batches. An agent never merges its own pull request,
and the reviewer never merges, approves or closes one. The `hold` label is how
that shows on a pull request.

The ruleset does not ask for an approval. `required_approving_review_count` is
`0`, because GitHub does not let anyone approve their own pull request and
this is a single-maintainer repository ([`docs/branch-protection.md`](branch-protection.md)
has the reasoning), and `bypass_actors` lists `0` actors, so nothing skips the
`Shell tests` check. What the ruleset does enforce is that every change is a
pull request and someone presses merge. The merge itself is recorded as
`Danathar`, and agent backends also commit as that login, so the merged-by
field cannot show whether a person or an agent pressed the button.
The policy above is the guarantee, not that field:

```bash
gh pr list --repo Danathar/aurora-zfs-simple --state merged --limit 60 \
  --json mergedBy --jq '[.[].mergedBy.login] | group_by(.) | map({login: .[0], merged: length})'
```

## What every agent shares

Every agent, whatever model or backend it runs on, is sent to the same
documents:

- [`.github/copilot-instructions.md`](../.github/copilot-instructions.md): the
  checks and the traps.
- [`AGENTS.md`](../AGENTS.md): build-failure diagnosis and upstream tracing.
- [`CONTRIBUTING.md`](../CONTRIBUTING.md): what a change needs and what CI
  cannot prove.
- [`docs/risk-tiers.md`](risk-tiers.md): how much evidence a change to each
  path needs.
- [`docs/SECURITY-AI.md`](SECURITY-AI.md): what an agent must never do.

[`.claude/settings.json`](../.claude/settings.json) and its hook bind a Claude
Code session. A backend that does not read them is held by the layers on
GitHub's side instead: the ruleset, the `Shell tests` check, and a person's
merge.

## What this repository does not run

No workflow here orchestrates agents. There is no dispatcher, no orchestrator
directory, no workflow that calls another with `gh workflow run` or
`repository_dispatch`, and no schedule that starts a model. The one workflow
that can start an agent at all is [`.github/workflows/ai-fix.yml`](../.github/workflows/ai-fix.yml),
and it starts one only when a person with write access labels an issue or says
`@claude`, only when a credential is set, and only into a pull request that
still needs a person to merge it.

That limit is deliberate. The header of `.github/workflows/ai-fix.yml` and
[`docs/SECURITY-AI.md`](SECURITY-AI.md) say why: this repository publishes a
signed image, a job holding `contents: write` is a real escalation path if a
bot can trigger it, and so the workflow runs from the default branch's copy and
refuses bot senders. Choosing which agent works on what, and when, would need a
scheduler holding that same kind of access on a timer, and the repository keeps
that outside itself. The orchestration stays in Hive; this repository keeps
its side in issues, labels, branches and the checks above.

## What is in flight right now

```bash
gh pr list --repo Danathar/aurora-zfs-simple --state open --json number,headRefName,labels \
  --jq '.[] | "#\(.number) \(.headRefName) \([.labels[].name] | join(","))"'
gh issue list --repo Danathar/aurora-zfs-simple --state open --label hive/covered-by-pr
gh issue list --repo Danathar/aurora-zfs-simple --state open --label needs-human
```

The first lists open pull requests by branch, so the prefix says which agent
owns each. The other two list the issues an agent has marked as already being
handled and the ones that wait on a person.
