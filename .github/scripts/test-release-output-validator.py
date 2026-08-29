#!/usr/bin/env python3
"""Focused clean-checkout tests for the public release-output gate."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / "scripts" / "validate-release-outputs.sh"


class ReleaseOutputValidatorTests(unittest.TestCase):
    def run_validator(self, build_directory: pathlib.Path) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["PYTHONOPTIMIZE"] = "2"
        environment["DORY_RELEASE_OUTPUTS_SKIP_PLATFORM_VALIDATION"] = "1"
        return subprocess.run(
            [str(VALIDATOR), str(build_directory), "9.8.7", "42"],
            cwd=ROOT,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

    def test_validator_is_shell_valid_and_uses_the_strict_metadata_boundary(self) -> None:
        subprocess.run(["bash", "-n", str(VALIDATOR)], cwd=ROOT, check=True)
        source = VALIDATOR.read_text(encoding="utf-8")

        self.assertNotIn("assert ", source)
        self.assertNotIn("DORY_RELEASE_OUTPUTS_SKIP_COMPONENT_SIGNATURE", source)
        self.assertIn("scripts/validate-release-metadata.py", source)
        self.assertIn("scripts/verify-release-sbom.py", source)
        self.assertIn("scripts/verify-distribution-signatures.sh", source)
        self.assertIn("duplicate ZIP member", source)
        self.assertIn("traversing ZIP member", source)
        self.assertIn("contains a symlink that escapes Dory.app", source)
        self.assertIn("build directory has an indirect ancestor", source)

        metadata = source.index("scripts/validate-release-metadata.py")
        platform_skip = source.index(
            'if [ "${DORY_RELEASE_OUTPUTS_SKIP_PLATFORM_VALIDATION:-0}" != "1" ]'
        )
        self.assertLess(metadata, platform_skip)

    def test_missing_build_directory_fails_closed_under_python_optimize(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dory-release-output-test.") as root:
            missing = pathlib.Path(root).resolve() / "missing"
            result = self.run_validator(missing)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("build directory is missing or indirect", result.stdout)

    def test_symlinked_build_directory_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dory-release-output-test.") as root:
            directory = pathlib.Path(root).resolve()
            target = directory / "target"
            target.mkdir()
            link = directory / "release-build-link"
            link.symlink_to(target, target_is_directory=True)
            result = self.run_validator(link)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("build directory is missing or indirect", result.stdout)

    def test_empty_direct_build_directory_rejects_missing_public_artifacts(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dory-release-output-test.") as root:
            result = self.run_validator(pathlib.Path(root).resolve())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("required public artifact is missing or empty", result.stdout)


if __name__ == "__main__":
    unittest.main()
