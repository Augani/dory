#!/bin/sh
# Root-only, guest-local lifecycle entry point installed by the signed tools package.
# The package and manifest are supplied by Dory's read-only distribution share.
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 077

PACKAGE_ID=com.pythonxi.Dory.GuestTools.pkg
APP=/Applications/DoryGuestTools.app
AGENT=/Library/LaunchAgents/com.pythonxi.Dory.GuestTools.agent.plist
HELPER='/Library/Application Support/Dory/GuestTools/dory-guest-tools-maintenance'
TEAM=864H636QW4
AGENT_SHA256=a0949886443846f2c9416ddcec1f06c7dd4a273d6c5ca3cc0fccbe71e09e5375

fail() { printf 'Dory Guest Tools: %s\n' "$*" >&2; exit 1; }
regular() { [ -f "$1" ] && [ ! -L "$1" ] || fail "$1 must be a direct regular file"; }
field() { /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null || fail "invalid package manifest field: $2"; }
sha256() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
bundle_label() {
  [ -n "$1" ] && [ "${#1}" -le 64 ] || fail 'bundle version/build is empty or unbounded'
  case "$1" in *[!A-Za-z0-9._:-]*) fail 'bundle version/build is not a portable label' ;; esac
}

# Signature/team checks remain in verify_installed. This separate exact tuple check is also
# used for the retained rollback package: equal public versions do not imply equal builds.
verify_installed_bundle_identity() {
  identity_app=$1
  identity_manifest=$2
  regular "$identity_app/Contents/Info.plist"
  expected_version=$(field "$identity_manifest" bundleManifest.bundle.version)
  expected_build=$(field "$identity_manifest" bundleManifest.bundle.build)
  bundle_label "$expected_version"
  bundle_label "$expected_build"
  installed_version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$identity_app/Contents/Info.plist") || fail 'installed app version is unavailable'
  installed_build=$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$identity_app/Contents/Info.plist") || fail 'installed app build is unavailable'
  [ "$installed_version" = "$expected_version" ] || fail 'installed app version differs from package manifest'
  [ "$installed_build" = "$expected_build" ] || fail 'installed app build differs from package manifest'
}

verify_package() {
  package=$1
  manifest=$2
  regular "$package"
  regular "$manifest"
  [ "$(field "$manifest" schema)" = 'dory.macos-guest-tools-package@3' ] || fail 'unsupported package manifest'
  [ "$(field "$manifest" package.filename)" = "${package##*/}" ] || fail 'package filename differs from manifest'
  [ "$(field "$manifest" package.installLocation)" = / ] || fail 'unexpected install location'
  [ "$(field "$manifest" package.installedAppPath)" = "$APP" ] || fail 'unexpected app path'
  [ "$(field "$manifest" package.installerTeamIdentifier)" = "$TEAM" ] || fail 'unexpected installer team'
  [ "$(field "$manifest" bundleManifest.bundle.identifier)" = com.pythonxi.Dory.GuestTools ] || fail 'unexpected manifest app identifier'
  bundle_label "$(field "$manifest" bundleManifest.bundle.version)"
  bundle_label "$(field "$manifest" bundleManifest.bundle.build)"
  [ "$(field "$manifest" loginAgent.path)" = "$AGENT" ] || fail 'unexpected login agent path'
  [ "$(field "$manifest" loginAgent.label)" = com.pythonxi.Dory.GuestTools.agent ] || fail 'unexpected login agent label'
  [ "$(field "$manifest" loginAgent.sha256)" = "$AGENT_SHA256" ] || fail 'unexpected login agent digest'
  [ "$(field "$manifest" notarization.status)" = stapled ] || fail 'package lacks stapled notarization'
  [ "$(field "$manifest" package.byteCount)" = "$(/usr/bin/stat -f %z "$package")" ] || fail 'package length differs from manifest'
  [ "$(field "$manifest" package.sha256)" = "$(sha256 "$package")" ] || fail 'package digest differs from manifest'
  signature=$(/usr/sbin/pkgutil --check-signature "$package" 2>&1) || fail 'invalid installer signature'
  printf '%s\n' "$signature" | /usr/bin/grep -F 'Developer ID Installer:' >/dev/null || fail 'not a Developer ID Installer package'
  printf '%s\n' "$signature" | /usr/bin/grep -F "($TEAM)" >/dev/null || fail 'installer has the wrong signing team'
  /usr/bin/xcrun stapler validate "$package" >/dev/null 2>&1 || fail 'invalid stapled ticket'
  /usr/sbin/spctl --assess --type install "$package" >/dev/null 2>&1 || fail 'Gatekeeper rejected package'
  payload=$(/usr/sbin/pkgutil --payload-files "$package") || fail 'could not inspect package payload'
  payload=$(printf '%s\n' "$payload" | /usr/bin/sed 's#^\./##')
  for required in \
    'Applications/DoryGuestTools.app/Contents/MacOS/DoryGuestTools' \
    'Library/LaunchAgents/com.pythonxi.Dory.GuestTools.agent.plist' \
    'Library/Application Support/Dory/GuestTools/dory-guest-tools-maintenance'; do
    printf '%s\n' "$payload" | /usr/bin/grep -Fx "$required" >/dev/null || fail "package lacks $required"
  done
}

verify_installed() {
  expected_agent_sha=$1
  [ -d "$APP" ] && [ ! -L "$APP" ] || fail 'installed app is missing or indirect'
  regular "$AGENT"
  regular "$HELPER"
  [ "$(sha256 "$AGENT")" = "$expected_agent_sha" ] || fail 'installed login agent was modified'
  /usr/bin/codesign --verify --deep --strict "$APP" >/dev/null 2>&1 || fail 'installed app signature is invalid'
  identity=$(/usr/bin/codesign -dv --verbose=4 "$APP" 2>&1) || fail 'could not read installed app identity'
  printf '%s\n' "$identity" | /usr/bin/grep -Fx 'Identifier=com.pythonxi.Dory.GuestTools' >/dev/null || fail 'installed app identifier differs'
  printf '%s\n' "$identity" | /usr/bin/grep -Fx "TeamIdentifier=$TEAM" >/dev/null || fail 'installed app signing team differs'
  /usr/sbin/pkgutil --pkg-info "$PACKAGE_ID" >/dev/null 2>&1 || fail 'Guest Tools package receipt is missing'
  if [ "$#" -eq 2 ]; then verify_installed_bundle_identity "$APP" "$2"; fi
}

install_package() {
  verify_package "$1" "$2"
  installed_agent_sha=$(field "$2" loginAgent.sha256)
  /usr/sbin/installer -pkg "$1" -target / || fail 'installer failed; inspect the guest install log'
  verify_installed "$installed_agent_sha" "$2"
}

uninstall_package() {
  verify_installed "$AGENT_SHA256"
  extensions=$(/usr/bin/systemextensionsctl list 2>/dev/null) || fail 'could not inspect installed system extensions'
  if printf '%s\n' "$extensions" | /usr/bin/grep -F 'com.pythonxi.Dory.GuestTools.CameraExtension' >/dev/null; then
    fail 'deactivate the Dory camera extension in Guest Tools before uninstalling'
  fi
  if /usr/bin/pgrep -f '^/Applications/DoryGuestTools.app/Contents/MacOS/DoryGuestTools([[:space:]]|$)' >/dev/null; then
    fail 'log out of Guest Tools user sessions before uninstalling'
  else
    process_status=$?
    [ "$process_status" -eq 1 ] || fail 'could not inspect active Guest Tools sessions'
  fi
  /bin/mkdir -p /var/db/DoryGuestTools
  [ -d /var/db/DoryGuestTools ] && [ ! -L /var/db/DoryGuestTools ] || fail 'recovery root is indirect'
  [ "$(/usr/bin/stat -f %u /var/db/DoryGuestTools)" -eq 0 ] || fail 'recovery root is not root-owned'
  /bin/chmod 0700 /var/db/DoryGuestTools
  backup=$(/usr/bin/mktemp -d /var/db/DoryGuestTools/uninstalled.XXXXXXXX) || fail 'could not create recovery directory'
  /bin/mkdir -p "$backup/Applications" "$backup/LaunchAgents" "$backup/GuestTools"
  /bin/mv "$APP" "$backup/Applications/" || fail 'could not move app into recovery directory'
  if ! /bin/mv "$AGENT" "$backup/LaunchAgents/"; then
    /bin/mv "$backup/Applications/DoryGuestTools.app" "$APP"
    fail 'could not move login agent into recovery directory'
  fi
  if ! /bin/mv "$HELPER" "$backup/GuestTools/"; then
    /bin/mv "$backup/LaunchAgents/com.pythonxi.Dory.GuestTools.agent.plist" "$AGENT"
    /bin/mv "$backup/Applications/DoryGuestTools.app" "$APP"
    fail 'could not move maintenance helper into recovery directory'
  fi
  if ! /usr/sbin/pkgutil --forget "$PACKAGE_ID" >/dev/null; then
    /bin/mv "$backup/GuestTools/dory-guest-tools-maintenance" "$HELPER"
    /bin/mv "$backup/LaunchAgents/com.pythonxi.Dory.GuestTools.agent.plist" "$AGENT"
    /bin/mv "$backup/Applications/DoryGuestTools.app" "$APP"
    fail 'could not forget package receipt; installed files were restored'
  fi
  printf 'Dory Guest Tools uninstalled. Recovery copy: %s\n' "$backup"
}

[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'run this command with sudo inside the Mac guest'
if [ "${DORY_GUEST_TOOLS_MAINTENANCE_LOCKED-}" != 1 ]; then
  DORY_GUEST_TOOLS_MAINTENANCE_LOCKED=1
  export DORY_GUEST_TOOLS_MAINTENANCE_LOCKED
  exec /usr/bin/lockf -k -t 0 /var/run/com.pythonxi.Dory.GuestTools.maintenance.lock /bin/sh "$0" "$@"
fi
case "${1-}" in
  install)
    [ "$#" -eq 3 ] || fail 'usage: install PACKAGE.pkg PACKAGE.pkg.json'
    if /usr/sbin/pkgutil --pkg-info "$PACKAGE_ID" >/dev/null 2>&1; then
      fail 'Guest Tools is already installed; use update or rollback with the retained current package'
    fi
    install_package "$2" "$3" ;;
  update|rollback)
    [ "$#" -eq 5 ] || fail 'usage: update|rollback TARGET.pkg TARGET.pkg.json CURRENT.pkg CURRENT.pkg.json'
    verify_package "$4" "$5"
    verify_installed "$(field "$5" loginAgent.sha256)" "$5"
    verify_package "$2" "$3"
    if ! (install_package "$2" "$3"); then
      printf 'Dory Guest Tools: package change failed; restoring prior signed package\n' >&2
      install_package "$4" "$5" || fail 'automatic rollback failed; preserve both packages and repair manually'
      fail 'package change failed; prior signed package was restored'
    fi ;;
  uninstall)
    [ "$#" -eq 1 ] || fail 'usage: uninstall'
    uninstall_package ;;
  *) fail 'usage: install|update|rollback|uninstall (see Guest Tools documentation)' ;;
esac
