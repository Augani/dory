#!/bin/bash
# Physical external-APFS bind-mount qualification. Requires a dedicated writable directory on a
# real external volume and refuses internal/System volumes or a non-empty Dory engine.
set -euo pipefail

SOCKET=""
DOCKER=""
DORY=""
EXTERNAL_ROOT=""
STATE_DIR=""
WORKROOT="${DORY_EXTERNAL_VOLUME_EVIDENCE_ROOT:-$HOME/.dory-external-volume-gate}"
IMAGE="${DORY_EXTERNAL_VOLUME_IMAGE:-alpine:latest}"
FD_BUDGET=8
CONFIRM=""
DISCONNECT_CONFIRM=""
DEDICATED_MARKER_NAME=".dory-release-external-volume"
DEDICATED_MARKER_VALUE="DORY-DEDICATED-RELEASE-APFS-V1"

usage() {
  cat <<EOF
Usage: scripts/external-volume-bind-gate.sh [required options]

Required:
  --socket PATH       Exact candidate Docker socket
  --docker PATH       Exact candidate Docker CLI
  --dory PATH         Exact candidate Dory CLI
  --state-dir PATH    Exact candidate runtime state directory
  --path PATH         Dedicated writable directory on an external APFS volume
  --image REF         Existing Alpine-compatible fixture image (default: $IMAGE)
  --confirm TOKEN     Must be ISOLATED-EXTERNAL-APFS-BIND
  --disconnect-confirm TOKEN
                      Must be DISCONNECT-RECONNECT-DEDICATED-APFS

Options:
  --workroot PATH     Evidence root (default: $WORKROOT)
  --fd-growth N       Aggregate Dory FD growth budget (default: $FD_BUDGET)
  --help              Show this help
EOF
}
die() { echo "external-volume-gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --dory) need_value "$1" "$#"; DORY="$2"; shift 2 ;;
    --state-dir) need_value "$1" "$#"; STATE_DIR="$2"; shift 2 ;;
    --path) need_value "$1" "$#"; EXTERNAL_ROOT="$2"; shift 2 ;;
    --image) need_value "$1" "$#"; IMAGE="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --fd-growth) need_value "$1" "$#"; FD_BUDGET="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    --disconnect-confirm) need_value "$1" "$#"; DISCONNECT_CONFIRM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ "$CONFIRM" = ISOLATED-EXTERNAL-APFS-BIND ] \
  || die "requires --confirm ISOLATED-EXTERNAL-APFS-BIND"
[ "$DISCONNECT_CONFIRM" = DISCONNECT-RECONNECT-DEDICATED-APFS ] \
  || die "requires --disconnect-confirm DISCONNECT-RECONNECT-DEDICATED-APFS"
[ "$(uname -s)" = Darwin ] || die "physical external-volume gate requires macOS"
[ -S "$SOCKET" ] || die "candidate socket is unavailable: $SOCKET"
[ -x "$DOCKER" ] || die "Docker CLI is not executable: $DOCKER"
[ -x "$DORY" ] || die "Dory CLI is not executable: $DORY"
[ -d "$STATE_DIR" ] || die "candidate state directory is unavailable: $STATE_DIR"
case "$FD_BUDGET" in ''|*[!0-9]*) die "--fd-growth must be a non-negative integer" ;; esac
for command in diskutil jq lsof mkfifo plutil ps python3 seq shasum stat; do
  command -v "$command" >/dev/null || die "missing required command: $command"
done

[ -d "$EXTERNAL_ROOT" ] || die "external test root is unavailable: $EXTERNAL_ROOT"
[ ! -L "$EXTERNAL_ROOT" ] || die "external test root must not be a symlink"
EXTERNAL_ROOT="$(cd "$EXTERNAL_ROOT" && pwd -P)"
case "$EXTERNAL_ROOT/" in /Volumes/*/*/) ;; *) die "test root must be below /Volumes/<external-name>: $EXTERNAL_ROOT" ;; esac
diskutil info -plist "$EXTERNAL_ROOT" > "${TMPDIR:-/tmp}/dory-external-disk-$$.plist"
disk_json="$(plutil -convert json -o - "${TMPDIR:-/tmp}/dory-external-disk-$$.plist")"
rm -f "${TMPDIR:-/tmp}/dory-external-disk-$$.plist"
mount_point="$(printf '%s' "$disk_json" | jq -r '.MountPoint // empty')"
device_identifier="$(printf '%s' "$disk_json" | jq -r '.DeviceIdentifier // empty')"
internal="$(printf '%s' "$disk_json" | jq -r '.Internal // true')"
filesystem="$(printf '%s' "$disk_json" | jq -r '.FilesystemType // .FilesystemName // empty' | tr '[:upper:]' '[:lower:]')"
[ -n "$mount_point" ] && [ -n "$device_identifier" ] \
  || die "external APFS device identity is incomplete"
[ "$internal" = false ] || die "test path is not on an external physical volume"
case "$filesystem" in *apfs*) ;; *) die "external test volume is not APFS (reported: $filesystem)" ;; esac
case "$EXTERNAL_ROOT/" in "$mount_point"/*/) ;; *) die "test root is outside reported mount point $mount_point" ;; esac
[ -w "$EXTERNAL_ROOT" ] || die "external test root is not writable"
dedicated_marker="$mount_point/$DEDICATED_MARKER_NAME"
[ -f "$dedicated_marker" ] && [ ! -L "$dedicated_marker" ] \
  || die "external volume lacks the operator-created dedicated-release marker: $dedicated_marker"
[ "$(cat "$dedicated_marker")" = "$DEDICATED_MARKER_VALUE" ] \
  || die "external volume marker does not authorize disconnect/reconnect qualification"

docker_e() { DOCKER_HOST="unix://$SOCKET" "$DOCKER" "$@"; }
docker_e version >/dev/null || die "candidate Docker API is unavailable"
docker_e image inspect "$IMAGE" >/dev/null 2>&1 \
  || die "required fixture image is unavailable: $IMAGE"
[ -z "$(docker_e ps -aq)" ] || die "gate requires zero pre-existing containers"
[ -z "$(docker_e volume ls -q)" ] || die "gate requires zero pre-existing named volumes"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
OWNER="dory-external-$RUN_ID"
HOST_DIR="$EXTERNAL_ROOT/$OWNER"
WORKDIR="$WORKROOT/$RUN_ID"
RESULTS="$WORKDIR/results.tsv"
VOLUME_UNMOUNTED=0
mkdir -p "$HOST_DIR" "$WORKDIR"
printf 'test\tstatus\tdetail\n' > "$RESULTS"
remove_owned_shadow_path() {
  local path
  [ ! -e "$mount_point/$DEDICATED_MARKER_NAME" ] || return 0
  rm -rf "$HOST_DIR"
  path="$EXTERNAL_ROOT"
  while [ "$path" != "$mount_point" ]; do
    rmdir "$path" 2>/dev/null || break
    path="$(dirname "$path")"
  done
  rmdir "$mount_point" 2>/dev/null || true
}
cleanup() {
  set +e
  docker_e ps -aq --filter "label=dev.dory.external=$OWNER" | while IFS= read -r id; do
    [ -n "$id" ] && docker_e rm -f -v "$id" >/dev/null 2>&1 || true
  done
  if [ "$VOLUME_UNMOUNTED" = 1 ] || [ ! -d "$mount_point" ]; then
    remove_owned_shadow_path
    diskutil mount "$device_identifier" >/dev/null 2>&1 || true
    for _ in $(seq 1 100); do [ -d "$mount_point" ] && break; sleep 0.1; done
    VOLUME_UNMOUNTED=0
  fi
  if [ -d "$mount_point" ] \
     && [ -f "$mount_point/$DEDICATED_MARKER_NAME" ] \
     && [ "$(cat "$mount_point/$DEDICATED_MARKER_NAME" 2>/dev/null)" = "$DEDICATED_MARKER_VALUE" ]; then
    rm -rf "$HOST_DIR"
  fi
}
trap cleanup EXIT INT TERM
pass() { printf '%s\tPASS\t%s\n' "$1" "$2" >> "$RESULTS"; }

sample_fds() {
  local output="$1" total=0 pid command count
  : > "$output"
  while read -r pid command; do
    [ -n "$pid" ] || continue
    case "$command" in
      *dory-hv*"$STATE_DIR"*|*gvproxy*"$STATE_DIR"*|*dory-dataplane-proxy*"$STATE_DIR"*) ;;
      *) continue ;;
    esac
    count="$(lsof -a -p "$pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
    printf '%s\t%s\t%s\n' "$pid" "$count" "$command" >> "$output"
    total=$((total + count))
  done < <(ps axww -o pid=,command=)
  [ "$total" -gt 0 ] || die "could not attribute any candidate engine file descriptors"
  printf '%s' "$total"
}

printf host-marker > "$HOST_DIR/host-marker"
docker_e run --rm --label "dev.dory.external=$OWNER" -v "$HOST_DIR:/external" "$IMAGE" \
  sh -ec 'test "$(cat /external/host-marker)" = host-marker; printf guest-marker > /external/guest-marker; ln /external/guest-marker /external/guest-hardlink; chmod 0400 /external/guest-marker; test "$(cat /external/guest-hardlink)" = guest-marker'
[ "$(cat "$HOST_DIR/guest-marker")" = guest-marker ] || die "guest write did not reach external APFS"
[ "$(stat -f '%l' "$HOST_DIR/guest-marker")" = 2 ] || die "external APFS hard link was not preserved"
pass ownership-hardlink "bidirectional bytes and restrictive hard-link alias passed on $mount_point"

mkfifo "$HOST_DIR/host-fifo"
set +e
python3 - "$SOCKET" "$DOCKER" "$HOST_DIR" "$OWNER" "$IMAGE" <<'PY'
import os, subprocess, sys
socket, docker, host, owner, image = sys.argv[1:]
try:
    result = subprocess.run(
        [docker, "-H", "unix://" + socket, "run", "--rm", "--label", "dev.dory.external=" + owner, "-v", host + ":/external", image, "dd", "if=/external/host-fifo", "of=/dev/null", "bs=1", "count=1"],
        timeout=5,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
except subprocess.TimeoutExpired:
    raise SystemExit(124)
raise SystemExit(result.returncode)
PY
fifo_rc=$?
set -e
[ "$fifo_rc" -ne 0 ] || die "external FIFO unexpectedly opened as a regular file"
[ "$fifo_rc" -ne 124 ] || die "external FIFO open exceeded five seconds"
docker_e version >/dev/null || die "Docker API wedged after external FIFO open"
rm -f "$HOST_DIR/host-fifo"
pass fifo-fail-fast "external FIFO rejected promptly; API remained live"

before="$(sample_fds "$WORKDIR/fds-before.tsv")"
docker_e run --rm --label "dev.dory.external=$OWNER" -v "$HOST_DIR:/external" "$IMAGE" sh -ec '
  i=0
  while [ "$i" -lt 10000 ]; do
    printf "%s" "$i" > /external/fd-churn
    dd if=/external/fd-churn of=/dev/null bs=32 count=1 2>/dev/null
    i=$((i + 1))
  done
  rm -f /external/fd-churn
'
sleep 2
after="$(sample_fds "$WORKDIR/fds-after.tsv")"
growth=$((after - before))
[ "$growth" -le "$FD_BUDGET" ] || die "external bind churn grew Dory FDs by $growth (budget $FD_BUDGET)"
pass fd-stability "operations=10000 before=$before after=$after growth=$growth"

python3 - "$HOST_DIR/large.bin" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
chunk = bytes(range(256)) * 4096
with path.open("wb") as handle:
    for _ in range(64):
        handle.write(chunk)
PY
host_sha="$(shasum -a 256 "$HOST_DIR/large.bin" | awk '{print $1}')"
guest_sha="$(docker_e run --rm --label "dev.dory.external=$OWNER" -v "$HOST_DIR:/external:ro" "$IMAGE" sha256sum /external/large.bin | awk '{print $1}')"
[ "$host_sha" = "$guest_sha" ] || die "64 MiB external bind checksum mismatch"
pass large-file "64 MiB sha256=$host_sha"

"$DORY" engine sleep >/dev/null
"$DORY" engine wake >/dev/null
for _ in $(seq 1 120); do docker_e version >/dev/null 2>&1 && break; sleep 1; done
docker_e run --rm --label "dev.dory.external=$OWNER" -v "$HOST_DIR:/external:ro" "$IMAGE" \
  sh -ec 'test "$(cat /external/guest-marker)" = guest-marker'
pass engine-restart "external bind and bytes survived candidate sleep/wake"

diskutil unmount "$device_identifier" > "$WORKDIR/diskutil-unmount.txt"
VOLUME_UNMOUNTED=1
for _ in $(seq 1 100); do [ ! -e "$mount_point" ] && break; sleep 0.1; done
[ ! -e "$mount_point" ] || die "external APFS mount point remained present after unmount"
set +e
python3 - "$SOCKET" "$DOCKER" "$HOST_DIR" "$OWNER" "$IMAGE" <<'PY'
import subprocess
import sys

socket, docker, host, owner, image = sys.argv[1:]
try:
    result = subprocess.run(
        [
            docker, "-H", "unix://" + socket,
            "run", "--rm", "--label", "dev.dory.external=" + owner,
            "-v", host + ":/external", image,
            "sh", "-ec", "printf forbidden-shadow-write > /external/should-not-exist",
        ],
        timeout=10,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
except subprocess.TimeoutExpired:
    raise SystemExit(124)
raise SystemExit(result.returncode)
PY
missing_rc=$?
set -e
[ "$missing_rc" -ne 0 ] || die "missing external volume unexpectedly accepted a bind write"
[ "$missing_rc" -ne 124 ] || die "missing external volume bind did not fail within ten seconds"
docker_e version >/dev/null || die "Docker API wedged after missing external-volume bind"
[ ! -e "$HOST_DIR" ] || die "missing external volume created an internal shadow path"
diskutil mount "$device_identifier" > "$WORKDIR/diskutil-mount.txt"
VOLUME_UNMOUNTED=0
for _ in $(seq 1 100); do
  [ -f "$dedicated_marker" ] && [ -d "$HOST_DIR" ] && break
  sleep 0.1
done
[ "$(cat "$dedicated_marker" 2>/dev/null || true)" = "$DEDICATED_MARKER_VALUE" ] \
  || die "dedicated external APFS volume did not remount with its identity marker"
[ "$(cat "$HOST_DIR/guest-marker" 2>/dev/null || true)" = guest-marker ] \
  || die "external APFS bytes were lost across unmount/remount"
[ "$(stat -f '%l' "$HOST_DIR/guest-marker")" = 2 ] \
  || die "external APFS hard link was lost across unmount/remount"
docker_e run --rm --label "dev.dory.external=$OWNER" -v "$HOST_DIR:/external:ro" "$IMAGE" \
  sh -ec 'test "$(cat /external/guest-marker)" = guest-marker; test "$(cat /external/guest-hardlink)" = guest-marker'
pass disconnect-reconnect "device=$device_identifier missing bind failed rc=$missing_rc; bytes and hard links survived remount"

{
  echo status=PASS
  echo "run_id=$RUN_ID"
  echo "mount_point=$mount_point"
  echo "filesystem=$filesystem"
  echo "internal=$internal"
  echo "device_identifier=$device_identifier"
  echo "image=$IMAGE"
  echo 'disconnect_reconnect=PASS'
  echo 'missing_drive_rejected=PASS'
  echo "docker_sha256=$(shasum -a 256 "$DOCKER" | awk '{print $1}')"
  echo "dory_sha256=$(shasum -a 256 "$DORY" | awk '{print $1}')"
  echo "completed_epoch=$(date +%s)"
} > "$WORKDIR/manifest.txt"
echo "external APFS bind gate PASS; evidence: $WORKDIR"
