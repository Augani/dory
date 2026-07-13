#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-sleep-evidence.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

COMMIT=0123456789abcdef0123456789abcdef01234567
RUN_ID=1234
ATTEMPT=2
CUSTOM_DNS=10.20.30.40
PROBE_HOST=registry.corp.example
PROBE_URL=https://registry.corp.example/v2/
TAILSCALE_EXIT_NODE=release-exit-node.example.ts.net
APP="$TMP/Dory.app"
EVIDENCE="$TMP/evidence"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$EVIDENCE"
printf app > "$APP/Contents/MacOS/Dory"
printf docker > "$APP/Contents/Helpers/docker"
printf doryd > "$APP/Contents/Helpers/doryd"
printf hv > "$APP/Contents/Helpers/dory-hv"
printf ctl > "$APP/Contents/Helpers/dorydctl"
printf kernel > "$APP/Contents/Resources/dory-hv-kernel-arm64"
printf rootfs > "$APP/Contents/Resources/dory-machine-rootfs-arm64.ext4"

sha() { shasum -a 256 "$1" | awk '{print $1}'; }
text_sha() { printf '%s' "$1" | shasum -a 256 | awk '{print $1}'; }
cat > "$EVIDENCE/manifest.txt" <<EOF
run_id=20260712T120000Z-123
cycles=5
auto_wake_seconds=30
physical_sleep=true
wifi_required=true
vpn_required=true
custom_dns_required=true
route_churn=PASS
route_churn_rounds=3
release_qualifying=true
source_commit=$COMMIT
github_run_id=$RUN_ID
github_run_attempt=$ATTEMPT
app_executable_sha256=$(sha "$APP/Contents/MacOS/Dory")
docker_sha256=$(sha "$APP/Contents/Helpers/docker")
doryd_sha256=$(sha "$APP/Contents/Helpers/doryd")
dory_hv_sha256=$(sha "$APP/Contents/Helpers/dory-hv")
dorydctl_sha256=$(sha "$APP/Contents/Helpers/dorydctl")
machine_kernel_sha256=$(sha "$APP/Contents/Resources/dory-hv-kernel-arm64")
machine_rootfs_sha256=$(sha "$APP/Contents/Resources/dory-machine-rootfs-arm64.ext4")
machine_id=dory-sleep-session-20260712T120000Z-123
machine_session_reconnect=PASS
custom_dns_sha256=$(text_sha "$CUSTOM_DNS")
probe_host_sha256=$(text_sha "$PROBE_HOST")
probe_url_sha256=$(text_sha "$PROBE_URL")
tailscale_exit_node_sha256=$(text_sha "$TAILSCALE_EXIT_NODE")
EOF
printf 'round\tphase\tstatus\tdetail\n' > "$EVIDENCE/route-churn-results.tsv"
for round in 1 2 3; do
  printf '%s\texit-node-active\tPASS\thost/container/API remained reachable\n' "$round" \
    >> "$EVIDENCE/route-churn-results.tsv"
  printf '%s\tbaseline-restored\tPASS\troute/DNS/proxy contract and Docker recovered\n' \
    "$round" >> "$EVIDENCE/route-churn-results.tsv"
  for phase in enabled restored; do
    route_dir="$EVIDENCE/route-churn-$round-$phase"
    mkdir -p "$route_dir"
    printf '{"BackendState":"Running"}\n' > "$route_dir/tailscale-status.json"
  done
  for contract in default-route dns proxy service-dns resolvers; do
    : > "$EVIDENCE/route-churn-$round-restored/$contract.contract.diff"
  done
done
printf 'cycle\tphase\tstatus\tdetail\n' > "$EVIDENCE/results.tsv"
for cycle in 1 2 3 4 5; do
  printf '%s\tmachine-session-pre-sleep\tPASS\tinteractive shell ready token observed\n' \
    "$cycle" >> "$EVIDENCE/results.tsv"
  printf '%s\tpre-sleep\tPASS\tcontract and probes healthy\n' "$cycle" >> "$EVIDENCE/results.tsv"
  printf '%s\tsleep-resume\tPASS\telapsed_seconds=30 scheduled_wake_seconds=30\n' \
    "$cycle" >> "$EVIDENCE/results.tsv"
  printf '%s\tpost-wake\tPASS\thost/container probes and network contract preserved\n' \
    "$cycle" >> "$EVIDENCE/results.tsv"
  printf '%s\tmachine-session-reconnect\tPASS\tfresh exec, stop/start, and disk marker verified\n' \
    "$cycle" >> "$EVIDENCE/results.tsv"
  printf 'DORY_SESSION_READY_%s_20260712T120000Z-123\n' "$cycle" \
    > "$EVIDENCE/cycle-$cycle-machine-shell.out"
  for pair in machine-status-after-wake:running machine-status-stopped:stopped \
    machine-status-restarted:running; do
    suffix="${pair%%:*}"
    state="${pair#*:}"
    printf '{"id":"dory-sleep-session-20260712T120000Z-123","state":"%s"}\n' "$state" \
      > "$EVIDENCE/cycle-$cycle-$suffix.json"
  done
  for pair in machine-reconnect:dory-machine-reconnect \
    machine-restart-persistence:dory-machine-restart; do
    suffix="${pair%%:*}"
    token="${pair#*:}-$cycle"
    printf '{"schema":"dev.dory.machine.exec","version":1,"machine":"dory-sleep-session-20260712T120000Z-123","exitCode":0,"timedOut":false,"stdout":"%s","stdoutTruncated":false,"stderrTruncated":false}\n' \
      "$token" > "$EVIDENCE/cycle-$cycle-$suffix.json"
  done
  printf 'Scheduled wake event\n' > "$EVIDENCE/cycle-$cycle-scheduled-wake.txt"
  printf 'Entering Sleep\nDarkWake\nWake from Normal Sleep\n' > "$EVIDENCE/cycle-$cycle-pmset-log.txt"
  mkdir -p "$EVIDENCE/cycle-$cycle-after"
  printf 'fixture contract\n' > "$EVIDENCE/cycle-$cycle-after/contract.sha256"
  for contract in default-route dns proxy service-dns resolvers; do
    : > "$EVIDENCE/cycle-$cycle-after/$contract.contract.diff"
  done
done

verify() {
  scripts/verify-sleep-wake-evidence.py \
    --manifest "$1/manifest.txt" \
    --results "$1/results.tsv" \
    --evidence-root "$1" \
    --app "$APP" \
    --source-commit "$COMMIT" \
    --run-id "$RUN_ID" \
    --run-attempt "$ATTEMPT" \
    --cycles 5 \
    --auto-wake-seconds 30 \
    --custom-dns "$CUSTOM_DNS" \
    --probe-host "$PROBE_HOST" \
    --probe-url "$PROBE_URL" \
    --tailscale-exit-node "$TAILSCALE_EXIT_NODE"
}

verify "$EVIDENCE" >/dev/null

expect_failure() {
  local fixture="$1" label="$2"
  if verify "$fixture" >/dev/null 2>&1; then
    echo "test-sleep-wake-evidence: accepted $label" >&2
    exit 1
  fi
}

cp -R "$EVIDENCE" "$TMP/failed-row"
sed -i '' $'s/1\tpost-wake\tPASS/1\tpost-wake\tFAIL/' "$TMP/failed-row/results.tsv"
expect_failure "$TMP/failed-row" "a failed post-wake row"

cp -R "$EVIDENCE" "$TMP/missing-machine-reconnect"
sed -i '' $'/1\tmachine-session-reconnect\t/d' "$TMP/missing-machine-reconnect/results.tsv"
expect_failure "$TMP/missing-machine-reconnect" "a missing post-sleep machine reconnect"

cp -R "$EVIDENCE" "$TMP/wedged-machine-stop"
sed -i '' 's/"state":"stopped"/"state":"running"/' \
  "$TMP/wedged-machine-stop/cycle-2-machine-status-stopped.json"
expect_failure "$TMP/wedged-machine-stop" "a machine stop that remained wedged"

cp -R "$EVIDENCE" "$TMP/short-sleep"
sed -i '' 's/elapsed_seconds=30/elapsed_seconds=1/' "$TMP/short-sleep/results.tsv"
expect_failure "$TMP/short-sleep" "a sleep command that returned immediately"

cp -R "$EVIDENCE" "$TMP/no-wake-log"
printf 'Entering Sleep only\n' > "$TMP/no-wake-log/cycle-3-pmset-log.txt"
expect_failure "$TMP/no-wake-log" "a pmset log without a wake event"

cp -R "$EVIDENCE" "$TMP/changed-contract"
printf 'route changed\n' > "$TMP/changed-contract/cycle-4-after/default-route.contract.diff"
expect_failure "$TMP/changed-contract" "a changed post-wake network contract"

cp -R "$EVIDENCE" "$TMP/wrong-private-network"
sed -i '' 's/vpn_required=true/vpn_required=false/' "$TMP/wrong-private-network/manifest.txt"
expect_failure "$TMP/wrong-private-network" "a non-VPN sleep campaign"

cp -R "$EVIDENCE" "$TMP/route-churn-not-restored"
printf 'default route remained on exit node\n' \
  > "$TMP/route-churn-not-restored/route-churn-2-restored/default-route.contract.diff"
expect_failure "$TMP/route-churn-not-restored" "an exit-node route that did not self-heal"

cp -R "$EVIDENCE" "$TMP/wrong-app"
printf tampered > "$APP/Contents/Helpers/doryd"
expect_failure "$TMP/wrong-app" "a sleep result bound to different candidate binaries"

echo "test-sleep-wake-evidence: PASS"
