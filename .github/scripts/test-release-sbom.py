#!/usr/bin/env python3
"""Offline security regressions for exact Dory.app CycloneDX evidence."""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GENERATOR = ROOT / "scripts" / "generate-release-sbom.py"
VERIFIER = ROOT / "scripts" / "verify-release-sbom.py"
VERSION = "9.8.7"
COMMIT = "a" * 40


class ReleaseSBOMTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory(prefix="dory-release-sbom-test.")
        self.root = pathlib.Path(self.directory.name)
        self.app = self.root / "Dory.app"
        executable = self.app / "Contents" / "MacOS" / "Dory"
        resource = self.app / "Contents" / "Resources" / "payload.txt"
        executable.parent.mkdir(parents=True)
        resource.parent.mkdir(parents=True)
        executable.write_bytes(b"candidate executable\n")
        executable.chmod(0o755)
        resource.write_bytes(b"candidate payload\n")
        os.symlink("payload.txt", resource.parent / "payload-current.txt")
        self.sbom = self.root / "Dory.cdx.json"

    def tearDown(self) -> None:
        self.directory.cleanup()

    def run_generator(self, output: pathlib.Path | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "python3",
                str(GENERATOR),
                "--app",
                str(self.app),
                "--version",
                VERSION,
                "--source-commit",
                COMMIT,
                "--output",
                str(output or self.sbom),
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    def run_verifier(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "python3",
                str(VERIFIER),
                "--sbom",
                str(self.sbom),
                "--app",
                str(self.app),
                "--version",
                VERSION,
                "--source-commit",
                COMMIT,
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    def test_exact_tree_round_trip_is_deterministic_and_portable(self) -> None:
        generated = self.run_generator()
        self.assertEqual(generated.returncode, 0, generated.stderr)
        first = self.sbom.read_bytes()
        second_path = self.root / "second.cdx.json"
        regenerated = self.run_generator(second_path)
        self.assertEqual(regenerated.returncode, 0, regenerated.stderr)
        self.assertEqual(first, second_path.read_bytes())
        self.assertNotIn(str(self.root).encode(), first)
        verified = self.run_verifier()
        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.assertIn("PASS", verified.stdout)

    def test_file_mutation_invalidates_the_inventory(self) -> None:
        self.assertEqual(self.run_generator().returncode, 0)
        with (self.app / "Contents" / "MacOS" / "Dory").open("ab") as handle:
            handle.write(b"tampered\n")
        verified = self.run_verifier()
        self.assertNotEqual(verified.returncode, 0)
        self.assertIn("does not exactly inventory", verified.stderr)

    def test_symlink_mutation_invalidates_the_inventory(self) -> None:
        self.assertEqual(self.run_generator().returncode, 0)
        link = self.app / "Contents" / "Resources" / "payload-current.txt"
        link.unlink()
        os.symlink("../MacOS/Dory", link)
        verified = self.run_verifier()
        self.assertNotEqual(verified.returncode, 0)
        self.assertIn("does not exactly inventory", verified.stderr)

    def test_symlink_that_escapes_the_app_is_rejected(self) -> None:
        link = self.app / "Contents" / "Resources" / "payload-current.txt"
        link.unlink()
        os.symlink(str(self.root / "outside"), link)
        (self.root / "outside").write_bytes(b"outside\n")
        generated = self.run_generator()
        self.assertNotEqual(generated.returncode, 0)
        self.assertIn("absolute symlink", generated.stderr)

    def test_unknown_sbom_field_is_rejected(self) -> None:
        self.assertEqual(self.run_generator().returncode, 0)
        document = json.loads(self.sbom.read_text(encoding="utf-8"))
        document["unexpected"] = True
        self.sbom.write_text(json.dumps(document) + "\n", encoding="utf-8")
        verified = self.run_verifier()
        self.assertNotEqual(verified.returncode, 0)
        self.assertIn("shape is invalid", verified.stderr)

    def test_output_inside_the_app_is_rejected(self) -> None:
        output = self.app / "Contents" / "Resources" / "Dory.cdx.json"
        generated = self.run_generator(output)
        self.assertNotEqual(generated.returncode, 0)
        self.assertIn("outside Dory.app", generated.stderr)
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
