#!/bin/bash
# Make a built Dory.app self-contained so users download ONLY the app — no Docker Desktop, Colima,
# OrbStack, Homebrew, or `brew install container` on the user's Mac.
#
# Bundled payload:
#   * Contents/Helpers/doryd     — launchd/XPC daemon that owns the engine, idle policy, networking,
#                                   health, and Linux machine lifecycle.
#   * Contents/Helpers/dorydctl  — diagnostic/control CLI used by readiness and support flows.
#   * Contents/Helpers/DoryVMM.app — Retina-capable per-machine Virtualization.framework helper.
#   * Contents/Helpers/dory-vmm  — CLI-compatible copy used by macOS 14 engine fallback and tooling.
#   * Contents/Helpers/dory-network-helper — local networking helper for doryd-owned domains/routes.
#   * Contents/Helpers/DoryHVRunner.app — Dory's Hypervisor.framework VMM as one nested signed
#                                   application graph. Its executable is Contents/MacOS/dory-hv.
#   * Contents/Helpers/gvproxy    — userspace networking (Apache-2.0) for the dory-hv engine.
#   * Contents/Helpers/docker, docker-buildx, docker-compose — Docker Core host CLIs.
#   * kubectl is exported as the independently installable Kubernetes component in Core builds.
#   * Contents/Helpers/DoryHVRunner.app/Contents/XPCServices/DoryRendererWorker.xpc — the pinned,
#                                   statically linked dual VirGL2 + Venus renderer worker; no
#                                   ambient renderer dylib
#                                   or ambient Vulkan loader is shipped at runtime.
#   * Contents/Resources/dory-hv-kernel-<arch>             — legacy raw kernel payload.
#   * Contents/Resources/dory-machine-rootfs-<arch>.ext4   — legacy raw machine payload.
#   * Contents/Resources/dory-hv-kernel-<arch>.lzfse       — LZFSE PVH/Image kernel for dory-hv.
#   * Contents/Resources/dory-vm-kernel-<arch>.lzfse       — compatibility alias to the Docker
#                                                           engine kernel in focused Core builds.
#   * Contents/Resources/dory-vm-initfs-<arch>.ext4.lzfse  — compatibility alias to the Docker
#                                                           engine rootfs in focused Core builds.
#   * Contents/Resources/dory-desktop-kernel-arm64.lzfse   — optional verified desktop kernel.
#   * Contents/Resources/dory-desktop-<distro>-rootfs-arm64.ext4.lzfse — optional desktop images.
#   * Contents/Resources/dory-agent-linux-<arch>           — guest relay/agent for host AI bridge
#                                                           and future vsock control features.
#   * Contents/Resources/dory-transfer-helper-image-arm64.tar — deterministic scratch image used
#                                                               for exact named-volume transfer.
#   * Contents/Resources/dory-engine-rootfs-<arch>.ext4.lzfse — offline dockerd rootfs selected by
#                                                              doryd, including macOS 14 dory-vmm fallback.
#   Assets are compressed by dory-hv (LZFSE) and decompressed in-process at first launch via Apple's
#   Compression framework — no external zstd binary or dylib is bundled.
#
# Run on an exported (pre-notarization) app so the payload is signed with the bundle:
#   scripts/bundle-engine.sh release-build/export/Dory.app
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="${1:?usage: bundle-engine.sh <path/to/Dory.app>}"
case "$APP" in
  /*) ;;
  *) APP="$(pwd)/$APP" ;;
esac
cd "$REPO_ROOT"

# shellcheck source=gvproxy-payload.sh
source scripts/gvproxy-payload.sh
# shellcheck source=host-cli-payload.sh
source scripts/host-cli-payload.sh

RESOURCES="$APP/Contents/Resources"
HELPERS="$APP/Contents/Helpers"
FRAMEWORKS="$APP/Contents/Frameworks"
HV_RUNNER_APP="$HELPERS/DoryHVRunner.app"
HV_RUNNER_EXECUTABLE="$HV_RUNNER_APP/Contents/MacOS/dory-hv"
FS_WORKER_XPC="$HV_RUNNER_APP/Contents/XPCServices/DoryFSWorker.xpc"
FS_WORKER_EXECUTABLE="$FS_WORKER_XPC/Contents/MacOS/DoryFSWorker"
RENDERER_WORKER_XPC="$HV_RUNNER_APP/Contents/XPCServices/DoryRendererWorker.xpc"
RENDERER_WORKER_EXECUTABLE="$RENDERER_WORKER_XPC/Contents/MacOS/DoryRendererWorker"
DORYD_EXECUTABLE="$HELPERS/doryd"
SUPPORT="$HOME/Library/Application Support/com.apple.container"

[ -d "$APP" ] || { echo "no such app bundle: $APP"; exit 1; }
mkdir -p "$RESOURCES" "$HELPERS" "$FRAMEWORKS"

DESKTOP_BUNDLE_MODE="${DORY_DESKTOP_BUNDLE_MODE:-none}"
case "$DESKTOP_BUNDLE_MODE" in
  none|debian|ubuntu|kali|all) ;;
  *) echo "DORY_DESKTOP_BUNDLE_MODE must be 'none', 'debian', 'ubuntu', 'kali', or 'all'" >&2; exit 64 ;;
esac
COMPONENT_BUNDLE_MODE="${DORY_COMPONENT_BUNDLE_MODE:-legacy}"
case "$COMPONENT_BUNDLE_MODE" in
  core|legacy) ;;
  *) echo "DORY_COMPONENT_BUNDLE_MODE must be 'core' or 'legacy'" >&2; exit 64 ;;
esac
if [ "$COMPONENT_BUNDLE_MODE" = core ] && [ "$DESKTOP_BUNDLE_MODE" != none ]; then
  echo "DORY_COMPONENT_BUNDLE_MODE=core cannot embed desktop payloads" >&2
  exit 64
fi
DESKTOP_APPCAST_URL="${DORY_DESKTOP_APPCAST_URL:-https://augani.github.io/dory/appcast-desktop.xml}"

find_xcode() {
  local dev app found
  for app in /Applications/Xcode.app /Applications/Xcode-*.app \
             "$HOME"/Applications/Xcode*.app "$HOME"/Downloads/Xcode*.app; do
    dev="$app/Contents/Developer"
    [ -x "$dev/usr/bin/xcodebuild" ] && { printf '%s' "$dev"; return 0; }
  done
  found="$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | head -1)"
  [ -n "$found" ] && [ -x "$found/Contents/Developer/usr/bin/xcodebuild" ] \
    && { printf '%s' "$found/Contents/Developer"; return 0; }
  return 1
}

if [ -z "${DEVELOPER_DIR:-}" ]; then
  active="$(xcode-select -p 2>/dev/null || true)"
  need_fallback=0
  case "$active" in
    ""|*CommandLineTools*) need_fallback=1 ;;
  esac
  [ -n "$active" ] && [ -x "$active/usr/bin/xcodebuild" ] || need_fallback=1
  if [ "$need_fallback" -eq 1 ]; then
    if DEVELOPER_DIR="$(find_xcode)"; then
      export DEVELOPER_DIR
      echo "note: active xcode-select ('${active:-unset}') has no xcodebuild; using DEVELOPER_DIR=$DEVELOPER_DIR" >&2
    else
      echo "error: no full Xcode found. Install Xcode.app or set DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer" >&2
      exit 1
    fi
  fi
fi

# DoryCore's generated bindings and universal static XCFramework are ignored artifacts. Release
# bundling must create them from this checkout before building either doryd/dory-vmm or dory-hv.
scripts/build-dory-ffi-xcframework.sh --if-needed

have_developer_id() {
  security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"
}

# Sign one bundled helper. When a Developer ID identity is configured or present in the keychain, a
# signing failure is FATAL: an ad-hoc fallback silently produces a "release" whose dory-hv/dory-vmm
# helpers are denied their restricted hypervisor/virtualization entitlements at launch, i.e. a broken
# engine that boots nowhere. Ad-hoc is only allowed on a dev machine with no Developer ID identity, or
# explicitly via DORY_ALLOW_ADHOC_SIGN=1. Transient timestamp/keychain hiccups are retried first.
codesign_helper() {
  local path="$1" entitlements="${2:-}" id="${DORY_SIGN_ID:-Developer ID Application}"
  local base=(--force --options runtime --timestamp)
  [ -n "$entitlements" ] && base+=(--entitlements "$entitlements")

  if [ "$id" = "-" ]; then
    codesign "${base[@]}" -s - "$path"
    return
  fi

  local _attempt err
  err="$(mktemp "${TMPDIR:-/tmp}/dory-codesign.XXXXXX")"
  for _attempt in 1 2 3; do
    if codesign "${base[@]}" -s "$id" "$path" 2>"$err"; then
      rm -f "$err"
      return 0
    fi
    sleep 2
  done

  echo "    ERROR: Developer ID signing failed for $(basename "$path") (identity: $id):" >&2
  sed 's/^/      /' "$err" >&2
  rm -f "$err"
  if [ "${DORY_ALLOW_ADHOC_SIGN:-0}" = "1" ] || ! have_developer_id; then
    echo "    WARNING: ad-hoc signing $(basename "$path") — NOT distributable and its entitlements will be denied at launch." >&2
    codesign --force ${entitlements:+--entitlements "$entitlements"} -s - "$path"
    return
  fi
  echo "    A Developer ID identity is present but signing failed; refusing to ship an ad-hoc helper. Set DORY_ALLOW_ADHOC_SIGN=1 only for a throwaway local build." >&2
  return 1
}

validate_xpc_worker_bundle() {
  local bundle="$1" expected_identifier="$2" executable="$3" label="$4"
  local executable_path="$bundle/Contents/MacOS/$executable"
  [ -d "$bundle" ] && [ ! -L "$bundle" ] \
    || { echo "    ERROR: $label XPC service is missing or indirect" >&2; return 1; }
  [ -x "$executable_path" ] && [ ! -L "$executable_path" ] \
    || { echo "    ERROR: $label XPC service has no direct executable" >&2; return 1; }
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Contents/Info.plist" 2>/dev/null)" = "$executable" ] \
    || { echo "    ERROR: $label XPC service has the wrong executable" >&2; return 1; }
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist" 2>/dev/null)" = "$expected_identifier" ] \
    || { echo "    ERROR: $label XPC service has the wrong bundle identifier" >&2; return 1; }
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$bundle/Contents/Info.plist" 2>/dev/null)" = 'XPC!' ] \
    || { echo "    ERROR: $label XPC service has the wrong package type" >&2; return 1; }
  [ "$(/usr/libexec/PlistBuddy -c 'Print :XPCService:ServiceType' "$bundle/Contents/Info.plist" 2>/dev/null)" = Application ] \
    || { echo "    ERROR: $label XPC service has the wrong service type" >&2; return 1; }
}

sign_runtime_payload() {
  codesign_helper "$1"
}

sign_runtime_payload_with_entitlements() {
  codesign_helper "$1" "$2"
}

normalize_darwin_arch() {
  case "$1" in
    arm64|aarch64) printf '%s\n' "arm64" ;;
    amd64|x86_64) printf '%s\n' "x86_64" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

darwin_triple_for_arch() {
  case "$1" in
    arm64) printf '%s\n' "arm64-apple-macosx" ;;
    x86_64) printf '%s\n' "x86_64-apple-macosx" ;;
    *) echo "unsupported Darwin helper arch: $1" >&2; return 1 ;;
  esac
}

swiftpm_helper_arches() {
  local raw arch normalized out
  raw="${DORY_SWIFTPM_HELPER_ARCHES:-${DORY_BUNDLE_ARCHES:-arm64 amd64}}"
  out=""
  for arch in $raw; do
    normalized="$(normalize_darwin_arch "$arch")"
    case " $out " in
      *" $normalized "*) ;;
      *) out="${out:+$out }$normalized" ;;
    esac
  done
  printf '%s\n' "$out"
}

host_cli_arches() {
  local raw arch normalized out
  raw="${DORY_HOST_CLI_ARCHES:-${DORY_BUNDLE_ARCHES:-arm64 amd64}}"
  out=""
  for arch in $raw; do
    normalized="$(normalize_darwin_arch "$arch")"
    case " $out " in
      *" $normalized "*) ;;
      *) out="${out:+$out }$normalized" ;;
    esac
  done
  printf '%s\n' "$out"
}

darwin_download_arch() {
  case "$1" in
    arm64) printf '%s\n' "arm64" ;;
    x86_64) printf '%s\n' "amd64" ;;
    *) echo "unsupported Darwin CLI arch: $1" >&2; return 1 ;;
  esac
}

docker_download_arch() {
  case "$1" in
    arm64) printf '%s\n' "aarch64" ;;
    x86_64) printf '%s\n' "x86_64" ;;
    *) echo "unsupported Docker CLI arch: $1" >&2; return 1 ;;
  esac
}

macho_has_arches() {
  local file="$1" expected="$2" actual arch
  [ -x "$file" ] || return 1
  actual="$(lipo -archs "$file" 2>/dev/null || true)"
  [ -n "$actual" ] || return 1
  for arch in $expected; do
    case " $actual " in
      *" $arch "*) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

build_swiftpm_product_for_arch() {
  local package="$1" configuration="$2" product="$3" arch="$4" package_abs scratch triple bin_path
  package_abs="$(cd "$package" && pwd)"
  scratch="$package_abs/.build/bundle-$configuration-$arch"
  triple="$(darwin_triple_for_arch "$arch")"
  swift build --package-path "$package_abs" -c "$configuration" --triple "$triple" \
    --scratch-path "$scratch" --product "$product" >&2
  bin_path="$(swift build --package-path "$package_abs" -c "$configuration" --triple "$triple" \
    --scratch-path "$scratch" --show-bin-path 2>/dev/null)"
  printf '%s/%s\n' "$bin_path" "$product"
}

assemble_swiftpm_executable() {
  local package="$1" configuration="$2" product="$3" destination="$4"
  local arch bin arches arch_info
  local built=()

  arches="$(swiftpm_helper_arches)"
  [ -n "$arches" ] || { echo "    ERROR: no SwiftPM helper architectures configured" >&2; exit 1; }
  for arch in $arches; do
    bin="$(build_swiftpm_product_for_arch "$package" "$configuration" "$product" "$arch")"
    [ -x "$bin" ] || { echo "    ERROR: $product helper was not produced for $arch" >&2; exit 1; }
    built+=("$bin")
  done

  if [ "${#built[@]}" -eq 1 ]; then
    install -m0755 "${built[0]}" "$destination"
  else
    lipo -create "${built[@]}" -output "$destination"
    chmod 0755 "$destination"
  fi

  arch_info="$(lipo -archs "$destination" 2>/dev/null || true)"
  echo "    assembled Helpers/$(basename "$destination")${arch_info:+ ($arch_info)}"
}

bundle_swiftpm_executable() {
  local package="$1" configuration="$2" product="$3" destination="$4" entitlements="${5:-}"

  assemble_swiftpm_executable "$package" "$configuration" "$product" "$destination"

  if [ -n "$entitlements" ]; then
    sign_runtime_payload_with_entitlements "$destination" "$entitlements"
  else
    sign_runtime_payload "$destination"
  fi
  echo "    signed Helpers/$(basename "$destination")"
}

assemble_doryd_for_release_identity() {
  assemble_swiftpm_executable "$1" "$2" doryd "$DORYD_EXECUTABLE"
  echo "    deferred Helpers/doryd final signature until the immutable renderer graph is verified"
}

fetch_url() {
  local url="$1" out="$2"
  curl -fsSL \
    --retry "${DORY_CURL_RETRIES:-2}" \
    --retry-delay "${DORY_CURL_RETRY_DELAY:-2}" \
    --connect-timeout "${DORY_CURL_CONNECT_TIMEOUT:-15}" \
    --max-time "${DORY_CURL_MAX_TIME:-240}" \
    "$url" -o "$out"
}

warn_or_fail_missing_bundle_asset() {
  local message="$1"
  if [ "${DORY_REQUIRE_BUNDLE_ASSETS:-0}" = "1" ]; then
    echo "    ERROR: $message" >&2
    exit 1
  fi
  echo "    WARNING: $message"
}

bundle_venus_renderer() {
  local expected_team managed_kernel
  local adhoc_arguments=()
  local release_arguments=()
  expected_team="${DORY_RENDERER_EXPECTED_TEAM:-864H636QW4}"
  managed_kernel="${DORY_RENDERER_MANAGED_KERNEL:-${DORY_DESKTOP_KERNEL_ARM64:-${DORY_DESKTOP_KERNEL:-$REPO_ROOT/guest/out/Image-desktop}}}"
  [ -f "$managed_kernel" ] && [ ! -L "$managed_kernel" ] || {
    echo "renderer verification requires the exact managed desktop kernel: $managed_kernel" >&2
    exit 1
  }
  if [ "${DORY_SIGN_ID:-Developer ID Application}" = "-" ]; then
    expected_team=-
    if [ "${DORY_RENDERER_ALLOW_ADHOC_TEST:-0}" != 1 ]; then
      echo "ad-hoc renderer verification requires DORY_RENDERER_ALLOW_ADHOC_TEST=1" >&2
      exit 1
    fi
    adhoc_arguments+=(--allow-adhoc-test)
  fi
  [ "${DORY_PUBLIC_RELEASE:-0}" != 1 ] || release_arguments+=(--require-release-signature)
  echo "==> Verifying the Xcode-sealed exact static dual VirGL2 + Venus renderer tuple…"
  python3 "$REPO_ROOT/scripts/package-renderer-production-bundle.py" verify \
    --runner-app "$HV_RUNNER_APP" \
    --expected-team "$expected_team" \
    --managed-kernel "$managed_kernel" \
    "${adhoc_arguments[@]+"${adhoc_arguments[@]}"}" \
    "${release_arguments[@]+"${release_arguments[@]}"}"
  echo "    accepted the immutable Xcode renderer bundle; no post-signing mutation was performed"
}

renderer_release_identity_mode() {
  local mode="${DORY_RENDERER_RELEASE_IDENTITY_MODE:-}"
  if [ -z "$mode" ]; then
    if [ "${DORY_PUBLIC_RELEASE:-0}" = 1 ]; then
      mode=production
    else
      mode=disabled
    fi
  fi
  case "$mode" in
    production|disabled) ;;
    *)
      echo "DORY_RENDERER_RELEASE_IDENTITY_MODE must be 'production' or 'disabled'" >&2
      return 64
      ;;
  esac
  if [ "${DORY_PUBLIC_RELEASE:-0}" = 1 ] && [ "$mode" != production ]; then
    echo "public releases require DORY_RENDERER_RELEASE_IDENTITY_MODE=production" >&2
    return 1
  fi
  printf '%s\n' "$mode"
}

codesign_production_release_identity() {
  local path="$1" entitlements="$2" id="${DORY_SIGN_ID:-Developer ID Application}"
  local _attempt error_file
  [ "$id" != - ] \
    || { echo "    ERROR: production renderer release identity cannot use ad-hoc signing" >&2; return 1; }
  error_file="$(mktemp "${TMPDIR:-/tmp}/dory-release-identity-codesign.XXXXXX")"
  for _attempt in 1 2 3; do
    if /usr/bin/codesign --force --options runtime --timestamp --identifier doryd \
        --entitlements "$entitlements" --sign "$id" "$path" 2>"$error_file"; then
      rm -f "$error_file"
      return 0
    fi
    sleep 2
  done
  echo "    ERROR: final production doryd signing failed (identity: $id):" >&2
  sed 's/^/      /' "$error_file" >&2
  rm -f "$error_file"
  return 1
}

finalize_doryd_signature() {
  local mode expected_team temporary entitlements
  [ "${DORY_BUNDLE_DORYD:-1}" = 1 ] || return 0
  [ -x "$DORYD_EXECUTABLE" ] && [ ! -L "$DORYD_EXECUTABLE" ] \
    || { echo "    ERROR: deferred doryd executable is missing or indirect" >&2; return 1; }
  mode="$(renderer_release_identity_mode)"
  if [ "$mode" = disabled ]; then
    echo "==> Signing doryd without renderer release identity (RawHV hardware 3D fails closed)…"
    sign_runtime_payload "$DORYD_EXECUTABLE"
    python3 "$REPO_ROOT/scripts/renderer-release-identity.py" verify-absent \
      --doryd "$DORYD_EXECUTABLE"
    return 0
  fi

  [ "${DORY_BUNDLE_VENUS:-1}" = 1 ] \
    || { echo "    ERROR: production renderer release identity requires the dual renderer worker" >&2; return 1; }
  [ "${DORY_RENDERER_ALLOW_ADHOC_TEST:-0}" != 1 ] \
    || { echo "    ERROR: production renderer release identity forbids ad-hoc renderer test mode" >&2; return 1; }
  expected_team="${DORY_RENDERER_EXPECTED_TEAM:-864H636QW4}"
  [ "$expected_team" = 864H636QW4 ] \
    || { echo "    ERROR: production renderer release identity requires Dory team 864H636QW4" >&2; return 1; }

  echo "==> Binding final Runner + Worker Code Directory hashes into doryd…"
  temporary="$(mktemp -d "${TMPDIR:-/tmp}/dory-renderer-release-identity.XXXXXX")"
  entitlements="$temporary/doryd-renderer-release-identity.entitlements"
  (
    trap 'rm -f "$entitlements"; rmdir "$temporary" 2>/dev/null || true' EXIT
    python3 "$REPO_ROOT/scripts/renderer-release-identity.py" create-entitlements \
      --runner-app "$HV_RUNNER_APP" \
      --expected-team "$expected_team" \
      --output "$entitlements"
    codesign_production_release_identity "$DORYD_EXECUTABLE" "$entitlements"
    python3 "$REPO_ROOT/scripts/renderer-release-identity.py" verify \
      --runner-app "$HV_RUNNER_APP" \
      --doryd "$DORYD_EXECUTABLE" \
      --expected-team "$expected_team"
  )
  echo "    sealed Helpers/doryd after the immutable runner graph"
}

find_debugfs() {
  for cand in "$(command -v debugfs 2>/dev/null)" \
              /opt/homebrew/opt/e2fsprogs/sbin/debugfs \
              /usr/local/opt/e2fsprogs/sbin/debugfs; do
    [ -n "$cand" ] && [ -x "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

inject_dory_agent_into_initfs() {
  local src="$1" agent="$2" out="$3" debugfs_bin init_tmp startup_tmp
  INITFS_TO_BUNDLE="$src"
  [ "${DORY_SKIP_AGENT_INJECT:-0}" = "1" ] && return 0
  [ -f "$agent" ] || { echo "    WARNING: guest agent not found at $agent — run guest/initfs/build.sh to build the Rust dory-agent before bundling"; return 0; }
  if ! debugfs_bin="$(find_debugfs)"; then
    echo "    WARNING: debugfs not found — install e2fsprogs or set DORY_SKIP_AGENT_INJECT=1; bundling initfs without dory-agent"
    return 0
  fi

  init_tmp="$(mktemp -t dory-init.XXXXXX)"
  startup_tmp="$(mktemp -t dory-agent-init.XXXXXX)"
  cp "$src" "$out"
  cat > "$startup_tmp" <<'SH'
#!/bin/sh
if [ -x /usr/bin/dory-agent ] && ! pgrep -x dory-agent >/dev/null 2>&1; then
  mkdir -p /run
  /usr/bin/dory-agent >/run/dory-agent.log 2>&1 &
fi
SH

  "$debugfs_bin" -w -R "mkdir /usr" "$out" >/dev/null 2>&1 || true
  "$debugfs_bin" -w -R "mkdir /usr/bin" "$out" >/dev/null 2>&1 || true
  "$debugfs_bin" -w -R "mkdir /etc" "$out" >/dev/null 2>&1 || true
  "$debugfs_bin" -w -R "rm /usr/bin/dory-agent" "$out" >/dev/null 2>&1 || true
  "$debugfs_bin" -w -R "write $agent /usr/bin/dory-agent" "$out" >/dev/null
  "$debugfs_bin" -w -R "sif /usr/bin/dory-agent mode 0100755" "$out" >/dev/null
  "$debugfs_bin" -w -R "rm /etc/dory-agent-init" "$out" >/dev/null 2>&1 || true
  "$debugfs_bin" -w -R "write $startup_tmp /etc/dory-agent-init" "$out" >/dev/null
  "$debugfs_bin" -w -R "sif /etc/dory-agent-init mode 0100755" "$out" >/dev/null

  if "$debugfs_bin" -R "dump /sbin/init $init_tmp" "$out" >/dev/null 2>&1 && ! grep -q "DORY_AGENT_START" "$init_tmp"; then
    cat >> "$init_tmp" <<'SH'

# DORY_AGENT_START
if [ -x /etc/dory-agent-init ]; then
  /etc/dory-agent-init || true
fi
# DORY_AGENT_END
SH
    "$debugfs_bin" -w -R "rm /sbin/init" "$out" >/dev/null 2>&1 || true
    "$debugfs_bin" -w -R "write $init_tmp /sbin/init" "$out" >/dev/null
    "$debugfs_bin" -w -R "sif /sbin/init mode 0100755" "$out" >/dev/null
  else
    echo "    WARNING: could not patch /sbin/init; injected /etc/dory-agent-init for initfs builders to source"
  fi

  rm -f "$init_tmp" "$startup_tmp"
  INITFS_TO_BUNDLE="$out"
  echo "    injected /usr/bin/dory-agent into initfs"
}

is_linux_elf_for_arch() {
  local arch="$1" bin="$2" magic
  [ -n "$bin" ] && [ -r "$bin" ] || return 1
  magic="$(dd if="$bin" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  [ "$magic" = "7f454c46" ] || return 1
  if [ "$arch" = "amd64" ]; then
    file "$bin" 2>/dev/null | grep -Eqi 'ELF.*(x86-64|x86_64)'
  else
    file "$bin" 2>/dev/null | grep -Eqi 'ELF.*(aarch64|ARM aarch64)'
  fi
}

find_toolbox_binary() {
  local name="$1" arch="$2" upper_arch env_name cand
  upper_arch="$(printf '%s' "$arch" | tr '[:lower:]-' '[:upper:]_')"
  env_name="DORY_TOOLBOX_${upper_arch}_$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')"
  if [ -n "${!env_name:-}" ] && [ -x "${!env_name}" ]; then
    if is_linux_elf_for_arch "$arch" "${!env_name}"; then
      printf '%s\n' "${!env_name}"; return 0
    fi
    echo "    WARNING: $env_name=${!env_name} is not a Linux $arch ELF; skipping $name" >&2
    return 1
  fi
  for cand in "$(command -v "$name" 2>/dev/null)" \
              "/opt/homebrew/bin/$name" \
              "/usr/local/bin/$name"; do
    [ -n "$cand" ] && [ -x "$cand" ] || continue
    if is_linux_elf_for_arch "$arch" "$cand"; then
      printf '%s\n' "$cand"; return 0
    fi
  done
  return 1
}

write_doryd_launch_agent() {
  local plist doryd vmm hv gvproxy log_dir log_path
  plist="$RESOURCES/dev.dory.doryd.plist"
  doryd="$HELPERS/doryd"
  vmm="$HELPERS/dory-vmm"
  if [ -x "$HELPERS/DoryVMM.app/Contents/MacOS/dory-vmm" ]; then
    vmm="$HELPERS/DoryVMM.app/Contents/MacOS/dory-vmm"
  fi
  hv="$HV_RUNNER_EXECUTABLE"
  gvproxy="$HELPERS/gvproxy"
  log_dir="$HOME/.dory"
  log_path="$log_dir/doryd.log"
  mkdir -p "$log_dir"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>dev.dory.doryd</string>
    <key>ProgramArguments</key>
    <array>
        <string>$doryd</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>dev.dory.doryd</key>
        <true/>
    </dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>DORYD_VMM_HELPER</key>
        <string>$vmm</string>
        <key>DORYD_HV_HELPER</key>
        <string>$hv</string>
        <key>DORYD_GVPROXY</key>
        <string>$gvproxy</string>
        <key>DORYD_HELPERS_DIR</key>
        <string>$HELPERS</string>
        <key>DORYD_RESOURCES_DIR</key>
        <string>$RESOURCES</string>
        <key>DORYD_HOST_CLI</key>
        <string>1</string>
        <key>DORYD_NETWORKING</key>
        <string>1</string>
        <key>DORYD_DOMAIN_SUFFIX</key>
        <string>dory.local</string>
        <key>DORYD_IDLE_SLEEP_AFTER_SECONDS</key>
        <string>300</string>
        <key>DORYD_DNS_PORT</key>
        <string>15353</string>
        <key>DORYD_HTTP_PROXY_PORT</key>
        <string>8080</string>
        <key>DORYD_HTTPS_PROXY_PORT</key>
        <string>8443</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ExitTimeOut</key>
    <integer>45</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$log_path</string>
    <key>StandardErrorPath</key>
    <string>$log_path</string>
</dict>
</plist>
PLIST
  plutil -lint "$plist" >/dev/null
  echo "    wrote Resources/dev.dory.doryd.plist"
}

bundle_doryd_helpers() {
  local configuration entitlements product helper vmm_app vmm_executable
  [ "${DORY_BUNDLE_DORYD:-1}" = "1" ] || { echo "==> DORY_BUNDLE_DORYD=0: skipping doryd helper bundling"; return 0; }
  [ -f "dory-core-swift/Package.swift" ] || { echo "    ERROR: dory-core-swift/Package.swift missing; cannot build doryd helpers" >&2; exit 1; }
  configuration="${DORY_DORYD_HELPER_CONFIGURATION:-release}"

  entitlements="$REPO_ROOT/dory-core-swift/Sources/dory-vmm/dory-vmm.entitlements"

  echo "==> Building doryd launchd helpers ($configuration, arches: $(swiftpm_helper_arches)); final doryd signing is deferred…"
  for product in doryd dorydctl dory-vmm dory-network-helper dory-dataplane-proxy; do
    helper="$HELPERS/$product"
    if [ "$product" = doryd ]; then
      assemble_doryd_for_release_identity "dory-core-swift" "$configuration"
    elif [ "$product" = "dory-vmm" ]; then
      bundle_swiftpm_executable "dory-core-swift" "$configuration" "$product" "$helper" "$entitlements"
    else
      bundle_swiftpm_executable "dory-core-swift" "$configuration" "$product" "$helper"
    fi
  done
  vmm_app="$HELPERS/DoryVMM.app"
  vmm_executable="$vmm_app/Contents/MacOS/dory-vmm"
  mkdir -p "$vmm_app/Contents/MacOS"
  install -m 0755 "$HELPERS/dory-vmm" "$vmm_executable"
  install -m 0644 "$REPO_ROOT/dory-core-swift/Sources/dory-vmm/Info.plist" \
    "$vmm_app/Contents/Info.plist"
  sign_runtime_payload_with_entitlements "$vmm_app" "$entitlements"
  mkdir -p "$APP/Contents/Library/LaunchDaemons"
  cp "$REPO_ROOT/Config/dev.dory.network-helper.plist" \
    "$APP/Contents/Library/LaunchDaemons/dev.dory.network-helper.plist"
  plutil -lint "$APP/Contents/Library/LaunchDaemons/dev.dory.network-helper.plist" >/dev/null
}

inject_debug_toolbox_into_initfs() {
  local image="$1" arch="$2" debugfs_bin busybox curl_bin strace_bin upper_arch
  [ "${DORY_SKIP_TOOLBOX_INJECT:-0}" = "1" ] && return 0
  [ -n "$image" ] && [ -f "$image" ] || return 0
  if ! debugfs_bin="$(find_debugfs)"; then
    echo "    WARNING: debugfs not found — cannot inject debug toolbox"
    return 0
  fi

  busybox="$(find_toolbox_binary busybox "$arch" || true)"
  curl_bin="$(find_toolbox_binary curl "$arch" || true)"
  strace_bin="$(find_toolbox_binary strace "$arch" || true)"
  upper_arch="$(printf '%s' "$arch" | tr '[:lower:]-' '[:upper:]_')"
  [ -n "$busybox" ] || echo "    WARNING: no Linux $arch busybox found; debug toolbox will lack it (set DORY_TOOLBOX_${upper_arch}_BUSYBOX to a Linux static binary)"
  [ -n "$curl_bin" ] || echo "    WARNING: no Linux $arch curl found; debug toolbox will lack it (set DORY_TOOLBOX_${upper_arch}_CURL to a Linux static binary)"
  [ -n "$strace_bin" ] || echo "    WARNING: no Linux $arch strace found; debug toolbox will lack it (set DORY_TOOLBOX_${upper_arch}_STRACE to a Linux static binary)"
  if [ -z "$busybox" ] && [ -z "$curl_bin" ] && [ -z "$strace_bin" ]; then
    echo "    WARNING: no valid Linux toolbox binaries available; skipping debug toolbox injection"
    return 0
  fi

  "$debugfs_bin" -w -R "mkdir /.dory-toolbox" "$image" >/dev/null 2>&1 || true
  "$debugfs_bin" -w -R "mkdir /.dory-toolbox/bin" "$image" >/dev/null 2>&1 || true
  if [ -n "$busybox" ]; then
    "$debugfs_bin" -w -R "rm /.dory-toolbox/bin/busybox" "$image" >/dev/null 2>&1 || true
    "$debugfs_bin" -w -R "write $busybox /.dory-toolbox/bin/busybox" "$image" >/dev/null
    "$debugfs_bin" -w -R "sif /.dory-toolbox/bin/busybox mode 0100755" "$image" >/dev/null
    for applet in sh ash cat chmod chown cp env grep ls mkdir mount ps pwd rm sed sleep stat touch umount; do
      "$debugfs_bin" -w -R "rm /.dory-toolbox/bin/$applet" "$image" >/dev/null 2>&1 || true
      "$debugfs_bin" -w -R "symlink /.dory-toolbox/bin/$applet busybox" "$image" >/dev/null 2>&1 || true
    done
    echo "    injected debug toolbox busybox ($(basename "$busybox"))"
  fi
  if [ -n "$curl_bin" ]; then
    "$debugfs_bin" -w -R "rm /.dory-toolbox/bin/curl" "$image" >/dev/null 2>&1 || true
    "$debugfs_bin" -w -R "write $curl_bin /.dory-toolbox/bin/curl" "$image" >/dev/null
    "$debugfs_bin" -w -R "sif /.dory-toolbox/bin/curl mode 0100755" "$image" >/dev/null
    echo "    injected debug toolbox curl"
  fi
  if [ -n "$strace_bin" ]; then
    "$debugfs_bin" -w -R "rm /.dory-toolbox/bin/strace" "$image" >/dev/null 2>&1 || true
    "$debugfs_bin" -w -R "write $strace_bin /.dory-toolbox/bin/strace" "$image" >/dev/null
    "$debugfs_bin" -w -R "sif /.dory-toolbox/bin/strace mode 0100755" "$image" >/dev/null
    echo "    injected debug toolbox strace"
  fi
}

bundle_doryd_helpers

echo "==> Verifying the Xcode-sealed Hypervisor.framework runner application…"
# The Dory target builds and embeds this exact application. Release assembly must never replace it
# with an independently built SwiftPM executable, because that would create a second launch and
# qualification authority outside the Xcode product graph.
rm -f "$HELPERS/dory-hv"
[ -d "$HV_RUNNER_APP" ] && [ ! -L "$HV_RUNNER_APP" ] \
  || { echo "    ERROR: Xcode-built DoryHVRunner.app is missing or indirect" >&2; exit 1; }
[ -x "$HV_RUNNER_EXECUTABLE" ] && [ ! -L "$HV_RUNNER_EXECUTABLE" ] \
  || { echo "    ERROR: DoryHVRunner.app has no direct executable" >&2; exit 1; }
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$HV_RUNNER_APP/Contents/Info.plist" 2>/dev/null)" = dory-hv ] \
  || { echo "    ERROR: DoryHVRunner.app CFBundleExecutable is not dory-hv" >&2; exit 1; }
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$HV_RUNNER_APP/Contents/Info.plist" 2>/dev/null)" = com.pythonxi.Dory.HVRunner ] \
  || { echo "    ERROR: DoryHVRunner.app has the wrong bundle identifier" >&2; exit 1; }
macho_has_arches "$HV_RUNNER_EXECUTABLE" "$(swiftpm_helper_arches)" \
  || { echo "    ERROR: DoryHVRunner.app does not contain every requested helper architecture" >&2; exit 1; }
validate_xpc_worker_bundle \
  "$FS_WORKER_XPC" \
  com.pythonxi.Dory.HVRunner.FSWorker \
  DoryFSWorker \
  'filesystem worker'
validate_xpc_worker_bundle \
  "$RENDERER_WORKER_XPC" \
  com.pythonxi.Dory.HVRunner.RendererWorker \
  DoryRendererWorker \
  'renderer worker'
macho_has_arches "$FS_WORKER_EXECUTABLE" "$(swiftpm_helper_arches)" \
  || { echo "    ERROR: filesystem worker does not contain every requested helper architecture" >&2; exit 1; }
macho_has_arches "$RENDERER_WORKER_EXECUTABLE" "$(swiftpm_helper_arches)" \
  || { echo "    ERROR: renderer worker does not contain every requested helper architecture" >&2; exit 1; }
# Xcode owns this nested signature graph.  Mutating or repairing it here would split packaging
# authority from the Release target and make the archived candidate differ from its renderer
# inventory.  The final outer Dory.app is signed later after bundle-engine adds outer helpers.
codesign --verify --strict --verbose=2 "$FS_WORKER_XPC"
codesign --verify --strict --verbose=2 "$RENDERER_WORKER_XPC"
codesign --verify --deep --strict --verbose=2 "$HV_RUNNER_APP"

echo "==> Bundling gvproxy (userspace networking for the dory-hv engine)…"
# gvproxy (gvisor-tap-vsock, Apache-2.0) gives the HV engine NAT/DNS with no restricted
# entitlement. The normal path builds the hash-pinned upstream source plus Dory's audited IPv6
# patch into a fresh deterministic binary.
# DORY_GVPROXY is the only local-binary override, and it is subjected to the same verification.
dory_gvproxy_validate_overrides
GVPROXY_VERSION="$(dory_gvproxy_version)"
GVPROXY_SHA256="$(dory_gvproxy_expected_sha256)"
GVPROXY_SRC="${DORY_GVPROXY:-}"
GVPROXY_TMP=""
GVPROXY_SOURCE_KIND="explicit-override"
GVPROXY_BUILD_PROVENANCE=""
if [ -n "$GVPROXY_SRC" ]; then
  if [ ! -f "$GVPROXY_SRC" ] || [ ! -x "$GVPROXY_SRC" ]; then
    echo "    ERROR: explicit DORY_GVPROXY is not an executable file: $GVPROXY_SRC" >&2
    exit 1
  fi
  echo "    using verified explicit DORY_GVPROXY override"
else
  GVPROXY_SOURCE_KIND="pinned-source-build"
  GVPROXY_TMP="$(mktemp "${TMPDIR:-/tmp}/dory-gvproxy-${GVPROXY_VERSION}.XXXXXX")"
  GVPROXY_BUILD_PROVENANCE="$GVPROXY_TMP.provenance"
  echo "    building provenance-pinned dual-stack gvproxy ${GVPROXY_VERSION}…"
  if scripts/build-gvproxy.sh --output "$GVPROXY_TMP" --provenance "$GVPROXY_BUILD_PROVENANCE"; then
    GVPROXY_SRC="$GVPROXY_TMP"
  else
    rm -f "$GVPROXY_TMP" "$GVPROXY_BUILD_PROVENANCE"
    GVPROXY_TMP=""
    GVPROXY_BUILD_PROVENANCE=""
  fi
fi
if [ -n "$GVPROXY_SRC" ] && [ -x "$GVPROXY_SRC" ]; then
  if ! dory_verify_gvproxy_payload "$GVPROXY_SRC" "$GVPROXY_VERSION" "$GVPROXY_SHA256"; then
    rm -f "$GVPROXY_TMP" "$GVPROXY_BUILD_PROVENANCE"
    exit 1
  fi
  cp "$GVPROXY_SRC" "$HELPERS/gvproxy"
  codesign --force --options runtime --timestamp -s "${DORY_SIGN_ID:-Developer ID Application}" "$HELPERS/gvproxy" 2>/dev/null \
    || codesign --force -s - "$HELPERS/gvproxy"
  if [ -n "$GVPROXY_BUILD_PROVENANCE" ] && [ -s "$GVPROXY_BUILD_PROVENANCE" ]; then
    cp "$GVPROXY_BUILD_PROVENANCE" "$RESOURCES/gvproxy-provenance.txt"
    printf 'source=%s\n' "$GVPROXY_SOURCE_KIND" >> "$RESOURCES/gvproxy-provenance.txt"
  else
    {
      printf 'version=%s\n' "$GVPROXY_VERSION"
      printf 'verified_sha256=%s\n' "$GVPROXY_SHA256"
      printf 'source=%s\n' "$GVPROXY_SOURCE_KIND"
      printf 'source_env=DORY_GVPROXY\n'
    } > "$RESOURCES/gvproxy-provenance.txt"
  fi
  rm -f "$GVPROXY_TMP" "$GVPROXY_BUILD_PROVENANCE"
  GVPROXY_TMP=""
  GVPROXY_BUILD_PROVENANCE=""
  echo "    bundled verified dual-stack Helpers/gvproxy ($GVPROXY_VERSION, $GVPROXY_SOURCE_KIND)"
else
  rm -f "$GVPROXY_TMP" "$GVPROXY_BUILD_PROVENANCE"
  echo "    ERROR: could not obtain gvproxy — the dory-hv engine cannot run without it; refusing to ship a broken engine." >&2
  exit 1
fi

if [ "${DORY_BUNDLE_VENUS:-1}" = "1" ]; then
  bundle_venus_renderer
else
  echo "==> DORY_BUNDLE_VENUS=0: renderer release identity is unavailable"
fi
finalize_doryd_signature

echo "==> Bundling the host kubectl + docker CLIs (so k8s and the docker CLI need no separate install)…"
# Host-side CLIs Dory shells out to: kubectl (Kubernetes browser/apply/scale/exec) and docker (the
# optional `docker` context). Bundling them means a fresh download needs nothing installed.
# Universal releases must carry CLIs that run on both Apple silicon and Intel Macs; fetch each
# Darwin architecture and lipo them into one helper.

download_host_cli_for_arch() {
  local name="$1" arch="$2" out="$3" provenance="${4:-$HOST_CLI_PROVENANCE}"
  local karch darch tgz work url expected_sha
  expected_sha="$(dory_host_cli_expected_sha256 "$name" "$arch")"
  case "$name" in
    kubectl)
      karch="$(darwin_download_arch "$arch")"
      url="https://dl.k8s.io/release/${KVER}/bin/darwin/${karch}/kubectl"
      fetch_url "$url" "$out" || return 1
      dory_verify_host_cli_payload "$out" "$expected_sha" || return 1
      chmod 0755 "$out" || return 1
      ;;
    docker)
      darch="$(docker_download_arch "$arch")"
      tgz="$(mktemp "${TMPDIR:-/tmp}/dory-docker-$arch.XXXXXX.tgz")"
      work="$(mktemp -d "${TMPDIR:-/tmp}/dory-docker-$arch.XXXXXX")"
      url="https://download.docker.com/mac/static/stable/${darch}/docker-${DOCKER_CLI_VERSION}.tgz"
      fetch_url "$url" "$tgz" || return 1
      dory_verify_host_cli_payload "$tgz" "$expected_sha" || return 1
      tar -xzf "$tgz" -C "$work" docker/docker || return 1
      install -m0755 "$work/docker/docker" "$out" || return 1
      rm -rf "$tgz" "$work"
      ;;
    docker-compose)
      darch="$(docker_download_arch "$arch")"
      url="https://github.com/docker/compose/releases/download/${COMPOSE_VER}/docker-compose-darwin-${darch}"
      fetch_url "$url" "$out" || return 1
      dory_verify_host_cli_payload "$out" "$expected_sha" || return 1
      chmod 0755 "$out" || return 1
      ;;
    docker-buildx)
      darch="$(darwin_download_arch "$arch")"
      url="https://github.com/docker/buildx/releases/download/${BUILDX_VER}/buildx-${BUILDX_VER}.darwin-${darch}"
      fetch_url "$url" "$out" || return 1
      dory_verify_host_cli_payload "$out" "$expected_sha" || return 1
      chmod 0755 "$out" || return 1
      ;;
    docker-credential-osxkeychain)
      darch="$(darwin_download_arch "$arch")"
      url="https://github.com/docker/docker-credential-helpers/releases/download/${DOCKER_CREDENTIAL_HELPER_VERSION}/docker-credential-osxkeychain-${DOCKER_CREDENTIAL_HELPER_VERSION}.darwin-${darch}"
      fetch_url "$url" "$out" || return 1
      dory_verify_host_cli_payload "$out" "$expected_sha" || return 1
      chmod 0755 "$out" || return 1
      ;;
    *)
      echo "unknown host CLI: $name" >&2
      return 1
      ;;
  esac
  printf 'name=%s version=%s arch=%s sha256=%s source_url=%s\n' \
    "$name" "$(dory_host_cli_version "$name")" "$arch" "$expected_sha" "$url" \
    >> "$provenance"
}

bundle_universal_host_cli() {
  local name="$1" destination="${2:-$HELPERS/$1}" provenance="${3:-$HOST_CLI_PROVENANCE}"
  local tmp arch bin arches arch_info
  local built=()
  mkdir -p "$(dirname "$destination")"
  arches="$(host_cli_arches)"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dory-$name.XXXXXX")"
  for arch in $arches; do
    bin="$tmp/$name-$arch"
    if ! download_host_cli_for_arch "$name" "$arch" "$bin" "$provenance"; then
      rm -rf "$tmp"
      if [ "${DORY_ALLOW_MISSING_HOST_CLI:-0}" = "1" ]; then
        echo "    WARNING: could not bundle $name for $arch — feature will need a system install on that architecture."
        return 0
      fi
      echo "    ERROR: could not bundle $name for $arch; set DORY_ALLOW_MISSING_HOST_CLI=1 only for development artifacts." >&2
      exit 1
    fi
    built+=("$bin")
  done

  if [ "${#built[@]}" -eq 1 ]; then
    install -m0755 "${built[0]}" "$destination"
  else
    lipo -create "${built[@]}" -output "$destination"
    chmod 0755 "$destination"
  fi
  rm -rf "$tmp"
  sign_runtime_payload "$destination"
  arch_info="$(lipo -archs "$destination" 2>/dev/null || true)"
  echo "    bundled Helpers/$name${arch_info:+ ($arch_info)}"
}

dory_host_cli_validate_metadata
KVER="$(dory_host_cli_version kubectl)"
DOCKER_CLI_VERSION="$(dory_host_cli_version docker)"
BUILDX_VER="$(dory_host_cli_version docker-buildx)"
COMPOSE_VER="$(dory_host_cli_version docker-compose)"
DOCKER_CREDENTIAL_HELPER_VERSION="$(dory_host_cli_version docker-credential-osxkeychain)"
HOST_CLI_PROVENANCE="$RESOURCES/host-cli-provenance.txt"
# Homebrew's ZIP unpacker normalizes ordinary readable resource files to 0644. Keep this public
# provenance inventory at that canonical mode so a cask install remains byte-for-byte and
# metadata-for-metadata identical to the SBOM-bound application tree.
rm -f "$HOST_CLI_PROVENANCE"
install -m 0644 /dev/null "$HOST_CLI_PROVENANCE"
if [ "$COMPONENT_BUNDLE_MODE" = core ]; then
  KUBECTL_COMPONENT_OUTPUT="${DORY_COMPONENT_KUBECTL_OUTPUT:-}"
  [ -n "$KUBECTL_COMPONENT_OUTPUT" ] || {
    echo "    ERROR: Core builds require DORY_COMPONENT_KUBECTL_OUTPUT" >&2
    exit 64
  }
  case "$KUBECTL_COMPONENT_OUTPUT" in
    /*) ;;
    *) echo "    ERROR: DORY_COMPONENT_KUBECTL_OUTPUT must be an absolute path" >&2; exit 64 ;;
  esac
  case "$KUBECTL_COMPONENT_OUTPUT" in
    "$APP"/*) echo "    ERROR: the Kubernetes component must be exported outside Dory.app" >&2; exit 64 ;;
  esac
  KUBECTL_COMPONENT_PROVENANCE="${DORY_COMPONENT_KUBECTL_PROVENANCE_OUTPUT:-$KUBECTL_COMPONENT_OUTPUT.provenance.txt}"
  mkdir -p "$(dirname "$KUBECTL_COMPONENT_PROVENANCE")"
  rm -f "$KUBECTL_COMPONENT_PROVENANCE"
  install -m 0644 /dev/null "$KUBECTL_COMPONENT_PROVENANCE"
  bundle_universal_host_cli kubectl "$KUBECTL_COMPONENT_OUTPUT" "$KUBECTL_COMPONENT_PROVENANCE"
  LC_ALL=C sort -o "$KUBECTL_COMPONENT_PROVENANCE" "$KUBECTL_COMPONENT_PROVENANCE"
  chmod 0644 "$KUBECTL_COMPONENT_PROVENANCE"
  rm -f "$HELPERS/kubectl"
  echo "    exported the signed Kubernetes component to $KUBECTL_COMPONENT_OUTPUT"
else
  bundle_universal_host_cli kubectl
fi
bundle_universal_host_cli docker
bundle_universal_host_cli docker-credential-osxkeychain
bundle_universal_host_cli docker-buildx
bundle_universal_host_cli docker-compose
LC_ALL=C sort -o "$HOST_CLI_PROVENANCE" "$HOST_CLI_PROVENANCE"
chmod 0644 "$HOST_CLI_PROVENANCE"

# Keep the CLI and doctor together so a clean install needs no external Dory tooling.
echo "==> Bundling the dory CLI helpers (Health panel + doctor/compat)…"
DORY_SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
BUNDLED_APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP/Contents/Info.plist")"
[ -n "$BUNDLED_APP_VERSION" ] || {
  echo "ERROR: Dory.app has no CFBundleShortVersionString" >&2
  exit 1
}
for script in dory dory-doctor; do
  if [ -f "$DORY_SCRIPTS/$script" ]; then
    install -m0755 "$DORY_SCRIPTS/$script" "$HELPERS/$script"
    if [ "$script" = dory ]; then
      python3 - "$HELPERS/$script" "$BUNDLED_APP_VERSION" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
version = sys.argv[2]
source, replacements = re.subn(
    r'(?m)^DORY_CLI_VERSION="[^"]+"$',
    f'DORY_CLI_VERSION="{version}"',
    path.read_text(),
)
if replacements != 1:
    raise SystemExit(f"expected one DORY_CLI_VERSION assignment in {path}")
path.write_text(source)
PY
    fi
    codesign --force --timestamp -s "${DORY_SIGN_ID:-Developer ID Application}" "$HELPERS/$script" 2>/dev/null \
      || codesign --force -s - "$HELPERS/$script"
    echo "    bundled + signed Helpers/$script"
  else
    echo "    WARNING: $DORY_SCRIPTS/$script missing — the Health panel will need a system dory install."
  fi
done

# No external zstd: the engine kernel/initfs are compressed with LZFSE by dory-hv itself (below) and
# decompressed in-process at first launch via Apple's Compression framework, so nothing external is
# linked or bundled for decompression.

host_guest_arch() {
  [ "$(uname -m)" = "x86_64" ] && printf '%s\n' "amd64" || printf '%s\n' "arm64"
}

native_guest_arch() {
  case "${DORY_BUNDLE_NATIVE_ARCH:-$(host_guest_arch)}" in
    arm64|aarch64) printf '%s\n' "arm64" ;;
    amd64|x86_64) printf '%s\n' "amd64" ;;
    *) host_guest_arch ;;
  esac
}

env_for_arch() {
  local prefix="$1" arch="$2" upper_arch
  upper_arch="$(printf '%s' "$arch" | tr '[:lower:]-' '[:upper:]_')"
  printf '%s_%s' "$prefix" "$upper_arch"
}

kernel_source_for_arch() {
  local arch="$1" env_name
  env_name="$(env_for_arch DORY_KERNEL "$arch")"
  if [ -n "${!env_name:-}" ]; then printf '%s\n' "${!env_name}"; return 0; fi
  if [ "$arch" = "$(host_guest_arch)" ] && [ -n "${DORY_KERNEL:-}" ]; then printf '%s\n' "$DORY_KERNEL"; return 0; fi
  if [ "$arch" = "arm64" ] && [ -f "$(dirname "$0")/../guest/out/Image" ]; then printf '%s\n' "$(dirname "$0")/../guest/out/Image"; return 0; fi
  if [ "$arch" = "amd64" ] && [ -f "$(dirname "$0")/../guest/out/bzImage-x86" ]; then printf '%s\n' "$(dirname "$0")/../guest/out/bzImage-x86"; return 0; fi
  if [ "$arch" = "arm64" ] && [ "$arch" = "$(host_guest_arch)" ]; then ls -t "$SUPPORT"/kernels/vmlinux-* 2>/dev/null | head -1; fi
}

hv_kernel_source_for_arch() {
  local arch="$1" env_name
  env_name="$(env_for_arch DORY_HV_KERNEL "$arch")"
  if [ -n "${!env_name:-}" ]; then printf '%s\n' "${!env_name}"; return 0; fi
  if [ "$arch" = "$(host_guest_arch)" ] && [ -n "${DORY_HV_KERNEL:-}" ]; then printf '%s\n' "$DORY_HV_KERNEL"; return 0; fi
  if [ "$arch" = "arm64" ] && [ -f "$(dirname "$0")/../guest/out/Image" ]; then printf '%s\n' "$(dirname "$0")/../guest/out/Image"; return 0; fi
  if [ "$arch" = "amd64" ] && [ -f "$(dirname "$0")/../guest/out/vmlinux-x86" ]; then printf '%s\n' "$(dirname "$0")/../guest/out/vmlinux-x86"; return 0; fi
  if [ "$arch" = "arm64" ] && [ "$arch" = "$(host_guest_arch)" ]; then ls -t "$SUPPORT"/kernels/vmlinux-* 2>/dev/null | head -1; fi
}

# Separate GPU-enabled kernel (built with DORY_EXPERIMENTAL_GPU=1 guest/kernel/build.sh, which now
# writes /out/Image-gpu). Kept distinct so the default kernel stays headless per the project doc.
hv_gpu_kernel_source_for_arch() {
  local arch="$1" env_name
  env_name="$(env_for_arch DORY_HV_GPU_KERNEL "$arch")"
  if [ -n "${!env_name:-}" ]; then printf '%s\n' "${!env_name}"; return 0; fi
  if [ "$arch" = "$(host_guest_arch)" ] && [ -n "${DORY_HV_GPU_KERNEL:-}" ]; then printf '%s\n' "$DORY_HV_GPU_KERNEL"; return 0; fi
  if [ "$arch" = "arm64" ] && [ -f "$(dirname "$0")/../guest/out/Image-gpu" ]; then printf '%s\n' "$(dirname "$0")/../guest/out/Image-gpu"; return 0; fi
  if [ "$arch" = "amd64" ] && [ -f "$(dirname "$0")/../guest/out/vmlinux-x86-gpu" ]; then printf '%s\n' "$(dirname "$0")/../guest/out/vmlinux-x86-gpu"; return 0; fi
}

hv_gpu_kernel_override_for_arch() {
  local arch="$1" env_name
  env_name="$(env_for_arch DORY_HV_GPU_KERNEL "$arch")"
  if [ -n "${!env_name:-}" ]; then printf '%s\n' "${!env_name}"; return 0; fi
  if [ "$arch" = "$(host_guest_arch)" ] && [ -n "${DORY_HV_GPU_KERNEL:-}" ]; then
    printf '%s\n' "$DORY_HV_GPU_KERNEL"
    return 0
  fi
  return 1
}

initfs_source_for_arch() {
  local arch="$1" env_name
  env_name="$(env_for_arch DORY_INITFS "$arch")"
  if [ -n "${!env_name:-}" ]; then printf '%s\n' "${!env_name}"; return 0; fi
  if [ "$arch" = "$(host_guest_arch)" ] && [ -n "${DORY_INITFS:-}" ]; then printf '%s\n' "$DORY_INITFS"; return 0; fi
  if [ -f "$(dirname "$0")/../guest/out/initfs-$arch.ext4" ]; then printf '%s\n' "$(dirname "$0")/../guest/out/initfs-$arch.ext4"; return 0; fi
}

guest_agent_source_for_arch() {
  local arch="$1" env_name agent
  env_name="$(env_for_arch DORY_GUEST_AGENT "$arch")"
  if [ -n "${!env_name:-}" ] && [ -f "${!env_name}" ]; then printf '%s\n' "${!env_name}"; return 0; fi
  if [ "$arch" = "$(host_guest_arch)" ] && [ -n "${DORY_GUEST_AGENT:-}" ] && [ -f "$DORY_GUEST_AGENT" ]; then printf '%s\n' "$DORY_GUEST_AGENT"; return 0; fi
  agent="$(dirname "$0")/../guest/out/dory-agent-$arch"
  if [ -f "$agent" ]; then printf '%s\n' "$agent"; return 0; fi
  agent="$(dirname "$0")/../guest/out/dory-agent"
  if [ "$arch" = "arm64" ] && [ -f "$agent" ]; then printf '%s\n' "$agent"; return 0; fi
  return 1
}

engine_rootfs_source_for_arch() {
  local arch="$1" env_name
  env_name="$(env_for_arch DORY_ENGINE_ROOTFS "$arch")"
  if [ -n "${!env_name:-}" ] && [ -f "${!env_name}" ]; then
    printf '%s\n' "${!env_name}"
    return 0
  fi
  if [ "$arch" = "$(host_guest_arch)" ] && [ -n "${DORY_ENGINE_ROOTFS:-}" ] && [ -f "$DORY_ENGINE_ROOTFS" ]; then
    printf '%s\n' "$DORY_ENGINE_ROOTFS"
    return 0
  fi
  if [ -f "$(dirname "$0")/../guest/out/dory-engine-rootfs-$arch.ext4" ]; then
    printf '%s\n' "$(dirname "$0")/../guest/out/dory-engine-rootfs-$arch.ext4"
    return 0
  fi
  if [ -f "$(dirname "$0")/../guest/out/initfs-$arch.ext4" ]; then
    printf '%s\n' "$(dirname "$0")/../guest/out/initfs-$arch.ext4"
    return 0
  fi
  if [ "$arch" = "$(host_guest_arch)" ] && [ -f "$HOME/.dory/hv/rootfs-pristine.ext4" ]; then
    printf '%s\n' "$HOME/.dory/hv/rootfs-pristine.ext4"
    return 0
  fi
  return 1
}

desktop_kernel_source_for_arch() {
  local arch="$1" env_name
  [ "$arch" = "arm64" ] || return 1
  env_name="$(env_for_arch DORY_DESKTOP_KERNEL "$arch")"
  if [ -n "${!env_name:-}" ] && [ -f "${!env_name}" ]; then
    printf '%s\n' "${!env_name}"
    return 0
  fi
  if [ -n "${DORY_DESKTOP_KERNEL:-}" ] && [ -f "$DORY_DESKTOP_KERNEL" ]; then
    printf '%s\n' "$DORY_DESKTOP_KERNEL"
    return 0
  fi
  [ -f "$REPO_ROOT/guest/out/Image-desktop" ] && printf '%s\n' "$REPO_ROOT/guest/out/Image-desktop"
}

desktop_rootfs_source_for_arch() {
  local arch="$1" distro="$2" env_name distro_env
  [ "$arch" = "arm64" ] || return 1
  distro_env="DORY_DESKTOP_$(printf '%s' "$distro" | tr '[:lower:]' '[:upper:]')_ROOTFS"
  env_name="$(env_for_arch "$distro_env" "$arch")"
  if [ -n "${!env_name:-}" ] && [ -f "${!env_name}" ]; then
    printf '%s\n' "${!env_name}"
    return 0
  fi
  if [ "$distro" = "debian" ] && [ -n "${DORY_DESKTOP_ROOTFS:-}" ] && [ -f "$DORY_DESKTOP_ROOTFS" ]; then
    printf '%s\n' "$DORY_DESKTOP_ROOTFS"
    return 0
  fi
  [ -f "$REPO_ROOT/guest/out/dory-desktop-$distro-rootfs-arm64.ext4" ] \
    && printf '%s\n' "$REPO_ROOT/guest/out/dory-desktop-$distro-rootfs-arm64.ext4"
}

host_darwin_arch() {
  normalize_darwin_arch "$(uname -m)"
}

lzfse_helper_path() {
  local helper host_arch
  if [ -n "${DORY_LZFSE_HELPER:-}" ] && [ -x "$DORY_LZFSE_HELPER" ]; then
    printf '%s\n' "$DORY_LZFSE_HELPER"
    return 0
  fi

  host_arch="$(host_darwin_arch)"
  helper="$HV_RUNNER_EXECUTABLE"
  if macho_has_arches "$helper" "$host_arch"; then
    printf '%s\n' "$helper"
    return 0
  fi

  echo "    ERROR: embedded DoryHVRunner.app has no $host_arch slice for asset compression" >&2
  echo "    Rebuild the Xcode runner for the host architecture or set DORY_LZFSE_HELPER to an explicit build tool." >&2
  exit 1
}

compress_asset() {  # raw_src  out.lzfse
  "$(lzfse_helper_path)" lzfse compress "$1" "$2"
}

bundle_hv_kernel_for_arch() {
  local arch="$1" kernel_src kernel_raw kernel_out
  kernel_src="$(hv_kernel_source_for_arch "$arch" || true)"
  kernel_raw="$RESOURCES/dory-hv-kernel-$arch"
  kernel_out="$RESOURCES/dory-hv-kernel-$arch.lzfse"
  if [ -n "$kernel_src" ] && [ -f "$kernel_src" ]; then
    if [ "$COMPONENT_BUNDLE_MODE" = legacy ]; then
      install -m0644 "$kernel_src" "$kernel_raw"
      echo "    bundled Resources/$(basename "$kernel_raw") ($(du -h "$kernel_raw" | awk '{print $1}'))"
    else
      rm -f "$kernel_raw"
    fi
    compress_asset "$kernel_src" "$kernel_out"
    echo "    bundled Resources/$(basename "$kernel_out") ($(du -h "$kernel_out" | awk '{print $1}'), from $(du -h "$kernel_src" | awk '{print $1}'))"
  else
    warn_or_fail_missing_bundle_asset "no $arch dory-hv kernel found; run guest/kernel/build.sh $arch or set $(env_for_arch DORY_HV_KERNEL "$arch")"
  fi
}

# Ships the GPU-enabled kernel as a distinct resource (dory-hv-kernel-gpu-<arch>.lzfse) selected at
# runtime only when GPU acceleration is on. Gated on DORY_BUNDLE_VENUS so headless-only builds skip
# it; the default headless kernel above is never overwritten.
bundle_hv_gpu_kernel_for_arch() {
  local arch="$1" kernel_src kernel_out override
  kernel_out="$RESOURCES/dory-hv-kernel-gpu-$arch.lzfse"
  if [ "${DORY_BUNDLE_VENUS:-1}" != "1" ]; then
    rm -f "$kernel_out"
    return 0
  fi
  if [ "$arch" != "arm64" ]; then
    rm -f "$kernel_out"
    echo "    note: Venus GPU is Apple-silicon-only; omitting unverified $arch GPU kernel"
    return 0
  fi
  override="$(hv_gpu_kernel_override_for_arch "$arch" || true)"
  if [ -n "$override" ] && [ "${DORY_ALLOW_UNVERIFIED_GUEST_ASSETS:-0}" != "1" ]; then
    echo "    ERROR: explicit $arch GPU kernel overrides require DORY_ALLOW_UNVERIFIED_GUEST_ASSETS=1 and are development-only" >&2
    exit 1
  fi
  kernel_src="$(hv_gpu_kernel_source_for_arch "$arch" || true)"
  if [ -n "$kernel_src" ] && [ -f "$kernel_src" ]; then
    if [ -z "$override" ] && ! DORY_EXPERIMENTAL_GPU=1 "$REPO_ROOT/guest/kernel/verify-build.sh" "$arch" >/dev/null 2>&1; then
      rm -f "$kernel_out"
      if [ "${DORY_BUNDLE_VENUS_REQUIRED:-0}" = "1" ] || [ "${DORY_PUBLIC_RELEASE:-0}" = "1" ]; then
        echo "    ERROR: required guest/out $arch GPU kernel is stale; rebuild it with DORY_EXPERIMENTAL_GPU=1 guest/kernel/build.sh $arch" >&2
        exit 1
      fi
      echo "    WARNING: omitting stale or unverified guest/out $arch GPU kernel; rebuild it with DORY_EXPERIMENTAL_GPU=1 guest/kernel/build.sh $arch" >&2
      return 0
    fi
    compress_asset "$kernel_src" "$kernel_out"
    echo "    bundled Resources/$(basename "$kernel_out") ($(du -h "$kernel_out" | awk '{print $1}'), from $(du -h "$kernel_src" | awk '{print $1}'))"
  else
    rm -f "$kernel_out"
    if [ "${DORY_BUNDLE_VENUS_REQUIRED:-0}" = "1" ] || [ "${DORY_PUBLIC_RELEASE:-0}" = "1" ]; then
      echo "    ERROR: required Apple-silicon GPU kernel is missing; build with DORY_EXPERIMENTAL_GPU=1 guest/kernel/build.sh arm64" >&2
      exit 1
    fi
    echo "    note: no $arch GPU kernel found; build with DORY_EXPERIMENTAL_GPU=1 guest/kernel/build.sh $arch or set $(env_for_arch DORY_HV_GPU_KERNEL "$arch") (GPU acceleration will be unavailable)"
  fi
}

bundle_guest_assets_for_arch() {
  local arch="$1" kernel_src initfs_src kernel_out initfs_raw initfs_out agent
  kernel_src="$(kernel_source_for_arch "$arch" || true)"
  initfs_src="$(initfs_source_for_arch "$arch" || true)"
  kernel_out="$RESOURCES/dory-vm-kernel-$arch.lzfse"
  initfs_raw="$RESOURCES/dory-machine-rootfs-$arch.ext4"
  initfs_out="$RESOURCES/dory-vm-initfs-$arch.ext4.lzfse"

  if [ -n "$kernel_src" ] && [ -f "$kernel_src" ]; then
    compress_asset "$kernel_src" "$kernel_out"
    echo "    bundled Resources/$(basename "$kernel_out") ($(du -h "$kernel_out" | awk '{print $1}'), from $(du -h "$kernel_src" | awk '{print $1}'))"
  else
    warn_or_fail_missing_bundle_asset "no $arch kernel found; run guest/kernel/build.sh $arch or set $(env_for_arch DORY_KERNEL "$arch")"
  fi

  INITFS_TO_BUNDLE="$initfs_src"
  if [ -n "$initfs_src" ] && [ -f "$initfs_src" ]; then
    agent="$(guest_agent_source_for_arch "$arch" || true)"
    inject_dory_agent_into_initfs "$initfs_src" "$agent" "/tmp/dory-initfs-$arch-agent-$$.ext4"
    inject_debug_toolbox_into_initfs "$INITFS_TO_BUNDLE" "$arch"
    if [ "$COMPONENT_BUNDLE_MODE" = legacy ]; then
      install -m0644 "$INITFS_TO_BUNDLE" "$initfs_raw"
      echo "    bundled Resources/$(basename "$initfs_raw") ($(du -h "$initfs_raw" | awk '{print $1}'))"
    else
      rm -f "$initfs_raw"
    fi
    compress_asset "$INITFS_TO_BUNDLE" "$initfs_out"
    echo "    bundled Resources/$(basename "$initfs_out") ($(du -h "$initfs_out" | awk '{print $1}'), from $(du -h "$INITFS_TO_BUNDLE" | awk '{print $1}'))"
    [ "$INITFS_TO_BUNDLE" = "$initfs_src" ] || rm -f "$INITFS_TO_BUNDLE"
  else
    warn_or_fail_missing_bundle_asset "no $arch initfs found; run guest/initfs/build.sh or set $(env_for_arch DORY_INITFS "$arch")"
  fi
}

bundle_guest_agent_for_arch() {
  local arch="$1" agent_src agent_out
  agent_src="$(guest_agent_source_for_arch "$arch" || true)"
  agent_out="$RESOURCES/dory-agent-linux-$arch"
  if [ -n "$agent_src" ] && [ -f "$agent_src" ]; then
    install -m0755 "$agent_src" "$agent_out"
    echo "    bundled Resources/$(basename "$agent_out") ($(du -h "$agent_out" | awk '{print $1}'))"
  else
    warn_or_fail_missing_bundle_asset "no $arch dory-agent found; run guest/initfs/build.sh $arch or set $(env_for_arch DORY_GUEST_AGENT "$arch")"
  fi
}

bundle_engine_rootfs_for_arch() {
  local arch="$1" rootfs_src rootfs_out
  rootfs_src="$(engine_rootfs_source_for_arch "$arch" || true)"
  rootfs_out="$RESOURCES/dory-engine-rootfs-$arch.ext4.lzfse"
  if [ -n "$rootfs_src" ] && [ -f "$rootfs_src" ]; then
    compress_asset "$rootfs_src" "$rootfs_out"
    echo "    bundled Resources/$(basename "$rootfs_out") ($(du -h "$rootfs_out" | awk '{print $1}'), from $(du -h "$rootfs_src" | awk '{print $1}'))"
  else
    warn_or_fail_missing_bundle_asset "no $arch engine rootfs found; run guest/initfs/build.sh $arch or set $(env_for_arch DORY_ENGINE_ROOTFS "$arch")"
  fi
}

link_core_vmm_assets_for_arch() {
  local arch="$1" kernel_target rootfs_target kernel_alias rootfs_alias
  [ "$COMPONENT_BUNDLE_MODE" = core ] || return 0
  kernel_target="dory-hv-kernel-$arch.lzfse"
  rootfs_target="dory-engine-rootfs-$arch.ext4.lzfse"
  kernel_alias="$RESOURCES/dory-vm-kernel-$arch.lzfse"
  rootfs_alias="$RESOURCES/dory-vm-initfs-$arch.ext4.lzfse"
  [ -s "$RESOURCES/$kernel_target" ] || {
    echo "    ERROR: focused Core build cannot alias missing $kernel_target" >&2
    return 1
  }
  [ -s "$RESOURCES/$rootfs_target" ] || {
    echo "    ERROR: focused Core build cannot alias missing $rootfs_target" >&2
    return 1
  }
  ln -sfn "$kernel_target" "$kernel_alias"
  ln -sfn "$rootfs_target" "$rootfs_alias"
  echo "    linked Resources/$(basename "$kernel_alias") -> $kernel_target"
  echo "    linked Resources/$(basename "$rootfs_alias") -> $rootfs_target"
}

bundle_desktop_assets_for_arch() {
  local arch="$1" kernel_src kernel_out distro distros rootfs_src rootfs_out metadata
  [ "$DESKTOP_BUNDLE_MODE" != none ] || return 0
  [ "$arch" = "arm64" ] || return 0
  case "$DESKTOP_BUNDLE_MODE" in
    all) distros="debian ubuntu kali" ;;
    *) distros="$DESKTOP_BUNDLE_MODE" ;;
  esac
  kernel_src="$(desktop_kernel_source_for_arch "$arch" || true)"
  if [ -z "$kernel_src" ]; then
    echo "    ERROR: all-inclusive build is missing the verified Apple Silicon desktop kernel" >&2
    return 1
  fi
  if [ "$kernel_src" = "$REPO_ROOT/guest/out/Image-desktop" ]; then
    DORY_KERNEL_PROFILE=accelerated-desktop \
      "$REPO_ROOT/guest/kernel/verify-build.sh" arm64 >/dev/null
  fi
  kernel_out="$RESOURCES/dory-desktop-kernel-arm64.lzfse"
  compress_asset "$kernel_src" "$kernel_out"
  echo "    bundled Resources/$(basename "$kernel_out") ($(du -h "$kernel_out" | awk '{print $1}'))"
  for distro in $distros; do
    rootfs_src="$(desktop_rootfs_source_for_arch "$arch" "$distro" || true)"
    if [ -z "$rootfs_src" ]; then
      echo "    ERROR: all-inclusive build is missing the verified $distro desktop image" >&2
      return 1
    fi
    if [ "$rootfs_src" = "$REPO_ROOT/guest/out/dory-desktop-$distro-rootfs-arm64.ext4" ]; then
      "$REPO_ROOT/guest/desktop/verify-build.sh" arm64 "$distro" >/dev/null
    fi
    rootfs_out="$RESOURCES/dory-desktop-$distro-rootfs-arm64.ext4.lzfse"
    compress_asset "$rootfs_src" "$rootfs_out"
    echo "    bundled Resources/$(basename "$rootfs_out") ($(du -h "$rootfs_out" | awk '{print $1}'))"
    for metadata in \
      "$REPO_ROOT/guest/out/dory-desktop-$distro-build-arm64.stamp" \
      "$REPO_ROOT/guest/out/dory-desktop-$distro-packages-arm64.txt"; do
      [ -s "$metadata" ] && install -m0644 "$metadata" "$RESOURCES/$(basename "$metadata")"
    done
  done
  metadata="$REPO_ROOT/guest/out/kernel-build-arm64-desktop.stamp"
  [ -s "$metadata" ] && install -m0644 "$metadata" "$RESOURCES/$(basename "$metadata")"
}

echo "==> Bundling VM kernel + initfs assets, compressed (so the engine needs no container install)…"
for asset_arch in ${DORY_BUNDLE_ARCHES:-arm64 amd64}; do
  bundle_guest_agent_for_arch "$asset_arch"
  bundle_hv_kernel_for_arch "$asset_arch"
  bundle_hv_gpu_kernel_for_arch "$asset_arch"
  if [ "$COMPONENT_BUNDLE_MODE" = legacy ]; then
    bundle_guest_assets_for_arch "$asset_arch"
  else
    # Docker Core already carries the exact kernel and rootfs needed by the macOS 14 VZ fallback.
    # Keep its historical resource names as in-bundle aliases instead of shipping a second copy of
    # each payload. Linux Machines remains an independently downloaded component with its own raw
    # machine rootfs and kernel.
    rm -f \
      "$RESOURCES/dory-vm-kernel-$asset_arch.lzfse" \
      "$RESOURCES/dory-vm-initfs-$asset_arch.ext4.lzfse"
  fi
  bundle_engine_rootfs_for_arch "$asset_arch"
  link_core_vmm_assets_for_arch "$asset_arch"
  bundle_desktop_assets_for_arch "$asset_arch"
  for stamp_kind in kernel initfs; do
    stamp="$REPO_ROOT/guest/out/${stamp_kind}-build-$asset_arch.stamp"
    if [ -s "$stamp" ]; then
      install -m0644 "$stamp" "$RESOURCES/dory-${stamp_kind}-build-$asset_arch.stamp"
    elif [ "${DORY_PUBLIC_RELEASE:-0}" = "1" ]; then
      echo "    ERROR: public release is missing verified guest build stamp: $stamp" >&2
      exit 1
    fi
  done
  if [ "$asset_arch" = arm64 ] && [ "${DORY_BUNDLE_VENUS:-1}" = "1" ]; then
    gpu_stamp="$REPO_ROOT/guest/out/kernel-build-arm64-gpu.stamp"
    if [ -s "$gpu_stamp" ]; then
      install -m0644 "$gpu_stamp" "$RESOURCES/dory-kernel-build-arm64-gpu.stamp"
    elif [ "${DORY_BUNDLE_VENUS_REQUIRED:-0}" = "1" ] || [ "${DORY_PUBLIC_RELEASE:-0}" = "1" ]; then
      echo "    ERROR: Venus-enabled release is missing verified GPU build stamp: $gpu_stamp" >&2
      exit 1
    fi
  fi
done

HOST_GUEST_ARCH="$(native_guest_arch)"
if [ -f "$RESOURCES/dory-hv-kernel-$HOST_GUEST_ARCH.lzfse" ]; then
  ln -sf "dory-hv-kernel-$HOST_GUEST_ARCH.lzfse" "$RESOURCES/dory-hv-kernel.lzfse"
fi
if [ -f "$RESOURCES/dory-hv-kernel-$HOST_GUEST_ARCH" ]; then
  ln -sf "dory-hv-kernel-$HOST_GUEST_ARCH" "$RESOURCES/dory-hv-kernel"
fi
if [ -f "$RESOURCES/dory-machine-rootfs-$HOST_GUEST_ARCH.ext4" ]; then
  ln -sf "dory-machine-rootfs-$HOST_GUEST_ARCH.ext4" "$RESOURCES/dory-machine-rootfs.ext4"
fi
if [ -f "$RESOURCES/dory-vm-kernel-$HOST_GUEST_ARCH.lzfse" ]; then
  ln -sf "dory-vm-kernel-$HOST_GUEST_ARCH.lzfse" "$RESOURCES/dory-vm-kernel.lzfse"
fi
if [ -f "$RESOURCES/dory-vm-initfs-$HOST_GUEST_ARCH.ext4.lzfse" ]; then
  ln -sf "dory-vm-initfs-$HOST_GUEST_ARCH.ext4.lzfse" "$RESOURCES/dory-vm-initfs.ext4.lzfse"
fi
if [ -f "$RESOURCES/dory-engine-rootfs-$HOST_GUEST_ARCH.ext4.lzfse" ]; then
  ln -sf "dory-engine-rootfs-$HOST_GUEST_ARCH.ext4.lzfse" "$RESOURCES/dory-engine-rootfs.ext4.lzfse"
fi

write_doryd_launch_agent

/usr/libexec/PlistBuddy -c 'Delete :DoryIncludesDesktopLinux' "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c 'Delete :DoryBundledComponents' "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c 'Add :DoryBundledComponents array' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :DoryBundledComponents:0 string docker-core' "$APP/Contents/Info.plist"
if [ "$DESKTOP_BUNDLE_MODE" != none ]; then
  /usr/libexec/PlistBuddy -c 'Add :DoryIncludesDesktopLinux bool true' "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :SUFeedURL $DESKTOP_APPCAST_URL" "$APP/Contents/Info.plist"
  for component in kubernetes linux-machines linux-desktop; do
    /usr/libexec/PlistBuddy -c "Add :DoryBundledComponents: string $component" "$APP/Contents/Info.plist"
  done
  case "$DESKTOP_BUNDLE_MODE" in
    all) desktop_distros="debian ubuntu kali" ;;
    *) desktop_distros="$DESKTOP_BUNDLE_MODE" ;;
  esac
  for component in $desktop_distros; do
    /usr/libexec/PlistBuddy -c "Add :DoryBundledComponents: string desktop-$component" "$APP/Contents/Info.plist"
  done
else
  /usr/libexec/PlistBuddy -c 'Add :DoryIncludesDesktopLinux bool false' "$APP/Contents/Info.plist"
  if [ "$COMPONENT_BUNDLE_MODE" = legacy ]; then
    for component in kubernetes linux-machines; do
      /usr/libexec/PlistBuddy -c "Add :DoryBundledComponents: string $component" "$APP/Contents/Info.plist"
    done
  fi
fi

echo "==> Bundling deterministic named-volume transfer helper image…"
scripts/build-transfer-helper.sh \
  --image-output "$RESOURCES/dory-transfer-helper-image-arm64.tar" \
  --image-metadata-output "$RESOURCES/dory-transfer-helper-image-arm64.json" >/dev/null
TRANSFER_HELPER_METADATA="$(python3 scripts/build-transfer-helper-image.py \
  --verify "$RESOURCES/dory-transfer-helper-image-arm64.tar" \
  --expected-helper-sha256 "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["helperSha256"])' \
    "$RESOURCES/dory-transfer-helper-image-arm64.json")")"
[ "$TRANSFER_HELPER_METADATA" = \
  "$(tr -d '\n' < "$RESOURCES/dory-transfer-helper-image-arm64.json")" ] \
  || { echo "    ERROR: transfer-helper metadata mismatch" >&2; exit 1; }
echo "    bundled Resources/dory-transfer-helper-image-arm64.tar"

# Seal a deterministic digest inventory inside the app before its outer Developer ID signature is
# applied. This gives support and release validation an exact map of every helper and guest asset,
# while the app signature protects the inventory itself from post-build edits.
PAYLOAD_DIGESTS="$RESOURCES/dory-payload-sha256.txt"
(
  cd "$APP"
  find Contents/Helpers Contents/Resources -type f \
    ! -name 'dory-payload-sha256.txt' -print \
    | LC_ALL=C sort \
    | while IFS= read -r payload; do
        shasum -a 256 "$payload"
      done
) > "$PAYLOAD_DIGESTS"
[ -s "$PAYLOAD_DIGESTS" ] || { echo "    ERROR: payload digest inventory is empty" >&2; exit 1; }
echo "    bundled Resources/dory-payload-sha256.txt"

echo "==> Payload injected into $APP"
echo "    Component profile: $COMPONENT_BUNDLE_MODE"
echo "    Engine payload ≈ $(du -ch "$RESOURCES"/dory-hv-*.lzfse "$RESOURCES"/dory-vm-*.lzfse "$RESOURCES"/dory-engine-rootfs-*.ext4.lzfse "$RESOURCES"/dory-desktop-*.lzfse "$HV_RUNNER_APP" "$HELPERS"/docker "$HELPERS"/docker-buildx "$HELPERS"/docker-compose "$HELPERS"/kubectl "$FRAMEWORKS"/*.dylib 2>/dev/null | tail -1 | awk '{print $1}') on disk"
echo "    Re-sign the app bundle before notarization so the payload is sealed."
