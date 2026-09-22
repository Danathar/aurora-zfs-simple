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
| `test-post-check.sh`        | the pure helpers in `build_files/post-check.sh`, with `rpm`, `ldd`, `find` and `modinfo` stubbed |
| `test-post-check-checks.sh` | `check_kernel_tree` and `check_zfs_packages`, against a text stand-in for the RPM database |
| `test-containerfile.sh`     | the `Containerfile`'s build-stage wiring: the `--mount` destinations on each `RUN` against the absolute paths the `build_files/` scripts read, extracted from the scripts rather than restated, plus the order the four are invoked in and their place inside one `RUN` |
| `test-shell-syntax.sh`      | `bash -n`, shebang and exec bit on every `*.sh`; `shellcheck -x` when installed; and that no tracked file is a shell script under some other name |
| `test-coverage.sh`          | every shipped `*.sh` is declared covered by a named test or UNCOVERED with a reason        |
| `test-coverage-map.sh`      | this file: the coverage table's first column against the `tests/test-*.sh` glob in both directions, and the "Not covered" list against `test-coverage.sh`'s `UNCOVERED` column in both directions |
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
| `test-manual-input-check.sh` | `docs/manual-input-check.md`: the manual pre-bump procedure held against the machine it describes — the artifact references and tag template against the `Containerfile`'s `FROM` lines, the copied payload paths against its bind mounts, the RPM names and `rpm --qf` query against `build_files/post-check.sh`, and the worked release example against `ARG FEDORA_VERSION` |
| `test-issue-templates.sh`   | `.github/ISSUE_TEMPLATE/**`: the two issue forms and the chooser — the shape GitHub's schema accepts, the repo paths and links they name, and `build-failure.yml`'s embedded diagnosis held against the `Containerfile`, `ci/write-badges.sh` and AGENTS.md's copy of the same recipe |
| `test-claude-settings.sh`   | `.claude/settings.json`: the `PostToolUse` shellcheck hook and the `PreToolUse` hook that gates `git diff --no-index`, both extracted and executed — the first against a recording `shellcheck` stub, the second against the command payloads it has to refuse and the ones it must leave alone — plus the permission table's `deny` rules, the decisions its `_note_*` keys record, and the reach of the one `allow` rule that names a script — `run-tests.sh` is run with a path outside `tests/` and has to refuse it |
| `test-quality-docs.sh`      | `docs/quality.md`, `docs/metrics.md` and `docs/review-rubric.md`: the badge and gate tables against `.github/workflows/build.yml`, `.github/workflows/status-badges.yml`, the `Containerfile` and `ci/write-badges.sh`; the metrics commands parsed and their `jq` filters compiled; and the rubric's checks, incident comments, shell bar, evidence table and signing claim against the code each one names |
| `test-memory-corrections.sh` | `.claude/memory/corrections.md`: the entry shape `.claude/memory/README.md` asks for, every repository path the entries cite, and each correction's claims against the machine that settles it — the `Containerfile`'s final two `RUN` steps and the rechunk's place after them in `.github/workflows/build.yml`, that step's `.Config` read and incident numbers, AGENTS.md's `--state all` query, diagnosis block and pin example, and `test-shell-syntax.sh`'s shellcheck skip against CI's `Install shellcheck` step |
| `test-agents-doc.sh`       | `AGENTS.md`: every claim in it that names something here, recomputed rather than restated — the step names it sends an agent to look for against `build.yml`'s own steps, with no *job* name of `build.yml` described as a step; the three-upstream-inputs table against the `Containerfile` in both directions, each "Referenced at" cell resolved to a real `ARG` or stage and each "Provides" path to the bind mount that supplies it from that stage; the numbered pipeline against the `/ctx/*.sh` invocations in order and each step's claims against the script it names; the Symptom block's RPM path, quoted `RUN` and "only `kmod-zfs` is kernel-versioned" signature against `build_files/zfs.sh`'s `ZFS_RPMS`; the 60-second diagnosis against `FEDORA_VERSION`, the two akmods repositories and the `ostree.linux` label `ci/write-badges.sh` reads; the fix options against the schedule, `workflow_dispatch` and the stage names the mixed-pin example would replace; the Chunkah remedy against the `Rechunk Image with Chunkah` step body; and its anchor, its `bash` blocks and its `jq` filters |
| `test-cursorrules.sh`       | `.cursorrules`: every rule that names something in this repository, held against it — the three artifacts the `Containerfile` assembles and the two `ci/write-badges.sh` compares, the `kmod-zfs` glob and the fatal install in `build_files/zfs.sh`, the kernel erase in `build_files/kernel-akmods.sh`, the indent exceptions against `.editorconfig`, the shebang, executable-bit and `shellcheck` bars against `test-shell-syntax.sh` and `.shellcheckrc`, and the scripts it calls unreachable from the host against `test-coverage.sh`'s `UNCOVERED` set |
| `test-copilot-instructions.sh` | `.github/copilot-instructions.md`: every instruction that names something in this repository — the three artifacts and the two compared kernels out of the `Containerfile` and `ci/write-badges.sh`, the kernel erase held against the `Containerfile` mount that supplies the replacement, the `kmod-zfs` glob and fatal install in `build_files/zfs.sh`, the `shellcheck` bar and its skip against `test-shell-syntax.sh` and `.shellcheckrc`, the shebang exemption and the two-space exception list against the tree and `.editorconfig` in both directions and against the same rules in `.cursorrules` and CONTRIBUTING.md, the three incident comments it tells an agent not to strip against `.github/workflows/build.yml` and `ci/write-badges.sh`, and the unreachable-from-the-host set against `test-coverage.sh`'s `UNCOVERED` column |
| `test-agent-prompts.sh`     | `.github/prompts/*.prompt.md` and `.claude/commands/*.md`: every claim that names something here — the two akmods references and the `ARG FEDORA_VERSION` `sed` run against the `Containerfile` rather than matched as text, the seven OpenZFS RPM families against `build_files/zfs.sh`'s `ZFS_RPMS`, the `kmod-zfs` glob asymmetry and the kernel erase that makes a newer `aurora-dx` kernel not skew, the badge and its `blocked` state against `ci/write-badges.sh` and README.md, and each `.claude/commands/` file against the prompt it wraps |
| `test-editorconfig.sh`      | `.editorconfig`: every section resolved the way EditorConfig resolves them and measured against the tree — line endings, final newlines, charset and the two trailing-whitespace exemptions over every tracked file, `indent_size` against the indentation each shell, YAML, JSON and `Containerfile` actually uses, and the header note's claims about Prettier and `.shellcheckrc` |
| `test-session-summary.sh`   | `.claude/session-summary.md`: every claim that names something here — the retired branch and tag against README.md, `ARG FEDORA_VERSION` and both unpinned akmods `FROM` lines against the `Containerfile`, `docs/**` against every path filter in `.github/workflows/build.yml`, the unchecked-after-Chunkah ordering against the `Containerfile`'s last two `RUN` steps and the workflow's step order, the `--rechunk` remedy against `tests/e2e/run-e2e.sh`, the Chunkah pin against the workflow and `renovate.json`'s own exclusion, the badge name and its leave-alone branch against `ci/write-badges.sh`, and the label-comparison snippet executed against the `Containerfile` it reads |
| `test-reflections.sh`       | `docs/reflections/**`: every entry against the format spec its `README.md` states — filename shape, a date stamp equal to the filename date, the three headings in order — and each entry's checkable claims against the file the claim is about: the tag set, single push, `skopeo copy --preserve-digests`, verify-before-sign order and digest-targeted `cosign sign` recomputed from `.github/workflows/build.yml` plus the nightly re-check in `nightly-compliance.yml`; the Chunkah field names and numbers held equal across the entry, AGENTS.md's diagnosis and the rechunk step's comment, with the cap's arithmetic checked; the corrected `README.md` → `AGENTS.md` direction both ways, the historical `renovate.json5` path's absence, the coverage-gate trigger as the complement of `build.yml`'s ignore list, and `docs/risk-tiers.md`'s tier order; and every `docs/reflections/<file>` cited from a non-Markdown file resolving to a tracked file |
| `test-pull-request-template.sh` | `.github/pull_request_template.md`: every claim in the checklist against the thing it restates — the suite command against the `run:` steps that invoke it, the shellcheck caveat against `test-shell-syntax.sh`'s skip and a straight-line `apt-get install -y shellcheck` step earlier in every job that runs the suite, with no `if:` or `continue-on-error:` on the step or its job, no effective shell other than bash, and no control flow around it, the scripts it calls unreachable against `test-coverage.sh`'s `UNCOVERED` set and the `Containerfile`'s `/ctx/` invocations, `post-check.sh`'s exception against its `BASH_SOURCE` guard, the `Build container image` name and `pull_request` trigger against `build.yml` with every step of `build.yml` classified in a manifest as safe on a pull request (its action and body free of push, copy, login and sign mechanisms) or guarded (its `if:` one unnegated `&&` chain carrying `github.event_name != 'pull_request'` whole) and every job classified as one that runs steps of its own or as a guarded reusable-workflow call, an unclassified step or job failing, the load-bearing-prose status of README.md and AGENTS.md against `docs/risk-tiers.md`'s tier 1 row, and the skew diagnosis headings a reviewer is sent to against AGENTS.md — plus the structure GitHub renders: one template at the path it reads, its five sections, and no pre-ticked box |
| `test-risk-tiers.sh`        | `docs/risk-tiers.md`: the tier table parsed and replayed rather than restated — every glob in the Paths column resolved against `git ls-files`, the "highest tier it touches" rule applied to the worked example the document states, the merge-on-green column agreed with `docs/SECURITY-AI.md`'s unattended lists, the push/verify/sign steps the tier 3 row names found in `build.yml` and each one carrying the `github.event_name != 'pull_request'` guard, the tier 3 evidence bullets against the `Containerfile`'s `post-check.sh` and `bootc container lint` `RUN` steps and against the absence of either after the rechunk step, `--rechunk` as a real mode of `tests/e2e/run-e2e.sh`, the `paths-ignore` claim replayed so a docs-only pull request starts no build and a `Containerfile` one does, and the "no bot stamps a tier" claim as an absence in `.github/labeler.yml`'s labels, in the labels those rules return for a file from each tier, and in every workflow — plus every `/`-bearing path the prose names, with `.github/renovate.json5` asserted still absent because the paragraph about issue #70 depends on it |
| `test-signing-key.sh`       | `cosign.pub`: the committed half decoded and checked as a P-256 public key rather than described, the private half hunted for across every tracked file, and every instruction that names the key — README.md's install command, `policy.json` entry, verification command and rebase example, and `docs/SECURITY-AI.md`'s claims about where `SIGNING_SECRET` lives — held against `.github/workflows/build.yml`, `.github/workflows/nightly-compliance.yml`, the `Containerfile`, `.gitignore` and `.claude/settings.json` |
| `test-harness.sh`           | the harness itself: `lib/assert.sh`'s tally and every assertion's failing branch, and `run-tests.sh`'s dependency preflight, discovery, failure reporting, and selection — including that a selection argument resolves to a `test-*.sh` in the runner's own directory and to nothing else |

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

`test-docs-paths.sh` applies the same idea to the prose. README.md is the public
entry document and sends readers with a failed build to AGENTS.md, so a path
either document names that does not exist is a real defect — README.md
advertised `.github/renovate.json5` for some time while the file was
`renovate.json` at the repo root. It checks the
"Repository Layout" block line by line, then the inline code spans, anchoring
the filter on `git ls-files` so that GitHub `org/repo` references are skipped
while anything rooted in a real top-level entry is enforced.

`test-manual-input-check.sh` takes the next step: from "the paths this document
names exist" to "the values this document names are still the repo's". The
document it covers is the whole procedure for moving `ARG FEDORA_VERSION`, and
it deliberately ships no script, so every command in it is a copy of something
that lives in the `Containerfile` or `build_files/post-check.sh` — the two
artifact references and their tag template, the payload directories copied out
of them, the ZFS package names that have to agree, the `rpm --qf` query whose
answer the reader carries forward, and the `ARG` defaults the base image guard
rests on. A copy drifts in silence: renaming a build stage or adding a package
to `check_zfs_packages` leaves a reader checking the wrong inputs against the
wrong image immediately before the one change this document exists to gate. So
nothing is typed in twice — each expectation is computed from the other side
and compared, including the worked "Fedora N to N+1" example, which is an
instruction rather than an illustration and is held to this repo's current
release and the one after it. The extractions fail when they match nothing,
because a renamed heading that quietly verifies an empty set is the same
outcome as no test.

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

## The signing key

`test-signing-key.sh` covers the file that nightly check verifies against.
`cosign.pub` is the trust anchor: `docs/risk-tiers.md` puts it in tier 3 and
`docs/SECURITY-AI.md` ranks its private half above every other secret here, and
before this test a dozen `grep -rF cosign.pub tests/` hits all used the path as
a payload or a classification target. Not one of them opened it.

Nothing in this repository notices if the key is wrong. `build.yml` signs with
`env://COSIGN_PRIVATE_KEY` and never reads the committed file; the only things
that do are the nightly re-verification — stubbed, correctly, in
`test-nightly-compliance.sh` — and a consumer's host. So the bytes are decoded
here rather than described: one PEM block and nothing outside it, a 91-byte
SubjectPublicKeyInfo, the `id-ecPublicKey` and `prime256v1` OIDs and an
uncompressed point, each asserted by name so a failure says which part moved.
The same pass hunts the private half: no tracked file carries a private-key PEM
marker, `.gitignore` still ignores `cosign.key`, and nothing tracked matches any
path the `Read(...)` deny rules in `.claude/settings.json` name — read out of
that file rather than restated, so a name added there is swept too.

The other half is the instructions. README.md tells a user to install the key
into `/etc/pki/containers/` and to add a `sigstoreSigned` entry to
`/etc/containers/policy.json`, and that entry fails *open* if it drifts: a host
whose `signedIdentity` pins a repository the workflow no longer publishes to
rejects everything, or accepts the wrong thing, and finds out at
`bootc upgrade`. So the published reference is derived once — from the slug
README.md's own build badge links to, with the derivation grounded in
`build.yml`'s `IMAGE_REGISTRY` and `IMAGE_NAME` expressions and its lowercasing
step — and the install command, the policy entry (parsed with `jq`, not matched
as text), the `cosign verify` command and the `--enforce-container-sigpolicy`
rebase are all held against it. Every concrete `ghcr.io` reference in README.md
has to be that image or one the `Containerfile` actually pulls, in both
directions, so a typo in the policy key fails rather than instructing a reader
to pin nothing.

`docs/SECURITY-AI.md` is joined the same way. Its claim that
`COSIGN_PRIVATE_KEY` "exists only in the signing step of `build.yml`" is
recomputed — exactly one workflow is handed `secrets.SIGNING_SECRET`, exactly
one step in it holds the value — and its secret-inventory row is parsed for the
step it names rather than read. The `gh secret set` example is checked to name
this repository and to pass the key by redirection, and the
`cosign public-key --key cosign.key` recipe to name the same private path
`.gitignore` and the permission table do: a rename on one side and not the
others is how a private key becomes trackable.

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

## The memory

`.claude/memory/corrections.md` is the one document here written to be believed
without being checked. Every agent configuration in the tree points a reader at
it before the code, and each entry is a claim about how the build behaves today,
phrased in the past tense of an incident that is over. Nothing opened the file:
`test-coverage.sh` sees only shipped `*.sh`, and `test-docs-paths.sh` resolves
what README.md and AGENTS.md name, not what the memory cites.

That combination fails in one direction. Move the Chunkah step, change what
`--config-str` is handed, drop the `shellcheck` skip branch, or renumber the
upstream PRs AGENTS.md sends a reader to, and the memory keeps confidently
describing the previous repository — to exactly the reader who came here to
avoid rediscovering something. So `test-memory-corrections.sh` computes every
literal from the file the entry cites and compares it with what the entry says:
the size cap, layer counts and exit code out of the rechunk step's own comments,
the hidden PR numbers out of AGENTS.md's sentence about them, the skip notice
out of `test-shell-syntax.sh`'s own `printf`.

Two of its checks are structural rather than textual. The four labels an entry
carries are paired with the sentences in `.claude/memory/README.md` that ask for
them, and both directions are asserted, so a label nobody declared fails rather
than going unchecked. And a citation counts as a path when it has a directory
component, when its suffix is one the tree tracks, *or* when its stem names a
tracked file — the last rule is what stops a rename to `post-check.bash` from
escaping as an unrecognized token that is therefore never resolved.

`test-agent-prompts.sh` already holds the Containerfile's two akmods `FROM`
lines to one tag and `kernel-akmods.sh` to erasing the base module tree. Both
properties are reached here from the other side, through AGENTS.md's pin example
and its 60-second diagnosis, which is where a reader mid-incident meets them.

## The Cursor rules

`.cursorrules` is the same kind of surface one step further out: Cursor loads it
before every edit, and nothing opened it either. `grep -rl cursorrules tests/`
returned two hits and neither read the file — `test-labeler.sh` asserts the path
matches the `area/agents` glob, and `test-memory-corrections.sh` names it in a
comment listing the agent configuration.

Its rules are instructions rather than notes, which makes a stale one act
immediately. Two were already wrong when `test-cursorrules.sh` was written. The
two-space exception list named only `ci/write-badges.sh` while `.editorconfig`
declares `.claude/hooks/gate-git-diff.sh` as well, so an agent following the
rules would have written a four-space diff into a two-space script. And the
shebang rule claimed every `*.sh`, when `lib/assert.sh` and `lib/markdown.sh`
are sourced and deliberately carry neither — which is exactly why
`test-shell-syntax.sh` skips them by name. Both lines were corrected with the
test that now holds them.

The rest is computed rather than restated: the artifacts out of the
`Containerfile`'s `FROM` stages, the two compared kernels out of
`write-badges.sh`'s own `from_ref` calls, the `kmod-zfs` glob and the absence of
a `|| true` out of `build_files/zfs.sh`, the two-space set out of
`.editorconfig`'s sections, and the three scripts no host test reaches out of
`test-coverage.sh`'s `UNCOVERED` column — both directions, so neither side can
gain a script alone. Where a rule is a judgement rather than a claim — "write in
the same register", "most red builds here are caused upstream" — it is left
alone.

`test-quality-docs.sh` already holds the run-by-path shebang rule as
`docs/review-rubric.md` states it, and `test-editorconfig.sh` measures the
indentation itself. This file asks the other question: whether `.cursorrules`
still describes the sets those two enforce.

## The Copilot instructions

`.github/copilot-instructions.md` is the same surface again, for a third
reader: GitHub loads it automatically before every Copilot suggestion in this
repository, and `grep -rF .github/copilot-instructions.md tests/` returned one
hit that does not read it — `test-labeler.sh` asserting the path matches the
`area/agents` glob.

It had drifted in exactly the pair of places `.cursorrules` had, and the pair
survived the correction: when `test-cursorrules.sh` fixed the short two-space
list and the overstated shebang rule in `.cursorrules`, the same two sentences
in `.github/copilot-instructions.md` were left as they were. So an agent taking
its instructions from GitHub rather than Cursor would still have written a
four-space diff into `.claude/hooks/gate-git-diff.sh` and `chmod +x`'d
`lib/assert.sh` and `lib/markdown.sh`. That is the argument for the test rather
than the edit: correcting prose nothing reads postpones the next copy instead of
stopping it. Both sentences are corrected here, and `test-copilot-instructions.sh`
now holds them — with the two-space list and the `tests/lib/` exemption compared
across all three documents that state them, `.cursorrules` and CONTRIBUTING.md
included, so a correction applied to one document alone fails.

Two of its sections are checked in ways the Cursor rules did not need. Its link
to AGENTS.md is relative and resolved from `.github/`, which is where GitHub
resolves it, so a move of either file fails rather than rendering a dead link
in the document Copilot reads first. And its "When writing comments" section
names three specific comments — the `.Config`-only `podman inspect`, the badge
script's refusal to guess, the push-once-then-copy tag propagation — and tells
an agent not to remove them; each is held against the code that carries it, and
the first one also as an absence, because an unformatted `podman inspect` added
beside it is the `MAX_ARG_STRLEN` failure the comment exists to record.

## The session summary

`.claude/session-summary.md` is the third file in that family and the one with
the shortest path to a wrong action. It is written for an agent that has read
nothing else, and its claims are almost all negative or procedural: neither
akmods input is pinned, nothing validates the image after Chunkah, the
openzfs/kernel badge can outlive the skew it described, run this snippet before
acting on it. A reader who believes one of those after it stops being true has
no reason to doubt it — which is the failure the document's own opening warns
about, aimed at itself: "a stale entry here is worse than an empty file, because
the next agent will act on it."

Nothing opened it before `test-session-summary.sh`. `test-coverage.sh` sees only
shipped `*.sh`, `test-docs-paths.sh` resolves what README.md and AGENTS.md name,
and `test-editorconfig.sh` reads the file as bytes to classify its indentation
rather than as claims.

So each claim is computed from the file it is about. The Fedora major is
compared as a number against `ARG FEDORA_VERSION`, so a bump fails here rather
than leaving the summary asserting 44. "Neither akmods input is pinned" is both
`FROM` lines checked for a digest and for the `FEDORA_VERSION` they still float
on. "`docs/` is in `build.yml`'s `paths-ignore`" is asserted for every trigger
that filters paths at all, because the reassurance it supports — a docs-only
branch showing no checks is config, not breakage — needs all of them. The open
thread about Chunkah is an ordering, so the ordering is what is asserted, and
the one remedy the summary offers is held to verifying the rechunked tag rather
than the built one. The badge is named by `ci/write-badges.sh` rather than
spelled here, and the leave-the-badge-alone branch the "confirm it against the
live labels" paragraph rests on is asserted on both halves: the inspect that
degrades to empty, and the branch that then writes nothing.

The snippet at the end is the one block a reader executes rather than believes,
so it is executed: the `sed` line runs against the real `Containerfile` and has
to return the same Fedora major, the two images it loops over have to be the two
the `Containerfile` pulls, and its `docker://` reference is expanded and
compared with each `FROM` line. A pin edited during an outage — the documented
workaround — cannot leave the snippet inspecting images the build no longer
uses, which is the trap `write-badges.sh`'s own comments describe.

`test-memory-corrections.sh` already holds the `Containerfile`'s trailing check
order and the rechunk's place in `build.yml`. Both are reached here from the
other side: that test asks what an incident record claims, this one asks whether
the summary's "Open threads" still describes today's pipeline.

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

Selection is also a permission boundary, which is why the sandbox holds files
outside the runner's directory as well as inside it. `.claude/settings.json`
allow-lists `Bash(./tests/run-tests.sh:*)`, so any path the runner is willing to
`bash` is a path that runs without a prompt, and allowing a script is allowing
whatever that script runs — the permission table gates the Bash tool's argv, not
what an approved command then executes. A selection argument therefore resolves
to a `test-*.sh` in the runner's own directory or fails with `not a test file
in`, which is a different message from `no such test` so a mistyped path is
still diagnosable. What remains reachable is a file written at
`tests/test-*.sh`, which the no-argument glob would run anyway.

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

## The map itself

`test-coverage-map.sh` applies the same idiom one level up, to the document you
are reading. The table above and the "Not covered" list are how a contributor
decides whether something is already tested and, if it is not, whether that was
a decision or an oversight — and until this test existed nothing joined either
to the tree. `test-quality-docs.sh` was the only file here that opened it, and
only to confirm one sentence about the covered-or-`UNCOVERED` decision; every
other mention of the path in `tests/` is a comment, a labeler fixture, or
`test-editorconfig.sh` reading it as bytes.

Both halves had already drifted, in the two directions that matter. The table
had no row for `test-agent-prompts.sh` or `test-containerfile.sh`, so neither
was reachable from the map; both rows are added with this test. And the "Not
covered" section said `.github/copilot-instructions.md` was unchecked while
`test-copilot-instructions.sh` sat in the table twenty lines above it. That
second one is the failure a gaps document has: a reader trusts it to say where
the holes are and stops looking, so understating coverage sends somebody to
write a test that exists and overstating it leaves a hole nobody checks.

So the table's first column is compared with `git ls-files 'tests/test-*.sh'` in
both directions, and the list is compared with `test-coverage.sh`'s `UNCOVERED`
column in both directions. The second comparison is deliberately made against
that manifest rather than against a `grep` of the suite: being *named* by a test
is not being *covered* by one. Nine test files name `build_files/zfs.sh` — to
record it as `UNCOVERED`, to check its mount contract, to read its `kmod-zfs`
glob, to classify its path — and not one of them executes a line of it, so a
name-based rule would fail on the entry the list most needs to keep. The
manifest is where this repository already records that difference, so the list
is held to it rather than to a second copy of it.

Both extractors are run against a fixture with known answers first, for the
reason `test-ci-workflows.sh` and `test-containerfile.sh` do the same: a parser
that silently matched nothing would report a clean map of an empty set. The
reasoning paragraphs are left alone — a sentence about why a pinned third-party
action has no shell of this repository's to run is judgement, not a claim the
tree can settle.

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

Nothing under `.github/` is left unopened. `copilot-instructions.md` was the
last entry on this list, on the reasoning that what it holds is advice to a
reader rather than a claim about the tree; `test-copilot-instructions.sh` now
recomputes every instruction in it that names something here, and the reasoning
that retired it is the one the paragraph below states.

That list used to include `.github/prompts/**` and `pull_request_template.md`,
on the reasoning that prose read by a human or an agent is not parsed and so is
not assertable. That reasoning was wrong twice. The prompts restate the
procedure the workflows and the `Containerfile` implement, which is what
`test-agent-prompts.sh` holds them to; the pull request template restates the
suite command, which build scripts no test can reach, what a pull request build
does not do, and where a reviewer is sent when the build is red — all of it
written down somewhere else in the tree, and all of it now recomputed from there
by `test-pull-request-template.sh`. The third pass was no protection either way:
the template contains no Markdown links at all, so the pass that was supposed to
cover it never looked at it, and the pass that checks path-shaped code spans
reads README.md and AGENTS.md only.

The distinction that survives is not human-readable versus machine-readable. It
is whether a sentence restates something the tree already decides. Where it
does, the sentence can be recomputed and drift fails the suite; where it is
advice, judgement or an instruction to a reader, there is nothing to compare it
against and these tests leave it alone.

The repository paths this section claims are unreached are listed here rather
than left in its prose, because a list can be joined to the tree and a sentence
cannot. `test-coverage-map.sh` reads it, and reads nothing else in this section:
every entry has to be a tracked file that `test-coverage.sh` still records as
`UNCOVERED`, and every `UNCOVERED` entry there has to appear below. A path that
acquires a covering test fails here instead of sitting on the list, which is how
the `copilot-instructions.md` sentence above went wrong.

- `build_files/build.sh`
- `build_files/kernel-akmods.sh`
- `build_files/zfs.sh`

Those three still run their work at the top level, so `source` executes the
whole file. Their happy path is exercised by the `Build container image`
workflow — a failure there blocks the push — and their failure branches remain
untested. Their contract with the `Containerfile` is a different claim and is
checked: `test-containerfile.sh` holds each mount destination against the
absolute paths the script reads.

The gaps above this list are not paths. `check_zfs_modules`,
`check_zfs_userspace` and `check_initramfs` are functions inside a covered file,
and the `uses:` steps of `build_push` are third-party actions with no path in
this repository, so neither can be listed or joined that way.

## The agent settings file

`.claude/settings.json` is not prose. It holds a `PostToolUse` hook — a shell
one-liner that runs `shellcheck -x` over every `*.sh` an agent writes and, by
exiting 2, blocks the edit — and a permission table whose `deny` list is what
stands between an agent and `cosign.key`, `podman system prune` and
`git push --force`. Both halves fail open and fail silently: a settings file
that does not parse as JSON is ignored in full, `deny` rules included, and a
misspelled event or tool name registers a hook that is never dispatched.

`test-claude-settings.sh` extracts that hook command with `jq` and runs it,
feeding it the same `{"tool_input":{"file_path":…}}` payload Claude Code does
and answering it with a recording `shellcheck` stub, from a working directory
that is not the repository. That last detail is the point of the exercise: the
hook's `cd "$CLAUDE_PROJECT_DIR"` is load-bearing, because `shellcheck -x`
resolves a `# shellcheck source=tests/lib/assert.sh` directive relative to the
working directory. Without the `cd`, editing any file under `tests/` comes back
as SC1091 and a cascade of SC2034s — a blocked edit on a file
`test-shell-syntax.sh` calls clean. The band that needs the real tool asserts
exactly that, on a committed file, and skips when `shellcheck` is not installed,
the same way `test-shell-syntax.sh` does.

The stub is what makes the rest cheap: its exit code, argv and working
directory are all asserted, and the cases where it must *not* run — a `.md` or
`.json` path, a payload with no `file_path`, no `shellcheck` on `PATH` — check
that it was never invoked. The `*.sh` filter is held against
`test-shell-syntax.sh`'s `-name '*.sh'` selection, so the hook and the gate
cannot come to disagree about which files have to be clean.

The file holds a second hook, on `PreToolUse`, for a hole the permission table
cannot close. `Bash(git diff:*)` is on the `allow` list, and
`git diff --no-index` compares two paths as plain files rather than as
repository content — so the pre-approved command prints any file this uid can
open, `cosign.key` and a `.env` included. The `Read(...)` rules that name those
paths gate the Read tool and have nothing to say about Bash, and no rule can
take their place: patterns match by prefix and flags may appear in any order, so
a narrower `allow` admits the flag anyway and a `deny` for it matches one
spelling of the command. A hook is handed the whole command string, so it can.

`test-claude-settings.sh` runs that one too, and starts by demonstrating what it
is for: `git diff --no-index` against a fixture in the test's own temp directory
has to print the fixture's contents. Then the hook itself — refusing the command
from the finding and three variants that put the flag somewhere a prefix rule
would miss, and leaving `git diff`, `git diff --stat`, `git status` and a
payload with no command in it alone, because a hook that turned the allow rule
back into a prompt would have traded one problem for the one it replaced.

Two filters agreeing is not the same as either one being complete, and the
suffix is the third selection of its kind: `test-coverage.sh` takes
`git ls-files '*.sh'` before it demands a covered-or-`UNCOVERED` decision. A
shell script named without the suffix sits outside all three at once — never
`bash -n`'d, never shellchecked, never required to record a coverage decision,
never linted at write time — and nothing fails. So `test-shell-syntax.sh` also
asserts that no tracked file is a shell script under another name: a shell
shebang, or the executable bit with no interpreter line at all, on a path that
does not end in `.sh`. A shebang naming another interpreter is exempt; a Python
helper has no business being called `*.sh`. `git ls-files` returning nothing
fails rather than passing, because an empty list would satisfy the assertion
without checking anything.

For the permission table the assertions are joins rather than a second copy of
the list. No `allow` rule may cover a command the `ask` or `deny` list gates —
adding `Bash(podman:*)` to `allow` stops the agent being asked before
`podman rmi`. The two `_note_*` keys are held against the rules they explain, so
the recorded reasoning and the table cannot drift apart. And the rules that name
files are checked against the tree: `cosign.key` and `.env` are denied to
`Read`, gitignored, and tracked by nothing, which is the order those three
defences belong in.

`build.yml` does not `paths-ignore` `.claude/**`, so a change to that file runs
this suite.

## The editor settings

`.editorconfig` opens by saying it "encodes the conventions already in the tree
rather than proposing new ones". That is the whole contract, and it is a claim
about every tracked file rather than a preference — which makes it testable, and
makes it rot silently. `test-editorconfig.sh` measures it.

The consequence of drift is a diff. EditorConfig does not reformat anything on
its own, but an editor acts on it: a file whose real indentation differs from
the `indent_size` its editor believes gets reindented by the next person who
touches it, and the formatting noise lands in a PR about something else. That is
exactly the diff the file exists to prevent, so a stale rule is worse than none.

It had already drifted. `.claude/hooks/gate-git-diff.sh` arrived with the
`git diff --no-index` gate and is written two-space, while `[*.sh]` declares four
and a comment named `ci/write-badges.sh` as "the one exception in the tree". The
two-space set is now asserted in both directions — every script measured at two
spaces must be declared, and every script declared at two must measure that way
— so the third one to arrive fails whichever side it lands on.

Resolution is last-match-wins over the sections, with globs that are not
fnmatch: a pattern with no separator matches at any depth, `**` crosses
separators, `{a,b}` is an alternation. The matcher is hand-rolled here and
carries its own case table, because a matcher that quietly matched everything
would make every assertion resting on it vacuously true.

The two measurements are picked around the same trap. Most-common-step is right
for shell only once heredoc bodies are skipped — the tests embed YAML, JSON and
Python fixtures, and a measure that reads those reports the fixture's language.
It is wrong for YAML outright: `.github/labeler.yml` steps by four at its nested
sequences while the file is two-space, so YAML and JSON are measured by their
first nesting level instead. Markdown and Python are not measured at all and the
file says so: a list continuation and a line wrapped to an open parenthesis both
indent to an alignment column, which is not an indent step.

The rest of the file's prose is joined to what it describes. The note arguing
against a Prettier config rests on nothing running one, so no tracked Prettier
config and no `prettier` invocation are both asserted; its alternative — "shell
style is enforced by `.shellcheckrc`, which CI actually runs" — is only true
while every workflow that runs this suite installs `shellcheck` first, since
`test-shell-syntax.sh` skips that pass when the binary is missing and stays
green. `.shellcheckrc`'s own reason for leaving `require-double-brackets` off
names `ci/write-badges.sh`; `.editorconfig` names it for the same style from the
other side; neither file mentions the other, and the fact underneath both is
measured here.

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
