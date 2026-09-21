#!/usr/bin/env bash
#
# Joins .github/copilot-instructions.md to the machine it describes.
#
# GitHub loads this file automatically before every Copilot suggestion in this
# repository, and nothing opened it. `grep -rF .github/copilot-instructions.md
# tests/` returned one hit before this file, and it does not read the document:
# test-labeler.sh asserts the path matches the `area/agents` glob.
# test-coverage.sh sees only shipped `*.sh`, and test-docs-paths.sh resolves
# paths named by README.md and AGENTS.md, not by this file.
#
# The document is aware of the risk -- its own opening paragraph says a second
# copy of AGENTS.md "would drift out of date and this repo has already been
# bitten by documentation that stopped matching the tree" -- and it drifted
# anyway, in exactly the pair of places .cursorrules drifted before it: the
# two-space exception list was short by one (.claude/hooks/gate-git-diff.sh),
# and the shebang rule claimed every `*.sh` when tests/lib/ is deliberately
# outside it. tests/test-cursorrules.sh corrected that pair in .cursorrules;
# this file was not corrected with it, so an agent reading it would still have
# written a four-space diff into a two-space script and chmod +x'd two sourced
# libraries. Correcting prose nothing reads only postpones the next copy.
#
# So every literal below is computed from the file the rule cites -- the
# Containerfile, ci/write-badges.sh, build_files/zfs.sh,
# build_files/kernel-akmods.sh, build_files/post-check.sh, .editorconfig,
# .shellcheckrc, .github/workflows/build.yml, tests/test-shell-syntax.sh,
# tests/test-coverage.sh -- and compared with what the document says. Editing
# one side alone is a red suite rather than a reader's problem. Extractions
# refuse to verify an empty set: a renamed section or a reworded rule fails
# here rather than passing vacuously.
#
# Scope: the claims that name something in this repository. Judgements that
# cannot be checked -- "most red builds here are not caused by this repo", "add
# to that style rather than stripping it" -- are left alone.
#
# Overlap with what already exists is deliberate and reached from the other
# side. test-shell-syntax.sh enforces the shebang and exec-bit rule directly;
# test-editorconfig.sh measures indentation; test-cursorrules.sh asks the same
# questions of .cursorrules. This file asks whether the document Copilot loads
# still describes the tree those tests enforce -- and, in the two places both
# agent-facing documents speak, whether they still agree with each other.

set -uo pipefail

TEST_NAME="test-copilot-instructions"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

DOC="${REPO_ROOT}/.github/copilot-instructions.md"
AGENTS="${REPO_ROOT}/AGENTS.md"
CURSORRULES="${REPO_ROOT}/.cursorrules"
CONTRIBUTING="${REPO_ROOT}/CONTRIBUTING.md"
CONTAINERFILE="${REPO_ROOT}/Containerfile"
WRITE_BADGES="${REPO_ROOT}/ci/write-badges.sh"
ZFS_SH="${REPO_ROOT}/build_files/zfs.sh"
KERNEL_AKMODS="${REPO_ROOT}/build_files/kernel-akmods.sh"
POST_CHECK="${REPO_ROOT}/build_files/post-check.sh"
EDITORCONFIG="${REPO_ROOT}/.editorconfig"
SHELLCHECKRC="${REPO_ROOT}/.shellcheckrc"
BUILD_WORKFLOW="${REPO_ROOT}/.github/workflows/build.yml"
SHELL_SYNTAX="${TEST_DIR}/test-shell-syntax.sh"
COVERAGE_TEST="${TEST_DIR}/test-coverage.sh"
RUN_TESTS="${TEST_DIR}/run-tests.sh"

for required in "${DOC}" "${AGENTS}" "${CURSORRULES}" "${CONTRIBUTING}" \
    "${CONTAINERFILE}" "${WRITE_BADGES}" "${ZFS_SH}" "${KERNEL_AKMODS}" \
    "${POST_CHECK}" "${EDITORCONFIG}" "${SHELLCHECKRC}" "${BUILD_WORKFLOW}" \
    "${SHELL_SYNTAX}" "${COVERAGE_TEST}" "${RUN_TESTS}"; do
    [[ -f "${required}" ]] && continue
    _fail "every file the instructions cite is present" \
        "no such file: ${required#"${REPO_ROOT}"/}" \
        "if it was removed on purpose, the instruction that cites it is now wrong"
    finish
    exit 1
done

DOC_TEXT="$(cat "${DOC}")"
CONTAINERFILE_TEXT="$(cat "${CONTAINERFILE}")"
BUILD_WORKFLOW_TEXT="$(cat "${BUILD_WORKFLOW}")"

# Fails rather than passing on an empty extraction. A reworded heading or a
# renamed section must not turn an assertion into a tautology.
require_nonempty() {
    local description=$1 value=$2
    if [[ -n "${value}" ]]; then
        _pass "extracted ${description}"
    else
        _fail "extracted ${description}" \
            "the extraction returned nothing, so everything below it would pass vacuously"
    fi
}

# Markdown wraps, so a sentence this document states is not a line. Collapse
# runs of whitespace before matching a phrase that could cross a line break;
# everything matched against a single line stays unsquashed.
squash() {
    tr '\n' ' ' | tr -s '[:space:]' ' '
}

# The `- ` bullet beginning with a given phrase, continuation lines included
# and the next bullet excluded. The bullet that follows the indent rule in all
# three documents names another script, and swallowing it would make the
# comparisons below pass for the wrong reason.
bullet() {
    awk -v phrase="$1" '
        index($0, "- " phrase) == 1 { in_rule = 1; print; next }
        in_rule && /^-[[:space:]]/ { in_rule = 0 }
        in_rule && /^[[:space:]]*$/ { in_rule = 0 }
        in_rule { print }
    '
}

# The body of one `## ` section, up to the next one.
doc_section() {
    awk -v want="$1" '
        /^## / { in_section = (substr($0, 4) == want); next }
        in_section { print }
    ' "${DOC}"
}

for section in "What this repo is" "The one thing to internalise" \
    "When writing code here" "When writing comments" \
    "What cannot be tested from the host"; do
    require_nonempty "the '${section}' section" "$(doc_section "${section}")"
done

# --- 1. the document points somewhere, and stays the short form -------------
#
# GitHub renders this file from .github/, so the link to AGENTS.md is relative
# and one directory up. A move of either file leaves Copilot's first
# instruction pointing at nothing, which reads as "there is no orientation
# document" rather than "it moved".

assert_contains "the instructions send the reader to AGENTS.md first" \
    "${DOC_TEXT}" "**Read [\`AGENTS.md\`](../AGENTS.md) first.**"

link_targets="$(grep -oE '\]\(([^)]+)\)' "${DOC}" | sed -E 's/^\]\(//; s/\)$//')"
require_nonempty "the links the instructions carry" "${link_targets}"

broken_links=""
while IFS= read -r target; do
    [[ -z "${target}" ]] && continue
    [[ "${target}" == http*://* ]] && continue
    # Relative to the document's own directory, which is how GitHub resolves it.
    resolved="$(cd "$(dirname "${DOC}")" && cd "$(dirname "${target}")" 2>/dev/null && pwd)/$(basename "${target}")"
    [[ -f "${resolved}" ]] || broken_links+="${target} "
done <<<"${link_targets}"
assert_eq "every relative link in the instructions resolves to a file" \
    "" "${broken_links% }"

tracked="$(cd "${REPO_ROOT}" && git ls-files)"
require_nonempty "the tracked file list" "${tracked}"

# Paths named in prose, not as links. A rename that misses this document leaves
# an instruction aimed at nothing. Repository-relative here: `./tests/...` is
# how the document writes a runnable command, and the one `../`-relative path
# is a link, already resolved against the document's directory above.
named_files="$(grep -ohE '[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+\.(sh|md|json|yml)' "${DOC}" |
    sed 's|^\./||' | grep -v '^\.\./' | LC_ALL=C sort -u)"
require_nonempty "the repository paths the instructions name" "${named_files}"

unresolved=""
while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    grep -qxF "${name}" <<<"${tracked}" || unresolved+="${name} "
done <<<"${named_files}"
assert_eq "every path the instructions name is a tracked file" "" "${unresolved% }"

# "it deliberately does not restate AGENTS.md" -- a file that grew past the
# document it defers to is no longer deferring to it, whatever the sentence
# still says.
doc_lines="$(wc -l <"${DOC}")"
agents_lines="$(wc -l <"${AGENTS}")"
if [[ "${doc_lines}" -lt "${agents_lines}" ]]; then
    _pass "the instructions are shorter than AGENTS.md, which is what 'does not restate' means"
else
    _fail "the instructions are shorter than AGENTS.md, which is what 'does not restate' means" \
        ".github/copilot-instructions.md: ${doc_lines} lines, AGENTS.md: ${agents_lines} lines"
fi

# --- 2. three prebuilt artifacts, two of which must agree -------------------
#
# Read out of the Containerfile's FROM lines rather than hard-coded here, so
# pinning one of them -- which AGENTS.md documents as an outage workaround --
# is visible to this test.

from_stages="$(grep -E '^FROM[[:space:]]' "${CONTAINERFILE}" |
    sed -nE 's/^FROM[[:space:]]+([^[:space:]]+)[[:space:]]+AS[[:space:]]+([A-Za-z0-9_-]+).*/\2 \1/p')"
require_nonempty "the Containerfile's FROM stages" "${from_stages}"

# `scratch` is the context stage, not an assembled artifact.
ublue_stages="$(awk '$2 ~ /ghcr\.io\/ublue-os\// || $2 ~ /AURORA_IMAGE/ { print $1 }' <<<"${from_stages}" |
    LC_ALL=C sort | tr '\n' ' ')"
assert_eq "the Containerfile assembles exactly the three artifacts the instructions name" \
    "akmods akmods-zfs base " "${ublue_stages}"
assert_contains "and the instructions say three" \
    "${DOC_TEXT}" "assembles three prebuilt Universal Blue artifacts"

# "Its correctness depends on two of those agreeing about the kernel version:
# akmods and akmods-zfs. The Aurora base is not one of them."
# ci/write-badges.sh is the code that makes that comparison, so the stages it
# inspects are the claim.
compared_stages="$(grep -oE 'from_ref[[:space:]]+[A-Za-z0-9_-]+' "${WRITE_BADGES}" |
    awk '{ print $2 }' | LC_ALL=C sort -u | tr '\n' ' ')"
assert_eq "ci/write-badges.sh compares exactly the two stages the instructions name" \
    "akmods akmods-zfs " "${compared_stages}"
assert_not_contains "and never inspects the Aurora base, which the instructions say is not one of them" \
    "${compared_stages}" "base"

for image in akmods akmods-zfs; do
    assert_contains "the instructions name ghcr.io/ublue-os/${image}" \
        "${DOC_TEXT}" "ghcr.io/ublue-os/${image}"
    assert_contains "and the Containerfile pulls it" \
        "${CONTAINERFILE_TEXT}" "ghcr.io/ublue-os/${image}:"
done

# "compare the ostree.linux label ... for the release the Containerfile
# targets" -- the label is a literal in both, and the release is read out of
# the Containerfile rather than restated.
assert_contains "the instructions name the ostree.linux label" "${DOC_TEXT}" "ostree.linux"
assert_contains "and ci/write-badges.sh reads that label" \
    "$(cat "${WRITE_BADGES}")" 'Labels["ostree.linux"]'
fedora_from_containerfile="$(sed -n 's/^ARG FEDORA_VERSION=\([0-9][0-9]*\).*/\1/p' "${CONTAINERFILE}" | head -1)"
require_nonempty "the Fedora release the Containerfile targets" "${fedora_from_containerfile}"
# shellcheck disable=SC2016 # the literal ${FEDORA_VERSION} is the needle
assert_contains "and both akmods tags carry that release rather than a pin" \
    "${CONTAINERFILE_TEXT}" 'ghcr.io/ublue-os/akmods-zfs:coreos-stable-"${FEDORA_VERSION}"'

# "It does not compile ZFS." Nothing in build_files/ may invoke a compiler or a
# module build, in command position.
compile_hits="$(grep -nE '(^|[;&|][[:space:]]*|^[[:space:]]+)(make|dkms|gcc|cc|akmods|\./configure)[[:space:]]' \
    "${REPO_ROOT}"/build_files/*.sh || true)"
assert_eq "no build_files script compiles anything, which is what 'prebuilt' means" \
    "" "${compile_hits}"

# "build_files/kernel-akmods.sh erases Aurora's kernel RPMs outright and
# installs the one from the akmods stream." Both halves, and the second one
# against the Containerfile mount that supplies it: the install path has to be
# the directory bound from the akmods stage, or the kernel is coming from
# somewhere the instructions do not describe.
kernel_akmods_text="$(cat "${KERNEL_AKMODS}")"
# shellcheck disable=SC2016 # the literal ${pkg} is the needle
assert_contains "kernel-akmods.sh erases the base kernel RPMs" \
    "${kernel_akmods_text}" 'rpm --erase "${pkg}" --nodeps'
assert_contains "over a package list that includes the kernel itself" \
    "${kernel_akmods_text}" "for pkg in kernel kernel-core"
# The whole line, not a prefix of it: `rm -rf /usr/lib/modules.bak` would
# satisfy a substring match while leaving the base module tree in place.
assert_eq "and removes the base module tree outright" \
    "rm -rf /usr/lib/modules" \
    "$(grep -E '^rm -rf /usr/lib/modules[[:space:]]*$' "${KERNEL_AKMODS}" | head -1)"

kernel_rpm_mount="$(sed -nE 's;.*--mount=type=bind,from=(akmods),src=/kernel-rpms,dst=([^[:space:],]+).*;\2;p' \
    "${CONTAINERFILE}" | head -1)"
require_nonempty "the Containerfile mount that supplies the akmods kernel RPMs" "${kernel_rpm_mount}"
assert_contains "and kernel-akmods.sh installs the replacement kernel from that mount" \
    "${kernel_akmods_text}" "dnf5 -y install \\
    ${kernel_rpm_mount}/kernel-[0-9]*.rpm"

# --- 3. never loosen the kmod-zfs glob --------------------------------------
#
# "Never 'fix' that failure by loosening the kmod-zfs glob in build_files/zfs.sh
# or making the install non-fatal." Both halves are checkable: the glob is
# anchored to the kernel just installed, and the install has no failure escape.

zfs_text="$(cat "${ZFS_SH}")"
# shellcheck disable=SC2016 # the literal ${KERNEL} is the anchor being asserted
assert_contains "the kmod-zfs glob is anchored to the replacement kernel" \
    "${zfs_text}" '/tmp/rpms/kmods/zfs/kmod-zfs-"${KERNEL}"*.rpm'
assert_contains "build_files/zfs.sh aborts on the first failure" "${zfs_text}" "set -eoux pipefail"

install_lines="$(grep -nE '^[[:space:]]*dnf5 .*install' "${ZFS_SH}")"
require_nonempty "the package installs in build_files/zfs.sh" "${install_lines}"
non_fatal="$(grep -E '\|\|[[:space:]]*(true|:)' <<<"${install_lines}" || true)"
assert_eq "no install in build_files/zfs.sh is made non-fatal" "" "${non_fatal}"

# The reason the instructions give -- "the failure moves from the build to the
# boot, where it is much worse" -- only holds while the script checks that the
# modules it installed are really there.
# shellcheck disable=SC2016 # the literal ${ZFS_MODULE_DIR} is the needle
assert_contains "build_files/zfs.sh fails the build when a module is missing" \
    "${zfs_text}" 'compgen -G "${ZFS_MODULE_DIR}/${module}.ko*"'

# --- 4. the "When writing code here" section --------------------------------

code_section="$(doc_section "When writing code here")"

# "It is shell. There is no package manager, no node_modules, and no build step."
manifests=""
for manifest in package.json package-lock.json yarn.lock requirements.txt \
    pyproject.toml setup.py Cargo.toml go.mod Gemfile Makefile justfile; do
    grep -qE "(^|/)${manifest}$" <<<"${tracked}" && manifests+="${manifest} "
done
assert_eq "the tree ships no package manager or build-step manifest" "" "${manifests% }"
assert_eq "and nothing under node_modules is tracked" \
    "" "$(grep -c '^node_modules/\|/node_modules/' <<<"${tracked}" | grep -v '^0$' || true)"

# "shellcheck -x must produce zero output, informational findings included. The
# test suite enforces this."
shell_syntax_text="$(cat "${SHELL_SYNTAX}")"
# shellcheck disable=SC2016 # the literal ${rel} is the needle
assert_contains "tests/test-shell-syntax.sh runs shellcheck with -x" \
    "${shell_syntax_text}" 'shellcheck -x "${rel}"'
# shellcheck disable=SC2016 # matching the assertion's own text, ${rel} included
assert_contains "and requires empty output rather than a severity floor" \
    "${shell_syntax_text}" 'assert_eq "shellcheck is clean for ${rel}" ""'
assert_contains ".shellcheckrc resolves sourced paths, matching that -x" \
    "$(cat "${SHELLCHECKRC}")" "external-sources=true"
disabled="$(grep -E '^[[:space:]]*disable=' "${SHELLCHECKRC}" || true)"
assert_eq ".shellcheckrc switches no check off, which is what 'informational included' means" \
    "" "${disabled}"

# "The test suite enforces this" is a claim about the suite, so the enforcing
# file has to be one run-tests.sh actually discovers: it globs test-*.sh in its
# own directory, and a file outside that glob enforces nothing.
assert_contains "run-tests.sh discovers tests by that glob" \
    "$(cat "${RUN_TESTS}")" "-name 'test-*.sh'"
assert_eq "and the enforcing file is inside it" \
    "tests/test-shell-syntax.sh" \
    "$(grep -xF 'tests/test-shell-syntax.sh' <<<"${tracked}")"

# "./tests/run-tests.sh is the suite. Install shellcheck before trusting a green
# run -- the suite skips that pass when the tool is absent."
assert_contains "the instructions name the runner by the path that exists" \
    "${code_section}" "./tests/run-tests.sh"
assert_eq "and that runner is executable" \
    "100755" "$(cd "${REPO_ROOT}" && git ls-files -s -- tests/run-tests.sh | awk '{ print $1 }')"
assert_contains "tests/test-shell-syntax.sh runs shellcheck only when it is installed" \
    "${shell_syntax_text}" 'command -v shellcheck >/dev/null 2>&1'
assert_contains "and says so rather than failing" \
    "${shell_syntax_text}" "skip shellcheck (not installed)"

# "Every *.sh needs a shebang and the executable bit" was the false version of
# this rule: tests/lib/ is sourced and carries neither, deliberately. The sets
# are computed from the tree, so adding a third library, or making one
# executable, fails here.
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
assert_contains "the instructions state that exemption rather than claiming every *.sh" \
    "${code_section}" "tests/lib/"
assert_not_contains "so the instructions no longer overstate the scope" \
    "${code_section}" "Every \`*.sh\`"

# "the Containerfile and the workflows run these scripts by path" is the reason
# the rule exists, so both halves have to still be true.
assert_contains "the Containerfile runs a build_files script by path" \
    "${CONTAINERFILE_TEXT}" "/ctx/build.sh"
assert_contains "and a workflow runs ci/write-badges.sh by path" \
    "${BUILD_WORKFLOW_TEXT}" "ci/write-badges.sh"

# "Four-space indentation, except <scripts>, which are two." The exception list
# is read out of the instructions and compared with .editorconfig's own
# two-space sections, both directions, so neither side can gain a script alone.
declared_two_space="$(sed -nE 's/^\[([^]]*\.sh)\][[:space:]]*$/\1/p' "${EDITORCONFIG}" |
    while IFS= read -r section; do
        awk -v want="[${section}]" '
            $0 == want { in_section = 1; next }
            /^\[/ { in_section = 0 }
            in_section && /^indent_size[[:space:]]*=[[:space:]]*2[[:space:]]*$/ { print substr(want, 2, length(want) - 2) }
        ' "${EDITORCONFIG}"
    done | LC_ALL=C sort -u | tr '\n' ' ')"
require_nonempty "the two-space scripts .editorconfig declares" "${declared_two_space}"

indent_rule="$(bullet "Four-space indentation" <<<"${code_section}")"
require_nonempty "the instructions' indentation bullet" "${indent_rule}"

documented_two_space="$(grep -oE '[A-Za-z0-9_./-]+\.sh' <<<"${indent_rule}" |
    LC_ALL=C sort -u | tr '\n' ' ')"
assert_eq "the instructions' two-space exceptions are exactly the ones .editorconfig declares" \
    "${declared_two_space}" "${documented_two_space}"
assert_contains ".editorconfig sets four spaces for every other shell script" \
    "$(awk '/^\[\*\.sh\]/ { in_section = 1; next } /^\[/ { in_section = 0 } in_section' "${EDITORCONFIG}")" \
    "indent_size = 4"

# --- 5. the two agent-facing documents still agree --------------------------
#
# .cursorrules, .github/copilot-instructions.md and CONTRIBUTING.md state the
# same two rules for three different readers. They drifted apart once already,
# in this direction: .cursorrules was corrected and this file was not. Compare
# the sets rather than the sentences, so a rewording that keeps the meaning
# passes and a correction applied to one document alone does not.

cursorrules_text="$(cat "${CURSORRULES}")"
contributing_text="$(cat "${CONTRIBUTING}")"

for document in "${cursorrules_text}" "${contributing_text}"; do
    sibling_rule="$(bullet "Four-space indent" <<<"${document}")"
    require_nonempty "a sibling document's indentation bullet" "${sibling_rule}"
    exceptions="$(grep -oE '[A-Za-z0-9_./-]+\.sh' <<<"${sibling_rule}" |
        LC_ALL=C sort -u | tr '\n' ' ')"
    require_nonempty "the two-space exceptions a sibling document names" "${exceptions}"
    assert_eq "every document that states the indent rule names the same exceptions" \
        "${declared_two_space}" "${exceptions}"
done

assert_contains ".cursorrules states the tests/lib/ exemption too" \
    "${cursorrules_text}" "tests/lib/"
assert_contains "and CONTRIBUTING.md states it as well" \
    "${contributing_text}" "tests/lib/"

# --- 6. the "When writing comments" section ---------------------------------
#
# This section is the one place the document points at specific comments and
# tells an agent not to remove them. A comment that has been deleted or moved
# leaves the instruction naming an incident with no code attached, which reads
# as "that workaround is gone".

comments_section="$(doc_section "When writing comments" | squash)"
require_nonempty "the comment rules as one line" "${comments_section}"

# The `.Config`-only podman inspect that works around MAX_ARG_STRLEN.
assert_contains "the instructions name the .Config-only inspect" \
    "${comments_section}" "\`.Config\`-only \`podman inspect\` that works around \`MAX_ARG_STRLEN\`"
assert_contains "and the workflow reads only that element" \
    "${BUILD_WORKFLOW_TEXT}" "podman inspect --format '{{json .Config}}'"
assert_contains "with the comment that records the limit it works around" \
    "${BUILD_WORKFLOW_TEXT}" "MAX_ARG_STRLEN"
# A full `podman inspect` anywhere in that workflow is the failure the comment
# describes, so its absence is the property, not the presence of the narrow one.
full_inspect="$(grep -nE 'podman inspect([[:space:]]+[^-[:space:]]|[[:space:]]*$)' "${BUILD_WORKFLOW}" || true)"
assert_eq "and no unformatted podman inspect was added beside it" "" "${full_inspect}"

# The badge script refusing to guess when an input is unreadable.
write_badges_text="$(cat "${WRITE_BADGES}")"
assert_contains "the instructions name the badge script's refusal to guess" \
    "${comments_section}" "the badge script refusing to guess when an input is unreadable"
assert_contains "and ci/write-badges.sh records that as deliberate" \
    "${write_badges_text}" "Refusing to guess is a deliberate property"
assert_contains "and says so in its output rather than inventing a version" \
    "${write_badges_text}" "<unreadable>"

# The push-once-then-copy tag propagation.
assert_contains "the instructions name the push-once-then-copy propagation" \
    "${comments_section}" "push-once-then-copy tag propagation"
assert_contains "the workflow pushes exactly one tag" \
    "${BUILD_WORKFLOW_TEXT}" "# Push exactly one tag."
# shellcheck disable=SC2016 # the literal ${DEFAULT_TAG} is the needle
assert_contains "and that tag is the default one" \
    "${BUILD_WORKFLOW_TEXT}" 'tags: ${{ env.DEFAULT_TAG }}'
assert_contains "the rest are copied from the pushed digest" \
    "${BUILD_WORKFLOW_TEXT}" "skopeo copy --preserve-digests"
# shellcheck disable=SC2016 # the literal ${digest} is the needle
assert_contains "with the digest as the copy source, not a second push" \
    "${BUILD_WORKFLOW_TEXT}" '"docker://${IMAGE_REGISTRY}/${IMAGE_NAME}@${digest}"'

# --- 7. the "What cannot be tested from the host" section -------------------
#
# The same decision tests/test-coverage.sh's manifest records, so the two must
# name the same scripts.

testing_section="$(doc_section "What cannot be tested from the host" | squash)"
require_nonempty "the unreachable-from-the-host section as one line" "${testing_section}"

uncovered="$(grep -E '^[^[:space:]]+\.sh	UNCOVERED' "${COVERAGE_TEST}" | cut -f1 | LC_ALL=C sort | tr '\n' ' ')"
require_nonempty "the UNCOVERED set in tests/test-coverage.sh" "${uncovered}"

documented_uncovered="$(grep -oE 'build_files/[A-Za-z0-9_-]+\.sh' <<<"${testing_section}" |
    grep -v 'post-check\.sh' | LC_ALL=C sort -u | tr '\n' ' ')"
require_nonempty "the scripts the instructions call unreachable from the host" "${documented_uncovered}"
assert_eq "the instructions name exactly the scripts the coverage manifest records as UNCOVERED" \
    "${uncovered}" "${documented_uncovered}"

# The other half of "only run inside an image build": the Containerfile is what
# runs them, by path.
while IFS= read -r script; do
    [[ -z "${script}" ]] && continue
    assert_contains "the Containerfile runs ${script} by path" \
        "${CONTAINERFILE_TEXT}" "/ctx/$(basename "${script}")"
done < <(tr ' ' '\n' <<<"${uncovered}")

# ...and nothing on the host does. A test that sourced or ran one of them would
# make the warning wrong, and the warning is the reason the manifest accepts
# three uncovered scripts at all.
# Command position only: tests/test-editorconfig.sh lists those paths inside a
# string it compares against, which is a mention and not an execution.
host_execs="$(
    cd "${REPO_ROOT}" || exit 1
    grep -rnE '(^|[;&|(]|\$\()[[:space:]]*(source|\.|bash|sh)[[:space:]]+[^[:space:]"]*build_files/(build|kernel-akmods|zfs)\.sh' tests/ || true
)"
assert_eq "no test on the host sources or runs those three scripts" "" "${host_execs}"

# "build_files/post-check.sh is partly covered through its sourceable helpers."
# Partly: the entry point is behind a BASH_SOURCE guard, which is the seam, and
# the manifest records the test that uses it.
# shellcheck disable=SC2016 # the literal ${BASH_SOURCE[0]} is the needle
assert_contains "build_files/post-check.sh has the BASH_SOURCE guard the instructions imply" \
    "$(cat "${POST_CHECK}")" '"${BASH_SOURCE[0]}" == "${0}"'
assert_contains "and the coverage manifest records it as covered, not UNCOVERED" \
    "$(cat "${COVERAGE_TEST}")" "build_files/post-check.sh	tests/test-post-check.sh"
assert_contains "by a test that sources it" \
    "$(cat "${TEST_DIR}/test-post-check.sh")" "build_files/post-check.sh"
assert_contains "which is why the instructions say partly rather than covered" \
    "${testing_section}" "partly covered"

# The Containerfile is named in the same sentence as the three scripts, and is
# unreachable for the same reason: nothing on the host builds it. tests/e2e/ is
# the exception the section does not have to mention, because it is not the
# suite -- run-tests.sh globs tests/test-*.sh at depth 1 and never descends.
assert_contains "the instructions name the Containerfile as unreachable too" \
    "${testing_section}" "\`Containerfile\`"
assert_contains "and run-tests.sh does not descend into tests/e2e/" \
    "$(cat "${RUN_TESTS}")" "-maxdepth 1"

finish
