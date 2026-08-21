#!/bin/bash
# Exact ECR regression: interrupt a large layer upload, resume it, repeat the manifest PUT,
# repull/run exact bytes, and delete both remote state and isolated credentials.
set -euo pipefail
umask 077

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
[ "$(stat -f %u "$SOCKET")" = "$(id -u)" ] \
  || die "Dory socket is not owned by the release user"
case "$DOCKER" in /*) ;; *) die "Docker CLI must be an absolute path" ;; esac
[ -f "$DOCKER" ] && [ ! -L "$DOCKER" ] && [ -x "$DOCKER" ] \
  || die "Docker CLI is unavailable or indirect: $DOCKER"
DOCKER="$(cd "$(dirname "$DOCKER")" && pwd -P)/$(basename "$DOCKER")"
BUILDX="$(dirname "$DOCKER")/docker-buildx"
[ -f "$BUILDX" ] && [ ! -L "$BUILDX" ] && [ -x "$BUILDX" ] \
  || die "the exact candidate Docker CLI has no sibling docker-buildx plugin: $BUILDX"
printf '%s\n' "$BASE_IMAGE" \
  | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[0-9a-f]{64}$' \
  || die "--base-image must be digest-pinned"
printf '%s\n' "$REGISTRY" | grep -Eq '^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com$' \
  || die "--registry must be an ECR registry host"
printf '%s\n' "$REPOSITORY" | grep -Eq '^[a-z0-9]+([._/-][a-z0-9]+)*$' \
  || die "--repository contains unsupported characters"
printf '%s\n' "$REGION" | grep -Eq '^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$' \
  || die "--region is invalid"
registry_account="${REGISTRY%%.*}"
registry_region="${REGISTRY#*.dkr.ecr.}"
registry_region="${registry_region%.amazonaws.com}"
[ "$registry_region" = "$REGION" ] \
  || die "registry hostname region differs from --region"
case "$LAYER_MIB" in ''|*[!0-9]*) die "--layer-mib must be an integer" ;; esac
[ "$LAYER_MIB" -ge 64 ] || die "--layer-mib must be at least 64"
for command in python3 shasum; do
  command -v "$command" >/dev/null || die "required command is missing: $command"
done
AWS_CLI="$(command -v aws 2>/dev/null || true)"
[ -n "$AWS_CLI" ] || die "required command is missing: aws"
AWS_CLI="$(python3 - "$AWS_CLI" <<'PY'
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
)"
[ -f "$AWS_CLI" ] && [ ! -L "$AWS_CLI" ] && [ -x "$AWS_CLI" ] \
  || die "resolved AWS CLI is unavailable or indirect"
case "$WORKROOT" in /*) ;; *) die "--workroot must be absolute" ;; esac
case "$WORKROOT" in /|"$HOME"|"$(pwd)") die "unsafe --workroot: $WORKROOT" ;; esac
[ ! -e "$WORKROOT" ] && [ ! -L "$WORKROOT" ] \
  || die "workroot already exists or is indirect: $WORKROOT"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
TAG="dory-retry-${RUN_ID//[^a-zA-Z0-9]/}"
REMOTE_REF="$REGISTRY/$REPOSITORY:$TAG"
mkdir "$WORKROOT"
WORKROOT="$(cd "$WORKROOT" && pwd -P)"
WORKDIR="$WORKROOT/$RUN_ID"
DOCKER_CONFIG="$WORKDIR/docker-config"
CONTEXT="$WORKDIR/context"
MANIFEST="$WORKDIR/manifest.txt"
mkdir -p "$DOCKER_CONFIG/cli-plugins" "$CONTEXT"
cp "$BUILDX" "$DOCKER_CONFIG/cli-plugins/docker-buildx"
chmod 0755 "$DOCKER_CONFIG/cli-plugins/docker-buildx"
[ -f "$DOCKER_CONFIG/cli-plugins/docker-buildx" ] \
  && [ ! -L "$DOCKER_CONFIG/cli-plugins/docker-buildx" ] \
  || die "isolated Buildx plugin is unavailable or indirect"
[ "$(shasum -a 256 "$DOCKER_CONFIG/cli-plugins/docker-buildx" | awk '{print $1}')" \
    = "$(shasum -a 256 "$BUILDX" | awk '{print $1}')" ] \
  || die "isolated Buildx copy differs from the candidate plugin"
REMOTE_DELETED=0
RUN_LABEL="dev.dory.ecr-retry=$RUN_ID"

docker_e() { DOCKER_HOST="unix://$SOCKET" DOCKER_CONFIG="$DOCKER_CONFIG" "$DOCKER" "$@"; }
docker_e version > "$WORKDIR/docker-version.txt" || die "Docker API is not ready"
docker_e buildx version > "$WORKDIR/buildx-version.txt" \
  || die "the bundled Buildx plugin is unavailable inside the isolated credential store"
docker_e image inspect "$BASE_IMAGE" > "$WORKDIR/base-image-inspect.json" 2>/dev/null \
  || die "base image is not present in the isolated store"
python3 - "$WORKDIR/base-image-inspect.json" "$BASE_IMAGE" <<'PY'
import json
import pathlib
import sys

document = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if not isinstance(document, list) or len(document) != 1 or not isinstance(document[0], dict):
    raise SystemExit("base image inspect is not one exact image")
requested_name, requested_digest = sys.argv[2].rsplit("@", 1)
accepted_names = {requested_name}
first = requested_name.split("/", 1)[0]
if "/" not in requested_name:
    accepted_names.add("docker.io/library/" + requested_name)
elif first != "localhost" and "." not in first and ":" not in first:
    accepted_names.add("docker.io/" + requested_name)
repo_digests = document[0].get("RepoDigests")
if not isinstance(repo_digests, list) or not any(
    value == name + "@" + requested_digest
    for name in accepted_names
    for value in repo_digests
):
    raise SystemExit("local base image does not retain its exact registry authority")
PY
"$AWS_CLI" --version > "$WORKDIR/aws-version.txt" 2>&1 \
  || die "AWS CLI version inspection failed"
"$AWS_CLI" sts get-caller-identity > "$WORKDIR/aws-caller.json" \
  || die "AWS caller identity is unavailable"
"$AWS_CLI" ecr describe-repositories --region "$REGION" --repository-names "$REPOSITORY" \
  > "$WORKDIR/ecr-repository.json" || die "disposable ECR repository is unavailable"
python3 - "$WORKDIR/aws-caller.json" "$WORKDIR/ecr-repository.json" \
  "$registry_account" "$REGISTRY/$REPOSITORY" <<'PY'
import json
import pathlib
import sys

caller = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
repositories = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
if not isinstance(caller, dict) or caller.get("Account") != sys.argv[3]:
    raise SystemExit("AWS caller account differs from the ECR registry account")
items = repositories.get("repositories") if isinstance(repositories, dict) else None
if not isinstance(items, list) or len(items) != 1 or not isinstance(items[0], dict):
    raise SystemExit("ECR repository lookup did not return one exact repository")
repository = items[0]
if repository.get("registryId") != sys.argv[3] or repository.get("repositoryUri") != sys.argv[4]:
    raise SystemExit("ECR repository authority differs from the requested registry path")
PY
caller_account_sha256="$(printf '%s' "$registry_account" | shasum -a 256 | awk '{print $1}')"
repository_authority_sha256="$(printf '%s' "$REGISTRY/$REPOSITORY" | shasum -a 256 | awk '{print $1}')"
rm -f "$WORKDIR/aws-caller.json" "$WORKDIR/ecr-repository.json"
REMOTE_DIGEST_REF=""

cleanup() {
  set +e
  docker_e ps -aq --filter "label=$RUN_LABEL" 2>/dev/null \
    | while IFS= read -r id; do
        [ -z "$id" ] || docker_e rm -f "$id" >/dev/null 2>&1 || true
      done
  docker_e image rm -f "$REMOTE_REF" >/dev/null 2>&1 || true
  [ -z "$REMOTE_DIGEST_REF" ] || docker_e image rm -f "$REMOTE_DIGEST_REF" >/dev/null 2>&1 || true
  if [ "$REMOTE_DELETED" -eq 0 ]; then
    "$AWS_CLI" ecr batch-delete-image --region "$REGION" --repository-name "$REPOSITORY" \
      --image-ids "imageTag=$TAG" >/dev/null 2>&1 || true
  fi
  docker_e logout "$REGISTRY" >/dev/null 2>&1 || true
  rm -rf "$DOCKER_CONFIG" "$CONTEXT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if "$AWS_CLI" ecr describe-images --region "$REGION" --repository-name "$REPOSITORY" \
    --image-ids "imageTag=$TAG" >/dev/null 2>&1; then
  die "unique retry tag unexpectedly exists before the gate"
fi

"$AWS_CLI" ecr get-login-password --region "$REGION" \
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
LABEL $RUN_LABEL
COPY retry-layer.bin /dory-ecr-retry.bin
RUN test "\$(sha256sum /dory-ecr-retry.bin | awk '{print \$1}')" = "$layer_sha"
CMD ["sha256sum", "/dory-ecr-retry.bin"]
EOF

DOCKER_BUILDKIT=1 docker_e build --network none --pull=false --progress=plain \
  -t "$REMOTE_REF" "$CONTEXT" \
  > "$WORKDIR/build.out" 2> "$WORKDIR/build.err" \
  || die "ECR retry fixture build failed"

set +e
docker_e push "$REMOTE_REF" > "$WORKDIR/interrupted-push.out" \
  2> "$WORKDIR/interrupted-push.err" &
push_pid=$!
interrupted=0
for _ in $(seq 1 600); do
  if ! kill -0 "$push_pid" 2>/dev/null; then break; fi
  # Docker 28's non-TTY progress renderer reports active uploads as `Waiting` and then jumps
  # directly to `Pushed`; older clients report `Pushing`. Accept either active-progress spelling,
  # but require the push process to remain alive through a one-second upload window before killing
  # it. A completed fast push cannot masquerade as the interrupted-upload regression.
  if grep -Eq '([[:space:]]|:)(Pushing|Waiting)([[:space:]]|$)' \
      "$WORKDIR/interrupted-push.out" "$WORKDIR/interrupted-push.err" 2>/dev/null; then
    sleep 1
    kill -0 "$push_pid" 2>/dev/null || break
    kill -TERM "$push_pid"
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
push_digests="$(python3 - \
  "$WORKDIR/resumed-push.out" "$WORKDIR/resumed-push.err" \
  "$WORKDIR/repeated-manifest-put.out" "$WORKDIR/repeated-manifest-put.err" <<'PY'
import pathlib
import re
import sys

def digest_for(paths):
    text = "\n".join(pathlib.Path(path).read_text(encoding="utf-8") for path in paths)
    matches = re.findall(r"(?m)^digest:\s*(sha256:[0-9a-f]{64})\s+size:\s*[1-9][0-9]*\s*$", text)
    if len(matches) != 1:
        raise SystemExit("ECR push output does not contain one exact manifest digest")
    return matches[0]

resumed = digest_for(sys.argv[1:3])
repeated = digest_for(sys.argv[3:5])
if resumed != repeated:
    raise SystemExit("repeated ECR manifest PUT changed the manifest digest")
print(resumed)
PY
)" || die "ECR push digest evidence failed semantic validation"
"$AWS_CLI" ecr describe-images --region "$REGION" --repository-name "$REPOSITORY" \
  --image-ids "imageTag=$TAG" > "$WORKDIR/ecr-image-after-push.json" \
  || die "ECR image is unavailable after repeated push"
remote_digest="$(python3 - "$WORKDIR/ecr-image-after-push.json" "$TAG" "$push_digests" <<'PY'
import json
import pathlib
import re
import sys

document = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
details = document.get("imageDetails") if isinstance(document, dict) else None
if not isinstance(details, list) or len(details) != 1 or not isinstance(details[0], dict):
    raise SystemExit("ECR did not return one exact pushed image")
detail = details[0]
digest = detail.get("imageDigest")
if digest != sys.argv[3] or re.fullmatch(r"sha256:[0-9a-f]{64}", digest or "") is None:
    raise SystemExit("ECR registry digest differs from the repeated push digest")
tags = detail.get("imageTags")
if not isinstance(tags, list) or tags != [sys.argv[2]]:
    raise SystemExit("ECR pushed image has an unexpected tag authority")
print(digest)
PY
)" || die "ECR remote image evidence failed semantic validation"
REMOTE_DIGEST_REF="$REGISTRY/$REPOSITORY@$remote_digest"
docker_e image rm -f "$REMOTE_REF" >/dev/null
docker_e pull "$REMOTE_DIGEST_REF" > "$WORKDIR/repull.out" 2> "$WORKDIR/repull.err" \
  || die "ECR repull failed after interrupted/resumed push"
run_sha="$(docker_e run --rm --pull=never --network none --label "$RUN_LABEL" \
  "$REMOTE_DIGEST_REF" | awk '{print $1}')"
[ "$run_sha" = "$layer_sha" ] || die "ECR repull/run returned the wrong layer checksum"
docker_e image rm -f "$REMOTE_DIGEST_REF" > "$WORKDIR/local-image-delete.out" \
  2> "$WORKDIR/local-image-delete.err" \
  || die "local ECR retry image cleanup failed"
if docker_e image inspect "$REMOTE_REF" >/dev/null 2>&1 \
    || docker_e image inspect "$REMOTE_DIGEST_REF" >/dev/null 2>&1; then
  die "local ECR retry image survived cleanup"
fi

"$AWS_CLI" ecr batch-delete-image --region "$REGION" --repository-name "$REPOSITORY" \
  --image-ids "imageTag=$TAG" > "$WORKDIR/remote-delete.json" \
  || die "remote ECR cleanup failed"
python3 - "$WORKDIR/remote-delete.json" "$TAG" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
tag = sys.argv[2]
image_ids = payload.get("imageIds") if isinstance(payload, dict) else None
if not isinstance(image_ids, list) or len(image_ids) != 1 or image_ids[0].get("imageTag") != tag:
    raise SystemExit("ECR cleanup did not report the one unique image tag")
if payload.get("failures") not in (None, []):
    raise SystemExit(f"ECR cleanup reported failures: {payload.get('failures')}")
PY
set +e
"$AWS_CLI" ecr describe-images --region "$REGION" --repository-name "$REPOSITORY" \
  --image-ids "imageTag=$TAG" > "$WORKDIR/remote-after-delete.out" \
  2> "$WORKDIR/remote-after-delete.err"
remote_after_delete_rc=$?
set -e
[ "$remote_after_delete_rc" -ne 0 ] \
  || die "remote ECR tag survived confirmed deletion"
grep -F 'ImageNotFoundException' "$WORKDIR/remote-after-delete.err" >/dev/null \
  || die "remote ECR deletion could not be verified fail-closed"
REMOTE_DELETED=1
[ -z "$(docker_e ps -aq --filter "label=$RUN_LABEL")" ] \
  || die "owned ECR retry container survived cleanup"
docker_e logout "$REGISTRY" > "$WORKDIR/logout.out" 2> "$WORKDIR/logout.err" \
  || die "isolated ECR logout failed"
rm -rf "$DOCKER_CONFIG" "$CONTEXT"
[ ! -e "$DOCKER_CONFIG" ] || die "isolated Docker credential directory survived cleanup"

{
  echo "status=PASS"
  echo "run_id=$RUN_ID"
  echo "registry_sha256=$(printf '%s' "$REGISTRY" | shasum -a 256 | awk '{print $1}')"
  echo "repository_sha256=$(printf '%s' "$REPOSITORY" | shasum -a 256 | awk '{print $1}')"
  echo "caller_account_sha256=$caller_account_sha256"
  echo "repository_authority_sha256=$repository_authority_sha256"
  echo "region=$REGION"
  echo "base_image=$BASE_IMAGE"
  echo "docker_cli_sha256=$(shasum -a 256 "$DOCKER" | awk '{print $1}')"
  echo "buildx_cli_sha256=$(shasum -a 256 "$BUILDX" | awk '{print $1}')"
  echo "aws_cli_sha256=$(shasum -a 256 "$AWS_CLI" | awk '{print $1}')"
  echo "layer_mib=$LAYER_MIB"
  echo "layer_sha256=$layer_sha"
  echo "authenticated_login=PASS"
  echo "bundled_buildx=PASS"
  echo "interrupted_push_progress=PASS"
  echo "interrupted_push_nonzero=PASS"
  echo "resumed_blob_upload=PASS"
  echo "repeated_manifest_put=PASS"
  echo "repeated_manifest_digest=$remote_digest"
  echo "registry_digest_agreement=PASS"
  echo "digest_based_repull=PASS"
  echo "repull_run_checksum=PASS"
  echo "local_image_cleanup=PASS"
  echo "remote_tag_cleanup=PASS"
  echo "remote_deletion_verified=PASS"
  echo "owned_container_cleanup=PASS"
  echo "isolated_credential_cleanup=PASS"
  echo "completed_epoch=$(date +%s)"
} > "$MANIFEST"

trap - EXIT INT TERM
echo "ECR retry gate: PASS ($MANIFEST)"
