#!/bin/sh
set -eu

if [ "$(uname -s)" != "Linux" ]; then
    echo "guest probes must be built inside the target Linux guest" >&2
    exit 1
fi

source_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
output_dir=${1:-"$source_dir/out/$(uname -m)"}
compiler=${CC:-cc}
glslc_bin=${GLSLC:-glslc}
compositor_commit=${DORY_COMPOSITOR_SOURCE_COMMIT:-stock-distro-session}

for command in "$compiler" "$glslc_bin" pkg-config; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "missing guest build dependency: $command" >&2
        exit 1
    }
done

mkdir -p "$output_dir"
output_dir=$(CDPATH='' cd -- "$output_dir" && pwd -P)
cflags="-std=c11 -O2 -g -Wall -Wextra -Wpedantic"

"$glslc_bin" -O "$source_dir/dory-compute-reduce.comp" \
    -o "$output_dir/dory-compute-reduce.spv"

# cflags and pkg-config output intentionally expand into individual compiler arguments.
# shellcheck disable=SC2046,SC2086
"$compiler" $cflags $(pkg-config --cflags vulkan wayland-client xcb) \
    "$source_dir/dory-vulkan-probe.c" -o "$output_dir/dory-vulkan-probe" \
    $(pkg-config --libs vulkan wayland-client xcb)

# shellcheck disable=SC2046,SC2086
"$compiler" $cflags $(pkg-config --cflags vulkan libdrm) \
    -DDORY_COMPOSITOR_SOURCE_COMMIT="\"$compositor_commit\"" \
    "$source_dir/dory-vulkan-compositor-probe.c" \
    -o "$output_dir/dory-vulkan-compositor-probe" \
    $(pkg-config --libs vulkan libdrm)

# shellcheck disable=SC2046,SC2086
"$compiler" $cflags $(pkg-config --cflags vulkan) \
    "$source_dir/dory-compute-probe.c" -o "$output_dir/dory-compute-probe" \
    $(pkg-config --libs vulkan)

# shellcheck disable=SC2046,SC2086
"$compiler" $cflags $(pkg-config --cflags glew sdl2) \
    "$source_dir/dory-gl-probe.c" -o "$output_dir/dory-gl-probe" \
    $(pkg-config --libs glew sdl2)

printf '%s\n' \
    "schema=dev.dory.guest-probe-build" \
    "version=2" \
    "architecture=$(uname -m)" \
    "kernel=$(uname -r)" \
    "compiler=$($compiler --version | sed -n '1p')" \
    "compositorSourceCommit=$compositor_commit" \
    "visualChallengeEncoding=fnv1a64-frame16-grid12x10" \
    "visualChallengeHeaderSHA256=$(sha256sum "$source_dir/dory-visual-challenge.h" | awk '{print $1}')" \
    "vulkanProbeSourceSHA256=$(sha256sum "$source_dir/dory-vulkan-probe.c" | awk '{print $1}')" \
    "vulkanCompositorProbeSourceSHA256=$(sha256sum "$source_dir/dory-vulkan-compositor-probe.c" | awk '{print $1}')" \
    "computeProbeSourceSHA256=$(sha256sum "$source_dir/dory-compute-probe.c" | awk '{print $1}')" \
    "computeShaderSourceSHA256=$(sha256sum "$source_dir/dory-compute-reduce.comp" | awk '{print $1}')" \
    "glProbeSourceSHA256=$(sha256sum "$source_dir/dory-gl-probe.c" | awk '{print $1}')" \
    "vulkanProbeBinarySHA256=$(sha256sum "$output_dir/dory-vulkan-probe" | awk '{print $1}')" \
    "vulkanCompositorProbeBinarySHA256=$(sha256sum "$output_dir/dory-vulkan-compositor-probe" | awk '{print $1}')" \
    "computeProbeBinarySHA256=$(sha256sum "$output_dir/dory-compute-probe" | awk '{print $1}')" \
    "computeShaderBinarySHA256=$(sha256sum "$output_dir/dory-compute-reduce.spv" | awk '{print $1}')" \
    "glProbeBinarySHA256=$(sha256sum "$output_dir/dory-gl-probe" | awk '{print $1}')" \
    "output=$output_dir" > "$output_dir/build-receipt.txt"

echo "built Dory GPU probes with the guest toolchain in $output_dir"
