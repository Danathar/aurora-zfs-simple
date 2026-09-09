"""Regression cases for `uses:` references that must not pass as pinned."""

from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

from lib.workflow_pins import check_workflow


SHA = "3d3c42e5aac5ba805825da76410c181273ba90b1"
CHECKER = Path(__file__).parent / "lib" / "workflow_pins.py"


def workflow(steps):
    return (
        "name: Fixture\non: workflow_dispatch\njobs:\n  check:\n"
        "    runs-on: ubuntu-latest\n    steps:\n"
        + textwrap.indent(steps, "      ")
        + "\n"
    )


class WorkflowPinsTest(unittest.TestCase):
    def assert_clean(self, source, expected_count):
        findings, examined = check_workflow(source, "fixture.yaml")
        self.assertEqual([], findings)
        self.assertEqual(expected_count, examined)

    def assert_rejected(self, source, path, needle="fixture.yaml:"):
        findings, examined = check_workflow(source, "fixture.yaml")
        self.assertEqual(1, len(findings), findings)
        self.assertIn(path, findings[0])
        self.assertIn(needle, findings[0])
        self.assertEqual(1, examined)

    def test_a_full_commit_sha_is_pinned(self):
        self.assert_clean(workflow(f"- uses: owner/action@{SHA} # v1.2.3"), 1)

    def test_mutable_and_ambiguous_refs_are_rejected(self):
        # Each of these resolves at run time to whatever the referenced
        # repository points it at, which is the property the check exists for.
        # A 39- and a 41-character hex string are here because an anchored
        # regex is the only thing separating them from the accepted spelling.
        cases = {
            "tag": "v1",
            "semver tag": "v1.2.3",
            "branch": "main",
            "short sha": SHA[:7],
            "uppercase sha": SHA.upper(),
            "39 hex": SHA[:39],
            "41 hex": SHA + "a",
        }
        for label, ref in cases.items():
            with self.subTest(label=label):
                self.assert_rejected(
                    workflow(f"- uses: owner/action@{ref}"),
                    "jobs.check.steps[0].uses",
                    "not pinned to a full",
                )

    def test_a_reference_with_no_ref_at_all_is_rejected(self):
        # `owner/action` with no `@` resolves to the default branch.
        self.assert_rejected(
            workflow("- uses: owner/action"),
            "jobs.check.steps[0].uses",
            "names no ref",
        )

    def test_a_subdirectory_action_is_read_as_one_reference(self):
        # The path may contain slashes; only the last `@` separates the ref.
        self.assert_clean(workflow(f"- uses: owner/repo/sub/action@{SHA}"), 1)
        self.assert_rejected(
            workflow("- uses: owner/repo/sub/action@v1"),
            "jobs.check.steps[0].uses",
            "not pinned to a full",
        )

    def test_a_local_action_needs_no_ref(self):
        # It is part of the commit under review, so there is nothing to pin.
        self.assert_clean(workflow("- uses: ./.github/actions/setup"), 1)

    def test_a_container_action_must_carry_a_digest(self):
        digest = "sha256:" + "b" * 64
        self.assert_clean(workflow(f"- uses: docker://alpine@{digest}"), 1)
        self.assert_rejected(
            workflow("- uses: docker://alpine:3.20"),
            "jobs.check.steps[0].uses",
            "pin it with an @sha256: digest",
        )

    def test_a_reusable_workflow_is_checked_like_an_action(self):
        # A job-level `uses:` runs with this repository's secrets, so it is the
        # same grant as a step-level action and gets the same rule.
        source = (
            "name: Fixture\non: workflow_dispatch\njobs:\n  call:\n"
            f"    uses: owner/repo/.github/workflows/test.yml@{SHA}\n"
        )
        self.assert_clean(source, 1)
        self.assert_rejected(
            source.replace(SHA, "main"), "jobs.call.uses", "not pinned to a full"
        )

    def test_steps_without_uses_are_not_counted(self):
        findings, examined = check_workflow(workflow("- run: echo safe"), "fixture.yaml")
        self.assertEqual([], findings)
        self.assertEqual(0, examined)

    def test_every_step_of_every_job_is_reached(self):
        source = (
            "name: Fixture\non: workflow_dispatch\njobs:\n"
            "  first:\n    runs-on: ubuntu-latest\n    steps:\n"
            f"      - uses: owner/a@{SHA}\n      - run: echo safe\n"
            "  second:\n    runs-on: ubuntu-latest\n    steps:\n"
            f"      - uses: owner/b@{SHA}\n"
        )
        self.assert_clean(source, 2)

    def test_an_alias_is_checked_where_it_is_used(self):
        # A reference defined once and reused reaches the same rule each time.
        source = (
            "name: Fixture\non: workflow_dispatch\n"
            "env:\n  ACTION: &action owner/action@v1\n"
            "jobs:\n  check:\n    runs-on: ubuntu-latest\n    steps:\n"
            "      - uses: *action\n"
        )
        self.assert_rejected(
            source, "jobs.check.steps[0].uses", "not pinned to a full"
        )

    def test_unreadable_yaml_is_a_finding_rather_than_a_clean_scan(self):
        findings, examined = check_workflow("jobs:\n  check:\n   - broken\n", "fixture.yaml")
        self.assertEqual(1, len(findings), findings)
        self.assertIn("cannot check workflow", findings[0])
        self.assertEqual(0, examined)

    def test_cli_fails_when_it_extracted_nothing(self):
        # The failure this guards is a clean-looking scan that inspected no
        # reference at all -- the same hole test-ai-fix.sh names when it asserts
        # its own extraction was nonempty.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "safe.yml").write_text(workflow("- run: echo safe"), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, "-B", str(CHECKER), str(root)],
                text=True, capture_output=True, check=False,
            )
            self.assertNotEqual(0, result.returncode)
            self.assertIn("asserted nothing", result.stderr)

    def test_cli_reports_a_workflow_it_cannot_decode(self):
        # Skipping an unreadable file would report a count and exit 0 over a
        # workflow nothing looked at.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "safe.yml").write_text(
                workflow(f"- uses: owner/action@{SHA}"), encoding="utf-8"
            )
            (root / "undecodable.yml").write_bytes(b"jobs:\n  check:\n    name: \xff\xfe\n")
            result = subprocess.run(
                [sys.executable, "-B", str(CHECKER), str(root)],
                text=True, capture_output=True, check=False,
            )
            self.assertNotEqual(0, result.returncode)
            self.assertIn("undecodable.yml: cannot read workflow", result.stderr)


if __name__ == "__main__":
    unittest.main()
