#!/bin/bash
# Qualify immutable, notarized public artifacts before any GitHub/Homebrew publication. The
# 8-hour endurance gate and 25-hour same-connection TCP gate share one isolated engine and run
# concurrently, reducing qualification wall time to 25 hours without weakening either duration.
set -euo pipefail

BUILD_DIR=""
VERSION=""
BUILD=""
SOURCE_COMMIT=""
QUALIFICATION_ROOT="${DORY_RELEASE_QUALIFICATION_ROOT:-$HOME/.dory-release-qualification}"
LONG_DURATION=90000
ENDURANCE_DURATION=28800
IMAGE="${DORY_RELEASE_QUALIFICATION_IMAGE:-}"
LOCK_IMAGE="${DORY_SOURCE_GATE_IMAGE:-}"
SSH_CLIENT_IMAGE="${DORY_RELEASE_SSH_CLIENT_IMAGE:-}"
NONNATIVE_NIX_IMAGE="${DORY_RELEASE_NONNATIVE_NIX_IMAGE:-nixos/nix@sha256:898e3874bc80a8fbd7df6001b6c83d6e0c904a942e3a4cdf8a89881458333cac}"
NONNATIVE_ARCH_IMAGE="${DORY_RELEASE_NONNATIVE_ARCH_IMAGE:-archlinux@sha256:2b4d67033863d9f495dfd0f52ad8b451fae84adb71b4bdf63f69d10643df2403}"
NONNATIVE_DEBIAN_IMAGE="${DORY_RELEASE_NONNATIVE_DEBIAN_IMAGE:-debian@sha256:3a953985c225a97dfb5a8f1ddc6a3ecefefc35ef51f537075e08941305045a1e}"
TESTCONTAINERS_VERSION="${DORY_RELEASE_TESTCONTAINERS_VERSION:-12.0.4}"
DEVCONTAINERS_VERSION="${DORY_RELEASE_DEVCONTAINERS_VERSION:-0.87.0}"
ACT_VERSION="${DORY_RELEASE_ACT_VERSION:-0.2.89}"
LOCALSTACK_IMAGE="${DORY_RELEASE_LOCALSTACK_IMAGE:-localstack/localstack:4.14.0@sha256:3ebc37595918b8accb852f8048fef2aff047d465167edd655528065b07bc364a}"
TILT_VERSION="${DORY_RELEASE_TILT_VERSION:-0.37.5}"
SUPABASE_VERSION="${DORY_RELEASE_SUPABASE_VERSION:-2.109.1}"
K3S_IMAGE="${DORY_RELEASE_K3S_IMAGE:-rancher/k3s:v1.36.2-k3s1@sha256:6a47cea22c4b834d4ba72c89d291696b79ebe406251f90b446e4dff03513dd87}"
K8S_WORKLOAD_IMAGE="${DORY_RELEASE_K8S_WORKLOAD_IMAGE:-nginx:alpine@sha256:54f2a904c251d5a34adf545a72d32515a15e08418dae0266e23be2e18c66fefa}"
SKAFFOLD_VERSION="${DORY_RELEASE_SKAFFOLD_VERSION:-2.23.0}"
ECR_REGISTRY="${DORY_RELEASE_ECR_REGISTRY:-}"
ECR_REPOSITORY="${DORY_RELEASE_ECR_REPOSITORY:-}"
ECR_REGION="${DORY_RELEASE_ECR_REGION:-}"
MIN_FREE_GB=20
CONFIRM=""
DEVELOPMENT_UNNOTARIZED="${DORY_ALLOW_UNNOTARIZED_QUALIFICATION:-0}"

usage() {
  cat <<EOF
Usage: scripts/qualify-release-candidate.sh [required options] [options]

Required:
  --build-dir DIR       Downloaded public release artifacts and release-manifest.json
  --version VERSION     Exact marketing version
  --build BUILD         Exact CFBundleVersion / release build
  --source-commit SHA   Exact 40-character Git commit
  --confirm TOKEN       Must be QUALIFY-EXACT-DORY-RELEASE

Options:
  --qualification-root DIR  Durable runner-local evidence root
  --long-duration SECONDS   Same-connection duration (default: $LONG_DURATION)
  --endurance-duration SEC  Resource/Compose duration (default: $ENDURANCE_DURATION)
  --image REF                Digest-pinned Alpine-compatible fixture image
  --lock-image REF           Digest-pinned Python image for cross-container bind locks
  --ssh-client-image REF     Digest-pinned image containing sh and ssh-add
  --nonnative-nix-image REF  Digest-pinned linux/amd64 Nix 2.34.7 image
  --nonnative-arch-image REF Digest-pinned linux/amd64 Arch image
  --nonnative-debian-image REF Digest-pinned linux/amd64 Debian trixie image
  --testcontainers-version V Exact npm Testcontainers version (default: $TESTCONTAINERS_VERSION)
  --devcontainers-version V  Exact @devcontainers/cli version (default: $DEVCONTAINERS_VERSION)
  --act-version VERSION       Exact nektos/act version (default: $ACT_VERSION)
  --localstack-image REF      Digest-pinned LocalStack image (default: $LOCALSTACK_IMAGE)
  --tilt-version VERSION      Exact Tilt version (default: $TILT_VERSION)
  --supabase-version VERSION  Exact Supabase CLI version (default: $SUPABASE_VERSION)
  --k3s-image REF             Digest-pinned k3s image (default: $K3S_IMAGE)
  --k8s-workload-image REF    Digest-pinned Kubernetes fixture (default: $K8S_WORKLOAD_IMAGE)
  --skaffold-version VERSION  Exact Skaffold version (default: $SKAFFOLD_VERSION)
  --ecr-registry HOST         Disposable ECR registry host
  --ecr-repository NAME       Pre-created disposable ECR repository
  --ecr-region REGION         AWS region for the disposable repository
  --min-free-gb N            Initial host free-space floor (default: $MIN_FREE_GB)
  --help                     Show this help

Release qualification requires at least 28,800 endurance seconds and more than 86,400 TCP
seconds. Shorter values are accepted only when DORY_ALLOW_SHORT_QUALIFICATION=1 and are recorded as
non-release development evidence. The script never publishes and never touches a pre-existing Dory
home; it owns one run-attempt-specific HOME beneath the qualification root.
For local harness validation only, DORY_ALLOW_UNNOTARIZED_QUALIFICATION=1 is accepted together with
DORY_ALLOW_SHORT_QUALIFICATION=1; its completion record is permanently non-release-qualifying.
EOF
}

die() { echo "release qualification: $*" >&2; exit 2; }
need_value() { [ "$2" -ge 2 ] || die "$1 requires a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --build-dir) need_value "$1" "$#"; BUILD_DIR="$2"; shift 2 ;;
    --version) need_value "$1" "$#"; VERSION="$2"; shift 2 ;;
    --build) need_value "$1" "$#"; BUILD="$2"; shift 2 ;;
    --source-commit) need_value "$1" "$#"; SOURCE_COMMIT="$2"; shift 2 ;;
    --qualification-root) need_value "$1" "$#"; QUALIFICATION_ROOT="$2"; shift 2 ;;
    --long-duration) need_value "$1" "$#"; LONG_DURATION="$2"; shift 2 ;;
    --endurance-duration) need_value "$1" "$#"; ENDURANCE_DURATION="$2"; shift 2 ;;
    --image) need_value "$1" "$#"; IMAGE="$2"; shift 2 ;;
    --lock-image) need_value "$1" "$#"; LOCK_IMAGE="$2"; shift 2 ;;
    --ssh-client-image) need_value "$1" "$#"; SSH_CLIENT_IMAGE="$2"; shift 2 ;;
    --nonnative-nix-image) need_value "$1" "$#"; NONNATIVE_NIX_IMAGE="$2"; shift 2 ;;
    --nonnative-arch-image) need_value "$1" "$#"; NONNATIVE_ARCH_IMAGE="$2"; shift 2 ;;
    --nonnative-debian-image) need_value "$1" "$#"; NONNATIVE_DEBIAN_IMAGE="$2"; shift 2 ;;
    --testcontainers-version) need_value "$1" "$#"; TESTCONTAINERS_VERSION="$2"; shift 2 ;;
    --devcontainers-version) need_value "$1" "$#"; DEVCONTAINERS_VERSION="$2"; shift 2 ;;
    --act-version) need_value "$1" "$#"; ACT_VERSION="$2"; shift 2 ;;
    --localstack-image) need_value "$1" "$#"; LOCALSTACK_IMAGE="$2"; shift 2 ;;
    --tilt-version) need_value "$1" "$#"; TILT_VERSION="$2"; shift 2 ;;
    --supabase-version) need_value "$1" "$#"; SUPABASE_VERSION="$2"; shift 2 ;;
    --k3s-image) need_value "$1" "$#"; K3S_IMAGE="$2"; shift 2 ;;
    --k8s-workload-image) need_value "$1" "$#"; K8S_WORKLOAD_IMAGE="$2"; shift 2 ;;
    --skaffold-version) need_value "$1" "$#"; SKAFFOLD_VERSION="$2"; shift 2 ;;
    --ecr-registry) need_value "$1" "$#"; ECR_REGISTRY="$2"; shift 2 ;;
    --ecr-repository) need_value "$1" "$#"; ECR_REPOSITORY="$2"; shift 2 ;;
    --ecr-region) need_value "$1" "$#"; ECR_REGION="$2"; shift 2 ;;
    --min-free-gb) need_value "$1" "$#"; MIN_FREE_GB="$2"; shift 2 ;;
    --confirm) need_value "$1" "$#"; CONFIRM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

positive_integer() {
  case "$2" in ''|*[!0-9]*) die "$1 must be a positive integer" ;; esac
  [ "$2" -gt 0 ] || die "$1 must be a positive integer"
}

bounded() {
  local limit="$1" pid started rc
  shift
  "$@" &
  pid=$!
  started=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    if [ $((SECONDS - started)) -ge "$limit" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      for _ in $(seq 1 50); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
      done
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.1
  done
  if wait "$pid"; then rc=0; else rc=$?; fi
  return "$rc"
}

[ "$CONFIRM" = "QUALIFY-EXACT-DORY-RELEASE" ] \
  || die "requires --confirm QUALIFY-EXACT-DORY-RELEASE"
[ -n "$BUILD_DIR" ] || die "--build-dir is required"
[ -d "$BUILD_DIR" ] || die "build directory is unavailable: $BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
[ -n "$VERSION" ] || die "--version is required"
[ -n "$BUILD" ] || die "--build is required"
printf '%s\n' "$SOURCE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' \
  || die "--source-commit must be a full lowercase Git SHA"
positive_integer long-duration "$LONG_DURATION"
positive_integer endurance-duration "$ENDURANCE_DURATION"
positive_integer min-free-gb "$MIN_FREE_GB"
printf '%s\n' "$IMAGE" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
  || die "--image (or DORY_RELEASE_QUALIFICATION_IMAGE) must be digest-pinned"
printf '%s\n' "$LOCK_IMAGE" | grep -Eq '@sha256:[0-9a-f]{64}$' \
  || die "--lock-image (or DORY_SOURCE_GATE_IMAGE) must be digest-pinned"
printf '%s\n' "$SSH_CLIENT_IMAGE" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
  || die "--ssh-client-image (or DORY_RELEASE_SSH_CLIENT_IMAGE) must be digest-pinned"
printf '%s\n' "$NONNATIVE_NIX_IMAGE" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
  || die "--nonnative-nix-image must be digest-pinned"
printf '%s\n' "$NONNATIVE_ARCH_IMAGE" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
  || die "--nonnative-arch-image must be digest-pinned"
printf '%s\n' "$NONNATIVE_DEBIAN_IMAGE" | grep -Eq '^.+@sha256:[0-9a-f]{64}$' \
  || die "--nonnative-debian-image must be digest-pinned"
printf '%s\n' "$TESTCONTAINERS_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$' \
  || die "--testcontainers-version must be an exact npm semver"
printf '%s\n' "$DEVCONTAINERS_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$' \
  || die "--devcontainers-version must be an exact npm semver"
printf '%s\n' "$ACT_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "--act-version must be an exact semantic version"
case "$LOCALSTACK_IMAGE" in *@sha256:[0-9a-f][0-9a-f]*) ;; \
  *) die "--localstack-image must be digest-pinned" ;; esac
printf '%s\n' "$TILT_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "--tilt-version must be an exact semantic version"
printf '%s\n' "$SUPABASE_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "--supabase-version must be an exact semantic version"
printf '%s\n' "$K3S_IMAGE" | grep -Eq '@sha256:[0-9a-f]{64}$' \
  || die "--k3s-image must be digest-pinned"
printf '%s\n' "$K8S_WORKLOAD_IMAGE" | grep -Eq '@sha256:[0-9a-f]{64}$' \
  || die "--k8s-workload-image must be digest-pinned"
printf '%s\n' "$SKAFFOLD_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "--skaffold-version must be an exact semantic version"
printf '%s\n' "$ECR_REGISTRY" | grep -Eq '^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com$' \
  || die "--ecr-registry (or DORY_RELEASE_ECR_REGISTRY) must be an ECR registry host"
printf '%s\n' "$ECR_REPOSITORY" | grep -Eq '^[a-z0-9]+([._/-][a-z0-9]+)*$' \
  || die "--ecr-repository (or DORY_RELEASE_ECR_REPOSITORY) is required"
printf '%s\n' "$ECR_REGION" | grep -Eq '^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$' \
  || die "--ecr-region (or DORY_RELEASE_ECR_REGION) is invalid"
if [ "${DORY_ALLOW_SHORT_QUALIFICATION:-0}" != 1 ]; then
  [ "$LONG_DURATION" -gt 86400 ] \
    || die "release qualification must keep one TCP connection beyond 24 hours"
  [ "$ENDURANCE_DURATION" -ge 28800 ] \
    || die "release qualification requires at least eight endurance hours"
fi
case "$DEVELOPMENT_UNNOTARIZED" in 0|1) ;; *) die "DORY_ALLOW_UNNOTARIZED_QUALIFICATION must be 0 or 1" ;; esac
if [ "$DEVELOPMENT_UNNOTARIZED" = 1 ] && [ "${DORY_ALLOW_SHORT_QUALIFICATION:-0}" != 1 ]; then
  die "unnotarized qualification is allowed only for explicitly shortened development runs"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
for command in caffeinate codesign curl ditto node npm pmset python3 shasum spctl tar xcodebuild xcrun; do
  command -v "$command" >/dev/null || die "missing required command: $command"
done

MANIFEST="$BUILD_DIR/release-manifest.json"
[ -s "$MANIFEST" ] || die "release manifest is missing: $MANIFEST"
python3 - "$BUILD_DIR" "$VERSION" "$BUILD" "$SOURCE_COMMIT" "$DEVELOPMENT_UNNOTARIZED" <<'PY'
import hashlib
import json
import os
import pathlib
import sys

root, version, build, source_commit, development_unnotarized = sys.argv[1:]
with open(os.path.join(root, "release-manifest.json"), encoding="utf-8") as handle:
    manifest = json.load(handle)
assert manifest.get("schemaVersion") == 2, "unexpected release manifest schema"
assert manifest.get("version") == version, "release manifest version mismatch"
assert str(manifest.get("build")) == build, "release manifest build mismatch"
assert manifest.get("sourceCommit") == source_commit, "release manifest source commit mismatch"
assert manifest.get("publicRelease") is True or development_unnotarized == "1", \
    "candidate is not marked public"
assert manifest.get("bundleEngine") is True, "candidate omits the engine"
assert manifest.get("notarized") is True or development_unnotarized == "1", \
    "candidate is not marked notarized"
assert manifest.get("variants") == "arm64", "candidate is not Apple-Silicon-only"
required = {
    f"Dory-{version}-arm64.zip", f"Dory-{version}.zip",
    f"Dory-{version}-arm64.dmg", f"Dory-{version}.dmg",
    f"Dory-{version}-lite.zip", f"Dory-{version}-app-update.zip",
    f"dory-engine-{version}-arm64.tar.gz", "appcast.xml",
    f"Dory-{version}.cdx.json",
}
if development_unnotarized == "1":
    # A local Developer ID candidate cannot truthfully carry the public/notarized appcast contract.
    # The completion record is permanently marked non-release-qualifying below.
    required.discard("appcast.xml")
records = manifest.get("artifacts")
assert isinstance(records, list), "release manifest artifacts are missing"
by_name = {record.get("name"): record for record in records}
assert not (required - set(by_name)), f"release manifest omits: {sorted(required - set(by_name))}"
for name in required:
    path = os.path.join(root, name)
    assert os.path.isfile(path), f"candidate artifact is missing: {name}"
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    record = by_name[name]
    assert record.get("bytes") == os.path.getsize(path), f"candidate size mismatch: {name}"
    assert record.get("sha256") == digest.hexdigest(), f"candidate digest mismatch: {name}"
    assert pathlib.Path(record.get("path", "")).name == name, f"manifest path mismatch: {name}"
PY

# Bind immutable candidate identity before host/toolchain prerequisites. This preserves the
# no-mutation contract and makes a wrong source/artifact fail for that reason on every runner.
xcodebuild -version >/dev/null 2>&1 \
  || die "full Xcode is required; Command Line Tools alone cannot run migration tests"

RUN_ID="${GITHUB_RUN_ID:-manual}"
RUN_ATTEMPT="${GITHUB_RUN_ATTEMPT:-1}"
RUN_KEY="$RUN_ID-$RUN_ATTEMPT-$SOURCE_COMMIT"
WORKDIR="$QUALIFICATION_ROOT/$RUN_KEY"
ENGINE_HOME="$HOME/.dqe-$RUN_ID-$RUN_ATTEMPT"
MIGRATION_SOURCE_HOME="$HOME/.dqm-$RUN_ID-$RUN_ATTEMPT"
SOCKET="$ENGINE_HOME/.dory/engine.sock"
MIGRATION_SOURCE_SOCKET="$MIGRATION_SOURCE_HOME/.dory/engine.sock"
[ ! -e "$WORKDIR" ] || die "qualification path already exists; refusing to overwrite evidence: $WORKDIR"
[ ! -e "$ENGINE_HOME" ] || die "short qualification engine HOME already exists: $ENGINE_HOME"
[ ! -e "$MIGRATION_SOURCE_HOME" ] \
  || die "short migration source HOME already exists: $MIGRATION_SOURCE_HOME"
python3 - \
  "$SOCKET" \
  "$MIGRATION_SOURCE_SOCKET" \
  "$ENGINE_HOME/.dory/hv/docker-backend.sock" \
  "$ENGINE_HOME/.dory/hv/gvproxy-api.sock" <<'PY'
import os
import sys

for path in sys.argv[1:]:
    length = len(os.fsencode(path))
    if length > 103:
        raise SystemExit(f"qualification Unix socket path is {length} bytes (limit 103): {path}")
PY
[ "$(uname -s)" = Darwin ] || die "release qualification requires macOS"
[ "$(uname -m)" = arm64 ] || die "release qualification requires physical Apple silicon"
[ "$(sysctl -n kern.hv_support 2>/dev/null || printf 0)" = 1 ] \
  || die "Hypervisor.framework is unavailable"
[ "$(sysctl -in kern.hv_vmm_present 2>/dev/null || printf 0)" != 1 ] \
  || die "nested virtualization cannot qualify a release"
case "$(sysctl -n hw.model 2>/dev/null || printf unknown)" in
  VirtualMac*) die "VirtualMac cannot qualify a release" ;;
esac
umask 077
mkdir -p "$WORKDIR/evidence" "$WORKDIR/extracted-app" "$WORKDIR/extracted-runtime" \
  "$WORKDIR/docker-config/cli-plugins" "$ENGINE_HOME/gate-evidence"

{
  sw_vers
  uname -a
  printf 'hw.model='; sysctl -n hw.model
  printf 'kern.hv_support='; sysctl -n kern.hv_support
  printf 'kern.hv_vmm_present='; sysctl -in kern.hv_vmm_present 2>/dev/null || printf '0\n'
  printf 'hw.optional.arm64='; sysctl -in hw.optional.arm64 2>/dev/null || printf '0\n'
} > "$WORKDIR/evidence/host-facts.txt"

available_kb="$(df -Pk "$WORKDIR" | awk 'NR == 2 {print $4}')"
required_kb=$(((MIN_FREE_GB + 8) * 1024 * 1024))
[ "$available_kb" -ge "$required_kb" ] \
  || die "host has ${available_kb} KiB free; qualification requires ${required_kb} KiB so extraction and engine setup still leave the ${MIN_FREE_GB} GiB runtime reserve"

UPDATE_ZIP="$BUILD_DIR/Dory-$VERSION-app-update.zip"
RUNTIME_TAR="$BUILD_DIR/dory-engine-$VERSION-arm64.tar.gz"
ditto -x -k "$UPDATE_ZIP" "$WORKDIR/extracted-app"
APP="$WORKDIR/extracted-app/Dory.app"
[ -d "$APP" ] || die "Sparkle candidate did not extract exactly at Dory.app"
[ "$(find "$WORKDIR/extracted-app" -type d -name Dory.app -print | wc -l | tr -d ' ')" = 1 ] \
  || die "Sparkle candidate contains multiple Dory.app bundles"
tar -xzf "$RUNTIME_TAR" -C "$WORKDIR/extracted-runtime"
RUNTIME_DIR="$WORKDIR/extracted-runtime/dory-engine-$VERSION-arm64"
RUNTIME="$RUNTIME_DIR/dory-engine"
[ -x "$RUNTIME_DIR/bin/dory-hv" ] || die "standalone runtime dory-hv is missing"
CANDIDATE_DORY_HV_SHA="$(shasum -a 256 "$RUNTIME_DIR/bin/dory-hv" | awk '{print $1}')"
DOCKER="$APP/Contents/Helpers/docker"
KUBECTL="$APP/Contents/Helpers/kubectl"
[ -x "$RUNTIME" ] || die "standalone runtime launcher is missing"
[ -x "$DOCKER" ] || die "candidate Docker CLI is missing"
[ -x "$KUBECTL" ] || die "candidate kubectl CLI is missing"
[ -x "$APP/Contents/Helpers/docker-compose" ] || die "candidate Compose plugin is missing"

codesign --verify --strict --deep "$APP"
codesign -dv --verbose=4 "$APP" 2> "$WORKDIR/evidence/codesign-details.txt"
grep -q 'Authority=Developer ID Application' "$WORKDIR/evidence/codesign-details.txt" \
  || die "candidate is not Developer ID signed"
# shellcheck source=gvproxy-payload.sh
source scripts/gvproxy-payload.sh
GVPROXY="$APP/Contents/Helpers/gvproxy"
GVPROXY_PROVENANCE="$APP/Contents/Resources/gvproxy-provenance.txt"
PAYLOAD_INVENTORY="$APP/Contents/Resources/dory-payload-sha256.txt"
dory_gvproxy_validate_overrides
dory_verify_signed_gvproxy_payload "$GVPROXY" "$GVPROXY_PROVENANCE" "$PAYLOAD_INVENTORY" \
  || die "candidate gvproxy is not bound to its reproducible build and signed payload inventory"
CANDIDATE_GVPROXY_SHA="$(dory_gvproxy_file_sha256 "$GVPROXY")"
CANDIDATE_GVPROXY_BUILD_SHA="$(dory_gvproxy_expected_sha256)"
if [ "$DEVELOPMENT_UNNOTARIZED" = 0 ]; then
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=4 "$APP" \
    > "$WORKDIR/evidence/gatekeeper-assessment.txt" 2>&1
  ! grep -qi 'assessment system is disabled' "$WORKDIR/evidence/gatekeeper-assessment.txt" \
    || die "Gatekeeper assessments are disabled on the qualification host"
  grep -q 'source=Notarized Developer ID' "$WORKDIR/evidence/gatekeeper-assessment.txt" \
    || die "Gatekeeper did not accept the notarized Developer ID candidate"
else
  echo "development-only: notarization validation skipped" \
    > "$WORKDIR/evidence/notarization-development-skip.txt"
fi
if [ "$DEVELOPMENT_UNNOTARIZED" = 0 ]; then
  scripts/verify-sparkle-update.sh "$APP" "$UPDATE_ZIP" "$BUILD_DIR/appcast.xml" \
    > "$WORKDIR/evidence/sparkle-verification.txt"
else
  echo "development-only: public Sparkle signing validation skipped" \
    > "$WORKDIR/evidence/sparkle-development-skip.txt"
fi
for helper in dory-hv gvproxy dory-dataplane-proxy; do
  cmp "$RUNTIME_DIR/bin/$helper" "$APP/Contents/Helpers/$helper" \
    || die "standalone runtime $helper differs from the qualified app"
done
cmp "$RUNTIME_DIR/share/dory/dory-hv-kernel-arm64.lzfse" \
  "$APP/Contents/Resources/dory-hv-kernel-arm64.lzfse" \
  || die "standalone runtime kernel differs from the qualified app"
cmp "$RUNTIME_DIR/share/dory/dory-engine-rootfs.ext4.lzfse" \
  "$APP/Contents/Resources/dory-engine-rootfs-arm64.ext4.lzfse" \
  || die "standalone runtime rootfs differs from the qualified app"
cmp "$RUNTIME_DIR/share/dory/dory-agent-linux-arm64" \
  "$APP/Contents/Resources/dory-agent-linux-arm64" \
  || die "standalone runtime guest agent differs from the qualified app"

bounded 600 scripts/offline-bundled-boot-gate.sh \
  --runtime "$RUNTIME_DIR" \
  --workroot "$WORKDIR/evidence/offline-bundled-boot" \
  --release-candidate \
  --confirm DISPOSABLE-RUNTIME-OFFLINE-CACHE \
  > "$WORKDIR/evidence/offline-bundled-boot.log" 2>&1 \
  || die "exact bundled/cached offline boot gate failed"
offline_boot_manifest="$(find "$WORKDIR/evidence/offline-bundled-boot" \
  -name manifest.txt -type f -print -quit)"
[ -s "$offline_boot_manifest" ] || die "offline bundled boot manifest is missing"
for proof in status fresh_bundled_boot cached_boot_without_bundle_sources \
  dead_proxy_environment host_tcp_dependency_absence prepared_assets_unchanged; do
  grep -qx "$proof=PASS" "$offline_boot_manifest" \
    || die "offline bundled boot evidence does not prove $proof"
done
grep -qx 'release_qualifying=true' "$offline_boot_manifest" \
  || die "offline bundled boot evidence is not bound to the exact candidate"
ln -s "$DOCKER" "$WORKDIR/docker"
ln -s "$APP/Contents/Helpers/docker-compose" "$WORKDIR/docker-config/cli-plugins/docker-compose"
ln -s "$APP/Contents/Helpers/docker-buildx" "$WORKDIR/docker-config/cli-plugins/docker-buildx"
export PATH="$WORKDIR:$PATH"
export DOCKER_CONFIG="$WORKDIR/docker-config"

mkdir -p "$WORKDIR/evidence/gvproxy-qemu-switch"
bounded 30 scripts/gvproxy-qemu-switch-gate.py \
  "$GVPROXY" \
  --expected-sha256 "$CANDIDATE_GVPROXY_SHA" \
  --provenance "$GVPROXY_PROVENANCE" \
  --evidence "$WORKDIR/evidence/gvproxy-qemu-switch/manifest.txt" \
  > "$WORKDIR/evidence/gvproxy-qemu-switch.log" 2>&1 \
  || die "exact gvproxy independent bidirectional LAN switch-port gate failed"
qemu_switch_manifest="$WORKDIR/evidence/gvproxy-qemu-switch/manifest.txt"
for proof in lan_to_guest guest_to_lan; do
  grep -qx "$proof=PASS" "$qemu_switch_manifest" \
    || die "gvproxy QEMU switch evidence does not prove $proof"
done
grep -qx "gvproxy_sha256=$CANDIDATE_GVPROXY_SHA" \
  "$qemu_switch_manifest" \
  || die "gvproxy QEMU switch gate used the wrong binary"
grep -qx "gvproxy_build_sha256=$CANDIDATE_GVPROXY_BUILD_SHA" \
  "$qemu_switch_manifest" \
  || die "gvproxy QEMU switch gate used the wrong reproducible build"
grep -qx 'release_qualifying=true' "$qemu_switch_manifest" \
  || die "gvproxy QEMU switch evidence is not release qualifying"

bounded 900 scripts/managed-data-drive-gate.sh \
  --runtime "$RUNTIME_DIR" \
  --docker "$DOCKER" \
  --image "$IMAGE" \
  --workroot "$WORKDIR/evidence/managed-data-drive" \
  > "$WORKDIR/evidence/managed-data-drive.log" 2>&1 \
  || die "managed data-drive persistence/fail-closed gate failed"
drive_summary="$(find "$WORKDIR/evidence/managed-data-drive" -name summary.txt -type f -print -quit)"
[ -s "$drive_summary" ] || die "managed data-drive summary is missing"
for proof in status fresh_drive_default explicit_drive_status running_drive_mismatch_rejected \
  lost_drive_identity_recovered lost_drive_identity_mismatch_rejected alternate_drive_untouched \
  unwritable_drive_rejected_cleanly missing_external_drive_rejected concurrent_attach_rejected \
  alias_concurrent_attach_rejected manifest_uuid_identity image_persistence \
  stopped_missing_selected_drive_rejected \
  container_writable_layer_persistence named_volume_persistence custom_network_persistence \
  transient_runtime_replacement durable_selection_survives_runtime_reset; do
  grep -qx "$proof=PASS" "$drive_summary" \
    || die "managed data-drive summary does not prove $proof"
done

bounded 180 scripts/data-drive-volume-identity-gate.sh \
  --dory-hv "$RUNTIME_DIR/bin/dory-hv" \
  --workroot "$WORKDIR/evidence/data-drive-volume-identity" \
  > "$WORKDIR/evidence/data-drive-volume-identity.log" 2>&1 \
  || die "data-drive APFS volume-identity gate failed"
volume_identity_summary="$(find "$WORKDIR/evidence/data-drive-volume-identity" \
  -name summary.txt -type f -print -quit)"
[ -s "$volume_identity_summary" ] || die "data-drive volume-identity summary is missing"
for proof in status external_volume_identity durable_selection_outside_runtime_state \
  bookmark_volume_rename_recovery missing_volume_shadow_prevention \
  same_name_wrong_volume_rejected original_volume_reaccepted; do
  grep -qx "$proof=PASS" "$volume_identity_summary" \
    || die "data-drive volume-identity summary does not prove $proof"
done
grep -qx "dory_hv_sha256=$CANDIDATE_DORY_HV_SHA" "$volume_identity_summary" \
  || die "data-drive volume-identity gate used the wrong dory-hv"

bounded 1200 scripts/native-ipv6-gate.sh \
  --dory-hv "$RUNTIME_DIR/bin/dory-hv" \
  --gvproxy "$RUNTIME_DIR/bin/gvproxy" \
  --gvproxy-provenance "$GVPROXY_PROVENANCE" \
  --payload-inventory "$PAYLOAD_INVENTORY" \
  --kernel "$RUNTIME_DIR/share/dory/dory-hv-kernel-arm64.lzfse" \
  --rootfs "$RUNTIME_DIR/share/dory/dory-engine-rootfs.ext4.lzfse" \
  --docker "$DOCKER" \
  --workroot "$WORKDIR/evidence/native-ipv6" \
  --require-external \
  > "$WORKDIR/evidence/native-ipv6.log" 2>&1 \
  || die "native IPv6 address/DNS/registry/TCP/restart gate failed"
ipv6_manifest="$(find "$WORKDIR/evidence/native-ipv6" -name manifest.txt -type f -print -quit)"
[ -s "$ipv6_manifest" ] || die "native IPv6 manifest is missing"
for proof in status fresh_boot restart docker_bridge_ipv6 container_global_ipv6 dns_aaaa \
  registry_aaaa ipv6_tcp_loopback ipv6_localhost_publish external_ipv6_tcp; do
  grep -qx "$proof=PASS" "$ipv6_manifest" \
    || die "native IPv6 manifest does not prove $proof"
done
grep -qx 'release_qualifying=true' "$ipv6_manifest" \
  || die "native IPv6 gate did not use a real external IPv6 route"

bounded 900 scripts/data-disk-growth-gate.sh \
  --runtime "$RUNTIME_DIR" \
  --docker "$DOCKER" \
  --image "$IMAGE" \
  --workroot "$WORKDIR/evidence/data-disk-growth" \
  > "$WORKDIR/evidence/data-disk-growth.log" 2>&1 \
  || die "16→128 GiB growth/sparse-trim/persistence gate failed"
growth_summary="$(find "$WORKDIR/evidence/data-disk-growth" -name summary.txt -type f -print -quit)"
[ -s "$growth_summary" ] || die "data-disk growth summary is missing"
grep -qx 'status=PASS' "$growth_summary" || die "data-disk growth summary is not PASS"
grep -qx 'sparse_allocation=PASS' "$growth_summary" \
  || die "data-disk growth did not remain sparse"
grep -qx 'discard_reclaim=PASS' "$growth_summary" \
  || die "data-disk growth did not reclaim deleted blocks"
grep -qx 'named_volume_restart_persistence=PASS' "$growth_summary" \
  || die "data-disk growth lost named-volume data across restart"

ENGINE_STARTED=0
MIGRATION_SOURCE_STARTED=0
LONG_PID=""
ENDURANCE_PID=""
CAFFEINATE_PID=""
NEXT_POWER_CHECK=0
stop_power_assertion() {
  local pid="${CAFFEINATE_PID:-}"
  [ -n "$pid" ] || return 0
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  CAFFEINATE_PID=""
}
assert_stable_power() {
  local power compact
  power="$(pmset -g batt)"
  compact="$(printf '%s' "$power" | tr '\n' ';')"
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$compact" \
    >> "$WORKDIR/evidence/power-history.tsv"
  grep -Fq "Now drawing from 'AC Power'" <<< "$power" \
    || die "qualification host lost AC power"
  [ -n "$CAFFEINATE_PID" ] && kill -0 "$CAFFEINATE_PID" 2>/dev/null \
    || die "qualification sleep-prevention assertion exited"
}
start_power_assertion() {
  local power assertions
  power="$(pmset -g batt)"
  printf '%s\n' "$power" > "$WORKDIR/evidence/power-source.txt"
  grep -Fq "Now drawing from 'AC Power'" <<< "$power" \
    || die "25-hour qualification requires stable AC power"
  /usr/bin/caffeinate -is -w $$ \
    > "$WORKDIR/evidence/caffeinate.log" 2>&1 &
  CAFFEINATE_PID=$!
  sleep 0.2
  kill -0 "$CAFFEINATE_PID" 2>/dev/null \
    || die "could not establish the 25-hour sleep-prevention assertion"
  assertions="$(pmset -g assertions)"
  printf '%s\n' "$assertions" > "$WORKDIR/evidence/power-assertions.txt"
  grep -F "pid $CAFFEINATE_PID(caffeinate)" <<< "$assertions" \
    | grep -Fq 'PreventUserIdleSystemSleep' \
    || die "caffeinate did not hold PreventUserIdleSystemSleep"
  grep -F "pid $CAFFEINATE_PID(caffeinate)" <<< "$assertions" \
    | grep -Fq 'PreventSystemSleep' \
    || die "caffeinate did not hold PreventSystemSleep"
  printf 'status=PASS\nflags=-is\ndisplay_sleep_prevented=false\n' \
    > "$WORKDIR/evidence/power-assertion-manifest.txt"
  printf 'checked_utc\tpmset_state\n' > "$WORKDIR/evidence/power-history.tsv"
  assert_stable_power
  NEXT_POWER_CHECK=$((SECONDS + 60))
}
owned_engine_pids_for() {
  local home="$1"
  ps axww -o pid=,command= | awk -v home="$home" '
    index($0, home) && ($0 ~ /\/dory-hv / || $0 ~ /\/gvproxy / ||
      $0 ~ /\/dory-dataplane-proxy /) { print $1 }
  '
}
owned_engine_pids() { owned_engine_pids_for "$ENGINE_HOME"; }
cleanup() {
  set +e
  [ -n "$ENDURANCE_PID" ] && kill -TERM "$ENDURANCE_PID" 2>/dev/null || true
  [ -n "$LONG_PID" ] && kill -TERM "$LONG_PID" 2>/dev/null || true
  [ -n "$ENDURANCE_PID" ] && wait "$ENDURANCE_PID" 2>/dev/null || true
  [ -n "$LONG_PID" ] && wait "$LONG_PID" 2>/dev/null || true
  if [ "$MIGRATION_SOURCE_STARTED" -eq 1 ]; then
    HOME="$MIGRATION_SOURCE_HOME" "$RUNTIME" stop \
      > "$WORKDIR/evidence/migration-source-stop.log" 2>&1 || true
  fi
  if [ "$ENGINE_STARTED" -eq 1 ]; then
    HOME="$ENGINE_HOME" "$RUNTIME" stop > "$WORKDIR/evidence/runtime-stop.log" 2>&1 || true
  fi
  for _ in $(seq 1 300); do
    [ ! -S "$SOCKET" ] && [ -z "$(owned_engine_pids)" ] && break
    sleep 0.1
  done
  if [ ! -S "$SOCKET" ] && [ -z "$(owned_engine_pids)" ]; then
    # Preserve partial long-gate diagnostics in the durable qualification root, but never leave a
    # multi-gigabyte short-path engine home behind after a clean cancellation or gate failure.
    for gate in long-lived endurance competitor-runtime bind-file-coherence bind-advisory-lock ssh-agent testcontainers devcontainers act localstack tilt supabase kubernetes-tooling migration; do
      if [ -d "$ENGINE_HOME/gate-evidence/$gate" ] \
         && [ ! -e "$WORKDIR/evidence/$gate" ]; then
        mv "$ENGINE_HOME/gate-evidence/$gate" "$WORKDIR/evidence/$gate" || true
      fi
    done
    rm -rf "$ENGINE_HOME"
  else
    printf 'cleanup retained active engine home for manual recovery: %s\n' "$ENGINE_HOME" \
      > "$WORKDIR/evidence/cleanup-retained-engine-home.txt"
  fi
  for _ in $(seq 1 300); do
    [ ! -S "$MIGRATION_SOURCE_SOCKET" ] \
      && [ -z "$(owned_engine_pids_for "$MIGRATION_SOURCE_HOME")" ] && break
    sleep 0.1
  done
  if [ ! -S "$MIGRATION_SOURCE_SOCKET" ] \
      && [ -z "$(owned_engine_pids_for "$MIGRATION_SOURCE_HOME")" ]; then
    rm -rf "$MIGRATION_SOURCE_HOME"
  else
    printf 'cleanup retained active migration source home for manual recovery: %s\n' \
      "$MIGRATION_SOURCE_HOME" \
      > "$WORKDIR/evidence/cleanup-retained-migration-source-home.txt"
  fi
  stop_power_assertion
}
trap cleanup EXIT INT TERM

start_power_assertion

# The full default Supabase stack is mandatory and cannot converge inside the standalone launcher's
# deliberately tiny 2 GiB default. Qualify the exact runtime with an explicit workstation-class
# ceiling; this changes capacity only, not the candidate binaries or guest image under test.
HOME="$ENGINE_HOME" "$RUNTIME" start --mem-mb 8192 --cpus 6 --amd64 \
  > "$WORKDIR/evidence/runtime-start.log" 2>&1
ENGINE_STARTED=1
ready=0
for _ in $(seq 1 900); do
  if [ -S "$SOCKET" ] \
     && curl -fsS --max-time 2 --unix-socket "$SOCKET" http://d/_ping >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.2
done
[ "$ready" -eq 1 ] || die "isolated candidate engine did not become ready within 180 seconds"

supervisor_evidence="$WORKDIR/evidence/standalone-supervisor-recovery"
mkdir -p "$supervisor_evidence"
initial_engine_pid="$(cat "$ENGINE_HOME/.dory/engine-cli.pid")"
initial_dataplane_pid="$(cat "$ENGINE_HOME/.dory/dataplane-cli.pid")"
rm -f "$ENGINE_HOME/.dory/engine-cli.pid" "$ENGINE_HOME/.dory/dataplane-cli.pid"
bounded 30 env HOME="$ENGINE_HOME" "$RUNTIME" start --mem-mb 8192 --cpus 6 --amd64 \
  > "$supervisor_evidence/pidfile-repair.out" \
  2> "$supervisor_evidence/pidfile-repair.err" \
  || die "exact standalone runtime did not repair lost healthy PID metadata"
grep -q 'already running' "$supervisor_evidence/pidfile-repair.out" \
  || die "lost PID metadata caused a healthy engine restart"
repaired_engine_pid="$(cat "$ENGINE_HOME/.dory/engine-cli.pid")"
repaired_dataplane_pid="$(cat "$ENGINE_HOME/.dory/dataplane-cli.pid")"
[ "$repaired_engine_pid" = "$initial_engine_pid" ] \
  && [ "$repaired_dataplane_pid" = "$initial_dataplane_pid" ] \
  || die "healthy PID metadata repair changed the running helper identities"

kill -KILL "$repaired_dataplane_pid" 2>/dev/null \
  || die "could not create the isolated dead-dataplane recovery fixture"
for _ in $(seq 1 100); do
  if ! kill -0 "$repaired_dataplane_pid" 2>/dev/null; then break; fi
  process_state="$(ps -p "$repaired_dataplane_pid" -o state= 2>/dev/null | tr -d '[:space:]')"
  [ "$process_state" = Z ] && break
  sleep 0.05
done
rm -f "$ENGINE_HOME/.dory/dataplane-cli.pid"
bounded 90 env HOME="$ENGINE_HOME" "$RUNTIME" start --mem-mb 8192 --cpus 6 --amd64 \
  > "$supervisor_evidence/incomplete-runtime-recovery.out" \
  2> "$supervisor_evidence/incomplete-runtime-recovery.err" \
  || die "exact standalone runtime did not recover its dead dataplane"
grep -q 'stopping incomplete previous runtime' \
  "$supervisor_evidence/incomplete-runtime-recovery.out" \
  || die "dead dataplane did not trigger incomplete-runtime recovery"
recovered_engine_pid="$(cat "$ENGINE_HOME/.dory/engine-cli.pid")"
recovered_dataplane_pid="$(cat "$ENGINE_HOME/.dory/dataplane-cli.pid")"
[ "$recovered_engine_pid" != "$initial_engine_pid" ] \
  && [ "$recovered_dataplane_pid" != "$initial_dataplane_pid" ] \
  || die "incomplete-runtime recovery did not create a new helper pair"
[ "$(curl -fsS --max-time 5 --unix-socket "$SOCKET" http://d/_ping)" = OK ] \
  || die "Docker API did not recover after exact standalone supervisor repair"
grep 'engine stopped:' "$ENGINE_HOME/.dory/engine.log" | tail -1 \
  > "$supervisor_evidence/recovery-shutdown.txt"
grep -qx 'dory-hv: engine stopped: powerOff' \
  "$supervisor_evidence/recovery-shutdown.txt" \
  || die "incomplete-runtime recovery did not gracefully power off the guest"
cat > "$supervisor_evidence/manifest.txt" <<EOF
status=PASS
healthy_pidfile_repair=PASS
dead_dataplane_detected=PASS
incomplete_runtime_poweroff=PASS
fresh_helper_pair=PASS
docker_api_recovery=PASS
runtime_launcher_sha256=$(shasum -a 256 "$RUNTIME" | awk '{print $1}')
dory_hv_sha256=$(shasum -a 256 "$RUNTIME_DIR/bin/dory-hv" | awk '{print $1}')
dataplane_sha256=$(shasum -a 256 "$RUNTIME_DIR/bin/dory-dataplane-proxy" | awk '{print $1}')
release_qualifying=true
EOF

DOCKER_HOST="unix://$SOCKET" "$DOCKER" version > "$WORKDIR/evidence/docker-version.txt"
owned_engine_pids > "$WORKDIR/evidence/engine-pids-started.txt"
[ -s "$WORKDIR/evidence/engine-pids-started.txt" ] \
  || die "no isolated candidate engine processes were attributable after start"
bounded 1200 scripts/nonnative-exec-conformance-gate.sh \
  --socket "$SOCKET" \
  --docker "$DOCKER" \
  --base-image "$NONNATIVE_DEBIAN_IMAGE" \
  --native-image "$IMAGE" \
  --workroot "$WORKDIR/evidence/nonnative-exec-conformance" \
  --confirm ISOLATED-DORY-NONNATIVE-EXEC \
  > "$WORKDIR/evidence/nonnative-exec-conformance.log" 2>&1 \
  || die "linux/amd64 generic exec conformance gate failed"
nonnative_exec_manifest="$(find "$WORKDIR/evidence/nonnative-exec-conformance" \
  -name manifest.txt -type f -print -quit)"
[ -s "$nonnative_exec_manifest" ] \
  || die "non-native exec conformance evidence manifest is missing"
for proof in status fresh_pulls amd64_only_binfmt canonical_shebang_paths env_shebang_chain \
  private_marker_isolation guest_seccomp_inheritance fd_exec_arguments fd_exec_null_argv \
  buildkit_exec_matrix runtime_exec_matrix docker_exec_matrix docker_api_after_exec \
  build_cache_cleanup owned_cleanup; do
  grep -qx "$proof=PASS" "$nonnative_exec_manifest" \
    || die "non-native exec conformance evidence does not prove $proof"
done
grep -Fx "base_image=$NONNATIVE_DEBIAN_IMAGE" "$nonnative_exec_manifest" >/dev/null \
  && grep -Fx "native_image=$IMAGE" "$nonnative_exec_manifest" >/dev/null \
  || die "non-native exec conformance gate used the wrong fixtures"
grep -qx 'oci_default_runtime=dory-runc' "$nonnative_exec_manifest" \
  && grep -qx 'fex_binfmt_flags=POCF' "$nonnative_exec_manifest" \
  && grep -qx 'platform=linux/amd64' "$nonnative_exec_manifest" \
  && grep -qx 'architecture=x86_64' "$nonnative_exec_manifest" \
  || die "non-native exec evidence omits the exact FEX/platform contract"

bounded 600 scripts/default-platform-image-gate.sh \
  --socket "$SOCKET" \
  --docker "$DOCKER" \
  --image "$IMAGE" \
  --expected-platform linux/arm64 \
  --require-docker-hub \
  --workroot "$WORKDIR/evidence/default-platform-image" \
  > "$WORKDIR/evidence/default-platform-image.log" 2>&1 \
  || die "default arm64 image pull/storage-reporting gate failed"
default_platform_manifest="$(find "$WORKDIR/evidence/default-platform-image" \
  -name manifest.txt -type f -print -quit)"
[ -s "$default_platform_manifest" ] || die "default platform image manifest is missing"
for proof in status default_pull_without_platform single_platform_local_image \
  default_run_architecture image_list_system_df_reconciled; do
  grep -qx "$proof=PASS" "$default_platform_manifest" \
    || die "default platform image evidence does not prove $proof"
done
grep -Fx "image=$IMAGE" "$default_platform_manifest" >/dev/null \
  || die "default platform image gate used the wrong fixture"
grep -qx 'expected_platform=linux/arm64' "$default_platform_manifest" \
  || die "default image pull did not qualify Apple Silicon"
grep -qx 'registry=docker.io' "$default_platform_manifest" \
  || die "default image pull did not qualify Docker Hub manifest access"

bounded 900 scripts/nonnative-nix-gc-gate.sh \
  --socket "$SOCKET" \
  --docker "$DOCKER" \
  --image "$NONNATIVE_NIX_IMAGE" \
  --workroot "$WORKDIR/evidence/nonnative-nix-gc" \
  --confirm ISOLATED-DORY-NONNATIVE-NIX-GC \
  > "$WORKDIR/evidence/nonnative-nix-gc.log" 2>&1 \
  || die "linux/amd64 Nix garbage-collection gate failed"
nonnative_nix_manifest="$(find "$WORKDIR/evidence/nonnative-nix-gc" \
  -name manifest.txt -type f -print -quit)"
[ -s "$nonnative_nix_manifest" ] || die "non-native Nix GC evidence manifest is missing"
for proof in status fresh_pull unreachable_store_path_created nix_collect_garbage_delete_old \
  unreachable_store_path_deleted docker_api_after_gc owned_cleanup; do
  grep -qx "$proof=PASS" "$nonnative_nix_manifest" \
    || die "non-native Nix GC evidence does not prove $proof"
done
grep -Fx "image=$NONNATIVE_NIX_IMAGE" "$nonnative_nix_manifest" >/dev/null \
  || die "non-native Nix GC gate used the wrong image"
grep -qx 'platform=linux/amd64' "$nonnative_nix_manifest" \
  && grep -qx 'architecture=x86_64' "$nonnative_nix_manifest" \
  && grep -qx 'nix_version=2.34.7' "$nonnative_nix_manifest" \
  || die "non-native Nix GC gate lost its exact architecture/version contract"

bounded 900 scripts/nonnative-arch-pacman-gate.sh \
  --socket "$SOCKET" \
  --docker "$DOCKER" \
  --base-image "$NONNATIVE_ARCH_IMAGE" \
  --workroot "$WORKDIR/evidence/nonnative-arch-pacman" \
  --confirm ISOLATED-DORY-NONNATIVE-ARCH-PACMAN \
  > "$WORKDIR/evidence/nonnative-arch-pacman.log" 2>&1 \
  || die "linux/amd64 Arch pacman sandbox gate failed"
nonnative_arch_manifest="$(find "$WORKDIR/evidence/nonnative-arch-pacman" \
  -name manifest.txt -type f -print -quit)"
[ -s "$nonnative_arch_manifest" ] || die "non-native Arch pacman evidence manifest is missing"
for proof in status fresh_pull pacman_default_sandbox alpm_user_switch fex_handler \
  fex_bundle_read_only fzf_inventory fzf_runtime docker_api_after_build owned_cleanup; do
  grep -qx "$proof=PASS" "$nonnative_arch_manifest" \
    || die "non-native Arch pacman evidence does not prove $proof"
done
grep -qx 'oci_default_runtime=dory-runc' "$nonnative_arch_manifest" \
  && grep -qx 'fex_binfmt_flags=POCF' "$nonnative_arch_manifest" \
  && grep -Eq '^fex_sha256=[0-9a-f]{64}$' "$nonnative_arch_manifest" \
  && grep -Eq '^fex_server_sha256=[0-9a-f]{64}$' "$nonnative_arch_manifest" \
  || die "non-native Arch pacman evidence omits the FEX runtime contract"
grep -Fx "base_image=$NONNATIVE_ARCH_IMAGE" "$nonnative_arch_manifest" >/dev/null \
  || die "non-native Arch pacman gate used the wrong image"

bounded 1800 scripts/nonnative-mmdebstrap-gate.sh \
  --socket "$SOCKET" \
  --docker "$DOCKER" \
  --base-image "$NONNATIVE_DEBIAN_IMAGE" \
  --workroot "$WORKDIR/evidence/nonnative-mmdebstrap" \
  --confirm ISOLATED-DORY-NONNATIVE-MMDEBSTRAP \
  > "$WORKDIR/evidence/nonnative-mmdebstrap.log" 2>&1 \
  || die "linux/amd64 mmdebstrap nested-chroot gate failed"
nonnative_mmdebstrap_manifest="$(find "$WORKDIR/evidence/nonnative-mmdebstrap" \
  -name manifest.txt -type f -print -quit)"
[ -s "$nonnative_mmdebstrap_manifest" ] \
  || die "non-native mmdebstrap evidence manifest is missing"
for proof in status fresh_pull reported_dockerfile_commands mmdebstrap_minbase_trixie \
  bad_fd_number_absent fex_handler fex_bundle_read_only rootfs_archive_readable \
  nested_chroot_no_proc nested_chroot_shebang private_marker_isolation \
  docker_api_after_build build_cache_cleanup owned_cleanup; do
  grep -qx "$proof=PASS" "$nonnative_mmdebstrap_manifest" \
    || die "non-native mmdebstrap evidence does not prove $proof"
done
grep -Fx "base_image=$NONNATIVE_DEBIAN_IMAGE" "$nonnative_mmdebstrap_manifest" >/dev/null \
  || die "non-native mmdebstrap gate used the wrong image"
grep -qx 'oci_default_runtime=dory-runc' "$nonnative_mmdebstrap_manifest" \
  && grep -qx 'fex_binfmt_flags=POCF' "$nonnative_mmdebstrap_manifest" \
  && grep -qx 'platform=linux/amd64' "$nonnative_mmdebstrap_manifest" \
  && grep -qx 'architecture=x86_64' "$nonnative_mmdebstrap_manifest" \
  || die "non-native mmdebstrap evidence omits the exact FEX/platform contract"

bounded 1800 scripts/ecr-registry-retry-gate.sh \
  --socket "$SOCKET" \
  --docker "$DOCKER" \
  --base-image "$IMAGE" \
  --registry "$ECR_REGISTRY" \
  --repository "$ECR_REPOSITORY" \
  --region "$ECR_REGION" \
  --workroot "$WORKDIR/evidence/ecr-registry" \
  --confirm DISPOSABLE-ECR-INTERRUPT-RETRY \
  > "$WORKDIR/evidence/ecr-registry.log" 2>&1 \
  || die "managed ECR interrupted-upload/retry gate failed"
ecr_manifest="$(find "$WORKDIR/evidence/ecr-registry" -name manifest.txt -type f -print -quit)"
[ -s "$ecr_manifest" ] || die "managed ECR evidence manifest is missing"
for proof in status authenticated_login bundled_buildx interrupted_push_progress \
  interrupted_push_nonzero resumed_blob_upload \
  repeated_manifest_put repull_run_checksum local_image_cleanup remote_tag_cleanup \
  isolated_credential_cleanup; do
  grep -qx "$proof=PASS" "$ecr_manifest" \
    || die "managed ECR evidence does not prove $proof"
done
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE \
  AWS_WEB_IDENTITY_TOKEN_FILE DORY_RELEASE_ECR_REGISTRY DORY_RELEASE_ECR_REPOSITORY \
  DORY_RELEASE_ECR_REGION || true

bounded 180 env \
  DORY_SOCK="$SOCKET" \
  DORY_DOCKER_BIN="$DOCKER" \
  DORY_BIND_COHERENCE_IMAGE="$IMAGE" \
  DORY_BIND_COHERENCE_WORKROOT="$ENGINE_HOME/gate-evidence/bind-file-coherence" \
  scripts/bind-file-coherence-gate.sh \
  > "$WORKDIR/evidence/bind-file-coherence.log" 2>&1 \
  || die "spaced-path/direct-file bind coherence gate failed"
bind_file_manifest="$(find "$ENGINE_HOME/gate-evidence/bind-file-coherence" \
  -name manifest.txt -type f -print -quit)"
[ -s "$bind_file_manifest" ] || die "bind-file coherence manifest is missing"
for proof in status path_with_spaces directory_bind direct_single_file_bind \
  same_inode_shrink same_inode_grow same_inode_content_refresh atomic_replacement \
  direct_atomic_replacement_pins_inode direct_rebind_follows_replacement \
  guest_to_host_truncation; do
  grep -qx "$proof=PASS" "$bind_file_manifest" \
    || die "bind-file coherence manifest does not prove $proof"
done
grep -qx 'direct_single_file_recreate_cycles=20' "$bind_file_manifest" \
  || die "bind-file coherence gate did not repeat direct file attachment 20 times"
grep -Fx "image=$IMAGE" "$bind_file_manifest" >/dev/null \
  || die "bind-file coherence gate used the wrong image"
bind_file_docker_sha="$(shasum -a 256 "$DOCKER" | awk '{print $1}')"
grep -qx "docker_cli_sha256=$bind_file_docker_sha" "$bind_file_manifest" \
  || die "bind-file coherence gate used the wrong Docker CLI"

guest_agent_evidence="$WORKDIR/evidence/guest-agent"
mkdir -p "$guest_agent_evidence"
guest_agent_expected_sha256="$(shasum -a 256 \
  "$RUNTIME_DIR/share/dory/dory-agent-linux-arm64" | awk '{print $1}')"
printf '%s\n' "$guest_agent_expected_sha256" | grep -Eq '^[0-9a-f]{64}$' \
  || die "could not hash the bundled standalone guest agent"
printf 'expected_sha256=%s\n' "$guest_agent_expected_sha256" \
  > "$guest_agent_evidence/manifest.txt"
verify_running_guest_agent() {
  local phase="$1" container="dory-qualified-agent-${RUN_ID}-${RUN_ATTEMPT}-$1"
  local output="$guest_agent_evidence/$phase.txt" actual
  if ! bounded 60 env DOCKER_HOST="unix://$SOCKET" "$DOCKER" run --rm --privileged \
      --name "$container" --label dev.dory.qualification=guest-agent \
      -v /:/dory-guest-root:ro "$IMAGE" \
      sh -ec 'sha256sum /dory-guest-root/run/dory-agent' > "$output" 2>&1; then
    DOCKER_HOST="unix://$SOCKET" "$DOCKER" rm -f "$container" >/dev/null 2>&1 || true
    die "could not inspect the running guest agent after $phase boot"
  fi
  actual="$(awk 'NR == 1 {print $1}' "$output")"
  [ "$actual" = "$guest_agent_expected_sha256" ] \
    || die "running guest agent after $phase boot differs from the exact bundled agent"
  printf '%s_sha256=%s\n' "$phase" "$actual" >> "$guest_agent_evidence/manifest.txt"
}
verify_running_guest_agent fresh

# Exercise the production migration implementation between two disposable candidate engines.
# This is intentionally before the long soaks: it proves the exact source commit can restore
# images, volumes, metadata, networks, containers, writable layers, and state without touching a
# user's Docker/OrbStack installation, then removes the second engine before duration sampling.
MIGRATION_SOURCE_STARTED=1
HOME="$MIGRATION_SOURCE_HOME" "$RUNTIME" start \
  > "$WORKDIR/evidence/migration-source-start.log" 2>&1
migration_source_ready=0
for _ in $(seq 1 900); do
  if [ -S "$MIGRATION_SOURCE_SOCKET" ] \
     && curl -fsS --max-time 2 --unix-socket "$MIGRATION_SOURCE_SOCKET" \
       http://d/_ping >/dev/null 2>&1; then
    migration_source_ready=1
    break
  fi
  sleep 0.2
done
[ "$migration_source_ready" -eq 1 ] \
  || die "isolated migration source engine did not become ready within 180 seconds"
DOCKER_HOST="unix://$MIGRATION_SOURCE_SOCKET" "$DOCKER" pull "$IMAGE" \
  > "$WORKDIR/evidence/migration-source-image-pull.txt"
bounded 1800 env \
  DORY_LIVE_SOURCE_SOCKET="$MIGRATION_SOURCE_SOCKET" \
  DORY_LIVE_TARGET_SOCKET="$SOCKET" \
  DORY_LIVE_MIGRATION_BASE_IMAGE="$IMAGE" \
  DORY_LIVE_MIGRATION_EVIDENCE_DIR="$ENGINE_HOME/gate-evidence/migration" \
  scripts/live-orbstack-migration-smoke.sh \
  > "$WORKDIR/evidence/migration.log" 2>&1 \
  || die "disposable two-engine production migration gate failed"
migration_manifest="$ENGINE_HOME/gate-evidence/migration/manifest.txt"
[ -s "$migration_manifest" ] || die "migration evidence manifest is missing"
grep -qx 'status=PASS' "$migration_manifest" \
  || die "migration evidence manifest is not PASS"
[ -z "$(DOCKER_HOST="unix://$SOCKET" "$DOCKER" ps -aq)" ] \
  || die "migration gate left containers on the isolated target engine"
HOME="$MIGRATION_SOURCE_HOME" "$RUNTIME" stop \
  > "$WORKDIR/evidence/migration-source-stop.log" 2>&1
for _ in $(seq 1 300); do
  [ ! -S "$MIGRATION_SOURCE_SOCKET" ] \
    && [ -z "$(owned_engine_pids_for "$MIGRATION_SOURCE_HOME")" ] && break
  sleep 0.1
done
[ ! -S "$MIGRATION_SOURCE_SOCKET" ] \
  || die "isolated migration source socket survived shutdown"
[ -z "$(owned_engine_pids_for "$MIGRATION_SOURCE_HOME")" ] \
  || die "isolated migration source helpers survived shutdown"
MIGRATION_SOURCE_STARTED=0
rm -rf "$MIGRATION_SOURCE_HOME"

# Supabase's released Go client pulls images and then reuses the same Docker HTTP connection for
# Vector's socket-mounted create. This gate therefore covers both the full product stack and the
# post-stream create classification that a one-shot `docker run` smoke cannot exercise.
bounded 1800 scripts/supabase-compatibility-gate.sh \
  --socket "$SOCKET" \
  --docker "$DOCKER" \
  --version "$SUPABASE_VERSION" \
  --workroot "$ENGINE_HOME/gate-evidence/supabase" \
  --confirm ISOLATED-ENGINE-SUPABASE \
  > "$WORKDIR/evidence/supabase.log" 2>&1 \
  || die "full default Supabase compatibility gate failed"
supabase_manifest="$ENGINE_HOME/gate-evidence/supabase/manifest.txt"
[ -s "$supabase_manifest" ] || die "Supabase evidence manifest is missing"
grep -qx 'status=PASS' "$supabase_manifest" || die "Supabase evidence manifest is not PASS"
[ -z "$(DOCKER_HOST="unix://$SOCKET" "$DOCKER" ps -aq)" ] \
  || die "Supabase gate left containers on the isolated engine"

# Exercise the Kubernetes toolchain that commonly exposes nested-container, privileged-runtime,
# dynamic-port, and long-lived API-stream incompatibilities in desktop container engines.
bounded 1800 scripts/kubernetes-tooling-compatibility-gate.sh \
  --socket "$SOCKET" \
  --docker "$DOCKER" \
  --kubectl "$KUBECTL" \
  --k3s-image "$K3S_IMAGE" \
  --workload-image "$K8S_WORKLOAD_IMAGE" \
  --tilt-version "$TILT_VERSION" \
  --skaffold-version "$SKAFFOLD_VERSION" \
  --workroot "$ENGINE_HOME/gate-evidence/kubernetes-tooling" \
  --confirm ISOLATED-ENGINE-KUBERNETES-TOOLING \
  > "$WORKDIR/evidence/kubernetes-tooling.log" 2>&1 \
  || die "k3s/Skaffold/Tilt Kubernetes compatibility gate failed"
kubernetes_tooling_manifest="$ENGINE_HOME/gate-evidence/kubernetes-tooling/manifest.txt"
[ -s "$kubernetes_tooling_manifest" ] \
  || die "Kubernetes tooling evidence manifest is missing"
grep -qx 'status=PASS' "$kubernetes_tooling_manifest" \
  || die "Kubernetes tooling evidence manifest is not PASS"
[ -z "$(DOCKER_HOST="unix://$SOCKET" "$DOCKER" ps -aq)" ] \
  || die "Kubernetes tooling gate left containers on the isolated engine"

bounded 1800 scripts/competitor-runtime-regression-gate.sh \
  --socket "$SOCKET" \
  --state-dir "$ENGINE_HOME/.dory" \
  --image "$IMAGE" \
  --workroot "$ENGINE_HOME/gate-evidence/competitor-runtime" \
  --connections 2000 \
  --restarts 20 \
  --fd-growth 8 \
  --docker "$DOCKER" \
  --runtime "$RUNTIME" \
  --runtime-home "$ENGINE_HOME" \
  --source-commit "$SOURCE_COMMIT" \
  > "$WORKDIR/evidence/competitor-runtime.log" 2>&1 \
  || die "bounded competitor runtime/backpressure/restart gate failed"
competitor_results="$(find "$ENGINE_HOME/gate-evidence/competitor-runtime" \
  -name results.tsv -type f -print -quit)"
[ -s "$competitor_results" ] || die "competitor runtime results are missing"
competitor_manifest="$(dirname "$competitor_results")/manifest.txt"
[ -s "$competitor_manifest" ] || die "competitor runtime manifest is missing"
competitor_docker_sha="$(shasum -a 256 "$DOCKER" | awk '{print $1}')"
grep -qx "docker_bin_sha256=$competitor_docker_sha" "$competitor_manifest" \
  || die "competitor runtime manifest is not bound to the qualified Docker CLI"
grep -qx "source_commit=$SOURCE_COMMIT" "$competitor_manifest" \
  || die "competitor runtime manifest is not bound to the qualified source commit"
grep -Eq '^dory_engine_sha256=[0-9a-f]{64}$' "$competitor_manifest" \
  || die "competitor runtime manifest omits the launcher digest"
grep -Eq '^bin_dory_hv_sha256=[0-9a-f]{64}$' "$competitor_manifest" \
  || die "competitor runtime manifest omits the dory-hv digest"
grep -Eq '^share_dory_dory_engine_rootfs_ext4_lzfse_sha256=[0-9a-f]{64}$' \
  "$competitor_manifest" \
  || die "competitor runtime manifest omits the rootfs digest"
grep -qx 'amd64_enabled=1' "$(dirname "$competitor_results")/engine-settings.txt" \
  || die "competitor runtime restart did not retain Apple Silicon amd64/FEX mode"
grep -q $'\tFAIL\t' "$competitor_results" \
  && die "competitor runtime results contain a failed row"
for proof in \
  published-port-handoff host-port-collision named-signal-delivery forwarded-connection-fds \
  concurrent-proxy-backpressure missing-source-cp restart-churn compose-port-restart \
  network-route-conflict network-alias-restart-ip standalone-engine-restart \
  named-volume-empty named-volume named-volume-cp security-opt-label seccomp-profile \
  bind-open-create-0200 bind-mount-option-contract nested-bind-subvolume \
  bind-special-file-fail-fast bind-open-fd-stability bind-hardlink-permissions healthcheck \
  buildx-named-context buildkit-default-arg image-save-stdout image-hardlink-missing-parent \
  buildkit-large-dockerfile buildkit-relative-temp-context dockerignore-layered-unignore \
  buildkit-concurrent-sessions container-resolver-contract container-dns-search \
  cleanup-restart-persistence; do
  awk -F '\t' -v proof="$proof" \
    '$1 == proof && $2 == "PASS" { found=1 } END { exit !found }' "$competitor_results" \
    || die "competitor runtime results do not prove $proof"
done
[ -S "$SOCKET" ] \
  && curl -fsS --max-time 2 --unix-socket "$SOCKET" http://d/_ping >/dev/null \
  || die "candidate engine did not recover after the restart gate"
verify_running_guest_agent restart
printf 'status=PASS\n' >> "$guest_agent_evidence/manifest.txt"

bounded 300 env HOME="$ENGINE_HOME" scripts/bind-advisory-lock-gate.sh \
  --socket "$SOCKET" \
  --docker "$DOCKER" \
  --image "$LOCK_IMAGE" \
  --workroot "$ENGINE_HOME/gate-evidence/bind-advisory-lock" \
  --confirm ISOLATED-DORY-BIND-LOCKS \
  > "$WORKDIR/evidence/bind-advisory-lock.log" 2>&1 \
  || die "cross-container bind advisory-lock gate failed"
bind_lock_manifest="$(find "$ENGINE_HOME/gate-evidence/bind-advisory-lock" \
  -name manifest.txt -type f -print -quit)"
[ -s "$bind_lock_manifest" ] || die "bind advisory-lock evidence manifest is missing"
for proof in status create_excl_readonly_mode0000_unlink \
  bsd_flock_exclusive_shared_unlock_upgrade_crash \
  posix_range_nonoverlap_blocking_unlock_crash cross_container_bind_mount; do
  grep -qx "$proof=PASS" "$bind_lock_manifest" \
    || die "bind advisory-lock manifest does not prove $proof"
done
bind_lock_docker_sha256="$(sed -n 's/^docker_cli_sha256=//p' "$bind_lock_manifest")"
printf '%s\n' "$bind_lock_docker_sha256" | grep -Eq '^[0-9a-f]{64}$' \
  || die "bind advisory-lock manifest does not identify the exact Docker CLI"
[ -z "$(DOCKER_HOST="unix://$SOCKET" "$DOCKER" ps -aq)" ] \
  || die "bind advisory-lock gate left containers on the isolated engine"

bounded 600 scripts/ssh-agent-forwarding-gate.sh \
  --socket "$SOCKET" \
  --docker "$DOCKER" \
  --image "$SSH_CLIENT_IMAGE" \
  --workroot "$ENGINE_HOME/gate-evidence/ssh-agent" \
  --concurrency 8 \
  > "$WORKDIR/evidence/ssh-agent.log" 2>&1 \
  || die "SSH-agent forwarding compatibility gate failed"
ssh_agent_manifest="$(find "$ENGINE_HOME/gate-evidence/ssh-agent" \
  -name manifest.txt -type f -print -quit)"
[ -s "$ssh_agent_manifest" ] || die "SSH-agent forwarding evidence manifest is missing"
grep -qx 'status=PASS' "$ssh_agent_manifest" \
  || die "SSH-agent forwarding evidence manifest is not PASS"
[ -z "$(DOCKER_HOST="unix://$SOCKET" "$DOCKER" ps -aq)" ] \
  || die "SSH-agent gate left containers on the isolated engine"

bounded 900 scripts/testcontainers-compatibility-gate.sh \
  --socket "$SOCKET" \
  --docker "$DOCKER" \
  --version "$TESTCONTAINERS_VERSION" \
  --image "$IMAGE" \
  --workroot "$ENGINE_HOME/gate-evidence/testcontainers" \
  > "$WORKDIR/evidence/testcontainers.log" 2>&1 \
  || die "Testcontainers/Ryuk compatibility gate failed"
testcontainers_manifest="$(find "$ENGINE_HOME/gate-evidence/testcontainers" \
  -name manifest.txt -type f -print -quit)"
[ -s "$testcontainers_manifest" ] || die "Testcontainers evidence manifest is missing"
grep -qx 'status=PASS' "$testcontainers_manifest" \
  || die "Testcontainers evidence manifest is not PASS"
[ -z "$(DOCKER_HOST="unix://$SOCKET" "$DOCKER" ps -aq)" ] \
  || die "Testcontainers gate left containers on the isolated engine"

bounded 900 scripts/devcontainers-compatibility-gate.sh \
  --socket "$SOCKET" \
  --docker "$DOCKER" \
  --version "$DEVCONTAINERS_VERSION" \
  --workroot "$ENGINE_HOME/gate-evidence/devcontainers" \
  --confirm ISOLATED-ENGINE-DEVCONTAINERS \
  > "$WORKDIR/evidence/devcontainers.log" 2>&1 \
  || die "Dev Containers CLI compatibility gate failed"
devcontainers_manifest="$ENGINE_HOME/gate-evidence/devcontainers/manifest.txt"
[ -s "$devcontainers_manifest" ] || die "Dev Containers evidence manifest is missing"
grep -qx 'status=PASS' "$devcontainers_manifest" \
  || die "Dev Containers evidence manifest is not PASS"
[ -z "$(DOCKER_HOST="unix://$SOCKET" "$DOCKER" ps -aq)" ] \
  || die "Dev Containers gate left containers on the isolated engine"

bounded 900 scripts/act-compatibility-gate.sh \
  --socket "$SOCKET" \
  --docker "$DOCKER" \
  --version "$ACT_VERSION" \
  --workroot "$ENGINE_HOME/gate-evidence/act" \
  --confirm ISOLATED-ENGINE-ACT \
  > "$WORKDIR/evidence/act.log" 2>&1 \
  || die "act workflow compatibility gate failed"
act_manifest="$ENGINE_HOME/gate-evidence/act/manifest.txt"
[ -s "$act_manifest" ] || die "act evidence manifest is missing"
grep -qx 'status=PASS' "$act_manifest" || die "act evidence manifest is not PASS"
[ -z "$(DOCKER_HOST="unix://$SOCKET" "$DOCKER" ps -aq)" ] \
  || die "act gate left containers on the isolated engine"

bounded 1200 scripts/localstack-compatibility-gate.sh \
  --socket "$SOCKET" \
  --docker "$DOCKER" \
  --image "$LOCALSTACK_IMAGE" \
  --workroot "$ENGINE_HOME/gate-evidence/localstack" \
  --confirm ISOLATED-ENGINE-LOCALSTACK \
  > "$WORKDIR/evidence/localstack.log" 2>&1 \
  || die "LocalStack S3/SQS compatibility gate failed"
localstack_manifest="$ENGINE_HOME/gate-evidence/localstack/manifest.txt"
[ -s "$localstack_manifest" ] || die "LocalStack evidence manifest is missing"
grep -qx 'status=PASS' "$localstack_manifest" \
  || die "LocalStack evidence manifest is not PASS"
[ -z "$(DOCKER_HOST="unix://$SOCKET" "$DOCKER" ps -aq)" ] \
  || die "LocalStack gate left containers on the isolated engine"

bounded 900 scripts/tilt-compose-compatibility-gate.sh \
  --socket "$SOCKET" \
  --docker "$DOCKER" \
  --version "$TILT_VERSION" \
  --workroot "$ENGINE_HOME/gate-evidence/tilt" \
  --confirm ISOLATED-ENGINE-TILT \
  > "$WORKDIR/evidence/tilt.log" 2>&1 \
  || die "Tilt Compose compatibility gate failed"
tilt_manifest="$ENGINE_HOME/gate-evidence/tilt/manifest.txt"
[ -s "$tilt_manifest" ] || die "Tilt evidence manifest is missing"
grep -qx 'status=PASS' "$tilt_manifest" || die "Tilt evidence manifest is not PASS"
[ -z "$(DOCKER_HOST="unix://$SOCKET" "$DOCKER" ps -aq)" ] \
  || die "Tilt gate left containers on the isolated engine"

# Do not retain an Actions/GitHub token in a process that intentionally runs beyond its 24-hour
# lifetime. Publication happens in a subsequent job with fresh credentials.
assert_stable_power
unset GITHUB_TOKEN GH_TOKEN ACTIONS_RUNTIME_TOKEN ACTIONS_ID_TOKEN_REQUEST_TOKEN \
  ACTIONS_ID_TOKEN_REQUEST_URL || true

scripts/long-lived-network-soak.sh \
  --socket "$SOCKET" \
  --docker "$DOCKER" \
  --image "$IMAGE" \
  --duration "$LONG_DURATION" \
  --workroot "$ENGINE_HOME/gate-evidence/long-lived" \
  --confirm ISOLATED-ENGINE-LONG-LIVED-TCP \
  > "$WORKDIR/evidence/long-lived.log" 2>&1 &
LONG_PID=$!

# Establish the measured TCP connection before taking the endurance baseline, so the long-lived
# fixture is present in both the first and final resource/state windows.
heartbeat_ready=0
for _ in $(seq 1 600); do
  kill -0 "$LONG_PID" 2>/dev/null || break
  if find "$ENGINE_HOME/gate-evidence/long-lived" -name heartbeats.tsv -type f -exec sh -c \
      'test "$(wc -l < "$1")" -ge 2' sh {} \; -print -quit 2>/dev/null | grep -q .; then
    heartbeat_ready=1
    break
  fi
  sleep 0.1
done
[ "$heartbeat_ready" -eq 1 ] || die "long-lived gate did not establish its measured connection"

scripts/endurance-reliability-soak.sh \
  --socket "$SOCKET" \
  --state-dir "$ENGINE_HOME/.dory" \
  --duration "$ENDURANCE_DURATION" \
  --compose-every 5 \
  --settle 2 \
  --workroot "$ENGINE_HOME/gate-evidence/endurance" \
  --min-free-gb "$MIN_FREE_GB" \
  --process-pattern "$ENGINE_HOME/.dory" \
  > "$WORKDIR/evidence/endurance.log" 2>&1 &
ENDURANCE_PID=$!

long_done=0
endurance_done=0
while [ "$long_done" -eq 0 ] || [ "$endurance_done" -eq 0 ]; do
  if [ "$SECONDS" -ge "$NEXT_POWER_CHECK" ]; then
    assert_stable_power
    NEXT_POWER_CHECK=$((SECONDS + 60))
  fi
  if [ "$long_done" -eq 0 ] && ! kill -0 "$LONG_PID" 2>/dev/null; then
    set +e; wait "$LONG_PID"; long_rc=$?; set -e
    LONG_PID=""
    long_done=1
    if [ "$long_rc" -ne 0 ]; then
      die "25-hour same-connection gate failed (exit $long_rc)"
    fi
  fi
  if [ "$endurance_done" -eq 0 ] && ! kill -0 "$ENDURANCE_PID" 2>/dev/null; then
    set +e; wait "$ENDURANCE_PID"; endurance_rc=$?; set -e
    ENDURANCE_PID=""
    endurance_done=1
    if [ "$endurance_rc" -ne 0 ]; then
      die "eight-hour endurance gate failed (exit $endurance_rc)"
    fi
  fi
  [ "$long_done" -eq 1 ] && [ "$endurance_done" -eq 1 ] || sleep 5
done
assert_stable_power

long_summary="$(find "$ENGINE_HOME/gate-evidence/long-lived" -name summary.txt -type f -print -quit)"
long_manifest="$(find "$ENGINE_HOME/gate-evidence/long-lived" -name manifest.txt -type f -print -quit)"
endurance_manifest="$(find "$ENGINE_HOME/gate-evidence/endurance" -name manifest.txt -type f -print -quit)"
endurance_cycles="$(find "$ENGINE_HOME/gate-evidence/endurance" -name cycles.tsv -type f -print -quit)"
[ -s "$long_summary" ] || die "long-lived summary is missing"
[ -s "$long_manifest" ] || die "long-lived manifest is missing"
grep -qx 'status=PASS' "$long_summary" || die "long-lived summary is not PASS"
grep -qx 'machine_to_docker_service=PASS' "$long_summary" \
  && grep -qx 'machine_service_route=host.docker.internal' "$long_summary" \
  && grep -qx 'machine_service_regular_200_400ms_plateau=ABSENT' "$long_summary" \
  || die "long-lived summary does not prove stable managed-machine-to-Docker service latency"
grep -qx 'machine_outbound_tcp=PASS' "$long_summary" \
  && grep -qx 'machine_outbound_failure_budget_per_mille=5' "$long_summary" \
  && grep -qx 'machine_outbound_consecutive_failure_limit=2' "$long_summary" \
  || die "long-lived summary does not prove stable managed-machine outbound TCP"
if [ "$LONG_DURATION" -gt 86400 ]; then
  grep -qx 'duration_beyond_24_hours=PASS' "$long_summary" \
    || die "long-lived summary does not prove the 24-hour edge"
fi
[ -s "$endurance_manifest" ] || die "endurance manifest is missing"
[ -s "$endurance_cycles" ] || die "endurance cycle results are missing"
if [ "$ENDURANCE_DURATION" -ge 28800 ]; then
  grep -qx 'release_qualifying=true' "$endurance_manifest" \
    || die "endurance summary is not release qualifying"
fi
grep -q $'\tFAIL\t' "$endurance_cycles" && die "endurance results contain a failed cycle"

long_owner="$(sed -n 's/^owner=//p' "$long_manifest")"
endurance_run_id="$(sed -n 's/^run_id=//p' "$endurance_manifest")"
[ -n "$long_owner" ] || die "long-lived ownership marker is missing"
[ -n "$endurance_run_id" ] || die "endurance ownership marker is missing"
endurance_owner="dory-endurance-$endurance_run_id"
long_leftovers="$(bounded 15 env DOCKER_HOST="unix://$SOCKET" "$DOCKER" ps -aq \
  --filter "label=dev.dory.long-lived=$long_owner")" \
  || die "could not verify long-lived fixture cleanup"
[ -z "$long_leftovers" ] || die "long-lived fixture container survived: $long_leftovers"
endurance_containers="$(bounded 15 env DOCKER_HOST="unix://$SOCKET" "$DOCKER" ps -aq \
  --filter "label=dev.dory.endurance=$endurance_owner")" \
  || die "could not verify endurance container cleanup"
endurance_volumes="$(bounded 15 env DOCKER_HOST="unix://$SOCKET" "$DOCKER" volume ls -q \
  --filter "label=dev.dory.endurance=$endurance_owner")" \
  || die "could not verify endurance volume cleanup"
endurance_networks="$(bounded 15 env DOCKER_HOST="unix://$SOCKET" "$DOCKER" network ls -q \
  --filter "label=dev.dory.endurance=$endurance_owner")" \
  || die "could not verify endurance network cleanup"
[ -z "$endurance_containers$endurance_volumes$endurance_networks" ] \
  || die "endurance-owned Docker objects survived cleanup"

HOME="$ENGINE_HOME" "$RUNTIME" stop > "$WORKDIR/evidence/runtime-stop.log" 2>&1
ENGINE_STARTED=0
for _ in $(seq 1 300); do
  [ ! -S "$SOCKET" ] && [ -z "$(owned_engine_pids)" ] && break
  sleep 0.1
done
[ ! -S "$SOCKET" ] || die "isolated candidate engine socket survived shutdown"
remaining_pids="$(owned_engine_pids)"
[ -z "$remaining_pids" ] \
  || die "isolated candidate engine helpers survived shutdown: $remaining_pids"
# Both roots normally live under the dedicated runner's persistent HOME. Move the immutable gate
# trees after engine shutdown so qualification does not briefly duplicate several GiB of evidence.
mv "$ENGINE_HOME/gate-evidence/long-lived" "$WORKDIR/evidence/long-lived"
mv "$ENGINE_HOME/gate-evidence/endurance" "$WORKDIR/evidence/endurance"
mv "$ENGINE_HOME/gate-evidence/competitor-runtime" "$WORKDIR/evidence/competitor-runtime"
mv "$ENGINE_HOME/gate-evidence/bind-file-coherence" "$WORKDIR/evidence/bind-file-coherence"
mv "$ENGINE_HOME/gate-evidence/bind-advisory-lock" "$WORKDIR/evidence/bind-advisory-lock"
mv "$ENGINE_HOME/gate-evidence/ssh-agent" "$WORKDIR/evidence/ssh-agent"
mv "$ENGINE_HOME/gate-evidence/testcontainers" "$WORKDIR/evidence/testcontainers"
mv "$ENGINE_HOME/gate-evidence/devcontainers" "$WORKDIR/evidence/devcontainers"
mv "$ENGINE_HOME/gate-evidence/act" "$WORKDIR/evidence/act"
mv "$ENGINE_HOME/gate-evidence/localstack" "$WORKDIR/evidence/localstack"
mv "$ENGINE_HOME/gate-evidence/tilt" "$WORKDIR/evidence/tilt"
mv "$ENGINE_HOME/gate-evidence/supabase" "$WORKDIR/evidence/supabase"
mv "$ENGINE_HOME/gate-evidence/kubernetes-tooling" "$WORKDIR/evidence/kubernetes-tooling"
mv "$ENGINE_HOME/gate-evidence/migration" "$WORKDIR/evidence/migration"

(cd "$WORKDIR" && \
  find evidence -type f ! -name evidence-sha256.txt -print \
    | LC_ALL=C sort \
    | while IFS= read -r path; do shasum -a 256 "$path"; done) \
  > "$WORKDIR/evidence/evidence-sha256.txt"
manifest_sha="$(shasum -a 256 "$MANIFEST" | awk '{print $1}')"
update_sha="$(shasum -a 256 "$UPDATE_ZIP" | awk '{print $1}')"
runtime_sha="$(shasum -a 256 "$RUNTIME_TAR" | awk '{print $1}')"
evidence_sha="$(shasum -a 256 "$WORKDIR/evidence/evidence-sha256.txt" | awk '{print $1}')"
completed_epoch="$(date +%s)"
release_qualifying=false
if [ "$LONG_DURATION" -gt 86400 ] && [ "$ENDURANCE_DURATION" -ge 28800 ] \
    && [ "$DEVELOPMENT_UNNOTARIZED" = 0 ]; then
  release_qualifying=true
fi
development_unnotarized=false
if [ "$DEVELOPMENT_UNNOTARIZED" = 1 ]; then development_unnotarized=true; fi
python3 - \
  "$WORKDIR/qualification.complete.json.partial" \
  "$release_qualifying" "$development_unnotarized" \
  "$VERSION" "$BUILD" "$SOURCE_COMMIT" "$RUN_ID" "$RUN_ATTEMPT" \
  "$manifest_sha" "$update_sha" "$runtime_sha" "$evidence_sha" \
  "$ENDURANCE_DURATION" "$LONG_DURATION" "$TESTCONTAINERS_VERSION" \
  "$DEVCONTAINERS_VERSION" "$ACT_VERSION" "$LOCALSTACK_IMAGE" "$TILT_VERSION" \
  "$SUPABASE_VERSION" "$K3S_IMAGE" "$K8S_WORKLOAD_IMAGE" "$SKAFFOLD_VERSION" \
  "$LOCK_IMAGE" "$bind_lock_docker_sha256" "$guest_agent_expected_sha256" \
  "$IMAGE" "$SSH_CLIENT_IMAGE" "$completed_epoch" <<'PY'
import json
import sys

(
    output, release_qualifying, development_unnotarized, version, build, source_commit,
    run_id, run_attempt, manifest_sha, update_sha, runtime_sha, evidence_sha,
    endurance_duration, long_duration, testcontainers_version, devcontainers_version,
    act_version, localstack_image, tilt_version, supabase_version, k3s_image,
    k8s_workload_image, skaffold_version, bind_lock_image, bind_lock_docker_sha256,
    guest_agent_sha256, fixture_image, ssh_client_image, completed_epoch,
) = sys.argv[1:]
payload = {
    "schemaVersion": 1,
    "status": "PASS",
    "releaseQualifying": release_qualifying == "true",
    "developmentUnnotarized": development_unnotarized == "true",
    "dataDiskGrowthGate": "PASS",
    "managedDataDriveGate": "PASS",
    "dataDriveVolumeIdentityGate": "PASS",
    "offlineBundledBootGate": "PASS",
    "defaultPlatformImageGate": "PASS",
    "nonnativeNixGCGate": "PASS",
    "nonnativeArchPacmanGate": "PASS",
    "nonnativeMmdebstrapGate": "PASS",
    "nonnativeExecConformanceGate": "PASS",
    "ecrRegistryRetryGate": "PASS",
    "bindFileCoherenceGate": "PASS",
    "powerAssertion": "PASS",
    "gvproxyQEMUSwitchGate": "PASS",
    "nativeIPv6Gate": "PASS",
    "migrationGate": "PASS",
    "competitorRuntimeGate": "PASS",
    "machineToDockerLongLivedGate": "PASS",
    "machineOutboundLongLivedGate": "PASS",
    "standaloneSupervisorRecoveryGate": "PASS",
    "bindAdvisoryLockGate": "PASS",
    "sshAgentForwardingGate": "PASS",
    "sshAgentImage": ssh_client_image,
    "bindAdvisoryLockImage": bind_lock_image,
    "bindAdvisoryLockDockerCLI_SHA256": bind_lock_docker_sha256,
    "guestAgentBootConfigGate": "PASS",
    "guestAgentSha256": guest_agent_sha256,
    "fixtureImage": fixture_image,
    "testcontainersGate": "PASS",
    "testcontainersVersion": testcontainers_version,
    "devcontainersGate": "PASS",
    "devcontainersVersion": devcontainers_version,
    "actGate": "PASS",
    "actVersion": act_version,
    "localstackGate": "PASS",
    "localstackImage": localstack_image,
    "tiltGate": "PASS",
    "tiltVersion": tilt_version,
    "supabaseGate": "PASS",
    "supabaseVersion": supabase_version,
    "kubernetesToolingGate": "PASS",
    "k3sImage": k3s_image,
    "kubernetesWorkloadImage": k8s_workload_image,
    "skaffoldVersion": skaffold_version,
    "version": version,
    "build": build,
    "sourceCommit": source_commit,
    "githubRunId": run_id,
    "githubRunAttempt": run_attempt,
    "candidateManifestSha256": manifest_sha,
    "appUpdateSha256": update_sha,
    "runtimeSha256": runtime_sha,
    "evidenceManifestSha256": evidence_sha,
    "enduranceDurationSeconds": int(endurance_duration),
    "longLivedDurationSeconds": int(long_duration),
    "completedEpoch": int(completed_epoch),
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
mv "$WORKDIR/qualification.complete.json.partial" "$WORKDIR/qualification.complete.json"

# Retain only immutable evidence and its small completion record between workflow jobs. Candidate
# artifacts are re-downloaded and rehashed by the publication job using fresh credentials.
rm -rf "$WORKDIR/extracted-app" "$WORKDIR/extracted-runtime" "$WORKDIR/docker-config" \
  "$WORKDIR/docker" "$ENGINE_HOME"
stop_power_assertion
trap - EXIT INT TERM
echo "release qualification PASS: $WORKDIR/qualification.complete.json"
