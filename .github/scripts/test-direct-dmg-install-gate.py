#!/usr/bin/env python3
"""Offline contract checks for the destructive physical DMG install boundary."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "direct-dmg-install-gate.sh"


class DirectDMGInstallGateTests(unittest.TestCase):
    def invoke(self, *arguments: str, runner_temp: str | None = None) -> subprocess.CompletedProcess[str]:
        environment = dict(os.environ)
        environment["DORY_RELEASE_CLEAN_USER"] = "1"
        if runner_temp is not None:
            environment["RUNNER_TEMP"] = runner_temp
        return subprocess.run(
            ["bash", str(GATE), *arguments],
            cwd=ROOT,
            env=environment,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    def test_script_is_syntax_valid_and_has_no_python_assertions(self) -> None:
        syntax = subprocess.run(["bash", "-n", str(GATE)], check=False)
        self.assertEqual(syntax.returncode, 0)
        source = GATE.read_text(encoding="utf-8")
        self.assertNotIn("assert ", source)
        self.assertIn("validate-release-metadata.py", source)
        self.assertIn("verify-release-sbom.py", source)
        self.assertIn("hdiutil attach -readonly -nobrowse -plist", source)
        self.assertIn("release-candidate-live-smoke.sh", source)
        self.assertIn("DORY_RELEASE_LIVE_CONFIRMED=ISOLATED-DORY-RELEASE-USER", source)
        self.assertIn('DORY_RELEASE_SOURCE_COMMIT="$SOURCE_COMMIT"', source)

    def test_help_documents_the_destructive_confirmation(self) -> None:
        result = self.invoke("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("CLEAN-RELEASE-USER-DMG-INSTALL", result.stdout)
        self.assertIn("--install-only", result.stdout)

    def test_missing_confirmation_fails_before_mutation(self) -> None:
        result = self.invoke(
            "--dmg", "missing.dmg",
            "--sbom", "missing.json",
            "--release-manifest", "missing-manifest.json",
            "--version", "9.8.7",
            "--build", "42",
            "--source-commit", "a" * 40,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("--confirm", result.stderr)

    def test_workroot_must_be_beneath_runner_temp(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dory-dmg-gate-test.") as directory:
            root = pathlib.Path(directory)
            inputs = []
            for name in ("candidate.dmg", "candidate.cdx.json", "release-manifest.json"):
                path = root / name
                path.write_bytes(b"fixture\n")
                inputs.append(path)
            result = self.invoke(
                "--dmg", str(inputs[0]),
                "--sbom", str(inputs[1]),
                "--release-manifest", str(inputs[2]),
                "--version", "9.8.7",
                "--build", "42",
                "--source-commit", "a" * 40,
                "--workroot", "/Applications",
                "--confirm", "CLEAN-RELEASE-USER-DMG-INSTALL",
                runner_temp=str(root),
            )
        self.assertEqual(result.returncode, 2)
        self.assertIn("unsafe --workroot", result.stderr)


if __name__ == "__main__":
    unittest.main()
