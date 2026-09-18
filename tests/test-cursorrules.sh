#!/usr/bin/env bash
#
# Joins .cursorrules to the machine it describes.
#
# .cursorrules is what Cursor loads before every edit in this repository, and
# nothing opened it. `grep -rl cursorrules tests/` returned two hits before this
# file and neither read it: test-labeler.sh asserts the path matches the
# `area/agents` glob, and test-memory-corrections.sh names it in a comment
# listing the agent-configuration surface. test-coverage.sh sees only shipped
# `*.sh`, and test-docs-paths.sh resolves paths named by README.md and
# AGENTS.md, not by this file.
#
# Unopened prose drifts, and this document drifts in the expensive direction:
# every line is a claim about how the tree behaves *today*, written as an
# instruction an agent will follow without checking. Two of them were already
# false when this test was written -- the two-space exception list was short by
# one, and the shebang rule claimed every `*.sh` when tests/lib/ is deliberately
# outside it -- so an agent obeying the file would have written a four-space
# diff into a two-space script and chmod +x'd two sourced libraries.
#
# So every literal below is computed from the file the rule cites -- the
# Containerfile, ci/write-badges.sh, build_files/zfs.sh,
# build_files/kernel-akmods.sh, .editorconfig, .shellcheckrc,
# tests/test-shell-syntax.sh, tests/test-coverage.sh -- and compared with what
# the rules say. Editing one side alone is a red suite rather than a reader's
# problem. Extractions refuse to verify an empty set: a renamed section or a
# reworded rule fails here rather than passing vacuously.
#
# Scope: the claims that name something in this repository. Judgements that
# cannot be checked -- "write in the same register", "most red builds here are
# caused upstream" -- are left alone.
#
# Overlap with what already exists is deliberate and reached from the other
# side. test-quality-docs.sh holds the run-by-path shebang rule as
# docs/review-rubric.md states it; test-shell-syntax.sh enforces it directly;
# test-editorconfig.sh measures indentation. This file asks a different
# question: whether .cursorrules still describes the sets those tests enforce.

set -uo pipefail

TEST_NAME="test-cursorrules"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

DOC="${REPO_ROOT}/.cursorrules"
AGENTS="${REPO_ROOT}/AGENTS.md"
CONTAINERFILE="${REPO_ROOT}/Containerfile"
WRITE_BADGES="${REPO_ROOT}/ci/write-badges.sh"
ZFS_SH="${REPO_ROOT}/build_files/zfs.sh"
KERNEL_AKMODS="${REPO_ROOT}/build_files/kernel-akmods.sh"
POST_CHECK="${REPO_ROOT}/build_files/post-check.sh"
EDITORCONFIG="${REPO_ROOT}/.editorconfig"
SHELLCHECKRC="${REPO_ROOT}/.shellcheckrc"
SHELL_SYNTAX="${TEST_DIR}/test-shell-syntax.sh"
COVERAGE_TEST="${TEST_DIR}/test-coverage.sh"
RUN_TESTS="${TEST_DIR}/run-tests.sh"

for required in "${DOC}" "${AGENTS}" "${CONTAINERFILE}" "${WRITE_BADGES}" \
    "${ZFS_SH}" "${KERNEL_AKMODS}" "${POST_CHECK}" "${EDITORCONFIG}" \
    "${SHELLCHECKRC}" "${SHELL_SYNTAX}" "${COVERAGE_TEST}" "${RUN_TESTS}"; do
    [[ -f "${required}" ]] && continue
    _fail "every file the rules cite is present" \
        "no such file: ${required#"${REPO_ROOT}"/}" \
        "if it was removed on purpose, the rule that cites it is now wrong"
    finish
    exit 1
done

DOC_TEXT="$(cat "${DOC}")"

# Fails rather than passing on an empty extraction. A reworded heading or a
# renamed function must not turn an assertion into a tautology.
require_nonempty() {
    local description=$1 value=$2
    if [[ -n "${value}" ]]; then
        _pass "extracted ${description}"
    else
        _fail "extracted ${description}" \
            "the extraction returned nothing, so everything below it would pass vacuously"
    fi
}

# The body of one `## ` section, up to the next one.
doc_section() {
    awk -v want="$1" '
        /^## / { in_section = (substr($0, 4) == want); next }
        in_section { print }
    ' "${DOC}"
}

for section in "Context" "Code" "Testing reality"; do
    require_nonempty "the ${section} section" "$(doc_section "${section}")"
done

# --- 1. every filename the rules name exists --------------------------------
#
# The rules point at files by name, including three by basename alone
# (kernel-akmods.sh, post-check.sh, Containerfile). A rename that misses this
# document leaves an instruction aimed at nothing, which reads as "that check is
# gone" rather than "that check moved".

tracked="$(cd "${REPO_ROOT}" && git ls-files)"
require_nonempty "the tracked file list" "${tracked}"

named_files="$(grep -ohE '(\./)?[A-Za-z0-9_./-]+\.(sh|md|json|yml)|\bContainerfile\b' "${DOC}" |
    sed 's|^\./||' | LC_ALL=C sort -u)"
require_nonempty "the filenames .cursorrules names" "${named_files}"

unresolved=""
while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    if [[ "${name}" == */* ]]; then
        grep -qxF "${name}" <<<"${tracked}" || unresolved+="${name} "
    else
        # A basename has to match exactly one tracked file, or the rule is
        # ambiguous about which script it is talking about.
        matches="$(grep -cE "(^|/)${name}$" <<<"${tracked}")"
        [[ "${matches}" -eq 1 ]] || unresolved+="${name}(${matches} matches) "
    fi
done <<<"${named_files}"
assert_eq "every file .cursorrules names resolves to exactly one tracked file" \
    "" "${unresolved% }"

# The opening rule sends the reader to AGENTS.md and says these rules are the
# short form of it. A .cursorrules that grew past AGENTS.md is not the short
# form any more, whatever the sentence still says.
assert_contains "the rules send the reader to AGENTS.md first" \
    "${DOC_TEXT}" "Read AGENTS.md first"
doc_lines="$(wc -l <"${DOC}")"
agents_lines="$(wc -l <"${AGENTS}")"
if [[ "${doc_lines}" -lt "${agents_lines}" ]]; then
    _pass "the rules are shorter than AGENTS.md, which is what 'the short form' means"
else
    _fail "the rules are shorter than AGENTS.md, which is what 'the short form' means" \
        ".cursorrules: ${doc_lines} lines, AGENTS.md: ${agents_lines} lines"
fi

# --- 2. three prebuilt artifacts, two of which must agree -------------------
#
# The Containerfile's ublue inputs are read out of the FROM lines rather than
# hard-coded here, so pinning one of them (which AGENTS.md documents as an
# outage workaround) is visible to this test.

from_stages="$(grep -E '^FROM[[:space:]]' "${CONTAINERFILE}" |
    sed -nE 's/^FROM[[:space:]]+([^[:space:]]+)[[:space:]]+AS[[:space:]]+([A-Za-z0-9_-]+).*/\2 \1/p')"
require_nonempty "the Containerfile's FROM stages" "${from_stages}"

# `scratch` is the context stage, not an assembled artifact.
ublue_stages="$(awk '$2 ~ /ghcr\.io\/ublue-os\// || $2 ~ /AURORA_IMAGE/ { print $1 }' <<<"${from_stages}" |
    LC_ALL=C sort | tr '\n' ' ')"
assert_eq "the Containerfile assembles exactly the three artifacts the rules name" \
    "akmods akmods-zfs base " "${ublue_stages}"
assert_contains "and the rules say three" "${DOC_TEXT}" "three prebuilt Universal Blue artifacts"

for image in akmods akmods-zfs; do
    assert_contains "the rules name ghcr.io/ublue-os/${image}, which the Containerfile pulls" \
        "${DOC_TEXT}" "ghcr.io/ublue-os/${image}"
    assert_contains "and the Containerfile pulls it" \
        "$(cat "${CONTAINERFILE}")" "ghcr.io/ublue-os/${image}:"
done

# "Correctness depends on TWO of them agreeing about the kernel version: akmods
# and akmods-zfs. The Aurora base is not one of them." ci/write-badges.sh is the
# code that makes that comparison, so the stage names it inspects are the claim.
compared_stages="$(grep -oE 'from_ref[[:space:]]+[A-Za-z0-9_-]+' "${WRITE_BADGES}" |
    awk '{ print $2 }' | LC_ALL=C sort -u | tr '\n' ' ')"
assert_eq "ci/write-badges.sh compares exactly the two stages the rules name" \
    "akmods akmods-zfs " "${compared_stages}"
assert_not_contains "and it never inspects the Aurora base, which the rules say is not one of them" \
    "${compared_stages}" "base"

# "Compare the ostree.linux label" -- the label name is a literal in both.
assert_contains "the rules name the ostree.linux label" "${DOC_TEXT}" "ostree.linux"
assert_contains "and ci/write-badges.sh reads that label" \
    "$(cat "${WRITE_BADGES}")" 'Labels["ostree.linux"]'

# "for the release the Containerfile targets" -- write-badges.sh reads the
# release out of the Containerfile rather than being told it. Run its own sed
# program against the Containerfile so a renamed ARG fails here.
fedora_from_containerfile="$(sed -n 's/^ARG FEDORA_VERSION=\([0-9][0-9]*\).*/\1/p' "${CONTAINERFILE}" | head -1)"
require_nonempty "the Fedora release the Containerfile targets" "${fedora_from_containerfile}"
assert_contains "ci/write-badges.sh reads that same ARG out of the Containerfile" \
    "$(cat "${WRITE_BADGES}")" 's/^ARG FEDORA_VERSION='
assert_contains "and the akmods tag the Containerfile pulls carries that release" \
    "$(cat "${CONTAINERFILE}")" 'ghcr.io/ublue-os/akmods:coreos-stable-"${FEDORA_VERSION}"'

# "kernel-akmods.sh erases Aurora's kernel outright" -- the reason the rules give
# for the image legitimately running a newer kernel than Aurora stable.
kernel_akmods_text="$(cat "${KERNEL_AKMODS}")"
assert_contains "kernel-akmods.sh erases the base kernel RPMs" \
    "${kernel_akmods_text}" 'rpm --erase "${pkg}" --nodeps'
assert_contains "over a package list that includes the kernel itself" \
    "${kernel_akmods_text}" "for pkg in kernel kernel-core"
# The whole line, not a prefix of it: `rm -rf /usr/lib/modules.bak` would
# satisfy a substring match while leaving the base module tree in place.
assert_eq "and removes the base module tree outright" \
    "rm -rf /usr/lib/modules" \
    "$(grep -E '^rm -rf /usr/lib/modules[[:space:]]*$' "${KERNEL_AKMODS}" | head -1)"

# "It does not compile ZFS; it assembles three prebuilt artifacts." Nothing in
# build_files/ may invoke a compiler or a module build, in command position.
compile_hits="$(grep -nE '(^|[;&|][[:space:]]*|^[[:space:]]+)(make|dkms|gcc|cc|akmods|\./configure)[[:space:]]' \
    "${REPO_ROOT}"/build_files/*.sh || true)"
assert_eq "no build_files script compiles anything, which is what 'prebuilt' means" \
    "" "${compile_hits}"
assert_contains "build_files/zfs.sh installs a prebuilt kmod RPM instead" \
    "$(cat "${ZFS_SH}")" "/tmp/rpms/kmods/zfs/kmod-zfs-"

# --- 3. never loosen the kmod-zfs glob --------------------------------------
#
# "Never loosen the kmod-zfs glob in build_files/zfs.sh or make that install
# non-fatal to get past it." Both halves are checkable: the glob is anchored to
# the kernel it just installed, and the install has no failure escape.

zfs_text="$(cat "${ZFS_SH}")"
# shellcheck disable=SC2016 # the literal ${KERNEL} is the anchor being asserted
assert_contains "the kmod-zfs glob is anchored to the replacement kernel" \
    "${zfs_text}" '/tmp/rpms/kmods/zfs/kmod-zfs-"${KERNEL}"*.rpm'
assert_contains "build_files/zfs.sh aborts on the first failure" "${zfs_text}" "set -eoux pipefail"

install_lines="$(grep -nE '^[[:space:]]*dnf5 .*install' "${ZFS_SH}")"
require_nonempty "the package installs in build_files/zfs.sh" "${install_lines}"
non_fatal="$(grep -E '\|\|[[:space:]]*(true|:)' <<<"${install_lines}" || true)"
assert_eq "no install in build_files/zfs.sh is made non-fatal" "" "${non_fatal}"

# The rules' reason -- "the failure moves from the build to the boot" -- is only
# true while the script checks that the modules it installed are really there.
assert_contains "build_files/zfs.sh fails the build when a module is missing" \
    "${zfs_text}" 'compgen -G "${ZFS_MODULE_DIR}/${module}.ko*"'

# --- 4. the Code section ----------------------------------------------------

code_section="$(doc_section "Code")"

# "Shell only. No package manager, no node_modules, no build step."
manifests=""
for manifest in package.json package-lock.json yarn.lock requirements.txt \
    pyproject.toml setup.py Cargo.toml go.mod Gemfile Makefile justfile; do
    grep -qE "(^|/)${manifest}$" <<<"${tracked}" && manifests+="${manifest} "
done
assert_eq "the tree ships no package manager or build-step manifest" "" "${manifests% }"
assert_eq "and nothing under node_modules is tracked" \
    "" "$(grep -c '^node_modules/\|/node_modules/' <<<"${tracked}" | grep -v '^0$' || true)"

# "shellcheck -x must produce zero output, informational findings included."
shell_syntax_text="$(cat "${SHELL_SYNTAX}")"
assert_contains "tests/test-shell-syntax.sh runs shellcheck with -x" \
    "${shell_syntax_text}" 'shellcheck -x "${rel}"'
# shellcheck disable=SC2016 # matching the assertion's own text, ${rel} included
assert_contains "and requires empty output rather than a severity floor" \
    "${shell_syntax_text}" 'assert_eq "shellcheck is clean for ${rel}" ""'
assert_contains ".shellcheckrc resolves sourced paths, matching that -x" \
    "$(cat "${SHELLCHECKRC}")" "external-sources=true"

# "informational findings included" is a claim about what is NOT there: no
# severity floor anywhere, and no check switched off in .shellcheckrc.
#
# Command position only. tests/test-quality-docs.sh holds the same property from
# the docs/review-rubric.md side and names `--severity` in an assertion string;
# matching that would be matching a test for this rule, not a breach of it.
severity_flags="$(cd "${REPO_ROOT}" &&
    git grep -nE '(^|[;&|(]|\$\()[[:space:]]*shellcheck[[:space:]][^"'"'"']*(--severity|[[:space:]]-S([[:space:]]|=))' -- . || true)"
assert_eq "no shellcheck invocation raises a severity floor" "" "${severity_flags}"
disabled="$(grep -E '^[[:space:]]*disable=' "${SHELLCHECKRC}" || true)"
assert_eq ".shellcheckrc switches no check off" "" "${disabled}"

# "Run ./tests/run-tests.sh with shellcheck installed; the suite skips that pass
# when it is missing, so a local green is weaker than CI's."
assert_contains "the rules name the runner by the path that exists" "${code_section}" "./tests/run-tests.sh"
assert_eq "and that runner is executable" \
    "100755" "$(cd "${REPO_ROOT}" && git ls-files -s -- tests/run-tests.sh | awk '{ print $1 }')"
assert_contains "tests/test-shell-syntax.sh runs shellcheck only when it is installed" \
    "${shell_syntax_text}" 'command -v shellcheck >/dev/null 2>&1'
assert_contains "and says so rather than failing" \
    "${shell_syntax_text}" "skip shellcheck (not installed)"

# "a local green is weaker than CI's" only holds while CI installs it.
ci_installs=""
for workflow in build.yml coverage-gate.yml; do
    path="${REPO_ROOT}/.github/workflows/${workflow}"
    if [[ -f "${path}" ]] && grep -qE 'apt-get install -y .*shellcheck' "${path}"; then
        continue
    fi
    ci_installs+="${workflow} "
done
assert_eq "CI installs shellcheck before running the suite, so its green is the stronger one" \
    "" "${ci_installs% }"

# "Shebang and executable bit on anything run by path" -- with tests/lib/ named
# as the exemption, because those two files are sourced and carry neither. The
# sets are computed, so adding a third library, or making one executable, fails.
lib_scripts="$(grep -E '^tests/lib/.*\.sh$' <<<"${tracked}" | LC_ALL=C sort)"
require_nonempty "the sourced library set" "${lib_scripts}"

wrong_mode=""
missing_shebang=""
while IFS= read -r script; do
    [[ -z "${script}" ]] && continue
    mode="$(cd "${REPO_ROOT}" && git ls-files -s -- "${script}" | awk '{ print $1 }')"
    first_line="$(head -1 "${REPO_ROOT}/${script}")"
    if grep -qxF "${script}" <<<"${lib_scripts}"; then
        [[ "${mode}" == "100644" ]] || wrong_mode+="${script}(exempt but ${mode}) "
        [[ "${first_line}" == '#!'* ]] && missing_shebang+="${script}(exempt but has a shebang) "
    else
        [[ "${mode}" == "100755" ]] || wrong_mode+="${script}(${mode}) "
        [[ "${first_line}" == '#!'* ]] || missing_shebang+="${script} "
    fi
done < <(grep -E '\.sh$' <<<"${tracked}")

assert_eq "every *.sh run by path is executable, and every sourced library is not" \
    "" "${wrong_mode% }"
assert_eq "every *.sh run by path carries a shebang, and no sourced library does" \
    "" "${missing_shebang% }"
assert_contains "tests/test-shell-syntax.sh exempts the same directory" \
    "${shell_syntax_text}" 'tests/lib/*'
assert_contains "and the rules state the exemption rather than claiming every *.sh" \
    "${code_section}" "tests/lib/"
assert_not_contains "so the rules no longer overstate the scope" \
    "${code_section}" "executable bit on every"

# "Four-space indent, except <scripts>, which are two." The exception list is
# read out of the rules and compared with .editorconfig's own two-space
# sections, both directions, so neither side can gain a script alone.
declared_two_space="$(sed -nE 's/^\[([^]]*\.sh)\][[:space:]]*$/\1/p' "${EDITORCONFIG}" |
    while IFS= read -r section; do
        awk -v want="[${section}]" '
            $0 == want { in_section = 1; next }
            /^\[/ { in_section = 0 }
            in_section && /^indent_size[[:space:]]*=[[:space:]]*2[[:space:]]*$/ { print substr(want, 2, length(want) - 2) }
        ' "${EDITORCONFIG}"
    done | LC_ALL=C sort -u | tr '\n' ' ')"
require_nonempty "the two-space scripts .editorconfig declares" "${declared_two_space}"

# One bullet, continuation lines included and the next bullet excluded: the
# rule that follows this one names tests/run-tests.sh, and swallowing it would
# make the comparison below pass for the wrong reason.
indent_rule="$(awk '
    /^-[[:space:]]+Four-space indent/ { in_rule = 1; print; next }
    in_rule && /^-[[:space:]]/ { in_rule = 0 }
    in_rule && /^[[:space:]]*$/ { in_rule = 0 }
    in_rule { print }
' <<<"${code_section}")"
require_nonempty "the rules' indentation bullet" "${indent_rule}"

documented_two_space="$(grep -oE '[A-Za-z0-9_./-]+\.sh' <<<"${indent_rule}" |
    LC_ALL=C sort -u | tr '\n' ' ')"
assert_eq "the rules' two-space exceptions are exactly the ones .editorconfig declares" \
    "${declared_two_space}" "${documented_two_space}"
assert_contains ".editorconfig sets four spaces for every other shell script" \
    "$(awk '/^\[\*\.sh\]/ { in_section = 1; next } /^\[/ { in_section = 0 } in_section' "${EDITORCONFIG}")" \
    "indent_size = 4"

# --- 5. the Testing reality section -----------------------------------------
#
# "build_files/build.sh, build_files/kernel-akmods.sh, build_files/zfs.sh and
# the Containerfile only execute inside an image build. Nothing on the host
# reaches them." That is the same decision tests/test-coverage.sh's manifest
# records, so the two must name the same scripts.

testing_section="$(doc_section "Testing reality")"

uncovered="$(grep -E '^[^[:space:]]+\.sh	UNCOVERED' "${COVERAGE_TEST}" | cut -f1 | LC_ALL=C sort | tr '\n' ' ')"
require_nonempty "the UNCOVERED set in tests/test-coverage.sh" "${uncovered}"

documented_uncovered="$(grep -oE 'build_files/[A-Za-z0-9_-]+\.sh' <<<"${testing_section}" |
    LC_ALL=C sort -u | tr '\n' ' ')"
require_nonempty "the scripts the rules call unreachable from the host" "${documented_uncovered}"
assert_eq "the rules name exactly the scripts the coverage manifest records as UNCOVERED" \
    "${uncovered}" "${documented_uncovered}"

# The other half of "only execute inside an image build": the Containerfile is
# what executes them, by path.
containerfile_text="$(cat "${CONTAINERFILE}")"
while IFS= read -r script; do
    [[ -z "${script}" ]] && continue
    assert_contains "the Containerfile runs ${script} by path" \
        "${containerfile_text}" "/ctx/$(basename "${script}")"
done < <(tr ' ' '\n' <<<"${uncovered}")

# ...and nothing on the host does. A test that sourced or ran one of them would
# make the rules' warning wrong, and the warning is the reason the manifest
# accepts three uncovered scripts at all.
# Command position again: tests/test-editorconfig.sh lists those paths inside a
# string it compares against, which is a mention and not an execution.
host_execs="$(cd "${REPO_ROOT}" &&
    grep -rnE '(^|[;&|(]|\$\()[[:space:]]*(source|\.|bash|sh)[[:space:]]+[^[:space:]"]*build_files/(build|kernel-akmods|zfs)\.sh' tests/ || true)"
assert_eq "no test on the host sources or runs those three scripts" "" "${host_execs}"

# "post-check.sh is partly covered through its sourceable helpers." Partly: the
# entry point is behind a BASH_SOURCE guard, which is the seam, and the manifest
# records the test that uses it.
assert_contains "build_files/post-check.sh has the BASH_SOURCE guard the rules imply" \
    "$(cat "${POST_CHECK}")" '"${BASH_SOURCE[0]}" == "${0}"'
assert_contains "and the coverage manifest records it as covered, not UNCOVERED" \
    "$(cat "${COVERAGE_TEST}")" "build_files/post-check.sh	tests/test-post-check.sh"
assert_contains "by a test that sources it" \
    "$(cat "${TEST_DIR}/test-post-check.sh")" "build_files/post-check.sh"
assert_contains "which is why the rules say partly rather than covered" \
    "${testing_section}" "partly covered"

finish
