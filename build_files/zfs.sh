#!/usr/bin/bash
#
# Script: build_files/zfs.sh
# What: Replaces the base image's kernel with the akmods kernel, installs the
#       ZFS kernel module and userspace tools, and rebuilds the initramfs.
#       This script runs inside the container during the image build (via a
#       Containerfile "RUN" step).
#
# Prerequisites: The Containerfile must have already copied kernel RPMs into
#       /tmp/kernel-rpms/ and ZFS/kmod RPMs into /tmp/rpms/ (typically by
#       mounting or COPYing from the akmods and akmods-zfs images).
#

# Safety flags (see build.sh for detailed explanation of each flag):
#   -e = exit on any error
#   -o pipefail = fail pipelines if any stage fails
#   -u = error on unset variables
#   -x = print each command before running it (great for build log debugging)
set -eoux pipefail

# =========================================================================
# SECTION: Replace the base kernel with the akmods kernel
# This section is modeled after Aurora's 02-install-common-kernel-akmods.sh
# =========================================================================
### aurora 02-install-common-kernel-akmods.sh ###

# --------------------------------------------------------------------------
# Remove the existing kernel packages that came with the base Aurora image.
# We need to replace them with the specific kernel version from the akmods
# image so that kernel modules (like ZFS) are built for the exact same kernel.
#
# "rpm --erase <package> --nodeps" removes a package without checking
# dependencies.  We use --nodeps because we are about to reinstall a
# different version of the same packages immediately afterward, so the
# temporary dependency breakage is intentional and harmless.
#
# The brace expansion kernel{-core,-modules,...} is a bash shorthand that
# expands to: kernel-core kernel-modules kernel-modules-core kernel-modules-extra
# So this loop removes each of those packages one by one.
# --------------------------------------------------------------------------
for pkg in kernel kernel{-core,-modules,-modules-core,-modules-extra}; do
    rpm --erase "${pkg}" --nodeps
done

# --------------------------------------------------------------------------
# Also remove pre-installed kernel module packages (xone for Xbox controller
# support, v4l2loopback for virtual webcam support).  These were compiled
# against the old kernel and will not work with the new one.  We will
# reinstall versions compiled for the new kernel below.
# --------------------------------------------------------------------------
for pkg in kmod-xone xone-kmod-common kmod-v4l2loopback v4l2loopback; do
    rpm --erase "${pkg}" --nodeps
done

# --------------------------------------------------------------------------
# Delete any leftover kernel module directories.  Some files in
# /usr/lib/modules are not tracked by RPM packages, so "rpm --erase" alone
# may leave orphaned files behind.  We wipe the directory entirely to ensure
# a clean slate before installing the new kernel.
# --------------------------------------------------------------------------
rm -rf /usr/lib/modules

# --------------------------------------------------------------------------
# Install the replacement kernel from the RPM files that were copied into
# /tmp/kernel-rpms/ by the Containerfile.
#
# The glob patterns (e.g. kernel-[0-9]*.rpm) match filenames that start with
# "kernel-" followed by a digit — this avoids accidentally matching packages
# like "kernel-devel" which start with a letter after "kernel-".
#
# dnf5 can install directly from local .rpm files when given file paths
# instead of package names.
# --------------------------------------------------------------------------
dnf5 -y install \
    /tmp/kernel-rpms/kernel-[0-9]*.rpm \
    /tmp/kernel-rpms/kernel-core-*.rpm \
    /tmp/kernel-rpms/kernel-modules-*.rpm

# --------------------------------------------------------------------------
# Lock the kernel version so that future "dnf update" commands (when the user
# runs the image) do not accidentally upgrade the kernel to a version that
# does not have matching ZFS modules.
#
# "dnf5 versionlock add" pins each listed package at its currently installed
# version.  Any "dnf update" will skip these packages until the lock is
# explicitly removed.
# --------------------------------------------------------------------------
dnf5 versionlock add kernel kernel-devel kernel-devel-matched kernel-core kernel-modules kernel-modules-core kernel-modules-extra

# --------------------------------------------------------------------------
# Reinstall the xone (Xbox controller) and v4l2loopback (virtual webcam)
# kernel modules — these are the versions from the akmods image that were
# compiled against the new kernel we just installed.
#
# The brace expansion {common,kmods} means dnf looks in both
# /tmp/rpms/common/ and /tmp/rpms/kmods/ for matching RPM files.
# --------------------------------------------------------------------------
dnf5 -y install /tmp/rpms/{common,kmods}/*xone*.rpm
dnf5 -y install /tmp/rpms/{kmods,common}/*v4l2loopback*.rpm

# --------------------------------------------------------------------------
# Download the ublue-os akmods public signing key.  Kernel modules from
# akmods are cryptographically signed so that Secure Boot can verify them.
# This .der file is the public half of that signing key; the system needs it
# to validate the module signatures at load time.
#
# curl flags:
#   -f  = fail with an error code on HTTP errors (e.g. 404) instead of
#         silently saving an error page as the output file.
#   --retry 3  = retry up to 3 times if the download fails (network hiccup).
#   -L  = follow HTTP redirects (GitHub often redirects to a CDN).
#   -o <path>  = write the downloaded file to this path.
# --------------------------------------------------------------------------
mkdir -p /etc/pki/akmods/certs
curl -f "https://github.com/ublue-os/akmods/raw/refs/heads/main/certs/public_key.der" --retry 3 -Lo /etc/pki/akmods/certs/akmods-ublue.der
### aurora 02-install-common-kernel-akmods.sh ###

# =========================================================================
# SECTION: Detect the installed kernel version
# =========================================================================

# --------------------------------------------------------------------------
# Figure out which kernel version we just installed by looking at the
# directory names under /usr/lib/modules/.  Each installed kernel creates
# a subdirectory named after its version (e.g. "6.12.8-200.fc41.x86_64").
#
# Breaking down the command:
#   find /usr/lib/modules -maxdepth 1 -mindepth 1 -type d
#       Find directories (-type d) that are exactly one level deep inside
#       /usr/lib/modules.  -maxdepth 1 prevents searching deeper.
#       -mindepth 1 excludes the /usr/lib/modules directory itself.
#   sort -V
#       Sort using "version" ordering, which correctly handles version
#       numbers (e.g. 6.9 < 6.10 < 6.12).  Regular alphabetical sort
#       would incorrectly put 6.9 after 6.10.
#   tail -n 1
#       Take only the last (highest version) line.
#   basename "..."
#       Strip the directory path, leaving just the version string
#       (e.g. "6.12.8-200.fc41.x86_64" instead of the full path).
#
# The $(...) syntax is "command substitution" — it runs the command inside
# and replaces itself with the command's stdout output.
# --------------------------------------------------------------------------
KERNEL=$(basename "$(find /usr/lib/modules -maxdepth 1 -mindepth 1 -type d | sort -V | tail -n 1)")

# If KERNEL is empty (-z tests for an empty string), no kernel was found
# and we cannot continue.  [[ ]] is bash's extended test syntax.
if [[ -z "${KERNEL}" ]]; then
    echo "ERROR: No kernel directory found in /usr/lib/modules" >&2
    exit 1
fi

# =========================================================================
# SECTION: Install ZFS
# =========================================================================

# --------------------------------------------------------------------------
# Build an array of all the RPM files (and one regular package) needed for
# a complete ZFS installation.  We collect them into an array so we can
# install everything in a single dnf5 call, which is faster and ensures
# dependencies are resolved together.
#
# What each item is:
#   kmod-zfs-${KERNEL}*  — the ZFS kernel module compiled for our exact kernel
#   libnvpair, libuutil, libzfs, libzpool — ZFS shared libraries needed by
#       the zfs/zpool command-line tools at runtime
#   python3-pyzfs  — Python bindings for ZFS (used by some admin scripts)
#   zfs-*          — the main ZFS userspace utilities (zfs, zpool, etc.)
#   pv             — "pipe viewer", a utility for monitoring data throughput;
#                    useful when piping large ZFS send/receive streams
#
# The glob patterns (e.g. [0-9]) ensure we match versioned library names
# like "libnvpair3" but not unrelated packages.
# --------------------------------------------------------------------------
ZFS_RPMS=(
    /tmp/rpms/kmods/zfs/kmod-zfs-"${KERNEL}"*.rpm
    /tmp/rpms/kmods/zfs/libnvpair[0-9]-*.rpm
    /tmp/rpms/kmods/zfs/libuutil[0-9]-*.rpm
    /tmp/rpms/kmods/zfs/libzfs[0-9]-*.rpm
    /tmp/rpms/kmods/zfs/libzpool[0-9]-*.rpm
    /tmp/rpms/kmods/zfs/python3-pyzfs-*.rpm
    /tmp/rpms/kmods/zfs/zfs-*.rpm
    pv
)

# Install all the ZFS RPMs in one transaction.
# "${ZFS_RPMS[@]}" expands the array so each element becomes a separate
# argument to dnf5 (the [@] means "all elements", and the quotes preserve
# elements that contain spaces, though none do here).
dnf5 -y install "${ZFS_RPMS[@]}"

# =========================================================================
# SECTION: Configure ZFS module loading and rebuild initramfs
# =========================================================================

# --------------------------------------------------------------------------
# "depmod" scans all installed kernel modules and builds a dependency map
# so the kernel knows which modules depend on which other modules.
#   -a  = scan all modules (not just new ones)
#   -v  = verbose output (shows what it finds, useful for debugging)
#   "${KERNEL}" = only process modules for this specific kernel version
#
# This must be run after installing kmod-zfs so the system knows about the
# new ZFS module and its dependencies.
# --------------------------------------------------------------------------
depmod -a -v "${KERNEL}"

# --------------------------------------------------------------------------
# Tell the system to automatically load the "zfs" kernel module at boot.
# Files in /usr/lib/modules-load.d/ are read by systemd-modules-load.service
# during early boot; each line is a module name to load.  The ">" operator
# creates the file (or overwrites it if it exists) with just the text "zfs".
# --------------------------------------------------------------------------
echo "zfs" >/usr/lib/modules-load.d/zfs.conf

# --------------------------------------------------------------------------
# Rebuild the initramfs (initial RAM filesystem).  The initramfs is a small
# filesystem image loaded into memory by the bootloader before the real root
# filesystem is available.  It contains just enough drivers and tools to
# find and mount the real root filesystem.
#
# We need to rebuild it because:
#   1. We replaced the kernel, so the old initramfs has the wrong modules.
#   2. We need ZFS support in the initramfs if the root filesystem is ZFS.
#
# Environment variable:
#   DRACUT_NO_XATTR=1 — tells dracut not to preserve extended attributes,
#       which can cause issues in container builds where the filesystem may
#       not support xattrs.
#
# dracut flags:
#   --no-hostonly  = build a generic initramfs that works on any hardware,
#                    not just the current machine (important because we are
#                    building inside a container, not on the target machine).
#   --kver "${KERNEL}"  = build for this specific kernel version.
#   --reproducible = make the output deterministic (same inputs always
#                    produce the same output), which helps with caching and
#                    verification.
#   -v             = verbose output for debugging.
#   --add "..."    = include these extra dracut modules in the initramfs:
#       ostree     — support for OSTree-based root filesystems (used by
#                    Fedora Atomic / bootc images)
#       fido2      — support for FIDO2 hardware security keys (for disk
#                    unlock)
#       tpm2-tss   — support for TPM 2.0 chips (for automatic disk unlock)
#       pkcs11     — support for PKCS#11 smartcards/tokens
#       pcsc       — support for PC/SC smartcard readers
#   -f "<path>"    = force overwrite and write the output to this path.
#                    The initramfs must live next to the kernel's modules
#                    directory so the bootloader can find it.
# --------------------------------------------------------------------------
export DRACUT_NO_XATTR=1
/usr/bin/dracut --no-hostonly --kver "${KERNEL}" --reproducible -v --add "ostree fido2 tpm2-tss pkcs11 pcsc" -f "/lib/modules/${KERNEL}/initramfs.img"

# --------------------------------------------------------------------------
# Restrict the initramfs file permissions to owner-read-write only (0600).
# The initramfs can contain sensitive data (encryption keys, security tokens)
# so it should not be world-readable.  The leading 0 means the number is in
# octal (base 8), which is the standard format for Unix file permissions.
#   0600 = owner can read+write, nobody else can do anything.
# --------------------------------------------------------------------------
chmod 0600 "/lib/modules/${KERNEL}/initramfs.img"
