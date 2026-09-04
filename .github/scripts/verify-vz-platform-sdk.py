#!/usr/bin/env python3
"""Check the final P00 SDK baseline, or an explicitly experimental USB SDK."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


class SDKContractFailure(RuntimeError):
    pass


def command(*arguments: str) -> str:
    result = subprocess.run(
        list(arguments),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise SDKContractFailure(
            f"command failed ({' '.join(arguments)}): {result.stderr.strip()}"
        )
    return result.stdout.strip()


def read_header(headers: Path, name: str) -> str:
    path = headers / name
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise SDKContractFailure(f"cannot read selected SDK header {path}: {error}") from error


def require(source: str, pattern: str, label: str) -> None:
    if re.search(pattern, source, re.MULTILINE) is None:
        raise SDKContractFailure(f"selected SDK does not prove {label}")


def require_class(source: str, name: str, minimum: str) -> None:
    require(
        source,
        r"VZ_EXPORT API_AVAILABLE\(macos\(" + re.escape(minimum)
        + r"\)\)\s*@interface " + re.escape(name) + r"\b",
        f"{name} availability on macOS {minimum}",
    )


def inspect_sdk(
    sdk: Path, sdk_version: str, *, experimental_usb: bool = False
) -> dict[str, object]:
    if re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", sdk_version) is None:
        raise SDKContractFailure(f"invalid selected SDK version: {sdk_version}")
    version = tuple(int(part) for part in sdk_version.split("."))
    if experimental_usb and version[0] < 27:
        raise SDKContractFailure(
            "experimental physical USB inspection requires a macOS 27 or later SDK"
        )
    if not experimental_usb and version not in {(26, 5), (26, 5, 0)}:
        raise SDKContractFailure(
            f"selected SDK {sdk_version} differs from the frozen final SDK 26.5 baseline; "
            "macOS 27 USB inspection requires --experimental-usb"
        )
    headers = sdk / "System/Library/Frameworks/Virtualization.framework/Headers"
    graphics = read_header(headers, "VZMacGraphicsDeviceConfiguration.h")
    audio_input = read_header(headers, "VZHostAudioInputStreamSource.h")
    audio_output = read_header(headers, "VZHostAudioOutputStreamSink.h")
    trackpad = read_header(headers, "VZMacTrackpadConfiguration.h")
    keyboard = read_header(headers, "VZMacKeyboardConfiguration.h")
    configuration = read_header(headers, "VZVirtualMachineConfiguration.h")
    umbrella = read_header(headers, "Virtualization.h")
    xhci = read_header(headers, "VZXHCIControllerConfiguration.h")
    usb_storage = read_header(headers, "VZUSBMassStorageDeviceConfiguration.h")
    hypervisor_headers = sdk / "System/Library/Frameworks/Hypervisor.framework/Headers"
    gic = read_header(hypervisor_headers, "hv_gic.h")

    require(graphics, r"Maximum of one display is supported[.]", "VZMac one-display maximum")
    require_class(graphics, "VZMacGraphicsDeviceConfiguration", "12.0")
    if experimental_usb:
        usb = read_header(headers, "VZUSBPassthroughDeviceConfiguration.h")
        require(usb, r"VZ_EXPORT API_AVAILABLE\(macos\(27[.]0\)\)", "macOS 27 USB passthrough")
        require(usb, r"initWithDevice:\(AAUSBAccessory \*\)device", "AccessoryAccess USB authority")
    elif (headers / "VZUSBPassthroughDeviceConfiguration.h").exists():
        raise SDKContractFailure("final SDK baseline unexpectedly declares physical USB passthrough")
    require_class(audio_input, "VZHostAudioInputStreamSource", "12.0")
    require_class(audio_output, "VZHostAudioOutputStreamSink", "12.0")
    require_class(trackpad, "VZMacTrackpadConfiguration", "13.0")
    require_class(keyboard, "VZMacKeyboardConfiguration", "14.0")
    require_class(xhci, "VZXHCIControllerConfiguration", "15.0")
    require_class(usb_storage, "VZUSBMassStorageDeviceConfiguration", "13.0")
    require(
        gic,
        r"API_AVAILABLE\(macos\(15[.]0\)\)\s*hv_return_t hv_gic_create\(",
        "macOS 15 native GIC",
    )
    require(
        configuration,
        r"validateSaveRestoreSupportWithError:.*API_AVAILABLE\(macos\(14[.]0\)\)",
        "save/restore validation",
    )
    if "VZCamera" in umbrella:
        raise SDKContractFailure(
            "selected SDK unexpectedly exposes a VZCamera symbol; camera policy requires review"
        )
    return {
        "schemaVersion": 2,
        "status": "PASS",
        "sdkVersion": sdk_version,
        "hostRequirement": "apple-silicon",
        "productMinimumHostVersion": "15.0",
        "sdkProfile": "experimental-usb" if experimental_usb else "final-26.5-baseline",
        "macGraphicsMaximumDisplays": 1,
        "macKeyboardAPI": "public",
        "macTrackpadAPI": "public",
        "hostAudioInputAPI": "public",
        "hostAudioOutputAPI": "public",
        "nativeGICAPI": "public-from-macos-15.0",
        "virtualUSBMassStorageAPI": "public-from-macos-13.0-controller-from-15.0",
        "usbPassthroughAPI": "experimental-from-macos-27.0" if experimental_usb else "not-in-baseline",
        "usbAuthority": "AccessoryAccess" if experimental_usb else None,
        "directVZCameraAPI": "absent-requires-qualified-usb-or-guest-bridge",
        "saveRestoreValidationAPI": "public-from-macos-14.0",
        "qualificationScope": "sdk-contract-only-physical-probes-required",
        "releaseQualification": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sdk", type=Path)
    parser.add_argument("--sdk-version")
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--experimental-usb", action="store_true",
        help="inspect macOS 27 physical USB declarations without qualifying the product baseline",
    )
    arguments = parser.parse_args()
    try:
        sdk = arguments.sdk or Path(command("xcrun", "--sdk", "macosx", "--show-sdk-path"))
        version = arguments.sdk_version or command(
            "xcrun", "--sdk", "macosx", "--show-sdk-version"
        )
        receipt = inspect_sdk(
            sdk.resolve(strict=True), version, experimental_usb=arguments.experimental_usb
        )
        encoded = json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n"
        if arguments.output is None:
            sys.stdout.write(encoded)
        else:
            arguments.output.write_text(encoded, encoding="utf-8")
            print(f"VZ platform SDK contract: PASS ({version}; {arguments.output})")
    except (OSError, SDKContractFailure) as error:
        print(f"VZ platform SDK contract: FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
