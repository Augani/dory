#!/usr/bin/env python3
"""Verify and summarize one controlled Dory OpenGL strategy comparison."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import stat
from typing import Any


SCHEMA = "dory.opengl-strategy-comparison@1"
RUN_SCHEMA = "dory.opengl-strategy-run@1"
PATHS = ("zink-venus", "virgl2-angle")
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


class EvidenceError(ValueError):
    pass


def fail(message: str) -> None:
    raise EvidenceError(message)


def direct_json(root: Path, name: str) -> dict[str, Any]:
    path = root / name
    try:
        metadata = path.lstat()
    except OSError as error:
        fail(f"{name} is missing: {error}")
    if path.is_symlink() or not stat.S_ISREG(metadata.st_mode) or metadata.st_size <= 0:
        fail(f"{name} must be a nonempty direct regular file")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"{name} is invalid JSON: {error}")
    if not isinstance(value, dict):
        fail(f"{name} must contain one JSON object")
    return value


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
    inferred_software = any(name in lowered for name in ("llvmpipe", "lavapipe", "software rasterizer"))
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

    runs = {
        path: validate_run(direct_json(root, f"{path}.json"), path)
        for path in PATHS
    }
    comparable_fields = (
        "sourceCommit", "candidateID", "hostHardwareModelIdentifier",
        "hostOperatingSystemBuild", "machineID", "guestDistribution", "guestVersion",
        "guestArchitecture", "desktopEnvironment", "widthPixels", "heightPixels", "cpuCount",
        "memoryMB", "workerArtifactSHA256",
    )
    for field in comparable_fields:
        if runs[PATHS[0]][field] != runs[PATHS[1]][field]:
            fail(f"renderer runs are not controlled: {field} differs")

    selected = runs[manifest["selectedPath"]]
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
