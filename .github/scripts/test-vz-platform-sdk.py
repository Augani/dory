#!/usr/bin/env python3
"""SDK contract fixtures; --require-selected-sdk also validates the actual SDK.

Fixture tests run on ordinary CI without depending on its current Xcode image.
The explicit live SDK gate fails for an unavailable or unreviewed selected SDK.
"""

from __future__ import annotations

import importlib.util
import argparse
import sys
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
    def fixture(self, sdk: Path, *, experimental_usb: bool = False) -> None:
        headers = sdk / "System/Library/Frameworks/Virtualization.framework/Headers"
        headers.mkdir(parents=True)
        sources = {
            "VZMacGraphicsDeviceConfiguration.h": "VZ_EXPORT API_AVAILABLE(macos(12.0)) @interface VZMacGraphicsDeviceConfiguration Maximum of one display is supported.",
            "VZHostAudioInputStreamSource.h": "VZ_EXPORT API_AVAILABLE(macos(12.0)) @interface VZHostAudioInputStreamSource",
            "VZHostAudioOutputStreamSink.h": "VZ_EXPORT API_AVAILABLE(macos(12.0)) @interface VZHostAudioOutputStreamSink",
            "VZMacTrackpadConfiguration.h": "VZ_EXPORT API_AVAILABLE(macos(13.0)) @interface VZMacTrackpadConfiguration",
            "VZMacKeyboardConfiguration.h": "VZ_EXPORT API_AVAILABLE(macos(14.0)) @interface VZMacKeyboardConfiguration",
            "VZVirtualMachineConfiguration.h": "validateSaveRestoreSupportWithError: API_AVAILABLE(macos(14.0))",
            "VZXHCIControllerConfiguration.h": "VZ_EXPORT API_AVAILABLE(macos(15.0)) @interface VZXHCIControllerConfiguration",
            "VZUSBMassStorageDeviceConfiguration.h": "VZ_EXPORT API_AVAILABLE(macos(13.0)) @interface VZUSBMassStorageDeviceConfiguration",
            "Virtualization.h": "#import <Virtualization/VZVirtualMachine.h>",
        }
        if experimental_usb:
            sources["VZUSBPassthroughDeviceConfiguration.h"] = (
                "VZ_EXPORT API_AVAILABLE(macos(27.0)) "
                "initWithDevice:(AAUSBAccessory *)device"
            )
        for name, source in sources.items():
            (headers / name).write_text(source, encoding="utf-8")
        hypervisor = sdk / "System/Library/Frameworks/Hypervisor.framework/Headers"
        hypervisor.mkdir(parents=True)
        (hypervisor / "hv_gic.h").write_text(
            "OS_EXPORT API_AVAILABLE(macos(15.0))\nhv_return_t hv_gic_create(hv_gic_config_t config);",
            encoding="utf-8",
        )

    def test_final_sdk_does_not_require_experimental_usb(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sdk = Path(temporary)
            self.fixture(sdk)
            receipt = VERIFICATION.inspect_sdk(sdk, "26.5")
            self.assertEqual(receipt["status"], "PASS")
            self.assertEqual(receipt["productMinimumHostVersion"], "15.0")
            self.assertEqual(receipt["usbPassthroughAPI"], "not-in-baseline")
            self.assertIsNone(receipt["usbAuthority"])
            self.assertFalse(receipt["releaseQualification"])

    def test_unreviewed_or_malformed_sdk_versions_reject(self) -> None:
        for version in ("15.0", "26.4", "26.6", "27.0", "26.5beta", "26", "-26.5", "26.5.1.2"):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as temporary:
                with self.assertRaises(VERIFICATION.SDKContractFailure):
                    VERIFICATION.inspect_sdk(Path(temporary), version)

    def test_experimental_usb_requires_explicit_scope_and_authority(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sdk = Path(temporary)
            self.fixture(sdk, experimental_usb=True)
            receipt = VERIFICATION.inspect_sdk(sdk, "27.0", experimental_usb=True)
            self.assertEqual(receipt["sdkProfile"], "experimental-usb")
            self.assertEqual(receipt["usbPassthroughAPI"], "experimental-from-macos-27.0")
            self.assertEqual(receipt["usbAuthority"], "AccessoryAccess")
            self.assertFalse(receipt["releaseQualification"])
            with self.assertRaisesRegex(VERIFICATION.SDKContractFailure, "unexpectedly declares"):
                VERIFICATION.inspect_sdk(sdk, "26.5")
            with self.assertRaisesRegex(VERIFICATION.SDKContractFailure, "requires a macOS 27"):
                VERIFICATION.inspect_sdk(sdk, "26.5", experimental_usb=True)

    def test_missing_or_changed_required_api_fails_closed(self) -> None:
        for framework, filename, source in (
            ("Virtualization", "VZMacGraphicsDeviceConfiguration.h", "multiple displays"),
            ("Virtualization", "VZVirtualMachineConfiguration.h", "validateSaveRestoreSupportWithError: API_AVAILABLE(macos(27.0))"),
            ("Virtualization", "VZXHCIControllerConfiguration.h", "VZ_EXPORT API_AVAILABLE(macos(27.0))"),
            ("Virtualization", "VZUSBMassStorageDeviceConfiguration.h", "VZ_EXPORT API_AVAILABLE(macos(27.0))"),
            ("Virtualization", "Virtualization.h", "@interface VZCameraDeviceConfiguration"),
            ("Hypervisor", "hv_gic.h", "API_AVAILABLE(macos(27.0)) hv_return_t hv_gic_create("),
            ("Virtualization", "VZMacKeyboardConfiguration.h", None),
        ):
            with self.subTest(filename=filename), tempfile.TemporaryDirectory() as temporary:
                sdk = Path(temporary)
                self.fixture(sdk)
                target = sdk / f"System/Library/Frameworks/{framework}.framework/Headers" / filename
                if source is None:
                    target.unlink()
                else:
                    target.write_text(source, encoding="utf-8")
                with self.assertRaises(VERIFICATION.SDKContractFailure):
                    VERIFICATION.inspect_sdk(sdk, "26.5")

    def test_experimental_sdk_cannot_pass_without_physical_usb_headers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sdk = Path(temporary)
            self.fixture(sdk)
            with self.assertRaisesRegex(VERIFICATION.SDKContractFailure, "cannot read selected SDK header"):
                VERIFICATION.inspect_sdk(sdk, "27.0", experimental_usb=True)


class VZSelectedSDKTests(unittest.TestCase):
    def test_selected_local_sdk_contract(self) -> None:
        version = VERIFICATION.command("xcrun", "--sdk", "macosx", "--show-sdk-version")
        sdk = Path(VERIFICATION.command("xcrun", "--sdk", "macosx", "--show-sdk-path"))
        receipt = VERIFICATION.inspect_sdk(sdk, version)
        self.assertEqual(receipt["status"], "PASS")
        self.assertEqual(receipt["macGraphicsMaximumDisplays"], 1)
        self.assertEqual(receipt["sdkProfile"], "final-26.5-baseline")
        self.assertEqual(receipt["qualificationScope"], "sdk-contract-only-physical-probes-required")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--require-selected-sdk", action="store_true")
    options, remaining = parser.parse_known_args()
    suites = ["VZPlatformSDKTests"]
    if options.require_selected_sdk:
        suites.append("VZSelectedSDKTests")
    unittest.main(argv=[sys.argv[0], *remaining], defaultTest=suites)
