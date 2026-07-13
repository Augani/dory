#!/bin/bash
# Focused non-native architecture build smoke for reports like:
#   docker build --platform linux/amd64 ... -> qemu signal 11 / build failure
#
# Requires a running Dory socket and non-native image support enabled in Dory when the target is
# not the host guest architecture.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DORY_SOCK="${DORY_SOCK:-$HOME/.dory/dory.sock}"
ALPINE_IMAGE="${READINESS_ALPINE_IMAGE:-alpine:latest}"
BUILD_IMAGE="${READINESS_NONNATIVE_BUILD_IMAGE:-node:20-alpine}"
TARGET_ARCH="${DORY_NONNATIVE_TARGET_ARCH:-}"
KEEP="${DORY_NONNATIVE_SMOKE_KEEP:-0}"
WORKDIR="${DORY_NONNATIVE_SMOKE_WORKDIR:-}"
DOCKER_BIN="${DORY_DOCKER_BIN:-}"

usage() {
  cat <<EOF
Usage: scripts/nonnative-build-smoke.sh [options]

Options:
  --target amd64|arm64  Target guest architecture (default: opposite of this Mac)
  --image IMAGE         Build base image (default: $BUILD_IMAGE)
  --socket PATH         Dory Docker socket (default: $DORY_SOCK)
  --docker PATH         Docker CLI path (default: ~/.dory/bin/docker, then PATH)
  --keep                Keep the generated build context and image tag
  -h, --help            Show this help

Environment:
  DORY_SOCK, DORY_DOCKER_BIN, DORY_NONNATIVE_TARGET_ARCH
  READINESS_ALPINE_IMAGE, READINESS_NONNATIVE_BUILD_IMAGE
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target) TARGET_ARCH="${2:?--target requires amd64 or arm64}"; shift 2 ;;
    --image) BUILD_IMAGE="${2:?--image requires an image reference}"; shift 2 ;;
    --socket) DORY_SOCK="${2:?--socket requires a path}"; shift 2 ;;
    --docker) DOCKER_BIN="${2:?--docker requires a path}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

host_guest_arch() {
  [ "$(uname -m)" = "x86_64" ] && printf '%s\n' "amd64" || printf '%s\n' "arm64"
}

default_target_arch() {
  [ "$(host_guest_arch)" = "amd64" ] && printf '%s\n' "arm64" || printf '%s\n' "amd64"
}

find_docker_bin() {
  local cand
  for cand in "$DOCKER_BIN" "$HOME/.dory/bin/docker" "$(command -v docker 2>/dev/null || true)"; do
    [ -n "$cand" ] && [ -x "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  done
  echo "nonnative-build-smoke: docker CLI not found. Start doryd, then open a new terminal so ~/.dory/bin is on PATH." >&2
  return 1
}

handler_for_arch() {
  case "$1" in
    amd64) printf '%s\n' "FEX-x86_64" ;;
    arm64) printf '%s\n' "qemu-aarch64" ;;
    *) echo "unsupported target architecture: $1" >&2; return 2 ;;
  esac
}

uname_pattern_for_arch() {
  case "$1" in
    amd64) printf '%s\n' 'x86_64|amd64' ;;
    arm64) printf '%s\n' 'aarch64|arm64' ;;
    *) echo "unsupported target architecture: $1" >&2; return 2 ;;
  esac
}

node_arch_for_arch() {
  case "$1" in
    amd64) printf '%s\n' "x64" ;;
    arm64) printf '%s\n' "arm64" ;;
    *) echo "unsupported target architecture: $1" >&2; return 2 ;;
  esac
}

write_node_build_fixture() {
  local dir="$1"
  mkdir -p "$dir/src" "$dir/scripts" "$dir/test" "$dir/vendor/dory-math"
  cat > "$dir/package.json" <<'EOF'
{
  "name": "dory-nonnative-build-smoke",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "dependencies": {
    "@dory/math-fixture": "file:vendor/dory-math"
  },
  "scripts": {
    "build": "node scripts/build.mjs",
    "test": "node --test test/*.test.mjs"
  }
}
EOF
  cat > "$dir/package-lock.json" <<'EOF'
{
  "name": "dory-nonnative-build-smoke",
  "version": "1.0.0",
  "lockfileVersion": 3,
  "requires": true,
  "packages": {
    "": {
      "name": "dory-nonnative-build-smoke",
      "version": "1.0.0",
      "dependencies": {
        "@dory/math-fixture": "file:vendor/dory-math"
      }
    },
    "node_modules/@dory/math-fixture": {
      "resolved": "vendor/dory-math",
      "link": true
    },
    "vendor/dory-math": {
      "name": "@dory/math-fixture",
      "version": "1.0.0"
    }
  }
}
EOF
  cat > "$dir/vendor/dory-math/package.json" <<'EOF'
{
  "name": "@dory/math-fixture",
  "version": "1.0.0",
  "type": "module",
  "exports": "./index.mjs"
}
EOF
  cat > "$dir/vendor/dory-math/index.mjs" <<'EOF'
export function weightedChecksum(values) {
  return values.reduce((total, value, index) => (total + value * (index + 1)) % 2147483647, 0);
}
EOF
  cat > "$dir/src/app.mjs" <<'EOF'
import { weightedChecksum } from '@dory/math-fixture';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';

export function fingerprint(value) {
  return createHash('sha256').update(value).digest('hex');
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const checksum = weightedChecksum(Array.from({ length: 4096 }, (_, index) => index % 251));
  console.log(`dory-nonnative-build-ok arch=${process.arch} checksum=${checksum} sha=${fingerprint('dory-readiness')}`);
}
EOF
  cat > "$dir/scripts/build.mjs" <<'EOF'
import { mkdir, readFile, writeFile } from 'node:fs/promises';

const source = await readFile(new URL('../src/app.mjs', import.meta.url), 'utf8');
await mkdir(new URL('../dist/', import.meta.url), { recursive: true });
await writeFile(new URL('../dist/app.mjs', import.meta.url), `// generated by npm run build\n${source}`);
EOF
  cat > "$dir/test/app.test.mjs" <<'EOF'
import assert from 'node:assert/strict';
import test from 'node:test';
import { weightedChecksum } from '@dory/math-fixture';
import { fingerprint } from '../dist/app.mjs';

test('built artifact executes on the requested architecture', () => {
  assert.equal(process.arch, process.env.EXPECTED_NODE_ARCH);
  assert.match(fingerprint('dory-readiness'), /^[0-9a-f]{64}$/);
  assert.notEqual(fingerprint('dory-readiness'), fingerprint('wrong-input'));
  assert.equal(weightedChecksum([3, 5, 7]), 34);
});
EOF
}

if [ "${DORY_NONNATIVE_SMOKE_SOURCE_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

TARGET_ARCH="${TARGET_ARCH:-$(default_target_arch)}"
HANDLER="$(handler_for_arch "$TARGET_ARCH")"
UNAME_PATTERN="$(uname_pattern_for_arch "$TARGET_ARCH")"
NODE_ARCH="$(node_arch_for_arch "$TARGET_ARCH")"
DOCKER_BIN="$(find_docker_bin)"

[ -S "$DORY_SOCK" ] || {
  echo "nonnative-build-smoke: missing Dory socket at $DORY_SOCK" >&2
  exit 1
}

if [ -z "$WORKDIR" ]; then
  WORKDIR="$(mktemp -d)"
else
  mkdir -p "$WORKDIR"
fi
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
TAG="dory-nonnative-smoke:${RUN_ID}-linux-${TARGET_ARCH}"
write_node_build_fixture "$WORKDIR"

cleanup() {
  if [ "$KEEP" != "1" ]; then
    "$DOCKER_BIN" -H "unix://$DORY_SOCK" rmi -f "$TAG" >/dev/null 2>&1 || true
    rm -rf "$WORKDIR"
  else
    echo "nonnative-build-smoke: kept context at $WORKDIR"
    echo "nonnative-build-smoke: kept image tag $TAG"
  fi
}
trap cleanup EXIT

docker_e() {
  "$DOCKER_BIN" -H "unix://$DORY_SOCK" "$@"
}

echo "nonnative-build-smoke: target linux/$TARGET_ARCH using $BUILD_IMAGE"

if [ "$(host_guest_arch)" != "$TARGET_ARCH" ]; then
  if ! binfmt_output="$(docker_e run --rm --privileged --label "dev.dory.nonnative-smoke=$RUN_ID" "$ALPINE_IMAGE" sh -c '
handler="$1"
mkdir -p /proc/sys/fs/binfmt_misc
grep -qs " /proc/sys/fs/binfmt_misc " /proc/mounts \
  || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
test -e /proc/sys/fs/binfmt_misc/register || { echo "binfmt_misc not mounted" >&2; exit 1; }
test -e "/proc/sys/fs/binfmt_misc/$handler" || { echo "$handler handler not registered" >&2; exit 1; }
grep -qx enabled "/proc/sys/fs/binfmt_misc/$handler" || { echo "$handler handler not enabled" >&2; exit 1; }
' sh "$HANDLER" 2>&1)"; then
    printf '%s\n' "$binfmt_output" >&2
    echo "nonnative-build-smoke: non-native support is not ready. Enable non-native image support in Dory, restart doryd, then retry." >&2
    exit 1
  fi
fi

cat > "$WORKDIR/Dockerfile" <<EOF
FROM $BUILD_IMAGE
LABEL dev.dory.nonnative-smoke=$RUN_ID
ARG EXPECTED_UNAME
ARG EXPECTED_NODE_ARCH
ENV EXPECTED_NODE_ARCH=\$EXPECTED_NODE_ARCH
WORKDIR /workspace
RUN actual="\$(uname -m)" \\
    && printf '%s\n' "\$actual" > /uname.txt \\
    && printf '%s\n' "\$actual" | grep -Eq "\$EXPECTED_UNAME"
RUN node -e "if (process.arch !== process.env.EXPECTED_NODE_ARCH) { throw new Error(process.arch + ' != ' + process.env.EXPECTED_NODE_ARCH) } console.log(process.arch)" > /node-arch.txt
RUN apk add --no-cache tar \
    && tar --version | grep -q 'GNU tar' \
    && mkdir -p /tmp/tar-source/a/b/c /tmp/tar-output \
    && printf nested-gnu-tar-ok > /tmp/tar-source/a/b/c/payload.txt \
    && ln /tmp/tar-source/a/b/c/payload.txt /tmp/tar-source/a/b/c/hardlink.txt \
    && tar -cf /tmp/nested.tar -C /tmp/tar-source . \
    && tar -xf /tmp/nested.tar -C /tmp/tar-output \
    && grep -qx nested-gnu-tar-ok /tmp/tar-output/a/b/c/payload.txt \
    && test "\$(stat -c %i /tmp/tar-output/a/b/c/payload.txt)" = "\$(stat -c %i /tmp/tar-output/a/b/c/hardlink.txt)"
COPY package.json package-lock.json ./
COPY vendor ./vendor
RUN npm ci --ignore-scripts --no-audit --no-fund
COPY src ./src
COPY scripts ./scripts
COPY test ./test
RUN npm run build \\
    && npm test \\
    && node dist/app.mjs | tee /build-result.txt \\
    && grep -q "dory-nonnative-build-ok arch=\$EXPECTED_NODE_ARCH" /build-result.txt
CMD ["node", "dist/app.mjs"]
EOF

DOCKER_BUILDKIT=1 docker_e build --progress=plain --platform "linux/$TARGET_ARCH" \
  --build-arg "EXPECTED_UNAME=$UNAME_PATTERN" \
  --build-arg "EXPECTED_NODE_ARCH=$NODE_ARCH" \
  -t "$TAG" "$WORKDIR"

docker_e run --rm --platform "linux/$TARGET_ARCH" \
  --label "dev.dory.nonnative-smoke=$RUN_ID" \
  "$TAG" | tee "$WORKDIR/result.txt"

grep -q "dory-nonnative-build-ok arch=$NODE_ARCH" "$WORKDIR/result.txt"
echo "nonnative-build-smoke: PASS linux/$TARGET_ARCH BuildKit npm ci + GNU tar nested/hardlink + build + test + runtime"
