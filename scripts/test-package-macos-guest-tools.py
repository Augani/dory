#!/usr/bin/env python3
"""Regression coverage for signed macOS Guest Tools package production."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PACKAGER = ROOT / "scripts" / "package-macos-guest-tools.py"


class GuestToolsPackageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="dory-guest-tools-package-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "DoryGuestTools.app"
        executable = self.app / "Contents/MacOS/DoryGuestTools"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"guest-tools")
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.pythonxi.Dory.GuestTools",
            "CFBundleExecutable": "DoryGuestTools",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
        }))
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
        self.write_tool("pkgutil", """#!/bin/sh
printf '%s\\n' 'Developer ID Installer: Dory (864H636QW4)'
""")
        self.output = self.root / "DoryGuestTools-1.0.0.pkg"
        self.manifest = self.root / "DoryGuestTools-1.0.0.pkg.json"

    def write_tool(self, name: str, contents: str) -> None:
        path = self.tools / name
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o755)

    def invoke(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable, str(PACKAGER), "--app", str(self.app),
                "--candidate-id", "macos-dev-1", "--source-commit", "a" * 40,
                "--installer-signing-identity", "Developer ID Installer: Dory (864H636QW4)",
                "--output", str(self.output), "--manifest-output", str(self.manifest),
            ],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            env={**os.environ, "PATH": str(self.tools) + os.pathsep + os.environ["PATH"]},
        )

    def test_signed_package_binds_the_bundle_manifest_and_candidate(self) -> None:
        completed = self.invoke()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        document = json.loads(self.manifest.read_text())
        self.assertEqual(document["schema"], "dory.macos-guest-tools-package@1")
        self.assertEqual(document["candidateID"], "macos-dev-1")
        self.assertEqual(document["sourceCommit"], "a" * 40)
        self.assertEqual(document["bundleManifest"]["candidateID"], "macos-dev-1")
        self.assertEqual(
            document["bundleManifestSHA256"],
            hashlib.sha256(
                (json.dumps(document["bundleManifest"], indent=2, sort_keys=True) + "\n").encode()
            ).hexdigest(),
        )
        self.assertEqual(document["package"]["sha256"], hashlib.sha256(self.output.read_bytes()).hexdigest())
        self.assertEqual(document["package"]["installerTeamIdentifier"], "864H636QW4")

    def test_wrong_installer_team_is_rejected(self) -> None:
        self.write_tool("pkgutil", "#!/bin/sh\nprintf '%s\\n' 'Developer ID Installer: Other (BADTEAM)'\n")
        completed = self.invoke()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("expected Dory Developer ID Installer team", completed.stderr)
        self.assertFalse(self.output.exists())
        self.assertFalse(self.manifest.exists())

    def test_indirect_package_output_is_rejected(self) -> None:
        direct = self.root / "direct.pkg"
        direct.write_bytes(b"existing")
        self.output.symlink_to(direct.name)
        completed = self.invoke()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("must not be a symbolic link", completed.stderr)

    def test_package_output_inside_the_app_bundle_is_rejected(self) -> None:
        self.output = self.app / "Contents/Resources/DoryGuestTools.pkg"
        completed = self.invoke()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("outside the guest-tools app bundle", completed.stderr)


if __name__ == "__main__":
    unittest.main()
