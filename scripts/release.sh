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
             /Applications/Xcode.app /Applications/Xcode-*.app "$HOME"/Applications/Xcode*.app; do
    [ -x "$app/Contents/Developer/usr/bin/xcodebuild" ] && { export DEVELOPER_DIR="$app/Contents/Developer"; break; }
  done
fi
cd "$(dirname "${BASH_SOURCE[0]}")/.."

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
  local candidate
  candidate="$(python3 - "$BUILD_DIR" <<'PY'
import os
import sys

print(os.path.realpath(os.path.abspath(sys.argv[1])))
PY
)"
  case "$(basename "$candidate")" in
    release-build*) ;;
    *) release_error "DORY_RELEASE_BUILD_DIR must be a dedicated release-build* directory: $candidate" ;;
  esac
  case "$candidate" in
    /|"$HOME"|"$(pwd -P)") release_error "refusing unsafe release build directory: $candidate" ;;
  esac
  [ ! -L "$BUILD_DIR" ] || release_error "release build directory cannot be a symlink: $BUILD_DIR"
  BUILD_DIR="$candidate"
  DERIVED_DATA_DIR="$BUILD_DIR/DerivedData"
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

preflight_public_toolchain() {
  local version
  version="$(xcodebuild -version)"
  printf '%s\n' "$version" | grep -Fx 'Xcode 26.6' >/dev/null \
    && printf '%s\n' "$version" | grep -Fx 'Build version 17F109' >/dev/null \
    || release_error "public releases require the pinned Xcode 26.6 build 17F109 toolchain"
}

preflight_public_release() {
  [ "${DORY_PUBLIC_RELEASE:-0}" = "1" ] || return 0

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
  [ "${DORY_APPCAST_PREFER_APP_UPDATE:-1}" = "1" ] \
    || release_error "public releases must point Sparkle at the self-contained app-update ZIP"
  [ "${DORY_BUILD_LITE:-1}" = "1" ] \
    || release_error "public releases must generate the documented lite ZIP"
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
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=4 "$app"
}

validate_stapled_dmg() {
  local dmg="$1" assessment
  echo "==> Validating stapled DMG ticket + Gatekeeper assessment..."
  xcrun stapler validate "$dmg"
  assessment="$(spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg" 2>&1)" \
    || release_error "Gatekeeper rejected stapled DMG: $dmg"
  printf '%s\n' "$assessment"
  printf '%s\n' "$assessment" | grep -Fx 'source=Notarized Developer ID' >/dev/null \
    || release_error "stapled DMG is not accepted as Notarized Developer ID: $dmg"
}

verify_full_bundle() {
  local app="$1" helpers resources launch_agent asset_arch helper cli_version
  helpers="$app/Contents/Helpers"
  resources="$app/Contents/Resources"
  launch_agent="$resources/dev.dory.doryd.plist"

  echo "==> Verifying full clean-Mac bundle payload..."
  for helper in doryd dorydctl dory-vmm dory-network-helper dory-dataplane-proxy dory-hv gvproxy docker docker-buildx docker-compose kubectl dory dory-doctor; do
    assert_executable_exists "$helpers/$helper" "bundled helper"
  done
  for helper in doryd dorydctl dory-vmm dory-network-helper dory-dataplane-proxy dory-hv; do
    assert_macho_arches "$helpers/$helper" "$HELPER_ARCHES"
  done
  for helper in gvproxy docker docker-buildx docker-compose kubectl; do
    assert_macho_arches "$helpers/$helper" "$HOST_CLI_ARCHES"
  done
  scripts/verify-macos-deployment-targets.sh "$app" "$HELPER_ARCHES"
  for helper in doryd dorydctl dory-vmm dory-network-helper dory-dataplane-proxy dory-hv gvproxy docker docker-buildx docker-compose kubectl dory dory-doctor; do
    verify_developer_id_signature "$helpers/$helper"
  done
  cli_version="$("$helpers/dory" version)"
  [ "$cli_version" = "$VERSION" ] \
    || release_error "bundled dory CLI version $cli_version does not match $VERSION"

  for asset_arch in $BUNDLE_ARCHES; do
    assert_file_exists "$resources/dory-agent-linux-$asset_arch" "guest agent"
    assert_file_exists "$resources/dory-hv-kernel-$asset_arch" "raw dory-hv kernel"
    assert_file_exists "$resources/dory-hv-kernel-$asset_arch.lzfse" "compressed dory-hv kernel"
    assert_file_exists "$resources/dory-machine-rootfs-$asset_arch.ext4" "machine rootfs"
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
  assert_file_exists "$resources/dory-payload-sha256.txt" "payload digest inventory"
  assert_file_exists "$launch_agent" "bundled launchd plist"
  plutil -lint "$launch_agent" >/dev/null
  (cd "$app" && shasum -a 256 -c "Contents/Resources/dory-payload-sha256.txt" >/dev/null) \
    || release_error "$app payload digest inventory does not match bundled helpers/resources"
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
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
    <key>com.apple.security.virtualization</key>
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
  xcodebuild -project Dory.xcodeproj -scheme Dory -configuration Release \
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
    sign_dmg "$dmg"
    verify_dmg_signature "$dmg"
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
  local manifest="$BUILD_DIR/release-manifest.json" artifact first kind
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
      if [ "$first" -eq 0 ]; then
        echo ","
      fi
      first=0
      printf '    {"name":"%s","path":"%s","kind":"%s","bytes":%s,"sha256":"%s"}' \
        "$(json_escape "$(basename "$artifact")")" \
        "$(json_escape "$(basename "$artifact")")" \
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

rm -rf "$BUILD_DIR"
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
  fi
  verify_codesign "$APP"
  finish_app_artifact "$APP" "$ZIP" "$DMG"
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
done

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
if [ "${DORY_BUNDLE_ENGINE:-1}" = "1" ] && [ "${DORY_BUILD_LITE:-1}" = "1" ]; then
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
      xcrun stapler staple "$LITE_APP"
      validate_stapled_app "$LITE_APP"
      zip_app "$LITE_APP" "$LITE_ZIP"
    fi
  fi
fi

# app-update: a self-contained application update. Sparkle replaces Dory.app, so boot-critical
# guest assets stay in this artifact even though that makes updates larger.
APP_UPDATE_ZIP=""
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
    scripts/validate-app-update-payload.sh "$UPDATE_APP" "$UPDATE_ARCHES"
    # The SBOM inventories the exact notarized full app. Re-signing this copy would change the main
    # executable and CodeResources, making Sparkle install different bytes than the direct app.
    verify_codesign "$UPDATE_APP"
    APP_UPDATE_ZIP="$BUILD_DIR/Dory-$VERSION-app-update.zip"
    finish_zip_update_artifact "$UPDATE_APP" "$APP_UPDATE_ZIP"
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
SBOM_APP="${UNIVERSAL_APP:-$ARM64_APP}"
if [ -n "$SBOM_APP" ] && [ -d "$SBOM_APP" ]; then
  SBOM="$BUILD_DIR/Dory-$VERSION.cdx.json"
  echo "==> Generating exact app-tree CycloneDX SBOM..."
  scripts/generate-release-sbom.py \
    --app "$SBOM_APP" --version "$VERSION" --source-commit "$SOURCE_COMMIT" --output "$SBOM"
  scripts/verify-release-sbom.py \
    --sbom "$SBOM" --app "$SBOM_APP" --version "$VERSION" --source-commit "$SOURCE_COMMIT"
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
for artifact in "$LITE_ZIP" "$APP_UPDATE_ZIP" "$RUNTIME_TAR" "$SBOM"; do
  [ -n "$artifact" ] && [ -f "$artifact" ] || continue
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
MANIFEST_ARTIFACTS+=("$LITE_ZIP" "$APP_UPDATE_ZIP" "$RUNTIME_TAR" "$APPCAST" "$SBOM")
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
    echo "runtime=$RUNTIME_TAR"
    echo "sbom=$SBOM"
    echo "manifest=$MANIFEST"
    echo "appcast=$APPCAST"
    echo "appcast_zip=$APPCAST_ZIP"
    echo "zip_arm64=$(path_if_exists "$BUILD_DIR/Dory-$VERSION-arm64.zip")"
    echo "zip_x86_64=$(path_if_exists "$BUILD_DIR/Dory-$VERSION-x86_64.zip")"
    echo "zip_universal=$(path_if_exists "$BUILD_DIR/Dory-$VERSION-universal.zip")"
    echo "dmg_arm64=$(path_if_exists "$BUILD_DIR/Dory-$VERSION-arm64.dmg")"
    echo "dmg_x86_64=$(path_if_exists "$BUILD_DIR/Dory-$VERSION-x86_64.dmg")"
    echo "dmg_universal=$(path_if_exists "$BUILD_DIR/Dory-$VERSION-universal.dmg")"
  } >> "$GITHUB_OUTPUT"
fi
