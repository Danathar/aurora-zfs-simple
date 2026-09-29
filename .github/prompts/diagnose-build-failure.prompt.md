---
description: Work out why a Build container image run is red, with evidence
mode: agent
---

# Diagnose a failed build

Goal: name the cause with evidence, and say which fix applies. Not: make the
build green by any means available.

## 0. Cheapest check first

Look at the **OpenZFS/kernel** badge in `README.md`. It is derived from the same
two labels step 1 reads. If it says `blocked`, you already have the answer and
can skip to step 3.

## 1. Confirm or rule out skew

Only the two akmods labels decide this.

```bash
FEDORA_VERSION=$(sed -n 's/^ARG FEDORA_VERSION=//p' Containerfile)
for img in akmods akmods-zfs; do
  printf '%-12s %s\n' "$img" "$(skopeo inspect --format '{{ index .Labels "ostree.linux" }}' \
    "docker://ghcr.io/ublue-os/${img}:coreos-stable-${FEDORA_VERSION}-x86_64")"
done
```

**Differ** → skew. Go to step 2.
**Identical** → not skew. Go to step 4.

Do not treat a differing `aurora-dx` kernel as skew. `kernel-akmods.sh` erases
Aurora's kernel outright; this image legitimately runs a newer kernel than
Aurora stable whenever the akmods stream is ahead. That is the design.

## 2. Confirm the failure matches the diagnosis

Skew always dies inside `zfs.sh`, on the `kmod-zfs` glob, while the ZFS
*userspace* RPMs in the same command resolve fine — they are not
kernel-versioned. That asymmetry is the signature.

```bash
gh run view <run-id> --log-failed | grep -E "KERNEL=|Failed to access RPM|Error: building"
```

`--log-failed` reports the step as `UNKNOWN STEP` and dumps a lot of image-pull
noise here, so the grep is required.

If the labels differ but the failure is somewhere else, you have two problems.
Say so rather than assuming.

## 3. Find *why* it is stale before choosing a fix

Do not stop at "the tag is stale". Work outward as
[`AGENTS.md`](../../AGENTS.md#tracing-to-the-upstream-root-cause) sets out. The
question that changes the answer: is the wait bounded?

- A 2.4.x point release carrying the compat bump flows through on its own,
  because upstream pins ZFS to a `minor_version`.
- If the ceiling is only raised in the next *minor*, ublue must bump that pin
  first — a PR on their side, so a longer and less certain wait.
- ublue may also carry the commits as patches rather than wait for the tag.
  Check for that before concluding nothing is moving:

```bash
gh pr list --repo ublue-os/akmods --search zfs --state all --limit 20
```

`--state all` is load-bearing. The default `--state open` hides exactly the
window that matters — after a patch PR merges, before the floating tag rebuilds
— and would lead you to pin unnecessarily.

## 4. Not skew

Check which step failed and match it against
[Other failure modes](../../AGENTS.md#other-failure-modes). The known ones:
Chunkah exiting 126 with `Argument list too long`, `post-check.sh` rejecting the
finished image, `bootc container lint` failing on a warning, and the
`Containerfile`'s Fedora guard firing because `aurora-dx:stable` moved release.

## 5. Report

State the cause, the evidence, and the recommended option (wait / pin both /
testing-stream kmod) with its cost. If the recommendation is to wait, say what
you are waiting *on* and how you would know it cleared.

## Never

Do not loosen the `kmod-zfs` glob in `build_files/zfs.sh`, and do not make that
install non-fatal. A kmod built for a different kernel will not load; the
failure would move from the build to the boot.
