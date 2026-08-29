#!/usr/bin/env python3
"""Build the small, signed in-place update payload shipped beside each desktop rootfs."""

from __future__ import annotations

import argparse
import hashlib
import os
import pathlib
import shutil
import stat
import tarfile
import tempfile


def digest(path: pathlib.Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            value.update(chunk)
    return value.hexdigest()


def add_path(archive: tarfile.TarFile, source: pathlib.Path, name: str) -> None:
    info = source.lstat()
    if stat.S_ISLNK(info.st_mode):
        raise SystemExit(f"desktop update payload refuses symlink: {source}")
    if not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
        raise SystemExit(f"desktop update payload refuses special file: {source}")
    tar_info = archive.gettarinfo(str(source), arcname=name)
    tar_info.uid = 0
    tar_info.gid = 0
    tar_info.uname = "root"
    tar_info.gname = "root"
    tar_info.mtime = 0
    if source.is_dir():
        archive.addfile(tar_info)
    else:
        with source.open("rb") as contents:
            archive.addfile(tar_info, contents)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--distro", choices=("debian", "ubuntu", "kali"), required=True)
    parser.add_argument("--fingerprint", required=True)
    parser.add_argument("--packages", type=pathlib.Path, required=True)
    parser.add_argument("--overlay", type=pathlib.Path, required=True)
    parser.add_argument("--agent", type=pathlib.Path, required=True)
    parser.add_argument("--venus-runtime", type=pathlib.Path, required=True)
    parser.add_argument("--graphics-installer", type=pathlib.Path, required=True)
    parser.add_argument("--apply", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if len(args.fingerprint) != 64 or any(c not in "0123456789abcdef" for c in args.fingerprint):
        raise SystemExit("desktop update fingerprint must be a lowercase SHA-256 digest")
    for path in (
        args.packages,
        args.agent,
        args.venus_runtime,
        args.graphics_installer,
        args.apply,
    ):
        if not path.is_file() or path.is_symlink() or path.stat().st_size == 0:
            raise SystemExit(f"desktop update input is invalid: {path}")
    if not args.overlay.is_dir() or args.overlay.is_symlink():
        raise SystemExit(f"desktop update overlay is invalid: {args.overlay}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="dory-desktop-update-") as temporary:
        staging = pathlib.Path(temporary)
        shutil.copy2(args.apply, staging / "apply.sh")
        shutil.copy2(args.agent, staging / "dory-agent")
        shutil.copy2(args.venus_runtime, staging / "dory-mesa-venus-arm64.tar.zst")
        shutil.copy2(args.graphics_installer, staging / "install-graphics-pack.sh")
        shutil.copy2(args.packages, staging / "packages.txt")
        (staging / "manifest.env").write_text(
            f"schema=2\narch=arm64\ndistro={args.distro}\ninput_sha256={args.fingerprint}\n",
            encoding="utf-8",
        )
        os.chmod(staging / "apply.sh", 0o755)
        os.chmod(staging / "dory-agent", 0o755)
        os.chmod(staging / "install-graphics-pack.sh", 0o755)

        overlay_tar = staging / "rootfs-overlay.tar"
        with tarfile.open(overlay_tar, "w", format=tarfile.PAX_FORMAT) as archive:
            add_path(archive, args.overlay, ".")
            for source in sorted(args.overlay.rglob("*")):
                add_path(archive, source, source.relative_to(args.overlay).as_posix())

        payloads = [
            "apply.sh",
            "dory-agent",
            "dory-mesa-venus-arm64.tar.zst",
            "manifest.env",
            "install-graphics-pack.sh",
            "packages.txt",
            "rootfs-overlay.tar",
        ]
        (staging / "SHA256SUMS").write_text(
            "".join(f"{digest(staging / name)}  {name}\n" for name in payloads),
            encoding="utf-8",
        )
        temporary_output = args.output.with_name(f".{args.output.name}.tmp-{os.getpid()}")
        try:
            with tarfile.open(temporary_output, "w", format=tarfile.PAX_FORMAT) as archive:
                for name in [*payloads, "SHA256SUMS"]:
                    add_path(archive, staging / name, name)
            os.replace(temporary_output, args.output)
        finally:
            temporary_output.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
