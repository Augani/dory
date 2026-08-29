#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dory-release-kernel-gate.XXXXXX")"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "release guest-kernel gate test failed: $*" >&2
  exit 1
}

FIXTURE="$TMP_ROOT/repository"
mkdir -p "$FIXTURE/guest/kernel" "$FIXTURE/guest/out"
cp "$ROOT/guest/kernel/verify-release-package.sh" "$FIXTURE/guest/kernel/"
cat > "$FIXTURE/guest/kernel/verify-build.sh" <<'VERIFY'
#!/bin/bash
set -eu
case "${DORY_KERNEL_PROFILE:?}" in
  headless) artifact=Image ;;
  venus) artifact=Image-gpu ;;
  accelerated-desktop) artifact=Image-desktop ;;
  *) exit 65 ;;
esac
[ "${DORY_EXPERIMENTAL_GPU:?}" = 0 ] || exit 66
[ -s "${DORY_KERNEL_OUT_DIR:?}/$artifact" ] || exit 67
printf '%s|%s|%s|%s\n' \
  "$DORY_KERNEL_PROFILE" "$DORY_EXPERIMENTAL_GPU" "$DORY_KERNEL_OUT_DIR" "${1:-}" \
  >> "${FAKE_VERIFY_LOG:?}"
[ "${FAKE_FAIL_PROFILE:-}" != "$DORY_KERNEL_PROFILE" ]
VERIFY
chmod +x "$FIXTURE/guest/kernel/verify-build.sh"
GATE="$FIXTURE/guest/kernel/verify-release-package.sh"
VERIFY_LOG="$TMP_ROOT/verify.log"

run_gate() {
  env -i \
    PATH="/usr/bin:/bin" \
    TMPDIR="${TMPDIR:-/tmp}" \
    FAKE_VERIFY_LOG="$VERIFY_LOG" \
    "$@" \
    /bin/bash "$GATE"
}

assert_log() {
  local expected="$1"
  grep -Fqx -- "$expected" "$VERIFY_LOG" \
    || fail "verification log is missing: $expected"
}

assert_log_count() {
  local expected="$1" actual
  actual="$(wc -l < "$VERIFY_LOG" | tr -d ' ')"
  [ "$actual" = "$expected" ] \
    || fail "expected $expected verifier calls, found $actual"
}

# Debug and explicit no-asset Release configurations must not consult release artifacts.
: > "$VERIFY_LOG"
run_gate CONFIGURATION=Debug FAKE_FAIL_PROFILE=headless >/dev/null
assert_log_count 0
run_gate CONFIGURATION=Release DORY_BUILD_DEBUG_HELPERS=0 FAKE_FAIL_PROFILE=headless >/dev/null
assert_log_count 0

# A normal Release build verifies every artifact the post-build helper will copy. Desktop remains
# opt-in, so it is not consulted until a distro bundle is requested.
printf 'headless\n' > "$FIXTURE/guest/out/Image"
printf 'venus\n' > "$FIXTURE/guest/out/Image-gpu"
printf 'desktop\n' > "$FIXTURE/guest/out/Image-desktop"
: > "$VERIFY_LOG"
run_gate CONFIGURATION=Release >/dev/null
assert_log_count 2
assert_log "headless|0|$FIXTURE/guest/out|arm64"
assert_log "venus|0|$FIXTURE/guest/out|arm64"
if grep -Fq 'accelerated-desktop|' "$VERIFY_LOG"; then
  fail "desktop kernel was verified for a headless-only bundle"
fi

: > "$VERIFY_LOG"
run_gate CONFIGURATION=Release DORY_DESKTOP_BUNDLE_MODE=ubuntu >/dev/null
assert_log_count 3
assert_log "accelerated-desktop|0|$FIXTURE/guest/out|arm64"

# Optional missing artifacts are skipped, but required Core and Venus artifacts fail closed.
rm "$FIXTURE/guest/out/Image" "$FIXTURE/guest/out/Image-gpu"
: > "$VERIFY_LOG"
run_gate CONFIGURATION=Release DORY_REQUIRE_CORE_ASSETS=0 >/dev/null
assert_log_count 0
if run_gate CONFIGURATION=Release >/dev/null 2>&1; then
  fail "Release accepted a missing required headless kernel"
fi
if run_gate CONFIGURATION=Release DORY_REQUIRE_CORE_ASSETS=0 \
    DORY_BUNDLE_VENUS_REQUIRED=1 >/dev/null 2>&1; then
  fail "Release accepted a missing required Venus kernel"
fi

# A verifier failure is propagated before Xcode can finish the Release product.
printf 'headless\n' > "$FIXTURE/guest/out/Image"
printf 'venus\n' > "$FIXTURE/guest/out/Image-gpu"
if run_gate CONFIGURATION=Release FAKE_FAIL_PROFILE=venus >/dev/null 2>&1; then
  fail "Release swallowed the Venus provenance failure"
fi

if run_gate CONFIGURATION=Release DORY_BUILD_DEBUG_HELPERS=invalid >/dev/null 2>&1; then
  fail "Release accepted an invalid asset-bundling control"
fi
if run_gate CONFIGURATION=Release DORY_BUILD_DEBUG_HELPERS=0 \
    DORY_DESKTOP_BUNDLE_MODE=ubuntu >/dev/null 2>&1; then
  fail "Release accepted a desktop bundle with guest assets disabled"
fi

PROJECT="$ROOT/Dory.xcodeproj/project.pbxproj"
grep -Fq 'Verify Release Guest Kernels' "$PROJECT" \
  || fail "Dory target has no Release guest-kernel build phase"
grep -Fq 'guest/kernel/verify-release-package.sh' "$PROJECT" \
  || fail "Xcode phase does not invoke the focused kernel gate"

echo "release guest-kernel gate tests passed"
