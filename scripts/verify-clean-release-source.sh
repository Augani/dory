#!/bin/bash
# A public artifact's sourceCommit is meaningful only when every non-ignored source path is exactly
# the recorded Git commit. Generated guest/out assets are intentionally ignored and are validated
# independently by their deterministic provenance stamps.
set -euo pipefail

ROOT="${1:-.}"
[ -d "$ROOT" ] && [ ! -L "$ROOT" ] || {
  echo "release source verification failed: worktree root is missing or indirect: $ROOT" >&2
  exit 1
}
LOGICAL_ROOT="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$ROOT")"
cd "$ROOT"
PHYSICAL_ROOT="$(pwd -P)"
[ "$LOGICAL_ROOT" = "$PHYSICAL_ROOT" ] || {
  echo "release source verification failed: worktree root has an indirect ancestor" >&2
  exit 1
}

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "release source verification failed: not inside a Git worktree: $ROOT" >&2
  exit 1
}

STATUS="$(git status --porcelain=v1 --untracked-files=all --ignore-submodules=none)"
if [ -n "$STATUS" ]; then
  echo "release source verification failed: public release worktree is not clean" >&2
  printf '%s\n' "$STATUS" >&2
  exit 1
fi

echo "release source verification: PASS (clean commit $(git rev-parse HEAD))"
