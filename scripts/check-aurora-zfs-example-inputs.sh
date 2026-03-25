#!/usr/bin/env bash
#
# Script: scripts/check-aurora-zfs-example-inputs.sh
# What: Checks whether the simple Aurora ZFS example currently has a coherent
#       set of upstream inputs.
# Doing: Detects the Fedora version from Aurora image labels, verifies that
#        the matching `ublue-os/akmods` and `ublue-os/akmods-zfs` images exist,
#        then compares kernel-specific tags published in both repos.
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

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'ERROR: required command not found: %s\n' "$cmd" >&2
    exit 2
  fi
}

extract_label_value() {
  local key="$1"
  local content="$2"

  sed -n "s/^[[:space:]]*\"${key}\":[[:space:]]*\"\([^\"]*\)\".*/\1/p" <<<"$content" | head -n 1
}

fedora_version_from_aurora_image() {
  local image="$1"
  local config
  local ostree_linux
  local fedora

  config="$(skopeo inspect --config "docker://${image}")"
  ostree_linux="$(extract_label_value "ostree.linux" "$config")"

  if [[ -n "$ostree_linux" ]]; then
    fedora="$(sed -n 's/.*\.fc\([0-9]\+\)\..*/\1/p' <<<"$ostree_linux" | head -n 1)"
  fi

  if [[ -z "$fedora" ]]; then
    printf 'ERROR: unable to derive Fedora version from ostree.linux label on %s\n' "$image" >&2
    exit 1
  fi

  printf '%s\n' "$fedora"
}

kernel_releases_from_image_tags() {
  local image="$1"
  local fedora_version="$2"
  local repo
  local base_tag

  repo="${image%:*}"
  base_tag="${image##*:}"

  skopeo list-tags "docker://${repo}" \
    | grep -oE "${base_tag}-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.fc${fedora_version}\.(x86_64|aarch64)" \
    | sed -E "s/^${base_tag}-//" \
    | sort -u
}

require_command skopeo
require_command sed
require_command sort
require_command grep
require_command head
require_command tr

printf 'Checking Aurora example inputs\n'
printf '  Aurora image:   %s\n' "$AURORA_IMAGE"
printf '  Akmods stream:  %s\n' "$AKMODS_STREAM"
printf '\n'

FEDORA_VERSION="$(fedora_version_from_aurora_image "$AURORA_IMAGE" | tr -d '\r\n')"
AKMODS_IMAGE="ghcr.io/ublue-os/akmods:${AKMODS_STREAM}-${FEDORA_VERSION}"
ZFS_IMAGE="ghcr.io/ublue-os/akmods-zfs:${AKMODS_STREAM}-${FEDORA_VERSION}"

printf 'Detected Fedora version in Aurora labels:    %s\n' "$FEDORA_VERSION"
printf 'Expected akmods image:                     %s\n' "$AKMODS_IMAGE"
printf 'Expected ZFS image:                        %s\n' "$ZFS_IMAGE"
printf '\n'

printf 'Step 1: verify the akmods image exists...\n'
skopeo inspect "docker://${AKMODS_IMAGE}" >/dev/null
printf '  OK\n'

printf 'Step 2: verify the ZFS akmods image exists...\n'
skopeo inspect "docker://${ZFS_IMAGE}" >/dev/null
printf '  OK\n\n'

printf 'Step 3: read kernel releases published as akmods tags...\n'
mapfile -t KERNEL_RELEASES < <(kernel_releases_from_image_tags "$AKMODS_IMAGE" "$FEDORA_VERSION")

if [[ "${#KERNEL_RELEASES[@]}" -eq 0 ]]; then
  printf 'ERROR: no kernel-specific tags were found in %s\n' "$AKMODS_IMAGE" >&2
  exit 1
fi

printf '  Found kernel releases:\n'
printf '    %s\n' "${KERNEL_RELEASES[@]}"
printf '\n'

printf 'Step 4: verify that every akmods kernel release has a matching ZFS kernel tag...\n'
mapfile -t ZFS_KERNEL_RELEASES < <(kernel_releases_from_image_tags "$ZFS_IMAGE" "$FEDORA_VERSION")

if [[ "${#ZFS_KERNEL_RELEASES[@]}" -eq 0 ]]; then
  printf 'ERROR: no kernel-specific tags were found in %s\n' "$ZFS_IMAGE" >&2
  exit 1
fi

for kernel_release in "${KERNEL_RELEASES[@]}"; do
  if printf '%s\n' "${ZFS_KERNEL_RELEASES[@]}" | grep -Fxq "$kernel_release"; then
    printf '  OK: found matching ZFS tag for %s\n' "$kernel_release"
  else
    printf 'ERROR: missing matching ZFS tag for %s\n' "$kernel_release" >&2
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
