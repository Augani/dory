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
# Usage:  scripts/benchmark.sh [count] [image]      e.g.  scripts/benchmark.sh 2 alpine:latest
set -euo pipefail

COUNT="${1:-2}"
IMAGE="${2:-alpine:latest}"
DORY_SOCK="${DORY_SOCK:-$HOME/.dory/dory.sock}"
CONTAINER_BIN="$(command -v container || echo /opt/homebrew/bin/container)"
SETTLE="${BENCH_SETTLE:-12}"
LABEL="dory-bench"

[ "$(uname)" = "Darwin" ] || { echo "benchmark requires macOS"; exit 1; }

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
