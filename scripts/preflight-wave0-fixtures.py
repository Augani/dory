#!/usr/bin/env python3
"""Record whether Wave 0's owned desktop-fixture build can start safely.

This is deliberately a preflight, not a fixture creator: it never creates a
campaign directory, downloads media, starts Docker, or adopts a pre-existing
VM directory.  A successful preflight only says that a new, explicitly owned
campaign directory may be created by the documented desktop producer.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
ROOTFS_NAMES = (
    "dory-desktop-debian-rootfs-arm64.ext4.zst",
    "dory-desktop-ubuntu-rootfs-arm64.ext4.zst",
    "dory-desktop-kali-rootfs-arm64.ext4.zst",
)
GIB = 1024**3


class PreflightError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise PreflightError(f"Wave 0 fixture preflight: {message}")


def direct_regular(path: Path) -> bool:
    return path.is_file() and not path.is_symlink()


def direct_directory(path: Path) -> bool:
    return path.is_dir() and not path.is_symlink()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def nearest_existing_ancestor(path: Path) -> Path:
    candidate = path
    while not candidate.exists() and candidate != candidate.parent:
        candidate = candidate.parent
    return candidate


def campaign_root(root: Path, path: Path) -> dict[str, str]:
    if not path.is_absolute():
        fail("campaign root must be absolute")
    try:
        relative = path.relative_to(root)
    except ValueError as error:
        raise PreflightError("campaign root must be beneath the source root") from error
    if ".." in relative.parts:
        fail("campaign root must not contain parent traversal")
    if len(relative.parts) < 2 or relative.parts[0] != ".dory-build":
        fail("campaign root must be beneath source-root/.dory-build/")
    cursor = root
    for part in relative.parts:
        cursor /= part
        if cursor.is_symlink():
            fail(f"campaign root contains symbolic-link authority: {cursor}")
    if path.exists() or path.is_symlink():
        return {"path": str(path), "status": "not-empty-or-not-new"}
    ancestor = nearest_existing_ancestor(path)
    if not direct_directory(ancestor):
        return {"path": str(path), "status": "parent-unavailable"}
    return {
        "path": str(path),
        "status": "reserved-uncreated",
        "cleanupOwner": "Wave 0 qualification",
        "cleanupRule": "remove only after campaign helpers and guests are confirmed stopped",
    }


def docker_status(binary: str) -> dict[str, str]:
    try:
        result = subprocess.run(
            [binary, "version", "--format", "{{.Server.Version}}"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=20,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"status": "unavailable", "detail": str(error)}
    version = result.stdout.strip()
    if result.returncode != 0 or not version:
        detail = result.stderr.strip() or "Docker did not provide a server version"
        return {"status": "unavailable", "detail": detail}
    return {"status": "available", "serverVersion": version}


def output_artifact(output: Path, name: str) -> dict[str, Any]:
    path = output / name
    if not direct_regular(path):
        return {"name": name, "status": "unavailable"}
    return {
        "name": name,
        "status": "available",
        "byteCount": path.stat().st_size,
        "sha256": sha256(path),
    }


def source_inputs(root: Path) -> list[dict[str, str]]:
    names = (
        "guest/desktop/PINS",
        "guest/desktop/build.sh",
        "guest/desktop/input-fingerprint.sh",
        "guest/desktop/verify-build.sh",
    )
    result: list[dict[str, str]] = []
    for name in names:
        path = root / name
        result.append({
            "path": name,
            "status": "available" if direct_regular(path) else "unavailable",
        })
    return result


def write_result(path: Path, payload: dict[str, Any]) -> None:
    if path.is_symlink():
        fail(f"output must not be a symbolic link: {path}")
    if path.parent.exists() and not direct_directory(path.parent):
        fail(f"output parent must be a direct directory: {path.parent}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--guest-output", type=Path)
    parser.add_argument("--campaign-root", type=Path)
    parser.add_argument("--docker", default="docker")
    parser.add_argument("--minimum-free-gib", type=int, default=12)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    root = arguments.source_root.resolve()
    if not direct_directory(root):
        fail(f"source root must be a direct directory: {root}")
    if arguments.minimum_free_gib < 1 or arguments.minimum_free_gib > 1024:
        fail("minimum free GiB must be between 1 and 1024")
    output = (arguments.guest_output or root / "guest/out").resolve()
    campaign = (arguments.campaign_root or root / ".dory-build/wave0-fixtures").absolute()
    # Canonicalize the explicitly selected source root (macOS /var may alias
    # /private/var), while preserving every child component for symlink checks.
    try:
        relative_campaign = campaign.relative_to(arguments.source_root.absolute())
    except ValueError:
        relative_campaign = None
    if relative_campaign is not None:
        campaign = root / relative_campaign
    campaign = campaign_root(root, campaign)
    capacity_path = nearest_existing_ancestor(Path(campaign["path"]))
    if not direct_directory(capacity_path):
        fail(f"campaign capacity path is not a direct directory: {capacity_path}")
    free = shutil.disk_usage(capacity_path).free
    required = arguments.minimum_free_gib * GIB
    capacity = {
        "path": str(capacity_path),
        "freeBytes": free,
        "requiredFreeBytes": required,
        "status": "available" if free >= required else "insufficient",
    }
    rootfs = [output_artifact(output, name) for name in ROOTFS_NAMES]
    sources = source_inputs(root)
    docker = docker_status(arguments.docker)
    blockers: list[str] = []
    if docker["status"] != "available":
        blockers.append("docker-engine-unavailable")
    if capacity["status"] != "available":
        blockers.append("insufficient-disposable-fixture-space")
    if campaign["status"] != "reserved-uncreated":
        blockers.append("campaign-root-is-not-a-new-owned-scratch-path")
    if any(item["status"] != "available" for item in sources):
        blockers.append("desktop-producer-input-unavailable")
    if any(item["status"] != "available" for item in rootfs):
        blockers.append("desktop-rootfs-artifacts-unavailable")
    payload: dict[str, Any] = {
        "schemaVersion": 1,
        "kind": "dev.dory.wave0-owned-fixture-preflight",
        "sourceRoot": str(root),
        "guestOutput": str(output),
        "sourceInputs": sources,
        "desktopRootfs": rootfs,
        "docker": docker,
        "capacity": capacity,
        "campaignRoot": campaign,
        "acquisition": {
            "producer": "guest/desktop/build.sh arm64 <debian|ubuntu|kali>",
            "doesNotAdopt": "pre-existing VM, installed disk, or user runtime directory",
        },
        "blockers": blockers,
        "fixtureReadiness": "ready-to-build" if not blockers else "blocked",
        "releaseQualified": False,
    }
    if arguments.output is None:
        sys.stdout.write(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    else:
        write_result(arguments.output, payload)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PreflightError as error:
        raise SystemExit(str(error))
