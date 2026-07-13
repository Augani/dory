#!/bin/bash
# Focused reproduction for stale bind-file size/content metadata (Docker Desktop #7501).
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOCKET="${DORY_SOCK:-$HOME/.dory/dory.sock}"
DOCKER="${DORY_DOCKER_BIN:-$(command -v docker 2>/dev/null || true)}"
IMAGE="${DORY_BIND_COHERENCE_IMAGE:-alpine:latest}"
WORKROOT="${DORY_BIND_COHERENCE_WORKROOT:-$HOME/.dory-bind-coherence}"

usage() {
  cat <<'EOF'
Usage: scripts/bind-file-coherence-gate.sh [options]

Options:
  --socket PATH      Docker-compatible Dory socket (default: ~/.dory/dory.sock)
  --docker PATH      Docker CLI
  --image REF        Already-local probe image (default: alpine:latest)
  --workroot PATH    Evidence root inside Dory's shared home (default: ~/.dory-bind-coherence)
  -h, --help

The gate uses uniquely named/labeled containers with --pull=never and a fresh host directory whose
path contains spaces. It proves direct single-file bind reliability, same-inode shrink/grow/content
refresh, atomic replacement, and guest-to-host truncation.
EOF
}

die() { echo "bind-file-coherence: $*" >&2; exit 1; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --image) need_value "$1" "$#"; IMAGE="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option $1" ;;
  esac
done

[ -x "$DOCKER" ] || die "Docker CLI is unavailable"
case "$SOCKET" in /*) ;; *) die "socket must be absolute" ;; esac
case "$WORKROOT" in /*) ;; *) die "workroot must be absolute" ;; esac
[ -S "$SOCKET" ] || die "socket is unavailable: $SOCKET"
"$DOCKER" -H "unix://$SOCKET" version >/dev/null 2>&1 || die "Docker API is unreachable"
"$DOCKER" -H "unix://$SOCKET" image inspect "$IMAGE" >/dev/null 2>&1 \
  || die "probe image must already be local: $IMAGE"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_DIR="$WORKROOT/$RUN_ID"
SHARE="$RUN_DIR/path with spaces"
RESULTS="$RUN_DIR/results.tsv"
NAME="dory-bind-coherence-$(printf '%s' "$RUN_ID" | tr -cd '[:alnum:]')"
LABEL="dev.dory.bind-coherence=$RUN_ID"
mkdir -p "$SHARE"
printf 'phase\thost_inode\thost_size\tguest_directory_size\tguest_direct_size\thost_sha256\tguest_directory_sha256\tguest_direct_sha256\n' > "$RESULTS"

docker_e() { "$DOCKER" -H "unix://$SOCKET" "$@"; }
cleanup() {
  local owned
  owned="$(docker_e ps -aq --filter "label=$LABEL" 2>/dev/null || true)"
  [ -z "$owned" ] || docker_e rm -f $owned >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

FILE="$SHARE/value.bin"
dd if=/dev/zero of="$FILE" bs=4096 count=1 2>/dev/null
printf 'initial-marker\n' | dd of="$FILE" conv=notrunc 2>/dev/null
start_primary_container() {
  docker_e run -d --pull never --network none --name "$NAME" --label "$LABEL" \
    -v "$SHARE:/work" -v "$FILE:/single/value.bin" \
    "$IMAGE" sh -c 'exec tail -f /dev/null' >/dev/null
}
start_primary_container

host_inode() { stat -f%i "$FILE"; }
host_size() { stat -f%z "$FILE"; }
host_sha() { shasum -a 256 "$FILE" | awk '{print $1}'; }
guest_size() { docker_e exec "$NAME" stat -c %s /work/value.bin 2>/dev/null | tr -d '\r'; }
guest_sha() { docker_e exec "$NAME" sha256sum /work/value.bin 2>/dev/null | awk '{print $1}'; }
guest_direct_size() { docker_e exec "$NAME" stat -c %s /single/value.bin 2>/dev/null | tr -d '\r'; }
guest_direct_sha() { docker_e exec "$NAME" sha256sum /single/value.bin 2>/dev/null | awk '{print $1}'; }

wait_guest_state() {
  local expected_size="$1" expected_sha="$2" expected_direct_size="$3" expected_direct_sha="$4"
  local deadline=$(( $(date +%s) + 15 )) size sha direct_size direct_sha
  while [ "$(date +%s)" -lt "$deadline" ]; do
    size="$(guest_size || true)"; sha="$(guest_sha || true)"
    direct_size="$(guest_direct_size || true)"; direct_sha="$(guest_direct_sha || true)"
    [ "$size" = "$expected_size" ] && [ "$sha" = "$expected_sha" ] \
      && [ "$direct_size" = "$expected_direct_size" ] && [ "$direct_sha" = "$expected_direct_sha" ] \
      && return 0
    sleep 1
  done
  die "guest retained stale metadata/content: expected size=$expected_size sha=$expected_sha, directory=${size:-unavailable}/${sha:-unavailable}, direct=${direct_size:-unavailable}/${direct_sha:-unavailable}"
}

record_phase() {
  local phase="$1" hs hsha gs gsha direct_size direct_sha expected_direct_size expected_direct_sha
  hs="$(host_size)"; hsha="$(host_sha)"
  expected_direct_size="${2:-$hs}"; expected_direct_sha="${3:-$hsha}"
  wait_guest_state "$hs" "$hsha" "$expected_direct_size" "$expected_direct_sha"
  gs="$(guest_size)"; gsha="$(guest_sha)"
  direct_size="$(guest_direct_size)"; direct_sha="$(guest_direct_sha)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$phase" "$(host_inode)" "$hs" "$gs" "$direct_size" "$hsha" "$gsha" "$direct_sha" \
    >> "$RESULTS"
}

initial_inode="$(host_inode)"
record_phase initial

printf 'shrunk\n' > "$FILE"
[ "$(host_inode)" = "$initial_inode" ] || die "shrink unexpectedly replaced the host inode"
record_phase same-inode-shrink

dd if=/dev/zero of="$FILE" bs=131073 count=1 2>/dev/null
printf 'grown-marker\n' | dd of="$FILE" conv=notrunc 2>/dev/null
[ "$(host_inode)" = "$initial_inode" ] || die "grow unexpectedly replaced the host inode"
record_phase same-inode-grow

printf 'same-size-new-content' | dd of="$FILE" bs=21 count=1 conv=notrunc 2>/dev/null
[ "$(host_inode)" = "$initial_inode" ] || die "content write unexpectedly replaced the host inode"
record_phase same-inode-content

direct_size_before_replace="$(guest_direct_size)"
direct_sha_before_replace="$(guest_direct_sha)"
printf 'atomic-replacement-with-a-distinct-size\n' > "$FILE.replacement"
mv "$FILE.replacement" "$FILE"
[ "$(host_inode)" != "$initial_inode" ] || die "atomic replacement reused the old host inode"
# Native Linux direct file binds pin the source inode: the directory view follows an atomic path
# replacement, while the direct view intentionally remains on the old inode until reattached.
record_phase atomic-replacement-pinned-direct \
  "$direct_size_before_replace" "$direct_sha_before_replace"
docker_e rm -f "$NAME" >/dev/null
start_primary_container
record_phase direct-rebind-after-replacement

docker_e exec "$NAME" sh -c "printf xyz > /single/value.bin"
[ "$(host_size)" = 3 ] || die "guest truncation was not visible on the host"
[ "$(host_sha)" = "$(printf xyz | shasum -a 256 | awk '{print $1}')" ] \
  || die "guest write content was not visible on the host"
record_phase guest-truncate

docker_e rm -f "$NAME" >/dev/null
DIRECT_CYCLES=20
for cycle in $(seq 1 "$DIRECT_CYCLES"); do
  docker_e run --rm --pull never --network none \
    --name "$NAME-direct-$cycle" --label "$LABEL" \
    -v "$FILE:/single/value.bin" "$IMAGE" \
    sh -c '[ "$(cat /single/value.bin)" = xyz ]' >/dev/null
done
[ "$(host_sha)" = "$(printf xyz | shasum -a 256 | awk '{print $1}')" ] \
  || die "repeated direct file mounts changed the host file"

{
  printf 'status=PASS\n'
  printf 'path_with_spaces=PASS\n'
  printf 'directory_bind=PASS\n'
  printf 'direct_single_file_bind=PASS\n'
  printf 'direct_single_file_recreate_cycles=%s\n' "$DIRECT_CYCLES"
  printf 'same_inode_shrink=PASS\n'
  printf 'same_inode_grow=PASS\n'
  printf 'same_inode_content_refresh=PASS\n'
  printf 'atomic_replacement=PASS\n'
  printf 'direct_atomic_replacement_pins_inode=PASS\n'
  printf 'direct_rebind_follows_replacement=PASS\n'
  printf 'guest_to_host_truncation=PASS\n'
  printf 'image=%s\n' "$IMAGE"
  printf 'docker_cli_sha256=%s\n' "$(shasum -a 256 "$DOCKER" | awk '{print $1}')"
  printf 'results_sha256=%s\n' "$(shasum -a 256 "$RESULTS" | awk '{print $1}')"
} > "$RUN_DIR/manifest.txt"
trap - EXIT INT TERM
printf 'bind-file coherence gate PASS; evidence: %s\n' "$RUN_DIR"
