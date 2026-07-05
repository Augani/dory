#!/bin/bash
# Make a built Dory.app self-contained so users download ONLY the app — no `brew install container`.
#
# Default ("OrbStack model") injects the in-process engines and pulls the docker engine IMAGE on
# first launch (the image is NOT bundled), the way OrbStack ships an app and fetches engine bits on
# first run. Bundled payload:
#   * Contents/Helpers/dory-hv    — Dory's own Hypervisor.framework VMM (elastic memory via free-page
#                                   reporting, SMP, journaled data disk), signed with
#                                   com.apple.security.hypervisor. Preferred when DORY_HV_ENGINE=1.
#   * Contents/Helpers/gvproxy    — userspace networking (Apache-2.0) for the dory-hv engine.
#   * Contents/Helpers/dory-vm    — the older Virtualization.framework helper (~100MB), fallback.
#   * Contents/Helpers/zstd       — decompresses the assets on first launch.
#   * Contents/Resources/dory-vm-kernel.zst       — compressed Linux kernel  (~15MB -> ~6MB).
#   * Contents/Resources/dory-vm-initfs.ext4.zst  — compressed VM initfs     (~165MB -> ~30MB).
#   The docker engine image (docker:dind) is NOT bundled — the engine pulls it on first boot.
#
# Set DORY_BUNDLE_LEGACY=1 to additionally inject the heavy offline payload (the docker:dind image
# tarball + Apple's `container` toolchain) for the legacy SharedVMProvisioner path — adds ~600MB.
#
# Run on an exported (pre-notarization) app so the payload is signed with the bundle:
#   scripts/bundle-engine.sh release-build/export/Dory.app
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

APP="${1:?usage: bundle-engine.sh <path/to/Dory.app>}"
RESOURCES="$APP/Contents/Resources"
HELPERS="$APP/Contents/Helpers"
SUPPORT="$HOME/Library/Application Support/com.apple.container"

[ -d "$APP" ] || { echo "no such app bundle: $APP"; exit 1; }
command -v zstd >/dev/null || { echo "zstd not found (brew install zstd)"; exit 1; }
mkdir -p "$RESOURCES" "$HELPERS"

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
  [ -f "$agent" ] || { echo "    WARNING: guest agent not found at $agent — run guest/agent/build.sh before bundling for Track 0 RPC"; return 0; }
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

find_qemu_x86_64_static() {
  if [ -n "${DORY_QEMU_X86_64_STATIC:-}" ] && [ -x "$DORY_QEMU_X86_64_STATIC" ]; then
    printf '%s\n' "$DORY_QEMU_X86_64_STATIC"; return 0
  fi
  for cand in "$(command -v qemu-x86_64-static 2>/dev/null)" \
              /opt/homebrew/bin/qemu-x86_64-static \
              /usr/local/bin/qemu-x86_64-static \
              /opt/homebrew/opt/qemu/bin/qemu-x86_64-static \
              /usr/local/opt/qemu/bin/qemu-x86_64-static; do
    [ -n "$cand" ] && [ -x "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

inject_qemu_into_initfs() {
  local image="$1" qemu="$2" debugfs_bin
  [ "${DORY_SKIP_QEMU_INJECT:-0}" = "1" ] && return 0
  [ -n "$image" ] && [ -f "$image" ] || return 0
  [ -n "$qemu" ] && [ -x "$qemu" ] || return 0
  if ! debugfs_bin="$(find_debugfs)"; then
    echo "    WARNING: debugfs not found — cannot inject qemu-x86_64-static"
    return 0
  fi
  "$debugfs_bin" -w -R "mkdir /usr" "$image" >/dev/null 2>&1 || true
  "$debugfs_bin" -w -R "mkdir /usr/bin" "$image" >/dev/null 2>&1 || true
  "$debugfs_bin" -w -R "rm /usr/bin/qemu-x86_64-static" "$image" >/dev/null 2>&1 || true
  "$debugfs_bin" -w -R "write $qemu /usr/bin/qemu-x86_64-static" "$image" >/dev/null
  "$debugfs_bin" -w -R "sif /usr/bin/qemu-x86_64-static mode 0100755" "$image" >/dev/null
  echo "    injected /usr/bin/qemu-x86_64-static into initfs"
}

is_linux_aarch64_elf() {
  local bin="$1" magic
  [ -n "$bin" ] && [ -r "$bin" ] || return 1
  magic="$(dd if="$bin" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')"
  [ "$magic" = "7f454c46" ] || return 1
  file "$bin" 2>/dev/null | grep -Eqi 'ELF.*(aarch64|ARM aarch64)'
}

find_toolbox_binary() {
  local name="$1" env_name="DORY_TOOLBOX_$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')" cand
  if [ -n "${!env_name:-}" ] && [ -x "${!env_name}" ]; then
    if is_linux_aarch64_elf "${!env_name}"; then
      printf '%s\n' "${!env_name}"; return 0
    fi
    echo "    WARNING: $env_name=${!env_name} is not a Linux aarch64 ELF; skipping $name" >&2
    return 1
  fi
  for cand in "$(command -v "$name" 2>/dev/null)" \
              "/opt/homebrew/bin/$name" \
              "/usr/local/bin/$name"; do
    [ -n "$cand" ] && [ -x "$cand" ] || continue
    if is_linux_aarch64_elf "$cand"; then
      printf '%s\n' "$cand"; return 0
    fi
  done
  return 1
}

inject_debug_toolbox_into_initfs() {
  local image="$1" debugfs_bin busybox curl_bin strace_bin
  [ "${DORY_SKIP_TOOLBOX_INJECT:-0}" = "1" ] && return 0
  [ -n "$image" ] && [ -f "$image" ] || return 0
  if ! debugfs_bin="$(find_debugfs)"; then
    echo "    WARNING: debugfs not found — cannot inject debug toolbox"
    return 0
  fi

  busybox="$(find_toolbox_binary busybox || true)"
  curl_bin="$(find_toolbox_binary curl || true)"
  strace_bin="$(find_toolbox_binary strace || true)"
  [ -n "$busybox" ] || echo "    WARNING: no Linux aarch64 busybox found; debug toolbox will lack it (set DORY_TOOLBOX_BUSYBOX to a Linux static binary)"
  [ -n "$curl_bin" ] || echo "    WARNING: no Linux aarch64 curl found; debug toolbox will lack it (set DORY_TOOLBOX_CURL to a Linux static binary)"
  [ -n "$strace_bin" ] || echo "    WARNING: no Linux aarch64 strace found; debug toolbox will lack it (set DORY_TOOLBOX_STRACE to a Linux static binary)"
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

echo "==> Building + signing the in-process VM engine helper (dory-vm)…"
PKG="$(dirname "$0")/../Packages/ContainerizationEngine"
if [ -d "$PKG" ]; then
  ( cd "$PKG" && swift build -c release --product dory-vmboot )
  # This package emits to .build/out/Products/<config>/ — NOT swift's --show-bin-path location.
  HELPER_BIN="$(find "$PKG/.build" -name dory-vmboot -type f -path '*Release*' 2>/dev/null | head -1)"
  [ -n "$HELPER_BIN" ] || HELPER_BIN="$(find "$PKG/.build" -name dory-vmboot -type f 2>/dev/null | head -1)"
  cat > /tmp/dory-vm.entitlements <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.virtualization</key><true/></dict></plist>
PLIST
  cp "$HELPER_BIN" "$HELPERS/dory-vm"
  codesign --force --options runtime --entitlements /tmp/dory-vm.entitlements \
    -s "${DORY_SIGN_ID:-Developer ID Application}" "$HELPERS/dory-vm" 2>/dev/null \
    || codesign --force --entitlements /tmp/dory-vm.entitlements -s - "$HELPERS/dory-vm"
  echo "    bundled Helpers/dory-vm (signed with com.apple.security.virtualization)"
fi

echo "==> Building + signing the Hypervisor.framework VM engine (dory-hv)…"
# dory-hv is Dory's own VMM: elastic memory via free-page reporting, SMP, journaled data disk.
# It needs only the unrestricted com.apple.security.hypervisor entitlement (no vm.networking).
# The provisioner prefers it when DORY_HV_ENGINE=1 and it is present in Helpers.
if [ -d "$PKG" ]; then
  ( cd "$PKG" && swift build -c release --product dory-hv )
  HV_BIN="$(find "$PKG/.build" -name dory-hv -type f -path '*Release*' 2>/dev/null | head -1)"
  [ -n "$HV_BIN" ] || HV_BIN="$(find "$PKG/.build" -name dory-hv -type f 2>/dev/null | head -1)"
  if [ -n "$HV_BIN" ]; then
    cat > /tmp/dory-hv.entitlements <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.hypervisor</key><true/></dict></plist>
PLIST
    cp "$HV_BIN" "$HELPERS/dory-hv"
    codesign --force --options runtime --timestamp --entitlements /tmp/dory-hv.entitlements \
      -s "${DORY_SIGN_ID:-Developer ID Application}" "$HELPERS/dory-hv" 2>/dev/null \
      || codesign --force --entitlements /tmp/dory-hv.entitlements -s - "$HELPERS/dory-hv"
    echo "    bundled Helpers/dory-hv (signed with com.apple.security.hypervisor)"
  else
    echo "    WARNING: dory-hv build produced no binary; skipping the HV engine"
  fi
fi

echo "==> Bundling gvproxy (userspace networking for the dory-hv engine)…"
# gvproxy (gvisor-tap-vsock, Apache-2.0) gives the HV engine NAT/DNS with no restricted
# entitlement. Prefer a path from DORY_GVPROXY, else podman's bundled copy, else PATH.
GVPROXY_SRC="${DORY_GVPROXY:-}"
if [ -z "$GVPROXY_SRC" ]; then
  for cand in /opt/homebrew/opt/podman/libexec/podman/gvproxy \
              /usr/local/opt/podman/libexec/podman/gvproxy \
              "$(command -v gvproxy 2>/dev/null)"; do
    [ -n "$cand" ] && [ -x "$cand" ] && { GVPROXY_SRC="$cand"; break; }
  done
fi
if [ -n "$GVPROXY_SRC" ] && [ -x "$GVPROXY_SRC" ]; then
  cp "$GVPROXY_SRC" "$HELPERS/gvproxy"
  codesign --force --options runtime --timestamp -s "${DORY_SIGN_ID:-Developer ID Application}" "$HELPERS/gvproxy" 2>/dev/null \
    || codesign --force -s - "$HELPERS/gvproxy"
  echo "    bundled Helpers/gvproxy (from $GVPROXY_SRC)"
else
  echo "    WARNING: no gvproxy found — the dory-hv engine needs it. Set DORY_GVPROXY or 'brew install podman'."
fi

echo "==> Bundling the host kubectl + docker CLIs (so k8s and the docker CLI need no separate install)…"
# Host-side CLIs Dory shells out to: kubectl (Kubernetes browser/apply/scale/exec) and docker (the
# optional `docker` context). Bundling them means a fresh download needs nothing installed. Prefer a
# local copy on the build machine, else fetch the darwin/arm64 binary. HostTools resolves the
# bundled copy first at runtime.
ARCH="$(uname -m)"; [ "$ARCH" = "x86_64" ] && KARCH="amd64" || KARCH="arm64"
[ "$ARCH" = "x86_64" ] && DARCH="x86_64" || DARCH="aarch64"

bundle_cli() {  # name  local-fallback-path  download-url
  local name="$1" local_src="$2" url="$3" tmp="/tmp/dory-cli-$1"
  if [ -x "$local_src" ]; then cp "$local_src" "$HELPERS/$name"
  elif command -v "$name" >/dev/null 2>&1; then cp "$(command -v "$name")" "$HELPERS/$name"
  elif [ -n "$url" ]; then curl -fsSL "$url" -o "$tmp" 2>/dev/null && install -m0755 "$tmp" "$HELPERS/$name" && rm -f "$tmp"; fi
  if [ -x "$HELPERS/$name" ]; then
    codesign --force --options runtime --timestamp -s "${DORY_SIGN_ID:-Developer ID Application}" "$HELPERS/$name" 2>/dev/null \
      || codesign --force -s - "$HELPERS/$name"
    echo "    bundled Helpers/$name"
  else
    echo "    WARNING: could not bundle $name — the feature will need a system install."
  fi
}

KVER="$(curl -fsSL https://dl.k8s.io/release/stable.txt 2>/dev/null || echo v1.31.0)"
bundle_cli kubectl "" "https://dl.k8s.io/release/${KVER}/bin/darwin/${KARCH}/kubectl"
# The static docker CLI tarball contains a single `docker` binary.
if [ ! -x "$HELPERS/docker" ]; then
  DOCKER_TGZ="/tmp/dory-docker.tgz"
  if curl -fsSL "https://download.docker.com/mac/static/stable/${DARCH}/docker-27.5.1.tgz" -o "$DOCKER_TGZ" 2>/dev/null; then
    tar -xzf "$DOCKER_TGZ" -C /tmp docker/docker 2>/dev/null && install -m0755 /tmp/docker/docker "$HELPERS/docker" && rm -rf "$DOCKER_TGZ" /tmp/docker
  fi
fi
bundle_cli docker "" ""

echo "==> Bundling zstd (decompresses the engine assets on first launch)…"
ZSTD_BIN="$(command -v zstd)"
cp "$ZSTD_BIN" "$HELPERS/zstd"
codesign --force --options runtime -s "${DORY_SIGN_ID:-Developer ID Application}" "$HELPERS/zstd" 2>/dev/null \
  || codesign --force -s - "$HELPERS/zstd"
echo "    bundled Helpers/zstd"

echo "==> Bundling the VM kernel + initfs, compressed (so the engine needs no \`container\` install)…"
DORY_GUEST_KERNEL_ZST="$(dirname "$0")/../guest/out/Image.zst"
if [ -n "${DORY_KERNEL:-}" ]; then
  KERNEL_SRC="$DORY_KERNEL"
elif [ -f "$DORY_GUEST_KERNEL_ZST" ]; then
  KERNEL_SRC="$DORY_GUEST_KERNEL_ZST"
else
  KERNEL_SRC="$(ls -t "$SUPPORT"/kernels/vmlinux-* 2>/dev/null | head -1)"
fi
INITFS_SRC="${DORY_INITFS:-$(ls -t "$SUPPORT"/containers/*/initfs.ext4 2>/dev/null | head -1)}"
INITFS_TO_BUNDLE="$INITFS_SRC"
if [ -n "$KERNEL_SRC" ] && [ -f "$KERNEL_SRC" ]; then
  if [ "${KERNEL_SRC##*.}" = "zst" ]; then
    cp "$KERNEL_SRC" "$RESOURCES/dory-vm-kernel.zst"
  else
    zstd -19 -q -f "$KERNEL_SRC" -o "$RESOURCES/dory-vm-kernel.zst"
  fi
  echo "    bundled Resources/dory-vm-kernel.zst ($(du -h "$RESOURCES/dory-vm-kernel.zst" | awk '{print $1}'), from $(du -h "$KERNEL_SRC" | awk '{print $1}'))"
else
  echo "    WARNING: no kernel found at guest/out/Image.zst or under $SUPPORT/kernels; run guest/kernel/build.sh or set DORY_KERNEL"
fi
if [ -n "$INITFS_SRC" ] && [ -f "$INITFS_SRC" ]; then
  DORY_GUEST_AGENT="$(dirname "$0")/../guest/out/dory-agent"
  inject_dory_agent_into_initfs "$INITFS_SRC" "$DORY_GUEST_AGENT" "/tmp/dory-initfs-agent-$$.ext4"
  QEMU_X86_64="$(find_qemu_x86_64_static || true)"
  if [ -n "$QEMU_X86_64" ]; then
    inject_qemu_into_initfs "$INITFS_TO_BUNDLE" "$QEMU_X86_64"
  else
    echo "    WARNING: qemu-x86_64-static not found; amd64 binfmt will rely on the runtime installer fallback"
  fi
  inject_debug_toolbox_into_initfs "$INITFS_TO_BUNDLE"
  # --long catches the large zero-fill region in the sparse ext4 (512MB -> ~31MB).
  zstd -19 --long=27 -q -f "$INITFS_TO_BUNDLE" -o "$RESOURCES/dory-vm-initfs.ext4.zst"
  echo "    bundled Resources/dory-vm-initfs.ext4.zst ($(du -h "$RESOURCES/dory-vm-initfs.ext4.zst" | awk '{print $1}'), from $(du -h "$INITFS_TO_BUNDLE" | awk '{print $1}'))"
  [ "$INITFS_TO_BUNDLE" = "$INITFS_SRC" ] || rm -f "$INITFS_TO_BUNDLE"
else
  echo "    WARNING: no initfs found — set DORY_INITFS to a built initfs.ext4"
fi

if [ "${DORY_BUNDLE_LEGACY:-0}" = "1" ]; then
  echo "==> DORY_BUNDLE_LEGACY=1: injecting the heavy offline payload (image tar + container toolchain)…"
  IMAGE="${DORY_ENGINE_IMAGE:-docker.io/library/docker:dind}"
  CONTAINER_BIN="$(command -v container || true)"
  [ -n "$CONTAINER_BIN" ] || { echo "container CLI not found; cannot bundle legacy payload"; exit 1; }
  container image save "$IMAGE" -o "$RESOURCES/dory-engine-image.tar"
  echo "    bundled Resources/dory-engine-image.tar ($(du -h "$RESOURCES/dory-engine-image.tar" | awk '{print $1}'))"
  CELLAR="$(dirname "$(dirname "$(readlink -f "$CONTAINER_BIN" || echo "$CONTAINER_BIN")")")"
  cp "$CONTAINER_BIN" "$HELPERS/container"
  [ -d "$CELLAR/libexec" ] && cp -R "$CELLAR/libexec" "$HELPERS/libexec"
  echo "    bundled Helpers/container + libexec"
fi

TOTAL="$(du -sh "$RESOURCES"/dory-vm-* "$HELPERS"/dory-vm 2>/dev/null | awk '{s+=$1} END{print s}')"
echo "==> Payload injected into $APP"
echo "    Engine payload ≈ $(du -ch "$RESOURCES"/dory-vm-*.zst "$HELPERS"/dory-vm 2>/dev/null | tail -1 | awk '{print $1}') on disk (engine image pulled on first launch)"
echo "    Re-sign the bundle (codesign --deep) before notarization so the payload is sealed."
