#!/usr/bin/env bash
#
# A coverage gate for a repository where most code cannot be covered.
#
# Line coverage is meaningless here: build_files/build.sh,
# build_files/kernel-akmods.sh and build_files/zfs.sh run at the top level inside
# an image build against a real RPM database, module tree and initramfs, and
# nothing on the host reaches them. A percentage threshold would either sit near
# zero forever or be gamed. What is worth enforcing is that the gap stays
# *deliberate*.
#
# So this asserts a decision, not a number. Every shell script the repo ships
# outside tests/ is listed below as either covered by a named test file, or
# uncovered with the reason. Adding a script without touching this file turns
# the suite red, which is the whole point: the choice gets made once, in the
# open, instead of drifting.
#
# Both directions are checked, so the manifest cannot rot:
#
#   * a script missing from the manifest fails      (new code, no decision)
#   * a manifest entry with no script fails         (stale after a deletion)
#   * a "covered" claim whose test does not exist,
#     or does not reference the script, fails       (coverage in name only)

set -uo pipefail

TEST_NAME="test-coverage"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

# script <TAB> covering test file, or the literal UNCOVERED plus a reason.
#
# The three UNCOVERED entries are not an oversight — tests/README.md explains
# them at length. Those scripts do their work at the top level, so `source`
# executes the whole file; there is no seam to test against. post-check.sh is
# covered precisely because it grew one (a `BASH_SOURCE`-guarded entry point).
MANIFEST=$(
    cat <<'EOF'
.claude/hooks/gate-git-diff.sh	tests/test-claude-settings.sh
build_files/build.sh	UNCOVERED	runs its work at the top level; sourcing it executes the whole file. Exercised only by a real image build.
build_files/kernel-akmods.sh	UNCOVERED	same, and it erases the running system's kernel RPMs. Exercised only by a real image build.
build_files/zfs.sh	UNCOVERED	same. Its happy path is exercised by the Build container image workflow; its failure branches are not.
build_files/post-check.sh	tests/test-post-check.sh
ci/write-badges.sh	tests/test-write-badges.sh
EOF
)

# --- every shipped script has a decision recorded ---------------------------

manifest_paths=$(cut -f1 <<<"${MANIFEST}" | sort)

shipped=$(cd "${REPO_ROOT}" && git ls-files '*.sh' | grep -v '^tests/' | sort)

if [[ -z "${shipped}" ]]; then
    _fail "found shipped shell scripts" "git ls-files matched no *.sh outside tests/"
    finish
    exit
fi

while IFS= read -r script; do
    [[ -z "${script}" ]] && continue
    if grep -qxF "${script}" <<<"${manifest_paths}"; then
        _pass "coverage is declared for ${script}"
    else
        _fail "coverage is declared for ${script}" \
            "add it to the MANIFEST in tests/test-coverage.sh, as either a" \
            "covering test file or UNCOVERED plus the reason"
    fi
done <<<"${shipped}"

# --- and every decision still refers to something --------------------------

while IFS=$'\t' read -r script covering reason; do
    [[ -z "${script}" ]] && continue

    if grep -qxF "${script}" <<<"${shipped}"; then
        _pass "manifest entry still exists: ${script}"
    else
        _fail "manifest entry still exists: ${script}" \
            "no such tracked script; remove the stale MANIFEST entry"
        continue
    fi

    if [[ "${covering}" == "UNCOVERED" ]]; then
        if [[ -n "${reason// }" ]]; then
            _pass "${script} is UNCOVERED with a stated reason"
        else
            _fail "${script} is UNCOVERED with a stated reason" \
                "an UNCOVERED entry must say why"
        fi
        continue
    fi

    # A coverage claim has to be worth something: the file must exist and must
    # actually name the script under test.
    if [[ ! -f "${REPO_ROOT}/${covering}" ]]; then
        _fail "${script} is covered by ${covering}" "no such test file"
        continue
    fi
    if grep -qF -- "${script}" "${REPO_ROOT}/${covering}"; then
        _pass "${script} is covered by ${covering}"
    else
        _fail "${script} is covered by ${covering}" \
            "${covering} never references ${script}"
    fi
done <<<"${MANIFEST}"

finish
