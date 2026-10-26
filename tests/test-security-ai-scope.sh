#!/usr/bin/env bash
#
# Joins the first bullet of docs/SECURITY-AI.md's "What this policy does not
# cover" section to the controls that exist in the tree.
#
# That bullet is where a reader learns which of the page's rules a machine
# enforces and which rest on a reviewer. It named three mechanical controls --
# the `permissions:` blocks, the `if:` conditions on the publishing steps and
# branch protection -- and called them the only ones. It left out the two the
# same page calls "the boundary an agent works inside" under "What an agent may
# do unattended": the `deny` list in .claude/settings.json and the `PreToolUse`
# gate it runs. Nothing read the section, so docs/section-map.txt marked it
# `prose: unchecked:`.
#
# The controls are read from the tree rather than listed here, so a control the
# tree gains has to be named on the page before this passes:
#
#   1. the section and its "It is not enforced by CI." bullet are present;
#   2. the bullet names .claude/settings.json and `deny` while that file holds a
#      deny list, `PreToolUse` and each script a PreToolUse hook runs, the
#      committed ruleset files, and every file under .github/policies/;
#   3. each of those control files sits in docs/risk-tiers.md's Tier 3 row,
#      by its own path or by a `dir/**` entry, as the bullet says it does;
#   4. every relative link in the section resolves, and every tests/*.sh the
#      bullet names is tracked and names, outside a comment, a control file the
#      bullet says it checks.
#
# Markdown wraps, so the bullet is squashed to single spaces before matching.

# The awk and jq programs below are single-quoted so that `$0` and `$1` reach
# them rather than the shell. SC2016 is off for the file rather than repeated.
# shellcheck disable=SC2016

set -uo pipefail

TEST_NAME="test-security-ai-scope"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

SECURITY_MD="${REPO_ROOT}/docs/SECURITY-AI.md"
SETTINGS="${REPO_ROOT}/.claude/settings.json"
RISK_TIERS="${REPO_ROOT}/docs/risk-tiers.md"
HEADING="## What this policy does not cover"
LEAD="- **It is not enforced by CI.**"

for required in "${SECURITY_MD}" "${SETTINGS}" "${RISK_TIERS}"; do
    assert_file_exists "${required#"${REPO_ROOT}/"} is present" "${required}"
done

# section <file> <heading> — the lines after <heading> up to the next `## `.
section() {
    awk -v heading="$2" '
        $0 == heading { inside = 1; next }
        inside && /^## / { exit }
        inside { print }
    ' "$1"
}

# bullets <text> — one line per top-level `- ` bullet, continuations joined and
# runs of whitespace squashed to one space.
bullets() {
    awk '
        /^- / { if (buf != "") print buf; buf = $0; next }
        /^[^ ]/ || /^$/ { if (buf != "") print buf; buf = ""; next }
        buf != "" { buf = buf " " $0 }
        END { if (buf != "") print buf }
    ' <<<"$1" | sed -E 's/[[:space:]]+/ /g; s/ $//'
}

SECTION="$(section "${SECURITY_MD}" "${HEADING}")"
assert_contains "docs/SECURITY-AI.md still has the section" "${SECTION:+present}" "present"

BULLET="$(bullets "${SECTION}" | grep -F -- "${LEAD}")"
assert_contains "the section still opens a bullet with the CI lead" "${BULLET}" "${LEAD}"

# --- the controls the tree holds ---------------------------------------------

# Each entry is a repository path the bullet must name, as a link target or in
# backticks; the path is checked as written on the page, without the `../`.
CONTROLS=()

deny_count="$(jq '.permissions.deny // [] | length' "${SETTINGS}")"
if [[ "${deny_count}" -gt 0 ]]; then
    CONTROLS+=(".claude/settings.json")
    assert_contains "the bullet calls the settings file's list the deny list" \
        "${BULLET}" '`deny`'
fi

mapfile -t HOOK_SCRIPTS < <(
    jq -r '.hooks.PreToolUse // [] | .[].hooks[]?.command' "${SETTINGS}" |
        sed -e 's/^"//' -e 's/"$//' -e 's|^\${CLAUDE_PROJECT_DIR:-\.}/||' \
            -e 's|^\$CLAUDE_PROJECT_DIR/||' -e 's|^\./||'
)
if [[ "${#HOOK_SCRIPTS[@]}" -gt 0 ]]; then
    assert_contains "the bullet names the PreToolUse gate" "${BULLET}" '`PreToolUse`'
fi
for script in "${HOOK_SCRIPTS[@]}"; do
    # A command this cannot reduce to a tracked path is a parsing failure here,
    # not a hook the page can skip.
    assert_eq "the PreToolUse command '${script}' is a tracked file" "${script}" \
        "$(git -C "${REPO_ROOT}" ls-files --error-unmatch -- "${script}" 2>/dev/null)"
    CONTROLS+=("${script}")
done

mapfile -t COMMITTED < <(git -C "${REPO_ROOT}" ls-files -- .github/rulesets .github/policies)
CONTROLS+=("${COMMITTED[@]}")

# A scan that finds nothing passes everything; these are what the tree held
# when this test was written.
for expected in .claude/settings.json .claude/hooks/gate-git-diff.sh \
    .github/rulesets/main.json .github/policies/workflow-permissions.json; do
    assert_contains "the controls read from the tree include ${expected}" \
        "$(printf '%s\n' "${CONTROLS[@]}")" "${expected}"
done

for control in "${CONTROLS[@]}"; do
    if grep -qF -e "\`${control}\`" -e "(../${control})" <<<"${BULLET}"; then
        _pass "the bullet names ${control}"
    else
        _fail "the bullet names ${control}" \
            "docs/SECURITY-AI.md's \"${LEAD}\" bullet lists the mechanical controls" \
            "and leaves out ${control}"
    fi
done

# --- Tier 3 ------------------------------------------------------------------

TIER3_ROW="$(grep -m1 -F '| **3 ' "${RISK_TIERS}")"
assert_contains "docs/risk-tiers.md still has a Tier 3 row" "${TIER3_ROW:+present}" "present"
assert_contains "the bullet says risk-tiers.md puts the controls in Tier 3" \
    "${BULLET}" "Tier 3"

mapfile -t TIER3_PATHS < <(grep -oE '`[^`]+`' <<<"${TIER3_ROW}" | tr -d '`')
for control in "${CONTROLS[@]}"; do
    covered=""
    for entry in "${TIER3_PATHS[@]}"; do
        if [[ "${entry}" == "${control}" ]] ||
            { [[ "${entry}" == */'**' ]] && [[ "${control}" == "${entry%'**'}"* ]]; }; then
            covered="${entry}"
            break
        fi
    done
    assert_contains "${control} is in the Tier 3 row" "${covered:+in}" "in"
done

# --- links and the tests the bullet names ------------------------------------

mapfile -t LINKS < <(grep -oE '\]\([^)#]+' <<<"${SECTION}" | sed 's/^](//' | grep -vE '^[a-z]+:')
if [[ "${#LINKS[@]}" -gt 0 ]]; then
    _pass "the section's links were read"
else
    _fail "the section's links were read" "no relative link found under \"${HEADING}\""
fi
for link in "${LINKS[@]}"; do
    assert_file_exists "the section's link ${link} resolves from docs/" \
        "${REPO_ROOT}/docs/${link}"
done

mapfile -t NAMED_TESTS < <(grep -oE '`tests/[^`]+\.sh`' <<<"${BULLET}" | tr -d '`' | sort -u)
for named in "${NAMED_TESTS[@]}"; do
    assert_eq "${named} is tracked" "${named}" \
        "$(git -C "${REPO_ROOT}" ls-files --error-unmatch -- "${named}" 2>/dev/null)"
    reads=""
    for control in "${CONTROLS[@]}"; do
        if grep -v '^[[:space:]]*#' "${REPO_ROOT}/${named}" 2>/dev/null |
            grep -qF "${control}"; then
            reads="${control}"
            break
        fi
    done
    assert_contains "${named} reads a control file the bullet names" "${reads:+reads}" "reads"
done

finish
