#!/usr/bin/env python3
"""Build and package the pinned DoryARMVirt firmware bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
FIRMWARE_ROOT = REPOSITORY_ROOT / "Firmware" / "DoryARMVirt"
PLATFORM_ROOT = FIRMWARE_ROOT / "DoryARMVirtPkg"
PATCH_ROOT = FIRMWARE_ROOT / "patches"
SOURCE_LOCK_PATH = FIRMWARE_ROOT / "source.lock.json"
TOOLCHAIN_LOCK_PATH = FIRMWARE_ROOT / "toolchain.lock.json"
PACKAGE_ROOT = REPOSITORY_ROOT / "dory-core-swift"
EXPECTED_BUNDLE_FILES = {
    "firmware-code.fd",
    "manifest.json",
    "sbom.json",
    "variable-store-template.json",
}
EXPECTED_FIRMWARE_BYTES = 4 * 1024 * 1024


class BuildFailure(RuntimeError):
    pass


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--edk2-source",
        type=Path,
        help="verified local EDK II checkout used instead of fetching the pinned source",
    )
    parser.add_argument(
        "--keep-workspace",
        action="store_true",
        help="retain the isolated source/build workspace for diagnosis",
    )
    return parser.parse_args()


def load_json(path: Path) -> Dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BuildFailure(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise BuildFailure(f"expected a JSON object in {path}")
    return value


def run(
    command: List[str],
    *,
    cwd: Optional[Path] = None,
    environment: Optional[Dict[str, str]] = None,
    capture: bool = False,
) -> str:
    rendered = " ".join(command)
    print(f"+ {rendered}", flush=True)
    try:
        result = subprocess.run(
            command,
            cwd=cwd,
            env=environment,
            check=True,
            text=True,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.STDOUT if capture else None,
        )
    except subprocess.CalledProcessError as error:
        output = error.stdout.strip() if error.stdout else ""
        detail = f"\n{output}" if output else ""
        raise BuildFailure(f"command failed ({error.returncode}): {rendered}{detail}") from error
    return result.stdout.strip() if capture and result.stdout else ""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_keys(value: Dict[str, Any], names: Iterable[str], source: Path) -> None:
    missing = sorted(set(names) - set(value))
    if missing:
        raise BuildFailure(f"{source} is missing required fields: {', '.join(missing)}")


def tool_version(command: List[str]) -> str:
    return run(command, capture=True)


def verify_tool(name: str, descriptor: Dict[str, Any]) -> None:
    require_keys(descriptor, ["executable", "version"], TOOLCHAIN_LOCK_PATH)
    executable = Path(str(descriptor["executable"]))
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise BuildFailure(f"pinned {name} is unavailable: {executable}")
    expected_digest = descriptor.get("sha256")
    if expected_digest is not None and sha256(executable) != expected_digest:
        raise BuildFailure(f"pinned {name} digest does not match: {executable}")


def verify_toolchain(toolchain: Dict[str, Any]) -> Dict[str, str]:
    require_keys(
        toolchain,
        [
            "architecture",
            "buildTarget",
            "compiler",
            "compilerFamily",
            "configuration",
            "host",
            "iasl",
            "llvmAr",
            "make",
            "python",
            "schemaVersion",
            "xcodeDeveloperDirectory",
        ],
        TOOLCHAIN_LOCK_PATH,
    )
    if toolchain["schemaVersion"] != 1:
        raise BuildFailure("unsupported toolchain lock schema")
    if platform.machine() != toolchain["host"]["architecture"]:
        raise BuildFailure("host architecture does not match the firmware toolchain lock")
    if toolchain["compilerFamily"] != "CLANGDWARF":
        raise BuildFailure("DoryARMVirt requires the pinned CLANGDWARF toolchain")

    for name in ("compiler", "llvmAr", "iasl", "make", "python"):
        verify_tool(name, toolchain[name])

    compiler_output = tool_version([toolchain["compiler"]["executable"], "--version"])
    if f"version {toolchain['compiler']['version']}" not in compiler_output.splitlines()[0]:
        raise BuildFailure("compiler version does not match the firmware toolchain lock")
    archive_output = tool_version([toolchain["llvmAr"]["executable"], "--version"])
    if f"version {toolchain['llvmAr']['version']}" not in archive_output.splitlines()[0]:
        raise BuildFailure("llvm-ar version does not match the firmware toolchain lock")
    iasl_output = tool_version([toolchain["iasl"]["executable"], "-v"])
    if f"version {toolchain['iasl']['version']}" not in iasl_output:
        raise BuildFailure("iasl version does not match the firmware toolchain lock")
    python_output = tool_version([toolchain["python"]["executable"], "--version"])
    if python_output != f"Python {toolchain['python']['version']}":
        raise BuildFailure("Python version does not match the firmware toolchain lock")
    make_output = tool_version([toolchain["make"]["executable"], "--version"])
    if f"Make {toolchain['make']['version']}" not in make_output.splitlines()[0]:
        raise BuildFailure("make version does not match the firmware toolchain lock")

    developer_directory = Path(toolchain["xcodeDeveloperDirectory"])
    if not developer_directory.is_dir():
        raise BuildFailure(f"pinned Xcode developer directory is unavailable: {developer_directory}")
    xcode_output = tool_version(
        [str(developer_directory / "usr" / "bin" / "xcodebuild"), "-version"]
    )
    expected_xcode = (
        f"Xcode {toolchain['host']['xcodeVersion']}\n"
        f"Build version {toolchain['host']['xcodeBuild']}"
    )
    if xcode_output != expected_xcode:
        raise BuildFailure("Xcode version does not match the firmware toolchain lock")

    environment = os.environ.copy()
    environment.update(
        {
            "CC": toolchain["compiler"]["executable"],
            "DEVELOPER_DIR": str(developer_directory),
            "LC_ALL": "C",
            "PYTHONHASHSEED": "0",
            "SDKROOT": str(
                developer_directory
                / "Platforms"
                / "MacOSX.platform"
                / "Developer"
                / "SDKs"
                / "MacOSX.sdk"
            ),
            "TZ": "UTC",
        }
    )
    executable_directories = [
        str(Path(toolchain["compiler"]["executable"]).parent),
        str(Path(toolchain["iasl"]["executable"]).parent),
    ]
    environment["PATH"] = os.pathsep.join(executable_directories + [environment["PATH"]])
    return environment


def verify_source_checkout(source: Path, source_lock: Dict[str, Any]) -> None:
    revision = run(["git", "rev-parse", "HEAD"], cwd=source, capture=True)
    if revision != source_lock["revision"]:
        raise BuildFailure(f"EDK II source revision {revision} does not match the source lock")
    status = run(["git", "submodule", "status"], cwd=source, capture=True)
    for line in status.splitlines():
        if line and line[0] in "-+U":
            raise BuildFailure(f"EDK II submodule is not pinned and initialized: {line}")


def prepare_source(
    workspace: Path,
    source_lock: Dict[str, Any],
    local_source: Optional[Path],
) -> Path:
    source = workspace / "edk2"
    if local_source is not None:
        local_source = local_source.resolve()
        verify_source_checkout(local_source, source_lock)
        run(
            [
                "rsync",
                "-a",
                "--exclude=/.git",
                "--exclude=/Build",
                "--exclude=/Conf",
                "--exclude=/DoryARMVirtPkg",
                f"{local_source}/",
                f"{source}/",
            ]
        )
        return source

    run(
        [
            "git",
            "clone",
            "--branch",
            source_lock["tag"],
            "--depth",
            "1",
            source_lock["repository"],
            str(source),
        ]
    )
    revision = run(["git", "rev-parse", "HEAD"], cwd=source, capture=True)
    if revision != source_lock["revision"]:
        raise BuildFailure(f"fetched EDK II revision {revision} does not match the source lock")
    run(
        ["git", "submodule", "update", "--init", "--depth", "1"],
        cwd=source,
    )
    verify_source_checkout(source, source_lock)
    return source


def apply_source_patches(source: Path) -> None:
    patches = sorted(PATCH_ROOT.glob("*.patch"))
    if not patches:
        raise BuildFailure(f"no EDK II patches found in {PATCH_ROOT}")
    for patch in patches:
        # EDK II keeps this template in CRLF form. Ignore line-ending-only
        # whitespace while retaining a reviewable, ordinary unified diff.
        run(
            ["git", "apply", "--ignore-space-change", "--check", str(patch)],
            cwd=source,
        )
        run(["git", "apply", "--ignore-space-change", str(patch)], cwd=source)


def platform_inventory(destination: Path) -> str:
    files: List[Dict[str, Any]] = []
    input_roots = (PLATFORM_ROOT, PATCH_ROOT)
    for input_root in input_roots:
        for path in sorted(input_root.rglob("*")):
            if path.is_file():
                files.append(
                    {
                        "byteCount": path.stat().st_size,
                        "path": path.relative_to(FIRMWARE_ROOT).as_posix(),
                        "sha256": sha256(path),
                    }
                )
    inventory = {
        "files": files,
        "firmwareABI": "dory.edk2.armvirt@1",
        "machineABI": "dory.armvirt@1",
        "schemaVersion": 1,
    }
    encoded = json.dumps(inventory, sort_keys=True, separators=(",", ":")) + "\n"
    destination.write_text(encoded, encoding="utf-8")
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def write_reproducible_stack_cookies(
    source: Path,
    source_lock: Dict[str, Any],
    toolchain: Dict[str, Any],
) -> None:
    """Provide EDK II's supported pre-generated stack-cookie pools."""
    seed = hashlib.sha256()
    seed.update(b"dory-armvirt-stack-cookies-v1\0")
    seed.update(str(source_lock["revision"]).encode("ascii"))
    seed.update(sha256(TOOLCHAIN_LOCK_PATH).encode("ascii"))
    for input_root in (PLATFORM_ROOT, PATCH_ROOT):
        for path in sorted(input_root.rglob("*")):
            if path.is_file():
                seed.update(path.relative_to(FIRMWARE_ROOT).as_posix().encode("utf-8"))
                seed.update(sha256(path).encode("ascii"))

    build_root = (
        source
        / "Build"
        / "DoryARMVirt-AArch64"
        / f"{toolchain['buildTarget']}_{toolchain['compilerFamily']}"
    )
    build_root.mkdir(parents=True, exist_ok=True)
    for width in (32, 64):
        values = []
        for index in range(100):
            material = seed.digest() + width.to_bytes(1, "big") + index.to_bytes(2, "big")
            value = int.from_bytes(hashlib.sha256(material).digest()[: width // 8], "big")
            values.append(value or 1)
        destination = build_root / f"StackCookieValues{width}.json"
        destination.write_text(
            json.dumps(values, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )


def build_firmware(
    source: Path,
    workspace: Path,
    source_lock: Dict[str, Any],
    toolchain: Dict[str, Any],
    environment: Dict[str, str],
) -> Path:
    shutil.copytree(PLATFORM_ROOT, source / "DoryARMVirtPkg")
    write_reproducible_stack_cookies(source, source_lock, toolchain)
    environment = environment.copy()
    environment["SOURCE_DATE_EPOCH"] = str(source_lock["sourceDateEpoch"])
    environment["PYTHON_COMMAND"] = toolchain["python"]["executable"]
    jobs = str(max(1, os.cpu_count() or 1))
    (workspace / "Conf").mkdir()
    run(
        [toolchain["make"]["executable"], "-C", "BaseTools", "clean"],
        cwd=source,
        environment=environment,
    )
    run(
        [toolchain["make"]["executable"], "-C", "BaseTools", f"-j{jobs}"],
        cwd=source,
        environment=environment,
    )
    build_command = "\n".join(
        [
            "set -euo pipefail",
            f'export WORKSPACE="{source}"',
            f'export EDK_TOOLS_PATH="{source / "BaseTools"}"',
            f'export CONF_PATH="{workspace / "Conf"}"',
            'source "$WORKSPACE/edksetup.sh" BaseTools >/dev/null',
            'export PATH="$EDK_TOOLS_PATH/Source/C/bin:$PATH"',
            "build "
            f"-a {toolchain['architecture']} "
            f"-t {toolchain['compilerFamily']} "
            f"-b {toolchain['buildTarget']} "
            f"-p {toolchain['configuration']} "
            f"-n {jobs}",
        ]
    )
    run(["/bin/bash", "-c", build_command], cwd=source, environment=environment)
    firmware = (
        source
        / "Build"
        / "DoryARMVirt-AArch64"
        / "RELEASE_CLANGDWARF"
        / "FV"
        / "DORY_ARMVIRT_EFI.fd"
    )
    if not firmware.is_file() or firmware.stat().st_size != EXPECTED_FIRMWARE_BYTES:
        raise BuildFailure("firmware build did not produce the frozen 4 MiB code image")
    return firmware


def package_bundle(
    firmware: Path,
    workspace: Path,
    source_lock: Dict[str, Any],
    toolchain: Dict[str, Any],
    environment: Dict[str, str],
) -> Path:
    configuration = workspace / "platform-configuration.json"
    platform_digest = platform_inventory(configuration)
    toolchain_digest = sha256(TOOLCHAIN_LOCK_PATH)
    identifier_seed = (
        source_lock["revision"] + ":" + platform_digest + ":" + toolchain_digest
    ).encode("utf-8")
    build_identifier = "dory-armvirt-v1-" + hashlib.sha256(identifier_seed).hexdigest()[:20]

    swift_scratch = workspace / "swift-build"
    run(
        [
            "swift",
            "build",
            "-c",
            "release",
            "--package-path",
            str(PACKAGE_ROOT),
            "--scratch-path",
            str(swift_scratch),
            "--product",
            "dory-firmware-bundler",
        ],
        cwd=REPOSITORY_ROOT,
        environment=environment,
    )
    binary_root = Path(
        run(
            [
                "swift",
                "build",
                "-c",
                "release",
                "--package-path",
                str(PACKAGE_ROOT),
                "--scratch-path",
                str(swift_scratch),
                "--show-bin-path",
            ],
            cwd=REPOSITORY_ROOT,
            environment=environment,
            capture=True,
        ).splitlines()[-1]
    )
    bundle = workspace / "bundle"
    run(
        [
            str(binary_root / "dory-firmware-bundler"),
            "--firmware-code",
            str(firmware),
            "--platform-configuration",
            str(configuration),
            "--toolchain-descriptor",
            str(TOOLCHAIN_LOCK_PATH),
            "--output",
            str(bundle),
            "--build-identifier",
            build_identifier,
            "--source-repository",
            source_lock["repository"],
            "--source-revision",
            source_lock["revision"],
            "--source-date-epoch",
            str(source_lock["sourceDateEpoch"]),
            "--secure-boot-policy",
            "disabled",
        ],
        cwd=REPOSITORY_ROOT,
        environment=environment,
    )
    actual_files = {path.name for path in bundle.iterdir() if path.is_file()}
    if actual_files != EXPECTED_BUNDLE_FILES:
        raise BuildFailure(f"firmware bundle has an invalid file set: {sorted(actual_files)}")
    return bundle


def publish(bundle: Path, destination: Path) -> None:
    destination = destination.resolve()
    if destination.exists():
        raise BuildFailure(f"refusing to replace existing output: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(
        tempfile.mkdtemp(prefix=f".{destination.name}.", dir=str(destination.parent))
    )
    try:
        for source in bundle.iterdir():
            shutil.copy2(source, staging / source.name)
        os.replace(staging, destination)
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def main() -> int:
    arguments = parse_arguments()
    source_lock = load_json(SOURCE_LOCK_PATH)
    toolchain = load_json(TOOLCHAIN_LOCK_PATH)
    require_keys(
        source_lock,
        ["repository", "revision", "sourceDateEpoch", "tag"],
        SOURCE_LOCK_PATH,
    )
    environment = verify_toolchain(toolchain)

    workspace = Path(tempfile.mkdtemp(prefix="dory-armvirt-firmware."))
    try:
        source = prepare_source(workspace, source_lock, arguments.edk2_source)
        apply_source_patches(source)
        firmware = build_firmware(
            source,
            workspace,
            source_lock,
            toolchain,
            environment,
        )
        bundle = package_bundle(
            firmware,
            workspace,
            source_lock,
            toolchain,
            environment,
        )
        publish(bundle, arguments.output)
        print(f"DoryARMVirt bundle: {arguments.output.resolve()}")
        print(f"firmware sha256: {sha256(arguments.output.resolve() / 'firmware-code.fd')}")
        return 0
    finally:
        if arguments.keep_workspace:
            print(f"retained workspace: {workspace}")
        else:
            shutil.rmtree(workspace, ignore_errors=True)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BuildFailure as error:
        print(f"build-dory-armvirt-firmware: {error}", file=sys.stderr)
        sys.exit(2)
