# Aurora developer image with ZFS

[![Build container image](https://github.com/Danathar/aurora-zfs-simple/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/Danathar/aurora-zfs-simple/actions/workflows/build.yml)
[![Coverage gate](https://github.com/Danathar/aurora-zfs-simple/actions/workflows/coverage-gate.yml/badge.svg?branch=main)](https://github.com/Danathar/aurora-zfs-simple/actions/workflows/coverage-gate.yml)
[![Nightly compliance](https://github.com/Danathar/aurora-zfs-simple/actions/workflows/nightly-compliance.yml/badge.svg?branch=main)](https://github.com/Danathar/aurora-zfs-simple/actions/workflows/nightly-compliance.yml)
[![last good build](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2FDanathar%2Faurora-zfs-simple%2Fstatus%2Flast-good-build-badge.json)](https://github.com/Danathar/aurora-zfs-simple/pkgs/container/aurora-zfs-simple)
[![OpenZFS/kernel status](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2FDanathar%2Faurora-zfs-simple%2Fstatus%2Fakmods-badge.json)](AGENTS.md#dominant-failure-mode-kernel--zfs-akmod-skew)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/Danathar/aurora-zfs-simple)
[![Maintenance assisted by Hivecommons Hive](https://img.shields.io/badge/maintenance%20assisted%20by-Hivecommons%20Hive-1f6feb)](https://github.com/hivecommons/hive)
[![ACMM L4 Security-Aware](https://img.shields.io/badge/ACMM-L4%20Security--Aware-2da44e)](https://github.com/hivecommons/hive#acmm-levels)
[![AI assisted](https://img.shields.io/badge/AI-assisted-d29922)](#about-this-project)
[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)

The three workflow badges are red whenever that workflow's last run on `main`
failed. **Build container image** is the one that decides whether there is a new
image at all; the two badges beside it say what a red build means for you:

- **last good build** — when the published `:latest` image was actually built.
  This image is still installable and still boots; a red build just means it has
  not been refreshed since that date.
- **OpenZFS/kernel** — whether the two akmods images *this `Containerfile`
  pulls* agree on a kernel version. `blocked` means there is no `kmod-zfs`
  published for the kernel the build wants, which is the near-universal cause of
  a red build here. Because it reads the `FROM` lines rather than a fixed tag,
  it also tracks pinned inputs correctly. Click through for what that means and
  what to do about it.

> [!NOTE]
> `main` is now the maintained AMD/non-NVIDIA branch. The previous NVIDIA Open
> version was moved to the
> [`nvidia-legacy`](https://github.com/Danathar/aurora-zfs-simple/tree/nvidia-legacy)
> branch and tagged
> `nvidia-last-known-good-2026-05-31`. That NVIDIA branch is unmaintained; it
> worked the last time it was used, but it may stop building or working as
> upstream Aurora, kernel, ZFS, or NVIDIA inputs change.

This is a small, GitHub-built Aurora DX developer image that adds ZFS back using
upstream Universal Blue akmods artifacts.

It is intended for users who already understand ZFS and kernel-module matching.
The expected install path is to rebase an existing Aurora install to the
published container image.

[Discussion](https://github.com/ublue-os/aurora/issues/1765)

## Trusting The Signing Key

Every image this repository publishes is signed with the key whose public half
is committed here as `cosign.pub`, and the nightly compliance workflow
re-verifies the published `:latest` against it. None of that is checked on your
machine unless the host's container signature policy knows about the key, so
configure it before switching. This is a one-time setup per host.

Install the public key:

```bash
sudo install -Dm0644 cosign.pub /etc/pki/containers/aurora-zfs-simple.pub
```

Then add an entry for the image to the `docker` transport map in
`/etc/containers/policy.json`. The Aurora base image already ships that file
with entries for the Universal Blue keys, so add to the existing map rather
than replacing the file:

```json
"ghcr.io/danathar/aurora-zfs-simple": [
  {
    "type": "sigstoreSigned",
    "keyPath": "/etc/pki/containers/aurora-zfs-simple.pub",
    "signedIdentity": { "type": "matchRepository" }
  }
]
```

For a fork, use your own repository's path and your own `cosign.pub`.

## Switching To This Image

After the GitHub Actions workflow publishes your fork's image, switch an
existing Aurora install to it:

```bash
sudo bootc switch --enforce-container-sigpolicy ghcr.io/<owner>/<repo>:latest
```

For this repository, that would be:

```bash
sudo bootc switch --enforce-container-sigpolicy ghcr.io/danathar/aurora-zfs-simple:latest
```

`--enforce-container-sigpolicy` is what makes the signature checked, and bootc
records it: every later `bootc upgrade` on that host enforces it too. Dropping
the flag switches to whatever `:latest` currently resolves to without checking
the signature at all, on that rebase and on every upgrade after it. Only do
that deliberately, and only if you have not configured the policy above:

```bash
sudo bootc switch ghcr.io/<owner>/<repo>:latest
```

Reboot after switching.

## Switching Back To Upstream

To go back to upstream Aurora DX stable:

```bash
sudo bootc switch --enforce-container-sigpolicy ghcr.io/ublue-os/aurora-dx:stable
```

Reboot after switching back.

## What It Uses

- base image: `ghcr.io/ublue-os/aurora-dx:stable`
- kernel RPMs: `ghcr.io/ublue-os/akmods`
- ZFS RPMs: `ghcr.io/ublue-os/akmods-zfs`
- content-based image layering: [`coreos/chunkah`](https://github.com/coreos/chunkah)

This branch intentionally does not include the NVIDIA Open Aurora base image or
NVIDIA akmods.

## Important Design Detail

This image does not keep Aurora's original kernel packages.

`build_files/kernel-akmods.sh` removes the base kernel and installs the kernel
from the selected Universal Blue `akmods` stream. `build_files/zfs.sh` then
installs matching ZFS kmods and userspace packages from the corresponding
upstream akmods image. This ensures the kernel and ZFS module RPMs come from
matching Universal Blue akmods inputs.

The Fedora release is controlled here:

```Dockerfile
ARG FEDORA_VERSION=44
```

The base image intentionally tracks Aurora DX stable:

```Dockerfile
ARG AURORA_IMAGE=ghcr.io/ublue-os/aurora-dx
ARG AURORA_TAG=stable
```

The `Containerfile` has a guard that fails the build if the stable base image's
Fedora version does not match `FEDORA_VERSION`.

For the manual release-readiness checklist, see
[`docs/manual-input-check.md`](docs/manual-input-check.md).

## If The Kernel Moves Ahead Of Aurora

The kernel comes from the selected Universal Blue `akmods` stream, not directly
from the Aurora base image. That means this image can temporarily carry a newer
kernel than upstream Aurora stable when the akmods stream has moved ahead.

That is expected for this design, but ZFS must have a matching prebuilt kmod for
the same kernel. The build fails if the kernel and ZFS module stack do not line
up.

## Pinning The Kernel If Needed

If a new kernel lands before ZFS is ready or before you want to move, pin all
akmods inputs to the same full kernel tag. For example:

```Dockerfile
FROM ghcr.io/ublue-os/akmods:coreos-stable-44-6.19.14-101.fc44.x86_64 AS akmods
FROM ghcr.io/ublue-os/akmods-zfs:coreos-stable-44-6.19.14-101.fc44.x86_64 AS akmods-zfs
```

Pin both inputs together. Do not pin only one of them.

When a build has already failed this way, [`AGENTS.md`](AGENTS.md) has the
step-by-step diagnosis: how to confirm the skew, how to trace it back to the
upstream `ublue-os/akmods` job and the OpenZFS kernel-version gate, and how to
pick between waiting, pinning, and switching streams.

## Repository Layout

```text
AGENTS.md                                 agent notes: build-failure diagnosis and upstream tracing
CLAUDE.md                                 pointer to AGENTS.md
CONTRIBUTING.md                           how to work in this repo, and what CI does not prove
Containerfile                             image build definition
build_files/build.sh                      package and service customization inside the image
build_files/kernel-akmods.sh              kernel replacement and common akmods installation
build_files/post-check.sh                 final image validation for kernel and ZFS
build_files/zfs.sh                        ZFS RPM installation and final initramfs generation
ci/write-badges.sh                        derives the README status badge JSON
tests/                                    shell tests and Python/PyYAML workflow checks
tests/e2e/                                manual end-to-end image build and rechunk check
.github/workflows/build.yml               build and publish the container image
.github/workflows/status-badges.yml       refresh the status badges on the `status` branch
.github/workflows/coverage-gate.yml       run the suite on docs-only changes build.yml ignores
.github/workflows/nightly-compliance.yml  re-check the published image's signature and tags
.github/workflows/auto-qa.yml             compare CI timeouts against observed durations
.github/workflows/labeler.yml             apply the descriptive `area/*` labels
.github/workflows/ai-fix.yml              hand a labelled issue or a review to an agent
.github/labeler.yml                       path-to-label map for the above
.github/auto-qa-tuning.json               declared CI timeouts and the drift policy
renovate.json                             dependency updates, including the Chunkah release tag
docs/manual-input-check.md                Fedora release input-check notes
docs/quality.md                           where the signal comes from, and what it cannot tell you
docs/metrics.md                           what is measured here and what is not
docs/review-rubric.md                     what a review of a change here should ask
docs/risk-tiers.md                        how to classify a change, and the evidence each tier needs
docs/SECURITY-AI.md                       what an agent may do here, and what it must not touch
docs/reflections/                         durable lessons from things that went wrong
```

## Build And Publish

This repo is built by GitHub Actions.

Manual workflow run:

```bash
gh workflow run build.yml
```

The workflow also runs on the default branch according to `.github/workflows/build.yml`.
It builds the complete image, post-processes it with Chunkah, publishes a
single tag, copies that exact manifest to the remaining tags, verifies every
published tag resolves to one manifest digest, and then signs that digest on
default-branch non-PR runs.

Chunkah runs after the kernel and ZFS changes have been applied. It rebuilds the
final root filesystem into content-based layers, including both the inherited
Aurora content and this image's replacement kernel and ZFS files. This improves
layer reuse and update resumability; it does not change the files installed in
the image.

The workflow pins Chunkah to an explicit stable release tag, for example
`quay.io/coreos/chunkah:v0.6.0`, instead of the floating `latest` tag. A custom
manager in [`renovate.json`](renovate.json) matches that `CHUNKAH_IMAGE:` line
and opens a PR when a newer stable `vX.Y.Z` is published.

The pin is the semver tag only — there is no `@sha256:...` digest on it, and
`renovate.json` explicitly disables digest and pin updates for
`quay.io/coreos/chunkah`. So the guarantee here is "a named upstream release",
not "these exact bytes": Chunkah could in principle re-push `v0.6.0`.

Nothing downstream re-checks the result, either. `build_files/post-check.sh` and
`bootc container lint` run *inside* the `Containerfile`, so they validate the
image before the workflow hands it to Chunkah. The re-layered archive that comes
back out is loaded, tagged, pushed and signed without either check running
again, and `Verify pushed tags share one digest` confirms that every tag
resolves to one manifest — not that the manifest holds what was built.

Do not read this pin as digest-level immutability. If that property is wanted,
it needs a digest on `CHUNKAH_IMAGE` and a `currentDigest` group in the custom
manager, not an inference from the checks above.

Scheduled builds run weekly on Sunday morning at 05:00 UTC, which is about
1:00 AM Eastern during daylight time. This keeps the image refreshed before a
typical early-morning systemd pull timer without staging a new deployment every
day.

If Aurora or the upstream Universal Blue akmods images publish an important
update during the week, deciding whether to run an out-of-schedule manual build
is up to you.

## Build-Time Validation

Before `bootc container lint`, the `Containerfile` runs
`build_files/post-check.sh`. This is a fail-fast consistency check for the final
image. It is intended to catch cases where RPM metadata says something is
installed but the files needed at boot are missing.

The post-check verifies:

- exactly one kernel module tree exists under `/usr/lib/modules`
- the kernel RPM and module tree agree on the selected kernel version
- ZFS RPMs, userspace commands, shared libraries, systemd units, udev rules, and
  module-load config are present
- ZFS kmod, userspace, and libraries report one OpenZFS version/release
- `spl.ko` and `zfs.ko` exist for the selected kernel
- `modinfo -k <kernel> spl` and `modinfo -k <kernel> zfs` work after `depmod`
- `spl` and `zfs` module vermagic matches the selected kernel
- the generated initramfs contains `zfs.ko` and `spl.ko`
- critical ZFS kmod RPM payload files are not missing or content-modified, while
  harmless rpm-ostree/bootc ownership/group/timestamp normalization is ignored

These checks do not prove that a real pool imports because the GitHub runner
does not provide those host devices to the image build. They do verify that the
image contains the expected kernel modules, userspace tools, libraries, and boot
integration before it is published.

## Rebase An Existing Aurora Install

After your image is published to GHCR, rebase an existing Aurora install to the
custom image. Configure the signature policy first — see
[Trusting The Signing Key](#trusting-the-signing-key) — then switch, replacing
the owner and repository with your fork.

```bash
sudo bootc switch --enforce-container-sigpolicy ghcr.io/<owner>/<repo>:latest
```

Without `--enforce-container-sigpolicy` the image's signature is not checked,
on this rebase or on any later `bootc upgrade`:

```bash
sudo bootc switch ghcr.io/<owner>/<repo>:latest
```

Reboot after the switch, then validate ZFS as you normally would.

Useful post-rebase checks:

```bash
cat /proc/cmdline
lsmod | grep -E 'zfs|spl'
zpool status
```

Your ZFS pools should import normally.

## Signature Verification

```bash
cosign verify --key cosign.pub ghcr.io/danathar/aurora-zfs-simple:latest
```

This is a one-shot manual check, and it proves only what `:latest` pointed at
while the command was running. It does not make anything on the host verify a
later pull. What does that is
[Trusting The Signing Key](#trusting-the-signing-key) plus switching with
`--enforce-container-sigpolicy`, which applies the check to the rebase and to
every `bootc upgrade` after it.

## About this project

> [!NOTE]
> This image was built with AI assistance and should be treated cautiously.
>
> It is a third-party image. It is not an official Aurora or Universal Blue
> image, is not sanctioned by the Universal Blue project, is not an official
> Fedora image, and is not sanctioned by the Fedora Project.
>
> It replaces the base image's kernel and installs out-of-tree ZFS modules, so
> it is provided as-is, without any promise that it will be safe for your
> systems, pools, or data. Review what it does before rebasing a machine to it,
> and keep backups. The maintainer is not responsible for data loss, an
> unbootable system, a failed build, or other consequences that may result from
> using this image.

> [!NOTE]
> **Maintenance on this repository is assisted by [Hivecommons Hive](https://github.com/hivecommons/hive) at ACMM level 4.**
>
> Hive orchestrates a fleet of AI agents that continuously review this codebase.
>
> At **L4 (Security-Aware)** all agents may file issues, and the quality,
> sec-check and CI agents may additionally open pull requests that carry a
> `hold` label. The rest stay advisory: they report, they do not act. Every
> change is still reviewed and merged by a human maintainer.
>
> Learn more: [Hive](https://github.com/hivecommons/hive) · [Hive Hub](https://hive.kubestellar.io) · [full ACMM policy matrix](https://github.com/hivecommons/hive/blob/v4/src/docs/acmm-policy-matrix.md)

## References

- Aurora repo: https://github.com/ublue-os/aurora
- Aurora discussion: https://github.com/ublue-os/aurora/issues/1765
- Universal Blue akmods repo: https://github.com/ublue-os/akmods
- Universal Blue akmods issues: https://github.com/ublue-os/akmods/issues
- Chunkah repo: https://github.com/coreos/chunkah
