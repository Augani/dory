#!/bin/bash
# Exact Apple container #1628 reproduction: Arch pacman must switch to its alpm sandbox user and
# install a package during a linux/amd64 BuildKit RUN without disabling the sandbox.
set -euo pipefail

SOCKET=""
DOCKER=""
BASE_IMAGE=""
WORKROOT="${TMPDIR:-/tmp}/dory-nonnative-arch-pacman"
CONFIRM=""

usage() {
  cat <<EOF
Usage: scripts/nonnative-arch-pacman-gate.sh [required options]

  --socket PATH       Exact isolated Dory Docker socket
  --docker PATH       Exact Docker CLI
  --base-image REF    Digest-pinned linux/amd64 Arch image
  --workroot DIR      Evidence root (default: $WORKROOT)
  --confirm TOKEN     Must be ISOLATED-DORY-NONNATIVE-ARCH-PACMAN
  --help

The base image must be absent before the gate. The gate fresh-pulls it, builds the competitor's
exact RUN pacman -Sy --noconfirm fzf without --disable-sandbox, runs the package, rechecks the
Docker API, and removes its base/build images and container.
EOF
}

die() { echo "non-native Arch pacman gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --base-image) need_value "$1" "$#"; BASE_IMAGE="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ "$CONFIRM" = ISOLATED-DORY-NONNATIVE-ARCH-PACMAN ] \
  || die "requires --confirm ISOLATED-DORY-NONNATIVE-ARCH-PACMAN"
[ -S "$SOCKET" ] || die "Dory socket is unavailable: $SOCKET"
[ -x "$DOCKER" ] || die "Docker CLI is not executable: $DOCKER"
printf '%s\n' "$BASE_IMAGE" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
  || die "--base-image must be digest-pinned"
for command in python3 shasum; do
  command -v "$command" >/dev/null || die "required command is missing: $command"
done

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
TAG="dory-arch-pacman:${RUN_ID//[^a-zA-Z0-9]/}"
CONTAINER="dory-arch-pacman-${RUN_ID//[^a-zA-Z0-9]/}"
HANDLER_CONTAINER="$CONTAINER-handler"
WORKDIR="$WORKROOT/$RUN_ID"
CONTEXT="$WORKDIR/context"
MANIFEST="$WORKDIR/manifest.txt"
mkdir -p "$CONTEXT"
BASE_OWNED=0

docker_e() { DOCKER_HOST="unix://$SOCKET" "$DOCKER" "$@"; }
cleanup() {
  set +e
  docker_e rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker_e rm -f "$HANDLER_CONTAINER" >/dev/null 2>&1 || true
  docker_e image rm -f "$TAG" >/dev/null 2>&1 || true
  if [ "$BASE_OWNED" -eq 1 ]; then
    docker_e image rm -f "$BASE_IMAGE" >/dev/null 2>&1 || true
  fi
  rm -rf "$CONTEXT"
}
trap cleanup EXIT INT TERM

docker_e version > "$WORKDIR/docker-version-before.txt" || die "Docker API is not ready"
docker_e info --format '{{.DefaultRuntime}}' > "$WORKDIR/default-runtime.txt" \
  || die "Docker runtime inventory is unavailable"
grep -qx dory-runc "$WORKDIR/default-runtime.txt" \
  || die "Dory's FEX-aware OCI runtime is not Docker's default runtime"
if docker_e image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
  die "Arch base image already exists; the gate requires a fresh isolated pull"
fi
docker_e pull --platform linux/amd64 "$BASE_IMAGE" \
  > "$WORKDIR/pull.out" 2> "$WORKDIR/pull.err" \
  || die "fresh linux/amd64 Arch pull failed"
BASE_OWNED=1
docker_e image inspect "$BASE_IMAGE" > "$WORKDIR/base-image-inspect.json"
python3 - "$WORKDIR/base-image-inspect.json" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert isinstance(payload, list) and len(payload) == 1, "Arch image inspect is not singular"
assert payload[0].get("Os") == "linux" and payload[0].get("Architecture") == "amd64", \
    "Arch fixture is not linux/amd64"
PY

cat > "$CONTEXT/Dockerfile" <<EOF
FROM $BASE_IMAGE
RUN pacman -Sy --noconfirm fzf
CMD ["fzf", "--version"]
EOF
DOCKER_BUILDKIT=1 docker_e build --progress=plain --platform linux/amd64 \
  -t "$TAG" "$CONTEXT" > "$WORKDIR/build.out" 2> "$WORKDIR/build.err" \
  || die "linux/amd64 Arch pacman sandbox build failed"
if grep -Eqi 'error restricting syscalls via seccomp|switching to sandbox user .* failed' \
    "$WORKDIR/build.out" "$WORKDIR/build.err"; then
    die "Arch pacman build logged the competitor's seccomp/sandbox failure"
fi
docker_e run --rm --name "$HANDLER_CONTAINER" --privileged --platform linux/amd64 "$TAG" \
  sh -ec 'mkdir -p /proc/sys/fs/binfmt_misc; grep -qs " /proc/sys/fs/binfmt_misc " /proc/mounts || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc; grep -qx enabled /proc/sys/fs/binfmt_misc/FEX-x86_64; grep -qx "interpreter /usr/lib/dory/fex/FEX" /proc/sys/fs/binfmt_misc/FEX-x86_64; grep -qx "flags: POCF" /proc/sys/fs/binfmt_misc/FEX-x86_64' \
  > "$WORKDIR/fex-handler.out" 2> "$WORKDIR/fex-handler.err" \
  || die "FEX binfmt handler is unavailable or has unsafe flags"
docker_e run --name "$CONTAINER" --platform linux/amd64 "$TAG" \
  sh -ec '
    test "$(uname -m)" = x86_64
    test "$FEX_ROOTFS" = /
    test "$FEX_NEEDSSECCOMP" = 1
    test "$FEX_APP_CONFIG_LOCATION" = /usr/lib/dory/fex
    test "$FEX_SERVERSOCKETPATH" = /run/dory-fex/FEXServer.Socket
    case "$PATH" in /usr/lib/dory/fex:*) ;; *) exit 1;; esac
    test -x /usr/lib/dory/fex/FEX
    test -x /usr/lib/dory/fex/FEXServer
    if touch /usr/lib/dory/fex/.dory-write-probe 2>/dev/null; then exit 1; fi
    runtime_mount="$(awk '\''$2 == "/run/dory-fex" && $3 == "tmpfs" { print $4; exit }'\'' /proc/mounts)"
    test -n "$runtime_mount"
    case ",$runtime_mount," in *,nosuid,*) ;; *) exit 1;; esac
    case ",$runtime_mount," in *,nodev,*) ;; *) exit 1;; esac
    case ",$runtime_mount," in *,noexec,*) ;; *) exit 1;; esac
    test "$(stat -c %a /run/dory-fex)" = 1777
    test -S "$FEX_SERVERSOCKETPATH"
    fex_hash="$(sha256sum /usr/lib/dory/fex/FEX | awk "{print \$1}")"
    server_hash="$(sha256sum /usr/lib/dory/fex/FEXServer | awk "{print \$1}")"
    case "$fex_hash:$server_hash" in
      b862d2a4358b102b125ae50da357b189a5d4710a3be830ef3280cba400c7099b:bbe8a34fc2ba4e606acd7e5b11d9b51da283835f40d2851e2ed39d35d28f2597) ;;
      *) exit 1;;
    esac
    echo "fex_sha256=$fex_hash"
    echo "fex_server_sha256=$server_hash"
    pacman -Q fzf
    fzf --version
  ' \
  > "$WORKDIR/run.out" 2> "$WORKDIR/run.err" \
  || die "installed linux/amd64 fzf did not execute"
grep -Eq '^fzf [0-9]' "$WORKDIR/run.out" \
  || die "pacman package inventory did not contain fzf"
grep -Eq '^[0-9]+[.][0-9]+' "$WORKDIR/run.out" \
  || die "fzf runtime version output is missing"
docker_e rm "$CONTAINER" > "$WORKDIR/container-delete.out"
docker_e version > "$WORKDIR/docker-version-after.txt" \
  || die "Docker API wedged after the Arch pacman build"
docker_e image rm -f "$TAG" > "$WORKDIR/built-image-delete.out" \
  || die "built Arch fixture cleanup failed"
docker_e image rm -f "$BASE_IMAGE" > "$WORKDIR/base-image-delete.out" \
  || die "Arch base image cleanup failed"
BASE_OWNED=0
if docker_e image inspect "$TAG" >/dev/null 2>&1 \
   || docker_e image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
  die "Arch pacman gate image survived cleanup"
fi
rm -rf "$CONTEXT"

{
  echo "status=PASS"
  echo "run_id=$RUN_ID"
  echo "base_image=$BASE_IMAGE"
  echo "platform=linux/amd64"
  echo "architecture=x86_64"
  echo "fresh_pull=PASS"
  echo "pacman_default_sandbox=PASS"
  echo "alpm_user_switch=PASS"
  echo "oci_default_runtime=dory-runc"
  echo "fex_handler=PASS"
  echo "fex_binfmt_flags=POCF"
  echo "fex_bundle_read_only=PASS"
  echo "fex_config_read_only=PASS"
  echo "fex_private_runtime=PASS"
  echo "fex_shared_server_socket=PASS"
  grep -E '^fex(_server)?_sha256=' "$WORKDIR/run.out"
  echo "fzf_inventory=PASS"
  echo "fzf_runtime=PASS"
  echo "docker_api_after_build=PASS"
  echo "owned_cleanup=PASS"
  echo "docker_cli_sha256=$(shasum -a 256 "$DOCKER" | awk '{print $1}')"
  echo "build_output_sha256=$(shasum -a 256 "$WORKDIR/build.out" | awk '{print $1}')"
  echo "run_output_sha256=$(shasum -a 256 "$WORKDIR/run.out" | awk '{print $1}')"
  echo "completed_epoch=$(date +%s)"
} > "$MANIFEST"

trap - EXIT INT TERM
echo "non-native Arch pacman gate: PASS ($MANIFEST)"
