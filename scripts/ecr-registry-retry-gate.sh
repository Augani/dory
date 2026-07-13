#!/bin/bash
# Exact ECR regression: interrupt a large layer upload, resume it, repeat the manifest PUT,
# repull/run exact bytes, and delete both remote state and isolated credentials.
set -euo pipefail

SOCKET=""
DOCKER=""
BASE_IMAGE=""
REGISTRY=""
REPOSITORY=""
REGION=""
WORKROOT="${TMPDIR:-/tmp}/dory-ecr-retry"
CONFIRM=""
LAYER_MIB=96

usage() {
  cat <<EOF
Usage: scripts/ecr-registry-retry-gate.sh [required options]

  --socket PATH          Exact isolated Dory Docker socket
  --docker PATH          Exact Docker CLI
  --base-image REF       Existing digest-pinned Alpine-compatible image
  --registry HOST        ECR registry host (ACCOUNT.dkr.ecr.REGION.amazonaws.com)
  --repository NAME      Pre-created disposable ECR repository
  --region REGION        AWS region containing the repository
  --workroot DIR         Evidence root (default: $WORKROOT)
  --layer-mib N          Incompressible retry layer MiB (default: $LAYER_MIB)
  --confirm TOKEN        Must be DISPOSABLE-ECR-INTERRUPT-RETRY
  --help

AWS credentials are read only by the AWS CLI from its normal environment/provider chain. The gate
never prints or stores them. It refuses to run against a non-ECR host and always attempts to delete
its unique remote tag.
EOF
}

die() { echo "ECR retry gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --base-image) need_value "$1" "$#"; BASE_IMAGE="$2"; shift 2 ;;
    --registry) need_value "$1" "$#"; REGISTRY="$2"; shift 2 ;;
    --repository) need_value "$1" "$#"; REPOSITORY="$2"; shift 2 ;;
    --region) need_value "$1" "$#"; REGION="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --layer-mib) need_value "$1" "$#"; LAYER_MIB="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ "$CONFIRM" = DISPOSABLE-ECR-INTERRUPT-RETRY ] \
  || die "requires --confirm DISPOSABLE-ECR-INTERRUPT-RETRY"
[ -S "$SOCKET" ] || die "Dory socket is unavailable: $SOCKET"
[ -x "$DOCKER" ] || die "Docker CLI is not executable: $DOCKER"
printf '%s\n' "$BASE_IMAGE" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
  || die "--base-image must be digest-pinned"
printf '%s\n' "$REGISTRY" | grep -Eq '^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com$' \
  || die "--registry must be an ECR registry host"
printf '%s\n' "$REPOSITORY" | grep -Eq '^[a-z0-9]+([._/-][a-z0-9]+)*$' \
  || die "--repository contains unsupported characters"
printf '%s\n' "$REGION" | grep -Eq '^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$' \
  || die "--region is invalid"
case "$LAYER_MIB" in ''|*[!0-9]*) die "--layer-mib must be an integer" ;; esac
[ "$LAYER_MIB" -ge 64 ] || die "--layer-mib must be at least 64"
for command in aws python3 shasum; do
  command -v "$command" >/dev/null || die "required command is missing: $command"
done

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
TAG="dory-retry-${RUN_ID//[^a-zA-Z0-9]/}"
REMOTE_REF="$REGISTRY/$REPOSITORY:$TAG"
WORKDIR="$WORKROOT/$RUN_ID"
DOCKER_CONFIG="$WORKDIR/docker-config"
CONTEXT="$WORKDIR/context"
MANIFEST="$WORKDIR/manifest.txt"
mkdir -p "$DOCKER_CONFIG" "$CONTEXT"
REMOTE_DELETED=0

docker_e() { DOCKER_HOST="unix://$SOCKET" DOCKER_CONFIG="$DOCKER_CONFIG" "$DOCKER" "$@"; }
docker_e version >/dev/null || die "Docker API is not ready"
docker_e image inspect "$BASE_IMAGE" >/dev/null 2>&1 \
  || die "base image is not present in the isolated store"
aws ecr describe-repositories --region "$REGION" --repository-names "$REPOSITORY" \
  >/dev/null || die "disposable ECR repository is unavailable"

cleanup() {
  set +e
  docker_e image rm -f "$REMOTE_REF" >/dev/null 2>&1 || true
  if [ "$REMOTE_DELETED" -eq 0 ]; then
    aws ecr batch-delete-image --region "$REGION" --repository-name "$REPOSITORY" \
      --image-ids "imageTag=$TAG" >/dev/null 2>&1 || true
  fi
  docker_e logout "$REGISTRY" >/dev/null 2>&1 || true
  rm -rf "$DOCKER_CONFIG" "$CONTEXT"
}
trap cleanup EXIT INT TERM

if aws ecr describe-images --region "$REGION" --repository-name "$REPOSITORY" \
    --image-ids "imageTag=$TAG" >/dev/null 2>&1; then
  die "unique retry tag unexpectedly exists before the gate"
fi

aws ecr get-login-password --region "$REGION" \
  | docker_e login --username AWS --password-stdin "$REGISTRY" \
    > "$WORKDIR/login.out" 2> "$WORKDIR/login.err" \
  || die "isolated ECR login failed"

layer_path="$CONTEXT/retry-layer.bin"
layer_sha="$(python3 - "$layer_path" "$LAYER_MIB" <<'PY'
import hashlib
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
remaining = int(sys.argv[2]) * 1024 * 1024
digest = hashlib.sha256()
counter = 0
with path.open("wb") as handle:
    while remaining:
        block = bytearray()
        while len(block) < min(1024 * 1024, remaining):
            block.extend(hashlib.sha256(f"dory-ecr-retry-{counter}".encode()).digest())
            counter += 1
        chunk = bytes(block[:min(len(block), remaining)])
        handle.write(chunk)
        digest.update(chunk)
        remaining -= len(chunk)
print(digest.hexdigest())
PY
)"
cat > "$CONTEXT/Dockerfile" <<EOF
FROM $BASE_IMAGE
COPY retry-layer.bin /dory-ecr-retry.bin
RUN test "\$(sha256sum /dory-ecr-retry.bin | awk '{print \$1}')" = "$layer_sha"
CMD ["sha256sum", "/dory-ecr-retry.bin"]
EOF

DOCKER_BUILDKIT=1 docker_e build --progress=plain -t "$REMOTE_REF" "$CONTEXT" \
  > "$WORKDIR/build.out" 2> "$WORKDIR/build.err" \
  || die "ECR retry fixture build failed"

set +e
docker_e push "$REMOTE_REF" > "$WORKDIR/interrupted-push.out" \
  2> "$WORKDIR/interrupted-push.err" &
push_pid=$!
interrupted=0
for _ in $(seq 1 600); do
  if ! kill -0 "$push_pid" 2>/dev/null; then break; fi
  if grep -Eq '([[:space:]]|:)Pushing([[:space:]]|$)' \
      "$WORKDIR/interrupted-push.out" "$WORKDIR/interrupted-push.err" 2>/dev/null; then
    sleep 1
    kill -TERM "$push_pid" 2>/dev/null || true
    interrupted=1
    break
  fi
  sleep 0.1
done
wait "$push_pid"
interrupted_rc=$?
set -e
[ "$interrupted" -eq 1 ] || die "first ECR push completed or stalled before an upload could be interrupted"
[ "$interrupted_rc" -ne 0 ] || die "interrupted ECR push returned success"

docker_e push "$REMOTE_REF" > "$WORKDIR/resumed-push.out" 2> "$WORKDIR/resumed-push.err" \
  || die "resumed ECR push failed"
docker_e push "$REMOTE_REF" > "$WORKDIR/repeated-manifest-put.out" \
  2> "$WORKDIR/repeated-manifest-put.err" \
  || die "repeated ECR manifest PUT failed"
docker_e image rm -f "$REMOTE_REF" >/dev/null
docker_e pull "$REMOTE_REF" > "$WORKDIR/repull.out" 2> "$WORKDIR/repull.err" \
  || die "ECR repull failed after interrupted/resumed push"
run_sha="$(docker_e run --rm "$REMOTE_REF" | awk '{print $1}')"
[ "$run_sha" = "$layer_sha" ] || die "ECR repull/run returned the wrong layer checksum"
docker_e image rm -f "$REMOTE_REF" > "$WORKDIR/local-image-delete.out" \
  2> "$WORKDIR/local-image-delete.err" \
  || die "local ECR retry image cleanup failed"
if docker_e image inspect "$REMOTE_REF" >/dev/null 2>&1; then
  die "local ECR retry image survived cleanup"
fi

aws ecr batch-delete-image --region "$REGION" --repository-name "$REPOSITORY" \
  --image-ids "imageTag=$TAG" > "$WORKDIR/remote-delete.json" \
  || die "remote ECR cleanup failed"
python3 - "$WORKDIR/remote-delete.json" "$TAG" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
tag = sys.argv[2]
assert any(item.get("imageTag") == tag for item in payload.get("imageIds", [])), \
    "ECR cleanup did not report the unique image tag"
assert not payload.get("failures"), f"ECR cleanup reported failures: {payload.get('failures')}"
PY
REMOTE_DELETED=1
docker_e logout "$REGISTRY" > "$WORKDIR/logout.out" 2> "$WORKDIR/logout.err" \
  || die "isolated ECR logout failed"
rm -rf "$DOCKER_CONFIG" "$CONTEXT"
[ ! -e "$DOCKER_CONFIG" ] || die "isolated Docker credential directory survived cleanup"

{
  echo "status=PASS"
  echo "run_id=$RUN_ID"
  echo "registry_sha256=$(printf '%s' "$REGISTRY" | shasum -a 256 | awk '{print $1}')"
  echo "repository_sha256=$(printf '%s' "$REPOSITORY" | shasum -a 256 | awk '{print $1}')"
  echo "region=$REGION"
  echo "base_image=$BASE_IMAGE"
  echo "docker_cli_sha256=$(shasum -a 256 "$DOCKER" | awk '{print $1}')"
  echo "layer_mib=$LAYER_MIB"
  echo "layer_sha256=$layer_sha"
  echo "authenticated_login=PASS"
  echo "interrupted_push_nonzero=PASS"
  echo "resumed_blob_upload=PASS"
  echo "repeated_manifest_put=PASS"
  echo "repull_run_checksum=PASS"
  echo "local_image_cleanup=PASS"
  echo "remote_tag_cleanup=PASS"
  echo "isolated_credential_cleanup=PASS"
  echo "completed_epoch=$(date +%s)"
} > "$MANIFEST"

trap - EXIT INT TERM
echo "ECR retry gate: PASS ($MANIFEST)"
