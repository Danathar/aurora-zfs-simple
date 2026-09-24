# Branch protection

`main` is what the Sunday build signs and publishes. This file says what
protects it, why each rule is there, and how to check that GitHub is really
enforcing it.

## Status

As of 2026-09-24, `main` has no branch protection and no ruleset. Check it
yourself; neither call needs admin rights:

```bash
gh api repos/Danathar/aurora-zfs-simple/branches/main --jq .protected
gh api repos/Danathar/aurora-zfs-simple/rulesets
```

`false` and `[]` mean unprotected. Once the ruleset below is applied, the first
prints `true` and the second lists `protect main`.

## Why it matters here

Every other gate in this repository sits behind a pull request. The shell
suite, the reviewer, and the rule that a pull request cannot publish or sign are
all about pull requests. Nothing makes anyone open one. Any token that holds
`contents: write` can push to `main` directly.

One such token is the `fix` job in
[`.github/workflows/ai-fix.yml`](../.github/workflows/ai-fix.yml). Its prompt
tells the agent never to push to `main`. That is an instruction to a model that
reads issue bodies written by strangers. It is not a control. A push by
`GITHUB_TOKEN` does not start `build.yml` itself, but the next scheduled or
manual build signs whatever `main` holds.

## The ruleset

[`.github/rulesets/main.json`](../.github/rulesets/main.json) is the agreed
definition. It is in GitHub's import format, so it applies as-is. What each rule
does:

- **Targets `~DEFAULT_BRANCH`**, so it follows a rename of `main`. The `status`
  branch that `status-badges.yml` pushes to is not covered, and does not need
  to be.
- **No bypass actors.** A bypass for Actions or for an App hands back the direct
  push this exists to stop.
- **`deletion` and `non_fast_forward`** stop `main` being deleted or rewritten.
- **`pull_request` with 0 approvals.** GitHub does not let anyone approve their
  own pull request. On a single-maintainer repository, requiring one approval
  means nothing can ever merge, including the change that relaxes the rule.
  What 0 still enforces is that every change arrives as a pull request and a
  person presses merge.
- **One required check, `Shell tests`.** It is the only check every pull request
  gets: `build.yml` runs it on code changes and `coverage-gate.yml` runs it on
  the docs-only changes `build.yml` ignores. `Build and push image` is not
  required, because a docs-only pull request never gets it and would wait
  forever. `Apply area labels` classifies a change rather than checking it.
  `integration_id` 15368 is GitHub Actions.

Nothing in this repository pushes to `main` outside a pull request today. Every
first-parent commit on `main` since 2026-08-01 is a pull request merge. Renovate
automerges through pull requests too. So applying this should change nothing
about how work lands.

## Applying it

A pull request cannot change repository settings. A repository admin applies
it once:

```bash
gh api --method POST repos/Danathar/aurora-zfs-simple/rulesets \
  --input .github/rulesets/main.json
```

To change it later, edit the file through a pull request, then update the live
ruleset from the file with `--method PUT` on `rulesets/<id>`.

## When there is a second reviewer

Set `required_approving_review_count` to 1. Consider
`require_last_push_approval`, so a push after approval needs a fresh one.
