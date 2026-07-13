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

assert_file_contains() {
  grep -Fq -- "$2" "$1" || fail "$1 does not contain required reproducibility wiring: $2"
}

source guest/kernel/config-policy.sh
source guest/kernel/docker-endpoint.sh
policy_config="$TMP_ROOT/kernel-policy.config"
: > "$policy_config"
dory_kernel_config_honors_policy "$policy_config" CONFIG_DRM_ARMADA n \
  || fail "omitted disabled Kconfig symbol was rejected"
printf '# CONFIG_DRM_ARMADA is not set\n' > "$policy_config"
dory_kernel_config_honors_policy "$policy_config" CONFIG_DRM_ARMADA n \
  || fail "explicitly disabled Kconfig symbol was rejected"
printf 'CONFIG_DRM_ARMADA=y\n' > "$policy_config"
if dory_kernel_config_honors_policy "$policy_config" CONFIG_DRM_ARMADA n; then
  fail "enabled Kconfig symbol satisfied an =n policy"
fi
printf 'CONFIG_DRM_ARMADA=m\n' > "$policy_config"
if dory_kernel_config_honors_policy "$policy_config" CONFIG_DRM_ARMADA n; then
  fail "module Kconfig symbol satisfied an =n policy"
fi
printf 'CONFIG_DRM_VIRTIO_GPU=y\n' > "$policy_config"
dory_kernel_config_honors_policy "$policy_config" CONFIG_DRM_VIRTIO_GPU y \
  || fail "enabled Kconfig symbol did not satisfy an =y policy"
printf 'CONFIG_DRM_VIRTIO_GPU=m\n' > "$policy_config"
if dory_kernel_config_honors_policy "$policy_config" CONFIG_DRM_VIRTIO_GPU y; then
  fail "module Kconfig symbol satisfied an =y policy"
fi

fake_docker="$TMP_ROOT/fake-docker"
fake_context="$TMP_ROOT/fake-docker-context"
fake_log="$TMP_ROOT/fake-docker.log"
printf '%s\n' \
  '#!/bin/bash' \
  'set -eu' \
  'if [ "${1:-}" = context ] && [ "${2:-}" = show ]; then' \
  '  IFS= read -r selected < "$FAKE_DOCKER_CONTEXT_FILE"' \
  '  printf "%s\\n" "$selected"' \
  '  exit 0' \
  'fi' \
  'if [ "${1:-}" = context ] && [ "${2:-}" = inspect ]; then' \
  '  printf "unix:///%s.sock\\n" "$3"' \
  '  exit 0' \
  'fi' \
  'printf "%s\\n" "$*" >> "$FAKE_DOCKER_LOG"' > "$fake_docker"
chmod +x "$fake_docker"
printf 'first\n' > "$fake_context"
export FAKE_DOCKER_CONTEXT_FILE="$fake_context" FAKE_DOCKER_LOG="$fake_log"
captured_endpoint="$(dory_kernel_resolve_docker_endpoint "$fake_docker")"
assert_equal "$captured_endpoint" "unix:///first.sock" "initial Docker endpoint was not captured"
printf 'second\n' > "$fake_context"
dory_kernel_docker "$fake_docker" "$captured_endpoint" cp build:/out/. staging/
dory_kernel_docker "$fake_docker" "$captured_endpoint" rm -f build
grep -Fqx -- '--host unix:///first.sock cp build:/out/. staging/' "$fake_log" \
  || fail "Docker copy was redirected after the active context changed"
grep -Fqx -- '--host unix:///first.sock rm -f build' "$fake_log" \
  || fail "Docker cleanup was redirected after the active context changed"
if grep -Fq 'second.sock' "$fake_log"; then
  fail "captured Docker operations consulted the changed active context"
fi
unset FAKE_DOCKER_CONTEXT_FILE FAKE_DOCKER_LOG

mkdir -p "$TMP_ROOT/kernel/guest"
cp -R guest/kernel "$TMP_ROOT/kernel/guest/"

kernel_base="$(cd "$TMP_ROOT/kernel" && guest/kernel/input-fingerprint.sh arm64)"
kernel_amd64="$(cd "$TMP_ROOT/kernel" && guest/kernel/input-fingerprint.sh amd64)"
kernel_alias="$(cd "$TMP_ROOT/kernel" && guest/kernel/input-fingerprint.sh x86_64)"
assert_equal "$kernel_amd64" "$kernel_alias" "amd64 kernel aliases produced different fingerprints"

for required_pin in \
  KERNEL_SOURCE_DATE_EPOCH=0 \
  KERNEL_BUILD_USER=dory \
  KERNEL_BUILD_HOST=builder \
  KERNEL_BUILD_VERSION=1; do
  assert_file_contains guest/kernel/PINS "$required_pin"
done
for required_env in \
  'SOURCE_DATE_EPOCH="$KERNEL_SOURCE_DATE_EPOCH"' \
  'KBUILD_BUILD_TIMESTAMP="@$KERNEL_SOURCE_DATE_EPOCH"' \
  'KBUILD_BUILD_USER="$KERNEL_BUILD_USER"' \
  'KBUILD_BUILD_HOST="$KERNEL_BUILD_HOST"' \
  'KBUILD_BUILD_VERSION="$KERNEL_BUILD_VERSION"' \
  'KCONFIG_NOTIMESTAMP=1' \
  'ZERO_AR_DATE=1' \
  'TZ=UTC' \
  'LC_ALL=C'; do
  assert_file_contains guest/kernel/build.sh "$required_env"
done

printf '\nKERNEL_SOURCE_DATE_EPOCH=1\n' >> "$TMP_ROOT/kernel/guest/kernel/PINS"
kernel_epoch_changed="$(cd "$TMP_ROOT/kernel" && guest/kernel/input-fingerprint.sh arm64)"
assert_different "$kernel_base" "$kernel_epoch_changed" "kernel epoch mutation did not invalidate fingerprint"
cp guest/kernel/PINS "$TMP_ROOT/kernel/guest/kernel/PINS"

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

mkdir -p "$TMP_ROOT/initfs/guest" "$TMP_ROOT/initfs/dory-core" "$TMP_ROOT/initfs/patches"
cp -R guest/initfs "$TMP_ROOT/initfs/guest/"
cp patches/fex-container-fd-isolation.patch "$TMP_ROOT/initfs/patches/"
for item in Cargo.lock Cargo.toml agent pb proto runc-wrapper sync; do
  cp -R "dory-core/$item" "$TMP_ROOT/initfs/dory-core/"
done

initfs_base="$(cd "$TMP_ROOT/initfs" && guest/initfs/input-fingerprint.sh arm64)"
initfs_alias="$(cd "$TMP_ROOT/initfs" && guest/initfs/input-fingerprint.sh aarch64)"
assert_equal "$initfs_base" "$initfs_alias" "arm64 initfs aliases produced different fingerprints"

printf '\n// test mutation\n' >> "$TMP_ROOT/initfs/dory-core/pb/proto/agent.proto"
initfs_proto_changed="$(cd "$TMP_ROOT/initfs" && guest/initfs/input-fingerprint.sh arm64)"
assert_different "$initfs_base" "$initfs_proto_changed" "protobuf mutation did not invalidate initfs fingerprint"
cp dory-core/pb/proto/agent.proto "$TMP_ROOT/initfs/dory-core/pb/proto/agent.proto"

printf '\n// test mutation\n' >> "$TMP_ROOT/initfs/dory-core/runc-wrapper/src/lib.rs"
initfs_wrapper_changed="$(cd "$TMP_ROOT/initfs" && guest/initfs/input-fingerprint.sh arm64)"
assert_different "$initfs_base" "$initfs_wrapper_changed" "dory-runc mutation did not invalidate initfs fingerprint"
cp dory-core/runc-wrapper/src/lib.rs "$TMP_ROOT/initfs/dory-core/runc-wrapper/src/lib.rs"

printf 'test mutation\n' >> "$TMP_ROOT/initfs/guest/initfs/vendor/fex-2607-dory1/FEX"
initfs_fex_changed="$(cd "$TMP_ROOT/initfs" && guest/initfs/input-fingerprint.sh arm64)"
assert_different "$initfs_base" "$initfs_fex_changed" "vendored FEX mutation did not invalidate initfs fingerprint"
cp guest/initfs/vendor/fex-2607-dory1/FEX "$TMP_ROOT/initfs/guest/initfs/vendor/fex-2607-dory1/FEX"

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
  guest/kernel/config-policy.sh guest/kernel/docker-endpoint.sh guest/kernel/input-fingerprint.sh \
  guest/kernel/verify-build.sh guest/kernel/build.sh \
  guest/initfs/input-fingerprint.sh guest/initfs/verify-build.sh guest/initfs/build.sh \
  scripts/release.sh scripts/bundle-engine.sh

echo "guest build provenance tests passed"
