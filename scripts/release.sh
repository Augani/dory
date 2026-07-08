#!/bin/bash
# Dory release pipeline: archive + Developer ID sign -> notarize -> staple -> zip/dmg.
#
# Default release shape:
#   * Dory-<version>-arm64.zip      Apple silicon optimized app
#   * Dory-<version>-x86_64.zip     Intel optimized app
#   * Dory-<version>-universal.zip  Universal app
#   * Dory-<version>.zip            Compatibility alias for the universal app
#
# Requires (one-time, your Apple Developer account -- the external gate):
#   * A "Developer ID Application" certificate in your keychain.
#   * A notarytool keychain profile:  xcrun notarytool store-credentials dory-notary \
#         --apple-id you@example.com --team-id <TEAMID> --password <app-specific-password>
#
# Then:  scripts/release.sh 1.0.0
set -euo pipefail

# Prefer an explicit DEVELOPER_DIR; otherwise pick up a local Xcode install, else fall back to
# the Xcode already selected by xcode-select (CI runners set this themselves).
if [ -z "${DEVELOPER_DIR:-}" ]; then
  for app in /Applications/Xcode.app /Applications/Xcode-*.app "$HOME"/Applications/Xcode*.app; do
    [ -x "$app/Contents/Developer/usr/bin/xcodebuild" ] && { export DEVELOPER_DIR="$app/Contents/Developer"; break; }
  done
fi
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
# Monotonic build number (CFBundleVersion). Sparkle compares this to detect updates. CI passes
# the run number; locally it defaults to 1.
BUILD="${2:-${DORY_BUILD:-1}}"
BUILD_DIR="${DORY_RELEASE_BUILD_DIR:-release-build}"
NOTARY_PROFILE="${DORY_NOTARY_PROFILE:-dory-notary}"
TEAM="${NOTARY_TEAM_ID:-864H636QW4}"
NOTARY_TEAM_ID="${NOTARY_TEAM_ID:-$TEAM}"
RELEASE_VARIANTS="${DORY_RELEASE_VARIANTS:-arm64 x86_64 universal}"
SIGN_IDENTITY="${DORY_SIGN_ID:-Developer ID Application}"

notarize() {
  if [ -n "${NOTARY_APPLE_ID:-}" ]; then
    xcrun notarytool submit "$1" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" --wait
  else
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  fi
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

file_size_bytes() {
  wc -c < "$1" | tr -d '[:space:]'
}

path_if_exists() {
  [ -f "$1" ] && printf '%s' "$1"
}

copy_alias() {
  local source="$1" destination="$2"
  [ -n "$source" ] && [ -f "$source" ] || return 0
  [ "$source" = "$destination" ] && return 0
  rm -f "$destination"
  ln -f "$source" "$destination" 2>/dev/null || cp -p "$source" "$destination"
}

assert_app_binary_arches() {
  local binary="$1" expected="$2" archs arch
  archs="$(lipo -archs "$binary")"
  for arch in $expected; do
    case " $archs " in
      *" $arch "*) ;;
      *) echo "release error: $binary missing $arch (archs: ${archs:-none})" >&2; exit 1 ;;
    esac
  done
  echo "==> Verified app binary for $expected: $archs"
}

configure_variant() {
  local requested="$1"
  VARIANT="$requested"
  case "$requested" in
    arm64|apple-silicon|silicon)
      VARIANT="arm64"
      VARIANT_SUFFIX="arm64"
      XCODE_ARCHS="arm64"
      BUNDLE_ARCHES="arm64"
      HELPER_ARCHES="arm64"
      HOST_CLI_ARCHES="arm64"
      NATIVE_GUEST_ARCH="arm64"
      ;;
    x86_64|amd64|intel)
      VARIANT="x86_64"
      VARIANT_SUFFIX="x86_64"
      XCODE_ARCHS="x86_64"
      BUNDLE_ARCHES="amd64"
      HELPER_ARCHES="x86_64"
      HOST_CLI_ARCHES="x86_64"
      NATIVE_GUEST_ARCH="amd64"
      ;;
    universal|fat)
      VARIANT="universal"
      VARIANT_SUFFIX="universal"
      XCODE_ARCHS="arm64 x86_64"
      BUNDLE_ARCHES="arm64 amd64"
      HELPER_ARCHES="arm64 x86_64"
      HOST_CLI_ARCHES="arm64 x86_64"
      # Compatibility symlinks inside universal bundles are advisory; doryd selects arch-specific
      # resources at runtime from Contents/Resources.
      NATIVE_GUEST_ARCH="${DORY_UNIVERSAL_NATIVE_GUEST_ARCH:-arm64}"
      ;;
    *)
      echo "release error: unknown DORY_RELEASE_VARIANTS entry '$requested' (use arm64, x86_64, universal)" >&2
      exit 1
      ;;
  esac
}

release_error() {
  echo "release error: $*" >&2
  exit 1
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || release_error "required tool '$1' not found"
}

preflight_macos_floor() {
  grep -q 'depends_on macos: :sonoma' Casks/dory.rb \
    || release_error "Homebrew cask must keep macOS 14 Sonoma support"
  for appcast in docs-build/appcast.xml website/public/appcast.xml; do
    [ -f "$appcast" ] || continue
    grep -q '<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>' "$appcast" \
      || release_error "$appcast must advertise Sparkle minimumSystemVersion 14.0"
  done
}

preflight_release() {
  local requested
  echo "==> Release preflight..."
  for tool in xcodebuild codesign xcrun ditto lipo shasum plutil security; do
    require_tool "$tool"
  done
  preflight_macos_floor
  if [ "${DORY_MAKE_DMG:-1}" = "1" ]; then
    require_tool hdiutil
  fi
  if [ -z "$RELEASE_VARIANTS" ]; then
    release_error "DORY_RELEASE_VARIANTS is empty"
  fi
  for requested in $RELEASE_VARIANTS; do
    configure_variant "$requested"
  done

  if [ "${DORY_SKIP_SIGNING_PREFLIGHT:-0}" != "1" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    security find-identity -v -p codesigning | grep -F "$SIGN_IDENTITY" >/dev/null \
      || release_error "codesigning identity '$SIGN_IDENTITY' not found; import the Developer ID Application certificate or set DORY_SKIP_SIGNING_PREFLIGHT=1 for local dry-runs"
  fi

  if [ "${DORY_SKIP_NOTARIZE:-0}" = "1" ]; then
    echo "==> WARNING: notarization disabled by DORY_SKIP_NOTARIZE=1; do not publish these artifacts."
  else
    require_tool spctl
    if [ -n "${NOTARY_APPLE_ID:-}" ] || [ -n "${NOTARY_PASSWORD:-}" ]; then
      [ -n "${NOTARY_APPLE_ID:-}" ] || release_error "NOTARY_APPLE_ID is required when using notarytool environment credentials"
      [ -n "${NOTARY_TEAM_ID:-}" ] || release_error "NOTARY_TEAM_ID is required when using notarytool environment credentials"
      [ -n "${NOTARY_PASSWORD:-}" ] || release_error "NOTARY_PASSWORD is required when using notarytool environment credentials"
    else
      echo "==> Using notarytool keychain profile '$NOTARY_PROFILE' (set NOTARY_APPLE_ID/NOTARY_TEAM_ID/NOTARY_PASSWORD in CI)."
    fi
  fi
}

assert_file_exists() {
  [ -f "$1" ] || release_error "$2 missing: $1"
}

assert_executable_exists() {
  [ -x "$1" ] || release_error "$2 missing or not executable: $1"
}

assert_macho_arches() {
  local binary="$1" expected="$2" archs arch
  assert_executable_exists "$binary" "Mach-O executable"
  archs="$(lipo -archs "$binary" 2>/dev/null || true)"
  [ -n "$archs" ] || release_error "$binary is not a Mach-O binary"
  for arch in $expected; do
    case " $archs " in
      *" $arch "*) ;;
      *) release_error "$binary missing $arch (archs: ${archs:-none})" ;;
    esac
  done
}

verify_codesign() {
  local app="$1"
  echo "==> Verifying code signature for $app..."
  codesign --verify --strict --deep --verbose=2 "$app"
  verify_developer_id_signature "$app"
}

verify_developer_id_signature() {
  local path="$1"
  [ "${DORY_REQUIRE_DEVELOPER_ID_SIGNATURES:-1}" = "1" ] || return 0
  [ "$SIGN_IDENTITY" != "-" ] || return 0
  codesign -dv "$path" 2>&1 | grep -q 'Authority=Developer ID Application' \
    || release_error "$path is not signed by a Developer ID Application certificate"
}

validate_stapled_app() {
  local app="$1"
  echo "==> Validating stapled app ticket + Gatekeeper assessment..."
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=4 "$app"
}

validate_stapled_dmg() {
  local dmg="$1"
  echo "==> Validating stapled DMG ticket + Gatekeeper assessment..."
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg"
}

verify_full_bundle() {
  local app="$1" helpers resources launch_agent asset_arch helper
  helpers="$app/Contents/Helpers"
  resources="$app/Contents/Resources"
  launch_agent="$resources/dev.dory.doryd.plist"

  echo "==> Verifying full clean-Mac bundle payload..."
  for helper in doryd dorydctl dory-vmm dory-network-helper dory-hv dory-vm gvproxy docker docker-compose kubectl dory dory-doctor dory-idle-proxy; do
    assert_executable_exists "$helpers/$helper" "bundled helper"
  done
  for helper in doryd dorydctl dory-vmm dory-network-helper dory-hv dory-vm; do
    assert_macho_arches "$helpers/$helper" "$HELPER_ARCHES"
  done
  for helper in gvproxy docker docker-compose kubectl; do
    assert_macho_arches "$helpers/$helper" "$HOST_CLI_ARCHES"
  done
  for helper in doryd dorydctl dory-vmm dory-network-helper dory-hv dory-vm gvproxy docker docker-compose kubectl dory dory-doctor dory-idle-proxy; do
    verify_developer_id_signature "$helpers/$helper"
  done

  for asset_arch in $BUNDLE_ARCHES; do
    assert_file_exists "$resources/dory-agent-linux-$asset_arch" "guest agent"
    assert_file_exists "$resources/dory-hv-kernel-$asset_arch" "raw dory-hv kernel"
    assert_file_exists "$resources/dory-hv-kernel-$asset_arch.lzfse" "compressed dory-hv kernel"
    assert_file_exists "$resources/dory-machine-rootfs-$asset_arch.ext4" "machine rootfs"
    assert_file_exists "$resources/dory-vm-kernel-$asset_arch.lzfse" "compressed VZ kernel"
    assert_file_exists "$resources/dory-vm-initfs-$asset_arch.ext4.lzfse" "compressed VZ initfs"
  done
  assert_file_exists "$resources/dory-engine-rootfs.ext4.lzfse" "engine rootfs"
  assert_file_exists "$launch_agent" "bundled launchd plist"
  plutil -lint "$launch_agent" >/dev/null
}

sign_app() {
  local app="$1"
  echo "==> Signing $(basename "$(dirname "$app")")/Dory.app (Developer ID + hardened runtime)..."
  # NOT --deep: bundle-engine.sh already signed nested helpers with their own entitlements
  # (dory-hv needs com.apple.security.hypervisor, dory-vm/dory-vmm need virtualization), and --deep
  # would re-sign them without those entitlements.
  codesign --force --options runtime --timestamp --entitlements Dory/Dory.entitlements --sign "$SIGN_IDENTITY" "$app"
}

archive_variant() {
  local variant="$1" archive="$2"
  echo "==> Archiving + signing Dory $VERSION $variant (Developer ID, team $TEAM, archs: $XCODE_ARCHS)..."
  xcodebuild -project Dory.xcodeproj -scheme Dory -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$archive" \
    ARCHS="$XCODE_ARCHS" \
    ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM" \
    archive
}

zip_app() {
  local app="$1" zip="$2"
  rm -f "$zip"
  ditto -c -k --keepParent "$app" "$zip"
}

finish_app_artifact() {
  local app="$1" zip="$2" dmg="$3"
  zip_app "$app" "$zip"
  if [ "${DORY_SKIP_NOTARIZE:-0}" = "1" ]; then
    echo "==> Skipping notarization for $zip (DORY_SKIP_NOTARIZE=1)"
  else
    echo "==> Notarizing $zip..."
    notarize "$zip"
    xcrun stapler staple "$app"
    validate_stapled_app "$app"
    zip_app "$app" "$zip"
  fi

  if [ "${DORY_MAKE_DMG:-1}" = "1" ]; then
    echo "==> Building DMG $dmg..."
    scripts/make-dmg.sh "$app" "$VERSION" "$dmg"
    if [ "${DORY_SKIP_NOTARIZE:-0}" = "1" ]; then
      echo "==> Skipping notarization for $dmg (DORY_SKIP_NOTARIZE=1)"
    else
      echo "==> Notarizing $dmg..."
      notarize "$dmg"
      xcrun stapler staple "$dmg"
      validate_stapled_dmg "$dmg"
    fi
  fi
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

artifact_kind() {
  case "$1" in
    *.dmg) printf '%s' "dmg" ;;
    *.zip) printf '%s' "zip" ;;
    *.tar.gz) printf '%s' "tar.gz" ;;
    *) printf '%s' "file" ;;
  esac
}

write_release_manifest() {
  local manifest="$BUILD_DIR/release-manifest.json" artifact first kind
  first=1
  {
    echo "{"
    echo "  \"schemaVersion\": 1,"
    echo "  \"version\": \"$(json_escape "$VERSION")\","
    echo "  \"build\": \"$(json_escape "$BUILD")\","
    echo "  \"bundleEngine\": $([ "${DORY_BUNDLE_ENGINE:-1}" = "1" ] && echo true || echo false),"
    echo "  \"notarized\": $([ "${DORY_SKIP_NOTARIZE:-0}" = "1" ] && echo false || echo true),"
    echo "  \"variants\": \"$(json_escape "$RELEASE_VARIANTS")\","
    echo "  \"artifacts\": ["
    for artifact in "$@"; do
      [ -n "$artifact" ] && [ -f "$artifact" ] || continue
      kind="$(artifact_kind "$artifact")"
      if [ "$first" -eq 0 ]; then
        echo ","
      fi
      first=0
      printf '    {"name":"%s","path":"%s","kind":"%s","bytes":%s,"sha256":"%s"}' \
        "$(json_escape "$(basename "$artifact")")" \
        "$(json_escape "$artifact")" \
        "$kind" \
        "$(file_size_bytes "$artifact")" \
        "$(sha256_file "$artifact")"
    done
    echo
    echo "  ]"
    echo "}"
  } > "$manifest"
  printf '%s' "$manifest"
}

build_appcast_enabled() {
  local requested="${DORY_BUILD_APPCAST:-}"
  if [ -z "$requested" ]; then
    [ "${DORY_SKIP_NOTARIZE:-0}" = "1" ] && requested="0" || requested="1"
  fi
  case "$requested" in
    0|1) printf '%s' "$requested" ;;
    *) release_error "DORY_BUILD_APPCAST must be 0 or 1" ;;
  esac
}

preflight_release
if [ "${DORY_RELEASE_PREFLIGHT_ONLY:-0}" = "1" ]; then
  echo "==> Preflight-only mode passed."
  exit 0
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

ZIPS=()
DMGS=()
FIRST_ARCHIVE=""
UNIVERSAL_ARCHIVE=""
UNIVERSAL_ZIP=""
UNIVERSAL_DMG=""
ARM64_APP=""

for requested in $RELEASE_VARIANTS; do
  configure_variant "$requested"
  ARCHIVE="$BUILD_DIR/Dory-$VARIANT_SUFFIX.xcarchive"
  EXPORT_DIR="$BUILD_DIR/export-$VARIANT_SUFFIX"
  APP="$EXPORT_DIR/Dory.app"
  ZIP="$BUILD_DIR/Dory-$VERSION-$VARIANT_SUFFIX.zip"
  DMG="$BUILD_DIR/Dory-$VERSION-$VARIANT_SUFFIX.dmg"

  archive_variant "$VARIANT" "$ARCHIVE"
  [ -n "$FIRST_ARCHIVE" ] || FIRST_ARCHIVE="$ARCHIVE"
  [ "$VARIANT" = "universal" ] && UNIVERSAL_ARCHIVE="$ARCHIVE"

  rm -rf "$EXPORT_DIR"
  mkdir -p "$EXPORT_DIR"
  cp -R "$ARCHIVE/Products/Applications/Dory.app" "$EXPORT_DIR/"
  assert_app_binary_arches "$APP/Contents/MacOS/Dory" "$XCODE_ARCHS"

  # Engine bundling is the full-release default: users should be able to install Dory.app on a clean
  # Mac without Docker Desktop, Colima, OrbStack, Homebrew, or Apple `container`.
  if [ "${DORY_BUNDLE_ENGINE:-1}" = "1" ]; then
    echo "==> Bundling the self-contained engine for $VARIANT..."
    DORY_BUNDLE_ARCHES="$BUNDLE_ARCHES" \
    DORY_SWIFTPM_HELPER_ARCHES="$HELPER_ARCHES" \
    DORY_HOST_CLI_ARCHES="$HOST_CLI_ARCHES" \
    DORY_BUNDLE_NATIVE_ARCH="$NATIVE_GUEST_ARCH" \
    DORY_REQUIRE_BUNDLE_ASSETS="${DORY_REQUIRE_BUNDLE_ASSETS:-1}" \
      scripts/bundle-engine.sh "$APP"
  else
    echo "==> WARNING: producing a development app without bundled engine assets for $VARIANT."
  fi

  sign_app "$APP"
  if [ "${DORY_BUNDLE_ENGINE:-1}" = "1" ]; then
    verify_full_bundle "$APP"
  fi
  verify_codesign "$APP"
  finish_app_artifact "$APP" "$ZIP" "$DMG"
  ZIPS+=("$ZIP")
  [ -f "$DMG" ] && DMGS+=("$DMG")

  case "$VARIANT" in
    arm64) ARM64_APP="$APP" ;;
    universal)
      UNIVERSAL_ZIP="$ZIP"
      [ -f "$DMG" ] && UNIVERSAL_DMG="$DMG"
      ;;
  esac
done

# Keep the historic cask/download filenames pointed at the universal artifact.
COMPAT_ZIP=""
COMPAT_DMG=""
if [ -n "$UNIVERSAL_ZIP" ]; then
  COMPAT_ZIP="$BUILD_DIR/Dory-$VERSION.zip"
  copy_alias "$UNIVERSAL_ZIP" "$COMPAT_ZIP"
  ZIPS+=("$COMPAT_ZIP")
fi
if [ -n "$UNIVERSAL_DMG" ]; then
  COMPAT_DMG="$BUILD_DIR/Dory-$VERSION.dmg"
  copy_alias "$UNIVERSAL_DMG" "$COMPAT_DMG"
  DMGS+=("$COMPAT_DMG")
fi

# ---- Extra release flavors ---------------------------------------------------------------
# lite: app only, universal when the universal variant is built.
LITE_ZIP=""
if [ "${DORY_BUNDLE_ENGINE:-1}" = "1" ] && [ "${DORY_BUILD_LITE:-1}" = "1" ]; then
  LITE_ARCHIVE="${UNIVERSAL_ARCHIVE:-$FIRST_ARCHIVE}"
  if [ -n "$LITE_ARCHIVE" ] && [ -d "$LITE_ARCHIVE/Products/Applications/Dory.app" ]; then
    echo "==> Building lite app (no bundled engine)..."
    LITE_DIR="$BUILD_DIR/export-lite"
    LITE_APP="$LITE_DIR/Dory.app"
    rm -rf "$LITE_DIR"
    mkdir -p "$LITE_DIR"
    cp -R "$LITE_ARCHIVE/Products/Applications/Dory.app" "$LITE_DIR/"
    sign_app "$LITE_APP"
    verify_codesign "$LITE_APP"
    LITE_ZIP="$BUILD_DIR/Dory-$VERSION-lite.zip"
    zip_app "$LITE_APP" "$LITE_ZIP"
    if [ "${DORY_SKIP_NOTARIZE:-0}" = "1" ]; then
      echo "==> Skipping notarization for $LITE_ZIP (DORY_SKIP_NOTARIZE=1)"
    else
      echo "==> Notarizing lite app..."
      notarize "$LITE_ZIP"
      xcrun stapler staple "$LITE_APP"
      zip_app "$LITE_APP" "$LITE_ZIP"
    fi
  fi
fi

# Headless runtime stays arm64 for now because scripts/runtime/dory-engine is currently the
# Apple-silicon CLI runtime. The platform-optimized app artifacts above are the primary download
# surface for Intel + universal distribution.
RUNTIME_TAR=""
if [ "${DORY_BUNDLE_ENGINE:-1}" = "1" ] && [ "${DORY_BUILD_RUNTIME:-1}" = "1" ] && [ -n "$ARM64_APP" ]; then
  echo "==> Packaging standalone engine runtime..."
  RUNTIME_NAME="dory-engine-$VERSION-arm64"
  RUNTIME_DIR="$BUILD_DIR/runtime/$RUNTIME_NAME"
  rm -rf "$BUILD_DIR/runtime"
  mkdir -p "$RUNTIME_DIR/bin" "$RUNTIME_DIR/share/dory"
  cp "$ARM64_APP/Contents/Helpers/dory-hv" "$RUNTIME_DIR/bin/"
  cp "$ARM64_APP/Contents/Helpers/gvproxy" "$RUNTIME_DIR/bin/"
  cp "$ARM64_APP/Contents/Resources/dory-hv-kernel-arm64.lzfse" "$RUNTIME_DIR/share/dory/"
  [ -f "$ARM64_APP/Contents/Resources/dory-agent-linux-arm64" ] && cp "$ARM64_APP/Contents/Resources/dory-agent-linux-arm64" "$RUNTIME_DIR/share/dory/"
  [ -f "$ARM64_APP/Contents/Resources/dory-engine-rootfs.ext4.lzfse" ] && cp "$ARM64_APP/Contents/Resources/dory-engine-rootfs.ext4.lzfse" "$RUNTIME_DIR/share/dory/"
  cp scripts/runtime/dory-engine "$RUNTIME_DIR/dory-engine"
  chmod 0755 "$RUNTIME_DIR/dory-engine"
  cat > "$RUNTIME_DIR/README.md" <<EOF
# dory-engine $VERSION (arm64)

Dory's container engine as a standalone, Colima-style runtime: one shared Linux VM running
dockerd, with memory returned to macOS as workloads idle.

    ./dory-engine start          # boots the engine, publishes ~/.dory/engine.sock
    ./dory-engine start --amd64  # also enable x86/amd64 images via QEMU emulation
    docker context use dory-engine
    docker run --rm alpine echo hello

\`dory-engine stop|status|env\` manage it. Requires macOS 14+ on Apple silicon.
EOF
  tar -czf "$BUILD_DIR/$RUNTIME_NAME.tar.gz" -C "$BUILD_DIR/runtime" "$RUNTIME_NAME"
  RUNTIME_TAR="$BUILD_DIR/$RUNTIME_NAME.tar.gz"
fi

DEFAULT_ZIP="${COMPAT_ZIP:-${UNIVERSAL_ZIP:-${ZIPS[0]:-}}}"
DEFAULT_DMG="${COMPAT_DMG:-${UNIVERSAL_DMG:-}}"
DEFAULT_SHA256=""
[ -n "$DEFAULT_ZIP" ] && DEFAULT_SHA256="$(sha256_file "$DEFAULT_ZIP")"

APPCAST=""
if [ "$(build_appcast_enabled)" = "1" ]; then
  [ -n "$DEFAULT_ZIP" ] || release_error "cannot generate Sparkle appcast without a default zip artifact"
  echo "==> Generating Sparkle appcast..."
  APPCAST="$BUILD_DIR/appcast.xml"
  scripts/generate-appcast.sh "$VERSION" "$BUILD" "$DEFAULT_ZIP" "$APPCAST" "website/public/appcast.xml" >/dev/null
  mkdir -p docs-build website/public
  cp "$APPCAST" docs-build/appcast.xml
  cp "$APPCAST" website/public/appcast.xml
  preflight_macos_floor
fi

echo "==> Done."
if [ "${#ZIPS[@]}" -gt 0 ]; then
  for artifact in "${ZIPS[@]}"; do
    [ -n "$artifact" ] && [ -f "$artifact" ] || continue
    echo "    $artifact  (sha256: $(sha256_file "$artifact"))"
  done
fi
if [ "${#DMGS[@]}" -gt 0 ]; then
  for artifact in "${DMGS[@]}"; do
    [ -n "$artifact" ] && [ -f "$artifact" ] || continue
    echo "    $artifact  (sha256: $(sha256_file "$artifact"))"
  done
fi
for artifact in "$LITE_ZIP" "$RUNTIME_TAR"; do
  [ -n "$artifact" ] && [ -f "$artifact" ] || continue
  echo "    $artifact  (sha256: $(sha256_file "$artifact"))"
done

MANIFEST="$(write_release_manifest "${ZIPS[@]}" "${DMGS[@]}" "$LITE_ZIP" "$RUNTIME_TAR" "$APPCAST")"
echo "    $MANIFEST  (release manifest)"
[ -n "$APPCAST" ] && echo "    $APPCAST  (Sparkle appcast)"

# Expose outputs to a GitHub Actions step when running in CI.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "zip=$DEFAULT_ZIP"
    echo "sha256=$DEFAULT_SHA256"
    echo "version=$VERSION"
    echo "build=$BUILD"
    echo "dmg=$DEFAULT_DMG"
    echo "lite=$LITE_ZIP"
    echo "runtime=$RUNTIME_TAR"
    echo "manifest=$MANIFEST"
    echo "appcast=$APPCAST"
    echo "zip_arm64=$(path_if_exists "$BUILD_DIR/Dory-$VERSION-arm64.zip")"
    echo "zip_x86_64=$(path_if_exists "$BUILD_DIR/Dory-$VERSION-x86_64.zip")"
    echo "zip_universal=$(path_if_exists "$BUILD_DIR/Dory-$VERSION-universal.zip")"
    echo "dmg_arm64=$(path_if_exists "$BUILD_DIR/Dory-$VERSION-arm64.dmg")"
    echo "dmg_x86_64=$(path_if_exists "$BUILD_DIR/Dory-$VERSION-x86_64.dmg")"
    echo "dmg_universal=$(path_if_exists "$BUILD_DIR/Dory-$VERSION-universal.dmg")"
  } >> "$GITHUB_OUTPUT"
fi
