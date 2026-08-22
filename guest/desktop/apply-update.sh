#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
EXPECTED_DISTRO="${1:-}"
RELEASE_VERSION="${2:-}"

fail() {
  echo "Dory desktop update failed: $*" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || fail "the update must run as root"
case "$EXPECTED_DISTRO" in
  debian|ubuntu|kali) ;;
  *) fail "unsupported distribution '$EXPECTED_DISTRO'" ;;
esac
[ -n "$RELEASE_VERSION" ] || fail "the target release version is missing"
[ -f "$ROOT/manifest.env" ] || fail "manifest.env is missing"
[ -f "$ROOT/SHA256SUMS" ] || fail "SHA256SUMS is missing"

(cd "$ROOT" && sha256sum -c SHA256SUMS) || fail "the signed update payload is corrupt"

manifest_value() {
  sed -n "s/^$1=//p" "$ROOT/manifest.env"
}

[ "$(manifest_value schema)" = 2 ] || fail "the update manifest schema is unsupported"
[ "$(manifest_value arch)" = arm64 ] || fail "the update payload has the wrong architecture"
[ "$(manifest_value distro)" = "$EXPECTED_DISTRO" ] || fail "the update payload has the wrong distribution"
INPUT_SHA256="$(manifest_value input_sha256)"
case "$INPUT_SHA256" in
  [0-9a-f][0-9a-f]*) ;;
  *) fail "the update payload fingerprint is invalid" ;;
esac
[ "${#INPUT_SHA256}" -eq 64 ] || fail "the update payload fingerprint is invalid"

. /etc/os-release
[ "${ID:-}" = "$EXPECTED_DISTRO" ] || fail "this guest is ${ID:-unknown}, not $EXPECTED_DISTRO"
[ "$(uname -m)" = aarch64 ] || fail "this guest is not ARM64"

require_package() {
  package="$1"
  dpkg-query -W -f='${Status}\n' "$package" 2>/dev/null \
    | grep -Fqx 'install ok installed' \
    || fail "the guest is missing required package '$package'; install a supported desktop image before updating Dory guest tools"
}

# packages.txt is the signed package provenance for the matching full image. A guest-tools update
# must not turn into an unreviewed, network-dependent distribution upgrade. Validate the small
# runtime surface the integration layer needs, then update only Dory-owned files below. Ubuntu,
# Debian, and Kali remain responsible for their normal package updates inside the guest.
for package in binfmt-support dconf-cli network-manager openssh-server pipewire spice-vdagent x11-utils zstd; do
  require_package "$package"
done
case "$EXPECTED_DISTRO" in
  ubuntu)
    for package in gdm3 gnome-shell firefox; do require_package "$package"; done
    ;;
  *)
    for package in lightdm xfce4; do require_package "$package"; done
    ;;
esac
if [ "$EXPECTED_DISTRO" = ubuntu ]; then
  # Keep Ubuntu's dock pointed at the Mozilla APT launcher rather than the absent Snap ID.
  sed -i "s/firefox_firefox\.desktop/firefox.desktop/g" \
    /usr/share/glib-2.0/schemas/10_ubuntu-settings.gschema.override
  glib-compile-schemas /usr/share/glib-2.0/schemas
fi

# The component payload is signature-verified on the host and digest-verified again above. Apply
# only Dory-owned integration files; package-manager and user configuration remain guest-owned.
MANAGED_USER="$(cat /var/lib/dory/username 2>/dev/null || printf 'dory\n')"
id "$MANAGED_USER" >/dev/null 2>&1 || fail "the managed desktop account is missing"
tar -xf "$ROOT/rootfs-overlay.tar" -C /
zstd -q -d -c "$ROOT/dory-mesa-venus-arm64.tar.zst" | tar -xf - -C /
install -m0755 "$ROOT/dory-agent" /usr/bin/dory-agent
chmod 0755 /usr/lib/dory/clipboard /usr/lib/dory/configure-machine /usr/lib/dory/first-boot \
  /usr/lib/dory/start-agent /usr/lib/dory/wait-host-configuration \
  /usr/lib/dory/configure-display /usr/lib/dory/configure-zram \
  /usr/lib/dory/configure-graphics-backend /usr/lib/dory/configure-intel-translation \
  /usr/lib/dory/dory-vulkan-probe
chmod 0600 /etc/NetworkManager/system-connections/dory-wired.nmconnection
chmod 0644 /etc/polkit-1/rules.d/49-dory-passwordless-admin.rules
if [ -x /usr/bin/dconf ]; then
  dconf update
fi

rm -f /etc/resolv.conf
ln -s ../run/NetworkManager/resolv.conf /etc/resolv.conf
case "$EXPECTED_DISTRO" in
  ubuntu)
    rm -rf /etc/lightdm
    sed -i "s/^AutomaticLogin=.*/AutomaticLogin=$MANAGED_USER/" /etc/gdm3/custom.conf
    systemctl enable gdm3.service
    ;;
  *)
    rm -rf /etc/gdm3
    sed -i "s/^autologin-user=.*/autologin-user=$MANAGED_USER/" \
      /etc/lightdm/lightdm.conf.d/50-dory.conf
    systemctl enable lightdm.service
    ;;
esac
systemctl enable NetworkManager.service NetworkManager-wait-online.service ssh.service \
  dory-first-boot.service dory-boot.service dory-desktop-ready.service dory-zram.service \
  dory-graphics-backend.service dory-intel-translation.service
systemctl set-default graphical.target
systemctl daemon-reload

install -d -m0755 /var/lib/dory
RECEIPT="/var/lib/dory/desktop-update.env"
TEMP_RECEIPT="${RECEIPT}.tmp.$$"
{
  printf 'schema=1\n'
  printf 'distro=%s\n' "$EXPECTED_DISTRO"
  printf 'version=%s\n' "$RELEASE_VERSION"
  printf 'input_sha256=%s\n' "$INPUT_SHA256"
  printf 'installed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$TEMP_RECEIPT"
chmod 0644 "$TEMP_RECEIPT"
mv -f "$TEMP_RECEIPT" "$RECEIPT"

echo "Dory desktop update applied: $EXPECTED_DISTRO $RELEASE_VERSION $INPUT_SHA256"
