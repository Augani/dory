#!/usr/bin/env python3
"""Offline contract tests for the cross-container advisory-lock gate."""

from __future__ import annotations

import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "bind-advisory-lock-gate.sh"
PROBE = ROOT / "scripts" / "bind-advisory-lock-probe.py"


class BindAdvisoryLockGateTests(unittest.TestCase):
    def test_gate_and_probe_cover_native_lock_semantics(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], check=True)
        compile(PROBE.read_text(encoding="utf-8"), str(PROBE), "exec")
        gate = GATE.read_text(encoding="utf-8")
        probe = PROBE.read_text(encoding="utf-8")
        for proof in (
            "create-mode-zero",
            "O_CREAT|O_EXCL mode-0000",
            "flock-exclusive-contender",
            "flock-shared-peer",
            "flock-upgrade.blocked",
            "flock-after-crash",
            "record-nonoverlap",
            "record-waiter.acquired",
            "record-after-crash",
            "cross_container_bind_mount=PASS",
            'mktemp -d "$HOME/.dory-bind-lock-gate.XXXXXXXX"',
            "Dory socket is not owned by the release user",
        ):
            self.assertIn(proof, gate, proof)
        for proof in ("fcntl.flock", "fcntl.lockf", "LOCK_NB", "LOCK_UN", "os.O_EXCL"):
            self.assertIn(proof, probe, proof)
        self.assertNotIn("assert ", gate)
        self.assertNotIn("assert ", probe)

    def test_relative_workroot_fails_before_socket_or_docker_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result = subprocess.run(
                [
                    str(GATE),
                    "--socket",
                    str(pathlib.Path(temporary) / "missing.sock"),
                    "--docker",
                    "/missing/docker",
                    "--image",
                    "example.invalid/python@sha256:" + "a" * 64,
                    "--workroot",
                    "relative-evidence",
                    "--confirm",
                    "ISOLATED-DORY-BIND-LOCKS",
                ],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("--workroot must be absolute", result.stderr)


if __name__ == "__main__":
    unittest.main()
