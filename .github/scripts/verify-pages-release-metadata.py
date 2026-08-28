#!/usr/bin/env python3
"""Verify and transactionally preserve Dory's signed Pages release metadata."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from collections.abc import Callable


SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DORY = "https://augani.github.io/dory/appcast"
PUBLIC_KEY_BASE64 = "AFetajNbqZty68rRY7OMWYNt6suUsrokQmYMhDJtnP4="
CATALOG_NAMES = ("catalog.json", "catalog.json.sha256", "catalog.json.sig")
COMPONENT_IDS = {
    "docker-core",
    "kubernetes",
    "linux-machines",
    "linux-desktop",
    "desktop-debian",
    "desktop-ubuntu",
    "desktop-kali",
}
SEMVER_PATTERN = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
)


def fail(message: str) -> None:
    raise SystemExit(f"Pages release metadata error: {message}")


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def direct_regular_file(path: pathlib.Path, maximum_bytes: int) -> bytes:
    try:
        info = path.lstat()
    except OSError as error:
        fail(f"could not inspect {path}: {error}")
    require(stat.S_ISREG(info.st_mode), f"{path} is not a direct regular file")
    require(0 < info.st_size <= maximum_bytes, f"{path} has an invalid size")
    try:
        return path.read_bytes()
    except OSError as error:
        fail(f"could not read {path}: {error}")


def semantic_version(value: object, label: str) -> tuple[int, int, int]:
    match = SEMVER_PATTERN.fullmatch(value if isinstance(value, str) else "")
    require(match is not None, f"{label} is not a canonical stable semantic version: {value!r}")
    return tuple(int(part) for part in match.groups())


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        require(key not in value, f"catalog JSON repeats key {key!r}")
        value[key] = item
    return value


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def appcast_current_identity(
    payload: bytes, label: str
) -> tuple[tuple[int, int, int], int]:
    require(0 < len(payload) <= 2 * 1024 * 1024, f"{label} has an invalid size")
    try:
        item = ET.fromstring(payload).find("./channel/item")
    except ET.ParseError as error:
        fail(f"{label} is invalid XML: {error}")
    require(item is not None, f"{label} has no current release item")
    version = item.findtext(f"{{{SPARKLE}}}shortVersionString")
    build = item.findtext(f"{{{SPARKLE}}}version")
    version_value = semantic_version(version, f"{label} current version")
    require(
        build is not None and re.fullmatch(r"[1-9][0-9]*", build) is not None,
        f"{label} has an invalid current build",
    )
    return version_value, int(build)


class GitHubReleaseAuthority:
    """Binds appcast bytes and their Sparkle signature to exact GitHub release assets."""

    def __init__(self, repository: str = "Augani/dory") -> None:
        self.repository = repository
        self.token = os.environ.get("GH_TOKEN", "")
        self.cache: dict[str, dict[str, object]] = {}
        self.appcast_cache: dict[str, bytes] = {}
        self.ledger: tuple[tuple[int, int, int], int] | None = None
        cache_value = os.environ.get("DORY_SPARKLE_AUTHORITY_CACHE", "")
        if cache_value:
            self.cache_root = pathlib.Path(cache_value)
            self.cache_root.mkdir(parents=True, exist_ok=True)
            require(
                self.cache_root.is_dir() and not self.cache_root.is_symlink(),
                f"Sparkle authority cache is indirect: {self.cache_root}",
            )
        else:
            self.cache_root = pathlib.Path(tempfile.mkdtemp(prefix="dory-sparkle-authority-"))

    def request(self, url: str, *, api: bool, destination: pathlib.Path | None = None) -> bytes:
        headers = {"User-Agent": "Dory-Pages-release-metadata-verifier"}
        if api:
            headers.update(
                {
                    "Accept": "application/vnd.github+json",
                    "X-GitHub-Api-Version": "2022-11-28",
                }
            )
            if self.token:
                headers["Authorization"] = f"Bearer {self.token}"
        separator = "&" if "?" in url else "?"
        request = urllib.request.Request(
            f"{url}{separator}dory_metadata={time.time_ns()}", headers=headers
        )
        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                if destination is None:
                    return response.read()
                with destination.open("wb") as output:
                    shutil.copyfileobj(response, output, length=1024 * 1024)
                return b""
        except (OSError, urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as error:
            fail(f"authoritative GitHub release request failed closed for {url}: {error}")

    def release(self, version: str) -> dict[str, object]:
        if version in self.cache:
            return self.cache[version]
        encoded_tag = urllib.parse.quote(f"v{version}", safe="")
        url = f"https://api.github.com/repos/{self.repository}/releases/tags/{encoded_tag}"
        try:
            release = json.loads(self.request(url, api=True).decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as error:
            fail(f"GitHub release v{version} is invalid JSON: {error}")
        require(isinstance(release, dict), f"GitHub release v{version} is not an object")
        require(release.get("tag_name") == f"v{version}", f"GitHub release v{version} has the wrong tag")
        require(release.get("draft") is False, f"GitHub release v{version} is a draft")
        require(release.get("prerelease") is False, f"GitHub release v{version} is a prerelease")
        assets = release.get("assets")
        require(
            isinstance(assets, list) and all(isinstance(asset, dict) for asset in assets),
            f"GitHub release v{version} has an invalid asset list",
        )
        self.cache[version] = release
        return release

    @staticmethod
    def exact_asset(release: dict[str, object], name: str, version: str) -> dict[str, object]:
        assets = release.get("assets")
        require(isinstance(assets, list), f"GitHub release v{version} has no asset list")
        matches = [asset for asset in assets if isinstance(asset, dict) and asset.get("name") == name]
        require(len(matches) == 1, f"GitHub release v{version} does not have exactly one {name}")
        return matches[0]

    def small_asset_bytes(
        self, asset: dict[str, object], version: str, name: str
    ) -> bytes:
        url = asset.get("browser_download_url")
        require(isinstance(url, str), f"v{version} {name} has no download URL")
        parsed = urllib.parse.urlsplit(url)
        expected_path = f"/{self.repository}/releases/download/v{version}/{name}"
        require(
            parsed.scheme == "https"
            and parsed.netloc == "github.com"
            and parsed.path == expected_path
            and not parsed.query
            and not parsed.fragment
            and parsed.username is None
            and parsed.password is None,
            f"v{version} {name} has a non-canonical download URL",
        )
        payload = self.request(url, api=False)
        size = asset.get("size")
        require(
            isinstance(size, int) and 0 < size <= 2 * 1024 * 1024,
            f"v{version} {name} has an invalid size",
        )
        require(size == len(payload), f"v{version} {name} size differs from GitHub")
        digest = asset.get("digest")
        actual = hashlib.sha256(payload).hexdigest()
        require(digest == f"sha256:{actual}", f"v{version} {name} digest differs from GitHub")
        return payload

    def stable_ledger(self) -> tuple[tuple[int, int, int], int]:
        if self.ledger is not None:
            return self.ledger
        rows: list[dict[str, object]] = []
        page = 1
        while True:
            url = (
                f"https://api.github.com/repos/{self.repository}/releases"
                f"?per_page=100&page={page}"
            )
            try:
                payload = json.loads(self.request(url, api=True).decode("utf-8"))
            except (UnicodeError, json.JSONDecodeError) as error:
                fail(f"GitHub stable release page {page} is invalid JSON: {error}")
            require(
                isinstance(payload, list) and all(isinstance(row, dict) for row in payload),
                f"GitHub stable release page {page} has an invalid shape",
            )
            rows.extend(payload)
            if len(payload) < 100:
                break
            page += 1
            require(page <= 100, "GitHub stable release pagination exceeded its safety bound")

        stable: list[tuple[tuple[int, int, int], str, dict[str, object]]] = []
        seen: set[tuple[int, int, int]] = set()
        for release in rows:
            draft = release.get("draft")
            prerelease = release.get("prerelease")
            require(
                isinstance(draft, bool) and isinstance(prerelease, bool),
                "GitHub release has ambiguous draft/prerelease state",
            )
            if draft or prerelease:
                continue
            tag = release.get("tag_name")
            if not isinstance(tag, str) or not tag.startswith("v"):
                continue
            match = SEMVER_PATTERN.fullmatch(tag[1:])
            if match is None:
                continue
            version_value = tuple(int(part) for part in match.groups())
            require(version_value not in seen, f"GitHub repeats stable release {tag}")
            seen.add(version_value)
            assets = release.get("assets")
            require(
                isinstance(assets, list) and all(isinstance(asset, dict) for asset in assets),
                f"GitHub release {tag} has an invalid asset list",
            )
            stable.append((version_value, tag[1:], release))
            self.cache[tag[1:]] = release
        require(stable, "GitHub has no canonical stable release authority")

        counts: dict[tuple[int, int, int], int] = {}
        for version_value, _, release in stable:
            assets = release.get("assets")
            require(isinstance(assets, list), "GitHub release lost its asset list")
            counts[version_value] = sum(
                isinstance(asset, dict) and asset.get("name") == "appcast.xml"
                for asset in assets
            )
            require(counts[version_value] <= 1, "stable release repeats appcast.xml")
        appcast_versions = [version for version, count in counts.items() if count == 1]
        require(appcast_versions, "no stable release has an authoritative appcast.xml")
        floor = min(appcast_versions)
        builds: list[int] = []
        for version_value, version, release in sorted(stable):
            count = counts[version_value]
            if version_value >= floor:
                require(count == 1, f"stable release v{version} lacks one appcast.xml")
            if count == 0:
                continue
            asset = self.exact_asset(release, "appcast.xml", version)
            appcast = self.small_asset_bytes(asset, version, "appcast.xml")
            self.appcast_cache[version] = appcast
            appcast_version, appcast_build = appcast_current_identity(
                appcast, f"v{version} appcast.xml"
            )
            require(appcast_version == version_value, f"v{version} appcast disagrees with its tag")
            builds.append(appcast_build)
        self.ledger = (max(version for version, _, _ in stable), max(builds))
        return self.ledger

    def cached_update_asset(self, asset: dict[str, object], version: str) -> pathlib.Path:
        size = asset.get("size")
        digest_value = asset.get("digest")
        require(isinstance(size, int) and 0 < size <= 4 * 1024 * 1024 * 1024, "update size is invalid")
        require(
            isinstance(digest_value, str)
            and re.fullmatch(r"sha256:[0-9a-f]{64}", digest_value) is not None,
            "update asset has no canonical GitHub SHA-256",
        )
        expected_digest = digest_value.removeprefix("sha256:")
        destination = self.cache_root / f"{expected_digest}.app-update.zip"
        if destination.exists():
            require(destination.is_file() and not destination.is_symlink(), "cached update is indirect")
            if destination.stat().st_size == size and sha256_file(destination) == expected_digest:
                return destination
            fail(f"cached update differs from GitHub authority: {destination}")
        url = asset.get("browser_download_url")
        require(isinstance(url, str), "update asset has no download URL")
        temporary = self.cache_root / f".{expected_digest}.{os.getpid()}.partial"
        require(not temporary.exists(), f"update download staging path already exists: {temporary}")
        self.request(url, api=False, destination=temporary)
        require(temporary.stat().st_size == size, "downloaded update size differs from GitHub")
        require(sha256_file(temporary) == expected_digest, "downloaded update digest differs from GitHub")
        os.replace(temporary, destination)
        return destination

    def verify(self, version: str, appcast_bytes: bytes, signature: bytes, enclosure: ET.Element) -> None:
        maximum_version, maximum_build = self.stable_ledger()
        current_version, current_build = appcast_current_identity(
            appcast_bytes, f"v{version} appcast.xml"
        )
        require(current_version == maximum_version, f"v{version} is not the maximum stable release")
        require(current_build == maximum_build, f"v{version} does not carry the maximum stable build")
        release = self.release(version)
        appcast_asset = self.exact_asset(release, "appcast.xml", version)
        authoritative = self.appcast_cache.get(version)
        if authoritative is None:
            authoritative = self.small_asset_bytes(appcast_asset, version, "appcast.xml")
        require(appcast_bytes == authoritative, f"appcast.xml differs from authoritative v{version} release asset")

        update_name = f"Dory-{version}-app-update.zip"
        update_asset = self.exact_asset(release, update_name, version)
        require(enclosure.get("length") == str(update_asset.get("size")), "Sparkle length differs from release asset")
        update_path = self.cached_update_asset(update_asset, version)
        public_key = base64.b64decode(PUBLIC_KEY_BASE64, validate=True)
        with tempfile.TemporaryDirectory(prefix="dory-sparkle-ed25519-") as temporary_value:
            temporary = pathlib.Path(temporary_value)
            key_path = temporary / "public-key.der"
            signature_path = temporary / "signature.raw"
            key_path.write_bytes(bytes.fromhex("302a300506032b6570032100") + public_key)
            signature_path.write_bytes(signature)
            result = subprocess.run(
                [
                    "openssl",
                    "pkeyutl",
                    "-verify",
                    "-pubin",
                    "-inkey",
                    str(key_path),
                    "-keyform",
                    "DER",
                    "-rawin",
                    "-in",
                    str(update_path),
                    "-sigfile",
                    str(signature_path),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
        require(
            result.returncode == 0,
            f"Sparkle Ed25519 signature does not authenticate {update_name}: {result.stdout.strip()}",
        )


Authority = Callable[[str, bytes, bytes, ET.Element], None]


def release_item(path: pathlib.Path, authority: Authority) -> tuple[int, str, int]:
    raw = direct_regular_file(path, 2 * 1024 * 1024)
    try:
        item = ET.fromstring(raw).find("./channel/item")
    except ET.ParseError as error:
        fail(f"{path} is invalid XML: {error}")
    require(item is not None, f"{path} has no release item")
    build = item.findtext(f"{{{SPARKLE}}}version")
    require(
        build is not None and re.fullmatch(r"[1-9][0-9]*", build) is not None,
        f"{path} has an invalid monotonic build",
    )
    version = item.findtext(f"{{{SPARKLE}}}shortVersionString")
    semantic_version(version, f"{path} release version")
    require(isinstance(version, str), f"{path} has no release version")
    require(
        item.findtext(f"{{{SPARKLE}}}minimumSystemVersion") == "14.0",
        f"{path} has an invalid macOS floor",
    )
    for name in ("dataSchemaVersion", "minimumReadableDataSchema", "maximumReadableDataSchema"):
        require(item.findtext(f"{{{DORY}}}{name}") == "1", f"{path} has an invalid Dory data schema contract")
    schema = item.findtext(f"{{{DORY}}}componentCatalogSchema")
    require(schema in {"1", "2"}, f"{path} has an invalid component catalog schema")
    enclosures = item.findall("enclosure")
    require(len(enclosures) == 1, f"{path} does not have one Sparkle enclosure")
    enclosure = enclosures[0]
    parsed = urllib.parse.urlsplit(enclosure.get("url", ""))
    expected_path = f"/Augani/dory/releases/download/v{version}/Dory-{version}-app-update.zip"
    require(
        parsed.scheme == "https"
        and parsed.netloc == "github.com"
        and parsed.path == expected_path
        and not parsed.query
        and not parsed.fragment
        and parsed.username is None
        and parsed.password is None,
        f"{path} has an invalid Sparkle release asset URL",
    )
    length = enclosure.get("length")
    require(length is not None and re.fullmatch(r"[1-9][0-9]*", length) is not None, f"{path} has an invalid Sparkle enclosure length")
    require(enclosure.get("type") == "application/octet-stream", f"{path} has an invalid Sparkle enclosure type")
    try:
        signature = base64.b64decode(enclosure.get(f"{{{SPARKLE}}}edSignature", ""), validate=True)
    except (ValueError, binascii.Error) as error:
        fail(f"{path} has a malformed Sparkle signature: {error}")
    require(len(signature) == 64, f"{path} has an invalid Sparkle signature")
    authority(version, raw, signature, enclosure)
    return int(build), version, int(schema)


def verify_catalog(root: pathlib.Path) -> tuple[str, int]:
    catalog_dir = root / "components" / "arm64"
    catalog_path = catalog_dir / "catalog.json"
    digest_path = catalog_dir / "catalog.json.sha256"
    signature_path = catalog_dir / "catalog.json.sig"
    catalog_bytes = direct_regular_file(catalog_path, 4 * 1024 * 1024)
    digest_bytes = direct_regular_file(digest_path, 65)
    signature_bytes = direct_regular_file(signature_path, 128)
    try:
        digest_text = digest_bytes.decode("ascii")
    except UnicodeError as error:
        fail(f"{digest_path} is not ASCII: {error}")
    require(re.fullmatch(r"[0-9a-f]{64}\n", digest_text) is not None, f"{digest_path} is not one canonical SHA-256 line")
    require(hashlib.sha256(catalog_bytes).hexdigest() == digest_text.rstrip("\n"), f"{digest_path} does not authenticate catalog.json")
    try:
        signature_text = signature_bytes.decode("ascii")
        signature = base64.b64decode(signature_text.rstrip("\n"), validate=True)
        public_key = base64.b64decode(PUBLIC_KEY_BASE64, validate=True)
    except (UnicodeError, ValueError, binascii.Error) as error:
        fail(f"{signature_path} is malformed: {error}")
    require(signature_text == signature_text.rstrip("\n") + "\n", f"{signature_path} is not canonical")
    require(len(signature) == 64 and len(public_key) == 32, f"{signature_path} is not Ed25519")
    with tempfile.TemporaryDirectory(prefix="dory-pages-ed25519-") as temporary_value:
        temporary = pathlib.Path(temporary_value)
        key_path = temporary / "public-key.der"
        signature_raw_path = temporary / "signature.raw"
        key_path.write_bytes(bytes.fromhex("302a300506032b6570032100") + public_key)
        signature_raw_path.write_bytes(signature)
        result = subprocess.run(
            [
                "openssl", "pkeyutl", "-verify", "-pubin", "-inkey", str(key_path),
                "-keyform", "DER", "-rawin", "-in", str(catalog_path),
                "-sigfile", str(signature_raw_path),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
    require(result.returncode == 0, f"{catalog_path} production signature is invalid: {result.stdout.strip()}")
    try:
        catalog = json.loads(catalog_bytes, object_pairs_hook=unique_object)
    except (UnicodeError, json.JSONDecodeError) as error:
        fail(f"{catalog_path} is invalid JSON: {error}")
    canonical = (json.dumps(catalog, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")
    require(canonical == catalog_bytes, f"{catalog_path} is not canonical JSON")
    require(catalog.get("kind") == "dev.dory.component-catalog", f"{catalog_path} has the wrong kind")
    schema = catalog.get("schemaVersion")
    require(schema in {1, 2}, f"{catalog_path} has an unsupported schema")
    require(catalog.get("architecture") == "arm64", f"{catalog_path} has the wrong architecture")
    release_version = catalog.get("releaseVersion")
    semantic_version(release_version, f"{catalog_path} releaseVersion")
    semantic_version(catalog.get("minimumAppVersion"), f"{catalog_path} minimumAppVersion")
    components = catalog.get("components")
    require(isinstance(components, list) and len(components) == len(COMPONENT_IDS), f"{catalog_path} component list is invalid")
    identifiers = [component.get("id") for component in components if isinstance(component, dict)]
    require(len(identifiers) == len(components) and set(identifiers) == COMPONENT_IDS, f"{catalog_path} component identities are not exact")
    require(len(identifiers) == len(set(identifiers)), f"{catalog_path} repeats a component")
    asset_paths: set[str] = set()
    for component in components:
        require(isinstance(component, dict), f"{catalog_path} contains an invalid component")
        identifier = component["id"]
        dependencies = component.get("dependencies")
        require(isinstance(dependencies, list) and len(dependencies) == len(set(dependencies)), f"{identifier} dependencies are invalid")
        require(all(dependency in COMPONENT_IDS and dependency != identifier for dependency in dependencies), f"{identifier} has an invalid dependency")
        assets = component.get("assets")
        require(isinstance(assets, list), f"{identifier} assets are invalid")
        for asset in assets:
            require(isinstance(asset, dict), f"{identifier} has an invalid asset")
            path = asset.get("path")
            require(
                isinstance(path, str)
                and path
                and "\\" not in path
                and not pathlib.PurePosixPath(path).is_absolute()
                and "." not in pathlib.PurePosixPath(path).parts
                and ".." not in pathlib.PurePosixPath(path).parts,
                f"{identifier} has an unsafe asset path",
            )
            require(path not in asset_paths, f"catalog repeats installed asset path {path}")
            asset_paths.add(path)
            for field in ("sha256", "installedSHA256"):
                require(re.fullmatch(r"[0-9a-f]{64}", asset.get(field, "")) is not None, f"{identifier}/{path} has an invalid {field}")
            for field in ("downloadBytes", "installedBytes"):
                require(isinstance(asset.get(field), int) and asset[field] > 0, f"{identifier}/{path} has invalid {field}")
            url = asset.get("url")
            parsed = urllib.parse.urlsplit(url or "")
            expected_prefix = f"/Augani/dory/releases/download/v{release_version}/"
            require(
                parsed.scheme == "https"
                and parsed.netloc == "github.com"
                and parsed.path.startswith(expected_prefix)
                and not parsed.query
                and not parsed.fragment
                and parsed.username is None
                and parsed.password is None,
                f"{identifier}/{path} has an invalid release asset URL",
            )
        if identifier != "docker-core":
            require(assets, f"{identifier} has no downloadable assets")
            require(component.get("downloadBytes") == sum(asset["downloadBytes"] for asset in assets), f"{identifier} download total is invalid")
            require(component.get("installedBytes") == sum(asset["installedBytes"] for asset in assets), f"{identifier} installed total is invalid")
    visiting: set[str] = set()
    visited: set[str] = set()
    by_id = {component["id"]: component for component in components}

    def visit(identifier: str) -> None:
        require(identifier not in visiting, f"catalog dependency cycle includes {identifier}")
        if identifier in visited:
            return
        visiting.add(identifier)
        for dependency in by_id[identifier]["dependencies"]:
            visit(dependency)
        visiting.remove(identifier)
        visited.add(identifier)

    for identifier in identifiers:
        visit(identifier)
    if schema == 2:
        qualification = catalog.get("virtualMachineQualification")
        require(isinstance(qualification, dict), f"{catalog_path} lacks schema-2 qualification metadata")
        require(qualification.get("component") == "linux-desktop", f"{catalog_path} qualification component is invalid")
        require(qualification.get("path") == "virtual-machine-qualification.json", f"{catalog_path} qualification path is invalid")
        require(isinstance(qualification.get("signingKeyID"), str) and qualification["signingKeyID"], f"{catalog_path} qualification key is missing")
        require(isinstance(by_id["linux-desktop"].get("qualification"), list) and by_id["linux-desktop"]["qualification"], f"{catalog_path} has no qualified VM identities")
    require(isinstance(release_version, str), f"{catalog_path} has no release version")
    require(isinstance(schema, int), f"{catalog_path} has no numeric schema")
    return release_version, schema


def verify_root(root: pathlib.Path, label: str, authority: Authority) -> tuple[tuple[int, str, int], tuple[str, int]]:
    appcast = release_item(root / "appcast.xml", authority)
    catalog = verify_catalog(root)
    require(appcast[1] == catalog[0], f"{label} appcast and catalog versions differ")
    require(appcast[2] == catalog[1], f"{label} appcast and catalog schemas differ")
    return appcast, catalog


def transaction_files(root: pathlib.Path) -> tuple[bytes, ...]:
    return (
        direct_regular_file(root / "appcast.xml", 2 * 1024 * 1024),
        *(direct_regular_file(root / "components" / "arm64" / name, 4 * 1024 * 1024) for name in CATALOG_NAMES),
    )


def preserve_metadata(live_root: pathlib.Path, checked_root: pathlib.Path, authority: Authority) -> None:
    live_appcast, live_catalog = verify_root(live_root, "live", authority)
    checked_appcast, checked_catalog = verify_root(checked_root, "checked-in", authority)
    live_semver = semantic_version(live_catalog[0], "live catalog release")
    checked_semver = semantic_version(checked_catalog[0], "checked-in catalog release")
    if live_appcast[0] > checked_appcast[0]:
        require(live_semver > checked_semver, "newer live appcast does not carry a newer catalog release")
        preserve_live = True
    elif live_appcast[0] == checked_appcast[0]:
        require(live_semver == checked_semver, "equal appcast builds disagree on catalog release")
        require(
            transaction_files(live_root) == transaction_files(checked_root),
            "equal release identity has two different signed metadata transactions",
        )
        preserve_live = True
    else:
        require(live_semver < checked_semver, "checked-in appcast build is newer but its catalog is not")
        preserve_live = False
    if preserve_live:
        shutil.copyfile(live_root / "appcast.xml", checked_root / "appcast.xml")
        for name in CATALOG_NAMES:
            shutil.copyfile(live_root / "components" / "arm64" / name, checked_root / "components" / "arm64" / name)
        selected_appcast, selected_catalog = verify_root(checked_root, "preserved live", authority)
        print(f"Preserved live signed release metadata for {selected_catalog[0]} ({selected_appcast[0]}).")
    else:
        print(f"Checked-in release metadata {checked_catalog[0]} ({checked_appcast[0]}) is newer; retaining it.")


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="mode", required=True)
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("root", type=pathlib.Path)
    verify_parser.add_argument("label")
    preserve_parser = subparsers.add_parser("preserve")
    preserve_parser.add_argument("live_root", type=pathlib.Path)
    preserve_parser.add_argument("checked_root", type=pathlib.Path)
    arguments = parser.parse_args()
    github_authority = GitHubReleaseAuthority()
    authority: Authority = github_authority.verify
    if arguments.mode == "verify":
        appcast, catalog = verify_root(arguments.root, arguments.label, authority)
        print(f"Verified {arguments.label} signed release metadata for {catalog[0]} ({appcast[0]}).")
    else:
        preserve_metadata(arguments.live_root, arguments.checked_root, authority)


if __name__ == "__main__":
    main()
