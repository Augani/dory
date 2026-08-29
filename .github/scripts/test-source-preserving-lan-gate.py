#!/usr/bin/env python3
"""Non-mutating authority tests for physical source-preserving networking."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "source-preserving-lan-gate.sh"


class SourcePreservingLANGateTests(unittest.TestCase):
    def invoke(
        self,
        app: pathlib.Path,
        runtime: pathlib.Path,
        docker: pathlib.Path,
        workroot: pathlib.Path,
        temporary_root: pathlib.Path,
        *,
        address: str = "192.0.2.10",
        confirmation: str = "PHYSICAL-SOURCE-PRESERVATION",
        ssh_options: tuple[str, ...] = ("StrictHostKeyChecking=yes",),
    ) -> subprocess.CompletedProcess[str]:
        command = [
            str(GATE),
            "--app", str(app),
            "--runtime", str(runtime),
            "--docker", str(docker),
            "--host-address", address,
            "--peer-ssh", "release-peer@example.invalid",
            "--mode", "lan",
            "--server-image", "example.invalid/server@sha256:" + "a" * 64,
            "--workroot", str(workroot),
        ]
        for option in ssh_options:
            command.extend(("--ssh-option", option))
        command.extend(("--confirm", confirmation))
        environment = os.environ.copy()
        environment["RUNNER_TEMP"] = str(temporary_root)
        environment["PYTHONOPTIMIZE"] = "2"
        return subprocess.run(
            command,
            cwd=ROOT,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

    @staticmethod
    def fixture(temporary: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path, pathlib.Path]:
        app = temporary / "Dory.app"
        helpers = app / "Contents" / "Helpers"
        helpers.mkdir(parents=True)
        docker = helpers / "docker"
        docker.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        docker.chmod(0o755)
        runtime = temporary / "dory-engine-runtime"
        runtime.mkdir()
        launcher = runtime / "dory-engine"
        launcher.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        launcher.chmod(0o755)
        return app, runtime, docker

    def test_source_is_shell_valid_and_closes_privileged_helper_ownership(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], cwd=ROOT, check=True)
        source = GATE.read_text(encoding="utf-8")
        self.assertNotIn("assert ", source)
        for contract in (
            "StrictHostKeyChecking=yes",
            '"$DOCKER" = "$APP/Contents/Helpers/docker"',
            "source=Notarized Developer ID",
            "a pre-existing Dory network helper would be replaced",
            "--unregister-network-helper",
            "Dory network helper survived final cleanup",
            "network_helper_unregistered=PASS",
            "host_boot_session_unchanged=PASS",
        ):
            self.assertIn(contract, source)

    def test_confirmation_host_and_ssh_authorities_fail_before_mutation(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dory-source-lan-test.") as raw:
            temporary = pathlib.Path(raw).resolve()
            app, runtime, docker = self.fixture(temporary)
            workroot = temporary / "dory-source-lan-lan"
            confirmation = self.invoke(
                app, runtime, docker, workroot, temporary, confirmation="wrong"
            )
            loopback = self.invoke(
                app, runtime, docker, workroot, temporary, address="127.0.0.1"
            )
            missing_host_key = self.invoke(
                app, runtime, docker, workroot, temporary, ssh_options=()
            )
            disabled_host_key = self.invoke(
                app,
                runtime,
                docker,
                workroot,
                temporary,
                ssh_options=("StrictHostKeyChecking=no",),
            )
        self.assertIn("confirmation token is required", confirmation.stdout)
        self.assertIn("valid unicast IPv4", loopback.stdout)
        self.assertIn("exactly one --ssh-option", missing_host_key.stdout)
        self.assertIn("StrictHostKeyChecking must be yes", disabled_host_key.stdout)

    def test_indirect_app_and_non_candidate_docker_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dory-source-lan-test.") as raw:
            temporary = pathlib.Path(raw).resolve()
            app, runtime, docker = self.fixture(temporary)
            app_link = temporary / "linked-Dory.app"
            app_link.symlink_to(app, target_is_directory=True)
            indirect = self.invoke(
                app_link,
                runtime,
                docker,
                temporary / "dory-source-lan-lan",
                temporary,
            )
            foreign = temporary / "foreign-docker"
            foreign.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            foreign.chmod(0o755)
            wrong_docker = self.invoke(
                app,
                runtime,
                foreign,
                temporary / "dory-source-lan-lan",
                temporary,
            )
        self.assertIn("candidate app must be a direct Dory.app directory", indirect.stdout)
        self.assertIn("Docker CLI is not the exact candidate helper", wrong_docker.stdout)


if __name__ == "__main__":
    unittest.main()
