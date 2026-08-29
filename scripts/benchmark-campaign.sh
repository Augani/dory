#!/bin/bash
# Full competitive benchmark campaign: for each engine, INSTALL -> START (per VM profile) -> MEASURE
# -> STOP -> UNINSTALL + PURGE, so every engine is measured in isolation with nothing else installed.
# Dory is measured last against a signed Release Dory.app.
#
# The actual measurement is delegated to scripts/benchmark-compare.sh (same probe for every engine).
# This orchestrator only owns the lifecycle: clean install, VM sizing, socket wait, and complete purge.
#
# Two VM-fairness profiles run per engine:
#   pinned  -- every VM capped to the same vCPU/RAM ceiling (CAMPAIGN_PINNED_CPUS/_MEM_GB), so the
#              comparison isolates engine overhead, not who ships a bigger VM. Note that OrbStack and
#              Dory reclaim RAM dynamically, so "pinned" is a ceiling; Colima/Podman reserve it.
#   default -- each engine exactly as it installs, i.e. the out-of-the-box experience.
#
# SAFETY: engines are installed and PURGED one at a time (only one competitor VM exists at any moment),
# which keeps disk and memory bounded on a 16 GB / limited-disk Mac. A live campaign is disabled unless
# the operator supplies the exact destructive-purge confirmation token. --dry-run never creates a result
# directory and never invokes an engine, package manager, Docker API, app, or removal command.
#
# Usage:
#   scripts/benchmark-campaign.sh --dory-app release-build/export-arm64/Dory.app \
#     --confirm-destructive-purge DELETE-SELECTED-ENGINE-DATA
#   scripts/benchmark-campaign.sh --engines colima,podman --profiles default --dry-run
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPARE="$ROOT/scripts/benchmark-compare.sh"

ENGINES="${CAMPAIGN_ENGINES:-orbstack,colima,podman,dory}"
PROFILES="${CAMPAIGN_PROFILES:-pinned,default}"
PINNED_CPUS="${CAMPAIGN_PINNED_CPUS:-6}"
PINNED_MEM_GB="${CAMPAIGN_PINNED_MEM_GB:-6}"
DEFAULT_LABEL_CPUS="${CAMPAIGN_DEFAULT_CPUS:-}"   # informational only; empty means engine default
RUNS="${CAMPAIGN_RUNS:-2}"
MEMORY_COUNT="${CAMPAIGN_MEMORY_COUNT:-3}"
METRICS="${CAMPAIGN_METRICS:-memory,build}"
DORY_APP="${CAMPAIGN_DORY_APP:-$ROOT/release-build/export-arm64/Dory.app}"
DRY_RUN="${DRY_RUN:-0}"
SOCKET_WAIT="${CAMPAIGN_SOCKET_WAIT:-120}"
CAMPAIGN_DIR_OVERRIDE="${CAMPAIGN_WORKDIR:-}"
PURGE_CONFIRMATION=""
PURGE_TOKEN="DELETE-SELECTED-ENGINE-DATA"

usage() {
  cat <<EOF
Usage:
  scripts/benchmark-campaign.sh [options]

Options:
  --engines CSV          Comma-separated subset of: orbstack,colima,podman,dory
                         (default: $ENGINES)
  --profiles CSV         Comma-separated subset of: pinned,default (default: $PROFILES)
  --dory-app PATH        Signed Release Dory.app used for Dory measurements
  --metrics CSV          Metrics passed to benchmark-compare: memory,cpu,build,network,fs
                         (default: $METRICS)
  --pinned-cpus N        CPU ceiling for the pinned profile (default: $PINNED_CPUS)
  --pinned-memory-gb N   RAM ceiling in GiB for the pinned profile (default: $PINNED_MEM_GB)
  --runs N               Timed repetitions per metric (default: $RUNS)
  --memory-count N       Idle containers for the memory metric (default: $MEMORY_COUNT)
  --socket-wait SEC      Engine socket deadline (default: $SOCKET_WAIT)
  --work DIR             Exact result directory (must not already exist for a live run)
  --dry-run              Validate and print the complete lifecycle plan without mutations
  --confirm-destructive-purge $PURGE_TOKEN
                         Required for every live run. Selected competitors are installed,
                         stopped, uninstalled, and their VM/application data is permanently deleted.
  -h, --help             Show this help without creating files or invoking engine commands

Without --dry-run or the exact confirmation token above, the campaign exits before creating its
result directory or invoking any state-changing command.
EOF
}

die() { printf 'benchmark-campaign: %s\n' "$*" >&2; exit 2; }

require_value() {
  [ "$2" -ge 2 ] || die "$1 requires a value"
  case "$3" in --*) die "$1 requires a value" ;; esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --engines) require_value "$1" "$#" "${2:-}"; ENGINES="$2"; shift 2 ;;
    --profiles) require_value "$1" "$#" "${2:-}"; PROFILES="$2"; shift 2 ;;
    --dory-app) require_value "$1" "$#" "${2:-}"; DORY_APP="$2"; shift 2 ;;
    --metrics) require_value "$1" "$#" "${2:-}"; METRICS="$2"; shift 2 ;;
    --pinned-cpus) require_value "$1" "$#" "${2:-}"; PINNED_CPUS="$2"; shift 2 ;;
    --pinned-memory-gb) require_value "$1" "$#" "${2:-}"; PINNED_MEM_GB="$2"; shift 2 ;;
    --runs) require_value "$1" "$#" "${2:-}"; RUNS="$2"; shift 2 ;;
    --memory-count) require_value "$1" "$#" "${2:-}"; MEMORY_COUNT="$2"; shift 2 ;;
    --socket-wait) require_value "$1" "$#" "${2:-}"; SOCKET_WAIT="$2"; shift 2 ;;
    --work) require_value "$1" "$#" "${2:-}"; CAMPAIGN_DIR_OVERRIDE="$2"; shift 2 ;;
    --confirm-destructive-purge)
      require_value "$1" "$#" "${2:-}"
      PURGE_CONFIRMATION="$2"
      shift 2
      ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

positive_integer() {
  case "$2" in ''|*[!0-9]*) die "$1 must be a positive integer" ;; esac
  [ "$2" -gt 0 ] || die "$1 must be a positive integer"
}

bounded_integer() {
  positive_integer "$1" "$2"
  [ "${#2}" -le 9 ] || die "$1 must be at most $3"
  [ "$2" -le "$3" ] || die "$1 must be at most $3"
}

validate_csv() {
  local label="$1" csv="$2" allowed="$3" value seen values old_ifs
  [ -n "$csv" ] || die "$label must contain at least one value"
  case "$csv" in *[[:space:]]*) die "$label must not contain whitespace" ;; esac
  case ",$csv," in *',,'*) die "$label contains an empty value" ;; esac
  old_ifs="$IFS"
  IFS=','
  read -r -a values <<< "$csv"
  IFS="$old_ifs"
  [ "${#values[@]}" -gt 0 ] || die "$label must contain at least one value"
  seen=','
  for value in "${values[@]}"; do
    [ -n "$value" ] || die "$label contains an empty value"
    case ",$allowed," in *",$value,"*) ;; *) die "unsupported $label value: $value" ;; esac
    case "$seen" in *",$value,"*) die "duplicate $label value: $value" ;; esac
    seen="$seen$value,"
  done
}

validate_csv engines "$ENGINES" 'orbstack,colima,podman,dory'
validate_csv profiles "$PROFILES" 'pinned,default'
validate_csv metrics "$METRICS" 'memory,cpu,build,network,fs'
bounded_integer pinned-cpus "$PINNED_CPUS" 256
bounded_integer pinned-memory-gb "$PINNED_MEM_GB" 1024
bounded_integer runs "$RUNS" 100
bounded_integer memory-count "$MEMORY_COUNT" 1000
bounded_integer socket-wait "$SOCKET_WAIT" 3600
if [ -n "$DEFAULT_LABEL_CPUS" ]; then bounded_integer default-cpus "$DEFAULT_LABEL_CPUS" 256; fi
case "$DRY_RUN" in 0|1) ;; *) die 'DRY_RUN must be 0 or 1' ;; esac

if [ -n "$PURGE_CONFIRMATION" ] && [ "$PURGE_CONFIRMATION" != "$PURGE_TOKEN" ]; then
  die "confirmation token must be exactly: $PURGE_TOKEN"
fi
if [ "$DRY_RUN" != 1 ] && [ "$PURGE_CONFIRMATION" != "$PURGE_TOKEN" ]; then
  die "live execution is disabled; use --dry-run or type --confirm-destructive-purge $PURGE_TOKEN"
fi

[ -n "${HOME:-}" ] || die 'HOME must name the user home directory'
case "$HOME" in /*) ;; *) die 'HOME must be an absolute path' ;; esac
[ -d "$HOME" ] || die "HOME is not a directory: $HOME"
HOME_REAL="$(cd "$HOME" 2>/dev/null && pwd -P)" || die "HOME cannot be resolved: $HOME"
[ "$HOME_REAL" != / ] || die 'HOME must not resolve to the filesystem root'

case "$DORY_APP" in
  /*) ;;
  *) DORY_APP="$PWD/$DORY_APP" ;;
esac
case "$DORY_APP" in *$'\n'*|*$'\r'*) die '--dory-app must not contain line breaks' ;; esac
case "$DORY_APP" in */Dory.app) ;; *) die '--dory-app must name a Dory.app bundle' ;; esac

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
if [ -n "$CAMPAIGN_DIR_OVERRIDE" ]; then
  CAMPAIGN_DIR="$CAMPAIGN_DIR_OVERRIDE"
else
  CAMPAIGN_DIR="$HOME/.dory-benchmark/campaign-$RUN_ID"
fi
case "$CAMPAIGN_DIR" in
  /*) ;;
  *) die '--work/CAMPAIGN_WORKDIR must be an absolute path' ;;
esac
case "$CAMPAIGN_DIR" in *$'\n'*|*$'\r'*) die 'campaign result directory must not contain line breaks' ;; esac
case "$CAMPAIGN_DIR" in /|'') die 'campaign result directory must not be the filesystem root' ;; esac

case ",$ENGINES," in
  *,dory,*)
    if [ "$DRY_RUN" != 1 ]; then
      [ -d "$DORY_APP" ] || die "Dory release app not found at $DORY_APP"
      [ -x "$DORY_APP/Contents/MacOS/Dory" ] || die "Dory app executable is missing at $DORY_APP/Contents/MacOS/Dory"
      codesign --verify --deep --strict "$DORY_APP" >/dev/null 2>&1 || \
        die "Dory app failed strict code-signature verification: $DORY_APP"
    fi
    ;;
esac
[ -x "$COMPARE" ] || die "benchmark probe is not executable: $COMPARE"

assert_mutation_authorized() {
  [ "$DRY_RUN" = 1 ] && return 0
  [ "$PURGE_CONFIRMATION" = "$PURGE_TOKEN" ] || die 'internal safety check refused an unauthorized mutation'
}

CAMPAIGN_LOG="$CAMPAIGN_DIR/campaign.log"
CAMPAIGN_TSV="$CAMPAIGN_DIR/campaign-results.tsv"

[ ! -e "$CAMPAIGN_DIR" ] || die "campaign result directory already exists: $CAMPAIGN_DIR"
if [ "$DRY_RUN" = 1 ]; then
  printf 'engine\tprofile\tresult\tresult_dir\tdetail\n'
else
  assert_mutation_authorized
  mkdir -p "$CAMPAIGN_DIR" || die "could not create campaign result directory: $CAMPAIGN_DIR"
  printf 'engine\tprofile\tresult\tresult_dir\tdetail\n' > "$CAMPAIGN_TSV"
fi

log()  {
  if [ "$DRY_RUN" = 1 ]; then
    printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2
  else
    printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$CAMPAIGN_LOG" >&2
  fi
}
run()  { log "+ $*"; [ "$DRY_RUN" = "1" ] && return 0; assert_mutation_authorized; "$@"; }
brewq() { run brew "$@"; }

disk_free_gb() { df -g / | awk 'NR==2 { print $4 }'; }

record() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" "${5:-}"
  else
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" "${5:-}" >> "$CAMPAIGN_TSV"
  fi
  log "RESULT $1/$2: $3 ${5:-}"
}

pinned_mem_mib() { echo $(( PINNED_MEM_GB * 1024 )); }

# Wait until $1 is a live docker socket answering `version`, up to SOCKET_WAIT seconds.
wait_docker_sock() {
  local sock="$1" waited=0
  [ "$DRY_RUN" = "1" ] && return 0
  while [ "$waited" -lt "$SOCKET_WAIT" ]; do
    [ -S "$sock" ] && docker -H "unix://$sock" version >/dev/null 2>&1 && return 0
    sleep 2; waited=$((waited + 2))
  done
  return 1
}

measure() {
  local engine="$1" profile="$2" sockenv="$3" sock="$4" extra_env="${5:-}"
  local out="$CAMPAIGN_DIR/$engine-$profile"
  local jobs="$PINNED_CPUS"
  [ "$profile" = "default" ] && jobs="8"
  log "measuring $engine [$profile] -> $out"
  if [ "$DRY_RUN" = "1" ]; then
    log "+ (dry-run) BENCH_WORKDIR=$out $sockenv=$sock benchmark-compare --engines $engine --metrics $METRICS"
    record "$engine" "$profile" "DRY" "$out" "dry-run"
    return 0
  fi
  assert_mutation_authorized
  mkdir -p "$out"
  local dory_app_args=()
  [ "$engine" = "dory" ] && dory_app_args=(--dory-app "$DORY_APP")
  # shellcheck disable=SC2086 -- extra_env is an internal, intentionally word-split env assignment list.
  if env "$sockenv=$sock" $extra_env BENCH_WORKDIR="$out" BENCH_BUILD_JOBS="$jobs" \
       METRICS="$METRICS" BENCH_RUNS="$RUNS" BENCH_MEMORY_COUNT="$MEMORY_COUNT" \
       "$COMPARE" --engines "$engine" --metrics "$METRICS" "${dory_app_args[@]}" \
       >"$out/compare.log" 2>&1; then
    record "$engine" "$profile" "OK" "$out" "$(grep -hE 'median=|delta' "$out"/*/status.tsv 2>/dev/null | tr '\n' ';' | cut -c1-200)"
  else
    record "$engine" "$profile" "MEASURE_FAILED" "$out" "see compare.log"
  fi
}

# ---- OrbStack ------------------------------------------------------------------------------------
install_orbstack() { brewq install --cask orbstack; }
start_orbstack() {
  local profile="$1"
  if [ "$profile" = "pinned" ]; then
    run orb config set cpu "$PINNED_CPUS" 2>/dev/null || log "note: orb config set cpu unsupported; OrbStack default CPU"
    run orb config set memory_mib "$(pinned_mem_mib)" 2>/dev/null || log "note: orb config set memory_mib unsupported; OrbStack manages memory dynamically"
  fi
  run orb start 2>/dev/null || run open -a OrbStack
  wait_docker_sock "$HOME/.orbstack/run/docker.sock"
}
stop_orbstack() { run orb stop 2>/dev/null || true; }
purge_orbstack() {
  assert_mutation_authorized
  run orb stop 2>/dev/null || true
  run orb delete-data -y 2>/dev/null || true
  run osascript -e 'quit app "OrbStack"' 2>/dev/null || true
  brewq uninstall --cask --zap orbstack 2>/dev/null || brewq uninstall --cask orbstack 2>/dev/null || true
  run rm -rf "$HOME/.orbstack" "$HOME/Library/Application Support/OrbStack" \
      "$HOME/Library/Caches/dev.orbstack.OrbStack" "$HOME/Library/Group Containers/HUAQ24HBR6.dev.orbstack" 2>/dev/null || true
}

# ---- Colima --------------------------------------------------------------------------------------
install_colima() { brewq install colima; }
start_colima() {
  local profile="$1"
  if [ "$profile" = "pinned" ]; then
    run colima start --cpu "$PINNED_CPUS" --memory "$PINNED_MEM_GB" --disk 20
  else
    run colima start
  fi
  wait_docker_sock "$HOME/.colima/default/docker.sock"
}
stop_colima() { run colima stop 2>/dev/null || true; }
purge_colima() {
  assert_mutation_authorized
  run colima delete -f 2>/dev/null || true
  brewq uninstall colima 2>/dev/null || true
  run rm -rf "$HOME/.colima" "$HOME/.lima/colima" 2>/dev/null || true
}

# ---- Podman --------------------------------------------------------------------------------------
install_podman() { brewq install podman; }
start_podman() {
  local profile="$1"
  run podman machine rm -f podman-machine-default 2>/dev/null || true
  if [ "$profile" = "pinned" ]; then
    run podman machine init --cpus "$PINNED_CPUS" --memory "$(pinned_mem_mib)" --disk-size 20
  else
    run podman machine init
  fi
  run podman machine start
  if [ "$DRY_RUN" != "1" ]; then
    PODMAN_SOCK="$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null)"
    export PODMAN_SOCK
    log "podman socket: $PODMAN_SOCK"
    wait_docker_sock "$PODMAN_SOCK"
  fi
}
stop_podman() { run podman machine stop 2>/dev/null || true; }
purge_podman() {
  assert_mutation_authorized
  run podman machine stop 2>/dev/null || true
  run podman machine rm -f 2>/dev/null || true
  brewq uninstall podman 2>/dev/null || true
  run rm -rf "$HOME/.local/share/containers" "$HOME/.config/containers" 2>/dev/null || true
}

# ---- Dory (signed Release app) -------------------------------------------------------------------
install_dory() {
  log "using signed Release Dory.app at $DORY_APP"
}
start_dory() {
  local profile="$1"
  # Dory reclaims RAM dynamically (free-page reporting); the pinned profile sets a ceiling via env
  # consumed by the launch agent. If the app auto-sizes, this is a no-op and is footnoted.
  if [ "$profile" = "pinned" ]; then
    export DORYD_CPUS="$PINNED_CPUS" DORYD_MEMORY_MB="$(pinned_mem_mib)"
  else
    unset DORYD_CPUS DORYD_MEMORY_MB 2>/dev/null || true
  fi
  # prepare_dory_release_app inside benchmark-compare opens the app and waits for the socket.
  return 0
}
stop_dory() { run osascript -e 'quit app "Dory"' 2>/dev/null || true; run pkill -f 'dory-hv|doryd' 2>/dev/null || true; }
purge_dory() { assert_mutation_authorized; :; }  # do not uninstall the user's Dory; it is the product under test

engine_defined() { type "install_$1" >/dev/null 2>&1; }

run_engine() {
  local engine="$1" profile sockenv sock
  if ! engine_defined "$engine"; then
    record "$engine" "-" "UNKNOWN_ENGINE" "" "no recipe"
    return
  fi
  case "$engine" in
    orbstack) sockenv="ORBSTACK_SOCK"; sock="$HOME/.orbstack/run/docker.sock" ;;
    colima)   sockenv="COLIMA_SOCK";   sock="$HOME/.colima/default/docker.sock" ;;
    podman)   sockenv="PODMAN_SOCK";   sock="" ;;
    dory)     sockenv="DORY_SOCK";     sock="$HOME/.dory/dory.sock" ;;
  esac

  log "===== ENGINE $engine (disk free $(disk_free_gb)G) ====="
  if ! "install_$engine"; then
    record "$engine" "-" "INSTALL_FAILED" "" "install recipe returned non-zero"
    "purge_$engine" 2>/dev/null || true
    return
  fi

  local OLD_IFS="$IFS" profiles
  IFS=','
  read -r -a profiles <<< "$PROFILES"
  IFS="$OLD_IFS"
  for profile in "${profiles[@]}"; do
    if ! "start_$engine" "$profile"; then
      record "$engine" "$profile" "START_FAILED" "" "start/socket-wait failed"
      "stop_$engine" 2>/dev/null || true
      continue
    fi
    [ "$engine" = "podman" ] && sock="${PODMAN_SOCK:-}"
    measure "$engine" "$profile" "$sockenv" "$sock"
    "stop_$engine" 2>/dev/null || true
  done

  log "purging $engine ..."
  assert_mutation_authorized
  "purge_$engine" 2>/dev/null || true
  log "disk free after $engine purge: $(disk_free_gb)G"
}

log "campaign $RUN_ID engines=$ENGINES profiles=$PROFILES pinned=${PINNED_CPUS}cpu/${PINNED_MEM_GB}GB runs=$RUNS"
log "results dir: $CAMPAIGN_DIR"
[ "$DRY_RUN" = "1" ] && log "DRY RUN -- no installs, starts, measurements, files, or purge commands are executed"

OLD_IFS="$IFS"
IFS=','
read -r -a CAMPAIGN_ENGINE_LIST <<< "$ENGINES"
IFS="$OLD_IFS"
for engine in "${CAMPAIGN_ENGINE_LIST[@]}"; do
  run_engine "$engine"
done

log "===== CAMPAIGN COMPLETE ====="
if [ "$DRY_RUN" != 1 ]; then
  column -t -s "$(printf '\t')" "$CAMPAIGN_TSV" 2>/dev/null | tee -a "$CAMPAIGN_LOG" || cat "$CAMPAIGN_TSV"
fi
log "raw results under: $CAMPAIGN_DIR"
