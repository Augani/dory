#!/usr/bin/env python3
"""Create a deterministic inventory for one staged Dory macOS Guest Tools bundle.

This does not sign, notarize, or qualify a guest tools package.  It binds the exact
bundle bytes to a candidate and source commit so the release packaging and guest
qualification stages have an auditable input instead of a hand-transcribed version.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile


EXPECTED_BUNDLE_IDENTIFIER = "com.pythonxi.Dory.GuestTools"
EXPECTED_TEAM_IDENTIFIER = "864H636QW4"
SOURCE_FILES = (
    "GuestTools/DoryGuestTools/DoryGuestMetalProbe.swift",
    "GuestTools/DoryGuestTools/DoryGuestToolsApp.swift",
    "GuestTools/DoryGuestTools/DoryGuestTools.entitlements",
    "GuestTools/METAL_PROBE.md",
)


class ManifestError(ValueError):
    pass


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def valid_label(value: str, maximum: int = 128) -> bool:
    return 1 <= len(value.encode("utf-8")) <= maximum and all(
        character.isascii() and (character.isalnum() or character in "._:-")
        for character in value
    )


def contained(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def read_regular(path: Path) -> bytes:
    status = path.lstat()
    if not stat.S_ISREG(status.st_mode):
        raise ManifestError(f"required file is not a regular file: {path}")
    return path.read_bytes()


def inventory_tree(root: Path) -> tuple[list[dict[str, object]], str]:
    entries: list[dict[str, object]] = []
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix().encode()):
        relative = path.relative_to(root).as_posix()
        metadata = path.lstat()
        if stat.S_ISDIR(metadata.st_mode):
            continue
        if stat.S_ISREG(metadata.st_mode):
            kind, payload = "regular", read_regular(path)
        elif stat.S_ISLNK(metadata.st_mode):
            target = os.readlink(path)
            if Path(target).is_absolute():
                raise ManifestError(f"bundle has an absolute symlink: {relative}")
            resolved = (path.parent / target).resolve(strict=True)
            if not contained(resolved, root):
                raise ManifestError(f"bundle symlink escapes bundle: {relative}")
            kind, payload = "symlink", target.encode("utf-8")
        else:
            raise ManifestError(f"bundle has an unsupported filesystem entry: {relative}")
        entry = {
            "path": relative,
            "type": kind,
            "mode": f"{stat.S_IMODE(metadata.st_mode):04o}",
            "byteCount": len(payload),
            "sha256": sha256(payload),
        }
        entries.append(entry)
        digest.update(
            f"{relative}\0{kind}\0{entry['mode']}\0{entry['byteCount']}\0{entry['sha256']}\n".encode()
        )
    if not entries:
        raise ManifestError("bundle inventory is empty")
    return entries, digest.hexdigest()


def source_inventory(root: Path) -> tuple[list[dict[str, str]], str]:
    entries: list[dict[str, str]] = []
    digest = hashlib.sha256()
    for relative in SOURCE_FILES:
        path = root / relative
        payload = read_regular(path)
        item = {"path": relative, "sha256": sha256(payload)}
        entries.append(item)
        digest.update(f"{relative}\0{item['sha256']}\n".encode())
    return entries, digest.hexdigest()


def signing(app: Path, allow_unsigned_development: bool) -> dict[str, object]:
    command = ["codesign", "-dvvv", str(app)]
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    verification = subprocess.run(
        ["codesign", "--verify", "--strict", "--deep", str(app)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    details = result.stdout + result.stderr
    fields: dict[str, list[str]] = {}
    for line in details.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            fields.setdefault(key.strip(), []).append(value.strip())
    team = fields.get("TeamIdentifier", [None])[-1]
    authorities = fields.get("Authority", [])
    hardened = any("runtime" in item for item in fields.get("CodeDirectory", []))
    developer_id = bool(authorities) and authorities[0].startswith("Developer ID Application:")
    if (result.returncode == 0 and verification.returncode == 0
            and team == EXPECTED_TEAM_IDENTIFIER and developer_id and hardened):
        return {
            "classification": "developer-id-signed",
            "teamIdentifier": team,
            "authority": authorities[0],
            "hardenedRuntime": True,
        }
    if allow_unsigned_development:
        return {"classification": "unsigned-development", "releaseEligible": False}
    raise ManifestError(
        "guest tools bundle must be Developer-ID-signed by Dory with hardened runtime; "
        "use --allow-unsigned-development only for a non-release development inventory"
    )


def atomic_write(path: Path, payload: bytes) -> None:
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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--candidate-id", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--allow-unsigned-development", action="store_true")
    arguments = parser.parse_args()
    try:
        if not valid_label(arguments.candidate_id):
            raise ManifestError("candidate ID must use 1–128 ASCII letters, digits, '.', '_', ':', or '-'")
        if len(arguments.source_commit) != 40 or any(character not in "0123456789abcdef" for character in arguments.source_commit):
            raise ManifestError("source commit must be a lowercase 40-character Git SHA")
        if arguments.app.name != "DoryGuestTools.app" or arguments.app.is_symlink() or not arguments.app.is_dir():
            raise ManifestError("app must be a non-symlink DoryGuestTools.app bundle")
        app = arguments.app.resolve(strict=True)
        output = arguments.output.resolve()
        if contained(output, app):
            raise ManifestError("output must remain outside the guest tools bundle")
        info = plistlib.loads(read_regular(app / "Contents/Info.plist"))
        if info.get("CFBundleIdentifier") != EXPECTED_BUNDLE_IDENTIFIER:
            raise ManifestError("bundle identifier is not Dory Guest Tools")
        executable = info.get("CFBundleExecutable")
        version = info.get("CFBundleShortVersionString")
        build = info.get("CFBundleVersion")
        if not all(isinstance(value, str) and valid_label(value, 64) for value in (executable, version, build)):
            raise ManifestError("bundle executable, version, and build must be bounded portable labels")
        binary = app / "Contents/MacOS" / executable
        read_regular(binary)
        bundle_entries, bundle_sha256 = inventory_tree(app)
        source_entries, source_sha256 = source_inventory(arguments.source_root.resolve(strict=True))
        document = {
            "schema": "dory.macos-guest-tools-manifest@1",
            "candidateID": arguments.candidate_id,
            "sourceCommit": arguments.source_commit,
            "bundle": {
                "identifier": EXPECTED_BUNDLE_IDENTIFIER,
                "version": version,
                "build": build,
                "treeSHA256": bundle_sha256,
                "entries": bundle_entries,
            },
            "source": {"treeSHA256": source_sha256, "entries": source_entries},
            "capabilities": [{"id": "metal-probe", "version": 1}],
            "signing": signing(app, arguments.allow_unsigned_development),
        }
        atomic_write(output, (json.dumps(document, indent=2, sort_keys=True) + "\n").encode())
    except (ManifestError, OSError, plistlib.InvalidFileException) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
