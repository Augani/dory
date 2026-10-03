#!/usr/bin/env python3
"""Produce one signed, candidate-bound macOS Dory Guest Tools installer package.

The input app must already carry the Dory Developer ID Application signature.
This producer does not qualify a guest capability or make a release claim: it
creates an installable package and a portable manifest for a later candidate
qualification workflow.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_GENERATOR = ROOT / "scripts" / "generate-macos-guest-tools-manifest.py"
EXPECTED_INSTALLER_TEAM = "864H636QW4"
PACKAGE_SCHEMA = "dory.macos-guest-tools-package@3"
LOGIN_AGENT = ROOT / "GuestTools/Packaging/com.pythonxi.Dory.GuestTools.agent.plist"
LOGIN_AGENT_PATH = "/Library/LaunchAgents/com.pythonxi.Dory.GuestTools.agent.plist"
MAINTENANCE_HELPER = ROOT / "GuestTools/Packaging/dory-guest-tools-maintenance.sh"
MAINTENANCE_HELPER_PATH = "/Library/Application Support/Dory/GuestTools/dory-guest-tools-maintenance"


class PackageError(ValueError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def direct_regular(path: Path, label: str) -> Path:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise PackageError(f"{label} is unavailable: {path}") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise PackageError(f"{label} must be a direct regular file: {path}")
    return path


def bounded_text(value: str, label: str, maximum_bytes: int = 256) -> str:
    if not (1 <= len(value.encode("utf-8")) <= maximum_bytes) or any(
        ord(character) < 0x20 or ord(character) > 0x7E for character in value
    ):
        raise PackageError(f"{label} must be a bounded printable ASCII value")
    return value


def candidate_label(value: str, label: str) -> str:
    allowed = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-")
    if not (1 <= len(value.encode("utf-8")) <= 128) or any(character not in allowed for character in value):
        raise PackageError(f"{label} must use 1–128 ASCII letters, digits, '.', '_', ':', or '-'")
    return value


def source_commit(value: str) -> str:
    if len(value) != 40 or any(character not in "0123456789abcdef" for character in value):
        raise PackageError("source commit must be a lowercase 40-character Git SHA")
    return value


def output_path(path: Path, label: str) -> Path:
    if path.exists() and path.is_symlink():
        raise PackageError(f"{label} must not be a symbolic link: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    return path.parent.resolve(strict=True) / path.name


def write_atomic(path: Path, payload: bytes) -> None:
    output_path(path, "manifest output")
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


def command(arguments: list[str], label: str) -> str:
    completed = subprocess.run(
        arguments, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False
    )
    if completed.returncode != 0:
        raise PackageError(f"{label} failed: {(completed.stderr or completed.stdout).strip()}")
    return completed.stdout + completed.stderr


def verify_installer_signature(package: Path) -> None:
    details = command(["pkgutil", "--check-signature", str(package)], "installer signature verification")
    if "Developer ID Installer:" not in details or f"({EXPECTED_INSTALLER_TEAM})" not in details:
        raise PackageError(
            "installer package is not signed by the expected Dory Developer ID Installer team"
        )


def verify_payload_paths(package: Path) -> None:
    listing = command(["pkgutil", "--payload-files", str(package)], "installer payload inventory")
    paths = {line.removeprefix("./") for line in listing.splitlines()}
    required = {
        "Applications/DoryGuestTools.app/Contents/MacOS/DoryGuestTools",
        "Library/LaunchAgents/com.pythonxi.Dory.GuestTools.agent.plist",
        "Library/Application Support/Dory/GuestTools/dory-guest-tools-maintenance",
    }
    if not required.issubset(paths):
        raise PackageError("installer does not contain the guest app, login agent and maintenance helper")


def notarize_and_staple(package: Path, keychain_profile: str) -> str:
    completed = subprocess.run(
        [
            "xcrun", "notarytool", "submit", str(package),
            "--keychain-profile", keychain_profile,
            "--wait", "--timeout", "30m", "--output-format", "json",
        ],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        timeout=31 * 60,
    )
    if completed.returncode != 0:
        raise PackageError(f"notarization submission failed: {completed.stderr.strip()}")
    try:
        result = json.loads(completed.stdout)
        submission_id = str(uuid.UUID(result["id"]))
    except (TypeError, ValueError, KeyError, json.JSONDecodeError) as error:
        raise PackageError("notarytool did not return a valid submission ID") from error
    if result.get("status") != "Accepted":
        raise PackageError(f"notarization was not accepted: {result.get('status', 'unknown')}")
    command(["xcrun", "stapler", "staple", str(package)], "installer ticket stapling")
    command(["xcrun", "stapler", "validate", str(package)], "stapled ticket validation")
    command(["spctl", "--assess", "--type", "install", str(package)], "installer Gatekeeper assessment")
    return submission_id


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--candidate-id", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--installer-signing-identity", required=True)
    parser.add_argument("--notary-profile", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--manifest-output", required=True, type=Path)
    parser.add_argument("--source-root", type=Path, default=ROOT)
    arguments = parser.parse_args()

    try:
        candidate = candidate_label(arguments.candidate_id, "candidate ID")
        commit = source_commit(arguments.source_commit)
        identity = bounded_text(arguments.installer_signing_identity, "installer signing identity")
        notary_profile = candidate_label(arguments.notary_profile, "notary keychain profile")
        if arguments.app.name != "DoryGuestTools.app" or arguments.app.is_symlink() or not arguments.app.is_dir():
            raise PackageError("app must be a direct DoryGuestTools.app bundle")
        app = arguments.app.resolve(strict=True)
        output = output_path(arguments.output, "package output")
        manifest_output = output_path(arguments.manifest_output, "manifest output")
        if output.suffix != ".pkg":
            raise PackageError("package output must end in .pkg")
        if output == manifest_output or output in manifest_output.parents or manifest_output in output.parents:
            raise PackageError("package and manifest outputs must be separate")
        if app in output.parents or app in manifest_output.parents:
            raise PackageError("package outputs must remain outside the guest-tools app bundle")
        direct_regular(MANIFEST_GENERATOR, "guest-tools manifest generator")
        login_agent = direct_regular(LOGIN_AGENT, "guest-tools login agent")
        agent_bytes = login_agent.read_bytes()
        maintenance_helper = direct_regular(MAINTENANCE_HELPER, "guest-tools maintenance helper")
        helper_source = maintenance_helper.read_text(encoding="utf-8")
        helper_agent_digest = re.search(r"^AGENT_SHA256=([0-9a-f]{64})$", helper_source, re.MULTILINE)
        if helper_agent_digest is None or helper_agent_digest.group(1) != hashlib.sha256(agent_bytes).hexdigest():
            raise PackageError("guest-tools maintenance helper does not bind the current login agent")
        try:
            agent = plistlib.loads(agent_bytes)
        except (ValueError, TypeError) as error:
            raise PackageError("guest-tools login agent is not a valid property list") from error
        if agent != {
            "Label": "com.pythonxi.Dory.GuestTools.agent",
            "ProgramArguments": [
                "/Applications/DoryGuestTools.app/Contents/MacOS/DoryGuestTools",
                "--integration-agent",
            ],
            "LimitLoadToSessionType": "Aqua",
            "RunAtLoad": True,
            "KeepAlive": {"SuccessfulExit": False},
            "ThrottleInterval": 15,
        }:
            raise PackageError("guest-tools login agent has an unexpected authority or launch contract")

        with tempfile.TemporaryDirectory(prefix=".dory-guest-tools-package-", dir=output.parent) as temporary:
            staging = Path(temporary)
            bundle_manifest = staging / "bundle-manifest.json"
            command([
                sys.executable, str(MANIFEST_GENERATOR), "--app", str(app),
                "--candidate-id", candidate, "--source-commit", commit,
                "--source-root", str(arguments.source_root.resolve(strict=True)),
                "--output", str(bundle_manifest),
            ], "signed guest-tools bundle inventory")
            manifest_bytes = direct_regular(bundle_manifest, "guest-tools bundle manifest").read_bytes()
            try:
                bundle = json.loads(manifest_bytes)
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                raise PackageError("guest-tools bundle manifest is not valid JSON") from error
            if not isinstance(bundle, dict) or bundle.get("candidateID") != candidate or bundle.get("sourceCommit") != commit:
                raise PackageError("guest-tools bundle manifest does not bind this candidate and source commit")

            staged_package = staging / output.name
            payload_root = staging / "payload"
            applications = payload_root / "Applications"
            applications.mkdir(parents=True)
            shutil.copytree(app, applications / app.name, symlinks=True)
            launch_agents = payload_root / "Library/LaunchAgents"
            launch_agents.mkdir(parents=True)
            shutil.copy2(login_agent, launch_agents / login_agent.name)
            maintenance_directory = payload_root / MAINTENANCE_HELPER_PATH.lstrip("/")
            maintenance_directory.parent.mkdir(parents=True)
            shutil.copy2(maintenance_helper, maintenance_directory)
            maintenance_directory.chmod(0o755)
            command([
                "pkgbuild", "--root", str(payload_root), "--install-location", "/",
                "--identifier", "com.pythonxi.Dory.GuestTools.pkg",
                "--version", bundle["bundle"]["version"],
                "--ownership", "recommended", "--sign", identity,
                str(staged_package),
            ], "signed guest-tools package build")
            direct_regular(staged_package, "signed guest-tools package")
            if staged_package.stat().st_size == 0:
                raise PackageError("signed guest-tools package is empty")
            verify_installer_signature(staged_package)
            verify_payload_paths(staged_package)
            submission_id = notarize_and_staple(staged_package, notary_profile)
            verify_installer_signature(staged_package)
            package_bytes = staged_package.stat().st_size
            package_digest = sha256(staged_package)
            package_manifest = {
                "schema": PACKAGE_SCHEMA,
                "candidateID": candidate,
                "sourceCommit": commit,
                "bundleManifestSHA256": hashlib.sha256(manifest_bytes).hexdigest(),
                "bundleManifest": bundle,
                "notarization": {
                    "status": "stapled",
                    "submissionID": submission_id,
                },
                "package": {
                    "filename": output.name,
                    "sha256": package_digest,
                    "byteCount": package_bytes,
                    "installLocation": "/",
                    "installedAppPath": "/Applications/DoryGuestTools.app",
                    "installerTeamIdentifier": EXPECTED_INSTALLER_TEAM,
                },
                "loginAgent": {
                    "path": LOGIN_AGENT_PATH,
                    "label": agent["Label"],
                    "sha256": hashlib.sha256(agent_bytes).hexdigest(),
                },
            }
            staged_manifest = staging / manifest_output.name
            staged_manifest.write_bytes(
                (json.dumps(package_manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
            )
            os.replace(staged_manifest, manifest_output)
            os.replace(staged_package, output)
    except (PackageError, OSError, subprocess.TimeoutExpired) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
