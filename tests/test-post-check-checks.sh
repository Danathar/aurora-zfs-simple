#!/usr/bin/env bash
#
# Tests for the two check_* stages of build_files/post-check.sh that decide
# purely from what rpm(1) and find(1) report: check_kernel_tree and
# check_zfs_packages.
#
# tests/test-post-check.sh drives the small require_*/verify_* helpers one call
# at a time with a stub that ignores its arguments. The stages above them are a
# different thing to test: their value is in the *wiring* -- which package names
# are demanded, which glob feeds the version comparison, and that a stage's
# verdict survives being assembled from several rpm calls. A stub that answers
# every query identically cannot show any of that, so this file backs rpm with a
# small text database instead and lets the real queries run against it.
#
# The remaining five stages are not reachable from here. check_zfs_modules,
# check_zfs_userspace and check_initramfs read absolute paths under /usr/lib and
# require zfs/zpool/zdb/zed on PATH, so on any host that is not the finished
# image they fail before reaching the logic worth checking; check_rpm_payloads
# is one call to verify_rpm_payload, already covered, and
# check_module_signatures reads /etc/pki/akmods/certs/akmods-ublue.der, which
# only the built image has -- its comparison lives in require_module_signed,
# covered in tests/test-post-check.sh.

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
STATUS=0
OUTPUT=""

# Fresh sandbox per case: its own stub bin directory and its own rpm database.
new_case() {
    case_dir="${WORK_ROOT}/$1"
    mkdir -p "${case_dir}/bin"
    : >"${case_dir}/rpmdb"
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
run_check() {
    OUTPUT="$(
        PATH="${case_dir}/bin:${PATH}" bash -c '
            source "$1"
            shift
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

finish
