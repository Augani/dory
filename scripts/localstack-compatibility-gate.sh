#!/bin/bash
# Exercises LocalStack's real S3 and SQS APIs on an empty disposable Dory engine.
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
  --image REF         Digest-pinned LocalStack image

The gate refuses any existing container, named volume, or custom network. It proves dynamic
localhost publishing, LocalStack health, S3 object round-trip, SQS message round-trip, and exact
object cleanup. It never binds a user's Docker socket into LocalStack.
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

[ "$CONFIRM" = ISOLATED-ENGINE-LOCALSTACK ] \
  || die "requires --confirm ISOLATED-ENGINE-LOCALSTACK"
[ -S "$SOCKET" ] || die "socket is unavailable: $SOCKET"
[ -x "$DOCKER" ] || die "Docker CLI is unavailable: $DOCKER"
case "$IMAGE" in *@sha256:[0-9a-f][0-9a-f]*) ;; *) die "LocalStack image must be digest-pinned" ;; esac
[ -n "$WORKROOT" ] || die "--workroot is required"
[ ! -e "$WORKROOT" ] || die "workroot already exists: $WORKROOT"
for command in curl lsof python3; do
  command -v "$command" >/dev/null || die "missing required command: $command"
done

mkdir -p "$WORKROOT/evidence"
WORKROOT="$(cd "$WORKROOT" && pwd)"
EVIDENCE="$WORKROOT/evidence"
export DOCKER_HOST="unix://$SOCKET"
unset DOCKER_CONTEXT
docker_e() { "$DOCKER" "$@"; }
custom_network_ids() { docker_e network ls --filter type=custom --format '{{.ID}}' | sed '/^$/d'; }
object_counts() {
  printf 'containers=%s\n' "$(docker_e ps -aq | sed '/^$/d' | wc -l | tr -d ' ')"
  printf 'volumes=%s\n' "$(docker_e volume ls -q | sed '/^$/d' | wc -l | tr -d ' ')"
  printf 'custom_networks=%s\n' "$(custom_network_ids | wc -l | tr -d ' ')"
}
cleanup_objects() {
  local ids
  ids="$(docker_e ps -aq)"; [ -z "$ids" ] || docker_e rm -f $ids >/dev/null 2>&1 || true
  ids="$(docker_e volume ls -q)"; [ -z "$ids" ] || docker_e volume rm -f $ids >/dev/null 2>&1 || true
  ids="$(custom_network_ids)"; [ -z "$ids" ] || docker_e network rm $ids >/dev/null 2>&1 || true
}
trap 'set +e; cleanup_objects' EXIT INT TERM

object_counts > "$EVIDENCE/baseline.txt"
grep -qx 'containers=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing containers"
grep -qx 'volumes=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing named volumes"
grep -qx 'custom_networks=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing custom networks"

docker_e pull "$IMAGE" > "$EVIDENCE/image-pull.txt"
docker_e image inspect "$IMAGE" > "$EVIDENCE/image-inspect.json"
container="dory-localstack-$$"
docker_e run -d --name "$container" \
  -e SERVICES=s3,sqs \
  -e EAGER_SERVICE_LOADING=1 \
  -p 127.0.0.1::4566 \
  "$IMAGE" > "$EVIDENCE/container-id.txt"

published=""
for _ in $(seq 1 300); do
  published="$(docker_e port "$container" 4566/tcp 2>/dev/null | sed -n '1p')"
  [ -n "$published" ] && break
  sleep 0.2
done
[ -n "$published" ] || die "LocalStack dynamic host port was not published"
printf '%s\n' "$published" > "$EVIDENCE/published-port.txt"
host_port="${published##*:}"
printf '%s\n' "$host_port" | grep -Eq '^[1-9][0-9]{0,4}$' \
  || die "LocalStack published port is invalid: $published"

healthy=0
for _ in $(seq 1 600); do
  if curl -fsS --max-time 3 "http://127.0.0.1:$host_port/_localstack/health" \
      > "$EVIDENCE/health.json.partial" 2>/dev/null; then
    if python3 - "$EVIDENCE/health.json.partial" <<'PY'
import json, sys
services = json.load(open(sys.argv[1], encoding="utf-8")).get("services", {})
raise SystemExit(0 if services.get("s3") in ("available", "running") and services.get("sqs") in ("available", "running") else 1)
PY
    then healthy=1; break; fi
  fi
  sleep 0.5
done
[ "$healthy" -eq 1 ] || { docker_e logs "$container" > "$EVIDENCE/container.log" 2>&1 || true; die "LocalStack S3/SQS did not become healthy"; }
mv "$EVIDENCE/health.json.partial" "$EVIDENCE/health.json"

lsof -nP -iTCP:"$host_port" -sTCP:LISTEN > "$EVIDENCE/host-listener.txt"
grep -Eq "TCP 127\\.0\\.0\\.1:$host_port \\(LISTEN\\)" "$EVIDENCE/host-listener.txt" \
  || die "requested loopback port has no 127.0.0.1 host listener"
if grep -Eq "TCP (\\*|0\\.0\\.0\\.0):$host_port \\(LISTEN\\)" "$EVIDENCE/host-listener.txt"; then
  die "requested loopback port was widened to all host interfaces"
fi

docker_e exec "$container" sh -lc '
  set -eu
  printf "dory-localstack-object\n" > /tmp/dory-object
  awslocal s3api create-bucket --bucket dory-compat-bucket >/tmp/create-bucket.json
  awslocal s3api put-object --bucket dory-compat-bucket --key proof --body /tmp/dory-object >/tmp/put-object.json
  awslocal s3api get-object --bucket dory-compat-bucket --key proof /tmp/dory-object-out >/tmp/get-object.json
  cmp /tmp/dory-object /tmp/dory-object-out
  queue_url="$(awslocal sqs create-queue --queue-name dory-compat-queue --query QueueUrl --output text)"
  awslocal sqs send-message --queue-url "$queue_url" --message-body dory-localstack-message >/tmp/send-message.json
  body="$(awslocal sqs receive-message --queue-url "$queue_url" --wait-time-seconds 2 --query "Messages[0].Body" --output text)"
  test "$body" = dory-localstack-message
  printf "s3=PASS\nsqs=PASS\n"
' > "$EVIDENCE/service-roundtrip.txt" 2> "$EVIDENCE/service-roundtrip.stderr"
grep -qx 's3=PASS' "$EVIDENCE/service-roundtrip.txt" || die "LocalStack S3 round-trip failed"
grep -qx 'sqs=PASS' "$EVIDENCE/service-roundtrip.txt" || die "LocalStack SQS round-trip failed"

docker_e logs "$container" > "$EVIDENCE/container.log" 2>&1 || true
cleanup_objects
object_counts > "$EVIDENCE/final.txt"
cmp -s "$EVIDENCE/baseline.txt" "$EVIDENCE/final.txt" \
  || die "LocalStack gate did not restore the exact empty object baseline"

cat > "$WORKROOT/manifest.txt.partial" <<EOF
status=PASS
localstack_image=$IMAGE
dynamic_localhost_port=PASS
loopback_only_listener=PASS
health_endpoint=PASS
s3_object_roundtrip=PASS
sqs_message_roundtrip=PASS
exact_baseline_cleanup=PASS
completed_epoch=$(date +%s)
EOF
mv "$WORKROOT/manifest.txt.partial" "$WORKROOT/manifest.txt"
trap - EXIT INT TERM
echo "LocalStack compatibility gate: PASS"
