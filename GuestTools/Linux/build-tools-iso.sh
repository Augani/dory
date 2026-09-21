#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT=""
GPG_KEY=""
declare -a DEBS=()
declare -a RPMS=()

usage() {
  cat >&2 <<'EOF'
usage: build-dory-guest-tools-iso.sh --deb PACKAGE.deb [--deb ...] \
  --rpm PACKAGE.rpm [--rpm ...] --gpg-key FINGERPRINT --output PATH.iso

Builds one signed, offline apt + dnf repository image. Packages must have been built natively
inside their target Dory Ubuntu/Fedora VM; this assembler never invokes Docker or QEMU.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --deb) [ "$#" -ge 2 ] || { usage; exit 64; }; DEBS+=("$2"); shift 2 ;;
    --rpm) [ "$#" -ge 2 ] || { usage; exit 64; }; RPMS+=("$2"); shift 2 ;;
    --gpg-key) [ "$#" -ge 2 ] || { usage; exit 64; }; GPG_KEY="$2"; shift 2 ;;
    --output) [ "$#" -ge 2 ] || { usage; exit 64; }; OUTPUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 64 ;;
  esac
done

[ "${#DEBS[@]}" -gt 0 ] && [ "${#RPMS[@]}" -gt 0 ] \
  || { echo "at least one .deb and one .rpm are required" >&2; exit 64; }
[ -n "$GPG_KEY" ] && [ -n "$OUTPUT" ] || { usage; exit 64; }
case "$OUTPUT" in /*.iso) ;; *) echo "--output must be an absolute .iso path" >&2; exit 64 ;; esac

for command in gpg dpkg-scanpackages apt-ftparchive gzip createrepo_c rpm rpmsign; do
  command -v "$command" >/dev/null 2>&1 \
    || { echo "required command is unavailable: $command" >&2; exit 69; }
done
if ! command -v xorriso >/dev/null 2>&1 && ! command -v hdiutil >/dev/null 2>&1; then
  echo "xorriso or hdiutil is required" >&2
  exit 69
fi

fingerprint="$(gpg --batch --with-colons --list-secret-keys "$GPG_KEY" 2>/dev/null \
  | awk -F: '$1 == "fpr" { print $10; exit }')"
[ -n "$fingerprint" ] || { echo "the requested GPG secret key is unavailable" >&2; exit 66; }

work="$(mktemp -d "${TMPDIR:-/tmp}/dory-tools-iso.XXXXXX")"
temporary="${OUTPUT%.iso}.partial.$$.iso"
cleanup() { rm -rf "$work"; rm -f "$temporary"; }
trap cleanup EXIT HUP INT TERM
image="$work/image"
mkdir -p "$image/apt/pool" "$image/rpm"

copy_packages() {
  local destination="$1"
  shift
  local source resolved name
  for source in "$@"; do
    [ -f "$source" ] && [ ! -L "$source" ] \
      || { echo "package must be a regular non-symlink: $source" >&2; exit 66; }
    resolved="$(cd "$(dirname "$source")" && pwd -P)/$(basename "$source")"
    name="$(basename "$resolved")"
    case "$name" in *[!A-Za-z0-9._+~-]*) echo "unsafe package name: $name" >&2; exit 64 ;; esac
    install -m0644 "$resolved" "$destination/$name"
  done
}
copy_packages "$image/apt/pool" "${DEBS[@]}"
copy_packages "$image/rpm" "${RPMS[@]}"

for package in "$image"/rpm/*.rpm; do
  rpmsign --addsign --define "_gpg_name $fingerprint" "$package"
  rpm --checksig "$package" | grep -Eq 'digests signatures OK|pgp.*OK' \
    || { echo "RPM signature verification failed: $package" >&2; exit 65; }
done

(
  cd "$image/apt"
  dpkg-scanpackages --multiversion pool /dev/null > Packages
  gzip -n -9 -c Packages > Packages.gz
  apt-ftparchive release . > Release
  gpg --batch --yes --armor --local-user "$fingerprint" --detach-sign \
    --output Release.gpg Release
  gpg --batch --yes --armor --local-user "$fingerprint" --clearsign \
    --output InRelease Release
)
createrepo_c --quiet "$image/rpm"
gpg --batch --yes --armor --local-user "$fingerprint" --detach-sign \
  --output "$image/rpm/repodata/repomd.xml.asc" "$image/rpm/repodata/repomd.xml"
gpg --batch --yes --armor --export "$fingerprint" > "$image/dory-repository-key.asc"

install -m0755 "$ROOT/GuestTools/Linux/iso/install.sh" "$image/install.sh"
install -m0644 "$ROOT/GuestTools/Linux/iso/README.txt" "$image/README.txt"
(
  cd "$image"
  find . -type f -print | LC_ALL=C sort | while IFS= read -r path; do
    shasum -a 256 "$path"
  done > SHA256SUMS
)
gpg --batch --yes --armor --local-user "$fingerprint" --detach-sign \
  --output "$image/SHA256SUMS.asc" "$image/SHA256SUMS"

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$temporary"
if command -v xorriso >/dev/null 2>&1; then
  xorriso -as mkisofs -quiet -iso-level 3 -J -R -V DORY_TOOLS -o "$temporary" "$image"
else
  hdiutil makehybrid -quiet -iso -joliet -default-volume-name DORY_TOOLS \
    -o "$temporary" "$image"
fi
[ -s "$temporary" ] || { echo "ISO assembler produced no output" >&2; exit 65; }
mv -f "$temporary" "$OUTPUT"
trap - EXIT HUP INT TERM
rm -rf "$work"
printf 'wrote %s\n' "$OUTPUT"
