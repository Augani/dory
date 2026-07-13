#!/bin/bash
# Runs a real GitHub Actions workflow through checksum-pinned act on an empty disposable Dory engine.
set -euo pipefail

SOCKET=""
DOCKER=""
VERSION="${DORY_RELEASE_ACT_VERSION:-0.2.89}"
SHA256=""
RUNNER_IMAGE="${DORY_RELEASE_ACT_RUNNER_IMAGE:-node:20.19.5-bookworm-slim@sha256:9e70124bd00f47dd023e349cd587132ae61892acc0e47ed641416c3e18f401c3}"
WORKROOT=""
CONFIRM=""

usage() {
  cat <<'EOF'
Usage: scripts/act-compatibility-gate.sh [required options] [options]

Required:
  --socket PATH       Unix socket for an already-running disposable Dory engine
  --docker PATH       Exact Docker CLI from the candidate runtime
  --workroot DIR      New evidence directory owned by this gate
  --confirm TOKEN     Must be ISOLATED-ENGINE-ACT

Options:
  --version VERSION   Exact nektos/act version (default: 0.2.89)
  --sha256 HASH       Archive SHA-256 (defaults to the published 0.2.89 Darwin host checksum)
  --runner-image REF  Digest-pinned runner image

The host act process talks to the supplied Dory socket. Runner containers receive the daemon's
guest-local unix:///var/run/docker.sock, never the macOS socket path. The gate refuses any existing
container, named volume, or custom network and returns those object counts to zero.
EOF
}

die() { echo "act compatibility gate: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --socket) need_value "$1" "$#"; SOCKET="$2"; shift 2 ;;
    --docker) need_value "$1" "$#"; DOCKER="$2"; shift 2 ;;
    --version) need_value "$1" "$#"; VERSION="$2"; shift 2 ;;
    --sha256) need_value "$1" "$#"; SHA256="$2"; shift 2 ;;
    --runner-image) need_value "$1" "$#"; RUNNER_IMAGE="$2"; shift 2 ;;
    --workroot) need_value "$1" "$#"; WORKROOT="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ "$CONFIRM" = ISOLATED-ENGINE-ACT ] || die "requires --confirm ISOLATED-ENGINE-ACT"
[ -S "$SOCKET" ] || die "socket is unavailable: $SOCKET"
[ -x "$DOCKER" ] || die "Docker CLI is unavailable: $DOCKER"
printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "--version must be an exact semantic version"
case "$(uname -m)" in
  arm64) ARCHIVE_ARCH=arm64; DEFAULT_SHA=48ae218af96725f7635a66de2b87e1e346893b02add0f16b92f560296b2151fc ;;
  x86_64) ARCHIVE_ARCH=x86_64; DEFAULT_SHA=41b31488e7c254baec31cce12c7dade3e35973b8a31b9486206ad43f233d814e ;;
  *) die "unsupported macOS architecture: $(uname -m)" ;;
esac
if [ -z "$SHA256" ]; then
  [ "$VERSION" = 0.2.89 ] \
    || die "--sha256 is required when --version differs from the pinned default"
  SHA256="$DEFAULT_SHA"
fi
printf '%s\n' "$SHA256" | grep -Eq '^[0-9a-f]{64}$' || die "--sha256 is invalid"
case "$RUNNER_IMAGE" in *@sha256:[0-9a-f][0-9a-f]*) ;; *) die "runner image must be digest-pinned" ;; esac
[ -n "$WORKROOT" ] || die "--workroot is required"
[ ! -e "$WORKROOT" ] || die "workroot already exists: $WORKROOT"
for command in curl python3 shasum tar; do
  command -v "$command" >/dev/null || die "missing required command: $command"
done

mkdir -p "$WORKROOT/evidence" "$WORKROOT/workspace/.github/workflows" "$WORKROOT/download"
WORKROOT="$(cd "$WORKROOT" && pwd)"
WORKSPACE="$WORKROOT/workspace"
EVIDENCE="$WORKROOT/evidence"
DOWNLOAD="$WORKROOT/download"
export DOCKER_HOST="unix://$SOCKET"
unset DOCKER_CONTEXT
docker_e() { "$DOCKER" "$@"; }
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
  cleanup_objects
  rm -rf "$DOWNLOAD"
}
trap cleanup EXIT INT TERM

object_counts > "$EVIDENCE/baseline.txt"
grep -qx 'containers=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing containers"
grep -qx 'volumes=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing named volumes"
grep -qx 'custom_networks=0' "$EVIDENCE/baseline.txt" || die "engine has pre-existing custom networks"

archive="$DOWNLOAD/act.tgz"
url="https://github.com/nektos/act/releases/download/v$VERSION/act_Darwin_$ARCHIVE_ARCH.tar.gz"
curl -fsSL --retry 3 --connect-timeout 15 --max-time 180 "$url" -o "$archive"
printf '%s  %s\n' "$SHA256" "$archive" | shasum -a 256 -c - > "$EVIDENCE/archive-checksum.txt"
tar -xzf "$archive" -C "$DOWNLOAD" act
[ -x "$DOWNLOAD/act" ] || die "verified act archive did not contain an executable"
"$DOWNLOAD/act" --version > "$EVIDENCE/act-version.txt"
grep -Eq "(^|[[:space:]])v?$VERSION([[:space:]]|$)" "$EVIDENCE/act-version.txt" \
  || die "act binary version differs from the requested release"

cat > "$WORKSPACE/.github/workflows/dory-act-smoke.yml" <<'YAML'
name: Dory act compatibility
on: workflow_dispatch
jobs:
  smoke:
    runs-on: ubuntu-latest
    steps:
      - name: Prove workspace and runner execution
        run: |
          test "$(cat host-sentinel.txt)" = "host-to-act"
          printf 'act-to-host\n' > act-sentinel.txt
          printf 'runner-exec=PASS\n'
YAML
printf 'host-to-act\n' > "$WORKSPACE/host-sentinel.txt"

(cd "$WORKSPACE" && \
  "$DOWNLOAD/act" workflow_dispatch \
    --workflows .github/workflows/dory-act-smoke.yml \
    --job smoke \
    --bind \
    --container-daemon-socket unix:///var/run/docker.sock \
    --platform "ubuntu-latest=$RUNNER_IMAGE" \
    --pull \
    --verbose) > "$EVIDENCE/act-run.log" 2> "$EVIDENCE/act-run.stderr"
grep -q 'runner-exec=PASS' "$EVIDENCE/act-run.log" \
  || die "act workflow did not execute its runner step"
grep -qx 'act-to-host' "$WORKSPACE/act-sentinel.txt" \
  || die "act runner write was not visible in the macOS workspace"

cleanup_objects
rm -rf "$DOWNLOAD"
object_counts > "$EVIDENCE/final.txt"
cmp -s "$EVIDENCE/baseline.txt" "$EVIDENCE/final.txt" \
  || die "act gate did not restore the exact empty object baseline"

cat > "$WORKROOT/manifest.txt.partial" <<EOF
status=PASS
act_version=$VERSION
act_archive_sha256=$SHA256
runner_image=$RUNNER_IMAGE
host_socket_routing=PASS
guest_local_socket_mount=PASS
workflow_execution=PASS
host_to_runner_workspace=PASS
runner_to_host_workspace=PASS
exact_baseline_cleanup=PASS
completed_epoch=$(date +%s)
EOF
mv "$WORKROOT/manifest.txt.partial" "$WORKROOT/manifest.txt"
trap - EXIT INT TERM
echo "act compatibility gate: PASS ($VERSION)"
