#!/usr/bin/env python3
"""Fail unless every public Dory release surface serves one exact candidate."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import pathlib
import re
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET


def fail(message: str) -> None:
    raise SystemExit(f"public release verification: {message}")


def fetch(url: str, *, token: str = "", attempts: int = 4, delay: int = 2) -> bytes:
    separator = "&" if "?" in url else "?"
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "Dory-public-release-verifier",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    last_error: Exception | None = None
    for attempt in range(1, attempts + 1):
        request = urllib.request.Request(
            f"{url}{separator}dory_verify={time.time_ns()}", headers=headers
        )
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return response.read()
        except Exception as error:  # pragma: no cover - error details are surfaced below
            last_error = error
            if attempt < attempts:
                time.sleep(delay)
    fail(f"could not fetch {url}: {last_error}")


def sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def release_asset_bytes(asset: dict[str, object]) -> bytes:
    url = str(asset.get("browser_download_url", ""))
    if not url:
        fail(f"release asset {asset.get('name')!r} has no download URL")
    return fetch(url)


def parse_cask(payload: bytes, label: str) -> tuple[str, str]:
    text = payload.decode("utf-8")
    version_match = re.search(r'^  version "([^"]+)"$', text, re.MULTILINE)
    digest_match = re.search(r'^  sha256 "([0-9a-f]{64})"$', text, re.MULTILINE)
    if not version_match or not digest_match:
        fail(f"{label} does not contain one pinned version and SHA-256")
    return version_match.group(1), digest_match.group(1)


def verify_casks(version: str, digest: str) -> None:
    urls = {
        "Dory repository cask":
            "https://raw.githubusercontent.com/Augani/dory/main/Casks/dory.rb",
        "homebrew-dory tap cask":
            "https://raw.githubusercontent.com/Augani/homebrew-dory/main/Casks/dory.rb",
    }
    pending = dict(urls)
    errors: list[str] = []
    for attempt in range(1, 19):
        errors = []
        for label, url in list(pending.items()):
            try:
                actual_version, actual_digest = parse_cask(fetch(url, attempts=1), label)
                if (actual_version, actual_digest) != (version, digest):
                    errors.append(
                        f"{label} serves {actual_version}/{actual_digest}, expected {version}/{digest}"
                    )
                    continue
                del pending[label]
            except (Exception, SystemExit) as error:  # pragma: no cover - propagation retry
                errors.append(str(error))
        if not pending:
            return
        if attempt < 18:
            time.sleep(5)
    fail("; ".join(errors))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", default="Augani/dory")
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--expected-primary-sha256", required=True)
    arguments = parser.parse_args()

    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", arguments.version):
        fail("version must be a stable semantic version such as 0.4.5")
    if not re.fullmatch(r"[0-9a-f]{40}", arguments.source_commit):
        fail("source commit must be a full lowercase Git SHA")
    if not re.fullmatch(r"[0-9a-f]{64}", arguments.expected_primary_sha256):
        fail("primary SHA-256 must contain 64 lowercase hexadecimal characters")

    token = os.environ.get("GH_TOKEN", "")
    tag = f"v{arguments.version}"
    api_url = f"https://api.github.com/repos/{arguments.repository}/releases/tags/{tag}"
    release = json.loads(fetch(api_url, token=token).decode("utf-8"))
    if release.get("tag_name") != tag or release.get("draft") or release.get("prerelease"):
        fail(f"{tag} is not a public stable release")

    asset_rows = release.get("assets", [])
    assets = {str(row["name"]): row for row in asset_rows}
    if len(assets) != len(asset_rows):
        fail("release contains duplicate asset names")

    version = arguments.version
    required = {
        f"Dory-{version}-arm64.zip",
        f"Dory-{version}.zip",
        f"Dory-{version}-arm64.dmg",
        f"Dory-{version}.dmg",
        f"Dory-{version}-app-update.zip",
        f"dory-engine-{version}-arm64.tar.gz",
        f"Dory-{version}.cdx.json",
        f"Dory-{version}-performance-evidence.zip",
        f"Dory-{version}-reliability-evidence.zip",
        f"Dory-{version}-reliability-evidence.zip.sha256",
        "release-manifest.json",
        "appcast.xml",
        "catalog.json",
        "catalog.json.sha256",
        "catalog.json.sig",
    }
    missing = required - assets.keys()
    if missing:
        fail(f"required release assets are missing: {', '.join(sorted(missing))}")

    manifest_bytes = release_asset_bytes(assets["release-manifest.json"])
    manifest = json.loads(manifest_bytes.decode("utf-8"))
    if manifest.get("schemaVersion") != 2:
        fail("release manifest must use the complete schema version 2 contract")
    if manifest.get("version") != version:
        fail("release manifest version does not match the tag")
    if manifest.get("sourceCommit") != arguments.source_commit:
        fail("release manifest source commit does not match the workflow commit")
    if manifest.get("publicRelease") is not True or manifest.get("notarized") is not True:
        fail("release manifest is not a notarized public-release manifest")
    if assets["release-manifest.json"].get("digest") != f"sha256:{sha256(manifest_bytes)}":
        fail("GitHub digest does not match release-manifest.json")

    manifest_artifacts = manifest.get("artifacts", [])
    if not manifest_artifacts:
        fail("release manifest has no artifacts")
    for row in manifest_artifacts:
        name = str(row.get("name", ""))
        if name not in assets:
            fail(f"manifest artifact is not published: {name}")
        asset = assets[name]
        expected_digest = f"sha256:{row.get('sha256', '')}"
        if asset.get("digest") != expected_digest:
            fail(f"GitHub digest does not match the manifest for {name}")
        if asset.get("size") != row.get("bytes"):
            fail(f"GitHub size does not match the manifest for {name}")

    primary_name = f"Dory-{version}.zip"
    primary = assets[primary_name]
    if primary.get("digest") != f"sha256:{arguments.expected_primary_sha256}":
        fail("primary ZIP digest differs from the qualified candidate")

    appcast_bytes = release_asset_bytes(assets["appcast.xml"])
    if assets["appcast.xml"].get("digest") != f"sha256:{sha256(appcast_bytes)}":
        fail("GitHub digest does not match appcast.xml")
    live_appcast = fetch("https://augani.github.io/dory/appcast.xml", attempts=8, delay=3)
    if live_appcast != appcast_bytes:
        fail("live Sparkle appcast differs from the release asset")
    sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    item = ET.fromstring(appcast_bytes).find("./channel/item")
    if item is None or item.findtext(f"{{{sparkle}}}shortVersionString") != version:
        fail("live appcast does not advertise the released version")
    enclosure = item.find("enclosure")
    if enclosure is None:
        fail("live appcast has no enclosure")
    update_name = pathlib.PurePosixPath(
        urllib.parse.urlparse(enclosure.attrib.get("url", "")).path
    ).name
    if update_name != f"Dory-{version}-app-update.zip":
        fail(f"live appcast encloses the wrong asset: {update_name}")
    if int(enclosure.attrib.get("length", "0")) != assets[update_name].get("size"):
        fail("live appcast enclosure length differs from the update ZIP")
    try:
        signature = base64.b64decode(
            enclosure.attrib[f"{{{sparkle}}}edSignature"], validate=True
        )
    except Exception as error:
        fail(f"live appcast signature is not valid base64: {error}")
    if len(signature) != 64:
        fail("live appcast does not contain a 64-byte Ed25519 signature")

    catalog_bytes = release_asset_bytes(assets["catalog.json"])
    catalog_digest_bytes = release_asset_bytes(assets["catalog.json.sha256"])
    catalog_signature_bytes = release_asset_bytes(assets["catalog.json.sig"])
    for name, payload in {
        "catalog.json": catalog_bytes,
        "catalog.json.sha256": catalog_digest_bytes,
        "catalog.json.sig": catalog_signature_bytes,
    }.items():
        if assets[name].get("digest") != f"sha256:{sha256(payload)}":
            fail(f"GitHub digest does not match {name}")
    expected_catalog_digest = sha256(catalog_bytes)
    if catalog_digest_bytes.decode("utf-8").strip() != expected_catalog_digest:
        fail("published component catalog digest does not match catalog.json")
    try:
        catalog_signature = base64.b64decode(catalog_signature_bytes.strip(), validate=True)
    except Exception as error:
        fail(f"component catalog signature is not valid base64: {error}")
    if len(catalog_signature) != 64:
        fail("component catalog does not contain a 64-byte Ed25519 signature")

    live_component_root = "https://augani.github.io/dory/components/arm64"
    for name, expected in {
        "catalog.json": catalog_bytes,
        "catalog.json.sha256": catalog_digest_bytes,
        "catalog.json.sig": catalog_signature_bytes,
    }.items():
        if fetch(f"{live_component_root}/{name}", attempts=8, delay=3) != expected:
            fail(f"live component metadata differs from the release asset: {name}")

    catalog = json.loads(catalog_bytes.decode("utf-8"))
    if catalog.get("releaseVersion") != version or catalog.get("architecture") != "arm64":
        fail("component catalog release identity is invalid")
    component_assets = [
        row
        for component in catalog.get("components", [])
        for row in component.get("assets", [])
    ]
    if not component_assets:
        fail("component catalog contains no downloadable assets")
    for row in component_assets:
        name = pathlib.PurePosixPath(urllib.parse.urlparse(row.get("url", "")).path).name
        if name not in assets:
            fail(f"catalog component is not a release asset: {name}")
        if assets[name].get("digest") != f"sha256:{row.get('sha256', '')}":
            fail(f"catalog digest differs from the GitHub asset for {name}")
        if assets[name].get("size") != row.get("downloadBytes"):
            fail(f"catalog size differs from the GitHub asset for {name}")

    reliability_name = f"Dory-{version}-reliability-evidence.zip"
    reliability_digest = release_asset_bytes(assets[f"{reliability_name}.sha256"])
    reliability_fields = reliability_digest.decode("utf-8").strip().split()
    if len(reliability_fields) != 2 or pathlib.PurePath(reliability_fields[1]).name != reliability_name:
        fail("reliability evidence digest file is malformed")
    if assets[reliability_name].get("digest") != f"sha256:{reliability_fields[0]}":
        fail("reliability evidence ZIP differs from its published digest file")

    verify_casks(version, arguments.expected_primary_sha256)
    print(
        f"public release verification: PASS ({tag}, {len(assets)} assets, "
        f"{len(component_assets)} component downloads, Pages and both casks exact)"
    )


if __name__ == "__main__":
    main()
