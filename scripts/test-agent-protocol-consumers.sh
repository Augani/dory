#!/bin/bash
# Offline regression gate for shell consumers of the guest-control surface. These scripts must use
# typed DoryCore/doryd paths (or fail closed), never revive the retired BE-length + JSON protocol.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

bash -n scripts/dory
bash -n scripts/readiness.sh

if grep -Eq 'struct\.pack\(">I"|debug\.shell|^[[:space:]]*agent_rpc(_readiness)?\(\)' \
  scripts/dory scripts/readiness.sh; then
  echo "legacy JSON agent wire consumer found" >&2
  exit 1
fi

set +e
debug_output="$(scripts/dory debug example 2>&1)"
debug_status=$?
set -e
[ "$debug_status" -eq 2 ]
printf '%s\n' "$debug_output" | grep -q 'protocol v1 has no namespace-debug RPC'

clock_body="$(sed -n '/^test_clock_sync() {/,/^}/p' scripts/readiness.sh)"
printf '%s\n' "$clock_body" | grep -q 'dorydctl docker clock-sync'
if printf '%s\n' "$clock_body" | grep -Eq 'date[[:space:]].*-s|kill[[:space:]]+-USR1|--privileged'; then
  echo "clock readiness must not mutate a live VM or signal an unchecked PID" >&2
  exit 1
fi

grep -q 'dory-agent protocol v1 has no guest vhci attach/detach RPC' scripts/readiness.sh
grep -q 'dory-agent protocol v1 has no namespace-debug RPC' scripts/readiness.sh

echo "agent protocol shell consumers: ok"
