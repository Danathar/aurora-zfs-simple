#!/usr/bin/bash

set -eoux pipefail

### aurora 02-install-common-kernel-akmods.sh ###
# Remove Existing Kernel, mostly whatever `rpm -qa | grep kernel` spits out
for pkg in kernel kernel{-core,-modules,-modules-core,-modules-extra}; do
    rpm --erase "${pkg}" --nodeps
done

# probably should remove the kmods as well just to be sure
# as they have to be built for the exact kernel version
for pkg in kmod-xone xone-kmod-common kmod-v4l2loopback v4l2loopback; do
    rpm --erase "${pkg}" --nodeps
done

# cleanup leftovers that are not covered by kernel-* packages for some reason
rm -rf /usr/lib/modules

# Install Kernel
dnf5 -y install \
    /tmp/kernel-rpms/kernel-[0-9]*.rpm \
    /tmp/kernel-rpms/kernel-core-*.rpm \
    /tmp/kernel-rpms/kernel-modules-*.rpm

dnf5 versionlock add kernel kernel-devel kernel-devel-matched kernel-core kernel-modules kernel-modules-core kernel-modules-extra

# if you care about this kinda stuff
dnf5 -y install /tmp/rpms/{common,kmods}/*xone*.rpm
dnf5 -y install /tmp/rpms/{kmods,common}/*v4l2loopback*.rpm

mkdir -p /etc/pki/akmods/certs
curl "https://github.com/ublue-os/akmods/raw/refs/heads/main/certs/public_key.der" --retry 3 -Lo /etc/pki/akmods/certs/akmods-ublue.der
### aurora 02-install-common-kernel-akmods.sh ###

KERNEL=$(basename $(find /usr/lib/modules -maxdepth 1 -mindepth 1 -type d | sort -V | tail -n 1))

# Here we actually install zfs
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

dnf5 -y install "${ZFS_RPMS[@]}"

# Depmod and autoload
depmod -a -v "${KERNEL}"
echo "zfs" >/usr/lib/modules-load.d/zfs.conf

export DRACUT_NO_XATTR=1
/usr/bin/dracut --no-hostonly --kver "${KERNEL}" --reproducible -v --add "ostree fido2 tpm2-tss pkcs11 pcsc" -f "/lib/modules/${KERNEL}/initramfs.img"
chmod 0600 "/lib/modules/${KERNEL}/initramfs.img"
