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
    python3 "$ROOT/scripts/package-renderer-production-bundle.py" prune \
      --runner-app "$RUNNER_APP"
    # CODE_SIGNING_ALLOWED=NO leaves Xcode's linker signatures on copied XPC products. Those
    # signatures do not bind Info.plist or bundle resources and cannot be sealed safely inside the
    # runner. Give development builds the same leaf-to-root graph used by release packaging; the
    # outer build may then sign the runner with either an ad-hoc or Developer ID identity.
    if [ "${CODE_SIGNING_ALLOWED:-NO}" != YES ]; then
      for worker_contract in \
        "DoryFSWorker.xpc:$ROOT/Packages/ContainerizationEngine/DoryFSWorker.entitlements" \
        "DoryRendererWorker.xpc:$ROOT/Packages/ContainerizationEngine/DoryRendererWorker.entitlements"; do
        worker_name="${worker_contract%%:*}"
        worker_entitlements="${worker_contract#*:}"
        worker_bundle="$RUNNER_APP/Contents/XPCServices/$worker_name"
        [ -d "$worker_bundle" ] && [ ! -L "$worker_bundle" ] || {
          echo "error: development runner is missing $worker_name" >&2
          exit 1
        }
        /usr/bin/codesign --force --sign - --options runtime \
          --entitlements "$worker_entitlements" "$worker_bundle"
        /usr/bin/codesign --verify --strict "$worker_bundle"
      done
    fi
    exit 0
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

require_sha256() {
  local value="$1"
  local label="$2"
  [[ "$value" =~ ^[0-9a-f]{64}$ ]] \
    && [ "$value" != 0000000000000000000000000000000000000000000000000000000000000000 ] || {
      echo "error: $label must be a nonzero lowercase SHA-256" >&2
      exit 1
    }
}
require_kernel() {
  local path="$1"
  local digest="$2"
  local label="$3"
  [ -f "$path" ] && [ ! -L "$path" ] || {
    echo "error: $label must name the exact qualified guest-kernel artifact" >&2
    exit 1
  }
  require_sha256 "$digest" "$label digest"
  [ "$(shasum -a 256 "$path" | awk '{ print $1 }')" = "$digest" ] || {
    echo "error: $label bytes differ from its configured digest" >&2
    exit 1
  }
}
require_arm64_linux_kernel() {
  local path="$1"
  python3 - "$path" <<'PY'
import pathlib
import sys

with pathlib.Path(sys.argv[1]).open("rb") as handle:
    header = handle.read(64)
if len(header) < 64 or header[56:60] != b"ARM\x64":
    raise SystemExit(
        "error: DORY_RENDERER_MANAGED_KERNEL must be an arm64 Linux kernel Image"
    )
PY
}
require_pc_linux_kernel() {
  local path="$1"
  [ "$(basename "$path")" = vmlinux-x86-pc-virgl2 ] || {
    echo "error: DORY_RENDERER_PC_MANAGED_KERNEL must be the PC VirGL2 kernel artifact" >&2
    exit 1
  }
  python3 - "$path" <<'PY'
import pathlib
import sys

with pathlib.Path(sys.argv[1]).open("rb") as handle:
    header = handle.read(20)
if (
    len(header) < 20
    or header[:7] != b"\x7fELF\x02\x01\x01"
    or int.from_bytes(header[18:20], "little") != 62
):
    raise SystemExit(
        "error: DORY_RENDERER_PC_MANAGED_KERNEL must be an x86_64 ELF kernel"
    )
PY
  DORY_KERNEL_OUT_DIR="$(cd "$(dirname "$path")" && pwd)" \
    DORY_KERNEL_PROFILE=pc-virgl2 \
    "$ROOT/guest/kernel/verify-build.sh" amd64 >/dev/null || {
      echo "error: DORY_RENDERER_PC_MANAGED_KERNEL does not match the verified PC VirGL2 kernel producer stamp" >&2
      exit 1
    }
}
require_pc_mesa_runtime() {
  local path="$1"
  local digest="$2"
  [ -f "$path" ] && [ ! -L "$path" ] || {
    echo "error: DORY_RENDERER_PC_GUEST_MESA must name the exact verified x86 Mesa producer artifact" >&2
    exit 1
  }
  require_sha256 "$digest" "DORY_RENDERER_PC_GUEST_MESA_SHA256"
  [ "$(basename "$path")" = dory-mesa-virgl2-x86_64.tar.zst ] || {
    echo "error: DORY_RENDERER_PC_GUEST_MESA must be the PC VirGL2 producer artifact" >&2
    exit 1
  }
  [ "$(shasum -a 256 "$path" | awk '{ print $1 }')" = "$digest" ] || {
    echo "error: DORY_RENDERER_PC_GUEST_MESA bytes differ from its configured digest" >&2
    exit 1
  }
  DORY_MESA_OUT_DIR="$(cd "$(dirname "$path")" && pwd)" \
    "$ROOT/guest/mesa/verify-pc-virgl2-build.sh" x86_64 >/dev/null || {
      echo "error: DORY_RENDERER_PC_GUEST_MESA does not match the verified PC VirGL2 producer stamp" >&2
      exit 1
    }
}

MANAGED_KERNEL_SHA256="${DORY_RENDERER_MANAGED_KERNEL_SHA256:-}"
MANAGED_KERNEL="${DORY_RENDERER_MANAGED_KERNEL:-}"
require_kernel "$MANAGED_KERNEL" "$MANAGED_KERNEL_SHA256" "DORY_RENDERER_MANAGED_KERNEL"
require_arm64_linux_kernel "$MANAGED_KERNEL"

PC_MANAGED_KERNEL_SHA256="${DORY_RENDERER_PC_MANAGED_KERNEL_SHA256:-}"
PC_MANAGED_KERNEL="${DORY_RENDERER_PC_MANAGED_KERNEL:-}"
PC_GUEST_MESA_SHA256="${DORY_RENDERER_PC_GUEST_MESA_SHA256:-}"
PC_GUEST_MESA="${DORY_RENDERER_PC_GUEST_MESA:-}"
PC_QUALIFICATION_ENABLED=0
if [ -n "$PC_MANAGED_KERNEL" ] || [ -n "$PC_MANAGED_KERNEL_SHA256" ] \
    || [ -n "$PC_GUEST_MESA" ] || [ -n "$PC_GUEST_MESA_SHA256" ]; then
  [ -n "$PC_MANAGED_KERNEL" ] && [ -n "$PC_MANAGED_KERNEL_SHA256" ] \
    && [ -n "$PC_GUEST_MESA" ] && [ -n "$PC_GUEST_MESA_SHA256" ] || {
      echo "error: PC renderer qualification requires DORY_RENDERER_PC_MANAGED_KERNEL, _SHA256, _GUEST_MESA, and _GUEST_MESA_SHA256" >&2
      exit 1
    }
  require_kernel "$PC_MANAGED_KERNEL" "$PC_MANAGED_KERNEL_SHA256" \
    "DORY_RENDERER_PC_MANAGED_KERNEL"
  require_pc_linux_kernel "$PC_MANAGED_KERNEL"
  require_pc_mesa_runtime "$PC_GUEST_MESA" "$PC_GUEST_MESA_SHA256"
  PC_QUALIFICATION_ENABLED=1
fi
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
PC_SIGNATURE_SOURCE="${DORY_RENDERER_PC_QUALIFICATION_SIGNATURE:-}"
SIGNER="${DORY_RENDERER_QUALIFICATION_SIGNER:-}"
if [ -n "$SIGNATURE_SOURCE" ] && [ -n "$SIGNER" ]; then
  echo "error: choose either an external qualification signature or signer, not both" >&2
  exit 1
fi
if [ -n "$PC_SIGNATURE_SOURCE" ] && [ -n "$SIGNER" ]; then
  echo "error: choose either an external PC qualification signature or signer, not both" >&2
  exit 1
fi
if [ "$QUALIFICATION_MODE" = release ] && [ -z "$SIGNATURE_SOURCE" ] && [ -z "$SIGNER" ]; then
  echo "error: release qualification requires an external detached-signature source" >&2
  exit 1
fi
if [ "$QUALIFICATION_MODE" = release ] && [ "$PC_QUALIFICATION_ENABLED" = 1 ] \
    && [ -z "$PC_SIGNATURE_SOURCE" ] && [ -z "$SIGNER" ]; then
  echo "error: release PC qualification requires an external detached-signature source" >&2
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
  --timestamp \
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
STAGED_PC_RECEIPT="$QUALIFICATION_SCRATCH/renderer-bootstrap-qualification-pc-x86_64-virgl2.json"
STAGED_PC_SIGNATURE="$QUALIFICATION_SCRATCH/renderer-bootstrap-qualification-pc-x86_64-virgl2.json.sig"
rm -f "$STAGED_RECEIPT" "$STAGED_SIGNATURE" "$STAGED_PC_RECEIPT" "$STAGED_PC_SIGNATURE"
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
if [ "$PC_QUALIFICATION_ENABLED" = 1 ]; then
  "$RUNNER_APP/Contents/MacOS/dory-hv" renderer-qualify \
    --producer-fence-contract dory-pc-x86_64-virgl2 \
    --inventory "$RUNNER_APP/Contents/Resources/renderer-production-inventory.json" \
    --managed-kernel-sha256 "$PC_MANAGED_KERNEL_SHA256" \
    --guest-mesa-sha256 "$PC_GUEST_MESA_SHA256" \
    --issued-at "$ISSUED_AT" \
    --expires-at "$EXPIRES_AT" \
    --output "$STAGED_PC_RECEIPT"
  [ -f "$STAGED_PC_RECEIPT" ] && [ ! -L "$STAGED_PC_RECEIPT" ] || {
    echo "error: live PC renderer qualification did not emit a direct receipt" >&2
    exit 1
  }
fi

if [ -n "$SIGNER" ]; then
  [ -f "$SIGNER" ] && [ ! -L "$SIGNER" ] && [ -x "$SIGNER" ] || {
    echo "error: DORY_RENDERER_QUALIFICATION_SIGNER must be a direct executable" >&2
    exit 1
  }
  "$SIGNER" --receipt "$STAGED_RECEIPT" --output "$STAGED_SIGNATURE"
  if [ "$PC_QUALIFICATION_ENABLED" = 1 ]; then
    "$SIGNER" --receipt "$STAGED_PC_RECEIPT" --output "$STAGED_PC_SIGNATURE"
  fi
else
  if [ -n "$SIGNATURE_SOURCE" ]; then
    [ -f "$SIGNATURE_SOURCE" ] && [ ! -L "$SIGNATURE_SOURCE" ] || {
      echo "error: detached renderer qualification signature is unavailable" >&2
      exit 1
    }
    install -m0644 "$SIGNATURE_SOURCE" "$STAGED_SIGNATURE"
  fi
  if [ "$PC_QUALIFICATION_ENABLED" = 1 ] && [ -n "$PC_SIGNATURE_SOURCE" ]; then
    [ -f "$PC_SIGNATURE_SOURCE" ] && [ ! -L "$PC_SIGNATURE_SOURCE" ] || {
      echo "error: detached PC renderer qualification signature is unavailable" >&2
      exit 1
    }
    install -m0644 "$PC_SIGNATURE_SOURCE" "$STAGED_PC_SIGNATURE"
  fi
fi

RUNNER_RESOURCES="$RUNNER_APP/Contents/Resources"
install -m0644 "$STAGED_RECEIPT" \
  "$RUNNER_RESOURCES/renderer-bootstrap-qualification.json"
if [ "$PC_QUALIFICATION_ENABLED" = 1 ]; then
  install -m0644 "$STAGED_PC_RECEIPT" \
    "$RUNNER_RESOURCES/renderer-bootstrap-qualification-pc-x86_64-virgl2.json"
else
  rm -f "$RUNNER_RESOURCES/renderer-bootstrap-qualification-pc-x86_64-virgl2.json"
fi
if [ -f "$STAGED_SIGNATURE" ] && [ ! -L "$STAGED_SIGNATURE" ]; then
  install -m0644 "$STAGED_SIGNATURE" \
    "$RUNNER_RESOURCES/renderer-bootstrap-qualification.json.sig"
else
  rm -f "$RUNNER_RESOURCES/renderer-bootstrap-qualification.json.sig"
fi
if [ "$PC_QUALIFICATION_ENABLED" = 1 ] \
    && [ -f "$STAGED_PC_SIGNATURE" ] && [ ! -L "$STAGED_PC_SIGNATURE" ]; then
  install -m0644 "$STAGED_PC_SIGNATURE" \
    "$RUNNER_RESOURCES/renderer-bootstrap-qualification-pc-x86_64-virgl2.json.sig"
else
  rm -f "$RUNNER_RESOURCES/renderer-bootstrap-qualification-pc-x86_64-virgl2.json.sig"
fi

RELEASE_ARGUMENTS=()
[ "$QUALIFICATION_MODE" = preview ] \
  || RELEASE_ARGUMENTS+=(--require-release-signature)
RUNNER_APP_CANONICAL="$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).resolve(strict=True))' "$RUNNER_APP")"
PC_EVIDENCE_ARGUMENTS=()
if [ "$PC_QUALIFICATION_ENABLED" = 1 ]; then
  PC_EVIDENCE_ARGUMENTS+=(--pc-managed-kernel "$PC_MANAGED_KERNEL")
  PC_EVIDENCE_ARGUMENTS+=(--pc-guest-mesa "$PC_GUEST_MESA")
fi
python3 "$ROOT/scripts/package-renderer-production-bundle.py" seal-evidence \
  --runner-app "$RUNNER_APP_CANONICAL" \
  --managed-kernel "$MANAGED_KERNEL" \
  --expected-team "$EXPECTED_TEAM" \
  "${PC_EVIDENCE_ARGUMENTS[@]+"${PC_EVIDENCE_ARGUMENTS[@]}"}" \
  "${ADHOC_ARGUMENTS[@]+"${ADHOC_ARGUMENTS[@]}"}" \
  "${RELEASE_ARGUMENTS[@]+"${RELEASE_ARGUMENTS[@]}"}"
echo "renderer.qualification.mode=$QUALIFICATION_MODE"
