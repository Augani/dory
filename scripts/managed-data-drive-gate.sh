#!/bin/bash
# Proves that a fresh managed .dorydrive preserves every durable Docker object even when all
# transient runtime state is replaced. Runs only against isolated disposable paths.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/managed-data-drive-gate.sh --runtime DIR --docker PATH [options]

Required:
  --runtime DIR       Exact standalone runtime bundle containing dory-engine
  --docker PATH       Exact Docker CLI to use

Options:
  --image REF         Small image used for persistence checks (default alpine:3.20)
  --workroot DIR      Evidence root (default /tmp/dory-managed-drive-evidence)
  --keep-workload     Preserve the disposable runtime HOME and data drive
  --help              Show this help
EOF
}

RUNTIME=""
DOCKER=""
IMAGE="alpine:3.20"
WORKROOT="${TMPDIR:-/tmp}/dory-managed-drive-evidence"
KEEP=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --runtime) RUNTIME="${2:?--runtime requires a directory}"; shift 2 ;;
    --docker) DOCKER="${2:?--docker requires a path}"; shift 2 ;;
    --image) IMAGE="${2:?--image requires a reference}"; shift 2 ;;
    --workroot) WORKROOT="${2:?--workroot requires a directory}"; shift 2 ;;
    --keep-workload) KEEP=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "managed data-drive gate: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

[ "$(uname -m)" = arm64 ] || { echo "managed data-drive gate: physical Apple silicon is required" >&2; exit 69; }
[ -x "$RUNTIME/dory-engine" ] || { echo "managed data-drive gate: runtime launcher is missing" >&2; exit 66; }
[ -x "$RUNTIME/bin/dory-hv" ] || { echo "managed data-drive gate: dory-hv is missing" >&2; exit 66; }
[ -x "$DOCKER" ] || { echo "managed data-drive gate: Docker CLI is missing" >&2; exit 66; }

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_ROOT="$WORKROOT/$RUN_ID"
EVIDENCE="$RUN_ROOT/evidence"
RUNTIME_HOME="${DORY_MANAGED_DRIVE_RUNTIME_HOME:-${TMPDIR:-/tmp}}"
if [ -z "${DORY_MANAGED_DRIVE_RUNTIME_HOME:-}" ]; then
  RUNTIME_HOME="${RUNTIME_HOME%/}/dory-md-$PPID-$$"
fi
STATE="$RUNTIME_HOME/.dory"
FIRST_STATE="$RUNTIME_HOME/.dory-first-runtime"
DRIVE="$RUNTIME_HOME/Library/Application Support/Dory/Dory.dorydrive"
SELECTION_RECORD="$RUNTIME_HOME/Library/Application Support/Dory/data-drive-selection.json"
SOCKET="$STATE/engine.sock"
ENGINE_PIDFILE="$STATE/engine-cli.pid"
DATAPLANE_PIDFILE="$STATE/dataplane-cli.pid"
NAME="dory-drive-${RUN_ID//[^a-zA-Z0-9]/}"
VOLUME="$NAME-volume"
NETWORK="$NAME-network"
MARKER="marker-$RUN_ID"
OTHER_DRIVE="$RUNTIME_HOME/Library/Application Support/Dory/Other.dorydrive"
ALIAS_HOME="${TMPDIR:-/tmp}/dory-md-alias-$PPID-$$"

[ ! -e "$RUNTIME_HOME" ] || { echo "managed data-drive gate: isolated HOME exists: $RUNTIME_HOME" >&2; exit 73; }
mkdir -p "$RUNTIME_HOME" "$EVIDENCE"
python3 - "$SOCKET" "$STATE/hv/docker-backend.sock" <<'PY'
import os, sys
for path in sys.argv[1:]:
    if len(os.fsencode(path)) > 103:
        raise SystemExit(f"managed data-drive socket path exceeds 103 bytes: {path}")
PY

cleanup() {
  status=$?
  set +e
  if [ -S "$SOCKET" ]; then
    DOCKER_HOST="unix://$SOCKET" "$DOCKER" rm -f "$NAME" >/dev/null 2>&1 || true
    DOCKER_HOST="unix://$SOCKET" "$DOCKER" volume rm "$VOLUME" >/dev/null 2>&1 || true
    DOCKER_HOST="unix://$SOCKET" "$DOCKER" network rm "$NETWORK" >/dev/null 2>&1 || true
  fi
  HOME="$RUNTIME_HOME" "$RUNTIME/dory-engine" stop >/dev/null 2>&1 || true
  rm -f "$ALIAS_HOME"
  if [ "$status" -ne 0 ]; then
    [ ! -f "$STATE/engine.log" ] || cp "$STATE/engine.log" "$EVIDENCE/failure-engine.log"
    [ ! -f "$FIRST_STATE/engine.log" ] || cp "$FIRST_STATE/engine.log" "$EVIDENCE/failure-first-engine.log"
  fi
  if [ "$KEEP" -ne 1 ]; then rm -rf "$RUNTIME_HOME"; fi
  trap - EXIT INT TERM
  exit "$status"
}
trap cleanup EXIT INT TERM

HOME="$RUNTIME_HOME" "$RUNTIME/dory-engine" start --data-drive "$DRIVE" \
  >"$EVIDENCE/first-start.log" 2>&1
[ -f "$DRIVE/drive.json" ] || { echo "managed data-drive gate: manifest missing" >&2; exit 1; }
for directory in engine kubernetes machines snapshots exports operations; do
  [ -d "$DRIVE/$directory" ] \
    || { echo "managed data-drive gate: durable directory missing: $directory" >&2; exit 1; }
done
[ -s "$STATE/data-drive.id" ] \
  || { echo "managed data-drive gate: drive UUID ownership record missing" >&2; exit 1; }
[ -s "$SELECTION_RECORD" ] \
  || { echo "managed data-drive gate: durable selected-drive record missing" >&2; exit 1; }
selection_hash_before="$(shasum -a 256 "$SELECTION_RECORD" | awk '{print $1}')"
cp "$SELECTION_RECORD" "$EVIDENCE/selection-before-runtime-reset.json"
[ ! -e "$DRIVE/engine/docker-data.ext4.partial" ] \
  || { echo "managed data-drive gate: first-launch disk transaction was not finalized" >&2; exit 1; }
HOME="$RUNTIME_HOME" "$RUNTIME/dory-engine" status >"$EVIDENCE/first-status.log"
grep -F "data drive: $DRIVE" "$EVIDENCE/first-status.log" >/dev/null \
  || { echo "managed data-drive gate: status lost the selected drive" >&2; exit 1; }

# Rebuild lost launcher metadata only when the actual live dory-hv command is bound to the exact
# requested drive. This reproduces an interrupted metadata flush without interrupting the VM.
original_engine_pid="$(cat "$ENGINE_PIDFILE")"
original_dataplane_pid="$(cat "$DATAPLANE_PIDFILE")"
rm -f "$STATE/data-drive.path"
HOME="$RUNTIME_HOME" "$RUNTIME/dory-engine" start --data-drive "$DRIVE" \
  >"$EVIDENCE/lost-identity-same-drive.log" 2>&1
grep -F "already running (pid $original_engine_pid)" "$EVIDENCE/lost-identity-same-drive.log" >/dev/null
[ "$(cat "$STATE/data-drive.path")" = "$DRIVE" ] \
  || { echo "managed data-drive gate: exact live drive identity was not restored" >&2; exit 1; }
[ "$(cat "$ENGINE_PIDFILE")" = "$original_engine_pid" ]
[ "$(cat "$DATAPLANE_PIDFILE")" = "$original_dataplane_pid" ]

rm -f "$STATE/data-drive.path"
if HOME="$RUNTIME_HOME" "$RUNTIME/dory-engine" start --data-drive "$OTHER_DRIVE" \
    >"$EVIDENCE/lost-identity-mismatch.out" 2>"$EVIDENCE/lost-identity-mismatch.err"; then
  echo "managed data-drive gate: missing metadata silently adopted a different drive" >&2
  exit 1
fi
grep -F 'running engine data drive does not match requested' \
  "$EVIDENCE/lost-identity-mismatch.err" >/dev/null
[ ! -e "$OTHER_DRIVE" ] \
  || { echo "managed data-drive gate: rejected alternate drive was modified" >&2; exit 1; }
[ ! -e "$STATE/data-drive.path" ] \
  || { echo "managed data-drive gate: mismatched live identity was recorded" >&2; exit 1; }
[ "$(cat "$ENGINE_PIDFILE")" = "$original_engine_pid" ]
[ "$(cat "$DATAPLANE_PIDFILE")" = "$original_dataplane_pid" ]
curl -sf --max-time 2 --unix-socket "$SOCKET" http://d/_ping \
  >"$EVIDENCE/lost-identity-mismatch-api.txt"
HOME="$RUNTIME_HOME" "$RUNTIME/dory-engine" start --data-drive "$DRIVE" \
  >"$EVIDENCE/lost-identity-repair.log" 2>&1
[ "$(cat "$STATE/data-drive.path")" = "$DRIVE" ]

if HOME="$RUNTIME_HOME" "$RUNTIME/dory-engine" start \
    --data-drive "$OTHER_DRIVE" \
    >"$EVIDENCE/drive-mismatch.out" 2>"$EVIDENCE/drive-mismatch.err"; then
  echo "managed data-drive gate: running engine accepted a different drive" >&2
  exit 1
fi
grep -F 'already running with data drive' "$EVIDENCE/drive-mismatch.err" >/dev/null
[ ! -e "$OTHER_DRIVE" ] \
  || { echo "managed data-drive gate: rejected alternate drive was modified" >&2; exit 1; }

READ_ONLY_PARENT="$RUNTIME_HOME/Library/Application Support/Dory/ReadOnly"
UNWRITABLE_DRIVE="$READ_ONLY_PARENT/Blocked.dorydrive"
mkdir -p "$READ_ONLY_PARENT"
chmod 0500 "$READ_ONLY_PARENT"
set +e
HOME="$RUNTIME_HOME" "$RUNTIME/bin/dory-hv" engine --data-drive "$UNWRITABLE_DRIVE" \
  >"$EVIDENCE/unwritable-drive.out" 2>"$EVIDENCE/unwritable-drive.err"
unwritable_rc=$?
set -e
chmod 0700 "$READ_ONLY_PARENT"
[ "$unwritable_rc" -eq 1 ] \
  || { echo "managed data-drive gate: unwritable drive did not fail cleanly (rc=$unwritable_rc)" >&2; exit 1; }
grep -F 'invalid Dory data drive: prepare Dory data drive' \
  "$EVIDENCE/unwritable-drive.err" >/dev/null
[ ! -e "$UNWRITABLE_DRIVE" ] \
  || { echo "managed data-drive gate: unwritable drive left a partial bundle" >&2; exit 1; }
curl -sf --max-time 2 --unix-socket "$SOCKET" http://d/_ping \
  >"$EVIDENCE/unwritable-drive-api.txt"

MISSING="/Volumes/DoryMissing-$PPID-$$/Dory.dorydrive"
if HOME="$RUNTIME_HOME" "$RUNTIME/bin/dory-hv" engine --data-drive "$MISSING" \
    >"$EVIDENCE/missing-volume.out" 2>"$EVIDENCE/missing-volume.err"; then
  echo "managed data-drive gate: missing external volume was accepted" >&2
  exit 1
fi
grep -F 'data drive volume is not mounted' "$EVIDENCE/missing-volume.err" >/dev/null

ln -s "$RUNTIME_HOME" "$ALIAS_HOME"
ALIAS_DRIVE="$ALIAS_HOME/Library/Application Support/Dory/Dory.dorydrive"
if HOME="$RUNTIME_HOME" "$RUNTIME/bin/dory-hv" engine \
    --state-dir "$RUNTIME_HOME/second-state" --data-drive "$ALIAS_DRIVE" \
    --kernel "$STATE/vm/dory-hv-kernel-arm64" --gvproxy "$RUNTIME/bin/gvproxy" \
    --rootfs "$STATE/vm/dory-engine-rootfs.ext4" --engine-sock "$RUNTIME_HOME/second.sock" \
    >"$EVIDENCE/second-attach.out" 2>"$EVIDENCE/second-attach.err"; then
  echo "managed data-drive gate: a second engine attached the live drive" >&2
  exit 1
fi
grep -E 'lock|locked|in use' "$EVIDENCE/second-attach.err" >/dev/null

export DOCKER_HOST="unix://$SOCKET"
"$DOCKER" image inspect "$IMAGE" >/dev/null 2>&1 \
  || "$DOCKER" pull "$IMAGE" >"$EVIDENCE/pull.log" 2>&1
"$DOCKER" volume create "$VOLUME" >"$EVIDENCE/volume-create.txt"
"$DOCKER" network create "$NETWORK" >"$EVIDENCE/network-create.txt"
"$DOCKER" run -d --name "$NAME" --network "$NETWORK" -v "$VOLUME:/proof" "$IMAGE" \
  sh -c "printf '%s' '$MARKER-volume' > /proof/marker; printf '%s' '$MARKER-layer' > /layer-marker; sleep 86400" \
  >"$EVIDENCE/container-create.txt"
[ "$("$DOCKER" exec "$NAME" cat /proof/marker)" = "$MARKER-volume" ]
[ "$("$DOCKER" exec "$NAME" cat /layer-marker)" = "$MARKER-layer" ]
"$DOCKER" stop "$NAME" >"$EVIDENCE/container-stop.txt"
"$DOCKER" image inspect "$IMAGE" >"$EVIDENCE/image-before.json"
"$DOCKER" container inspect "$NAME" >"$EVIDENCE/container-before.json"
"$DOCKER" volume inspect "$VOLUME" >"$EVIDENCE/volume-before.json"
"$DOCKER" network inspect "$NETWORK" >"$EVIDENCE/network-before.json"

HOME="$RUNTIME_HOME" "$RUNTIME/dory-engine" stop >"$EVIDENCE/first-stop.log" 2>&1
cp "$STATE/engine.log" "$EVIDENCE/first-engine.log"
mv "$STATE" "$FIRST_STATE"
[ -s "$SELECTION_RECORD" ] \
  || { echo "managed data-drive gate: replacing runtime state removed the drive selection" >&2; exit 1; }

HOME="$RUNTIME_HOME" "$RUNTIME/dory-engine" start \
  >"$EVIDENCE/restart-with-fresh-runtime.log" 2>&1
[ "$(shasum -a 256 "$SELECTION_RECORD" | awk '{print $1}')" = "$selection_hash_before" ] \
  || { echo "managed data-drive gate: runtime reset changed stable selected-drive authority" >&2; exit 1; }
HOME="$RUNTIME_HOME" "$RUNTIME/dory-engine" status >"$EVIDENCE/status-after-runtime-reset.log"
grep -F "data drive: $DRIVE" "$EVIDENCE/status-after-runtime-reset.log" >/dev/null \
  || { echo "managed data-drive gate: fresh runtime did not recover its durable drive" >&2; exit 1; }
export DOCKER_HOST="unix://$STATE/engine.sock"
"$DOCKER" image inspect "$IMAGE" >"$EVIDENCE/image-after.json"
"$DOCKER" container inspect "$NAME" >"$EVIDENCE/container-after.json"
"$DOCKER" volume inspect "$VOLUME" >"$EVIDENCE/volume-after.json"
"$DOCKER" network inspect "$NETWORK" >"$EVIDENCE/network-after.json"
"$DOCKER" start "$NAME" >"$EVIDENCE/container-restart.txt"
[ "$("$DOCKER" exec "$NAME" cat /proof/marker)" = "$MARKER-volume" ]
[ "$("$DOCKER" exec "$NAME" cat /layer-marker)" = "$MARKER-layer" ]
[ "$("$DOCKER" inspect -f '{{range .NetworkSettings.Networks}}{{.NetworkID}}{{end}}' "$NAME")" = \
  "$("$DOCKER" network inspect -f '{{.Id}}' "$NETWORK")" ]

"$DOCKER" rm -f "$NAME" >/dev/null
"$DOCKER" volume rm "$VOLUME" >/dev/null
"$DOCKER" network rm "$NETWORK" >/dev/null
HOME="$RUNTIME_HOME" "$RUNTIME/dory-engine" stop >"$EVIDENCE/final-stop.log" 2>&1
cp "$STATE/engine.log" "$EVIDENCE/final-engine.log"
cp "$DRIVE/drive.json" "$EVIDENCE/drive.json"

# A detached, renamed, or replaced selected drive must never turn into a fresh empty store at the
# remembered path. Keep the original as rollback while proving the stopped launcher fails closed.
PARKED_DRIVE="$DRIVE.parked"
mv "$DRIVE" "$PARKED_DRIVE"
if HOME="$RUNTIME_HOME" "$RUNTIME/dory-engine" start --data-drive "$DRIVE" \
    >"$EVIDENCE/stopped-missing-drive.out" 2>"$EVIDENCE/stopped-missing-drive.err"; then
  echo "managed data-drive gate: stopped runtime silently created a replacement selected drive" >&2
  exit 1
fi
grep -F 'refusing to create a replacement' "$EVIDENCE/stopped-missing-drive.err" >/dev/null
[ ! -e "$DRIVE" ] \
  || { echo "managed data-drive gate: missing selected drive left a shadow replacement" >&2; exit 1; }
mv "$PARKED_DRIVE" "$DRIVE"

python3 - "$EVIDENCE/drive.json" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
import datetime, uuid
assert data["kind"] == "dev.dory.data-drive"
assert data["schemaVersion"] == 1
assert data["product"] == "Dory"
uuid.UUID(data["id"])
assert datetime.datetime.fromisoformat(data["createdAt"].replace("Z", "+00:00")).tzinfo
PY

{
  printf 'status=PASS\n'
  printf 'architecture=arm64\n'
  printf 'fresh_drive_default=PASS\n'
  printf 'explicit_drive_status=PASS\n'
  printf 'running_drive_mismatch_rejected=PASS\n'
  printf 'lost_drive_identity_recovered=PASS\n'
  printf 'lost_drive_identity_mismatch_rejected=PASS\n'
  printf 'alternate_drive_untouched=PASS\n'
  printf 'unwritable_drive_rejected_cleanly=PASS\n'
  printf 'missing_external_drive_rejected=PASS\n'
  printf 'concurrent_attach_rejected=PASS\n'
  printf 'alias_concurrent_attach_rejected=PASS\n'
  printf 'manifest_uuid_identity=PASS\n'
  printf 'stopped_missing_selected_drive_rejected=PASS\n'
  printf 'image_persistence=PASS\n'
  printf 'container_writable_layer_persistence=PASS\n'
  printf 'named_volume_persistence=PASS\n'
  printf 'custom_network_persistence=PASS\n'
  printf 'transient_runtime_replacement=PASS\n'
  printf 'durable_selection_survives_runtime_reset=PASS\n'
  stat -f 'drive_logical_bytes=%z' "$DRIVE/engine/docker-data.ext4"
  printf 'drive_allocated_bytes=%s\n' "$(( $(stat -f '%b' "$DRIVE/engine/docker-data.ext4") * 512 ))"
} >"$EVIDENCE/summary.txt"

echo "managed data-drive gate: PASS ($EVIDENCE/summary.txt)"
