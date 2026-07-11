#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="$ROOT/scripts/benchmark-registry-npm.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-registry-bench-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

printf '{"name":"fixture","version":"1.0.0"}\n' > "$TMP/package.json"
printf '{"name":"fixture","version":"1.0.0","lockfileVersion":3,"packages":{}}\n' > "$TMP/package-lock.json"
DIGEST="sha256:$(printf 'a%.0s' {1..64})"

output="$($HARNESS --engines dory,colima --rounds 4 --image "node@$DIGEST" \
  --fixture "$TMP" --dry-run 2>"$TMP/stderr")"
grep -q 'dry-run only' "$TMP/stderr"
[ "$(printf '%s\n' "$output" | awk 'NR > 1 { count++ } END { print count + 0 }')" -eq 8 ]
[ "$(printf '%s\n' "$output" | awk -F '\t' 'NR > 1 && $2 == 1 && $3 == "dory" { count++ } END { print count + 0 }')" -eq 2 ]
[ "$(printf '%s\n' "$output" | awk -F '\t' 'NR > 1 && $2 == 1 && $3 == "colima" { count++ } END { print count + 0 }')" -eq 2 ]

if $HARNESS --engines dory,colima --rounds 3 --image "node@$DIGEST" \
  --fixture "$TMP" --dry-run >/dev/null 2>&1; then
  echo 'expected unbalanced rounds to fail' >&2
  exit 1
fi

echo 'registry npm benchmark offline tests passed'
