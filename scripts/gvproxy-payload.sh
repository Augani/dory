#!/bin/bash
# Shared gvproxy supply-chain policy for debug and release bundles.
#
# DORY_GVPROXY is the only supported local-binary override. The override is still verified against
# the pinned Dory dual-stack derivative metadata by default. To test another audited build, set both
# DORY_GVPROXY_VERSION and DORY_GVPROXY_SHA256; setting only one is rejected.

DORY_GVPROXY_DEFAULT_VERSION="v0.8.9-dory1"
DORY_GVPROXY_DEFAULT_SHA256="78904d7887361cbff9ec2f6c6789100752de801b340c801cc08a7bf21fa543d6"

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
