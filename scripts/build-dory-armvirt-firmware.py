#!/usr/bin/env python3
"""Build and package a pinned Dory UEFI firmware bundle."""

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
PACKAGE_ROOT = REPOSITORY_ROOT / "dory-core-swift"
EXPECTED_BUNDLE_FILES = {
    "firmware-code.fd",
    "manifest.json",
    "sbom.json",
    "variable-store-template.json",
}


PLATFORM_DEFINITIONS: Dict[str, Dict[str, Any]] = {
    "armvirt": {
        "directory": "DoryARMVirt",
        "package": "DoryARMVirtPkg",
        "outputDirectory": "DoryARMVirt-AArch64",
        "artifact": "DORY_ARMVIRT_EFI.fd",
        "expectedBytes": 4 * 1024 * 1024,
        "firmwareABI": "dory.edk2.armvirt@1",
        "machineABI": "dory.armvirt@1",
        "platform": "dory-armvirt-v1",
        "buildIdentifierPrefix": "dory-armvirt-v1-",
        "displayName": "DoryARMVirt",
        "stackCookies": True,
    },
    "pc": {
        "directory": "DoryPC",
        "package": "DoryPCPkg",
        "outputDirectory": "DoryPC-X64",
        "artifact": "OVMF_CODE.fd",
        "expectedBytes": 0x37C000,
        "firmwareABI": "dory.edk2.pc@1",
        "machineABI": "dory.pc@1",
        "platform": "dory-pc-v1",
        "buildIdentifierPrefix": "dory-pc-v1-",
        "displayName": "DoryPC",
        "stackCookies": False,
    },
}

PLATFORM: Dict[str, Any]
FIRMWARE_ROOT: Path
PLATFORM_ROOT: Path
PATCH_ROOT: Path
SOURCE_LOCK_PATH: Path
TOOLCHAIN_LOCK_PATH: Path


def configure_platform(name: str) -> None:
    global PLATFORM, FIRMWARE_ROOT, PLATFORM_ROOT, PATCH_ROOT
    global SOURCE_LOCK_PATH, TOOLCHAIN_LOCK_PATH
    PLATFORM = PLATFORM_DEFINITIONS[name]
    FIRMWARE_ROOT = REPOSITORY_ROOT / "Firmware" / PLATFORM["directory"]
    PLATFORM_ROOT = FIRMWARE_ROOT / PLATFORM["package"]
    PATCH_ROOT = FIRMWARE_ROOT / "patches"
    SOURCE_LOCK_PATH = FIRMWARE_ROOT / "source.lock.json"
    TOOLCHAIN_LOCK_PATH = FIRMWARE_ROOT / "toolchain.lock.json"


def verify_platform_contract() -> None:
    if PLATFORM["platform"] != "dory-pc-v1":
        return
    configuration = PLATFORM_ROOT / "DoryPC.dsc"
    flash_definition = PLATFORM_ROOT / "DoryPC.fdf"
    memory_definition = PLATFORM_ROOT / "DoryMemFd.fdf.inc"
    boot_manager = (
        PLATFORM_ROOT
        / "Library"
        / "DoryPlatformBootManagerLib"
        / "DoryPlatformBootManagerLib.c"
    )
    try:
        lines = configuration.read_text(encoding="utf-8").splitlines()
        flash_contents = flash_definition.read_text(encoding="utf-8")
        memory_contents = memory_definition.read_text(encoding="utf-8")
        boot_manager_contents = boot_manager.read_text(encoding="utf-8")
    except OSError as error:
        raise BuildFailure(f"cannot read DoryPC platform definition: {error}") from error
    for line in lines:
        binding = line.strip()
        if binding.startswith("QemuFwCfgLib|") and not binding.endswith(
            "/QemuFwCfgLibNull.inf"
        ):
            raise BuildFailure(
                "DoryPC must bind the upstream fw_cfg interface to its null library"
            )
        if binding.startswith("QemuFwCfgS3Lib|") and not binding.endswith(
            "/BaseQemuFwCfgS3LibNull.inf"
        ):
            raise BuildFailure(
                "DoryPC must bind the upstream fw_cfg S3 interface to its null library"
            )
        if binding.startswith(("QemuBootOrderLib|", "QemuLoadImageLib|")):
            raise BuildFailure("DoryPC must not bind a foreign machine boot or image policy")
        if binding.startswith(
            (
                "CcExitLib|",
                "CcProbeLib|",
                "MemEncryptSevLib|",
                "MemEncryptTdxLib|",
                "TdxHelperLib|",
                "TdxMailboxLib|",
                "TdxMeasurementLib|",
            )
        ) and "Null" not in binding:
            raise BuildFailure("DoryPC confidential-guest interfaces must bind null libraries")
    forbidden_tokens = (
        "TDX_GUEST_SUPPORTED",
        "SecTdxHelperLib.inf",
        "BaseIoLibIntrinsicSev.inf",
    )
    contents = "\n".join(lines)
    if any(token in contents for token in forbidden_tokens):
        raise BuildFailure("DoryPC must not compile a confidential-guest execution path")
    if "DEFINE BUILD_SHELL             = FALSE" not in contents:
        raise BuildFailure("DoryPC production firmware must not embed the UEFI shell")
    if "gEfiMdeModulePkgTokenSpaceGuid.PcdUse1GPageTable|TRUE" not in contents:
        raise BuildFailure(
            "DoryPC firmware must use the compatible-v1 1 GiB page-table capability"
        )
    if "CustomDecompressLib" in contents:
        raise BuildFailure("DoryPC production firmware must not perform guest-side FV decompression")
    if "DORY_PC_UNCOMPRESSED_MAIN_FV" not in contents:
        raise BuildFailure("DoryPC SEC must select its uncompressed memory-FV path")
    if "DoryBootProbe" in contents:
        raise BuildFailure("DoryPC must not compile the superseded boot-probe application")
    serial_console_driver = "MdeModulePkg/Universal/SerialDxe/SerialDxe.inf"
    if serial_console_driver not in contents or serial_console_driver not in flash_contents:
        raise BuildFailure(
            "DoryPC firmware must publish a serial Simple Text Output console"
        )
    apriori_start = flash_contents.find("APRIORI DXE {")
    apriori_end = flash_contents.find("\n}", apriori_start)
    if apriori_start < 0 or apriori_end < 0:
        raise BuildFailure("DoryPC firmware must define a DXE APRIORI dispatch list")
    apriori = flash_contents[apriori_start:apriori_end]
    console_dispatch_order = (
        "MdeModulePkg/Universal/Console/ConPlatformDxe/ConPlatformDxe.inf",
        "MdeModulePkg/Universal/Console/ConSplitterDxe/ConSplitterDxe.inf",
        serial_console_driver,
        "MdeModulePkg/Universal/Console/TerminalDxe/TerminalDxe.inf",
    )
    console_dispatch_positions = [apriori.find(driver) for driver in console_dispatch_order]
    if any(position < 0 for position in console_dispatch_positions):
        raise BuildFailure("DoryPC console drivers must be dispatched before BDS")
    if console_dispatch_positions != sorted(console_dispatch_positions):
        raise BuildFailure("DoryPC console drivers must preserve their dependency order")
    graphics_apriori_order = (
        "MdeModulePkg/Universal/HiiDatabaseDxe/HiiDatabaseDxe.inf",
        "MdeModulePkg/Universal/Console/GraphicsConsoleDxe/GraphicsConsoleDxe.inf",
    )
    graphics_apriori_positions = [apriori.find(driver) for driver in graphics_apriori_order]
    if any(position < 0 for position in graphics_apriori_positions):
        raise BuildFailure("DoryPC graphics console dependencies must be dispatched before BDS")
    if graphics_apriori_positions != sorted(graphics_apriori_positions):
        raise BuildFailure("DoryPC graphics console dependencies must preserve their order")
    virtio_dispatch_order = (
        "MdeModulePkg/Bus/Pci/PciBusDxe/PciBusDxe.inf",
        "OvmfPkg/Virtio10Dxe/Virtio10.inf",
        "OvmfPkg/VirtioGpuDxe/VirtioGpu.inf",
    )
    virtio_dispatch_positions = [apriori.find(driver) for driver in virtio_dispatch_order]
    if any(position < 0 for position in virtio_dispatch_positions):
        raise BuildFailure("DoryPC display drivers must be dispatched before BDS")
    if virtio_dispatch_positions != sorted(virtio_dispatch_positions):
        raise BuildFailure("DoryPC display drivers must preserve their dependency order")
    graphics_console_dispatch_order = (
        "MdeModulePkg/Universal/HiiDatabaseDxe/HiiDatabaseDxe.inf",
        "MdeModulePkg/Universal/Console/GraphicsConsoleDxe/GraphicsConsoleDxe.inf",
        "MdeModulePkg/Universal/BdsDxe/BdsDxe.inf",
    )
    graphics_console_dispatch_positions = [
        flash_contents.find(driver) for driver in graphics_console_dispatch_order
    ]
    if any(position < 0 for position in graphics_console_dispatch_positions):
        raise BuildFailure("DoryPC graphics console dependencies must be present")
    if graphics_console_dispatch_positions != sorted(graphics_console_dispatch_positions):
        raise BuildFailure("DoryPC graphics console dependencies must be dispatched before BDS")
    if "SECTION GUIDED" in flash_contents:
        raise BuildFailure("DoryPC compact firmware volume must not use guest-side extraction")
    direct_memory_fvs = ("SECTION FV_IMAGE = PEIFV", "SECTION FV_IMAGE = DXEFV")
    if any(fv not in flash_contents for fv in direct_memory_fvs):
        raise BuildFailure("DoryPC compact firmware volume must contain direct PEI and DXE FVs")
    if "!include DoryPCPkg/DoryMemFd.fdf.inc" not in flash_contents:
        raise BuildFailure("DoryPC firmware must use its right-sized memory firmware volumes")
    required_memory_regions = (
        "0x030000|0x030000",
        "0x060000|0x2C0000",
    )
    if any(region not in memory_contents for region in required_memory_regions):
        raise BuildFailure("DoryPC memory firmware-volume layout has drifted")
    required_probe_contract = (
        "DORY_PC_CONFIGURATION_FLAG_BOOT_PROBE",
        "DORY-PC-UEFI-BOOT",
        "DORY_PC_PM1_CONTROL_PORT",
        "DoryConnectDisplayConsole",
        "EfiBootManagerConnectVideoController",
        "DORY_PC_GPU_DEVICE_ID",
    )
    if any(value not in boot_manager_contents for value in required_probe_contract):
        raise BuildFailure("DoryPC firmware qualification probe contract has drifted")
    unsupported_firmware_drivers = (
        "EbcDxe",
        "VirtioScsiDxe",
        "RamDiskDxe",
        "ScsiBusDxe",
        "ScsiDiskDxe",
        "SataControllerDxe",
        "AtaAtapiPassThru",
        "AtaBusDxe",
        "NvmExpressDxe",
        "CxlDxe",
        "S3SaveStateDxe",
        "BootScriptExecutorDxe",
        "UhciDxe",
        "EhciDxe",
    )
    present_unsupported = [
        driver for driver in unsupported_firmware_drivers if driver in flash_contents
    ]
    if present_unsupported:
        raise BuildFailure(
            "DoryPC firmware embeds drivers for absent machine devices: "
            + ", ".join(present_unsupported)
        )


configure_platform("armvirt")


class BuildFailure(RuntimeError):
    pass


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    operation = parser.add_mutually_exclusive_group(required=True)
    operation.add_argument("--output", type=Path)
    operation.add_argument(
        "--package-app",
        type=Path,
        help="verify and package DoryPC firmware into one Xcode-built app",
    )
    parser.add_argument(
        "--platform",
        choices=tuple(PLATFORM_DEFINITIONS),
        default="armvirt",
        help="Dory firmware platform to build (default: armvirt)",
    )
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
    parser.add_argument(
        "--qualification-bootstrap",
        choices=("0", "1"),
        help="whether --package-app materializes or removes qualification firmware",
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


def verify_packaged_pc_bundle(bundle: Path) -> None:
    """Mirror the runtime's digest and ABI admission before Xcode seals the app."""
    try:
        bundle.lstat()
    except OSError as error:
        raise BuildFailure(f"cannot inspect DoryPC firmware bundle: {error}") from error
    if not bundle.is_dir() or bundle.is_symlink():
        raise BuildFailure("DoryPC firmware bundle must be a direct directory")
    actual_files = {path.name for path in bundle.iterdir()}
    if actual_files != EXPECTED_BUNDLE_FILES:
        raise BuildFailure(
            f"DoryPC firmware bundle has an invalid file set: {sorted(actual_files)}"
        )
    for file_name in EXPECTED_BUNDLE_FILES:
        path = bundle / file_name
        try:
            file_metadata = path.lstat()
        except OSError as error:
            raise BuildFailure(f"cannot inspect DoryPC {file_name}: {error}") from error
        if not path.is_file() or path.is_symlink() or file_metadata.st_size <= 0:
            raise BuildFailure(f"DoryPC {file_name} must be a non-empty direct regular file")

    manifest = load_json(bundle / "manifest.json")
    expected_identities = {
        "firmwareABIIdentity": "dory.edk2.pc@1",
        "machineABIIdentity": "dory.pc@1",
        "variableBridgeIdentity": "dory.uefi.variable-bridge.pc@1",
        "variableStoreFormatIdentity": "dory.uefi.variables.pc@1",
    }
    if manifest.get("schemaVersion") != 1:
        raise BuildFailure("DoryPC firmware manifest schemaVersion must be 1")
    for key, expected in expected_identities.items():
        if manifest.get(key) != expected:
            raise BuildFailure(f"DoryPC firmware manifest {key} is not {expected}")
    if manifest.get("reproducible") is not True:
        raise BuildFailure("DoryPC firmware manifest must identify a reproducible build")
    if manifest.get("secureBootPolicy") != "disabled":
        raise BuildFailure("DoryPC v1 secureBootPolicy must be disabled")
    build_identifier = manifest.get("buildIdentifier")
    if not isinstance(build_identifier, str) or not build_identifier.startswith("dory-pc-v1-"):
        raise BuildFailure("DoryPC firmware manifest has an invalid buildIdentifier")

    def verify_artifact(
        file_name: str,
        digest_key: str,
        byte_count_key: Optional[str] = None,
    ) -> None:
        path = bundle / file_name
        expected_digest = manifest.get(digest_key)
        if not isinstance(expected_digest, str) or len(expected_digest) != 64:
            raise BuildFailure(f"DoryPC firmware manifest has an invalid {digest_key}")
        if sha256(path) != expected_digest:
            raise BuildFailure(f"DoryPC {file_name} does not match {digest_key}")
        if byte_count_key is not None:
            expected_bytes = manifest.get(byte_count_key)
            if (
                not isinstance(expected_bytes, int)
                or isinstance(expected_bytes, bool)
                or path.stat().st_size != expected_bytes
            ):
                raise BuildFailure(f"DoryPC {file_name} does not match {byte_count_key}")

    verify_artifact("firmware-code.fd", "firmwareCodeSHA256", "firmwareCodeByteCount")
    if (bundle / "firmware-code.fd").stat().st_size % 4_096 != 0:
        raise BuildFailure("DoryPC firmware-code.fd must be 4 KiB aligned")
    verify_artifact(
        "variable-store-template.json",
        "variableStoreTemplateSHA256",
        "variableStoreTemplateByteCount",
    )
    verify_artifact("sbom.json", "sbomSHA256")

    variable_store = load_json(bundle / "variable-store-template.json")
    if variable_store.get("schemaVersion") != 1 or variable_store.get("generation") != 1:
        raise BuildFailure("DoryPC variable-store template has an invalid generation contract")
    if variable_store.get("formatIdentity") != "dory.uefi.variables.pc@1":
        raise BuildFailure("DoryPC variable-store template has an incompatible formatIdentity")
    if variable_store.get("machineABIIdentity") != "dory.pc@1":
        raise BuildFailure("DoryPC variable-store template has an incompatible machineABIIdentity")
    if load_json(bundle / "sbom.json").get("bomFormat") != "CycloneDX":
        raise BuildFailure("DoryPC sbom.json must be a CycloneDX document")


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
        raise BuildFailure("Dory firmware requires the pinned CLANGDWARF toolchain")

    tool_names = ["compiler", "llvmAr", "iasl", "make", "python"]
    if PLATFORM["platform"] == "dory-pc-v1":
        require_keys(toolchain, ["nasm"], TOOLCHAIN_LOCK_PATH)
        tool_names.append("nasm")
    for name in tool_names:
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
    if "nasm" in toolchain:
        nasm_output = tool_version([toolchain["nasm"]["executable"], "-v"])
        if f"NASM version {toolchain['nasm']['version']}" not in nasm_output:
            raise BuildFailure("NASM version does not match the firmware toolchain lock")

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
    if "nasm" in toolchain:
        executable_directories.append(str(Path(toolchain["nasm"]["executable"]).parent))
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
                "--exclude=/DoryPCPkg",
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
        "firmwareABI": PLATFORM["firmwareABI"],
        "machineABI": PLATFORM["machineABI"],
        "schemaVersion": 1,
    }
    encoded = json.dumps(inventory, sort_keys=True, separators=(",", ":")) + "\n"
    destination.write_text(encoded, encoding="utf-8")
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def current_build_identifier(source_lock: Dict[str, Any]) -> str:
    with tempfile.NamedTemporaryFile() as inventory_file:
        platform_digest = platform_inventory(Path(inventory_file.name))
    identifier_seed = (
        source_lock["revision"] + ":" + platform_digest + ":" + sha256(TOOLCHAIN_LOCK_PATH)
    ).encode("utf-8")
    return PLATFORM["buildIdentifierPrefix"] + hashlib.sha256(identifier_seed).hexdigest()[:20]


def write_reproducible_stack_cookies(
    source: Path,
    source_lock: Dict[str, Any],
    toolchain: Dict[str, Any],
) -> None:
    """Provide EDK II's supported pre-generated stack-cookie pools."""
    seed = hashlib.sha256()
    seed.update((PLATFORM["platform"] + "-stack-cookies-v1\0").encode("ascii"))
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
        / PLATFORM["outputDirectory"]
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
    shutil.copytree(PLATFORM_ROOT, source / PLATFORM["package"])
    if PLATFORM["stackCookies"]:
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
        / PLATFORM["outputDirectory"]
        / f"{toolchain['buildTarget']}_{toolchain['compilerFamily']}"
        / "FV"
        / PLATFORM["artifact"]
    )
    if not firmware.is_file() or firmware.stat().st_size != PLATFORM["expectedBytes"]:
        raise BuildFailure(
            "firmware build did not produce the frozen "
            f"{PLATFORM['expectedBytes']}-byte code image"
        )
    if firmware.stat().st_size % 4096 != 0:
        raise BuildFailure("firmware code image is not 4 KiB aligned")
    if PLATFORM["platform"] == "dory-pc-v1" and firmware.read_bytes()[-16:] == b"\xff" * 16:
        raise BuildFailure("DoryPC firmware reset vector is empty")
    return firmware


def package_bundle(
    firmware: Path,
    workspace: Path,
    source_lock: Dict[str, Any],
    toolchain: Dict[str, Any],
    environment: Dict[str, str],
) -> Path:
    configuration = workspace / "platform-configuration.json"
    platform_inventory(configuration)
    build_identifier = current_build_identifier(source_lock)

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
            "--platform",
            PLATFORM["platform"],
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


def build_and_publish(arguments: argparse.Namespace, output: Path) -> int:
    source_lock = load_json(SOURCE_LOCK_PATH)
    toolchain = load_json(TOOLCHAIN_LOCK_PATH)
    require_keys(
        source_lock,
        ["repository", "revision", "sourceDateEpoch", "tag"],
        SOURCE_LOCK_PATH,
    )
    environment = verify_toolchain(toolchain)

    workspace = Path(
        tempfile.mkdtemp(prefix=f"{PLATFORM['platform']}-firmware.")
    )
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
        publish(bundle, output)
        print(f"{PLATFORM['displayName']} bundle: {output.resolve()}")
        print(f"firmware sha256: {sha256(output.resolve() / 'firmware-code.fd')}")
        return 0
    finally:
        if arguments.keep_workspace:
            print(f"retained workspace: {workspace}")
        else:
            shutil.rmtree(workspace, ignore_errors=True)


def remove_packaged_pc_bundle(destination: Path) -> None:
    if destination.is_symlink() or (destination.exists() and not destination.is_dir()):
        destination.unlink()
    elif destination.is_dir():
        shutil.rmtree(destination)


def refresh_default_pc_bundle(arguments: argparse.Namespace, source: Path) -> None:
    source.parent.mkdir(parents=True, exist_ok=True)
    candidate = Path(tempfile.mkdtemp(prefix=f".{source.name}.refresh.", dir=str(source.parent)))
    candidate.rmdir()
    try:
        build_and_publish(arguments, candidate)
        verify_packaged_pc_bundle(candidate)
        if not source.exists():
            os.replace(candidate, source)
            return

        backup = Path(tempfile.mkdtemp(prefix=f".{source.name}.previous.", dir=str(source.parent)))
        backup.rmdir()
        os.replace(source, backup)
        try:
            os.replace(candidate, source)
        except Exception:
            os.replace(backup, source)
            raise
        else:
            shutil.rmtree(backup)
    finally:
        if candidate.exists():
            shutil.rmtree(candidate, ignore_errors=True)


def package_pc_qualification_app(arguments: argparse.Namespace) -> int:
    if arguments.platform != "pc":
        raise BuildFailure("--package-app requires --platform pc")
    if arguments.qualification_bootstrap is None:
        raise BuildFailure("--package-app requires --qualification-bootstrap 0 or 1")

    app = Path(os.path.abspath(arguments.package_app))
    if app.suffix != ".app" or not app.is_dir() or app.is_symlink():
        raise BuildFailure(f"qualification firmware destination is not a direct app: {app}")
    resources = app / "Contents" / "Resources"
    destination = resources / "dory-pc-firmware"
    if arguments.qualification_bootstrap == "0":
        remove_packaged_pc_bundle(destination)
        return 0

    explicit_bundle = os.environ.get("DORY_PC_FIRMWARE_BUNDLE")
    source = (
        Path(explicit_bundle)
        if explicit_bundle
        else REPOSITORY_ROOT / "guest/out/dory-pc-firmware"
    )
    if explicit_bundle is None:
        source_lock = load_json(SOURCE_LOCK_PATH)
        expected_identifier = current_build_identifier(source_lock)
        cached_identifier = None
        if source.is_dir() and not source.is_symlink():
            try:
                cached_identifier = load_json(source / "manifest.json").get("buildIdentifier")
            except (BuildFailure, OSError):
                cached_identifier = None
        if cached_identifier != expected_identifier:
            print(
                "note: rebuilding stale provenance-pinned DoryPC firmware for qualification",
                file=sys.stderr,
            )
            refresh_default_pc_bundle(arguments, source)
    verify_packaged_pc_bundle(source)

    resources.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".dory-pc-firmware.", dir=str(resources)))
    try:
        for file_name in sorted(EXPECTED_BUNDLE_FILES):
            shutil.copy2(source / file_name, staging / file_name)
        verify_packaged_pc_bundle(staging)
        remove_packaged_pc_bundle(destination)
        os.replace(staging, destination)
        run(["/usr/bin/xattr", "-cr", str(destination)])
    finally:
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)
    print(f"packaged DoryPC firmware: {destination}")
    return 0


def main() -> int:
    arguments = parse_arguments()
    configure_platform(arguments.platform)
    verify_platform_contract()
    if arguments.package_app is not None:
        return package_pc_qualification_app(arguments)
    assert arguments.output is not None
    if arguments.qualification_bootstrap is not None:
        raise BuildFailure("--qualification-bootstrap is valid only with --package-app")
    return build_and_publish(arguments, arguments.output)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BuildFailure as error:
        print(f"build-dory-firmware: {error}", file=sys.stderr)
        sys.exit(2)
