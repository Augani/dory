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
require_source 'dev.dory.guest-resources' dory-core-swift/Sources/DorydKit/DockerTier.swift \
  "guest memory/disk response is not versioned"
require_source 'decodeGuestResourceSnapshot' dory-core-swift/Sources/DorydKit/DockerTier.swift \
  "guest memory/disk response lacks an exact bounded decoder"
require_source 'file-service-resources.json' Packages/ContainerizationEngine/Sources/dory-hv/FileServiceResourcePublisher.swift \
  "bounded file-service resource snapshot is missing"
require_source 'dev.dory.file-service.resources' Packages/ContainerizationEngine/Sources/dory-hv/FileServiceResourcePublisher.swift \
  "versioned file-service resource schema is missing"
require_source 'fileServiceResourceSnapshot' dory-core-swift/Sources/DorydKit/DockerTier.swift \
  "bounded file-service resource decoder is missing"
require_source 'exactJSONKeys' dory-core-swift/Sources/DorydKit/DockerTier.swift \
  "file-service decoder no longer rejects schema expansion"
require_source 'observationActive' dory-core-swift/Sources/DorydKit/DockerTier.swift \
  "file-service decoder no longer requires a live observation stream"
require_source 'kFSEventStreamCreateFlagIgnoreSelf' Packages/ContainerizationEngine/Sources/DoryFSWorkerServiceCore/DoryFSWorkerHostCoherence.swift \
  "worker-local guest-write self suppression is missing"
require_source 'kFSEventStreamCreateFlagFileEvents' Packages/ContainerizationEngine/Sources/DoryFSWorkerServiceCore/DoryFSWorkerHostCoherence.swift \
  "exact host child event observation is missing"
require_source 'FSEventsGetCurrentEventId' Packages/ContainerizationEngine/Sources/DoryFSWorkerServiceCore/DoryFSWorkerHostCoherence.swift \
  "preactivation event checkpoint is missing"
require_source 'kFSEventStreamEventFlagHistoryDone' Packages/ContainerizationEngine/Sources/DoryFSWorkerServiceCore/DoryFSWorkerHostCoherence.swift \
  "observation activation no longer waits for FSEvents catch-up"
require_source 'activateCoherence' Packages/ContainerizationEngine/Sources/DoryFSWorkerContracts/DoryFSWorkerXPC.swift \
  "post-handler coherence activation handshake is missing"
require_source 'DoryFSWorkerCoherenceAcknowledgement' Packages/ContainerizationEngine/Sources/DoryFSWorkerContracts/DoryFSWorkerCoherence.swift \
  "exact retained-batch acknowledgement contract is missing"
require_source 'guard coherenceExchange != nil' Packages/ContainerizationEngine/Sources/DoryFSWorkerServiceCore/DoryFSWorkerService.swift \
  "coherence policy can be advertised without an enforcement exchange"
require_source 'share.readOnly || configuration.genericGuest' Packages/ContainerizationEngine/Sources/dory-hv/DesktopMode.swift \
  "generic desktop media no longer stays within invalidation-only capability"
require_source 'resources.file_service_failed' dory-core-swift/Sources/DorydKit/HealthReporter.swift \
  "terminal file-service coherence loss is not reported as a failure"

engine_activation_line="$(grep -nF 'try filesystemWorker.client.activateCoherence()' Packages/ContainerizationEngine/Sources/dory-hv/EngineMode.swift | head -1 | cut -d: -f1)"
engine_guest_line="$(grep -nF 'let stop = try machineRunner.runToCompletion()' Packages/ContainerizationEngine/Sources/dory-hv/EngineMode.swift | head -1 | cut -d: -f1)"
[ -n "$engine_activation_line" ] && [ -n "$engine_guest_line" ] \
  && [ "$engine_activation_line" -lt "$engine_guest_line" ] \
  || fail "engine coherence activation is not ordered before guest execution"
desktop_activation_line="$(grep -nF 'try filesystemWorker.client.activateCoherence()' Packages/ContainerizationEngine/Sources/dory-hv/DesktopMode.swift | head -1 | cut -d: -f1)"
desktop_guest_line="$(grep -nF 'try startMachine()' Packages/ContainerizationEngine/Sources/dory-hv/DesktopMode.swift | head -1 | cut -d: -f1)"
[ -n "$desktop_activation_line" ] && [ -n "$desktop_guest_line" ] \
  && [ "$desktop_activation_line" -lt "$desktop_guest_line" ] \
  || fail "desktop coherence activation is not ordered before guest execution"
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
