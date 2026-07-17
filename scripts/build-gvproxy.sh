#!/bin/bash
# Build Dory's provenance-pinned dual-stack gvproxy from the audited upstream v0.8.9 source.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM_VERSION="v0.8.9"
DORY_VERSION="v0.8.9-dory2"
SOURCE_SHA256="6cbcb7959a5d90b59253ea6d8bdf0285e2cfbc3b301398704b41e3069293f4fb"
PATCH="$ROOT/patches/gvproxy-native-ipv6.patch"
PATCH_SHA256="3d6db9d9c2e6ff79b8abd334afe3664c84b84ca11a6308e8cc3d30f8fc05ab96"
GO_TOOLCHAIN="go1.26.5"
GO_MOD_SHA256="75848c190dca5cc7af27ebe017d5a4d59d4a117c97eaa6b8ac0359e58d868eec"
GO_SUM_SHA256="25b1a52ad3181030b6ccf92af5d69a1a4282f8f2342dad5348b5c954c304c4b3"
GO_PROXY="https://proxy.golang.org"
GO_SUMDB="sum.golang.org"
OUTPUT=""
PROVENANCE=""
RUN_TESTS=1

usage() {
  echo "usage: $0 --output PATH [--provenance PATH] [--skip-tests]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) OUTPUT="${2:?missing output path}"; shift 2 ;;
    --provenance) PROVENANCE="${2:?missing provenance path}"; shift 2 ;;
    --skip-tests) RUN_TESTS=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
[ -n "$OUTPUT" ] || { usage; exit 2; }

for command in curl patch tar go shasum; do
  command -v "$command" >/dev/null 2>&1 || { echo "build-gvproxy: missing $command" >&2; exit 1; }
done
LIPO="${DORY_LIPO_BIN:-$(command -v lipo 2>/dev/null || true)}"
[ -x "$LIPO" ] || { echo "build-gvproxy: lipo is required" >&2; exit 1; }

actual_patch_sha="$(shasum -a 256 "$PATCH" | awk '{print $1}')"
[ "$actual_patch_sha" = "$PATCH_SHA256" ] || {
  echo "build-gvproxy: patch digest mismatch (expected $PATCH_SHA256, got $actual_patch_sha)" >&2
  exit 1
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-gvproxy-build.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
ARCHIVE="$TMP/gvisor-tap-vsock.tar.gz"
SOURCE="$TMP/source"
mkdir -p "$SOURCE"
curl --fail --location --silent --show-error \
  "https://github.com/containers/gvisor-tap-vsock/archive/refs/tags/${UPSTREAM_VERSION}.tar.gz" \
  --output "$ARCHIVE"
actual_source_sha="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
[ "$actual_source_sha" = "$SOURCE_SHA256" ] || {
  echo "build-gvproxy: source digest mismatch (expected $SOURCE_SHA256, got $actual_source_sha)" >&2
  exit 1
}
tar -xzf "$ARCHIVE" -C "$SOURCE" --strip-components=1
patch --batch --forward -p1 -d "$SOURCE" < "$PATCH"

actual_go_mod_sha="$(shasum -a 256 "$SOURCE/go.mod" | awk '{print $1}')"
actual_go_sum_sha="$(shasum -a 256 "$SOURCE/go.sum" | awk '{print $1}')"
[ "$actual_go_mod_sha" = "$GO_MOD_SHA256" ] || {
  echo "build-gvproxy: go.mod digest mismatch (expected $GO_MOD_SHA256, got $actual_go_mod_sha)" >&2
  exit 1
}
[ "$actual_go_sum_sha" = "$GO_SUM_SHA256" ] || {
  echo "build-gvproxy: go.sum digest mismatch (expected $GO_SUM_SHA256, got $actual_go_sum_sha)" >&2
  exit 1
}

# A fixed binary digest requires a fixed compiler. GOTOOLCHAIN=auto changes output whenever Go's
# supported patch releases advance, so ignore the build host's Go environment and select one exact,
# checksum-database-verified toolchain. The module graph is immutable under -mod=readonly.
export GOENV=off
export GOTOOLCHAIN="$GO_TOOLCHAIN"
export GOFLAGS=""
export GOEXPERIMENT=""
export GOWORK=off
export GOPROXY="$GO_PROXY"
export GOSUMDB="$GO_SUMDB"
export CGO_ENABLED=0
export GOAMD64=v1
export GOARM64=v8.0
export TZ=UTC
export LC_ALL=C
export LANG=C
actual_go_toolchain="$(go env GOVERSION)"
[ "$actual_go_toolchain" = "$GO_TOOLCHAIN" ] || {
  echo "build-gvproxy: expected $GO_TOOLCHAIN, selected $actual_go_toolchain" >&2
  exit 1
}
(cd "$SOURCE" && go mod verify)
if [ "$RUN_TESTS" = 1 ]; then
  (cd "$SOURCE" && go test -mod=readonly ./pkg/services/dns ./pkg/tap ./pkg/virtualnetwork ./pkg/services/forwarder ./cmd/gvproxy)
fi

ldflags="-s -w -buildid= -X github.com/containers/gvisor-tap-vsock/pkg/types.gitVersion=$DORY_VERSION"
for arch in arm64 amd64; do
  (cd "$SOURCE" && \
    GOOS=darwin GOARCH="$arch" go build -mod=readonly -trimpath -buildvcs=false \
      -ldflags "$ldflags" -o "$TMP/gvproxy-$arch" ./cmd/gvproxy)
  slice_toolchain="$(go version -m "$TMP/gvproxy-$arch" | sed -n '1s/.*: //p')"
  [ "$slice_toolchain" = "$GO_TOOLCHAIN" ] || {
    echo "build-gvproxy: $arch slice used unexpected toolchain ${slice_toolchain:-unknown}" >&2
    exit 1
  }
done
arm64_sha="$(shasum -a 256 "$TMP/gvproxy-arm64" | awk '{print $1}')"
amd64_sha="$(shasum -a 256 "$TMP/gvproxy-amd64" | awk '{print $1}')"
mkdir -p "$(dirname "$OUTPUT")"
"$LIPO" -create "$TMP/gvproxy-arm64" "$TMP/gvproxy-amd64" \
  -segalign x86_64 0x1000 -segalign arm64 0x4000 -output "$OUTPUT"
chmod 0755 "$OUTPUT"

actual_version="$("$OUTPUT" -version 2>&1 | tr -d '\r' | sed -n '1p')"
[ "$actual_version" = "gvproxy version $DORY_VERSION" ] || {
  echo "build-gvproxy: unexpected version: $actual_version" >&2
  exit 1
}
actual_arches="$("$LIPO" -archs "$OUTPUT")"
for arch in arm64 x86_64; do
  case " $actual_arches " in
    *" $arch "*) ;;
    *) echo "build-gvproxy: missing $arch slice ($actual_arches)" >&2; exit 1 ;;
  esac
done

output_sha="$(shasum -a 256 "$OUTPUT" | awk '{print $1}')"
if [ -n "$PROVENANCE" ]; then
  mkdir -p "$(dirname "$PROVENANCE")"
  {
    echo "version=$DORY_VERSION"
    echo "upstream_version=$UPSTREAM_VERSION"
    echo "source_url=https://github.com/containers/gvisor-tap-vsock/archive/refs/tags/${UPSTREAM_VERSION}.tar.gz"
    echo "source_sha256=$SOURCE_SHA256"
    echo "patch_sha256=$PATCH_SHA256"
    echo "go_toolchain=$GO_TOOLCHAIN"
    echo "go_mod_sha256=$GO_MOD_SHA256"
    echo "go_sum_sha256=$GO_SUM_SHA256"
    echo "go_proxy=$GO_PROXY"
    echo "go_sumdb=$GO_SUMDB"
    echo "go_arm64=v8.0"
    echo "go_amd64=v1"
    echo "fat_x86_64_segalign=0x1000"
    echo "fat_arm64_segalign=0x4000"
    echo "arm64_sha256=$arm64_sha"
    echo "amd64_sha256=$amd64_sha"
    echo "verified_sha256=$output_sha"
    echo "features=native-ipv6-v2,host-route-aware-aaaa-v1,source-preserving-lan-qemu-v1"
    echo "architectures=$actual_arches"
  } > "$PROVENANCE"
fi
echo "$output_sha  $OUTPUT"
