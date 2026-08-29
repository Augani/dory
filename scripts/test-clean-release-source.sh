#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-clean-release-source.XXXXXX")"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
mkdir -p "$REPO"

git -C "$REPO" init -q
git -C "$REPO" config user.name 'Dory Release Test'
git -C "$REPO" config user.email 'release-test@dory.invalid'
printf 'tracked\n' > "$REPO/tracked.txt"
printf 'guest/out/\n' > "$REPO/.gitignore"
git -C "$REPO" add tracked.txt .gitignore
git -C "$REPO" commit -qm initial

scripts/verify-clean-release-source.sh "$REPO" >/dev/null

ln -s "$REPO" "$TMP/indirect-repo"
if scripts/verify-clean-release-source.sh "$TMP/indirect-repo" >"$TMP/indirect.out" 2>"$TMP/indirect.err"; then
  echo "clean release source test failed: accepted a symlinked worktree" >&2
  exit 1
fi
grep -q 'missing or indirect' "$TMP/indirect.err" || {
  echo "clean release source test failed: indirect root failed for the wrong reason" >&2
  exit 1
}

expect_rejected() {
  local name="$1"
  if scripts/verify-clean-release-source.sh "$REPO" >"$TMP/$name.out" 2>"$TMP/$name.err"; then
    echo "clean release source test failed: accepted $name" >&2
    exit 1
  fi
  grep -q 'public release worktree is not clean' "$TMP/$name.err" || {
    echo "clean release source test failed: $name did not fail for the clean-tree contract" >&2
    exit 1
  }
}

printf 'modified\n' >> "$REPO/tracked.txt"
expect_rejected modified-tracked
git -C "$REPO" restore tracked.txt

printf 'staged\n' >> "$REPO/tracked.txt"
git -C "$REPO" add tracked.txt
expect_rejected staged-tracked
git -C "$REPO" reset -q HEAD -- tracked.txt
git -C "$REPO" restore tracked.txt

printf 'untracked\n' > "$REPO/new-source.swift"
expect_rejected untracked-source
rm "$REPO/new-source.swift"

mkdir -p "$REPO/guest/out"
printf 'generated\n' > "$REPO/guest/out/Image"
scripts/verify-clean-release-source.sh "$REPO" >/dev/null

echo "clean release source tests passed"
