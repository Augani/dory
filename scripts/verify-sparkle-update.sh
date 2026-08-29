#!/bin/bash
# Prove that the final Sparkle ZIP is signed by the private key corresponding to the public key
# embedded in the exact candidate app. This closes the gap between "64 bytes of base64" and an
# update that Sparkle will actually accept.
set -euo pipefail

APP="${1:?usage: verify-sparkle-update.sh <Dory.app> <update.zip> <appcast.xml>}"
UPDATE_ZIP="${2:?usage: verify-sparkle-update.sh <Dory.app> <update.zip> <appcast.xml>}"
APPCAST="${3:?usage: verify-sparkle-update.sh <Dory.app> <update.zip> <appcast.xml>}"

fail() {
  echo "Sparkle verification error: $*" >&2
  exit 1
}

find_sign_update() {
  local candidate found=""
  if [ -n "${DORY_SPARKLE_SIGN_UPDATE:-}" ]; then
    [ -f "$DORY_SPARKLE_SIGN_UPDATE" ] && [ ! -L "$DORY_SPARKLE_SIGN_UPDATE" ] \
      && [ -x "$DORY_SPARKLE_SIGN_UPDATE" ] \
      || fail "DORY_SPARKLE_SIGN_UPDATE is unavailable or indirect"
    printf '%s\n' "$DORY_SPARKLE_SIGN_UPDATE"
    return 0
  fi
  for candidate in \
    .build/artifacts/sparkle/Sparkle/bin/sign_update \
    SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update; do
    if [ -f "$candidate" ] && [ ! -L "$candidate" ] && [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  if [ -d "$HOME/Library/Developer/Xcode/DerivedData" ]; then
    found="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
      -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update' \
      -type f -perm -111 2>/dev/null | sort | tail -n 1 || true)"
  fi
  [ -n "$found" ] || fail "Sparkle sign_update was not resolved by the release build"
  printf '%s\n' "$found"
}

[ -d "$APP" ] && [ ! -L "$APP" ] || fail "candidate app is missing or indirect: $APP"
[ -f "$APP/Contents/Info.plist" ] && [ ! -L "$APP/Contents/Info.plist" ] \
  || fail "candidate Info.plist is missing or indirect"
[ -f "$UPDATE_ZIP" ] && [ ! -L "$UPDATE_ZIP" ] && [ -s "$UPDATE_ZIP" ] \
  || fail "update ZIP is missing, indirect, or empty: $UPDATE_ZIP"
[ -f "$APPCAST" ] && [ ! -L "$APPCAST" ] && [ -s "$APPCAST" ] \
  || fail "appcast is missing, indirect, or empty: $APPCAST"

SIGNATURE="$(python3 - "$APPCAST" "$(basename "$UPDATE_ZIP")" \
  "$(stat -f %z "$UPDATE_ZIP")" <<'PY'
import base64
import os
import re
import sys
import urllib.parse
import xml.etree.ElementTree as ET

path, expected_name, expected_length = sys.argv[1:4]
sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
items = ET.parse(path).getroot().findall("./channel/item")
if len(items) != 1:
    raise SystemExit("appcast must contain exactly one current item")
item = items[0]
enclosure = item.find("enclosure")
if enclosure is None:
    raise SystemExit("current appcast item has no enclosure")
parsed = urllib.parse.urlparse(enclosure.attrib.get("url", ""))
name = os.path.basename(parsed.path)
if name != expected_name:
    raise SystemExit(f"appcast encloses {name!r}, expected {expected_name!r}")
match = re.fullmatch(r"Dory-(.+)-app-update\.zip", expected_name)
if match is None:
    raise SystemExit("update ZIP name does not identify a Dory release")
expected_path = f"/Augani/dory/releases/download/v{match.group(1)}/{expected_name}"
if (
    parsed.scheme != "https"
    or parsed.netloc != "github.com"
    or parsed.path != expected_path
    or parsed.params
    or parsed.query
    or parsed.fragment
    or parsed.username is not None
    or parsed.password is not None
):
    raise SystemExit("appcast enclosure URL is not the canonical Dory release asset")
if enclosure.attrib.get("length") != expected_length:
    raise SystemExit("appcast enclosure length does not match the exact update ZIP")
signature = enclosure.attrib.get(f"{{{sparkle}}}edSignature", "")
if not signature:
    raise SystemExit("current appcast enclosure has no EdDSA signature")
try:
    decoded = base64.b64decode(signature, validate=True)
except ValueError as error:
    raise SystemExit(f"appcast EdDSA signature is not valid base64: {error}")
if len(decoded) != 64:
    raise SystemExit("appcast EdDSA signature must decode to 64 bytes")
print(signature)
PY
)"

EMBEDDED_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[ -n "$EMBEDDED_PUBLIC_KEY" ] || fail "candidate app has no SUPublicEDKey"

# The embedded public key is the runtime trust anchor. Verify the exact final ZIP directly so local
# keychain-backed releases do not have to export their private key merely to prove the appcast.
if ! xcrun swift - "$UPDATE_ZIP" "$SIGNATURE" "$EMBEDDED_PUBLIC_KEY" <<'SWIFT'
import CryptoKit
import Foundation

guard CommandLine.arguments.count == 4,
      let signature = Data(base64Encoded: CommandLine.arguments[2]),
      let publicKeyData = Data(base64Encoded: CommandLine.arguments[3]) else {
    fatalError("Sparkle signature or public key is not valid base64")
}
let payload = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
guard publicKey.isValidSignature(signature, for: payload) else {
    fatalError("Sparkle signature does not match the exact update ZIP and embedded public key")
}
SWIFT
then
  fail "embedded Sparkle public key rejected the final update ZIP signature"
fi

if [ -z "${DORY_SPARKLE_PRIVATE_KEY:-}" ]; then
  echo "Sparkle update verification: PASS (signature valid against embedded public key)"
  exit 0
fi

SIGN_UPDATE="$(find_sign_update)"
printf '%s' "$DORY_SPARKLE_PRIVATE_KEY" \
  | "$SIGN_UPDATE" --verify --ed-key-file - "$UPDATE_ZIP" "$SIGNATURE" >/dev/null \
  || fail "Sparkle private key rejected the final update ZIP signature"

DERIVED_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/dory-sparkle-public.XXXXXX")"
trap 'rm -f "$DERIVED_OUTPUT"' EXIT
if ! xcrun swift - > "$DERIVED_OUTPUT" <<'SWIFT'
import CryptoKit
import Foundation

guard let encoded = ProcessInfo.processInfo.environment["DORY_SPARKLE_PRIVATE_KEY"]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      let secret = Data(base64Encoded: encoded) else {
    fatalError("Sparkle private key is not valid base64")
}

let publicKey: Data
if secret.count == 32 {
    do {
        publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
            .publicKey.rawRepresentation
    } catch {
        fatalError("Sparkle private seed could not derive an Ed25519 public key")
    }
} else if secret.count == 96 {
    // Sparkle's legacy exported format is a 64-byte private key followed by its 32-byte public key.
    publicKey = secret.suffix(32)
} else {
    fatalError("Sparkle private key must decode to 32 or 96 bytes")
}
print(publicKey.base64EncodedString())
SWIFT
then
  fail "could not derive the Sparkle public key"
fi
DERIVED_PUBLIC_KEY="$(cat "$DERIVED_OUTPUT")"
rm -f "$DERIVED_OUTPUT"
trap - EXIT

[ "$DERIVED_PUBLIC_KEY" = "$EMBEDDED_PUBLIC_KEY" ] \
  || fail "configured Sparkle private key does not match the candidate app's SUPublicEDKey"

echo "Sparkle update verification: PASS (signature valid; embedded public key matches)"
