#!/usr/bin/env python3
"""Create and verify doryd's signed, embedded renderer release identity."""

from __future__ import annotations

import argparse
import os
import pathlib
import plistlib
import re
import stat
import struct
import subprocess
import sys
from typing import NoReturn


PRODUCTION_TEAM_IDENTIFIER = "864H636QW4"
RUNNER_IDENTIFIER = "com.pythonxi.Dory.HVRunner"
RUNNER_EXECUTABLE = "dory-hv"
WORKER_IDENTIFIER = "com.pythonxi.Dory.HVRunner.RendererWorker"
WORKER_EXECUTABLE = "DoryRendererWorker"
DORYD_IDENTIFIER = "doryd"
IDENTITY_SEGMENT_NAME = "__TEXT"
IDENTITY_SECTION_NAME = "__doryid"
IDENTITY_SCHEMA_VERSION = 1
IDENTITY_KEYS = frozenset({
    "schema-version",
    "runner-cdhash",
    "renderer-worker-cdhash",
    "tuple-definition-sha256",
})
HASH_40 = re.compile(r"[0-9a-f]{40}")
HASH_64 = re.compile(r"[0-9a-f]{64}")
CODESIGN = "/usr/bin/codesign"
LIPO = "/usr/bin/lipo"
MAX_PLIST_BYTES = 1024 * 1024


class ReleaseIdentityError(RuntimeError):
    pass


def fail(message: str) -> NoReturn:
    raise ReleaseIdentityError(message)


def command_output(arguments: list[str], label: str) -> str:
    try:
        result = subprocess.run(
            arguments,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        detail = ""
        if isinstance(error, subprocess.CalledProcessError) and error.stdout:
            detail = f": {error.stdout.strip()}"
        fail(f"{label} failed{detail}")
    return result.stdout


def direct_directory(path: pathlib.Path, label: str) -> pathlib.Path:
    try:
        status = path.lstat()
    except OSError as error:
        fail(f"{label} is unavailable: {error}")
    if not stat.S_ISDIR(status.st_mode) or path.is_symlink():
        fail(f"{label} must be a direct directory")
    return path


def direct_regular_file(
    path: pathlib.Path, label: str, *, executable: bool = False
) -> pathlib.Path:
    try:
        status = path.lstat()
    except OSError as error:
        fail(f"{label} is unavailable: {error}")
    if (
        not stat.S_ISREG(status.st_mode)
        or path.is_symlink()
        or status.st_nlink != 1
        or status.st_size <= 0
    ):
        fail(f"{label} must be a nonempty direct regular file with one link")
    if executable and status.st_mode & 0o111 == 0:
        fail(f"{label} must be executable")
    return path


def read_plist(path: pathlib.Path, label: str) -> dict[str, object]:
    direct_regular_file(path, label)
    try:
        raw = path.read_bytes()
        if len(raw) > MAX_PLIST_BYTES:
            fail(f"{label} exceeds the bounded plist size")
        value = plistlib.loads(raw)
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"{label} is invalid: {error}")
    if not isinstance(value, dict):
        fail(f"{label} root must be a dictionary")
    return value


def validate_bundle_identity(
    bundle: pathlib.Path,
    *,
    identifier: str,
    executable: str,
    package_type: str,
    label: str,
) -> pathlib.Path:
    direct_directory(bundle, label)
    contents = direct_directory(bundle / "Contents", f"{label} Contents")
    macos = direct_directory(contents / "MacOS", f"{label} MacOS")
    info = read_plist(contents / "Info.plist", f"{label} Info.plist")
    expected = {
        "CFBundleIdentifier": identifier,
        "CFBundleExecutable": executable,
        "CFBundlePackageType": package_type,
    }
    for key, value in expected.items():
        if info.get(key) != value:
            fail(f"{label} {key} must be {value}")
    return direct_regular_file(
        macos / executable, f"{label} executable", executable=True
    )


def verify_exact_arm64(path: pathlib.Path, label: str) -> None:
    architectures = command_output(
        [LIPO, "-archs", os.fspath(path)], f"inspect {label} architectures"
    ).split()
    if architectures != ["arm64"]:
        fail(f"{label} must contain exactly the arm64 architecture")


def exact_detail_values(details: str, field: str) -> list[str]:
    prefix = f"{field}="
    return [line[len(prefix):] for line in details.splitlines() if line.startswith(prefix)]


def parse_production_signature_details(
    details: str,
    *,
    label: str,
    expected_identifier: str,
    expected_team: str,
) -> str:
    if expected_team != PRODUCTION_TEAM_IDENTIFIER:
        fail(
            f"{label} expected team must be Dory production team "
            f"{PRODUCTION_TEAM_IDENTIFIER}"
        )
    identifiers = exact_detail_values(details, "Identifier")
    if identifiers != [expected_identifier]:
        fail(f"{label} signing identifier must be exactly {expected_identifier}")
    teams = exact_detail_values(details, "TeamIdentifier")
    if teams != [expected_team]:
        fail(f"{label} must be signed by production team {expected_team}")
    authorities = exact_detail_values(details, "Authority")
    if not authorities or not authorities[0].startswith("Developer ID Application:"):
        fail(f"{label} must use a Developer ID Application identity")
    if len(exact_detail_values(details, "Timestamp")) != 1:
        fail(f"{label} must carry one secure signing timestamp")
    code_directories = [
        line for line in details.splitlines() if line.startswith("CodeDirectory ")
    ]
    if len(code_directories) != 1 or not re.search(
        r"flags=0x[0-9a-fA-F]+\([^)]*\bruntime\b[^)]*\)", code_directories[0]
    ):
        fail(f"{label} must be sealed with the hardened runtime")
    hashes = exact_detail_values(details, "CDHash")
    if len(hashes) != 1:
        fail(f"{label} must expose exactly one Code Directory hash")
    cdhash = hashes[0]
    if not HASH_40.fullmatch(cdhash) or cdhash == "0" * 40:
        fail(f"{label} Code Directory hash must be nonzero canonical 40-hex")
    return cdhash


def verify_production_signature(
    path: pathlib.Path,
    *,
    label: str,
    expected_identifier: str,
    expected_team: str,
    deep: bool = False,
) -> str:
    arguments = [CODESIGN, "--verify", "--strict"]
    if deep:
        arguments.append("--deep")
    requirement = (
        f'anchor apple generic and identifier "{expected_identifier}" and '
        f'certificate leaf[subject.OU] = "{expected_team}"'
    )
    arguments.append(f"-R={requirement}")
    arguments.append(os.fspath(path))
    command_output(arguments, f"verify {label} signature")
    details = command_output(
        [CODESIGN, "-d", "--verbose=4", os.fspath(path)],
        f"inspect {label} signature",
    )
    return parse_production_signature_details(
        details,
        label=label,
        expected_identifier=expected_identifier,
        expected_team=expected_team,
    )


def verify_runner_graph(
    runner: pathlib.Path, expected_team: str
) -> tuple[str, str]:
    runner_executable = validate_bundle_identity(
        runner,
        identifier=RUNNER_IDENTIFIER,
        executable=RUNNER_EXECUTABLE,
        package_type="APPL",
        label="DoryHVRunner.app",
    )
    worker = runner / "Contents" / "XPCServices" / "DoryRendererWorker.xpc"
    worker_executable = validate_bundle_identity(
        worker,
        identifier=WORKER_IDENTIFIER,
        executable=WORKER_EXECUTABLE,
        package_type="XPC!",
        label="DoryRendererWorker.xpc",
    )
    verify_exact_arm64(runner_executable, "DoryHVRunner.app executable")
    verify_exact_arm64(worker_executable, "DoryRendererWorker.xpc executable")
    worker_cdhash = verify_production_signature(
        worker,
        label="DoryRendererWorker.xpc",
        expected_identifier=WORKER_IDENTIFIER,
        expected_team=expected_team,
    )
    runner_cdhash = verify_production_signature(
        runner,
        label="DoryHVRunner.app",
        expected_identifier=RUNNER_IDENTIFIER,
        expected_team=expected_team,
        deep=True,
    )
    return runner_cdhash, worker_cdhash


def parse_tuple_definition_digest(output: str) -> str:
    values = exact_detail_values(output, "definition.sha256")
    if len(values) != 1 or not HASH_64.fullmatch(values[0]) or values[0] == "0" * 64:
        fail("renderer tuple verifier did not return one canonical nonzero SHA-256")
    return values[0]


def tuple_definition_digest(repo_root: pathlib.Path) -> str:
    tool = direct_regular_file(
        repo_root / "scripts" / "renderer-production-tuple.py",
        "renderer tuple verifier",
    )
    definition = direct_regular_file(
        repo_root / "Config" / "DoryRendererProductionTuple.json",
        "renderer tuple definition",
    )
    output = command_output(
        [
            sys.executable,
            os.fspath(tool),
            "--definition",
            os.fspath(definition),
            "verify-definition",
            "--repo-root",
            os.fspath(repo_root),
        ],
        "verify renderer tuple definition",
    )
    return parse_tuple_definition_digest(output)


def release_identity_payload(
    *, runner_cdhash: str, worker_cdhash: str, tuple_digest: str
) -> dict[str, object]:
    for value, label in (
        (runner_cdhash, "runner-cdhash"),
        (worker_cdhash, "renderer-worker-cdhash"),
    ):
        if not HASH_40.fullmatch(value) or value == "0" * 40:
            fail(f"{label} must be nonzero canonical 40-hex")
    if not HASH_64.fullmatch(tuple_digest) or tuple_digest == "0" * 64:
        fail("tuple-definition-sha256 must be nonzero canonical 64-hex")
    return {
        "schema-version": IDENTITY_SCHEMA_VERSION,
        "runner-cdhash": runner_cdhash,
        "renderer-worker-cdhash": worker_cdhash,
        "tuple-definition-sha256": tuple_digest,
    }


def validate_release_identity_payload(
    value: dict[str, object], expected: dict[str, object]
) -> None:
    if set(value) != IDENTITY_KEYS:
        fail("doryd renderer release identity has a noncanonical key set")
    if type(value.get("schema-version")) is not int:  # bool is not an integer here.
        fail("doryd renderer release identity schema-version must be an integer")
    for field in (
        "runner-cdhash",
        "renderer-worker-cdhash",
        "tuple-definition-sha256",
    ):
        if type(value.get(field)) is not str:
            fail(f"doryd renderer release identity {field} must be a string")
    if value != expected:
        fail("doryd renderer release identity differs from the final signed graph")


def canonical_identity_bytes(value: dict[str, object]) -> bytes:
    return plistlib.dumps(value, fmt=plistlib.FMT_XML, sort_keys=True)


def write_identity_plist(path: pathlib.Path, value: dict[str, object]) -> None:
    direct_directory(path.parent, "identity temporary directory")
    raw = canonical_identity_bytes(value)
    try:
        with path.open("xb") as handle:
            handle.write(raw)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(path, 0o600)
    except OSError as error:
        fail(f"cannot create canonical temporary doryd identity: {error}")
    if path.read_bytes() != raw:
        fail("canonical temporary doryd identity changed after creation")
    validate_release_identity_payload(read_plist(path, "doryd identity"), value)


def read_signed_entitlements(
    path: pathlib.Path, label: str, *, allow_empty: bool = False
) -> dict[str, object]:
    try:
        result = subprocess.run(
            [CODESIGN, "-d", "--entitlements", ":-", os.fspath(path)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if allow_empty and not result.stdout:
            return {}
        value = plistlib.loads(result.stdout)
    except (OSError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        fail(f"inspect {label} entitlements failed: {error}")
    if not isinstance(value, dict):
        fail(f"{label} entitlements root must be a dictionary")
    return value


def decode_macho_name(raw: bytes) -> str:
    try:
        return raw.split(b"\0", 1)[0].decode("ascii")
    except UnicodeDecodeError as error:
        fail(f"Mach-O section name is not ASCII: {error}")


def read_identity_from_thin_macho(raw: bytes) -> bytes | None:
    if len(raw) < 32:
        fail("doryd Mach-O header is truncated")
    magic, _, _, _, command_count, command_bytes, _, _ = struct.unpack_from(
        "<IiiIIIII", raw, 0
    )
    if magic != 0xFEEDFACF:
        fail("doryd release identity requires a thin little-endian 64-bit Mach-O")
    commands_end = 32 + command_bytes
    if commands_end > len(raw):
        fail("doryd Mach-O load-command table is truncated")

    matches: list[bytes] = []
    cursor = 32
    for _ in range(command_count):
        if cursor + 8 > commands_end:
            fail("doryd Mach-O load command is truncated")
        command, command_size = struct.unpack_from("<II", raw, cursor)
        if command_size < 8 or cursor + command_size > commands_end:
            fail("doryd Mach-O load command has an invalid size")
        if command == 0x19:  # LC_SEGMENT_64
            if command_size < 72:
                fail("doryd LC_SEGMENT_64 command is truncated")
            segment_name = decode_macho_name(raw[cursor + 8:cursor + 24])
            section_count = struct.unpack_from("<I", raw, cursor + 64)[0]
            expected_size = 72 + section_count * 80
            if expected_size > command_size:
                fail("doryd LC_SEGMENT_64 section table is truncated")
            section_cursor = cursor + 72
            for _ in range(section_count):
                section_name = decode_macho_name(
                    raw[section_cursor:section_cursor + 16]
                )
                declared_segment = decode_macho_name(
                    raw[section_cursor + 16:section_cursor + 32]
                )
                section_size = struct.unpack_from("<Q", raw, section_cursor + 40)[0]
                section_offset = struct.unpack_from("<I", raw, section_cursor + 48)[0]
                if (
                    segment_name == IDENTITY_SEGMENT_NAME
                    and declared_segment == IDENTITY_SEGMENT_NAME
                    and section_name == IDENTITY_SECTION_NAME
                ):
                    end = section_offset + section_size
                    if (
                        section_size == 0
                        or section_size > MAX_PLIST_BYTES
                        or section_offset < commands_end
                        or end > len(raw)
                    ):
                        fail("doryd embedded renderer identity has invalid bounds")
                    matches.append(raw[section_offset:end])
                section_cursor += 80
        cursor += command_size
    if cursor != commands_end:
        fail("doryd Mach-O load-command sizes are noncanonical")
    if len(matches) > 1:
        fail("doryd contains duplicate renderer release-identity sections")
    return matches[0] if matches else None


def macho_slices(raw: bytes) -> list[bytes]:
    if len(raw) < 8:
        fail("doryd Mach-O container is truncated")
    big_magic = struct.unpack_from(">I", raw, 0)[0]
    little_magic = struct.unpack_from("<I", raw, 0)[0]
    if little_magic == 0xFEEDFACF:
        return [raw]
    if big_magic in {0xCAFEBABE, 0xCAFEBABF}:
        endian = ">"
        is_64 = big_magic == 0xCAFEBABF
    elif little_magic in {0xCAFEBABE, 0xCAFEBABF}:
        endian = "<"
        is_64 = little_magic == 0xCAFEBABF
    else:
        fail("doryd release identity requires a 64-bit Mach-O")

    architecture_count = struct.unpack_from(endian + "I", raw, 4)[0]
    if architecture_count == 0 or architecture_count > 32:
        fail("doryd universal Mach-O has an invalid architecture count")
    entry_size = 32 if is_64 else 20
    table_end = 8 + architecture_count * entry_size
    if table_end > len(raw):
        fail("doryd universal Mach-O architecture table is truncated")
    slices: list[bytes] = []
    occupied: list[tuple[int, int]] = []
    cursor = 8
    for _ in range(architecture_count):
        if is_64:
            _, _, offset, size, _, _ = struct.unpack_from(
                endian + "iiQQII", raw, cursor
            )
        else:
            _, _, offset, size, _ = struct.unpack_from(
                endian + "iiIII", raw, cursor
            )
        end = offset + size
        if size == 0 or offset < table_end or end > len(raw):
            fail("doryd universal Mach-O slice has invalid bounds")
        if any(offset < prior_end and prior_offset < end
               for prior_offset, prior_end in occupied):
            fail("doryd universal Mach-O slices overlap")
        occupied.append((offset, end))
        slices.append(raw[offset:end])
        cursor += entry_size
    return slices


def read_embedded_identity_bytes(path: pathlib.Path) -> bytes | None:
    """Return the consistent __TEXT,__doryid section without invoking a tool."""
    raw = direct_regular_file(path, "doryd", executable=True).read_bytes()
    sections = [read_identity_from_thin_macho(value) for value in macho_slices(raw)]
    present = [value for value in sections if value is not None]
    if not present:
        return None
    if len(present) != len(sections):
        fail("doryd renderer release identity is missing from one Mach-O slice")
    if any(value != present[0] for value in present[1:]):
        fail("doryd renderer release identity differs across Mach-O slices")
    return present[0]


def read_embedded_identity(path: pathlib.Path) -> dict[str, object] | None:
    raw = read_embedded_identity_bytes(path)
    if raw is None:
        return None
    try:
        value = plistlib.loads(raw)
    except plistlib.InvalidFileException as error:
        fail(f"doryd embedded renderer identity is not a plist: {error}")
    if not isinstance(value, dict):
        fail("doryd embedded renderer identity root must be a dictionary")
    if canonical_identity_bytes(value) != raw:
        fail("doryd embedded renderer identity is not canonical XML")
    return value


def create_identity_plist(arguments: argparse.Namespace) -> None:
    runner_cdhash, worker_cdhash = verify_runner_graph(
        arguments.runner_app, arguments.expected_team
    )
    tuple_digest = tuple_definition_digest(arguments.repo_root)
    value = release_identity_payload(
        runner_cdhash=runner_cdhash,
        worker_cdhash=worker_cdhash,
        tuple_digest=tuple_digest,
    )
    write_identity_plist(arguments.output, value)
    print(f"renderer.release-identity.runner-cdhash={runner_cdhash}")
    print(f"renderer.release-identity.worker-cdhash={worker_cdhash}")
    print(f"renderer.release-identity.tuple-definition-sha256={tuple_digest}")
    print(f"renderer.release-identity.plist={arguments.output}")


def verify_identity(arguments: argparse.Namespace) -> None:
    doryd = direct_regular_file(arguments.doryd, "doryd", executable=True)
    verify_exact_arm64(doryd, "doryd")
    runner_cdhash, worker_cdhash = verify_runner_graph(
        arguments.runner_app, arguments.expected_team
    )
    tuple_digest = tuple_definition_digest(arguments.repo_root)
    expected = release_identity_payload(
        runner_cdhash=runner_cdhash,
        worker_cdhash=worker_cdhash,
        tuple_digest=tuple_digest,
    )
    verify_production_signature(
        doryd,
        label="doryd",
        expected_identifier=DORYD_IDENTIFIER,
        expected_team=arguments.expected_team,
    )
    if read_signed_entitlements(doryd, "doryd", allow_empty=True):
        fail("production doryd must not carry custom entitlements")
    embedded = read_embedded_identity(doryd)
    if embedded is None:
        fail("production doryd omits its embedded renderer release identity")
    validate_release_identity_payload(embedded, expected)
    print(f"renderer.release-identity.runner-cdhash={runner_cdhash}")
    print(f"renderer.release-identity.worker-cdhash={worker_cdhash}")
    print(f"renderer.release-identity.tuple-definition-sha256={tuple_digest}")
    print("renderer.release-identity=verified-production")


def verify_absent(arguments: argparse.Namespace) -> None:
    doryd = direct_regular_file(arguments.doryd, "doryd", executable=True)
    command_output([CODESIGN, "--verify", "--strict", os.fspath(doryd)], "verify doryd")
    entitlements = read_signed_entitlements(doryd, "doryd", allow_empty=True)
    if entitlements:
        fail("non-production doryd must not carry any signed entitlements")
    if read_embedded_identity(doryd) is not None:
        fail("non-production doryd must not carry a renderer release identity section")
    print("renderer.release-identity=absent-fail-closed")


def parser() -> argparse.ArgumentParser:
    repo_root = pathlib.Path(__file__).resolve().parent.parent
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)

    create = commands.add_parser("create-plist")
    create.add_argument("--runner-app", required=True, type=pathlib.Path)
    create.add_argument("--output", required=True, type=pathlib.Path)
    create.add_argument("--expected-team", default=PRODUCTION_TEAM_IDENTIFIER)
    create.add_argument("--repo-root", type=pathlib.Path, default=repo_root)

    verify = commands.add_parser("verify")
    verify.add_argument("--runner-app", required=True, type=pathlib.Path)
    verify.add_argument("--doryd", required=True, type=pathlib.Path)
    verify.add_argument("--expected-team", default=PRODUCTION_TEAM_IDENTIFIER)
    verify.add_argument("--repo-root", type=pathlib.Path, default=repo_root)

    absent = commands.add_parser("verify-absent")
    absent.add_argument("--doryd", required=True, type=pathlib.Path)
    return result


def main() -> int:
    arguments = parser().parse_args()
    if arguments.command in {"create-plist", "verify"}:
        if arguments.expected_team != PRODUCTION_TEAM_IDENTIFIER:
            fail(
                "renderer release identity can only bind Dory production team "
                f"{PRODUCTION_TEAM_IDENTIFIER}"
            )
        arguments.repo_root = arguments.repo_root.resolve(strict=True)
    if arguments.command == "create-plist":
        create_identity_plist(arguments)
    elif arguments.command == "verify":
        verify_identity(arguments)
    elif arguments.command == "verify-absent":
        verify_absent(arguments)
    else:  # argparse makes this unreachable.
        fail("unsupported command")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ReleaseIdentityError) as error:
        print(f"renderer-release-identity: {error}", file=sys.stderr)
        raise SystemExit(1)
