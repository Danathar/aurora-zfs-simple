#!/usr/bin/env bash
#
# Writes the shields.io endpoint-badge JSON files behind the README status
# badges.
#
# Two questions a reader should be able to answer from the README alone:
#
#   1. Is there a usable image, and how old is it?  -> last-good-build badge,
#      read straight off the published `:latest` image's Created timestamp.
#   2. If the build is red, why?                    -> openzfs/kernel badge,
#      derived from the two upstream akmods images' `ostree.linux` labels.
#
# Note (2) does not look at build logs at all. This repo does not compile ZFS —
# it assembles prebuilt akmods artifacts — so the dominant failure mode is
# visible in the upstream labels *before* a build ever runs. This is the same
# check AGENTS.md documents as the "60-second diagnosis", just automated. It
# also means the badge goes green again on its own the moment upstream
# re-converges, without waiting for the Sunday build to prove it.
#
# Refusing to guess is a deliberate property: if an input cannot be read, the
# corresponding badge is left at its last known value rather than overwritten
# with something wrong. A stale-but-true badge beats a fresh-but-invented one.

set -euo pipefail

OUT_DIR="${OUT_DIR:-artifacts}"
CONTAINERFILE="${CONTAINERFILE:-Containerfile}"

mkdir -p "$OUT_DIR"

set_output() {
  [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  return 0
}

write_badge() {
  local path="$1" label="$2" message="$3" color="$4"
  jq -n --arg l "$label" --arg m "$message" --arg c "$color" \
    '{schemaVersion: 1, label: $l, message: $m, color: $c}' >"$path"
  echo "Wrote ${path}: ${message}"
}

# Empty output (rather than a hard failure) when the image cannot be read, so a
# transient registry error degrades to "leave the badge alone".
#
# JSON rather than --format: skopeo's Go templates render .Created via Go's
# default time formatting ("2026-07-19 06:04:15.123 +0000 UTC"), which is not
# what `date -d` wants. The JSON field is plain ISO 8601.
inspect_json() {
  local ref="$1"
  shift
  skopeo inspect "$@" "docker://${ref}" 2>/dev/null || true
}

# 7.1.4-200.fc44.x86_64 -> 7.1.4-200. The Fedora release and arch are constant
# across the comparison and only cost badge width.
short_kernel() { printf '%s' "${1%%.fc*}"; }

# ---------------------------------------------------------------------------
# Badge 1: openzfs/kernel compatibility
# ---------------------------------------------------------------------------

# Read the Fedora major from the Containerfile so this never drifts from what
# the build actually pulls.
FEDORA_VERSION="${FEDORA_VERSION:-$(sed -n 's/^ARG FEDORA_VERSION=\([0-9][0-9]*\).*/\1/p' "$CONTAINERFILE" | head -1)}"
if [ -z "$FEDORA_VERSION" ]; then
  echo "Could not read ARG FEDORA_VERSION from ${CONTAINERFILE}" >&2
  exit 1
fi
echo "Fedora version: ${FEDORA_VERSION}"

ostree_linux_of() {
  printf '%s' "$1" | jq -r '.Labels["ostree.linux"] // empty' 2>/dev/null || true
}

# Read the image reference for a build stage out of the Containerfile rather
# than reconstructing it from a stream name. The documented outage workarounds
# edit these FROM lines directly -- pinning both inputs to one kernel tag, or
# mixing coreos-stable akmods with a coreos-testing ZFS kmod -- and a badge that
# kept inspecting the floating tags would report on images the build no longer
# uses. It would show "blocked" after a pin had already fixed the build, and,
# worse, show "in sync" when only one input had been pinned, which is precisely
# the mistake AGENTS.md warns against.
from_ref() {
  local stage="$1" line ref
  line="$(grep -E "^FROM[[:space:]]+[^[:space:]]+[[:space:]]+AS[[:space:]]+${stage}[[:space:]]*$" "$CONTAINERFILE" | head -1)"
  [ -n "$line" ] || return 0
  ref="$(printf '%s' "$line" | awk '{print $2}' | tr -d "\"'")"
  # The Containerfile interpolates the same ARG this script already resolved.
  ref="${ref//\$\{FEDORA_VERSION\}/${FEDORA_VERSION}}"
  ref="${ref//\$FEDORA_VERSION/${FEDORA_VERSION}}"
  printf '%s' "$ref"
}

akmods_ref="$(from_ref akmods)"
akmods_zfs_ref="$(from_ref akmods-zfs)"

echo "akmods ref:     ${akmods_ref:-<not found>}"
echo "akmods-zfs ref: ${akmods_zfs_ref:-<not found>}"

kernel_akmods=""
kernel_zfs=""
if [ -n "$akmods_ref" ] && [ -n "$akmods_zfs_ref" ]; then
  kernel_akmods="$(ostree_linux_of "$(inspect_json "$akmods_ref")")"
  kernel_zfs="$(ostree_linux_of "$(inspect_json "$akmods_zfs_ref")")"
  echo "akmods:     ${kernel_akmods:-<unreadable>}"
  echo "akmods-zfs: ${kernel_zfs:-<unreadable>}"
fi

if [ -z "$kernel_akmods" ] || [ -z "$kernel_zfs" ]; then
  echo "Could not determine both akmods kernels; leaving the openzfs/kernel badge as-is."
  set_output akmods_updated false
elif [ "$kernel_akmods" = "$kernel_zfs" ]; then
  write_badge "${OUT_DIR}/akmods-badge.json" \
    "openzfs/kernel" \
    "in sync ($(short_kernel "$kernel_akmods"))" \
    "brightgreen"
  set_output akmods_updated true
else
  write_badge "${OUT_DIR}/akmods-badge.json" \
    "openzfs/kernel" \
    "blocked: kernel $(short_kernel "$kernel_akmods"), ZFS kmod $(short_kernel "$kernel_zfs")" \
    "red"
  set_output akmods_updated true
fi

# ---------------------------------------------------------------------------
# Badge 2: age of the published :latest image
# ---------------------------------------------------------------------------

# `latest` only moves when a build actually publishes, so during an outage this
# is what tells a reader a working image still exists and how stale it is.
IMAGE_REF="${IMAGE_REF:-}"
if [ -z "$IMAGE_REF" ]; then
  owner="$(printf '%s' "${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER or IMAGE_REF required}" | tr '[:upper:]' '[:lower:]')"
  name="$(printf '%s' "${IMAGE_NAME:?IMAGE_NAME or IMAGE_REF required}" | tr '[:upper:]' '[:lower:]')"
  IMAGE_REF="ghcr.io/${owner}/${name}:latest"
fi

# The first path component of a reference is a registry host only when it
# contains a dot or a port, or is localhost -- otherwise it is a Docker Hub
# namespace and the host is implicit. Getting this wrong would key the auth
# entry on `owner` instead of `ghcr.io`, and skopeo would find no credential
# and inspect anonymously.
registry_host_of() {
  local ref="$1" first="${1%%/*}"
  if [ "$first" = "$ref" ]; then
    printf 'docker.io'
  elif [ "$first" = "localhost" ] ||
    [ "$first" != "${first#*.}" ] ||
    [ "$first" != "${first#*:}" ]; then
    printf '%s' "$first"
  else
    printf 'docker.io'
  fi
}

# The credential reaches skopeo through a 0600 file rather than --creds:
# /proc/<pid>/cmdline is mode 0444, so a token on skopeo's command line is
# readable by every uid on the runner for as long as the inspect runs, and
# lands in any ps capture taken while debugging a hung one. That is the same
# reasoning that makes build.yml sign with `--key env://` rather than a key
# path (tests/test-build-publish.sh). The environment is safer because
# /proc/<pid>/environ is 0600; the file narrows it to the uid that wrote it.
#
# jq reads the pair through env.* rather than --arg so it does not simply move
# the token from skopeo's argv to jq's.
creds_args=()
if [ -n "${REGISTRY_ACTOR:-}" ] && [ -n "${REGISTRY_TOKEN:-}" ]; then
  auth_file="$(mktemp)"
  chmod 600 "$auth_file"
  # shellcheck disable=SC2064 # expand now: auth_file is never reassigned
  trap "rm -f '$auth_file'" EXIT
  REGISTRY_ACTOR="$REGISTRY_ACTOR" REGISTRY_TOKEN="$REGISTRY_TOKEN" \
    jq -n --arg r "$(registry_host_of "$IMAGE_REF")" \
    '{auths: {($r): {auth: ((env.REGISTRY_ACTOR + ":" + env.REGISTRY_TOKEN) | @base64)}}}' \
    >"$auth_file"
  creds_args=(--authfile "$auth_file")
fi

created="$(printf '%s' "$(inspect_json "$IMAGE_REF" "${creds_args[@]}")" | jq -r '.Created // empty' 2>/dev/null || true)"
created_date="${created%%T*}"

# Compare whole days in UTC, matching how a reader reads the date on the badge.
created_epoch="$(date -u -d "$created_date" +%s 2>/dev/null || true)"

if [ -z "$created_date" ] || [ -z "$created_epoch" ]; then
  echo "Could not read a usable Created timestamp from ${IMAGE_REF} (got '${created}'); leaving the last-good-build badge as-is."
  set_output last_good_updated false
else
  today_epoch="$(date -u -d "$(date -u +%F)" +%s)"
  days=$(((today_epoch - created_epoch) / 86400))

  if [ "$days" -le 0 ]; then
    age="today"
  elif [ "$days" -eq 1 ]; then
    age="1 day ago"
  else
    age="${days} days ago"
  fi

  write_badge "${OUT_DIR}/last-good-build-badge.json" \
    "last good build" \
    "${created_date} (${age})" \
    "brightgreen"
  set_output last_good_updated true
fi
