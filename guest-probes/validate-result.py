#!/usr/bin/env python3
"""Fail-closed validation for one dev.dory.gpu-probe v1 result."""

from __future__ import annotations

import argparse
import importlib.util
import json
import math
from pathlib import Path
import re
import struct
import sys
from typing import Any


PROBES = {"vulkan-application", "vulkan-compositor", "compute", "gl"}
SOFTWARE_RENDERERS = ("llvmpipe", "lavapipe", "softpipe", "swrast",
                      "software rasterizer")
RESULT_HASH = re.compile(r"^fnv1a64:[0-9a-f]{16}$")
VISUAL_READBACK_ENCODING = "rgb8-cell-centers-top-left-grid12x10@1"
VISUAL_READBACK_HEX = re.compile(r"^[0-9a-f]{720}$")
SCANOUT_BACKGROUND_RGBA_HEX = re.compile(r"^[0-9a-f]{8}$")
# Numeric VkFormat values used by dory-vulkan-probe.c; its hash includes the C enum bytes.
VULKAN_ATLAS_FORMATS = {"rgba8-unorm": 37, "bgra8-unorm": 44}
COMPOSITOR_FORMATS = {"xrgb8888/bgra8-unorm", "xbgr8888/rgba8-unorm"}
OFFSCREEN_APPLICATION_EXTENT = {"width": 320, "height": 240}
PIXEL_ORACLE_PATH = Path(__file__).resolve().with_name("pixel-oracle.py")
PIXEL_ORACLE_SPEC = importlib.util.spec_from_file_location(
    "dory_pixel_oracle", PIXEL_ORACLE_PATH
)
if PIXEL_ORACLE_SPEC is None or PIXEL_ORACLE_SPEC.loader is None:
    raise RuntimeError("could not load the Dory pixel oracle")
PIXEL_ORACLE = importlib.util.module_from_spec(PIXEL_ORACLE_SPEC)
sys.modules[PIXEL_ORACLE_SPEC.name] = PIXEL_ORACLE
PIXEL_ORACLE_SPEC.loader.exec_module(PIXEL_ORACLE)


def fail(message: str) -> None:
    raise ValueError(message)


def nonempty_string(record: dict[str, Any], key: str) -> str:
    value = record.get(key)
    if not isinstance(value, str) or not value:
        fail(f"{key} must be a non-empty string")
    return value


def expected_compute_result(nonce: str) -> tuple[int, str]:
    """Replay the fixed v1 compute input/reduction using C's uint32 arithmetic."""
    mask32 = 0xFFFF_FFFF
    mask64 = 0xFFFF_FFFF_FFFF_FFFF
    nonce_hash = PIXEL_ORACLE.FNV_OFFSET
    for byte in nonce.encode("utf-8"):
        nonce_hash = ((nonce_hash ^ byte) * PIXEL_ORACLE.FNV_PRIME) & mask64
    seed = (nonce_hash ^ (nonce_hash >> 32)) & mask32
    reduction = 0
    for index in range(1024 * 1024):
        value = (((index ^ seed) * 17 + 23) & mask32) % 251
        reduction = (reduction + value) & mask32
    result_hash = nonce_hash
    for byte in struct.pack("<I", reduction):
        result_hash = ((result_hash ^ byte) * PIXEL_ORACLE.FNV_PRIME) & mask64
    return reduction, f"fnv1a64:{result_hash:016x}"


def fnv1a64(parts: tuple[bytes, ...]) -> str:
    value = PIXEL_ORACLE.FNV_OFFSET
    for part in parts:
        for byte in part:
            value = ((value ^ byte) * PIXEL_ORACLE.FNV_PRIME) & 0xFFFF_FFFF_FFFF_FFFF
    return f"fnv1a64:{value:016x}"


def validate_vulkan_result_hash(record: dict[str, Any], nonce: str) -> None:
    """Replay the probe's native little-endian VkFormat/VkExtent2D metadata digest.

    This authenticates the result fields against the fixed probe algorithm. It is not an
    output-pixel oracle: the separate guest readback and captured-window checks remain required.
    """
    extent = record.get("extent")
    if not isinstance(extent, dict) or set(extent) != {"width", "height"}:
        fail("Vulkan result extent is missing or malformed")
    width, height = extent["width"], extent["height"]
    if not all(type(value) is int and 0 <= value <= 16_384 for value in (width, height)):
        fail("Vulkan result extent is outside the supported bound")
    prefix = (
        nonce.encode("utf-8"),
        record["deviceName"].encode("utf-8"),
        record["driver"].encode("utf-8"),
    )
    suffix = struct.pack("<II", width, height)
    if record["probe"] == "vulkan-application":
        atlas_format = record.get("colorAtlasFormat")
        if not isinstance(atlas_format, str) or atlas_format not in VULKAN_ATLAS_FORMATS:
            fail("Vulkan color atlas format is unsupported")
        if record["frameCount"] == 0:
            if (width, height) != (0, 0) or record.get("surfaceFormat") != "none":
                fail("offscreen Vulkan result must have no surface extent or format")
        else:
            surface_format = record.get("surfaceFormat")
            if not isinstance(surface_format, str) or surface_format not in {
                "bgra8-unorm", "rgba8-unorm", "bgra8-srgb", "rgba8-srgb",
            }:
                fail("Vulkan application surface format is unsupported")
        expected = fnv1a64(prefix + (
            struct.pack("<I", VULKAN_ATLAS_FORMATS[atlas_format]), suffix,
        ))
    else:
        compositor_format = record.get("format")
        if not isinstance(compositor_format, str) or compositor_format not in COMPOSITOR_FORMATS:
            fail("Vulkan compositor format is unsupported")
        expected = fnv1a64(prefix + (compositor_format.encode("utf-8"), suffix))
    if record["resultHash"] != expected:
        fail("Vulkan resultHash differs from the independent probe metadata digest")


def validate_visual_readback(record: dict[str, Any], nonce: str, frame_count: int) -> None:
    if record.get("visualReadbackEncoding") != VISUAL_READBACK_ENCODING:
        fail("visual readback encoding is missing or unsupported")
    encoded = record.get("visualReadbackRGBHex")
    if not isinstance(encoded, str) or VISUAL_READBACK_HEX.fullmatch(encoded) is None:
        fail("visual readback must contain 120 lowercase RGB8 cell-center samples")
    actual = bytes.fromhex(encoded)
    expected = PIXEL_ORACLE.expected_readback_rgb(nonce, frame_count)
    if any(abs(observed - reference) > 8 for observed, reference in zip(actual, expected)):
        fail("visual readback differs from the independent challenge color oracle")


def validate_compositor_background(record: dict[str, Any]) -> None:
    encoded = record.get("scanoutBackgroundRGBAHex")
    if not isinstance(encoded, str) or SCANOUT_BACKGROUND_RGBA_HEX.fullmatch(encoded) is None:
        fail("Vulkan compositor background readback is missing or malformed")
    observed = bytes.fromhex(encoded)
    if any(abs(actual - expected) > 2 for actual, expected in zip(
        observed, (0, 64, 191, 255)
    )):
        fail("Vulkan compositor background differs from the independent color oracle")


def validate_application_offscreen_readback(record: dict[str, Any], nonce: str) -> None:
    if record.get("offscreenExtent") != OFFSCREEN_APPLICATION_EXTENT:
        fail("Vulkan application offscreen extent is missing or unsupported")
    if record.get("offscreenReadbackEncoding") != VISUAL_READBACK_ENCODING:
        fail("Vulkan application offscreen readback encoding is missing or unsupported")
    encoded = record.get("offscreenReadbackRGBHex")
    if not isinstance(encoded, str) or VISUAL_READBACK_HEX.fullmatch(encoded) is None:
        fail("Vulkan application offscreen readback must contain 120 RGB8 samples")
    expected = PIXEL_ORACLE.expected_readback_rgb(nonce, 1)
    if any(abs(observed - reference) > 8 for observed, reference in zip(
        bytes.fromhex(encoded), expected
    )):
        fail("Vulkan application offscreen readback differs from the challenge oracle")
    background = record.get("offscreenBackgroundRGBAHex")
    if not isinstance(background, str) or SCANOUT_BACKGROUND_RGBA_HEX.fullmatch(background) is None:
        fail("Vulkan application offscreen background readback is missing or malformed")
    if any(abs(observed - reference) > 2 for observed, reference in zip(
        bytes.fromhex(background), (8, 24, 48, 255)
    )):
        fail("Vulkan application offscreen background differs from the color oracle")
    coherence = record.get("offscreenReadbackMemoryCoherency")
    if not isinstance(coherence, str) or coherence not in {"coherent", "noncoherent"}:
        fail("Vulkan application offscreen readback memory coherency is invalid")


PRESENTED_APPLICATION_FIELDS = (
    "presentedReadbackEncoding", "presentedReadbackRGBHex",
    "presentedBackgroundRGBAHex", "presentedReadbackMemoryCoherency",
)


def validate_application_presented_readback(record: dict[str, Any], nonce: str) -> None:
    if record["frameCount"] == 0:
        if any(key in record for key in PRESENTED_APPLICATION_FIELDS):
            fail("offscreen Vulkan application must not claim presented readback")
        return
    if record.get("presentedReadbackEncoding") != VISUAL_READBACK_ENCODING:
        fail("Vulkan application presented readback encoding is missing or unsupported")
    encoded = record.get("presentedReadbackRGBHex")
    if not isinstance(encoded, str) or VISUAL_READBACK_HEX.fullmatch(encoded) is None:
        fail("Vulkan application presented readback must contain 120 RGB8 samples")
    expected = PIXEL_ORACLE.expected_readback_rgb(nonce, 1)
    if record["surfaceFormat"].endswith("-srgb"):
        expected = bytes(
            channel for offset in range(0, len(expected), 3)
            for channel in PIXEL_ORACLE._srgb_color(tuple(expected[offset:offset + 3]))
        )
    if any(abs(observed - reference) > 8 for observed, reference in zip(
        bytes.fromhex(encoded), expected
    )):
        fail("Vulkan application presented readback differs from the challenge oracle")
    background = record.get("presentedBackgroundRGBAHex")
    if not isinstance(background, str) or SCANOUT_BACKGROUND_RGBA_HEX.fullmatch(background) is None:
        fail("Vulkan application presented background readback is missing or malformed")
    expected_background = (8, 24, 48)
    if record["surfaceFormat"].endswith("-srgb"):
        expected_background = PIXEL_ORACLE._srgb_color(expected_background)
    if any(abs(observed - reference) > 8 for observed, reference in zip(
        bytes.fromhex(background), (*expected_background, 255)
    )):
        fail("Vulkan application presented background differs from the color oracle")
    coherence = record.get("presentedReadbackMemoryCoherency")
    if not isinstance(coherence, str) or coherence not in {"coherent", "noncoherent"}:
        fail("Vulkan application presented readback memory coherency is invalid")


def validate(record: Any, expected_nonce: str | None = None) -> dict[str, Any]:
    if not isinstance(record, dict):
        fail("probe result must be one JSON object")
    if (
        record.get("schema") != "dev.dory.gpu-probe"
        or type(record.get("version")) is not int
        or record["version"] != 1
    ):
        fail("unsupported probe schema/version")
    if nonempty_string(record, "probe") not in PROBES:
        fail("unknown probe kind")
    device = nonempty_string(record, "deviceName")
    driver = nonempty_string(record, "driver")
    renderer_identity = f"{device} {driver}".lower()
    if any(name in renderer_identity for name in SOFTWARE_RENDERERS):
        fail("software Vulkan/OpenGL renderer is not campaign evidence")
    nonempty_string(record, "apiVersion")
    extensions = record.get("extensionsUsed")
    if not isinstance(extensions, list) or not all(
        isinstance(value, str) and value for value in extensions
    ):
        fail("extensionsUsed must be an array of non-empty strings")
    if "featuresUsed" in record:
        features = record["featuresUsed"]
        if not isinstance(features, list) or not all(
            isinstance(value, str) and value for value in features
        ) or features != sorted(set(features)):
            fail("featuresUsed must be a sorted unique array of non-empty strings")
    result_hash = nonempty_string(record, "resultHash")
    if RESULT_HASH.fullmatch(result_hash) is None:
        fail("resultHash must be a lowercase fnv1a64 digest")
    frame_count = record.get("frameCount")
    if not isinstance(frame_count, int) or isinstance(frame_count, bool) or frame_count < 0:
        fail("frameCount must be a non-negative integer")
    nonce = nonempty_string(record, "nonce")
    if expected_nonce is not None and nonce != expected_nonce:
        fail("probe nonce does not match the campaign nonce")
    timings = record.get("timings")
    if not isinstance(timings, dict) or not timings:
        fail("timings must be a non-empty object")
    for key, value in timings.items():
        if not isinstance(key, str) or not key.endswith("Milliseconds"):
            fail("timing keys must end in Milliseconds")
        if not isinstance(value, (int, float)) or isinstance(value, bool):
            fail(f"timing {key} must be numeric")
        if not math.isfinite(value) or value < 0:
            fail(f"timing {key} must be finite and non-negative")
    if record["probe"] in {"compute", "gl", "vulkan-compositor"} and frame_count == 0:
        fail(f"{record['probe']} must report at least one completed frame/workload")
    if record["probe"] == "compute":
        coherency = record.get("memoryCoherency")
        if coherency is not None and (
            not isinstance(coherency, dict)
            or set(coherency) != {"input", "output"}
            or any(
                not isinstance(value, str) or value not in {"coherent", "noncoherent"}
                for value in coherency.values()
            )
        ):
            fail("compute memory coherency record is malformed")
        reduction, expected_hash = expected_compute_result(nonce)
        if (
            frame_count != 1
            or extensions
            or record.get("elementCount") != 1024 * 1024
            or record.get("reduction") != reduction
            or result_hash != expected_hash
        ):
            fail("compute result does not match the independent v1 reduction oracle")
    if record["probe"] in {"vulkan-application", "vulkan-compositor"}:
        if record["probe"] == "vulkan-compositor" and "readbackMemoryCoherency" in record:
            value = record["readbackMemoryCoherency"]
            if not isinstance(value, str) or value not in {"coherent", "noncoherent"}:
                fail("Vulkan compositor readback memory coherency is invalid")
        if record["probe"] == "vulkan-compositor" and frame_count != 1:
            fail("Vulkan compositor must report exactly one presented frame")
        if record["probe"] == "vulkan-application" and frame_count not in {0, 1}:
            fail("Vulkan application must report zero or one presented frame")
        validate_vulkan_result_hash(record, nonce)
        if record["probe"] == "vulkan-application":
            validate_application_offscreen_readback(record, nonce)
            validate_application_presented_readback(record, nonce)
    if record["probe"] in {"gl", "vulkan-compositor", "vulkan-application"}:
        if frame_count > 0:
            extent = record.get("extent")
            if not isinstance(extent, dict) or set(extent) != {"width", "height"}:
                fail("presenting probe extent is missing or malformed")
            width, height = extent["width"], extent["height"]
            if not all(type(value) is int and 1 <= value <= 16_384 for value in (width, height)):
                fail("presenting probe extent is outside the supported bound")
            cell = max(8, min(20, width // 80, height // 50))
            if 24 + 12 * cell > width or 24 + 10 * cell > height:
                fail("presenting probe extent cannot contain its visual challenge")
            hold = record.get("presentedHoldMilliseconds")
            if type(hold) is not int or not 0 <= hold <= 30_000:
                fail("presenting probe hold duration is missing or invalid")
            if "presentedReadyFile" in record:
                ready_file = record["presentedReadyFile"]
                if (
                    not isinstance(ready_file, str) or not ready_file.startswith("/")
                    or len(ready_file) > 4096
                    or any(ord(character) < 32 for character in ready_file)
                ):
                    fail("presented-frame marker path is invalid")
            try:
                PIXEL_ORACLE.validate_challenge_record(
                    record.get("visualChallenge"), nonce, frame_count
                )
            except PIXEL_ORACLE.PixelOracleError as error:
                fail(str(error))
        elif any(key in record for key in (
            "visualChallenge", "presentedHoldMilliseconds", "presentedReadyFile",
        )):
            fail("a non-presenting probe must not claim a visual challenge or hold")
    if record["probe"] == "gl":
        if record.get("extent") != {"width": 960, "height": 600}:
            fail("GL visual readback has an unsupported source extent")
        validate_visual_readback(record, nonce, frame_count)
    elif record["probe"] == "vulkan-compositor":
        validate_visual_readback(record, nonce, frame_count)
        validate_compositor_background(record)
    elif "visualReadbackRGBHex" in record or "visualReadbackEncoding" in record:
        fail("only presenting GL and Vulkan compositor probes may claim visual readback")
    if record["probe"] != "vulkan-compositor" and "scanoutBackgroundRGBAHex" in record:
        fail("only the Vulkan compositor may claim a scanout background readback")
    if record["probe"] != "vulkan-application" and any(
        key in record for key in (
            "offscreenExtent", "offscreenReadbackEncoding", "offscreenReadbackRGBHex",
            "offscreenBackgroundRGBAHex", "offscreenReadbackMemoryCoherency",
            *PRESENTED_APPLICATION_FIELDS,
        )
    ):
        fail("only the Vulkan application may claim offscreen readback")
    return record


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--nonce", help="require the exact campaign nonce")
    parser.add_argument("path", nargs="?", help="result file; stdin when omitted")
    arguments = parser.parse_args()
    try:
        if arguments.path:
            with open(arguments.path, encoding="utf-8") as source:
                record = json.load(source)
        else:
            record = json.load(sys.stdin)
        validate(record, arguments.nonce)
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"invalid Dory GPU probe result: {error}", file=sys.stderr)
        return 1
    json.dump(record, sys.stdout, sort_keys=True, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
