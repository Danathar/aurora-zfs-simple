---
description: Pin both akmods inputs to a matching kernel, or unpin them
mode: agent
---

# Pin the akmods inputs

Use when skew is confirmed and waiting is no longer acceptable — each week spent
waiting is one skipped image, so the deployed system stops receiving Aurora and
security updates.

## The rule that matters

**Pin both inputs or neither.** Pinning only one recreates the skew you are
trying to escape. The `Containerfile` comments say so; this is the single most
common way to make the situation worse.

## Pick the kernel

The last kernel for which both images have a build. From the diagnosis, that is
the `ostree.linux` value on `akmods-zfs` — the one that stopped moving.

## Apply

Replace **both** floating tags with the same kernel-pinned tag:

```Dockerfile
FROM ghcr.io/ublue-os/akmods:coreos-stable-45-7.2.11-300.fc45.x86_64 AS akmods
FROM ghcr.io/ublue-os/akmods-zfs:coreos-stable-45-7.2.11-300.fc45.x86_64 AS akmods-zfs
```

Verify the tags exist before pushing:

```bash
for img in akmods akmods-zfs; do
  skopeo inspect --format '{{ index .Labels "ostree.linux" }}' \
    "docker://ghcr.io/ublue-os/${img}:coreos-stable-45-7.2.11-300.fc45.x86_64"
done
```

Both must print the same value. That is the whole safety property.

## The variant worth knowing

The `coreos-stable` and `coreos-testing` streams publish builds for the **same**
kernel, so the kernel can come from stable while only the ZFS kmod comes from
testing. Read
[Fix options](../../AGENTS.md#fix-options) before choosing this — it is right
when OpenZFS's cap is stale metadata and wrong when the compat code genuinely
does not exist yet. The `ostree.linux` labels must still match.

## Leave a trail

A pin freezes the image on an unpatched kernel until someone removes it. That
someone will not remember. So:

- note in the PR why it was pinned and what would let it be unpinned
- open a tracking issue, or add an incident-log entry in `AGENTS.md`

## Unpinning

Restore both `FROM` lines to the floating tags together, after confirming the
labels have re-converged with the step-1 check. Never unpin one at a time.
