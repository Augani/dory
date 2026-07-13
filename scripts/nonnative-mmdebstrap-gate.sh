#!/bin/bash
# Exact OrbStack #2543 reproduction: mmdebstrap must bootstrap Debian during a linux/amd64
# BuildKit RUN on Apple Silicon without Rosetta's /bin/sh "Bad fd number" failure.
set -euo pipefail

SOCKET=""
DOCKER=""
BASE_IMAGE=""
WORKROOT="${TMPDIR:-/tmp}/dory-nonnative-mmdebstrap"
CONFIRM=""

usage() {
  cat <<EOF
Usage: scripts/nonnative-mmdebstrap-gate.sh [required options]

  --socket PATH       Exact isolated Dory Docker socket
  --docker PATH       Exact Docker CLI
  --base-image REF    Digest-pinned linux/amd64 Debian trixie image
  --workroot DIR      Evidence root (default: $WORKROOT)
  --confirm TOKEN     Must be ISOLATED-DORY-NONNATIVE-MMDEBSTRAP
  --help

The base image must be absent before the gate. The gate fresh-pulls it and builds OrbStack
#2543's reported apt/mmdebstrap commands without shell, seccomp, or sandbox workarounds. It then
proves the generated Debian rootfs tar is readable and complete, rechecks the Docker API, and
removes its base/build images and containers.
EOF
}

die() { echo "non-native mmdebstrap gate: $*" >&2; exit 2; }
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

[ "$CONFIRM" = ISOLATED-DORY-NONNATIVE-MMDEBSTRAP ] \
  || die "requires --confirm ISOLATED-DORY-NONNATIVE-MMDEBSTRAP"
[ -S "$SOCKET" ] || die "Dory socket is unavailable: $SOCKET"
[ -x "$DOCKER" ] || die "Docker CLI is not executable: $DOCKER"
printf '%s\n' "$BASE_IMAGE" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
  || die "--base-image must be digest-pinned"
for command in python3 shasum; do
  command -v "$command" >/dev/null || die "required command is missing: $command"
done

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
TAG="dory-mmdebstrap:${RUN_ID//[^a-zA-Z0-9]/}"
CONTAINER="dory-mmdebstrap-${RUN_ID//[^a-zA-Z0-9]/}"
HANDLER_CONTAINER="$CONTAINER-handler"
WORKDIR="$WORKROOT/$RUN_ID"
CONTEXT="$WORKDIR/context"
MANIFEST="$WORKDIR/manifest.txt"
mkdir -p "$CONTEXT"
BASE_OWNED=0
BUILD_ATTEMPTED=0

docker_e() { DOCKER_HOST="unix://$SOCKET" "$DOCKER" "$@"; }
cleanup() {
  set +e
  docker_e rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker_e rm -f "$HANDLER_CONTAINER" >/dev/null 2>&1 || true
  docker_e image rm -f "$TAG" >/dev/null 2>&1 || true
  if [ "$BASE_OWNED" -eq 1 ]; then
    docker_e image rm -f "$BASE_IMAGE" >/dev/null 2>&1 || true
  fi
  if [ "$BUILD_ATTEMPTED" -eq 1 ]; then
    docker_e builder prune --all --force >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

docker_e version > "$WORKDIR/docker-version-before.txt" \
  || die "Docker API is not ready"
docker_e info --format '{{.DefaultRuntime}}' > "$WORKDIR/default-runtime.txt" \
  || die "Docker runtime inventory is unavailable"
grep -qx dory-runc "$WORKDIR/default-runtime.txt" \
  || die "Dory's FEX-aware OCI runtime is not Docker's default runtime"
if docker_e image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
  die "Debian base image already exists; the gate requires a fresh isolated pull"
fi

docker_e pull --platform linux/amd64 "$BASE_IMAGE" \
  > "$WORKDIR/pull.out" 2> "$WORKDIR/pull.err" \
  || die "fresh linux/amd64 Debian trixie pull failed"
BASE_OWNED=1
docker_e image inspect "$BASE_IMAGE" > "$WORKDIR/base-image-inspect.json"
python3 - "$WORKDIR/base-image-inspect.json" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert isinstance(payload, list) and len(payload) == 1, "Debian image inspect is not singular"
image = payload[0]
assert image.get("Os") == "linux", "Debian fixture is not a Linux image"
assert image.get("Architecture") == "amd64", "Debian fixture is not linux/amd64"
PY

cat > "$CONTEXT/Dockerfile" <<EOF
FROM $BASE_IMAGE

RUN apt-get update && \\
    apt-get install -y --no-install-recommends wget ca-certificates mmdebstrap

# Bootstrap a minimal trixie rootfs from the public Debian mirror.
RUN mmdebstrap --variant=minbase trixie /tmp/rootfs.tar
EOF

BUILD_ATTEMPTED=1
DOCKER_BUILDKIT=1 docker_e build --no-cache --progress=plain --platform linux/amd64 \
  -t "$TAG" "$CONTEXT" > "$WORKDIR/build.out" 2> "$WORKDIR/build.err" \
  || die "linux/amd64 mmdebstrap build failed"
if grep -Eqi 'bad fd number|cat >&10 returned|hooklistener errored' \
    "$WORKDIR/build.out" "$WORKDIR/build.err"; then
  die "mmdebstrap build logged OrbStack #2543's shell descriptor failure"
fi

docker_e image inspect "$TAG" > "$WORKDIR/built-image-inspect.json"
python3 - "$WORKDIR/built-image-inspect.json" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert isinstance(payload, list) and len(payload) == 1, "built image inspect is not singular"
image = payload[0]
assert image.get("Os") == "linux", "built fixture is not a Linux image"
assert image.get("Architecture") == "amd64", "built fixture is not linux/amd64"
PY

docker_e run --rm --name "$HANDLER_CONTAINER" --privileged --platform linux/amd64 "$TAG" \
  sh -ec 'mkdir -p /proc/sys/fs/binfmt_misc; grep -qs " /proc/sys/fs/binfmt_misc " /proc/mounts || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc; grep -qx enabled /proc/sys/fs/binfmt_misc/FEX-x86_64; grep -qx "interpreter /usr/lib/dory/fex/FEX" /proc/sys/fs/binfmt_misc/FEX-x86_64; grep -qx "flags: POCF" /proc/sys/fs/binfmt_misc/FEX-x86_64' \
  > "$WORKDIR/fex-handler.out" 2> "$WORKDIR/fex-handler.err" \
  || die "FEX binfmt handler is unavailable or has unsafe flags"

docker_e run --name "$CONTAINER" --platform linux/amd64 --entrypoint sh "$TAG" -ec '
  test "$(uname -m)" = x86_64
  test "$FEX_ROOTFS" = /
  test "$FEX_NEEDSSECCOMP" = 1
  test "$FEX_APP_CONFIG_LOCATION" = /usr/lib/dory/fex
  test "$FEX_SERVERSOCKETPATH" = /run/dory-fex/FEXServer.Socket
  case "$PATH" in /usr/lib/dory/fex:*) ;; *) exit 1;; esac
  test -x /usr/lib/dory/fex/FEX
  test -x /usr/lib/dory/fex/FEXServer
  if touch /usr/lib/dory/fex/.dory-write-probe 2>/dev/null; then exit 1; fi
  runtime_mount="$(awk '$2 == "/run/dory-fex" && $3 == "tmpfs" { print $4; exit }' /proc/mounts)"
  test -n "$runtime_mount"
  case ",$runtime_mount," in *,nosuid,*) ;; *) exit 1;; esac
  case ",$runtime_mount," in *,nodev,*) ;; *) exit 1;; esac
  case ",$runtime_mount," in *,noexec,*) ;; *) exit 1;; esac
  test "$(stat -c %a /run/dory-fex)" = 1777
  test -S "$FEX_SERVERSOCKETPATH"
  fex_hash="$(sha256sum /usr/lib/dory/fex/FEX | awk "{print \$1}")"
  server_hash="$(sha256sum /usr/lib/dory/fex/FEXServer | awk "{print \$1}")"
  case "$fex_hash:$server_hash" in
    385c2495a46f00450ffa62e641552b7f18928aa18f3d0a8b621c526ccf79e009:9a4b098f004a5e9e1759ead38795f48bbc900e654d51e3bcf20d9921f00b2ef4) ;;
    *) exit 1;;
  esac
  test -s /tmp/rootfs.tar
  tar -tf /tmp/rootfs.tar | sed "s#^\\./##" > /tmp/rootfs.entries
  grep -qx etc/debian_version /tmp/rootfs.entries
  grep -Eq "^(bin/sh|usr/bin/dash|usr/bin/sh)$" /tmp/rootfs.entries
  debian_version="$(
    tar -xOf /tmp/rootfs.tar ./etc/debian_version 2>/dev/null \
      || tar -xOf /tmp/rootfs.tar etc/debian_version
  )"
  debian_version="$(printf "%s" "$debian_version" | tr -d "\r\n")"
  test -n "$debian_version"
  mmdebstrap_version="$(mmdebstrap --version)"
  echo "$mmdebstrap_version" | grep -Eq "^mmdebstrap [0-9]"
  echo "architecture=x86_64"
  echo "fex_sha256=$fex_hash"
  echo "fex_server_sha256=$server_hash"
  echo "mmdebstrap_version=$mmdebstrap_version"
  echo "debian_version=$debian_version"
  echo "rootfs_archive_bytes=$(wc -c < /tmp/rootfs.tar | tr -d " ")"
  echo "rootfs_archive_entries=$(wc -l < /tmp/rootfs.entries | tr -d " ")"
  echo "rootfs_archive_readable=PASS"
' > "$WORKDIR/run.out" 2> "$WORKDIR/run.err" \
  || die "generated linux/amd64 Debian rootfs archive verification failed"

grep -qx 'architecture=x86_64' "$WORKDIR/run.out" \
  || die "mmdebstrap fixture did not execute as x86_64"
grep -Eq '^mmdebstrap_version=mmdebstrap [0-9]' "$WORKDIR/run.out" \
  || die "mmdebstrap version output is missing"
grep -Eq '^debian_version=[^[:space:]]+' "$WORKDIR/run.out" \
  || die "bootstrapped Debian version is missing"
grep -Eq '^rootfs_archive_bytes=[1-9][0-9]+$' "$WORKDIR/run.out" \
  || die "bootstrapped rootfs archive size is invalid"
grep -Eq '^rootfs_archive_entries=[1-9][0-9]+$' "$WORKDIR/run.out" \
  || die "bootstrapped rootfs archive inventory is invalid"
grep -qx 'rootfs_archive_readable=PASS' "$WORKDIR/run.out" \
  || die "bootstrapped rootfs archive was not verified"

docker_e rm "$CONTAINER" > "$WORKDIR/container-delete.out"
docker_e version > "$WORKDIR/docker-version-after.txt" \
  || die "Docker API wedged after the mmdebstrap build"
docker_e image rm -f "$TAG" > "$WORKDIR/built-image-delete.out" \
  || die "built mmdebstrap fixture cleanup failed"
docker_e image rm -f "$BASE_IMAGE" > "$WORKDIR/base-image-delete.out" \
  || die "Debian base image cleanup failed"
BASE_OWNED=0
docker_e builder prune --all --force > "$WORKDIR/builder-prune.out" \
  || die "mmdebstrap BuildKit cache cleanup failed"
BUILD_ATTEMPTED=0
if docker_e image inspect "$TAG" >/dev/null 2>&1 \
   || docker_e image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
  die "mmdebstrap gate image survived cleanup"
fi

{
  echo "status=PASS"
  echo "run_id=$RUN_ID"
  echo "orbstack_issue=2543"
  echo "orbstack_issue_url=https://github.com/orbstack/orbstack/issues/2543"
  echo "base_image=$BASE_IMAGE"
  echo "platform=linux/amd64"
  echo "architecture=x86_64"
  echo "fresh_pull=PASS"
  echo "reported_dockerfile_commands=PASS"
  echo "mmdebstrap_minbase_trixie=PASS"
  echo "bad_fd_number_absent=PASS"
  echo "oci_default_runtime=dory-runc"
  echo "fex_handler=PASS"
  echo "fex_binfmt_flags=POCF"
  echo "fex_bundle_read_only=PASS"
  echo "fex_config_read_only=PASS"
  echo "fex_private_runtime=PASS"
  echo "fex_shared_server_socket=PASS"
  grep -E '^fex(_server)?_sha256=' "$WORKDIR/run.out"
  grep -E '^(mmdebstrap_version|debian_version|rootfs_archive_bytes|rootfs_archive_entries)=' \
    "$WORKDIR/run.out"
  echo "rootfs_archive_readable=PASS"
  echo "docker_api_after_build=PASS"
  echo "build_cache_cleanup=PASS"
  echo "owned_cleanup=PASS"
  echo "docker_cli_sha256=$(shasum -a 256 "$DOCKER" | awk '{print $1}')"
  echo "dockerfile_sha256=$(shasum -a 256 "$CONTEXT/Dockerfile" | awk '{print $1}')"
  echo "base_inspect_sha256=$(shasum -a 256 "$WORKDIR/base-image-inspect.json" | awk '{print $1}')"
  echo "build_output_sha256=$(shasum -a 256 "$WORKDIR/build.out" | awk '{print $1}')"
  echo "run_output_sha256=$(shasum -a 256 "$WORKDIR/run.out" | awk '{print $1}')"
  echo "completed_epoch=$(date +%s)"
} > "$MANIFEST"

trap - EXIT INT TERM
echo "non-native mmdebstrap gate: PASS ($MANIFEST)"
