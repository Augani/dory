#!/usr/bin/env bash
# Offline argument, schedule, and destructive-orchestrator safety tests. No Docker socket, package
# registry, engine manager, app, or filesystem outside a temporary directory is touched.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="$ROOT/scripts/benchmark-developer-workflows.sh"
QUALIFIER="$ROOT/scripts/qualify-container-engine-performance.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-developer-benchmark-test.XXXXXX")"
trap '/bin/rm -rf "$TMP"' EXIT
fail() { echo "benchmark developer workflow test: $*" >&2; exit 1; }

RUBY='example.invalid/ruby@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
NODE='example.invalid/node@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
COMPOSER='example.invalid/composer@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'

bash -n "$HARNESS" "$QUALIFIER"
"$HARNESS" --help > "$TMP/help.txt"
grep -Fq -- '--ruby-image REF' "$TMP/help.txt"
grep -Fq -- '--dry-run' "$TMP/help.txt"
"$QUALIFIER" --help > "$TMP/qualifier-help.txt"
grep -Fq 'CLEAN-BENCHMARK-USER-DELETE-ENGINE-DATA' "$TMP/qualifier-help.txt"

"$HARNESS" --ruby-image "$RUBY" --node-image "$NODE" --composer-image "$COMPOSER" \
  --engines dory,orbstack,colima --rounds 9 --work "$TMP/must-not-exist" --dry-run \
  > "$TMP/schedule.tsv" 2> "$TMP/dry.err"
[ ! -e "$TMP/must-not-exist" ] || fail "dry-run created its work directory"
grep -Fq 'no engine, image, registry, cache, or filesystem mutation was attempted' "$TMP/dry.err"
awk -F '\t' '
  NR == 1 { if ($0 != "workflow\tround\tposition\tengine") exit 1; next }
  { rows++; count[$1]++; positions[$1 "/" $4 "/" $3]++ }
  END {
    if (rows != 81 || count["rails"] != 27 || count["pnpm"] != 27 || count["composer"] != 27) exit 1
    for (workflow in count) for (engine_index = 1; engine_index <= 3; engine_index++) {
      engine = engine_index == 1 ? "dory" : (engine_index == 2 ? "orbstack" : "colima")
      for (position = 1; position <= 3; position++)
        if (positions[workflow "/" engine "/" position] != 3) exit 1
    }
  }
' "$TMP/schedule.tsv" || fail "dry schedule is not fully position-balanced"

expect_failure() {
  local label="$1" expected="$2"
  shift 2
  if "$@" > "$TMP/$label.out" 2>&1; then fail "$label unexpectedly passed"; fi
  grep -Fq "$expected" "$TMP/$label.out" || fail "$label failed for the wrong reason"
}
expect_failure mutable-image 'ruby-image must include an immutable' \
  "$HARNESS" --ruby-image ruby:latest --node-image "$NODE" --composer-image "$COMPOSER" --dry-run
expect_failure unbalanced-rounds 'rounds must be a multiple' \
  "$HARNESS" --ruby-image "$RUBY" --node-image "$NODE" --composer-image "$COMPOSER" --rounds 8 --dry-run
expect_failure missing-confirm 'CLEAN-BENCHMARK-USER-DELETE-ENGINE-DATA is required' "$QUALIFIER"
expect_failure missing-clean-user 'DORY_RELEASE_CLEAN_USER=1 is required' \
  env -u DORY_RELEASE_CLEAN_USER -u DORY_RELEASE_BENCHMARK_USER "$QUALIFIER" \
    --confirm CLEAN-BENCHMARK-USER-DELETE-ENGINE-DATA
expect_failure missing-benchmark-user 'DORY_RELEASE_BENCHMARK_USER=1 is required' \
  env -u DORY_RELEASE_BENCHMARK_USER DORY_RELEASE_CLEAN_USER=1 "$QUALIFIER" \
    --confirm CLEAN-BENCHMARK-USER-DELETE-ENGINE-DATA

grep -Fq 'DORY_RELEASE_CLEAN_USER' "$QUALIFIER"
grep -Fq 'DORY_RELEASE_BENCHMARK_USER' "$QUALIFIER"
grep -Fq 'validate-release-metadata.py' "$QUALIFIER"
grep -Fq 'benchmark-campaign.sh' "$QUALIFIER"
grep -Fq 'benchmark-user-workflows.sh' "$QUALIFIER"
grep -Fq 'benchmark-developer-workflows.sh' "$QUALIFIER"
grep -Fq 'benchmark-registry-npm.sh' "$QUALIFIER"
grep -Fq 'benchmark-external-network.sh' "$QUALIFIER"
grep -Fq 'shasum -a 256 -c sha256.txt' "$QUALIFIER"
grep -Fq 'cleanup left state behind' "$QUALIFIER"

echo "benchmark developer workflow offline tests passed"
