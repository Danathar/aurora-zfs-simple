# Copilot instructions

**Read [`AGENTS.md`](../AGENTS.md) first.** It is the real orientation document
for this repo and is kept current. This file exists so Copilot picks up the
essentials automatically; it deliberately does not restate AGENTS.md, because a
second copy of that content would drift out of date and this repo has already
been bitten by documentation that stopped matching the tree.

## What this repo is

A thin Aurora DX derivative that adds ZFS back. It does **not** compile ZFS. It
assembles three prebuilt Universal Blue artifacts: the Aurora base, `akmods`,
and `akmods-zfs`.

Its correctness depends on **two** of those agreeing about the kernel version:
`akmods` and `akmods-zfs`. The Aurora base is not one of them.
`build_files/kernel-akmods.sh` erases Aurora's kernel RPMs outright and installs
the one from the akmods stream, so this image legitimately runs a newer kernel
than Aurora stable whenever that stream is ahead. **That is the design, not a
fault.** Never recommend a downgrade or a pin on the strength of the base
image's kernel differing.

## The one thing to internalise

Most red builds here are **not caused by this repo**. `akmods` tracks whatever
kernel Fedora ships; `akmods-zfs` can only advance when OpenZFS supports that
kernel. When Fedora's kernel overtakes OpenZFS's `Linux-Maximum`, the ZFS build
freezes upstream and this repo breaks the next time it builds.

Before proposing any change to a failing build, confirm the cause: compare the
`ostree.linux` label on `ghcr.io/ublue-os/akmods` and
`ghcr.io/ublue-os/akmods-zfs` for the release the `Containerfile` targets —
those two labels, and nothing else, decide it. If they differ, that is the
answer. AGENTS.md has the exact commands and the fix options.

Never "fix" that failure by loosening the `kmod-zfs` glob in
`build_files/zfs.sh` or making the install non-fatal. A kmod built for a
different kernel will not load, and the failure moves from the build to the
boot, where it is much worse.

## When writing code here

- It is shell. There is no package manager, no `node_modules`, and no build
  step. Do not introduce one.
- `shellcheck -x` must produce **zero** output, informational findings included.
  The test suite enforces this.
- Every `*.sh` needs a shebang and the executable bit; the `Containerfile` and
  the workflows run these scripts by path.
- Four-space indentation, except `ci/write-badges.sh`, which is two.
- `./tests/run-tests.sh` is the suite. Install `shellcheck` before trusting a
  green run — the suite skips that pass when the tool is absent.

## When writing comments

This repo's comments explain *why*, and specifically why something that looks
wrong is deliberate: the `.Config`-only `podman inspect` that works around
`MAX_ARG_STRLEN`, the badge script refusing to guess when an input is
unreadable, the push-once-then-copy tag propagation. Do not "clean up" code
whose comment explains an incident. Add to that style rather than stripping it.

## What cannot be tested from the host

`build_files/build.sh`, `build_files/kernel-akmods.sh`, `build_files/zfs.sh` and
the `Containerfile` only run inside an image build. A green local suite is not
evidence for a change to any of them. `build_files/post-check.sh` is partly
covered through its sourceable helpers. Say how an image-build change was
verified, or say that it was not.
