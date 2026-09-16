#!/usr/bin/env bash
#
# Joins .github/prompts/*.prompt.md and .claude/commands/*.md to the machine
# they operate.
#
# Those five documents are the operating procedure for this repo. When a build
# goes red, the agent reading `diagnose-build-failure.prompt.md` decides whether
# it is akmod skew; `pin-akmods.prompt.md` is what gets edited into the
# Containerfile when waiting stops being acceptable; `bump-fedora-version.prompt.md`
# frames the highest-risk change here. `.claude/commands/` wraps each as a slash
# command so Claude Code, Copilot and Cursor all follow one copy.
#
# Before this file nothing opened them. `tests/test-coverage.sh` cannot see
# Markdown, and the only contact any test had was pass 3 of
# tests/test-docs-paths.sh, which resolves relative link targets in every
# tracked *.md -- that proves the files they point at exist and says nothing
# about what they claim.
#
# What they claim is a hand copy of this tree:
#
#   * the two akmods image references the diagnosis inspects are a second copy
#     of the Containerfile's `FROM ... AS akmods{,-zfs}` lines, reached by a
#     `sed` of `ARG FEDORA_VERSION` that this test runs rather than reads,
#   * the seven OpenZFS RPM families the bump prompt says must agree are the
#     `ZFS_RPMS` array in build_files/zfs.sh,
#   * the `kmod-zfs` glob asymmetry it uses as the skew signature, the Fedora
#     guard it promises, and the kernel erase that makes a newer `aurora-dx`
#     kernel *not* skew are all properties of Containerfile and build_files/,
#   * the badge and the `blocked` state step 0 sends the reader to are produced
#     by ci/write-badges.sh and described in README.md, and
#   * each command file restates one rule from its prompt in its own words.
#
# A copy drifts silently, and the failure mode is specific: an agent following a
# drifted procedure during an outage inspects the images the build no longer
# pulls and reports "not skew" with confidence. So nothing below is typed in
# twice -- every expectation is computed from the Containerfile, build_files/,
# ci/write-badges.sh, README.md or the prompt itself. Extractions that match
# nothing fail loudly rather than verifying an empty set.
#
# Scope: claims that name something in this repo. Judgement calls, and prose
# about what Universal Blue publishes, are not checkable here and are left
# alone.

# Almost every needle here is a literal that has to reach a file's text
# unexpanded -- `${KERNEL}`, `${FEDORA_VERSION}`, `$ARGUMENTS`, `${stage}`. The
# single quotes are the point, so SC2016 is off for the file rather than
# repeated above a dozen lines.
# shellcheck disable=SC2016

set -uo pipefail

TEST_NAME="test-agent-prompts"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

PROMPT_DIR="${REPO_ROOT}/.github/prompts"
CMD_DIR="${REPO_ROOT}/.claude/commands"
CONTAINERFILE="${REPO_ROOT}/Containerfile"
ZFS_SH="${REPO_ROOT}/build_files/zfs.sh"
KERNEL_AKMODS_SH="${REPO_ROOT}/build_files/kernel-akmods.sh"
WRITE_BADGES="${REPO_ROOT}/ci/write-badges.sh"
AGENTS_MD="${REPO_ROOT}/AGENTS.md"
README_MD="${REPO_ROOT}/README.md"
BUILD_YML="${REPO_ROOT}/.github/workflows/build.yml"

DIAGNOSE="${PROMPT_DIR}/diagnose-build-failure.prompt.md"
PIN="${PROMPT_DIR}/pin-akmods.prompt.md"
BUMP="${PROMPT_DIR}/bump-fedora-version.prompt.md"

for required in "${DIAGNOSE}" "${PIN}" "${BUMP}" "${CONTAINERFILE}" "${ZFS_SH}" \
    "${KERNEL_AKMODS_SH}" "${WRITE_BADGES}" "${AGENTS_MD}" "${README_MD}" "${BUILD_YML}"; do
    assert_file_exists "${required#"${REPO_ROOT}/"} is present" "${required}"
done

# --- What the build actually does -------------------------------------------
#
# Everything the documents are checked against is derived here, once.

# The Containerfile's own ARG default. Read independently of the sed the
# diagnose prompt ships, so that command can be compared against this rather
# than against itself.
FEDORA_VERSION="$(sed -nE 's/^ARG[[:space:]]+FEDORA_VERSION=([0-9]+).*/\1/p' "${CONTAINERFILE}" | head -1)"
AURORA_IMAGE="$(sed -nE 's/^ARG[[:space:]]+AURORA_IMAGE=(.+)$/\1/p' "${CONTAINERFILE}" | head -1)"
AURORA_TAG="$(sed -nE 's/^ARG[[:space:]]+AURORA_TAG=(.+)$/\1/p' "${CONTAINERFILE}" | head -1)"

if [[ -z "${FEDORA_VERSION}" || -z "${AURORA_IMAGE}" || -z "${AURORA_TAG}" ]]; then
    _fail "the Containerfile still declares FEDORA_VERSION, AURORA_IMAGE and AURORA_TAG" \
        "FEDORA_VERSION='${FEDORA_VERSION}' AURORA_IMAGE='${AURORA_IMAGE}' AURORA_TAG='${AURORA_TAG}'"
else
    _pass "the Containerfile still declares FEDORA_VERSION, AURORA_IMAGE and AURORA_TAG"
fi

# The image reference a build stage pulls, with quoting removed and
# FEDORA_VERSION resolved -- the same two substitutions ci/write-badges.sh makes,
# reimplemented rather than sourced so that a change to one has to be a
# deliberate change to both.
containerfile_ref() {
    local stage=$1 line ref
    line="$(grep -E "^FROM[[:space:]]+[^[:space:]]+[[:space:]]+AS[[:space:]]+${stage}[[:space:]]*$" \
        "${CONTAINERFILE}" | head -1)"
    [[ -n "${line}" ]] || return 0
    ref="$(printf '%s' "${line}" | awk '{print $2}' | tr -d "\"'")"
    ref="${ref//\$\{FEDORA_VERSION\}/${FEDORA_VERSION}}"
    ref="${ref//\$FEDORA_VERSION/${FEDORA_VERSION}}"
    printf '%s' "${ref}"
}

# The unresolved form, for deciding whether the inputs are currently pinned.
containerfile_ref_raw() {
    local stage=$1 line
    line="$(grep -E "^FROM[[:space:]]+[^[:space:]]+[[:space:]]+AS[[:space:]]+${stage}[[:space:]]*$" \
        "${CONTAINERFILE}" | head -1)"
    [[ -n "${line}" ]] || return 0
    printf '%s' "$(printf '%s' "${line}" | awk '{print $2}' | tr -d "\"'")"
}

AKMODS_REF="$(containerfile_ref akmods)"
AKMODS_ZFS_REF="$(containerfile_ref akmods-zfs)"
AKMODS_REF_RAW="$(containerfile_ref_raw akmods)"

if [[ -z "${AKMODS_REF}" || -z "${AKMODS_ZFS_REF}" ]]; then
    _fail "the Containerfile still pulls both akmods stages" \
        "akmods='${AKMODS_REF}' akmods-zfs='${AKMODS_ZFS_REF}'"
else
    _pass "the Containerfile still pulls both akmods stages"
fi

# Repository part of an image reference: everything before the tag.
repo_of() { printf '%s' "${1%%:*}"; }
# Tag part.
tag_of() { printf '%s' "${1#*:}"; }

# The RPM families build_files/zfs.sh installs into the image, derived from the
# ZFS_RPMS array: one name per entry, with the path, the version glob and the
# kernel interpolation stripped. `pv` is not an OpenZFS package and is dropped.
zfs_rpm_families() {
    sed -n '/^ZFS_RPMS=(/,/^)/p' "${ZFS_SH}" |
        sed -e '1d' -e '$d' |
        sed -e 's#^[[:space:]]*##' -e 's#[[:space:]]*$##' |
        grep -E '^/tmp/rpms/kmods/zfs/' |
        sed -e 's#^/tmp/rpms/kmods/zfs/##' |
        sed -e 's#-"\${KERNEL}".*##' -e 's#\[0-9\]-\*\.rpm$##' -e 's#-\*\.rpm$##' |
        sort -u
}

ZFS_FAMILIES="$(zfs_rpm_families)"
if [[ -z "${ZFS_FAMILIES}" ]]; then
    _fail "build_files/zfs.sh still declares a ZFS_RPMS array of package globs" \
        "extracted no package names from ZFS_RPMS"
else
    _pass "build_files/zfs.sh still declares a ZFS_RPMS array of package globs"
fi

# --- Markdown helpers --------------------------------------------------------

# A frontmatter value, from the block delimited by the first two `---` lines.
frontmatter_value() {
    local file=$1 key=$2
    awk -v key="${key}" '
        NR == 1 && $0 == "---" { inside = 1; next }
        inside && $0 == "---"  { exit }
        inside && index($0, key ":") == 1 {
            sub(/^[^:]*:[[:space:]]*/, "")
            print
            exit
        }
    ' "${file}"
}

# Everything inside fenced code blocks, which is where the runnable snippets
# live. The prose passes below deliberately use the whole file instead.
fenced_content() {
    awk '/^[ \t]*(```|~~~)/ { fenced = !fenced; next } fenced' "$1"
}

# Prose with hard wraps flattened and inline markup dropped, so a claim that the
# author wrapped across two lines -- or emphasised a word inside -- still
# matches as one string.
flattened_prose() {
    tr '\n' ' ' <"$1" | tr -d '`*' | sed -e 's/[[:space:]]\+/ /g'
}

# Offset of the first line matching a pattern, for the ordering assertions.
line_of() {
    grep -n -m1 -e "$2" "$1" | cut -d: -f1
}

# --- 1. The catalogs list the files beside them ------------------------------
#
# Both README tables are hand-maintained. A prompt added without a row is
# undiscoverable; a row left behind after a rename points at nothing.

prompt_files="$(cd "${PROMPT_DIR}" && find . -maxdepth 1 -name '*.md' ! -name 'README.md' -printf '%f\n' | sort)"
listed_prompts="$(grep -oE '\[`[a-z0-9-]+\.prompt\.md`\]' "${PROMPT_DIR}/README.md" |
    tr -d '[]`' | sort -u)"

assert_eq "the prompt catalog lists exactly the prompt files beside it" \
    "${prompt_files}" "${listed_prompts}"

while IFS= read -r prompt; do
    [[ -n "${prompt}" ]] || continue
    case "${prompt}" in
        *.prompt.md)
            _pass "${prompt} carries the .prompt.md suffix Copilot discovers by" ;;
        *)
            _fail "${prompt} carries the .prompt.md suffix Copilot discovers by" \
                "a plain .md in .github/prompts/ is invisible to Copilot" ;;
    esac

    description="$(frontmatter_value "${PROMPT_DIR}/${prompt}" description)"
    if [[ -n "${description}" ]]; then
        _pass "${prompt} carries a description in frontmatter"
    else
        _fail "${prompt} carries a description in frontmatter" \
            "the prompt catalog states description and mode frontmatter are required"
    fi

    assert_eq "${prompt} runs in agent mode" "agent" \
        "$(frontmatter_value "${PROMPT_DIR}/${prompt}" mode)"
done <<<"${prompt_files}"

command_files="$(cd "${CMD_DIR}" && find . -maxdepth 1 -name '*.md' ! -name 'README.md' -printf '%f\n' | sort)"
listed_commands="$(grep -oE '`/[a-z0-9-]+`' "${CMD_DIR}/README.md" | tr -d '`/' | sed 's/$/.md/' | sort -u)"

assert_eq "the command catalog lists exactly the command files beside it" \
    "${command_files}" "${listed_commands}"

# Each command is documented as a thin pointer at one prompt. Checking the
# mapping both ways is what makes it a pointer rather than a second copy: a
# prompt no command wraps is unreachable from Claude Code, and a command that
# points at two prompts has started to be a procedure of its own.
wrapped_prompts=""
while IFS= read -r cmd; do
    [[ -n "${cmd}" ]] || continue
    targets="$(grep -oE '\.github/prompts/[a-z0-9-]+\.prompt\.md' "${CMD_DIR}/${cmd}" |
        sed 's#.*/##' | sort -u)"
    if [[ "$(printf '%s\n' "${targets}" | grep -c .)" -eq 1 ]]; then
        _pass "${cmd} points at exactly one prompt"
        wrapped_prompts+="${targets}"$'\n'
    else
        _fail "${cmd} points at exactly one prompt" \
            "prompt links found: $(printf '%s' "${targets}" | tr '\n' ' ')"
    fi

    if [[ -n "$(frontmatter_value "${CMD_DIR}/${cmd}" description)" ]]; then
        _pass "${cmd} carries a description in frontmatter"
    else
        _fail "${cmd} carries a description in frontmatter" \
            "Claude Code lists the command by this string"
    fi

    # `$ARGUMENTS` is the only way the argument the description asks for reaches
    # the model. Without it the command silently discards what the user typed.
    assert_contains "${cmd} substitutes the argument it asks for" \
        "$(cat "${CMD_DIR}/${cmd}")" '$ARGUMENTS'

    # "That file is the procedure; do not restate it here." A fenced block in a
    # command file is a second copy of a command that already exists upstream.
    if [[ -z "$(fenced_content "${CMD_DIR}/${cmd}")" ]]; then
        _pass "${cmd} ships no runnable block of its own"
    else
        _fail "${cmd} ships no runnable block of its own" \
            "the procedure lives in .github/prompts/; a copy here drifts"
    fi
done <<<"${command_files}"

assert_eq "every prompt is wrapped by exactly one command" \
    "${prompt_files}" "$(printf '%s' "${wrapped_prompts}" | sort)"

# --- 2. The diagnosis inspects the images the build pulls --------------------

# The prompt ships this sed as a runnable step, so run it rather than read it.
# A rename of the ARG, or a Containerfile that stops declaring it, has to fail
# here and not in front of an operator during an outage.
sed_command="$(grep -oE "sed -n 's[^']*' Containerfile" "${DIAGNOSE}" | head -1)"
if [[ -z "${sed_command}" ]]; then
    _fail "the diagnosis still reads FEDORA_VERSION out of the Containerfile with sed" \
        "no 'sed -n ... Containerfile' command found in ${DIAGNOSE#"${REPO_ROOT}/"}"
else
    _pass "the diagnosis still reads FEDORA_VERSION out of the Containerfile with sed"
    extracted="$(cd "${REPO_ROOT}" && eval "${sed_command}")"
    assert_eq "running the diagnosis' own sed yields the Containerfile's FEDORA_VERSION" \
        "${FEDORA_VERSION}" "${extracted}"
fi

# The refs the skopeo loop builds, with the shell variable the prompt's own sed
# populates resolved to the value it would hold.
diagnose_refs="$(fenced_content "${DIAGNOSE}" |
    grep -oE 'ghcr\.io/ublue-os/[^"'"'"' ]+' |
    sed -e "s#\${img}#akmods#" -e "s#\${FEDORA_VERSION}#${FEDORA_VERSION}#g" |
    sort -u)"

if [[ -z "${diagnose_refs}" ]]; then
    _fail "the diagnosis names the akmods images by reference" "no ghcr.io reference in a fenced block"
else
    _pass "the diagnosis names the akmods images by reference"
fi

# The loop iterates `akmods akmods-zfs` over one templated ref, so the repository
# it names is the akmods stage's; the -zfs stage has to share everything else.
diagnose_ref="$(printf '%s\n' "${diagnose_refs}" | head -1)"
assert_eq "the diagnosis inspects the akmods repository the build pulls" \
    "$(repo_of "${AKMODS_REF}")" "$(repo_of "${diagnose_ref}")"
assert_contains "the diagnosis iterates both akmods stage names" \
    "$(fenced_content "${DIAGNOSE}")" "for img in akmods akmods-zfs"
assert_eq "the second stage's repository differs only by the -zfs suffix the loop appends" \
    "$(repo_of "${AKMODS_REF}")-zfs" "$(repo_of "${AKMODS_ZFS_REF}")"

# Tag equality only holds while the inputs float. Pinning is a documented and
# temporary state (pin-akmods.prompt.md), and it deliberately rewrites both FROM
# lines away from this template, so assert against the state the tree is in
# rather than failing a correct pin.
if [[ "${AKMODS_REF_RAW}" == *'${FEDORA_VERSION}'* || "${AKMODS_REF_RAW}" == *'$FEDORA_VERSION'* ]]; then
    assert_eq "the diagnosis inspects the exact tag the unpinned build pulls" \
        "${AKMODS_REF}" "${diagnose_ref}"
else
    # Pinned: the safety property pin-akmods.prompt.md states is that both
    # inputs carry the same kernel tag, which is checkable here and is the
    # mistake the prompt exists to prevent.
    assert_eq "while the inputs are pinned, both FROM lines carry the same tag" \
        "$(tag_of "${AKMODS_REF}")" "$(tag_of "${AKMODS_ZFS_REF}")"
fi

assert_contains "the diagnosis reads the label the badge and the pin check both read" \
    "$(fenced_content "${DIAGNOSE}")" 'ostree.linux'

# --- 3. The skew signature is a property of build_files/ ----------------------

zfs_sh="$(cat "${ZFS_SH}")"

assert_contains "build_files/zfs.sh still installs kmod-zfs by the kernel-versioned glob" \
    "${zfs_sh}" '/tmp/rpms/kmods/zfs/kmod-zfs-"${KERNEL}"*.rpm'

assert_contains "build_files/zfs.sh still aborts on the first failing command" \
    "${zfs_sh}" 'set -eoux pipefail'

zfs_install_line="$(grep -E '^dnf5 .*ZFS_RPMS' "${ZFS_SH}")"
if [[ -z "${zfs_install_line}" ]]; then
    _fail "build_files/zfs.sh installs the ZFS_RPMS set in one dnf5 command" \
        "no dnf5 install of ZFS_RPMS found"
else
    _pass "build_files/zfs.sh installs the ZFS_RPMS set in one dnf5 command"
    assert_not_contains "that install is fatal, as the prompt's Never section requires" \
        "${zfs_install_line}" '|| true'
fi

# The asymmetry the prompt uses as the signature: the userspace RPMs in the same
# command are not kernel-versioned, so they resolve while the kmod does not.
userspace_globs="$(sed -n '/^ZFS_RPMS=(/,/^)/p' "${ZFS_SH}" | grep -E 'lib|python3-pyzfs|/zfs-')"
if [[ -z "${userspace_globs}" ]]; then
    _fail "the same command installs the ZFS userspace RPMs" "no userspace globs in ZFS_RPMS"
else
    _pass "the same command installs the ZFS userspace RPMs"
    assert_not_contains "the userspace globs are not kernel-versioned, which is the asymmetry the prompt reads" \
        "${userspace_globs}" 'KERNEL'
fi

# "kernel-akmods.sh erases Aurora's kernel outright" -- why a newer aurora-dx
# kernel is not skew, and the reason the prompt tells the reader not to chase it.
kernel_akmods_sh="$(cat "${KERNEL_AKMODS_SH}")"
assert_contains "build_files/kernel-akmods.sh still removes the base image's module tree" \
    "${kernel_akmods_sh}" 'rm -rf /usr/lib/modules'
assert_contains "build_files/kernel-akmods.sh still erases the base kernel RPMs" \
    "${kernel_akmods_sh}" 'rpm --erase "${pkg}" --nodeps'
assert_contains "the diagnosis names the script that does the erasing" \
    "$(flattened_prose "${DIAGNOSE}")" 'kernel-akmods.sh'

# --- 4. Step 0's badge is the badge this repo publishes ----------------------

write_badges="$(cat "${WRITE_BADGES}")"

# The label is the argument after the output path, and the script writes this
# badge from two branches. Collect both: a rename that touches only one branch
# still leaves the reader looking for a badge by a name it sometimes does not
# carry, so the set has to have exactly one member before it is compared.
badge_labels="$(grep -A1 -F 'write_badge "${OUT_DIR}/akmods-badge.json"' "${WRITE_BADGES}" |
    sed -nE 's/^[[:space:]]*"([^"]+)".*/\1/p' | sort -u)"
badge_label_count="$(printf '%s\n' "${badge_labels}" | grep -c .)"

if [[ "${badge_label_count}" -ne 1 ]]; then
    _fail "ci/write-badges.sh writes this badge under exactly one label" \
        "labels found: $(printf '%s' "${badge_labels}" | tr '\n' ' ')"
else
    _pass "ci/write-badges.sh writes this badge under exactly one label"
    # The documents spell it with OpenZFS capitalised; the JSON label is
    # lower-case. Same badge, so compare case-insensitively.
    readme_badge_name="$(grep -oE '\*\*[A-Za-z]+/kernel\*\*' "${README_MD}" | head -1 | tr -d '*' |
        tr '[:upper:]' '[:lower:]')"
    assert_eq "the name the diagnosis and README use is the label the badge carries" \
        "${badge_labels}" "${readme_badge_name}"
fi

assert_contains "blocked is a state ci/write-badges.sh actually emits" \
    "${write_badges}" '"blocked: kernel '
assert_contains "README.md explains what blocked means, as step 0 assumes" \
    "$(flattened_prose "${README_MD}")" 'blocked means there is no kmod-zfs'
assert_contains "the badge is derived from the same ostree.linux label step 1 reads" \
    "${write_badges}" 'ostree.linux'
assert_contains "the badge reads the Containerfile's FROM lines rather than a fixed tag" \
    "${write_badges}" 'AS[[:space:]]+${stage}'

# --- 5. Step 4's non-skew failure modes exist in this repo -------------------

agents_prose="$(flattened_prose "${AGENTS_MD}")"
assert_contains "AGENTS.md still documents the Chunkah exit 126 failure" \
    "${agents_prose}" 'Chunkah rechunk: Argument list too long (exit 126)'
assert_contains "the run the diagnosis is about is the name build.yml publishes" \
    "$(flattened_prose "${DIAGNOSE}")" "$(sed -nE 's/^name:[[:space:]]*(.+)$/\1/p' "${BUILD_YML}" | head -1)"
assert_file_exists "post-check.sh, which step 4 names as a rejecter, is present" \
    "${REPO_ROOT}/build_files/post-check.sh"
assert_contains "the Containerfile still runs post-check.sh over the assembled image" \
    "$(cat "${CONTAINERFILE}")" '/ctx/post-check.sh'

# The Fedora guard both the diagnosis and the bump prompt promise.
guard="$(grep -A1 'rpm -E %fedora' "${CONTAINERFILE}" | tr '\n' ' ')"
if [[ -z "${guard}" ]]; then
    _fail "the Containerfile still guards the base image's Fedora release" \
        "no 'rpm -E %fedora' comparison found"
else
    _pass "the Containerfile still guards the base image's Fedora release"
    assert_contains "the guard compares the base image against FEDORA_VERSION" \
        "${guard}" '${FEDORA_VERSION}'
    assert_contains "the guard fails the build rather than warning" "${guard}" 'exit 1'
    assert_contains "the guard names the image it rejected, which is what makes it loud" \
        "${guard}" '${AURORA_IMAGE}:${AURORA_TAG}'
fi

# --- 6. Step 3's upstream check ---------------------------------------------

diagnose_fenced="$(fenced_content "${DIAGNOSE}")"
assert_contains "step 3 still queries the akmods repository the inputs come from" \
    "${diagnose_fenced}" "--repo $(repo_of "${AKMODS_REF}" | sed 's#^ghcr\.io/##')"
assert_contains "--state all is still on that query, as the prose calls load-bearing" \
    "${diagnose_fenced}" '--state all'

# --- 7. The pin procedure edits the lines the build reads --------------------

pin_fenced="$(fenced_content "${PIN}")"
pin_from_lines="$(printf '%s\n' "${pin_fenced}" | grep -E '^FROM ')"
pin_from_count="$(printf '%s\n' "${pin_from_lines}" | grep -c .)"

assert_eq "the pin example rewrites both FROM lines, never one" "2" "${pin_from_count}"

pin_tags="$(printf '%s\n' "${pin_from_lines}" | awk '{print $2}' | sed 's/^[^:]*://' | sort -u)"
assert_eq "both pinned lines carry one kernel tag, which is the whole safety property" \
    "1" "$(printf '%s\n' "${pin_tags}" | grep -c .)"

pin_repos="$(printf '%s\n' "${pin_from_lines}" | awk '{print $2}' | sed 's/:.*//' | sort -u)"
assert_eq "the pin example replaces the repositories the build actually pulls" \
    "$(printf '%s\n%s\n' "$(repo_of "${AKMODS_REF}")" "$(repo_of "${AKMODS_ZFS_REF}")" | sort -u)" \
    "${pin_repos}"

pin_stages="$(printf '%s\n' "${pin_from_lines}" | awk '{print $4}' | sort -u)"
assert_eq "the pin example keeps the stage aliases the Containerfile's RUN mounts reference" \
    "$(printf 'akmods\nakmods-zfs\n' | sort -u)" "${pin_stages}"

# The verify snippet has to check the tag the example writes, or it verifies
# nothing about the change being made.
assert_contains "the verify step inspects the same tag the example pins to" \
    "${pin_fenced}" "$(printf '%s\n' "${pin_tags}" | head -1)"
assert_contains "the verify step reads the label that decides the match" \
    "${pin_fenced}" 'ostree.linux'

# "The `Containerfile` comments say so" -- the pin-both rule is stated there too.
assert_contains "the Containerfile comment the pin prompt cites is still there" \
    "$(flattened_prose "${CONTAINERFILE}")" 'if you have to pin keep this in sync with the above'

# --- 8. The bump prompt's inputs and package set -----------------------------

bump_fenced="$(fenced_content "${BUMP}")"
bump_inputs="$(printf '%s\n' "${bump_fenced}" | grep -oE 'ghcr\.io/ublue-os/[a-z0-9-]+' | sort -u)"
expected_inputs="$(printf '%s\n%s\n%s\n' \
    "${AURORA_IMAGE}" "$(repo_of "${AKMODS_REF}")" "$(repo_of "${AKMODS_ZFS_REF}")" | sort -u)"

assert_eq "the three inputs that must line up are the three the Containerfile pulls" \
    "${expected_inputs}" "${bump_inputs}"

assert_contains "the base image tag the bump prompt names is the one the build uses" \
    "${bump_fenced}" "${AURORA_IMAGE}:${AURORA_TAG}"

# The OpenZFS release has to be coherent across exactly the families zfs.sh
# installs. Both directions: a package added to the build and not to the prompt
# leaves the operator checking an incomplete set, and a name dropped from the
# build leaves the prompt asking for an artifact that is no longer there.
bump_prose="$(flattened_prose "${BUMP}")"
bump_named=""
missing_from_prompt=""
while IFS= read -r family; do
    [[ -n "${family}" ]] || continue
    if [[ "${bump_prose}" == *" ${family} "* || "${bump_prose}" == *" ${family},"* || "${bump_prose}" == *" ${family}."* ]]; then
        bump_named+="${family}"$'\n'
    else
        missing_from_prompt+="${family} "
    fi
done <<<"${ZFS_FAMILIES}"

if [[ -z "${missing_from_prompt}" ]]; then
    _pass "every OpenZFS family build_files/zfs.sh installs is named in the bump prompt"
else
    _fail "every OpenZFS family build_files/zfs.sh installs is named in the bump prompt" \
        "named in ZFS_RPMS but not in the prompt: ${missing_from_prompt}"
fi

# The reverse: the prompt's coherence list, taken from the sentence that states
# it, must not name a package the build does not install.
coherence_list="$(printf '%s' "${bump_prose}" |
    sed -nE 's/.*one coherent OpenZFS release across (.*)not a mixture.*/\1/p')"
if [[ -z "${coherence_list}" ]]; then
    _fail "the bump prompt still lists the families that must carry one release" \
        "no 'one coherent OpenZFS release across ... not a mixture' sentence"
else
    _pass "the bump prompt still lists the families that must carry one release"
    listed_families="$(printf '%s' "${coherence_list}" |
        sed -e 's/[[:space:]]and[[:space:]]/,/g' |
        tr ',' '\n' |
        sed -e 's/^[^a-z0-9]*//' -e 's/[^a-z0-9-]*$//' |
        grep -E '^[a-z0-9]' | sort -u)"
    assert_eq "that list is exactly the set build_files/zfs.sh installs" \
        "${ZFS_FAMILIES}" "${listed_families}"
fi

# --- 9. The commands' restatements are still true of their prompts -----------
#
# Each command file is a pointer, but each also repeats one rule in its own
# words. A repeated rule whose source later changes is a lie with nothing to
# catch it, so every restatement is joined back to the prompt it came from.

diagnose_cmd="$(flattened_prose "${CMD_DIR}/diagnose-build.md")"
diagnose_prose="$(flattened_prose "${DIAGNOSE}")"

assert_contains "diagnose-build.md still restates the --state all rule" \
    "${diagnose_cmd}" '--state all'
assert_contains "diagnose-build.md's --state all restatement matches the prompt" \
    "${diagnose_prose}" '--state all is load-bearing'

assert_contains "diagnose-build.md still restates the do-not-loosen rule" \
    "${diagnose_cmd}" 'loosens the kmod-zfs glob or makes its install non-fatal'
assert_contains "the prompt still carries the rule diagnose-build.md restates" \
    "${diagnose_prose}" 'Do not loosen the kmod-zfs glob'

# "Run the two-label comparison before reading any logs" is an ordering claim
# about the prompt, so check the order rather than the presence.
label_line="$(line_of "${DIAGNOSE}" 'ostree.linux')"
log_line="$(line_of "${DIAGNOSE}" 'log-failed')"
if [[ -z "${label_line}" || -z "${log_line}" ]]; then
    _fail "the prompt has both a label comparison and a log read" \
        "labels at line '${label_line}', logs at line '${log_line}'"
elif [[ "${label_line}" -lt "${log_line}" ]]; then
    _pass "the prompt puts the two-label comparison before any log reading"
else
    _fail "the prompt puts the two-label comparison before any log reading" \
        "labels at line ${label_line}, logs at line ${log_line}"
fi

pin_cmd="$(flattened_prose "${CMD_DIR}/pin-akmods.md")"
pin_prose="$(flattened_prose "${PIN}")"
assert_contains "pin-akmods.md still restates the both-lines rule" \
    "${pin_cmd}" 'both FROM lines move together'
assert_contains "the prompt still carries the both-lines rule" \
    "${pin_prose}" 'Pin both inputs or neither'
assert_contains "pin-akmods.md still restates the identical-labels precondition" \
    "${pin_cmd}" 'ostree.linux labels must be confirmed identical'
assert_contains "the prompt still requires the labels to match" \
    "${pin_prose}" 'ostree.linux labels must still match'

inputs_cmd="$(flattened_prose "${CMD_DIR}/check-inputs.md")"
bump_prose_only="$(flattened_prose "${BUMP}")"
assert_contains "check-inputs.md still restates that FEDORA_VERSION changes last" \
    "${inputs_cmd}" 'ARG FEDORA_VERSION changes last'
assert_contains "the prompt still puts FEDORA_VERSION last" \
    "${bump_prose_only}" 'ARG FEDORA_VERSION is the last step'
assert_contains "check-inputs.md sends the reader to the same procedure the prompt does" \
    "${inputs_cmd}" 'docs/manual-input-check.md'
assert_contains "the prompt names that procedure too" \
    "${bump_prose_only}" 'docs/manual-input-check.md'

finish
