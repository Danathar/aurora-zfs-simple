#!/usr/bin/env bash
#
# Joins the three quality documents to the machine they describe.
#
# docs/quality.md, docs/metrics.md and docs/review-rubric.md are the documents a
# reader is pointed at to answer "what does this repo actually verify", "what do
# the badges mean" and "what should a review here reject". Every one of their
# claims is a hand copy of something that lives in build.yml, the Containerfile,
# ci/write-badges.sh or tests/test-coverage.sh, and before this file no test
# opened any of them: `grep -rl` over tests/ returned nothing for
# review-rubric.md and metrics.md, and the single hit for quality.md was a
# comment in tests/test-nightly-compliance.sh. The two directory-wide scans read
# their bytes -- tests/test-docs-paths.sh resolves path-shaped code spans and
# Markdown links in every tracked *.md, tests/test-shell-syntax.sh selects by
# suffix -- and neither reads a claim.
#
# That matters more here than "docs can rot".
# docs/reflections/2026-09-03-prose-an-agent-is-told-to-trust.md is this repo's
# own finding that prose named as a source of truth for a reader who does not
# know the tree is an input to incident response, not decoration. These three
# documents are exactly that: a badge table that tells a reader a red build is
# survivable, a gate table that tells them what a green suite proves, and a
# rubric that tells a reviewer what to reject on sight.
#
# So nothing here is typed in twice where it can be computed. The expectations
# are read out of the workflow, the Containerfile, the badge script and the
# coverage manifest and compared with what the documents say, which means
# editing one side without the other is a red suite rather than a reader's
# problem. Extractions that match nothing fail loudly: a renamed heading or a
# deleted table must fail, not silently verify an empty set. `require_claim`
# holds the sentences the joins below hang off, so deleting the claim fails
# instead of quietly turning its assertion into a no-op.
#
# The prose names its relationships precisely enough to join them too. The
# source and destination documents in review-rubric.md are read from the claim
# before their link is checked; the scripts quality.md calls unreachable are
# compared with the manifest's UNCOVERED set; and metrics.md must point at the
# file that actually holds that manifest. The dated snapshots under
# docs/metrics/ are read as well: each must be linked from metrics.md, and each
# command in it must parse, name this repository and be pinned to the scope its
# numbers were read over.

set -uo pipefail

TEST_NAME="test-quality-docs"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

QUALITY_DOC="${REPO_ROOT}/docs/quality.md"
METRICS_DOC="${REPO_ROOT}/docs/metrics.md"
RUBRIC_DOC="${REPO_ROOT}/docs/review-rubric.md"
BUILD_WF="${REPO_ROOT}/.github/workflows/build.yml"
BADGES_WF="${REPO_ROOT}/.github/workflows/status-badges.yml"
COVERAGE_WF="${REPO_ROOT}/.github/workflows/coverage-gate.yml"
CONTAINERFILE="${REPO_ROOT}/Containerfile"
BADGE_SCRIPT="${REPO_ROOT}/ci/write-badges.sh"
COVERAGE_TEST="${REPO_ROOT}/tests/test-coverage.sh"
SYNTAX_TEST="${REPO_ROOT}/tests/test-shell-syntax.sh"
TESTS_README="${REPO_ROOT}/tests/README.md"
AGENTS_DOC="${REPO_ROOT}/AGENTS.md"
README="${REPO_ROOT}/README.md"

missing=0
for required in \
    "${QUALITY_DOC}" "${METRICS_DOC}" "${RUBRIC_DOC}" "${BUILD_WF}" \
    "${BADGES_WF}" "${COVERAGE_WF}" "${CONTAINERFILE}" "${BADGE_SCRIPT}" \
    "${COVERAGE_TEST}" "${SYNTAX_TEST}" "${TESTS_README}" "${AGENTS_DOC}" \
    "${README}"; do
    if [[ -f "${required}" ]]; then
        continue
    fi
    _fail "${required#"${REPO_ROOT}"/} is present" "no such file"
    missing=1
done

if [[ "${missing}" -ne 0 ]]; then
    finish
    exit
fi

# --- extraction helpers -----------------------------------------------------

# The body of one `##` section, verbatim, fences included. Scoping to a section
# rather than counting tables from the top of the file keeps each expectation
# anchored to what the document says where.
doc_section() {
    local file=$1 heading=$2
    awk -v heading="${heading}" '
        $0 == heading { in_section = 1; next }
        /^## /        { in_section = 0 }
        in_section
    ' "${file}"
}

# The data rows of the first Markdown table in a chunk of text: leading `|`,
# minus the header row and minus the `|---|` separator.
table_rows() {
    awk '
        /^\|/ {
            if ($0 ~ /^\|[[:space:]:|-]+\|[[:space:]:|-]*$/) { seen_rule = 1; next }
            if (seen_rule) { print }
            next
        }
        seen_rule && NF == 0 { seen_rule = 0 }
    '
}

# One cell of a `| a | b | c |` row, 1-indexed, trimmed, verbatim. `raw_cell` is
# what the code-span reader needs; `cell` strips the Markdown emphasis and
# code-span markers that carry no meaning when the cell is read as a name.
raw_cell() {
    local row=$1 index=$2 value
    value="$(awk -F'|' -v n="${index}" '{ print $(n + 1) }' <<<"${row}")"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

cell() {
    local row=$1 index=$2 value
    value="$(raw_cell "${row}" "${index}")"
    value="${value//\*/}"
    value="${value//\`/}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

# The code spans on a line of prose.
code_spans() {
    # SC2016: the backticks delimit Markdown code spans, not a command
    # substitution, so they stay literal.
    # shellcheck disable=SC2016
    grep -oE '`[^`]+`' <<<"$1" | tr -d '`'
}

# The bodies of the fenced blocks with a given info string, concatenated with a
# blank line between them so each stays a separate compound command.
fenced_blocks() {
    local file=$1 lang=$2
    awk -v lang="${lang}" '
        /^(```|~~~)/ {
            if (in_block) { in_block = 0; if (emit) print ""; emit = 0; next }
            info = $0
            sub(/^(```|~~~)/, "", info)
            gsub(/[[:space:]]/, "", info)
            in_block = 1
            emit = (info == lang)
            next
        }
        emit
    ' "${file}"
}

# A claim this file goes on to verify has to still be in the document. Without
# this every join below degrades to a check on the tree alone the moment the
# sentence it came from is deleted.
require_claim() {
    local file=$1 description=$2 needle=$3 flattened
    # Prose wraps, so the sentence being looked for is matched against the
    # document with its line breaks collapsed. A claim that has to be searched
    # for at one particular wrap point is a claim a reflow can silently delete.
    flattened="$(tr '\n' ' ' <"${file}" | tr -s '[:space:]' ' ')"
    if [[ "${flattened}" == *"${needle}"* ]]; then
        _pass "${file#"${REPO_ROOT}"/} still claims ${description}"
        return 0
    fi
    _fail "${file#"${REPO_ROOT}"/} still claims ${description}" \
        "the sentence this test verifies is gone: ${needle}" \
        "either restore it or drop the assertions that depend on it"
    return 1
}

# An extraction that matched nothing is not a passing check, it is an unverified
# document.
require_nonempty() {
    local description=$1 content=$2
    if [[ -n "${content//[[:space:]]/}" ]]; then
        _pass "the document still has ${description}"
        return 0
    fi
    _fail "the document still has ${description}" \
        "nothing was extracted, so the checks over it verify nothing"
    return 1
}

# The line number of a workflow step, by display name. Steps are the unit the
# documents talk about, and their order is load-bearing: "before the rechunk"
# and "fail before signing" are both claims about which line comes first.
step_line() {
    local file=$1 name=$2
    grep -nF -- "- name: ${name}" "${file}" | head -1 | cut -d: -f1
}

# The single-letter options and the long words of a `set -...` line, as a sorted
# list. `set -eoux pipefail` and `set -euo pipefail` differ only in `x`, and a
# claim about `set -euo pipefail` is a claim about the options, not the spelling.
set_options() {
    local file=$1 line letters=() words=()
    line="$(grep -m1 -E '^set -' "${file}")"
    [[ -z "${line}" ]] && return 0
    local token first rest index
    for token in ${line#set }; do
        first="${token:0:1}"
        if [[ "${first}" == "-" ]]; then
            rest="${token:1}"
            for ((index = 0; index < ${#rest}; index++)); do
                letters+=("${rest:index:1}")
            done
        else
            words+=("${token}")
        fi
    done
    printf '%s\n' "${letters[@]}" "${words[@]}" | LC_ALL=C sort | tr '\n' ' '
}

# --- helper case tables -----------------------------------------------------
#
# Every assertion below is only as good as these three extractors, so each gets
# its own table first. An extractor that silently mis-parses turns a join into a
# comparison of two empty strings.

HELPER_TABLE_INPUT="| Badge | Source |
| ----- | ------ |
| **build** | \`build.yml\` |
| **last good build** | the image |
"
assert_eq "table_rows drops the header and the separator" \
    "2" "$(table_rows <<<"${HELPER_TABLE_INPUT}" | grep -c '^|')"
# SC2016 here and below: the single quotes hold Markdown and shell text this
# test looks for literally, not expressions it wants expanded.
# shellcheck disable=SC2016
assert_eq "cell trims, and drops emphasis and code spans" \
    "build" "$(cell '| **build** | `build.yml` |' 1)"
# shellcheck disable=SC2016
assert_eq "cell reads the second column" \
    "build.yml" "$(cell '| **build** | `build.yml` |' 2)"
# shellcheck disable=SC2016
assert_eq "code_spans returns each span on the line" \
    "a b" "$(code_spans 'text `a` and `b` here' | tr '\n' ' ' | sed 's/ $//')"
assert_eq "set_options sorts the letters and the words together" \
    "e o pipefail u " "$(set_options <(printf '#!/usr/bin/env bash\nset -euo pipefail\n'))"
assert_eq "set_options reads a differently spelled cluster the same way" \
    "e o pipefail u x " "$(set_options <(printf '#!/usr/bin/env bash\nset -eoux pipefail\n'))"

BUILD_TEXT="$(cat "${BUILD_WF}")"
BADGE_TEXT="$(cat "${BADGE_SCRIPT}")"

# =============================================================================
# docs/quality.md -- the badges
# =============================================================================

BADGE_SECTION="$(doc_section "${QUALITY_DOC}" "## The badges")"
BADGE_ROWS="$(table_rows <<<"${BADGE_SECTION}")"
require_nonempty "a badge table under '## The badges'" "${BADGE_ROWS}"

assert_eq "the badge table still describes three badges" \
    "3" "$(grep -c '^|' <<<"${BADGE_ROWS}")"

badge_names=""
while IFS= read -r row; do
    [[ -z "${row}" ]] && continue
    badge_names+="$(cell "${row}" 1)|"
done <<<"${BADGE_ROWS}"
assert_eq "the three badges are the three the README carries" \
    "build|last good build|OpenZFS/kernel|" "${badge_names}"

# Badge 1: "Actions status for build.yml on main". The README is where that
# badge is rendered, so the claim is about a URL that exists there.
assert_contains "the README renders the build badge for build.yml on main" \
    "$(grep -F 'actions/workflows/build.yml/badge.svg' "${README}")" \
    "branch=main"

# Badge 2: "Created timestamp on the published :latest image". ci/write-badges.sh
# is what reads it, and it reads the JSON field rather than a Go template.
assert_contains "write-badges.sh reads the Created field for the age badge" \
    "${BADGE_TEXT}" ".Created // empty"
# shellcheck disable=SC2016
assert_contains "the reference it reads ends at the :latest tag" \
    "${BADGE_TEXT}" 'IMAGE_REF="ghcr.io/${owner}/${name}:latest"'

# Badge 3: "ostree.linux labels on the two akmods images the Containerfile
# pulls". Both halves are computed: the label the script reads, and that the
# stages it inspects are exactly the akmods stages the Containerfile declares.
assert_contains "write-badges.sh reads the ostree.linux label" \
    "${BADGE_TEXT}" 'ostree.linux'

containerfile_akmods_stages="$(
    sed -nE 's|^FROM[[:space:]]+ghcr\.io/ublue-os/akmods[^[:space:]]*[[:space:]]+AS[[:space:]]+([^[:space:]]+)[[:space:]]*$|\1|p' \
        "${CONTAINERFILE}" | LC_ALL=C sort | tr '\n' ' '
)"
badge_script_stages="$(
    sed -nE 's|^[a-z_]+_ref="\$\(from_ref ([^)]+)\)"$|\1|p' "${BADGE_SCRIPT}" |
        LC_ALL=C sort | tr '\n' ' '
)"
require_nonempty "akmods stages in the Containerfile" "${containerfile_akmods_stages}"
assert_eq "the badge inspects exactly the akmods stages the Containerfile pulls" \
    "${containerfile_akmods_stages}" "${badge_script_stages}"
assert_eq "and there are two of them, which is what makes it a comparison" \
    "2" "$(wc -w <<<"${containerfile_akmods_stages}")"

# "It refuses to guess": one leave-alone branch per badge, not a slogan.
require_claim "${QUALITY_DOC}" "the badge pipeline refuses to guess" \
    "It refuses to guess."
assert_eq "write-badges.sh leaves each of the two badges alone when an input is unreadable" \
    "2" "$(grep -c 'badge as-is' "${BADGE_SCRIPT}")"

# "It runs on its own daily schedule rather than only after a build."
require_claim "${QUALITY_DOC}" "the badge job runs on its own daily schedule" \
    "It runs on its own daily schedule"
badges_cron="$(sed -nE "s/^[[:space:]]*- cron: '([^']+)'.*/\1/p" "${BADGES_WF}" | head -1)"
assert_eq "the status-badges schedule fires every day" \
    "* * *" "$(awk '{ print $3, $4, $5 }' <<<"${badges_cron}")"
assert_contains "and it still also runs after a build" \
    "$(cat "${BADGES_WF}")" 'workflows: ["Build container image"]'
assert_contains "while skipping the pull_request builds" \
    "$(cat "${BADGES_WF}")" "github.event.workflow_run.event != 'pull_request'"

# =============================================================================
# docs/quality.md -- the gates
# =============================================================================

GATE_SECTION="$(doc_section "${QUALITY_DOC}" "## The gates")"
GATE_ROWS="$(table_rows <<<"${GATE_SECTION}")"
require_nonempty "a gate table under '## The gates'" "${GATE_ROWS}"

gate_names=""
while IFS= read -r row; do
    [[ -z "${row}" ]] && continue
    gate_names+="$(cell "${row}" 1)|"
done <<<"${GATE_ROWS}"
assert_eq "the gate table still lists the five gates this test joins" \
    "Shell tests job in build.yml|The image build itself|post-check.sh|bootc container lint|Verify pushed tags share one digest|" \
    "${gate_names}"

# Gate 1: the `Shell tests` job, and what it blocks.
assert_contains "build.yml has a job whose display name is Shell tests" \
    "${BUILD_TEXT}" "name: Shell tests"
build_push_needs="$(awk '/^  build_push:/ { found = 1 } found && /^    needs:/ { print $2; exit }' "${BUILD_WF}")"
tests_job_id="$(awk '/^  [a-z_]+:$/ { job = $1 } /name: Shell tests/ { gsub(":", "", job); print job; exit }' "${BUILD_WF}")"
assert_eq "build_push is blocked by the job that runs the suite" \
    "${tests_job_id}" "${build_push_needs}"

# "every PR and push, minus paths-ignore" -- both triggers, both filtered.
require_claim "${QUALITY_DOC}" "the suite runs on every PR and push minus paths-ignore" \
    "minus \`paths-ignore\`"
for trigger in pull_request push; do
    trigger_block="$(awk -v t="  ${trigger}:" '
        $0 == t { in_t = 1; next }
        /^  [a-z_]+:/ { in_t = 0 }
        in_t
    ' "${BUILD_WF}")"
    if grep -qE '^[[:space:]]+paths-ignore:[[:space:]]*$' <<<"${trigger_block}"; then
        _pass "build.yml filters its ${trigger} trigger with paths-ignore"
    else
        _fail "build.yml filters its ${trigger} trigger with paths-ignore" \
            "no paths-ignore key under the ${trigger} trigger"
    fi
done

# Gates 3 and 4 are RUN steps in the image, not workflow steps.
for image_gate in "/ctx/post-check.sh" "bootc container lint"; do
    assert_contains "the Containerfile runs ${image_gate} inside the build" \
        "$(grep -E '^(RUN|    )' "${CONTAINERFILE}")" "${image_gate}"
done

# Gate 5, and the ordering claim attached to it: the digest check runs on
# default-branch non-PR runs and blocks signing, so it has to come first.
verify_line="$(step_line "${BUILD_WF}" "Verify pushed tags share one digest")"
sign_line="$(step_line "${BUILD_WF}" "Sign container image")"
rechunk_line="$(step_line "${BUILD_WF}" "Rechunk Image with Chunkah")"
build_line="$(step_line "${BUILD_WF}" "Build Image")"
push_line="$(step_line "${BUILD_WF}" "Push To GHCR")"
for step_name in Build\ Image Rechunk\ Image\ with\ Chunkah Push\ To\ GHCR \
    Verify\ pushed\ tags\ share\ one\ digest Sign\ container\ image; do
    if [[ -n "$(step_line "${BUILD_WF}" "${step_name}")" ]]; then
        _pass "build.yml still has the '${step_name}' step"
    else
        _fail "build.yml still has the '${step_name}' step" \
            "the ordering claims in docs/quality.md are about this step"
    fi
done

if [[ -n "${verify_line}" && -n "${sign_line}" ]]; then
    if [[ "${verify_line}" -lt "${sign_line}" ]]; then
        _pass "the digest check runs before signing, so it can block it"
    else
        _fail "the digest check runs before signing, so it can block it" \
            "verify at line ${verify_line}, sign at line ${sign_line}"
    fi
fi

verify_if="$(awk -v n="${verify_line}" 'NR > n && /^        if: / { print; exit }' "${BUILD_WF}")"
assert_contains "the digest check is scoped to non-pull_request runs" \
    "${verify_if}" "github.event_name != 'pull_request'"
assert_contains "and to the default branch" \
    "${verify_if}" "github.event.repository.default_branch"

# "it says nothing about that manifest's contents" / "There is no automated
# check on the far side of the rechunk": no step after the rechunk re-runs
# either image gate.
require_claim "${QUALITY_DOC}" "nothing checks the image after the rechunk" \
    "There is no automated check on the far side of the rechunk"
after_rechunk="$(awk -v n="${rechunk_line}" 'NR > n' "${BUILD_WF}")"
assert_not_contains "no step after the rechunk runs post-check.sh again" \
    "${after_rechunk}" "post-check.sh"
assert_not_contains "no step after the rechunk runs bootc container lint again" \
    "${after_rechunk}" "bootc container lint"

# "The re-layered archive that comes back is loaded, tagged, pushed and signed."
rechunk_body="$(awk -v start="${rechunk_line}" -v stop="${push_line}" 'NR > start && NR < stop' "${BUILD_WF}")"
assert_contains "the rechunked archive is loaded back into container storage" \
    "${rechunk_body}" "podman load -i"
assert_contains "and tagged from the chunked image" \
    "${rechunk_body}" "podman tag"
if [[ -n "${build_line}" && -n "${rechunk_line}" && "${build_line}" -lt "${rechunk_line}" ]]; then
    _pass "the image is built before it is rechunked"
else
    _fail "the image is built before it is rechunked" \
        "build at line ${build_line}, rechunk at line ${rechunk_line}"
fi
if [[ -n "${push_line}" && -n "${sign_line}" && "${push_line}" -lt "${sign_line}" ]]; then
    _pass "and pushed before it is signed"
else
    _fail "and pushed before it is signed" \
        "push at line ${push_line}, sign at line ${sign_line}"
fi

# =============================================================================
# docs/quality.md -- what is not measured
# =============================================================================

# "no coverage percentage -- most of this repo's shell cannot be reached from
# the host". The manifest is what stands in for the number, so the claim is
# joined to it: the scripts recorded as unreachable are exactly the ones with no
# sourceable entry point, and post-check.sh is covered because it grew one.
require_claim "${QUALITY_DOC}" "no coverage percentage is tracked" \
    "no coverage percentage"

manifest="$(awk '/^MANIFEST=\$\(/, /^EOF$/' "${COVERAGE_TEST}" | grep -E '^[a-z].*\.sh')"
require_nonempty "a coverage manifest in tests/test-coverage.sh" "${manifest}"

# Scoped to build_files/, which is what the claim is about: those scripts run
# inside the image build. ci/write-badges.sh has no BASH_SOURCE guard either and
# is covered anyway, because the host can run it end to end with stubs.
uncovered="$(awk -F'\t' '$2 == "UNCOVERED" && $1 ~ /^build_files\// { print $1 }' <<<"${manifest}" |
    LC_ALL=C sort | tr '\n' ' ')"
unreachable_claim="$(awk '
    /^`Shell tests` cannot reach / { found = 1 }
    found && NF == 0 { exit }
    found
' "${QUALITY_DOC}")"
require_nonempty "the Shell tests unreachability claim" "${unreachable_claim}"
documented_unreachable="$(grep -oE 'build_files/[a-z-]+\.sh' <<<"${unreachable_claim}" |
    LC_ALL=C sort -u | tr '\n' ' ')"
assert_eq "quality.md names exactly the build_files scripts the manifest marks UNCOVERED" \
    "${uncovered}" "${documented_unreachable}"
assert_contains "the same claim still names the Containerfile as unreachable" \
    "${unreachable_claim}" "Containerfile"
require_claim "${QUALITY_DOC}" "post-check.sh is the sourceable exception" \
    "post-check.sh\` is the exception"
assert_contains "quality.md names the seam that makes post-check.sh sourceable" \
    "$(cat "${QUALITY_DOC}")" "BASH_SOURCE"
no_seam=""
while IFS= read -r script; do
    [[ -z "${script}" ]] && continue
    if ! grep -q 'BASH_SOURCE' "${REPO_ROOT}/${script}"; then
        no_seam+="${script} "
    fi
done < <(cd "${REPO_ROOT}" && git ls-files 'build_files/*.sh' | LC_ALL=C sort)
assert_eq "the build_files scripts recorded as unreachable are exactly the ones with no sourceable entry point" \
    "${uncovered}" "${no_seam}"
assert_contains "post-check.sh is covered, which is why it is not in that set" \
    "${manifest}" "build_files/post-check.sh	tests/test-post-check.sh"

# No percentage is produced anywhere, which is what makes the manifest the gate.
# Scoped to what CI runs -- the workflows and ci/ -- rather than tests/, where a
# test that names a coverage tool in order to assert its absence would match
# itself.
for coverage_tool in bashcov kcov "coverage run"; do
    matched="$(cd "${REPO_ROOT}" && git grep -l -F -- "${coverage_tool}" -- .github ci | tr '\n' ' ')"
    assert_eq "CI measures no line-coverage percentage with ${coverage_tool}" \
        "" "${matched}"
done

# =============================================================================
# docs/metrics.md
# =============================================================================

metrics_blocks="$(fenced_blocks "${METRICS_DOC}" bash)"
require_nonempty "runnable bash blocks" "${metrics_blocks}"

if bash -n <<<"${metrics_blocks}" 2>/dev/null; then
    _pass "every bash block in docs/metrics.md parses"
else
    _fail "every bash block in docs/metrics.md parses" \
        "bash -n rejected the concatenated blocks"
fi

# The jq filters the commands hand to gh have to compile. A filter that does not
# is a command a reader copies and watches fail.
joined_blocks="$(sed -e ':a' -e '/\\$/N; s/\\\n[[:space:]]*/ /; ta' <<<"${metrics_blocks}")"
filters="$(grep -oE -- "(-q|--jq) '[^']+'" <<<"${joined_blocks}" | sed -E "s/^(-q|--jq) '//; s/'\$//")"
require_nonempty "jq filters in its gh commands" "${filters}"
while IFS= read -r filter; do
    [[ -z "${filter}" ]] && continue
    jq "${filter}" <<<'[]' >/dev/null 2>&1
    status=$?
    # 3 is jq's compile error; 5 is "this filter errored on this input", which
    # says nothing about the filter a reader runs against real data.
    if [[ "${status}" -ne 3 ]]; then
        _pass "jq compiles the filter ${filter:0:48}"
    else
        _fail "jq compiles the filter ${filter:0:48}" "jq reported a compile error"
    fi
done <<<"${filters}"

# `gh run list --workflow build.yml --event schedule` is only a build-health
# question if build.yml is still the scheduled build.
workflows_named="$(grep -oE -- '--workflow [a-z-]+\.yml' <<<"${metrics_blocks}" | awk '{ print $2 }' | LC_ALL=C sort -u)"
require_nonempty "a --workflow argument in its build-health commands" "${workflows_named}"
while IFS= read -r workflow; do
    [[ -z "${workflow}" ]] && continue
    assert_file_exists "the build-health command names a workflow this repo has: ${workflow}" \
        "${REPO_ROOT}/.github/workflows/${workflow}"
done <<<"${workflows_named}"
build_cron="$(sed -nE "s/^[[:space:]]*- cron: '([^']+)'.*/\1/p" "${BUILD_WF}" | head -1)"
require_nonempty "a cron schedule on build.yml" "${build_cron}"
assert_eq "the build runs weekly, which is what makes two weeks two missed builds" \
    "* * 0" "$(awk '{ print $3, $4, $5 }' <<<"${build_cron}")"
require_claim "${METRICS_DOC}" "two weeks of staleness is two missed builds" \
    "More than two weeks old means at least two scheduled builds"

# The freshness command reads the same image, at the same tag, through the same
# field as the badge it says it shares a source with.
require_claim "${METRICS_DOC}" "freshness has the same source as the badge" \
    'Same source as the "last good build" badge'
metrics_ref="$(grep -oE 'docker://[^ ]+' <<<"${metrics_blocks}" | head -1)"
metrics_ref="${metrics_ref#docker://}"
readme_ref="$(grep -oE 'ghcr\.io/[a-z0-9._-]+/[a-z0-9._-]+:[a-z0-9._-]+' "${README}" |
    grep -v 'ublue-os' | LC_ALL=C sort -u | head -1)"
require_nonempty "an image reference in the freshness command" "${metrics_ref}"
assert_eq "it is the published image the README tells users to rebase onto" \
    "${readme_ref}" "${metrics_ref}"
default_tag="$(sed -nE 's/^[[:space:]]*DEFAULT_TAG: "([^"]+)".*/\1/p' "${BUILD_WF}" | head -1)"
assert_eq "at the tag build.yml publishes as the default" \
    "${default_tag}" "${metrics_ref##*:}"
assert_contains "and through the Created field the badge script reads" \
    "${metrics_blocks}" "{{.Created}}"

# "AGENTS.md covers how to fetch and respond to them" -- the bot, and the
# endpoint that surfaces inline review comments.
require_claim "${METRICS_DOC}" "AGENTS.md covers the review bot" \
    "covers how to fetch and respond to them"
assert_contains "AGENTS.md still names the review bot metrics.md points at" \
    "$(cat "${AGENTS_DOC}")" "chatgpt-codex-connector[bot]"
assert_contains "and still shows how to fetch its inline comments" \
    "$(cat "${AGENTS_DOC}")" "/pulls/<N>/comments"

# The per-script decisions live in the manifest; tests/README.md explains the
# gate rather than carrying the list itself.
require_claim "${METRICS_DOC}" "a stated decision per script replaces the number" \
    "a stated decision per script rather than a number"
decision_claim="$(awk '
    /The `MANIFEST` in / { found = 1 }
    found && /^- \*\*/ && !/Test coverage percentage/ { exit }
    found
' "${METRICS_DOC}")"
require_nonempty "the per-script decision pointer" "${decision_claim}"
# SC2016: the backticks are Markdown delimiters in the regex, not substitution.
# shellcheck disable=SC2016
decision_file="$(grep -oE '`tests/[a-z-]+\.sh`' <<<"${decision_claim}" | head -1 | tr -d '`')"
assert_eq "metrics.md points at the file that holds the per-script decisions" \
    "${COVERAGE_TEST#"${REPO_ROOT}"/}" "${decision_file}"
# SC2016: this is the literal manifest assignment the document names.
# shellcheck disable=SC2016
assert_contains "that file contains the manifest metrics.md names" \
    "$(cat "${REPO_ROOT}/${decision_file}")" 'MANIFEST=$('
assert_contains "tests/README.md documents the covered-or-UNCOVERED decision" \
    "$(cat "${TESTS_README}")" "the literal \`UNCOVERED\` and a reason"
while IFS=$'\t' read -r script _ reason; do
    [[ -z "${script}" ]] && continue
    if [[ -n "${reason//[[:space:]]/}" || -z "${reason}" ]]; then
        continue
    fi
    _fail "each UNCOVERED script states why" "${script} records an empty reason"
done <<<"${manifest}"
uncovered_count="$(awk -F'\t' '$2 == "UNCOVERED" && $3 ~ /[^[:space:]]/' <<<"${manifest}" | wc -l)"
assert_eq "every unreachable script records a reason, which is what is tracked instead" \
    "$(awk -F'\t' '$2 == "UNCOVERED"' <<<"${manifest}" | wc -l)" "${uncovered_count}"

# =============================================================================
# docs/metrics/*.md -- dated snapshots
# =============================================================================
#
# metrics.md is the method; a snapshot under docs/metrics/ is one reading of it,
# dated and left as it was read. What a snapshot owes a later reader is that its
# numbers can be reproduced, so each one is held to that: its commands parse and
# their jq filters compile, every `gh` call names this repository (a clone here
# carries an `upstream` remote, and a bare `gh` can read the parent repository
# instead), and every listing is pinned to the scope the numbers came from -- the
# runs created before the snapshot's date, the pull requests up to one number --
# so a rerun reads the same records rather than newer ones. It cannot freeze
# those records -- a reopened pull request or a deleted comment still changes
# the answer -- and the snapshot says so.

repo_slug="$(grep -oE 'github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/workflows/build\.yml' "${README}" |
    head -1 | cut -d/ -f2,3)"
require_nonempty "this repository's slug in README.md's build badge" "${repo_slug}"

# Prints each command line in $1 (continuations already joined) that runs a `gh`
# call without naming this repository. A line may hold a `$(gh ...)` inside a
# loop, so calls are counted rather than lines matched. Every subcommand counts,
# not a list of the ones in use today: `gh api` has to name the repository in
# its path, and anything else -- `pr`, `run`, or a later `gh workflow list` --
# has to carry `--repo` or `-R`.
unscoped_gh_calls() {
    local line calls named api_calls api_named
    while IFS= read -r line; do
        calls="$(grep -oE '(^|[^[:alnum:]_./-])gh [a-z]+' <<<"${line}" | grep -vc ' api$')"
        named="$(grep -oE -- "(--repo|-R) ${repo_slug}( |$)" <<<"${line}" | wc -l)"
        api_calls="$(grep -oE '(^|[^[:alnum:]_./-])gh api ' <<<"${line}" | wc -l)"
        api_named="$(grep -oE "gh api \"?repos/${repo_slug}/" <<<"${line}" | wc -l)"
        if [[ "${calls}" -ne "${named}" || "${api_calls}" -ne "${api_named}" ]]; then
            printf '%s\n' "${line}"
        fi
    done <<<"$1"
}

# metrics.md's commands are the ones a reader runs for current values, so they
# are held to the same rule as the snapshots' (Codex review on #248: a clone
# made with `gh repo clone` defaults `gh` to the parent repository).
assert_eq "every gh call in docs/metrics.md names ${repo_slug}" \
    "" "$(unscoped_gh_calls "${joined_blocks}")"

snapshots=()
while IFS= read -r snapshot; do
    snapshots+=("${snapshot}")
done < <(find "${REPO_ROOT}/docs/metrics" -maxdepth 1 -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)
require_nonempty "a dated snapshot under docs/metrics/" "${snapshots[*]}"

for snapshot in "${snapshots[@]}"; do
    rel="${snapshot#"${REPO_ROOT}"/}"
    read_on="$(basename "${snapshot}" .md)"
    if [[ "${read_on}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && date -d "${read_on}" >/dev/null 2>&1; then
        _pass "${rel} is named for the date it was read"
    else
        _fail "${rel} is named for the date it was read" "expected docs/metrics/YYYY-MM-DD.md"
        continue
    fi
    assert_eq "${rel}'s title carries the same date" \
        "# Metrics snapshot — ${read_on}" "$(head -1 "${snapshot}")"
    assert_contains "docs/metrics.md links to ${rel}" \
        "$(cat "${METRICS_DOC}")" "](metrics/${read_on}.md)"

    snapshot_blocks="$(fenced_blocks "${snapshot}" bash)"
    require_nonempty "runnable bash blocks in ${rel}" "${snapshot_blocks}" || continue
    if bash -n <<<"${snapshot_blocks}" 2>/dev/null; then
        _pass "every bash block in ${rel} parses"
    else
        _fail "every bash block in ${rel} parses" "bash -n rejected the concatenated blocks"
    fi

    snapshot_joined="$(sed -e ':a' -e '/\\$/N; s/\\\n[[:space:]]*/ /; ta' <<<"${snapshot_blocks}")"
    snapshot_filters="$(grep -oE -- "(-q|--jq) '[^']+'" <<<"${snapshot_joined}" |
        sed -E "s/^(-q|--jq) '//; s/'\$//")"
    require_nonempty "jq filters in ${rel}'s gh commands" "${snapshot_filters}"
    uncompiled=""
    while IFS= read -r filter; do
        [[ -z "${filter}" ]] && continue
        jq "${filter}" <<<'[]' >/dev/null 2>&1
        # 3 is jq's compile error, as in the metrics.md check above.
        [[ $? -eq 3 ]] && uncompiled+="${filter:0:60}"$'\n'
    done <<<"${snapshot_filters}"
    assert_eq "jq compiles every filter in ${rel}" "" "${uncompiled%$'\n'}"

    # The extractor reads a filter only when it is single-quoted on one line. A
    # double-quoted filter, or one that wraps, would be skipped while the
    # assertion above still said every filter compiled, so every -q/--jq on a
    # gh command has to be one the extractor read.
    gh_lines="$(grep -E '(^|[^[:alnum:]_./-])gh [a-z]+' <<<"${snapshot_joined}")"
    jq_flags="$(grep -oE -- '(^|[[:space:]])(-q|--jq)([[:space:]]|=)' <<<"${gh_lines}" | wc -l)"
    assert_eq "every jq filter in ${rel} is single-quoted on one line, so the compile check read it" \
        "${jq_flags}" "$(grep -c . <<<"${snapshot_filters}")"

    unpinned=""
    while IFS= read -r line; do
        if [[ "${line}" == *"gh run list"* && "${line}" != *"--created '<${read_on}'"* ]]; then
            unpinned+="${line}"$'\n'
        fi
        # `.number <=` alone is applied by jq after `--limit` has already cut
        # the newest-first listing, so the cutoff also has to reach GitHub.
        if [[ "${line}" == *"gh pr list"* ]] &&
            [[ "${line}" != *".number <= "* || "${line}" != *"--search 'created:<="* ]]; then
            unpinned+="${line}"$'\n'
        fi
    done <<<"${snapshot_joined}"
    assert_eq "every gh call in ${rel} names ${repo_slug}" "" "$(unscoped_gh_calls "${snapshot_joined}")"
    assert_eq "every run and pull request listing in ${rel} is pinned to a fixed scope" \
        "" "${unpinned%$'\n'}"
    # Two tables over different ranges of pull requests would not add up.
    pr_bounds="$(grep -oE '\.number <= [0-9]+' <<<"${snapshot_joined}" | LC_ALL=C sort -u)"
    if [[ "$(grep -c . <<<"${pr_bounds}")" -le 1 ]]; then
        _pass "${rel} reads every pull request listing up to the same number"
    else
        _fail "${rel} reads every pull request listing up to the same number" \
            "bounds found: ${pr_bounds//$'\n'/, }"
    fi
done

# =============================================================================
# docs/review-rubric.md
# =============================================================================

# The severity list has to classify every numbered section exactly once, or a
# reviewer reading it cannot tell whether an unlisted section blocks.
rubric_sections="$(sed -nE 's/^## ([0-9]+)\..*/\1/p' "${RUBRIC_DOC}" | LC_ALL=C sort -n | tr '\n' ' ')"
require_nonempty "numbered rubric sections" "${rubric_sections}"
severity_section="$(doc_section "${RUBRIC_DOC}" "## Severity")"
severity_numbers="$(grep -oE '(^|[^0-9])[0-9]+(,|\b)' <<<"${severity_section}" |
    grep -oE '[0-9]+' | LC_ALL=C sort -n | tr '\n' ' ')"
assert_eq "the severity list classifies every numbered section exactly once" \
    "${rubric_sections}" "${severity_numbers}"
assert_eq "the sections run 1..N without a gap" \
    "$(seq 1 "$(wc -w <<<"${rubric_sections}")" | tr '\n' ' ')" "${rubric_sections}"

# Section 3 names the direction of the incident-response handoff. Read both
# filenames from the prose so reversing them, or substituting another source,
# checks that claim rather than a second hard-coded copy of it.
reader_route_claim="$(awk '
    /directs readers handling a failed build/ { found = 1 }
    found { print; if (/`\./) exit }
' "${RUBRIC_DOC}")"
require_nonempty "the incident-response document route" "${reader_route_claim}"
route_source="$(code_spans "${reader_route_claim}" | sed -n '1p')"
route_target="$(code_spans "${reader_route_claim}" | sed -n '2p')"
require_nonempty "a source document in that route" "${route_source}"
require_nonempty "a destination document in that route" "${route_target}"
assert_file_exists "the route source exists: ${route_source}" "${REPO_ROOT}/${route_source}"
assert_file_exists "the route destination exists: ${route_target}" "${REPO_ROOT}/${route_target}"
assert_contains "the source document points readers to the destination" \
    "$(cat "${REPO_ROOT}/${route_source}")" "(${route_target}"

# Section 1: the four checks it says turn a red build green by deleting the
# protection. Each has to still be the thing it describes.
require_claim "${RUBRIC_DOC}" "loosening the kmod-zfs glob is the worst change available" \
    "Loosening the \`kmod-zfs\` glob in \`build_files/zfs.sh\`"
zfs_script="${REPO_ROOT}/build_files/zfs.sh"
# shellcheck disable=SC2016
assert_contains "zfs.sh still installs kmod-zfs through a kernel-scoped glob" \
    "$(cat "${zfs_script}")" 'kmod-zfs-"${KERNEL}"*.rpm'
install_line="$(grep -E '^dnf5 .* install ' "${zfs_script}")"
assert_not_contains "and that install is still fatal" "${install_line}" "|| true"
assert_contains "because zfs.sh still sets -e" " $(set_options "${zfs_script}")" " e "
# The guard is the whole RUN, not a clause inside one: `RUN true || test ...`
# reads the same to grep and protects nothing.
# SC1003: the trailing backslash is the Containerfile's line continuation, and
# it is part of the line being matched.
# shellcheck disable=SC2016,SC1003
if grep -qxF 'RUN test "$(rpm -E %fedora)" = "${FEDORA_VERSION}" || \' "${CONTAINERFILE}"; then
    _pass "the Containerfile still guards the Fedora major, as the whole RUN"
else
    _fail "the Containerfile still guards the Fedora major, as the whole RUN" \
        "no RUN whose first command is the rpm -E %fedora comparison"
fi
assert_contains "post-check.sh still asserts rather than reports" \
    "$(cat "${REPO_ROOT}/build_files/post-check.sh")" "require_glob"

# Section 2: "both akmods inputs pinned, or neither". The invariant is that the
# two FROM lines carry the same shape of tag, whichever shape that is.
require_claim "${RUBRIC_DOC}" "both akmods inputs are pinned, or neither" \
    "Are both akmods inputs pinned, or neither?"
akmods_tags="$(sed -nE 's|^FROM[[:space:]]+ghcr\.io/ublue-os/akmods[^:]*:([^[:space:]]+)[[:space:]]+AS.*|\1|p' \
    "${CONTAINERFILE}")"
require_nonempty "two akmods FROM lines to compare" "${akmods_tags}"
tag_shapes="$(sed -E 's/"?\$\{?FEDORA_VERSION\}?"?/<fedora>/g; s/[0-9]+/<n>/g' <<<"${akmods_tags}" |
    LC_ALL=C sort -u | wc -l)"
assert_eq "both akmods FROM lines carry the same shape of tag" "1" "${tag_shapes}"
assert_eq "and there are exactly two of them" "2" "$(grep -c . <<<"${akmods_tags}")"

# Section 4: the three comments that encode a past failure. Deleting one deletes
# the reason the code is shaped that way, which is the whole claim.
require_claim "${RUBRIC_DOC}" "three comments encode a specific past failure" \
    "Is a comment explaining an incident being removed?"
assert_contains "the .Config-only inspect still explains MAX_ARG_STRLEN" \
    "${BUILD_TEXT}" "MAX_ARG_STRLEN"
assert_contains "and is still the .Config-only form" \
    "${BUILD_TEXT}" "podman inspect --format '{{json .Config}}'"
assert_contains "the badge script still explains why it refuses to guess" \
    "${BADGE_TEXT}" "Refusing to guess is a deliberate property"
assert_contains "the push step still explains push-once-then-copy" \
    "${BUILD_TEXT}" "Push exactly one tag"
assert_contains "and the copy still preserves the pushed digest" \
    "${BUILD_TEXT}" "skopeo copy --preserve-digests"

# Section 5: the shell bar, stated as "zero output, informational findings
# included". That is a property of how the suite invokes shellcheck.
require_claim "${RUBRIC_DOC}" "shellcheck runs with -x and must be silent" \
    "\`shellcheck -x\` clean, zero output, informational findings included"
shellcheck_call="$(grep -F 'shellcheck -x' "${SYNTAX_TEST}")"
require_nonempty "a shellcheck invocation in tests/test-shell-syntax.sh" "${shellcheck_call}"
assert_not_contains "the suite applies no severity filter, so info findings count" \
    "${shellcheck_call}" "--severity"
# shellcheck disable=SC2016
assert_contains "and the assertion is that the output is empty" \
    "$(cat "${SYNTAX_TEST}")" 'assert_eq "shellcheck is clean for ${rel}" ""'
assert_contains "external sources are resolved, matching the -x" \
    "$(cat "${REPO_ROOT}/.shellcheckrc")" "external-sources=true"

# "Shebang and executable bit on anything run by path -- the Containerfile and
# the workflows do exactly that", and "set -euo pipefail on anything executed".
run_by_path="$(
    {
        sed -nE 's|.*/ctx/([a-z-]+\.sh).*|build_files/\1|p' "${CONTAINERFILE}"
        grep -ohE '\./(ci|tests)/[a-z-]+\.sh' "${REPO_ROOT}"/.github/workflows/*.yml | sed 's|^\./||'
    } | LC_ALL=C sort -u
)"
require_nonempty "scripts executed by path" "${run_by_path}"
while IFS= read -r script; do
    [[ -z "${script}" ]] && continue
    if [[ ! -f "${REPO_ROOT}/${script}" ]]; then
        _fail "${script} is run by path and exists" "no such tracked script"
        continue
    fi
    mode="$(cd "${REPO_ROOT}" && git ls-files -s -- "${script}" | awk '{ print $1 }')"
    assert_eq "${script} is executable, because it is run by path" "100755" "${mode}"
    assert_contains "${script} carries a shebang" "$(head -1 "${REPO_ROOT}/${script}")" "#!"

    options=" $(set_options "${REPO_ROOT}/${script}")"
    # tests/run-tests.sh is the one exception, and it is deliberate: it runs
    # every test file and reports all of the failures, so `-e` would abort the
    # run at the first red file. Asserting the exception by name means a second
    # script dropping `-e` still fails here.
    if [[ "${script}" == "tests/run-tests.sh" ]]; then
        assert_not_contains "tests/run-tests.sh deliberately omits -e so one red file does not end the run" \
            "${options}" " e "
        assert_contains "and collects the failures instead" \
            "$(cat "${REPO_ROOT}/${script}")" "failed+="
        continue
    fi
    for option in e u o pipefail; do
        assert_contains "${script} sets ${option}" "${options}" " ${option} "
    done
done <<<"${run_by_path}"

# "post-check.sh is covered *because* someone guarded its entry point with
# BASH_SOURCE. The others are not, because they do their work at the top level."
require_claim "${RUBRIC_DOC}" "the BASH_SOURCE seam is why post-check.sh is covered" \
    "guarded its entry point with"
# shellcheck disable=SC2016
assert_contains "post-check.sh still has that guard" \
    "$(cat "${REPO_ROOT}/build_files/post-check.sh")" 'if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then'

# Section 6: the evidence table. Every path in the left column resolves, and the
# workflow run it asks for is a workflow this repo has under that display name.
EVIDENCE_SECTION="$(doc_section "${RUBRIC_DOC}" "## 6. Was it verified, and could it have been?")"
EVIDENCE_ROWS="$(table_rows <<<"${EVIDENCE_SECTION}")"
require_nonempty "an evidence table under section 6" "${EVIDENCE_ROWS}"
tracked="$(cd "${REPO_ROOT}" && git ls-files)"
while IFS= read -r row; do
    [[ -z "${row}" ]] && continue
    spans="$(code_spans "$(raw_cell "${row}" 1)")"
    # A row without code spans names a kind of change rather than a path. Those
    # are enumerated, and an unrecognised one fails: a new row in a form this
    # loop cannot check must not pass silently.
    if [[ -z "${spans}" ]]; then
        label="$(cell "${row}" 1)"
        case "${label}" in
            Workflows)
                assert_eq "the evidence table's Workflows row still has workflows to describe" \
                    "0" "$([[ -n "$(cd "${REPO_ROOT}" && git ls-files '.github/workflows/*.yml')" ]] && echo 0 || echo 1)"
                ;;
            Docs)
                assert_eq "the evidence table's Docs row still has documents to describe" \
                    "0" "$([[ -n "$(cd "${REPO_ROOT}" && git ls-files 'docs/*.md')" ]] && echo 0 || echo 1)"
                ;;
            *)
                _fail "the evidence row '${label}' is in a form this test can check" \
                    "no code span and no known label; add a case or restore the paths"
                ;;
        esac
        continue
    fi
    for span in ${spans}; do
        case "${span}" in
            */)
                if grep -q "^${span}" <<<"${tracked}"; then
                    _pass "the evidence table's ${span} is a directory this repo tracks"
                else
                    _fail "the evidence table's ${span} is a directory this repo tracks" \
                        "no tracked file lives under it"
                fi
                ;;
            *)
                if grep -qxF "${span}" <<<"${tracked}"; then
                    _pass "the evidence table's ${span} is a tracked file"
                else
                    _fail "the evidence table's ${span} is a tracked file" \
                        "no such path in git ls-files"
                fi
                ;;
        esac
    done
done < <(sed -nE 's/^(\|[^|]*\|).*/\1/p' <<<"${EVIDENCE_ROWS}")

assert_contains "the evidence table asks for a run of the workflow by its display name" \
    "${EVIDENCE_SECTION}" "Build container image"
assert_eq "and that is still build.yml's name" \
    "Build container image" "$(sed -nE 's/^name: (.*)$/\1/p' "${BUILD_WF}" | head -1)"
assert_contains "the suite the table names is run with shellcheck installed" \
    "${BUILD_TEXT}" "name: Install shellcheck"

# Section 7: secrets and signing. "signing still applies to the same digest that
# was verified" is the assertion; the two steps read one output.
require_claim "${RUBRIC_DOC}" "signing applies to the digest that was verified" \
    "signing still applies to the same digest that was verified"
sign_block="$(awk -v n="${sign_line}" 'NR >= n && NR < n + 12' "${BUILD_WF}")"
verify_block="$(awk -v n="${verify_line}" 'NR >= n && NR < n + 12' "${BUILD_WF}")"
# shellcheck disable=SC2016
assert_contains "the sign step signs by digest, not by tag" \
    "${sign_block}" '@${DIGEST}'
assert_contains "and takes that digest from the push step" \
    "${sign_block}" "steps.push.outputs.digest"
assert_contains "which is the digest the verify step compared every tag against" \
    "${verify_block}" "steps.push.outputs.digest"
assert_contains "the private key reaches cosign through the environment" \
    "${sign_block}" "--key env://COSIGN_PRIVATE_KEY"
assert_contains "from the secret the rubric names" \
    "${sign_block}" "secrets.SIGNING_SECRET"
if grep -qxF "cosign.key" "${REPO_ROOT}/.gitignore"; then
    _pass "and cosign.key stays out of the tree"
else
    _fail "and cosign.key stays out of the tree" \
        "no uncommented cosign.key line in .gitignore"
fi
if grep -qxF "cosign.key" <<<"${tracked}"; then
    _fail "cosign.key is not tracked" "the signing key is committed"
else
    _pass "cosign.key is not tracked"
fi

finish
