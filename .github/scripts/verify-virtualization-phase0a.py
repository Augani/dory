#!/usr/bin/env python3
"""Validate the binding Phase 0A ADR set and repository workstream map."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


ADR_HEADING = re.compile(r"^## (ADR-(\d{3})) — (.+)$", re.MULTILINE)
REQUIRED_FIELDS = (
    "Status",
    "Decision",
    "Owners",
    "Dependencies",
    "Test strategy",
    "Exit gate",
)
EXPECTED_AREAS = {
    "Packages/ContainerizationEngine",
    "New DoryDBT packages",
    "New machine packages",
    "New firmware package/tooling",
    "dory-core-swift/Sources/DoryOperations",
    "dory-core-swift/Sources/DoryVMMKit",
    "Media/image tooling",
    "DoryDesktopExperience/CLI",
    "Components/release/tests/qualification/documentation",
}


class ValidationFailure(RuntimeError):
    pass


def nonempty_strings(value: object, label: str) -> list[str]:
    if not isinstance(value, list) or not value:
        raise ValidationFailure(f"{label} must be a non-empty array")
    if not all(isinstance(item, str) and item.strip() for item in value):
        raise ValidationFailure(f"{label} must contain non-empty strings")
    return value


def validate(adr_path: Path, program_path: Path) -> None:
    text = adr_path.read_text(encoding="utf-8")
    matches = list(ADR_HEADING.finditer(text))
    expected_ids = [f"ADR-{number:03d}" for number in range(1, 27)]
    actual_ids = [match.group(1) for match in matches]
    if actual_ids != expected_ids:
        raise ValidationFailure(f"ADR sequence differs: {actual_ids!r}")
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        body = text[match.end():end]
        for field in REQUIRED_FIELDS:
            field_match = re.search(
                rf"^- \*\*{re.escape(field)}:\*\*\s+(.+)$", body, re.MULTILINE
            )
            if field_match is None or not field_match.group(1).strip():
                raise ValidationFailure(f"{match.group(1)} is missing {field}")

    document = json.loads(program_path.read_text(encoding="utf-8"))
    if set(document) != {
        "schemaVersion", "charter", "phase", "status", "hostBoundary",
        "workstreams", "stopGates",
    }:
        raise ValidationFailure("program manifest has unexpected top-level fields")
    if document["schemaVersion"] != 1 or document["phase"] != "0A":
        raise ValidationFailure("program manifest identity is invalid")
    if document["status"] != "in-progress":
        raise ValidationFailure("Phase 0A must remain in-progress while stop gates are open")
    if document["hostBoundary"] != "apple-silicon-only":
        raise ValidationFailure("host boundary must remain Apple-silicon-only")
    workstreams = document["workstreams"]
    if not isinstance(workstreams, list) or len(workstreams) != len(EXPECTED_AREAS):
        raise ValidationFailure("program manifest must map all nine repository rows")
    areas: set[str] = set()
    covered: set[str] = set()
    for index, workstream in enumerate(workstreams):
        if not isinstance(workstream, dict) or set(workstream) != {
            "area", "adrs", "owners", "testStrategy", "exitGate", "dependencies"
        }:
            raise ValidationFailure(f"workstream {index} schema is invalid")
        area = workstream["area"]
        if not isinstance(area, str) or area in areas:
            raise ValidationFailure(f"workstream {index} area is invalid or duplicated")
        areas.add(area)
        adrs = nonempty_strings(workstream["adrs"], f"workstream {index} ADRs")
        if any(adr not in expected_ids for adr in adrs):
            raise ValidationFailure(f"workstream {index} references an unknown ADR")
        covered.update(adrs)
        nonempty_strings(workstream["owners"], f"workstream {index} owners")
        nonempty_strings(workstream["dependencies"], f"workstream {index} dependencies")
        for field in ("testStrategy", "exitGate"):
            if not isinstance(workstream[field], str) or not workstream[field].strip():
                raise ValidationFailure(f"workstream {index} has no {field}")
    if areas != EXPECTED_AREAS:
        raise ValidationFailure(f"repository workstream map differs: {areas!r}")
    missing = set(expected_ids) - covered
    if missing:
        raise ValidationFailure(f"ADRs are not owned by a repository workstream: {sorted(missing)}")
    if len(nonempty_strings(document["stopGates"], "stop gates")) < 5:
        raise ValidationFailure("Phase 0A stop-gate inventory is incomplete")
    print("virtualization Phase 0A records: PASS (26 ADRs, 9 workstreams, open gates retained)")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--adrs",
        type=Path,
        default=Path("docs/virtualization/phase-0a-decision-records.md"),
    )
    parser.add_argument(
        "--program",
        type=Path,
        default=Path("docs/virtualization/phase-0a-program.json"),
    )
    arguments = parser.parse_args()
    try:
        validate(arguments.adrs, arguments.program)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValidationFailure) as error:
        print(f"virtualization Phase 0A records: FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
