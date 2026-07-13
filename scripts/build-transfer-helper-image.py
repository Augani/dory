#!/usr/bin/env python3
"""Build a deterministic Docker-load archive containing only dory-transfer-helper."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import stat
import struct
import tarfile
from pathlib import Path


CREATED = "1970-01-01T00:00:00Z"


def canonical_json(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def sha256(contents: bytes) -> str:
    return hashlib.sha256(contents).hexdigest()


def validate_helper_elf(helper: bytes) -> None:
    if (
        len(helper) < 64
        or helper[:4] != b"\x7fELF"
        or helper[4] != 2
        or helper[5] != 1
        or helper[6] != 1
    ):
        raise ValueError("helper is not a 64-bit little-endian ELF")
    elf_type, machine, version = struct.unpack_from("<HHI", helper, 16)
    if elf_type not in (2, 3) or machine != 183 or version != 1:
        raise ValueError("helper is not a Linux/AArch64 executable ELF")
    program_offset = struct.unpack_from("<Q", helper, 32)[0]
    header_size, program_entry_size, program_count = struct.unpack_from("<HHH", helper, 52)
    if header_size != 64 or program_entry_size < 56 or program_count == 0:
        raise ValueError("helper ELF has an invalid program-header table")
    program_bytes = program_entry_size * program_count
    if program_offset > len(helper) or program_bytes > len(helper) - program_offset:
        raise ValueError("helper ELF program-header table is out of bounds")
    for index in range(program_count):
        segment_type = struct.unpack_from(
            "<I", helper, program_offset + index * program_entry_size
        )[0]
        if segment_type == 3:
            raise ValueError("helper ELF has a dynamic interpreter")


def tar_info(name: str, size: int, mode: int) -> tarfile.TarInfo:
    info = tarfile.TarInfo(name)
    info.size = size
    info.mode = mode
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    info.mtime = 0
    return info


def build_layer(helper: bytes) -> bytes:
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        archive.addfile(
            tar_info("dory-transfer-helper", len(helper), 0o755),
            io.BytesIO(helper),
        )
    return output.getvalue()


def build_archive(helper: bytes) -> tuple[bytes, dict[str, object]]:
    validate_helper_elf(helper)
    helper_digest = sha256(helper)
    layer = build_layer(helper)
    layer_digest = sha256(layer)
    config = canonical_json(
        {
            "architecture": "arm64",
            "config": {
                "Entrypoint": ["/dory-transfer-helper"],
                "Labels": {
                    "dev.dory.component": "transfer-helper",
                    "dev.dory.helper.sha256": helper_digest,
                    "dev.dory.manifest.schema": "1",
                },
                "User": "0",
                "WorkingDir": "/",
            },
            "created": CREATED,
            "history": [
                {
                    "created": CREATED,
                    "created_by": "Dory deterministic transfer-helper image builder v1",
                }
            ],
            "os": "linux",
            "rootfs": {"diff_ids": [f"sha256:{layer_digest}"], "type": "layers"},
        }
    )
    config_digest = sha256(config)
    config_name = f"{config_digest}.json"
    layer_directory = layer_digest
    manifest = canonical_json(
        [
            {
                "Config": config_name,
                "Layers": [f"{layer_directory}/layer.tar"],
                "RepoTags": None,
            }
        ]
    )
    legacy_layer = canonical_json(
        {
            "architecture": "arm64",
            "created": CREATED,
            "id": layer_digest,
            "os": "linux",
        }
    )
    members = [
        (config_name, config, 0o644),
        (f"{layer_directory}/VERSION", b"1.0", 0o644),
        (f"{layer_directory}/json", legacy_layer, 0o644),
        (f"{layer_directory}/layer.tar", layer, 0o644),
        ("manifest.json", manifest, 0o644),
    ]
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name, contents, mode in members:
            archive.addfile(tar_info(name, len(contents), mode), io.BytesIO(contents))
    image_archive = output.getvalue()
    metadata: dict[str, object] = {
        "archiveBytes": len(image_archive),
        "archiveSha256": sha256(image_archive),
        "helperBytes": len(helper),
        "helperSha256": helper_digest,
        "imageConfigDigest": f"sha256:{config_digest}",
        "layerDiffId": f"sha256:{layer_digest}",
        "platform": "linux/arm64",
        "schemaVersion": 1,
    }
    return image_archive, metadata


def verify_archive(
    image_archive: bytes, expected_helper_sha256: str | None = None
) -> dict[str, object]:
    with tarfile.open(fileobj=io.BytesIO(image_archive), mode="r:") as archive:
        members = archive.getmembers()
        for member in members:
            if not member.isfile() or any(
                (
                    member.uid != 0,
                    member.gid != 0,
                    member.mtime != 0,
                    bool(member.pax_headers),
                )
            ):
                raise ValueError(f"non-canonical outer image member: {member.name}")
        by_name = {member.name: member for member in members}
        if len(by_name) != len(members) or "manifest.json" not in by_name:
            raise ValueError("image archive has duplicate members or no manifest")
        manifest_bytes = archive.extractfile(by_name["manifest.json"]).read()
        manifest = json.loads(manifest_bytes)
        if canonical_json(manifest) != manifest_bytes:
            raise ValueError("image manifest is not canonical JSON")
        if not isinstance(manifest, list) or len(manifest) != 1:
            raise ValueError("image archive must contain exactly one image")
        item = manifest[0]
        if item.get("RepoTags") is not None or len(item.get("Layers", [])) != 1:
            raise ValueError("image archive must be untagged with exactly one layer")
        config_name = item.get("Config", "")
        layer_name = item["Layers"][0]
        expected_names = {
            config_name,
            layer_name,
            f"{Path(layer_name).parent}/VERSION",
            f"{Path(layer_name).parent}/json",
            "manifest.json",
        }
        if set(by_name) != expected_names:
            raise ValueError("image archive contains an unexpected member set")
        expected_order = [
            config_name,
            f"{Path(layer_name).parent}/VERSION",
            f"{Path(layer_name).parent}/json",
            layer_name,
            "manifest.json",
        ]
        if [member.name for member in members] != expected_order:
            raise ValueError("image archive member order is not canonical")
        config_bytes = archive.extractfile(by_name[config_name]).read()
        config_digest = sha256(config_bytes)
        if config_name != f"{config_digest}.json":
            raise ValueError("image config name does not match its digest")
        config = json.loads(config_bytes)
        if canonical_json(config) != config_bytes:
            raise ValueError("image config is not canonical JSON")
        image_config = config.get("config", {})
        labels = image_config.get("Labels", {})
        helper_digest = labels.get("dev.dory.helper.sha256", "")
        if expected_helper_sha256 and helper_digest != expected_helper_sha256:
            raise ValueError("embedded helper digest label does not match")
        if (
            config.get("architecture") != "arm64"
            or config.get("os") != "linux"
            or image_config.get("Entrypoint") != ["/dory-transfer-helper"]
            or image_config.get("User") != "0"
            or labels.get("dev.dory.component") != "transfer-helper"
            or labels.get("dev.dory.manifest.schema") != "1"
        ):
            raise ValueError("image config violates the transfer-helper contract")
        layer = archive.extractfile(by_name[layer_name]).read()
        layer_digest = sha256(layer)
        if config.get("rootfs") != {
            "diff_ids": [f"sha256:{layer_digest}"],
            "type": "layers",
        }:
            raise ValueError("layer digest does not match the image rootfs")
        version = archive.extractfile(
            by_name[f"{Path(layer_name).parent}/VERSION"]
        ).read()
        if version != b"1.0":
            raise ValueError("legacy layer version is invalid")
        legacy_bytes = archive.extractfile(
            by_name[f"{Path(layer_name).parent}/json"]
        ).read()
        legacy = json.loads(legacy_bytes)
        if canonical_json(legacy) != legacy_bytes or legacy != {
            "architecture": "arm64",
            "created": CREATED,
            "id": str(Path(layer_name).parent),
            "os": "linux",
        }:
            raise ValueError("legacy layer metadata is invalid")

    with tarfile.open(fileobj=io.BytesIO(layer), mode="r:") as layer_archive:
        layer_members = layer_archive.getmembers()
        if len(layer_members) != 1:
            raise ValueError("helper image layer must contain exactly one entry")
        helper_member = layer_members[0]
        if (
            helper_member.name != "dory-transfer-helper"
            or not helper_member.isfile()
            or helper_member.mode != 0o755
            or helper_member.uid != 0
            or helper_member.gid != 0
            or helper_member.mtime != 0
            or bool(helper_member.pax_headers)
        ):
            raise ValueError("helper image layer entry is not canonical")
        helper = layer_archive.extractfile(helper_member).read()
    if sha256(helper) != helper_digest:
        raise ValueError("helper bytes do not match the config label")
    validate_helper_elf(helper)
    canonical_archive, metadata = build_archive(helper)
    if canonical_archive != image_archive:
        raise ValueError("image archive bytes are not canonical")
    return metadata


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--helper", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--metadata-output", type=Path)
    parser.add_argument("--verify", type=Path)
    parser.add_argument("--expected-helper-sha256")
    arguments = parser.parse_args()

    if arguments.verify:
        if arguments.helper or arguments.output or arguments.metadata_output:
            parser.error("--verify cannot be combined with build outputs")
        metadata = verify_archive(
            arguments.verify.read_bytes(), arguments.expected_helper_sha256
        )
        print((canonical_json(metadata) + b"\n").decode("utf-8"), end="")
        return
    if not arguments.helper or not arguments.output or arguments.expected_helper_sha256:
        parser.error("build mode requires --helper and --output")

    helper_stat = arguments.helper.stat()
    if not stat.S_ISREG(helper_stat.st_mode) or helper_stat.st_nlink != 1:
        raise SystemExit("transfer helper image: helper must be a singly linked regular file")
    helper = arguments.helper.read_bytes()
    image_archive, metadata = build_archive(helper)

    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = arguments.output.with_name(f".{arguments.output.name}.{os.getpid()}.partial")
    temporary.write_bytes(image_archive)
    os.chmod(temporary, 0o644)
    os.replace(temporary, arguments.output)

    encoded_metadata = canonical_json(metadata) + b"\n"
    if arguments.metadata_output:
        arguments.metadata_output.parent.mkdir(parents=True, exist_ok=True)
        metadata_temporary = arguments.metadata_output.with_name(
            f".{arguments.metadata_output.name}.{os.getpid()}.partial"
        )
        metadata_temporary.write_bytes(encoded_metadata)
        os.chmod(metadata_temporary, 0o644)
        os.replace(metadata_temporary, arguments.metadata_output)
    print(encoded_metadata.decode("utf-8"), end="")


if __name__ == "__main__":
    main()
