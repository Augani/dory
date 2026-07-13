#!/bin/bash
# Prove Docker Desktop-compatible SSH-agent forwarding through Dory's guest-local well-known socket.
set -euo pipefail

SOCKET="${DORY_SSH_AGENT_GATE_SOCKET:-$HOME/.dory/dory.sock}"
DOCKER="${DORY_SSH_AGENT_GATE_DOCKER:-docker}"
IMAGE="${DORY_SSH_AGENT_GATE_IMAGE:-}"
WORKROOT="${DORY_SSH_AGENT_GATE_WORKROOT:-$HOME/.dory-ssh-agent-gate}"
CONCURRENCY="${DORY_SSH_AGENT_GATE_CONCURRENCY:-8}"

usage() {
  cat <<EOF
Usage: scripts/ssh-agent-forwarding-gate.sh [options]

  --socket PATH       Exact Dory Docker socket
  --docker PATH       Exact Docker CLI
  --image REF         Existing digest-pinned image containing sh and ssh-add
  --workroot PATH     Evidence root (default: $WORKROOT)
  --concurrency N     Concurrent agent clients (default: $CONCURRENCY)
  --help

Requires a live same-user SSH_AUTH_SOCK with at least one loaded public key. The gate proves both
an ordinary container bind to Dory's Docker Desktop-compatible guest socket and a BuildKit
RUN --mount=type=ssh session. It never stores key material: it compares sorted public-listing
hashes and records only SHA-256 values.
EOF
}

die() { echo "ssh-agent-forwarding-gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --image) need_value "$1" "$#"; IMAGE="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --concurrency) need_value "$1" "$#"; CONCURRENCY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$CONCURRENCY" in ''|*[!0-9]*) die "concurrency must be a positive integer" ;; esac
[ "$CONCURRENCY" -gt 0 ] || die "concurrency must be positive"
[ -S "$SOCKET" ] || die "Dory socket is unavailable: $SOCKET"
printf '%s\n' "$IMAGE" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
  || die "--image must be a digest-pinned image containing sh and ssh-add"
[ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ] \
  || die "SSH_AUTH_SOCK must name a live same-user SSH agent socket"
if [[ "$DOCKER" == */* ]]; then [ -x "$DOCKER" ] || die "Docker CLI is not executable"; fi
for command in ssh-add shasum sort; do command -v "$command" >/dev/null || die "missing $command"; done

docker_e() { DOCKER_HOST="unix://$SOCKET" "$DOCKER" "$@"; }
docker_e version >/dev/null || die "Dory Docker API is not ready"
docker_e image inspect "$IMAGE" >/dev/null 2>&1 || die "required image is not local: $IMAGE"
host_keys="$(ssh-add -L 2>/dev/null | LC_ALL=C sort)"
[ -n "$host_keys" ] || die "the release SSH agent has no public keys loaded"
host_hash="$(printf '%s\n' "$host_keys" | shasum -a 256 | awk '{print $1}')"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
OWNER="dory-ssh-agent-$RUN_ID"
BUILD_IMAGE="dory-ssh-agent-buildkit:gate-$(date +%s)-$$"
WORKDIR="$WORKROOT/$RUN_ID"
mkdir -p "$WORKDIR"
cleanup() {
  local id
  docker_e ps -aq --filter "label=dev.dory.ssh-agent=$OWNER" 2>/dev/null \
    | while IFS= read -r id; do
        [ -n "$id" ] && docker_e rm -f "$id" >/dev/null 2>&1 || true
      done
  docker_e image rm -f "$BUILD_IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

container_keys() {
  docker_e run --rm --label "dev.dory.ssh-agent=$OWNER" \
    --entrypoint sh \
    -v /run/host-services/ssh-auth.sock:/agent.sock \
    -e SSH_AUTH_SOCK=/agent.sock "$IMAGE" -ec '
      command -v ssh-add >/dev/null
      test -S "$SSH_AUTH_SOCK"
      ssh-add -L
    ' | LC_ALL=C sort
}

single_keys="$(container_keys)"
[ -n "$single_keys" ] || die "container SSH agent returned no identities"
single_hash="$(printf '%s\n' "$single_keys" | shasum -a 256 | awk '{print $1}')"
[ "$single_hash" = "$host_hash" ] || die "container SSH agent identities differ from the host"

pids=""
for index in $(seq 1 "$CONCURRENCY"); do
  (
    keys="$(container_keys)"
    printf '%s\n' "$keys" | shasum -a 256 | awk '{print $1}' > "$WORKDIR/client-$index.sha256"
  ) > "$WORKDIR/client-$index.out" 2> "$WORKDIR/client-$index.err" &
  pids="$pids $!"
done
for pid in $pids; do wait "$pid" || die "a concurrent SSH-agent client failed"; done
for hash_file in "$WORKDIR"/client-*.sha256; do
  [ "$(cat "$hash_file")" = "$host_hash" ] \
    || die "a concurrent SSH-agent client observed different identities"
done
# Successful evidence retains only digests. Per-client stdout/stderr are useful on failure but are
# empty on success and are removed before the immutable qualification tree is hashed.
rm -f "$WORKDIR"/client-*.out "$WORKDIR"/client-*.err

# BuildKit's SSH session is a separate data path from an ordinary bind-mounted container socket.
# Prove the exact public identity listing reaches a required, network-disabled build mount. Only
# its digest is committed to the layer/evidence; neither public-key text nor private material is
# retained in the image or logs.
BUILD_CONTEXT="$WORKDIR/buildkit-context"
mkdir -p "$BUILD_CONTEXT"
cat > "$BUILD_CONTEXT/Dockerfile" <<EOF
FROM $IMAGE
RUN --network=none --mount=type=ssh,required=true \
    test -S "\$SSH_AUTH_SOCK" && \
    ssh-add -L | LC_ALL=C sort | sha256sum | awk '{print \$1}' > /dory-agent-listing.sha256
EOF
DOCKER_BUILDKIT=1 docker_e build --progress=plain \
  --ssh "default=$SSH_AUTH_SOCK" \
  --label "dev.dory.ssh-agent=$OWNER" \
  -t "$BUILD_IMAGE" "$BUILD_CONTEXT" \
  > "$WORKDIR/buildkit.out" 2> "$WORKDIR/buildkit.err" \
  || die "BuildKit required SSH mount failed"
buildkit_hash="$(docker_e run --rm --network none --label "dev.dory.ssh-agent=$OWNER" \
  --entrypoint cat "$BUILD_IMAGE" /dory-agent-listing.sha256 | tr -d '[:space:]')"
printf '%s\n' "$buildkit_hash" | grep -Eq '^[0-9a-f]{64}$' \
  || die "BuildKit SSH mount did not produce one identity-listing digest"
[ "$buildkit_hash" = "$host_hash" ] \
  || die "BuildKit SSH mount identities differ from the host"
rm -rf "$BUILD_CONTEXT"

{
  echo status=PASS
  echo "run_id=$RUN_ID"
  echo "guest_socket=/run/host-services/ssh-auth.sock"
  echo "concurrency=$CONCURRENCY"
  echo "public_key_listing_sha256=$host_hash"
  echo "buildkit_required_ssh_mount=PASS"
  echo "buildkit_public_key_listing_sha256=$buildkit_hash"
  echo "image=$IMAGE"
  echo "docker_sha256=$(shasum -a 256 "$DOCKER" | awk '{print $1}')"
  echo "completed_epoch=$(date +%s)"
} > "$WORKDIR/manifest.txt"
cleanup
trap - EXIT INT TERM
echo "ssh-agent forwarding gate PASS; evidence: $WORKDIR"
