#!/usr/bin/env bash
#
# Covers the `Publish badges to status branch` step of
# `.github/workflows/status-badges.yml` -- the ~25 lines of shell that take the
# JSON files ci/write-badges.sh produced and land them on the `status` branch.
#
# Nothing executed this before. test-write-badges.sh drives the script that
# writes the payloads and stops at the artifacts directory; test-ci-workflows.sh
# and test-auto-qa-tuning.sh read this workflow only as YAML (does the job skip
# pull requests, does it declare a timeout, is it in the tuning manifest). So
# the half of the pipeline that actually mutates a branch with a
# `contents: write` token was asserted by nobody, in either the unit suite or
# tests/e2e/run-e2e.sh.
#
# The step is worth executing rather than reading, because its useful properties
# are all conditional and none of them are visible in the text:
#
#   * the `status` branch may or may not exist yet. The first run in a fresh
#     repository has to take the `--orphan` path; every run after it has to take
#     the fetch path, on top of what is already published.
#   * only files written this run are copied over. The workflow comment states
#     this outright: "a run that could read one input but not the other leaves
#     the other badge's last known-good content alone". That is the same
#     deliberate no-overwrite rule test-write-badges.sh pins down inside the
#     script, and here it depends on a `[ -f ... ]` guard that a refactor could
#     drop without changing a single visible behaviour on the happy path.
#   * an unchanged badge must produce no commit at all. Without the
#     `git diff --cached --quiet` branch this job would push an empty-tree commit
#     to `status` every day at 06:30 forever.
#   * the push is `HEAD:status`. A push to the wrong ref from a job holding
#     `contents: write` is the failure that matters most here, and it is one
#     word away.
#
# The step is extracted from the YAML with PyYAML and run against a real local
# bare repository, reached by rewriting the `https://github.com/...` URL the
# step builds with `url.<file://...>.insteadOf` in a per-case
# `GIT_CONFIG_GLOBAL`. Nothing is stubbed: it is git that runs, so the orphan
# branch, the shallow fetch, the staged diff and the ref the push lands on are
# all observed on the far side rather than asserted from the script's text.
# Overriding GIT_CONFIG_GLOBAL also drops the ambient user identity, which makes
# the step's own `git config user.name/user.email` lines load-bearing -- the
# committer the branch ends up with is checked, not assumed.
#
# The `if:` gate is checked against ci/write-badges.sh as well. The step only
# runs when `steps.badges.outputs.akmods_updated` or `last_good_updated` is
# 'true'; if the script were to rename an output, the gate would silently go
# false forever and the badges would simply stop updating with every job green.

set -uo pipefail

TEST_NAME="test-status-badges"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

BADGES_WF="${REPO_ROOT}/.github/workflows/status-badges.yml"
WRITE_BADGES="${REPO_ROOT}/ci/write-badges.sh"
WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

for required in "${BADGES_WF}" "${WRITE_BADGES}"; do
    if [[ ! -f "${required}" ]]; then
        _fail "${required#"${REPO_ROOT}/"} exists" \
            "no such file: ${required}" \
            "if the status badge pipeline was removed, delete this test with it"
        finish
        exit 1
    fi
done

# This step pushes with a write token; a missing parser must fail rather than
# skip, including when this file is invoked directly instead of through
# run-tests.sh.
if ! "${WORKFLOW_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    _fail "the status badge checker requires Python 3 with PyYAML" \
        "install python3-yaml (Debian/Ubuntu) or python3-pyyaml (Fedora)," \
        "or install PyYAML in the interpreter selected by WORKFLOW_PYTHON"
    finish
    exit 1
fi

# --- the workflow, as JSON --------------------------------------------------

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

# The normalizer is tested against known answers before it is trusted: an
# extraction that silently returned nothing would make every case below a
# vacuous pass.
fixture="${TMP_ROOT}/fixture.yml"
cat >"${fixture}" <<'YAML'
---
name: Fixture
on:
  schedule:
    - cron: '30 06 * * *'
jobs:
  badges:
    steps:
      - name: Publish badges to status branch
        if: steps.demo.outputs.changed == 'true'
        run: |
          echo marker
YAML

fixture_json="${TMP_ROOT}/fixture.json"
if "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${fixture}" >"${fixture_json}" 2>"${TMP_ROOT}/fixture.err"; then
    assert_eq "the normalizer reads a fixture's trigger by name" \
        "30 06 * * *" "$(jq -r '.on.schedule[0].cron' <"${fixture_json}")"
    assert_eq "the normalizer reads a fixture's block-scalar run: body" \
        "echo marker" "$(jq -r '.jobs.badges.steps[0].run' <"${fixture_json}")"
    assert_eq "the normalizer reads a fixture's step condition" \
        "steps.demo.outputs.changed == 'true'" \
        "$(jq -r '.jobs.badges.steps[0].if' <"${fixture_json}")"
else
    _fail "the normalizer parses a fixture workflow" "$(cat "${TMP_ROOT}/fixture.err")"
fi

WF_JSON="${TMP_ROOT}/status-badges.json"
if ! "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${BADGES_WF}" >"${WF_JSON}" 2>"${TMP_ROOT}/wf.err"; then
    _fail "status-badges.yml parses as YAML" "$(cat "${TMP_ROOT}/wf.err")"
    finish
    exit 1
fi
_pass "status-badges.yml parses as YAML"

wf() {
    jq -r "$1" <"${WF_JSON}"
}

PUBLISH_STEP='.jobs.badges.steps[] | select(.name == "Publish badges to status branch")'

# =============================================================================
# A. the gate that decides whether the step runs at all
# =============================================================================

publish_if="$(wf "${PUBLISH_STEP} | .if // \"\"")"

assert_contains "the publish step is gated on the akmods badge having been written" \
    "${publish_if}" "steps.badges.outputs.akmods_updated == 'true'"
assert_contains "the publish step is gated on the last-good badge having been written" \
    "${publish_if}" "steps.badges.outputs.last_good_updated == 'true'"

# The gate names two outputs of another file. Nothing else in the repository
# ties the two together, so a rename in the script would leave a condition that
# is false on every run -- badges silently frozen, every job green.
for output in akmods_updated last_good_updated; do
    if grep -q "set_output ${output} true" "${WRITE_BADGES}"; then
        _pass "ci/write-badges.sh can set ${output} to true, so the gate can open"
    else
        _fail "ci/write-badges.sh can set ${output} to true, so the gate can open" \
            "the publish step's if: waits for steps.badges.outputs.${output} == 'true'" \
            "but no 'set_output ${output} true' remains in ci/write-badges.sh"
    fi
done

# The step reads its inputs out of the workspace, and the badge step is what
# put them there. If OUT_DIR stops being 'artifacts', the copy loop finds
# nothing and the job pushes an unchanged branch forever.
assert_eq "the badge step writes into the artifacts directory the publish step reads" \
    "artifacts" "$(wf '.jobs.badges.steps[] | select(.id == "badges") | .env.OUT_DIR')"

# =============================================================================
# B. the step, executed
# =============================================================================

PUBLISH="${TMP_ROOT}/publish.sh"
wf "${PUBLISH_STEP} | .run" >"${PUBLISH}"

if [[ ! -s "${PUBLISH}" ]] || ! grep -q 'git push' "${PUBLISH}"; then
    _fail "the publish script was extracted from status-badges.yml" \
        "expected a step named 'Publish badges to status branch' in the badges job" \
        "carrying a run: body that pushes; extracted $(wc -c <"${PUBLISH}") byte(s)" \
        "the step name probably changed -- update this test to match"
    finish
    exit 1
fi
_pass "the publish script was extracted from status-badges.yml"

TEST_REPO="Danathar/aurora-zfs-simple"
TEST_TOKEN="not-a-real-token"

AKMODS_BADGE='{"schemaVersion":1,"label":"akmods","message":"in sync","color":"green"}'
LAST_GOOD_BADGE='{"schemaVersion":1,"label":"last good build","message":"2 days ago","color":"green"}'

# git_seed <remote> <file>=<content>...
#
# Publishes an initial `status` branch to the bare repository, the way a
# previous run of this job would have left it. Called with no files, the remote
# stays empty and the step has to take the --orphan path.
git_seed() {
    local remote=$1
    shift
    local seed="${remote%.git}.seed"
    mkdir -p "${seed}"
    git -C "${seed}" init -q
    local pair
    for pair in "$@"; do
        printf '%s\n' "${pair#*=}" >"${seed}/${pair%%=*}"
    done
    git -C "${seed}" add -A
    git -C "${seed}" \
        -c user.name="seed" -c user.email="seed@example.invalid" \
        commit -q -m "previous badge state"
    git -C "${seed}" push -q "${remote}" HEAD:status
}

# publish <case name> [artifact file names...]
#
# Runs the extracted step against a fresh bare repository with the named badge
# files present in $GITHUB_WORKSPACE/artifacts. Callers seed the remote first
# via CASE_REMOTE when they want an existing `status` branch.
#
# Sets PUB_STATUS, PUB_STDOUT, PUB_STDERR and CASE_REMOTE.
new_case() {
    CASE_DIR="$(mktemp -d "${TMP_ROOT}/case.XXXXXX")"
    CASE_REMOTE="${CASE_DIR}/remote.git"
    CASE_WORKSPACE="${CASE_DIR}/workspace"
    git init -q --bare "${CASE_REMOTE}"
    mkdir -p "${CASE_WORKSPACE}/artifacts"

    # The step builds its remote URL by interpolating REPO into a github.com
    # https URL, with no credential in it -- the token reaches git through a
    # credential helper that reads GH_TOKEN from the environment. Rewriting
    # exactly that URL to the local bare repo leaves the step's own string
    # construction under test: a change to the URL it builds stops matching,
    # and the fetch/push fail loudly. A URL that regained an embedded
    # credential would no longer match either, which is what B7 asserts.
    cat >"${CASE_DIR}/gitconfig" <<EOF
[url "file://${CASE_REMOTE}"]
    insteadOf = https://github.com/${TEST_REPO}.git
EOF
}

publish() {
    local stdout_file="${CASE_DIR}/stdout" stderr_file="${CASE_DIR}/stderr"

    (
        cd "${CASE_WORKSPACE}" || exit 1
        GIT_CONFIG_GLOBAL="${CASE_DIR}/gitconfig" \
            GIT_CONFIG_NOSYSTEM=1 \
            GITHUB_WORKSPACE="${CASE_WORKSPACE}" \
            GH_TOKEN="${TEST_TOKEN}" \
            REPO="${TEST_REPO}" \
            bash "${PUBLISH}"
    ) >"${stdout_file}" 2>"${stderr_file}"
    PUB_STATUS=$?
    PUB_STDOUT="$(cat "${stdout_file}")"
    PUB_STDERR="$(cat "${stderr_file}")"
}

# remote_file <path> — the content of a file on the published status branch.
remote_file() {
    git --git-dir="${CASE_REMOTE}" show "status:$1" 2>/dev/null
}

# --- B1. the first ever run: no status branch yet ---------------------------

new_case
printf '%s\n' "${AKMODS_BADGE}" >"${CASE_WORKSPACE}/artifacts/akmods-badge.json"
printf '%s\n' "${LAST_GOOD_BADGE}" >"${CASE_WORKSPACE}/artifacts/last-good-build-badge.json"
# The copy loop names the two badge files, rather than copying the artifacts
# directory. That distinction only shows up when something else is in there --
# and something else can be: ci/write-badges.sh runs skopeo in the same job, and
# this branch is served publicly from raw.githubusercontent.com.
printf 'raw skopeo output\n' >"${CASE_WORKSPACE}/artifacts/scratch.json"
publish

assert_eq "a repository with no status branch publishes successfully" "0" "${PUB_STATUS}"
assert_eq "the orphan run publishes the akmods badge" \
    "${AKMODS_BADGE}" "$(remote_file akmods-badge.json)"
assert_eq "the orphan run publishes the last-good badge" \
    "${LAST_GOOD_BADGE}" "$(remote_file last-good-build-badge.json)"

# --orphan, not a branch off whatever the default is: the status branch must
# carry the badges and nothing else, and must be rootless.
assert_eq "only the two named badge files reach the status branch" \
    "akmods-badge.json last-good-build-badge.json" \
    "$(git --git-dir="${CASE_REMOTE}" ls-tree --name-only status | tr '\n' ' ' | sed 's/ $//')"
assert_eq "the status branch starts from a root commit, not the build branch" \
    "1" "$(git --git-dir="${CASE_REMOTE}" rev-list --count status)"

# GIT_CONFIG_GLOBAL is overridden for the run, so this identity can only have
# come from the step's own `git config` lines.
assert_eq "the commit is authored by the actions bot" \
    "github-actions[bot] <github-actions[bot]@users.noreply.github.com>" \
    "$(git --git-dir="${CASE_REMOTE}" log -1 --format='%cn <%ce>' status)"
assert_eq "the commit message says what it is" \
    "Update status badges" \
    "$(git --git-dir="${CASE_REMOTE}" log -1 --format='%s' status)"

# --- B2. a later run, one badge readable ------------------------------------
#
# The workflow comment's stated rule: a run that could read one input but not
# the other leaves the other badge's last known-good content alone.

new_case
git_seed "${CASE_REMOTE}" \
    "akmods-badge.json=stale akmods" \
    "last-good-build-badge.json=last known good"
printf '%s\n' "${AKMODS_BADGE}" >"${CASE_WORKSPACE}/artifacts/akmods-badge.json"
publish

assert_eq "a run with one readable input succeeds" "0" "${PUB_STATUS}"
assert_eq "the badge written this run is republished" \
    "${AKMODS_BADGE}" "$(remote_file akmods-badge.json)"
assert_eq "the badge not written this run keeps its last known-good content" \
    "last known good" "$(remote_file last-good-build-badge.json)"
assert_eq "the existing history is built on, not replaced" \
    "2" "$(git --git-dir="${CASE_REMOTE}" rev-list --count status)"

# --- B3. nothing changed ----------------------------------------------------
#
# The daily schedule means this is the common case, not an edge case: without
# the staged-diff branch, `status` would grow one empty commit every morning.

new_case
git_seed "${CASE_REMOTE}" \
    "akmods-badge.json=${AKMODS_BADGE}" \
    "last-good-build-badge.json=${LAST_GOOD_BADGE}"
before="$(git --git-dir="${CASE_REMOTE}" rev-parse status)"
printf '%s\n' "${AKMODS_BADGE}" >"${CASE_WORKSPACE}/artifacts/akmods-badge.json"
printf '%s\n' "${LAST_GOOD_BADGE}" >"${CASE_WORKSPACE}/artifacts/last-good-build-badge.json"
publish

assert_eq "an unchanged run succeeds" "0" "${PUB_STATUS}"
assert_contains "an unchanged run says it committed nothing" \
    "${PUB_STDOUT}" "Badge content unchanged; nothing to commit."
assert_eq "an unchanged run pushes no commit" \
    "${before}" "$(git --git-dir="${CASE_REMOTE}" rev-parse status)"

# --- B4. the push lands on status, and only on status -----------------------
#
# This job holds contents: write. A push that resolved to the default branch
# would put bot commits on the branch that produces images -- exactly what the
# workflow's comment says the separate branch exists to prevent.

new_case
git_seed "${CASE_REMOTE}" "akmods-badge.json=stale akmods"
git --git-dir="${CASE_REMOTE}" symbolic-ref HEAD refs/heads/main
printf '%s\n' "${AKMODS_BADGE}" >"${CASE_WORKSPACE}/artifacts/akmods-badge.json"
publish

assert_eq "the publish run succeeds against an existing status branch" "0" "${PUB_STATUS}"
assert_eq "only the status branch is written" \
    "refs/heads/status" \
    "$(git --git-dir="${CASE_REMOTE}" for-each-ref --format='%(refname)' refs/heads | tr '\n' ' ' | sed 's/ $//')"

# --- B5. an unrelated file already on the branch survives -------------------
#
# `git add -A` runs in a checkout of the status branch, so anything already
# published there is staged unchanged rather than deleted. A future switch back
# to an orphan checkout on every run would silently drop it.

new_case
git_seed "${CASE_REMOTE}" \
    "akmods-badge.json=stale akmods" \
    "README.md=badge payloads, published by CI"
printf '%s\n' "${AKMODS_BADGE}" >"${CASE_WORKSPACE}/artifacts/akmods-badge.json"
publish

assert_eq "publishing over an existing branch succeeds" "0" "${PUB_STATUS}"
assert_eq "a file already on the status branch is left in place" \
    "badge payloads, published by CI" "$(remote_file README.md)"

# --- B6. an unreadable remote fails the job ---------------------------------
#
# The step runs under `set -euo pipefail`, so a push that cannot land must stop
# the job rather than let a green run imply published badges.

new_case
rm -rf "${CASE_REMOTE}"
printf '%s\n' "${AKMODS_BADGE}" >"${CASE_WORKSPACE}/artifacts/akmods-badge.json"
publish

if [[ "${PUB_STATUS}" -ne 0 ]]; then
    _pass "a remote that cannot be pushed to fails the step"
else
    _fail "a remote that cannot be pushed to fails the step" \
        "the step exited 0 with no reachable remote" \
        "stdout: ${PUB_STDOUT}" \
        "stderr: ${PUB_STDERR}"
fi

# --- B7. the write token never reaches a command line -----------------------
#
# /proc/<pid>/cmdline is mode 0444, so a credential spliced into the remote URL
# is readable by every uid on the runner for as long as any git process holds
# it, it is copied verbatim into .git/config, and it lands in any ps capture
# taken while debugging a hung fetch. #150 took the same exposure out of
# skopeo's argv in ci/write-badges.sh and nightly-compliance.yml; this job's
# token is the write-scoped one, so it is the one that matters most.
#
# Executed rather than read: the step runs behind a PATH shim that records
# every git argv and then exec's the real git, so this observes the process the
# runner would actually create. The credential helper the step installs carries
# the literal text ${GH_TOKEN} on git's command line and expands it from the
# environment only inside the helper's own shell, so the value cannot appear
# here however the fetch or push is routed.

new_case
GIT_ARGV_LOG="${CASE_DIR}/git-argv.log"
SHIM_DIR="${CASE_DIR}/bin"
mkdir -p "${SHIM_DIR}"
REAL_GIT="$(command -v git)"
cat >"${SHIM_DIR}/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${GIT_ARGV_LOG}"
exec "${REAL_GIT}" "\$@"
EOF
chmod +x "${SHIM_DIR}/git"
: >"${GIT_ARGV_LOG}"
printf '%s\n' "${AKMODS_BADGE}" >"${CASE_WORKSPACE}/artifacts/akmods-badge.json"

SAVED_PATH="${PATH}"
PATH="${SHIM_DIR}:${PATH}"
publish
PATH="${SAVED_PATH}"

assert_eq "the step still publishes with every git argv recorded" \
    "0" "${PUB_STATUS}"
assert_not_contains "no git command line carries the write token" \
    "$(cat "${GIT_ARGV_LOG}")" "${TEST_TOKEN}"

# The shim has to have seen the commands, or the assertion above passes over an
# empty log. The remote is added, fetched from and pushed to by name.
assert_contains "the argv log recorded the git invocations it is asserting on" \
    "$(cat "${GIT_ARGV_LOG}")" "remote add origin"

finish
