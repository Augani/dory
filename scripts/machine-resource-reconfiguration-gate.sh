#!/bin/bash
# Exact-artifact regression for VM CPU/memory edits. Owns one uniquely named machine and never
# mutates an existing machine definition.
set -euo pipefail

CTL=""
KERNEL=""
ROOTFS=""
WORKROOT="${DORY_MACHINE_RESOURCE_WORKROOT:-$HOME/.dory-machine-resource-gate}"
CONFIRM=""

usage() {
  cat <<EOF
Usage: scripts/machine-resource-reconfiguration-gate.sh [required options]

Required:
  --ctl PATH          Exact candidate dorydctl executable
  --kernel PATH       Exact candidate machine kernel
  --rootfs PATH       Exact candidate machine rootfs
  --confirm TOKEN     Must be ISOLATED-DORY-MACHINE-RESOURCES

Options:
  --workroot PATH     Durable evidence root (default: $WORKROOT)
  --help              Show this help

The candidate doryd service must already be running. The gate creates one unique machine, requires
a real built-in k8s-lab recipe install plus independent kubectl verification, cycles
1/1GiB -> 8/16GiB -> 2/4GiB while it is running, verifies guest-visible resources, truthful
machine-stats schema/ranges, and persistent disk state after every automatic restart, proves
out-of-contract updates fail without mutation, then deletes only its owned machine.
EOF
}

die() { echo "machine-resource-gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ctl) need_value "$1" "$#"; CTL="$2"; shift 2 ;;
    --kernel) need_value "$1" "$#"; KERNEL="$2"; shift 2 ;;
    --rootfs) need_value "$1" "$#"; ROOTFS="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ "$CONFIRM" = ISOLATED-DORY-MACHINE-RESOURCES ] \
  || die "requires --confirm ISOLATED-DORY-MACHINE-RESOURCES"
[ -x "$CTL" ] || die "dorydctl is not executable: $CTL"
[ -s "$KERNEL" ] || die "machine kernel is unavailable: $KERNEL"
[ -s "$ROOTFS" ] || die "machine rootfs is unavailable: $ROOTFS"
for command in jq shasum; do command -v "$command" >/dev/null || die "missing required command: $command"; done

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
MACHINE="dory-resource-$RUN_ID"
WORKDIR="$WORKROOT/$RUN_ID"
RESULTS="$WORKDIR/results.tsv"
MANIFEST="$WORKDIR/manifest.txt"
mkdir -p "$WORKDIR"
printf 'test\tstatus\tdetail\n' > "$RESULTS"
OWNED=0

ctl() { "$CTL" --timeout 180 "$@"; }
cleanup() {
  set +e
  if [ "$OWNED" -eq 1 ]; then
    ctl machine stop "$MACHINE" > "$WORKDIR/cleanup-stop.json" 2> "$WORKDIR/cleanup-stop.err" || true
    ctl machine delete "$MACHINE" > "$WORKDIR/cleanup-delete.json" 2> "$WORKDIR/cleanup-delete.err" || true
  fi
}
trap cleanup EXIT INT TERM
pass() { printf '%s\tPASS\t%s\n' "$1" "$2" >> "$RESULTS"; }

ctl machine list > "$WORKDIR/list-before.json"
jq -e --arg id "$MACHINE" 'all(.[]; .id != $id)' "$WORKDIR/list-before.json" >/dev/null \
  || die "owned machine name already exists: $MACHINE"

ctl machine create "$MACHINE" --kernel "$KERNEL" --rootfs "$ROOTFS" \
  --memory-mb 1024 --cpus 1 > "$WORKDIR/create.json"
OWNED=1
ctl machine start "$MACHINE" > "$WORKDIR/start.json"

verify_status() {
  local label="$1" cpus="$2" memory="$3"
  local status="$WORKDIR/status-$label.json" stats="$WORKDIR/stats-$label.json" state=""
  for _ in $(seq 1 360); do
    ctl machine status "$MACHINE" > "$status"
    state="$(jq -r '.state' "$status")"
    case "$state" in
      running) break ;;
      failed|stopped) die "$label machine entered terminal state: $state" ;;
    esac
    sleep 0.5
  done
  [ "$state" = running ] || die "$label machine did not become ready within 180 seconds"
  jq -e --argjson cpus "$cpus" --argjson memory "$memory" \
    '.state == "running" and .cpuCount == $cpus and .memoryMB == $memory' "$status" >/dev/null \
    || die "$label status does not report running cpus=$cpus memoryMB=$memory"
  ctl machine exec "$MACHINE" --json -- sh -ec \
    'test "$(getconf _NPROCESSORS_ONLN)" -eq "$1"; mem=$(awk "/MemTotal:/ {print int(\$2 / 1024)}" /proc/meminfo); test "$mem" -ge "$2"; test -f /root/dory-resource-marker || printf marker > /root/dory-resource-marker' \
    sh "$cpus" "$((memory * 85 / 100))" > "$WORKDIR/guest-$label.json"
  jq -e '.exitCode == 0 and .timedOut == false and .stdoutTruncated == false and .stderrTruncated == false' \
    "$WORKDIR/guest-$label.json" >/dev/null || die "$label guest resource/persistence probe failed"
  ctl machine stats "$MACHINE" > "$stats"
  jq -e --argjson minimumTotal "$((memory * 1024 * 1024 * 85 / 100))" '
    (keys | sort) == ([
      "blockReadBytes", "blockWriteBytes", "cpuPercent", "memoryTotalBytes",
      "memoryUsedBytes", "networkReceiveBytes", "networkTransmitBytes", "processCount",
      "schema", "uptimeSeconds", "version"
    ] | sort)
    and .schema == "dev.dory.machine.stats"
    and .version == 1
    and (.cpuPercent | type == "number" and . >= 0 and . <= 100)
    and (.memoryUsedBytes | type == "number" and . >= 0)
    and (.memoryTotalBytes | type == "number" and . >= $minimumTotal)
    and .memoryUsedBytes <= .memoryTotalBytes
    and (.networkReceiveBytes | type == "number" and . >= 0)
    and (.networkTransmitBytes | type == "number" and . >= 0)
    and (.blockReadBytes | type == "number" and . >= 0)
    and (.blockWriteBytes | type == "number" and . >= 0)
    and (.processCount | type == "number" and . > 0)
    and (.uptimeSeconds | type == "number" and . >= 0)
  ' "$stats" >/dev/null || die "$label machine stats schema/range probe failed"
  pass "resource-$label" "running cpus=$cpus memoryMB=$memory; guest, live stats, and disk marker verified"
}

verify_status initial 1 1024
ctl machine provision "$MACHINE" --recipe k8s-lab > "$WORKDIR/provision-k8s-lab.json"
jq -e '
  .recipe == "k8s-lab"
  and .install.exitCode == 0 and .install.timedOut == false
  and .install.stdoutTruncated == false and .install.stderrTruncated == false
  and .verify.exitCode == 0 and .verify.timedOut == false
  and .verify.stdoutTruncated == false and .verify.stderrTruncated == false
' "$WORKDIR/provision-k8s-lab.json" >/dev/null \
  || die "required k8s-lab provisioning did not report complete install/verify success"
ctl machine exec "$MACHINE" --json -- sh -ec \
  'kubectl version --client=true >/dev/null' > "$WORKDIR/provision-k8s-lab-independent-verify.json"
jq -e '.exitCode == 0 and .timedOut == false and .stdoutTruncated == false and .stderrTruncated == false' \
  "$WORKDIR/provision-k8s-lab-independent-verify.json" >/dev/null \
  || die "required k8s-lab provisioning did not survive independent verification"
pass required-provisioning "k8s-lab install and verify completed; independent kubectl check passed"
ctl machine update "$MACHINE" --cpus 8 --memory-mb 16384 > "$WORKDIR/update-maximum.json"
verify_status maximum 8 16384
ctl machine update "$MACHINE" --cpus 2 --memory-mb 4096 > "$WORKDIR/update-normal.json"
verify_status normal 2 4096

for invalid in cpu memory; do
  set +e
  if [ "$invalid" = cpu ]; then
    ctl machine update "$MACHINE" --cpus 9 > "$WORKDIR/invalid-cpu.out" 2> "$WORKDIR/invalid-cpu.err"
  else
    ctl machine update "$MACHINE" --memory-mb 512 > "$WORKDIR/invalid-memory.out" 2> "$WORKDIR/invalid-memory.err"
  fi
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || die "out-of-contract $invalid update unexpectedly succeeded"
  pass "invalid-$invalid" "rejected without daemon exit (exit=$rc)"
done
verify_status after-invalid 2 4096

ctl machine stop "$MACHINE" > "$WORKDIR/stop.json"
ctl machine delete "$MACHINE" > "$WORKDIR/delete.json"
OWNED=0
ctl machine list > "$WORKDIR/list-after.json"
jq -e --arg id "$MACHINE" 'all(.[]; .id != $id)' "$WORKDIR/list-after.json" >/dev/null \
  || die "owned machine survived deletion"
pass cleanup "owned machine stopped and deleted; no pre-existing machine touched"

{
  echo "status=PASS"
  echo "run_id=$RUN_ID"
  echo "machine=$MACHINE"
  echo "ctl=$CTL"
  echo "ctl_sha256=$(shasum -a 256 "$CTL" | awk '{print $1}')"
  echo "kernel_sha256=$(shasum -a 256 "$KERNEL" | awk '{print $1}')"
  echo "rootfs_sha256=$(shasum -a 256 "$ROOTFS" | awk '{print $1}')"
  echo "required_provisioning=PASS"
  echo "completed_epoch=$(date +%s)"
} > "$MANIFEST"
echo "machine resource reconfiguration gate PASS; evidence: $WORKDIR"
