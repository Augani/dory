#!/usr/bin/env python3
"""Inventory the Wave 0 app and guest producers without calling an incomplete set a candidate."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
SHA256 = re.compile(r"^[0-9a-f]{64}$")


class InventoryError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise InventoryError(f"Wave 0 candidate inventory: {message}")


def direct_regular(path: Path) -> bool:
    return path.is_file() and not path.is_symlink()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def relative_path(root: Path, path: Path) -> str:
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return path.name


def macos_minimum(vtool: str, binary: Path) -> str | None:
    result = subprocess.run(
        [vtool, "-arch", "arm64", "-show-build", str(binary)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    macos = False
    for line in result.stdout.splitlines():
        fields = line.split()
        if fields[:2] == ["platform", "MACOS"]:
            macos = True
            continue
        if macos and fields[:1] == ["minos"] and len(fields) == 2:
            return fields[1]
    return None


def artifact(
    *, identifier: str, file: Path, display_path: str, vtool: str | None = None
) -> dict[str, Any]:
    if not direct_regular(file):
        return {"id": identifier, "path": display_path, "status": "unavailable"}
    result: dict[str, Any] = {
        "id": identifier,
        "path": display_path,
        "status": "available",
        "byteCount": file.stat().st_size,
        "sha256": sha256(file),
    }
    if vtool is not None:
        minimum = macos_minimum(vtool, file)
        if minimum is None:
            result["status"] = "unreadable-macos-deployment-target"
        else:
            result["minimumMacOS"] = minimum
    return result


def source_inputs(root: Path, paths: tuple[str, ...]) -> list[dict[str, str]]:
    result: list[dict[str, str]] = []
    for relative in paths:
        file = root / relative
        if direct_regular(file):
            result.append({"path": relative, "status": "available", "sha256": sha256(file)})
        else:
            result.append({"path": relative, "status": "unavailable"})
    return result


def producer(
    *,
    identifier: str,
    owner: str,
    inputs: list[dict[str, str]],
    artifacts: list[dict[str, Any]],
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    source_available = all(item["status"] == "available" for item in inputs)
    artifacts_available = all(item["status"] == "available" for item in artifacts)
    metadata_available = not isinstance(metadata, dict) or not isinstance(metadata.get("status"), str) or metadata["status"] in {
        "available", "matches-current-archive", "matches-current-firmware", "matches-current-inputs",
        "matches-current-source", "matches-current-producer",
    }
    result: dict[str, Any] = {
        "id": identifier,
        "owner": owner,
        "sourceInputs": inputs,
        "artifacts": artifacts,
        "status": "available" if source_available and artifacts_available and metadata_available else "incomplete",
    }
    if metadata:
        result["metadata"] = metadata
    return result


def vtool_path(value: str | None) -> str:
    if value:
        return value
    result = subprocess.run(
        ["xcrun", "--find", "vtool"], text=True, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, check=False,
    )
    if result.returncode != 0 or not result.stdout.strip():
        fail("vtool is unavailable")
    return result.stdout.strip()


def plist_identity(app: Path) -> dict[str, str]:
    info = app / "Contents/Info.plist"
    if not direct_regular(info):
        return {"status": "unavailable"}
    try:
        value = plistlib.loads(info.read_bytes())
    except (plistlib.InvalidFileException, OSError):
        return {"status": "invalid"}
    if not isinstance(value, dict):
        return {"status": "invalid"}
    keys = ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion")
    result = {key: value[key] for key in keys if isinstance(value.get(key), str)}
    # The status key is added after this completeness check.  Counting it here
    # made a fully populated Info.plist look incomplete in every receipt.
    result["status"] = "available" if len(result) == len(keys) else "incomplete"
    return result


def source_binding_metadata(root: Path, app: Path) -> dict[str, Any]:
    binding = app / "Contents/Resources/development-source-binding.json"
    tool = root / "scripts/write-development-source-binding.py"
    if not direct_regular(binding) or not direct_regular(tool):
        return {"status": "unavailable"}
    try:
        result = subprocess.run(
            [sys.executable, str(tool), "verify-sources", "--source-root", str(root), "--binding", str(binding)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired):
        return {"status": "invalid", "bindingSHA256": sha256(binding)}
    if result.returncode == 0:
        return {"status": "matches-current-source", "bindingSHA256": sha256(binding)}
    detail = result.stderr.strip()
    return {
        "status": "stale-source" if "does not match" in detail else "invalid",
        "bindingSHA256": sha256(binding),
    }


def app_metadata(root: Path, app: Path) -> dict[str, Any]:
    identity = plist_identity(app)
    binding = source_binding_metadata(root, app)
    status = "matches-current-source" if (
        identity["status"] == "available" and binding["status"] == "matches-current-source"
    ) else "invalid-app-identity" if identity["status"] != "available" else binding["status"]
    return {"status": status, "identity": identity, "sourceBinding": binding}


def source_state(root: Path) -> dict[str, Any]:
    commit = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "HEAD"], text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    status = subprocess.run(
        ["git", "-C", str(root), "status", "--porcelain=v1"], text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if commit.returncode != 0 or status.returncode != 0:
        return {"status": "unavailable"}
    status_bytes = status.stdout.encode("utf-8")
    return {
        "status": "available",
        "headCommit": commit.stdout.strip(),
        "worktreeDirty": bool(status.stdout),
        "worktreeStatusSHA256": hashlib.sha256(status_bytes).hexdigest(),
    }


def ffi_metadata(receipt: Path, archive: Path) -> dict[str, Any]:
    if not direct_regular(receipt):
        return {"status": "unavailable"}
    try:
        value = json.loads(receipt.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"status": "invalid"}
    if not isinstance(value, dict) or value.get("kind") != "dev.dory.ffi-deployment-targets":
        return {"status": "invalid"}
    expected = value.get("librarySHA256")
    if not isinstance(expected, str) or SHA256.fullmatch(expected) is None:
        return {"status": "invalid"}
    if not direct_regular(archive):
        return {"status": "unavailable", "receiptSHA256": sha256(receipt)}
    return {
        "status": "matches-current-archive" if expected == sha256(archive) else "archive-mismatch",
        "receiptSHA256": sha256(receipt),
        "maximumSupportedMacOS": value.get("maximumSupportedMacOS"),
        "slices": value.get("slices"),
    }


def firmware_metadata(manifest: Path, firmware: Path) -> dict[str, Any]:
    if not direct_regular(manifest):
        return {"status": "unavailable"}
    try:
        value = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"status": "invalid"}
    expected = value.get("firmwareCodeSHA256") if isinstance(value, dict) else None
    if not isinstance(expected, str) or SHA256.fullmatch(expected) is None:
        return {"status": "invalid"}
    if not direct_regular(firmware):
        return {"status": "unavailable", "manifestSHA256": sha256(manifest)}
    return {
        "status": "matches-current-firmware" if expected == sha256(firmware) else "firmware-mismatch",
        "manifestSHA256": sha256(manifest),
        "source": value.get("source"),
        "machineABIIdentity": value.get("machineABIIdentity"),
        "firmwareABIIdentity": value.get("firmwareABIIdentity"),
    }


def stamp_values(stamp: Path) -> dict[str, str] | None:
    """Return a strict key/value desktop build stamp, or ``None`` when malformed."""
    try:
        values: dict[str, str] = {}
        for line in stamp.read_text(encoding="utf-8").splitlines():
            key, separator, value = line.partition("=")
            if not separator or not key or not value or key in values:
                return None
            values[key] = value
    except OSError:
        return None
    return values


def desktop_rootfs_metadata(root: Path, guest: Path) -> dict[str, Any]:
    """Keep a present desktop rootfs from being treated as current by presence alone."""
    fingerprint = root / "guest/desktop/input-fingerprint.sh"
    if not direct_regular(fingerprint):
        return {"status": "unavailable", "detail": "desktop input fingerprint script is unavailable"}

    records: list[dict[str, str]] = []
    for distro in ("debian", "ubuntu", "kali"):
        stamp = guest / f"dory-desktop-{distro}-build-arm64.stamp"
        record: dict[str, str] = {
            "distro": distro,
            "stamp": relative_path(root, stamp),
        }
        if not direct_regular(stamp):
            record["status"] = "unavailable"
            records.append(record)
            continue
        values = stamp_values(stamp)
        recorded = values.get("input_sha256") if values is not None else None
        if (
            values is None
            or values.get("schema") != "2"
            or values.get("arch") != "arm64"
            or values.get("distro") != distro
            or not isinstance(recorded, str)
            or SHA256.fullmatch(recorded) is None
        ):
            record["status"] = "invalid-stamp"
            records.append(record)
            continue
        try:
            current_result = subprocess.run(
                [str(fingerprint), "arm64", distro],
                cwd=root,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=120,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            record["status"] = "input-fingerprint-unavailable"
            records.append(record)
            continue
        current = current_result.stdout.strip()
        if current_result.returncode != 0 or SHA256.fullmatch(current) is None:
            record["status"] = "input-fingerprint-unavailable"
            records.append(record)
            continue
        record["recordedInputSHA256"] = recorded
        record["currentInputSHA256"] = current
        record["status"] = "matches-current-inputs" if recorded == current else "stale-inputs"
        if record["status"] == "matches-current-inputs":
            compressed = guest / f"dory-desktop-{distro}-rootfs-arm64.ext4.zst"
            expected_archive = values.get("compressed_sha256", "")
            if not SHA256.fullmatch(expected_archive):
                record["status"] = "invalid-stamp"
            elif not direct_regular(compressed):
                record["status"] = "unavailable"
            else:
                record["recordedCompressedSHA256"] = expected_archive
                record["actualCompressedSHA256"] = sha256(compressed)
                if record["actualCompressedSHA256"] != expected_archive:
                    record["status"] = "artifact-mismatch"
        records.append(record)

    statuses = {record["status"] for record in records}
    if statuses == {"matches-current-inputs"}:
        status = "matches-current-inputs"
    elif "artifact-mismatch" in statuses:
        status = "artifact-mismatch"
    elif "stale-inputs" in statuses:
        status = "stale-inputs"
    else:
        status = "unavailable"
    return {"status": status, "buildStamps": records}


def mesa_producer_metadata(root: Path, guest: Path) -> dict[str, Any]:
    """Verify each architecture/profile instead of admitting present archives."""
    records = []
    for profile, arch, name in (
        ("venus", "arm64", "verify-build.sh"),
        ("arm-virgl2", "arm64", "verify-pc-virgl2-build.sh"),
        ("pc-virgl2", "x86_64", "verify-pc-virgl2-build.sh"),
    ):
        record = {"profile": profile, "architecture": arch, "status": "unavailable"}
        verifier = root / "guest/mesa" / name
        if direct_regular(verifier):
            try:
                result = subprocess.run(
                    [str(verifier), arch], cwd=root,
                    env={**os.environ, "DORY_MESA_OUT_DIR": str(guest)},
                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    check=False, timeout=120,
                )
                record["status"] = "matches-current-producer" if result.returncode == 0 else "verification-failed"
                record["verificationSHA256"] = hashlib.sha256(result.stdout + result.stderr).hexdigest()
            except (OSError, subprocess.TimeoutExpired):
                record["status"] = "verification-unavailable"
        records.append(record)
    return {
        "status": "matches-current-producer" if all(
            record["status"] == "matches-current-producer" for record in records
        ) else "verification-failed",
        "profiles": records,
    }


def kernel_producer_metadata(root: Path, guest: Path, *, arch: str, profile: str) -> dict[str, str]:
    """Require the kernel producer's own verifier, not artifact presence alone."""
    verifier = root / "guest/kernel/verify-build.sh"
    if not direct_regular(verifier):
        return {"status": "unavailable"}
    environment = os.environ.copy()
    environment.update({
        "DORY_KERNEL_OUT_DIR": str(guest),
        "DORY_KERNEL_PROFILE": profile,
        # Explicit profile selection is the authority; no ambient experimental
        # switch may silently select a different producer contract.
        "DORY_EXPERIMENTAL_GPU": "0",
    })
    try:
        result = subprocess.run(
            [str(verifier), arch], cwd=root, env=environment,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            check=False, timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired):
        return {"status": "verification-unavailable"}
    transcript = result.stdout + result.stderr
    if result.returncode == 0:
        return {
            "status": "matches-current-producer",
            "verificationSHA256": hashlib.sha256(transcript).hexdigest(),
        }
    return {
        "status": "verification-failed",
        "verificationSHA256": hashlib.sha256(transcript).hexdigest(),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--ffi", type=Path, default=ROOT / "dory-core-swift/artifacts/DoryFFI.xcframework/macos-arm64_x86_64/libdory_ffi.a")
    parser.add_argument("--guest-output", type=Path, default=ROOT / "guest/out")
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--vtool")
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()

    app = arguments.app.absolute()
    root = arguments.source_root.resolve()
    guest = arguments.guest_output.resolve()
    ffi = arguments.ffi.absolute()
    if not app.is_dir() or app.is_symlink():
        fail(f"app must be a direct directory: {app}")
    vtool = vtool_path(arguments.vtool)
    def app_file(identifier: str, relative: str, *, mach_o: bool = True) -> dict[str, Any]:
        return artifact(
            identifier=identifier,
            file=app / relative,
            display_path=f"Dory.app/{relative}",
            vtool=vtool if mach_o else None,
        )
    repo_file = lambda identifier, relative: artifact(
        identifier=identifier, file=root / relative, display_path=relative
    )
    guest_file = lambda identifier, relative: artifact(
        identifier=identifier, file=guest / relative, display_path=f"guest/out/{relative}"
    )

    ffi_receipt = root / "dory-core-swift/artifacts/DoryFFI.xcframework/deployment-targets.json"
    firmware_manifest = guest / "dory-pc-firmware/manifest.json"
    firmware_code = guest / "dory-pc-firmware/firmware-code.fd"
    producers = [
        producer(
            identifier="app", owner="Dory Xcode application target",
            inputs=source_inputs(root, ("Dory.xcodeproj/project.pbxproj", "Config/Dory-Info.plist", "scripts/build.sh")),
            artifacts=[app_file("dory-app", "Contents/MacOS/Dory")],
            metadata=app_metadata(root, app),
        ),
        producer(
            identifier="daemon", owner="dory-core-swift doryd",
            inputs=source_inputs(root, ("dory-core-swift/Package.swift", "dory-core-swift/Sources/doryd/main.swift")),
            artifacts=[app_file("doryd", "Contents/Helpers/doryd")],
        ),
        producer(
            identifier="ffi", owner="dory-core Rust static library producer",
            inputs=source_inputs(root, ("dory-core/Cargo.lock", "scripts/build-dory-ffi-xcframework.sh", "scripts/verify-dory-ffi-deployment-targets.py")),
            artifacts=[artifact(identifier="dory-ffi", file=ffi, display_path=relative_path(root, ffi))],
            metadata=ffi_metadata(ffi_receipt, ffi),
        ),
        producer(
            identifier="runner", owner="ContainerizationEngine dory-hv",
            inputs=source_inputs(root, ("Packages/ContainerizationEngine/Package.swift", "Packages/ContainerizationEngine/Sources/dory-hv/main.swift", "scripts/build.sh")),
            artifacts=[app_file("dory-hv", "Contents/Helpers/DoryHVRunner.app/Contents/MacOS/dory-hv")],
        ),
        producer(
            identifier="renderer", owner="renderer tuple and nested worker producer",
            inputs=source_inputs(root, ("Config/DoryRendererProductionTuple.json", "scripts/xcode-package-renderer-production.sh", "scripts/assemble-renderer-production-worker.sh")),
            artifacts=[
                app_file("renderer-worker", "Contents/Helpers/DoryHVRunner.app/Contents/XPCServices/DoryRendererWorker.xpc/Contents/MacOS/DoryRendererWorker"),
                app_file(
                    "renderer-production-inventory",
                    "Contents/Helpers/DoryHVRunner.app/Contents/Resources/renderer-production-inventory.json",
                    mach_o=False,
                ),
            ],
        ),
        producer(
            identifier="pc-firmware", owner="DoryFirmware PC bundle producer",
            inputs=source_inputs(root, ("dory-core-swift/Sources/DoryFirmware/DoryFirmwareBundleBuilder.swift", "dory-core-swift/Sources/DoryFirmware/DoryPCUEFILaunchPlan.swift")),
            artifacts=[guest_file("pc-firmware-manifest", "dory-pc-firmware/manifest.json"), guest_file("pc-firmware-code", "dory-pc-firmware/firmware-code.fd")],
            metadata=firmware_metadata(firmware_manifest, firmware_code),
        ),
        producer(
            identifier="arm64-kernel", owner="guest/kernel Venus profile producer",
            inputs=source_inputs(root, ("guest/kernel/build.sh", "guest/kernel/profile.sh")),
            artifacts=[guest_file("arm64-venus-kernel", "Image-gpu"), guest_file("arm64-venus-stamp", "kernel-build-arm64-gpu.stamp")],
            metadata=kernel_producer_metadata(root, guest, arch="arm64", profile="venus"),
        ),
        producer(
            identifier="arm64-desktop-kernel", owner="guest/kernel accelerated-desktop profile producer",
            inputs=source_inputs(root, ("guest/kernel/build.sh", "guest/kernel/profile.sh")),
            artifacts=[guest_file("arm64-desktop-kernel", "Image-desktop"), guest_file("arm64-desktop-stamp", "kernel-build-arm64-desktop.stamp")],
            metadata=kernel_producer_metadata(root, guest, arch="arm64", profile="accelerated-desktop"),
        ),
        producer(
            identifier="x86_64-kernel", owner="guest/kernel PC VirGL2 profile producer",
            inputs=source_inputs(root, ("guest/kernel/build.sh", "guest/kernel/profile.sh")),
            artifacts=[guest_file("x86_64-pc-virgl2-kernel", "bzImage-x86-pc-virgl2"), guest_file("x86_64-pc-virgl2-stamp", "kernel-build-amd64-pc-virgl2.stamp")],
            metadata=kernel_producer_metadata(root, guest, arch="amd64", profile="pc-virgl2"),
        ),
        producer(
            identifier="desktop-rootfs", owner="guest/desktop general-purpose distro producer",
            inputs=source_inputs(root, (
                "guest/desktop/PINS", "guest/desktop/build.sh",
                "guest/desktop/input-fingerprint.sh", "guest/desktop/verify-build.sh",
            )),
            artifacts=[
                guest_file("desktop-debian-rootfs", "dory-desktop-debian-rootfs-arm64.ext4.zst"),
                guest_file("desktop-ubuntu-rootfs", "dory-desktop-ubuntu-rootfs-arm64.ext4.zst"),
                guest_file("desktop-kali-rootfs", "dory-desktop-kali-rootfs-arm64.ext4.zst"),
            ],
            metadata=desktop_rootfs_metadata(root, guest),
        ),
        producer(
            identifier="mesa", owner="guest/mesa Venus and ARM64/x86_64 VirGL2 producers",
            inputs=source_inputs(root, ("guest/mesa/PINS", "guest/mesa/build.sh", "guest/mesa/build-pc-virgl2.sh")),
            artifacts=[guest_file("arm64-venus-mesa", "dory-mesa-venus-arm64.tar.zst"), guest_file("arm64-virgl2-mesa", "dory-mesa-virgl2-arm64.tar.zst"), guest_file("x86_64-virgl2-mesa", "dory-mesa-virgl2-x86_64.tar.zst")],
            metadata=mesa_producer_metadata(root, guest),
        ),
        producer(
            identifier="guest-tools", owner="guest initfs and Docker producers",
            inputs=source_inputs(root, ("guest/initfs/build.sh", "guest/initfs/vendor/docker-29.6.1-dory1/rebuild.sh")),
            artifacts=[
                guest_file("arm64-agent", "dory-agent-arm64"),
                guest_file("x86_64-agent", "dory-agent-amd64"),
                guest_file("arm64-docker", "docker-29.6.1-dory1/docker-29.6.1-dory1-arm64.tgz"),
            ],
        ),
    ]
    incomplete = [entry["id"] for entry in producers if entry["status"] != "available"]
    app_source_binding = app_metadata(root, app)["sourceBinding"]["status"]
    source_bound = app_source_binding == "matches-current-source"
    result = {
        "schemaVersion": 1,
        "kind": "dev.dory.wave0-producer-inventory",
        "sourceState": source_state(root),
        "appIdentity": plist_identity(app),
        "candidateStatus": (
            "incomplete" if incomplete
            else "development-source-bound" if source_bound
            else "development-unbound"
        ),
        "candidateSourceBinding": (
            "verified: app embeds identical complete source entries; Git metadata records capture time"
            if source_bound
            else "unproven: app artifacts do not embed the current source revision"
        ),
        "releaseQualified": False,
        "incompleteProducers": incomplete,
        "producers": producers,
    }
    encoded = (json.dumps(result, sort_keys=True, indent=2) + "\n").encode("utf-8")
    if arguments.output is None:
        sys.stdout.buffer.write(encoded)
    else:
        output = arguments.output if arguments.output.is_absolute() else root / arguments.output
        if output.is_symlink():
            fail(f"output must not be a symbolic link: {output}")
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(encoded)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except InventoryError as error:
        raise SystemExit(str(error))
