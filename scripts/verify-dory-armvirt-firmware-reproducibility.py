#!/usr/bin/env python3
"""Build DoryARMVirt twice and require byte-identical firmware bundles."""

from __future__ import annotations

import argparse
import hashlib
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import List, Optional


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
BUILDER = REPOSITORY_ROOT / "scripts" / "build-dory-armvirt-firmware.py"
EXPECTED_FILES = (
    "firmware-code.fd",
    "manifest.json",
    "sbom.json",
    "variable-store-template.json",
)


class VerificationFailure(RuntimeError):
    pass


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--edk2-source",
        type=Path,
        help="verified local EDK II checkout used instead of fetching the pinned source",
    )
    return parser.parse_args()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build(destination: Path, local_source: Optional[Path]) -> None:
    command: List[str] = [sys.executable, str(BUILDER), "--output", str(destination)]
    if local_source is not None:
        command.extend(["--edk2-source", str(local_source.resolve())])
    subprocess.run(command, cwd=REPOSITORY_ROOT, check=True)


def verify_bundle(directory: Path) -> None:
    actual = tuple(sorted(path.name for path in directory.iterdir() if path.is_file()))
    if actual != tuple(sorted(EXPECTED_FILES)):
        raise VerificationFailure(f"unexpected bundle file set: {actual}")


def main() -> int:
    arguments = parse_arguments()
    with tempfile.TemporaryDirectory(prefix="dory-armvirt-reproducibility.") as root:
        root_path = Path(root)
        first = root_path / "first"
        second = root_path / "second"
        build(first, arguments.edk2_source)
        build(second, arguments.edk2_source)
        verify_bundle(first)
        verify_bundle(second)

        for name in EXPECTED_FILES:
            first_file = first / name
            second_file = second / name
            if first_file.read_bytes() != second_file.read_bytes():
                raise VerificationFailure(
                    f"{name} is not reproducible: "
                    f"{sha256(first_file)} != {sha256(second_file)}"
                )
            print(f"{sha256(first_file)}  {name}")
    print("DoryARMVirt firmware bundle is byte-for-byte reproducible")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, subprocess.CalledProcessError, VerificationFailure) as error:
        print(f"verify-dory-armvirt-firmware-reproducibility: {error}", file=sys.stderr)
        sys.exit(2)
