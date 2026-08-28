#!/usr/bin/env python3
"""Validate one canonical release identity against every published stable release."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from collections.abc import Callable, Iterable


SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SEMVER_PATTERN = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
)
POSITIVE_BUILD_PATTERN = re.compile(r"[1-9][0-9]*")


def fail(message: str) -> None:
    raise SystemExit(f"release identity error: {message}")


def semantic_version(value: object, label: str) -> tuple[int, int, int]:
    match = SEMVER_PATTERN.fullmatch(value if isinstance(value, str) else "")
    if match is None:
        fail(f"{label} is not a canonical stable semantic version: {value!r}")
    return tuple(int(part) for part in match.groups())


def positive_build(value: object, label: str) -> int:
    text = value if isinstance(value, str) else ""
    if POSITIVE_BUILD_PATTERN.fullmatch(text) is None:
        fail(f"{label} is not one canonical positive integer: {value!r}")
    return int(text)


def unique_project_value(project: str, setting: str) -> str:
    values = sorted(
        set(re.findall(rf"^\s*{re.escape(setting)} = ([^;]+);", project, re.MULTILINE))
    )
    if len(values) != 1:
        fail(f"project {setting} values are not unique: {values!r}")
    return values[0]


def current_appcast_identity(payload: bytes, label: str) -> tuple[tuple[int, int, int], int]:
    if not 0 < len(payload) <= 2 * 1024 * 1024:
        fail(f"{label} has an invalid size")
    try:
        root = ET.fromstring(payload)
    except ET.ParseError as error:
        fail(f"{label} is not valid XML: {error}")
    item = root.find("./channel/item")
    if item is None:
        fail(f"{label} has no current release item")
    version_text = item.findtext(f"{{{SPARKLE}}}shortVersionString")
    build_text = item.findtext(f"{{{SPARKLE}}}version")
    return (
        semantic_version(version_text, f"{label} current version"),
        positive_build(build_text, f"{label} current build"),
    )


def validate_release_history(
    releases: Iterable[dict[str, object]],
    fetch_asset: Callable[[dict[str, object], str], bytes],
    requested_version: str,
    requested_build: str,
) -> tuple[tuple[int, int, int] | None, int | None]:
    requested_version_value = semantic_version(requested_version, "requested release version")
    requested_build_value = positive_build(requested_build, "requested release build")

    stable: list[tuple[tuple[int, int, int], str, dict[str, object], list[dict[str, object]]]] = []
    seen_versions: set[tuple[int, int, int]] = set()
    for release in releases:
        if not isinstance(release, dict):
            fail("GitHub release listing contains a non-object entry")
        draft = release.get("draft")
        prerelease = release.get("prerelease")
        if not isinstance(draft, bool) or not isinstance(prerelease, bool):
            fail("GitHub release listing has an ambiguous draft/prerelease state")
        if draft or prerelease:
            continue
        tag = release.get("tag_name")
        if not isinstance(tag, str) or not tag.startswith("v"):
            continue
        match = SEMVER_PATTERN.fullmatch(tag[1:])
        if match is None:
            continue
        version_value = tuple(int(part) for part in match.groups())
        if version_value in seen_versions:
            fail(f"GitHub has more than one stable release for {tag}")
        seen_versions.add(version_value)
        assets_value = release.get("assets")
        if not isinstance(assets_value, list) or not all(
            isinstance(asset, dict) for asset in assets_value
        ):
            fail(f"GitHub release {tag} has an invalid asset listing")
        stable.append((version_value, tag, release, list(assets_value)))

    if any(version == requested_version_value for version, _, _, _ in stable):
        fail(f"release v{requested_version} already exists")
    previous_version = max((version for version, _, _, _ in stable), default=None)
    if previous_version is not None and requested_version_value <= previous_version:
        rendered = ".".join(str(part) for part in previous_version)
        fail(
            f"release version {requested_version} is not newer than published version {rendered}"
        )

    appcast_counts: dict[tuple[int, int, int], int] = {}
    for version, _, _, assets in stable:
        appcast_counts[version] = sum(asset.get("name") == "appcast.xml" for asset in assets)
        if appcast_counts[version] > 1:
            fail(f"stable release v{'.'.join(map(str, version))} repeats appcast.xml")

    appcast_versions = [version for version, count in appcast_counts.items() if count == 1]
    if stable and not appcast_versions:
        fail("no published stable release carries the authoritative appcast build ledger")
    appcast_floor = min(appcast_versions, default=None)
    published_builds: list[int] = []
    for version, tag, _, assets in sorted(stable):
        count = appcast_counts[version]
        if appcast_floor is not None and version >= appcast_floor and count != 1:
            fail(f"stable release {tag} is missing its unique authoritative appcast.xml")
        if count == 0:
            continue
        asset = next(asset for asset in assets if asset.get("name") == "appcast.xml")
        payload = fetch_asset(asset, tag)
        size = asset.get("size")
        if not isinstance(size, int) or size != len(payload):
            fail(f"stable release {tag} appcast size differs from GitHub metadata")
        digest = asset.get("digest")
        actual_digest = hashlib.sha256(payload).hexdigest()
        if digest != f"sha256:{actual_digest}":
            fail(f"stable release {tag} appcast digest differs from GitHub metadata")
        appcast_version, appcast_build = current_appcast_identity(payload, f"{tag} appcast.xml")
        if appcast_version != version:
            fail(f"stable release {tag} appcast current version disagrees with its tag")
        published_builds.append(appcast_build)

    previous_build = max(published_builds, default=None)
    if previous_build is not None and requested_build_value <= previous_build:
        fail(
            f"release build {requested_build} is not newer than published build {previous_build}"
        )
    return previous_version, previous_build


class GitHubClient:
    def __init__(self, repository: str, token: str) -> None:
        if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) is None:
            fail(f"invalid GitHub repository: {repository!r}")
        if not token:
            fail("GH_TOKEN is required to prove the complete GitHub release history")
        self.repository = repository
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "Dory-release-identity-verifier",
            "X-GitHub-Api-Version": "2022-11-28",
        }

    def request(self, url: str) -> bytes:
        request = urllib.request.Request(url, headers=self.headers)
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return response.read()
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as error:
            fail(f"GitHub request failed closed for {url}: {error}")

    def releases(self) -> list[dict[str, object]]:
        releases: list[dict[str, object]] = []
        page = 1
        while True:
            url = (
                f"https://api.github.com/repos/{self.repository}/releases"
                f"?per_page=100&page={page}"
            )
            try:
                payload = json.loads(self.request(url).decode("utf-8"))
            except (UnicodeError, json.JSONDecodeError) as error:
                fail(f"GitHub release page {page} is invalid JSON: {error}")
            if not isinstance(payload, list) or not all(isinstance(row, dict) for row in payload):
                fail(f"GitHub release page {page} has an invalid shape")
            releases.extend(payload)
            if len(payload) < 100:
                return releases
            page += 1
            if page > 100:
                fail("GitHub release pagination exceeded the fail-closed safety bound")

    def fetch_asset(self, asset: dict[str, object], tag: str) -> bytes:
        url = asset.get("browser_download_url")
        if not isinstance(url, str):
            fail("GitHub appcast asset has no browser download URL")
        parsed = urllib.parse.urlsplit(url)
        expected_path = f"/{self.repository}/releases/download/{tag}/appcast.xml"
        if (
            parsed.scheme != "https"
            or parsed.netloc != "github.com"
            or parsed.path != expected_path
            or parsed.query
            or parsed.fragment
            or parsed.username is not None
            or parsed.password is not None
        ):
            fail(f"GitHub appcast browser download URL is not canonical: {url!r}")
        request = urllib.request.Request(
            url, headers={"User-Agent": "Dory-release-identity-verifier"}
        )
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return response.read()
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as error:
            fail(f"public GitHub appcast download failed closed for {url}: {error}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", default="Augani/dory")
    parser.add_argument("--project", type=pathlib.Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--github-output", type=pathlib.Path)
    arguments = parser.parse_args()

    version_value = semantic_version(arguments.version, "requested release version")
    build_value = positive_build(arguments.build, "requested release build")
    try:
        project = arguments.project.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        fail(f"could not read project build settings: {error}")
    project_version = unique_project_value(project, "MARKETING_VERSION")
    project_build = unique_project_value(project, "CURRENT_PROJECT_VERSION")
    if semantic_version(project_version, "project MARKETING_VERSION") != version_value:
        fail(
            f"project MARKETING_VERSION {project_version!r} does not match {arguments.version}"
        )
    if positive_build(project_build, "project CURRENT_PROJECT_VERSION") != build_value:
        fail(f"project CURRENT_PROJECT_VERSION {project_build!r} does not match {arguments.build}")

    client = GitHubClient(arguments.repository, os.environ.get("GH_TOKEN", ""))
    previous_version, previous_build = validate_release_history(
        client.releases(), client.fetch_asset, arguments.version, arguments.build
    )
    if arguments.github_output is not None:
        with arguments.github_output.open("a", encoding="utf-8") as output:
            output.write(f"version={arguments.version}\n")
            output.write(f"build={arguments.build}\n")
            previous_text = (
                "" if previous_version is None else ".".join(str(part) for part in previous_version)
            )
            output.write(f"previous_version={previous_text}\n")
    previous_version_text = (
        "none" if previous_version is None else ".".join(str(part) for part in previous_version)
    )
    print(
        f"Release identity {arguments.version} ({arguments.build}) is newer than all "
        f"published stable releases (previous {previous_version_text}/{previous_build or 'none'})."
    )


if __name__ == "__main__":
    main()
