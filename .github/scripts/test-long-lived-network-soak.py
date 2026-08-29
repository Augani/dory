#!/usr/bin/env python3
"""Offline contract for the >24-hour same-connection network release soak."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "long-lived-network-soak.sh"


class LongLivedNetworkSoakTests(unittest.TestCase):
    def test_gate_binds_same_connection_latency_external_tcp_and_candidate(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "ISOLATED-ENGINE-LONG-LIVED-TCP",
            "Dory socket must be an absolute path",
            "Dory socket is unavailable or indirect",
            "Dory socket is not owned by the release user",
            "Docker CLI must be an absolute path",
            "Docker CLI is unavailable or indirect",
            "workroot already exists or is indirect",
            "release candidate evidence requires --source-commit",
            "release candidate duration must exceed 24 hours",
            "release candidate image must be digest-pinned",
            "release candidate fixture must resolve to linux/arm64",
            "DOCKER_CONTEXT",
            "required offline image is missing",
            "`connection` is never replaced",
            "measured TCP connection closed",
            "connection tuple changed during the measured soak",
            "duration_beyond_24_hours=",
            "host.docker.internal",
            "managed-machine p99 protocol RTT exceeded 100ms",
            "sustained >=150ms plateau",
            "managed-machine outbound TCP failed too often",
            "managed-machine outbound TCP had consecutive failures",
            "long-lived soak changed the exact fixture image identity",
            "service fixture survived owned cleanup",
            "managed-machine fixture survived owned cleanup",
            "same_tcp_connection=PASS",
            "machine_to_docker_service=PASS",
            "machine_service_regular_200_400ms_plateau=ABSENT",
            "machine_outbound_tcp=PASS",
            "exact_image_identity=PASS",
            "owned_cleanup=PASS",
            "heartbeats_sha256=",
            "machine_service_sha256=",
            "machine_outbound_sha256=",
            "summary_sha256=",
            "docker_cli_sha256=",
            "same_user_socket=PASS",
            "release_qualifying=",
            "status=PASS",
        ):
            self.assertIn(proof, text, proof)
        for unsafe in (
            "assert ",
            'mkdir -p "$WORKROOT"',
            'DOCKER_HOST="unix://$SOCKET" "$DOCKER"',
            'echo "socket=$SOCKET"',
            'echo "docker=$DOCKER"',
        ):
            self.assertNotIn(unsafe, text, unsafe)

    def test_confirmation_fails_before_socket_cli_or_workroot_access(self) -> None:
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
                    "--image",
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
