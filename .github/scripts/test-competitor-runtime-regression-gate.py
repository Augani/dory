#!/usr/bin/env python3
"""Offline contract for the run-owned competitor-runtime regression qualification gate."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "competitor-runtime-regression-gate.sh"


class CompetitorRuntimeRegressionGateTests(unittest.TestCase):
    def test_gate_is_exact_run_owned_bounded_and_release_bindable(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "ISOLATED-ENGINE-COMPETITOR-REGRESSION",
            "Dory socket must be an absolute path",
            "Dory socket is unavailable or indirect",
            "Dory socket is not owned by the release user",
            "Dory state directory is unavailable or indirect",
            "workroot already exists or is indirect",
            "canonical workroot already exists or is indirect",
            "release candidate evidence requires --source-commit",
            "release candidate image must be digest-pinned",
            "release candidate evidence requires --runtime",
            "release candidate evidence requires --compose",
            "release candidate evidence requires --buildx",
            "standalone runtime is unavailable or indirect",
            "standalone runtime member is missing or indirect",
            "release candidate CLI is unavailable or indirect",
            "engine restart test requires an isolated engine with zero pre-existing containers",
            'label=dev.dory.compatibility=$OWNER',
            'docker_e ps -aq --filter "label=dev.dory.compatibility=$OWNER"',
            'docker_e volume ls -q --filter "label=dev.dory.compatibility=$OWNER"',
            'docker_e network ls -q --filter "label=dev.dory.compatibility=$OWNER"',
            "forwarded-connection-fds",
            "concurrent-proxy-backpressure",
            "compose-v2-lifecycle",
            "network-api-lifecycle",
            "standalone-engine-restart",
            "volume-api-lifecycle",
            "bind-open-fd-stability",
            "image-hardlink-missing-parent",
            "buildkit-concurrent-sessions",
            "buildkit-cache-cancellation",
            "cleanup-restart-persistence",
            "docker_bin_sha256=",
            "compose_bin_sha256=",
            "buildx_bin_sha256=",
            "results_sha256=",
            "status=PASS",
            "release_qualifying=",
            "raise SystemExit",
        ):
            self.assertIn(proof, text, proof)
        for unsafe in (
            "assert ",
            'echo "socket=$SOCKET"',
            'echo "state_dir=$STATE_DIR"',
            'echo "runtime=$RUNTIME"',
            'echo "runtime_home=$RUNTIME_HOME"',
            'echo "docker_bin_resolved=$docker_bin_resolved"',
            'echo "compose_bin_resolved=$compose_bin_resolved"',
            'echo "buildx_bin_resolved=$buildx_bin_resolved"',
            "docker_e system prune",
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
                    "--state-dir",
                    str(pathlib.Path(temporary) / "missing-state"),
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
            self.assertIn("requires --confirm", result.stderr)
            self.assertFalse(workroot.exists())


if __name__ == "__main__":
    unittest.main()
