#!/usr/bin/env python3
"""Offline contract for exact gvproxy QEMU-switch qualification."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "gvproxy-qemu-switch-gate.py"


class GVProxyQEMUSwitchGateTests(unittest.TestCase):
    def test_gate_binds_compiled_identity_private_sockets_frames_and_shutdown(self) -> None:
        subprocess.run(["python3", "-m", "py_compile", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "EXACT-GVPROXY-QEMU-SWITCH",
            "gvproxy must be an absolute path",
            "gvproxy is unavailable or indirect",
            "gvproxy is not owned by the release user",
            "release candidate digest is compiled and cannot be overridden",
            "release candidate evidence requires --source-commit",
            "release candidate evidence requires --provenance",
            "provenance is missing or indirect",
            "provenance must contain exactly one verified_sha256",
            "reproducible-build SHA-256 mismatch",
            "unexpected version identity",
            "workroot already exists or is indirect",
            "canonical workroot already exists or is indirect",
            "evidence must be the exact WORKROOT/manifest.txt authority",
            "gvproxy published a missing, indirect, or foreign-owned switch socket",
            "LAN-to-guest Ethernet frame changed in transit",
            "guest-to-LAN Ethernet frame",
            "gvproxy exited before teardown",
            "gvproxy did not terminate within two seconds of SIGTERM",
            "schema=3",
            "status=PASS",
            "source_commit=",
            "gvproxy_sha256=",
            "gvproxy_build_sha256=",
            "provenance_sha256=",
            "same_user_switch_sockets=PASS",
            "graceful_helper_shutdown=PASS",
            "lan_to_guest=PASS",
            "guest_to_lan=PASS",
            "frame_contract_sha256=",
            "release_qualifying=",
            "evidence.chmod(0o600)",
        ):
            self.assertIn(proof, text, proof)
        for unsafe in (
            "gvproxy_path=",
            'os.environ.get("DORY_NETWORK_MTU"',
            'mkdir(parents=True, exist_ok=True)',
            '"release_qualifying=true"',
        ):
            self.assertNotIn(unsafe, text, unsafe)

    def test_confirmation_fails_before_binary_or_workroot_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workroot = pathlib.Path(temporary) / "must-not-exist"
            result = subprocess.run(
                [
                    "python3",
                    str(GATE),
                    "/missing/gvproxy",
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
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertIn("requires --confirm", result.stderr)
            self.assertFalse(workroot.exists())


if __name__ == "__main__":
    unittest.main()
