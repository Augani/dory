#!/usr/bin/env python3
"""Run the actual maintenance helper's identity function, never its privileged entry point.

Only plutil reads of test-owned temporary JSON/plist fixtures execute. No signing, receipt,
Installer, launchctl, system-extension, root-path writes or package installation is invoked.
"""

from __future__ import annotations

import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "GuestTools/Packaging/dory-guest-tools-maintenance.sh"
ENTRY_POINT = '\n[ "$(/usr/bin/id -u)" -eq 0 ] || fail '


class MaintenanceIdentityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="dory-tools-identity-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "DoryGuestTools.app"
        self.info = self.app / "Contents/Info.plist"
        self.info.parent.mkdir(parents=True)
        self.manifest = self.root / "retained.pkg.json"
        self.write_installed("1.0.0", "7")
        self.write_manifest("1.0.0", "7")
        self.source = HELPER.read_text(encoding="utf-8")
        definitions, boundary, _ = self.source.partition(ENTRY_POINT)
        self.assertTrue(boundary, "the root-only entry point must remain outside this harness")
        self.definitions = definitions

    def write_installed(self, version: str, build: str | None) -> None:
        document = {
            "CFBundleIdentifier": "com.pythonxi.Dory.GuestTools",
            "CFBundleShortVersionString": version,
        }
        if build is not None:
            document["CFBundleVersion"] = build
        self.info.write_bytes(plistlib.dumps(document))

    def write_manifest(self, version: object, build: object, destination: Path | None = None) -> None:
        (destination or self.manifest).write_text(json.dumps({
            "schema": "dory.macos-guest-tools-package@3",
            "bundleManifest": {"bundle": {
                "identifier": "com.pythonxi.Dory.GuestTools", "version": version, "build": build,
            }},
        }), encoding="utf-8")

    def invoke(self, manifest: Path | None = None) -> subprocess.CompletedProcess[str]:
        # Execute the function definitions directly from the current production source.
        # No copied verifier, rewritten command paths or source-only production bypass exists.
        return subprocess.run(
            ["/bin/sh", "-s", "--", str(self.app), str(manifest or self.manifest)],
            input=self.definitions + '\nverify_installed_bundle_identity "$1" "$2"\n',
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            check=False, timeout=10,
        )

    def test_exact_installed_version_and_build_are_accepted(self) -> None:
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_same_version_different_retained_build_is_rejected(self) -> None:
        self.write_manifest("1.0.0", "6")
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("installed app build differs", result.stderr)

    def test_target_verification_rejects_old_app_even_after_installer_reports_success(self) -> None:
        self.write_manifest("1.1.0", "8")
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("installed app version differs", result.stderr)

    def test_target_build_mismatch_does_not_claim_successful_rollback_to_another_build(self) -> None:
        target = self.root / "target.pkg.json"
        self.write_manifest("1.0.0", "8", target)
        target_result = self.invoke(target)
        self.assertNotEqual(target_result.returncode, 0)
        self.assertIn("installed app build differs", target_result.stderr)
        # The retained current package is still exact; its normal recovery verification works.
        previous_result = self.invoke()
        self.assertEqual(previous_result.returncode, 0, previous_result.stderr)
        # A partial/incorrect recovery must not silently pass just because public versions match.
        self.write_installed("1.0.0", "9")
        incomplete_recovery = self.invoke()
        self.assertNotEqual(incomplete_recovery.returncode, 0)
        self.assertIn("installed app build differs", incomplete_recovery.stderr)

    def test_missing_installed_build_is_rejected(self) -> None:
        self.write_installed("1.0.0", None)
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("installed app build is unavailable", result.stderr)

    def test_manifest_identity_labels_are_bounded_and_nonempty(self) -> None:
        for value in ["", "b" * 65, "contains space", "build\n7", "../7"]:
            for field in ["version", "build"]:
                with self.subTest(value=value, field=field):
                    self.write_manifest(value if field == "version" else "1.0.0",
                                        value if field == "build" else "7")
                    result = self.invoke()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("bundle version/build", result.stderr)

    def test_indirect_installed_metadata_is_rejected_without_changing_target(self) -> None:
        direct = self.root / "other.plist"
        original = self.info.read_bytes()
        direct.write_bytes(original)
        self.info.unlink()
        self.info.symlink_to(direct)
        result = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be a direct regular file", result.stderr)
        self.assertEqual(direct.read_bytes(), original)

    def test_every_package_change_and_recovery_binds_installed_manifest_tuple(self) -> None:
        installed = self.source.split("verify_installed() {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn('verify_installed_bundle_identity "$APP" "$2"', installed)
        # Existing signature/team/package authority checks must remain before the tuple check.
        self.assertLess(installed.index("codesign --verify"),
                        installed.index("verify_installed_bundle_identity"))
        install = self.source.split("install_package() {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn('verify_installed "$installed_agent_sha" "$2"', install)
        self.assertLess(install.index("/usr/sbin/installer"), install.index("verify_installed"))
        update = self.source.split("  update|rollback)", 1)[1].split("  uninstall)", 1)[0]
        self.assertIn('verify_installed "$(field "$5" loginAgent.sha256)" "$5"', update)
        self.assertLess(update.index("verify_installed"), update.index('verify_package "$2" "$3"'))
        self.assertIn('install_package "$4" "$5" || fail', update)


if __name__ == "__main__":
    unittest.main()
