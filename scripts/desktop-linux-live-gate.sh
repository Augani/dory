#!/bin/bash
# Boot and exercise every managed desktop with the exact signed release candidate. This gate is
# intentionally destructive only to its uniquely named temporary machines and work directory.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CTL=""
COMPONENT_DIR=""
KERNEL=""
DEBIAN_ROOTFS=""
UBUNTU_ROOTFS=""
KALI_ROOTFS=""
DEBIAN_UPDATE=""
UBUNTU_UPDATE=""
KALI_UPDATE=""
ZED_ARCHIVE=""
ZED_VERSION=""
ZED_SHA256=""
DESKTOP_VERSION=""
SELECTED_DISTRO="all"
WORKROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/dory-desktop-linux-live"
CONFIRM=""

usage() {
  echo "usage: desktop-linux-live-gate.sh --ctl PATH --component-dir PATH --kernel PATH [--distro all|debian|ubuntu|kali] [desktop assets] --zed-archive PATH --zed-version VERSION --zed-sha256 SHA256 --version VERSION --workroot PATH --confirm EXACT-CANDIDATE-DESKTOPS" >&2
  exit 64
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ctl) CTL="${2:?missing path}"; shift 2 ;;
    --component-dir) COMPONENT_DIR="${2:?missing path}"; shift 2 ;;
    --kernel) KERNEL="${2:?missing path}"; shift 2 ;;
    --debian-rootfs) DEBIAN_ROOTFS="${2:?missing path}"; shift 2 ;;
    --ubuntu-rootfs) UBUNTU_ROOTFS="${2:?missing path}"; shift 2 ;;
    --kali-rootfs) KALI_ROOTFS="${2:?missing path}"; shift 2 ;;
    --debian-update) DEBIAN_UPDATE="${2:?missing path}"; shift 2 ;;
    --ubuntu-update) UBUNTU_UPDATE="${2:?missing path}"; shift 2 ;;
    --kali-update) KALI_UPDATE="${2:?missing path}"; shift 2 ;;
    --zed-archive) ZED_ARCHIVE="${2:?missing path}"; shift 2 ;;
    --zed-version) ZED_VERSION="${2:?missing version}"; shift 2 ;;
    --zed-sha256) ZED_SHA256="${2:?missing digest}"; shift 2 ;;
    --distro) SELECTED_DISTRO="${2:?missing distro}"; shift 2 ;;
    --version) DESKTOP_VERSION="${2:?missing version}"; shift 2 ;;
    --workroot) WORKROOT="${2:?missing path}"; shift 2 ;;
    --confirm) CONFIRM="${2:?missing confirmation}"; shift 2 ;;
    *) usage ;;
  esac
done

[ "$CONFIRM" = EXACT-CANDIDATE-DESKTOPS ] || usage
case "$SELECTED_DISTRO" in
  all|debian|ubuntu|kali) ;;
  *) echo "desktop live gate: unsupported distro selection: $SELECTED_DISTRO" >&2; exit 64 ;;
esac
[ -x "$CTL" ] || { echo "desktop live gate: missing dorydctl: $CTL" >&2; exit 66; }
[ -d "$COMPONENT_DIR" ] && [ ! -L "$COMPONENT_DIR" ] \
  || { echo "desktop live gate: missing component candidate directory: $COMPONENT_DIR" >&2; exit 66; }
HELPERS="$(cd "$(dirname "$CTL")" && pwd)"
VMM="$HELPERS/dory-hv"
VZ_VMM="$HELPERS/dory-vmm"
[ -x "$VMM" ] || { echo "desktop live gate: accelerated candidate dory-hv is missing: $VMM" >&2; exit 66; }
[ -x "$VZ_VMM" ] || { echo "desktop live gate: fallback candidate dory-vmm is missing: $VZ_VMM" >&2; exit 66; }
assets=("$KERNEL" "$ZED_ARCHIVE")
case "$SELECTED_DISTRO" in
  all) assets+=("$DEBIAN_ROOTFS" "$UBUNTU_ROOTFS" "$KALI_ROOTFS" "$DEBIAN_UPDATE" "$UBUNTU_UPDATE" "$KALI_UPDATE") ;;
  debian) assets+=("$DEBIAN_ROOTFS" "$DEBIAN_UPDATE") ;;
  ubuntu) assets+=("$UBUNTU_ROOTFS" "$UBUNTU_UPDATE") ;;
  kali) assets+=("$KALI_ROOTFS" "$KALI_UPDATE") ;;
esac
for asset in "${assets[@]}"; do
  [ -f "$asset" ] && [ ! -L "$asset" ] && [ -s "$asset" ] \
    || { echo "desktop live gate: missing regular asset: $asset" >&2; exit 66; }
done
absolute_asset() {
  local asset_input="$1"
  local asset_directory
  asset_directory="$(cd "$(dirname "$asset_input")" && pwd -P)"
  printf '%s/%s\n' "$asset_directory" "$(basename "$asset_input")"
}
KERNEL="$(absolute_asset "$KERNEL")"
ZED_ARCHIVE="$(absolute_asset "$ZED_ARCHIVE")"
COMPONENT_DIR="$(cd "$COMPONENT_DIR" && pwd -P)"
case "$SELECTED_DISTRO" in
  all)
    DEBIAN_ROOTFS="$(absolute_asset "$DEBIAN_ROOTFS")"
    UBUNTU_ROOTFS="$(absolute_asset "$UBUNTU_ROOTFS")"
    KALI_ROOTFS="$(absolute_asset "$KALI_ROOTFS")"
    DEBIAN_UPDATE="$(absolute_asset "$DEBIAN_UPDATE")"
    UBUNTU_UPDATE="$(absolute_asset "$UBUNTU_UPDATE")"
    KALI_UPDATE="$(absolute_asset "$KALI_UPDATE")"
    ;;
  debian)
    DEBIAN_ROOTFS="$(absolute_asset "$DEBIAN_ROOTFS")"
    DEBIAN_UPDATE="$(absolute_asset "$DEBIAN_UPDATE")"
    ;;
  ubuntu)
    UBUNTU_ROOTFS="$(absolute_asset "$UBUNTU_ROOTFS")"
    UBUNTU_UPDATE="$(absolute_asset "$UBUNTU_UPDATE")"
    ;;
  kali)
    KALI_ROOTFS="$(absolute_asset "$KALI_ROOTFS")"
    KALI_UPDATE="$(absolute_asset "$KALI_UPDATE")"
    ;;
esac
printf '%s\n' "$DESKTOP_VERSION" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$' \
  || { echo "desktop live gate: invalid desktop version: $DESKTOP_VERSION" >&2; exit 64; }
printf '%s\n' "$ZED_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || { echo "desktop live gate: invalid Zed version: $ZED_VERSION" >&2; exit 64; }
printf '%s\n' "$ZED_SHA256" | grep -Eq '^[0-9a-f]{64}$' \
  || { echo "desktop live gate: invalid Zed digest" >&2; exit 64; }
[ "$(shasum -a 256 "$ZED_ARCHIVE" | awk '{print $1}')" = "$ZED_SHA256" ] \
  || { echo "desktop live gate: Zed archive digest mismatch" >&2; exit 66; }
[ -n "${RUNNER_TEMP:-}" ] \
  || { echo "desktop live gate: RUNNER_TEMP must identify the dedicated release workspace" >&2; exit 64; }
case "$RUNNER_TEMP" in /*) ;; *) echo "desktop live gate: RUNNER_TEMP must be absolute" >&2; exit 64 ;; esac
case "$WORKROOT" in /*) ;; *) echo "desktop live gate: workroot must be absolute" >&2; exit 64 ;; esac
[ ! -L "$WORKROOT" ] \
  || { echo "desktop live gate: workroot must not be a symlink" >&2; exit 64; }
WORKROOT="$(python3 - "$RUNNER_TEMP" "$WORKROOT" <<'PY'
import os
import sys

runner, requested = map(os.path.realpath, sys.argv[1:])
if requested == runner or not requested.startswith(runner.rstrip(os.sep) + os.sep):
    raise SystemExit("workroot must be a strict child of RUNNER_TEMP")
print(requested)
PY
)" || { echo "desktop live gate: unsafe workroot: $WORKROOT" >&2; exit 64; }

rm -rf "$WORKROOT"
mkdir -p "$WORKROOT/share" "$WORKROOT/evidence"
printf 'Dory desktop release gate\n' > "$WORKROOT/share/host-marker.txt"
cp "$ZED_ARCHIVE" "$WORKROOT/share/zed-linux-aarch64.tar.gz"
[ "$(shasum -a 256 "$WORKROOT/share/zed-linux-aarch64.tar.gz" | awk '{print $1}')" = "$ZED_SHA256" ]
codesign --verify --strict "$VMM"
codesign -d --entitlements :- "$VMM" > "$WORKROOT/evidence/dory-hv-entitlements.plist" 2>&1
grep -q 'com.apple.security.hypervisor' "$WORKROOT/evidence/dory-hv-entitlements.plist"
grep -q 'com.apple.security.device.audio-input' "$WORKROOT/evidence/dory-hv-entitlements.plist"
grep -q 'com.apple.security.cs.disable-library-validation' "$WORKROOT/evidence/dory-hv-entitlements.plist"
codesign --verify --strict "$VZ_VMM"
codesign -d --entitlements :- "$VZ_VMM" > "$WORKROOT/evidence/dory-vmm-entitlements.plist" 2>&1
grep -q 'com.apple.security.virtualization' "$WORKROOT/evidence/dory-vmm-entitlements.plist"
grep -q 'com.apple.security.device.audio-input' "$WORKROOT/evidence/dory-vmm-entitlements.plist"
grep -q 'NSMicrophoneUsageDescription' "$HELPERS/../Info.plist"
ACTIVE_MACHINE=""
ZED_QUALIFIED=0

cleanup() {
  result=$?
  set +e
  if [ -n "$ACTIVE_MACHINE" ]; then
    "$CTL" machine stop "$ACTIVE_MACHINE" >/dev/null 2>&1 || true
    "$CTL" machine delete "$ACTIVE_MACHINE" >/dev/null 2>&1 || true
  fi
  trap - EXIT INT TERM
  exit "$result"
}
trap cleanup EXIT INT TERM

exec_json() {
  machine="$1"
  shift
  "$CTL" machine exec "$machine" --json --timeout-ms 120000 \
    --output-limit-bytes 262144 -- "$@"
}

assert_exec_token() {
  machine="$1"
  token="$2"
  shift 2
  output="$(exec_json "$machine" "$@")"
  if ! printf '%s\n' "$output" | python3 -c '
import json, sys
token = sys.argv[1]
body = json.load(sys.stdin)
if not isinstance(body, dict):
    raise SystemExit("exec response is not an object")
if body.get("exitCode") != 0 or body.get("timedOut") is not False:
    raise SystemExit(f"exec failed: {body!r}")
stdout = body.get("stdout")
if not isinstance(stdout, str) or token not in stdout:
    raise SystemExit(f"exec response omitted {token!r}: {body!r}")
' "$token"; then
    printf '%s\n' "$output" >&2
    return 1
  fi
  printf '%s\n' "$output"
}

wait_for_exec_token() {
  machine="$1"
  token="$2"
  shift 2
  for attempt in $(seq 1 60); do
    if output="$(assert_exec_token "$machine" "$token" "$@" 2>/dev/null)"; then
      printf '%s\n' "$output"
      return 0
    fi
    sleep 1
  done
  echo "desktop live gate: $machine did not satisfy $token readiness" >&2
  assert_exec_token "$machine" "$token" "$@"
}

wait_for_desktop() {
  machine="$1"
  manager="$2"
  session="$3"
  for attempt in $(seq 1 120); do
    if assert_exec_token "$machine" desktop-ready sh -lc \
      "systemctl is-active '$manager' >/dev/null && pgrep -u dorygate -x '$session' >/dev/null && echo desktop-ready" \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  "$CTL" machine status "$machine" >&2 || true
  echo "desktop live gate: $machine did not reach its graphical session" >&2
  return 1
}

wait_for_running() {
  machine="$1"
  for attempt in $(seq 1 240); do
    if "$CTL" machine status "$machine" 2>/dev/null | python3 -c '
import json, sys
body = json.load(sys.stdin)
raise SystemExit(0 if body.get("state") == "running" else 1)
'; then
      return 0
    fi
    sleep 0.25
  done
  "$CTL" machine status "$machine" >&2 || true
  echo "desktop live gate: $machine did not complete its ready handoff" >&2
  return 1
}

run_desktop() {
  distro="$1"
  rootfs="$2"
  manager="$3"
  session="$4"
  browser="$5"
  browser_pattern="$6"
  browser_desktop="$7"
  update_bundle="$8"
  shift 8
  expected_apps="$*"
  machine="dory-release-desktop-${distro}-$$"
  ACTIVE_MACHINE="$machine"

  component_id="desktop-$distro"
  candidate_result="$WORKROOT/evidence/$distro-component-import.json"
  "$CTL" component install-candidate "$component_id" \
    --candidate-dir "$COMPONENT_DIR" --json > "$candidate_result"
  selection="$WORKROOT/evidence/$distro-component-selection.txt"
  python3 - "$candidate_result" "$COMPONENT_DIR/catalog.json" \
    "$component_id" "$DESKTOP_VERSION" > "$selection" <<'PY'
import json
import pathlib
import re
import sys

result_path, catalog_path, component_id, expected_version = sys.argv[1:]
result = json.loads(pathlib.Path(result_path).read_text(encoding="utf-8"))
if not isinstance(result, dict) or set(result) != {
    "catalogDigest", "installations", "schema", "schemaVersion"
}:
    raise SystemExit("component import response has an unexpected shape")
if result["schema"] != "dev.dory.component-candidate-import" or result["schemaVersion"] != 1:
    raise SystemExit("component import response has an unexpected contract")
digest = result["catalogDigest"]
if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
    raise SystemExit("component import response has an invalid catalog digest")
installations = result["installations"]
if not isinstance(installations, dict) or set(installations) != {"linux-desktop", component_id}:
    raise SystemExit("component import response does not contain the exact desktop dependency set")
safe_id = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,254}")
for value in installations.values():
    if not isinstance(value, str) or safe_id.fullmatch(value) is None:
        raise SystemExit("component import response has an invalid installation identity")

catalog = json.loads(pathlib.Path(catalog_path).read_text(encoding="utf-8"))
if not isinstance(catalog, dict) or catalog.get("schemaVersion") != 2:
    raise SystemExit("signed component catalog is not schema 2")
if catalog.get("releaseVersion") != expected_version:
    raise SystemExit("signed component catalog release differs from the desktop candidate")
components = catalog.get("components")
if not isinstance(components, list):
    raise SystemExit("signed component catalog omits components")
matches = {
    row.get("id"): row for row in components
    if isinstance(row, dict) and row.get("id") in {"linux-desktop", component_id}
}
if set(matches) != {"linux-desktop", component_id}:
    raise SystemExit("signed component catalog omits the selected desktop components")
runtime_version = matches["linux-desktop"].get("version")
distribution_version = matches[component_id].get("version")
for value in (runtime_version, distribution_version):
    if not isinstance(value, str) or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,127}", value) is None:
        raise SystemExit("signed component version is invalid")

print(digest)
print(installations["linux-desktop"])
print(installations[component_id])
print(runtime_version)
print(distribution_version)
PY
  [ "$(wc -l < "$selection" | tr -d ' ')" = 5 ] \
    || { echo "desktop live gate: invalid component selection evidence" >&2; exit 1; }
  catalog_digest="$(sed -n '1p' "$selection")"
  runtime_installation="$(sed -n '2p' "$selection")"
  distribution_installation="$(sed -n '3p' "$selection")"
  runtime_version="$(sed -n '4p' "$selection")"
  distribution_version="$(sed -n '5p' "$selection")"
  update_version="$distribution_version+runtime.$runtime_version"

  "$CTL" component verify all --offline --json \
    > "$WORKROOT/evidence/$distro-component-verify.json"
  installed_kernel="$("$CTL" component path linux-desktop dory-desktop-kernel-arm64.lzfse)"
  installed_rootfs="$("$CTL" component path "$component_id" \
    "dory-desktop-$distro-rootfs-arm64.ext4.lzfse")"
  installed_update="$("$CTL" component path "$component_id" \
    "dory-desktop-$distro-update-arm64.tar")"
  for installed_asset in "$installed_kernel" "$installed_rootfs" "$installed_update"; do
    [ -f "$installed_asset" ] && [ ! -L "$installed_asset" ] && [ -s "$installed_asset" ] \
      || { echo "desktop live gate: installed component asset is invalid: $installed_asset" >&2; exit 1; }
  done
  cmp -s "$KERNEL" "$installed_kernel" \
    || { echo "desktop live gate: installed desktop kernel differs from the candidate" >&2; exit 1; }
  cmp -s "$rootfs" "$installed_rootfs" \
    || { echo "desktop live gate: installed $distro rootfs differs from the candidate" >&2; exit 1; }
  cmp -s "$update_bundle" "$installed_update" \
    || { echo "desktop live gate: installed $distro update differs from the candidate" >&2; exit 1; }

  if "$CTL" machine status "$machine" >/dev/null 2>&1; then
    echo "desktop live gate: refusing to overwrite existing machine $machine" >&2
    exit 1
  fi

  created="$WORKROOT/evidence/$distro-create.json"
  "$CTL" machine create "$machine" \
    --kernel "$installed_kernel" --rootfs "$installed_rootfs" --memory-mb 4096 --cpus 4 \
    --display-mode desktop \
    --share "releasegate=$WORKROOT/share:/home/dorygate/Mac:ro" \
    --guest-user dorygate --guest-uid 1550 \
    --desktop-distro "$distro" --runtime accelerated --graphics virgl-venus \
    --clipboard bidirectional > "$created"
  python3 - "$created" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    body = json.load(handle)
if not isinstance(body, dict) or body.get("state") != "created":
    raise SystemExit(f"machine create did not return created: {body!r}")
if body.get("displayMode") != "desktop":
    raise SystemExit(f"machine create did not retain desktop mode: {body!r}")
PY

  "$CTL" machine start "$machine" > "$WORKROOT/evidence/$distro-start.json"
  wait_for_desktop "$machine" "$manager" "$session"
  wait_for_running "$machine"
  "$CTL" machine status "$machine" > "$WORKROOT/evidence/$distro-running.json"
  machine_pid="$(python3 - "$WORKROOT/evidence/$distro-running.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    body = json.load(handle)
if not isinstance(body, dict) or body.get("state") != "running" \
        or body.get("displayMode") != "desktop":
    raise SystemExit(f"machine did not reach running desktop state: {body!r}")
pid = body.get("pid")
if not isinstance(pid, int) or pid <= 0:
    raise SystemExit(f"machine status has an invalid pid: {body!r}")
print(pid)
PY
)"
  ps -ww -p "$machine_pid" -o command= | grep -F "$VMM" \
    > "$WORKROOT/evidence/$distro-vmm-command.txt"
  grep -F -- '--resolved-graphics hardware-accelerated-3d' \
    "$WORKROOT/evidence/$distro-vmm-command.txt"

  app_checks=""
  for app in $expected_apps; do
    app_checks="$app_checks command -v '$app' >/dev/null;"
  done
  wait_for_exec_token "$machine" system-pass sh -lc "
    set -eu
    systemctl is-active '$manager' >/dev/null
    systemctl is-active dory-zram.service >/dev/null
    test \"\$(cat /run/dory/graphics-backend)\" = virgl2+venus
    grep -q '^venus-ready:' /run/dory/graphics-status
    grep -q '^/dev/zram0 ' /proc/swaps
    pgrep -u dorygate -x '$session' >/dev/null
    desktop_uid=\$(id -u dorygate)
    desktop_environment=\$(runuser -u dorygate -- env XDG_RUNTIME_DIR=\"/run/user/\$desktop_uid\" \
      DBUS_SESSION_BUS_ADDRESS=\"unix:path=/run/user/\$desktop_uid/bus\" \
      systemctl --user show-environment)
    printf '%s\n' \"\$desktop_environment\" | grep -Fqx 'MOZ_ENABLE_WAYLAND=0'
    printf '%s\n' \"\$desktop_environment\" | grep -Fqx 'GSK_RENDERER=gl'
    ethernet=\$(nmcli -t -f DEVICE,TYPE,STATE device status | awk -F: '\$2 ~ /^ethernet\$/ && \$3 ~ /^connected\$/ { print \$1; exit }')
    test -n \"\$ethernet\"
    ip -4 -o addr show dev \"\$ethernet\" | grep -q ' inet '
    test \"\$(nmcli -g GENERAL.CONNECTION device show \"\$ethernet\")\" = 'Dory Wired'
    test \"\$(readlink /etc/resolv.conf)\" = ../run/NetworkManager/resolv.conf
    getent ahostsv4 example.com >/dev/null
    test \"\$(curl -4 -fsS --max-time 30 -o /dev/null -w '%{http_code}' https://example.com)\" = 200
    command -v '$browser' >/dev/null
    command -v gio >/dev/null
    test -f '$browser_desktop'
    command -v xwininfo >/dev/null
    $app_checks
    grep -q 'virtio-snd' /proc/asound/cards
    grep -q 'playback' /proc/asound/pcm
    grep -q 'capture' /proc/asound/pcm
    audio_status=\$(runuser -u dorygate -- env XDG_RUNTIME_DIR=\"/run/user/\$desktop_uid\" \
      wpctl status)
    test \"\$(printf '%s\\n' \"\$audio_status\" | grep -Fc 'Dory Audio Pro')\" -ge 2
    runuser -u dorygate -- env XDG_RUNTIME_DIR=\"/run/user/\$desktop_uid\" \
      DBUS_SESSION_BUS_ADDRESS=\"unix:path=/run/user/\$desktop_uid/bus\" \
      timeout 15 aplay -D pipewire -q -t raw -f S16_LE -r 48000 -c 2 -d 1 /dev/zero
    runuser -u dorygate -- env XDG_RUNTIME_DIR=\"/run/user/\$desktop_uid\" \
      DBUS_SESSION_BUS_ADDRESS=\"unix:path=/run/user/\$desktop_uid/bus\" \
      timeout 15 arecord -D pipewire -q -t raw -f S16_LE -r 48000 -c 2 -d 1 /dev/null
    mountpoint -q /home/dorygate/Mac
    grep -qx 'Dory desktop release gate' /home/dorygate/Mac/host-marker.txt
    ! touch /home/dorygate/Mac/write-must-fail 2>/dev/null
    printf persistence-pass > /home/dorygate/.dory-release-marker
    echo system-pass
  " > "$WORKROOT/evidence/$distro-system.json"

  # Arm a receipt that can only be written by systemd while the guest is performing an orderly
  # shutdown. Merely terminating the VM helper cannot create this marker, so the subsequent boot
  # distinguishes graceful guest shutdown from the host watchdog fallback.
  assert_exec_token "$machine" graceful-shutdown-armed sh -lc "
    set -eu
    marker=/var/lib/dory/release-graceful-shutdown
    unit=/etc/systemd/system/dory-release-graceful-shutdown.service
    rm -f \"\$marker\"
    printf '%s\n' \
      '[Unit]' \
      'Description=Dory release gate graceful shutdown receipt' \
      'After=multi-user.target' \
      '' \
      '[Service]' \
      'Type=oneshot' \
      'ExecStart=/bin/true' \
      \"ExecStop=/bin/sh -c 'printf graceful-shutdown-pass > \$marker; sync'\" \
      'RemainAfterExit=yes' \
      '' \
      '[Install]' \
      'WantedBy=multi-user.target' > \"\$unit\"
    systemctl daemon-reload
    systemctl enable --now dory-release-graceful-shutdown.service >/dev/null
    systemctl is-active --quiet dory-release-graceful-shutdown.service
    test ! -e \"\$marker\"
    echo graceful-shutdown-armed
  " > "$WORKROOT/evidence/$distro-graceful-shutdown-armed.json"

  assert_exec_token "$machine" display-baseline-ready sh -lc "
    set -eu
    uid=\$(id -u dorygate)
    runtime=/run/user/\$uid
    session_env=\$(runuser -u dorygate -- env XDG_RUNTIME_DIR=\"\$runtime\" \
      DBUS_SESSION_BUS_ADDRESS=\"unix:path=\$runtime/bus\" systemctl --user show-environment \
      | grep -E '^(DISPLAY|XAUTHORITY)=')
    display=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^DISPLAY=//p')
    xauth=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^XAUTHORITY=//p')
    mode=\$(runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
      xrandr --current | awk '\$2 ~ /\\*/ { print \$1; exit }')
    printf '%s\n' \"\$mode\" | grep -Eq '^[0-9]+x[0-9]+$'
    printf '%s\n' \"\$mode\" > /var/lib/dory/release-display-baseline
    echo display-baseline-ready
  " > "$WORKROOT/evidence/$distro-display-baseline.json"

  original_window_size="$(osascript - "$machine_pid" <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    if not UI elements enabled then error "Accessibility permission is required for display qualification"
    set targetProcess to first process whose unix id is targetPID
    set originalSize to size of front window of targetProcess
    set size of front window of targetProcess to {960, 640}
    return ((item 1 of originalSize) as text) & "x" & ((item 2 of originalSize) as text)
  end tell
end run
APPLESCRIPT
)"
  printf '%s\n' "$original_window_size" | grep -Eq '^[0-9]+x[0-9]+$' \
    || { echo "desktop live gate: invalid original window size: $original_window_size" >&2; exit 1; }
  printf '%s\n' "$original_window_size" \
    > "$WORKROOT/evidence/$distro-display-original-window.txt"

  assert_exec_token "$machine" dynamic-display-resized sh -lc "
    set -eu
    uid=\$(id -u dorygate)
    runtime=/run/user/\$uid
    session_env=\$(runuser -u dorygate -- env XDG_RUNTIME_DIR=\"\$runtime\" \
      DBUS_SESSION_BUS_ADDRESS=\"unix:path=\$runtime/bus\" systemctl --user show-environment \
      | grep -E '^(DISPLAY|XAUTHORITY)=')
    display=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^DISPLAY=//p')
    xauth=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^XAUTHORITY=//p')
    baseline=\$(cat /var/lib/dory/release-display-baseline)
    for _ in \$(seq 1 30); do
      current=\$(runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
        xrandr --current | awk '\$2 ~ /\\*/ { print \$1; exit }')
      if printf '%s\n' \"\$current\" | grep -Eq '^[0-9]+x[0-9]+$' \
          && test \"\$current\" != \"\$baseline\"; then
        printf '%s\n' \"\$current\" > /var/lib/dory/release-display-resized
        echo dynamic-display-resized
        exit 0
      fi
      sleep 1
    done
    echo 'guest display mode did not follow the host window resize' >&2
    exit 1
  " > "$WORKROOT/evidence/$distro-display-resized.json"

  original_window_width="${original_window_size%x*}"
  original_window_height="${original_window_size#*x}"
  osascript - "$machine_pid" "$original_window_width" "$original_window_height" <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  set restoredWidth to (item 2 of argv) as integer
  set restoredHeight to (item 3 of argv) as integer
  tell application "System Events"
    set targetProcess to first process whose unix id is targetPID
    set size of front window of targetProcess to {restoredWidth, restoredHeight}
  end tell
end run
APPLESCRIPT

  assert_exec_token "$machine" dynamic-display-restored sh -lc "
    set -eu
    uid=\$(id -u dorygate)
    runtime=/run/user/\$uid
    session_env=\$(runuser -u dorygate -- env XDG_RUNTIME_DIR=\"\$runtime\" \
      DBUS_SESSION_BUS_ADDRESS=\"unix:path=\$runtime/bus\" systemctl --user show-environment \
      | grep -E '^(DISPLAY|XAUTHORITY)=')
    display=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^DISPLAY=//p')
    xauth=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^XAUTHORITY=//p')
    baseline=\$(cat /var/lib/dory/release-display-baseline)
    for _ in \$(seq 1 30); do
      current=\$(runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
        xrandr --current | awk '\$2 ~ /\\*/ { print \$1; exit }')
      if test \"\$current\" = \"\$baseline\"; then
        echo dynamic-display-restored
        exit 0
      fi
      sleep 1
    done
    echo 'guest display mode did not return after restoring the host window' >&2
    exit 1
  " > "$WORKROOT/evidence/$distro-display-restored.json"

  host_to_guest_clipboard="dory-host-to-guest-$distro-$(uuidgen | tr '[:upper:]' '[:lower:]')"
  osascript <<'APPLESCRIPT'
tell application "Finder" to activate
delay 0.25
APPLESCRIPT
  printf '%s' "$host_to_guest_clipboard" | pbcopy
  osascript - "$machine_pid" <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  tell application "System Events"
    set targetProcess to first process whose unix id is targetPID
    set frontmost of targetProcess to true
  end tell
end run
APPLESCRIPT
  assert_exec_token "$machine" clipboard-host-to-guest-pass sh -lc "
    set -eu
    for _ in \$(seq 1 30); do
      actual=\$(/usr/lib/dory/clipboard get 'text/plain;charset=utf-8' 2>/dev/null || true)
      if test \"\$actual\" = '$host_to_guest_clipboard'; then
        echo clipboard-host-to-guest-pass
        exit 0
      fi
      sleep 1
    done
    echo 'host clipboard did not reach the guest' >&2
    exit 1
  " > "$WORKROOT/evidence/$distro-clipboard-host-to-guest.json"

  guest_to_host_clipboard="dory-guest-to-host-$distro-$(uuidgen | tr '[:upper:]' '[:lower:]')"
  assert_exec_token "$machine" clipboard-guest-source-ready sh -lc "
    set -eu
    printf '%s' '$guest_to_host_clipboard' \
      | /usr/lib/dory/clipboard set 'text/plain;charset=utf-8'
    echo clipboard-guest-source-ready
  " > "$WORKROOT/evidence/$distro-clipboard-guest-source.json"
  osascript <<'APPLESCRIPT'
tell application "Finder" to activate
APPLESCRIPT
  clipboard_guest_to_host_ok=0
  for _ in $(seq 1 30); do
    if [ "$(pbpaste)" = "$guest_to_host_clipboard" ]; then
      clipboard_guest_to_host_ok=1
      break
    fi
    sleep 1
  done
  [ "$clipboard_guest_to_host_ok" = 1 ] \
    || { echo "desktop live gate: guest clipboard did not reach the host" >&2; exit 1; }
  printf '%s\n' "$guest_to_host_clipboard" \
    > "$WORKROOT/evidence/$distro-clipboard-guest-to-host.txt"

  input_token="doryinputpass$distro"
  assert_exec_token "$machine" input-window-ready sh -lc "
    set -eu
    uid=\$(id -u dorygate)
    runtime=/run/user/\$uid
    session_env=\$(runuser -u dorygate -- env XDG_RUNTIME_DIR=\"\$runtime\" \
      DBUS_SESSION_BUS_ADDRESS=\"unix:path=\$runtime/bus\" systemctl --user show-environment \
      | grep -E '^(DISPLAY|XAUTHORITY)=')
    display=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^DISPLAY=//p')
    xauth=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^XAUTHORITY=//p')
    marker=/home/dorygate/.dory-release-input
    reader=/tmp/dory-release-input-reader
    rm -f \"\$marker\"
    printf '%s' \
      'IyEvYmluL3NoCklGUz0gcmVhZCAtciBsaW5lCnByaW50ZiAiJXMiICIkbGluZSIgPiAvaG9tZS9kb3J5Z2F0ZS8uZG9yeS1yZWxlYXNlLWlucHV0Cg==' \
      | base64 -d > \"\$reader\"
    chmod 0755 \"\$reader\"
    chown dorygate:dorygate \"\$reader\"
    runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
      setsid -f xterm -title DoryInputGate -geometry 200x60+0+0 -e \"\$reader\"
    for _ in \$(seq 1 30); do
      if runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
          xwininfo -root -tree 2>/dev/null | grep -Fq 'DoryInputGate'; then
        echo input-window-ready
        exit 0
      fi
      sleep 1
    done
    echo 'guest input window did not map' >&2
    exit 1
  " > "$WORKROOT/evidence/$distro-input-window.json"

  osascript - "$machine_pid" "$input_token" <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  set inputToken to item 2 of argv
  tell application "System Events"
    set targetProcess to first process whose unix id is targetPID
    set frontmost of targetProcess to true
    set targetWindow to front window of targetProcess
    set windowPosition to position of targetWindow
    set windowSize to size of targetWindow
    set clickX to (item 1 of windowPosition) + ((item 1 of windowSize) div 2)
    set clickY to (item 2 of windowPosition) + ((item 2 of windowSize) div 2)
    delay 0.25
    click at {clickX, clickY}
    delay 0.25
    keystroke inputToken
    key code 36
  end tell
end run
APPLESCRIPT

  assert_exec_token "$machine" keyboard-pointer-input-pass sh -lc "
    set -eu
    marker=/home/dorygate/.dory-release-input
    for _ in \$(seq 1 30); do
      if test -f \"\$marker\" && test \"\$(cat \"\$marker\")\" = '$input_token'; then
        echo keyboard-pointer-input-pass
        exit 0
      fi
      sleep 1
    done
    echo 'host keyboard/pointer input did not reach the guest exactly' >&2
    exit 1
  " > "$WORKROOT/evidence/$distro-keyboard-pointer-input.json"

  assert_exec_token "$machine" browser-window-mapped sh -lc "
    set -eu
    uid=\$(id -u dorygate)
    runtime=/run/user/\$uid
    session_env=\$(runuser -u dorygate -- env XDG_RUNTIME_DIR=\"\$runtime\" \
      DBUS_SESSION_BUS_ADDRESS=\"unix:path=\$runtime/bus\" systemctl --user show-environment \
      | grep -E '^(DISPLAY|DBUS_SESSION_BUS_ADDRESS|XAUTHORITY|XDG_RUNTIME_DIR)=')
    display=\$(printf '%s\\n' \"\$session_env\" | sed -n 's/^DISPLAY=//p')
    dbus=\$(printf '%s\\n' \"\$session_env\" | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p')
    xauth=\$(printf '%s\\n' \"\$session_env\" | sed -n 's/^XAUTHORITY=//p')
    configured_runtime=\$(printf '%s\\n' \"\$session_env\" | sed -n 's/^XDG_RUNTIME_DIR=//p')
    test -n \"\$display\"
    test -n \"\$xauth\"
    test \"\$configured_runtime\" = \"\$runtime\"
    if [ '$distro' = ubuntu ]; then
      favorites=\$(runuser -u dorygate -- env DBUS_SESSION_BUS_ADDRESS=\"\$dbus\" \
        XDG_RUNTIME_DIR=\"\$runtime\" gsettings get org.gnome.shell favorite-apps)
      printf '%s\\n' \"\$favorites\" | grep -Fq \"'firefox.desktop'\"
      ! printf '%s\\n' \"\$favorites\" | grep -Fq 'firefox_firefox.desktop'
    fi
    runuser -u dorygate -- env DISPLAY=\"\$display\" DBUS_SESSION_BUS_ADDRESS=\"\$dbus\" \
      XAUTHORITY=\"\$xauth\" XDG_RUNTIME_DIR=\"\$runtime\" MOZ_ENABLE_WAYLAND=0 \
      gio launch '$browser_desktop' https://example.com >/tmp/dory-release-browser.log 2>&1
    for _ in \$(seq 1 30); do
      if pgrep -u dorygate -f '$browser_pattern' >/dev/null \
          && runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
            xwininfo -root -tree 2>/dev/null \
            | grep -Eq '\(\"Navigator\" \"firefox(-esr)?\"\)'; then
        echo browser-running
        echo browser-window-mapped
        exit 0
      fi
      sleep 1
    done
    cat /tmp/dory-release-browser.log >&2
    exit 1
  " > "$WORKROOT/evidence/$distro-browser.json"

  if [ "$distro" = ubuntu ]; then
    assert_exec_token "$machine" gtk-windows-mapped sh -lc "
      set -eu
      uid=\$(id -u dorygate)
      runtime=/run/user/\$uid
      session_env=\$(runuser -u dorygate -- env XDG_RUNTIME_DIR=\"\$runtime\" \
        DBUS_SESSION_BUS_ADDRESS=\"unix:path=\$runtime/bus\" systemctl --user show-environment \
        | grep -E '^(DISPLAY|DBUS_SESSION_BUS_ADDRESS|XAUTHORITY|XDG_RUNTIME_DIR|GSK_RENDERER)=')
      display=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^DISPLAY=//p')
      dbus=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p')
      xauth=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^XAUTHORITY=//p')
      renderer=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^GSK_RENDERER=//p')
      test \"\$renderer\" = gl
      runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
        XDG_RUNTIME_DIR=\"\$runtime\" DBUS_SESSION_BUS_ADDRESS=\"\$dbus\" GSK_RENDERER=\"\$renderer\" \
        XDG_CURRENT_DESKTOP=ubuntu:GNOME DESKTOP_SESSION=ubuntu GDMSESSION=ubuntu \
        gio launch /usr/share/applications/org.gnome.Nautilus.desktop \
        >/tmp/dory-release-files.log 2>&1
      runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
        XDG_RUNTIME_DIR=\"\$runtime\" DBUS_SESSION_BUS_ADDRESS=\"\$dbus\" GSK_RENDERER=\"\$renderer\" \
        XDG_CURRENT_DESKTOP=ubuntu:GNOME DESKTOP_SESSION=ubuntu GDMSESSION=ubuntu \
        gio launch /usr/share/applications/org.gnome.Calculator.desktop \
        >/tmp/dory-release-calculator.log 2>&1
      runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
        XDG_RUNTIME_DIR=\"\$runtime\" DBUS_SESSION_BUS_ADDRESS=\"\$dbus\" GSK_RENDERER=\"\$renderer\" \
        XDG_CURRENT_DESKTOP=ubuntu:GNOME DESKTOP_SESSION=ubuntu GDMSESSION=ubuntu \
        gio launch /usr/share/applications/org.gnome.Settings.desktop \
        >/tmp/dory-release-settings.log 2>&1
      runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
        XDG_RUNTIME_DIR=\"\$runtime\" DBUS_SESSION_BUS_ADDRESS=\"\$dbus\" GSK_RENDERER=\"\$renderer\" \
        XDG_CURRENT_DESKTOP=ubuntu:GNOME DESKTOP_SESSION=ubuntu GDMSESSION=ubuntu \
        gnome-terminal >/tmp/dory-release-terminal.log 2>&1
      for _ in \$(seq 1 30); do
        windows=\$(runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \
          xwininfo -root -tree 2>/dev/null)
        if printf '%s\n' \"\$windows\" | grep -Fq '(\"org.gnome.Nautilus\" \"org.gnome.Nautilus\")' \
            && printf '%s\n' \"\$windows\" | grep -Fq '(\"gnome-calculator\" \"gnome-calculator\")' \
            && printf '%s\n' \"\$windows\" | grep -Fq '(\"gnome-control-center\" \"gnome-control-center\")' \
            && printf '%s\n' \"\$windows\" | grep -Eq '\(\"gnome-terminal-server\" \"Gnome-terminal(-server)?\"\)'; then
          for process_pattern in '/usr/bin/nautilus' '/usr/bin/gnome-calculator' 'gnome-control-center'; do
            process_id=\$(pgrep -n -u dorygate -f \"\$process_pattern\")
            tr '\\0' '\\n' <\"/proc/\$process_id/environ\" | grep -Fqx 'GSK_RENDERER=gl'
          done
          echo gtk-windows-mapped
          exit 0
        fi
        sleep 1
      done
      cat /tmp/dory-release-files.log /tmp/dory-release-calculator.log \
        /tmp/dory-release-settings.log /tmp/dory-release-terminal.log >&2
      exit 1
    " > "$WORKROOT/evidence/$distro-gtk-windows.json"

    assert_exec_token "$machine" zed-native-venus sh -lc "
      set -eu
      uid=\$(id -u dorygate)
      runtime=/run/user/\$uid
      session_env=\$(runuser -u dorygate -- env XDG_RUNTIME_DIR=\"\$runtime\" \\
        DBUS_SESSION_BUS_ADDRESS=\"unix:path=\$runtime/bus\" systemctl --user show-environment \\
        | grep -E '^(DISPLAY|DBUS_SESSION_BUS_ADDRESS|XAUTHORITY|XDG_RUNTIME_DIR|VK_DRIVER_FILES|LD_LIBRARY_PATH)=')
      display=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^DISPLAY=//p')
      dbus=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p')
      xauth=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^XAUTHORITY=//p')
      vk_driver=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^VK_DRIVER_FILES=//p')
      library_path=\$(printf '%s\n' \"\$session_env\" | sed -n 's/^LD_LIBRARY_PATH=//p')
      test -n \"\$display\"
      test -n \"\$xauth\"
      test -n \"\$vk_driver\"
      test -n \"\$library_path\"
      rm -rf /home/dorygate/.local/zed.app
      runuser -u dorygate -- mkdir -p /home/dorygate/.local /home/dorygate/Projects/dory-gate
      test \"\$(sha256sum /home/dorygate/Mac/zed-linux-aarch64.tar.gz | awk '{print \$1}')\" \\
        = '$ZED_SHA256'
      printf 'fn main() { println!(\"Dory Venus gate\"); }\n' \\
        > /home/dorygate/Projects/dory-gate/main.rs
      chown -R dorygate:dorygate /home/dorygate/Projects/dory-gate
      runuser -u dorygate -- tar -xzf /home/dorygate/Mac/zed-linux-aarch64.tar.gz \\
        -C /home/dorygate/.local
      test -x /home/dorygate/.local/zed.app/bin/zed
      runuser -u dorygate -- /home/dorygate/.local/zed.app/bin/zed --version \\
        | grep -F '$ZED_VERSION'
      runuser -u dorygate -- env -u ZED_ALLOW_EMULATED_GPU \\
        DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \\
        XDG_RUNTIME_DIR=\"\$runtime\" DBUS_SESSION_BUS_ADDRESS=\"\$dbus\" \\
        VK_DRIVER_FILES=\"\$vk_driver\" LD_LIBRARY_PATH=\"\$library_path\" \\
        /home/dorygate/.local/zed.app/bin/zed /home/dorygate/Projects/dory-gate/main.rs \\
        >/tmp/dory-release-zed.log 2>&1
      for _ in \$(seq 1 60); do
        zed_pid=\$(pgrep -n -u dorygate -f '/zed.app/libexec/zed-editor' || true)
        if test -n \"\$zed_pid\" \\
            && tr '\\0' '\\n' <\"/proc/\$zed_pid/environ\" | grep -Fqx \"VK_DRIVER_FILES=\$vk_driver\" \\
            && tr '\\0' '\\n' <\"/proc/\$zed_pid/environ\" | grep -Fqx \"LD_LIBRARY_PATH=\$library_path\" \\
            && ! tr '\\0' '\\n' <\"/proc/\$zed_pid/environ\" | grep -q '^ZED_ALLOW_EMULATED_GPU=' \\
            && runuser -u dorygate -- env DISPLAY=\"\$display\" XAUTHORITY=\"\$xauth\" \\
              xwininfo -root -tree 2>/dev/null | grep -Eiq 'zed|dory-gate/main.rs'; then
          echo zed-native-venus
          exit 0
        fi
        sleep 1
      done
      cat /tmp/dory-release-zed.log >&2
      exit 1
    " > "$WORKROOT/evidence/$distro-zed.json"
    ZED_QUALIFIED=1
  fi

  "$CTL" machine stop "$machine" > "$WORKROOT/evidence/$distro-stop.json"
  python3 - "$WORKROOT/evidence/$distro-stop.json" "$machine" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    body = json.load(handle)
if not isinstance(body, dict) or body.get("id") != sys.argv[2] \
        or body.get("state") != "stopped":
    raise SystemExit(f"machine stop did not complete cleanly: {body!r}")
PY
  "$CTL" machine start "$machine" > "$WORKROOT/evidence/$distro-restart.json"
  wait_for_desktop "$machine" "$manager" "$session"
  wait_for_running "$machine"
  assert_exec_token "$machine" graceful-shutdown-pass sh -lc "
    set -eu
    grep -Fqx graceful-shutdown-pass /var/lib/dory/release-graceful-shutdown
    cat /home/dorygate/.dory-release-marker
    mountpoint -q /home/dorygate/Mac
    echo graceful-shutdown-pass
  " \
    > "$WORKROOT/evidence/$distro-persistence.json"

  recovery_snapshot="recovery-$distro"
  assert_exec_token "$machine" recovery-source-ready sh -lc "
    set -eu
    recovery_path=/home/dorygate/.dory-release-recovery.bin
    recovery_sum=/home/dorygate/.dory-release-recovery.sha256
    dd if=/dev/urandom of=\"\$recovery_path\" bs=1M count=16 status=none
    sha256sum \"\$recovery_path\" > \"\$recovery_sum\"
    sync
    echo recovery-source-ready
  " > "$WORKROOT/evidence/$distro-recovery-source.json"
  "$CTL" machine snapshot "$machine" --id "$recovery_snapshot" \
    --note "Exact release-candidate recovery proof" \
    > "$WORKROOT/evidence/$distro-recovery-snapshot.json"
  snapshot_plan_sha="$(python3 - \
    "$WORKROOT/evidence/$distro-recovery-snapshot.json" \
    "$machine" "$recovery_snapshot" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    body = json.load(handle)
if not isinstance(body, dict) or body.get("machineID") != sys.argv[2] \
        or body.get("id") != sys.argv[3]:
    raise SystemExit(f"snapshot returned the wrong authority: {body!r}")
if body.get("consistency") not in {"cold-stopped", "guest-quiesced"}:
    raise SystemExit(f"snapshot omitted an exact consistency contract: {body!r}")
identity = body.get("runtimeIdentity")
if not isinstance(identity, dict) or identity.get("mode") != "resolved-plan" \
        or re.fullmatch(r"[0-9a-f]{64}", identity.get("planSHA256", "")) is None:
    raise SystemExit(f"snapshot omitted resolved runtime authority: {body!r}")
artifacts = body.get("artifactEvidence")
if not isinstance(artifacts, dict):
    raise SystemExit(f"snapshot omitted artifact evidence: {body!r}")
for key in ("rootfs", "kernel"):
    artifact = artifacts.get(key)
    if not isinstance(artifact, dict) \
            or not isinstance(artifact.get("byteCount"), int) \
            or artifact["byteCount"] <= 0 \
            or re.fullmatch(r"[0-9a-f]{64}", artifact.get("sha256", "")) is None:
        raise SystemExit(f"snapshot has invalid {key} evidence: {body!r}")
print(identity["planSHA256"])
PY
  )"
  printf '%s\n' "$snapshot_plan_sha" \
    > "$WORKROOT/evidence/$distro-recovery-snapshot-plan.txt"
  wait_for_desktop "$machine" "$manager" "$session"
  wait_for_running "$machine"
  assert_exec_token "$machine" recovery-source-mutated sh -lc "
    set -eu
    recovery_path=/home/dorygate/.dory-release-recovery.bin
    recovery_sum=/home/dorygate/.dory-release-recovery.sha256
    printf 'mutated-after-snapshot\n' > \"\$recovery_path\"
    if sha256sum -c \"\$recovery_sum\" >/dev/null 2>&1; then
      echo 'recovery mutation did not change the payload' >&2
      exit 1
    fi
    sync
    echo recovery-source-mutated
  " > "$WORKROOT/evidence/$distro-recovery-mutated.json"
  "$CTL" machine restore-snapshot "$machine" "$recovery_snapshot" \
    > "$WORKROOT/evidence/$distro-recovery-restore.json"
  restored_plan_sha="$(python3 - \
    "$WORKROOT/evidence/$distro-recovery-restore.json" \
    "$machine" "$snapshot_plan_sha" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    body = json.load(handle)
if not isinstance(body, dict) or body.get("id") != sys.argv[2] \
        or body.get("state") not in {"starting", "running"}:
    raise SystemExit(f"restore did not resume the running machine: {body!r}")
identity = body.get("runtimeIdentity")
if not isinstance(identity, dict) or identity.get("mode") != "resolved-plan" \
        or re.fullmatch(r"[0-9a-f]{64}", identity.get("planSHA256", "")) is None:
    raise SystemExit(f"restore did not publish fresh resolved authority: {body!r}")
if identity["planSHA256"] == sys.argv[3]:
    raise SystemExit(f"restore reused the snapshot's stale launch plan: {body!r}")
print(identity["planSHA256"])
PY
  )"
  printf '%s\n' "$restored_plan_sha" \
    > "$WORKROOT/evidence/$distro-recovery-restored-plan.txt"
  wait_for_desktop "$machine" "$manager" "$session"
  wait_for_running "$machine"
  assert_exec_token "$machine" recovery-exact-bytes-restored sh -lc "
    set -eu
    sha256sum -c /home/dorygate/.dory-release-recovery.sha256
    echo recovery-exact-bytes-restored
  " > "$WORKROOT/evidence/$distro-recovery-qualified.json"
  "$CTL" machine delete-snapshot "$machine" "$recovery_snapshot" \
    > "$WORKROOT/evidence/$distro-recovery-delete.json"
  "$CTL" machine snapshots "$machine" \
    > "$WORKROOT/evidence/$distro-recovery-remaining-snapshots.json"
  python3 - "$WORKROOT/evidence/$distro-recovery-remaining-snapshots.json" \
    "$recovery_snapshot" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    body = json.load(handle)
if not isinstance(body, list) or any(
        isinstance(row, dict) and row.get("id") == sys.argv[2] for row in body):
    raise SystemExit(f"recovery snapshot survived deletion: {body!r}")
PY

  "$CTL" machine desktop-update "$machine" \
    --distro "$distro" --version "$update_version" \
    --distribution-installation "$distribution_installation" \
    --runtime-installation "$runtime_installation" \
    > "$WORKROOT/evidence/$distro-desktop-update.json"
  python3 - "$WORKROOT/evidence/$distro-desktop-update.json" "$update_version" \
    "$catalog_digest" "$distribution_installation" "$runtime_installation" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    body = json.load(handle)
if not isinstance(body, dict) or body.get("version") != sys.argv[2]:
    raise SystemExit(f"desktop update returned the wrong version: {body!r}")
status = body.get("status")
if not isinstance(status, dict) or status.get("state") != "running":
    raise SystemExit(f"desktop update did not restore running state: {body!r}")
for key in ("inputSHA256", "bundleSHA256"):
    value = body.get(key)
    if not isinstance(value, str) or len(value) != 64:
        raise SystemExit(f"desktop update omitted {key}: {body!r}")
if not isinstance(body.get("snapshotID"), str) or not body["snapshotID"]:
    raise SystemExit(f"desktop update omitted rollback snapshot authority: {body!r}")
receipt = status.get("installedDesktopPayloadReceipt")
if not isinstance(receipt, dict):
    raise SystemExit(f"desktop status omitted installed payload receipt: {body!r}")
expected = {
    "releaseVersion": sys.argv[2],
    "distributionCatalogSHA256": sys.argv[3],
    "runtimeCatalogSHA256": sys.argv[3],
    "distributionInstallationName": sys.argv[4],
    "runtimeInstallationName": sys.argv[5],
    "provenance": "verified-update-bundle",
}
for key, value in expected.items():
    if receipt.get(key) != value:
        raise SystemExit(f"desktop receipt mismatch for {key}: {body!r}")
PY
  wait_for_desktop "$machine" "$manager" "$session"
  wait_for_running "$machine"
  assert_exec_token "$machine" update-pass sh -lc \
    "grep -Fqx 'version=$update_version' /var/lib/dory/desktop-update.env; cat /home/dorygate/.dory-release-marker; echo update-pass" \
    > "$WORKROOT/evidence/$distro-update-qualified.json"

  # Public updates accept only signed component installation identities. A stale identity must be
  # rejected before guest mutation while the already-qualified machine keeps running.
  if "$CTL" machine desktop-update "$machine" \
      --distro "$distro" --version "$update_version" \
      --distribution-installation "$distribution_installation-stale" \
      --runtime-installation "$runtime_installation" \
      > "$WORKROOT/evidence/$distro-stale-update-stdout.json" \
      2> "$WORKROOT/evidence/$distro-stale-update-stderr.txt"; then
    echo "desktop live gate: stale $distro component identity unexpectedly succeeded" >&2
    exit 1
  fi
  grep -q 'desktop update component selection is stale' \
    "$WORKROOT/evidence/$distro-stale-update-stderr.txt"
  wait_for_desktop "$machine" "$manager" "$session"
  wait_for_running "$machine"
  assert_exec_token "$machine" stale-update-rejected sh -lc \
    "grep -Fqx 'version=$update_version' /var/lib/dory/desktop-update.env; cat /home/dorygate/.dory-release-marker; echo stale-update-rejected" \
    > "$WORKROOT/evidence/$distro-stale-update-qualified.json"

  "$CTL" machine stop "$machine" >/dev/null
  "$CTL" machine delete "$machine" >/dev/null
  if "$CTL" machine status "$machine" >/dev/null 2>&1; then
    echo "desktop live gate: temporary machine survived deletion: $machine" >&2
    exit 1
  fi
  ACTIVE_MACHINE=""
  printf '%s=PASS\n' "$distro" >> "$WORKROOT/evidence/desktop-results.txt"
}

if [ "$SELECTED_DISTRO" = all ] || [ "$SELECTED_DISTRO" = debian ]; then
  run_desktop debian "$DEBIAN_ROOTFS" lightdm xfce4-session firefox-esr \
    'firefox-esr|/firefox' /usr/share/applications/firefox-esr.desktop "$DEBIAN_UPDATE" \
    xfce4-terminal thunar mousepad ristretto file-roller evince galculator
fi
if [ "$SELECTED_DISTRO" = all ] || [ "$SELECTED_DISTRO" = ubuntu ]; then
  run_desktop ubuntu "$UBUNTU_ROOTFS" gdm3 gnome-shell firefox \
    'firefox' /usr/share/applications/firefox.desktop "$UBUNTU_UPDATE" \
    gnome-terminal nautilus gnome-text-editor eog file-roller evince \
    gnome-calculator gnome-control-center
fi
if [ "$SELECTED_DISTRO" = all ] || [ "$SELECTED_DISTRO" = kali ]; then
  run_desktop kali "$KALI_ROOTFS" lightdm xfce4-session firefox-esr \
    'firefox-esr|/firefox' /usr/share/applications/firefox-esr.desktop "$KALI_UPDATE" \
    xfce4-terminal thunar mousepad ristretto file-roller atril
fi

{
  printf 'source_commit=%s\n' "${GITHUB_SHA:-local}"
  printf 'distros=%s\n' "$SELECTED_DISTRO"
  printf 'kernel_sha256=%s\n' "$(shasum -a 256 "$KERNEL" | awk '{print $1}')"
  printf 'zed_version=%s\n' "$ZED_VERSION"
  printf 'zed_sha256=%s\n' "$ZED_SHA256"
  if [ "$ZED_QUALIFIED" = 1 ]; then
    printf 'zed_native_venus=PASS\n'
  else
    printf 'zed_native_venus=NOT-RUN\n'
  fi
  printf 'snapshot_restore_exact_bytes=PASS\n'
  printf 'graceful_shutdown=PASS\n'
  printf 'dynamic_retina_display=PASS\n'
  printf 'clipboard_bidirectional=PASS\n'
  printf 'keyboard_pointer_input=PASS\n'
  if [ "$SELECTED_DISTRO" = all ] || [ "$SELECTED_DISTRO" = debian ]; then
    printf 'debian_rootfs_sha256=%s\n' "$(shasum -a 256 "$DEBIAN_ROOTFS" | awk '{print $1}')"
    printf 'debian_update_sha256=%s\n' "$(shasum -a 256 "$DEBIAN_UPDATE" | awk '{print $1}')"
  fi
  if [ "$SELECTED_DISTRO" = all ] || [ "$SELECTED_DISTRO" = ubuntu ]; then
    printf 'ubuntu_rootfs_sha256=%s\n' "$(shasum -a 256 "$UBUNTU_ROOTFS" | awk '{print $1}')"
    printf 'ubuntu_update_sha256=%s\n' "$(shasum -a 256 "$UBUNTU_UPDATE" | awk '{print $1}')"
  fi
  if [ "$SELECTED_DISTRO" = all ] || [ "$SELECTED_DISTRO" = kali ]; then
    printf 'kali_rootfs_sha256=%s\n' "$(shasum -a 256 "$KALI_ROOTFS" | awk '{print $1}')"
    printf 'kali_update_sha256=%s\n' "$(shasum -a 256 "$KALI_UPDATE" | awk '{print $1}')"
  fi
  printf 'status=PASS\n'
} > "$WORKROOT/evidence/manifest.txt"

rm -f "$WORKROOT/share/zed-linux-aarch64.tar.gz"
[ "$SELECTED_DISTRO" != all ] && [ "$SELECTED_DISTRO" != ubuntu ] \
  || [ "$ZED_QUALIFIED" = 1 ]

echo "Desktop Linux exact-candidate live gate: PASS ($WORKROOT/evidence/manifest.txt)"
