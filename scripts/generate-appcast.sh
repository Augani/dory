#!/bin/bash
# Generate a Sparkle appcast item for a signed Dory release artifact.
set -euo pipefail

usage() {
  echo "usage: scripts/generate-appcast.sh <version> <build> <artifact.zip> <output.xml> [previous-appcast.xml]" >&2
  exit 64
}

[ "$#" -ge 4 ] || usage

VERSION="$1"
BUILD="$2"
ARTIFACT="$3"
OUTPUT="$4"
PREVIOUS="${5:-$OUTPUT}"

[ -f "$ARTIFACT" ] || { echo "appcast error: artifact not found: $ARTIFACT" >&2; exit 1; }

APPCAST_TITLE="${DORY_APPCAST_TITLE:-Dory}"
APPCAST_LINK="${DORY_APPCAST_LINK:-https://augani.github.io/dory/appcast.xml}"
APPCAST_DESCRIPTION="${DORY_APPCAST_DESCRIPTION:-Updates for Dory - native Docker and Linux containers for macOS.}"
MINIMUM_SYSTEM_VERSION="${DORY_APPCAST_MINIMUM_SYSTEM_VERSION:-14.0}"
ASSET_BASE_URL="${DORY_RELEASE_ASSET_BASE_URL:-https://github.com/Augani/dory/releases/download/v$VERSION}"
ARTIFACT_URL="${DORY_APPCAST_ARTIFACT_URL:-${ASSET_BASE_URL%/}/$(basename "$ARTIFACT")}"
PUBDATE="${DORY_APPCAST_PUBDATE:-$(LC_ALL=C TZ=UTC date -u '+%a, %d %b %Y %H:%M:%S +0000')}"

xml_escape() {
  printf '%s' "$1" | sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g'
}

file_size_bytes() {
  wc -c < "$1" | tr -d '[:space:]'
}

find_sign_update() {
  local found=""
  if [ -n "${DORY_SPARKLE_SIGN_UPDATE:-}" ]; then
    [ -x "$DORY_SPARKLE_SIGN_UPDATE" ] || {
      echo "appcast error: DORY_SPARKLE_SIGN_UPDATE is not executable: $DORY_SPARKLE_SIGN_UPDATE" >&2
      exit 1
    }
    printf '%s' "$DORY_SPARKLE_SIGN_UPDATE"
    return 0
  fi

  for candidate in \
    ".build/artifacts/sparkle/Sparkle/bin/sign_update" \
    "SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"; do
    if [ -x "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  if [ -d "$HOME/Library/Developer/Xcode/DerivedData" ]; then
    found="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update' -type f -perm -111 2>/dev/null | sort | tail -n 1 || true)"
  fi
  if [ -n "$found" ]; then
    printf '%s' "$found"
    return 0
  fi

  echo "appcast error: Sparkle sign_update not found; set DORY_SPARKLE_SIGN_UPDATE or build once so SwiftPM resolves Sparkle" >&2
  exit 1
}

sparkle_signature() {
  local tool signature
  if [ -n "${DORY_SPARKLE_ED_SIGNATURE:-}" ]; then
    printf '%s' "$DORY_SPARKLE_ED_SIGNATURE"
    return 0
  fi

  if [ "${CI:-}" = "true" ] && [ -z "${DORY_SPARKLE_PRIVATE_KEY:-}" ] && [ -z "${DORY_SPARKLE_ACCOUNT:-}" ]; then
    echo "appcast error: CI appcast signing requires DORY_SPARKLE_PRIVATE_KEY or DORY_SPARKLE_ACCOUNT" >&2
    exit 1
  fi

  tool="$(find_sign_update)"
  if [ -n "${DORY_SPARKLE_PRIVATE_KEY:-}" ]; then
    if [ -n "${DORY_SPARKLE_ACCOUNT:-}" ]; then
      signature="$(printf '%s' "$DORY_SPARKLE_PRIVATE_KEY" | "$tool" --account "$DORY_SPARKLE_ACCOUNT" --ed-key-file - -p "$ARTIFACT")"
    else
      signature="$(printf '%s' "$DORY_SPARKLE_PRIVATE_KEY" | "$tool" --ed-key-file - -p "$ARTIFACT")"
    fi
  else
    if [ -n "${DORY_SPARKLE_ACCOUNT:-}" ]; then
      signature="$("$tool" --account "$DORY_SPARKLE_ACCOUNT" -p "$ARTIFACT")"
    else
      signature="$("$tool" -p "$ARTIFACT")"
    fi
  fi

  signature="$(printf '%s' "$signature" | tail -n 1 | tr -d '\r\n')"
  [ -n "$signature" ] || { echo "appcast error: Sparkle signature was empty" >&2; exit 1; }
  printf '%s' "$signature"
}

append_previous_items() {
  [ -f "$PREVIOUS" ] || return 0
  awk -v build="$BUILD" -v version="$VERSION" '
    /<item>/ {
      in_item = 1
      item = $0 ORS
      next
    }
    in_item {
      item = item $0 ORS
      if ($0 ~ /<\/item>/) {
        if (index(item, "<sparkle:version>" build "</sparkle:version>") == 0 &&
            index(item, "<sparkle:shortVersionString>" version "</sparkle:shortVersionString>") == 0) {
          printf "%s", item
        }
        in_item = 0
        item = ""
      }
    }
  ' "$PREVIOUS"
}

SIGNATURE="$(sparkle_signature)"
LENGTH="$(file_size_bytes "$ARTIFACT")"
mkdir -p "$(dirname "$OUTPUT")"
TMP_OUTPUT="$(mktemp "${OUTPUT}.XXXXXX")"
trap 'rm -f "$TMP_OUTPUT"' EXIT

{
  cat <<EOF
<?xml version="1.0" standalone="yes"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>$(xml_escape "$APPCAST_TITLE")</title>
    <link>$(xml_escape "$APPCAST_LINK")</link>
    <description>$(xml_escape "$APPCAST_DESCRIPTION")</description>
    <language>en</language>
    <item>
      <title>$(xml_escape "$VERSION")</title>
      <pubDate>$(xml_escape "$PUBDATE")</pubDate>
      <sparkle:version>$(xml_escape "$BUILD")</sparkle:version>
      <sparkle:shortVersionString>$(xml_escape "$VERSION")</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$(xml_escape "$MINIMUM_SYSTEM_VERSION")</sparkle:minimumSystemVersion>
      <enclosure url="$(xml_escape "$ARTIFACT_URL")" sparkle:edSignature="$(xml_escape "$SIGNATURE")" length="$(xml_escape "$LENGTH")" type="application/octet-stream" />
    </item>
EOF
  append_previous_items
  cat <<EOF
  </channel>
</rss>
EOF
} > "$TMP_OUTPUT"

mv "$TMP_OUTPUT" "$OUTPUT"
trap - EXIT
printf '%s\n' "$OUTPUT"
