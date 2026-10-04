#!/usr/bin/env python3
"""Offline contract tests for the physical SSH-agent forwarding gate."""

from __future__ import annotations

import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "ssh-agent-forwarding-gate.sh"

class SSHAgentForwardingGateTests(unittest.TestCase):

    def test_excessive_concurrency_fails_before_socket_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run(
                [
                    str(GATE),
                    "--socket",
                    str(pathlib.Path(temporary) / "missing.sock"),
                    "--docker",
                    "/missing/docker",
                    "--image",
                    "example.invalid/ssh@sha256:" + "a" * 64,
                    "--workroot",
                    str(pathlib.Path(temporary) / "evidence"),
                    "--concurrency",
                    "65",
                ],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("concurrency must be between 1 and 64", result.stderr)

if __name__ == "__main__":
    unittest.main()
