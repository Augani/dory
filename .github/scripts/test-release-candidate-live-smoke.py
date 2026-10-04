#!/usr/bin/env python3
"""Offline contract tests for the exact physical release-candidate wrapper."""

from __future__ import annotations

import os
import pathlib
import re
import socket
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "release-candidate-live-smoke.sh"
FEX_KIND_GATE = ROOT / "scripts" / "fex-kind-live-gate.sh"

class ReleaseCandidateLiveSmokeTests(unittest.TestCase):

    def test_every_invoked_script_is_tracked(self) -> None:
        text = GATE.read_text(encoding="utf-8")
        dependencies = sorted(set(re.findall(r"scripts/[A-Za-z0-9._/-]+\.sh", text)))
        self.assertGreaterEqual(len(dependencies), 10)
        for dependency in dependencies:
            result = subprocess.run(
                ["git", "ls-files", "--error-unmatch", dependency],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 0, f"untracked live dependency: {dependency}")

    def test_fex_kind_confirmation_fails_before_host_or_workroot_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workroot = pathlib.Path(temporary) / "must-not-exist"
            result = subprocess.run(
                [
                    "bash",
                    str(FEX_KIND_GATE),
                    "--socket",
                    str(pathlib.Path(temporary) / "missing.sock"),
                    "--docker",
                    "/missing/docker",
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
            self.assertIn("requires --confirm EXACT-DORY-FEX-KIND", result.stderr)
            self.assertFalse(workroot.exists())

    def test_fex_kind_rejects_unpinned_kind_bytes_before_evidence_creation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            socket_path = root / "dory.sock"
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(str(socket_path))
            try:
                fake_tool = root / "fake-tool"
                fake_tool.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                fake_tool.chmod(0o755)
                running_kernel = root / "running-kernel"
                expected_kernel = root / "expected-kernel"
                running_initfs = root / "running-initfs"
                expected_initfs = root / "expected-initfs"
                running_kernel.write_bytes(b"same kernel\n")
                expected_kernel.write_bytes(b"same kernel\n")
                running_initfs.write_bytes(b"same initfs\n")
                expected_initfs.write_bytes(b"same initfs\n")
                workroot = root / "must-not-exist"
                result = subprocess.run(
                    [
                        "bash",
                        str(FEX_KIND_GATE),
                        "--socket",
                        str(socket_path),
                        "--docker",
                        str(fake_tool),
                        "--kind",
                        str(fake_tool),
                        "--kubectl",
                        str(fake_tool),
                        "--kernel",
                        str(running_kernel),
                        "--initfs",
                        str(running_initfs),
                        "--expected-kernel",
                        str(expected_kernel),
                        "--expected-initfs",
                        str(expected_initfs),
                        "--source-commit",
                        "a" * 40,
                        "--workroot",
                        str(workroot),
                        "--confirm",
                        "EXACT-DORY-FEX-KIND",
                    ],
                    cwd=ROOT,
                    env={**os.environ, "HOME": temporary},
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=False,
                )
            finally:
                listener.close()
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("kind v0.29.0 Darwin ARM64 digest mismatch", result.stderr)
            self.assertFalse(workroot.exists())

    def test_dedicated_user_confirmation_fails_before_host_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            app = pathlib.Path(temporary) / "Dory.app"
            app.mkdir()
            result = subprocess.run(
                [str(GATE), str(app)],
                cwd=ROOT,
                env={
                    **os.environ,
                    "HOME": temporary,
                    "DORY_RELEASE_SOURCE_COMMIT": "a" * 40,
                },
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("DORY_RELEASE_LIVE_CONFIRMED", result.stderr)

if __name__ == "__main__":
    unittest.main()
