#!/usr/bin/env python3
"""Offline contract tests for the checksum-pinned act compatibility gate."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "act-compatibility-gate.sh"


class ActCompatibilityGateTests(unittest.TestCase):
    def test_contract_is_exact_and_offline_at_runtime(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "ISOLATED-ENGINE-ACT",
            "socket is not owned by the release user",
            "Docker CLI is unavailable or indirect",
            "runner image must be an exact digest reference",
            "required offline runner image is missing",
            "act_Darwin_$ARCHIVE_ARCH.tar.gz",
            "shasum -a 256 -c -",
            "verified act archive did not contain a direct executable",
            "--container-daemon-socket unix:///var/run/docker.sock",
            "--pull=false",
            "host_to_runner_workspace=PASS",
            "runner_to_host_workspace=PASS",
            "act_binary_sha256=",
            "docker_cli_sha256=",
        ):
            self.assertIn(proof, text, proof)
        self.assertNotIn("--pull \\", text)
        self.assertNotIn("assert ", text)

    def test_confirmation_fails_before_socket_or_download_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run(
                [
                    str(GATE),
                    "--socket", str(pathlib.Path(temporary) / "missing.sock"),
                    "--docker", "/missing/docker",
                    "--runner-image", "example.invalid/runner@sha256:" + "a" * 64,
                    "--workroot", str(pathlib.Path(temporary) / "evidence"),
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


if __name__ == "__main__":
    unittest.main()
