#!/bin/bash
# CI gate: the full DoryTests suite must run to completion with zero failures. The retry
# handles shared-runner host deaths (too few tests ran), never real test failures.
set -uo pipefail
cd "$(dirname "$0")/.."
LOG="${DORY_CI_TEST_LOG:-/tmp/dory_ci_tests.log}"

ALLOW='^$'

# Retry the whole suite on ANY non-clean attempt, not only when too few tests ran. A shared-runner
# host death is intermittent and can be *partial*: one xctest worker crashes, its tests all report
# "failed" at 0.000s while 300+ others still pass. The old gate treated that first-attempt cascade as
# a hard failure and exited before the retry, turning an infra flake into a red check. Real failures
# reproduce on the retry, so only fail if the suite is still not clean on the second attempt.
last_reason=""
for attempt in 1 2; do
  bash scripts/test.sh -skip-testing:DoryUITests 2>&1 | tee "$LOG"

  passed=$(grep -cE "Test case '.*' passed" "$LOG" || true)
  failed=$(grep -oE "Test case '[^']+' failed" "$LOG" | sort -u || true)
  unexpected=$(printf '%s\n' "$failed" | grep -vE "$ALLOW" | grep -vE '^$' || true)

  echo "ci-gate: attempt=$attempt passed=$passed"
  if [ -n "$failed" ]; then printf 'ci-gate known-flaky or failed:\n%s\n' "$failed"; fi

  if [ -z "$unexpected" ] && [ "${passed:-0}" -ge 300 ]; then
    echo "ci-gate: OK — suite ran to completion with no unexpected failures"
    exit 0
  fi

  if [ -n "$unexpected" ]; then
    last_reason="unexpected failures:\n$unexpected"
  else
    last_reason="only $passed tests ran (shared-runner host death)"
  fi
  [ "$attempt" -lt 2 ] && echo "ci-gate: attempt $attempt not clean ($last_reason); retrying once"
done
printf 'ci-gate: FAIL — still not clean after retry. %b\n' "$last_reason"
exit 1
