#!/usr/bin/env bash
#
# Measures .editorconfig against the tree it claims to describe.
#
# The file's own opening sentence is the contract being tested: it "encodes the
# conventions already in the tree rather than proposing new ones". That is a
# falsifiable statement about every tracked file, and nothing was checking it.
# A rule that no longer matches the tree is worse than no rule, because the
# editor is the thing that acts on it: an indent_size an editor believes and the
# file disagrees with produces a reformatting diff in the next PR that touches
# the file, which is precisely the diff .editorconfig exists to prevent.
#
# Both directions are checked for every claim that names a file:
#
#   * a declared section whose glob matches no tracked file fails   (stale rule)
#   * a file whose measured style differs from its resolved rule    (stale tree)
#   * the set of two-space shell scripts must be exactly the set
#     .editorconfig declares as two-space                           (either way)
#
# Resolution is last-match-wins across sections, which is EditorConfig's own
# rule, so the matcher below is hand-rolled and carries its own case table --
# without one, every assertion that depends on it could be vacuously true.
#
# Two measurements, each chosen because the obvious one is wrong here:
#
#   * shell: the most common positive indentation step, with heredoc bodies
#     skipped. The tests embed YAML, JSON and Python fixtures in heredocs, so a
#     measure that reads them reports the fixture's language, not the script's.
#   * YAML and JSON: the smallest positive indentation depth. Nested sequences
#     step by four in .github/labeler.yml while the file is two-space, so "most
#     common step" is wrong for these; the first nesting level is not.
#
# Markdown and Python are deliberately not measured. A Markdown list
# continuation and a Python line wrapped to an open parenthesis both indent to
# an alignment column rather than by an indent step, so neither file type has a
# step to compare against.

set -uo pipefail

TEST_NAME="test-editorconfig"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

CONFIG="${REPO_ROOT}/.editorconfig"

assert_file_exists ".editorconfig is tracked at the repository root" "${CONFIG}"

analysis=""
if analysis=$(python3 - "${REPO_ROOT}" <<'PY'
import os
import re
import subprocess
import sys

repo_root = sys.argv[1]


def git(*args):
    result = subprocess.run(
        ["git", "-C", repo_root, *args],
        capture_output=True,
        text=True,
        check=True,
    )
    return [line for line in result.stdout.split("\n") if line]


tracked = git("ls-files")
tracked_dirs = set()
for path in tracked:
    parts = path.split("/")
    for index in range(1, len(parts)):
        tracked_dirs.add("/".join(parts[:index]))

# --- .editorconfig, parsed -------------------------------------------------

preamble = {}
sections = []
comments = []
current = None
config_text = open(os.path.join(repo_root, ".editorconfig"), encoding="utf-8").read()
for raw in config_text.split("\n"):
    line = raw.strip()
    if not line:
        continue
    if line.startswith("#") or line.startswith(";"):
        comments.append(line.lstrip("#; ").rstrip())
        continue
    if line.startswith("[") and line.endswith("]"):
        current = (line[1:-1], {})
        sections.append(current)
        continue
    if "=" in line:
        key, value = line.split("=", 1)
        key = key.strip().lower()
        value = value.strip()
        if current is None:
            preamble[key] = value
        else:
            current[1][key] = value

# --- EditorConfig glob matching, hand-rolled -------------------------------


def translate(pattern):
    out = []
    index = 0
    end = len(pattern)
    while index < end:
        char = pattern[index]
        if char == "*":
            if pattern[index:index + 2] == "**":
                out.append(".*")
                index += 2
            else:
                out.append("[^/]*")
                index += 1
        elif char == "?":
            out.append("[^/]")
            index += 1
        elif char == "[":
            close = index + 1
            if close < end and pattern[close] in "!^":
                close += 1
            if close < end and pattern[close] == "]":
                close += 1
            while close < end and pattern[close] != "]":
                close += 1
            if close >= end:
                out.append(re.escape("["))
                index += 1
            else:
                body = pattern[index + 1:close]
                if body.startswith("!"):
                    body = "^" + body[1:]
                out.append("[" + body + "]")
                index = close + 1
        elif char == "{":
            depth = 1
            close = index + 1
            while close < end and depth:
                if pattern[close] == "{":
                    depth += 1
                elif pattern[close] == "}":
                    depth -= 1
                close += 1
            body = pattern[index + 1:close - 1]
            parts = []
            buffer = ""
            nested = 0
            for char in body:
                if char == "," and nested == 0:
                    parts.append(buffer)
                    buffer = ""
                    continue
                if char == "{":
                    nested += 1
                elif char == "}":
                    nested -= 1
                buffer += char
            parts.append(buffer)
            out.append("(?:" + "|".join(translate(part) for part in parts) + ")")
            index = close
        elif char == "\\":
            if index + 1 < end:
                out.append(re.escape(pattern[index + 1]))
                index += 2
            else:
                out.append(re.escape("\\"))
                index += 1
        else:
            out.append(re.escape(char))
            index += 1
    return "".join(out)


def matches(pattern, path):
    glob = pattern[1:] if pattern.startswith("/") else pattern
    expression = re.compile("^" + translate(glob) + "$")
    if "/" in glob:
        return bool(expression.match(path))
    return bool(expression.match(path)) or bool(expression.match(os.path.basename(path)))


def resolve(path):
    resolved = {}
    for glob, properties in sections:
        if matches(glob, path):
            resolved.update(properties)
    return resolved


MATCHER_CASES = [
    ("*", "README.md", True),
    ("*", "docs/reflections/README.md", True),
    ("*.sh", "tests/test-harness.sh", True),
    ("*.sh", "tests/test-harness.shx", False),
    ("*.sh", "sh", False),
    ("*.{yml,yaml}", ".github/workflows/build.yml", True),
    ("*.{yml,yaml}", "renovate.json", False),
    ("ci/write-badges.sh", "ci/write-badges.sh", True),
    ("ci/write-badges.sh", "vendor/ci/write-badges.sh", False),
    ("ci/*.sh", "ci/write-badges.sh", True),
    ("ci/*.sh", "ci/nested/write-badges.sh", False),
    ("**/*.sh", "tests/lib/assert.sh", True),
    ("LICENSE", "LICENSE", True),
    ("LICENSE", "docs/LICENSE", True),
    ("Containerfile", "Containerfile", True),
    ("{tests/a.sh,tests/b.sh}", "tests/b.sh", True),
    ("{tests/a.sh,tests/b.sh}", "tests/c.sh", False),
]
matcher_failures = [
    "%s~%s" % (pattern, path)
    for pattern, path, expected in MATCHER_CASES
    if matches(pattern, path) is not expected
]

# --- measurements ----------------------------------------------------------

HEREDOC = re.compile(r"<<-?[ \t]*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")
SINGLE_BRACKET = re.compile(r"(?:^|[ \t]|&&|\|\||;|\()\[ ")


def shell_scan(text):
    """Indentation step, leading-tab lines and single-bracket tests, code only.

    Heredoc bodies are the fixtures the tests feed to the code under test. They
    are data in another language and are skipped; the line that opens the
    heredoc is still code and is measured.
    """
    steps = {}
    previous = 0
    delimiter = None
    tab_lines = 0
    single_brackets = 0
    for line in text.split("\n"):
        if delimiter is not None:
            if line.strip() == delimiter:
                delimiter = None
            continue
        opened = HEREDOC.search(line)
        stripped = line.strip()
        if stripped:
            if line.startswith("\t"):
                tab_lines += 1
            if not stripped.startswith("#") and SINGLE_BRACKET.search(line):
                single_brackets += 1
            indent = len(line) - len(line.lstrip(" "))
            if indent > previous:
                steps[indent - previous] = steps.get(indent - previous, 0) + 1
            previous = indent
        if opened is not None:
            delimiter = opened.group(2)
    step = 0
    if steps:
        step = min(steps, key=lambda size: (-steps[size], size))
    return step, tab_lines, single_brackets


def minimum_indent(text):
    smallest = 0
    for line in text.split("\n"):
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent > 0 and (smallest == 0 or indent < smallest):
            smallest = indent
    return smallest


HARD_BREAK = re.compile(r"\S  +$")

crlf = []
no_final_newline = []
not_utf8 = []
trailing_whitespace = []
trim_exempt = []
leading_tabs_outside_heredoc = []
markdown_hard_breaks = []
shell_steps = {}
shell_single_brackets = {}
indent_mismatch = []

for path in tracked:
    blob = open(os.path.join(repo_root, path), "rb").read()
    try:
        text = blob.decode("utf-8")
    except UnicodeDecodeError:
        not_utf8.append(path)
        continue
    rules = resolve(path)
    if b"\r" in blob:
        crlf.append(path)
    if blob and not blob.endswith(b"\n"):
        no_final_newline.append(path)
    if rules.get("trim_trailing_whitespace") == "true":
        if any(line != line.rstrip() for line in text.split("\n")):
            trailing_whitespace.append(path)
    else:
        trim_exempt.append(path)

    if path.endswith(".sh"):
        step, tab_lines, single_brackets = shell_scan(text)
        shell_steps[path] = step
        shell_single_brackets[path] = single_brackets
        if tab_lines:
            leading_tabs_outside_heredoc.append(path)
        declared = rules.get("indent_size", "")
        if step and declared != str(step):
            indent_mismatch.append("%s:%s!=%s" % (path, step, declared))
    else:
        if any(line.startswith("\t") for line in text.split("\n")):
            leading_tabs_outside_heredoc.append(path)

    if path.endswith(".md"):
        if any(HARD_BREAK.search(line) for line in text.split("\n")):
            markdown_hard_breaks.append(path)

    if path.endswith((".yml", ".yaml", ".json")) or path == "Containerfile":
        smallest = minimum_indent(text)
        declared = rules.get("indent_size", "")
        if smallest and declared != str(smallest):
            indent_mismatch.append("%s:%s!=%s" % (path, smallest, declared))

shipped_shell = sorted(
    path for path in shell_steps if not path.startswith("tests/")
)
two_space_measured = sorted(path for path, step in shell_steps.items() if step == 2)
two_space_declared = sorted(
    path
    for path in shell_steps
    if resolve(path).get("indent_size") == "2"
)
no_indent_shell = sorted(path for path, step in shell_steps.items() if step == 0)
single_bracket_shipped = sorted(
    path for path in shipped_shell if shell_single_brackets[path] > 0
)

# --- claims the comments make about the rest of the repository -------------

KNOWN_KEYS = {
    "charset",
    "end_of_line",
    "indent_size",
    "indent_style",
    "insert_final_newline",
    "trim_trailing_whitespace",
}
unknown_keys = sorted(
    {key for _, properties in sections for key in properties} - KNOWN_KEYS
)
dead_globs = sorted(
    glob for glob, _ in sections if not any(matches(glob, path) for path in tracked)
)

URL = re.compile(r"https?://\S+")
PATHISH = re.compile(r"(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_-]+\.[A-Za-z0-9]+|[A-Za-z0-9_.-]+/")
unresolved_paths = []
for comment in comments:
    for token in PATHISH.findall(URL.sub(" ", comment)):
        candidate = token.rstrip("/")
        if candidate in tracked or candidate in tracked_dirs:
            continue
        unresolved_paths.append(token)

prettier_config = sorted(
    path
    for path in tracked
    if os.path.basename(path).startswith(".prettierrc")
    or os.path.basename(path).startswith("prettier.config")
)
# An invocation, not a mention: .editorconfig argues the decision in prose and
# tests/README.md records it, so a bare word search finds the argument rather
# than the tool. What would make the argument false is prettier in command
# position, or listed as a dependency for something to install.
PRETTIER_INVOCATION = re.compile(
    r"(?:^[ \t]*|[;&|(]\s*|\brun:\s*|\b(?:npx|bunx|pnpm|yarn)\s+"
    r"|\bnpm\s+(?:run|exec)\s+)prettier\b",
    re.MULTILINE,
)
PRETTIER_DEPENDENCY = re.compile(r"\"prettier\"\s*:")
prettier_callers = []
for path in tracked:
    try:
        text = open(os.path.join(repo_root, path), encoding="utf-8").read()
    except (UnicodeDecodeError, OSError):
        continue
    if PRETTIER_INVOCATION.search(text) or PRETTIER_DEPENDENCY.search(text):
        prettier_callers.append(path)

shellcheck_installers = sorted(
    os.path.basename(path)
    for path in tracked
    if path.startswith(".github/workflows/")
    and "install -y shellcheck" in open(os.path.join(repo_root, path), encoding="utf-8").read()
)
suite_runners = sorted(
    os.path.basename(path)
    for path in tracked
    if path.startswith(".github/workflows/")
    and re.search(
        r"^\s*run:\s*\./tests/run-tests\.sh\s*$",
        open(os.path.join(repo_root, path), encoding="utf-8").read(),
        re.MULTILINE,
    )
)
shellcheckrc = open(os.path.join(repo_root, ".shellcheckrc"), encoding="utf-8").read()
shell_syntax_test = open(
    os.path.join(repo_root, "tests/test-shell-syntax.sh"), encoding="utf-8"
).read()


def emit(key, value):
    print("%s\t%s" % (key, value))


emit("root", preamble.get("root", ""))
emit("section-count", len(sections))
emit("section-globs", " ".join(glob for glob, _ in sections))
emit("dead-globs", " ".join(dead_globs))
emit("unknown-keys", " ".join(unknown_keys))
emit("matcher-failures", " ".join(matcher_failures))
emit("matcher-cases", len(MATCHER_CASES))

emit("tracked-count", len(tracked))
emit("declared-end-of-line", resolve("README.md").get("end_of_line", ""))
emit("declared-charset", resolve("README.md").get("charset", ""))
emit("declared-final-newline", resolve("README.md").get("insert_final_newline", ""))
emit("declared-indent-style", resolve("README.md").get("indent_style", ""))
emit("crlf", " ".join(crlf))
emit("no-final-newline", " ".join(no_final_newline))
emit("not-utf8", " ".join(not_utf8))
emit("trailing-whitespace", " ".join(trailing_whitespace))
emit(
    "trim-exempt-unexpected",
    " ".join(
        sorted(
            path
            for path in trim_exempt
            if not path.endswith(".md") and os.path.basename(path) != "LICENSE"
        )
    ),
)
emit(
    "trim-exempt-missing",
    " ".join(
        sorted(
            path
            for path in tracked
            if (path.endswith(".md") or os.path.basename(path) == "LICENSE")
            and path not in trim_exempt
        )
    ),
)
emit("markdown-hard-breaks", " ".join(markdown_hard_breaks))
emit("leading-tabs", " ".join(sorted(leading_tabs_outside_heredoc)))

emit("indent-mismatch", " ".join(sorted(indent_mismatch)))
emit("shell-count", len(shell_steps))
emit("shipped-shell", " ".join(shipped_shell))
emit("two-space-measured", " ".join(two_space_measured))
emit("two-space-declared", " ".join(two_space_declared))
emit("no-indent-shell", " ".join(no_indent_shell))
emit("single-bracket-shipped", " ".join(single_bracket_shipped))
emit("declared-sh-indent", resolve("tests/test-harness.sh").get("indent_size", ""))
emit("declared-yaml-indent", resolve(".github/workflows/build.yml").get("indent_size", ""))
emit("declared-json-indent", resolve("renovate.json").get("indent_size", ""))
emit("declared-md-indent", resolve("README.md").get("indent_size", ""))
emit("declared-md-trim", resolve("README.md").get("trim_trailing_whitespace", ""))
emit("declared-license-style", resolve("LICENSE").get("indent_style", ""))
emit("declared-license-trim", resolve("LICENSE").get("trim_trailing_whitespace", ""))
emit("declared-containerfile-indent", resolve("Containerfile").get("indent_size", ""))

emit("unresolved-comment-paths", " ".join(sorted(set(unresolved_paths))))
emit("prettier-config", " ".join(prettier_config))
emit("prettier-callers", " ".join(prettier_callers))
emit("shellcheck-installers", " ".join(shellcheck_installers))
emit("suite-runners", " ".join(suite_runners))
emit("shellcheckrc-names-write-badges", str("ci/write-badges.sh" in shellcheckrc).lower())
emit("shellcheckrc-double-bracket-note", str("require-double-brackets" in shellcheckrc).lower())
emit("shell-syntax-runs-shellcheck", str("shellcheck -x" in shell_syntax_test).lower())
PY
); then
    _pass "the tree can be measured against .editorconfig"
else
    _fail "the tree can be measured against .editorconfig" \
        "the analysis below could not run; nothing after this point was checked"
    finish
    exit
fi

# Looks one fact up by name. A missing name returns empty and a non-zero status,
# so a fact this test stops emitting fails an assertion rather than passing one
# with the empty string on both sides.
fact() {
    awk -F'\t' -v key="$1" '$1 == key { print $2; found = 1; exit } END { exit !found }' \
        <<<"${analysis}"
}

# A floor rather than an exact count: the tree grows, and a test that has to be
# edited every time a file is added stops being read and starts being updated.
# What these guard against is the measurement collapsing to nothing, which would
# make every "this list is empty" assertion below pass by checking no files.
assert_at_least() {
    local description=$1 floor=$2 actual=$3
    if [[ "${actual}" =~ ^[0-9]+$ ]] && [[ "${actual}" -ge "${floor}" ]]; then
        _pass "${description}"
    else
        _fail "${description}" "expected at least: ${floor}" "actual: ${actual}"
    fi
}

# =============================================================================
# The file itself
# =============================================================================
#
# `root = true` is what stops an .editorconfig further up the filesystem -- a
# developer's home directory, a parent checkout -- from contributing rules to
# this tree. Without it the settings below are a starting point rather than the
# whole answer, and the file's claim to encode *this* repository's conventions
# is only true on machines that happen to have nothing above it.

assert_eq "the file stops EditorConfig searching parent directories" "true" "$(fact root)"
assert_eq "every property it sets is one EditorConfig defines" "" "$(fact unknown-keys)"
assert_eq "no section glob matches nothing in the tree" "" "$(fact dead-globs)"

# =============================================================================
# The matcher this test resolves rules with
# =============================================================================
#
# EditorConfig resolves a file's settings by applying every matching section in
# order, last one wins, and its glob syntax is not fnmatch: a pattern without a
# separator matches at any depth, `**` crosses separators, and `{a,b}` is an
# alternation. Everything below depends on that being implemented correctly, so
# it is checked against a table first -- a matcher that returned True for
# everything would otherwise make each assertion that follows trivially pass.

assert_eq "the glob matcher agrees with its case table" "" "$(fact matcher-failures)"
assert_eq "the case table covers every glob form the file uses" "17" "$(fact matcher-cases)"

# =============================================================================
# [*]: the rules that apply to every tracked file
# =============================================================================

assert_eq "line endings are declared LF" "lf" "$(fact declared-end-of-line)"
assert_eq "no tracked file contains a carriage return" "" "$(fact crlf)"

assert_eq "a final newline is declared" "true" "$(fact declared-final-newline)"
assert_eq "every tracked file ends with a newline" "" "$(fact no-final-newline)"

assert_eq "the charset is declared UTF-8" "utf-8" "$(fact declared-charset)"
assert_eq "every tracked file decodes as UTF-8" "" "$(fact not-utf8)"

assert_eq "indentation is declared to be spaces" "space" "$(fact declared-indent-style)"
assert_eq "no file indents a line of its own code with a tab" "" "$(fact leading-tabs)"

assert_at_least "the measurement covered the whole tree" "80" "$(fact tracked-count)"

# =============================================================================
# trim_trailing_whitespace: on everywhere except where the file says otherwise
# =============================================================================
#
# Two exemptions are declared, and each is a decision rather than an oversight.
# Markdown gives two trailing spaces a meaning (a hard line break) and LICENSE
# is a verbatim third-party text that nothing here is entitled to reflow. The
# exempt set is asserted exactly: adding a file type to it is then a visible
# change rather than a silent one.

assert_eq "trailing whitespace is trimmed everywhere it is not exempted" \
    "" "$(fact trailing-whitespace)"
assert_eq "nothing outside Markdown and LICENSE is exempt from trimming" \
    "" "$(fact trim-exempt-unexpected)"
assert_eq "every Markdown file and LICENSE is exempt" "" "$(fact trim-exempt-missing)"
assert_eq "Markdown is exempt from trimming" "false" "$(fact declared-md-trim)"
assert_eq "LICENSE is exempt from trimming" "false" "$(fact declared-license-trim)"
assert_eq "LICENSE's indentation is left unset rather than declared" \
    "unset" "$(fact declared-license-style)"

# The Markdown exemption's comment states the ground it stands on -- "This repo
# does not use them" -- which is a claim about the tree, not a preference. If a
# hard line break ever lands, the comment is wrong and the exemption becomes
# load bearing rather than precautionary; either way the reader should be told.
assert_eq "no Markdown file uses a two-space hard line break today" \
    "" "$(fact markdown-hard-breaks)"

# =============================================================================
# indent_size, measured against every file type the config names
# =============================================================================

assert_eq "shell is declared four-space" "4" "$(fact declared-sh-indent)"
assert_eq "YAML is declared two-space" "2" "$(fact declared-yaml-indent)"
assert_eq "JSON is declared two-space" "2" "$(fact declared-json-indent)"
assert_eq "Markdown is declared two-space" "2" "$(fact declared-md-indent)"
assert_eq "the Containerfile is declared four-space" "4" "$(fact declared-containerfile-indent)"

assert_eq "every shell, YAML, JSON and Containerfile indents as declared" \
    "" "$(fact indent-mismatch)"
assert_at_least "every shell script in the tree was measured" "30" "$(fact shell-count)"

# build_files/build.sh is measured at zero because it has no indented line at
# all -- it is a flat sequence of commands. Asserting that explicitly keeps it
# from being read as "unmeasurable", which is how a file silently drops out of
# the check above.
assert_eq "the only unindented shell script is build_files/build.sh" \
    "build_files/build.sh" "$(fact no-indent-shell)"

# The two-space exceptions, both directions. Declaring a file two-space that is
# not, or leaving a two-space file undeclared, fails here -- which is what makes
# this the assertion that catches the next one to arrive.
assert_eq "the two-space shell scripts are exactly the ones declared two-space" \
    "$(fact two-space-measured)" "$(fact two-space-declared)"
assert_eq "and they are ci/write-badges.sh and the settings hook" \
    ".claude/hooks/gate-git-diff.sh ci/write-badges.sh" "$(fact two-space-measured)"

# =============================================================================
# The single-bracket note, joined to .shellcheckrc
# =============================================================================
#
# .editorconfig says ci/write-badges.sh uses single brackets; .shellcheckrc says
# the same thing from the other side, as its reason for leaving
# require-double-brackets off. Neither file mentions the other, so the two
# notes can drift apart without anything failing. They describe one fact about
# one file, and that fact is measurable.

assert_eq "ci/write-badges.sh is the only shipped script using single brackets" \
    "ci/write-badges.sh" "$(fact single-bracket-shipped)"
assert_eq ".shellcheckrc names the same file" "true" \
    "$(fact shellcheckrc-names-write-badges)"
assert_eq ".shellcheckrc still records why double brackets are not required" \
    "true" "$(fact shellcheckrc-double-bracket-note)"
assert_eq "the shipped scripts are the six outside tests/" \
    ".claude/hooks/gate-git-diff.sh build_files/build.sh build_files/kernel-akmods.sh build_files/post-check.sh build_files/zfs.sh ci/write-badges.sh" \
    "$(fact shipped-shell)"

# =============================================================================
# The header note: no Prettier, shellcheck instead
# =============================================================================
#
# The note argues against adding a Prettier config on the grounds that nothing
# runs one and its first run would rewrite AGENTS.md and README.md. Its premise
# -- that no Prettier config exists and nothing invokes prettier -- is the half
# that can rot without anyone noticing, so it is the half asserted here. The
# "seven files" count in the note is not reproduced: prettier is not a
# dependency of this repository and installing one to check a comment would
# make the suite depend on the tool the comment exists to keep out.

assert_eq "no Prettier configuration is tracked" "" "$(fact prettier-config)"
assert_eq "nothing in the tree invokes prettier" "" "$(fact prettier-callers)"

# "Shell style is enforced by .shellcheckrc, which CI actually runs" is the
# note's alternative, and it is only true while the suite reaches CI with the
# tool installed. tests/test-shell-syntax.sh skips its shellcheck pass when the
# binary is absent, so a workflow that runs the suite without installing the
# tool first enforces nothing and stays green.
assert_file_exists ".shellcheckrc is tracked" "${REPO_ROOT}/.shellcheckrc"
assert_eq "tests/test-shell-syntax.sh is what runs shellcheck" "true" \
    "$(fact shell-syntax-runs-shellcheck)"
assert_eq "every workflow that runs the suite installs shellcheck first" \
    "$(fact suite-runners)" "$(fact shellcheck-installers)"
assert_eq "and those workflows are the three that gate a change" \
    "build.yml coverage-gate.yml nightly-compliance.yml" "$(fact suite-runners)"

# =============================================================================
# Paths named in the comments
# =============================================================================
#
# Every file .editorconfig names in prose is a file it makes a claim about. A
# rename that misses the comment leaves the claim pointing at nothing, and a
# comment is the one part of a config file no tool validates.

assert_eq "every path named in a comment still exists" "" \
    "$(fact unresolved-comment-paths)"

finish
