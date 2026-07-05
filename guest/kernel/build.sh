#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
source PINS

OUT="$(pwd)/../out"
mkdir -p "$OUT"

docker run --rm --platform linux/arm64 \
  -v "$PWD":/src \
  -v "$OUT":/out \
  -w /build \
  debian:12-slim bash -euxc '
  apt-get update
  apt-get install -y build-essential flex bison bc libssl-dev libelf-dev xz-utils zstd curl
  curl -fsSL '"$KERNEL_URL"' -o linux.tar.xz
  echo "'"$KERNEL_SHA256"'  linux.tar.xz" | sha256sum -c -
  tar xf linux.tar.xz --strip-components=1
  make defconfig
  scripts/kconfig/merge_config.sh -m .config /src/dory.config
  make olddefconfig
  make -j$(nproc) Image
  cp arch/arm64/boot/Image /out/Image
  zstd -19 -f /out/Image -o /out/Image.zst
'
