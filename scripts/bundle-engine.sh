#!/bin/bash
# Make a built Dory.app self-contained so users download ONLY the app — no Docker Desktop, Colima,
# OrbStack, Homebrew, or `brew install container` on the user's Mac.
#
# Bundled payload:
#   * Contents/Helpers/doryd     — launchd/XPC daemon that owns the engine, idle policy, networking,
#                                   health, and Linux machine lifecycle.
#   * Contents/Helpers/dorydctl  — diagnostic/control CLI used by readiness and support flows.
#   * Contents/Helpers/dory-vmm  — per-machine Virtualization.framework helper and macOS 14 Docker
#                                   engine fallback, signed with com.apple.security.virtualization.
#   * Contents/Helpers/dory-network-helper — local networking helper for doryd-owned domains/routes.
#   * Contents/Helpers/dory-hv    — Dory's own Hypervisor.framework VMM (elastic memory via free-page
#                                   reporting, SMP, journaled data disk), signed with
#                                   com.apple.security.hypervisor. Preferred where available.
#   * Contents/Helpers/gvproxy    — userspace networking (Apache-2.0) for the dory-hv engine.
#   * Contents/Helpers/docker, docker-buildx, docker-compose, kubectl — clean-Mac host CLIs.
#   * Contents/Frameworks/libvirglrenderer.dylib, libMoltenVK.dylib — optional experimental
#                                   Venus/Vulkan renderer payload for in-guest GPU acceleration.
#   * Contents/Resources/dory-hv-kernel-<arch>             — raw kernel path used by doryd/dory-hv.
#   * Contents/Resources/dory-machine-rootfs-<arch>.ext4   — raw per-machine rootfs used by dory-vmm.
#   * Contents/Resources/dory-hv-kernel-<arch>.lzfse       — LZFSE PVH/Image kernel for dory-hv.
#   * Contents/Resources/dory-vm-kernel-<arch>.lzfse       — LZFSE Linux kernel.
#   * Contents/Resources/dory-vm-initfs-<arch>.ext4.lzfse  — LZFSE VM initfs.
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
SUPPORT="$HOME/Library/Application Support/com.apple.container"

[ -d "$APP" ] || { echo "no such app bundle: $APP"; exit 1; }
mkdir -p "$RESOURCES" "$HELPERS" "$FRAMEWORKS"

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

  local attempt err
  err="$(mktemp "${TMPDIR:-/tmp}/dory-codesign.XXXXXX")"
  for attempt in 1 2 3; do
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

bundle_swiftpm_executable() {
  local package="$1" configuration="$2" product="$3" destination="$4" entitlements="${5:-}"
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

  if [ -n "$entitlements" ]; then
    sign_runtime_payload_with_entitlements "$destination" "$entitlements"
  else
    sign_runtime_payload "$destination"
  fi
  arch_info="$(lipo -archs "$destination" 2>/dev/null || true)"
  echo "    bundled Helpers/$(basename "$destination")${arch_info:+ ($arch_info)}"
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

fetch_url_stdout() {
  local url="$1"
  curl -fsSL \
    --retry "${DORY_CURL_RETRIES:-2}" \
    --retry-delay "${DORY_CURL_RETRY_DELAY:-2}" \
    --connect-timeout "${DORY_CURL_CONNECT_TIMEOUT:-15}" \
    --max-time "${DORY_CURL_MAX_TIME:-240}" \
    "$url"
}

dylib_has_symbol() {
  local dylib="$1" symbol="$2"
  [ -f "$dylib" ] || return 1
  nm -gU "$dylib" 2>/dev/null | grep -q "_$symbol"
}

find_compatible_virglrenderer() {
  local cand
  for cand in "${DORY_VIRGLRENDERER_PATH:-}" \
              "${DORY_VIRGLRENDERER:-}" \
              "$FRAMEWORKS/libvirglrenderer.dylib" \
              /opt/homebrew/lib/libvirglrenderer.dylib \
              /opt/homebrew/opt/virglrenderer/lib/libvirglrenderer.dylib \
              /opt/homebrew/opt/virglrenderer/lib/libvirglrenderer.1.dylib \
              /usr/local/lib/libvirglrenderer.dylib \
              /usr/local/opt/virglrenderer/lib/libvirglrenderer.dylib \
              /usr/local/opt/virglrenderer/lib/libvirglrenderer.1.dylib; do
    [ -n "$cand" ] && [ -f "$cand" ] || continue
    # The Venus path maps host-visible blobs via virgl_renderer_resource_get_map_ptr (the
    # libkrun/krunkit model); the slp/krunkit build exports it. resource_map is the fallback.
    if dylib_has_symbol "$cand" virgl_renderer_resource_get_map_ptr \
       || dylib_has_symbol "$cand" virgl_renderer_resource_map; then
      printf '%s\n' "$cand"
      return 0
    fi
    echo "    WARNING: $cand exports no virgl_renderer_resource_get_map_ptr/resource_map; skipping for Venus GPU bundling" >&2
  done
  return 1
}

find_moltenvk_icd() {
  local cand old_ifs
  if [ -n "${DORY_MOLTENVK_ICD:-}" ] && [ -f "$DORY_MOLTENVK_ICD" ]; then
    printf '%s\n' "$DORY_MOLTENVK_ICD"
    return 0
  fi
  if [ -n "${VK_ICD_FILENAMES:-}" ]; then
    old_ifs="$IFS"
    IFS=':'
    for cand in $VK_ICD_FILENAMES; do
      IFS="$old_ifs"
      [ -n "$cand" ] && [ -f "$cand" ] && { printf '%s\n' "$cand"; return 0; }
      IFS=':'
    done
    IFS="$old_ifs"
  fi
  for cand in "$RESOURCES/vulkan/icd.d/MoltenVK_icd.json" \
              /opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json \
              /opt/homebrew/share/vulkan/icd.d/MoltenVK_icd.json \
              /usr/local/etc/vulkan/icd.d/MoltenVK_icd.json \
              /usr/local/share/vulkan/icd.d/MoltenVK_icd.json; do
    [ -n "$cand" ] && [ -f "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

find_moltenvk_dylib() {
  local icd="${1:-}" library_path cand base_dir relative_dir
  if [ -n "${DORY_MOLTENVK_DYLIB:-}" ] && [ -f "$DORY_MOLTENVK_DYLIB" ]; then
    printf '%s\n' "$DORY_MOLTENVK_DYLIB"
    return 0
  fi
  if [ -n "$icd" ] && [ -f "$icd" ]; then
    library_path="$(sed -nE 's/.*"library_path"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$icd" | head -1)"
    if [ -n "$library_path" ]; then
      if [ "${library_path#/}" != "$library_path" ] && [ -f "$library_path" ]; then
        printf '%s\n' "$library_path"
        return 0
      fi
      base_dir="$(cd "$(dirname "$icd")" && pwd)"
      relative_dir="$(dirname "$library_path")"
      cand="$(cd "$base_dir/$relative_dir" 2>/dev/null && pwd)/$(basename "$library_path")"
      [ -f "$cand" ] && { printf '%s\n' "$cand"; return 0; }
    fi
  fi
  for cand in "$FRAMEWORKS/libMoltenVK.dylib" \
              /opt/homebrew/lib/libMoltenVK.dylib \
              /opt/homebrew/opt/molten-vk/lib/libMoltenVK.dylib \
              /usr/local/lib/libMoltenVK.dylib \
              /usr/local/opt/molten-vk/lib/libMoltenVK.dylib; do
    [ -n "$cand" ] && [ -f "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

is_bundle_dependency() {
  case "$1" in
    /System/*|/usr/lib/*|@rpath/*|@loader_path/*|@executable_path/*) return 1 ;;
    /opt/homebrew/*|/usr/local/*|/opt/local/*|/Library/Frameworks/*) return 0 ;;
    *) return 1 ;;
  esac
}

BUNDLED_DYLIBS=""
copy_dylib_dependency_closure() {
  local src="$1" dest_name="${2:-}" dest dep dep_base deps
  [ -f "$src" ] || return 0
  [ -n "$dest_name" ] || dest_name="$(basename "$src")"
  case "|$BUNDLED_DYLIBS|" in
    *"|$dest_name|"*) return 0 ;;
  esac
  BUNDLED_DYLIBS="${BUNDLED_DYLIBS}|$dest_name"
  dest="$FRAMEWORKS/$dest_name"
  cp "$src" "$dest"
  chmod 0755 "$dest"
  install_name_tool -id "@rpath/$dest_name" "$dest" 2>/dev/null || true
  # @loader_path lets each bundled dylib resolve its @rpath siblings (all in Contents/Frameworks)
  # without depending on the loading executable carrying an rpath to Frameworks — fully self-contained.
  install_name_tool -add_rpath @loader_path "$dest" 2>/dev/null || true

  deps="$(otool -L "$dest" 2>/dev/null | awk 'NR > 1 {print $1}')"
  for dep in $deps; do
    is_bundle_dependency "$dep" || continue
    [ -f "$dep" ] || { echo "    WARNING: dependency $dep is referenced by $dest_name but was not found"; continue; }
    dep_base="$(basename "$dep")"
    copy_dylib_dependency_closure "$dep" "$dep_base"
    install_name_tool -change "$dep" "@rpath/$dep_base" "$dest" 2>/dev/null || true
  done
}

warn_or_fail_optional_venus() {
  local message="$1"
  if [ "${DORY_BUNDLE_VENUS_REQUIRED:-0}" = "1" ]; then
    echo "    ERROR: $message" >&2
    exit 1
  fi
  echo "    WARNING: $message"
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
  local virgl icd molten bundled_icd dylib
  echo "==> Bundling experimental Venus GPU renderer (virglrenderer + MoltenVK)…"
  if ! virgl="$(find_compatible_virglrenderer)"; then
    warn_or_fail_optional_venus "no compatible libvirglrenderer.dylib found; install the slp/krunkit tap (brew install slp/krunkit/virglrenderer molten-vk libepoxy) or set DORY_VIRGLRENDERER_PATH to a Venus build that exports virgl_renderer_resource_get_map_ptr"
    return 0
  fi
  if ! icd="$(find_moltenvk_icd)"; then
    warn_or_fail_optional_venus "MoltenVK_icd.json not found; install/provide MoltenVK or set DORY_MOLTENVK_ICD"
    return 0
  fi
  if ! molten="$(find_moltenvk_dylib "$icd")"; then
    warn_or_fail_optional_venus "libMoltenVK.dylib not found; install/provide MoltenVK or set DORY_MOLTENVK_DYLIB"
    return 0
  fi

  mkdir -p "$FRAMEWORKS" "$RESOURCES/vulkan/icd.d"
  BUNDLED_DYLIBS=""
  copy_dylib_dependency_closure "$virgl" libvirglrenderer.dylib
  copy_dylib_dependency_closure "$molten" libMoltenVK.dylib

  if ! dylib_has_symbol "$FRAMEWORKS/libvirglrenderer.dylib" virgl_renderer_resource_get_map_ptr \
     && ! dylib_has_symbol "$FRAMEWORKS/libvirglrenderer.dylib" virgl_renderer_resource_map; then
    warn_or_fail_optional_venus "bundled libvirglrenderer.dylib exports no virgl_renderer_resource_get_map_ptr/resource_map"
    return 0
  fi

  bundled_icd="$RESOURCES/vulkan/icd.d/MoltenVK_icd.json"
  if grep -q '"library_path"' "$icd"; then
    sed -E 's#"library_path"[[:space:]]*:[[:space:]]*"[^"]+"#"library_path": "@executable_path/../Frameworks/libMoltenVK.dylib"#' "$icd" > "$bundled_icd"
  else
    cp "$icd" "$bundled_icd"
    echo "    WARNING: bundled MoltenVK ICD has no library_path entry to rewrite"
  fi

  while IFS= read -r dylib; do
    [ -n "$dylib" ] || continue
    # Belt-and-suspenders self-containment: rewrite any remaining absolute homebrew/local dep to
    # @rpath and guarantee a @loader_path rpath, so the bundled runtime never needs those libs on the
    # user's Mac. Then (re-)sign, since the edits invalidate the signature.
    for dep in $(otool -L "$dylib" | awk 'NR>1{print $1}'); do
      case "$dep" in
        /opt/homebrew/*|/usr/local/*)
          install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$dylib" 2>/dev/null || true ;;
      esac
    done
    otool -l "$dylib" | grep -q "path @loader_path " || install_name_tool -add_rpath @loader_path "$dylib" 2>/dev/null || true
    sign_runtime_payload "$dylib"
  done < <(find "$FRAMEWORKS" -maxdepth 1 -type f -name '*.dylib' -print)

  echo "    bundled Frameworks/libvirglrenderer.dylib (from $virgl)"
  echo "    bundled Frameworks/libMoltenVK.dylib (from $molten)"
  echo "    bundled Resources/vulkan/icd.d/MoltenVK_icd.json"
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
  hv="$HELPERS/dory-hv"
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
  local configuration entitlements product helper
  [ "${DORY_BUNDLE_DORYD:-1}" = "1" ] || { echo "==> DORY_BUNDLE_DORYD=0: skipping doryd helper bundling"; return 0; }
  [ -f "dory-core-swift/Package.swift" ] || { echo "    ERROR: dory-core-swift/Package.swift missing; cannot build doryd helpers" >&2; exit 1; }
  configuration="${DORY_DORYD_HELPER_CONFIGURATION:-release}"

  entitlements="$(mktemp "${TMPDIR:-/tmp}/dory-vmm-entitlements.XXXXXX")"
  cat > "$entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.virtualization</key><true/></dict></plist>
PLIST

  echo "==> Building + signing doryd launchd helpers ($configuration, arches: $(swiftpm_helper_arches))…"
  for product in doryd dorydctl dory-vmm dory-network-helper dory-dataplane-proxy; do
    helper="$HELPERS/$product"
    if [ "$product" = "dory-vmm" ]; then
      bundle_swiftpm_executable "dory-core-swift" "$configuration" "$product" "$helper" "$entitlements"
    else
      bundle_swiftpm_executable "dory-core-swift" "$configuration" "$product" "$helper"
    fi
  done
  mkdir -p "$APP/Contents/Library/LaunchDaemons"
  cp "$REPO_ROOT/Config/dev.dory.network-helper.plist" \
    "$APP/Contents/Library/LaunchDaemons/dev.dory.network-helper.plist"
  plutil -lint "$APP/Contents/Library/LaunchDaemons/dev.dory.network-helper.plist" >/dev/null
  rm -f "$entitlements"
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

PKG="$(dirname "$0")/../Packages/ContainerizationEngine"

echo "==> Building + signing the Hypervisor.framework VM engine (dory-hv)…"
# dory-hv is Dory's own VMM: elastic memory via free-page reporting, SMP, journaled data disk.
# It needs only the unrestricted com.apple.security.hypervisor entitlement (no vm.networking).
# The provisioner prefers it when DORY_HV_ENGINE=1 and it is present in Helpers.
if [ -d "$PKG" ]; then
  DORY_HV_ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/dory-hv-entitlements.XXXXXX")"
  cat > "$DORY_HV_ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.hypervisor</key><true/></dict></plist>
PLIST
  bundle_swiftpm_executable "$PKG" release dory-hv "$HELPERS/dory-hv" "$DORY_HV_ENTITLEMENTS"
  rm -f "$DORY_HV_ENTITLEMENTS"
fi

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
  echo "==> DORY_BUNDLE_VENUS=0: skipping experimental Venus GPU renderer bundling"
fi

echo "==> Bundling the host kubectl + docker CLIs (so k8s and the docker CLI need no separate install)…"
# Host-side CLIs Dory shells out to: kubectl (Kubernetes browser/apply/scale/exec) and docker (the
# optional `docker` context). Bundling them means a fresh download needs nothing installed.
# Universal releases must carry CLIs that run on both Apple silicon and Intel Macs; fetch each
# Darwin architecture and lipo them into one helper.

download_host_cli_for_arch() {
  local name="$1" arch="$2" out="$3" karch darch tgz work url expected_sha
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
    *)
      echo "unknown host CLI: $name" >&2
      return 1
      ;;
  esac
  printf 'name=%s version=%s arch=%s sha256=%s source_url=%s\n' \
    "$name" "$(dory_host_cli_version "$name")" "$arch" "$expected_sha" "$url" \
    >> "$HOST_CLI_PROVENANCE"
}

bundle_universal_host_cli() {
  local name="$1" destination="$HELPERS/$1" tmp arch bin arches arch_info
  local built=()
  arches="$(host_cli_arches)"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dory-$name.XXXXXX")"
  for arch in $arches; do
    bin="$tmp/$name-$arch"
    if ! download_host_cli_for_arch "$name" "$arch" "$bin"; then
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
HOST_CLI_PROVENANCE="$RESOURCES/host-cli-provenance.txt"
: > "$HOST_CLI_PROVENANCE"
bundle_universal_host_cli kubectl
bundle_universal_host_cli docker
bundle_universal_host_cli docker-buildx
bundle_universal_host_cli docker-compose
LC_ALL=C sort -o "$HOST_CLI_PROVENANCE" "$HOST_CLI_PROVENANCE"

# The `dory` CLI + its Python helper, so the in-app Health panel and `dory doctor`/`dory compat`
# work on a clean Mac with nothing installed. They must sit together in Helpers so the
# bash wrapper resolves dory-doctor beside itself (stdlib-only Python; needs the
# system python3). Files under Contents/Helpers are treated as nested code, so codesign must sign
# each one individually (its CMS signature rides in an xattr) or the non-deep app re-sign fails with
# "code object is not signed at all".
echo "==> Bundling the dory CLI helpers (Health panel + doctor/compat)…"
DORY_SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
for script in dory dory-doctor; do
  if [ -f "$DORY_SCRIPTS/$script" ]; then
    install -m0755 "$DORY_SCRIPTS/$script" "$HELPERS/$script"
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
  helper="$HELPERS/dory-hv"
  if macho_has_arches "$helper" "$host_arch"; then
    printf '%s\n' "$helper"
    return 0
  fi

  if [ -n "${LZFSE_HELPER_CACHE:-}" ] && [ -x "$LZFSE_HELPER_CACHE" ]; then
    printf '%s\n' "$LZFSE_HELPER_CACHE"
    return 0
  fi

  [ -d "$PKG" ] || { echo "    ERROR: $PKG missing; cannot build a host dory-hv compressor" >&2; exit 1; }
  echo "    building host-arch dory-hv for asset compression ($host_arch)" >&2
  LZFSE_HELPER_CACHE="$(build_swiftpm_product_for_arch "$PKG" release dory-hv "$host_arch")"
  [ -x "$LZFSE_HELPER_CACHE" ] || { echo "    ERROR: host dory-hv compressor was not produced" >&2; exit 1; }
  printf '%s\n' "$LZFSE_HELPER_CACHE"
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
    install -m0644 "$kernel_src" "$kernel_raw"
    echo "    bundled Resources/$(basename "$kernel_raw") ($(du -h "$kernel_raw" | awk '{print $1}'))"
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
    install -m0644 "$INITFS_TO_BUNDLE" "$initfs_raw"
    echo "    bundled Resources/$(basename "$initfs_raw") ($(du -h "$initfs_raw" | awk '{print $1}'))"
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

echo "==> Bundling VM kernel + initfs assets, compressed (so the engine needs no container install)…"
for asset_arch in ${DORY_BUNDLE_ARCHES:-arm64 amd64}; do
  bundle_guest_agent_for_arch "$asset_arch"
  bundle_hv_kernel_for_arch "$asset_arch"
  bundle_hv_gpu_kernel_for_arch "$asset_arch"
  bundle_guest_assets_for_arch "$asset_arch"
  bundle_engine_rootfs_for_arch "$asset_arch"
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
echo "    Engine payload ≈ $(du -ch "$RESOURCES"/dory-hv-*.lzfse "$RESOURCES"/dory-vm-*.lzfse "$RESOURCES"/dory-engine-rootfs-*.ext4.lzfse "$HELPERS"/dory-hv "$HELPERS"/docker "$HELPERS"/docker-buildx "$HELPERS"/docker-compose "$HELPERS"/kubectl "$FRAMEWORKS"/*.dylib 2>/dev/null | tail -1 | awk '{print $1}') on disk"
echo "    Re-sign the app bundle before notarization so the payload is sealed."
