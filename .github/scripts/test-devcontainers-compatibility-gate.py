#!/usr/bin/env python3
"""Offline contract tests for the Dev Containers compatibility gate."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "devcontainers-compatibility-gate.sh"


class DevContainersCompatibilityGateTests(unittest.TestCase):
    def test_contract_uses_exact_candidate_and_fixture(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "ISOLATED-ENGINE-DEVCONTAINERS",
            "socket is not owned by the release user",
            "Docker CLI is unavailable or indirect",
            "--image must be an exact digest reference",
            "required offline fixture image is missing",
            "dist.integrity",
            "registry.npmjs.org",
            "executed Dev Containers CLI version does not match",
            "host_to_container_workspace=PASS",
            "container_to_host_workspace=PASS",
            "exact_baseline_cleanup=PASS",
            "docker_cli_sha256=",
            "node_sha256=",
            "npm_sha256=",
        ):
            self.assertIn(proof, text, proof)
        for stale in ('"image": "alpine:3.22"', "assert "):
            self.assertNotIn(stale, text, stale)

    def test_confirmation_fails_before_socket_or_npm_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run(
                [
                    str(GATE),
                    "--socket", str(pathlib.Path(temporary) / "missing.sock"),
                    "--docker", "/missing/docker",
                    "--version", "0.87.0",
                    "--image", "example.invalid/alpine@sha256:" + "a" * 64,
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
