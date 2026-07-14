#!/bin/bash
# Test Dory with a full Xcode toolchain. Building/testing from the CLI never re-bumps the
# project's objectVersion 77 (only the Xcode GUI does). Override explicitly with
# DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
Usage: scripts/test.sh [--ui] [xcodebuild test arguments]

Runs the Dory unit-test scheme by default. Use --ui (or -only-testing:DoryUITests) to select the
dedicated shared Dory UI Tests scheme. Extra arguments are forwarded to test-without-building.
EOF
}

scheme="Dory"
test_args=()
for argument in "$@"; do
  case "$argument" in
    -h|--help) usage; exit 0 ;;
    --ui) scheme="Dory UI Tests" ;;
    -only-testing:DoryUITests|-only-testing:DoryUITests/*)
      scheme="Dory UI Tests"
      test_args+=("$argument")
      ;;
    *) test_args+=("$argument") ;;
  esac
done

find_xcode() {
  local dev app found
  for app in /Applications/Xcode.app /Applications/Xcode-*.app \
             "$HOME"/Applications/Xcode*.app "$HOME"/Downloads/Xcode*.app; do
    dev="$app/Contents/Developer"
    [ -x "$dev/usr/bin/xcodebuild" ] && { printf '%s' "$dev"; return 0; }
  done
  found="$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | head -1)"
  [ -n "$found" ] && [ -x "$found/Contents/Developer/usr/bin/xcodebuild" ] \
    && { printf '%s' "$found/Contents/Developer"; return 0; }
  return 1
}

if [ -z "${DEVELOPER_DIR:-}" ]; then
  active="$(xcode-select -p 2>/dev/null || true)"
  need_fallback=0
  case "$active" in ""|*CommandLineTools*) need_fallback=1 ;; esac
  [ -x "$active/usr/bin/xcodebuild" ] || need_fallback=1
  if [ "$need_fallback" -eq 1 ]; then
    if DEVELOPER_DIR="$(find_xcode)"; then
      export DEVELOPER_DIR
      echo "note: active xcode-select ('${active:-unset}') has no xcodebuild; using DEVELOPER_DIR=$DEVELOPER_DIR" >&2
    else
      echo "error: no full Xcode found. Install Xcode.app or set DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer" >&2
      exit 1
    fi
  fi
fi

# Hosted macOS tests launch a second Dory.app with the production bundle identifier. LaunchServices
# can route that request to an already-running installed copy and then report the test host as
# damaged (IDELaunchErrorDomain Code 20). Fail with the real remedy before spending time building.
if pgrep -f '/Dory\.app/Contents/MacOS/Dory([[:space:]]|$)' >/dev/null 2>&1; then
  echo "error: quit every running Dory GUI before hosted tests; duplicate com.pythonxi.Dory apps cause LaunchServices Code 20" >&2
  exit 1
fi

cleanup_test_products() {
  scripts/clean-xcode-products.sh
}
trap cleanup_test_products EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

xcode_args=(-project Dory.xcodeproj -scheme "$scheme" -destination 'platform=macOS')
if [ "$scheme" = "Dory UI Tests" ]; then
  xcode_args+=(-parallel-testing-enabled NO)
fi
if [ -n "${CI:-}" ]; then
  xcode_args+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
fi

xcodebuild "${xcode_args[@]}" build-for-testing

# Xcode 27 intermittently re-serializes the project to objectVersion 110 (breaks stable Xcode + CI);
# pin it back to 77 before the test phase. Only rewrites that one line.
sed -i '' 's/objectVersion = 110;/objectVersion = 77;/' Dory.xcodeproj/project.pbxproj 2>/dev/null || true

# Clear quarantine from transient products and unregister stale test bundles before XCTest launch.
# The system-managed provenance attribute is only removed best-effort because SIP may protect it;
# it is not itself a failed Gatekeeper assessment.
scripts/clean-xcode-products.sh

if [ "${#test_args[@]}" -gt 0 ]; then
  xcodebuild "${xcode_args[@]}" test-without-building "${test_args[@]}"
else
  # Bash 3.2 (the system /bin/bash on supported macOS releases) raises "unbound variable"
  # for an empty-array expansion under `set -u`. The unfiltered full suite is the common path.
  xcodebuild "${xcode_args[@]}" test-without-building
fi
scripts/clean-xcode-products.sh
