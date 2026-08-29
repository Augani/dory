#!/bin/bash
# Reproduce OrbStack #2538 on Apple Silicon: Nix garbage collection in linux/amd64 must not fail
# with EPERM while reading process state. This gate owns a fresh digest-pinned image and container.
set -euo pipefail

SOCKET=""
DOCKER=""
IMAGE=""
WORKROOT="${TMPDIR:-/tmp}/dory-nonnative-nix-gc"
CONFIRM=""
SOURCE_COMMIT=""
RELEASE_CANDIDATE=0

usage() {
  cat <<EOF
Usage: scripts/nonnative-nix-gc-gate.sh [required options]

  --socket PATH       Exact isolated Dory Docker socket
  --docker PATH       Exact Docker CLI
  --image REF         Digest-pinned linux/amd64 Nix 2.34.7 image
  --workroot DIR      Evidence root (default: $WORKROOT)
  --confirm TOKEN     Must be ISOLATED-DORY-NONNATIVE-NIX-GC
  --source-commit SHA Exact 40-character source commit for release evidence
  --release-candidate Mark exact candidate evidence as release qualifying
  --help

The image must be absent before the gate. The gate performs a fresh linux/amd64 pull, proves
x86_64 and Nix 2.34.7, adds an unreachable store path, runs nix-collect-garbage --delete-old,
requires that exact path to disappear, checks Docker API liveness, and removes all owned state.
EOF
}

die() { echo "nonnative Nix GC gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --image) need_value "$1" "$#"; IMAGE="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    --source-commit) need_value "$1" "$#"; SOURCE_COMMIT="$2"; shift 2 ;;
    --release-candidate) RELEASE_CANDIDATE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ "$CONFIRM" = ISOLATED-DORY-NONNATIVE-NIX-GC ] \
  || die "requires --confirm ISOLATED-DORY-NONNATIVE-NIX-GC"
for command in id python3 shasum stat; do
  command -v "$command" >/dev/null || die "required command is missing: $command"
done
case "$SOCKET" in /*) ;; *) die "Dory socket must be an absolute path" ;; esac
[ -S "$SOCKET" ] && [ ! -L "$SOCKET" ] || die "Dory socket is unavailable or indirect: $SOCKET"
[ "$(stat -f %u "$SOCKET")" = "$(id -u)" ] || die "Dory socket is not owned by the release user"
case "$DOCKER" in /*) ;; *) die "Docker CLI must be an absolute path" ;; esac
[ -f "$DOCKER" ] && [ ! -L "$DOCKER" ] && [ -s "$DOCKER" ] && [ -x "$DOCKER" ] \
  || die "Docker CLI is unavailable or indirect: $DOCKER"
printf '%s\n' "$IMAGE" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
  || die "--image must be digest-pinned"
if [ -n "$SOURCE_COMMIT" ]; then
  printf '%s\n' "$SOURCE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' \
    || die "source commit must be a full lowercase Git SHA"
fi
if [ "$RELEASE_CANDIDATE" -eq 1 ]; then
  [ -n "$SOURCE_COMMIT" ] || die "release candidate evidence requires --source-commit"
fi
case "$WORKROOT" in /*) ;; *) die "workroot must be an absolute path" ;; esac
case "$WORKROOT" in /|"$HOME") die "unsafe workroot: $WORKROOT" ;; esac
[ ! -e "$WORKROOT" ] && [ ! -L "$WORKROOT" ] \
  || die "workroot already exists or is indirect: $WORKROOT"
mkdir "$WORKROOT"
WORKROOT="$(cd "$WORKROOT" && pwd -P)"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
CONTAINER="dory-nonnative-nix-gc-${RUN_ID//[^a-zA-Z0-9]/}"
WORKDIR="$WORKROOT/$RUN_ID"
MANIFEST="$WORKDIR/manifest.txt"
mkdir -p "$WORKDIR"
IMAGE_OWNED=0

docker_e() {
  env -u DOCKER_API_VERSION -u DOCKER_AUTH_CONFIG -u DOCKER_CERT_PATH \
    -u DOCKER_CONTEXT -u DOCKER_CUSTOM_HEADERS -u DOCKER_DEFAULT_PLATFORM \
    -u DOCKER_TLS -u DOCKER_TLS_VERIFY DOCKER_HOST="unix://$SOCKET" \
    "$DOCKER" "$@"
}
cleanup() {
  set +e
  docker_e rm -f "$CONTAINER" >/dev/null 2>&1 || true
  if [ "$IMAGE_OWNED" -eq 1 ]; then
    docker_e image rm -f "$IMAGE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

docker_e version > "$WORKDIR/docker-version-before.txt" \
  || die "Docker API is not ready"
if docker_e image inspect "$IMAGE" >/dev/null 2>&1; then
  die "Nix fixture already exists; the gate requires a fresh isolated pull"
fi
docker_e pull --platform linux/amd64 "$IMAGE" \
  > "$WORKDIR/pull.out" 2> "$WORKDIR/pull.err" \
  || die "fresh linux/amd64 Nix pull failed"
IMAGE_OWNED=1
docker_e image inspect "$IMAGE" > "$WORKDIR/image-inspect.json"
python3 - "$WORKDIR/image-inspect.json" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if not isinstance(payload, list) or len(payload) != 1:
    raise SystemExit("Nix image inspect is not singular")
image = payload[0]
if image.get("Os") != "linux":
    raise SystemExit("Nix fixture is not a Linux image")
if image.get("Architecture") != "amd64":
    raise SystemExit("Nix fixture is not linux/amd64")
PY
image_id="$(docker_e image inspect -f '{{.Id}}' "$IMAGE")"

set +e
docker_e run --name "$CONTAINER" --platform linux/amd64 --entrypoint sh "$IMAGE" -lc '
set -eu
[ "$(uname -m)" = x86_64 ]
version="$(nix --version)"
[ "$version" = "nix (Nix) 2.34.7" ]
printf "architecture=x86_64\nversion=%s\n" "$version"
printf dory-nix-gc-unreachable > /tmp/dory-nix-garbage
garbage="$(nix-store --add /tmp/dory-nix-garbage)"
[ -n "$garbage" ] && [ -e "$garbage" ]
printf "garbage_path=%s\n" "$garbage"
nix-collect-garbage --delete-old
[ ! -e "$garbage" ]
printf "gc_deleted_unreachable_path=PASS\n"
' > "$WORKDIR/run.out" 2> "$WORKDIR/run.err"
run_rc=$?
set -e
[ "$run_rc" -eq 0 ] || die "linux/amd64 Nix garbage collection failed (exit=$run_rc)"
grep -qx 'architecture=x86_64' "$WORKDIR/run.out" \
  || die "Nix fixture did not execute as x86_64"
grep -qx 'version=nix (Nix) 2.34.7' "$WORKDIR/run.out" \
  || die "Nix fixture version changed"
grep -Eq '^garbage_path=/nix/store/[a-z0-9]{32}-dory-nix-garbage$' "$WORKDIR/run.out" \
  || die "Nix gate did not retain the exact unreachable store path"
grep -qx 'gc_deleted_unreachable_path=PASS' "$WORKDIR/run.out" \
  || die "Nix GC did not delete the unreachable store path"

docker_e rm "$CONTAINER" > "$WORKDIR/container-delete.out"
docker_e version > "$WORKDIR/docker-version-after.txt" \
  || die "Docker API wedged after non-native Nix GC"
docker_e image rm -f "$IMAGE" > "$WORKDIR/image-delete.out" \
  || die "Nix fixture image cleanup failed"
IMAGE_OWNED=0
if docker_e image inspect "$IMAGE" >/dev/null 2>&1; then
  die "Nix fixture survived local cleanup"
fi

release_qualifying=false
[ "$RELEASE_CANDIDATE" -eq 0 ] || release_qualifying=true
{
  echo "status=PASS"
  echo "run_id=$RUN_ID"
  echo "image=$IMAGE"
  echo "image_id=$image_id"
  echo "source_commit=$SOURCE_COMMIT"
  echo "platform=linux/amd64"
  echo "architecture=x86_64"
  echo "nix_version=2.34.7"
  echo "fresh_pull=PASS"
  echo "unreachable_store_path_created=PASS"
  echo "nix_collect_garbage_delete_old=PASS"
  echo "unreachable_store_path_deleted=PASS"
  echo "docker_api_after_gc=PASS"
  echo "owned_cleanup=PASS"
  echo "docker_cli_sha256=$(shasum -a 256 "$DOCKER" | awk '{print $1}')"
  echo "run_output_sha256=$(shasum -a 256 "$WORKDIR/run.out" | awk '{print $1}')"
  echo "release_qualifying=$release_qualifying"
  echo "completed_epoch=$(date +%s)"
} > "$MANIFEST"

trap - EXIT INT TERM
echo "nonnative Nix GC gate: PASS ($MANIFEST)"
