#!/usr/bin/env python3
"""Generate a deterministic CycloneDX inventory for the exact shipped Dory.app tree."""

import argparse
import hashlib
import json
import os
import pathlib
import stat
import tempfile
import urllib.parse
import uuid


def digest_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def snapshot(metadata: os.stat_result) -> tuple[int, int, int, int, int, int]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def digest_file(path: pathlib.Path) -> tuple[str, os.stat_result]:
    flags = os.O_RDONLY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise ValueError(f"release app entry is not a regular file: {path}")
        value = hashlib.sha256()
        while chunk := os.read(descriptor, 1024 * 1024):
            value.update(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    current = path.lstat()
    if snapshot(before) != snapshot(after) or snapshot(after) != snapshot(current):
        raise ValueError(f"release app file changed while it was inventoried: {path}")
    return value.hexdigest(), current


def symlink_snapshot(path: pathlib.Path, app_root: pathlib.Path) -> tuple[str, int, os.stat_result]:
    before = path.lstat()
    target = os.readlink(path)
    after = path.lstat()
    if snapshot(before) != snapshot(after):
        raise ValueError(f"release app symlink changed while it was inventoried: {path}")
    if pathlib.PurePosixPath(target).is_absolute():
        raise ValueError(f"release app contains an absolute symlink: {path}")
    try:
        resolved = (path.parent / target).resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise ValueError(f"release app contains an unresolved symlink: {path}") from error
    if resolved != app_root and app_root not in resolved.parents:
        raise ValueError(f"release app symlink escapes Dory.app: {path}")
    try:
        encoded = target.encode("utf-8")
    except UnicodeError as error:
        raise ValueError(f"release app symlink is not portable UTF-8: {path}") from error
    return digest_bytes(encoded), len(encoded), after


def app_entries(app: pathlib.Path) -> list[pathlib.Path]:
    result: list[pathlib.Path] = []

    def visit(directory: pathlib.Path) -> None:
        with os.scandir(directory) as entries:
            ordered = sorted(entries, key=lambda entry: entry.name.encode("utf-8"))
        for entry in ordered:
            path = pathlib.Path(entry.path)
            metadata = entry.stat(follow_symlinks=False)
            if stat.S_ISDIR(metadata.st_mode):
                visit(path)
            elif stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
                result.append(path)
            else:
                raise ValueError(f"release app contains unsupported filesystem entry: {path}")

    visit(app)
    return result


def inventory(app: pathlib.Path) -> tuple[list[dict[str, object]], str]:
    root_metadata = app.lstat()
    if app.name != "Dory.app" or not stat.S_ISDIR(root_metadata.st_mode):
        raise ValueError(f"exact non-symlink Dory.app is missing: {app}")
    app = app.resolve(strict=True)
    components: list[dict[str, object]] = []
    tree = hashlib.sha256()
    for path in app_entries(app):
        relative = path.relative_to(app.parent).as_posix()
        metadata = path.lstat()
        if stat.S_ISREG(metadata.st_mode):
            kind = "regular"
            sha256, metadata = digest_file(path)
            size = metadata.st_size
        elif stat.S_ISLNK(metadata.st_mode):
            kind = "symlink"
            sha256, size, metadata = symlink_snapshot(path, app)
        else:
            raise ValueError(f"release app entry changed type while it was inventoried: {path}")
        mode = f"{stat.S_IMODE(metadata.st_mode):04o}"
        bom_ref = "dory-file:" + urllib.parse.quote(relative, safe="/._-")
        components.append(
            {
                "type": "file",
                "bom-ref": bom_ref,
                "name": relative,
                "hashes": [{"alg": "SHA-256", "content": sha256}],
                "properties": [
                    {"name": "dev.dory.file.type", "value": kind},
                    {"name": "dev.dory.file.mode", "value": mode},
                    {"name": "dev.dory.file.size", "value": str(size)},
                ],
            }
        )
        tree.update(f"{relative}\0{kind}\0{mode}\0{size}\0{sha256}\n".encode())
    return components, tree.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=pathlib.Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()
    if len(args.source_commit) != 40 or any(char not in "0123456789abcdef" for char in args.source_commit):
        raise SystemExit("source commit must be a full lowercase Git SHA")

    components, tree_sha256 = inventory(args.app)
    if not components:
        raise SystemExit("Dory.app inventory is empty")
    root_ref = f"pkg:github/Augani/dory@{args.version}?commit={args.source_commit}"
    serial = uuid.uuid5(uuid.NAMESPACE_URL, f"{root_ref}#{tree_sha256}")
    document = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "serialNumber": f"urn:uuid:{serial}",
        "version": 1,
        "metadata": {
            "component": {
                "type": "application",
                "bom-ref": root_ref,
                "group": "Augani",
                "name": "Dory",
                "version": args.version,
                "licenses": [{"license": {"id": "GPL-3.0-only"}}],
                "properties": [
                    {"name": "dev.dory.source.commit", "value": args.source_commit},
                    {"name": "dev.dory.app.tree.sha256", "value": tree_sha256},
                    {"name": "dev.dory.inventory.scope", "value": "exact-shipped-app-files"},
                ],
            }
        },
        "components": components,
        "dependencies": [{"ref": root_ref, "dependsOn": [item["bom-ref"] for item in components]}],
    }
    output = args.output.resolve()
    app_root = args.app.resolve(strict=True)
    if output == app_root or app_root in output.parents:
        raise SystemExit("SBOM output must remain outside Dory.app")
    output.parent.mkdir(parents=True, exist_ok=True)
    payload = (json.dumps(document, indent=2, sort_keys=True) + "\n").encode("utf-8")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{output.name}.tmp-", dir=output.parent)
    temporary = pathlib.Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o644)
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, output)
        directory_descriptor = os.open(output.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    finally:
        if temporary.exists():
            temporary.unlink()


if __name__ == "__main__":
    try:
        main()
    except (OSError, UnicodeError, ValueError) as error:
        raise SystemExit(f"release SBOM generation error: {error}") from error
