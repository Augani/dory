#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

case "${1:-arm64}" in
  arm64|aarch64)
    ARCH=arm64
    TARGET=aarch64-unknown-linux-musl
    CROSS_CC="${DORY_AARCH64_LINUX_MUSL_CC:-}"
    DEFAULT_CROSS_CC=aarch64-linux-musl-gcc
    ;;
  amd64|x86_64)
    ARCH=amd64
    TARGET=x86_64-unknown-linux-musl
    CROSS_CC="${DORY_X86_64_LINUX_MUSL_CC:-}"
    DEFAULT_CROSS_CC=x86_64-linux-musl-gcc
    ;;
  *) echo "usage: $0 [arm64|amd64]" >&2; exit 64 ;;
esac

INPUTS=(
  guest/initfs/build.sh
  guest/initfs/init
  guest/initfs/PINS
  guest/initfs/vendor/docker-29.6.1-dory1/Dockerfile
  guest/initfs/vendor/docker-29.6.1-dory1/LICENSE.Moby
  guest/initfs/vendor/docker-29.6.1-dory1/README.md
  guest/initfs/vendor/docker-29.6.1-dory1/patches/docker-start-intent.patch
  guest/initfs/vendor/docker-29.6.1-dory1/rebuild.sh
  Config/DoryRendererProductionTuple.json
  guest/desktop/install-graphics-pack.sh
  guest/mesa/PINS
  guest/mesa/build.sh
  guest/mesa/dory-vulkan-compositor-probe.c
  guest/mesa/dory-vulkan-probe.c
  guest/mesa/input-fingerprint.sh
  guest/mesa/verify-build.sh
  scripts/renderer-production-tuple.py
  dory-core/Cargo.lock
  dory-core/Cargo.toml
)

# Only the guest Rust packages and their local transitive dependencies affect these binaries. Hashing
# unrelated workspace crates made a UI/FFI-only change invalidate a perfectly current initfs, while
# omitting protobuf sources let a protocol change falsely pass verification.
for package in agent pb proto runc-wrapper sync; do
  [ -d "dory-core/$package" ] || {
    echo "missing required guest Rust package: dory-core/$package" >&2
    exit 1
  }
  while IFS= read -r input; do
    INPUTS+=("$input")
  done < <(
    find "dory-core/$package" \
      -path '*/target' -prune -o \
      -path '*/tests' -prune -o \
      -path '*/examples' -prune -o \
      -path '*/benches' -prune -o \
      -type f \( -name '*.rs' -o -name '*.proto' -o -name Cargo.toml -o -name build.rs \) -print \
      | LC_ALL=C sort
  )
done

for optional in \
  .cargo/config .cargo/config.toml rust-toolchain rust-toolchain.toml \
  dory-core/.cargo/config dory-core/.cargo/config.toml \
  dory-core/rust-toolchain dory-core/rust-toolchain.toml; do
  [ ! -f "$optional" ] || INPUTS+=("$optional")
done


upper="$(printf '%s' "$ARCH" | tr '[:lower:]' '[:upper:]')"
docker_override_var="DORY_INITFS_DOCKER_TARBALL_${upper}"
docker_override_sha_var="DORY_INITFS_DOCKER_TARBALL_${upper}_SHA256"
docker_override_path="${!docker_override_var:-}"
docker_override_sha="${!docker_override_sha_var:-}"
if [ "$ARCH" = arm64 ]; then
  INPUTS+=(
    guest/initfs/vendor/fex-2607-dory1/Dockerfile
    guest/initfs/vendor/fex-2607-dory1/Dockerfile.dockerignore
    guest/initfs/vendor/fex-2607-dory1/FEX
    guest/initfs/vendor/fex-2607-dory1/FEXServer
    guest/initfs/vendor/fex-2607-dory1/BUILD_PACKAGES.txt
    guest/initfs/vendor/fex-2607-dory1/LICENSE.FEX
    guest/initfs/vendor/fex-2607-dory1/README.md
    guest/initfs/vendor/fex-2607-dory1/rebuild.sh
    patches/fex-container-fd-isolation.patch
    patches/fex-processor-id-stack-fix.patch
    patches/fex-restore-complete-signal-context.patch
  )
fi

if [ "$ARCH" = amd64 ]; then
  INPUTS+=(
    guest/mesa/build-pc-virgl2.sh
    guest/mesa/input-pc-virgl2-fingerprint.sh
    guest/mesa/verify-pc-virgl2-build.sh
    guest/initfs/PINS.pc-virgl2-x86_64
  )
fi

if command -v rust-lld >/dev/null 2>&1; then
  LINKER="$(command -v rust-lld)"
elif [ -n "$CROSS_CC" ] && command -v "$CROSS_CC" >/dev/null 2>&1; then
  LINKER="$(command -v "$CROSS_CC")"
elif command -v "$DEFAULT_CROSS_CC" >/dev/null 2>&1; then
  LINKER="$(command -v "$DEFAULT_CROSS_CC")"
else
  echo "no linker found for $TARGET; install rust-lld or $DEFAULT_CROSS_CC" >&2
  exit 1
fi

EFFECTIVE_RUSTFLAGS="${RUSTFLAGS:-}"
if [ "$(basename "$LINKER")" = rust-lld ]; then
  EFFECTIVE_RUSTFLAGS="$EFFECTIVE_RUSTFLAGS -C linker-flavor=ld.lld"
fi

# Include the Rust toolchain and effective build flags because both can change the static guest
# binary without changing source. Paths are relative to the repository so clones hash identically.
{
  printf 'schema=3\narch=%s\ntarget=%s\nsize_mb=%s\nrustflags=%s\n' \
    "$ARCH" "$TARGET" "${DORY_INITFS_SIZE_MB:-1024}" "$EFFECTIVE_RUSTFLAGS"
  rustc -Vv
  cargo -V
  printf 'linker_sha256=%s\n' "$(shasum -a 256 "$LINKER" | awk '{print $1}')"
  if [ -n "$docker_override_path" ]; then
    docker_override_receipt="${docker_override_path%.tgz}.receipt.json"
    [ -n "$docker_override_sha" ] || { echo "$docker_override_var requires $docker_override_sha_var" >&2; exit 64; }
    [ -f "$docker_override_path" ] || { echo "$docker_override_var does not name a file: $docker_override_path" >&2; exit 64; }
    [ -f "$docker_override_receipt" ] || { echo "Docker override is missing producer receipt: $docker_override_receipt" >&2; exit 64; }
    actual_override_sha="$(shasum -a 256 "$docker_override_path" | awk '{print $1}')"
    [ "$actual_override_sha" = "$docker_override_sha" ] || { echo "$docker_override_var sha256 mismatch: expected $docker_override_sha got $actual_override_sha" >&2; exit 1; }
    current_producer_input="$("$ROOT/guest/initfs/vendor/docker-29.6.1-dory1/rebuild.sh" input-sha256 "$ARCH")"
    python3 - "$docker_override_receipt" "$ARCH" "$actual_override_sha" "$current_producer_input" <<'PY'
import json
import pathlib
import sys

receipt = pathlib.Path(sys.argv[1])
arch = sys.argv[2]
actual = sys.argv[3]
current_input = sys.argv[4]
record = json.loads(receipt.read_text(encoding="utf-8"))
if record.get("arch") != arch:
    raise SystemExit(f"Docker override receipt arch mismatch: expected {arch}, got {record.get('arch')}")
if record.get("candidateStaticTarball", {}).get("sha256") != actual:
    raise SystemExit("Docker override receipt does not match tarball sha256")
receipt_input = record.get("producer", {}).get("inputSha256")
if receipt_input != current_input:
    raise SystemExit(f"Docker override producer input mismatch: receipt {receipt_input}, current {current_input}")
verification = record.get("runtimeVerification", {})
if verification.get("status") != "passed":
    raise SystemExit(f"Docker override runtime verification is not passed: {verification!r}")
PY
    printf 'docker_override_sha256=%s\n' "$actual_override_sha"
    printf 'docker_override_producer_input_sha256=%s\n' "$current_producer_input"
    printf 'docker_override_runtime_verification=passed\n'
  fi
  for input in "${INPUTS[@]}"; do
    printf 'input=%s\n' "$input"
    shasum -a 256 "$input"
  done
} | shasum -a 256 | awk '{print $1}'
