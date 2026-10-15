# Replays renovate.json's packageRules the way Renovate applies them to one
# update: a rule applies when every match* key it carries matches, and a later
# applying rule overrides an earlier one. Reading only the rule that names a
# package misses a rule that reaches it some other way -- a later
# matchDepNames automerge, or matchManagers ["custom.regex"] with
# enabled: false, which also stops the update and leaves the suite green. A
# match key or pattern this does not model raises, so a new rule cannot be
# misread as "does not apply".
#
# An update is a dict with name, manager, datasource, dep_type (None when the
# regex manager has no depTypeTemplate), type and file. Presets named in
# "extends" are not expanded.

import re


def file_glob(pattern):
    # minimatch with dot: true, for the subset matchFileNames uses here: "**"
    # as a whole segment spans directories, "*" and "**" inside a segment stay
    # in it.
    if re.search(r"[\[\]{}()!+@?\\]", pattern):
        raise SystemExit(f"matchFileNames entry outside the modeled glob subset: {pattern!r}")
    out = []
    for segment in pattern.split("/"):
        if segment == "**":
            out.append(None)
        else:
            out.append(re.sub(r"(?:\\\*)+", "[^/]*", re.escape(segment)))
    expression = ""
    for index, segment in enumerate(out):
        last = index == len(out) - 1
        if segment is None:
            expression += ".*" if last else "(?:[^/]+/)*"
        else:
            expression += segment + ("" if last else "/")
    return re.compile(expression + r"\Z")


def literal(values, key):
    for value in values:
        if value.startswith("/") or re.search(r"[*?!{}]", value):
            raise SystemExit(f"{key} entry outside the modeled literal subset: {value!r}")
    return values


def applies(rule, update):
    for key, values in rule.items():
        if key.startswith("exclude"):
            raise SystemExit(f"packageRules key not modeled: {key}")
        if not key.startswith("match"):
            continue
        if key in ("matchPackageNames", "matchDepNames"):
            if update["name"] not in literal(values, key):
                return False
        elif key == "matchManagers":
            if update["manager"] not in literal(values, key):
                return False
        elif key == "matchDatasources":
            if update["datasource"] not in literal(values, key):
                return False
        elif key == "matchUpdateTypes":
            if update["type"] not in values:
                return False
        elif key == "matchDepTypes":
            if update["dep_type"] not in values:
                return False
        elif key == "matchFileNames":
            if not any(file_glob(value).match(update["file"]) for value in values):
                return False
        else:
            raise SystemExit(f"packageRules key not modeled: {key}")
    return True


def decide(config, update):
    """Return (enabled, automerge) for one update after every rule, in order."""
    enabled = config.get("enabled", True)
    automerge = config.get("automerge", False)
    for rule in config.get("packageRules", []):
        if applies(rule, update):
            enabled = rule.get("enabled", enabled)
            automerge = rule.get("automerge", automerge)
    return enabled, automerge
