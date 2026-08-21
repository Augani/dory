#!/usr/bin/env python3
"""Offline contract tests for the exact physical release-candidate wrapper."""

from __future__ import annotations

import os
import pathlib
import re
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "release-candidate-live-smoke.sh"


class ReleaseCandidateLiveSmokeTests(unittest.TestCase):
    def test_live_contract_binds_candidate_and_all_physical_gates(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "DORY_RELEASE_LIVE_CONFIRMED=ISOLATED-DORY-RELEASE-USER",
            "live qualification requires an exact source commit",
            "candidate app is unavailable or indirect",
            "candidate executable is unavailable or indirect",
            "candidate Docker socket is not owned by the release user",
            "candidate app has no valid notarization ticket",
            "candidate is not accepted as Notarized Developer ID",
            "required offline release fixture is missing",
            "ISOLATED-DORY-MACHINE-RESOURCES",
            "EXACT-CANDIDATE-DESKTOPS",
            "ISOLATED-EXTERNAL-APFS-BIND",
            "ISOLATED-DORY-BIND-LOCKS",
            "SLEEP-AND-WAKE-THIS-MAC",
            'DORY_APP="$APP"',
            'READINESS_DOCKER_BIN="$DOCKER_CLI"',
            'READINESS_ALPINE_IMAGE="$FIXTURE_IMAGE"',
            'READINESS_NONNATIVE_BUILD_IMAGE="$NONNATIVE_BUILD_IMAGE"',
            "live-manifest.txt",
            "live_candidate=PASS",
        ):
            self.assertIn(proof, text, proof)
        for stale in ("alpine:latest", "nginx:alpine", "node:20-alpine", "assert "):
            self.assertNotIn(stale, text, stale)

    def test_every_invoked_script_is_tracked(self) -> None:
        text = GATE.read_text(encoding="utf-8")
        dependencies = sorted(set(re.findall(r"scripts/[A-Za-z0-9._/-]+\.sh", text)))
        self.assertGreaterEqual(len(dependencies), 10)
        for dependency in dependencies:
            result = subprocess.run(
                ["git", "ls-files", "--error-unmatch", dependency],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 0, f"untracked live dependency: {dependency}")

    def test_dedicated_user_confirmation_fails_before_host_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            app = pathlib.Path(temporary) / "Dory.app"
            app.mkdir()
            result = subprocess.run(
                [str(GATE), str(app)],
                cwd=ROOT,
                env={
                    **os.environ,
                    "HOME": temporary,
                    "DORY_RELEASE_SOURCE_COMMIT": "a" * 40,
                },
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("DORY_RELEASE_LIVE_CONFIRMED", result.stderr)


if __name__ == "__main__":
    unittest.main()
