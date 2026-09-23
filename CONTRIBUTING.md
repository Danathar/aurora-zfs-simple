# Contributing

A small repo with an unusual shape: almost none of its code runs on your
machine, and the thing most likely to make it red is not in it. Both facts drive
everything below.

If you are an LLM agent, read [`AGENTS.md`](AGENTS.md) instead — or first. It
covers build-failure diagnosis in far more depth than this file.

## Before you start: is it actually broken?

Check the README badges. **OpenZFS/kernel** reads the `ostree.linux` label off
the two upstream akmods images this `Containerfile` pulls. When it says
`blocked`, there is no `kmod-zfs` published for the kernel the build wants. It
clears when upstream re-converges.

That is the dominant failure mode here, it is anticipated in the `Containerfile`
comments, and it is the same reason Aurora dropped ZFS.

Separate the root cause from the response, because they live in different
places:

- **The cause is not in this repo and cannot be fixed here.** No change on this
  side makes upstream publish a `kmod-zfs` for a kernel OpenZFS does not yet
  support. A PR that claims to "fix the ZFS build" is misreading the failure.
- **The response can absolutely be a change here.** Pinning both akmods inputs
  to the last kernel they agreed on restores green builds immediately, and
  switching streams is the other documented option. These are real, supported
  mitigations — not workarounds to be talked out of.

[`AGENTS.md`](AGENTS.md#dominant-failure-mode-kernel--zfs-akmod-skew) has the
60-second confirmation and how to choose between waiting, pinning and switching.
Pin **both** inputs or neither; a half-pin is the one move guaranteed to break.

## Running the tests

```bash
./tests/run-tests.sh                    # everything
./tests/run-tests.sh test-write-badges  # one file
```

The suite needs bash 4+, `jq`, GNU `date`, `sed`, and Python 3 with PyYAML.
Install PyYAML with `sudo apt-get install python3-yaml` on Debian/Ubuntu or
`sudo dnf install python3-pyyaml` on Fedora. The workflow expression check uses
`python3` by default; set `WORKFLOW_PYTHON` to use a different interpreter, such
as one from a virtual environment with PyYAML installed. A missing parser fails
the suite. CI installs PyYAML explicitly and uses `/usr/bin/python3`.

**Install `shellcheck` before you trust a green run.** `test-shell-syntax.sh`
skips its shellcheck pass when the tool is absent, so the suite stays usable
without it — which means a local pass is weaker than CI's, where shellcheck is
installed and the pass is enforced. The bar is *zero output* from
`shellcheck -x`, informational findings included. When a finding is genuinely
wrong, silence it with a `# shellcheck disable=SCxxxx` directive and a comment
saying why, rather than reshaping the code around it.

[`tests/README.md`](tests/README.md) has the map of what is covered, and is
candid about what is not.

## What the tests cannot reach

`build_files/build.sh`, `build_files/kernel-akmods.sh`, `build_files/zfs.sh` and
the `Containerfile` run inside an image build against a real RPM database,
module tree and initramfs. Nothing on the host reaches them.

`build_files/post-check.sh` is the exception, and only partly: it guards its
entry point with

```bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

so sourcing it defines the helpers without running a check, and
`test-post-check.sh` calls them directly with `rpm`, `ldd` and `find` stubbed.
The `check_*` functions themselves are still only exercised by a real build.

So: if you change `build_files/` or the `Containerfile`, a green suite is not
evidence. Say in the PR how you verified it, or say that you did not. A green
`Build container image` run on the PR is the strongest evidence available — it
builds the whole image and runs `post-check.sh` and `bootc container lint`
inside it, and publishes and signs nothing.

## One gotcha about CI

`build.yml` sets `paths-ignore` for `README.md` and `docs/**`. A pull request
touching *only* those paths therefore starts no run at all, so the shell suite
does not execute — including on the changes most likely to introduce doc
drift.

Touching one non-ignored file is enough to get a run. If your change is purely
prose, run `./tests/run-tests.sh` locally and say so in the PR.

## Style

Match the file you are editing. Across the repo:

- `set -euo pipefail` at the top of anything executed; `set -uo pipefail` in the
  test runner, which needs to survive a failing test and report it.
- Four-space indentation in shell, except `ci/write-badges.sh` and
  `.claude/hooks/gate-git-diff.sh`, which use two and are left alone.
- Shebang and executable bit on anything run by path. The test suite enforces
  this, because the `Containerfile` and the workflows run these scripts by path.
  The exception is `tests/lib/`, which is only ever sourced and deliberately
  carries neither.
- Comments explain *why*, and especially why something that looks wrong is
  deliberate. This repo has several of those — the `.Config`-only inspect that
  works around `MAX_ARG_STRLEN`, the badge script refusing to guess when an
  input is unreadable, the single-push-then-copy tag propagation. They read as
  odd until you know the incident behind them. Preserve that, and add to it.

## Docs are load-bearing

`README.md` is the public entry document and directs a reader with a failed
build to `AGENTS.md`. A path or a behaviour claim that has drifted is a real
defect, not a nit —
[#70](https://github.com/Danathar/aurora-zfs-simple/issues/70) was exactly
that.

When you change a workflow, a script's behaviour, or a pinned input, check
whether `README.md`, `AGENTS.md` or `docs/manual-input-check.md` describes it.

## Pull requests

Branch from `main`, one concern per PR. The template asks the questions worth
answering.

After opening a PR, check `chatgpt-codex-connector[bot]`. It posts as a review
with inline comments, which `gh pr view <N> --comments` does **not** show:

```bash
gh api repos/{owner}/{repo}/pulls/<N>/comments \
  --jq '.[] | "PATH: \(.path):\(.line // .original_line)\n\(.body)\n---"'
```

Verify each finding before acting — it is often right, not automatically right.
Fix what is valid; push back with evidence on what is not. Do not block on it:
give it a couple of minutes and move on if nothing appears.

To hand a verified finding to an agent instead of fixing it yourself, comment
`@claude` on the pull request, or label an issue `ai-fix-requested`. That runs
[`.github/workflows/ai-fix.yml`](.github/workflows/ai-fix.yml), which opens a
pull request and never merges one. The bot's own comment cannot start it — yours
is what does, deliberately, because you have verified the finding and the bot
has not.

It has to be a conversation comment rather than an inline reply on the review
thread, which is less convenient and not an oversight: those two placements run
workflow files from different branches, and only one of them is safe for a job
that can write to the repo. Read
[`docs/SECURITY-AI.md`](docs/SECURITY-AI.md#agent-authored-pull-requests) before
adding a trigger to that workflow.

## Changes that need a conversation first

Open an issue before:

- pinning the akmods inputs on `main` (pin **both** or neither — a half-pin is
  the one thing guaranteed to break)
- moving `FEDORA_VERSION`, which has a pre-flight checklist in
  [`docs/manual-input-check.md`](docs/manual-input-check.md)
- changing what gets signed, or the tag-propagation logic that keeps every
  published tag on one manifest digest
- adding a runtime dependency to CI. The repo deliberately has no package
  manager and no `node_modules`; the tests are shell because the code is shell.
- widening the agent permission boundary — a new allow row or a dropped `deny`
  row in `.claude/settings.json`, or a relaxed refusal in
  `.claude/hooks/gate-git-diff.sh`. Those two files are Tier 3 in
  [`docs/risk-tiers.md`](docs/risk-tiers.md) for the reason the section there
  gives. Narrowing the boundary needs no issue first.
