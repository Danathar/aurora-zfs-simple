# Agent tasks

How to trace a change in this repository back to the agent task that produced
it, and dated ledgers of what that trace found.

Most pull requests here are opened by coding agents working from an issue. Each
one leaves marks, and together they answer "which task made this change, and
which agent made it". None of the marks is created by anything in this tree:
they are written by the agents and the orchestration around them, so this page
describes what history shows, not a rule the repository enforces. The first
ledger below is the evidence for each statement here.

For how an agent is expected to behave here, read
[`.github/copilot-instructions.md`](../../.github/copilot-instructions.md),
[`CONTRIBUTING.md`](../../CONTRIBUTING.md) and
[`docs/SECURITY-AI.md`](../SECURITY-AI.md). For what a change is allowed to
touch, read [`docs/risk-tiers.md`](../risk-tiers.md). This directory is a
record, not a brief.

## The marks

**The pull request signature.** An agent-written pull request body carries a
line beginning `— hive:` that names the backend, the model, the effort, and for
the Hive agents the role (`agent=quality`, `agent=sec-check`, and so on). It is
the only mark that appears on every agent pull request opened since
2026-09-03, and it is the one to count by.

```bash
gh pr view <n> --repo Danathar/aurora-zfs-simple --json body --jq '.body | capture("— hive: (?<sig>.*)").sig'
```

Not every signature names a role. The ones written from a maintainer-driven
agent session carry `backend=` and usually `model=`, and nothing else; for
those the branch name and the issue are the only other trace.

**The author is not the key.** The pull request author tells you which account
pushed, not which agent worked. Some agent pull requests are opened under the
maintainer's own login, so counting `app/danathar-atomic-hive` undercounts
agent work. The reverse also happens: a few pull requests opened by that app
account never carried the line, only an older `Filed by <role> agent` footer or
nothing. Another agent, GitHub
Copilot, opens pull requests as `app/copilot-swe-agent` with no signature at
all. The ledger counts each case.

```bash
gh pr view <n> --repo Danathar/aurora-zfs-simple --json author,body --jq '{author: .author.login, signed: (.body | test("— hive:"))}'
```

**The branch name.** The Hive agents push to `<role>/<slug>`: `quality/`,
`sec/`, `arch/` or `architect/`, `guide/`, `scanner/`, `strategy/`. The prefix
is a hint about the kind of work and is not an identity: a maintainer-driven
agent session pushes to `fix/`, `docs/` or `test/`, which a person also uses,
and the prefix does not always match the signature's `agent=`.

```bash
gh pr view <n> --repo Danathar/aurora-zfs-simple --json headRefName --jq '.headRefName'
git log --merges --grep='^Merge pull request #<n> ' --format='%s'
```

The second command reads the same name from `main`'s own history: the merge
commit's subject carries the pull request number and the branch, and survives
the branch being deleted.

**The issue.** A `Closes #<n>` line in the body is what the contributing guide
already asks of everyone. GitHub reads it into the pull request's closing
references, and into the commit message when the same line is in the commit.

```bash
gh pr view <n> --repo Danathar/aurora-zfs-simple --json closingIssuesReferences --jq '[.closingIssuesReferences[].number]'
git log --no-merges -i -E --grep='^(closes|fixes|resolves) #<issue>' --format='%h %s'
```

**The commit trailers.** A commit made in an agent session driven by a
maintainer carries `Hive-Run: Danathar/aurora-zfs-simple#<issue>` naming the
issue the run was for, and sometimes `Hive-Plan:` and `Hive-Spec:` beside it.
The first commit on `main` with the trailer is from 2026-09-28. They survive
a rebase where the branch name does not, and `git log` reads them without the
GitHub API. Commits made by the Hive agents on their own do not carry them.

```bash
git log --no-merges --grep='^Hive-Run: ' --format='%h %cs %(trailers:key=Hive-Run,valueonly)' | grep .
git log --no-merges --grep='^Hive-Run: Danathar/aurora-zfs-simple#<issue>$' --format='%h %s'
```

**The commit author.** Some commits are authored under a role identity:
`quality@hive.kubestellar.io`, `architect@hive.kubestellar.io`,
`strategist@hive.kubestellar.io`, `sec-check@users.noreply.github.com`, the
earlier `hive-bot@kubestellar.io`, and the GitHub app
`danathar-atomic-hive[bot]`. Most agent commits are not, because an agent that
commits through the maintainer's git configuration commits as the maintainer.
An agent author on a commit proves the agent made it; a maintainer author
proves nothing either way.

```bash
git log --no-merges --format='%ae' | grep -E '@hive\.kubestellar\.io$|^hive-bot@kubestellar\.io$|danathar-atomic-hive\[bot\]|^sec-check@' | sed -E 's/^[0-9]+\+//' | sort | uniq -c
```

## Reading one change end to end

Take a pull request number, then:

1. `gh pr view <n> --repo Danathar/aurora-zfs-simple --json body,closingIssuesReferences` gives the signature and the issue.
2. `git log --merges --grep='^Merge pull request #<n> ' --format='%h %P %s'` gives the merge and its two parents.
3. `git log --no-merges --format='%h %ae %s' <first parent>..<second parent>` gives the commits it merged, with their author identities and any trailers.

A change that carries a signature and an issue is traced. One without a
closing reference is not necessarily untraced, because some bodies name the
issue without a closing keyword, but the ledger lists them so a reader can
look.

## What the ledgers hold

Each dated file below is one reading of those marks over a pinned range of
pull requests and a pinned `main`, with the exact command under every table so
it reproduces, and it is left as it was read. A ledger does not describe
current state, so it does not go stale; for the current picture, run the
commands above.

This is the same shape as [`docs/metrics/`](../metrics/), for the same reason.
Whether the agents' work is any good is a quality question and lives in
[`docs/metrics.md`](../metrics.md); this directory records who did what and for
which issue.

## Ledgers

- [2026-10-03](2026-10-03.md): pull requests up to #311, `main` at `0ba3fac`
