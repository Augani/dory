#!/usr/bin/env python3
"""Verify one retained Dory physical GPU displayed-pixel evidence bundle."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
from typing import Any


ROOT = Path(__file__).resolve().parent
PROBE_VALIDATOR_PATH = ROOT / "validate-result.py"
SPEC = importlib.util.spec_from_file_location("dory_probe_validator", PROBE_VALIDATOR_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load the Dory GPU probe validator")
PROBE_VALIDATOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PROBE_VALIDATOR
SPEC.loader.exec_module(PROBE_VALIDATOR)
PIXEL_ORACLE_PATH = ROOT / "pixel-oracle.py"
PIXEL_SPEC = importlib.util.spec_from_file_location("dory_pixel_oracle", PIXEL_ORACLE_PATH)
if PIXEL_SPEC is None or PIXEL_SPEC.loader is None:
    raise RuntimeError("could not load the Dory pixel oracle")
PIXEL_ORACLE = importlib.util.module_from_spec(PIXEL_SPEC)
sys.modules[PIXEL_SPEC.name] = PIXEL_ORACLE
PIXEL_SPEC.loader.exec_module(PIXEL_ORACLE)
BUILD_RECEIPT_PATH = ROOT / "verify-build-receipt.py"
BUILD_SPEC = importlib.util.spec_from_file_location(
    "dory_probe_build_receipt", BUILD_RECEIPT_PATH
)
if BUILD_SPEC is None or BUILD_SPEC.loader is None:
    raise RuntimeError("could not load the Dory probe build receipt validator")
BUILD_RECEIPT = importlib.util.module_from_spec(BUILD_SPEC)
sys.modules[BUILD_SPEC.name] = BUILD_RECEIPT
BUILD_SPEC.loader.exec_module(BUILD_RECEIPT)
TRACE_CHAIN_PATH = ROOT / "graphics-trace-chain.py"
TRACE_SPEC = importlib.util.spec_from_file_location("dory_graphics_trace_chain", TRACE_CHAIN_PATH)
if TRACE_SPEC is None or TRACE_SPEC.loader is None:
    raise RuntimeError("could not load the Dory accelerated graphics trace verifier")
TRACE_CHAIN = importlib.util.module_from_spec(TRACE_SPEC)
TRACE_SPEC.loader.exec_module(TRACE_CHAIN)


class EvidenceError(ValueError):
    pass


MAX_RECEIPT_BYTES = 8 * 1024 * 1024
MAX_CAPTURE_OR_TRACE_BYTES = 64 * 1024 * 1024


def fail(message: str) -> None:
    raise EvidenceError(message)


def file_limit(path: Path) -> int:
    return (
        MAX_CAPTURE_OR_TRACE_BYTES
        if path.name in {"framebuffer.png", "graphics-trace.ndjson"}
        else MAX_RECEIPT_BYTES
    )


def direct_file(root: Path, name: str) -> Path:
    path = root / name
    try:
        entry = path.lstat()
    except OSError as error:
        fail(f"{name} is missing: {error}")
    if not stat.S_ISREG(entry.st_mode) or path.is_symlink() or entry.st_size <= 0:
        fail(f"{name} must be a nonempty direct regular file")
    if entry.st_size > file_limit(path):
        fail(f"{name} exceeds the supported byte bound")
    return path


def bounded_bytes(path: Path, label: str) -> bytes:
    limit = file_limit(path)
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
        with os.fdopen(descriptor, "rb") as source:
            entry = os.fstat(source.fileno())
            if not stat.S_ISREG(entry.st_mode) or entry.st_size > limit:
                fail(f"{label} is not a bounded direct regular file")
            payload = source.read(limit + 1)
    except OSError as error:
        fail(f"{label} is unreadable: {error}")
    if len(payload) > limit:
        fail(f"{label} exceeds the supported byte bound")
    return payload


def digest(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def unique_json_fields(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            fail(f"JSON contains a duplicate {key} field")
        value[key] = item
    return value


def reject_json_constant(value: str) -> None:
    fail(f"JSON contains unsupported constant {value}")


def object_from(payload: bytes, label: str) -> dict[str, Any]:
    try:
        value = json.loads(
            payload, object_pairs_hook=unique_json_fields,
            parse_constant=reject_json_constant,
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"{label} is invalid JSON: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must contain one JSON object")
    return value


def positive_integer(value: Any, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        fail(f"{label} must be a positive integer")
    return value


def nonempty_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        fail(f"{label} must be a nonempty string")
    return value


def matching_fields(
    left: dict[str, Any], right: dict[str, Any], fields: tuple[str, ...], label: str
) -> None:
    for field in fields:
        if left.get(field) != right.get(field):
            fail(f"{label} disagrees on {field}")


def trace_events(payload: bytes) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    try:
        for index, line in enumerate(
            payload.decode("utf-8").splitlines(), 1
        ):
            if not line:
                fail(f"graphics trace line {index} is empty")
            event = json.loads(
                line, object_pairs_hook=unique_json_fields,
                parse_constant=reject_json_constant,
            )
            if not isinstance(event, dict):
                fail(f"graphics trace line {index} is not an object")
            events.append(event)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"graphics trace is invalid NDJSON: {error}")
    return events


def verify(root: Path, expected_nonce: str | None = None) -> dict[str, Any]:
    if not root.is_dir() or root.is_symlink():
        fail("evidence root must be a direct directory")

    paths = {
        name: direct_file(root, name)
        for name in (
            "gpu-probe.json",
            "gpu-probe-build-receipt.txt",
            "gpu-probe-ready-transport.json",
            "framebuffer.png",
            "display-capture-frame.json",
            "display-capture-frame.released",
            "window-capture.json",
            "graphics-trace.ndjson",
            "graphics-correlation.json",
            "pixel-oracle.json",
            "gpu-display-evidence.json",
        )
    }
    # Freeze each direct artifact once. Parsing, hashing, and the pixel oracle must consume
    # identical bytes even if a campaign producer is still publishing nearby evidence.
    payloads = {name: bounded_bytes(path, name) for name, path in paths.items()}

    probe = object_from(payloads["gpu-probe.json"], "GPU probe")
    try:
        PROBE_VALIDATOR.validate(probe, expected_nonce)
    except ValueError as error:
        fail(f"GPU probe is invalid: {error}")
    try:
        BUILD_RECEIPT.validate_payload(
            payloads["gpu-probe-build-receipt.txt"], source_directory=ROOT
        )
    except (OSError, BUILD_RECEIPT.BuildReceiptError) as error:
        fail(f"GPU probe build receipt is invalid: {error}")

    capture_frame = object_from(payloads["display-capture-frame.json"], "capture-frame receipt")
    if (
        capture_frame.get("kind") != "dev.dory.display-qualification-window"
        or capture_frame.get("schemaVersion") != 2
        or capture_frame.get("framePollingHeldForCapture") is not True
    ):
        fail("capture-frame receipt schema identity is invalid")
    if payloads["display-capture-frame.released"] != (
        b"capture-next-metal-completed-frame\n"
    ):
        fail("qualification capture release marker is invalid")
    machine = nonempty_string(capture_frame.get("machineID"), "capture machineID")
    operation = nonempty_string(capture_frame.get("operationID"), "capture operationID")
    ready_path = probe.get("presentedReadyFile")
    if (
        not isinstance(ready_path, str) or not ready_path.startswith("/")
        or type(probe.get("presentedHoldMilliseconds")) is not int
        or probe["presentedHoldMilliseconds"] < 5000
    ):
        fail("GPU probe lacks a bounded presented-frame marker and capture hold")
    ready_transport = object_from(
        payloads["gpu-probe-ready-transport.json"], "GPU probe ready transport"
    )
    if (
        ready_transport.get("schema") != "dev.dory.machine.exec"
        or ready_transport.get("version") != 1
        or ready_transport.get("machine") != machine
        or ready_transport.get("argv") != ["cat", ready_path]
        or type(ready_transport.get("exitCode")) is not int
        or ready_transport["exitCode"] != 0
        or ready_transport.get("timedOut") is not False
        or ready_transport.get("stdoutTruncated") is not False
        or ready_transport.get("stderrTruncated") is not False
        or ready_transport.get("stdout") != (
            "dory-visual-presented:"
            f"{probe['visualChallenge']['payloadHash']}:{probe['frameCount']}\n"
        )
    ):
        fail("GPU probe ready transport does not prove the presented marker")
    generation = positive_integer(
        capture_frame.get("displayResourceGeneration"), "capture displayResourceGeneration"
    )
    completion = positive_integer(
        capture_frame.get("metalCommandBufferCompletionID"),
        "capture metalCommandBufferCompletionID",
    )
    positive_integer(capture_frame.get("frameSequence"), "capture frameSequence")
    if capture_frame.get("scanoutID") != 0:
        fail("capture-frame receipt is not for scanout zero")

    capture = object_from(payloads["window-capture.json"], "window capture")
    if (
        capture.get("kind") != "dev.dory.machine-window-capture"
        or capture.get("schemaVersion") != 2
        or capture.get("status") != "PASS"
    ):
        fail("window capture schema identity or status is invalid")
    matching_fields(
        capture,
        capture_frame,
        (
            "machineID",
            "operationID",
            "frameSequence",
            "displayResourceGeneration",
            "metalCommandBufferCompletionID",
            "windowNumber",
            "windowTitle",
            "transport",
            "guestViewport",
            "framePollingHeldForCapture",
        ),
        "window capture",
    )
    framebuffer_bytes = payloads["framebuffer.png"]
    framebuffer_sha256 = digest(framebuffer_bytes)
    capture_frame_sha256 = digest(payloads["display-capture-frame.json"])
    if capture.get("framebufferSHA256") != framebuffer_sha256:
        fail("window capture framebuffer digest does not match")
    if capture.get("windowReceiptSHA256") != capture_frame_sha256:
        fail("window capture receipt digest does not match")

    events = trace_events(payloads["graphics-trace.ndjson"])
    try:
        chain = TRACE_CHAIN.verify(events, capture_frame)
    except TRACE_CHAIN.TraceChainError as error:
        fail(f"graphics trace has no authenticated accelerated frame chain: {error}")
    viewport = capture_frame.get("guestViewport")
    if not isinstance(viewport, dict):
        fail("capture-frame receipt lacks guest viewport geometry")
    for origin_key, extent_key, surface_key in (
        ("sourceX", "sourceWidth", "graphicsSurfaceWidth"),
        ("sourceY", "sourceHeight", "graphicsSurfaceHeight"),
    ):
        origin = viewport.get(origin_key)
        extent = viewport.get(extent_key)
        if (
            type(origin) is not int or type(extent) is not int
            or origin < 0 or extent <= 0
            or origin + extent > chain[surface_key]
        ):
            fail("captured guest source rectangle exceeds the accelerated surface")
    trace_sha256 = digest(payloads["graphics-trace.ndjson"])

    correlation = object_from(payloads["graphics-correlation.json"], "graphics correlation")
    if (
        correlation.get("kind") != "dev.dory.display-graphics-correlation"
        or correlation.get("schemaVersion") != 3
        or correlation.get("status") != "PASS"
    ):
        fail("graphics correlation schema identity or status is invalid")
    matching_fields(
        correlation,
        capture,
        (
            "machineID",
            "operationID",
            "frameSequence",
            "displayResourceGeneration",
            "metalCommandBufferCompletionID",
            "framebufferSHA256",
        ),
        "graphics correlation",
    )
    for field, value in chain.items():
        if correlation.get(field) != value:
            fail(f"graphics correlation {field} does not match the accelerated trace")
    if correlation.get("graphicsTraceSHA256") != trace_sha256:
        fail("graphics correlation trace digest does not match")

    evidence = object_from(payloads["gpu-display-evidence.json"], "displayed-pixel evidence")
    if (
        evidence.get("kind") != "dev.dory.gpu-displayed-pixel-evidence"
        or evidence.get("schemaVersion") != 3
        or evidence.get("status") != "PASS"
    ):
        fail("displayed-pixel evidence schema identity or status is invalid")
    matching_fields(
        evidence,
        capture,
        (
            "machineID",
            "operationID",
            "frameSequence",
            "framebufferSHA256",
            "displayResourceGeneration",
            "metalCommandBufferCompletionID",
        ),
        "displayed-pixel evidence",
    )
    for evidence_key, probe_key in (
        ("probe", "probe"),
        ("probeNonce", "nonce"),
        ("probeResultHash", "resultHash"),
        ("deviceName", "deviceName"),
        ("driver", "driver"),
        ("frameCount", "frameCount"),
        ("visualChallenge", "visualChallenge"),
        ("probePresentedReadyFile", "presentedReadyFile"),
    ):
        if evidence.get(evidence_key) != probe.get(probe_key):
            fail(f"displayed-pixel evidence disagrees on {evidence_key}")
    for field, value in chain.items():
        if evidence.get(field) != value:
            fail(f"displayed-pixel evidence {field} does not match the accelerated trace")
    expected_digests = {
        "probeSHA256": digest(payloads["gpu-probe.json"]),
        "probeBuildReceiptSHA256": digest(payloads["gpu-probe-build-receipt.txt"]),
        "probeReadyTransportSHA256": digest(payloads["gpu-probe-ready-transport.json"]),
        "framebufferSHA256": framebuffer_sha256,
        "windowReceiptSHA256": capture_frame_sha256,
        "graphicsTraceSHA256": trace_sha256,
        "graphicsCorrelationSHA256": digest(payloads["graphics-correlation.json"]),
        "captureReceiptSHA256": digest(payloads["window-capture.json"]),
        "captureReleaseSHA256": digest(payloads["display-capture-frame.released"]),
        "pixelOracleSHA256": digest(payloads["pixel-oracle.json"]),
    }
    for key, expected in expected_digests.items():
        if evidence.get(key) != expected:
            fail(f"displayed-pixel evidence {key} does not match")

    try:
        pixel_result = PIXEL_ORACLE.verify_image_pixels(
            PIXEL_ORACLE.decode_png_bytes(framebuffer_bytes),
            capture.get("guestViewport"),
            probe["nonce"],
            probe["frameCount"],
            probe_kind=probe["probe"],
            probe_extent=probe.get("extent"),
            probe_format=probe.get("surfaceFormat"),
        )
    except PIXEL_ORACLE.PixelOracleError as error:
        fail(f"captured pixels are invalid: {error}")
    retained_pixel_result = object_from(payloads["pixel-oracle.json"], "pixel oracle")
    if retained_pixel_result != pixel_result:
        fail("retained pixel oracle result differs from independent replay")
    if capture.get("captureWidth") != pixel_result["imageWidth"]:
        fail("window capture width disagrees with the decoded PNG")
    if capture.get("captureHeight") != pixel_result["imageHeight"]:
        fail("window capture height disagrees with the decoded PNG")

    return {
        "status": "evidence-verified",
        "machineID": machine,
        "operationID": operation,
        "probe": probe["probe"],
        "probeNonce": probe["nonce"],
        "probeSHA256": digest(payloads["gpu-probe.json"]),
        "displayResourceGeneration": generation,
        "metalCommandBufferCompletionID": completion,
        **chain,
        "visualChallengePayloadHash": pixel_result["payloadHash"],
        "gpuDisplayedPixelEvidenceSHA256": digest(payloads["gpu-display-evidence.json"]),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nonce", help="require the exact campaign nonce")
    parser.add_argument("evidence_directory", type=Path)
    arguments = parser.parse_args()
    try:
        result = verify(arguments.evidence_directory, arguments.nonce)
    except (OSError, EvidenceError, ValueError) as error:
        print(f"invalid Dory GPU displayed-pixel evidence: {error}", file=sys.stderr)
        return 1
    json.dump(result, sys.stdout, sort_keys=True, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
