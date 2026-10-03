#!/usr/bin/env python3
"""Regression coverage for manual and VZ-socket macOS guest Metal evidence."""

from __future__ import annotations

import hashlib
import binascii
import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile
import textwrap
import unittest
import zlib


ROOT = Path(__file__).resolve().parents[1]
VERIFIER = ROOT / "scripts/verify-macos-guest-metal-probe.py"
VERIFIER_SPEC = importlib.util.spec_from_file_location("dory_macos_metal_verifier", VERIFIER)
assert VERIFIER_SPEC is not None and VERIFIER_SPEC.loader is not None
VERIFIER_MODULE = importlib.util.module_from_spec(VERIFIER_SPEC)
VERIFIER_SPEC.loader.exec_module(VERIFIER_MODULE)
SOURCE_FILES = (
    "GuestTools/DoryGuestTools/DoryGuestFilePublication.swift",
    "GuestTools/DoryGuestTools/DoryGuestIntegrationClient.swift",
    "GuestTools/DoryGuestTools/DoryGuestMetalProbe.swift",
    "GuestTools/DoryGuestTools/DoryGuestMetalProbeTransport.swift",
    "GuestTools/DoryGuestTools/DoryGuestToolsApp.swift",
    "GuestTools/DoryGuestTools/DoryGuestTools.entitlements",
    "GuestTools/METAL_PROBE.md",
    "GuestTools/Packaging/com.pythonxi.Dory.GuestTools.agent.plist",
    "GuestTools/Packaging/dory-guest-tools-maintenance.sh",
    "dory-core-swift/Sources/DoryMacGuestIntegrationWire/DoryMacGuestIntegrationWire.swift",
)


def sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def compute_digest() -> str:
    values = [((index * 17) ^ 0x5A5A) + 3 for index in range(1_024)]
    return sha256(b"".join(struct.pack("<I", value) for value in values))


def png_chunk(kind: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload)) + kind + payload
        + struct.pack(">I", binascii.crc32(kind + payload) & 0xFFFF_FFFF)
    )


class GuestMetalProbeVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="dory-guest-metal-probe-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.manifest = self.root / "guest-tools-manifest.json"
        self.challenge = self.root / "challenge.json"
        self.result = self.root / "result.json"
        self.transport = self.root / "result.transport.json"
        self.capture = self.root / "product-window.png"
        self.capture_receipt = self.root / "product-window.json"
        self.output = self.root / "verification.json"
        self.write_json(self.manifest, self.make_manifest())
        self.write_json(self.result, self.make_result())

    @staticmethod
    def write_json(path: Path, value: object) -> None:
        path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")

    def make_manifest(self) -> dict[str, object]:
        source_entries = []
        digest = hashlib.sha256()
        for relative in sorted(SOURCE_FILES, key=lambda item: item.encode("utf-8")):
            source_digest = sha256((ROOT / relative).read_bytes())
            source_entries.append({"path": relative, "sha256": source_digest})
            digest.update(f"{relative}\0{source_digest}\n".encode())
        return {
            "schema": "dory.macos-guest-tools-manifest@2",
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
            "capabilities": [
                {"id": "clipboard-image-read", "version": 2},
                {"id": "clipboard-image-write", "version": 2},
                {"id": "clipboard-text-read", "version": 2},
                {"id": "clipboard-text-write", "version": 2},
                {"id": "file-pull", "version": 2},
                {"id": "file-push", "version": 2},
                {"id": "guest-time", "version": 2},
                {"id": "health", "version": 2},
                {"id": "metal-probe", "version": 2},
                {"id": "open-url", "version": 2},
            ],
            "signing": {"classification": "unsigned-development", "releaseEligible": False},
        }

    @staticmethod
    def make_result() -> dict[str, object]:
        return {
            "schema": "dory.guest-tools.metal-probe@2",
            "createdAt": "2026-09-14T00:00:01Z",
            "nonce": "nonce-1",
            "candidateID": "macos-dev-1",
            "machineID": "machine-1",
            "operationID": "operation-1",
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
            "probeShaderSHA256": VERIFIER_MODULE.approved_shader_digest(),
            "computeOutputSHA256": compute_digest(),
            "renderedPatternSHA256": VERIFIER_MODULE.rendered_pattern_digests("nonce-1")["native"],
            "visualChallenge": VERIFIER_MODULE.visual_challenge("nonce-1"),
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
                "--operation-id", "operation-1",
                "--guest-tools-manifest", str(self.manifest), "--output", str(self.challenge),
                "--issued-at", "2026-09-14T00:00:00Z",
            ],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )

    def invoke_verify(
        self, transport: bool = False, window: bool = False
    ) -> subprocess.CompletedProcess[str]:
        arguments = [
                sys.executable, str(VERIFIER), "verify", "--challenge", str(self.challenge),
                "--result", str(self.result), "--guest-tools-manifest", str(self.manifest),
                "--source-root", str(ROOT), "--output", str(self.output),
            ]
        if transport:
            arguments += ["--transport-receipt", str(self.transport)]
        if window:
            arguments += [
                "--window-capture", str(self.capture),
                "--window-capture-receipt", str(self.capture_receipt),
            ]
        return subprocess.run(
            arguments,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )

    def issue_challenge(self) -> None:
        completed = self.invoke_issue()
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def write_transport_receipt(self) -> None:
        payload = self.result.read_bytes()
        self.write_json(self.transport, {
            "schema": "dory.macos-guest-metal-probe-transport@3",
            "collectedAt": "2026-09-14T00:00:02Z",
            "collectedMonotonicNanoseconds": 2_000_000_000,
            "collection": "vz-virtio-socket",
            "candidateID": "macos-dev-1",
            "machineID": "machine-1",
            "operationID": "operation-1",
            "nonce": "nonce-1",
            "resultSHA256": sha256(payload),
            "resultByteCount": len(payload),
        })

    def write_window_capture(
        self, blank: bool = False, inverted: bool = False, corrupt_background: bool = False
    ) -> None:
        width, height = 640, 360
        viewport = (80, 60, 480, 180)
        pixels = bytearray((18, 20, 24, 255) * (width * height))
        if not blank:
            x0, y0, viewport_width, viewport_height = viewport
            for local_y in range(viewport_height):
                sampled_y = viewport_height - 1 - local_y if inverted else local_y
                shader_y = min(63, sampled_y * 64 // viewport_height)
                for local_x in range(viewport_width):
                    shader_x = min(63, local_x * 64 // viewport_width)
                    marker_x = shader_x - 8
                    marker_y = shader_y - 12
                    if 0 <= marker_x < 48 and 0 <= marker_y < 40:
                        color = VERIFIER_MODULE.marker_color(
                            marker_x // 4, marker_y // 4, "nonce-1"
                        )
                    elif corrupt_background:
                        color = (18, 20, 24)
                    else:
                        color = (
                            (13, 191, 242)
                            if ((shader_x >> 3) ^ (shader_y >> 3)) & 1
                            else (230, 51, 89)
                        )
                    offset = ((y0 + local_y) * width + x0 + local_x) * 4
                    pixels[offset : offset + 4] = bytes((*color, 255))
        rows = b"".join(
            b"\x00" + pixels[row * width * 4 : (row + 1) * width * 4]
            for row in range(height)
        )
        payload = (
            b"\x89PNG\r\n\x1a\n"
            + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + png_chunk(b"IDAT", zlib.compress(rows))
            + png_chunk(b"IEND", b"")
        )
        self.capture.write_bytes(payload)
        self.write_json(self.capture_receipt, {
            "schema": "dory.macos-guest-metal-window-capture@2",
            "capturedAt": "2026-09-14T00:00:03Z",
            "capturedMonotonicNanoseconds": 3_000_000_000,
            "captureScope": "selected-vzmac-product-window",
            "candidateID": "macos-dev-1",
            "machineID": "machine-1",
            "operationID": "operation-1",
            "nonce": "nonce-1",
            "challengeSHA256": sha256(self.challenge.read_bytes()),
            "resultSHA256": sha256(self.result.read_bytes()),
            "captureSHA256": sha256(payload),
            "captureByteCount": len(payload),
            "captureWidth": width,
            "captureHeight": height,
            "guestPreview": {
                "coordinateSpace": "capture-pixels-top-left",
                "x": viewport[0], "y": viewport[1],
                "width": viewport[2], "height": viewport[3],
                "sourceWidth": viewport[2], "sourceHeight": viewport[3],
                "backingScaleFactor": 1.0,
                "colorSpace": "sRGB",
            },
            "windowProcessIdentifier": 1234,
            "windowNumber": 7,
        })

    def test_verified_export_is_explicit_development_evidence(self) -> None:
        self.issue_challenge()
        completed = self.invoke_verify()
        self.assertEqual(completed.returncode, 0, completed.stderr)
        verification = json.loads(self.output.read_text())
        self.assertEqual(verification["schema"], "dory.macos-guest-metal-probe-verification@2")

        self.assertEqual(verification["status"], "development-observed")
        self.assertFalse(verification["releaseEligible"])
        self.assertEqual(verification["collection"], "audited-manual")
        self.assertEqual(verification["candidateID"], "macos-dev-1")
        self.assertEqual(verification["nonce"], "nonce-1")
        self.assertEqual(verification["operationID"], "operation-1")
        self.assertEqual(verification["observed"]["machineID"], "machine-1")
        self.assertEqual(verification["observed"]["guestOperatingSystemVersion"], "26.0.0")
        self.assertEqual(verification["observed"]["guestOperatingSystemBuild"], "25A123")
        self.assertEqual(verification["observed"]["guestActiveProcessorCount"], 4)
        self.assertEqual(verification["observed"]["guestPhysicalMemoryBytes"], 8 * 1024 * 1024 * 1024)

    def test_generated_manifest_is_accepted_by_metal_verifier(self) -> None:
        app = self.root / "DoryGuestTools.app"
        binary = app / "Contents/MacOS/DoryGuestTools"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"guest-tools-test-binary")
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.pythonxi.Dory.GuestTools",
            "CFBundleExecutable": "DoryGuestTools",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
        }))
        generated = subprocess.run([
            sys.executable, str(ROOT / "scripts/generate-macos-guest-tools-manifest.py"),
            "--app", str(app), "--candidate-id", "macos-dev-1",
            "--source-commit", "a" * 40, "--source-root", str(ROOT),
            "--output", str(self.manifest), "--allow-unsigned-development",
        ], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        self.assertEqual(generated.returncode, 0, generated.stderr)
        self.issue_challenge()
        completed = self.invoke_verify()
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_older_manifest_schema_is_not_current_probe_evidence(self) -> None:
        self.issue_challenge()
        manifest = self.make_manifest()
        manifest["schema"] = "dory.macos-guest-tools-manifest@1"
        self.write_json(self.manifest, manifest)
        completed = self.invoke_verify()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("manifest schema is unsupported", completed.stderr)

    def test_ambiguous_or_nonfinite_json_is_rejected_before_proof(self) -> None:
        self.issue_challenge()
        original = self.challenge.read_text()
        self.challenge.write_text(original.replace(
            '"nonce": "nonce-1",',
            '"nonce": "nonce-1",\n  "nonce": "nonce-1",',
            1,
        ))
        completed = self.invoke_verify()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("duplicate JSON key", completed.stderr)

        self.challenge.write_text(original)
        self.result.write_text(self.result.read_text().replace(
            '"guestActiveProcessorCount": 4',
            '"guestActiveProcessorCount": NaN',
            1,
        ))
        completed = self.invoke_verify()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("non-finite JSON number", completed.stderr)

    def test_vz_socket_receipt_proves_machine_bound_collection(self) -> None:
        self.issue_challenge()
        self.write_transport_receipt()
        completed = self.invoke_verify(transport=True)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        verification = json.loads(self.output.read_text())
        self.assertEqual(verification["status"], "transport-collected")
        self.assertEqual(verification["collection"], "vz-virtio-socket")
        self.assertFalse(verification["releaseEligible"])
        self.assertEqual(len(verification["limitations"]), 2)

    def test_decoded_product_window_binds_current_visual_challenge(self) -> None:
        self.issue_challenge()
        self.write_transport_receipt()
        self.write_window_capture()
        completed = self.invoke_verify(transport=True, window=True)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        verification = json.loads(self.output.read_text())
        self.assertEqual(verification["status"], "window-correlated")
        self.assertEqual(verification["collection"], "vz-virtio-socket+product-window")
        self.assertEqual(verification["windowCapture"]["markerOrientation"], "native")
        self.assertFalse(verification["releaseEligible"])

    def test_product_window_requires_host_monotonic_capture_timestamp(self) -> None:
        self.issue_challenge()
        self.write_transport_receipt()
        self.write_window_capture()
        receipt = json.loads(self.capture_receipt.read_text())
        for value in (None, True, 0, -1, "3000000000"):
            with self.subTest(value=value):
                receipt["capturedMonotonicNanoseconds"] = value
                self.write_json(self.capture_receipt, receipt)
                completed = self.invoke_verify(transport=True, window=True)
                self.assertNotEqual(completed.returncode, 0)
                self.assertIn("capturedMonotonicNanoseconds is invalid", completed.stderr)
                self.assertFalse(self.output.exists())

    def test_transport_requires_host_monotonic_collection_timestamp(self) -> None:
        self.issue_challenge()
        self.write_transport_receipt()
        receipt = json.loads(self.transport.read_text())
        for value in (None, True, 0, -1, "2000000000"):
            with self.subTest(value=value):
                receipt["collectedMonotonicNanoseconds"] = value
                self.write_json(self.transport, receipt)
                completed = self.invoke_verify(transport=True)
                self.assertNotEqual(completed.returncode, 0)
                self.assertIn("collectedMonotonicNanoseconds is invalid", completed.stderr)
                self.assertFalse(self.output.exists())

    def test_product_window_must_follow_collection_on_host_monotonic_clock(self) -> None:
        self.issue_challenge()
        self.write_transport_receipt()
        self.write_window_capture()
        receipt = json.loads(self.capture_receipt.read_text())
        receipt["capturedMonotonicNanoseconds"] = 1_000_000_000
        self.write_json(self.capture_receipt, receipt)
        completed = self.invoke_verify(transport=True, window=True)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("does not follow guest result collection on the host monotonic clock", completed.stderr)
        self.assertFalse(self.output.exists())

    def test_host_evidence_must_follow_the_challenge_and_collection(self) -> None:
        self.issue_challenge()
        self.write_transport_receipt()
        self.write_window_capture()
        transport = json.loads(self.transport.read_text())
        capture = json.loads(self.capture_receipt.read_text())
        transport["collectedAt"] = "2026-09-13T23:59:59Z"
        self.write_json(self.transport, transport)
        completed = self.invoke_verify(transport=True, window=True)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("transport receipt predates the host challenge", completed.stderr)
        self.assertFalse(self.output.exists())

        transport["collectedAt"] = "2026-09-14T00:00:02Z"
        self.write_json(self.transport, transport)
        capture["capturedAt"] = "2026-09-14T00:00:01Z"
        self.write_json(self.capture_receipt, capture)
        completed = self.invoke_verify(transport=True, window=True)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("capture predates guest result collection", completed.stderr)
        self.assertFalse(self.output.exists())

        capture["capturedAt"] = "2026-09-13T23:59:59Z"
        self.write_json(self.capture_receipt, capture)
        completed = self.invoke_verify(window=True)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("capture predates the host challenge", completed.stderr)
        self.assertFalse(self.output.exists())

    def test_host_evidence_timestamps_require_offsets(self) -> None:
        self.issue_challenge()
        self.write_transport_receipt()
        transport = json.loads(self.transport.read_text())
        transport["collectedAt"] = "2026-09-14T00:00:02"
        self.write_json(self.transport, transport)
        completed = self.invoke_verify(transport=True)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("must include a UTC offset", completed.stderr)
        self.assertFalse(self.output.exists())

    def test_vertically_inverted_product_window_is_rejected(self) -> None:
        self.issue_challenge()
        self.write_window_capture(inverted=True)
        completed = self.invoke_verify(window=True)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("vertically inverted", completed.stderr)
        self.assertFalse(self.output.exists())

    def test_vertically_inverted_render_digest_is_rejected(self) -> None:
        self.issue_challenge()
        result = self.make_result()
        result["renderedPatternSHA256"] = (
            VERIFIER_MODULE.rendered_pattern_digests("nonce-1")["vertically-inverted"]
        )
        self.write_json(self.result, result)
        completed = self.invoke_verify()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("checkerboard oracle", completed.stderr)

    def test_approved_shader_source_matches_guest_source(self) -> None:
        source = (ROOT / "GuestTools/DoryGuestTools/DoryGuestMetalProbe.swift").read_text()
        shader = source.split('private static let shaderSource = """\n', 1)[1]
        shader = shader.split('\n    """', 1)[0]
        self.assertEqual(textwrap.dedent(shader), VERIFIER_MODULE.APPROVED_SHADER_SOURCE)

    @unittest.skipUnless(sys.platform == "darwin", "host Metal is only available on macOS")
    def test_host_metal_shader_pixels_match_independent_oracle(self) -> None:
        expected = VERIFIER_MODULE.rendered_pattern_digests("nonce-1")["native"]
        completed = subprocess.run(
            [
                "swift", str(ROOT / "scripts/check-macos-guest-metal-shader.swift"),
                str(ROOT / "GuestTools/DoryGuestTools/DoryGuestMetalProbe.swift"),
                "nonce-1", expected,
            ],
            cwd=ROOT, capture_output=True, text=True, check=False, timeout=60,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stdout.strip(), expected)

    def test_self_consistent_blank_product_window_is_rejected(self) -> None:
        self.issue_challenge()
        self.write_window_capture(blank=True)
        completed = self.invoke_verify(window=True)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("do not contain the current nonce", completed.stderr)
        self.assertFalse(self.output.exists())

    def test_rehashed_marker_only_product_window_is_rejected(self) -> None:
        self.issue_challenge()
        self.write_window_capture(corrupt_background=True)
        completed = self.invoke_verify(window=True)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("do not contain the approved checkerboard", completed.stderr)
        self.assertFalse(self.output.exists())

    def test_oversized_guest_result_is_rejected_before_reading(self) -> None:
        self.issue_challenge()
        with self.result.open("wb") as destination:
            destination.truncate(8 * 1024 * 1024 + 1)
        completed = self.invoke_verify()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("exceeds the supported byte bound", completed.stderr)
        self.assertFalse(self.output.exists())

    def test_oversized_product_window_is_rejected_before_reading(self) -> None:
        self.issue_challenge()
        self.write_window_capture()
        with self.capture.open("wb") as destination:
            destination.truncate(VERIFIER_MODULE.PIXEL_ORACLE.MAX_PNG_BYTES + 1)
        completed = self.invoke_verify(window=True)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("exceeds the supported byte bound", completed.stderr)
        self.assertFalse(self.output.exists())

    def test_vz_socket_receipt_rejects_tampered_raw_result(self) -> None:
        self.issue_challenge()
        self.write_transport_receipt()
        result = self.make_result()
        result["metalDeviceName"] = "Tampered GPU"
        self.write_json(self.result, result)
        completed = self.invoke_verify(transport=True)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("result digest", completed.stderr)
        self.assertFalse(self.output.exists())

    def test_nonce_mismatch_is_rejected(self) -> None:
        self.issue_challenge()
        result = self.make_result()
        result["nonce"] = "wrong-nonce"
        self.write_json(self.result, result)
        completed = self.invoke_verify()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("candidate or nonce", completed.stderr)
        self.assertFalse(self.output.exists())

    def test_machine_identity_mismatch_is_rejected(self) -> None:
        self.issue_challenge()
        result = self.make_result()
        result["machineID"] = "other-machine"
        self.write_json(self.result, result)
        completed = self.invoke_verify()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("machine ID", completed.stderr)
        self.assertFalse(self.output.exists())

    def test_unapproved_shader_identity_is_rejected(self) -> None:
        self.issue_challenge()
        result = self.make_result()
        result["probeShaderSHA256"] = "c" * 64
        self.write_json(self.result, result)
        completed = self.invoke_verify()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("approved retained Metal source", completed.stderr)
        self.assertFalse(self.output.exists())

    def test_well_formed_but_wrong_render_digest_is_rejected(self) -> None:
        self.issue_challenge()
        result = self.make_result()
        result["renderedPatternSHA256"] = "d" * 64
        self.write_json(self.result, result)
        completed = self.invoke_verify()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("checkerboard oracle", completed.stderr)
        self.assertFalse(self.output.exists())

    def test_stale_visual_challenge_is_rejected_even_with_well_formed_hashes(self) -> None:
        self.issue_challenge()
        result = self.make_result()
        result["visualChallenge"] = VERIFIER_MODULE.visual_challenge("older-nonce")
        self.write_json(self.result, result)
        completed = self.invoke_verify()
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("visual challenge", completed.stderr)
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
