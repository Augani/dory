#!/usr/bin/env python3
"""Fail closed on new source debt or any QEMU identity in a shipping artifact."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter
from pathlib import Path


SOURCE_PATTERNS = {
    "persisted-identity": re.compile(rb"qemu-hvf|qemuHypervisorFramework"),
    "executable-or-helper": re.compile(
        rb"qemu-(?:system|img|aarch64|x86_64)(?:-static)?"
    ),
    "control-protocol": re.compile(rb"listen-qemu|GVProxyQEMU"),
}
ARTIFACT_PATTERN = re.compile(rb"qemu", re.IGNORECASE)
SOURCE_ROOTS = (
    "Config",
    "Dory",
    "Packages/ContainerizationEngine/Sources",
    "dory-core-swift/Sources",
    "dory-core",
    "scripts/build-components.py",
    "scripts/bundle-engine.sh",
    "scripts/runtime",
    ".github/workflows",
)


class AuditFailure(RuntimeError):
    pass


def regular_files(root: Path) -> list[Path]:
    if root.is_symlink():
        raise AuditFailure(f"indirect audit root is forbidden: {root}")
    if root.is_file():
        return [root]
    if not root.is_dir():
        return []
    result: list[Path] = []
    for directory, names, filenames in os.walk(root, followlinks=False):
        names[:] = sorted(name for name in names if name not in {".build", "Tests"})
        for filename in sorted(filenames):
            path = Path(directory) / filename
            if path.is_symlink() or filename.endswith("Tests.swift"):
                continue
            result.append(path)
    return result


def load_debt(path: Path) -> dict[tuple[str, str], int]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AuditFailure(f"cannot read debt manifest {path}: {error}") from error
    if document.get("schemaVersion") != 1 or not isinstance(document.get("entries"), list):
        raise AuditFailure("debt manifest must use schemaVersion 1 and an entries array")
    allowed: dict[tuple[str, str], int] = {}
    for index, entry in enumerate(document["entries"]):
        if not isinstance(entry, dict) or set(entry) != {
            "category", "path", "maximumOccurrences", "disposition"
        }:
            raise AuditFailure(f"debt entry {index} has an invalid schema")
        category = entry["category"]
        relative = entry["path"]
        maximum = entry["maximumOccurrences"]
        disposition = entry["disposition"]
        if category not in SOURCE_PATTERNS:
            raise AuditFailure(f"debt entry {index} has an unknown category")
        if not isinstance(relative, str) or relative.startswith(("/", "../")):
            raise AuditFailure(f"debt entry {index} has an unsafe path")
        if not isinstance(maximum, int) or isinstance(maximum, bool) or maximum < 1:
            raise AuditFailure(f"debt entry {index} has an invalid occurrence ceiling")
        if not isinstance(disposition, str) or not disposition.strip():
            raise AuditFailure(f"debt entry {index} has no removal disposition")
        key = (category, relative)
        if key in allowed:
            raise AuditFailure(f"duplicate debt entry for {category}: {relative}")
        allowed[key] = maximum
    return allowed


def audit_source(repository: Path, debt_path: Path) -> None:
    repository = repository.resolve(strict=True)
    allowed = load_debt(debt_path)
    observed: Counter[tuple[str, str]] = Counter()
    for relative_root in SOURCE_ROOTS:
        for path in regular_files(repository / relative_root):
            try:
                payload = path.read_bytes()
            except OSError as error:
                raise AuditFailure(f"cannot read production source {path}: {error}") from error
            relative = path.relative_to(repository).as_posix()
            for category, pattern in SOURCE_PATTERNS.items():
                count = len(pattern.findall(payload))
                if count:
                    observed[(category, relative)] += count

    violations: list[str] = []
    for key, count in sorted(observed.items()):
        maximum = allowed.get(key)
        if maximum is None:
            violations.append(f"new {key[0]} surface ({count}) in {key[1]}")
        elif count > maximum:
            violations.append(
                f"{key[0]} debt grew from ceiling {maximum} to {count} in {key[1]}"
            )
    if violations:
        raise AuditFailure("source audit failed:\n- " + "\n- ".join(violations))

    remaining = sum(observed.values())
    print(f"no-QEMU source audit: PASS ({remaining} inventoried Phase 0B removals; no growth)")


def audit_artifact(root: Path) -> None:
    root = root.resolve(strict=True)
    violations: list[str] = []
    for path in regular_files(root):
        relative = path.relative_to(root).as_posix()
        if ARTIFACT_PATTERN.search(relative.encode("utf-8", errors="surrogateescape")):
            violations.append(f"forbidden artifact path: {relative}")
            continue
        try:
            payload = path.read_bytes()
        except OSError as error:
            raise AuditFailure(f"cannot read artifact {path}: {error}") from error
        if ARTIFACT_PATTERN.search(payload):
            violations.append(f"forbidden artifact content: {relative}")
    if violations:
        raise AuditFailure("artifact audit failed:\n- " + "\n- ".join(violations[:50]))
    print(f"no-QEMU artifact audit: PASS ({root})")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", type=Path, default=Path("."))
    parser.add_argument(
        "--debt-manifest",
        type=Path,
        default=Path("docs/virtualization/no-qemu-source-debt.json"),
    )
    parser.add_argument("--artifact-root", type=Path)
    arguments = parser.parse_args()
    try:
        if arguments.artifact_root is not None:
            audit_artifact(arguments.artifact_root)
        else:
            audit_source(arguments.repository, arguments.debt_manifest)
    except (AuditFailure, OSError) as error:
        print(f"no-QEMU audit: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
