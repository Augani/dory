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
    [ -x "$DORY_SPARKLE_SIGN_UPDATE" ] \
      || fail "DORY_SPARKLE_SIGN_UPDATE is not executable"
    printf '%s\n' "$DORY_SPARKLE_SIGN_UPDATE"
    return 0
  fi
  for candidate in \
    .build/artifacts/sparkle/Sparkle/bin/sign_update \
    SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update; do
    if [ -x "$candidate" ]; then
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

[ -d "$APP" ] || fail "candidate app is missing: $APP"
[ -s "$UPDATE_ZIP" ] || fail "update ZIP is missing or empty: $UPDATE_ZIP"
[ -s "$APPCAST" ] || fail "appcast is missing or empty: $APPCAST"

SIGNATURE="$(python3 - "$APPCAST" "$(basename "$UPDATE_ZIP")" <<'PY'
import os
import sys
import urllib.parse
import xml.etree.ElementTree as ET

path, expected_name = sys.argv[1:3]
sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
item = ET.parse(path).getroot().find("./channel/item")
if item is None:
    raise SystemExit("appcast has no current item")
enclosure = item.find("enclosure")
if enclosure is None:
    raise SystemExit("current appcast item has no enclosure")
name = os.path.basename(urllib.parse.urlparse(enclosure.attrib.get("url", "")).path)
if name != expected_name:
    raise SystemExit(f"appcast encloses {name!r}, expected {expected_name!r}")
signature = enclosure.attrib.get(f"{{{sparkle}}}edSignature", "")
if not signature:
    raise SystemExit("current appcast enclosure has no EdDSA signature")
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
