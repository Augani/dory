#!/usr/bin/env python3
"""Offline contract for isolated authenticated-registry and image-lifecycle qualification."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "private-registry-auth-gate.sh"


class PrivateRegistryAuthGateTests(unittest.TestCase):
    def test_gate_binds_candidate_registry_auth_context_and_secret_cleanup(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "ISOLATED-ENGINE-PRIVATE-REGISTRY",
            "Docker CLI must be an absolute path",
            "Docker CLI is unavailable or indirect",
            "socket is not owned by the release user",
            "workroot already exists or is indirect",
            "Docker Buildx plugin must be an absolute path",
            "Docker Buildx plugin is unavailable or indirect",
            "isolated Buildx copy differs from the candidate plugin",
            "qualified image does not retain its exact registry authority",
            "registry volume is missing its exact run authority",
            "--pull=never --name",
            '--mount "type=volume,src=$VOLUME,dst=/var/lib/registry"',
            '--mount "type=bind,src=$AUTH,dst=/auth"',
            "authenticated registry runtime binding differs from the qualified image/network",
            "authenticated registry mount graph differs from its exact authorities",
            "authenticated registry environment omits its loopback/auth contract",
            "unauthenticated pull unexpectedly succeeded",
            "unauthenticated pull failed without an authentication rejection",
            'CONTEXT="$WORKDIR/context"',
            '"$CONTEXT/Dockerfile"',
            "BuildKit context is not the exact Dockerfile-only authority",
            "--progress plain --pull --network none",
            "BuildKit secret leaked into image history",
            "private registry credential or BuildKit secret leaked into the image archive",
            "save/load changed the image identity",
            "filtered image prune retained the run-owned derived image",
            'docker_e ps -aq --filter "label=dev.dory.private-registry=$RUN_ID"',
            "private registry evidence retained secret bytes",
            "dockerfile_only_build_context=PASS",
            "archive_secret_nonleak=PASS",
            "secret_free_evidence=PASS",
            "owned_cleanup=PASS",
            "isolated_credential_cleanup=PASS",
            "docker_cli_sha256=",
            "buildx_cli_sha256=",
        ):
            self.assertIn(proof, text, proof)
        self.assertIn(
            "'^[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[0-9a-f]{64}$'", text
        )
        for stale in (
            'ln -s "$BUILDX"',
            '"$HOME/.docker/cli-plugins/docker-buildx"',
            '-v "$VOLUME:/var/lib/registry"',
            '-v "$AUTH:/auth"',
            '-t "$BUILT_REF" -- "$WORKDIR"',
            "assert ",
        ):
            self.assertNotIn(stale, text, stale)

    def test_confirmation_fails_before_socket_helpers_images_or_workroot_access(self) -> None:
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
                    "--buildx",
                    "/missing/buildx",
                    "--base-image",
                    "invalid",
                    "--source-commit",
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
