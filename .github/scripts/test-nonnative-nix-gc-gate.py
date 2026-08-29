#!/usr/bin/env python3
"""Offline contract for linux/amd64 Nix garbage-collection qualification."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "nonnative-nix-gc-gate.sh"


class NonnativeNixGCGateTests(unittest.TestCase):
    def test_gate_binds_fresh_amd64_image_and_exact_gc_outcome(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "ISOLATED-DORY-NONNATIVE-NIX-GC",
            "Dory socket must be an absolute path",
            "Dory socket is unavailable or indirect",
            "Dory socket is not owned by the release user",
            "Docker CLI must be an absolute path",
            "Docker CLI is unavailable or indirect",
            "--image must be digest-pinned",
            "workroot already exists or is indirect",
            "release candidate evidence requires --source-commit",
            "DOCKER_CONTEXT",
            "Nix fixture already exists; the gate requires a fresh isolated pull",
            "pull --platform linux/amd64",
            "Nix fixture is not linux/amd64",
            'version="$(nix --version)"',
            'nix-collect-garbage --delete-old',
            "gc_deleted_unreachable_path=PASS",
            "Docker API wedged after non-native Nix GC",
            "Nix fixture survived local cleanup",
            "image_id=",
            "source_commit=",
            "nix_version=2.34.7",
            "fresh_pull=PASS",
            "unreachable_store_path_created=PASS",
            "nix_collect_garbage_delete_old=PASS",
            "unreachable_store_path_deleted=PASS",
            "owned_cleanup=PASS",
            "docker_cli_sha256=",
            "run_output_sha256=",
            "release_qualifying=",
            "status=PASS",
        ):
            self.assertIn(proof, text, proof)
        for unsafe in (
            "assert ",
            'mkdir -p "$WORKROOT"',
            'DOCKER_HOST="unix://$SOCKET" "$DOCKER"',
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
