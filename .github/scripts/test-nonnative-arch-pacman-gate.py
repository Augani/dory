#!/usr/bin/env python3
"""Offline contract for linux/amd64 Arch pacman sandbox qualification."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "nonnative-arch-pacman-gate.sh"


class NonnativeArchPacmanGateTests(unittest.TestCase):
    def test_gate_binds_fresh_arch_image_fex_and_default_pacman_sandbox(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "ISOLATED-DORY-NONNATIVE-ARCH-PACMAN",
            "Dory socket must be an absolute path",
            "Dory socket is unavailable or indirect",
            "Dory socket is not owned by the release user",
            "Docker CLI must be an absolute path",
            "Docker CLI is unavailable or indirect",
            "--base-image must be digest-pinned",
            "workroot already exists or is indirect",
            "release candidate evidence requires --source-commit",
            "DOCKER_CONTEXT",
            "Arch base image already exists; the gate requires a fresh isolated pull",
            "pull --platform linux/amd64",
            "Arch fixture is not linux/amd64",
            "RUN pacman -Sy --noconfirm fzf",
            "--disable-sandbox",
            "competitor's seccomp/sandbox failure",
            "flags: POCF",
            "FEX_ROOTFS",
            "FEX_NEEDSSECCOMP",
            "fex_bundle_read_only=PASS",
            "fex_config_read_only=PASS",
            "fex_private_runtime=PASS",
            "fex_shared_server_socket=PASS",
            "Arch pacman gate image survived cleanup",
            "base_image_id=",
            "source_commit=",
            "pacman_default_sandbox=PASS",
            "alpm_user_switch=PASS",
            "fzf_inventory=PASS",
            "fzf_runtime=PASS",
            "docker_api_after_build=PASS",
            "owned_cleanup=PASS",
            "docker_cli_sha256=",
            "build_output_sha256=",
            "run_output_sha256=",
            "release_qualifying=",
            "status=PASS",
        ):
            self.assertIn(proof, text, proof)
        for unsafe in (
            "assert ",
            'mkdir -p "$WORKROOT"',
            'DOCKER_HOST="unix://$SOCKET" "$DOCKER"',
            "pacman -Sy --noconfirm --disable-sandbox",
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
                    "--base-image",
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
