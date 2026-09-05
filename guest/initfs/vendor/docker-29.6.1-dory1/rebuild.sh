#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
INITFS_DIR="$ROOT/guest/initfs"
PINS="$INITFS_DIR/PINS"
CACHE_DIR="${DORY_INITFS_CACHE:-$ROOT/guest/.cache/initfs}"
OUT_DIR="${DORY_DOCKER_VENDOR_OUT:-$ROOT/guest/out/docker-29.6.1-dory1}"
WORK_BASE="${DORY_DOCKER_VENDOR_WORK:-${TMPDIR:-/tmp}}"

MOBY_URL="https://github.com/moby/moby.git"
MOBY_TAG="docker-v29.6.1"
MOBY_TAG_OBJECT="5259f1f37f10f37594a18eab40604e3e91622fe9"
MOBY_COMMIT="8ec5ab355a34b2a0e2b3238d67bdefe77fefa982"
PATCH_SHA256="0cd760859b4b95ad5f424fa5ea60bb2d48511a5154124adacdf715291ea7d85e"
SOURCE_DATE_EPOCH="1782422754"
VERSION="29.6.1-dory1"
DOCKER_GITCOMMIT="${MOBY_COMMIT}-dory-start-intent"
PLATFORM_NAME="Dory Container Engine"
PRODUCT_NAME="Dory Container Engine"
DEFAULT_PRODUCT_LICENSE="Apache-2.0"
DEBIAN_SNAPSHOT="20260713T000000Z"
GO_VERSION="1.25.9"
BUILDER_IMAGE="golang:${GO_VERSION}-bookworm@sha256:298734aec230b5f3e8cee450ce6d7eccc39f1797ba548ee90d57e9803030c6c3"
XX_IMAGE="tonistiigi/xx:1.9.0@sha256:c64defb9ed5a91eacb37f96ccc3d4cd72521c4bd18d5442905b95e2226b0e707"
VERIFY_IMAGE="debian:12-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171"

usage() {
  echo "usage: $0 [arm64|amd64]" >&2
  echo "       $0 input-sha256 [arm64|amd64]" >&2
  exit 64
}

MODE=build
if [ "${1:-}" = "input-sha256" ]; then
  MODE=input-sha256
  shift
fi

case "${1:-}" in
  arm64|aarch64) ARCH=arm64; PIN_KEY=docker_arm64; PLATFORM=linux/arm64 ;;
  amd64|x86_64) ARCH=amd64; PIN_KEY=docker_amd64; PLATFORM=linux/amd64 ;;
  *) usage ;;
esac

PUBLISH_TEMPS=()
WORK_ROOT=
if [ "$MODE" = build ]; then
  mkdir -p "$CACHE_DIR" "$OUT_DIR" "$WORK_BASE"
  WORK_ROOT="$(mktemp -d "$WORK_BASE/dory-dockerd-producer-${ARCH}.XXXXXX")"
  cleanup() {
    if [ "${#PUBLISH_TEMPS[@]}" -gt 0 ]; then
      rm -f "${PUBLISH_TEMPS[@]}"
    fi
    if [ "${DORY_DOCKER_KEEP_WORK:-0}" != 1 ]; then
      rm -rf "$WORK_ROOT"
    fi
  }
  trap cleanup EXIT
  printf 'work_root=%s\n' "$WORK_ROOT"
fi

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

capture_producer_inputs() {
  {
    printf 'schema=1\n'
    printf 'arch=%s\nplatform=%s\n' "$ARCH" "$PLATFORM"
    printf 'moby_url=%s\nmoby_tag=%s\nmoby_tag_object=%s\nmoby_commit=%s\n' "$MOBY_URL" "$MOBY_TAG" "$MOBY_TAG_OBJECT" "$MOBY_COMMIT"
    printf 'patch_sha256=%s\nsource_date_epoch=%s\nversion=%s\ndocker_gitcommit=%s\n' "$PATCH_SHA256" "$SOURCE_DATE_EPOCH" "$VERSION" "$DOCKER_GITCOMMIT"
    printf 'platform_name=%s\nproduct_name=%s\ndefault_product_license=%s\n' "$PLATFORM_NAME" "$PRODUCT_NAME" "$DEFAULT_PRODUCT_LICENSE"
    printf 'debian_snapshot=%s\nbuilder_image=%s\nxx_image=%s\nverify_image=%s\n' "$DEBIAN_SNAPSHOT" "$BUILDER_IMAGE" "$XX_IMAGE" "$VERIFY_IMAGE"
    for input in "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR/rebuild.sh" "$SCRIPT_DIR/patches/docker-start-intent.patch" "$PINS"; do
      case "$input" in
        "$ROOT"/*) label="${input#$ROOT/}" ;;
        *) label="$input" ;;
      esac
      printf 'input=%s\n' "$label"
      sha256_file "$input"
    done
  } | shasum -a 256 | awk '{print $1}'
}

verify_producer_inputs_unchanged() {
  local current
  current="$(capture_producer_inputs)"
  [ "$current" = "$PRODUCER_INPUT_SHA256" ] || {
    echo "producer inputs changed during build: before $PRODUCER_INPUT_SHA256 after $current" >&2
    exit 1
  }
}

pin_field() {
  local key="$1" field="$2"
  awk -v key="$key" -v field="$field" '
    $1 == key {
      if (field == "url") print $2
      else if (field == "sha256") print $3
      exit
    }
  ' "$PINS"
}

fetch_pin() {
  local key="$1" url expected name path actual
  url="$(pin_field "$key" url)"
  expected="$(pin_field "$key" sha256)"
  [ -n "$url" ] && [ -n "$expected" ] || { echo "missing pin for $key" >&2; exit 1; }
  name="$(basename "$url")"
  path="$CACHE_DIR/$key-$name"
  if [ ! -f "$path" ] || [ "$(sha256_file "$path")" != "$expected" ]; then
    rm -f "$path"
    curl -fL --retry 3 "$url" -o "$path"
  fi
  actual="$(sha256_file "$path")"
  [ "$actual" = "$expected" ] || { echo "sha256 mismatch for $name: expected $expected got $actual" >&2; exit 1; }
  printf '%s\n' "$path"
}

verify_patch_hash() {
  local actual
  actual="$(sha256_file "$SCRIPT_DIR/patches/docker-start-intent.patch")"
  [ "$actual" = "$PATCH_SHA256" ] || {
    echo "patch hash mismatch: expected $PATCH_SHA256 got $actual" >&2
    exit 1
  }
}

prepare_source() {
  local src="$1"
  git clone --quiet --filter=blob:none --branch "$MOBY_TAG" "$MOBY_URL" "$src"
  [ "$(git -C "$src" rev-parse HEAD)" = "$MOBY_COMMIT" ] || {
    echo "unexpected Moby commit in $src" >&2
    exit 1
  }
  [ "$(git -C "$src" rev-parse "$MOBY_TAG^{tag}")" = "$MOBY_TAG_OBJECT" ] || {
    echo "unexpected Moby tag object for $MOBY_TAG" >&2
    exit 1
  }
  git -C "$src" apply --index "$SCRIPT_DIR/patches/docker-start-intent.patch"
}

build_dockerd() {
  local src="$1" dest="$2" build_dest="$WORK_ROOT/build-output"
  rm -rf "$build_dest"
  mkdir -p "$build_dest"
  docker buildx build \
    --progress=plain \
    --platform "$PLATFORM" \
    --build-arg "BUILDER_IMAGE=$BUILDER_IMAGE" \
    --build-arg "XX_IMAGE=$XX_IMAGE" \
    --build-arg "VERSION=$VERSION" \
    --build-arg "DOCKER_GITCOMMIT=$DOCKER_GITCOMMIT" \
    --build-arg "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" \
    --build-arg "PLATFORM_NAME=$PLATFORM_NAME" \
    --build-arg "PRODUCT_NAME=$PRODUCT_NAME" \
    --build-arg "DEFAULT_PRODUCT_LICENSE=$DEFAULT_PRODUCT_LICENSE" \
    --build-arg "DEBIAN_SNAPSHOT=$DEBIAN_SNAPSHOT" \
    --output "type=local,dest=$build_dest" \
    -f "$SCRIPT_DIR/Dockerfile" \
    "$src"
  install -m0755 "$build_dest/dockerd" "$dest"
}

make_candidate_tarball() {
  local upstream_tar="$1" dockerd="$2" output="$3" unpack="$WORK_ROOT/upstream-static" before="$WORK_ROOT/upstream-preserved.sha256" after="$WORK_ROOT/candidate-preserved.sha256"
  rm -rf "$unpack"
  mkdir -p "$unpack"
  tar -xzf "$upstream_tar" -C "$unpack"
  [ -d "$unpack/docker" ] || { echo "upstream Docker tarball did not contain docker/" >&2; exit 1; }
  ( cd "$unpack/docker" && find . -type f ! -name dockerd -print | LC_ALL=C sort | xargs shasum -a 256 ) > "$before"
  install -m0755 "$dockerd" "$unpack/docker/dockerd"
  ( cd "$unpack/docker" && find . -type f ! -name dockerd -print | LC_ALL=C sort | xargs shasum -a 256 ) > "$after"
  cmp -s "$before" "$after" || { echo "non-dockerd file changed while composing candidate tarball" >&2; exit 1; }
  python3 - "$unpack" "$output" "$SOURCE_DATE_EPOCH" <<'PY'
import gzip
import pathlib
import sys
import tarfile

root = pathlib.Path(sys.argv[1]).resolve()
output = pathlib.Path(sys.argv[2]).resolve()
epoch = int(sys.argv[3])
paths = sorted(root.rglob('*'), key=lambda path: path.relative_to(root).as_posix())
output.parent.mkdir(parents=True, exist_ok=True)
with output.open('wb') as raw_out:
    with gzip.GzipFile(filename='', mode='wb', fileobj=raw_out, mtime=epoch) as gz:
        with tarfile.open(fileobj=gz, mode='w', format=tarfile.USTAR_FORMAT) as tar:
            for path in paths:
                rel = path.relative_to(root).as_posix()
                if rel.startswith('._') or '/._' in rel or rel == '.DS_Store' or rel.endswith('/.DS_Store'):
                    raise SystemExit(f'refusing AppleDouble/macOS metadata in archive: {rel}')
                info = tar.gettarinfo(str(path), arcname=rel)
                info.uid = 0
                info.gid = 0
                info.uname = 'root'
                info.gname = 'root'
                info.mtime = epoch
                if info.isfile():
                    with path.open('rb') as handle:
                        tar.addfile(info, handle)
                else:
                    tar.addfile(info)
PY
}

write_receipt() {
  local upstream_tar="$1" dockerd="$2" output="$3" receipt="$4"
  local runtime_status="${RUNTIME_VERIFICATION_STATUS:-unknown}" runtime_reason="${RUNTIME_VERIFICATION_REASON:-not recorded}"
  python3 - "$receipt" "$ARCH" "$PLATFORM" "$MOBY_URL" "$MOBY_TAG" "$MOBY_TAG_OBJECT" "$MOBY_COMMIT" "$PATCH_SHA256" "$VERSION" "$DOCKER_GITCOMMIT" "$SOURCE_DATE_EPOCH" "$BUILDER_IMAGE" "$XX_IMAGE" "$VERIFY_IMAGE" "$DEBIAN_SNAPSHOT" "$runtime_status" "$runtime_reason" "$PRODUCER_INPUT_SHA256" "$DOCKERFILE_SHA256" "$REBUILD_SCRIPT_SHA256" "$upstream_tar" "$(sha256_file "$upstream_tar")" "$dockerd" "$(sha256_file "$dockerd")" "$output" "$(sha256_file "$output")" <<'PY'
import json
import pathlib
import sys

(
    receipt, arch, platform, moby_url, moby_tag, moby_tag_object, moby_commit,
    patch_sha256, version, docker_gitcommit, source_date_epoch, builder_image,
    xx_image, verify_image, debian_snapshot, runtime_status, runtime_reason,
    producer_input_sha256, dockerfile_sha256, rebuild_script_sha256, upstream_tar,
    upstream_sha256, dockerd,
    dockerd_sha256, output, output_sha256,
) = sys.argv[1:]
record = {
    'schema': 1,
    'arch': arch,
    'platform': platform,
    'moby': {
        'url': moby_url,
        'tag': moby_tag,
        'tagObject': moby_tag_object,
        'commit': moby_commit,
        'patchSha256': patch_sha256,
    },
    'version': version,
    'dockerGitCommit': docker_gitcommit,
    'sourceDateEpoch': int(source_date_epoch),
    'builder': {
        'golangImage': builder_image,
        'xxImage': xx_image,
        'verifyImage': verify_image,
        'debianSnapshot': debian_snapshot,
    },
    'producer': {
        'inputSha256': producer_input_sha256,
        'dockerfileSha256': dockerfile_sha256,
        'rebuildScriptSha256': rebuild_script_sha256,
    },
    'runtimeVerification': {
        'status': runtime_status,
        'platform': platform,
        'reason': runtime_reason,
    },
    'upstreamStaticTarball': {
        'path': upstream_tar,
        'sha256': upstream_sha256,
    },
    'patchedDockerdBuildOutput': {
        'workPath': dockerd,
        'sha256': dockerd_sha256,
    },
    'candidateStaticTarball': {
        'path': output,
        'sha256': output_sha256,
    },
}
pathlib.Path(receipt).write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
PY
}

verify_candidate() {
  local tarball="$1" verify_dir="$WORK_ROOT/verify" dockerd_version state_json exit_code state_error
  rm -rf "$verify_dir"
  mkdir -p "$verify_dir"
  tar -xzf "$tarball" -C "$verify_dir"
  for name in runc ctr containerd docker-proxy docker-init docker dockerd containerd-shim-runc-v2; do
    [ -x "$verify_dir/docker/$name" ] || { echo "candidate missing executable docker/$name" >&2; exit 1; }
  done
  file "$verify_dir/docker/dockerd"
  case "${DORY_DOCKER_SKIP_RUNTIME_VERIFY:-0}" in
    1)
      RUNTIME_VERIFICATION_STATUS=skipped
      RUNTIME_VERIFICATION_REASON="DORY_DOCKER_SKIP_RUNTIME_VERIFY=1"
      echo "runtime verification skipped by DORY_DOCKER_SKIP_RUNTIME_VERIFY=1"
      ;;
    *)
      local cid rc
      cid="$(docker create --platform "$PLATFORM" "$VERIFY_IMAGE" sh -eu -c 'chmod +x /tmp/dockerd; /tmp/dockerd --version')"
      rc=0
      docker cp "$verify_dir/docker/dockerd" "$cid:/tmp/dockerd" || rc=$?
      if [ "$rc" -eq 0 ]; then
        dockerd_version="$(docker start -a "$cid")" || rc=$?
      fi
      state_json="$(docker inspect "$cid" --format '{{json .State}}' 2>/dev/null || true)"
      exit_code="$(docker inspect "$cid" --format '{{.State.ExitCode}}' 2>/dev/null || true)"
      state_error="$(docker inspect "$cid" --format '{{.State.Error}}' 2>/dev/null || true)"
      docker rm -f "$cid" >/dev/null 2>&1 || true
      if [ "$rc" -ne 0 ] || [ "$exit_code" != 0 ] || [ -n "$state_error" ]; then
        echo "runtime verification failed for $PLATFORM: docker_rc=$rc state=$state_json" >&2
        exit 1
      fi
      echo "$dockerd_version"
      RUNTIME_VERIFICATION_STATUS=passed
      RUNTIME_VERIFICATION_REASON="dockerd --version executed in $VERIFY_IMAGE on $PLATFORM"
      case "$dockerd_version" in
        *"$VERSION"*"$DOCKER_GITCOMMIT"*) ;;
        *) echo "dockerd --version did not report expected Dory version metadata" >&2; exit 1 ;;
      esac
      ;;
  esac
}

verify_patch_hash
if [ "$MODE" = input-sha256 ]; then
  capture_producer_inputs
  exit 0
fi
SRC="$WORK_ROOT/moby"
PATCHED_DOCKERD="$WORK_ROOT/dockerd"
OUTPUT_TARBALL="$OUT_DIR/docker-${VERSION}-${ARCH}.tgz"
RECEIPT="$OUT_DIR/docker-${VERSION}-${ARCH}.receipt.json"
TMP_TARBALL="$WORK_ROOT/docker-${VERSION}-${ARCH}.tgz"
TMP_RECEIPT="$WORK_ROOT/docker-${VERSION}-${ARCH}.receipt.json"
DOCKERFILE_SHA256="$(sha256_file "$SCRIPT_DIR/Dockerfile")"
REBUILD_SCRIPT_SHA256="$(sha256_file "$SCRIPT_DIR/rebuild.sh")"
PRODUCER_INPUT_SHA256="$(capture_producer_inputs)"
UPSTREAM_TAR="$(fetch_pin "$PIN_KEY")"
prepare_source "$SRC"
build_dockerd "$SRC" "$PATCHED_DOCKERD"
make_candidate_tarball "$UPSTREAM_TAR" "$PATCHED_DOCKERD" "$TMP_TARBALL"
verify_candidate "$TMP_TARBALL"
verify_producer_inputs_unchanged
OUTPUT_TMP="$(mktemp "$OUT_DIR/.docker-${VERSION}-${ARCH}.XXXXXX.tgz")"
RECEIPT_TMP_PUBLISH="$(mktemp "$OUT_DIR/.docker-${VERSION}-${ARCH}.XXXXXX.receipt.json")"
SHA_TMP="$(mktemp "$OUT_DIR/.docker-${VERSION}-${ARCH}.XXXXXX.sha256")"
PUBLISH_TEMPS+=("$OUTPUT_TMP" "$RECEIPT_TMP_PUBLISH" "$SHA_TMP")
install -m0644 "$TMP_TARBALL" "$OUTPUT_TMP"
mv "$OUTPUT_TMP" "$OUTPUT_TARBALL"
write_receipt "$UPSTREAM_TAR" "$PATCHED_DOCKERD" "$OUTPUT_TARBALL" "$TMP_RECEIPT"
install -m0644 "$TMP_RECEIPT" "$RECEIPT_TMP_PUBLISH"
mv "$RECEIPT_TMP_PUBLISH" "$RECEIPT"
sha256_file "$OUTPUT_TARBALL" | tee "$SHA_TMP"
chmod 0644 "$SHA_TMP"
mv "$SHA_TMP" "$OUTPUT_TARBALL.sha256"
printf 'wrote %s\n' "$OUTPUT_TARBALL"
printf 'wrote %s\n' "$RECEIPT"
