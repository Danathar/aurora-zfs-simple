#!/usr/bin/env bash
#
# Boots the published image in a throwaway VM and checks, over SSH, that it
# finished booting with ZFS installed and the zfs kernel module loaded.
#
# This image is the one in its family that throws away Aurora's kernel
# (build_files/kernel-akmods.sh) and boots the one kmod-zfs was built for. Every
# other check here reads the image as files: build_files/post-check.sh proves
# zfs.ko is in the image and matches the kernel, build.yml that the pushed
# digest is signed, nightly-compliance.yml that `:latest` still is. None of them
# starts it. So a replacement kernel that does not boot under the Aurora
# userspace, or a zfs.ko that is present but will not load, would sit at
# `:latest` until a machine tracking it rebooted into it.
#
# What this does, in order:
#
#   1. Resolves the tag to a digest and reads the image's revision label. The
#      digest is what boots, because `:latest` can move while this runs; the
#      revision is printed so a reader can tell which commit was booted.
#   2. Pulls that digest.
#   3. Boots it with `bcvk ephemeral run-ssh`. bcvk starts the image's own
#      kernel and initramfs in QEMU with the image as a read-only virtiofs
#      root, logs in as root with a key it provisions, and runs the check
#      script. Nothing is installed to a disk and nothing is upgraded.
#   4. Reads the results back from marked lines of the SSH session's output and
#      writes result.json and a summary.
#
# It reports; it gates nothing. .github/workflows/boot-test.yml runs it after
# every build.yml run on main, against whatever `:latest` is then.
#
# A port of the boot test in Danathar/arch-bootc (scripts/boot-test.sh), with
# the guest checks of Danathar/zfs-aurora-complex (ci_tools/boot_test.py), the
# sibling built on the same Aurora base.
#
# Exit status:
#   0  the image booted and every check passed
#   1  the boot or a check failed
#   2  usage error, missing tool, or the image could not be resolved or pulled

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: boot-test.sh --image REF [--work DIR]

Boot a published aurora-zfs-simple image in a throwaway VM with bcvk and check
that ZFS is installed and its kernel module loaded at boot.

  --image REF  Image to boot, by tag or digest, e.g.
               ghcr.io/danathar/aurora-zfs-simple:latest. Required.
  --work DIR   Where logs, the check script and result.json go.
               Defaults to ./boot-test.

Needs skopeo, podman, bcvk, jq, base64, timeout, and /dev/kvm.

Exit status: 0 passed, 1 the boot or a check failed, 2 usage or setup error.
USAGE
}

# Every guest line the host reads starts with this, so results can be told
# apart from whatever else the SSH session carries (login banners, terminal
# queries). It is looked for anywhere in a line, not only at its start.
MARKER="AZS-BOOT-"

VM_MEMORY="4G"
VM_VCPUS="2"
# Seconds the guest waits for boot to settle before it checks anyway. A unit
# that never finishes starting must not stop the ZFS checks from running.
SETTLE_TIMEOUT_SECONDS=300
# Seconds for one whole boot, checks included. bcvk gives up on SSH by itself
# after four minutes; this bounds a VM that answers SSH and then hangs.
BOOT_TIMEOUT_SECONDS=$((15 * 60))
# A second boot absorbs nested-VM failures that have nothing to do with the
# image, such as a slow runner missing bcvk's SSH deadline. It is taken only
# when the guest reported no check at all. Once any check has reported, the VM
# booted and logged in, and that boot is the answer: a failed check that a
# later hang cut off before DONE must not be replaced by a second boot.
BOOT_ATTEMPTS=2
LOG_TAIL_LINES=40
PULL_RETRIES=3

image=""
work="boot-test"

need_value() {
    if (($2 < 2)); then
        printf 'error: %s needs a value\n' "$1" >&2
        exit 2
    fi
}

while (($# > 0)); do
    case "$1" in
        --image)
            need_value "$1" "$#"
            image="$2"
            shift 2
            ;;
        --work)
            need_value "$1" "$#"
            work="$2"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            printf 'error: unknown argument %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "${image}" ]]; then
    echo "error: --image is required" >&2
    usage >&2
    exit 2
fi

# What each check runs in the guest. Exit 0 passes, and the first line it
# prints is kept as the detail.
#
# - boot:finished: systemd left `starting`. `degraded` passes because failed
#   units are listed separately and not judged: several fail on every
#   ephemeral boot for reasons that are the VM's, not the image's.
# - package:zfs and package:kmod-zfs: build_files/zfs.sh installed both.
# - module:zfs: /sys/module/zfs exists only once the module is loaded, so this
#   is the modules-load.d entry zfs.sh writes, working against the kernel
#   kernel-akmods.sh put in. The version it prints is the loaded module's.
# - zpool:list: userspace reaches the loaded module. "no pools available" is a
#   pass; the VM has no pool to import.
#
# Order matters. OpenZFS's libzfs_init runs `modprobe zfs` when the module is
# absent, so any zfs or zpool command before module:zfs would load the module
# and hide a boot that failed to. rpm does not touch it, and zpool:list comes
# last for that reason; the `zfs version` line the guest prints for the record
# runs after every check.
#
# sshd is not checked here because the session itself is the check.
checks=(
    "boot:finished|case \"\${state}\" in running | degraded) echo \"\${state}\" ;; *) echo \"\${state:-timeout}\"; false ;; esac"
    "package:zfs|rpm -q zfs"
    "package:kmod-zfs|rpm -q kmod-zfs"
    "module:zfs|test -d /sys/module/zfs && cat /sys/module/zfs/version"
    "zpool:list|timeout 60 zpool list"
)

for tool in skopeo podman bcvk jq base64 timeout; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        printf 'error: %s is required\n' "${tool}" >&2
        exit 2
    fi
done

# The check script the guest runs once SSH is up.
guest_script() {
    local entry name command
    cat <<EOF
set -u
# bcvk gives the session a terminal, so systemctl would page its output through
# less and wait for a key that never comes.
export SYSTEMD_PAGER= PAGER=cat
state="\$(timeout ${SETTLE_TIMEOUT_SECONDS} systemctl is-system-running --wait 2>/dev/null)"
echo "${MARKER}STATE \${state:-timeout}"
echo "${MARKER}INFO kernel \$(uname -r)"
EOF
    for entry in "${checks[@]}"; do
        name="${entry%%|*}"
        command="${entry#*|}"
        cat <<EOF
if out="\$(${command} 2>&1)"; then status=pass; else status=fail; fi
echo "${MARKER}CHECK ${name} \${status} \$(printf '%s\n' "\${out}" | head -n 1)"
EOF
    done
    cat <<EOF
zfs version 2>/dev/null | while read -r line; do
  echo "${MARKER}INFO zfs-version \${line}"
done
systemctl --failed --plain --no-legend --full | while read -r unit _; do
  echo "${MARKER}FAILED-UNIT \${unit}"
done
echo "${MARKER}DONE"
EOF
}

# What bcvk needs from the guest that an installed system has or does not need,
# injected into this boot only. The image is unchanged, and nothing here
# reaches an installed system.
#
# - aurora-zfs-simple-roothome.service. bcvk provisions root's SSH key through
#   a systemd credential that tmpfiles writes to /root/.ssh. On an ostree image
#   /root is a symlink to /var/roothome, which an installed system has from its
#   deployment but an ephemeral /var built from the image does not, so the key
#   was never written. The unit creates the directory before tmpfiles runs.
# - sshd.service, wanted by default.target. bcvk connects to TCP port 22
#   through QEMU's user network, so sshd has to run whether or not the image
#   enables it.
# - flatpak-preinstall.service, masked. Aurora's first boot downloads about a
#   gigabyte of Flatpaks from Flathub, and boot does not finish until it does.
#   In the VM that download can stall on Flathub and then run out of space,
#   which held run 40186293766 at `starting` past the settle wait and failed
#   boot:finished on an image whose ZFS checks all passed (#441). Its result
#   says nothing about the kernel or ZFS. The mask is an empty file, which
#   systemd reads as masked: bcvk copies top-level unit files as regular files,
#   so a /dev/null symlink would not survive.
#
# zfs-aurora-complex, zfs-kinoite-complex and atomic-image-builder inject the
# same two for the same reasons.
ROOTHOME_UNIT='[Unit]
Description=Create /var/roothome so systemd credentials can provision /root/.ssh
DefaultDependencies=no
After=local-fs.target
Before=systemd-tmpfiles-setup.service
ConditionPathExists=!/var/roothome

[Service]
Type=oneshot
ExecStart=/usr/bin/mkdir -p -m 0700 /var/roothome

[Install]
WantedBy=default.target'

write_units() {
    local dir="$1"
    mkdir -p "${dir}/system/default.target.wants"
    printf '%s\n' "${ROOTHOME_UNIT}" >"${dir}/system/aurora-zfs-simple-roothome.service"
    ln -sfn ../aurora-zfs-simple-roothome.service \
        "${dir}/system/default.target.wants/aurora-zfs-simple-roothome.service"
    ln -sfn /usr/lib/systemd/system/sshd.service \
        "${dir}/system/default.target.wants/sshd.service"
    : >"${dir}/system/flatpak-preinstall.service"
}

# The marked lines of one boot's output, with whatever preceded the marker on
# the same line dropped.
marked_lines() {
    grep -aoE "${MARKER}[A-Z-]+( .*)?" "$1" | sed -E "s/^${MARKER}//; s/\r$//" || true
}

# result.json's `report`, built from one boot's output.
parse_report() {
    local log="$1" line kind rest state="" kernel="" finished=false
    local -a rows=()
    while IFS= read -r line; do
        kind="${line%% *}"
        rest=""
        [[ "${line}" == *" "* ]] && rest="${line#* }"
        case "${kind}" in
            DONE) finished=true ;;
            STATE) state="${rest}" ;;
            INFO)
                case "${rest}" in
                    "kernel "*) kernel="${rest#kernel }" ;;
                    "zfs-version "*) rows+=("Z ${rest#zfs-version }") ;;
                    *) ;;
                esac
                ;;
            CHECK) rows+=("C ${rest}") ;;
            FAILED-UNIT) [[ -n "${rest}" ]] && rows+=("U ${rest}") ;;
            *) ;;
        esac
    done < <(marked_lines "${log}")
    jq -n \
        --argjson finished "${finished}" \
        --arg state "${state}" \
        --arg kernel "${kernel}" \
        --args '{
            done: $finished,
            state: $state,
            kernel: $kernel,
            zfs_version: [$ARGS.positional[] | select(startswith("Z ")) | .[2:]],
            checks: [$ARGS.positional[] | select(startswith("C ")) | .[2:]
                | capture("^(?<name>[^ ]+) (?<status>[^ ]+) ?(?<detail>.*)$")],
            failed_units: [$ARGS.positional[] | select(startswith("U ")) | .[2:]]
        }' \
        "${rows[@]}"
}

# Passed or not, and why, from a report and the checks this script expects.
judge() {
    local report="$1"
    jq -r --args '
        ($ARGS.positional) as $expected
        | (.checks | map({key: .name, value: .status}) | from_entries) as $ran
        | [$expected[] | select($ran[.] == null)] as $missing
        | [.checks[] | select(.status != "pass") | .name] as $failed
        | if (.done | not) then
            "fail\tThe VM never reached the point where the checks finish (no SSH, or the checks hung)."
          elif ($missing + $failed | length) > 0 then
            "fail\tBooted and logged in, but "
              + ([(if ($missing | length) > 0 then "checks with no result: " + ($missing | join(", ")) else empty end),
                  (if ($failed | length) > 0 then "failed checks: " + ($failed | join(", ")) else empty end)]
                 | join("; ")) + "."
          else
            "pass\tBooted, logged in over SSH, and every check passed."
          end' "${check_names[@]}" <<<"${report}"
}

check_names=()
for entry in "${checks[@]}"; do
    check_names+=("${entry%%|*}")
done

mkdir -p "${work}"
work="$(cd -- "${work}" && pwd)"

# Boot a digest, not the tag: `:latest` can move while this runs, and the
# summary must name exactly the artifact that was booted.
if ! inspected="$(skopeo inspect --retry-times "${PULL_RETRIES}" \
    --format '{{.Digest}} {{index .Labels "org.opencontainers.image.revision"}}' \
    "docker://${image}")"; then
    printf 'error: could not resolve %s to a digest\n' "${image}" >&2
    exit 2
fi
digest="${inspected%% *}"
revision="${inspected#* }"
if [[ ! "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    printf 'error: %s resolved to %s, which is not a digest\n' "${image}" "${digest}" >&2
    exit 2
fi
if [[ -z "${revision}" || "${revision}" == "<no value>" ]]; then
    revision="unknown"
fi
# Strip a tag, but not a registry port: only a colon in the last path segment
# starts a tag.
repository="${image%%@*}"
if [[ "${repository##*/}" == *:* ]]; then
    repository="${repository%:*}"
fi
pinned="${repository}@${digest}"
echo "Booting ${pinned} (revision ${revision})"

if ! podman pull --quiet --retry "${PULL_RETRIES}" "${pinned}"; then
    printf 'error: could not pull %s\n' "${pinned}" >&2
    exit 2
fi

write_units "${work}/units"
# The script travels inside the SSH command line, base64-encoded so no shell
# quoting can change it, rather than on a --ro-bind virtiofs share: bcvk mounts
# a share with an SELinux `context=` option that some guest kernels refuse
# (arch-bootc's hosted run 39145575748), and then the guest never sees the
# file. The same script is kept in the work directory, so what the guest ran
# is in the artifact.
mkdir -p "${work}/checks"
guest_script >"${work}/checks/checks.sh"
guest_command="echo $(base64 -w0 <"${work}/checks/checks.sh") | base64 -d | bash"

report=""
log=""
attempts=0
for ((attempt = 1; attempt <= BOOT_ATTEMPTS; attempt++)); do
    attempts="${attempt}"
    log_dir="${work}/boot-${attempt}"
    mkdir -p "${log_dir}"
    log="${log_dir}/bcvk.log"
    name="aurora-zfs-simple-boot-test-$$-${attempt}"
    # Every path is absolute: a relative --systemd-units path was silently
    # ignored in zfs-kinoite-complex's local runs.
    command=(
        bcvk ephemeral run-ssh
        --name "${name}"
        --memory "${VM_MEMORY}"
        --vcpus "${VM_VCPUS}"
        --systemd-units "${work}/units"
        --log-dir "journal,console=${log_dir}/"
        "${pinned}"
        --
        "${guest_command}"
    )
    printf '+ %s <checks/checks.sh, base64-encoded>\n' "${command[*]:0:${#command[@]}-1}"
    status=0
    timeout --kill-after=30 "${BOOT_TIMEOUT_SECONDS}" "${command[@]}" >"${log}" 2>&1 </dev/null || status=$?
    if ((status == 124)); then
        printf '\nbcvk timed out after %ss\n' "${BOOT_TIMEOUT_SECONDS}" >>"${log}"
    fi
    # A killed bcvk leaves the VM's container running, holding its memory
    # through the next attempt.
    podman rm --force --ignore "${name}" >/dev/null 2>&1 || true
    report="$(parse_report "${log}")"
    if [[ "$(jq -r '.done or (.checks | length > 0)' <<<"${report}")" == "true" ]]; then
        break
    fi
done

verdict="$(judge "${report}")"
outcome="${verdict%%$'\t'*}"
summary="${verdict#*$'\t'}"

jq -n \
    --arg image "${image}" \
    --arg booted "${pinned}" \
    --arg revision "${revision}" \
    --argjson passed "$([[ "${outcome}" == pass ]] && echo true || echo false)" \
    --arg summary "${summary}" \
    --argjson attempts "${attempts}" \
    --argjson report "${report}" \
    '{image: $image, booted: $booted, revision: $revision, passed: $passed,
      summary: $summary, attempts: $attempts, report: $report}' \
    >"${work}/result.json"

render_summary() {
    jq -r '
        "## Boot test",
        "",
        "**\(if .passed then "Passed" else "Failed" end)**: \(.summary)",
        "",
        "| | |",
        "|---|---|",
        "| Image | `\(.image)` |",
        "| Booted | `\(.booted)` |",
        "| Revision | `\(.revision)` |",
        "| Boots | \(.attempts) |",
        "| Kernel | `\(.report.kernel | if . == "" then "unknown" else . end)` |",
        "| systemd state | `\(.report.state | if . == "" then "unknown" else . end)` |",
        "| zfs version | `\(.report.zfs_version | if length == 0 then "unknown" else join(" / ") end)` |",
        (if (.report.checks | length) > 0 then
            "", "| Check | Result | Detail |", "|---|---|---|",
            (.report.checks[] | "| `\(.name)` | \(.status) | `\(.detail)` |")
        else empty end),
        (if (.report.failed_units | length) > 0 then
            "", "Failed units (not judged): \(.report.failed_units | map("`\(.)`") | join(", "))"
        else empty end)
    ' "${work}/result.json"
    if [[ "${outcome}" != pass ]]; then
        printf '\n<details><summary>bcvk output (tail)</summary>\n\n```\n'
        tail -n "${LOG_TAIL_LINES}" "${log}"
        printf '```\n\n</details>\n'
    fi
}

text="$(render_summary)"
printf '%s\n' "${text}"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "${text}" >>"${GITHUB_STEP_SUMMARY}"
fi

if [[ "${outcome}" != pass ]]; then
    printf 'error: boot test failed for %s: %s\n' "${pinned}" "${summary}" >&2
    exit 1
fi
