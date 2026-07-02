#!/bin/bash
# CI gate: the full DoryTests suite must run to completion with zero failures. The retry
# handles shared-runner host deaths (too few tests ran), never real test failures.
set -uo pipefail
cd "$(dirname "$0")/.."
LOG="${DORY_CI_TEST_LOG:-/tmp/dory_ci_tests.log}"

ALLOW='^$'

for attempt in 1 2; do
  bash scripts/test.sh -skip-testing:DoryUITests 2>&1 | tee "$LOG"

  passed=$(grep -cE "Test case '.*' passed" "$LOG" || true)
  failed=$(grep -oE "Test case '[^']+' failed" "$LOG" | sort -u || true)
  unexpected=$(printf '%s\n' "$failed" | grep -vE "$ALLOW" | grep -vE '^$' || true)

  echo "ci-gate: attempt=$attempt passed=$passed"
  if [ -n "$failed" ]; then printf 'ci-gate known-flaky or failed:\n%s\n' "$failed"; fi

  if [ -n "$unexpected" ]; then
    printf 'ci-gate: FAIL — unexpected failures:\n%s\n' "$unexpected"
    exit 1
  fi
  if [ "${passed:-0}" -ge 300 ]; then
    echo "ci-gate: OK — suite ran to completion; failures (if any) are known timing flakes"
    exit 0
  fi
  echo "ci-gate: only $passed tests ran (shared-runner host death); retrying once"
done
echo "ci-gate: FAIL — host died mid-suite on both attempts"
exit 1
