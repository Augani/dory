#!/bin/bash
# Dory local Kubernetes bootstrap.
# Runs k3s as a privileged container inside Dory's daemon-managed shared engine VM
# and writes ~/.kube/dory-config. Requires doryd to be running.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DORY_CLI="${DORY_CLI:-$ROOT/scripts/dory}"
MACHINE="dory-k8s"
IMAGE="${DORY_K3S_IMAGE:-rancher/k3s:v1.36.2-k3s1}"
KUBECONFIG_PATH="${DORY_KUBECONFIG:-$HOME/.kube/dory-config}"
KUBECTL_BIN="${KUBECTL_BIN:-$(command -v kubectl 2>/dev/null || true)}"

echo "==> Checking Dory engine via doryd..."
"$DORY_CLI" version >/dev/null

echo "==> Pulling Kubernetes ($IMAGE)..."
"$DORY_CLI" pull "$IMAGE" >/dev/null

echo "==> Starting k3s inside Dory's shared engine..."
"$DORY_CLI" rm -f "$MACHINE" >/dev/null 2>&1 || true
"$DORY_CLI" create \
  --name "$MACHINE" \
  --privileged \
  -p 6443:6443 \
  "$IMAGE" \
  server --disable=traefik --tls-san=127.0.0.1 --tls-san=host.docker.internal >/dev/null
"$DORY_CLI" start "$MACHINE" >/dev/null

echo "==> Waiting for the Kubernetes node to become Ready..."
last_probe=""
for _ in $(seq 1 "${DORY_K3S_READY_POLLS:-90}"); do
  if "$DORY_CLI" inspect "$MACHINE" --format '{{.State.Running}}' 2>/dev/null | grep -qx true; then
    last_probe="$("$DORY_CLI" exec "$MACHINE" kubectl get nodes --no-headers 2>&1 || true)"
    if printf '%s\n' "$last_probe" | grep -q Ready; then
      break
    fi
  else
    echo "k3s container exited during startup:" >&2
    "$DORY_CLI" logs --tail 80 "$MACHINE" >&2 || true
    exit 1
  fi
  sleep "${DORY_K3S_READY_INTERVAL:-2}"
done

if ! printf '%s\n' "$last_probe" | grep -q Ready; then
  echo "k3s did not become Ready before the timeout:" >&2
  printf '%s\n' "$last_probe" >&2
  "$DORY_CLI" logs --tail 80 "$MACHINE" >&2 || true
  exit 1
fi

echo "==> Exporting kubeconfig to $KUBECONFIG_PATH..."
mkdir -p "$(dirname "$KUBECONFIG_PATH")"
"$DORY_CLI" exec "$MACHINE" cat /etc/rancher/k3s/k3s.yaml > "$KUBECONFIG_PATH"
chmod 600 "$KUBECONFIG_PATH"

if [ -n "$KUBECTL_BIN" ]; then
  echo "==> Waiting for localhost:6443 to answer..."
  for _ in $(seq 1 "${DORY_K3S_API_POLLS:-60}"); do
    if "$KUBECTL_BIN" --kubeconfig "$KUBECONFIG_PATH" get --raw /version >/dev/null 2>&1; then
      break
    fi
    sleep "${DORY_K3S_API_INTERVAL:-2}"
  done
fi

echo "Done. Dory's Kubernetes screen will show live pods."
echo "For kubectl on the command line:"
echo "    export KUBECONFIG=\"$KUBECONFIG_PATH\""
echo "    kubectl get pods -A"
