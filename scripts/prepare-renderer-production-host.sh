#!/bin/bash
# Materialize the exact static renderer link closure consumed by the production worker target.
# This producer never writes into an application bundle and never emits renderer dylibs or an ICD.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFIER="$ROOT/scripts/renderer-production-tuple.py"
DEPENDENCY_PREFIX=""
DEPENDENCY_INVENTORY=""
LINK_ROOT=""
LINK_INVENTORY=""
JOBS=3
FRESH=0

usage() {
  echo "usage: $0 --dependency-prefix PATH --dependency-inventory PATH --link-root PATH --link-inventory PATH [--jobs COUNT] [--fresh]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dependency-prefix) DEPENDENCY_PREFIX="${2:?missing dependency prefix}"; shift 2 ;;
    --dependency-inventory) DEPENDENCY_INVENTORY="${2:?missing dependency inventory}"; shift 2 ;;
    --link-root) LINK_ROOT="${2:?missing link root}"; shift 2 ;;
    --link-inventory) LINK_INVENTORY="${2:?missing link inventory}"; shift 2 ;;
    --jobs) JOBS="${2:?missing jobs count}"; shift 2 ;;
    --fresh) FRESH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "prepare-renderer-production-host: unknown argument $1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$DEPENDENCY_PREFIX" ] && [ -n "$DEPENDENCY_INVENTORY" ] \
  && [ -n "$LINK_ROOT" ] && [ -n "$LINK_INVENTORY" ] || { usage; exit 2; }
case "$DEPENDENCY_PREFIX" in
  /|"$HOME"|"$ROOT") echo "prepare-renderer-production-host: refusing broad dependency path" >&2; exit 2 ;;
esac
case "$LINK_ROOT" in
  /|"$HOME"|"$ROOT") echo "prepare-renderer-production-host: refusing broad link-closure path" >&2; exit 2 ;;
esac
case "$JOBS" in
  ''|*[!0-9]*) echo "prepare-renderer-production-host: jobs must be an integer" >&2; exit 2 ;;
esac
[ "$JOBS" -gt 0 ] && [ "$JOBS" -le 3 ] || {
  echo "prepare-renderer-production-host: jobs must be between 1 and 3" >&2
  exit 2
}
[ "$(dirname "$DEPENDENCY_INVENTORY")" = "$DEPENDENCY_PREFIX" ] || {
  echo "prepare-renderer-production-host: dependency inventory must be a direct child of its prefix" >&2
  exit 2
}
[ "$(dirname "$LINK_INVENTORY")" = "$LINK_ROOT" ] || {
  echo "prepare-renderer-production-host: link inventory must be a direct child of its root" >&2
  exit 2
}

python3 "$VERIFIER" verify-definition --repo-root "$ROOT"

if [ "$FRESH" = 1 ]; then
  for stage in "$DEPENDENCY_PREFIX" "$LINK_ROOT"; do
    if [ -e "$stage" ] || [ -L "$stage" ]; then
      echo "prepare-renderer-production-host: --fresh refuses a pre-existing producer stage: $stage" >&2
      exit 1
    fi
  done
fi

if [ "$FRESH" = 0 ] && python3 "$VERIFIER" verify-inventory \
    --profile staticDependencies \
    --root "$DEPENDENCY_PREFIX" \
    --inventory "$DEPENDENCY_INVENTORY" >/dev/null 2>&1; then
  :
else
  if [ "$FRESH" = 0 ] && [ -e "$DEPENDENCY_PREFIX" ] \
      && [ ! -d "$DEPENDENCY_PREFIX" ]; then
    echo "prepare-renderer-production-host: dependency prefix is not a directory" >&2
    exit 1
  fi
  if [ "$FRESH" = 0 ] && [ -d "$DEPENDENCY_PREFIX" ] \
      && [ -n "$(find "$DEPENDENCY_PREFIX" -mindepth 1 -print -quit)" ]; then
    echo "prepare-renderer-production-host: refusing to replace an invalid nonempty dependency stage" >&2
    exit 1
  fi
  "$ROOT/scripts/build-renderer-production-dependencies.sh" \
    --prefix "$DEPENDENCY_PREFIX" \
    --inventory "$DEPENDENCY_INVENTORY" \
    --jobs "$JOBS"
fi
python3 "$VERIFIER" verify-inventory \
  --profile staticDependencies \
  --root "$DEPENDENCY_PREFIX" \
  --inventory "$DEPENDENCY_INVENTORY"

if [ "$FRESH" = 0 ] && python3 "$VERIFIER" verify-inventory \
    --profile staticLinkClosure \
    --root "$LINK_ROOT" \
    --inventory "$LINK_INVENTORY" >/dev/null 2>&1; then
  :
else
  if [ "$FRESH" = 0 ] && [ -e "$LINK_ROOT" ] && [ ! -d "$LINK_ROOT" ]; then
    echo "prepare-renderer-production-host: link root is not a directory" >&2
    exit 1
  fi
  if [ "$FRESH" = 0 ] && [ -d "$LINK_ROOT" ] \
      && [ -n "$(find "$LINK_ROOT" -mindepth 1 -print -quit)" ]; then
    echo "prepare-renderer-production-host: refusing to replace an invalid nonempty link stage" >&2
    exit 1
  fi
  mkdir -p "$LINK_ROOT"
  "$ROOT/scripts/build-virglrenderer.sh" \
    --output-root "$LINK_ROOT" \
    --inventory "$LINK_INVENTORY" \
    --dependency-prefix "$DEPENDENCY_PREFIX" \
    --dependency-inventory "$DEPENDENCY_INVENTORY" \
    --jobs "$JOBS"
fi
python3 "$VERIFIER" verify-inventory \
  --profile staticLinkClosure \
  --root "$LINK_ROOT" \
  --inventory "$LINK_INVENTORY"
printf 'renderer.linkRoot=%s\n' "$LINK_ROOT"
printf 'renderer.linkInventory=%s\n' "$LINK_INVENTORY"
