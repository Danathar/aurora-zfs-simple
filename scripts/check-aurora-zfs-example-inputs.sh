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

# Safety net: stop the script immediately if any command fails (-e), if any
# variable is used before being set (-u), or if any command in a pipeline
# fails (-o pipefail).  Without this, errors could silently pass and the
# script would keep running with bad data.
set -euo pipefail

# --------------------------------------------------------------------------
# Configuration — these two variables control which upstream images we check.
# They can be overridden from the environment, e.g.:
#   AURORA_IMAGE=ghcr.io/ublue-os/aurora:42 ./check-aurora-zfs-example-inputs.sh
#
# The "${VAR:-default}" syntax means: use the value of VAR if it is already
# set in the environment; otherwise fall back to the default value after ":-".
# --------------------------------------------------------------------------
AURORA_IMAGE="${AURORA_IMAGE:-ghcr.io/ublue-os/aurora:latest}"
AKMODS_STREAM="${AKMODS_STREAM:-coreos-stable}"

# --------------------------------------------------------------------------
# Helper function: require_command
# Checks that a command-line tool is installed and available on $PATH.
# If it is missing the script prints an error and exits immediately (exit 2).
#
# How it works:
#   "command -v <name>" prints the path to the binary if it exists, or
#   returns a non-zero exit code if it does not.  We redirect both stdout
#   and stderr to /dev/null so the user only sees our own error message.
# --------------------------------------------------------------------------
require_command() {
  local cmd="$1"                           # store the first argument in a local variable
  if ! command -v "$cmd" >/dev/null 2>&1; then
    # >&2 sends the message to stderr (file descriptor 2) so it shows up
    # as an error rather than normal output.
    printf 'ERROR: required command not found: %s\n' "$cmd" >&2
    exit 2
  fi
}

# --------------------------------------------------------------------------
# Helper function: kernel_releases_from_akmods_image
# Given a container image reference (e.g. ghcr.io/ublue-os/akmods:...),
# this function:
#   1. Pulls the image so we have a local copy.
#   2. Mounts its filesystem so we can read files inside it.
#   3. Finds all kernel-core RPM files in the /kernel-rpms directory.
#   4. Strips the "kernel-core-" prefix and ".rpm" suffix from each filename,
#      leaving just the kernel version string (e.g. "6.12.8-200.fc41.x86_64").
#   5. Prints the unique, sorted list of kernel versions to stdout.
#
# Why "podman unshare":
#   Mounting container images requires a user namespace (a Linux security
#   feature).  "podman unshare" enters that namespace so the mount works
#   without root privileges.  The inner "sh -c '...'" runs a small
#   sub-script inside that namespace.
#
# The odd-looking '"'"' sequences are how you embed a literal single-quote
# inside a single-quoted string in bash.  The pattern is:
#   '  — end the current single-quoted string
#   "'"  — start a double-quoted string containing just a single quote
#   '  — resume the single-quoted string
# We need this in the trap command so the cleanup runs correctly.
#
# The "trap ... EXIT" line tells the shell to automatically unmount the
# image when the sub-script finishes (whether it succeeds or fails), so we
# never leave mounted images behind.
# --------------------------------------------------------------------------
kernel_releases_from_akmods_image() {
  podman unshare sh -c '
    image="$1"

    # Pull the image quietly; discard output since we only care about errors.
    podman pull -q "$image" >/dev/null

    # Mount the image filesystem and store the mount-point path.
    mnt="$(podman image mount "$image")"

    # Register a cleanup handler: when this sub-shell exits for any reason,
    # unmount the image automatically.
    trap '"'"'podman image unmount "$image" >/dev/null'"'"' EXIT

    # Look inside the mounted image for kernel-core RPM files.
    # -maxdepth 1    = only look in the top-level directory, not subdirectories
    # -type f        = only match regular files (not directories or symlinks)
    # -name "..."    = match filenames starting with "kernel-core-" ending in ".rpm"
    # -printf "%f\n" = print just the filename (not the full path), one per line
    #
    # Then pipe through sed to strip the prefix and suffix, leaving the version.
    # Finally sort -u removes duplicates and sorts alphabetically.
    find "$mnt/kernel-rpms" -maxdepth 1 -type f -name "kernel-core-*.rpm" -printf "%f\n" \
      | sed -e "s/^kernel-core-//" -e "s/\\.rpm$//" \
      | sort -u
  ' sh "$1"
  # The "sh" before "$1" is a positional-parameter trick: inside "sh -c 'SCRIPT'
  # arg0 arg1", $0 is set to arg0 (we use "sh" as a placeholder name) and $1 is
  # set to arg1 (the image reference we actually need).
}

# --------------------------------------------------------------------------
# Helper function: matching_zfs_rpm_exists
# Checks whether the ZFS akmods image contains a kmod-zfs RPM that was
# built for a specific kernel release.
#
# Arguments:
#   $1 — the ZFS container image reference
#   $2 — the kernel release string to look for (e.g. "6.12.8-200.fc41.x86_64")
#
# Returns:
#   exit code 0 (success) if at least one matching RPM is found
#   exit code 1 (failure) if no match is found
#
# The logic is similar to kernel_releases_from_akmods_image above:
#   1. Pull and mount the ZFS image.
#   2. Search for kmod-zfs RPMs whose filename starts with the kernel release.
#   3. "-print -quit" tells find to stop after the first match (optimization).
#   4. Pipe to "grep -q ." which succeeds if find printed anything, fails if
#      find printed nothing.
# --------------------------------------------------------------------------
matching_zfs_rpm_exists() {
  local image="$1"             # the ZFS container image to inspect
  local kernel_release="$2"    # the kernel version string to match against

  podman unshare sh -c '
    image="$1"
    kernel_release="$2"
    podman pull -q "$image" >/dev/null
    mnt="$(podman image mount "$image")"
    trap '"'"'podman image unmount "$image" >/dev/null'"'"' EXIT

    # Look for a kmod-zfs RPM matching this kernel release.
    # -print -quit = print the first match and stop searching (we only need
    #   to know if at least one exists, not list all of them).
    # grep -q .    = quietly check if find produced any output at all.
    #   -q means "quiet" (no output), and "." matches any single character,
    #   so this succeeds if there is at least one line of output.
    find "$mnt/rpms/kmods/zfs" -maxdepth 1 -type f -name "kmod-zfs-${kernel_release}*.rpm" -print -quit \
      | grep -q .
  ' sh "$image" "$kernel_release"
}

# --------------------------------------------------------------------------
# Pre-flight: make sure every tool this script depends on is installed.
# If any are missing, require_command will print an error and stop the script.
# --------------------------------------------------------------------------
require_command podman    # container engine (like Docker) for pulling/mounting images
require_command skopeo    # tool for inspecting container registries without pulling
require_command sed       # stream editor for text substitution
require_command sort      # sorts and deduplicates text lines
require_command grep      # searches for patterns in text

# --------------------------------------------------------------------------
# Step 0: Print a header showing what we are about to check, so the user
# can verify the configuration is correct before the slow network calls.
# --------------------------------------------------------------------------
printf 'Checking Aurora example inputs\n'
printf '  Aurora image:   %s\n' "$AURORA_IMAGE"
printf '  Akmods stream:  %s\n' "$AKMODS_STREAM"
printf '\n'

# --------------------------------------------------------------------------
# Detect the Fedora version inside the Aurora image.
#
# "podman run --rm" starts a throwaway container from the Aurora image.
# Inside that container we run "rpm -E %fedora", which tells RPM to expand
# the %fedora macro — this prints just the Fedora version number (e.g. "41").
# --rm means the container is automatically deleted after it exits.
#
# "tr -d '\r\n'" strips any trailing carriage-return or newline characters
# so we get a clean string like "41" with no whitespace.
#
# We need the Fedora version to construct the correct tag names for the
# akmods and akmods-zfs images, since they are tagged per-Fedora-release.
# --------------------------------------------------------------------------
FEDORA_VERSION="$(podman run --rm "$AURORA_IMAGE" rpm -E %fedora | tr -d '\r\n')"

# Build the full image references by combining the stream name and Fedora
# version.  For example: ghcr.io/ublue-os/akmods:coreos-stable-41
AKMODS_IMAGE="ghcr.io/ublue-os/akmods:${AKMODS_STREAM}-${FEDORA_VERSION}"
ZFS_IMAGE="ghcr.io/ublue-os/akmods-zfs:${AKMODS_STREAM}-${FEDORA_VERSION}"

printf 'Detected Fedora version in Aurora userspace: %s\n' "$FEDORA_VERSION"
printf 'Expected akmods image:                     %s\n' "$AKMODS_IMAGE"
printf 'Expected ZFS image:                        %s\n' "$ZFS_IMAGE"
printf '\n'

# --------------------------------------------------------------------------
# Step 1: Use skopeo to check if the akmods image exists in the registry.
#
# "skopeo inspect" fetches metadata about a container image without actually
# downloading the full image.  The "docker://" prefix tells skopeo to use
# the Docker/OCI registry protocol.
#
# We redirect stdout to /dev/null because we only care whether the command
# succeeds (exit 0) or fails (non-zero exit).  If it fails, set -e will
# stop the script automatically.
# --------------------------------------------------------------------------
printf 'Step 1: verify the akmods image exists...\n'
skopeo inspect "docker://${AKMODS_IMAGE}" >/dev/null
printf '  OK\n'

# Step 2: Same check for the ZFS akmods image.
printf 'Step 2: verify the ZFS akmods image exists...\n'
skopeo inspect "docker://${ZFS_IMAGE}" >/dev/null
printf '  OK\n\n'

# --------------------------------------------------------------------------
# Step 3: Pull the akmods image and list the kernel versions it ships.
#
# "mapfile -t KERNEL_RELEASES < <(...)" reads lines of output from the
# function into a bash array called KERNEL_RELEASES.
#   -t  = strip trailing newlines from each line
#   < <(...)  = "process substitution" — runs the command in a sub-process
#     and feeds its stdout as if it were a file.
#
# We use an array (not a plain string) because each kernel release is a
# separate element, which makes the loop in Step 4 reliable — we match
# each version exactly, with no risk of splitting on spaces or other
# characters inside a version string.
# --------------------------------------------------------------------------
printf 'Step 3: read kernel releases published in the akmods image...\n'
mapfile -t KERNEL_RELEASES < <(kernel_releases_from_akmods_image "$AKMODS_IMAGE")

# "${#KERNEL_RELEASES[@]}" is bash syntax for "the number of elements in the
# KERNEL_RELEASES array".  If it is zero, something is wrong — the image
# should always contain at least one kernel.
if [[ "${#KERNEL_RELEASES[@]}" -eq 0 ]]; then
  printf 'ERROR: no kernel-core RPMs were found in %s\n' "$AKMODS_IMAGE" >&2
  exit 1
fi

# Print what we found so the user can sanity-check the versions.
# "${KERNEL_RELEASES[@]}" expands to every element of the array, and printf
# is called once per element because the format string has one %s.
printf '  Found kernel releases:\n'
printf '    %s\n' "${KERNEL_RELEASES[@]}"
printf '\n'

# --------------------------------------------------------------------------
# Step 4: For every kernel version found in akmods, verify that a matching
# ZFS kernel module RPM exists in the akmods-zfs image.
#
# This is the core compatibility check.  If the ZFS image is missing a
# kmod-zfs RPM for any kernel that akmods ships, then building a combined
# image would fail — the ZFS module would not load for that kernel.
#
# The "for ... in" loop iterates over each element of the KERNEL_RELEASES
# array one at a time.
# --------------------------------------------------------------------------
printf 'Step 4: verify that every akmods kernel release has a matching ZFS kmod RPM...\n'
for kernel_release in "${KERNEL_RELEASES[@]}"; do
  if matching_zfs_rpm_exists "$ZFS_IMAGE" "$kernel_release"; then
    printf '  OK: found kmod-zfs for %s\n' "$kernel_release"
  else
    # Print the error to stderr (>&2) so it stands out and can be captured
    # separately from normal output.
    printf 'ERROR: missing kmod-zfs RPM for %s\n' "$kernel_release" >&2
    printf 'STOP: do not move the Aurora example to Fedora %s yet.\n' "$FEDORA_VERSION" >&2
    exit 1
  fi
done
printf '\n'

# --------------------------------------------------------------------------
# If we reach this point, every check passed — all upstream inputs are
# compatible.  Print a summary and suggest next steps for the operator.
# --------------------------------------------------------------------------
printf 'PASS\n'
printf 'The upstream Aurora example inputs look coherent for Fedora %s on %s.\n' "$FEDORA_VERSION" "$AKMODS_STREAM"
printf 'Next steps:\n'
printf '  1. Update the example to Fedora %s if needed.\n' "$FEDORA_VERSION"
printf '  2. Prefer an Aurora stable tag or digest instead of aurora:latest.\n'
printf '  3. Build the image.\n'
printf '  4. Test the image before deploying it.\n'
