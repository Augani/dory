#!/usr/bin/env python3
"""Validate the exact guest-built GPU probe source and binary hash receipt."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys


SOURCE_FILES = {
    "visualChallengeHeaderSHA256": "dory-visual-challenge.h",
    "vulkanProbeSourceSHA256": "dory-vulkan-probe.c",
    "vulkanCompositorProbeSourceSHA256": "dory-vulkan-compositor-probe.c",
    "computeProbeSourceSHA256": "dory-compute-probe.c",
    "computeShaderSourceSHA256": "dory-compute-reduce.comp",
    "glProbeSourceSHA256": "dory-gl-probe.c",
}
BINARY_FILES = {
    "vulkanProbeBinarySHA256": "dory-vulkan-probe",
    "vulkanCompositorProbeBinarySHA256": "dory-vulkan-compositor-probe",
    "computeProbeBinarySHA256": "dory-compute-probe",
    "computeShaderBinarySHA256": "dory-compute-reduce.spv",
    "glProbeBinarySHA256": "dory-gl-probe",
}
IDENTITY_FIELDS = {
    "schema", "version", "architecture", "kernel", "compiler",
    "compositorSourceCommit", "visualChallengeEncoding", "output",
}
EXPECTED_FIELDS = IDENTITY_FIELDS | SOURCE_FILES.keys() | BINARY_FILES.keys()
SHA256 = re.compile(r"^[0-9a-f]{64}$")


class BuildReceiptError(ValueError):
    pass


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def validate(
    receipt_path: Path,
    *,
    source_directory: Path | None = None,
    binary_directory: Path | None = None,
    architecture: str | None = None,
) -> dict[str, str]:
    descriptor = os.open(receipt_path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise BuildReceiptError("build receipt must be a direct regular file")
        payload = source.read(16_385)
    return validate_payload(
        payload,
        source_directory=source_directory,
        binary_directory=binary_directory,
        architecture=architecture,
    )


def validate_payload(
    payload: bytes,
    *,
    source_directory: Path | None = None,
    binary_directory: Path | None = None,
    architecture: str | None = None,
) -> dict[str, str]:
    if not 0 < len(payload) <= 16_384:
        raise BuildReceiptError("build receipt byte count is outside the supported bound")
    try:
        lines = payload.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise BuildReceiptError(f"build receipt is not UTF-8: {error}") from error
    record: dict[str, str] = {}
    for line in lines:
        if "=" not in line:
            raise BuildReceiptError("build receipt contains a malformed field")
        key, value = line.split("=", 1)
        if key in record or key not in EXPECTED_FIELDS or not value:
            raise BuildReceiptError("build receipt has a duplicate, unknown, or empty field")
        if any(ord(character) < 32 or ord(character) > 126 for character in value):
            raise BuildReceiptError("build receipt contains a non-printable value")
        record[key] = value
    if record.keys() != EXPECTED_FIELDS:
        raise BuildReceiptError("build receipt fields are incomplete")
    if record["schema"] != "dev.dory.guest-probe-build" or record["version"] != "2":
        raise BuildReceiptError("build receipt schema/version is unsupported")
    if record["architecture"] not in {"aarch64", "x86_64"}:
        raise BuildReceiptError("build receipt architecture is unsupported")
    if architecture is not None and record["architecture"] != architecture:
        raise BuildReceiptError("build receipt architecture does not match the selected guest")
    if record["visualChallengeEncoding"] != "fnv1a64-frame16-grid12x10":
        raise BuildReceiptError("build receipt visual challenge encoding is unsupported")
    if any(len(record[key]) > 256 for key in ("kernel", "compiler", "compositorSourceCommit")):
        raise BuildReceiptError("build receipt toolchain or source identity is too long")
    if not Path(record["output"]).is_absolute() or len(record["output"]) > 4096:
        raise BuildReceiptError("build receipt output path is invalid")
    for key in SOURCE_FILES.keys() | BINARY_FILES.keys():
        if SHA256.fullmatch(record[key]) is None:
            raise BuildReceiptError(f"build receipt {key} is not a SHA-256 digest")
    for key in BINARY_FILES:
        if record[key] == "0" * 64:
            raise BuildReceiptError(f"build receipt {key} is an unset binary digest")
    for directory, files in (
        (source_directory, SOURCE_FILES), (binary_directory, BINARY_FILES)
    ):
        if directory is None:
            continue
        for key, name in files.items():
            path = directory / name
            if path.is_symlink() or not path.is_file() or digest(path) != record[key]:
                raise BuildReceiptError(f"build receipt {key} does not match {name}")
    return record


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receipt", type=Path)
    parser.add_argument("--source-directory", type=Path)
    parser.add_argument("--binary-directory", type=Path)
    parser.add_argument("--architecture", choices=("aarch64", "x86_64"))
    arguments = parser.parse_args()
    try:
        record = validate(
            arguments.receipt,
            source_directory=arguments.source_directory,
            binary_directory=arguments.binary_directory,
            architecture=arguments.architecture,
        )
    except (OSError, BuildReceiptError) as error:
        print(f"invalid Dory guest GPU probe build receipt: {error}", file=sys.stderr)
        return 1
    json.dump(record, sys.stdout, sort_keys=True, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
