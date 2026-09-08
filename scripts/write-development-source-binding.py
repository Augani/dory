#!/usr/bin/env python3
"""Create or verify the source snapshot sealed into a development Dory app.

Release provenance is deliberately stricter and lives in the release workflow.  This
tool gives a locally signed development app an equally explicit *local* source
binding: every tracked and non-ignored untracked source entry is hashed at the
start of compilation. Assembly verifies that snapshot again.  A later source edit makes verification fail.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess
import sys
from typing import Any


KIND = "dev.dory.development-source-binding"
SCHEMA_VERSION = 1
# Evidence is an output of qualification, not an application source input.  In
# particular, the candidate inventory is written after the app has been signed;
# including its bytes here would immediately invalidate an otherwise matching
# development candidate.  Keep this exception narrowly scoped so ordinary
# untracked source changes remain observable.
GENERATED_OUTPUT_PREFIXES = (("docs", "virtualization", "evidence"),)


class SourceBindingError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise SourceBindingError(f"development source binding: {message}")


def direct_regular(path: Path) -> bool:
    return path.is_file() and not path.is_symlink()


def run_git(root: Path, *arguments: str) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(root), *arguments],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        fail(detail or f"git {' '.join(arguments)} failed")
    return result.stdout


def git_paths(root: Path, *arguments: str) -> list[str]:
    raw = run_git(root, *arguments)
    if raw and not raw.endswith(b"\0"):
        fail("git path output is not NUL-delimited")
    values = [item.decode("utf-8", errors="strict") for item in raw.split(b"\0") if item]
    if len(set(values)) != len(values):
        fail("git returned a duplicate source path")
    return values


def checked_relative_path(value: str) -> str:
    path = PurePosixPath(value)
    if not value or path.is_absolute() or ".." in path.parts or path == PurePosixPath("."):
        fail(f"git returned an unsafe source path: {value!r}")
    return path.as_posix()


def is_generated_output_path(value: str) -> bool:
    parts = PurePosixPath(checked_relative_path(value)).parts
    return any(parts[:len(prefix)] == prefix for prefix in GENERATED_OUTPUT_PREFIXES)


def selected_git_paths(root: Path) -> tuple[list[str], list[str]]:
    tracked = [
        path for path in git_paths(root, "ls-files", "-z")
        if not is_generated_output_path(path)
    ]
    untracked = [
        path for path in git_paths(root, "ls-files", "--others", "--exclude-standard", "-z")
        if not is_generated_output_path(path)
    ]
    return tracked, untracked


def source_worktree_status(root: Path, untracked: list[str]) -> tuple[bool, bytes]:
    """Return a source-only dirty bit and stable status record.

    ``git status`` is intentionally not used directly: its untracked output
    includes qualification receipts, which are excluded above.  Git's binary
    diff covers tracked source modifications; selected untracked source names
    complete the dirty-state description.
    """
    tracked_diff = run_git(
        root,
        "diff", "--binary", "--no-ext-diff", "HEAD", "--", ".",
        ":(exclude)docs/virtualization/evidence/**",
    )
    record = {
        "trackedDiffSHA256": sha256_bytes(tracked_diff),
        "untrackedPaths": untracked,
    }
    return bool(tracked_diff) or bool(untracked), canonical_json(record)


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_entry(root: Path, relative: str, tracking: str) -> dict[str, str]:
    safe_relative = checked_relative_path(relative)
    path = root / safe_relative
    try:
        metadata = path.lstat()
    except OSError as error:
        fail(f"cannot inspect {safe_relative}: {error}")
    if stat.S_ISREG(metadata.st_mode):
        kind = "regular"
        digest = sha256_file(path)
    elif stat.S_ISLNK(metadata.st_mode):
        kind = "symlink"
        digest = sha256_bytes(os.fsencode(os.readlink(path)))
    else:
        fail(f"source entry is neither a regular file nor a symbolic link: {safe_relative}")
    return {
        "path": safe_relative,
        "kind": kind,
        "sha256": digest,
        "tracking": tracking,
        "mode": stat.S_IMODE(metadata.st_mode),
    }


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def source_snapshot(root: Path) -> dict[str, Any]:
    root = root.resolve()
    if not root.is_dir() or root.is_symlink():
        fail(f"source root must be a direct directory: {root}")
    if run_git(root, "rev-parse", "--is-inside-work-tree").strip() != b"true":
        fail("source root is not a Git worktree")

    before_commit = run_git(root, "rev-parse", "HEAD").decode("ascii", errors="strict").strip()
    tracked, untracked = selected_git_paths(root)
    before_dirty, before_status = source_worktree_status(root, untracked)
    overlap = set(tracked) & set(untracked)
    if overlap:
        fail(f"source path is both tracked and untracked: {sorted(overlap)[0]}")
    entries = [
        source_entry(root, path, "tracked") for path in tracked
    ] + [
        source_entry(root, path, "untracked") for path in untracked
    ]
    entries.sort(key=lambda entry: entry["path"])
    if len({entry["path"] for entry in entries}) != len(entries):
        fail("source snapshot contains a duplicate path")

    after_commit = run_git(root, "rev-parse", "HEAD").decode("ascii", errors="strict").strip()
    after_tracked, after_untracked = selected_git_paths(root)
    after_dirty, after_status = source_worktree_status(root, after_untracked)
    if (
        before_commit != after_commit
        or before_status != after_status
        or tracked != after_tracked
        or untracked != after_untracked
        or before_dirty != after_dirty
    ):
        fail("source changed while the snapshot was being collected; retry the build")
    if len(before_commit) != 40 or any(character not in "0123456789abcdef" for character in before_commit):
        fail("Git HEAD is not a full lowercase SHA-1 commit")
    return {
        "git": {
            "headCommit": before_commit,
            "worktreeDirty": before_dirty,
            "worktreeStatusSHA256": sha256_bytes(before_status),
        },
        "sourceTree": {
            "entryCount": len(entries),
            "sha256": sha256_bytes(canonical_json(entries)),
        },
        "entries": entries,
    }


def binding(root: Path) -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "kind": KIND,
        "releaseQualified": False,
        **source_snapshot(root),
    }


def read_binding(path: Path) -> dict[str, Any]:
    if not direct_regular(path):
        fail(f"binding must be a direct regular file: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot parse binding {path}: {error}")
    if not isinstance(value, dict) or value.get("schemaVersion") != SCHEMA_VERSION or value.get("kind") != KIND:
        fail(f"binding has the wrong schema or kind: {path}")
    if value.get("releaseQualified") is not False:
        fail("a development source binding must not claim release qualification")
    git = value.get("git")
    if not isinstance(git, dict) or set(git) != {"headCommit", "worktreeDirty", "worktreeStatusSHA256"}:
        fail("binding has invalid captured Git metadata")
    for field, size in (("headCommit", 40), ("worktreeStatusSHA256", 64)):
        text = git.get(field)
        if not isinstance(text, str) or len(text) != size or any(c not in "0123456789abcdef" for c in text):
            fail("binding has invalid captured Git metadata")
    if type(git.get("worktreeDirty")) is not bool:
        fail("binding has invalid captured Git metadata")
    return value


def write_binding(path: Path, value: dict[str, Any]) -> None:
    if path.is_symlink():
        fail(f"output must not be a symbolic link: {path}")
    if path.parent.exists() and (not path.parent.is_dir() or path.parent.is_symlink()):
        fail(f"output parent must be a direct directory: {path.parent}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(json.dumps(value, sort_keys=True, indent=2, ensure_ascii=False).encode("utf-8") + b"\n")
    path.chmod(0o644)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("create", "verify", "verify-sources"))
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--binding", type=Path)
    arguments = parser.parse_args()
    root = arguments.source_root.resolve()
    if arguments.operation == "create":
        if arguments.output is None or arguments.binding is not None:
            fail("create requires --output and does not accept --binding")
        write_binding(arguments.output.absolute(), binding(root))
        return 0
    if arguments.binding is None or arguments.output is not None:
        fail("verify requires --binding and does not accept --output")
    actual = read_binding(arguments.binding.absolute())
    expected = binding(root)
    # Assembly uses strict `verify`. Post-build inventory may compare the exact
    # entries while retaining the original Git metadata as capture-time history.
    # Committing excluded evidence must not relabel or invalidate identical bytes.
    comparison_actual = actual
    comparison_expected = expected
    if arguments.operation == "verify-sources":
        comparison_actual = {key: value for key, value in actual.items() if key != "git"}
        comparison_expected = {key: value for key, value in expected.items() if key != "git"}
    if comparison_actual != comparison_expected:
        fail("binding does not match the current complete source snapshot")
    print(f"verified development source binding {actual['sourceTree']['sha256']}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SourceBindingError as error:
        raise SystemExit(str(error))
