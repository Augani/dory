#!/usr/bin/env python3
"""Regression coverage for the macOS guest tools artifact manifest."""

from __future__ import annotations

import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "scripts/generate-macos-guest-tools-manifest.py"


class GuestToolsManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="dory-guest-tools-manifest-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "DoryGuestTools.app"
        binary = self.app / "Contents/MacOS/DoryGuestTools"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"guest-tools")
        plist = {
            "CFBundleIdentifier": "com.pythonxi.Dory.GuestTools",
            "CFBundleExecutable": "DoryGuestTools",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
        }
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(plist))
        self.output = self.root / "manifest.json"

    def invoke(self, *extra: str, environment: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(GENERATOR), "--app", str(self.app), "--candidate-id", "macos-dev-1",
             "--source-commit", "a" * 40, "--output", str(self.output), *extra],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, env=environment,
        )

    def test_unsigned_development_inventory_is_explicit_and_deterministic(self) -> None:
        first = self.invoke("--allow-unsigned-development")
        self.assertEqual(first.returncode, 0, first.stderr)
        before = self.output.read_bytes()
        second = self.invoke("--allow-unsigned-development")
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(before, self.output.read_bytes())
        document = json.loads(before)
        self.assertEqual(document["signing"], {"classification": "unsigned-development", "releaseEligible": False})
        self.assertEqual(document["capabilities"], [{"id": "metal-probe", "version": 1}])
        self.assertEqual(document["bundle"]["identifier"], "com.pythonxi.Dory.GuestTools")

    def test_unsigned_bundle_is_not_a_release_manifest(self) -> None:
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Developer-ID-signed", result.stderr)
        self.assertFalse(self.output.exists())

    def test_displayed_signature_without_strict_verification_is_rejected(self) -> None:
        tools = self.root / "tools"
        tools.mkdir()
        codesign = tools / "codesign"
        codesign.write_text(
            "#!/bin/sh\n"
            "case \"$*\" in\n"
            "  *--verify*) exit 1 ;;\n"
            "esac\n"
            "printf '%s\\n' 'Authority=Developer ID Application: Dory' 'TeamIdentifier=864H636QW4' 'CodeDirectory=v=20400 flags=0x10000(runtime)' >&2\n"
        )
        codesign.chmod(0o755)
        environment = {**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"]}
        result = self.invoke(environment=environment)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Developer-ID-signed", result.stderr)
        self.assertFalse(self.output.exists())

    def test_malformed_candidate_and_bundle_identity_reject(self) -> None:
        result = self.invoke("--candidate-id", "not permitted")
        self.assertNotEqual(result.returncode, 0)
        plist = plistlib.loads((self.app / "Contents/Info.plist").read_bytes())
        plist["CFBundleIdentifier"] = "example.invalid.tools"
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(plist))
        result = self.invoke("--allow-unsigned-development")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("bundle identifier", result.stderr)


if __name__ == "__main__":
    unittest.main()
