# Session summary

State of play for an agent picking this repo up cold. `AGENTS.md` says how the
repo *works*; this says what is currently *in flight*, which is the part git
history does not make obvious.

Rewrite it at the end of a session that changes the answer. Delete anything that
has landed — a stale entry here is worse than an empty file, because the next
agent will act on it.

---

**Last updated:** 2026-09-19

## Where things stand

`main` is the maintained AMD/non-NVIDIA branch. The NVIDIA variant lives on
`nvidia-legacy`, tagged `nvidia-last-known-good-2026-05-31`, and is unmaintained.

Neither akmods input is pinned. `FEDORA_VERSION` is 44. If either changes, the
reason belongs in `AGENTS.md`'s incident log, not here.

## In flight

Nothing is currently in flight.

`docs/` is in `build.yml`'s `paths-ignore`, so a docs-only branch may show no
checks at all. That is the workflow config, not a failure.

## Open threads worth knowing about

**Nothing validates the image after Chunkah.** `post-check.sh` and `bootc
container lint` are `RUN` steps, so they run before the rechunk; the re-layered
archive is loaded, tagged, pushed and signed unchecked. `tests/e2e/run-e2e.sh
--rechunk` closes this loop locally but nothing does in CI. Worth running after
a Chunkah version bump.

**The Chunkah pin is a semver tag, not a digest**, and `renovate.json` disables
digest updates for it deliberately. Do not "fix" that without checking whether
the maintainer wants the tradeoff changed.

## Before you start anything

Check the OpenZFS/kernel badge. If it says `blocked`, upstream akmod skew is the
likely cause and the response — wait, pin both inputs, or switch streams — is in
`AGENTS.md`.

**Confirm it against the live labels before acting on it.** `ci/write-badges.sh`
deliberately leaves a badge at its last value when it cannot read an input, so
`blocked` can outlive the skew it described: a transient registry error during
the daily run is enough, and the badge will then still say `blocked` after
upstream has re-converged. That is the badge working as designed, not a bug, but
it means the badge is a strong hint and not a verdict.

```bash
FEDORA_VERSION=$(sed -n 's/^ARG FEDORA_VERSION=//p' Containerfile)
for img in akmods akmods-zfs; do
  printf '%-12s %s\n' "$img" "$(skopeo inspect --format '{{ index .Labels "ostree.linux" }}' \
    "docker://ghcr.io/ublue-os/${img}:coreos-stable-${FEDORA_VERSION}-x86_64")"
done
```

Identical labels mean the skew has cleared and the red build is something else —
investigate it rather than waiting. Only a live mismatch justifies "do not
attempt a code fix".
