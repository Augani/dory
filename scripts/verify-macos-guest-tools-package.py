#!/usr/bin/env python3
"""Fail-closed verifier for a distributed macOS Dory Guest Tools package."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import stat
import subprocess
from typing import Any


EXPECTED_TEAM = "864H636QW4"
PACKAGE_SCHEMA = "dory.macos-guest-tools-package@1"
BUNDLE_SCHEMA = "dory.macos-guest-tools-manifest@1"
LABEL = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
MODE = re.compile(r"^[0-7]{4}$")


class VerificationError(ValueError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise VerificationError(message)


def direct_regular(path: Path, label: str) -> bytes:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise VerificationError(f"{label} is unavailable: {path}") from error
    require(stat.S_ISREG(metadata.st_mode), f"{label} must be a direct regular file: {path}")
    try:
        return path.read_bytes()
    except OSError as error:
        raise VerificationError(f"could not read {label}: {path}") from error


def sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        require(key not in result, f"JSON contains duplicate key: {key}")
        result[key] = value
    return result


def load_object(path: Path, label: str) -> tuple[dict[str, Any], bytes]:
    payload = direct_regular(path, label)
    try:
        value = json.loads(payload, object_pairs_hook=unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError, VerificationError) as error:
        raise VerificationError(f"{label} is not valid JSON") from error
    require(isinstance(value, dict), f"{label} must be a JSON object")
    return value, payload


def exact_keys(value: object, keys: set[str], label: str) -> dict[str, Any]:
    require(isinstance(value, dict) and set(value) == keys, f"{label} shape is invalid")
    return value


def label(value: object, name: str) -> str:
    require(isinstance(value, str) and LABEL.fullmatch(value) is not None, f"{name} is invalid")
    return value


def digest(value: object, name: str) -> str:
    require(isinstance(value, str) and SHA256.fullmatch(value) is not None, f"{name} is invalid")
    return value


def positive(value: object, name: str) -> int:
    require(isinstance(value, int) and not isinstance(value, bool) and value > 0, f"{name} is invalid")
    return value


def relative_path(value: object, name: str) -> str:
    require(isinstance(value, str) and value and not value.startswith("/"), f"{name} is invalid")
    require(all(part not in {"", ".", ".."} for part in value.split("/")), f"{name} is invalid")
    return value


def inventory_digest(entries: object, label_name: str) -> str:
    require(isinstance(entries, list) and entries, f"{label_name} inventory is invalid")
    normalized: list[tuple[str, str, str, int, str]] = []
    for index, entry in enumerate(entries):
        item = exact_keys(entry, {"path", "type", "mode", "byteCount", "sha256"}, f"{label_name} inventory entry")
        path = relative_path(item["path"], f"{label_name} inventory path")
        kind = item["type"]
        require(kind in {"regular", "symlink"}, f"{label_name} inventory entry type is invalid")
        mode = item["mode"]
        require(isinstance(mode, str) and MODE.fullmatch(mode) is not None, f"{label_name} inventory entry mode is invalid")
        byte_count = item["byteCount"]
        require(isinstance(byte_count, int) and not isinstance(byte_count, bool) and byte_count >= 0, f"{label_name} inventory entry byte count is invalid")
        normalized.append((path, kind, mode, byte_count, digest(item["sha256"], f"{label_name} inventory entry digest")))
    paths = [entry[0] for entry in normalized]
    require(paths == sorted(paths, key=lambda item: item.encode("utf-8")) and len(set(paths)) == len(paths), f"{label_name} inventory is not canonical")
    accumulator = hashlib.sha256()
    for path, kind, mode, byte_count, entry_digest in normalized:
        accumulator.update(f"{path}\0{kind}\0{mode}\0{byte_count}\0{entry_digest}\n".encode("utf-8"))
    return accumulator.hexdigest()


def source_inventory_digest(entries: object) -> str:
    require(isinstance(entries, list) and entries, "embedded source inventory is invalid")
    normalized: list[tuple[str, str]] = []
    for entry in entries:
        item = exact_keys(entry, {"path", "sha256"}, "embedded source inventory entry")
        normalized.append((
            relative_path(item["path"], "embedded source inventory path"),
            digest(item["sha256"], "embedded source inventory entry digest"),
        ))
    paths = [entry[0] for entry in normalized]
    require(paths == sorted(paths, key=lambda item: item.encode("utf-8")) and len(set(paths)) == len(paths), "embedded source inventory is not canonical")
    accumulator = hashlib.sha256()
    for path, entry_digest in normalized:
        accumulator.update(f"{path}\0{entry_digest}\n".encode("utf-8"))
    return accumulator.hexdigest()


def verify_bundle(value: object, candidate: str, commit: str) -> bytes:
    bundle = exact_keys(value, {
        "schema", "candidateID", "sourceCommit", "bundle", "source", "capabilities", "signing",
    }, "embedded guest-tools bundle manifest")
    require(bundle["schema"] == BUNDLE_SCHEMA, "embedded guest-tools bundle manifest schema is invalid")
    require(bundle["candidateID"] == candidate, "embedded guest-tools bundle manifest candidate differs")
    require(bundle["sourceCommit"] == commit, "embedded guest-tools bundle manifest source commit differs")
    app = exact_keys(bundle["bundle"], {"identifier", "version", "build", "treeSHA256", "entries"}, "embedded bundle")
    require(app["identifier"] == "com.pythonxi.Dory.GuestTools", "embedded bundle identifier is invalid")
    label(app["version"], "embedded bundle version")
    label(app["build"], "embedded bundle build")
    require(
        digest(app["treeSHA256"], "embedded bundle tree digest")
        == inventory_digest(app["entries"], "embedded bundle"),
        "embedded bundle tree digest differs from its inventory",
    )
    source = exact_keys(bundle["source"], {"treeSHA256", "entries"}, "embedded source inventory")
    require(
        digest(source["treeSHA256"], "embedded source tree digest")
        == source_inventory_digest(source["entries"]),
        "embedded source tree digest differs from its inventory",
    )
    require(bundle["capabilities"] == [{"id": "metal-probe", "version": 1}], "embedded capabilities are invalid")
    signing = exact_keys(bundle["signing"], {"classification", "teamIdentifier", "authority", "hardenedRuntime"}, "embedded signing")
    require(signing["classification"] == "developer-id-signed", "embedded bundle is not release signed")
    require(signing["teamIdentifier"] == EXPECTED_TEAM, "embedded bundle signing team is invalid")
    require(isinstance(signing["authority"], str) and signing["authority"].startswith("Developer ID Application:"), "embedded bundle authority is invalid")
    require(signing["hardenedRuntime"] is True, "embedded bundle lacks hardened runtime")
    return (json.dumps(bundle, indent=2, sort_keys=True) + "\n").encode("utf-8")


def verify_installer(package: Path) -> None:
    completed = subprocess.run(
        ["pkgutil", "--check-signature", str(package)],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    details = completed.stdout + completed.stderr
    require(completed.returncode == 0, "installer signature verification failed")
    require(
        "Developer ID Installer:" in details and f"({EXPECTED_TEAM})" in details,
        "installer package is not signed by the expected Dory Developer ID Installer team",
    )


def verify(package: Path, manifest_path: Path, candidate: str | None, commit: str | None) -> None:
    manifest, _ = load_object(manifest_path, "guest-tools package manifest")
    document = exact_keys(manifest, {
        "schema", "candidateID", "sourceCommit", "bundleManifestSHA256", "bundleManifest", "package",
    }, "guest-tools package manifest")
    require(document["schema"] == PACKAGE_SCHEMA, "guest-tools package manifest schema is invalid")
    observed_candidate = label(document["candidateID"], "candidate ID")
    observed_commit = document["sourceCommit"]
    require(isinstance(observed_commit, str) and re.fullmatch(r"[0-9a-f]{40}", observed_commit) is not None, "source commit is invalid")
    if candidate is not None:
        require(observed_candidate == candidate, "package manifest candidate differs from the expected candidate")
    if commit is not None:
        require(observed_commit == commit, "package manifest source commit differs from the expected source commit")
    embedded = verify_bundle(document["bundleManifest"], observed_candidate, observed_commit)
    require(digest(document["bundleManifestSHA256"], "bundle manifest digest") == sha256(embedded), "embedded bundle manifest digest is invalid")
    package_info = exact_keys(document["package"], {
        "filename", "sha256", "byteCount", "installLocation", "installerTeamIdentifier",
    }, "guest-tools package binding")
    require(package_info["filename"] == package.name and package.suffix == ".pkg", "package filename is invalid")
    expected_digest = digest(package_info["sha256"], "package digest")
    expected_bytes = positive(package_info["byteCount"], "package byte count")
    require(package_info["installLocation"] == "/Applications", "package install location is invalid")
    require(package_info["installerTeamIdentifier"] == EXPECTED_TEAM, "package installer team is invalid")
    payload = direct_regular(package, "guest-tools package")
    require(len(payload) == expected_bytes and sha256(payload) == expected_digest, "guest-tools package bytes differ from its manifest")
    verify_installer(package)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--package", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--candidate-id")
    parser.add_argument("--source-commit")
    arguments = parser.parse_args()
    try:
        expected_candidate = label(arguments.candidate_id, "expected candidate ID") if arguments.candidate_id else None
        expected_commit = arguments.source_commit
        if expected_commit is not None:
            require(re.fullmatch(r"[0-9a-f]{40}", expected_commit) is not None, "expected source commit is invalid")
        verify(arguments.package, arguments.manifest, expected_candidate, expected_commit)
    except (VerificationError, OSError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
