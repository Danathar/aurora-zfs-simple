# Manual Input Check

## Purpose

This repository is intentionally simple.

That simplicity comes with a tradeoff:

1. the build does not have a large automation layer that resolves, pins, and validates every moving upstream input for you
2. the operator has to decide whether the upstream Aurora, `akmods`, and `akmods-zfs` images line up before trying a build

This document explains two ways to do that:

1. with the helper script in [`scripts/check-aurora-zfs-example-inputs.sh`](../scripts/check-aurora-zfs-example-inputs.sh)
2. manually, step by step, without the script

## Why This Check Is Needed

This example does not just start from Aurora and add ZFS on top.

Its ZFS helper script does three important things:

1. starts from an Aurora userspace image
2. removes the kernel packages already in that image
3. installs kernel RPMs from `ghcr.io/ublue-os/akmods:<stream>-<fedora>`
4. installs ZFS RPMs from `ghcr.io/ublue-os/akmods-zfs:<stream>-<fedora>`

That means the key pre-build question is:

- does Aurora's Fedora release line up with a matching `akmods` image and a matching `akmods-zfs` image?

If the answer is no, stop and stay on the last working image.

## Scripted Check

The helper script lives here:

- [`scripts/check-aurora-zfs-example-inputs.sh`](../scripts/check-aurora-zfs-example-inputs.sh)

### What The Script Does

The script:

1. detects the Fedora version inside the chosen Aurora base image
2. checks that the matching `ublue-os/akmods` image exists for that Fedora release and stream
3. checks that the matching `ublue-os/akmods-zfs` image exists for that Fedora release and stream
4. mounts the `akmods` and `akmods-zfs` images locally through Podman instead of assuming those images include shell tools such as `bash` or `find`
5. reads the kernel releases published inside the `akmods` image
6. checks that each of those kernel releases has a matching `kmod-zfs` RPM in the `akmods-zfs` image

### Requirements

The script expects these commands on the machine where you run it:

1. `podman`
2. `skopeo`
3. `grep`
4. `sed`
5. `sort`

It also needs network access so those tools can inspect and run upstream
container images.

### Normal Usage

```bash
./scripts/check-aurora-zfs-example-inputs.sh
```

That uses:

1. `ghcr.io/ublue-os/aurora:stable`
2. `coreos-stable` as the akmods stream

### Override The Aurora Base Image

```bash
AURORA_IMAGE=ghcr.io/ublue-os/aurora:stable ./scripts/check-aurora-zfs-example-inputs.sh
```

Example with a digest-pinned image:

```bash
AURORA_IMAGE=ghcr.io/ublue-os/aurora@sha256:<digest> ./scripts/check-aurora-zfs-example-inputs.sh
```

### Override The Akmods Stream

```bash
AKMODS_STREAM=coreos-testing ./scripts/check-aurora-zfs-example-inputs.sh
```

## What To Do If The Script Passes

A pass means:

1. the Aurora image is on Fedora `N`
2. `ublue-os/akmods:<stream>-N` exists
3. `ublue-os/akmods-zfs:<stream>-N` exists
4. the kernel payload inside the `akmods` image has matching `kmod-zfs` RPMs inside the `akmods-zfs` image

A pass does **not** mean the finished image is already safe to deploy.
It means the upstream inputs look coherent enough to justify a build and test.

After a pass:

1. update `ARG FEDORA_VERSION=` in the `Containerfile` if needed
2. prefer `aurora:stable` or a digest instead of `aurora:latest`
3. build the image
4. test the image on a real machine or virtual machine (VM)
5. only then deploy it

## What To Do If The Script Fails

A failure means stop.

Do **not** move this example to that Fedora release yet.

A failure usually means one of these:

1. the matching `akmods` image is missing
2. the matching `akmods-zfs` image is missing
3. the `akmods` image contains a kernel release that does not have a matching `kmod-zfs` RPM in the ZFS image

After a failure:

1. stay on the last working image
2. do not update this example to the new Fedora release yet
3. do not deploy a new image based on mismatched inputs
4. check again later after upstream images have had time to catch up

## Manual Check Without The Script

If you prefer to do this by hand, use the steps below.

### Step 1: Pick The Aurora Base Image

Usually this should be:

```bash
ghcr.io/ublue-os/aurora:stable
```

Using `:latest` is less predictable because it can move while you are still
thinking through the build inputs.

### Step 2: Detect The Fedora Version In The Aurora Image

```bash
podman run --rm ghcr.io/ublue-os/aurora:stable rpm -E %fedora
```

If that prints `45`, then you should be thinking about Fedora 45 inputs.

### Step 3: Build The Expected Upstream Image Names

If Aurora says Fedora 45 and you want the `coreos-stable` stream, the matching
upstream inputs should be:

```text
ghcr.io/ublue-os/akmods:coreos-stable-45
ghcr.io/ublue-os/akmods-zfs:coreos-stable-45
```

### Step 4: Confirm Both Images Exist

```bash
skopeo inspect docker://ghcr.io/ublue-os/akmods:coreos-stable-45 >/dev/null
skopeo inspect docker://ghcr.io/ublue-os/akmods-zfs:coreos-stable-45 >/dev/null
```

If either command fails, stop.

That means upstream has not published the full matching set yet.

### Step 5: Read The Kernel Releases In The Akmods Image

```bash
podman run --rm ghcr.io/ublue-os/akmods:coreos-stable-45 \
  find /kernel-rpms -maxdepth 1 -type f -name 'kernel-core-*.rpm' -printf '%f\n'
```

From those filenames, remove:

1. the `kernel-core-` prefix
2. the `.rpm` suffix

That leaves the kernel release values you need to compare.

### Step 6: Check The ZFS Image For Matching RPMs

For each kernel release from the previous step, look for a matching file in the
ZFS image:

```bash
podman run --rm ghcr.io/ublue-os/akmods-zfs:coreos-stable-45 \
  find /rpms/kmods/zfs -maxdepth 1 -type f | sort
```

You want to see a matching `kmod-zfs-<kernel_release>...rpm` for every kernel
release found in the `akmods` image.

If they do not line up, stop.

### Step 7: Decide

If all of the above checks pass:

1. update the example
2. build it
3. test it
4. only then deploy it

If any check fails:

1. stay on the previous working image
2. do not move the example to the new Fedora release yet
3. check again later

## Short Operator Rule

If you only want the short version, use this:

1. Aurora moved to Fedora `N`
2. `akmods:<stream>-N` exists
3. `akmods-zfs:<stream>-N` exists
4. the kernels inside `akmods:<stream>-N` have matching `kmod-zfs` RPMs inside `akmods-zfs:<stream>-N`
5. only then build and test

If any one of those is false, stop and stay on the last working image.
