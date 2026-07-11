#!/bin/bash
# CI gate: the full DoryTests suite must run to completion with zero failures. The retry
# handles shared-runner host deaths (too few tests ran), never real test failures.
set -uo pipefail
cd "$(dirname "$0")/.."
LOG="${DORY_CI_TEST_LOG:-/tmp/dory_ci_tests.log}"

ALLOW='^$'

# Gate on the doctor helper's own tests: without `set -e` a failing exit here would be swallowed
# by the pipefail-only shell, letting CI pass on a broken diagnostic surface.
if ! bash scripts/test-dory-doctor.sh; then
  echo "ci-test: dory-doctor test suite failed" >&2
  exit 1
fi

# Benchmark publication is a product surface too. This gate is entirely offline: it validates the
# external-network harness's argument checks, balanced schedule, metadata parsing, and failure rows.
if ! bash scripts/test-benchmark-external-network.sh; then
  echo "ci-test: external-network benchmark tests failed" >&2
  exit 1
fi
if ! bash scripts/test-benchmark-user-workflows.sh; then
  echo "ci-test: user-workflow benchmark tests failed" >&2
  exit 1
fi

# The installed-engine host-share suite is deliberately disruptive, but its safety rails and
# guest-side coordination logic are testable without contacting Docker. Keep that offline contract
# in CI so the live gate cannot silently lose ownership checks, cleanup containment, or Bash 3.2
# compatibility.
if ! bash scripts/test-live-hostshare-integration.sh; then
  echo "ci-test: live host-share harness offline tests failed" >&2
  exit 1
fi

# Guest control has one authoritative handshake+mux+protobuf implementation. Shell tooling either
# reaches it through typed surfaces or fails closed for RPCs that do not exist yet.
if ! bash scripts/test-agent-protocol-consumers.sh; then
  echo "ci-test: agent protocol consumer tests failed" >&2
  exit 1
fi

# Compatibility surface: structural tier runs without an engine, so gate CI on it too.
if ! bash scripts/compat-smoke.sh; then
  echo "ci-test: compatibility smoke failed" >&2
  exit 1
fi

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
