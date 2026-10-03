#!/usr/bin/env python3
"""Run one OpenGL strategy path and retain measured, auditable comparison input.

Run this on the macOS host. Each workload command may enter the selected Linux guest (for
example through a campaign-owned SSH wrapper), but the renderer PID and graphics trace belong
to the host. A successful command alone is never a passing measurement: the command must emit
an explicit first-shader event and the Dory runner must complete at least two Metal frames.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import re
import signal
import stat
import subprocess
import sys
import time
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
VERIFIER_PATH = Path(__file__).with_name("verify-opengl-strategy.py")
SPEC = importlib.util.spec_from_file_location("dory_opengl_strategy_verifier", VERIFIER_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load the OpenGL strategy verifier")
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)

PLAN_SCHEMA = "dory.opengl-workload-plan@2"
COLLECTION_SCHEMA = "dory.opengl-workload-collection@5"
INVENTORY_SCHEMA = "dory.opengl-guest-inventory@1"
VISUAL_FILES = (
    "gpu-probe.json", "gpu-probe-build-receipt.txt",
    "gpu-probe-ready-transport.json", "framebuffer.png",
    "display-capture-frame.json", "display-capture-frame.released",
    "window-capture.json", "graphics-trace.ndjson", "graphics-correlation.json",
    "pixel-oracle.json", "gpu-display-evidence.json",
)
METRIC_PREFIX = "DORY_METRIC "
GLMARK_SCORE = re.compile(r"^glmark2 Score:\s*([1-9][0-9]*)\s*$", re.MULTILINE)
MAX_PLAN_BYTES = 1_048_576
MAX_RAW_BYTES = 64 * 1_048_576


class CollectionError(ValueError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise CollectionError(message)


def direct_bytes(path: Path, maximum: int = MAX_RAW_BYTES,
                 allow_empty: bool = False) -> bytes:
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW), "rb") as source:
        before = os.fstat(source.fileno())
        require(stat.S_ISREG(before.st_mode) and before.st_size <= maximum
                and (allow_empty or before.st_size > 0),
                f"{path} must be a bounded direct regular file")
        data = source.read(maximum + 1)
        after = os.fstat(source.fileno())
        current = path.lstat()
        require(len(data) == before.st_size and len(data) <= maximum
                and (before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                == (after.st_size, after.st_mtime_ns, after.st_ctime_ns)
                and (before.st_dev, before.st_ino) == (current.st_dev, current.st_ino),
                f"{path} changed during collection")
        return data


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW), "rb") as source:
        before = os.fstat(source.fileno())
        require(stat.S_ISREG(before.st_mode), f"{path} must be a direct regular file")
        byte_count = 0
        for block in iter(lambda: source.read(1_048_576), b""):
            byte_count += len(block)
            digest.update(block)
        after = os.fstat(source.fileno())
        current = path.lstat()
        require(byte_count == before.st_size
                and (before.st_size, before.st_mtime_ns, before.st_ctime_ns)
                == (after.st_size, after.st_mtime_ns, after.st_ctime_ns)
                and (before.st_dev, before.st_ino) == (current.st_dev, current.st_ino),
                f"{path} changed during hashing")
    return digest.hexdigest()


def command_output(argv: list[str], cwd: Path = ROOT) -> str:
    result = subprocess.run(argv, cwd=cwd, text=True, capture_output=True, check=False,
                            timeout=30)
    require(result.returncode == 0, f"{argv[0]} failed: {result.stderr.strip()[:300]}")
    return result.stdout.strip()


def argv(value: Any, label: str) -> list[str]:
    require(isinstance(value, list) and 1 <= len(value) <= 32,
            f"{label} must be a nonempty argv array of at most 32 entries")
    require(all(isinstance(item, str) and item and len(item.encode()) <= 1024
                for item in value), f"{label} contains an invalid argument")
    return value


def load_plan(path: Path) -> dict[str, Any]:
    try:
        plan = json.loads(direct_bytes(path, MAX_PLAN_BYTES))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CollectionError(f"invalid plan: {error}") from error
    require(isinstance(plan, dict) and set(plan) == {
        "schema", "path", "metadata", "workerPID", "workerExecutable", "graphicsTrace",
        "inventoryCommand", "visualEvidenceDirectory", "computeResultFile",
        "expectedProbeNonce", "workloads",
    }, "plan has invalid fields")
    require(plan["schema"] == PLAN_SCHEMA and plan["path"] in VERIFIER.PATHS,
            "plan schema/path is invalid")
    require(type(plan["workerPID"]) is int and plan["workerPID"] > 0,
            "workerPID must be a positive integer")
    for field in ("workerExecutable", "graphicsTrace"):
        require(isinstance(plan[field], str) and Path(plan[field]).is_absolute(),
                f"{field} must be an absolute path")
    require(isinstance(plan["visualEvidenceDirectory"], str)
            and Path(plan["visualEvidenceDirectory"]).is_absolute(),
            "visualEvidenceDirectory must be an absolute path")
    require((plan["path"] == "virgl2-angle" and plan["computeResultFile"] is None)
            or (plan["path"] == "zink-venus"
                and isinstance(plan["computeResultFile"], str)
                and Path(plan["computeResultFile"]).is_absolute()),
            "computeResultFile must be absolute for Zink and null for VirGL2")
    VERIFIER.text(plan["expectedProbeNonce"], "expectedProbeNonce")
    metadata = plan["metadata"]
    require(isinstance(metadata, dict) and set(metadata) == {
        "candidateID", "machineID", "guestDistribution", "guestVersion",
        "guestArchitecture", "desktopEnvironment", "widthPixels", "heightPixels",
        "cpuCount", "memoryMB", "rendererDevice", "glVersion", "apiCapabilities",
        "softwareRendererDetected", "workerGeneration", "operationID",
    }, "metadata has invalid fields")
    for field in ("candidateID", "machineID", "guestDistribution", "guestVersion",
                  "guestArchitecture", "desktopEnvironment", "rendererDevice", "glVersion",
                  "operationID"):
        VERIFIER.text(metadata[field], f"metadata {field}")
    for field in ("widthPixels", "heightPixels", "cpuCount", "memoryMB",
                  "workerGeneration"):
        VERIFIER.positive_int(metadata[field], f"metadata {field}")
    require(isinstance(metadata["softwareRendererDetected"], bool),
            "softwareRendererDetected must be boolean")
    capabilities = metadata["apiCapabilities"]
    require(isinstance(capabilities, list) and bool(capabilities)
            and all(isinstance(item, str) and 0 < len(item) <= 128 for item in capabilities)
            and capabilities == sorted(set(capabilities)),
            "apiCapabilities must be a sorted unique nonempty list")
    inferred_software = any(name in metadata["rendererDevice"].lower() for name in (
        "llvmpipe", "lavapipe", "softpipe", "swrast", "software rasterizer"))
    require(inferred_software == metadata["softwareRendererDetected"],
            "software renderer classification disagrees with rendererDevice")
    argv(plan["inventoryCommand"], "inventoryCommand")
    workloads = plan["workloads"]
    require(isinstance(workloads, list) and len(workloads) == len(VERIFIER.WORKLOADS),
            "plan must contain every required workload")
    for index, workload in enumerate(workloads):
        require(isinstance(workload, dict) and set(workload) == {
            "id", "command", "timeoutSeconds", "unavailableReason",
        }, f"workload {index} has invalid fields")
        require(workload["id"] == VERIFIER.WORKLOADS[index],
                "workloads must appear in the required order")
        if workload["command"] is None:
            require(isinstance(workload["unavailableReason"], str)
                    and 0 < len(workload["unavailableReason"]) <= 512,
                    f"{workload['id']} needs an explicit unavailable reason")
        else:
            argv(workload["command"], f"{workload['id']} command")
            require(workload["unavailableReason"] is None,
                    f"{workload['id']} cannot be both runnable and unavailable")
        require(type(workload["timeoutSeconds"]) is int
                and 10 <= workload["timeoutSeconds"] <= 3600,
                f"{workload['id']} timeoutSeconds must be 10..3600")
    return plan


def validate_inventory(inventory: Any, plan: dict[str, Any]) -> dict[str, Any]:
    require(isinstance(inventory, dict) and set(inventory) == {
        "schema", "path", "guestDistribution", "guestVersion", "guestArchitecture",
        "kernelRelease", "desktopEnvironment", "sessionType", "compositorVersion",
        "rendererDevice", "glVersion", "mesaVersion", "apiCapabilities",
        "softwareRendererDetected", "probeDeviceName", "probeDriver", "probeApiVersion",
        "probeResultSHA256", "probeSurfaceFormat", "probeColorAtlasFormat",
        "probeStrategyFeatureFallback",
        "packages", "driverFiles",
        "glxinfoBasic", "vulkanSummary",
    }, "guest inventory has invalid fields")
    require(inventory["schema"] == INVENTORY_SCHEMA and inventory["path"] == plan["path"],
            "guest inventory schema/path does not match the plan")
    for field in ("guestDistribution", "guestVersion", "guestArchitecture",
                  "desktopEnvironment", "rendererDevice", "glVersion",
                  "apiCapabilities", "softwareRendererDetected"):
        require(inventory[field] == plan["metadata"][field],
                f"guest inventory {field} disagrees with plan metadata")
    for field in ("kernelRelease", "compositorVersion", "mesaVersion",
                  "probeDeviceName", "probeDriver", "probeApiVersion", "glxinfoBasic"):
        require(isinstance(inventory[field], str) and bool(inventory[field]),
                f"guest inventory {field} is empty")
    require(inventory["sessionType"] in ("wayland", "x11"),
            "guest inventory sessionType is invalid")
    require(isinstance(inventory["probeResultSHA256"], str)
            and re.fullmatch(r"[0-9a-f]{64}", inventory["probeResultSHA256"]) is not None,
            "guest inventory probe result hash is invalid")
    require(inventory["probeSurfaceFormat"] is None
            or isinstance(inventory["probeSurfaceFormat"], str),
            "guest inventory probeSurfaceFormat is invalid")
    require((inventory["probeColorAtlasFormat"] is None and plan["path"] == "virgl2-angle")
            or (isinstance(inventory["probeColorAtlasFormat"], str)
                and inventory["probeColorAtlasFormat"] in ("bgra8-unorm", "rgba8-unorm")
                and plan["path"] == "zink-venus"),
            "guest inventory color-atlas format is invalid")
    require((inventory["probeStrategyFeatureFallback"] is None
             and plan["path"] == "virgl2-angle")
            or (type(inventory["probeStrategyFeatureFallback"]) is bool
                and plan["path"] == "zink-venus"),
            "guest inventory strategy feature fallback is invalid")
    for field in ("packages", "driverFiles"):
        value = inventory[field]
        require(isinstance(value, list) and bool(value)
                and all(isinstance(item, str) and item for item in value)
                and value == sorted(set(value)),
                f"guest inventory {field} must be a sorted unique nonempty list")
    require((inventory["vulkanSummary"] is None and plan["path"] == "virgl2-angle")
            or (isinstance(inventory["vulkanSummary"], str)
                and bool(inventory["vulkanSummary"]) and plan["path"] == "zink-venus"),
            "guest inventory Vulkan summary does not match the strategy path")
    return inventory


def collect_inventory(plan: dict[str, Any], output: Path) -> tuple[dict[str, Any], str]:
    stdout_path = output / "inventory.stdout.json"
    stderr_path = output / "inventory.stderr"
    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        process = subprocess.Popen(plan["inventoryCommand"], stdout=stdout,
                                   stderr=stderr, start_new_session=True)
        try:
            exit_code = process.wait(timeout=120)
        except subprocess.TimeoutExpired as error:
            terminate_process_group(process)
            raise CollectionError("guest inventory command timed out") from error
        terminate_process_group(process)
    require(stdout_path.stat().st_size <= MAX_PLAN_BYTES
            and stderr_path.stat().st_size <= MAX_PLAN_BYTES,
            "guest inventory command output exceeded 1 MiB")
    require(exit_code == 0,
            f"guest inventory command exited {exit_code}: "
            f"{stderr_path.read_text(encoding='utf-8', errors='replace')[:300]}")
    try:
        inventory = json.loads(direct_bytes(stdout_path, MAX_PLAN_BYTES))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CollectionError(f"guest inventory is invalid JSON: {error}") from error
    return validate_inventory(inventory, plan), sha256(stdout_path)


def terminate_process_group(process: subprocess.Popen[bytes]) -> None:
    """Retire a campaign-owned wrapper and any children in its isolated session."""
    leader_not_reaped = process.returncode is None
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    if leader_not_reaped:
        # Keep the leader's PID reserved until the final group signal; reaping it first
        # would permit PID/group-ID reuse while a stubborn grandchild is still alive.
        time.sleep(0.1)
    # The wrapper can exit on SIGTERM while a grandchild ignores it. Reap the entire
    # isolated group even if the direct child has already terminated.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=5)


def collect_visual_proof(plan: dict[str, Any], inventory: dict[str, Any],
                         output: Path) -> tuple[str, str | None]:
    source = Path(plan["visualEvidenceDirectory"])
    require(source.is_dir() and not source.is_symlink(),
            "visual evidence must be a direct directory")
    retained = output / "visual-evidence"
    retained.mkdir()
    for name in VISUAL_FILES:
        (retained / name).write_bytes(direct_bytes(source / name))
    try:
        proof = VERIFIER.PIXEL_VERIFIER.verify(retained, plan["expectedProbeNonce"])
    except (ValueError, OSError) as error:
        raise CollectionError(f"displayed-pixel proof failed: {error}") from error
    expected_probe = "vulkan-application" if plan["path"] == "zink-venus" else "gl"
    metadata = plan["metadata"]
    require(proof.get("status") == "evidence-verified"
            and proof["probe"] == expected_probe
            and proof["machineID"] == metadata["machineID"]
            and proof["operationID"] == metadata["operationID"]
            and proof["workerGeneration"] == metadata["workerGeneration"]
            and proof["probeNonce"] == plan["expectedProbeNonce"],
            "displayed-pixel proof belongs to another path, machine, operation or worker")
    probe_path = retained / "gpu-probe.json"
    require(sha256(probe_path) == inventory["probeResultSHA256"],
            "guest inventory and displayed-pixel proof use different probe results")
    probe = json.loads(direct_bytes(probe_path, MAX_PLAN_BYTES))
    require(probe.get("deviceName") == inventory["probeDeviceName"]
            and probe.get("driver") == inventory["probeDriver"]
            and probe.get("apiVersion") == inventory["probeApiVersion"],
            "displayed-pixel probe driver identity differs from guest inventory")
    compute_digest: str | None = None
    if plan["path"] == "zink-venus":
        compute_path = output / "compute-result.json"
        compute_path.write_bytes(direct_bytes(Path(plan["computeResultFile"]), MAX_PLAN_BYTES))
        try:
            compute = json.loads(direct_bytes(compute_path, MAX_PLAN_BYTES))
            VERIFIER.PIXEL_VERIFIER.PROBE_VALIDATOR.validate(
                compute, plan["expectedProbeNonce"])
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
            raise CollectionError(f"Venus compute proof failed: {error}") from error
        require(compute.get("probe") == "compute"
                and compute.get("deviceName") == inventory["probeDeviceName"]
                and compute.get("driver") == inventory["probeDriver"],
                "Venus compute proof belongs to another device or probe")
        compute_digest = sha256(compute_path)
    return sha256(retained / "gpu-display-evidence.json"), compute_digest


def percentile(values: list[float], percent: float) -> float:
    require(bool(values) and 0 < percent <= 100, "percentile input is empty or invalid")
    ordered = sorted(values)
    return ordered[max(0, math.ceil(percent / 100 * len(ordered)) - 1)]


def parse_trace(raw: bytes, machine_id: str, operation_id: str, worker_generation: int,
                width: int, height: int) -> list[int]:
    require(not raw or raw.endswith(b"\n"), "graphics trace ended with a partial event")
    timestamps: list[int] = []
    seen_completions: set[int] = set()
    accepted_frames: dict[tuple[int, int, int, int, int], int] = {}
    completed_frames: set[tuple[int, int, int, int, int]] = set()
    for line in raw.splitlines():
        try:
            event = json.loads(line)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise CollectionError(f"graphics trace contains malformed JSON: {error}") from error
        require(isinstance(event, dict), "graphics trace event is not an object")
        if event.get("stage") not in ("hostSubmissionAccepted", "metalPresentationCompleted"):
            continue
        context = event.get("context")
        if not isinstance(context, dict) or context.get("machineID") != machine_id \
                or context.get("operationID") != operation_id:
            continue
        if context.get("workerGeneration") != worker_generation:
            continue
        if event.get("scanoutID") != 0 or event.get("width") != width \
                or event.get("height") != height:
            continue
        frame_fields = (
            event.get("resourceID"), event.get("displayResourceGeneration"),
            event.get("rendererResourceGeneration"), event.get("deviceGeneration"),
            event.get("frameSequence"),
        )
        require(all(type(item) is int and item > 0 for item in frame_fields),
                "accelerated frame has incomplete resource/generation identity")
        frame = tuple(frame_fields)
        timestamp = event.get("monotonicNanoseconds")
        require(type(timestamp) is int and timestamp > 0,
                "accelerated frame has no monotonic timestamp")
        if event["stage"] == "hostSubmissionAccepted":
            require(frame not in accepted_frames, "duplicate host submission identity")
            accepted_frames[frame] = timestamp
            continue
        require(frame not in completed_frames, "duplicate Metal completion for one frame")
        require(frame in accepted_frames,
                "Metal completion lacks an earlier accepted host submission")
        require(timestamp > accepted_frames[frame],
                "Metal completion does not follow its accepted host submission")
        completed_frames.add(frame)
        completion = event.get("metalCommandBufferCompletionID")
        require(type(completion) is int and completion > 0 and completion not in seen_completions,
                "duplicate or missing Metal completion identity")
        require(not timestamps or timestamp > timestamps[-1],
                "Metal completion timestamps are not strictly increasing")
        seen_completions.add(completion)
        timestamps.append(timestamp)
    return timestamps


def shader_stall(raw_output: str) -> float | None:
    durations: list[int] = []
    for line in raw_output.splitlines():
        if not line.startswith(METRIC_PREFIX):
            continue
        try:
            event = json.loads(line[len(METRIC_PREFIX):])
        except json.JSONDecodeError as error:
            raise CollectionError(f"malformed DORY_METRIC event: {error}") from error
        require(isinstance(event, dict) and set(event) == {"kind", "durationNanoseconds"},
                "DORY_METRIC event has invalid fields")
        require(event["kind"] == "shaderCompile"
                and type(event["durationNanoseconds"]) is int
                and event["durationNanoseconds"] >= 0,
                "DORY_METRIC is not a valid shaderCompile duration")
        durations.append(event["durationNanoseconds"])
    return durations[0] / 1_000_000 if durations else None


def sample_worker(pid: int) -> tuple[float, int] | None:
    try:
        result = subprocess.run(
            ["ps", "-p", str(pid), "-o", "%cpu=", "-o", "rss="],
            capture_output=True, text=True, check=False, timeout=5,
            env={**os.environ, "LC_ALL": "C"},
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    fields = result.stdout.split()
    if len(fields) != 2:
        return None
    try:
        cpu, rss_kib = float(fields[0]), int(fields[1])
    except ValueError:
        return None
    if not math.isfinite(cpu) or cpu < 0 or rss_kib <= 0:
        return None
    return cpu, rss_kib * 1024


def open_trace(path: Path) -> Any:
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    source = os.fdopen(descriptor, "rb")
    if not stat.S_ISREG(os.fstat(descriptor).st_mode):
        source.close()
        raise CollectionError("graphics trace must be a direct regular file")
    return source


def appended_trace(source: Any, path: Path, start_offset: int) -> bytes:
    original = os.fstat(source.fileno())
    current = path.lstat()
    require(stat.S_ISREG(current.st_mode) and not path.is_symlink()
            and (current.st_dev, current.st_ino) == (original.st_dev, original.st_ino),
            "graphics trace was replaced during collection")
    size = original.st_size
    require(size >= start_offset and size - start_offset <= MAX_RAW_BYTES,
            "graphics trace was truncated or exceeded the collection limit")
    source.seek(start_offset)
    raw = source.read(size - start_offset)
    require(len(raw) == size - start_offset, "graphics trace changed during collection")
    return raw


def failed_workload(identifier: str, reason: str) -> dict[str, Any]:
    return {
        "id": identifier, "status": "FAIL", "frameCount": 0,
        "p95FrameIntervalMs": None, "firstShaderCompileStallMs": None,
        "workerPeakCPUPercent": None, "workerPeakRSSBytes": None,
        "score": None, "failure": reason[:512],
    }


def collect_workload(spec: dict[str, Any], plan: dict[str, Any], output: Path,
                     worker_generation: int) -> tuple[dict[str, Any], dict[str, Any]]:
    identifier = spec["id"]
    if spec["command"] is None:
        return failed_workload(identifier, spec["unavailableReason"]), {
            "id": identifier, "command": None, "reason": spec["unavailableReason"]}
    trace_path = Path(plan["graphicsTrace"])
    with open_trace(trace_path) as trace_source:
        return _collect_workload_with_trace(
            spec, plan, output, worker_generation, trace_source, trace_path
        )


def _collect_workload_with_trace(
    spec: dict[str, Any], plan: dict[str, Any], output: Path,
    worker_generation: int, trace_source: Any, trace_path: Path,
) -> tuple[dict[str, Any], dict[str, Any]]:
    identifier = spec["id"]
    start_offset = os.fstat(trace_source.fileno()).st_size
    stdout_path = output / f"{identifier}.stdout"
    stderr_path = output / f"{identifier}.stderr"
    command = spec["command"]
    peak_cpu: float | None = None
    peak_rss: int | None = None
    worker_samples: list[dict[str, int | float]] = []
    timed_out = False
    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        try:
            process = subprocess.Popen(command, stdout=stdout, stderr=stderr,
                                       start_new_session=True, env=os.environ.copy())
        except OSError as error:
            reason = f"workload command could not start: {error}"
            return failed_workload(identifier, reason), {
                "id": identifier, "command": command, "reason": reason[:512],
            }
        deadline = time.monotonic() + spec["timeoutSeconds"]
        while process.poll() is None:
            sample = sample_worker(plan["workerPID"])
            if sample is not None:
                timestamp = time.monotonic_ns()
                if worker_samples:
                    timestamp = max(
                        timestamp, int(worker_samples[-1]["monotonicNanoseconds"]) + 1
                    )
                worker_samples.append({
                    "monotonicNanoseconds": timestamp,
                    "workerPID": plan["workerPID"],
                    "cpuPercent": sample[0],
                    "rssBytes": sample[1],
                })
                peak_cpu = max(peak_cpu or 0, sample[0])
                peak_rss = max(peak_rss or 0, sample[1])
            if time.monotonic() >= deadline:
                timed_out = True
                terminate_process_group(process)
                break
            time.sleep(0.2)
        exit_code = process.wait()
        if not timed_out:
            terminate_process_group(process)
    trace_raw = appended_trace(trace_source, trace_path, start_offset)
    trace_output = output / f"{identifier}.graphics-trace.ndjson"
    trace_output.write_bytes(trace_raw)
    samples_output = output / f"{identifier}.worker-samples.ndjson"
    samples_output.write_bytes(b"".join(
        json.dumps(sample, sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"
        for sample in worker_samples
    ))
    stdout_raw = direct_bytes(stdout_path, allow_empty=True)
    stderr_raw = direct_bytes(stderr_path, allow_empty=True)
    require(len(stdout_raw) <= MAX_RAW_BYTES and len(stderr_raw) <= MAX_RAW_BYTES,
            f"{identifier} output exceeded collection limit")
    output_text = (stdout_raw + b"\n" + stderr_raw).decode("utf-8", errors="replace")
    timestamps = parse_trace(
        trace_raw, plan["metadata"]["machineID"], plan["metadata"]["operationID"],
        worker_generation,
        plan["metadata"]["widthPixels"], plan["metadata"]["heightPixels"],
    )
    intervals = [(right - left) / 1_000_000 for left, right in zip(timestamps, timestamps[1:])]
    stall = shader_stall(output_text)
    scores = [int(value) for value in GLMARK_SCORE.findall(output_text)]
    problems: list[str] = []
    if timed_out:
        problems.append("workload timed out")
    elif exit_code != 0:
        problems.append(f"workload exited {exit_code}")
    if len(intervals) < 1:
        problems.append("fewer than two authenticated Metal-completed frames")
    if stall is None:
        problems.append("missing first-shader compile telemetry")
    if peak_cpu is None or peak_rss is None:
        problems.append("renderer worker CPU/RSS could not be sampled")
    if identifier == "glmark2" and len(scores) != 1:
        problems.append("missing or ambiguous glmark2 score")
    if plan["metadata"]["softwareRendererDetected"]:
        problems.append("software renderer detected")
    passed = not problems
    measurement: dict[str, Any] = {
        "id": identifier,
        "status": "PASS" if passed else "FAIL",
        "frameCount": len(timestamps),
        "p95FrameIntervalMs": percentile(intervals, 95) if intervals else None,
        "firstShaderCompileStallMs": stall,
        "workerPeakCPUPercent": peak_cpu,
        "workerPeakRSSBytes": peak_rss,
        "score": scores[0] if identifier == "glmark2" and len(scores) == 1 else None,
        "failure": "; ".join(problems)[:512] if problems else None,
    }
    raw = {
        "id": identifier, "command": command, "exitCode": exit_code,
        "timedOut": timed_out, "frameCount": len(timestamps),
        "p99FrameIntervalMs": percentile(intervals, 99) if intervals else None,
        # Empty output is still a retained file with a definite digest. A comparison
        # verifier must never accept digest-shaped strings without replaying these bytes.
        "stdoutSHA256": sha256(stdout_path),
        "stderrSHA256": sha256(stderr_path),
        "graphicsTraceSHA256": sha256(trace_output),
        "workerSamplesSHA256": sha256(samples_output),
    }
    return measurement, raw


def collect(plan_path: Path, output: Path) -> dict[str, Any]:
    require(platform.system() == "Darwin", "collector must run on the macOS renderer host")
    plan = load_plan(plan_path)
    require(not output.exists() and not output.is_symlink(),
            "output directory must not already exist")
    worker = Path(plan["workerExecutable"])
    worker_digest = sha256(worker)
    trace = Path(plan["graphicsTrace"])
    trace_metadata = trace.lstat()
    require(stat.S_ISREG(trace_metadata.st_mode) and not trace.is_symlink(),
            "graphicsTrace must be a direct regular file")
    commit = command_output(["git", "rev-parse", "HEAD"])
    require(VERIFIER.COMMIT.fullmatch(commit) is not None, "source commit is invalid")
    require(not command_output(["git", "status", "--porcelain"]),
            "source tree must be clean before collecting release evidence")
    model = command_output(["sysctl", "-n", "hw.model"])
    build = command_output(["sw_vers", "-buildVersion"])
    worker_generation = plan["metadata"].get("workerGeneration")
    # The generation is passed separately from metadata because comparison-run @1 has no slot
    # for it. Require an explicit positive value rather than matching another VM's trace.
    require(type(worker_generation) is int and worker_generation > 0,
            "metadata.workerGeneration must be a positive integer")
    output.mkdir(parents=True, exist_ok=False)
    (output / "plan.json").write_bytes(direct_bytes(plan_path, MAX_PLAN_BYTES))
    raw_directory = output / "raw"
    raw_directory.mkdir()
    inventory, inventory_digest = collect_inventory(plan, output)
    visual_digest, compute_digest = collect_visual_proof(plan, inventory, output)
    measurements: list[dict[str, Any]] = []
    raw_workloads: list[dict[str, Any]] = []
    for spec in plan["workloads"]:
        measurement, raw = collect_workload(spec, plan, raw_directory, worker_generation)
        measurements.append(measurement)
        raw_workloads.append(raw)
    metadata = dict(plan["metadata"])
    metadata.pop("workerGeneration")
    metadata.pop("operationID")
    run = {
        "schema": VERIFIER.RUN_SCHEMA, "path": plan["path"],
        "sourceCommit": commit, "capturedAt": datetime.now(timezone.utc)
            .isoformat(timespec="seconds").replace("+00:00", "Z"),
        "hostHardwareModelIdentifier": model, "hostOperatingSystemBuild": build,
        "workerArtifactSHA256": worker_digest, **metadata, "workloads": measurements,
    }
    VERIFIER.validate_run(run, plan["path"])
    raw = {
        "schema": COLLECTION_SCHEMA, "path": plan["path"],
        "planSHA256": sha256(plan_path), "workerPID": plan["workerPID"],
        "workerGeneration": worker_generation, "inventorySHA256": inventory_digest,
        "visualEvidenceSHA256": visual_digest, "computeSHA256": compute_digest,
        "workloads": raw_workloads,
        "operationID": plan["metadata"]["operationID"],
    }
    run_path = output / f"{plan['path']}.json"
    run_path.write_text(json.dumps(run, sort_keys=True, indent=2) + "\n")
    raw["runSHA256"] = sha256(run_path)
    (output / "collection.json").write_text(json.dumps(raw, sort_keys=True, indent=2) + "\n")
    return run


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        run = collect(arguments.plan, arguments.output)
    except (CollectionError, VERIFIER.EvidenceError, OSError, subprocess.TimeoutExpired) as error:
        print(f"OpenGL strategy collection failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"path": run["path"], "output": str(arguments.output)}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
