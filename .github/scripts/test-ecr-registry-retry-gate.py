#!/usr/bin/env python3
"""Offline contract for interrupted ECR push/retry qualification."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "ecr-registry-retry-gate.sh"


class ECRRegistryRetryGateTests(unittest.TestCase):
    def test_gate_binds_candidate_account_repository_digests_and_cleanup(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "DISPOSABLE-ECR-INTERRUPT-RETRY",
            "Dory socket is not owned by the release user",
            "Docker CLI must be an absolute path",
            "Docker CLI is unavailable or indirect",
            "no sibling docker-buildx plugin",
            "registry hostname region differs from --region",
            "workroot already exists or is indirect",
            "isolated Buildx copy differs from the candidate plugin",
            "local base image does not retain its exact registry authority",
            "AWS caller account differs from the ECR registry account",
            "ECR repository authority differs from the requested registry path",
            'rm -f "$WORKDIR/aws-caller.json" "$WORKDIR/ecr-repository.json"',
            "DOCKER_CONFIG=\"$DOCKER_CONFIG\"",
            "--network none --pull=false --progress=plain",
            "first ECR push completed or stalled before an upload could be interrupted",
            "interrupted ECR push returned success",
            "ECR push output does not contain one exact manifest digest",
            "repeated ECR manifest PUT changed the manifest digest",
            "ECR registry digest differs from the repeated push digest",
            'REMOTE_DIGEST_REF="$REGISTRY/$REPOSITORY@$remote_digest"',
            'docker_e pull "$REMOTE_DIGEST_REF"',
            "--rm --pull=never --network none --label",
            "ECR repull/run returned the wrong layer checksum",
            "ECR cleanup did not report the one unique image tag",
            "remote ECR tag survived confirmed deletion",
            "remote ECR deletion could not be verified fail-closed",
            "owned ECR retry container survived cleanup",
            "isolated Docker credential directory survived cleanup",
            "caller_account_sha256=",
            "repository_authority_sha256=",
            "docker_cli_sha256=",
            "buildx_cli_sha256=",
            "aws_cli_sha256=",
            "registry_digest_agreement=PASS",
            "digest_based_repull=PASS",
            "remote_deletion_verified=PASS",
            "owned_container_cleanup=PASS",
            "isolated_credential_cleanup=PASS",
        ):
            self.assertIn(proof, text, proof)
        self.assertIn(
            "'^[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[0-9a-f]{64}$'", text
        )
        for stale in (
            "assert ",
            'ln -s "$BUILDX"',
            'docker_e pull "$REMOTE_REF"',
            'docker_e run --rm "$REMOTE_REF"',
            "aws ecr ",
        ):
            self.assertNotIn(stale, text, stale)

    def test_confirmation_fails_before_socket_aws_helpers_or_workroot_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workroot = pathlib.Path(temporary) / "must-not-exist"
            result = subprocess.run(
                [
                    "bash",
                    str(GATE),
                    "--socket",
                    str(pathlib.Path(temporary) / "missing.sock"),
                    "--docker",
                    "/missing/docker",
                    "--base-image",
                    "invalid",
                    "--registry",
                    "invalid",
                    "--repository",
                    "invalid",
                    "--region",
                    "invalid",
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
            self.assertIn("requires --confirm", result.stderr)
            self.assertFalse(workroot.exists())


if __name__ == "__main__":
    unittest.main()
