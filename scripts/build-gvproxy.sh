#!/bin/bash
# Build Dory's provenance-pinned dual-stack gvproxy from the audited upstream v0.8.9 source.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM_VERSION="v0.8.9"
DORY_VERSION="v0.8.9-dory1"
SOURCE_SHA256="6cbcb7959a5d90b59253ea6d8bdf0285e2cfbc3b301398704b41e3069293f4fb"
PATCH="$ROOT/patches/gvproxy-native-ipv6.patch"
PATCH_SHA256="ca76b2a8a304aa4b3aba835543f325832de83a14163f6b86b37491cc165e2ce3"
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

export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"
if [ "$RUN_TESTS" = 1 ]; then
  (cd "$SOURCE" && go test -mod=mod ./pkg/services/dns ./pkg/tap ./pkg/virtualnetwork ./pkg/services/forwarder ./cmd/gvproxy)
fi

ldflags="-s -w -buildid= -X github.com/containers/gvisor-tap-vsock/pkg/types.gitVersion=$DORY_VERSION"
for arch in arm64 amd64; do
  (cd "$SOURCE" && \
    CGO_ENABLED=0 GOOS=darwin GOARCH="$arch" go build -mod=mod -trimpath -buildvcs=false \
      -ldflags "$ldflags" -o "$TMP/gvproxy-$arch" ./cmd/gvproxy)
done
mkdir -p "$(dirname "$OUTPUT")"
"$LIPO" -create "$TMP/gvproxy-arm64" "$TMP/gvproxy-amd64" -output "$OUTPUT"
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
    echo "verified_sha256=$output_sha"
    echo "features=native-ipv6-v1,source-preserving-lan-qemu-v1"
    echo "architectures=$actual_arches"
  } > "$PROVENANCE"
fi
echo "$output_sha  $OUTPUT"
