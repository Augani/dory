#!/bin/bash
# Reproduce GitHub issue #78 against the exact Dory Linux runtime. This is intentionally a live,
# release-candidate gate: it creates a real kind v1.33 cluster, admits an amd64 workload through
# the nested node containerd/runc stack on an arm64 kernel, and exercises both create and exec.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SOCKET=""
DOCKER=""
KIND=""
KUBECTL=""
KERNEL=""
INITFS=""
EXPECTED_KERNEL=""
EXPECTED_INITFS=""
WORKROOT=""
SOURCE_COMMIT=""
CONFIRM=""

KIND_VERSION="v0.29.0"
KIND_DARWIN_ARM64_SHA256="314d8f1428842fd1ba2110fd0052a0f0b3ab5773ab1bdcdad1ff036e913310c9"
KIND_NODE_IMAGE="kindest/node:v1.33.0@sha256:02f73d6ae3f11ad5d543f16736a2cb2a63a300ad60e81dac22099b0b04784a4e"
STRESS_IMAGE="polinux/stress:1.0.4@sha256:b6144f84f9c15dac80deb48d3a646b55c7043ab1d83ea0a697c09097aaad21aa"
EXPECTED_NODE_RUNC_VERSION="1.2.3"
EXPECTED_KERNEL_RELEASE=""

usage() {
  printf '%s\n' \
    'Usage: scripts/fex-kind-live-gate.sh [required options]' \
    '' \
    '  --socket PATH          Exact isolated Dory Docker socket' \
    '  --docker PATH          Exact signed candidate Docker CLI' \
    '  --kind PATH            Pinned kind v0.29.0 Darwin ARM64 binary' \
    '  --kubectl PATH         Exact signed Dory Kubernetes component' \
    '  --kernel PATH          Kernel file used by the running Dory VM' \
    '  --initfs PATH          Engine rootfs file used by the running Dory VM' \
    '  --expected-kernel PATH Same-commit guest/out/Image-gpu release artifact' \
    '  --expected-initfs PATH Same-commit guest/out/initfs-arm64.ext4 artifact' \
    '  --source-commit SHA    Exact 40-character release source commit' \
    '  --workroot DIR         New absolute evidence directory' \
    '  --confirm TOKEN        Must be EXACT-DORY-FEX-KIND' \
    '  --help' \
    '' \
    'The immutable images reproduce issue #78: kindest/node v1.33.0 and polinux/stress 1.0.4.'
}

die() { echo "FEX kind live gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --kind) need_value "$1" "$#"; KIND="$2"; shift 2 ;;
    --kubectl) need_value "$1" "$#"; KUBECTL="$2"; shift 2 ;;
    --kernel) need_value "$1" "$#"; KERNEL="$2"; shift 2 ;;
    --initfs) need_value "$1" "$#"; INITFS="$2"; shift 2 ;;
    --expected-kernel) need_value "$1" "$#"; EXPECTED_KERNEL="$2"; shift 2 ;;
    --expected-initfs) need_value "$1" "$#"; EXPECTED_INITFS="$2"; shift 2 ;;
    --source-commit) need_value "$1" "$#"; SOURCE_COMMIT="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ "$CONFIRM" = EXACT-DORY-FEX-KIND ] || die 'requires --confirm EXACT-DORY-FEX-KIND'
for command in awk grep id ln mkdir seq shasum sleep stat tr; do
  command -v "$command" >/dev/null || die "required host command is missing: $command"
done
kernel_version="$(awk -F= '$1 == "KERNEL_VERSION" { print $2; exit }' guest/kernel/PINS)"
printf '%s\n' "$kernel_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die 'guest/kernel/PINS has no exact KERNEL_VERSION'
EXPECTED_KERNEL_RELEASE="$kernel_version-dory"
case "$SOCKET" in /*) ;; *) die 'Dory socket must be an absolute path' ;; esac
[ -S "$SOCKET" ] && [ ! -L "$SOCKET" ] || die "Dory socket is unavailable or indirect: $SOCKET"
[ "$(stat -f %u "$SOCKET")" = "$(id -u)" ] || die 'Dory socket is not owned by the release user'
for pair in "Docker CLI:$DOCKER" "kind binary:$KIND" "kubectl component:$KUBECTL"; do
  label="${pair%%:*}"
  path="${pair#*:}"
  case "$path" in /*) ;; *) die "$label must be an absolute path" ;; esac
  [ -f "$path" ] && [ ! -L "$path" ] && [ -s "$path" ] && [ -x "$path" ] \
    || die "$label is unavailable or indirect: $path"
done
for pair in "running kernel:$KERNEL" "running initfs:$INITFS" \
            "same-commit kernel:$EXPECTED_KERNEL" "same-commit initfs:$EXPECTED_INITFS"; do
  label="${pair%%:*}"
  path="${pair#*:}"
  case "$path" in /*) ;; *) die "$label must be an absolute path" ;; esac
  [ -f "$path" ] && [ ! -L "$path" ] && [ -s "$path" ] \
    || die "$label is unavailable or indirect: $path"
done
printf '%s\n' "$SOURCE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' \
  || die 'source commit must be a full lowercase Git SHA'
case "$WORKROOT" in /*) ;; *) die 'workroot must be an absolute path' ;; esac
case "$WORKROOT" in /|"$HOME"|"$ROOT") die "unsafe workroot: $WORKROOT" ;; esac
[ ! -e "$WORKROOT" ] && [ ! -L "$WORKROOT" ] \
  || die "workroot already exists or is indirect: $WORKROOT"

kind_sha256="$(shasum -a 256 "$KIND" | awk '{print $1}')"
[ "$kind_sha256" = "$KIND_DARWIN_ARM64_SHA256" ] \
  || die "kind $KIND_VERSION Darwin ARM64 digest mismatch"
running_kernel_sha256="$(shasum -a 256 "$KERNEL" | awk '{print $1}')"
expected_kernel_sha256="$(shasum -a 256 "$EXPECTED_KERNEL" | awk '{print $1}')"
[ "$running_kernel_sha256" = "$expected_kernel_sha256" ] \
  || die 'running Dory VM kernel differs from the same-commit Venus release artifact'
running_initfs_sha256="$(shasum -a 256 "$INITFS" | awk '{print $1}')"
expected_initfs_sha256="$(shasum -a 256 "$EXPECTED_INITFS" | awk '{print $1}')"
[ "$running_initfs_sha256" = "$expected_initfs_sha256" ] \
  || die 'running Dory VM initfs differs from the same-commit release artifact'

mkdir "$WORKROOT"
WORKROOT="$(cd "$WORKROOT" && pwd -P)"
EVIDENCE="$WORKROOT/evidence"
TOOLBIN="$WORKROOT/bin"
KUBECONFIG="$WORKROOT/kubeconfig"
mkdir "$EVIDENCE" "$TOOLBIN"
ln -s "$DOCKER" "$TOOLBIN/docker"
export KUBECONFIG
export PATH="$TOOLBIN:$PATH"

RUN_TOKEN="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-$$}"
RUN_TOKEN="$(printf '%s' "$RUN_TOKEN" | tr -cd 'a-zA-Z0-9-')"
[ -n "$RUN_TOKEN" ] || die 'could not derive an isolated cluster name'
CLUSTER="dory-fex-issue78-$RUN_TOKEN"
NODE="$CLUSTER-control-plane"
ONE_SHOT_POD="issue78-stress"
EXEC_POD="issue78-exec"
CLUSTER_OWNED=0
KIND_IMAGE_OWNED=0

docker_e() {
  env -u DOCKER_API_VERSION -u DOCKER_AUTH_CONFIG -u DOCKER_CERT_PATH \
    -u DOCKER_CONTEXT -u DOCKER_CUSTOM_HEADERS -u DOCKER_DEFAULT_PLATFORM \
    -u DOCKER_TLS -u DOCKER_TLS_VERIFY DOCKER_HOST="unix://$SOCKET" \
    "$DOCKER" "$@"
}

kind_e() {
  env -u DOCKER_API_VERSION -u DOCKER_AUTH_CONFIG -u DOCKER_CERT_PATH \
    -u DOCKER_CONTEXT -u DOCKER_CUSTOM_HEADERS -u DOCKER_DEFAULT_PLATFORM \
    -u DOCKER_TLS -u DOCKER_TLS_VERIFY DOCKER_HOST="unix://$SOCKET" \
    KUBECONFIG="$KUBECONFIG" PATH="$PATH" "$KIND" "$@"
}

kubectl_e() {
  env KUBECONFIG="$KUBECONFIG" "$KUBECTL" "$@"
}

cleanup() {
  set +e
  if [ "$CLUSTER_OWNED" -eq 1 ]; then
    kubectl_e get pods -A -o wide > "$EVIDENCE/pods-final.txt" 2>&1 || true
    kubectl_e get events -A --sort-by=.lastTimestamp > "$EVIDENCE/events-final.txt" 2>&1 || true
    docker_e logs "$NODE" > "$EVIDENCE/kind-node.log" 2>&1 || true
    kind_e export logs "$EVIDENCE/kind-export" --name "$CLUSTER" \
      > "$EVIDENCE/kind-export.out" 2> "$EVIDENCE/kind-export.err" || true
    kind_e delete cluster --name "$CLUSTER" \
      > "$EVIDENCE/kind-delete.out" 2> "$EVIDENCE/kind-delete.err" || true
    CLUSTER_OWNED=0
  fi
  [ "$KIND_IMAGE_OWNED" -eq 0 ] \
    || docker_e image rm -f "$KIND_NODE_IMAGE" \
      > "$EVIDENCE/kind-image-delete.out" 2> "$EVIDENCE/kind-image-delete.err" || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '%s\n' \
  "kind create cluster --name $CLUSTER --image $KIND_NODE_IMAGE --wait 180s" \
  "kubectl run $ONE_SHOT_POD --image=$STRESS_IMAGE --restart=Never -- uname -m" \
  "kubectl run $EXEC_POD --image=$STRESS_IMAGE --restart=Never --command -- /bin/sh -c 'while :; do sleep 60; done'" \
  "kubectl exec $EXEC_POD -- uname -m" > "$EVIDENCE/exact-commands.txt"

DORY_KERNEL_PROFILE=venus guest/kernel/verify-build.sh arm64 \
  > "$EVIDENCE/kernel-verification.txt" 2>&1 \
  || die 'same-commit Venus kernel verification failed'
guest/initfs/verify-build.sh arm64 > "$EVIDENCE/initfs-verification.txt" 2>&1 \
  || die 'same-commit initfs verification failed'

docker_e version > "$EVIDENCE/docker-version.txt" || die 'Dory Docker API is unavailable'
server_os="$(docker_e info --format '{{.OSType}}')"
server_arch="$(docker_e info --format '{{.Architecture}}')"
default_runtime="$(docker_e info --format '{{.DefaultRuntime}}')"
runtimes="$(docker_e info --format '{{json .Runtimes}}')"
[ "$server_os/$server_arch" = linux/arm64 ] \
  || die "issue #78 requires a linux/arm64 Dory engine, got $server_os/$server_arch"
[ "$default_runtime" = dory-runc ] || die 'dory-runc is not Docker default runtime'
printf '%s\n' "$runtimes" | grep -q '"dory-runc"' \
  || die 'dory-runc is absent from Docker runtime inventory'

kubectl_version_json="$($KUBECTL version --client -o json)" \
  || die 'signed Kubernetes component cannot report its version'
printf '%s\n' "$kubectl_version_json" > "$EVIDENCE/kubectl-version.json"
kind_version="$($KIND version)" || die 'pinned kind binary cannot report its version'
printf '%s\n' "$kind_version" > "$EVIDENCE/kind-version.txt"
printf '%s\n' "$kind_version" | grep -Fq "$KIND_VERSION" \
  || die "kind binary is not $KIND_VERSION"

if kind_e get clusters | grep -Fxq "$CLUSTER"; then
  die "owned kind cluster already exists: $CLUSTER"
fi
if docker_e image inspect "$KIND_NODE_IMAGE" >/dev/null 2>&1; then
  die "kind node image already exists; release gate requires a fresh exact pull: $KIND_NODE_IMAGE"
fi
docker_e pull --platform linux/arm64 "$KIND_NODE_IMAGE" \
  > "$EVIDENCE/kind-image-pull.out" 2> "$EVIDENCE/kind-image-pull.err" \
  || die 'exact kind node image pull failed'
KIND_IMAGE_OWNED=1
docker_e image inspect "$KIND_NODE_IMAGE" > "$EVIDENCE/kind-image-inspect.json"
kind_repo_digests="$(docker_e image inspect -f '{{json .RepoDigests}}' "$KIND_NODE_IMAGE")"
printf '%s\n' "$kind_repo_digests" | grep -Fq \
  'kindest/node@sha256:02f73d6ae3f11ad5d543f16736a2cb2a63a300ad60e81dac22099b0b04784a4e' \
  || die 'pulled kind node does not expose the pinned v1.33.0 repository digest'

outer_wrapper_record="$(docker_e run --rm --platform linux/arm64 --entrypoint /bin/sh \
  "$KIND_NODE_IMAGE" -ec 'sha256sum /run/dory-fex/dory-fex-init; uname -r')" \
  || die 'outer OCI admission did not expose the Dory runtime wrapper'
printf '%s\n' "$outer_wrapper_record" > "$EVIDENCE/outer-wrapper.txt"
outer_wrapper_sha256="$(printf '%s\n' "$outer_wrapper_record" | awk 'NR == 1 { print $1 }')"
outer_kernel_release="$(printf '%s\n' "$outer_wrapper_record" | awk 'NR == 2 { print; exit }')"
[ "$outer_kernel_release" = "$EXPECTED_KERNEL_RELEASE" ] \
  || die "running guest kernel release is $outer_kernel_release, expected $EXPECTED_KERNEL_RELEASE"

CLUSTER_OWNED=1
kind_e create cluster --name "$CLUSTER" --image "$KIND_NODE_IMAGE" --wait 180s \
  > "$EVIDENCE/kind-create.out" 2> "$EVIDENCE/kind-create.err" \
  || die 'kind v1.33.0 cluster creation failed through Dory'

node_runtime="$(docker_e inspect -f '{{.HostConfig.Runtime}}' "$NODE")"
[ "$node_runtime" = dory-runc ] \
  || die "kind node bypassed Dory runtime admission: $node_runtime"
node_arch="$(docker_e exec "$NODE" uname -m)"
[ "$node_arch" = aarch64 ] || die "kind node is not native arm64: $node_arch"
node_kernel_release="$(docker_e exec "$NODE" uname -r)"
[ "$node_kernel_release" = "$EXPECTED_KERNEL_RELEASE" ] \
  || die "kind node kernel is $node_kernel_release, expected $EXPECTED_KERNEL_RELEASE"
docker_e exec "$NODE" runc --version > "$EVIDENCE/nested-runc-version.txt"
nested_runc_version="$(awk 'NR == 1 && $1 == "runc" && $2 == "version" { print $3 }' \
  "$EVIDENCE/nested-runc-version.txt")"
[ "$nested_runc_version" = "$EXPECTED_NODE_RUNC_VERSION" ] \
  || die "pinned kind node runc changed: $nested_runc_version"

docker_e exec "$NODE" cat /proc/self/mountinfo > "$EVIDENCE/nested-mountinfo.txt"
for mountpoint in /usr/lib/dory/fex /run/dory-fex/dory-fex-init \
                  /usr/local/bin/runc.real /usr/local/bin/dory-runc /usr/local/sbin/runc; do
  awk -v target="$mountpoint" '$5 == target { found = 1 } END { exit !found }' \
    "$EVIDENCE/nested-mountinfo.txt" \
    || die "kind node lacks exact Dory nested-runtime mount: $mountpoint"
done
awk '$5 == "/usr/local/bin/runc.real" && $4 == "/usr/local/sbin/runc" { found = 1 }
     END { exit !found }' "$EVIDENCE/nested-mountinfo.txt" \
  || die 'runc.real is not the preserved kind node runtime file mount'
node_wrapper_sha256="$(docker_e exec "$NODE" sha256sum /usr/local/bin/dory-runc | awk '{print $1}')"
[ "$node_wrapper_sha256" = "$outer_wrapper_sha256" ] \
  || die 'nested kind wrapper differs from the outer Dory runtime wrapper'
docker_e exec "$NODE" /bin/sh -ec \
  'grep -qx enabled /proc/sys/fs/binfmt_misc/FEX-x86_64 &&
   grep -qx "flags: POCF" /proc/sys/fs/binfmt_misc/FEX-x86_64' \
  || die 'kind node does not inherit Dory seccomp-correct FEX-x86_64 binfmt admission'
fex_sha256="$(docker_e exec "$NODE" sha256sum /usr/lib/dory/fex/FEX | awk '{print $1}')"
fex_server_sha256="$(
  docker_e exec "$NODE" sha256sum /usr/lib/dory/fex/FEXServer | awk '{print $1}'
)"

kubectl_e run "$ONE_SHOT_POD" --image="$STRESS_IMAGE" --restart=Never -- uname -m \
  > "$EVIDENCE/one-shot-create.out" 2> "$EVIDENCE/one-shot-create.err" \
  || die 'issue #78 one-shot amd64 pod admission failed'
one_shot_phase=""
for _ in $(seq 1 180); do
  one_shot_phase="$(kubectl_e get pod "$ONE_SHOT_POD" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "$one_shot_phase" in
    Succeeded) break ;;
    Failed) break ;;
  esac
  sleep 1
done
kubectl_e get pod "$ONE_SHOT_POD" -o yaml > "$EVIDENCE/one-shot-pod.yaml" 2>&1 || true
kubectl_e describe pod "$ONE_SHOT_POD" > "$EVIDENCE/one-shot-describe.txt" 2>&1 || true
kubectl_e logs "$ONE_SHOT_POD" > "$EVIDENCE/one-shot.log" 2>&1 || true
[ "$one_shot_phase" = Succeeded ] \
  || die "issue #78 one-shot pod did not succeed (phase=$one_shot_phase)"
one_shot_uname="$(tr -d '\r' < "$EVIDENCE/one-shot.log")"
[ "$one_shot_uname" = x86_64 ] \
  || die "issue #78 one-shot result is not x86_64: $one_shot_uname"
one_shot_exit="$(kubectl_e get pod "$ONE_SHOT_POD" \
  -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}')"
one_shot_restarts="$(kubectl_e get pod "$ONE_SHOT_POD" \
  -o jsonpath='{.status.containerStatuses[0].restartCount}')"
[ "$one_shot_exit/$one_shot_restarts" = 0/0 ] \
  || die "issue #78 pod exit/restart contract failed: $one_shot_exit/$one_shot_restarts"
if grep -Eiq 'FEXServerClient|Failure to setup client|Could.?t execute: FEXServer' \
  "$EVIDENCE/one-shot.log" "$EVIDENCE/one-shot-describe.txt"; then
  die 'issue #78 FEXServer failure signature is still present'
fi

kubectl_e run "$EXEC_POD" --image="$STRESS_IMAGE" --restart=Never --command -- \
  /bin/sh -c 'while :; do sleep 60; done' \
  > "$EVIDENCE/exec-pod-create.out" 2> "$EVIDENCE/exec-pod-create.err" \
  || die 'long-lived amd64 exec pod admission failed'
kubectl_e wait --for=condition=Ready "pod/$EXEC_POD" --timeout=180s \
  > "$EVIDENCE/exec-pod-wait.out" 2> "$EVIDENCE/exec-pod-wait.err" \
  || die 'long-lived amd64 exec pod did not become ready'
kubectl_e exec "$EXEC_POD" -- uname -m \
  > "$EVIDENCE/kubectl-exec.log" 2> "$EVIDENCE/kubectl-exec.err" \
  || die 'nested runc exec through the amd64 pod failed'
exec_uname="$(tr -d '\r' < "$EVIDENCE/kubectl-exec.log")"
[ "$exec_uname" = x86_64 ] || die "nested runc exec result is not x86_64: $exec_uname"
if grep -Eiq 'FEXServerClient|Failure to setup client|Could.?t execute: FEXServer' \
  "$EVIDENCE/kubectl-exec.log" "$EVIDENCE/kubectl-exec.err"; then
  die 'FEXServer failure signature is present in nested runc exec'
fi
kubectl_e delete pod "$EXEC_POD" --wait=true --timeout=60s \
  > "$EVIDENCE/exec-pod-delete.out" 2> "$EVIDENCE/exec-pod-delete.err" \
  || die 'long-lived amd64 exec pod cleanup failed'
kubectl_e delete pod "$ONE_SHOT_POD" --wait=true --timeout=60s \
  > "$EVIDENCE/one-shot-delete.out" 2> "$EVIDENCE/one-shot-delete.err" \
  || die 'one-shot amd64 pod cleanup failed'

kubectl_e get pods -A -o wide > "$EVIDENCE/pods-final.txt" 2>&1 \
  || die 'cannot retain final kind pod inventory'
kubectl_e get events -A --sort-by=.lastTimestamp > "$EVIDENCE/events-final.txt" 2>&1 \
  || die 'cannot retain final kind event inventory'
docker_e logs "$NODE" > "$EVIDENCE/kind-node.log" 2>&1 \
  || die 'cannot retain kind node log'
kind_e export logs "$EVIDENCE/kind-export" --name "$CLUSTER" \
  > "$EVIDENCE/kind-export.out" 2> "$EVIDENCE/kind-export.err" \
  || die 'cannot retain kind diagnostic export'
kind_e delete cluster --name "$CLUSTER" \
  > "$EVIDENCE/kind-delete.out" 2> "$EVIDENCE/kind-delete.err" \
  || die 'kind cluster cleanup failed'
CLUSTER_OWNED=0
if kind_e get clusters | grep -Fxq "$CLUSTER"; then
  die 'kind cluster remains after cleanup'
fi
if docker_e inspect "$NODE" >/dev/null 2>&1; then
  die 'kind node container remains after cleanup'
fi
docker_e image rm -f "$KIND_NODE_IMAGE" \
  > "$EVIDENCE/kind-image-delete.out" 2> "$EVIDENCE/kind-image-delete.err" \
  || die 'kind node image cleanup failed'
KIND_IMAGE_OWNED=0
if docker_e image inspect "$KIND_NODE_IMAGE" >/dev/null 2>&1; then
  die 'kind node image remains after cleanup'
fi
docker_e version > "$EVIDENCE/docker-version-after.txt" \
  || die 'Dory Docker API is unavailable after the nested kind workload'

kubectl_sha256="$(shasum -a 256 "$KUBECTL" | awk '{print $1}')"
docker_sha256="$(shasum -a 256 "$DOCKER" | awk '{print $1}')"
{
  echo 'kind=dev.dory.fex-kind-issue78-live-gate'
  echo 'schema=1'
  echo "source_commit=$SOURCE_COMMIT"
  echo "kind_version=$KIND_VERSION"
  echo "kind_sha256=$kind_sha256"
  echo "kubectl_sha256=$kubectl_sha256"
  echo "docker_sha256=$docker_sha256"
  echo "kind_node_image=$KIND_NODE_IMAGE"
  echo "stress_image=$STRESS_IMAGE"
  echo "kernel_release=$node_kernel_release"
  echo "kernel_sha256=$running_kernel_sha256"
  echo "initfs_sha256=$running_initfs_sha256"
  echo "runc_wrapper_sha256=$node_wrapper_sha256"
  echo "fex_sha256=$fex_sha256"
  echo "fex_server_sha256=$fex_server_sha256"
  echo "nested_runc_version=$nested_runc_version"
  echo "node_runtime=$node_runtime"
  echo "node_arch=$node_arch"
  echo "one_shot_uname=$one_shot_uname"
  echo "one_shot_exit_code=$one_shot_exit"
  echo "one_shot_restart_count=$one_shot_restarts"
  echo "nested_exec_uname=$exec_uname"
  echo 'fex_errors=absent'
  echo 'isolated_cleanup=PASS'
  echo 'docker_after=PASS'
  echo 'issue_78=PASS'
  echo 'status=PASS'
} > "$EVIDENCE/manifest.txt"

echo "FEX kind live gate: PASS ($EVIDENCE/manifest.txt)"
