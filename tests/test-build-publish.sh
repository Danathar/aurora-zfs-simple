#!/usr/bin/env bash
#
# Covers the publish band of .github/workflows/build.yml's `build_push` job —
# the four `run:` bodies that decide what the registry ends up holding and what
# gets signed:
#
#   Prepare environment              lower-cases the registry/image reference
#   Propagate tags from the pushed digest   copies one manifest onto every tag
#   Verify pushed tags share one digest     refuses to sign a split tag set
#   Sign container image             signs the digest
#
# Nothing in this repository executed any of them. They are shell inside YAML
# strings, so run-tests.sh does not find them, test-shell-syntax.sh does not
# `bash -n` them and shellcheck never sees them. test-ci-workflows.sh reads
# build.yml, but only structurally: it asserts the `tests` job has installed
# the linter by the time it runs the suite, that a `build_push:` job exists, and
# that the paths-ignore/trigger relation with coverage-gate.yml holds. It says
# nothing about what these steps do. tests/e2e/run-e2e.sh names the same
# invariant in prose and re-implements a rechunk of its own; it does not run
# this workflow's shell.
#
# That band is where the workflow's published output is decided, and its
# failure modes are the quiet kind:
#
#   1. The propagate step exists because sequential `podman push`es of one
#      local image can produce different manifest digests, which split what
#      `latest` and the date tags pointed at and left `latest` outside the
#      signed digest. The fix is one server-side `skopeo copy
#      --preserve-digests` per tag from the pushed digest. Drop
#      --preserve-digests, or copy from `:latest` instead of `@digest`, and the
#      split silently returns — every tag still exists, so nothing looks wrong.
#
#   2. The verify step is the guard that makes (1) checkable, and it has to fail
#      *before* signing. If a mismatch or an unreadable tag were treated as a
#      warning, the job would sign one digest and publish tags pointing
#      elsewhere, which is the exact state the two steps exist to prevent.
#
#   3. Both steps refuse to run on an empty digest. `steps.push.outputs.digest`
#      is empty whenever the push action changes its output contract; without
#      that guard the propagate loop would copy from `...@` and the verify loop
#      would compare every tag against the empty string.
#
#   4. `github.repository_owner` is `Danathar` — an uppercase letter, which is
#      not valid in a registry reference. Every skopeo and cosign call in the
#      job depends on the one `${VAR,,}` line in Prepare environment, so that
#      line's output is fed into the later cases here rather than hand-written.
#
#   5. The sign step signs `@${DIGEST}`. Signing a tag instead would leave the
#      digest consumers pull unsigned while cosign still reports success.
#
# Each body is extracted from the YAML and executed as a real subprocess against
# a file-backed fake registry: a directory of tag files holding digests, driven
# by recording `skopeo` and `cosign` stubs. What is asserted is what the next
# step and the registry's users consume — the exit code, the argv, and the
# resulting tag/digest map.
#
# The YAML is read with PyYAML rather than by hand, for the same reason
# test-nightly-compliance.sh and test-ai-fix.sh do: these `run:` bodies are
# block scalars, and re-deriving their indentation with sed is a second
# implementation that can disagree with the one Actions uses. The `on:` key is
# the known trap — YAML 1.1 reads a bare `on` as the boolean true — so the
# normalizer renames it back and is checked against a fixture with a known
# answer before it is trusted on the real file.

set -uo pipefail

TEST_NAME="test-build-publish"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

BUILD_WF="${REPO_ROOT}/.github/workflows/build.yml"
WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

if [[ ! -f "${BUILD_WF}" ]]; then
    _fail "build.yml exists" \
        "no such file: ${BUILD_WF}" \
        "if the workflow was removed on purpose, delete this test with it"
    finish
    exit 1
fi

# This decides what the published image's tags point at; a missing parser must
# fail rather than skip, including when the file is invoked directly instead of
# through run-tests.sh.
if ! "${WORKFLOW_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    _fail "the build.yml publish check requires Python 3 with PyYAML" \
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
  push:
    branches:
      - main
env:
  DEFAULT_TAG: "latest"
jobs:
  demo:
    steps:
      - name: Named step
        if: github.event_name != 'pull_request'
        env:
          DIGEST: ${{ steps.push.outputs.digest }}
        run: |
          echo marker
YAML

fixture_json="${TMP_ROOT}/fixture.json"
if "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${fixture}" >"${fixture_json}" 2>"${TMP_ROOT}/fixture.err"; then
    assert_eq "the normalizer reads a fixture's push branches by name" \
        "main" "$(jq -r '.on.push.branches[0]' <"${fixture_json}")"
    assert_eq "the normalizer reads a fixture's workflow-level env" \
        "latest" "$(jq -r '.env.DEFAULT_TAG' <"${fixture_json}")"
    assert_eq "the normalizer reads a fixture's block-scalar run: body" \
        "echo marker" "$(jq -r '.jobs.demo.steps[0].run' <"${fixture_json}")"
    # shellcheck disable=SC2016 # an Actions expression, compared as literal text
    assert_eq "the normalizer reads a fixture step's env: block" \
        '${{ steps.push.outputs.digest }}' \
        "$(jq -r '.jobs.demo.steps[] | select(.name == "Named step") | .env.DIGEST' <"${fixture_json}")"
else
    _fail "the normalizer parses a fixture workflow" "$(cat "${TMP_ROOT}/fixture.err")"
fi

# --- the real file ----------------------------------------------------------

WF_JSON="${TMP_ROOT}/build.json"
if ! "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${BUILD_WF}" >"${WF_JSON}" 2>"${TMP_ROOT}/wf.err"; then
    _fail "build.yml parses as YAML" "$(cat "${TMP_ROOT}/wf.err")"
    finish
    exit 1
fi
_pass "build.yml parses as YAML"

# wf <jq expression> — one value out of the parsed workflow.
wf() {
    jq -r "$1" <"${WF_JSON}"
}

# step_field <step name> <field> — one field of one build_push step, or "".
step_field() {
    wf ".jobs.build_push.steps[] | select(.name == \"$1\") | .$2 // \"\""
}

# extract <destination> <step name> <marker> — pull a run: body out and refuse
# to continue with an empty or unrecognisable one. Without this, a renamed step
# would leave every case below running an empty file: exit 0, no output, no
# registry writes, and assertions that pass while measuring nothing.
extract() {
    local dest=$1 name=$2 marker=$3
    step_field "${name}" "run" >"${dest}"
    if [[ ! -s "${dest}" ]] || ! grep -q -- "${marker}" "${dest}"; then
        _fail "the '${name}' script was extracted from build.yml" \
            "expected a run: body containing ${marker}; extracted" \
            "$(wc -c <"${dest}") byte(s) from the build_push job" \
            "the step name probably changed — update this test to match"
        finish
        exit 1
    fi
    _pass "the '${name}' script was extracted from build.yml"
}

DIGEST_A="sha256:1111111111111111111111111111111111111111111111111111111111111111"
DIGEST_B="sha256:2222222222222222222222222222222222222222222222222222222222222222"

# =============================================================================
# A. "Prepare environment" — the case fold every later reference depends on
# =============================================================================
#
# IMAGE_REGISTRY is built from github.repository_owner, which for this account
# is `Danathar`, and IMAGE_NAME from the repository name. Uppercase is not
# legal in a registry reference, so this step's two lines are what make the
# skopeo and cosign calls in the rest of the job addressable at all.

PREPARE="${TMP_ROOT}/prepare.sh"
extract "${PREPARE}" "Prepare environment" 'GITHUB_ENV'

prepare_dir="$(mktemp -d "${TMP_ROOT}/prepare.XXXXXX")"
: >"${prepare_dir}/env"
IMAGE_REGISTRY="ghcr.io/Danathar" \
    IMAGE_NAME="Aurora-ZFS-Simple" \
    GITHUB_ENV="${prepare_dir}/env" \
    bash "${PREPARE}" >/dev/null 2>&1
prepare_status=$?

assert_eq "the prepare step succeeds" "0" "${prepare_status}"
assert_contains "the prepare step lower-cases the registry for GHCR" \
    "$(cat "${prepare_dir}/env")" "IMAGE_REGISTRY=ghcr.io/danathar"
assert_contains "the prepare step lower-cases the image name for GHCR" \
    "$(cat "${prepare_dir}/env")" "IMAGE_NAME=aurora-zfs-simple"

# Everything below runs against the values this step actually produced — read
# back out of GITHUB_ENV the way Actions hands them to later steps — so a
# regression that stopped folding the case would fail the publish cases too
# rather than only this one.
github_env() {
    grep -m1 "^$1=" "${prepare_dir}/env" | cut -d= -f2-
}
IMAGE_REGISTRY="$(github_env IMAGE_REGISTRY)"
IMAGE_NAME="$(github_env IMAGE_NAME)"
DEFAULT_TAG="$(wf '.env.DEFAULT_TAG')"

assert_eq "the workflow still defines the DEFAULT_TAG the publish steps skip on" \
    "latest" "${DEFAULT_TAG}"

# =============================================================================
# B. the fake registry
# =============================================================================
#
# A directory of files named for tags, each holding the digest that tag
# resolves to. `skopeo copy` writes one; `skopeo inspect` reads one and fails
# the way a registry does when the tag is absent. That is enough to observe the
# thing under test: which manifest each published tag ends up pointing at.

# make_skopeo <dir> — write a recording skopeo stub into <dir>/bin.
#
# Reads and writes <dir>/registry, appends its argv to <dir>/calls, and honours
# <dir>/copy-fails: a tag listed there makes `copy` fail, which is how a
# registry-side rejection is injected.
make_skopeo() {
    local dir=$1
    mkdir -p "${dir}/bin" "${dir}/registry"
    : >"${dir}/calls"
    : >"${dir}/copy-fails"

    cat >"${dir}/bin/skopeo" <<PY
#!/usr/bin/env bash
dir=${dir@Q}
printf '%s\n' "\$*" >>"\${dir}/calls"

registry_file() {
    # docker://host/name:tag or docker://host/name@sha256:...
    local ref=\${1#docker://}
    printf '%s' "\${dir}/registry/\${ref##*:}"
}

case \$1 in
copy)
    shift
    src="" dst=""
    for arg in "\$@"; do
        case \${arg} in
        docker://*) if [ -z "\${src}" ]; then src=\${arg}; else dst=\${arg}; fi ;;
        esac
    done
    tag=\${dst##*:}
    if grep -qxF "\${tag}" "\${dir}/copy-fails"; then
        echo "Error: writing manifest: denied" >&2
        exit 1
    fi
    case \${src} in
    *@sha256:*) digest="sha256:\${src##*@sha256:}" ;;
    *)
        # A copy from a tag rather than the pushed digest: resolve it, which is
        # exactly the indirection --preserve-digests exists to avoid.
        src_file=\$(registry_file "\${src}")
        if [ ! -f "\${src_file}" ]; then
            echo "Error: reading manifest: manifest unknown" >&2
            exit 1
        fi
        digest=\$(cat "\${src_file}")
        ;;
    esac
    printf '%s' "\${digest}" >"\$(registry_file "\${dst}")"
    ;;
inspect)
    ref=""
    for arg in "\$@"; do
        case \${arg} in docker://*) ref=\${arg} ;; esac
    done
    file=\$(registry_file "\${ref}")
    if [ ! -f "\${file}" ]; then
        echo "Error: reading manifest \${ref##*:}: manifest unknown" >&2
        exit 1
    fi
    cat "\${file}"
    ;;
*)
    echo "unexpected skopeo subcommand: \$1" >&2
    exit 2
    ;;
esac
PY
    chmod +x "${dir}/bin/skopeo"
}

# registry_tag <dir> <tag> — what that tag resolves to, or "" if absent.
registry_tag() {
    local file="$1/registry/$2"
    [[ -f "${file}" ]] && cat "${file}"
}

# registry_tags <dir> — every published tag, space separated and sorted.
registry_tags() {
    (cd "$1/registry" && ls) | sort | tr '\n' ' ' | sed 's/ $//'
}

# =============================================================================
# C. "Propagate tags from the pushed digest"
# =============================================================================

PROPAGATE="${TMP_ROOT}/propagate.sh"
extract "${PROPAGATE}" "Propagate tags from the pushed digest" 'skopeo copy'

# propagate <digest> <tags> — run the step in a fresh registry.
# Sets P_DIR, P_STATUS, P_OUTPUT and P_CALLS.
propagate() {
    local digest=$1 tags=$2

    P_DIR="$(mktemp -d "${TMP_ROOT}/propagate.XXXXXX")"
    make_skopeo "${P_DIR}"
    # The push action published exactly one tag before this step runs.
    [[ -n "${digest}" ]] && printf '%s' "${digest}" >"${P_DIR}/registry/${DEFAULT_TAG}"

    P_OUTPUT="$(
        PATH="${P_DIR}/bin:${PATH}" \
            IMAGE_REGISTRY="${IMAGE_REGISTRY}" \
            IMAGE_NAME="${IMAGE_NAME}" \
            DEFAULT_TAG="${DEFAULT_TAG}" \
            DIGEST="${digest}" \
            TAGS="${tags}" \
            bash "${PROPAGATE}" 2>&1
    )"
    P_STATUS=$?
    P_CALLS="$(cat "${P_DIR}/calls")"
}

# --- the ordinary push: one manifest, four tags -----------------------------

propagate "${DIGEST_A}" "latest latest.20260101 20260101 pr-42"

assert_eq "propagating the pushed digest succeeds" "0" "${P_STATUS}"
assert_eq "every date and pull-request tag is published" \
    "20260101 latest latest.20260101 pr-42" "$(registry_tags "${P_DIR}")"
assert_eq "latest.YYYYMMDD resolves to the pushed digest" \
    "${DIGEST_A}" "$(registry_tag "${P_DIR}" latest.20260101)"
assert_eq "the bare date tag resolves to the pushed digest" \
    "${DIGEST_A}" "$(registry_tag "${P_DIR}" 20260101)"
assert_eq "the pull-request tag resolves to the pushed digest" \
    "${DIGEST_A}" "$(registry_tag "${P_DIR}" pr-42)"

# The copy source is the digest, not `:latest`: copying tag-to-tag would
# re-introduce the indirection that split the tag set in the first place.
assert_contains "each tag is copied from the pushed digest reference" \
    "${P_CALLS}" "docker://${IMAGE_REGISTRY}/${IMAGE_NAME}@${DIGEST_A} docker://${IMAGE_REGISTRY}/${IMAGE_NAME}:20260101"
assert_not_contains "no tag is copied from another tag" \
    "${P_CALLS}" "copy --preserve-digests docker://${IMAGE_REGISTRY}/${IMAGE_NAME}:latest"

# Without --preserve-digests skopeo may re-compress and rewrite the manifest,
# which produces a different digest for a byte-identical image — the failure
# this whole band exists to prevent.
assert_eq "every copy preserves the manifest digest" \
    "3" "$(grep -c -- '--preserve-digests' <<<"${P_CALLS}")"

# `latest` was published by the push step itself. Copying it onto itself is at
# best a wasted registry round trip and at worst a rewrite of the one manifest
# everything else is compared against.
assert_eq "the already-pushed default tag is not copied over itself" \
    "0" "$(grep -c ":${DEFAULT_TAG}\$" <<<"${P_CALLS}")"

# --- a push that exposed no digest ------------------------------------------
#
# steps.push.outputs.digest is empty whenever the push action changes its output
# contract. Copying from `...@` would either fail per tag or, worse, succeed
# against something unintended.

propagate "" "latest latest.20260101"
assert_eq "an empty digest fails the step" "1" "${P_STATUS}"
assert_contains "an empty digest says why" \
    "${P_OUTPUT}" "push step did not expose a digest"
assert_eq "an empty digest reaches the registry not at all" "" "${P_CALLS}"

# --- a copy the registry rejects --------------------------------------------
#
# The step runs under `set -euo pipefail`. A rejected copy has to stop the job:
# the tag it failed to write still resolves to whatever it held before, and the
# verify step downstream is the only thing that would notice.

propagate "${DIGEST_A}" "latest latest.20260101 20260101"
printf '%s\n' "latest.20260101" >"${P_DIR}/copy-fails"
propagate_dir_with_failure="${P_DIR}"
P_OUTPUT="$(
    PATH="${propagate_dir_with_failure}/bin:${PATH}" \
        IMAGE_REGISTRY="${IMAGE_REGISTRY}" \
        IMAGE_NAME="${IMAGE_NAME}" \
        DEFAULT_TAG="${DEFAULT_TAG}" \
        DIGEST="${DIGEST_A}" \
        TAGS="latest latest.20260101 20260101" \
        bash "${PROPAGATE}" 2>&1
)"
P_STATUS=$?
assert_eq "a rejected copy fails the step" "1" "${P_STATUS}"

# =============================================================================
# D. "Verify pushed tags share one digest"
# =============================================================================

VERIFY="${TMP_ROOT}/verify.sh"
extract "${VERIFY}" "Verify pushed tags share one digest" 'skopeo inspect'

# verify <dir> <digest> <tags> — run the step against an existing registry.
# Sets V_STATUS and V_OUTPUT.
verify() {
    local dir=$1 digest=$2 tags=$3

    V_OUTPUT="$(
        PATH="${dir}/bin:${PATH}" \
            IMAGE_REGISTRY="${IMAGE_REGISTRY}" \
            IMAGE_NAME="${IMAGE_NAME}" \
            DEFAULT_TAG="${DEFAULT_TAG}" \
            DIGEST="${digest}" \
            TAGS="${tags}" \
            bash "${VERIFY}" 2>&1
    )"
    V_STATUS=$?
}

# --- the state the propagate step just produced -----------------------------
#
# Run against the registry left behind by the happy-path propagation above, so
# the two steps are checked as the pair they are rather than against a fixture
# written by hand here.

propagate "${DIGEST_A}" "latest latest.20260101 20260101 pr-42"
verify "${P_DIR}" "${DIGEST_A}" "latest latest.20260101 20260101 pr-42"

assert_eq "a consistent tag set passes" "0" "${V_STATUS}"
assert_eq "every tag is reported, including the pushed default tag" \
    "4" "$(grep -c ' OK$' <<<"${V_OUTPUT}")"
assert_contains "the default tag is checked too, not assumed" \
    "${V_OUTPUT}" "Tag latest -> ${DIGEST_A} OK"

# --- a tag pointing somewhere else ------------------------------------------
#
# This is the state the band exists to catch: `latest` published by one push,
# a date tag left over from another. Signing here would sign one digest while
# `latest` served a different image.

printf '%s' "${DIGEST_B}" >"${P_DIR}/registry/20260101"
verify "${P_DIR}" "${DIGEST_A}" "latest latest.20260101 20260101"

assert_eq "a tag resolving elsewhere fails before signing" "1" "${V_STATUS}"
assert_contains "the failure names the offending tag and both digests" \
    "${V_OUTPUT}" "Tag 20260101 resolves to ${DIGEST_B}, expected ${DIGEST_A}"

# --- a tag that is not there at all -----------------------------------------
#
# skopeo exits non-zero and prints nothing, so `actual` would be empty. An
# unreadable tag has to fail rather than compare "" against the digest and
# report a mismatch that misdescribes the problem — or, if the comparison were
# ever loosened, pass.

rm -f "${P_DIR}/registry/20260101"
verify "${P_DIR}" "${DIGEST_A}" "latest 20260101"
assert_eq "an unreadable tag fails the step" "1" "${V_STATUS}"

# --- no digest to verify against --------------------------------------------
#
# Comparing every tag against the empty string would fail on the first tag with
# a message about a digest mismatch. The explicit guard is what makes the log
# say what actually went wrong.

verify "${P_DIR}" "" "latest"
assert_eq "an empty digest fails the verify step" "1" "${V_STATUS}"
assert_contains "an empty digest says why, rather than reporting a mismatch" \
    "${V_OUTPUT}" "push step did not expose a digest"

# =============================================================================
# E. "Sign container image"
# =============================================================================
#
# cosign signs a reference. If that reference were a tag, the signature would
# cover whatever the tag resolved to at signing time and consumers verifying by
# digest — which is what nightly-compliance.yml does — would find nothing.

SIGN="${TMP_ROOT}/sign.sh"
extract "${SIGN}" "Sign container image" 'cosign sign'

sign_dir="$(mktemp -d "${TMP_ROOT}/sign.XXXXXX")"
mkdir -p "${sign_dir}/bin"
{
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016 # these expansions belong to the generated stub
    printf 'printf "%%s\\n" "$*" >> %q\n' "${sign_dir}/calls"
    # shellcheck disable=SC2016 # likewise
    printf 'printf "key=%%s\\n" "${COSIGN_PRIVATE_KEY:-}" >> %q\n' "${sign_dir}/calls"
} >"${sign_dir}/bin/cosign"
chmod +x "${sign_dir}/bin/cosign"
: >"${sign_dir}/calls"

sign_output="$(
    PATH="${sign_dir}/bin:${PATH}" \
        IMAGE_REGISTRY="${IMAGE_REGISTRY}" \
        IMAGE_NAME="${IMAGE_NAME}" \
        DIGEST="${DIGEST_A}" \
        COSIGN_PRIVATE_KEY="a-private-key" \
        bash "${SIGN}" 2>&1
)"
sign_status=$?
sign_calls="$(cat "${sign_dir}/calls")"

assert_eq "the sign step succeeds" "0" "${sign_status}"
assert_eq "the sign step's only command is cosign" "" "${sign_output}"
assert_contains "the signature covers the digest, not a tag" \
    "${sign_calls}" "${IMAGE_REGISTRY}/${IMAGE_NAME}@${DIGEST_A}"
assert_not_contains "no tag reference is signed" \
    "${sign_calls}" "${IMAGE_NAME}:"
# --key env:// keeps the private key out of the runner's filesystem and out of
# any argv a later step could read.
assert_contains "the key is read from the environment, not a file" \
    "${sign_calls}" "--key env://COSIGN_PRIVATE_KEY"
assert_contains "the private key reaches cosign through that variable" \
    "${sign_calls}" "key=a-private-key"
# Without -y cosign prompts for confirmation and the unattended job hangs until
# the 90-minute job timeout.
assert_contains "the signing is non-interactive" "${sign_calls}" "-y"

# =============================================================================
# F. the wiring between the steps
# =============================================================================
#
# Each body above was executed with environment values supplied here. What
# actually supplies them in CI is the step's `env:` block, and those are the
# only lines tying the three steps to one push. They are asserted as text
# because there is nothing to execute: an expression pointing at another step's
# output would still parse, still run, and still produce an empty digest.

for step in "Propagate tags from the pushed digest" "Verify pushed tags share one digest" "Sign container image"; do
    # shellcheck disable=SC2016 # an Actions expression, compared as literal text
    assert_eq "'${step}' takes its digest from the push step's output" \
        '${{ steps.push.outputs.digest }}' "$(step_field "${step}" 'env.DIGEST')"
done

for step in "Propagate tags from the pushed digest" "Verify pushed tags share one digest"; do
    # shellcheck disable=SC2016 # likewise
    assert_eq "'${step}' iterates the tag list the metadata action generated" \
        '${{ steps.metadata.outputs.tags }}' "$(step_field "${step}" 'env.TAGS')"
done

# The push step generates exactly one tag. If it ever pushed the whole list
# again, the propagate step's single-manifest guarantee would be gone and the
# verify step would be checking tags that came from separate pushes.
# shellcheck disable=SC2016 # likewise
assert_eq "the push step publishes exactly the default tag" \
    '${{ env.DEFAULT_TAG }}' "$(step_field "Push To GHCR" 'with.tags')"

# The publish band is gated so a pull request never writes to the registry
# under the account's name. The guard has to be the same on all of them: a step
# that ran while the push did not would work from an empty digest, which is the
# case C and D above fail on.
PUSH_GUARD="$(step_field "Push To GHCR" "if")"
assert_contains "the push is gated on a non-pull-request build of the default branch" \
    "${PUSH_GUARD}" "github.event_name != 'pull_request'"
assert_contains "the push guard also requires the default branch" \
    "${PUSH_GUARD}" "github.event.repository.default_branch"

for step in "Login to GitHub Container Registry" "Propagate tags from the pushed digest" \
    "Verify pushed tags share one digest" "Install Cosign" "Sign container image"; do
    assert_eq "'${step}' runs under exactly the push step's guard" \
        "${PUSH_GUARD}" "$(step_field "${step}" "if")"
done

# Order is the invariant that makes the verify step a gate rather than a report:
# it has to sit after the tags are propagated and before anything is signed.
STEP_ORDER="$(wf '[.jobs.build_push.steps[].name] | to_entries[] | "\(.key) \(.value)"')"
step_index() {
    grep -F " $1" <<<"${STEP_ORDER}" | head -n1 | cut -d' ' -f1
}
push_at="$(step_index "Push To GHCR")"
propagate_at="$(step_index "Propagate tags from the pushed digest")"
verify_at="$(step_index "Verify pushed tags share one digest")"
sign_at="$(step_index "Sign container image")"

if [[ -n "${push_at}" && -n "${propagate_at}" && -n "${verify_at}" && -n "${sign_at}" &&
    "${push_at}" -lt "${propagate_at}" && "${propagate_at}" -lt "${verify_at}" &&
    "${verify_at}" -lt "${sign_at}" ]]; then
    _pass "the tags are propagated, then verified, and only then signed"
else
    _fail "the tags are propagated, then verified, and only then signed" \
        "got push=${push_at} propagate=${propagate_at} verify=${verify_at} sign=${sign_at}" \
        "a verify step after the signing would report a split tag set that is" \
        "already published and signed"
fi

finish
