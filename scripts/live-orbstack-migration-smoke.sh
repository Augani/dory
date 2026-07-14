#!/bin/bash
# Real, non-destructive migration smoke. Creates uniquely named fixtures in OrbStack, exercises
# Dory's production migration code through the unit-test host, and removes only those fixtures.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE_SOCKET="${DORY_LIVE_SOURCE_SOCKET:-$HOME/.orbstack/run/docker.sock}"
TARGET_SOCKET="${DORY_LIVE_TARGET_SOCKET:-$HOME/.dory/dory.sock}"
# Keep the fixture image free of Config.Volumes. The gate creates and verifies its own two named
# volumes; an image-declared anonymous volume would add unrelated daemon-owned state and make exact
# source-baseline cleanup depend on Docker's anonymous-volume retention policy.
BASE_IMAGE="${DORY_LIVE_MIGRATION_BASE_IMAGE:-alpine:3.20}"
EVIDENCE_DIR="${DORY_LIVE_MIGRATION_EVIDENCE_DIR:-}"
MARKER="/private/tmp/dev.dory.live-orbstack-migration-test-$(id -u)"
ACK="$MARKER.passed"
HELPER_ARCHIVE="${DORY_LIVE_MIGRATION_HELPER_ARCHIVE:-}"
HELPER_METADATA="${DORY_LIVE_MIGRATION_HELPER_METADATA:-}"
HELPER_DIR=""

[ -S "$SOURCE_SOCKET" ] || { echo "OrbStack socket is not ready: $SOURCE_SOCKET" >&2; exit 1; }
[ -S "$TARGET_SOCKET" ] || { echo "Dory socket is not ready: $TARGET_SOCKET" >&2; exit 1; }
DOCKER_HOST="unix://$SOURCE_SOCKET" docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 \
  || { echo "source fixture image is missing from OrbStack: $BASE_IMAGE" >&2; exit 1; }

case "$BASE_IMAGE$SOURCE_SOCKET$TARGET_SOCKET" in
  *$'\n'*) echo "live migration inputs must not contain newlines" >&2; exit 1 ;;
esac
if [ -n "$EVIDENCE_DIR" ]; then
  case "$EVIDENCE_DIR" in
    /*) ;;
    *) echo "live migration evidence directory must be absolute" >&2; exit 1 ;;
  esac
  [ ! -e "$EVIDENCE_DIR" ] \
    || { echo "live migration evidence directory already exists: $EVIDENCE_DIR" >&2; exit 1; }
  mkdir -p "$EVIDENCE_DIR"
fi
[ ! -e "$MARKER" ] || { echo "stale live migration marker exists: $MARKER" >&2; exit 1; }
rm -f "$ACK"
cleanup() {
  rm -f "$MARKER" "$ACK"
  [ -z "$HELPER_DIR" ] || rm -rf "$HELPER_DIR"
}
trap cleanup EXIT INT TERM
if [ -z "$HELPER_ARCHIVE" ] || [ -z "$HELPER_METADATA" ]; then
  HELPER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dory-live-transfer-helper.XXXXXX")"
  HELPER_ARCHIVE="$HELPER_DIR/dory-transfer-helper-image-arm64.tar"
  HELPER_METADATA="$HELPER_DIR/dory-transfer-helper-image-arm64.json"
  scripts/build-transfer-helper.sh \
    --image-output "$HELPER_ARCHIVE" \
    --image-metadata-output "$HELPER_METADATA" >/dev/null
fi
[ -s "$HELPER_ARCHIVE" ] || { echo "live migration helper archive is missing" >&2; exit 1; }
[ -s "$HELPER_METADATA" ] || { echo "live migration helper metadata is missing" >&2; exit 1; }
export DORY_LIVE_MIGRATION_HELPER_ARCHIVE="$HELPER_ARCHIVE"
export DORY_LIVE_MIGRATION_HELPER_METADATA="$HELPER_METADATA"
printf '%s\n%s\n%s\n%s\n%s\n' \
  "$BASE_IMAGE" "$SOURCE_SOCKET" "$TARGET_SOCKET" "$HELPER_ARCHIVE" "$HELPER_METADATA" > "$MARKER"

scripts/test.sh -only-testing:DoryTests/MigrationTests
[ "$(cat "$ACK" 2>/dev/null || true)" = "passed" ] \
  || { echo "live migration XCTest did not execute the Docker fixture" >&2; exit 1; }

for socket in "$SOURCE_SOCKET" "$TARGET_SOCKET"; do
  leftovers="$(DOCKER_HOST="unix://$socket" docker ps -aq --filter 'name=dory-migration-live' 2>/dev/null || true)"
  [ -z "$leftovers" ] || { echo "owned migration fixture cleanup failed on $socket: $leftovers" >&2; exit 1; }
done
if [ -n "$EVIDENCE_DIR" ]; then
  cat > "$EVIDENCE_DIR/manifest.txt.partial" <<'EOF'
status=PASS
production_migration_path=PASS
source_baseline_restored=PASS
target_baseline_restored=PASS
image_transfer=PASS
two_named_volumes=PASS
volume_64mib_checksum=PASS
volume_metadata_symlink_hardlink=PASS
custom_network_ipam=PASS
running_paused_state=PASS
stopped_writable_layer=PASS
fixed_port_handoff=PASS
EOF
  mv "$EVIDENCE_DIR/manifest.txt.partial" "$EVIDENCE_DIR/manifest.txt"
fi
echo "live production migration smoke passed"
