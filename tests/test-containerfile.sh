#!/usr/bin/env bash
#
# Tests for the Containerfile's build-stage wiring.
#
# The Containerfile is the only place that says how the four build_files
# scripts are invoked and what filesystem they are handed. Each one reads
# absolute paths -- /tmp/kernel-rpms, /tmp/rpms/common, /tmp/rpms/kmods,
# /tmp/rpms/kmods/zfs -- that exist for exactly as long as the `--mount` lines
# on the enclosing `RUN` say they do. Nothing in the scripts declares that
# requirement and nothing in the Containerfile names the scripts' paths, so the
# two halves are joined only by hand.
#
# That join is what this file asserts. Both sides look fine on their own when
# it breaks:
#
#   * drop `dst=/tmp/rpms/kmods/zfs` and zfs.sh's glob matches nothing, so
#     `dnf5 install` is handed a literal `*.rpm` path;
#   * move the zfs mount above the `/tmp/rpms/kmods` mount it nests inside and
#     the parent shadows it;
#   * rename a script, or add a fifth one, and the Containerfile still builds
#     until the missing step's absence shows up as a missing module;
#   * split `kernel-akmods.sh && zfs.sh` into two `RUN`s and zfs.sh looks for a
#     kernel tree under a mount the second RUN no longer has.
#
# None of that fails until a real image build runs, which is the one thing this
# suite cannot do -- tests/test-coverage.sh records those three scripts as
# UNCOVERED for that reason. Their *contract with the Containerfile* is
# checkable here, cheaply, which is a different claim from covering their code.
#
# The requirement is extracted from the scripts rather than typed in, so a new
# mount-backed path in a script is checked the moment it is written. An
# extractor that silently returns nothing would make every case vacuous, so it
# is run against a fixture with known answers first, and each script's real
# extraction is asserted to be non-empty.

set -uo pipefail

TEST_NAME="test-containerfile"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

CONTAINERFILE="${REPO_ROOT}/Containerfile"

assert_file_exists "the Containerfile exists" "${CONTAINERFILE}"
if [[ ! -f "${CONTAINERFILE}" ]]; then
    finish
    exit
fi

# --- parsing ----------------------------------------------------------------

# Fold `\`-continued lines into one instruction each and drop whole-line
# comments, which is what a builder does before it reads an instruction.
normalize() {
    awk '
        /^[[:space:]]*#/ { next }
        {
            line = $0
            sub(/[[:space:]]+$/, "", line)
            if (line ~ /\\$/) {
                sub(/\\$/, "", line)
                buf = buf line " "
                next
            }
            if (buf != "" || line != "") { print buf line }
            buf = ""
        }
        END { if (buf != "") print buf }
    ' "$1"
}

INSTRUCTIONS=()
while IFS= read -r line; do
    [[ -z "${line// /}" ]] && continue
    INSTRUCTIONS+=("${line}")
done < <(normalize "${CONTAINERFILE}")

if [[ "${#INSTRUCTIONS[@]}" -eq 0 ]]; then
    _fail "the Containerfile has instructions" "normalize produced nothing"
    finish
    exit
fi

# Stage names declared by `FROM ... AS <name>`, and the stage each instruction
# belongs to.
STAGES=()
RUN_BODIES=()     # every RUN instruction, in file order
declare -A CTX_COPIES=()

current_stage=""
for instruction in "${INSTRUCTIONS[@]}"; do
    read -ra words <<<"${instruction}"
    case "${words[0]}" in
    FROM)
        current_stage=""
        for ((i = 1; i < ${#words[@]} - 1; i++)); do
            if [[ "${words[i]^^}" == "AS" ]]; then
                current_stage="${words[i + 1]}"
                STAGES+=("${current_stage}")
            fi
        done
        ;;
    COPY)
        if [[ "${current_stage}" == "ctx" ]]; then
            CTX_COPIES["${words[-2]} ${words[-1]}"]=1
        fi
        ;;
    RUN)
        RUN_BODIES+=("${instruction}")
        ;;
    *) ;; # every other instruction is irrelevant to the script wiring
    esac
done

stage_declared() {
    local wanted=$1 stage
    for stage in "${STAGES[@]}"; do
        [[ "${stage}" == "${wanted}" ]] && return 0
    done
    return 1
}

# The mounts of one RUN, one per line, in declaration order:
#   <kind> <TAB> <destination> <TAB> <from-stage or ->
run_mounts() {
    local body=$1 token spec field key value kind dst from
    read -ra tokens <<<"${body}"
    for token in "${tokens[@]}"; do
        [[ "${token}" == --mount=* ]] || continue
        spec="${token#--mount=}"
        kind=""
        dst=""
        from="-"
        while IFS= read -r field; do
            key="${field%%=*}"
            value="${field#*=}"
            case "${key}" in
            type) kind="${value}" ;;
            dst | destination | target) dst="${value}" ;;
            from) from="${value}" ;;
            *) ;; # other mount options do not change what a script can read
            esac
        done < <(tr ',' '\n' <<<"${spec}")
        printf '%s\t%s\t%s\n' "${kind:-bind}" "${dst}" "${from}"
    done
}

# The /ctx scripts a RUN executes, in the order it executes them.
run_scripts() {
    grep -oE '/ctx/[A-Za-z0-9_.-]+\.sh' <<<"$1"
}

# --- what a build_files script needs from a mount ---------------------------

# Every absolute path under /tmp a script reads, reduced to the deepest
# directory that is spelled out rather than globbed. `${VAR}` and `*` end a
# path: what is above them is the part a mount has to provide.
required_dirs() {
    local file=$1 cand expanded=() e part dir
    while IFS= read -r cand; do
        cand="${cand//\"/}"
        cand="${cand//\'/}"
        cand="$(sed -E 's/\$\{[A-Za-z_][A-Za-z0-9_]*\}/*/g; s/\$[A-Za-z_][A-Za-z0-9_]*/*/g' <<<"${cand}")"
        # A path that survived the rewrites above still has to be plain text
        # before it is brace-expanded.
        [[ "${cand}" =~ ^[]A-Za-z0-9_./,{}*?[-]+$ ]] || continue
        set -f
        eval "expanded=( ${cand} )" 2>/dev/null || {
            set +f
            continue
        }
        set +f
        for e in "${expanded[@]}"; do
            dir=""
            local parts=()
            IFS='/' read -ra parts <<<"${e}"
            for part in "${parts[@]}"; do
                [[ -z "${part}" ]] && continue
                [[ "${part}" == *[\*\?\[]* ]] && break
                dir="${dir}/${part}"
            done
            [[ -n "${dir}" && "${dir}" != "/tmp" ]] && printf '%s\n' "${dir}"
        done
    done < <(grep -oE "/tmp/[^[:space:]\`;|&)]*" "${file}") | sort -u
}

# A mount at `dst` provides `needed` when it is that directory, when it is
# mounted below it (so the directory exists as a parent), or when `needed`
# lives under it.
mount_provides() {
    local dst=$1 needed=$2
    [[ "${dst}" == "${needed}" ]] && return 0
    [[ "${needed}" == "${dst}/"* ]] && return 0
    [[ "${dst}" == "${needed}/"* ]] && return 0
    return 1
}

# --- 0. the extractors answer correctly on known input ----------------------

fixture_dir="$(mktemp -d)"
trap 'rm -rf "${fixture_dir}"' EXIT

cat >"${fixture_dir}/fixture.sh" <<'FIXTURE'
#!/usr/bin/bash
dnf5 -y install /tmp/kernel-rpms/kernel-[0-9]*.rpm
dnf5 -y install /tmp/rpms/{common,kmods}/*xone*.rpm
cp /tmp/rpms/kmods/zfs/kmod-zfs-"${KERNEL}"*.rpm .
find /tmp/rpms -name 'ublue-os-akmods-addons-*.rpm'
work=$(mktemp -d)
echo "nothing here: /var/cache/dnf"
FIXTURE

assert_eq "the path extractor reduces globs, braces and variables to directories" \
    "/tmp/kernel-rpms /tmp/rpms /tmp/rpms/common /tmp/rpms/kmods /tmp/rpms/kmods/zfs" \
    "$(required_dirs "${fixture_dir}/fixture.sh" | tr '\n' ' ' | sed 's/ $//')"

cat >"${fixture_dir}/nopaths.sh" <<'FIXTURE'
#!/usr/bin/bash
systemctl enable podman.socket
FIXTURE

assert_eq "and returns nothing for a script that reads no /tmp path" \
    "" "$(required_dirs "${fixture_dir}/nopaths.sh")"

mount_case() {
    local dst=$1 needed=$2
    if mount_provides "${dst}" "${needed}"; then echo yes; else echo no; fi
}

assert_eq "a mount provides the directory it is mounted at" \
    "yes" "$(mount_case /tmp/rpms/kmods /tmp/rpms/kmods)"
assert_eq "a mount provides paths below it" \
    "yes" "$(mount_case /tmp/rpms /tmp/rpms/kmods)"
assert_eq "a mount below a directory makes that directory exist" \
    "yes" "$(mount_case /tmp/rpms/ublue-os /tmp/rpms)"
assert_eq "a sibling mount provides nothing" \
    "no" "$(mount_case /tmp/rpms/common /tmp/rpms/kmods)"
assert_eq "and a prefix that is not a path component provides nothing" \
    "no" "$(mount_case /tmp/rpms /tmp/rpms-extra)"

# --- 1. /ctx is build_files, and every script on both sides is accounted for -

assert_eq "the ctx stage copies build_files to the root it is mounted from" \
    "1" "${CTX_COPIES[build_files /]:-0}"

invoked=()
for body in "${RUN_BODIES[@]}"; do
    while IFS= read -r script; do
        [[ -z "${script}" ]] && continue
        invoked+=("${script#/ctx/}")
    done < <(run_scripts "${body}")
done

if [[ "${#invoked[@]}" -eq 0 ]]; then
    _fail "the Containerfile invokes the build_files scripts" \
        "no RUN instruction executes a /ctx/*.sh path"
    finish
    exit
fi

shipped_scripts="$(cd "${REPO_ROOT}" && git ls-files 'build_files/*.sh' | sed 's|^build_files/||' | sort)"

for script in "${invoked[@]}"; do
    assert_file_exists "/ctx/${script} is a tracked build_files script" \
        "${REPO_ROOT}/build_files/${script}"
done

assert_eq "every tracked build_files script is invoked by the Containerfile" \
    "${shipped_scripts}" "$(printf '%s\n' "${invoked[@]}" | sort -u)"

assert_eq "and none of them is invoked twice" \
    "$(printf '%s\n' "${invoked[@]}" | wc -l)" \
    "$(printf '%s\n' "${invoked[@]}" | sort -u | wc -l)"

# --- 2. each RUN hands its scripts the tree they read -----------------------

for index in "${!RUN_BODIES[@]}"; do
    body="${RUN_BODIES[index]}"
    scripts=()
    while IFS= read -r script; do
        [[ -n "${script}" ]] && scripts+=("${script}")
    done < <(run_scripts "${body}")
    [[ "${#scripts[@]}" -eq 0 ]] && continue

    label="RUN #$((index + 1)) (${scripts[*]})"

    bind_dsts=()
    tmpfs_dsts=()
    has_ctx_mount=0
    while IFS=$'\t' read -r kind dst from; do
        case "${kind}" in
        bind)
            bind_dsts+=("${dst}")
            [[ "${dst}" == "/ctx" ]] && has_ctx_mount=1
            if [[ "${from}" != "-" ]]; then
                if stage_declared "${from}"; then
                    _pass "${label}: mount from=${from} names a declared stage"
                else
                    _fail "${label}: mount from=${from} names a declared stage" \
                        "declared stages: ${STAGES[*]}"
                fi
            fi
            ;;
        tmpfs) tmpfs_dsts+=("${dst}") ;;
        *) ;; # cache mounts hold no build input
        esac
    done < <(run_mounts "${body}")

    # /ctx/x.sh is only executable because a bind mount puts it there.
    assert_eq "${label}: mounts the ctx stage at /ctx" "1" "${has_ctx_mount}"

    for script in "${scripts[@]}"; do
        file="${REPO_ROOT}/build_files/${script#/ctx/}"
        [[ -f "${file}" ]] || continue
        needed=()
        while IFS= read -r dir; do
            [[ -n "${dir}" ]] && needed+=("${dir}")
        done < <(required_dirs "${file}")

        for dir in "${needed[@]:-}"; do
            [[ -z "${dir}" ]] && continue
            provided=0
            for dst in "${bind_dsts[@]:-}"; do
                [[ -z "${dst}" ]] && continue
                if mount_provides "${dst}" "${dir}"; then
                    provided=1
                    break
                fi
            done
            if [[ "${provided}" -eq 1 ]]; then
                _pass "${label}: ${script} reads ${dir}, and a mount provides it"
            else
                _fail "${label}: ${script} reads ${dir}, and a mount provides it" \
                    "no --mount on this RUN puts anything at or under ${dir}" \
                    "this RUN mounts: ${bind_dsts[*]:-<none>}"
            fi
        done
    done

    # A tmpfs over a bind mount's destination replaces it with an empty
    # directory, so the two cannot be stacked on the same tree.
    for tmpfs_dst in "${tmpfs_dsts[@]:-}"; do
        [[ -z "${tmpfs_dst}" ]] && continue
        for dst in "${bind_dsts[@]:-}"; do
            [[ -z "${dst}" ]] && continue
            if [[ "${dst}" == "${tmpfs_dst}/"* ]]; then
                _fail "${label}: no tmpfs covers a bind mount of the same RUN" \
                    "tmpfs at ${tmpfs_dst} shadows the bind mount at ${dst}"
            else
                _pass "${label}: tmpfs at ${tmpfs_dst} does not cover ${dst}"
            fi
        done
    done

    # Nested binds: the parent has to be mounted first or it hides the child.
    for ((i = 0; i < ${#bind_dsts[@]}; i++)); do
        for ((j = i + 1; j < ${#bind_dsts[@]}; j++)); do
            if [[ "${bind_dsts[i]}" == "${bind_dsts[j]}/"* ]]; then
                _fail "${label}: nested mounts are declared parent first" \
                    "${bind_dsts[j]} contains ${bind_dsts[i]} but is declared after it"
            fi
        done
    done
done

# --- 3. the order the scripts run in ----------------------------------------

# kernel-akmods.sh erases /usr/lib/modules and installs the replacement kernel;
# zfs.sh picks that kernel out of /usr/lib/modules and builds its initramfs.
# They also read different mounts, so a split would need both mount sets
# duplicated -- keeping them in one RUN is what makes the pairing hold.
same_run=""
for body in "${RUN_BODIES[@]}"; do
    mapfile -t in_run < <(run_scripts "${body}")
    joined=" ${in_run[*]:-} "
    if [[ "${joined}" == *" /ctx/kernel-akmods.sh "* ]]; then
        same_run="${joined}"
    fi
done
assert_contains "kernel-akmods.sh and zfs.sh run in one RUN" \
    "${same_run}" "/ctx/kernel-akmods.sh /ctx/zfs.sh"

order="$(printf '%s\n' "${RUN_BODIES[@]}" | grep -oE '/ctx/[A-Za-z0-9_.-]+\.sh' | tr '\n' ' ')"
assert_eq "and the four scripts run kernel, zfs, build, post-check" \
    "/ctx/kernel-akmods.sh /ctx/zfs.sh /ctx/build.sh /ctx/post-check.sh " \
    "${order}"

# post-check.sh is the gate: it inspects the finished image, so nothing that
# changes the image may run after it.
last_ctx_run=-1
for index in "${!RUN_BODIES[@]}"; do
    [[ -n "$(run_scripts "${RUN_BODIES[index]}")" ]] && last_ctx_run="${index}"
done
assert_contains "post-check.sh is the last build_files script to run" \
    "${RUN_BODIES[last_ctx_run]}" "/ctx/post-check.sh"

lint_after_post_check=0
for ((index = last_ctx_run + 1; index < ${#RUN_BODIES[@]}; index++)); do
    [[ "${RUN_BODIES[index]}" == *"bootc container lint"* ]] && lint_after_post_check=1
done
assert_eq "and bootc container lint runs after it" "1" "${lint_after_post_check}"

# --- 4. the specific joins, named -------------------------------------------
#
# The loops above are generic: if an extractor regressed to returning nothing
# they would pass while checking nothing. These name the four mounts the build
# actually depends on, so the generic cases cannot go quiet.

kernel_akmods_dirs="$(required_dirs "${REPO_ROOT}/build_files/kernel-akmods.sh" | tr '\n' ' ')"
zfs_dirs="$(required_dirs "${REPO_ROOT}/build_files/zfs.sh" | tr '\n' ' ')"

assert_contains "kernel-akmods.sh reads the kernel RPM mount" \
    "${kernel_akmods_dirs}" "/tmp/kernel-rpms"
assert_contains "kernel-akmods.sh reads the common akmods mount" \
    "${kernel_akmods_dirs}" "/tmp/rpms/common"
assert_contains "kernel-akmods.sh reads the kmods mount" \
    "${kernel_akmods_dirs}" "/tmp/rpms/kmods"
assert_contains "zfs.sh reads the akmods-zfs mount" \
    "${zfs_dirs}" "/tmp/rpms/kmods/zfs"

all_mounts=""
for body in "${RUN_BODIES[@]}"; do
    all_mounts+="$(run_mounts "${body}")"$'\n'
done

# The ZFS kmods come from a different image than the common ones, on its own
# mutable tag; kernel-akmods.sh's certificate comment turns on that split.
assert_contains "the zfs kmods are mounted from the akmods-zfs stage" \
    "${all_mounts}" $'bind\t/tmp/rpms/kmods/zfs\takmods-zfs'
assert_contains "the common kmods are mounted from the akmods stage" \
    "${all_mounts}" $'bind\t/tmp/rpms/kmods\takmods'
assert_contains "the kernel RPMs are mounted from the akmods stage" \
    "${all_mounts}" $'bind\t/tmp/kernel-rpms\takmods'

# build.sh installs packages and must not see the RPM mounts: a tmpfs /tmp is
# what keeps the akmods trees out of the image's cache layer.
for body in "${RUN_BODIES[@]}"; do
    [[ "${body}" == *"/ctx/build.sh"* ]] || continue
    assert_contains "build.sh's RUN puts a tmpfs on /tmp" \
        "$(run_mounts "${body}")" $'tmpfs\t/tmp\t-'
done

finish
