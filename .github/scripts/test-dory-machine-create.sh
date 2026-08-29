#!/bin/bash
# Offline regression test for the zero-option daemon-managed machine create path.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-machine-create-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/home"
: > "$TMP/kernel"
: > "$TMP/rootfs"

cat > "$TMP/dorydctl" <<'SH'
#!/bin/bash
set -euo pipefail

case "${1:-}" in
  component)
    # The production CLI probes installed-component paths even when explicit
    # test assets are available. Keep those probes offline and unresolved.
    exit 1
    ;;
  machine)
    printf '%s\n' "$@" > "$DORY_MACHINE_CREATE_CAPTURE"
    ;;
  *)
    echo "unexpected dorydctl command: $*" >&2
    exit 64
    ;;
esac
SH
chmod +x "$TMP/dorydctl"

capture="$TMP/create.args"
DORY_MACHINE_CREATE_CAPTURE="$capture" \
DORYDCTL_BIN="$TMP/dorydctl" \
DORY_SANDBOX_KERNEL="$TMP/kernel" \
DORY_SANDBOX_ROOTFS="$TMP/rootfs" \
DORY_MACHINE_ENV_ALLOW_LIST='ANTHROPIC_API_KEY,GH_TOKEN' \
ANTHROPIC_API_KEY='opaque-anthropic-secret' \
GH_TOKEN='opaque-github-secret' \
HOME="$TMP/home" \
  /bin/bash "$ROOT/scripts/dory" machine create test

expected="$TMP/expected.args"
printf '%s\n' \
  machine \
  create \
  test \
  --kernel \
  "$TMP/kernel" \
  --rootfs \
  "$TMP/rootfs" > "$expected"
cmp "$expected" "$capture"

rm -f "$capture"
if DORY_MACHINE_CREATE_CAPTURE="$capture" \
  DORYDCTL_BIN="$TMP/dorydctl" \
  DORY_SANDBOX_KERNEL="$TMP/kernel" \
  DORY_SANDBOX_ROOTFS="$TMP/rootfs" \
  HOME="$TMP/home" \
  /bin/bash "$ROOT/scripts/dory" machine create rejected --env API_TOKEN=opaque-value \
    >"$TMP/rejected.out" 2>"$TMP/rejected.err"; then
  echo "persistent machine environment was accepted" >&2
  exit 1
fi
grep -F "machine create no longer accepts persistent environment values" "$TMP/rejected.err" >/dev/null
[ ! -e "$capture" ] || {
  echo "dorydctl was invoked for rejected persistent environment" >&2
  exit 1
}

# Sandbox lifecycle/credential grants use the typed machine-create contract. The shell must not
# resurrect the retired persistent environment escape hatch, and retained status must consume the
# daemon's safe first-class projection rather than a raw environment payload.
grep -F 'create_args+=(--sandbox --sandbox-ssh-agent' "$ROOT/scripts/dory" >/dev/null
grep -F 'policy = status.get("sandboxPolicy")' "$ROOT/scripts/dory" >/dev/null
if grep -F 'create_args+=(--env "DORY_SANDBOX' "$ROOT/scripts/dory" >/dev/null; then
  echo "sandbox creation still persists lifecycle authority through raw environment" >&2
  exit 1
fi
if grep -F 'environment = {row["key"]: row["value"] for row in status.get("env", [])}' \
  "$ROOT/scripts/dory" >/dev/null; then
  echo "sandbox status still depends on raw environment disclosure" >&2
  exit 1
fi

echo "dory machine create regression test: PASS"
