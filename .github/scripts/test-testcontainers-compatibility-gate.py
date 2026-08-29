#!/usr/bin/env python3
"""Offline contract tests for the exact Testcontainers and Ryuk release gate."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "testcontainers-compatibility-gate.sh"


class TestcontainersCompatibilityGateTests(unittest.TestCase):
    def test_contract_binds_package_images_ryuk_and_cleanup(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "ISOLATED-ENGINE-TESTCONTAINERS",
            "socket is not owned by the release user",
            "Docker CLI is unavailable or indirect",
            "workload and Ryuk images must be exact digest references",
            "required offline workload image is missing",
            "required offline Ryuk image is missing",
            "dist.integrity",
            "registry.npmjs.org",
            "Testcontainers npm integrity differs from the pinned release value",
            "--npm-integrity is required when --version differs",
            "downloaded Testcontainers tarball failed its SHA-512 integrity check",
            "installed Testcontainers version",
            'RYUK_CONTAINER_IMAGE="$RYUK_IMAGE"',
            "TESTCONTAINERS_RYUK_DISABLED=false",
            "TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock",
            'socketMount.Source !== "/var/run/docker.sock"',
            'withPullPolicy({ shouldPull: () => false })',
            'Wait.forHttp("/", 8080)',
            "workload is not bound to the exact Ryuk session",
            "dory.release.testcontainers.run",
            "engine has pre-existing named volumes",
            "engine has pre-existing custom networks",
            "exact_baseline_cleanup=PASS",
            "docker_cli_sha256=",
            "node_sha256=",
            "npm_sha256=",
            "package_lock_sha256=",
        ):
            self.assertIn(proof, text, proof)
        for stale in ("alpine:3.20", "npm install testcontainers@", "assert "):
            self.assertNotIn(stale, text, stale)

    def test_confirmation_fails_before_socket_registry_or_workroot_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workroot = pathlib.Path(temporary) / "must-not-exist"
            result = subprocess.run(
                [
                    str(GATE),
                    "--socket", str(pathlib.Path(temporary) / "missing.sock"),
                    "--docker", "/missing/docker",
                    "--image", "example.invalid/workload@sha256:" + "a" * 64,
                    "--ryuk-image", "example.invalid/ryuk@sha256:" + "b" * 64,
                    "--workroot", str(workroot),
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
