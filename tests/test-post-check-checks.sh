#!/usr/bin/env bash
#
# Tests for five of the seven check_* stages of build_files/post-check.sh:
# check_kernel_tree and check_zfs_packages, which decide purely from what
# rpm(1) and find(1) report, and check_zfs_modules, check_module_signatures and
# check_initramfs, which read files only the finished image has through
# require_file and require_glob.
#
# tests/test-post-check.sh drives the small require_*/verify_* helpers one call
# at a time with a stub that ignores its arguments. The stages above them are a
# different thing to test: their value is in the *wiring* -- which package names
# are demanded, which glob feeds the version comparison, and that a stage's
# verdict survives being assembled from several rpm calls. A stub that answers
# every query identically cannot show any of that, so this file backs rpm with a
# small text database instead and lets the real queries run against it.
#
# The three file-reading stages are reached by pointing require_file and
# require_glob at a scratch root (see run_check and stage_case); the real
# helpers still do the checking. The remaining two are not run here.
# check_zfs_userspace greps /usr/lib/modules-load.d/zfs.conf directly rather
# than through a helper, so no root can be put under it without changing the
# script; check_rpm_payloads is one call to verify_rpm_payload, and
# tests/test-post-check.sh covers it by asserting that call's argument.
#
# The last section is static: it reads the package names these two stages
# demand and holds them against the lists kernel-akmods.sh and zfs.sh erase,
# install and versionlock.

set -uo pipefail

TEST_NAME="test-post-check-checks"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${REPO_ROOT}/build_files/post-check.sh"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "${WORK_ROOT}"' EXIT

case_dir=""
STAGE_ROOT=""
STAGE_KERNEL=""
STATUS=0
OUTPUT=""

# Fresh sandbox per case: its own stub bin directory and its own rpm database.
new_case() {
    case_dir="${WORK_ROOT}/$1"
    mkdir -p "${case_dir}/bin"
    : >"${case_dir}/rpmdb"
    STAGE_ROOT=""
    STAGE_KERNEL=""
}

# find(1) is only ever called one way here -- list the kernel module
# directories -- so this stub replays a canned listing and ignores its
# arguments.
stub_find() {
    cat >"${case_dir}/find.out"
    cat >"${case_dir}/bin/find" <<'STUB'
#!/usr/bin/env bash
cat "$(dirname "$0")/../find.out"
STUB
    chmod +x "${case_dir}/bin/find"
}

# rpm(1) is called four different ways by these two stages, and the answers have
# to agree with each other: `rpm -qa 'libzfs[0-9]*'` returns full NVRA strings
# that are then handed straight back to `rpm -q --qf`, so a stub that only
# understood bare package names would pass a test the real script fails. Back it
# with a database instead -- one "NAME VERSION RELEASE ARCH" record per line --
# and answer each query from that.
stub_rpm() {
    cat >"${case_dir}/bin/rpm" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail

db="$(dirname "$0")/../rpmdb"

all=0
fmt=""
keys=()
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -qa) all=1 ;;
        -q) ;;
        --qf | --queryformat)
            fmt="$2"
            shift
            ;;
        *) keys+=("$1") ;;
    esac
    shift
done

if [[ "${all}" -eq 1 ]]; then
    # `rpm -qa PATTERN...` prints the full NVRA of every installed package whose
    # *name* matches one of the shell globs, and prints nothing at all when none
    # do. No pattern means every package.
    while read -r name version release arch; do
        [[ -n "${name}" ]] || continue
        nvra="${name}-${version}-${release}.${arch}"
        if [[ "${#keys[@]}" -eq 0 ]]; then
            printf '%s\n' "${nvra}"
            continue
        fi
        for pattern in "${keys[@]}"; do
            # shellcheck disable=SC2053 # the pattern is meant to glob-match
            if [[ "${name}" == ${pattern} ]]; then
                printf '%s\n' "${nvra}"
                break
            fi
        done
    done <"${db}"
    exit 0
fi

status=0
for key in "${keys[@]}"; do
    record=""
    while read -r name version release arch; do
        [[ -n "${name}" ]] || continue
        nvra="${name}-${version}-${release}.${arch}"
        # A key is either a bare name or a full NVRA; rpm resolves both.
        if [[ "${key}" == "${name}" || "${key}" == "${nvra}" ]]; then
            record="${version}|${release}|${arch}|${nvra}"
            break
        fi
    done <"${db}"

    if [[ -z "${record}" ]]; then
        printf 'package %s is not installed\n' "${key}"
        status=1
        continue
    fi

    IFS='|' read -r version release arch nvra <<<"${record}"
    if [[ -n "${fmt}" ]]; then
        rendered="${fmt}"
        rendered="${rendered//%\{VERSION\}/${version}}"
        rendered="${rendered//%\{RELEASE\}/${release}}"
        rendered="${rendered//%\{ARCH\}/${arch}}"
        printf '%b' "${rendered}"
    else
        printf '%s\n' "${nvra}"
    fi
done
exit "${status}"
STUB
    chmod +x "${case_dir}/bin/rpm"
}

# Populate the current case's rpm database from stdin.
rpmdb() { cat >"${case_dir}/rpmdb"; }

# Source post-check.sh and run one check_* stage. $0 is deliberately not the
# script's path, so the entry-point guard keeps main() from running.
#
# When a case sets STAGE_ROOT (stage_case does), require_file and require_glob
# are wrapped to look under that directory instead of /, and KERNEL is set to
# STAGE_KERNEL as check_kernel_tree would have left it. The wrappers call the
# real helpers with the prefixed path, so what is checked and what a failure
# says are still post-check.sh's own; the stage under test builds the path.
run_check() {
    OUTPUT="$(
        PATH="${case_dir}/bin:${PATH}" STAGE_ROOT="${STAGE_ROOT}" STAGE_KERNEL="${STAGE_KERNEL}" bash -c '
            source "$1"
            shift
            if [[ -n "${STAGE_ROOT}" ]]; then
                eval "real_$(declare -f require_file)"
                eval "real_$(declare -f require_glob)"
                require_file() { real_require_file "${STAGE_ROOT}$1"; }
                require_glob() { real_require_glob "$1" "${STAGE_ROOT}$2"; }
                KERNEL="${STAGE_KERNEL}"
            fi
            "$@"
        ' "${TEST_NAME}" "${SCRIPT}" "$@" 2>&1
    )"
    STATUS=$?
}

# A coherent image: one module tree, and every kernel RPM reporting the same
# VERSION-RELEASE.ARCH as that tree's directory name.
KERNEL_DIR="6.17.4-200.fc43.x86_64"

matching_kernel_rpmdb() {
    rpmdb <<'EOF'
kernel 6.17.4 200.fc43 x86_64
kernel-core 6.17.4 200.fc43 x86_64
kernel-devel 6.17.4 200.fc43 x86_64
kernel-devel-matched 6.17.4 200.fc43 x86_64
kernel-modules 6.17.4 200.fc43 x86_64
kernel-modules-core 6.17.4 200.fc43 x86_64
kernel-modules-extra 6.17.4 200.fc43 x86_64
EOF
}

# ---------------------------------------------------------------------------
# check_kernel_tree: exactly one module tree
# ---------------------------------------------------------------------------

new_case kernel-tree-single
stub_find <<EOF
/usr/lib/modules/${KERNEL_DIR}
EOF
stub_rpm
matching_kernel_rpmdb
run_check check_kernel_tree
assert_eq "one module tree with matching kernel RPMs passes" 0 "${STATUS}"
assert_contains "the selected kernel is logged for the build log" \
    "${OUTPUT}" "post-check: selected kernel: ${KERNEL_DIR}"

new_case kernel-tree-none
stub_find </dev/null
stub_rpm
matching_kernel_rpmdb
run_check check_kernel_tree
assert_eq "no module tree at all is a failure, not an empty pass" 1 "${STATUS}"
assert_contains "the failure counts what it found" \
    "${OUTPUT}" "expected exactly one kernel module directory, found 0"

new_case kernel-tree-two
# Two trees is the leftover-kernel case: the image would carry modules for a
# kernel it does not boot.
stub_find <<EOF
/usr/lib/modules/6.17.3-200.fc43.x86_64
/usr/lib/modules/${KERNEL_DIR}
EOF
stub_rpm
matching_kernel_rpmdb
run_check check_kernel_tree
assert_eq "a leftover second module tree fails" 1 "${STATUS}"
assert_contains "the failure counts what it found" \
    "${OUTPUT}" "expected exactly one kernel module directory, found 2"
assert_contains "and lists the first directory for diagnosis" \
    "${OUTPUT}" "/usr/lib/modules/6.17.3-200.fc43.x86_64"
assert_contains "and the second" "${OUTPUT}" "/usr/lib/modules/${KERNEL_DIR}"

new_case kernel-tree-exports-kernel
# check_zfs_modules and check_initramfs build their paths out of KERNEL, so the
# global this stage leaves behind is a contract between stages, not a local.
stub_find <<EOF
/usr/lib/modules/${KERNEL_DIR}
EOF
stub_rpm
matching_kernel_rpmdb
OUTPUT="$(
    PATH="${case_dir}/bin:${PATH}" bash -c '
        source "$1"
        check_kernel_tree
        printf "KERNEL=%s\n" "${KERNEL}"
    ' "${TEST_NAME}" "${SCRIPT}" 2>&1
)"
STATUS=$?
assert_eq "the stage succeeds" 0 "${STATUS}"
assert_contains "KERNEL is left holding the directory's basename, not its path" \
    "${OUTPUT}" "KERNEL=${KERNEL_DIR}"

# ---------------------------------------------------------------------------
# check_kernel_tree: every kernel RPM must agree with the module tree
# ---------------------------------------------------------------------------

new_case kernel-rpm-absent
stub_find <<EOF
/usr/lib/modules/${KERNEL_DIR}
EOF
stub_rpm
# kernel-devel-matched left out: the headers package developer tooling picks up.
rpmdb <<'EOF'
kernel 6.17.4 200.fc43 x86_64
kernel-core 6.17.4 200.fc43 x86_64
kernel-devel 6.17.4 200.fc43 x86_64
kernel-modules 6.17.4 200.fc43 x86_64
kernel-modules-core 6.17.4 200.fc43 x86_64
kernel-modules-extra 6.17.4 200.fc43 x86_64
EOF
run_check check_kernel_tree
assert_eq "a missing kernel RPM fails" 1 "${STATUS}"
assert_contains "the failure names the package that is not installed" \
    "${OUTPUT}" "required RPM is not installed: kernel-devel-matched"

new_case kernel-rpm-version-skew
stub_find <<EOF
/usr/lib/modules/${KERNEL_DIR}
EOF
stub_rpm
# kernel-core one patch release behind the module tree: the image would boot one
# kernel while carrying another's files.
rpmdb <<'EOF'
kernel 6.17.4 200.fc43 x86_64
kernel-core 6.17.3 200.fc43 x86_64
kernel-devel 6.17.4 200.fc43 x86_64
kernel-devel-matched 6.17.4 200.fc43 x86_64
kernel-modules 6.17.4 200.fc43 x86_64
kernel-modules-core 6.17.4 200.fc43 x86_64
kernel-modules-extra 6.17.4 200.fc43 x86_64
EOF
run_check check_kernel_tree
assert_eq "a kernel RPM from another build fails" 1 "${STATUS}"
assert_contains "the failure names the offending package and the tree it disagrees with" \
    "${OUTPUT}" "kernel-core RPM does not match /usr/lib/modules kernel ${KERNEL_DIR}"

new_case kernel-rpm-release-skew
stub_find <<EOF
/usr/lib/modules/${KERNEL_DIR}
EOF
stub_rpm
# Same VERSION, different RELEASE. Comparing only %{VERSION} would let this
# through.
rpmdb <<'EOF'
kernel 6.17.4 200.fc43 x86_64
kernel-core 6.17.4 200.fc43 x86_64
kernel-devel 6.17.4 200.fc43 x86_64
kernel-devel-matched 6.17.4 200.fc43 x86_64
kernel-modules 6.17.4 200.fc43 x86_64
kernel-modules-core 6.17.4 200.fc43 x86_64
kernel-modules-extra 6.17.4 199.fc43 x86_64
EOF
run_check check_kernel_tree
assert_eq "a release-only difference still fails" 1 "${STATUS}"
assert_contains "the failure names the package whose release differs" \
    "${OUTPUT}" "kernel-modules-extra RPM does not match /usr/lib/modules kernel"

new_case kernel-rpm-arch-skew
stub_find <<EOF
/usr/lib/modules/${KERNEL_DIR}
EOF
stub_rpm
# Same VERSION-RELEASE, different ARCH. Dropping %{ARCH} from the comparison
# would let this through too.
rpmdb <<'EOF'
kernel 6.17.4 200.fc43 x86_64
kernel-core 6.17.4 200.fc43 x86_64
kernel-devel 6.17.4 200.fc43 aarch64
kernel-devel-matched 6.17.4 200.fc43 x86_64
kernel-modules 6.17.4 200.fc43 x86_64
kernel-modules-core 6.17.4 200.fc43 x86_64
kernel-modules-extra 6.17.4 200.fc43 x86_64
EOF
run_check check_kernel_tree
assert_eq "an arch-only difference still fails" 1 "${STATUS}"
assert_contains "the failure names the package whose arch differs" \
    "${OUTPUT}" "kernel-devel RPM does not match /usr/lib/modules kernel"

# ---------------------------------------------------------------------------
# check_zfs_packages
# ---------------------------------------------------------------------------

# A whole ZFS stack from one OpenZFS release, with the ABI number in the library
# package names as Fedora ships them.
coherent_zfs_rpmdb() {
    rpmdb <<'EOF'
zfs 2.3.4 1.fc44 x86_64
kmod-zfs 2.3.4 1.fc44 x86_64
python3-pyzfs 2.3.4 1.fc44 x86_64
libnvpair3 2.3.4 1.fc44 x86_64
libuutil3 2.3.4 1.fc44 x86_64
libzfs6 2.3.4 1.fc44 x86_64
libzpool6 2.3.4 1.fc44 x86_64
EOF
}

new_case zfs-packages-coherent
stub_rpm
coherent_zfs_rpmdb
run_check check_zfs_packages
assert_eq "one OpenZFS release across the whole stack passes" 0 "${STATUS}"
assert_contains "the stage announces itself in the build log" \
    "${OUTPUT}" "post-check: checking ZFS packages"

new_case zfs-packages-missing-named
stub_rpm
# python3-pyzfs is required by name, not by glob.
rpmdb <<'EOF'
zfs 2.3.4 1.fc44 x86_64
kmod-zfs 2.3.4 1.fc44 x86_64
libnvpair3 2.3.4 1.fc44 x86_64
libuutil3 2.3.4 1.fc44 x86_64
libzfs6 2.3.4 1.fc44 x86_64
libzpool6 2.3.4 1.fc44 x86_64
EOF
run_check check_zfs_packages
assert_eq "a missing exactly-named package fails" 1 "${STATUS}"
assert_contains "the failure names it" \
    "${OUTPUT}" "required RPM is not installed: python3-pyzfs"

new_case zfs-packages-missing-kmod
stub_rpm
rpmdb <<'EOF'
zfs 2.3.4 1.fc44 x86_64
python3-pyzfs 2.3.4 1.fc44 x86_64
libnvpair3 2.3.4 1.fc44 x86_64
libuutil3 2.3.4 1.fc44 x86_64
libzfs6 2.3.4 1.fc44 x86_64
libzpool6 2.3.4 1.fc44 x86_64
EOF
run_check check_zfs_packages
assert_eq "userspace ZFS without the kmod fails" 1 "${STATUS}"
assert_contains "the failure names the kmod" \
    "${OUTPUT}" "required RPM is not installed: kmod-zfs"

new_case zfs-packages-missing-abi-library
stub_rpm
# libzpool is required by glob because its ABI number is part of the name.
rpmdb <<'EOF'
zfs 2.3.4 1.fc44 x86_64
kmod-zfs 2.3.4 1.fc44 x86_64
python3-pyzfs 2.3.4 1.fc44 x86_64
libnvpair3 2.3.4 1.fc44 x86_64
libuutil3 2.3.4 1.fc44 x86_64
libzfs6 2.3.4 1.fc44 x86_64
EOF
run_check check_zfs_packages
assert_eq "a missing ABI-numbered library fails" 1 "${STATUS}"
assert_contains "the failure names the description and the glob" \
    "${OUTPUT}" "required RPM not installed for libzpool: libzpool*"

# ---------------------------------------------------------------------------
# check_zfs_packages: the split-stack case, through the real glob wiring
# ---------------------------------------------------------------------------

new_case zfs-packages-split-stack
stub_rpm
# kmod-zfs from one OpenZFS release, the libraries from the previous one. Each
# package exists, so every require_* above passes; only the version comparison
# catches it -- and only if `rpm -qa 'libzfs[0-9]*'` actually feeds it.
rpmdb <<'EOF'
zfs 2.3.4 1.fc44 x86_64
kmod-zfs 2.3.4 1.fc44 x86_64
python3-pyzfs 2.3.4 1.fc44 x86_64
libnvpair3 2.3.3 1.fc44 x86_64
libuutil3 2.3.3 1.fc44 x86_64
libzfs6 2.3.3 1.fc44 x86_64
libzpool6 2.3.3 1.fc44 x86_64
EOF
run_check check_zfs_packages
assert_eq "libraries from an older OpenZFS release than the kmod fail" 1 "${STATUS}"
assert_contains "the failure names the group" \
    "${OUTPUT}" "expected exactly one ZFS version"
assert_contains "and reports the library release it found" "${OUTPUT}" "2.3.3-1.fc44"
assert_contains "and the kmod release it found" "${OUTPUT}" "2.3.4-1.fc44"

new_case zfs-packages-split-named-only
stub_rpm
# The mirror case: the ABI libraries agree, `zfs` userspace does not.
rpmdb <<'EOF'
zfs 2.3.3 1.fc44 x86_64
kmod-zfs 2.3.4 1.fc44 x86_64
python3-pyzfs 2.3.4 1.fc44 x86_64
libnvpair3 2.3.4 1.fc44 x86_64
libuutil3 2.3.4 1.fc44 x86_64
libzfs6 2.3.4 1.fc44 x86_64
libzpool6 2.3.4 1.fc44 x86_64
EOF
run_check check_zfs_packages
assert_eq "userspace zfs from another release than the kmod fails" 1 "${STATUS}"
assert_contains "the failure names the group" \
    "${OUTPUT}" "expected exactly one ZFS version"

new_case zfs-packages-abi-bump-same-release
stub_rpm
# A pure ABI bump within one OpenZFS release: libzfs6 -> libzfs7 while every
# VERSION-RELEASE stays put. The comparison is on versions, not names, so this
# is deliberately not a failure.
rpmdb <<'EOF'
zfs 2.3.4 1.fc44 x86_64
kmod-zfs 2.3.4 1.fc44 x86_64
python3-pyzfs 2.3.4 1.fc44 x86_64
libnvpair4 2.3.4 1.fc44 x86_64
libuutil4 2.3.4 1.fc44 x86_64
libzfs7 2.3.4 1.fc44 x86_64
libzpool7 2.3.4 1.fc44 x86_64
EOF
run_check check_zfs_packages
assert_eq "a different ABI number at the same release still passes" 0 "${STATUS}"

new_case zfs-packages-unnumbered-library
stub_rpm
# The two globs are not the same: existence is checked with 'libzfs*' but the
# version comparison uses 'libzfs[0-9]*'. A package whose name has no ABI digit
# therefore satisfies the first and is invisible to the second. This documents
# that gap rather than asserting a guard the script does not have.
rpmdb <<'EOF'
zfs 2.3.4 1.fc44 x86_64
kmod-zfs 2.3.4 1.fc44 x86_64
python3-pyzfs 2.3.4 1.fc44 x86_64
libnvpair3 2.3.4 1.fc44 x86_64
libuutil3 2.3.4 1.fc44 x86_64
libzfs-devel 2.3.3 1.fc44 x86_64
libzpool6 2.3.4 1.fc44 x86_64
EOF
run_check check_zfs_packages
assert_eq "an ABI-less library satisfies the existence glob" 0 "${STATUS}"
assert_not_contains "and is left out of the version comparison entirely" \
    "${OUTPUT}" "expected exactly one ZFS version"

new_case zfs-packages-empty-database
stub_rpm
rpmdb </dev/null
run_check check_zfs_packages
assert_eq "an image with no ZFS at all fails" 1 "${STATUS}"
assert_contains "and fails on the first required package, not on the version count" \
    "${OUTPUT}" "required RPM is not installed: zfs"

# ---------------------------------------------------------------------------
# check_zfs_modules, check_module_signatures and check_initramfs
# ---------------------------------------------------------------------------
#
# These three stages read files the finished image has and a host does not:
# the module tree under /usr/lib/modules/KERNEL, its initramfs.img, and the
# certificate at /etc/pki/akmods/certs/akmods-ublue.der. Every one of those
# reads goes through require_file or require_glob, so run_check can point the
# two helpers at a scratch root (stage_case below) and the real helpers still
# do the checking -- only the leading directory changes. The commands the
# stages call (depmod, modinfo, lsinitrd, openssl) are stubs on PATH.
#
# What these cases are for is each stage's failure branches. A real image build
# runs every stage, but only on an image that passes, so a guard deleted from
# one of them -- the vermagic comparison, the zfs.ko grep, the commonName read
# -- still leaves the build green.

# Values of the real certificate, as tests/test-post-check.sh records them.
CERT_CN="ublue kernel"
CERT_SERIAL="7DF87AF5DEE738D9FAC2F8A38219374BE0A180A7"
CERT_SKID="2C:25:06:15:58:B5:02:0C:4B:0D:9C:A5:60:62:E0:0C:6C:DB:04:6A"
MODULE_SIG_KEY="7D:F8:7A:F5:DE:E7:38:D9:FA:C2:F8:A3:82:19:37:4B:E0:A1:80:A7"
OTHER_UBLUE_KEY="17:6E:3C:E6:72:DA:64:B6:F4:27:2F:73:92:F5:A4:6F:3C:CE:86:36"
MODULE_DIR="usr/lib/modules/${KERNEL_DIR}/extra/zfs"
CERT_PATH="etc/pki/akmods/certs/akmods-ublue.der"

# modinfo is asked three things here: whether it can find a module at all
# (`modinfo -k K spl`), and a module's vermagic, signer and sig_key fields.
# Answers are per module and per field -- modinfo.<module>.<field>.out, and
# modinfo.<module>.status for the plain lookup -- because a gate that checked
# only one of spl and zfs is the case worth catching. A field no case
# registered prints nothing, which is what modinfo does for a field a module
# does not carry.
stub_stage_modinfo() {
    cat >"${case_dir}/bin/modinfo" <<'STUB'
#!/usr/bin/env bash
dir="$(dirname "$0")/.."
field=""
module=""
while [[ $# -gt 0 ]]; do
    case "$1" in
    -k) shift 2 ;;
    -F)
        field=$2
        shift 2
        ;;
    *)
        module=$1
        shift
        ;;
    esac
done
if [[ -z "${field}" ]]; then
    [[ -f "${dir}/modinfo.${module}.status" ]] && exit "$(cat "${dir}/modinfo.${module}.status")"
    exit 0
fi
[[ -f "${dir}/modinfo.${module}.${field}.out" ]] && cat "${dir}/modinfo.${module}.${field}.out"
exit 0
STUB
    chmod +x "${case_dir}/bin/modinfo"
}

module_field() { printf '%s\n' "$3" >"${case_dir}/modinfo.$1.$2.out"; }
module_lookup_fails() { printf '1\n' >"${case_dir}/modinfo.$1.status"; }

# openssl is asked for the certificate's subject, serial and subjectKeyIdentifier,
# each by its own option. Each answer is a file; an absent one makes that query
# fail, which is how `-ext subjectKeyIdentifier` answers for a certificate
# without the extension.
stub_openssl() {
    cat >"${case_dir}/bin/openssl" <<'STUB'
#!/usr/bin/env bash
dir="$(dirname "$0")/.."
query=""
for arg in "$@"; do
    case "${arg}" in
    -subject) query=subject ;;
    -serial) query=serial ;;
    subjectKeyIdentifier) query=skid ;;
    esac
done
if [[ -f "${dir}/openssl.${query}.out" ]]; then
    cat "${dir}/openssl.${query}.out"
    exit 0
fi
printf 'openssl stub: no %s\n' "${query}" >&2
exit 1
STUB
    chmod +x "${case_dir}/bin/openssl"
}

cert_answer() { cat >"${case_dir}/openssl.$1.out"; }

# A fresh case whose stages read from a scratch root. Stubs are installed for
# every command the three stages call; each case then lays down only the files
# and answers it needs.
stage_case() {
    new_case "$1"
    STAGE_ROOT="${case_dir}/root"
    STAGE_KERNEL="${KERNEL_DIR}"
    mkdir -p "${STAGE_ROOT}"
    printf '#!/usr/bin/env bash\nexit 0\n' >"${case_dir}/bin/depmod"
    chmod +x "${case_dir}/bin/depmod"
    cat >"${case_dir}/bin/lsinitrd" <<'STUB'
#!/usr/bin/env bash
cat "$(dirname "$0")/../lsinitrd.out"
STUB
    chmod +x "${case_dir}/bin/lsinitrd"
    : >"${case_dir}/lsinitrd.out"
    stub_stage_modinfo
    stub_openssl
}

# Lay a file down under the scratch root.
root_file() {
    mkdir -p "$(dirname "${STAGE_ROOT}/$1")"
    : >"${STAGE_ROOT}/$1"
}

# Both modules on disk and built for the selected kernel.
coherent_modules() {
    root_file "${MODULE_DIR}/spl.ko.xz"
    root_file "${MODULE_DIR}/zfs.ko.xz"
    module_field spl vermagic "${KERNEL_DIR} SMP preempt mod_unload modversions"
    module_field zfs vermagic "${KERNEL_DIR} SMP preempt mod_unload modversions"
}

# The certificate the image installs, answered as openssl prints it.
installed_certificate() {
    root_file "${CERT_PATH}"
    cert_answer subject <<EOF
subject=
    organizationName          = Universal Blue
    organizationalUnitName    = kernel signing
    commonName                = ${CERT_CN}
EOF
    cert_answer serial <<EOF
serial=${CERT_SERIAL}
EOF
    cert_answer skid <<EOF
X509v3 Subject Key Identifier:
    ${CERT_SKID}
EOF
}

# spl and zfs both signed by that certificate's key, identified by serial.
signed_modules() {
    local module
    for module in spl zfs; do
        module_field "${module}" signer "${CERT_CN}"
        module_field "${module}" sig_key "${MODULE_SIG_KEY}"
    done
}

# --- check_zfs_modules ------------------------------------------------------

stage_case zfs-modules-coherent
coherent_modules
run_check check_zfs_modules
assert_eq "both modules present and built for the selected kernel passes" 0 "${STATUS}"
assert_contains "the stage announces itself in the build log" \
    "${OUTPUT}" "post-check: checking ZFS kernel modules"

stage_case zfs-modules-compressed-either-way
# The globs accept a module compressed or not, and the two need not agree.
root_file "${MODULE_DIR}/spl.ko"
root_file "${MODULE_DIR}/zfs.ko.zst"
module_field spl vermagic "${KERNEL_DIR} SMP preempt mod_unload modversions"
module_field zfs vermagic "${KERNEL_DIR} SMP preempt mod_unload modversions"
run_check check_zfs_modules
assert_eq "an uncompressed spl.ko beside a zstd zfs.ko passes" 0 "${STATUS}"

stage_case zfs-modules-spl-missing
root_file "${MODULE_DIR}/zfs.ko.xz"
module_field spl vermagic "${KERNEL_DIR} SMP"
module_field zfs vermagic "${KERNEL_DIR} SMP"
run_check check_zfs_modules
assert_eq "no spl.ko for the selected kernel fails" 1 "${STATUS}"
assert_contains "the failure names the module and the kernel's path" \
    "${OUTPUT}" "required spl kernel module not found matching: ${STAGE_ROOT}/${MODULE_DIR}/spl.ko*"

stage_case zfs-modules-zfs-missing
root_file "${MODULE_DIR}/spl.ko.xz"
module_field spl vermagic "${KERNEL_DIR} SMP"
module_field zfs vermagic "${KERNEL_DIR} SMP"
run_check check_zfs_modules
assert_eq "no zfs.ko for the selected kernel fails" 1 "${STATUS}"
assert_contains "the failure names the module and the kernel's path" \
    "${OUTPUT}" "required zfs kernel module not found matching: ${STAGE_ROOT}/${MODULE_DIR}/zfs.ko*"

stage_case zfs-modules-under-another-kernel
# Modules built and installed for the previous kernel: the files exist, just
# not under the tree this image boots.
root_file "usr/lib/modules/6.17.3-200.fc43.x86_64/extra/zfs/spl.ko.xz"
root_file "usr/lib/modules/6.17.3-200.fc43.x86_64/extra/zfs/zfs.ko.xz"
run_check check_zfs_modules
assert_eq "modules under another kernel's tree fail" 1 "${STATUS}"
assert_contains "and are reported as missing for this one" \
    "${OUTPUT}" "required spl kernel module not found matching: ${STAGE_ROOT}/${MODULE_DIR}/spl.ko*"

stage_case zfs-modules-modinfo-cannot-find-spl
coherent_modules
module_lookup_fails spl
run_check check_zfs_modules
assert_eq "a module modinfo cannot resolve after depmod fails" 1 "${STATUS}"
assert_contains "the failure names the module and the kernel" \
    "${OUTPUT}" "modinfo cannot find spl for ${KERNEL_DIR}"

stage_case zfs-modules-modinfo-cannot-find-zfs
coherent_modules
module_lookup_fails zfs
run_check check_zfs_modules
assert_eq "the same for zfs" 1 "${STATUS}"
assert_contains "the failure names zfs" \
    "${OUTPUT}" "modinfo cannot find zfs for ${KERNEL_DIR}"

stage_case zfs-modules-zfs-vermagic-skew
# The file is where it should be and modinfo finds it, but it was built for the
# previous kernel -- the case that passes every check above and then fails to
# load at boot.
coherent_modules
module_field zfs vermagic "6.17.3-200.fc43.x86_64 SMP preempt mod_unload modversions"
run_check check_zfs_modules
assert_eq "a zfs.ko built for another kernel fails" 1 "${STATUS}"
assert_contains "the failure quotes the vermagic and names the kernel" \
    "${OUTPUT}" "zfs vermagic '6.17.3-200.fc43.x86_64 SMP preempt mod_unload modversions' does not match kernel ${KERNEL_DIR}"

stage_case zfs-modules-spl-vermagic-skew
coherent_modules
module_field spl vermagic "6.17.3-200.fc43.x86_64 SMP preempt mod_unload modversions"
run_check check_zfs_modules
assert_eq "an spl.ko built for another kernel fails too" 1 "${STATUS}"
assert_contains "the failure names spl" \
    "${OUTPUT}" "spl vermagic '6.17.3-200.fc43.x86_64 SMP"

stage_case zfs-modules-vermagic-longer-release
# The release field has to equal the kernel, not merely start with it: a
# +debug or -rt build of the same version is a different kernel to the loader.
coherent_modules
module_field zfs vermagic "${KERNEL_DIR}+debug SMP preempt mod_unload modversions"
run_check check_zfs_modules
assert_eq "a vermagic release that only starts with the kernel's fails" 1 "${STATUS}"
assert_contains "and is reported as a mismatch" \
    "${OUTPUT}" "zfs vermagic '${KERNEL_DIR}+debug"

stage_case zfs-modules-vermagic-empty
# A module with no vermagic field at all has not been shown to match anything.
coherent_modules
: >"${case_dir}/modinfo.zfs.vermagic.out"
run_check check_zfs_modules
assert_eq "a missing vermagic fails rather than passing" 1 "${STATUS}"
assert_contains "and is reported as a mismatch" \
    "${OUTPUT}" "zfs vermagic '' does not match kernel ${KERNEL_DIR}"

# --- check_module_signatures ------------------------------------------------

stage_case module-signatures-coherent
installed_certificate
signed_modules
run_check check_module_signatures
assert_eq "both modules signed by the installed certificate's key passes" 0 "${STATUS}"
assert_contains "the certificate's name, serial and key id are logged" \
    "${OUTPUT}" "post-check: akmods signing certificate: ${CERT_CN} (serial ${CERT_SERIAL}, subject key id ${CERT_SKID})"

stage_case module-signatures-by-subject-key-id
# A signature that names its signer by subjectKeyIdentifier rather than serial.
# This passes only if the stage hands the SKID it read to the comparison, not
# just the serial.
installed_certificate
for module in spl zfs; do
    module_field "${module}" signer "${CERT_CN}"
    module_field "${module}" sig_key "${CERT_SKID}"
done
run_check check_module_signatures
assert_eq "modules identifying the key by subjectKeyIdentifier pass" 0 "${STATUS}"

stage_case module-signatures-no-skid-extension
# subjectKeyIdentifier is an optional extension. A certificate without one still
# offers its serial, and is not an error.
installed_certificate
rm "${case_dir}/openssl.skid.out"
signed_modules
run_check check_module_signatures
assert_eq "a certificate without a subjectKeyIdentifier passes on its serial" 0 "${STATUS}"
assert_contains "and the log names the serial alone" \
    "${OUTPUT}" "post-check: akmods signing certificate: ${CERT_CN} (serial ${CERT_SERIAL})"

stage_case module-signatures-certificate-absent
signed_modules
cert_answer subject <<EOF
subject=
    commonName                = ${CERT_CN}
EOF
cert_answer serial <<<"serial=${CERT_SERIAL}"
run_check check_module_signatures
assert_eq "an image without the certificate fails" 1 "${STATUS}"
assert_contains "the failure names the path users are told to enroll" \
    "${OUTPUT}" "required file not found: ${STAGE_ROOT}/${CERT_PATH}"

stage_case module-signatures-subject-unreadable
installed_certificate
rm "${case_dir}/openssl.subject.out"
signed_modules
run_check check_module_signatures
assert_eq "a certificate openssl cannot read fails" 1 "${STATUS}"
assert_contains "the failure says the subject could not be read" \
    "${OUTPUT}" "could not read the subject of /${CERT_PATH}"

stage_case module-signatures-no-common-name
# Without a commonName there is no name to compare the modules' signer against.
installed_certificate
cert_answer subject <<'EOF'
subject=
    organizationName          = Universal Blue
    organizationalUnitName    = kernel signing
EOF
signed_modules
run_check check_module_signatures
assert_eq "a certificate subject with no commonName fails" 1 "${STATUS}"
assert_contains "the failure says so" \
    "${OUTPUT}" "no commonName in the subject of /${CERT_PATH}"

stage_case module-signatures-serial-unreadable
installed_certificate
rm "${case_dir}/openssl.serial.out"
signed_modules
run_check check_module_signatures
assert_eq "a certificate whose serial cannot be read fails" 1 "${STATUS}"
assert_contains "the failure says the serial could not be read" \
    "${OUTPUT}" "could not read the serial number of /${CERT_PATH}"

stage_case module-signatures-no-key-identifier
# openssl answers, but with an empty serial and no subjectKeyIdentifier: the
# certificate yields no key the modules could be tied to.
installed_certificate
cert_answer serial <<<"serial="
rm "${case_dir}/openssl.skid.out"
signed_modules
run_check check_module_signatures
assert_eq "a certificate yielding no key identifier fails" 1 "${STATUS}"
assert_contains "and fails at the certificate, before any module is compared" \
    "${OUTPUT}" "no key identifier could be read from /${CERT_PATH}"

stage_case module-signatures-spl-other-key
# zfs.ko signed by the installed key, spl.ko by a second key of the same
# vendor. Both modules have to be checked: a Secure Boot host that cannot load
# spl cannot load zfs either.
installed_certificate
signed_modules
module_field spl sig_key "${OTHER_UBLUE_KEY}"
run_check check_module_signatures
assert_eq "spl signed by another key fails even when zfs is right" 1 "${STATUS}"
assert_contains "the failure names spl and the key that signed it" \
    "${OUTPUT}" "spl is signed by key 176E3CE672DA64B6F4272F7392F5A46F3CCE8636"

stage_case module-signatures-zfs-other-key
installed_certificate
signed_modules
module_field zfs sig_key "${OTHER_UBLUE_KEY}"
run_check check_module_signatures
assert_eq "zfs signed by another key fails" 1 "${STATUS}"
assert_contains "the failure names zfs" \
    "${OUTPUT}" "zfs is signed by key 176E3CE672DA64B6F4272F7392F5A46F3CCE8636"

# --- check_initramfs --------------------------------------------------------

stage_case initramfs-carries-both-modules
root_file "usr/lib/modules/${KERNEL_DIR}/initramfs.img"
cat >"${case_dir}/lsinitrd.out" <<EOF
-rw-r--r--   1 root root  1830104 Jan  1 00:00 usr/lib/modules/${KERNEL_DIR}/extra/zfs/spl.ko.xz
-rw-r--r--   1 root root  4002120 Jan  1 00:00 usr/lib/modules/${KERNEL_DIR}/extra/zfs/zfs.ko.xz
EOF
run_check check_initramfs
assert_eq "an initramfs listing both modules passes" 0 "${STATUS}"
assert_contains "the stage announces itself in the build log" \
    "${OUTPUT}" "post-check: checking initramfs contents"

stage_case initramfs-absent
run_check check_initramfs
assert_eq "no initramfs for the selected kernel fails" 1 "${STATUS}"
assert_contains "the failure names the kernel's initramfs path" \
    "${OUTPUT}" "required file not found: ${STAGE_ROOT}/usr/lib/modules/${KERNEL_DIR}/initramfs.img"

stage_case initramfs-without-zfs
# The case the stage exists for: RPMs and modules on disk, and a boot image that
# cannot import a root pool.
root_file "usr/lib/modules/${KERNEL_DIR}/initramfs.img"
cat >"${case_dir}/lsinitrd.out" <<EOF
-rw-r--r--   1 root root  1830104 Jan  1 00:00 usr/lib/modules/${KERNEL_DIR}/extra/zfs/spl.ko.xz
-rw-r--r--   1 root root    20480 Jan  1 00:00 usr/lib/dracut/hooks/zfs-load-module.sh
EOF
run_check check_initramfs
assert_eq "an initramfs without zfs.ko fails" 1 "${STATUS}"
assert_contains "the failure names zfs.ko" \
    "${OUTPUT}" "initramfs does not contain zfs.ko"

stage_case initramfs-without-spl
root_file "usr/lib/modules/${KERNEL_DIR}/initramfs.img"
cat >"${case_dir}/lsinitrd.out" <<EOF
-rw-r--r--   1 root root  4002120 Jan  1 00:00 usr/lib/modules/${KERNEL_DIR}/extra/zfs/zfs.ko.xz
EOF
run_check check_initramfs
assert_eq "an initramfs without spl.ko fails" 1 "${STATUS}"
assert_contains "the failure names spl.ko" \
    "${OUTPUT}" "initramfs does not contain spl.ko"

# --- the package sets these stages demand, against the build that installs them
#
# The cases above feed each stage a database. They cannot say whether the names
# the stages demand are the names the build installs, because that list is
# written out again in each build script:
#
#   * kernel-akmods.sh erases the base kernel packages by name, installs the
#     replacement from globs, and versionlocks the set by name;
#   * kernel-akmods.sh erases any inherited ZFS packages by name, and zfs.sh
#     installs the OpenZFS set from globs;
#   * check_kernel_tree and check_zfs_packages require their own copies, and
#     check_zfs_packages writes the ZFS set a second time for its version
#     comparison.
#
# A package added to one of those lists and not the others fails nowhere until
# it matters. Left out of the versionlock, a later `dnf5 upgrade` in a derived
# image can move that package off the kernel the kmods were built for; left out
# of the version comparison, a library from another OpenZFS release passes the
# gate. So the lists are read out of the scripts and held to post-check.sh's,
# which is the one that blocks a publish.
#
# Each extractor is run against a fixture with known answers first: one that
# returned nothing would make every comparison below agree about nothing.

KERNEL_AKMODS_SH="${REPO_ROOT}/build_files/kernel-akmods.sh"
ZFS_SH="${REPO_ROOT}/build_files/zfs.sh"
FIXTURES="${WORK_ROOT}/fixtures"
mkdir -p "${FIXTURES}"

# One name per line, sorted, for set comparison.
as_set() { tr ' ' '\n' | sed '/^$/d' | sort -u; }

# The kernel packages kernel-akmods.sh erases: the words of its
# `for pkg in kernel ...; do` loop.
erased_kernel_packages() {
    sed -nE 's/^for pkg in (kernel[^;]*); do$/\1/p' "$1" | as_set
}

# The kernel packages kernel-akmods.sh versionlocks.
locked_kernel_packages() {
    sed -nE 's/^dnf5 versionlock add (.*)$/\1/p' "$1" | as_set
}

# The file globs kernel-akmods.sh installs the replacement kernel from, with
# the mount path stripped: `kernel-core-*.rpm`, `kernel-[0-9]*.rpm`, ...
installed_kernel_globs() {
    grep -oE '/tmp/kernel-rpms/[^[:space:]\\]+' "$1" |
        sed 's#^/tmp/kernel-rpms/##' | sort -u
}

# The kernel packages check_kernel_tree requires: its kernel_packages array.
required_kernel_packages() {
    sed -n '/^check_kernel_tree()/,/^}/p' "$1" |
        sed -n '/kernel_packages=(/,/)/p' |
        sed -nE 's/^[[:space:]]+(kernel[a-z-]*)$/\1/p' | as_set
}

# The ZFS families kernel-akmods.sh erases when the base image carries them:
# the quoted `rpm -qa` patterns feeding EXISTING_ZFS_PACKAGES, trailing `*`
# dropped.
erased_zfs_families() {
    sed -n '/^mapfile -t EXISTING_ZFS_PACKAGES/,/^)/p' "$1" |
        sed -nE "s/^[[:space:]]+'([^']+)'.*/\1/p" | sed 's/\*$//' | as_set
}

# The ZFS families zfs.sh installs: each ZFS_RPMS entry under the akmods-zfs
# mount, with the path, the kernel interpolation and the version glob stripped.
# `pv` is not an OpenZFS package and is not under that mount. The `${KERNEL}`
# in single quotes is the literal text zfs.sh writes.
# shellcheck disable=SC2016
installed_zfs_families() {
    sed -n '/^ZFS_RPMS=(/,/^)/p' "$1" |
        sed -nE 's#^[[:space:]]*/tmp/rpms/kmods/zfs/##p' |
        sed -e 's#-"\${KERNEL}".*##' -e 's#\[0-9\]-\*\.rpm$##' -e 's#-\*\.rpm$##' |
        as_set
}

# The ZFS families check_zfs_packages requires to exist: the first argument of
# each require_rpm and require_rpm_glob.
required_zfs_families() {
    sed -n '/^check_zfs_packages()/,/^}/p' "$1" |
        sed -nE 's/^[[:space:]]*require_rpm(_glob)? "([^"]+)".*/\2/p' | as_set
}

# The ZFS families check_zfs_packages puts in its one-release comparison: the
# names it prints and the `[0-9]*` patterns it hands `rpm -qa`.
compared_zfs_families() {
    local body
    body="$(sed -n '/^check_zfs_packages()/,/^}/p' "$1")"
    {
        sed -nE "s/^[[:space:]]*printf '%s\\\\n' (.*)$/\1/p" <<<"${body}" | tr ' ' '\n'
        sed -nE "s/^[[:space:]]*rpm -qa (.*)$/\1/p" <<<"${body}" |
            grep -oE "'[^']+'" | tr -d "'" | sed 's/\[0-9\]\*$//'
    } | as_set
}

cat >"${FIXTURES}/kernel-akmods.sh" <<'FIXTURE'
for pkg in kernel kernel-core kernel-devel; do
    true
done
for pkg in kmod-xone v4l2loopback; do
    true
done
mapfile -t EXISTING_ZFS_PACKAGES < <(
    rpm -qa \
        'kmod-zfs' \
        'libzfs*' \
        | sort -u
)
dnf5 -y install \
    /tmp/kernel-rpms/kernel-[0-9]*.rpm \
    /tmp/kernel-rpms/kernel-core-*.rpm
dnf5 versionlock add kernel kernel-core
FIXTURE

cat >"${FIXTURES}/zfs.sh" <<'FIXTURE'
ZFS_RPMS=(
    /tmp/rpms/kmods/zfs/kmod-zfs-"${KERNEL}"*.rpm
    /tmp/rpms/kmods/zfs/libzfs[0-9]-*.rpm
    /tmp/rpms/kmods/zfs/zfs-*.rpm
    pv
)
FIXTURE

cat >"${FIXTURES}/post-check.sh" <<'FIXTURE'
check_kernel_tree() {
    local kernel_packages=(
        kernel
        kernel-core
    )
}

check_zfs_packages() {
    require_rpm "zfs"
    require_rpm_glob "libzfs" "libzfs*"
    mapfile -t zfs_versioned_packages < <(
        {
            printf '%s\n' kmod-zfs zfs
            rpm -qa 'libzfs[0-9]*' 'libzpool[0-9]*'
        } | sort -u
    )
}
FIXTURE

assert_eq "the kernel erase extractor reads the kernel loop and not the kmod one" \
    "kernel kernel-core kernel-devel" \
    "$(erased_kernel_packages "${FIXTURES}/kernel-akmods.sh" | paste -sd' ' -)"
assert_eq "the versionlock extractor reads the locked names" \
    "kernel kernel-core" \
    "$(locked_kernel_packages "${FIXTURES}/kernel-akmods.sh" | paste -sd' ' -)"
assert_eq "the kernel install extractor reads the file globs" \
    "kernel-[0-9]*.rpm kernel-core-*.rpm" \
    "$(installed_kernel_globs "${FIXTURES}/kernel-akmods.sh" | paste -sd' ' -)"
assert_eq "the check_kernel_tree extractor reads kernel_packages" \
    "kernel kernel-core" \
    "$(required_kernel_packages "${FIXTURES}/post-check.sh" | paste -sd' ' -)"
assert_eq "the ZFS erase extractor reads the rpm -qa patterns" \
    "kmod-zfs libzfs" \
    "$(erased_zfs_families "${FIXTURES}/kernel-akmods.sh" | paste -sd' ' -)"
assert_eq "the ZFS install extractor strips paths, globs and pv" \
    "kmod-zfs libzfs zfs" \
    "$(installed_zfs_families "${FIXTURES}/zfs.sh" | paste -sd' ' -)"
assert_eq "the check_zfs_packages existence extractor reads both require forms" \
    "libzfs zfs" \
    "$(required_zfs_families "${FIXTURES}/post-check.sh" | paste -sd' ' -)"
assert_eq "the check_zfs_packages comparison extractor reads names and patterns" \
    "kmod-zfs libzfs libzpool zfs" \
    "$(compared_zfs_families "${FIXTURES}/post-check.sh" | paste -sd' ' -)"

# Compare one extracted list with post-check.sh's, naming what differs.
assert_same_set() {
    local description=$1 expected=$2 actual=$3
    if [[ -z "${actual}" ]]; then
        _fail "${description}" "extracted nothing; the script's shape has changed"
    elif [[ "${expected}" == "${actual}" ]]; then
        _pass "${description}"
    else
        _fail "${description}" \
            "only in post-check.sh: $(comm -23 <(printf '%s\n' "${expected}") <(printf '%s\n' "${actual}") | paste -sd' ' -)" \
            "only in the build:     $(comm -13 <(printf '%s\n' "${expected}") <(printf '%s\n' "${actual}") | paste -sd' ' -)"
    fi
}

required_kernel="$(required_kernel_packages "${SCRIPT}")"
if [[ -z "${required_kernel}" ]]; then
    _fail "check_kernel_tree still lists its kernel packages" \
        "no kernel_packages array read from ${SCRIPT}"
else
    _pass "check_kernel_tree still lists its kernel packages"
fi

assert_same_set "kernel-akmods.sh erases exactly the kernel packages check_kernel_tree requires" \
    "${required_kernel}" "$(erased_kernel_packages "${KERNEL_AKMODS_SH}")"
assert_same_set "and versionlocks exactly those packages" \
    "${required_kernel}" "$(locked_kernel_packages "${KERNEL_AKMODS_SH}")"

# The install is by file glob, so match each required package's RPM file name
# against the globs: every package has a glob that installs it, and every glob
# installs a package the gate requires. The version is a stand-in; what matters
# is where the name ends and the version begins.
kernel_globs="$(installed_kernel_globs "${KERNEL_AKMODS_SH}")"
if [[ -z "${kernel_globs}" ]]; then
    _fail "kernel-akmods.sh still installs the kernel from /tmp/kernel-rpms globs" \
        "no /tmp/kernel-rpms/ glob read from ${KERNEL_AKMODS_SH}"
else
    _pass "kernel-akmods.sh still installs the kernel from /tmp/kernel-rpms globs"
fi

unmatched_packages=()
while IFS= read -r pkg; do
    [[ -z "${pkg}" ]] && continue
    found=0
    while IFS= read -r glob; do
        # shellcheck disable=SC2053 # the glob is meant to match
        [[ "${pkg}-6.17.4-200.fc44.x86_64.rpm" == ${glob} ]] && found=1
    done <<<"${kernel_globs}"
    [[ "${found}" -eq 1 ]] || unmatched_packages+=("${pkg}")
done <<<"${required_kernel}"
assert_eq "every kernel package check_kernel_tree requires is installed by a kernel-akmods.sh glob" \
    "" "${unmatched_packages[*]:-}"

unused_globs=()
while IFS= read -r glob; do
    [[ -z "${glob}" ]] && continue
    found=0
    while IFS= read -r pkg; do
        # shellcheck disable=SC2053 # the glob is meant to match
        [[ "${pkg}-6.17.4-200.fc44.x86_64.rpm" == ${glob} ]] && found=1
    done <<<"${required_kernel}"
    [[ "${found}" -eq 1 ]] || unused_globs+=("${glob}")
done <<<"${kernel_globs}"
assert_eq "and every kernel-akmods.sh glob installs a package check_kernel_tree requires" \
    "" "${unused_globs[*]:-}"

required_zfs="$(required_zfs_families "${SCRIPT}")"
if [[ -z "${required_zfs}" ]]; then
    _fail "check_zfs_packages still lists its ZFS packages" \
        "no require_rpm or require_rpm_glob read from ${SCRIPT}"
else
    _pass "check_zfs_packages still lists its ZFS packages"
fi

assert_same_set "zfs.sh installs exactly the ZFS families check_zfs_packages requires" \
    "${required_zfs}" "$(installed_zfs_families "${ZFS_SH}")"
assert_same_set "kernel-akmods.sh erases exactly those families when the base image has them" \
    "${required_zfs}" "$(erased_zfs_families "${KERNEL_AKMODS_SH}")"
assert_same_set "check_zfs_packages compares the release of exactly the families it requires" \
    "${required_zfs}" "$(compared_zfs_families "${SCRIPT}")"

finish
