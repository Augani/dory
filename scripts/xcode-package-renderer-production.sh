#!/bin/bash
# Xcode DoryHVRunner phase: assemble, qualify, and seal the exact dual-Metal renderer.
set -euo pipefail

ROOT="${SRCROOT:?Xcode did not provide SRCROOT}"
RUNNER_APP="${TARGET_BUILD_DIR:?Xcode did not provide TARGET_BUILD_DIR}/${WRAPPER_NAME:?Xcode did not provide WRAPPER_NAME}"
CONFIGURATION_NAME="${CONFIGURATION:?Xcode did not provide CONFIGURATION}"
if [ "$CONFIGURATION_NAME" = Release ]; then
  DEFAULT_ENABLED=1
else
  DEFAULT_ENABLED=0
fi
if [ -n "${DORY_BUNDLE_RENDERER:-}" ] && [ -n "${DORY_BUNDLE_VENUS:-}" ] \
    && [ "$DORY_BUNDLE_RENDERER" != "$DORY_BUNDLE_VENUS" ]; then
  echo "error: DORY_BUNDLE_RENDERER and legacy DORY_BUNDLE_VENUS disagree" >&2
  exit 1
fi
if [ -n "${DORY_BUNDLE_RENDERER_REQUIRED:-}" ] \
    && [ -n "${DORY_BUNDLE_VENUS_REQUIRED:-}" ] \
    && [ "$DORY_BUNDLE_RENDERER_REQUIRED" != "$DORY_BUNDLE_VENUS_REQUIRED" ]; then
  echo "error: DORY_BUNDLE_RENDERER_REQUIRED and legacy DORY_BUNDLE_VENUS_REQUIRED disagree" >&2
  exit 1
fi
ENABLED="${DORY_BUNDLE_RENDERER:-${DORY_BUNDLE_VENUS:-$DEFAULT_ENABLED}}"
REQUIRED="${DORY_BUNDLE_RENDERER_REQUIRED:-${DORY_BUNDLE_VENUS_REQUIRED:-$ENABLED}}"
ALLOW_ADHOC_TEST="${DORY_RENDERER_ALLOW_ADHOC_TEST:-0}"
QUALIFICATION_MODE="${DORY_RENDERER_QUALIFICATION_MODE:-preview}"

case "$ENABLED:$REQUIRED" in
  0:0)
    exec python3 "$ROOT/scripts/package-renderer-production-bundle.py" prune \
      --runner-app "$RUNNER_APP"
    ;;
  0:1)
    echo "error: renderer-required=1 requires renderer-enabled=1" >&2
    exit 1 ;;
  1:0|1:1) ;;
  *) echo "error: renderer enabled/required controls must be 0 or 1" >&2; exit 1 ;;
esac
case "$ALLOW_ADHOC_TEST" in
  0|1) ;;
  *) echo "error: DORY_RENDERER_ALLOW_ADHOC_TEST must be 0 or 1" >&2; exit 1 ;;
esac
case "$QUALIFICATION_MODE" in
  preview|release) ;;
  *) echo "error: DORY_RENDERER_QUALIFICATION_MODE must be preview or release" >&2; exit 1 ;;
esac

[ "$CONFIGURATION_NAME" = Release ] || {
  echo "error: the production renderer tuple may only be packaged by a Release runner target" >&2
  exit 1
}
# Xcode provides ARCHS as a space-delimited build-setting list.
# shellcheck disable=SC2086
set -- ${ARCHS:?Xcode did not provide ARCHS}
[ "$#" -eq 1 ] && [ "$1" = arm64 ] || {
  echo "error: the production renderer tuple requires an exactly arm64 runner build" >&2
  exit 1
}
[ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] || {
  echo "error: production renderer packaging requires Xcode code signing" >&2
  exit 1
}
[ "${ENABLE_HARDENED_RUNTIME:-NO}" = YES ] || {
  echo "error: production renderer packaging requires the hardened runtime" >&2
  exit 1
}

LINK_ROOT="${DORY_RENDERER_LINK_ROOT:-$ROOT/release-build/virglrenderer-static}"
LINK_INVENTORY="${DORY_RENDERER_LINK_INVENTORY:-$LINK_ROOT/renderer-static-link-inventory.json}"
WORKER_SCRATCH="${TARGET_TEMP_DIR:?Xcode did not provide TARGET_TEMP_DIR}/DoryRendererProductionWorker"
SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
EXPECTED_TEAM="${DEVELOPMENT_TEAM:--}"
if [ -z "$EXPECTED_TEAM" ] || [ "$EXPECTED_TEAM" = - ]; then
  EXPECTED_TEAM=-
  SIGN_IDENTITY=-
  [ "$ALLOW_ADHOC_TEST" = 1 ] || {
    echo "error: ad-hoc renderer verification is allowed only with DORY_RENDERER_ALLOW_ADHOC_TEST=1" >&2
    exit 1
  }
elif [ "$ALLOW_ADHOC_TEST" = 1 ]; then
  echo "error: DORY_RENDERER_ALLOW_ADHOC_TEST cannot weaken a production signing identity" >&2
  exit 1
elif [ -z "$SIGN_IDENTITY" ] || [ "$SIGN_IDENTITY" = - ]; then
  echo "error: production renderer assembly requires Xcode's expanded signing identity" >&2
  exit 1
fi

ADHOC_ARGUMENTS=()
[ "$ALLOW_ADHOC_TEST" = 0 ] || ADHOC_ARGUMENTS+=(--allow-adhoc-test)

MANAGED_KERNEL_SHA256="${DORY_RENDERER_MANAGED_KERNEL_SHA256:-}"
MANAGED_KERNEL="${DORY_RENDERER_MANAGED_KERNEL:-}"
[ -f "$MANAGED_KERNEL" ] && [ ! -L "$MANAGED_KERNEL" ] || {
  echo "error: DORY_RENDERER_MANAGED_KERNEL must name the exact qualified guest-kernel artifact" >&2
  exit 1
}
[[ "$MANAGED_KERNEL_SHA256" =~ ^[0-9a-f]{64}$ ]] \
  && [ "$MANAGED_KERNEL_SHA256" != 0000000000000000000000000000000000000000000000000000000000000000 ] || {
    echo "error: DORY_RENDERER_MANAGED_KERNEL_SHA256 must bind the exact qualified guest kernel" >&2
    exit 1
  }
[ "$(shasum -a 256 "$MANAGED_KERNEL" | awk '{ print $1 }')" = "$MANAGED_KERNEL_SHA256" ] || {
  echo "error: managed renderer kernel bytes differ from DORY_RENDERER_MANAGED_KERNEL_SHA256" >&2
  exit 1
}
ISSUED_AT="${DORY_RENDERER_QUALIFICATION_ISSUED_AT:-}"
EXPIRES_AT="${DORY_RENDERER_QUALIFICATION_EXPIRES_AT:-}"
if [ -z "$ISSUED_AT" ] && [ -z "$EXPIRES_AT" ] && [ "$QUALIFICATION_MODE" = preview ]; then
  ISSUED_AT="$(python3 - <<'PY'
import datetime

issued = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
print(issued.strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
  )"
  EXPIRES_AT="$(python3 - "$ISSUED_AT" <<'PY'
import datetime
import sys

issued = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")
print((issued + datetime.timedelta(days=30)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
  )"
elif [ -z "$ISSUED_AT" ] || [ -z "$EXPIRES_AT" ]; then
  echo "error: qualification issuance and expiry must be supplied together" >&2
  exit 1
fi
python3 - "$ISSUED_AT" "$EXPIRES_AT" <<'PY'
import datetime
import re
import sys

pattern = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")
if not all(pattern.fullmatch(value) for value in sys.argv[1:]):
    raise SystemExit("error: renderer qualification timestamps must be canonical whole-second UTC")
issued, expires = (
    datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    for value in sys.argv[1:]
)
if expires <= issued or expires - issued > datetime.timedelta(days=548):
    raise SystemExit("error: renderer qualification validity must be positive and at most 548 days")
PY

SIGNATURE_SOURCE="${DORY_RENDERER_QUALIFICATION_SIGNATURE:-}"
SIGNER="${DORY_RENDERER_QUALIFICATION_SIGNER:-}"
if [ -n "$SIGNATURE_SOURCE" ] && [ -n "$SIGNER" ]; then
  echo "error: choose either an external qualification signature or signer, not both" >&2
  exit 1
fi
if [ "$QUALIFICATION_MODE" = release ] && [ -z "$SIGNATURE_SOURCE" ] && [ -z "$SIGNER" ]; then
  echo "error: release qualification requires an external detached-signature source" >&2
  exit 1
fi

"$ROOT/scripts/assemble-renderer-production-worker.sh" \
  --runner-app "$RUNNER_APP" \
  --link-root "$LINK_ROOT" \
  --link-inventory "$LINK_INVENTORY" \
  --scratch-path "$WORKER_SCRATCH" \
  --sign-identity "$SIGN_IDENTITY" \
  --expected-team "$EXPECTED_TEAM" \
  "${ADHOC_ARGUMENTS[@]+"${ADHOC_ARGUMENTS[@]}"}"

python3 "$ROOT/scripts/package-renderer-production-bundle.py" package \
  --runner-app "$RUNNER_APP" \
  --link-root "$LINK_ROOT" \
  --link-inventory "$LINK_INVENTORY" \
  --runner-entitlements "$ROOT/Packages/ContainerizationEngine/dory-hv.entitlements" \
  --expected-team "$EXPECTED_TEAM" \
  "${ADHOC_ARGUMENTS[@]+"${ADHOC_ARGUMENTS[@]}"}"

# The already-signed nested XPC authenticates the caller's team before returning capability bytes.
# Seal an intermediate runner only for that live peer-authenticated launch. The receipt mutation
# deliberately invalidates this intermediate seal; Xcode applies the final enclosing signature
# after this build phase has finished.
/usr/bin/codesign \
  --force \
  --sign "$SIGN_IDENTITY" \
  --identifier com.pythonxi.Dory.HVRunner \
  --options runtime \
  --entitlements "$ROOT/Packages/ContainerizationEngine/dory-hv.entitlements" \
  "$RUNNER_APP"
/usr/bin/codesign --verify --strict --deep "$RUNNER_APP"

QUALIFICATION_SCRATCH="$WORKER_SCRATCH/qualification"
mkdir -p "$QUALIFICATION_SCRATCH"
[ -d "$QUALIFICATION_SCRATCH" ] && [ ! -L "$QUALIFICATION_SCRATCH" ] || {
  echo "error: renderer qualification scratch is not a direct directory" >&2
  exit 1
}
STAGED_RECEIPT="$QUALIFICATION_SCRATCH/renderer-bootstrap-qualification.json"
STAGED_SIGNATURE="$QUALIFICATION_SCRATCH/renderer-bootstrap-qualification.json.sig"
rm -f "$STAGED_RECEIPT" "$STAGED_SIGNATURE"
"$RUNNER_APP/Contents/MacOS/dory-hv" renderer-qualify \
  --inventory "$RUNNER_APP/Contents/Resources/renderer-production-inventory.json" \
  --managed-kernel-sha256 "$MANAGED_KERNEL_SHA256" \
  --issued-at "$ISSUED_AT" \
  --expires-at "$EXPIRES_AT" \
  --output "$STAGED_RECEIPT"
[ -f "$STAGED_RECEIPT" ] && [ ! -L "$STAGED_RECEIPT" ] || {
  echo "error: live renderer qualification did not emit a direct receipt" >&2
  exit 1
}

if [ -n "$SIGNER" ]; then
  [ -f "$SIGNER" ] && [ ! -L "$SIGNER" ] && [ -x "$SIGNER" ] || {
    echo "error: DORY_RENDERER_QUALIFICATION_SIGNER must be a direct executable" >&2
    exit 1
  }
  "$SIGNER" --receipt "$STAGED_RECEIPT" --output "$STAGED_SIGNATURE"
elif [ -n "$SIGNATURE_SOURCE" ]; then
  [ -f "$SIGNATURE_SOURCE" ] && [ ! -L "$SIGNATURE_SOURCE" ] || {
    echo "error: detached renderer qualification signature is unavailable" >&2
    exit 1
  }
  install -m0644 "$SIGNATURE_SOURCE" "$STAGED_SIGNATURE"
fi

RUNNER_RESOURCES="$RUNNER_APP/Contents/Resources"
install -m0644 "$STAGED_RECEIPT" \
  "$RUNNER_RESOURCES/renderer-bootstrap-qualification.json"
if [ -f "$STAGED_SIGNATURE" ] && [ ! -L "$STAGED_SIGNATURE" ]; then
  install -m0644 "$STAGED_SIGNATURE" \
    "$RUNNER_RESOURCES/renderer-bootstrap-qualification.json.sig"
else
  rm -f "$RUNNER_RESOURCES/renderer-bootstrap-qualification.json.sig"
fi

RELEASE_ARGUMENTS=()
[ "$QUALIFICATION_MODE" = preview ] \
  || RELEASE_ARGUMENTS+=(--require-release-signature)
python3 "$ROOT/scripts/package-renderer-production-bundle.py" seal-evidence \
  --runner-app "$RUNNER_APP" \
  --managed-kernel "$MANAGED_KERNEL" \
  --expected-team "$EXPECTED_TEAM" \
  "${ADHOC_ARGUMENTS[@]+"${ADHOC_ARGUMENTS[@]}"}" \
  "${RELEASE_ARGUMENTS[@]+"${RELEASE_ARGUMENTS[@]}"}"
echo "renderer.qualification.mode=$QUALIFICATION_MODE"
