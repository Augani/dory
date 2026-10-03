#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT=""
GPG_KEY=""
EXPECTED_COMMIT=""
EXPECTED_ARCHITECTURE=""
declare -a DEBS=()
declare -a RPMS=()

usage() {
  cat >&2 <<'EOF'
usage: build-tools-iso.sh --deb PACKAGE.deb --rpm PACKAGE.rpm --gpg-key FINGERPRINT \
  --expected-source-commit SHA40 --expected-architecture arm64|x86_64 --output PATH.iso

Builds one signed, offline apt + dnf repository image for one guest architecture. Each package
must have a .build-receipt.json sidecar from build-native-package.sh. This assembler never
invokes Docker or QEMU.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --deb) [ "$#" -ge 2 ] || { usage; exit 64; }; DEBS+=("$2"); shift 2 ;;
    --rpm) [ "$#" -ge 2 ] || { usage; exit 64; }; RPMS+=("$2"); shift 2 ;;
    --gpg-key) [ "$#" -ge 2 ] || { usage; exit 64; }; GPG_KEY="$2"; shift 2 ;;
    --expected-source-commit) [ "$#" -ge 2 ] || { usage; exit 64; }; EXPECTED_COMMIT="$2"; shift 2 ;;
    --expected-architecture) [ "$#" -ge 2 ] || { usage; exit 64; }; EXPECTED_ARCHITECTURE="$2"; shift 2 ;;
    --output) [ "$#" -ge 2 ] || { usage; exit 64; }; OUTPUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 64 ;;
  esac
done

[ "${#DEBS[@]}" -eq 1 ] && [ "${#RPMS[@]}" -eq 1 ] \
  || { echo "exactly one native .deb and one native .rpm are required" >&2; exit 64; }
[ -n "$GPG_KEY" ] && [ -n "$OUTPUT" ] || { usage; exit 64; }
case "$EXPECTED_COMMIT" in *[!0-9a-f]*|'') usage; exit 64 ;; esac
[ "${#EXPECTED_COMMIT}" -eq 40 ] || { usage; exit 64; }
case "$EXPECTED_ARCHITECTURE" in arm64|x86_64) ;; *) usage; exit 64 ;; esac
case "$OUTPUT" in /*.iso) ;; *) echo "--output must be an absolute .iso path" >&2; exit 64 ;; esac

for command in gpg dpkg-deb dpkg-scanpackages apt-ftparchive gzip createrepo_c rpm rpmsign rpm2cpio python3; do
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
native_manifest="$(python3 -B "$ROOT/GuestTools/Linux/verify-native-package-set.py" \
  --deb "${DEBS[0]}" --rpm "${RPMS[0]}" \
  --expected-source-commit "$EXPECTED_COMMIT" \
  --expected-architecture "$EXPECTED_ARCHITECTURE")"

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
    install -m0644 "$resolved.build-receipt.json" \
      "$destination/$name.build-receipt.json"
  done
}
copy_packages "$image/apt/pool" "${DEBS[@]}"
copy_packages "$image/rpm" "${RPMS[@]}"
copied_manifest="$(python3 -B "$ROOT/GuestTools/Linux/verify-native-package-set.py" \
  --deb "$image/apt/pool/$(basename "${DEBS[0]}")" \
  --rpm "$image/rpm/$(basename "${RPMS[0]}")" \
  --expected-source-commit "$EXPECTED_COMMIT" \
  --expected-architecture "$EXPECTED_ARCHITECTURE")"
[ "$native_manifest" = "$copied_manifest" ] \
  || { echo "copied native packages changed before signing" >&2; exit 65; }
printf '%s\n' "$native_manifest" > "$image/native-build-manifest.json"
mkdir -p "$image/native-inputs"
install -m0644 "$image/rpm/$(basename "${RPMS[0]}")" \
  "$image/native-inputs/$(basename "${RPMS[0]}")"
install -m0644 "$image/rpm/$(basename "${RPMS[0]}").build-receipt.json" \
  "$image/native-inputs/$(basename "${RPMS[0]}").build-receipt.json"
rm -f "$image/rpm/$(basename "${RPMS[0]}").build-receipt.json"
gpg --batch --yes --armor --export "$fingerprint" > "$image/dory-repository-key.asc"
mkdir -p "$work/rpmdb"
rpm --dbpath "$work/rpmdb" --initdb >/dev/null
rpm --dbpath "$work/rpmdb" --import "$image/dory-repository-key.asc" >/dev/null

for package in "$image"/apt/pool/*.deb; do
  gpg --batch --yes --armor --local-user "$fingerprint" --detach-sign \
    --output "$package.asc" "$package"
  gpg --batch --verify "$package.asc" "$package" >/dev/null 2>&1 \
    || { echo "Debian package signature verification failed: $package" >&2; exit 65; }
done

for package in "$image"/rpm/*.rpm; do
  rpmsign --addsign --define "_gpg_name $fingerprint" "$package"
  rpm --dbpath "$work/rpmdb" --checksig "$package" \
    | grep -Eq 'digests signatures OK|pgp.*OK' \
    || { echo "RPM signature verification failed: $package" >&2; exit 65; }
  native_payload="$(rpm2cpio "$image/native-inputs/$(basename "$package")" | shasum -a 256 | cut -d' ' -f1)"
  signed_payload="$(rpm2cpio "$package" | shasum -a 256 | cut -d' ' -f1)"
  [ "$native_payload" = "$signed_payload" ] \
    || { echo "RPM signing changed the native package payload" >&2; exit 65; }
done

(
  cd "$image/apt"
  dpkg-scanpackages --multiversion pool /dev/null > Packages
  gzip -n -9 -c Packages > Packages.gz
  apt-ftparchive -o APT::FTPArchive::Release::Origin=Dory release . > Release
  gpg --batch --yes --armor --local-user "$fingerprint" --detach-sign \
    --output Release.gpg Release
  gpg --batch --yes --armor --local-user "$fingerprint" --clearsign \
    --output InRelease Release
)
createrepo_c --quiet "$image/rpm"
gpg --batch --yes --armor --local-user "$fingerprint" --detach-sign \
  --output "$image/rpm/repodata/repomd.xml.asc" "$image/rpm/repodata/repomd.xml"
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
"$ROOT/GuestTools/Linux/verify-tools-iso.sh" \
  --iso "$temporary" \
  --expected-gpg-key "$fingerprint" \
  --expected-source-commit "$EXPECTED_COMMIT" \
  --expected-architecture "$EXPECTED_ARCHITECTURE"
mv -f "$temporary" "$OUTPUT"
trap - EXIT HUP INT TERM
rm -rf "$work"
printf 'wrote %s\n' "$OUTPUT"
