#!/usr/bin/env python3
"""Verify and summarize one controlled Dory OpenGL strategy comparison."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
from typing import Any


ROOT = Path(__file__).resolve().parent
PIXEL_SPEC = importlib.util.spec_from_file_location(
    "dory_strategy_pixel_verifier", ROOT / "verify-displayed-pixel.py")
if PIXEL_SPEC is None or PIXEL_SPEC.loader is None:
    raise RuntimeError("could not load the displayed-pixel verifier")
PIXEL_VERIFIER = importlib.util.module_from_spec(PIXEL_SPEC)
sys.modules[PIXEL_SPEC.name] = PIXEL_VERIFIER
PIXEL_SPEC.loader.exec_module(PIXEL_VERIFIER)

SCHEMA = "dory.opengl-strategy-comparison@4"
RUN_SCHEMA = "dory.opengl-strategy-run@1"
COLLECTION_SCHEMA = "dory.opengl-workload-collection@5"
INVENTORY_SCHEMA = "dory.opengl-guest-inventory@1"
PATHS = ("zink-venus", "virgl2-angle")
ZINK_REQUIRED_CAPABILITIES = frozenset((
    "VK_EXT_extended_dynamic_state",
    "VK_EXT_robustness2",
    "dynamicRendering",
    "timelineSemaphore",
))
WORKLOADS = (
    "glmark2",
    "gnome-shell-overview",
    "kwin-overview",
    "gtk4-demo",
    "qt6-demo",
    "firefox-webgl-aquarium",
    "blender-viewport",
    "libreoffice-impress",
    "zed-editor",
)
SHA256 = re.compile(r"^[0-9a-f]{64}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
MAX_RAW_BYTES = 64 * 1_048_576
MAX_JSON_BYTES = 8 * 1_048_576
GLMARK_SCORE = re.compile(r"^glmark2 Score:\s*([1-9][0-9]*)\s*$", re.MULTILINE)


class EvidenceError(ValueError):
    pass


def fail(message: str) -> None:
    raise EvidenceError(message)


def unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            fail(f"retained JSON duplicates {key}")
        value[key] = item
    return value


def reject_json_constant(value: str) -> Any:
    fail(f"retained JSON contains non-finite {value}")


def direct_json_payload(root: Path, name: str) -> tuple[dict[str, Any], bytes]:
    path = root / name
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
        with os.fdopen(descriptor, "rb") as source:
            metadata = os.fstat(source.fileno())
            if not stat.S_ISREG(metadata.st_mode) or not 0 < metadata.st_size <= MAX_JSON_BYTES:
                fail(f"{name} must be a bounded nonempty direct regular file")
            payload = source.read(MAX_JSON_BYTES + 1)
    except OSError as error:
        fail(f"{name} is missing or indirect: {error}")
    if len(payload) != metadata.st_size:
        fail(f"{name} changed while it was read")
    try:
        value = json.loads(
            payload, object_pairs_hook=unique_json_object,
            parse_constant=reject_json_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"{name} is invalid JSON: {error}")
    if not isinstance(value, dict):
        fail(f"{name} must contain one JSON object")
    return value, payload


def direct_json(root: Path, name: str) -> dict[str, Any]:
    return direct_json_payload(root, name)[0]


def verify_raw_file(directory: Path, filename: str, expected: Any,
                    label: str) -> bytes:
    if not isinstance(expected, str) or SHA256.fullmatch(expected) is None:
        fail(f"{label} lacks a valid SHA-256 digest")
    path = directory / filename
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
        with os.fdopen(descriptor, "rb") as source:
            metadata = os.fstat(source.fileno())
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > MAX_RAW_BYTES:
                fail(f"{label} must be a bounded direct regular file")
            data = source.read(MAX_RAW_BYTES + 1)
    except OSError as error:
        fail(f"{label} is missing or indirect: {error}")
    if len(data) != metadata.st_size or hashlib.sha256(data).hexdigest() != expected:
        fail(f"{label} differs from the retained raw workload file")
    return data


def trace_timestamps(raw: bytes, run: dict[str, Any], collection: dict[str, Any]) -> list[int]:
    if raw and not raw.endswith(b"\n"):
        fail("raw graphics trace ends with a partial event")
    accepted: dict[tuple[int, int, int, int, int], int] = {}
    completed: set[tuple[int, int, int, int, int]] = set()
    completion_ids: set[int] = set()
    timestamps: list[int] = []
    for line in raw.splitlines():
        try:
            event = json.loads(line)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            fail(f"raw graphics trace contains invalid JSON: {error}")
        if not isinstance(event, dict) or event.get("stage") not in {
            "hostSubmissionAccepted", "metalPresentationCompleted",
        }:
            continue
        context = event.get("context")
        if not isinstance(context, dict) or context.get("machineID") != run["machineID"] \
                or context.get("operationID") != collection["operationID"] \
                or context.get("workerGeneration") != collection["workerGeneration"] \
                or event.get("scanoutID") != 0 \
                or event.get("width") != run["widthPixels"] \
                or event.get("height") != run["heightPixels"]:
            continue
        identity = tuple(event.get(field) for field in (
            "resourceID", "displayResourceGeneration", "rendererResourceGeneration",
            "deviceGeneration", "frameSequence",
        ))
        if not all(type(value) is int and value > 0 for value in identity):
            fail("raw accelerated frame lacks generation/resource identity")
        timestamp = event.get("monotonicNanoseconds")
        if type(timestamp) is not int or timestamp <= 0:
            fail("raw accelerated frame lacks a positive monotonic timestamp")
        if event["stage"] == "hostSubmissionAccepted":
            if identity in accepted:
                fail("raw graphics trace duplicates an accepted frame")
            accepted[identity] = timestamp
            continue
        completion_id = event.get("metalCommandBufferCompletionID")
        if identity not in accepted:
            fail("raw Metal completion lacks an earlier accepted host submission")
        if timestamp <= accepted[identity]:
            fail("raw Metal completion does not follow its accepted host submission")
        if identity in completed or type(completion_id) is not int or completion_id <= 0 \
                or completion_id in completion_ids \
                or (timestamps and timestamp <= timestamps[-1]):
            fail("raw graphics trace has invalid Metal completion identity or ordering")
        completed.add(identity)
        completion_ids.add(completion_id)
        timestamps.append(timestamp)
    return timestamps


def percentile(values: list[float], percent: int) -> float:
    ordered = sorted(values)
    return ordered[max(0, math.ceil(percent / 100 * len(ordered)) - 1)]


def replay_worker_samples(raw: bytes, measured: dict[str, Any], worker_pid: int) -> None:
    if raw and not raw.endswith(b"\n"):
        fail("raw renderer worker samples end with a partial event")
    lines = raw.splitlines()
    if len(lines) > 100_000:
        fail("raw renderer worker sample count exceeds the bound")
    previous_timestamp = 0
    peak_cpu: float | None = None
    peak_rss: int | None = None
    def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in pairs:
            if key in value:
                fail(f"raw renderer worker sample duplicates {key}")
            value[key] = item
        return value

    def reject_nonfinite(value: str) -> None:
        fail(f"raw renderer worker sample contains {value}")

    for line in lines:
        try:
            sample = json.loads(
                line, object_pairs_hook=unique_object,
                parse_constant=reject_nonfinite,
            )
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            fail(f"raw renderer worker sample is invalid JSON: {error}")
        if not isinstance(sample, dict):
            fail("raw renderer worker sample must be a JSON object")
        exact_keys(sample, {
            "monotonicNanoseconds", "workerPID", "cpuPercent", "rssBytes",
        }, "raw renderer worker sample")
        timestamp = positive_int(sample["monotonicNanoseconds"], "worker sample timestamp")
        if timestamp <= previous_timestamp or sample["workerPID"] != worker_pid:
            fail("raw renderer worker sample identity or ordering is invalid")
        previous_timestamp = timestamp
        cpu = nonnegative_number(sample["cpuPercent"], "worker sample CPU percent")
        rss = positive_int(sample["rssBytes"], "worker sample RSS bytes")
        peak_cpu = max(peak_cpu or 0, cpu)
        peak_rss = max(peak_rss or 0, rss)
    if measured["status"] == "PASS" and not lines:
        fail("passing workload lacks renderer worker CPU/RSS samples")
    if measured["workerPeakCPUPercent"] != peak_cpu \
            or measured["workerPeakRSSBytes"] != peak_rss:
        fail("renderer worker CPU/RSS peaks differ from retained raw samples")


def replay_workload(raw: dict[str, Any], measured: dict[str, Any], files: dict[str, bytes],
                    run: dict[str, Any], collection: dict[str, Any]) -> None:
    replay_worker_samples(
        files["workerSamplesSHA256"], measured, collection["workerPID"]
    )
    timestamps = trace_timestamps(files["graphicsTraceSHA256"], run, collection)
    if len(timestamps) != measured["frameCount"]:
        fail(f"{run['path']} {measured['id']} frame count differs from raw graphics trace")
    intervals = [(right - left) / 1_000_000 for left, right in
                 zip(timestamps, timestamps[1:])]
    for percent, field, value in (
        (95, "p95FrameIntervalMs", measured["p95FrameIntervalMs"]),
        (99, "p99FrameIntervalMs", raw["p99FrameIntervalMs"]),
    ):
        expected = percentile(intervals, percent) if intervals else None
        if value is None and expected is None:
            continue
        if not isinstance(value, (int, float)) or isinstance(value, bool) \
                or expected is None or not math.isclose(value, expected, abs_tol=1e-6):
            fail(f"{run['path']} {measured['id']} {field} differs from raw graphics trace")
    output = (files["stdoutSHA256"] + b"\n" + files["stderrSHA256"]).decode(
        "utf-8", errors="replace")
    stalls: list[int] = []
    for line in output.splitlines():
        if not line.startswith("DORY_METRIC "):
            continue
        try:
            event = json.loads(line[len("DORY_METRIC "):])
        except json.JSONDecodeError as error:
            fail(f"raw shader metric is invalid JSON: {error}")
        if not isinstance(event, dict) or set(event) != {"kind", "durationNanoseconds"} \
                or event["kind"] != "shaderCompile" \
                or type(event["durationNanoseconds"]) is not int \
                or event["durationNanoseconds"] < 0:
            fail("raw shader metric is malformed")
        stalls.append(event["durationNanoseconds"])
    stall = stalls[0] / 1_000_000 if stalls else None
    if measured["firstShaderCompileStallMs"] != stall:
        fail(f"{run['path']} {measured['id']} shader stall differs from raw output")
    if measured["id"] == "glmark2":
        scores = [int(value) for value in GLMARK_SCORE.findall(output)]
        score = scores[0] if len(scores) == 1 else None
        if measured["score"] != score:
            fail(f"{run['path']} glmark2 score differs from raw output")


def exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        fail(
            f"{label} keys are invalid "
            f"(missing={sorted(expected - actual)}, extra={sorted(actual - expected)})"
        )


def text(value: Any, label: str, maximum: int = 256) -> str:
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > maximum:
        fail(f"{label} must be a nonempty string no longer than {maximum} bytes")
    return value


def positive_int(value: Any, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        fail(f"{label} must be a positive integer")
    return value


def nonnegative_int(value: Any, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        fail(f"{label} must be a nonnegative integer")
    return value


def nonnegative_number(value: Any, label: str) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool) or value < 0:
        fail(f"{label} must be a finite nonnegative number")
    result = float(value)
    if result == float("inf") or result != result:
        fail(f"{label} must be a finite nonnegative number")
    return result


def validate_workload(value: Any, path: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{path} workload must be an object")
    exact_keys(
        value,
        {
            "id", "status", "frameCount", "p95FrameIntervalMs",
            "firstShaderCompileStallMs", "workerPeakCPUPercent", "workerPeakRSSBytes",
            "score", "failure",
        },
        f"{path} workload",
    )
    workload_id = text(value["id"], f"{path} workload id", 64)
    if workload_id not in WORKLOADS:
        fail(f"{path} workload id is unsupported: {workload_id}")
    if value["status"] not in ("PASS", "FAIL"):
        fail(f"{path} {workload_id} status must be PASS or FAIL")
    passed = value["status"] == "PASS"
    result: dict[str, Any] = {
        "id": workload_id,
        "status": value["status"],
        "frameCount": (
            positive_int(value["frameCount"], f"{path} {workload_id} frameCount")
            if passed
            else nonnegative_int(value["frameCount"], f"{path} {workload_id} frameCount")
        ),
        "score": value["score"],
        "failure": value["failure"],
    }
    for key in ("p95FrameIntervalMs", "firstShaderCompileStallMs", "workerPeakCPUPercent"):
        if value[key] is None and not passed:
            result[key] = None
        else:
            result[key] = nonnegative_number(value[key], f"{path} {workload_id} {key}")
    if value["workerPeakRSSBytes"] is None and not passed:
        result["workerPeakRSSBytes"] = None
    else:
        result["workerPeakRSSBytes"] = positive_int(
            value["workerPeakRSSBytes"], f"{path} {workload_id} workerPeakRSSBytes"
        )
    if workload_id == "glmark2" and passed:
        result["score"] = positive_int(value["score"], f"{path} glmark2 score")
    elif workload_id != "glmark2" and value["score"] is not None:
        fail(f"{path} {workload_id} score must be null")
    elif workload_id == "glmark2" and value["score"] is not None:
        result["score"] = positive_int(value["score"], f"{path} glmark2 score")
    if passed:
        if value["failure"] is not None:
            fail(f"{path} {workload_id} PASS must not include a failure")
    else:
        result["failure"] = text(value["failure"], f"{path} {workload_id} failure", 512)
    return result


def validate_run(value: dict[str, Any], expected_path: str) -> dict[str, Any]:
    exact_keys(
        value,
        {
            "schema", "path", "sourceCommit", "candidateID", "capturedAt",
            "hostHardwareModelIdentifier", "hostOperatingSystemBuild", "machineID",
            "guestDistribution", "guestVersion", "guestArchitecture", "desktopEnvironment",
            "widthPixels", "heightPixels", "cpuCount", "memoryMB", "rendererDevice",
            "glVersion", "apiCapabilities", "softwareRendererDetected", "workerArtifactSHA256",
            "workloads",
        },
        expected_path,
    )
    if value["schema"] != RUN_SCHEMA or value["path"] != expected_path:
        fail(f"{expected_path} schema or path identity is invalid")
    if not isinstance(value["sourceCommit"], str) or not COMMIT.fullmatch(value["sourceCommit"]):
        fail(f"{expected_path} sourceCommit is invalid")
    if not isinstance(value["workerArtifactSHA256"], str) or not SHA256.fullmatch(
        value["workerArtifactSHA256"]
    ):
        fail(f"{expected_path} workerArtifactSHA256 is invalid")
    if not isinstance(value["softwareRendererDetected"], bool):
        fail(f"{expected_path} softwareRendererDetected must be boolean")
    renderer = text(value["rendererDevice"], f"{expected_path} rendererDevice")
    lowered = renderer.lower()
    inferred_software = any(name in lowered for name in (
        "llvmpipe", "lavapipe", "softpipe", "swrast", "software rasterizer"))
    if inferred_software != value["softwareRendererDetected"]:
        fail(f"{expected_path} software-renderer classification disagrees with rendererDevice")
    capabilities = value["apiCapabilities"]
    if not isinstance(capabilities, list) or not capabilities:
        fail(f"{expected_path} apiCapabilities must be a nonempty list")
    validated_capabilities = [
        text(item, f"{expected_path} api capability", 128) for item in capabilities
    ]
    if validated_capabilities != sorted(set(validated_capabilities)):
        fail(f"{expected_path} apiCapabilities must be unique and sorted")
    workloads_value = value["workloads"]
    if not isinstance(workloads_value, list) or len(workloads_value) != len(WORKLOADS):
        fail(f"{expected_path} must contain exactly the required workloads")
    workloads = [validate_workload(item, expected_path) for item in workloads_value]
    identifiers = [item["id"] for item in workloads]
    if identifiers != list(WORKLOADS):
        fail(f"{expected_path} workloads must appear once in the required order")
    if value["softwareRendererDetected"] and any(item["status"] == "PASS" for item in workloads):
        fail(f"{expected_path} cannot pass a workload on a software renderer")
    result = dict(value)
    for key in (
        "candidateID", "capturedAt", "hostHardwareModelIdentifier", "hostOperatingSystemBuild",
        "machineID", "guestDistribution", "guestVersion", "guestArchitecture",
        "desktopEnvironment", "glVersion",
    ):
        result[key] = text(value[key], f"{expected_path} {key}")
    for key in ("widthPixels", "heightPixels", "cpuCount", "memoryMB"):
        result[key] = positive_int(value[key], f"{expected_path} {key}")
    result["rendererDevice"] = renderer
    result["apiCapabilities"] = validated_capabilities
    result["workloads"] = workloads
    return result


def verify_provenance(root: Path, path: str,
                      run: dict[str, Any], run_payload: bytes
                      ) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    inventory_name = f"{path}.inventory.json"
    collection_name = f"{path}.collection.json"
    plan_name = f"{path}.plan.json"
    inventory, inventory_payload = direct_json_payload(root, inventory_name)
    collection = direct_json(root, collection_name)
    plan, plan_payload = direct_json_payload(root, plan_name)
    exact_keys(collection, {
        "schema", "path", "planSHA256", "workerPID", "workerGeneration",
        "operationID", "inventorySHA256", "runSHA256", "visualEvidenceSHA256",
        "computeSHA256", "workloads",
    }, f"{path} collection")
    if collection["schema"] != COLLECTION_SCHEMA or collection["path"] != path:
        fail(f"{path} collection schema/path is invalid")
    for field in ("planSHA256", "inventorySHA256", "runSHA256",
                  "visualEvidenceSHA256"):
        if not isinstance(collection[field], str) or not SHA256.fullmatch(collection[field]):
            fail(f"{path} collection {field} is invalid")
    if hashlib.sha256(plan_payload).hexdigest() != collection["planSHA256"]:
        fail(f"{path} retained workload plan differs from collection digest")
    if plan.get("schema") != "dory.opengl-workload-plan@2" or plan.get("path") != path:
        fail(f"{path} retained workload plan schema/path is invalid")
    plan_metadata = plan.get("metadata")
    if not isinstance(plan_metadata, dict) or plan.get("workerPID") != collection["workerPID"] \
            or plan_metadata.get("workerGeneration") != collection["workerGeneration"] \
            or plan_metadata.get("operationID") != collection["operationID"]:
        fail(f"{path} retained workload plan disagrees with worker/operation identity")
    for field in ("candidateID", "machineID", "guestDistribution", "guestVersion",
                  "guestArchitecture", "desktopEnvironment", "widthPixels", "heightPixels",
                  "cpuCount", "memoryMB", "rendererDevice", "glVersion",
                  "apiCapabilities", "softwareRendererDetected"):
        if plan_metadata.get(field) != run[field]:
            fail(f"{path} retained workload plan {field} differs from run")
    plan_workloads = plan.get("workloads")
    if not isinstance(plan_workloads, list) or len(plan_workloads) != len(WORKLOADS):
        fail(f"{path} retained workload plan is incomplete")
    positive_int(collection["workerPID"], f"{path} workerPID")
    positive_int(collection["workerGeneration"], f"{path} workerGeneration")
    text(collection["operationID"], f"{path} operationID")
    for filename, payload, expected in (
        (f"{path}.json", run_payload, collection["runSHA256"]),
        (inventory_name, inventory_payload, collection["inventorySHA256"]),
    ):
        actual = hashlib.sha256(payload).hexdigest()
        if actual != expected:
            fail(f"{path} collection hash mismatch for {filename}")
    exact_keys(inventory, {
        "schema", "path", "guestDistribution", "guestVersion", "guestArchitecture",
        "kernelRelease", "desktopEnvironment", "sessionType", "compositorVersion",
        "rendererDevice", "glVersion", "mesaVersion", "apiCapabilities",
        "softwareRendererDetected", "probeDeviceName", "probeDriver", "probeApiVersion",
        "probeResultSHA256", "probeSurfaceFormat", "probeColorAtlasFormat",
        "probeStrategyFeatureFallback",
        "packages", "driverFiles", "glxinfoBasic", "vulkanSummary",
    }, f"{path} inventory")
    if inventory["schema"] != INVENTORY_SCHEMA or inventory["path"] != path:
        fail(f"{path} guest inventory schema/path is invalid")
    for field in ("guestDistribution", "guestVersion", "guestArchitecture",
                  "desktopEnvironment", "rendererDevice", "glVersion",
                  "apiCapabilities", "softwareRendererDetected"):
        if inventory[field] != run[field]:
            fail(f"{path} guest inventory {field} disagrees with the run")
    for field in ("kernelRelease", "compositorVersion", "mesaVersion",
                  "probeDeviceName", "probeDriver", "probeApiVersion", "glxinfoBasic"):
        text(inventory[field], f"{path} guest inventory {field}", 65536)
    if inventory["sessionType"] not in ("x11", "wayland"):
        fail(f"{path} guest inventory sessionType is invalid")
    if not isinstance(inventory["probeResultSHA256"], str) or not SHA256.fullmatch(
        inventory["probeResultSHA256"]
    ):
        fail(f"{path} probe result SHA-256 is invalid")
    for field in ("packages", "driverFiles"):
        values = inventory[field]
        if not isinstance(values, list) or not values or not all(
            isinstance(item, str) and item for item in values
        ) or values != sorted(set(values)):
            fail(f"{path} guest inventory {field} is invalid")
    if path == "zink-venus":
        if type(inventory["probeStrategyFeatureFallback"]) is not bool:
            fail("Zink inventory lacks optional feature negotiation status")
        if not isinstance(inventory["vulkanSummary"], str) or not inventory["vulkanSummary"]:
            fail("Zink inventory lacks Vulkan summary")
        if inventory["probeColorAtlasFormat"] not in ("bgra8-unorm", "rgba8-unorm"):
            fail("Zink inventory lacks a negotiated color atlas format")
    elif (inventory["vulkanSummary"] is not None
          or inventory["probeColorAtlasFormat"] is not None
          or inventory["probeStrategyFeatureFallback"] is not None):
        fail("VirGL2 inventory contains Vulkan-only fields")
    visual_directory = root / f"{path}.visual-evidence"
    try:
        visual = PIXEL_VERIFIER.verify(visual_directory)
    except (ValueError, OSError) as error:
        fail(f"{path} displayed-pixel proof failed independent replay: {error}")
    expected_probe = "vulkan-application" if path == "zink-venus" else "gl"
    if (visual.get("status") != "evidence-verified"
        or visual["probe"] != expected_probe or visual["machineID"] != run["machineID"]
        or visual["operationID"] != collection["operationID"]
        or visual["workerGeneration"] != collection["workerGeneration"]
        or visual["probeNonce"] != plan.get("expectedProbeNonce")):
        fail(f"{path} displayed-pixel proof belongs to another path or runner generation")
    if visual["gpuDisplayedPixelEvidenceSHA256"] != collection["visualEvidenceSHA256"]:
        fail(f"{path} displayed-pixel evidence digest differs from collection")
    probe, probe_payload = direct_json_payload(visual_directory, "gpu-probe.json")
    probe_digest = hashlib.sha256(probe_payload).hexdigest()
    if (probe_digest != inventory["probeResultSHA256"]
        or probe_digest != visual["probeSHA256"]):
        fail(f"{path} displayed-pixel probe differs from guest inventory")
    for inventory_field, probe_field in (("probeDeviceName", "deviceName"),
                                         ("probeDriver", "driver"),
                                         ("probeApiVersion", "apiVersion")):
        if inventory[inventory_field] != probe.get(probe_field):
            fail(f"{path} displayed-pixel {probe_field} differs from guest inventory")
    if path == "zink-venus":
        compute_name = f"{path}.compute.json"
        compute, compute_payload = direct_json_payload(root, compute_name)
        try:
            PIXEL_VERIFIER.PROBE_VALIDATOR.validate(compute, visual["probeNonce"])
        except ValueError as error:
            fail(f"Zink compute proof failed independent replay: {error}")
        if (compute.get("probe") != "compute"
            or compute.get("deviceName") != inventory["probeDeviceName"]
            or compute.get("driver") != inventory["probeDriver"]):
            fail("Zink compute proof belongs to another device or probe")
        if (not isinstance(collection["computeSHA256"], str)
            or not SHA256.fullmatch(collection["computeSHA256"])
            or hashlib.sha256(compute_payload).hexdigest()
                != collection["computeSHA256"]):
            fail("Zink compute proof digest differs from collection")
    elif collection["computeSHA256"] is not None:
        fail("VirGL2 collection cannot claim a Vulkan compute result")
    raw_workloads = collection["workloads"]
    if not isinstance(raw_workloads, list) or len(raw_workloads) != len(WORKLOADS):
        fail(f"{path} collection lacks the required workloads")
    raw_directory = root / f"{path}.raw"
    if not raw_directory.is_dir() or raw_directory.is_symlink():
        fail(f"{path} retained raw workload directory is missing or indirect")
    for index, raw in enumerate(raw_workloads):
        measured = run["workloads"][index]
        if not isinstance(raw, dict) or raw.get("id") != measured["id"]:
            fail(f"{path} raw workload order/identity differs")
        planned = plan_workloads[index]
        if not isinstance(planned, dict) or planned.get("id") != measured["id"] \
                or planned.get("command") != raw.get("command"):
            fail(f"{path} raw workload command differs from retained plan")
        if "reason" in raw:
            exact_keys(raw, {"id", "command", "reason"}, f"{path} raw workload")
            if measured["status"] != "FAIL":
                fail(f"{path} passing workload has no executed raw command")
            text(raw["reason"], f"{path} raw failure reason", 512)
            if planned["command"] is None \
                    and raw["reason"] != planned.get("unavailableReason"):
                fail(f"{path} unavailable workload reason differs from retained plan")
            continue
        exact_keys(raw, {
            "id", "command", "exitCode", "timedOut", "frameCount",
            "p99FrameIntervalMs", "stdoutSHA256", "stderrSHA256",
            "graphicsTraceSHA256", "workerSamplesSHA256",
        }, f"{path} raw workload")
        if not isinstance(raw["command"], list) or not raw["command"] \
                or not all(isinstance(argument, str) and argument for argument in raw["command"]):
            fail(f"{path} raw workload command is invalid")
        files: dict[str, bytes] = {}
        for field, suffix in (
            ("stdoutSHA256", ".stdout"),
            ("stderrSHA256", ".stderr"),
            ("graphicsTraceSHA256", ".graphics-trace.ndjson"),
            ("workerSamplesSHA256", ".worker-samples.ndjson"),
        ):
            files[field] = verify_raw_file(
                raw_directory, measured["id"] + suffix, raw[field],
                f"{path} {measured['id']} {field}",
            )
        if "frameCount" in raw and raw["frameCount"] != measured["frameCount"]:
            fail(f"{path} raw workload frame count differs")
        if raw.get("p99FrameIntervalMs") is not None:
            nonnegative_number(raw["p99FrameIntervalMs"], f"{path} p99 frame interval")
        if measured["status"] == "PASS":
            if measured["frameCount"] < 2:
                fail(f"{path} passing workload has fewer than two completed frames")
            if raw.get("exitCode") != 0 or raw.get("timedOut") is not False:
                fail(f"{path} passing workload did not exit successfully")
            if raw.get("frameCount") != measured["frameCount"]:
                fail(f"{path} passing workload frame count differs")
            p99 = nonnegative_number(raw.get("p99FrameIntervalMs"),
                                     f"{path} p99 frame interval")
            if p99 < measured["p95FrameIntervalMs"]:
                fail(f"{path} p99 frame interval is below p95")
        replay_workload(raw, measured, files, run, collection)
    return inventory, raw_workloads


def verify(root: Path) -> dict[str, Any]:
    if not root.is_dir() or root.is_symlink():
        fail("evidence root must be a direct directory")
    manifest = direct_json(root, "comparison.json")
    exact_keys(
        manifest,
        {"schema", "selectedPath", "compatibilityRequirement", "decisionRationale"},
        "comparison",
    )
    if manifest["schema"] != SCHEMA or manifest["selectedPath"] not in PATHS:
        fail("comparison schema or selectedPath is invalid")
    rationale = text(manifest["decisionRationale"], "decisionRationale", 1024)
    compatibility = manifest["compatibilityRequirement"]
    if compatibility is not None:
        compatibility = text(compatibility, "compatibilityRequirement", 512)

    run_artifacts = {
        path: direct_json_payload(root, f"{path}.json") for path in PATHS
    }
    runs = {
        path: validate_run(run_artifacts[path][0], path) for path in PATHS
    }
    provenance = {
        path: verify_provenance(root, path, runs[path], run_artifacts[path][1])
        for path in PATHS
    }
    inventories = {path: provenance[path][0] for path in PATHS}
    comparable_fields = (
        "sourceCommit", "candidateID", "hostHardwareModelIdentifier",
        "hostOperatingSystemBuild", "machineID", "guestDistribution", "guestVersion",
        "guestArchitecture", "desktopEnvironment", "widthPixels", "heightPixels", "cpuCount",
        "memoryMB", "workerArtifactSHA256",
    )
    for field in comparable_fields:
        if runs[PATHS[0]][field] != runs[PATHS[1]][field]:
            fail(f"renderer runs are not controlled: {field} differs")
    for field in ("kernelRelease", "sessionType", "compositorVersion", "mesaVersion",
                  "packages", "driverFiles"):
        if inventories[PATHS[0]][field] != inventories[PATHS[1]][field]:
            fail(f"renderer guest inventories are not controlled: {field} differs")

    selected = runs[manifest["selectedPath"]]
    zink = runs["zink-venus"]
    if all(workload["status"] == "PASS" for workload in zink["workloads"]):
        if inventories["zink-venus"]["probeStrategyFeatureFallback"]:
            fail("passing Zink run fell back from optional feature negotiation")
        missing_capabilities = sorted(
            ZINK_REQUIRED_CAPABILITIES - set(zink["apiCapabilities"])
        )
        if missing_capabilities:
            fail(f"passing Zink run is missing required capabilities: {missing_capabilities}")
    if selected["softwareRendererDetected"] or any(
        workload["status"] != "PASS" for workload in selected["workloads"]
    ):
        fail("selectedPath must pass every workload without software rendering")
    alternative = PATHS[1] if manifest["selectedPath"] == PATHS[0] else PATHS[0]
    alternative_failed = runs[alternative]["softwareRendererDetected"] or any(
        workload["status"] != "PASS" for workload in runs[alternative]["workloads"]
    )
    if compatibility is not None and alternative_failed:
        fail("a failing alternative cannot be retained for a compatibility requirement")
    if compatibility is None and not alternative_failed:
        fail("a passing alternative needs a named compatibility requirement or removal rationale")

    return {
        "schema": "dory.opengl-strategy-verification@1",
        "status": "PASS",
        "selectedPath": manifest["selectedPath"],
        "compatibilityRequirement": compatibility,
        "decisionRationale": rationale,
        "p99FrameIntervalsMs": {
            path: [raw.get("p99FrameIntervalMs") for raw in provenance[path][1]]
            for path in PATHS
        },
        "runs": runs,
    }


def markdown(summary: dict[str, Any]) -> str:
    lines = [
        "| Workload | Metric | Zink → Venus → MoltenVK | VirGL2 → ANGLE → Metal |",
        "|---|---|---:|---:|",
    ]
    runs = summary["runs"]
    for index, workload_id in enumerate(WORKLOADS):
        left = runs[PATHS[0]]["workloads"][index]
        right = runs[PATHS[1]]["workloads"][index]
        left_p99 = summary["p99FrameIntervalsMs"][PATHS[0]][index]
        right_p99 = summary["p99FrameIntervalsMs"][PATHS[1]][index]
        left_p99_text = "—" if left_p99 is None else f"{left_p99} ms"
        right_p99_text = "—" if right_p99 is None else f"{right_p99} ms"
        for label, key, suffix in (
            ("status", "status", ""),
            ("p95 frame", "p95FrameIntervalMs", " ms"),
            ("first shader stall", "firstShaderCompileStallMs", " ms"),
            ("worker peak CPU", "workerPeakCPUPercent", "%"),
            ("worker peak RSS", "workerPeakRSSBytes", " bytes"),
        ):
            left_value = "—" if left[key] is None else f"{left[key]}{suffix}"
            right_value = "—" if right[key] is None else f"{right[key]}{suffix}"
            lines.append(
                f"| {workload_id} | {label} | {left_value} | {right_value} |"
            )
        lines.append(f"| {workload_id} | p99 frame | {left_p99_text} | {right_p99_text} |")
    lines.extend((
        "",
        f"Selected default: `{summary['selectedPath']}`.",
        f"Decision: {summary['decisionRationale']}",
    ))
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--markdown", action="store_true")
    arguments = parser.parse_args()
    try:
        summary = verify(arguments.evidence)
    except EvidenceError as error:
        parser.error(str(error))
    if arguments.markdown:
        print(markdown(summary), end="")
    else:
        print(json.dumps(summary, sort_keys=True, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
