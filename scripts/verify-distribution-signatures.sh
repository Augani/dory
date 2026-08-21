#!/bin/bash
# Verify the notarization-facing contract for every Mach-O nested anywhere in an application.
set -euo pipefail

APP="${1:?usage: verify-distribution-signatures.sh <Dory.app> <expected-team-id>}"
EXPECTED_TEAM="${2:?usage: verify-distribution-signatures.sh <Dory.app> <expected-team-id>}"

fail() {
  echo "distribution signature error: $*" >&2
  exit 1
}

[ -d "$APP" ] && [ ! -L "$APP" ] || fail "application is missing or indirect: $APP"
APP_LOGICAL="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$APP")"
APP_PHYSICAL="$(cd "$APP" && pwd -P)"
[ "$APP_LOGICAL" = "$APP_PHYSICAL" ] || fail "application has an indirect ancestor"
printf '%s\n' "$EXPECTED_TEAM" | grep -Eq '^[A-Z0-9]{10}$' \
  || fail "expected team ID must be ten uppercase alphanumeric characters"
for tool in codesign file find grep mktemp; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
done

python3 - "$APP_PHYSICAL" <<'PY' || fail "application contains a symlink that escapes its bundle"
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for directory, names, files in os.walk(root, followlinks=False):
    for name in names + files:
        path = pathlib.Path(directory, name)
        if path.is_symlink():
            target = path.resolve(strict=False)
            if os.path.commonpath((root, target)) != str(root):
                raise SystemExit(f"escaping symlink: {path} -> {os.readlink(path)}")
PY

codesign --verify --strict --deep --verbose=2 "$APP" \
  || fail "application or nested code has an invalid signature: $APP"

inventory="$(mktemp "${TMPDIR:-/tmp}/dory-signatures.XXXXXX")"
trap 'rm -f "$inventory"' EXIT
find "$APP" -type f -print0 > "$inventory"

count=0
while IFS= read -r -d '' path; do
  description="$(file -b "$path")" || fail "could not identify file type: $path"
  case "$description" in
    *Mach-O*) ;;
    *) continue ;;
  esac

  count=$((count + 1))
  details="$(codesign -d --verbose=4 "$path" 2>&1)" \
    || fail "could not inspect code signature: $path"
  printf '%s\n' "$details" | grep -F 'Authority=Developer ID Application:' >/dev/null \
    || fail "Mach-O is not signed by a Developer ID Application certificate: $path"
  printf '%s\n' "$details" | grep -Fx "TeamIdentifier=$EXPECTED_TEAM" >/dev/null \
    || fail "Mach-O is not signed by expected team $EXPECTED_TEAM: $path"
  printf '%s\n' "$details" | grep -E '^Timestamp=' >/dev/null \
    || fail "Mach-O signature has no secure timestamp: $path"
  printf '%s\n' "$details" | grep -E '^CodeDirectory .+flags=.*\([^)]*runtime[^)]*\)' >/dev/null \
    || fail "Mach-O does not enable hardened runtime: $path"
  codesign --verify --strict --verbose=2 "$path" \
    || fail "Mach-O signature is invalid: $path"
done < "$inventory"

[ "$count" -gt 0 ] || fail "application contains no Mach-O code: $APP"
echo "Distribution signatures: PASS ($count Mach-O files; team $EXPECTED_TEAM)"
