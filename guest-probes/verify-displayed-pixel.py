#!/usr/bin/env python3
"""Verify one retained Dory physical GPU displayed-pixel evidence bundle."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
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
SPEC.loader.exec_module(PROBE_VALIDATOR)


class EvidenceError(ValueError):
    pass


def fail(message: str) -> None:
    raise EvidenceError(message)


def direct_file(root: Path, name: str) -> Path:
    path = root / name
    try:
        entry = path.lstat()
    except OSError as error:
        fail(f"{name} is missing: {error}")
    if not stat.S_ISREG(entry.st_mode) or path.is_symlink() or entry.st_size <= 0:
        fail(f"{name} must be a nonempty direct regular file")
    return path


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def object_from(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
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


def trace_events(path: Path) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    try:
        for index, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if not line:
                fail(f"graphics trace line {index} is empty")
            event = json.loads(line)
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
            "framebuffer.png",
            "display-capture-frame.json",
            "window-capture.json",
            "graphics-trace.ndjson",
            "graphics-correlation.json",
            "gpu-display-evidence.json",
        )
    }
    if paths["framebuffer.png"].read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
        fail("framebuffer.png is not a PNG")

    probe = object_from(paths["gpu-probe.json"], "GPU probe")
    try:
        PROBE_VALIDATOR.validate(probe, expected_nonce)
    except ValueError as error:
        fail(f"GPU probe is invalid: {error}")

    capture_frame = object_from(paths["display-capture-frame.json"], "capture-frame receipt")
    if (
        capture_frame.get("kind") != "dev.dory.display-qualification-window"
        or capture_frame.get("schemaVersion") != 1
    ):
        fail("capture-frame receipt schema identity is invalid")
    machine = nonempty_string(capture_frame.get("machineID"), "capture machineID")
    operation = nonempty_string(capture_frame.get("operationID"), "capture operationID")
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

    capture = object_from(paths["window-capture.json"], "window capture")
    if (
        capture.get("kind") != "dev.dory.machine-window-capture"
        or capture.get("schemaVersion") != 1
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
        ),
        "window capture",
    )
    framebuffer_sha256 = digest(paths["framebuffer.png"])
    capture_frame_sha256 = digest(paths["display-capture-frame.json"])
    if capture.get("framebufferSHA256") != framebuffer_sha256:
        fail("window capture framebuffer digest does not match")
    if capture.get("windowReceiptSHA256") != capture_frame_sha256:
        fail("window capture receipt digest does not match")

    events = trace_events(paths["graphics-trace.ndjson"])
    matches = [
        event
        for event in events
        if event.get("stage") == "metalPresentationCompleted"
        and isinstance(event.get("context"), dict)
        and event["context"].get("machineID") == machine
        and event["context"].get("operationID") == operation
        and event.get("scanoutID") == 0
        and event.get("displayResourceGeneration") == generation
        and event.get("metalCommandBufferCompletionID") == completion
    ]
    if len(matches) != 1:
        fail("graphics trace must contain exactly one matching Metal completion")
    trace_sha256 = digest(paths["graphics-trace.ndjson"])

    correlation = object_from(paths["graphics-correlation.json"], "graphics correlation")
    if (
        correlation.get("kind") != "dev.dory.display-graphics-correlation"
        or correlation.get("schemaVersion") != 1
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
    if correlation.get("graphicsTraceSequence") != matches[0].get("sequence"):
        fail("graphics correlation trace sequence does not match")
    if correlation.get("graphicsTraceSHA256") != trace_sha256:
        fail("graphics correlation trace digest does not match")

    evidence = object_from(paths["gpu-display-evidence.json"], "displayed-pixel evidence")
    if (
        evidence.get("kind") != "dev.dory.gpu-displayed-pixel-evidence"
        or evidence.get("schemaVersion") != 1
        or evidence.get("status") != "PASS"
    ):
        fail("displayed-pixel evidence schema identity or status is invalid")
    matching_fields(
        evidence,
        capture,
        (
            "machineID",
            "operationID",
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
    ):
        if evidence.get(evidence_key) != probe.get(probe_key):
            fail(f"displayed-pixel evidence disagrees on {evidence_key}")
    expected_digests = {
        "probeSHA256": digest(paths["gpu-probe.json"]),
        "framebufferSHA256": framebuffer_sha256,
        "windowReceiptSHA256": capture_frame_sha256,
        "graphicsTraceSHA256": trace_sha256,
        "graphicsCorrelationSHA256": digest(paths["graphics-correlation.json"]),
        "captureReceiptSHA256": digest(paths["window-capture.json"]),
    }
    for key, expected in expected_digests.items():
        if evidence.get(key) != expected:
            fail(f"displayed-pixel evidence {key} does not match")

    return {
        "status": "evidence-verified",
        "machineID": machine,
        "operationID": operation,
        "probe": probe["probe"],
        "probeNonce": probe["nonce"],
        "displayResourceGeneration": generation,
        "metalCommandBufferCompletionID": completion,
        "gpuDisplayedPixelEvidenceSHA256": digest(paths["gpu-display-evidence.json"]),
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
