#!/usr/bin/env python3
"""Fail-closed validation for one dev.dory.gpu-probe v1 result."""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from typing import Any


PROBES = {"vulkan-application", "vulkan-compositor", "compute", "gl"}
SOFTWARE_RENDERERS = ("llvmpipe", "lavapipe", "software rasterizer")
RESULT_HASH = re.compile(r"^fnv1a64:[0-9a-f]{16}$")


def fail(message: str) -> None:
    raise ValueError(message)


def nonempty_string(record: dict[str, Any], key: str) -> str:
    value = record.get(key)
    if not isinstance(value, str) or not value:
        fail(f"{key} must be a non-empty string")
    return value


def validate(record: Any, expected_nonce: str | None = None) -> dict[str, Any]:
    if not isinstance(record, dict):
        fail("probe result must be one JSON object")
    if record.get("schema") != "dev.dory.gpu-probe" or record.get("version") != 1:
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
