#!/usr/bin/env python3
"""Regression tests for post-distribution macOS Guest Tools package verification."""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PACKAGER = ROOT / "scripts" / "package-macos-guest-tools.py"
VERIFIER = ROOT / "scripts" / "verify-macos-guest-tools-package.py"


class GuestToolsPackageVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="dory-guest-tools-package-verifier-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "DoryGuestTools.app"
        executable = self.app / "Contents/MacOS/DoryGuestTools"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"guest-tools")
        (self.app / "Contents/Info.plist").write_text(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict>"
            "<key>CFBundleIdentifier</key><string>com.pythonxi.Dory.GuestTools</string>"
            "<key>CFBundleExecutable</key><string>DoryGuestTools</string>"
            "<key>CFBundleShortVersionString</key><string>1.0.0</string>"
            "<key>CFBundleVersion</key><string>1</string></dict></plist>", encoding="utf-8"
        )
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.write_tool("codesign", """#!/bin/sh
case \"$*\" in *--verify*) exit 0;; esac
printf '%s\\n' 'Authority=Developer ID Application: Dory' 'TeamIdentifier=864H636QW4' 'CodeDirectory=v=20400 flags=0x10000(runtime)' >&2
""")
        self.write_tool("productbuild", """#!/bin/sh
for value in \"$@\"; do output=\"$value\"; done
printf 'signed package' > \"$output\"
""")
        self.write_tool("pkgutil", "#!/bin/sh\nprintf '%s\\n' 'Developer ID Installer: Dory (864H636QW4)'\n")
        self.package = self.root / "DoryGuestTools.pkg"
        self.manifest = self.root / "DoryGuestTools.pkg.json"
        self.environment = {**os.environ, "PATH": str(self.tools) + os.pathsep + os.environ["PATH"]}
        built = subprocess.run([
            sys.executable, str(PACKAGER), "--app", str(self.app), "--candidate-id", "macos-dev-1",
            "--source-commit", "a" * 40, "--installer-signing-identity", "Developer ID Installer: Dory (864H636QW4)",
            "--output", str(self.package), "--manifest-output", str(self.manifest),
        ], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, env=self.environment)
        self.assertEqual(built.returncode, 0, built.stderr)

    def write_tool(self, name: str, contents: str) -> None:
        path = self.tools / name
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o755)

    def invoke(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run([
            sys.executable, str(VERIFIER), "--package", str(self.package), "--manifest", str(self.manifest),
            "--candidate-id", "macos-dev-1", "--source-commit", "a" * 40,
        ], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, env=self.environment)

    def test_candidate_bound_signed_package_verifies(self) -> None:
        completed = self.invoke()
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_package_tampering_is_rejected(self) -> None:
        self.package.write_bytes(b"tampered")
        completed = self.invoke()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("bytes differ", completed.stderr)

    def test_wrong_installer_team_is_rejected(self) -> None:
        self.write_tool("pkgutil", "#!/bin/sh\nprintf '%s\\n' 'Developer ID Installer: Other (BADTEAM)'\n")
        completed = self.invoke()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("expected Dory Developer ID Installer team", completed.stderr)


if __name__ == "__main__":
    unittest.main()
