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

FAKE_CODESIGN="$TMP/codesign"
cat > "$FAKE_CODESIGN" <<'SH'
#!/bin/sh
case "$1" in
  --verify) exit 0 ;;
  -dv) printf '%s\n' 'Authority=Developer ID Application: Fixture (TEAMID)' >&2; exit 0 ;;
esac
exit 64
SH
chmod 0755 "$FAKE_CODESIGN"
PROVENANCE="$TMP/gvproxy-provenance.txt"
INVENTORY="$TMP/dory-payload-sha256.txt"
printf 'verified_sha256=%s\n' "$DORY_GVPROXY_DEFAULT_SHA256" > "$PROVENANCE"
printf '%s  Contents/Helpers/gvproxy\n' "$PAYLOAD_SHA" > "$INVENTORY"
DORY_LIPO_BIN="$FAKE_LIPO" DORY_CODESIGN_BIN="$FAKE_CODESIGN" \
  dory_verify_signed_gvproxy_payload "$PAYLOAD" "$PROVENANCE" "$INVENTORY" \
  || fail "valid signed-candidate identity chain was rejected"
printf '%064d  Contents/Helpers/gvproxy\n' 0 > "$INVENTORY"
if DORY_LIPO_BIN="$FAKE_LIPO" DORY_CODESIGN_BIN="$FAKE_CODESIGN" \
  dory_verify_signed_gvproxy_payload "$PAYLOAD" "$PROVENANCE" "$INVENTORY" \
  >/dev/null 2>&1; then
  fail "signed candidate outside the payload inventory was accepted"
fi
printf '%s  Contents/Helpers/gvproxy\n' "$PAYLOAD_SHA" > "$INVENTORY"

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
  "bd9183f5dbe2bd27d7ea57f2f2dd4d5ce26487eeb1fa8c82cd81bad4df50e0c0" ] \
  || fail "default checksum pin regressed"
for reproducible_input in \
  'GO_TOOLCHAIN="go1.26.5"' \
  'GO_MOD_SHA256="75848c190dca5cc7af27ebe017d5a4d59d4a117c97eaa6b8ac0359e58d868eec"' \
  'GO_SUM_SHA256="25b1a52ad3181030b6ccf92af5d69a1a4282f8f2342dad5348b5c954c304c4b3"' \
  'export GOTOOLCHAIN="$GO_TOOLCHAIN"' \
  'go test -mod=readonly' \
  'go build -mod=readonly' \
  '-segalign x86_64 0x1000 -segalign arm64 0x4000'; do
  grep -Fq "$reproducible_input" "$SCRIPT_DIR/build-gvproxy.sh" \
    || fail "gvproxy rebuild omits reproducible input: $reproducible_input"
done
if grep -Eq '^[[:space:]]*(export[[:space:]]+)?GOTOOLCHAIN=.*auto|[[:space:]]-mod=mod([[:space:]]|$)' \
    "$SCRIPT_DIR/build-gvproxy.sh"; then
  fail "gvproxy rebuild still permits a floating toolchain or mutable module graph"
fi

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
