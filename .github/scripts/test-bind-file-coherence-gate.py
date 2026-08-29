#!/usr/bin/env python3
"""Offline contract for direct-file bind coherence qualification."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "bind-file-coherence-gate.sh"


class BindFileCoherenceGateTests(unittest.TestCase):
    def test_gate_binds_exact_runtime_mounts_and_all_coherence_phases(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "ISOLATED-ENGINE-BIND-FILE-COHERENCE",
            "Docker CLI must be an absolute path",
            "Docker CLI is unavailable or indirect",
            "socket is not owned by the release user",
            "workroot already exists or is indirect",
            "probe image must be an exact digest reference",
            'docker_e run -d --pull=never --network none --name "$NAME"',
            '--mount "type=bind,src=$SHARE,dst=/work"',
            '--mount "type=bind,src=$FILE,dst=/single/value.bin"',
            "bind probe did not launch the exact qualified image",
            "bind probe is missing its exact ownership label",
            "bind probe unexpectedly has network access",
            "bind probe mount graph differs from the exact host sources",
            "guest retained stale metadata/content",
            "same-inode-shrink",
            "same-inode-grow",
            "same-inode-content",
            "atomic-replacement-pinned-direct",
            "direct-rebind-after-replacement",
            "guest-truncate",
            'docker_e ps -aq --filter "label=$LABEL"',
            "exact_container_authority=PASS",
            "network_isolation=PASS",
            "direct_single_file_recreate_cycles=%s",
            "same_inode_shrink=PASS",
            "same_inode_grow=PASS",
            "same_inode_content_refresh=PASS",
            "direct_atomic_replacement_pins_inode=PASS",
            "direct_rebind_follows_replacement=PASS",
            "guest_to_host_truncation=PASS",
            "owned_container_cleanup=PASS",
            "docker_cli_sha256=",
            "results_sha256=",
        ):
            self.assertIn(proof, text, proof)
        self.assertIn(
            "'^[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[0-9a-f]{64}$'", text
        )
        for stale in (
            "alpine:latest",
            "--pull never",
            "docker_e rm -f $owned",
            'ids="$(docker_e ps -aq)"',
            "docker_e volume rm",
            "docker_e network rm",
            "assert ",
        ):
            self.assertNotIn(stale, text, stale)

    def test_confirmation_fails_before_socket_helper_image_or_workroot_access(self) -> None:
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
                env={
                    **os.environ,
                    "HOME": temporary,
                    "DORY_BIND_COHERENCE_CONFIRM": "",
                },
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
