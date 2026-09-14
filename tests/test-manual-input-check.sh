#!/usr/bin/env bash
#
# Joins docs/manual-input-check.md to the machine it describes.
#
# That document is the whole procedure for the highest-risk change this repo
# makes: moving `ARG FEDORA_VERSION` to a new Fedora major. It deliberately
# ships no script -- "This repo intentionally does not include scripts or local
# build helpers for checking upstream inputs" -- so the commands a human runs
# before the bump exist only as prose, and prose is the one artifact in this
# tree that nothing verifies. tests/test-docs-paths.sh resolves the links
# between documents and tests/test-coverage.sh cannot see Markdown at all, so
# before this file every literal in it -- the artifact image references, the tag
# template, the paths copied out of the artifacts, the RPM names that have to
# agree, the `rpm --qf` query, the `ARG` values -- was unchecked.
#
# Each of those literals is a copy of something that lives in the Containerfile
# or build_files/post-check.sh. A copy drifts silently: renaming a build stage,
# re-tagging the akmods artifacts, adding a package to check_zfs_packages, or
# bumping FEDORA_VERSION all leave this document describing the previous repo,
# and the reader following it is checking the wrong inputs against the wrong
# image before making the one change the document exists to gate.
#
# So nothing here is typed in twice. Every expectation is computed from the
# Containerfile or from post-check.sh and compared with what the document says,
# which means editing one side without the other is a red suite rather than a
# reader's problem. The extractions fail loudly when they match nothing: a
# renamed heading or a deleted fenced block must fail, not silently verify an
# empty set.
#
# Scope: the claims that name something in this repo. Prose about what Universal
# Blue publishes, and the judgement calls the document asks a human to make, are
# not checkable here and are left alone.

set -uo pipefail

TEST_NAME="test-manual-input-check"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

DOC="${REPO_ROOT}/docs/manual-input-check.md"
CONTAINERFILE="${REPO_ROOT}/Containerfile"
POST_CHECK="${REPO_ROOT}/build_files/post-check.sh"

assert_file_exists "docs/manual-input-check.md is present" "${DOC}"
assert_file_exists "Containerfile is present" "${CONTAINERFILE}"
assert_file_exists "build_files/post-check.sh is present" "${POST_CHECK}"

if [[ ! -f "${DOC}" || ! -f "${CONTAINERFILE}" || ! -f "${POST_CHECK}" ]]; then
    finish
    exit
fi

# --- extraction helpers -----------------------------------------------------

# The bodies of the fenced blocks with a given info string inside one `##`
# section, concatenated. Scoping to a section rather than counting blocks from
# the top of the file keeps the test anchored to what the document says where,
# so adding an example elsewhere does not shift every expectation by one.
blocks_in_section() {
    local file=$1 heading=$2 lang=$3
    awk -v heading="${heading}" -v lang="${lang}" '
        $0 == heading  { in_section = 1; next }
        /^## /         { in_section = 0 }
        !in_section    { next }
        /^(```|~~~)/ {
            if (in_block) {
                in_block = 0
                emit = 0
            } else {
                info = $0
                sub(/^(```|~~~)/, "", info)
                gsub(/[[:space:]]/, "", info)
                in_block = 1
                emit = (info == lang)
            }
            next
        }
        emit
    ' "${file}"
}

# A fenced block that matched nothing is not a passing check, it is an
# unverified document. Every extraction goes through here.
require_block() {
    local description=$1 content=$2
    if [[ -n "${content//[[:space:]]/}" ]]; then
        _pass "the document still has ${description}"
        return 0
    fi
    _fail "the document still has ${description}" \
        "no such fenced block was found, so the checks over it verify nothing"
    return 1
}

# `ARG NAME=value` from the Containerfile, first declaration wins.
arg_value() {
    sed -nE "s/^ARG $1=(.*)\$/\1/p" "${CONTAINERFILE}" | head -1
}

# The image reference of a build stage, with the shell quoting the Containerfile
# uses around "${FEDORA_VERSION}" removed.
stage_ref() {
    sed -nE "s/^FROM (.+) AS $1\$/\1/p" "${CONTAINERFILE}" | head -1 | tr -d '"'
}

# The code spans on one line of prose.
code_spans() {
    # SC2016: the backticks delimit Markdown code spans, not a command
    # substitution, so they stay literal.
    # shellcheck disable=SC2016
    grep -oE '`[^`]+`' <<<"$1" | tr -d '`'
}

FEDORA_VERSION="$(arg_value FEDORA_VERSION)"
AURORA_IMAGE="$(arg_value AURORA_IMAGE)"
AURORA_TAG="$(arg_value AURORA_TAG)"

if [[ ! "${FEDORA_VERSION}" =~ ^[0-9]+$ ]]; then
    _fail "the Containerfile declares a numeric ARG FEDORA_VERSION" \
        "read: ${FEDORA_VERSION:-<nothing>}"
    finish
    exit
fi
_pass "the Containerfile declares a numeric ARG FEDORA_VERSION"

AKMODS_REF="$(stage_ref akmods)"
AKMODS_ZFS_REF="$(stage_ref akmods-zfs)"
BASE_REF="$(stage_ref base)"
BASE_REF="${BASE_REF//\$\{AURORA_IMAGE\}/${AURORA_IMAGE}}"
BASE_REF="${BASE_REF//\$\{AURORA_TAG\}/${AURORA_TAG}}"

for ref_name in AKMODS_REF AKMODS_ZFS_REF BASE_REF; do
    if [[ -z "${!ref_name}" ]]; then
        _fail "the Containerfile still names the ${ref_name} build stage" \
            "no FROM ... AS stage line produced a reference"
        finish
        exit
    fi
done
_pass "the Containerfile still names the akmods, akmods-zfs and base stages"

# The three references with ${FEDORA_VERSION} resolved to a given release.
refs_for_release() {
    local release=$1
    printf '%s\n%s\n%s\n' \
        "${BASE_REF}" \
        "${AKMODS_REF//\$\{FEDORA_VERSION\}/${release}}" \
        "${AKMODS_ZFS_REF//\$\{FEDORA_VERSION\}/${release}}" | sort
}

# --- 1. "What Must Match" lists the images the build actually pulls ----------
#
# The document writes the release as a literal `N`. Substituting N into the
# Containerfile's own FROM lines is what makes this a join rather than a second
# copy of the same three strings: re-tag an artifact, rename an image, or point
# the base at aurora-dx-nvidia, and the expectation moves with it.

must_match="$(blocks_in_section "${DOC}" '## What Must Match' 'text')"
if require_block 'a "What Must Match" image block' "${must_match}"; then
    documented="$(grep -v '^[[:space:]]*$' <<<"${must_match}" | sort)"
    assert_eq "the documented inputs are the images the Containerfile pulls" \
        "$(refs_for_release N)" "${documented}"
fi

# --- 2. the tag template the reader exports ---------------------------------

how_to="$(blocks_in_section "${DOC}" '## How To Check The Inputs' 'bash')"
if require_block 'the "How To Check The Inputs" commands' "${how_to}"; then
    documented_tag="$(sed -nE 's/^AKMODS_TAG="([^"]+)".*/\1/p' <<<"${how_to}" | head -1)"
    assert_eq "AKMODS_TAG matches the tag the Containerfile pulls" \
        "${AKMODS_REF#*:}" "${documented_tag}"

    # Both artifact images are inspected, under that tag, by their real names.
    # SC2016: ${AKMODS_TAG} is the literal text the document writes, not a
    # variable this test expands.
    # shellcheck disable=SC2016
    expected_inspects="$(printf 'docker://%s:${AKMODS_TAG}\ndocker://%s:${AKMODS_TAG}\n' \
        "${AKMODS_REF%%:*}" "${AKMODS_ZFS_REF%%:*}" | sort)"
    actual_inspects="$(grep -oE 'docker://[^"]+' <<<"${how_to}" | sort)"
    assert_eq "the skopeo inspects name both artifact images the build uses" \
        "${expected_inspects}" "${actual_inspects}"

    # --- 3. the payload paths copied out of the artifacts -------------------
    #
    # A `podman cp` source is the same claim as a `--mount ... src=` in the
    # Containerfile: that this path exists inside that image. They are written
    # in two places and nothing but this joined them, so a reader could be
    # copying a directory the build no longer mounts.
    mounts="$(grep -oE -- '--mount=type=bind,from=[^,]+,src=[^, ]+' "${CONTAINERFILE}" |
        sed -E 's/.*from=([^,]+),src=(.*)/\1 \2/' | sort -u)"
    if [[ -z "${mounts}" ]]; then
        _fail "the Containerfile still bind-mounts artifact payloads" \
            "no --mount=type=bind,from=...,src=... lines found"
    else
        _pass "the Containerfile still bind-mounts artifact payloads"

        # variable prefix -> image reference, from `x_cid=$(podman create "ref")`
        declare -A cid_image=()
        while IFS=' ' read -r cid_var image; do
            [[ -z "${cid_var}" ]] && continue
            cid_image["${cid_var}"]="${image}"
        done < <(sed -nE 's/^([A-Za-z0-9_]+)=\$\(podman create "([^"]+)"\).*/\1 \2/p' <<<"${how_to}")

        copies=0
        while IFS=' ' read -r cid_var path; do
            [[ -z "${cid_var}" ]] && continue
            copies=$((copies + 1))
            image="${cid_image[${cid_var}]:-}"
            if [[ -z "${image}" ]]; then
                _fail "podman cp copies ${path} out of a container the document created" \
                    "no podman create assigned \${${cid_var}}"
                continue
            fi
            # The reference carries ${AKMODS_TAG}; the repository half is what
            # identifies the build stage.
            repo="${image%%:*}"
            case "${repo}" in
                "${AKMODS_REF%%:*}") stage="akmods" ;;
                "${AKMODS_ZFS_REF%%:*}") stage="akmods-zfs" ;;
                *)
                    _fail "podman cp reads an image the build pulls: ${repo}" \
                        "not the akmods or akmods-zfs image the Containerfile uses"
                    continue
                    ;;
            esac
            if grep -qxF "${stage} ${path}" <<<"${mounts}"; then
                _pass "the build mounts ${path} from ${stage}, as the document says to copy"
            else
                _fail "the build mounts ${path} from ${stage}, as the document says to copy" \
                    "no --mount from=${stage} with src=${path} in the Containerfile"
            fi
        done < <(sed -nE 's/^podman cp "\$\{([A-Za-z0-9_]+)\}:([^"]+)".*/\1 \2/p' <<<"${how_to}")

        if [[ "${copies}" -gt 0 ]]; then
            _pass "the document still copies ${copies} payload path(s) out of the artifacts"
        else
            _fail "the document still copies payload path(s) out of the artifacts" \
                "no podman cp lines were found, so the mount join verifies nothing"
        fi
    fi

    # --- 4. the kernel query -----------------------------------------------
    #
    # post-check.sh compares `rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n'`
    # against the directory name under /usr/lib/modules. The document tells the
    # reader to compute the kernel they expect the same way, and that value is
    # what they carry into the ZFS comparison -- a different format string there
    # produces a value that never matches what the build will check.
    kernel_tree="$(sed -n '/^check_kernel_tree()/,/^}/p' "${POST_CHECK}")"
    post_check_qf="$(sed -nE "s/.*--qf '([^']*)'.*/\1/p" <<<"${kernel_tree}" | head -1)"
    doc_qf="$(grep -oE -- '--qf "[^"]*%\{ARCH\}[^"]*"' <<<"${how_to}" |
        sed -E 's/^--qf "//; s/"$//')"
    assert_eq "exactly one documented rpm query asks for the architecture" \
        1 "$(grep -c . <<<"${doc_qf}")"
    assert_eq "the documented kernel query matches the one post-check.sh compares against" \
        "${post_check_qf}" "${doc_qf}"

    # The RPM that query reads has to be one post-check.sh requires, or the
    # reader is pinning their expectation to a package the image never checks.
    kernel_pkgs="$(sed -nE 's/^[[:space:]]{8}(kernel[a-z-]*)$/\1/p' <<<"${kernel_tree}" | sort -u)"
    doc_kernel_rpm="$(grep -oE 'kernel-rpms/[a-z0-9-]+-\*\.rpm' <<<"${how_to}" |
        sed -E 's#^kernel-rpms/##; s/-\*\.rpm$//' | sort -u)"
    if [[ -z "${doc_kernel_rpm}" ]]; then
        _fail "the document reads the kernel version out of a kernel RPM" \
            "no kernel-rpms/<name>-*.rpm glob found"
    elif grep -qxF "${doc_kernel_rpm}" <<<"${kernel_pkgs}"; then
        _pass "the kernel RPM the document reads (${doc_kernel_rpm}) is one post-check.sh requires"
    else
        _fail "the kernel RPM the document reads (${doc_kernel_rpm}) is one post-check.sh requires" \
            "check_kernel_tree requires: $(tr '\n' ' ' <<<"${kernel_pkgs}")"
    fi

    # The worked kernel example carries a Fedora release in its dist tag. Left
    # behind at a bump it tells the reader to expect the previous release.
    doc_kernel_example="$(sed -nE 's/^KERNEL="([^"]+)".*/\1/p' <<<"${how_to}" | head -1)"
    if [[ "${doc_kernel_example}" =~ \.fc([0-9]+)\. ]]; then
        assert_eq "the example kernel is built for the Fedora release this repo is on" \
            "${FEDORA_VERSION}" "${BASH_REMATCH[1]}"
    else
        _fail "the example kernel names a Fedora release" \
            "no .fcNN. in KERNEL=\"${doc_kernel_example:-<nothing>}\""
    fi
fi

# --- 5. the ZFS package set --------------------------------------------------
#
# Three lists of the same packages: the prose sentence, the glob list the reader
# is told to query, and what check_zfs_packages requires of the finished image.
# The third is the one that blocks a publish, so it is the expectation and the
# two in the document are compared against it.

zfs_packages="$(sed -n '/^check_zfs_packages()/,/^}/p' "${POST_CHECK}")"
post_check_zfs="$(
    {
        sed -nE 's/^[[:space:]]*require_rpm "([^"]+)".*/\1/p' <<<"${zfs_packages}"
        sed -nE 's/^[[:space:]]*require_rpm_glob "([^"]+)".*/\1/p' <<<"${zfs_packages}"
    } | sort -u
)"
if [[ -z "${post_check_zfs}" ]]; then
    _fail "post-check.sh still requires a set of ZFS packages" \
        "check_zfs_packages yielded no require_rpm/require_rpm_glob names"
else
    _pass "post-check.sh still requires a set of ZFS packages"

    coherent_line="$(grep -n 'one coherent OpenZFS release' "${DOC}" | head -1 | cut -d: -f1)"
    if [[ -z "${coherent_line}" ]]; then
        _fail "the document still names the packages that must agree" \
            "no 'one coherent OpenZFS release' sentence in ${DOC##*/}"
    else
        # From that phrase to the end of its paragraph: the spans before it name
        # the artifact image, not packages.
        sentence="$(sed -n "${coherent_line},/^[[:space:]]*\$/p" "${DOC}" |
            sed '1s/.*one coherent OpenZFS release//' | tr '\n' ' ')"
        documented_zfs="$(code_spans "${sentence}" | sort -u)"
        assert_eq "the packages the prose says must agree are the ones post-check.sh requires" \
            "${post_check_zfs}" "${documented_zfs}"
    fi

    if [[ -n "${how_to}" ]]; then
        # Every glob under the copied ZFS payload directory, reduced to the
        # package name it is there to match.
        queried_zfs="$(grep -oE 'zfs-rpms/[A-Za-z0-9.+-]*\*?\.rpm' <<<"${how_to}" |
            sed -E 's#^zfs-rpms/##; s/\*?\.rpm$//; s/-$//' | sort -u)"
        assert_eq "the RPM globs the reader queries cover the same package set" \
            "${post_check_zfs}" "${queried_zfs}"
    fi
fi

# --- 6. "the build's post-check.sh performs the final validation" ------------
#
# A claim about ordering: post-check.sh has to be the last build_files script
# the Containerfile runs, or something else runs after the gate that is
# described as final.

ctx_scripts="$(grep -oE '/ctx/[A-Za-z0-9._-]+\.sh' "${CONTAINERFILE}")"
if [[ -z "${ctx_scripts}" ]]; then
    _fail "the Containerfile still runs the build_files scripts" "no /ctx/*.sh invocations found"
else
    assert_eq "post-check.sh is the last build step, as the document claims" \
        "/ctx/post-check.sh" "$(tail -1 <<<"${ctx_scripts}")"
fi

# --- 7. the base image guard -------------------------------------------------

guard_block="$(blocks_in_section "${DOC}" '## Base Image Guard' 'Dockerfile')"
if require_block 'a "Base Image Guard" ARG block' "${guard_block}"; then
    while IFS= read -r line; do
        [[ -z "${line//[[:space:]]/}" ]] && continue
        if grep -qxF "${line}" "${CONTAINERFILE}"; then
            _pass "the Containerfile declares the documented default: ${line}"
        else
            _fail "the Containerfile declares the documented default: ${line}" \
                "no such line in the Containerfile"
        fi
    done <<<"${guard_block}"
fi

# The document says the build fails when the base image has moved to a
# different Fedora release. Checking that the comparison exists is not enough:
# a guard that reports the mismatch and carries on is exactly the failure this
# sentence promises does not happen.
guard_run="$(awk '
    /rpm -E %fedora/ { capture = 1 }
    capture          { print }
    capture && /exit/ { exit }
' "${CONTAINERFILE}")"
if [[ -z "${guard_run}" ]]; then
    _fail "the Containerfile compares the base image's Fedora release with FEDORA_VERSION" \
        "no rpm -E %fedora comparison found"
else
    _pass "the Containerfile compares the base image's Fedora release with FEDORA_VERSION"
    assert_contains "the guard fails the build on a mismatch" "${guard_run}" "exit 1"
    # SC2016: the needle is the Containerfile's own unexpanded text.
    # shellcheck disable=SC2016
    assert_contains "and its message names the base image it checked" \
        "${guard_run}" '${AURORA_IMAGE}:${AURORA_TAG}'
fi

# --- 8. the worked "next release" example ------------------------------------
#
# This section is an instruction, not an illustration: it tells the reader which
# tags to look for and what to write in the Containerfile when they line up. Its
# numbers have to be this repo's current release and the one after it, or the
# reader checks inputs for a release that already shipped here.

# SC2016: the backticks are the document's Markdown code span, matched literally.
# shellcheck disable=SC2016
NEXT_HEADING='## When Fedora `N+1` Is Released'
next_args="$(blocks_in_section "${DOC}" "${NEXT_HEADING}" 'Dockerfile')"
next_refs="$(blocks_in_section "${DOC}" "${NEXT_HEADING}" 'text')"

documented_next=""
if require_block 'a "When Fedora N+1 Is Released" ARG block' "${next_args}"; then
    documented_next="$(sed -nE 's/^ARG FEDORA_VERSION=([0-9]+).*/\1/p' <<<"${next_args}" | head -1)"
    if [[ -z "${documented_next}" ]]; then
        _fail "the example bump sets ARG FEDORA_VERSION to a release number" \
            "read: $(tr '\n' ' ' <<<"${next_args}")"
    else
        assert_eq "the example bump moves to the release after the one this repo is on" \
            "$((FEDORA_VERSION + 1))" "${documented_next}"
    fi
fi

if require_block 'a "When Fedora N+1 Is Released" tag block' "${next_refs}"; then
    if [[ -n "${documented_next}" ]]; then
        # The same three-reference shape as "What Must Match", minus the base
        # image, which does not move with the release.
        expected_next="$(refs_for_release "${documented_next}" | grep -vxF "${BASE_REF}")"
        assert_eq "the tags to look for are the artifact images at that release" \
            "${expected_next}" "$(grep -v '^[[:space:]]*$' <<<"${next_refs}" | sort)"
    fi
fi

# The prose that introduces those tags names the same pair of releases.
# Joined to one line first: the sentence is wrapped, and which word the wrap
# falls on is not something this test should have an opinion about.
example_move="$(tr '\n' ' ' <"${DOC}" |
    sed -nE 's/.*before moving from Fedora ([0-9]+) to Fedora ([0-9]+).*/\1 \2/p' | head -1)"
if [[ -z "${example_move}" ]]; then
    _fail "the document still walks through a named release move" \
        "no 'before moving from Fedora N to Fedora N+1' sentence"
else
    assert_eq "the worked move starts at the release this repo is on and ends at the example bump" \
        "${FEDORA_VERSION} ${documented_next}" "${example_move}"
fi

finish
