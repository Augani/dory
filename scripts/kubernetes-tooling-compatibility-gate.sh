#!/bin/bash
# Runs checksum/digest-pinned k3s, Skaffold, and Tilt Kubernetes workflows on an empty Dory engine.
set -euo pipefail

SOCKET=""
DOCKER=""
KUBECTL=""
WORKROOT=""
CONFIRM=""
K3S_IMAGE="${DORY_RELEASE_K3S_IMAGE:-rancher/k3s:v1.36.2-k3s1@sha256:6a47cea22c4b834d4ba72c89d291696b79ebe406251f90b446e4dff03513dd87}"
WORKLOAD_IMAGE="${DORY_RELEASE_K8S_WORKLOAD_IMAGE:-nginx:alpine@sha256:54f2a904c251d5a34adf545a72d32515a15e08418dae0266e23be2e18c66fefa}"
TILT_VERSION="${DORY_RELEASE_TILT_VERSION:-0.37.5}"
TILT_SHA256=""
SKAFFOLD_VERSION="${DORY_RELEASE_SKAFFOLD_VERSION:-2.23.0}"
SKAFFOLD_SHA256=""
TOOL_CACHE=""
KUBERNETES_STABILITY_SAMPLES=60

usage() {
  cat <<'EOF'
Usage: scripts/kubernetes-tooling-compatibility-gate.sh [required options] [options]

Required:
  --socket PATH          Unix socket for an already-running disposable Dory engine
  --docker PATH          Exact Docker CLI from the candidate app
  --kubectl PATH         Exact kubectl CLI from the candidate app
  --workroot DIR         New evidence directory owned by this gate
  --confirm TOKEN        Must be ISOLATED-ENGINE-KUBERNETES-TOOLING

Options:
  --k3s-image REF        Digest-pinned k3s image
  --workload-image REF   Digest-pinned Kubernetes HTTP fixture image
  --tilt-version V       Exact Tilt version (default: 0.37.5)
  --tilt-sha256 HASH     Tilt archive SHA-256
  --skaffold-version V   Exact Skaffold version (default: 2.23.0)
  --skaffold-sha256 HASH Skaffold binary SHA-256
  --tool-cache DIR       Optional directory containing tilt.tgz and skaffold

The gate starts a disposable nested k3s control plane, proves its API and node readiness, deploys
and deletes a NodePort workload through Skaffold, repeats through Tilt's Kubernetes engine, verifies
both host-facing listeners are loopback-only, and restores the exact empty Docker-object baseline.
EOF
}

die() { echo "Kubernetes tooling compatibility gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --kubectl) need_value "$1" "$#"; KUBECTL="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    --k3s-image) need_value "$1" "$#"; K3S_IMAGE="$2"; shift 2 ;;
    --workload-image) need_value "$1" "$#"; WORKLOAD_IMAGE="$2"; shift 2 ;;
    --tilt-version) need_value "$1" "$#"; TILT_VERSION="$2"; shift 2 ;;
    --tilt-sha256) need_value "$1" "$#"; TILT_SHA256="$2"; shift 2 ;;
    --skaffold-version) need_value "$1" "$#"; SKAFFOLD_VERSION="$2"; shift 2 ;;
    --skaffold-sha256) need_value "$1" "$#"; SKAFFOLD_SHA256="$2"; shift 2 ;;
    --tool-cache) need_value "$1" "$#"; TOOL_CACHE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ "$CONFIRM" = ISOLATED-ENGINE-KUBERNETES-TOOLING ] \
  || die "requires --confirm ISOLATED-ENGINE-KUBERNETES-TOOLING"
[ -S "$SOCKET" ] || die "socket is unavailable: $SOCKET"
[ "$(stat -f %u "$SOCKET")" = "$(id -u)" ] \
  || die "socket is not owned by the release user"
for helper_name in DOCKER KUBECTL; do
  helper_path="${!helper_name}"
  case "$helper_path" in /*) ;; *) die "$helper_name helper must be an absolute path" ;; esac
  [ -f "$helper_path" ] && [ ! -L "$helper_path" ] && [ -x "$helper_path" ] \
    || die "$helper_name helper is unavailable or indirect: $helper_path"
done
case "$WORKROOT" in /*) ;; *) die "--workroot must be absolute" ;; esac
case "$WORKROOT" in /|"$HOME"|"$(pwd)") die "unsafe --workroot: $WORKROOT" ;; esac
[ ! -e "$WORKROOT" ] && [ ! -L "$WORKROOT" ] \
  || die "workroot already exists or is indirect: $WORKROOT"
for exact_image in "$K3S_IMAGE" "$WORKLOAD_IMAGE"; do
  printf '%s\n' "$exact_image" \
    | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[0-9a-f]{64}$' \
    || die "k3s and workload images must be exact digest references"
done
printf '%s\n' "$TILT_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "--tilt-version must be an exact semantic version"
printf '%s\n' "$SKAFFOLD_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "--skaffold-version must be an exact semantic version"
case "$(uname -m)" in
  arm64)
    TILT_ARCH=arm64
    SKAFFOLD_ARCH=arm64
    DEFAULT_TILT_SHA=d8c701ada9d3ee29c983651a8f344d8a4c13363e6c25a843b478aa4444ee6f30
    DEFAULT_SKAFFOLD_SHA=91723c608562b11cbbdd1df8596e8bb54ab4d7069184ba1e29497bba8d69047c
    ;;
  x86_64)
    TILT_ARCH=x86_64
    SKAFFOLD_ARCH=amd64
    DEFAULT_TILT_SHA=5db0bd3a690db4d12ddf22afbe14df5a56f0d6351731694c2e1e59158b3eb00c
    DEFAULT_SKAFFOLD_SHA=2a10d49399eaa87794af73a1f0687d6501d72a15ece60de2c3b712248fe583e4
    ;;
  *) die "unsupported macOS architecture: $(uname -m)" ;;
esac
if [ -z "$TILT_SHA256" ]; then
  [ "$TILT_VERSION" = 0.37.5 ] || die "--tilt-sha256 is required for a non-default Tilt version"
  TILT_SHA256="$DEFAULT_TILT_SHA"
fi
if [ -z "$SKAFFOLD_SHA256" ]; then
  [ "$SKAFFOLD_VERSION" = 2.23.0 ] \
    || die "--skaffold-sha256 is required for a non-default Skaffold version"
  SKAFFOLD_SHA256="$DEFAULT_SKAFFOLD_SHA"
fi
printf '%s\n' "$TILT_SHA256" | grep -Eq '^[0-9a-f]{64}$' \
  || die "Tilt SHA-256 is invalid"
printf '%s\n' "$SKAFFOLD_SHA256" | grep -Eq '^[0-9a-f]{64}$' \
  || die "Skaffold SHA-256 is invalid"
for command in curl lsof python3 shasum tar; do
  command -v "$command" >/dev/null || die "missing required command: $command"
done
if [ -n "$TOOL_CACHE" ]; then
  case "$TOOL_CACHE" in /*) ;; *) die "--tool-cache must be absolute" ;; esac
  [ -d "$TOOL_CACHE" ] && [ ! -L "$TOOL_CACHE" ] \
    || die "tool cache is unavailable or indirect: $TOOL_CACHE"
fi

mkdir -p "$WORKROOT/evidence" "$WORKROOT/workspace" "$WORKROOT/download"
WORKROOT="$(cd "$WORKROOT" && pwd)"
EVIDENCE="$WORKROOT/evidence"
WORKSPACE="$WORKROOT/workspace"
DOWNLOAD="$WORKROOT/download"
TOOL_HOME="$WORKROOT/tool-home"
KUBECONFIG="$WORKROOT/kubeconfig"
mkdir -p "$TOOL_HOME"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
K3S_CONTAINER="dory-k8s-tooling-$RUN_ID"
k3s_container_id=""
export DOCKER_HOST="unix://$SOCKET"
unset DOCKER_CONTEXT
docker_e() { "$DOCKER" "$@"; }
engine_health() {
  docker_e version --format 'client={{.Client.Version}} server={{.Server.Version}} api={{.Server.APIVersion}}'
}
custom_network_ids() { docker_e network ls --filter type=custom --format '{{.ID}}' | sed '/^$/d'; }
object_counts() {
  printf 'containers=%s\n' "$(docker_e ps -aq | sed '/^$/d' | wc -l | tr -d ' ')"
  printf 'volumes=%s\n' "$(docker_e volume ls -q | sed '/^$/d' | wc -l | tr -d ' ')"
  printf 'custom_networks=%s\n' "$(custom_network_ids | wc -l | tr -d ' ')"
}
cleanup_outer_container() {
  if [ -n "$k3s_container_id" ]; then
    docker_e rm -f -v "$k3s_container_id" \
      > "$EVIDENCE/k3s-cleanup.log" 2>&1 || true
  fi
  docker_e ps -aq --filter "label=dory.release.kubernetes-tooling.run=$RUN_ID" 2>/dev/null \
    | while IFS= read -r id; do
        [ -z "$id" ] || docker_e rm -f -v "$id" \
          >> "$EVIDENCE/k3s-cleanup.log" 2>&1 || true
      done
}
cleanup() {
  set +e
  if [ -x "$DOWNLOAD/tilt" ] && [ -f "$WORKSPACE/Tiltfile" ] && [ -f "$KUBECONFIG" ]; then
    (cd "$WORKSPACE" && HOME="$TOOL_HOME" KUBECONFIG="$KUBECONFIG" \
      "$DOWNLOAD/tilt" down --file Tiltfile --delete-namespaces) \
      >/dev/null 2>&1 || true
  fi
  if [ -x "$DOWNLOAD/skaffold" ] && [ -f "$WORKSPACE/skaffold.yaml" ] && [ -f "$KUBECONFIG" ]; then
    (cd "$WORKSPACE" && HOME="$TOOL_HOME" KUBECONFIG="$KUBECONFIG" \
      "$DOWNLOAD/skaffold" delete --filename skaffold.yaml) >/dev/null 2>&1 || true
  fi
  cleanup_outer_container
  rm -rf "$DOWNLOAD" "$KUBECONFIG"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

object_counts > "$EVIDENCE/baseline.txt"
grep -qx 'containers=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing containers"
grep -qx 'volumes=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing named volumes"
grep -qx 'custom_networks=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing custom networks"

engine_health > "$EVIDENCE/engine-health-before-tools.txt"
tilt_archive="$DOWNLOAD/tilt.tgz"
if [ -n "$TOOL_CACHE" ]; then
  [ -f "$TOOL_CACHE/tilt.tgz" ] && [ ! -L "$TOOL_CACHE/tilt.tgz" ] \
    || die "tool cache tilt.tgz is missing or indirect"
  [ -f "$TOOL_CACHE/skaffold" ] && [ ! -L "$TOOL_CACHE/skaffold" ] \
    || die "tool cache skaffold is missing or indirect"
  cp "$TOOL_CACHE/tilt.tgz" "$tilt_archive"
  cp "$TOOL_CACHE/skaffold" "$DOWNLOAD/skaffold"
  printf 'source=checksum-verified-cache\n' > "$EVIDENCE/tool-source.txt"
else
  curl -fsSL --retry 5 --retry-all-errors --continue-at - --connect-timeout 15 --max-time 900 \
    "https://github.com/tilt-dev/tilt/releases/download/v$TILT_VERSION/tilt.$TILT_VERSION.mac.$TILT_ARCH.tar.gz" \
    -o "$tilt_archive"
  curl -fsSL --retry 5 --retry-all-errors --continue-at - --connect-timeout 15 --max-time 900 \
    "https://github.com/GoogleContainerTools/skaffold/releases/download/v$SKAFFOLD_VERSION/skaffold-darwin-$SKAFFOLD_ARCH" \
    -o "$DOWNLOAD/skaffold"
  printf 'source=official-release-download\n' > "$EVIDENCE/tool-source.txt"
fi
printf '%s  %s\n' "$TILT_SHA256" "$tilt_archive" | shasum -a 256 -c - \
  > "$EVIDENCE/tilt-checksum.txt"
tar -xzf "$tilt_archive" -C "$DOWNLOAD" tilt
[ -f "$DOWNLOAD/tilt" ] && [ ! -L "$DOWNLOAD/tilt" ] \
  || die "verified Tilt archive did not contain a direct regular binary"

printf '%s  %s\n' "$SKAFFOLD_SHA256" "$DOWNLOAD/skaffold" | shasum -a 256 -c - \
  > "$EVIDENCE/skaffold-checksum.txt"
chmod 0755 "$DOWNLOAD/skaffold"
[ -f "$DOWNLOAD/skaffold" ] && [ ! -L "$DOWNLOAD/skaffold" ] \
  && [ -x "$DOWNLOAD/tilt" ] && [ -x "$DOWNLOAD/skaffold" ] \
  || die "verified tooling downloads are not executable"
"$DOWNLOAD/tilt" version > "$EVIDENCE/tilt-version.txt"
python3 - "$EVIDENCE/tilt-version.txt" "$TILT_VERSION" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
version = sys.argv[2]
if re.search(rf"(?<![0-9.])v?{re.escape(version)}(?![0-9.])", text) is None:
    raise SystemExit("Tilt binary version differs from the requested release")
PY
HOME="$TOOL_HOME" "$DOWNLOAD/skaffold" config set --global collect-metrics false \
  > "$EVIDENCE/skaffold-telemetry-disabled.txt"
HOME="$TOOL_HOME" "$DOWNLOAD/skaffold" version > "$EVIDENCE/skaffold-version.txt"
grep -Fx "v$SKAFFOLD_VERSION" "$EVIDENCE/skaffold-version.txt" >/dev/null \
  || die "Skaffold binary version differs from the requested release"
"$KUBECTL" version --client -o json > "$EVIDENCE/kubectl-client-version.json" \
  || die "candidate kubectl client version inspection failed"
shasum -a 256 "$DOCKER" > "$EVIDENCE/docker-cli-sha256.txt"
shasum -a 256 "$KUBECTL" > "$EVIDENCE/kubectl-sha256.txt"
shasum -a 256 "$DOWNLOAD/tilt" > "$EVIDENCE/tilt-binary-sha256.txt"
shasum -a 256 "$DOWNLOAD/skaffold" > "$EVIDENCE/skaffold-binary-sha256.txt"
engine_health > "$EVIDENCE/engine-health-after-tools.txt" \
  || die "Dory engine became unavailable while preparing Kubernetes tools"

pull_ok=0
for pull_attempt in 1 2 3; do
  if docker_e pull "$K3S_IMAGE" >> "$EVIDENCE/k3s-pull.txt" 2>> "$EVIDENCE/k3s-pull.stderr"; then
    pull_ok=1
    break
  fi
  if ! engine_health >> "$EVIDENCE/k3s-pull-engine-health.txt" 2>&1; then
    die "Dory engine became unavailable during the k3s image pull"
  fi
  printf 'attempt=%s result=retryable-stream-failure\n' "$pull_attempt" \
    >> "$EVIDENCE/k3s-pull-retries.txt"
  sleep 2
done
[ "$pull_ok" -eq 1 ] || die "k3s image pull failed after three healthy-engine attempts"
engine_health > "$EVIDENCE/engine-health-after-k3s-pull.txt"
k3s_container_id="$(docker_e run -d --pull=never --privileged --name "$K3S_CONTAINER" \
  --label "dory.release.kubernetes-tooling.run=$RUN_ID" \
  -p 127.0.0.1::6443 -p 127.0.0.1::30080 \
  "$K3S_IMAGE" server --disable=traefik --tls-san=127.0.0.1 --write-kubeconfig-mode=644 \
  )"
printf '%s\n' "$k3s_container_id" > "$EVIDENCE/k3s-container-id.txt"
printf '%s\n' "$k3s_container_id" | grep -Eq '^[0-9a-f]{64}$' \
  || die "nested k3s launch did not return an exact container ID"
docker_e inspect "$k3s_container_id" > "$EVIDENCE/k3s-container-inspect.json"
python3 - "$EVIDENCE/k3s-container-inspect.json" "$K3S_IMAGE" "$RUN_ID" <<'PY'
import json
import pathlib
import sys

document = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if not isinstance(document, list) or len(document) != 1 or not isinstance(document[0], dict):
    raise SystemExit("unexpected nested k3s inspect shape")
container = document[0]
config = container.get("Config")
host = container.get("HostConfig")
if not isinstance(config, dict) or not isinstance(host, dict):
    raise SystemExit("nested k3s inspect omitted configuration")
if config.get("Image") != sys.argv[2]:
    raise SystemExit("nested k3s container does not use the exact qualified image")
labels = config.get("Labels")
if not isinstance(labels, dict) or labels.get("dory.release.kubernetes-tooling.run") != sys.argv[3]:
    raise SystemExit("nested k3s container is missing its run authority label")
if host.get("Privileged") is not True:
    raise SystemExit("nested k3s control plane is not privileged")
if host.get("Binds") not in (None, []):
    raise SystemExit("nested k3s control plane unexpectedly binds host paths")
for key in ("6443/tcp", "30080/tcp"):
    bindings = host.get("PortBindings", {}).get(key)
    if not isinstance(bindings, list) or len(bindings) != 1:
        raise SystemExit(f"nested k3s has unexpected {key} bindings")
    binding = bindings[0]
    if not isinstance(binding, dict) or binding.get("HostIp") != "127.0.0.1":
        raise SystemExit(f"nested k3s {key} is not loopback-only")
PY
k3s_ready=0
for _ in $(seq 1 180); do
  state="$(docker_e inspect "$k3s_container_id" --format '{{.State.Status}}' 2>/dev/null || true)"
  [ "$state" = running ] || die "k3s container exited during startup"
  if docker_e exec "$k3s_container_id" kubectl get nodes --no-headers 2>/dev/null \
      | grep -q ' Ready'; then
    k3s_ready=1
    break
  fi
  sleep 2
done
[ "$k3s_ready" -eq 1 ] || die "k3s node did not become Ready"
docker_e port "$k3s_container_id" 6443/tcp > "$EVIDENCE/k3s-api-port.txt"
docker_e port "$k3s_container_id" 30080/tcp > "$EVIDENCE/k3s-node-port.txt"
read_port() {
  python3 - "$1" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.fullmatch(r"127\.0\.0\.1:([0-9]{1,5})\n?", text)
if match is None or not 1 <= int(match.group(1)) <= 65535:
    raise SystemExit("Dory did not allocate one exact loopback host port")
print(match.group(1))
PY
}
api_port="$(read_port "$EVIDENCE/k3s-api-port.txt")"
node_port="$(read_port "$EVIDENCE/k3s-node-port.txt")"
docker_e exec "$k3s_container_id" cat /etc/rancher/k3s/k3s.yaml \
  > "$EVIDENCE/kubeconfig-container.yaml"
python3 - "$EVIDENCE/kubeconfig-container.yaml" "$KUBECONFIG" "$api_port" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
servers = re.findall(r"(?m)^\s*server:\s*(\S+)\s*$", source)
if servers != ["https://127.0.0.1:6443"]:
    raise SystemExit("nested kubeconfig has unexpected API authorities")
rendered = source.replace("https://127.0.0.1:6443", f"https://127.0.0.1:{sys.argv[3]}")
pathlib.Path(sys.argv[2]).write_text(rendered, encoding="utf-8")
PY
chmod 0600 "$KUBECONFIG"
KUBECONFIG="$KUBECONFIG" "$KUBECTL" get --raw /version > "$EVIDENCE/kubernetes-version.json"
KUBECONFIG="$KUBECONFIG" "$KUBECTL" get nodes -o wide > "$EVIDENCE/kubernetes-nodes.txt"
grep -q ' Ready ' "$EVIDENCE/kubernetes-nodes.txt" || die "host kubectl did not observe a Ready node"
verify_workload_pod() {
  selector="$1"
  evidence_path="$2"
  KUBECONFIG="$KUBECONFIG" "$KUBECTL" -n dory-tooling-gate get pods \
    -l "$selector" -o json > "$evidence_path"
  python3 - "$evidence_path" "$WORKLOAD_IMAGE" <<'PY'
import json
import pathlib
import re
import sys

document = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
items = document.get("items") if isinstance(document, dict) else None
if not isinstance(items, list) or len(items) != 1 or not isinstance(items[0], dict):
    raise SystemExit("expected exactly one qualified workload pod")
pod = items[0]
containers = pod.get("spec", {}).get("containers")
statuses = pod.get("status", {}).get("containerStatuses")
if not isinstance(containers, list) or len(containers) != 1 or containers[0].get("image") != sys.argv[2]:
    raise SystemExit("workload pod does not declare the exact qualified image")
if pod.get("status", {}).get("phase") != "Running":
    raise SystemExit("qualified workload pod is not running")
if not isinstance(statuses, list) or len(statuses) != 1 or statuses[0].get("ready") is not True:
    raise SystemExit("qualified workload pod is not ready")
image_id = statuses[0].get("imageID")
if not isinstance(image_id, str) or re.search(r"@sha256:[0-9a-f]{64}$", image_id) is None:
    raise SystemExit("runtime workload image has no immutable image ID")
PY
}
for mapping in "api:$api_port" "nodeport:$node_port"; do
  name="${mapping%%:*}"
  port="${mapping##*:}"
  lsof -nP -iTCP:"$port" -sTCP:LISTEN > "$EVIDENCE/listener-$name.txt"
  grep -Eq "TCP (127\\.0\\.0\\.1|\\[::1\\]):$port \\(LISTEN\\)" "$EVIDENCE/listener-$name.txt" \
    || die "$name port has no loopback-only host listener"
  ! grep -Eq "TCP (\\*|0\\.0\\.0\\.0):$port \\(LISTEN\\)" "$EVIDENCE/listener-$name.txt" \
    || die "$name port widened to all host interfaces"
done

stability_started=$SECONDS
: > "$EVIDENCE/kubernetes-api-stability.tsv"
printf 'sample\tepoch\treadyz\n' >> "$EVIDENCE/kubernetes-api-stability.tsv"
for sample in $(seq 1 "$KUBERNETES_STABILITY_SAMPLES"); do
  readyz="$(KUBECONFIG="$KUBECONFIG" "$KUBECTL" get --raw /readyz 2>/dev/null)" \
    || die "host Kubernetes API connection failed at stability sample $sample"
  [ "$readyz" = ok ] \
    || die "host Kubernetes API was not ready at stability sample $sample: $readyz"
  printf '%s\t%s\t%s\n' "$sample" "$(date +%s)" "$readyz" \
    >> "$EVIDENCE/kubernetes-api-stability.tsv"
  [ "$sample" -eq "$KUBERNETES_STABILITY_SAMPLES" ] || sleep 1
done
stability_duration=$((SECONDS - stability_started))

cat > "$WORKSPACE/skaffold.yaml" <<'YAML'
apiVersion: skaffold/v4beta13
kind: Config
metadata:
  name: dory-kubernetes-tooling
manifests:
  rawYaml:
    - skaffold-k8s.yaml
deploy:
  kubectl: {}
YAML
cat > "$WORKSPACE/skaffold-k8s.yaml" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: dory-tooling-gate
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: skaffold-web
  namespace: dory-tooling-gate
spec:
  replicas: 1
  selector:
    matchLabels: {app: skaffold-web}
  template:
    metadata:
      labels: {app: skaffold-web}
    spec:
      containers:
        - name: web
          image: $WORKLOAD_IMAGE
          ports: [{containerPort: 80}]
          readinessProbe:
            httpGet: {path: /, port: 80}
            initialDelaySeconds: 1
            periodSeconds: 1
---
apiVersion: v1
kind: Service
metadata:
  name: skaffold-web
  namespace: dory-tooling-gate
spec:
  type: NodePort
  selector: {app: skaffold-web}
  ports:
    - port: 80
      targetPort: 80
      nodePort: 30080
YAML
(cd "$WORKSPACE" && HOME="$TOOL_HOME" KUBECONFIG="$KUBECONFIG" "$DOWNLOAD/skaffold" run \
  --filename skaffold.yaml --status-check=true) \
  > "$EVIDENCE/skaffold-run.log" 2> "$EVIDENCE/skaffold-run.stderr"
KUBECONFIG="$KUBECONFIG" "$KUBECTL" -n dory-tooling-gate rollout status \
  deployment/skaffold-web --timeout=5m > "$EVIDENCE/skaffold-rollout.txt"
verify_workload_pod 'app=skaffold-web' "$EVIDENCE/skaffold-workload-pod.json"
cat > "$WORKSPACE/ingress-only-network-policy.yaml" <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ingress-only-web
  namespace: dory-tooling-gate
spec:
  podSelector:
    matchLabels: {app: skaffold-web}
  policyTypes: [Ingress]
  ingress:
    - {}
YAML
KUBECONFIG="$KUBECONFIG" "$KUBECTL" apply -f "$WORKSPACE/ingress-only-network-policy.yaml" \
  > "$EVIDENCE/ingress-only-network-policy-apply.txt"
skaffold_pod="$(KUBECONFIG="$KUBECONFIG" "$KUBECTL" -n dory-tooling-gate get pod \
  -l app=skaffold-web -o jsonpath='{.items[0].metadata.name}')"
[ -n "$skaffold_pod" ] || die "Skaffold workload pod is missing for NetworkPolicy probe"
KUBECONFIG="$KUBECONFIG" "$KUBECTL" -n dory-tooling-gate exec "$skaffold_pod" -- sh -ec '
  getent hosts skaffold-web.dory-tooling-gate.svc.cluster.local
  wget -qO- --timeout=5 http://skaffold-web.dory-tooling-gate.svc.cluster.local/ \
    | grep -qi "<title>Welcome to nginx!</title>"
' > "$EVIDENCE/ingress-only-network-policy-egress.txt"
curl -fsS --retry 30 --retry-delay 1 --retry-all-errors --max-time 5 \
  "http://127.0.0.1:$node_port/" > "$EVIDENCE/skaffold-http.html"
grep -qi '<title>Welcome to nginx!</title>' "$EVIDENCE/skaffold-http.html" \
  || die "Skaffold NodePort workload returned unexpected content"
(cd "$WORKSPACE" && HOME="$TOOL_HOME" KUBECONFIG="$KUBECONFIG" "$DOWNLOAD/skaffold" delete \
  --filename skaffold.yaml) > "$EVIDENCE/skaffold-delete.log" 2>&1
for _ in $(seq 1 120); do
  ! KUBECONFIG="$KUBECONFIG" "$KUBECTL" get namespace dory-tooling-gate >/dev/null 2>&1 \
    && break
  sleep 0.5
done
! KUBECONFIG="$KUBECONFIG" "$KUBECTL" get namespace dory-tooling-gate >/dev/null 2>&1 \
  || die "Skaffold delete did not remove its namespace"

cat > "$WORKSPACE/Tiltfile" <<'TILT'
allow_k8s_contexts('default')
k8s_yaml('tilt-k8s.yaml')
k8s_resource('tilt-web')
TILT
cat > "$WORKSPACE/tilt-k8s.yaml" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: dory-tooling-gate
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tilt-web
  namespace: dory-tooling-gate
spec:
  replicas: 1
  selector:
    matchLabels: {app: tilt-web}
  template:
    metadata:
      labels: {app: tilt-web}
    spec:
      containers:
        - name: web
          image: $WORKLOAD_IMAGE
          ports: [{containerPort: 80}]
          readinessProbe:
            httpGet: {path: /, port: 80}
            initialDelaySeconds: 1
            periodSeconds: 1
---
apiVersion: v1
kind: Service
metadata:
  name: tilt-web
  namespace: dory-tooling-gate
spec:
  type: NodePort
  selector: {app: tilt-web}
  ports:
    - port: 80
      targetPort: 80
      nodePort: 30080
YAML
(cd "$WORKSPACE" && HOME="$TOOL_HOME" KUBECONFIG="$KUBECONFIG" "$DOWNLOAD/tilt" ci \
  --file Tiltfile --host localhost --port 0 --timeout 5m \
  --output-snapshot-on-exit "$EVIDENCE/tilt-kubernetes-snapshot.json") \
  > "$EVIDENCE/tilt-kubernetes.log" 2> "$EVIDENCE/tilt-kubernetes.stderr"
KUBECONFIG="$KUBECONFIG" "$KUBECTL" -n dory-tooling-gate rollout status \
  deployment/tilt-web --timeout=5m > "$EVIDENCE/tilt-rollout.txt"
verify_workload_pod 'app=tilt-web' "$EVIDENCE/tilt-workload-pod.json"
curl -fsS --retry 30 --retry-delay 1 --retry-all-errors --max-time 5 \
  "http://127.0.0.1:$node_port/" > "$EVIDENCE/tilt-http.html"
grep -qi '<title>Welcome to nginx!</title>' "$EVIDENCE/tilt-http.html" \
  || die "Tilt NodePort workload returned unexpected content"
(cd "$WORKSPACE" && HOME="$TOOL_HOME" KUBECONFIG="$KUBECONFIG" "$DOWNLOAD/tilt" down \
  --file Tiltfile --delete-namespaces) \
  > "$EVIDENCE/tilt-down.log" 2> "$EVIDENCE/tilt-down.stderr"
for _ in $(seq 1 120); do
  ! KUBECONFIG="$KUBECONFIG" "$KUBECTL" get namespace dory-tooling-gate >/dev/null 2>&1 \
    && break
  sleep 0.5
done
! KUBECONFIG="$KUBECONFIG" "$KUBECTL" get namespace dory-tooling-gate >/dev/null 2>&1 \
  || die "Tilt down did not remove its namespace"

docker_e rm -f -v "$k3s_container_id" > "$EVIDENCE/k3s-remove.txt"
k3s_container_id=""
rm -f "$KUBECONFIG"
rm -rf "$DOWNLOAD"
object_counts > "$EVIDENCE/final.txt"
cmp -s "$EVIDENCE/baseline.txt" "$EVIDENCE/final.txt" \
  || die "Kubernetes tooling gate did not restore the exact empty Docker-object baseline"

cat > "$WORKROOT/manifest.txt.partial" <<EOF
status=PASS
k3s_image=$K3S_IMAGE
workload_image=$WORKLOAD_IMAGE
k3s_container_exact_image=PASS
privileged_nested_control_plane=PASS
k3s_node_ready=PASS
host_kubectl_api=PASS
host_kubectl_stability=PASS
host_kubectl_stability_samples=$KUBERNETES_STABILITY_SAMPLES
host_kubectl_stability_duration_seconds=$stability_duration
loopback_only_api_listener=PASS
loopback_only_nodeport_listener=PASS
docker_cli_sha256=$(awk '{print $1}' "$EVIDENCE/docker-cli-sha256.txt")
kubectl_sha256=$(awk '{print $1}' "$EVIDENCE/kubectl-sha256.txt")
skaffold_version=$SKAFFOLD_VERSION
skaffold_sha256=$SKAFFOLD_SHA256
skaffold_binary_sha256=$(awk '{print $1}' "$EVIDENCE/skaffold-binary-sha256.txt")
skaffold_run=PASS
skaffold_rollout=PASS
skaffold_exact_workload_image=PASS
skaffold_nodeport_http=PASS
ingress_only_network_policy_egress=PASS
skaffold_delete=PASS
tilt_version=$TILT_VERSION
tilt_archive_sha256=$TILT_SHA256
tilt_binary_sha256=$(awk '{print $1}' "$EVIDENCE/tilt-binary-sha256.txt")
tilt_kubernetes_ci=PASS
tilt_rollout=PASS
tilt_exact_workload_image=PASS
tilt_nodeport_http=PASS
tilt_down=PASS
exact_workload_image=PASS
owned_container_cleanup=PASS
exact_baseline_cleanup=PASS
completed_epoch=$(date +%s)
EOF
mv "$WORKROOT/manifest.txt.partial" "$WORKROOT/manifest.txt"
trap - EXIT INT TERM
echo "Kubernetes tooling compatibility gate: PASS (k3s, Skaffold $SKAFFOLD_VERSION, Tilt $TILT_VERSION)"
