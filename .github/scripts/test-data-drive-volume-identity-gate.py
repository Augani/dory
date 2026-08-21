#!/usr/bin/env python3
"""Offline contract for physical APFS data-drive volume identity qualification."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "data-drive-volume-identity-gate.sh"


class DataDriveVolumeIdentityGateTests(unittest.TestCase):
    def test_gate_binds_candidate_helper_images_devices_and_drive_authority(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "PHYSICAL-APFS-VOLUME-IDENTITY",
            "physical Apple silicon is required",
            "dory-hv must be absolute",
            "dory-hv is missing or indirect",
            "workroot already exists or is indirect",
            "generated APFS mount name is already in use",
            "hdiutil attach -plist -nobrowse",
            "hdiutil attached the image at an unexpected mount point",
            "hdiutil did not report an exact mounted APFS device",
            'hdiutil detach "$first_device"',
            'hdiutil detach "$second_device"',
            "data-drive manifest has an unexpected shape",
            "data-drive manifest ID differs from dory-hv output",
            "selection authority has an unexpected shape",
            "selection authority differs from the APFS volume",
            "clearing runtime state forgot the selected drive",
            "bookmark did not recover the renamed volume",
            "detached selected volume was accepted",
            "same-name replacement volume was accepted",
            "original drive identity changed",
            "external_volume_identity=PASS",
            "durable_selection_outside_runtime_state=PASS",
            "bookmark_volume_rename_recovery=PASS",
            "missing_volume_shadow_prevention=PASS",
            "same_name_wrong_volume_rejected=PASS",
            "original_volume_reaccepted=PASS",
            "exact_candidate_helper=PASS",
            "exact_device_detach=PASS",
            "dory_hv_sha256=",
        ):
            self.assertIn(proof, text, proof)
        for stale in (
            "assert ",
            'hdiutil detach "$MOUNT"',
            'hdiutil detach "$RENAMED_MOUNT"',
        ):
            self.assertNotIn(stale, text, stale)

    def test_confirmation_fails_before_architecture_helper_or_workroot_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workroot = pathlib.Path(temporary) / "must-not-exist"
            result = subprocess.run(
                [
                    "bash",
                    str(GATE),
                    "--dory-hv",
                    "/missing/dory-hv",
                    "--workroot",
                    str(workroot),
                ],
                cwd=ROOT,
                env={**os.environ, "HOME": temporary},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("requires --confirm", result.stderr)
            self.assertFalse(workroot.exists())


if __name__ == "__main__":
    unittest.main()
