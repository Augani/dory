#!/usr/bin/env python3
"""Offline contract for linux/amd64 mmdebstrap release qualification."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "nonnative-mmdebstrap-gate.sh"


class NonnativeMmdebstrapGateTests(unittest.TestCase):
    def test_gate_binds_fresh_debian_image_and_proc_less_nested_rootfs(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "ISOLATED-DORY-NONNATIVE-MMDEBSTRAP",
            "Dory socket must be an absolute path",
            "Dory socket is unavailable or indirect",
            "Dory socket is not owned by the release user",
            "Docker CLI must be an absolute path",
            "Docker CLI is unavailable or indirect",
            "--base-image must be digest-pinned",
            "workroot already exists or is indirect",
            "release candidate evidence requires --source-commit",
            "DOCKER_CONTEXT",
            "Debian base image already exists; the gate requires a fresh isolated pull",
            "pull --platform linux/amd64",
            "Debian fixture is not linux/amd64",
            "RUN mmdebstrap --variant=minbase trixie /tmp/rootfs.tar",
            "bad fd number|cat >&10 returned|hooklistener errored",
            "flags: POCF",
            "nested-chroot-shebang-ok",
            "test ! -e /tmp/dory-nested-root/proc/self",
            "private_marker_isolation=PASS",
            "generated linux/amd64 Debian rootfs archive verification failed",
            "Docker API wedged after the mmdebstrap build",
            "builder prune --all --force",
            "mmdebstrap gate image survived cleanup",
            "base_image_id=",
            "built_image_id=",
            "source_commit=",
            "reported_dockerfile_commands=PASS",
            "mmdebstrap_minbase_trixie=PASS",
            "bad_fd_number_absent=PASS",
            "rootfs_archive_readable=PASS",
            "nested_chroot_no_proc=PASS",
            "nested_chroot_shebang=PASS",
            "build_cache_cleanup=PASS",
            "isolated_builder_cache_prune=PASS",
            "owned_cleanup=PASS",
            "docker_cli_sha256=",
            "dockerfile_sha256=",
            "base_inspect_sha256=",
            "build_log_sha256=",
            "run_output_sha256=",
            "release_qualifying=",
            "status=PASS",
        ):
            self.assertIn(proof, text, proof)
        for unsafe in (
            "assert ",
            'mkdir -p "$WORKROOT"',
            'DOCKER_HOST="unix://$SOCKET" "$DOCKER"',
            "--security-opt seccomp=unconfined",
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
