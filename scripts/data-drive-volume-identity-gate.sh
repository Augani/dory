#!/bin/bash
# Proves that the exact dory-hv binds an external .dorydrive to its APFS volume UUID, not merely
# the reusable /Volumes/<name> path. Uses two disposable sparse APFS images with the same name.
set -euo pipefail
umask 077

usage() {
  echo "Usage: $0 --dory-hv PATH [--workroot DIR]" >&2
}

DORY_HV=""
WORKROOT="${TMPDIR:-/tmp}/dory-volume-identity-evidence"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dory-hv) DORY_HV="${2:?--dory-hv requires a path}"; shift 2 ;;
    --workroot) WORKROOT="${2:?--workroot requires a directory}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "data-drive volume identity gate: unknown argument: $1" >&2; usage; exit 64 ;;
  esac
done

[ "$(uname -m)" = arm64 ] \
  || { echo "data-drive volume identity gate: physical Apple silicon is required" >&2; exit 69; }
[ -x "$DORY_HV" ] \
  || { echo "data-drive volume identity gate: dory-hv is missing" >&2; exit 66; }
command -v hdiutil >/dev/null \
  || { echo "data-drive volume identity gate: hdiutil is missing" >&2; exit 69; }

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_ROOT="$WORKROOT/$RUN_ID"
EVIDENCE="$RUN_ROOT/evidence"
TEST_HOME="$RUN_ROOT/home"
FIRST_IMAGE="$RUN_ROOT/first.dmg"
SECOND_IMAGE="$RUN_ROOT/second.dmg"
COPIED_DRIVE="$RUN_ROOT/copied.dorydrive"
VOLUME_NAME="DoryIdentity-$PPID-$$"
RENAMED_VOLUME_NAME="DoryRenamed-$PPID-$$"
MOUNT="/Volumes/$VOLUME_NAME"
RENAMED_MOUNT="/Volumes/$RENAMED_VOLUME_NAME"
DRIVE="$MOUNT/Dory.dorydrive"
RENAMED_DRIVE="$RENAMED_MOUNT/Dory.dorydrive"
SELECTION_RECORD="$TEST_HOME/Library/Application Support/Dory/data-drive-selection.json"

[ ! -e "$RUN_ROOT" ] \
  || { echo "data-drive volume identity gate: run directory already exists" >&2; exit 73; }
mkdir -p "$EVIDENCE" "$TEST_HOME"

run_dory_hv() {
  HOME="$TEST_HOME" "$DORY_HV" "$@"
}

cleanup() {
  status=$?
  set +e
  hdiutil detach "$RENAMED_MOUNT" -quiet >/dev/null 2>&1 || true
  hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
  rm -f "$FIRST_IMAGE" "$SECOND_IMAGE"
  rm -rf "$COPIED_DRIVE"
  trap - EXIT INT TERM
  exit "$status"
}
trap cleanup EXIT INT TERM

hdiutil create -quiet -size 128m -fs APFS -volname "$VOLUME_NAME" "$FIRST_IMAGE"
hdiutil attach -quiet -nobrowse "$FIRST_IMAGE"
first_drive_id="$(run_dory_hv data-drive select "$DRIVE")"
cp "$DRIVE/drive.json" "$EVIDENCE/first-drive.json"
cp "$SELECTION_RECORD" "$EVIDENCE/initial-selection.json"
cp -R "$DRIVE" "$COPIED_DRIVE"

first_volume_uuid="$(python3 - "$EVIDENCE/first-drive.json" "$first_drive_id" <<'PY'
import json
import pathlib
import sys
import uuid

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert manifest["kind"] == "dev.dory.data-drive"
assert manifest["schemaVersion"] == 1
assert manifest["id"].lower() == sys.argv[2]
volume = manifest["volume"]
assert volume["filesystem"] == "apfs"
assert volume["nameAtCreation"].startswith("DoryIdentity-")
print(str(uuid.UUID(volume["uuid"])))
PY
)"

[ "$(run_dory_hv data-drive selected-path)" = "$DRIVE" ] \
  || { echo "data-drive volume identity gate: initial selection path was not remembered" >&2; exit 1; }
mkdir -p "$TEST_HOME/.dory"
printf 'replaceable runtime state\n' > "$TEST_HOME/.dory/cache"
rm -rf "$TEST_HOME/.dory"
[ "$(run_dory_hv data-drive selected-path)" = "$DRIVE" ] \
  || { echo "data-drive volume identity gate: clearing runtime state forgot the selected drive" >&2; exit 1; }

diskutil rename "$MOUNT" "$RENAMED_VOLUME_NAME" > "$EVIDENCE/rename-volume.out"
[ -d "$RENAMED_MOUNT" ] \
  || { echo "data-drive volume identity gate: renamed APFS mount is unavailable" >&2; exit 1; }
remembered_after_rename="$(run_dory_hv data-drive selected-path)"
[ "$remembered_after_rename" = "$RENAMED_DRIVE" ] \
  || { echo "data-drive volume identity gate: bookmark did not recover the renamed volume" >&2; exit 1; }
renamed_drive_id="$(run_dory_hv data-drive select "$remembered_after_rename")"
[ "$renamed_drive_id" = "$first_drive_id" ] \
  || { echo "data-drive volume identity gate: renamed drive identity changed" >&2; exit 1; }
cp "$SELECTION_RECORD" "$EVIDENCE/renamed-selection.json"
python3 - "$EVIDENCE/renamed-selection.json" "$RENAMED_DRIVE" "$first_drive_id" "$first_volume_uuid" <<'PY'
import json
import pathlib
import sys
import uuid

selection = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert selection["schemaVersion"] == 2
assert selection["phase"] == "ready"
assert selection["canonicalPath"] == sys.argv[2]
assert selection["driveID"].lower() == sys.argv[3]
assert str(uuid.UUID(selection["volumeUUID"])) == str(uuid.UUID(sys.argv[4]))
assert selection["bookmark"]
PY

diskutil rename "$RENAMED_MOUNT" "$VOLUME_NAME" > "$EVIDENCE/restore-volume-name.out"
[ -d "$MOUNT" ] \
  || { echo "data-drive volume identity gate: restored APFS mount is unavailable" >&2; exit 1; }
[ "$(run_dory_hv data-drive selected-path)" = "$DRIVE" ] \
  || { echo "data-drive volume identity gate: bookmark did not follow the restored name" >&2; exit 1; }
[ "$(run_dory_hv data-drive select "$DRIVE")" = "$first_drive_id" ] \
  || { echo "data-drive volume identity gate: restored-name drive identity changed" >&2; exit 1; }

hdiutil detach "$MOUNT" -quiet
if run_dory_hv data-drive id "$DRIVE" \
    >"$EVIDENCE/missing-volume.out" 2>"$EVIDENCE/missing-volume.err"; then
  echo "data-drive volume identity gate: detached selected volume was accepted" >&2
  exit 1
fi
grep -F 'volume is not mounted' "$EVIDENCE/missing-volume.err" >/dev/null
[ ! -e "$MOUNT" ] \
  || { echo "data-drive volume identity gate: detached volume left a shadow mount path" >&2; exit 1; }

hdiutil create -quiet -size 128m -fs APFS -volname "$VOLUME_NAME" "$SECOND_IMAGE"
hdiutil attach -quiet -nobrowse "$SECOND_IMAGE"
cp -R "$COPIED_DRIVE" "$DRIVE"
if run_dory_hv data-drive select "$DRIVE" \
    >"$EVIDENCE/wrong-volume.out" 2>"$EVIDENCE/wrong-volume.err"; then
  echo "data-drive volume identity gate: same-name replacement volume was accepted" >&2
  exit 1
fi
grep -F 'invalid or incompatible manifest' "$EVIDENCE/wrong-volume.err" >/dev/null
hdiutil detach "$MOUNT" -quiet

hdiutil attach -quiet -nobrowse "$FIRST_IMAGE"
restored_drive_id="$(run_dory_hv data-drive select "$DRIVE")"
[ "$restored_drive_id" = "$first_drive_id" ] \
  || { echo "data-drive volume identity gate: original drive identity changed" >&2; exit 1; }
hdiutil detach "$MOUNT" -quiet

{
  printf 'status=PASS\n'
  printf 'architecture=arm64\n'
  printf 'external_volume_identity=PASS\n'
  printf 'durable_selection_outside_runtime_state=PASS\n'
  printf 'bookmark_volume_rename_recovery=PASS\n'
  printf 'missing_volume_shadow_prevention=PASS\n'
  printf 'same_name_wrong_volume_rejected=PASS\n'
  printf 'original_volume_reaccepted=PASS\n'
  printf 'drive_id=%s\n' "$first_drive_id"
  printf 'volume_uuid=%s\n' "$first_volume_uuid"
  shasum -a 256 "$DORY_HV" | awk '{print "dory_hv_sha256=" $1}'
} > "$EVIDENCE/summary.txt"

echo "data-drive volume identity gate: PASS ($EVIDENCE/summary.txt)"
