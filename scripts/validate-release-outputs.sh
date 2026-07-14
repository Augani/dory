#!/bin/bash
# Fail closed on the exact artifact/update contract consumed by GitHub Releases, Sparkle, and the
# Homebrew cask. Run only after scripts/release.sh has finished every variant.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="${1:?usage: validate-release-outputs.sh <build-dir> <version> <build>}"
VERSION="${2:?usage: validate-release-outputs.sh <build-dir> <version> <build>}"
BUILD="${3:?usage: validate-release-outputs.sh <build-dir> <version> <build>}"
TEAM="${NOTARY_TEAM_ID:-864H636QW4}"

fail() {
  echo "release outputs error: $*" >&2
  exit 1
}

validate_app_zip_layout() {
  local archive="$1" label="$2"
  python3 - "$archive" <<'PY' || fail "$label has an unsafe or unexpected archive layout"
import pathlib
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    names = set()
    for item in archive.infolist():
        name = item.filename
        path = pathlib.PurePosixPath(name)
        assert name and "\\" not in name, f"invalid ZIP member: {name!r}"
        assert name not in names, f"duplicate ZIP member: {name!r}"
        names.add(name)
        assert not path.is_absolute(), f"absolute ZIP member: {name!r}"
        assert ".." not in path.parts, f"traversing ZIP member: {name!r}"
        assert path.parts[0] == "Dory.app", f"unexpected top-level ZIP member: {name!r}"
    assert "Dory.app/Contents/MacOS/Dory" in names, "Dory executable is absent"
PY
}

validate_app_symlinks() {
  local app="$1" label="$2"
  python3 - "$app" <<'PY' || fail "$label contains a symlink that escapes Dory.app"
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
for directory, names, files in os.walk(root, followlinks=False):
    for name in names + files:
        path = pathlib.Path(directory, name)
        if path.is_symlink():
            target = path.resolve(strict=False)
            assert os.path.commonpath((root, target)) == str(root), f"{path} -> {os.readlink(path)}"
PY
}

EXTRACT_ROOT=""
DMG_MOUNT=""
cleanup() {
  if [ -n "$DMG_MOUNT" ]; then
    hdiutil detach "$DMG_MOUNT" -quiet >/dev/null 2>&1 || true
  fi
  [ -z "$EXTRACT_ROOT" ] || rm -rf "$EXTRACT_ROOT"
}
trap cleanup EXIT

required_artifacts=(
  "Dory-$VERSION-arm64.zip"
  "Dory-$VERSION.zip"
  "Dory-$VERSION-arm64.dmg"
  "Dory-$VERSION.dmg"
  "Dory-$VERSION-lite.zip"
  "Dory-$VERSION-app-update.zip"
  "dory-engine-$VERSION-arm64.tar.gz"
  "Dory-$VERSION.cdx.json"
  "appcast.xml"
)

for artifact in "${required_artifacts[@]}"; do
  [ -s "$BUILD_DIR/$artifact" ] || fail "required public artifact is missing or empty: $BUILD_DIR/$artifact"
done
[ -s "$BUILD_DIR/release-manifest.json" ] || fail "release manifest is missing or empty"
[ -d "$BUILD_DIR/export-arm64/Dory.app" ] || fail "arm64 notarized candidate app is missing"
SBOM_SOURCE_COMMIT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sourceCommit"])' \
  "$BUILD_DIR/release-manifest.json")"
scripts/verify-release-sbom.py \
  --sbom "$BUILD_DIR/Dory-$VERSION.cdx.json" \
  --app "$BUILD_DIR/export-arm64/Dory.app" \
  --version "$VERSION" \
  --source-commit "$SBOM_SOURCE_COMMIT" >/dev/null \
  || fail "CycloneDX SBOM does not match the exact shipped app tree"

[ "$(shasum -a 256 "$BUILD_DIR/Dory-$VERSION.zip" | awk '{print $1}')" = \
  "$(shasum -a 256 "$BUILD_DIR/Dory-$VERSION-arm64.zip" | awk '{print $1}')" ] \
  || fail "compatibility ZIP is not byte-identical to the arm64 ZIP"
[ "$(shasum -a 256 "$BUILD_DIR/Dory-$VERSION.dmg" | awk '{print $1}')" = \
  "$(shasum -a 256 "$BUILD_DIR/Dory-$VERSION-arm64.dmg" | awk '{print $1}')" ] \
  || fail "compatibility DMG is not byte-identical to the arm64 DMG"

EXTRACT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dory-release-archives.XXXXXX")"
DIRECT_ZIP="$BUILD_DIR/Dory-$VERSION-arm64.zip"
DIRECT_MEMBERS="$(unzip -Z1 "$DIRECT_ZIP")" || fail "arm64 ZIP is unreadable"
validate_app_zip_layout "$DIRECT_ZIP" "arm64 ZIP"
if printf '%s\n' "$DIRECT_MEMBERS" \
  | grep -Eiq '(^|/)([^/]*(Tests?|UITests)-Runner\.app|[^/]+\.xctest)(/|$)'; then
  fail "arm64 ZIP contains an XCTest runner or test bundle"
fi
DIRECT_EXTRACT="$EXTRACT_ROOT/direct"
mkdir -p "$DIRECT_EXTRACT"
ditto -x -k "$DIRECT_ZIP" "$DIRECT_EXTRACT" || fail "arm64 ZIP could not be extracted"
DIRECT_APP="$DIRECT_EXTRACT/Dory.app"
validate_app_symlinks "$DIRECT_APP" "arm64 ZIP"
scripts/verify-release-sbom.py \
  --sbom "$BUILD_DIR/Dory-$VERSION.cdx.json" \
  --app "$DIRECT_APP" \
  --version "$VERSION" \
  --source-commit "$SBOM_SOURCE_COMMIT" >/dev/null \
  || fail "arm64 ZIP app differs from the SBOM-bound release app tree"

UPDATE_ZIP="$BUILD_DIR/Dory-$VERSION-app-update.zip"
UPDATE_MEMBERS="$(unzip -Z1 "$UPDATE_ZIP")" || fail "Sparkle app-update ZIP is unreadable"
validate_app_zip_layout "$UPDATE_ZIP" "Sparkle app-update ZIP"
if printf '%s\n' "$UPDATE_MEMBERS" \
  | grep -Eiq '(^|/)([^/]*(Tests?|UITests)-Runner\.app|[^/]+\.xctest)(/|$)'; then
  fail "Sparkle app-update ZIP contains an XCTest runner or test bundle"
fi
for member in \
  Dory.app/Contents/Resources/dory-hv-kernel-gpu-arm64.lzfse \
  Dory.app/Contents/Resources/dory-kernel-build-arm64-gpu.stamp \
  Dory.app/Contents/Resources/dory-transfer-helper-image-arm64.tar \
  Dory.app/Contents/Resources/dory-transfer-helper-image-arm64.json \
  Dory.app/Contents/Resources/dory-payload-sha256.txt \
  Dory.app/Contents/Helpers/dory-dataplane-proxy \
  Dory.app/Contents/Helpers/docker-buildx \
  Dory.app/Contents/Library/LaunchDaemons/dev.dory.network-helper.plist; do
  grep -Fxq "$member" <<< "$UPDATE_MEMBERS" \
    || fail "Sparkle app-update ZIP omits required self-contained payload: $member"
done

UPDATE_EXTRACT="$EXTRACT_ROOT/update"
mkdir -p "$UPDATE_EXTRACT"
ditto -x -k "$UPDATE_ZIP" "$UPDATE_EXTRACT" \
  || fail "Sparkle app-update ZIP could not be extracted"
UPDATE_APP="$UPDATE_EXTRACT/Dory.app"
validate_app_symlinks "$UPDATE_APP" "Sparkle app-update ZIP"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$UPDATE_APP/Contents/Info.plist")" = "$VERSION" ] \
  || fail "Sparkle app-update marketing version does not match $VERSION"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "$UPDATE_APP/Contents/Info.plist")" = "$BUILD" ] \
  || fail "Sparkle app-update build does not match $BUILD"
scripts/verify-release-sbom.py \
  --sbom "$BUILD_DIR/Dory-$VERSION.cdx.json" \
  --app "$UPDATE_APP" \
  --version "$VERSION" \
  --source-commit "$SBOM_SOURCE_COMMIT" >/dev/null \
  || fail "Sparkle app-update differs from the SBOM-bound direct app tree"

LITE_ZIP="$BUILD_DIR/Dory-$VERSION-lite.zip"
LITE_MEMBERS="$(unzip -Z1 "$LITE_ZIP")" || fail "lite ZIP is unreadable"
validate_app_zip_layout "$LITE_ZIP" "lite ZIP"
if printf '%s\n' "$LITE_MEMBERS" \
  | grep -Eiq '(^|/)([^/]*(Tests?|UITests)-Runner\.app|[^/]+\.xctest)(/|$)'; then
  fail "lite ZIP contains an XCTest runner or test bundle"
fi
for forbidden in \
  Dory.app/Contents/Helpers/doryd \
  Dory.app/Contents/Helpers/dory-hv \
  Dory.app/Contents/Resources/dory-engine-rootfs.ext4.lzfse \
  Dory.app/Contents/Resources/dory-payload-sha256.txt; do
  if grep -Fxq "$forbidden" <<< "$LITE_MEMBERS"; then
    fail "lite ZIP unexpectedly contains bundled engine payload: $forbidden"
  fi
done

LITE_EXTRACT="$EXTRACT_ROOT/lite"
mkdir -p "$LITE_EXTRACT"
ditto -x -k "$LITE_ZIP" "$LITE_EXTRACT" \
  || fail "lite ZIP could not be extracted"
LITE_APP="$LITE_EXTRACT/Dory.app"
validate_app_symlinks "$LITE_APP" "lite ZIP"
LITE_INFO="$LITE_APP/Contents/Info.plist"
[ -x "$LITE_APP/Contents/MacOS/Dory" ] || fail "lite ZIP has no executable Dory app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$LITE_INFO")" = "$VERSION" ] \
  || fail "lite app marketing version does not match $VERSION"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$LITE_INFO")" = "$BUILD" ] \
  || fail "lite app build does not match $BUILD"

python3 - "$BUILD_DIR" "$VERSION" "$BUILD" <<'PY'
import base64
import email.utils
import hashlib
import json
import os
import re
import sys
import urllib.parse
import xml.etree.ElementTree as ET

build_dir, version, build = sys.argv[1:4]

def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

manifest_path = os.path.join(build_dir, "release-manifest.json")
with open(manifest_path, encoding="utf-8") as handle:
    manifest = json.load(handle)

assert manifest.get("schemaVersion") == 2, "unexpected release manifest schema"
assert manifest.get("version") == version, "manifest version mismatch"
assert str(manifest.get("build")) == build, "manifest build mismatch"
source_commit = manifest.get("sourceCommit")
assert isinstance(source_commit, str) and len(source_commit) == 40 \
    and all(character in "0123456789abcdef" for character in source_commit), \
    "manifest sourceCommit is not a full lowercase Git SHA"
assert manifest.get("publicRelease") is True, "manifest is not marked as a public release"
assert manifest.get("bundleEngine") is True, "manifest describes an app-only release"
assert manifest.get("notarized") is True, "manifest describes an unnotarized release"
assert manifest.get("variants") == "arm64", "manifest is not Apple-Silicon-only"

required = {
    f"Dory-{version}-arm64.zip",
    f"Dory-{version}.zip",
    f"Dory-{version}-arm64.dmg",
    f"Dory-{version}.dmg",
    f"Dory-{version}-lite.zip",
    f"Dory-{version}-app-update.zip",
    f"dory-engine-{version}-arm64.tar.gz",
    f"Dory-{version}.cdx.json",
    "appcast.xml",
}
records = manifest.get("artifacts")
assert isinstance(records, list) and records, "manifest has no artifacts"
by_name = {record.get("name"): record for record in records}
assert len(by_name) == len(records), "manifest contains duplicate artifact names"
missing = required - set(by_name)
assert not missing, f"manifest omits required artifacts: {sorted(missing)}"
unexpected = set(by_name) - required
assert not unexpected, f"manifest contains unexpected public artifacts: {sorted(unexpected)}"
for name, record in by_name.items():
    recorded_path = record.get("path")
    assert recorded_path == name, f"manifest path must be a portable artifact filename: {name}: {recorded_path}"
    path = os.path.join(build_dir, name)
    assert os.path.isfile(path), f"manifest artifact is missing: {name}: {path}"
    size = os.path.getsize(path)
    assert record.get("bytes") == size, f"manifest byte count mismatch: {name}"
    digest = sha256_file(path)
    assert record.get("sha256") == digest, f"manifest SHA-256 mismatch: {name}"

sbom_record = by_name[f"Dory-{version}.cdx.json"]
assert sbom_record.get("kind") == "cyclonedx-json", "SBOM artifact kind mismatch"

sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
root = ET.parse(os.path.join(build_dir, "appcast.xml")).getroot()
assert root.tag == "rss" and root.attrib.get("version") == "2.0", "appcast root is invalid"
channel = root.find("channel")
assert channel is not None, "appcast has no channel"
assert channel.findtext("title") == "Dory", "appcast channel identity mismatch"
assert channel.findtext("link") == "https://augani.github.io/dory/appcast.xml", "appcast link mismatch"
items = channel.findall("item")
assert items, "appcast has no current item"
item = items[0]
assert item.findtext(f"{{{sparkle}}}version") == build, "appcast build mismatch"
assert item.findtext(f"{{{sparkle}}}shortVersionString") == version, "appcast version mismatch"
expected_name = f"Dory-{version}-app-update.zip"
artifact_path = os.path.join(build_dir, expected_name)
seen_builds = set()
seen_versions = set()
for index, release_item in enumerate(items):
    release_build = release_item.findtext(f"{{{sparkle}}}version", "")
    release_version = release_item.findtext(f"{{{sparkle}}}shortVersionString", "")
    assert release_build.isdigit() and int(release_build) > 0, "appcast item build is invalid"
    assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?", release_version), \
        "appcast item version is invalid"
    assert release_build not in seen_builds, f"duplicate appcast build: {release_build}"
    assert release_version not in seen_versions, f"duplicate appcast version: {release_version}"
    seen_builds.add(release_build)
    seen_versions.add(release_version)
    assert release_item.findtext(f"{{{sparkle}}}minimumSystemVersion") == "14.0", \
        f"appcast {release_version} macOS floor mismatch"
    publication_date = release_item.findtext("pubDate", "")
    assert email.utils.parsedate_to_datetime(publication_date).tzinfo is not None, \
        f"appcast {release_version} publication date is invalid"
    enclosure = release_item.find("enclosure")
    assert enclosure is not None, f"appcast {release_version} item has no enclosure"
    parsed_url = urllib.parse.urlparse(enclosure.attrib.get("url", ""))
    actual_name = os.path.basename(parsed_url.path)
    expected_prefix = f"/Augani/dory/releases/download/v{release_version}/"
    assert parsed_url.scheme == "https" and parsed_url.netloc == "github.com", \
        f"appcast {release_version} enclosure is not on GitHub"
    assert parsed_url.path.startswith(expected_prefix), \
        f"appcast {release_version} enclosure is outside its versioned Dory release"
    assert actual_name.startswith(f"Dory-{release_version}") and actual_name.endswith(".zip"), \
        f"appcast {release_version} enclosure filename is invalid"
    assert enclosure.attrib.get("type") == "application/octet-stream", \
        f"appcast {release_version} enclosure type is invalid"
    length = enclosure.attrib.get("length", "")
    assert length.isdigit() and int(length) > 0, f"appcast {release_version} length is invalid"
    signature = enclosure.attrib.get(f"{{{sparkle}}}edSignature", "")
    try:
        decoded = base64.b64decode(signature, validate=True)
    except Exception as error:
        raise AssertionError(f"appcast {release_version} EdDSA signature is invalid: {error}") from error
    assert len(decoded) == 64, \
        f"appcast {release_version} EdDSA signature decoded to {len(decoded)} bytes, expected 64"
    if index == 0:
        assert actual_name == expected_name, \
            f"appcast points at {actual_name!r}, expected {expected_name!r}"
        assert length == str(os.path.getsize(artifact_path)), "appcast length mismatch"
    else:
        assert int(release_build) < int(build), \
            f"historical appcast build {release_build} is not older than {build}"
PY

APP="$BUILD_DIR/export-arm64/Dory.app"
INFO="$APP/Contents/Info.plist"
NETWORK_HELPER="$APP/Contents/Helpers/dory-network-helper"
NETWORK_DAEMON_PLIST="$APP/Contents/Library/LaunchDaemons/dev.dory.network-helper.plist"
test_payload="$(find "$APP" \
  \( -type d -iname '*Tests-Runner.app' -o -type d -iname '*UITests-Runner.app' \
     -o -type d -iname '*.xctest' \) -print -quit)"
[ -z "$test_payload" ] \
  || fail "arm64 public app contains a test-only bundle: $test_payload"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")" = "$VERSION" ] \
  || fail "arm64 app marketing version does not match $VERSION"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")" = "$BUILD" ] \
  || fail "arm64 app build does not match $BUILD"

[ -x "$NETWORK_HELPER" ] || fail "arm64 app has no privileged network helper"
[ -s "$NETWORK_DAEMON_PLIST" ] || fail "arm64 app has no privileged network daemon plist"
plutil -lint "$NETWORK_DAEMON_PLIST" >/dev/null \
  || fail "privileged network daemon plist is invalid"
[ "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$NETWORK_DAEMON_PLIST" 2>/dev/null)" = \
  "Contents/Helpers/dory-network-helper" ] \
  || fail "privileged network daemon BundleProgram is invalid"
[ "$(/usr/libexec/PlistBuddy -c 'Print :MachServices:dev.dory.network-helper' "$NETWORK_DAEMON_PLIST" 2>/dev/null)" = \
  "true" ] \
  || fail "privileged network daemon Mach service is missing"

RESOURCES="$APP/Contents/Resources"
GVPROXY="$APP/Contents/Helpers/gvproxy"
GVPROXY_PROVENANCE="$RESOURCES/gvproxy-provenance.txt"
[ -x "$GVPROXY" ] || fail "arm64 app has no executable gvproxy helper"
[ -s "$GVPROXY_PROVENANCE" ] || fail "arm64 app has no gvproxy provenance"
[ -s "$RESOURCES/host-cli-provenance.txt" ] || fail "arm64 app has no host CLI provenance"
[ -s "$RESOURCES/dory-payload-sha256.txt" ] || fail "arm64 app has no payload digest inventory"
[ -s "$RESOURCES/dory-kernel-build-arm64.stamp" ] || fail "arm64 app has no kernel provenance"
[ -s "$RESOURCES/dory-initfs-build-arm64.stamp" ] || fail "arm64 app has no initfs provenance"
[ ! -e "$RESOURCES/dory-kernel-build-amd64.stamp" ] || fail "arm64 app unexpectedly bundles Intel guest assets"
[ ! -e "$RESOURCES/dory-initfs-build-amd64.stamp" ] || fail "arm64 app unexpectedly bundles Intel initfs assets"
[ -s "$RESOURCES/dory-hv-kernel-gpu-arm64.lzfse" ] || fail "arm64 app has no verified Apple-silicon GPU kernel"
[ -s "$RESOURCES/dory-kernel-build-arm64-gpu.stamp" ] || fail "arm64 app has no Apple-silicon GPU provenance"
[ -s "$RESOURCES/dory-transfer-helper-image-arm64.tar" ] \
  || fail "arm64 app has no named-volume transfer helper image"
[ -s "$RESOURCES/dory-transfer-helper-image-arm64.json" ] \
  || fail "arm64 app has no named-volume transfer helper metadata"
TRANSFER_HELPER_SHA256="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["helperSha256"])' \
  "$RESOURCES/dory-transfer-helper-image-arm64.json")" \
  || fail "transfer-helper metadata is invalid"
TRANSFER_VERIFIED_METADATA="$(python3 scripts/build-transfer-helper-image.py \
  --verify "$RESOURCES/dory-transfer-helper-image-arm64.tar" \
  --expected-helper-sha256 "$TRANSFER_HELPER_SHA256")" \
  || fail "named-volume transfer helper image is invalid"
[ "$TRANSFER_VERIFIED_METADATA" = "$(tr -d '\n' < "$RESOURCES/dory-transfer-helper-image-arm64.json")" ] \
  || fail "transfer-helper metadata does not describe the exact archive"
[ "$(shasum -a 256 "$RESOURCES/dory-transfer-helper-image-arm64.tar" | awk '{print $1}')" = \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["archiveSha256"])' \
    "$RESOURCES/dory-transfer-helper-image-arm64.json")" ] \
  || fail "transfer-helper image archive digest does not match its metadata"
(cd "$APP" && shasum -a 256 -c Contents/Resources/dory-payload-sha256.txt >/dev/null) \
  || fail "arm64 app payload digest inventory does not match"

# A release must contain the audited, reproducible Dory dual-stack derivative. Merely recording a
# provenance file is insufficient: every identity field is singular and exact, and the signed
# helper must still self-identify as that derivative. These pins intentionally require an explicit
# validator update whenever the upstream source or Dory patch changes.
gvproxy_provenance_value() {
  local key="$1"
  awk -v key="$key" '
    index($0, key "=") == 1 { count += 1; value = substr($0, length(key) + 2) }
    END { if (count == 1) print value; else exit 1 }
  ' "$GVPROXY_PROVENANCE"
}
require_gvproxy_provenance() {
  local key="$1" expected="$2" actual
  actual="$(gvproxy_provenance_value "$key")" \
    || fail "gvproxy provenance must contain exactly one $key entry"
  [ "$actual" = "$expected" ] \
    || fail "gvproxy provenance $key mismatch (expected $expected, got ${actual:-empty})"
}
require_gvproxy_provenance version v0.8.9-dory1
require_gvproxy_provenance upstream_version v0.8.9
require_gvproxy_provenance source_url \
  https://github.com/containers/gvisor-tap-vsock/archive/refs/tags/v0.8.9.tar.gz
require_gvproxy_provenance source_sha256 \
  6cbcb7959a5d90b59253ea6d8bdf0285e2cfbc3b301398704b41e3069293f4fb
require_gvproxy_provenance patch_sha256 \
  ca76b2a8a304aa4b3aba835543f325832de83a14163f6b86b37491cc165e2ce3
require_gvproxy_provenance go_toolchain go1.26.5
require_gvproxy_provenance go_mod_sha256 \
  75848c190dca5cc7af27ebe017d5a4d59d4a117c97eaa6b8ac0359e58d868eec
require_gvproxy_provenance go_sum_sha256 \
  25b1a52ad3181030b6ccf92af5d69a1a4282f8f2342dad5348b5c954c304c4b3
require_gvproxy_provenance go_proxy https://proxy.golang.org
require_gvproxy_provenance go_sumdb sum.golang.org
require_gvproxy_provenance go_arm64 v8.0
require_gvproxy_provenance go_amd64 v1
require_gvproxy_provenance fat_x86_64_segalign 0x1000
require_gvproxy_provenance fat_arm64_segalign 0x4000
require_gvproxy_provenance arm64_sha256 \
  98f142909b2ba839e87bf8c4cf61e9a20f79d5c9ea1158930240d63dcaee380b
require_gvproxy_provenance amd64_sha256 \
  3d2d55b482e7c47033d2f956141b569c0d00861947038173a23e3b08c132c4f0
require_gvproxy_provenance verified_sha256 \
  bd9183f5dbe2bd27d7ea57f2f2dd4d5ce26487eeb1fa8c82cd81bad4df50e0c0
require_gvproxy_provenance features native-ipv6-v1,source-preserving-lan-qemu-v1
require_gvproxy_provenance architectures "x86_64 arm64"
require_gvproxy_provenance source pinned-source-build
[ "$("$GVPROXY" -version 2>&1 | tr -d '\r' | sed -n '1p')" = \
  "gvproxy version v0.8.9-dory1" ] \
  || fail "bundled gvproxy does not identify as v0.8.9-dory1"

if [ "${DORY_RELEASE_OUTPUTS_SKIP_PLATFORM_VALIDATION:-0}" != "1" ]; then
  DMG="$BUILD_DIR/Dory-$VERSION-arm64.dmg"
  [ "$(lipo -archs "$GVPROXY")" = "x86_64 arm64" ] \
    || fail "bundled gvproxy architecture contract changed"
  scripts/verify-distribution-signatures.sh "$APP" "$TEAM"
  codesign --verify --strict --verbose=2 "$NETWORK_HELPER"
  xcrun stapler validate "$APP"
  app_assessment="$(spctl --assess --type execute --verbose=4 "$APP" 2>&1)" \
    || fail "Gatekeeper rejected arm64 app"
  printf '%s\n' "$app_assessment"
  grep -Fx 'source=Notarized Developer ID' <<< "$app_assessment" >/dev/null \
    || fail "arm64 app is not accepted as Notarized Developer ID"

  scripts/verify-distribution-signatures.sh "$DIRECT_APP" "$TEAM"
  xcrun stapler validate "$DIRECT_APP"
  direct_assessment="$(spctl --assess --type execute --verbose=4 "$DIRECT_APP" 2>&1)" \
    || fail "Gatekeeper rejected the extracted arm64 ZIP app"
  printf '%s\n' "$direct_assessment"
  grep -Fx 'source=Notarized Developer ID' <<< "$direct_assessment" >/dev/null \
    || fail "extracted arm64 ZIP app is not accepted as Notarized Developer ID"

  scripts/verify-distribution-signatures.sh "$UPDATE_APP" "$TEAM"
  xcrun stapler validate "$UPDATE_APP"
  update_assessment="$(spctl --assess --type execute --verbose=4 "$UPDATE_APP" 2>&1)" \
    || fail "Gatekeeper rejected Sparkle app-update"
  printf '%s\n' "$update_assessment"
  grep -Fx 'source=Notarized Developer ID' <<< "$update_assessment" >/dev/null \
    || fail "Sparkle app-update is not accepted as Notarized Developer ID"

  scripts/verify-distribution-signatures.sh "$LITE_APP" "$TEAM"
  xcrun stapler validate "$LITE_APP"
  lite_assessment="$(spctl --assess --type execute --verbose=4 "$LITE_APP" 2>&1)" \
    || fail "Gatekeeper rejected lite app"
  printf '%s\n' "$lite_assessment"
  grep -Fx 'source=Notarized Developer ID' <<< "$lite_assessment" >/dev/null \
    || fail "lite app is not accepted as Notarized Developer ID"

  codesign --verify --strict --verbose=2 "$DMG" \
    || fail "arm64 DMG signature is invalid"
  dmg_codesign="$(codesign -d --verbose=4 "$DMG" 2>&1)" \
    || fail "could not inspect arm64 DMG signature"
  grep -F 'Authority=Developer ID Application:' <<< "$dmg_codesign" >/dev/null \
    || fail "arm64 DMG is not Developer ID signed"
  grep -F "TeamIdentifier=$TEAM" <<< "$dmg_codesign" >/dev/null \
    || fail "arm64 DMG is signed by the wrong team"
  grep -E '^Timestamp=' <<< "$dmg_codesign" >/dev/null \
    || fail "arm64 DMG signature has no secure timestamp"
  xcrun stapler validate "$DMG"
  dmg_assessment="$(spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG" 2>&1)" \
    || fail "Gatekeeper rejected arm64 DMG"
  printf '%s\n' "$dmg_assessment"
  grep -Fx 'source=Notarized Developer ID' <<< "$dmg_assessment" >/dev/null \
    || fail "arm64 DMG is not accepted as Notarized Developer ID"

  ATTACH_PLIST="$EXTRACT_ROOT/dmg-attach.plist"
  if command -v diskutil >/dev/null 2>&1 \
    && diskutil image attach --help >/dev/null 2>&1; then
    diskutil image attach --readOnly --nobrowse --plist "$DMG" > "$ATTACH_PLIST"
  else
    hdiutil attach -readonly -nobrowse -plist "$DMG" > "$ATTACH_PLIST"
  fi
  DMG_MOUNT="$(python3 - "$ATTACH_PLIST" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    payload = plistlib.load(handle)
mounts = [row["mount-point"] for row in payload.get("system-entities", []) if row.get("mount-point")]
assert len(mounts) == 1, f"expected one mounted volume, found {mounts}"
print(mounts[0])
PY
)" || fail "could not identify the mounted DMG volume"
  [ -d "$DMG_MOUNT/Dory.app" ] || fail "mounted DMG has no Dory.app"
  [ "$(find "$DMG_MOUNT" -maxdepth 1 -type d -name Dory.app -print | wc -l | tr -d ' ')" = 1 ] \
    || fail "mounted DMG does not contain exactly one Dory.app"
  [ -L "$DMG_MOUNT/Applications" ] \
    && [ "$(readlink "$DMG_MOUNT/Applications")" = /Applications ] \
    || fail "mounted DMG has no Applications shortcut"
  mount | grep -F " on $DMG_MOUNT (" | grep -F 'read-only' >/dev/null \
    || fail "release DMG did not mount read-only"
  MOUNTED_APP="$DMG_MOUNT/Dory.app"
  validate_app_symlinks "$MOUNTED_APP" "mounted DMG app"
  scripts/verify-release-sbom.py \
    --sbom "$BUILD_DIR/Dory-$VERSION.cdx.json" \
    --app "$MOUNTED_APP" \
    --version "$VERSION" \
    --source-commit "$SBOM_SOURCE_COMMIT" >/dev/null \
    || fail "mounted DMG app differs from the SBOM-bound direct app tree"
  scripts/verify-distribution-signatures.sh "$MOUNTED_APP" "$TEAM"
  xcrun stapler validate "$MOUNTED_APP"
  mounted_assessment="$(spctl --assess --type execute --verbose=4 "$MOUNTED_APP" 2>&1)" \
    || fail "Gatekeeper rejected the app inside the mounted DMG"
  printf '%s\n' "$mounted_assessment"
  grep -Fx 'source=Notarized Developer ID' <<< "$mounted_assessment" >/dev/null \
    || fail "mounted DMG app is not accepted as Notarized Developer ID"
  hdiutil detach "$DMG_MOUNT" -quiet
  DMG_MOUNT=""
fi

echo "release outputs: PASS ($VERSION build $BUILD)"
