#!/bin/bash
# Memory benchmark: Dory's shared VM (all containers in one VM) vs one micro-VM per container.
#
# Methodology: measure system memory in use (active + wired + compressed, via vm_stat) before and
# after starting N identical containers, in each mode. The delta is the memory those containers and
# their VM(s) cost. Backend-agnostic — no internal APIs, just the public CLIs and vm_stat.
#
# Requires a real macOS 26 (Tahoe) machine with hardware virtualization: Dory's engine running
# (shared VM, socket at ~/.dory/dory.sock) and Apple's `container` CLI for the per-container mode.
# This CANNOT run on GitHub-hosted runners — they are VMs without nested virtualization.
#
# Usage:
#   scripts/benchmark.sh [count] [image]             # memory benchmark
#   scripts/benchmark.sh fileshare [host-dir]        # virtio-fs file-sharing benchmark
set -euo pipefail

COUNT="${1:-2}"
IMAGE="${2:-alpine:latest}"
DORY_SOCK="${DORY_SOCK:-$HOME/.dory/dory.sock}"
CONTAINER_BIN="$(command -v container || echo /opt/homebrew/bin/container)"
SETTLE="${BENCH_SETTLE:-12}"
LABEL="dory-bench"

[ "$(uname)" = "Darwin" ] || { echo "benchmark requires macOS"; exit 1; }

if [ "${1:-}" = "fileshare" ]; then
  shift
  SHARE_ROOT="${1:-$PWD/.dory-file-bench}"
  RESULT_DIR="${BENCH_RESULT_DIR:-$PWD/docs/research}"
  FILE_IMAGE="${DORY_FILE_BENCH_IMAGE:-dory/file-bench:local}"
  KERNEL_TREE="${BENCH_KERNEL_TREE:-}"
  NPM_PACKAGE="${BENCH_NPM_PACKAGE:-vite@latest}"
  mkdir -p "$SHARE_ROOT" "$RESULT_DIR"

  docker_sock_args() {
    local sock="$1"; shift
    docker -H "unix://$sock" "$@"
  }

  ensure_file_bench_image() {
    local sock="$1" tmp
    if docker_sock_args "$sock" image inspect "$FILE_IMAGE" >/dev/null 2>&1; then return 0; fi
    tmp="$(mktemp -d -t dory-file-bench.XXXXXX)"
    cat > "$tmp/Dockerfile" <<'DOCKERFILE'
FROM ubuntu:24.04
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends fio git nodejs npm ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /work
DOCKERFILE
    docker_sock_args "$sock" build -t "$FILE_IMAGE" "$tmp" >/dev/null
    rm -rf "$tmp"
  }

  run_timed() {
    /usr/bin/time -p "$@" 2>&1 >/tmp/dory-bench-out.$$ | awk '/^real / { print $2 }'
  }

  bench_engine() {
    local name="$1" sock="$2" root="$SHARE_ROOT/$name" fio_dir npm_dir git_dir fio_time npm_time git_time
    [ -S "$sock" ] || { echo "skip $name: socket not found $sock" >&2; return 0; }
    rm -rf "$root"
    mkdir -p "$root/fio" "$root/npm"
    ensure_file_bench_image "$sock"

    fio_dir="$root/fio"
    fio_time="$(run_timed docker_sock_args "$sock" run --rm -v "$fio_dir:/work" "$FILE_IMAGE" \
      fio --name=dory-randread --directory=/work --rw=randread --bs=4k --size=256m --iodepth=16 --numjobs=1 --runtime=30 --time_based --group_reporting)"

    npm_dir="$root/npm"
    npm_time="$(run_timed docker_sock_args "$sock" run --rm -v "$npm_dir:/work" "$FILE_IMAGE" \
      sh -lc "npm init -y >/dev/null 2>&1 && npm install $NPM_PACKAGE >/dev/null")"

    git_time="null"
    if [ -n "$KERNEL_TREE" ] && [ -d "$KERNEL_TREE/.git" ]; then
      git_dir="$root/linux"
      rm -rf "$git_dir"
      cp -R "$KERNEL_TREE" "$git_dir"
      git_time="$(run_timed docker_sock_args "$sock" run --rm -v "$git_dir:/work" "$FILE_IMAGE" git -C /work status --porcelain=v1)"
    fi

    cat <<JSON
    {
      "engine": "$name",
      "socket": "$sock",
      "fio4kRandreadSeconds": $fio_time,
      "npmInstallSeconds": $npm_time,
      "gitStatusSeconds": $git_time
    }
JSON
  }

  echo "==> Benchmarking file sharing in $SHARE_ROOT"
  {
    echo "{"
    echo "  \"shareRoot\": \"$SHARE_ROOT\","
    echo "  \"image\": \"$FILE_IMAGE\","
    echo "  \"npmPackage\": \"$NPM_PACKAGE\","
    echo "  \"kernelTree\": \"${KERNEL_TREE:-}\","
    echo "  \"results\": ["
    first=1
    for spec in \
      "dory:$DORY_SOCK" \
      "orbstack:${ORBSTACK_DOCKER_SOCK:-$HOME/.orbstack/run/docker.sock}" \
      "docker-desktop:${DOCKER_DESKTOP_SOCK:-$HOME/.docker/run/docker.sock}"; do
      name="${spec%%:*}"
      sock="${spec#*:}"
      result="$(bench_engine "$name" "$sock" || true)"
      [ -n "$result" ] || continue
      [ "$first" -eq 1 ] || echo ","
      first=0
      printf "%s\n" "$result"
    done
    echo "  ]"
    echo "}"
  } > "$RESULT_DIR/file-sharing-benchmark.json"
  echo "wrote $RESULT_DIR/file-sharing-benchmark.json"
  exit 0
fi

# Used memory in bytes = (active + wired + compressed) pages * page size.
used_mem() {
  vm_stat | awk '
    /page size of/ { for (i=1;i<=NF;i++) if ($i+0>0) ps=$i }
    /Pages active/ { gsub(/\./,"",$3); a=$3 }
    /Pages wired down/ { gsub(/\./,"",$4); w=$4 }
    /Pages occupied by compressor/ { gsub(/\./,"",$5); c=$5 }
    END { printf "%.0f", (a+w+c)*ps }'
}

settle() { sleep "$SETTLE"; }

cleanup_shared() {
  docker -H "unix://$DORY_SOCK" ps -aq --filter "label=$LABEL" 2>/dev/null \
    | xargs -I{} docker -H "unix://$DORY_SOCK" rm -f {} >/dev/null 2>&1 || true
}
cleanup_percontainer() {
  "$CONTAINER_BIN" ls -aq 2>/dev/null | grep "^$LABEL-" 2>/dev/null \
    | xargs -I{} "$CONTAINER_BIN" rm -f {} >/dev/null 2>&1 || true
}

measure() { # mode -> prints delta bytes
  local mode="$1" base peak i
  if [ "$mode" = shared ]; then cleanup_shared; else cleanup_percontainer; fi
  settle
  base="$(used_mem)"
  for i in $(seq 1 "$COUNT"); do
    if [ "$mode" = shared ]; then
      docker -H "unix://$DORY_SOCK" run -d --label "$LABEL" "$IMAGE" sleep 600 >/dev/null
    else
      "$CONTAINER_BIN" run -d --name "$LABEL-$i" "$IMAGE" sleep 600 >/dev/null
    fi
  done
  settle
  peak="$(used_mem)"
  if [ "$mode" = shared ]; then cleanup_shared; else cleanup_percontainer; fi
  echo $(( peak - base ))
}

mb() { awk -v b="$1" 'BEGIN { printf "%.0f", b/1048576 }'; }

echo "==> Benchmarking $COUNT × $IMAGE  (settle ${SETTLE}s)…"
trap 'cleanup_shared; cleanup_percontainer' EXIT

SHARED="$(measure shared)"
PERCON="$(measure percontainer)"
RATIO="$(awk -v p="$PERCON" -v s="$SHARED" 'BEGIN { printf "%.1f", (s>0)? p/s : 0 }')"

printf '\n%-28s %8s MB\n' "Dory — one shared VM" "$(mb "$SHARED")"
printf '%-28s %8s MB\n'   "One VM per container"  "$(mb "$PERCON")"
printf '%-28s %8sx\n\n'   "Less memory"            "$RATIO"

cat > benchmark-results.json <<JSON
{
  "containers": $COUNT,
  "image": "$IMAGE",
  "sharedVmBytes": $SHARED,
  "perContainerBytes": $PERCON,
  "sharedVmMb": $(mb "$SHARED"),
  "perContainerMb": $(mb "$PERCON"),
  "ratio": $RATIO
}
JSON
echo "wrote benchmark-results.json"
