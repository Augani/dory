#!/usr/bin/env python3
"""Build Dory's Apple Silicon component payloads and signed catalog."""

from __future__ import annotations

import argparse
import base64
import binascii
import copy
import datetime as dt
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.parse
import uuid
from typing import NoReturn


CATALOG_KIND = "dev.dory.component-catalog"
TEST_CATALOG_KIND = "dev.dory.component-catalog.test-fixture"
CATALOG_SCHEMA = 2
ARCHITECTURE = "arm64"
QUALIFICATION_KIND = "dev.dory.virtual-machine-qualification-manifest"
QUALIFICATION_SCHEMA = 2
QUALIFICATION_COMPONENT = "linux-desktop"
QUALIFICATION_PATH = "virtual-machine-qualification.json"
QUALIFICATION_SIGNATURE_PATH = "virtual-machine-qualification.json.sig"
PERFORMANCE_RECEIPT_KIND = "dev.dory.linux-vm-performance-verification-receipt"
PERFORMANCE_RECEIPT_SCHEMA = 1
PERFORMANCE_RECEIPT_SUFFIX = ".linux-vm-performance-verification.json"
PERFORMANCE_RECEIPT_SIGNATURE_SUFFIX = PERFORMANCE_RECEIPT_SUFFIX + ".sig"
INVENTORY_KIND = "dev.dory.component-candidate-inventory"
INVENTORY_SCHEMA = 2
INVENTORY_PATH = "component-candidate-inventory.json"
INVENTORY_DIGEST_PATH = "component-candidate-inventory.json.sha256"
DEFAULT_CATALOG_PUBLIC_KEY = "AFetajNbqZty68rRY7OMWYNt6suUsrokQmYMhDJtnP4="
MAX_QUALIFICATION_BYTES = 2 * 1024 * 1024
FS_WORKER_BUNDLE_PATH = pathlib.PurePosixPath(
    "Contents/XPCServices/DoryFSWorker.xpc"
)
FS_WORKER_IDENTIFIER = "com.pythonxi.Dory.HVRunner.FSWorker"
FS_WORKER_EXECUTABLE = "DoryFSWorker"
RENDERER_WORKER_BUNDLE_PATH = pathlib.PurePosixPath(
    "Contents/XPCServices/DoryRendererWorker.xpc"
)
RENDERER_WORKER_IDENTIFIER = "com.pythonxi.Dory.HVRunner.RendererWorker"
RENDERER_WORKER_EXECUTABLE = "DoryRendererWorker"
VMM_BUNDLE_PATH = pathlib.PurePosixPath("Contents/Helpers/DoryVMM.app")
VMM_IDENTIFIER = "dory-vmm"
VMM_EXECUTABLE = "dory-vmm"
OUTER_APPLICATION_IDENTIFIER = "com.pythonxi.Dory"
OUTER_APPLICATION_EXECUTABLE = "Dory"
SIGNING_TEAM_IDENTIFIER = "864H636QW4"
EXPECTED_OUTER_APPLICATION_ENTITLEMENTS = {
    "com.apple.security.application-groups": [
        "864H636QW4.group.com.pythonxi.Dory"
    ],
    "com.apple.security.device.audio-input": True,
    "com.apple.security.network.client": True,
    "com.apple.security.network.server": True,
}
EXPECTED_RUNNER_ENTITLEMENTS = {
    "com.apple.security.device.audio-input": True,
    "com.apple.security.device.camera": True,
    "com.apple.security.hypervisor": True,
}
EXPECTED_VMM_ENTITLEMENTS = {
    "com.apple.security.device.audio-input": True,
    "com.apple.security.virtualization": True,
}
# The filesystem worker deliberately carries no ambient sandbox grants. Its authority is the
# one-shot, authenticated XPC transfer of already-open directory descriptors; App Sandbox cannot
# use an inherited directory descriptor to open descendants and would make valid openat calls fail.
EXPECTED_FS_WORKER_ENTITLEMENTS: dict[str, object] = {}
EXPECTED_RENDERER_WORKER_ENTITLEMENTS = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.application-groups": ["864H636QW4.dory-renderer"],
}
DEVELOPER_ID_INTERMEDIATE_OID = "1.2.840.113635.100.6.2.6"
DEVELOPER_ID_APPLICATION_OID = "1.2.840.113635.100.6.1.13"


def fail(message: str) -> NoReturn:
    raise SystemExit(f"component build error: {message}")


def regular_file(path: pathlib.Path, label: str) -> pathlib.Path:
    try:
        info = path.lstat()
    except FileNotFoundError:
        fail(f"{label} is missing: {path}")
    if not stat.S_ISREG(info.st_mode) or info.st_size <= 0:
        fail(f"{label} is not a non-empty regular file: {path}")
    return path


def directory(path: pathlib.Path, label: str) -> pathlib.Path:
    try:
        info = path.lstat()
    except FileNotFoundError:
        fail(f"{label} is missing: {path}")
    if not stat.S_ISDIR(info.st_mode):
        fail(f"{label} is not a directory: {path}")
    return path


def absolute_without_resolving(path: pathlib.Path) -> pathlib.Path:
    """Return a lexical absolute path while preserving a final symlink for lstat checks."""
    return pathlib.Path(os.path.abspath(os.fspath(path)))


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def byte_size(path: pathlib.Path) -> int:
    return regular_file(path, "artifact").stat().st_size


def require_arm64_macho(path: pathlib.Path, label: str) -> None:
    architectures = run(["lipo", "-archs", str(path)]).split()
    if "arm64" not in architectures:
        fail(f"{label} does not contain arm64 code")


def application_tree_binding(path: pathlib.Path) -> dict:
    """Bind every direct app-tree entry without following framework/resource symlinks."""
    records = []
    regular_bytes = 0
    for root, directories, files in os.walk(path, followlinks=False):
        root_path = pathlib.Path(root)
        names = sorted(set(directories + files))
        for name in names:
            candidate = root_path / name
            info = candidate.lstat()
            relative = candidate.relative_to(path).as_posix()
            parts = pathlib.PurePosixPath(relative).parts
            if len(relative.encode("utf-8")) > 4096 or any(
                part in {"", ".", ".."} for part in parts
            ):
                fail(f"core app contains an unsafe path: {relative}")
            record = {
                "path": relative,
                "mode": stat.S_IMODE(info.st_mode),
            }
            if stat.S_ISDIR(info.st_mode):
                record["kind"] = "directory"
            elif stat.S_ISREG(info.st_mode):
                record.update(
                    {
                        "kind": "regular",
                        "bytes": info.st_size,
                        "sha256": sha256(candidate),
                    }
                )
                regular_bytes += info.st_size
            elif stat.S_ISLNK(info.st_mode):
                target = os.readlink(candidate)
                target_parts = pathlib.PurePosixPath(target).parts
                if (
                    not target
                    or len(target.encode("utf-8")) > 4096
                    or pathlib.PurePosixPath(target).is_absolute()
                    or any(part in {"", ".", ".."} for part in target_parts)
                ):
                    fail(f"core app contains an unsafe symbolic link: {relative}")
                record.update({"kind": "symlink", "target": target})
            else:
                fail(f"core app contains a special entry: {relative}")
            records.append(record)
        directories[:] = [
            name for name in directories
            if not (root_path / name).is_symlink()
        ]
    records.sort(key=lambda value: value["path"])
    if not records or regular_bytes <= 0:
        fail(f"core app contains no bindable payload: {path}")
    return {
        "entryCount": len(records),
        "regularFileBytes": regular_bytes,
        "graphSHA256": hashlib.sha256(canonical_json_bytes(records)).hexdigest(),
    }


def run(
    command: list[str],
    *,
    cwd: pathlib.Path | None = None,
    env: dict[str, str] | None = None,
) -> str:
    completed = subprocess.run(
        command,
        cwd=cwd,
        env=env,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip() or f"exit {completed.returncode}"
        fail(f"{' '.join(command)} failed: {detail}")
    return completed.stdout.strip()


def validate_sources(repo: pathlib.Path, source_root: pathlib.Path, kubectl: pathlib.Path) -> None:
    expected_default = repo / "guest" / "out"
    if source_root.resolve() != expected_default.resolve():
        fail("verified builds must use guest/out; use --skip-source-verification only for tests")
    run([str(repo / "guest/kernel/verify-build.sh"), "arm64"], cwd=repo)
    run([str(repo / "guest/initfs/verify-build.sh"), "arm64"], cwd=repo)
    desktop_env = dict(os.environ)
    desktop_env["DORY_KERNEL_PROFILE"] = "accelerated-desktop"
    run([str(repo / "guest/kernel/verify-build.sh"), "arm64"], cwd=repo, env=desktop_env)
    for distro in ("debian", "ubuntu", "kali"):
        run([str(repo / "guest/desktop/verify-build.sh"), "arm64", distro], cwd=repo)
    run(["codesign", "--verify", "--strict", str(kubectl)])
    archs = run(["lipo", "-archs", str(kubectl)]).split()
    if "arm64" not in archs:
        fail(f"kubectl does not contain arm64 code: {' '.join(archs)}")


def designated_code_requirement(path: pathlib.Path) -> str:
    completed = subprocess.run(
        ["codesign", "-d", "-r-", str(path)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        fail(f"could not read the designated requirement for {path}")
    for line in (completed.stdout + "\n" + completed.stderr).splitlines():
        if "designated =>" in line:
            requirement = line.split("designated =>", 1)[1].strip()
            if requirement and len(requirement.encode("utf-8")) <= 4096:
                return requirement
    fail(f"codesign returned no designated requirement for {path}")


def developer_id_designated_requirement(identifier: str) -> str:
    return (
        f'identifier "{identifier}" and anchor apple generic and '
        f'certificate 1[field.{DEVELOPER_ID_INTERMEDIATE_OID}] /* exists */ and '
        f'certificate leaf[field.{DEVELOPER_ID_APPLICATION_OID}] /* exists */ and '
        f'certificate leaf[subject.OU] = "{SIGNING_TEAM_IDENTIFIER}"'
    )


def test_designated_requirement(identifier: str) -> str:
    return f'identifier "{identifier}"'


def signature_details(path: pathlib.Path, label: str) -> tuple[str, bool]:
    completed = subprocess.run(
        ["codesign", "-d", "--verbose=4", str(path)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        fail(f"could not inspect the {label} signature")
    details = completed.stdout + "\n" + completed.stderr
    team_identifier = None
    runtime = False
    for line in details.splitlines():
        if line.startswith("TeamIdentifier="):
            team_identifier = line.split("=", 1)[1].strip()
        elif line.startswith("CodeDirectory "):
            flag_names = re.search(r"flags=[^ ]*\(([^)]*)\)", line)
            if flag_names is not None:
                runtime = "runtime" in {
                    value.strip() for value in flag_names.group(1).split(",")
                }
    if team_identifier is None:
        fail(f"{label} signature does not report a team identity")
    return team_identifier, runtime


def signed_identity_evidence(
    bundle: pathlib.Path,
    *,
    relative_path: str,
    label: str,
    expected_identifier: str,
    expected_executable: str,
    expected_package_type: str,
    expected_entitlements: dict,
    allow_test_signatures: bool,
) -> dict:
    actual_requirement = designated_code_requirement(bundle)
    expected_requirement = (
        test_designated_requirement(expected_identifier)
        if allow_test_signatures
        else developer_id_designated_requirement(expected_identifier)
    )
    if actual_requirement != expected_requirement:
        fail(f"{label} designated requirement is not canonical")
    run(
        [
            "codesign",
            "--verify",
            "--strict",
            f"-R={expected_requirement}",
            str(bundle),
        ]
    )
    team_identifier, hardened_runtime = signature_details(bundle, label)
    expected_team = "not set" if allow_test_signatures else SIGNING_TEAM_IDENTIFIER
    if team_identifier != expected_team:
        fail(f"{label} signing team is not canonical")
    if hardened_runtime == allow_test_signatures:
        fail(f"{label} hardened-runtime policy is invalid")
    entitlements = signed_entitlements(bundle, label)
    if entitlements != expected_entitlements:
        fail(f"{label} entitlements do not match their exact authority")
    code_resources = regular_file(
        bundle / "Contents" / "_CodeSignature" / "CodeResources",
        f"{label} CodeResources seal",
    )
    return {
        "path": relative_path,
        "bundleIdentifier": expected_identifier,
        "bundleExecutable": expected_executable,
        "bundlePackageType": expected_package_type,
        "designatedRequirement": actual_requirement,
        "signatureKind": (
            "adhoc-test" if allow_test_signatures else "developer-id-application"
        ),
        "teamIdentifier": "-" if allow_test_signatures else SIGNING_TEAM_IDENTIFIER,
        "hardenedRuntime": hardened_runtime,
        "entitlements": entitlements,
        "codeResourcesPath": (
            "Contents/_CodeSignature/CodeResources"
            if expected_package_type == "APPL"
            else (
                pathlib.PurePosixPath(relative_path)
                / "Contents"
                / "_CodeSignature"
                / "CodeResources"
            ).as_posix()
        ),
        "codeResourcesSHA256": sha256(code_resources),
    }


def signed_entitlements(path: pathlib.Path, label: str) -> dict:
    try:
        entitlements = plistlib.loads(
            run(
                ["codesign", "-d", "--entitlements", "-", "--xml", str(path)]
            ).encode("utf-8")
        )
    except (plistlib.InvalidFileException, ValueError):
        fail(f"{label} entitlements are malformed")
    if not isinstance(entitlements, dict):
        fail(f"{label} entitlements are not a dictionary")
    return entitlements


def verify_nested_xpc_worker(
    application: pathlib.Path,
    *,
    bundle_path: pathlib.PurePosixPath,
    label: str,
    expected_identifier: str,
    expected_executable: str,
    expected_entitlements: dict,
    entitlement_boundary: str,
    allow_test_signatures: bool,
) -> dict:
    worker = directory(
        application.joinpath(*bundle_path.parts),
        f"nested {label} XPC service",
    )
    worker_info_path = regular_file(
        worker / "Contents" / "Info.plist",
        f"nested {label} Info.plist",
    )
    try:
        worker_info = plistlib.loads(worker_info_path.read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError):
        fail(f"nested {label} Info.plist is malformed")
    if worker_info.get("CFBundleIdentifier") != expected_identifier:
        fail(f"nested {label} bundle identifier is invalid")
    if worker_info.get("CFBundleExecutable") != expected_executable:
        fail(f"nested {label} CFBundleExecutable is invalid")
    if worker_info.get("CFBundlePackageType") != "XPC!":
        fail(f"nested {label} bundle package type is invalid")
    worker_service = worker_info.get("XPCService")
    if (
        not isinstance(worker_service, dict)
        or worker_service.get("ServiceType") != "Application"
    ):
        fail(f"nested {label} XPC service type is invalid")
    worker_executable = regular_file(
        worker / "Contents" / "MacOS" / expected_executable,
        f"nested {label} executable",
    )
    if worker_executable.stat().st_mode & 0o111 == 0:
        fail(f"nested {label} executable is not executable")
    require_arm64_macho(worker_executable, f"nested {label} executable")

    run(["codesign", "--verify", "--strict", str(worker)])
    try:
        return signed_identity_evidence(
            worker,
            relative_path=bundle_path.as_posix(),
            label=f"nested {label}",
            expected_identifier=expected_identifier,
            expected_executable=expected_executable,
            expected_package_type="XPC!",
            expected_entitlements=expected_entitlements,
            allow_test_signatures=allow_test_signatures,
        )
    except SystemExit as error:
        message = str(error)
        if "entitlements do not match their exact authority" in message:
            fail(
                f"nested {label} entitlements do not match its "
                f"{entitlement_boundary}"
            )
        raise


def source_commit(repo: pathlib.Path, explicit: str | None) -> str:
    value = explicit or run(["git", "rev-parse", "HEAD"], cwd=repo)
    value = value.strip().lower()
    if len(value) not in {40, 64} or any(character not in "0123456789abcdef" for character in value):
        fail("source commit must be an exact lowercase Git digest")
    return value


def recipe_digest(repo: pathlib.Path) -> str:
    inputs = [
        repo / "scripts/build-components.py",
        repo / "guest/kernel/build.sh",
        repo / "guest/initfs/build.sh",
        repo / "guest/desktop/build.sh",
    ]
    digest = hashlib.sha256()
    for path in inputs:
        file = regular_file(path, "component build recipe")
        relative = str(file.relative_to(repo)).encode("utf-8")
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        digest.update(file.read_bytes())
    return digest.hexdigest()


def generated_at(value: str | None) -> str:
    if value:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    elif os.environ.get("SOURCE_DATE_EPOCH"):
        parsed = dt.datetime.fromtimestamp(
            int(os.environ["SOURCE_DATE_EPOCH"]), tz=dt.timezone.utc
        )
    else:
        parsed = dt.datetime.now(tz=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def unique_json_object(pairs: list[tuple[str, object]]) -> dict:
    result: dict = {}
    for key, value in pairs:
        if key in result:
            fail(f"JSON contains duplicate key: {key}")
        result[key] = value
    return result


def exact_keys(value: object, required: set[str], optional: set[str], label: str) -> dict:
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    actual = set(value)
    if not required <= actual or not actual <= required | optional:
        fail(f"{label} has missing or unknown fields")
    return value


def nonempty_string(value: object, label: str, maximum_bytes: int = 256) -> str:
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > maximum_bytes:
        fail(f"{label} must be a bounded non-empty string")
    return value


def sha256_value(value: object, label: str) -> str:
    text = nonempty_string(value, label, 64)
    if len(text) != 64 or any(character not in "0123456789abcdef" for character in text):
        fail(f"{label} must be a lowercase SHA-256 digest")
    return text


def positive_integer_value(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        fail(f"{label} must be a positive integer")
    return value


def boolean_value(value: object, label: str) -> bool:
    if not isinstance(value, bool):
        fail(f"{label} must be a boolean")
    return value


def validate_qualification_record(value: object, index: int) -> dict:
    label = f"qualification record {index}"
    required = {
        "qualificationIdentity", "guest", "bootMediaKind", "bootMediaSource",
        "backend", "backendImplementationIdentifier", "backendRuntimeBuildIdentifier",
        "virtualHardwareABIVersion", "graphics", "devices",
        "hostHardwareModelIdentifier", "hostOperatingSystemBuild", "components",
        "virtioGPUKernelAndDeviceSupportQualified", "producerFenceBeforeFlushQualified",
        "venusVulkanGuestRuntimeQualified", "performanceQualification",
    }
    record = exact_keys(
        value,
        required,
        {"immutableArtifactSHA256", "mutableProvenance"},
        label,
    )
    nonempty_string(record["qualificationIdentity"], f"{label} identity")

    guest = exact_keys(record["guest"], {"family", "architecture"}, set(), f"{label} guest")
    if guest["family"] not in {"linux", "windows", "macos"}:
        fail(f"{label} guest family is unsupported")
    if guest["architecture"] not in {"arm64", "x86_64"}:
        fail(f"{label} guest architecture is unsupported")
    if record["bootMediaKind"] not in {
        "linux-kernel", "installer-iso", "virtual-disk", "installed-linux-boot-bundle",
        "macos-restore-image",
    }:
        fail(f"{label} boot media kind is unsupported")
    if record["bootMediaSource"] not in {
        "dory-bundled", "vendor-download", "user-provided",
    }:
        fail(f"{label} boot media source is unsupported")
    if record["backend"] not in {
        "dory-hypervisor", "apple-virtualization-framework", "qemu-hvf",
    }:
        fail(f"{label} backend is unsupported")
    if record["graphics"] not in {
        "none", "software", "host-accelerated-display", "hardware-accelerated-3d",
    }:
        fail(f"{label} graphics contract is unsupported")
    nonempty_string(record["backendImplementationIdentifier"], f"{label} implementation")
    nonempty_string(record["backendRuntimeBuildIdentifier"], f"{label} runtime build")
    positive_integer_value(record["virtualHardwareABIVersion"], f"{label} ABI")
    nonempty_string(record["hostHardwareModelIdentifier"], f"{label} host model")
    nonempty_string(record["hostOperatingSystemBuild"], f"{label} host build")

    immutable = record.get("immutableArtifactSHA256")
    mutable = record.get("mutableProvenance")
    if (immutable is None) == (mutable is None):
        fail(f"{label} must have exactly one immutable or mutable media identity")
    if immutable is not None:
        sha256_value(immutable, f"{label} immutable artifact")
    if mutable is not None:
        provenance = exact_keys(
            mutable,
            {"repositoryIdentity", "mediaIdentity", "revision"},
            set(),
            f"{label} mutable provenance",
        )
        nonempty_string(provenance["repositoryIdentity"], f"{label} repository identity")
        nonempty_string(provenance["mediaIdentity"], f"{label} media identity")
        positive_integer_value(provenance["revision"], f"{label} media revision")

    devices = exact_keys(
        record["devices"],
        {
            "networkAttachment", "audioInput", "audioOutput", "keyboard", "pointer",
            "directorySharing", "clipboard", "clockSynchronization", "dynamicDisplay",
            "gracefulShutdown",
        },
        set(),
        f"{label} devices",
    )
    if devices["networkAttachment"] not in {
        "disconnected", "shared-nat", "bridged", "isolated",
    }:
        fail(f"{label} network attachment is unsupported")
    for key in set(devices) - {"networkAttachment"}:
        boolean_value(devices[key], f"{label} device {key}")

    components = record["components"]
    if not isinstance(components, list) or not components:
        fail(f"{label} components must be a non-empty array")
    identifiers: list[str] = []
    for component_index, value in enumerate(components):
        component = exact_keys(
            value,
            {"componentIdentifier", "buildIdentifier", "artifactSHA256"},
            set(),
            f"{label} component {component_index}",
        )
        identifiers.append(nonempty_string(
            component["componentIdentifier"], f"{label} component identifier"
        ))
        nonempty_string(component["buildIdentifier"], f"{label} component build")
        sha256_value(component["artifactSHA256"], f"{label} component digest")
    if identifiers != sorted(identifiers) or len(set(identifiers)) != len(identifiers):
        fail(f"{label} components must be uniquely sorted by identifier")
    boolean_value(
        record["virtioGPUKernelAndDeviceSupportQualified"],
        f"{label} VirtIO GPU qualification",
    )
    boolean_value(
        record["producerFenceBeforeFlushQualified"],
        f"{label} producer fence-before-flush qualification",
    )
    boolean_value(
        record["venusVulkanGuestRuntimeQualified"],
        f"{label} Venus qualification",
    )
    performance = exact_keys(
        record["performanceQualification"],
        {
            "bundleInventorySHA256", "graphicsImplementation", "matrixCellID",
            "signaturePublicKeyID",
            "verificationReceiptPath", "verificationReceiptSHA256",
        },
        set(),
        f"{label} performance qualification",
    )
    sha256_value(
        performance["bundleInventorySHA256"],
        f"{label} performance bundle inventory",
    )
    sha256_value(performance["matrixCellID"], f"{label} matrix cell")
    nonempty_string(
        performance["graphicsImplementation"],
        f"{label} performance graphics implementation",
    )
    sha256_value(
        performance["signaturePublicKeyID"],
        f"{label} performance signing key",
    )
    expected_receipt_path = (
        performance["matrixCellID"] + PERFORMANCE_RECEIPT_SUFFIX
    )
    if performance["verificationReceiptPath"] != expected_receipt_path:
        fail(f"{label} performance receipt path does not bind its matrix cell")
    sha256_value(
        performance["verificationReceiptSHA256"],
        f"{label} performance verification receipt",
    )
    return record


def load_qualification_manifest(
    path: pathlib.Path,
    *,
    release_version: str,
    public_key_base64: str,
) -> dict:
    path = regular_file(path.resolve(), "VM qualification manifest")
    if path.stat().st_size > MAX_QUALIFICATION_BYTES:
        fail("VM qualification manifest exceeds the maximum size")
    try:
        public_key = base64.b64decode(public_key_base64, validate=True)
    except (ValueError, binascii.Error):
        fail("catalog public key is malformed")
    if len(public_key) != 32:
        fail("catalog public key must be a 32-byte Ed25519 key")
    try:
        manifest = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=unique_json_object,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"VM qualification manifest is unreadable: {error}")
    manifest = exact_keys(
        manifest,
        {
            "kind", "schemaVersion", "manifestIdentity", "catalogReleaseVersion",
            "architecture", "signingKeyID", "records",
        },
        {"candidateBinding"},
        "VM qualification manifest",
    )
    expected_key_id = hashlib.sha256(public_key).hexdigest()
    if manifest["kind"] != QUALIFICATION_KIND:
        fail("VM qualification manifest kind is invalid")
    schema_version = manifest["schemaVersion"]
    if (
        isinstance(schema_version, bool)
        or not isinstance(schema_version, int)
        or schema_version != QUALIFICATION_SCHEMA
    ):
        fail("VM qualification manifest schema is unsupported")
    nonempty_string(manifest["manifestIdentity"], "VM qualification manifest identity")
    if manifest["catalogReleaseVersion"] != release_version:
        fail("VM qualification manifest release does not match the catalog")
    if manifest["architecture"] != ARCHITECTURE:
        fail("VM qualification manifest architecture is unsupported")
    if manifest["signingKeyID"] != expected_key_id:
        fail("VM qualification manifest signing key does not match the catalog trust root")
    records = manifest["records"]
    if not isinstance(records, list) or not records:
        fail("VM qualification manifest must contain records")
    validated = [
        validate_qualification_record(record, index)
        for index, record in enumerate(records)
    ]
    identities = [record["qualificationIdentity"] for record in validated]
    if len(set(identities)) != len(identities):
        fail("VM qualification identities must be unique")
    if "candidateBinding" in manifest:
        binding = exact_keys(
            manifest["candidateBinding"],
            {"componentCandidateInventorySHA256", "sbomSHA256"},
            set(),
            "VM qualification candidate binding",
        )
        sha256_value(
            binding["componentCandidateInventorySHA256"],
            "VM qualification inventory binding",
        )
        sha256_value(binding["sbomSHA256"], "VM qualification SBOM binding")
    return manifest


def load_performance_verification_receipt(
    path: pathlib.Path,
    *,
    public_key_base64: str,
) -> dict:
    path = regular_file(path.resolve(), "Linux VM performance verification receipt")
    if path.stat().st_size > MAX_QUALIFICATION_BYTES:
        fail("Linux VM performance verification receipt exceeds the maximum size")
    receipt = load_json_file(
        path,
        "Linux VM performance verification receipt",
        MAX_QUALIFICATION_BYTES,
    )
    if path.read_bytes() != canonical_json_bytes(receipt):
        fail("Linux VM performance verification receipt is not canonical JSON")
    receipt = exact_keys(
        receipt,
        {
            "bundleInventorySHA256", "candidate", "kind", "releaseQualified",
            "schemaVersion", "signaturePublicKeyID", "supportCell",
        },
        set(),
        "Linux VM performance verification receipt",
    )
    try:
        public_key = base64.b64decode(public_key_base64, validate=True)
    except (ValueError, binascii.Error):
        fail("catalog public key is malformed")
    if len(public_key) != 32:
        fail("catalog public key must be a 32-byte Ed25519 key")
    expected_key_id = hashlib.sha256(public_key).hexdigest()
    if receipt["kind"] != PERFORMANCE_RECEIPT_KIND \
            or receipt["schemaVersion"] != PERFORMANCE_RECEIPT_SCHEMA:
        fail("Linux VM performance verification receipt kind or schema is unsupported")
    if receipt["releaseQualified"] is not True:
        fail("Linux VM performance verification receipt is not release-qualified")
    sha256_value(receipt["bundleInventorySHA256"], "performance bundle inventory")
    if receipt["signaturePublicKeyID"] != expected_key_id:
        fail("Linux VM performance verification receipt uses another trust root")

    candidate = exact_keys(
        receipt["candidate"],
        {
            "applicationSHA256", "budgetSetSHA256",
            "componentCandidateInventorySHA256", "runtimePlanSHA256", "sbomSHA256",
            "virtualHardwareABIVersion",
        },
        set(),
        "Linux VM performance candidate binding",
    )
    for field in (
        "applicationSHA256", "budgetSetSHA256", "componentCandidateInventorySHA256",
        "runtimePlanSHA256", "sbomSHA256",
    ):
        sha256_value(candidate[field], f"performance candidate {field}")
    abi = candidate["virtualHardwareABIVersion"]
    if not isinstance(abi, str) or not abi.isdecimal() \
            or str(int(abi)) != abi or not 1 <= int(abi) <= 65_535:
        fail("performance candidate virtual hardware ABI is invalid")

    support = exact_keys(
        receipt["supportCell"],
        {
            "backend", "graphicsImplementation", "hostIdentitySHA256",
            "installedSystemIdentitySHA256", "installerSHA256", "matrixCellID",
            "requestedGraphicsQuality", "selectedGraphicsQuality",
        },
        set(),
        "Linux VM performance support-cell binding",
    )
    if support["backend"] not in {"rawhv", "vz"}:
        fail("Linux VM performance support-cell backend is unsupported")
    for field in (
        "hostIdentitySHA256", "installedSystemIdentitySHA256", "installerSHA256",
        "matrixCellID",
    ):
        sha256_value(support[field], f"performance support cell {field}")
    nonempty_string(
        support["graphicsImplementation"],
        "performance support-cell graphics implementation",
    )
    for field in ("requestedGraphicsQuality", "selectedGraphicsQuality"):
        if support[field] not in {"accelerated", "software"}:
            fail(f"performance support-cell {field} is unsupported")
    if support["requestedGraphicsQuality"] != support["selectedGraphicsQuality"]:
        fail("release-qualified performance receipt contains a graphics fallback")
    return receipt


def canonical_json_bytes(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode(
        "utf-8"
    )


def write_bytes(path: pathlib.Path, value: bytes) -> None:
    path.write_bytes(value)
    os.chmod(path, 0o644)


def write_text(path: pathlib.Path, value: str, encoding: str = "ascii") -> None:
    path.write_text(value, encoding=encoding)
    os.chmod(path, 0o644)


def safe_release_value(value: object, label: str) -> str:
    result = nonempty_string(value, label)
    if any(character in result for character in ("/", "\\", "\x00")) or result in {".", ".."}:
        fail(f"{label} contains unsafe path characters")
    return result


def validate_asset_base_url(value: str) -> str:
    result = nonempty_string(value.rstrip("/"), "asset base URL", 2048)
    parsed = urllib.parse.urlsplit(result)
    if parsed.scheme != "https" or not parsed.netloc or parsed.query or parsed.fragment:
        fail("asset base URL must be an HTTPS URL without a query or fragment")
    return result


def artifact_name_from_url(value: object, asset_base_url: str) -> str:
    url = nonempty_string(value, "component asset URL", 4096)
    prefix = asset_base_url.rstrip("/") + "/"
    if not url.startswith(prefix):
        fail("component asset URL does not use the inventory asset base URL")
    parsed = urllib.parse.urlsplit(url)
    if parsed.query or parsed.fragment:
        fail("component asset URL cannot contain a query or fragment")
    encoded_name = pathlib.PurePosixPath(parsed.path).name
    name = urllib.parse.unquote(encoded_name)
    if (
        not name
        or name != encoded_name
        or name in {".", ".."}
        or any(character in name for character in ("/", "\\", "\x00"))
    ):
        fail("component asset URL has an unsafe filename")
    return name


def component_specs(
    source_root: pathlib.Path,
    kubectl: pathlib.Path,
    minimum_app_version: str,
) -> list[dict]:
    desktop_specs = []
    for distro, display, summary in (
        (
            "debian",
            "Debian 13 Desktop",
            "A stable Debian 13 Xfce desktop with its own packages and official repositories.",
        ),
        (
            "ubuntu",
            "Ubuntu 24.04 LTS Desktop",
            "Canonical's Ubuntu 24.04 LTS GNOME desktop with its own packages and official repositories.",
        ),
        (
            "kali",
            "Kali Linux Desktop",
            "A Kali rolling Xfce security desktop with its own packages and official repositories.",
        ),
    ):
        desktop_specs.append(
            {
                "id": f"desktop-{distro}",
                "displayName": display,
                "summary": summary,
                "dependencies": ["docker-core", "linux-desktop"],
                "provides": [f"guest.linux-desktop.{distro}.arm64@1"],
                "requires": [
                    f"app.dory-core>={minimum_app_version}",
                    "guest.linux-desktop-runtime.arm64@1",
                ],
                "assets": [
                    {
                        "path": f"dory-desktop-{distro}-rootfs-arm64.ext4.lzfse",
                        "source": source_root / f"dory-desktop-{distro}-rootfs-arm64.ext4",
                        "delivery": "lzfse-stored",
                        "executable": False,
                        "role": "guest-disk",
                        "bootMediaKind": "virtual-disk",
                    },
                    {
                        "path": f"dory-desktop-{distro}-build-arm64.stamp",
                        "source": source_root / f"dory-desktop-{distro}-build-arm64.stamp",
                        "delivery": "none",
                        "executable": False,
                        "role": "build-metadata",
                    },
                    {
                        "path": f"dory-desktop-{distro}-packages-arm64.txt",
                        "source": source_root / f"dory-desktop-{distro}-packages-arm64.txt",
                        "delivery": "none",
                        "executable": False,
                        "role": "guest-package-manifest",
                    },
                    {
                        "path": f"dory-desktop-{distro}-update-arm64.tar",
                        "source": source_root / f"dory-desktop-{distro}-update-arm64.tar",
                        "delivery": "none",
                        "executable": False,
                        "role": "guest-update",
                    },
                ],
            }
        )
    return [
        {
            "id": "kubernetes",
            "displayName": "Kubernetes",
            "summary": "kubectl and Dory's local k3s workflow. The selected k3s image downloads when you create the cluster.",
            "dependencies": ["docker-core"],
            "provides": ["cli.kubectl@1"],
            "requires": [f"app.dory-core>={minimum_app_version}"],
            "assets": [
                {
                    "path": "kubectl",
                    "source": kubectl,
                    "delivery": "none",
                    "executable": True,
                    "role": "host-cli",
                }
            ],
        },
        {
            "id": "linux-machines",
            "displayName": "Linux Machines",
            "summary": "Headless VPS-style Linux machines with terminals, services, and persistent disks.",
            "dependencies": ["docker-core"],
            "provides": ["guest.linux-headless.arm64@1"],
            "requires": [f"app.dory-core>={minimum_app_version}"],
            "assets": [
                {
                    "path": "dory-hv-kernel-arm64",
                    "source": source_root / "Image",
                    "delivery": "lzfse-expanded",
                    "executable": False,
                    "role": "guest-kernel",
                    "bootMediaKind": "linux-kernel",
                },
                {
                    "path": "dory-machine-rootfs-arm64.ext4",
                    "source": source_root / "initfs-arm64.ext4",
                    "delivery": "lzfse-expanded",
                    "executable": False,
                    "role": "guest-disk",
                    "bootMediaKind": "virtual-disk",
                },
            ],
        },
        {
            "id": "linux-desktop",
            "displayName": "Linux Desktop Runtime",
            "summary": "The graphical VM kernel shared by independently installable desktop distributions.",
            "dependencies": ["docker-core"],
            # Device-level GPU claims are deliberately absent from the unqualified inventory.
            # A future qualification policy may derive them conjunctively from signed records.
            "provides": ["guest.linux-desktop-runtime.arm64@1"],
            "requires": [f"app.dory-core>={minimum_app_version}"],
            "assets": [
                {
                    "path": "dory-desktop-kernel-arm64.lzfse",
                    "source": source_root / "Image-desktop",
                    "delivery": "lzfse-stored",
                    "executable": False,
                    "role": "guest-kernel",
                    "bootMediaKind": "linux-kernel",
                },
                {
                    "path": "kernel-build-arm64-desktop.stamp",
                    "source": source_root / "kernel-build-arm64-desktop.stamp",
                    "delivery": "none",
                    "executable": False,
                    "role": "build-metadata",
                },
            ],
        },
        *desktop_specs,
    ]


def safe_artifact_name(
    version: str, component_id: str, installed_path: str, compressed: bool
) -> str:
    suffix = safe_release_value(installed_path, "installed asset path")
    if compressed and not suffix.endswith(".lzfse"):
        suffix += ".lzfse"
    return f"Dory-{version}-component-{component_id}-{ARCHITECTURE}-{suffix}"


def materialize_asset(
    *,
    version: str,
    component_id: str,
    asset: dict,
    output: pathlib.Path,
    asset_base_url: str,
    compression_tool: pathlib.Path,
    allow_test_code_requirement: bool,
) -> dict:
    source = regular_file(pathlib.Path(asset["source"]), f"{component_id} source")
    delivery = asset["delivery"]
    if delivery not in {"none", "lzfse-expanded", "lzfse-stored"}:
        fail(f"{component_id} has an unsupported asset delivery mode")
    compressed = delivery in {"lzfse-expanded", "lzfse-stored"}
    artifact_name = safe_artifact_name(version, component_id, asset["path"], compressed)
    destination = output / artifact_name
    if compressed:
        run(
            [
                str(compression_tool),
                "-encode",
                "-a",
                "lzfse",
                "-i",
                str(source),
                "-o",
                str(destination),
            ]
        )
    else:
        shutil.copyfile(source, destination)
    os.chmod(destination, 0o644)

    download_bytes = byte_size(destination)
    download_digest = sha256(destination)
    if delivery == "lzfse-expanded":
        compression = "lzfse"
        installed_bytes = byte_size(source)
        installed_digest = sha256(source)
    else:
        compression = "none"
        installed_bytes = download_bytes
        installed_digest = download_digest
    result = {
        "path": asset["path"],
        "role": asset["role"],
        "url": f"{asset_base_url}/{artifact_name}",
        "compression": compression,
        "downloadBytes": download_bytes,
        "installedBytes": installed_bytes,
        "sha256": download_digest,
        "installedSHA256": installed_digest,
        "executable": bool(asset["executable"]),
    }
    if asset["executable"]:
        result["codeRequirement"] = (
            f'identifier "dev.dory.test.{installed_digest[:16]}"'
            if allow_test_code_requirement
            else designated_code_requirement(source)
        )
    return result


def unqualified_release(
    *, version: str, spec: dict, assets: list[dict]
) -> dict:
    return {
        "id": spec["id"],
        "version": version,
        "displayName": spec["displayName"],
        "summary": spec["summary"],
        "dependencies": spec["dependencies"],
        "downloadBytes": sum(asset["downloadBytes"] for asset in assets),
        "installedBytes": sum(asset["installedBytes"] for asset in assets),
        "assets": assets,
        "architectures": [ARCHITECTURE],
        "hostRequirements": {"platform": "macos", "minimumVersion": "14.0"},
        "provides": spec["provides"],
        "requires": spec["requires"],
    }


def signed_application_binding(
    application: pathlib.Path,
    *,
    label: str,
    relative_path: str,
    expected_identifier: str,
    expected_executable: str,
    expected_entitlements: dict,
    requires_hv_workers: bool,
    allow_test_signatures: bool,
    required_usage_descriptions: tuple[str, ...] = (),
) -> dict:
    application = directory(application, f"nested {label} application")
    info_path = regular_file(
        application / "Contents" / "Info.plist", f"nested {label} Info.plist"
    )
    try:
        info = plistlib.loads(info_path.read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError):
        fail(f"nested {label} Info.plist is malformed")
    if info.get("CFBundleIdentifier") != expected_identifier:
        fail(f"nested {label} bundle identifier is invalid")
    if info.get("CFBundleExecutable") != expected_executable:
        fail(f"nested {label} CFBundleExecutable is invalid")
    if info.get("CFBundlePackageType") != "APPL":
        fail(f"nested {label} bundle package type is invalid")
    for usage_key in required_usage_descriptions:
        usage_value = info.get(usage_key)
        if not isinstance(usage_value, str) or not usage_value.strip():
            fail(f"nested {label} is missing {usage_key}")
    executable = regular_file(
        application / "Contents" / "MacOS" / expected_executable,
        f"nested {label} executable",
    )
    if executable.stat().st_mode & 0o111 == 0:
        fail(f"nested {label} executable is not executable")
    require_arm64_macho(executable, f"nested {label} executable")

    # Verify inside-out before binding every byte in the complete signed graph.
    nested_bundles = []
    if requires_hv_workers:
        xpc_root = directory(
            application / "Contents" / "XPCServices",
            "nested runner XPCServices",
        )
        expected_workers = {
            FS_WORKER_BUNDLE_PATH.name,
            RENDERER_WORKER_BUNDLE_PATH.name,
        }
        actual_workers = {entry.name for entry in xpc_root.iterdir()}
        if actual_workers != expected_workers:
            fail("nested runner XPC worker graph is not exact")
        nested_bundles.append(verify_nested_xpc_worker(
            application,
            bundle_path=FS_WORKER_BUNDLE_PATH,
            label="filesystem worker",
            expected_identifier=FS_WORKER_IDENTIFIER,
            expected_executable=FS_WORKER_EXECUTABLE,
            expected_entitlements=EXPECTED_FS_WORKER_ENTITLEMENTS,
            entitlement_boundary="descriptor capability boundary",
            allow_test_signatures=allow_test_signatures,
        ))
        nested_bundles.append(verify_nested_xpc_worker(
            application,
            bundle_path=RENDERER_WORKER_BUNDLE_PATH,
            label="renderer worker",
            expected_identifier=RENDERER_WORKER_IDENTIFIER,
            expected_executable=RENDERER_WORKER_EXECUTABLE,
            expected_entitlements=EXPECTED_RENDERER_WORKER_ENTITLEMENTS,
            entitlement_boundary="minimal sandbox",
            allow_test_signatures=allow_test_signatures,
        ))
    elif os.path.lexists(application / "Contents" / "XPCServices"):
        fail(f"nested {label} application must not contain XPC workers")
    run(["codesign", "--verify", "--deep", "--strict", str(application)])
    try:
        application_identity = signed_identity_evidence(
            application,
            relative_path=relative_path,
            label=f"nested {label}",
            expected_identifier=expected_identifier,
            expected_executable=expected_executable,
            expected_package_type="APPL",
            expected_entitlements=expected_entitlements,
            allow_test_signatures=allow_test_signatures,
        )
    except SystemExit as error:
        message = str(error)
        if "entitlements do not match their exact authority" in message:
            fail(f"nested {label} entitlements do not match its hardware boundary")
        raise

    files = []
    for candidate in sorted(application.rglob("*")):
        entry = candidate.lstat()
        if stat.S_ISDIR(entry.st_mode):
            continue
        if not stat.S_ISREG(entry.st_mode):
            fail(f"nested {label} contains an indirect or special entry: {candidate}")
        relative = candidate.relative_to(application).as_posix()
        if len(relative.encode("utf-8")) > 1024 or any(
            part in {"", ".", ".."} for part in pathlib.PurePosixPath(relative).parts
        ):
            fail(f"nested {label} contains an unsafe path: {relative}")
        files.append(
            {
                "path": relative,
                "bytes": entry.st_size,
                "mode": stat.S_IMODE(entry.st_mode),
                "sha256": sha256(candidate),
            }
        )
    if not files or len(files) > 512:
        fail(f"nested {label} signed graph has an invalid file count")
    binding = {
        **application_identity,
        "nestedBundles": nested_bundles,
        "files": files,
    }
    binding["graphSHA256"] = hashlib.sha256(canonical_json_bytes(binding)).hexdigest()
    return binding


def outer_application_binding(
    application: pathlib.Path,
    *,
    release_version: str,
    allow_test_signatures: bool,
) -> dict:
    application = directory(application, "outer Dory application")
    info_path = regular_file(
        application / "Contents" / "Info.plist", "outer Dory Info.plist"
    )
    try:
        info = plistlib.loads(info_path.read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError):
        fail("outer Dory Info.plist is malformed")
    if info.get("CFBundleIdentifier") != OUTER_APPLICATION_IDENTIFIER:
        fail("outer Dory bundle identifier is invalid")
    if info.get("CFBundleExecutable") != OUTER_APPLICATION_EXECUTABLE:
        fail("outer Dory CFBundleExecutable is invalid")
    if info.get("CFBundlePackageType") != "APPL":
        fail("outer Dory bundle package type is invalid")
    if info.get("CFBundleShortVersionString") != release_version:
        fail("outer Dory marketing version does not match the component release")
    bundle_version = safe_release_value(
        info.get("CFBundleVersion"), "outer Dory bundle version"
    )
    executable = regular_file(
        application / "Contents" / "MacOS" / OUTER_APPLICATION_EXECUTABLE,
        "outer Dory executable",
    )
    if executable.stat().st_mode & 0o111 == 0:
        fail("outer Dory executable is not executable")
    require_arm64_macho(executable, "outer Dory executable")
    run(["codesign", "--verify", "--deep", "--strict", str(application)])
    identity = signed_identity_evidence(
        application,
        relative_path="Dory.app",
        label="outer Dory application",
        expected_identifier=OUTER_APPLICATION_IDENTIFIER,
        expected_executable=OUTER_APPLICATION_EXECUTABLE,
        expected_package_type="APPL",
        expected_entitlements=EXPECTED_OUTER_APPLICATION_ENTITLEMENTS,
        allow_test_signatures=allow_test_signatures,
    )
    return {
        **identity,
        "bundleShortVersion": release_version,
        "bundleVersion": bundle_version,
        "executableBytes": byte_size(executable),
        "executableSHA256": sha256(executable),
    }


def disk_image_application_binding(
    artifact: pathlib.Path,
    *,
    expected_application: dict,
) -> dict:
    artifact = regular_file(artifact, "Docker Core disk image")
    if artifact.suffix.lower() != ".dmg":
        fail("Docker Core artifact must be an Apple disk image")
    before_info = artifact.lstat()
    # DiskImages may update a verification xattr on first attachment, which changes ctime without
    # changing the direct file, its mode, its bytes, or its release identity. Keep the byte-level
    # TOCTOU check strict while excluding that reader-induced metadata side effect.
    before_identity = (
        before_info.st_dev,
        before_info.st_ino,
        before_info.st_mode,
        before_info.st_size,
        before_info.st_mtime_ns,
    )
    before_digest = sha256(artifact)
    mount_parent = pathlib.Path(tempfile.mkdtemp(prefix="dory-core-dmg-"))
    mount_point = mount_parent / "volume"
    mount_point.mkdir(mode=0o700)
    attached = False
    try:
        run(
            [
                "hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
                "-owners", "off", "-mountpoint", str(mount_point), str(artifact),
            ]
        )
        attached = True
        mounted_application = directory(
            mount_point / "Dory.app", "Docker Core disk-image Dory.app"
        )
        mounted_binding = application_tree_binding(mounted_application)
        if mounted_binding != expected_application:
            fail("Docker Core disk image does not contain the exact supplied Dory.app")
    finally:
        if attached:
            completed = subprocess.run(
                ["hdiutil", "detach", str(mount_point)],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            if completed.returncode != 0:
                fail("could not detach the verified Docker Core disk image")
        shutil.rmtree(mount_parent, ignore_errors=True)
    after_info = artifact.lstat()
    after_identity = (
        after_info.st_dev,
        after_info.st_ino,
        after_info.st_mode,
        after_info.st_size,
        after_info.st_mtime_ns,
    )
    if after_identity != before_identity or sha256(artifact) != before_digest:
        fail("Docker Core disk image changed while its application was verified")
    return {
        "bytes": before_identity[3],
        "sha256": before_digest,
        "format": "apple-disk-image",
        "embeddedApplicationPath": "Dory.app",
        "embeddedApplicationGraphSHA256": expected_application["graphSHA256"],
    }


def core_binding(
    core_artifact: pathlib.Path,
    core_app: pathlib.Path,
    *,
    release_version: str,
    allow_test_signatures: bool,
) -> dict:
    application_tree = application_tree_binding(core_app)
    helpers = []
    helper_paths = {
        "dory-hv": "Contents/Helpers/DoryHVRunner.app/Contents/MacOS/dory-hv",
        "dory-vmm": "Contents/Helpers/DoryVMM.app/Contents/MacOS/dory-vmm",
    }
    for identifier in ("dory-hv", "dory-vmm"):
        relative_path = helper_paths[identifier]
        helper = regular_file(core_app / relative_path, f"{identifier} candidate helper")
        if helper.stat().st_mode & 0o111 == 0:
            fail(f"{identifier} candidate helper is not executable")
        record = {
            "componentIdentifier": identifier,
            "path": relative_path,
            "bytes": byte_size(helper),
            "sha256": sha256(helper),
            "executable": True,
        }
        if identifier == "dory-hv":
            record["signedBundle"] = signed_application_binding(
                core_app / "Contents/Helpers/DoryHVRunner.app",
                label="runner",
                relative_path="Contents/Helpers/DoryHVRunner.app",
                expected_identifier="com.pythonxi.Dory.HVRunner",
                expected_executable="dory-hv",
                expected_entitlements=EXPECTED_RUNNER_ENTITLEMENTS,
                requires_hv_workers=True,
                allow_test_signatures=allow_test_signatures,
                required_usage_descriptions=(
                    "NSCameraUsageDescription", "NSMicrophoneUsageDescription",
                ),
            )
        else:
            record["signedBundle"] = signed_application_binding(
                core_app.joinpath(*VMM_BUNDLE_PATH.parts),
                label="VMM",
                relative_path=VMM_BUNDLE_PATH.as_posix(),
                expected_identifier=VMM_IDENTIFIER,
                expected_executable=VMM_EXECUTABLE,
                expected_entitlements=EXPECTED_VMM_ENTITLEMENTS,
                requires_hv_workers=False,
                allow_test_signatures=allow_test_signatures,
                required_usage_descriptions=("NSMicrophoneUsageDescription",),
            )
        helpers.append(record)
    application = {
        **application_tree,
        "signedBundle": outer_application_binding(
            core_app,
            release_version=release_version,
            allow_test_signatures=allow_test_signatures,
        ),
    }
    artifact = disk_image_application_binding(
        core_artifact,
        expected_application=application_tree,
    )
    if application_tree_binding(core_app) != application_tree:
        fail("outer Dory application changed while its release binding was created")
    return {
        "artifact": artifact,
        "application": application,
        "installedBytes": application["regularFileBytes"],
        "helpers": helpers,
    }


def candidate_file_records(components: list[dict], asset_base_url: str) -> list[dict]:
    records = []
    names: set[str] = set()
    for component in components:
        for asset in component["assets"]:
            name = artifact_name_from_url(asset["url"], asset_base_url)
            if name in names:
                fail(f"candidate inventory repeats stored asset: {name}")
            names.add(name)
            records.append(
                {
                    "name": name,
                    "bytes": asset["downloadBytes"],
                    "sha256": asset["sha256"],
                }
            )
    return sorted(records, key=lambda item: item["name"])


def build_candidate_inventory(args: argparse.Namespace, repo: pathlib.Path) -> None:
    version = safe_release_value(args.version, "release version")
    minimum_app_version = safe_release_value(
        args.minimum_app_version or version, "minimum app version"
    )
    source_root = (args.source_root or repo / "guest" / "out").resolve()
    core_artifact, core_app = resolved_core_inputs(args)
    kubectl = regular_file(args.kubectl.resolve(), "kubectl")
    compression_tool = regular_file(
        pathlib.Path("/usr/bin/compression_tool"), "macOS compression_tool"
    )
    if not args.skip_source_verification:
        validate_sources(repo, source_root, kubectl)

    asset_base_url = validate_asset_base_url(
        args.asset_base_url
        or f"https://github.com/Augani/dory/releases/download/v{version}"
    )
    output_argument = absolute_without_resolving(args.output)
    if output_argument.is_symlink():
        fail("component candidate output cannot be a symbolic link")
    output_argument.parent.mkdir(parents=True, exist_ok=True)
    output_parent = directory(
        output_argument.parent, "component candidate output parent"
    ).resolve()
    output = output_parent / output_argument.name
    if output in {
        pathlib.Path("/"),
        pathlib.Path.home().resolve(),
        pathlib.Path.cwd().resolve(),
    }:
        fail(f"refusing unsafe component candidate output: {output}")
    staging: pathlib.Path | None = pathlib.Path(
        tempfile.mkdtemp(prefix=f".{output.name}.partial-", dir=output.parent)
    )
    try:
        core = core_binding(
            core_artifact,
            core_app,
            release_version=version,
            allow_test_signatures=args.skip_source_verification,
        )
        components = [
            {
                "id": "docker-core",
                "version": version,
                "displayName": "Docker Core",
                "summary": "The signed Dory app, Docker engine, CLI, Buildx, Compose, networking, storage, migration, and health tools.",
                "dependencies": [],
                "downloadBytes": core["artifact"]["bytes"],
                "installedBytes": core["installedBytes"],
                "assets": [],
                "architectures": [ARCHITECTURE],
                "hostRequirements": {"platform": "macos", "minimumVersion": "14.0"},
                "provides": [
                    f"app.dory-core@{version}",
                    "backend.rawhv-linux@1",
                    "backend.vz-linux@1",
                ],
                "requires": [],
            }
        ]
        media_bindings = []
        for spec in component_specs(source_root, kubectl, minimum_app_version):
            materialized = []
            for source_asset in spec["assets"]:
                result = materialize_asset(
                    version=version,
                    component_id=spec["id"],
                    asset=source_asset,
                    output=staging,
                    asset_base_url=asset_base_url,
                    compression_tool=compression_tool,
                    allow_test_code_requirement=args.skip_source_verification,
                )
                materialized.append(result)
                if "bootMediaKind" in source_asset:
                    media_bindings.append(
                        {
                            "componentIdentifier": spec["id"],
                            "assetPath": result["path"],
                            "bootMediaKind": source_asset["bootMediaKind"],
                            "delivery": source_asset["delivery"],
                            "immutableArtifactSHA256": sha256(
                                pathlib.Path(source_asset["source"])
                            ),
                            "storedSHA256": result["sha256"],
                        }
                    )
            components.append(
                unqualified_release(version=version, spec=spec, assets=materialized)
            )

        inventory = {
            "kind": INVENTORY_KIND,
            "schemaVersion": INVENTORY_SCHEMA,
            "releaseVersion": version,
            "generatedAt": generated_at(args.generated_at),
            "minimumAppVersion": minimum_app_version,
            "architecture": ARCHITECTURE,
            "assetBaseURL": asset_base_url,
            "sourceCommit": source_commit(repo, args.source_commit),
            "builder": nonempty_string(args.builder_identity, "builder identity"),
            "recipeDigest": recipe_digest(repo),
            "core": core,
            "mediaBindings": sorted(
                media_bindings,
                key=lambda item: (item["componentIdentifier"], item["assetPath"]),
            ),
            "components": components,
            "files": candidate_file_records(components, asset_base_url),
        }
        validate_candidate_inventory(inventory)
        write_bytes(staging / INVENTORY_PATH, canonical_json_bytes(inventory))
        write_text(
            staging / INVENTORY_DIGEST_PATH,
            sha256(staging / INVENTORY_PATH) + "\n",
        )
        validate_candidate_directory(staging, inventory, exact=True)
        publish(staging, output)
        staging = None
    finally:
        if staging is not None and staging.exists():
            remove_private_build_directory(staging, output.parent)


def load_json_file(path: pathlib.Path, label: str, maximum_bytes: int) -> object:
    path = regular_file(path, label)
    if path.stat().st_size > maximum_bytes:
        fail(f"{label} exceeds the maximum size")
    try:
        return json.loads(
            path.read_text(encoding="utf-8"), object_pairs_hook=unique_json_object
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"{label} is unreadable: {error}")


def validate_string_array(value: object, label: str) -> list[str]:
    if not isinstance(value, list):
        fail(f"{label} must be an array")
    result = [nonempty_string(item, label) for item in value]
    if len(result) != len(set(result)):
        fail(f"{label} contains duplicate values")
    return result


def validate_inventory_asset(
    value: object, *, label: str, asset_base_url: str
) -> tuple[dict, str]:
    asset = exact_keys(
        value,
        {
            "path", "role", "url", "compression", "downloadBytes", "installedBytes",
            "sha256", "installedSHA256", "executable",
        },
        {"codeRequirement"},
        label,
    )
    safe_release_value(asset["path"], f"{label} path")
    nonempty_string(asset["role"], f"{label} role")
    name = artifact_name_from_url(asset["url"], asset_base_url)
    if asset["compression"] not in {"none", "lzfse"}:
        fail(f"{label} has unsupported compression")
    positive_integer_value(asset["downloadBytes"], f"{label} download bytes")
    positive_integer_value(asset["installedBytes"], f"{label} installed bytes")
    sha256_value(asset["sha256"], f"{label} stored digest")
    sha256_value(asset["installedSHA256"], f"{label} installed digest")
    executable = boolean_value(asset["executable"], f"{label} executable")
    if executable:
        nonempty_string(asset.get("codeRequirement"), f"{label} code requirement", 4096)
    elif "codeRequirement" in asset:
        fail(f"{label} has a code requirement but is not executable")
    return asset, name


SIGNED_IDENTITY_KEYS = {
    "path", "bundleIdentifier", "bundleExecutable", "bundlePackageType",
    "designatedRequirement", "signatureKind", "teamIdentifier",
    "hardenedRuntime", "entitlements", "codeResourcesPath",
    "codeResourcesSHA256",
}


def validate_signed_identity_evidence(
    value: object,
    configuration: dict,
    label: str,
) -> dict:
    identity = exact_keys(value, SIGNED_IDENTITY_KEYS, set(), label)
    for field, expected in (
        ("path", configuration["path"]),
        ("bundleIdentifier", configuration["identifier"]),
        ("bundleExecutable", configuration["executable"]),
        ("bundlePackageType", configuration["packageType"]),
        ("entitlements", configuration["entitlements"]),
        ("codeResourcesPath", configuration["codeResourcesPath"]),
    ):
        if identity[field] != expected:
            fail(f"{label} {field} is invalid")
    sha256_value(identity["codeResourcesSHA256"], f"{label} CodeResources digest")
    signature_kind = identity["signatureKind"]
    if signature_kind == "developer-id-application":
        expected_team = SIGNING_TEAM_IDENTIFIER
        expected_runtime = True
        expected_requirement = developer_id_designated_requirement(
            configuration["identifier"]
        )
    elif signature_kind == "adhoc-test":
        expected_team = "-"
        expected_runtime = False
        expected_requirement = test_designated_requirement(configuration["identifier"])
    else:
        fail(f"{label} signature kind is invalid")
    if identity["teamIdentifier"] != expected_team:
        fail(f"{label} team identifier is invalid")
    if identity["hardenedRuntime"] is not expected_runtime:
        fail(f"{label} hardened-runtime evidence is invalid")
    if identity["designatedRequirement"] != expected_requirement:
        fail(f"{label} designated requirement is not canonical")
    return identity


def validate_core_signed_bundle(helper: dict, identifier: str) -> None:
    configurations = {
        "dory-hv": {
            "path": "Contents/Helpers/DoryHVRunner.app",
            "identifier": "com.pythonxi.Dory.HVRunner",
            "executable": "dory-hv",
            "packageType": "APPL",
            "entitlements": EXPECTED_RUNNER_ENTITLEMENTS,
            "codeResourcesPath": "Contents/_CodeSignature/CodeResources",
            "nestedBundles": (
                {
                    "label": "filesystem worker",
                    "path": FS_WORKER_BUNDLE_PATH.as_posix(),
                    "identifier": FS_WORKER_IDENTIFIER,
                    "executable": FS_WORKER_EXECUTABLE,
                    "packageType": "XPC!",
                    "entitlements": EXPECTED_FS_WORKER_ENTITLEMENTS,
                    "codeResourcesPath": (
                        FS_WORKER_BUNDLE_PATH
                        / "Contents" / "_CodeSignature" / "CodeResources"
                    ).as_posix(),
                },
                {
                    "label": "renderer worker",
                    "path": RENDERER_WORKER_BUNDLE_PATH.as_posix(),
                    "identifier": RENDERER_WORKER_IDENTIFIER,
                    "executable": RENDERER_WORKER_EXECUTABLE,
                    "packageType": "XPC!",
                    "entitlements": EXPECTED_RENDERER_WORKER_ENTITLEMENTS,
                    "codeResourcesPath": (
                        RENDERER_WORKER_BUNDLE_PATH
                        / "Contents" / "_CodeSignature" / "CodeResources"
                    ).as_posix(),
                },
            ),
        },
        "dory-vmm": {
            "path": VMM_BUNDLE_PATH.as_posix(),
            "identifier": VMM_IDENTIFIER,
            "executable": VMM_EXECUTABLE,
            "packageType": "APPL",
            "entitlements": EXPECTED_VMM_ENTITLEMENTS,
            "codeResourcesPath": "Contents/_CodeSignature/CodeResources",
            "nestedBundles": (),
        },
    }
    configuration = configurations.get(identifier)
    if configuration is None:
        fail(f"{identifier} cannot declare a core signed bundle")
    label = f"{identifier} signed bundle"
    signed_bundle = exact_keys(
        helper["signedBundle"],
        SIGNED_IDENTITY_KEYS | {"nestedBundles", "files", "graphSHA256"},
        set(),
        label,
    )
    root_identity = validate_signed_identity_evidence(
        {key: signed_bundle[key] for key in SIGNED_IDENTITY_KEYS},
        configuration,
        label,
    )
    nested_values = signed_bundle["nestedBundles"]
    nested_configurations = configuration["nestedBundles"]
    if not isinstance(nested_values, list) \
            or len(nested_values) != len(nested_configurations):
        fail(f"{label} nested signed graph is invalid")
    nested_identities = []
    for index, (nested_value, nested_configuration) in enumerate(
        zip(nested_values, nested_configurations, strict=True)
    ):
        nested_identities.append(
            validate_signed_identity_evidence(
                nested_value,
                nested_configuration,
                f"{label} {nested_configuration['label']} {index}",
            )
        )
    files = signed_bundle["files"]
    if not isinstance(files, list) or not files or len(files) > 512:
        fail(f"{label} file graph is invalid")
    previous_path = ""
    file_records = {}
    for file_index, file_value in enumerate(files):
        file_record = exact_keys(
            file_value,
            {"path", "bytes", "mode", "sha256"},
            set(),
            f"{label} file {file_index}",
        )
        relative = nonempty_string(
            file_record["path"],
            f"{label} file {file_index} path",
            1024,
        )
        parts = pathlib.PurePosixPath(relative).parts
        if relative.startswith("/") or any(part in {"", ".", ".."} for part in parts):
            fail(f"{label} contains an unsafe file path")
        if relative <= previous_path:
            fail(f"{label} files are not uniquely sorted")
        previous_path = relative
        positive_integer_value(file_record["bytes"], f"{label} file bytes")
        mode = file_record["mode"]
        if isinstance(mode, bool) or not isinstance(mode, int) or not 0 <= mode <= 0o7777:
            fail(f"{label} file mode is invalid")
        sha256_value(file_record["sha256"], f"{label} file digest")
        if identifier == "dory-vmm" and parts[:2] == ("Contents", "XPCServices"):
            fail("dory-vmm signed bundle must not contain XPC workers")
        file_records[relative] = file_record

    required_records = {
        "Contents/Info.plist": f"{label} Info.plist",
        root_identity["codeResourcesPath"]: f"{label} CodeResources seal",
    }
    executable_relative = f"Contents/MacOS/{configuration['executable']}"
    required_records[executable_relative] = f"{label} declared executable"
    declared_executables = {executable_relative}
    for nested_identity, nested_configuration in zip(
        nested_identities, nested_configurations, strict=True
    ):
        nested_path = pathlib.PurePosixPath(nested_configuration["path"])
        required_records[(nested_path / "Contents" / "Info.plist").as_posix()] = (
            f"{label} {nested_configuration['label']} Info.plist"
        )
        nested_executable = (
            nested_path / "Contents" / "MacOS" / nested_configuration["executable"]
        ).as_posix()
        required_records[nested_executable] = (
            f"{label} {nested_configuration['label']} executable"
        )
        required_records[nested_identity["codeResourcesPath"]] = (
            f"{label} {nested_configuration['label']} CodeResources seal"
        )
        declared_executables.add(nested_executable)
    for required_path, required_label in required_records.items():
        if required_path not in file_records:
            fail(f"{label} does not contain its required {required_label}")

    executable_record = file_records[executable_relative]
    if executable_record["mode"] & 0o111 == 0:
        fail(f"{label} declared executable is not executable")
    if (
        executable_record["bytes"] != helper["bytes"]
        or executable_record["sha256"] != helper["sha256"]
    ):
        fail(f"{identifier} executable binding differs from its signed bundle graph")

    for executable_path in declared_executables:
        if file_records[executable_path]["mode"] & 0o111 == 0:
            fail(f"{label} executable binding is not executable")
    for relative in file_records:
        if (
            relative.startswith("Contents/MacOS/")
            or "/Contents/MacOS/" in relative
        ) and relative not in declared_executables:
            fail(f"{label} contains an undeclared bundle executable")
    identity_records = [root_identity] + nested_identities
    for identity in identity_records:
        seal_record = file_records[identity["codeResourcesPath"]]
        if seal_record["sha256"] != identity["codeResourcesSHA256"]:
            fail(f"{label} CodeResources evidence differs from its signed graph")

    graph_payload = dict(signed_bundle)
    graph_digest = graph_payload.pop("graphSHA256")
    sha256_value(graph_digest, f"{label} graph digest")
    if hashlib.sha256(canonical_json_bytes(graph_payload)).hexdigest() != graph_digest:
        fail(f"{label} graph digest is invalid")


def validate_outer_application_signed_bundle(
    value: object,
    *,
    release_version: str,
) -> dict:
    label = "outer Dory signed bundle"
    bundle = exact_keys(
        value,
        SIGNED_IDENTITY_KEYS
        | {
            "bundleShortVersion",
            "bundleVersion",
            "executableBytes",
            "executableSHA256",
        },
        set(),
        label,
    )
    validate_signed_identity_evidence(
        {key: bundle[key] for key in SIGNED_IDENTITY_KEYS},
        {
            "path": "Dory.app",
            "identifier": OUTER_APPLICATION_IDENTIFIER,
            "executable": OUTER_APPLICATION_EXECUTABLE,
            "packageType": "APPL",
            "entitlements": EXPECTED_OUTER_APPLICATION_ENTITLEMENTS,
            "codeResourcesPath": "Contents/_CodeSignature/CodeResources",
        },
        label,
    )
    if bundle["bundleShortVersion"] != release_version:
        fail("outer Dory signed bundle release version is invalid")
    safe_release_value(bundle["bundleVersion"], "outer Dory signed bundle build version")
    positive_integer_value(
        bundle["executableBytes"], "outer Dory signed bundle executable bytes"
    )
    sha256_value(
        bundle["executableSHA256"], "outer Dory signed bundle executable digest"
    )
    return bundle


def validate_candidate_inventory(value: object) -> dict:
    inventory = exact_keys(
        value,
        {
            "kind", "schemaVersion", "releaseVersion", "generatedAt",
            "minimumAppVersion", "architecture", "assetBaseURL", "sourceCommit",
            "builder", "recipeDigest", "core", "mediaBindings", "components", "files",
        },
        set(),
        "component candidate inventory",
    )
    if inventory["kind"] != INVENTORY_KIND or inventory["schemaVersion"] != INVENTORY_SCHEMA:
        fail("component candidate inventory kind or schema is unsupported")
    version = safe_release_value(inventory["releaseVersion"], "inventory release version")
    nonempty_string(inventory["generatedAt"], "inventory generation time")
    safe_release_value(inventory["minimumAppVersion"], "inventory minimum app version")
    if inventory["architecture"] != ARCHITECTURE:
        fail("component candidate inventory architecture is unsupported")
    asset_base_url = validate_asset_base_url(inventory["assetBaseURL"])
    commit = nonempty_string(inventory["sourceCommit"], "inventory source commit", 64)
    if len(commit) not in {40, 64} or any(character not in "0123456789abcdef" for character in commit):
        fail("inventory source commit is not an exact lowercase Git digest")
    nonempty_string(inventory["builder"], "inventory builder")
    sha256_value(inventory["recipeDigest"], "inventory recipe digest")

    core = exact_keys(
        inventory["core"],
        {"application", "artifact", "installedBytes", "helpers"},
        set(),
        "core binding",
    )
    artifact = exact_keys(
        core["artifact"],
        {
            "bytes",
            "sha256",
            "format",
            "embeddedApplicationPath",
            "embeddedApplicationGraphSHA256",
        },
        set(),
        "core artifact",
    )
    positive_integer_value(artifact["bytes"], "core artifact bytes")
    sha256_value(artifact["sha256"], "core artifact digest")
    if artifact["format"] != "apple-disk-image":
        fail("core artifact format is unsupported")
    if artifact["embeddedApplicationPath"] != "Dory.app":
        fail("core artifact embedded application path is invalid")
    sha256_value(
        artifact["embeddedApplicationGraphSHA256"],
        "core artifact embedded application graph digest",
    )
    application = exact_keys(
        core["application"],
        {"entryCount", "regularFileBytes", "graphSHA256", "signedBundle"},
        set(),
        "core application binding",
    )
    positive_integer_value(application["entryCount"], "core application entry count")
    positive_integer_value(
        application["regularFileBytes"], "core application regular-file bytes"
    )
    sha256_value(application["graphSHA256"], "core application graph digest")
    if artifact["embeddedApplicationGraphSHA256"] != application["graphSHA256"]:
        fail("core disk image does not bind the declared application graph")
    validate_outer_application_signed_bundle(
        application["signedBundle"], release_version=version
    )
    positive_integer_value(core["installedBytes"], "core installed bytes")
    if core["installedBytes"] != application["regularFileBytes"]:
        fail("core installed bytes do not match the application graph")
    helpers = core["helpers"]
    if not isinstance(helpers, list) or len(helpers) != 2:
        fail("core helper binding must contain dory-hv and dory-vmm")
    helper_ids = []
    for index, value in enumerate(helpers):
        helper = exact_keys(
            value,
            {
                "componentIdentifier", "path", "bytes", "sha256", "executable",
                "signedBundle",
            },
            set(),
            f"core helper {index}",
        )
        identifier = nonempty_string(
            helper["componentIdentifier"], f"core helper {index} identifier"
        )
        helper_ids.append(identifier)
        expected_path = {
            "dory-hv": "Contents/Helpers/DoryHVRunner.app/Contents/MacOS/dory-hv",
            "dory-vmm": "Contents/Helpers/DoryVMM.app/Contents/MacOS/dory-vmm",
        }.get(identifier)
        if expected_path is None or helper["path"] != expected_path:
            fail(f"core helper {index} path does not bind its identifier")
        positive_integer_value(helper["bytes"], f"core helper {index} bytes")
        sha256_value(helper["sha256"], f"core helper {index} digest")
        if boolean_value(helper["executable"], f"core helper {index} executable") is not True:
            fail(f"core helper {index} is not executable")
        validate_core_signed_bundle(helper, identifier)
    if helper_ids != ["dory-hv", "dory-vmm"]:
        fail("core helper bindings must be uniquely sorted")

    components = inventory["components"]
    if not isinstance(components, list) or not components:
        fail("component candidate inventory must contain components")
    component_ids = []
    stored_assets: dict[tuple[str, str], dict] = {}
    stored_names: dict[str, dict] = {}
    for index, value in enumerate(components):
        label = f"inventory component {index}"
        component = exact_keys(
            value,
            {
                "id", "version", "displayName", "summary", "dependencies",
                "downloadBytes", "installedBytes", "assets", "architectures",
                "hostRequirements", "provides", "requires",
            },
            set(),
            label,
        )
        identifier = nonempty_string(component["id"], f"{label} identifier")
        component_ids.append(identifier)
        if component["version"] != version:
            fail(f"{label} version does not match the inventory")
        nonempty_string(component["displayName"], f"{label} display name")
        nonempty_string(component["summary"], f"{label} summary", 2048)
        validate_string_array(component["dependencies"], f"{label} dependencies")
        positive_integer_value(component["downloadBytes"], f"{label} download bytes")
        positive_integer_value(component["installedBytes"], f"{label} installed bytes")
        if component["architectures"] != [ARCHITECTURE]:
            fail(f"{label} architecture is unsupported")
        host = exact_keys(
            component["hostRequirements"], {"platform", "minimumVersion"}, set(), f"{label} host"
        )
        if host != {"platform": "macos", "minimumVersion": "14.0"}:
            fail(f"{label} host requirements are unsupported")
        provides = validate_string_array(component["provides"], f"{label} provides")
        if any(
            "virgl" in item.lower() or "venus" in item.lower()
            for item in provides
        ):
            fail(f"{label} contains an unqualified GPU capability")
        validate_string_array(component["requires"], f"{label} requires")
        assets = component["assets"]
        if not isinstance(assets, list):
            fail(f"{label} assets must be an array")
        for asset_index, raw_asset in enumerate(assets):
            asset, name = validate_inventory_asset(
                raw_asset,
                label=f"{label} asset {asset_index}",
                asset_base_url=asset_base_url,
            )
            expected_prefix = f"Dory-{version}-component-{identifier}-{ARCHITECTURE}-"
            if not name.startswith(expected_prefix) or len(name) == len(expected_prefix):
                fail(f"{label} asset filename does not bind release, component, and architecture")
            key = (identifier, asset["path"])
            if key in stored_assets or name in stored_names:
                fail(f"{label} contains a duplicate stored asset")
            stored_assets[key] = asset
            stored_names[name] = asset
        if identifier == "docker-core":
            if assets or component["downloadBytes"] != artifact["bytes"] or component["installedBytes"] != core["installedBytes"]:
                fail("Docker Core component does not match its core binding")
        elif (
            component["downloadBytes"] != sum(item["downloadBytes"] for item in assets)
            or component["installedBytes"] != sum(item["installedBytes"] for item in assets)
        ):
            fail(f"{label} aggregate sizes do not match its assets")
    if component_ids[0] != "docker-core" or len(component_ids) != len(set(component_ids)):
        fail("component identifiers must be unique with Docker Core first")

    files = inventory["files"]
    if not isinstance(files, list):
        fail("inventory files must be an array")
    file_names = []
    for index, value in enumerate(files):
        record = exact_keys(value, {"name", "bytes", "sha256"}, set(), f"inventory file {index}")
        name = safe_release_value(record["name"], f"inventory file {index} name")
        file_names.append(name)
        positive_integer_value(record["bytes"], f"inventory file {index} bytes")
        sha256_value(record["sha256"], f"inventory file {index} digest")
        asset = stored_names.get(name)
        if asset is None or record["bytes"] != asset["downloadBytes"] or record["sha256"] != asset["sha256"]:
            fail(f"inventory file {index} does not match a component asset")
    if file_names != sorted(file_names) or len(file_names) != len(set(file_names)):
        fail("inventory files must be uniquely sorted")
    if set(file_names) != set(stored_names):
        fail("inventory files do not cover the exact stored asset set")

    media = inventory["mediaBindings"]
    if not isinstance(media, list) or not media:
        fail("candidate inventory must bind packaged boot media")
    media_keys = []
    for index, value in enumerate(media):
        binding = exact_keys(
            value,
            {
                "componentIdentifier", "assetPath", "bootMediaKind", "delivery",
                "immutableArtifactSHA256", "storedSHA256",
            },
            set(),
            f"media binding {index}",
        )
        key = (
            nonempty_string(binding["componentIdentifier"], f"media binding {index} component"),
            safe_release_value(binding["assetPath"], f"media binding {index} path"),
        )
        media_keys.append(key)
        if binding["bootMediaKind"] not in {"linux-kernel", "virtual-disk"}:
            fail(f"media binding {index} has unsupported boot media kind")
        if binding["delivery"] not in {"none", "lzfse-expanded", "lzfse-stored"}:
            fail(f"media binding {index} has unsupported delivery")
        sha256_value(binding["immutableArtifactSHA256"], f"media binding {index} artifact")
        sha256_value(binding["storedSHA256"], f"media binding {index} stored digest")
        asset = stored_assets.get(key)
        if asset is None or binding["storedSHA256"] != asset["sha256"]:
            fail(f"media binding {index} does not match a stored component asset")
        expected_compression = "lzfse" if binding["delivery"] == "lzfse-expanded" else "none"
        if asset["compression"] != expected_compression:
            fail(f"media binding {index} delivery does not match catalog metadata")
    if media_keys != sorted(media_keys) or len(media_keys) != len(set(media_keys)):
        fail("media bindings must be uniquely sorted")
    return inventory


def load_candidate_inventory(output: pathlib.Path) -> tuple[dict, str]:
    path = regular_file(output / INVENTORY_PATH, "component candidate inventory")
    raw = path.read_bytes()
    value = load_json_file(path, "component candidate inventory", 8 * 1024 * 1024)
    inventory = validate_candidate_inventory(value)
    if raw != canonical_json_bytes(inventory):
        fail("component candidate inventory is not canonical JSON")
    digest = hashlib.sha256(raw).hexdigest()
    digest_file = regular_file(output / INVENTORY_DIGEST_PATH, "candidate inventory digest")
    try:
        digest_text = digest_file.read_text(encoding="ascii")
    except (OSError, UnicodeError) as error:
        fail(f"candidate inventory digest is unreadable: {error}")
    if digest_text != digest + "\n":
        fail("candidate inventory digest does not match the inventory")
    return inventory, digest


def require_release_core_signatures(inventory: dict) -> None:
    identities = [inventory["core"]["application"]["signedBundle"]]
    for helper in inventory["core"]["helpers"]:
        signed_bundle = helper["signedBundle"]
        identities.extend([signed_bundle] + signed_bundle["nestedBundles"])
    for identity in identities:
        if (
            identity["signatureKind"] != "developer-id-application"
            or identity["teamIdentifier"] != SIGNING_TEAM_IDENTIFIER
            or identity["hardenedRuntime"] is not True
        ):
            fail("staged finalization requires Developer ID core signature evidence")


def require_matching_core_inputs(
    inventory: dict,
    *,
    core_artifact: pathlib.Path,
    core_app: pathlib.Path,
    allow_test_signatures: bool,
    phase: str,
) -> None:
    actual = core_binding(
        core_artifact,
        core_app,
        release_version=inventory["releaseVersion"],
        allow_test_signatures=allow_test_signatures,
    )
    if actual != inventory["core"]:
        fail(f"core signature evidence differs from the exact {phase} inputs")


def validate_candidate_directory(output: pathlib.Path, inventory: dict, *, exact: bool) -> None:
    expected = {item["name"] for item in inventory["files"]} | {
        INVENTORY_PATH,
        INVENTORY_DIGEST_PATH,
    }
    actual = set()
    for entry in output.iterdir():
        info = entry.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_size <= 0:
            fail(f"candidate output contains an indirect or empty entry: {entry.name}")
        actual.add(entry.name)
    if exact and actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        fail(f"candidate output file set changed (missing={missing}, extra={extra})")
    if not expected <= actual:
        fail("candidate output is missing inventory-bound files")
    for record in inventory["files"]:
        path = regular_file(output / record["name"], "inventory-bound asset")
        if path.stat().st_size != record["bytes"] or sha256(path) != record["sha256"]:
            fail(f"inventory-bound asset changed: {record['name']}")


def stat_identity(info: os.stat_result) -> tuple[int, int, int, int, int, int]:
    return (
        info.st_dev,
        info.st_ino,
        info.st_mode,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def snapshot_candidate_directory(candidate: pathlib.Path, inventory: dict) -> dict:
    validate_candidate_directory(candidate, inventory, exact=True)
    expected = sorted(
        {item["name"] for item in inventory["files"]}
        | {INVENTORY_PATH, INVENTORY_DIGEST_PATH}
    )
    files = {}
    for name in expected:
        path = regular_file(candidate / name, "candidate snapshot file")
        files[name] = {
            "identity": stat_identity(path.lstat()),
            "sha256": sha256(path),
        }
    return {
        "directoryIdentity": stat_identity(candidate.lstat()),
        "files": files,
    }


def verify_candidate_snapshot(
    candidate: pathlib.Path, inventory: dict, snapshot: dict
) -> None:
    validate_candidate_directory(candidate, inventory, exact=True)
    if stat_identity(candidate.lstat()) != snapshot["directoryIdentity"]:
        fail("candidate directory changed during finalization")
    for name, expected in snapshot["files"].items():
        path = regular_file(candidate / name, "candidate snapshot file")
        if (
            stat_identity(path.lstat()) != expected["identity"]
            or sha256(path) != expected["sha256"]
        ):
            fail(f"candidate file changed during finalization: {name}")


def copy_candidate_file(
    source: pathlib.Path, destination: pathlib.Path, expected: dict
) -> None:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(source, flags)
    except OSError as error:
        fail(f"candidate file could not be opened directly: {source.name}: {error}")
    digest = hashlib.sha256()
    copied = 0
    try:
        with os.fdopen(descriptor, "rb", closefd=True) as source_handle:
            before = os.fstat(source_handle.fileno())
            if stat_identity(before) != expected["identity"]:
                fail(f"candidate file changed before copy: {source.name}")
            with destination.open("xb") as destination_handle:
                while chunk := source_handle.read(1024 * 1024):
                    destination_handle.write(chunk)
                    digest.update(chunk)
                    copied += len(chunk)
                destination_handle.flush()
                os.fsync(destination_handle.fileno())
            after = os.fstat(source_handle.fileno())
            if stat_identity(after) != expected["identity"]:
                fail(f"candidate file changed while copied: {source.name}")
    except BaseException:
        destination.unlink(missing_ok=True)
        raise
    if copied != expected["identity"][3] or digest.hexdigest() != expected["sha256"]:
        destination.unlink(missing_ok=True)
        fail(f"candidate file copy does not match its snapshot: {source.name}")
    os.chmod(destination, 0o644)


def asset_lookup(inventory: dict) -> dict[tuple[str, str], dict]:
    return {
        (component["id"], asset["path"]): asset
        for component in inventory["components"]
        for asset in component["assets"]
    }


def decode_asset(path: pathlib.Path, compression_tool: pathlib.Path) -> tuple[str, int]:
    handle, temporary = tempfile.mkstemp(prefix="dory-component-decode-")
    os.close(handle)
    destination = pathlib.Path(temporary)
    try:
        run(
            [
                str(compression_tool), "-decode", "-a", "lzfse",
                "-i", str(path), "-o", str(destination),
            ]
        )
        return sha256(destination), byte_size(destination)
    finally:
        destination.unlink(missing_ok=True)


def validate_installed_and_media_bindings(
    output: pathlib.Path, inventory: dict, compression_tool: pathlib.Path
) -> None:
    assets = asset_lookup(inventory)
    filenames = {
        key: artifact_name_from_url(asset["url"], inventory["assetBaseURL"])
        for key, asset in assets.items()
    }
    decoded: dict[tuple[str, str], tuple[str, int]] = {}
    for key, asset in assets.items():
        if asset["compression"] == "lzfse":
            decoded[key] = decode_asset(output / filenames[key], compression_tool)
            if decoded[key] != (asset["installedSHA256"], asset["installedBytes"]):
                fail(f"installed asset digest does not match the candidate: {key[0]}/{key[1]}")
        elif asset["sha256"] != asset["installedSHA256"] or asset["downloadBytes"] != asset["installedBytes"]:
            fail(f"uncompressed installed binding is inconsistent: {key[0]}/{key[1]}")

    for binding in inventory["mediaBindings"]:
        key = (binding["componentIdentifier"], binding["assetPath"])
        path = output / filenames[key]
        if binding["delivery"] in {"lzfse-expanded", "lzfse-stored"}:
            raw_digest, _ = decoded.get(key) or decode_asset(path, compression_tool)
        else:
            raw_digest = sha256(path)
        if raw_digest != binding["immutableArtifactSHA256"]:
            fail(f"packaged boot media does not match its immutable source binding: {key[0]}/{key[1]}")


def validate_qualification_candidate_binding(
    manifest: dict,
    *,
    inventory_digest: str,
    sbom_digest: str,
    required: bool,
) -> None:
    binding = manifest.get("candidateBinding")
    if binding is None:
        if required:
            fail("VM qualification manifest does not bind the candidate inventory and SBOM")
        return
    if binding["componentCandidateInventorySHA256"] != inventory_digest:
        fail("VM qualification manifest binds another component candidate inventory")
    if binding["sbomSHA256"] != sbom_digest:
        fail("VM qualification manifest binds another SBOM")


def verify_ed25519_signature(
    repo: pathlib.Path,
    message: pathlib.Path,
    signature: pathlib.Path,
    public_key_base64: str,
    label: str,
) -> None:
    signature = regular_file(signature, f"{label} signature")
    try:
        signature_text = signature.read_text(encoding="ascii")
        decoded = base64.b64decode(signature_text.strip(), validate=True)
    except (OSError, UnicodeError, ValueError, binascii.Error):
        fail(f"{label} signature is malformed")
    if signature_text != signature_text.strip() + "\n" or len(decoded) != 64:
        fail(f"{label} signature must be one canonical Ed25519 signature line")
    verifier = regular_file(
        repo / ".github/scripts/verify-ed25519-signature.swift",
        f"{label} signature verifier",
    )
    run(
        [
            "xcrun", "swift", str(verifier), public_key_base64,
            str(signature), str(message),
        ]
    )


def catalog_public_key_bytes(value: str, label: str) -> bytes:
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error):
        fail(f"{label} is not valid base64")
    if len(decoded) != 32:
        fail(f"{label} is not an Ed25519 public key")
    return decoded


def validate_qualification_bindings(manifest: dict, inventory: dict) -> None:
    runtime_contracts = {
        "dory-hypervisor": ("dory.raw-hv-linux.compatibility.v1", "dory-hv"),
        "apple-virtualization-framework": ("dory.vz-linux.compatibility.v1", "dory-vmm"),
    }
    helpers = {
        item["componentIdentifier"]: item for item in inventory["core"]["helpers"]
    }
    bundled_media: dict[str, set[str]] = {}
    for binding in inventory["mediaBindings"]:
        bundled_media.setdefault(binding["bootMediaKind"], set()).add(
            binding["immutableArtifactSHA256"]
        )

    for index, record in enumerate(manifest["records"]):
        label = f"qualification record {index}"
        if record["guest"] != {"family": "linux", "architecture": ARCHITECTURE}:
            fail(f"{label} is not Linux arm64 qualification for this catalog")
        contract = runtime_contracts.get(record["backend"])
        if contract is None:
            fail(f"{label} backend is not shipped by the Apple Silicon candidate")
        implementation, helper_id = contract
        helper = helpers.get(helper_id)
        if helper is None:
            fail(f"{label} runtime helper is absent from the candidate inventory")
        runtime_digest = helper["sha256"]
        expected_build = f"sha256:{runtime_digest}"
        if record["backendImplementationIdentifier"] != implementation:
            fail(f"{label} implementation does not match the candidate adapter")
        if record["backendRuntimeBuildIdentifier"] != expected_build:
            fail(f"{label} runtime build does not match the candidate helper")
        if record["components"] != [
            {
                "componentIdentifier": helper_id,
                "buildIdentifier": expected_build,
                "artifactSHA256": runtime_digest,
            }
        ]:
            fail(f"{label} component evidence does not match the candidate helper")
        if record["bootMediaSource"] == "dory-bundled":
            accepted = bundled_media.get(record["bootMediaKind"])
            if accepted is None or record.get("immutableArtifactSHA256") not in accepted:
                fail(f"{label} bundled media digest is not inventory-bound boot media")
        elif record["bootMediaSource"] in {"vendor-download", "user-provided"}:
            if record["bootMediaKind"] not in {"installer-iso", "virtual-disk"} \
                    or record.get("immutableArtifactSHA256") is None:
                fail(f"{label} external media is not one exact immutable EFI input")
        else:
            fail(f"{label} media source is unsupported")


def validate_performance_receipt_bindings(
    manifest: dict,
    receipts: list[tuple[pathlib.Path, pathlib.Path, dict]],
    *,
    application_digest: str,
    inventory_digest: str,
    sbom_digest: str,
) -> list[tuple[pathlib.Path, pathlib.Path, dict]]:
    records_by_path: dict[str, dict] = {}
    for index, record in enumerate(manifest["records"]):
        path = record["performanceQualification"]["verificationReceiptPath"]
        if path in records_by_path:
            fail("VM qualification records repeat a performance verification receipt")
        records_by_path[path] = record

    receipts_by_path: dict[str, tuple[pathlib.Path, pathlib.Path, dict]] = {}
    for receipt_path, signature_path, receipt in receipts:
        name = receipt_path.name
        if name in receipts_by_path:
            fail("performance verification receipt inputs repeat a file name")
        receipts_by_path[name] = (receipt_path, signature_path, receipt)
    if set(records_by_path) != set(receipts_by_path):
        fail("VM qualification records and verified performance receipts are not one-to-one")

    backend_names = {
        "dory-hypervisor": "rawhv",
        "apple-virtualization-framework": "vz",
    }
    graphics_quality = {
        "none": "software",
        "software": "software",
        "host-accelerated-display": "software",
        "hardware-accelerated-3d": "accelerated",
    }
    ordered: list[tuple[pathlib.Path, pathlib.Path, dict]] = []
    for path in sorted(records_by_path):
        record = records_by_path[path]
        receipt_path, signature_path, receipt = receipts_by_path[path]
        performance = record["performanceQualification"]
        candidate = receipt["candidate"]
        support = receipt["supportCell"]
        if sha256(receipt_path) != performance["verificationReceiptSHA256"]:
            fail(f"performance verification receipt digest differs for {path}")
        if receipt["bundleInventorySHA256"] != performance["bundleInventorySHA256"]:
            fail(f"performance bundle inventory differs for {path}")
        if receipt["signaturePublicKeyID"] != performance["signaturePublicKeyID"]:
            fail(f"performance trust root differs for {path}")
        if support["matrixCellID"] != performance["matrixCellID"]:
            fail(f"performance matrix cell differs for {path}")
        if support["graphicsImplementation"] != performance["graphicsImplementation"]:
            fail(f"performance graphics implementation differs for {path}")
        if candidate["applicationSHA256"] != application_digest:
            fail(f"performance receipt binds another Dory application for {path}")
        if candidate["componentCandidateInventorySHA256"] != inventory_digest:
            fail(f"performance receipt binds another component candidate for {path}")
        if candidate["sbomSHA256"] != sbom_digest:
            fail(f"performance receipt binds another SBOM for {path}")
        if candidate["virtualHardwareABIVersion"] \
                != str(record["virtualHardwareABIVersion"]):
            fail(f"performance receipt binds another virtual hardware ABI for {path}")
        if support["installerSHA256"] != record.get("immutableArtifactSHA256"):
            fail(f"performance receipt binds another boot artifact for {path}")
        if support["backend"] != backend_names.get(record["backend"]):
            fail(f"performance receipt binds another backend for {path}")
        expected_quality = graphics_quality.get(record["graphics"])
        if support["requestedGraphicsQuality"] != expected_quality \
                or support["selectedGraphicsQuality"] != expected_quality:
            fail(f"performance receipt binds another graphics quality for {path}")
        if expected_quality == "software" \
                and support["graphicsImplementation"] != "software":
            fail(f"software qualification uses a non-software implementation for {path}")
        if expected_quality == "accelerated" \
                and support["graphicsImplementation"] == "software":
            fail(f"accelerated qualification uses a software implementation for {path}")
        ordered.append((receipt_path, signature_path, receipt))
    return ordered


def sign_catalog(catalog_path: pathlib.Path, signer: pathlib.Path) -> str:
    regular_file(signer, "Sparkle sign_update")
    signature = run([str(signer), "-p", str(catalog_path)]).strip()
    try:
        decoded = base64.b64decode(signature, validate=True)
    except (ValueError, binascii.Error):
        fail("Sparkle sign_update returned a malformed signature")
    if len(decoded) != 64:
        fail("Sparkle sign_update returned an unexpected Ed25519 signature length")
    run([str(signer), "--verify", str(catalog_path), signature])
    return signature


def remove_private_build_directory(path: pathlib.Path, parent: pathlib.Path) -> None:
    """Delete only a hidden direct child of the declared build-output parent."""
    resolved = path.resolve()
    resolved_parent = parent.resolve()
    forbidden = {
        pathlib.Path("/"),
        pathlib.Path.home().resolve(),
        pathlib.Path.cwd().resolve(),
    }
    if (
        resolved in forbidden
        or resolved.parent != resolved_parent
        or not resolved.name.startswith(".")
        or path.is_symlink()
        or not path.is_dir()
    ):
        fail(f"refusing unsafe component build cleanup: {path}")
    shutil.rmtree(resolved)


def publish(staging: pathlib.Path, output: pathlib.Path) -> None:
    backup = output.parent / f".{output.name}.previous-{uuid.uuid4().hex}"
    if output.exists() or output.is_symlink():
        if output.is_symlink() or not output.is_dir():
            fail(f"refusing to replace non-directory output: {output}")
        output.rename(backup)
    try:
        staging.rename(output)
    except BaseException:
        if backup.exists() and not output.exists():
            backup.rename(output)
        raise
    if backup.exists():
        remove_private_build_directory(backup, output.parent)


def qualification_evidence_asset(
    *,
    version: str,
    source: pathlib.Path,
    installed_path: str,
    staging: pathlib.Path,
    asset_base_url: str,
    compression_tool: pathlib.Path,
) -> dict:
    return materialize_asset(
        version=version,
        component_id=QUALIFICATION_COMPONENT,
        asset={
            "path": installed_path,
            "source": source,
            "delivery": "none",
            "executable": False,
            "role": "qualification-evidence",
        },
        output=staging,
        asset_base_url=asset_base_url,
        compression_tool=compression_tool,
        allow_test_code_requirement=False,
    )


def resolved_core_inputs(args: argparse.Namespace) -> tuple[pathlib.Path, pathlib.Path]:
    artifact_argument = absolute_without_resolving(args.core_artifact)
    core_artifact = regular_file(
        artifact_argument, "exact core release artifact input"
    ).resolve()
    app_argument = absolute_without_resolving(args.core_app)
    core_app = directory(app_argument, "exact core application input").resolve()
    return core_artifact, core_app


def finalize_catalog(
    args: argparse.Namespace,
    repo: pathlib.Path,
    *,
    require_signature: bool,
    require_binding: bool,
    require_catalog_signature: bool,
) -> None:
    candidate_argument = absolute_without_resolving(args.candidate)
    candidate = directory(candidate_argument, "component candidate input").resolve()

    output_argument = absolute_without_resolving(args.output)
    if output_argument.is_symlink():
        fail("final component output cannot be a symbolic link")
    output_argument.parent.mkdir(parents=True, exist_ok=True)
    output_parent = directory(
        output_argument.parent, "final component output parent"
    ).resolve()
    output = output_parent / output_argument.name
    if output in {
        pathlib.Path("/"),
        pathlib.Path.home().resolve(),
        pathlib.Path.cwd().resolve(),
    }:
        fail(f"refusing unsafe final component output: {output}")
    if (
        candidate == output
        or candidate in output.parents
        or output in candidate.parents
    ):
        fail("final component output must be separate from the candidate directory")
    inventory, inventory_digest = load_candidate_inventory(candidate)
    allow_test_signatures = getattr(args, "allow_test_signatures", False)
    catalog_key = catalog_public_key_bytes(
        args.catalog_public_key, "catalog public key"
    )
    production_catalog_key = catalog_public_key_bytes(
        DEFAULT_CATALOG_PUBLIC_KEY, "production catalog public key"
    )
    if allow_test_signatures and catalog_key == production_catalog_key:
        fail(
            "test-signature finalization requires a non-production catalog trust root"
        )
    if require_catalog_signature and not allow_test_signatures:
        require_release_core_signatures(inventory)
    core_artifact, core_app = resolved_core_inputs(args)
    require_matching_core_inputs(
        inventory,
        core_artifact=core_artifact,
        core_app=core_app,
        allow_test_signatures=allow_test_signatures,
        phase="pre-finalization core",
    )
    validate_candidate_directory(candidate, inventory, exact=True)
    compression_tool = regular_file(
        pathlib.Path("/usr/bin/compression_tool"), "macOS compression_tool"
    )
    validate_installed_and_media_bindings(candidate, inventory, compression_tool)

    sbom = regular_file(args.sbom.resolve(), "component SBOM")
    sbom_digest = sha256(sbom)
    qualification_path = regular_file(
        args.qualification_manifest.resolve(), "VM qualification manifest"
    )
    qualification_digest = sha256(qualification_path)
    qualification_signature = (
        regular_file(args.qualification_signature.resolve(), "VM qualification signature")
        if args.qualification_signature is not None
        else None
    )
    qualification_signature_digest = (
        sha256(qualification_signature) if qualification_signature is not None else None
    )
    if require_signature and qualification_signature is None:
        fail("finalization requires a detached VM qualification signature")
    if qualification_signature is not None:
        verify_ed25519_signature(
            repo,
            qualification_path,
            qualification_signature,
            args.catalog_public_key,
            "VM qualification",
        )
        if (
            sha256(qualification_path) != qualification_digest
            or sha256(qualification_signature) != qualification_signature_digest
        ):
            fail("VM qualification evidence changed during signature verification")
    manifest = load_qualification_manifest(
        qualification_path,
        release_version=inventory["releaseVersion"],
        public_key_base64=args.catalog_public_key,
    )
    validate_qualification_candidate_binding(
        manifest,
        inventory_digest=inventory_digest,
        sbom_digest=sbom_digest,
        required=require_binding,
    )
    validate_qualification_bindings(manifest, inventory)
    receipt_arguments = args.performance_verification_receipt
    receipt_signature_arguments = args.performance_verification_signature
    if len(receipt_arguments) != len(receipt_signature_arguments):
        fail("performance verification receipt and signature counts differ")
    performance_receipts: list[tuple[pathlib.Path, pathlib.Path, dict]] = []
    performance_input_digests: dict[pathlib.Path, str] = {}
    for receipt_argument, signature_argument in zip(
        receipt_arguments,
        receipt_signature_arguments,
        strict=True,
    ):
        receipt_path = regular_file(
            receipt_argument.resolve(),
            "Linux VM performance verification receipt",
        )
        signature_path = regular_file(
            signature_argument.resolve(),
            "Linux VM performance verification receipt signature",
        )
        if signature_path.name != receipt_path.name + ".sig":
            fail("performance verification signature name does not bind its receipt")
        verify_ed25519_signature(
            repo,
            receipt_path,
            signature_path,
            args.catalog_public_key,
            "Linux VM performance verification receipt",
        )
        receipt = load_performance_verification_receipt(
            receipt_path,
            public_key_base64=args.catalog_public_key,
        )
        performance_receipts.append((receipt_path, signature_path, receipt))
        performance_input_digests[receipt_path] = sha256(receipt_path)
        performance_input_digests[signature_path] = sha256(signature_path)
    performance_receipts = validate_performance_receipt_bindings(
        manifest,
        performance_receipts,
        application_digest=inventory["core"]["application"]["graphSHA256"],
        inventory_digest=inventory_digest,
        sbom_digest=sbom_digest,
    )
    if sha256(qualification_path) != qualification_digest:
        fail("VM qualification manifest changed during validation")
    candidate_snapshot = snapshot_candidate_directory(candidate, inventory)

    signer = args.signer.resolve() if args.signer is not None else None
    if require_catalog_signature and signer is None:
        fail("finalization requires a catalog signer")
    staging: pathlib.Path | None = pathlib.Path(
        tempfile.mkdtemp(prefix=f".{output.name}.finalize-", dir=output.parent)
    )
    try:
        candidate_names = [item["name"] for item in inventory["files"]] + [
            INVENTORY_PATH,
            INVENTORY_DIGEST_PATH,
        ]
        for name in candidate_names:
            copy_candidate_file(
                candidate / name,
                staging / name,
                candidate_snapshot["files"][name],
            )

        evidence_assets = [
            qualification_evidence_asset(
                version=inventory["releaseVersion"],
                source=qualification_path,
                installed_path=QUALIFICATION_PATH,
                staging=staging,
                asset_base_url=inventory["assetBaseURL"],
                compression_tool=compression_tool,
            )
        ]
        if qualification_signature is not None:
            evidence_assets.append(
                qualification_evidence_asset(
                    version=inventory["releaseVersion"],
                    source=qualification_signature,
                    installed_path=QUALIFICATION_SIGNATURE_PATH,
                    staging=staging,
                    asset_base_url=inventory["assetBaseURL"],
                    compression_tool=compression_tool,
                )
            )
        for receipt_path, signature_path, _ in performance_receipts:
            evidence_assets.append(
                qualification_evidence_asset(
                    version=inventory["releaseVersion"],
                    source=receipt_path,
                    installed_path=receipt_path.name,
                    staging=staging,
                    asset_base_url=inventory["assetBaseURL"],
                    compression_tool=compression_tool,
                )
            )
            evidence_assets.append(
                qualification_evidence_asset(
                    version=inventory["releaseVersion"],
                    source=signature_path,
                    installed_path=signature_path.name,
                    staging=staging,
                    asset_base_url=inventory["assetBaseURL"],
                    compression_tool=compression_tool,
                )
            )
        if evidence_assets[0]["sha256"] != qualification_digest:
            fail("VM qualification manifest changed while finalization copied it")
        if (
            qualification_signature_digest is not None
            and evidence_assets[1]["sha256"] != qualification_signature_digest
        ):
            fail("VM qualification signature changed while finalization copied it")
        for path, expected_digest in performance_input_digests.items():
            if sha256(path) != expected_digest:
                fail("performance verification input changed while finalization copied it")

        provenance = {
            "sourceCommit": inventory["sourceCommit"],
            "builder": inventory["builder"],
            "recipeDigest": inventory["recipeDigest"],
            "sbomDigest": sbom_digest,
            "attestationDigest": qualification_digest,
        }
        qualification_ids = [
            record["qualificationIdentity"] for record in manifest["records"]
        ]
        components = copy.deepcopy(inventory["components"])
        for component in components:
            component["provenance"] = provenance
            component["qualification"] = (
                qualification_ids if component["id"] == QUALIFICATION_COMPONENT else []
            )
            if component["id"] == QUALIFICATION_COMPONENT:
                component["assets"].extend(evidence_assets)
                component["downloadBytes"] = sum(
                    asset["downloadBytes"] for asset in component["assets"]
                )
                component["installedBytes"] = sum(
                    asset["installedBytes"] for asset in component["assets"]
                )

        catalog = {
            "kind": TEST_CATALOG_KIND if allow_test_signatures else CATALOG_KIND,
            "schemaVersion": CATALOG_SCHEMA,
            "releaseVersion": inventory["releaseVersion"],
            "generatedAt": inventory["generatedAt"],
            "minimumAppVersion": inventory["minimumAppVersion"],
            "architecture": inventory["architecture"],
            "components": components,
            "virtualMachineQualification": {
                "component": QUALIFICATION_COMPONENT,
                "path": QUALIFICATION_PATH,
                "manifestIdentity": manifest["manifestIdentity"],
                "manifestFormatVersion": manifest["schemaVersion"],
                "signingKeyID": manifest["signingKeyID"],
            },
        }
        catalog_path = staging / "catalog.json"
        write_bytes(catalog_path, canonical_json_bytes(catalog))
        # The public signer must only authenticate evidence re-derived from the same immutable app
        # and release artifact. Recompute immediately before invoking it to close the candidate /
        # qualification work-window TOCTOU boundary.
        require_matching_core_inputs(
            inventory,
            core_artifact=core_artifact,
            core_app=core_app,
            allow_test_signatures=allow_test_signatures,
            phase="pre-signing core",
        )
        if signer is not None:
            catalog_signature_path = staging / "catalog.json.sig"
            write_text(catalog_signature_path, sign_catalog(catalog_path, signer) + "\n")
            verify_ed25519_signature(
                repo,
                catalog_path,
                catalog_signature_path,
                args.catalog_public_key,
                "component catalog",
            )
            require_matching_core_inputs(
                inventory,
                core_artifact=core_artifact,
                core_app=core_app,
                allow_test_signatures=allow_test_signatures,
                phase="post-signing core",
            )
        write_text(staging / "catalog.json.sha256", sha256(catalog_path) + "\n")

        # The independently copied candidate bytes and their immutable source are checked again
        # after all final metadata is built.
        staged_inventory, staged_inventory_digest = load_candidate_inventory(staging)
        if staged_inventory_digest != inventory_digest or staged_inventory != inventory:
            fail("candidate inventory changed during finalization")
        validate_candidate_directory(staging, inventory, exact=False)
        validate_installed_and_media_bindings(staging, inventory, compression_tool)
        verify_candidate_snapshot(candidate, inventory, candidate_snapshot)
        if sha256(sbom) != sbom_digest or sha256(qualification_path) != qualification_digest:
            fail("SBOM or VM qualification manifest changed during finalization")
        if (
            qualification_signature is not None
            and sha256(qualification_signature) != qualification_signature_digest
        ):
            fail("VM qualification signature changed during finalization")
        for path, expected_digest in performance_input_digests.items():
            if sha256(path) != expected_digest:
                fail("performance verification input changed during finalization")
        publish(staging, output)
        staging = None
    finally:
        if staging is not None and staging.exists():
            remove_private_build_directory(staging, output.parent)


def verify_candidate(args: argparse.Namespace) -> None:
    """Verify one immutable pre-publication candidate without creating support metadata."""
    candidate_argument = absolute_without_resolving(args.candidate)
    candidate = directory(candidate_argument, "component candidate input").resolve()
    inventory, inventory_digest = load_candidate_inventory(candidate)
    core_artifact, core_app = resolved_core_inputs(args)
    allow_test_signatures = getattr(args, "allow_test_signatures", False)
    require_matching_core_inputs(
        inventory,
        core_artifact=core_artifact,
        core_app=core_app,
        allow_test_signatures=allow_test_signatures,
        phase="candidate-verification core",
    )
    snapshot = snapshot_candidate_directory(candidate, inventory)
    compression_tool = regular_file(
        pathlib.Path("/usr/bin/compression_tool"), "macOS compression_tool"
    )
    validate_installed_and_media_bindings(candidate, inventory, compression_tool)
    verify_candidate_snapshot(candidate, inventory, snapshot)
    require_matching_core_inputs(
        inventory,
        core_artifact=core_artifact,
        core_app=core_app,
        allow_test_signatures=allow_test_signatures,
        phase="post-verification core",
    )
    receipt = {
        "architecture": inventory["architecture"],
        "componentCandidateInventorySHA256": inventory_digest,
        "components": [component["id"] for component in inventory["components"]],
        "fileCount": len(inventory["files"]),
        "kind": "dev.dory.component-candidate-verification",
        "releaseVersion": inventory["releaseVersion"],
        "schemaVersion": 1,
        "sourceCommit": inventory["sourceCommit"],
    }
    sys.stdout.buffer.write(canonical_json_bytes(receipt))


def add_assemble_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--version", required=True)
    parser.add_argument("--core-artifact", required=True, type=pathlib.Path)
    parser.add_argument("--core-app", required=True, type=pathlib.Path)
    parser.add_argument("--kubectl", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--asset-base-url")
    parser.add_argument("--source-root", type=pathlib.Path)
    parser.add_argument("--minimum-app-version")
    parser.add_argument("--generated-at")
    parser.add_argument("--source-commit")
    parser.add_argument("--builder-identity", default="dory.build-components.v2")
    parser.add_argument("--skip-source-verification", action="store_true")


def add_finalize_arguments(
    parser: argparse.ArgumentParser,
    *,
    staged: bool,
    include_candidate: bool = True,
    include_output: bool = True,
    include_core_inputs: bool = True,
) -> None:
    if include_candidate:
        parser.add_argument("--candidate", required=True, type=pathlib.Path)
    if include_output:
        parser.add_argument("--output", required=True, type=pathlib.Path)
    if include_core_inputs:
        parser.add_argument("--core-artifact", required=True, type=pathlib.Path)
        parser.add_argument("--core-app", required=True, type=pathlib.Path)
    parser.add_argument("--qualification-manifest", required=True, type=pathlib.Path)
    parser.add_argument(
        "--qualification-signature", required=staged, type=pathlib.Path
    )
    parser.add_argument("--sbom", required=True, type=pathlib.Path)
    parser.add_argument("--signer", required=staged, type=pathlib.Path)
    parser.add_argument("--catalog-public-key", default=DEFAULT_CATALOG_PUBLIC_KEY)
    parser.add_argument(
        "--allow-test-signatures", action="store_true", help=argparse.SUPPRESS
    )
    parser.add_argument(
        "--performance-verification-receipt",
        required=True,
        action="append",
        type=pathlib.Path,
    )
    parser.add_argument(
        "--performance-verification-signature",
        required=True,
        action="append",
        type=pathlib.Path,
    )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    arguments = list(sys.argv[1:] if argv is None else argv)
    commands = {"assemble", "verify-candidate", "finalize", "legacy"}
    if arguments and arguments[0] not in commands and arguments[0] != "--help":
        arguments.insert(0, "legacy")
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    assemble = subparsers.add_parser(
        "assemble", help="assemble immutable component assets and candidate inventory"
    )
    add_assemble_arguments(assemble)
    finalize = subparsers.add_parser(
        "finalize", help="bind signed qualification evidence and publish schema-2 metadata"
    )
    add_finalize_arguments(finalize, staged=True)
    verify = subparsers.add_parser(
        "verify-candidate",
        help="verify immutable candidate bytes without creating support metadata",
    )
    verify.add_argument("--candidate", required=True, type=pathlib.Path)
    verify.add_argument("--core-artifact", required=True, type=pathlib.Path)
    verify.add_argument("--core-app", required=True, type=pathlib.Path)
    verify.add_argument(
        "--allow-test-signatures", action="store_true", help=argparse.SUPPRESS
    )
    legacy = subparsers.add_parser(
        "legacy", help="compatibility-only combined build for existing local fixtures"
    )
    add_assemble_arguments(legacy)
    add_finalize_arguments(
        legacy,
        staged=False,
        include_candidate=False,
        include_output=False,
        include_core_inputs=False,
    )
    return parser.parse_args(arguments)


def main() -> None:
    args = parse_args()
    repo = pathlib.Path(__file__).resolve().parent.parent
    if args.command == "assemble":
        build_candidate_inventory(args, repo)
    elif args.command == "verify-candidate":
        verify_candidate(args)
    elif args.command == "finalize":
        finalize_catalog(
            args,
            repo,
            require_signature=True,
            require_binding=True,
            require_catalog_signature=True,
        )
    else:
        # Compatibility exists only for existing local fixture generators. Verified/public callers
        # must use the separate candidate and final output contract.
        if not args.skip_source_verification:
            fail("legacy component builds are restricted to local test fixtures")
        legacy_output_argument = absolute_without_resolving(args.output)
        if legacy_output_argument.is_symlink():
            fail("legacy component output cannot be a symbolic link")
        legacy_output_argument.parent.mkdir(parents=True, exist_ok=True)
        legacy_output_parent = directory(
            legacy_output_argument.parent, "legacy component output parent"
        ).resolve()
        legacy_output = legacy_output_parent / legacy_output_argument.name
        legacy_candidate = legacy_output.parent / (
            f".{legacy_output.name}.legacy-candidate-{uuid.uuid4().hex}"
        )
        assembly_args = copy.copy(args)
        assembly_args.output = legacy_candidate
        finalization_args = copy.copy(args)
        finalization_args.candidate = legacy_candidate
        finalization_args.output = legacy_output
        try:
            build_candidate_inventory(assembly_args, repo)
            finalize_catalog(
                finalization_args,
                repo,
                require_signature=False,
                require_binding=False,
                require_catalog_signature=False,
            )
            # The historical combined fixture contract did not publish candidate-inventory files.
            # Staged `finalize` retains them; remove them only from this compatibility output.
            for name in (INVENTORY_PATH, INVENTORY_DIGEST_PATH):
                regular_file(legacy_output / name, "legacy candidate inventory").unlink()
        finally:
            if legacy_candidate.exists():
                remove_private_build_directory(legacy_candidate, legacy_output.parent)


if __name__ == "__main__":
    main()
