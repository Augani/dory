#!/bin/bash
# Build Dory with a full Xcode toolchain from the command line.
# The project is saved in Xcode 16 format (objectVersion 77); building from the CLI never
# re-bumps that format, so both stable Xcode 26.x and Xcode 27 are safe here (only the Xcode
# GUI re-bumps it). Override the toolchain explicitly with
# DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer.
set -u
cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
Usage: scripts/build.sh [xcodebuild arguments]

Builds the Debug Dory app with a full Xcode toolchain, then bundles and ad-hoc signs the local
engine, daemon, Docker CLI, Compose, Buildx, and kubectl helpers. Extra arguments are forwarded to
xcodebuild. This command creates a development app only; it does not create or publish a release.

Useful environment controls:
  DEVELOPER_DIR=PATH              Select a full Xcode toolchain
  DORY_BUILD_DEBUG_HELPERS=0      Skip dory-hv/gvproxy bundling
  DORY_BUILD_DORYD_HELPERS=0      Skip doryd/dory-vmm helper bundling
  DORY_ALLOW_MISSING_GVPROXY=1    Permit an intentionally incomplete development bundle
EOF
}

for argument in "$@"; do
  case "$argument" in
    -h|--help) usage; exit 0 ;;
  esac
done

# shellcheck source=gvproxy-payload.sh
source scripts/gvproxy-payload.sh

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

# Respect an explicit DEVELOPER_DIR; otherwise fall back to a discovered full Xcode when the
# active `xcode-select` path is Command Line Tools (which ships no xcodebuild).
if [ -z "${DEVELOPER_DIR:-}" ]; then
  active="$(xcode-select -p 2>/dev/null || true)"
  need_fallback=0
  case "$active" in
    ""|*CommandLineTools*) need_fallback=1 ;;
  esac
  [ -x "$active/usr/bin/xcodebuild" ] || need_fallback=1
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

# Both doryd/dory-vmm and raw dory-hv link the same Rust handshake+mux+protobuf client through
# DoryCore. Its generated Swift and XCFramework are intentionally ignored build products, so a
# clean checkout must materialize them before either Swift package is resolved.
if [ "${DORY_BUILD_DEBUG_HELPERS:-1}" = "1" ] || [ "${DORY_BUILD_DORYD_HELPERS:-1}" = "1" ]; then
  scripts/build-dory-ffi-xcframework.sh --if-needed || exit 1
fi

LOG=/tmp/dory_build.log

# The post-build bundling below injects helpers and guest assets that are not Xcode target outputs.
# Remove that modified product before rebuilding so Xcode's script sandbox never has to delete it.
for app in "$HOME"/Library/Developer/Xcode/DerivedData/Dory-*/Build/Products/Debug/Dory.app; do
  [ -d "$app" ] || continue
  rm -rf "$app"
done

xcodebuild -project Dory.xcodeproj -scheme Dory -destination 'platform=macOS' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO "$@" > "$LOG" 2>&1
status=$?

# Xcode 27 intermittently re-serializes the project to objectVersion 110 (breaks stable Xcode + CI);
# pin it back to 77. Only rewrites that one line, so intended pbxproj edits are preserved.
sed -i '' 's/objectVersion = 110;/objectVersion = 77;/' Dory.xcodeproj/project.pbxproj 2>/dev/null || true

# macOS 27 can stamp DerivedData app products with provenance metadata that leaves debug
# bundles launchable-looking but stuck before main/dyld. Clear it and strip transient XCTest
# payloads from normal debug app builds.
scripts/clean-xcode-products.sh --strip-test-products

fetch_url() {
  local url="$1" out="$2"
  curl -fsSL \
    --retry "${DORY_CURL_RETRIES:-2}" \
    --retry-delay "${DORY_CURL_RETRY_DELAY:-2}" \
    --connect-timeout "${DORY_CURL_CONNECT_TIMEOUT:-15}" \
    --max-time "${DORY_CURL_MAX_TIME:-240}" \
    "$url" -o "$out"
}

debug_engine_rootfs_source() {
  local arch="$1" upper release_arch env_arch env_lzfse cand host_guest_arch host_lzfse host_raw
  case "$arch" in
    arm64) upper="ARM64"; release_arch="arm64" ;;
    amd64) upper="AMD64"; release_arch="x86_64" ;;
    *) return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64) host_guest_arch="amd64" ;;
    *) host_guest_arch="arm64" ;;
  esac
  if [ "$arch" = "$host_guest_arch" ]; then
    host_lzfse="${DORY_ENGINE_ROOTFS_LZFSE:-}"
    host_raw="${DORY_ENGINE_ROOTFS:-}"
  else
    host_lzfse=""
    host_raw=""
  fi
  env_arch="DORY_ENGINE_ROOTFS_$upper"
  env_lzfse="DORY_ENGINE_ROOTFS_${upper}_LZFSE"
  for cand in \
    "${!env_lzfse:-}" \
    "${!env_arch:-}" \
    "$host_lzfse" \
    "$host_raw" \
    "guest/out/dory-engine-rootfs-$arch.ext4.lzfse" \
    "guest/out/dory-engine-rootfs-$arch.ext4" \
    "guest/out/initfs-$arch.ext4.lzfse" \
    "guest/out/initfs-$arch.ext4" \
    "release-build/export-$release_arch/Dory.app/Contents/Resources/dory-engine-rootfs-$arch.ext4.lzfse" \
    "release-build/export-$release_arch/Dory.app/Contents/Resources/dory-engine-rootfs.ext4.lzfse"; do
    [ -n "$cand" ] && [ -f "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

bundle_debug_engine_rootfs() {
  local app="$1" arch="$2" compressor="$3" src out host_guest_arch
  src="$(debug_engine_rootfs_source "$arch" || true)"
  [ -n "$src" ] || return 0
  out="$app/Contents/Resources/dory-engine-rootfs-$arch.ext4.lzfse"
  mkdir -p "$app/Contents/Resources"
  case "$src" in
    *.lzfse) cp "$src" "$out" ;;
    *) "$compressor" lzfse compress "$src" "$out" ;;
  esac
  chmod 0644 "$out"
  xattr -cr "$out" 2>/dev/null || true
  case "$(uname -m)" in
    x86_64) host_guest_arch="amd64" ;;
    *) host_guest_arch="arm64" ;;
  esac
  if [ "$arch" = "$host_guest_arch" ]; then
    ln -sf "dory-engine-rootfs-$arch.ext4.lzfse" "$app/Contents/Resources/dory-engine-rootfs.ext4.lzfse"
  fi
}

bundle_debug_desktop_assets() {
  local app="$1" compressor="$2" kernel kernel_out distro rootfs rootfs_out metadata
  [ "$(uname -m)" = "arm64" ] || return 0
  kernel="guest/out/Image-desktop"
  [ -f "$kernel" ] || return 0
  guest/kernel/verify-build.sh arm64 desktop >/dev/null || return 1
  kernel_out="$app/Contents/Resources/dory-desktop-kernel-arm64.lzfse"
  if [ ! -f "$kernel_out" ] || [ "$kernel" -nt "$kernel_out" ]; then
    "$compressor" lzfse compress "$kernel" "$kernel_out" || return 1
  fi
  for distro in debian ubuntu kali; do
    rootfs="guest/out/dory-desktop-$distro-rootfs-arm64.ext4"
    [ -f "$rootfs" ] || continue
    guest/desktop/verify-build.sh arm64 "$distro" >/dev/null || return 1
    rootfs_out="$app/Contents/Resources/dory-desktop-$distro-rootfs-arm64.ext4.lzfse"
    if [ ! -f "$rootfs_out" ] || [ "$rootfs" -nt "$rootfs_out" ]; then
      "$compressor" lzfse compress "$rootfs" "$rootfs_out" || return 1
    fi
    for metadata in \
      "guest/out/dory-desktop-$distro-build-arm64.stamp" \
      "guest/out/dory-desktop-$distro-packages-arm64.txt"; do
      [ -s "$metadata" ] && install -m0644 "$metadata" "$app/Contents/Resources/"
    done
  done
  for metadata in guest/out/kernel-build-arm64-desktop.stamp; do
    [ -s "$metadata" ] && install -m0644 "$metadata" "$app/Contents/Resources/"
  done
}

bundle_debug_hv_helper() {
  local pkg configuration hv_bin entitlements app helper
  local gvproxy_src gvproxy_version gvproxy_sha256 gvproxy_tmp
  [ "${DORY_BUILD_DEBUG_HELPERS:-1}" = "1" ] || return 0
  configuration="${DORY_DEBUG_HELPER_CONFIGURATION:-release}"
  pkg="Packages/ContainerizationEngine"
  [ -d "$pkg" ] || return 0

  echo "note: building and bundling dory-hv helper ($configuration)" >&2
  ( cd "$pkg" && swift build -c "$configuration" --product dory-hv ) || return 1
  hv_bin="$(cd "$pkg" && swift build -c "$configuration" --product dory-hv --show-bin-path 2>/dev/null)/dory-hv"
  if [ ! -x "$hv_bin" ]; then
    hv_bin="$(find "$pkg/.build" -name dory-hv -type f -ipath "*/$configuration/*" -not -path '*dSYM*' -print | head -1)"
  fi
  [ -x "$hv_bin" ] || { echo "error: dory-hv helper was not produced" >&2; return 1; }

  dory_gvproxy_validate_overrides || return 1
  gvproxy_version="$(dory_gvproxy_version)"
  gvproxy_sha256="$(dory_gvproxy_expected_sha256)"
  gvproxy_src="${DORY_GVPROXY:-}"
  gvproxy_tmp=""
  if [ -n "$gvproxy_src" ]; then
    # This is the only local-binary override. It is never trusted without the same checksum,
    # universal-slice, and version checks as the pinned source build.
    if [ ! -f "$gvproxy_src" ] || [ ! -x "$gvproxy_src" ]; then
      echo "error: explicit DORY_GVPROXY is not an executable file: $gvproxy_src" >&2
      return 1
    fi
    echo "note: using verified explicit DORY_GVPROXY override" >&2
  else
    gvproxy_tmp="$(mktemp "${TMPDIR:-/tmp}/dory-gvproxy-${gvproxy_version}.XXXXXX")" || return 1
    echo "note: building provenance-pinned dual-stack gvproxy $gvproxy_version" >&2
    if scripts/build-gvproxy.sh --output "$gvproxy_tmp" --provenance "$gvproxy_tmp.provenance"; then
      gvproxy_src="$gvproxy_tmp"
    else
      rm -f "$gvproxy_tmp"
      rm -f "$gvproxy_tmp.provenance"
      gvproxy_tmp=""
    fi
  fi
  if [ -z "$gvproxy_src" ] || [ ! -x "$gvproxy_src" ]; then
    if [ "${DORY_ALLOW_MISSING_GVPROXY:-0}" = "1" ]; then
      echo "warning: gvproxy unavailable; doryd/dory-hv docker tier will not configure" >&2
    else
      echo "error: could not obtain gvproxy; set DORY_GVPROXY or DORY_ALLOW_MISSING_GVPROXY=1" >&2
      return 1
    fi
  elif ! dory_verify_gvproxy_payload "$gvproxy_src" "$gvproxy_version" "$gvproxy_sha256"; then
    rm -f "$gvproxy_tmp" "$gvproxy_tmp.provenance"
    return 1
  fi

  entitlements="$(mktemp "${TMPDIR:-/tmp}/dory-hv-entitlements.XXXXXX")"
  cat > "$entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.hypervisor</key><true/></dict></plist>
PLIST

  for app in "$HOME"/Library/Developer/Xcode/DerivedData/Dory-*/Build/Products/Debug/Dory.app; do
    [ -d "$app" ] || continue
    mkdir -p "$app/Contents/Helpers"
    mkdir -p "$app/Contents/Resources"
    helper="$app/Contents/Helpers/dory-hv"
    cp "$hv_bin" "$helper"
    codesign --force --options runtime --entitlements "$entitlements" -s - "$helper" >/dev/null 2>&1 \
      || codesign --force --entitlements "$entitlements" -s - "$helper" >/dev/null
    xattr -cr "$helper" 2>/dev/null || true
    if [ -n "$gvproxy_src" ] && [ -x "$gvproxy_src" ]; then
      cp "$gvproxy_src" "$app/Contents/Helpers/gvproxy"
      codesign --force --options runtime -s - "$app/Contents/Helpers/gvproxy" >/dev/null 2>&1 \
        || codesign --force -s - "$app/Contents/Helpers/gvproxy" >/dev/null
      xattr -cr "$app/Contents/Helpers/gvproxy" 2>/dev/null || true
      if [ -n "$gvproxy_tmp" ] && [ -s "$gvproxy_tmp.provenance" ]; then
        cp "$gvproxy_tmp.provenance" "$app/Contents/Resources/gvproxy-provenance.txt"
        echo 'source=pinned-source-build' >> "$app/Contents/Resources/gvproxy-provenance.txt"
      else
        {
          echo "version=$gvproxy_version"
          echo "verified_sha256=$gvproxy_sha256"
          echo 'source=explicit-override'
        } > "$app/Contents/Resources/gvproxy-provenance.txt"
      fi
    fi
    for arch in arm64 amd64; do
      if [ -f "guest/out/dory-agent-$arch" ]; then
        cp "guest/out/dory-agent-$arch" "$app/Contents/Resources/dory-agent-linux-$arch"
        chmod 0755 "$app/Contents/Resources/dory-agent-linux-$arch"
      fi
      if [ -f "guest/out/initfs-$arch.ext4" ]; then
        cp "guest/out/initfs-$arch.ext4" "$app/Contents/Resources/dory-machine-rootfs-$arch.ext4"
        chmod 0644 "$app/Contents/Resources/dory-machine-rootfs-$arch.ext4"
        if [ "$arch" = "arm64" ]; then
          cp "$app/Contents/Resources/dory-machine-rootfs-$arch.ext4" "$app/Contents/Resources/dory-machine-rootfs.ext4"
        fi
      fi
      bundle_debug_engine_rootfs "$app" "$arch" "$hv_bin"
    done
    if [ -f "guest/out/Image" ]; then
      cp "guest/out/Image" "$app/Contents/Resources/dory-hv-kernel-arm64"
      cp "$app/Contents/Resources/dory-hv-kernel-arm64" "$app/Contents/Resources/dory-hv-kernel"
      "$hv_bin" lzfse compress "guest/out/Image" "$app/Contents/Resources/dory-hv-kernel-arm64.lzfse"
      cp "$app/Contents/Resources/dory-hv-kernel-arm64.lzfse" "$app/Contents/Resources/dory-hv-kernel.lzfse"
    fi
    if [ -f "guest/out/Image-gpu" ]; then
      "$hv_bin" lzfse compress "guest/out/Image-gpu" "$app/Contents/Resources/dory-hv-kernel-gpu-arm64.lzfse"
    fi
    bundle_debug_desktop_assets "$app" "$hv_bin" || return 1
  done

  rm -f "$entitlements"
  rm -f "$gvproxy_tmp" "$gvproxy_tmp.provenance"
}

bundle_doryd_swiftpm_helpers() {
  local configuration bin_path entitlements app product helper
  [ "${DORY_BUILD_DORYD_HELPERS:-1}" = "1" ] || return 0
  [ -f "dory-core-swift/Package.swift" ] || return 0
  configuration="${DORY_DORYD_HELPER_CONFIGURATION:-debug}"

  echo "note: building and bundling doryd SwiftPM helpers ($configuration)" >&2
  for product in doryd dorydctl dory-vmm dory-network-helper; do
    swift build --package-path dory-core-swift -c "$configuration" --product "$product" || return 1
  done
  bin_path="$(swift build --package-path dory-core-swift -c "$configuration" --show-bin-path 2>/dev/null)"

  entitlements="$(mktemp "${TMPDIR:-/tmp}/dory-vmm-entitlements.XXXXXX")"
  cat > "$entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.virtualization</key><true/></dict></plist>
PLIST

  for app in "$HOME"/Library/Developer/Xcode/DerivedData/Dory-*/Build/Products/Debug/Dory.app; do
    [ -d "$app" ] || continue
    mkdir -p "$app/Contents/Helpers"
    for product in doryd dorydctl dory-vmm dory-network-helper; do
      [ -x "$bin_path/$product" ] || { echo "error: $product helper was not produced" >&2; rm -f "$entitlements"; return 1; }
      helper="$app/Contents/Helpers/$product"
      cp "$bin_path/$product" "$helper"
      if [ "$product" = "dory-vmm" ]; then
        codesign --force --options runtime --entitlements "$entitlements" -s - "$helper" >/dev/null 2>&1 \
          || codesign --force --entitlements "$entitlements" -s - "$helper" >/dev/null
      else
        codesign --force -s - "$helper" >/dev/null
      fi
      xattr -cr "$helper" 2>/dev/null || true
    done
    write_doryd_launch_agent "$app"
    mkdir -p "$app/Contents/Library/LaunchDaemons"
    cp "Config/dev.dory.network-helper.plist" \
      "$app/Contents/Library/LaunchDaemons/dev.dory.network-helper.plist"
    plutil -lint "$app/Contents/Library/LaunchDaemons/dev.dory.network-helper.plist" >/dev/null
  done

  rm -f "$entitlements"
}

bundle_debug_transfer_helper() {
  local work app
  work="$(mktemp -d "${TMPDIR:-/tmp}/dory-transfer-helper.XXXXXX")" || return 1
  if ! scripts/build-transfer-helper.sh \
    --image-output "$work/dory-transfer-helper-image-arm64.tar" \
    --image-metadata-output "$work/dory-transfer-helper-image-arm64.json" >/dev/null; then
    rm -rf "$work"
    return 1
  fi
  for app in "$HOME"/Library/Developer/Xcode/DerivedData/Dory-*/Build/Products/Debug/Dory.app; do
    [ -d "$app" ] || continue
    mkdir -p "$app/Contents/Resources"
    install -m0644 "$work/dory-transfer-helper-image-arm64.tar" "$app/Contents/Resources/"
    install -m0644 "$work/dory-transfer-helper-image-arm64.json" "$app/Contents/Resources/"
  done
  rm -rf "$work"
}

resolve_symlink() {
  local source="$1" dir next
  while [ -L "$source" ]; do
    dir="$(cd -P "$(dirname "$source")" >/dev/null 2>&1 && pwd)"
    next="$(readlink "$source")"
    case "$next" in
      /*) source="$next" ;;
      *) source="$dir/$next" ;;
    esac
  done
  printf '%s\n' "$source"
}

first_existing_cli() {
  local cand
  for cand in "$@"; do
    [ -n "$cand" ] || continue
    cand="$(resolve_symlink "$cand")"
    if [ -f "$cand" ] && [ -r "$cand" ]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

host_cli_cache_dir() {
  printf '%s\n' "${DORY_HOST_CLI_CACHE:-$PWD/.build/host-cli}"
}

host_arch() {
  case "$(uname -m)" in
    arm64|arm64e) printf 'arm64\n' ;;
    x86_64|amd64) printf 'x86_64\n' ;;
    *) uname -m ;;
  esac
}

docker_static_arch() {
  case "$(host_arch)" in
    arm64) printf 'aarch64\n' ;;
    x86_64) printf 'x86_64\n' ;;
    *) return 1 ;;
  esac
}

kubectl_darwin_arch() {
  case "$(host_arch)" in
    arm64) printf 'arm64\n' ;;
    x86_64) printf 'amd64\n' ;;
    *) return 1 ;;
  esac
}

buildx_darwin_arch() {
  case "$(host_arch)" in
    arm64) printf 'arm64\n' ;;
    x86_64) printf 'amd64\n' ;;
    *) return 1 ;;
  esac
}

download_docker_cli() {
  [ "${DORY_BUNDLE_HOST_CLI_DOWNLOADS:-1}" = "1" ] || return 1
  local version arch cache tgz tmp out
  version="${DORY_DOCKER_CLI_VERSION:-29.0.1}"
  arch="$(docker_static_arch)" || return 1
  cache="$(host_cli_cache_dir)"
  out="$cache/docker-$version-$arch"
  [ -x "$out" ] && { printf '%s\n' "$out"; return 0; }
  mkdir -p "$cache"
  tgz="$cache/docker-$version-$arch.tgz"
  fetch_url "https://download.docker.com/mac/static/stable/$arch/docker-$version.tgz" "$tgz" || return 1
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dory-docker-cli.XXXXXX")"
  tar -xzf "$tgz" -C "$tmp"
  install -m 0755 "$tmp/docker/docker" "$out"
  rm -rf "$tmp"
  xattr -cr "$out" 2>/dev/null || true
  printf '%s\n' "$out"
}

download_docker_compose() {
  [ "${DORY_BUNDLE_HOST_CLI_DOWNLOADS:-1}" = "1" ] || return 1
  local version arch cache out
  version="${DORY_DOCKER_COMPOSE_VERSION:-v2.39.2}"
  arch="$(docker_static_arch)" || return 1
  cache="$(host_cli_cache_dir)"
  out="$cache/docker-compose-$version-$arch"
  [ -x "$out" ] && { printf '%s\n' "$out"; return 0; }
  mkdir -p "$cache"
  fetch_url "https://github.com/docker/compose/releases/download/$version/docker-compose-darwin-$arch" "$out" || return 1
  chmod 0755 "$out"
  xattr -cr "$out" 2>/dev/null || true
  printf '%s\n' "$out"
}

download_docker_buildx() {
  [ "${DORY_BUNDLE_HOST_CLI_DOWNLOADS:-1}" = "1" ] || return 1
  local version arch cache out
  version="${DORY_BUILDX_VERSION:-v0.34.1}"
  arch="$(buildx_darwin_arch)" || return 1
  cache="$(host_cli_cache_dir)"
  out="$cache/docker-buildx-$version-$arch"
  [ -x "$out" ] && { printf '%s\n' "$out"; return 0; }
  mkdir -p "$cache"
  fetch_url "https://github.com/docker/buildx/releases/download/$version/buildx-$version.darwin-$arch" "$out" || return 1
  chmod 0755 "$out"
  xattr -cr "$out" 2>/dev/null || true
  printf '%s\n' "$out"
}

download_kubectl() {
  [ "${DORY_BUNDLE_HOST_CLI_DOWNLOADS:-1}" = "1" ] || return 1
  local version arch cache out
  version="${DORY_KUBECTL_VERSION:-v1.36.1}"
  arch="$(kubectl_darwin_arch)" || return 1
  cache="$(host_cli_cache_dir)"
  out="$cache/kubectl-$version-$arch"
  [ -x "$out" ] && { printf '%s\n' "$out"; return 0; }
  mkdir -p "$cache"
  fetch_url "https://dl.k8s.io/release/$version/bin/darwin/$arch/kubectl" "$out" || return 1
  chmod 0755 "$out"
  xattr -cr "$out" 2>/dev/null || true
  printf '%s\n' "$out"
}

copy_host_cli_helper() {
  local app="$1" tool="$2" source dest cand
  shift 2
  dest="$app/Contents/Helpers/$tool"
  source="$(first_existing_cli "$@" || true)"
  if [ -z "${source:-}" ]; then
    echo "warning: host CLI helper '$tool' unavailable; terminal docker/kubectl setup cannot bundle it" >&2
    return 0
  fi
  mkdir -p "$app/Contents/Helpers"
  cp "$source" "$dest"
  chmod 0755 "$dest"
  xattr -cr "$dest" 2>/dev/null || true
  codesign --force -s - "$dest" >/dev/null 2>&1 || true
}

bundle_host_cli_helpers() {
  local app docker docker_buildx docker_compose kubectl
  [ "${DORY_BUNDLE_HOST_CLI:-1}" = "1" ] || return 0
  docker="$(first_existing_cli "${DORY_DOCKER_CLI:-}" /Applications/Dory.app/Contents/Helpers/docker "$HOME/.dory/bin/docker" /opt/homebrew/bin/docker /usr/local/bin/docker "$(command -v docker 2>/dev/null || true)" || download_docker_cli || true)"
  docker_buildx="$(first_existing_cli "${DORY_DOCKER_BUILDX:-}" /Applications/Dory.app/Contents/Helpers/docker-buildx "$HOME/.docker/cli-plugins/docker-buildx" "$HOME/.dory/bin/docker-buildx" /opt/homebrew/lib/docker/cli-plugins/docker-buildx /usr/local/lib/docker/cli-plugins/docker-buildx || download_docker_buildx || true)"
  docker_compose="$(first_existing_cli "${DORY_DOCKER_COMPOSE:-}" /Applications/Dory.app/Contents/Helpers/docker-compose "$HOME/.docker/cli-plugins/docker-compose" "$HOME/.dory/bin/docker-compose" /opt/homebrew/bin/docker-compose /usr/local/bin/docker-compose "$(command -v docker-compose 2>/dev/null || true)" || download_docker_compose || true)"
  kubectl="$(first_existing_cli "${DORY_KUBECTL:-}" /Applications/Dory.app/Contents/Helpers/kubectl "$HOME/.dory/bin/kubectl" /opt/homebrew/bin/kubectl /usr/local/bin/kubectl "$(command -v kubectl 2>/dev/null || true)" || download_kubectl || true)"
  for app in "$HOME"/Library/Developer/Xcode/DerivedData/Dory-*/Build/Products/Debug/Dory.app; do
    [ -d "$app" ] || continue
    copy_host_cli_helper "$app" docker "$docker"
    copy_host_cli_helper "$app" docker-buildx "$docker_buildx"
    copy_host_cli_helper "$app" docker-compose "$docker_compose"
    copy_host_cli_helper "$app" kubectl "$kubectl"
    copy_host_cli_helper "$app" dory \
      "${DORY_CLI:-}" \
      scripts/dory \
      /Applications/Dory.app/Contents/Helpers/dory \
      "$HOME/.dory/bin/dory"
    copy_host_cli_helper "$app" dory-doctor \
      "${DORY_DOCTOR_BIN:-}" \
      scripts/dory-doctor \
      /Applications/Dory.app/Contents/Helpers/dory-doctor \
      "$HOME/.dory/bin/dory-doctor"
  done
}

sign_debug_apps() {
  local app helper framework
  for app in "$HOME"/Library/Developer/Xcode/DerivedData/Dory-*/Build/Products/Debug/Dory.app; do
    [ -d "$app" ] || continue
    xattr -cr "$app" 2>/dev/null || true
    for helper in docker docker-buildx docker-compose kubectl dory dory-doctor; do
      [ -f "$app/Contents/Helpers/$helper" ] || continue
      codesign --force -s - "$app/Contents/Helpers/$helper" >/dev/null 2>&1 || true
    done
    # Xcode strips development-only framework headers after SwiftPM has signed the artifact.
    # Refresh each top-level framework seal before sealing the modified app bundle.
    for framework in "$app"/Contents/Frameworks/*.framework; do
      [ -d "$framework" ] || continue
      codesign --force -s - "$framework" >/dev/null || return 1
    done
    codesign --force -s - "$app" >/dev/null || return 1
    codesign --verify --deep --strict "$app" || return 1
  done
}

write_doryd_launch_agent() {
  local app resources helpers plist doryd vmm hv gvproxy kernel rootfs amd64 log_dir log_path
  app="$1"
  resources="$app/Contents/Resources"
  helpers="$app/Contents/Helpers"
  plist="$resources/dev.dory.doryd.plist"
  doryd="$helpers/doryd"
  vmm="$helpers/dory-vmm"
  hv="$helpers/dory-hv"
  gvproxy="$helpers/gvproxy"
  kernel="$resources/dory-hv-kernel"
  amd64="${DORYD_AMD64:-0}"
  if [ "$(uname -m)" = "arm64" ]; then
    amd64="${DORYD_AMD64:-1}"
    rootfs="$resources/dory-machine-rootfs-arm64.ext4"
  else
    rootfs="$resources/dory-machine-rootfs-amd64.ext4"
  fi
  log_dir="$HOME/.dory"
  log_path="$log_dir/doryd.log"
  mkdir -p "$resources" "$log_dir"
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
        <key>DORYD_HV_KERNEL</key>
        <string>$kernel</string>
        <key>DORYD_MACHINE_KERNEL</key>
        <string>$kernel</string>
        <key>DORYD_MACHINE_ROOTFS</key>
        <string>$rootfs</string>
        <key>DORYD_GVPROXY</key>
        <string>$gvproxy</string>
        <key>DORYD_HELPERS_DIR</key>
        <string>$helpers</string>
        <key>DORYD_RESOURCES_DIR</key>
        <string>$resources</string>
        <key>DORYD_AMD64</key>
        <string>$amd64</string>
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
  plutil -lint "$plist" >/dev/null || return 1
}

if [ "$status" -eq 0 ]; then
  bundle_debug_hv_helper || status=$?
fi
if [ "$status" -eq 0 ]; then
  bundle_doryd_swiftpm_helpers || status=$?
fi
if [ "$status" -eq 0 ]; then
  bundle_debug_transfer_helper || status=$?
fi
if [ "$status" -eq 0 ]; then
  bundle_host_cli_helpers || status=$?
fi
if [ "$status" -eq 0 ]; then
  sign_debug_apps || status=$?
fi

grep -E '(error:|warning:.*\.swift|BUILD SUCCEEDED|BUILD FAILED)' "$LOG" | tail -60 || true
echo "xcodebuild_exit=$status"
exit "$status"
