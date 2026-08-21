#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=host-cli-payload.sh
source "$ROOT/scripts/host-cli-payload.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-host-cli.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "test-host-cli-payload: FAIL: $*" >&2; exit 1; }

dory_host_cli_validate_metadata || fail "default pinned metadata was rejected"
[ "$(dory_host_cli_version kubectl)" = v1.36.1 ] || fail "kubectl version pin regressed"
[ "$(dory_host_cli_version docker)" = 29.0.1 ] || fail "Docker CLI version pin regressed"
[ "$(dory_host_cli_version docker-buildx)" = v0.34.1 ] || fail "Buildx version pin regressed"
[ "$(dory_host_cli_version docker-compose)" = v2.39.2 ] || fail "Compose version pin regressed"

printf 'payload\n' > "$TMP/cli"
sha="$(shasum -a 256 "$TMP/cli" | awk '{print $1}')"
dory_verify_host_cli_payload "$TMP/cli" "$sha" || fail "valid payload was rejected"
if dory_verify_host_cli_payload "$TMP/cli" 0000000000000000000000000000000000000000000000000000000000000000 \
  >/dev/null 2>&1; then
  fail "checksum mismatch was accepted"
fi

if (DORY_KUBECTL_VERSION=v9.9.9; unset DORY_KUBECTL_SHA256_ARM64 DORY_KUBECTL_SHA256_X86_64; \
  dory_host_cli_validate_metadata) >/dev/null 2>&1; then
  fail "unpaired kubectl version override was accepted"
fi
(DORY_KUBECTL_VERSION=v9.9.9 \
  DORY_KUBECTL_SHA256_ARM64="$sha" DORY_KUBECTL_SHA256_X86_64="$sha" \
  dory_host_cli_validate_metadata) || fail "paired kubectl override was rejected"

grep -q 'source scripts/host-cli-payload.sh' "$ROOT/scripts/bundle-engine.sh" \
  || fail "bundle-engine does not load the host CLI verifier"
grep -q 'dory_verify_host_cli_payload' "$ROOT/scripts/bundle-engine.sh" \
  || fail "bundle-engine does not verify downloaded host CLIs"
grep -Fq 'chmod 0644 "$HOST_CLI_PROVENANCE"' "$ROOT/scripts/bundle-engine.sh" \
  || fail "bundle-engine does not publish portable host CLI provenance permissions"
[ "$(grep -c 'dory_verify_host_cli_payload .*|| return 1' "$ROOT/scripts/bundle-engine.sh")" -eq 4 ] \
  || fail "host CLI checksum failures are not propagated out of conditional download functions"
grep -A2 'docker-buildx)' "$ROOT/scripts/bundle-engine.sh" | grep -q 'darwin_download_arch' \
  || fail "Buildx download does not use its arm64/amd64 Darwin asset names"
bash -n "$ROOT/scripts/host-cli-payload.sh" "$ROOT/scripts/bundle-engine.sh"
echo "test-host-cli-payload: PASS"
