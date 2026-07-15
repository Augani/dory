#!/bin/bash
# Single public test entrypoint for Dory's Rust, Swift package, app, and UI suites.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<'EOF'
Usage: scripts/test.sh [all|rust|swift|app|ui|build] [-- xcodebuild arguments]

  all    Run every test suite (default)
  rust   Run formatting, lint, and tests for the Rust workspace
  swift  Run both Swift package test suites
  app    Run the Dory app unit-test scheme
  ui     Run the dedicated Dory UI-test scheme
  build  Compile the Apple Silicon app without running tests

Arguments after -- are forwarded to xcodebuild for app, ui, and build modes.
EOF
}

mode="all"
if [ "$#" -gt 0 ]; then
  case "$1" in
    all|rust|swift|app|ui|build) mode="$1"; shift ;;
    -h|--help) usage; exit 0 ;;
  esac
fi
[ "${1:-}" != -- ] || shift
xcode_extra=("$@")

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "test: required command is missing: $1" >&2
    exit 1
  }
}

select_xcode() {
  [ "$(uname -s)" = Darwin ] || {
    echo "test: $mode requires macOS" >&2
    exit 1
  }
  if [ -z "${DEVELOPER_DIR:-}" ]; then
    local app developer
    for app in /Applications/Xcode-26.6.0-Release.Candidate.app \
               /Applications/Xcode.app /Applications/Xcode-*.app \
               "$HOME"/Applications/Xcode*.app; do
      developer="$app/Contents/Developer"
      if [ -x "$developer/usr/bin/xcodebuild" ]; then
        export DEVELOPER_DIR="$developer"
        break
      fi
    done
  fi
  require xcodebuild
}

clean_test_products() {
  [ "$(uname -s)" = Darwin ] || return 0
  scripts/clean-xcode-products.sh >/dev/null
}

cleanup_after_xcode() {
  local status=$?
  trap - EXIT INT TERM
  clean_test_products || true
  exit "$status"
}

run_xcodebuild() {
  # macOS still ships Bash 3.2, where expanding an empty array under `set -u` aborts the script.
  # Disable nounset only while forwarding the optional argument list.
  set +u
  xcodebuild "$@" "${xcode_extra[@]}"
  local status=$?
  set -u
  return "$status"
}

run_rust() {
  require cargo
  (
    cd dory-core
    cargo fmt --all -- --check
    cargo clippy --workspace --all-targets --locked -- -D warnings
    cargo test --workspace --locked
  )
}

prepare_swift() {
  select_xcode
  scripts/build-dory-ffi-xcframework.sh --if-needed
}

run_swift() {
  prepare_swift
  swift test --package-path dory-core-swift
  swift test --package-path Packages/ContainerizationEngine
}

run_app() {
  prepare_swift
  if pgrep -f '/Dory\.app/Contents/MacOS/Dory([[:space:]]|$)' >/dev/null 2>&1; then
    echo "test: quit every running Dory app before hosted tests" >&2
    exit 1
  fi
  clean_test_products
  trap cleanup_after_xcode EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [ -n "${CI:-}" ]; then
    run_xcodebuild test \
      -project Dory.xcodeproj \
      -scheme Dory \
      -destination 'platform=macOS' \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO
  else
    run_xcodebuild test \
      -project Dory.xcodeproj \
      -scheme Dory \
      -destination 'platform=macOS'
  fi
  clean_test_products
  trap - EXIT INT TERM
}

run_ui() {
  prepare_swift
  if pgrep -f '/Dory\.app/Contents/MacOS/Dory([[:space:]]|$)' >/dev/null 2>&1; then
    echo "test: quit every running Dory app before UI tests" >&2
    exit 1
  fi
  clean_test_products
  trap cleanup_after_xcode EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  run_xcodebuild test \
    -project Dory.xcodeproj \
    -scheme 'Dory UI Tests' \
    -destination 'platform=macOS' \
    -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGN_IDENTITY=-
  clean_test_products
  trap - EXIT INT TERM
}

run_build() {
  prepare_swift
  run_xcodebuild build \
    -project Dory.xcodeproj \
    -scheme Dory \
    -destination 'generic/platform=macOS' \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO
}

case "$mode" in
  rust) run_rust ;;
  swift) run_swift ;;
  app) run_app ;;
  ui) run_ui ;;
  build) run_build ;;
  all)
    run_rust
    if [ "$(uname -s)" = Darwin ]; then
      run_swift
      run_app
      run_ui
    fi
    ;;
esac
