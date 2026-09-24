# Risk tiers

How to classify a change here, what evidence each tier needs before it merges,
and — the part that is easy to get wrong — what CI actually proves at each tier.

The tiers are not about diff size. A one-line change to the `Containerfile` can
produce an unbootable host; a 400-line test file cannot. They are about **blast
radius**: who or what is damaged if the change is wrong, and how it is noticed.

## The tiers

| Tier                       | Blast radius                                                                     | Paths                                                                                                        | Merge on green CI alone?                                     |
| -------------------------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------ |
| **3 — Published artifact** | A wrong change ships signed bytes, a host that will not boot, or an agent that can reach past the deny list | `Containerfile`, `build_files/**`, the push/verify/sign steps of `.github/workflows/build.yml`, `cosign.pub`, `.claude/settings.json`, `.claude/hooks/**`, `.github/rulesets/**` | **No.** Needs a human and stated evidence.                   |
| **2 — Pipeline**           | A wrong change breaks or silently degrades the build, badges, or dependency pins | other parts of `.github/workflows/**`, `ci/**`, `renovate.json`, `.github/dependabot.yml`                    | No. Needs a human, but CI is meaningful evidence.            |
| **1 — Load-bearing prose** | A wrong change misleads a human or an agent mid-incident                         | `README.md`, `AGENTS.md`, `CONTRIBUTING.md`, `docs/**`, `.github/prompts/**`, `.claude/**`                   | Yes, if the doc-path suite is green and a human has read it. |
| **0 — Self-checking**      | A wrong change fails in front of the person who made it                          | `tests/**`, `.editorconfig`, `.shellcheckrc`, `.gitignore`                                                   | Yes.                                                         |

When a change spans tiers, **it takes the highest tier it touches.** A pull
request that edits `tests/` and one line of `build_files/` is Tier 3.

## Why Tier 1 is not the bottom

In most repos, docs are the safe tier. Here they are not: the public
[`README.md`](../README.md) sends a reader handling a broken build to the
diagnosis in [`AGENTS.md`](../AGENTS.md). A path or a behaviour claim that has
drifted is therefore an input to an incident response, and a wrong one sends
the responder somewhere that does not exist.

That is not hypothetical.
[#70](https://github.com/Danathar/aurora-zfs-simple/issues/70) was exactly this:
`README.md` advertised `.github/renovate.json5` while the file was
`renovate.json` at the repo root. `tests/test-docs-paths.sh` exists because of
it — see [`docs/reflections/`](reflections/).

Tier 1 sits above Tier 0 for that reason, and only below Tier 2 because a
misleading doc still needs a human to act on it before it does damage.

## Why two files under `.claude/` are Tier 3

Most of `.claude/` is Tier 1 prose — `.claude/commands/**` point at the
procedures in `.github/prompts/`, `.claude/memory/**` and
`.claude/session-summary.md` record what past sessions learned. Two files are
not prose at all, and the table names them in the top row so that the
highest-tier rule above puts a change to either of them there:

- `.claude/settings.json` is the permission table. Its `deny` list is what
  stands between an agent and `cosign.key`, `cosign sign`, `git push --force`
  and `podman system prune`, and its `hooks` block is what registers the
  `PreToolUse` gate at all.
- `.claude/hooks/gate-git-diff.sh` is that gate. It re-gates the allow-listed
  commands that otherwise reach past every `Read(...)` deny rule — the whole
  corpus is in the `_note_*` keys of `.claude/settings.json` and in
  [`tests/test-claude-settings.sh`](../tests/test-claude-settings.sh), which
  opens by saying the settings file is not documentation.

The difference from Tier 1 is what a wrong change does. A drifted document is
read by a human who then acts on it; a widened allow rule or a weakened refusal
is executed, unprompted, by the next agent that runs here — including the agent
that proposed the change. That is the one edit a pull request cannot be reviewed
by its own result, so it takes a human, the way signing does.
[`docs/SECURITY-AI.md`](SECURITY-AI.md) lists it among the changes that need a
human decision first.

## Evidence, by tier

What to write in the pull request. The template asks; this says what a good
answer looks like.

**Tier 3.** A green `Build container image` run on the pull request is the
strongest evidence available, and it is *not* proof:

- it builds the whole image and runs `build_files/post-check.sh` and
  `bootc container lint` inside it, publishing and signing nothing — so it
  proves the image assembles and passes its own consistency checks;
- it does **not** validate the artifact on the far side of the Chunkah rechunk,
  which is what actually gets pushed and signed
  ([`docs/quality.md`](quality.md#what-each-one-does-not-cover) is blunt about
  this);
- it does **not** prove a pool imports or that the image boots. No CI job here
  does.

So a Tier 3 pull request says which of those gaps it is exposed to, and how it
was covered — a local `tests/e2e/run-e2e.sh --rechunk` run, a rebase onto a real
machine, or an explicit "not verified beyond the build."

**Tier 2.** Say what would break if the change is wrong and how you would
notice. Workflow changes are hard to test before merge; that is a reason to be
explicit, not a reason to skip it. Anything touching publishing, signing or tag
propagation is Tier 3, not Tier 2, regardless of which file it lives in.

**Tier 1.** Run `./tests/run-tests.sh` locally and say so. A docs-only pull
request starts no `Build container image` run at all — `build.yml` sets
`paths-ignore` for `README.md` and `docs/**` — which is why
`.github/workflows/coverage-gate.yml` exists to run the suite on exactly that
complement.

**Tier 0.** Green suite is the evidence.

## The classification is advisory

There is no bot that stamps a tier on a pull request, and this file does not
create one. It is a shared vocabulary so that "this is Tier 3, I only have a
green build" is a complete and honest statement, and so that a reviewer knows
what to ask for.

Two related documents: [`docs/SECURITY-AI.md`](SECURITY-AI.md) lists the changes
an agent may not make unattended — the overlap with Tier 3 is not a coincidence
— and [`CONTRIBUTING.md`](../CONTRIBUTING.md#changes-that-need-a-conversation-first)
lists the changes that need an issue opened before the work starts.
