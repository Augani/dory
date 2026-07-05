#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INITFS_DIR="$ROOT/guest/initfs"
OUT_DIR="$ROOT/guest/out"
CACHE_DIR="${DORY_INITFS_CACHE:-$ROOT/guest/.cache/initfs}"
PINS="$INITFS_DIR/PINS"
SIZE_MB="${DORY_INITFS_SIZE_MB:-512}"

mkdir -p "$OUT_DIR" "$CACHE_DIR"

find_mke2fs() {
  for cand in "${DORY_MKE2FS:-}" \
              "$(command -v mke2fs 2>/dev/null || true)" \
              "$(command -v mkfs.ext4 2>/dev/null || true)" \
              "$HOME/Library/Android/sdk/platform-tools/mke2fs" \
              /opt/homebrew/opt/e2fsprogs/sbin/mke2fs \
              /usr/local/opt/e2fsprogs/sbin/mke2fs; do
    [ -n "$cand" ] && [ -x "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

pin_field() {
  local key="$1" field="$2"
  awk -v key="$key" -v field="$field" '
    $1 == key {
      if (field == "url") print $2
      else if (field == "sha256") print $3
      exit
    }
  ' "$PINS"
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

fetch_pin() {
  local key="$1" url expected name path actual
  url="$(pin_field "$key" url)"
  expected="$(pin_field "$key" sha256)"
  [ -n "$url" ] && [ -n "$expected" ] || { echo "missing pin for $key" >&2; exit 1; }
  name="$(basename "$url")"
  path="$CACHE_DIR/$name"
  if [ ! -f "$path" ] || [ "$(sha256_file "$path")" != "$expected" ]; then
    rm -f "$path"
    curl -fL --retry 3 "$url" -o "$path"
  fi
  actual="$(sha256_file "$path")"
  [ "$actual" = "$expected" ] || { echo "sha256 mismatch for $name: expected $expected got $actual" >&2; exit 1; }
  printf '%s\n' "$path"
}

normalize_arch() {
  case "${1:-}" in
    arm64|aarch64) printf '%s\n' arm64 ;;
    amd64|x86_64) printf '%s\n' amd64 ;;
    *) echo "usage: guest/initfs/build.sh [arm64|amd64|all]" >&2; exit 2 ;;
  esac
}

extract_tar() {
  local tarball="$1" dest="$2"
  tar -xzf "$tarball" -C "$dest" --exclude './dev/*' --exclude 'dev/*'
}

install_docker_static() {
  local tarball="$1" dest="$2" tmp
  tmp="$(mktemp -d)"
  tar -xzf "$tarball" -C "$tmp"
  mkdir -p "$dest/usr/local/bin"
  for name in runc ctr containerd docker-proxy docker-init docker dockerd containerd-shim-runc-v2; do
    if [ -f "$tmp/docker/$name" ]; then
      install -m0755 "$tmp/docker/$name" "$dest/usr/local/bin/$name"
    fi
  done
  rm -rf "$tmp"
}

write_runtime_files() {
  local rootfs="$1" arch="$2" agent="$OUT_DIR/dory-agent-$arch"
  mkdir -p "$rootfs"/{dev,proc,sys,run,tmp,var/log,var/run,var/lib/docker,usr/bin,usr/local/bin,etc,sbin}
  rm -f "$rootfs/sbin/init"
  cp "$INITFS_DIR/init" "$rootfs/sbin/init"
  chmod 0755 "$rootfs/sbin/init"
  if [ -x "$agent" ]; then
    install -m0755 "$agent" "$rootfs/usr/bin/dory-agent"
  else
    echo "WARNING: $agent not found; run guest/agent/build.sh before building initfs for guest RPC" >&2
  fi
  cat > "$rootfs/etc/resolv.conf" <<'EOF'
nameserver 192.168.127.1
nameserver 1.1.1.1
EOF
  cat > "$rootfs/etc/hostname" <<'EOF'
dory-engine
EOF
}

build_arch() {
  local arch="$1" alpine_key docker_key alpine_tar docker_tar rootfs image mke2fs
  alpine_key="alpine_$arch"
  docker_key="docker_$arch"
  alpine_tar="$(fetch_pin "$alpine_key")"
  docker_tar="$(fetch_pin "$docker_key")"
  rootfs="$(mktemp -d)"
  image="$OUT_DIR/initfs-$arch.ext4"
  mke2fs="$(find_mke2fs)" || { echo "mke2fs not found; install e2fsprogs or Android platform-tools" >&2; exit 1; }

  extract_tar "$alpine_tar" "$rootfs"
  install_docker_static "$docker_tar" "$rootfs"
  write_runtime_files "$rootfs" "$arch"

  rm -f "$image"
  truncate -s "${SIZE_MB}m" "$image"
  "$mke2fs" -q -F -t ext4 -L dory-initfs -d "$rootfs" "$image"
  rm -rf "$rootfs"
  echo "built $image ($(du -h "$image" | awk '{print $1}'))"
}

case "${1:-all}" in
  all)
    build_arch arm64
    build_arch amd64
    ;;
  *)
    build_arch "$(normalize_arch "$1")"
    ;;
esac
