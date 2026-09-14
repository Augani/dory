#!/usr/bin/env python3
"""Audit a manually exported Dory macOS guest Metal probe result.

This is deliberately a development-evidence boundary, not guest-to-host
authentication.  It makes the manual handoff reviewable by binding one raw
guest result to a host-issued challenge, the staged Guest Tools manifest, and
the retained probe source inventory.  Its output is never release eligible.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
import tempfile
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_SCHEMA = "dory.macos-guest-tools-manifest@1"
RESULT_SCHEMA = "dory.guest-tools.metal-probe@1"
CHALLENGE_SCHEMA = "dory.macos-guest-metal-probe-challenge@1"
VERIFICATION_SCHEMA = "dory.macos-guest-metal-probe-verification@1"
BUNDLE_IDENTIFIER = "com.pythonxi.Dory.GuestTools"
SOURCE_FILES = (
    "GuestTools/DoryGuestTools/DoryGuestMetalProbe.swift",
    "GuestTools/DoryGuestTools/DoryGuestToolsApp.swift",
    "GuestTools/DoryGuestTools/DoryGuestTools.entitlements",
    "GuestTools/METAL_PROBE.md",
)
LABEL = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")


class ProbeError(ValueError):
    pass


def digest(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def read_regular(path: Path, label: str) -> bytes:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise ProbeError(f"{label} is unavailable: {path}") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise ProbeError(f"{label} must be a direct regular file: {path}")
    try:
        return path.read_bytes()
    except OSError as error:
        raise ProbeError(f"could not read {label}: {path}") from error


def load_json(path: Path, label: str) -> tuple[dict[str, Any], bytes]:
    payload = read_regular(path, label)
    try:
        value = json.loads(payload)
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
        dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ProbeError(f"{name} is not ISO-8601") from error
    return value


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
    if capabilities != [{"id": "metal-probe", "version": 1}]:
        raise ProbeError("manifest must declare exactly metal-probe@1")
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
        for relative in SOURCE_FILES:
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
        "schema", "issuedAt", "candidateID", "machineID", "nonce", "guestToolsManifestSHA256",
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
        "nonce": label(value["nonce"], "challenge nonce"),
        "manifestSHA256": sha256_value(value["guestToolsManifestSHA256"], "challenge manifest digest"),
        "bundleIdentifier": BUNDLE_IDENTIFIER,
        "bundleVersion": label(value["guestToolsVersion"], "challenge bundle version"),
        "bundleBuild": label(value["guestToolsBuild"], "challenge bundle build"),
    }


def validate_result(value: dict[str, Any], challenge: dict[str, str]) -> dict[str, Any]:
    exact_keys(value, {
        "schema", "createdAt", "nonce", "candidateID", "machineID", "guestOperatingSystemVersion",
        "guestOperatingSystemBuild",
        "guestActiveProcessorCount", "guestPhysicalMemoryBytes", "guestToolsBundleIdentifier",
        "guestToolsVersion", "guestToolsBuild", "metalDeviceName", "metalRegistryID",
        "usesUnifiedMemory", "probeShaderSHA256", "computeOutputSHA256", "renderedPatternSHA256",
        "computeValueCount", "renderedWidth", "renderedHeight", "computeCommandBufferStatus",
        "renderCommandBufferStatus",
    }, "guest probe result")
    if value["schema"] != RESULT_SCHEMA:
        raise ProbeError("guest probe result schema is unsupported")
    if value["candidateID"] != challenge["candidateID"] or value["nonce"] != challenge["nonce"]:
        raise ProbeError("guest probe result does not match the host-issued candidate or nonce")
    if value["machineID"] != challenge["machineID"]:
        raise ProbeError("guest probe result does not match the host-issued machine ID")
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
    if value["computeOutputSHA256"] != compute_digest():
        raise ProbeError("guest compute digest does not match the retained deterministic workload")
    if (value["computeValueCount"], value["renderedWidth"], value["renderedHeight"]) != (1_024, 64, 64):
        raise ProbeError("guest probe workload dimensions are unsupported")
    if value["computeCommandBufferStatus"] != "completed" or value["renderCommandBufferStatus"] != "completed":
        raise ProbeError("guest probe command buffers did not both complete")
    return {
        "guestOperatingSystemVersion": value["guestOperatingSystemVersion"],
        "guestOperatingSystemBuild": value["guestOperatingSystemBuild"],
        "machineID": value["machineID"],
        "guestActiveProcessorCount": value["guestActiveProcessorCount"],
        "guestPhysicalMemoryBytes": value["guestPhysicalMemoryBytes"],
        "metalDeviceName": value["metalDeviceName"],
        "metalRegistryID": value["metalRegistryID"],
        "usesUnifiedMemory": value["usesUnifiedMemory"],
        "probeShaderSHA256": value["probeShaderSHA256"],
        "computeOutputSHA256": value["computeOutputSHA256"],
        "renderedPatternSHA256": value["renderedPatternSHA256"],
    }


def issue(arguments: argparse.Namespace) -> None:
    manifest, payload = load_json(arguments.guest_tools_manifest, "guest tools manifest")
    manifest_fields = validate_manifest(manifest, payload, None)
    candidate_id = label(arguments.candidate_id, "candidate ID")
    if candidate_id != manifest_fields["candidateID"]:
        raise ProbeError("challenge candidate ID does not match the staged Guest Tools manifest")
    issued_at = arguments.issued_at or dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    document = {
        "schema": CHALLENGE_SCHEMA,
        "issuedAt": utc_timestamp(issued_at, "challenge issuedAt"),
        "candidateID": candidate_id,
        "machineID": label(arguments.machine_id, "machine ID"),
        "nonce": label(arguments.nonce, "nonce"),
        "guestToolsManifestSHA256": manifest_fields["manifestSHA256"],
        "guestToolsBundleIdentifier": manifest_fields["bundleIdentifier"],
        "guestToolsVersion": manifest_fields["bundleVersion"],
        "guestToolsBuild": manifest_fields["bundleBuild"],
    }
    atomic_write(arguments.output, canonical_json(document))


def verify(arguments: argparse.Namespace) -> None:
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
    document = {
        "schema": VERIFICATION_SCHEMA,
        "status": "development-observed",
        "releaseEligible": False,
        "collection": "audited-manual",
        "challengeSHA256": digest(challenge_payload),
        "resultSHA256": digest(result_payload),
        "guestToolsManifestSHA256": manifest_fields["manifestSHA256"],
        "candidateID": challenge_fields["candidateID"],
        "machineID": challenge_fields["machineID"],
        "nonce": challenge_fields["nonce"],
        "observed": observed,
        "limitations": [
            "Manual export is not authenticated guest-to-host transport.",
            "This verifier cannot prove that the result came from the selected Dory window or machine.",
            "This development observation is not final-candidate qualification or release evidence.",
        ],
    }
    atomic_write(arguments.output, canonical_json(document))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    issue_parser = commands.add_parser("issue", help="write a host-issued manual-export challenge")
    issue_parser.add_argument("--candidate-id", required=True)
    issue_parser.add_argument("--machine-id", required=True)
    issue_parser.add_argument("--nonce", required=True)
    issue_parser.add_argument("--guest-tools-manifest", required=True, type=Path)
    issue_parser.add_argument("--output", required=True, type=Path)
    issue_parser.add_argument("--issued-at")
    verify_parser = commands.add_parser("verify", help="verify one manual guest result against a challenge")
    verify_parser.add_argument("--challenge", required=True, type=Path)
    verify_parser.add_argument("--result", required=True, type=Path)
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
