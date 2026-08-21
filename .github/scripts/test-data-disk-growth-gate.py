#!/usr/bin/env python3
"""Offline contract for sparse Docker data-disk growth qualification."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "data-disk-growth-gate.sh"


class DataDiskGrowthGateTests(unittest.TestCase):
    def test_gate_binds_helpers_storage_authority_and_unprivileged_probes(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "ISOLATED-RUNTIME-DATA-DISK-GROWTH",
            "runtime must be absolute",
            "Docker CLI must be absolute",
            "candidate helper is unavailable or indirect",
            "--image must be an exact digest reference",
            "workroot already exists or is indirect",
            "mke2fs is required as a direct executable",
            "data-disk growth Unix socket path is",
            "runtime socket is unavailable or owned by another user",
            'docker_e pull "$IMAGE"',
            "local probe image does not retain its exact registry authority",
            'docker_e volume create --label "$LABEL" "$NAME"',
            "growth volume differs from its exact run authority",
            "--rm --pull=never --network none --label",
            '--mount "type=volume,src=$NAME,dst=/data"',
            "df -Pk /data",
            "resize/fstrim startup took",
            "boot-time fstrim evidence",
            "named-volume marker changed after restart",
            "helper grew a disk still attached to the running VM",
            "pre-growth capacity response is not initialized at 128 GiB",
            "explicit growth response is not exactly 256 GiB",
            "e2fsck_mode=forced-preen",
            "explicit growth did not use a forced offline preen",
            "owned probe container survived completion",
            "owned volume cleanup failed",
            "dory_engine_sha256=",
            "dory_hv_sha256=",
            "docker_cli_sha256=",
            "mke2fs_sha256=",
            "exact_candidate_helpers=PASS",
            "exact_probe_image=PASS",
            "network_isolated_probes=PASS",
            "privileged_host_bind_absent=PASS",
            "discard_reclaim=PASS",
            "explicit_capacity_growth=PASS",
            "owned_container_cleanup=PASS",
            "owned_volume_cleanup=PASS",
            "runtime_shutdown=PASS",
        ):
            self.assertIn(proof, text, proof)
        self.assertIn(
            "'^[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[0-9a-f]{64}$'", text
        )
        for stale in (
            "alpine:3.20",
            "--privileged",
            "-v /:/host",
            "/host/var/lib/docker",
            "assert ",
            "runtime=$RUNTIME",
        ):
            self.assertNotIn(stale, text, stale)

    def test_confirmation_fails_before_helpers_runtime_home_or_workroot_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workroot = pathlib.Path(temporary) / "must-not-exist"
            runtime_home = pathlib.Path(temporary) / "runtime-must-not-exist"
            result = subprocess.run(
                [
                    "bash",
                    str(GATE),
                    "--runtime",
                    "/missing/runtime",
                    "--docker",
                    "/missing/docker",
                    "--image",
                    "invalid",
                    "--workroot",
                    str(workroot),
                ],
                cwd=ROOT,
                env={
                    **os.environ,
                    "HOME": temporary,
                    "DORY_DATA_DISK_RUNTIME_HOME": str(runtime_home),
                },
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("requires --confirm", result.stderr)
            self.assertFalse(workroot.exists())
            self.assertFalse(runtime_home.exists())


if __name__ == "__main__":
    unittest.main()
