#!/usr/bin/env bash
#
# Joins the two pages that describe ai-fix.yml to the files that decide what it
# can do.
#
# docs/SECURITY-AI.md's "Agent-authored pull requests" says how the workflow
# starts, who can start it, what its token holds and why that grant is bounded.
# docs/branch-protection.md's "Why it matters here" says the `fix` job's token
# is why the ruleset has to exist. tests/test-ai-fix.sh holds the workflow, but
# it reads neither page, so docs/section-map.txt marked both sections
# `prose: unchecked:`. The security page named two of the five scopes the job
# holds and left out `id-token: write` and `actions: read`, under a sentence
# saying the job holds no more than opening a pull request requires.
#
#   1. both sections are present, and their links resolve;
#   2. the triggers, the label, the phrase and the branch prefix the page gives
#      are the ones in the workflow, and neither removed trigger came back;
#   3. no bot and no user without write access can start the agent;
#   4. every scope the `fix` job holds is on the page, and the only other scope
#      the page names is the `packages: write` it says the job lacks;
#   5. the job cannot reach SIGNING_SECRET, and every step that publishes or
#      signs in build.yml carries the gate the page quotes;
#   6. the ruleset is what the two pages say, and build.yml still has the
#      scheduled and manual triggers that would sign what reached `main`;
#   7. the prompt says what the pages say it says, and its approval labels are
#      the ones SECURITY-AI.md lists;
#   8. `preflight` is what stops a run with no credentials or a fork head.
#
# Markdown wraps, so each section is squashed to single spaces before a phrase
# is matched.

# The needles below are single-quoted so that `${{` reaches jq rather than the
# shell. SC2016 is off for the file rather than repeated.
# shellcheck disable=SC2016

set -uo pipefail

TEST_NAME="test-ai-fix-docs"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

SECURITY_MD="${REPO_ROOT}/docs/SECURITY-AI.md"
PROTECTION_MD="${REPO_ROOT}/docs/branch-protection.md"
CONTRIBUTING_MD="${REPO_ROOT}/CONTRIBUTING.md"
AI_FIX="${REPO_ROOT}/.github/workflows/ai-fix.yml"
BUILD="${REPO_ROOT}/.github/workflows/build.yml"
RULESET="${REPO_ROOT}/.github/rulesets/main.json"
SECURITY_HEADING='## Agent-authored pull requests'
PROTECTION_HEADING='## Why it matters here'
WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"

for required in "${SECURITY_MD}" "${PROTECTION_MD}" "${CONTRIBUTING_MD}" "${AI_FIX}" "${BUILD}" "${RULESET}"; do
    assert_file_exists "${required#"${REPO_ROOT}/"} is present" "${required}"
done

if ! "${WORKFLOW_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    _fail "reading the workflows requires Python 3 with PyYAML" \
        "install python3-yaml (Debian/Ubuntu) or python3-pyyaml (Fedora)," \
        "or install PyYAML in the interpreter selected by WORKFLOW_PYTHON"
    finish
    exit 1
fi

# Prints the section headed $1 in $2, up to the next heading of any level, so
# "Reading the record back" stays with the test that joins it.
raw_section() {
    awk -v heading="$1" '
        $0 == heading { inside = 1; next }
        inside && /^##+ / { exit }
        inside { print }
    ' "$2"
}

squash() { tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g'; }

SECURITY="$(raw_section "${SECURITY_HEADING}" "${SECURITY_MD}" | squash)"
PROTECTION="$(raw_section "${PROTECTION_HEADING}" "${PROTECTION_MD}" | squash)"
CONTRIBUTING="$(squash <"${CONTRIBUTING_MD}")"

# A workflow as JSON. PyYAML reads the bare key `on` as true, so it is renamed.
workflow_json() {
    "${WORKFLOW_PYTHON}" -B -c '
import json, sys, yaml
with open(sys.argv[1], encoding="utf-8") as handle:
    data = yaml.safe_load(handle)
data["on"] = data.pop(True)
print(json.dumps(data))
' "$1"
}

AI_FIX_JSON="$(workflow_json "${AI_FIX}")"
BUILD_JSON="$(workflow_json "${BUILD}")"
assert_contains "ai-fix.yml parses" "${AI_FIX_JSON:+parsed}" "parsed"
assert_contains "build.yml parses" "${BUILD_JSON:+parsed}" "parsed"

fix() { jq -r "$1" <<<"${AI_FIX_JSON}"; }
build() { jq -r "$1" <<<"${BUILD_JSON}"; }
action_input() { fix ".jobs.fix.steps[] | select(.uses // \"\" | startswith(\"anthropics/claude-code-action@\")).with.\"$1\""; }

PROMPT="$(action_input prompt | squash)"
assert_contains "the fix job has a prompt to read" "${PROMPT:+present}" "present"

# --- 1. the sections and their links -----------------------------------------

assert_contains "docs/SECURITY-AI.md still has the section" "${SECURITY:+present}" "present"
assert_contains "docs/branch-protection.md still has the section" "${PROTECTION:+present}" "present"

links() {
    grep -oE '\]\([^)#]+' <<<"$1" | sed 's/^](//' | LC_ALL=C sort -u
}
link_count=0
while IFS= read -r link; do
    [[ -n "${link}" ]] || continue
    link_count=$((link_count + 1))
    assert_file_exists "the link to ${link} resolves" "${REPO_ROOT}/docs/${link}"
done < <(links "${SECURITY} ${PROTECTION}")
assert_eq "the sections link the workflow, the ruleset page and CONTRIBUTING.md" "3" "${link_count}"

# --- 2. how it starts ---------------------------------------------------------

assert_eq "ai-fix.yml has the two triggers the page names" \
    "issue_comment issues" "$(fix '.on | keys | join(" ")')"
assert_contains "the page names them" "${SECURITY}" \
    'Its triggers — `issues` and `issue_comment` — run the default branch'"'"'s copy'
assert_contains "the page says why the review triggers went" "${SECURITY}" \
    'originally also listened on `pull_request_review` and `pull_request_review_comment`'

label="$(action_input label_trigger)"
phrase="$(action_input trigger_phrase)"
prefix="$(action_input branch_prefix)"
assert_eq "the action reads the label" "ai-fix-requested" "${label}"
assert_eq "the action reads the phrase" "@claude" "${phrase}"
assert_contains "the page gives that label and phrase" "${SECURITY}" \
    "Label an issue \`${label}\`, or comment \`${phrase}\` on an issue or a pull request"
assert_contains "the page gives that branch" "${SECURITY}" \
    "opens a pull request from an \`${prefix}*\` branch"
preflight_if="$(fix '.jobs.preflight.if')"
assert_contains "preflight lets that label through" "${preflight_if}" "'${label}'"
assert_contains "preflight lets that phrase through" "${preflight_if}" "'${phrase}'"

# --- 3. who can start it ------------------------------------------------------

assert_eq "allowed_bots is empty" "" "$(action_input allowed_bots)"
assert_eq "allowed_non_write_users is empty" "" "$(action_input allowed_non_write_users)"
assert_contains "the page says both" "${SECURITY}" \
    '**A bot cannot start it.** `allowed_bots` is empty and only a user with write access can trigger it.'

# --- 4. what its token holds --------------------------------------------------

assert_eq "the workflow has no top-level permissions to add to a job's" "null" "$(fix '.permissions')"
scopes="$(fix '.jobs.fix.permissions | to_entries[] | "\(.key): \(.value)"' | LC_ALL=C sort)"
assert_contains "the fix job holds contents: write" "${scopes}" "contents: write"
assert_eq "the fix job cannot push a package" "null" "$(fix '.jobs.fix.permissions.packages')"
assert_contains "the page says so" "${SECURITY}" \
    '**It holds `contents: write`**, which the list above says needs a human decision.'
assert_contains "and that it comes without the package scope" "${SECURITY}" \
    'it comes with neither `packages: write` nor access to `SIGNING_SECRET`'

# Both ways: a scope added to the job has to reach the page, and a scope the
# page names has to be one the job holds, apart from the one it says is absent.
named="$(raw_section "${SECURITY_HEADING}" "${SECURITY_MD}" | squash \
    | grep -oE '`[a-z-]+: (read|write)`' | tr -d '`' | LC_ALL=C sort -u)"
assert_eq "the scopes the page names are the job's, plus the absent packages: write" \
    "$(printf '%s\npackages: write\n' "${scopes}" | LC_ALL=C sort -u)" "${named}"
assert_contains "the page says which scope is past the minimum" "${SECURITY}" \
    '`actions: read` goes past what opening a pull request requires'
assert_contains "the list above the section needs a human for that grant" \
    "$(squash <"${SECURITY_MD}")" \
    '**granting any new workflow `packages: write`, `contents: write`, or access to `secrets`.**'

# --- 5. why the grant is bounded ----------------------------------------------

assert_not_contains "ai-fix.yml never reads the signing secret" \
    "$(fix '[.jobs[].steps[] | tostring] | join(" ")')" "SIGNING_SECRET"
assert_eq "no ai-fix.yml job names an environment, the signing key's home" \
    "0" "$(fix '[.jobs[] | select(has("environment"))] | length')"

GATE="github.event_name != 'pull_request' && github.ref == format('refs/heads/{0}', github.event.repository.default_branch)"
assert_contains "the page quotes the first half of the gate" "${SECURITY}" \
    "gated on \`github.event_name != 'pull_request'\` *and* the default branch"

# Everything from the first gated step to the end of the job carries the gate,
# and that band holds every step that logs in, pushes, signs or copies.
gated_band="$(jq -r --arg gate "${GATE}" '
    .jobs.build_push.steps as $steps
    | ($steps | map(.if == $gate) | index(true)) as $first
    | $steps[$first:] | map(.if == $gate) | all
' <<<"${BUILD_JSON}")"
assert_eq "every step from the first gated one to the end of build_push is gated" "true" "${gated_band}"
ungated_publish="$(jq -r --arg gate "${GATE}" '
    [.jobs.build_push.steps[]
     | select(.if != $gate)
     | select((.uses // "" | test("login-action|push-to-registry|cosign-installer|attest"))
              or (.run // "" | test("cosign sign|skopeo copy|podman push"))
              or (tostring | test("SIGNING_SECRET")))
     | .name] | join(", ")
' <<<"${BUILD_JSON}")"
assert_eq "no ungated step publishes or signs" "" "${ungated_publish}"
assert_contains "the sign step is in that band" \
    "$(jq -r --arg gate "${GATE}" '[.jobs.build_push.steps[] | select(.if == $gate) | .name] | join(", ")' <<<"${BUILD_JSON}")" \
    "Sign container image"

# --- 6. what keeps it off main ------------------------------------------------

assert_eq "the ruleset is active" "active" "$(jq -r '.enforcement' "${RULESET}")"
assert_eq "the ruleset has no bypass actors" "0" "$(jq -r '.bypass_actors | length' "${RULESET}")"
assert_eq "the ruleset covers the default branch" \
    '["~DEFAULT_BRANCH"]' "$(jq -c '.conditions.ref_name.include' "${RULESET}")"
since="$(sed -nE 's/.*has been active on `main` since ([0-9-]+),.*/\1/p' "${PROTECTION_MD}")"
assert_contains "docs/branch-protection.md gives the date" "${since:+present}" "present"
assert_contains "SECURITY-AI.md gives the same date and no bypass actors" "${SECURITY}" \
    "active on \`main\` since ${since} with no bypass actors"
assert_contains "SECURITY-AI.md says the ruleset is the control" "${SECURITY}" \
    'without it the same token could push to `main` directly, and the next scheduled build would sign what it pushed.'

assert_eq "the agent gets the job's GITHUB_TOKEN, the push the page reasons about" \
    '${{ github.token }}' "$(action_input github_token)"
assert_contains "docs/branch-protection.md names that job" "${PROTECTION}" \
    'One such token is the `fix` job in [`.github/workflows/ai-fix.yml`](../.github/workflows/ai-fix.yml).'
assert_contains "docs/branch-protection.md says what that token does not start" "${PROTECTION}" \
    'A push by `GITHUB_TOKEN` does not start `build.yml` itself, but the next scheduled or manual build signs whatever `main` holds.'
assert_eq "build.yml still has a scheduled trigger" "true" "$(build '.on | has("schedule")')"
assert_eq "build.yml still has a manual trigger" "true" "$(build '.on | has("workflow_dispatch")')"

# --- 7. the prompt ------------------------------------------------------------

assert_contains "the prompt forbids pushing to main" "${PROMPT}" 'Never push to `main`'
assert_contains "the prompt names the branch the page gives" "${PROMPT}" \
    "Open a pull request from an \`${prefix}*\` branch."
assert_contains "docs/branch-protection.md reports that" "${PROTECTION}" \
    'Its prompt tells the agent never to push to `main`.'
assert_contains "and calls it no control" "${PROTECTION}" 'It is not a control.'
assert_contains "SECURITY-AI.md quotes it as an instruction" "${SECURITY}" \
    'The prompt'"'"'s "never push to `main`" is an instruction, not a control.'

assert_contains "rule 1 is on the page" "${SECURITY}" \
    '**It says what it is.** The pull request body states that an agent wrote it and what evidence exists that it works'
assert_contains "and in the prompt" "${PROMPT}" \
    'State in the pull request body that an agent wrote it, which issue or comment asked, and what evidence exists that it works.'
assert_contains "the page attributes the evidence rule to CONTRIBUTING.md" "${SECURITY}" \
    'a green shell suite is *not* evidence for a change to `build_files/` or the `Containerfile`'
assert_contains "CONTRIBUTING.md says it" "${CONTRIBUTING}" \
    'if you change `build_files/` or the `Containerfile`, a green suite is not evidence.'
assert_contains "the prompt repeats it" "${PROMPT}" \
    'a green shell suite is not evidence for a change to build_files/ or the Containerfile'

assert_contains "rule 2 is on the page" "${SECURITY}" \
    '**It never self-approves.** An agent must not apply an approval label from the list above, approve a review, or enable auto-merge.'
assert_contains "the prompt forbids merging and approving" "${PROMPT}" 'never merge, never approve.'
assert_contains "the prompt forbids an approval label" "${PROMPT}" 'Never apply a label that means approval.'

# The list on the page spells each label out; the prompt folds agent/* and
# hive/* into one pattern each. Fold the page's the same way and compare.
page_labels="$(awk '
    /^labels are:$/ { armed = 1 }
    armed && /^```text$/ { inside = 1; next }
    inside && /^```$/ { exit }
    inside { print }
' "${SECURITY_MD}" | tr -s ' ' '\n' | sed -E 's#/.*#/*#' | LC_ALL=C sort -u)"
prompt_labels="$(sed -nE 's/.*In this repository (.*) are read by an external system.*/\1/p' <<<"${PROMPT}" \
    | grep -oE '`[^`]+`' | tr -d '`' | LC_ALL=C sort -u)"
assert_contains "the page's label list was read" "${page_labels}" "testing"
assert_eq "the prompt's approval labels are the ones SECURITY-AI.md lists" "${page_labels}" "${prompt_labels}"

# --- 8. what stops a run ------------------------------------------------------

assert_eq "the fix job waits for preflight" "preflight" "$(fix '.jobs.fix.needs')"
assert_eq "and runs only on its yes" "needs.preflight.outputs.run == 'yes'" "$(fix '.jobs.fix.if')"
script="$(fix '.jobs.preflight.steps[0].run')"
assert_contains "preflight records a missing credential in the run summary" "${script}" \
    'Skipped: no agent credentials are configured on this repository.'
assert_contains "and a fork head" "${script}" 'comes from a fork.'
assert_not_contains "and never fails the run for either" "${script}" 'exit 1'
assert_contains "the page says a missing credential stops there" "${SECURITY}" \
    'every trigger currently stops at the workflow'"'"'s `preflight` job, records why in the run summary, and succeeds.'
assert_contains "the page says a fork head is skipped" "${SECURITY}" \
    'Fork pull requests are skipped rather than half-attempted'

finish
