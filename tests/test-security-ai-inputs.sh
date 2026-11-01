#!/usr/bin/env bash
#
# Joins the upstream-labels row of docs/SECURITY-AI.md's "Inputs to treat as
# untrusted" table to the code in the tree that reads image labels.
#
# The row is where a reader learns which code consumes the labels an upstream
# account controls. It named ci/write-badges.sh as the one that parses them and
# said nothing else did. write-badges.sh reads only the two akmods images'
# `ostree.linux`; the Aurora image's labels reach the image this repository signs
# through build.yml's rechunk step, which hands Chunkah the built image's
# inherited `.Config`. Nothing read the section, so docs/section-map.txt marked
# it `prose: unchecked:`.
#
# The readers are found in the tree rather than listed here, so code that starts
# reading labels has to be classified below, and named on the page if what it
# reads comes from upstream, before this passes:
#
#   1. the section and the one upstream-labels row are present;
#   2. every file under ci/ and .github/workflows/ that reads `.Labels` or
#      `.Config` outside a comment is in READERS, and every READERS entry still
#      reads one;
#   3. each upstream reader is named in the row, and each own-image reader is
#      not;
#   4. write-badges.sh reads `ostree.linux`, and only from the Containerfile's
#      akmods and akmods-zfs stages, which the row says;
#   5. the rechunk step hands Chunkah the built image's `.Config`, the image is
#      built on the Aurora stage, and the step drops labels by name, which the
#      row says.
#
# Markdown wraps nothing inside a table row, but runs of spaces are squashed
# before matching all the same.

# The awk programs and the needles below are single-quoted so that `$0`, `${{`
# and `${source_image}` reach them rather than the shell. SC2016 is off for the
# file rather than repeated.
# shellcheck disable=SC2016

set -uo pipefail

TEST_NAME="test-security-ai-inputs"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

SECURITY_MD="${REPO_ROOT}/docs/SECURITY-AI.md"
WRITE_BADGES="${REPO_ROOT}/ci/write-badges.sh"
BUILD_YML="${REPO_ROOT}/.github/workflows/build.yml"
CONTAINERFILE="${REPO_ROOT}/Containerfile"
HEADING="## Inputs to treat as untrusted"
RECHUNK_STEP="Rechunk Image with Chunkah"

for required in "${SECURITY_MD}" "${WRITE_BADGES}" "${BUILD_YML}" "${CONTAINERFILE}"; do
    assert_file_exists "${required#"${REPO_ROOT}/"} is present" "${required}"
done

# Every file that reads image labels, and where the image it reads them from
# comes from. `upstream` readers must be named in the row; `own` readers read
# an image this repository built, and the reason says why that is not upstream.
declare -A READERS=(
    ["ci/write-badges.sh"]="upstream"
    [".github/workflows/build.yml"]="upstream"
    ["ci/boot-test.sh"]="own: reads org.opencontainers.image.revision off the published image it boots, which build.yml's Image Metadata step sets"
)

# --- 1. the row --------------------------------------------------------------

SECTION="$(awk -v heading="${HEADING}" '
    $0 == heading { inside = 1; next }
    inside && /^## / { exit }
    inside { print }
' "${SECURITY_MD}")"
assert_contains "docs/SECURITY-AI.md still has the section" "${SECTION:+present}" "present"

ROWS="$(grep -E '^\| `ostree\.linux`' <<<"${SECTION}")"
assert_eq "the section has one row for the upstream image labels" "1" "$(grep -c . <<<"${ROWS}")"
ROW="$(sed -E 's/[[:space:]]+/ /g' <<<"${ROWS}")"
assert_contains "the row still covers the akmods and Aurora images' labels" \
    "${ROW}" '| `ostree.linux` and other labels on the upstream akmods and Aurora images |'
assert_contains "and still says they are data" "${ROW}" "are data, never commands."

# --- 2. the readers in the tree ----------------------------------------------

mapfile -t FOUND < <(
    cd "${REPO_ROOT}" &&
        git ls-files -- 'ci/*' '.github/workflows/*' |
        while IFS= read -r file; do
            if grep -v '^[[:space:]]*#' "${file}" | grep -qE '\.(Labels|Config)\b'; then
                printf '%s\n' "${file}"
            fi
        done | LC_ALL=C sort
)
assert_eq "the label readers in the tree are the ones classified here" \
    "$(printf '%s\n' "${!READERS[@]}" | LC_ALL=C sort)" "$(printf '%s\n' "${FOUND[@]}")"

# A scan that finds nothing passes everything above against an empty table.
for expected in ci/write-badges.sh .github/workflows/build.yml; do
    assert_contains "the scan still finds ${expected}" "$(printf '%s\n' "${FOUND[@]}")" "${expected}"
done

# --- 3. who the row names ----------------------------------------------------

# A workflow is named the way the page names workflows, by its file name.
page_name() {
    case "$1" in
        .github/workflows/*) printf '%s' "${1#.github/workflows/}" ;;
        *) printf '%s' "$1" ;;
    esac
}

for reader in "${!READERS[@]}"; do
    named="$(page_name "${reader}")"
    if [[ "${READERS[${reader}]}" == upstream ]]; then
        assert_contains "the row names ${named}, which reads upstream labels" "${ROW}" "\`${named}\`"
    else
        assert_not_contains "the row does not name ${named}, which reads only this repository's image" \
            "${ROW}" "\`${named}\`"
    fi
done

mapfile -t ROW_PATHS < <(grep -oE '`[^` ]+\.(sh|yml)`' <<<"${ROW}" | tr -d '`' | sort -u)
for path in "${ROW_PATHS[@]}"; do
    known=""
    for reader in "${!READERS[@]}"; do
        if [[ "$(page_name "${reader}")" == "${path}" ]]; then
            known="${reader}"
        fi
    done
    assert_contains "the row's ${path} is a label reader found above" "${known:+found}" "found"
done

# --- 4. ci/write-badges.sh ---------------------------------------------------

badges_code="$(grep -v '^[[:space:]]*#' "${WRITE_BADGES}")"
assert_eq "write-badges.sh reads exactly one label, ostree.linux" 'Labels["ostree.linux"]' \
    "$(grep -oE 'Labels\["[^"]+"\]' <<<"${badges_code}" | sort -u)"
# from_ref is how the script turns a Containerfile stage into the reference it
# inspects; its own definition is not a call.
assert_eq "and inspects only the Containerfile's akmods and akmods-zfs stages" \
    $'akmods\nakmods-zfs' \
    "$(grep -oE 'from_ref [a-z-]+' <<<"${badges_code}" | awk '{print $2}' | LC_ALL=C sort -u)"
for stage in akmods akmods-zfs; do
    assert_eq "the Containerfile's ${stage} stage is a ghcr.io/ublue-os/${stage} image" "1" \
        "$(grep -cE "^FROM ghcr\\.io/ublue-os/${stage}:[^[:space:]]+ AS ${stage}\$" "${CONTAINERFILE}")"
done
assert_contains "the row says write-badges.sh parses the akmods images' ostree.linux" \
    "${ROW}" "\`ci/write-badges.sh\` parses the two akmods images' \`ostree.linux\` labels"

# --- 5. build.yml's rechunk step ---------------------------------------------

rechunk="$(awk -v name="      - name: ${RECHUNK_STEP}" '
    $0 == name { inside = 1; print; next }
    inside && /^      - name: / { exit }
    inside
' "${BUILD_YML}" | grep -v '^[[:space:]]*#')"
assert_contains "build.yml still has the ${RECHUNK_STEP} step" "${rechunk:+present}" "present"
assert_contains "the step reads the built image's .Config" "${rechunk}" \
    'CHUNKAH_CONFIG_STR="$(podman inspect --format '"'"'{{json .Config}}'"'"' "${source_image}")"'
assert_contains "and hands it to Chunkah" "${rechunk}" "-e CHUNKAH_CONFIG_STR"
assert_contains "the image it reads is the local build of IMAGE_NAME" "${rechunk}" \
    'source_image="localhost/${IMAGE_NAME}:${DEFAULT_TAG}"'
assert_contains "and the step drops labels by name" "${rechunk}" "--label io.artifacthub.package.logo-url-"

# The built image's labels are Aurora's because its last stage is built on the
# Aurora image: the stage that names it is the last FROM.
assert_eq "the Containerfile's last stage is built on the Aurora image" \
    'FROM ${AURORA_IMAGE}:${AURORA_TAG} AS base' "$(grep -E '^FROM ' "${CONTAINERFILE}" | tail -1)"
assert_eq "which defaults to ghcr.io/ublue-os/aurora-dx" "1" \
    "$(grep -cE '^ARG AURORA_IMAGE=ghcr\.io/ublue-os/aurora-dx$' "${CONTAINERFILE}")"
assert_contains "the row names the step and says it carries the Aurora image's labels" "${ROW}" \
    "the \`${RECHUNK_STEP}\` step of \`build.yml\` carries the Aurora image's labels onto the image this repository signs and publishes, apart from the ones it drops by name"

finish
