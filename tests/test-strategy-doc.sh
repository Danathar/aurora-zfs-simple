#!/usr/bin/env bash
#
# Joins docs/strategy.md to the files that make its commands mean what it says.
#
# The page is commands, not numbers, so nothing on it goes stale by itself --
# but a command can quietly stop answering its question. A `gh ... list` that
# loses its `--limit` falls back to gh's default of 30 and undercounts without
# an error (docs/metrics.md records the same trap); a bare `gh` in a clone of
# this fork reads the parent repository; a renamed label returns no issues,
# which the page would read as "nothing is waiting on a human"; and a badge file
# that moves would make the skew command print nothing, which reads the same as
# "no skew". None of those fail on their own, so this test holds the page to the
# repository:
#
#   * its bash blocks parse, its `jq` filters compile, and every `gh` call names
#     this repository (the slug is read from the README's build badge, the same
#     place test-quality-docs.sh reads it);
#   * every list asks for everything it counts: issue and PR lists pin
#     `--limit 1000`, and every list carries some `--limit`;
#   * the three filters that carry logic -- consecutive lost builds, the badge
#     decode and the branch-prefix grouping -- are run on small inputs and must
#     give the answer the prose says they give;
#   * the badge command reads the file and branch that ci/write-badges.sh and
#     status-badges.yml actually write, and the workflow it lists is the
#     scheduled build;
#   * the labels it reads are ones that cannot be approvals to auto-merge
#     (docs/SECURITY-AI.md lists those), and `hold` is the one README.md says
#     agent pull requests get;
#   * the page's one sentence of reasoning, "there is no report job", is still
#     true of the tree, and metrics.md still points at the page.
#
# `needs-human` is applied by the Hive, outside this repository, so there is no
# file here to join it to. It is held to the other half of the rule instead:
# it must not be one of the labels SECURITY-AI.md says Hive reads as approval.

set -uo pipefail

TEST_NAME="test-strategy-doc"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=tests/lib/docs.sh
source "${TEST_DIR}/lib/docs.sh"

DOC="${REPO_ROOT}/docs/strategy.md"
README="${REPO_ROOT}/README.md"
METRICS_DOC="${REPO_ROOT}/docs/metrics.md"
SECURITY_DOC="${REPO_ROOT}/docs/SECURITY-AI.md"
BUILD_WF="${REPO_ROOT}/.github/workflows/build.yml"
BADGES_WF="${REPO_ROOT}/.github/workflows/status-badges.yml"
BADGE_SCRIPT="${REPO_ROOT}/ci/write-badges.sh"

missing=0
for required in "${DOC}" "${README}" "${METRICS_DOC}" "${SECURITY_DOC}" \
    "${BUILD_WF}" "${BADGES_WF}" "${BADGE_SCRIPT}"; do
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

# --- the commands ------------------------------------------------------------

blocks="$(fenced_blocks "${DOC}" bash)"
require_nonempty "bash blocks in docs/strategy.md" "${blocks}"

if bash -n <<<"${blocks}" 2>/dev/null; then
    _pass "every bash block in docs/strategy.md parses"
else
    _fail "every bash block in docs/strategy.md parses" "bash -n rejected the concatenated blocks"
fi

joined="$(join_continuations <<<"${blocks}")"
gh_lines="$(grep -E '(^|[^[:alnum:]_./-])gh [a-z]+' <<<"${joined}")"
require_nonempty "gh commands" "${gh_lines}"

repo_slug="$(grep -oE 'github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/workflows/build\.yml' "${README}" |
    head -1 | cut -d/ -f2,3)"
require_nonempty "this repository's slug in README.md's build badge" "${repo_slug}"
assert_eq "every gh call in docs/strategy.md names ${repo_slug}" \
    "" "$(unscoped_gh_calls "${joined}" "${repo_slug}")"

filters="$(jq_filters <<<"${joined}")"
require_nonempty "jq filters in its gh commands" "${filters}"
assert_jq_filters_compile "jq compiles every filter in docs/strategy.md" <<<"${filters}"
# The extractor reads only single-quoted filters on one line. Any other form
# would be skipped while the compile check above still said every filter passed.
assert_eq "every jq flag in docs/strategy.md is a filter the compile check read" \
    "$(jq_flag_count <<<"${joined}")" "$(grep -c . <<<"${filters}")"

# Issue and PR lists are counts, so they must see everything. Run lists are the
# newest few by design, but still have to say how few.
unlimited=""
while IFS= read -r line; do
    [[ "${line}" == *" list "* ]] || continue
    if [[ "${line}" == *"gh issue list"* || "${line}" == *"gh pr list"* ]]; then
        [[ "${line}" == *"--limit 1000"* ]] || unlimited+="${line}"$'\n'
    else
        [[ "${line}" == *"--limit "* ]] || unlimited+="${line}"$'\n'
    fi
done <<<"${gh_lines}"
assert_eq "every issue and PR list asks for 1000 and every run list names a limit" \
    "" "${unlimited%$'\n'}"

# --- the build-health command ------------------------------------------------

workflows_named="$(grep -oE -- '--workflow [a-z-]+\.yml' <<<"${joined}" | awk '{ print $2 }' | LC_ALL=C sort -u)"
assert_eq "the build-health command reads build.yml and nothing else" "build.yml" "${workflows_named}"
assert_contains "build.yml still has a schedule trigger, which is what --event schedule selects" \
    "$(cat "${BUILD_WF}")" "- cron: '"
assert_contains "and the command selects it" "${joined}" "--event schedule"

lost_filter="$(grep -F 'index("success")' <<<"${filters}")"
require_nonempty "the consecutive-lost-builds filter" "${lost_filter}" || lost_filter='.'
assert_eq "no lost builds when the newest scheduled run succeeded" \
    "0" "$(jq -c "${lost_filter}" <<<'[{"conclusion":"success"},{"conclusion":"failure"}]')"
assert_eq "two lost builds, counted up to the first success" \
    "2" "$(jq -c "${lost_filter}" <<<'[{"conclusion":"failure"},{"conclusion":"cancelled"},{"conclusion":"success"},{"conclusion":"failure"}]')"
assert_eq "a run still in progress is not a lost build" \
    "1" "$(jq -c "${lost_filter}" <<<'[{"conclusion":""},{"conclusion":"failure"},{"conclusion":"success"}]')"
assert_eq "no success at all reads as the whole window, which the page says means at least that many" \
    "3" "$(jq -c "${lost_filter}" <<<'[{"conclusion":"failure"},{"conclusion":"failure"},{"conclusion":"failure"}]')"

# --- the skew-badge command --------------------------------------------------

badge_command="$(grep -F 'contents/' <<<"${joined}")"
require_nonempty "the badge command" "${badge_command}"
badge_file="$(sed -nE 's|.*contents/([^?"]+)\?ref=([^"]+)".*|\1|p' <<<"${badge_command}")"
badge_ref="$(sed -nE 's|.*contents/([^?"]+)\?ref=([^"]+)".*|\2|p' <<<"${badge_command}")"
assert_contains "ci/write-badges.sh writes the file the page reads (${badge_file})" \
    "$(cat "${BADGE_SCRIPT}")" "\${OUT_DIR}/${badge_file}"
assert_contains "status-badges.yml publishes that file" \
    "$(cat "${BADGES_WF}")" "${badge_file}"
assert_contains "to the branch the page reads (${badge_ref})" \
    "$(cat "${BADGES_WF}")" "git push origin HEAD:${badge_ref}"
assert_contains "and the README's OpenZFS/kernel badge renders that same file from that branch" \
    "$(grep -F 'OpenZFS/kernel status' "${README}")" "%2F${badge_ref}%2F${badge_file}"

# GitHub's contents API wraps base64 with newlines, which not every jq's
# `@base64d` accepts, so the filter strips them first. The sample is the JSON write-badges.sh writes, encoded the same way.
decode_filter="$(grep -F '@base64d' <<<"${filters}")"
require_nonempty "the badge decode filter" "${decode_filter}" || decode_filter='.'
sample='{"schemaVersion":1,"label":"openzfs/kernel","message":"in sync (7.2.5-200)","color":"brightgreen"}'
api_reply="$(jq -n --arg c "$(printf '%s\n' "${sample}" | base64 -w 60)" '{content: $c}')"
assert_eq "the decode filter recovers the badge message from a wrapped contents reply" \
    '"in sync (7.2.5-200)"' "$(jq -c "${decode_filter}" <<<"${api_reply}")"
# shellcheck disable=SC2016
assert_contains "write-badges.sh still words the message 'in sync' when the akmods agree" \
    "$(cat "${BADGE_SCRIPT}")" '"in sync ($('
assert_contains "and 'blocked' when they do not, the two states the page tells the reader to look for" \
    "$(cat "${BADGE_SCRIPT}")" '"blocked: kernel'

# --- the merged-work command -------------------------------------------------

prefix_filter="$(grep -F 'split("/")' <<<"${filters}")"
require_nonempty "the branch-prefix grouping filter" "${prefix_filter}" || prefix_filter='.'
assert_eq "the grouping filter counts merged PRs by the first part of the branch name" \
    '[{"prefix":"docs","count":1},{"prefix":"fix","count":2}]' \
    "$(jq -c "${prefix_filter}" <<<'[{"headRefName":"fix/a"},{"headRefName":"docs/b"},{"headRefName":"fix/c/d"}]')"
assert_contains "the merged-work search is bounded by a date placeholder" \
    "${joined}" '--search "merged:>=<date>"'

# --- the labels --------------------------------------------------------------

approval_block="$(awk '
    /labels as an \*\*approval to auto-merge on green CI\*\*/ { found = 1 }
    found && /^```text/ { in_block = 1; next }
    found && in_block && /^```/ { exit }
    found && in_block
' "${SECURITY_DOC}")"
require_nonempty "SECURITY-AI.md's list of labels Hive reads as approval" "${approval_block}"

labels_read="$(grep -oE -- '--label [A-Za-z0-9/_-]+' <<<"${joined}" | awk '{ print $2 }' | LC_ALL=C sort -u)"
assert_eq "the page reads exactly two labels, hold and needs-human" \
    "hold needs-human" "$(tr '\n' ' ' <<<"${labels_read}" | sed 's/ $//')"
for label in ${labels_read}; do
    assert_eq "${label} is not a label Hive reads as approval to auto-merge" \
        "0" "$(tr -s ' ' '\n' <<<"${approval_block}" | grep -cxF "${label}")"
done
require_claim "${README}" "agent pull requests get a hold label" \
    "gets a \`hold\` label automatically"

# --- the claim that there is no report job -----------------------------------

assert_contains "docs/strategy.md has a section giving the reason for no report job" \
    "$(cat "${DOC}")" "## Why there is no report job"
if (cd "${REPO_ROOT}" && git ls-files --error-unmatch .github/workflows/strategy-report.yml >/dev/null 2>&1); then
    _fail "no strategy-report.yml workflow is committed" \
        "the page says there is no scheduled report job; update docs/strategy.md or drop the workflow"
else
    _pass "no strategy-report.yml workflow is committed"
fi

# --- reachability --------------------------------------------------------------

assert_contains "docs/metrics.md links to the page" "$(cat "${METRICS_DOC}")" "](strategy.md)"

finish
