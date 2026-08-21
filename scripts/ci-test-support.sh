#!/bin/bash

# Return the completed-test count that Xcode reported. A single invocation can contain distinct
# XCTest and Swift Testing runners, so take the largest aggregate from each runner and add them.
# Individual pass lines remain a last-resort signal for an interrupted runner with no summary.
dory_ci_count_completed_tests() {
  local log="$1" swift_summary xctest_summary individual total

  swift_summary="$(sed -nE 's/.*Test run with ([0-9]+) tests.*/\1/p' "$log" \
    | awk '$1 > maximum { maximum=$1 } END { if (maximum != "") print maximum }')"
  xctest_summary="$(sed -nE 's/.*Executed ([0-9]+) tests.*/\1/p' "$log" \
    | awk '$1 > maximum { maximum=$1 } END { if (maximum != "") print maximum }')"
  total=0
  case "$swift_summary" in ''|*[!0-9]*) ;; *) total=$((total + swift_summary)) ;; esac
  case "$xctest_summary" in ''|*[!0-9]*) ;; *) total=$((total + xctest_summary)) ;; esac
  if [ "$total" -gt 0 ]; then
    printf '%s\n' "$total"
    return
  fi

  individual="$(grep -cE "Test case '[^']+' passed|Test .+\(.*\) passed after" "$log" || true)"
  printf '%s\n' "$individual"
}

dory_ci_failure_lines() {
  local log="$1"
  grep -E "Test case '[^']+' failed|Test .+ failed after|(^|[^[:alpha:]])error:" "$log" \
    | tail -50 || true
}
