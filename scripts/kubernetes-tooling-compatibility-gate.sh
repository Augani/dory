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
[ -x "$DOCKER" ] || die "Docker CLI is unavailable: $DOCKER"
[ -x "$KUBECTL" ] || die "kubectl is unavailable: $KUBECTL"
[ -n "$WORKROOT" ] || die "--workroot is required"
[ ! -e "$WORKROOT" ] || die "workroot already exists: $WORKROOT"
printf '%s\n' "$K3S_IMAGE" | grep -Eq '@sha256:[0-9a-f]{64}$' \
  || die "--k3s-image must be digest-pinned"
printf '%s\n' "$WORKLOAD_IMAGE" | grep -Eq '@sha256:[0-9a-f]{64}$' \
  || die "--workload-image must be digest-pinned"
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

mkdir -p "$WORKROOT/evidence" "$WORKROOT/workspace" "$WORKROOT/download"
WORKROOT="$(cd "$WORKROOT" && pwd)"
EVIDENCE="$WORKROOT/evidence"
WORKSPACE="$WORKROOT/workspace"
DOWNLOAD="$WORKROOT/download"
TOOL_HOME="$WORKROOT/tool-home"
KUBECONFIG="$WORKROOT/kubeconfig"
mkdir -p "$TOOL_HOME"
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
cleanup_objects() {
  local ids
  ids="$(docker_e ps -aq)"; [ -z "$ids" ] || docker_e rm -f $ids >/dev/null 2>&1 || true
  ids="$(docker_e volume ls -q)"; [ -z "$ids" ] || docker_e volume rm -f $ids >/dev/null 2>&1 || true
  ids="$(custom_network_ids)"; [ -z "$ids" ] || docker_e network rm $ids >/dev/null 2>&1 || true
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
  cleanup_objects
  rm -rf "$DOWNLOAD" "$KUBECONFIG"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

object_counts > "$EVIDENCE/baseline.txt"
grep -qx 'containers=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing containers"
grep -qx 'volumes=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing named volumes"
grep -qx 'custom_networks=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing custom networks"

engine_health > "$EVIDENCE/engine-health-before-tools.txt"
tilt_archive="$DOWNLOAD/tilt.tgz"
if [ -n "$TOOL_CACHE" ]; then
  [ -f "$TOOL_CACHE/tilt.tgz" ] || die "tool cache is missing tilt.tgz"
  [ -f "$TOOL_CACHE/skaffold" ] || die "tool cache is missing skaffold"
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

printf '%s  %s\n' "$SKAFFOLD_SHA256" "$DOWNLOAD/skaffold" | shasum -a 256 -c - \
  > "$EVIDENCE/skaffold-checksum.txt"
chmod 0755 "$DOWNLOAD/skaffold"
[ -x "$DOWNLOAD/tilt" ] && [ -x "$DOWNLOAD/skaffold" ] \
  || die "verified tooling downloads are not executable"
"$DOWNLOAD/tilt" version > "$EVIDENCE/tilt-version.txt"
grep -F "$TILT_VERSION" "$EVIDENCE/tilt-version.txt" >/dev/null \
  || die "Tilt binary version differs from the requested release"
HOME="$TOOL_HOME" "$DOWNLOAD/skaffold" config set --global collect-metrics false \
  > "$EVIDENCE/skaffold-telemetry-disabled.txt"
HOME="$TOOL_HOME" "$DOWNLOAD/skaffold" version > "$EVIDENCE/skaffold-version.txt"
grep -Fx "v$SKAFFOLD_VERSION" "$EVIDENCE/skaffold-version.txt" >/dev/null \
  || die "Skaffold binary version differs from the requested release"
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
docker_e run -d --privileged --name dory-k8s-tooling-gate \
  -p 127.0.0.1::6443 -p 127.0.0.1::30080 \
  "$K3S_IMAGE" server --disable=traefik --tls-san=127.0.0.1 --write-kubeconfig-mode=644 \
  > "$EVIDENCE/k3s-container-id.txt"
k3s_ready=0
for _ in $(seq 1 180); do
  state="$(docker_e inspect dory-k8s-tooling-gate --format '{{.State.Status}}' 2>/dev/null || true)"
  [ "$state" = running ] || die "k3s container exited during startup"
  if docker_e exec dory-k8s-tooling-gate kubectl get nodes --no-headers 2>/dev/null \
      | grep -q ' Ready'; then
    k3s_ready=1
    break
  fi
  sleep 2
done
[ "$k3s_ready" -eq 1 ] || die "k3s node did not become Ready"
api_port="$(docker_e port dory-k8s-tooling-gate 6443/tcp | sed -n 's/.*://p' | head -1)"
node_port="$(docker_e port dory-k8s-tooling-gate 30080/tcp | sed -n 's/.*://p' | head -1)"
case "$api_port$node_port" in *[!0-9]*) die "Dory did not allocate numeric k3s host ports" ;; esac
docker_e exec dory-k8s-tooling-gate cat /etc/rancher/k3s/k3s.yaml \
  | sed "s/127.0.0.1:6443/127.0.0.1:$api_port/" > "$KUBECONFIG"
chmod 0600 "$KUBECONFIG"
KUBECONFIG="$KUBECONFIG" "$KUBECTL" get --raw /version > "$EVIDENCE/kubernetes-version.json"
KUBECONFIG="$KUBECONFIG" "$KUBECTL" get nodes -o wide > "$EVIDENCE/kubernetes-nodes.txt"
grep -q ' Ready ' "$EVIDENCE/kubernetes-nodes.txt" || die "host kubectl did not observe a Ready node"
for mapping in "api:$api_port" "nodeport:$node_port"; do
  name="${mapping%%:*}"
  port="${mapping##*:}"
  lsof -nP -iTCP:"$port" -sTCP:LISTEN > "$EVIDENCE/listener-$name.txt"
  grep -Eq "TCP (127\\.0\\.0\\.1|\\[::1\\]):$port \\(LISTEN\\)" "$EVIDENCE/listener-$name.txt" \
    || die "$name port has no loopback-only host listener"
  ! grep -Eq "TCP (\\*|0\\.0\\.0\\.0):$port \\(LISTEN\\)" "$EVIDENCE/listener-$name.txt" \
    || die "$name port widened to all host interfaces"
done

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

docker_e rm -f dory-k8s-tooling-gate > "$EVIDENCE/k3s-remove.txt"
rm -f "$KUBECONFIG"
cleanup_objects
rm -rf "$DOWNLOAD"
object_counts > "$EVIDENCE/final.txt"
cmp -s "$EVIDENCE/baseline.txt" "$EVIDENCE/final.txt" \
  || die "Kubernetes tooling gate did not restore the exact empty Docker-object baseline"

cat > "$WORKROOT/manifest.txt.partial" <<EOF
status=PASS
k3s_image=$K3S_IMAGE
workload_image=$WORKLOAD_IMAGE
k3s_node_ready=PASS
host_kubectl_api=PASS
loopback_only_api_listener=PASS
loopback_only_nodeport_listener=PASS
skaffold_version=$SKAFFOLD_VERSION
skaffold_sha256=$SKAFFOLD_SHA256
skaffold_run=PASS
skaffold_rollout=PASS
skaffold_nodeport_http=PASS
ingress_only_network_policy_egress=PASS
skaffold_delete=PASS
tilt_version=$TILT_VERSION
tilt_archive_sha256=$TILT_SHA256
tilt_kubernetes_ci=PASS
tilt_rollout=PASS
tilt_nodeport_http=PASS
tilt_down=PASS
exact_baseline_cleanup=PASS
completed_epoch=$(date +%s)
EOF
mv "$WORKROOT/manifest.txt.partial" "$WORKROOT/manifest.txt"
trap - EXIT INT TERM
echo "Kubernetes tooling compatibility gate: PASS (k3s, Skaffold $SKAFFOLD_VERSION, Tilt $TILT_VERSION)"
