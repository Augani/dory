#!/usr/bin/env python3
"""Bind Phase 0A VZMac capability decisions to one selected public SDK."""

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


def inspect_sdk(sdk: Path, sdk_version: str) -> dict[str, object]:
    try:
        major = int(sdk_version.split(".", 1)[0])
    except (ValueError, IndexError) as error:
        raise SDKContractFailure(f"invalid selected SDK version: {sdk_version}") from error
    if major < 27:
        raise SDKContractFailure(
            f"selected SDK {sdk_version} predates the required final macOS 27 USB API contract"
        )
    headers = sdk / "System/Library/Frameworks/Virtualization.framework/Headers"
    graphics = read_header(headers, "VZMacGraphicsDeviceConfiguration.h")
    usb = read_header(headers, "VZUSBPassthroughDeviceConfiguration.h")
    audio_input = read_header(headers, "VZHostAudioInputStreamSource.h")
    audio_output = read_header(headers, "VZHostAudioOutputStreamSink.h")
    trackpad = read_header(headers, "VZMacTrackpadConfiguration.h")
    keyboard = read_header(headers, "VZMacKeyboardConfiguration.h")
    configuration = read_header(headers, "VZVirtualMachineConfiguration.h")
    umbrella = read_header(headers, "Virtualization.h")

    require(graphics, r"Maximum of one display is supported[.]", "VZMac one-display maximum")
    require(usb, r"VZ_EXPORT API_AVAILABLE\(macos\(27[.]0\)\)", "macOS 27 USB passthrough")
    require(usb, r"initWithDevice:\(AAUSBAccessory \*\)device", "AccessoryAccess USB authority")
    require(audio_input, r"@interface VZHostAudioInputStreamSource", "host audio input")
    require(audio_output, r"@interface VZHostAudioOutputStreamSink", "host audio output")
    require(trackpad, r"@interface VZMacTrackpadConfiguration", "Mac trackpad")
    require(keyboard, r"@interface VZMacKeyboardConfiguration", "Mac keyboard")
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
        "schemaVersion": 1,
        "status": "PASS",
        "sdkVersion": sdk_version,
        "hostRequirement": "apple-silicon",
        "macGraphicsMaximumDisplays": 1,
        "macKeyboardAPI": "public",
        "macTrackpadAPI": "public",
        "hostAudioInputAPI": "public",
        "hostAudioOutputAPI": "public",
        "usbPassthroughAPI": "public-from-macos-27.0",
        "usbAuthority": "AccessoryAccess",
        "directVZCameraAPI": "absent-requires-qualified-usb-or-guest-bridge",
        "saveRestoreValidationAPI": "public-from-macos-14.0",
        "qualificationScope": "sdk-contract-only-physical-probes-required",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sdk", type=Path)
    parser.add_argument("--sdk-version")
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    try:
        sdk = arguments.sdk or Path(command("xcrun", "--sdk", "macosx", "--show-sdk-path"))
        version = arguments.sdk_version or command(
            "xcrun", "--sdk", "macosx", "--show-sdk-version"
        )
        receipt = inspect_sdk(sdk.resolve(strict=True), version)
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
