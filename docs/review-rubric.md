# Review rubric

What to actually look at in a pull request here, ordered by how much damage the
mistake causes. This is not a generic checklist — it is the set of things that
have gone wrong, or would be expensive if they did.

## 1. Does it move a failure from the build to the boot?

The highest-severity mistake available in this repo, and it looks like a fix.

Loosening the `kmod-zfs` glob in `build_files/zfs.sh`, making that install
non-fatal, relaxing a `post-check.sh` assertion, or removing the
`Containerfile`'s Fedora guard will all turn a red build green. They do it by
deleting the check that was protecting the boot. A `kmod-zfs` built for a
different kernel does not load, and the user finds out after rebasing.

**Reject on sight** unless the PR argues specifically why the check was wrong,
not merely inconvenient.

## 2. Are both akmods inputs pinned, or neither?

Pinning one `FROM` line and not the other recreates the exact skew a pin is
meant to escape. If a PR pins, check that both lines carry the same
kernel-pinned tag and that the PR shows their `ostree.linux` labels matching.

Also check there is a note saying what would let the pin be removed. A pin
freezes the image on an unpatched kernel until someone remembers, and nobody
remembers.

## 3. Does it claim something the code does not do?

`README.md` is the entry document, and directs readers handling a failed build
to `AGENTS.md`. A documentation claim that has drifted is a real defect here,
not a nit — #70 was exactly that: the README described digest-level pinning the
repo does not implement, so a reader would have assumed a supply-chain
guarantee that was not there.

For any behavioural claim in a diff, find the line of code that makes it true.
Pay particular attention to claims about *ordering*, which are easy to get
backwards.

## 4. Is a comment explaining an incident being removed?

Several comments here encode a specific past failure: the `.Config`-only
`podman inspect` that works around `MAX_ARG_STRLEN`, the badge script refusing
to guess when an input is unreadable, the push-once-then-copy tag propagation.

Each looks like something to tidy up. Deleting one deletes the reason the code
is shaped that way, and the incident recurs. If a PR removes or rewrites one,
the PR needs to say why it no longer applies.

## 5. Shell quality

- `shellcheck -x` clean, zero output, informational findings included. Where a
  finding is genuinely wrong, a `# shellcheck disable=SCxxxx` with a comment
  explaining why beats reshaping the code around it.
- Shebang and executable bit on anything run by path — the `Containerfile` and
  the workflows do exactly that.
- `set -euo pipefail` on anything executed, with the exceptions
  `CONTRIBUTING.md` names: the build scripts add `x`, and the test runner,
  every `tests/test-*.sh` and `.claude/hooks/gate-git-diff.sh` use
  `set -uo pipefail`.
- New scripts: is there a seam that makes them testable? `post-check.sh` is
  covered *because* someone guarded its entry point with `BASH_SOURCE`. The
  others are not, because they do their work at the top level.

## 6. Was it verified, and could it have been?

The question is not "are there tests" but "was the right kind of evidence
offered":

| Change to                       | Evidence                                                                                         |
| ------------------------------- | ------------------------------------------------------------------------------------------------ |
| `ci/write-badges.sh`, `tests/`  | The shell suite, run with `shellcheck` installed                                                 |
| `build_files/`, `Containerfile` | A green `Build container image` run on the PR, or an explicit statement that it was not verified |
| Workflows                       | Reason carefully; a workflow change is often only testable by merging                            |
| Docs                            | Read the code it describes                                                                       |

"Tests pass" on a `build_files/` change means nothing — the suite cannot reach
that code. A PR that says "not verified, here is why" is more useful than one
that implies coverage it does not have.

## 7. Secrets and signing

Anything touching `cosign.key`, `SIGNING_SECRET`, or the signing step gets read
line by line. Check that no key material can reach a log, and that signing
still applies to the same digest that was verified.

## Severity

- **Blocking** — 1, 2, 7, and any doc claim that is actively false.
- **Should fix** — 3, 4, 5.
- **Discuss** — 6, when the honest answer is "not verified" and the risk is
  acceptable.
