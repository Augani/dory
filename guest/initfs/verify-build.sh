#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

case "${1:-arm64}" in
  arm64|aarch64) ARCH=arm64 ;;
  amd64|x86_64) ARCH=amd64 ;;
  *) echo "usage: $0 [arm64|amd64]" >&2; exit 64 ;;
esac

OUT="${DORY_INITFS_OUT_DIR:-guest/out}"
AGENT="$OUT/dory-agent-$ARCH"
IMAGE="$OUT/initfs-$ARCH.ext4"
STAMP="$OUT/initfs-build-$ARCH.stamp"

fail() {
  echo "initfs verification failed: $*" >&2
  exit 1
}

stamp_value() {
  local key="$1"
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$STAMP"
}

find_debugfs() {
  local candidate
  for candidate in \
    "$(command -v debugfs 2>/dev/null || true)" \
    /opt/homebrew/opt/e2fsprogs/sbin/debugfs \
    /usr/local/opt/e2fsprogs/sbin/debugfs; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

for path in "$AGENT" "$IMAGE" "$STAMP"; do
  [ -s "$path" ] || fail "missing or empty $path; rebuild with guest/initfs/build.sh $ARCH"
done

EXPECTED_INPUT="$(guest/initfs/input-fingerprint.sh "$ARCH")"
[ "$(stamp_value schema)" = "3" ] || fail "$STAMP has an unsupported schema"
[ "$(stamp_value arch)" = "$ARCH" ] || fail "$STAMP was built for another architecture"
[ "$(stamp_value input_sha256)" = "$EXPECTED_INPUT" ] \
  || fail "$IMAGE is stale relative to the current initfs/guest-agent sources"
[ "$(stamp_value agent_sha256)" = "$(shasum -a 256 "$AGENT" | awk '{print $1}')" ] \
  || fail "$AGENT does not match its build stamp"
[ "$(stamp_value image_sha256)" = "$(shasum -a 256 "$IMAGE" | awk '{print $1}')" ] \
  || fail "$IMAGE does not match its build stamp"

file "$AGENT" | grep -q 'ELF 64-bit' || fail "$AGENT is not a 64-bit Linux ELF binary"
case "$ARCH" in
  arm64) file "$AGENT" | grep -Eq 'ARM aarch64|arm64' || fail "$AGENT is not arm64" ;;
  amd64) file "$AGENT" | grep -Eq 'x86-64|x86_64' || fail "$AGENT is not amd64" ;;
esac

DEBUGFS="$(find_debugfs)" || fail "debugfs is required to validate the initfs contents (install e2fsprogs)"

require_root_owned() {
  local path="$1" stat_output
  stat_output="$($DEBUGFS -R "stat $path" "$IMAGE" 2>&1)"
  grep -Eq 'User:[[:space:]]+0[[:space:]]+Group:[[:space:]]+0' <<<"$stat_output" \
    || fail "$IMAGE path is not root-owned: $path"
}
for required in \
  /bin/sh \
  /sbin/init \
  /sbin/e2fsck \
  /sbin/fstrim \
  /usr/sbin/dumpe2fs \
  /usr/sbin/resize2fs \
  /usr/bin/dory-agent \
  /usr/local/bin/containerd \
  /usr/local/bin/crun \
  /usr/local/bin/docker \
  /usr/local/bin/dockerd \
  /usr/local/bin/runc \
  /usr/sbin/iptables; do
  "$DEBUGFS" -R "stat $required" "$IMAGE" 2>&1 | grep -q '^Inode:' \
    || fail "$IMAGE is missing required guest path $required"
  require_root_owned "$required"
done

if [ "$ARCH" = arm64 ]; then
  for required in \
    /lib/ld-linux-aarch64.so.1 \
    /usr/bin/vulkaninfo \
    /usr/local/bin/dory-runc \
    /usr/local/bin/runc.real \
    /usr/lib/dory/fex/FEX \
    /usr/lib/dory/fex/FEXServer \
    /usr/lib/dory/engine-gpu-runtime.env \
    /usr/lib/aarch64-linux-gnu/libvulkan.so.1 \
    /opt/dory/mesa/lib/libvulkan_virtio.so \
    /opt/dory/mesa/libexec/dory-vulkan-compositor-probe \
    /opt/dory/mesa/libexec/dory-vulkan-probe \
    /opt/dory/mesa/share/vulkan/icd.d/virtio_icd.aarch64.json \
    /etc/vulkan/icd.d/dory-virtio_icd.aarch64.json \
    /opt/dory/mesa/share/dory/runtime.env \
    /opt/dory/mesa/share/dory/build-packages.txt \
    /usr/lib/dory/fex/licenses/FEX-Emu.copyright \
    /usr/lib/dory/fex/licenses/libc6.copyright \
    /usr/lib/dory/fex/licenses/gcc-14-base.copyright \
    /usr/lib/dory/fex/provenance/BUILD_PACKAGES.txt; do
    "$DEBUGFS" -R "stat $required" "$IMAGE" 2>&1 | grep -q '^Inode:' \
      || fail "$IMAGE is missing required Apple Silicon FEX path $required"
    require_root_owned "$required"
  done
fi

if [ "$ARCH" = amd64 ]; then
  for required in \
    /lib64/ld-linux-x86-64.so.2 \
    /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 \
    /lib/x86_64-linux-gnu/libc.so.6 \
    /lib/x86_64-linux-gnu/libdl.so.2 \
    /lib/x86_64-linux-gnu/libm.so.6 \
    /lib/x86_64-linux-gnu/libpthread.so.0 \
    /lib/x86_64-linux-gnu/libgcc_s.so.1 \
    /usr/lib/x86_64-linux-gnu/libstdc++.so.6 \
    /usr/lib/x86_64-linux-gnu/libX11.so.6 \
    /usr/lib/x86_64-linux-gnu/libX11-xcb.so.1 \
    /usr/lib/x86_64-linux-gnu/libXext.so.6 \
    /usr/lib/x86_64-linux-gnu/libXxf86vm.so.1 \
    /usr/lib/x86_64-linux-gnu/libxcb.so.1 \
    /usr/lib/x86_64-linux-gnu/libxcb-dri3.so.0 \
    /usr/lib/x86_64-linux-gnu/libxcb-glx.so.0 \
    /usr/lib/x86_64-linux-gnu/libxcb-present.so.0 \
    /usr/lib/x86_64-linux-gnu/libxcb-randr.so.0 \
    /usr/lib/x86_64-linux-gnu/libxcb-shm.so.0 \
    /usr/lib/x86_64-linux-gnu/libxcb-sync.so.1 \
    /usr/lib/x86_64-linux-gnu/libxcb-xfixes.so.0 \
    /usr/lib/x86_64-linux-gnu/libxshmfence.so.1 \
    /lib/x86_64-linux-gnu/libz.so.1 \
    /usr/lib/x86_64-linux-gnu/libzstd.so.1 \
    /usr/lib/dory/engine-gpu-runtime.env \
    /opt/dory/mesa/lib/dri/virtio_gpu_dri.so \
    /opt/dory/mesa/lib/libGL.so \
    /opt/dory/mesa/lib/libGL.so.1 \
    /opt/dory/mesa/lib/libGL.so.1.2.0 \
    /opt/dory/mesa/lib/libgallium-26.0.0-devel.so \
    /opt/dory/mesa/share/dory/runtime.env \
    /opt/dory/mesa/share/dory/build-packages.txt; do
    "$DEBUGFS" -R "stat $required" "$IMAGE" 2>&1 | grep -q '^Inode:' \
      || fail "$IMAGE is missing required PC VirGL2 runtime path $required"
  done
fi

AGENT_DUMP="$(mktemp /tmp/dory-agent-verify.XXXXXX)"
FEX_DUMP=""
FEX_SERVER_DUMP=""
FEX_BUILD_PACKAGES_DUMP=""
DORY_RUNC_DUMP=""
RUNC_REAL_DUMP=""
GPU_RUNTIME_DUMP=""
VENUS_ICD_DUMP=""
VENUS_MANIFEST_DUMP=""
PC_MESA_EXTRACT=""
PC_MESA_DUMP=""
PC_MESA_REFERENCE=""
CONTAINER_VENUS_ICD_DUMP=""
cleanup() {
  rm -f "$AGENT_DUMP" "$FEX_DUMP" "$FEX_SERVER_DUMP" "$FEX_BUILD_PACKAGES_DUMP" \
    "$DORY_RUNC_DUMP" "$RUNC_REAL_DUMP" "$GPU_RUNTIME_DUMP" "$VENUS_ICD_DUMP" \
    "$CONTAINER_VENUS_ICD_DUMP" "$VENUS_MANIFEST_DUMP"
  [ -z "$PC_MESA_EXTRACT" ] || rm -rf "$PC_MESA_EXTRACT"
  [ -z "$PC_MESA_DUMP" ] || rm -rf "$PC_MESA_DUMP"
  [ -z "$PC_MESA_REFERENCE" ] || rm -rf "$PC_MESA_REFERENCE"
}
trap cleanup EXIT
"$DEBUGFS" -R "dump /usr/bin/dory-agent $AGENT_DUMP" "$IMAGE" >/dev/null 2>&1 \
  || fail "could not extract /usr/bin/dory-agent from $IMAGE"
[ "$(shasum -a 256 "$AGENT_DUMP" | awk '{print $1}')" = "$(shasum -a 256 "$AGENT" | awk '{print $1}')" ] \
  || fail "$IMAGE embeds a different dory-agent than $AGENT"

if [ "$ARCH" = arm64 ]; then
  "$DEBUGFS" -R 'stat /usr/local/bin/runc' "$IMAGE" 2>&1 \
    | grep -q 'Fast link dest: "dory-runc"' \
    || fail "$IMAGE does not route BuildKit's conventional runc path through dory-runc"
  GPU_RUNTIME_DUMP="$(mktemp /tmp/dory-engine-gpu-runtime-verify.XXXXXX)"
  VENUS_ICD_DUMP="$(mktemp /tmp/dory-engine-venus-icd-verify.XXXXXX)"
  VENUS_MANIFEST_DUMP="$(mktemp /tmp/dory-engine-venus-manifest-verify.XXXXXX)"
  CONTAINER_VENUS_ICD_DUMP="$(mktemp /tmp/dory-container-venus-icd-verify.XXXXXX)"
  "$DEBUGFS" -R "dump /usr/lib/dory/engine-gpu-runtime.env $GPU_RUNTIME_DUMP" \
    "$IMAGE" >/dev/null 2>&1 || fail "could not extract the engine GPU runtime receipt"
  "$DEBUGFS" -R "dump /opt/dory/mesa/share/vulkan/icd.d/virtio_icd.aarch64.json $VENUS_ICD_DUMP" \
    "$IMAGE" >/dev/null 2>&1 || fail "could not extract the Venus ICD manifest"
  "$DEBUGFS" -R "dump /etc/vulkan/icd.d/dory-virtio_icd.aarch64.json $CONTAINER_VENUS_ICD_DUMP" \
    "$IMAGE" >/dev/null 2>&1 || fail "could not extract the container Venus ICD manifest"
  "$DEBUGFS" -R "dump /opt/dory/mesa/share/dory/runtime.env $VENUS_MANIFEST_DUMP" \
    "$IMAGE" >/dev/null 2>&1 || fail "could not extract the Venus runtime manifest"
  grep -Fqx 'schema=1' "$GPU_RUNTIME_DUMP" \
    || fail "$IMAGE contains an unsupported engine GPU runtime receipt"
  expected_mesa_sha="$(
    python3 - "$ROOT/Config/DoryRendererProductionTuple.json" <<'PY'
import json
import pathlib
import sys
definition = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(definition["guestMesaBuildPolicy"]["runtimeSHA256"])
PY
  )"
  grep -Fqx "mesa_runtime_sha256=$expected_mesa_sha" "$GPU_RUNTIME_DUMP" \
    || fail "$IMAGE embeds a Mesa Venus runtime outside the production tuple"
  grep -Fqx 'mesa_runtime_contract=DoryRendererArtifactManifest.guestMesa' \
    "$GPU_RUNTIME_DUMP" || fail "$IMAGE does not bind the Mesa runtime digest contract"
  grep -Fqx 'mesa_icd=/opt/dory/mesa/share/vulkan/icd.d/virtio_icd.aarch64.json' \
    "$GPU_RUNTIME_DUMP" || fail "$IMAGE does not bind the engine Venus ICD path"
  grep -Fqx 'container_vulkan_icd=/etc/vulkan/icd.d/dory-virtio_icd.aarch64.json' \
    "$GPU_RUNTIME_DUMP" || fail "$IMAGE does not bind the container Vulkan ICD path"
  grep -Fqx 'vulkaninfo_package=debian_vulkan_tools_arm64' "$GPU_RUNTIME_DUMP" \
    || fail "$IMAGE does not record the pinned vulkaninfo package"
  grep -Fqx 'vulkan_loader_package=debian_libvulkan1_arm64' "$GPU_RUNTIME_DUMP" \
    || fail "$IMAGE does not record the pinned Vulkan loader package"
  grep -Fqx 'debian_suite=bookworm' "$GPU_RUNTIME_DUMP" \
    || fail "$IMAGE does not record the pinned GPU userland suite"
  grep -Fqx 'debian_snapshot=20260713T000000Z' "$GPU_RUNTIME_DUMP" \
    || fail "$IMAGE does not record the pinned GPU userland snapshot"
  grep -Fq '"library_path": "../../../lib/libvulkan_virtio.so"' "$VENUS_ICD_DUMP" \
    || fail "$IMAGE Venus ICD is not relocatable within its Dory pack"
  python3 - "$VENUS_ICD_DUMP" "$CONTAINER_VENUS_ICD_DUMP" <<'PY' \
    || fail "$IMAGE container Venus ICD does not activate the tuple-bound Dory ICD"
import json
import pathlib
import sys

pack = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
container = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
expected = {
    "file_format_version": pack.get("file_format_version", "1.0.1"),
    "ICD": {
        "api_version": pack["ICD"]["api_version"],
        "library_arch": pack["ICD"].get("library_arch", "64"),
        "library_path": "/opt/dory/mesa/lib/libvulkan_virtio.so",
    },
}
if container != expected:
    raise SystemExit(1)
PY
  for manifest_line in \
    schema=6 \
    architecture=aarch64 \
    libc_family=glibc \
    vulkan_api=1.3 \
    vulkan13_features=dynamicRendering,maintenance4,synchronization2 \
    vulkan_device_extensions=VK_KHR_external_semaphore_fd,VK_KHR_swapchain \
    vulkan_instance_extensions=VK_KHR_surface,VK_KHR_wayland_surface,VK_KHR_xcb_surface \
    pack_layout=single-tree \
    libdrm_linkage=static-hidden \
    manifest_library_path=../../../lib/libvulkan_virtio.so; do
    grep -Fqx "$manifest_line" "$VENUS_MANIFEST_DUMP" \
      || fail "$IMAGE Venus runtime manifest omits $manifest_line"
  done
  FEX_DUMP="$(mktemp /tmp/dory-fex-verify.XXXXXX)"
  FEX_SERVER_DUMP="$(mktemp /tmp/dory-fex-server-verify.XXXXXX)"
  FEX_BUILD_PACKAGES_DUMP="$(mktemp /tmp/dory-fex-build-packages-verify.XXXXXX)"
  DORY_RUNC_DUMP="$(mktemp /tmp/dory-runc-verify.XXXXXX)"
  RUNC_REAL_DUMP="$(mktemp /tmp/dory-runc-real-verify.XXXXXX)"
  "$DEBUGFS" -R "dump /usr/lib/dory/fex/FEX $FEX_DUMP" "$IMAGE" >/dev/null 2>&1 \
    || fail "could not extract the FEX interpreter"
  "$DEBUGFS" -R "dump /usr/lib/dory/fex/FEXServer $FEX_SERVER_DUMP" "$IMAGE" >/dev/null 2>&1 \
    || fail "could not extract FEXServer"
  "$DEBUGFS" -R "dump /usr/lib/dory/fex/provenance/BUILD_PACKAGES.txt $FEX_BUILD_PACKAGES_DUMP" \
    "$IMAGE" >/dev/null 2>&1 || fail "could not extract the FEX build package inventory"
  "$DEBUGFS" -R "dump /usr/local/bin/dory-runc $DORY_RUNC_DUMP" "$IMAGE" >/dev/null 2>&1 \
    || fail "could not extract dory-runc"
  "$DEBUGFS" -R "dump /usr/local/bin/runc.real $RUNC_REAL_DUMP" "$IMAGE" >/dev/null 2>&1 \
    || fail "could not extract runc.real"
  FEX_PAIR="$(shasum -a 256 "$FEX_DUMP" | awk '{print $1}'):$(shasum -a 256 "$FEX_SERVER_DUMP" | awk '{print $1}')"
  case "$FEX_PAIR" in
    3f6e1a5ab3ae4d164573ee1ad381afff1670e9b124c0556e53101f025a74c134:bbe8a34fc2ba4e606acd7e5b11d9b51da283835f40d2851e2ed39d35d28f2597) ;;
    *) fail "$IMAGE contains an unverified static-PIE FEX binary pair" ;;
  esac
  [ "$(shasum -a 256 "$FEX_BUILD_PACKAGES_DUMP" | awk '{print $1}')" = \
      ad3b0e4ab4e53ac328b0209f592a6f86100f5ca2c17715f2b40ee9b130b0f0b1 ] \
    || fail "$IMAGE contains an unverified FEX build package inventory"
  for static_fex in "$FEX_DUMP" "$FEX_SERVER_DUMP"; do
    if patchelf --print-interpreter "$static_fex" >/dev/null 2>&1; then
      fail "$IMAGE contains a dynamically loaded FEX executable that cannot cross chroot boundaries"
    fi
    needed="$(patchelf --print-needed "$static_fex" 2>&1)" || {
      echo "$needed" | grep -q "cannot find section '.dynamic'" \
        || fail "$IMAGE FEX static-link verification failed"
      needed=""
    }
    [ -z "$needed" ] || fail "$IMAGE FEX executable has dynamic library dependencies"
  done
  file "$DORY_RUNC_DUMP" | grep -Eq 'ELF 64-bit.*(ARM aarch64|arm64).*(static-pie|statically) linked' \
    || fail "$IMAGE dory-runc is not a static arm64 Linux binary"
  file "$RUNC_REAL_DUMP" | grep -Eq 'ELF 64-bit.*(ARM aarch64|arm64).*(static-pie|statically) linked' \
    || fail "$IMAGE runc.real is not Docker's static arm64 runtime"
fi

if [ "$ARCH" = amd64 ]; then
  "$ROOT/guest/mesa/verify-pc-virgl2-build.sh" x86_64 >/dev/null
  expected_mesa_sha="$(shasum -a 256 "$ROOT/guest/out/dory-mesa-virgl2-x86_64.tar.zst" | awk '{print $1}')"
  GPU_RUNTIME_DUMP="$(mktemp /tmp/dory-engine-gpu-runtime-verify.XXXXXX)"
  "$DEBUGFS" -R "dump /usr/lib/dory/engine-gpu-runtime.env $GPU_RUNTIME_DUMP" \
    "$IMAGE" >/dev/null 2>&1 || fail "could not extract the PC VirGL2 runtime receipt"
  grep -Fqx 'schema=2' "$GPU_RUNTIME_DUMP" \
    || fail "$IMAGE contains an unsupported PC VirGL2 runtime receipt"
  grep -Fqx "mesa_runtime_sha256=$expected_mesa_sha" "$GPU_RUNTIME_DUMP" \
    || fail "$IMAGE embeds a PC VirGL2 runtime outside the verified producer artifact"
  grep -Fqx 'mesa_runtime_contract=DoryRendererArtifactManifest.guestMesa.pcVirGL2' \
    "$GPU_RUNTIME_DUMP" || fail "$IMAGE does not bind the PC VirGL2 Mesa runtime digest contract"
  grep -Fqx 'mesa_profile=pc-virgl2' "$GPU_RUNTIME_DUMP" \
    || fail "$IMAGE does not bind the PC VirGL2 Mesa profile"
  grep -Fqx 'mesa_architecture=x86_64' "$GPU_RUNTIME_DUMP" \
    || fail "$IMAGE does not bind the PC VirGL2 Mesa architecture"
  grep -Fqx 'mesa_gl_loader=/opt/dory/mesa/lib/libGL.so.1' "$GPU_RUNTIME_DUMP" \
    || fail "$IMAGE does not bind the PC VirGL2 GL loader path"
  grep -Fqx 'mesa_dri_driver=/opt/dory/mesa/lib/dri/virtio_gpu_dri.so' "$GPU_RUNTIME_DUMP" \
    || fail "$IMAGE does not bind the PC VirGL2 DRI driver path"
  grep -Fqx 'required_guest_ld_library_path=/opt/dory/mesa/lib' "$GPU_RUNTIME_DUMP" \
    || fail "$IMAGE does not bind the PC VirGL2 GL loader search path"
  grep -Fqx 'required_guest_libgl_drivers_path=/opt/dory/mesa/lib/dri' "$GPU_RUNTIME_DUMP" \
    || fail "$IMAGE does not bind the PC VirGL2 DRI search path"
  grep -Fqx 'producer_fence_contract=doryPCX8664LinuxVirGL2PrepareFBV1' "$GPU_RUNTIME_DUMP" \
    || fail "$IMAGE does not bind the PC VirGL2 producer-fence contract"
  grep -Fqx 'producer_fence_contract_raw=2' "$GPU_RUNTIME_DUMP" \
    || fail "$IMAGE does not bind the PC VirGL2 producer-fence wire value"
  grep -Fqx 'debian_suite=bookworm' "$GPU_RUNTIME_DUMP" \
    || fail "$IMAGE does not record the pinned PC VirGL2 userland suite"
  grep -Fqx 'debian_snapshot=20260713T000000Z' "$GPU_RUNTIME_DUMP" \
    || fail "$IMAGE does not record the pinned PC VirGL2 userland snapshot"

  PC_MESA_EXTRACT="$(mktemp -d /tmp/dory-pc-mesa-reference.XXXXXX)"
  PC_MESA_DUMP="$(mktemp -d /tmp/dory-pc-mesa-image.XXXXXX)"
  PC_MESA_REFERENCE="$PC_MESA_EXTRACT/opt/dory/mesa"
  zstd -q -d -c "$ROOT/guest/out/dory-mesa-virgl2-x86_64.tar.zst" \
    | tar -xf - -C "$PC_MESA_EXTRACT"
  for embedded in \
    lib/dri/virtio_gpu_dri.so \
    lib/libGL.so \
    lib/libGL.so.1 \
    lib/libGL.so.1.2.0 \
    lib/libgallium-26.0.0-devel.so \
    share/dory/build-packages.txt \
    share/dory/runtime.env; do
    mkdir -p "$PC_MESA_DUMP/$(dirname "$embedded")"
    "$DEBUGFS" -R "dump /opt/dory/mesa/$embedded $PC_MESA_DUMP/$embedded" \
      "$IMAGE" >/dev/null 2>&1 || fail "could not extract embedded PC VirGL2 runtime file $embedded"
    cmp -s "$PC_MESA_REFERENCE/$embedded" "$PC_MESA_DUMP/$embedded" \
      || fail "$IMAGE embeds PC VirGL2 runtime bytes that differ from the verified producer artifact: $embedded"
  done
fi

echo "verified $ARCH initfs input fingerprint $EXPECTED_INPUT"
