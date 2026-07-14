#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-26.6.0-Release.Candidate.app/Contents/Developer}"
export DEVELOPER_DIR
HELPER="${DORY_HV_BIN:-$REPO_ROOT/Packages/ContainerizationEngine/.build/debug/dory-hv}"

if [ ! -x "$HELPER" ]; then
  swift build --package-path "$REPO_ROOT/Packages/ContainerizationEngine" --product dory-hv
fi

TMP_HOME="$(mktemp -d /tmp/dory-data-backup-gate.XXXXXX)"
trap 'rm -rf "$TMP_HOME"' EXIT
DRIVE="$TMP_HOME/Library/Application Support/Dory/Dory.dorydrive"
RESTORED="$TMP_HOME/Library/Application Support/Dory/Restored.dorydrive"
ARCHIVE="$TMP_HOME/Full.dorybackup"

HOME="$TMP_HOME" "$HELPER" data-drive select "$DRIVE" >/dev/null
printf 'verified-cli-roundtrip\n' > "$DRIVE/engine/fixture.txt"
xattr -wx dev.dory.test 0001feff "$DRIVE/engine/fixture.txt"
truncate -s 33554432 "$DRIVE/engine/sparse.img"
printf head | dd of="$DRIVE/engine/sparse.img" bs=1 seek=0 conv=notrunc status=none
printf tail | dd of="$DRIVE/engine/sparse.img" bs=1 seek=33554428 conv=notrunc status=none

HOME="$TMP_HOME" DORY_HV_BIN="$HELPER" "$REPO_ROOT/scripts/dory" data backup "$ARCHIVE" \
  > "$TMP_HOME/backup.json"
HOME="$TMP_HOME" DORY_HV_BIN="$HELPER" "$REPO_ROOT/scripts/dory" data verify "$ARCHIVE" \
  > "$TMP_HOME/verify.json"

mv "$ARCHIVE/complete.json" "$ARCHIVE/complete.invalid"
if HOME="$TMP_HOME" DORY_HV_BIN="$HELPER" "$REPO_ROOT/scripts/dory" data verify "$ARCHIVE" \
  > /dev/null 2>&1; then
  echo "backup gate: incomplete archive unexpectedly verified" >&2
  exit 1
fi
mv "$ARCHIVE/complete.invalid" "$ARCHIVE/complete.json"

HOME="$TMP_HOME" DORY_HV_BIN="$HELPER" "$REPO_ROOT/scripts/dory" data restore \
  "$ARCHIVE" "$RESTORED" > "$TMP_HOME/restore.json"
cmp "$DRIVE/engine/fixture.txt" "$RESTORED/engine/fixture.txt"
cmp "$DRIVE/engine/sparse.img" "$RESTORED/engine/sparse.img"
restored_xattr="$(xattr -px dev.dory.test "$RESTORED/engine/fixture.txt" \
  | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
[ "$restored_xattr" = "0001feff" ]
logical="$(stat -f %z "$RESTORED/engine/sparse.img")"
allocated="$(( $(stat -f %b "$RESTORED/engine/sparse.img") * 512 ))"
[ "$logical" -eq 33554432 ]
[ "$allocated" -lt "$logical" ]

HOME="$TMP_HOME" DORY_HV_BIN="$HELPER" "$REPO_ROOT/scripts/dory" data use "$RESTORED" \
  > /dev/null
selected="$(HOME="$TMP_HOME" DORY_HV_BIN="$HELPER" "$REPO_ROOT/scripts/dory" data path)"
[ "$selected" = "$RESTORED" ]

python3 - "$TMP_HOME/backup.json" "$TMP_HOME/verify.json" "$TMP_HOME/restore.json" <<'PY'
import json
import sys

records = []
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as handle:
        record = json.load(handle)
    assert len(record["archiveManifestDigest"]) == 64
    assert record["entryCount"] >= 9
    assert record["logicalBytes"] > record["storedBytes"]
    records.append(record)
assert records[0] == records[1] == records[2]
PY

if find "$TMP_HOME" -name '*.partial' -print -quit | grep -q .; then
  echo "backup gate: unpublished partial remained after success" >&2
  exit 1
fi

echo "Dory sparse data-drive backup/restore gate passed."
