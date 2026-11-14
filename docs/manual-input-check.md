# Fedora Release Input Check

This repo intentionally does not include scripts or local build helpers for
checking upstream inputs. Before moving to the next Fedora major release, check
the Universal Blue package tags yourself.

## What Must Match

For a Fedora release `N`, these inputs need to exist and line up. The block
names the base image the `Containerfile` uses now:

```text
ghcr.io/ublue-os/aurora-dx:stable-44.20261110.1
ghcr.io/ublue-os/akmods:coreos-stable-N-x86_64
ghcr.io/ublue-os/akmods-zfs:coreos-stable-N-x86_64
```

The base is normally `aurora-dx:stable`. It is pinned to the last Fedora 44
build for now (see "Base Image Guard"). When checking release `N`, check
`aurora-dx:stable`, because that is the tag the bump returns to.

The kernel provided by `akmods:coreos-stable-N-x86_64` must have matching ZFS
kmods in the corresponding `akmods-zfs` image.

ZFS userspace RPMs are installed from the same `akmods-zfs` artifact as
`kmod-zfs`, so they should match automatically. If manually inspecting the
artifact, check that it contains one coherent OpenZFS release for `kmod-zfs`,
`zfs`, `libzfs`, `libzpool`, `libnvpair`, `libuutil`, and `python3-pyzfs`.

## How To Check The Inputs

These checks can be run from any shell where you have `skopeo`, `podman`, and
`rpm` available. The akmods artifact images are RPM payload containers and may
not contain a shell, so inspect them by copying the RPM directories out with
`podman cp` instead of running commands inside the container.

Set the Fedora release you want to inspect:

```bash
FEDORA_VERSION=45
AKMODS_TAG="coreos-stable-${FEDORA_VERSION}-x86_64"
```

Check that the expected artifact tags exist:

```bash
skopeo inspect --format '{{.Digest}}' "docker://ghcr.io/ublue-os/akmods:${AKMODS_TAG}"
skopeo inspect --format '{{.Digest}}' "docker://ghcr.io/ublue-os/akmods-zfs:${AKMODS_TAG}"
```

Copy the RPM payloads to a temporary directory:

```bash
tmpdir=$(mktemp -d)

akmods_cid=$(podman create "ghcr.io/ublue-os/akmods:${AKMODS_TAG}")
podman cp "${akmods_cid}:/kernel-rpms" "${tmpdir}/kernel-rpms"
podman rm "${akmods_cid}" >/dev/null

zfs_cid=$(podman create "ghcr.io/ublue-os/akmods-zfs:${AKMODS_TAG}")
podman cp "${zfs_cid}:/rpms/kmods/zfs" "${tmpdir}/zfs-rpms"
podman rm "${zfs_cid}" >/dev/null
```

Check the kernel version published by the base akmods artifact:

```bash
rpm -qp --qf "%{VERSION}-%{RELEASE}.%{ARCH}\n" \
  "${tmpdir}"/kernel-rpms/kernel-core-*.rpm
```

Save that value as the kernel you expect ZFS to match. For example:

```bash
KERNEL="6.19.14-101.fc44.x86_64"
```

Check that the ZFS artifact has a kmod for that exact kernel and one coherent
OpenZFS userspace release:

```bash
echo "ZFS kmods:"
for rpm in "${tmpdir}"/zfs-rpms/kmod-zfs-*.rpm; do
  basename "${rpm}"
  rpm -qp --qf "  %{NAME} %{VERSION}-%{RELEASE}\n" "${rpm}"
  rpm -qpl "${rpm}" | grep "/lib/modules/"
done

echo
echo "ZFS userspace:"
rpm -qp --qf "%{NAME} %{VERSION}-%{RELEASE}\n" \
  "${tmpdir}"/zfs-rpms/zfs-*.rpm \
  "${tmpdir}"/zfs-rpms/libzfs*.rpm \
  "${tmpdir}"/zfs-rpms/libzpool*.rpm \
  "${tmpdir}"/zfs-rpms/libnvpair*.rpm \
  "${tmpdir}"/zfs-rpms/libuutil*.rpm \
  "${tmpdir}"/zfs-rpms/python3-pyzfs-*.rpm \
  | sort -u
```

Good signs:

- the `kmod-zfs` RPM filename includes the expected kernel version
- `kmod-zfs`, `zfs`, the ZFS libraries, and `python3-pyzfs` show the same
  OpenZFS version/release
- there is not a mixture of old and new OpenZFS releases in the same artifact

Clean up the temporary directory when done:

```bash
rm -rf "${tmpdir}"
```

After these manual checks, still let GitHub Actions build the image. The build's
`post-check.sh` performs the final validation against the actual assembled image
before it is published.

## When Fedora `N+1` Is Released

Do not immediately change `FEDORA_VERSION`.

First check that the next-release tags exist. For example, before moving from
Fedora 44 to Fedora 45, check for:

```text
ghcr.io/ublue-os/akmods:coreos-stable-45-x86_64
ghcr.io/ublue-os/akmods-zfs:coreos-stable-45-x86_64
```

Then check that ZFS has kmods for the same kernel release that `akmods` is
publishing. Userspace should come from the same ZFS artifact image and should
represent the same ZFS release as the matching kmod.

If they line up, update the `Containerfile`:

```Dockerfile
ARG FEDORA_VERSION=45
```

If `AURORA_TAG` is pinned to a dated Fedora 44 build (see "Base Image Guard"
below), set it back to `stable` in the same change.

If they do not line up, leave `FEDORA_VERSION` alone and stay on the last
working image.

## Base Image Guard

The base image normally tracks Aurora DX stable, with `ARG AURORA_TAG=stable`.
For now it is pinned to the last Fedora 44 stable build:

```Dockerfile
ARG AURORA_IMAGE=ghcr.io/ublue-os/aurora-dx
ARG AURORA_TAG=stable-44.20261110.1
```

The `Containerfile` fails the build if `aurora-dx:stable` has moved to a
different Fedora release than `FEDORA_VERSION`. That prevents accidentally
building a mixed-release image while still allowing stable-channel updates.

When Aurora stable moves to Fedora `N+1` before the akmods tags for `N+1`
exist, that guard fails every build. The response is to pin `AURORA_TAG` to the
last dated Fedora `N` stable build, as above, and remove
the pin when `FEDORA_VERSION` moves. Aurora userspace is frozen while the pin
stands. This was done for Fedora 45 in #499.
