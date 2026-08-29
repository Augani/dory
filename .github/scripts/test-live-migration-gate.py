#!/usr/bin/env python3
"""Offline contract tests for the isolated live migration gate."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "live-orbstack-migration-smoke.sh"


class LiveMigrationGateTests(unittest.TestCase):
    def test_contract_is_exact_and_owned(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "ISOLATED-DORY-LIVE-MIGRATION",
            "live migration base image must be an exact digest reference",
            "DORY_LIVE_DOCKER_BIN is required",
            "live migration Docker CLI is unavailable or indirect",
            "source and target sockets must differ",
            "socket is not owned by the release user",
            "DORY_LIVE_ORBSTACK_MIGRATION_MARKER",
            "live migration marker must remain below its private root",
            "source_baseline_restored=PASS",
            "target_baseline_restored=PASS",
            "volume_64mib_checksum=PASS",
            "docker_cli_sha256=",
            "helper_archive_sha256=",
        ):
            self.assertIn(proof, text, proof)
        for stale in ("alpine:3.20", "DOCKER_HOST=\"unix://$socket\" docker", "assert "):
            self.assertNotIn(stale, text, stale)

    def test_confirmation_fails_before_socket_or_docker_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run(
                [str(GATE)],
                cwd=ROOT,
                env={
                    **os.environ,
                    "HOME": temporary,
                    "DORY_LIVE_MIGRATION_BASE_IMAGE": "example.invalid/alpine@sha256:" + "a" * 64,
                    "DORY_LIVE_DOCKER_BIN": "/missing/docker",
                },
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("DORY_LIVE_MIGRATION_CONFIRMED", result.stderr)


if __name__ == "__main__":
    unittest.main()
