#!/usr/bin/env python3
"""Verify that a Dory CycloneDX SBOM is an exact, portable app-tree inventory."""

import argparse
import importlib.util
import json
import pathlib
import re
import uuid

generator_path = pathlib.Path(__file__).with_name("generate-release-sbom.py")
generator_spec = importlib.util.spec_from_file_location("generate_release_sbom", generator_path)
if generator_spec is None or generator_spec.loader is None:
    raise RuntimeError("cannot load release SBOM generator")
generator = importlib.util.module_from_spec(generator_spec)
generator_spec.loader.exec_module(generator)

DOCUMENT_KEYS = {
    "bomFormat",
    "specVersion",
    "serialNumber",
    "version",
    "metadata",
    "components",
    "dependencies",
}


def unique_json_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"SBOM contains duplicate JSON key: {key}")
        result[key] = value
    return result


def exact_object(value: object, keys: set[str], label: str) -> dict:
    if not isinstance(value, dict) or set(value) != keys:
        raise ValueError(f"{label} shape is invalid")
    return value


def properties(rows: object) -> dict[str, str]:
    if not isinstance(rows, list):
        raise ValueError("SBOM properties are malformed")
    result: dict[str, str] = {}
    for row in rows:
        if not isinstance(row, dict) or set(row) != {"name", "value"} or row["name"] in result:
            raise ValueError("SBOM property is malformed or duplicated")
        result[str(row["name"])] = str(row["value"])
    return result


def leaks_runner_local_path(serialized: str, app: pathlib.Path) -> bool:
    app_parent_root = app.resolve().parent.parent
    filesystem_root = pathlib.Path(app_parent_root.anchor)
    leaks_app_parent = app_parent_root != filesystem_root and str(app_parent_root) in serialized
    return leaks_app_parent or "/Users/" in serialized


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sbom", required=True, type=pathlib.Path)
    parser.add_argument("--app", required=True, type=pathlib.Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-commit", required=True)
    args = parser.parse_args()
    if re.fullmatch(r"[0-9a-f]{40}", args.source_commit) is None:
        raise ValueError("source commit must be a full lowercase Git SHA")
    serialized = args.sbom.read_text(encoding="utf-8")
    document = json.loads(serialized, object_pairs_hook=unique_json_object)
    exact_object(document, DOCUMENT_KEYS, "release SBOM")
    if document.get("bomFormat") != "CycloneDX" or document.get("specVersion") != "1.6":
        raise ValueError("release SBOM is not CycloneDX 1.6")
    if document.get("version") != 1:
        raise ValueError("release SBOM identity is malformed")
    expected_components, tree_sha256 = generator.inventory(args.app)
    if document.get("components") != expected_components:
        raise ValueError("release SBOM does not exactly inventory the shipped app tree")
    metadata = exact_object(document["metadata"], {"component"}, "release SBOM metadata")
    root = exact_object(
        metadata["component"],
        {"type", "bom-ref", "group", "name", "version", "licenses", "properties"},
        "release SBOM root component",
    )
    root_ref = f"pkg:github/Augani/dory@{args.version}?commit={args.source_commit}"
    expected_serial = f"urn:uuid:{uuid.uuid5(uuid.NAMESPACE_URL, f'{root_ref}#{tree_sha256}')}"
    if document["serialNumber"] != expected_serial:
        raise ValueError("release SBOM deterministic identity mismatch")
    if root.get("type") != "application" or root.get("bom-ref") != root_ref:
        raise ValueError("release SBOM root component mismatch")
    if root.get("group") != "Augani" or root.get("name") != "Dory" or root.get("version") != args.version:
        raise ValueError("release SBOM product identity mismatch")
    if root.get("licenses") != [{"license": {"id": "GPL-3.0-only"}}]:
        raise ValueError("release SBOM license mismatch")
    expected_properties = {
        "dev.dory.source.commit": args.source_commit,
        "dev.dory.app.tree.sha256": tree_sha256,
        "dev.dory.inventory.scope": "exact-shipped-app-files",
    }
    if properties(root.get("properties")) != expected_properties:
        raise ValueError("release SBOM source/tree binding mismatch")
    expected_dependencies = [{"ref": root_ref, "dependsOn": [item["bom-ref"] for item in expected_components]}]
    if document.get("dependencies") != expected_dependencies:
        raise ValueError("release SBOM dependency inventory mismatch")
    if leaks_runner_local_path(serialized, args.app):
        raise ValueError("release SBOM leaks a runner-local path")
    print("release CycloneDX SBOM: PASS")


if __name__ == "__main__":
    try:
        main()
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(f"release SBOM error: {error}") from error
