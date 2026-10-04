#!/usr/bin/env python3
"""Non-mutating arming tests for the physical VZ native-IPv6 gate."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "vz-native-ipv6-gate.sh"

class VZNativeIPv6GateTests(unittest.TestCase):
    @staticmethod
    def fixture(temporary: pathlib.Path) -> dict[str, pathlib.Path]:
        paths = {
            name: temporary / name
            for name in ("dory-vmm", "gvproxy", "kernel", "rootfs", "docker")
        }
        for name, path in paths.items():
            path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            if name in {"dory-vmm", "gvproxy", "docker"}:
                path.chmod(0o755)
        return paths

    @staticmethod
    def invoke(
        paths: dict[str, pathlib.Path],
        temporary: pathlib.Path,
        *,
        workroot_name: str = "dory-vz-native-ipv6-evidence",
        extra: tuple[str, ...] = (),
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["RUNNER_TEMP"] = str(temporary)
        environment["PYTHONOPTIMIZE"] = "2"
        return subprocess.run(
            [
                str(GATE),
                "--dory-vmm", str(paths["dory-vmm"]),
                "--gvproxy", str(paths["gvproxy"]),
                "--kernel", str(paths["kernel"]),
                "--rootfs", str(paths["rootfs"]),
                "--docker", str(paths["docker"]),
                "--workroot", str(temporary / workroot_name),
                *extra,
            ],
            cwd=ROOT,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

    def test_indirect_input_fails_before_physical_host_probe(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dory-vz-ipv6-test.") as raw:
            temporary = pathlib.Path(raw).resolve()
            paths = self.fixture(temporary)
            linked = temporary / "linked-dory-vmm"
            linked.symlink_to(paths["dory-vmm"])
            paths["dory-vmm"] = linked
            result = self.invoke(paths, temporary)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("input must be a direct file", result.stdout)

    def test_source_confirmation_and_workroot_authority_fail_before_mutation(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dory-vz-ipv6-test.") as raw:
            temporary = pathlib.Path(raw).resolve()
            paths = self.fixture(temporary)
            confirmation = self.invoke(
                paths,
                temporary,
                extra=("--app", str(temporary / "Dory.app"), "--source-confirm", "wrong"),
            )
            workroot = self.invoke(paths, temporary, workroot_name="unscoped")
        self.assertIn("exact confirmation token", confirmation.stdout)
        self.assertIn("dedicated VZ gate name", workroot.stdout)

if __name__ == "__main__":
    unittest.main()
