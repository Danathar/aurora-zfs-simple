# shellcheck shell=bash
#
# Extractors and claim checks shared by the tests that join a document to the
# files that make it true.
#
# Sourced, never executed, and after lib/assert.sh: `require_claim` and
# `require_nonempty` report through its `_pass` and `_fail`, and `require_claim`
# trims the caller's `REPO_ROOT` from the path it prints. They lived inside
# test-quality-docs.sh until a second test needed the same reading of the same
# kind of document; two copies would let "what counts as a gh call that names
# this repository" drift between the docs that are held to it.

# The body of one `##` section, verbatim, fences included. Scoping to a section
# rather than counting tables from the top of the file keeps each expectation
# anchored to what the document says where.
doc_section() {
    local file=$1 heading=$2
    awk -v heading="${heading}" '
        $0 == heading { in_section = 1; next }
        /^## /        { in_section = 0 }
        in_section
    ' "${file}"
}

# The data rows of the first Markdown table in a chunk of text: leading `|`,
# minus the header row and minus the `|---|` separator.
table_rows() {
    awk '
        /^\|/ {
            if ($0 ~ /^\|[[:space:]:|-]+\|[[:space:]:|-]*$/) { seen_rule = 1; next }
            if (seen_rule) { print }
            next
        }
        seen_rule && NF == 0 { seen_rule = 0 }
    '
}

# The bodies of the fenced blocks with a given info string, concatenated with a
# blank line between them so each stays a separate compound command.
fenced_blocks() {
    local file=$1 lang=$2
    awk -v lang="${lang}" '
        /^(```|~~~)/ {
            if (in_block) { in_block = 0; if (emit) print ""; emit = 0; next }
            info = $0
            sub(/^(```|~~~)/, "", info)
            gsub(/[[:space:]]/, "", info)
            in_block = 1
            emit = (info == lang)
            next
        }
        emit
    ' "${file}"
}

# A claim this file goes on to verify has to still be in the document. Without
# this every join below degrades to a check on the tree alone the moment the
# sentence it came from is deleted.
require_claim() {
    local file=$1 description=$2 needle=$3 flattened
    # Prose wraps, so the sentence being looked for is matched against the
    # document with its line breaks collapsed. A claim that has to be searched
    # for at one particular wrap point is a claim a reflow can silently delete.
    flattened="$(tr '\n' ' ' <"${file}" | tr -s '[:space:]' ' ')"
    if [[ "${flattened}" == *"${needle}"* ]]; then
        _pass "${file#"${REPO_ROOT}"/} still claims ${description}"
        return 0
    fi
    _fail "${file#"${REPO_ROOT}"/} still claims ${description}" \
        "the sentence this test verifies is gone: ${needle}" \
        "either restore it or drop the assertions that depend on it"
    return 1
}

# An extraction that matched nothing is not a passing check, it is an unverified
# document.
require_nonempty() {
    local description=$1 content=$2
    if [[ -n "${content//[[:space:]]/}" ]]; then
        _pass "the document still has ${description}"
        return 0
    fi
    _fail "the document still has ${description}" \
        "nothing was extracted, so the checks over it verify nothing"
    return 1
}

# Prints each command line in $1 (continuations already joined, see
# join_continuations) that runs a `gh` call without naming the repository $2. A line may hold a `$(gh ...)` inside a
# loop, so calls are counted rather than lines matched. Every subcommand counts,
# not a list of the ones in use today: `gh api` has to name the repository in
# its path, and anything else -- `pr`, `run`, or a later `gh workflow list` --
# has to carry `--repo` or `-R`.
unscoped_gh_calls() {
    local slug=$2 line calls named api_calls api_named
    while IFS= read -r line; do
        calls="$(grep -oE '(^|[^[:alnum:]_./-])gh [a-z]+' <<<"${line}" | grep -vc ' api$')"
        named="$(grep -oE -- "(--repo|-R) ${slug}( |$)" <<<"${line}" | wc -l)"
        api_calls="$(grep -oE '(^|[^[:alnum:]_./-])gh api ' <<<"${line}" | wc -l)"
        api_named="$(grep -oE "gh api \"?repos/${slug}/" <<<"${line}" | wc -l)"
        if [[ "${calls}" -ne "${named}" || "${api_calls}" -ne "${api_named}" ]]; then
            printf '%s\n' "${line}"
        fi
    done <<<"$1"
}

# Backslash-continued lines joined into one, so a multi-line `gh` command can be
# inspected as the single command a reader pastes.
join_continuations() {
    sed -e ':a' -e '/\\$/N; s/\\\n[[:space:]]*/ /; ta'
}

# Every single-quoted `-q`/`--jq` filter in the joined commands on stdin, one per
# line. A filter written any other way is not read, which is why callers also
# compare this count with `jq_flag_count`.
jq_filters() {
    grep -oE -- "(-q|--jq) '[^']+'" | sed -E "s/^(-q|--jq) '//; s/'\$//"
}

# How many `-q`/`--jq` flags the `gh` commands on stdin carry.
jq_flag_count() {
    grep -E '(^|[^[:alnum:]_./-])gh [a-z]+' | grep -oE -- '(^|[[:space:]])(-q|--jq)([[:space:]]|=)' | wc -l
}

# Fails for each filter on stdin (one per line) that jq cannot compile. Status 3
# is jq's compile error; 5 is "this filter errored on this input", which says
# nothing about the filter a reader runs against real data.
assert_jq_filters_compile() {
    local description=$1 filter bad=""
    while IFS= read -r filter; do
        [[ -z "${filter}" ]] && continue
        jq "${filter}" <<<'[]' >/dev/null 2>&1
        [[ $? -eq 3 ]] && bad+="${filter:0:60}"$'\n'
    done
    assert_eq "${description}" "" "${bad%$'\n'}"
}

