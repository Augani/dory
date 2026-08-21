#!/usr/bin/env python3
"""Offline contract tests for the physical external-APFS bind gate."""

from __future__ import annotations

import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "external-volume-bind-gate.sh"


class ExternalVolumeBindGateTests(unittest.TestCase):
    def test_external_volume_contract_is_complete(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "DISCONNECT-RECONNECT-DEDICATED-APFS",
            "DORY-DEDICATED-RELEASE-APFS-V1",
            "test root must be below /Volumes/<external-name>",
            "test path is not on an external physical volume",
            "external test volume is not APFS",
            "--image must be a digest-pinned fixture",
            "candidate socket is not owned by the release user",
            "external FIFO rejected promptly",
            "operations=10000",
            "64 MiB external bind checksum mismatch",
            '"$DORY" engine sleep',
            'diskutil unmount "$device_identifier"',
            "missing external volume unexpectedly accepted a bind write",
            "external APFS bytes were lost across unmount/remount",
            "disconnect_reconnect=PASS",
        ):
            self.assertIn(proof, text, proof)
        for stale in ("alpine:latest", "assert "):
            self.assertNotIn(stale, text, stale)

    def test_confirmation_is_required_before_host_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run(
                [
                    str(GATE),
                    "--socket",
                    str(pathlib.Path(temporary) / "missing.sock"),
                    "--docker",
                    "/missing/docker",
                    "--dory",
                    "/missing/dory",
                    "--state-dir",
                    str(pathlib.Path(temporary) / "state"),
                    "--path",
                    str(pathlib.Path(temporary) / "volume"),
                    "--image",
                    "example.invalid/alpine@sha256:" + "a" * 64,
                    "--workroot",
                    str(pathlib.Path(temporary) / "evidence"),
                ],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("requires --confirm", result.stderr)


if __name__ == "__main__":
    unittest.main()
