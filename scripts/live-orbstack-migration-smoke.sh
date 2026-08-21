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
BASE_IMAGE="${DORY_LIVE_MIGRATION_BASE_IMAGE:-}"
DOCKER_BIN="${DORY_LIVE_DOCKER_BIN:-}"
EVIDENCE_DIR="${DORY_LIVE_MIGRATION_EVIDENCE_DIR:-}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
MARKER_ROOT="${EVIDENCE_DIR:-${TMPDIR:-/tmp}}"
MARKER="${DORY_LIVE_ORBSTACK_MIGRATION_MARKER:-$MARKER_ROOT/dory-live-migration-$RUN_ID.marker}"
ACK="$MARKER.passed"
HELPER_ARCHIVE="${DORY_LIVE_MIGRATION_HELPER_ARCHIVE:-}"
HELPER_METADATA="${DORY_LIVE_MIGRATION_HELPER_METADATA:-}"
HELPER_DIR=""

[ "${DORY_LIVE_MIGRATION_CONFIRMED:-}" = ISOLATED-DORY-LIVE-MIGRATION ] || {
  echo "live migration requires DORY_LIVE_MIGRATION_CONFIRMED=ISOLATED-DORY-LIVE-MIGRATION" >&2
  exit 2
}
printf '%s\n' "$BASE_IMAGE" \
  | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[0-9a-f]{64}$' || {
    echo "live migration base image must be an exact digest reference" >&2
    exit 2
  }
[ -n "$DOCKER_BIN" ] || { echo "DORY_LIVE_DOCKER_BIN is required" >&2; exit 2; }
case "$DOCKER_BIN" in /*) ;; *) echo "live migration Docker CLI must be absolute" >&2; exit 2 ;; esac
[ -f "$DOCKER_BIN" ] && [ ! -L "$DOCKER_BIN" ] && [ -x "$DOCKER_BIN" ] || {
  echo "live migration Docker CLI is unavailable or indirect" >&2
  exit 2
}
[ -S "$SOURCE_SOCKET" ] || { echo "source socket is not ready: $SOURCE_SOCKET" >&2; exit 1; }
[ -S "$TARGET_SOCKET" ] || { echo "Dory socket is not ready: $TARGET_SOCKET" >&2; exit 1; }
[ "$SOURCE_SOCKET" != "$TARGET_SOCKET" ] \
  || { echo "live migration source and target sockets must differ" >&2; exit 2; }
for socket in "$SOURCE_SOCKET" "$TARGET_SOCKET"; do
  [ "$(stat -f %u "$socket")" = "$(id -u)" ] \
    || { echo "live migration socket is not owned by the release user: $socket" >&2; exit 2; }
done
DOCKER_HOST="unix://$SOURCE_SOCKET" "$DOCKER_BIN" image inspect "$BASE_IMAGE" >/dev/null 2>&1 \
  || { echo "source fixture image is missing: $BASE_IMAGE" >&2; exit 1; }

case "$BASE_IMAGE$SOURCE_SOCKET$TARGET_SOCKET" in
  *$'\n'*) echo "live migration inputs must not contain newlines" >&2; exit 1 ;;
esac
case "$MARKER_ROOT" in /*) ;; *) echo "live migration marker root must be absolute" >&2; exit 2 ;; esac
case "$MARKER_ROOT" in /|"$HOME"|"$(pwd)") echo "unsafe live migration marker root" >&2; exit 2 ;; esac
[ ! -L "$MARKER_ROOT" ] || { echo "live migration marker root must not be a symlink" >&2; exit 2; }
case "$MARKER" in "$MARKER_ROOT"/*) ;;
  *) echo "live migration marker must remain below its private root" >&2; exit 2 ;;
esac
if [ -n "$EVIDENCE_DIR" ]; then
  case "$EVIDENCE_DIR" in
    /*) ;;
    *) echo "live migration evidence directory must be absolute" >&2; exit 1 ;;
  esac
  case "$EVIDENCE_DIR" in /|"$HOME"|"$(pwd)") echo "unsafe live migration evidence directory" >&2; exit 2 ;; esac
  [ ! -e "$EVIDENCE_DIR" ] && [ ! -L "$EVIDENCE_DIR" ] \
    || { echo "live migration evidence directory already exists: $EVIDENCE_DIR" >&2; exit 1; }
  mkdir -p "$EVIDENCE_DIR"
  [ -d "$EVIDENCE_DIR" ] && [ ! -L "$EVIDENCE_DIR" ] \
    || { echo "live migration evidence directory changed while preparing it" >&2; exit 1; }
fi
[ ! -e "$MARKER" ] && [ ! -L "$MARKER" ] && [ ! -e "$ACK" ] && [ ! -L "$ACK" ] \
  || { echo "stale live migration marker exists: $MARKER" >&2; exit 1; }
cleanup() {
  rm -f "$MARKER" "$ACK"
  [ -z "$HELPER_DIR" ] || rm -rf "$HELPER_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ -z "$HELPER_ARCHIVE" ] || [ -z "$HELPER_METADATA" ]; then
  HELPER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dory-live-transfer-helper.XXXXXX")"
  HELPER_ARCHIVE="$HELPER_DIR/dory-transfer-helper-image-arm64.tar"
  HELPER_METADATA="$HELPER_DIR/dory-transfer-helper-image-arm64.json"
  scripts/build-transfer-helper.sh \
    --image-output "$HELPER_ARCHIVE" \
    --image-metadata-output "$HELPER_METADATA" >/dev/null
fi
[ -f "$HELPER_ARCHIVE" ] && [ ! -L "$HELPER_ARCHIVE" ] && [ -s "$HELPER_ARCHIVE" ] \
  || { echo "live migration helper archive is missing or indirect" >&2; exit 1; }
[ -f "$HELPER_METADATA" ] && [ ! -L "$HELPER_METADATA" ] && [ -s "$HELPER_METADATA" ] \
  || { echo "live migration helper metadata is missing or indirect" >&2; exit 1; }
export DORY_LIVE_MIGRATION_HELPER_ARCHIVE="$HELPER_ARCHIVE"
export DORY_LIVE_MIGRATION_HELPER_METADATA="$HELPER_METADATA"
export DORY_LIVE_ORBSTACK_MIGRATION_MARKER="$MARKER"
printf '%s\n%s\n%s\n%s\n%s\n' \
  "$BASE_IMAGE" "$SOURCE_SOCKET" "$TARGET_SOCKET" "$HELPER_ARCHIVE" "$HELPER_METADATA" > "$MARKER"

scripts/test.sh app -- -only-testing:DoryTests/MigrationTests
[ "$(cat "$ACK" 2>/dev/null || true)" = "passed" ] \
  || { echo "live migration XCTest did not execute the Docker fixture" >&2; exit 1; }

for socket in "$SOURCE_SOCKET" "$TARGET_SOCKET"; do
  leftovers="$(DOCKER_HOST="unix://$socket" "$DOCKER_BIN" ps -aq \
    --filter 'name=dory-migration-live' 2>/dev/null || true)"
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
  {
    printf 'base_image=%s\n' "$BASE_IMAGE"
    printf 'docker_cli_sha256=%s\n' "$(shasum -a 256 "$DOCKER_BIN" | awk '{print $1}')"
    printf 'helper_archive_sha256=%s\n' "$(shasum -a 256 "$HELPER_ARCHIVE" | awk '{print $1}')"
    printf 'helper_metadata_sha256=%s\n' "$(shasum -a 256 "$HELPER_METADATA" | awk '{print $1}')"
  } >> "$EVIDENCE_DIR/manifest.txt.partial"
  mv "$EVIDENCE_DIR/manifest.txt.partial" "$EVIDENCE_DIR/manifest.txt"
fi
echo "live production migration smoke passed"
