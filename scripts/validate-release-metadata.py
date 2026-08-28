#!/usr/bin/env python3
"""Validate the public release manifest and complete Sparkle appcast contract."""

import base64
import email.utils
import hashlib
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
import urllib.parse
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DORY = "https://augani.github.io/dory/appcast"
MANIFEST_KEYS = {
    "schemaVersion",
    "version",
    "build",
    "sourceCommit",
    "publicRelease",
    "bundleEngine",
    "notarized",
    "variants",
    "artifacts",
}
RECORD_KEYS = {"name", "path", "kind", "bytes", "sha256"}
VERSION_PATTERN = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
CATALOG_PUBLIC_KEY = "AFetajNbqZty68rRY7OMWYNt6suUsrokQmYMhDJtnP4="
CATALOG_KEYS = {
    "kind",
    "schemaVersion",
    "releaseVersion",
    "generatedAt",
    "minimumAppVersion",
    "architecture",
    "components",
    "virtualMachineQualification",
}
COMPONENT_KEYS = {
    "id",
    "version",
    "displayName",
    "summary",
    "dependencies",
    "downloadBytes",
    "installedBytes",
    "assets",
    "architectures",
    "hostRequirements",
    "provides",
    "requires",
    "provenance",
    "qualification",
}
ASSET_REQUIRED_KEYS = {
    "path",
    "role",
    "url",
    "compression",
    "downloadBytes",
    "installedBytes",
    "sha256",
    "installedSHA256",
    "executable",
}
QUALIFICATION_KEYS = {
    "component",
    "path",
    "manifestIdentity",
    "manifestFormatVersion",
    "signingKeyID",
}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def unique_json_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        require(key not in result, f"JSON contains duplicate key: {key}")
        result[key] = value
    return result


def exact_object(value: object, keys: set[str], label: str) -> dict:
    require(isinstance(value, dict) and set(value) == keys, f"{label} shape is invalid")
    return value


def positive_integer(value: object, label: str) -> int:
    require(
        not isinstance(value, bool) and isinstance(value, int) and value > 0,
        f"{label} must be a positive integer",
    )
    return value


def nonempty_string(value: object, label: str) -> str:
    require(isinstance(value, str) and value and len(value.encode("utf-8")) <= 4_096, f"{label} is invalid")
    return value


def digest_value(value: object, label: str) -> str:
    require(isinstance(value, str) and SHA256_PATTERN.fullmatch(value) is not None, f"{label} is invalid")
    return value


def verify_catalog_signature(
    catalog_path: pathlib.Path,
    signature_path: pathlib.Path,
    public_key: str,
) -> None:
    verifier = pathlib.Path(__file__).resolve().parent.parent / ".github/scripts/verify-ed25519-signature.swift"
    require(verifier.is_file(), "Ed25519 verifier is missing")
    completed = subprocess.run(
        ["xcrun", "swift", str(verifier), public_key, str(signature_path), str(catalog_path)],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    require(completed.returncode == 0, "component catalog signature is invalid")


def validate_catalog(
    build_dir: pathlib.Path,
    version: str,
    source_commit: str,
    *,
    public_key: str = CATALOG_PUBLIC_KEY,
) -> set[str]:
    component_dir = build_dir / "components" / "arm64"
    catalog_path = component_dir / "catalog.json"
    digest_path = component_dir / "catalog.json.sha256"
    signature_path = component_dir / "catalog.json.sig"
    for path in (catalog_path, digest_path, signature_path):
        require(path.is_file() and not path.is_symlink(), f"component catalog input is missing or indirect: {path.name}")
    catalog_bytes = catalog_path.read_bytes()
    require(0 < len(catalog_bytes) <= 2 * 1_024 * 1_024, "component catalog size is invalid")
    expected_digest = hashlib.sha256(catalog_bytes).hexdigest()
    require(
        digest_path.read_text(encoding="ascii") == expected_digest + "\n",
        "component catalog digest does not authenticate catalog.json",
    )
    verify_catalog_signature(catalog_path, signature_path, public_key)
    catalog = json.loads(catalog_bytes, object_pairs_hook=unique_json_object)
    exact_object(catalog, CATALOG_KEYS, "component catalog")
    require(catalog["kind"] == "dev.dory.component-catalog", "component catalog kind mismatch")
    require(catalog["schemaVersion"] == 2, "component catalog must use schema 2")
    require(catalog["releaseVersion"] == version, "component catalog release version mismatch")
    require(catalog["minimumAppVersion"] == version, "component catalog app version mismatch")
    require(catalog["architecture"] == "arm64", "component catalog architecture mismatch")
    generated_at = nonempty_string(catalog["generatedAt"], "component catalog generatedAt")
    require(
        re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", generated_at) is not None,
        "component catalog generatedAt is not canonical UTC",
    )

    qualification = exact_object(
        catalog["virtualMachineQualification"],
        QUALIFICATION_KEYS,
        "component catalog VM qualification declaration",
    )
    require(qualification["component"] == "linux-desktop", "VM qualification component mismatch")
    require(
        qualification["path"] == "virtual-machine-qualification.json",
        "VM qualification path mismatch",
    )
    nonempty_string(qualification["manifestIdentity"], "VM qualification identity")
    require(qualification["manifestFormatVersion"] == 2, "VM qualification schema mismatch")
    decoded_key = base64.b64decode(public_key, validate=True)
    require(len(decoded_key) == 32, "component catalog public key is invalid")
    require(
        qualification["signingKeyID"] == hashlib.sha256(decoded_key).hexdigest(),
        "VM qualification signing key does not match the catalog trust root",
    )

    components = catalog["components"]
    require(isinstance(components, list) and components, "component catalog has no components")
    component_ids: list[str] = []
    component_assets: dict[tuple[str, str], dict] = {}
    artifact_names: set[str] = set()
    for index, value in enumerate(components):
        component = exact_object(value, COMPONENT_KEYS, f"component {index}")
        component_id = nonempty_string(component["id"], f"component {index} id")
        component_ids.append(component_id)
        require(component["version"] == version, f"component {component_id} version mismatch")
        nonempty_string(component["displayName"], f"component {component_id} display name")
        nonempty_string(component["summary"], f"component {component_id} summary")
        require(component["architectures"] == ["arm64"], f"component {component_id} architecture mismatch")
        host = exact_object(
            component["hostRequirements"],
            {"platform", "minimumVersion"},
            f"component {component_id} host requirements",
        )
        require(host == {"platform": "macos", "minimumVersion": "14.0"}, f"component {component_id} host contract mismatch")
        for field in ("dependencies", "provides", "requires", "qualification"):
            require(
                isinstance(component[field], list)
                and all(isinstance(item, str) and item for item in component[field]),
                f"component {component_id} {field} is invalid",
            )
        positive_integer(component["downloadBytes"], f"component {component_id} downloadBytes")
        positive_integer(component["installedBytes"], f"component {component_id} installedBytes")
        provenance = exact_object(
            component["provenance"],
            {"sourceCommit", "builder", "recipeDigest", "sbomDigest", "attestationDigest"},
            f"component {component_id} provenance",
        )
        require(
            provenance["sourceCommit"] == source_commit,
            f"component {component_id} source commit does not match the release",
        )
        nonempty_string(provenance["builder"], f"component {component_id} builder")
        for field in ("recipeDigest", "sbomDigest", "attestationDigest"):
            digest_value(provenance[field], f"component {component_id} {field}")
        assets = component["assets"]
        require(isinstance(assets, list), f"component {component_id} assets are invalid")
        for asset_index, raw_asset in enumerate(assets):
            allowed_keys = ASSET_REQUIRED_KEYS | {"codeRequirement"}
            require(
                isinstance(raw_asset, dict)
                and ASSET_REQUIRED_KEYS <= set(raw_asset) <= allowed_keys,
                f"component {component_id} asset {asset_index} shape is invalid",
            )
            asset = raw_asset
            nonempty_string(asset["role"], "component asset role")
            installed_path = pathlib.PurePosixPath(nonempty_string(asset["path"], "component asset path"))
            require(
                not installed_path.is_absolute() and ".." not in installed_path.parts,
                f"component {component_id} asset path is unsafe",
            )
            require(asset["compression"] in {"none", "lzfse"}, "component asset compression is invalid")
            require(isinstance(asset["executable"], bool), "component asset executable flag is invalid")
            require(
                (asset["executable"] and nonempty_string(asset.get("codeRequirement"), "component asset code requirement"))
                or (not asset["executable"] and "codeRequirement" not in asset),
                "component asset code requirement does not match executable state",
            )
            download_bytes = positive_integer(
                asset["downloadBytes"], "component asset downloadBytes"
            )
            installed_bytes = positive_integer(
                asset["installedBytes"], "component asset installedBytes"
            )
            download_digest = digest_value(asset["sha256"], "component asset digest")
            installed_digest = digest_value(
                asset["installedSHA256"], "component installed digest"
            )
            if asset["compression"] == "none":
                require(
                    download_bytes == installed_bytes
                    and download_digest == installed_digest,
                    "uncompressed component asset binding is inconsistent",
                )
            parsed = urllib.parse.urlparse(nonempty_string(asset["url"], "component asset URL"))
            require(
                parsed.scheme == "https"
                and parsed.netloc == "github.com"
                and parsed.path.startswith(f"/Augani/dory/releases/download/v{version}/")
                and not parsed.params
                and not parsed.query
                and not parsed.fragment,
                "component asset URL is not canonical",
            )
            artifact_name = os.path.basename(parsed.path)
            require(
                artifact_name.startswith(f"Dory-{version}-component-{component_id}-arm64-"),
                "component asset name is invalid",
            )
            require(artifact_name not in artifact_names, "component asset name is duplicated")
            artifact_path = component_dir / artifact_name
            try:
                artifact_info = artifact_path.lstat()
            except FileNotFoundError:
                raise ValueError(f"component asset file is missing: {artifact_name}") from None
            require(
                stat.S_ISREG(artifact_info.st_mode) and artifact_info.st_size > 0,
                f"component asset file is indirect or empty: {artifact_name}",
            )
            require(
                artifact_info.st_size == download_bytes,
                f"component asset byte count differs from catalog: {artifact_name}",
            )
            require(
                sha256_file(artifact_path) == download_digest,
                f"component asset digest differs from catalog: {artifact_name}",
            )
            artifact_names.add(artifact_name)
            component_assets[(component_id, str(installed_path))] = asset
    require(len(set(component_ids)) == len(component_ids), "component IDs are duplicated")
    require(component_ids[0] == "docker-core", "Docker Core must be the first component")
    require(components[0]["assets"] == [], "Docker Core must not declare downloadable assets")
    require("linux-desktop" in component_ids, "Linux Desktop qualification component is missing")
    require(
        all(dependency in set(component_ids) for component in components for dependency in component["dependencies"]),
        "component dependency is unavailable",
    )
    qualification_asset = component_assets.get((qualification["component"], qualification["path"]))
    require(
        qualification_asset is not None and qualification_asset["role"] == "qualification-evidence",
        "signed catalog does not bind its VM qualification asset",
    )
    linux_desktop = components[component_ids.index("linux-desktop")]
    require(
        linux_desktop["provenance"]["attestationDigest"] == qualification_asset["installedSHA256"],
        "VM qualification provenance does not bind the declared asset",
    )
    return artifact_names


def validate_manifest(build_dir: pathlib.Path, version: str, build: str) -> tuple[dict, str]:
    path = build_dir / "release-manifest.json"
    require(path.is_file() and not path.is_symlink(), "release manifest is missing or indirect")
    manifest = json.loads(
        path.read_text(encoding="utf-8"),
        object_pairs_hook=unique_json_object,
    )
    require(isinstance(manifest, dict) and set(manifest) == MANIFEST_KEYS, "release manifest shape is invalid")
    require(manifest["schemaVersion"] == 2, "unexpected release manifest schema")
    require(manifest["version"] == version, "manifest version mismatch")
    require(str(manifest["build"]) == build, "manifest build mismatch")
    source_commit = manifest["sourceCommit"]
    require(
        isinstance(source_commit, str)
        and re.fullmatch(r"[0-9a-f]{40}", source_commit) is not None,
        "manifest sourceCommit is not a full lowercase Git SHA",
    )
    require(manifest["publicRelease"] is True, "manifest is not marked as a public release")
    require(manifest["bundleEngine"] is True, "manifest describes an app-only release")
    require(manifest["notarized"] is True, "manifest describes an unnotarized release")
    require(manifest["variants"] == "arm64", "manifest is not Apple-Silicon-only")

    required = {
        f"Dory-{version}-arm64.zip",
        f"Dory-{version}.zip",
        f"Dory-{version}-arm64.dmg",
        f"Dory-{version}.dmg",
        f"Dory-{version}-app-update.zip",
        f"dory-engine-{version}-arm64.tar.gz",
        f"Dory-{version}.cdx.json",
        "appcast.xml",
        "catalog.json",
        "catalog.json.sha256",
        "catalog.json.sig",
    }
    required.update(validate_catalog(build_dir, version, source_commit))
    records = manifest["artifacts"]
    require(isinstance(records, list) and records, "manifest has no artifacts")
    require(
        all(isinstance(record, dict) and set(record) == RECORD_KEYS for record in records),
        "manifest artifact record shape is invalid",
    )
    by_name = {record["name"]: record for record in records}
    require(len(by_name) == len(records), "manifest contains duplicate artifact names")
    require(set(by_name) == required, f"manifest artifact set mismatch: {sorted(set(by_name) ^ required)}")
    for name, record in by_name.items():
        expected_path = f"components/arm64/{name}" if name.startswith("catalog.json") or \
            name.startswith(f"Dory-{version}-component-") else name
        require(record["path"] == expected_path, f"manifest path is not portable: {name}")
        require(isinstance(record["kind"], str) and record["kind"], f"manifest kind is invalid: {name}")
        artifact = build_dir / record["path"]
        require(artifact.is_file() and not artifact.is_symlink(), f"manifest artifact is missing or indirect: {name}")
        require(record["bytes"] == artifact.stat().st_size, f"manifest byte count mismatch: {name}")
        require(record["sha256"] == sha256_file(artifact), f"manifest SHA-256 mismatch: {name}")
    require(by_name[f"Dory-{version}.cdx.json"]["kind"] == "cyclonedx-json", "SBOM artifact kind mismatch")
    return by_name, source_commit


def validate_appcast(
    build_dir: pathlib.Path,
    version: str,
    build: str,
    filename: str,
    title: str,
    link: str,
    expected_name: str,
) -> None:
    root = ET.parse(build_dir / filename).getroot()
    require(root.tag == "rss" and root.attrib == {"version": "2.0"}, "appcast root is invalid")
    channel = root.find("channel")
    require(channel is not None, "appcast has no channel")
    require(channel.findtext("title") == title, f"{filename} channel identity mismatch")
    require(channel.findtext("link") == link, f"{filename} link mismatch")
    require(
        channel.findtext("description") == "Updates for Dory - native Docker and Linux containers for macOS.",
        "appcast description mismatch",
    )
    require(channel.findtext("language") == "en", "appcast language mismatch")
    items = channel.findall("item")
    require(bool(items), "appcast has no current item")
    require(items[0].findtext(f"{{{SPARKLE}}}version") == build, "appcast build mismatch")
    require(items[0].findtext(f"{{{SPARKLE}}}shortVersionString") == version, "appcast version mismatch")

    expected_size = (build_dir / expected_name).stat().st_size
    seen_builds: set[str] = set()
    seen_versions: set[str] = set()
    for index, item in enumerate(items):
        release_build = item.findtext(f"{{{SPARKLE}}}version", "")
        release_version = item.findtext(f"{{{SPARKLE}}}shortVersionString", "")
        require(release_build.isdigit() and int(release_build) > 0, "appcast item build is invalid")
        require(VERSION_PATTERN.fullmatch(release_version) is not None, "appcast item version is invalid")
        require(release_build not in seen_builds, f"duplicate appcast build: {release_build}")
        require(release_version not in seen_versions, f"duplicate appcast version: {release_version}")
        seen_builds.add(release_build)
        seen_versions.add(release_version)
        require(item.findtext("title") == release_version, f"appcast {release_version} title mismatch")
        require(
            item.findtext(f"{{{SPARKLE}}}minimumSystemVersion") == "14.0",
            f"appcast {release_version} macOS floor mismatch",
        )
        target_schema = item.findtext(f"{{{DORY}}}dataSchemaVersion", "")
        minimum_schema = item.findtext(f"{{{DORY}}}minimumReadableDataSchema", "")
        maximum_schema = item.findtext(f"{{{DORY}}}maximumReadableDataSchema", "")
        component_schema = item.findtext(f"{{{DORY}}}componentCatalogSchema", "")
        require(
            all(value.isdigit() and int(value) > 0 for value in (
                target_schema, minimum_schema, maximum_schema, component_schema
            )),
            f"appcast {release_version} Dory schema contract is missing or invalid",
        )
        require(
            int(minimum_schema) <= int(target_schema) <= int(maximum_schema),
            f"appcast {release_version} readable data-schema range excludes its target",
        )
        require(
            int(component_schema) == (2 if index == 0 else 1),
            f"appcast {release_version} component schema is unsupported",
        )
        publication_date = email.utils.parsedate_to_datetime(item.findtext("pubDate", ""))
        require(publication_date.tzinfo is not None, f"appcast {release_version} publication date is invalid")
        enclosure = item.find("enclosure")
        require(enclosure is not None, f"appcast {release_version} item has no enclosure")
        expected_attributes = {"url", f"{{{SPARKLE}}}edSignature", "length", "type"}
        require(set(enclosure.attrib) == expected_attributes, f"appcast {release_version} enclosure shape is invalid")
        parsed_url = urllib.parse.urlparse(enclosure.attrib["url"])
        filename = os.path.basename(parsed_url.path)
        require(
            parsed_url.scheme == "https"
            and parsed_url.netloc == "github.com"
            and not parsed_url.params
            and not parsed_url.query
            and not parsed_url.fragment,
            f"appcast {release_version} enclosure is not a canonical GitHub URL",
        )
        require(
            parsed_url.path.startswith(f"/Augani/dory/releases/download/v{release_version}/"),
            f"appcast {release_version} enclosure is outside its versioned Dory release",
        )
        require(
            filename.startswith(f"Dory-{release_version}") and filename.endswith(".zip"),
            f"appcast {release_version} enclosure filename is invalid",
        )
        require(enclosure.attrib["type"] == "application/octet-stream", "appcast enclosure type is invalid")
        length = enclosure.attrib["length"]
        require(length.isdigit() and int(length) > 0, f"appcast {release_version} length is invalid")
        signature = base64.b64decode(enclosure.attrib[f"{{{SPARKLE}}}edSignature"], validate=True)
        require(len(signature) == 64, f"appcast {release_version} EdDSA signature length is invalid")
        if index == 0:
            require(filename == expected_name, f"appcast points at {filename!r}, expected {expected_name!r}")
            require(int(length) == expected_size, "appcast length mismatch")
        else:
            require(
                int(release_build) < int(build),
                f"historical appcast build {release_build} is not older than {build}",
            )


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: validate-release-metadata.py <build-dir> <version> <build>")
    build_dir = pathlib.Path(sys.argv[1])
    require(build_dir.is_dir() and not build_dir.is_symlink(), "build directory is missing or indirect")
    require(build_dir.resolve() == build_dir.absolute(), "build directory must be canonical")
    version, build = sys.argv[2:]
    _, source_commit = validate_manifest(build_dir, version, build)
    validate_appcast(
        build_dir,
        version,
        build,
        "appcast.xml",
        "Dory",
        "https://augani.github.io/dory/appcast.xml",
        f"Dory-{version}-app-update.zip",
    )
    print(source_commit)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, ET.ParseError) as error:
        raise SystemExit(f"release metadata error: {error}") from error
