#!/usr/bin/env python3
"""Offline contract for default multi-platform image selection qualification."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "default-platform-image-gate.sh"


class DefaultPlatformImageGateTests(unittest.TestCase):
    def test_gate_binds_candidate_default_selection_and_reporting_surfaces(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "ISOLATED-ENGINE-DEFAULT-PLATFORM",
            "Dory socket is not owned by the release user",
            "Docker CLI must be an absolute path",
            "Docker CLI is unavailable or indirect",
            "workroot already exists or is indirect",
            "qualification engine is not empty",
            "# Intentionally no --platform here.",
            'docker_e pull "$IMAGE"',
            'docker_e create --pull=never --name "$NAME"',
            "container did not use the exact requested image",
            "container does not carry the exact run authority label",
            "default-platform container binds host paths",
            "fresh qualification store contains",
            "image-list and system-df storage bytes disagree",
            "local image does not retain the exact requested manifest-list authority",
            'docker_e ps -aq --filter "label=dev.dory.default-platform=$OWNER"',
            "fresh_empty_store=PASS",
            "default_pull_without_platform=PASS",
            "single_platform_local_image=PASS",
            "default_run_architecture=PASS",
            "exact_container_image=PASS",
            "host_path_free_container=PASS",
            "image_list_system_df_reconciled=PASS",
            "owned_container_cleanup=PASS",
            "docker_cli_sha256=",
        ):
            self.assertIn(proof, text, proof)
        self.assertIn(
            "'^[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[0-9a-f]{64}$'", text
        )
        self.assertNotIn('docker_e pull --platform', text)
        for stale in (
            "assert ",
            'ids="$(docker_e ps -aq)"',
            "docker_e volume rm",
            "docker_e network rm",
            'echo "socket=$SOCKET"',
            'echo "docker=$DOCKER"',
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
