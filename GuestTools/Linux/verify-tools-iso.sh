#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: verify-tools-iso.sh --iso ABSOLUTE.iso --expected-gpg-key FINGERPRINT \
  --expected-source-commit SHA40 --expected-architecture arm64|x86_64 [--portable]

Checks the assembled ISO bytes, the complete signed inventory, native build receipts, apt/dnf
metadata, individual package signatures, and the signed RPM's unchanged native payload.
--portable performs the source/key/architecture and signed-byte checks on macOS without dpkg/rpm;
full package-metadata and RPM-payload validation remains required at ISO assembly.
EOF
}

iso=""
expected_key=""
expected_commit=""
expected_architecture=""
portable=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --iso) [ "$#" -ge 2 ] || { usage; exit 64; }; iso="$2"; shift 2 ;;
    --expected-gpg-key) [ "$#" -ge 2 ] || { usage; exit 64; }; expected_key="$2"; shift 2 ;;
    --expected-source-commit) [ "$#" -ge 2 ] || { usage; exit 64; }; expected_commit="$2"; shift 2 ;;
    --expected-architecture) [ "$#" -ge 2 ] || { usage; exit 64; }; expected_architecture="$2"; shift 2 ;;
    --portable) portable=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 64 ;;
  esac
done

case "$iso" in /*.iso) ;; *) usage; exit 64 ;; esac
case "$expected_commit" in *[!0-9a-f]*|'') usage; exit 64 ;; esac
[ "${#expected_commit}" -eq 40 ] || { usage; exit 64; }
case "$expected_architecture" in arm64|x86_64) ;; *) usage; exit 64 ;; esac
case "$expected_key" in *[!A-Fa-f0-9]*|'') usage; exit 64 ;; esac
case "${#expected_key}" in 40|64) ;; *) usage; exit 64 ;; esac
[ -f "$iso" ] && [ ! -L "$iso" ] && [ -s "$iso" ] \
  || { echo "ISO must be a nonempty direct regular file" >&2; exit 66; }

for required in gpg shasum python3 cmp find sort; do
  command -v "$required" >/dev/null 2>&1 \
    || { echo "required verification command is unavailable: $required" >&2; exit 69; }
done
if [ "$portable" -eq 0 ]; then
  for required in dpkg-deb rpm rpm2cpio; do
    command -v "$required" >/dev/null 2>&1 \
      || { echo "required full-verification command is unavailable: $required" >&2; exit 69; }
  done
fi
if ! command -v xorriso >/dev/null 2>&1 && ! command -v hdiutil >/dev/null 2>&1; then
  echo "xorriso or hdiutil is required to inspect the ISO" >&2
  exit 69
fi

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
verify_work="$(mktemp -d "${TMPDIR:-/tmp}/dory-tools-verify.XXXXXX")"
mounted=0
mount_point="$verify_work/mount"
cleanup() {
  if [ "$mounted" -eq 1 ]; then hdiutil detach -quiet "$mount_point" || :; fi
  rm -rf "$verify_work"
}
trap cleanup EXIT HUP INT TERM

if command -v xorriso >/dev/null 2>&1; then
  image="$verify_work/image"
  mkdir -p "$image"
  xorriso -osirrox on -indev "$iso" -extract / "$image" >/dev/null 2>&1
else
  mkdir -p "$mount_point"
  hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount_point" "$iso"
  mounted=1
  image="$mount_point"
fi

key="$image/dory-repository-key.asc"
[ -f "$key" ] && [ ! -L "$key" ] \
  || { echo "ISO repository key is missing or indirect" >&2; exit 65; }
key_details="$(gpg --batch --show-keys --with-colons "$key" 2>/dev/null)"
[ "$(printf '%s\n' "$key_details" | awk -F: '$1 == "pub" { count++ } END { print count+0 }')" -eq 1 ] \
  || { echo "ISO repository key must contain exactly one primary key" >&2; exit 65; }
actual_key="$(printf '%s\n' "$key_details" | awk -F: '$1 == "fpr" { print $10; exit }')"
[ "$(printf '%s' "$actual_key" | tr '[:lower:]' '[:upper:]')" \
  = "$(printf '%s' "$expected_key" | tr '[:lower:]' '[:upper:]')" ] \
  || { echo "ISO repository key is not the selected release key" >&2; exit 65; }
gpg_home="$verify_work/gnupg"
mkdir -m0700 "$gpg_home"
gpg --homedir "$gpg_home" --batch --import "$key" >/dev/null 2>&1

gpg --homedir "$gpg_home" --batch --verify \
  "$image/SHA256SUMS.asc" "$image/SHA256SUMS" >/dev/null 2>&1 \
  || { echo "ISO inventory signature is invalid" >&2; exit 65; }
(
  cd "$image"
  [ -z "$(find . -type l -print -quit)" ]
  shasum -a 256 -c SHA256SUMS >/dev/null
  find . -type f ! -name SHA256SUMS ! -name SHA256SUMS.asc -print \
    | LC_ALL=C sort > "$verify_work/actual-files"
  cut -c 67- SHA256SUMS | LC_ALL=C sort > "$verify_work/listed-files"
  cmp -s "$verify_work/actual-files" "$verify_work/listed-files"
) || { echo "ISO inventory is incomplete or has mismatched bytes" >&2; exit 65; }

gpg --homedir "$gpg_home" --batch --verify \
  "$image/apt/Release.gpg" "$image/apt/Release" >/dev/null 2>&1 \
  || { echo "apt Release signature is invalid" >&2; exit 65; }
grep -Fxq 'Origin: Dory' "$image/apt/Release" \
  || { echo "apt Release is missing the Dory package origin" >&2; exit 65; }
gpg --homedir "$gpg_home" --batch --decrypt "$image/apt/InRelease" \
  > "$verify_work/clear-release" 2>/dev/null
cmp -s "$verify_work/clear-release" "$image/apt/Release" \
  || { echo "apt InRelease differs from Release" >&2; exit 65; }
gpg --homedir "$gpg_home" --batch --verify \
  "$image/rpm/repodata/repomd.xml.asc" "$image/rpm/repodata/repomd.xml" \
  >/dev/null 2>&1 \
  || { echo "dnf repository metadata signature is invalid" >&2; exit 65; }

shopt -s nullglob
deb_packages=("$image"/apt/pool/*.deb)
signed_rpms=("$image"/rpm/*.rpm)
native_rpms=("$image"/native-inputs/*.rpm)
[ "${#deb_packages[@]}" -eq 1 ] && [ "${#signed_rpms[@]}" -eq 1 ] \
  && [ "${#native_rpms[@]}" -eq 1 ] \
  || { echo "ISO package count is invalid" >&2; exit 65; }
[ "$(basename "${signed_rpms[0]}")" = "$(basename "${native_rpms[0]}")" ] \
  || { echo "signed RPM is not the retained native RPM" >&2; exit 65; }
gpg --homedir "$gpg_home" --batch --verify \
  "${deb_packages[0]}.asc" "${deb_packages[0]}" >/dev/null 2>&1 \
  || { echo "Debian package signature is invalid" >&2; exit 65; }

native_verify_args=(
  --deb "${deb_packages[0]}" --rpm "${native_rpms[0]}"
  --expected-source-commit "$expected_commit"
  --expected-architecture "$expected_architecture"
)
[ "$portable" -eq 0 ] \
  || native_verify_args+=(--portable-manifest "$image/native-build-manifest.json")
python3 -B "$root/GuestTools/Linux/verify-native-package-set.py" \
  "${native_verify_args[@]}" > "$verify_work/recomputed-native-manifest"
cmp -s "$verify_work/recomputed-native-manifest" "$image/native-build-manifest.json" \
  || { echo "ISO native-build manifest disagrees with package receipts" >&2; exit 65; }

if [ "$portable" -eq 0 ]; then
  mkdir -p "$verify_work/rpmdb"
  rpm --dbpath "$verify_work/rpmdb" --initdb >/dev/null
  rpm --dbpath "$verify_work/rpmdb" --import "$key" >/dev/null
  rpm --dbpath "$verify_work/rpmdb" --checksig "${signed_rpms[0]}" \
    | grep -Eq 'digests signatures OK|pgp.*OK' \
    || { echo "signed RPM verification failed" >&2; exit 65; }
  native_metadata="$(rpm -qp --queryformat '%{NAME} %{VERSION} %{RELEASE} %{ARCH}' "${native_rpms[0]}")"
  signed_metadata="$(rpm -qp --queryformat '%{NAME} %{VERSION} %{RELEASE} %{ARCH}' "${signed_rpms[0]}")"
  [ "$native_metadata" = "$signed_metadata" ] \
    || { echo "signed RPM metadata differs from the native build" >&2; exit 65; }
  native_payload="$(rpm2cpio "${native_rpms[0]}" | shasum -a 256 | cut -d' ' -f1)"
  signed_payload="$(rpm2cpio "${signed_rpms[0]}" | shasum -a 256 | cut -d' ' -f1)"
  [ "$native_payload" = "$signed_payload" ] \
    || { echo "signed RPM payload differs from the native build" >&2; exit 65; }
fi

printf 'verified %s for %s at %s\n' "$iso" "$expected_architecture" "$expected_commit"
