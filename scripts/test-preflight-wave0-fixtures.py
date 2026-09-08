#!/usr/bin/env python3
"""Contract tests for the fail-closed Wave 0 fixture preflight."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PREFLIGHT = ROOT / "scripts/preflight-wave0-fixtures.py"


class FixturePreflightTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="dory-wave0-fixture-preflight-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in (
            "guest/desktop/PINS", "guest/desktop/build.sh",
            "guest/desktop/input-fingerprint.sh", "guest/desktop/verify-build.sh",
        ):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name, encoding="utf-8")
        self.docker = self.root / "docker"
        self.docker.write_text("#!/bin/sh\nprintf '27.0.1\\n'\n", encoding="utf-8")
        self.docker.chmod(0o755)

    def preflight(self, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable, str(PREFLIGHT), "--source-root", str(self.root),
                "--guest-output", str(self.root / "guest/out"),
                "--campaign-root", str(self.root / ".dory-build/wave0-fixtures"),
                "--docker", str(self.docker), "--minimum-free-gib", "1", *extra,
            ],
            check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

    def test_missing_rootfs_is_a_blocker_not_a_fixture_pass(self) -> None:
        result = self.preflight()

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["fixtureReadiness"], "blocked")
        self.assertIn("desktop-rootfs-artifacts-unavailable", payload["blockers"])
        self.assertEqual(payload["campaignRoot"]["status"], "reserved-uncreated")
        self.assertFalse((self.root / ".dory-build/wave0-fixtures").exists())

    def test_only_a_new_owned_scratch_path_can_be_ready(self) -> None:
        output = self.root / "guest/out"
        output.mkdir(parents=True)
        for name in (
            "dory-desktop-debian-rootfs-arm64.ext4.zst",
            "dory-desktop-ubuntu-rootfs-arm64.ext4.zst",
            "dory-desktop-kali-rootfs-arm64.ext4.zst",
        ):
            (output / name).write_bytes(name.encode("ascii"))

        result = self.preflight()

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["fixtureReadiness"], "ready-to-build")
        campaign = self.root / ".dory-build/wave0-fixtures"
        campaign.mkdir(parents=True)
        result = self.preflight()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "campaign-root-is-not-a-new-owned-scratch-path",
            json.loads(result.stdout)["blockers"],
        )

    def test_docker_failure_is_retained_in_an_output_receipt(self) -> None:
        self.docker.write_text("#!/bin/sh\necho socket missing >&2\nexit 1\n", encoding="utf-8")
        receipt = self.root / "receipt.json"

        result = self.preflight("--output", str(receipt))

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(receipt.read_text(encoding="utf-8"))
        self.assertEqual(payload["docker"]["status"], "unavailable")
        self.assertIn("docker-engine-unavailable", payload["blockers"])

    def test_rejects_a_campaign_outside_owned_build_scratch(self) -> None:
        result = subprocess.run(
            [
                sys.executable, str(PREFLIGHT), "--source-root", str(self.root),
                "--campaign-root", str(self.root / "fixtures"), "--docker", str(self.docker),
            ],
            check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("source-root/.dory-build", result.stderr)

    def test_rejects_symlink_inside_owned_scratch_even_if_target_is_inside(self):
        scratch = self.root / ".dory-build"
        scratch.mkdir()
        target = scratch / "target"
        target.mkdir()
        alias = scratch / "alias"
        alias.symlink_to(target)
        result = self.preflight("--campaign-root", str(alias / "new-campaign"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symbolic-link authority", result.stderr)
        self.assertFalse((target / "new-campaign").exists())

    def test_rejects_dangling_output_symlink_without_creating_target(self):
        target = self.root / "missing.json"
        alias = self.root / "alias.json"
        alias.symlink_to(target)
        result = self.preflight("--output", str(alias))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(target.exists())


if __name__ == "__main__":
    unittest.main()
