#!/usr/bin/env python3
"""Offline contract tests for the physical sandbox security gate."""

from __future__ import annotations

import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "sandbox-security-gate.sh"

class SandboxSecurityGateTests(unittest.TestCase):

    def test_invalid_network_authority_fails_before_sandbox_creation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            dory = root / "dory"
            dory.write_text("#!/bin/sh\nexit 99\n", encoding="utf-8")
            dory.chmod(0o700)
            result = subprocess.run(
                [
                    str(GATE),
                    "--dory",
                    str(dory),
                    "--workroot",
                    str(root / "evidence"),
                    "--allowed-network",
                    "not a host:70000",
                ],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("allowed network port is outside", result.stderr)
            self.assertFalse((root / "evidence").exists())

if __name__ == "__main__":
    unittest.main()
