#!/usr/bin/env bash
#
# Exercises the Chunkah custom manager against both checked-in pin syntaxes,
# then the division of labour between the two dependency bots: which of
# renovate.json and .github/dependabot.yml owns each ecosystem.
#
# Renovate uses RE2's JavaScript-style named captures; Python's equivalent is
# substituted below so the repository's existing Python dependency can run the
# same expression without requiring a Renovate installation.

set -uo pipefail

TEST_NAME="test-renovate"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

CONFIG="${REPO_ROOT}/renovate.json"

if jq empty "${CONFIG}" >/dev/null 2>&1; then
    _pass "renovate.json is valid JSON"
else
    _fail "renovate.json is valid JSON" "jq could not parse ${CONFIG}"
    finish
    exit
fi

analysis=""
if analysis=$(python3 - "${CONFIG}" "${REPO_ROOT}" <<'PY'
import json
import pathlib
import re
import sys

config_path = pathlib.Path(sys.argv[1])
repo_root = pathlib.Path(sys.argv[2])
config = json.loads(config_path.read_text())

managers = [
    manager
    for manager in config.get("customManagers", [])
    if manager.get("customType") == "regex"
    and manager.get("description") == "Track stable Chunkah container releases"
]
if len(managers) != 1:
    raise SystemExit(f"expected one Chunkah regex manager, found {len(managers)}")

manager = managers[0]
match_strings = manager.get("matchStrings", [])
if len(match_strings) != 1:
    raise SystemExit(f"expected one Chunkah match string, found {len(match_strings)}")

# Python and JavaScript spell named capture groups differently. The rest of
# this expression uses syntax common to Python's re and Renovate's RE2 engine.
expression = re.sub(
    r"\(\?<([A-Za-z][A-Za-z0-9_]*)>",
    r"(?P<\1>",
    match_strings[0],
)
matcher = re.compile(expression)

file_patterns = []
for raw_pattern in manager.get("managerFilePatterns", []):
    if len(raw_pattern) < 2 or not raw_pattern.startswith("/") or not raw_pattern.endswith("/"):
        raise SystemExit(f"unsupported manager file pattern: {raw_pattern!r}")
    file_patterns.append(re.compile(raw_pattern[1:-1]))

files = (
    (".github/workflows/build.yml", "CHUNKAH_IMAGE: quay.io/coreos/chunkah:v9.8.7"),
    (
        "tests/e2e/run-e2e.sh",
        'CHUNKAH_IMAGE="${CHUNKAH_IMAGE:-quay.io/coreos/chunkah:v9.8.7}"',
    ),
)

for relative_path, expected_replacement in files:
    text = (repo_root / relative_path).read_text()
    matches = list(matcher.finditer(text))
    eligible = any(pattern.search(relative_path) for pattern in file_patterns)
    values = ",".join(match.group("currentValue") for match in matches)

    def replace_version(match):
        start, end = match.span("currentValue")
        return match.group(0)[: start - match.start()] + "v9.8.7" + match.group(0)[end - match.start() :]

    updated = matcher.sub(replace_version, text)
    replacement_preserved_syntax = expected_replacement in updated
    print(
        relative_path,
        str(eligible).lower(),
        len(matches),
        values,
        str(replacement_preserved_syntax).lower(),
        sep="\t",
    )
PY
); then
    _pass "Chunkah manager can be evaluated"
else
    _fail "Chunkah manager can be evaluated" "failed to load or compile its configuration"
    finish
    exit
fi

mapfile -t rows <<<"${analysis}"
assert_eq "both Chunkah pin files were analyzed" "2" "${#rows[@]}"

IFS=$'\t' read -r workflow_path workflow_eligible workflow_matches workflow_value workflow_replaced <<<"${rows[0]}"
assert_eq "first result is the workflow pin" ".github/workflows/build.yml" "${workflow_path}"
assert_eq "workflow path is selected by managerFilePatterns" "true" "${workflow_eligible}"
assert_eq "workflow contains exactly one Chunkah match" "1" "${workflow_matches}"
assert_eq "workflow replacement changes only the version capture" "true" "${workflow_replaced}"

IFS=$'\t' read -r script_path script_eligible script_matches script_value script_replaced <<<"${rows[1]}"
assert_eq "second result is the e2e script pin" "tests/e2e/run-e2e.sh" "${script_path}"
assert_eq "e2e script path is selected by managerFilePatterns" "true" "${script_eligible}"
assert_eq "e2e script contains exactly one Chunkah match" "1" "${script_matches}"
assert_eq "e2e replacement preserves Bash parameter expansion" "true" "${script_replaced}"
assert_eq "workflow and e2e Chunkah pins agree" "${workflow_value}" "${script_value}"

# =============================================================================
# Who updates what: renovate.json against .github/dependabot.yml
# =============================================================================
#
# The split between the two bots lives in a comment inside renovate.json --
# "Dependabot owns GitHub Actions version updates; disable Renovate's
# github-actions manager to avoid duplicate PRs". Only one half of that sentence
# is in renovate.json; the other half is an ecosystem entry in
# .github/dependabot.yml, and the two files never mention each other.
#
# The consequence of them drifting apart is silent either way. Both bots on
# github-actions means duplicate pull requests. Neither means the full-SHA
# `uses:` pins that tests/lib/workflow_pins.py requires stop being moved by
# anything and go stale with the suite green -- the pins stay valid, so nothing
# fails. The cases below assert the ownership of each ecosystem, not just the
# presence of each file.

DEPENDABOT_CONFIG="${REPO_ROOT}/.github/dependabot.yml"
WORKFLOW_PYTHON="${WORKFLOW_PYTHON:-python3}"

if [[ ! -f "${DEPENDABOT_CONFIG}" ]]; then
    # Not a skip: renovate.json disables its github-actions manager on the
    # assumption that this file exists.
    _fail ".github/dependabot.yml exists" \
        "no such file: ${DEPENDABOT_CONFIG}" \
        "renovate.json disables its github-actions manager and leaves the" \
        "GitHub Actions SHA pins to Dependabot; with this file gone, nothing" \
        "updates them"
    finish
    exit 1
fi

if ! "${WORKFLOW_PYTHON}" -c 'import yaml' >/dev/null 2>&1; then
    _fail "the dependency-ownership cases require Python 3 with PyYAML" \
        "install python3-yaml (Debian/Ubuntu) or python3-pyyaml (Fedora)," \
        "or install PyYAML in the interpreter selected by WORKFLOW_PYTHON"
    finish
    exit 1
fi

bot_facts=""
if ! bot_facts=$("${WORKFLOW_PYTHON}" -B - "${REPO_ROOT}" <<'PY'
import json
import pathlib
import sys

import yaml

repo_root = pathlib.Path(sys.argv[1])
renovate = json.loads((repo_root / "renovate.json").read_text())
dependabot = yaml.safe_load((repo_root / ".github" / "dependabot.yml").read_text())

# Dependabot names an ecosystem, Renovate names a manager, and the two
# vocabularies differ. An ecosystem missing from this table is reported rather
# than assumed harmless: adding one has to come with a decision about which bot
# owns it, and that decision is what these cases exist to hold.
ECOSYSTEM_TO_MANAGER = {
    "bundler": "bundler",
    "cargo": "cargo",
    "composer": "composer",
    "docker": "dockerfile",
    "github-actions": "github-actions",
    "gitsubmodule": "git-submodules",
    "gomod": "gomod",
    "gradle": "gradle",
    "maven": "maven",
    "npm": "npm",
    "nuget": "nuget",
    "pip": "pip_requirements",
    "terraform": "terraform",
}

updates = dependabot.get("updates") or []
ecosystems = [entry.get("package-ecosystem") for entry in updates]

# A packageRules entry disables a manager outright only when nothing else
# narrows it. One that also carried matchFileNames or matchUpdateTypes would
# leave the manager live everywhere it did not name, which is not the same
# thing as handing the ecosystem to the other bot.
blanket_disabled = set()
for rule in renovate.get("packageRules", []):
    if rule.get("enabled") is not False:
        continue
    if [key for key in rule if key.startswith("match") and key != "matchManagers"]:
        continue
    blanket_disabled.update(rule.get("matchManagers", []))

managers = [
    manager
    for manager in renovate.get("customManagers", [])
    if manager.get("description") == "Track stable Chunkah container releases"
]
chunkah_dep_name = managers[0].get("depNameTemplate", "") if len(managers) == 1 else ""

package_rules = [rule for rule in renovate.get("packageRules", []) if rule.get("matchPackageNames")]
named_packages = sorted({name for rule in package_rules for name in rule["matchPackageNames"]})
chunkah_disabled_types = set()
for rule in package_rules:
    if rule.get("enabled") is False and chunkah_dep_name in rule["matchPackageNames"]:
        chunkah_disabled_types.update(rule.get("matchUpdateTypes", []))

renovate_owns_actions = "github-actions" not in blanket_disabled
dependabot_owns_actions = "github-actions" in ecosystems
owner = {
    (True, False): "renovate",
    (False, True): "dependabot",
    (True, True): "both",
    (False, False): "neither",
}[(renovate_owns_actions, dependabot_owns_actions)]

# Every place a dependency bot can be configured in this repository. A second
# Renovate config would be read alongside renovate.json and is not covered by
# anything here, so its appearance has to fail rather than pass unseen.
candidates = (
    "renovate.json",
    "renovate.json5",
    ".renovaterc",
    ".renovaterc.json",
    ".github/renovate.json",
    ".github/renovate.json5",
    ".github/dependabot.yml",
    ".github/dependabot.yaml",
)
bot_configs = [name for name in candidates if (repo_root / name).is_file()]

tier_rows = [
    line
    for line in (repo_root / "docs" / "risk-tiers.md").read_text().splitlines()
    if line.startswith("| **2 ")
]
tier_row = tier_rows[0] if len(tier_rows) == 1 else ""

readme = (repo_root / "README.md").read_text()
pin_claim = [
    paragraph
    for paragraph in readme.split("\n\n")
    if "disables digest and pin updates" in paragraph
]

facts = {
    "dependabot_version": str(dependabot.get("version")),
    # One line per github-actions entry, so a second copy of it -- two entries
    # opening the same update twice -- reads differently from one.
    "github_actions_updates": ",".join(
        "{}|{}".format(
            entry.get("directory"),
            (entry.get("schedule") or {}).get("interval"),
        )
        for entry in updates
        if entry.get("package-ecosystem") == "github-actions"
    ),
    "github_actions_owner": owner,
    "unknown_ecosystems": ",".join(
        sorted(set(ecosystems) - set(ECOSYSTEM_TO_MANAGER))
    ),
    "ecosystems_renovate_still_owns": ",".join(
        sorted(
            eco
            for eco in ecosystems
            if eco in ECOSYSTEM_TO_MANAGER
            and ECOSYSTEM_TO_MANAGER[eco] not in blanket_disabled
        )
    ),
    "dockerfile_manager_disabled": str("dockerfile" in blanket_disabled).lower(),
    "containerfile_ecosystems": ",".join(
        sorted(eco for eco in ecosystems if ECOSYSTEM_TO_MANAGER.get(eco) == "dockerfile")
    ),
    "chunkah_dep_name": chunkah_dep_name,
    "renovate_named_packages": ",".join(named_packages),
    "chunkah_disabled_update_types": ",".join(sorted(chunkah_disabled_types)),
    "bot_configs": ",".join(bot_configs),
    "bot_configs_missing_from_tier_2": ",".join(
        name for name in bot_configs if name not in tier_row
    ),
    "readme_pin_claims": str(len(pin_claim)),
    "readme_pin_claim_names_package": str(
        len(pin_claim) == 1 and bool(chunkah_dep_name) and chunkah_dep_name in pin_claim[0]
    ).lower(),
}

for key in sorted(facts):
    print(key, facts[key], sep="\t")
PY
); then
    _fail "the two bot configurations can be read together" \
        "failed to load renovate.json, .github/dependabot.yml, or the documents they are held against"
    finish
    exit 1
fi
_pass "the two bot configurations can be read together"

declare -A FACT=()
while IFS=$'\t' read -r fact_key fact_value; do
    [[ -n "${fact_key}" ]] || continue
    FACT["${fact_key}"]="${fact_value}"
done <<<"${bot_facts}"

assert_eq "dependabot.yml declares the v2 configuration format" \
    "2" "${FACT[dependabot_version]}"

# directory and interval are asserted together with the entry, not separately:
# an entry scoped to a subdirectory would not reach .github/workflows, and one
# with no schedule is not a running updater.
assert_eq "Dependabot updates GitHub Actions weekly from the repository root" \
    "/|weekly" "${FACT[github_actions_updates]}"

assert_eq "GitHub Actions updates have exactly one owner, and it is Dependabot" \
    "dependabot" "${FACT[github_actions_owner]}"

assert_eq "every Dependabot ecosystem maps to a known Renovate manager" \
    "" "${FACT[unknown_ecosystems]}"

assert_eq "no Dependabot ecosystem duplicates a manager Renovate still runs" \
    "" "${FACT[ecosystems_renovate_still_owns]}"

# The Containerfile's image ARGs are hand-managed and the weekly build tracks
# :stable on purpose. Renovate's dockerfile manager is off for that reason;
# a docker ecosystem here would start opening the pull requests it refuses to.
assert_eq "Renovate's dockerfile manager stays disabled" \
    "true" "${FACT[dockerfile_manager_disabled]}"
assert_eq "and no Dependabot ecosystem updates the Containerfile either" \
    "" "${FACT[containerfile_ecosystems]}"

# Without this join a rename of depNameTemplate detaches the pin rule silently:
# the rule keeps matching a package name nothing tracks any more, and Chunkah
# starts receiving the digest pins the README says it does not get.
assert_eq "the packageRules names are the package the Chunkah manager tracks" \
    "${FACT[chunkah_dep_name]}" "${FACT[renovate_named_packages]}"
assert_eq "the Chunkah manager tracks the image the workflow pins" \
    "quay.io/coreos/chunkah" "${FACT[chunkah_dep_name]}"
assert_eq "digest and pin updates are disabled for that package" \
    "digest,pin,pinDigest" "${FACT[chunkah_disabled_update_types]}"

assert_eq "the repository configures exactly these two dependency bots" \
    "renovate.json,.github/dependabot.yml" "${FACT[bot_configs]}"
assert_eq "and docs/risk-tiers.md rates both of them Tier 2" \
    "" "${FACT[bot_configs_missing_from_tier_2]}"

# README.md tells a reader the Chunkah pin is a tag and stays one. That claim
# is true only for as long as the packageRule holds, and the two are edited
# separately.
assert_eq "README.md states the digest and pin disable exactly once" \
    "1" "${FACT[readme_pin_claims]}"
assert_eq "and names the package the rule disables" \
    "true" "${FACT[readme_pin_claim_names_package]}"

finish
