#!/bin/bash
# Compatibility entrypoint. New operator documentation uses scripts/dory-release.sh exclusively.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
if [ "${1:-}" = --check ]; then
  [ "$#" -eq 1 ] || { echo "usage: scripts/publish-release.sh [--check|VERSION]" >&2; exit 64; }
  exec "$ROOT/scripts/dory-release.sh" check
fi
[ "$#" -eq 1 ] || { echo "usage: scripts/publish-release.sh [--check|VERSION]" >&2; exit 64; }
exec "$ROOT/scripts/dory-release.sh" publish "$1"
