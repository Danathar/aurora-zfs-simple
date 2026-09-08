#!/usr/bin/bash
# Purpose:
#   Validate that the finished image contains a coherent kernel and ZFS stack
#   before CI publishes it. Any failure here should block publishing.
#
# Scope:
#   This script intentionally runs inside the image build, not on a booted
#   machine. It can inspect the assembled filesystem, RPM database, module tree,
#   generated initramfs, and userspace binaries, but it must not depend on
#   runtime hardware or loaded kernel modules.
#
# Not tested here:
#   Real ZFS pool import, `zpool status`, and `zfs --version`. Those belong in
#   post-rebase checks on the actual booted machine.
#
# Execution order is defined in main() at the bottom of the file:
# 1. check_kernel_tree
# 2. check_zfs_packages
# 3. check_zfs_modules
# 4. check_module_signatures
# 5. check_zfs_userspace
# 6. check_initramfs
# 7. check_rpm_payloads

set -euo pipefail

KERNEL=""
INITRAMFS_LIST=""

log() {
    # Use a stable prefix so failures are easy to find in GitHub Actions logs.
    printf 'post-check: %s\n' "$*"
}

fail() {
    # Print failures to stderr and stop the build immediately. Any failure here
    # means the image should not be published.
    printf 'post-check: ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    # Verify an expected userspace command exists somewhere in PATH.
    local cmd=$1
    command -v "${cmd}" >/dev/null 2>&1 || fail "required command not found: ${cmd}"
}

require_file() {
    # Verify an exact path exists.
    local path=$1
    [[ -e "${path}" ]] || fail "required file not found: ${path}"
}

require_glob() {
    # Verify at least one path matches a shell glob. This handles module files
    # that may be compressed or uncompressed, e.g. .ko, .ko.xz, or .ko.zst.
    local description=$1
    local pattern=$2

    if ! compgen -G "${pattern}" >/dev/null; then
        fail "required ${description} not found matching: ${pattern}"
    fi
}

require_rpm() {
    # Verify the RPM database says an exact package name is installed.
    local pkg=$1
    rpm -q "${pkg}" >/dev/null 2>&1 || fail "required RPM is not installed: ${pkg}"
}

require_rpm_glob() {
    # Verify the RPM database has at least one installed package matching a name
    # glob. This is useful for libraries whose ABI number is part of the package
    # name, such as libzfs6 or libnvpair3.
    local description=$1
    local pattern=$2
    local matches

    matches=$(rpm -qa "${pattern}")
    if [[ -z "${matches}" ]]; then
        fail "required RPM not installed for ${description}: ${pattern}"
    fi
}

require_ldd_resolved() {
    # Verify a dynamically linked executable has no missing shared libraries.
    # This is a build-safe userspace check because it only reads the binary and
    # dynamic linker metadata; it does not execute the tool's real functionality.
    local binary=$1
    local ldd_output

    require_file "${binary}"
    ldd_output=$(ldd "${binary}")
    if grep -q 'not found' <<<"${ldd_output}"; then
        printf '%s\n' "${ldd_output}" >&2
        fail "unresolved shared library dependency for ${binary}"
    fi
}

require_module_signed() {
    # Verify a module carries a signature naming the certificate this image
    # installs for MOK enrollment.
    #
    # The kernel records the signer's X.509 commonName in the module's
    # signature, which is what `modinfo -F signer` prints; an unsigned module
    # prints nothing at all. Comparing that against the commonName of
    # /etc/pki/akmods/certs/akmods-ublue.der is what ties the trust anchor the
    # image ships to the modules it is supposed to authorize.
    local kernel=$1 module=$2 expected=$3
    local signer

    # A modinfo that cannot answer is treated as an empty signer rather than
    # letting `set -e` end the script here: the two cases mean the same thing
    # for this gate -- nothing was proven -- and failing through the branch
    # below says so, instead of dying without a message.
    signer=$(modinfo -k "${kernel}" -F signer "${module}" 2>/dev/null |
        sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | head -1) || signer=""

    if [[ -z "${signer}" ]]; then
        fail "${module} carries no module signature; a Secure Boot host that enrolled '${expected}' cannot load it"
    fi

    if [[ "${signer}" != "${expected}" ]]; then
        fail "${module} is signed by '${signer}', not by the certificate this image installs ('${expected}')"
    fi
}

verify_rpm_payload() {
    # Verify critical kmod RPM payloads are not missing or content-modified.
    # Plain `rpm -V` is too strict for rpm-ostree/bootc images because file
    # owner, group, and timestamps may be normalized during image assembly.
    local pkg=$1
    local verify_output
    local line
    local flags
    local payload_flags

    verify_output=$(rpm -V "${pkg}" 2>&1 || true)
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue

        if [[ "${line}" == missing* ]]; then
            printf '%s\n' "${verify_output}" >&2
            fail "RPM verification found missing files for ${pkg}"
        fi

        # Anything that is not a verification line is not evidence of a clean
        # payload. rpm -V writes nine flag columns followed by a space; stderr
        # is merged into this output, so a message such as "package kmod-zfs is
        # not installed" arrives here too, and read as flags it contains no
        # failure letter and passes. This is a fail-closed gate in front of
        # signing, so a line it cannot parse fails rather than being skipped.
        #
        # That case is currently unreachable -- check_zfs_packages runs
        # require_rpm "kmod-zfs" earlier in main() and exits if it is absent --
        # but the gate should not depend on the order of calls in main() for a
        # property nothing states. A new flag letter in a future rpm lands here
        # too, and stopping to look at it is the right outcome.
        if [[ ! "${line}" =~ ^[.?SM5DLUGTP]{9}([[:space:]]|$) ]]; then
            printf '%s\n' "${verify_output}" >&2
            fail "unrecognised rpm -V output for ${pkg}: ${line}"
        fi

        # The first nine characters are rpm's verification flags, one column
        # each, in the order S M 5 D L U G T P. Example: ".....UGT." means only
        # user/group/time differ, which is acceptable here.
        flags=${line:0:9}

        # U, G and T are the three normalized during image assembly. Every
        # other column describes the payload itself: size, mode, digest,
        # device numbers, link target and capabilities.
        payload_flags="${flags:0:5}${flags:8:1}"

        if [[ "${payload_flags}" =~ [SM5DLP] ]]; then
            printf '%s\n' "${verify_output}" >&2
            fail "RPM verification found payload changes for ${pkg}"
        fi

        # rpm writes '?' in a column when it could not run that test at all --
        # the file could not be read, or its link target could not be resolved
        # (rpm -V's READFAIL and READLINKFAIL, which land in the S, 5 and L
        # columns). That is not '.', and treating it as such is what turns a
        # fail-closed gate into one that passes on doubt. Nothing downstream
        # re-checks: the next steps sign and publish.
        if [[ "${payload_flags}" == *'?'* ]]; then
            printf '%s\n' "${verify_output}" >&2
            fail "RPM verification could not check the payload for ${pkg}"
        fi
    done <<<"${verify_output}"
}

require_single_rpm_version() {
    # Verify a group of RPMs all report the same VERSION-RELEASE. This catches
    # split stacks like kmod-zfs from one OpenZFS release but libzfs/zfs from
    # another.
    local description=$1
    shift
    local versions

    mapfile -t versions < <(rpm -q --qf '%{VERSION}-%{RELEASE}\n' "$@" | sort -u)
    if [[ "${#versions[@]}" -ne 1 ]]; then
        printf 'post-check: %s versions found:\n' "${description}" >&2
        printf '  %s\n' "${versions[@]}" >&2
        fail "expected exactly one ${description} version"
    fi
}

check_kernel_tree() {
    log "checking kernel module tree"

    # The image should contain exactly one kernel module tree. Multiple trees can
    # hide accidental old kernel/kmod leftovers; zero means the kernel install failed.
    local kernel_dirs
    mapfile -t kernel_dirs < <(find /usr/lib/modules -maxdepth 1 -mindepth 1 -type d | sort -V)
    if [[ "${#kernel_dirs[@]}" -ne 1 ]]; then
        printf 'post-check: kernel module directories found:\n' >&2
        printf '  %s\n' "${kernel_dirs[@]}" >&2
        fail "expected exactly one kernel module directory, found ${#kernel_dirs[@]}"
    fi

    KERNEL=$(basename "${kernel_dirs[0]}")
    log "selected kernel: ${KERNEL}"

    local kernel_pkg
    local kernel_packages=(
        kernel
        kernel-core
        kernel-devel
        kernel-devel-matched
        kernel-modules
        kernel-modules-core
        kernel-modules-extra
    )

    for kernel_pkg in "${kernel_packages[@]}"; do
        require_rpm "${kernel_pkg}"
        # Make sure each kernel RPM agrees with /usr/lib/modules. If this mismatches,
        # the image can boot one kernel while carrying files or headers for another.
        if [[ "$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' "${kernel_pkg}")" != "${KERNEL}" ]]; then
            fail "${kernel_pkg} RPM does not match /usr/lib/modules kernel ${KERNEL}"
        fi
    done
}

check_zfs_packages() {
    log "checking ZFS packages"

    require_rpm "zfs"
    require_rpm "kmod-zfs"
    require_rpm "python3-pyzfs"
    require_rpm_glob "libnvpair" "libnvpair*"
    require_rpm_glob "libuutil" "libuutil*"
    require_rpm_glob "libzfs" "libzfs*"
    require_rpm_glob "libzpool" "libzpool*"

    # Confirm all ZFS components come from one OpenZFS VERSION-RELEASE.
    local zfs_versioned_packages
    mapfile -t zfs_versioned_packages < <(
        {
            printf '%s\n' kmod-zfs zfs python3-pyzfs
            rpm -qa 'libnvpair[0-9]*' 'libuutil[0-9]*' 'libzfs[0-9]*' 'libzpool[0-9]*'
        } | sort -u
    )
    require_single_rpm_version "ZFS" "${zfs_versioned_packages[@]}"
}

check_zfs_modules() {
    log "checking ZFS kernel modules"

    require_glob "spl kernel module" "/usr/lib/modules/${KERNEL}/extra/zfs/spl.ko*"
    require_glob "zfs kernel module" "/usr/lib/modules/${KERNEL}/extra/zfs/zfs.ko*"

    # `modinfo -k` is safe at build time because it reads module files for the
    # named kernel; it does not load the module.
    depmod -a "${KERNEL}"
    modinfo -k "${KERNEL}" spl >/dev/null 2>&1 || fail "modinfo cannot find spl for ${KERNEL}"
    modinfo -k "${KERNEL}" zfs >/dev/null 2>&1 || fail "modinfo cannot find zfs for ${KERNEL}"

    # Verify each module was built for this exact kernel. modinfo finding the
    # file does not prove vermagic matches; a mismatched module would pass the
    # checks above and then fail to load at boot. The first space-delimited
    # vermagic field is the kernel release string.
    local module vermagic
    for module in spl zfs; do
        vermagic=$(modinfo -k "${KERNEL}" -F vermagic "${module}")
        if [[ "${vermagic%% *}" != "${KERNEL}" ]]; then
            fail "${module} vermagic '${vermagic}' does not match kernel ${KERNEL}"
        fi
    done
}

check_module_signatures() {
    # The certificate installed at /etc/pki/akmods/certs/akmods-ublue.der comes
    # out of the ublue-os-akmods-addons RPM in the `akmods` image, while
    # kmod-zfs comes from the separate `akmods-zfs` image (Containerfile stages
    # `akmods` and `akmods-zfs`, mounted side by side into the same RUN). Those
    # are two upstream images on two mutable tags, so the certificate matching
    # the modules is a property to check, not one the build gets for free -- a
    # pin applied to one FROM line and not the other, or an upstream key
    # rotation landing in one image first, would ship a trust anchor that does
    # not correspond to the modules it is meant to authorize.
    #
    # A user enrolls that certificate into MOK, and the failure it prevents is
    # only visible after the rebase: on a Secure Boot host zfs.ko does not
    # load, and pools do not import. This gate runs before the image is signed
    # and published, which is where the mismatch should stop.
    log "checking ZFS kernel module signatures"

    local cert="/etc/pki/akmods/certs/akmods-ublue.der"
    require_file "${cert}"

    # -nameopt multiline prints one RDN per line as `commonName = value`,
    # which is stable to parse; the default single-line form is not.
    local subject signer_cn
    subject=$(openssl x509 -inform der -in "${cert}" -noout -subject -nameopt multiline 2>&1) ||
        fail "could not read the subject of ${cert}: ${subject}"

    signer_cn=$(printf '%s\n' "${subject}" |
        sed -n 's/^[[:space:]]*commonName[[:space:]]*=[[:space:]]*//p' | head -1)
    if [[ -z "${signer_cn}" ]]; then
        printf '%s\n' "${subject}" >&2
        fail "no commonName in the subject of ${cert}"
    fi
    log "akmods signing certificate: ${signer_cn}"

    local module
    for module in spl zfs; do
        require_module_signed "${KERNEL}" "${module}" "${signer_cn}"
    done
}

check_zfs_userspace() {
    log "checking ZFS userspace and integration files"

    require_command "zfs"
    require_command "zpool"
    require_command "zdb"
    require_command "zed"
    # Do not run `zfs --version` or `zpool --version` here. OpenZFS version
    # commands can try to query the kernel module version, but the image build
    # container is not booted with this image's kernel modules loaded.

    require_ldd_resolved "$(command -v zfs)"
    require_ldd_resolved "$(command -v zpool)"

    require_file "/usr/lib/modules-load.d/zfs.conf"
    grep -qx 'zfs' /usr/lib/modules-load.d/zfs.conf || fail "/usr/lib/modules-load.d/zfs.conf does not contain exactly 'zfs'"
    require_file "/usr/lib/systemd/system-generators/zfs-mount-generator"
    require_file "/usr/lib/systemd/system/zfs-import.target"
    require_file "/usr/lib/systemd/system/zfs-import-cache.service"
    require_file "/usr/lib/systemd/system/zfs-import-scan.service"
    require_file "/usr/lib/systemd/system/zfs-mount.service"
    require_file "/usr/lib/systemd/system/zfs-zed.service"
    require_file "/usr/lib/udev/rules.d/90-zfs.rules"
}

check_initramfs() {
    log "checking initramfs contents"

    # Verify the initramfs was generated and contains ZFS. This catches cases
    # where RPMs and modules exist on disk but the boot image would be missing them.
    require_file "/usr/lib/modules/${KERNEL}/initramfs.img"
    INITRAMFS_LIST=$(lsinitrd "/usr/lib/modules/${KERNEL}/initramfs.img")
    grep -q 'zfs\.ko' <<<"${INITRAMFS_LIST}" || fail "initramfs does not contain zfs.ko"
    grep -q 'spl\.ko' <<<"${INITRAMFS_LIST}" || fail "initramfs does not contain spl.ko"
}

check_rpm_payloads() {
    log "checking RPM file verification for critical kmods"

    verify_rpm_payload "kmod-zfs"
}

main() {
    check_kernel_tree

    check_zfs_packages
    check_zfs_modules
    check_module_signatures
    check_zfs_userspace

    check_initramfs
    check_rpm_payloads

    log "all checks passed"
}

# Only run the checks when this file is executed. Sourcing it defines the
# helpers without touching the system, which is what lets tests/test-post-check.sh
# exercise require_glob, verify_rpm_payload and require_single_rpm_version
# directly instead of only through a 40-minute image build.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
