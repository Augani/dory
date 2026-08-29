#!/usr/bin/env python3
"""Non-mutating arming tests for exact-candidate container-engine performance qualification."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "qualify-container-engine-performance.sh"


class ContainerEnginePerformanceGateTests(unittest.TestCase):
    def invoke(
        self,
        candidate: pathlib.Path,
        workroot: pathlib.Path,
        temporary_root: pathlib.Path,
        *,
        confirmation: str = "CLEAN-BENCHMARK-USER-DELETE-ENGINE-DATA",
        clean_user: bool = True,
        benchmark_user: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["RUNNER_TEMP"] = str(temporary_root)
        environment["PYTHONOPTIMIZE"] = "2"
        for key, enabled in (
            ("DORY_RELEASE_CLEAN_USER", clean_user),
            ("DORY_RELEASE_BENCHMARK_USER", benchmark_user),
        ):
            if enabled:
                environment[key] = "1"
            else:
                environment.pop(key, None)
        digest = "example.invalid/fixture@sha256:" + "a" * 64
        return subprocess.run(
            [
                str(GATE),
                "--candidate-dir", str(candidate),
                "--version", "9.8.7",
                "--build", "42",
                "--source-commit", "b" * 40,
                "--workroot", str(workroot),
                "--alpine-image", digest,
                "--iperf-image", digest,
                "--node-image", digest,
                "--postgres-image", digest,
                "--redis-image", digest,
                "--ruby-image", digest,
                "--composer-image", digest,
                "--curl-image", digest,
                "--probe-url", "https://example.invalid/probe",
                "--download-url", "https://example.invalid/payload",
                "--download-bytes", "4096",
                "--confirm", confirmation,
            ],
            cwd=ROOT,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

    def test_source_is_shell_valid_and_candidate_bound(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], cwd=ROOT, check=True)
        source = GATE.read_text(encoding="utf-8")
        self.assertNotIn("assert ", source)
        for contract in (
            "scripts/validate-release-metadata.py",
            'export PATH="$APP/Contents/Helpers:$PATH"',
            '"$(command -v docker)" = "$CANDIDATE_DOCKER"',
            "codesign --verify --strict --deep",
            "xcrun stapler validate",
            "candidate source commit mismatch",
            "an existing OrbStack installation would be removed",
            "an existing Colima installation would be removed",
            'LIMA_COLIMA_STATE="$HOME/.lima/colima"',
            "host rebooted during the performance campaign",
            "engine_state_removed=PASS",
            "docs/container-engine-performance-qualification.md",
            "dev.dory.container-engine-performance-qualification",
            "cannot authorize Linux VM support or",
        ):
            self.assertIn(contract, source)
        self.assertNotIn("dev.dory.linux-vm-performance-evidence", source)

    def test_explicit_clean_account_arming_precedes_host_or_filesystem_mutation(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dory-performance-gate-test.") as raw:
            temporary = pathlib.Path(raw).resolve()
            candidate = temporary / "candidate"
            candidate.mkdir()
            workroot = temporary / "dory-container-engine-performance"
            no_confirmation = self.invoke(
                candidate, workroot, temporary, confirmation="wrong"
            )
            no_clean_user = self.invoke(
                candidate, workroot, temporary, clean_user=False
            )
            no_benchmark_user = self.invoke(
                candidate, workroot, temporary, benchmark_user=False
            )
        self.assertIn("--confirm CLEAN-BENCHMARK-USER-DELETE-ENGINE-DATA", no_confirmation.stdout)
        self.assertIn("DORY_RELEASE_CLEAN_USER=1 is required", no_clean_user.stdout)
        self.assertIn("DORY_RELEASE_BENCHMARK_USER=1 is required", no_benchmark_user.stdout)

    def test_candidate_and_workroot_authorities_reject_indirection_or_overlap(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dory-performance-gate-test.") as raw:
            temporary = pathlib.Path(raw).resolve()
            candidate = temporary / "candidate"
            candidate.mkdir()
            candidate_link = temporary / "candidate-link"
            candidate_link.symlink_to(candidate, target_is_directory=True)
            indirect = self.invoke(
                candidate_link,
                temporary / "dory-container-engine-performance",
                temporary,
            )
            wrong_name = self.invoke(
                candidate,
                temporary / "performance-output",
                temporary,
            )
            parent = temporary / "dory-container-engine-performance"
            nested_candidate = parent / "candidate"
            nested_candidate.mkdir(parents=True)
            overlap = self.invoke(nested_candidate, parent, temporary)
        self.assertIn("candidate directory must be direct", indirect.stdout)
        self.assertIn(
            "dedicated dory-container-engine-performance name", wrong_name.stdout
        )
        self.assertIn("workroot cannot contain the candidate", overlap.stdout)


if __name__ == "__main__":
    unittest.main()
