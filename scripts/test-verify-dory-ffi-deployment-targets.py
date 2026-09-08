#!/usr/bin/env python3
"""Offline contract tests for FFI static-library deployment-target verification."""

from __future__ import annotations

import json
from pathlib import Path
import os
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
VERIFIER = ROOT / "scripts" / "verify-dory-ffi-deployment-targets.py"


class FFIDeploymentTargetVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.library = self.root / "libdory_ffi.a"
        self.library.write_bytes(b"fixture static archive")
        self.lipo = self.tool("lipo", """
            import shutil
            import sys

            if sys.argv[1] == "-archs":
                print("arm64 x86_64")
            elif sys.argv[1] == "-thin":
                shutil.copyfile(sys.argv[3], sys.argv[5])
            else:
                raise SystemExit(64)
        """)
        self.ar = self.tool("ar", """
            import os
            import sys

            if sys.argv[1] == "-t":
                print("__.SYMDEF")
                print("alpha.o")
                print("alpha.o" if os.environ.get("FFI_TEST_DUPLICATE") == "1" else "beta.o")
            elif sys.argv[1] == "-p":
                sys.stdout.buffer.write(sys.argv[3].encode("ascii"))
            else:
                raise SystemExit(64)
        """)
        self.vtool = self.tool("vtool", """
            import os

            if os.environ.get("FFI_TEST_LEGACY") == "1":
                print("cmd LC_VERSION_MIN_MACOSX")
                print("version " + os.environ["FFI_TEST_MINIMUM"])
            else:
                print("platform MACOS")
                print("minos " + os.environ["FFI_TEST_MINIMUM"])
        """)

    def tool(self, name: str, body: str) -> Path:
        path = self.root / name
        path.write_text("#!/usr/bin/env python3\n" + textwrap.dedent(body), encoding="utf-8")
        path.chmod(0o755)
        return path

    def verify(
        self, *, minimum: str, duplicate: bool = False, legacy: bool = False
    ) -> subprocess.CompletedProcess[str]:
        environment = dict(os.environ)
        environment["FFI_TEST_MINIMUM"] = minimum
        if duplicate:
            environment["FFI_TEST_DUPLICATE"] = "1"
        if legacy:
            environment["FFI_TEST_LEGACY"] = "1"
        return subprocess.run(
            [
                "python3", str(VERIFIER),
                "--library", str(self.library),
                "--maximum-macos", "14.0",
                "--lipo", str(self.lipo),
                "--ar", str(self.ar),
                "--vtool", str(self.vtool),
            ],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
        )

    def test_accepts_every_object_at_the_supported_floor(self) -> None:
        result = self.verify(minimum="14.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt["maximumSupportedMacOS"], "14.0.0")
        self.assertEqual([entry["architecture"] for entry in receipt["slices"]], ["arm64", "x86_64"])
        self.assertEqual([entry["objectCount"] for entry in receipt["slices"]], [2, 2])

    def test_rejects_one_object_built_for_a_newer_macos(self) -> None:
        result = self.verify(minimum="27.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires macOS 27.0.0, above supported 14.0.0", result.stderr)

    def test_accepts_legacy_macos_version_commands(self) -> None:
        result = self.verify(minimum="10.12", legacy=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt["slices"][0]["maximumMinimumMacOS"], "10.12.0")

    def test_rejects_duplicate_archive_members_without_skipping_one(self) -> None:
        result = self.verify(minimum="14.0", duplicate=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate member names", result.stderr)


if __name__ == "__main__":
    unittest.main()
