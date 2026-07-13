#!/usr/bin/env bash
# Offline safety/argument tests for benchmark-campaign.sh. No engine, app, package manager, Docker
# socket, or removal command is accessed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="$ROOT/scripts/benchmark-campaign.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dory-campaign-test.XXXXXX")"
cleanup() { /bin/rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
fail() { echo "benchmark-campaign test failed: $*" >&2; exit 1; }

FAKE_BIN="$TMP_ROOT/fake-bin"
MUTATION_LOG="$TMP_ROOT/mutations.log"
/bin/mkdir -p "$FAKE_BIN" "$TMP_ROOT/home"
: > "$MUTATION_LOG"

# Every command that could mutate an installed engine or the filesystem is a tripwire. A safe
# --help/error/--dry-run path must not execute any of them. The harness may still use read-only
# platform commands such as date, df, and awk.
for command in mkdir rm brew orb colima podman open osascript pkill docker codesign sleep tee env; do
  printf '%s\n' \
    '#!/bin/sh' \
    'printf "MUTATION %s %s\n" "$0" "$*" >> "$MUTATION_LOG"' \
    'exit 99' > "$FAKE_BIN/$command"
  chmod +x "$FAKE_BIN/$command"
done

safe_env() {
  env PATH="$FAKE_BIN:$PATH" HOME="$TMP_ROOT/home" MUTATION_LOG="$MUTATION_LOG" "$@"
}

assert_no_mutation() {
  local label="$1" work="$2"
  [ ! -s "$MUTATION_LOG" ] || fail "$label invoked a mutation command: $(tr '\n' ';' < "$MUTATION_LOG")"
  [ ! -e "$work" ] || fail "$label created its campaign directory: $work"
}

expect_rejected() {
  local label="$1" work="$TMP_ROOT/work-$1" rc
  shift
  : > "$MUTATION_LOG"
  set +e
  safe_env CAMPAIGN_WORKDIR="$work" "$HARNESS" "$@" \
    > "$TMP_ROOT/$label.out" 2> "$TMP_ROOT/$label.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "$label returned $rc, expected argument/preflight exit 2"
  assert_no_mutation "$label" "$work"
}

bash -n "$HARNESS"

# Help must be a pure read: notably, it must exit before RUN_ID/result-directory initialization.
help_work="$TMP_ROOT/help-work"
: > "$MUTATION_LOG"
safe_env CAMPAIGN_WORKDIR="$help_work" "$HARNESS" --help > "$TMP_ROOT/help.txt"
assert_no_mutation help "$help_work"
grep -Fq -- '--engines CSV' "$TMP_ROOT/help.txt"
grep -Fq -- '--profiles CSV' "$TMP_ROOT/help.txt"
grep -Fq -- '--dory-app PATH' "$TMP_ROOT/help.txt"
grep -Fq -- '--dry-run' "$TMP_ROOT/help.txt"
grep -Fq -- '--confirm-destructive-purge DELETE-SELECTED-ENGINE-DATA' "$TMP_ROOT/help.txt"

# No-argument live execution is disabled by default. Parsing and all validation failures are inert.
expect_rejected confirmation-required
expect_rejected unknown-option --definitely-not-an-option
expect_rejected missing-engines --engines
expect_rejected option-is-not-value --engines --dry-run
expect_rejected empty-engine --engines 'dory,' --dry-run
expect_rejected unsupported-engine --engines dory,docker-desktop --dry-run
expect_rejected duplicate-engine --engines dory,dory --dry-run
expect_rejected unsupported-profile --profiles turbo --dry-run
expect_rejected duplicate-profile --profiles default,default --dry-run
expect_rejected unsupported-metric --metrics memory,imaginary --dry-run
expect_rejected zero-runs --runs 0 --dry-run
expect_rejected nonnumeric-memory --memory-count many --dry-run
expect_rejected excessive-socket-wait --socket-wait 3601 --dry-run
expect_rejected overflowing-cpus --pinned-cpus 999999999999999999999 --dry-run
expect_rejected bad-app-suffix --dory-app "$TMP_ROOT/not-dory.app" --dry-run
expect_rejected relative-work --work relative/results --dry-run
expect_rejected wrong-confirmation --confirm-destructive-purge YES --dry-run

# A pre-existing destination is invalid even in planning mode, so dry-run accurately predicts the
# live preflight instead of promising a campaign that would later clobber results.
existing_work="$TMP_ROOT/existing-work"
/bin/mkdir -p "$existing_work"
: > "$MUTATION_LOG"
set +e
safe_env "$HARNESS" --engines colima --work "$existing_work" --dry-run \
  > "$TMP_ROOT/existing-work.out" 2> "$TMP_ROOT/existing-work.err"
existing_rc=$?
set -e
[ "$existing_rc" -eq 2 ] || fail "existing work directory returned $existing_rc, expected 2"
[ ! -s "$MUTATION_LOG" ] || fail 'existing work-directory preflight invoked a mutation command'
[ -z "$(find "$existing_work" -mindepth 1 -print -quit)" ] || fail 'existing work directory was modified'

# The exact confirmation token is parsed, but a live campaign still validates every prerequisite
# before creating output or running an engine. This deliberately missing app keeps the test offline.
expect_rejected live-preflight \
  --engines dory \
  --dory-app "$TMP_ROOT/missing/Dory.app" \
  --confirm-destructive-purge DELETE-SELECTED-ENGINE-DATA

# Exercise every documented selector plus numeric/path options. The fake commands turn any accidental
# execution into a hard failure and an auditable marker. A nonexistent Dory.app is valid for planning.
dry_work="$TMP_ROOT/dry-work"
: > "$MUTATION_LOG"
safe_env CAMPAIGN_WORKDIR="$TMP_ROOT/ignored-env-work" "$HARNESS" \
  --engines orbstack,colima,podman,dory \
  --profiles default,pinned \
  --dory-app "$TMP_ROOT/Release Build/Dory.app" \
  --metrics memory,build \
  --pinned-cpus 4 \
  --pinned-memory-gb 5 \
  --runs 3 \
  --memory-count 7 \
  --socket-wait 45 \
  --work "$dry_work" \
  --dry-run > "$TMP_ROOT/dry.tsv" 2> "$TMP_ROOT/dry.err"

assert_no_mutation dry-run "$dry_work"
[ ! -e "$TMP_ROOT/ignored-env-work" ] || fail 'CLI --work did not safely override CAMPAIGN_WORKDIR'
grep -Fq 'no installs, starts, measurements, files, or purge commands are executed' "$TMP_ROOT/dry.err"
grep -Fq 'engines=orbstack,colima,podman,dory profiles=default,pinned pinned=4cpu/5GB runs=3' "$TMP_ROOT/dry.err"
awk -F '\t' '
  NR == 1 {
    if ($0 != "engine\tprofile\tresult\tresult_dir\tdetail") exit 1
    next
  }
  {
    rows++
    if ($3 != "DRY" || $5 != "dry-run") exit 1
    key=$1 "/" $2
    count[key]++
  }
  END {
    if (rows != 8) exit 1
    if (count["orbstack/default"] != 1 || count["orbstack/pinned"] != 1 ||
        count["colima/default"] != 1 || count["colima/pinned"] != 1 ||
        count["podman/default"] != 1 || count["podman/pinned"] != 1 ||
        count["dory/default"] != 1 || count["dory/pinned"] != 1) exit 1
  }
' "$TMP_ROOT/dry.tsv" || fail 'dry-run did not honor the requested engine/profile matrix'

echo 'benchmark-campaign offline safety tests passed'
