#!/usr/bin/env python3
"""Offline contract tests for the exact LocalStack S3/SQS compatibility gate."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "localstack-compatibility-gate.sh"


class LocalStackCompatibilityGateTests(unittest.TestCase):
    def test_contract_is_exact_offline_and_scoped(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "ISOLATED-ENGINE-LOCALSTACK",
            "socket is not owned by the release user",
            "Docker CLI is unavailable or indirect",
            "LocalStack image must be an exact digest reference",
            "required offline LocalStack image is missing",
            "--pull=never",
            "dory.release.localstack.run",
            "LocalStack container did not use the exact requested image",
            "LocalStack unexpectedly received a Docker socket",
            'binding[0].get("HostIp") != "127.0.0.1"',
            "requested loopback port was widened to all host interfaces",
            "awslocal s3api put-object",
            "awslocal s3api get-object",
            "awslocal sqs send-message",
            "awslocal sqs receive-message",
            "s3_object_roundtrip=PASS",
            "sqs_message_roundtrip=PASS",
            "owned_container_cleanup=PASS",
            "exact_baseline_cleanup=PASS",
            "docker_cli_sha256=",
        ):
            self.assertIn(proof, text, proof)
        for stale in ("docker_e pull", "docker_e volume rm", "docker_e network rm", "assert "):
            self.assertNotIn(stale, text, stale)

    def test_confirmation_fails_before_socket_image_or_workroot_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workroot = pathlib.Path(temporary) / "must-not-exist"
            result = subprocess.run(
                [
                    str(GATE),
                    "--socket", str(pathlib.Path(temporary) / "missing.sock"),
                    "--docker", "/missing/docker",
                    "--image", "example.invalid/localstack@sha256:" + "a" * 64,
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
