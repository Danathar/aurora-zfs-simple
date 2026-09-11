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
| `test-ci-workflows.sh`      | CI still runs this suite with its dependencies, neither workflow's path filter leaves a gap, workflow run/shell values contain no Actions expressions, and every action any workflow uses is pinned to immutable code |
| `test-auto-qa-tuning.sh`    | every workflow job is bounded by a timeout, and declared to the auto-QA manifest at the number the YAML actually says |
| `test-auto-qa-run.sh`       | `.github/workflows/auto-qa.yml`: the `Compare declared timeouts with observed durations` step, extracted and executed against a `gh` stub backed by JSON fixtures — the two samples, the killed-at-the-cap margin, the at-risk and loose verdicts, and which of them fails the workflow |
| `test-e2e-preflight.sh`     | `tests/e2e/run-e2e.sh`'s option parsing, free-space preflight and `--clean`, with `podman` and `df` stubbed |
| `test-e2e-verify.sh`        | `tests/e2e/run-e2e.sh` after the build: `--rechunk`, the four checks, `--keep-going` and the report, with the `podman` stub succeeding the build |
| `test-ai-fix.sh`            | `.github/workflows/ai-fix.yml`: the `preflight` step's decision script, extracted and executed with `gh` stubbed, plus the permissions, triggers and action inputs that bound its `contents: write` grant |
| `test-nightly-compliance.sh` | `.github/workflows/nightly-compliance.yml`: the `published_image` job's four `run:` bodies, extracted and executed with `skopeo` and `cosign` stubbed — auth-file use, the never-published exemption, the signature check, the date-tag digest comparison and the run summary |
| `test-status-badges.sh`     | `.github/workflows/status-badges.yml`: the `Publish badges to status branch` step, extracted and executed against a real local bare repository — the orphan first run, the no-overwrite copy, the unchanged-content no-op and the ref the push lands on |
| `test-build-publish.sh`     | `.github/workflows/build.yml`: the `build_push` job's publish band — `Prepare environment`, `Propagate tags from the pushed digest`, `Verify pushed tags share one digest` and `Sign container image`, extracted and executed against a file-backed fake registry with `skopeo` and `cosign` stubbed |
| `test-build-rechunk.sh`     | `.github/workflows/build.yml`: the `build_push` job's build band — `Update Podman`, `Move container storage to the large runner disk` and `Rechunk Image with Chunkah`, extracted and executed with `podman`, `sudo`, `apt-get` and `df` stubbed and `HOME` redirected |
| `test-labeler.sh`           | the pull request labeler: `.github/labeler.yml`'s `area/*` namespace and its globs evaluated against real repository paths, plus the `pull_request_target` shape that bounds `.github/workflows/labeler.yml`'s write token |
| `test-renovate.sh`          | the Chunkah regex manager against both checked-in pin syntaxes, including a simulated version-only replacement, and the split of work between `renovate.json` and `.github/dependabot.yml` |
| `test-issue-templates.sh`   | `.github/ISSUE_TEMPLATE/**`: the two issue forms and the chooser — the shape GitHub's schema accepts, the repo paths and links they name, and `build-failure.yml`'s embedded diagnosis held against the `Containerfile`, `ci/write-badges.sh` and AGENTS.md's copy of the same recipe |
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

The credential cases assert a third property, one the script's shape has to keep
rather than one it can state: the GHCR token reaches `skopeo` through a `0600`
file and never through the command line. `/proc/<pid>/cmdline` is mode `0444`, so
a token in an argv is readable by every uid on the runner for as long as the
inspect runs, and is printed by any `ps` someone adds while debugging a hung one
— the same exposure `build.yml` already refuses for the signing key by passing
`--key env://` rather than a path, which `test-build-publish.sh` asserts. That
file is meant to be gone by the time the script exits, so it cannot be inspected
afterwards; the stub records its path, mode and contents from *inside* the call
instead, and the tests then check that the recorded path no longer exists. The
registry key is asserted too, because keying the entry on the wrong host leaves
skopeo with no credential and degrades silently to an anonymous inspect rather
than failing.

`test-docs-paths.sh` applies the same idea to the prose. AGENTS.md tells an
agent mid-incident to trust these two documents, so a path they name that does
not exist is a real defect — README.md advertised `.github/renovate.json5` for
some time while the file was `renovate.json` at the repo root. It checks the
"Repository Layout" block line by line, then the inline code spans, anchoring
the filter on `git ls-files` so that GitHub `org/repo` references are skipped
while anything rooted in a real top-level entry is enforced.

`test-issue-templates.sh` extends that to the one set of instructions a human
reads before anything in this repo runs: `.github/ISSUE_TEMPLATE/**`. Those
three files fail in a way nothing else here does. GitHub validates them
server-side, and a malformed form is dropped from the chooser silently — no
error, no red check, just a template that stops being offered. So the first half
of the file is shape: the element types, unique ids, labels, dropdowns with
distinct options, and `validations.required` as a real boolean rather than the
string `"true"`. That last one is why the file goes through PyYAML instead of
`grep`; both spellings look identical in the text and only one of them works.

The second half is agreement with the tree, which is the half that rots
quietly. `build-failure.yml` embeds a runnable diagnosis, and every piece of it
is a claim about something else here: the `sed` that reads `FEDORA_VERSION` out
of the `Containerfile` is *executed* against the real file rather than matched
as a string, because the failure mode is not that the text changed — it is that
the text is unchanged and now extracts nothing. The two
`ghcr.io/ublue-os/akmods*` references it builds are held against the
`Containerfile`'s `FROM` lines with that version substituted, the `ostree.linux`
label it inspects against the label `ci/write-badges.sh` reads, and the log
`grep` against AGENTS.md's copy of the same recipe. AGENTS.md is what an agent
is told to trust mid-incident, so the two copies disagreeing means the form
collects evidence for a question nobody is asking — including the release
AGENTS.md hard-codes, which this checks against the `Containerfile`'s `ARG`.

The chooser's `contact_links` are out of `test-docs-paths.sh`'s reach twice
over: they are absolute URLs, and they are in YAML. One of them carries an
`#anchor` into AGENTS.md, resolved here under the same slug rules — hence
`lib/markdown.sh`, which both tests now share rather than keeping two copies of
GitHub's slug rules that could drift apart.

`test-renovate.sh` covers a division of labour that is written down in only one
of the two places it binds. `renovate.json` disables its `github-actions`
manager with a comment saying Dependabot owns those updates; the other half of
that sentence is an ecosystem entry in `.github/dependabot.yml`, and neither
file mentions the other. Both halves failing is silent in opposite directions —
two bots on `github-actions` opens every update twice, and neither leaves the
full-SHA `uses:` pins that `lib/workflow_pins.py` requires with nothing to move
them, which does not fail anything because a stale pin is still a valid one. So
the cases assert ownership rather than presence: each Dependabot ecosystem is
mapped to the Renovate manager it would collide with, an unmapped ecosystem is
a failure rather than an assumed-harmless addition, and the `Containerfile`'s
hand-managed ARGs are checked against both bots at once. The Chunkah
`packageRules` entry is joined to the custom manager's `depNameTemplate`,
because a rename there would detach the rule while leaving it valid JSON, and
the README paragraph promising the pin stays a tag is held against the same
name.

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

The pinning check is the other directory-wide pass, in `lib/workflow_pins.py`
with regressions in `test_workflow_pins.py`, and it exists because the same rule
was previously asserted one file at a time. `test-ai-fix.sh` walks every `uses:`
in `ai-fix.yml` because that job holds `contents: write`, and `test-labeler.sh`
checks `labeler.yml`'s single action because that one holds
`pull-requests: write` on an event any outside contributor can trigger. Both
still do, and both assert more than pinning about those files — but between them
they left `build.yml` unchecked, and `build_push` holds `packages: write`, runs
six third-party actions, and hands `secrets.SIGNING_SECRET` to `cosign sign`. A
`uses:` on a tag there is a third party deciding what gets signed under the key
`cosign.pub` tells consumers to verify against.

Applying the rule to the directory covers `status-badges.yml` (`contents: write`,
pushes the status branch), `nightly-compliance.yml`, `coverage-gate.yml` and
`auto-qa.yml` as well, and covers a workflow added later that nobody remembers
to write a test for. Step-level `uses:` and a job-level reusable-workflow
`uses:` are both checked: `owner/repo[/path]@ref` must carry a full
40-character lowercase commit SHA, `docker://` must carry an `@sha256:` digest,
and `./local/action` needs no ref because it moves with the commit under review.
A scan that extracted no `uses:` at all fails rather than reporting a clean
result, the way `test-ai-fix.sh` already refuses its own empty extraction.

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

## The status branch

`test-write-badges.sh` stops where `ci/write-badges.sh` does, at the artifacts
directory. `test-status-badges.sh` picks the pipeline up there and covers the
rest of it: the `Publish badges to status branch` step of
`.github/workflows/status-badges.yml`, the shell that turns those two JSON files
into a commit on the `status` branch that shields.io reads.

The step is extracted from the parsed YAML and run for real. Nothing is stubbed:
the remote is a local bare repository, reached by rewriting the
`https://github.com/…` URL the step builds with
`url.<file://…>.insteadOf` in a per-case `GIT_CONFIG_GLOBAL`. So the orphan
branch, the shallow fetch, the staged diff and the ref the push lands on are all
observed on the far side rather than read out of the script. Overriding
`GIT_CONFIG_GLOBAL` also drops the ambient git identity, which leaves the step's
own `git config user.name/user.email` lines load-bearing — the committer the
branch ends up with is checked, not assumed.

What it pins down is conditional, and none of it is visible in the text: the
first run in a repository with no `status` branch has to take the `--orphan`
path and every run after it the fetch path; only files written this run are
copied over, so a run that could read one input but not the other leaves the
other badge's last known-good content alone (the same no-overwrite rule
`test-write-badges.sh` asserts inside the script, here resting on a `[ -f … ]`
guard); an unchanged badge produces no commit at all, which on a daily schedule
is the common case rather than an edge one; and the push is `HEAD:status`, one
word away from putting bot commits on the branch that produces images. The
copy loop naming the two files, rather than copying the directory, is asserted
too — `status` is served publicly from raw.githubusercontent.com, and the job
that writes it also runs `skopeo`.

The step's `if:` guard is read against `ci/write-badges.sh`. It waits for
`steps.badges.outputs.akmods_updated` or `last_good_updated` to be `'true'`, and
nothing else in the repository ties those two files together: rename an output
in the script and the gate is false on every run, badges frozen, every job
green.

## The published tag set

`test-build-publish.sh` covers the last four `run:` bodies of `build.yml`'s
`build_push` job — the ones that decide what the registry ends up holding and
what is signed. Until it existed nothing executed them: they are shell inside
YAML strings, so `run-tests.sh` does not find them, `test-shell-syntax.sh` does
not `bash -n` them and `shellcheck` never sees them, while
`test-ci-workflows.sh` reads the same file only for its jobs, triggers and path
filters.

The band exists because of a real incident. Sequential `podman push`es of one
local image can emit different manifest bytes — the first uploads, later ones
reuse cached blob info — so `latest` and the date tags ended up on different
digests and `latest` fell outside what was signed. The job now pushes exactly
one tag and copies that manifest onto the rest with `skopeo copy
--preserve-digests`, then verifies every tag resolves to the pushed digest
before `cosign` runs.

Each step is extracted from the parsed YAML and run as a real subprocess against
a file-backed fake registry: a directory of tag files holding digests, written
by a recording `skopeo copy` stub and read back by `skopeo inspect`. So the
assertions are about the state the registry is left in, not about the text of
the script — the tags that exist, the digest each one resolves to, and the argv
that got them there. The `Prepare environment` step is run first and its
`GITHUB_ENV` output feeds the rest, because `github.repository_owner` is
`Danathar` and every reference in the job depends on that one case fold.

What it pins down:

- the copy source is the pushed `@digest`, never `:latest`, and
  `--preserve-digests` is on every copy — either change re-creates the split
  with all the tags still present and nothing looking wrong;
- the already-pushed default tag is skipped by the propagate loop and checked by
  the verify loop;
- a mismatched tag, an unreadable tag and an empty `steps.push.outputs.digest`
  each fail the job, and fail it *before* `cosign` signs anything;
- `cosign` signs `@${DIGEST}`, non-interactively, with the key read from the
  environment — signing a tag would leave the digest that consumers (and
  `nightly-compliance.yml`) verify unsigned while the job stayed green;
- the three steps take their digest and tag list from the same push and metadata
  outputs, run under exactly the push step's `if:` guard, and sit in the order
  push → propagate → verify → sign.

## The rechunk and the runner's disks

`test-build-rechunk.sh` covers the three `run:` bodies that come before the
publish band in the same job: `Update Podman`, `Move container storage to the
large runner disk` and `Rechunk Image with Chunkah`. They are extracted from the
parsed YAML the same way, and executed with recording `podman`, `sudo`,
`apt-get` and `df` stubs and a redirected `HOME`. The `sudo` stub records and
returns rather than exec-ing, so running the suite writes nothing under `/etc`
or `/mnt`. `IMAGE_NAME` is not hand-written either: `Prepare environment` is run
first and its `GITHUB_ENV` output supplies the lower-cased name the later steps
address the image by.

Two of the three fail quietly rather than loudly, which is what makes them worth
executing:

- `Update Podman` pins `crun`, `buildah`, `podman` and `skopeo` to the
  `resolute` pocket because Ubuntu 24.04's podman drops Chunkah's layer
  annotations on push. Lose the `/resolute` suffixes and apt installs the
  runner's own podman again — the build still succeeds, just without the
  annotations. The step is also written to retire itself once the hosted image
  ships podman 5, so both sides of `-ge 5` are covered, including the 5.0.0
  boundary, and the skip path is asserted to make no apt or `sudo` calls at all.
- `Move container storage` is checked against a *populated* store, because that
  is what the hosted image ships. The `rm -rf` before the `ln -s` is the whole
  step: without it the link is created inside the existing directory, podman
  goes on using `/`, and the step still exits 0 — the failure arrives much later
  as an out-of-disk part-way through the rechunk.

For the rechunk itself the assertions are about the sequence and the argv, since
that is where its two recorded fixes live. `podman inspect --format
'{{json .Config}}'` is deliberate: the full inspect grows with the base image's
layer count, and at 256 layers it crossed `MAX_ARG_STRLEN` and exec failed with
`E2BIG`, so the stub honours the format string and the exported
`CHUNKAH_CONFIG_STR` is checked to carry no per-layer content. The
buffer-to-archive, `podman image prune -af`, `TMPDIR=/mnt/tmp podman load`
ordering is what keeps two unpacked copies of the image off one disk, so the
calls are asserted in order rather than as a set — and a failing chunkah run is
asserted to reach neither the prune nor the load, because the prune deletes the
source image the job would otherwise still have. A failing `podman inspect` is
covered for the same reason: it is what the separate `export
CHUNKAH_CONFIG_STR` line buys, since folding it into the assignment would return
`export`'s status and rechunk with an empty config. The closing
`for tag in ${TAGS}` is unquoted on purpose — the metadata step sets
`sep-tags: " "` — so the tag loop is driven with a three-tag list and the
resulting `podman tag` calls are counted.

## The AI fix workflow

`test-ai-fix.sh` covers `.github/workflows/ai-fix.yml`, which is the only
workflow here that grants `contents: write` to a job an outside event can start.

Its `preflight` step is 65 lines of shell inside a YAML string, so nothing in
this repository executed it: not this suite (it is not a `*.sh` file), not
`shellcheck`, not `bash -n`. Those lines are the access-control decision — bot
sender, no credentials, fork head, hand off — and a wrong answer is silent
either way. `run=no` where `yes` belongs reads as a quiet workflow; `run=yes`
where `no` belongs starts an agent with push access on an event the workflow's
own header says must never start one. So the test extracts the script from the
parsed YAML and runs it, with a stub `gh` and the step's `env:` block supplied
case by case, asserting both the `run=` output the `fix` job gates on and the
run-summary text, which is a human's only explanation of a skip. An empty
extraction fails rather than passing vacuously.

The second half asserts the invariants that file argues for in prose, since
prose does not fail. `pull_request_review` and `pull_request_review_comment`
were removed from its triggers because they run the *head branch's* copy of a
workflow, so a pull request could add its own trigger and reach that
`contents: write` in the same pull request; nothing stopped either from being
added back. The permission blocks are compared as whole sets rather than spot
checked, `allowed_bots: ''` is read from parsed YAML so an absent key is not
mistaken for an empty one, both actions must be pinned to a commit SHA, and
`needs.preflight.outputs.run == 'yes'` is compared rather than searched for —
broaden it and every check in the first half stops mattering while all of them
still pass.

## The nightly compliance workflow

`test-nightly-compliance.sh` covers the `published_image` job of
`.github/workflows/nightly-compliance.yml`, the only thing here that looks at the
*published* image after the run that pushed it. Its four `run:` bodies live
inside YAML strings, so this suite never globbed them and `shellcheck` never saw
them; `test-ci-workflows.sh` reads the file, but only for the `suite` job's
shellcheck ordering.

Two decisions in that job are silent when they are wrong. The first draws the
line between "nothing was ever published here" — exempt, exit 0, every later
step skipped — and "the image stopped being readable", which is the headline
incident the job exists to catch. The whole line is one `grep -qiE` over
skopeo's stderr, and widening it restores the behaviour the file's header
describes as the bug it was written to fix: a `manifest unknown` (`:latest`
deleted or repointed) or an `unauthorized` reported as a quiet green run. The
second accumulates a status across two date tags, where an absent tag is a
warning and a disagreeing tag is a failure; if a later matching tag reset the
accumulator, a repointed `latest.YYYYMMDD` would be printed to stdout and the
job would still pass.

So each body is extracted from the parsed YAML and run as a real subprocess with
`skopeo` and `cosign` stubbed, asserting what the next step and the job status
consume: the `GITHUB_OUTPUT` keys, the exit code, the `::error::` and
`::warning::` annotations, and the step summary. The `if:` guards are asserted
next to them, because the exemption only means anything while the steps after it
are gated on `present` — ungated, the exempt path runs `cosign verify` against
an empty digest and fails the run it was meant to spare.

The skopeo stubs also record every argument. Both inspect steps must name the
`~/.docker/config.json` written by `docker/login-action`, must never receive the
registry token or `--creds` on their command line, and must fail before calling
skopeo if that file is absent. The last guard prevents a missing login artifact
from silently turning a successful check of a public package into an anonymous
one.

## The labeler

`test-labeler.sh` covers the pair that applies `area/*` labels:
`.github/labeler.yml` and `.github/workflows/labeler.yml`. Two
directory-scanning checks already touched the workflow — `test-auto-qa-tuning.sh`
for its timeout and manifest entry, `test-ci-workflows.sh`'s expression pass
because it reads every file in `.github/workflows/` — but nothing read either
file for what it says, and nothing read the config at all.

The workflow is the one job here that holds a write token on an event a stranger
triggers. `pull_request_target` runs the *base* branch's copy with
`pull-requests: write`, which is safe for exactly as long as the head branch's
contents never arrive: an `actions/checkout` of the head ref, or a `run:` body
executing something the pull request supplied, hands an outside contributor that
token. Both absences are asserted, along with the permission set as a whole, the
trigger and its event types, the SHA pin, and `sync-labels: false` — the action
would otherwise remove a label a human applied by hand.

The config carries a different boundary. `ci`, `testing`, `quality`, `security`,
`hive/*` and `agent/*` mean *approved to auto-merge* to the external system this
repository is connected to (docs/SECURITY-AI.md, "Labels carry authority"), and
`ci` and `testing` are exactly what a path-based labeler would attach to a change
under `.github/workflows/` or `tests/`. The `area/*` namespace is what keeps that
from happening, and it was enforced by a comment. Here it is a check, twice: every
label must be in `area/`, and none may appear in the authority list the doc
publishes — read out of the doc rather than copied, so the two cannot drift.

The globs are asserted by evaluating them against paths that exist in this tree,
not by reading them back. `tests/*` in place of `tests/**` parses, reviews
cleanly, and silently stops labeling everything below the first level; only a
path-to-labels table catches it. The matcher that evaluation needs is itself run
against a fixture config with known answers first — an under-matching matcher
would turn the whole table into a vacuous pass.

## The auto-QA report

`test-auto-qa-tuning.sh` and `test-auto-qa-run.sh` split the auto-QA workflow
between them along a line worth stating: the first checks the *manifest*
(`.github/auto-qa-tuning.json`) against the workflow files, and reads
`auto-qa.yml` only as text, to confirm it still points at that manifest. The
second executes the workflow's one `run:` body. Until it existed, the shell that
turns those numbers into a verdict was run by nothing — it is shell inside a
YAML string, so `run-tests.sh` does not find it, `test-shell-syntax.sh` does not
`bash -n` it, and `shellcheck` never sees it.

The step is extracted with PyYAML and run as a real subprocess, with the
manifest written per case and `gh` replaced by a stub that answers from JSON
fixtures and records its argv. The stub honours `--jq` by piping the fixture
through the real jq, so the filters in the workflow are exercised rather than
bypassed; the arithmetic, the `awk` ratio comparisons and the summary table are
the workflow's own.

The property that most needs a test is the one the workflow's header records as
having already gone wrong once. Duration is sampled from *successful* runs,
because a run that failed for an unrelated reason says nothing about how long
the work takes — but a job killed at `timeout-minutes` is a *failure*, so
sampling successes alone left this workflow blindest at the moment it mattered:
once every current run dies at the cap, the only samples left are older and
faster, and it reported "ok" while the build was broken on a schedule. The
second query exists for that case, and a case here removes every successful run
so that only it can produce the verdict.

`cap_s=$((timeout_s * 98 / 100))` is what makes "killed at the cap" decidable at
all, since the API exposes no timed-out conclusion: a job killed at 10m reports
a hair under 600s and an ordinary test failure returns long before it. Cases sit
on both sides of that margin, and on both sides of the at-risk ratio, including
exactly at it. A slow *success* at the same duration is checked too — without
the `conclusion == "failure"` filter, every job approaching its cap would be
reported as one that had already been killed.

The remaining cases cover what the report is for: only **at risk** exits
non-zero, "loose" is written and never fails, a job with no sampled runs renders
as an absence rather than as a very fast job, the at-risk arm produces one row
rather than two, and the manifest is left exactly as it was found — this
workflow proposes a number, it does not edit a timeout.

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

Every `run:` body of `build.yml`'s `build_push` job is now executed by a test —
the build band by `test-build-rechunk.sh`, the publish band by
`test-build-publish.sh`. What is left in that job is its `uses:` steps
(`checkout`, `remove-unwanted-software`, `docker/metadata-action`,
`buildah-build`, `login-action`, `push-to-registry`, `cosign-installer`), which
are pinned third-party actions with no shell of this repository's own. Nothing here runs them, and the tag list
`metadata-action` produces is only observable through the `run:` bodies on
either side of it, which is where the tests supply it themselves.

What is left unchecked under `.github/` after `test-issue-templates.sh` is the
prose that has no machine-readable contract: `.github/prompts/**`,
`pull_request_template.md` and `copilot-instructions.md`. Their relative links
are resolved by `test-docs-paths.sh`'s third pass, and nothing else about them is
assertable — they are read by a human or an agent, not parsed.

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
