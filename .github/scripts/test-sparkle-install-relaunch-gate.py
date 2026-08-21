#!/usr/bin/env python3
"""Non-mutating arming tests for the exact-candidate Sparkle install gate."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "sparkle-install-relaunch-gate.sh"


class SparkleInstallRelaunchGateTests(unittest.TestCase):
    def invoke(
        self,
        paths: dict[str, pathlib.Path],
        temporary_root: pathlib.Path,
        *,
        confirmation: str = "CLEAN-RELEASE-USER-SPARKLE-INSTALL",
        clean_user: bool = True,
        build_only: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        command = [
            str(GATE),
            "--candidate-app", str(paths["app"]),
            "--update-zip", str(paths["update"]),
            "--appcast", str(paths["appcast"]),
            "--release-manifest", str(paths["manifest"]),
            "--sbom", str(paths["sbom"]),
            "--sparkle-source", str(paths["sparkle"]),
            "--version", "9.8.7",
            "--build", "42",
            "--source-commit", "a" * 40,
            "--workroot", str(temporary_root / "dory-release-live-sparkle"),
        ]
        if build_only:
            command.append("--build-only")
        else:
            command.extend(("--confirm", confirmation))
        environment = os.environ.copy()
        environment["RUNNER_TEMP"] = str(temporary_root)
        environment["PYTHONOPTIMIZE"] = "2"
        if clean_user:
            environment["DORY_RELEASE_CLEAN_USER"] = "1"
        else:
            environment.pop("DORY_RELEASE_CLEAN_USER", None)
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
    def fixture(temporary: pathlib.Path) -> dict[str, pathlib.Path]:
        paths = {
            "app": temporary / "Dory.app",
            "update": temporary / "Dory-9.8.7-app-update.zip",
            "appcast": temporary / "appcast.xml",
            "manifest": temporary / "release-manifest.json",
            "sbom": temporary / "Dory-9.8.7.cdx.json",
            "sparkle": temporary / "Sparkle",
        }
        paths["app"].mkdir()
        paths["sparkle"].mkdir()
        for key in ("update", "appcast", "manifest", "sbom"):
            paths[key].write_text("fixture\n", encoding="utf-8")
        return paths

    def test_source_is_shell_valid_optimizer_safe_and_exactly_bound(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], cwd=ROOT, check=True)
        source = GATE.read_text(encoding="utf-8")
        self.assertNotIn("assert ", source)
        for contract in (
            "scripts/validate-release-metadata.py",
            "scripts/verify-sparkle-update.sh",
            "scripts/verify-release-sbom.py",
            "--untracked-files=all",
            "source=Notarized Developer ID",
            "candidate metadata source commit mismatch",
            "run evidence authority already exists",
            "atomic_install_swap=PASS",
            "different_relaunch_pid=PASS",
            "docker_context_removed=PASS",
            "daemon_processes_stopped=PASS",
            "initial_clean_user_state_restored=PASS",
        ):
            self.assertIn(contract, source)

    def test_live_execution_requires_confirmation_and_clean_release_user(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dory-sparkle-gate-test.") as raw:
            temporary = pathlib.Path(raw).resolve()
            paths = self.fixture(temporary)
            confirmation = self.invoke(paths, temporary, confirmation="wrong")
            clean_user = self.invoke(paths, temporary, clean_user=False)
        self.assertIn("--confirm CLEAN-RELEASE-USER-SPARKLE-INSTALL", confirmation.stdout)
        self.assertIn("DORY_RELEASE_CLEAN_USER=1", clean_user.stdout)

    def test_build_only_still_rejects_indirect_candidate_input(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dory-sparkle-gate-test.") as raw:
            temporary = pathlib.Path(raw).resolve()
            paths = self.fixture(temporary)
            linked = temporary / "linked-Dory.app"
            linked.symlink_to(paths["app"], target_is_directory=True)
            paths["app"] = linked
            result = self.invoke(paths, temporary, build_only=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("required path is unavailable or indirect", result.stdout)


if __name__ == "__main__":
    unittest.main()
