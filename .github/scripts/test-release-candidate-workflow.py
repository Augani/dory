#!/usr/bin/env python3
"""Static authority checks for the private signed-candidate workflow."""

from __future__ import annotations

import pathlib
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "release-candidate.yml"
RELEASE = ROOT / "scripts" / "release.sh"


class ReleaseCandidateWorkflowTests(unittest.TestCase):
    def test_candidate_is_signed_but_cannot_publish(self) -> None:
        source = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("DORY_PUBLIC_RELEASE_PHASE: candidate", source)
        self.assertIn("DORY_PUBLIC_RELEASE: '1'", source)
        self.assertIn("runs-on: [self-hosted, macOS, arm64, dory, release]", source)
        self.assertIn("DEVELOPER_ID_CERT_P12_BASE64", source)
        self.assertIn("NOTARY_APPLE_ID", source)
        self.assertIn("SPARKLE_PRIVATE_KEY", source)
        self.assertIn("component-candidate-final-verification.receipt", source)
        self.assertIn("dory-signed-release-candidate-", source)
        self.assertIn('test -s "release-build/Dory-$VERSION.dmg"', source)
        self.assertIn('test -s "release-build/Dory-$VERSION.zip"', source)
        self.assertIn("test ! -e release-build/components/arm64/catalog.json", source)
        self.assertIn('"docker-core": 0', source)
        self.assertIn('"kubernetes": 1', source)
        self.assertIn('"linux-machines": 2', source)
        self.assertIn('"linux-desktop": 2', source)
        self.assertIn('"desktop-debian": 4', source)
        self.assertIn('"desktop-ubuntu": 4', source)
        self.assertIn('"desktop-kali": 4', source)
        self.assertIn("permissions:\n  contents: read", source)
        for forbidden in (
            "contents: write",
            "gh release create",
            "publish-github-release.py",
            "publish-pages",
            "bump-cask",
            "catalog.json.sig",
        ):
            self.assertNotIn(forbidden, source)

    def test_candidate_builds_every_modular_guest_from_its_commit(self) -> None:
        source = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("DORY_EXPERIMENTAL_GPU=0 guest/kernel/build.sh arm64", source)
        self.assertIn("DORY_EXPERIMENTAL_GPU=1 guest/kernel/build.sh arm64", source)
        self.assertIn("DORY_KERNEL_PROFILE=accelerated-desktop guest/kernel/build.sh arm64", source)
        for distro in ("debian", "ubuntu", "kali"):
            self.assertIn(
                f"guest/out/dory-desktop-{distro}-rootfs-arm64.ext4.zst",
                source,
            )
        self.assertIn('guest/desktop/build.sh arm64 "$distro"', source)
        self.assertIn('guest/desktop/verify-build.sh arm64 "$distro"', source)

    def test_release_script_keeps_publication_blocked_after_staging(self) -> None:
        subprocess.run(["bash", "-n", str(RELEASE)], cwd=ROOT, check=True)
        source = RELEASE.read_text(encoding="utf-8")
        self.assertIn("preflight_component_candidate_supply_chain", source)
        self.assertIn('candidate) preflight_component_candidate_supply_chain', source)
        self.assertIn('publish) preflight_component_supply_chain', source)
        self.assertIn(
            "no physical Linux VM campaign producer is wired after immutable candidate assembly",
            source,
        )


if __name__ == "__main__":
    unittest.main()
