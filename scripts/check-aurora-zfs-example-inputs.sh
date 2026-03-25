#!/usr/bin/env bash
#
# Script: scripts/check-aurora-zfs-example-inputs.sh
# What: Checks whether the simple Aurora ZFS example currently has a coherent
#       set of upstream inputs.
# Doing: Detects the Fedora version in the chosen Aurora image, verifies that
#        the matching `ublue-os/akmods` and `ublue-os/akmods-zfs` images exist,
#        then compares the kernel RPMs in `akmods` against the `kmod-zfs` RPMs
#        published in `akmods-zfs`.
# Why: This example is intentionally simple and does not contain the larger
#      input-resolution and gating pipeline used by more automated repos. The
#      operator needs a repeatable pre-build check before moving to a new Fedora
#      release.
# Goal: Exit 0 only when the upstream Aurora, akmods, and ZFS inputs appear to
#       line up well enough to justify a build-and-test cycle.
#
set -euo pipefail

AURORA_IMAGE="${AURORA_IMAGE:-ghcr.io/ublue-os/aurora:latest}"
AKMODS_STREAM="${AKMODS_STREAM:-coreos-stable}"

# Fail early with a clear message when a required CLI is missing.
require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'ERROR: required command not found: %s\n' "$cmd" >&2
    exit 2
  fi
}

# Pull and mount the akmods image, then enumerate kernel-core RPM versions.
kernel_releases_from_akmods_image() {
  podman unshare sh -c '
    image="$1"
    podman pull -q "$image" >/dev/null
    mnt="$(podman image mount "$image")"
    trap '"'"'podman image unmount "$image" >/dev/null'"'"' EXIT
    find "$mnt/kernel-rpms" -maxdepth 1 -type f -name "kernel-core-*.rpm" -printf "%f\n" \
      | sed -e "s/^kernel-core-//" -e "s/\\.rpm$//" \
      | sort -u
  ' sh "$1"
}

# Return success when at least one matching kmod-zfs RPM exists for a kernel release.
matching_zfs_rpm_exists() {
  local image="$1"
  local kernel_release="$2"

  podman unshare sh -c '
    image="$1"
    kernel_release="$2"
    podman pull -q "$image" >/dev/null
    mnt="$(podman image mount "$image")"
    trap '"'"'podman image unmount "$image" >/dev/null'"'"' EXIT
    find "$mnt/rpms/kmods/zfs" -maxdepth 1 -type f -name "kmod-zfs-${kernel_release}*.rpm" -print -quit \
      | grep -q .
  ' sh "$image" "$kernel_release"
}

require_command podman
require_command skopeo
require_command sed
require_command sort
require_command grep

# Discover Fedora from the Aurora userspace because downstream tags are Fedora-scoped.
printf 'Checking Aurora example inputs\n'
printf '  Aurora image:   %s\n' "$AURORA_IMAGE"
printf '  Akmods stream:  %s\n' "$AKMODS_STREAM"
printf '\n'

FEDORA_VERSION="$(podman run --rm "$AURORA_IMAGE" rpm -E %fedora | tr -d '\r\n')"
AKMODS_IMAGE="ghcr.io/ublue-os/akmods:${AKMODS_STREAM}-${FEDORA_VERSION}"
ZFS_IMAGE="ghcr.io/ublue-os/akmods-zfs:${AKMODS_STREAM}-${FEDORA_VERSION}"

printf 'Detected Fedora version in Aurora userspace: %s\n' "$FEDORA_VERSION"
printf 'Expected akmods image:                     %s\n' "$AKMODS_IMAGE"
printf 'Expected ZFS image:                        %s\n' "$ZFS_IMAGE"
printf '\n'

printf 'Step 1: verify the akmods image exists...\n'
skopeo inspect "docker://${AKMODS_IMAGE}" >/dev/null
printf '  OK\n'

printf 'Step 2: verify the ZFS akmods image exists...\n'
skopeo inspect "docker://${ZFS_IMAGE}" >/dev/null
printf '  OK\n\n'

printf 'Step 3: read kernel releases published in the akmods image...\n'
# mapfile keeps each kernel release as one array element for exact matching later.
mapfile -t KERNEL_RELEASES < <(kernel_releases_from_akmods_image "$AKMODS_IMAGE")

if [[ "${#KERNEL_RELEASES[@]}" -eq 0 ]]; then
  printf 'ERROR: no kernel-core RPMs were found in %s\n' "$AKMODS_IMAGE" >&2
  exit 1
fi

printf '  Found kernel releases:\n'
printf '    %s\n' "${KERNEL_RELEASES[@]}"
printf '\n'

printf 'Step 4: verify that every akmods kernel release has a matching ZFS kmod RPM...\n'
# A single miss means inputs are out of sync, so stop immediately.
for kernel_release in "${KERNEL_RELEASES[@]}"; do
  if matching_zfs_rpm_exists "$ZFS_IMAGE" "$kernel_release"; then
    printf '  OK: found kmod-zfs for %s\n' "$kernel_release"
  else
    printf 'ERROR: missing kmod-zfs RPM for %s\n' "$kernel_release" >&2
    printf 'STOP: do not move the Aurora example to Fedora %s yet.\n' "$FEDORA_VERSION" >&2
    exit 1
  fi
done
printf '\n'

printf 'PASS\n'
printf 'The upstream Aurora example inputs look coherent for Fedora %s on %s.\n' "$FEDORA_VERSION" "$AKMODS_STREAM"
printf 'Next steps:\n'
printf '  1. Update the example to Fedora %s if needed.\n' "$FEDORA_VERSION"
printf '  2. Prefer an Aurora stable tag or digest instead of aurora:latest.\n'
printf '  3. Build the image.\n'
printf '  4. Test the image before deploying it.\n'
