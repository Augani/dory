#!/usr/bin/env python3
"""Fail closed when a DoryFFI static-library object exceeds the supported macOS floor."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


class VerificationError(Exception):
    pass


VERSION = re.compile(r"^(\d+)(?:\.(\d+))?(?:\.(\d+))?$")


def fail(message: str) -> None:
    raise VerificationError(f"FFI deployment-target verification: {message}")


def version(value: str, *, label: str) -> tuple[int, int, int]:
    match = VERSION.fullmatch(value)
    if match is None:
        fail(f"{label} is not a macOS version: {value!r}")
    return tuple(int(component or 0) for component in match.groups())


def normalized_version(value: str, *, label: str) -> str:
    parsed = version(value, label=label)
    return f"{parsed[0]}.{parsed[1]}.{parsed[2]}"


def run(arguments: list[str], *, label: str, stdout=None) -> str:
    try:
        result = subprocess.run(
            arguments,
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE if stdout is None else stdout,
            stderr=subprocess.PIPE,
        )
    except OSError as error:
        fail(f"could not run {label}: {error}")
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        fail(f"{label} failed{(': ' + detail) if detail else ''}")
    return "" if stdout is not None else result.stdout.decode("utf-8", "replace")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def macos_minimum(vtool: str, architecture: str, object_path: Path) -> str:
    output = run(
        [vtool, "-arch", architecture, "-show-build", str(object_path)],
        label=f"vtool for {architecture} object {object_path.name}",
    )
    is_macos = False
    legacy_macos = False
    for line in output.splitlines():
        fields = line.split()
        if fields[:2] == ["platform", "MACOS"]:
            is_macos = True
            legacy_macos = False
            continue
        if is_macos and fields[:1] == ["minos"] and len(fields) == 2:
            return normalized_version(fields[1], label=f"minimum macOS for {object_path.name}")
        if fields[:2] == ["cmd", "LC_VERSION_MIN_MACOSX"]:
            legacy_macos = True
            is_macos = False
            continue
        if legacy_macos and fields[:1] == ["version"] and len(fields) == 2:
            return normalized_version(fields[1], label=f"minimum macOS for {object_path.name}")
    fail(f"{architecture} object {object_path.name} has no macOS minimum-version load command")


def object_records(
    *, library: Path, architecture: str, lipo: str, ar: str, vtool: str
) -> list[str]:
    with tempfile.TemporaryDirectory(prefix="dory-ffi-deployment-targets-") as temporary:
        root = Path(temporary)
        thin = root / f"libdory_ffi-{architecture}.a"
        run(
            [lipo, "-thin", architecture, str(library), "-output", str(thin)],
            label=f"thin {architecture} FFI archive",
        )
        members = [
            line
            for line in run([ar, "-t", str(thin)], label=f"list {architecture} FFI archive").splitlines()
            if line and not line.startswith("__.SYMDEF")
        ]
        if not members:
            fail(f"{architecture} FFI archive contains no objects")
        if len(set(members)) != len(members):
            fail(f"{architecture} FFI archive has duplicate member names; cannot inspect every object safely")

        minimums: list[str] = []
        for index, member in enumerate(members):
            destination = root / f"object-{index}"
            with destination.open("wb") as handle:
                run([ar, "-p", str(thin), member], label=f"extract {architecture} FFI object", stdout=handle)
            minimums.append(macos_minimum(vtool, architecture, destination))
        return minimums


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True, type=Path)
    parser.add_argument("--maximum-macos", required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--lipo", default="lipo")
    parser.add_argument("--ar", default="ar")
    parser.add_argument("--vtool", default="vtool")
    arguments = parser.parse_args()

    library = arguments.library.resolve()
    if not library.is_file() or library.is_symlink():
        fail("library must be a direct regular file")
    maximum = version(arguments.maximum_macos, label="maximum macOS")
    for name in (arguments.lipo, arguments.ar, arguments.vtool):
        if shutil.which(name) is None:
            fail(f"required tool is unavailable: {name}")

    architectures = run([arguments.lipo, "-archs", str(library)], label="read FFI archive architectures").split()
    if sorted(architectures) != ["arm64", "x86_64"]:
        fail(f"FFI archive architectures must be arm64 and x86_64, got: {' '.join(architectures) or 'none'}")

    observed = []
    for architecture in ("arm64", "x86_64"):
        minimums = object_records(
            library=library,
            architecture=architecture,
            lipo=arguments.lipo,
            ar=arguments.ar,
            vtool=arguments.vtool,
        )
        counts: dict[str, int] = {}
        for minimum in minimums:
            if version(minimum, label=f"{architecture} object minimum macOS") > maximum:
                fail(
                    f"{architecture} FFI object requires macOS {minimum}, above supported "
                    f"{normalized_version(arguments.maximum_macos, label='maximum macOS')}"
                )
            counts[minimum] = counts.get(minimum, 0) + 1
        observed.append({
            "architecture": architecture,
            "objectCount": len(minimums),
            "minimumMacOSCounts": dict(sorted(counts.items(), key=lambda item: version(item[0], label="observed macOS"))),
            "maximumMinimumMacOS": max(minimums, key=lambda item: version(item, label="observed macOS")),
        })

    result = {
        "kind": "dev.dory.ffi-deployment-targets",
        "schemaVersion": 1,
        "librarySHA256": sha256(library),
        "maximumSupportedMacOS": normalized_version(arguments.maximum_macos, label="maximum macOS"),
        "slices": observed,
    }
    encoded = (json.dumps(result, sort_keys=True, indent=2) + "\n").encode("utf-8")
    if arguments.output is None:
        print(encoded.decode("utf-8"), end="")
    else:
        if arguments.output.exists() and arguments.output.is_symlink():
            fail("output must not be a symbolic link")
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_bytes(encoded)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except VerificationError as error:
        raise SystemExit(str(error))
