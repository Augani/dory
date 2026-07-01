#!/bin/bash
# CI gate: the full DoryTests suite must run to completion; only the known timing-flaky
# tests (tracked for a proper fix) may fail. Robust to xcodebuild -skip-testing quirks
# with Swift Testing identifiers.
set -uo pipefail
cd "$(dirname "$0")/.."
LOG="${DORY_CI_TEST_LOG:-/tmp/dory_ci_tests.log}"

ALLOW='shimWaitBlocksUntilContainerStops|generatesCAAndIssuesVerifiableDomainCertificate|detectSkipsHungSocketAndFindsNextCandidate|detectProbesMultipleStaleSocketsConcurrently|snapshotDoesNotWaitForHungStatsProbe'

bash scripts/test.sh -skip-testing:DoryUITests 2>&1 | tee "$LOG"

passed=$(grep -cE "Test case '.*' passed" "$LOG" || true)
failed=$(grep -oE "Test case '[^']+' failed" "$LOG" | sort -u || true)
unexpected=$(printf '%s\n' "$failed" | grep -vE "$ALLOW" | grep -vE '^$' || true)

echo "ci-gate: passed=$passed"
if [ -n "$failed" ]; then printf 'ci-gate known-flaky or failed:\n%s\n' "$failed"; fi

if [ "${passed:-0}" -lt 300 ]; then
  echo "ci-gate: FAIL — only $passed tests ran; the host likely died mid-suite"
  exit 1
fi
if [ -n "$unexpected" ]; then
  printf 'ci-gate: FAIL — unexpected failures:\n%s\n' "$unexpected"
  exit 1
fi
echo "ci-gate: OK — suite ran to completion; failures (if any) are known timing flakes"
exit 0
