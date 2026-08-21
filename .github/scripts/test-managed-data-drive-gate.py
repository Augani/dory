#!/usr/bin/env python3
"""Offline contract for managed durable-data-drive release qualification."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "managed-data-drive-gate.sh"


class ManagedDataDriveGateTests(unittest.TestCase):
    def test_gate_binds_candidate_and_exact_durable_object_continuity(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "ISOLATED-ENGINE-MANAGED-DATA-DRIVE",
            "physical Apple silicon is required",
            "runtime must be an absolute path",
            "runtime is unavailable or indirect",
            "Docker CLI must be an absolute path",
            "Docker CLI is unavailable or indirect",
            "runtime member is missing or indirect",
            "workroot already exists or is indirect",
            "isolated HOME exists or is indirect",
            "temporary alias path already exists or is indirect",
            "release candidate evidence requires --source-commit",
            "release candidate image must be digest-pinned",
            "release candidate image is not preloaded in the isolated engine",
            "engine socket is missing or indirect after first start",
            "engine socket is not owned by the release user",
            "first-launch retry left its partial bundle",
            "interrupted first launch adopted a different drive identity",
            "missing metadata silently adopted a different drive",
            "running engine accepted a different drive",
            "missing external volume was accepted",
            "a second engine attached the live drive",
            "stopped runtime silently created a replacement selected drive",
            "transient runtime replacement changed the image identity",
            "transient runtime replacement changed the container identity",
            "transient runtime replacement changed the network identity",
            "drive manifest has an unexpected shape",
            "selection authority differs from the drive manifest",
            "exact_image_identity=PASS",
            "exact_container_identity=PASS",
            "exact_network_identity=PASS",
            "same_user_engine_socket=PASS",
            "release_qualifying=",
            "source_commit=",
            "docker_cli_sha256=",
            "dory_engine_sha256=",
            "dory_hv_sha256=",
            "gvproxy_sha256=",
            "dataplane_proxy_sha256=",
            "kernel_asset_sha256=",
            "rootfs_asset_sha256=",
            "agent_asset_sha256=",
            "drive_manifest_sha256=",
            "selection_authority_sha256=",
            "status=PASS",
        ):
            self.assertIn(proof, text, proof)
        for unsafe in (
            "assert ",
            'mkdir -p "$WORKROOT"',
            'rm -rf "$WORKROOT"',
        ):
            self.assertNotIn(unsafe, text, unsafe)

    def test_confirmation_fails_before_architecture_runtime_or_workroot_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workroot = pathlib.Path(temporary) / "must-not-exist"
            result = subprocess.run(
                [
                    "bash",
                    str(GATE),
                    "--runtime",
                    "/missing/runtime",
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
