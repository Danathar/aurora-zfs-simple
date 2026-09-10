#!/usr/bin/env bash
#
# Covers the one `run:` body of .github/workflows/auto-qa.yml — the step
# `Compare declared timeouts with observed durations`, which is the whole of
# that workflow's own logic.
#
# tests/test-auto-qa-tuning.sh reads the same workflow, but only as text: it
# greps the body for `CONFIG: .github/auto-qa-tuning.json` and for the jq path
# that iterates the manifest, and everything else it asserts is about the
# manifest rather than the shell. Nothing executed this script. It is shell
# inside a YAML string, so run-tests.sh does not find it, test-shell-syntax.sh
# does not `bash -n` it, and shellcheck never sees it either.
#
# What the body decides, and how each half fails:
#
#   1. It asks two different questions of two different samples, and the
#      workflow's own header records why: duration comes from *successful* runs,
#      because a run that failed for an unrelated reason says nothing about how
#      long the work takes — but a job killed at its cap is a *failure*, so
#      sampling successes alone made this workflow blindest exactly when it
#      mattered. Once every current run dies at the cap the only successes left
#      are older and faster, and it reported "ok" while the build was broken.
#      Lose the second query and that regression comes back silently: the row
#      still renders, the workflow still passes, and the number it prints is
#      stale rather than absent.
#
#   2. `cap_s=$((timeout_s * 98 / 100))` is what separates "killed at the cap"
#      from "failed for some other reason". The API exposes no timed-out
#      conclusion, so duration is the only signal; a job killed at 10m reports a
#      hair under 600s, and an ordinary test failure returns long before it.
#      Widen that margin to the timeout itself and the detection never fires;
#      drop the `conclusion == "failure"` filter and every slow success is
#      reported as a run that was killed.
#
#   3. Only **at risk** exits non-zero. "Loose" is written to the summary and
#      never fails, because a red workflow nobody has to act on trains people to
#      ignore red workflows. And the at-risk arm `continue`s: without it a job
#      already dying at its cap renders a second, contradictory row from the
#      stale duration below.
#
#   4. It proposes rather than edits — it writes to $GITHUB_STEP_SUMMARY and
#      leaves the manifest alone.
#
# Each case runs the extracted body as a real subprocess against a recording
# `gh` stub backed by JSON fixtures, with the step's env and a manifest written
# for the case. The stub honours `--jq` by piping the fixture through the real
# jq, so the filter in the workflow is load-bearing rather than decoration; the
# arithmetic, the awk ratio comparisons and the table are the real ones.
#
# The YAML is read with PyYAML, as test-build-publish.sh, test-build-rechunk.sh,
# test-ai-fix.sh and test-nightly-compliance.sh do: this is a block scalar, and
# re-deriving its indentation with sed is a second implementation that can
# disagree with the one Actions uses. The `on:` key is the known trap — YAML 1.1
# reads a bare `on` as the boolean true — so the normalizer renames it back and
# is checked against a fixture with a known answer before it is trusted.

set -uo pipefail

TEST_NAME="test-auto-qa-run"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

AUTO_QA_WF="${REPO_ROOT}/.github/workflows/auto-qa.yml"
WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

if [[ ! -f "${AUTO_QA_WF}" ]]; then
    _fail "auto-qa.yml exists" \
        "no such file: ${AUTO_QA_WF}" \
        "if the workflow was removed on purpose, delete this test with it"
    finish
    exit 1
fi

# This decides whether a CI timeout is reported as drifting; a missing parser
# must fail rather than skip, including when the file is invoked directly
# instead of through run-tests.sh.
if ! "${WORKFLOW_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    _fail "the auto-qa.yml step check requires Python 3 with PyYAML" \
        "install python3-yaml (Debian/Ubuntu) or python3-pyyaml (Fedora)," \
        "or install PyYAML in the interpreter selected by WORKFLOW_PYTHON"
    finish
    exit 1
fi

# --- normalizer -------------------------------------------------------------

NORMALIZER="${TMP_ROOT}/normalize.py"
cat >"${NORMALIZER}" <<'PY'
"""Print one workflow file as JSON, with the `on:` key readable by name.

YAML 1.1 -- which is what PyYAML implements, and what Actions accepts -- reads a
bare `on` as the boolean true, so `doc["on"]` raises KeyError on every workflow
ever written. Renaming it here keeps that quirk in one place instead of in
every jq path below.
"""

import json
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = yaml.safe_load(handle)

if isinstance(doc, dict) and True in doc:
    doc["on"] = doc.pop(True)

json.dump(doc, sys.stdout)
PY

# --- the normalizer is tested before it is trusted --------------------------

fixture="${TMP_ROOT}/fixture.yml"
cat >"${fixture}" <<'YAML'
---
name: Fixture
on:
  schedule:
    - cron: '15 08 * * 1'
jobs:
  tune:
    steps:
      - name: Named step
        env:
          REPO: ${{ github.repository }}
        run: |
          echo marker
YAML

fixture_json="${TMP_ROOT}/fixture.json"
if "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${fixture}" >"${fixture_json}" 2>"${TMP_ROOT}/fixture.err"; then
    assert_eq "the normalizer reads a fixture's schedule by name" \
        "15 08 * * 1" "$(jq -r '.on.schedule[0].cron' <"${fixture_json}")"
    assert_eq "the normalizer reads a fixture's block-scalar run: body" \
        "echo marker" "$(jq -r '.jobs.tune.steps[0].run' <"${fixture_json}")"
    # shellcheck disable=SC2016 # an Actions expression, compared as literal text
    assert_eq "the normalizer reads a fixture step's env: block" \
        '${{ github.repository }}' \
        "$(jq -r '.jobs.tune.steps[] | select(.name == "Named step") | .env.REPO' <"${fixture_json}")"
else
    _fail "the normalizer parses a fixture workflow" "$(cat "${TMP_ROOT}/fixture.err")"
fi

# --- the real file ----------------------------------------------------------

WF_JSON="${TMP_ROOT}/auto-qa.json"
if ! "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${AUTO_QA_WF}" >"${WF_JSON}" 2>"${TMP_ROOT}/wf.err"; then
    _fail "auto-qa.yml parses as YAML" "$(cat "${TMP_ROOT}/wf.err")"
    finish
    exit 1
fi
_pass "auto-qa.yml parses as YAML"

wf() {
    jq -r "$1" <"${WF_JSON}"
}

STEP_NAME="Compare declared timeouts with observed durations"

STEP="${TMP_ROOT}/compare.sh"
wf ".jobs.tune.steps[] | select(.name == \"${STEP_NAME}\") | .run // \"\"" >"${STEP}"
if [[ ! -s "${STEP}" ]] || ! grep -q -- 'at_risk_ratio' "${STEP}"; then
    _fail "the '${STEP_NAME}' script was extracted from auto-qa.yml" \
        "expected a run: body reading .policy.at_risk_ratio; extracted" \
        "$(wc -c <"${STEP}") byte(s) from the tune job" \
        "the step name probably changed — update this test to match"
    finish
    exit 1
fi
_pass "the '${STEP_NAME}' script was extracted from auto-qa.yml"

# The env the body reads. GH_TOKEN is the credential the stub stands in for;
# REPO and CONFIG are supplied per case below, and are asserted here so a step
# that stopped taking them from the workflow cannot leave every case silently
# reading this repository's real manifest instead.
# shellcheck disable=SC2016 # Actions expressions, compared as literal text
assert_eq "the step still takes its token from the workflow's github.token" \
    '${{ github.token }}' \
    "$(wf ".jobs.tune.steps[] | select(.name == \"${STEP_NAME}\") | .env.GH_TOKEN")"
# shellcheck disable=SC2016
assert_eq "the step still takes the repository it samples from the event" \
    '${{ github.repository }}' \
    "$(wf ".jobs.tune.steps[] | select(.name == \"${STEP_NAME}\") | .env.REPO")"

# Read-only over the Actions API, and no write scope at all: this workflow
# reports a number, it does not edit a timeout.
assert_eq "the job that runs it can read the run history" \
    "read" "$(wf '.jobs.tune.permissions.actions')"
assert_eq "and cannot write to the repository" \
    "read" "$(wf '.jobs.tune.permissions.contents')"

# --- fixtures ---------------------------------------------------------------

# A fixed epoch, so a case's durations are the only thing that varies.
BASE_EPOCH=1767225600 # 2026-01-01T00:00:00Z

# write_config <path> <sample> <at_risk> <loose> [<workflow>|<job>|<minutes>]...
write_config() {
    local path=$1 sample=$2 at_risk=$3 loose=$4
    shift 4

    local jobs="[]" entry name job minutes
    for entry in "$@"; do
        IFS='|' read -r name job minutes <<<"${entry}"
        jobs="$(jq --arg w "${name}" --arg j "${job}" --argjson t "${minutes}" \
            '. + [{workflow: $w, job: $j, timeout_minutes: $t}]' <<<"${jobs}")"
    done

    jq -n --argjson s "${sample}" --argjson a "${at_risk}" --argjson l "${loose}" \
        --argjson jobs "${jobs}" \
        '{policy: {statistic: "max", sample_size: $s, at_risk_ratio: $a, loose_ratio: $l},
          jobs: $jobs}' >"${path}"
}

# runs_fixture <case dir> <workflow file> <status> [<run id>...] — the payload
# the run listing returns. An empty id list is a real answer, not a missing
# fixture: it is what a workflow with no runs of that status looks like.
runs_fixture() {
    local dir=$1 workflow=$2 status=$3
    shift 3

    local runs="[]" id
    for id in "$@"; do
        runs="$(jq --argjson i "${id}" '. + [{id: $i}]' <<<"${runs}")"
    done

    mkdir -p "${dir}/api"
    jq -n --argjson r "${runs}" '{workflow_runs: $r}' \
        >"${dir}/api/runs-${workflow}-${status}.json"
}

# jobs_fixture <case dir> <run id> [<job name>|<conclusion>|<seconds>]... —
# the jobs of one run. A seconds value of `null` writes null timestamps, which
# is the case the body's `select(.started_at != null ...)` exists for.
jobs_fixture() {
    local dir=$1 id=$2
    shift 2

    local jobs="[]" entry name conclusion seconds started completed
    for entry in "$@"; do
        IFS='|' read -r name conclusion seconds <<<"${entry}"
        if [[ "${seconds}" == "null" ]]; then
            jobs="$(jq --arg n "${name}" --arg c "${conclusion}" \
                '. + [{name: $n, conclusion: $c, started_at: null, completed_at: null}]' \
                <<<"${jobs}")"
            continue
        fi
        started="$(date -u -d "@${BASE_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)"
        completed="$(date -u -d "@$((BASE_EPOCH + seconds))" +%Y-%m-%dT%H:%M:%SZ)"
        jobs="$(jq --arg n "${name}" --arg c "${conclusion}" \
            --arg s "${started}" --arg e "${completed}" \
            '. + [{name: $n, conclusion: $c, started_at: $s, completed_at: $e}]' \
            <<<"${jobs}")"
    done

    mkdir -p "${dir}/api"
    jq -n --argjson j "${jobs}" '{jobs: $j}' >"${dir}/api/jobs-${id}.json"
}

# make_gh <case dir> — a recording `gh` backed by the case's fixtures.
#
# It answers the two shapes the body asks for and refuses anything else, and it
# applies `--jq` through the real jq rather than ignoring it, so the filter the
# workflow passes is exercised: a filter that stopped selecting run ids would
# produce an empty sample here rather than a test that cannot tell.
make_gh() {
    local dir=$1
    mkdir -p "${dir}/bin" "${dir}/api"
    : >"${dir}/gh-calls"

    cat >"${dir}/bin/gh" <<PY
#!/usr/bin/env bash
dir=${dir@Q}
printf '%s\n' "\$*" >>"\${dir}/gh-calls"

if [ "\$1" != "api" ]; then
    printf 'gh stub: unexpected subcommand: %s\n' "\$1" >&2
    exit 1
fi

url=\$2
shift 2

filter=""
while [ "\$#" -gt 0 ]; do
    case "\$1" in
        --jq) filter=\$2; shift 2 ;;
        *) shift ;;
    esac
done

fixture=""
case "\${url}" in
    */actions/workflows/*/runs\?*)
        workflow=\${url#*/actions/workflows/}
        workflow=\${workflow%%/runs\?*}
        query=\${url#*/runs\?}
        status=\${query#status=}
        status=\${status%%&*}
        fixture="\${dir}/api/runs-\${workflow}-\${status}.json"
        ;;
    */actions/runs/*/jobs)
        run_id=\${url#*/actions/runs/}
        run_id=\${run_id%/jobs}
        fixture="\${dir}/api/jobs-\${run_id}.json"
        ;;
esac

if [ -z "\${fixture}" ] || [ ! -f "\${fixture}" ]; then
    printf 'gh stub: no fixture for %s\n' "\${url}" >&2
    exit 1
fi

if [ -n "\${filter}" ]; then
    jq -r "\${filter}" <"\${fixture}"
else
    cat "\${fixture}"
fi
PY
    chmod +x "${dir}/bin/gh"
}

# new_case <name> — a case directory with a stub gh already in it.
new_case() {
    local dir
    dir="$(mktemp -d "${TMP_ROOT}/$1.XXXXXX")"
    make_gh "${dir}"
    printf '%s' "${dir}"
}

# run_step <case dir> <config path> — execute the extracted body.
run_step() {
    local dir=$1 config=$2
    : >"${dir}/summary.md"

    PATH="${dir}/bin:${PATH}" \
        GH_TOKEN="stub-token" \
        REPO="Danathar/aurora-zfs-simple" \
        CONFIG="${config}" \
        GITHUB_STEP_SUMMARY="${dir}/summary.md" \
        bash "${STEP}" >"${dir}/out" 2>"${dir}/err"
    printf '%s' "$?" >"${dir}/status"
}

status_of() { cat "$1/status"; }
summary_of() { cat "$1/summary.md"; }
out_of() { cat "$1/out"; }
calls_of() { cat "$1/gh-calls"; }

# row_for <case dir> <workflow> <job> — the summary row for one manifest entry.
row_for() {
    grep -F "| $2 | $3 |" "$1/summary.md"
}

# =============================================================================
# A. a job comfortably inside its timeout
# =============================================================================

ok_dir="$(new_case ok)"
ok_config="${ok_dir}/tuning.json"
write_config "${ok_config}" 3 0.75 0.2 'build.yml|Build and push image|10'
runs_fixture "${ok_dir}" "build.yml" "success" 11 12
runs_fixture "${ok_dir}" "build.yml" "completed" 11 12
# The slowest sampled run is deliberately not the last one read: the statistic
# is the maximum, and a body that kept whichever it saw last would still fill
# the row.
jobs_fixture "${ok_dir}" 11 'Build and push image|success|300'
jobs_fixture "${ok_dir}" 12 'Build and push image|success|200'
run_step "${ok_dir}" "${ok_config}"

assert_eq "a job inside its timeout does not fail the workflow" \
    "0" "$(status_of "${ok_dir}")"
assert_contains "the summary is headed for a step summary reader" \
    "$(summary_of "${ok_dir}")" "### Auto-QA tuning"
assert_contains "it says how many runs it sampled" \
    "$(summary_of "${ok_dir}")" "Slowest of the last 3 successful runs"
assert_contains "and names the manifest the numbers came from" \
    "$(summary_of "${ok_dir}")" "${ok_config}"
assert_contains "it writes the table header" \
    "$(summary_of "${ok_dir}")" "| Workflow | Job | Timeout | Slowest run | Verdict |"
assert_eq "the row reports the slowest sampled run, not the last or the mean" \
    "| build.yml | Build and push image | 10m | 5m0s | ok |" \
    "$(row_for "${ok_dir}" "build.yml" "Build and push image")"
assert_not_contains "and it raises no workflow error" \
    "$(out_of "${ok_dir}")" "::error::"
assert_contains "the closing note records that only at risk fails" \
    "$(summary_of "${ok_dir}")" "Only **at risk** fails this workflow"

# The two questions, and the two samples they need. A body that asked for
# successes twice would still produce the row above.
assert_contains "it samples successful runs at the configured sample size" \
    "$(calls_of "${ok_dir}")" \
    "repos/Danathar/aurora-zfs-simple/actions/workflows/build.yml/runs?status=success&per_page=3"
assert_contains "and samples completed runs too, which is where a killed job is" \
    "$(calls_of "${ok_dir}")" \
    "repos/Danathar/aurora-zfs-simple/actions/workflows/build.yml/runs?status=completed&per_page=3"
assert_eq "the completed listing is a query of its own, asked once" \
    "1" "$(grep -c -- 'status=completed' "${ok_dir}/gh-calls")"
assert_eq "each sampled run is opened for its jobs" \
    "4" "$(grep -c -- '/actions/runs/1[12]/jobs' "${ok_dir}/gh-calls")"

# It proposes rather than edits: nothing here rewrites the manifest.
assert_eq "the manifest it read is left exactly as it found it" \
    "$(write_config "${ok_dir}/expected.json" 3 0.75 0.2 'build.yml|Build and push image|10'
       cat "${ok_dir}/expected.json")" \
    "$(cat "${ok_config}")"

# =============================================================================
# B. grown into the timeout, and the boundary either side of the ratio
# =============================================================================

# 500s of a 600s timeout is past 0.75 of it.
risk_dir="$(new_case at-risk)"
risk_config="${risk_dir}/tuning.json"
write_config "${risk_config}" 3 0.75 0.2 'build.yml|Build and push image|10'
runs_fixture "${risk_dir}" "build.yml" "success" 21
runs_fixture "${risk_dir}" "build.yml" "completed" 21
jobs_fixture "${risk_dir}" 21 'Build and push image|success|500'
run_step "${risk_dir}" "${risk_config}"

assert_eq "a job grown past the at-risk ratio fails the workflow" \
    "1" "$(status_of "${risk_dir}")"
assert_contains "the row says raise the timeout or make the job faster" \
    "$(row_for "${risk_dir}" "build.yml" "Build and push image")" \
    "**at risk** — raise the timeout or make the job faster"
assert_contains "and an annotation names the ratio it exceeded" \
    "$(out_of "${risk_dir}")" \
    "::error::build.yml / Build and push image: slowest run 8m20s exceeds 0.75 of its 10m timeout"

# Exactly at the ratio is not past it, and is not loose either.
edge_dir="$(new_case at-ratio)"
edge_config="${edge_dir}/tuning.json"
write_config "${edge_config}" 3 0.75 0.2 'build.yml|Build and push image|10'
runs_fixture "${edge_dir}" "build.yml" "success" 31
runs_fixture "${edge_dir}" "build.yml" "completed" 31
jobs_fixture "${edge_dir}" 31 'Build and push image|success|450'
run_step "${edge_dir}" "${edge_config}"

assert_eq "a run exactly at the ratio is not yet at risk" \
    "0" "$(status_of "${edge_dir}")"
assert_eq "and reads as ok rather than loose" \
    "| build.yml | Build and push image | 10m | 7m30s | ok |" \
    "$(row_for "${edge_dir}" "build.yml" "Build and push image")"

# Far under the timeout is advisory only. A red workflow nobody has to act on
# trains people to ignore red workflows, so this must not fail.
loose_dir="$(new_case loose)"
loose_config="${loose_dir}/tuning.json"
write_config "${loose_config}" 3 0.75 0.2 'build.yml|Build and push image|10'
runs_fixture "${loose_dir}" "build.yml" "success" 41
runs_fixture "${loose_dir}" "build.yml" "completed" 41
jobs_fixture "${loose_dir}" 41 'Build and push image|success|100'
run_step "${loose_dir}" "${loose_config}"

assert_eq "a timeout looser than it needs to be does not fail the workflow" \
    "0" "$(status_of "${loose_dir}")"
assert_contains "it is reported as advisory" \
    "$(row_for "${loose_dir}" "build.yml" "Build and push image")" \
    "loose — could tighten (advisory)"
assert_not_contains "with no annotation to act on" \
    "$(out_of "${loose_dir}")" "::error::"

# =============================================================================
# C. the killed-at-the-cap query, which is the blind spot the body exists for
# =============================================================================

# The regression in its original form: every current run dies at the cap, so
# the success listing is empty and the only evidence is in a failure.
killed_dir="$(new_case killed)"
killed_config="${killed_dir}/tuning.json"
write_config "${killed_config}" 3 0.75 0.2 'build.yml|Build and push image|10'
runs_fixture "${killed_dir}" "build.yml" "success"
runs_fixture "${killed_dir}" "build.yml" "completed" 51
jobs_fixture "${killed_dir}" 51 'Build and push image|failure|595'
run_step "${killed_dir}" "${killed_config}"

assert_eq "a job already being killed at its cap fails the workflow" \
    "1" "$(status_of "${killed_dir}")"
assert_contains "even with no successful run left to measure" \
    "$(row_for "${killed_dir}" "build.yml" "Build and push image")" \
    "**at risk** — a run has already been killed at the cap"
assert_contains "the row still shows the sample is empty rather than inventing one" \
    "$(row_for "${killed_dir}" "build.yml" "Build and push image")" \
    "_no successful runs sampled_"
assert_contains "and the annotation names the timeout it was killed at" \
    "$(out_of "${killed_dir}")" \
    "::error::build.yml / Build and push image: a run was killed at its 10m timeout"
assert_eq "the killed-at-the-cap arm renders one row, not two" \
    "1" "$(row_for "${killed_dir}" "build.yml" "Build and push image" | wc -l)"

# A failure that ran to within 2% of the cap was killed by it; the margin is
# what makes that decidable, since the API exposes no timed-out conclusion.
margin_dir="$(new_case cap-margin)"
margin_config="${margin_dir}/tuning.json"
write_config "${margin_config}" 3 0.75 0.2 'build.yml|Build and push image|10'
runs_fixture "${margin_dir}" "build.yml" "success"
runs_fixture "${margin_dir}" "build.yml" "completed" 61
jobs_fixture "${margin_dir}" 61 'Build and push image|failure|588'
run_step "${margin_dir}" "${margin_config}"

assert_eq "a failure at 98% of the cap counts as killed by it" \
    "1" "$(status_of "${margin_dir}")"
assert_contains "and is reported as the cap, not as an ordinary failure" \
    "$(row_for "${margin_dir}" "build.yml" "Build and push image")" \
    "a run has already been killed at the cap"

# An ordinary test failure returns long before the cap and says nothing about
# duration. Reporting it as a timeout would be a false alarm on every red run.
short_dir="$(new_case short-failure)"
short_config="${short_dir}/tuning.json"
write_config "${short_config}" 3 0.75 0.2 'build.yml|Build and push image|10'
runs_fixture "${short_dir}" "build.yml" "success" 71
runs_fixture "${short_dir}" "build.yml" "completed" 71 72
jobs_fixture "${short_dir}" 71 'Build and push image|success|200'
jobs_fixture "${short_dir}" 72 'Build and push image|failure|100'
run_step "${short_dir}" "${short_config}"

assert_eq "a failure well short of the cap is not a timeout" \
    "0" "$(status_of "${short_dir}")"
assert_eq "and leaves the verdict on the successful sample" \
    "| build.yml | Build and push image | 10m | 3m20s | ok |" \
    "$(row_for "${short_dir}" "build.yml" "Build and push image")"

# A slow *success* is not evidence of a kill: the second query filters on
# conclusion, and without that filter every job near its cap reads as killed.
slowok_dir="$(new_case slow-success)"
slowok_config="${slowok_dir}/tuning.json"
write_config "${slowok_config}" 3 0.99 0.2 'build.yml|Build and push image|10'
runs_fixture "${slowok_dir}" "build.yml" "success" 81
runs_fixture "${slowok_dir}" "build.yml" "completed" 81
jobs_fixture "${slowok_dir}" 81 'Build and push image|success|588'
run_step "${slowok_dir}" "${slowok_config}"

assert_eq "a run that finished successfully at the cap margin was not killed" \
    "0" "$(status_of "${slowok_dir}")"
assert_not_contains "so no kill is reported" \
    "$(summary_of "${slowok_dir}")" "killed at the cap"
assert_eq "and its duration is still the one measured" \
    "| build.yml | Build and push image | 10m | 9m48s | ok |" \
    "$(row_for "${slowok_dir}" "build.yml" "Build and push image")"

# =============================================================================
# D. which jobs of a sampled run count
# =============================================================================

# A run holds every job of its workflow. Matching on the name is what keeps a
# 90-minute build out of the row for a 10-minute test job.
select_dir="$(new_case select)"
select_config="${select_dir}/tuning.json"
write_config "${select_config}" 3 0.75 0.2 'build.yml|Shell tests|10'
runs_fixture "${select_dir}" "build.yml" "success" 91
runs_fixture "${select_dir}" "build.yml" "completed" 91
#
# The job with null timestamps is listed *first* on purpose. Its guard is not a
# style choice: `fromdateiso8601` on a null aborts the whole jq program, so a
# body without it loses every duration after the first job still running or
# still queued — and the row it then prints reads "no successful runs sampled",
# which is indistinguishable from a workflow nobody has run.
jobs_fixture "${select_dir}" 91 \
    'Build and push image|success|5000' \
    'Shell tests|success|null' \
    'Shell tests|success|240' \
    'Shell tests|cancelled|4000'
run_step "${select_dir}" "${select_config}"

assert_eq "sampling one job ignores the other jobs of the same run" \
    "0" "$(status_of "${select_dir}")"
assert_eq "only the named job's successful, timestamped runs are measured" \
    "| build.yml | Shell tests | 10m | 4m0s | ok |" \
    "$(row_for "${select_dir}" "build.yml" "Shell tests")"

# No runs at all is a reported absence, not a verdict: there is nothing to
# compare, and inventing a zero would read as a very fast job.
empty_dir="$(new_case empty)"
empty_config="${empty_dir}/tuning.json"
write_config "${empty_config}" 3 0.75 0.2 'labeler.yml|Apply area labels|5'
runs_fixture "${empty_dir}" "labeler.yml" "success"
runs_fixture "${empty_dir}" "labeler.yml" "completed"
run_step "${empty_dir}" "${empty_config}"

assert_eq "a job with no sampled runs does not fail the workflow" \
    "0" "$(status_of "${empty_dir}")"
assert_eq "and renders as an absence with no verdict" \
    "| labeler.yml | Apply area labels | 5m | _no successful runs sampled_ | — |" \
    "$(row_for "${empty_dir}" "labeler.yml" "Apply area labels")"

# =============================================================================
# E. the whole manifest, and how one bad entry affects the rest
# =============================================================================

many_dir="$(new_case manifest)"
many_config="${many_dir}/tuning.json"
write_config "${many_config}" 3 0.75 0.2 \
    'build.yml|Build and push image|10' \
    'coverage-gate.yml|Shell tests|10' \
    'labeler.yml|Apply area labels|5'
runs_fixture "${many_dir}" "build.yml" "success"
runs_fixture "${many_dir}" "build.yml" "completed" 101
jobs_fixture "${many_dir}" 101 'Build and push image|failure|595'
runs_fixture "${many_dir}" "coverage-gate.yml" "success" 102
runs_fixture "${many_dir}" "coverage-gate.yml" "completed" 102
jobs_fixture "${many_dir}" 102 'Shell tests|success|300'
runs_fixture "${many_dir}" "labeler.yml" "success" 103
runs_fixture "${many_dir}" "labeler.yml" "completed" 103
jobs_fixture "${many_dir}" 103 'Apply area labels|success|280'
run_step "${many_dir}" "${many_config}"

assert_eq "one at-risk entry fails the workflow" \
    "1" "$(status_of "${many_dir}")"
assert_eq "the entry killed at its cap is reported" \
    "1" "$(row_for "${many_dir}" "build.yml" "Build and push image" | grep -c 'killed at the cap')"
assert_contains "the entry after it is still sampled and reported" \
    "$(row_for "${many_dir}" "coverage-gate.yml" "Shell tests")" \
    "| coverage-gate.yml | Shell tests | 10m | 5m0s | ok |"
assert_contains "and so is the last one, at risk on its own tighter timeout" \
    "$(row_for "${many_dir}" "labeler.yml" "Apply area labels")" \
    "raise the timeout or make the job faster"
assert_eq "every manifest entry produces exactly one row" \
    "3" "$(grep -c '^| [a-z-]*\.yml | ' "${many_dir}/summary.md")"
assert_eq "each entry is sampled against its own workflow file" \
    "1" "$(grep -c -- 'workflows/coverage-gate.yml/runs?status=success' "${many_dir}/gh-calls")"

finish
