#!/bin/bash
# Runs Node Testcontainers and its real Ryuk reaper against an explicitly empty Dory engine.
set -euo pipefail

SOCKET=""
DOCKER=""
DEFAULT_VERSION="12.0.4"
DEFAULT_PACKAGE_INTEGRITY="sha512-QIR/8xF1+F/26cIM+9B4yyxNTbKJxAv3hygZyhPRgZ8Q2AhlPZjDdpXRuk16V37X4bgJRI3hXFhoEICMBA7Adg=="
VERSION="${DORY_RELEASE_TESTCONTAINERS_VERSION:-$DEFAULT_VERSION}"
PACKAGE_INTEGRITY="${DORY_RELEASE_TESTCONTAINERS_INTEGRITY:-}"
IMAGE=""
RYUK_IMAGE="${DORY_RELEASE_TESTCONTAINERS_RYUK_IMAGE:-testcontainers/ryuk:0.14.0@sha256:7c1a8a9a47c780ed0f983770a662f80deb115d95cce3e2daa3d12115b8cd28f0}"
WORKROOT=""
NODE="${DORY_RELEASE_NODE_BIN:-$(command -v node 2>/dev/null || true)}"
NPM="${DORY_RELEASE_NPM_BIN:-$(command -v npm 2>/dev/null || true)}"
CONFIRM=""

usage() {
  cat <<'EOF'
Usage: scripts/testcontainers-compatibility-gate.sh [required options] [options]

Required:
  --socket PATH       Unix socket for an already-running disposable Dory engine
  --docker PATH       Exact Docker CLI from the candidate runtime
  --image REF         Digest-pinned workload fixture already present in Dory
  --workroot DIR      New evidence directory owned by this gate
  --confirm TOKEN     Must be ISOLATED-ENGINE-TESTCONTAINERS

Options:
  --version VERSION   Exact npm testcontainers version (default: 12.0.4)
  --npm-integrity SRI Expected sha512- npm integrity (required for a non-default version)
  --ryuk-image REF    Digest-pinned Ryuk fixture already present in Dory
  --node PATH         Exact Node executable used by the harness
  --npm PATH          Exact npm executable used by the harness

The gate verifies the canonical npm tarball and SHA-512 integrity, runs an HTTP workload through
Testcontainers, proves that the real Ryuk container uses the guest-local Docker socket, and returns
the disposable engine to its exact empty container/volume/custom-network baseline. It never uses a
user's default Docker socket and never pulls either container image.
EOF
}

die() { echo "testcontainers gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --version) need_value "$1" "$#"; VERSION="$2"; shift 2 ;;
    --npm-integrity) need_value "$1" "$#"; PACKAGE_INTEGRITY="$2"; shift 2 ;;
    --image) need_value "$1" "$#"; IMAGE="$2"; shift 2 ;;
    --ryuk-image) need_value "$1" "$#"; RYUK_IMAGE="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --node) need_value "$1" "$#"; NODE="$2"; shift 2 ;;
    --npm) need_value "$1" "$#"; NPM="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

# This acknowledgement must fail before the gate looks at a socket, tool, registry, or workroot.
[ "$CONFIRM" = ISOLATED-ENGINE-TESTCONTAINERS ] \
  || die "requires --confirm ISOLATED-ENGINE-TESTCONTAINERS"
[ -S "$SOCKET" ] || die "socket is unavailable: $SOCKET"
[ "$(stat -f %u "$SOCKET")" = "$(id -u)" ] \
  || die "socket is not owned by the release user"
case "$DOCKER" in /*) ;; *) die "Docker CLI must be an absolute path" ;; esac
[ -f "$DOCKER" ] && [ ! -L "$DOCKER" ] && [ -x "$DOCKER" ] \
  || die "Docker CLI is unavailable or indirect: $DOCKER"
printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$' \
  || die "--version must be an exact npm semver"
if [ -z "$PACKAGE_INTEGRITY" ]; then
  [ "$VERSION" = "$DEFAULT_VERSION" ] \
    || die "--npm-integrity is required when --version differs from $DEFAULT_VERSION"
  PACKAGE_INTEGRITY="$DEFAULT_PACKAGE_INTEGRITY"
fi
for exact_image in "$IMAGE" "$RYUK_IMAGE"; do
  printf '%s\n' "$exact_image" \
    | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[0-9a-f]{64}$' \
    || die "workload and Ryuk images must be exact digest references"
done
case "$WORKROOT" in /*) ;; *) die "--workroot must be absolute" ;; esac
case "$WORKROOT" in /|"$HOME"|"$(pwd)") die "unsafe --workroot: $WORKROOT" ;; esac
[ ! -e "$WORKROOT" ] && [ ! -L "$WORKROOT" ] \
  || die "workroot already exists or is indirect: $WORKROOT"
for command in curl python3 shasum; do
  command -v "$command" >/dev/null || die "missing required command: $command"
done

resolve_executable() {
  python3 - "$1" <<'PY'
import os
import sys

path = os.path.realpath(sys.argv[1])
if not os.path.isabs(path) or not os.path.isfile(path) or not os.access(path, os.X_OK):
    raise SystemExit(1)
print(path)
PY
}
NODE="$(resolve_executable "$NODE")" || die "Node is unavailable or indirect"
NPM="$(resolve_executable "$NPM")" || die "npm is unavailable or indirect"

mkdir -p "$WORKROOT/evidence" "$WORKROOT/project" "$WORKROOT/download"
WORKROOT="$(cd "$WORKROOT" && pwd)"
PROJECT="$WORKROOT/project"
EVIDENCE="$WORKROOT/evidence"
DOWNLOAD="$WORKROOT/download"
STATE="$EVIDENCE/runtime-state.json"
RESULT="$EVIDENCE/result.json"
export DOCKER_HOST="unix://$SOCKET"
unset DOCKER_CONTEXT
docker_e() { "$DOCKER" "$@"; }
docker_e version > "$EVIDENCE/docker-version.txt" || die "Docker API is not ready"
docker_e image inspect "$IMAGE" > "$EVIDENCE/workload-image.json" 2>&1 \
  || die "required offline workload image is missing: $IMAGE"
docker_e image inspect "$RYUK_IMAGE" > "$EVIDENCE/ryuk-image.json" 2>&1 \
  || die "required offline Ryuk image is missing: $RYUK_IMAGE"

custom_network_ids() {
  docker_e network ls --filter type=custom --format '{{.ID}}' | sed '/^$/d'
}
object_counts() {
  printf 'containers=%s\n' "$(docker_e ps -aq | sed '/^$/d' | wc -l | tr -d ' ')"
  printf 'volumes=%s\n' "$(docker_e volume ls -q | sed '/^$/d' | wc -l | tr -d ' ')"
  printf 'custom_networks=%s\n' "$(custom_network_ids | wc -l | tr -d ' ')"
}
object_counts > "$EVIDENCE/baseline.txt"
grep -qx 'containers=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing containers"
grep -qx 'volumes=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing named volumes"
grep -qx 'custom_networks=0' "$EVIDENCE/baseline.txt" \
  || die "engine has pre-existing custom networks"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
owned_container_ids() {
  if [ -s "$STATE" ]; then
    python3 - "$STATE" <<'PY' 2>/dev/null || true
import json
import re
import sys

try:
    state = json.load(open(sys.argv[1], encoding="utf-8"))
except (OSError, ValueError):
    raise SystemExit(0)
for key in ("workloadContainerId", "ryukContainerId"):
    value = state.get(key)
    if isinstance(value, str) and re.fullmatch(r"[0-9a-f]{12,64}", value):
        print(value)
PY
  fi
  docker_e ps -aq --filter "label=dory.release.testcontainers.run=$RUN_ID" 2>/dev/null || true
  # This label is enabled only for this explicitly empty test engine and handles a signal in the
  # tiny interval between Ryuk creation and publication of runtime-state.json.
  docker_e ps -aq --filter 'label=TESTCONTAINERS_RYUK_TEST_LABEL=true' 2>/dev/null || true
}
cleanup_owned() {
  local ids
  ids="$(owned_container_ids | sed '/^$/d' | sort -u)"
  [ -z "$ids" ] || docker_e rm -f -v $ids > "$EVIDENCE/container-cleanup.log" 2>&1 || true
}
cleanup() {
  set +e
  cleanup_owned
  rm -rf "$WORKROOT/.npm-cache" "$DOWNLOAD"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"$NPM" view --json "testcontainers@$VERSION" version dist.integrity dist.tarball \
  > "$EVIDENCE/npm-package.json"
python3 - "$EVIDENCE/npm-package.json" "$VERSION" "$PACKAGE_INTEGRITY" <<'PY'
import base64
import json
import sys
import urllib.parse

with open(sys.argv[1], encoding="utf-8") as handle:
    package = json.load(handle)
expected_keys = {"version", "dist.integrity", "dist.tarball"}
if not isinstance(package, dict) or set(package) != expected_keys:
    raise SystemExit("Testcontainers npm package metadata has an unexpected shape")
if package["version"] != sys.argv[2]:
    raise SystemExit("Testcontainers npm registry returned a different version")
integrity = package["dist.integrity"]
if not isinstance(integrity, str) or not integrity.startswith("sha512-"):
    raise SystemExit("Testcontainers npm package has no SHA-512 integrity")
try:
    digest = base64.b64decode(integrity.removeprefix("sha512-"), validate=True)
except ValueError as error:
    raise SystemExit(f"Testcontainers npm integrity is invalid: {error}")
if len(digest) != 64:
    raise SystemExit("Testcontainers npm integrity is not SHA-512")
if integrity != sys.argv[3]:
    raise SystemExit("Testcontainers npm integrity differs from the pinned release value")
url = urllib.parse.urlparse(package["dist.tarball"])
expected_path = f"/testcontainers/-/testcontainers-{sys.argv[2]}.tgz"
if url.scheme != "https" or url.netloc != "registry.npmjs.org" or url.path != expected_path \
        or url.params or url.query or url.fragment:
    raise SystemExit("Testcontainers npm tarball URL is not canonical")
PY
PACKAGE_URL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["dist.tarball"])' "$EVIDENCE/npm-package.json")"
curl -fsSL --retry 3 --connect-timeout 15 --max-time 180 \
  "$PACKAGE_URL" -o "$DOWNLOAD/testcontainers.tgz"
python3 - "$DOWNLOAD/testcontainers.tgz" "$PACKAGE_INTEGRITY" <<'PY'
import base64
import hashlib
import sys

expected = base64.b64decode(sys.argv[2].removeprefix("sha512-"), validate=True)
digest = hashlib.sha512()
with open(sys.argv[1], "rb") as handle:
    while chunk := handle.read(1024 * 1024):
        digest.update(chunk)
if digest.digest() != expected:
    raise SystemExit("downloaded Testcontainers tarball failed its SHA-512 integrity check")
PY

cat > "$PROJECT/package.json" <<'JSON'
{"private":true}
JSON
(cd "$PROJECT" && \
  NPM_CONFIG_CACHE="$WORKROOT/.npm-cache" "$NPM" install \
    --ignore-scripts --no-audit --no-fund "$DOWNLOAD/testcontainers.tgz") \
    > "$EVIDENCE/npm-install.out" 2> "$EVIDENCE/npm-install.err"
"$NODE" - "$PROJECT/node_modules/testcontainers/package.json" "$VERSION" <<'JS'
const fs = require("node:fs");
const actual = JSON.parse(fs.readFileSync(process.argv[2], "utf8")).version;
if (actual !== process.argv[3]) {
  throw new Error(`installed Testcontainers version ${actual} differs from ${process.argv[3]}`);
}
JS
cp "$PROJECT/package-lock.json" "$EVIDENCE/package-lock.json"

cat > "$PROJECT/gate.cjs" <<'JS'
const fs = require("node:fs");
const http = require("node:http");
const {
  GenericContainer,
  Wait,
  getContainerRuntimeClient,
  getReaper,
} = require("testcontainers");

function fail(message) {
  throw new Error(message);
}

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
  const ryukImage = process.env.RYUK_CONTAINER_IMAGE;
  const marker = process.env.DORY_TESTCONTAINERS_MARKER;
  const runId = process.env.DORY_TESTCONTAINERS_RUN_ID;
  const statePath = process.env.DORY_TESTCONTAINERS_STATE;
  const resultPath = process.env.DORY_TESTCONTAINERS_RESULT;
  const startupTimeout = Number(process.env.DORY_TESTCONTAINERS_TIMEOUT_MS || "60000");
  const runtime = await getContainerRuntimeClient();
  const reaper = await getReaper(runtime);
  const reaperHandle = runtime.container.getById(reaper.containerId);
  const reaperInspect = await runtime.container.inspect(reaperHandle);
  if (reaperInspect.Config.Image !== ryukImage) fail("Ryuk did not use the exact requested image");
  if (reaperInspect.Config.Labels["org.testcontainers.ryuk"] !== "true") {
    fail("Ryuk identity label is missing");
  }
  if (reaperInspect.Config.Labels["org.testcontainers.session-id"] !== reaper.sessionId) {
    fail("Ryuk session label is not exact");
  }
  const socketMount = reaperInspect.Mounts.find((mount) => mount.Destination === "/var/run/docker.sock");
  if (!socketMount || socketMount.Type !== "bind" || socketMount.Source !== "/var/run/docker.sock") {
    fail("Ryuk did not receive the guest-local Docker socket bind");
  }
  const state = {
    ryukContainerId: reaper.containerId,
    ryukSessionId: reaper.sessionId,
    workloadContainerId: null,
  };
  fs.writeFileSync(statePath, JSON.stringify(state) + "\n", { mode: 0o600 });

  const responseText = `HTTP/1.1 200 OK\r\nContent-Length: ${marker.length}\r\nConnection: close\r\n\r\n${marker}`;
  const command = `while true; do printf '%s' '${responseText}' | nc -l -p 8080; done`;
  const container = await new GenericContainer(image)
    .withCommand(["sh", "-c", command])
    .withLabels({ "dory.release.testcontainers.run": runId })
    .withPullPolicy({ shouldPull: () => false })
    .withExposedPorts(8080)
    .withWaitStrategy(Wait.forHttp("/", 8080).forStatusCode(200))
    .withStartupTimeout(startupTimeout)
    .start();
  state.workloadContainerId = container.getId();
  fs.writeFileSync(statePath, JSON.stringify(state) + "\n", { mode: 0o600 });
  try {
    const workloadInspect = await runtime.container.inspect(runtime.container.getById(container.getId()));
    if (workloadInspect.Config.Image !== image) fail("workload did not use the exact requested image");
    if (workloadInspect.Config.Labels["dory.release.testcontainers.run"] !== runId) {
      fail("workload ownership label is missing");
    }
    if (workloadInspect.Config.Labels["org.testcontainers.session-id"] !== reaper.sessionId) {
      fail("workload is not bound to the exact Ryuk session");
    }
    const response = await get(container.getHost(), container.getMappedPort(8080));
    if (response.status !== 200 || response.body !== marker) {
      fail(`wrong HTTP response: ${response.status} ${JSON.stringify(response.body)}`);
    }
    fs.writeFileSync(resultPath, JSON.stringify({
      status: "PASS",
      marker,
      workloadImage: workloadInspect.Config.Image,
      ryukImage: reaperInspect.Config.Image,
      ryukSessionId: reaper.sessionId,
      host: container.getHost(),
      mappedPort: container.getMappedPort(8080),
    }) + "\n", { mode: 0o600 });
  } finally {
    await container.stop();
  }
})().catch((error) => {
  console.error(error && error.stack ? error.stack : String(error));
  process.exit(1);
});
JS

MARKER="dory-testcontainers-$RUN_ID"
(cd "$PROJECT" && \
  DOCKER_HOST="unix://$SOCKET" \
  TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock \
  TESTCONTAINERS_HOST_OVERRIDE=127.0.0.1 \
  TESTCONTAINERS_RYUK_DISABLED=false \
  TESTCONTAINERS_RYUK_TEST_LABEL=true \
  RYUK_CONTAINER_IMAGE="$RYUK_IMAGE" \
  DORY_TESTCONTAINERS_IMAGE="$IMAGE" \
  DORY_TESTCONTAINERS_MARKER="$MARKER" \
  DORY_TESTCONTAINERS_RUN_ID="$RUN_ID" \
  DORY_TESTCONTAINERS_STATE="$STATE" \
  DORY_TESTCONTAINERS_RESULT="$RESULT" \
  "$NODE" gate.cjs) > "$EVIDENCE/gate.out" 2> "$EVIDENCE/gate.err"

python3 - "$RESULT" "$MARKER" "$IMAGE" "$RYUK_IMAGE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    result = json.load(handle)
expected_keys = {"status", "marker", "workloadImage", "ryukImage", "ryukSessionId", "host", "mappedPort"}
if not isinstance(result, dict) or set(result) != expected_keys:
    raise SystemExit("Testcontainers result has an unexpected shape")
if result["status"] != "PASS" or result["marker"] != sys.argv[2]:
    raise SystemExit("Testcontainers HTTP marker proof is missing")
if result["workloadImage"] != sys.argv[3] or result["ryukImage"] != sys.argv[4]:
    raise SystemExit("Testcontainers result did not bind exact images")
if result["host"] != "127.0.0.1" or not isinstance(result["mappedPort"], int) \
        or not 1 <= result["mappedPort"] <= 65535:
    raise SystemExit("Testcontainers host port proof is invalid")
if not isinstance(result["ryukSessionId"], str) or not result["ryukSessionId"]:
    raise SystemExit("Testcontainers Ryuk session proof is missing")
PY

cleanup_owned
object_counts > "$EVIDENCE/final.txt"
cmp -s "$EVIDENCE/baseline.txt" "$EVIDENCE/final.txt" \
  || die "Testcontainers gate did not restore the exact empty object baseline"

cat > "$WORKROOT/manifest.txt.partial" <<EOF
status=PASS
testcontainers_version=$VERSION
npm_package_integrity=$PACKAGE_INTEGRITY
package_lock_sha256=$(shasum -a 256 "$EVIDENCE/package-lock.json" | awk '{print $1}')
workload_image=$IMAGE
ryuk_image=$RYUK_IMAGE
docker_cli_sha256=$(shasum -a 256 "$DOCKER" | awk '{print $1}')
node_sha256=$(shasum -a 256 "$NODE" | awk '{print $1}')
npm_sha256=$(shasum -a 256 "$NPM" | awk '{print $1}')
node_version=$("$NODE" --version)
npm_version=$("$NPM" --version)
canonical_npm_package=PASS
workload_http_wait=PASS
workload_http_response=PASS
ryuk_started=PASS
ryuk_guest_local_socket=PASS
workload_ryuk_session_binding=PASS
exact_baseline_cleanup=PASS
completed_epoch=$(date +%s)
EOF
mv "$WORKROOT/manifest.txt.partial" "$WORKROOT/manifest.txt"
rm -rf "$WORKROOT/.npm-cache" "$DOWNLOAD" "$PROJECT/node_modules"
trap - EXIT INT TERM
echo "Testcontainers compatibility gate: PASS ($VERSION)"
