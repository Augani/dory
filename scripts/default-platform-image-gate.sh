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
CONFIRM=""

usage() {
  cat <<EOF
Usage: scripts/default-platform-image-gate.sh --socket PATH --docker PATH --image REF --confirm TOKEN [options]

Required:
  --socket PATH          Exact isolated Dory Docker socket
  --docker PATH          Exact Docker CLI to qualify
  --image REF            Digest-pinned multi-platform image absent from the fresh store
  --confirm TOKEN        Must be ISOLATED-ENGINE-DEFAULT-PLATFORM

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
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ "$CONFIRM" = ISOLATED-ENGINE-DEFAULT-PLATFORM ] \
  || die "requires --confirm ISOLATED-ENGINE-DEFAULT-PLATFORM"
[ -S "$SOCKET" ] || die "Dory socket is unavailable: $SOCKET"
[ "$(stat -f %u "$SOCKET")" = "$(id -u)" ] \
  || die "Dory socket is not owned by the release user"
case "$DOCKER" in /*) ;; *) die "Docker CLI must be an absolute path" ;; esac
[ -f "$DOCKER" ] && [ ! -L "$DOCKER" ] && [ -x "$DOCKER" ] \
  || die "Docker CLI is unavailable or indirect: $DOCKER"
printf '%s\n' "$IMAGE" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[0-9a-f]{64}$' \
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
case "$WORKROOT" in /*) ;; *) die "--workroot must be absolute" ;; esac
case "$WORKROOT" in /|"$HOME"|"$(pwd)") die "unsafe --workroot: $WORKROOT" ;; esac
[ ! -e "$WORKROOT" ] && [ ! -L "$WORKROOT" ] \
  || die "workroot already exists or is indirect: $WORKROOT"

docker_e() { DOCKER_HOST="unix://$SOCKET" "$DOCKER" "$@"; }
docker_e version >/dev/null || die "Docker API is not ready at $SOCKET"
baseline_counts="$(
  printf 'containers=%s\n' "$(docker_e ps -aq | sed '/^$/d' | wc -l | tr -d ' ')"
  printf 'images=%s\n' "$(docker_e image ls -q | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
  printf 'volumes=%s\n' "$(docker_e volume ls -q | sed '/^$/d' | wc -l | tr -d ' ')"
  printf 'custom_networks=%s\n' "$(docker_e network ls --filter type=custom -q | sed '/^$/d' | wc -l | tr -d ' ')"
)"
for empty_object in containers images volumes custom_networks; do
  printf '%s\n' "$baseline_counts" | grep -qx "$empty_object=0" \
    || die "qualification engine is not empty: $empty_object"
done
if docker_e image inspect "$IMAGE" >/dev/null 2>&1; then
  die "target image already exists; default pull selection would not be proven: $IMAGE"
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
OWNER="dory-default-platform-$RUN_ID"
NAME="dory-default-platform-${RUN_ID//[^a-zA-Z0-9]/}"
WORKDIR="$WORKROOT/$RUN_ID"
MANIFEST="$WORKDIR/manifest.txt"
mkdir -p "$WORKDIR"
printf '%s\n' "$baseline_counts" > "$WORKDIR/baseline.txt"
container_id=""

cleanup() {
  if [ -n "$container_id" ]; then
    docker_e rm -f "$container_id" >/dev/null 2>&1 || true
  fi
  docker_e ps -aq --filter "label=dev.dory.default-platform=$OWNER" 2>/dev/null \
    | while IFS= read -r id; do
        [ -z "$id" ] || docker_e rm -f "$id" >/dev/null 2>&1 || true
      done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Intentionally no --platform here. This exact command is the behavior under qualification.
docker_e pull "$IMAGE" > "$WORKDIR/default-pull.txt" \
  || die "default image pull failed"
docker_e image inspect "$IMAGE" > "$WORKDIR/image-inspect.json"
curl -fsS --max-time 10 --unix-socket "$SOCKET" 'http://d/images/json?digests=1' \
  > "$WORKDIR/images-json.json"
curl -fsS --max-time 10 --unix-socket "$SOCKET" http://d/system/df \
  > "$WORKDIR/system-df.json"

expected_arch="${EXPECTED_PLATFORM#linux/}"
container_id="$(docker_e create --pull=never --name "$NAME" \
  --label "dev.dory.default-platform=$OWNER" "$IMAGE" uname -m)"
printf '%s\n' "$container_id" | grep -Eq '^[0-9a-f]{64}$' \
  || die "default-platform container creation returned an invalid ID"
docker_e inspect "$container_id" > "$WORKDIR/container-inspect.json"
docker_e start -a "$container_id" > "$WORKDIR/default-run-uname.txt"
docker_e rm "$container_id" >/dev/null
container_id=""
[ -z "$(docker_e ps -aq --filter "label=dev.dory.default-platform=$OWNER")" ] \
  || die "owned default-platform container survived cleanup"

stats="$(python3 - "$WORKDIR/image-inspect.json" "$WORKDIR/images-json.json" \
  "$WORKDIR/system-df.json" "$WORKDIR/container-inspect.json" \
  "$WORKDIR/default-run-uname.txt" "$IMAGE" "$expected_arch" "$OWNER" <<'PY'
import json
import pathlib
import sys

(
    inspect_path,
    images_path,
    df_path,
    container_path,
    uname_path,
    reference,
    expected_arch,
    owner,
) = sys.argv[1:]
inspect = json.loads(pathlib.Path(inspect_path).read_text(encoding="utf-8"))

def require(condition, message):
    if not condition:
        raise SystemExit(message)

require(isinstance(inspect, list) and len(inspect) == 1, "image inspect is not one exact image")
image = inspect[0]
require(image.get("Os") == "linux", f"default pull selected non-Linux OS: {image.get('Os')}")
require(
    image.get("Architecture") == expected_arch,
    f"default pull selected {image.get('Architecture')} instead of {expected_arch}",
)
image_id = image.get("Id")
require(
    isinstance(image_id, str) and len(image_id) == 71
    and image_id.startswith("sha256:")
    and all(character in "0123456789abcdef" for character in image_id[7:]),
    "local image ID is invalid",
)
inspect_size = int(image.get("Size", 0))
require(inspect_size > 0, "image inspect reports zero local bytes")

container_document = json.loads(pathlib.Path(container_path).read_text(encoding="utf-8"))
require(
    isinstance(container_document, list) and len(container_document) == 1,
    "container inspect is not one exact container",
)
container = container_document[0]
container_config = container.get("Config")
host_config = container.get("HostConfig")
require(isinstance(container_config, dict), "container inspect omits Config")
require(isinstance(host_config, dict), "container inspect omits HostConfig")
require(container_config.get("Image") == reference, "container did not use the exact requested image")
labels = container_config.get("Labels")
require(
    isinstance(labels, dict) and labels.get("dev.dory.default-platform") == owner,
    "container does not carry the exact run authority label",
)
require(host_config.get("Binds") in (None, []), "default-platform container binds host paths")

images = json.loads(pathlib.Path(images_path).read_text(encoding="utf-8"))
require(isinstance(images, list), "/images/json is not a list")
require(len(images) == 1, f"fresh qualification store contains {len(images)} image records")
matches = [entry for entry in images if entry.get("Id") == image_id]
require(len(matches) == 1, f"/images/json has {len(matches)} entries for the selected image")
list_size = int(matches[0].get("Size", 0))

system_df = json.loads(pathlib.Path(df_path).read_text(encoding="utf-8"))
require(isinstance(system_df, dict), "/system/df is not an object")
df_images = system_df.get("Images") or []
require(isinstance(df_images, list), "/system/df Images is not a list")
require(len(df_images) == 1, f"fresh /system/df contains {len(df_images)} image records")
df_matches = [entry for entry in df_images if entry.get("Id") == image_id]
require(len(df_matches) == 1, f"/system/df has {len(df_matches)} entries for the selected image")
df_size = int(df_matches[0].get("Size", 0))
require(
    list_size == df_size,
    f"image-list and system-df storage bytes disagree: list={list_size} system_df={df_size}",
)
size_ratio_milli = max(inspect_size, df_size) * 1000 // min(inspect_size, df_size)
require(
    size_ratio_milli <= 16000,
    f"inspect/storage size definitions diverge by more than 16x: {size_ratio_milli / 1000:.3f}x",
)
layers_size = int(system_df.get("LayersSize", 0))
require(
    layers_size >= df_size,
    f"system-df layer bytes are below its image bytes: layers={layers_size} image={df_size}",
)
require(
    layers_size <= df_size * 2,
    f"system-df layer bytes are not attributable to the one local image: {layers_size} vs {df_size}",
)

uname = pathlib.Path(uname_path).read_text(encoding="utf-8").strip()
expected_uname = {"arm64": {"aarch64", "arm64"}, "amd64": {"x86_64", "amd64"}}[expected_arch]
require(uname in expected_uname, f"default run architecture is {uname}, expected {expected_arch}")
repo_digests = image.get("RepoDigests") or []
requested_digest = reference.rsplit("@", 1)[-1]
requested_name = reference.rsplit("@", 1)[0]
accepted_names = {requested_name}
if "/" not in requested_name:
    accepted_names.add("docker.io/library/" + requested_name)
elif (
    requested_name.split("/", 1)[0] != "localhost"
    and "." not in requested_name.split("/", 1)[0]
    and ":" not in requested_name.split("/", 1)[0]
):
    accepted_names.add("docker.io/" + requested_name)
require(
    isinstance(repo_digests, list)
    and any(value == name + "@" + requested_digest for name in accepted_names for value in repo_digests),
    "local image does not retain the exact requested manifest-list authority",
)

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
  echo "docker_cli_sha256=$(shasum -a 256 "$DOCKER" | awk '{print $1}')"
  echo "image=$IMAGE"
  echo "registry=$registry"
  echo "expected_platform=$EXPECTED_PLATFORM"
  echo "fresh_empty_store=PASS"
  echo "default_pull_without_platform=PASS"
  echo "single_platform_local_image=PASS"
  echo "default_run_architecture=PASS"
  echo "exact_container_image=PASS"
  echo "host_path_free_container=PASS"
  echo "image_list_system_df_reconciled=PASS"
  echo "owned_container_cleanup=PASS"
  printf '%s\n' "$stats"
  echo "completed_epoch=$(date +%s)"
} > "$MANIFEST"

trap - EXIT INT TERM
echo "default platform image gate: PASS ($MANIFEST)"
