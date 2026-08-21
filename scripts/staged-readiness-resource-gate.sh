#!/bin/bash
# Static contract gate by default; --live verifies an installed doryd without mutating workloads.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE=static
case "${1:-}" in
  "") ;;
  --live) MODE=live ;;
  -h|--help)
    echo "usage: scripts/staged-readiness-resource-gate.sh [--live]"
    exit 0
    ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac
cd "$ROOT"

fail() { echo "staged readiness/resource gate failed: $*" >&2; exit 1; }
require_source() {
  local pattern="$1" file="$2" label="$3"
  grep -F "$pattern" "$file" >/dev/null || fail "$label"
}

require_source 'dev.dory.readiness' dory-core-swift/Sources/DorydKit/Readiness.swift \
  "versioned readiness schema is missing"
for stage in app doryd vmProcess guestAgent mountsDataDisk network dockerd hostSocketContext kubernetes; do
  require_source "case $stage" dory-core-swift/Sources/DorydKit/Readiness.swift \
    "readiness stage $stage is missing"
done
require_source 'destructive: Bool = false' dory-core-swift/Sources/DorydKit/Readiness.swift \
  "bounded repairs no longer state their non-destructive contract"
require_source 'promotionWaiters' dory-core-swift/Sources/DorydKit/DockerTier.swift \
  "promotion is no longer event/condition driven"
require_source 'repairSocketForwarder' dory-core-swift/Sources/DorydKit/DockerTier.swift \
  "socket-only repair is missing"
require_source 'repairDockerDaemon' dory-core-swift/Sources/DorydKit/DockerTier.swift \
  "dockerd-only repair is missing"
require_source 'guestResourceSnapshot' dory-core-swift/Sources/DorydKit/DockerTier.swift \
  "guest memory/disk composition probe is missing"
require_source 'host-share-resources.json' Packages/ContainerizationEngine/Sources/dory-hv/EngineMode.swift \
  "host-share watcher/backpressure snapshot is missing"
for check in resources.processes resources.guest resources.file_service resources.trend network.resources disk.reclaimable; do
  require_source "id: \"$check\"" dory-core-swift/Sources/DorydKit/HealthReporter.swift \
    "health surface omits $check"
done
require_source 'dory readiness [--json]' scripts/dory \
  "CLI does not expose the staged contract"

[ "$MODE" = live ] || { echo "staged readiness/resource gate: PASS (static)"; exit 0; }

CTL="${DORYDCTL:-}"
if [ -z "$CTL" ]; then
  for candidate in \
    "$ROOT/dory-core-swift/.build/debug/dorydctl" \
    "$HOME/.dory/bin/dorydctl" \
    "/Applications/Dory.app/Contents/Helpers/dorydctl"; do
    if [ -x "$candidate" ]; then CTL="$candidate"; break; fi
  done
fi
[ -x "$CTL" ] || fail "dorydctl not found; set DORYDCTL to the exact installed candidate helper"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-staged-readiness.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
"$CTL" health > "$TMP/health.json"
python3 - "$TMP/health.json" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
readiness = report.get("readiness")
assert isinstance(readiness, dict)
assert readiness.get("schema") == "dev.dory.readiness"
assert readiness.get("version") == 1
expected = [
    "app", "doryd", "vmProcess", "guestAgent", "mountsDataDisk", "network",
    "dockerd", "hostSocketContext", "kubernetes",
]
stages = readiness.get("stages")
assert isinstance(stages, list) and [stage.get("id") for stage in stages] == expected
for stage in stages:
    assert stage.get("state") in {"waiting", "ready", "degraded", "blocked", "inactive"}
    assert isinstance(stage.get("reasonCode"), str) and stage["reasonCode"]
    assert isinstance(stage.get("repair"), dict)
    assert stage["repair"].get("owner")
    assert stage["repair"].get("mutation")
    assert stage["repair"].get("destructive") is False
    if stage.get("required"):
        assert stage.get("deadlineAt")

results = {item.get("id"): item for item in report.get("results", [])}
for check in (
    "memory.footprint", "resources.processes", "resources.guest",
    "resources.file_service", "resources.trend", "network.resources",
    "disk.dory_drive", "disk.reclaimable",
):
    assert check in results, check
assert results["disk.reclaimable"].get("data", {}).get("mutation_performed") in {None, "false"}
print("staged readiness/resource gate: PASS (live)")
PY
