#!/bin/bash
# Proves an existing 16 GiB ext4 Docker disk grows safely under the exact bundled runtime.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/data-disk-growth-gate.sh --runtime DIR --docker PATH [options]

Required:
  --runtime DIR       Exact runtime bundle containing dory-engine
  --docker PATH       Exact Docker CLI to use

Options:
  --image REF         Small Linux image used for guest df + persistence (default alpine:3.20)
  --workroot DIR      Evidence root (default /tmp/dory-data-disk-growth)
  --keep-runtime-home Preserve the isolated runtime HOME after completion
  --help              Show this help
EOF
}

RUNTIME=""
DOCKER=""
IMAGE="alpine:3.20"
WORKROOT="${TMPDIR:-/tmp}/dory-data-disk-growth"
KEEP_HOME=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --runtime) RUNTIME="${2:?--runtime requires a directory}"; shift 2 ;;
    --docker) DOCKER="${2:?--docker requires a path}"; shift 2 ;;
    --image) IMAGE="${2:?--image requires a reference}"; shift 2 ;;
    --workroot) WORKROOT="${2:?--workroot requires a directory}"; shift 2 ;;
    --keep-runtime-home) KEEP_HOME=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "data-disk growth gate: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

[ -n "$RUNTIME" ] || { echo "data-disk growth gate: --runtime is required" >&2; exit 64; }
[ -n "$DOCKER" ] || { echo "data-disk growth gate: --docker is required" >&2; exit 64; }
[ -x "$RUNTIME/dory-engine" ] || { echo "data-disk growth gate: runtime supervisor not executable: $RUNTIME/dory-engine" >&2; exit 66; }
[ -x "$DOCKER" ] || { echo "data-disk growth gate: Docker CLI not executable: $DOCKER" >&2; exit 66; }
command -v python3 >/dev/null || { echo "data-disk growth gate: python3 is required" >&2; exit 69; }

MKE2FS="${DORY_MKE2FS:-}"
if [ -z "$MKE2FS" ]; then
  for candidate in \
    /opt/homebrew/opt/e2fsprogs/sbin/mke2fs \
    /usr/local/opt/e2fsprogs/sbin/mke2fs \
    "$(command -v mke2fs 2>/dev/null || true)" \
    "$(command -v mkfs.ext4 2>/dev/null || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then MKE2FS="$candidate"; break; fi
  done
fi
[ -x "$MKE2FS" ] || { echo "data-disk growth gate: mke2fs is required" >&2; exit 69; }

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_ROOT="$WORKROOT/$RUN_ID"
RUNTIME_HOME="${DORY_DATA_DISK_RUNTIME_HOME:-$HOME/.ddg-$$}"
EVIDENCE="$RUN_ROOT/evidence"
STATE="$RUNTIME_HOME/.dory"
LEGACY_DISK="$STATE/hv/docker-data.ext4"
DATA_DRIVE="$RUNTIME_HOME/Library/Application Support/Dory/Dory.dorydrive"
DISK="$DATA_DRIVE/engine/docker-data.ext4"
SOCKET="$STATE/engine.sock"
NAME="dory-data-growth-${RUN_ID//[^a-zA-Z0-9]/}"
MARKER="persistent-$RUN_ID"
[ ! -e "$RUNTIME_HOME" ] || {
  echo "data-disk growth gate: isolated runtime HOME already exists: $RUNTIME_HOME" >&2
  exit 73
}
python3 - "$SOCKET" "$STATE/hv/docker-backend.sock" "$STATE/hv/gvproxy-api.sock" <<'PY'
import os
import sys

for path in sys.argv[1:]:
    length = len(os.fsencode(path))
    if length > 103:
        raise SystemExit(f"data-disk growth Unix socket path is {length} bytes (limit 103): {path}")
PY
mkdir -p "$STATE/hv" "$EVIDENCE"

capture_failure_evidence() {
  [ ! -f "$STATE/engine.log" ] || cp "$STATE/engine.log" "$EVIDENCE/engine.log"
  [ ! -d "$STATE/hv/guest-logs" ] || {
    mkdir -p "$EVIDENCE/guest-logs"
    cp -R "$STATE/hv/guest-logs/." "$EVIDENCE/guest-logs/"
  }
  if [ -f "$DISK" ]; then
    {
      stat -f 'logical_bytes=%z' "$DISK"
      stat -f 'allocated_blocks=%b' "$DISK"
      printf 'allocated_bytes=%s\n' "$(( $(stat -f '%b' "$DISK") * 512 ))"
    } >"$EVIDENCE/failure-disk-stat.txt"
  fi
  ps ax -o pid=,ppid=,state=,command= 2>/dev/null \
    | awk -v home="$RUNTIME_HOME" 'index($0, home) { print }' \
    >"$EVIDENCE/failure-runtime-processes.txt" || true
}

cleanup() {
  status=$?
  set +e
  [ "$status" -eq 0 ] || capture_failure_evidence
  if [ -S "$SOCKET" ]; then
    DOCKER_HOST="unix://$SOCKET" "$DOCKER" rm -f "$NAME" >/dev/null 2>&1 || true
    DOCKER_HOST="unix://$SOCKET" "$DOCKER" volume rm "$NAME" >/dev/null 2>&1 || true
  fi
  HOME="$RUNTIME_HOME" "$RUNTIME/dory-engine" stop >/dev/null 2>&1 || true
  if [ "$KEEP_HOME" -ne 1 ]; then rm -rf "$RUNTIME_HOME"; fi
  trap - EXIT INT TERM
  exit "$status"
}
trap cleanup EXIT INT TERM

# Preallocate the first GiB without changing the eventual 16 GiB legacy geometry. `nodiscard`
# deliberately leaves unused ext4 blocks physically allocated so the exact guest boot must issue
# virtio DISCARD/fstrim and return them to APFS. This reproduces old Docker images that stay large
# on the host after layers or volumes were deleted.
dd if=/dev/zero of="$LEGACY_DISK" bs=1m count=1024 >/dev/null 2>&1
truncate -s 16g "$LEGACY_DISK"
"$MKE2FS" -q -F -t ext4 -E nodiscard "$LEGACY_DISK"
BEFORE_LOGICAL="$(stat -f '%z' "$LEGACY_DISK")"
BEFORE_ALLOCATED="$(( $(stat -f '%b' "$LEGACY_DISK") * 512 ))"
MIN_SEED_ALLOCATED=$((768 * 1024 * 1024))
[ "$BEFORE_ALLOCATED" -ge "$MIN_SEED_ALLOCATED" ] || {
  echo "data-disk growth gate: discard-reclaim seed allocated only $BEFORE_ALLOCATED bytes" >&2
  exit 1
}

START_BEGIN="$(date +%s)"
HOME="$RUNTIME_HOME" "$RUNTIME/dory-engine" start --legacy-data-disk "$LEGACY_DISK" >"$EVIDENCE/start.log" 2>&1
START_SECONDS=$(( $(date +%s) - START_BEGIN ))
[ "$START_SECONDS" -le 60 ] || {
  echo "data-disk growth gate: resize/fstrim startup took $START_SECONDS seconds" >&2
  exit 1
}
[ -f "$DISK.migrated-from-legacy" ] || {
  echo "data-disk growth gate: managed drive did not record legacy adoption" >&2
  exit 1
}
TRIM_LOG="$STATE/hv/guest-logs/data-trim.log"
[ -s "$TRIM_LOG" ] || {
  echo "data-disk growth gate: guest did not publish boot-time fstrim evidence" >&2
  exit 1
}
cp "$TRIM_LOG" "$EVIDENCE/data-trim.log"
DOCKER_HOST="unix://$SOCKET" "$DOCKER" info >"$EVIDENCE/docker-info.txt"
DOCKER_HOST="unix://$SOCKET" "$DOCKER" image inspect "$IMAGE" >/dev/null 2>&1 \
  || DOCKER_HOST="unix://$SOCKET" "$DOCKER" pull "$IMAGE" >"$EVIDENCE/pull.log" 2>&1

GUEST_KIB="$(DOCKER_HOST="unix://$SOCKET" "$DOCKER" run --rm --privileged -v /:/host "$IMAGE" \
  sh -c "df -Pk /host/var/lib/docker | awk 'NR==2 {print \$2}'")"
case "$GUEST_KIB" in *[!0-9]*|'') echo "data-disk growth gate: unreadable guest capacity: $GUEST_KIB" >&2; exit 1 ;; esac
GUEST_BYTES="$((GUEST_KIB * 1024))"
case "$GUEST_BYTES" in *[!0-9]*|'') echo "data-disk growth gate: unreadable guest capacity: $GUEST_BYTES" >&2; exit 1 ;; esac
MIN_BYTES=$((120 * 1024 * 1024 * 1024))
[ "$GUEST_BYTES" -ge "$MIN_BYTES" ] || {
  echo "data-disk growth gate: guest ext4 capacity is $GUEST_BYTES, expected at least $MIN_BYTES" >&2
  exit 1
}

DOCKER_HOST="unix://$SOCKET" "$DOCKER" volume create "$NAME" >"$EVIDENCE/volume-create.txt"
DOCKER_HOST="unix://$SOCKET" "$DOCKER" run --name "$NAME" --rm -v "$NAME:/data" "$IMAGE" \
  sh -c "printf '%s' '$MARKER' > /data/marker"
HOME="$RUNTIME_HOME" "$RUNTIME/dory-engine" stop >"$EVIDENCE/stop.log" 2>&1
RESTART_BEGIN="$(date +%s)"
HOME="$RUNTIME_HOME" "$RUNTIME/dory-engine" start --legacy-data-disk "$LEGACY_DISK" >"$EVIDENCE/restart.log" 2>&1
RESTART_SECONDS=$(( $(date +%s) - RESTART_BEGIN ))
[ "$RESTART_SECONDS" -le 60 ] || {
  echo "data-disk growth gate: post-growth restart took $RESTART_SECONDS seconds" >&2
  exit 1
}
PERSISTED="$(DOCKER_HOST="unix://$SOCKET" "$DOCKER" run --name "$NAME" --rm -v "$NAME:/data" "$IMAGE" cat /data/marker)"
[ "$PERSISTED" = "$MARKER" ] || { echo "data-disk growth gate: named-volume marker changed after restart" >&2; exit 1; }

AFTER_LOGICAL="$(stat -f '%z' "$DISK")"
AFTER_ALLOCATED="$(( $(stat -f '%b' "$DISK") * 512 ))"
MIN_LOGICAL=$((128 * 1024 * 1024 * 1024))
[ "$AFTER_LOGICAL" -ge "$MIN_LOGICAL" ] || {
  echo "data-disk growth gate: host disk stayed at $AFTER_LOGICAL bytes, expected at least $MIN_LOGICAL" >&2
  exit 1
}
[ "$AFTER_ALLOCATED" -lt "$AFTER_LOGICAL" ] || {
  echo "data-disk growth gate: sparse growth eagerly allocated $AFTER_ALLOCATED of $AFTER_LOGICAL bytes" >&2
  exit 1
}
[ "$AFTER_ALLOCATED" -lt "$BEFORE_ALLOCATED" ] || {
  echo "data-disk growth gate: boot-time fstrim did not reclaim the preallocated seed ($BEFORE_ALLOCATED -> $AFTER_ALLOCATED)" >&2
  exit 1
}
cat >"$EVIDENCE/summary.txt" <<EOF
status=PASS
runtime=$RUNTIME
image=$IMAGE
start_seconds=$START_SECONDS
restart_seconds=$RESTART_SECONDS
seed_logical_bytes=$BEFORE_LOGICAL
seed_allocated_bytes=$BEFORE_ALLOCATED
grown_logical_bytes=$AFTER_LOGICAL
grown_allocated_bytes=$AFTER_ALLOCATED
minimum_logical_bytes=$MIN_LOGICAL
sparse_allocation=PASS
discard_reclaim=PASS
boot_trim_evidence=PASS
guest_ext4_bytes=$GUEST_BYTES
minimum_guest_bytes=$MIN_BYTES
named_volume_restart_persistence=PASS
EOF
echo "data-disk growth gate: PASS ($EVIDENCE/summary.txt)"
