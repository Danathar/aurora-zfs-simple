# Prose an agent is told to trust needs a test

**2026-09-03** — documentation, tooling

## What happened

`README.md` advertised a Renovate config at `.github/renovate.json5`. The file
was `renovate.json`, at the repo root, and had been for a long time
([#70](https://github.com/Danathar/aurora-zfs-simple/issues/70)).

On its own that is a typo. What made it a defect is the structure around it:
[`AGENTS.md`](../../AGENTS.md) tells an agent handling a broken build to trust
`README.md`. So the wrong path was not decoration — it was an input to incident
response, handed to a reader who by construction does not know the tree well
enough to notice.

> **Correction, 2026-09-15:** The relationship above was recorded backwards.
> `AGENTS.md` has never pointed to `README.md`; `README.md` is the entry document
> and directs readers with a failed build to `AGENTS.md`. The drift and the need
> for the test remain real. See
> [#170](https://github.com/Danathar/aurora-zfs-simple/issues/170).

Every other claim in that document had exactly the same standing, and nothing
checked any of them.

## What changed

`tests/test-docs-paths.sh`. It reads the `Repository Layout` block in
`README.md` line by line, then the inline code spans in `README.md` and
`AGENTS.md`, and asserts that anything naming a real repo path exists. The
filter is anchored on `git ls-files`, so `org/repo` references and prose in
backticks are skipped while anything rooted in a real top-level entry is
enforced.

`.github/workflows/coverage-gate.yml` landed alongside it for a related reason:
`build.yml` sets `paths-ignore` for `README.md` and `docs/**`, so a docs-only
pull request started no run at all — the shell suite did not execute on exactly
the changes most likely to introduce doc drift. The coverage gate triggers on
the complement of that ignore list.

## What to carry forward

- **Docs consumed by automation are code.** The moment a document is named as a
  source of truth for an agent, its claims need the same treatment as an
  assertion: something has to fail when they stop being true.
- **Check the gap in the trigger, not just the check.** The suite that would
  have caught this existed. It did not run on the changes that needed it,
  because the path filter that keeps CI cheap also removed the only verification
  from doc changes. A gate's trigger is part of the gate.
- **"It's just a docs change" is a claim about blast radius, and here it is
  often wrong.** [`docs/risk-tiers.md`](../risk-tiers.md) puts load-bearing
  prose above self-checking test code for this reason.

The narrow lesson is the test. The broad one: when you add a `paths-ignore` to
save CI minutes, write down what stops being verified.
