#!/usr/bin/env python3
"""Verify one complete schema-1 Linux VM performance evidence bundle.

The structural pre-signing validator remains a separate gate.  This verifier consumes the
assembled bundle, authenticates its canonical inventory with a caller-supplied Ed25519 trust
root, verifies every inventoried byte, recomputes summaries from raw observations, and evaluates
applicable frozen absolute budgets.  It does not collect measurements or provide a production
signing key.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import decimal
import hashlib
import importlib.util
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from typing import Any, Iterable


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
REPOSITORY_ROOT = SCRIPT_DIR.parent
STRUCTURAL_VALIDATOR = SCRIPT_DIR / "validate-linux-vm-performance-evidence.py"
DEFAULT_SIGNATURE_VERIFIER = (
    REPOSITORY_ROOT / ".github/scripts/verify-ed25519-signature.swift"
)

_SPEC = importlib.util.spec_from_file_location(
    "dory_linux_vm_performance_evidence", STRUCTURAL_VALIDATOR
)
if _SPEC is None or _SPEC.loader is None:  # pragma: no cover - installation defect
    raise RuntimeError("Linux VM performance structural validator could not be loaded")
_STRUCTURAL = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_STRUCTURAL)

EvidenceError = _STRUCTURAL.EvidenceError
fail = _STRUCTURAL.fail
require = _STRUCTURAL.require

SCHEMA_VERSION = 1
INVENTORY_NAME = "bundle-inventory.json"
EVIDENCE_MANIFEST_NAME = "evidence-manifest.json"
BUDGET_SET_NAME = "budget-set.json"
INVENTORY_KIND = "dev.dory.linux-vm-performance-bundle-inventory"
OBSERVATION_KIND = "dev.dory.linux-vm-performance-observation"
SAMPLING_PLAN_KIND = "dev.dory.linux-vm-performance-sampling-plan"
SUMMARIES_KIND = "dev.dory.linux-vm-performance-summaries"
FALLBACKS_KIND = "dev.dory.linux-vm-performance-fallbacks"
UNAVAILABLE_KIND = "dev.dory.linux-vm-performance-unavailable-evidence"
MATRIX_CELL_KIND = "dev.dory.linux-vm-performance-matrix-cell"

MAX_INVENTORY_BYTES = 4 * 1024 * 1024
MAX_INVENTORY_FILES = 16_384
MAX_TOTAL_PAYLOAD_BYTES = 64 * 1024 * 1024 * 1024
MAX_SINGLE_PAYLOAD_BYTES = 8 * 1024 * 1024 * 1024
MAX_OBSERVATIONS_BYTES = 256 * 1024 * 1024
MAX_OBSERVATIONS = 1_000_000
MAX_OBSERVATION_LINE_BYTES = 64 * 1024
MAX_SUMMARY_BYTES = 16 * 1024 * 1024
MAX_METRICS = 16_384
MAX_SIGNATURE_BYTES = 1024
DECIMAL_PLACES = decimal.Decimal("0.000000000001")
SUMMARY_SELECTION_QUERY = "schema1:all-valid-correct-no-fallback"

INVENTORY_KEYS = {
    "budgetSet",
    "evidenceManifest",
    "files",
    "kind",
    "schemaVersion",
}
INVENTORY_FILE_KEYS = {"bytes", "path", "sha256"}
OBSERVATION_KEYS = {
    "campaignRound",
    "clockCalibration",
    "clockID",
    "correctness",
    "endTimestampNanoseconds",
    "fallback",
    "fallbackReason",
    "kind",
    "matrixCellID",
    "measurementScope",
    "metricDefinitionRevision",
    "metricID",
    "observationID",
    "operationID",
    "owner",
    "reason",
    "sampleIndex",
    "schemaVersion",
    "sourceEvidence",
    "startTimestampNanoseconds",
    "unit",
    "validity",
    "value",
    "warmState",
    "workloadPhase",
}
SAMPLING_PLAN_KEYS = {"kind", "metrics", "schemaVersion"}
SAMPLING_METRIC_KEYS = {
    "expectedSampleCount",
    "metricDefinitionRevision",
    "metricID",
    "minimumIndependentRounds",
    "unit",
}
SUMMARIES_KEYS = {"kind", "metrics", "schemaVersion"}
SUMMARY_METRIC_KEYS = {
    "evaluatedSampleCount",
    "failedCorrectnessSampleCount",
    "fallbackSampleCount",
    "invalidSampleCount",
    "metricDefinitionRevision",
    "metricID",
    "observationIDs",
    "sampleCount",
    "selectionQuery",
    "statistics",
    "unavailableSampleCount",
    "unit",
    "validSampleCount",
}
STATISTIC_KEYS = {
    "coefficientOfVariation",
    "lowerQuartile",
    "maximum",
    "mean",
    "median",
    "minimum",
    "p90",
    "p95",
    "p99",
    "upperQuartile",
}
FALLBACK_KEYS = {"capabilityID", "reason"}
UNAVAILABLE_KEYS = {"evidenceID", "mandatory", "reason"}
MATRIX_CELL_KEYS = {
    "campaign",
    "candidate",
    "guest",
    "host",
    "kind",
    "launch",
    "schemaVersion",
}
MATRIX_CELL_CANDIDATE_KEYS = {
    "applicationSHA256",
    "codeSignatureEvidenceSHA256",
    "componentCandidateInventorySHA256",
    "runtimePlanSHA256",
    "sbomSHA256",
    "virtualHardwareABIVersion",
}
MATRIX_CELL_HOST_KEYS = {
    "architecture",
    "displayTopologySHA256",
    "identitySHA256",
    "noiseControlsSHA256",
    "storageTopologySHA256",
}
MATRIX_CELL_GUEST_KEYS = {
    "architecture",
    "guestToolsSHA256",
    "initrdSHA256",
    "installedSystemIdentitySHA256",
    "installerSHA256",
    "installerSignatureEvidenceSHA256",
    "kernelSHA256",
    "mesaAndRendererClientIdentitySHA256",
}
MATRIX_CELL_LAUNCH_KEYS = {
    "backend",
    "devicesSHA256",
    "graphics",
    "graphicsSelectionReceiptSHA256",
    "resourcesSHA256",
}
MATRIX_CELL_GRAPHICS_KEYS = {
    "accelerationEvidence",
    "accelerationEvidenceSHA256",
    "fallback",
    "fallbackReason",
    "implementation",
    "requestedQuality",
    "selectedQuality",
    "selectionReceiptSHA256",
}
MATRIX_CELL_CAMPAIGN_KEYS = {
    "definitionID",
    "definitionRevision",
    "harnessSHA256",
    "samplingPlanSHA256",
    "workloadSHA256",
}

BUDGET_STATISTICS = {
    "lower-quartile": "lowerQuartile",
    "maximum": "maximum",
    "mean": "mean",
    "median": "median",
    "minimum": "minimum",
    "p90": "p90",
    "p95": "p95",
    "p99": "p99",
    "upper-quartile": "upperQuartile",
}


@dataclass(frozen=True)
class InventoryEntry:
    path: str
    byte_count: int
    sha256: str


@dataclass(frozen=True)
class SamplingMetric:
    metric_id: str
    revision: int
    unit: str
    expected_sample_count: int
    minimum_independent_rounds: int

    @property
    def key(self) -> tuple[str, int, str]:
        return (self.metric_id, self.revision, self.unit)


@dataclass(frozen=True)
class SummaryMetric:
    key: tuple[str, int, str]
    observations: tuple[dict[str, Any], ...]
    evaluated: tuple[dict[str, Any], ...]
    statistics: dict[str, decimal.Decimal | None]


@dataclass(frozen=True)
class BudgetResult:
    budget_id: str
    passed: bool
    observed: decimal.Decimal | None
    reason: str


@dataclass(frozen=True)
class BundleResult:
    qualification_mode: str
    manifest_verdict: str
    budget_results: tuple[BudgetResult, ...]
    inventory_sha256: str
    public_key_id: str
    candidate: "CandidateBinding"
    support_cell: "SupportCellBinding"

    @property
    def release_qualified(self) -> bool:
        return (
            self.qualification_mode == "release"
            and self.manifest_verdict == "qualified"
            and bool(self.budget_results)
            and all(result.passed for result in self.budget_results)
        )


@dataclass(frozen=True)
class CandidateBinding:
    component_candidate_inventory_sha256: str
    application_sha256: str
    sbom_sha256: str
    runtime_plan_sha256: str
    budget_set_sha256: str
    virtual_hardware_abi_version: str

    @classmethod
    def from_manifest(cls, value: dict[str, Any]) -> "CandidateBinding":
        return cls(
            component_candidate_inventory_sha256=(
                value["componentCandidateInventorySHA256"]
            ),
            application_sha256=value["applicationSHA256"],
            sbom_sha256=value["sbomSHA256"],
            runtime_plan_sha256=value["runtimePlanSHA256"],
            budget_set_sha256=value["budgetSetSHA256"],
            virtual_hardware_abi_version=value["virtualHardwareABIVersion"],
        )

    def values(self) -> dict[str, str]:
        return {
            "component candidate inventory SHA-256": (
                self.component_candidate_inventory_sha256
            ),
            "application SHA-256": self.application_sha256,
            "SBOM SHA-256": self.sbom_sha256,
            "runtime plan SHA-256": self.runtime_plan_sha256,
            "budget set SHA-256": self.budget_set_sha256,
            "virtual hardware ABI version": self.virtual_hardware_abi_version,
        }


@dataclass(frozen=True)
class SupportCellBinding:
    matrix_cell_id: str
    installer_sha256: str
    backend: str
    requested_graphics_quality: str
    selected_graphics_quality: str
    graphics_implementation: str
    host_identity_sha256: str
    installed_system_identity_sha256: str


@dataclass(frozen=True)
class ExpectedSupportCell:
    matrix_cell_id: str
    installer_sha256: str
    backend: str
    selected_graphics_quality: str


def exact_object(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    return _STRUCTURAL.exact_object(value, keys, label)


def canonical_identifier(value: Any, label: str) -> str:
    return _STRUCTURAL.canonical_identifier(value, label)


def canonical_string(value: Any, label: str, maximum_bytes: int = 4096) -> str:
    return _STRUCTURAL.canonical_string(value, label, maximum_bytes)


def positive_integer(value: Any, label: str) -> int:
    return _STRUCTURAL.positive_integer(value, label)


def nonnegative_integer(value: Any, label: str) -> int:
    require(
        type(value) is int and value >= 0, f"{label} must be a non-negative integer"
    )
    return value


def canonical_relative_path(value: Any, label: str) -> str:
    text = canonical_string(value, label, 512)
    require("\\" not in text, f"{label} must use POSIX separators")
    path = pathlib.PurePosixPath(text)
    require(
        not path.is_absolute() and text == path.as_posix(),
        f"{label} must be a canonical relative POSIX path",
    )
    require(
        bool(path.parts) and all(part not in {"", ".", ".."} for part in path.parts),
        f"{label} contains a forbidden path component",
    )
    return text


def decode_canonical_object(
    raw: bytes, label: str, maximum_bytes: int
) -> dict[str, Any]:
    require(0 < len(raw) <= maximum_bytes, f"{label} size is invalid")
    try:
        value = json.loads(
            raw,
            object_pairs_hook=_STRUCTURAL.no_duplicate_object,
            parse_constant=_STRUCTURAL.reject_nonfinite_json,
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
        raw == _STRUCTURAL.canonical_json(value),
        f"{label} must be canonical JSON with one final newline",
    )
    return value


class BundleRoot:
    """Descriptor-relative, no-symlink access to one immutable bundle tree."""

    def __init__(self, path: pathlib.Path):
        self.path = pathlib.Path(os.path.abspath(path))
        self.fd: int | None = None
        self.verified_identities: dict[str, tuple[int, int, int, int, int]] = {}

    def __enter__(self) -> "BundleRoot":
        try:
            resolved = self.path.resolve(strict=True)
        except OSError as error:
            fail(f"bundle root cannot be resolved: {error}")
        require(resolved == self.path, "bundle root has an indirect ancestor")
        nofollow = getattr(os, "O_NOFOLLOW", 0)
        require(nofollow != 0, "host does not provide no-follow file opens")
        try:
            self.fd = os.open(
                self.path,
                os.O_RDONLY | os.O_DIRECTORY | nofollow,
            )
        except OSError as error:
            fail(f"bundle root is missing or indirect: {error}")
        require(
            stat.S_ISDIR(os.fstat(self.fd).st_mode), "bundle root is not a directory"
        )
        return self

    def __exit__(self, _type: Any, _value: Any, _traceback: Any) -> None:
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None

    def _root_fd(self) -> int:
        require(self.fd is not None, "bundle root is not open")
        return self.fd

    def open_regular(self, path: str, label: str) -> int:
        canonical_relative_path(path, label)
        parts = pathlib.PurePosixPath(path).parts
        directory_fd = os.dup(self._root_fd())
        nofollow = os.O_NOFOLLOW
        try:
            for part in parts[:-1]:
                try:
                    next_fd = os.open(
                        part,
                        os.O_RDONLY | os.O_DIRECTORY | nofollow,
                        dir_fd=directory_fd,
                    )
                except OSError as error:
                    fail(f"{label} has a missing or indirect ancestor: {error}")
                os.close(directory_fd)
                directory_fd = next_fd
            try:
                file_fd = os.open(
                    parts[-1], os.O_RDONLY | nofollow, dir_fd=directory_fd
                )
            except OSError as error:
                fail(f"{label} is missing or indirect: {error}")
        finally:
            os.close(directory_fd)
        file_stat = os.fstat(file_fd)
        if not stat.S_ISREG(file_stat.st_mode) or file_stat.st_nlink != 1:
            os.close(file_fd)
            fail(f"{label} must be one direct regular file")
        return file_fd

    def read_regular(
        self,
        path: str,
        label: str,
        *,
        maximum_bytes: int,
        expected_bytes: int | None = None,
        expected_sha256: str | None = None,
        retain: bool = True,
    ) -> bytes | None:
        file_fd = self.open_regular(path, label)
        try:
            before = os.fstat(file_fd)
            require(before.st_size <= maximum_bytes, f"{label} exceeds its size limit")
            if expected_bytes is not None:
                require(
                    before.st_size == expected_bytes,
                    f"{label} byte count differs from inventory",
                )
            digest = hashlib.sha256()
            retained = bytearray() if retain else None
            read_bytes = 0
            while True:
                chunk = os.read(file_fd, 1024 * 1024)
                if not chunk:
                    break
                read_bytes += len(chunk)
                require(read_bytes <= maximum_bytes, f"{label} exceeds its size limit")
                digest.update(chunk)
                if retained is not None:
                    retained.extend(chunk)
            after = os.fstat(file_fd)
            require(
                (
                    before.st_dev,
                    before.st_ino,
                    before.st_size,
                    before.st_mtime_ns,
                    before.st_ctime_ns,
                )
                == (
                    after.st_dev,
                    after.st_ino,
                    after.st_size,
                    after.st_mtime_ns,
                    after.st_ctime_ns,
                ),
                f"{label} changed while it was verified",
            )
            require(read_bytes == before.st_size, f"{label} changed while it was read")
            if expected_sha256 is not None:
                require(
                    digest.hexdigest() == expected_sha256,
                    f"{label} SHA-256 differs from inventory",
                )
            self.verified_identities[path] = (
                after.st_dev,
                after.st_ino,
                after.st_size,
                after.st_mtime_ns,
                after.st_ctime_ns,
            )
            return bytes(retained) if retained is not None else None
        finally:
            os.close(file_fd)

    def revalidate_identities(self) -> None:
        for path, expected in sorted(self.verified_identities.items()):
            file_fd = self.open_regular(path, f"verified payload {path}")
            try:
                current = os.fstat(file_fd)
            finally:
                os.close(file_fd)
            require(
                (
                    current.st_dev,
                    current.st_ino,
                    current.st_size,
                    current.st_mtime_ns,
                    current.st_ctime_ns,
                )
                == expected,
                f"verified payload {path} changed after authentication",
            )

    def all_files(self) -> set[str]:
        files: set[str] = set()

        def visit(directory_fd: int, prefix: tuple[str, ...]) -> None:
            with os.scandir(directory_fd) as entries:
                names = sorted(entry.name for entry in entries)
            for name in names:
                require(
                    name not in {"", ".", ".."} and "/" not in name,
                    "bundle has an invalid entry name",
                )
                relative = "/".join((*prefix, name))
                try:
                    entry_stat = os.stat(
                        name, dir_fd=directory_fd, follow_symlinks=False
                    )
                except OSError as error:
                    fail(f"bundle entry {relative} cannot be inspected: {error}")
                if stat.S_ISLNK(entry_stat.st_mode):
                    fail(f"bundle entry {relative} is a symbolic link")
                if stat.S_ISDIR(entry_stat.st_mode):
                    try:
                        child_fd = os.open(
                            name,
                            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=directory_fd,
                        )
                    except OSError as error:
                        fail(f"bundle directory {relative} is indirect: {error}")
                    try:
                        visit(child_fd, (*prefix, name))
                    finally:
                        os.close(child_fd)
                elif stat.S_ISREG(entry_stat.st_mode):
                    require(
                        entry_stat.st_nlink == 1,
                        f"bundle entry {relative} is a hard link",
                    )
                    files.add(relative)
                else:
                    fail(f"bundle entry {relative} is not a regular file or directory")

        visit(self._root_fd(), ())
        return files


def validate_inventory(
    value: dict[str, Any],
) -> tuple[dict[str, InventoryEntry], str, str]:
    inventory = exact_object(value, INVENTORY_KEYS, "bundle inventory")
    require(
        type(inventory["schemaVersion"]) is int
        and inventory["schemaVersion"] == SCHEMA_VERSION,
        "bundle inventory schema is unsupported",
    )
    require(inventory["kind"] == INVENTORY_KIND, "bundle inventory kind is unsupported")
    evidence_path = canonical_relative_path(
        inventory["evidenceManifest"], "inventory evidenceManifest"
    )
    budget_path = canonical_relative_path(inventory["budgetSet"], "inventory budgetSet")
    require(
        evidence_path == EVIDENCE_MANIFEST_NAME,
        "schema-1 evidence manifest path is not canonical",
    )
    require(budget_path == BUDGET_SET_NAME, "schema-1 budget-set path is not canonical")
    raw_files = inventory["files"]
    require(
        isinstance(raw_files, list) and raw_files,
        "bundle inventory files must be a non-empty array",
    )
    require(
        len(raw_files) <= MAX_INVENTORY_FILES, "bundle inventory has too many files"
    )
    entries: dict[str, InventoryEntry] = {}
    total_bytes = 0
    for index, raw_entry in enumerate(raw_files):
        label = f"bundle inventory file[{index}]"
        entry = exact_object(raw_entry, INVENTORY_FILE_KEYS, label)
        path = canonical_relative_path(entry["path"], f"{label} path")
        require(
            path not in {INVENTORY_NAME},
            f"{label} cannot inventory the inventory itself",
        )
        byte_count = positive_integer(entry["bytes"], f"{label} bytes")
        require(byte_count <= MAX_SINGLE_PAYLOAD_BYTES, f"{label} is too large")
        digest = _STRUCTURAL.sha256_identity(entry["sha256"], f"{label} sha256")
        require(path not in entries, f"bundle inventory repeats path {path}")
        entries[path] = InventoryEntry(path, byte_count, digest)
        total_bytes += byte_count
        require(
            total_bytes <= MAX_TOTAL_PAYLOAD_BYTES,
            "bundle inventory payload is too large",
        )
    paths = list(entries)
    require(paths == sorted(paths), "bundle inventory paths must be sorted and unique")
    require(
        evidence_path in entries,
        "bundle inventory does not contain the evidence manifest",
    )
    require(budget_path in entries, "bundle inventory does not contain the budget set")
    return entries, evidence_path, budget_path


def manifest_references(evidence: dict[str, Any]) -> set[str]:
    references = {
        evidence["candidate"]["codeSignatureEvidence"],
        evidence["host"]["displayTopology"],
        evidence["host"]["identity"],
        evidence["host"]["noiseControls"],
        evidence["host"]["powerAndThermalState"],
        evidence["host"]["storageTopology"],
        evidence["guest"]["installedSystemIdentity"],
        evidence["guest"]["installerSignatureEvidence"],
        evidence["guest"]["mesaAndRendererClientIdentity"],
        evidence["launch"]["devices"],
        evidence["launch"]["graphicsSelectionReceipt"],
        evidence["launch"]["resources"],
        evidence["campaign"]["clockCalibration"],
        evidence["campaign"]["matrixCellDescriptor"],
        evidence["campaign"]["samplingPlan"],
        evidence["observations"],
        evidence["summaries"],
        evidence["fallbacks"],
        evidence["unavailableEvidence"],
    }
    acceleration_evidence = evidence["launch"]["graphics"][
        "accelerationEvidence"
    ]
    if acceleration_evidence is not None:
        references.add(acceleration_evidence)
    return {canonical_relative_path(path, "evidence reference") for path in references}


def decode_public_key(value: str) -> bytes:
    canonical_string(value, "signature public key", 64)
    try:
        decoded = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        fail("signature public key must be canonical base64")
    require(len(decoded) == 32, "signature public key must decode to 32 bytes")
    require(
        base64.b64encode(decoded).decode("ascii") == value,
        "signature public key is not canonical base64",
    )
    return decoded


def validate_signature_bytes(raw: bytes) -> None:
    try:
        text = raw.decode("ascii")
        decoded = base64.b64decode(text.strip(), validate=True)
    except (UnicodeError, binascii.Error, ValueError):
        fail("bundle signature is malformed")
    require(
        text == text.strip() + "\n",
        "bundle signature must be one canonical base64 line",
    )
    require(len(decoded) == 64, "bundle signature must be one Ed25519 signature")


def direct_verifier(path: pathlib.Path) -> pathlib.Path:
    logical = pathlib.Path(os.path.abspath(path))
    try:
        resolved = logical.resolve(strict=True)
    except OSError as error:
        fail(f"signature verifier is missing: {error}")
    require(resolved == logical, "signature verifier has an indirect ancestor")
    verifier_stat = logical.stat()
    require(
        stat.S_ISREG(verifier_stat.st_mode) and not logical.is_symlink(),
        "signature verifier is not a direct regular file",
    )
    return logical


def verify_detached_signature(
    inventory_raw: bytes,
    signature_raw: bytes,
    public_key_base64: str,
    verifier_path: pathlib.Path,
) -> str:
    public_key = decode_public_key(public_key_base64)
    validate_signature_bytes(signature_raw)
    verifier = direct_verifier(verifier_path)
    with tempfile.TemporaryDirectory(prefix="dory-performance-signature-") as temporary:
        temporary_path = pathlib.Path(temporary)
        inventory_path = temporary_path / INVENTORY_NAME
        signature_path = temporary_path / "bundle.sig"
        inventory_path.write_bytes(inventory_raw)
        signature_path.write_bytes(signature_raw)
        try:
            completed = subprocess.run(
                [
                    "xcrun",
                    "swift",
                    str(verifier),
                    public_key_base64,
                    str(signature_path),
                    str(inventory_path),
                ],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=120,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            fail(f"detached signature verifier could not run: {error}")
    require(completed.returncode == 0, "detached bundle signature is invalid")
    return hashlib.sha256(public_key).hexdigest()


def decimal_value(value: Any, label: str) -> decimal.Decimal:
    _STRUCTURAL.finite_number(value, label)
    result = decimal.Decimal(str(value))
    require(result.is_finite(), f"{label} must be finite")
    require(
        result.as_tuple().exponent >= -12, f"{label} exceeds schema-1 decimal precision"
    )
    require(result == 0 or result.adjusted() <= 30, f"{label} magnitude is unsupported")
    return result


def optional_timestamp(value: Any, label: str) -> int | None:
    if value is None:
        return None
    return nonnegative_integer(value, label)


def validate_observations(
    raw: bytes,
    evidence: dict[str, Any],
    inventory_paths: set[str],
) -> list[dict[str, Any]]:
    require(
        0 < len(raw) <= MAX_OBSERVATIONS_BYTES, "observations JSONL size is invalid"
    )
    require(raw.endswith(b"\n"), "observations JSONL must end with one newline")
    observations: list[dict[str, Any]] = []
    for index, line in enumerate(raw.splitlines(keepends=True)):
        label = f"observation[{index}]"
        require(line != b"\n", "observations JSONL contains a blank line")
        require(len(line) <= MAX_OBSERVATION_LINE_BYTES, f"{label} is too large")
        observation = decode_canonical_object(line, label, MAX_OBSERVATION_LINE_BYTES)
        exact_object(observation, OBSERVATION_KEYS, label)
        require(
            type(observation["schemaVersion"]) is int
            and observation["schemaVersion"] == SCHEMA_VERSION,
            f"{label} schema is unsupported",
        )
        require(observation["kind"] == OBSERVATION_KIND, f"{label} kind is unsupported")
        _STRUCTURAL.canonical_uuid(
            observation["observationID"], f"{label} observationID"
        )
        canonical_identifier(observation["metricID"], f"{label} metricID")
        positive_integer(
            observation["metricDefinitionRevision"], f"{label} metricDefinitionRevision"
        )
        require(
            observation["operationID"] == evidence["launch"]["operationID"],
            f"{label} operationID differs from manifest",
        )
        require(
            observation["matrixCellID"] == evidence["campaign"]["matrixCellID"],
            f"{label} matrixCellID differs from manifest",
        )
        positive_integer(observation["campaignRound"], f"{label} campaignRound")
        positive_integer(observation["sampleIndex"], f"{label} sampleIndex")
        canonical_identifier(observation["workloadPhase"], f"{label} workloadPhase")
        require(
            observation["warmState"] in {"cold", "warm"},
            f"{label} warmState is unsupported",
        )
        canonical_identifier(observation["unit"], f"{label} unit")
        canonical_identifier(
            observation["measurementScope"], f"{label} measurementScope"
        )
        canonical_identifier(observation["owner"], f"{label} owner")
        canonical_identifier(observation["clockID"], f"{label} clockID")
        clock_path = canonical_relative_path(
            observation["clockCalibration"], f"{label} clockCalibration"
        )
        require(
            clock_path == evidence["campaign"]["clockCalibration"],
            f"{label} clock calibration differs from manifest",
        )
        source_path = canonical_relative_path(
            observation["sourceEvidence"], f"{label} sourceEvidence"
        )
        require(
            source_path in inventory_paths,
            f"{label} source evidence is not inventoried",
        )
        start = optional_timestamp(
            observation["startTimestampNanoseconds"],
            f"{label} startTimestampNanoseconds",
        )
        end = optional_timestamp(
            observation["endTimestampNanoseconds"], f"{label} endTimestampNanoseconds"
        )
        require(
            (start is None) == (end is None),
            f"{label} timestamps must be both present or both null",
        )
        if start is not None and end is not None:
            require(start <= end, f"{label} timestamps are reversed")
        validity = observation["validity"]
        require(
            validity in {"valid", "invalid", "unavailable"},
            f"{label} validity is unsupported",
        )
        correctness = observation["correctness"]
        require(
            correctness in {"passed", "failed", "unavailable"},
            f"{label} correctness is unsupported",
        )
        require(
            type(observation["fallback"]) is bool, f"{label} fallback must be a Boolean"
        )
        if observation["fallback"]:
            canonical_string(observation["fallbackReason"], f"{label} fallbackReason")
        else:
            require(
                observation["fallbackReason"] is None,
                f"{label} fallbackReason must be null without fallback",
            )
        if validity == "valid":
            decimal_value(observation["value"], f"{label} value")
            require(observation["reason"] is None, f"{label} valid reason must be null")
            require(start is not None, f"{label} valid sample requires timestamps")
            require(
                correctness != "unavailable",
                f"{label} valid sample has unavailable correctness",
            )
        else:
            require(
                observation["value"] is None, f"{label} non-valid value must be null"
            )
            canonical_string(observation["reason"], f"{label} reason")
        observations.append(observation)
        require(
            len(observations) <= MAX_OBSERVATIONS,
            "observations JSONL has too many records",
        )
    require(observations, "observations JSONL has no records")
    observation_ids = [observation["observationID"] for observation in observations]
    require(
        observation_ids == sorted(set(observation_ids)),
        "observation IDs must be sorted and unique",
    )
    sample_keys = [
        (
            observation["metricID"],
            observation["metricDefinitionRevision"],
            observation["campaignRound"],
            observation["sampleIndex"],
        )
        for observation in observations
    ]
    require(
        len(sample_keys) == len(set(sample_keys)),
        "observation sample coordinates must be unique",
    )
    return observations


def validate_sampling_plan(
    value: dict[str, Any],
) -> dict[tuple[str, int, str], SamplingMetric]:
    plan = exact_object(value, SAMPLING_PLAN_KEYS, "sampling plan")
    require(
        type(plan["schemaVersion"]) is int and plan["schemaVersion"] == SCHEMA_VERSION,
        "sampling plan schema is unsupported",
    )
    require(plan["kind"] == SAMPLING_PLAN_KIND, "sampling plan kind is unsupported")
    raw_metrics = plan["metrics"]
    require(
        isinstance(raw_metrics, list) and raw_metrics,
        "sampling plan metrics must be a non-empty array",
    )
    require(len(raw_metrics) <= MAX_METRICS, "sampling plan has too many metrics")
    metrics: dict[tuple[str, int, str], SamplingMetric] = {}
    for index, raw_metric in enumerate(raw_metrics):
        label = f"sampling plan metric[{index}]"
        metric = exact_object(raw_metric, SAMPLING_METRIC_KEYS, label)
        checked = SamplingMetric(
            canonical_identifier(metric["metricID"], f"{label} metricID"),
            positive_integer(
                metric["metricDefinitionRevision"], f"{label} metricDefinitionRevision"
            ),
            canonical_identifier(metric["unit"], f"{label} unit"),
            positive_integer(
                metric["expectedSampleCount"], f"{label} expectedSampleCount"
            ),
            positive_integer(
                metric["minimumIndependentRounds"], f"{label} minimumIndependentRounds"
            ),
        )
        require(
            checked.expected_sample_count <= MAX_OBSERVATIONS,
            f"{label} expectedSampleCount is too large",
        )
        require(
            checked.minimum_independent_rounds <= checked.expected_sample_count,
            f"{label} independent-round requirement exceeds samples",
        )
        require(
            checked.key not in metrics, f"sampling plan repeats metric {checked.key}"
        )
        metrics[checked.key] = checked
    require(
        list(metrics) == sorted(metrics),
        "sampling plan metrics must be sorted and unique",
    )
    return metrics


def rounded_decimal(value: decimal.Decimal) -> decimal.Decimal:
    with decimal.localcontext() as context:
        context.prec = 80
        return value.quantize(
            DECIMAL_PLACES, rounding=decimal.ROUND_HALF_EVEN
        ).normalize()


def percentile(
    values: list[decimal.Decimal], numerator: int, denominator: int
) -> decimal.Decimal:
    require(bool(values), "cannot compute a percentile without values")
    if len(values) == 1:
        return values[0]
    with decimal.localcontext() as context:
        context.prec = 80
        rank = (
            decimal.Decimal(len(values) - 1)
            * decimal.Decimal(numerator)
            / decimal.Decimal(denominator)
        )
        lower_index = int(rank.to_integral_value(rounding=decimal.ROUND_FLOOR))
        upper_index = int(rank.to_integral_value(rounding=decimal.ROUND_CEILING))
        if lower_index == upper_index:
            return values[lower_index]
        fraction = rank - decimal.Decimal(lower_index)
        return (
            values[lower_index] + (values[upper_index] - values[lower_index]) * fraction
        )


def compute_statistics(
    observations: Iterable[dict[str, Any]],
) -> dict[str, decimal.Decimal | None]:
    values = sorted(
        decimal_value(observation["value"], "observation value")
        for observation in observations
    )
    if not values:
        return {key: None for key in STATISTIC_KEYS}
    with decimal.localcontext() as context:
        context.prec = 80
        mean = sum(values, decimal.Decimal(0)) / decimal.Decimal(len(values))
        coefficient: decimal.Decimal | None
        if len(values) < 2 or mean == 0:
            coefficient = None
        else:
            variance = sum((value - mean) ** 2 for value in values) / decimal.Decimal(
                len(values)
            )
            coefficient = variance.sqrt() / abs(mean)
        computed = {
            "minimum": values[0],
            "lowerQuartile": percentile(values, 1, 4),
            "median": percentile(values, 1, 2),
            "upperQuartile": percentile(values, 3, 4),
            "maximum": values[-1],
            "mean": mean,
            "p90": percentile(values, 90, 100),
            "p95": percentile(values, 95, 100),
            "p99": percentile(values, 99, 100),
            "coefficientOfVariation": coefficient,
        }
    return {
        key: rounded_decimal(value) if value is not None else None
        for key, value in computed.items()
    }


def validate_statistics(
    value: Any,
    expected: dict[str, decimal.Decimal | None],
    label: str,
) -> None:
    statistics = exact_object(value, STATISTIC_KEYS, label)
    for key in sorted(STATISTIC_KEYS):
        expected_value = expected[key]
        actual = statistics[key]
        if expected_value is None:
            require(actual is None, f"{label} {key} must be null")
        else:
            require(
                decimal_value(actual, f"{label} {key}") == expected_value,
                f"{label} {key} differs from raw observations",
            )


def validate_summaries(
    value: dict[str, Any],
    observations: list[dict[str, Any]],
    sampling_plan: dict[tuple[str, int, str], SamplingMetric],
) -> dict[tuple[str, int, str], SummaryMetric]:
    summaries = exact_object(value, SUMMARIES_KEYS, "summaries")
    require(
        type(summaries["schemaVersion"]) is int
        and summaries["schemaVersion"] == SCHEMA_VERSION,
        "summaries schema is unsupported",
    )
    require(summaries["kind"] == SUMMARIES_KIND, "summaries kind is unsupported")
    raw_metrics = summaries["metrics"]
    require(
        isinstance(raw_metrics, list) and raw_metrics,
        "summaries metrics must be a non-empty array",
    )
    require(len(raw_metrics) <= MAX_METRICS, "summaries have too many metrics")
    grouped: dict[tuple[str, int, str], list[dict[str, Any]]] = {}
    for observation in observations:
        key = (
            observation["metricID"],
            observation["metricDefinitionRevision"],
            observation["unit"],
        )
        grouped.setdefault(key, []).append(observation)
    require(
        set(grouped) == set(sampling_plan),
        "raw observation metrics differ from the sampling plan",
    )
    results: dict[tuple[str, int, str], SummaryMetric] = {}
    for index, raw_metric in enumerate(raw_metrics):
        label = f"summary metric[{index}]"
        metric = exact_object(raw_metric, SUMMARY_METRIC_KEYS, label)
        key = (
            canonical_identifier(metric["metricID"], f"{label} metricID"),
            positive_integer(
                metric["metricDefinitionRevision"], f"{label} metricDefinitionRevision"
            ),
            canonical_identifier(metric["unit"], f"{label} unit"),
        )
        require(key in sampling_plan, f"{label} is not present in the sampling plan")
        require(key not in results, f"summaries repeat metric {key}")
        selected = tuple(grouped[key])
        plan_metric = sampling_plan[key]
        require(
            len(selected) == plan_metric.expected_sample_count,
            f"{label} does not contain the planned sample count",
        )
        rounds = {observation["campaignRound"] for observation in selected}
        require(
            len(rounds) >= plan_metric.minimum_independent_rounds,
            f"{label} has too few independent rounds",
        )
        observation_ids = [observation["observationID"] for observation in selected]
        require(
            metric["observationIDs"] == observation_ids,
            f"{label} observationIDs differ from raw observations",
        )
        require(
            metric["selectionQuery"] == SUMMARY_SELECTION_QUERY,
            f"{label} selectionQuery is unsupported",
        )
        evaluated = tuple(
            observation
            for observation in selected
            if observation["validity"] == "valid"
            and observation["correctness"] == "passed"
            and not observation["fallback"]
        )
        counts = {
            "sampleCount": len(selected),
            "evaluatedSampleCount": len(evaluated),
            "validSampleCount": sum(
                observation["validity"] == "valid" for observation in selected
            ),
            "invalidSampleCount": sum(
                observation["validity"] == "invalid" for observation in selected
            ),
            "unavailableSampleCount": sum(
                observation["validity"] == "unavailable" for observation in selected
            ),
            "fallbackSampleCount": sum(
                observation["fallback"] for observation in selected
            ),
            "failedCorrectnessSampleCount": sum(
                observation["correctness"] == "failed" for observation in selected
            ),
        }
        for field, expected_count in counts.items():
            require(
                metric[field] == expected_count and type(metric[field]) is int,
                f"{label} {field} differs from raw observations",
            )
        statistics = compute_statistics(evaluated)
        validate_statistics(metric["statistics"], statistics, f"{label} statistics")
        results[key] = SummaryMetric(key, selected, evaluated, statistics)
    require(
        list(results) == sorted(results), "summary metrics must be sorted and unique"
    )
    require(
        set(results) == set(sampling_plan), "summaries differ from the sampling plan"
    )
    return results


def validate_fallbacks(value: dict[str, Any]) -> list[dict[str, Any]]:
    root = exact_object(value, {"items", "kind", "schemaVersion"}, "fallbacks")
    require(
        type(root["schemaVersion"]) is int and root["schemaVersion"] == SCHEMA_VERSION,
        "fallbacks schema is unsupported",
    )
    require(root["kind"] == FALLBACKS_KIND, "fallbacks kind is unsupported")
    require(isinstance(root["items"], list), "fallbacks items must be an array")
    checked: list[dict[str, Any]] = []
    for index, raw_item in enumerate(root["items"]):
        label = f"fallback[{index}]"
        item = exact_object(raw_item, FALLBACK_KEYS, label)
        canonical_identifier(item["capabilityID"], f"{label} capabilityID")
        canonical_string(item["reason"], f"{label} reason")
        checked.append(item)
    ids = [item["capabilityID"] for item in checked]
    require(
        ids == sorted(set(ids)), "fallback capability IDs must be sorted and unique"
    )
    return checked


def validate_unavailable(value: dict[str, Any]) -> list[dict[str, Any]]:
    root = exact_object(
        value, {"items", "kind", "schemaVersion"}, "unavailable evidence"
    )
    require(
        type(root["schemaVersion"]) is int and root["schemaVersion"] == SCHEMA_VERSION,
        "unavailable evidence schema is unsupported",
    )
    require(
        root["kind"] == UNAVAILABLE_KIND, "unavailable evidence kind is unsupported"
    )
    require(
        isinstance(root["items"], list), "unavailable evidence items must be an array"
    )
    checked: list[dict[str, Any]] = []
    for index, raw_item in enumerate(root["items"]):
        label = f"unavailable evidence[{index}]"
        item = exact_object(raw_item, UNAVAILABLE_KEYS, label)
        canonical_identifier(item["evidenceID"], f"{label} evidenceID")
        require(type(item["mandatory"]) is bool, f"{label} mandatory must be a Boolean")
        canonical_string(item["reason"], f"{label} reason")
        checked.append(item)
    ids = [item["evidenceID"] for item in checked]
    require(
        ids == sorted(set(ids)), "unavailable evidence IDs must be sorted and unique"
    )
    return checked


def budget_is_applicable(budget: dict[str, Any], evidence: dict[str, Any]) -> bool:
    applicability = budget["applicability"]
    return (
        budget["state"] == "frozen"
        and evidence["campaign"]["matrixCellID"] in applicability["matrixCellIDs"]
        and evidence["qualificationMode"] in applicability["qualificationModes"]
        and applicability["graphicsQuality"]
        in {"any", evidence["launch"]["graphics"]["selectedQuality"]}
    )


def evaluate_budgets(
    budgets: list[dict[str, Any]],
    evidence: dict[str, Any],
    summaries: dict[tuple[str, int, str], SummaryMetric],
) -> list[BudgetResult]:
    results: list[BudgetResult] = []
    for budget in budgets:
        if not budget_is_applicable(budget, evidence):
            continue
        budget_id = budget["id"]
        key = (budget_id, budget["metricDefinitionRevision"], budget["unit"])
        summary = summaries.get(key)
        if summary is None:
            results.append(
                BudgetResult(budget_id, False, None, "planned metric is missing")
            )
            continue
        statistic_key = BUDGET_STATISTICS.get(budget["statistic"])
        if statistic_key is None:
            results.append(
                BudgetResult(
                    budget_id, False, None, "statistic is unsupported by schema 1"
                )
            )
            continue
        observed = summary.statistics[statistic_key]
        unhealthy = [
            observation
            for observation in summary.observations
            if observation["validity"] != "valid"
            or observation["correctness"] != "passed"
            or observation["fallback"]
        ]
        if unhealthy:
            results.append(
                BudgetResult(
                    budget_id,
                    False,
                    observed,
                    "one or more planned samples is invalid, unavailable, incorrect, or fallback",
                )
            )
            continue
        if observed is None:
            results.append(
                BudgetResult(budget_id, False, None, "statistic has no valid samples")
            )
            continue
        direction = budget["direction"]
        if direction == "atMost":
            passed = observed <= decimal_value(
                budget["upperBound"], f"budget {budget_id} upperBound"
            )
        elif direction == "atLeast":
            passed = observed >= decimal_value(
                budget["lowerBound"], f"budget {budget_id} lowerBound"
            )
        else:
            passed = (
                decimal_value(budget["lowerBound"], f"budget {budget_id} lowerBound")
                <= observed
                <= decimal_value(budget["upperBound"], f"budget {budget_id} upperBound")
            )
        results.append(
            BudgetResult(
                budget_id,
                passed,
                observed,
                (
                    "absolute frozen bound passed"
                    if passed
                    else "absolute frozen bound failed"
                ),
            )
        )
    return results


def require_inventory_reference(
    entries: dict[str, InventoryEntry], path: str, label: str
) -> None:
    require(
        path in entries, f"{label} is not present in the canonical bundle inventory"
    )


def inventory_digest(
    entries: dict[str, InventoryEntry], path: str, label: str
) -> str:
    require_inventory_reference(entries, path, label)
    return entries[path].sha256


def expected_matrix_cell_descriptor(
    evidence: dict[str, Any], entries: dict[str, InventoryEntry]
) -> dict[str, Any]:
    candidate = evidence["candidate"]
    host = evidence["host"]
    guest = evidence["guest"]
    launch = evidence["launch"]
    campaign = evidence["campaign"]
    graphics = launch["graphics"]

    selection_digest = inventory_digest(
        entries,
        launch["graphicsSelectionReceipt"],
        "graphics selection receipt",
    )
    require(
        graphics["selectionReceiptSHA256"] == selection_digest,
        "graphics selection receipt digest does not match its signed bundle bytes",
    )
    acceleration_path = graphics["accelerationEvidence"]
    if acceleration_path is None:
        require(
            graphics["accelerationEvidenceSHA256"] is None,
            "graphics acceleration evidence digest exists without a bundle path",
        )
    else:
        acceleration_digest = inventory_digest(
            entries, acceleration_path, "graphics acceleration evidence"
        )
        require(
            graphics["accelerationEvidenceSHA256"] == acceleration_digest,
            "graphics acceleration evidence digest does not match its signed bundle bytes",
        )

    return {
        "campaign": {
            "definitionID": campaign["definitionID"],
            "definitionRevision": campaign["definitionRevision"],
            "harnessSHA256": campaign["harnessSHA256"],
            "samplingPlanSHA256": inventory_digest(
                entries, campaign["samplingPlan"], "sampling plan"
            ),
            "workloadSHA256": campaign["workloadSHA256"],
        },
        "candidate": {
            "applicationSHA256": candidate["applicationSHA256"],
            "codeSignatureEvidenceSHA256": inventory_digest(
                entries,
                candidate["codeSignatureEvidence"],
                "candidate code-signature evidence",
            ),
            "componentCandidateInventorySHA256": candidate[
                "componentCandidateInventorySHA256"
            ],
            "runtimePlanSHA256": candidate["runtimePlanSHA256"],
            "sbomSHA256": candidate["sbomSHA256"],
            "virtualHardwareABIVersion": candidate["virtualHardwareABIVersion"],
        },
        "guest": {
            "architecture": guest["architecture"],
            "guestToolsSHA256": guest["guestToolsSHA256"],
            "initrdSHA256": guest["initrdSHA256"],
            "installedSystemIdentitySHA256": inventory_digest(
                entries,
                guest["installedSystemIdentity"],
                "installed-system identity",
            ),
            "installerSHA256": guest["installerSHA256"],
            "installerSignatureEvidenceSHA256": inventory_digest(
                entries,
                guest["installerSignatureEvidence"],
                "installer-signature evidence",
            ),
            "kernelSHA256": guest["kernelSHA256"],
            "mesaAndRendererClientIdentitySHA256": inventory_digest(
                entries,
                guest["mesaAndRendererClientIdentity"],
                "guest graphics identity",
            ),
        },
        "host": {
            "architecture": host["architecture"],
            "displayTopologySHA256": inventory_digest(
                entries, host["displayTopology"], "host display topology"
            ),
            "identitySHA256": inventory_digest(
                entries, host["identity"], "host identity"
            ),
            "noiseControlsSHA256": inventory_digest(
                entries, host["noiseControls"], "host noise controls"
            ),
            "storageTopologySHA256": inventory_digest(
                entries, host["storageTopology"], "host storage topology"
            ),
        },
        "kind": MATRIX_CELL_KIND,
        "launch": {
            "backend": launch["backend"],
            "devicesSHA256": inventory_digest(
                entries, launch["devices"], "launch devices"
            ),
            "graphics": dict(graphics),
            "graphicsSelectionReceiptSHA256": selection_digest,
            "resourcesSHA256": inventory_digest(
                entries, launch["resources"], "launch resources"
            ),
        },
        "schemaVersion": SCHEMA_VERSION,
    }


def validate_matrix_cell_descriptor(
    raw: bytes,
    evidence: dict[str, Any],
    entries: dict[str, InventoryEntry],
) -> SupportCellBinding:
    descriptor = decode_canonical_object(
        raw, "matrix-cell descriptor", MAX_SUMMARY_BYTES
    )
    exact_object(descriptor, MATRIX_CELL_KEYS, "matrix-cell descriptor")
    exact_object(
        descriptor["candidate"],
        MATRIX_CELL_CANDIDATE_KEYS,
        "matrix-cell candidate",
    )
    exact_object(descriptor["host"], MATRIX_CELL_HOST_KEYS, "matrix-cell host")
    exact_object(descriptor["guest"], MATRIX_CELL_GUEST_KEYS, "matrix-cell guest")
    launch = exact_object(
        descriptor["launch"], MATRIX_CELL_LAUNCH_KEYS, "matrix-cell launch"
    )
    exact_object(
        launch["graphics"], MATRIX_CELL_GRAPHICS_KEYS, "matrix-cell graphics"
    )
    exact_object(
        descriptor["campaign"],
        MATRIX_CELL_CAMPAIGN_KEYS,
        "matrix-cell campaign",
    )
    expected = expected_matrix_cell_descriptor(evidence, entries)
    require(
        descriptor == expected,
        "matrix-cell descriptor does not match the exact signed support-cell inputs",
    )
    matrix_cell_id = hashlib.sha256(raw).hexdigest()
    require(
        evidence["campaign"]["matrixCellID"] == matrix_cell_id,
        "campaign matrixCellID is not the SHA-256 of its canonical descriptor",
    )
    host_identity = descriptor["host"]["identitySHA256"]
    installed_identity = descriptor["guest"]["installedSystemIdentitySHA256"]
    graphics = descriptor["launch"]["graphics"]
    return SupportCellBinding(
        matrix_cell_id=matrix_cell_id,
        installer_sha256=descriptor["guest"]["installerSHA256"],
        backend=descriptor["launch"]["backend"],
        requested_graphics_quality=graphics["requestedQuality"],
        selected_graphics_quality=graphics["selectedQuality"],
        graphics_implementation=graphics["implementation"],
        host_identity_sha256=host_identity,
        installed_system_identity_sha256=installed_identity,
    )


def verify_bundle(
    bundle_path: pathlib.Path,
    public_key_base64: str,
    verifier_path: pathlib.Path = DEFAULT_SIGNATURE_VERIFIER,
) -> BundleResult:
    # There is deliberately no unsigned bundle traversal mode, including for release failures.
    decode_public_key(public_key_base64)
    with BundleRoot(bundle_path) as bundle:
        inventory_raw = bundle.read_regular(
            INVENTORY_NAME,
            "bundle inventory",
            maximum_bytes=MAX_INVENTORY_BYTES,
        )
        assert inventory_raw is not None
        inventory = decode_canonical_object(
            inventory_raw, "bundle inventory", MAX_INVENTORY_BYTES
        )
        entries, evidence_path, budget_path = validate_inventory(inventory)

        evidence_entry = entries[evidence_path]
        budget_entry = entries[budget_path]
        evidence_raw = bundle.read_regular(
            evidence_path,
            "evidence manifest",
            maximum_bytes=_STRUCTURAL.MAX_JSON_BYTES,
            expected_bytes=evidence_entry.byte_count,
            expected_sha256=evidence_entry.sha256,
        )
        budget_raw = bundle.read_regular(
            budget_path,
            "budget set",
            maximum_bytes=_STRUCTURAL.MAX_JSON_BYTES,
            expected_bytes=budget_entry.byte_count,
            expected_sha256=budget_entry.sha256,
        )
        assert evidence_raw is not None and budget_raw is not None
        evidence = _STRUCTURAL.decode_canonical_object(
            evidence_raw, "evidence manifest"
        )
        budget_set = _STRUCTURAL.decode_canonical_object(budget_raw, "budget set")
        budgets = _STRUCTURAL.validate_budget_set(budget_set)
        _STRUCTURAL.validate_evidence(evidence, budget_raw, budget_set, budgets)

        signature_path = canonical_relative_path(
            evidence["signature"], "bundle signature path"
        )
        require(
            signature_path not in entries,
            "detached signature must not create a circular inventory entry",
        )
        for reference in manifest_references(evidence):
            require_inventory_reference(entries, reference, "evidence reference")

        semantic_paths = {
            evidence["observations"],
            evidence["summaries"],
            evidence["fallbacks"],
            evidence["unavailableEvidence"],
            evidence["campaign"]["matrixCellDescriptor"],
            evidence["campaign"]["samplingPlan"],
        }
        retained: dict[str, bytes] = {
            evidence_path: evidence_raw,
            budget_path: budget_raw,
        }
        for path, entry in entries.items():
            if path in retained:
                continue
            maximum = MAX_SINGLE_PAYLOAD_BYTES
            if path == evidence["observations"]:
                maximum = MAX_OBSERVATIONS_BYTES
            elif path in semantic_paths:
                maximum = MAX_SUMMARY_BYTES
            data = bundle.read_regular(
                path,
                f"inventoried payload {path}",
                maximum_bytes=maximum,
                expected_bytes=entry.byte_count,
                expected_sha256=entry.sha256,
                retain=path in semantic_paths,
            )
            if data is not None:
                retained[path] = data

        actual_files = bundle.all_files()
        expected_files = set(entries) | {INVENTORY_NAME, signature_path}
        require(
            actual_files == expected_files,
            "bundle files differ from the canonical inventory "
            f"(missing={sorted(expected_files - actual_files)}, extra={sorted(actual_files - expected_files)})",
        )
        signature_raw = bundle.read_regular(
            signature_path,
            "detached bundle signature",
            maximum_bytes=MAX_SIGNATURE_BYTES,
        )
        assert signature_raw is not None
        public_key_id = verify_detached_signature(
            inventory_raw,
            signature_raw,
            public_key_base64,
            verifier_path,
        )

        support_cell = validate_matrix_cell_descriptor(
            retained[evidence["campaign"]["matrixCellDescriptor"]],
            evidence,
            entries,
        )

        observations = validate_observations(
            retained[evidence["observations"]],
            evidence,
            set(entries),
        )
        sampling_plan_value = decode_canonical_object(
            retained[evidence["campaign"]["samplingPlan"]],
            "sampling plan",
            MAX_SUMMARY_BYTES,
        )
        sampling_plan = validate_sampling_plan(sampling_plan_value)
        summaries_value = decode_canonical_object(
            retained[evidence["summaries"]],
            "summaries",
            MAX_SUMMARY_BYTES,
        )
        summaries = validate_summaries(summaries_value, observations, sampling_plan)
        fallbacks = validate_fallbacks(
            decode_canonical_object(
                retained[evidence["fallbacks"]], "fallbacks", MAX_SUMMARY_BYTES
            )
        )
        unavailable = validate_unavailable(
            decode_canonical_object(
                retained[evidence["unavailableEvidence"]],
                "unavailable evidence",
                MAX_SUMMARY_BYTES,
            )
        )
        budget_results = evaluate_budgets(budgets, evidence, summaries)

        if (
            evidence["qualificationMode"] == "release"
            and evidence["verdict"] == "qualified"
        ):
            require(not fallbacks, "qualified bundle contains a fallback record")
            require(
                not any(item["mandatory"] for item in unavailable),
                "qualified bundle contains mandatory unavailable evidence",
            )
            require(
                budget_results,
                "qualified bundle has no applicable frozen budget result",
            )
            require(
                all(result.passed for result in budget_results),
                "qualified manifest contradicts recomputed frozen absolute budget results",
            )

        bundle.revalidate_identities()
        require(
            bundle.all_files() == expected_files,
            "bundle file set changed after authentication",
        )

        return BundleResult(
            evidence["qualificationMode"],
            evidence["verdict"],
            tuple(budget_results),
            hashlib.sha256(inventory_raw).hexdigest(),
            public_key_id,
            CandidateBinding.from_manifest(evidence["candidate"]),
            support_cell,
        )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-root", required=True, type=pathlib.Path)
    parser.add_argument(
        "--signature-public-key-base64",
        required=True,
        help="caller-supplied 32-byte Ed25519 public key; no production key is embedded",
    )
    parser.add_argument(
        "--signature-verifier",
        type=pathlib.Path,
        default=DEFAULT_SIGNATURE_VERIFIER,
        help="trusted detached Ed25519 verifier implementation",
    )
    parser.add_argument(
        "--require-release-qualified",
        action="store_true",
        help=(
            "fail unless this is a qualified release bundle and every required "
            "caller-supplied candidate binding matches"
        ),
    )
    parser.add_argument("--expected-component-candidate-inventory-sha256")
    parser.add_argument("--expected-application-sha256")
    parser.add_argument("--expected-sbom-sha256")
    parser.add_argument("--expected-runtime-plan-sha256")
    parser.add_argument("--expected-budget-set-sha256")
    parser.add_argument("--expected-virtual-hardware-abi-version")
    parser.add_argument("--expected-matrix-cell-id")
    parser.add_argument("--expected-installer-sha256")
    parser.add_argument("--expected-backend", choices=("rawhv", "vz"))
    parser.add_argument(
        "--expected-selected-graphics-quality",
        choices=("accelerated", "software"),
    )
    return parser.parse_args()


def format_decimal(value: decimal.Decimal | None) -> str:
    if value is None:
        return "unavailable"
    return format(value, "f")


def expected_candidate_binding(
    arguments: argparse.Namespace,
) -> CandidateBinding | None:
    raw = {
        "component candidate inventory SHA-256": (
            arguments.expected_component_candidate_inventory_sha256
        ),
        "application SHA-256": arguments.expected_application_sha256,
        "SBOM SHA-256": arguments.expected_sbom_sha256,
        "runtime plan SHA-256": arguments.expected_runtime_plan_sha256,
        "budget set SHA-256": arguments.expected_budget_set_sha256,
        "virtual hardware ABI version": (
            arguments.expected_virtual_hardware_abi_version
        ),
    }
    if not any(value is not None for value in raw.values()):
        return None
    missing = sorted(label for label, value in raw.items() if value is None)
    require(
        not missing,
        "expected candidate bindings are incomplete: " + ", ".join(missing),
    )
    return CandidateBinding(
        component_candidate_inventory_sha256=_STRUCTURAL.sha256_identity(
            raw["component candidate inventory SHA-256"],
            "expected component candidate inventory SHA-256",
        ),
        application_sha256=_STRUCTURAL.sha256_identity(
            raw["application SHA-256"], "expected application SHA-256"
        ),
        sbom_sha256=_STRUCTURAL.sha256_identity(
            raw["SBOM SHA-256"],
            "expected SBOM SHA-256",
        ),
        runtime_plan_sha256=_STRUCTURAL.sha256_identity(
            raw["runtime plan SHA-256"], "expected runtime plan SHA-256"
        ),
        budget_set_sha256=_STRUCTURAL.sha256_identity(
            raw["budget set SHA-256"], "expected budget set SHA-256"
        ),
        virtual_hardware_abi_version=_STRUCTURAL.canonical_version(
            raw["virtual hardware ABI version"],
            "expected virtual hardware ABI version",
        ),
    )


def expected_support_cell(
    arguments: argparse.Namespace,
) -> ExpectedSupportCell | None:
    raw = {
        "matrix-cell ID": arguments.expected_matrix_cell_id,
        "installer SHA-256": arguments.expected_installer_sha256,
        "backend": arguments.expected_backend,
        "selected graphics quality": arguments.expected_selected_graphics_quality,
    }
    if not any(value is not None for value in raw.values()):
        return None
    missing = sorted(label for label, value in raw.items() if value is None)
    require(
        not missing,
        "expected support-cell bindings are incomplete: " + ", ".join(missing),
    )
    return ExpectedSupportCell(
        matrix_cell_id=_STRUCTURAL.sha256_identity(
            raw["matrix-cell ID"], "expected matrix-cell ID"
        ),
        installer_sha256=_STRUCTURAL.sha256_identity(
            raw["installer SHA-256"], "expected installer SHA-256"
        ),
        backend=raw["backend"],
        selected_graphics_quality=raw["selected graphics quality"],
    )


def enforce_publication_admission(
    result: BundleResult,
    *,
    require_release_qualified: bool,
    expected: CandidateBinding | None,
    expected_cell: ExpectedSupportCell | None,
) -> None:
    if require_release_qualified:
        require(
            result.release_qualified,
            "bundle is not release-qualified",
        )
        require(
            expected is not None,
            "release qualification requires every expected candidate binding",
        )
        require(
            expected_cell is not None,
            "release qualification requires every expected support-cell binding",
        )
    if expected is not None:
        observed = result.candidate.values()
        for label, expected_value in expected.values().items():
            require(
                observed[label] == expected_value,
                f"signed {label} does not match the publication candidate",
            )
    if expected_cell is not None:
        observed_cell = result.support_cell
        require(
            observed_cell.matrix_cell_id == expected_cell.matrix_cell_id,
            "signed matrix-cell ID does not match the publication support record",
        )
        require(
            observed_cell.installer_sha256 == expected_cell.installer_sha256,
            "signed installer SHA-256 does not match the publication support record",
        )
        require(
            observed_cell.backend == expected_cell.backend,
            "signed backend does not match the publication support record",
        )
        require(
            observed_cell.selected_graphics_quality
            == expected_cell.selected_graphics_quality,
            "signed graphics quality does not match the publication support record",
        )


def main() -> int:
    arguments = parse_arguments()
    try:
        result = verify_bundle(
            arguments.bundle_root,
            arguments.signature_public_key_base64,
            arguments.signature_verifier,
        )
        enforce_publication_admission(
            result,
            require_release_qualified=arguments.require_release_qualified,
            expected=expected_candidate_binding(arguments),
            expected_cell=expected_support_cell(arguments),
        )
    except (EvidenceError, OSError) as error:
        print(f"Linux VM performance bundle error: {error}", file=sys.stderr)
        return 1
    print("Linux VM performance bundle bytes and detached signature: VERIFIED")
    print(f"bundle-inventory.sha256={result.inventory_sha256}")
    print(f"signature.public-key-id={result.public_key_id}")
    print(f"support-cell.matrix-cell-id={result.support_cell.matrix_cell_id}")
    print(f"support-cell.installer-sha256={result.support_cell.installer_sha256}")
    print(f"support-cell.backend={result.support_cell.backend}")
    print(
        "support-cell.selected-graphics-quality="
        f"{result.support_cell.selected_graphics_quality}"
    )
    for budget in result.budget_results:
        verdict = "PASS" if budget.passed else "FAIL"
        print(
            f"budget.{budget.budget_id}={verdict} observed={format_decimal(budget.observed)} reason={budget.reason}"
        )
    if result.qualification_mode == "calibration":
        print(
            "Linux VM performance release qualification: NOT APPLICABLE (calibration)"
        )
        return 0
    if result.release_qualified:
        print("Linux VM performance release qualification: PASS")
        return 0
    print("Linux VM performance release qualification: FAIL", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
