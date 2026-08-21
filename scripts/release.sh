#!/bin/bash
# Dory release pipeline: archive + Developer ID sign -> notarize -> staple -> zip/dmg.
#
# Default release shape (Apple Silicon first):
#   * Dory-<version>-arm64.zip      Apple silicon app
#   * Dory-<version>.zip            Compatibility alias for the arm64 app
# Intel/universal variants remain available for development builds but are not public defaults.
#
# Requires (one-time, your Apple Developer account -- the external gate):
#   * A "Developer ID Application" certificate in your keychain.
#   * A notarytool keychain profile:  xcrun notarytool store-credentials dory-notary \
#         --apple-id you@example.com --team-id <TEAMID> --password <app-specific-password>
#
# Then:  scripts/release.sh 1.0.0 42
set -euo pipefail

# Prefer an explicit DEVELOPER_DIR; otherwise pick up a local Xcode install, else fall back to
# the Xcode already selected by xcode-select (CI runners set this themselves).
if [ -z "${DEVELOPER_DIR:-}" ]; then
  for app in /Applications/Xcode-26.6.0-Release.Candidate.app \
             /Applications/Xcode_26.6.app /Applications/Xcode_26.6.0.app \
             /Applications/Xcode.app /Applications/Xcode-*.app "$HOME"/Applications/Xcode*.app; do
    [ -x "$app/Contents/Developer/usr/bin/xcodebuild" ] && { export DEVELOPER_DIR="$app/Contents/Developer"; break; }
  done
fi
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$(pwd -P)"

VERSION="${1:-}"
BUILD="${2:-${DORY_BUILD:-}}"
if [ -z "$VERSION" ] || [ -z "$BUILD" ]; then
  echo "usage: scripts/release.sh <version> <monotonic-build-number>" >&2
  exit 64
fi
BUILD_DIR="${DORY_RELEASE_BUILD_DIR:-release-build}"
NOTARY_PROFILE="${DORY_NOTARY_PROFILE:-dory-notary}"
TEAM="${NOTARY_TEAM_ID:-864H636QW4}"
NOTARY_TEAM_ID="${NOTARY_TEAM_ID:-$TEAM}"
RELEASE_VARIANTS="${DORY_RELEASE_VARIANTS:-arm64}"
SIGN_IDENTITY="${DORY_SIGN_ID:-Developer ID Application}"
SOURCE_COMMIT="${DORY_RELEASE_SOURCE_COMMIT:-$(git rev-parse HEAD 2>/dev/null || true)}"
HOMEBREW_CASK="${DORY_HOMEBREW_CASK:-Casks/dory.rb}"
DERIVED_DATA_DIR=""

notarize() {
  if [ -n "${NOTARY_APPLE_ID:-}" ]; then
    xcrun notarytool submit "$1" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" --wait
  else
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  fi
}

validate_notary_credentials() {
  if [ -n "${NOTARY_APPLE_ID:-}" ]; then
    echo "==> Validating notarytool environment credentials..."
    xcrun notarytool history \
      --apple-id "$NOTARY_APPLE_ID" \
      --team-id "$NOTARY_TEAM_ID" \
      --password "$NOTARY_PASSWORD" \
      --output-format json >/dev/null 2>&1 \
      || release_error "notarytool environment credentials are unavailable or invalid"
  else
    echo "==> Validating notarytool keychain profile '$NOTARY_PROFILE'..."
    xcrun notarytool history \
      --keychain-profile "$NOTARY_PROFILE" \
      --output-format json >/dev/null 2>&1 \
      || release_error "notarytool keychain profile '$NOTARY_PROFILE' is unavailable or invalid; configure it with 'xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id $NOTARY_TEAM_ID'"
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

validate_release_build_dir() {
  local logical parent physical_parent name candidate
  logical="$(python3 - "$BUILD_DIR" <<'PY'
import os
import sys

print(os.path.abspath(sys.argv[1]))
PY
)"
  parent="$(dirname "$logical")"
  name="$(basename "$logical")"
  case "$name" in
    release-build*) ;;
    *) release_error "DORY_RELEASE_BUILD_DIR must be a dedicated release-build* directory: $logical" ;;
  esac
  [ -d "$parent" ] && [ ! -L "$parent" ] \
    || release_error "release build parent must be a direct directory: $parent"
  physical_parent="$(cd "$parent" && pwd -P)"
  [ "$parent" = "$physical_parent" ] \
    || release_error "release build parent has an indirect ancestor: $parent"
  [ "$physical_parent" = "$REPO_ROOT" ] \
    || release_error "release build directory must be a direct child of the checkout: $logical"
  candidate="$physical_parent/$name"
  if [ -e "$candidate" ] || [ -L "$candidate" ]; then
    [ -d "$candidate" ] && [ ! -L "$candidate" ] \
      || release_error "release build authority must be a direct directory: $candidate"
    [ "$(stat -f '%u' "$candidate")" = "$(id -u)" ] \
      || release_error "release build authority is not owned by this user: $candidate"
  fi
  BUILD_DIR="$candidate"
  DERIVED_DATA_DIR="$BUILD_DIR/DerivedData"
}

preflight_macos_floor() {
  [ -f "$HOMEBREW_CASK" ] \
    || release_error "Homebrew cask is missing: $HOMEBREW_CASK"
  grep -q 'depends_on macos: :sonoma' "$HOMEBREW_CASK" \
    || release_error "Homebrew cask must keep macOS 14 Sonoma support"
  for appcast in \
    docs-build/appcast.xml docs-build/appcast-desktop.xml \
    website/public/appcast.xml website/public/appcast-desktop.xml; do
    [ -f "$appcast" ] || continue
    grep -q '<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>' "$appcast" \
      || release_error "$appcast must advertise Sparkle minimumSystemVersion 14.0"
  done
}

preflight_public_toolchain() {
  local version
  version="$(xcodebuild -version)"
  printf '%s\n' "$version" | grep -Fx 'Xcode 26.6' >/dev/null \
    || release_error "public releases require the pinned Xcode 26.6 toolchain"
  printf '%s\n' "$version" | grep -Eq '^Build version 17F(109|113)$' \
    || release_error "public releases require approved Xcode 26.6 build 17F109 or 17F113"
}

preflight_public_release() {
  [ "${DORY_PUBLIC_RELEASE:-0}" = "1" ] || return 0

  [ "$TEAM" = 864H636QW4 ] && [ "$NOTARY_TEAM_ID" = 864H636QW4 ] \
    || release_error "public releases must use Dory signing team 864H636QW4"

  [ "$VERSION" = "${VERSION#v}" ] \
    || release_error "public release version must not include a leading v: $VERSION"
  printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$' \
    || release_error "public release version must be SemVer-like (for example 0.3.0): $VERSION"
  case "$BUILD" in
    ''|*[!0-9]*) release_error "public release build must be a positive integer: $BUILD" ;;
    0) release_error "public release build must be greater than zero" ;;
  esac
  printf '%s\n' "$SOURCE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' \
    || release_error "public release source commit must be a full lowercase Git SHA: ${SOURCE_COMMIT:-missing}"
  [ "$SOURCE_COMMIT" = "$(git rev-parse HEAD)" ] \
    || release_error "public release source commit $SOURCE_COMMIT does not match checkout $(git rev-parse HEAD)"
  preflight_public_toolchain

  [ "${DORY_BUNDLE_ENGINE:-1}" = "1" ] \
    || release_error "public releases must bundle the engine"
  [ "$RELEASE_VARIANTS" = "arm64" ] \
    || release_error "public releases must build exactly the Apple Silicon variant: arm64"
  [ "${DORY_REQUIRE_BUNDLE_ASSETS:-1}" = "1" ] \
    || release_error "public releases must require every bundle asset"
  [ "${DORY_REQUIRE_DEVELOPER_ID_SIGNATURES:-1}" = "1" ] \
    || release_error "public releases must require Developer ID signatures"
  [ "${DORY_BUNDLE_VENUS:-1}" = "1" ] \
    || release_error "public full releases advertise the Apple-silicon Venus GPU payload and must bundle it"
  [ "${DORY_BUNDLE_VENUS_REQUIRED:-0}" = "1" ] \
    || release_error "public full releases must fail when the advertised Venus renderer is unavailable"
  [ "$SIGN_IDENTITY" != "-" ] \
    || release_error "public releases cannot use ad-hoc signing"
  [ "${DORY_SKIP_NOTARIZE:-0}" != "1" ] \
    || release_error "public releases cannot skip notarization"
  [ "${DORY_SKIP_SIGNING_PREFLIGHT:-0}" != "1" ] \
    || release_error "public releases cannot skip signing preflight"
  [ "${DORY_ALLOW_ADHOC_SIGN:-0}" != "1" ] \
    || release_error "public releases cannot allow ad-hoc nested-code fallback"
  [ "${DORY_ALLOW_UNVERIFIED_GUEST_ASSETS:-0}" != "1" ] \
    || release_error "public releases cannot use unverified guest assets"
  [ "${DORY_ALLOW_MISSING_HOST_CLI:-0}" != "1" ] \
    || release_error "public releases cannot omit clean-Mac host CLIs"
  [ "${DORY_BUILD_APPCAST:-1}" = "1" ] \
    || release_error "public releases must generate an appcast"
  [ "${DORY_BUILD_APP_UPDATE:-1}" = "1" ] \
    || release_error "public releases must generate the app-update ZIP referenced by the appcast"
  [ "${DORY_BUILD_DESKTOP_EDITION:-0}" = "0" ] \
    || release_error "focused public releases no longer ship a fixed Desktop edition"
  [ "${DORY_BUILD_COMPONENTS:-1}" = "1" ] \
    || release_error "public releases must generate the signed focused component catalog"
  [ "${DORY_RELEASE_RESUME_ACCEPTED_DESKTOP:-0}" != "1" ] \
    || release_error "the legacy Desktop-edition resume path cannot produce a focused release"
  [ "${DORY_APPCAST_PREFER_APP_UPDATE:-1}" = "1" ] \
    || release_error "public releases must point Sparkle at the self-contained app-update ZIP"
  [ "${DORY_BUILD_LITE:-0}" = "0" ] \
    || release_error "focused public releases ship one Docker Core app, not a separate lite app"
  [ "${DORY_BUILD_RUNTIME:-1}" = "1" ] \
    || release_error "public releases must generate the documented headless runtime"
  [ "${DORY_MAKE_DMG:-1}" = "1" ] \
    || release_error "public releases must generate DMGs"
  [ -z "${DORY_APPCAST_ZIP:-}" ] \
    || release_error "public releases cannot redirect the appcast to an external ZIP override"
  [ "${DORY_RELEASE_ASSET_BASE_URL:-https://github.com/Augani/dory/releases/download/v$VERSION}" = \
    "https://github.com/Augani/dory/releases/download/v$VERSION" ] \
    || release_error "public release assets must use the versioned Augani/dory GitHub release URL"
  [ -z "${DORY_APPCAST_ARTIFACT_URL:-}" ] \
    || release_error "public releases cannot override the appcast artifact URL"
  [ "${DORY_APPCAST_LINK:-https://augani.github.io/dory/appcast.xml}" = \
    "https://augani.github.io/dory/appcast.xml" ] \
    || release_error "public releases must use Dory's production Sparkle feed URL"
  [ "${DORY_APPCAST_MINIMUM_SYSTEM_VERSION:-14.0}" = "14.0" ] \
    || release_error "public releases must keep the declared macOS 14 minimum"
  [ "${DORY_APPCAST_TITLE:-Dory}" = "Dory" ] \
    || release_error "public releases must keep the Dory appcast identity"
  [ -z "${DORY_APPCAST_PUBDATE:-}" ] \
    || release_error "public releases cannot override the appcast publication date"
  [ -z "${DORY_SPARKLE_ED_SIGNATURE:-}" ] \
    || release_error "public releases must create the Sparkle signature from the configured private key"
  [ -z "${DORY_SPARKLE_SIGN_UPDATE:-}" ] \
    || release_error "public releases must use sign_update from the release build's pinned Sparkle package"

  scripts/verify-clean-release-source.sh . >/dev/null \
    || release_error "public release source does not exactly match commit $SOURCE_COMMIT"
}

release_host_guest_arch() {
  [ "$(uname -m)" = x86_64 ] && printf '%s\n' amd64 || printf '%s\n' arm64
}

release_guest_arches() {
  local requested arches=""
  for requested in $RELEASE_VARIANTS; do
    case "$requested" in
      arm64|apple-silicon|silicon) arches="$arches arm64" ;;
      x86_64|amd64|intel) arches="$arches amd64" ;;
      universal|fat) arches="$arches arm64 amd64" ;;
      *) release_error "unknown DORY_RELEASE_VARIANTS entry '$requested' (use arm64, x86_64, universal)" ;;
    esac
  done
  for requested in arm64 amd64; do
    case " $arches " in *" $requested "*) printf '%s\n' "$requested" ;; esac
  done
}

# Return the exact environment variable bundle-engine.sh will consult for a guest asset. The
# architecture-specific spelling wins; the unsuffixed compatibility spelling applies only to the
# host's native guest architecture.
guest_override_name() {
  local prefix="$1" arch="$2" upper name
  upper="$(printf '%s' "$arch" | tr '[:lower:]-' '[:upper:]_')"
  name="${prefix}_${upper}"
  if [ -n "${!name:-}" ]; then
    printf '%s\n' "$name"
  elif [ "$arch" = "$(release_host_guest_arch)" ] && [ -n "${!prefix:-}" ]; then
    printf '%s\n' "$prefix"
  fi
}

# Fail in seconds, not after the full xcodebuild, when an engine-bundled release is requested on a
# runner that never built/fetched the guest assets. bundle-engine.sh remains the authoritative
# (hard-failing) check; this only covers the two classes every engine bundle needs.
preflight_guest_assets() {
  [ "${DORY_BUNDLE_ENGINE:-1}" = "1" ] || return 0
  local arch name value hv_kernel vm_kernel initfs agent engine_rootfs gpu_kernel
  local missing="" override_names="" kernel_verify_arches="" gpu_verify_arches="" initfs_verify_arches=""

  for arch in $(release_guest_arches); do
    hv_kernel="$(guest_override_name DORY_HV_KERNEL "$arch")"
    vm_kernel="$(guest_override_name DORY_KERNEL "$arch")"
    initfs="$(guest_override_name DORY_INITFS "$arch")"
    agent="$(guest_override_name DORY_GUEST_AGENT "$arch")"
    engine_rootfs="$(guest_override_name DORY_ENGINE_ROOTFS "$arch")"
    gpu_kernel=""
    # Venus is currently advertised and verified only on Apple silicon. Never infer an untested
    # Intel GPU guarantee merely because the public app also carries an x86_64 CPU slice.
    if [ "${DORY_BUNDLE_VENUS:-1}" = "1" ] && [ "$arch" = arm64 ]; then
      gpu_kernel="$(guest_override_name DORY_HV_GPU_KERNEL "$arch")"
      [ -n "$gpu_kernel" ] || gpu_verify_arches="$gpu_verify_arches $arch"
    fi

    for name in "$hv_kernel" "$vm_kernel" "$initfs" "$agent" "$engine_rootfs" "$gpu_kernel"; do
      [ -n "$name" ] || continue
      value="${!name}"
      [ -f "$value" ] || release_error "$name does not name a regular file: $value"
      case " $override_names " in *" $name "*) ;; *) override_names="$override_names $name" ;; esac
    done

    # dory-hv and Virtualization.framework have independent kernel override surfaces. If either
    # consumer still selects guest/out, the standard kernel must retain valid provenance.
    if [ -z "$hv_kernel" ] || [ -z "$vm_kernel" ]; then
      kernel_verify_arches="$kernel_verify_arches $arch"
    fi

    # The standalone agent, VZ initfs, and engine rootfs also select independently. A DORY_INITFS
    # override does not replace the guest/out agent or the engine-rootfs fallback.
    if [ -z "$initfs" ] || [ -z "$agent" ]; then
      initfs_verify_arches="$initfs_verify_arches $arch"
    fi
    if [ -z "$engine_rootfs" ]; then
      if [ -f "guest/out/dory-engine-rootfs-$arch.ext4" ]; then
        override_names="$override_names guest/out/dory-engine-rootfs-$arch.ext4(implicit)"
      else
        initfs_verify_arches="$initfs_verify_arches $arch"
      fi
    fi
  done

  if [ -n "$override_names" ]; then
    [ "${DORY_ALLOW_UNVERIFIED_GUEST_ASSETS:-0}" = "1" ] \
      || release_error "guest-asset overrides bypass source provenance:$override_names. Use verified guest/out assets, or explicitly set DORY_ALLOW_UNVERIFIED_GUEST_ASSETS=1 for a development-only release"
    echo "==> WARNING: accepting unverified development guest assets:$override_names"
  fi

  for arch in arm64 amd64; do
    case " $kernel_verify_arches " in
      *" $arch "*)
        if [ "$arch" = arm64 ]; then
          if [ -f guest/out/Image ]; then
            DORY_EXPERIMENTAL_GPU=0 guest/kernel/verify-build.sh "$arch" >/dev/null \
              || release_error "$arch kernel is stale or missing required features"
          else
            missing="$missing arm64-kernel(guest/out/Image)"
          fi
        else
          if [ -f guest/out/vmlinux-x86 ]; then
            DORY_EXPERIMENTAL_GPU=0 guest/kernel/verify-build.sh "$arch" >/dev/null \
              || release_error "$arch kernel is stale or missing required features"
          else
            missing="$missing amd64-kernel(guest/out/vmlinux-x86)"
          fi
        fi
        ;;
    esac
    case " $initfs_verify_arches " in
      *" $arch "*)
        if [ ! -f "guest/out/initfs-$arch.ext4" ]; then
          missing="$missing $arch-initfs(guest/out/initfs-$arch.ext4)"
        else
          guest/initfs/verify-build.sh "$arch" >/dev/null \
            || release_error "$arch initfs/guest agent is stale"
        fi
        ;;
    esac
    case " $gpu_verify_arches " in
      *" $arch "*)
        if [ ! -f "guest/out/Image-gpu" ]; then
          missing="$missing arm64-gpu-kernel(guest/out/Image-gpu)"
        else
          DORY_EXPERIMENTAL_GPU=1 guest/kernel/verify-build.sh arm64 >/dev/null \
            || release_error "arm64 GPU kernel is stale or missing required Venus features"
        fi
        ;;
    esac
  done
  [ -z "$missing" ] || release_error "engine-bundled release needs guest assets on this runner; missing:$missing. Build them with guest/kernel/build.sh and guest/initfs/build.sh (or use the matching DORY_HV_KERNEL_*, DORY_KERNEL_*, DORY_INITFS_*, DORY_GUEST_AGENT_*, and DORY_ENGINE_ROOTFS_* overrides with the explicit development escape), or set DORY_BUNDLE_ENGINE=0 for an app-only dry-run"
}

preflight_release() {
  local requested
  echo "==> Release preflight..."
  for tool in xcodebuild codesign xcrun ditto file lipo shasum plutil security python3 tar unzip; do
    require_tool "$tool"
  done
  validate_release_build_dir
  preflight_public_release
  preflight_macos_floor
  preflight_guest_assets
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
    validate_notary_credentials
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
  if [ "${DORY_REQUIRE_DEVELOPER_ID_SIGNATURES:-1}" = "1" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    scripts/verify-distribution-signatures.sh "$app" "$TEAM"
  fi
}

verify_developer_id_signature() {
  local path="$1" details
  [ "${DORY_REQUIRE_DEVELOPER_ID_SIGNATURES:-1}" = "1" ] || return 0
  [ "$SIGN_IDENTITY" != "-" ] || return 0
  details="$(codesign -dv --verbose=4 "$path" 2>&1)" \
    || release_error "could not inspect code signature for $path"
  printf '%s\n' "$details" | grep 'Authority=Developer ID Application' >/dev/null \
    || release_error "$path is not signed by a Developer ID Application certificate"
}

validate_stapled_app() {
  local app="$1"
  echo "==> Validating stapled app ticket + Gatekeeper assessment..."
  stapler_with_retry validate "$app"
  spctl --assess --type execute --verbose=4 "$app"
}

validate_stapled_dmg() {
  local dmg="$1" assessment
  echo "==> Validating stapled DMG ticket + Gatekeeper assessment..."
  stapler_with_retry validate "$dmg"
  assessment="$(spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg" 2>&1)" \
    || release_error "Gatekeeper rejected stapled DMG: $dmg"
  printf '%s\n' "$assessment"
  printf '%s\n' "$assessment" | grep -Fx 'source=Notarized Developer ID' >/dev/null \
    || release_error "stapled DMG is not accepted as Notarized Developer ID: $dmg"
}

stapler_with_retry() {
  local action="$1" target="$2" attempt=1 max_attempts=5 delay
  while ! xcrun stapler "$action" "$target"; do
    [ "$attempt" -lt "$max_attempts" ] \
      || release_error "stapler $action failed after $max_attempts attempts: $target"
    delay=$((attempt * 5))
    echo "==> stapler $action attempt $attempt failed; retrying in ${delay}s..." >&2
    sleep "$delay"
    attempt=$((attempt + 1))
  done
}

verify_full_bundle() {
  local app="$1" helpers resources frameworks launch_agent asset_arch helper cli_version
  helpers="$app/Contents/Helpers"
  resources="$app/Contents/Resources"
  frameworks="$app/Contents/Frameworks"
  launch_agent="$resources/dev.dory.doryd.plist"

  echo "==> Verifying full clean-Mac bundle payload..."
  for helper in doryd dorydctl dory-vmm dory-network-helper dory-dataplane-proxy dory-hv gvproxy docker docker-buildx docker-compose dory dory-doctor; do
    assert_executable_exists "$helpers/$helper" "bundled helper"
  done
  for helper in doryd dorydctl dory-vmm dory-network-helper dory-dataplane-proxy dory-hv; do
    assert_macho_arches "$helpers/$helper" "$HELPER_ARCHES"
  done
  for helper in gvproxy docker docker-buildx docker-compose; do
    assert_macho_arches "$helpers/$helper" "$HOST_CLI_ARCHES"
  done
  scripts/verify-macos-deployment-targets.sh "$app" "$HELPER_ARCHES"
  for helper in doryd dorydctl dory-vmm dory-network-helper dory-dataplane-proxy dory-hv gvproxy docker docker-buildx docker-compose dory dory-doctor; do
    verify_developer_id_signature "$helpers/$helper"
  done
  cli_version="$("$helpers/dory" version)"
  [ "$cli_version" = "$VERSION" ] \
    || release_error "bundled dory CLI version $cli_version does not match $VERSION"

  for asset_arch in $BUNDLE_ARCHES; do
    assert_file_exists "$resources/dory-agent-linux-$asset_arch" "guest agent"
    assert_file_exists "$resources/dory-hv-kernel-$asset_arch.lzfse" "compressed dory-hv kernel"
    assert_file_exists "$resources/dory-vm-kernel-$asset_arch.lzfse" "compressed VZ kernel"
    assert_file_exists "$resources/dory-vm-initfs-$asset_arch.ext4.lzfse" "compressed VZ initfs"
    assert_file_exists "$resources/dory-engine-rootfs-$asset_arch.ext4.lzfse" "engine rootfs"
    assert_file_exists "$resources/dory-kernel-build-$asset_arch.stamp" "kernel provenance stamp"
    assert_file_exists "$resources/dory-initfs-build-$asset_arch.stamp" "initfs provenance stamp"
    if [ "$asset_arch" = arm64 ] && [ "${DORY_BUNDLE_VENUS:-1}" = "1" ]; then
      assert_file_exists "$resources/dory-hv-kernel-gpu-arm64.lzfse" "Apple-silicon GPU kernel"
      assert_file_exists "$resources/dory-kernel-build-arm64-gpu.stamp" "Apple-silicon GPU kernel provenance"
    fi
  done
  assert_file_exists "$resources/dory-engine-rootfs.ext4.lzfse" "engine rootfs"
  assert_file_exists "$resources/gvproxy-provenance.txt" "gvproxy provenance"
  assert_file_exists "$resources/host-cli-provenance.txt" "host CLI provenance"
  [ "$(stat -f '%Lp' "$resources/host-cli-provenance.txt")" = 644 ] \
    || release_error "host CLI provenance must use portable mode 0644"
  if [ "${DORY_BUNDLE_VENUS:-1}" = "1" ]; then
    assert_file_exists "$frameworks/libvirglrenderer.dylib" "patched VirGL/Venus renderer"
    assert_file_exists "$frameworks/libMoltenVK.dylib" "MoltenVK renderer"
    assert_file_exists "$resources/vulkan/icd.d/MoltenVK_icd.json" "MoltenVK ICD"
    assert_file_exists "$resources/virglrenderer-provenance.txt" "VirGL renderer provenance"
    assert_file_exists "$resources/moltenvk-provenance.txt" "MoltenVK provenance"
    nm -gU "$frameworks/libvirglrenderer.dylib" \
      | grep '_dory_virglrenderer_macos_fragment_coord_fix$' >/dev/null \
      || release_error "bundled VirGL renderer is missing Dory's macOS shader compatibility fix"
    nm -gU "$frameworks/libvirglrenderer.dylib" \
      | grep '_dory_virglrenderer_macos_venus_fence_fix$' >/dev/null \
      || release_error "bundled VirGL renderer is missing Dory's macOS Venus fence fix"
    nm -gU "$frameworks/libvirglrenderer.dylib" \
      | grep -E '_virgl_renderer_resource_(get_map_ptr|map)$' >/dev/null \
      || release_error "bundled VirGL renderer has no host-visible Venus map entry point"
    nm -gU "$frameworks/libMoltenVK.dylib" \
      | grep '_dory_moltenvk_spirv_native_array_fix$' >/dev/null \
      || release_error "bundled MoltenVK is missing Dory's SPIRV native-array fix"
    otool -L "$frameworks/libvirglrenderer.dylib" \
      | grep '@loader_path/libMoltenVK\.dylib' >/dev/null \
      || release_error "bundled VirGL renderer is not linked to its MoltenVK sibling"
    grep -q '^features=venus,macos-core-shader-compat-v2,macos-venus-fence-callback-v1,moltenvk-native-array-v1$' "$resources/virglrenderer-provenance.txt" \
      || release_error "VirGL renderer provenance does not declare Dory's shader and fence fixes"
    grep -q '^features=spirv-native-function-arrays-v1$' "$resources/moltenvk-provenance.txt" \
      || release_error "MoltenVK provenance does not declare Dory's shader fix"
    grep -Eq '^bundled_sha256=[0-9a-f]{64}$' "$resources/virglrenderer-provenance.txt" \
      || release_error "VirGL renderer provenance is missing the bundled dylib digest"
    verify_developer_id_signature "$frameworks/libvirglrenderer.dylib"
    verify_developer_id_signature "$frameworks/libMoltenVK.dylib"
  fi
  assert_file_exists "$resources/dory-payload-sha256.txt" "payload digest inventory"
  assert_file_exists "$launch_agent" "bundled launchd plist"
  plutil -lint "$launch_agent" >/dev/null
  (cd "$app" && shasum -a 256 -c "Contents/Resources/dory-payload-sha256.txt" >/dev/null) \
    || release_error "$app payload digest inventory does not match bundled helpers/resources"
}

verify_lean_bundle() {
  local app="$1" resources included feed bundled
  resources="$app/Contents/Resources"
  included="$(/usr/libexec/PlistBuddy -c 'Print :DoryIncludesDesktopLinux' "$app/Contents/Info.plist" 2>/dev/null || true)"
  feed="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$app/Contents/Info.plist" 2>/dev/null || true)"
  bundled="$(/usr/libexec/PlistBuddy -c 'Print :DoryBundledComponents' "$app/Contents/Info.plist" 2>/dev/null || true)"
  [ "$included" = false ] || release_error "Core app must declare DoryIncludesDesktopLinux=false"
  [ "$feed" = "https://augani.github.io/dory/appcast.xml" ] \
    || release_error "Core app must use the primary Sparkle feed"
  [ "$bundled" = $'Array {\n    docker-core\n}' ] \
    || release_error "Core app must declare only docker-core in DoryBundledComponents"
  [ ! -e "$app/Contents/Helpers/kubectl" ] \
    || release_error "Core app unexpectedly contains kubectl"
  for payload in \
    dory-hv-kernel-arm64 \
    dory-hv-kernel \
    dory-machine-rootfs-arm64.ext4 \
    dory-machine-rootfs.ext4; do
    [ ! -e "$resources/$payload" ] || release_error "Core app unexpectedly contains $payload"
  done
  for payload in \
    dory-desktop-kernel-arm64.lzfse \
    kernel-build-arm64-desktop.stamp \
    dory-desktop-debian-rootfs-arm64.ext4.lzfse \
    dory-desktop-ubuntu-rootfs-arm64.ext4.lzfse \
    dory-desktop-kali-rootfs-arm64.ext4.lzfse; do
    [ ! -e "$resources/$payload" ] || release_error "Core app unexpectedly contains $payload"
  done
}

verify_desktop_bundle() {
  local app="$1" resources included feed distro
  resources="$app/Contents/Resources"
  included="$(/usr/libexec/PlistBuddy -c 'Print :DoryIncludesDesktopLinux' "$app/Contents/Info.plist" 2>/dev/null || true)"
  feed="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$app/Contents/Info.plist" 2>/dev/null || true)"
  [ "$included" = true ] || release_error "Desktop app must declare DoryIncludesDesktopLinux=true"
  [ "$feed" = "https://augani.github.io/dory/appcast-desktop.xml" ] \
    || release_error "Desktop app must use the Desktop Sparkle feed"
  assert_file_exists "$resources/dory-desktop-kernel-arm64.lzfse" "Desktop Linux kernel"
  assert_file_exists "$resources/kernel-build-arm64-desktop.stamp" "Desktop Linux kernel provenance"
  for distro in debian ubuntu kali; do
    assert_file_exists "$resources/dory-desktop-$distro-rootfs-arm64.ext4.lzfse" "$distro Desktop image"
    assert_file_exists "$resources/dory-desktop-$distro-build-arm64.stamp" "$distro Desktop provenance"
    assert_file_exists "$resources/dory-desktop-$distro-packages-arm64.txt" "$distro Desktop package manifest"
  done
}

sign_app() {
  local app="$1"
  local entitlements="Dory/Dory.entitlements"
  echo "==> Signing $(basename "$(dirname "$app")")/Dory.app (Developer ID + hardened runtime)..."
  if [ "$SIGN_IDENTITY" = "-" ]; then
    entitlements="$BUILD_DIR/local-adhoc-app.entitlements"
    mkdir -p "$(dirname "$entitlements")"
    /bin/cat > "$entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
</dict>
</plist>
PLIST
  fi
  # NOT --deep: bundle-engine.sh already signed nested helpers with their own entitlements
  # (dory-hv needs com.apple.security.hypervisor, dory-vmm needs virtualization), and --deep
  # would re-sign them without those entitlements.
  codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$SIGN_IDENTITY" "$app"
}

sign_dmg() {
  local dmg="$1"
  echo "==> Signing $(basename "$dmg") (Developer ID + secure timestamp)..."
  if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --sign - "$dmg"
  else
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$dmg"
  fi
}

verify_dmg_signature() {
  local dmg="$1" details
  codesign --verify --strict --verbose=2 "$dmg" \
    || release_error "disk image signature is invalid: $dmg"
  [ "${DORY_REQUIRE_DEVELOPER_ID_SIGNATURES:-1}" = "1" ] || return 0
  [ "$SIGN_IDENTITY" != "-" ] || return 0
  details="$(codesign -d --verbose=4 "$dmg" 2>&1)" \
    || release_error "could not inspect disk image signature: $dmg"
  printf '%s\n' "$details" | grep -F 'Authority=Developer ID Application:' >/dev/null \
    || release_error "disk image is not signed by a Developer ID Application certificate: $dmg"
  printf '%s\n' "$details" | grep -F "TeamIdentifier=$TEAM" >/dev/null \
    || release_error "disk image is not signed by expected team $TEAM: $dmg"
  printf '%s\n' "$details" | grep -E '^Timestamp=' >/dev/null \
    || release_error "disk image signature has no secure timestamp: $dmg"
}

archive_variant() {
  local variant="$1" archive="$2"
  echo "==> Archiving + signing Dory $VERSION $variant (Developer ID, team $TEAM, archs: $XCODE_ARCHS)..."
  xcodebuild -project Dory.xcodeproj -scheme Dory -configuration Release -scmProvider system \
    -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED_DATA_DIR" -archivePath "$archive" \
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
  # Resource-fork metadata creates a top-level __MACOSX directory that violates the public
  # archive contract and is unnecessary for Dory's signed application bundle.
  COPYFILE_DISABLE=1 ditto -c -k --keepParent "$app" "$zip"
}

finish_app_artifact() {
  local app="$1" zip="$2" dmg="$3"
  zip_app "$app" "$zip"
  if [ "${DORY_SKIP_NOTARIZE:-0}" = "1" ]; then
    echo "==> Skipping notarization for $zip (DORY_SKIP_NOTARIZE=1)"
  else
    echo "==> Notarizing $zip..."
    notarize "$zip"
    stapler_with_retry staple "$app"
    validate_stapled_app "$app"
    zip_app "$app" "$zip"
  fi

  if [ "${DORY_MAKE_DMG:-1}" = "1" ]; then
    echo "==> Building DMG $dmg..."
    scripts/make-dmg.sh "$app" "$VERSION" "$dmg"
    sign_dmg "$dmg"
    verify_dmg_signature "$dmg"
    if [ "${DORY_SKIP_NOTARIZE:-0}" = "1" ]; then
      echo "==> Skipping notarization for $dmg (DORY_SKIP_NOTARIZE=1)"
    else
      echo "==> Notarizing $dmg..."
      notarize "$dmg"
      stapler_with_retry staple "$dmg"
      validate_stapled_dmg "$dmg"
    fi
  fi
}

finish_zip_update_artifact() {
  local app="$1" zip="$2"
  # The update app is copied from the already notarized and stapled direct-release app. Submitting
  # that copy again creates a different stapling ticket in Contents/CodeResources, so Sparkle would
  # install bytes that no longer match the direct ZIP, DMG, or exact-tree SBOM. Sparkle authenticates
  # the ZIP with its EdDSA signature; Gatekeeper authenticates the unchanged signed/stapled app.
  if [ "${DORY_SKIP_NOTARIZE:-0}" != "1" ]; then
    validate_stapled_app "$app"
  fi
  zip_app "$app" "$zip"
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

artifact_kind() {
  case "$1" in
    *.cdx.json) printf '%s' "cyclonedx-json" ;;
    *.dmg) printf '%s' "dmg" ;;
    *.zip) printf '%s' "zip" ;;
    *.tar.gz) printf '%s' "tar.gz" ;;
    *) printf '%s' "file" ;;
  esac
}

write_release_manifest() {
  local manifest="$BUILD_DIR/release-manifest.json" artifact first kind record_path
  first=1
  {
    echo "{"
    echo "  \"schemaVersion\": 2,"
    echo "  \"version\": \"$(json_escape "$VERSION")\","
    echo "  \"build\": \"$(json_escape "$BUILD")\","
    echo "  \"sourceCommit\": \"$(json_escape "$SOURCE_COMMIT")\","
    echo "  \"publicRelease\": $([ "${DORY_PUBLIC_RELEASE:-0}" = "1" ] && echo true || echo false),"
    echo "  \"bundleEngine\": $([ "${DORY_BUNDLE_ENGINE:-1}" = "1" ] && echo true || echo false),"
    echo "  \"notarized\": $([ "${DORY_SKIP_NOTARIZE:-0}" = "1" ] && echo false || echo true),"
    echo "  \"variants\": \"$(json_escape "$RELEASE_VARIANTS")\","
    echo "  \"artifacts\": ["
    for artifact in "$@"; do
      [ -n "$artifact" ] && [ -f "$artifact" ] || continue
      kind="$(artifact_kind "$artifact")"
      record_path="${artifact#$BUILD_DIR/}"
      [ "$record_path" != "$artifact" ] \
        || release_error "release manifest artifact is outside the build directory: $artifact"
      case "/$record_path/" in
        *"/../"*|*"/./"*) release_error "release manifest artifact path is unsafe: $record_path" ;;
      esac
      if [ "$first" -eq 0 ]; then
        echo ","
      fi
      first=0
      printf '    {"name":"%s","path":"%s","kind":"%s","bytes":%s,"sha256":"%s"}' \
        "$(json_escape "$(basename "$artifact")")" \
        "$(json_escape "$record_path")" \
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

if [ "${DORY_RELEASE_SOURCE_ONLY:-0}" = "1" ]; then
  if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; else exit 0; fi
fi

preflight_release
if [ "${DORY_RELEASE_PREFLIGHT_ONLY:-0}" = "1" ]; then
  echo "==> Preflight-only mode passed."
  exit 0
fi

if [ "${DORY_RELEASE_RESUME_ACCEPTED_DESKTOP:-0}" != "1" ]; then
  rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"

ZIPS=()
DMGS=()
FIRST_ARCHIVE=""
UNIVERSAL_ARCHIVE=""
UNIVERSAL_ZIP=""
UNIVERSAL_DMG=""
UNIVERSAL_APP=""
ARM64_APP=""
ARM64_ZIP=""
ARM64_DMG=""
DESKTOP_APP=""
DESKTOP_ZIP=""
DESKTOP_DMG=""
COMPONENT_OUTPUT_DIR="$BUILD_DIR/components/arm64"
COMPONENT_INPUT_DIR="$BUILD_DIR/component-inputs"
COMPONENT_KUBECTL="$COMPONENT_INPUT_DIR/kubectl"
COMPONENT_KUBECTL_PROVENANCE="$COMPONENT_INPUT_DIR/kubectl.provenance.txt"
COMPONENT_ASSETS=()

if [ "${DORY_RELEASE_RESUME_ACCEPTED_DESKTOP:-0}" = "1" ]; then
  echo "==> Resuming after accepted Desktop ZIP notarization..."
  configure_variant arm64
  FIRST_ARCHIVE="$BUILD_DIR/Dory-arm64.xcarchive"
  ARM64_APP="$BUILD_DIR/export-arm64/Dory.app"
  ARM64_ZIP="$BUILD_DIR/Dory-$VERSION-arm64.zip"
  ARM64_DMG="$BUILD_DIR/Dory-$VERSION-arm64.dmg"
  DESKTOP_APP="$BUILD_DIR/export-desktop-arm64/Dory.app"
  DESKTOP_ZIP="$BUILD_DIR/Dory-$VERSION-desktop-arm64.zip"
  DESKTOP_DMG="$BUILD_DIR/Dory-$VERSION-desktop-arm64.dmg"
  [ -d "$FIRST_ARCHIVE/Products/Applications/Dory.app" ] \
    || release_error "resume archive is missing: $FIRST_ARCHIVE"
  for artifact in "$ARM64_ZIP" "$ARM64_DMG" "$DESKTOP_ZIP"; do
    assert_file_exists "$artifact" "resume artifact"
  done
  [ -d "$ARM64_APP" ] || release_error "resume Lean app is missing: $ARM64_APP"
  [ -d "$DESKTOP_APP" ] || release_error "resume Desktop app is missing: $DESKTOP_APP"
  DORY_SPARKLE_SIGN_UPDATE="$DERIVED_DATA_DIR/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
  [ -x "$DORY_SPARKLE_SIGN_UPDATE" ] \
    || release_error "pinned Sparkle sign_update is missing from the resumed build"
  export DORY_SPARKLE_SIGN_UPDATE
  verify_full_bundle "$ARM64_APP"
  verify_lean_bundle "$ARM64_APP"
  verify_codesign "$ARM64_APP"
  validate_stapled_app "$ARM64_APP"
  verify_full_bundle "$DESKTOP_APP"
  verify_desktop_bundle "$DESKTOP_APP"
  verify_codesign "$DESKTOP_APP"
  stapler_with_retry staple "$DESKTOP_APP"
  validate_stapled_app "$DESKTOP_APP"
  zip_app "$DESKTOP_APP" "$DESKTOP_ZIP"
  echo "==> Building DMG $DESKTOP_DMG..."
  scripts/make-dmg.sh "$DESKTOP_APP" "$VERSION" "$DESKTOP_DMG"
  sign_dmg "$DESKTOP_DMG"
  verify_dmg_signature "$DESKTOP_DMG"
  echo "==> Notarizing $DESKTOP_DMG..."
  notarize "$DESKTOP_DMG"
  stapler_with_retry staple "$DESKTOP_DMG"
  validate_stapled_dmg "$DESKTOP_DMG"
  ZIPS+=("$ARM64_ZIP" "$DESKTOP_ZIP")
  DMGS+=("$ARM64_DMG" "$DESKTOP_DMG")
else
for requested in $RELEASE_VARIANTS; do
  configure_variant "$requested"
  ARCHIVE="$BUILD_DIR/Dory-$VARIANT_SUFFIX.xcarchive"
  EXPORT_DIR="$BUILD_DIR/export-$VARIANT_SUFFIX"
  APP="$EXPORT_DIR/Dory.app"
  ZIP="$BUILD_DIR/Dory-$VERSION-$VARIANT_SUFFIX.zip"
  DMG="$BUILD_DIR/Dory-$VERSION-$VARIANT_SUFFIX.dmg"

  archive_variant "$VARIANT" "$ARCHIVE"
  if [ -z "${DORY_SPARKLE_SIGN_UPDATE:-}" ]; then
    DORY_SPARKLE_SIGN_UPDATE="$DERIVED_DATA_DIR/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
    [ -x "$DORY_SPARKLE_SIGN_UPDATE" ] \
      || release_error "pinned Sparkle sign_update was not produced by this release build"
    export DORY_SPARKLE_SIGN_UPDATE
  fi
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
    # A release consumes the exact stamped initfs. Opportunistically rewriting it with host-found
    # agent or toolbox binaries would make the signed guest vary by runner and escape provenance;
    # add those tools to guest/initfs/PINS + build.sh before making them part of a release image.
    DORY_BUNDLE_ARCHES="$BUNDLE_ARCHES" \
    DORY_SWIFTPM_HELPER_ARCHES="$HELPER_ARCHES" \
    DORY_HOST_CLI_ARCHES="$HOST_CLI_ARCHES" \
    DORY_BUNDLE_NATIVE_ARCH="$NATIVE_GUEST_ARCH" \
    DORY_COMPONENT_BUNDLE_MODE=core \
    DORY_COMPONENT_KUBECTL_OUTPUT="$COMPONENT_KUBECTL" \
    DORY_COMPONENT_KUBECTL_PROVENANCE_OUTPUT="$COMPONENT_KUBECTL_PROVENANCE" \
    DORY_DESKTOP_BUNDLE_MODE=none \
    DORY_SKIP_AGENT_INJECT=1 \
    DORY_SKIP_TOOLBOX_INJECT=1 \
    DORY_REQUIRE_BUNDLE_ASSETS="${DORY_REQUIRE_BUNDLE_ASSETS:-1}" \
      scripts/bundle-engine.sh "$APP"
  else
    echo "==> WARNING: producing a development app without bundled engine assets for $VARIANT."
  fi

  scripts/sign-sparkle-for-distribution.sh "$APP" "$SIGN_IDENTITY"
  sign_app "$APP"
  if [ "${DORY_BUNDLE_ENGINE:-1}" = "1" ]; then
    verify_full_bundle "$APP"
    verify_lean_bundle "$APP"
  fi
  verify_codesign "$APP"
  finish_app_artifact "$APP" "$ZIP" "$DMG"

  if [ "$VARIANT" = arm64 ] \
    && [ "${DORY_BUNDLE_ENGINE:-1}" = "1" ] \
    && [ "${DORY_BUILD_COMPONENTS:-1}" = "1" ]; then
    [ -f "$DMG" ] || release_error "focused component catalog requires the Core DMG"
    assert_executable_exists "$COMPONENT_KUBECTL" "exported Kubernetes component"
    assert_file_exists "$COMPONENT_KUBECTL_PROVENANCE" "Kubernetes component provenance"
    assert_macho_arches "$COMPONENT_KUBECTL" arm64
    verify_developer_id_signature "$COMPONENT_KUBECTL"
    echo "==> Building signed focused component catalog..."
    scripts/build-components.py \
      --version "$VERSION" \
      --minimum-app-version "$VERSION" \
      --core-artifact "$DMG" \
      --core-app "$APP" \
      --kubectl "$COMPONENT_KUBECTL" \
      --output "$COMPONENT_OUTPUT_DIR" \
      --asset-base-url "https://github.com/Augani/dory/releases/download/v$VERSION" \
      --signer "$DORY_SPARKLE_SIGN_UPDATE"
    assert_file_exists "$COMPONENT_OUTPUT_DIR/catalog.json" "component catalog"
    assert_file_exists "$COMPONENT_OUTPUT_DIR/catalog.json.sig" "component catalog signature"
    assert_file_exists "$COMPONENT_OUTPUT_DIR/catalog.json.sha256" "component catalog digest"
    mkdir -p website/public/components/arm64
    cp "$COMPONENT_OUTPUT_DIR/catalog.json" website/public/components/arm64/catalog.json
    cp "$COMPONENT_OUTPUT_DIR/catalog.json.sig" website/public/components/arm64/catalog.json.sig
    cp "$COMPONENT_OUTPUT_DIR/catalog.json.sha256" website/public/components/arm64/catalog.json.sha256
    while IFS= read -r component_asset; do
      COMPONENT_ASSETS+=("$component_asset")
    done < <(find "$COMPONENT_OUTPUT_DIR" -maxdepth 1 -type f -print | LC_ALL=C sort)
  fi
  ZIPS+=("$ZIP")
  [ -f "$DMG" ] && DMGS+=("$DMG")

  case "$VARIANT" in
    arm64)
      ARM64_APP="$APP"
      ARM64_ZIP="$ZIP"
      [ -f "$DMG" ] && ARM64_DMG="$DMG"
      ;;
    universal)
      UNIVERSAL_ZIP="$ZIP"
      [ -f "$DMG" ] && UNIVERSAL_DMG="$DMG"
      UNIVERSAL_APP="$APP"
      ;;
  esac

  if [ "$VARIANT" = arm64 ] \
    && [ "${DORY_BUNDLE_ENGINE:-1}" = "1" ] \
    && [ "${DORY_BUILD_DESKTOP_EDITION:-0}" = "1" ]; then
    DESKTOP_EXPORT_DIR="$BUILD_DIR/export-desktop-arm64"
    DESKTOP_APP="$DESKTOP_EXPORT_DIR/Dory.app"
    DESKTOP_ZIP="$BUILD_DIR/Dory-$VERSION-desktop-arm64.zip"
    DESKTOP_DMG="$BUILD_DIR/Dory-$VERSION-desktop-arm64.dmg"
    rm -rf "$DESKTOP_EXPORT_DIR"
    mkdir -p "$DESKTOP_EXPORT_DIR"
    cp -R "$ARCHIVE/Products/Applications/Dory.app" "$DESKTOP_EXPORT_DIR/"
    assert_app_binary_arches "$DESKTOP_APP/Contents/MacOS/Dory" "$XCODE_ARCHS"
    echo "==> Bundling the all-inclusive Desktop edition for Apple silicon..."
    DORY_BUNDLE_ARCHES="$BUNDLE_ARCHES" \
    DORY_SWIFTPM_HELPER_ARCHES="$HELPER_ARCHES" \
    DORY_HOST_CLI_ARCHES="$HOST_CLI_ARCHES" \
    DORY_BUNDLE_NATIVE_ARCH="$NATIVE_GUEST_ARCH" \
    DORY_DESKTOP_BUNDLE_MODE=all \
    DORY_SKIP_AGENT_INJECT=1 \
    DORY_SKIP_TOOLBOX_INJECT=1 \
    DORY_REQUIRE_BUNDLE_ASSETS="${DORY_REQUIRE_BUNDLE_ASSETS:-1}" \
      scripts/bundle-engine.sh "$DESKTOP_APP"
    scripts/sign-sparkle-for-distribution.sh "$DESKTOP_APP" "$SIGN_IDENTITY"
    sign_app "$DESKTOP_APP"
    verify_full_bundle "$DESKTOP_APP"
    verify_desktop_bundle "$DESKTOP_APP"
    verify_codesign "$DESKTOP_APP"
    finish_app_artifact "$DESKTOP_APP" "$DESKTOP_ZIP" "$DESKTOP_DMG"
    ZIPS+=("$DESKTOP_ZIP")
    [ -f "$DESKTOP_DMG" ] && DMGS+=("$DESKTOP_DMG")
  fi
done
fi

# Keep the historic cask/download filenames as aliases for the public primary artifact. During the
# Apple-Silicon-first phase that is arm64; a future universal release can take precedence unchanged.
COMPAT_ZIP=""
COMPAT_DMG=""
PRIMARY_ZIP="${UNIVERSAL_ZIP:-$ARM64_ZIP}"
PRIMARY_DMG="${UNIVERSAL_DMG:-$ARM64_DMG}"
if [ -n "$PRIMARY_ZIP" ]; then
  COMPAT_ZIP="$BUILD_DIR/Dory-$VERSION.zip"
  copy_alias "$PRIMARY_ZIP" "$COMPAT_ZIP"
  ZIPS+=("$COMPAT_ZIP")
fi
if [ -n "$PRIMARY_DMG" ]; then
  COMPAT_DMG="$BUILD_DIR/Dory-$VERSION.dmg"
  copy_alias "$PRIMARY_DMG" "$COMPAT_DMG"
  DMGS+=("$COMPAT_DMG")
fi

# ---- Extra release flavors ---------------------------------------------------------------
# lite: app only, from the public primary archive.
LITE_ZIP=""
if [ "${DORY_BUNDLE_ENGINE:-1}" = "1" ] && [ "${DORY_BUILD_LITE:-0}" = "1" ]; then
  LITE_ARCHIVE="${UNIVERSAL_ARCHIVE:-$FIRST_ARCHIVE}"
  if [ -n "$LITE_ARCHIVE" ] && [ -d "$LITE_ARCHIVE/Products/Applications/Dory.app" ]; then
    echo "==> Building lite app (no bundled engine)..."
    LITE_DIR="$BUILD_DIR/export-lite"
    LITE_APP="$LITE_DIR/Dory.app"
    rm -rf "$LITE_DIR"
    mkdir -p "$LITE_DIR"
    cp -R "$LITE_ARCHIVE/Products/Applications/Dory.app" "$LITE_DIR/"
    scripts/sign-sparkle-for-distribution.sh "$LITE_APP" "$SIGN_IDENTITY"
    sign_app "$LITE_APP"
    verify_codesign "$LITE_APP"
    LITE_ZIP="$BUILD_DIR/Dory-$VERSION-lite.zip"
    zip_app "$LITE_APP" "$LITE_ZIP"
    if [ "${DORY_SKIP_NOTARIZE:-0}" = "1" ]; then
      echo "==> Skipping notarization for $LITE_ZIP (DORY_SKIP_NOTARIZE=1)"
    else
      echo "==> Notarizing lite app..."
      notarize "$LITE_ZIP"
      stapler_with_retry staple "$LITE_APP"
      validate_stapled_app "$LITE_APP"
      zip_app "$LITE_APP" "$LITE_ZIP"
    fi
  fi
fi

# app-update: edition-specific, self-contained application updates. Sparkle replaces Dory.app, so
# each feed must retain the engine and the exact Lean or Desktop capability selected by the user.
APP_UPDATE_ZIP=""
DESKTOP_APP_UPDATE_ZIP=""
if [ "${DORY_BUNDLE_ENGINE:-1}" = "1" ] && [ "${DORY_BUILD_APP_UPDATE:-1}" = "1" ]; then
  UPDATE_SOURCE_APP="${UNIVERSAL_APP:-$ARM64_APP}"
  UPDATE_ARCHES="arm64"
  [ -z "$UNIVERSAL_APP" ] || UPDATE_ARCHES="arm64 amd64"
  if [ -n "$UPDATE_SOURCE_APP" ] && [ -d "$UPDATE_SOURCE_APP" ]; then
    echo "==> Building self-contained app update bundle..."
    UPDATE_DIR="$BUILD_DIR/export-app-update"
    UPDATE_APP="$UPDATE_DIR/Dory.app"
    rm -rf "$UPDATE_DIR"
    mkdir -p "$UPDATE_DIR"
    ditto "$UPDATE_SOURCE_APP" "$UPDATE_APP"
    scripts/validate-app-update-payload.sh "$UPDATE_APP" "$UPDATE_ARCHES" core
    # The SBOM inventories the exact notarized full app. Re-signing this copy would change the main
    # executable and CodeResources, making Sparkle install different bytes than the direct app.
    verify_codesign "$UPDATE_APP"
    APP_UPDATE_ZIP="$BUILD_DIR/Dory-$VERSION-app-update.zip"
    finish_zip_update_artifact "$UPDATE_APP" "$APP_UPDATE_ZIP"
  fi
  if [ -n "$DESKTOP_APP" ] && [ -d "$DESKTOP_APP" ]; then
    echo "==> Building self-contained Desktop app update bundle..."
    DESKTOP_UPDATE_DIR="$BUILD_DIR/export-desktop-app-update"
    DESKTOP_UPDATE_APP="$DESKTOP_UPDATE_DIR/Dory.app"
    rm -rf "$DESKTOP_UPDATE_DIR"
    mkdir -p "$DESKTOP_UPDATE_DIR"
    ditto "$DESKTOP_APP" "$DESKTOP_UPDATE_APP"
    scripts/validate-app-update-payload.sh "$DESKTOP_UPDATE_APP" arm64 desktop
    verify_codesign "$DESKTOP_UPDATE_APP"
    DESKTOP_APP_UPDATE_ZIP="$BUILD_DIR/Dory-$VERSION-desktop-app-update.zip"
    finish_zip_update_artifact "$DESKTOP_UPDATE_APP" "$DESKTOP_APP_UPDATE_ZIP"
  fi
fi

# Headless runtime is arm64 during the Apple-Silicon-first release phase.
RUNTIME_TAR=""
if [ "${DORY_BUNDLE_ENGINE:-1}" = "1" ] && [ "${DORY_BUILD_RUNTIME:-1}" = "1" ] && [ -n "$ARM64_APP" ]; then
  echo "==> Packaging standalone engine runtime..."
  RUNTIME_NAME="dory-engine-$VERSION-arm64"
  RUNTIME_DIR="$BUILD_DIR/runtime/$RUNTIME_NAME"
  rm -rf "$BUILD_DIR/runtime"
  mkdir -p "$RUNTIME_DIR/bin" "$RUNTIME_DIR/share/dory"
  cp "$ARM64_APP/Contents/Helpers/dory-hv" "$RUNTIME_DIR/bin/"
  cp "$ARM64_APP/Contents/Helpers/gvproxy" "$RUNTIME_DIR/bin/"
  cp "$ARM64_APP/Contents/Helpers/dory-dataplane-proxy" "$RUNTIME_DIR/bin/"
  cp "$ARM64_APP/Contents/Resources/dory-hv-kernel-arm64.lzfse" "$RUNTIME_DIR/share/dory/"
  [ -f "$ARM64_APP/Contents/Resources/dory-agent-linux-arm64" ] && cp "$ARM64_APP/Contents/Resources/dory-agent-linux-arm64" "$RUNTIME_DIR/share/dory/"
  if [ -f "$ARM64_APP/Contents/Resources/dory-engine-rootfs-arm64.ext4.lzfse" ]; then
    cp "$ARM64_APP/Contents/Resources/dory-engine-rootfs-arm64.ext4.lzfse" "$RUNTIME_DIR/share/dory/dory-engine-rootfs.ext4.lzfse"
  elif [ -f "$ARM64_APP/Contents/Resources/dory-engine-rootfs.ext4.lzfse" ]; then
    cp "$ARM64_APP/Contents/Resources/dory-engine-rootfs.ext4.lzfse" "$RUNTIME_DIR/share/dory/"
  fi
  cp scripts/runtime/dory-engine "$RUNTIME_DIR/dory-engine"
  chmod 0755 "$RUNTIME_DIR/dory-engine"
  cat > "$RUNTIME_DIR/README.md" <<EOF
# dory-engine $VERSION (arm64)

Dory's container engine as a standalone, Colima-style runtime: one shared Linux VM running
dockerd, with virtio free-page reporting. Host-pressure reclaim remains opt-in and experimental.

    ./dory-engine start          # boots the engine; bundled FEX/amd64 is on by default
    ./dory-engine start --no-amd64 # explicit native-only opt-out
    ./dory-engine start --lan-visible # opt in to wildcard publication for wildcard Docker binds
    docker context use dory-engine
    docker run --rm alpine echo hello

\`dory-engine stop|status|env\` manage it. Requires macOS 15+ on Apple silicon.
EOF
  tar -czf "$BUILD_DIR/$RUNTIME_NAME.tar.gz" -C "$BUILD_DIR/runtime" "$RUNTIME_NAME"
  RUNTIME_TAR="$BUILD_DIR/$RUNTIME_NAME.tar.gz"
fi

SBOM=""
DESKTOP_SBOM=""
SBOM_APP="${UNIVERSAL_APP:-$ARM64_APP}"
if [ -n "$SBOM_APP" ] && [ -d "$SBOM_APP" ]; then
  SBOM="$BUILD_DIR/Dory-$VERSION.cdx.json"
  echo "==> Generating exact app-tree CycloneDX SBOM..."
  scripts/generate-release-sbom.py \
    --app "$SBOM_APP" --version "$VERSION" --source-commit "$SOURCE_COMMIT" --output "$SBOM"
  scripts/verify-release-sbom.py \
    --sbom "$SBOM" --app "$SBOM_APP" --version "$VERSION" --source-commit "$SOURCE_COMMIT"
fi
if [ -n "$DESKTOP_APP" ] && [ -d "$DESKTOP_APP" ]; then
  DESKTOP_SBOM="$BUILD_DIR/Dory-$VERSION-desktop.cdx.json"
  echo "==> Generating exact Desktop app-tree CycloneDX SBOM..."
  scripts/generate-release-sbom.py \
    --app "$DESKTOP_APP" --version "$VERSION" --source-commit "$SOURCE_COMMIT" --output "$DESKTOP_SBOM"
  scripts/verify-release-sbom.py \
    --sbom "$DESKTOP_SBOM" --app "$DESKTOP_APP" --version "$VERSION" --source-commit "$SOURCE_COMMIT"
fi

DEFAULT_ZIP="${COMPAT_ZIP:-${UNIVERSAL_ZIP:-${ZIPS[0]:-}}}"
DEFAULT_DMG="${COMPAT_DMG:-${UNIVERSAL_DMG:-}}"
DEFAULT_SHA256=""
[ -n "$DEFAULT_ZIP" ] && DEFAULT_SHA256="$(sha256_file "$DEFAULT_ZIP")"

APPCAST_ZIP="$DEFAULT_ZIP"
if [ "${DORY_APPCAST_PREFER_APP_UPDATE:-1}" = "1" ] && [ -n "$APP_UPDATE_ZIP" ] && [ -f "$APP_UPDATE_ZIP" ]; then
  APPCAST_ZIP="$APP_UPDATE_ZIP"
fi
if [ -n "${DORY_APPCAST_ZIP:-}" ]; then
  [ -f "$DORY_APPCAST_ZIP" ] || release_error "DORY_APPCAST_ZIP does not exist: $DORY_APPCAST_ZIP"
  APPCAST_ZIP="$DORY_APPCAST_ZIP"
fi

APPCAST=""
DESKTOP_APPCAST=""
if [ "$(build_appcast_enabled)" = "1" ]; then
  [ -n "$APPCAST_ZIP" ] || release_error "cannot generate Sparkle appcast without an app update artifact"
  echo "==> Generating Sparkle appcast for $(basename "$APPCAST_ZIP")..."
  APPCAST="$BUILD_DIR/appcast.xml"
  scripts/generate-appcast.sh "$VERSION" "$BUILD" "$APPCAST_ZIP" "$APPCAST" "website/public/appcast.xml" >/dev/null
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
for artifact in "$LITE_ZIP" "$APP_UPDATE_ZIP" "$DESKTOP_APP_UPDATE_ZIP" "$RUNTIME_TAR" "$SBOM" "$DESKTOP_SBOM"; do
  [ -n "$artifact" ] && [ -f "$artifact" ] || continue
  echo "    $artifact  (sha256: $(sha256_file "$artifact"))"
done
for artifact in "${COMPONENT_ASSETS[@]}"; do
  [ -f "$artifact" ] || continue
  echo "    $artifact  (sha256: $(sha256_file "$artifact"))"
done

MANIFEST_ARTIFACTS=()
if [ "${#ZIPS[@]}" -gt 0 ]; then
  for artifact in "${ZIPS[@]}"; do
    MANIFEST_ARTIFACTS+=("$artifact")
  done
fi
if [ "${#DMGS[@]}" -gt 0 ]; then
  for artifact in "${DMGS[@]}"; do
    MANIFEST_ARTIFACTS+=("$artifact")
  done
fi
MANIFEST_ARTIFACTS+=("$LITE_ZIP" "$APP_UPDATE_ZIP" "$DESKTOP_APP_UPDATE_ZIP" "$RUNTIME_TAR" "$APPCAST" "$DESKTOP_APPCAST" "$SBOM" "$DESKTOP_SBOM")
if [ "${#COMPONENT_ASSETS[@]}" -gt 0 ]; then
  MANIFEST_ARTIFACTS+=("${COMPONENT_ASSETS[@]}")
fi
MANIFEST="$(write_release_manifest "${MANIFEST_ARTIFACTS[@]}")"
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
    echo "app_update=$APP_UPDATE_ZIP"
    echo "desktop_app_update=$DESKTOP_APP_UPDATE_ZIP"
    echo "runtime=$RUNTIME_TAR"
    echo "sbom=$SBOM"
    echo "desktop_sbom=$DESKTOP_SBOM"
    echo "manifest=$MANIFEST"
    echo "appcast=$APPCAST"
    echo "desktop_appcast=$DESKTOP_APPCAST"
    echo "component_catalog=$(path_if_exists "$COMPONENT_OUTPUT_DIR/catalog.json")"
    echo "component_catalog_signature=$(path_if_exists "$COMPONENT_OUTPUT_DIR/catalog.json.sig")"
    echo "component_directory=$COMPONENT_OUTPUT_DIR"
    echo "appcast_zip=$APPCAST_ZIP"
    echo "zip_arm64=$(path_if_exists "$BUILD_DIR/Dory-$VERSION-arm64.zip")"
    echo "zip_x86_64=$(path_if_exists "$BUILD_DIR/Dory-$VERSION-x86_64.zip")"
    echo "zip_universal=$(path_if_exists "$BUILD_DIR/Dory-$VERSION-universal.zip")"
    echo "dmg_arm64=$(path_if_exists "$BUILD_DIR/Dory-$VERSION-arm64.dmg")"
    echo "zip_desktop_arm64=$(path_if_exists "$BUILD_DIR/Dory-$VERSION-desktop-arm64.zip")"
    echo "dmg_desktop_arm64=$(path_if_exists "$BUILD_DIR/Dory-$VERSION-desktop-arm64.dmg")"
    echo "dmg_x86_64=$(path_if_exists "$BUILD_DIR/Dory-$VERSION-x86_64.dmg")"
    echo "dmg_universal=$(path_if_exists "$BUILD_DIR/Dory-$VERSION-universal.dmg")"
  } >> "$GITHUB_OUTPUT"
fi
