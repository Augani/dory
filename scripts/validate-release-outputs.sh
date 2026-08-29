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

[ -d "$BUILD_DIR" ] && [ ! -L "$BUILD_DIR" ] \
  || fail "build directory is missing or indirect: $BUILD_DIR"
BUILD_DIR_LOGICAL="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$BUILD_DIR")"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd -P)"
[ "$BUILD_DIR" = "$BUILD_DIR_LOGICAL" ] || fail "build directory has an indirect ancestor"

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
        if not name or "\\" in name:
            raise SystemExit(f"invalid ZIP member: {name!r}")
        if name in names:
            raise SystemExit(f"duplicate ZIP member: {name!r}")
        names.add(name)
        if path.is_absolute():
            raise SystemExit(f"absolute ZIP member: {name!r}")
        if ".." in path.parts:
            raise SystemExit(f"traversing ZIP member: {name!r}")
        if path.parts[0] != "Dory.app":
            raise SystemExit(f"unexpected top-level ZIP member: {name!r}")
    if "Dory.app/Contents/MacOS/Dory" not in names:
        raise SystemExit("Dory executable is absent")
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
            if os.path.commonpath((root, target)) != str(root):
                raise SystemExit(f"{path} -> {os.readlink(path)}")
PY
}

validate_core_payload_aliases() {
  local app="$1" label="$2" resources kernel_alias rootfs_alias
  resources="$app/Contents/Resources"
  kernel_alias="$resources/dory-vm-kernel-arm64.lzfse"
  rootfs_alias="$resources/dory-vm-initfs-arm64.ext4.lzfse"
  [ -L "$kernel_alias" ] \
    || fail "$label stores a duplicate VZ kernel instead of a Core payload alias"
  [ "$(readlink "$kernel_alias")" = "dory-hv-kernel-arm64.lzfse" ] \
    || fail "$label VZ kernel alias has the wrong target"
  [ -L "$rootfs_alias" ] \
    || fail "$label stores a duplicate VZ rootfs instead of a Core payload alias"
  [ "$(readlink "$rootfs_alias")" = "dory-engine-rootfs-arm64.ext4.lzfse" ] \
    || fail "$label VZ rootfs alias has the wrong target"
  [ -s "$kernel_alias" ] && [ -s "$rootfs_alias" ] \
    || fail "$label Core payload aliases do not resolve to non-empty files"
}

validate_edition() {
  local app="$1" edition="$2" label="$3" expected_flag expected_feed actual_flag actual_feed
  case "$edition" in
    lean)
      expected_flag=false
      expected_feed=https://augani.github.io/dory/appcast.xml
      ;;
    desktop)
      expected_flag=true
      expected_feed=https://augani.github.io/dory/appcast-desktop.xml
      ;;
    *) fail "unknown edition validator: $edition" ;;
  esac
  actual_flag="$(/usr/libexec/PlistBuddy -c 'Print :DoryIncludesDesktopLinux' \
    "$app/Contents/Info.plist" 2>/dev/null || true)"
  actual_feed="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' \
    "$app/Contents/Info.plist" 2>/dev/null || true)"
  [ "$actual_flag" = "$expected_flag" ] \
    || fail "$label has the wrong DoryIncludesDesktopLinux value"
  [ "$actual_feed" = "$expected_feed" ] || fail "$label uses the wrong Sparkle feed"
}

validate_desktop_members() {
  local members="$1" label="$2" member
  for member in \
    Dory.app/Contents/Resources/dory-desktop-kernel-arm64.lzfse \
    Dory.app/Contents/Resources/kernel-build-arm64-desktop.stamp \
    Dory.app/Contents/Resources/dory-desktop-debian-rootfs-arm64.ext4.lzfse \
    Dory.app/Contents/Resources/dory-desktop-debian-build-arm64.stamp \
    Dory.app/Contents/Resources/dory-desktop-debian-packages-arm64.txt \
    Dory.app/Contents/Resources/dory-desktop-ubuntu-rootfs-arm64.ext4.lzfse \
    Dory.app/Contents/Resources/dory-desktop-ubuntu-build-arm64.stamp \
    Dory.app/Contents/Resources/dory-desktop-ubuntu-packages-arm64.txt \
    Dory.app/Contents/Resources/dory-desktop-kali-rootfs-arm64.ext4.lzfse \
    Dory.app/Contents/Resources/dory-desktop-kali-build-arm64.stamp \
    Dory.app/Contents/Resources/dory-desktop-kali-packages-arm64.txt; do
    grep -Fxq "$member" <<< "$members" || fail "$label omits Desktop payload: $member"
  done
}

validate_lean_members() {
  local members="$1" label="$2" member
  for member in \
    Dory.app/Contents/Resources/dory-desktop-kernel-arm64.lzfse \
    Dory.app/Contents/Resources/kernel-build-arm64-desktop.stamp \
    Dory.app/Contents/Resources/dory-desktop-debian-rootfs-arm64.ext4.lzfse \
    Dory.app/Contents/Resources/dory-desktop-ubuntu-rootfs-arm64.ext4.lzfse \
    Dory.app/Contents/Resources/dory-desktop-kali-rootfs-arm64.ext4.lzfse; do
    if grep -Fxq "$member" <<< "$members"; then
      fail "$label unexpectedly contains Desktop payload: $member"
    fi
  done
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
SBOM_SOURCE_COMMIT="$(python3 scripts/validate-release-metadata.py \
  "$BUILD_DIR" "$VERSION" "$BUILD")" \
  || fail "release manifest or appcast metadata is invalid"

COMPONENT_DIR="$BUILD_DIR/components/arm64"
CATALOG_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' \
  "$BUILD_DIR/export-arm64/Dory.app/Contents/Info.plist" 2>/dev/null)" \
  || fail "release app does not contain its component signature trust root"
[ "$CATALOG_PUBLIC_KEY" = "AFetajNbqZty68rRY7OMWYNt6suUsrokQmYMhDJtnP4=" ] \
  || fail "release app component signature trust root is unexpected"

KUBECTL_COMPONENT="$(find "$COMPONENT_DIR" -maxdepth 1 -type f \
  -name "Dory-$VERSION-component-kubernetes-arm64-kubectl" -print)"
[ -n "$KUBECTL_COMPONENT" ] || fail "focused Kubernetes component is missing"
[ "$(lipo -archs "$KUBECTL_COMPONENT")" = arm64 ] \
  || fail "focused Kubernetes component is not arm64-only"
codesign --verify --strict --verbose=2 "$KUBECTL_COMPONENT" \
  || fail "focused Kubernetes component signature is invalid"
if [ "${DORY_RELEASE_OUTPUTS_SKIP_PLATFORM_VALIDATION:-0}" != "1" ]; then
  kubectl_signature="$(codesign -d --verbose=4 "$KUBECTL_COMPONENT" 2>&1)" \
    || fail "could not inspect the focused Kubernetes component signature"
  grep -F 'Authority=Developer ID Application:' <<< "$kubectl_signature" >/dev/null \
    && grep -F "TeamIdentifier=$TEAM" <<< "$kubectl_signature" >/dev/null \
    || fail "focused Kubernetes component is not signed by the expected Developer ID team"
fi

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
validate_core_payload_aliases "$DIRECT_APP" "arm64 ZIP"
validate_edition "$DIRECT_APP" lean "arm64 ZIP"
validate_lean_members "$DIRECT_MEMBERS" "arm64 ZIP"
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
validate_lean_members "$UPDATE_MEMBERS" "Sparkle app-update ZIP"

UPDATE_EXTRACT="$EXTRACT_ROOT/update"
mkdir -p "$UPDATE_EXTRACT"
ditto -x -k "$UPDATE_ZIP" "$UPDATE_EXTRACT" \
  || fail "Sparkle app-update ZIP could not be extracted"
UPDATE_APP="$UPDATE_EXTRACT/Dory.app"
validate_app_symlinks "$UPDATE_APP" "Sparkle app-update ZIP"
validate_core_payload_aliases "$UPDATE_APP" "Sparkle app-update ZIP"
validate_edition "$UPDATE_APP" lean "Sparkle app-update ZIP"
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

APP="$BUILD_DIR/export-arm64/Dory.app"
INFO="$APP/Contents/Info.plist"
validate_core_payload_aliases "$APP" "arm64 release app"
validate_edition "$APP" lean "arm64 release app"
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
[ "$("$APP/Contents/Helpers/dory" version)" = "$VERSION" ] \
  || fail "bundled dory CLI version does not match $VERSION"

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
[ "$(stat -f '%Lp' "$RESOURCES/host-cli-provenance.txt")" = 644 ] \
  || fail "arm64 app host CLI provenance does not use portable mode 0644"
[ -s "$RESOURCES/dory-payload-sha256.txt" ] || fail "arm64 app has no payload digest inventory"
[ -s "$RESOURCES/dory-kernel-build-arm64.stamp" ] || fail "arm64 app has no kernel provenance"
[ -s "$RESOURCES/dory-initfs-build-arm64.stamp" ] || fail "arm64 app has no initfs provenance"
[ ! -e "$RESOURCES/dory-kernel-build-amd64.stamp" ] || fail "arm64 app unexpectedly bundles Intel guest assets"
[ ! -e "$RESOURCES/dory-initfs-build-amd64.stamp" ] || fail "arm64 app unexpectedly bundles Intel initfs assets"
[ -s "$RESOURCES/dory-hv-kernel-gpu-arm64.lzfse" ] || fail "arm64 app has no verified Apple-silicon GPU kernel"
[ -s "$RESOURCES/dory-kernel-build-arm64-gpu.stamp" ] || fail "arm64 app has no Apple-silicon GPU provenance"
for desktop_payload in \
  dory-desktop-kernel-arm64.lzfse \
  kernel-build-arm64-desktop.stamp \
  dory-desktop-debian-rootfs-arm64.ext4.lzfse \
  dory-desktop-ubuntu-rootfs-arm64.ext4.lzfse \
  dory-desktop-kali-rootfs-arm64.ext4.lzfse; do
  [ ! -e "$RESOURCES/$desktop_payload" ] \
    || fail "lean arm64 app unexpectedly contains $desktop_payload"
done
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
require_gvproxy_provenance version v0.8.9-dory2
require_gvproxy_provenance upstream_version v0.8.9
require_gvproxy_provenance source_url \
  https://github.com/containers/gvisor-tap-vsock/archive/refs/tags/v0.8.9.tar.gz
require_gvproxy_provenance source_sha256 \
  6cbcb7959a5d90b59253ea6d8bdf0285e2cfbc3b301398704b41e3069293f4fb
require_gvproxy_provenance patch_sha256 \
  3d6db9d9c2e6ff79b8abd334afe3664c84b84ca11a6308e8cc3d30f8fc05ab96
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
  4517af6ee49549b8b709ea3fa69e219364772f422ef97c940f7ba0a592b07a88
require_gvproxy_provenance amd64_sha256 \
  3907fc0c3431e561c27e10269a265fc7fa6430d6d915cd184dccdc8e29c55855
require_gvproxy_provenance verified_sha256 \
  47c278f1636736ba552de3d2f0e68409cdc968d63bc02149637e449f40274459
require_gvproxy_provenance features native-ipv6-v2,host-route-aware-aaaa-v1,source-preserving-lan-qemu-v1
require_gvproxy_provenance architectures "x86_64 arm64"
require_gvproxy_provenance source pinned-source-build
[ "$("$GVPROXY" -version 2>&1 | tr -d '\r' | sed -n '1p')" = \
  "gvproxy version v0.8.9-dory2" ] \
  || fail "bundled gvproxy does not identify as v0.8.9-dory2"

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
    diskutil image attach --readOnly --nobrowse --plist "$DMG" > "$ATTACH_PLIST"
  fi
  DMG_MOUNT="$(python3 - "$ATTACH_PLIST" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    payload = plistlib.load(handle)
mounts = [row["mount-point"] for row in payload.get("system-entities", []) if row.get("mount-point")]
if len(mounts) != 1:
    raise SystemExit(f"expected one mounted volume, found {mounts}")
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
