#!/usr/bin/env python3
"""Contract tests for the development app source-binding producer."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "scripts/write-development-source-binding.py"


class DevelopmentSourceBindingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="dory-source-binding-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "source"
        self.root.mkdir()
        (self.root / "tracked.txt").write_text("first\n", encoding="utf-8")
        (self.root / "link").symlink_to("tracked.txt")
        self.run_git("init", "-q")
        self.run_git("config", "user.email", "test@example.invalid")
        self.run_git("config", "user.name", "Dory test")
        self.run_git("add", "tracked.txt", "link")
        self.run_git("commit", "-qm", "fixture")
        self.binding = Path(self.temporary.name) / "Dory.app/Contents/Resources/development-source-binding.json"

    def run_git(self, *arguments: str) -> None:
        subprocess.run(["git", "-C", str(self.root), *arguments], check=True)

    def run_tool(self, operation: str, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(TOOL), operation, "--source-root", str(self.root), *arguments],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_clean_snapshot_contains_tracked_regular_and_symlink_entries(self) -> None:
        created = self.run_tool("create", "--output", str(self.binding))
        self.assertEqual(created.returncode, 0, created.stderr)

        payload = json.loads(self.binding.read_text(encoding="utf-8"))
        self.assertEqual(payload["kind"], "dev.dory.development-source-binding")
        self.assertFalse(payload["releaseQualified"])
        self.assertFalse(payload["git"]["worktreeDirty"])
        entries = {entry["path"]: entry for entry in payload["entries"]}
        self.assertEqual(entries["tracked.txt"]["kind"], "regular")
        self.assertEqual(entries["link"]["kind"], "symlink")
        verified = self.run_tool("verify", "--binding", str(self.binding))
        self.assertEqual(verified.returncode, 0, verified.stderr)

    def test_modified_and_untracked_sources_invalidate_a_binding(self) -> None:
        self.assertEqual(self.run_tool("create", "--output", str(self.binding)).returncode, 0)
        (self.root / "tracked.txt").write_text("changed\n", encoding="utf-8")
        changed = self.run_tool("verify", "--binding", str(self.binding))
        self.assertNotEqual(changed.returncode, 0)
        self.assertIn("does not match", changed.stderr)

        self.assertEqual(self.run_tool("create", "--output", str(self.binding)).returncode, 0)
        (self.root / "untracked.txt").write_text("new\n", encoding="utf-8")
        untracked = self.run_tool("verify", "--binding", str(self.binding))
        self.assertNotEqual(untracked.returncode, 0)
        self.assertIn("does not match", untracked.stderr)

    def test_create_rejects_output_symlink_without_overwriting_target(self) -> None:
        target = Path(self.temporary.name) / "preserved.json"
        target.write_text("preserve me")
        self.binding.parent.mkdir(parents=True)
        self.binding.symlink_to(target)
        result = self.run_tool("create", "--output", str(self.binding))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_text(), "preserve me")
        self.assertTrue(self.binding.is_symlink())

    def test_verify_rejects_symlink_even_when_target_binding_is_valid(self) -> None:
        self.assertEqual(self.run_tool("create", "--output", str(self.binding)).returncode, 0)
        link = Path(self.temporary.name) / "binding-link.json"
        link.symlink_to(self.binding)
        result = self.run_tool("verify", "--binding", str(link))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("direct regular file", result.stderr)

    def test_bundle_assembly_preserves_prebuild_identity_and_rejects_source_drift(self) -> None:
        self.assertEqual(self.run_tool("create", "--output", str(self.binding)).returncode, 0)
        script = (ROOT / "scripts/build.sh").read_text()
        start = script.index("write_development_source_binding() {")
        function = script[start:script.index("\n}\n", start) + 3]
        home = Path(self.temporary.name) / "home"
        app = home / "Library/Developer/Xcode/DerivedData/Dory-fixture/Build/Products/Debug/Dory.app"
        app.mkdir(parents=True)
        output = app / "Contents/Resources/development-source-binding.json"
        environment = dict(os.environ, HOME=str(home), ROOT=str(self.root),
            XCODE_CONFIGURATION="Debug", SOURCE_BINDING_INPUT=str(self.binding))
        def assemble():
            return subprocess.run(["bash"], input=function + "\nwrite_development_source_binding\n",
                cwd=ROOT, env=environment, text=True, capture_output=True)
        result = assemble()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_bytes(), self.binding.read_bytes())
        output.unlink()
        (self.root / "tracked.txt").write_text("edited while compiling\n")
        result = assemble()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())

    def test_generated_evidence_does_not_invalidate_a_binding(self) -> None:
        self.assertEqual(self.run_tool("create", "--output", str(self.binding)).returncode, 0)
        evidence = self.root / "docs/virtualization/evidence/wave0/receipt.json"
        evidence.parent.mkdir(parents=True)
        evidence.write_text('{"first": true}\n', encoding="utf-8")
        self.assertEqual(self.run_tool("verify", "--binding", str(self.binding)).returncode, 0)

        evidence.write_text('{"updated": true}\n', encoding="utf-8")
        verified = self.run_tool("verify", "--binding", str(self.binding))
        self.assertEqual(verified.returncode, 0, verified.stderr)

    def test_evidence_commit_preserves_sources_but_not_strict_assembly_identity(self) -> None:
        self.assertEqual(self.run_tool("create", "--output", str(self.binding)).returncode, 0)
        original = self.binding.read_bytes()
        evidence = self.root / "docs/virtualization/evidence/receipt.json"
        evidence.parent.mkdir(parents=True)
        evidence.write_text("{}\n")
        self.run_git("add", ".")
        self.run_git("commit", "-qm", "retain evidence")
        self.assertNotEqual(self.run_tool("verify", "--binding", str(self.binding)).returncode, 0)
        checked = self.run_tool("verify-sources", "--binding", str(self.binding))
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.assertEqual(self.binding.read_bytes(), original)
        (self.root / "tracked.txt").chmod(0o755)
        self.assertNotEqual(self.run_tool("verify-sources", "--binding", str(self.binding)).returncode, 0)

    def test_source_comparison_rejects_content_drift_and_corrupt_capture_metadata(self) -> None:
        self.assertEqual(self.run_tool("create", "--output", str(self.binding)).returncode, 0)
        original = self.binding.read_bytes()
        payload = json.loads(original)
        payload["git"]["headCommit"] = "not-a-commit"
        self.binding.write_text(json.dumps(payload))
        self.assertNotEqual(self.run_tool("verify-sources", "--binding", str(self.binding)).returncode, 0)
        self.binding.write_bytes(original)
        (self.root / "tracked.txt").write_text("different source\n")
        self.run_git("add", ".")
        self.run_git("commit", "-qm", "change source")
        self.assertNotEqual(self.run_tool("verify-sources", "--binding", str(self.binding)).returncode, 0)


if __name__ == "__main__":
    unittest.main()
