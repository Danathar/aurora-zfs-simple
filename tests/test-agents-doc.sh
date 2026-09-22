#!/usr/bin/env bash
#
# Joins AGENTS.md to the machine it describes.
#
# AGENTS.md is the file an agent is pointed at first when a build goes red.
# `.github/copilot-instructions.md` and `.cursorrules` both open by sending the
# reader here and are measured against it; the issue chooser deep-links into its
# skew section; `docs/risk-tiers.md` classifies it as load-bearing prose. Six
# tests read it as a *source* — test-issue-templates.sh compares the 60-second
# diagnosis against the copy embedded in `build-failure.yml`, test-reflections.sh
# holds the Chunkah numbers equal across three files, test-memory-corrections.sh
# checks the `--state all` query, test-quality-docs.sh checks the review-bot
# endpoint — and not one of them reads it as a *subject*. Every claim those
# tests do not happen to quote was unchecked, in the longest document here and
# the one most likely to be followed literally at 2am.
#
# It had already drifted. The Symptom section named the failing step
# `Build and push image`; that is the *job* name in `.github/workflows/build.yml`
# — `auto-qa-tuning.json` and `auto-qa.yml` both use it as one — and the step is
# `Build Image`. The document said so itself 200 lines later ("skew always dies
# inside `zfs.sh` during `Build Image`"), as does `.claude/memory/corrections.md`.
# So the first instruction an agent follows, in the section it is sent to, told
# it to look for a step name `gh run view --log-failed` never prints.
#
# What is checked here is the part of the document that is a claim about this
# repository, recomputed from the repository rather than restated:
#
#   * every step name it tells an agent to look at, against the step names
#     build.yml actually defines — and, in the other direction, no *job* name of
#     build.yml written as a step, which is the failure above;
#   * the three-upstream-inputs table against the `Containerfile`: each image
#     reference against the `FROM` line it cites, in both directions, each
#     "Referenced at" cell against a real `ARG` or stage name, and each
#     "Provides" path against the bind mount that supplies it from that stage;
#   * the numbered build pipeline against the `/ctx/*.sh` invocations in the
#     `Containerfile`, in order, and each step's claims against the script it
#     names;
#   * the Symptom block's RPM path and `Error: building at STEP` line against
#     `build_files/zfs.sh` and the `RUN` that invokes it, and the "only
#     `kmod-zfs` is kernel-versioned" claim against `ZFS_RPMS` itself;
#   * the 60-second diagnosis against the `Containerfile`'s `FEDORA_VERSION`,
#     the two akmods repositories and the `ostree.linux` label
#     `ci/write-badges.sh` reads;
#   * the Fix options against build.yml's schedule and `workflow_dispatch`, and
#     the mixed-pin example against the stage names it would replace;
#   * the Chunkah section against the `Rechunk Image with Chunkah` step body;
#   * its links, its one in-page anchor, that every `bash` block parses and
#     every `--jq` filter compiles.
#
# Judgement is left alone: why waiting is usually right, what a `coreos-testing`
# kmod costs, the upstream issue map and the incident log's account of what
# OpenZFS maintainers said are not claims about this tree and nothing here tries
# to check them. The incident log's *internal* agreement is checked only where
# the document tells a reader to act on it.
#
# The extractors are run against a fixture with known answers first. An
# extractor that quietly returned nothing would make every assertion below
# vacuously true, and the step-claim reader in particular is shape-sensitive in
# a way no reader of the document can see: Markdown wraps, so `` `Test Image`
# step`` is split across two lines in the source and only matches once the
# prose is flattened.

# Most of what this file matches is shell source and Markdown code spans:
# `${KERNEL}` as zfs.sh writes it, a backtick class for a code span, `${img}`
# as the document's own loop writes it. Every one of those has to reach the
# matcher unexpanded, so the single quotes are the point rather than an
# oversight, and SC2016 is off for the file rather than repeated above each.
# shellcheck disable=SC2016

set -uo pipefail

TEST_NAME="test-agents-doc"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=tests/lib/markdown.sh
source "${TEST_DIR}/lib/markdown.sh"

AGENTS_DOC="${REPO_ROOT}/AGENTS.md"
BUILD_WF="${REPO_ROOT}/.github/workflows/build.yml"
CONTAINERFILE="${REPO_ROOT}/Containerfile"
KERNEL_AKMODS_SH="${REPO_ROOT}/build_files/kernel-akmods.sh"
ZFS_SH="${REPO_ROOT}/build_files/zfs.sh"
WRITE_BADGES="${REPO_ROOT}/ci/write-badges.sh"
WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"

missing_input=0
for required in "${AGENTS_DOC}" "${BUILD_WF}" "${CONTAINERFILE}" \
    "${KERNEL_AKMODS_SH}" "${ZFS_SH}" "${WRITE_BADGES}"; do
    if [[ -f "${required}" ]]; then
        _pass "$(basename "${required}") is present"
    else
        _fail "$(basename "${required}") is present" "no such file: ${required}"
        missing_input=1
    fi
done
if [[ "${missing_input}" -ne 0 ]]; then
    finish
    exit 1
fi

# PyYAML is already a requirement of this suite (CONTRIBUTING.md). The step
# names below have to come from the parser rather than from a `grep` for
# `- name:`: `run:` bodies here contain lines that look like keys, and a
# grep-built step set that silently gained one would make the vocabulary check
# pass on a name build.yml does not define.
if ! "${WORKFLOW_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    _fail "reading build.yml requires Python 3 with PyYAML" \
        "install python3-yaml (Debian/Ubuntu) or python3-pyyaml (Fedora)," \
        "or install PyYAML in the interpreter selected by WORKFLOW_PYTHON"
    finish
    exit 1
fi

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "${TMP_ROOT}"' EXIT

# An extraction that matched nothing is an unchecked document, not a pass.
require_nonempty() {
    local description=$1 content=$2
    if [[ -n "${content//[[:space:]]/}" ]]; then
        _pass "still has ${description}"
        return 0
    fi
    _fail "still has ${description}" \
        "nothing was extracted, so the checks over it verify nothing"
    return 1
}

# --- the machine ------------------------------------------------------------

MACHINE_PY="${TMP_ROOT}/machine.py"
cat >"${MACHINE_PY}" <<'PY'
"""Emit the facts AGENTS.md makes claims about, as key<TAB>value lines.

Reads a workflow and the Containerfile. `run:` bodies are written out one file
per step so the shell can match against them without quoting a YAML block.
"""

import os
import re
import sys

import yaml

workflow_path, containerfile_path, out_dir = sys.argv[1:4]


def emit(key, *values):
    print("\t".join([key, *values]))


with open(workflow_path, encoding="utf-8") as handle:
    doc = yaml.safe_load(handle)

# PyYAML implements YAML 1.1, where a bare `on` is the boolean true.
if isinstance(doc, dict) and True in doc:
    doc["on"] = doc.pop(True)

triggers = doc.get("on") or {}
for key in triggers:
    emit("trigger", str(key))
for entry in triggers.get("schedule") or []:
    emit("schedule-cron", entry["cron"])

for job_id, job in (doc.get("jobs") or {}).items():
    emit("job-name", job.get("name", job_id))
    for step in job.get("steps") or []:
        name = step.get("name")
        if name is None:
            continue
        emit("step-name", name)
        if "run" in step:
            slug = re.sub(r"[^A-Za-z0-9]+", "-", name).strip("-")
            with open(os.path.join(out_dir, f"run-{slug}"), "w", encoding="utf-8") as body:
                body.write(step["run"])

containerfile = open(containerfile_path, encoding="utf-8").read()

for name, value in re.findall(r"^ARG\s+([A-Za-z_][A-Za-z0-9_]*)=(\S+)", containerfile, re.M):
    emit("arg", name, value)

for ref, stage in re.findall(r"^FROM\s+(\S+)\s+AS\s+(\S+)", containerfile, re.M):
    emit("stage", stage)
    emit("from", stage, ref)

# A `RUN` spans as many physical lines as it has continuations; the mounts and
# the command belong to the same instruction only once they are joined.
for instruction in re.sub(r"\\\n\s*", " ", containerfile).splitlines():
    if not instruction.startswith("RUN "):
        continue
    for source_stage, src, dst in re.findall(
        r"--mount=type=bind,from=([^,\s]+),src=([^,\s]+),dst=([^,\s]+)", instruction
    ):
        emit("mount", source_stage, src, dst)
    scripts = re.findall(r"/ctx/([A-Za-z0-9._-]+\.sh)", instruction)
    if scripts:
        emit("run-scripts", " ".join(scripts))
PY

MACHINE_FACTS="${TMP_ROOT}/machine.txt"
if ! "${WORKFLOW_PYTHON}" -B "${MACHINE_PY}" "${BUILD_WF}" "${CONTAINERFILE}" \
    "${TMP_ROOT}" >"${MACHINE_FACTS}" 2>"${TMP_ROOT}/machine.err"; then
    _fail "build.yml and the Containerfile parse" "$(cat "${TMP_ROOT}/machine.err")"
    finish
    exit 1
fi

# All values of one fact key, tab-separated, one record per line.
machine() {
    awk -F'\t' -v key="$1" '$1 == key { sub(/^[^\t]*\t/, ""); print }' "${MACHINE_FACTS}"
}

# The n-th value after the one that selects the record: `machine_field arg
# AURORA_TAG 1` reads the default out of `arg<TAB>AURORA_TAG<TAB>stable`.
machine_field() {
    awk -F'\t' -v key="$1" -v first="$2" -v field="$3" \
        '$1 == key && $2 == first { print $(field + 2); exit }' "${MACHINE_FACTS}"
}

STEP_NAMES="$(machine step-name | LC_ALL=C sort -u)"
JOB_NAMES="$(machine job-name | LC_ALL=C sort -u)"
require_nonempty "a step-name set read out of build.yml" "${STEP_NAMES}" || true
require_nonempty "a job-name set read out of build.yml" "${JOB_NAMES}" || true

# --- the document -----------------------------------------------------------

DOC_PY="${TMP_ROOT}/doc.py"
cat >"${DOC_PY}" <<'PY'
"""Emit the claims AGENTS.md makes, as key<TAB>value lines.

Everything is read outside fenced code blocks unless the extractor says
otherwise: a name inside a fence is a sample of output, not a claim about this
repository.
"""

import re
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()


def emit(key, *values):
    print("\t".join([key, *values]))


# Prose by section, with the heading each claim sits under. Two sections name
# the failing step and they have to name the same one, which is only checkable
# if a claim carries where it was made.
sections, current, fenced = [], ("(preamble)", []), False
for line in lines:
    if line.lstrip().startswith("```"):
        fenced = not fenced
        continue
    if fenced:
        continue
    heading = re.match(r"^#{2,6}\s+(.*\S)\s*$", line)
    if heading:
        sections.append(current)
        current = (heading.group(1), [])
        continue
    current[1].append(line)
sections.append(current)

# Markdown wraps. `` `Test Image` step`` is two lines in the source and matches
# nothing until the prose is one string.
for heading, body in sections:
    flat = re.sub(r"\s+", " ", " ".join(body))
    # The three ways this document names the place a failure appears.
    for pattern in (r"`([^`]+)` step\b", r"\bduring `([^`]+)`", r"\bSymptom, in `([^`]+)`"):
        for match in re.finditer(pattern, flat):
            emit("step-claim", match.group(1), heading)

section = None
for line in lines:
    if line.startswith("## "):
        section = line[3:].strip()
        continue

    if section == "The three upstream inputs" and line.startswith("|") and "---" not in line:
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) == 3 and cells[0].startswith("`"):
            emit("input-row", cells[0].strip("`"), cells[1], cells[2])

    if section == "Build pipeline":
        item = re.match(r"^(\d+)\. ", line)
        if item:
            current_item = item.group(1)
        if re.match(r"^(\d+\. |   )", line):
            for script in dict.fromkeys(re.findall(r"build_files/([A-Za-z0-9._-]+\.sh)", line)):
                emit("pipeline-script", current_item, script)
PY

DOC_FACTS="${TMP_ROOT}/doc.txt"
if ! "${WORKFLOW_PYTHON}" -B "${DOC_PY}" "${AGENTS_DOC}" >"${DOC_FACTS}" 2>"${TMP_ROOT}/doc.err"; then
    _fail "AGENTS.md is readable by the extractors" "$(cat "${TMP_ROOT}/doc.err")"
    finish
    exit 1
fi

claims() {
    awk -F'\t' -v key="$1" '$1 == key { sub(/^[^\t]*\t/, ""); print }' "${DOC_FACTS}"
}

# --- the extractors, against known answers ----------------------------------

FIXTURE="${TMP_ROOT}/fixture.md"
cat >"${FIXTURE}" <<'EOF'
# Fixture

## Symptom

The `Wrapped
Name` step and `Inline Name` step, a failure during `During Name`, and the
Symptom, in `Symptom Name`:

```
The `Fenced Name` step is a sample, not a claim.
```

## The three upstream inputs

| Input        | Referenced at | Provides |
| ------------ | ------------- | -------- |
| `first/ref`  | cited at      | gives    |
| not-a-span   | ignored       | ignored  |

## Elsewhere

| `other/ref`  | under another heading | ignored |

## Build pipeline

1. [`build_files/one.sh`](build_files/one.sh) does a thing.
2. [`build_files/two.sh`](build_files/two.sh) and
   [`build_files/three.sh`](build_files/three.sh) finish it.

Trailing prose naming build_files/four.sh outside any item.
EOF

FIXTURE_FACTS="$("${WORKFLOW_PYTHON}" -B "${DOC_PY}" "${FIXTURE}")"

assert_eq "the step-claim reader flattens wrapped prose, ignores fences and keeps the section" \
    "$(printf 'Wrapped Name\tSymptom\nInline Name\tSymptom\nDuring Name\tSymptom\nSymptom Name\tSymptom')" \
    "$(awk -F'\t' '$1 == "step-claim" { print $2 "\t" $3 }' <<<"${FIXTURE_FACTS}")"

assert_eq "the input-table reader takes the rows under its own heading only" \
    "first/ref" \
    "$(awk -F'\t' '$1 == "input-row" { print $2 }' <<<"${FIXTURE_FACTS}")"

assert_eq "the pipeline reader keeps item order and reads continuation lines" \
    "$(printf '1\tone.sh\n2\ttwo.sh\n2\tthree.sh')" \
    "$(awk -F'\t' '$1 == "pipeline-script" { print $2 "\t" $3 }' <<<"${FIXTURE_FACTS}")"

# --- 1. the step names it sends an agent to look at --------------------------
#
# `gh run view --log-failed` groups a log by step, so a step name in this
# document is an instruction to search for a literal string. A name that is not
# a step of build.yml finds nothing, and the reader concludes the failure is
# somewhere else.
#
# Three names here belong to ublue-os/akmods' workflow, not to this one, and
# the sections that use them say so. They are exempt by name rather than by
# guessing which section a claim came from — and the exemption is checked in
# both directions below, so it cannot quietly absorb a local step that was
# renamed away.
UPSTREAM_STEPS=$(printf '%s\n' "Test Image" "Build COREOS-STABLE akmods" "Build zfs coreos-stable")

STEP_CLAIMS="$(claims step-claim | awk -F'\t' '{ print $1 }' | LC_ALL=C sort -u)"
if require_nonempty "step names AGENTS.md tells an agent to look for" "${STEP_CLAIMS}"; then
    while IFS= read -r claim; do
        [[ -n "${claim}" ]] || continue
        if grep -Fxq "${claim}" <<<"${UPSTREAM_STEPS}"; then
            continue
        fi
        if grep -Fxq "${claim}" <<<"${STEP_NAMES}"; then
            _pass "the '${claim}' step it names is a step of build.yml"
        else
            _fail "the '${claim}' step it names is a step of build.yml" \
                "build.yml defines no step with that name" \
                "steps: $(tr '\n' '|' <<<"${STEP_NAMES}")"
        fi
    done <<<"${STEP_CLAIMS}"
fi

# The failure this file was written for: `Build and push image` is the job, and
# a job name written as a step sends the reader looking for a heading the log
# never prints.
while IFS= read -r job; do
    [[ -n "${job}" ]] || continue
    if grep -Fxq "${job}" <<<"${STEP_CLAIMS}"; then
        _fail "build.yml's '${job}' job is not described as a step" \
            "it is a job name; naming it as a step sends an agent looking for a step that does not exist"
    else
        _pass "build.yml's '${job}' job is not described as a step"
    fi
done <<<"${JOB_NAMES}"

# The exemption list has to stay an exemption list: a name this repo adopts as
# a step of its own must stop being exempt, and a name the document no longer
# uses must stop being listed.
while IFS= read -r upstream; do
    [[ -n "${upstream}" ]] || continue
    if grep -Fxq "${upstream}" <<<"${STEP_NAMES}"; then
        _fail "'${upstream}' is an upstream step name, not one of build.yml's" \
            "build.yml now defines a step with that name, so exempting it hides a real claim"
    else
        _pass "'${upstream}' is an upstream step name, not one of build.yml's"
    fi
    if grep -Fq "${upstream}" "${AGENTS_DOC}"; then
        _pass "AGENTS.md still names the upstream '${upstream}' the exemption covers"
    else
        _fail "AGENTS.md still names the upstream '${upstream}' the exemption covers" \
            "the exemption is dead and should be removed with the prose that needed it"
    fi
done <<<"${UPSTREAM_STEPS}"

# The two sections that name the failing step have to name the same one. They
# did not: Symptom said `Build and push image` and Other failure modes said
# `Build Image`, and only the second was a step. Either section read alone
# looks authoritative, so the disagreement is invisible to a reader who opens
# the one they were sent to.
step_in_section() {
    claims step-claim | awk -F'\t' -v section="$1" '$2 == section { print $1; exit }'
}
symptom_step="$(step_in_section "Symptom")"
other_modes_step="$(step_in_section "Other failure modes")"
require_nonempty "a failing step named in the Symptom section" "${symptom_step}" || true
require_nonempty "a failing step named in Other failure modes" "${other_modes_step}" || true
assert_eq "both sections that name the step skew dies in name the same step" \
    "${symptom_step}" "${other_modes_step}"

# --- 2. the three upstream inputs, against the Containerfile -----------------

INPUT_ROWS="$(claims input-row)"
if require_nonempty "a three-upstream-inputs table" "${INPUT_ROWS}"; then
    assert_eq "the table of three upstream inputs has three rows" \
        "3" "$(wc -l <<<"${INPUT_ROWS}")"
fi

# `FROM` references as the document would write them: shell quoting removed and
# the Fedora version left as the `<N>` placeholder the table uses. The base
# image is `${AURORA_IMAGE}:${AURORA_TAG}`, so its `ARG` defaults are resolved
# the way buildah resolves them.
aurora_image="$(machine_field arg AURORA_IMAGE 1)"
aurora_tag="$(machine_field arg AURORA_TAG 1)"
fedora_version="$(machine_field arg FEDORA_VERSION 1)"
require_nonempty "an AURORA_IMAGE default in the Containerfile" "${aurora_image}" || true
require_nonempty "an AURORA_TAG default in the Containerfile" "${aurora_tag}" || true
require_nonempty "a FEDORA_VERSION default in the Containerfile" "${fedora_version}" || true

resolved_ref() {
    local ref=$1
    ref="${ref//\"/}"
    ref="${ref//\$\{AURORA_IMAGE\}/${aurora_image}}"
    ref="${ref//\$\{AURORA_TAG\}/${aurora_tag}}"
    printf '%s' "${ref}"
}

MACHINE_REFS="$(
    machine from | while IFS=$'\t' read -r _ ref; do
        ref="$(resolved_ref "${ref}")"
        [[ "${ref}" == ghcr.io/* ]] || continue
        printf '%s\n' "${ref//\$\{FEDORA_VERSION\}/<N>}"
    done | LC_ALL=C sort -u
)"
DOC_REFS="$(awk -F'\t' '{ print $1 }' <<<"${INPUT_ROWS}" | LC_ALL=C sort -u)"
assert_eq "the table names exactly the ghcr.io images the Containerfile pulls" \
    "${MACHINE_REFS}" "${DOC_REFS}"

# The "Referenced at" column points at something real: two `ARG` names for the
# base image, and the stage names for the two akmods images. A stage renamed in
# the Containerfile leaves this column describing a `FROM` line that is gone.
containerfile_text="$(cat "${CONTAINERFILE}")"
#
# Every backticked span in the cell is classified and then checked, rather than
# checked if it happens to look like something: a span that falls into no kind
# fails, so a cell rewritten into a form this loop cannot read is reported
# instead of silently passing.
STAGES="$(machine stage)"
while IFS=$'\t' read -r ref cited _; do
    [[ -n "${ref}" ]] || continue
    while IFS= read -r span; do
        span="${span//\`/}"
        case "${span}" in
            Containerfile)
                assert_file_exists "${ref} is cited to the Containerfile, which is there" \
                    "${CONTAINERFILE}"
                ;;
            FROM*AS*)
                stage="${span##*AS }"
                if grep -Fxq "${stage}" <<<"${STAGES}"; then
                    _pass "${ref} is cited through the Containerfile's '${stage}' stage"
                else
                    _fail "${ref} is cited through the Containerfile's '${stage}' stage" \
                        "the Containerfile builds no stage by that name"
                fi
                ;;
            [A-Z]*)
                if grep -qE "^ARG[[:space:]]+${span}=" <<<"${containerfile_text}"; then
                    _pass "${ref} is cited through the Containerfile's ARG ${span}"
                else
                    _fail "${ref} is cited through the Containerfile's ARG ${span}" \
                        "the Containerfile declares no ARG by that name"
                fi
                ;;
            *)
                _fail "${ref}'s Referenced at cell names only things this check knows how to resolve" \
                    "unclassified span: ${span}"
                ;;
        esac
    done < <(grep -oE '`[^`]+`' <<<"${cited}")
done <<<"${INPUT_ROWS}"

# The "Provides" column is the load-bearing half: it says which image supplies
# which path, and the whole skew story rests on those two being different
# images. Each backticked absolute path in the column has to be the `src` of a
# bind mount from the stage that row names.
while IFS=$'\t' read -r ref cited provides; do
    [[ -n "${ref}" ]] || continue
    stage="$(grep -oE 'AS [a-z0-9-]+' <<<"${cited}" | awk '{ print $2 }')"
    [[ -n "${stage}" ]] || continue
    for path in $(grep -oE '`/[A-Za-z0-9/_-]+`' <<<"${provides}" | tr -d '`'); do
        if machine mount | grep -qE "^${stage}"$'\t'"${path}"$'\t'; then
            _pass "${path} is mounted from the '${stage}' stage, as the table says"
        else
            _fail "${path} is mounted from the '${stage}' stage, as the table says" \
                "no bind mount in the Containerfile has from=${stage},src=${path}"
        fi
    done
done <<<"${INPUT_ROWS}"

# --- 3. the build pipeline ---------------------------------------------------
#
# The numbered list is an ordering claim. `zfs.sh` reads back a kernel that
# `kernel-akmods.sh` installed, so an order that has drifted is not a cosmetic
# error — it describes a build that could not work.
PIPELINE_SCRIPTS="$(claims pipeline-script | awk -F'\t' '{ print $2 }')"
CTX_SCRIPTS="$(machine run-scripts | tr ' ' '\n')"
if require_nonempty "a numbered build pipeline" "${PIPELINE_SCRIPTS}"; then
    assert_eq "the pipeline lists the Containerfile's /ctx scripts, in its order" \
        "${CTX_SCRIPTS}" "${PIPELINE_SCRIPTS}"
fi
while IFS= read -r script; do
    [[ -n "${script}" ]] || continue
    assert_file_exists "the pipeline names a script this repo ships: ${script}" \
        "${REPO_ROOT}/build_files/${script}"
done <<<"${PIPELINE_SCRIPTS}"

kernel_akmods_text="$(cat "${KERNEL_AKMODS_SH}")"
zfs_text="$(cat "${ZFS_SH}")"

# Step 1's claims, against the script it names.
assert_contains "kernel-akmods.sh erases Aurora's kernel RPMs, as step 1 says" \
    "${kernel_akmods_text}" 'rpm --erase "${pkg}" --nodeps'
# "entirely" is the whole of the claim, so the path is matched as a whole line:
# `rm -rf /usr/lib/modules.d` contains the string and deletes something else.
if grep -qE '^rm -rf /usr/lib/modules$' "${KERNEL_AKMODS_SH}"; then
    _pass "and deletes /usr/lib/modules entirely"
else
    _fail "and deletes /usr/lib/modules entirely" \
        "kernel-akmods.sh removes no such directory outright"
fi
assert_contains "and installs the kernel from the akmods image's mount" \
    "${kernel_akmods_text}" "/tmp/kernel-rpms/kernel-"
assert_contains "and versionlocks it" \
    "${kernel_akmods_text}" "versionlock add kernel"

# Step 2's claims, against the script it names.
assert_contains "zfs.sh derives KERNEL from /usr/lib/modules, as step 2 says" \
    "${zfs_text}" 'KERNEL=$(basename "$(find /usr/lib/modules'
assert_contains "and installs kmod-zfs for that kernel from the akmods-zfs mount" \
    "${zfs_text}" '/tmp/rpms/kmods/zfs/kmod-zfs-"${KERNEL}"*.rpm'
assert_contains "and runs depmod" "${zfs_text}" 'depmod -a -v "${KERNEL}"'
assert_contains "and rebuilds the initramfs" "${zfs_text}" "dracut"

# "KERNEL comes from the akmods image, but kmod-zfs must come from the
# akmods-zfs image" — the sentence the whole document hangs on, recomputed from
# the two mounts rather than restated.
kernel_rpms_stage="$(machine mount | awk -F'\t' '$3 == "/tmp/kernel-rpms" { print $1 }')"
zfs_rpms_stage="$(machine mount | awk -F'\t' '$3 == "/tmp/rpms/kmods/zfs" { print $1 }')"
assert_eq "the kernel RPMs the build installs come from the akmods stage" \
    "akmods" "${kernel_rpms_stage}"
assert_eq "the ZFS kmods come from the akmods-zfs stage, which is the skew" \
    "akmods-zfs" "${zfs_rpms_stage}"

# --- 4. the Symptom block ----------------------------------------------------

doc_text="$(cat "${AGENTS_DOC}")"

# The failing glob a reader is told to recognise has to be the glob zfs.sh
# runs. The directory is read out of the document rather than written into the
# pattern -- a pattern that names the right directory matches only the
# occurrences that are already right, and reports nothing about the one that
# drifted.
symptom_dirs="$(grep -oE '/[A-Za-z0-9/_.-]*/kmod-zfs-[^ "]*\*\.rpm' "${AGENTS_DOC}" |
    xargs -r -n1 dirname | LC_ALL=C sort -u)"
zfs_kmod_dir="$(grep -oE '/[A-Za-z0-9/_.-]*/kmod-zfs-' "${ZFS_SH}" | head -1 | xargs -r dirname)"
require_nonempty "kmod-zfs paths in the Symptom block" "${symptom_dirs}" || true
require_nonempty "a kmod-zfs path in zfs.sh" "${zfs_kmod_dir}" || true
assert_eq "every kmod-zfs path the Symptom shows lives where zfs.sh looks for it" \
    "${zfs_kmod_dir}" "${symptom_dirs}"

# The `Error: building at STEP` line quotes the RUN instruction. Both scripts,
# in that order, have to be one instruction of the Containerfile.
error_scripts="$(grep -oE '/ctx/[a-z-]+\.sh' <<<"${doc_text}" | sed 's#/ctx/##' | awk '!seen[$0]++ && NR <= 2' | tr '\n' ' ')"
assert_contains "the quoted build error names a real RUN of the Containerfile" \
    "$(machine run-scripts)" "${error_scripts% }"

# "Only `kmod-zfs` is kernel-versioned" is the signature the section teaches.
# Read it out of ZFS_RPMS rather than from the prose: the userspace entries
# carry no ${KERNEL}, the kmod entry does, and each family the prose names is
# really in the array.
zfs_rpms="$(sed -n '/^ZFS_RPMS=(/,/^)/p' "${ZFS_SH}")"
require_nonempty "a ZFS_RPMS array in zfs.sh" "${zfs_rpms}" || true
for family in libnvpair libzfs zfs-; do
    if grep -q "zfs/${family}" <<<"${zfs_rpms}"; then
        _pass "the userspace family ${family}* the Symptom names is in ZFS_RPMS"
    else
        _fail "the userspace family ${family}* the Symptom names is in ZFS_RPMS" \
            "zfs.sh installs no RPM matching that prefix"
    fi
    if grep "zfs/${family}" <<<"${zfs_rpms}" | grep -q 'KERNEL'; then
        _fail "and is not kernel-versioned, which is why it resolves" \
            "${family}* carries \${KERNEL}, so the Symptom's signature is wrong"
    else
        _pass "and is not kernel-versioned, which is why it resolves"
    fi
done
assert_contains "while kmod-zfs is kernel-versioned, which is why it fails alone" \
    "${zfs_rpms}" 'kmod-zfs-"${KERNEL}"'

# --- 5. the 60-second diagnosis ----------------------------------------------

diagnosis="$(sed -n '/^### 60-second diagnosis$/,/^### /p' "${AGENTS_DOC}")"
require_nonempty "a 60-second diagnosis section" "${diagnosis}" || true

# The version the diagnosis pins, against the Containerfile's own default. A
# Fedora bump that leaves this behind sends every reader to inspect last
# release's images.
diagnosis_version="$(grep -oE '^FEDORA_VERSION=[0-9]+' <<<"${diagnosis}" | cut -d= -f2)"
assert_eq "the diagnosis inspects the Fedora version the Containerfile builds" \
    "${fedora_version}" "${diagnosis_version}"

# The two images it loops over are the two akmods repositories, and only those:
# the third is printed as context and the prose says so.
diagnosis_images="$(grep -oE '^for img in .*' <<<"${diagnosis}" | sed 's/^for img in //; s/; do$//' | tr ' ' '\n' | LC_ALL=C sort -u)"
AKMODS_REPOS="$(
    machine from | while IFS=$'\t' read -r stage ref; do
        [[ "${stage}" == akmods* ]] || continue
        ref="${ref%%:*}"
        printf '%s\n' "${ref##*/}"
    done | LC_ALL=C sort -u
)"
assert_eq "the skew test inspects exactly the Containerfile's two akmods images" \
    "${AKMODS_REPOS}" "${diagnosis_images}"

# The reference it builds for each, against the Containerfile's tag shape. The
# loop substitutes the repository, so the Containerfile's `akmods` reference
# with `${img}` in that position is the string the diagnosis has to contain --
# a tag template that drifts from the Containerfile inspects images this build
# never pulls.
akmods_ref="$(resolved_ref "$(machine_field from akmods 1)")"
assert_contains "and builds each reference the way the Containerfile tags them" \
    "${diagnosis}" "${akmods_ref/\/akmods:/\/\$\{img\}:}"

# The context line is the base image, at the tag the Containerfile resolves to.
base_ref="$(resolved_ref "$(machine_field from base 1)")"
assert_contains "the context line inspects the base image the Containerfile uses" \
    "${diagnosis}" "docker://${base_ref}"

# `ostree.linux` is "the authoritative kernel version" only because the badge
# script reads that label. Take the name out of the `jq` filter rather than out
# of the file: the header comment names it too, so a whole-file match is
# satisfied by prose while the code reads something else.
badge_label="$(grep -oE '\.Labels\["[a-z.]+"\]' "${WRITE_BADGES}" | head -1 |
    sed -E 's/^\.Labels\["//; s/"\]$//')"
require_nonempty "a label ci/write-badges.sh reads out of the akmods images" "${badge_label}" || true
diagnosis_labels="$(grep -oE 'index \.Labels "[a-z.]+"' <<<"${diagnosis}" |
    sed -E 's/^index \.Labels "//; s/"$//' | LC_ALL=C sort -u)"
require_nonempty "labels the diagnosis inspects" "${diagnosis_labels}" || true
assert_eq "every label the diagnosis inspects is the one the badge script reads" \
    "${badge_label}" "${diagnosis_labels}"
assert_contains "and the prose names it as the authoritative kernel version" \
    "${doc_text}" "The \`${badge_label}\` label is the authoritative kernel version"

# Step 4 of the upstream trace filters the tag list by the same Fedora version.
tag_greps="$(grep -oE 'grep coreos-stable-[0-9]+' <<<"${doc_text}" | awk '{ print $2 }' | LC_ALL=C sort -u)"
require_nonempty "a tag filter in the 'what can I pin to' step" "${tag_greps}" || true
assert_eq "the pinnable-tag search filters on the Fedora version being built" \
    "coreos-stable-${fedora_version}" "${tag_greps}"

# --- 6. Fix options ----------------------------------------------------------

doc_cron="$(grep -oE '`[0-9]{2} [0-9]{2} \* \* [0-9]`' <<<"${doc_text}" | tr -d '`' | head -1)"
build_cron="$(machine schedule-cron | head -1)"
require_nonempty "a cron in the cost-of-waiting paragraph" "${doc_cron}" || true
assert_eq "the schedule it quotes is build.yml's schedule" "${build_cron}" "${doc_cron}"

# "weekly" and "one failed run per Sunday" are claims about that cron's fields,
# not decoration. Day-of-month, month and day-of-week decide both.
assert_eq "the quoted cron really is weekly, which is what 'one per Sunday' means" \
    "* * 0" "$(awk '{ print $3, $4, $5 }' <<<"${build_cron}")"
assert_contains "and the paragraph calls it weekly" "${doc_text}" "runs weekly"
assert_contains "and names the day that cron's 0 selects" "${doc_text}" "per Sunday"

# "The workflow has workflow_dispatch, so you can build on demand."
if grep -Fxq "workflow_dispatch" <<<"$(machine trigger)"; then
    _pass "build.yml has the workflow_dispatch trigger the wait paragraph relies on"
else
    _fail "build.yml has the workflow_dispatch trigger the wait paragraph relies on" \
        "triggers: $(tr '\n' '|' <<<"$(machine trigger)")"
fi

# The mixed-pin example is meant to be pasted into the Containerfile. Its two
# `FROM` lines have to name the stages that are there, the repositories that
# are there, and — the safety property the paragraph states — one kernel.
mixed_pin="$(grep -E '^FROM ghcr\.io/ublue-os/akmods' <<<"${doc_text}")"
require_nonempty "a mixed-pin Dockerfile example" "${mixed_pin}" || true
mixed_stages="$(grep -oE 'AS [a-z-]+$' <<<"${mixed_pin}" | awk '{ print $2 }' | LC_ALL=C sort -u)"
assert_eq "the mixed-pin example replaces the Containerfile's two akmods stages" \
    "$(printf 'akmods\nakmods-zfs')" "${mixed_stages}"
mixed_kernels="$(grep -oE '[0-9]+-[0-9.]+-[0-9]+\.fc[0-9]+\.x86_64' <<<"${mixed_pin}" | sed -E 's/^[0-9]+-//' | LC_ALL=C sort -u)"
assert_eq "and pins both images to one kernel, which is the whole safety property" \
    "1" "$(wc -l <<<"${mixed_kernels}")"
assert_contains "the pinned kernel keeps the stable stream for the kernel itself" \
    "${mixed_pin}" "akmods:coreos-stable-"
assert_contains "and takes only the ZFS kmod from coreos-testing, as the prose says" \
    "${mixed_pin}" "akmods-zfs:coreos-testing-"

# "They must be pinned together — the Containerfile comments say so."
assert_contains "the Containerfile really carries the keep-in-sync pin comment" \
    "${containerfile_text}" "keep this in sync with the above"

# --- 7. the Chunkah section --------------------------------------------------
#
# test-reflections.sh holds the numbers in this section equal across the entry,
# this document and the step's comment. What is checked here is the other half:
# that the remedy it describes is the one the step runs, so an agent told "the
# step now passes --format '{{json .Config}}'" finds that in the workflow.
RECHUNK_BODY="${TMP_ROOT}/run-Rechunk-Image-with-Chunkah"
if [[ -f "${RECHUNK_BODY}" ]]; then
    _pass "the Rechunk Image with Chunkah step has a run: body to compare with"
    rechunk_text="$(cat "${RECHUNK_BODY}")"
    assert_contains "the step passes the .Config format AGENTS.md says it does" \
        "${rechunk_text}" "--format '{{json .Config}}'"
    assert_contains "through CHUNKAH_CONFIG_STR, the variable the section names" \
        "${rechunk_text}" "CHUNKAH_CONFIG_STR"
    assert_contains "handed to podman run with -e, which is what makes it argv" \
        "${rechunk_text}" "-e CHUNKAH_CONFIG_STR"
    assert_contains "and the section names the three fields a full inspect adds" \
        "${doc_text}" "GraphDriver.Data.LowerDir"
else
    _fail "the Rechunk Image with Chunkah step has a run: body to compare with" \
        "no run: body was extracted for that step name"
fi

# --- 8. links, anchors and runnable blocks -----------------------------------

# The one in-page link. A heading rename leaves "see Other failure modes"
# landing at the top of the page, which is exactly where a reader does not need
# to be.
SLUGS="$(heading_slugs "${AGENTS_DOC}")"
ANCHORS="$(grep -oE '\]\(#[a-z0-9_-]+\)' "${AGENTS_DOC}" | sed 's/^](#//; s/)$//' | LC_ALL=C sort -u)"
if require_nonempty "in-page anchors" "${ANCHORS}"; then
    while IFS= read -r anchor; do
        [[ -n "${anchor}" ]] || continue
        if grep -Fxq "${anchor}" <<<"${SLUGS}"; then
            _pass "the in-page link #${anchor} resolves to a heading of its own"
        else
            _fail "the in-page link #${anchor} resolves to a heading of its own" \
                "no heading in AGENTS.md slugs to that anchor"
        fi
    done <<<"${ANCHORS}"
fi

# Every relative link out of this document, and -- where the link text is a
# backticked path -- the text against the target. A reader following the words
# and a reader following the link have to land in the same place; a rename that
# updates one and not the other leaves the page reading correctly and going
# somewhere else.
LINKS="$(grep -oE '\[`[^`]+`\]\([A-Za-z0-9./_-]+\)' "${AGENTS_DOC}" | LC_ALL=C sort -u)"
if require_nonempty "relative links with a path for link text" "${LINKS}"; then
    while IFS= read -r link; do
        [[ -n "${link}" ]] || continue
        link_text="${link#*\[\`}"
        link_text="${link_text%%\`\]*}"
        link_target="${link#*](}"
        link_target="${link_target%)}"
        assert_eq "the link to ${link_target} says where it goes" \
            "${link_target}" "${link_text}"
        assert_file_exists "and ${link_target} is a file this repo has" \
            "${REPO_ROOT}/${link_target}"
    done <<<"${LINKS}"
fi

# Every bash block is something a reader copies. One that does not parse is a
# command that fails in front of them mid-incident.
bash_blocks="$(awk '/^```bash$/ { collecting = 1; next } collecting && /^```$/ { collecting = 0; next } collecting' "${AGENTS_DOC}")"
if require_nonempty "runnable bash blocks" "${bash_blocks}"; then
    if bash -n <<<"${bash_blocks}" 2>/dev/null; then
        _pass "every bash block in AGENTS.md parses"
    else
        _fail "every bash block in AGENTS.md parses" "bash -n rejected the concatenated blocks"
    fi
fi

# The jq filters those blocks hand to gh have to compile.
joined_blocks="$(sed -e ':a' -e '/\\$/N; s/\\\n[[:space:]]*/ /; ta' <<<"${bash_blocks}")"
filters="$(grep -oE -- "(-q|--jq) '[^']+'" <<<"${joined_blocks}" | sed -E "s/^(-q|--jq) '//; s/'\$//")"
if require_nonempty "jq filters in its gh commands" "${filters}"; then
    while IFS= read -r filter; do
        [[ -n "${filter}" ]] || continue
        jq "${filter}" <<<'[]' >/dev/null 2>&1
        status=$?
        # 3 is jq's compile error; 5 is "this filter errored on this input",
        # which says nothing about the filter a reader runs against real data.
        if [[ "${status}" -ne 3 ]]; then
            _pass "jq compiles the filter ${filter:0:48}"
        else
            _fail "jq compiles the filter ${filter:0:48}" "jq reported a compile error"
        fi
    done <<<"${filters}"
fi

finish
