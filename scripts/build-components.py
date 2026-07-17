#!/usr/bin/env python3
"""Build Dory's Apple Silicon component payloads and signed catalog."""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import pathlib
import shutil
import stat
import subprocess
import tempfile
import uuid
from typing import NoReturn


CATALOG_KIND = "dev.dory.component-catalog"
CATALOG_SCHEMA = 1
ARCHITECTURE = "arm64"


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


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def byte_size(path: pathlib.Path) -> int:
    return regular_file(path, "artifact").stat().st_size


def tree_size(path: pathlib.Path) -> int:
    total = 0
    for root, directories, files in os.walk(path, followlinks=False):
        directories[:] = [
            name for name in directories
            if not pathlib.Path(root, name).is_symlink()
        ]
        for name in files:
            candidate = pathlib.Path(root, name)
            info = candidate.lstat()
            if stat.S_ISREG(info.st_mode):
                total += info.st_size
    if total <= 0:
        fail(f"core app contains no regular-file payload: {path}")
    return total


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
    desktop_env["DORY_KERNEL_PROFILE"] = "desktop"
    run([str(repo / "guest/kernel/verify-build.sh"), "arm64"], cwd=repo, env=desktop_env)
    for distro in ("debian", "ubuntu", "kali"):
        run([str(repo / "guest/desktop/verify-build.sh"), "arm64", distro], cwd=repo)
    run(["codesign", "--verify", "--strict", str(kubectl)])
    archs = run(["lipo", "-archs", str(kubectl)]).split()
    if "arm64" not in archs:
        fail(f"kubectl does not contain arm64 code: {' '.join(archs)}")


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


def component_specs(source_root: pathlib.Path, kubectl: pathlib.Path) -> list[dict]:
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
            "An Ubuntu 24.04 LTS Xfce desktop with its own packages and official repositories.",
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
                "assets": [
                    {
                        "path": f"dory-desktop-{distro}-rootfs-arm64.ext4.lzfse",
                        "source": source_root / f"dory-desktop-{distro}-rootfs-arm64.ext4",
                        "delivery": "lzfse-stored",
                        "executable": False,
                    },
                    {
                        "path": f"dory-desktop-{distro}-build-arm64.stamp",
                        "source": source_root / f"dory-desktop-{distro}-build-arm64.stamp",
                        "delivery": "none",
                        "executable": False,
                    },
                    {
                        "path": f"dory-desktop-{distro}-packages-arm64.txt",
                        "source": source_root / f"dory-desktop-{distro}-packages-arm64.txt",
                        "delivery": "none",
                        "executable": False,
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
            "assets": [
                {
                    "path": "kubectl",
                    "source": kubectl,
                    "delivery": "none",
                    "executable": True,
                }
            ],
        },
        {
            "id": "linux-machines",
            "displayName": "Linux Machines",
            "summary": "Headless VPS-style Linux machines with terminals, services, and persistent disks.",
            "dependencies": ["docker-core"],
            "assets": [
                {
                    "path": "dory-hv-kernel-arm64",
                    "source": source_root / "Image",
                    "delivery": "lzfse-expanded",
                    "executable": False,
                },
                {
                    "path": "dory-machine-rootfs-arm64.ext4",
                    "source": source_root / "initfs-arm64.ext4",
                    "delivery": "lzfse-expanded",
                    "executable": False,
                },
            ],
        },
        {
            "id": "linux-desktop",
            "displayName": "Linux Desktop Runtime",
            "summary": "The graphical VM kernel shared by independently installable desktop distributions.",
            "dependencies": ["docker-core"],
            "assets": [
                {
                    "path": "dory-desktop-kernel-arm64.lzfse",
                    "source": source_root / "Image-desktop",
                    "delivery": "lzfse-stored",
                    "executable": False,
                },
                {
                    "path": "kernel-build-arm64-desktop.stamp",
                    "source": source_root / "kernel-build-arm64-desktop.stamp",
                    "delivery": "none",
                    "executable": False,
                },
            ],
        },
        *desktop_specs,
    ]


def safe_artifact_name(
    version: str, component_id: str, installed_path: str, compressed: bool
) -> str:
    suffix = installed_path
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
) -> dict:
    source = regular_file(pathlib.Path(asset["source"]), f"{component_id} source")
    delivery = asset["delivery"]
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
    return {
        "path": asset["path"],
        "url": f"{asset_base_url.rstrip('/')}/{artifact_name}",
        "compression": compression,
        "downloadBytes": download_bytes,
        "installedBytes": installed_bytes,
        "sha256": download_digest,
        "installedSHA256": installed_digest,
        "executable": bool(asset["executable"]),
    }


def sign_catalog(catalog_path: pathlib.Path, signer: pathlib.Path) -> str:
    regular_file(signer, "Sparkle sign_update")
    signature = run([str(signer), "-p", str(catalog_path)]).strip()
    try:
        decoded = base64.b64decode(signature, validate=True)
    except ValueError:
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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--core-artifact", required=True, type=pathlib.Path)
    parser.add_argument("--core-app", required=True, type=pathlib.Path)
    parser.add_argument("--kubectl", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--asset-base-url")
    parser.add_argument("--source-root", type=pathlib.Path)
    parser.add_argument("--minimum-app-version")
    parser.add_argument("--generated-at")
    parser.add_argument("--signer", type=pathlib.Path)
    parser.add_argument("--skip-source-verification", action="store_true")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    repo = pathlib.Path(__file__).resolve().parent.parent
    source_root = (args.source_root or repo / "guest" / "out").resolve()
    core_artifact = regular_file(args.core_artifact.resolve(), "Docker Core artifact")
    core_app = directory(args.core_app.resolve(), "Docker Core app")
    kubectl = regular_file(args.kubectl.resolve(), "kubectl")
    compression_tool = pathlib.Path("/usr/bin/compression_tool")
    regular_file(compression_tool, "macOS compression_tool")
    if not args.skip_source_verification:
        validate_sources(repo, source_root, kubectl)

    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    staging: pathlib.Path | None = pathlib.Path(
        tempfile.mkdtemp(prefix=f".{output.name}.partial-", dir=output.parent)
    )
    try:
        asset_base_url = args.asset_base_url or (
            f"https://github.com/Augani/dory/releases/download/v{args.version}"
        )
        releases = [
            {
                "id": "docker-core",
                "version": args.version,
                "displayName": "Docker Core",
                "summary": "The signed Dory app, Docker engine, CLI, Buildx, Compose, networking, storage, migration, and health tools.",
                "dependencies": [],
                "downloadBytes": byte_size(core_artifact),
                "installedBytes": tree_size(core_app),
                "assets": [],
            }
        ]
        for spec in component_specs(source_root, kubectl):
            assets = [
                materialize_asset(
                    version=args.version,
                    component_id=spec["id"],
                    asset=asset,
                    output=staging,
                    asset_base_url=asset_base_url,
                    compression_tool=compression_tool,
                )
                for asset in spec["assets"]
            ]
            releases.append(
                {
                    "id": spec["id"],
                    "version": args.version,
                    "displayName": spec["displayName"],
                    "summary": spec["summary"],
                    "dependencies": spec["dependencies"],
                    "downloadBytes": sum(asset["downloadBytes"] for asset in assets),
                    "installedBytes": sum(asset["installedBytes"] for asset in assets),
                    "assets": assets,
                }
            )

        catalog = {
            "kind": CATALOG_KIND,
            "schemaVersion": CATALOG_SCHEMA,
            "releaseVersion": args.version,
            "generatedAt": generated_at(args.generated_at),
            "minimumAppVersion": args.minimum_app_version or args.version,
            "architecture": ARCHITECTURE,
            "components": releases,
        }
        catalog_path = staging / "catalog.json"
        catalog_path.write_text(
            json.dumps(catalog, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        os.chmod(catalog_path, 0o644)
        if args.signer:
            signature = sign_catalog(catalog_path, args.signer.resolve())
            (staging / "catalog.json.sig").write_text(
                signature + "\n", encoding="ascii"
            )
            os.chmod(staging / "catalog.json.sig", 0o644)
        (staging / "catalog.json.sha256").write_text(
            sha256(catalog_path) + "\n", encoding="ascii"
        )
        os.chmod(staging / "catalog.json.sha256", 0o644)
        publish(staging, output)
        staging = None
    finally:
        if staging is not None and staging.exists():
            remove_private_build_directory(staging, output.parent)


if __name__ == "__main__":
    main()
