#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: build-native-package.sh --format deb|rpm --output-dir ABSOLUTE_DIRECTORY

Run inside the matching stock Linux guest from a clean Dory checkout. Builds the package from
tracked source in an isolated temporary directory, verifies its native architecture, and writes
the package plus a source-bound SHA-256 receipt. This does not build a guest image or cross-compile.
EOF
}

package_format=""
output_dir=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --format) [ "$#" -ge 2 ] || { usage; exit 64; }; package_format="$2"; shift 2 ;;
    --output-dir) [ "$#" -ge 2 ] || { usage; exit 64; }; output_dir="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 64 ;;
  esac
done

case "$package_format" in deb|rpm) ;; *) usage; exit 64 ;; esac
case "$output_dir" in /*) ;; *) echo "--output-dir must be absolute" >&2; exit 64 ;; esac
[ "$(uname -s)" = Linux ] || { echo "native package build requires Linux" >&2; exit 69; }

case "$(uname -m)" in
  aarch64) guest_architecture=arm64; deb_arch=arm64; rpm_arch=aarch64 ;;
  x86_64) guest_architecture=x86_64; deb_arch=amd64; rpm_arch=x86_64 ;;
  *) echo "only native ARM64 and x86_64 Linux guests are supported" >&2; exit 69 ;;
esac

for required in git tar sha256sum mktemp; do
  command -v "$required" >/dev/null 2>&1 \
    || { echo "required command is unavailable: $required" >&2; exit 69; }
done
repository_root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
[ -f "$repository_root/dory-core/Cargo.lock" ] \
  || { echo "Dory source checkout is incomplete" >&2; exit 66; }
[ -z "$(git -C "$repository_root" status --porcelain --untracked-files=normal)" ] \
  || { echo "package source checkout must be clean" >&2; exit 65; }
source_commit="$(git -C "$repository_root" rev-parse HEAD)"
case "$source_commit" in
  *[!0-9a-f]*|'') echo "source commit is invalid" >&2; exit 65 ;;
esac
[ "${#source_commit}" -eq 40 ] || { echo "source commit is invalid" >&2; exit 65; }

if [ "$package_format" = deb ]; then
  for required in dpkg dpkg-buildpackage dpkg-deb cargo rustc protoc; do
    command -v "$required" >/dev/null 2>&1 \
      || { echo "required Debian build command is unavailable: $required" >&2; exit 69; }
  done
  [ "$(dpkg --print-architecture)" = "$deb_arch" ] \
    || { echo "dpkg architecture does not match the native CPU" >&2; exit 65; }
else
  for required in rpm rpmbuild cargo rustc protoc; do
    command -v "$required" >/dev/null 2>&1 \
      || { echo "required RPM build command is unavailable: $required" >&2; exit 69; }
  done
  [ "$(rpm --eval '%{_arch}')" = "$rpm_arch" ] \
    || { echo "RPM architecture does not match the native CPU" >&2; exit 65; }
fi

build_work="$(mktemp -d "${TMPDIR:-/tmp}/dory-native-package.XXXXXX")"
cleanup() { rm -rf "$build_work"; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$build_work/source"
git -C "$repository_root" archive --format=tar "$source_commit" \
  dory-core GuestTools/Linux LICENSE | tar -xf - -C "$build_work/source"

if [ "$package_format" = deb ]; then
  (
    cd "$build_work/source/GuestTools/Linux"
    dpkg-buildpackage --build=binary --no-sign
  )
  mapfile -d '' packages < <(find "$build_work/source/GuestTools" -maxdepth 1 \
    -type f -name "dory-guest-tools_*_${deb_arch}.deb" -print0)
else
  mkdir -p "$build_work/rpmbuild"
  rpmbuild -bb "$build_work/source/GuestTools/Linux/rpm/dory-guest-tools.spec" \
    --define "_sourcedir $build_work/source" \
    --define "_topdir $build_work/rpmbuild"
  mapfile -d '' packages < <(find "$build_work/rpmbuild/RPMS" \
    -type f -name "dory-guest-tools-*.${rpm_arch}.rpm" -print0)
fi
[ "${#packages[@]}" -eq 1 ] \
  || { echo "expected exactly one native dory-guest-tools package" >&2; exit 65; }
package="${packages[0]}"
package_name="$(basename "$package")"
case "$package_name" in
  *[!A-Za-z0-9._+~-]*|'') echo "package filename is unsafe" >&2; exit 65 ;;
esac

if [ "$package_format" = deb ]; then
  [ "$(dpkg-deb --field "$package" Package)" = dory-guest-tools ] \
    && [ "$(dpkg-deb --field "$package" Architecture)" = "$deb_arch" ] \
    || { echo "Debian package identity or architecture is wrong" >&2; exit 65; }
else
  [ "$(rpm -qp --queryformat '%{NAME} %{ARCH}' "$package")" \
    = "dory-guest-tools $rpm_arch" ] \
    || { echo "RPM package identity or architecture is wrong" >&2; exit 65; }
fi

mkdir -p "$output_dir"
[ -d "$output_dir" ] && [ ! -L "$output_dir" ] \
  || { echo "output directory must be a direct directory" >&2; exit 65; }
destination="$output_dir/$package_name"
receipt="$destination.build-receipt.json"
[ ! -e "$destination" ] && [ ! -e "$receipt" ] \
  || { echo "output package or receipt already exists" >&2; exit 73; }
install -m0644 "$package" "$destination"
package_digest="$(sha256sum "$destination" | cut -d' ' -f1)"
printf '{"schema":"dory.linux-guest-tools-native-build@1","sourceCommit":"%s","guestArchitecture":"%s","format":"%s","packageFile":"%s","packageSHA256":"%s"}\n' \
  "$source_commit" "$guest_architecture" "$package_format" "$package_name" \
  "$package_digest" > "$receipt"
printf 'wrote %s and %s\n' "$destination" "$receipt"
