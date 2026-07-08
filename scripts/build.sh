#!/bin/bash
# Build Dory with a full Xcode toolchain from the command line.
# The project is saved in Xcode 16 format (objectVersion 77); building from the CLI never
# re-bumps that format, so both stable Xcode 26.x and Xcode 27 are safe here (only the Xcode
# GUI re-bumps it). Override the toolchain explicitly with
# DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer.
set -u
cd "$(dirname "$0")/.."

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

LOG=/tmp/dory_build.log
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

bundle_debug_hv_helper() {
  local pkg configuration hv_bin entitlements app helper gvproxy_src gvproxy_version gvproxy_tmp
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

  gvproxy_version="${DORY_GVPROXY_VERSION:-v0.8.6}"
  gvproxy_src="${DORY_GVPROXY:-}"
  if [ -z "$gvproxy_src" ]; then
    for cand in /opt/homebrew/opt/podman/libexec/podman/gvproxy \
                /usr/local/opt/podman/libexec/podman/gvproxy \
                /opt/homebrew/bin/gvproxy \
                /usr/local/bin/gvproxy \
                "$(command -v gvproxy 2>/dev/null)"; do
      [ -n "$cand" ] && [ -x "$cand" ] && { gvproxy_src="$cand"; break; }
    done
  fi
  if [ -z "$gvproxy_src" ] || [ ! -x "$gvproxy_src" ]; then
    gvproxy_tmp="/tmp/dory-gvproxy-darwin"
    if [ -x "$gvproxy_tmp" ]; then
      gvproxy_src="$gvproxy_tmp"
    else
      echo "note: fetching gvproxy $gvproxy_version (gvisor-tap-vsock release)" >&2
    fi
    if [ -z "$gvproxy_src" ] && fetch_url "https://github.com/containers/gvisor-tap-vsock/releases/download/${gvproxy_version}/gvproxy-darwin" "$gvproxy_tmp" 2>/dev/null; then
      chmod +x "$gvproxy_tmp"
      gvproxy_src="$gvproxy_tmp"
    fi
  fi
  if [ -z "$gvproxy_src" ] || [ ! -x "$gvproxy_src" ]; then
    if [ "${DORY_ALLOW_MISSING_GVPROXY:-0}" = "1" ]; then
      echo "warning: gvproxy unavailable; doryd/dory-hv docker tier will not configure" >&2
    else
      echo "error: could not obtain gvproxy; set DORY_GVPROXY or DORY_ALLOW_MISSING_GVPROXY=1" >&2
      return 1
    fi
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
  done

  rm -f "$entitlements"
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
  done

  rm -f "$entitlements"
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
  local app docker docker_compose kubectl
  [ "${DORY_BUNDLE_HOST_CLI:-1}" = "1" ] || return 0
  docker="$(first_existing_cli "${DORY_DOCKER_CLI:-}" /Applications/Dory.app/Contents/Helpers/docker "$HOME/.dory/bin/docker" /opt/homebrew/bin/docker /usr/local/bin/docker "$(command -v docker 2>/dev/null || true)" || download_docker_cli || true)"
  docker_compose="$(first_existing_cli "${DORY_DOCKER_COMPOSE:-}" /Applications/Dory.app/Contents/Helpers/docker-compose "$HOME/.docker/cli-plugins/docker-compose" "$HOME/.dory/bin/docker-compose" /opt/homebrew/bin/docker-compose /usr/local/bin/docker-compose "$(command -v docker-compose 2>/dev/null || true)" || download_docker_compose || true)"
  kubectl="$(first_existing_cli "${DORY_KUBECTL:-}" /Applications/Dory.app/Contents/Helpers/kubectl "$HOME/.dory/bin/kubectl" /opt/homebrew/bin/kubectl /usr/local/bin/kubectl "$(command -v kubectl 2>/dev/null || true)" || download_kubectl || true)"
  for app in "$HOME"/Library/Developer/Xcode/DerivedData/Dory-*/Build/Products/Debug/Dory.app; do
    [ -d "$app" ] || continue
    copy_host_cli_helper "$app" docker "$docker"
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
    copy_host_cli_helper "$app" dory-idle-proxy \
      "${DORY_IDLE_PROXY_BIN:-}" \
      scripts/dory-idle-proxy \
      /Applications/Dory.app/Contents/Helpers/dory-idle-proxy \
      "$HOME/.dory/bin/dory-idle-proxy"
  done
}

sign_debug_apps() {
  local app helper
  for app in "$HOME"/Library/Developer/Xcode/DerivedData/Dory-*/Build/Products/Debug/Dory.app; do
    [ -d "$app" ] || continue
    xattr -cr "$app" 2>/dev/null || true
    for helper in docker docker-compose kubectl dory dory-doctor dory-idle-proxy; do
      [ -f "$app/Contents/Helpers/$helper" ] || continue
      codesign --force -s - "$app/Contents/Helpers/$helper" >/dev/null 2>&1 || true
    done
    codesign --force -s - "$app" >/dev/null || return 1
  done
}

write_doryd_launch_agent() {
  local app resources helpers plist doryd vmm hv gvproxy kernel rootfs amd64
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
  mkdir -p "$resources"
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
        <key>DORYD_AMD64</key>
        <string>$amd64</string>
        <key>DORYD_NETWORKING</key>
        <string>1</string>
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
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>/tmp/doryd.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/doryd.log</string>
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
  bundle_host_cli_helpers || status=$?
fi
if [ "$status" -eq 0 ]; then
  sign_debug_apps || status=$?
fi

grep -E '(error:|warning:.*\.swift|BUILD SUCCEEDED|BUILD FAILED)' "$LOG" | tail -60 || true
echo "xcodebuild_exit=$status"
exit "$status"
