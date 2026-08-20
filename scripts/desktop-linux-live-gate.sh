#!/bin/bash
# Boot and exercise every managed desktop with the exact signed release candidate. This gate is
# intentionally destructive only to its uniquely named temporary machines and work directory.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CTL=""
KERNEL=""
DEBIAN_ROOTFS=""
UBUNTU_ROOTFS=""
KALI_ROOTFS=""
DEBIAN_UPDATE=""
UBUNTU_UPDATE=""
KALI_UPDATE=""
DESKTOP_VERSION=""
SELECTED_DISTRO="all"
WORKROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/dory-desktop-linux-live"
CONFIRM=""

usage() {
  echo "usage: desktop-linux-live-gate.sh --ctl PATH --kernel PATH [--distro all|debian|ubuntu|kali] [desktop assets] --version VERSION --workroot PATH --confirm EXACT-CANDIDATE-DESKTOPS" >&2
  exit 64
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ctl) CTL="${2:?missing path}"; shift 2 ;;
    --kernel) KERNEL="${2:?missing path}"; shift 2 ;;
    --debian-rootfs) DEBIAN_ROOTFS="${2:?missing path}"; shift 2 ;;
    --ubuntu-rootfs) UBUNTU_ROOTFS="${2:?missing path}"; shift 2 ;;
    --kali-rootfs) KALI_ROOTFS="${2:?missing path}"; shift 2 ;;
    --debian-update) DEBIAN_UPDATE="${2:?missing path}"; shift 2 ;;
    --ubuntu-update) UBUNTU_UPDATE="${2:?missing path}"; shift 2 ;;
    --kali-update) KALI_UPDATE="${2:?missing path}"; shift 2 ;;
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
HELPERS="$(cd "$(dirname "$CTL")" && pwd)"
VMM="$HELPERS/dory-hv"
VZ_VMM="$HELPERS/dory-vmm"
[ -x "$VMM" ] || { echo "desktop live gate: accelerated candidate dory-hv is missing: $VMM" >&2; exit 66; }
[ -x "$VZ_VMM" ] || { echo "desktop live gate: fallback candidate dory-vmm is missing: $VZ_VMM" >&2; exit 66; }
assets=("$KERNEL")
case "$SELECTED_DISTRO" in
  all) assets+=("$DEBIAN_ROOTFS" "$UBUNTU_ROOTFS" "$KALI_ROOTFS" "$DEBIAN_UPDATE" "$UBUNTU_UPDATE" "$KALI_UPDATE") ;;
  debian) assets+=("$DEBIAN_ROOTFS" "$DEBIAN_UPDATE") ;;
  ubuntu) assets+=("$UBUNTU_ROOTFS" "$UBUNTU_UPDATE") ;;
  kali) assets+=("$KALI_ROOTFS" "$KALI_UPDATE") ;;
esac
for asset in "${assets[@]}"; do
  [ -s "$asset" ] || { echo "desktop live gate: missing asset: $asset" >&2; exit 66; }
done
absolute_asset() {
  local asset_input="$1"
  local asset_directory
  asset_directory="$(cd "$(dirname "$asset_input")" && pwd -P)"
  printf '%s/%s\n' "$asset_directory" "$(basename "$asset_input")"
}
KERNEL="$(absolute_asset "$KERNEL")"
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
case "$WORKROOT" in
  ""|/|"$HOME"|"$ROOT"|"${RUNNER_TEMP:-/definitely-not-this-path}")
    echo "desktop live gate: unsafe workroot: $WORKROOT" >&2
    exit 64
    ;;
esac
case "$WORKROOT" in
  *dory*desktop*) ;;
  *) echo "desktop live gate: workroot must identify the Dory desktop gate: $WORKROOT" >&2; exit 64 ;;
esac

rm -rf "$WORKROOT"
mkdir -p "$WORKROOT/share" "$WORKROOT/evidence"
printf 'Dory desktop release gate\n' > "$WORKROOT/share/host-marker.txt"
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
assert body["exitCode"] == 0 and not body["timedOut"], body
assert token in body["stdout"], body
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

  if "$CTL" machine status "$machine" >/dev/null 2>&1; then
    echo "desktop live gate: refusing to overwrite existing machine $machine" >&2
    exit 1
  fi

  created="$WORKROOT/evidence/$distro-create.json"
  "$CTL" machine create "$machine" \
    --kernel "$KERNEL" --rootfs "$rootfs" --memory-mb 4096 --cpus 4 \
    --display-mode desktop \
    --share "releasegate=$WORKROOT/share:/home/dorygate/Mac:ro" \
    --env "DORY_DESKTOP_DISTRO=$distro" \
    --env DORY_DESKTOP_VMM=accelerated \
    --env DORY_DESKTOP_GRAPHICS=virgl \
    --env DORY_GUEST_USER=dorygate --env DORY_GUEST_UID=1550 > "$created"
  python3 - "$created" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    body = json.load(handle)
assert body["state"] == "created", body
assert body["displayMode"] == "desktop", body
PY

  "$CTL" machine start "$machine" > "$WORKROOT/evidence/$distro-start.json"
  wait_for_desktop "$machine" "$manager" "$session"
  wait_for_running "$machine"
  "$CTL" machine status "$machine" > "$WORKROOT/evidence/$distro-running.json"
  machine_pid="$(python3 - "$WORKROOT/evidence/$distro-running.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    body = json.load(handle)
assert body["state"] == "running" and body["displayMode"] == "desktop", body
print(body["pid"])
PY
)"
  ps -ww -p "$machine_pid" -o command= | grep -F "$VMM" \
    > "$WORKROOT/evidence/$distro-vmm-command.txt"

  app_checks=""
  for app in $expected_apps; do
    app_checks="$app_checks command -v '$app' >/dev/null;"
  done
  wait_for_exec_token "$machine" system-pass sh -lc "
    set -eu
    systemctl is-active '$manager' >/dev/null
    systemctl is-active dory-zram.service >/dev/null
    test \"\$(cat /run/dory/graphics-backend)\" = virgl2
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
  fi

  "$CTL" machine stop "$machine" > "$WORKROOT/evidence/$distro-stop.json"
  "$CTL" machine start "$machine" > "$WORKROOT/evidence/$distro-restart.json"
  wait_for_desktop "$machine" "$manager" "$session"
  wait_for_running "$machine"
  assert_exec_token "$machine" persistence-pass sh -lc \
    "cat /home/dorygate/.dory-release-marker; mountpoint -q /home/dorygate/Mac" \
    > "$WORKROOT/evidence/$distro-persistence.json"

  "$CTL" machine desktop-update "$machine" \
    --distro "$distro" --version "$DESKTOP_VERSION" \
    --bundle "$update_bundle" --kernel "$KERNEL" \
    > "$WORKROOT/evidence/$distro-desktop-update.json"
  python3 - "$WORKROOT/evidence/$distro-desktop-update.json" "$DESKTOP_VERSION" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    body = json.load(handle)
assert body["version"] == sys.argv[2], body
assert body["status"]["state"] == "running", body
assert len(body["inputSHA256"]) == 64, body
assert len(body["bundleSHA256"]) == 64, body
assert body["snapshotID"], body
PY
  wait_for_desktop "$machine" "$manager" "$session"
  wait_for_running "$machine"
  assert_exec_token "$machine" update-pass sh -lc \
    "grep -Fqx 'version=$DESKTOP_VERSION' /var/lib/dory/desktop-update.env; cat /home/dorygate/.dory-release-marker; echo update-pass" \
    > "$WORKROOT/evidence/$distro-update-qualified.json"

  bad_update="$WORKROOT/$distro-corrupt-update.tar"
  printf 'not a tar archive\n' > "$bad_update"
  if "$CTL" machine desktop-update "$machine" \
      --distro "$distro" --version "$DESKTOP_VERSION-fault" \
      --bundle "$bad_update" --kernel "$KERNEL" \
      > "$WORKROOT/evidence/$distro-rollback-stdout.json" \
      2> "$WORKROOT/evidence/$distro-rollback-stderr.txt"; then
    echo "desktop live gate: corrupt $distro update unexpectedly succeeded" >&2
    exit 1
  fi
  grep -q 'last-good snapshot' "$WORKROOT/evidence/$distro-rollback-stderr.txt"
  grep -q 'was restored' "$WORKROOT/evidence/$distro-rollback-stderr.txt"
  wait_for_desktop "$machine" "$manager" "$session"
  wait_for_running "$machine"
  assert_exec_token "$machine" rollback-pass sh -lc \
    "grep -Fqx 'version=$DESKTOP_VERSION' /var/lib/dory/desktop-update.env; cat /home/dorygate/.dory-release-marker; echo rollback-pass" \
    > "$WORKROOT/evidence/$distro-rollback-qualified.json"

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

echo "Desktop Linux exact-candidate live gate: PASS ($WORKROOT/evidence/manifest.txt)"
