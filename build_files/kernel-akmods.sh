#!/usr/bin/bash
# Replace Aurora's base kernel with the selected Universal Blue akmods kernel,
# then reinstall common akmods that must match that kernel.

set -eoux pipefail

### aurora 02-install-common-kernel-akmods.sh ###

# Replace base-image kernel RPMs with the kernel from the selected akmods stream.
# Include kernel-devel packages so developer tooling does not keep stale headers
# from the Aurora base image after the runtime kernel has been replaced.
for pkg in kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra kernel-devel kernel-devel-matched; do
    if rpm -q "${pkg}" >/dev/null 2>&1; then
        rpm --erase "${pkg}" --nodeps
    fi
done

# Remove kmods compiled for the base-image kernel; matching versions are installed below
# or by the dedicated ZFS script that runs after the replacement kernel is in place.
for pkg in kmod-xone xone-kmod-common kmod-v4l2loopback v4l2loopback; do
    if rpm -q "${pkg}" >/dev/null 2>&1; then
        rpm --erase "${pkg}" --nodeps
    fi
done

# Remove any inherited ZFS RPMs before deleting /usr/lib/modules. If the base
# image already has ZFS installed, removing the module tree without erasing the
# RPM first leaves rpmdb entries behind but no zfs.ko/spl.ko files. A later
# `dnf5 install` then reports kmod-zfs as "already installed" and does not
# restore the missing modules.
mapfile -t EXISTING_ZFS_PACKAGES < <(
    rpm -qa \
        'kmod-zfs' \
        'zfs' \
        'libnvpair*' \
        'libuutil*' \
        'libzfs*' \
        'libzpool*' \
        'python3-pyzfs' \
        | sort -u
)
if [[ "${#EXISTING_ZFS_PACKAGES[@]}" -gt 0 ]]; then
    rpm --erase "${EXISTING_ZFS_PACKAGES[@]}" --nodeps
fi

rm -rf /usr/lib/modules

dnf5 -y install \
    /tmp/kernel-rpms/kernel-[0-9]*.rpm \
    /tmp/kernel-rpms/kernel-core-*.rpm \
    /tmp/kernel-rpms/kernel-devel-[0-9]*.rpm \
    /tmp/kernel-rpms/kernel-devel-matched-*.rpm \
    /tmp/kernel-rpms/kernel-modules-*.rpm

# Prevent later updates from replacing the kernel without matching kmods.
dnf5 versionlock add kernel kernel-devel kernel-devel-matched kernel-core kernel-modules kernel-modules-core kernel-modules-extra

# Reinstall common akmods for the replacement kernel.
dnf5 -y install /tmp/rpms/{common,kmods}/*xone*.rpm
dnf5 -y install /tmp/rpms/{kmods,common}/*v4l2loopback*.rpm

# Install the ublue akmods Secure Boot public key.
#
# Extracted from the ublue-os-akmods-addons RPM shipped in the same akmods
# image the kmods above were installed from -- not fetched over the network.
# The previous curl of ublue-os/akmods@refs/heads/main was the one unpinned
# external input in this build, and nothing tied what it returned to the kmods
# the certificate is supposed to validate (#115). The addons RPM is built in
# the same akmods CI run that compiled and signed the kmods installed above, so
# for those the certificate and the modules move together by construction.
#
# That does not extend to ZFS. kmod-zfs comes from the separate `akmods-zfs`
# image, on its own mutable tag, so the certificate matching those modules is
# a property to check rather than one this mount provides. post-check.sh's
# check_module_signatures is what checks it, before the image is signed.
addons_rpm=$(find /tmp/rpms -name 'ublue-os-akmods-addons-*.rpm' -print -quit)
if [[ -z "${addons_rpm}" ]]; then
    echo "ERROR: no ublue-os-akmods-addons RPM under /tmp/rpms; cannot install the akmods Secure Boot certificate." >&2
    exit 1
fi
cert_extract_dir=$(mktemp -d)
rpm2cpio "${addons_rpm}" | (cd "${cert_extract_dir}" && cpio -idm --quiet ./etc/pki/akmods/certs/akmods-ublue.der)
# A certificate that does not parse as DER must fail the build here, not
# surface later as an unenrollable MOK on a user's machine.
openssl x509 -inform der -in "${cert_extract_dir}/etc/pki/akmods/certs/akmods-ublue.der" -noout
install -Dm0644 "${cert_extract_dir}/etc/pki/akmods/certs/akmods-ublue.der" /etc/pki/akmods/certs/akmods-ublue.der
rm -rf "${cert_extract_dir}"
### aurora 02-install-common-kernel-akmods.sh ###
