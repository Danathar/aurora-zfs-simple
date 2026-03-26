# Manual Input Check

## Purpose

This repository is intentionally simple.

That simplicity comes with a tradeoff:

1. the build does not have a large automation layer that resolves, pins, and validates every moving upstream input for you
2. the operator (that's you) has to decide whether the upstream Aurora, `akmods`, and `akmods-zfs` images line up before trying a build

This document explains two ways to do that:

1. with the helper script in [`scripts/check-aurora-zfs-example-inputs.sh`](../scripts/check-aurora-zfs-example-inputs.sh)
2. manually, step by step, without the script

If you are not sure what some of these terms mean yet, keep reading — each
section explains the relevant concepts as they come up.

## Why This Check Is Needed

This example does not just start from Aurora and add ZFS on top.

Its ZFS helper script does three important things:

1. starts from an Aurora userspace image (this is the base operating system — all the non-kernel software like your desktop, libraries, and system tools)
2. removes the kernel packages already in that image (the kernel is the core of the OS that talks to your hardware)
3. installs kernel RPMs from `ghcr.io/ublue-os/akmods:<stream>-<fedora>` (RPMs are Fedora's package format — think of them like `.deb` files on Ubuntu or `.pkg` files on macOS)
4. installs ZFS RPMs from `ghcr.io/ublue-os/akmods-zfs:<stream>-<fedora>` (ZFS is a filesystem with advanced features like snapshots, compression, and data integrity checking)

That means the key pre-build question is:

- does Aurora's Fedora release line up with a matching `akmods` image and a matching `akmods-zfs` image?

The reason this matters is that kernel modules (like ZFS) must be compiled for
the **exact** kernel version they will run on.  A ZFS module built for kernel
6.12.8 will not load on kernel 6.12.9.  If the versions do not match, the
system will boot without ZFS support, which could mean your data is inaccessible.

If the answer is no, stop and stay on the last working image.

## Scripted Check

The helper script lives here:

- [`scripts/check-aurora-zfs-example-inputs.sh`](../scripts/check-aurora-zfs-example-inputs.sh)

The script itself contains detailed inline comments explaining every command
and shell construct it uses.  If you want to understand what it does under
the hood, open it and read through — it is written to teach, not just to run.

### What The Script Does

The script performs the following checks in order.  If any step fails, it stops
immediately and tells you what went wrong.

1. **Detects the Fedora version** inside the chosen Aurora base image.  It does
   this by running `rpm -E %fedora` inside the image, which asks the RPM
   package manager what Fedora version the image is built on (e.g. "41").

2. **Checks that the matching `ublue-os/akmods` image exists** for that Fedora
   release and stream.  It uses `skopeo inspect` to query the container
   registry without downloading the full image — this is fast and lightweight.

3. **Checks that the matching `ublue-os/akmods-zfs` image exists** in the same
   way.

4. **Mounts the `akmods` and `akmods-zfs` images locally** through Podman
   (a container tool similar to Docker) instead of assuming those images include
   shell tools such as `bash` or `find`.  "Mounting" means making the files
   inside the container image accessible on your local filesystem, like plugging
   in a USB drive — you can browse and read the files without actually running
   the container.

5. **Reads the kernel releases** published inside the `akmods` image by looking
   at the RPM filenames in its `/kernel-rpms` directory.

6. **Checks that each kernel release has a matching `kmod-zfs` RPM** in the
   `akmods-zfs` image.  This is the critical compatibility check — if any
   kernel version is missing its ZFS module, the build would produce a broken
   image.

### Requirements

The script expects these commands on the machine where you run it:

1. **`podman`** — a container engine (like Docker) for pulling, mounting, and
   running container images.  On Fedora it is usually pre-installed.
2. **`skopeo`** — a tool for inspecting container registries without downloading
   full images.  Install with `dnf install skopeo` if missing.
3. **`grep`** — searches for text patterns (pre-installed on virtually all Linux
   systems).
4. **`sed`** — a "stream editor" that transforms text, used here to strip
   prefixes and suffixes from filenames (pre-installed on virtually all Linux
   systems).
5. **`sort`** — sorts and deduplicates lines of text (pre-installed on
   virtually all Linux systems).

It also needs **network access** so those tools can reach the container
registries at `ghcr.io` (GitHub Container Registry) to inspect and pull the
upstream images.

### Normal Usage

```bash
./scripts/check-aurora-zfs-example-inputs.sh
```

That uses the default settings:

1. `ghcr.io/ublue-os/aurora:stable` as the Aurora base image
2. `coreos-stable` as the akmods stream (a "stream" is a release channel — `coreos-stable` tracks the stable kernel that Fedora CoreOS uses, which tends to be well-tested and reliable)

### Override The Aurora Base Image

You can point the script at a different Aurora image by setting the
`AURORA_IMAGE` environment variable before the command.  In shell, putting
`VAR=value` before a command sets that variable just for that one command.

```bash
AURORA_IMAGE=ghcr.io/ublue-os/aurora:stable ./scripts/check-aurora-zfs-example-inputs.sh
```

Example with a digest-pinned image (a digest is a SHA-256 hash that uniquely
identifies an exact version of an image — unlike tags, digests never change or
move, so they are the safest way to refer to a specific build):

```bash
AURORA_IMAGE=ghcr.io/ublue-os/aurora@sha256:<digest> ./scripts/check-aurora-zfs-example-inputs.sh
```

### Override The Akmods Stream

If you want to test against a different stream (e.g. `coreos-testing` for
newer but less proven kernels):

```bash
AKMODS_STREAM=coreos-testing ./scripts/check-aurora-zfs-example-inputs.sh
```

## What To Do If The Script Passes

A pass means all four of these are true:

1. the Aurora image is on Fedora `N`
2. `ublue-os/akmods:<stream>-N` exists in the registry
3. `ublue-os/akmods-zfs:<stream>-N` exists in the registry
4. the kernel payload inside the `akmods` image has matching `kmod-zfs` RPMs inside the `akmods-zfs` image

A pass does **not** mean the finished image is already safe to deploy.
It means the upstream inputs look coherent enough to justify a build and test.
Think of it like checking that you have all the ingredients before cooking — it
does not guarantee the meal will taste good, but at least you will not discover
a missing ingredient halfway through.

After a pass:

1. update `ARG FEDORA_VERSION=` in the `Containerfile` if needed (this is the
   line in the build file that tells the build which Fedora version to target)
2. prefer `aurora:stable` or a digest instead of `aurora:latest` (`:latest` can
   change at any time, so your build inputs could shift between when you checked
   and when you actually build)
3. build the image
4. test the image on a real machine or virtual machine (VM)
5. only then deploy it

## What To Do If The Script Fails

A failure means **stop**.

Do **not** move this example to that Fedora release yet.

A failure usually means one of these:

1. the matching `akmods` image is missing — Universal Blue has not published
   kernel packages for this Fedora version yet
2. the matching `akmods-zfs` image is missing — the ZFS kernel module has not
   been built for this Fedora version yet
3. the `akmods` image contains a kernel release that does not have a matching
   `kmod-zfs` RPM in the ZFS image — the ZFS build is lagging behind the
   kernel build

None of these are problems you can fix yourself.  They are upstream timing
issues — the various Universal Blue images are built by different pipelines
that do not always finish at the same time.

After a failure:

1. stay on the last working image (do not change anything)
2. do not update this example to the new Fedora release yet
3. do not deploy a new image based on mismatched inputs
4. check again later after upstream images have had time to catch up (hours to
   days, depending on the release cycle)

## Manual Check Without The Script

If you prefer to do this by hand — or if the script is not working and you want
to understand what it would have done — follow the steps below.

Each step includes the command to run and an explanation of what it does.

### Step 1: Pick The Aurora Base Image

Usually this should be:

```bash
ghcr.io/ublue-os/aurora:stable
```

Using `:latest` is less predictable because it can move to a new Fedora version
while you are still thinking through the build inputs.  The `:stable` tag is
more deliberate — it only moves when the Aurora team explicitly promotes a build.

If you want maximum predictability, use a **digest** (the `@sha256:...` form)
instead of a tag.  A digest refers to one exact image and will never change.

### Step 2: Detect The Fedora Version In The Aurora Image

```bash
podman run --rm ghcr.io/ublue-os/aurora:stable rpm -E %fedora
```

What this command does, piece by piece:

- **`podman run`** — start a new container from the specified image
- **`--rm`** — automatically delete the container when it finishes (cleanup)
- **`ghcr.io/ublue-os/aurora:stable`** — the image to run
- **`rpm -E %fedora`** — the command to execute inside the container.  `rpm` is
  Fedora's package manager, and `-E %fedora` tells it to expand the `%fedora`
  macro, which evaluates to the Fedora version number (e.g. `41`, `42`, `45`)

If that prints `45`, then you should be thinking about Fedora 45 inputs for
all subsequent steps.

### Step 3: Build The Expected Upstream Image Names

Now that you know the Fedora version, you can construct the image references
you need to check.  The naming convention is:

```text
ghcr.io/ublue-os/akmods:<stream>-<fedora-version>
ghcr.io/ublue-os/akmods-zfs:<stream>-<fedora-version>
```

So if Aurora says Fedora 45 and you want the `coreos-stable` stream, the
matching upstream inputs should be:

```text
ghcr.io/ublue-os/akmods:coreos-stable-45
ghcr.io/ublue-os/akmods-zfs:coreos-stable-45
```

### Step 4: Confirm Both Images Exist

```bash
skopeo inspect docker://ghcr.io/ublue-os/akmods:coreos-stable-45 >/dev/null
skopeo inspect docker://ghcr.io/ublue-os/akmods-zfs:coreos-stable-45 >/dev/null
```

What this does:

- **`skopeo inspect`** queries the container registry for metadata about an
  image.  It does **not** download the image — it just checks that it exists
  and retrieves information like its creation date and labels.
- **`docker://`** is the protocol prefix that tells skopeo to use the standard
  container registry protocol (the same one Docker and Podman use).
- **`>/dev/null`** discards the normal output (the metadata JSON) because we
  only care whether the command succeeds or fails.  `/dev/null` is a special
  file on Linux that throws away anything written to it.

If either command fails (prints an error and returns a non-zero exit code),
**stop**.  That means upstream has not published the full matching set yet.

### Step 5: Read The Kernel Releases In The Akmods Image

```bash
podman run --rm ghcr.io/ublue-os/akmods:coreos-stable-45 \
  find /kernel-rpms -maxdepth 1 -type f -name 'kernel-core-*.rpm' -printf '%f\n'
```

What this does:

- Runs the `find` command inside the akmods container image
- **`/kernel-rpms`** — the directory inside the image where kernel RPMs are
  stored
- **`-maxdepth 1`** — only look in the top-level directory, do not recurse
  into subdirectories
- **`-type f`** — only match regular files (not directories)
- **`-name 'kernel-core-*.rpm'`** — only match files whose name starts with
  `kernel-core-` and ends with `.rpm`
- **`-printf '%f\n'`** — print just the filename (not the full path), followed
  by a newline

You will see output like:

```text
kernel-core-6.12.8-200.fc45.x86_64.rpm
```

From those filenames, remove:

1. the `kernel-core-` prefix
2. the `.rpm` suffix

That leaves the **kernel release** value: `6.12.8-200.fc45.x86_64`

This is the version string you need to match against the ZFS RPMs in the next
step.

### Step 6: Check The ZFS Image For Matching RPMs

For each kernel release from the previous step, look for a matching file in the
ZFS image:

```bash
podman run --rm ghcr.io/ublue-os/akmods-zfs:coreos-stable-45 \
  find /rpms/kmods/zfs -maxdepth 1 -type f | sort
```

This lists all files in the ZFS RPM directory, sorted alphabetically.  You want
to see a file named `kmod-zfs-<kernel_release>...rpm` for every kernel release
found in the `akmods` image.

For example, if Step 5 found `6.12.8-200.fc45.x86_64`, you should see
something like `kmod-zfs-6.12.8-200.fc45.x86_64-2.2.7-1.fc45.x86_64.rpm`
in this listing.

If they do not line up — if a kernel release has no matching `kmod-zfs` RPM —
**stop**.  The ZFS module would not load for that kernel.

### Step 7: Decide

If all of the above checks pass:

1. update the example (change `FEDORA_VERSION` in the Containerfile)
2. build it (`podman build -t aurora-zfs-example:local .`)
3. test it (boot it in a VM or on a test machine and verify ZFS works)
4. only then deploy it to your real machines

If any check fails:

1. stay on the previous working image (change nothing)
2. do not move the example to the new Fedora release yet
3. check again later (upstream pipelines may need hours or days to catch up)

## Short Operator Rule

If you already understand all of the above and just want a quick checklist:

1. Aurora moved to Fedora `N`
2. `akmods:<stream>-N` exists
3. `akmods-zfs:<stream>-N` exists
4. the kernels inside `akmods:<stream>-N` have matching `kmod-zfs` RPMs inside `akmods-zfs:<stream>-N`
5. only then build and test

If any one of those is false, stop and stay on the last working image.
