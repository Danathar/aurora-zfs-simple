# Tests

Bash tests for the shell this repository ships, plus a Python/PyYAML workflow
expression check. No third-party test framework is needed.

```bash
./tests/run-tests.sh                    # everything
./tests/run-tests.sh test-write-badges  # one file
```

Requirements: bash 4+, `jq`, GNU `date`, `sed`, and Python 3 with PyYAML
(`python3-yaml` on Debian/Ubuntu, `python3-pyyaml` on Fedora). The workflow check
uses `python3` by default; `WORKFLOW_PYTHON` can select another interpreter with
PyYAML installed. Missing Python or PyYAML fails the check. `shellcheck` is used
when present and skipped when not.

## What is covered

| File                        | Covers                                                                                     |
| --------------------------- | ------------------------------------------------------------------------------------------ |
| `test-write-badges.sh`      | `ci/write-badges.sh` end to end, with `skopeo` stubbed                                     |
| `test-post-check.sh`        | the pure helpers in `build_files/post-check.sh`, with `rpm`, `ldd` and `find` stubbed      |
| `test-post-check-checks.sh` | `check_kernel_tree` and `check_zfs_packages`, against a text stand-in for the RPM database |
| `test-shell-syntax.sh`      | `bash -n`, shebang and exec bit on every `*.sh`; `shellcheck -x` when installed            |
| `test-coverage.sh`          | every shipped `*.sh` is declared covered by a named test or UNCOVERED with a reason        |
| `test-docs-paths.sh`        | every repo path README.md and AGENTS.md name actually exists                               |
| `test-ci-workflows.sh`      | CI still runs this suite with its dependencies, neither workflow's path filter leaves a gap, and workflow run/shell values contain no Actions expressions |
| `test-auto-qa-tuning.sh`    | every workflow job is bounded by a timeout, and declared to the auto-QA manifest at the number the YAML actually says |
| `test-e2e-preflight.sh`     | `tests/e2e/run-e2e.sh`'s option parsing, free-space preflight and `--clean`, with `podman` and `df` stubbed |
| `test-e2e-verify.sh`        | `tests/e2e/run-e2e.sh` after the build: `--rechunk`, the four checks, `--keep-going` and the report, with the `podman` stub succeeding the build |
| `test-harness.sh`           | the harness itself: `lib/assert.sh`'s tally and every assertion's failing branch, and `run-tests.sh`'s dependency preflight, discovery, selection and failure reporting |

`ci/write-badges.sh` is run as a real subprocess. Its only two inputs are a
Containerfile (a fixture file) and `skopeo inspect`, which a stub earlier on
`PATH` answers from canned JSON while recording its own argv. Nothing else is
mocked, so the tests exercise the script's actual control flow, including the
two properties its comments call deliberate:

- an input that cannot be read leaves the corresponding badge file untouched
  instead of overwriting it with a guess, and
- image references come from the Containerfile's `FROM` lines, so an outage pin
  is reflected in the badge rather than reported against the floating tags.

One case copies the checked-in `Containerfile` in as its fixture: if a stage is
renamed or dropped, that test fails rather than the badge silently going stale.

`test-docs-paths.sh` applies the same idea to the prose. AGENTS.md tells an
agent mid-incident to trust these two documents, so a path they name that does
not exist is a real defect — README.md advertised `.github/renovate.json5` for
some time while the file was `renovate.json` at the repo root. It checks the
"Repository Layout" block line by line, then the inline code spans, anchoring
the filter on `git ls-files` so that GitHub `org/repo` references are skipped
while anything rooted in a real top-level entry is enforced.

`test-ci-workflows.sh` closes the same kind of gap one level up. Everything in
the "In CI" section below was, until it existed, prose that nothing checked: the
suite could keep passing while the workflow that runs it was renamed, stripped
of its `shellcheck` install, or unhooked from `build_push`. The path filters are
the sharp case, because a workflow that stops running is not a workflow that
fails — a `paths-ignore` that grows a third entry produces a *green* result on
the very change that stopped being covered. The topology checks use the existing
indentation-anchored extractors and exercise them against a fixture first, so
an empty extraction fails the suite instead of passing without checking anything.

The expression check uses a real YAML parser in `lib/workflow_expressions.py`,
with regressions in `test_workflow_expressions.py`; both are invoked by
`test-ci-workflows.sh`. It checks step `run` and `shell` values (including
parallel groups), and workflow/job `defaults.run.shell`, after YAML folding,
escape decoding and alias resolution. This catches flow mappings, multiline
scalars, indentationless sequences and expressions whose `$` is escaped in the
source. A job output or environment variable named `run` remains data.

The checker composes YAML nodes with PyYAML's `SafeLoader`, retaining source
locations and duplicate keys without constructing Python objects or converting
the `on` key to a boolean. Both `.yml` and `.yaml` files are scanned. Malformed
YAML, duplicate keys, merge keys, custom tags, recursive aliases and invalid
shapes along executable paths fail the check. Ordinary anchors and aliases
are supported, including a value defined as data and later used as a script.
Diagnostics name both the consuming workflow path and the scalar's source
location, which points to the definition for an alias.

Executable scalars are checked as decoded text regardless of PyYAML's inferred
tag. This avoids rejecting plain commands such as `yes` and `on`, which PyYAML
tags as YAML 1.1 booleans but Actions reads as YAML 1.2 strings. Other scalar
literals are also accepted in string fields by Actions' template reader.
Mappings and sequences still fail, and a scalar's tag never exempts its text
from the expression check. This does not validate whether a command exists or
whether an empty script can execute successfully.

This is an invariant over those executable fields, not a general Actions
schema validator or a security audit of third-party action inputs, reusable
workflows, composite actions, or how a script later uses its environment.

What runs that test matters as much as what it asserts, and this is the part a
first draft got wrong. A `pull_request` run executes the *head* branch's copy of
a workflow file, so a pull request deleting the `Shell tests` job from
`build.yml` would be checked by the `build.yml` that no longer has it — the
suite that would have gone red is the suite that no longer runs. So
`coverage-gate.yml` triggers on `.github/workflows/**` too, and the test asserts
that it does: any workflow edit is checked by a workflow the pull request did
not touch, and the two files police each other. Disabling the gate now takes an
edit to both in one pull request. Making that impossible rather than merely
conspicuous needs a required status check in branch protection, which no file in
the tree can assert.

The branch and activity filters are checked for the same reason. A path filter
is not the only way a workflow stops running: point `build.yml`'s
`pull_request` at another branch and it no longer runs on pull requests to
`main`, while `coverage-gate.yml` keeps running and every path assertion still
passes. Merge that and a source-only pull request runs no suite at all — the
same hole, reached by a different door.

`test-auto-qa-tuning.sh` holds `.github/auto-qa-tuning.json` against the
workflow files. That manifest is what `auto-qa.yml` samples against, and it has
two failure modes that are quiet in the same way: a job absent from it is never
sampled and nothing goes red, and a `timeout_minutes` that no longer matches the
YAML makes every verdict wrong in a direction the workflow cannot see — it reads
the numbers there, not the YAML. `status-badges.yml` shipped for months with no
`timeout-minutes` at all and no entry in the manifest, so its `badges` job — the
one holding `contents: write` — could have held a runner for six hours on a hung
`skopeo`. The test asserts every job declares a timeout, appears in exactly one
of `jobs` or `untracked`, and, when tracked, at the number the workflow really
declares. `untracked` is the `UNCOVERED` idiom from `test-coverage.sh`: not
watching a job is a legitimate answer, but it has to be an answer, with the
reason next to it.

## End-to-end

`tests/e2e/run-e2e.sh` builds the real image with podman and checks the real
artifact. It is not part of this suite — `run-tests.sh` globs `test-*.sh` at
`maxdepth 1` — because it takes tens of minutes and about 40G.

Its `--rechunk` mode covers the one thing nothing else does: `post-check.sh` and
`bootc container lint` are `RUN` steps, so they validate the image *before* the
workflow hands it to Chunkah, and nothing re-checks the re-layered result before
it is pushed and signed. See [`e2e/README.md`](e2e/README.md).

Not being in the suite is not the same as being untestable, though, and
`test-e2e-preflight.sh` covers the half of that script that costs nothing to
run: everything it decides *before* the build. The build is the expensive part;
option parsing, the free-space check and the `EXIT` trap are reached in
milliseconds, and the only external commands involved are `podman` and `df`,
both resolved through `PATH`. So they are stubbed — `podman` records its argv
and fails `build`, `df` answers from a table of
`path`/`device`/`available-KB` rows — and the script stops at that boundary.

That table is what makes the free-space reasoning observable. `run-e2e.sh`
probes the filesystems that actually receive data rather than the checkout, and
deduplicates them by device, because two paths on one filesystem must not each
be asked for 40G; a case that puts the graph root and the archive directory on
one device asserts a single report line, and a case that separates them asserts
two. The archive directory defaulting beside podman's storage rather than to
`TMPDIR` is asserted the same way, with `TMPDIR` pointed somewhere else
entirely — on a Fedora Atomic desktop that default is the difference between
working and dying on a tmpfs. A graph root that does not exist yet, which is
every machine that has never pulled an image, is asserted to be probed at its
nearest existing ancestor.

The cleanup assertions are the other half. `--clean` is the only thing here
that deletes, and the promise in `e2e/README.md` is that it removes exactly the
tags this run created and never prunes. A stubbed build that fails after the tag
is recorded reaches the `EXIT` trap with one tag outstanding, so the test can
compare the `rmi` argument against the `build` argument rather than merely
observing that something was removed. Running without `--clean` asserts no
`rmi` at all. The missing-`podman` case asserts the other trap property: it is
installed before `ARCHIVE` and `LOAD_TMPDIR` have real values, so a failed
prerequisite has to print its own message and exit rather than die on an unbound
variable inside `cleanup`.

`test-e2e-verify.sh` takes the other half. The reasoning that stopped the
preflight tests at `podman build` applies to the build and to nothing after it:
the rechunk, the four checks against the image and the report are `podman` calls
and no other external command. So the same stub, told to *succeed* the build
rather than fail it, runs the whole second half on the host in milliseconds
against an image that never existed.

What that reaches is the script's own accounting, which nothing else touches.
`--keep-going` is the difference between one reported failure and all of them,
and the `CHECKS`/`FAILURES` tally is the only place a check that quietly stopped
running would show — so a case fails three checks at once and asserts all three
are reported and totalled, and a case fails one without `--keep-going` and
asserts the later checks did not merely go unreported but never ran, by looking
for their `podman` calls.

`--rechunk` is asserted against the workflow it rehearses: chunkah's image pin,
`--max-layers 128`, `--prune /sysroot/` and both dropped `ostree` labels, plus
the narrow `{{json .Config}}` read the script's comment explains as a
`MAX_ARG_STRLEN` workaround. The mode's point is that the *re-layered* image is
what gets checked, so the tests compare the tag each check ran against with the
tag chunkah was told to produce; verifying the pre-rechunk image would leave
`--rechunk` asserting nothing while still passing. The archive is a
multi-gigabyte temp file, so a stubbed `podman load` failure asserts the `EXIT`
trap removes it, and a `--clean` run after a rechunk asserts *both* tags are
removed — a `CREATED_TAGS` append missed after the rechunk strands the larger of
the two.

The `containers.bootc` label is the one check that must not fail: a local
`podman build` never has it, because the workflow applies it via
`docker/metadata-action`. So its absence exits 0 and says nothing outside
`--rechunk`, and prints the `note` line inside it, where a dropped label is a
real regression signal. Both directions are asserted.

What still needs a real image is what the checks inspect — whether ZFS userspace
is actually present, whether there is exactly one module tree. These tests cover
how the script reacts to those answers, not the answers themselves.

## The harness

Everything above asserts something about the repository. `test-harness.sh`
asserts something about the two files that decide what "the suite passed"
means, because they fail in the same quiet direction as a workflow that stops
running.

`lib/assert.sh` keeps one counter of assertions and one of failures. `_fail` is
the only place the failure counter moves and `finish` is the only place it is
read, so disarming either leaves every test file in this directory printing its
`ok` lines and exiting 0 while asserting nothing. And no test can reach those
lines by passing: a failing branch of `assert_eq` only runs when a test is
already broken. So they are reached deliberately — a throwaway script sources
`assert.sh`, provokes one assertion each way, and its output and exit status are
what gets checked. That covers the failure text as well as the counters, since a
`FAIL` line that does not say what it expected is a failure nobody can act on.

`run-tests.sh` gets the same treatment one level up, by copying it into a
sandbox directory of fake `test-*.sh` files that pass or fail on command. It
resolves its test directory from `BASH_SOURCE`, so the copy globs the sandbox
rather than this directory. Each fake writes a marker when it runs, which is
what makes "was not reported as failed" and "never ran" distinguishable: the
runner has to collect a failing file into its summary *and* keep running the
files behind it, and a selected name has to be the only thing that runs. The
error paths matter for the same reason as the `paths-ignore` assertions above —
a typo'd test name, or a checkout without `jq`, must not resolve to a run of
nothing that exits 0.

This is the one file here that does not source `lib/assert.sh`. A test of the
assertion helpers cannot report its own verdict through them: an `assert.sh`
that has stopped counting failures would swallow this file's failures too, and
the run that proves the breakage would be the run that hides it. It carries its
own small `expect_*` helpers instead, prints in the same format, and reports a
`check(s)`/`failure(s)` tally of its own.

## The coverage gate

`test-coverage.sh` exists because a percentage would be meaningless here. Most
of this repo's shell cannot be reached from the host at all, so a line-coverage
threshold would either sit near zero forever or get gamed. What is worth
enforcing is that the gap stays deliberate.

It holds a manifest pairing every tracked `*.sh` outside `tests/` with either
the test file that covers it or the literal `UNCOVERED` and a reason. Adding a
script without touching that manifest turns the suite red, so the decision gets
made once, in the open. It is checked in both directions — a stale entry left
behind by a deleted script fails too, as does a "covered by" claim naming a test
file that does not exist or never mentions the script.

## post-check.sh

The script guards its entry point with

```bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

so sourcing it defines `require_glob`, `verify_rpm_payload`,
`require_single_rpm_version` and the rest without running a single check.
`test-post-check.sh` calls them directly with a stub standing in for `rpm`,
`ldd` or `find`, and asserts the guard in both directions: sourcing runs no
check, executing still runs `main`.

Sourcing is also what makes `main`'s own call sequence readable. Each stage is
replaced by a recorder, so the test reads the order without an RPM database,
module tree or initramfs underneath — and that order is a contract rather than
an arrangement. `verify_rpm_payload`'s comment argues that its unparseable-line
branch is unreachable *because* `check_zfs_packages` demands `kmod-zfs` earlier
in `main`; move `check_rpm_payloads` ahead of it and the comment silently
becomes false while the build stays green. A dropped stage is quiet in the same
way. So the assertions are the exact six-stage sequence, `all checks passed`
printed only after the last of them, and — by failing a stage in the middle,
where "did not run" and "was never called" are distinguishable — that a failure
stops the stages behind it.

`test-post-check-checks.sh` goes one level up, to the `check_*` stages. Two of
the six decide purely from what `rpm` and `find` report, so they run on any
host: `check_kernel_tree` and `check_zfs_packages`. What is worth testing there
is the wiring rather than any single call — which package names are demanded,
which glob feeds the version comparison, and whether a verdict assembled from
several `rpm` invocations survives. A stub that answers every query the same way
cannot show that, so this file backs `rpm` with a small text database — one
`NAME VERSION RELEASE ARCH` record per line — and lets the real queries run
against it. That also keeps the stub honest about a detail the script depends
on: `rpm -qa 'libzfs[0-9]*'` returns full `NVRA` strings that are handed
straight back to `rpm -q --qf`, so both forms have to resolve.

## Not covered

`check_zfs_modules`, `check_zfs_userspace` and `check_initramfs` read absolute
paths under `/usr/lib` and require `zfs`/`zpool`/`zdb`/`zed` on `PATH`. On any
host that is not the finished image they fail before reaching the logic worth
checking — the `spl`/`zfs` vermagic comparison, the `modules-load.d` content
match and the `lsinitrd` listing — so covering them needs an injectable root
prefix in the script itself.

`check_rpm_payloads` needs no such prefix — it is one call to
`verify_rpm_payload`, and which package it names is the whole of it, so
`test-post-check.sh` covers it by stubbing that helper and asserting the
argument. Verifying the wrong package, or none, would otherwise still exit 0.

The other `build_files/*.sh` scripts still run their work at the top level, so
`source` executes the whole file. Their happy path is exercised by the `Build
container image` workflow — a failure there blocks the push — and their failure
branches remain untested.

## In CI

`.github/workflows/build.yml` runs the suite as a `Shell tests` job on every
pull request and push, with `shellcheck` and PyYAML installed, and `build_push`
has `needs: tests` so a red suite blocks the image build. The coverage and
nightly suite jobs install the same dependencies. All three select the system
Python explicitly so it sees the PyYAML package installed by apt.

`build.yml` sets `paths-ignore` for `README.md` and `docs/**` though, so a
change touching only those starts no run there.
`.github/workflows/coverage-gate.yml` triggers on that complement and runs the
same suite, so a docs-only change is no longer the one kind of change nothing
verifies. One workflow or the other runs the suite; a change touching both docs
and code trips both.

`coverage-gate.yml` also triggers on `.github/workflows/**`, which is the
deliberate exception to "one or the other": it is what lets it check a change to
`build.yml`, which `build.yml` cannot check for itself.

All four of those facts — both workflows running the suite with `shellcheck`
installed first, `needs: tests`, and every path one workflow ignores being
picked up by the other — are asserted by `test-ci-workflows.sh`, so this section
is enforced rather than merely accurate.

Running on `pull_request` is what closes the gap this suite was written for:
`ci/write-badges.sh` is executed by no other trigger here — the `Status badges`
workflow runs it on a schedule and on `workflow_run` completion and explicitly
skips `pull_request` — so before this job a change to it reached `main` having
never run once.
