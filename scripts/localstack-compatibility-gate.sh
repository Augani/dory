#!/bin/bash
# Exercises LocalStack's real S3 and SQS APIs on an explicitly empty disposable Dory engine.
set -euo pipefail

SOCKET=""
DOCKER=""
IMAGE="${DORY_RELEASE_LOCALSTACK_IMAGE:-localstack/localstack:4.14.0@sha256:3ebc37595918b8accb852f8048fef2aff047d465167edd655528065b07bc364a}"
WORKROOT=""
CONFIRM=""

usage() {
  cat <<'EOF'
Usage: scripts/localstack-compatibility-gate.sh [required options] [options]

Required:
  --socket PATH       Unix socket for an already-running disposable Dory engine
  --docker PATH       Exact Docker CLI from the candidate runtime
  --workroot DIR      New evidence directory owned by this gate
  --confirm TOKEN     Must be ISOLATED-ENGINE-LOCALSTACK

Options:
  --image REF         Digest-pinned LocalStack image already present in Dory

The gate refuses any existing container, named volume, or custom network. It proves dynamic
loopback-only publishing, LocalStack health, an S3 object round-trip, an SQS message round-trip,
and exact engine cleanup. It never pulls the image or binds any Docker socket into LocalStack.
EOF
}

die() { echo "LocalStack compatibility gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --image) need_value "$1" "$#"; IMAGE="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

# Refuse before inspecting a socket or creating evidence unless isolation was explicitly approved.
[ "$CONFIRM" = ISOLATED-ENGINE-LOCALSTACK ] \
  || die "requires --confirm ISOLATED-ENGINE-LOCALSTACK"
[ -S "$SOCKET" ] || die "socket is unavailable: $SOCKET"
[ "$(stat -f %u "$SOCKET")" = "$(id -u)" ] \
  || die "socket is not owned by the release user"
case "$DOCKER" in /*) ;; *) die "Docker CLI must be an absolute path" ;; esac
[ -f "$DOCKER" ] && [ ! -L "$DOCKER" ] && [ -x "$DOCKER" ] \
  || die "Docker CLI is unavailable or indirect: $DOCKER"
printf '%s\n' "$IMAGE" \
  | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[0-9a-f]{64}$' \
  || die "LocalStack image must be an exact digest reference"
case "$WORKROOT" in /*) ;; *) die "--workroot must be absolute" ;; esac
case "$WORKROOT" in /|"$HOME"|"$(pwd)") die "unsafe --workroot: $WORKROOT" ;; esac
[ ! -e "$WORKROOT" ] && [ ! -L "$WORKROOT" ] \
  || die "workroot already exists or is indirect: $WORKROOT"
for command in curl lsof python3 shasum; do
  command -v "$command" >/dev/null || die "missing required command: $command"
done

mkdir -p "$WORKROOT/evidence"
WORKROOT="$(cd "$WORKROOT" && pwd)"
EVIDENCE="$WORKROOT/evidence"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
CONTAINER_NAME="dory-localstack-$RUN_ID"
container_id=""
export DOCKER_HOST="unix://$SOCKET"
unset DOCKER_CONTEXT
docker_e() { "$DOCKER" "$@"; }
docker_e version > "$EVIDENCE/docker-version.txt" || die "Docker API is not ready"
docker_e image inspect "$IMAGE" > "$EVIDENCE/image-inspect.json" 2>&1 \
  || die "required offline LocalStack image is missing: $IMAGE"

custom_network_ids() {
  docker_e network ls --filter type=custom --format '{{.ID}}' | sed '/^$/d'
}
object_counts() {
  printf 'containers=%s\n' "$(docker_e ps -aq | sed '/^$/d' | wc -l | tr -d ' ')"
  printf 'volumes=%s\n' "$(docker_e volume ls -q | sed '/^$/d' | wc -l | tr -d ' ')"
  printf 'custom_networks=%s\n' "$(custom_network_ids | wc -l | tr -d ' ')"
}
object_counts > "$EVIDENCE/baseline.txt"
grep -qx 'containers=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing containers"
grep -qx 'volumes=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing named volumes"
grep -qx 'custom_networks=0' "$EVIDENCE/baseline.txt" \
  || die "engine has pre-existing custom networks"

cleanup() {
  set +e
  if [ -n "$container_id" ]; then
    docker_e rm -f -v "$container_id" > "$EVIDENCE/container-cleanup.log" 2>&1 || true
  fi
  docker_e ps -aq --filter "label=dory.release.localstack.run=$RUN_ID" 2>/dev/null \
    | while IFS= read -r id; do
        [ -z "$id" ] || docker_e rm -f -v "$id" >> "$EVIDENCE/container-cleanup.log" 2>&1 || true
      done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

container_id="$(docker_e run -d --pull=never \
  --name "$CONTAINER_NAME" \
  --label "dory.release.localstack.run=$RUN_ID" \
  -e SERVICES=s3,sqs \
  -e EAGER_SERVICE_LOADING=1 \
  -p 127.0.0.1::4566 \
  "$IMAGE")"
printf '%s\n' "$container_id" | grep -Eq '^[0-9a-f]{64}$' \
  || die "LocalStack returned an invalid container ID"
printf '%s\n' "$container_id" > "$EVIDENCE/container-id.txt"
docker_e inspect "$container_id" > "$EVIDENCE/container-inspect.json"
python3 - "$EVIDENCE/container-inspect.json" "$IMAGE" "$RUN_ID" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    documents = json.load(handle)
if not isinstance(documents, list) or len(documents) != 1 or not isinstance(documents[0], dict):
    raise SystemExit("LocalStack inspect result has an unexpected shape")
document = documents[0]
config = document.get("Config")
host = document.get("HostConfig")
mounts = document.get("Mounts")
if not isinstance(config, dict) or config.get("Image") != sys.argv[2]:
    raise SystemExit("LocalStack container did not use the exact requested image")
labels = config.get("Labels")
if not isinstance(labels, dict) or labels.get("dory.release.localstack.run") != sys.argv[3]:
    raise SystemExit("LocalStack ownership label is missing")
if not isinstance(host, dict) or host.get("Binds") not in (None, []):
    raise SystemExit("LocalStack unexpectedly received a host bind")
if not isinstance(mounts, list) or any(
    isinstance(mount, dict) and mount.get("Destination") == "/var/run/docker.sock"
    for mount in mounts
):
    raise SystemExit("LocalStack unexpectedly received a Docker socket")
bindings = host.get("PortBindings")
binding = bindings.get("4566/tcp") if isinstance(bindings, dict) else None
if not isinstance(binding, list) or len(binding) != 1 or binding[0].get("HostIp") != "127.0.0.1":
    raise SystemExit("LocalStack port was not bound only to IPv4 loopback")
PY

published=""
for _ in $(seq 1 300); do
  published="$(docker_e port "$container_id" 4566/tcp 2>/dev/null | sed -n '1p')"
  [ -n "$published" ] && break
  sleep 0.2
done
[ -n "$published" ] || die "LocalStack dynamic host port was not published"
printf '%s\n' "$published" > "$EVIDENCE/published-port.txt"
case "$published" in 127.0.0.1:*) ;; *) die "LocalStack port is not loopback-only: $published" ;; esac
host_port="${published##*:}"
python3 - "$host_port" <<'PY'
import sys

if not sys.argv[1].isdigit() or not 1 <= int(sys.argv[1]) <= 65535:
    raise SystemExit("LocalStack published port is invalid")
PY

healthy=0
for _ in $(seq 1 600); do
  if curl -fsS --max-time 3 "http://127.0.0.1:$host_port/_localstack/health" \
      > "$EVIDENCE/health.json.partial" 2>/dev/null; then
    if python3 - "$EVIDENCE/health.json.partial" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    document = json.load(handle)
services = document.get("services") if isinstance(document, dict) else None
if not isinstance(services, dict):
    raise SystemExit(1)
valid = {"available", "running"}
raise SystemExit(0 if services.get("s3") in valid and services.get("sqs") in valid else 1)
PY
    then
      healthy=1
      break
    fi
  fi
  sleep 0.5
done
if [ "$healthy" -ne 1 ]; then
  docker_e logs "$container_id" > "$EVIDENCE/container.log" 2>&1 || true
  die "LocalStack S3/SQS did not become healthy"
fi
mv "$EVIDENCE/health.json.partial" "$EVIDENCE/health.json"

lsof -nP -iTCP:"$host_port" -sTCP:LISTEN > "$EVIDENCE/host-listener.txt"
grep -Eq "TCP 127\\.0\\.0\\.1:$host_port \\(LISTEN\\)" "$EVIDENCE/host-listener.txt" \
  || die "requested loopback port has no 127.0.0.1 host listener"
if grep -Eq "TCP (\\*|0\\.0\\.0\\.0):$host_port \\(LISTEN\\)" "$EVIDENCE/host-listener.txt"; then
  die "requested loopback port was widened to all host interfaces"
fi

docker_e exec "$container_id" sh -lc '
  set -eu
  printf "dory-localstack-object\n" > /tmp/dory-object
  awslocal s3api create-bucket --bucket dory-compat-bucket >/tmp/create-bucket.json
  awslocal s3api put-object --bucket dory-compat-bucket --key proof --body /tmp/dory-object >/tmp/put-object.json
  awslocal s3api get-object --bucket dory-compat-bucket --key proof /tmp/dory-object-out >/tmp/get-object.json
  cmp /tmp/dory-object /tmp/dory-object-out
  queue_url="$(awslocal sqs create-queue --queue-name dory-compat-queue --query QueueUrl --output text)"
  awslocal sqs send-message --queue-url "$queue_url" --message-body dory-localstack-message >/tmp/send-message.json
  body=""
  attempt=0
  while [ "$attempt" -lt 10 ] && [ "$body" != dory-localstack-message ]; do
    body="$(awslocal sqs receive-message --queue-url "$queue_url" --wait-time-seconds 2 --query "Messages[0].Body" --output text)"
    attempt=$((attempt + 1))
  done
  test "$body" = dory-localstack-message
  printf "s3=PASS\nsqs=PASS\n"
' > "$EVIDENCE/service-roundtrip.txt" 2> "$EVIDENCE/service-roundtrip.stderr"
grep -qx 's3=PASS' "$EVIDENCE/service-roundtrip.txt" \
  || die "LocalStack S3 round-trip failed"
grep -qx 'sqs=PASS' "$EVIDENCE/service-roundtrip.txt" \
  || die "LocalStack SQS round-trip failed"

docker_e logs "$container_id" > "$EVIDENCE/container.log" 2>&1 || true
cleanup
container_id=""
object_counts > "$EVIDENCE/final.txt"
cmp -s "$EVIDENCE/baseline.txt" "$EVIDENCE/final.txt" \
  || die "LocalStack gate did not restore the exact empty object baseline"

cat > "$WORKROOT/manifest.txt.partial" <<EOF
status=PASS
localstack_image=$IMAGE
localstack_image_id=$(docker_e image inspect --format '{{.Id}}' "$IMAGE")
docker_cli_sha256=$(shasum -a 256 "$DOCKER" | awk '{print $1}')
offline_image_use=PASS
no_docker_socket_mount=PASS
dynamic_localhost_port=PASS
loopback_only_listener=PASS
health_endpoint=PASS
s3_object_roundtrip=PASS
sqs_message_roundtrip=PASS
owned_container_cleanup=PASS
exact_baseline_cleanup=PASS
completed_epoch=$(date +%s)
EOF
mv "$WORKROOT/manifest.txt.partial" "$WORKROOT/manifest.txt"
trap - EXIT INT TERM
echo "LocalStack compatibility gate: PASS"
