#!/usr/bin/env python3
"""Contract tests for the Wave 0 producer inventory."""

from __future__ import annotations

import json
import hashlib
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
INVENTORY = ROOT / "scripts/inventory-wave0-candidate.py"
FIRMWARE_PRODUCER = ROOT / "scripts/build-dory-armvirt-firmware.py"


class FirmwareProducerContractTests(unittest.TestCase):
    def test_current_pc_platform_has_a_source_derived_identifier(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(FIRMWARE_PRODUCER),
                "--platform",
                "pc",
                "--print-build-identifier",
            ],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertRegex(result.stdout.strip(), r"^dory-pc-v1-[0-9a-f]{20}$")


class CandidateInventoryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="dory-wave0-inventory-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "Dory.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/MacOS/Dory").write_bytes(b"Dory")
        (self.app / "Contents/Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleIdentifier": "com.pythonxi.Dory",
                    "CFBundleShortVersionString": "0.0.1",
                    "CFBundleVersion": "1",
                    "LSMinimumSystemVersion": "14.0",
                }
            )
        )
        for relative in ("Dory.xcodeproj/project.pbxproj", "Config/Dory-Info.plist", "scripts/build.sh"):
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(relative.encode())
        for relative in (
            "Config/DoryRendererProductionTuple.json",
            "scripts/xcode-package-renderer-production.sh",
            "scripts/assemble-renderer-production-worker.sh",
        ):
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(relative.encode())
        renderer = self.app / "Contents/Helpers/DoryHVRunner.app/Contents"
        (renderer / "XPCServices/DoryRendererWorker.xpc/Contents/MacOS").mkdir(parents=True)
        (renderer / "XPCServices/DoryRendererWorker.xpc/Contents/MacOS/DoryRendererWorker").write_bytes(
            b"worker"
        )
        (renderer / "Resources").mkdir()
        (renderer / "Resources/renderer-production-inventory.json").write_text("{}\n")
        self.vtool = self.root / "fake-vtool"
        self.vtool.write_text("#!/bin/sh\nprintf 'platform MACOS\\nminos 14.0\\n'\n")
        self.vtool.chmod(self.vtool.stat().st_mode | stat.S_IXUSR)

    def write_desktop_rootfs(self, *, stale: bool = False) -> None:
        desktop = self.root / "guest/desktop"
        desktop.mkdir(parents=True, exist_ok=True)
        for name in ("PINS", "build.sh", "verify-build.sh"):
            (desktop / name).write_text(f"fixture {name}\n")
        fingerprint = desktop / "input-fingerprint.sh"
        fingerprint.write_text(
            "#!/bin/sh\n"
            "case \"$2\" in\n"
            "  debian) printf '%064d\\n' 1 ;;\n"
            "  ubuntu) printf '%064d\\n' 2 ;;\n"
            "  kali) printf '%064d\\n' 3 ;;\n"
            "esac\n"
        )
        fingerprint.chmod(fingerprint.stat().st_mode | stat.S_IXUSR)
        output = self.root / "guest/out"
        output.mkdir(parents=True, exist_ok=True)
        expected = {"debian": "1", "ubuntu": "2", "kali": "3"}
        for distro, suffix in expected.items():
            (output / f"dory-desktop-{distro}-rootfs-arm64.ext4.zst").write_bytes(b"rootfs")
            recorded = "0" if stale and distro == "kali" else suffix
            (output / f"dory-desktop-{distro}-build-arm64.stamp").write_text(
                f"schema=2\narch=arm64\ndistro={distro}\ninput_sha256={int(recorded):064d}\n"
                f"compressed_sha256={hashlib.sha256(b'rootfs').hexdigest()}\n"
            )

    def write_pc_firmware(self, *, manifest_identifier: str, expected_identifier: str) -> None:
        output = self.root / "guest/out/dory-pc-firmware"
        output.mkdir(parents=True, exist_ok=True)
        firmware = b"firmware"
        (output / "firmware-code.fd").write_bytes(firmware)
        (output / "manifest.json").write_text(json.dumps({
            "buildIdentifier": manifest_identifier,
            "firmwareCodeSHA256": hashlib.sha256(firmware).hexdigest(),
            "source": {"repository": "fixture", "revision": "1"},
            "machineABIIdentity": "dory.pc@1",
            "firmwareABIIdentity": "dory.edk2.pc@1",
        }))
        producer = self.root / "scripts/build-dory-armvirt-firmware.py"
        producer.parent.mkdir(parents=True, exist_ok=True)
        producer.write_text(
            "import sys\n"
            "assert sys.argv[1:] == ['--platform', 'pc', '--print-build-identifier']\n"
            f"print({expected_identifier!r})\n"
        )

    def run_inventory(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable, str(INVENTORY), "--app", str(self.app),
                "--source-root", str(self.root), "--guest-output", str(self.root / "guest/out"),
                "--ffi", str(self.root / "ffi.a"), "--vtool", str(self.vtool),
            ],
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )

    def test_inventory_records_deployment_target_and_missing_required_producers(self) -> None:
        result = self.run_inventory()

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        app = next(item for item in payload["producers"] if item["id"] == "app")
        self.assertEqual(app["status"], "incomplete")
        self.assertEqual(app["artifacts"][0]["minimumMacOS"], "14.0")
        self.assertEqual(app["metadata"]["identity"]["status"], "available")
        self.assertEqual(app["metadata"]["sourceBinding"]["status"], "unavailable")
        renderer = next(item for item in payload["producers"] if item["id"] == "renderer")
        self.assertEqual(renderer["status"], "available")
        self.assertEqual(renderer["artifacts"][1]["status"], "available")
        self.assertNotIn("renderer", payload["incompleteProducers"])
        self.assertEqual(payload["candidateStatus"], "incomplete")
        self.assertFalse(payload["releaseQualified"])

    def test_mismatched_ffi_receipt_keeps_its_producer_incomplete(self) -> None:
        ffi = self.root / "ffi.a"
        ffi.write_bytes(b"ffi bytes")
        receipt = self.root / "dory-core-swift/artifacts/DoryFFI.xcframework/deployment-targets.json"
        receipt.parent.mkdir(parents=True)
        receipt.write_text(json.dumps({"kind": "dev.dory.ffi-deployment-targets", "librarySHA256": "0" * 64}))

        result = self.run_inventory()

        self.assertEqual(result.returncode, 0, result.stderr)
        ffi_producer = next(item for item in json.loads(result.stdout)["producers"] if item["id"] == "ffi")
        self.assertEqual(ffi_producer["metadata"]["status"], "archive-mismatch")
        self.assertEqual(ffi_producer["status"], "incomplete")

    def test_pc_firmware_must_match_current_platform_sources(self) -> None:
        self.write_pc_firmware(
            manifest_identifier="dory-pc-v1-stale",
            expected_identifier="dory-pc-v1-current",
        )

        result = self.run_inventory()

        self.assertEqual(result.returncode, 0, result.stderr)
        firmware = next(
            item for item in json.loads(result.stdout)["producers"]
            if item["id"] == "pc-firmware"
        )
        self.assertEqual(firmware["metadata"]["status"], "stale-source")
        self.assertEqual(
            firmware["metadata"]["expectedBuildIdentifier"],
            "dory-pc-v1-current",
        )
        self.assertEqual(firmware["status"], "incomplete")

    def test_pc_firmware_current_source_binding_is_available(self) -> None:
        self.write_pc_firmware(
            manifest_identifier="dory-pc-v1-current",
            expected_identifier="dory-pc-v1-current",
        )

        result = self.run_inventory()

        self.assertEqual(result.returncode, 0, result.stderr)
        firmware = next(
            item for item in json.loads(result.stdout)["producers"]
            if item["id"] == "pc-firmware"
        )
        self.assertEqual(firmware["metadata"]["status"], "matches-current-source")
        self.assertEqual(firmware["status"], "incomplete")

    def test_desktop_stamps_must_match_current_inputs(self) -> None:
        self.write_desktop_rootfs(stale=True)

        result = self.run_inventory()

        self.assertEqual(result.returncode, 0, result.stderr)
        desktop = next(item for item in json.loads(result.stdout)["producers"] if item["id"] == "desktop-rootfs")
        self.assertEqual(desktop["metadata"]["status"], "stale-inputs")
        self.assertEqual(desktop["metadata"]["buildStamps"][2]["distro"], "kali")
        self.assertEqual(desktop["metadata"]["buildStamps"][2]["status"], "stale-inputs")
        self.assertEqual(desktop["status"], "incomplete")

    def test_kernel_presence_requires_its_producer_verifier(self) -> None:
        kernel = self.root / "guest/kernel"
        kernel.mkdir(parents=True)
        for name in ("build.sh", "profile.sh"):
            (kernel / name).write_text("fixture\n")
        verifier = kernel / "verify-build.sh"
        verifier.write_text("#!/bin/sh\necho stale producer >&2\nexit 1\n")
        verifier.chmod(verifier.stat().st_mode | stat.S_IXUSR)
        output = self.root / "guest/out"
        output.mkdir(parents=True, exist_ok=True)
        (output / "Image-gpu").write_bytes(b"kernel")
        (output / "kernel-build-arm64-gpu.stamp").write_text("stamp\n")

        result = self.run_inventory()

        self.assertEqual(result.returncode, 0, result.stderr)
        arm64 = next(item for item in json.loads(result.stdout)["producers"] if item["id"] == "arm64-kernel")
        self.assertEqual(arm64["metadata"]["status"], "verification-failed")
        self.assertEqual(arm64["status"], "incomplete")

    def test_desktop_archive_must_match_its_current_stamp(self):
        self.write_desktop_rootfs()
        result = self.run_inventory()
        self.assertEqual(result.returncode, 0, result.stderr)
        desktop = next(item for item in json.loads(result.stdout)["producers"] if item["id"] == "desktop-rootfs")
        self.assertEqual(desktop["status"], "available")
        archive = self.root / "guest/out/dory-desktop-ubuntu-rootfs-arm64.ext4.zst"
        archive.write_bytes(b"replaced rootfs")
        result = self.run_inventory()
        self.assertEqual(result.returncode, 0, result.stderr)
        desktop = next(item for item in json.loads(result.stdout)["producers"] if item["id"] == "desktop-rootfs")
        self.assertEqual(desktop["status"], "incomplete")
        self.assertEqual(desktop["metadata"]["status"], "artifact-mismatch")

    def test_valid_source_binding_cannot_hide_invalid_app_identity(self):
        # Isolate the independent identity check; source verification is represented
        # by a successful fixture tool, not claimed as a real source-binding pass.
        verifier = self.root / "scripts/write-development-source-binding.py"
        verifier.write_text("raise SystemExit(0)\n")
        resource = self.app / "Contents/Resources/development-source-binding.json"
        resource.parent.mkdir(parents=True)
        resource.write_text("{}")
        for value in [{"CFBundleIdentifier": "com.pythonxi.Dory"}, ["not a dictionary"]]:
            with self.subTest(value=value):
                (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(value))
                result = self.run_inventory()
                self.assertEqual(result.returncode, 0, result.stderr)
                app = next(item for item in json.loads(result.stdout)["producers"] if item["id"] == "app")
                self.assertEqual(app["status"], "incomplete")
                self.assertEqual(app["metadata"]["status"], "invalid-app-identity")

    def test_mesa_profiles_require_individual_verification(self):
        mesa = self.root / "guest/mesa"
        mesa.mkdir(parents=True)
        for name in ("verify-build.sh", "verify-pc-virgl2-build.sh"):
            verifier = mesa / name
            verifier.write_text('#!/bin/sh\ntest "$1" = arm64\n')
            verifier.chmod(0o755)
        result = self.run_inventory()
        self.assertEqual(result.returncode, 0, result.stderr)
        entry = next(x for x in json.loads(result.stdout)["producers"] if x["id"] == "mesa")
        self.assertEqual(entry["metadata"]["status"], "verification-failed")
        profiles = {x["profile"]: x["status"] for x in entry["metadata"]["profiles"]}
        self.assertEqual(profiles, {
            "venus": "matches-current-producer", "arm-virgl2": "matches-current-producer",
            "pc-virgl2": "verification-failed",
        })
        self.assertEqual(entry["status"], "incomplete")

    def test_app_symlink_is_rejected(self):
        alias = self.root / "alias.app"
        alias.symlink_to(self.app)
        self.app = alias
        result = self.run_inventory()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("direct directory", result.stderr)


if __name__ == "__main__":
    unittest.main()
