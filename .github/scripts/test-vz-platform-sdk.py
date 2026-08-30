#!/usr/bin/env python3
"""Regression tests for the selected VZMac public SDK contract."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VERIFIER = ROOT / ".github/scripts/verify-vz-platform-sdk.py"


def load_verifier():
    specification = importlib.util.spec_from_file_location("vz_sdk_verifier", VERIFIER)
    if specification is None or specification.loader is None:
        raise RuntimeError("cannot load VZ SDK verifier")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


VERIFICATION = load_verifier()


class VZPlatformSDKTests(unittest.TestCase):
    def test_pre_27_sdk_fails_before_header_access(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(VERIFICATION.SDKContractFailure, "predates"):
                VERIFICATION.inspect_sdk(Path(temporary), "26.6")

    def test_selected_local_sdk_contract_when_available(self) -> None:
        version = subprocess.run(
            ["xcrun", "--sdk", "macosx", "--show-sdk-version"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        ).stdout.strip()
        if int(version.split(".", 1)[0]) < 27:
            self.skipTest("local SDK predates the Phase 0A final VZ USB contract")
        sdk = Path(subprocess.run(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        ).stdout.strip())
        receipt = VERIFICATION.inspect_sdk(sdk, version)
        self.assertEqual(receipt["status"], "PASS")
        self.assertEqual(receipt["macGraphicsMaximumDisplays"], 1)
        self.assertEqual(receipt["usbPassthroughAPI"], "public-from-macos-27.0")
        self.assertEqual(
            receipt["qualificationScope"],
            "sdk-contract-only-physical-probes-required",
        )

    def test_release_job_is_fail_closed_and_preserves_receipt(self) -> None:
        workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        self.assertIn("Bind VZMac paths to the selected final public SDK", workflow)
        self.assertIn("DEVELOPER_DIR: /Library/Developer/CommandLineTools", workflow)
        self.assertIn('test -d "$DEVELOPER_DIR/SDKs/MacOSX.sdk"', workflow)
        self.assertIn("verify-vz-platform-sdk.py", workflow)
        self.assertIn("dory-vz-platform-sdk.json", workflow)


if __name__ == "__main__":
    unittest.main()
