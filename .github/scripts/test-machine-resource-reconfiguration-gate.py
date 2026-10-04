#!/usr/bin/env python3
"""Offline safety and CLI contract for the physical VM resource gate."""

from __future__ import annotations

import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "machine-resource-reconfiguration-gate.sh"

class MachineResourceReconfigurationGateTests(unittest.TestCase):

    def test_symlinked_candidate_input_fails_before_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            ctl = root / "dorydctl"
            ctl.write_text("#!/bin/sh\nexit 99\n", encoding="utf-8")
            ctl.chmod(0o700)
            kernel = root / "kernel"
            kernel.write_bytes(b"kernel")
            kernel_link = root / "kernel-link"
            kernel_link.symlink_to(kernel)
            rootfs = root / "rootfs"
            rootfs.write_bytes(b"rootfs")
            work = root / "evidence"

            result = subprocess.run(
                [
                    str(GATE),
                    "--ctl",
                    str(ctl),
                    "--kernel",
                    str(kernel_link),
                    "--rootfs",
                    str(rootfs),
                    "--workroot",
                    str(work),
                    "--confirm",
                    "ISOLATED-DORY-MACHINE-RESOURCES",
                ],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("kernel is not an exact regular file", result.stderr)
            self.assertFalse(work.exists())

if __name__ == "__main__":
    unittest.main()
