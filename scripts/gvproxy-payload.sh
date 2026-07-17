#!/bin/bash
# Shared gvproxy supply-chain policy for debug and release bundles.
#
# DORY_GVPROXY is the only supported local-binary override. The override is still verified against
# the pinned Dory dual-stack derivative metadata by default. To test another audited build, set both
# DORY_GVPROXY_VERSION and DORY_GVPROXY_SHA256; setting only one is rejected.

DORY_GVPROXY_DEFAULT_VERSION="v0.8.9-dory2"
DORY_GVPROXY_DEFAULT_SHA256="47c278f1636736ba552de3d2f0e68409cdc968d63bc02149637e449f40274459"

dory_gvproxy_validate_overrides() {
  local version_override="${DORY_GVPROXY_VERSION:-}"
  local sha_override="${DORY_GVPROXY_SHA256:-}"

  if { [ -n "$version_override" ] && [ -z "$sha_override" ]; } \
    || { [ -z "$version_override" ] && [ -n "$sha_override" ]; }; then
    echo "error: DORY_GVPROXY_VERSION and DORY_GVPROXY_SHA256 must be set together" >&2
    return 1
  fi

  local version="${version_override:-$DORY_GVPROXY_DEFAULT_VERSION}"
  local sha="${sha_override:-$DORY_GVPROXY_DEFAULT_SHA256}"
  case "$version" in
    v[0-9]*) ;;
    *) echo "error: invalid gvproxy version '$version' (expected a v-prefixed release tag)" >&2; return 1 ;;
  esac
  case "$version" in
    *[!A-Za-z0-9._+-]*) echo "error: invalid characters in gvproxy version '$version'" >&2; return 1 ;;
  esac
  case "$sha" in
    *[!0-9A-Fa-f]*|"") echo "error: invalid gvproxy SHA-256 '$sha'" >&2; return 1 ;;
  esac
  if [ "${#sha}" -ne 64 ]; then
    echo "error: invalid gvproxy SHA-256 length (${#sha}, expected 64)" >&2
    return 1
  fi
}

dory_gvproxy_version() {
  printf '%s\n' "${DORY_GVPROXY_VERSION:-$DORY_GVPROXY_DEFAULT_VERSION}"
}

dory_gvproxy_expected_sha256() {
  printf '%s\n' "${DORY_GVPROXY_SHA256:-$DORY_GVPROXY_DEFAULT_SHA256}" \
    | tr '[:upper:]' '[:lower:]'
}

dory_gvproxy_file_sha256() {
  local file="$1" shasum_bin="${DORY_SHASUM_BIN:-}"
  if [ -z "$shasum_bin" ]; then
    if [ -x /usr/bin/shasum ]; then
      shasum_bin="/usr/bin/shasum"
    else
      shasum_bin="$(command -v shasum 2>/dev/null || true)"
    fi
  fi
  if [ -z "$shasum_bin" ] || [ ! -x "$shasum_bin" ]; then
    echo "error: shasum is required to verify gvproxy" >&2
    return 1
  fi
  "$shasum_bin" -a 256 "$file" | awk '{print $1}' | tr '[:upper:]' '[:lower:]'
}

dory_verify_gvproxy_payload() {
  local file="$1" expected_version="$2" expected_sha="$3"
  local actual_sha lipo_bin actual_arches actual_version required_arch

  if [ ! -f "$file" ] || [ ! -x "$file" ]; then
    echo "error: gvproxy payload is not an executable file: $file" >&2
    return 1
  fi

  if ! actual_sha="$(dory_gvproxy_file_sha256 "$file")"; then
    return 1
  fi
  expected_sha="$(printf '%s' "$expected_sha" | tr '[:upper:]' '[:lower:]')"
  if [ "$actual_sha" != "$expected_sha" ]; then
    echo "error: gvproxy SHA-256 mismatch (expected $expected_sha, got $actual_sha)" >&2
    return 1
  fi

  lipo_bin="${DORY_LIPO_BIN:-}"
  if [ -z "$lipo_bin" ]; then
    if [ -x /usr/bin/lipo ]; then
      lipo_bin="/usr/bin/lipo"
    else
      lipo_bin="$(command -v lipo 2>/dev/null || true)"
    fi
  fi
  if [ -z "$lipo_bin" ] || [ ! -x "$lipo_bin" ]; then
    echo "error: lipo is required to verify the universal gvproxy payload" >&2
    return 1
  fi
  actual_arches="$("$lipo_bin" -archs "$file" 2>/dev/null || true)"
  for required_arch in arm64 x86_64; do
    case " $actual_arches " in
      *" $required_arch "*) ;;
      *)
        echo "error: gvproxy is not universal (missing $required_arch; found: ${actual_arches:-none})" >&2
        return 1
        ;;
    esac
  done

  actual_version="$("$file" -version 2>&1 | tr -d '\r' | sed -n '1p' || true)"
  if [ "$actual_version" != "gvproxy version $expected_version" ]; then
    echo "error: gvproxy version mismatch (expected '$expected_version', got '${actual_version:-no output}')" >&2
    return 1
  fi
}

# A Developer ID signature changes a Mach-O file's SHA-256, so an exact release candidate has two
# identities that must both remain bound: the reproducible pre-signing build hash in provenance and
# the signed file hash sealed by the app's payload inventory. Never compare a signed helper directly
# with DORY_GVPROXY_DEFAULT_SHA256; that would reject every correctly signed candidate.
dory_verify_signed_gvproxy_payload() {
  local file="$1" provenance="$2" inventory="$3"
  local actual_sha expected_build_sha provenance_build_sha inventory_sha codesign_bin details

  [ -s "$provenance" ] || {
    echo "error: signed gvproxy provenance is missing: $provenance" >&2
    return 1
  }
  [ -s "$inventory" ] || {
    echo "error: signed gvproxy payload inventory is missing: $inventory" >&2
    return 1
  }
  actual_sha="$(dory_gvproxy_file_sha256 "$file")" || return 1
  dory_verify_gvproxy_payload "$file" "$(dory_gvproxy_version)" "$actual_sha" || return 1

  expected_build_sha="$(dory_gvproxy_expected_sha256)"
  provenance_build_sha="$(awk -F= '
    $1 == "verified_sha256" { count += 1; value = $2 }
    END { if (count == 1) print value; else exit 1 }
  ' "$provenance")" || {
    echo "error: gvproxy provenance must contain exactly one verified_sha256" >&2
    return 1
  }
  if [ "$provenance_build_sha" != "$expected_build_sha" ]; then
    echo "error: gvproxy reproducible-build SHA-256 mismatch (expected $expected_build_sha, got $provenance_build_sha)" >&2
    return 1
  fi

  inventory_sha="$(awk '
    $2 == "Contents/Helpers/gvproxy" { count += 1; value = $1 }
    END { if (count == 1) print value; else exit 1 }
  ' "$inventory")" || {
    echo "error: payload inventory must contain exactly one Contents/Helpers/gvproxy entry" >&2
    return 1
  }
  if [ "$inventory_sha" != "$actual_sha" ]; then
    echo "error: signed gvproxy SHA-256 is not sealed by the payload inventory (expected $inventory_sha, got $actual_sha)" >&2
    return 1
  fi

  codesign_bin="${DORY_CODESIGN_BIN:-$(command -v codesign 2>/dev/null || true)}"
  [ -n "$codesign_bin" ] && [ -x "$codesign_bin" ] || {
    echo "error: codesign is required to verify signed gvproxy" >&2
    return 1
  }
  "$codesign_bin" --verify --strict "$file" >/dev/null 2>&1 || {
    echo "error: signed gvproxy has an invalid code signature" >&2
    return 1
  }
  details="$("$codesign_bin" -dv --verbose=4 "$file" 2>&1)" || {
    echo "error: could not inspect signed gvproxy identity" >&2
    return 1
  }
  printf '%s\n' "$details" | grep -q '^Authority=Developer ID Application' || {
    echo "error: gvproxy is not signed with a Developer ID Application identity" >&2
    return 1
  }
}
