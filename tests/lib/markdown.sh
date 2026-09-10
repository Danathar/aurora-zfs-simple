# shellcheck shell=bash
#
# Markdown helpers shared by the tests that check prose references.
#
# Sourced, never executed. These live here because two tests need the same
# answer to "what anchors does this document really offer": test-docs-paths.sh
# resolves `](file.md#anchor)` links between tracked documents, and
# test-issue-templates.sh resolves the absolute links the issue chooser
# (.github/ISSUE_TEMPLATE/config.yml) points into this repo's own Markdown. Two
# copies of GitHub's slug rules would drift, and a slug rule that drifts makes
# one of the two tests wrong without making either fail.

# Everything outside fenced code blocks. A link in a fenced example is a sample,
# not a claim about this repo, and the same fence rule has to apply when the
# headings are collected or an example's `# comment` would register as one.
outside_fences() {
    awk '/^[ \t]*(```|~~~)/ { fenced = !fenced; next } !fenced' "$1"
}

# GitHub's heading slug: lower-cased, backticks and punctuation dropped, each
# remaining space turned into a hyphen. Dropping punctuation does not join the
# words around it, which is why "kernel / ZFS" slugs to "kernel--zfs" — the
# doubled hyphen is correct and a link that omits it is broken.
slugify() {
    local text=${1,,}
    text=${text//\`/}
    text=$(printf '%s' "${text}" | LC_ALL=C sed -E 's/[^a-z0-9 _-]//g')
    printf '%s' "${text// /-}"
}

# The slugs a Markdown file offers, one per line.
heading_slugs() {
    local heading
    while IFS= read -r heading; do
        printf '%s\n' "$(slugify "${heading}")"
    done < <(outside_fences "$1" |
        sed -nE 's/^#{1,6}[[:space:]]+(.*[^[:space:]])[[:space:]]*$/\1/p')
}
