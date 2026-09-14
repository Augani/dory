#!/usr/bin/env python3
"""Regression coverage for audited manual macOS guest Metal-probe exports."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
VERIFIER = ROOT / "scripts/verify-macos-guest-metal-probe.py"
SOURCE_FILES = (
    "GuestTools/DoryGuestTools/DoryGuestMetalProbe.swift",
    "GuestTools/DoryGuestTools/DoryGuestToolsApp.swift",
    "GuestTools/DoryGuestTools/DoryGuestTools.entitlements",
    "GuestTools/METAL_PROBE.md",
)


def sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def compute_digest() -> str:
    values = [((index * 17) ^ 0x5A5A) + 3 for index in range(1_024)]
    return sha256(b"".join(struct.pack("<I", value) for value in values))


class GuestMetalProbeVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="dory-guest-metal-probe-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.manifest = self.root / "guest-tools-manifest.json"
        self.challenge = self.root / "challenge.json"
        self.result = self.root / "result.json"
        self.output = self.root / "verification.json"
        self.write_json(self.manifest, self.make_manifest())
        self.write_json(self.result, self.make_result())

    @staticmethod
    def write_json(path: Path, value: object) -> None:
        path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")

    def make_manifest(self) -> dict[str, object]:
        source_entries = []
        digest = hashlib.sha256()
        for relative in SOURCE_FILES:
            source_digest = sha256((ROOT / relative).read_bytes())
            source_entries.append({"path": relative, "sha256": source_digest})
            digest.update(f"{relative}\0{source_digest}\n".encode())
        return {
            "schema": "dory.macos-guest-tools-manifest@1",
            "candidateID": "macos-dev-1",
            "sourceCommit": "a" * 40,
            "bundle": {
                "identifier": "com.pythonxi.Dory.GuestTools",
                "version": "1.0.0",
                "build": "1",
                "treeSHA256": "b" * 64,
                "entries": [{"fixture": True}],
            },
            "source": {"treeSHA256": digest.hexdigest(), "entries": source_entries},
            "capabilities": [{"id": "metal-probe", "version": 1}],
            "signing": {"classification": "unsigned-development", "releaseEligible": False},
        }

    @staticmethod
    def make_result() -> dict[str, object]:
        return {
            "schema": "dory.guest-tools.metal-probe@1",
            "createdAt": "2026-09-14T00:00:01Z",
            "nonce": "nonce-1",
            "candidateID": "macos-dev-1",
            "guestOperatingSystemVersion": "26.0.0",
            "guestOperatingSystemBuild": "25A123",
            "guestActiveProcessorCount": 4,
            "guestPhysicalMemoryBytes": 8 * 1024 * 1024 * 1024,
            "guestToolsBundleIdentifier": "com.pythonxi.Dory.GuestTools",
            "guestToolsVersion": "1.0.0",
            "guestToolsBuild": "1",
            "metalDeviceName": "Apple Paravirtual GPU",
            "metalRegistryID": "1",
            "usesUnifiedMemory": True,
            "probeShaderSHA256": "c" * 64,
            "computeOutputSHA256": compute_digest(),
            "renderedPatternSHA256": "d" * 64,
            "computeValueCount": 1_024,
            "renderedWidth": 64,
            "renderedHeight": 64,
            "computeCommandBufferStatus": "completed",
            "renderCommandBufferStatus": "completed",
        }

    def invoke_issue(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable, str(VERIFIER), "issue", "--candidate-id", "macos-dev-1",
                "--machine-id", "machine-1", "--nonce", "nonce-1",
                "--guest-tools-manifest", str(self.manifest), "--output", str(self.challenge),
                "--issued-at", "2026-09-14T00:00:00Z",
            ],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )

    def invoke_verify(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable, str(VERIFIER), "verify", "--challenge", str(self.challenge),
                "--result", str(self.result), "--guest-tools-manifest", str(self.manifest),
                "--source-root", str(ROOT), "--output", str(self.output),
            ],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )

    def issue_challenge(self) -> None:
        completed = self.invoke_issue()
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_verified_export_is_explicit_development_evidence(self) -> None:
        self.issue_challenge()
        completed = self.invoke_verify()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        verification = json.loads(self.output.read_text())
        self.assertEqual(verification["schema"], "dory.macos-guest-metal-probe-verification@1")
        self.assertEqual(verification["status"], "development-observed")
        self.assertFalse(verification["releaseEligible"])
        self.assertEqual(verification["collection"], "audited-manual")
        self.assertEqual(verification["candidateID"], "macos-dev-1")
        self.assertEqual(verification["nonce"], "nonce-1")
        self.assertEqual(verification["observed"]["guestOperatingSystemVersion"], "26.0.0")
        self.assertEqual(verification["observed"]["guestOperatingSystemBuild"], "25A123")
        self.assertEqual(verification["observed"]["guestActiveProcessorCount"], 4)
        self.assertEqual(verification["observed"]["guestPhysicalMemoryBytes"], 8 * 1024 * 1024 * 1024)

    def test_nonce_mismatch_is_rejected(self) -> None:
        self.issue_challenge()
        result = self.make_result()
        result["nonce"] = "wrong-nonce"
        self.write_json(self.result, result)
        completed = self.invoke_verify()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("candidate or nonce", completed.stderr)
        self.assertFalse(self.output.exists())

    def test_missing_guest_operating_system_build_is_rejected(self) -> None:
        self.issue_challenge()
        result = self.make_result()
        del result["guestOperatingSystemBuild"]
        self.write_json(self.result, result)
        completed = self.invoke_verify()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("keys are invalid", completed.stderr)
        self.assertFalse(self.output.exists())

    def test_stale_retained_source_is_rejected(self) -> None:
        manifest = self.make_manifest()
        manifest["source"]["entries"][0]["sha256"] = "e" * 64  # type: ignore[index]
        self.write_json(self.manifest, manifest)
        self.issue_challenge()
        completed = self.invoke_verify()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("retained source", completed.stderr)
        self.assertFalse(self.output.exists())

    def test_ambiguous_result_schema_is_rejected(self) -> None:
        self.issue_challenge()
        result = self.make_result()
        result["unverified"] = True
        self.write_json(self.result, result)
        completed = self.invoke_verify()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("keys are invalid", completed.stderr)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
