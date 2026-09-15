#!/usr/bin/env python3
"""Regression tests for the Wave 0 qualification-matrix admission contract."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "scripts/validate-wave0-qualification-matrix.py"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class MatrixTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="dory-wave0-matrix-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "Config").mkdir()
        (self.root / "guest/out").mkdir(parents=True)
        artifacts = {}
        for name in ("Image-gpu", "mesa-arm.zst", "vmlinux-pc", "mesa-pc.zst"):
            path = self.root / "guest/out" / name
            path.write_bytes(name.encode())
            artifacts[name] = digest(path)
        self.artifacts = artifacts
        catalog = {
            "schemaVersion": 1, "kind": "virtualization-guest-candidates", "selectionDate": "2026-09-08",
            "scope": "fixture", "downloadPolicy": "fixture", "artifacts": [
                {"id": "ubuntu-arm", "family": "debian", "role": "general-purpose", "guest": "linux", "architecture": "arm64"},
                {"id": "fedora-arm", "family": "fedora", "role": "general-purpose", "guest": "linux", "architecture": "arm64"},
                {"id": "ubuntu-x86", "family": "debian", "role": "general-purpose", "guest": "linux", "architecture": "x86_64"},
                {"id": "fedora-x86", "family": "fedora", "role": "general-purpose", "guest": "linux", "architecture": "x86_64"},
                {"id": "macos-26.6.2-25G83-arm64", "family": "macos", "role": "general-purpose", "guest": "macos", "architecture": "arm64"},
            ],
        }
        for artifact in catalog["artifacts"]:
            artifact["sha256"] = hashlib.sha256(artifact["id"].encode()).hexdigest()
        self.catalog_path = self.root / "Config/DoryVirtualizationGuestCandidates.json"
        self.catalog_path.write_text(json.dumps(catalog))
        self.matrix = {
            "schemaVersion": 1, "kind": "dev.dory.wave0-qualification-matrix", "selectionDate": "2026-09-08",
            "selectionStatus": "proposed-review-required", "releaseQualified": False,
            "candidateCatalog": "Config/DoryVirtualizationGuestCandidates.json",
            "candidateCatalogSHA256": digest(self.catalog_path),
            "vendorSupportEvidence": [{"url": "https://ubuntu.example", "subject": "u", "selectionReason": "u"}, {"url": "https://fedora.example", "subject": "f", "selectionReason": "f"}, {"url": "https://apple.example", "subject": "a", "selectionReason": "a"}],
            "hostClasses": [{"id": "host", "architecture": "arm64", "model": "Mac14,10", "soc": "Apple M2 Pro", "memoryMiB": 16384, "operatingSystem": {"version": "26.6.2", "build": "25G83"}, "releaseAdmission": "exact"}],
            "resourceClasses": [{"id": "standard", "guestCPUs": 4, "guestMemoryMiB": 8192, "guestDiskGiB": 64, "display": "x", "workloads": ["boot"]}],
            "cpuProfiles": [{"id": "arm", "architecture": "arm64", "executionOwner": "native", "status": "implementation-only"}, {"id": "x86", "architecture": "x86_64", "executionOwner": "dbt", "status": "implementation-only"}, {"id": "mac", "architecture": "arm64", "executionOwner": "vz", "status": "implementation-only"}],
            "graphicsProfiles": [
                {"id": "arm", "guestArchitecture": "arm64", "guestPageKiB": 16, "hostPath": "metal", "kernel": {"path": "guest/out/Image-gpu", "sha256": artifacts["Image-gpu"]}, "mesa": {"path": "guest/out/mesa-arm.zst", "sha256": artifacts["mesa-arm.zst"]}, "status": "unqualified"},
                {"id": "x86", "guestArchitecture": "x86_64", "guestPageKiB": 4, "hostPath": "metal", "kernel": {"path": "guest/out/vmlinux-pc", "sha256": artifacts["vmlinux-pc"]}, "mesa": {"path": "guest/out/mesa-pc.zst", "sha256": artifacts["mesa-pc.zst"]}, "status": "unqualified"},
                {"id": "mac", "guestArchitecture": "arm64", "guestPageKiB": 16, "hostPath": "metal", "status": "unqualified"},
            ],
            "guestCells": [
                {"id": "ua", "guest": "linux", "architecture": "arm64", "mediaID": "ubuntu-arm", "cpuProfile": "arm", "resourceClasses": ["standard"], "graphicsProfiles": ["arm"]},
                {"id": "fa", "guest": "linux", "architecture": "arm64", "mediaID": "fedora-arm", "cpuProfile": "arm", "resourceClasses": ["standard"], "graphicsProfiles": ["arm"]},
                {"id": "ux", "guest": "linux", "architecture": "x86_64", "mediaID": "ubuntu-x86", "cpuProfile": "x86", "resourceClasses": ["standard"], "graphicsProfiles": ["x86"]},
                {"id": "fx", "guest": "linux", "architecture": "x86_64", "mediaID": "fedora-x86", "cpuProfile": "x86", "resourceClasses": ["standard"], "graphicsProfiles": ["x86"]},
                {"id": "mac", "guest": "macos", "architecture": "arm64", "mediaID": "macos-26.6.2-25G83-arm64", "cpuProfile": "mac", "resourceClasses": ["standard"], "graphicsProfiles": ["mac"]},
            ],
            "review": {"status": "pending", "requiredApprovals": ["release owner", "runtime owner", "security reviewer"], "approvalRule": "exact", "approvals": []},
        }

    def invoke(self, matrix: dict[str, object], approved: bool = False) -> subprocess.CompletedProcess[str]:
        path = self.root / "Config/matrix.json"
        path.write_text(json.dumps(matrix))
        command = [sys.executable, str(VALIDATOR), "--matrix", str(path), "--source-root", str(self.root)]
        if approved:
            command.append("--require-approved")
        return subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)

    def test_valid_matrix_stays_review_pending(self) -> None:
        result = self.invoke(self.matrix)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "review-pending")

    def test_rejects_a_missing_linux_family(self) -> None:
        matrix = json.loads(json.dumps(self.matrix))
        matrix["guestCells"][1]["mediaID"] = "ubuntu-arm"
        result = self.invoke(matrix)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("lacks two immutable", result.stderr)

    def test_requires_named_approval_for_release_use(self) -> None:
        result = self.invoke(self.matrix, approved=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("has not received", result.stderr)

    def approved_matrix(self):
        matrix = json.loads(json.dumps(self.matrix))
        result = self.invoke(matrix)
        self.assertEqual(result.returncode, 0, result.stderr)
        content_digest = json.loads(result.stdout)["approvalPayloadSHA256"]
        matrix["selectionStatus"] = "approved"
        matrix["review"]["status"] = "approved"
        matrix["review"]["approvals"] = [
            {"role": role, "reviewer": "fixture-" + str(index),
             "reviewedAt": "2026-09-08T12:00:00Z",
             "evidenceURL": "https://example.invalid/review/" + str(index),
             "payloadSHA256": content_digest}
            for index, role in enumerate(matrix["review"]["requiredApprovals"])
        ]
        return matrix

    def test_approval_records_bind_exact_content(self):
        matrix = self.approved_matrix()
        result = self.invoke(matrix, approved=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        matrix["resourceClasses"][0]["guestCPUs"] = 8
        result = self.invoke(matrix, approved=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not bind", result.stderr)

    def test_status_flags_cannot_replace_review_records(self):
        matrix = self.approved_matrix()
        matrix["review"]["approvals"] = []
        result = self.invoke(matrix, approved=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("lacks required review records", result.stderr)

    def test_duplicate_reviewer_role_cannot_satisfy_three_approvals(self):
        matrix = self.approved_matrix()
        matrix["review"]["approvals"][1] = matrix["review"]["approvals"][0]
        result = self.invoke(matrix, approved=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown or repeated", result.stderr)

    def test_catalog_replacement_invalidates_binding(self):
        catalog = json.loads(self.catalog_path.read_text())
        catalog["artifacts"][0]["sha256"] = "a" * 64
        self.catalog_path.write_text(json.dumps(catalog))
        result = self.invoke(self.matrix)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("catalog digest mismatch", result.stderr)

    def test_missing_media_digest_is_rejected_even_with_matching_catalog(self):
        catalog = json.loads(self.catalog_path.read_text())
        del catalog["artifacts"][0]["sha256"]
        self.catalog_path.write_text(json.dumps(catalog))
        self.matrix["candidateCatalogSHA256"] = digest(self.catalog_path)
        result = self.invoke(self.matrix)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("media digest", result.stderr)

    def test_cross_architecture_profiles_are_rejected(self):
        for key, value in [("cpuProfile", "x86"), ("graphicsProfiles", ["x86"])]:
            with self.subTest(key=key):
                matrix = json.loads(json.dumps(self.matrix))
                matrix["guestCells"][0][key] = value
                result = self.invoke(matrix)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("architecture mismatch", result.stderr)

    def test_duplicate_resource_or_graphics_selection_is_rejected(self):
        for key in ["resourceClasses", "graphicsProfiles"]:
            with self.subTest(key=key):
                matrix = json.loads(json.dumps(self.matrix))
                matrix["guestCells"][0][key] *= 2
                result = self.invoke(matrix)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unique known", result.stderr)

    def test_artifact_cannot_escape_source_root(self):
        self.matrix["graphicsProfiles"][0]["kernel"]["path"] = "../outside"
        result = self.invoke(self.matrix)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("within the source root", result.stderr)

    def test_artifact_cannot_follow_a_symlinked_parent_outside_source_root(self):
        with tempfile.TemporaryDirectory(prefix="dory-outside-matrix-") as outside:
            outside_path = Path(outside)
            artifact = outside_path / "Image-gpu"
            artifact.write_bytes(b"Image-gpu")
            (self.root / "guest/alias").symlink_to(outside_path, target_is_directory=True)
            self.matrix["graphicsProfiles"][0]["kernel"]["path"] = "guest/alias/Image-gpu"
            result = self.invoke(self.matrix)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must not traverse symbolic links", result.stderr)

    def test_catalog_cannot_follow_a_symlinked_parent(self):
        (self.root / "Config").rename(self.root / "real-config")
        (self.root / "Config").symlink_to(self.root / "real-config", target_is_directory=True)
        result = self.invoke(self.matrix)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must not traverse symbolic links", result.stderr)

    def test_selection_date_must_exist_in_the_calendar(self):
        self.matrix["selectionDate"] = "2026-02-30"
        result = self.invoke(self.matrix)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("valid calendar date", result.stderr)

    def test_unpinned_graphics_are_visible_and_cannot_be_approved(self):
        del self.matrix["graphicsProfiles"][0]["kernel"]
        result = self.invoke(self.matrix)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["unpinnedGraphicsInputs"], ["arm.kernel"])
        result = self.invoke(self.approved_matrix(), approved=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unpinned graphics inputs", result.stderr)


if __name__ == "__main__":
    unittest.main()
