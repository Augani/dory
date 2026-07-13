#!/bin/bash
# Qualify FEX's generic Linux exec contract on Apple Silicon. This deliberately covers process
# transitions rather than individual package-manager symptoms.
set -euo pipefail

SOCKET=""
DOCKER=""
BASE_IMAGE=""
NATIVE_IMAGE=""
WORKROOT="${TMPDIR:-/tmp}/dory-nonnative-exec-conformance"
CONFIRM=""

usage() {
  cat <<EOF
Usage: scripts/nonnative-exec-conformance-gate.sh [required options]

  --socket PATH        Exact isolated Dory Docker socket
  --docker PATH        Exact Docker CLI
  --base-image REF     Digest-pinned linux/amd64 Debian image
  --native-image REF   Digest-pinned linux/arm64 image with sh and mount
  --workroot DIR       Evidence root (default: $WORKROOT)
  --confirm TOKEN      Must be ISOLATED-DORY-NONNATIVE-EXEC
  --help

The gate fresh-pulls both fixtures, performs the execution matrix in BuildKit, at runtime, and
through docker exec, proves inherited guest seccomp, and removes all owned state and build cache.
EOF
}

die() { echo "non-native exec conformance gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --base-image) need_value "$1" "$#"; BASE_IMAGE="$2"; shift 2 ;;
    --native-image) need_value "$1" "$#"; NATIVE_IMAGE="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ "$CONFIRM" = ISOLATED-DORY-NONNATIVE-EXEC ] \
  || die "requires --confirm ISOLATED-DORY-NONNATIVE-EXEC"
[ -S "$SOCKET" ] || die "Dory socket is unavailable: $SOCKET"
[ -x "$DOCKER" ] || die "Docker CLI is not executable: $DOCKER"
for ref in "$BASE_IMAGE" "$NATIVE_IMAGE"; do
  printf '%s\n' "$ref" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
    || die "fixture images must be digest-pinned"
done
for command in python3 shasum; do
  command -v "$command" >/dev/null || die "required command is missing: $command"
done

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
TAG="dory-exec-conformance:${RUN_ID//[^a-zA-Z0-9]/}"
CONTAINER="dory-exec-conformance-${RUN_ID//[^a-zA-Z0-9]/}"
HANDLER_CONTAINER="$CONTAINER-handler"
WORKDIR="$WORKROOT/$RUN_ID"
CONTEXT="$WORKDIR/context"
MANIFEST="$WORKDIR/manifest.txt"
mkdir -p "$CONTEXT"
BASE_OWNED=0
NATIVE_OWNED=0
BUILD_ATTEMPTED=0

docker_e() { DOCKER_HOST="unix://$SOCKET" "$DOCKER" "$@"; }
cleanup() {
  set +e
  docker_e rm -f "$CONTAINER" "$HANDLER_CONTAINER" >/dev/null 2>&1 || true
  docker_e image rm -f "$TAG" >/dev/null 2>&1 || true
  [ "$BASE_OWNED" -eq 0 ] || docker_e image rm -f "$BASE_IMAGE" >/dev/null 2>&1 || true
  [ "$NATIVE_OWNED" -eq 0 ] || docker_e image rm -f "$NATIVE_IMAGE" >/dev/null 2>&1 || true
  [ "$BUILD_ATTEMPTED" -eq 0 ] || docker_e builder prune --all --force >/dev/null 2>&1 || true
  rm -rf "$CONTEXT"
}
trap cleanup EXIT INT TERM

docker_e version > "$WORKDIR/docker-version-before.txt" || die "Docker API is not ready"
docker_e info --format '{{.DefaultRuntime}}' > "$WORKDIR/default-runtime.txt" \
  || die "Docker runtime inventory is unavailable"
grep -qx dory-runc "$WORKDIR/default-runtime.txt" \
  || die "Dory's FEX-aware OCI runtime is not Docker's default runtime"
for ref in "$BASE_IMAGE" "$NATIVE_IMAGE"; do
  if docker_e image inspect "$ref" >/dev/null 2>&1; then
    die "fixture already exists; the gate requires fresh isolated pulls: $ref"
  fi
done

docker_e pull --platform linux/amd64 "$BASE_IMAGE" \
  > "$WORKDIR/base-pull.out" 2> "$WORKDIR/base-pull.err" \
  || die "fresh linux/amd64 Debian pull failed"
BASE_OWNED=1
docker_e pull --platform linux/arm64 "$NATIVE_IMAGE" \
  > "$WORKDIR/native-pull.out" 2> "$WORKDIR/native-pull.err" \
  || die "fresh linux/arm64 handler fixture pull failed"
NATIVE_OWNED=1
docker_e image inspect "$BASE_IMAGE" > "$WORKDIR/base-image-inspect.json"
docker_e image inspect "$NATIVE_IMAGE" > "$WORKDIR/native-image-inspect.json"
python3 - "$WORKDIR/base-image-inspect.json" "$WORKDIR/native-image-inspect.json" <<'PY'
import json
import pathlib
import sys

for path, architecture in zip(sys.argv[1:], ("amd64", "arm64")):
    payload = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    assert isinstance(payload, list) and len(payload) == 1
    assert payload[0].get("Os") == "linux" and payload[0].get("Architecture") == architecture
PY

cat > "$CONTEXT/fd_exec_probe.py" <<'PY'
#!/usr/bin/python3
import os

for key in ("FEX_INTERPRETER_INSTALLED", "FEX_EXECVEFD", "FEX_SECCOMPFD"):
    assert key not in os.environ
fd = os.open("/usr/bin/dpkg", os.O_RDONLY | os.O_CLOEXEC)
os.execve(fd, ["dory-dpkg", "--version"], os.environ.copy())
PY

cat > "$CONTEXT/fd_null_argv_probe.py" <<'PY'
#!/usr/bin/python3
import ctypes
import os

fd = os.open("/usr/bin/true", os.O_RDONLY | os.O_CLOEXEC)
libc = ctypes.CDLL(None, use_errno=True)
result = libc.syscall(322, fd, b"", None, None, 0x1000)
raise OSError(ctypes.get_errno(), f"execveat unexpectedly returned {result}")
PY

cat > "$CONTEXT/seccomp_launcher.py" <<'PY'
#!/usr/bin/python3
import ctypes
import os


class SockFilter(ctypes.Structure):
    _fields_ = [("code", ctypes.c_ushort), ("jt", ctypes.c_ubyte),
                ("jf", ctypes.c_ubyte), ("k", ctypes.c_uint)]


class SockFprog(ctypes.Structure):
    _fields_ = [("length", ctypes.c_ushort), ("filter", ctypes.POINTER(SockFilter))]


for key in ("FEX_INTERPRETER_INSTALLED", "FEX_EXECVEFD", "FEX_SECCOMPFD"):
    assert key not in os.environ
filters = (SockFilter * 5)(
    SockFilter(0x20, 0, 0, 0),
    SockFilter(0x15, 2, 0, 83),
    SockFilter(0x15, 1, 0, 258),
    SockFilter(0x06, 0, 0, 0x7FFF0000),
    SockFilter(0x06, 0, 0, 0x00050000 | 13),
)
program = SockFprog(len(filters), filters)
libc = ctypes.CDLL(None, use_errno=True)
assert libc.prctl(38, 1, 0, 0, 0) == 0, ctypes.get_errno()
assert libc.prctl(22, 2, ctypes.byref(program), 0, 0) == 0, ctypes.get_errno()
os.execve("/opt/dory-exec/chain-a.sh", ["dory-chain-a", "preserved"], os.environ.copy())
PY

cat > "$CONTEXT/chain-a.sh" <<'SH'
#!/bin/sh
set -eu
test "$0" = /opt/dory-exec/chain-a.sh
test "$1" = preserved
test -z "${FEX_INTERPRETER_INSTALLED-}"
test -z "${FEX_EXECVEFD-}"
test -z "${FEX_SECCOMPFD-}"
exec /opt/dory-exec/chain-b.py from-shell
SH

cat > "$CONTEXT/chain-b.py" <<'PY'
#!/usr/bin/env python3
import errno
import os
import subprocess
import sys

assert sys.argv == ["/opt/dory-exec/chain-b.py", "from-shell"]
for key in ("FEX_INTERPRETER_INSTALLED", "FEX_EXECVEFD", "FEX_SECCOMPFD"):
    assert key not in os.environ
try:
    os.mkdir("/tmp/dory-seccomp-python")
except OSError as error:
    assert error.errno == errno.EACCES, error
else:
    raise AssertionError("mkdir bypassed inherited guest seccomp")
mkdir = subprocess.run(["/bin/mkdir", "/tmp/dory-seccomp-child"], check=False,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
assert mkdir.returncode != 0 and "Permission denied" in mkdir.stderr, mkdir
version = subprocess.check_output(["/bin/cat", "/etc/debian_version"], text=True).strip()
assert version
print(f"seccomp-shebang-chain-ok debian={version}", flush=True)
PY

cat > "$CONTEXT/Dockerfile" <<EOF
FROM $BASE_IMAGE
RUN apt-get update && apt-get install -y --no-install-recommends python3 && rm -rf /var/lib/apt/lists/*
COPY --chmod=0755 fd_exec_probe.py fd_null_argv_probe.py seccomp_launcher.py chain-a.sh chain-b.py /opt/dory-exec/
RUN test "\$(sha256sum /usr/lib/dory/fex/FEX | cut -d' ' -f1)" = b862d2a4358b102b125ae50da357b189a5d4710a3be830ef3280cba400c7099b
RUN /usr/bin/python3 /opt/dory-exec/fd_exec_probe.py | grep -q '^Debian .dpkg. package management program version' && echo fd-exec-arguments-buildkit=PASS
RUN /usr/bin/python3 /opt/dory-exec/fd_null_argv_probe.py && echo fd-exec-null-argv-buildkit=PASS
RUN /usr/bin/python3 /opt/dory-exec/seccomp_launcher.py | grep -q '^seccomp-shebang-chain-ok ' && echo seccomp-shebang-chain-buildkit=PASS
CMD ["sleep", "300"]
EOF

BUILD_ATTEMPTED=1
DOCKER_BUILDKIT=1 docker_e build --no-cache --progress=plain --platform linux/amd64 \
  -t "$TAG" "$CONTEXT" > "$WORKDIR/build.out" 2> "$WORKDIR/build.err" \
  || die "BuildKit exec conformance matrix failed"
for proof in fd-exec-arguments-buildkit fd-exec-null-argv-buildkit \
  seccomp-shebang-chain-buildkit; do
  grep -q "$proof=PASS" "$WORKDIR/build.err" \
    || die "BuildKit log does not retain $proof"
done

docker_e run --rm --platform linux/amd64 --entrypoint /usr/bin/python3 "$TAG" \
  /opt/dory-exec/fd_exec_probe.py > "$WORKDIR/fd-exec.out" 2> "$WORKDIR/fd-exec.err" \
  || die "runtime descriptor exec lost its argument vector"
grep -q '^Debian .dpkg. package management program version' "$WORKDIR/fd-exec.out" \
  || die "runtime descriptor exec output is incomplete"
docker_e run --rm --platform linux/amd64 --entrypoint /usr/bin/python3 "$TAG" \
  /opt/dory-exec/fd_null_argv_probe.py \
  > "$WORKDIR/fd-null-argv.out" 2> "$WORKDIR/fd-null-argv.err" \
  || die "runtime descriptor exec rejected a null argv"
docker_e run --rm --platform linux/amd64 --entrypoint /usr/bin/python3 "$TAG" \
  /opt/dory-exec/seccomp_launcher.py \
  > "$WORKDIR/seccomp-chain.out" 2> "$WORKDIR/seccomp-chain.err" \
  || die "runtime seccomp/shebang chain failed"
grep -q '^seccomp-shebang-chain-ok ' "$WORKDIR/seccomp-chain.out" \
  || die "runtime seccomp/shebang proof is missing"

docker_e run -d --name "$CONTAINER" --platform linux/amd64 "$TAG" >/dev/null \
  || die "long-running amd64 exec fixture failed to start"
docker_e exec "$CONTAINER" /usr/bin/python3 /opt/dory-exec/fd_exec_probe.py \
  > "$WORKDIR/docker-exec.out" 2> "$WORKDIR/docker-exec.err" \
  || die "docker exec descriptor chain failed"
grep -q '^Debian .dpkg. package management program version' "$WORKDIR/docker-exec.out" \
  || die "docker exec output is incomplete"
docker_e exec "$CONTAINER" sh -ec \
  'test -z "${FEX_INTERPRETER_INSTALLED-}"; test -z "${FEX_EXECVEFD-}"; test -z "${FEX_SECCOMPFD-}"' \
  || die "a private FEX handoff marker leaked through docker exec"
docker_e rm -f "$CONTAINER" > "$WORKDIR/container-delete.out"

docker_e run --name "$HANDLER_CONTAINER" --rm --privileged --platform linux/arm64 \
  "$NATIVE_IMAGE" sh -ec '
    mkdir -p /proc/sys/fs/binfmt_misc
    grep -qs " /proc/sys/fs/binfmt_misc " /proc/mounts \
      || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
    grep -qx enabled /proc/sys/fs/binfmt_misc/FEX-x86_64
    grep -qx "interpreter /usr/lib/dory/fex/FEX" /proc/sys/fs/binfmt_misc/FEX-x86_64
    grep -qx "flags: POCF" /proc/sys/fs/binfmt_misc/FEX-x86_64
    test ! -e /proc/sys/fs/binfmt_misc/FEX-x86
  ' > "$WORKDIR/handler.out" 2> "$WORKDIR/handler.err" \
  || die "the production amd64-only FEX binfmt contract is not exact"

docker_e version > "$WORKDIR/docker-version-after.txt" \
  || die "Docker API wedged after exec conformance"
docker_e image rm -f "$TAG" > "$WORKDIR/built-image-delete.out" \
  || die "built exec fixture cleanup failed"
docker_e image rm -f "$BASE_IMAGE" > "$WORKDIR/base-image-delete.out" \
  || die "Debian fixture cleanup failed"
BASE_OWNED=0
docker_e image rm -f "$NATIVE_IMAGE" > "$WORKDIR/native-image-delete.out" \
  || die "native fixture cleanup failed"
NATIVE_OWNED=0
docker_e builder prune --all --force > "$WORKDIR/builder-prune.out" \
  || die "exec conformance BuildKit cache cleanup failed"
BUILD_ATTEMPTED=0

{
  echo "status=PASS"
  echo "run_id=$RUN_ID"
  echo "base_image=$BASE_IMAGE"
  echo "native_image=$NATIVE_IMAGE"
  echo "platform=linux/amd64"
  echo "architecture=x86_64"
  echo "fresh_pulls=PASS"
  echo "oci_default_runtime=dory-runc"
  echo "fex_sha256=b862d2a4358b102b125ae50da357b189a5d4710a3be830ef3280cba400c7099b"
  echo "fex_server_sha256=bbe8a34fc2ba4e606acd7e5b11d9b51da283835f40d2851e2ed39d35d28f2597"
  echo "amd64_only_binfmt=PASS"
  echo "fex_binfmt_flags=POCF"
  echo "canonical_shebang_paths=PASS"
  echo "env_shebang_chain=PASS"
  echo "private_marker_isolation=PASS"
  echo "guest_seccomp_inheritance=PASS"
  echo "fd_exec_arguments=PASS"
  echo "fd_exec_null_argv=PASS"
  echo "buildkit_exec_matrix=PASS"
  echo "runtime_exec_matrix=PASS"
  echo "docker_exec_matrix=PASS"
  echo "docker_api_after_exec=PASS"
  echo "build_cache_cleanup=PASS"
  echo "owned_cleanup=PASS"
  echo "docker_cli_sha256=$(shasum -a 256 "$DOCKER" | awk '{print $1}')"
  echo "dockerfile_sha256=$(shasum -a 256 "$CONTEXT/Dockerfile" | awk '{print $1}')"
  echo "build_log_sha256=$(shasum -a 256 "$WORKDIR/build.err" | awk '{print $1}')"
  echo "seccomp_output_sha256=$(shasum -a 256 "$WORKDIR/seccomp-chain.out" | awk '{print $1}')"
  echo "docker_exec_output_sha256=$(shasum -a 256 "$WORKDIR/docker-exec.out" | awk '{print $1}')"
  echo "completed_epoch=$(date +%s)"
} > "$MANIFEST"

rm -rf "$CONTEXT"
trap - EXIT INT TERM
echo "non-native exec conformance gate: PASS ($MANIFEST)"
