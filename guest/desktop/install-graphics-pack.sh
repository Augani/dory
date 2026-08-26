#!/bin/bash
set -euo pipefail

ARCHIVE="${1:?usage: install-graphics-pack.sh <archive> <absolute-target-root> <expected-uid>}"
TARGET_ROOT="${2:?usage: install-graphics-pack.sh <archive> <absolute-target-root> <expected-uid>}"
EXPECTED_UID="${3:?usage: install-graphics-pack.sh <archive> <absolute-target-root> <expected-uid>}"

fail() {
  echo "Dory graphics-pack installation failed: $*" >&2
  exit 1
}

[ -f "$ARCHIVE" ] && [ ! -L "$ARCHIVE" ] && [ -s "$ARCHIVE" ] \
  || fail "archive is missing, empty, or indirect"
case "$TARGET_ROOT" in
  /*) ;;
  *) fail "target root must be absolute" ;;
esac
[ -d "$TARGET_ROOT" ] && [ ! -L "$TARGET_ROOT" ] || fail "target root is not a direct directory"
case "$EXPECTED_UID" in
  ''|*[!0-9]*) fail "expected owner UID is invalid" ;;
esac
command -v zstd >/dev/null 2>&1 || fail "zstd is required"

parent="${TARGET_ROOT%/}/opt/dory"
[ -n "$parent" ] || parent=/opt/dory
install -d -m0755 "$parent"
journal="$parent/.mesa-update-transaction"
destination="$parent/mesa"

recover_interrupted_transaction() {
  [ -d "$journal" ] || return 0
  owner_pid=$(sed -n 's/^pid=//p' "$journal/owner" 2>/dev/null || true)
  case "$owner_pid" in
    ''|*[!0-9]*) ;;
    *)
      if kill -0 "$owner_pid" 2>/dev/null; then
        fail "another graphics-pack transaction is active"
      fi
      ;;
  esac
  if [ ! -e "$destination" ] && [ -d "$journal/previous" ]; then
    mv "$journal/previous" "$destination"
  fi
  rm -rf "$journal"
}

recover_interrupted_transaction
mkdir -m0700 "$journal" || fail "could not acquire the graphics-pack transaction"
printf 'pid=%s\n' "$$" > "$journal/owner"
stage=$(mktemp -d "$journal/stage.XXXXXX")
installed=0
had_previous=0
cleanup() {
  result=$?
  if [ "$result" -ne 0 ]; then
    if [ "$installed" -eq 1 ]; then
      rm -rf "$destination"
    fi
    if [ "$had_previous" -eq 1 ] && [ -d "$journal/previous" ]; then
      mv "$journal/previous" "$destination"
    fi
  fi
  rm -rf "$journal"
  exit "$result"
}
trap cleanup EXIT INT TERM

members=$(zstd -q -d -c "$ARCHIVE" | tar -tf -) || fail "archive inventory is unreadable"
while IFS= read -r member; do
  normalized=${member#./}
  normalized=${normalized%/}
  case "$normalized" in
    ''|.|opt|opt/dory|opt/dory/mesa|opt/dory/mesa/*) ;;
    *) fail "archive writes outside /opt/dory/mesa: $member" ;;
  esac
  case "$normalized" in
    /*|..|../*|*/..|*/../*|*//*|*\\*) fail "archive contains an unsafe path: $member" ;;
  esac
done <<< "$members"

zstd -q -d -c "$ARCHIVE" \
  | tar --extract --file - --directory "$stage" --no-same-owner --no-same-permissions \
  || fail "archive extraction failed"
candidate="$stage/opt/dory/mesa"
[ -d "$candidate" ] && [ ! -L "$candidate" ] || fail "archive has no direct Mesa tree"
if find "$candidate" -type l -print -quit | grep -q .; then
  fail "runtime pack contains an indirect path"
fi
if find "$candidate" ! -type f ! -type d -print -quit | grep -q .; then
  fail "runtime pack contains a special file"
fi
actual_files=$(find "$candidate" -type f -print \
  | sed "s#^$candidate/##" | LC_ALL=C sort)
expected_files='lib/libvulkan_virtio.so
libexec/dory-vulkan-compositor-probe
libexec/dory-vulkan-probe
share/dory/build-packages.txt
share/dory/runtime.env
share/vulkan/icd.d/virtio_icd.aarch64.json'
[ "$actual_files" = "$expected_files" ] || fail "runtime pack file allowlist differs"
for required in $expected_files; do
  [ -s "$candidate/$required" ] || fail "runtime pack file is empty: $required"
done
if find "$candidate" \( -type f -o -type d \) \
    \( -perm -020 -o -perm -002 \) -print -quit | grep -q .; then
  fail "runtime pack contains a group- or world-writable path"
fi
while IFS= read -r path; do
  if stat -c %u "$path" >/dev/null 2>&1; then
    owner=$(stat -c %u "$path")
    links=$(stat -c %h "$path")
  else
    owner=$(stat -f %u "$path")
    links=$(stat -f %l "$path")
  fi
  [ "$owner" = "$EXPECTED_UID" ] || fail "runtime pack path has owner $owner: $path"
  if [ -f "$path" ]; then
    [ "$links" -eq 1 ] || fail "runtime pack contains a multiply-linked file: $path"
  fi
done < <(find "$candidate" -print)
grep -Fqx 'schema=6' "$candidate/share/dory/runtime.env" \
  || fail "runtime pack schema is unsupported"
grep -Fqx 'pack_layout=single-tree' "$candidate/share/dory/runtime.env" \
  || fail "runtime pack layout is unsupported"

if [ -e "$destination" ]; then
  [ -d "$destination" ] && [ ! -L "$destination" ] \
    || fail "existing graphics-pack destination is indirect"
  mv "$destination" "$journal/previous"
  had_previous=1
fi
mv "$candidate" "$destination"
installed=1

# The new tree was fully validated before either rename. Removing the prior tree now also removes
# every stale schema/file that an overlay update could accidentally leave loader-visible.
if [ "$had_previous" -eq 1 ]; then
  rm -rf "$journal/previous"
  had_previous=0
fi
installed=0
rm -rf "$journal"
trap - EXIT INT TERM
