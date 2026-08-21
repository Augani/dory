#!/bin/bash
# Proves that the exact dory-hv binds an external .dorydrive to its APFS volume UUID, not merely
# the reusable /Volumes/<name> path. Uses two disposable sparse APFS images with the same name.
set -euo pipefail
umask 077

usage() {
  echo "Usage: $0 --dory-hv PATH --confirm PHYSICAL-APFS-VOLUME-IDENTITY [--workroot DIR]" >&2
}

DORY_HV=""
WORKROOT="${TMPDIR:-/tmp}/dory-volume-identity-evidence"
CONFIRM=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dory-hv) DORY_HV="${2:?--dory-hv requires a path}"; shift 2 ;;
    --workroot) WORKROOT="${2:?--workroot requires a directory}"; shift 2 ;;
    --confirm) CONFIRM="${2:?--confirm requires a token}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "data-drive volume identity gate: unknown argument: $1" >&2; usage; exit 64 ;;
  esac
done

[ "$CONFIRM" = PHYSICAL-APFS-VOLUME-IDENTITY ] \
  || { echo "data-drive volume identity gate: requires --confirm PHYSICAL-APFS-VOLUME-IDENTITY" >&2; exit 2; }
[ "$(uname -m)" = arm64 ] \
  || { echo "data-drive volume identity gate: physical Apple silicon is required" >&2; exit 69; }
case "$DORY_HV" in /*) ;; *) echo "data-drive volume identity gate: dory-hv must be absolute" >&2; exit 66 ;; esac
[ -f "$DORY_HV" ] && [ ! -L "$DORY_HV" ] && [ -x "$DORY_HV" ] \
  || { echo "data-drive volume identity gate: dory-hv is missing or indirect" >&2; exit 66; }
case "$WORKROOT" in /*) ;; *) echo "data-drive volume identity gate: workroot must be absolute" >&2; exit 73 ;; esac
case "$WORKROOT" in /|"$HOME"|"$(pwd)") echo "data-drive volume identity gate: unsafe workroot" >&2; exit 73 ;; esac
[ ! -e "$WORKROOT" ] && [ ! -L "$WORKROOT" ] \
  || { echo "data-drive volume identity gate: workroot already exists or is indirect" >&2; exit 73; }
for command in diskutil hdiutil python3 shasum; do
  command -v "$command" >/dev/null \
    || { echo "data-drive volume identity gate: $command is missing" >&2; exit 69; }
done

mkdir "$WORKROOT"
WORKROOT="$(cd "$WORKROOT" && pwd -P)"
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
[ ! -e "$MOUNT" ] && [ ! -e "$RENAMED_MOUNT" ] \
  || { echo "data-drive volume identity gate: generated APFS mount name is already in use" >&2; exit 73; }
first_device=""
second_device=""

run_dory_hv() {
  HOME="$TEST_HOME" "$DORY_HV" "$@"
}

cleanup() {
  status=$?
  set +e
  [ -z "$second_device" ] || hdiutil detach "$second_device" -quiet >/dev/null 2>&1 || true
  [ -z "$first_device" ] || hdiutil detach "$first_device" -quiet >/dev/null 2>&1 || true
  rm -f "$FIRST_IMAGE" "$SECOND_IMAGE"
  rm -rf "$COPIED_DRIVE"
  trap - EXIT INT TERM
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

attach_image() {
  local image="$1" expected_mount="$2" evidence="$3"
  hdiutil attach -plist -nobrowse "$image" > "$evidence"
  python3 - "$evidence" "$expected_mount" <<'PY'
import pathlib
import plistlib
import re
import sys

document = plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())
if not isinstance(document, dict) or "system-entities" not in document:
    raise SystemExit("hdiutil attach returned an unexpected authority shape")
entities = document["system-entities"]
if not isinstance(entities, list) or not all(isinstance(item, dict) for item in entities):
    raise SystemExit("hdiutil attach returned invalid system entities")
mounted = [item for item in entities if "mount-point" in item]
if len(mounted) != 1 or mounted[0].get("mount-point") != sys.argv[2]:
    raise SystemExit("hdiutil attached the image at an unexpected mount point")
device = mounted[0].get("dev-entry")
if not isinstance(device, str) or re.fullmatch(r"/dev/disk[0-9]+s[0-9]+", device) is None:
    raise SystemExit("hdiutil did not report an exact mounted APFS device")
print(device)
PY
}

hdiutil create -quiet -size 128m -fs APFS -volname "$VOLUME_NAME" "$FIRST_IMAGE"
[ -f "$FIRST_IMAGE" ] && [ ! -L "$FIRST_IMAGE" ] \
  || { echo "data-drive volume identity gate: first APFS image is unavailable or indirect" >&2; exit 1; }
first_device="$(attach_image "$FIRST_IMAGE" "$MOUNT" "$EVIDENCE/first-attach.plist")"
first_drive_id="$(run_dory_hv data-drive select "$DRIVE")"
printf '%s\n' "$first_drive_id" | grep -Eq '^[0-9a-fA-F-]{36}$' \
  || { echo "data-drive volume identity gate: dory-hv returned an invalid drive ID" >&2; exit 1; }
cp "$DRIVE/drive.json" "$EVIDENCE/first-drive.json"
cp "$SELECTION_RECORD" "$EVIDENCE/initial-selection.json"
cp -R "$DRIVE" "$COPIED_DRIVE"

first_volume_uuid="$(python3 - "$EVIDENCE/first-drive.json" "$first_drive_id" <<'PY'
import json
import pathlib
import sys
import uuid
from datetime import datetime

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
expected = {"kind", "schemaVersion", "id", "product", "createdAt", "volume"}
if not isinstance(manifest, dict) or set(manifest) != expected:
    raise SystemExit("data-drive manifest has an unexpected shape")
if (
    manifest["kind"] != "dev.dory.data-drive"
    or manifest["schemaVersion"] != 1
    or manifest["product"] != "Dory"
):
    raise SystemExit("data-drive manifest has an unsupported contract")
if str(uuid.UUID(manifest["id"])) != str(uuid.UUID(sys.argv[2])):
    raise SystemExit("data-drive manifest ID differs from dory-hv output")
try:
    datetime.fromisoformat(manifest["createdAt"].replace("Z", "+00:00"))
except (AttributeError, ValueError) as error:
    raise SystemExit("data-drive manifest has an invalid creation timestamp") from error
volume = manifest["volume"]
if not isinstance(volume, dict) or set(volume) != {"filesystem", "nameAtCreation", "uuid"}:
    raise SystemExit("data-drive volume authority has an unexpected shape")
if volume["filesystem"] != "apfs" or not volume["nameAtCreation"].startswith("DoryIdentity-"):
    raise SystemExit("data-drive volume authority is not the expected APFS identity")
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
from datetime import datetime

selection = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
expected = {
    "schemaVersion", "phase", "canonicalPath", "driveID",
    "volumeUUID", "bookmark", "selectedAt",
}
if not isinstance(selection, dict) or set(selection) != expected:
    raise SystemExit("selection authority has an unexpected shape")
if selection["schemaVersion"] != 2 or selection["phase"] != "ready":
    raise SystemExit("selection authority is not ready schema v2")
if selection["canonicalPath"] != sys.argv[2] or selection["driveID"].lower() != sys.argv[3].lower():
    raise SystemExit("selection authority differs from the selected drive")
if str(uuid.UUID(selection["volumeUUID"])) != str(uuid.UUID(sys.argv[4])):
    raise SystemExit("selection authority differs from the APFS volume")
if not isinstance(selection["bookmark"], str) or not selection["bookmark"]:
    raise SystemExit("selection authority omits its security-scoped bookmark")
try:
    datetime.fromisoformat(selection["selectedAt"].replace("Z", "+00:00"))
except (AttributeError, ValueError) as error:
    raise SystemExit("selection authority has an invalid timestamp") from error
PY

diskutil rename "$RENAMED_MOUNT" "$VOLUME_NAME" > "$EVIDENCE/restore-volume-name.out"
[ -d "$MOUNT" ] \
  || { echo "data-drive volume identity gate: restored APFS mount is unavailable" >&2; exit 1; }
[ "$(run_dory_hv data-drive selected-path)" = "$DRIVE" ] \
  || { echo "data-drive volume identity gate: bookmark did not follow the restored name" >&2; exit 1; }
[ "$(run_dory_hv data-drive select "$DRIVE")" = "$first_drive_id" ] \
  || { echo "data-drive volume identity gate: restored-name drive identity changed" >&2; exit 1; }

hdiutil detach "$first_device" -quiet
first_device=""
if run_dory_hv data-drive id "$DRIVE" \
    >"$EVIDENCE/missing-volume.out" 2>"$EVIDENCE/missing-volume.err"; then
  echo "data-drive volume identity gate: detached selected volume was accepted" >&2
  exit 1
fi
grep -F 'volume is not mounted' "$EVIDENCE/missing-volume.err" >/dev/null
[ ! -e "$MOUNT" ] \
  || { echo "data-drive volume identity gate: detached volume left a shadow mount path" >&2; exit 1; }

hdiutil create -quiet -size 128m -fs APFS -volname "$VOLUME_NAME" "$SECOND_IMAGE"
[ -f "$SECOND_IMAGE" ] && [ ! -L "$SECOND_IMAGE" ] \
  || { echo "data-drive volume identity gate: second APFS image is unavailable or indirect" >&2; exit 1; }
second_device="$(attach_image "$SECOND_IMAGE" "$MOUNT" "$EVIDENCE/second-attach.plist")"
cp -R "$COPIED_DRIVE" "$DRIVE"
if run_dory_hv data-drive select "$DRIVE" \
    >"$EVIDENCE/wrong-volume.out" 2>"$EVIDENCE/wrong-volume.err"; then
  echo "data-drive volume identity gate: same-name replacement volume was accepted" >&2
  exit 1
fi
grep -F 'invalid or incompatible manifest' "$EVIDENCE/wrong-volume.err" >/dev/null
hdiutil detach "$second_device" -quiet
second_device=""

first_device="$(attach_image "$FIRST_IMAGE" "$MOUNT" "$EVIDENCE/first-reattach.plist")"
restored_drive_id="$(run_dory_hv data-drive select "$DRIVE")"
[ "$restored_drive_id" = "$first_drive_id" ] \
  || { echo "data-drive volume identity gate: original drive identity changed" >&2; exit 1; }
hdiutil detach "$first_device" -quiet
first_device=""

{
  printf 'status=PASS\n'
  printf 'architecture=arm64\n'
  printf 'external_volume_identity=PASS\n'
  printf 'durable_selection_outside_runtime_state=PASS\n'
  printf 'bookmark_volume_rename_recovery=PASS\n'
  printf 'missing_volume_shadow_prevention=PASS\n'
  printf 'same_name_wrong_volume_rejected=PASS\n'
  printf 'original_volume_reaccepted=PASS\n'
  printf 'exact_candidate_helper=PASS\n'
  printf 'exact_device_detach=PASS\n'
  printf 'drive_id=%s\n' "$first_drive_id"
  printf 'volume_uuid=%s\n' "$first_volume_uuid"
  shasum -a 256 "$DORY_HV" | awk '{print "dory_hv_sha256=" $1}'
} > "$EVIDENCE/summary.txt"

echo "data-drive volume identity gate: PASS ($EVIDENCE/summary.txt)"
