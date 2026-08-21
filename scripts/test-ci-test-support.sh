#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=ci-test-support.sh
source scripts/ci-test-support.sh

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-ci-parser.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

assert_count() {
  local expected="$1" fixture="$2" actual
  actual="$(dory_ci_count_completed_tests "$fixture")"
  if [ "$actual" != "$expected" ]; then
    echo "ci-test parser: expected $expected completed tests, got $actual for $fixture" >&2
    exit 1
  fi
}

printf '%s\n' \
  'Test alpha() passed after 0.001 seconds.' \
  'Test run with 616 tests in 95 suites passed after 9.750 seconds.' \
  > "$TMP/swift-testing.log"
assert_count 616 "$TMP/swift-testing.log"

printf '%s\n' \
  "Test case '-[DoryTests.LegacyTests testOne]' passed (0.001 seconds)." \
  'Executed 423 tests, with 0 failures (0 unexpected) in 12.000 seconds' \
  > "$TMP/xctest.log"
assert_count 423 "$TMP/xctest.log"

printf '%s\n' \
  'Executed 10 tests, with 0 failures (0 unexpected) in 1.000 seconds' \
  'Executed 220 tests, with 0 failures (0 unexpected) in 2.000 seconds' \
  'Test run with 125 tests in 20 suites passed after 3.000 seconds.' \
  > "$TMP/mixed-runners.log"
assert_count 345 "$TMP/mixed-runners.log"

printf '%s\n' \
  'Test first() passed after 0.001 seconds.' \
  'Test second() passed after 0.001 seconds.' \
  > "$TMP/interrupted.log"
assert_count 2 "$TMP/interrupted.log"

printf '%s\n' \
  'Test brokenPath() failed after 0.001 seconds with 1 issue.' \
  'DoryTests/File.swift:10: error: expectation failed' \
  > "$TMP/failure.log"
failure_lines="$(dory_ci_failure_lines "$TMP/failure.log")"
printf '%s' "$failure_lines" | grep -q 'brokenPath' || {
  echo 'ci-test parser: Swift Testing failure line was not retained' >&2
  exit 1
}
printf '%s' "$failure_lines" | grep -q 'expectation failed' || {
  echo 'ci-test parser: compiler-style error line was not retained' >&2
  exit 1
}

echo 'ci-test log parser tests passed'
