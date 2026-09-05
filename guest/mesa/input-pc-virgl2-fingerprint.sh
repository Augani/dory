#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source guest/mesa/PINS

case "${1:-x86_64}" in
  amd64|x86_64) ;;
  *) echo "the Dory PC VirGL2 runtime supports x86_64 only" >&2; exit 64 ;;
esac

{
  printf 'schema=2\narch=x86_64\nprofile=pc-virgl2\n'
  printf 'mesa_version=%s\nmeson_version=%s\nbuilder=%s\n' \
    "$MESA_VERSION" "$MESON_VERSION" "$MESA_BUILDER_IMAGE"
  for input in \
    guest/mesa/PINS \
    guest/mesa/build-pc-virgl2.sh \
    guest/mesa/input-pc-virgl2-fingerprint.sh; do
    printf 'input=%s\n' "$input"
    shasum -a 256 "$input"
  done
} | shasum -a 256 | awk '{print $1}'
