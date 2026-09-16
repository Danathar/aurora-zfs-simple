#!/usr/bin/env bash
#
# Joins .claude/memory/corrections.md to the machine it describes.
#
# That file exists to be believed. `.claude/memory/README.md` says an entry
# earns its place when someone confidently believed something false and it cost
# time, and every agent configuration in this tree -- CLAUDE.md, AGENTS.md,
# .cursorrules, the prompts under .github/prompts/ -- points a reader at the
# memory before it points them at the code. Nothing opened it. `grep -rl
# '.claude/memory' tests/` returned nothing before this file, tests/test-coverage.sh
# sees only shipped `*.sh`, and tests/test-docs-paths.sh resolves paths named by
# README.md and AGENTS.md, not by this document.
#
# Prose that nothing opens is prose that drifts, and this document drifts in a
# particularly expensive direction: every entry is a claim about how the build
# behaves *today*, written in the past tense of an incident. Move the Chunkah
# step, change what `--config-str` is handed, drop the `shellcheck` skip branch,
# or renumber the upstream PRs AGENTS.md sends a reader to, and the memory keeps
# confidently asserting the previous repository -- to exactly the reader who came
# here to avoid rediscovering something.
#
# So every literal below is computed from the file the entry cites -- the
# Containerfile, .github/workflows/build.yml, AGENTS.md, build_files/kernel-akmods.sh,
# tests/test-shell-syntax.sh -- and compared with what the entry says. Editing
# one side alone is a red suite rather than a reader's problem. Extractions
# refuse to verify an empty set: a renamed step or a deleted section fails here.
#
# Scope: the claims that name something in this repository, plus the entry shape
# README.md requires. Judgements about upstream ("usually correct", "worse
# than") are not checkable and are left alone. The two properties
# tests/test-agent-prompts.sh already holds -- the Containerfile's two akmods
# `FROM` lines carrying one tag, and kernel-akmods.sh erasing the base module
# tree -- are reached here from a different side, through what AGENTS.md's own
# pin example and diagnosis block say, so neither test stands in for the other.

set -uo pipefail

TEST_NAME="test-memory-corrections"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

DOC="${REPO_ROOT}/.claude/memory/corrections.md"
MEMORY_README="${REPO_ROOT}/.claude/memory/README.md"
CONTAINERFILE="${REPO_ROOT}/Containerfile"
BUILD_WF="${REPO_ROOT}/.github/workflows/build.yml"
AGENTS="${REPO_ROOT}/AGENTS.md"
KERNEL_AKMODS="${REPO_ROOT}/build_files/kernel-akmods.sh"
SHELL_SYNTAX="${TEST_DIR}/test-shell-syntax.sh"
WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

assert_file_exists ".claude/memory/corrections.md is present" "${DOC}"
assert_file_exists ".claude/memory/README.md is present" "${MEMORY_README}"

for required in "${DOC}" "${MEMORY_README}" "${CONTAINERFILE}" "${BUILD_WF}" \
    "${AGENTS}" "${KERNEL_AKMODS}" "${SHELL_SYNTAX}"; do
    [[ -f "${required}" ]] && continue
    _fail "every file the corrections cite is present" \
        "no such file: ${required#"${REPO_ROOT}"/}" \
        "if it was removed on purpose, the correction that cites it is now wrong"
    finish
    exit 1
done

DOC_TEXT="$(cat "${DOC}")"
AGENTS_TEXT="$(cat "${AGENTS}")"

# --- 1. the shape README.md requires ----------------------------------------
#
# The four labels are not hard-coded as a house style; each one is paired with
# the phrase in README.md that asks for it, and that phrase is asserted to still
# be there. Rewriting the contract in README.md without rewriting this table
# fails, which is the only way the table stays a join rather than a second
# opinion.

LABELS=("Believed" "True" "Established by" "Avoid by")
README_PHRASES=(
    "what was believed"
    "what is true"
    "how it was established"
    "the cheapest way to avoid it"
)

MEMORY_README_TEXT="$(cat "${MEMORY_README}")"
for i in "${!LABELS[@]}"; do
    assert_contains "README.md still asks for '${LABELS[${i}]}'" \
        "${MEMORY_README_TEXT}" "${README_PHRASES[${i}]}"
done

mapfile -t ENTRY_TITLES < <(grep '^## ' "${DOC}" | sed 's/^## //')

if [[ "${#ENTRY_TITLES[@]}" -eq 0 ]]; then
    _fail "corrections.md has entries" \
        "no '## ' heading found; the extraction below would verify nothing"
    finish
    exit 1
fi
_pass "corrections.md has entries (${#ENTRY_TITLES[@]})"

# The body of entry N, where N is 1-based in document order.
entry_body() {
    local want=$1
    awk -v want="${want}" '
        /^## / { n++; if (n > want) exit; if (n == want) { grab = 1; next } }
        grab   { print }
    ' "${DOC}"
}

for i in "${!ENTRY_TITLES[@]}"; do
    body="$(entry_body "$((i + 1))")"
    title="${ENTRY_TITLES[${i}]}"
    if [[ -z "${body//[[:space:]]/}" ]]; then
        _fail "entry '${title}' has a body" "the extraction returned nothing"
        continue
    fi
    for label in "${LABELS[@]}"; do
        assert_contains "entry '${title}' records ${label}" "${body}" "**${label}:**"
    done
done

# And the other direction: a label nobody declared is a label nobody checks.
while IFS= read -r label; do
    [[ -z "${label}" ]] && continue
    found=0
    for known in "${LABELS[@]}"; do
        [[ "${label}" == "${known}" ]] && found=1
    done
    if [[ "${found}" -eq 1 ]]; then
        _pass "the '${label}:' label is one README.md asks for"
    else
        _fail "the '${label}:' label is one README.md asks for" \
            "corrections.md uses a label this test does not know about;" \
            "add it to LABELS with the README.md phrase that asks for it"
    fi
done < <(grep -o '^\*\*[^*]*:\*\*' "${DOC}" | sed 's/^\*\*//; s/:\*\*$//' | sort -u)

assert_contains "corrections.md points back at README.md for what belongs here" \
    "${DOC_TEXT}" "[\`README.md\`](README.md)"

# --- 2. every repository path the corrections name still exists --------------
#
# Entries cite the file that settles them, and a citation to a path that moved
# is the failure mode README.md calls worse than no entry at all. Bare file
# names are resolved by basename, which is how the document writes them.
#
# What counts as a citation is computed from the tree rather than listed, so a
# citation cannot escape by being renamed to something the list never mentioned.
# A backticked token is one when it has a directory component, when its suffix
# is one this repository tracks, or when its stem names a tracked file -- that
# last rule is what catches `post-check.bash` and `kernel-akmods.bash`, which a
# suffix list would drop as unrecognized and therefore never resolve. Values
# that only look like files -- `ostree.linux`, `.Config`, `RootFS.Layers` --
# match none of the three and stay out of it.

TRACKED="$(cd "${REPO_ROOT}" && git ls-files)"
# A suffix is one to eight alphanumerics after the last dot; a stem is the name
# with that suffix removed, or the whole name when it has no such suffix.
TRACKED_NAMES=""
TRACKED_SUFFIXES=""
TRACKED_STEMS=""
while IFS= read -r tracked_path; do
    tracked_name="${tracked_path##*/}"
    TRACKED_NAMES+="${tracked_name}"$'\n'
    if [[ "${tracked_name}" =~ ^(.*)\.([A-Za-z0-9]{1,8})$ ]]; then
        TRACKED_STEMS+="${BASH_REMATCH[1]}"$'\n'
        TRACKED_SUFFIXES+="${BASH_REMATCH[2]}"$'\n'
    else
        TRACKED_STEMS+="${tracked_name}"$'\n'
    fi
done <<<"${TRACKED}"
TRACKED_NAMES="$(sort -u <<<"${TRACKED_NAMES%$'\n'}")"
TRACKED_SUFFIXES="$(sort -u <<<"${TRACKED_SUFFIXES%$'\n'}")"
TRACKED_STEMS="$(sort -u <<<"${TRACKED_STEMS%$'\n'}")"

if [[ -z "${TRACKED_SUFFIXES}" || -z "${TRACKED_STEMS}" ]]; then
    _fail "the tracked file names were read" "git ls-files produced none"
    finish
    exit 1
fi

# Is this backticked token naming a file at all?
looks_like_a_path() {
    local token=$1 base suffix stem
    [[ "${token}" == */* ]] && return 0
    [[ "${token}" == Containerfile ]] && return 0
    base="${token##*/}"
    [[ "${base}" == *.* ]] || return 1
    suffix="${base##*.}"
    stem="${base%.*}"
    [[ -n "${stem}" ]] || return 1
    grep -qxF "${suffix}" <<<"${TRACKED_SUFFIXES}" && return 0
    grep -qxF "${stem}" <<<"${TRACKED_STEMS}" && return 0
    return 1
}

path_checks=0
while IFS= read -r token; do
    [[ -z "${token}" ]] && continue
    candidate="${token#./}"
    looks_like_a_path "${candidate}" || continue
    path_checks=$((path_checks + 1))
    if grep -qxF "${candidate}" <<<"${TRACKED}"; then
        _pass "corrections.md cites a tracked path: ${candidate}"
    elif grep -qxF "${candidate}" <<<"${TRACKED_NAMES}"; then
        _pass "corrections.md cites a tracked file by name: ${candidate}"
    else
        _fail "corrections.md cites a tracked path: ${candidate}" \
            "git tracks no such file; the entry cites something that moved"
    fi
done < <(
    # shellcheck disable=SC2016 # a backtick is the delimiter being matched, not a command
    grep -o '`[^`]*`' "${DOC}" |
        tr -d '`' |
        grep -E '^\.?/?[A-Za-z0-9][A-Za-z0-9._/-]*$' |
        sort -u
)

if [[ "${path_checks}" -eq 0 ]]; then
    _fail "corrections.md cites repository paths" \
        "no backticked path matched; the resolver above verified nothing"
fi

# --- 3. the workflow the entries describe -----------------------------------

if ! "${WORKFLOW_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    _fail "reading build.yml requires Python 3 with PyYAML" \
        "install python3-yaml (Debian/Ubuntu) or python3-pyyaml (Fedora)," \
        "or install PyYAML in the interpreter selected by WORKFLOW_PYTHON"
    finish
    exit 1
fi

NORMALIZER="${TMP_ROOT}/normalize.py"
cat >"${NORMALIZER}" <<'PY'
"""Print one workflow file as JSON, with the `on:` key readable by name.

PyYAML implements YAML 1.1, where a bare `on` is the boolean true, so
doc["on"] raises KeyError on every workflow ever written.
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

BUILD_JSON="${TMP_ROOT}/build.json"
if ! "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${BUILD_WF}" >"${BUILD_JSON}" 2>"${TMP_ROOT}/normalize.err"; then
    _fail "build.yml parses" "$(cat "${TMP_ROOT}/normalize.err")"
    finish
    exit 1
fi
_pass "build.yml parses"

step_names() {
    jq -r --arg job "$1" '.jobs[$job].steps[] | .name // empty' <"${BUILD_JSON}"
}

step_index() {
    local job=$1 name=$2
    step_names "${job}" | grep -nxF "${name}" | head -1 | cut -d: -f1
}

step_run() {
    jq -r --arg job "$1" --arg name "$2" \
        '.jobs[$job].steps[] | select(.name == $name) | .run // empty' <"${BUILD_JSON}"
}

# --- 3a. "post-check.sh and bootc container lint run before Chunkah" ---------
#
# The entry's whole point is an ordering, so the ordering is what is asserted:
# both checks are RUN steps in the Containerfile, the rechunk happens after the
# build step that executes them, and nothing from the rechunk onward re-runs
# either one.

# One Containerfile RUN instruction per line, continuations folded in.
mapfile -t RUN_BLOCKS < <(
    awk '
        /^RUN / { if (block != "") print block; block = $0; prev = $0; next }
        block != "" {
            if (prev ~ /\\[[:space:]]*$/) { block = block " " $0 }
            else { print block; block = "" }
        }
        { prev = $0 }
        END { if (block != "") print block }
    ' "${CONTAINERFILE}"
)

if [[ "${#RUN_BLOCKS[@]}" -lt 2 ]]; then
    _fail "the Containerfile still ends in two RUN steps" \
        "found ${#RUN_BLOCKS[@]} RUN instruction(s)"
else
    last="${RUN_BLOCKS[$((${#RUN_BLOCKS[@]} - 1))]}"
    second_last="${RUN_BLOCKS[$((${#RUN_BLOCKS[@]} - 2))]}"
    assert_contains "the Containerfile's last RUN is the image lint" \
        "${last}" "bootc container lint"
    assert_contains "the RUN before it is post-check.sh" \
        "${second_last}" "/ctx/post-check.sh"
fi

BUILD_IMAGE_STEP="Build Image"
RECHUNK_STEP="Rechunk Image with Chunkah"
DIGEST_STEP="Verify pushed tags share one digest"

build_idx="$(step_index build_push "${BUILD_IMAGE_STEP}")"
rechunk_idx="$(step_index build_push "${RECHUNK_STEP}")"

if [[ -z "${build_idx}" || -z "${rechunk_idx}" ]]; then
    _fail "build.yml still has the steps the entry names" \
        "'${BUILD_IMAGE_STEP}' -> '${build_idx:-missing}'," \
        "'${RECHUNK_STEP}' -> '${rechunk_idx:-missing}'"
else
    if [[ "${build_idx}" -lt "${rechunk_idx}" ]]; then
        _pass "the Containerfile's checks run in '${BUILD_IMAGE_STEP}', before the rechunk"
    else
        _fail "the Containerfile's checks run in '${BUILD_IMAGE_STEP}', before the rechunk" \
            "step ${build_idx} is not before step ${rechunk_idx}"
    fi

    # Everything from the rechunk onward, names and bodies together.
    after_rechunk="$(jq -r --argjson i "$((rechunk_idx - 1))" \
        '.jobs.build_push.steps[$i:][] | (.name // "") + "\n" + (.run // "")' <"${BUILD_JSON}")"
    if [[ -z "${after_rechunk//[[:space:]]/}" ]]; then
        _fail "the steps from the rechunk onward were read" "the slice was empty"
    else
        assert_not_contains "nothing from the rechunk onward re-runs post-check.sh" \
            "${after_rechunk}" "post-check.sh"
        assert_not_contains "nothing from the rechunk onward re-runs the image lint" \
            "${after_rechunk}" "bootc container lint"
        for expected in "${DIGEST_STEP}" "Push To GHCR" "Sign container image"; do
            assert_contains "the rechunked image is still ${expected,}" \
                "${after_rechunk}" "${expected}"
        done
    fi
fi

# The entry credits that digest check with establishing tag identity and nothing
# more, so it has to still be comparing digests rather than content.
digest_body="$(step_run build_push "${DIGEST_STEP}")"
if [[ -z "${digest_body}" ]]; then
    _fail "the '${DIGEST_STEP}' step still has a body" "extracted nothing"
else
    assert_contains "'${DIGEST_STEP}' compares digests, which is all the entry credits it with" \
        "${digest_body}" "Digest"
fi

# --- 3b. "a full podman inspect for --config-str breaks at scale" ------------
#
# Every number in this entry is a copy of a number in the rechunk step's
# comments, so each one is read out of the workflow and required to appear in
# the entry rather than typed in twice here.

rechunk_body="$(step_run build_push "${RECHUNK_STEP}")"
if [[ -z "${rechunk_body}" ]]; then
    _fail "the '${RECHUNK_STEP}' step still has a body" "extracted nothing"
else
    # shellcheck disable=SC2016 # workflow shell, compared as literal text
    config_assignment="$(grep -F 'CHUNKAH_CONFIG_STR="$(' <<<"${rechunk_body}")"
    if [[ -z "${config_assignment}" ]]; then
        _fail "the rechunk step still computes CHUNKAH_CONFIG_STR" "no assignment found"
    else
        # shellcheck disable=SC2016
        assert_contains "--config-str is handed the .Config element, not a whole inspect" \
            "${config_assignment}" "--format '{{json .Config}}'"
    fi

    for literal in $'MAX_ARG_STRLEN' $'E2BIG'; do
        assert_contains "the rechunk step still records ${literal}" \
            "${rechunk_body}" "${literal}"
        assert_contains "and the entry repeats ${literal}" "${DOC_TEXT}" "${literal}"
    done

    cap="$(grep -oE '[0-9]+ KiB' <<<"${rechunk_body}" | head -1)"
    layers="$(grep -oE 'from [0-9]+ to [0-9]+ layers' <<<"${rechunk_body}" | head -1)"
    config_size="$(grep -oE '~[0-9.]+ KiB' <<<"${rechunk_body}" | head -1)"
    exit_code="$(grep -oE 'exit 1[0-9]{2}' <<<"${rechunk_body}" | head -1)"

    if [[ -z "${cap}" || -z "${layers}" || -z "${config_size}" || -z "${exit_code}" ]]; then
        _fail "the rechunk step's incident numbers were read" \
            "cap='${cap}' layers='${layers}' config='${config_size}' exit='${exit_code}'"
    else
        assert_contains "the entry states the workflow's argv cap (${cap})" \
            "${DOC_TEXT}" "${cap}"
        assert_contains "the entry states the workflow's layer growth (${layers})" \
            "${DOC_TEXT}" "${layers}"
        # The workflow writes "~1.5 KiB" and the entry "around 1.5 KiB"; the
        # number is the claim, the tilde is prose.
        assert_contains "the entry states the workflow's .Config size (${config_size})" \
            "${DOC_TEXT}" "${config_size#\~}"
        assert_contains "the entry states the workflow's failure code (${exit_code})" \
            "${DOC_TEXT}" "${exit_code#exit }"
    fi
fi

# --- 3c. "a green local test run is weaker than a green CI run" --------------

shell_syntax_text="$(cat "${SHELL_SYNTAX}")"
assert_contains "test-shell-syntax.sh still decides on shellcheck's presence" \
    "${shell_syntax_text}" "command -v shellcheck"

skip_notice="$(grep -oE 'skip shellcheck \([^)]*\)' "${SHELL_SYNTAX}" | head -1)"
if [[ -z "${skip_notice}" ]]; then
    _fail "test-shell-syntax.sh still announces the skip" \
        "no 'skip shellcheck (...)' notice found; the entry tells a reader to look for one"
else
    assert_contains "the entry quotes the notice the runner actually prints" \
        "${DOC_TEXT}" "${skip_notice}"
fi

# "The bar in CI is zero output, informational findings included."
# shellcheck disable=SC2016
assert_contains "the shellcheck bar is still empty output" \
    "${shell_syntax_text}" 'assert_eq "shellcheck is clean for ${rel}" "" "${output}"'

install_idx="$(step_index tests "Install shellcheck")"
suite_idx="$(step_index tests "Run shell test suite")"
if [[ -z "${install_idx}" || -z "${suite_idx}" ]]; then
    _fail "the Shell tests job still installs shellcheck before running the suite" \
        "'Install shellcheck' -> '${install_idx:-missing}'," \
        "'Run shell test suite' -> '${suite_idx:-missing}'"
elif [[ "${install_idx}" -lt "${suite_idx}" ]]; then
    _pass "CI installs shellcheck before running the suite, which is why it enforces the skip"
else
    _fail "CI installs shellcheck before running the suite, which is why it enforces the skip" \
        "step ${install_idx} is not before step ${suite_idx}"
fi

assert_contains "the Install shellcheck step installs the tool the entry names" \
    "$(step_run tests "Install shellcheck")" "shellcheck"

# --- 4. the AGENTS.md claims -------------------------------------------------

# --- 4a. "gh pr list hides the window you are looking for" ------------------

# shellcheck disable=SC2016 # Markdown code spans, compared as literal text
assert_contains "AGENTS.md still states the default the entry warns about" \
    "${AGENTS_TEXT}" '`gh pr list` defaults to `--state open`'

# The PR numbers are read out of AGENTS.md, so renumbering there fails here
# rather than leaving the memory pointing at PRs nobody is told to look for.
mapfile -t HIDDEN_PRS < <(
    grep -oE 'The default also hides #[0-9]+ and #[0-9]+' "${AGENTS}" |
        grep -oE '#[0-9]+'
)
if [[ "${#HIDDEN_PRS[@]}" -ne 2 ]]; then
    _fail "AGENTS.md still names the two PRs the default hides" \
        "found ${#HIDDEN_PRS[@]}: ${HIDDEN_PRS[*]:-none}"
else
    for pr in "${HIDDEN_PRS[@]}"; do
        assert_contains "the entry names the same hidden PR (${pr})" "${DOC_TEXT}" "${pr}"
    done
fi

# "Avoid by: always --state all when checking upstream for a fix in flight" is
# only advice if the tree itself keeps taking it. This file is excluded along
# with the entry: the query string appears here as the thing being searched
# for, and matching it would count this test's own source as a query.
upstream_queries=0
while IFS= read -r line; do
    upstream_queries=$((upstream_queries + 1))
    if [[ "${line}" == *"--state all"* ]]; then
        _pass "an upstream akmods PR query passes --state all"
    else
        _fail "an upstream akmods PR query passes --state all" \
            "this one does not: ${line}"
    fi
done < <(
    cd "${REPO_ROOT}" &&
        git grep -h 'gh pr list --repo ublue-os/akmods' -- \
            ':!.claude/memory/corrections.md' ':!tests/test-memory-corrections.sh'
)
if [[ "${upstream_queries}" -eq 0 ]]; then
    _fail "the tree still queries upstream akmods PRs" \
        "no 'gh pr list --repo ublue-os/akmods' found; the entry's advice applies to nothing"
fi

# --- 4b. "a differing aurora-dx kernel is not skew" -------------------------

assert_contains "AGENTS.md's diagnosis still loops exactly the two akmods images" \
    "${AGENTS_TEXT}" "for img in akmods akmods-zfs"
assert_contains "and marks the aurora-dx inspect as context rather than part of the test" \
    "${AGENTS_TEXT}" "# context only — not part of the skew test"
# shellcheck disable=SC2016 # a Markdown code span, compared as literal text
assert_contains "AGENTS.md still says a differing aurora-dx kernel is not skew" \
    "${AGENTS_TEXT}" 'Do **not** treat a differing `aurora-dx` kernel as skew'

kernel_akmods_text="$(cat "${KERNEL_AKMODS}")"
# shellcheck disable=SC2016 # the script's own expansion, compared as literal text
assert_contains "kernel-akmods.sh still erases the base image's kernel RPMs" \
    "${kernel_akmods_text}" 'rpm --erase "${pkg}" --nodeps'
assert_contains "and still installs the kernel from the akmods stream" \
    "${kernel_akmods_text}" "/tmp/kernel-rpms/kernel-"

# --- 4c. "pinning one akmods input is worse than pinning neither" -----------
#
# AGENTS.md's worked pin is the one place the mixed-stream case is written down,
# and the entry's safety property is that both lines carry the same kernel. The
# streams may differ; the kernel version may not.

mapfile -t PIN_EXAMPLE < <(grep -E '^FROM ghcr.io/ublue-os/akmods(-zfs)?:' "${AGENTS}")
if [[ "${#PIN_EXAMPLE[@]}" -ne 2 ]]; then
    _fail "AGENTS.md still shows both akmods FROM lines pinned together" \
        "found ${#PIN_EXAMPLE[@]} line(s); the entry's safety property has no example"
else
    kernels=()
    for line in "${PIN_EXAMPLE[@]}"; do
        tag="${line#*:}"
        tag="${tag%% *}"
        # Drop the stream prefix (coreos-stable / coreos-testing); what is left
        # is the Fedora major and kernel the two stages have to share.
        kernels+=("$(sed -E 's/^coreos-[a-z]+-//' <<<"${tag}")")
    done
    assert_eq "AGENTS.md's pin example carries one kernel across both stages" \
        "${kernels[0]}" "${kernels[1]}"
    if [[ "${PIN_EXAMPLE[0]}" == "${PIN_EXAMPLE[1]}" ]]; then
        _fail "the example pins two distinct stages" "both lines are identical"
    else
        _pass "the example pins two distinct stages"
    fi
fi

# shellcheck disable=SC2016 # a Markdown code span, compared as literal text
assert_contains "AGENTS.md still requires the labels be confirmed identical before pushing" \
    "${AGENTS_TEXT}" 'Verify the `ostree.linux` labels are identical before doing this'

finish
