#!/usr/bin/env bash
#
# Joins CONTRIBUTING.md to the machine it describes.
#
# CONTRIBUTING.md is the page a human contributor reads before touching this
# repository. Several tests read it as a *source* -- test-copilot-instructions.sh
# its two-space indentation exceptions and the tests/lib/ exemption,
# test-risk-tiers.sh its conversation-first section -- and none read the rest of
# it as a *subject*. Two of its claims were false, one of them from the day the
# page was written:
#
#   * "The `check_*` functions themselves are still only exercised by a real
#     build." bcd4a6b added tests/test-post-check-checks.sh, which runs
#     check_kernel_tree and check_zfs_packages against stubbed rpm and find, on
#     2026-09-03 at 08:15; the page was added at 11:58 the same day.
#   * "`set -uo pipefail` in the test runner" named one exception to the
#     `set -euo pipefail` rule. Every tests/test-*.sh and
#     .claude/hooks/gate-git-diff.sh use `set -uo pipefail` too -- thirty-eight
#     files the rule, read as written, calls wrong.
#
# What is checked here, recomputed from the tree rather than restated:
#
#   * the badge paragraph: the number of upstream akmods images the
#     Containerfile pulls, and that ci/write-badges.sh reads `ostree.linux`;
#   * the two runner commands against tests/run-tests.sh's own usage lines, and
#     the tool list against the runner's `for tool in ...` check, both ways;
#   * the PyYAML packages, the WORKFLOW_PYTHON default and CI's interpreter
#     against the tests and the `Shell tests` job;
#   * the shellcheck paragraph against test-shell-syntax.sh: skipped when the
#     tool is absent, `shellcheck -x`, zero output required, and installed by
#     the same CI job that runs the suite;
#   * "What the tests cannot reach": the named build scripts against
#     build_files/ both ways, the quoted guard against post-check.sh verbatim,
#     the stubbed tools against test-post-check.sh, and the reached `check_*`
#     stages against test-post-check-checks.sh both ways, with the "Two of the
#     seven" / "other five" count words;
#   * the PR build: the workflow name, post-check.sh and `bootc container lint`
#     in the Containerfile, and every publishing or signing step gated off pull
#     requests;
#   * the CI gotcha's `paths-ignore` list against build.yml's pull_request
#     trigger, both ways;
#   * the `set` rule against every tracked shell script's first `set` line,
#     with the exceptions the page names and only those;
#   * the tests/lib/ exemption from shebang and executable bit;
#   * the ai-fix.yml paragraph: the label, the `@claude` comment, the two
#     triggers and nothing from the review-thread family, and the bot refusal;
#   * "no package manager and no `node_modules`" against the tracked files.

# Most of what this file matches is shell source and Markdown code spans,
# which have to reach the matcher unexpanded, so the single quotes are the
# point and SC2016 is off for the file rather than repeated above each.
# shellcheck disable=SC2016

set -uo pipefail

TEST_NAME="test-contributing"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

# Sets of paths and globs travel here as space-separated words, and the page's
# `tests/test-*.sh` has to stay a pattern rather than expand against the tree.
set -f

DOC="${REPO_ROOT}/CONTRIBUTING.md"
CONTAINERFILE="${REPO_ROOT}/Containerfile"
BUILD_YML="${REPO_ROOT}/.github/workflows/build.yml"
AI_FIX_YML="${REPO_ROOT}/.github/workflows/ai-fix.yml"
RUNNER="${REPO_ROOT}/tests/run-tests.sh"
SHELL_SYNTAX="${REPO_ROOT}/tests/test-shell-syntax.sh"
POST_CHECK="${REPO_ROOT}/build_files/post-check.sh"
POST_CHECK_TEST="${REPO_ROOT}/tests/test-post-check.sh"
POST_CHECK_CHECKS="${REPO_ROOT}/tests/test-post-check-checks.sh"
WRITE_BADGES="${REPO_ROOT}/ci/write-badges.sh"

missing=0
for required in "${DOC}" "${CONTAINERFILE}" "${BUILD_YML}" "${AI_FIX_YML}" \
    "${RUNNER}" "${SHELL_SYNTAX}" "${POST_CHECK}" "${POST_CHECK_TEST}" \
    "${POST_CHECK_CHECKS}" "${WRITE_BADGES}"; do
    if [[ -f "${required}" ]]; then
        _pass "${required#"${REPO_ROOT}"/} is present"
    else
        _fail "${required#"${REPO_ROOT}"/} is present" "no such file"
        missing=1
    fi
done
if [[ "${missing}" -ne 0 ]]; then
    finish
    exit 1
fi

# The workflow facts come out of YAML, parsed the way the other workflow tests
# parse it. A missing parser fails, as CONTRIBUTING.md says it does.
WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"
if ! "${WORKFLOW_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    _fail "PyYAML is importable" \
        "install python3-yaml, or set WORKFLOW_PYTHON to an interpreter that has it"
    finish
    exit 1
fi

# --- helpers ------------------------------------------------------------------

# The body of a `## ` section of $2, up to the next `## `.
section_body() {
    awk -v want="$1" '
        $0 == want { inside = 1; next }
        inside && /^## / { exit }
        inside
    ' "$2"
}

# Prose outside fenced blocks, on one line, whitespace squashed. Markdown
# wraps, so a sentence worth anchoring is usually split across lines.
flatten() {
    awk '/^[ \t]*```/ { fenced = !fenced; next } !fenced' |
        tr '\n' ' ' | tr -s '[:space:]' ' '
}

# The contents of every fenced block in the text on stdin.
fenced_lines() {
    awk '/^[ \t]*```/ { fenced = !fenced; next } fenced'
}

# Every code span in the text on stdin, one per line.
code_spans() {
    grep -oE '`[^`]+`' | tr -d '`'
}

# Sorted, de-duplicated, space-joined words from stdin.
word_set() {
    LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'
}

# The Markdown bullet (first line plus indented continuations, squashed) in the
# text on stdin whose text starts with $1.
bullet() {
    awk -v lead="$1" '
        /^- / {
            if (keep) exit
            keep = (index(substr($0, 3), lead) == 1)
            if (keep) item = substr($0, 3)
            next
        }
        keep && /^[ \t]+[^ \t]/ { sub(/^[ \t]+/, ""); item = item " " $0; next }
        keep { exit }
        END { if (keep) print item }
    ' | sed -E 's/[[:space:]]+/ /g; s/ $//'
}

# A number word, as the page writes counts.
number_word() {
    local words=(zero one two three four five six seven eight nine ten)
    printf '%s' "${words[$1]:-$1}"
}

# Run a Python snippet against a workflow file; the snippet sees `wf`.
workflow_query() {
    "${WORKFLOW_PYTHON}" -B - "$1" <<PY
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
on = wf.get("on", wf.get(True))
${2}
PY
}

# --- 0. the helpers against fixtures ------------------------------------------

fixture_bullets=$'- `set -euo` at the top; the runner\n  keeps going.\n- Four-space\n  indentation.\nafter'
assert_eq "bullet() folds a wrapped bullet's continuation lines in" \
    '`set -euo` at the top; the runner keeps going.' \
    "$(bullet '`set -euo`' <<<"${fixture_bullets}")"
assert_eq "bullet() stops at the next bullet" \
    'Four-space indentation.' "$(bullet 'Four-space' <<<"${fixture_bullets}")"
assert_eq "flatten() joins wrapped lines and skips fences" \
    'a b c ' "$(printf 'a\nb\n```\nfenced\n```\nc\n' | flatten)"

# --- 1. "Before you start": the badge paragraph -------------------------------

before=$(section_body "## Before you start: is it actually broken?" "${DOC}" | flatten)
if [[ -n "${before}" ]]; then
    _pass "the page has its 'Before you start' section"
else
    _fail "the page has its 'Before you start' section" "heading renamed or removed"
fi

akmods_from=$(grep -cE '^FROM [^ ]*/akmods(-[a-z]+)?:' "${CONTAINERFILE}")
if [[ "${before}" =~ the\ ([a-z]+)\ upstream\ akmods\ images ]]; then
    assert_eq "'the N upstream akmods images' counts the Containerfile's akmods FROM lines" \
        "$(number_word "${akmods_from}")" "${BASH_REMATCH[1]}"
else
    _fail "the badge paragraph counts the upstream akmods images" "sentence reworded"
fi
assert_contains "the badge paragraph names the label it reads" "${before}" '`ostree.linux` label'
assert_contains "ci/write-badges.sh does read that label" \
    "$(grep -v '^[[:space:]]*#' "${WRITE_BADGES}")" '.Labels["ostree.linux"]'
assert_contains "the page names the badge by its README alt text" "${before}" '**OpenZFS/kernel**'
assert_contains "README.md does carry that badge" \
    "$(cat "${REPO_ROOT}/README.md")" '[![OpenZFS/kernel status]'

# --- 2. "Running the tests" ---------------------------------------------------

running_raw=$(section_body "## Running the tests" "${DOC}")
running=$(flatten <<<"${running_raw}")

# The two commands, against the runner's own usage lines: same invocations,
# and the one-file example names a test that exists.
doc_commands=$(fenced_lines <<<"${running_raw}" | sed -E 's/[[:space:]]*#.*$//' | sed '/^$/d')
runner_usage=$(grep -E '^#[[:space:]]+\./tests/run-tests\.sh' "${RUNNER}" |
    sed -E 's/^#[[:space:]]+//; s/[[:space:]]+#.*$//; s/[[:space:]]+$//')
assert_eq "the page shows two runner commands" "2" "$(grep -c . <<<"${doc_commands}")"
assert_eq "they are the runner's own usage lines" \
    "$(LC_ALL=C sort <<<"${runner_usage}")" "$(LC_ALL=C sort <<<"${doc_commands}")"
one_file=$(awk 'NF == 2 { print $2 }' <<<"${doc_commands}")
if [[ -n "${one_file}" && -f "${REPO_ROOT}/tests/${one_file}.sh" ]]; then
    _pass "the one-file example names a real test: ${one_file}"
else
    _fail "the one-file example names a real test" "no tests/${one_file}.sh"
fi

# The tool list, both ways against the runner's preflight loop.
if [[ "${running}" =~ The\ suite\ needs\ ([^.]+)\. ]]; then
    needs=${BASH_REMATCH[1]}
    assert_contains "the list ends with Python 3 and PyYAML" "${needs}" "Python 3 with PyYAML"
    doc_tools=$(
        {
            [[ "${needs}" =~ (^|[^a-z])bash\ [0-9] ]] && echo bash
            code_spans <<<"${needs}"
        } | word_set
    )
else
    _fail "the page states what the suite needs" "sentence reworded"
    doc_tools=""
fi
runner_tools=$(sed -nE 's/^for tool in (.*); do$/\1/p' "${RUNNER}" | tr ' ' '\n' | sed '/^$/d' | word_set)
if [[ -n "${runner_tools}" ]]; then
    _pass "the runner checks for its tools up front"
else
    _fail "the runner checks for its tools up front" "no 'for tool in ...; do' line"
fi
assert_eq "the page names exactly the tools the runner requires" "${runner_tools}" "${doc_tools}"
assert_contains "the runner's own requirements line agrees on bash 4+" \
    "$(grep -E '^# Requirements:' "${RUNNER}")" 'bash 4+, jq, coreutils date, sed'

# PyYAML: the Debian package the page names is the one CI installs.
tests_steps=$(workflow_query "${BUILD_YML}" '
for step in wf["jobs"]["tests"]["steps"]:
    print("STEP\t%s\t%s\t%s" % (step.get("name", ""), (step.get("run") or "").replace("\n", " ; "),
                                (step.get("env") or {}).get("WORKFLOW_PYTHON", "")))
')
install_step=$(awk -F'\t' '$3 ~ /apt-get install/' <<<"${tests_steps}")
suite_step=$(awk -F'\t' '$3 ~ /\.\/tests\/run-tests\.sh/' <<<"${tests_steps}")
apt_package=$(grep -oE 'sudo apt-get install [a-z0-9-]+' <<<"${running}" | awk '{print $4}')
assert_eq "the page's apt package for PyYAML" "python3-yaml" "${apt_package}"
assert_contains "the Shell tests job installs that package" "${install_step}" "${apt_package:-<none>}"
assert_contains "the page names Fedora's package too" "${running}" '`sudo dnf install python3-pyyaml`'

# WORKFLOW_PYTHON: "uses `python3` by default", and CI pins /usr/bin/python3.
# This file excluded: the sed below spells the variable too.
defaults=$(grep -rhoE 'WORKFLOW_PYTHON:-[^}]*' "${REPO_ROOT}/tests" --include='test-*.sh' \
    --exclude="${TEST_NAME}.sh" |
    sed 's/WORKFLOW_PYTHON:-//' | word_set)
assert_contains "the page says WORKFLOW_PYTHON defaults to python3" \
    "${running}" 'uses `python3` by default; set `WORKFLOW_PYTHON`'
assert_eq "every test that reads WORKFLOW_PYTHON defaults it to python3" "python3" "${defaults}"
ci_python=$(awk -F'\t' '{print $4}' <<<"${suite_step}")
assert_contains "the page names CI's interpreter" "${running}" "uses \`${ci_python:-<none>}\`"
assert_eq "CI runs the suite with /usr/bin/python3" "/usr/bin/python3" "${ci_python}"
assert_contains "the page says a missing parser fails the suite" "${running}" "A missing parser fails the suite."

# The shellcheck pass: skipped when absent, enforced in CI, zero output, -x.
syntax_code=$(grep -v '^[[:space:]]*#' "${SHELL_SYNTAX}")
assert_contains "the page says test-shell-syntax.sh skips shellcheck when it is absent" \
    "${running}" '`test-shell-syntax.sh` skips its shellcheck pass when the tool is absent'
assert_contains "test-shell-syntax.sh guards the pass on the tool being present" \
    "${syntax_code}" 'if command -v shellcheck'
assert_contains "and prints a skip line otherwise" "${syntax_code}" "skip shellcheck (not installed)"
assert_contains "the page's bar is zero output from shellcheck -x" "${running}" \
    'The bar is *zero output* from `shellcheck -x`'
assert_contains "test-shell-syntax.sh runs shellcheck -x" "${syntax_code}" 'shellcheck -x "${rel}"'
assert_contains "and requires its output to be empty" "${syntax_code}" \
    'assert_eq "shellcheck is clean for ${rel}" "" "${output}"'
if grep -qE 'shellcheck[^|]*(-S|--severity)' <<<"${syntax_code}" ||
    grep -qE '^[[:space:]]*severity' "${REPO_ROOT}/.shellcheckrc" 2>/dev/null; then
    _fail "no severity filter hides informational findings" "a -S/--severity or severity= is set"
else
    _pass "no severity filter hides informational findings"
fi
# From the install command itself: the step also runs `shellcheck --version`,
# which would satisfy a search of the whole step.
apt_install=$(grep -oE 'apt-get install [^;]*' <<<"${install_step}")
assert_contains "the Shell tests job installs shellcheck" " ${apt_install} " " shellcheck "
install_line=$(grep -n $'\t' <<<"${tests_steps}" | awk -F'\t' '$3 ~ /apt-get install/ {print $1}' | cut -d: -f1)
suite_line=$(grep -n $'\t' <<<"${tests_steps}" | awk -F'\t' '$3 ~ /run-tests\.sh/ {print $1}' | cut -d: -f1)
if [[ -n "${install_line}" && -n "${suite_line}" && "${install_line}" -lt "${suite_line}" ]]; then
    _pass "shellcheck is installed before the suite runs, in the same job"
else
    _fail "shellcheck is installed before the suite runs, in the same job" \
        "install step ${install_line:-none}, suite step ${suite_line:-none}"
fi
assert_contains "the page points at the directive, with a reason" "${running}" \
    'silence it with a `# shellcheck disable=SCxxxx` directive and a comment'

# --- 3. "What the tests cannot reach" -----------------------------------------

reach_raw=$(section_body "## What the tests cannot reach" "${DOC}")
reach=$(flatten <<<"${reach_raw}")
first_paragraph=$(awk 'NF == 0 && seen { exit } NF { seen = 1; print }' <<<"${reach_raw}" | flatten)

# The named scripts, both ways against build_files/ minus the exception.
named_unreachable=$(code_spans <<<"${first_paragraph}" | grep -v '^Containerfile$' | word_set)
tree_unreachable=$(git -C "${REPO_ROOT}" ls-files 'build_files/*.sh' |
    grep -vx 'build_files/post-check.sh' | word_set)
assert_eq "the unreachable list is every build_files script but post-check.sh" \
    "${tree_unreachable}" "${named_unreachable}"
assert_contains "and the Containerfile" "${first_paragraph}" '`Containerfile` run inside an image build'
assert_contains "post-check.sh is named as the exception" "${reach}" \
    '`build_files/post-check.sh` is the exception'

# The guard, verbatim, as consecutive lines of post-check.sh.
guard=$(fenced_lines <<<"${reach_raw}")
if [[ -n "${guard}" && "$(cat "${POST_CHECK}")" == *"${guard}"* ]]; then
    _pass "the quoted entry-point guard is post-check.sh's, verbatim"
else
    _fail "the quoted entry-point guard is post-check.sh's, verbatim" "quoted: ${guard}"
fi

# The stubbed tools against test-post-check.sh's stub_command calls.
if [[ "${reach}" =~ \`test-post-check\.sh\`\ calls\ them\ directly\ with\ ([^.]+)\ stubbed ]]; then
    doc_stubs=$(code_spans <<<"${BASH_REMATCH[1]}" | word_set)
else
    _fail "the page says what test-post-check.sh stubs" "sentence reworded"
    doc_stubs=""
fi
test_stubs=$(grep -v '^[[:space:]]*#' "${POST_CHECK_TEST}" |
    grep -oE '(^|[[:space:]])stub_command [a-z]+' | awk '{print $2}' | word_set)
assert_eq "the stubbed tools are the ones test-post-check.sh stubs" "${test_stubs}" "${doc_stubs}"

# The reached check_* stages, both ways against test-post-check-checks.sh.
defined_checks=$(grep -oE '^check_[a-z_]+\(\)' "${POST_CHECK}" | tr -d '()' | word_set)
run_checks=$(grep -v '^[[:space:]]*#' "${POST_CHECK_CHECKS}" |
    grep -oE '(^|[[:space:]])run_check check_[a-z_]+' | awk '{print $2}' | word_set)
if [[ "${reach}" =~ \`test-post-check-checks\.sh\`\ runs\ ([^.]+)\ against ]]; then
    doc_checks=$(code_spans <<<"${BASH_REMATCH[1]}" | word_set)
else
    _fail "the page names the check_* stages test-post-check-checks.sh runs" \
        "no '\`test-post-check-checks.sh\` runs ... against' sentence"
    doc_checks=""
fi
assert_eq "the reached stages are the ones test-post-check-checks.sh runs" "${run_checks}" "${doc_checks}"
for check in ${run_checks}; do
    if [[ " ${defined_checks} " == *" ${check} "* ]]; then
        _pass "${check} is a stage post-check.sh defines"
    else
        _fail "${check} is a stage post-check.sh defines" "not in: ${defined_checks}"
    fi
done
n_defined=$(wc -w <<<"${defined_checks}")
n_run=$(wc -w <<<"${run_checks}")
if [[ "${reach}" =~ ([A-Z][a-z]+)\ of\ the\ ([a-z]+)\ \`check_\*\`\ stages\ are\ reached ]]; then
    assert_eq "'N of the M' names how many stages are reached" \
        "$(number_word "${n_run}")" "${BASH_REMATCH[1],,}"
    assert_eq "'N of the M' names how many stages post-check.sh has" \
        "$(number_word "${n_defined}")" "${BASH_REMATCH[2]}"
else
    _fail "the page counts the reached check_* stages" "no 'N of the M \`check_*\` stages are reached'"
fi
if [[ "${reach}" =~ The\ other\ ([a-z]+)\ read ]]; then
    assert_eq "'the other N' is the stages left to a real build" \
        "$(number_word $((n_defined - n_run)))" "${BASH_REMATCH[1]}"
else
    _fail "the page counts the stages left to a real build" "no 'The other N read' sentence"
fi
assert_not_contains "the page no longer says every check_* function needs a real build" \
    "${reach}" 'The `check_*` functions themselves are still only exercised by a real build'

# The PR build: its name, what the Containerfile runs, and that it publishes
# and signs nothing.
workflow_name=$(workflow_query "${BUILD_YML}" 'print(wf["name"])')
assert_contains "the page names the build workflow as build.yml names it" \
    "${reach}" "A green \`${workflow_name}\` run on the PR"
assert_eq "build.yml runs on pull requests" "yes" \
    "$(workflow_query "${BUILD_YML}" 'print("yes" if "pull_request" in on else "no")')"
container_runs=$(grep -E '^[[:space:]]*(RUN|/ctx/)' "${CONTAINERFILE}")
assert_contains "the Containerfile runs post-check.sh" "${container_runs}" "/ctx/post-check.sh"
assert_contains "and bootc container lint" "${container_runs}" "RUN bootc container lint"
assert_contains "the page says both run inside the build" "${reach}" \
    'runs `post-check.sh` and `bootc container lint` inside it, and publishes and signs nothing'
ungated=$(workflow_query "${BUILD_YML}" '
publishing = ("docker/login-action", "push-to-registry", "cosign", "skopeo copy", "podman push")
for job in wf["jobs"].values():
    for step in job.get("steps", []):
        text = "%s %s" % (step.get("uses", ""), step.get("run", ""))
        if any(word in text for word in publishing):
            cond = step.get("if", "")
            if "github.event_name != '"'"'pull_request'"'"'" not in cond:
                print(step.get("name", "?"))
')
publishing_steps=$(workflow_query "${BUILD_YML}" '
publishing = ("docker/login-action", "push-to-registry", "cosign", "skopeo copy", "podman push")
print(sum(1 for job in wf["jobs"].values() for step in job.get("steps", [])
          if any(w in "%s %s" % (step.get("uses", ""), step.get("run", "")) for w in publishing)))
')
if [[ "${publishing_steps}" -ge 1 ]]; then
    _pass "build.yml has publishing and signing steps to check (${publishing_steps})"
else
    _fail "build.yml has publishing and signing steps to check" "found none"
fi
assert_eq "every publishing or signing step is skipped on a pull request" "" "${ungated}"

# --- 4. "One gotcha about CI" -------------------------------------------------

gotcha=$(section_body "## One gotcha about CI" "${DOC}" | flatten)
gotcha_re='sets `paths-ignore` for ((`[^`]+`(, and |, | and )?)+)'
if [[ "${gotcha}" =~ ${gotcha_re} ]]; then
    doc_ignored=$(code_spans <<<"${BASH_REMATCH[1]}" | word_set)
else
    _fail "the gotcha names the ignored paths" "sentence reworded"
    doc_ignored=""
fi
pr_ignored=$(workflow_query "${BUILD_YML}" '
for path in (on.get("pull_request") or {}).get("paths-ignore", []):
    print(path)
' | word_set)
assert_eq "the ignored paths are build.yml's pull_request paths-ignore" "${pr_ignored}" "${doc_ignored}"
assert_contains "the gotcha is about build.yml" "${gotcha}" '`build.yml` sets `paths-ignore`'
assert_eq "the Shell tests job lives in that workflow" "Shell tests" \
    "$(workflow_query "${BUILD_YML}" 'print(wf["jobs"]["tests"]["name"])')"

# --- 5. "Style": the set rule, the tests/lib exemption -------------------------

style=$(section_body "## Style" "${DOC}")
set_rule=$(bullet '`set -euo pipefail`' <<<"${style}")
if [[ -n "${set_rule}" ]]; then
    _pass "the Style section states the set rule"
else
    _fail "the Style section states the set rule" "no bullet starting with \`set -euo pipefail\`"
fi

# The exceptions the page names: everything backticked after `set -uo pipefail`
# that is a path or glob, plus "the test runner".
uo_clause=${set_rule#*'`set -uo pipefail`'}
declared_uo=$(
    {
        [[ "${uo_clause}" == *"the test runner"* ]] && echo "tests/run-tests.sh"
        code_spans <<<"${uo_clause}" | grep '/'
    } | word_set
)
assert_contains "the uo exceptions include the runner" " ${declared_uo} " " tests/run-tests.sh "

# Classify every tracked shell script by the flags of its first `set` line.
declare -A flags_of=()
while IFS= read -r rel; do
    [[ -f "${REPO_ROOT}/${rel}" ]] || continue
    first=$(head -1 "${REPO_ROOT}/${rel}")
    [[ "${first}" == '#!'*sh* ]] || continue
    line=$(grep -m1 -E '^[[:space:]]*set -[a-z]+' "${REPO_ROOT}/${rel}")
    letters=$(sed -nE 's/^[[:space:]]*set -([a-z]+).*/\1/p' <<<"${line}" | grep -o . | LC_ALL=C sort | tr -d '\n')
    [[ "${line}" == *pipefail* ]] && letters+="+pipefail"
    flags_of["${rel}"]=${letters:-none}
done < <(git -C "${REPO_ROOT}" ls-files)

matches_declared_uo() {
    local rel=$1 pattern
    for pattern in ${declared_uo}; do
        # shellcheck disable=SC2053 # the pattern is a glob on purpose
        [[ "${rel}" == ${pattern} ]] && return 0
    done
    return 1
}

uo_files="" euo_files="" x_files="" wrong=""
for rel in "${!flags_of[@]}"; do
    case "${flags_of[${rel}]}" in
        ou+pipefail) uo_files+="${rel} " ;;
        eou+pipefail) euo_files+="${rel} " ;;
        eoux+pipefail) euo_files+="${rel} " x_files+="${rel} " ;;
        *) wrong+="${rel}(${flags_of[${rel}]}) " ;;
    esac
done
assert_eq "every shell script uses set -euo pipefail or set -uo pipefail" "" "${wrong}"
if [[ -n "${uo_files}" && -n "${euo_files}" ]]; then
    _pass "both halves of the rule have scripts in them"
else
    _fail "both halves of the rule have scripts in them" "uo: ${uo_files:-none}" "euo: ${euo_files:-none}"
fi

undeclared=""
for rel in ${uo_files}; do
    matches_declared_uo "${rel}" || undeclared+="${rel} "
done
assert_eq "every script without -e is one the page names as an exception" "" "${undeclared}"

misdeclared=""
for rel in ${euo_files}; do
    matches_declared_uo "${rel}" && misdeclared+="${rel} "
done
assert_eq "no script the page names as an exception uses -e" "" "${misdeclared}"

for pattern in ${declared_uo}; do
    hit=""
    for rel in ${uo_files}; do
        # shellcheck disable=SC2053 # the pattern is a glob on purpose
        [[ "${rel}" == ${pattern} ]] && { hit=1; break; }
    done
    if [[ -n "${hit}" ]]; then
        _pass "the named exception ${pattern} matches a script that uses set -uo"
    else
        _fail "the named exception ${pattern} matches a script that uses set -uo" "matches none"
    fi
done

# "the three build scripts add `x`"
x_set=$(tr ' ' '\n' <<<"${x_files}" | sed '/^$/d' | word_set)
build_scripts=$(git -C "${REPO_ROOT}" ls-files 'build_files/*.sh' |
    grep -vx 'build_files/post-check.sh' | word_set)
if [[ "${set_rule}" =~ the\ ([a-z]+)\ build\ scripts\ add\ \`x\` ]]; then
    assert_eq "'the N build scripts' counts the scripts that add x" \
        "$(number_word "$(wc -w <<<"${x_set}")")" "${BASH_REMATCH[1]}"
else
    _fail "the set rule says which scripts add x" "no 'the N build scripts add \`x\`'"
fi
assert_eq "the scripts that add x are the build scripts" "${build_scripts}" "${x_set}"

# tests/lib/: no shebang, no executable bit.
lib_rule=$(bullet 'Shebang and executable bit' <<<"${style}")
assert_contains "the page exempts tests/lib/ from shebang and executable bit" \
    "${lib_rule}" 'The exception is `tests/lib/`, which is only ever sourced and deliberately carries neither.'
lib_bad=""
while read -r mode _ _ path; do
    [[ "${mode}" == 100755 ]] && lib_bad+="${path}(executable) "
    [[ "$(head -c2 "${REPO_ROOT}/${path}")" == '#!' ]] && lib_bad+="${path}(shebang) "
done < <(git -C "${REPO_ROOT}" ls-files -s tests/lib)
assert_eq "no tests/lib/ file has a shebang or the executable bit" "" "${lib_bad}"

# --- 6. "Pull requests": the ai-fix.yml paragraph -----------------------------

prs=$(section_body "## Pull requests" "${DOC}" | flatten)
if [[ "${prs}" =~ comment\ \`([^\`]+)\`\ on\ the\ pull\ request,\ or\ label\ an\ issue\ \`([^\`]+)\` ]]; then
    doc_mention=${BASH_REMATCH[1]}
    doc_label=${BASH_REMATCH[2]}
else
    _fail "the page names the mention and the label that start ai-fix.yml" "sentence reworded"
    doc_mention="" doc_label=""
fi
triggers=$(workflow_query "${AI_FIX_YML}" '
for event, spec in on.items():
    print("%s:%s" % (event, ",".join((spec or {}).get("types", []))))
' | word_set)
assert_eq "ai-fix.yml runs on a labelled issue and a new comment, nothing else" \
    "issue_comment:created issues:labeled" "${triggers}"
preflight_if=$(workflow_query "${AI_FIX_YML}" 'print(wf["jobs"]["preflight"]["if"])')
assert_contains "preflight fires on the label the page names" "${preflight_if}" \
    "github.event.label.name == '${doc_label:-<none>}'"
assert_contains "and on a comment containing the mention the page names" "${preflight_if}" \
    "contains(github.event.comment.body, '${doc_mention:-<none>}')"
assert_contains "the page says it has to be a conversation comment" "${prs}" \
    "It has to be a conversation comment rather than an inline reply on the review thread"
assert_contains "the page says the bot's own comment cannot start it" "${prs}" \
    "The bot's own comment cannot start it"
bots=$(workflow_query "${AI_FIX_YML}" '
for job in wf["jobs"].values():
    for step in job.get("steps", []):
        if "allowed_bots" in (step.get("with") or {}):
            print(repr(step["with"]["allowed_bots"]))
')
assert_eq "the action's allowed_bots is empty" "''" "${bots}"
assert_contains "and preflight refuses a bot sender itself" \
    "$(workflow_query "${AI_FIX_YML}" '
for step in wf["jobs"]["preflight"]["steps"]:
    print(step.get("run", ""))
')" '"${SENDER_TYPE}" = "Bot"'
assert_contains "the page says it opens a pull request and never merges one" \
    "${prs}" "which opens a pull request and never merges one"

# --- 7. "Changes that need a conversation first" ------------------------------

conversation=$(section_body "## Changes that need a conversation first" "${DOC}" | flatten)
assert_contains "the page says there is no package manager and no node_modules" \
    "${conversation}" 'The repo deliberately has no package manager and no `node_modules`'
manifests=$(git -C "${REPO_ROOT}" ls-files |
    grep -E '(^|/)(package(-lock)?\.json|yarn\.lock|pnpm-lock\.yaml|node_modules/|requirements[^/]*\.txt|pyproject\.toml|Pipfile|Gemfile|go\.mod|Cargo\.toml)' |
    tr '\n' ' ')
assert_eq "no package manifest or node_modules is tracked" "" "${manifests}"
assert_contains "FEDORA_VERSION's checklist is docs/manual-input-check.md" "${conversation}" \
    'moving `FEDORA_VERSION`, which has a pre-flight checklist in [`docs/manual-input-check.md`]'
assert_contains "that page is about FEDORA_VERSION" \
    "$(cat "${REPO_ROOT}/docs/manual-input-check.md")" "FEDORA_VERSION"
assert_contains "and the Containerfile declares it" "$(cat "${CONTAINERFILE}")" "ARG FEDORA_VERSION"

finish
