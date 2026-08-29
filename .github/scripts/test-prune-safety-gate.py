#!/usr/bin/env python3
"""Offline contract for destructive prune qualification on an exact isolated engine."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "prune-safety-gate.sh"


class PruneSafetyGateTests(unittest.TestCase):
    def test_gate_proves_exact_preconditions_survivors_victims_and_cleanup(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "ISOLATED-ENGINE-PRUNE",
            "Docker CLI must be an absolute path",
            "Docker CLI is unavailable or indirect",
            "socket is not owned by the release user",
            "workroot already exists or is indirect",
            "dedicated engine must contain exactly the qualified base image",
            "initial system-df does not contain exactly the qualified base image",
            "initial system-df contains pre-existing",
            "--network none --pull=false",
            "prune fixture build returned an invalid image ID",
            "prune fixture containers do not bind the exact built images",
            "fixture engine contains containers outside the exact prune scenario",
            "fixture engine contains volumes outside the exact prune scenario",
            "fixture engine contains custom networks outside the exact prune scenario",
            "fixture engine contains images outside the exact prune scenario",
            "docker_e system prune -af --volumes",
            "docker_e container prune -f",
            "docker_e image prune -af",
            "docker_e network prune -f",
            "docker_e volume prune -af",
            "docker_e builder prune -af",
            "protected volume data changed during prune",
            "stopped victim container survived prune",
            "unused victim image survived prune",
            "unused victim volume survived prune",
            "unused victim network survived prune",
            "post-prune images differ from the protected fixture image",
            "exact_base_image_precondition=PASS",
            "exact_owned_fixture=PASS",
            "active_volume_bytes_preserved=PASS",
            "build_cache_removed=PASS",
            "owned_cleanup=PASS",
            "docker_cli_sha256=",
        ):
            self.assertIn(proof, text, proof)
        self.assertIn(
            "'^[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[0-9a-f]{64}$'", text
        )
        for stale in (
            "assert ",
            "Docker CLI is unavailable\"",
            "^.+@sha256",
        ):
            self.assertNotIn(stale, text, stale)

    def test_confirmation_fails_before_socket_helper_source_or_workroot_access(self) -> None:
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
            self.assertIn("destructive prune requires --confirm", result.stderr)
            self.assertFalse(workroot.exists())


if __name__ == "__main__":
    unittest.main()
