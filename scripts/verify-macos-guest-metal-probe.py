#!/usr/bin/env python3
"""Audit a Dory macOS guest Metal probe result and its optional VZ-socket receipt.

The manual path remains development-only. A transport receipt proves that the
selected VZ runtime collected the raw result over its machine-local VirtIO
socket, while visible-window and lifecycle correlation remain separate gates.
"""

from __future__ import annotations

import argparse
import importlib.util
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
import sys
import tempfile
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_SCHEMA = "dory.macos-guest-tools-manifest@2"
MANIFEST_CAPABILITIES = [
    {"id": "clipboard-image-read", "version": 2},
    {"id": "clipboard-image-write", "version": 2},
    {"id": "clipboard-text-read", "version": 2},
    {"id": "clipboard-text-write", "version": 2},
    {"id": "file-pull", "version": 2},
    {"id": "file-push", "version": 2},
    {"id": "guest-time", "version": 2},
    {"id": "health", "version": 2},
    {"id": "metal-probe", "version": 2},
    {"id": "open-url", "version": 2},
]
RESULT_SCHEMA = "dory.guest-tools.metal-probe@2"
CHALLENGE_SCHEMA = "dory.macos-guest-metal-probe-challenge@2"
VERIFICATION_SCHEMA = "dory.macos-guest-metal-probe-verification@2"
TRANSPORT_SCHEMA = "dory.macos-guest-metal-probe-transport@3"
BUNDLE_IDENTIFIER = "com.pythonxi.Dory.GuestTools"
SOURCE_FILES = (
    "GuestTools/DoryGuestTools/DoryGuestFilePublication.swift",
    "GuestTools/DoryGuestTools/DoryGuestIntegrationClient.swift",
    "GuestTools/DoryGuestTools/DoryGuestMetalProbe.swift",
    "GuestTools/DoryGuestTools/DoryGuestMetalProbeTransport.swift",
    "GuestTools/DoryGuestTools/DoryGuestToolsApp.swift",
    "GuestTools/DoryGuestTools/DoryGuestTools.entitlements",
    "GuestTools/METAL_PROBE.md",
    "GuestTools/Packaging/com.pythonxi.Dory.GuestTools.agent.plist",
    "GuestTools/Packaging/dory-guest-tools-maintenance.sh",
    "dory-core-swift/Sources/DoryMacGuestIntegrationWire/DoryMacGuestIntegrationWire.swift",
)
LABEL = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
PIXEL_ORACLE_PATH = ROOT / "guest-probes/pixel-oracle.py"
PIXEL_ORACLE_SPEC = importlib.util.spec_from_file_location("dory_pixel_oracle", PIXEL_ORACLE_PATH)
if PIXEL_ORACLE_SPEC is None or PIXEL_ORACLE_SPEC.loader is None:
    raise RuntimeError("could not load the retained PNG pixel oracle")
PIXEL_ORACLE = importlib.util.module_from_spec(PIXEL_ORACLE_SPEC)
sys.modules[PIXEL_ORACLE_SPEC.name] = PIXEL_ORACLE
PIXEL_ORACLE_SPEC.loader.exec_module(PIXEL_ORACLE)
APPROVED_SHADER_SOURCE = """#include <metal_stdlib>
using namespace metal;

kernel void dory_probe_compute(device uint *output [[buffer(0)]],
                               uint index [[thread_position_in_grid]]) {
    output[index] = ((index * 17) ^ 0x5A5A) + 3;
}

struct DoryProbeRasterOut {
    float4 position [[position]];
    float2 uv;
};

struct DoryProbeChallenge {
    uint2 hashWords;
    uint frameMarker;
    uint reserved;
};

vertex DoryProbeRasterOut dory_probe_vertex(uint index [[vertex_id]]) {
    constexpr float2 positions[] = {
        float2(-1.0, -1.0), float2(1.0, -1.0),
        float2(-1.0, 1.0), float2(1.0, 1.0),
    };
    DoryProbeRasterOut output;
    output.position = float4(positions[index], 0.0, 1.0);
    output.uv = float2((positions[index].x + 1.0) * 0.5,
                       (1.0 - positions[index].y) * 0.5);
    return output;
}

fragment float4 dory_probe_fragment(
    DoryProbeRasterOut input [[stage_in]],
    constant DoryProbeChallenge &challenge [[buffer(0)]]) {
    uint2 pixel = uint2(min(input.uv * 64.0, float2(63.0)));
    if (pixel.x >= 8 && pixel.x < 56 && pixel.y >= 12 && pixel.y < 52) {
        uint column = (pixel.x - 8) / 4;
        uint row = (pixel.y - 12) / 4;
        if (column == 0 && row == 0) return float4(244.0 / 255.0, 67.0 / 255.0, 54.0 / 255.0, 1.0);
        if (column == 11 && row == 0) return float4(76.0 / 255.0, 175.0 / 255.0, 80.0 / 255.0, 1.0);
        if (column == 0 && row == 9) return float4(33.0 / 255.0, 150.0 / 255.0, 243.0 / 255.0, 1.0);
        if (column == 11 && row == 9) return float4(255.0 / 255.0, 235.0 / 255.0, 59.0 / 255.0, 1.0);
        if (column == 0 || column == 11 || row == 0 || row == 9)
            return float4(6.0 / 255.0, 10.0 / 255.0, 20.0 / 255.0, 1.0);
        uint bitIndex = (row - 1) * 10 + (column - 1);
        uint bit = bitIndex < 32 ? ((challenge.hashWords.x >> bitIndex) & 1)
                 : bitIndex < 64 ? ((challenge.hashWords.y >> (bitIndex - 32)) & 1)
                                 : ((challenge.frameMarker >> (bitIndex - 64)) & 1);
        return bit ? float4(64.0 / 255.0, 224.0 / 255.0, 196.0 / 255.0, 1.0)
                   : float4(24.0 / 255.0, 52.0 / 255.0, 92.0 / 255.0, 1.0);
    }
    bool alternate = ((pixel.x >> 3) ^ (pixel.y >> 3)) & 1;
    return alternate ? float4(13.0 / 255.0, 191.0 / 255.0, 242.0 / 255.0, 1.0)
                     : float4(230.0 / 255.0, 51.0 / 255.0, 89.0 / 255.0, 1.0);
}"""


class ProbeError(ValueError):
    pass


def digest(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def read_regular(path: Path, label: str, *, max_bytes: int = 8 * 1024 * 1024) -> bytes:
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
        with os.fdopen(descriptor, "rb") as source:
            metadata = os.fstat(source.fileno())
            if not stat.S_ISREG(metadata.st_mode):
                raise ProbeError(f"{label} must be a direct regular file: {path}")
            if metadata.st_size > max_bytes:
                raise ProbeError(f"{label} exceeds the supported byte bound: {path}")
            payload = source.read(max_bytes + 1)
    except OSError as error:
        raise ProbeError(f"{label} is unavailable: {path}") from error
    if len(payload) > max_bytes:
        raise ProbeError(f"{label} exceeds the supported byte bound: {path}")
    return payload


def load_json(path: Path, label: str) -> tuple[dict[str, Any], bytes]:
    payload = read_regular(path, label)
    def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in pairs:
            if key in value:
                raise ProbeError(f"{label} contains a duplicate JSON key: {key}")
            value[key] = item
        return value

    def reject_nonfinite(value: str) -> Any:
        raise ProbeError(f"{label} contains a non-finite JSON number: {value}")

    try:
        value = json.loads(
            payload, object_pairs_hook=unique_object, parse_constant=reject_nonfinite
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProbeError(f"{label} is not valid JSON") from error
    if not isinstance(value, dict):
        raise ProbeError(f"{label} must be a JSON object")
    return value, payload


def exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise ProbeError(f"{label} keys are invalid (missing={missing}, extra={extra})")


def label(value: Any, name: str) -> str:
    if not isinstance(value, str) or not LABEL.fullmatch(value):
        raise ProbeError(f"{name} must use 1–128 ASCII letters, digits, '.', '_', ':', or '-'")
    return value


def sha256_value(value: Any, name: str) -> str:
    if not isinstance(value, str) or not SHA256.fullmatch(value):
        raise ProbeError(f"{name} must be a lowercase SHA-256 digest")
    return value


def utc_timestamp(value: Any, name: str) -> str:
    if not isinstance(value, str) or len(value.encode("utf-8")) > 128:
        raise ProbeError(f"{name} must be a bounded ISO-8601 timestamp")
    try:
        instant = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ProbeError(f"{name} is not ISO-8601") from error
    if instant.tzinfo is None or instant.utcoffset() is None:
        raise ProbeError(f"{name} must include a UTC offset")
    return value


def timestamp_instant(value: Any, name: str) -> dt.datetime:
    return dt.datetime.fromisoformat(utc_timestamp(value, name).replace("Z", "+00:00"))


def atomic_write(path: Path, payload: bytes) -> None:
    if path.exists() and path.is_symlink():
        raise ProbeError(f"output must not be a symbolic link: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.tmp-", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def canonical_json(value: dict[str, Any]) -> bytes:
    return (json.dumps(value, sort_keys=True, indent=2) + "\n").encode("utf-8")


def compute_digest() -> str:
    values = [((index * 17) ^ 0x5A5A) + 3 for index in range(1_024)]
    return digest(b"".join(struct.pack("<I", value) for value in values))


def approved_shader_digest() -> str:
    return digest(APPROVED_SHADER_SOURCE.encode("utf-8"))


def fnv1a64(nonce: str, frame_marker: int) -> int:
    value = 14_695_981_039_346_656_037
    for byte in nonce.encode("utf-8") + struct.pack("<I", frame_marker):
        value ^= byte
        value = (value * 1_099_511_628_211) & 0xFFFF_FFFF_FFFF_FFFF
    return value


def visual_challenge(nonce: str, frame_marker: int = 1) -> dict[str, Any]:
    return {
        "kind": "dev.dory.visual-challenge",
        "version": 1,
        "encoding": "fnv1a64-frame16-grid12x10",
        "frameMarker": frame_marker,
        "payloadHash": f"fnv1a64:{fnv1a64(nonce, frame_marker):016x}",
    }


def rendered_pattern_digests(nonce: str, frame_marker: int = 1) -> dict[str, str]:
    """Derive the expected BGRA8 readback and an inverted negative control."""
    results: dict[str, str] = {}
    cyan = bytes((242, 191, 13, 255))
    magenta = bytes((89, 51, 230, 255))
    challenge_hash = fnv1a64(nonce, frame_marker)
    colors = {
        "border": bytes((20, 10, 6, 255)),
        "topLeft": bytes((54, 67, 244, 255)),
        "topRight": bytes((80, 175, 76, 255)),
        "bottomLeft": bytes((243, 150, 33, 255)),
        "bottomRight": bytes((59, 235, 255, 255)),
        "zero": bytes((92, 52, 24, 255)),
        "one": bytes((196, 224, 64, 255)),
    }
    for name, inverted_y in (("native", False), ("vertically-inverted", True)):
        pixels = bytearray()
        for readback_y in range(64):
            y = 63 - readback_y if inverted_y else readback_y
            for x in range(64):
                marker_x = x - 8
                marker_y = y - 12
                if 0 <= marker_x < 48 and 0 <= marker_y < 40:
                    column = marker_x // 4
                    row = marker_y // 4
                    if (column, row) == (0, 0):
                        pixels.extend(colors["topLeft"])
                    elif (column, row) == (11, 0):
                        pixels.extend(colors["topRight"])
                    elif (column, row) == (0, 9):
                        pixels.extend(colors["bottomLeft"])
                    elif (column, row) == (11, 9):
                        pixels.extend(colors["bottomRight"])
                    elif column in {0, 11} or row in {0, 9}:
                        pixels.extend(colors["border"])
                    else:
                        bit_index = (row - 1) * 10 + (column - 1)
                        bit = (
                            (challenge_hash >> bit_index) & 1
                            if bit_index < 64
                            else (frame_marker >> (bit_index - 64)) & 1
                        )
                        pixels.extend(colors["one"] if bit else colors["zero"])
                    continue
                alternate = ((x >> 3) ^ (y >> 3)) & 1 == 1
                pixels.extend(cyan if alternate else magenta)
        results[name] = digest(bytes(pixels))
    return results


def marker_color(column: int, row: int, nonce: str, frame_marker: int = 1) -> tuple[int, int, int]:
    colors = {
        "border": (6, 10, 20),
        "topLeft": (244, 67, 54),
        "topRight": (76, 175, 80),
        "bottomLeft": (33, 150, 243),
        "bottomRight": (255, 235, 59),
        "zero": (24, 52, 92),
        "one": (64, 224, 196),
    }
    if (column, row) == (0, 0):
        return colors["topLeft"]
    if (column, row) == (11, 0):
        return colors["topRight"]
    if (column, row) == (0, 9):
        return colors["bottomLeft"]
    if (column, row) == (11, 9):
        return colors["bottomRight"]
    if column in {0, 11} or row in {0, 9}:
        return colors["border"]
    bit_index = (row - 1) * 10 + (column - 1)
    bit = (
        (fnv1a64(nonce, frame_marker) >> bit_index) & 1
        if bit_index < 64
        else (frame_marker >> (bit_index - 64)) & 1
    )
    return colors["one"] if bit else colors["zero"]


def verify_window_pixels(image: Any, viewport: tuple[int, int, int, int], nonce: str) -> str:
    x, y, width, height = viewport

    def sample(virtual_x: float, virtual_y: float, inverted_y: bool) -> tuple[int, int, int]:
        sample_x = x + min(width - 1, max(0, int(virtual_x * width / 64)))
        vertical = 64 - virtual_y if inverted_y else virtual_y
        sample_y = y + min(height - 1, max(0, int(vertical * height / 64)))
        return image.pixel(sample_x, sample_y)[:3]

    def marker_matches(inverted_y: bool) -> bool:
        for row in range(10):
            for column in range(12):
                virtual_x = 8 + (column + 0.5) * 4
                virtual_y = 12 + (row + 0.5) * 4
                actual = sample(virtual_x, virtual_y, inverted_y)
                expected = marker_color(column, row, nonce)
                if max(abs(actual[index] - expected[index]) for index in range(3)) > 24:
                    return False
        return True

    def checkerboard_matches() -> bool:
        for tile_y in range(8):
            for tile_x in range(8):
                # Stay away from both checkerboard and marker boundaries after
                # the guest preview has been scaled into capture pixels.
                virtual_x = tile_x * 8 + 5
                virtual_y = tile_y * 8 + 5
                if 8 <= virtual_x < 56 and 12 <= virtual_y < 52:
                    continue  # The nonce/frame marker covers these tiles.
                actual = sample(virtual_x, virtual_y, False)
                expected = (
                    (13, 191, 242) if (tile_x ^ tile_y) & 1 else (230, 51, 89)
                )
                if max(abs(actual[index] - expected[index]) for index in range(3)) > 24:
                    return False
        return True

    if marker_matches(False):
        if not checkerboard_matches():
            raise ProbeError(
                "captured Mac product-window pixels do not contain the approved checkerboard"
            )
        return "native"
    if marker_matches(True):
        raise ProbeError("captured Mac product-window challenge is vertically inverted")
    raise ProbeError(
        "captured Mac product-window pixels do not contain the current nonce/frame challenge"
    )


def validate_window_capture(
    receipt: dict[str, Any],
    capture_path: Path,
    challenge: dict[str, str],
    challenge_payload: bytes,
    result_payload: bytes,
    transport_receipt: dict[str, Any] | None,
) -> dict[str, Any]:
    exact_keys(receipt, {
        "schema", "capturedAt", "capturedMonotonicNanoseconds", "captureScope",
        "candidateID", "machineID", "operationID",
        "nonce", "challengeSHA256", "resultSHA256", "captureSHA256", "captureByteCount",
        "captureWidth", "captureHeight", "guestPreview", "windowProcessIdentifier", "windowNumber",
    }, "Mac product-window capture receipt")
    if receipt["schema"] != "dory.macos-guest-metal-window-capture@2":
        raise ProbeError("Mac product-window capture receipt schema is unsupported")
    if receipt["captureScope"] != "selected-vzmac-product-window":
        raise ProbeError("capture does not declare the selected VZMac product window")
    captured_at = timestamp_instant(receipt["capturedAt"], "Mac product-window capturedAt")
    issued_at = timestamp_instant(challenge["issuedAt"], "challenge issuedAt")
    if captured_at < issued_at:
        raise ProbeError("Mac product-window capture predates the host challenge")
    if transport_receipt is not None and captured_at < timestamp_instant(
        transport_receipt["collectedAt"], "transport receipt collectedAt"
    ):
        raise ProbeError("Mac product-window capture predates guest result collection")
    captured_monotonic = receipt["capturedMonotonicNanoseconds"]
    if type(captured_monotonic) is not int or captured_monotonic <= 0:
        raise ProbeError("Mac product-window capturedMonotonicNanoseconds is invalid")
    if transport_receipt is not None and captured_monotonic <= transport_receipt["collectedMonotonicNanoseconds"]:
        raise ProbeError("Mac product-window capture does not follow guest result collection on the host monotonic clock")
    for field in ("candidateID", "machineID", "operationID", "nonce"):
        if receipt[field] != challenge[field]:
            raise ProbeError(f"Mac product-window capture {field} does not match the challenge")
    capture_payload = read_regular(
        capture_path, "Mac product-window capture", max_bytes=PIXEL_ORACLE.MAX_PNG_BYTES
    )
    if receipt["challengeSHA256"] != digest(challenge_payload):
        raise ProbeError("Mac product-window capture does not bind the exact challenge bytes")
    if receipt["resultSHA256"] != digest(result_payload):
        raise ProbeError("Mac product-window capture does not bind the exact guest result bytes")
    if receipt["captureSHA256"] != digest(capture_payload):
        raise ProbeError("Mac product-window capture digest does not match the PNG")
    if receipt["captureByteCount"] != len(capture_payload):
        raise ProbeError("Mac product-window capture byte count does not match the PNG")
    for field in ("windowProcessIdentifier", "windowNumber"):
        if not isinstance(receipt[field], int) or isinstance(receipt[field], bool) or receipt[field] <= 0:
            raise ProbeError(f"Mac product-window capture {field} is invalid")
    try:
        image = PIXEL_ORACLE.decode_png_bytes(capture_payload)
        viewport = PIXEL_ORACLE._viewport(image, receipt["guestPreview"])
    except PIXEL_ORACLE.PixelOracleError as error:
        raise ProbeError(f"Mac product-window PNG is invalid: {error}") from error
    if (receipt["captureWidth"], receipt["captureHeight"]) != (image.width, image.height):
        raise ProbeError("Mac product-window capture dimensions do not match decoded PNG pixels")
    orientation = verify_window_pixels(image, viewport, challenge["nonce"])
    return {
        "captureSHA256": receipt["captureSHA256"],
        "captureWidth": image.width,
        "captureHeight": image.height,
        "guestPreview": receipt["guestPreview"],
        "markerOrientation": orientation,
        "capturedMonotonicNanoseconds": captured_monotonic,
        "windowProcessIdentifier": receipt["windowProcessIdentifier"],
        "windowNumber": receipt["windowNumber"],
    }


def validate_manifest(value: dict[str, Any], payload: bytes, source_root: Path | None) -> dict[str, str]:
    exact_keys(value, {
        "schema", "candidateID", "sourceCommit", "bundle", "source", "capabilities", "signing",
    }, "guest tools manifest")
    if value["schema"] != MANIFEST_SCHEMA:
        raise ProbeError("guest tools manifest schema is unsupported")
    candidate_id = label(value["candidateID"], "manifest candidate ID")
    if not isinstance(value["sourceCommit"], str) or not re.fullmatch(r"[0-9a-f]{40}", value["sourceCommit"]):
        raise ProbeError("manifest source commit is invalid")
    bundle = value["bundle"]
    if not isinstance(bundle, dict):
        raise ProbeError("manifest bundle must be an object")
    expected_bundle = {"identifier", "version", "build", "treeSHA256", "entries"}
    exact_keys(bundle, expected_bundle, "manifest bundle")
    if bundle["identifier"] != BUNDLE_IDENTIFIER:
        raise ProbeError("manifest bundle identifier is not Dory Guest Tools")
    version = label(bundle["version"], "manifest bundle version")
    build = label(bundle["build"], "manifest bundle build")
    sha256_value(bundle["treeSHA256"], "manifest bundle tree digest")
    if not isinstance(bundle["entries"], list) or not bundle["entries"]:
        raise ProbeError("manifest bundle inventory is empty")
    capabilities = value["capabilities"]
    if capabilities != MANIFEST_CAPABILITIES:
        raise ProbeError("manifest must declare the exact Mac Guest Tools capability inventory")
    signing = value["signing"]
    if not isinstance(signing, dict):
        raise ProbeError("manifest signing must be an object")
    if signing.get("classification") == "developer-id-signed":
        exact_keys(signing, {"classification", "teamIdentifier", "authority", "hardenedRuntime"}, "manifest signing")
        if signing["teamIdentifier"] != "864H636QW4" or signing["hardenedRuntime"] is not True:
            raise ProbeError("signed manifest does not bind Dory's hardened Developer ID identity")
    elif signing == {"classification": "unsigned-development", "releaseEligible": False}:
        pass
    else:
        raise ProbeError("manifest signing classification is unsupported")
    source = value["source"]
    if not isinstance(source, dict):
        raise ProbeError("manifest source must be an object")
    exact_keys(source, {"treeSHA256", "entries"}, "manifest source")
    sha256_value(source["treeSHA256"], "manifest source tree digest")
    entries = source["entries"]
    if not isinstance(entries, list) or len(entries) != len(SOURCE_FILES):
        raise ProbeError("manifest source inventory is incomplete")
    source_entries: dict[str, str] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise ProbeError("manifest source entry must be an object")
        exact_keys(entry, {"path", "sha256"}, "manifest source entry")
        path = entry["path"]
        if not isinstance(path, str) or path not in SOURCE_FILES or path in source_entries:
            raise ProbeError("manifest source entry path is invalid")
        source_entries[path] = sha256_value(entry["sha256"], f"manifest source digest for {path}")
    if set(source_entries) != set(SOURCE_FILES):
        raise ProbeError("manifest source inventory does not cover the retained probe sources")
    if source_root is not None:
        resolved_root = source_root.resolve(strict=True)
        inventory_digest = hashlib.sha256()
        for relative in sorted(SOURCE_FILES, key=lambda item: item.encode("utf-8")):
            actual = digest(read_regular(resolved_root / relative, f"retained source {relative}"))
            if actual != source_entries[relative]:
                raise ProbeError(f"retained source does not match staged manifest: {relative}")
            inventory_digest.update(f"{relative}\0{actual}\n".encode("utf-8"))
        if inventory_digest.hexdigest() != source["treeSHA256"]:
            raise ProbeError("retained source inventory digest does not match staged manifest")
    return {
        "candidateID": candidate_id,
        "bundleIdentifier": BUNDLE_IDENTIFIER,
        "bundleVersion": version,
        "bundleBuild": build,
        "manifestSHA256": digest(payload),
    }


def validate_challenge(value: dict[str, Any]) -> dict[str, str]:
    exact_keys(value, {
        "schema", "issuedAt", "candidateID", "machineID", "operationID", "nonce", "guestToolsManifestSHA256",
        "guestToolsBundleIdentifier", "guestToolsVersion", "guestToolsBuild",
    }, "probe challenge")
    if value["schema"] != CHALLENGE_SCHEMA:
        raise ProbeError("probe challenge schema is unsupported")
    if value["guestToolsBundleIdentifier"] != BUNDLE_IDENTIFIER:
        raise ProbeError("probe challenge bundle identifier is unsupported")
    return {
        "issuedAt": utc_timestamp(value["issuedAt"], "challenge issuedAt"),
        "candidateID": label(value["candidateID"], "challenge candidate ID"),
        "machineID": label(value["machineID"], "challenge machine ID"),
        "operationID": label(value["operationID"], "challenge operation ID"),
        "nonce": label(value["nonce"], "challenge nonce"),
        "manifestSHA256": sha256_value(value["guestToolsManifestSHA256"], "challenge manifest digest"),
        "bundleIdentifier": BUNDLE_IDENTIFIER,
        "bundleVersion": label(value["guestToolsVersion"], "challenge bundle version"),
        "bundleBuild": label(value["guestToolsBuild"], "challenge bundle build"),
    }


def validate_result(value: dict[str, Any], challenge: dict[str, str]) -> dict[str, Any]:
    exact_keys(value, {
        "schema", "createdAt", "nonce", "candidateID", "machineID", "guestOperatingSystemVersion",
        "guestOperatingSystemBuild", "operationID",
        "guestActiveProcessorCount", "guestPhysicalMemoryBytes", "guestToolsBundleIdentifier",
        "guestToolsVersion", "guestToolsBuild", "metalDeviceName", "metalRegistryID",
        "usesUnifiedMemory", "probeShaderSHA256", "computeOutputSHA256", "renderedPatternSHA256",
        "visualChallenge",
        "computeValueCount", "renderedWidth", "renderedHeight", "computeCommandBufferStatus",
        "renderCommandBufferStatus",
    }, "guest probe result")
    if value["schema"] != RESULT_SCHEMA:
        raise ProbeError("guest probe result schema is unsupported")
    if value["candidateID"] != challenge["candidateID"] or value["nonce"] != challenge["nonce"]:
        raise ProbeError("guest probe result does not match the host-issued candidate or nonce")
    if value["machineID"] != challenge["machineID"]:
        raise ProbeError("guest probe result does not match the host-issued machine ID")
    if value["operationID"] != challenge["operationID"]:
        raise ProbeError("guest probe result does not match the host-issued operation ID")
    if (value["guestToolsBundleIdentifier"], value["guestToolsVersion"], value["guestToolsBuild"]) != (
        challenge["bundleIdentifier"], challenge["bundleVersion"], challenge["bundleBuild"],
    ):
        raise ProbeError("guest probe result does not match the staged Guest Tools bundle")
    utc_timestamp(value["createdAt"], "guest result createdAt")
    if not isinstance(value["guestOperatingSystemVersion"], str) or not VERSION.fullmatch(value["guestOperatingSystemVersion"]):
        raise ProbeError("guest operating-system version is invalid")
    label(value["guestOperatingSystemBuild"], "guest operating-system build")
    if not isinstance(value["guestActiveProcessorCount"], int) or value["guestActiveProcessorCount"] < 1:
        raise ProbeError("guest active processor count is invalid")
    if not isinstance(value["guestPhysicalMemoryBytes"], int) or value["guestPhysicalMemoryBytes"] < 1:
        raise ProbeError("guest physical memory is invalid")
    if not isinstance(value["metalDeviceName"], str) or not value["metalDeviceName"].strip() or len(value["metalDeviceName"].encode()) > 1_024:
        raise ProbeError("guest Metal device name is invalid")
    if not isinstance(value["metalRegistryID"], str) or not value["metalRegistryID"].isdigit() or len(value["metalRegistryID"]) > 32:
        raise ProbeError("guest Metal registry ID is invalid")
    if not isinstance(value["usesUnifiedMemory"], bool):
        raise ProbeError("guest unified-memory flag is invalid")
    for field in ("probeShaderSHA256", "computeOutputSHA256", "renderedPatternSHA256"):
        sha256_value(value[field], f"guest result {field}")
    if value["probeShaderSHA256"] != approved_shader_digest():
        raise ProbeError("guest shader digest does not match the approved retained Metal source")
    if value["computeOutputSHA256"] != compute_digest():
        raise ProbeError("guest compute digest does not match the retained deterministic workload")
    expected_challenge = visual_challenge(challenge["nonce"])
    if value["visualChallenge"] != expected_challenge:
        raise ProbeError("guest visual challenge does not match the host-issued nonce and frame marker")
    pattern_digests = rendered_pattern_digests(challenge["nonce"])
    if value["renderedPatternSHA256"] != pattern_digests["native"]:
        raise ProbeError("guest render digest does not match the independent checkerboard oracle")
    if (value["computeValueCount"], value["renderedWidth"], value["renderedHeight"]) != (1_024, 64, 64):
        raise ProbeError("guest probe workload dimensions are unsupported")
    if value["computeCommandBufferStatus"] != "completed" or value["renderCommandBufferStatus"] != "completed":
        raise ProbeError("guest probe command buffers did not both complete")
    return {
        "guestOperatingSystemVersion": value["guestOperatingSystemVersion"],
        "guestOperatingSystemBuild": value["guestOperatingSystemBuild"],
        "machineID": value["machineID"],
        "operationID": value["operationID"],
        "guestActiveProcessorCount": value["guestActiveProcessorCount"],
        "guestPhysicalMemoryBytes": value["guestPhysicalMemoryBytes"],
        "metalDeviceName": value["metalDeviceName"],
        "metalRegistryID": value["metalRegistryID"],
        "usesUnifiedMemory": value["usesUnifiedMemory"],
        "probeShaderSHA256": value["probeShaderSHA256"],
        "computeOutputSHA256": value["computeOutputSHA256"],
        "renderedPatternSHA256": value["renderedPatternSHA256"],
        "renderedPatternOrientation": "native",
        "visualChallenge": expected_challenge,
    }


def validate_transport_receipt(
    value: dict[str, Any], result_payload: bytes, challenge: dict[str, str]
) -> None:
    exact_keys(value, {
        "schema", "collectedAt", "collectedMonotonicNanoseconds", "collection",
        "candidateID", "machineID", "operationID", "nonce",
        "resultSHA256", "resultByteCount",
    }, "transport receipt")
    if value["schema"] != TRANSPORT_SCHEMA or value["collection"] != "vz-virtio-socket":
        raise ProbeError("transport receipt is not a supported VZ virtio-socket collection")
    if timestamp_instant(value["collectedAt"], "transport receipt collectedAt") < timestamp_instant(
        challenge["issuedAt"], "challenge issuedAt"
    ):
        raise ProbeError("transport receipt predates the host challenge")
    collected_monotonic = value["collectedMonotonicNanoseconds"]
    if type(collected_monotonic) is not int or collected_monotonic <= 0:
        raise ProbeError("transport receipt collectedMonotonicNanoseconds is invalid")
    for field in ("candidateID", "machineID", "operationID", "nonce"):
        if value[field] != challenge[field]:
            raise ProbeError(f"transport receipt {field} does not match the host challenge")
    if value["resultSHA256"] != digest(result_payload):
        raise ProbeError("transport receipt result digest does not match the raw guest result")
    if value["resultByteCount"] != len(result_payload):
        raise ProbeError("transport receipt byte count does not match the raw guest result")


def issue(arguments: argparse.Namespace) -> None:
    manifest, payload = load_json(arguments.guest_tools_manifest, "guest tools manifest")
    manifest_fields = validate_manifest(manifest, payload, None)
    candidate_id = label(arguments.candidate_id, "candidate ID")
    if candidate_id != manifest_fields["candidateID"]:
        raise ProbeError("challenge candidate ID does not match the staged Guest Tools manifest")
    issued_at = arguments.issued_at or dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    document = {
        "schema": CHALLENGE_SCHEMA,
        "issuedAt": utc_timestamp(issued_at, "challenge issuedAt"),
        "candidateID": candidate_id,
        "machineID": label(arguments.machine_id, "machine ID"),
        "operationID": label(arguments.operation_id, "operation ID"),
        "nonce": label(arguments.nonce, "nonce"),
        "guestToolsManifestSHA256": manifest_fields["manifestSHA256"],
        "guestToolsBundleIdentifier": manifest_fields["bundleIdentifier"],
        "guestToolsVersion": manifest_fields["bundleVersion"],
        "guestToolsBuild": manifest_fields["bundleBuild"],
    }
    atomic_write(arguments.output, canonical_json(document))


def verify(arguments: argparse.Namespace, *, write_output: bool = True) -> dict[str, Any]:
    challenge, challenge_payload = load_json(arguments.challenge, "probe challenge")
    challenge_fields = validate_challenge(challenge)
    manifest, manifest_payload = load_json(arguments.guest_tools_manifest, "guest tools manifest")
    manifest_fields = validate_manifest(manifest, manifest_payload, arguments.source_root)
    if challenge_fields["manifestSHA256"] != manifest_fields["manifestSHA256"]:
        raise ProbeError("host challenge does not bind the supplied staged Guest Tools manifest")
    if any(challenge_fields[field] != manifest_fields[field] for field in (
        "candidateID", "bundleIdentifier", "bundleVersion", "bundleBuild",
    )):
        raise ProbeError("host challenge and staged Guest Tools manifest disagree")
    result, result_payload = load_json(arguments.result, "guest probe result")
    observed = validate_result(result, challenge_fields)
    transport_collected = arguments.transport_receipt is not None
    transport = None
    if transport_collected:
        transport, _ = load_json(arguments.transport_receipt, "transport receipt")
        validate_transport_receipt(transport, result_payload, challenge_fields)
    has_window_capture = arguments.window_capture is not None or arguments.window_capture_receipt is not None
    if has_window_capture and (
        arguments.window_capture is None or arguments.window_capture_receipt is None
    ):
        raise ProbeError("window capture PNG and receipt must be supplied together")
    window_capture = None
    if has_window_capture:
        capture_receipt, _ = load_json(
            arguments.window_capture_receipt, "Mac product-window capture receipt"
        )
        window_capture = validate_window_capture(
            capture_receipt,
            arguments.window_capture,
            challenge_fields,
            challenge_payload,
            result_payload,
            transport,
        )
    document = {
        "schema": VERIFICATION_SCHEMA,
        "status": (
            "window-correlated" if window_capture is not None
            else "transport-collected" if transport_collected
            else "development-observed"
        ),
        "releaseEligible": False,
        "collection": (
            "vz-virtio-socket+product-window" if transport_collected and window_capture is not None
            else "audited-manual+product-window" if window_capture is not None
            else "vz-virtio-socket" if transport_collected
            else "audited-manual"
        ),
        "challengeSHA256": digest(challenge_payload),
        "resultSHA256": digest(result_payload),
        "guestToolsManifestSHA256": manifest_fields["manifestSHA256"],
        "candidateID": challenge_fields["candidateID"],
        "machineID": challenge_fields["machineID"],
        "operationID": challenge_fields["operationID"],
        "nonce": challenge_fields["nonce"],
        "observed": observed,
        "windowCapture": window_capture,
        "limitations": (
            [
                "Decoded pixels prove the challenged marker and checkerboard were present in the declared product-window viewport; lifecycle and sustained-workload qualification remain separate gates.",
                "This sub-result remains non-release-eligible until the outer signed candidate campaign validates capture authority and lifecycle transitions.",
            ] if window_capture is not None else [
                "VZ virtio-socket binds collection to the selected machine runtime, but this receipt does not prove the rendered pattern was visible in the selected Dory window.",
                "This transport receipt must be correlated with product-window capture and lifecycle evidence before release qualification.",
            ] if transport_collected else [
                "Manual export is not authenticated guest-to-host transport.",
                "This verifier cannot prove that the result came from the selected Dory window or machine.",
                "This development observation is not final-candidate qualification or release evidence.",
            ]
        ),
    }
    if write_output:
        atomic_write(arguments.output, canonical_json(document))
    return document


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    issue_parser = commands.add_parser("issue", help="write a host-issued manual-export challenge")
    issue_parser.add_argument("--candidate-id", required=True)
    issue_parser.add_argument("--machine-id", required=True)
    issue_parser.add_argument("--operation-id", required=True)
    issue_parser.add_argument("--nonce", required=True)
    issue_parser.add_argument("--guest-tools-manifest", required=True, type=Path)
    issue_parser.add_argument("--output", required=True, type=Path)
    issue_parser.add_argument("--issued-at")
    verify_parser = commands.add_parser("verify", help="verify one manual guest result against a challenge")
    verify_parser.add_argument("--challenge", required=True, type=Path)
    verify_parser.add_argument("--result", required=True, type=Path)
    verify_parser.add_argument("--transport-receipt", type=Path)
    verify_parser.add_argument("--window-capture", type=Path)
    verify_parser.add_argument("--window-capture-receipt", type=Path)
    verify_parser.add_argument("--guest-tools-manifest", required=True, type=Path)
    verify_parser.add_argument("--source-root", type=Path, default=ROOT)
    verify_parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    try:
        if arguments.command == "issue":
            issue(arguments)
        else:
            verify(arguments)
    except (ProbeError, OSError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
