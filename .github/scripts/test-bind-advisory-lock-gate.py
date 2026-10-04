#!/usr/bin/env python3
"""Offline contract tests for the cross-container advisory-lock gate."""

from __future__ import annotations

import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "bind-advisory-lock-gate.sh"
PROBE = ROOT / "scripts" / "bind-advisory-lock-probe.py"

class BindAdvisoryLockGateTests(unittest.TestCase):

    def test_relative_workroot_fails_before_socket_or_docker_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run(
                [
                    str(GATE),
                    "--socket",
                    str(pathlib.Path(temporary) / "missing.sock"),
                    "--docker",
                    "/missing/docker",
                    "--image",
                    "example.invalid/python@sha256:" + "a" * 64,
                    "--workroot",
                    "relative-evidence",
                    "--confirm",
                    "ISOLATED-DORY-BIND-LOCKS",
                ],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("--workroot must be absolute", result.stderr)

if __name__ == "__main__":
    unittest.main()
