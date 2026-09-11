#!/usr/bin/env bash
#
# Tests for `.github/ISSUE_TEMPLATE/**` — the three files nothing else here reads.
#
# The rest of the suite covers code, workflows and prose. The issue forms are
# none of those, and they fail in a way no other surface does: GitHub validates
# them server-side and, when one is malformed, silently drops it from the chooser
# rather than reporting an error anywhere a maintainer will see. The template
# that was supposed to ask for the two akmods labels simply stops being offered,
# and the next build-failure report arrives with a log dump and no diagnosis.
#
# So there are two kinds of assertion here.
#
#   1. Shape, against what GitHub's issue-form schema accepts: the element types,
#      unique ids, labels, real booleans in `validations.required`, dropdowns with
#      options. This is the part that decides whether the form is offered at all.
#
#   2. Agreement with the tree, which is the part that rots quietly. Both forms
#      name real files; `build-failure.yml` goes further and embeds a runnable
#      diagnosis — a `sed` that reads `FEDORA_VERSION` out of the `Containerfile`,
#      the two `ghcr.io/ublue-os/akmods*` references it feeds, the `ostree.linux`
#      label to inspect, and the `grep` that finds the failing lines in a run log.
#      Every one of those is a claim about something else in this repo. The `sed`
#      is executed here against the real `Containerfile` rather than matched as a
#      string, because the failure mode is not "the text changed" — it is "the
#      text is unchanged and now extracts nothing".
#
# The copied-recipe checks are the reason this is worth a file. `AGENTS.md` holds
# the same 60-second diagnosis, and AGENTS.md is what an agent is told to trust
# mid-incident. The two copies have to say the same thing: a reporter following
# the form and an agent following AGENTS.md must end up inspecting the same
# images with the same label, or the form collects evidence for a question nobody
# is asking.
#
# test-docs-paths.sh checks the prose this way already, but only for `*.md`, and
# the chooser's `contact_links` are absolute URLs in YAML — out of its reach in
# both respects. One of them carries an `#anchor` into AGENTS.md, so a heading
# rename there leaves the "read this first" link landing at the top of the page.

set -uo pipefail

TEST_NAME="test-issue-templates"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=tests/lib/markdown.sh
source "${TEST_DIR}/lib/markdown.sh"

TEMPLATE_DIR="${REPO_ROOT}/.github/ISSUE_TEMPLATE"
BUG_FORM="${TEMPLATE_DIR}/bug.yml"
BUILD_FAILURE_FORM="${TEMPLATE_DIR}/build-failure.yml"
CHOOSER="${TEMPLATE_DIR}/config.yml"
CONTAINERFILE="${REPO_ROOT}/Containerfile"
BUILD_WF="${REPO_ROOT}/.github/workflows/build.yml"
BADGE_SCRIPT="${REPO_ROOT}/ci/write-badges.sh"
AGENTS_DOC="${REPO_ROOT}/AGENTS.md"
WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

for required in "${BUG_FORM}" "${BUILD_FAILURE_FORM}" "${CHOOSER}" \
    "${CONTAINERFILE}" "${BUILD_WF}" "${BADGE_SCRIPT}" "${AGENTS_DOC}"; do
    if [[ ! -f "${required}" ]]; then
        _fail "every file this test reads exists" \
            "no such file: ${required#"${REPO_ROOT}"/}" \
            "if it was removed on purpose, update or delete this test with it"
        finish
        exit 1
    fi
done

# A missing parser must fail rather than skip: these templates are the only
# instructions a reporter gets, and an unparsed file is an unchecked file.
if ! "${WORKFLOW_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    _fail "the issue-template checker requires Python 3 with PyYAML" \
        "install python3-yaml (Debian/Ubuntu) or python3-pyyaml (Fedora)," \
        "or install PyYAML in the interpreter selected by WORKFLOW_PYTHON"
    finish
    exit 1
fi

# --- parser -----------------------------------------------------------------

NORMALIZER="${TMP_ROOT}/to-json.py"
cat >"${NORMALIZER}" <<'PY'
"""Print one issue-template YAML file as JSON on stdout.

Nothing is rewritten: issue forms have no equivalent of a workflow's `on:`
quirk. The point of going through PyYAML is that it is the parser with a claim
to matching what GitHub accepts, so `required: true` arrives as a boolean and
`required: "true"` arrives as a string -- a difference every jq query below
depends on and no grep can see.
"""

import json
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = yaml.safe_load(handle)

json.dump(doc, sys.stdout)
PY

# The normalizer is tested before it is trusted: a quietly broken one would make
# every assertion below vacuous rather than red.
fixture="${TMP_ROOT}/fixture.yml"
cat >"${fixture}" <<'YAML'
---
name: Fixture
body:
  - type: textarea
    id: evidence
    attributes:
      label: Evidence
    validations:
      required: true
  - type: dropdown
    id: area
    attributes:
      label: Area
      options:
        - first
        - second
YAML

fixture_json="${TMP_ROOT}/fixture.json"
if "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${fixture}" >"${fixture_json}" 2>"${TMP_ROOT}/fixture.err"; then
    assert_eq "the normalizer reads a fixture form's element type" \
        "textarea" "$(jq -r '.body[0].type' <"${fixture_json}")"
    assert_eq "the normalizer keeps validations.required a boolean" \
        "boolean" "$(jq -r '.body[0].validations.required | type' <"${fixture_json}")"
    assert_eq "the normalizer reads a fixture form's dropdown options" \
        "first second" "$(jq -r '.body[1].attributes.options | join(" ")' <"${fixture_json}")"
else
    _fail "the normalizer parses a fixture issue form" "$(cat "${TMP_ROOT}/fixture.err")"
    finish
    exit 1
fi

# json_for <file> — path to that file's JSON, parsed once. Empty on failure.
json_for() {
    local file=$1 name json
    name="$(basename "${file}" .yml)"
    json="${TMP_ROOT}/${name}.json"
    if [[ -f "${json}" ]]; then
        printf '%s' "${json}"
        return 0
    fi
    if "${WORKFLOW_PYTHON}" -B "${NORMALIZER}" "${file}" >"${json}" 2>"${TMP_ROOT}/${name}.err"; then
        printf '%s' "${json}"
        return 0
    fi
    rm -f "${json}"
    return 1
}

# q <json> <jq expression> — one value out of a parsed template.
q() {
    jq -r "$2" <"$1"
}

# --- 1. the two issue forms are shapes GitHub will accept -------------------
#
# Every assertion in this section is one GitHub enforces server-side, where
# failing it means the form is dropped from the chooser without a message.

FORM_JSON=()
for form in "${BUG_FORM}" "${BUILD_FAILURE_FORM}"; do
    rel="${form#"${REPO_ROOT}"/}"
    if ! json="$(json_for "${form}")"; then
        _fail "${rel} parses as YAML" "$(cat "${TMP_ROOT}/$(basename "${form}" .yml).err")"
        continue
    fi
    _pass "${rel} parses as YAML"
    FORM_JSON+=("${json}")

    assert_eq "${rel} declares a non-empty name" \
        "yes" "$(q "${json}" 'if (.name | type) == "string" and (.name | length) > 0 then "yes" else "no" end')"
    assert_eq "${rel} declares a non-empty description" \
        "yes" "$(q "${json}" 'if (.description | type) == "string" and (.description | length) > 0 then "yes" else "no" end')"

    # Without labels the form is indistinguishable from a blank issue once it is
    # filed, which is the whole reason for having two of them.
    assert_eq "${rel} applies at least one non-empty label" \
        "yes" "$(q "${json}" '
            if (.labels | type) == "array"
                and (.labels | length) > 0
                and ([.labels[] | select((type != "string") or (length == 0))] | length) == 0
            then "yes" else "no" end')"

    assert_eq "${rel} has a non-empty body" \
        "yes" "$(q "${json}" 'if (.body | type) == "array" and (.body | length) > 0 then "yes" else "no" end')"

    # SC2016: $type is a jq variable, not a shell one, here and in the queries
    # below that bind one.
    # shellcheck disable=SC2016
    assert_eq "${rel} uses only element types GitHub accepts" \
        "" "$(q "${json}" '
            [.body[] | (.type // "<none>") as $type
             | select(["markdown","input","textarea","dropdown","checkboxes"] | index($type) | not)
             | $type]
            | join(", ")')"

    # A markdown block is the only element with no id, and the only one that
    # cannot carry validations; GitHub rejects both.
    assert_eq "${rel}'s markdown blocks carry text and nothing else" \
        "" "$(q "${json}" '
            [.body[] | select(.type == "markdown")
             | select((((.attributes.value // "") | gsub("\\s"; "")) == "")
                      or has("id") or has("validations"))]
            | length | if . == 0 then "" else "\(.) malformed markdown block(s)" end')"

    assert_eq "${rel}'s input elements all declare a usable id" \
        "" "$(q "${json}" '
            [.body[] | select(.type != "markdown")
             | select(((.id // "") | test("^[A-Za-z0-9_-]+$")) | not)
             | (.id // "<none>")]
            | join(", ")')"

    # shellcheck disable=SC2016
    assert_eq "${rel}'s element ids are unique" \
        "yes" "$(q "${json}" '
            [.body[] | select(.type != "markdown") | .id] as $ids
            | if ($ids | length) == ($ids | unique | length) then "yes"
              else "no: " + (($ids | group_by(.) | map(select(length > 1) | .[0])) | join(", ")) end')"

    assert_eq "${rel}'s input elements all declare a label" \
        "" "$(q "${json}" '
            [.body[] | select(.type != "markdown")
             | select((((.attributes.label // "") | gsub("\\s"; "")) == ""))
             | (.id // "<none>")]
            | join(", ")')"

    # `required: "true"` is a string, parses fine, and is not what GitHub reads.
    assert_eq "${rel} spells validations.required as a boolean" \
        "" "$(q "${json}" '
            [.body[] | select(has("validations"))
             | select((.validations.required | type) != "boolean")
             | (.id // "<none>")]
            | join(", ")')"

    assert_eq "${rel}'s dropdowns offer at least two distinct non-empty options" \
        "" "$(q "${json}" '
            [.body[] | select(.type == "dropdown")
             | select(((.attributes.options | type) != "array")
                      or ((.attributes.options | length) < 2)
                      or ([.attributes.options[] | select((type != "string") or (length == 0))] | length) > 0
                      or ((.attributes.options | length) != (.attributes.options | unique | length)))
             | (.id // "<none>")]
            | join(", ")')"

    # A form where nothing is required collects a title and an empty body.
    assert_eq "${rel} requires at least one field" \
        "yes" "$(q "${json}" 'if ([.body[] | select(.validations.required == true)] | length) > 0 then "yes" else "no" end')"
done

# --- 2. the chooser ---------------------------------------------------------

if ! CHOOSER_JSON="$(json_for "${CHOOSER}")"; then
    _fail ".github/ISSUE_TEMPLATE/config.yml parses as YAML" "$(cat "${TMP_ROOT}/config.err")"
    CHOOSER_JSON=""
else
    _pass ".github/ISSUE_TEMPLATE/config.yml parses as YAML"

    # Quoted, this is the string "true" and GitHub reads it as false — the
    # difference between "Open a blank issue" being offered and not.
    assert_eq "config.yml spells blank_issues_enabled as a boolean" \
        "boolean" "$(q "${CHOOSER_JSON}" '.blank_issues_enabled | type')"

    assert_eq "config.yml offers at least one contact link" \
        "yes" "$(q "${CHOOSER_JSON}" 'if (.contact_links | type) == "array" and (.contact_links | length) > 0 then "yes" else "no" end')"

    # GitHub requires all three keys on every link and drops the whole file if
    # one is missing, taking blank_issues_enabled with it.
    assert_eq "every contact link declares name, url and about" \
        "" "$(q "${CHOOSER_JSON}" '
            [.contact_links[]
             | select((((.name // "") | tostring | gsub("\\s"; "")) == "")
                      or (((.url // "") | tostring | gsub("\\s"; "")) == "")
                      or (((.about // "") | tostring | gsub("\\s"; "")) == ""))
             | (.name // "<unnamed>")]
            | join(", ")')"

    assert_eq "every contact link is an https URL" \
        "" "$(q "${CHOOSER_JSON}" '
            [.contact_links[] | select((.url // "" | tostring | startswith("https://")) | not) | (.url // "<none>")]
            | join(", ")')"
fi

# --- 3. the URLs that point back into this repository -----------------------
#
# A link into this repo is a claim about a path here, and test-docs-paths.sh
# cannot see these: they are absolute, and they are in YAML.

self_urls=$(grep -ohE 'https://(github\.com|raw\.githubusercontent\.com)/[A-Za-z0-9][A-Za-z0-9._/#-]*' \
    "${BUG_FORM}" "${BUILD_FAILURE_FORM}" "${CHOOSER}" | sort -u)

slugs=()
while IFS= read -r url; do
    [[ -z "${url}" ]] && continue
    rest="${url#https://}"
    host="${rest%%/*}"
    path="${rest#*/}"
    owner="${path%%/*}"
    repo_rest="${path#*/}"
    name="${repo_rest%%/*}"
    [[ -z "${owner}" || -z "${name}" || "${owner}" == "${path}" ]] && continue
    slugs+=("${host}|${owner}/${name}|${url}")
done <<<"${self_urls}"

if [[ "${#slugs[@]}" -eq 0 ]]; then
    _fail "the templates yielded GitHub URLs to check" \
        "the URL extraction matched nothing, so every link in them is unverified"
fi

# The repository these templates belong to, taken from the templates themselves
# and then held against README.md. Nothing in a checkout knows its own slug — a
# fork has a different one — but the chooser and the README must agree on it, or
# "read this first" sends a reporter to another repository's copy of the docs.
own_slug=""
for entry in "${slugs[@]}"; do
    candidate="${entry#*|}"
    candidate="${candidate%%|*}"
    if grep -qF "github.com/${candidate}" "${REPO_ROOT}/README.md"; then
        own_slug="${candidate}"
        break
    fi
done

if [[ -z "${own_slug}" ]]; then
    _fail "the templates link to the repository README.md links to" \
        "no owner/name in the templates' GitHub URLs appears in README.md" \
        "found: $(printf '%s\n' "${slugs[@]}" | cut -d'|' -f2 | sort -u | tr '\n' ' ')"
else
    _pass "the templates link to the repository README.md links to: ${own_slug}"

    # Every URL naming this repository agrees on the owner. A transfer or a fork
    # leaves one copy behind under the old owner, and the stale link still
    # resolves — to somebody else's tree. Matched on the repository *name*, so an
    # ordinary cross-link (ublue-os/akmods, ublue-os/aurora) is not this test's
    # business; a link to the old owner's copy of this repo is.
    own_name="${own_slug#*/}"
    assert_eq "every URL naming ${own_name} uses the owner README.md links to" \
        "" "$(printf '%s\n' "${slugs[@]}" |
        awk -F'|' -v slug="${own_slug}" -v name="${own_name}" \
            '$2 != slug && substr($2, index($2, "/") + 1) == name { print $3 }' |
        sort -u | tr '\n' ' ' | sed 's/ $//')"

    paths_checked=0
    anchors_checked=0
    for entry in "${slugs[@]}"; do
        host="${entry%%|*}"
        slug="${entry#*|}"
        slug="${slug%%|*}"
        url="${entry##*|}"
        [[ "${slug}" == "${own_slug}" ]] || continue

        # Only the two forms that name a file: blob/<ref>/<path> on github.com,
        # and <ref>/<path> on raw.githubusercontent.com. An /actions/ or /issues/
        # URL names no path here.
        tail_path=""
        case "${host}" in
            github.com)
                after="${url#https://github.com/"${slug}"/}"
                [[ "${after}" == blob/* ]] || continue
                after="${after#blob/}"
                tail_path="${after#*/}"
                ;;
            raw.githubusercontent.com)
                after="${url#https://raw.githubusercontent.com/"${slug}"/}"
                tail_path="${after#*/}"
                ;;
            *)
                continue
                ;;
        esac
        [[ -z "${tail_path}" || "${tail_path}" == "${after}" ]] && continue

        anchor=""
        [[ "${tail_path}" == *"#"* ]] && anchor="${tail_path#*#}"
        file_path="${tail_path%%#*}"
        [[ -z "${file_path}" ]] && continue

        paths_checked=$((paths_checked + 1))
        if [[ -e "${REPO_ROOT}/${file_path}" ]]; then
            _pass "the templates link to an existing path: ${file_path}"
        else
            _fail "the templates link to an existing path: ${file_path}" \
                "no such path in this repo, linked as ${url}"
            continue
        fi

        [[ -z "${anchor}" || "${file_path}" != *.md ]] && continue
        anchors_checked=$((anchors_checked + 1))
        if grep -qxF "${anchor}" <<<"$(heading_slugs "${REPO_ROOT}/${file_path}")"; then
            _pass "the templates link to an existing heading: ${file_path}#${anchor}"
        else
            _fail "the templates link to an existing heading: ${file_path}#${anchor}" \
                "no heading in ${file_path} slugs to ${anchor}" \
                "a renamed heading leaves this link landing at the top of the page"
        fi
    done

    if [[ "${paths_checked}" -gt 0 ]]; then
        _pass "the templates yielded ${paths_checked} in-repo path link(s) to check"
    else
        _fail "the templates yielded in-repo path link(s) to check" \
            "the blob/raw URL extraction matched nothing, so those links are unverified"
    fi
    if [[ "${anchors_checked}" -gt 0 ]]; then
        _pass "the templates yielded ${anchors_checked} heading anchor(s) to check"
    else
        _fail "the templates yielded heading anchor(s) to check" \
            "no anchored link was extracted, so a heading rename goes unnoticed"
    fi
fi

# --- 4. every repo file the templates name still exists ---------------------
#
# Same conservative filter test-docs-paths.sh applies to code spans: a path is
# checked only when it is unambiguously one, and the extensions are the ones this
# repo owns. The dropdown that routes a report to an area names four of them.

top_level=()
while IFS= read -r entry; do
    top_level+=("${entry}")
done < <(cd "${REPO_ROOT}" && git ls-files | cut -d/ -f1 | sort -u)

basenames=()
while IFS= read -r entry; do
    basenames+=("${entry}")
done < <(cd "${REPO_ROOT}" && git ls-files | xargs -n1 basename | sort -u)

in_list() {
    local needle=$1 item
    shift
    for item in "$@"; do
        [[ "${item}" == "${needle}" ]] && return 0
    done
    return 1
}

# Only the strings the templates show a reader, not their YAML keys.
template_strings=""
for json in "${FORM_JSON[@]}" ${CHOOSER_JSON:+"${CHOOSER_JSON}"}; do
    template_strings+=$'\n'"$(jq -r '[.. | strings] | join("\n")' <"${json}")"
done

tokens=$(grep -oE '[A-Za-z0-9_.][A-Za-z0-9_./-]*' <<<"${template_strings}" | sort -u)

paths_named=0
while IFS= read -r token; do
    [[ -z "${token}" ]] && continue
    case "${token}" in
        *.md | *.sh | *.json | *.yml | Containerfile) ;;
        *) continue ;;
    esac
    # A URL fragment or an image reference is not a path into this checkout.
    [[ "${token}" == *://* || "${token}" == *.com/* || "${token}" == *ghcr.io* ]] && continue

    paths_named=$((paths_named + 1))
    if [[ "${token}" == */* ]]; then
        if ! in_list "${token%%/*}" "${top_level[@]}"; then
            paths_named=$((paths_named - 1))
            continue
        fi
        if [[ -e "${REPO_ROOT}/${token}" ]]; then
            _pass "the templates name an existing path: ${token}"
        else
            _fail "the templates name an existing path: ${token}" \
                "no such path in repo"
        fi
    elif in_list "${token}" "${basenames[@]}"; then
        _pass "the templates name an existing file: ${token}"
    else
        _fail "the templates name an existing file: ${token}" \
            "no tracked file in the repo is named ${token}"
    fi
done <<<"${tokens}"

if [[ "${paths_named}" -gt 0 ]]; then
    _pass "the templates yielded ${paths_named} file reference(s) to check"
else
    _fail "the templates yielded file reference(s) to check" \
        "the filter matched nothing, so the templates' file references are unverified"
fi

# --- 5. the embedded diagnosis still works ---------------------------------
#
# build-failure.yml asks a reporter to run a command block before filling in the
# rest, and the answer it produces is the diagnosis for almost every red build
# here. Each piece of that block is checked against the thing it reads.

BF_JSON="${TMP_ROOT}/build-failure.json"
bf_markdown="$(jq -r '[.body[] | select(.type == "markdown") | .attributes.value] | join("\n")' <"${BF_JSON}")"
recipe="$(awk '/^[ \t]*```/ { fenced = !fenced; next } fenced' <<<"${bf_markdown}")"

if [[ -z "${recipe//[[:space:]]/}" ]]; then
    _fail "build-failure.yml embeds a command block" \
        "no fenced block found in its markdown elements; the rest of this section is vacuous"
else
    _pass "build-failure.yml embeds a command block"

    # 5a. The Fedora release is read out of the Containerfile rather than typed,
    #     which is the template's own claim about why it keeps working. Run the
    #     sed it tells the reporter to run: a renamed or requoted ARG leaves it
    #     extracting nothing and the whole diagnosis targets an empty tag.
    sed_script="$(grep -oE "sed -n 's[^']*'" <<<"${recipe}" | head -1 | sed -E "s/^sed -n '//; s/'$//")"
    if [[ -z "${sed_script}" ]]; then
        _fail "the diagnosis reads FEDORA_VERSION out of the Containerfile with sed" \
            "no sed -n '…' found in the command block"
        fedora_version=""
    else
        _pass "the diagnosis reads FEDORA_VERSION out of the Containerfile with sed"
        fedora_version="$(sed -n "${sed_script}" "${CONTAINERFILE}")"
        if [[ "${fedora_version}" =~ ^[0-9]+$ ]]; then
            _pass "running that sed against the real Containerfile yields a release: ${fedora_version}"
        else
            _fail "running that sed against the real Containerfile yields a release" \
                "sed -n '${sed_script}' Containerfile printed: ${fedora_version:-<nothing>}" \
                "the reporter would inspect ':coreos-stable--x86_64' and learn nothing"
        fi
    fi

    # 5b. The two images it inspects are the two the Containerfile builds from.
    #     Either side can move: a new tag scheme in the Containerfile, or a third
    #     akmods image, and the form keeps asking about the old pair.
    ref_template="$(grep -oE 'docker://ghcr\.io/[^"]+' <<<"${recipe}" | head -1)"
    img_list="$(grep -oE 'for +img +in +[A-Za-z0-9 _-]+' <<<"${recipe}" | head -1 | sed -E 's/^for +img +in +//')"
    from_refs="$(sed -nE 's/^FROM +([^ ]+).*/\1/p' "${CONTAINERFILE}" |
        tr -d '"' | sed "s/\${FEDORA_VERSION}/${fedora_version}/g" | sort -u)"

    if [[ -z "${ref_template}" || -z "${img_list}" || -z "${fedora_version}" ]]; then
        _fail "the diagnosis inspects images the Containerfile builds from" \
            "could not extract the loop (images: ${img_list:-<none>}, reference: ${ref_template:-<none>})"
    else
        for img in ${img_list}; do
            expected="${ref_template#docker://}"
            expected="${expected//\$\{img\}/${img}}"
            expected="${expected//\$\{FEDORA_VERSION\}/${fedora_version}}"
            if grep -qxF "${expected}" <<<"${from_refs}"; then
                _pass "the diagnosis inspects an image the Containerfile builds from: ${expected}"
            else
                _fail "the diagnosis inspects an image the Containerfile builds from: ${expected}" \
                    "no FROM in the Containerfile resolves to it" \
                    "Containerfile FROM references: $(tr '\n' ' ' <<<"${from_refs}")"
            fi
        done

        # And it asks about both of them: the comparison is the diagnosis, so one
        # image alone answers nothing.
        assert_eq "the diagnosis compares the akmods pair" \
            "2" "$(wc -w <<<"${img_list}" | tr -d ' ')"
    fi

    # 5c. The label it reads is the label this repo's own badge script reads.
    label="$(grep -oE 'index \.Labels "[^"]+"' <<<"${recipe}" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
    if [[ -z "${label}" ]]; then
        _fail "the diagnosis inspects a label ci/write-badges.sh also reads" \
            "no '{{ index .Labels \"…\" }}' found in the command block"
    else
        if grep -qF "\"${label}\"" "${BADGE_SCRIPT}"; then
            _pass "the diagnosis inspects a label ci/write-badges.sh also reads: ${label}"
        else
            _fail "the diagnosis inspects a label ci/write-badges.sh also reads: ${label}" \
                "ci/write-badges.sh does not read that label, so the badge and the form" \
                "would be answering the skew question from different data"
        fi
    fi
fi

# 5d. The log grep is AGENTS.md's, verbatim. AGENTS.md is what an agent is told
#     to trust mid-incident; a reporter following the form has to surface the
#     same lines that document asks for.
log_grep="$(grep -ohE 'grep -E "[^"]+"' "${BUILD_FAILURE_FORM}" | head -1)"
if [[ -z "${log_grep}" ]]; then
    _fail "build-failure.yml tells the reporter how to grep the failing log" \
        "no 'grep -E \"…\"' found in the template"
else
    _pass "build-failure.yml tells the reporter how to grep the failing log"
    if grep -qF "${log_grep}" "${AGENTS_DOC}"; then
        _pass "that grep is the one AGENTS.md gives: ${log_grep}"
    else
        _fail "that grep is the one AGENTS.md gives" \
            "the template says: ${log_grep}" \
            "AGENTS.md's 60-second diagnosis does not contain that string," \
            "so the form and the document a responder trusts disagree"
    fi
fi

# 5e. AGENTS.md's copy of the same recipe hard-codes the release the template
#     reads out of the Containerfile. After a FEDORA_VERSION bump the two
#     disagree, and AGENTS.md is the copy an agent runs.
agents_version="$(grep -oE '^FEDORA_VERSION=[0-9]+' "${AGENTS_DOC}" | head -1 | cut -d= -f2)"
if [[ -z "${agents_version}" ]]; then
    _fail "AGENTS.md's diagnosis pins a Fedora release" \
        "no 'FEDORA_VERSION=<n>' line found in AGENTS.md"
else
    containerfile_version="$(sed -nE 's/^ARG FEDORA_VERSION=([0-9]+).*/\1/p' "${CONTAINERFILE}" | head -1)"
    assert_eq "AGENTS.md's diagnosis targets the Containerfile's Fedora release" \
        "${containerfile_version}" "${agents_version}"
fi

# --- 6. the failure modes the dropdown offers are still real ----------------
#
# Each option routes a report at a mechanism in this repo. When one of those is
# removed the option becomes a trap: a reporter picks it and describes something
# that cannot happen.
shapes="$(jq -r '[.body[] | select(.type == "dropdown") | .attributes.options[]] | join("\n")' <"${BF_JSON}")"

if grep -qi 'chunkah' <<<"${shapes}"; then
    _pass "the shape dropdown offers the Chunkah rechunk"
    # The step, not a passing mention: a comment or a leftover environment
    # variable naming Chunkah does not rechunk anything.
    if grep -qiE '^[[:space:]]*-[[:space:]]+name:.*chunkah' "${BUILD_WF}"; then
        _pass "and build.yml still has a step that rechunks with Chunkah"
    else
        _fail "and build.yml still has a step that rechunks with Chunkah" \
            "no step in build.yml is named after Chunkah; the option describes a step that is gone"
    fi
else
    _fail "the shape dropdown offers the Chunkah rechunk" \
        "build.yml rechunks with Chunkah and that failure has its own exit code (126);" \
        "if the step is gone, remove this assertion with the option"
fi

if grep -qi 'fedora version guard' <<<"${shapes}"; then
    _pass "the shape dropdown offers the Containerfile's Fedora version guard"
    # The comparison, not the words: the error message this guard prints names
    # `rpm -E %fedora` too, and a guard reduced to its own error message would
    # leave a mismatched base image building.
    # SC2016: the Containerfile's own text is being matched, so its expansions
    # have to stay literal.
    # shellcheck disable=SC2016
    if grep -qF 'test "$(rpm -E %fedora)" = "${FEDORA_VERSION}"' "${CONTAINERFILE}"; then
        _pass "and the Containerfile still compares rpm -E %fedora with FEDORA_VERSION"
    else
        _fail "and the Containerfile still compares rpm -E %fedora with FEDORA_VERSION" \
            "the guard the option names is not in the Containerfile any more"
    fi
else
    _fail "the shape dropdown offers the Containerfile's Fedora version guard" \
        "the Containerfile fails the build when its base image is a different release;" \
        "if that guard is gone, remove this assertion with the option"
fi

finish
