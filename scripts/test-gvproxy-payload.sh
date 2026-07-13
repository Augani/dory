#!/bin/bash
# Offline regression tests for the gvproxy release pin and payload verifier.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=gvproxy-payload.sh
source "$SCRIPT_DIR/gvproxy-payload.sh"

fail() {
  echo "test-gvproxy-payload: FAIL: $*" >&2
  exit 1
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-gvproxy-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PAYLOAD="$TMP/gvproxy"
FAKE_LIPO="$TMP/lipo"

write_payload() {
  local version="$1"
  printf '%s\n' '#!/bin/sh' "printf '%s\\n' 'gvproxy version $version'" > "$PAYLOAD"
  chmod +x "$PAYLOAD"
}

write_lipo_arches() {
  local arches="$1"
  printf '%s\n' '#!/bin/sh' "printf '%s\\n' '$arches'" > "$FAKE_LIPO"
  chmod +x "$FAKE_LIPO"
}

write_payload "v0.8.9-dory1"
write_lipo_arches "x86_64 arm64"
PAYLOAD_SHA="$(shasum -a 256 "$PAYLOAD" | awk '{print $1}')"
DORY_LIPO_BIN="$FAKE_LIPO" dory_verify_gvproxy_payload "$PAYLOAD" "v0.8.9-dory1" "$PAYLOAD_SHA" \
  || fail "valid universal payload was rejected"

if DORY_LIPO_BIN="$FAKE_LIPO" dory_verify_gvproxy_payload \
  "$PAYLOAD" "v0.8.9-dory1" "0000000000000000000000000000000000000000000000000000000000000000" \
  >/dev/null 2>&1; then
  fail "checksum mismatch was accepted"
fi

write_lipo_arches "arm64"
if DORY_LIPO_BIN="$FAKE_LIPO" dory_verify_gvproxy_payload \
  "$PAYLOAD" "v0.8.9-dory1" "$PAYLOAD_SHA" >/dev/null 2>&1; then
  fail "single-slice payload was accepted"
fi

write_lipo_arches "x86_64 arm64"
write_payload "v0.8.8"
PAYLOAD_SHA="$(shasum -a 256 "$PAYLOAD" | awk '{print $1}')"
if DORY_LIPO_BIN="$FAKE_LIPO" dory_verify_gvproxy_payload \
  "$PAYLOAD" "v0.8.9-dory1" "$PAYLOAD_SHA" >/dev/null 2>&1; then
  fail "wrong gvproxy version was accepted"
fi

if (DORY_GVPROXY_VERSION="v0.9.0"; unset DORY_GVPROXY_SHA256; dory_gvproxy_validate_overrides) \
  >/dev/null 2>&1; then
  fail "unpaired version override was accepted"
fi
if (unset DORY_GVPROXY_VERSION; DORY_GVPROXY_SHA256="$PAYLOAD_SHA"; dory_gvproxy_validate_overrides) \
  >/dev/null 2>&1; then
  fail "unpaired checksum override was accepted"
fi
dory_gvproxy_validate_overrides || fail "default pinned metadata was rejected"
(DORY_GVPROXY_VERSION="v0.9.0"; DORY_GVPROXY_SHA256="$PAYLOAD_SHA"; \
  dory_gvproxy_validate_overrides) || fail "paired custom metadata was rejected"

[ "$DORY_GVPROXY_DEFAULT_VERSION" = "v0.8.9-dory1" ] || fail "default version pin regressed"
[ "$DORY_GVPROXY_DEFAULT_SHA256" = \
  "78904d7887361cbff9ec2f6c6789100752de801b340c801cc08a7bf21fa543d6" ] \
  || fail "default checksum pin regressed"

for script in "$REPO_ROOT/scripts/build.sh" "$REPO_ROOT/scripts/bundle-engine.sh"; do
  grep -q 'source .*gvproxy-payload.sh' "$script" || fail "$(basename "$script") does not load verifier"
  grep -q 'dory_verify_gvproxy_payload' "$script" || fail "$(basename "$script") does not verify payload"
  if grep -Eq 'podman/libexec/podman/gvproxy|command -v gvproxy|/tmp/dory-gvproxy-darwin' "$script"; then
    fail "$(basename "$script") still accepts ambient or stale gvproxy binaries"
  fi
done

ENGINE_MODE="$REPO_ROOT/Packages/ContainerizationEngine/Sources/dory-hv/EngineMode.swift"
grep -Fq 'gvproxy.arguments?.append(contentsOf: ["-ssh-port", "-1"])' "$ENGINE_MODE" \
  || fail "EngineMode does not disable gvproxy's unused SSH listener in flag-only mode"
grep -Fq '"-listen-qemu", "unix://\(lanDatapathSocket)"' "$ENGINE_MODE" \
  || fail "EngineMode does not give the source-preserving LAN bridge an independent QEMU port"
grep -Fq 'GVProxyQEMUFrameDecoder' "$REPO_ROOT/dory-core-swift/Sources/DoryCore/DirectIPBridge.swift" \
  || fail "the source-preserving LAN bridge does not frame gvproxy's QEMU stream"
if sed -n '/if let nativeIPv6 {/,/} else {/p' "$ENGINE_MODE" | grep -q -- '-ssh-port'; then
  fail "EngineMode passes the incompatible -ssh-port flag with the native IPv6 config"
fi

bash -n "$SCRIPT_DIR/gvproxy-payload.sh"
bash -n "$SCRIPT_DIR/build-gvproxy.sh"
bash -n "$SCRIPT_DIR/build.sh"
bash -n "$SCRIPT_DIR/bundle-engine.sh"
python3 -m py_compile "$SCRIPT_DIR/gvproxy-qemu-switch-gate.py"
echo "test-gvproxy-payload: PASS"
