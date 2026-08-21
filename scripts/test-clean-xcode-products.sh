#!/bin/bash
# Offline regression for macOS 27's stale LaunchServices/provenance test-host rejection.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dory-clean-xcode.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PRODUCTS="$TMP/DerivedData/Dory-fixture/Build/Products/Debug"
APP="$PRODUCTS/Dory.app"
RUNNER="$PRODUCTS/DoryUITests-Runner.app"
mkdir -p "$APP/Contents/MacOS" "$RUNNER/Contents/MacOS"
printf 'app\n' > "$APP/Contents/MacOS/Dory"
printf 'runner\n' > "$RUNNER/Contents/MacOS/DoryUITests-Runner"
xattr -w com.apple.quarantine '0081;fixture;DoryTests;' "$APP/Contents/MacOS/Dory"
xattr -w com.apple.quarantine '0081;fixture;DoryTests;' "$RUNNER/Contents/MacOS/DoryUITests-Runner"
xattr -wx com.apple.provenance 01020a "$APP/Contents/MacOS/Dory"
xattr -wx com.apple.provenance 01020a "$RUNNER/Contents/MacOS/DoryUITests-Runner"

LS_LOG="$TMP/lsregister.log"
cat > "$TMP/lsregister" <<'SH'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$DORY_TEST_LSREGISTER_LOG"
if [ "${1:-}" = -dump ]; then exit 0; fi
SH
chmod +x "$TMP/lsregister"

DORY_LSREGISTER_BIN="$TMP/lsregister" DORY_TEST_LSREGISTER_LOG="$LS_LOG" \
  scripts/clean-xcode-products.sh --root "$TMP/DerivedData"

if xattr -p com.apple.quarantine "$APP/Contents/MacOS/Dory" >/dev/null 2>&1; then
  echo "test-clean-xcode-products: Dory test host quarantine survived cleanup" >&2
  exit 1
fi
if xattr -p com.apple.quarantine "$RUNNER/Contents/MacOS/DoryUITests-Runner" >/dev/null 2>&1; then
  echo "test-clean-xcode-products: UI test runner quarantine survived cleanup" >&2
  exit 1
fi
grep -Fq -- "-u $APP" "$LS_LOG" \
  || { echo "test-clean-xcode-products: Dory test host was not unregistered" >&2; exit 1; }
grep -Fq -- "-u $RUNNER" "$LS_LOG" \
  || { echo "test-clean-xcode-products: UI test runner was not unregistered" >&2; exit 1; }
grep -Fq 'trap cleanup_test_products EXIT' scripts/test.sh \
  || { echo "test-clean-xcode-products: failure-path cleanup trap is missing" >&2; exit 1; }
grep -Fq 'duplicate com.pythonxi.Dory apps cause LaunchServices Code 20' scripts/test.sh \
  || { echo "test-clean-xcode-products: duplicate-app preflight is missing" >&2; exit 1; }
grep -Fq 'has_quarantine_xattrs' scripts/clean-xcode-products.sh \
  || { echo "test-clean-xcode-products: cleanup does not verify quarantine removal" >&2; exit 1; }
grep -Fq 'provenance is system-managed' scripts/clean-xcode-products.sh \
  || { echo "test-clean-xcode-products: protected provenance policy is missing" >&2; exit 1; }

bash -n scripts/clean-xcode-products.sh scripts/test.sh
echo "test-clean-xcode-products: PASS"
