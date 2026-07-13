#!/bin/bash
# Destructive only to uniquely named, operation-owned Docker objects created by this process.
# Qualifies the exact Linux/arm64 helper through Docker's public archive boundary.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCKER=""
CONTEXT=""
IMAGE_ARCHIVE=""
EXPECTED_IMAGE_ARCHIVE_SHA256=""
EXPECTED_HELPER_SHA256=""
FIXTURE_IMAGE=""

usage() {
  cat >&2 <<'EOF'
usage: scripts/volume-transfer-gate.sh --docker PATH --context NAME \
  --image-archive PATH --expected-image-archive-sha256 HEX \
  --expected-helper-sha256 HEX --fixture-image IMMUTABLE_IMAGE

IMMUTABLE_IMAGE must be an image ID (sha256:...) or a digest-pinned reference and must provide
Python 3. The gate creates and removes only dory-transfer-qual-<random> objects.
EOF
  exit 2
}

need_value() {
  [ "$2" -ge 2 ] || usage
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --context) need_value "$1" "$#"; CONTEXT="$2"; shift 2 ;;
    --image-archive) need_value "$1" "$#"; IMAGE_ARCHIVE="$2"; shift 2 ;;
    --expected-image-archive-sha256)
      need_value "$1" "$#"; EXPECTED_IMAGE_ARCHIVE_SHA256="$2"; shift 2
      ;;
    --expected-helper-sha256) need_value "$1" "$#"; EXPECTED_HELPER_SHA256="$2"; shift 2 ;;
    --fixture-image) need_value "$1" "$#"; FIXTURE_IMAGE="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

[ -x "$DOCKER" ] || { echo "volume transfer gate: Docker CLI is not executable: $DOCKER" >&2; exit 2; }
[ -n "$CONTEXT" ] || usage
[ -f "$IMAGE_ARCHIVE" ] \
  || { echo "volume transfer gate: image archive is unavailable: $IMAGE_ARCHIVE" >&2; exit 2; }
printf '%s' "$EXPECTED_IMAGE_ARCHIVE_SHA256" | grep -Eq '^[0-9a-f]{64}$' || usage
printf '%s' "$EXPECTED_HELPER_SHA256" | grep -Eq '^[0-9a-f]{64}$' || usage
case "$FIXTURE_IMAGE" in
  sha256:*|*@sha256:*) ;;
  *) echo "volume transfer gate: fixture image must be immutable" >&2; exit 2 ;;
esac
command -v python3 >/dev/null 2>&1 || { echo "volume transfer gate: python3 is required" >&2; exit 2; }

actual_image_archive_sha256="$(shasum -a 256 "$IMAGE_ARCHIVE" | awk '{print $1}')"
[ "$actual_image_archive_sha256" = "$EXPECTED_IMAGE_ARCHIVE_SHA256" ] || {
  echo "volume transfer gate: image archive digest mismatch" >&2
  exit 1
}
image_metadata="$(python3 "$ROOT/scripts/build-transfer-helper-image.py" \
  --verify "$IMAGE_ARCHIVE" --expected-helper-sha256 "$EXPECTED_HELPER_SHA256")"
actual_helper_sha256="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["helperSha256"])' \
  "$image_metadata")"
expected_layer_diff_id="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["layerDiffId"])' \
  "$image_metadata")"
image_config_digest="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["imageConfigDigest"])' \
  "$image_metadata")"

docker() {
  "$DOCKER" --context "$CONTEXT" "$@"
}

engine_arch="$(docker version --format '{{.Server.Arch}}')"
[ "$engine_arch" = arm64 ] || {
  echo "volume transfer gate: Apple Silicon launch gate requires an arm64 engine" >&2
  exit 1
}
fixture_id="$(docker image inspect "$FIXTURE_IMAGE" --format '{{.Id}}')"
case "$FIXTURE_IMAGE" in
  sha256:*) [ "$fixture_id" = "$FIXTURE_IMAGE" ] || { echo "volume transfer gate: fixture ID mismatch" >&2; exit 1; } ;;
  *@sha256:*)
    docker image inspect "$FIXTURE_IMAGE" --format '{{json .RepoDigests}}' \
      | grep -Fq "${FIXTURE_IMAGE#*@}" \
      || { echo "volume transfer gate: fixture digest is not installed" >&2; exit 1; }
    ;;
esac

token="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(8))
PY
)"
prefix="dory-transfer-qual-$token"
helper_image="$prefix-helper"
source_volume="$prefix-source"
target_volume="$prefix-target"
fixture="$prefix-fixture"
source_scanner="$prefix-source-scan"
source_rescanner="$prefix-source-rescan"
target_carrier="$prefix-target-carrier"
repairer="$prefix-repair"
target_scanner="$prefix-target-scan"
source_manifest="$(mktemp)"
source_after_manifest="$(mktemp)"
target_manifest="$(mktemp)"
loaded_image_id=""
loaded_image_was_present=1

cleanup() {
  docker rm -f "$fixture" "$source_scanner" "$source_rescanner" "$target_carrier" "$repairer" \
    "$target_scanner" >/dev/null 2>&1 || true
  docker volume rm "$source_volume" "$target_volume" >/dev/null 2>&1 || true
  docker image rm "$helper_image" >/dev/null 2>&1 || true
  if [ "$loaded_image_was_present" -eq 0 ] && [ -n "$loaded_image_id" ]; then
    docker image rm "$loaded_image_id" >/dev/null 2>&1 || true
  fi
  rm -f "$source_manifest" "$source_after_manifest" "$target_manifest"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

before_image_ids="$(docker image ls --no-trunc \
  --filter label=dev.dory.component=transfer-helper --format '{{.ID}}')"
load_output="$(docker image load --input "$IMAGE_ARCHIVE")"
loaded_image_id="$(printf '%s\n' "$load_output" | sed -n 's/^Loaded image ID: //p' | tail -1)"
printf '%s' "$loaded_image_id" | grep -Eq '^sha256:[0-9a-f]{64}$' || {
  echo "volume transfer gate: daemon did not report the loaded image ID" >&2
  exit 1
}
if printf '%s\n' "$before_image_ids" | grep -Fxq "$loaded_image_id"; then
  loaded_image_was_present=1
else
  loaded_image_was_present=0
fi
image_contract="$(docker image inspect "$loaded_image_id" --format \
  '{{.Architecture}}|{{.Os}}|{{json .Config.Entrypoint}}|{{index .Config.Labels "dev.dory.helper.sha256"}}|{{index .RootFS.Layers 0}}')"
[ "$image_contract" = "arm64|linux|[\"/dory-transfer-helper\"]|$EXPECTED_HELPER_SHA256|$expected_layer_diff_id" ] || {
  echo "volume transfer gate: loaded image contract mismatch" >&2
  exit 1
}
docker image tag "$loaded_image_id" "$helper_image"
helper_image_id="$loaded_image_id"
docker volume create "$source_volume" >/dev/null
docker volume create "$target_volume" >/dev/null

docker run --name "$fixture" --network none \
  --mount "type=volume,src=$source_volume,dst=/data" \
  --entrypoint python "$FIXTURE_IMAGE" -c '
import os, socket
root=b"/data"
os.chown(root, 111, 222)
os.chmod(root, 0o751)
os.setxattr(root, b"user.root", b"root-value\x00\xff", follow_symlinks=False)
os.mkdir(root+b"/nested", 0o711)
path=root+b"/nested/name-\xff"
fd=os.open(path, os.O_CREAT|os.O_WRONLY, 0o750)
os.write(fd, b"exact-content\x00\xff")
os.close(fd)
os.chown(path, 123, 456)
os.chmod(path, 0o6750)
os.utime(path, ns=(1712345678123456789,1712345678123456789), follow_symlinks=False)
os.setxattr(path, b"user.dory", b"metadata\x00\xff", follow_symlinks=False)
os.link(path, root+b"/nested/hard-link")
os.symlink(b"name-\xff", root+b"/nested/symbolic-link")
os.mkfifo(root+b"/fifo", 0o640)
sparse=root+b"/sparse"
fd=os.open(sparse, os.O_CREAT|os.O_WRONLY, 0o600)
os.write(fd,b"HEAD")
os.lseek(fd,8*1024*1024-4,os.SEEK_SET)
os.write(fd,b"TAIL")
os.close(fd)
os.chown(sparse, 333, 444)
os.setxattr(sparse, b"user.sparse", b"yes", follow_symlinks=False)
sock=socket.socket(socket.AF_UNIX)
sock.bind((root+b"/socket").decode("ascii"))
sock.close()
os.utime(root+b"/nested", ns=(1611111111222222222,1611111111222222222), follow_symlinks=False)
os.utime(root, ns=(1511111111333333333,1511111111333333333), follow_symlinks=False)
' >/dev/null

docker create --name "$source_scanner" --network none \
  --mount "type=volume,src=$source_volume,dst=/data,readonly" \
  "$helper_image" scan --root /data --output /manifest.json >/dev/null
source_receipt="$(docker start -a "$source_scanner")"
docker cp "$source_scanner:/manifest.json" "$source_manifest"

docker create --name "$target_carrier" --network none \
  --mount "type=volume,src=$target_volume,dst=/data" \
  "$helper_image" scan --root /data --output /unused.json >/dev/null
docker cp "$fixture:/data/." - | docker cp - "$target_carrier:/data"

docker create --name "$repairer" --network none \
  --mount "type=volume,src=$target_volume,dst=/data" \
  "$helper_image" repair --root /data --manifest /source-manifest.json >/dev/null
docker cp "$source_manifest" "$repairer:/source-manifest.json"
repair_receipt="$(docker start -a "$repairer")"

docker create --name "$source_rescanner" --network none \
  --mount "type=volume,src=$source_volume,dst=/data,readonly" \
  "$helper_image" scan --root /data --output /manifest.json >/dev/null
source_after_receipt="$(docker start -a "$source_rescanner")"
docker cp "$source_rescanner:/manifest.json" "$source_after_manifest"

docker create --name "$target_scanner" --network none \
  --mount "type=volume,src=$target_volume,dst=/data,readonly" \
  "$helper_image" scan --root /data --output /manifest.json >/dev/null
target_receipt="$(docker start -a "$target_scanner")"
docker cp "$target_scanner:/manifest.json" "$target_manifest"

physical="$(docker run --rm --network none \
  --mount "type=volume,src=$target_volume,dst=/data,readonly" \
  --entrypoint python "$FIXTURE_IMAGE" -c '
import json, os
st=os.stat(b"/data/sparse")
print(json.dumps({
  "logicalBytes":st.st_size,
  "allocatedBytes":st.st_blocks*512,
  "rootXattr":os.getxattr(b"/data",b"user.root").hex(),
  "fileXattr":os.getxattr(b"/data/nested/name-\xff",b"user.dory").hex(),
  "socketExists":os.path.lexists(b"/data/socket")
},separators=(",",":")))
')"

python3 - "$source_manifest" "$source_after_manifest" "$target_manifest" "$source_receipt" \
  "$source_after_receipt" "$repair_receipt" "$target_receipt" "$physical" \
  "$actual_helper_sha256" "$actual_image_archive_sha256" "$image_config_digest" \
  "$helper_image_id" "$fixture_id" <<'PY'
import json, sys
source_path, source_after_path, target_path = sys.argv[1:4]
source_receipt, source_after_receipt, repair_receipt, target_receipt, physical = map(
    json.loads, sys.argv[4:9]
)
helper_sha256, image_archive_sha256, image_config_digest, helper_image_id, fixture_image_id = (
    sys.argv[9:14]
)
with open(source_path, "rb") as handle:
    source = json.load(handle)
with open(source_after_path, "rb") as handle:
    source_after = json.load(handle)
with open(target_path, "rb") as handle:
    target = json.load(handle)
assert source_after == source, "source changed during transfer"
assert source_after_receipt["manifest_sha256"] == source_receipt["manifest_sha256"]
source["entries"] = [entry for entry in source["entries"] if entry["kind"] != "socket"]
assert target == source, "independent target manifest differs from normalized source"
assert source_receipt["socket_count"] == 1
assert repair_receipt["excluded_socket_count"] == 1
assert repair_receipt["verified_entry_count"] == len(target["entries"])
assert repair_receipt["target_manifest_sha256"] == target_receipt["manifest_sha256"]
assert physical["logicalBytes"] == 8 * 1024 * 1024
assert physical["allocatedBytes"] < physical["logicalBytes"] // 4
assert physical["rootXattr"] == b"root-value\x00\xff".hex()
assert physical["fileXattr"] == b"metadata\x00\xff".hex()
assert physical["socketExists"] is False
print(json.dumps({
    "schemaVersion": 1,
    "status": "PASS",
    "platform": "linux/arm64",
    "helperSha256": helper_sha256,
    "helperImageArchiveSha256": image_archive_sha256,
    "helperImageConfigDigest": image_config_digest,
    "helperImageId": helper_image_id,
    "fixtureImageId": fixture_image_id,
    "sourceManifestSha256": source_receipt["manifest_sha256"],
    "targetManifestSha256": target_receipt["manifest_sha256"],
    "sourceEntries": source_receipt["entry_count"],
    "verifiedTargetEntries": target_receipt["entry_count"],
    "excludedSockets": repair_receipt["excluded_socket_count"],
    "sparseLogicalBytes": physical["logicalBytes"],
    "sparseAllocatedBytes": physical["allocatedBytes"]
}, separators=(",", ":")))
PY
