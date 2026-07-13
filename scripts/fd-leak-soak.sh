#!/bin/bash
set -euo pipefail

SOCKET="${DORY_FD_SOAK_SOCKET:-$HOME/.dory/dory.sock}"
IMAGE="${DORY_FD_SOAK_IMAGE:-alpine:latest}"
ITERATIONS="${DORY_FD_SOAK_ITERATIONS:-50}"
SETTLE_SECONDS="${DORY_FD_SOAK_SETTLE_SECONDS:-3}"
ALLOWED_GROWTH="${DORY_FD_SOAK_ALLOWED_GROWTH:-12}"

usage() {
  cat <<'EOF'
Usage: scripts/fd-leak-soak.sh [options]

Options:
  --socket PATH       Docker-compatible Unix socket (default: ~/.dory/dory.sock)
  --image REF         Existing local image; the soak never pulls (default: alpine:latest)
  --iterations N      Owned container lifecycle cycles (default: 50)
  --settle SECONDS    Settle time before the final FD sample (default: 3)
  --allowed-growth N  Maximum per-process FD growth over baseline (default: 12)
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) SOCKET="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --settle) SETTLE_SECONDS="$2"; shift 2 ;;
    --allowed-growth) ALLOWED_GROWTH="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$ITERATIONS:$SETTLE_SECONDS:$ALLOWED_GROWTH" in
  *[!0-9:]*|:*|*::*|*:) echo "iterations, settle, and allowed growth must be non-negative integers" >&2; exit 2 ;;
esac
[ "$ITERATIONS" -gt 0 ] || { echo "iterations must be greater than zero" >&2; exit 2; }
[ -S "$SOCKET" ] || { echo "Dory socket is unavailable: $SOCKET" >&2; exit 1; }
command -v curl >/dev/null
command -v python3 >/dev/null
command -v lsof >/dev/null

api() {
  method="$1"
  path="$2"
  shift 2
  curl --fail --silent --show-error --unix-socket "$SOCKET" -X "$method" "http://localhost$path" "$@"
}

encoded_image="$(python3 - "$IMAGE" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=""))
PY
)"
api GET "/images/$encoded_image/json" >/dev/null || {
  echo "required image is not local on the selected engine: $IMAGE" >&2
  echo "pull it explicitly before running this offline soak" >&2
  exit 1
}

owner="dory-fd-soak-$$-$(date +%s)"
cleanup() {
  rows="$(api GET '/containers/json?all=1' 2>/dev/null || printf '[]')"
  ids="$(printf '%s' "$rows" | python3 -c '
import json
import sys
owner = sys.argv[1]
try:
    rows = json.load(sys.stdin)
except Exception:
    rows = []
for row in rows:
    if (row.get("Labels") or {}).get("dory.test.owner") == owner:
        print(row.get("Id", ""))
' "$owner")"
  for id in $ids; do
    encoded_id="$(python3 - "$id" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=""))
PY
)"
    api DELETE "/containers/$encoded_id?force=true&v=true" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT INT TERM

pids="$(pgrep -f '(^|/)(Dory|doryd|dory-hv)( |$)' || true)"
[ -n "$pids" ] || { echo "no Dory frontend/daemon/VMM processes found" >&2; exit 1; }

fd_count() {
  lsof -n -P -p "$1" 2>/dev/null | awk 'NR > 1 { count += 1 } END { print count + 0 }'
}

baseline="$(mktemp "${TMPDIR:-/tmp}/dory-fd-baseline.XXXXXX")"
final="$(mktemp "${TMPDIR:-/tmp}/dory-fd-final.XXXXXX")"
trap 'rm -f "$baseline" "$final"; cleanup' EXIT INT TERM
for pid in $pids; do
  command="$(ps -p "$pid" -o comm= | xargs basename)"
  printf '%s\t%s\t%s\n' "$pid" "$command" "$(fd_count "$pid")" >> "$baseline"
done

i=1
while [ "$i" -le "$ITERATIONS" ]; do
  name="$owner-$i"
  body="$(python3 - "$IMAGE" "$owner" <<'PY'
import json
import sys
print(json.dumps({
    "Image": sys.argv[1],
    "Cmd": ["sh", "-c", "printf dory-fd-soak"],
    "Labels": {"dory.test.owner": sys.argv[2]},
}))
PY
)"
  created="$(api POST "/containers/create?name=$name" -H 'Content-Type: application/json' --data-binary "$body")"
  id="$(printf '%s' "$created" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Id"])')"
  encoded_id="$(python3 - "$id" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=""))
PY
)"
  api POST "/containers/$encoded_id/start" >/dev/null
  api POST "/containers/$encoded_id/wait?condition=not-running" >/dev/null
  api GET "/containers/$encoded_id/json?size=1" >/dev/null
  api GET "/containers/$encoded_id/logs?stdout=1&stderr=1" >/dev/null
  api DELETE "/containers/$encoded_id?force=true&v=true" >/dev/null
  if [ $((i % 10)) -eq 0 ] || [ "$i" -eq "$ITERATIONS" ]; then
    echo "fd-soak: completed $i/$ITERATIONS lifecycle cycles"
  fi
  i=$((i + 1))
done

sleep "$SETTLE_SECONDS"
failed=0
while IFS="$(printf '\t')" read -r pid command before; do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "fd-soak: FAIL process exited during soak: $command ($pid)" >&2
    failed=1
    continue
  fi
  after="$(fd_count "$pid")"
  growth=$((after - before))
  printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$command" "$before" "$after" "$growth" >> "$final"
  if [ "$growth" -gt "$ALLOWED_GROWTH" ]; then
    echo "fd-soak: FAIL $command ($pid) grew by $growth FDs ($before -> $after; allowed $ALLOWED_GROWTH)" >&2
    failed=1
  else
    echo "fd-soak: PASS $command ($pid) $before -> $after FDs (growth $growth)"
  fi
done < "$baseline"

[ "$failed" -eq 0 ] || exit 1
echo "fd-soak: PASS $ITERATIONS owned lifecycle cycles; no Dory process exceeded the FD growth budget"
