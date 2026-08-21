#!/usr/bin/env python3
"""Offline contract tests for the exact Tilt and Docker Compose compatibility gate."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "tilt-compose-compatibility-gate.sh"


class TiltComposeCompatibilityGateTests(unittest.TestCase):
    def test_contract_binds_tilt_candidate_compose_image_and_project(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "ISOLATED-ENGINE-TILT",
            "socket is not owned by the release user",
            "$helper_name helper is unavailable or indirect",
            "--image must be an exact digest reference",
            "shasum -a 256 -c -",
            "verified Tilt archive did not contain a direct executable",
            "private Compose plugin differs from the candidate helper",
            "Tilt would not discover the exact candidate Docker CLI",
            "Tilt would not discover the exact candidate Compose helper",
            "exact candidate Compose plugin is not loadable",
            "required offline Tilt workload image is missing",
            "pull_policy: never",
            "com.docker.compose.project=$PROJECT_NAME",
            "Tilt Compose service did not use the exact workload image",
            "Tilt Compose workspace bind is not exact and writable",
            "host_to_service_workspace=PASS",
            "service_to_host_workspace=PASS",
            "owned_project_cleanup=PASS",
            "exact_baseline_cleanup=PASS",
            "tilt_binary_sha256=",
            "docker_cli_sha256=",
            "compose_plugin_sha256=",
        ):
            self.assertIn(proof, text, proof)
        for stale in ("image: alpine:", "docker_e pull", "ids=\"$(docker_e ps -aq)\"", "assert "):
            self.assertNotIn(stale, text, stale)

    def test_confirmation_fails_before_socket_download_or_workroot_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workroot = pathlib.Path(temporary) / "must-not-exist"
            result = subprocess.run(
                [
                    str(GATE),
                    "--socket", str(pathlib.Path(temporary) / "missing.sock"),
                    "--docker", "/missing/docker",
                    "--compose", "/missing/docker-compose",
                    "--image", "example.invalid/alpine@sha256:" + "a" * 64,
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
