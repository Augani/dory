#!/usr/bin/env python3
"""Offline regression tests for the single release-operator command."""

from __future__ import annotations

import pathlib
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
COMMAND = ROOT / "scripts" / "dory-release.sh"
LEGACY = ROOT / "scripts" / "publish-release.sh"


class DoryReleaseCommandTests(unittest.TestCase):
    def test_command_is_shell_valid_and_documents_each_action(self) -> None:
        subprocess.run(["bash", "-n", str(COMMAND)], cwd=ROOT, check=True)
        result = subprocess.run(
            [str(COMMAND), "--help"],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        for action in ("check", "candidate", "status", "publish"):
            self.assertIn(action, result.stdout)
        self.assertIn("release-build/candidates/", result.stdout)
        self.assertIn("physical qualification evidence", result.stdout)

    def test_candidate_and_publish_share_exact_source_preflight(self) -> None:
        source = COMMAND.read_text(encoding="utf-8")
        self.assertEqual(source.count('verify_operator_context "$version"'), 2)
        self.assertIn('CANDIDATE_WORKFLOW="release-candidate.yml"', source)
        self.assertIn('PUBLIC_WORKFLOW="release.yml"', source)
        self.assertIn('git branch --show-current', source)
        self.assertIn('git status --porcelain --untracked-files=normal', source)
        self.assertIn('local main must exactly match origin/main', source)
        self.assertIn('.github/scripts/verify-release-identity.py', source)
        self.assertIn('gh run watch "$RUN_ID"', source)
        self.assertIn('.github/scripts/verify-public-release.py', source)

    def test_private_candidate_is_downloaded_but_never_published(self) -> None:
        source = COMMAND.read_text(encoding="utf-8")
        candidate = source.split("stage_candidate()", 1)[1].split(
            "publish_release()", 1
        )[0]
        self.assertIn("dory-signed-release-candidate-$HEAD_SHA-$run_attempt", candidate)
        self.assertIn('gh run download "$RUN_ID"', candidate)
        for forbidden in ("gh release", "verify-public-release.py", "PUBLIC_WORKFLOW"):
            self.assertNotIn(forbidden, candidate)

    def test_legacy_publisher_is_only_a_compatibility_shim(self) -> None:
        subprocess.run(["bash", "-n", str(LEGACY)], cwd=ROOT, check=True)
        source = LEGACY.read_text(encoding="utf-8")
        self.assertIn('scripts/dory-release.sh" publish', source)
        self.assertNotIn("gh workflow run", source)
        self.assertNotIn("verify-release-identity.py", source)


if __name__ == "__main__":
    unittest.main()
