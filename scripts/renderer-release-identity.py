#!/usr/bin/env python3
"""Create and verify doryd's directed production renderer release identity."""

from __future__ import annotations

import argparse
import os
import pathlib
import plistlib
import re
import stat
import subprocess
import sys
from typing import NoReturn


PRODUCTION_TEAM_IDENTIFIER = "864H636QW4"
RUNNER_IDENTIFIER = "com.pythonxi.Dory.HVRunner"
RUNNER_EXECUTABLE = "dory-hv"
WORKER_IDENTIFIER = "com.pythonxi.Dory.HVRunner.RendererWorker"
WORKER_EXECUTABLE = "DoryRendererWorker"
DORYD_IDENTIFIER = "doryd"
ENTITLEMENT_NAME = "com.pythonxi.dory.renderer-release-identity.v1"
ENTITLEMENT_SCHEMA_VERSION = 1
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


def release_identity_entitlements(
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
        ENTITLEMENT_NAME: {
            "schema-version": ENTITLEMENT_SCHEMA_VERSION,
            "runner-cdhash": runner_cdhash,
            "renderer-worker-cdhash": worker_cdhash,
            "tuple-definition-sha256": tuple_digest,
        }
    }


def validate_release_identity_entitlements(
    value: dict[str, object], expected: dict[str, object]
) -> None:
    if set(value) != {ENTITLEMENT_NAME}:
        fail("doryd entitlement top level must contain only the renderer release identity")
    nested = value.get(ENTITLEMENT_NAME)
    if not isinstance(nested, dict) or set(nested) != IDENTITY_KEYS:
        fail("doryd renderer release identity has a noncanonical key set")
    if type(nested.get("schema-version")) is not int:  # bool is not an integer here.
        fail("doryd renderer release identity schema-version must be an integer")
    for field in (
        "runner-cdhash",
        "renderer-worker-cdhash",
        "tuple-definition-sha256",
    ):
        if type(nested.get(field)) is not str:
            fail(f"doryd renderer release identity {field} must be a string")
    if value != expected:
        fail("doryd renderer release identity differs from the final signed graph")


def canonical_entitlement_bytes(value: dict[str, object]) -> bytes:
    return plistlib.dumps(value, fmt=plistlib.FMT_XML, sort_keys=True)


def write_entitlements(path: pathlib.Path, value: dict[str, object]) -> None:
    direct_directory(path.parent, "entitlement temporary directory")
    raw = canonical_entitlement_bytes(value)
    try:
        with path.open("xb") as handle:
            handle.write(raw)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(path, 0o600)
    except OSError as error:
        fail(f"cannot create canonical temporary doryd entitlement: {error}")
    if path.read_bytes() != raw:
        fail("canonical temporary doryd entitlement changed after creation")
    validate_release_identity_entitlements(read_plist(path, "doryd entitlement"), value)


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


def create_entitlements(arguments: argparse.Namespace) -> None:
    runner_cdhash, worker_cdhash = verify_runner_graph(
        arguments.runner_app, arguments.expected_team
    )
    tuple_digest = tuple_definition_digest(arguments.repo_root)
    value = release_identity_entitlements(
        runner_cdhash=runner_cdhash,
        worker_cdhash=worker_cdhash,
        tuple_digest=tuple_digest,
    )
    write_entitlements(arguments.output, value)
    print(f"renderer.release-identity.runner-cdhash={runner_cdhash}")
    print(f"renderer.release-identity.worker-cdhash={worker_cdhash}")
    print(f"renderer.release-identity.tuple-definition-sha256={tuple_digest}")
    print(f"renderer.release-identity.entitlements={arguments.output}")


def verify_identity(arguments: argparse.Namespace) -> None:
    doryd = direct_regular_file(arguments.doryd, "doryd", executable=True)
    verify_exact_arm64(doryd, "doryd")
    runner_cdhash, worker_cdhash = verify_runner_graph(
        arguments.runner_app, arguments.expected_team
    )
    tuple_digest = tuple_definition_digest(arguments.repo_root)
    expected = release_identity_entitlements(
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
    validate_release_identity_entitlements(
        read_signed_entitlements(doryd, "doryd"), expected
    )
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
    print("renderer.release-identity=absent-fail-closed")


def parser() -> argparse.ArgumentParser:
    repo_root = pathlib.Path(__file__).resolve().parent.parent
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)

    create = commands.add_parser("create-entitlements")
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
    if arguments.command in {"create-entitlements", "verify"}:
        if arguments.expected_team != PRODUCTION_TEAM_IDENTIFIER:
            fail(
                "renderer release identity can only bind Dory production team "
                f"{PRODUCTION_TEAM_IDENTIFIER}"
            )
        arguments.repo_root = arguments.repo_root.resolve(strict=True)
    if arguments.command == "create-entitlements":
        create_entitlements(arguments)
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
