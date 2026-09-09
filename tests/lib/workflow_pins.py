"""Require every action a workflow uses to name immutable code.

A `uses:` value is the one input to a job that can change after review without a
commit here: `owner/repo@v1` resolves to whatever that tag points at when the run
starts. `build.yml`'s `build_push` job holds `packages: write` and hands
`secrets.SIGNING_SECRET` to `cosign sign`, so a moving reference there is a third
party deciding what gets signed under a key consumers are told to trust.

Three shapes, three rules:

* `owner/repo[/path]@ref` -- `ref` must be a full 40-character lowercase commit
  SHA. A tag, a branch, or an abbreviated SHA can be repointed; a full SHA
  cannot, and GitHub refuses an ambiguous short one rather than resolving it.
* `docker://image[:tag]` -- must carry an `@sha256:` digest. A registry tag is
  mutable for the same reason a git tag is.
* `./path` -- allowed with no ref at all. A local action is part of the commit
  being reviewed.

Composes YAML nodes rather than constructing Python objects, for the same
reasons `workflow_expressions.py` does: source locations survive, duplicate keys
are rejected instead of silently collapsing, and the literal `on` key is not
converted to a YAML 1.1 boolean. That module owns the shared graph validation, so
malformed YAML, merge keys, custom tags and recursive aliases fail here too.
"""

import argparse
from pathlib import Path
import re
import sys

import yaml
from yaml.nodes import ScalarNode, SequenceNode

try:  # run as a script: sys.path[0] is tests/lib
    from workflow_expressions import WorkflowError, location, mapping, validate_graph
except ImportError:  # imported as lib.workflow_pins from tests/
    from lib.workflow_expressions import (  # type: ignore[no-redef]
        WorkflowError,
        location,
        mapping,
        validate_graph,
    )

COMMIT_SHA = re.compile(r"^[0-9a-f]{40}$")
IMAGE_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")


def check_workflow(source, filename="workflow.yml"):
    """Return (diagnostics, count). An empty list means every `uses:` was pinned.

    `count` is how many `uses:` values were examined, so a caller can refuse to
    report success on a scan that inspected nothing.
    """
    findings = []
    examined = 0

    def reference(node, path):
        nonlocal examined
        if not isinstance(node, ScalarNode):
            raise WorkflowError(f"{location(node)}: {path}: expected a scalar")
        examined += 1
        value = node.value

        if value.startswith("./") or value.startswith(".\\"):
            # Local to this repository, so it moves with the commit under review.
            return

        if value.startswith("docker://"):
            _, _, image = value.partition("docker://")
            _, separator, digest = image.rpartition("@")
            if separator and IMAGE_DIGEST.match(digest):
                return
            findings.append(
                f"{filename}:{location(node)}: {path}: {value!r} is a container tag; "
                "pin it with an @sha256: digest"
            )
            return

        repository, separator, ref = value.rpartition("@")
        if not separator or not repository:
            findings.append(
                f"{filename}:{location(node)}: {path}: {value!r} names no ref; "
                "pin it to a full 40-character commit SHA"
            )
            return
        if COMMIT_SHA.match(ref):
            return
        findings.append(
            f"{filename}:{location(node)}: {path}: {value!r} is not pinned to a full "
            "40-character commit SHA; a tag, a branch or a short SHA can be repointed "
            "at other code without a commit here"
        )

    def steps(node, path):
        # Shape errors are the expression checker's to report; this pass only
        # walks whatever sequence it is given and skips anything that is not a
        # mapping with a `uses:` key.
        if not isinstance(node, SequenceNode):
            raise WorkflowError(f"{location(node)}: {path}: expected a sequence")
        for index, step in enumerate(node.value):
            step_path = f"{path}[{index}]"
            values = mapping(step, step_path)
            if "uses" in values:
                reference(values["uses"], step_path + ".uses")
            if "parallel" in values:
                steps(values["parallel"], step_path + ".parallel")

    try:
        root = yaml.compose(source, Loader=yaml.SafeLoader)
        validate_graph(root, set(), set())
        workflow = mapping(root, "workflow")
        if "jobs" not in workflow:
            raise WorkflowError("1:1: workflow: missing jobs mapping")
        jobs = mapping(workflow["jobs"], "jobs")
        if not jobs:
            raise WorkflowError(f"{location(workflow['jobs'])}: jobs: empty mapping")
        for name, job in jobs.items():
            path = f"jobs.{name}"
            values = mapping(job, path)
            # A job-level `uses:` is a reusable workflow, which runs with this
            # repository's secrets exactly as a step-level action does.
            if "uses" in values:
                reference(values["uses"], path + ".uses")
            if "steps" in values:
                steps(values["steps"], path + ".steps")
    except (yaml.YAMLError, WorkflowError, RecursionError) as error:
        findings.append(f"{filename}: cannot check workflow: {error}")
    return findings, examined


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workflow_dir", type=Path)
    args = parser.parse_args(argv)
    try:
        workflows = sorted(
            path for path in args.workflow_dir.iterdir()
            if path.is_file() and path.suffix in {".yml", ".yaml"}
        )
    except OSError as error:
        print(f"{args.workflow_dir}: cannot list workflows: {error}", file=sys.stderr)
        return 1
    if not workflows:
        print(f"{args.workflow_dir}: no .yml or .yaml workflows found", file=sys.stderr)
        return 1

    findings = []
    examined = 0
    for path in workflows:
        try:
            found, count = check_workflow(path.read_text(encoding="utf-8"), str(path))
        except (OSError, UnicodeError) as error:
            findings.append(f"{path}: cannot read workflow: {error}")
            continue
        findings.extend(found)
        examined += count

    if findings:
        print("\n".join(findings), file=sys.stderr)
        print(
            "Resolve the tag to a commit SHA and keep the version as a trailing "
            "comment, e.g. `uses: owner/action@<sha> # v1.2.3`.",
            file=sys.stderr,
        )
        return 1

    # Nothing to report and nothing examined are different results, and only one
    # of them is a pass. A refactor that moves every action behind a key this
    # walker does not follow would otherwise read as a clean scan.
    if examined == 0:
        print(
            f"{args.workflow_dir}: no uses: values were extracted from "
            f"{len(workflows)} workflow(s); this check asserted nothing",
            file=sys.stderr,
        )
        return 1

    print(f"checked {examined} pinned uses: value(s) in {len(workflows)} workflow(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
