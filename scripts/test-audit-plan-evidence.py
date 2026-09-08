#!/usr/bin/env python3
"""Contract tests for the historical PLAN evidence auditor."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
AUDITOR = ROOT / "scripts/audit-plan-evidence.py"


class PlanEvidenceAuditTests(unittest.TestCase):
    def make_root(self) -> tuple[tempfile.TemporaryDirectory[str], Path]:
        temporary = tempfile.TemporaryDirectory(prefix="dory-plan-evidence-audit-")
        root = Path(temporary.name)
        (root / "docs/virtualization/evidence/receipt").mkdir(parents=True)
        return temporary, root

    def run_audit(self, root: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(AUDITOR), "--root", str(root), *arguments],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def plan(self, root: Path, links: str) -> None:
        (root / "PLAN.md").write_text(
            "### Evidence worth reading first\n\n" + links + "\n\n## Next section\n"
        )

    def test_preserves_json_jsonl_and_hashed_attachments(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        receipt = root / "docs/virtualization/evidence/receipt/result.json"
        log = receipt.parent / "result.log"
        log.write_bytes(b"raw result\n")
        receipt.write_text(json.dumps({"artifactSHA256": {"result.log": hashlib.sha256(log.read_bytes()).hexdigest()}}))
        smoke = receipt.parent / "smoke.jsonl"
        smoke.write_text('{"event":"ready"}\n')
        self.plan(
            root,
            "[receipt](docs/virtualization/evidence/receipt/result.json) "
            "[smoke](docs/virtualization/evidence/receipt/smoke.jsonl)",
        )

        result = self.run_audit(root, "--require-complete")

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["incompleteDocuments"], [])
        self.assertEqual(
            [document["status"] for document in payload["documents"]],
            ["preserved", "preserved-jsonl"],
        )

    def test_classifies_missing_and_tampered_artifacts_without_passing_them(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        receipt = root / "docs/virtualization/evidence/receipt/result.json"
        receipt.write_text(
            json.dumps(
                {
                    "artifactSHA256": {"missing.log": "a" * 64},
                    "artifacts": [{"file": "outside.log", "sha256": "b" * 64}],
                }
            )
        )
        (receipt.parent / "outside.log").write_bytes(b"wrong bytes")
        self.plan(root, "docs/virtualization/evidence/receipt/result.json")

        result = self.run_audit(root, "--require-complete")

        self.assertEqual(result.returncode, 1, result.stderr)
        payload = json.loads(result.stdout)
        document = payload["documents"][0]
        self.assertEqual(document["status"], "incomplete-local-payload")
        self.assertEqual(
            {attachment["status"] for attachment in document["attachments"]},
            {"unavailable", "mismatch"},
        )

    def test_rejects_attachment_paths_that_escape_the_receipt_directory(self) -> None:
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        receipt = root / "docs/virtualization/evidence/receipt/result.json"
        receipt.write_text(json.dumps({"artifactSHA256": {"../other.log": "a" * 64}}))
        self.plan(root, "docs/virtualization/evidence/receipt/result.json")

        result = self.run_audit(root, "--require-complete")

        self.assertEqual(result.returncode, 1, result.stderr)
        attachment = json.loads(result.stdout)["documents"][0]["attachments"][0]
        self.assertEqual(attachment["status"], "unsafe-relative-path")

    def test_symlinked_receipt_is_not_promoted_to_preserved(self):
        temporary, root = self.make_root()
        self.addCleanup(temporary.cleanup)
        target = root / "docs/virtualization/evidence/receipt/real.jsonl"
        target.write_text('{"event":"ready"}\n')
        alias = target.with_name("alias.jsonl")
        alias.symlink_to(target)
        self.plan(root, "docs/virtualization/evidence/receipt/alias.jsonl")
        result = self.run_audit(root, "--require-complete")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(json.loads(result.stdout)["documents"][0]["status"], "unavailable")


if __name__ == "__main__":
    unittest.main()
