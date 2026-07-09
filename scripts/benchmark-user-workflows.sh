#!/usr/bin/env bash
# User-relevant container-engine head-to-head. Measures what developers actually feel, not synthetic
# throughput: real dependency install over a bind mount, per-container cold-start overhead, host->guest
# file-change (hot-reload) latency, image build I/O, and host RAM cost of a real stack. Engines run
# INTERLEAVED (round-robin) so run-to-run drift hits every engine equally; medians + coefficient of
# variation are reported per P0.5.
#
# Usage: scripts/benchmark-user-workflows.sh [--engines dory,orbstack,colima] [--rounds 7]
set -uo pipefail

ENGINES_CSV="${BENCH_ENGINES:-dory,orbstack,colima}"
ROUNDS="${BENCH_ROUNDS:-7}"
WORK="${BENCH_WORK:-$HOME/.dory-user-bench}"
NODE_IMAGE="${BENCH_NODE_IMAGE:-node:22-alpine}"
ALPINE_IMAGE="${BENCH_ALPINE_IMAGE:-alpine:3.21}"
PG_IMAGE="${BENCH_PG_IMAGE:-postgres:16-alpine}"
REDIS_IMAGE="${BENCH_REDIS_IMAGE:-redis:7-alpine}"
CV_WARN="${BENCH_CV_WARN_PCT:-15}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --engines) ENGINES_CSV="$2"; shift 2 ;;
    --rounds) ROUNDS="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
IFS=',' read -r -a ENGINES <<< "$ENGINES_CSV"
mkdir -p "$WORK"

# ---- engine plumbing ----------------------------------------------------------------------------
sock_for() {
  case "$1" in
    dory) echo "${DORY_SOCK:-$HOME/.dory/dory.sock}" ;;
    orbstack) echo "${ORBSTACK_SOCK:-$HOME/.orbstack/run/docker.sock}" ;;
    colima) echo "${COLIMA_SOCK:-$HOME/.colima/default/docker.sock}" ;;
    docker-desktop) echo "${DOCKER_DESKTOP_SOCK:-$HOME/.docker/run/docker.sock}" ;;
    *) echo "" ;;
  esac
}
proc_pattern() {
  case "$1" in
    dory) echo "${DORY_PROCESS_PATTERN:-Dory|doryd|dory-hv|dory-vmm|gvproxy}" ;;
    orbstack) echo "${ORBSTACK_PROCESS_PATTERN:-OrbStack|xbin/vmgr|orbstack}" ;;
    colima) echo "${COLIMA_PROCESS_PATTERN:-colima|limactl|lima-guestagent|socket_vmnet|qemu-system|Virtualization.VirtualMachine}" ;;
    *) echo "$1" ;;
  esac
}
de() { local e="$1"; shift; docker -H "unix://$(sock_for "$e")" "$@"; }
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
# Per-engine phys_footprint (MB) summed over the engine's process tree — the RAM the engine actually
# charges, isolated from unrelated system churn. footprint(1) works on the current user's processes.
footprint_mb() {
  local pat pid v u tot=0
  pat="$(proc_pattern "$1")"
  for pid in $(ps -axo pid,args | awk -v p="$pat" '$0 ~ p && $0 !~ /awk/ { print $1 }'); do
    set -- $(/usr/bin/footprint "$pid" 2>/dev/null | awk '/phys_footprint:/ { print $2, $3; exit }')
    v="${1:-}"; u="${2:-}"; [ -n "$v" ] || continue
    tot=$(awk -v t="$tot" -v v="$v" -v u="$u" 'BEGIN{ m=(u=="KB"||u=="K")?v/1024:(u=="GB"||u=="G")?v*1024:v; printf "%.0f", t+m }')
  done
  echo "$tot"
}

# ---- stats --------------------------------------------------------------------------------------
median() { printf '%s\n' "$@" | awk '{v[n++]=$1+0} END{if(!n){print 0;exit} for(i=0;i<n;i++)for(j=i+1;j<n;j++)if(v[j]<v[i]){t=v[i];v[i]=v[j];v[j]=t} printf (n%2)?"%.3f":"%.3f", (n%2)?v[(n-1)/2]:(v[n/2-1]+v[n/2])/2}'; }
cvpct()  { [ "$#" -gt 1 ] || { printf 0; return; }; printf '%s\n' "$@" | awk '{v[n++]=$1+0;s+=$1+0} END{if(n<2||s==0){print 0;exit} m=s/n;for(i=0;i<n;i++){d=v[i]-m;ss+=d*d} printf "%.1f",100*sqrt(ss/(n-1))/m}'; }

# ---- fixtures -----------------------------------------------------------------------------------
setup_fixtures() {
  local npm="$WORK/npm" build="$WORK/build" hot="$WORK/hot"
  mkdir -p "$npm" "$build" "$hot" "$WORK/npmcache"
  cat > "$npm/package.json" <<'JSON'
{ "name":"dory-bench","version":"1.0.0","private":true,
  "dependencies":{
    "express":"4.19.2","lodash":"4.17.21","axios":"1.6.8","chalk":"4.1.2",
    "react":"18.3.1","react-dom":"18.3.1","typescript":"5.4.5","commander":"12.1.0",
    "date-fns":"3.6.0","zod":"3.23.8"
  } }
JSON
  # I/O-heavy build with NO network so it measures the snapshotter/overlay, not apt/apk downloads.
  cat > "$build/Dockerfile" <<DOCKER
FROM $ALPINE_IMAGE
RUN mkdir -p /w && cd /w \\
 && for i in \$(seq 1 3000); do printf 'content line %s\\n' "\$i" > "f\$i.txt"; done \\
 && cat /w/f*.txt | wc -l \\
 && for i in \$(seq 1 3000); do rm -f "/w/f\$i.txt"; done
CMD ["true"]
DOCKER
}

# ---- metrics ------------------------------------------------------------------------------------
# 1) npm install over a HOST bind mount — the decade-old #1 Docker-on-Mac file-sharing pain.
warm_npm() { local e="$1"; de "$e" run --rm -v "$WORK/npm:/app" -v "$WORK/npmcache:/root/.npm" -w /app "$NODE_IMAGE" \
    sh -c 'npm install --no-audit --no-fund --loglevel=error' >/dev/null 2>&1; rm -rf "$WORK/npm/node_modules" "$WORK/npm/package-lock.json"; }
m_npm() {
  local e="$1"; rm -rf "$WORK/npm/node_modules" "$WORK/npm/package-lock.json"
  local t0 t1; t0=$(now_ms)
  de "$e" run --rm -v "$WORK/npm:/app" -v "$WORK/npmcache:/root/.npm" -w /app "$NODE_IMAGE" \
    sh -c 'npm install --no-audit --no-fund --loglevel=error' >/dev/null 2>&1
  t1=$(now_ms); awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f\n",(b-a)/1000}'
}

# 2) Per-container cold-start overhead — create+start+teardown of a trivial container.
m_coldstart() { local e="$1" t0 t1; t0=$(now_ms); de "$e" run --rm "$ALPINE_IMAGE" true >/dev/null 2>&1; t1=$(now_ms); echo $((t1-t0)); }

# 3) Hot-reload latency — how long after a HOST edit does a process in the container see it? A
#    persistent container tight-copies /w/a -> /w/b; we write a sentinel to a and wait for it in b.
#    Round-trips the mount twice, so it captures the cache-coherence window a file watcher fights.
hot_start() { local e="$1"; de "$e" rm -f "hotwatch-$e" >/dev/null 2>&1; echo INIT > "$WORK/hot/a"; : > "$WORK/hot/b"
  de "$e" run -d --name "hotwatch-$e" -v "$WORK/hot:/w" "$ALPINE_IMAGE" \
    sh -c 'while true; do cp /w/a /w/b 2>/dev/null; sleep 0.01; done' >/dev/null 2>&1; }
hot_stop() { local e="$1"; de "$e" rm -f "hotwatch-$e" >/dev/null 2>&1; }
m_hotreload() {
  local e="$1" sentinel; sentinel="s$(now_ms)$RANDOM"
  local t0; t0=$(now_ms); printf '%s\n' "$sentinel" > "$WORK/hot/a"
  local deadline=$(( t0 + 5000 ))
  while [ "$(now_ms)" -lt "$deadline" ]; do
    grep -q "$sentinel" "$WORK/hot/b" 2>/dev/null && { echo $(( $(now_ms) - t0 )); return; }
  done
  echo "-1"  # timed out (>5s) — hot reload effectively broken for this engine
}

# 4a) Image build I/O (no network) — snapshotter/overlay write path.
m_build() { local e="$1" t0 t1; t0=$(now_ms); de "$e" build --no-cache -q -t "dorybench:$e" "$WORK/build" >/dev/null 2>&1; t1=$(now_ms); awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f\n",(b-a)/1000}'; }

# 4b) Host RAM cost of a real stack (postgres+redis) — system-wide, engine-agnostic. Measured once
#     (not per round): delta of host used-memory with the stack up, then a reclaim reading 20s after
#     tearing it down (dory returns pages via free-page reporting; VZ engines do not).
mem_stack() {
  local e="$1" base up after
  de "$e" rm -f "pg-$e" "redis-$e" >/dev/null 2>&1
  sleep 5; base=$(footprint_mb "$e")
  de "$e" run -d --name "pg-$e" -e POSTGRES_PASSWORD=bench "$PG_IMAGE" >/dev/null 2>&1
  de "$e" run -d --name "redis-$e" "$REDIS_IMAGE" >/dev/null 2>&1
  sleep 15; up=$(footprint_mb "$e")
  de "$e" rm -f "pg-$e" "redis-$e" >/dev/null 2>&1
  sleep 25; after=$(footprint_mb "$e")
  # absolute footprint with the stack up, and MB reclaimed 25s after teardown (free-page reporting)
  echo "$up $((up-after))"
}

# ---- run ----------------------------------------------------------------------------------------
echo "== user-workflow head-to-head =="
echo "engines: ${ENGINES[*]}   rounds: $ROUNDS   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
setup_fixtures

# Pre-pull images + warm caches per engine (untimed) so the timed rounds measure the workload,
# not one-time downloads.
for e in "${ENGINES[@]}"; do
  echo "-- prepare $e --"
  for img in "$NODE_IMAGE" "$ALPINE_IMAGE" "$PG_IMAGE" "$REDIS_IMAGE"; do de "$e" pull -q "$img" >/dev/null 2>&1; done
  warm_npm "$e"; de "$e" build --no-cache -q -t "dorybench:$e" "$WORK/build" >/dev/null 2>&1
  hot_start "$e"
done

# Samples are accumulated to files (bash 3.2 has no associative arrays): $SAMP/<metric>-<engine>
SAMP="$WORK/samples"; rm -rf "$SAMP"; mkdir -p "$SAMP"

for r in $(seq 1 "$ROUNDS"); do
  for e in "${ENGINES[@]}"; do
    m_npm "$e"       >> "$SAMP/npm-$e"
    m_coldstart "$e" >> "$SAMP/cold-$e"
    m_hotreload "$e" >> "$SAMP/hot-$e"
    m_build "$e"     >> "$SAMP/build-$e"
    printf '  round %s/%s %-9s done\n' "$r" "$ROUNDS" "$e"
  done
done
for e in "${ENGINES[@]}"; do hot_stop "$e"; done

# memory stack (sequential — starting a stack in one engine perturbs system-wide memory)
for e in "${ENGINES[@]}"; do mem_stack "$e" > "$SAMP/mem-$e"; done

# ---- report -----------------------------------------------------------------------------------
line() { printf '%s\n' "--------------------------------------------------------------------------------"; }
echo; line; echo "RESULTS (median; cv% in parens; lower is better except reclaim)"; line
printf '%-24s' "metric"; for e in "${ENGINES[@]}"; do printf '%-18s' "$e"; done; echo
report_row() {
  local label="$1" unit="$2" key="$3" e med cv vals
  printf '%-24s' "$label"
  for e in "${ENGINES[@]}"; do
    vals="$(tr '\n' ' ' < "$SAMP/$key-$e" 2>/dev/null)"
    # shellcheck disable=SC2086
    med=$(median $vals); cv=$(cvpct $vals)
    printf '%-18s' "$(awk -v m="$med" -v c="$cv" -v u="$unit" 'BEGIN{printf "%.3g%s(%s%%)", m, u, c}')"
  done; echo
}
report_row "npm install (bind)"   "s"  npm
report_row "container cold-start"  "ms" cold
report_row "hot-reload latency"    "ms" hot
report_row "image build I/O"       "s"  build
printf '%-24s' "footprint w/stack(MB)"; for e in "${ENGINES[@]}"; do printf '%-18s' "$(awk '{print $1}' "$SAMP/mem-$e" 2>/dev/null)"; done; echo
printf '%-24s' "reclaimed 25s(MB)";     for e in "${ENGINES[@]}"; do printf '%-18s' "$(awk '{print $2}' "$SAMP/mem-$e" 2>/dev/null)"; done; echo
line
echo "notes: lower is better except reclaim (higher = more host RAM returned after the stack stops —"
echo "       dory's free-page reporting; VZ-backed engines cannot and stay ~0). hot-reload -1 = host"
echo "       edit not visible in the container within 5s (watcher-breaking). footprint = phys_footprint"
echo "       summed over each engine's process tree via footprint(1); cross-engine attribution is"
echo "       approximate (process-pattern based)."
