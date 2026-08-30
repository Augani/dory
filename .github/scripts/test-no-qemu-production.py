#!/usr/bin/env python3
"""Offline regression tests for Dory's no-QEMU source and artifact gate."""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / ".github/scripts/verify-no-qemu-production.py"


def load_auditor():
    specification = importlib.util.spec_from_file_location("no_qemu_auditor", SCRIPT)
    if specification is None or specification.loader is None:
        raise RuntimeError("cannot load no-QEMU auditor")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


AUDITOR = load_auditor()


class NoQEMUProductionTests(unittest.TestCase):
    def write_manifest(self, root: Path, entries: list[dict[str, object]]) -> Path:
        manifest = root / "debt.json"
        manifest.write_text(
            json.dumps({"schemaVersion": 1, "entries": entries}), encoding="utf-8"
        )
        return manifest

    def test_repository_matches_reviewed_debt_ceiling(self) -> None:
        AUDITOR.audit_source(
            ROOT, ROOT / "docs/virtualization/no-qemu-source-debt.json"
        )

    def test_pull_request_and_release_workflows_enforce_the_gate(self) -> None:
        tests = (ROOT / ".github/workflows/tests.yml").read_text(encoding="utf-8")
        release = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        self.assertIn("python3 .github/scripts/test-no-qemu-production.py", tests)
        self.assertIn("Reject prohibited runtime artifacts", release)
        self.assertIn("python3 .github/scripts/verify-no-qemu-production.py", release)
        self.assertIn('--artifact-root "${{ steps.sparkle_candidate.outputs.app }}"', release)

    def test_new_source_surface_and_debt_growth_fail(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "Dory/Models/Models.swift"
            source.parent.mkdir(parents=True)
            source.write_text('let legacy = "qemu-hvf"\n', encoding="utf-8")
            empty = self.write_manifest(root, [])
            with self.assertRaisesRegex(AUDITOR.AuditFailure, "new persisted-identity"):
                AUDITOR.audit_source(root, empty)

            allowed = self.write_manifest(
                root,
                [{
                    "category": "persisted-identity",
                    "path": "Dory/Models/Models.swift",
                    "maximumOccurrences": 1,
                    "disposition": "remove",
                }],
            )
            AUDITOR.audit_source(root, allowed)
            source.write_text('let a = "qemu-hvf"\nlet b = "qemu-hvf"\n', encoding="utf-8")
            with self.assertRaisesRegex(AUDITOR.AuditFailure, "debt grew"):
                AUDITOR.audit_source(root, allowed)

    def test_artifact_audit_rejects_names_and_contents(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            clean = root / "Dory.app/Contents/MacOS/Dory"
            clean.parent.mkdir(parents=True)
            clean.write_bytes(b"dory native runtime")
            AUDITOR.audit_artifact(root)

            clean.write_bytes(b"embedded qemu-system-aarch64 dependency")
            with self.assertRaisesRegex(AUDITOR.AuditFailure, "artifact content"):
                AUDITOR.audit_artifact(root)
            clean.write_bytes(b"clean again")
            forbidden_name = root / "Dory.app/Contents/Helpers/qemu-img"
            forbidden_name.parent.mkdir(parents=True, exist_ok=True)
            forbidden_name.write_bytes(b"tool")
            with self.assertRaisesRegex(AUDITOR.AuditFailure, "artifact path"):
                AUDITOR.audit_artifact(root)


if __name__ == "__main__":
    unittest.main()
