#!/usr/bin/env python3
"""Validate the two native package inputs before assembling one architecture's tools ISO."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys


RECEIPT_SCHEMA = "dory.linux-guest-tools-native-build@1"
SET_SCHEMA = "dory.linux-guest-tools-native-package-set@1"
RECEIPT_KEYS = {
    "schema", "sourceCommit", "guestArchitecture", "format", "packageFile", "packageSHA256"
}
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
COMMIT = re.compile(r"[0-9a-f]{40}\Z")
SAFE_NAME = re.compile(r"[A-Za-z0-9._+~-]+\Z")
ARCHITECTURES = {"arm64": ("arm64", "aarch64"), "x86_64": ("amd64", "x86_64")}


class PackageSetError(ValueError):
    pass


@contextmanager
def direct_file(path: Path, *, maximum_bytes: int):
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as error:
        raise PackageSetError(f"missing input {path}: {error}") from error
    with os.fdopen(descriptor, "rb") as stream:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size <= 0:
            raise PackageSetError(f"input must be a nonempty direct regular file: {path}")
        if metadata.st_size > maximum_bytes:
            raise PackageSetError(f"input exceeds its size limit: {path}")
        yield stream


def package_digest(path: Path) -> str:
    with direct_file(path, maximum_bytes=1024 * 1024 * 1024) as stream:
        initial = os.fstat(stream.fileno())
        digest = hashlib.sha256()
        total = 0
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
            total += len(chunk)
        final = os.fstat(stream.fileno())
        if total != initial.st_size or (final.st_size, final.st_mtime_ns) != (
            initial.st_size, initial.st_mtime_ns
        ):
            raise PackageSetError(f"package changed during hashing: {path}")
        return digest.hexdigest()


def package_field(arguments: list[str]) -> str:
    try:
        result = subprocess.run(
            arguments, check=True, capture_output=True, text=True, timeout=15
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        raise PackageSetError(f"package metadata inspection failed: {arguments[0]}") from error
    return result.stdout.strip()


def validate_package(
    path: Path, package_format: str, *, portable_version: str | None = None
) -> dict[str, str]:
    digest = package_digest(path)
    if not SAFE_NAME.fullmatch(path.name):
        raise PackageSetError("package filename is unsafe")
    receipt_path = Path(f"{path}.build-receipt.json")
    try:
        with direct_file(receipt_path, maximum_bytes=4096) as stream:
            receipt = json.load(stream)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise PackageSetError(f"build receipt is invalid JSON: {receipt_path}") from error
    if not isinstance(receipt, dict) or set(receipt) != RECEIPT_KEYS:
        raise PackageSetError("build receipt fields are incomplete or unexpected")
    if receipt["schema"] != RECEIPT_SCHEMA or receipt["format"] != package_format:
        raise PackageSetError("build receipt schema or format is wrong")
    source_commit = receipt["sourceCommit"]
    architecture = receipt["guestArchitecture"]
    if not isinstance(source_commit, str) or not COMMIT.fullmatch(source_commit):
        raise PackageSetError("build receipt source commit is invalid")
    if not isinstance(architecture, str) or architecture not in ARCHITECTURES:
        raise PackageSetError("build receipt architecture is unsupported")
    if receipt["packageFile"] != path.name:
        raise PackageSetError("build receipt filename does not match the package")
    if not isinstance(receipt["packageSHA256"], str) or not SHA256.fullmatch(
        receipt["packageSHA256"]
    ) or receipt["packageSHA256"] != digest:
        raise PackageSetError("build receipt digest does not match the package")

    if portable_version is None:
        deb_arch, rpm_arch = ARCHITECTURES[architecture]
        if package_format == "deb":
            if package_field(["dpkg-deb", "--field", str(path), "Package"]) != "dory-guest-tools":
                raise PackageSetError("Debian package name is wrong")
            if package_field(["dpkg-deb", "--field", str(path), "Architecture"]) != deb_arch:
                raise PackageSetError("Debian package architecture is wrong")
            version = package_field(["dpkg-deb", "--field", str(path), "Version"]).split("-", 1)[0]
        else:
            if package_field(["rpm", "-qp", "--queryformat", "%{NAME}", str(path)]) \
                    != "dory-guest-tools":
                raise PackageSetError("RPM package name is wrong")
            if package_field(["rpm", "-qp", "--queryformat", "%{ARCH}", str(path)]) != rpm_arch:
                raise PackageSetError("RPM package architecture is wrong")
            version = package_field(["rpm", "-qp", "--queryformat", "%{VERSION}", str(path)])
    else:
        # The portable release check runs on macOS without dpkg/rpm. The package metadata was
        # checked when the ISO was assembled; here the signed manifest supplies its version.
        version = portable_version
    if not version or len(version) > 64 or not SAFE_NAME.fullmatch(version):
        raise PackageSetError("package version is invalid")
    return {
        "format": package_format,
        "packageFile": path.name,
        "nativePackageSHA256": digest,
        "sourceCommit": source_commit,
        "guestArchitecture": architecture,
        "version": version,
    }


def verify(
    deb: Path, rpm: Path, *, portable_version: str | None = None
) -> dict[str, object]:
    packages = [
        validate_package(deb, "deb", portable_version=portable_version),
        validate_package(rpm, "rpm", portable_version=portable_version),
    ]
    if packages[0]["sourceCommit"] != packages[1]["sourceCommit"]:
        raise PackageSetError("native packages come from different source commits")
    if packages[0]["guestArchitecture"] != packages[1]["guestArchitecture"]:
        raise PackageSetError("native packages target different guest architectures")
    if packages[0]["version"] != packages[1]["version"]:
        raise PackageSetError("native packages carry different tools versions")
    return {
        "schema": SET_SCHEMA,
        "sourceCommit": packages[0]["sourceCommit"],
        "guestArchitecture": packages[0]["guestArchitecture"],
        "version": packages[0]["version"],
        "packages": [
            {
                "format": item["format"],
                "packageFile": item["packageFile"],
                "nativePackageSHA256": item["nativePackageSHA256"],
            }
            for item in packages
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--deb", required=True, type=Path)
    parser.add_argument("--rpm", required=True, type=Path)
    parser.add_argument("--expected-source-commit")
    parser.add_argument("--expected-architecture", choices=tuple(ARCHITECTURES))
    parser.add_argument("--portable-manifest", type=Path)
    arguments = parser.parse_args()
    try:
        signed_manifest = None
        if arguments.portable_manifest is not None:
            with direct_file(arguments.portable_manifest, maximum_bytes=4096) as stream:
                signed_manifest = json.load(stream)
            if not isinstance(signed_manifest, dict) or set(signed_manifest) != {
                "schema", "sourceCommit", "guestArchitecture", "version", "packages"
            } or signed_manifest["schema"] != SET_SCHEMA:
                raise PackageSetError("portable native-build manifest schema is invalid")
            version = signed_manifest["version"]
            if not isinstance(version, str) or not version or len(version) > 64 \
                    or not SAFE_NAME.fullmatch(version):
                raise PackageSetError("portable native-build version is invalid")
        else:
            version = None
        manifest = verify(arguments.deb, arguments.rpm, portable_version=version)
        if signed_manifest is not None and manifest != signed_manifest:
            raise PackageSetError("portable native-build manifest differs from package receipts")
        if arguments.expected_source_commit is not None and (
            manifest["sourceCommit"] != arguments.expected_source_commit
        ):
            raise PackageSetError("native package source commit differs from the candidate")
        if arguments.expected_architecture is not None and (
            manifest["guestArchitecture"] != arguments.expected_architecture
        ):
            raise PackageSetError("native package architecture differs from the selected cell")
    except (PackageSetError, UnicodeError, json.JSONDecodeError) as error:
        print(f"native package set rejected: {error}", file=sys.stderr)
        return 1
    print(json.dumps(manifest, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
