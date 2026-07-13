#!/bin/bash
# Proves Dory's exact bundled VM image has no remote freshness/HEAD dependency. A disposable
# clone boots once from the compressed release assets, then boots again after those source assets
# are hidden, using only the prepared local kernel/rootfs cache under deliberately dead proxies.
set -euo pipefail

RUNTIME=""
WORKROOT="${TMPDIR:-/tmp}/dory-offline-bundled-boot"
START_TIMEOUT=180
STOP_TIMEOUT=40
CONFIRM=""
RELEASE_CANDIDATE=0

usage() {
  cat <<EOF
Usage: scripts/offline-bundled-boot-gate.sh --runtime DIR --confirm TOKEN [options]

Required:
  --runtime DIR       Exact extracted Dory standalone runtime
  --confirm TOKEN     Must be DISPOSABLE-RUNTIME-OFFLINE-CACHE

Options:
  --workroot DIR      Evidence root (default: $WORKROOT)
  --start-timeout N   Per-start deadline in seconds (default: $START_TIMEOUT)
  --stop-timeout N    Per-stop deadline in seconds (default: $STOP_TIMEOUT)
  --release-candidate Mark an exact candidate run as release-qualifying
  --help

The gate clones the runtime and creates a fresh isolated HOME. It never edits the supplied runtime,
the installed app, ~/.dory, or a user data drive.
EOF
}

die() { echo "offline bundled boot gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --runtime) need_value "$1" "$#"; RUNTIME="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --start-timeout) need_value "$1" "$#"; START_TIMEOUT="$2"; shift 2 ;;
    --stop-timeout) need_value "$1" "$#"; STOP_TIMEOUT="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    --release-candidate) RELEASE_CANDIDATE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

positive_integer() {
  case "$2" in ''|*[!0-9]*) die "$1 must be a positive integer" ;; esac
  [ "$2" -gt 0 ] || die "$1 must be a positive integer"
}

[ "$CONFIRM" = DISPOSABLE-RUNTIME-OFFLINE-CACHE ] \
  || die "requires --confirm DISPOSABLE-RUNTIME-OFFLINE-CACHE"
[ -n "$RUNTIME" ] || die "--runtime is required"
RUNTIME="$(cd "$RUNTIME" 2>/dev/null && pwd)" || die "runtime directory not found: $RUNTIME"
positive_integer start-timeout "$START_TIMEOUT"
positive_integer stop-timeout "$STOP_TIMEOUT"
for path in \
  "$RUNTIME/dory-engine" \
  "$RUNTIME/bin/dory-hv" \
  "$RUNTIME/bin/gvproxy" \
  "$RUNTIME/bin/dory-dataplane-proxy" \
  "$RUNTIME/share/dory/dory-hv-kernel-arm64.lzfse" \
  "$RUNTIME/share/dory/dory-engine-rootfs.ext4.lzfse" \
  "$RUNTIME/share/dory/dory-agent-linux-arm64"; do
  [ -s "$path" ] || die "required runtime asset is missing: $path"
done
for command in cmp cp curl lsof ps python3 shasum; do
  command -v "$command" >/dev/null || die "required command is missing: $command"
done

run_bounded() {
  local limit="$1" output="$2" pid started rc
  shift 2
  "$@" > "$output" 2>&1 &
  pid=$!
  started=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    if [ $((SECONDS - started)) -ge "$limit" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 0.2
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.1
  done
  if wait "$pid"; then rc=0; else rc=$?; fi
  return "$rc"
}

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
WORKDIR="$WORKROOT/$RUN_ID"
RUNTIME_COPY="$WORKDIR/runtime-under-test"
OFFLINE_HOME="$WORKDIR/offline-home"
HIDDEN_ASSETS="$WORKDIR/hidden-assets"
MANIFEST="$WORKDIR/manifest.txt"
mkdir -p "$WORKDIR" "$RUNTIME_COPY" "$OFFLINE_HOME" "$HIDDEN_ASSETS"

cleanup() {
  HOME="$OFFLINE_HOME" "$RUNTIME_COPY/dory-engine" stop >/dev/null 2>&1 || true
  rm -rf "$RUNTIME_COPY" "$OFFLINE_HOME" "$HIDDEN_ASSETS"
}
trap cleanup EXIT INT TERM

# APFS clone-copy keeps the exact input bytes without doubling the large release payload. The
# supplied runtime remains immutable while the clone's source assets are hidden for phase two.
cp -cR "$RUNTIME/." "$RUNTIME_COPY/"
for relative in dory-engine bin/dory-hv bin/gvproxy bin/dory-dataplane-proxy \
  share/dory/dory-hv-kernel-arm64.lzfse \
  share/dory/dory-engine-rootfs.ext4.lzfse \
  share/dory/dory-agent-linux-arm64; do
  cmp "$RUNTIME/$relative" "$RUNTIME_COPY/$relative" \
    || die "runtime clone differs before testing: $relative"
done

kernel_asset="$RUNTIME_COPY/share/dory/dory-hv-kernel-arm64.lzfse"
rootfs_asset="$RUNTIME_COPY/share/dory/dory-engine-rootfs.ext4.lzfse"
kernel_asset_sha="$(shasum -a 256 "$kernel_asset" | awk '{print $1}')"
rootfs_asset_sha="$(shasum -a 256 "$rootfs_asset" | awk '{print $1}')"
agent_asset_sha="$(shasum -a 256 "$RUNTIME_COPY/share/dory/dory-agent-linux-arm64" | awk '{print $1}')"

offline_env=(
  env HOME="$OFFLINE_HOME"
  HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9
  ALL_PROXY=socks5://127.0.0.1:9 NO_PROXY=
  http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9
  all_proxy=socks5://127.0.0.1:9 no_proxy=
)

probe() {
  local phase="$1" socket="$OFFLINE_HOME/.dory/engine.sock"
  [ -S "$socket" ] || die "$phase boot did not publish the isolated Docker socket"
  [ "$(curl -fsS --max-time 5 --unix-socket "$socket" http://d/_ping)" = OK ] \
    || die "$phase boot Docker API is not ready"
  curl -fsS --max-time 5 --unix-socket "$socket" http://d/version \
    > "$WORKDIR/$phase-version.json"
}

capture_host_tcp() {
  local phase="$1" output pid
  output="$WORKDIR/$phase-host-tcp.txt"
  : > "$output"
  for pidfile in "$OFFLINE_HOME/.dory/engine-cli.pid" "$OFFLINE_HOME/.dory/dataplane-cli.pid"; do
    [ -s "$pidfile" ] || continue
    pid="$(cat "$pidfile")"
    lsof -nP -a -p "$pid" -iTCP >> "$output" 2>/dev/null || true
  done
  ps -axo pid=,command= | awk -v needle="$OFFLINE_HOME/.dory" \
    'index($0, needle) {print $1}' | while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      lsof -nP -a -p "$pid" -iTCP >> "$output" 2>/dev/null || true
    done
  python3 - "$output" <<'PY'
import pathlib
import sys

lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace").splitlines()
dependencies = [line for line in lines if "->" in line and ("(ESTABLISHED)" in line or "(SYN_SENT)" in line)]
assert not dependencies, "offline boot retained a host TCP dependency: " + " | ".join(dependencies)
PY
}

run_bounded "$START_TIMEOUT" "$WORKDIR/fresh-start.log" \
  "${offline_env[@]}" "$RUNTIME_COPY/dory-engine" start --mem-mb 2048 --cpus 2 \
  || die "fresh exact-bundle boot failed or exceeded $START_TIMEOUT seconds"
probe fresh
capture_host_tcp fresh
prepared_kernel="$OFFLINE_HOME/.dory/vm/dory-hv-kernel-arm64"
prepared_rootfs="$OFFLINE_HOME/.dory/vm/dory-engine-rootfs.ext4"
[ -s "$prepared_kernel" ] || die "fresh boot did not prepare the bundled kernel"
[ -s "$prepared_rootfs" ] || die "fresh boot did not prepare the bundled rootfs"
prepared_kernel_sha="$(shasum -a 256 "$prepared_kernel" | awk '{print $1}')"
prepared_rootfs_sha="$(shasum -a 256 "$prepared_rootfs" | awk '{print $1}')"
run_bounded "$STOP_TIMEOUT" "$WORKDIR/fresh-stop.log" \
  "${offline_env[@]}" "$RUNTIME_COPY/dory-engine" stop \
  || die "fresh exact-bundle stop failed or exceeded $STOP_TIMEOUT seconds"
cp "$OFFLINE_HOME/.dory/engine.log" "$WORKDIR/fresh-engine.log"

mv "$kernel_asset" "$HIDDEN_ASSETS/"
mv "$rootfs_asset" "$HIDDEN_ASSETS/"
[ ! -e "$kernel_asset" ] && [ ! -e "$rootfs_asset" ] \
  || die "disposable compressed image assets were not hidden"

run_bounded "$START_TIMEOUT" "$WORKDIR/cached-start.log" \
  "${offline_env[@]}" "$RUNTIME_COPY/dory-engine" start --mem-mb 2048 --cpus 2 \
  || die "cached offline boot failed or exceeded $START_TIMEOUT seconds"
probe cached
capture_host_tcp cached
[ "$prepared_kernel_sha" = "$(shasum -a 256 "$prepared_kernel" | awk '{print $1}')" ] \
  || die "cached offline boot changed the prepared kernel"
[ "$prepared_rootfs_sha" = "$(shasum -a 256 "$prepared_rootfs" | awk '{print $1}')" ] \
  || die "cached offline boot changed the prepared rootfs"
run_bounded "$STOP_TIMEOUT" "$WORKDIR/cached-stop.log" \
  "${offline_env[@]}" "$RUNTIME_COPY/dory-engine" stop \
  || die "cached offline stop failed or exceeded $STOP_TIMEOUT seconds"
cp "$OFFLINE_HOME/.dory/engine.log" "$WORKDIR/cached-engine.log"
grep -Fq 'ready in' "$WORKDIR/fresh-start.log" || die "fresh boot never reported readiness"
grep -Fq 'ready in' "$WORKDIR/cached-start.log" || die "cached offline boot never reported readiness"
! grep -Fq 'preparing kernel' "$WORKDIR/cached-start.log" \
  || die "cached offline boot tried to prepare a missing kernel source"
! grep -Fq 'preparing engine rootfs' "$WORKDIR/cached-start.log" \
  || die "cached offline boot tried to prepare a missing rootfs source"

release_qualifying=false
[ "$RELEASE_CANDIDATE" -eq 0 ] || release_qualifying=true
{
  echo "status=PASS"
  echo "run_id=$RUN_ID"
  echo "runtime=$RUNTIME"
  echo "kernel_asset_sha256=$kernel_asset_sha"
  echo "rootfs_asset_sha256=$rootfs_asset_sha"
  echo "agent_asset_sha256=$agent_asset_sha"
  echo "prepared_kernel_sha256=$prepared_kernel_sha"
  echo "prepared_rootfs_sha256=$prepared_rootfs_sha"
  echo "fresh_bundled_boot=PASS"
  echo "cached_boot_without_bundle_sources=PASS"
  echo "dead_proxy_environment=PASS"
  echo "host_tcp_dependency_absence=PASS"
  echo "prepared_assets_unchanged=PASS"
  echo "release_qualifying=$release_qualifying"
  echo "completed_epoch=$(date +%s)"
} > "$MANIFEST"

cleanup
trap - EXIT INT TERM
echo "offline bundled boot gate: PASS ($MANIFEST)"
