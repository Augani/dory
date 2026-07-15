#!/bin/bash
# Exercise the exact Dory.app candidate on clean physical hardware. The public Apple-silicon gate
# additionally proves that the persisted GPU + amd64 settings reach launchd, the GPU-specific guest
# kernel, dory-hv, the Venus renderer, /dev/dri, and a real non-native BuildKit workload. The Intel
# release gate uses the same harness with notarization disabled only for its same-commit ad-hoc
# candidate, then runs the strict physical-Intel readiness suite.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="${1:?usage: release-candidate-live-smoke.sh <notarized Dory.app>}"
case "$APP" in /*) ;; *) APP="$ROOT/$APP" ;; esac
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
EXECUTABLE="$APP/Contents/MacOS/Dory"
DORY_CLI="$APP/Contents/Helpers/dory"
DOCKER_CLI="$APP/Contents/Helpers/docker"
SERVICE="gui/$(id -u)/dev.dory.doryd"
PLIST="$HOME/Library/LaunchAgents/dev.dory.doryd.plist"
STATE="$HOME/.dory"
APP_SUPPORT="$HOME/Library/Application Support/Dory"
PREF_DOMAIN="com.pythonxi.Dory"
LOG_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/dory-release-live-${GITHUB_RUN_ID:-$$}"
REQUIRED_ARCH="${DORY_RELEASE_LIVE_REQUIRED_ARCH:-arm64}"
REQUIRE_NOTARIZED="${DORY_RELEASE_LIVE_REQUIRE_NOTARIZED:-1}"
REQUIRE_PHYSICAL_INTEL="${DORY_RELEASE_LIVE_REQUIRE_PHYSICAL_INTEL:-0}"
EXTERNAL_VOLUME_ROOT="${DORY_RELEASE_EXTERNAL_VOLUME_ROOT:-}"
LOCK_IMAGE="${DORY_RELEASE_LOCK_IMAGE:-}"
FIXTURE_IMAGE="${DORY_RELEASE_FIXTURE_IMAGE:-}"
NONNATIVE_BUILD_IMAGE="${DORY_RELEASE_NONNATIVE_BUILD_IMAGE:-}"
SSH_CLIENT_IMAGE="${DORY_RELEASE_SSH_CLIENT_IMAGE:-}"
RUN_PHYSICAL_SLEEP="${DORY_RELEASE_RUN_PHYSICAL_SLEEP:-0}"
CORPORATE_DNS="${DORY_RELEASE_CORPORATE_DNS_SERVER:-}"
CORPORATE_PROBE_HOST="${DORY_RELEASE_CORPORATE_VPN_PROBE_HOST:-}"
CORPORATE_PROBE_URL="${DORY_RELEASE_CORPORATE_VPN_PROBE_URL:-}"
TAILSCALE_EXIT_NODE="${DORY_RELEASE_TAILSCALE_EXIT_NODE:-}"
APP_PID=""
PREVIOUS_CONTEXT="default"
PROFILE_PATHS=("$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.profile")
PROFILE_EXISTED=()

fail() {
  echo "release live smoke error: $*" >&2
  exit 1
}

cleanup() {
  local profile index
  set +e
  mkdir -p "$LOG_ROOT"
  [ -f "$STATE/doryd.log" ] && cp "$STATE/doryd.log" "$LOG_ROOT/doryd.log"
  [ -f "$STATE/hv/dory-hv.log" ] && cp "$STATE/hv/dory-hv.log" "$LOG_ROOT/dory-hv.log"
  [ -f "$PLIST" ] && cp "$PLIST" "$LOG_ROOT/dev.dory.doryd.plist"
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    "$DORY_CLI" engine sleep >/dev/null 2>&1 || true
    kill -TERM "$APP_PID" 2>/dev/null || true
    for _ in $(seq 1 60); do
      kill -0 "$APP_PID" 2>/dev/null || break
      sleep 0.5
    done
    kill -KILL "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
  "$DORY_CLI" uninstall >/dev/null 2>&1 || true
  "$DOCKER_CLI" context use "$PREVIOUS_CONTEXT" >/dev/null 2>&1 || true
  "$DOCKER_CLI" context rm -f dory >/dev/null 2>&1 || true
  rm -f "$PLIST"
  rm -rf "$STATE" "$APP_SUPPORT"
  defaults delete "$PREF_DOMAIN" >/dev/null 2>&1 || true
  for index in "${!PROFILE_PATHS[@]}"; do
    profile="${PROFILE_PATHS[$index]}"
    if [ "${PROFILE_EXISTED[$index]}" = "0" ] && [ -f "$profile" ] \
       && ! grep -q '[^[:space:]]' "$profile"; then
      rm -f "$profile"
    fi
  done
}

[ "$(uname -s)" = Darwin ] || fail "live release candidate requires macOS"
case "$REQUIRED_ARCH" in
  arm64|x86_64) ;;
  *) fail "DORY_RELEASE_LIVE_REQUIRED_ARCH must be arm64 or x86_64" ;;
esac
case "$REQUIRE_NOTARIZED:$REQUIRE_PHYSICAL_INTEL" in
  0:0|0:1|1:0|1:1) ;;
  *) fail "live-gate boolean settings must be 0 or 1" ;;
esac
case "$RUN_PHYSICAL_SLEEP" in 0|1) ;;
  *) fail "DORY_RELEASE_RUN_PHYSICAL_SLEEP must be 0 or 1" ;;
esac
[ "$RUN_PHYSICAL_SLEEP" = 0 ] || [ "$REQUIRED_ARCH:$REQUIRE_NOTARIZED" = arm64:1 ] \
  || fail "physical sleep/wake is valid only for the notarized Apple-silicon candidate"
if [ "$RUN_PHYSICAL_SLEEP" = 1 ]; then
  [ -n "$CORPORATE_DNS" ] \
    || fail "DORY_RELEASE_CORPORATE_DNS_SERVER is required for physical release qualification"
  [ -n "$CORPORATE_PROBE_HOST" ] \
    || fail "DORY_RELEASE_CORPORATE_VPN_PROBE_HOST is required for physical release qualification"
  [ -n "$CORPORATE_PROBE_URL" ] \
    || fail "DORY_RELEASE_CORPORATE_VPN_PROBE_URL is required for physical release qualification"
  [ -n "$TAILSCALE_EXIT_NODE" ] \
    || fail "DORY_RELEASE_TAILSCALE_EXIT_NODE is required for physical release qualification"
fi
[ "$(uname -m)" = "$REQUIRED_ARCH" ] \
  || fail "candidate requires physical $REQUIRED_ARCH hardware; this host is $(uname -m)"
[ "$(sysctl -n kern.hv_support 2>/dev/null || printf 0)" = 1 ] \
  || fail "Hypervisor.framework is unavailable (hosted/nested macOS runners cannot satisfy the live gate)"
if [ "$REQUIRED_ARCH" = arm64 ]; then
  [ "$(sysctl -in kern.hv_vmm_present 2>/dev/null || printf 0)" != 1 ] \
    || fail "nested Virtualization.framework host detected; physical hardware is required"
  case "$(sysctl -n hw.model 2>/dev/null || printf unknown)" in
    VirtualMac*) fail "VirtualMac hosts do not qualify as physical release hardware" ;;
  esac
  [ "${DORY_RELEASE_PHYSICAL_ARM64_CONFIRMED:-0}" = 1 ] \
    || fail "physical Apple-silicon host facts were not independently recorded"
  [ -n "$EXTERNAL_VOLUME_ROOT" ] \
    || fail "DORY_RELEASE_EXTERNAL_VOLUME_ROOT must name dedicated writable external APFS test media"
  [ -d "$EXTERNAL_VOLUME_ROOT" ] \
    || fail "external APFS release test root is unavailable: $EXTERNAL_VOLUME_ROOT"
  printf '%s\n' "$LOCK_IMAGE" | grep -Eq '@sha256:[0-9a-f]{64}$' \
    || fail "DORY_RELEASE_LOCK_IMAGE must be a digest-pinned image containing python3"
  printf '%s\n' "$FIXTURE_IMAGE" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
    || fail "DORY_RELEASE_FIXTURE_IMAGE must be a digest-pinned Alpine image"
  printf '%s\n' "$NONNATIVE_BUILD_IMAGE" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
    || fail "DORY_RELEASE_NONNATIVE_BUILD_IMAGE must be a digest-pinned amd64 Node/Alpine image"
  printf '%s\n' "$SSH_CLIENT_IMAGE" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
    || fail "DORY_RELEASE_SSH_CLIENT_IMAGE must be a digest-pinned image containing ssh-add"
  [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ] \
    || fail "physical release qualification requires a live SSH_AUTH_SOCK"
  ssh-add -L >/dev/null 2>&1 \
    || fail "physical release qualification requires at least one loaded SSH-agent identity"
fi
[ -x "$EXECUTABLE" ] || fail "candidate app executable is missing: $EXECUTABLE"
[ -x "$DORY_CLI" ] || fail "candidate Dory CLI is missing: $DORY_CLI"
[ -x "$DOCKER_CLI" ] || fail "candidate Docker CLI is missing: $DOCKER_CLI"
codesign --verify --strict --deep "$APP" || fail "candidate app signature is invalid"
if [ "$REQUIRE_NOTARIZED" = 1 ]; then
  xcrun stapler validate "$APP" || fail "candidate app has no valid notarization ticket"
fi
if [ "$REQUIRE_PHYSICAL_INTEL" = 1 ]; then
  [ "$REQUIRED_ARCH" = x86_64 ] || fail "the physical Intel readiness gate requires x86_64"
  [ "${READINESS_PHYSICAL_INTEL_CONFIRMED:-0}" = 1 ] \
    || fail "Intel host facts were not independently recorded before the live gate"
fi

if launchctl print "$SERVICE" >/dev/null 2>&1; then
  fail "dev.dory.doryd is already loaded; use a clean dedicated release user"
fi
[ ! -e "$PLIST" ] || fail "existing Dory LaunchAgent would be overwritten: $PLIST"
[ ! -e "$STATE" ] || fail "existing Dory state would be touched: $STATE"
[ ! -e "$APP_SUPPORT" ] || fail "existing Dory application state would be touched: $APP_SUPPORT"
if defaults read "$PREF_DOMAIN" >/dev/null 2>&1; then
  fail "existing Dory preferences would be touched; use a clean dedicated release user"
fi
for process in Dory doryd dory-hv dory-vmm; do
  if pgrep -u "$(id -u)" -x "$process" >/dev/null 2>&1; then
    fail "$process is already running; use a clean dedicated release user"
  fi
done
for profile in "${PROFILE_PATHS[@]}"; do
  if [ -f "$profile" ]; then PROFILE_EXISTED+=(1); else PROFILE_EXISTED+=(0); fi
  if [ -f "$profile" ] && grep -Fq '# >>> dory cli >>>' "$profile"; then
    fail "existing Dory shell integration would be touched: $profile"
  fi
done
if "$DOCKER_CLI" context inspect dory >/dev/null 2>&1; then
  fail "existing Docker context 'dory' would be touched"
fi
PREVIOUS_CONTEXT="$($DOCKER_CLI context show 2>/dev/null || printf default)"
[ -n "$PREVIOUS_CONTEXT" ] || PREVIOUS_CONTEXT=default

mkdir -p "$LOG_ROOT"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
defaults write "$PREF_DOMAIN" dory.hasCompletedOnboarding -bool true
defaults write "$PREF_DOMAIN" dory.keepDorydRunningAfterQuit -bool false
if [ "$REQUIRED_ARCH" = arm64 ]; then
  defaults write "$PREF_DOMAIN" dory.experimentalGPU -bool true
  defaults write "$PREF_DOMAIN" dory.rosettaX86Enabled -bool true
  EXPECTED_GPU=venus
  EXPECTED_AMD64=1
else
  defaults write "$PREF_DOMAIN" dory.experimentalGPU -bool false
  defaults write "$PREF_DOMAIN" dory.rosettaX86Enabled -bool false
  EXPECTED_GPU=off
  EXPECTED_AMD64=0
fi

"$EXECUTABLE" >"$LOG_ROOT/app.stdout.log" 2>"$LOG_ROOT/app.stderr.log" &
APP_PID=$!

ready=0
for _ in $(seq 1 360); do
  kill -0 "$APP_PID" 2>/dev/null || {
    tail -100 "$LOG_ROOT/app.stderr.log" >&2 || true
    fail "candidate app exited before its Docker socket became ready"
  }
  if [ -S "$STATE/dory.sock" ] \
     && curl -fsS --max-time 2 --unix-socket "$STATE/dory.sock" http://d/_ping >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.5
done
[ "$ready" = 1 ] || fail "candidate app did not boot its bundled engine within 180 seconds"
"$DOCKER_CLI" buildx version >/dev/null \
  || fail "candidate did not install its bundled Docker Buildx plugin on the clean release account"

launch_state="$(launchctl print "$SERVICE")" || fail "candidate app did not load dev.dory.doryd"
printf '%s\n' "$launch_state" > "$LOG_ROOT/launchctl-print.txt"
grep -Fq "program = $APP/Contents/Helpers/doryd" <<< "$launch_state" \
  || fail "loaded daemon does not come from the release candidate app"
grep -Eq 'exit timeout = 45([[:space:]]|$)' <<< "$launch_state" \
  || fail "loaded daemon does not honor the 45-second graceful shutdown contract"
[ "$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:DORYD_GPU' "$PLIST")" = "$EXPECTED_GPU" ] \
  || fail "candidate LaunchAgent did not persist DORYD_GPU=$EXPECTED_GPU"
[ "$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:DORYD_AMD64' "$PLIST")" = "$EXPECTED_AMD64" ] \
  || fail "candidate LaunchAgent did not persist DORYD_AMD64=$EXPECTED_AMD64"
grep -Eq "DORYD_GPU[^[:alnum:]_]+$EXPECTED_GPU([^[:alnum:]_]|$)" <<< "$launch_state" \
  || fail "loaded daemon environment does not contain DORYD_GPU=$EXPECTED_GPU"
grep -Eq "DORYD_AMD64[^[:alnum:]_]+$EXPECTED_AMD64([^[:alnum:]_]|$)" <<< "$launch_state" \
  || fail "loaded daemon environment does not contain DORYD_AMD64=$EXPECTED_AMD64"

hv_pid_list="$(pgrep -u "$(id -u)" -x dory-hv || true)"
hv_pid_count="$(printf '%s\n' "$hv_pid_list" | awk 'NF { count++ } END { print count + 0 }')"
[ "$hv_pid_count" -eq 1 ] \
  || fail "expected exactly one candidate dory-hv helper, found $hv_pid_count"
hv_pid="$(printf '%s\n' "$hv_pid_list" | awk 'NF { print; exit }')"
hv_command="$(ps -ww -p "$hv_pid" -o command=)"
printf '%s\n' "$hv_command" > "$LOG_ROOT/dory-hv-command.txt"
grep -Fq "$APP/Contents/Helpers/dory-hv" <<< "$hv_command" \
  || fail "running dory-hv helper does not come from the candidate app: $hv_command"

if [ "$REQUIRED_ARCH" = arm64 ]; then
  gpu_kernel="$STATE/hv/assets/dory-hv-kernel-gpu-arm64"
  hv_log="$STATE/hv/dory-hv.log"
  [ -s "$gpu_kernel" ] || fail "GPU-specific candidate kernel was not prepared at $gpu_kernel"
  grep -Fq -- "--kernel $gpu_kernel" <<< "$hv_command" \
    || fail "dory-hv did not select the prepared GPU kernel: $hv_command"
  grep -Eq -- '(^|[[:space:]])--gpu[[:space:]]+venus([[:space:]]|$)' <<< "$hv_command" \
    || fail "dory-hv was not launched with --gpu venus: $hv_command"
  grep -Eq -- '(^|[[:space:]])--amd64([[:space:]]|$)' <<< "$hv_command" \
    || fail "dory-hv was not launched with non-native amd64 support: $hv_command"

  renderer_ready=0
  for _ in $(seq 1 120); do
    if [ -f "$hv_log" ] \
       && grep -F 'experimental gpu=venus: attached virtio-gpu with virglrenderer ' "$hv_log" \
          | grep -Fq ' and MoltenVK ICD '; then
      renderer_ready=1
      break
    fi
    sleep 0.5
  done
  [ "$renderer_ready" = 1 ] \
    || fail "dory-hv log does not prove that virglrenderer and MoltenVK attached in Venus mode"

  "$DOCKER_CLI" -H "unix://$STATE/dory.sock" run --rm \
    --device /dev/dri/renderD128 "$FIXTURE_IMAGE" \
    sh -c 'test -c /dev/dri/renderD128'

  binfmt_ready=0
  for _ in $(seq 1 90); do
    if "$DOCKER_CLI" -H "unix://$STATE/dory.sock" run --rm --privileged "$FIXTURE_IMAGE" \
       sh -c 'test -e /proc/sys/fs/binfmt_misc/FEX-x86_64 && grep -qx enabled /proc/sys/fs/binfmt_misc/FEX-x86_64 && grep -qx "flags: POCF" /proc/sys/fs/binfmt_misc/FEX-x86_64' \
       >/dev/null 2>&1; then
      binfmt_ready=1
      break
    fi
    sleep 1
  done
  [ "$binfmt_ready" = 1 ] \
    || fail "candidate did not register seccomp-correct FEX-x86_64 after the persisted amd64 opt-in"

  DORY_SOCK="$STATE/dory.sock" DORY_DOCKER_BIN="$DOCKER_CLI" \
    READINESS_ALPINE_IMAGE="$FIXTURE_IMAGE" \
    scripts/nonnative-build-smoke.sh \
      --target amd64 --socket "$STATE/dory.sock" --docker "$DOCKER_CLI" \
      --image "$NONNATIVE_BUILD_IMAGE"

  scripts/machine-resource-reconfiguration-gate.sh \
    --ctl "$APP/Contents/Helpers/dorydctl" \
    --kernel "$APP/Contents/Resources/dory-hv-kernel-arm64" \
    --rootfs "$APP/Contents/Resources/dory-machine-rootfs-arm64.ext4" \
    --workroot "$LOG_ROOT/machine-resource" \
    --confirm ISOLATED-DORY-MACHINE-RESOURCES

  scripts/external-volume-bind-gate.sh \
    --socket "$STATE/dory.sock" \
    --docker "$DOCKER_CLI" \
    --dory "$DORY_CLI" \
    --state-dir "$STATE/hv" \
    --path "$EXTERNAL_VOLUME_ROOT" \
    --image "$FIXTURE_IMAGE" \
    --workroot "$LOG_ROOT/external-volume" \
    --confirm ISOLATED-EXTERNAL-APFS-BIND \
    --disconnect-confirm DISCONNECT-RECONNECT-DEDICATED-APFS

  scripts/bind-advisory-lock-gate.sh \
    --socket "$STATE/dory.sock" \
    --docker "$DOCKER_CLI" \
    --image "$LOCK_IMAGE" \
    --workroot "$LOG_ROOT/bind-advisory-lock" \
    --confirm ISOLATED-DORY-BIND-LOCKS

  scripts/ssh-agent-forwarding-gate.sh \
    --socket "$STATE/dory.sock" \
    --docker "$DOCKER_CLI" \
    --image "$SSH_CLIENT_IMAGE" \
    --workroot "$LOG_ROOT/ssh-agent"

  if [ "$RUN_PHYSICAL_SLEEP" = 1 ]; then
    DORY_NETWORK_INTEGRITY_SOURCE_COMMIT="${GITHUB_SHA:-}" \
      DORY_NETWORK_INTEGRITY_IMAGE="$FIXTURE_IMAGE" \
      scripts/host-network-integrity-gate.sh \
        --socket "$STATE/dory.sock" \
        --docker "$DOCKER_CLI" \
        --app "$APP" \
        --cycles 5 \
        --auto-wake-seconds 30 \
        --workroot "$LOG_ROOT/sleep-wake" \
        --require-vpn \
        --custom-dns "$CORPORATE_DNS" \
        --probe-host "$CORPORATE_PROBE_HOST" \
        --probe-url "$CORPORATE_PROBE_URL" \
        --tailscale-exit-node "$TAILSCALE_EXIT_NODE" \
        --confirm-route-churn VPN-ROUTE-CHURN \
        --confirm-physical-sleep SLEEP-AND-WAKE-THIS-MAC
  fi
fi

DORY_APP="$APP" \
DORY_CLI_BIN="$DORY_CLI" \
DORY_DOCTOR_BIN="$APP/Contents/Helpers/dory-doctor" \
DORY_DOCKER_BIN="$DOCKER_CLI" \
DORY_SOCK="$STATE/dory.sock" \
DORY_ENGINE_SOCK="$STATE/hv/engine.sock" \
DORY_P0_STOP_WAKE=1 \
DORY_P0_IMAGE="$FIXTURE_IMAGE" \
DORY_COMPAT_IMAGE="$FIXTURE_IMAGE" \
  scripts/p0-smoke.sh

if [ "$REQUIRE_PHYSICAL_INTEL" = 1 ]; then
  PATH="$APP/Contents/Helpers:$PATH" \
  DORY_SOCK="$STATE/dory.sock" \
  READINESS_STRICT=1 \
  READINESS_REQUIRE_PHYSICAL_INTEL=1 \
    scripts/readiness.sh --engines dory --strict --require-physical-intel
fi

echo "release candidate live smoke: PASS"
