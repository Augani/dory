#!/usr/bin/env python3
"""Non-mutating contract tests for the clean-user Homebrew release gate."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
GATE = ROOT / "scripts" / "homebrew-install-gate.sh"
SOURCE_COMMIT = "a" * 40


class HomebrewInstallGateTests(unittest.TestCase):
    def invoke(
        self,
        candidate: pathlib.Path,
        workroot: pathlib.Path,
        *,
        clean_user: bool = True,
        confirmation: str = "CLEAN-RELEASE-USER-HOMEBREW-INSTALL",
        temporary_root: pathlib.Path,
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["RUNNER_TEMP"] = str(temporary_root)
        environment["PYTHONOPTIMIZE"] = "2"
        if clean_user:
            environment["DORY_RELEASE_CLEAN_USER"] = "1"
        else:
            environment.pop("DORY_RELEASE_CLEAN_USER", None)
        return subprocess.run(
            [
                str(GATE),
                "--candidate-dir",
                str(candidate),
                "--version",
                "9.8.7",
                "--build",
                "42",
                "--source-commit",
                SOURCE_COMMIT,
                "--workroot",
                str(workroot),
                "--confirm",
                confirmation,
            ],
            cwd=ROOT,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

    def test_source_is_shell_valid_and_has_no_optimizer_bypass(self) -> None:
        subprocess.run(["bash", "-n", str(GATE)], cwd=ROOT, check=True)
        source = GATE.read_text(encoding="utf-8")
        self.assertNotIn("assert ", source)
        for contract in (
            "scripts/validate-release-metadata.py",
            "scripts/verify-release-sbom.py",
            "com.apple.quarantine",
            "source=Notarized Developer ID",
            "data_drive_preserved=PASS",
            "zap_preserved_data=PASS",
            "profile_restoration=PASS",
        ):
            self.assertIn(contract, source)

    def test_confirmation_and_clean_user_guards_precede_mutation(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dory-homebrew-gate-test.") as raw:
            temporary = pathlib.Path(raw).resolve()
            candidate = temporary / "candidate"
            candidate.mkdir()
            workroot = temporary / "dory-homebrew-install"
            missing_confirmation = self.invoke(
                candidate,
                workroot,
                confirmation="wrong",
                temporary_root=temporary,
            )
            missing_clean_user = self.invoke(
                candidate,
                workroot,
                clean_user=False,
                temporary_root=temporary,
            )
        self.assertNotEqual(missing_confirmation.returncode, 0)
        self.assertIn("--confirm CLEAN-RELEASE-USER-HOMEBREW-INSTALL", missing_confirmation.stdout)
        self.assertNotEqual(missing_clean_user.returncode, 0)
        self.assertIn("DORY_RELEASE_CLEAN_USER=1 is required", missing_clean_user.stdout)

    def test_candidate_symlink_is_rejected_before_host_checks(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dory-homebrew-gate-test.") as raw:
            temporary = pathlib.Path(raw).resolve()
            target = temporary / "candidate-target"
            target.mkdir()
            candidate = temporary / "candidate-link"
            candidate.symlink_to(target, target_is_directory=True)
            result = self.invoke(
                candidate,
                temporary / "dory-homebrew-install",
                temporary_root=temporary,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--candidate-dir must be a direct directory", result.stdout)

    def test_workroot_is_restricted_to_owned_runner_temp_namespace(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dory-homebrew-gate-test.") as raw:
            temporary = pathlib.Path(raw).resolve()
            candidate = temporary / "candidate"
            candidate.mkdir()
            wrong_name = self.invoke(
                candidate,
                temporary / "unscoped-output",
                temporary_root=temporary,
            )
            outside = self.invoke(
                candidate,
                ROOT / "dory-homebrew-install",
                temporary_root=temporary,
            )
            target = temporary / "existing-output"
            target.mkdir()
            link = temporary / "dory-homebrew-install"
            link.symlink_to(target, target_is_directory=True)
            symlink = self.invoke(candidate, link, temporary_root=temporary)
            nested_candidate = temporary / "dory-homebrew-install.candidate-parent" / "candidate"
            nested_candidate.mkdir(parents=True)
            overlap = self.invoke(
                nested_candidate,
                nested_candidate.parent,
                temporary_root=temporary,
            )
        self.assertIn("dedicated dory-homebrew-install name", wrong_name.stdout)
        self.assertIn("inside the runner temporary directory", outside.stdout)
        self.assertIn("must not be a symlink", symlink.stdout)
        self.assertIn("cannot contain the candidate", overlap.stdout)


if __name__ == "__main__":
    unittest.main()
