#!/usr/bin/env python3
"""Offline authority tests for the public release orchestrator."""

from __future__ import annotations

import os
import pathlib
import shlex
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
RELEASE = ROOT / "scripts" / "release.sh"


class ReleaseOrchestratorTests(unittest.TestCase):
    @staticmethod
    def run_bash(program: str) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["PYTHONOPTIMIZE"] = "2"
        return subprocess.run(
            ["bash", "-c", program],
            cwd=ROOT,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

    def test_source_is_shell_valid_and_binds_public_release_authority(self) -> None:
        subprocess.run(["bash", "-n", str(RELEASE)], cwd=ROOT, check=True)
        source = RELEASE.read_text(encoding="utf-8")
        self.assertNotIn("assert ", source)
        for contract in (
            "release build directory must be a direct child of the checkout",
            "release build authority is not owned by this user",
            "public releases must use Dory signing team 864H636QW4",
            "scripts/verify-clean-release-source.sh",
            "scripts/verify-macos-deployment-targets.sh",
            "scripts/validate-app-update-payload.sh",
            "source=Notarized Developer ID",
            "scripts/generate-release-sbom.py",
            "scripts/verify-release-sbom.py",
            "scripts/generate-appcast.sh",
            "scripts/build-dory-ffi-xcframework.sh",
            "generated DoryFFI static library must contain arm64 and x86_64",
            "write_release_manifest",
        ):
            self.assertIn(contract, source)

        ffi = source.index("  prepare_release_ffi_bridge\n")
        renderer = source.index("  prepare_release_renderer_host\n")
        archive = source.index('  archive_variant "$VARIANT" "$ARCHIVE"')
        self.assertLess(ffi, renderer)
        self.assertLess(renderer, archive)

    def test_missing_metadata_fails_before_release_mutation(self) -> None:
        result = subprocess.run(
            [str(RELEASE)],
            cwd=ROOT,
            env={**os.environ, "PYTHONOPTIMIZE": "2"},
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        self.assertEqual(result.returncode, 64)
        self.assertIn("usage: scripts/release.sh", result.stdout)

    def test_recursive_build_cleanup_is_confined_to_checkout(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dory-release-orchestrator.") as raw:
            outside = pathlib.Path(raw).resolve() / "release-build-escape"
            result = self.run_bash(
                "set -euo pipefail; "
                "DORY_RELEASE_SOURCE_ONLY=1 "
                f"DORY_RELEASE_BUILD_DIR={shlex.quote(str(outside))} "
                "source scripts/release.sh 1.2.3 4; validate_release_build_dir"
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("direct child of the checkout", result.stdout)

    def test_public_release_rejects_replaceable_signing_team(self) -> None:
        result = self.run_bash(
            "set -euo pipefail; "
            "DORY_RELEASE_SOURCE_ONLY=1 NOTARY_TEAM_ID=TESTTEAM "
            "source scripts/release.sh 1.2.3 4; "
            "DORY_PUBLIC_RELEASE=1 preflight_public_release"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must use Dory signing team 864H636QW4", result.stdout)


if __name__ == "__main__":
    unittest.main()
