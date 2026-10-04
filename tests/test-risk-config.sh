#!/usr/bin/env bash
#
# .claude/risk-config.json, against docs/risk-tiers.md and the tree.
#
# The JSON is the document's tier table in a form a program can read. Two copies
# of one table drift unless something reads both, so this reads both: the
# document's table is parsed (tier, name, backticked path globs in order, merge
# answer) and compared with the JSON field by field. The document is
# authoritative; test-risk-tiers.sh is what holds the document itself to the
# tree, so only the agreement between the two is checked here, plus the one claim
# the JSON adds -- that every glob it lists still claims a tracked file.
#
# The JSON lists globs, never individual workflows, on purpose: a per-file list
# is a second copy of the tree that drifts every time a workflow is added.

# Backticks inside single quotes below are Markdown code-span delimiters to match, not shell.
# shellcheck disable=SC2016

set -uo pipefail

TEST_NAME="test-risk-config"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

CONFIG_REL=".claude/risk-config.json"
DOC_REL="docs/risk-tiers.md"
CONFIG="${REPO_ROOT}/${CONFIG_REL}"
DOC="${REPO_ROOT}/${DOC_REL}"

for required in "${CONFIG}" "${DOC}"; do
    [[ -f "${required}" ]] && continue
    _fail "${required#"${REPO_ROOT}"/} is present" "no such file"
    finish
    exit
done

if ! jq -e . "${CONFIG}" >/dev/null 2>&1; then
    _fail "${CONFIG_REL} is valid JSON" "jq could not parse it"
    finish
    exit
fi
_pass "${CONFIG_REL} is valid JSON"

TRACKED="$(git -C "${REPO_ROOT}" ls-files)"

assert_eq "the config is tracked, not left to a .gitignore rule" \
    "${CONFIG_REL}" "$(grep -xF -- "${CONFIG_REL}" <<<"${TRACKED}")"

# --- the document's table ---------------------------------------------------

table_rows=$(
    awk '
        /^## The tiers$/ { in_section = 1; next }
        in_section && /^## /        { exit }
        in_section && /^\| \*\*[0-9]/ { print }
    ' "${DOC}"
)
if [[ -z "${table_rows}" ]]; then
    _fail "${DOC_REL} still has a tier table under '## The tiers'" \
        "nothing was extracted, so the comparison below would verify nothing"
    finish
    exit
fi

trim() { sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//' <<<"$1"; }

# Backticked spans of a cell, one per line, in order.
spans() { grep -o '`[^`]*`' <<<"$1" | sed -e 's/^`//' -e 's/`$//'; }

doc_tiers=()
declare -A DOC_NAME=() DOC_PATHS=() DOC_PATHS_CELL=() DOC_MERGE=() DOC_CONDITION=()

while IFS= read -r row; do
    body=${row#\|}
    body=${body%\|}
    IFS='|' read -r c_tier _ c_paths c_merge <<<"${body}"

    label=$(sed -E 's/^[[:space:]]*\*\*//; s/\*\*[[:space:]]*$//' <<<"${c_tier}")
    number=${label%% *}
    name=$(trim "${label#*— }")
    merge=$(trim "${c_merge}")

    doc_tiers+=("${number}")
    DOC_NAME["${number}"]="${name}"
    DOC_PATHS_CELL["${number}"]="${c_paths}"
    DOC_PATHS["${number}"]="$(spans "${c_paths}")"
    case "${merge}" in
        Yes*)
            DOC_MERGE["${number}"]=true
            condition=''
            if [[ "${merge}" == 'Yes, if '* ]]; then
                condition=${merge#Yes, if }
                condition=${condition%.}
            fi
            DOC_CONDITION["${number}"]="${condition}"
            ;;
        '**No.**'* | No*) DOC_MERGE["${number}"]=false; DOC_CONDITION["${number}"]='' ;;
        *) DOC_MERGE["${number}"]=unparsed; DOC_CONDITION["${number}"]='' ;;
    esac
done <<<"${table_rows}"

# --- agreement --------------------------------------------------------------

# Same tiers, same order: the document lists them highest first and the order is
# part of what a reader acts on.
assert_eq "the config lists the document's tiers in the document's order" \
    "${doc_tiers[*]}" "$(jq -r '[.tiers[].tier] | map(tostring) | join(" ")' "${CONFIG}")"

assert_eq "the config names the document it copies" \
    "${DOC_REL}" "$(jq -r '.source' "${CONFIG}")"

# Types and keys. `jq -r` prints the string "false" and the boolean false the
# same way, and `select(.tier == 1)` does not match a tier written as "1", so the
# comparisons below cannot see either. A program reading the file can: in most
# languages a non-empty string is true, so "false" would read as "merge on green
# CI alone". The key sets are closed for the same reason -- a key the document
# does not have is a claim nothing here checks.
assert_eq "the config's top-level keys are the ones the document backs" \
    '$comment highest_tier_wins source tiers' \
    "$(jq -r 'keys_unsorted | sort | join(" ")' "${CONFIG}")"
assert_eq "highest_tier_wins is a JSON boolean" \
    "boolean" "$(jq -r '.highest_tier_wins | type' "${CONFIG}")"
tier_count=$(jq '.tiers | length' "${CONFIG}")
for ((i = 0; i < tier_count; i++)); do
    entry=$(jq -c --argjson i "${i}" '.tiers[$i]' "${CONFIG}")
    assert_eq "tiers[${i}] uses only known keys" "" \
        "$(jq -r 'keys - ["tier","name","paths","partial_paths","merge_on_green_ci_alone","merge_condition"] | join(" ")' <<<"${entry}")"
    assert_eq "tiers[${i}].tier is a JSON number" "number" "$(jq -r '.tier | type' <<<"${entry}")"
    assert_eq "tiers[${i}].merge_on_green_ci_alone is a JSON boolean" \
        "boolean" "$(jq -r '.merge_on_green_ci_alone | type' <<<"${entry}")"
    assert_eq "tiers[${i}] has no empty merge_condition" \
        "ok" "$(jq -r 'if has("merge_condition") and .merge_condition == "" then "empty" else "ok" end' <<<"${entry}")"
done

for tier in "${doc_tiers[@]}"; do
    entry=$(jq -c --argjson t "${tier}" '.tiers[] | select(.tier == $t)' "${CONFIG}")
    # Exactly one entry: none means the tier would be skipped unchecked, two
    # means a program has to guess which one counts.
    matches=$(jq --argjson t "${tier}" '[.tiers[] | select(.tier == $t)] | length' "${CONFIG}")
    assert_eq "tier ${tier} has exactly one entry in the config" "1" "${matches}"
    [[ -z "${entry}" || "${matches}" != 1 ]] && continue

    assert_eq "tier ${tier} has the document's name" \
        "${DOC_NAME[${tier}]}" "$(jq -r '.name' <<<"${entry}")"

    assert_eq "tier ${tier} lists the document's path globs, in order" \
        "${DOC_PATHS[${tier}]}" "$(jq -r '.paths[]' <<<"${entry}")"

    assert_eq "tier ${tier} gives the document's merge-on-green-CI-alone answer" \
        "${DOC_MERGE[${tier}]}" "$(jq -r '.merge_on_green_ci_alone' <<<"${entry}")"

    # "Yes, if X" is not a plain yes; a program that read only the boolean would
    # merge what the document says needs a human to have read it first.
    assert_eq "tier ${tier} carries the document's condition on that answer" \
        "${DOC_CONDITION[${tier}]}" "$(jq -r '.merge_condition // ""' <<<"${entry}")"

    # A glob that matches no tracked path is a rule that classifies nothing.
    while IFS= read -r glob; do
        [[ -z "${glob}" ]] && continue
        pathspec=":(glob)${glob}"
        [[ "${glob}" == */ ]] && pathspec=":(glob)${glob}**"
        count=$(git -C "${REPO_ROOT}" ls-files -- "${pathspec}" | grep -c .)
        if [[ "${count}" -gt 0 ]]; then
            _pass "tier ${tier} glob matches ${count} tracked path(s): ${glob}"
        else
            _fail "tier ${tier} glob matches a tracked path: ${glob}" \
                "no tracked path matches it; the config classifies nothing there"
        fi
    done < <(jq -r '.paths[]' <<<"${entry}")

    # A glob that covers only part of a file (the push/verify/sign steps of
    # build.yml) has to say so, or a program reads it as the whole file.
    while IFS= read -r partial; do
        [[ -z "${partial}" ]] && continue
        if jq -e --arg p "${partial}" '.paths | index($p)' <<<"${entry}" >/dev/null &&
            [[ "${DOC_PATHS_CELL[${tier}]}" == *"steps of \`${partial}\`"* ]]; then
            _pass "tier ${tier} partial path is a partial claim in the document: ${partial}"
        else
            _fail "tier ${tier} partial path is a partial claim in the document: ${partial}" \
                "it must be in paths and the document must say 'steps of \`${partial}\`'"
        fi
    done < <(jq -r '.partial_paths[]?' <<<"${entry}")
done

# The reverse of the partial check: the document's "steps of `x`" claims must
# each be recorded, or the JSON states a whole-file claim the document does not.
for tier in "${doc_tiers[@]}"; do
    while IFS= read -r claimed; do
        [[ -z "${claimed}" ]] && continue
        if jq -e --argjson t "${tier}" --arg p "${claimed}" \
            '.tiers[] | select(.tier == $t) | .partial_paths // [] | index($p)' "${CONFIG}" >/dev/null; then
            _pass "tier ${tier}: the document's partial claim is recorded: ${claimed}"
        else
            _fail "tier ${tier}: the document's partial claim is recorded: ${claimed}" \
                "add it to partial_paths"
        fi
    done < <(grep -oE 'steps of `[^`]+`' <<<"${DOC_PATHS_CELL[${tier}]}" | sed -E 's/^steps of `//; s/`$//')
done

assert_eq "a change spanning tiers takes the highest, as the document says" \
    "true" "$(jq -r '.highest_tier_wins' "${CONFIG}")"
assert_eq "the document states that rule" \
    "yes" "$(tr '\n' ' ' <"${DOC}" | tr -s '[:space:]' ' ' | grep -qF 'it takes the highest tier it touches' && echo yes || echo no)"

# --- the config's own tier --------------------------------------------------
#
# Highest tier whose globs claim the file, computed from the JSON the way the
# document says to compute it. Tier 3, because it is the one file here a program
# could read to decide a merge; the Tier 1 `.claude/**` glob matches it too.
config_tier=''
while IFS= read -r tier; do
    mapfile -t specs < <(jq -r --argjson t "${tier}" \
        '.tiers[] | select(.tier == $t) | .paths[] | if endswith("/") then . + "**" else . end | ":(glob)" + .' "${CONFIG}")
    if git -C "${REPO_ROOT}" ls-files -- "${specs[@]}" | grep -qxF -- "${CONFIG_REL}"; then
        if [[ -z "${config_tier}" || "${tier}" -gt "${config_tier}" ]]; then
            config_tier="${tier}"
        fi
    fi
done < <(jq -r '.tiers[].tier' "${CONFIG}")
assert_eq "the config file is classified by its own globs as the published-artifact tier" \
    "3" "${config_tier}"

# --- the two documents' pointers --------------------------------------------

doc_flat=$(tr '\n' ' ' <"${DOC}" | tr -s '[:space:]' ' ')
assert_contains "${DOC_REL} points at the config" "${doc_flat}" "\`${CONFIG_REL}\`"
assert_contains "${DOC_REL} names the test that holds them equal" \
    "${doc_flat}" "tests/test-risk-config.sh"
comment=$(jq -r '."$comment"' "${CONFIG}")
assert_contains "the config's comment names the authoritative document" \
    "${comment}" "${DOC_REL}"
assert_contains "the config's comment names the test that holds it equal" \
    "${comment}" "tests/test-risk-config.sh"

# --- "nothing enforces this file" ---------------------------------------------
#
# The comment and the document both say no automation reads the JSON. That is an
# absence, so it is checked as one: nothing outside docs, tests and the file
# itself may mention it. A workflow, hook or script that starts reading it makes
# this fail, which is the cue to rewrite the claim -- and to look at the tier the
# file sits in again.
readers=$(
    cd "${REPO_ROOT}" &&
        git grep -lF -- 'risk-config.json' -- . \
            ':(exclude)docs/**' ':(exclude)tests/**' ':(exclude)README.md' \
            ":(exclude)${CONFIG_REL}"
)
if [[ -z "${readers}" ]]; then
    _pass "nothing outside docs, tests and the config itself reads it"
else
    _fail "nothing outside docs, tests and the config itself reads it" \
        "${readers//$'\n'/, }" \
        "the claim that nothing enforces the config no longer holds"
fi

finish
