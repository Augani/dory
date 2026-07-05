#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUITE_DIR="$ROOT/examples/readiness"
APP="${DORY_APP:-/Applications/Dory.app}"
DOCKER_HOST_VALUE="${DORY_DOCKER_HOST:-unix://$HOME/.dory/dory.sock}"
KUBECONFIG_PATH="${DORY_KUBECONFIG:-$HOME/.kube/dory-config}"
PROJECT="${DORY_READINESS_PROJECT:-doryready}"
RUN_ID="${DORY_READINESS_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
WORKDIR="${DORY_READINESS_WORKDIR:-$SUITE_DIR/tmp/$RUN_ID}"
HTTP_PORT="${DORY_READINESS_API_PORT:-18080}"
K3S_IMAGE="${DORY_K3S_IMAGE:-rancher/k3s:v1.36.2-k3s1}"
WITH_KUBERNETES=0
WITH_MACHINES=1
KEEP=0
STRICT_ATTACH=1

PASS=0
FAIL=0
SKIP=0
CURRENT_TEST=""

usage() {
  cat <<EOF
Usage: examples/readiness/run.sh [options]

Options:
  --with-kubernetes        Start/verify Dory's k3s container and apply Kubernetes examples
  --skip-machines          Skip Linux machine container checks
  --skip-attach            Skip docker run/exec attached-output checks
  --keep                   Leave containers, volumes, networks, images, and k8s resources behind
  --project NAME           Compose/project prefix (default: $PROJECT)
  --port PORT              Host port for the Compose HTTP service (default: $HTTP_PORT)
  -h, --help               Show this help

Env:
  DORY_APP                 Dory.app path (default: /Applications/Dory.app)
  DORY_DOCKER_HOST         Docker host URI (default: unix://~/.dory/dory.sock)
  DORY_KUBECONFIG          Kubeconfig path (default: ~/.kube/dory-config)
  DORY_K3S_IMAGE           k3s image for --with-kubernetes
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --with-kubernetes) WITH_KUBERNETES=1; shift ;;
    --skip-machines) WITH_MACHINES=0; shift ;;
    --skip-attach) STRICT_ATTACH=0; shift ;;
    --keep) KEEP=1; shift ;;
    --project) PROJECT="$2"; shift 2 ;;
    --port) HTTP_PORT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

mkdir -p "$WORKDIR"
RESULTS="$WORKDIR/results.tsv"
printf 'status\ttest\tdetail\n' > "$RESULTS"

DOCKER_BIN="${DORY_DOCKER_BIN:-$APP/Contents/Helpers/docker}"
COMPOSE_PLUGIN="${DORY_COMPOSE_PLUGIN:-$APP/Contents/Helpers/docker-compose}"
KUBECTL_BIN="${DORY_KUBECTL_BIN:-$APP/Contents/Helpers/kubectl}"

if [ ! -x "$DOCKER_BIN" ]; then
  DOCKER_BIN="$(command -v docker || true)"
fi
if [ -z "$DOCKER_BIN" ] || [ ! -x "$DOCKER_BIN" ]; then
  echo "docker CLI not found. Set DORY_APP or DORY_DOCKER_BIN." >&2
  exit 2
fi

export DOCKER_HOST="$DOCKER_HOST_VALUE"
export DOCKER_CONFIG="$WORKDIR/docker-config"
mkdir -p "$DOCKER_CONFIG/cli-plugins"
if [ -x "$COMPOSE_PLUGIN" ]; then
  ln -sf "$COMPOSE_PLUGIN" "$DOCKER_CONFIG/cli-plugins/docker-compose"
fi

docker_cmd() { "$DOCKER_BIN" "$@"; }
compose_cmd() { "$DOCKER_BIN" compose "$@"; }
kubectl_cmd() { KUBECONFIG="$KUBECONFIG_PATH" "$KUBECTL_BIN" "$@"; }

record() {
  local status="$1" test="$2" detail="$3"
  printf '%s\t%s\t%s\n' "$status" "$test" "$(printf '%s' "$detail" | tr '\n\t' '  ' | cut -c 1-600)" >> "$RESULTS"
  case "$status" in
    PASS) PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$test" ;;
    FAIL) FAIL=$((FAIL + 1)); printf '  [FAIL] %s -- %s\n' "$test" "$detail" ;;
    SKIP) SKIP=$((SKIP + 1)); printf '  [SKIP] %s -- %s\n' "$test" "$detail" ;;
  esac
}

run_test() {
  local name="$1"
  shift
  CURRENT_TEST="$name"
  local log="$WORKDIR/$name.log"
  printf '==> %s\n' "$name"
  if ( set -e; "$@" ) >"$log" 2>&1; then
    record PASS "$name" "ok"
  else
    local rc=$?
    record FAIL "$name" "exit=$rc; log=$log; $(tail -20 "$log" 2>/dev/null)"
  fi
}

skip_test() {
  record SKIP "$1" "$2"
}

cleanup() {
  local status=$?
  if [ "$KEEP" = "0" ]; then
    compose_cmd -f "$SUITE_DIR/compose/compose.yaml" -p "$PROJECT" down -v --remove-orphans >/dev/null 2>&1 || true
    docker_cmd rm -f dory-readiness-run dory-readiness-exec dory-readiness-cp dory-readiness-volume dory-readiness-net-web dory-readiness-limits >/dev/null 2>&1 || true
    docker_cmd rm -f dory-machine-readiness dory-machine-readiness-clone >/dev/null 2>&1 || true
    docker_cmd network rm dory-readiness-net >/dev/null 2>&1 || true
    docker_cmd volume rm dory-readiness-volume >/dev/null 2>&1 || true
    docker_cmd rmi -f dory/readiness-app:local dory/readiness-saved:local dory/readiness-machine:local dory/readiness-machine-snapshot:local >/dev/null 2>&1 || true
    if [ "$WITH_KUBERNETES" = "1" ] && [ -x "$KUBECTL_BIN" ]; then
      kubectl_cmd delete namespace dory-readiness --ignore-not-found=true >/dev/null 2>&1 || true
    fi
  fi
  return "$status"
}
trap cleanup EXIT

wait_http() {
  local url="$1" pattern="$2"
  for _ in $(seq 1 40); do
    if curl -fsS "$url" 2>/dev/null | grep -q "$pattern"; then
      return 0
    fi
    sleep 1
  done
  curl -fsS "$url"
}

test_docker_api() {
  docker_cmd version
  docker_cmd info
  docker_cmd system df
}

test_compose_available() {
  compose_cmd version
}

test_build_image() {
  docker_cmd build -t dory/readiness-app:local "$SUITE_DIR/docker/app"
  docker_cmd image inspect dory/readiness-app:local
}

test_run_http_and_logs() {
  docker_cmd rm -f dory-readiness-run >/dev/null 2>&1 || true
  docker_cmd run -d --name dory-readiness-run \
    --label "dev.dory.readiness=$RUN_ID" \
    -e DORY_MESSAGE=run-ok \
    -p "127.0.0.1::8080" \
    dory/readiness-app:local
  local port
  port="$(docker_cmd port dory-readiness-run 8080/tcp | sed 's/.*://')"
  test -n "$port"
  wait_http "http://127.0.0.1:$port" "run-ok"
  docker_cmd logs dory-readiness-run >/dev/null
  docker_cmd inspect dory-readiness-run >/dev/null
}

test_exec_cp_volume_network() {
  docker_cmd rm -f dory-readiness-exec dory-readiness-cp dory-readiness-volume dory-readiness-net-web >/dev/null 2>&1 || true
  docker_cmd volume rm dory-readiness-volume >/dev/null 2>&1 || true
  docker_cmd network rm dory-readiness-net >/dev/null 2>&1 || true

  docker_cmd run -d --name dory-readiness-exec --label "dev.dory.readiness=$RUN_ID" dory/readiness-app:local
  docker_cmd exec dory-readiness-exec sh -c 'echo exec-side-effect > /tmp/exec.txt'
  docker_cmd cp dory-readiness-exec:/tmp/exec.txt "$WORKDIR/exec.txt"
  grep -q exec-side-effect "$WORKDIR/exec.txt"

  printf 'from-host\n' > "$WORKDIR/host.txt"
  docker_cmd cp "$WORKDIR/host.txt" dory-readiness-exec:/tmp/host.txt
  docker_cmd exec dory-readiness-exec sh -c 'grep -q from-host /tmp/host.txt'

  docker_cmd volume create --label "dev.dory.readiness=$RUN_ID" dory-readiness-volume
  docker_cmd run --rm --label "dev.dory.readiness=$RUN_ID" -v dory-readiness-volume:/data dory/readiness-app:local sh -c 'echo volume-ok > /data/value.txt'
  docker_cmd run --rm --label "dev.dory.readiness=$RUN_ID" -v dory-readiness-volume:/data dory/readiness-app:local sh -c 'grep -q volume-ok /data/value.txt'

  docker_cmd network create --label "dev.dory.readiness=$RUN_ID" dory-readiness-net
  docker_cmd run -d --name dory-readiness-net-web --network dory-readiness-net --network-alias web \
    --label "dev.dory.readiness=$RUN_ID" dory/readiness-app:local
  docker_cmd run --rm --network dory-readiness-net --label "dev.dory.readiness=$RUN_ID" dory/readiness-app:local \
    sh -c 'wget -qO- http://web:8080 | grep -q dory-readiness-ok'
}

test_save_load_limits() {
  docker_cmd tag dory/readiness-app:local dory/readiness-saved:local
  docker_cmd save -o "$WORKDIR/readiness-image.tar" dory/readiness-saved:local
  docker_cmd rmi -f dory/readiness-saved:local
  docker_cmd load -i "$WORKDIR/readiness-image.tar"
  docker_cmd image inspect dory/readiness-saved:local >/dev/null
  docker_cmd rm -f dory-readiness-limits >/dev/null 2>&1 || true
  docker_cmd run -d --name dory-readiness-limits --memory 128m --cpus 0.5 \
    --label "dev.dory.readiness=$RUN_ID" dory/readiness-app:local
  docker_cmd inspect dory-readiness-limits --format '{{.HostConfig.Memory}} {{.HostConfig.NanoCpus}}' | grep -q '134217728 500000000'
  docker_cmd rm -f dory-readiness-limits >/dev/null
}

test_attached_output() {
  local out status
  set +e
  out="$(docker_cmd run --rm dory/readiness-app:local sh -c 'echo run-attach-ok' 2>&1)"
  status=$?
  set -e
  test "$status" = "0"
  printf '%s\n' "$out" | grep -q run-attach-ok

  docker_cmd rm -f dory-readiness-exec >/dev/null 2>&1 || true
  docker_cmd run -d --name dory-readiness-exec --label "dev.dory.readiness=$RUN_ID" dory/readiness-app:local
  out="$(docker_cmd exec dory-readiness-exec sh -c 'echo exec-attach-ok' 2>&1)"
  printf '%s\n' "$out" | grep -q exec-attach-ok
}

test_compose_stack() {
  export DORY_READINESS_RUN_ID="$RUN_ID"
  export DORY_READINESS_API_PORT="$HTTP_PORT"
  compose_cmd -f "$SUITE_DIR/compose/compose.yaml" -p "$PROJECT" up -d --build
  compose_cmd -f "$SUITE_DIR/compose/compose.yaml" -p "$PROJECT" ps
  wait_http "http://127.0.0.1:$HTTP_PORT" "compose-ok"
  compose_cmd -f "$SUITE_DIR/compose/compose.yaml" -p "$PROJECT" logs worker | grep -q worker-ok
  local vol
  vol="${PROJECT}_readiness-data"
  docker_cmd run --rm -v "$vol:/data" dory/readiness-app:local sh -c 'grep -q compose-ok /data/api-response.txt && grep -q worker-ok /data/worker.txt'
}

bootstrap_kubernetes() {
  if [ ! -x "$KUBECTL_BIN" ]; then
    echo "kubectl not found at $KUBECTL_BIN"
    return 1
  fi
  if kubectl_cmd get nodes >/dev/null 2>&1; then
    return 0
  fi
  docker_cmd rm -f dory-k8s >/dev/null 2>&1 || true
  docker_cmd run -d --name dory-k8s --privileged \
    -p 6443:6443 \
    "$K3S_IMAGE" \
    server --disable=traefik --tls-san=127.0.0.1 --tls-san=host.docker.internal
  for _ in $(seq 1 90); do
    if [ "$(docker_cmd inspect -f '{{.State.Running}}' dory-k8s 2>/dev/null || true)" != "true" ]; then
      docker_cmd logs dory-k8s
      return 1
    fi
    if docker_cmd cp dory-k8s:/etc/rancher/k3s/k3s.yaml "$WORKDIR/dory-k3s.yaml" >/dev/null 2>&1; then
      mkdir -p "$(dirname "$KUBECONFIG_PATH")"
      cp "$WORKDIR/dory-k3s.yaml" "$KUBECONFIG_PATH"
      chmod 600 "$KUBECONFIG_PATH"
      if kubectl_cmd get nodes --no-headers 2>/dev/null | grep -q Ready; then
        kubectl_cmd get --raw /version >/dev/null
        return 0
      fi
    fi
    sleep 2
  done
  docker_cmd logs dory-k8s
  return 1
}

test_kubernetes_examples() {
  bootstrap_kubernetes
  kubectl_cmd apply -f "$SUITE_DIR/kubernetes/namespace.yaml"
  kubectl_cmd apply -f "$SUITE_DIR/kubernetes/configmap.yaml"
  kubectl_cmd apply -f "$SUITE_DIR/kubernetes/deployment.yaml"
  kubectl_cmd apply -f "$SUITE_DIR/kubernetes/service.yaml"
  kubectl_cmd -n dory-readiness rollout status deployment/readiness-web --timeout=180s
  kubectl_cmd -n dory-readiness delete job readiness-client --ignore-not-found=true
  kubectl_cmd apply -f "$SUITE_DIR/kubernetes/job.yaml"
  kubectl_cmd -n dory-readiness wait --for=condition=complete job/readiness-client --timeout=180s
  kubectl_cmd -n dory-readiness logs job/readiness-client >/dev/null
  kubectl_cmd get namespaces,deployments,services,pods,jobs -n dory-readiness
}

test_linux_machines() {
  docker_cmd build -t dory/readiness-machine:local "$SUITE_DIR/machines/alpine"
  docker_cmd rm -f dory-machine-readiness dory-machine-readiness-clone >/dev/null 2>&1 || true

  docker_cmd run -d --name dory-machine-readiness \
    --hostname readiness \
    --privileged \
    --cgroupns=host \
    --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
    --label dory.machine=alpine \
    --label dory.machine.version=3.20 \
    --label "dory.machine.arch=$(uname -m | sed 's/arm64/arm64/;s/x86_64/amd64/')" \
    --label dory.machine.user=root \
    -p "127.0.0.1::8080" \
    dory/readiness-machine:local

  docker_cmd inspect dory-machine-readiness --format '{{.State.Running}} {{index .Config.Labels "dory.machine"}}' | grep -q 'true alpine'
  docker_cmd exec dory-machine-readiness sh -c 'test -d /run && test -d /tmp && echo machine-exec-ok > /tmp/machine.txt'
  docker_cmd cp dory-machine-readiness:/tmp/machine.txt "$WORKDIR/machine.txt"
  grep -q machine-exec-ok "$WORKDIR/machine.txt"

  docker_cmd exec dory-machine-readiness sh -c 'mkdir -p /tmp/www && echo machine-http-ok > /tmp/www/index.html && /bin/busybox httpd -p 8080 -h /tmp/www'
  local port
  port="$(docker_cmd port dory-machine-readiness 8080/tcp | sed 's/.*://')"
  test -n "$port"
  wait_http "http://127.0.0.1:$port" "machine-http-ok"

  docker_cmd stop dory-machine-readiness
  docker_cmd inspect dory-machine-readiness --format '{{.State.Running}}' | grep -q false
  docker_cmd start dory-machine-readiness
  for _ in $(seq 1 20); do
    if docker_cmd inspect dory-machine-readiness --format '{{.State.Running}}' | grep -q true; then
      break
    fi
    sleep 1
  done
  docker_cmd exec dory-machine-readiness sh -c 'test -f /tmp/machine.txt'

  docker_cmd commit dory-machine-readiness dory/readiness-machine-snapshot:local >/dev/null
  docker_cmd run -d --name dory-machine-readiness-clone \
    --privileged --cgroupns=host \
    --label dory.machine=alpine \
    --label dory.machine.version=3.20 \
    dory/readiness-machine-snapshot:local
  docker_cmd exec dory-machine-readiness-clone sh -c 'test -f /tmp/machine.txt'
}

printf 'Dory readiness examples\n'
printf '  app:         %s\n' "$APP"
printf '  docker:      %s\n' "$DOCKER_BIN"
printf '  docker host: %s\n' "$DOCKER_HOST"
printf '  workdir:     %s\n' "$WORKDIR"

run_test docker-api test_docker_api
run_test compose-available test_compose_available
run_test build-image test_build_image
run_test run-http-and-logs test_run_http_and_logs
run_test exec-cp-volume-network test_exec_cp_volume_network
run_test save-load-limits test_save_load_limits
if [ "$STRICT_ATTACH" = "1" ]; then
  run_test attached-output test_attached_output
else
  skip_test attached-output "--skip-attach"
fi
run_test compose-stack test_compose_stack
if [ "$WITH_MACHINES" = "1" ]; then
  run_test linux-machines test_linux_machines
else
  skip_test linux-machines "--skip-machines"
fi
if [ "$WITH_KUBERNETES" = "1" ]; then
  run_test kubernetes-examples test_kubernetes_examples
else
  skip_test kubernetes-examples "pass --with-kubernetes"
fi

printf '\nResults: %s pass, %s fail, %s skip\n' "$PASS" "$FAIL" "$SKIP"
printf 'Details: %s\n' "$RESULTS"
test "$FAIL" = "0"
