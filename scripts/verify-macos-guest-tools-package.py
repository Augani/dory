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
    digest(app["treeSHA256"], "embedded bundle tree digest")
    require(isinstance(app["entries"], list) and app["entries"], "embedded bundle inventory is invalid")
    source = exact_keys(bundle["source"], {"treeSHA256", "entries"}, "embedded source inventory")
    digest(source["treeSHA256"], "embedded source tree digest")
    require(isinstance(source["entries"], list) and source["entries"], "embedded source inventory is invalid")
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
