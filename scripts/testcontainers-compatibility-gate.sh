#!/bin/bash
# End-to-end Node Testcontainers + Ryuk qualification against an isolated Dory engine.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/testcontainers-compatibility-gate.sh --socket PATH --docker PATH --version VERSION [options]

Required:
  --socket PATH       Disposable Dory Docker socket
  --docker PATH       Exact bundled Docker CLI
  --version VERSION   Exact npm `testcontainers` version to install and record

Options:
  --image REF         Workload image (default alpine:3.20)
  --workroot DIR      Evidence root (default /tmp/dory-testcontainers)
  --node PATH         Node executable (default: node from PATH)
  --npm PATH          npm executable (default: npm from PATH)
  --keep              Keep the npm project/evidence directory
  -h, --help

The engine must contain zero pre-existing containers. The gate may pull the requested workload and
Testcontainers' pinned Ryuk image. It removes only containers created on that isolated engine.
EOF
}

die() { echo "testcontainers gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
SOCKET=""
DOCKER=""
VERSION=""
IMAGE="alpine:3.20"
WORKROOT="${TMPDIR:-/tmp}/dory-testcontainers"
NODE="$(command -v node 2>/dev/null || true)"
NPM="$(command -v npm 2>/dev/null || true)"
KEEP=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --version) need_value "$1" "$#"; VERSION="$2"; shift 2 ;;
    --image) need_value "$1" "$#"; IMAGE="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --node) need_value "$1" "$#"; NODE="$2"; shift 2 ;;
    --npm) need_value "$1" "$#"; NPM="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "$SOCKET" ] || die "--socket is required"
[ -n "$DOCKER" ] || die "--docker is required"
[ -n "$VERSION" ] || die "--version is required"
[ -S "$SOCKET" ] || die "socket is unavailable: $SOCKET"
[ -x "$DOCKER" ] || die "Docker CLI is not executable: $DOCKER"
[ -n "$NODE" ] && [ -x "$NODE" ] || die "Node is unavailable"
[ -n "$NPM" ] && [ -x "$NPM" ] || die "npm is unavailable"

docker_e() { DOCKER_HOST="unix://$SOCKET" "$DOCKER" "$@"; }
docker_e version >/dev/null || die "Docker API is not ready"
[ -z "$(docker_e ps -aq)" ] || die "gate requires an isolated engine with zero pre-existing containers"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RUN_ROOT="$WORKROOT/$RUN_ID"
PROJECT="$RUN_ROOT/project"
EVIDENCE="$RUN_ROOT/evidence"
mkdir -p "$PROJECT" "$EVIDENCE"

cleanup() {
  set +e
  local id
  docker_e ps -a --no-trunc >"$EVIDENCE/containers-before-cleanup.txt" 2>&1 || true
  docker_e info >"$EVIDENCE/docker-info-before-cleanup.txt" 2>&1 || true
  docker_e ps -aq 2>/dev/null | while IFS= read -r id; do
    [ -n "$id" ] || continue
    docker_e inspect "$id" >"$EVIDENCE/container-$id-inspect.json" 2>&1 || true
    docker_e logs "$id" >"$EVIDENCE/container-$id.log" 2>&1 || true
  done
  # The zero-preexisting-container guard makes every container on this socket gate-owned, including
  # a workload interrupted before Testcontainers could apply/remove its normal session labels.
  docker_e ps -aq 2>/dev/null | while IFS= read -r id; do
    [ -n "$id" ] && docker_e rm -f -v "$id" >/dev/null 2>&1 || true
  done
  if [ "$KEEP" -ne 1 ]; then rm -rf "$PROJECT" "$RUN_ROOT/npm-cache"; fi
}
trap cleanup EXIT INT TERM

cat >"$PROJECT/package.json" <<EOF
{"private":true,"dependencies":{"testcontainers":"$VERSION"}}
EOF
cat >"$PROJECT/gate.cjs" <<'EOF'
const http = require("node:http");
const { GenericContainer, Wait } = require("testcontainers");

async function get(host, port) {
  return await new Promise((resolve, reject) => {
    const request = http.get({ host, port, path: "/", timeout: 5000 }, (response) => {
      let body = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => { body += chunk; });
      response.on("end", () => resolve({ status: response.statusCode, body }));
    });
    request.on("timeout", () => request.destroy(new Error("HTTP timeout")));
    request.on("error", reject);
  });
}

(async () => {
  const image = process.env.DORY_TESTCONTAINERS_IMAGE;
  const marker = process.env.DORY_TESTCONTAINERS_MARKER;
  const startupTimeout = Number(process.env.DORY_TESTCONTAINERS_TIMEOUT_MS || "60000");
  const container = await new GenericContainer(image)
    .withCommand(["sh", "-c", `printf '%s\\n' '#!/bin/sh' "awk 'length() <= 1 { exit }' >/dev/null" 'printf "HTTP/1.1 200 OK\\r\\nContent-Length: ${marker.length}\\r\\nConnection: close\\r\\n\\r\\n${marker}"' > /tmp/dory-http; chmod 755 /tmp/dory-http; exec nc -lk -p 8080 -e /tmp/dory-http`])
    .withExposedPorts(8080)
    .withWaitStrategy(Wait.forHttp("/", 8080).forStatusCode(200))
    .withStartupTimeout(startupTimeout)
    .start();
  try {
    const response = await get(container.getHost(), container.getMappedPort(8080));
    if (response.status !== 200 || response.body !== marker) {
      throw new Error(`wrong HTTP response: ${response.status} ${JSON.stringify(response.body)}`);
    }
    process.stdout.write(JSON.stringify({
      status: "PASS",
      host: container.getHost(),
      mappedPort: container.getMappedPort(8080),
      marker,
    }) + "\n");
  } finally {
    await container.stop();
  }
})().catch((error) => {
  console.error(error && error.stack ? error.stack : String(error));
  process.exit(1);
});
EOF

{
  echo "run_id=$RUN_ID"
  echo "socket=$SOCKET"
  echo "docker=$DOCKER"
  echo "node=$($NODE --version)"
  echo "npm=$($NPM --version)"
  echo "testcontainers=$VERSION"
  echo "image=$IMAGE"
  echo "started_epoch=$(date +%s)"
} >"$EVIDENCE/manifest.txt"

( cd "$PROJECT" && npm_config_cache="$RUN_ROOT/npm-cache" "$NPM" install --ignore-scripts --no-audit --no-fund ) \
  >"$EVIDENCE/npm-install.out" 2>"$EVIDENCE/npm-install.err"
cp "$PROJECT/package-lock.json" "$EVIDENCE/package-lock.json"
MARKER="dory-testcontainers-$RUN_ID"
( cd "$PROJECT" && \
  DOCKER_HOST="unix://$SOCKET" \
  TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock \
  TESTCONTAINERS_HOST_OVERRIDE=127.0.0.1 \
  DORY_TESTCONTAINERS_IMAGE="$IMAGE" \
  DORY_TESTCONTAINERS_MARKER="$MARKER" \
  "$NODE" gate.cjs ) >"$EVIDENCE/gate.out" 2>"$EVIDENCE/gate.err"

cleanup
leftovers="$(docker_e ps -aq 2>/dev/null || true)"
[ -z "$leftovers" ] || die "Testcontainers/Ryuk cleanup left containers: $leftovers"
echo "completed_epoch=$(date +%s)" >>"$EVIDENCE/manifest.txt"
echo "status=PASS" >>"$EVIDENCE/manifest.txt"
trap - EXIT INT TERM
echo "Testcontainers compatibility gate PASS; evidence: $EVIDENCE"
