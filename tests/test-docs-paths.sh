#!/usr/bin/env bash
#
# Asserts that every repo path the docs name actually exists.
#
# README.md's "Repository Layout" block and the inline path references scattered
# through it and AGENTS.md are load-bearing: AGENTS.md tells an agent
# mid-incident to trust them. They drifted before — the layout block advertised
# `.github/renovate.json5` while the file was `renovate.json` at the repo root,
# and nothing failed — so this test makes that a red suite instead of a reader's
# problem.
#
# Three passes, because the three kinds of reference fail differently:
#
#   1. the layout block, where the first field of every line is a path,
#   2. inline `code spans`, filtered down to the ones that look like repo paths,
#      and
#   3. Markdown link targets — `](path)` — in every tracked *.md.
#
# The filter for (2) is deliberately conservative. A span only has to exist if
# it is unambiguously a path into this repo: no absolute paths (those are inside
# the built image, e.g. /usr/lib/modules), no registry references, no globs.
# A missed reference is a gap; a false positive would make the suite lie.
#
# (3) needs no filter at all, which is why it can cover documents (1) and (2)
# deliberately leave alone. A code span is prose that may or may not be a path,
# but a link target is an unambiguous claim that something is there — so every
# relative one is checked, in every tracked Markdown file rather than just the
# two an agent is told to trust. That matters because the cross-references now
# form a graph: CONTRIBUTING.md, docs/risk-tiers.md, docs/SECURITY-AI.md and the
# .github/prompts/*.prompt.md files point at each other and at workflow YAML
# with `../` hops, so renaming one file breaks readers of another. `#anchors`
# into a Markdown file are resolved too, against that file's real headings under
# GitHub's slug rules, because a heading rename leaves the link working and the
# reader stranded at the top of the page.
#
# Scope: relative targets only. http(s) and mailto are somebody else's uptime,
# and fenced code blocks are skipped in both directions — a link inside an
# example is a sample, not a claim.

set -uo pipefail

TEST_NAME="test-docs-paths"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"
# shellcheck source=tests/lib/markdown.sh
source "${TEST_DIR}/lib/markdown.sh"

# A path may be a file or a directory; the layout block lists both.
assert_path_exists() {
    local description=$1 path=$2
    if [[ -e "${REPO_ROOT}/${path}" ]]; then
        _pass "${description}"
    else
        _fail "${description}" "no such path in repo: ${path}"
    fi
}

# --- 1. README.md "Repository Layout" block ---------------------------------
#
# Bounded by the ```text fence that follows the heading. Each line is
# "<path><spaces><description>", so the first field is the path.

layout=$(
    awk '
        /^## Repository Layout$/ { in_section = 1; next }
        in_section && /^```/     { fence++; next }
        in_section && fence == 1 { print }
        fence == 2               { exit }
    ' "${REPO_ROOT}/README.md"
)

if [[ -z "${layout}" ]]; then
    _fail "README.md has a Repository Layout block" \
        "no fenced block found under the '## Repository Layout' heading"
else
    _pass "README.md has a Repository Layout block"
    while IFS= read -r line; do
        [[ -z "${line// }" ]] && continue
        path="${line%% *}"
        # Directory entries are written with a trailing slash.
        assert_path_exists "layout entry exists: ${path}" "${path%/}"
    done <<<"${layout}"
fi

# --- 2. inline code spans in README.md and AGENTS.md ------------------------
#
# Anchored on what the repo actually contains, which is what keeps the filter
# from firing on things that merely look like paths:
#
#   * a span with a separator is checked only when its first segment is a
#     real top-level entry here. That admits `.github/workflows/build.yml` and
#     would have caught `.github/renovate.json5`, while skipping the GitHub
#     org/repo references (`ublue-os/akmods`, `coreos/chunkah`) that share the
#     same shape.
#   * a span without one is matched by basename, because both docs refer to
#     `zfs.sh` and `post-check.sh` without their directory.

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

for doc in README.md AGENTS.md; do
    # SC2016: the backticks are the Markdown code-span delimiters being matched,
    # not a command substitution, so they have to stay literal.
    # shellcheck disable=SC2016
    spans=$(grep -oE '`[^`]+`' "${REPO_ROOT}/${doc}" | tr -d '`' | sort -u)

    checked=0
    while IFS= read -r span; do
        [[ -z "${span}" ]] && continue
        # Relative, no shell metacharacters, no scheme.
        [[ "${span}" =~ ^[A-Za-z0-9_.][A-Za-z0-9_./-]*$ ]] || continue

        if [[ "${span}" == */* ]]; then
            in_list "${span%%/*}" "${top_level[@]}" || continue
            checked=$((checked + 1))
            assert_path_exists "${doc} names an existing path: ${span}" "${span%/}"
        else
            # Only filenames, and only ones whose extension we own. A bare word
            # like `main` or `latest` is not a claim about a file.
            case "${span}" in
                *.md | *.sh | *.json | *.yml | Containerfile) ;;
                *) continue ;;
            esac
            checked=$((checked + 1))
            if in_list "${span}" "${basenames[@]}"; then
                _pass "${doc} names an existing file: ${span}"
            else
                _fail "${doc} names an existing file: ${span}" \
                    "no tracked file in the repo is named ${span}"
            fi
        fi
    done <<<"${spans}"

    if [[ "${checked}" -gt 0 ]]; then
        _pass "${doc} yielded ${checked} path reference(s) to check"
    else
        _fail "${doc} yielded path reference(s) to check" \
            "the code-span filter matched nothing, so this file is unverified"
    fi
done

# --- 3. Markdown link targets in every tracked *.md -------------------------

# outside_fences, slugify and heading_slugs come from lib/markdown.sh: the issue
# chooser links into these same documents by absolute URL, and
# test-issue-templates.sh has to resolve those anchors under the same rules.

docs=()
while IFS= read -r doc; do
    docs+=("${doc}")
done < <(cd "${REPO_ROOT}" && git ls-files '*.md' | sort)

if [[ "${#docs[@]}" -eq 0 ]]; then
    _fail "the repo tracks Markdown files" "git ls-files matched no *.md"
fi

links_checked=0
anchors_checked=0

for doc in "${docs[@]}"; do
    doc_dir=$(dirname "${REPO_ROOT}/${doc}")

    targets=$(outside_fences "${REPO_ROOT}/${doc}" |
        grep -oE '\]\([^()[:space:]]+\)' | sed -E 's/^\]\(|\)$//g' | sort -u)

    while IFS= read -r target; do
        [[ -z "${target}" ]] && continue
        # Somebody else's uptime.
        [[ "${target}" =~ ^(https?|mailto): ]] && continue

        anchor="${target#*#}"
        path="${target%%#*}"
        [[ "${target}" == *"#"* ]] || anchor=""

        # A bare "#anchor" points inside the document that wrote it.
        if [[ -z "${path}" ]]; then
            resolved="${REPO_ROOT}/${doc}"
        else
            # No normalisation needed: the intermediate directories are real, so
            # the filesystem resolves the "../" hops on its own.
            resolved="${doc_dir}/${path%/}"
            links_checked=$((links_checked + 1))
            if [[ -e "${resolved}" ]]; then
                _pass "${doc} links to an existing path: ${path}"
            else
                _fail "${doc} links to an existing path: ${path}" \
                    "no such path, resolved from ${doc}: ${resolved#"${REPO_ROOT}"/}"
                continue
            fi
        fi

        # An anchor into a Markdown file has to name a heading it really has.
        # Anchors into anything else (a directory listing, a YAML file rendered
        # by GitHub) are not this test's business.
        [[ -z "${anchor}" || "${resolved}" != *.md || ! -f "${resolved}" ]] && continue

        anchors_checked=$((anchors_checked + 1))
        if grep -qxF "${anchor}" <<<"$(heading_slugs "${resolved}")"; then
            _pass "${doc} links to an existing heading: ${target}"
        else
            _fail "${doc} links to an existing heading: ${target}" \
                "no heading in ${resolved#"${REPO_ROOT}"/} slugs to ${anchor}"
        fi
    done <<<"${targets}"
done

# Both counters guard the extraction itself: a regex that quietly stops matching
# would otherwise turn this pass into a silent no-op that still reports green.
if [[ "${links_checked}" -gt 0 ]]; then
    _pass "the docs yielded ${links_checked} relative link target(s) to check"
else
    _fail "the docs yielded relative link target(s) to check" \
        "the link extraction matched nothing, so every document is unverified"
fi

if [[ "${anchors_checked}" -gt 0 ]]; then
    _pass "the docs yielded ${anchors_checked} in-document anchor(s) to check"
else
    _fail "the docs yielded in-document anchor(s) to check" \
        "the anchor extraction matched nothing, so heading renames go unnoticed"
fi

finish
