#!/usr/bin/env bash
#
# Covers .github/workflows/nightly-compliance.yml — the four `run:` bodies that
# decide, once a day and with nobody watching, whether the published image is
# still the image this repository tells consumers to trust.
#
# Nothing in this repository executed them. They are shell inside YAML strings,
# so they are not *.sh files: run-tests.sh does not find them, test-shell-syntax.sh
# does not `bash -n` them, and shellcheck never sees them. test-ci-workflows.sh
# reads this file, but only statically — it asserts that the `suite` job has
# installed shellcheck by the time it runs the suite, and nothing about the
# `published_image` job's logic.
#
# That logic is where the workflow's whole value sits, and its two failure modes
# are silent in opposite directions:
#
#   1. The "Resolve the published :latest" step draws one line between "nothing
#      was ever published here" (exempt, exit 0, every later step skipped) and
#      "the image stopped being readable" (fatal). The file's own header says
#      treating any inspect failure as absence — the earlier behaviour — made
#      the two loudest incidents this job exists for indistinguishable from a
#      quiet green run. The line is drawn by one `grep -qiE` over skopeo's
#      stderr, and widening it re-creates that bug with no test to notice: a
#      `manifest unknown` (`:latest` deleted or repointed) or an `unauthorized`
#      would once again report success.
#
#   2. The "Verify the date tags still share that digest" step accumulates a
#      status across two tags. An absent tag is a warning and a `continue`; a
#      present tag that disagrees is a failure. If a later matching tag reset
#      the accumulator — the obvious way to write this wrong, and the reason the
#      loop uses `status=1` rather than `exit 1` — a repointed `latest.YYYYMMDD`
#      would be reported on stdout and the job would still be green.
#
# So each step's `run:` body is extracted from the YAML and executed as a real
# subprocess, with `skopeo` and `cosign` stubbed on PATH and the step's `env:`
# block supplied case by case. What is asserted is what the *next* step and the
# job status consume: the `GITHUB_OUTPUT` keys, the exit code, the `::error::`
# and `::warning::` annotations, and the `GITHUB_STEP_SUMMARY` a human reads.
#
# The `if:` guards are asserted alongside, because the exemption in (1) only
# means anything if the steps after it are actually gated on `present`: without
# those guards, the "nothing published" path runs `cosign verify` against an
# empty digest and the exempt case fails anyway.
#
# The YAML is read with PyYAML rather than by hand, for the same reason
# test-ai-fix.sh does: these `run:` bodies are block scalars, and re-deriving
# their indentation with sed is a second implementation that can disagree with
# the one Actions uses. The `on:` key is the known trap — YAML 1.1 reads a bare
# `on` as the boolean true — so the normalizer renames it back and is checked
# against a fixture with a known answer before it is trusted on the real file.

set -uo pipefail

TEST_NAME="test-nightly-compliance"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

NIGHTLY_WF="${REPO_ROOT}/.github/workflows/nightly-compliance.yml"
WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

if [[ ! -f "${NIGHTLY_WF}" ]]; then
    _fail "nightly-compliance.yml exists" \
        "no such file: ${NIGHTLY_WF}" \
        "if the workflow was removed on purpose, delete this test with it"
    finish
    exit 1
fi

# This checks whether a published image is still signed; a missing parser must
# fail rather than skip, including when the file is invoked directly instead of
# through run-tests.sh.
if ! "${WORKFLOW_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    _fail "the nightly-compliance.yml checker requires Python 3 with PyYAML" \
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
    - cron: '30 07 * * *'
jobs:
  demo:
    steps:
      - name: Named step
        if: steps.other.outputs.present == 'true'
        run: |
          echo marker
YAML

fixture_json="${TMP_ROOT}/fixture.json"
if "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${fixture}" >"${fixture_json}" 2>"${TMP_ROOT}/fixture.err"; then
    assert_eq "the normalizer reads a fixture's schedule by name" \
        "30 07 * * *" "$(jq -r '.on.schedule[0].cron' <"${fixture_json}")"
    assert_eq "the normalizer reads a fixture's block-scalar run: body" \
        "echo marker" "$(jq -r '.jobs.demo.steps[0].run' <"${fixture_json}")"
    assert_eq "the normalizer reads a fixture's step selected by name" \
        "steps.other.outputs.present == 'true'" \
        "$(jq -r '.jobs.demo.steps[] | select(.name == "Named step") | .if' <"${fixture_json}")"
else
    _fail "the normalizer parses a fixture workflow" "$(cat "${TMP_ROOT}/fixture.err")"
fi

# --- the real file ----------------------------------------------------------

WF_JSON="${TMP_ROOT}/nightly.json"
if ! "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${NIGHTLY_WF}" >"${WF_JSON}" 2>"${TMP_ROOT}/wf.err"; then
    _fail "nightly-compliance.yml parses as YAML" "$(cat "${TMP_ROOT}/wf.err")"
    finish
    exit 1
fi
_pass "nightly-compliance.yml parses as YAML"

# wf <jq expression> — one value out of the parsed workflow.
wf() {
    jq -r "$1" <"${WF_JSON}"
}

# step_run <step name> — the run: body of one step of the published_image job.
step_run() {
    wf ".jobs.published_image.steps[] | select(.name == \"$1\") | .run"
}

# step_if <step name> — that step's `if:` guard, or the empty string.
step_if() {
    wf ".jobs.published_image.steps[] | select(.name == \"$1\") | .if // \"\""
}

# extract <destination> <step name> <marker> — pull a run: body out and refuse
# to continue with an empty or unrecognisable one. Without this, a renamed step
# would leave every case below running an empty file: exit 0, no output, no
# annotation, and assertions that pass while measuring nothing.
extract() {
    local dest=$1 name=$2 marker=$3
    step_run "${name}" >"${dest}"
    if [[ ! -s "${dest}" ]] || ! grep -q -- "${marker}" "${dest}"; then
        _fail "the '${name}' script was extracted from nightly-compliance.yml" \
            "expected a run: body containing ${marker}; extracted" \
            "$(wc -c <"${dest}") byte(s) from the published_image job" \
            "the step name probably changed — update this test to match"
        finish
        exit 1
    fi
    _pass "the '${name}' script was extracted from nightly-compliance.yml"
}

TEST_IMAGE="ghcr.io/danathar/aurora-zfs-simple"
TEST_ACTOR="a-runner"
TEST_TOKEN="not-a-real-token"
DIGEST_A="sha256:1111111111111111111111111111111111111111111111111111111111111111"
DIGEST_B="sha256:2222222222222222222222222222222222222222222222222222222222222222"

# =============================================================================
# A. "Prepare environment" — the case fold GHCR requires
# =============================================================================
#
# `github.repository_owner` is the account's display spelling, and this repo's
# is `Danathar`. A registry reference with an uppercase letter in it is not a
# valid one, so every skopeo and cosign call below depends on this one line.

PREPARE="${TMP_ROOT}/prepare.sh"
extract "${PREPARE}" "Prepare environment" 'GITHUB_ENV'

prepare_dir="$(mktemp -d "${TMP_ROOT}/prepare.XXXXXX")"
: >"${prepare_dir}/env"
IMAGE_REF="ghcr.io/Danathar/Aurora-ZFS-Simple" \
    GITHUB_ENV="${prepare_dir}/env" \
    bash "${PREPARE}" >/dev/null 2>&1
assert_eq "the prepare step lower-cases the image reference for GHCR" \
    "IMAGE_REF=ghcr.io/danathar/aurora-zfs-simple" \
    "$(cat "${prepare_dir}/env")"

# =============================================================================
# B. "Resolve the published :latest" — the exemption, executed
# =============================================================================

RESOLVE="${TMP_ROOT}/resolve.sh"
extract "${RESOLVE}" "Resolve the published :latest" 'present='

# resolve <skopeo stdout JSON, or ""> <skopeo stderr when it fails>
#
# Runs the extracted script in its own directory — it writes err.txt into the
# working directory — with a stub `skopeo` that either prints the canned inspect
# payload and succeeds, or prints the canned message on stderr and fails. Both
# are real skopeo behaviours; which one it is, is the decision under test.
#
# Sets R_STATUS, R_STDOUT, R_OUTPUT and R_CALLS.
resolve() {
    local ok_json=$1 err_text=$2 dir

    dir="$(mktemp -d "${TMP_ROOT}/resolve.XXXXXX")"
    mkdir -p "${dir}/bin"
    printf '%s' "${ok_json}" >"${dir}/skopeo.out"
    printf '%s\n' "${err_text}" >"${dir}/skopeo.err"
    : >"${dir}/calls"
    : >"${dir}/output"

    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "%%s\\n" "$*" >> %q\n' "${dir}/calls"
        printf 'if [ -s %q ]; then cat %q; exit 0; fi\n' \
            "${dir}/skopeo.out" "${dir}/skopeo.out"
        printf 'cat %q >&2\nexit 1\n' "${dir}/skopeo.err"
    } >"${dir}/bin/skopeo"
    chmod +x "${dir}/bin/skopeo"

    R_STDOUT="$(
        cd "${dir}" &&
            PATH="${dir}/bin:${PATH}" \
                IMAGE_REF="${TEST_IMAGE}" \
                REGISTRY_ACTOR="${TEST_ACTOR}" \
                REGISTRY_TOKEN="${TEST_TOKEN}" \
                GITHUB_OUTPUT="${dir}/output" \
                bash "${RESOLVE}" 2>&1
    )"
    R_STATUS=$?
    R_OUTPUT="$(cat "${dir}/output")"
    R_CALLS="$(cat "${dir}/calls")"
}

# out_value <key> — one key out of the captured GITHUB_OUTPUT, or "" if absent.
out_value() {
    local key=$1
    grep -m1 "^${key}=" <<<"${R_OUTPUT}" | cut -d= -f2- || true
}

# --- published, and readable ------------------------------------------------
#
# The `Created` timestamp deliberately carries a non-UTC offset that lands on
# the previous day locally. build.yml derives its date tags in UTC, so the tag
# this step goes looking for is 20260102, not 20260101 — which is what `date -u`
# is doing in that line and what dropping the -u would silently change.

resolve "$(printf '{"Digest":"%s","Created":"2026-01-01T23:30:00-05:00"}' "${DIGEST_A}")" ""
assert_eq "a readable :latest exits 0" "0" "${R_STATUS}"
assert_eq "a readable :latest reports present=true" "true" "$(out_value present)"
assert_eq "a readable :latest publishes the digest it resolved" \
    "${DIGEST_A}" "$(out_value digest)"
assert_eq "the date tag is derived from the image's creation time in UTC" \
    "20260102" "$(out_value date_tag)"
assert_contains "the inspect is authenticated with the registry credentials" \
    "${R_CALLS}" "--creds ${TEST_ACTOR}:${TEST_TOKEN}"
assert_contains "the inspect targets :latest of the job's image reference" \
    "${R_CALLS}" "docker://${TEST_IMAGE}:latest"

# --- never published: the one narrow exemption ------------------------------

resolve "" "time=\"2026-01-01T00:00:00Z\" level=fatal msg=\"initializing source docker://${TEST_IMAGE}:latest: reading manifest latest: name unknown\""
assert_eq "a name the registry has never heard of exits 0" "0" "${R_STATUS}"
assert_eq "a never-published image reports present=false" "false" "$(out_value present)"
assert_eq "a never-published image publishes no digest to verify" "" "$(out_value digest)"
assert_contains "a never-published image says so in the log" \
    "${R_STDOUT}" "nothing to check"
assert_not_contains "a never-published image is not annotated as an error" \
    "${R_STDOUT}" "::error::"

# The exemption is a case-insensitive match on three spellings; registries do
# not agree on which one they send, and a run that silently turned fatal on a
# repository with nothing published would be a nightly red with no cause.
resolve "" "Error: reading manifest: repository name not known to registry"
assert_eq "'repository name not known' is the same never-published case" \
    "0" "${R_STATUS}"
assert_eq "'repository name not known' reports present=false" \
    "false" "$(out_value present)"

resolve "" 'Error: NAME_UNKNOWN: repository not found'
assert_eq "the never-published match is case-insensitive" "0" "${R_STATUS}"
assert_eq "an upper-case NAME_UNKNOWN reports present=false" \
    "false" "$(out_value present)"

# --- everything else is fatal -----------------------------------------------
#
# These are the two incidents the job exists for. Each must fail the run, and
# must not write `present=`: the later steps are gated on it, so an exempting
# `present=false` here would skip the signature check and summarise a green run.

resolve "" "Error: reading manifest latest in ghcr.io: manifest unknown"
assert_eq "a deleted or repointed :latest fails the job" "1" "${R_STATUS}"
assert_contains "a deleted :latest is annotated as an error" \
    "${R_STDOUT}" "::error::"
assert_eq "a deleted :latest is not exempted as never-published" "" "$(out_value present)"
assert_contains "the error explains that the registry knows this name" \
    "${R_STDOUT}" "not the 'nothing published yet' case"

resolve "" "Error: reading manifest latest: unauthorized: authentication required"
assert_eq "an unauthorized inspect fails the job" "1" "${R_STATUS}"
assert_eq "an unauthorized inspect writes no present= output" "" "$(out_value present)"

resolve "" "Error: pinging container registry ghcr.io: Get \"https://ghcr.io/v2/\": dial tcp: i/o timeout"
assert_eq "a registry outage fails the job rather than passing it" "1" "${R_STATUS}"
assert_eq "a registry outage writes no present= output" "" "$(out_value present)"

resolve "" "Error: denied: requested access to the resource is denied"
assert_eq "a denied inspect fails the job" "1" "${R_STATUS}"

# skopeo's own message is the only diagnosis a reader gets, so it is printed
# rather than swallowed by the 2>err.txt redirect.
assert_contains "the failure prints skopeo's own error text" \
    "${R_STDOUT}" "requested access to the resource is denied"

# =============================================================================
# C. "Verify the published signature" — against the committed key, by digest
# =============================================================================

VERIFY_SIG="${TMP_ROOT}/verify-sig.sh"
extract "${VERIFY_SIG}" "Verify the published signature" 'cosign verify'

# verify_signature <cosign exit status>. Sets S_STATUS, S_STDOUT, S_CALLS.
verify_signature() {
    local cosign_status=$1 dir

    dir="$(mktemp -d "${TMP_ROOT}/cosign.XXXXXX")"
    mkdir -p "${dir}/bin"
    : >"${dir}/calls"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "%%s\\n" "$*" >> %q\n' "${dir}/calls"
        printf 'exit %s\n' "${cosign_status}"
    } >"${dir}/bin/cosign"
    chmod +x "${dir}/bin/cosign"

    S_STDOUT="$(
        PATH="${dir}/bin:${PATH}" \
            IMAGE_REF="${TEST_IMAGE}" \
            DIGEST="${DIGEST_A}" \
            bash "${VERIFY_SIG}" 2>&1
    )"
    S_STATUS=$?
    S_CALLS="$(cat "${dir}/calls")"
}

verify_signature 0
assert_eq "a verifying signature passes the step" "0" "${S_STATUS}"
assert_contains "a verifying signature is reported" \
    "${S_STDOUT}" "verifies against cosign.pub"
assert_contains "the signature is checked against the committed public key" \
    "${S_CALLS}" "--key cosign.pub"
# By digest, not by tag: re-resolving :latest here would verify whatever the tag
# points at now, which is not necessarily the digest the previous step reported
# and is exactly the drift this job is looking for.
assert_contains "the signature is checked against the resolved digest, not the tag" \
    "${S_CALLS}" "${TEST_IMAGE}@${DIGEST_A}"
assert_not_contains "the signature check does not re-resolve :latest" \
    "${S_CALLS}" ":latest"

verify_signature 1
assert_eq "an image that no longer verifies fails the job" "1" "${S_STATUS}"
assert_not_contains "a failed verification does not claim the signature verifies" \
    "${S_STDOUT}" "verifies against cosign.pub"

# =============================================================================
# D. "Verify the date tags still share that digest" — the accumulated status
# =============================================================================

TAGS="${TMP_ROOT}/tags.sh"
extract "${TAGS}" "Verify the date tags still share that digest" 'EXPECTED'

DATE_TAG="20260102"

# tags <digest for latest.20260102> <digest for 20260102>
#
# An empty argument means the tag is not published, which the stub reports the
# way skopeo does: non-zero, with the message on stderr that the step discards.
#
# Sets T_STATUS, T_STDOUT and T_CALLS.
tags() {
    local dated=$1 plain=$2 dir

    dir="$(mktemp -d "${TMP_ROOT}/tags.XXXXXX")"
    mkdir -p "${dir}/bin" "${dir}/digests"
    : >"${dir}/calls"
    [[ -n "${dated}" ]] && printf '%s\n' "${dated}" >"${dir}/digests/latest.${DATE_TAG}"
    [[ -n "${plain}" ]] && printf '%s\n' "${plain}" >"${dir}/digests/${DATE_TAG}"

    # shellcheck disable=SC2016 # these expansions belong to the generated stub
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf "%%s\\n" "$*" >> %q\n' "${dir}/calls"
        printf 'ref="${!#}"\n'
        printf 'file=%q/"${ref##*:}"\n' "${dir}/digests"
        printf 'if [ -f "${file}" ]; then cat "${file}"; exit 0; fi\n'
        printf 'echo "manifest unknown" >&2\nexit 1\n'
    } >"${dir}/bin/skopeo"
    chmod +x "${dir}/bin/skopeo"

    T_STDOUT="$(
        PATH="${dir}/bin:${PATH}" \
            IMAGE_REF="${TEST_IMAGE}" \
            REGISTRY_ACTOR="${TEST_ACTOR}" \
            REGISTRY_TOKEN="${TEST_TOKEN}" \
            EXPECTED="${DIGEST_A}" \
            DATE_TAG="${DATE_TAG}" \
            bash "${TAGS}" 2>&1
    )"
    T_STATUS=$?
    T_CALLS="$(cat "${dir}/calls")"
}

# --- both tags agree --------------------------------------------------------

tags "${DIGEST_A}" "${DIGEST_A}"
assert_eq "date tags that still share the digest pass" "0" "${T_STATUS}"
assert_contains "the dated latest tag is checked" \
    "${T_CALLS}" "docker://${TEST_IMAGE}:latest.${DATE_TAG}"
assert_contains "the bare date tag is checked" \
    "${T_CALLS}" "docker://${TEST_IMAGE}:${DATE_TAG}"
assert_contains "the tag check is authenticated" \
    "${T_CALLS}" "--creds ${TEST_ACTOR}:${TEST_TOKEN}"
assert_not_contains "agreeing tags produce no error annotation" \
    "${T_STDOUT}" "::error::"

# --- an absent tag is reported, not failed ----------------------------------
#
# A build straddling midnight UTC publishes tags for a date this step then reads
# back as absent. That is not drift, and turning it into a nightly failure would
# make the job's red mean nothing.

tags "" ""
assert_eq "tags that were never published do not fail the job" "0" "${T_STATUS}"
assert_contains "an absent tag is annotated as a warning" \
    "${T_STDOUT}" "::warning::"
assert_not_contains "an absent tag is not annotated as an error" \
    "${T_STDOUT}" "::error::"

tags "" "${DIGEST_A}"
assert_eq "one absent tag and one agreeing tag pass" "0" "${T_STATUS}"
assert_contains "the absent tag is named in the warning" \
    "${T_STDOUT}" "latest.${DATE_TAG} is not published"

# --- a tag that disagrees is the drift being hunted -------------------------

tags "${DIGEST_A}" "${DIGEST_B}"
assert_eq "a date tag pointing elsewhere fails the job" "1" "${T_STATUS}"
assert_contains "the disagreeing tag is annotated as an error" \
    "${T_STDOUT}" "::error::${DATE_TAG} resolves to ${DIGEST_B}"
assert_contains "the error names the digest that was expected" \
    "${T_STDOUT}" "expected ${DIGEST_A}"

# The accumulator, not an early exit: the second tag agrees and is reported OK,
# and the job must still be red for the first. Rewriting `status=1` as a reset
# assignment leaves every assertion above passing and this one failing.
tags "${DIGEST_B}" "${DIGEST_A}"
assert_eq "a mismatch on the first tag survives a later matching tag" \
    "1" "${T_STATUS}"
assert_contains "the later matching tag is still reported OK" \
    "${T_STDOUT}" "${DATE_TAG} -> ${DIGEST_A} OK"

# Neither does an absent tag clear a failure recorded before it.
tags "${DIGEST_B}" ""
assert_eq "a mismatch followed by an absent tag still fails" "1" "${T_STATUS}"

# --- both disagree ----------------------------------------------------------

tags "${DIGEST_B}" "${DIGEST_B}"
assert_eq "two disagreeing tags fail once, not twice" "1" "${T_STATUS}"

# =============================================================================
# E. "Summarize" — the run's only human-readable output
# =============================================================================

SUMMARIZE="${TMP_ROOT}/summarize.sh"
extract "${SUMMARIZE}" "Summarize" 'GITHUB_STEP_SUMMARY'

# summarize <PRESENT> <DIGEST> <DATE_TAG>. Sets SUMMARY.
summarize() {
    local dir
    dir="$(mktemp -d "${TMP_ROOT}/summary.XXXXXX")"
    : >"${dir}/summary"
    IMAGE_REF="${TEST_IMAGE}" \
        PRESENT="$1" \
        DIGEST="$2" \
        DATE_TAG="$3" \
        GITHUB_STEP_SUMMARY="${dir}/summary" \
        bash "${SUMMARIZE}" >/dev/null 2>&1
    SUMMARY="$(cat "${dir}/summary")"
}

summarize "true" "${DIGEST_A}" "${DATE_TAG}"
assert_contains "the summary names the image it checked" "${SUMMARY}" "${TEST_IMAGE}:latest"
assert_contains "the summary records the digest" "${SUMMARY}" "${DIGEST_A}"
assert_contains "the summary lists the dated latest tag it checked" \
    "${SUMMARY}" "latest.${DATE_TAG}"
assert_not_contains "a checked image is not summarised as unpublished" \
    "${SUMMARY}" "No published"

# The step is `if: always()`, so it also runs on the path where the resolve step
# exempted itself — and on the path where the resolve step failed before writing
# any output at all, which is an unset PRESENT rather than a false one.
summarize "false" "" ""
assert_contains "an unpublished image is summarised as nothing to check" \
    "${SUMMARY}" "No published"
assert_not_contains "an unpublished image reports no digest" "${SUMMARY}" "digest:"

summarize "" "" ""
assert_contains "an empty PRESENT is summarised as nothing to check" \
    "${SUMMARY}" "No published"

# The caveat is the point of the summary as much as the digest is: a green run
# here says nothing about the contents of the re-layered image, and a reader who
# assumes otherwise is the failure mode docs/quality.md exists to prevent.
summarize "true" "${DIGEST_A}" "${DATE_TAG}"
assert_contains "the summary states that image contents are not validated here" \
    "${SUMMARY}" "run-e2e.sh --rechunk"

# =============================================================================
# F. the guards that make the exemption above mean anything
# =============================================================================
#
# `present=false` is only an exemption if the steps that consume the digest are
# skipped. Ungated, the never-published path runs `cosign verify` on an empty
# digest and fails the job it was meant to exempt — and every executed case in
# section B stops describing the workflow's behaviour while still passing.

for guarded in "Verify the published signature" \
    "Verify the date tags still share that digest"; do
    assert_eq "'${guarded}' runs only when an image was found" \
        "steps.latest.outputs.present == 'true'" "$(step_if "${guarded}")"
done

assert_eq "the summary is written even when a check failed" \
    "always()" "$(step_if "Summarize")"

# The resolve step is the only one the others read outputs from, so it needs the
# id those expressions name.
assert_eq "the resolve step keeps the id its consumers reference" \
    "latest" "$(wf '.jobs.published_image.steps[] | select(.name == "Resolve the published :latest") | .id')"

# A read-only job: this workflow inspects and verifies, and nothing it does
# should be able to change a package or the tree.
assert_eq "the published_image job cannot write to the repository" \
    "read" "$(wf '.jobs.published_image.permissions.contents')"
assert_eq "the published_image job cannot write packages" \
    "read" "$(wf '.jobs.published_image.permissions.packages')"

finish
