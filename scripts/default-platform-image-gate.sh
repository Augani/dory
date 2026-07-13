#!/bin/bash
# Proves an unqualified multi-platform pull selects only the Apple-Silicon platform and that Docker's
# three local image/storage reporting surfaces reconcile to the same bytes.
set -euo pipefail

SOCKET=""
DOCKER=""
IMAGE=""
EXPECTED_PLATFORM="linux/arm64"
WORKROOT="${TMPDIR:-/tmp}/dory-default-platform-image"
REQUIRE_DOCKER_HUB=0

usage() {
  cat <<EOF
Usage: scripts/default-platform-image-gate.sh --socket PATH --docker PATH --image REF [options]

Required:
  --socket PATH          Exact isolated Dory Docker socket
  --docker PATH          Exact Docker CLI to qualify
  --image REF            Digest-pinned multi-platform image absent from the fresh store

Options:
  --expected-platform P  Expected local platform (default: $EXPECTED_PLATFORM)
  --workroot DIR         Evidence root (default: $WORKROOT)
  --require-docker-hub   Require this unqualified pull to exercise Docker Hub
  --help

The pull deliberately omits --platform. The gate is fail-closed if the target image already exists,
because a cached image cannot prove default platform selection.
EOF
}

die() { echo "default platform image gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --image) need_value "$1" "$#"; IMAGE="$2"; shift 2 ;;
    --expected-platform) need_value "$1" "$#"; EXPECTED_PLATFORM="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --require-docker-hub) REQUIRE_DOCKER_HUB=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "$SOCKET" ] || die "--socket is required"
[ -S "$SOCKET" ] || die "Dory socket is unavailable: $SOCKET"
[ -n "$DOCKER" ] || die "--docker is required"
[ -x "$DOCKER" ] || die "Docker CLI is not executable: $DOCKER"
printf '%s\n' "$IMAGE" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
  || die "--image must be digest-pinned"
printf '%s\n' "$EXPECTED_PLATFORM" | grep -Eq '^linux/(arm64|amd64)$' \
  || die "--expected-platform must be linux/arm64 or linux/amd64"
image_name="${IMAGE%@*}"
first_component="${image_name%%/*}"
registry=docker.io
if [ "$image_name" != "$first_component" ]; then
  case "$first_component" in
    *.*|*:*|localhost) registry="$first_component" ;;
  esac
fi
if [ "$REQUIRE_DOCKER_HUB" -eq 1 ] && [ "$registry" != docker.io ]; then
  die "--require-docker-hub received a non-Docker-Hub image: $IMAGE"
fi
for command in curl python3 shasum; do
  command -v "$command" >/dev/null || die "required command is missing: $command"
done

docker_e() { DOCKER_HOST="unix://$SOCKET" "$DOCKER" "$@"; }
docker_e version >/dev/null || die "Docker API is not ready at $SOCKET"
if docker_e image inspect "$IMAGE" >/dev/null 2>&1; then
  die "target image already exists; default pull selection would not be proven: $IMAGE"
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
OWNER="dory-default-platform-$RUN_ID"
NAME="dory-default-platform-${RUN_ID//[^a-zA-Z0-9]/}"
WORKDIR="$WORKROOT/$RUN_ID"
MANIFEST="$WORKDIR/manifest.txt"
mkdir -p "$WORKDIR"

cleanup() {
  docker_e rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# Intentionally no --platform here. This exact command is the behavior under qualification.
docker_e pull "$IMAGE" > "$WORKDIR/default-pull.txt" \
  || die "default image pull failed"
docker_e image inspect "$IMAGE" > "$WORKDIR/image-inspect.json"
curl -fsS --max-time 10 --unix-socket "$SOCKET" 'http://d/images/json?digests=1' \
  > "$WORKDIR/images-json.json"
curl -fsS --max-time 10 --unix-socket "$SOCKET" http://d/system/df \
  > "$WORKDIR/system-df.json"

expected_arch="${EXPECTED_PLATFORM#linux/}"
docker_e run --name "$NAME" --label "dev.dory.default-platform=$OWNER" \
  "$IMAGE" uname -m > "$WORKDIR/default-run-uname.txt"
docker_e inspect "$NAME" > "$WORKDIR/container-inspect.json"
docker_e rm "$NAME" >/dev/null

stats="$(python3 - "$WORKDIR/image-inspect.json" "$WORKDIR/images-json.json" \
  "$WORKDIR/system-df.json" "$WORKDIR/default-run-uname.txt" "$IMAGE" \
  "$expected_arch" <<'PY'
import json
import pathlib
import sys

inspect_path, images_path, df_path, uname_path, reference, expected_arch = sys.argv[1:]
inspect = json.loads(pathlib.Path(inspect_path).read_text(encoding="utf-8"))
assert isinstance(inspect, list) and len(inspect) == 1, "image inspect is not one exact image"
image = inspect[0]
assert image.get("Os") == "linux", f"default pull selected non-Linux OS: {image.get('Os')}"
assert image.get("Architecture") == expected_arch, \
    f"default pull selected {image.get('Architecture')} instead of {expected_arch}"
image_id = image.get("Id")
assert isinstance(image_id, str) and image_id.startswith("sha256:"), "local image ID is invalid"
inspect_size = int(image.get("Size", 0))
assert inspect_size > 0, "image inspect reports zero local bytes"

images = json.loads(pathlib.Path(images_path).read_text(encoding="utf-8"))
assert len(images) == 1, f"fresh qualification store contains {len(images)} image records"
matches = [entry for entry in images if entry.get("Id") == image_id]
assert len(matches) == 1, f"/images/json has {len(matches)} entries for the selected image"
list_size = int(matches[0].get("Size", 0))

system_df = json.loads(pathlib.Path(df_path).read_text(encoding="utf-8"))
df_images = system_df.get("Images") or []
assert len(df_images) == 1, f"fresh /system/df contains {len(df_images)} image records"
df_matches = [entry for entry in df_images if entry.get("Id") == image_id]
assert len(df_matches) == 1, f"/system/df has {len(df_matches)} entries for the selected image"
df_size = int(df_matches[0].get("Size", 0))
assert list_size == df_size, \
    f"image-list and system-df storage bytes disagree: list={list_size} system_df={df_size}"
size_ratio_milli = max(inspect_size, df_size) * 1000 // min(inspect_size, df_size)
assert size_ratio_milli <= 16000, \
    f"inspect/storage size definitions diverge by more than 16x: {size_ratio_milli / 1000:.3f}x"
layers_size = int(system_df.get("LayersSize", 0))
assert layers_size >= df_size, \
    f"system-df layer bytes are below its image bytes: layers={layers_size} image={df_size}"
assert layers_size <= df_size * 2, \
    f"system-df layer bytes are not attributable to the one local image: {layers_size} vs {df_size}"

uname = pathlib.Path(uname_path).read_text(encoding="utf-8").strip()
expected_uname = {"arm64": {"aarch64", "arm64"}, "amd64": {"x86_64", "amd64"}}[expected_arch]
assert uname in expected_uname, f"default run architecture is {uname}, expected {expected_arch}"
repo_digests = image.get("RepoDigests") or []
requested_digest = reference.rsplit("@", 1)[-1]
assert any(value.endswith("@" + requested_digest) for value in repo_digests), \
    "local image does not retain the requested manifest-list digest"

print(f"image_id={image_id}")
print(f"local_architecture={expected_arch}")
print(f"default_run_uname={uname}")
print(f"inspect_size_bytes={inspect_size}")
print(f"image_list_size_bytes={list_size}")
print(f"system_df_size_bytes={df_size}")
print(f"system_df_layers_size_bytes={layers_size}")
print(f"inspect_to_storage_ratio_milli={size_ratio_milli}")
print(f"requested_digest={requested_digest}")
PY
)" || die "default platform/storage evidence failed semantic verification"

{
  echo "status=PASS"
  echo "run_id=$RUN_ID"
  echo "owner=$OWNER"
  echo "socket=$SOCKET"
  echo "docker=$DOCKER"
  echo "docker_cli_sha256=$(shasum -a 256 "$DOCKER" | awk '{print $1}')"
  echo "image=$IMAGE"
  echo "registry=$registry"
  echo "expected_platform=$EXPECTED_PLATFORM"
  echo "default_pull_without_platform=PASS"
  echo "single_platform_local_image=PASS"
  echo "default_run_architecture=PASS"
  echo "image_list_system_df_reconciled=PASS"
  printf '%s\n' "$stats"
  echo "completed_epoch=$(date +%s)"
} > "$MANIFEST"

trap - EXIT INT TERM
echo "default platform image gate: PASS ($MANIFEST)"
