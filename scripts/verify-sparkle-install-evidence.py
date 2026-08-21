#!/usr/bin/env python3
"""Bind retained Sparkle installation evidence to one immutable release candidate."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import sys


SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
RUN_ID_PATTERN = re.compile(r"[0-9]{8}T[0-9]{6}Z-[1-9][0-9]*")
TEAM_ID_PATTERN = re.compile(r"[A-Z0-9]{10}")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=pathlib.Path)
    parser.add_argument("--app-update", required=True, type=pathlib.Path)
    parser.add_argument("--appcast", required=True, type=pathlib.Path)
    parser.add_argument("--release-manifest", required=True, type=pathlib.Path)
    parser.add_argument("--sbom", required=True, type=pathlib.Path)
    parser.add_argument("--gate-script", required=True, type=pathlib.Path)
    parser.add_argument("--package-resolved", required=True, type=pathlib.Path)
    parser.add_argument("--candidate-team", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--run-attempt", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True, type=int)
    return parser.parse_args()


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def direct_file(path: pathlib.Path, label: str, maximum_bytes: int | None = None) -> pathlib.Path:
    logical = pathlib.Path(os.path.abspath(path))
    require(logical.is_file() and not logical.is_symlink(), f"{label} is missing or indirect")
    require(logical.resolve() == logical, f"{label} has an indirect ancestor")
    if maximum_bytes is not None:
        require(logical.stat().st_size <= maximum_bytes, f"{label} is too large")
    return logical


def unique_json_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: pathlib.Path) -> object:
    with path.open("rb") as handle:
        return json.load(handle, object_pairs_hook=unique_json_object)


def read_evidence(path: pathlib.Path) -> dict[str, str]:
    values: dict[str, str] = {}
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            key, separator, value = line.rstrip("\n").partition("=")
            if not separator or not key or key in values:
                raise ValueError(f"malformed Sparkle evidence: {line!r}")
            values[key] = value
    return values


def candidate_tree_digest(path: pathlib.Path) -> str:
    payload = load_json(path)
    values = [
        row["value"]
        for row in payload["metadata"]["component"]["properties"]
        if row["name"] == "dev.dory.app.tree.sha256"
    ]
    if len(values) != 1 or SHA256_PATTERN.fullmatch(values[0]) is None:
        raise ValueError("SBOM must contain one valid Dory app tree digest")
    return values[0]


def sparkle_revision(path: pathlib.Path) -> str:
    payload = load_json(path)
    pins = [pin for pin in payload["pins"] if pin["identity"] == "sparkle"]
    if len(pins) != 1 or pins[0]["state"].get("version") != "2.9.4":
        raise ValueError("Package.resolved must contain exactly one Sparkle 2.9.4 pin")
    revision = pins[0]["state"].get("revision", "")
    if re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        raise ValueError("Sparkle pin has no full lowercase revision")
    return revision


def require_positive_integer(values: dict[str, str], key: str) -> None:
    value = values[key]
    if not value.isdigit() or int(value) <= 0:
        raise ValueError(f"invalid positive integer in Sparkle evidence: {key}")


def verify(arguments: argparse.Namespace) -> None:
    arguments.manifest = direct_file(arguments.manifest, "Sparkle evidence manifest", 64 * 1024)
    arguments.app_update = direct_file(arguments.app_update, "Sparkle update archive")
    arguments.appcast = direct_file(arguments.appcast, "Sparkle appcast", 2 * 1024 * 1024)
    arguments.release_manifest = direct_file(arguments.release_manifest, "release manifest", 2 * 1024 * 1024)
    arguments.sbom = direct_file(arguments.sbom, "release SBOM", 64 * 1024 * 1024)
    arguments.gate_script = direct_file(arguments.gate_script, "Sparkle gate script", 2 * 1024 * 1024)
    arguments.package_resolved = direct_file(arguments.package_resolved, "Package.resolved", 2 * 1024 * 1024)
    if arguments.build <= 1:
        raise ValueError("Sparkle qualification requires a build greater than one")
    if re.fullmatch(r"[0-9a-f]{40}", arguments.source_commit) is None:
        raise ValueError("source commit must be a full lowercase Git SHA")
    if TEAM_ID_PATTERN.fullmatch(arguments.candidate_team) is None:
        raise ValueError("candidate team must be a ten-character Apple Team ID")
    if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?", arguments.version) is None:
        raise ValueError("candidate version is invalid")
    if not arguments.run_id.isdigit() or int(arguments.run_id) <= 0 \
            or not arguments.run_attempt.isdigit() or int(arguments.run_attempt) <= 0:
        raise ValueError("workflow run identity is invalid")

    values = read_evidence(arguments.manifest)
    pass_keys = {
        "old_process_terminated",
        "different_relaunch_pid",
        "loopback_appcast_fetched",
        "exact_update_archive_fetched",
        "ed25519_archive_verified",
        "installed_tree_exact",
        "installed_notarization_ticket",
        "installed_gatekeeper",
        "application_support_preserved",
        "preferences_preserved",
        "atomic_install_swap",
        "sparkle_fallback_restoration_verified",
        "qualification_fixture_restored",
        "initial_clean_user_state_restored",
    }
    expected = {
        "status": "PASS",
        "release_qualifying": "true",
        "workflow_run_id": arguments.run_id,
        "workflow_run_attempt": arguments.run_attempt,
        "source_commit": arguments.source_commit,
        "candidate_version": arguments.version,
        "candidate_build": str(arguments.build),
        "previous_fixture_build": str(arguments.build - 1),
        "candidate_tree_sha256": candidate_tree_digest(arguments.sbom),
        "update_zip_sha256": sha256(arguments.app_update),
        "appcast_sha256": sha256(arguments.appcast),
        "release_manifest_sha256": sha256(arguments.release_manifest),
        "sbom_sha256": sha256(arguments.sbom),
        "gate_script_sha256": sha256(arguments.gate_script),
        "sparkle_version": "2.9.4",
        "sparkle_revision": sparkle_revision(arguments.package_resolved),
        "candidate_team": arguments.candidate_team,
        "sparkle_cli_team": arguments.candidate_team,
        "sparkle_autoupdate_team": arguments.candidate_team,
        **{key: "PASS" for key in pass_keys},
    }
    for key, expected_value in expected.items():
        if values.get(key) != expected_value:
            raise ValueError(
                f"Sparkle evidence mismatch for {key}: "
                f"{values.get(key)!r} != {expected_value!r}"
            )

    dynamic_keys = {
        "run_id",
        "sparkle_cli_sha256",
        "sparkle_framework_sha256",
        "old_pid",
        "relaunched_pid",
        "completed_epoch",
    }
    expected_keys = set(expected) | dynamic_keys
    if set(values) != expected_keys:
        difference = sorted(set(values) ^ expected_keys)
        raise ValueError(f"unexpected Sparkle evidence keys: {difference}")
    if RUN_ID_PATTERN.fullmatch(values["run_id"]) is None:
        raise ValueError("Sparkle evidence has an invalid qualification run identifier")
    for key in ("sparkle_cli_sha256", "sparkle_framework_sha256"):
        if SHA256_PATTERN.fullmatch(values[key]) is None:
            raise ValueError(f"invalid Sparkle evidence digest: {key}")
    for key in ("old_pid", "relaunched_pid", "completed_epoch"):
        require_positive_integer(values, key)
    if values["old_pid"] == values["relaunched_pid"]:
        raise ValueError("Sparkle evidence reused the previous app PID")


def main() -> int:
    arguments = parse_arguments()
    try:
        verify(arguments)
    except (KeyError, OSError, TypeError, ValueError) as error:
        print(f"Sparkle install evidence error: {error}", file=sys.stderr)
        return 1
    print("Sparkle install evidence: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
