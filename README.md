# aurora-zfs-example

GitHub Actions workflows: `build.yml`, `build-disk.yml`

> [!NOTE]
> This repository is an example implementation, not a maintained product.
>
> It shows one relatively simple way to build an Aurora-based image with ZFS by
> consuming upstream Universal Blue artifacts instead of running a larger
> self-hosted akmods pipeline.
>
> Simpler does not mean safer by itself. The operator still has to check whether
> the upstream Aurora, `akmods`, and `akmods-zfs` inputs line up before moving
> this example to a new Fedora release.

This repository builds a signed Aurora image with:

- upstream Aurora as the userspace base image
- kernel RPMs from `ghcr.io/ublue-os/akmods`
- ZFS RPMs from `ghcr.io/ublue-os/akmods-zfs`
- a direct `Containerfile` build instead of a larger custom build-control layer

The documentation in this repository tries to stay readable for someone who is
learning these topics while reading.

## Why This Repo Exists

The goal here is not to automate every edge case.
The goal is to show a simpler path.

This example assumes upstream Universal Blue already publishes the matching
parts you need:

1. Aurora userspace
2. common kernel RPMs
3. matching ZFS RPMs for that kernel stream

When those three things line up, this example can stay fairly small.
When they do not line up, the operator has to wait instead of trying to rebuild
and publish their own replacement inputs.

## Safety Model

The safety model in this repo is intentionally simpler than a large candidate-
first pipeline:

1. check whether the upstream inputs line up
2. if they do, build and test
3. if they do not, stop and stay on the last working image

This repo now includes a helper for that pre-build check:

- script: [`scripts/check-aurora-zfs-example-inputs.sh`](./scripts/check-aurora-zfs-example-inputs.sh)
- guide: [`docs/manual-input-check.md`](./docs/manual-input-check.md)

## Important Design Detail

This example does not keep Aurora's original kernel packages.

Its ZFS helper script removes the kernel packages from the Aurora base image and
installs replacement kernel RPMs from `ghcr.io/ublue-os/akmods`.
Then it installs ZFS RPMs from `ghcr.io/ublue-os/akmods-zfs`.

That is why the manual input check matters.
The key question is not just "what Aurora is shipping".
It is whether these three pieces belong together:

1. the Aurora base image
2. the chosen `akmods` stream for that Fedora release
3. the matching `akmods-zfs` stream for that Fedora release

## Repository Layout

```text
Containerfile                         image build definition
build_files/build.sh                  package and service customization inside the image
build_files/zfs.sh                    kernel and ZFS RPM installation logic
scripts/check-aurora-zfs-example-inputs.sh
                                      helper that checks whether upstream inputs line up
.github/workflows/build.yml           build and publish the container image
docs/manual-input-check.md            operator guide for the helper script and manual process
```

## Core Workflows

- [`.github/workflows/build.yml`](./.github/workflows/build.yml)
  - builds and publishes the container image
  - signs the image on default-branch non-PR runs
- [`.github/workflows/build-disk.yml`](./.github/workflows/build-disk.yml)
  - builds disk images from the published container image

Markdown and docs changes do not trigger the main image-build workflow.

## Manual Input Check Before A Fedora Release Change

Before changing this example from one Fedora release to the next, run:

```bash
./scripts/check-aurora-zfs-example-inputs.sh
```

That script:

1. detects the Fedora version inside the chosen Aurora image
2. verifies that the matching `akmods` and `akmods-zfs` images exist
3. compares the kernel payload in `akmods` against the `kmod-zfs` RPMs in `akmods-zfs`

If the script fails:

1. do not move this example to the new Fedora release yet
2. stay on the last working image
3. check again later after upstream catches up

If the script passes:

1. update the example if needed
2. build it
3. test it
4. only then deploy it

Full guide:

- [`docs/manual-input-check.md`](./docs/manual-input-check.md)

## Build And Publish

Container image workflow:

```bash
gh workflow run build.yml
```

Local build example:

```bash
podman build -t aurora-zfs-example:local .
```

## Quick Validation After Boot

```bash
rpm -q kmod-zfs
modinfo zfs | head
zpool --version
zfs --version
```

## Signature Verification

```bash
cosign verify --key cosign.pub ghcr.io/danathar/aurora-zfs-example:latest
```

## References

- Aurora discussion: https://github.com/ublue-os/aurora/issues/1765
- Universal Blue akmods repo: https://github.com/ublue-os/akmods
