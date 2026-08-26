#!/usr/bin/env python3
"""Validate canonical Linux VM performance evidence and its exact budget set.

This is a structural pre-signing gate. It rejects ambiguous JSON, authority drift, unsafe bundle
paths, provisional qualification, and graphics/fallback misclassification. It does not measure a
VM, verify the detached bundle signature, or invent performance budgets.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import math
import os
import pathlib
import re
import sys
import uuid
from typing import Any


EVIDENCE_KIND = "dev.dory.linux-vm-performance-evidence"
BUDGET_SET_KIND = "dev.dory.linux-vm-performance-budget-set"
SCHEMA_VERSION = 1
MAX_JSON_BYTES = 2 * 1024 * 1024
MAX_BUDGETS = 4096
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
IDENTIFIER_PATTERN = re.compile(r"[a-z][a-z0-9.-]{0,127}")
VERSION_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
UTC_PATTERN = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")


class EvidenceError(ValueError):
    pass


def fail(message: str) -> None:
    raise EvidenceError(message)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def no_duplicate_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        require(key not in result, f"JSON object repeats key {key!r}")
        result[key] = value
    return result


def reject_nonfinite_json(value: str) -> None:
    fail(f"JSON contains non-finite number {value!r}")


def canonical_json(value: Any) -> bytes:
    try:
        encoded = json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
    except (TypeError, ValueError, RecursionError) as error:
        fail(f"value cannot be encoded as canonical JSON: {error}")
    return (encoded + "\n").encode("utf-8")


def direct_file(path: pathlib.Path, label: str) -> pathlib.Path:
    logical = pathlib.Path(os.path.abspath(path))
    require(
        logical.is_file() and not logical.is_symlink(),
        f"{label} is missing or indirect",
    )
    require(logical.resolve() == logical, f"{label} has an indirect ancestor")
    size = logical.stat().st_size
    require(0 < size <= MAX_JSON_BYTES, f"{label} size is invalid")
    return logical


def decode_canonical_object(raw: bytes, label: str) -> dict[str, Any]:
    """Decode one bounded canonical JSON object supplied by a trusted file reader."""

    require(0 < len(raw) <= MAX_JSON_BYTES, f"{label} size is invalid")
    try:
        value = json.loads(
            raw,
            object_pairs_hook=no_duplicate_object,
            parse_constant=reject_nonfinite_json,
        )
    except EvidenceError:
        raise
    except (
        UnicodeDecodeError,
        json.JSONDecodeError,
        ValueError,
        RecursionError,
    ) as error:
        fail(f"cannot decode {label}: {error}")
    require(isinstance(value, dict), f"{label} root must be an object")
    require(
        raw == canonical_json(value),
        f"{label} must be canonical JSON with one final newline",
    )
    return value


def load_canonical_object(
    path: pathlib.Path, label: str
) -> tuple[dict[str, Any], bytes]:
    source = direct_file(path, label)
    raw = source.read_bytes()
    value = decode_canonical_object(raw, label)
    return value, raw


def exact_object(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{label} must be an object")
    actual = set(value)
    if actual != expected:
        fail(
            f"{label} keys differ "
            f"(missing={sorted(expected - actual)}, extra={sorted(actual - expected)})"
        )
    return value


def positive_integer(value: Any, label: str) -> int:
    require(type(value) is int and value > 0, f"{label} must be a positive integer")
    return value


def canonical_string(value: Any, label: str, maximum_bytes: int = 4096) -> str:
    require(isinstance(value, str), f"{label} must be a string")
    require(
        value and value == value.strip(),
        f"{label} must be a non-empty canonical string",
    )
    require(len(value.encode("utf-8")) <= maximum_bytes, f"{label} is too long")
    require(
        not any(ord(character) < 0x20 or ord(character) == 0x7F for character in value),
        f"{label} contains a control character",
    )
    return value


def canonical_identifier(value: Any, label: str) -> str:
    text = canonical_string(value, label, 128)
    require(
        IDENTIFIER_PATTERN.fullmatch(text) is not None,
        f"{label} is not a canonical identifier",
    )
    require(
        ".." not in text and not text.endswith((".", "-")), f"{label} is not canonical"
    )
    return text


def canonical_version(value: Any, label: str) -> str:
    text = canonical_string(value, label, 128)
    require(
        VERSION_PATTERN.fullmatch(text) is not None,
        f"{label} is not a canonical version",
    )
    return text


def sha256_identity(value: Any, label: str) -> str:
    require(
        isinstance(value, str) and SHA256_PATTERN.fullmatch(value) is not None,
        f"{label} must be a lowercase SHA-256",
    )
    require(value != "0" * 64, f"{label} must not be the all-zero identity")
    return value


def nullable_sha256(value: Any, label: str) -> str | None:
    if value is None:
        return None
    return sha256_identity(value, label)


def canonical_uuid(value: Any, label: str) -> str:
    text = canonical_string(value, label, 36)
    try:
        parsed = uuid.UUID(text)
    except ValueError:
        fail(f"{label} must be a canonical UUID")
    require(
        parsed.int != 0 and str(parsed) == text,
        f"{label} must be a non-zero canonical UUID",
    )
    return text


def canonical_utc(value: Any, label: str) -> str:
    text = canonical_string(value, label, 20)
    require(UTC_PATTERN.fullmatch(text) is not None, f"{label} must be canonical UTC")
    try:
        datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        fail(f"{label} is not a real UTC timestamp")
    return text


def relative_bundle_path(
    value: Any,
    label: str,
    *,
    prefix: str,
    suffix: str,
) -> str:
    text = canonical_string(value, label, 512)
    require("\\" not in text, f"{label} must use POSIX separators")
    path = pathlib.PurePosixPath(text)
    require(
        not path.is_absolute() and text == path.as_posix(),
        f"{label} must be a canonical relative POSIX path",
    )
    require(
        all(part not in {"", ".", ".."} for part in path.parts),
        f"{label} contains a forbidden path component",
    )
    require(path.parts and path.parts[0] == prefix, f"{label} must be inside {prefix}/")
    require(text.endswith(suffix), f"{label} must end in {suffix}")
    return text


def finite_number(value: Any, label: str) -> int | float:
    require(type(value) in {int, float}, f"{label} must be a JSON number")
    if isinstance(value, float):
        require(math.isfinite(value), f"{label} must be finite")
    return value


def validate_approval(value: Any, label: str) -> None:
    approval = exact_object(
        value,
        {"approvedAt", "owner", "recordSHA256", "reviewer"},
        label,
    )
    canonical_string(approval["owner"], f"{label} owner")
    canonical_string(approval["reviewer"], f"{label} reviewer")
    canonical_utc(approval["approvedAt"], f"{label} approvedAt")
    sha256_identity(approval["recordSHA256"], f"{label} recordSHA256")


def validate_bounds(budget: dict[str, Any], label: str) -> None:
    direction = budget["direction"]
    require(
        direction in {"atLeast", "atMost", "range"}, f"{label} direction is unsupported"
    )
    lower = budget["lowerBound"]
    upper = budget["upperBound"]
    if direction == "atLeast":
        finite_number(lower, f"{label} lowerBound")
        require(upper is None, f"{label} atLeast upperBound must be null")
    elif direction == "atMost":
        require(lower is None, f"{label} atMost lowerBound must be null")
        finite_number(upper, f"{label} upperBound")
    else:
        lower_number = finite_number(lower, f"{label} lowerBound")
        upper_number = finite_number(upper, f"{label} upperBound")
        require(lower_number <= upper_number, f"{label} range bounds are reversed")


def validate_budget(value: Any, index: int) -> dict[str, Any]:
    label = f"budget[{index}]"
    budget = exact_object(
        value,
        {
            "applicability",
            "approval",
            "baselineEvidenceSHA256",
            "direction",
            "id",
            "lowerBound",
            "metricDefinitionRevision",
            "rationale",
            "state",
            "statistic",
            "unit",
            "upperBound",
        },
        label,
    )
    budget_id = canonical_identifier(budget["id"], f"{label} id")
    positive_integer(
        budget["metricDefinitionRevision"], f"{label} metricDefinitionRevision"
    )
    state = budget["state"]
    require(
        state in {"provisional", "frozen", "retired"}, f"{label} state is unsupported"
    )
    require(
        budget["direction"] in {"atLeast", "atMost", "range"},
        f"{label} direction is unsupported",
    )
    canonical_identifier(budget["statistic"], f"{label} statistic")
    canonical_identifier(budget["unit"], f"{label} unit")
    canonical_string(budget["rationale"], f"{label} rationale")

    applicability = exact_object(
        budget["applicability"],
        {"architecture", "graphicsQuality", "matrixCellIDs", "qualificationModes"},
        f"{label} applicability",
    )
    require(
        applicability["architecture"] == "arm64", f"{label} architecture must be arm64"
    )
    graphics_quality = applicability["graphicsQuality"]
    require(
        graphics_quality in {"any", "software", "accelerated"},
        f"{label} graphicsQuality is unsupported",
    )
    if budget_id.startswith("gpu.accelerated."):
        require(
            graphics_quality == "accelerated",
            f"{label} accelerated GPU metric is misclassified",
        )
    if budget_id.startswith("gpu.software."):
        require(
            graphics_quality == "software",
            f"{label} software GPU metric is misclassified",
        )

    matrix_cells = applicability["matrixCellIDs"]
    require(
        isinstance(matrix_cells, list) and matrix_cells,
        f"{label} matrixCellIDs must be a non-empty array",
    )
    require(len(matrix_cells) <= MAX_BUDGETS, f"{label} has too many matrix cells")
    checked_cells = [
        sha256_identity(item, f"{label} matrixCellIDs item") for item in matrix_cells
    ]
    require(
        checked_cells == sorted(set(checked_cells)),
        f"{label} matrixCellIDs must be sorted and unique",
    )

    modes = applicability["qualificationModes"]
    require(
        isinstance(modes, list) and modes,
        f"{label} qualificationModes must be a non-empty array",
    )
    require(
        all(mode in {"calibration", "release"} for mode in modes),
        f"{label} qualificationModes is unsupported",
    )
    require(
        modes == sorted(set(modes)),
        f"{label} qualificationModes must be sorted and unique",
    )

    if state == "provisional":
        require(
            budget["lowerBound"] is None and budget["upperBound"] is None,
            f"{label} provisional bounds must be null",
        )
        require(
            budget["baselineEvidenceSHA256"] is None,
            f"{label} provisional baseline evidence must be null",
        )
        require(
            budget["approval"] is None, f"{label} provisional approval must be null"
        )
    else:
        validate_bounds(budget, label)
        sha256_identity(
            budget["baselineEvidenceSHA256"], f"{label} baselineEvidenceSHA256"
        )
        validate_approval(budget["approval"], f"{label} approval")
    return budget


def validate_budget_set(value: dict[str, Any]) -> list[dict[str, Any]]:
    budget_set = exact_object(
        value,
        {
            "architecture",
            "budgetSetID",
            "budgets",
            "kind",
            "revision",
            "schemaVersion",
            "state",
        },
        "budget set",
    )
    require(
        type(budget_set["schemaVersion"]) is int
        and budget_set["schemaVersion"] == SCHEMA_VERSION,
        "budget set schema is unsupported",
    )
    require(budget_set["kind"] == BUDGET_SET_KIND, "budget set kind is unsupported")
    require(
        budget_set["architecture"] == "arm64", "budget set architecture must be arm64"
    )
    canonical_identifier(budget_set["budgetSetID"], "budget set ID")
    positive_integer(budget_set["revision"], "budget set revision")
    require(
        budget_set["state"] in {"provisional", "frozen"},
        "budget set state is unsupported",
    )
    raw_budgets = budget_set["budgets"]
    require(
        isinstance(raw_budgets, list) and raw_budgets,
        "budget set budgets must be a non-empty array",
    )
    require(len(raw_budgets) <= MAX_BUDGETS, "budget set has too many budgets")
    budgets = [validate_budget(item, index) for index, item in enumerate(raw_budgets)]
    ids = [budget["id"] for budget in budgets]
    require(ids == sorted(set(ids)), "budget set IDs must be sorted and unique")
    if budget_set["state"] == "frozen":
        require(
            all(budget["state"] != "provisional" for budget in budgets),
            "frozen budget set contains a provisional budget",
        )
        require(
            any(budget["state"] == "frozen" for budget in budgets),
            "frozen budget set has no active frozen budget",
        )
    return budgets


def validate_graphics(value: Any, backend: str, verdict: str) -> str:
    graphics = exact_object(
        value,
        {
            "accelerationEvidence",
            "accelerationEvidenceSHA256",
            "fallback",
            "fallbackReason",
            "implementation",
            "requestedQuality",
            "selectedQuality",
            "selectionReceiptSHA256",
        },
        "launch graphics",
    )
    requested = graphics["requestedQuality"]
    selected = graphics["selectedQuality"]
    require(
        requested in {"software", "accelerated"},
        "graphics requestedQuality is unsupported",
    )
    require(
        selected in {"software", "accelerated"},
        "graphics selectedQuality is unsupported",
    )
    require(type(graphics["fallback"]) is bool, "graphics fallback must be a Boolean")
    expected_fallback = requested == "accelerated" and selected == "software"
    require(
        not (requested == "software" and selected == "accelerated"),
        "graphics selection cannot silently upgrade the requested quality",
    )
    require(
        graphics["fallback"] == expected_fallback,
        "graphics fallback classification contradicts requested and selected quality",
    )
    if expected_fallback:
        canonical_string(graphics["fallbackReason"], "graphics fallbackReason")
    else:
        require(
            graphics["fallbackReason"] is None,
            "graphics fallbackReason must be null without fallback",
        )
    sha256_identity(
        graphics["selectionReceiptSHA256"], "graphics selectionReceiptSHA256"
    )
    if selected == "software":
        require(
            graphics["implementation"] == "software",
            "software graphics must identify the software implementation",
        )
        require(
            graphics["accelerationEvidence"] is None,
            "software graphics cannot reference acceleration evidence",
        )
        require(
            graphics["accelerationEvidenceSHA256"] is None,
            "software graphics cannot carry acceleration evidence",
        )
    else:
        require(
            backend == "rawhv",
            "schema-1 accelerated graphics is not available on this backend",
        )
        require(
            graphics["implementation"] == "virgl-venus",
            "accelerated graphics implementation is unsupported",
        )
        relative_bundle_path(
            graphics["accelerationEvidence"],
            "graphics accelerationEvidence",
            prefix="evidence",
            suffix=".json",
        )
        sha256_identity(
            graphics["accelerationEvidenceSHA256"],
            "graphics accelerationEvidenceSHA256",
        )
    require(
        not (verdict == "qualified" and expected_fallback),
        "qualified evidence cannot contain a graphics fallback",
    )
    return selected


def validate_evidence(
    value: dict[str, Any],
    budget_raw: bytes,
    budget_set: dict[str, Any],
    budgets: list[dict[str, Any]],
) -> None:
    evidence = exact_object(
        value,
        {
            "campaign",
            "candidate",
            "fallbacks",
            "guest",
            "host",
            "kind",
            "launch",
            "observations",
            "qualificationMode",
            "schemaVersion",
            "signature",
            "summaries",
            "unavailableEvidence",
            "verdict",
        },
        "evidence manifest",
    )
    require(
        type(evidence["schemaVersion"]) is int
        and evidence["schemaVersion"] == SCHEMA_VERSION,
        "evidence schema is unsupported",
    )
    require(evidence["kind"] == EVIDENCE_KIND, "evidence kind is unsupported")
    mode = evidence["qualificationMode"]
    verdict = evidence["verdict"]
    require(mode in {"calibration", "release"}, "qualification mode is unsupported")
    allowed_verdicts = {
        "calibration": {"not-release-qualifying"},
        "release": {"failed", "qualified"},
    }
    require(verdict in allowed_verdicts[mode], "verdict contradicts qualification mode")

    references: list[str] = []

    candidate = exact_object(
        evidence["candidate"],
        {
            "applicationSHA256",
            "budgetSetSHA256",
            "codeSignatureEvidence",
            "componentCandidateInventorySHA256",
            "runtimePlanSHA256",
            "sbomSHA256",
            "virtualHardwareABIVersion",
        },
        "candidate",
    )
    for key in (
        "applicationSHA256",
        "componentCandidateInventorySHA256",
        "runtimePlanSHA256",
        "sbomSHA256",
    ):
        sha256_identity(candidate[key], f"candidate {key}")
    canonical_version(
        candidate["virtualHardwareABIVersion"], "candidate virtualHardwareABIVersion"
    )
    expected_budget_digest = hashlib.sha256(budget_raw).hexdigest()
    require(
        sha256_identity(candidate["budgetSetSHA256"], "candidate budgetSetSHA256")
        == expected_budget_digest,
        "candidate budgetSetSHA256 does not bind the canonical budget set",
    )
    references.append(
        relative_bundle_path(
            candidate["codeSignatureEvidence"],
            "candidate codeSignatureEvidence",
            prefix="evidence",
            suffix=".json",
        )
    )
    host = exact_object(
        evidence["host"],
        {
            "architecture",
            "displayTopology",
            "identity",
            "noiseControls",
            "powerAndThermalState",
            "storageTopology",
        },
        "host",
    )
    require(host["architecture"] == "arm64", "host architecture must be arm64")
    for key in (
        "displayTopology",
        "identity",
        "noiseControls",
        "powerAndThermalState",
        "storageTopology",
    ):
        references.append(
            relative_bundle_path(
                host[key], f"host {key}", prefix="evidence", suffix=".json"
            )
        )

    guest = exact_object(
        evidence["guest"],
        {
            "architecture",
            "guestToolsSHA256",
            "initrdSHA256",
            "installedSystemIdentity",
            "installerSHA256",
            "installerSignatureEvidence",
            "kernelSHA256",
            "mesaAndRendererClientIdentity",
        },
        "guest",
    )
    require(
        guest["architecture"] == "arm64" and budget_set["architecture"] == "arm64",
        "guest and budget architecture must be native arm64",
    )
    for key in ("installerSHA256", "kernelSHA256"):
        sha256_identity(guest[key], f"guest {key}")
    nullable_sha256(guest["initrdSHA256"], "guest initrdSHA256")
    nullable_sha256(guest["guestToolsSHA256"], "guest guestToolsSHA256")
    for key in (
        "installedSystemIdentity",
        "installerSignatureEvidence",
        "mesaAndRendererClientIdentity",
    ):
        references.append(
            relative_bundle_path(
                guest[key], f"guest {key}", prefix="evidence", suffix=".json"
            )
        )

    launch = exact_object(
        evidence["launch"],
        {
            "backend",
            "devices",
            "graphics",
            "graphicsSelectionReceipt",
            "operationID",
            "planGeneration",
            "resources",
        },
        "launch",
    )
    canonical_uuid(launch["operationID"], "launch operationID")
    positive_integer(launch["planGeneration"], "launch planGeneration")
    require(launch["backend"] in {"rawhv", "vz"}, "launch backend is unsupported")
    for key in ("devices", "graphicsSelectionReceipt", "resources"):
        references.append(
            relative_bundle_path(
                launch[key], f"launch {key}", prefix="evidence", suffix=".json"
            )
        )
    selected_graphics = validate_graphics(
        launch["graphics"], launch["backend"], verdict
    )
    if launch["graphics"]["accelerationEvidence"] is not None:
        references.append(launch["graphics"]["accelerationEvidence"])

    campaign = exact_object(
        evidence["campaign"],
        {
            "clockCalibration",
            "definitionID",
            "definitionRevision",
            "harnessSHA256",
            "matrixCellID",
            "matrixCellDescriptor",
            "samplingPlan",
            "workloadSHA256",
        },
        "campaign",
    )
    canonical_identifier(campaign["definitionID"], "campaign definitionID")
    positive_integer(campaign["definitionRevision"], "campaign definitionRevision")
    for key in ("harnessSHA256", "matrixCellID", "workloadSHA256"):
        sha256_identity(campaign[key], f"campaign {key}")
    for key in ("clockCalibration", "matrixCellDescriptor", "samplingPlan"):
        references.append(
            relative_bundle_path(
                campaign[key], f"campaign {key}", prefix="evidence", suffix=".json"
            )
        )

    references.append(
        relative_bundle_path(
            evidence["observations"], "observations", prefix="raw", suffix=".jsonl"
        )
    )
    for key in ("fallbacks", "summaries", "unavailableEvidence"):
        references.append(
            relative_bundle_path(evidence[key], key, prefix="summary", suffix=".json")
        )
    references.append(
        relative_bundle_path(
            evidence["signature"], "signature", prefix="signatures", suffix=".sig"
        )
    )
    require(
        len(references) == len(set(references)),
        "evidence bundle references must be unique",
    )

    if verdict == "qualified":
        require(
            budget_set["state"] == "frozen",
            "qualified evidence requires a frozen budget set",
        )
        require(
            all(budget["state"] != "provisional" for budget in budgets),
            "provisional budget cannot qualify evidence",
        )
        applicable = [
            budget
            for budget in budgets
            if budget["state"] == "frozen"
            and campaign["matrixCellID"] in budget["applicability"]["matrixCellIDs"]
            and mode in budget["applicability"]["qualificationModes"]
        ]
        require(applicable, "qualified evidence has no applicable frozen budget")
        for budget in applicable:
            quality = budget["applicability"]["graphicsQuality"]
            require(
                quality in {"any", selected_graphics},
                "matrix cell graphics quality contradicts the running selection",
            )
        if selected_graphics == "accelerated":
            require(
                any(
                    budget["applicability"]["graphicsQuality"] == "accelerated"
                    for budget in applicable
                ),
                "accelerated qualification has no applicable accelerated budget",
            )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", required=True, type=pathlib.Path)
    parser.add_argument("--budget-set", required=True, type=pathlib.Path)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        budget_set, budget_raw = load_canonical_object(
            arguments.budget_set, "budget set"
        )
        budgets = validate_budget_set(budget_set)
        evidence, evidence_raw = load_canonical_object(
            arguments.evidence, "evidence manifest"
        )
        validate_evidence(evidence, budget_raw, budget_set, budgets)
    except (EvidenceError, OSError) as error:
        print(f"Linux VM performance evidence error: {error}", file=sys.stderr)
        return 1
    print("Linux VM performance evidence structure: PASS")
    print(f"budget-set.sha256={hashlib.sha256(budget_raw).hexdigest()}")
    print(f"evidence.sha256={hashlib.sha256(evidence_raw).hexdigest()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
