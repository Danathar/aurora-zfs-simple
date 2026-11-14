---
description: Pre-flight the upstream inputs before moving FEDORA_VERSION
mode: agent
---

# Move to the next Fedora release

`docs/manual-input-check.md` is the procedure. This is the decision framing
around it.

## Do not start by editing the Containerfile

`ARG FEDORA_VERSION` is the *last* step, not the first. The tags for release
`N+1` have to exist and agree before the value changes.

## What must line up

```text
ghcr.io/ublue-os/aurora-dx:stable
ghcr.io/ublue-os/akmods:coreos-stable-N-x86_64
ghcr.io/ublue-os/akmods-zfs:coreos-stable-N-x86_64
```

The kernel published by `akmods` must have a matching `kmod-zfs` in
`akmods-zfs`, and that artifact must carry one coherent OpenZFS release across
`kmod-zfs`, `zfs`, `libzfs`, `libzpool`, `libnvpair`, `libuutil` and
`python3-pyzfs` — not a mixture.

Run the checks in [`docs/manual-input-check.md`](../../docs/manual-input-check.md).
Note that the akmods images are RPM payload containers and may have no shell, so
inspect them with `podman cp` rather than running commands inside them.

While the base image is pinned to an older Fedora release (as now, see #499),
the `Containerfile` names that pin instead of `:stable`:

```text
ghcr.io/ublue-os/aurora-dx:stable-44.20261110.1
```

Check the inputs against `aurora-dx:stable` anyway, since that is where the
bump goes. The bump then sets `AURORA_TAG` back to `stable` in the same change
as `FEDORA_VERSION`. Leaving the pin in would fail the guard below.

## The guard you get for free

The `Containerfile` fails the build if `aurora-dx:stable` is a different Fedora
release than `FEDORA_VERSION`. So a premature bump fails fast and loudly rather
than producing a mixed-release image. Do not remove that guard to "unblock" a
bump.

## Decide

**They line up** → update `ARG FEDORA_VERSION`, open a PR, and let Actions build
it. `post-check.sh` performs the real validation against the assembled image.

**They do not** → change nothing. Stay on the last working release. This is the
expected outcome for a while after a Fedora release, and it is not a problem to
be solved here.

## Do not forget

Anything that names the current release in prose or in a prefilled command
should be checked. Grep for the old number before opening the PR.
