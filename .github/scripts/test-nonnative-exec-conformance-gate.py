#!/usr/bin/env python3
"""Offline contract for the Apple-Silicon FEX exec-conformance release gate."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "nonnative-exec-conformance-gate.sh"


class NonnativeExecConformanceGateTests(unittest.TestCase):
    def test_gate_binds_exact_socket_cli_images_and_exec_matrix(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        text = GATE.read_text(encoding="utf-8")
        for proof in (
            "ISOLATED-DORY-NONNATIVE-EXEC",
            "Dory socket must be an absolute path",
            "Dory socket is unavailable or indirect",
            "Dory socket is not owned by the release user",
            "Docker CLI must be an absolute path",
            "Docker CLI is unavailable or indirect",
            "fixture images must be digest-pinned",
            "workroot already exists or is indirect",
            "release candidate evidence requires --source-commit",
            "DOCKER_CONTEXT",
            'DOCKER_HOST="unix://$SOCKET"',
            "fixture already exists; the gate requires fresh isolated pulls",
            "image platform does not match linux/",
            "private FEX handoff marker leaked",
            "PR_SET_NO_NEW_PRIVS failed",
            "PR_SET_SECCOMP failed",
            "mkdir bypassed inherited guest seccomp",
            "fd-exec-arguments-buildkit=PASS",
            "fd-exec-null-argv-buildkit=PASS",
            "seccomp-shebang-chain-buildkit=PASS",
            "flags: POCF",
            "docker exec descriptor chain failed",
            "Docker API wedged after exec conformance",
            "builder prune --all --force",
            "base_image_id=",
            "native_image_id=",
            "source_commit=",
            "fex_sha256=",
            "fex_server_sha256=",
            "guest_seccomp_inheritance=PASS",
            "fd_exec_arguments=PASS",
            "fd_exec_null_argv=PASS",
            "buildkit_exec_matrix=PASS",
            "runtime_exec_matrix=PASS",
            "docker_exec_matrix=PASS",
            "isolated_builder_cache_prune=PASS",
            "docker_cli_sha256=",
            "dockerfile_sha256=",
            "build_log_sha256=",
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
                    "--base-image",
                    "invalid",
                    "--native-image",
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
