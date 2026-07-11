#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dory-provenance.XXXXXX")"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "provenance test failed: $*" >&2
  exit 1
}

assert_different() {
  [ "$1" != "$2" ] || fail "$3"
}

assert_equal() {
  [ "$1" = "$2" ] || fail "$3"
}

mkdir -p "$TMP_ROOT/kernel/guest"
cp -R guest/kernel "$TMP_ROOT/kernel/guest/"

kernel_base="$(cd "$TMP_ROOT/kernel" && guest/kernel/input-fingerprint.sh arm64)"
kernel_amd64="$(cd "$TMP_ROOT/kernel" && guest/kernel/input-fingerprint.sh amd64)"
kernel_alias="$(cd "$TMP_ROOT/kernel" && guest/kernel/input-fingerprint.sh x86_64)"
assert_equal "$kernel_amd64" "$kernel_alias" "amd64 kernel aliases produced different fingerprints"

printf '\n# test mutation\n' >> "$TMP_ROOT/kernel/guest/kernel/dory-arm.config"
kernel_config_changed="$(cd "$TMP_ROOT/kernel" && guest/kernel/input-fingerprint.sh arm64)"
assert_different "$kernel_base" "$kernel_config_changed" "kernel config mutation did not invalidate fingerprint"
cp guest/kernel/dory-arm.config "$TMP_ROOT/kernel/guest/kernel/dory-arm.config"

kernel_patch="$(find "$TMP_ROOT/kernel/guest/kernel/patches" -type f -name '*.patch' | LC_ALL=C sort | sed -n '1p')"
[ -n "$kernel_patch" ] || fail "kernel fixture has no patch to fingerprint"
printf '\n# test mutation\n' >> "$kernel_patch"
kernel_patch_changed="$(cd "$TMP_ROOT/kernel" && guest/kernel/input-fingerprint.sh arm64)"
assert_different "$kernel_base" "$kernel_patch_changed" "kernel patch mutation did not invalidate fingerprint"

kernel_gpu="$(cd "$TMP_ROOT/kernel" && DORY_EXPERIMENTAL_GPU=1 guest/kernel/input-fingerprint.sh arm64)"
assert_different "$kernel_base" "$kernel_gpu" "GPU and headless kernels produced the same fingerprint"
if (cd "$TMP_ROOT/kernel" && DORY_EXPERIMENTAL_GPU=invalid guest/kernel/input-fingerprint.sh arm64 >/dev/null 2>&1); then
  fail "invalid GPU mode was accepted"
fi

mkdir -p "$TMP_ROOT/initfs/guest" "$TMP_ROOT/initfs/dory-core"
cp -R guest/initfs "$TMP_ROOT/initfs/guest/"
for item in Cargo.lock Cargo.toml agent pb proto sync; do
  cp -R "dory-core/$item" "$TMP_ROOT/initfs/dory-core/"
done

initfs_base="$(cd "$TMP_ROOT/initfs" && guest/initfs/input-fingerprint.sh arm64)"
initfs_alias="$(cd "$TMP_ROOT/initfs" && guest/initfs/input-fingerprint.sh aarch64)"
assert_equal "$initfs_base" "$initfs_alias" "arm64 initfs aliases produced different fingerprints"

printf '\n// test mutation\n' >> "$TMP_ROOT/initfs/dory-core/pb/proto/agent.proto"
initfs_proto_changed="$(cd "$TMP_ROOT/initfs" && guest/initfs/input-fingerprint.sh arm64)"
assert_different "$initfs_base" "$initfs_proto_changed" "protobuf mutation did not invalidate initfs fingerprint"
cp dory-core/pb/proto/agent.proto "$TMP_ROOT/initfs/dory-core/pb/proto/agent.proto"

mkdir -p "$TMP_ROOT/initfs/dory-core/ffi/src"
printf 'unrelated workspace source\n' > "$TMP_ROOT/initfs/dory-core/ffi/src/unrelated.rs"
initfs_unrelated="$(cd "$TMP_ROOT/initfs" && guest/initfs/input-fingerprint.sh arm64)"
assert_equal "$initfs_base" "$initfs_unrelated" "unrelated workspace source caused a false-stale initfs"

initfs_flags="$(cd "$TMP_ROOT/initfs" && RUSTFLAGS='-C opt-level=z' guest/initfs/input-fingerprint.sh arm64)"
assert_different "$initfs_base" "$initfs_flags" "effective Rust flags did not invalidate initfs fingerprint"

if (cd "$TMP_ROOT/initfs" && DORY_INITFS_SKIP_RUST_AGENT_BUILD=1 guest/initfs/build.sh arm64 >/dev/null 2>&1); then
  fail "skip-agent mode minted a provenance-verified initfs"
fi

bash -n \
  guest/kernel/input-fingerprint.sh guest/kernel/verify-build.sh guest/kernel/build.sh \
  guest/initfs/input-fingerprint.sh guest/initfs/verify-build.sh guest/initfs/build.sh \
  scripts/release.sh scripts/bundle-engine.sh

echo "guest build provenance tests passed"
