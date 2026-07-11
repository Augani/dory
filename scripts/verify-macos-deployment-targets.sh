#!/bin/bash
# Fail a release when a shipped Mach-O slice requires a newer macOS than the runtime tier gate
# promises. Dory.app and its Virtualization.framework fallback support Sonoma; dory-hv is a
# separate macOS 15+ tier.
set -euo pipefail

APP="${1:?usage: verify-macos-deployment-targets.sh <Dory.app> [expected-architectures]}"
EXPECTED_ARCHES="${2:-${DORY_EXPECTED_HELPER_ARCHES:-}}"

release_error() {
  echo "deployment-target error: $*" >&2
  exit 1
}

command -v lipo >/dev/null 2>&1 || release_error "lipo is required"
command -v xcrun >/dev/null 2>&1 || release_error "xcrun is required"
VTOOL="$(xcrun --find vtool 2>/dev/null || true)"
OTOOL="$(xcrun --find otool 2>/dev/null || command -v otool || true)"
[ -n "$VTOOL" ] || [ -n "$OTOOL" ] \
  || release_error "neither vtool nor otool is available"

normalize_version() {
  awk -F. '{ printf "%d.%d.%d\n", $1 + 0, $2 + 0, $3 + 0 }' <<<"$1"
}

slice_minimum_macos() {
  local binary="$1" arch="$2" output minimum=""
  if [ -n "$VTOOL" ]; then
    output="$($VTOOL -arch "$arch" -show-build "$binary" 2>/dev/null || true)"
    minimum="$(awk '
      $1 == "platform" && $2 == "MACOS" { macos = 1; next }
      macos && $1 == "minos" { print $2; exit }
      $1 == "cmd" && $2 == "LC_VERSION_MIN_MACOSX" { legacy = 1; next }
      legacy && $1 == "version" { print $2; exit }
    ' <<<"$output")"
  fi
  if [ -z "$minimum" ] && [ -n "$OTOOL" ]; then
    output="$($OTOOL -arch "$arch" -l "$binary" 2>/dev/null || true)"
    minimum="$(awk '
      $1 == "cmd" && $2 == "LC_BUILD_VERSION" { build = 1; legacy = 0; next }
      build && $1 == "platform" && ($2 == "1" || $2 == "MACOS") { macos = 1; next }
      build && macos && $1 == "minos" { print $2; exit }
      $1 == "cmd" && $2 == "LC_VERSION_MIN_MACOSX" { legacy = 1; build = 0; next }
      legacy && $1 == "version" { print $2; exit }
    ' <<<"$output")"
  fi
  [ -n "$minimum" ] || return 1
  printf '%s\n' "$minimum"
}

verify_binary() {
  local relative="$1" expected="$2" binary
  local actual_arches arch minimum normalized_expected normalized_actual
  binary="$APP/Contents/$relative"
  [ -x "$binary" ] || release_error "missing executable $binary"
  actual_arches="$(lipo -archs "$binary" 2>/dev/null || true)"
  [ -n "$actual_arches" ] || release_error "$binary is not a Mach-O executable"
  for arch in $EXPECTED_ARCHES; do
    case " $actual_arches " in
      *" $arch "*) ;;
      *) release_error "$relative is missing expected $arch slice (has: $actual_arches)" ;;
    esac
  done

  normalized_expected="$(normalize_version "$expected")"
  for arch in $actual_arches; do
    minimum="$(slice_minimum_macos "$binary" "$arch" || true)"
    [ -n "$minimum" ] \
      || release_error "could not read the macOS deployment target for $relative ($arch)"
    normalized_actual="$(normalize_version "$minimum")"
    [ "$normalized_actual" = "$normalized_expected" ] \
      || release_error "$relative ($arch) has minimum macOS $minimum; expected exactly $expected"
    echo "==> Verified $relative ($arch) minimum macOS $minimum"
  done
}

verify_binary "MacOS/Dory" 14.0
verify_binary "Helpers/doryd" 14.0
verify_binary "Helpers/dorydctl" 14.0
verify_binary "Helpers/dory-vmm" 14.0
verify_binary "Helpers/dory-network-helper" 14.0
verify_binary "Helpers/dory-hv" 15.0
