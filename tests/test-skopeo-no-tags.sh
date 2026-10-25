#!/usr/bin/env bash
#
# Asserts that every `skopeo inspect` CI runs skips the repository tag list.
#
# Without `--no-tags` (or `--raw`, which prints only the manifest), skopeo
# reads the image's manifest and then makes a second request for the
# repository's whole tag list, which it reports as `RepoTags`. Nothing in this
# repository reads `RepoTags`. This package holds hundreds of versions, so the
# list is the largest read and the least needed, and it can fail on its own: a
# quay.io 503 on the tag list alone turned a nightly check red in
# zfs-kinoite-complex (its #495 and #497). Issue #435 added the flag to every
# site here and asked for this check, so a new copy fails where it is written
# instead of on the night a registry has an outage.
#
# Scope is what CI and the image build run: .github/workflows/,
# .github/actions/, ci/ and build_files/. Human-run snippets in docs, prompts
# and issue templates are left out, as are the tests, whose skopeo is a stub.
#
# Commands are read as logical lines, with each backslash-newline joined first,
# because several sites wrap their flags across lines. Each `skopeo inspect` is
# read up to the end of its own command (the next `|`, `;`, `&` or `)`), so a
# `jq --raw-output` after a pipe does not count as `--raw`. Comment lines are
# skipped.

set -uo pipefail

TEST_NAME="test-skopeo-no-tags"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

INSPECT_RE='(^|[^[:alnum:]_-])skopeo[[:space:]]+inspect([[:space:]]|$)'
FLAG_RE='(^|[[:space:]])--(no-tags|raw)([[:space:]=]|$)'

# logical_lines <file> — print "<file>:<first line>:<text>" for each logical
# line, with backslash-newline continuations joined.
logical_lines() {
    awk '
        buf == "" { start = FNR }
        /\\$/ { buf = buf substr($0, 1, length($0) - 1) " "; next }
        { print FILENAME ":" start ":" buf $0; buf = "" }
        END { if (buf != "") print FILENAME ":" start ":" buf }
    ' "$1"
}

# inspect_sites <file>... — print "<file>:<line>:<ok|missing>:<command>" for
# every `skopeo inspect` outside a comment line.
inspect_sites() {
    local file entry where text rest command
    for file in "$@"; do
        while IFS= read -r entry; do
            # Tracked paths here carry no colon, so the first two fields are
            # the file and the line, and the rest is the command text.
            text=${entry#*:*:}
            where=${entry%":${text}"}
            [[ "${text}" =~ ^[[:space:]]*# ]] && continue
            rest=${text}
            while [[ "${rest}" =~ ${INSPECT_RE} ]]; do
                rest=${rest#*"${BASH_REMATCH[0]}"}
                command=${rest%%[|;&)]*}
                if [[ " ${command}" =~ ${FLAG_RE} ]]; then
                    printf '%s:ok:skopeo inspect %s\n' "${where}" "${command}"
                else
                    printf '%s:missing:skopeo inspect %s\n' "${where}" "${command}"
                fi
            done
        done < <(logical_lines "${file}")
    done
}

# --- the detector against known answers ------------------------------------

FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "${FIXTURE_DIR}"' EXIT

cat >"${FIXTURE_DIR}/fixture.yml" <<'EOF'
        run: |
          # skopeo inspect in a comment is not a call
          actual=$(skopeo inspect --format '{{.Digest}}' \
                     --authfile "${AUTH_FILE}" \
                     "docker://${IMAGE_REF}:${tag}")
          raw=$(skopeo inspect --authfile "${AUTH_FILE}" \
                  --no-tags "docker://${IMAGE_REF}:latest")
          skopeo inspect --raw "docker://${IMAGE_REF}" | jq -r .config.digest
          skopeo inspect "docker://${IMAGE_REF}" | jq --raw-output .Digest
          skopeo inspect --no-tags "docker://a" && skopeo inspect "docker://b"
          echo "two skopeo inspects against a registry"
EOF
FIXTURE_SITES=$(inspect_sites "${FIXTURE_DIR}/fixture.yml" | cut -d: -f2,3)
assert_eq "the detector finds each call, at the line it starts on, with the right verdict" \
    "$(printf '%s\n' 3:missing 6:ok 8:ok 9:missing 10:ok 10:missing)" "${FIXTURE_SITES}"

# --- the tree ----------------------------------------------------------------

mapfile -t SCANNED < <(
    cd "${REPO_ROOT}" &&
        git ls-files -- .github/workflows .github/actions ci build_files |
        sed "s|^|${REPO_ROOT}/|"
)
SITES=$(inspect_sites "${SCANNED[@]}")

# A scan that finds nothing passes everything, so the sites issue #435 listed
# must still be seen. A file dropping out of this list because its call was
# removed is fine; delete its entry here when that happens.
for expected in .github/workflows/build.yml .github/workflows/nightly-compliance.yml \
    ci/boot-test.sh ci/write-badges.sh; do
    assert_contains "the scan still sees the skopeo inspect in ${expected}" \
        "${SITES}" "${REPO_ROOT}/${expected}:"
done

MISSING=$(grep ':missing:' <<<"${SITES}" | sed "s|^${REPO_ROOT}/||")
if [[ -z "${MISSING}" ]]; then
    _pass "every skopeo inspect CI runs passes --no-tags or --raw"
else
    _fail "every skopeo inspect CI runs passes --no-tags or --raw" \
        "add --no-tags; nothing here reads RepoTags (issue #435):" \
        "${MISSING}"
fi

finish
