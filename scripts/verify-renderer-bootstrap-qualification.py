#!/usr/bin/env python3
"""Verify candidate-bound renderer bootstrap evidence in an assembled runner."""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
from typing import Any


PUBLIC_KEY = "AFetajNbqZty68rRY7OMWYNt6suUsrokQmYMhDJtnP4="
KIND = "dev.dory.renderer-bootstrap-qualification"
INVENTORY_KIND = "dev.dory.renderer-artifact-inventory"
SOURCE_TUPLE = "dory-dual-metal-20260826"
SOURCE_TUPLE_WIRE = 3
DEFINITION_SHA256 = "6f537361d165cbe75b04e98ce56c6e878060119c2aca112fa88ceba936092bba"
GUEST_MESA_SHA256 = "fa12e2bef9855dd382c3cd7f1dcd434f65302fc13471ae06367179f1ad37124c"
PRODUCTION_FEATURE_BITS = (1 << 11) - 1
MAX_VALIDITY_SECONDS = 548 * 24 * 60 * 60
RUNNER_REQUIREMENT = (
    'anchor apple generic and identifier "com.pythonxi.Dory.HVRunner" '
    'and certificate leaf[subject.OU] = "864H636QW4"'
)
WORKER_REQUIREMENT = (
    'anchor apple generic and identifier '
    '"com.pythonxi.Dory.HVRunner.RendererWorker" '
    'and certificate leaf[subject.OU] = "864H636QW4"'
)
EXPECTED_FILES = {
    "angleMetal": [
        "XPCServices/DoryRendererWorker.xpc/Contents/Frameworks/libEGL.dylib",
        "XPCServices/DoryRendererWorker.xpc/Contents/Frameworks/libGLESv2.dylib",
    ],
    "rendererWorker": [
        "XPCServices/DoryRendererWorker.xpc/Contents/MacOS/DoryRendererWorker",
    ],
}
INVENTORY_KEYS = {
    "architecture",
    "buildPolicy",
    "components",
    "dependencyBuildPolicy",
    "dependencySources",
    "definitionSha256",
    "guestMesaBuildPolicy",
    "kind",
    "platform",
    "producerFence",
    "profile",
    "schemaVersion",
    "sourceTuple",
    "sources",
    "toolchain",
}
RECEIPT_KEYS = {
    "bootstrapProtocolVersion",
    "bootstrapTranscriptSHA256",
    "capabilityReceiptProtocolVersion",
    "capabilityReceiptSHA256",
    "candidateInventorySHA256",
    "capsets",
    "expiresAt",
    "featureBits",
    "guestMesaSHA256",
    "issuedAt",
    "kind",
    "managedGuestKernelSHA256",
    "producerFenceContract",
    "qualificationIdentity",
    "revocationKeyID",
    "revocationSequence",
    "schemaVersion",
    "signingKeyID",
    "sourceTuple",
    "tupleDefinitionSHA256",
    "workerCodeDirectoryHash",
    "workerExecutableSHA256",
}
SHA256_RE = re.compile(r"[0-9a-f]{64}")
CDHASH_RE = re.compile(r"[0-9a-f]{40}")
TIMESTAMP_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")


class VerificationError(Exception):
    pass


def fail(message: str) -> None:
    raise VerificationError(message)


def canonical_json(value: Any) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8") + b"\n"


def regular_file(path: pathlib.Path, maximum: int) -> bytes:
    try:
        before = path.lstat()
    except OSError as error:
        fail(f"cannot inspect {path}: {error}")
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        fail(f"qualification input is not one direct regular file: {path}")
    if before.st_size <= 0 or before.st_size > maximum:
        fail(f"qualification input has invalid size: {path}")
    if before.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        fail(f"qualification input is group/world writable: {path}")
    try:
        with path.open("rb") as handle:
            data = handle.read(maximum + 1)
            after = os.fstat(handle.fileno())
    except OSError as error:
        fail(f"cannot read {path}: {error}")
    identity = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )
    if identity(before) != identity(after) or len(data) != before.st_size:
        fail(f"qualification input changed while being read: {path}")
    return data


def lowercase_sha256(value: Any, label: str) -> str:
    if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
        fail(f"{label} is not one lowercase SHA-256")
    return value


def exact_integer(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        fail(f"{label} is not an unsigned integer")
    return value


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def verify_inventory(contents: pathlib.Path) -> tuple[bytes, dict[str, Any]]:
    path = contents / "Resources/renderer-production-inventory.json"
    data = regular_file(path, 1024 * 1024)
    try:
        value = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"renderer inventory is invalid JSON: {error}")
    if not isinstance(value, dict) or data != canonical_json(value):
        fail("renderer inventory is not canonical JSON plus LF")
    if set(value) != INVENTORY_KEYS:
        fail("renderer inventory field set differs")
    if value.get("kind") != INVENTORY_KIND or value.get("schemaVersion") != 3:
        fail("renderer inventory kind/schema is unsupported")
    if value.get("profile") != "rendererBundle" or value.get("sourceTuple") != SOURCE_TUPLE:
        fail("renderer inventory profile/source tuple differs")
    if value.get("architecture") != "arm64" or value.get("platform") != "macos":
        fail("renderer inventory architecture/platform differs")
    if value.get("definitionSha256") != DEFINITION_SHA256:
        fail("renderer inventory definition digest differs")
    components = value.get("components")
    if not isinstance(components, dict) or set(components) != set(EXPECTED_FILES):
        fail("renderer inventory component set differs")
    for name, expected_paths in EXPECTED_FILES.items():
        component = components[name]
        if not isinstance(component, dict) or set(component) != {"digest", "files"}:
            fail(f"renderer inventory component is malformed: {name}")
        files = component["files"]
        if not isinstance(files, list) or len(files) != len(expected_paths):
            fail(f"renderer inventory file set differs: {name}")
        for record, relative in zip(files, expected_paths):
            if not isinstance(record, dict) or set(record) != {"bytes", "path", "sha256"}:
                fail(f"renderer inventory file record is malformed: {relative}")
            if record["path"] != relative:
                fail(f"renderer inventory path differs: {relative}")
            expected_size = exact_integer(record["bytes"], f"{relative} bytes")
            expected_digest = lowercase_sha256(record["sha256"], f"{relative} sha256")
            artifact = regular_file(contents / relative, 8 * 1024 * 1024 * 1024)
            if len(artifact) != expected_size or digest(artifact) != expected_digest:
                fail(f"packaged artifact differs from renderer inventory: {relative}")
        component_payload = canonical_json({"files": files, "name": name})
        if component.get("digest") != digest(component_payload):
            fail(f"renderer component digest differs: {name}")
    return data, value


def worker_cdhash(worker_bundle: pathlib.Path) -> str:
    result = subprocess.run(
        ["codesign", "-d", "--verbose=4", os.fspath(worker_bundle)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        fail("codesign could not inspect the packaged renderer worker")
    matches = re.findall(r"(?m)^CDHash=([0-9A-Fa-f]+)$", result.stdout)
    if len(matches) != 1 or CDHASH_RE.fullmatch(matches[0].lower()) is None:
        fail("renderer worker has no unique 20-byte CodeDirectory hash")
    return matches[0].lower()


def verify_code_identity(
    path: pathlib.Path, requirement: str, *, check_nested: bool
) -> None:
    command = [
        "codesign",
        "--verify",
        "--strict",
        "--all-architectures",
    ]
    if check_nested:
        command.append("--deep")
    command.extend(["-R", f"={requirement}", os.fspath(path)])
    result = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        fail(f"code signature does not satisfy the expected Developer ID identity: {path}")


def timestamp(value: Any, label: str) -> dt.datetime:
    if not isinstance(value, str) or TIMESTAMP_RE.fullmatch(value) is None:
        fail(f"{label} is not canonical whole-second UTC")
    try:
        return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=dt.timezone.utc
        )
    except ValueError as error:
        fail(f"{label} is invalid: {error}")


def direct_bundle_path(path: pathlib.Path) -> pathlib.Path:
    """Return one direct bundle while allowing a canonicalized parent alias.

    Xcode can spell its archive products below ``/tmp`` even when the checkout and build
    authority were supplied below macOS' canonical ``/private/tmp``.  The bundle itself must
    still be a directory rather than a symlink.  Binding the pre- and post-resolution inode
    identities keeps that direct-leaf guarantee and also closes a parent-alias race without
    rejecting the operating system's stable ``/tmp`` alias.
    """
    supplied = path.absolute()
    try:
        before = supplied.lstat()
        resolved = supplied.resolve(strict=True)
        after = resolved.stat()
    except OSError as error:
        fail(f"cannot inspect runner app: {error}")
    if supplied.suffix != ".app" or not stat.S_ISDIR(before.st_mode):
        fail("runner must be one direct app bundle")
    if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
        fail("runner changed while resolving its parent authority")
    return resolved


def verify_signature(repo: pathlib.Path, signature: pathlib.Path, receipt: pathlib.Path) -> None:
    signature_data = regular_file(signature, 128)
    try:
        line = signature_data.decode("ascii")
        decoded = base64.b64decode(line[:-1], validate=True)
    except (UnicodeDecodeError, ValueError) as error:
        fail(f"renderer release signature is malformed: {error}")
    if not line.endswith("\n") or line[:-1].strip() != line[:-1] or len(decoded) != 64:
        fail("renderer release signature is not one canonical Ed25519 line")
    verifier = repo / ".github/scripts/verify-ed25519-signature.swift"
    result = subprocess.run(
        ["xcrun", "swift", os.fspath(verifier), PUBLIC_KEY, os.fspath(signature), os.fspath(receipt)],
        check=False,
    )
    if result.returncode != 0:
        fail("renderer release signature does not authenticate the receipt")


def verify(arguments: argparse.Namespace) -> None:
    runner = direct_bundle_path(arguments.runner_app)
    contents = runner / "Contents"
    worker_bundle = contents / "XPCServices/DoryRendererWorker.xpc"
    if not arguments.allow_unsealed_staging:
        verify_code_identity(runner, RUNNER_REQUIREMENT, check_nested=True)
        verify_code_identity(worker_bundle, WORKER_REQUIREMENT, check_nested=False)
    inventory_data, inventory = verify_inventory(contents)
    receipt_path = contents / "Resources/renderer-bootstrap-qualification.json"
    receipt_data = regular_file(receipt_path, 64 * 1024)
    try:
        receipt = json.loads(receipt_data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"renderer qualification receipt is invalid JSON: {error}")
    if not isinstance(receipt, dict) or receipt_data != canonical_json(receipt):
        fail("renderer qualification receipt is not canonical JSON plus LF")
    if set(receipt) != RECEIPT_KEYS:
        fail("renderer qualification receipt field set differs")
    expected_scalars = {
        "kind": KIND,
        "schemaVersion": 1,
        "bootstrapProtocolVersion": 3,
        "capabilityReceiptProtocolVersion": 4,
        "producerFenceContract": 1,
        "sourceTuple": SOURCE_TUPLE_WIRE,
        "tupleDefinitionSHA256": DEFINITION_SHA256,
        "guestMesaSHA256": GUEST_MESA_SHA256,
        "featureBits": PRODUCTION_FEATURE_BITS,
        "candidateInventorySHA256": digest(inventory_data),
    }
    for field, expected in expected_scalars.items():
        if receipt.get(field) != expected:
            fail(f"renderer qualification differs at {field}")
    kernel_data = regular_file(
        arguments.managed_kernel.absolute(), 2 * 1024 * 1024 * 1024
    )
    if receipt["managedGuestKernelSHA256"] != digest(kernel_data):
        fail("renderer qualification binds a different managed guest kernel")
    worker_record = inventory["components"]["rendererWorker"]["files"][0]
    if receipt["workerExecutableSHA256"] != worker_record["sha256"]:
        fail("renderer qualification binds a different worker executable")
    actual_cdhash = worker_cdhash(worker_bundle)
    if receipt["workerCodeDirectoryHash"] != actual_cdhash:
        fail("renderer qualification binds a different worker CodeDirectory")
    key_id = hashlib.sha256(base64.b64decode(PUBLIC_KEY, validate=True)).hexdigest()
    if receipt["signingKeyID"] != key_id or receipt["revocationKeyID"] != key_id:
        fail("renderer qualification key IDs differ from the release trust root")
    transcript = lowercase_sha256(
        receipt["bootstrapTranscriptSHA256"], "bootstrapTranscriptSHA256"
    )
    lowercase_sha256(receipt["capabilityReceiptSHA256"], "capabilityReceiptSHA256")
    if receipt["qualificationIdentity"] != f"dory-renderer-bootstrap:{transcript}":
        fail("renderer qualification identity does not bind its transcript")
    if exact_integer(receipt["revocationSequence"], "revocationSequence") < 1:
        fail("renderer qualification revocation sequence is stale")
    capsets = receipt["capsets"]
    if not isinstance(capsets, list) or [row.get("id") for row in capsets if isinstance(row, dict)] != [2, 4]:
        fail("renderer qualification does not contain exact VirGL2 and Venus capsets")
    for row, expected_version in zip(capsets, [None, 0]):
        if not isinstance(row, dict) or set(row) != {"byteCount", "id", "maximumVersion", "sha256"}:
            fail("renderer qualification capset record is malformed")
        if exact_integer(row["byteCount"], "capset byteCount") <= 0:
            fail("renderer qualification capset is empty")
        version = exact_integer(row["maximumVersion"], "capset maximumVersion")
        if (row["id"] == 2 and version <= 0) or (row["id"] == 4 and version != expected_version):
            fail("renderer qualification capset version is invalid")
        lowercase_sha256(row["sha256"], "capset sha256")
    issued = timestamp(receipt["issuedAt"], "issuedAt")
    expires = timestamp(receipt["expiresAt"], "expiresAt")
    now = dt.datetime.now(dt.timezone.utc)
    if issued > now + dt.timedelta(minutes=5) or expires <= now:
        fail("renderer qualification is not currently valid")
    if expires <= issued or (expires - issued).total_seconds() > MAX_VALIDITY_SECONDS:
        fail("renderer qualification validity window is invalid")
    signature = contents / "Resources/renderer-bootstrap-qualification.json.sig"
    signature_present = signature.exists() or signature.is_symlink()
    if arguments.require_release_signature:
        verify_signature(arguments.repo_root.resolve(strict=True), signature, receipt_path)
    elif signature_present:
        verify_signature(arguments.repo_root.resolve(strict=True), signature, receipt_path)
    print(f"renderer.qualification={receipt_path}")
    print(f"renderer.qualification.sha256={digest(receipt_data)}")
    print(
        "renderer.qualification.releaseSignature="
        + ("verified" if signature_present else "preview")
    )
    print(
        "renderer.qualification.resourceSeal="
        + ("staging-unsealed" if arguments.allow_unsealed_staging else "verified")
    )


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--runner-app", type=pathlib.Path, required=True)
    result.add_argument("--managed-kernel", type=pathlib.Path, required=True)
    result.add_argument(
        "--repo-root",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parent.parent,
    )
    result.add_argument("--require-release-signature", action="store_true")
    result.add_argument(
        "--allow-unsealed-staging",
        action="store_true",
        help=(
            "skip the outer/nested Developer ID resource-seal check only while packaging, "
            "before the final outer app signature is applied"
        ),
    )
    return result


def main() -> int:
    try:
        verify(parser().parse_args())
    except (OSError, VerificationError, subprocess.SubprocessError) as error:
        print(f"renderer qualification verification error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
