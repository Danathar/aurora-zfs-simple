#!/usr/bin/env bash
#
# Tests for the pure helpers in build_files/post-check.sh.
#
# post-check.sh runs inside the image build against a real RPM database, module
# tree and initramfs, so its check_* functions are not reachable from a test on
# the host. Its helpers are: they take strings, shell out to one tool, and
# decide. Now that the file guards its entry point, sourcing it defines those
# helpers without running a single check, so each one can be called directly
# with a stub standing in for rpm, ldd or find.
#
# Each case sources the script in a fresh bash and calls one helper, because
# `fail` exits rather than returning -- a helper's verdict *is* the exit status
# of the process, and that is what these assertions read.
#
# The property most worth pinning down is verify_rpm_payload's nine-character
# flag window. rpm -V output puts the verification flags in columns 1-9 and the
# path after them, so a payload-change letter is only meaningful in that window
# -- an S, D, 5, L or P in a *filename* must not fail the build.
#
# The second property is which of those nine columns get a say. rpm writes '.'
# for a test that passed and '?' for one it could not perform, and this is a
# fail-closed gate in front of signing, so '?' must fail wherever a letter
# would. That holds for the six payload columns (S M 5 D L P) and not for the
# three the check deliberately ignores (U G T), which image assembly
# normalizes. Both directions are asserted below.

set -uo pipefail

TEST_NAME="test-post-check"
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

# Fresh sandbox per case: its own stub bin directory and canned responses, so
# no case can observe another's leftovers.
new_case() {
    case_dir="${WORK_ROOT}/$1"
    mkdir -p "${case_dir}/bin"
}

# Install a stub for a command that prints whatever `canned` registered and
# exits with whatever `exits` registered (0 by default), ignoring its
# arguments. Each case drives one helper, which makes one kind of call, so
# argument dispatch would only add a way for the stub to be wrong.
stub_command() {
    local name=$1
    : >"${case_dir}/${name}.out"
    printf '0\n' >"${case_dir}/${name}.status"
    cat >"${case_dir}/bin/${name}" <<'STUB'
#!/usr/bin/env bash
dir="$(dirname "$0")/.."
name="$(basename "$0")"
cat "${dir}/${name}.out"
exit "$(cat "${dir}/${name}.status")"
STUB
    chmod +x "${case_dir}/bin/${name}"
}

canned() { cat >"${case_dir}/$1.out"; }
exits() { printf '%s\n' "$2" >"${case_dir}/$1.status"; }

# Source post-check.sh and call one helper. $0 is deliberately not the script's
# path, which is exactly the condition the entry-point guard tests for.
run_helper() {
    OUTPUT="$(
        PATH="${case_dir}/bin:${PATH}" bash -c '
            source "$1"
            shift
            "$@"
        ' test-post-check "${SCRIPT}" "$@" 2>&1
    )"
    STATUS=$?
}

# Source post-check.sh and evaluate a snippet against what it defined. Same
# condition as run_helper -- $0 is not the script's path, so sourcing defines
# main and the check_* stages without running them -- but the snippet gets to
# redefine a stage before calling into it, which is how the order of main's
# calls can be read without a real RPM database underneath.
run_snippet() {
    OUTPUT="$(
        PATH="${case_dir}/bin:${PATH}" bash -c '
            source "$1"
            eval "$2"
        ' test-post-check "${SCRIPT}" "$1" 2>&1
    )"
    STATUS=$?
}

# ---------------------------------------------------------------------------
# The entry-point guard, in both directions
# ---------------------------------------------------------------------------

new_case guard-sourcing-runs-no-checks
run_helper log "sourced ok"
assert_eq "sourcing post-check.sh succeeds" 0 "${STATUS}"
assert_eq "sourcing defines the helpers and runs no check" \
    "post-check: sourced ok" "${OUTPUT}"

new_case guard-executing-still-runs-main
# Two kernel module directories make check_kernel_tree, the first thing main
# does, fail immediately -- so this proves main ran without letting any later
# check touch the host (check_zfs_modules would run `depmod -a`).
stub_command find
canned find <<'EOF'
/usr/lib/modules/6.1.0-1.fc44.x86_64
/usr/lib/modules/6.2.0-1.fc44.x86_64
EOF
OUTPUT="$(PATH="${case_dir}/bin:${PATH}" bash "${SCRIPT}" 2>&1)"
STATUS=$?
assert_eq "executing the script still runs main" 1 "${STATUS}"
assert_contains "main starts at the kernel tree check" \
    "${OUTPUT}" "post-check: checking kernel module tree"
assert_contains "and stops on the first failure" \
    "${OUTPUT}" "expected exactly one kernel module directory, found 2"

# ---------------------------------------------------------------------------
# main: which stages run, in what order, and when the success line is printed
# ---------------------------------------------------------------------------
#
# The case above proves main starts at check_kernel_tree and stops on the first
# failure. It cannot say anything about the five stages behind it, because the
# run it observes never reaches them -- and neither can a real image build,
# which only reports that main exited 0.
#
# The order is a contract, not an arrangement. verify_rpm_payload's comment
# argues that its unparseable-line branch "is currently unreachable --
# check_zfs_packages runs require_rpm kmod-zfs earlier in main() and exits if
# it is absent". That reasoning holds only while check_zfs_packages runs before
# check_rpm_payloads. Move check_rpm_payloads up, or drop a stage, and nothing
# in the tree notices: the build still passes, and the comment quietly becomes
# false. check_zfs_modules must also precede check_zfs_userspace and
# check_initramfs for a different reason -- it is what sets KERNEL's module
# tree up via depmod, and both later stages read paths under that kernel.
# check_module_signatures depends on that same depmod: it asks modinfo for each
# module's signer, so it has to run after the module tree is registered and
# before anything downstream treats the image as publishable.
#
# Each stage is replaced by a recorder, so this reads main's call sequence
# without needing the RPM database, module tree or initramfs any of them wants.

STAGE_RECORDERS='
check_kernel_tree()       { printf "ran %s\n" check_kernel_tree; }
check_zfs_packages()      { printf "ran %s\n" check_zfs_packages; }
check_zfs_modules()       { printf "ran %s\n" check_zfs_modules; }
check_module_signatures() { printf "ran %s\n" check_module_signatures; }
check_zfs_userspace()     { printf "ran %s\n" check_zfs_userspace; }
check_initramfs()         { printf "ran %s\n" check_initramfs; }
check_rpm_payloads()      { printf "ran %s\n" check_rpm_payloads; }
'

new_case main-runs-every-stage-in-order
run_snippet "${STAGE_RECORDERS}"'
main
'
assert_eq "main succeeds when every stage does" 0 "${STATUS}"
assert_eq "main runs all seven stages, in order, and reports success last" \
    "ran check_kernel_tree
ran check_zfs_packages
ran check_zfs_modules
ran check_module_signatures
ran check_zfs_userspace
ran check_initramfs
ran check_rpm_payloads
post-check: all checks passed" \
    "${OUTPUT}"

new_case main-stops-at-a-failing-middle-stage
# The existing guard case fails at the first stage, where "nothing after it
# ran" is indistinguishable from "nothing after it was ever called". Failing in
# the middle separates the two: the stages before it must have run, the ones
# after it must not, and the success line must not be printed.
run_snippet "${STAGE_RECORDERS}"'
check_zfs_userspace() { fail "stage under test"; }
main
'
assert_eq "a failing stage fails the run" 1 "${STATUS}"
assert_contains "the stages before it still ran" \
    "${OUTPUT}" "ran check_zfs_modules"
assert_not_contains "the stages after it did not" \
    "${OUTPUT}" "ran check_initramfs"
assert_not_contains "and no payload check ran either" \
    "${OUTPUT}" "ran check_rpm_payloads"
assert_not_contains "a failed run does not report all checks passed" \
    "${OUTPUT}" "all checks passed"

new_case rpm-payloads-verifies-the-zfs-kmod
# check_rpm_payloads is one call, and which package it names is the whole of
# it: post-check.sh is the gate in front of signing, and kmod-zfs is the RPM
# whose payload nothing downstream re-checks. Verifying some other package
# here, or none, would still exit 0.
run_snippet '
verify_rpm_payload() { printf "verified %s\n" "$*"; }
check_rpm_payloads
'
assert_eq "check_rpm_payloads succeeds when the payload verifies" 0 "${STATUS}"
assert_contains "it verifies the kmod-zfs payload" "${OUTPUT}" "verified kmod-zfs"
assert_eq "and verifies that one package only" \
    "post-check: checking RPM file verification for critical kmods
verified kmod-zfs" \
    "${OUTPUT}"

# ---------------------------------------------------------------------------
# require_glob: the compressed-module case it exists for
# ---------------------------------------------------------------------------

new_case require-glob-uncompressed
mkdir -p "${case_dir}/extra"
: >"${case_dir}/extra/zfs.ko"
run_helper require_glob "zfs kernel module" "${case_dir}/extra/zfs.ko*"
assert_eq "an uncompressed .ko satisfies the glob" 0 "${STATUS}"

new_case require-glob-xz
mkdir -p "${case_dir}/extra"
: >"${case_dir}/extra/zfs.ko.xz"
run_helper require_glob "zfs kernel module" "${case_dir}/extra/zfs.ko*"
assert_eq "an xz-compressed module satisfies the same glob" 0 "${STATUS}"

new_case require-glob-zst
mkdir -p "${case_dir}/extra"
: >"${case_dir}/extra/zfs.ko.zst"
run_helper require_glob "zfs kernel module" "${case_dir}/extra/zfs.ko*"
assert_eq "a zstd-compressed module satisfies the same glob" 0 "${STATUS}"

new_case require-glob-missing
mkdir -p "${case_dir}/extra"
: >"${case_dir}/extra/zfs.ko"
run_helper require_glob "spl kernel module" "${case_dir}/extra/spl.ko*"
assert_eq "no match is a hard failure" 1 "${STATUS}"
assert_contains "the failure names the description and the pattern" \
    "${OUTPUT}" "required spl kernel module not found matching: ${case_dir}/extra/spl.ko*"

new_case require-glob-directory-is-not-a-match
# compgen -G matches directories too; the patterns in use end in .ko* so this
# only documents the behaviour rather than asserting a guard that is not there.
mkdir -p "${case_dir}/extra/zfs.ko.d"
run_helper require_glob "zfs kernel module" "${case_dir}/extra/zfs.ko*"
assert_eq "a matching directory counts as a match" 0 "${STATUS}"

# ---------------------------------------------------------------------------
# verify_rpm_payload: rpm -V flag parsing
# ---------------------------------------------------------------------------

new_case payload-clean
stub_command rpm
canned rpm </dev/null
run_helper verify_rpm_payload kmod-zfs
assert_eq "no rpm -V output is a clean payload" 0 "${STATUS}"

new_case payload-metadata-only
stub_command rpm
exits rpm 1 # rpm -V exits non-zero whenever it reports anything
canned rpm <<'EOF'
.....UGT.    /usr/lib/modules/6.1.0-1.fc44.x86_64/extra/zfs/zfs.ko.xz
.....UG..    /usr/lib/modules/6.1.0-1.fc44.x86_64/extra/zfs/spl.ko.xz
EOF
run_helper verify_rpm_payload kmod-zfs
assert_eq "user/group/time drift alone is accepted in a bootc image" 0 "${STATUS}"

new_case payload-letters-in-the-filename-only
# The whole point of reading only columns 1-9: this path contains S, D, 5, L
# and P, and the flag window is all dots. Comparing against the whole line
# would fail a perfectly good image.
stub_command rpm
exits rpm 1
canned rpm <<'EOF'
.........    /usr/lib/modules/6.1.0-1.fc44.x86_64/extra/zfs/SPL-D5-LP.ko.xz
EOF
run_helper verify_rpm_payload kmod-zfs
assert_eq "flag letters appearing in the path do not fail the check" 0 "${STATUS}"

new_case payload-digest-changed
stub_command rpm
exits rpm 1
canned rpm <<'EOF'
.....UGT.    /usr/lib/modules/6.1.0-1.fc44.x86_64/extra/zfs/spl.ko.xz
..5....T.    /usr/lib/modules/6.1.0-1.fc44.x86_64/extra/zfs/zfs.ko.xz
EOF
run_helper verify_rpm_payload kmod-zfs
assert_eq "a changed digest fails even when other lines are benign" 1 "${STATUS}"
assert_contains "the failure says the payload changed" \
    "${OUTPUT}" "RPM verification found payload changes for kmod-zfs"
assert_contains "and prints the full rpm -V output for diagnosis" \
    "${OUTPUT}" "spl.ko.xz"

new_case payload-size-changed
stub_command rpm
exits rpm 1
canned rpm <<'EOF'
S.5....T.  c /etc/zfs/zed.d/zed.rc
EOF
run_helper verify_rpm_payload kmod-zfs
assert_eq "a size change fails" 1 "${STATUS}"
assert_contains "reported as a payload change" \
    "${OUTPUT}" "RPM verification found payload changes for kmod-zfs"

new_case payload-missing-file
stub_command rpm
exits rpm 1
canned rpm <<'EOF'
missing     /usr/lib/modules/6.1.0-1.fc44.x86_64/extra/zfs/zfs.ko.xz
EOF
run_helper verify_rpm_payload kmod-zfs
assert_eq "a missing file fails" 1 "${STATUS}"
assert_contains "missing files are reported separately from payload changes" \
    "${OUTPUT}" "RPM verification found missing files for kmod-zfs"

new_case payload-missing-reported-before-flags
# A missing line has no flag window at all: "missing " is only 8 characters, so
# the missing check must come first or the line would be judged on garbage.
stub_command rpm
exits rpm 1
canned rpm <<'EOF'
missing   c /etc/zfs/zed.d/zed.rc
EOF
run_helper verify_rpm_payload kmod-zfs
assert_contains "a missing line is classified as missing, not as a payload change" \
    "${OUTPUT}" "RPM verification found missing files for kmod-zfs"

new_case payload-unverifiable-digest
# rpm writes '?' in a column when the test could not be performed rather than
# when it passed. A file it could not read comes back with '?' in the size and
# digest columns; nothing else in the pipeline re-checks it, so "could not
# verify" has to fail the same as "verified different".
stub_command rpm
exits rpm 1
canned rpm <<'EOF'
?.?......    /usr/lib/modules/6.1.0-1.fc44.x86_64/extra/zfs/zfs.ko.xz
EOF
run_helper verify_rpm_payload kmod-zfs
assert_eq "an unverifiable digest fails rather than passing on doubt" 1 "${STATUS}"
assert_contains "reported as unverifiable, not as a payload change" \
    "${OUTPUT}" "RPM verification could not check the payload for kmod-zfs"
assert_contains "and prints the full rpm -V output for diagnosis" \
    "${OUTPUT}" "zfs.ko.xz"

new_case payload-unverifiable-link-target
# The other producer of '?': a symlink whose target could not be resolved,
# which lands in the L column.
stub_command rpm
exits rpm 1
canned rpm <<'EOF'
....?....    /usr/lib/modules/6.1.0-1.fc44.x86_64/extra/zfs/zfs.ko.xz
EOF
run_helper verify_rpm_payload kmod-zfs
assert_eq "an unverifiable link target fails" 1 "${STATUS}"
assert_contains "also reported as unverifiable" \
    "${OUTPUT}" "RPM verification could not check the payload for kmod-zfs"

new_case payload-unverifiable-everything
stub_command rpm
exits rpm 1
canned rpm <<'EOF'
?????????    /usr/lib/modules/6.1.0-1.fc44.x86_64/extra/zfs/zfs.ko.xz
EOF
run_helper verify_rpm_payload kmod-zfs
assert_eq "a wholly unverifiable file fails" 1 "${STATUS}"

new_case payload-unverifiable-metadata-only
# The tolerance boundary, in the other direction. User, group and time are
# ignored here because image assembly normalizes them, so a '?' in one of those
# three columns says nothing about the payload and must not fail the build --
# exactly as a U, G or T in the same column does not.
stub_command rpm
exits rpm 1
canned rpm <<'EOF'
.....???.    /usr/lib/modules/6.1.0-1.fc44.x86_64/extra/zfs/zfs.ko.xz
EOF
run_helper verify_rpm_payload kmod-zfs
assert_eq "an unverifiable user/group/time is ignored like a differing one" 0 "${STATUS}"

new_case payload-question-mark-in-the-filename-only
# The filename companion to the letters-in-the-path case: a '?' outside the
# nine-column window is part of a path, not a verdict.
stub_command rpm
exits rpm 1
canned rpm <<'EOF'
.........    /usr/lib/modules/6.1.0-1.fc44.x86_64/extra/zfs/what?.ko.xz
EOF
run_helper verify_rpm_payload kmod-zfs
assert_eq "a '?' appearing in the path does not fail the check" 0 "${STATUS}"

new_case payload-unparsed-line
# rpm -V writes to stderr as well, and the caller merges it. "package X is not
# installed" read as nine flag columns contains no failure letter, so before
# this check it passed -- a fail-closed gate returning clean for a package that
# is not there.
stub_command rpm
exits rpm 1
canned rpm <<'EOF'
package kmod-zfs is not installed
EOF
run_helper verify_rpm_payload kmod-zfs
assert_eq "output that is not a verification line fails" 1 "${STATUS}"
assert_contains "and says it could not be parsed" \
    "${OUTPUT}" "unrecognised rpm -V output for kmod-zfs"

new_case payload-short-flag-window
# A line with fewer than nine flag columns is not a verification line either.
stub_command rpm
exits rpm 1
canned rpm <<'EOF'
..5  /usr/lib/modules/6.1.0-1.fc44.x86_64/extra/zfs/zfs.ko.xz
EOF
run_helper verify_rpm_payload kmod-zfs
assert_eq "a short flag window fails rather than being read as flags" 1 "${STATUS}"

new_case payload-attribute-marker-still-parses
# The real format: nine columns, then the attribute marker column rpm uses for
# config, doc and ghost files. This must keep parsing as an ordinary line.
stub_command rpm
exits rpm 1
canned rpm <<'EOF'
.....UGT.  c /etc/zfs/zed.d/zed.rc
.......T.  d /usr/share/doc/zfs/README
EOF
run_helper verify_rpm_payload kmod-zfs
assert_eq "marked config and doc files still read as clean" 0 "${STATUS}"

# ---------------------------------------------------------------------------
# require_single_rpm_version: the split-stack failure it exists to catch
# ---------------------------------------------------------------------------

new_case single-version-agreeing
stub_command rpm
canned rpm <<'EOF'
2.3.4-1.fc44
2.3.4-1.fc44
2.3.4-1.fc44
EOF
run_helper require_single_rpm_version "ZFS" kmod-zfs zfs python3-pyzfs
assert_eq "one VERSION-RELEASE across the stack passes" 0 "${STATUS}"

new_case single-version-split-stack
stub_command rpm
canned rpm <<'EOF'
2.3.4-1.fc44
2.3.3-1.fc44
EOF
run_helper require_single_rpm_version "ZFS" kmod-zfs zfs
assert_eq "kmod-zfs from one release and zfs from another fails" 1 "${STATUS}"
assert_contains "the failure names the group" \
    "${OUTPUT}" "expected exactly one ZFS version"
assert_contains "and prints the older version it found" "${OUTPUT}" "2.3.3-1.fc44"
assert_contains "and the newer one" "${OUTPUT}" "2.3.4-1.fc44"

new_case single-version-nothing-installed
# rpm printing nothing must not read as "one version, therefore fine".
stub_command rpm
canned rpm </dev/null
run_helper require_single_rpm_version "ZFS" kmod-zfs
assert_eq "no versions at all is a failure, not a pass" 1 "${STATUS}"

# ---------------------------------------------------------------------------
# The remaining require_* helpers
# ---------------------------------------------------------------------------

new_case require-rpm
stub_command rpm
run_helper require_rpm zfs
assert_eq "an installed package passes" 0 "${STATUS}"

new_case require-rpm-absent
stub_command rpm
exits rpm 1
run_helper require_rpm zfs
assert_eq "an absent package fails" 1 "${STATUS}"
assert_contains "the failure names the package" \
    "${OUTPUT}" "required RPM is not installed: zfs"

new_case require-rpm-glob
stub_command rpm
canned rpm <<'EOF'
libzfs6-2.3.4-1.fc44.x86_64
EOF
run_helper require_rpm_glob "libzfs" "libzfs*"
assert_eq "an ABI-numbered package matches the name glob" 0 "${STATUS}"

new_case require-rpm-glob-empty
stub_command rpm
canned rpm </dev/null
run_helper require_rpm_glob "libzfs" "libzfs*"
assert_eq "no match fails" 1 "${STATUS}"
assert_contains "the failure names the description and the glob" \
    "${OUTPUT}" "required RPM not installed for libzfs: libzfs*"

new_case require-command-missing
run_helper require_command definitely-not-a-real-command
assert_eq "a missing command fails" 1 "${STATUS}"
assert_contains "the failure names the command" \
    "${OUTPUT}" "required command not found: definitely-not-a-real-command"

new_case require-file
: >"${case_dir}/present"
run_helper require_file "${case_dir}/present"
assert_eq "an existing path passes" 0 "${STATUS}"
run_helper require_file "${case_dir}/absent"
assert_eq "a missing path fails" 1 "${STATUS}"
assert_contains "the failure names the path" \
    "${OUTPUT}" "required file not found: ${case_dir}/absent"

new_case require-ldd-resolved
: >"${case_dir}/zpool"
stub_command ldd
canned ldd <<'EOF'
	libzfs.so.6 => /usr/lib64/libzfs.so.6 (0x00007f0000000000)
	libc.so.6 => /usr/lib64/libc.so.6 (0x00007f0000100000)
EOF
run_helper require_ldd_resolved "${case_dir}/zpool"
assert_eq "a fully resolved binary passes" 0 "${STATUS}"

new_case require-ldd-unresolved
: >"${case_dir}/zpool"
stub_command ldd
canned ldd <<'EOF'
	libzfs.so.6 => not found
	libc.so.6 => /usr/lib64/libc.so.6 (0x00007f0000100000)
EOF
run_helper require_ldd_resolved "${case_dir}/zpool"
assert_eq "a missing shared library fails" 1 "${STATUS}"
assert_contains "the failure names the binary" \
    "${OUTPUT}" "unresolved shared library dependency for ${case_dir}/zpool"
assert_contains "and prints the ldd output" "${OUTPUT}" "libzfs.so.6 => not found"

new_case require-ldd-missing-binary
stub_command ldd
run_helper require_ldd_resolved "${case_dir}/absent"
assert_eq "a binary that is not there fails before ldd runs" 1 "${STATUS}"
assert_contains "reported as a missing file, not as a link error" \
    "${OUTPUT}" "required file not found: ${case_dir}/absent"

# ---------------------------------------------------------------------------
# require_module_signed: the certificate-to-module binding
# ---------------------------------------------------------------------------
#
# The image installs /etc/pki/akmods/certs/akmods-ublue.der for a user to
# enroll into MOK, and kmod-zfs comes from a different upstream image than the
# RPM that certificate is extracted from. So "the module is signed by the key
# whose certificate we shipped" is a claim, and this helper is what turns it
# into a checked one. Both failure directions matter: an unsigned module (which
# a Secure Boot host cannot load at all) and a module signed by some other key
# (which means the enrolled certificate authorizes something else).

new_case module-signed-by-the-shipped-key
stub_command modinfo
canned modinfo <<'EOF'
Universal Blue akmods
EOF
run_helper require_module_signed 6.1.0-1.fc44.x86_64 zfs "Universal Blue akmods"
assert_eq "a module signed by the shipped certificate passes" 0 "${STATUS}"

new_case module-signer-padded
# modinfo pads its field output when it is not asked for a single field, and a
# trailing newline is always there. Neither is a mismatch.
stub_command modinfo
canned modinfo <<'EOF'
   Universal Blue akmods
EOF
run_helper require_module_signed 6.1.0-1.fc44.x86_64 zfs "Universal Blue akmods"
assert_eq "surrounding whitespace is not a mismatch" 0 "${STATUS}"

new_case module-unsigned
# `modinfo -F signer` prints nothing for a module with no signature.
stub_command modinfo
canned modinfo </dev/null
run_helper require_module_signed 6.1.0-1.fc44.x86_64 zfs "Universal Blue akmods"
assert_eq "an unsigned module fails" 1 "${STATUS}"
assert_contains "the failure says the module is unsigned" \
    "${OUTPUT}" "zfs carries no module signature"
assert_contains "and names the certificate the image ships" \
    "${OUTPUT}" "Universal Blue akmods"

new_case module-signed-by-another-key
stub_command modinfo
canned modinfo <<'EOF'
Some Other Vendor Key
EOF
run_helper require_module_signed 6.1.0-1.fc44.x86_64 spl "Universal Blue akmods"
assert_eq "a module signed by a different key fails" 1 "${STATUS}"
assert_contains "the failure names both signers" \
    "${OUTPUT}" "spl is signed by 'Some Other Vendor Key', not by the certificate this image installs ('Universal Blue akmods')"

new_case module-signer-unreadable
# modinfo failing outright is the same outcome as an unsigned module: nothing
# was proven, so the gate fails rather than passing on doubt.
stub_command modinfo
exits modinfo 1
canned modinfo </dev/null
run_helper require_module_signed 6.1.0-1.fc44.x86_64 zfs "Universal Blue akmods"
assert_eq "a modinfo that cannot answer fails" 1 "${STATUS}"
assert_contains "reported as no signature rather than passing" \
    "${OUTPUT}" "zfs carries no module signature"

finish
