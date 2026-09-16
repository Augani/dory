#!/usr/bin/env python3
"""Fail closed on Wave 0's immutable candidate matrix before review or release use."""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import hashlib
import json
from pathlib import Path
import re
import sys
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
REVIEW_ROLES = {"release owner", "runtime owner", "security reviewer"}
SHA256 = re.compile(r"^[0-9a-f]{64}$")


def fail(message: str) -> None:
    raise SystemExit(f"Wave 0 qualification matrix: {message}")


def direct_file(path: Path, label: str) -> Path:
    if not path.is_file() or path.is_symlink():
        fail(f"{label} is missing or indirect: {path}")
    return path


def source_file(root: Path, relative: Any, label: str) -> Path:
    path = Path(string(relative, f"{label} path"))
    if path.is_absolute() or ".." in path.parts:
        fail(f"{label} path must stay within the source root")
    current = root
    for part in path.parts:
        current /= part
        if current.is_symlink():
            fail(f"{label} path must not traverse symbolic links: {relative}")
    return direct_file(current, label)


def object_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            fail(f"JSON repeats key {key}")
        value[key] = item
    return value


def load(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(direct_file(path, label).read_text(encoding="utf-8"), object_pairs_hook=object_pairs)
    except (OSError, json.JSONDecodeError) as error:
        fail(f"{label} is invalid JSON: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    return value


def require_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        fail(f"{label} has wrong keys: missing={sorted(expected - actual)}, extra={sorted(actual - expected)}")


def string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        fail(f"{label} must be a nonempty string")
    return value


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with direct_file(path, "matrix artifact").open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def named(items: Any, label: str) -> dict[str, dict[str, Any]]:
    if not isinstance(items, list) or not items:
        fail(f"{label} must be a nonempty list")
    result: dict[str, dict[str, Any]] = {}
    for item in items:
        if not isinstance(item, dict):
            fail(f"{label} contains a non-object")
        identifier = string(item.get("id"), f"{label} id")
        if identifier in result:
            fail(f"{label} repeats {identifier}")
        result[identifier] = item
    return result


def approval_payload_sha256(matrix: dict[str, Any]) -> str:
    """Digest reviewed content independently of status and appended review records.

    Approval records document repository review; they are not cryptographic attestations.
    The catalog byte digest and every tuple remain inside the reviewed content.
    """
    payload = copy.deepcopy(matrix)
    payload.pop("selectionStatus", None)
    payload["review"].pop("status", None)
    payload["review"].pop("approvals", None)
    return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":"),
                                    ensure_ascii=False).encode("utf-8")).hexdigest()


def selections(value: Any, available: dict[str, Any], label: str) -> list[str]:
    if (not isinstance(value, list) or not value
            or any(not isinstance(item, str) or item not in available for item in value)
            or len(set(value)) != len(value)):
        fail(f"{label} must contain unique known identifiers")
    return value


def validate(
    matrix: dict[str, Any], catalog: dict[str, Any], root: Path,
    matrix_path: Path, require_approved: bool,
) -> dict[str, Any]:
    require_keys(matrix, {
        "schemaVersion", "kind", "selectionDate", "selectionStatus", "releaseQualified", "candidateCatalog",
        "candidateCatalogSHA256", "vendorSupportEvidence", "hostClasses", "resourceClasses", "cpuProfiles", "graphicsProfiles",
        "guestCells", "review",
    }, "matrix")
    if matrix["schemaVersion"] != 1 or matrix["kind"] != "dev.dory.wave0-qualification-matrix":
        fail("matrix schema identity is invalid")
    selection_date = string(matrix["selectionDate"], "selectionDate")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", selection_date):
        fail("selectionDate must be canonical YYYY-MM-DD")
    try:
        dt.date.fromisoformat(selection_date)
    except ValueError:
        fail("selectionDate must be a valid calendar date")
    if matrix["selectionStatus"] not in {"proposed-review-required", "approved"}:
        fail("selectionStatus is invalid")
    if matrix["releaseQualified"] is not False:
        fail("a Wave 0 matrix cannot claim release qualification")
    if matrix["candidateCatalog"] != "Config/DoryVirtualizationGuestCandidates.json":
        fail("matrix must bind the canonical guest candidate catalog")
    catalog_digest = string(matrix["candidateCatalogSHA256"], "candidate catalog digest")
    if not SHA256.fullmatch(catalog_digest) or sha256_file(source_file(root, matrix["candidateCatalog"], "candidate catalog")) != catalog_digest:
        fail("candidate catalog digest mismatch")
    evidence = matrix["vendorSupportEvidence"]
    if not isinstance(evidence, list) or len(evidence) < 3:
        fail("vendorSupportEvidence must retain Ubuntu, Fedora, and Apple authority")
    for item in evidence:
        if not isinstance(item, dict) or not str(item.get("url", "")).startswith("https://"):
            fail("vendor support evidence must use direct HTTPS authority")

    require_keys(catalog, {"schemaVersion", "kind", "selectionDate", "scope", "downloadPolicy", "artifacts"}, "candidate catalog")
    if catalog["schemaVersion"] != 1 or catalog["kind"] != "virtualization-guest-candidates":
        fail("candidate catalog kind is invalid")
    artifacts = named(catalog["artifacts"], "candidate artifacts")
    resources = named(matrix["resourceClasses"], "resource classes")
    for resource in resources.values():
        for key in ("guestCPUs", "guestMemoryMiB", "guestDiskGiB"):
            if type(resource.get(key)) is not int or resource[key] <= 0:
                fail(f"resource class {resource['id']} has invalid {key}")
        if not isinstance(resource.get("workloads"), list) or not resource["workloads"]:
            fail(f"resource class {resource['id']} has no workload")
    hosts = named(matrix["hostClasses"], "host classes")
    if not 1 <= len(hosts) <= 2:
        fail("Wave 0 must nominate one or two explicitly frozen host classes")
    for host in hosts.values():
        for key in ("architecture", "model", "soc", "releaseAdmission"):
            string(host.get(key), f"host {host['id']} {key}")
        if (host["architecture"] != "arm64" or not isinstance(host.get("memoryMiB"), int)
                or host["memoryMiB"] < 16384):
            fail(f"host class {host['id']} does not define the required Apple-silicon 16 GiB floor")
        operating_system = host.get("operatingSystem")
        if not isinstance(operating_system, dict) or set(operating_system) != {"version", "build"}:
            fail(f"host class {host['id']} operatingSystem is incomplete")
        string(operating_system["version"], f"host {host['id']} operating-system version")
        string(operating_system["build"], f"host {host['id']} operating-system build")

    cpus = named(matrix["cpuProfiles"], "CPU profiles")
    for profile in cpus.values():
        if profile.get("architecture") not in {"arm64", "x86_64"}:
            fail(f"CPU profile {profile['id']} has invalid architecture")
        string(profile.get("executionOwner"), f"CPU profile {profile['id']} execution owner")
        if profile.get("status") != "implementation-only":
            fail(f"CPU profile {profile['id']} must remain implementation-only")
    graphics = named(matrix["graphicsProfiles"], "graphics profiles")
    for profile in graphics.values():
        if profile.get("guestArchitecture") not in {"arm64", "x86_64"}:
            fail(f"graphics profile {profile['id']} has invalid architecture")
        if profile.get("status") != "unqualified":
            fail(f"graphics profile {profile['id']} must remain unqualified")
        page_size = profile.get("guestPageKiB")
        if page_size not in {4, 16}:
            fail(f"graphics profile {profile['id']} has invalid guestPageKiB")
        for artifact_key in ("kernel", "mesa"):
            if artifact_key not in profile:
                continue
            artifact = profile[artifact_key]
            if not isinstance(artifact, dict) or set(artifact) != {"path", "sha256"}:
                fail(f"graphics profile {profile['id']} has malformed {artifact_key}")
            digest = string(artifact["sha256"], f"{profile['id']} {artifact_key} digest")
            if not SHA256.fullmatch(digest):
                fail(f"graphics profile {profile['id']} has non-SHA256 {artifact_key} digest")
            actual = sha256_file(source_file(root, artifact["path"], "matrix artifact"))
            if actual != digest:
                fail(f"graphics profile {profile['id']} {artifact_key} digest mismatch")

    cells = named(matrix["guestCells"], "guest cells")
    families: dict[str, set[str]] = {"arm64": set(), "x86_64": set()}
    mac_cells = 0
    missing_inputs: set[str] = set()
    for cell in cells.values():
        media = artifacts.get(string(cell.get("mediaID"), f"cell {cell['id']} mediaID"))
        if media is None:
            fail(f"cell {cell['id']} references unknown media")
        architecture = string(cell.get("architecture"), f"cell {cell['id']} architecture")
        if architecture != media.get("architecture"):
            fail(f"cell {cell['id']} architecture does not match media")
        if media.get("guest") != cell.get("guest"):
            fail(f"cell {cell['id']} guest does not match media")
        if not SHA256.fullmatch(string(media.get("sha256"), f"cell {cell['id']} media digest")):
            fail(f"cell {cell['id']} media digest is not SHA-256")
        cpu = cpus.get(string(cell.get("cpuProfile"), f"cell {cell['id']} CPU profile"))
        if cpu is None or cpu["architecture"] != architecture:
            fail(f"cell {cell['id']} CPU profile architecture mismatch")
        selections(cell.get("resourceClasses"), resources, f"cell {cell['id']} resource classes")
        selected_graphics = selections(cell.get("graphicsProfiles"), graphics, f"cell {cell['id']} graphics profiles")
        if any(graphics[item]["guestArchitecture"] != architecture for item in selected_graphics):
            fail(f"cell {cell['id']} graphics profile architecture mismatch")
        if cell.get("guest") == "linux":
            for profile_id in selected_graphics:
                for artifact_key in ("kernel", "mesa"):
                    if artifact_key not in graphics[profile_id]:
                        missing_inputs.add(f"{profile_id}.{artifact_key}")
            if architecture not in families or media.get("role") != "general-purpose":
                fail(f"Linux cell {cell['id']} is not a general-purpose ARM64/x86_64 input")
            families[architecture].add(string(media.get("family"), f"cell {cell['id']} media family"))
        elif cell.get("guest") == "macos":
            mac_cells += 1
            if architecture != "arm64" or media.get("id") != "macos-26.6.2-25G83-arm64":
                fail("macOS cell must bind the selected arm64 26.6.2/25G83 IPSW")
        else:
            fail(f"cell {cell['id']} has invalid guest family")
    # The release closeout deliberately narrows the public candidate to exactly one cell.
    # Preserve the broader review fixture contract below so historical proposal records remain
    # readable, but do not let it expand the public release matrix.
    release_cell_ids = set(cells)
    if release_cell_ids == {"linux-arm64-ubuntu-24.04.4"}:
        cell = cells["linux-arm64-ubuntu-24.04.4"]
        if (cell.get("guest"), cell.get("architecture"), cell.get("mediaID")) != (
            "linux", "arm64", "ubuntu-server-24.04.4-arm64"
        ):
            fail("release matrix must bind Ubuntu 24.04.4 ARM64 only")
        if mac_cells != 0:
            fail("release matrix must not include a macOS guest cell")
    else:
        for architecture, selected_families in families.items():
            if len(selected_families) < 2 or not {"debian", "fedora"}.issubset(selected_families):
                fail(f"{architecture} lacks two immutable general-purpose Linux families")
        if mac_cells != 1:
            fail("matrix must include exactly one frozen macOS restore cell")

    review = matrix["review"]
    if not isinstance(review, dict) or set(review) != {"status", "requiredApprovals", "approvalRule", "approvals"}:
        fail("matrix review contract is invalid")
    roles = review["requiredApprovals"]
    if (review["status"] not in {"pending", "approved"} or not isinstance(roles, list)
            or any(not isinstance(role, str) for role in roles)
            or len(roles) != 3 or set(roles) != REVIEW_ROLES):
        fail("matrix reviewer requirements are invalid")
    string(review["approvalRule"], "approval rule")
    payload_digest = approval_payload_sha256(matrix)
    records = review["approvals"]
    if not isinstance(records, list):
        fail("matrix approvals must be a list")
    seen = set()
    for record in records:
        if not isinstance(record, dict):
            fail("matrix approval must be an object")
        require_keys(record, {"role", "reviewer", "reviewedAt", "evidenceURL", "payloadSHA256"}, "approval")
        role = string(record["role"], "approval role")
        if role not in REVIEW_ROLES or role in seen:
            fail("approval role is unknown or repeated")
        seen.add(role)
        string(record["reviewer"], "approval reviewer")
        if not string(record["evidenceURL"], "approval evidence").startswith("https://"):
            fail("approval evidence must name its HTTPS review record")
        try:
            dt.datetime.strptime(string(record["reviewedAt"], "approval time"), "%Y-%m-%dT%H:%M:%SZ")
        except ValueError:
            fail("approval time must be UTC YYYY-MM-DDTHH:MM:SSZ")
        if record["payloadSHA256"] != payload_digest:
            fail("approval does not bind the current matrix content")
    approved = matrix["selectionStatus"] == "approved" and review["status"] == "approved"
    if (matrix["selectionStatus"] == "approved") != (review["status"] == "approved"):
        fail("matrix approval status fields disagree")
    if approved and missing_inputs:
        fail(f"approved matrix has unpinned graphics inputs: {sorted(missing_inputs)}")
    if approved and seen != REVIEW_ROLES:
        fail("approved matrix lacks required review records")
    if require_approved and not approved:
        fail("matrix has not received the required approvals")
    return {
        "status": "approved" if matrix["selectionStatus"] == "approved" and review["status"] == "approved" else "review-pending",
        "linuxFamilies": {architecture: sorted(values) for architecture, values in families.items()},
        "guestCells": len(cells),
        "hostClasses": sorted(hosts),
        "graphicsProfiles": len(graphics),
        "matrixSHA256": sha256_file(matrix_path),
        "approvalPayloadSHA256": payload_digest,
        "unpinnedGraphicsInputs": sorted(missing_inputs),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--matrix", type=Path, default=ROOT / "Config/DoryWave0QualificationMatrix.json")
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--require-approved", action="store_true")
    arguments = parser.parse_args()
    root = arguments.source_root.resolve()
    matrix = load(arguments.matrix, "matrix")
    if matrix.get("candidateCatalog") != "Config/DoryVirtualizationGuestCandidates.json":
        fail("matrix must bind the canonical guest candidate catalog")
    catalog = load(source_file(root, matrix["candidateCatalog"], "candidate catalog"), "candidate catalog")
    print(json.dumps(validate(matrix, catalog, root, arguments.matrix, arguments.require_approved), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
