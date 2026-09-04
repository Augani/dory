#!/usr/bin/env python3
"""Behavior coverage for the frozen public-host/experimental boundary."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "release_host_policy", Path(__file__).with_name("verify-release-host-policy.py")
)
assert SPEC is not None and SPEC.loader is not None
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)
ROOT = Path(__file__).resolve().parents[2]

SDK_SPEC = importlib.util.spec_from_file_location(
    "release_sdk_fixtures", Path(__file__).with_name("test-vz-platform-sdk.py")
)
assert SDK_SPEC is not None and SDK_SPEC.loader is not None
SDK_FIXTURES = importlib.util.module_from_spec(SDK_SPEC)
SDK_SPEC.loader.exec_module(SDK_FIXTURES)


class ReleaseHostPolicyTests(unittest.TestCase):
    def test_exact_public_tuple_is_eligible_but_not_qualified(self) -> None:
        receipt = POLICY.inspect_host("26.6.2", "25G83")
        self.assertTrue(receipt["releaseTestingEligible"])
        self.assertFalse(receipt["releaseQualified"])
        self.assertEqual(receipt["minimumRuntimeMacOS"], "15.0")

    def test_beta_unreviewed_final_and_mismatched_tuples_reject(self) -> None:
        for version, build in (
            ("27.0", "26A5425a"), ("26.5", "25F5071a"),
            ("26.5", "25F999"), ("26.6", "25F71"),
            ("26.5", "25F71"), ("26.6.2", "25G5083a"), ("26.6.1", "25G83"),
            ("15.0", "24A335"), ("27.0", "26A335"),
        ):
            with self.subTest(version=version, build=build):
                with self.assertRaisesRegex(POLICY.HostPolicyFailure, "outside the frozen"):
                    POLICY.inspect_host(version, build)

    def test_malformed_facts_reject_even_in_experimental_mode(self) -> None:
        for version, build in (("26.5beta", "25F71"), ("26.5", "25F71\n"), ("", "")):
            with self.subTest(version=version, build=build):
                with self.assertRaises(POLICY.HostPolicyFailure):
                    POLICY.inspect_host(version, build, experimental=True)

    def test_experimental_mode_never_returns_release_eligibility(self) -> None:
        for version, build in (("27.0", "26A5425a"), ("26.6.2", "25G83")):
            with self.subTest(version=version):
                receipt = POLICY.inspect_host(version, build, experimental=True)
                self.assertEqual(receipt["status"], "EXPERIMENTAL")
                self.assertFalse(receipt["releaseTestingEligible"])
                self.assertFalse(receipt["releaseQualified"])

    def test_cli_rejects_beta_without_writing_a_passing_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "receipt.json"
            with patch.object(POLICY, "observed_version", side_effect=["27.0", "26A5425a"]), \
                 patch("sys.argv", ["verify-release-host-policy.py", "--output", str(output)]), \
                 contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(POLICY.main(), 1)
            self.assertFalse(output.exists())

    def test_cli_experimental_capture_cannot_pass_a_shell_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "receipt.json"
            with patch.object(POLICY, "observed_version", side_effect=["27.0", "26A5425a"]), \
                 patch("sys.argv", ["verify-release-host-policy.py", "--experimental", "--output", str(output)]):
                self.assertEqual(POLICY.main(), 3)
            receipt = json.loads(output.read_text())
            self.assertFalse(receipt["releaseTestingEligible"])
            self.assertEqual(receipt["hostBuild"], "26A5425a")


class ReleaseScriptPreflightTests(unittest.TestCase):
    """Source release functions only; fake host tools cannot archive or sign an app."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.sdk = self.root / "MacOSX.sdk"
        SDK_FIXTURES.VZPlatformSDKTests().fixture(self.sdk)
        self.calls = self.root / "tool-calls"
        commands = {
            "xcodebuild": 'test "$*" = "-version" || exit 99\nprintf "Xcode %s\\nBuild version %s\\n" "$DORY_TEST_XCODE_VERSION" "$DORY_TEST_XCODE_BUILD"',
            "sw_vers": 'case "$1" in -productVersion) printf "%s\\n" "$DORY_TEST_HOST_VERSION";; -buildVersion) printf "%s\\n" "$DORY_TEST_HOST_BUILD";; *) exit 99;; esac',
            "uname": 'test "$*" = "-m" || exit 99\nprintf "%s\\n" "$DORY_TEST_HOST_ARCH"',
            "xcrun": 'case "$*" in "--sdk macosx --show-sdk-version") printf "%s\\n" "$DORY_TEST_SDK_VERSION";; "--sdk macosx --show-sdk-path") printf "%s\\n" "$DORY_TEST_SDK_PATH";; *) exit 99;; esac',
        }
        for name, body in commands.items():
            tool = self.bin / name
            tool.write_text(
                '#!/bin/bash\nset -eu\nprintf "%s %s\\n" "${0##*/}" "$*" >> "$DORY_TEST_TOOL_CALLS"\n' + body + "\n"
            )
            tool.chmod(0o755)
        self.environment = {
            key: value for key, value in os.environ.items()
            if not key.startswith("DORY_")
        }
        self.environment.update({
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "DEVELOPER_DIR": str(self.root / "Xcode.app/Contents/Developer"),
            "DORY_RELEASE_SOURCE_ONLY": "1",
            "DORY_PUBLIC_RELEASE": "1",
            "DORY_TEST_RELEASE_SCRIPT": str(ROOT / "scripts/release.sh"),
            "DORY_TEST_TOOL_CALLS": str(self.calls),
            "DORY_TEST_XCODE_VERSION": "26.6",
            "DORY_TEST_XCODE_BUILD": "17F113",
            "DORY_TEST_HOST_VERSION": "26.6.2",
            "DORY_TEST_HOST_BUILD": "25G83",
            "DORY_TEST_HOST_ARCH": "arm64",
            "DORY_TEST_SDK_VERSION": "26.5",
            "DORY_TEST_SDK_PATH": str(self.sdk),
        })

    def run_preflight(self, command: str = "preflight_public_toolchain", **overrides: str):
        environment = {**self.environment, **overrides}
        return subprocess.run(
            ["/bin/bash", "-c", 'source "$DORY_TEST_RELEASE_SCRIPT" 1.2.3 42\n' + command],
            cwd=ROOT, env=environment, text=True, capture_output=True, timeout=20,
        )

    def test_final_toolchain_host_and_sdk_pass_without_qualification(self) -> None:
        result = self.run_preflight()
        self.assertEqual(result.returncode, 0, result.stderr)
        receipts = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(receipts), 2)
        self.assertTrue(receipts[0]["releaseTestingEligible"])
        self.assertFalse(receipts[0]["releaseQualified"])
        self.assertEqual(receipts[1]["sdkProfile"], "final-26.5-baseline")
        self.assertFalse(receipts[1]["releaseQualification"])

    def test_rc_and_unreviewed_xcode_builds_reject(self) -> None:
        for version, build in (("26.6", "17F109"), ("26.6", "17F999"), ("27.0", "17F113")):
            with self.subTest(version=version, build=build):
                result = self.run_preflight(DORY_TEST_XCODE_VERSION=version, DORY_TEST_XCODE_BUILD=build)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("17F113", result.stderr)

    def test_beta_and_non_apple_silicon_hosts_reject(self) -> None:
        for changes in (
            {"DORY_TEST_HOST_VERSION": "27.0", "DORY_TEST_HOST_BUILD": "26A5425a"},
            {"DORY_TEST_HOST_ARCH": "x86_64"},
        ):
            with self.subTest(changes=changes):
                result = self.run_preflight(**changes)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("release", result.stderr)

    def test_wrong_missing_and_incompatible_sdk_reject(self) -> None:
        for changes in (
            {"DORY_TEST_SDK_VERSION": "27.0"},
            {"DORY_TEST_SDK_PATH": str(self.root / "missing.sdk")},
        ):
            with self.subTest(changes=changes):
                result = self.run_preflight(**changes)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("SDK contract: FAIL", result.stderr)
        (self.sdk / "System/Library/Frameworks/Hypervisor.framework/Headers/hv_gic.h").unlink()
        result = self.run_preflight()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("hv_gic.h", result.stderr)

    def test_public_entrypoint_invokes_the_host_gate(self) -> None:
        result = self.run_preflight(
            "preflight_public_release",
            DORY_TEST_HOST_VERSION="27.0", DORY_TEST_HOST_BUILD="26A5425a",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outside the frozen public release-testing host policy", result.stderr)

    def test_development_preflight_does_not_impose_public_policy(self) -> None:
        result = self.run_preflight(
            "preflight_public_release", DORY_PUBLIC_RELEASE="0",
            DORY_TEST_XCODE_BUILD="17F109",
            DORY_TEST_HOST_VERSION="27.0", DORY_TEST_HOST_BUILD="26A5425a",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.calls.exists())

    def test_public_default_selection_uses_final_xcode(self) -> None:
        result = self.run_preflight('printf "%s\\n" "$DEVELOPER_DIR"', DEVELOPER_DIR="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "/Applications/Xcode-26.6.app/Contents/Developer")
        self.assertFalse(self.calls.exists())


if __name__ == "__main__":
    unittest.main()
