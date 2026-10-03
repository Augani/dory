Name: dory-guest-tools
Version: 0.1.0
Release: 1%{?dist}
Summary: Dory integration services for stock Linux virtual machines
License: GPL-3.0-only AND MIT
BuildRequires: cargo
BuildRequires: rust
BuildRequires: protobuf-compiler
BuildRequires: systemd-rpm-macros
Requires: wl-clipboard
Requires: xclip
Requires: util-linux
Requires: systemd

%description
Host-only vsock agent and bounded GNOME/KDE clipboard bridge for Dory virtual machines.

%build
cd %{_sourcedir}/dory-core
cargo build --locked --release -p dory-agent

%install
install -Dm755 %{_sourcedir}/dory-core/target/release/dory-agent \
  %{buildroot}/usr/lib/dory/dory-agent
install -Dm755 %{_sourcedir}/GuestTools/Linux/payload/usr/lib/dory/clipboard \
  %{buildroot}/usr/lib/dory/clipboard
install -Dm755 %{_sourcedir}/GuestTools/Linux/payload/usr/lib/dory/clipboard-session \
  %{buildroot}/usr/lib/dory/clipboard-session
install -Dm755 %{_sourcedir}/GuestTools/Linux/payload/usr/lib/dory/display-resize \
  %{buildroot}/usr/lib/dory/display-resize
install -Dm644 %{_sourcedir}/GuestTools/Linux/payload/usr/lib/dory/active-desktop-session \
  %{buildroot}/usr/lib/dory/active-desktop-session
install -Dm644 %{_sourcedir}/GuestTools/Linux/payload/usr/lib/systemd/system/dory-agent.service \
  %{buildroot}%{_unitdir}/dory-agent.service
install -Dm644 %{_sourcedir}/GuestTools/Linux/payload/usr/lib/systemd/user/dory-clipboard.service \
  %{buildroot}%{_userunitdir}/dory-clipboard.service
install -Dm644 %{_sourcedir}/GuestTools/Linux/payload/usr/lib/udev/rules.d/90-dory-display-resize.rules \
  %{buildroot}%{_udevrulesdir}/90-dory-display-resize.rules
install -Dm644 %{_sourcedir}/GuestTools/Linux/payload/usr/lib/tmpfiles.d/dory-guest-tools.conf \
  %{buildroot}%{_tmpfilesdir}/dory-guest-tools.conf
install -Dm644 %{_sourcedir}/LICENSE \
  %{buildroot}%{_licensedir}/dory-guest-tools/GPL-3.0.txt
install -Dm644 %{_sourcedir}/GuestTools/Linux/LICENSES/MIT.txt \
  %{buildroot}%{_licensedir}/dory-guest-tools/MIT.txt

%post
systemd-tmpfiles --create dory-guest-tools.conf || :
%systemd_post dory-agent.service
%systemd_user_post dory-clipboard.service
systemctl --global enable dory-clipboard.service || :
if command -v loginctl >/dev/null 2>&1; then
  for uid in $(loginctl list-users --no-legend --no-pager 2>/dev/null | awk '{ print $1 }'); do
    case "$uid" in ''|*[!0-9]*) continue ;; esac
    [ "$uid" -ge 1000 ] && [ "$uid" -lt 60000 ] || continue
    user="$(getent passwd "$uid" | cut -d: -f1)"
    [ -n "$user" ] || continue
    runtime="/run/user/$uid"
    [ -S "$runtime/bus" ] || continue
    runuser -u "$user" -- env XDG_RUNTIME_DIR="$runtime" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" \
      systemctl --user is-active --quiet graphical-session.target || continue
    runuser -u "$user" -- env XDG_RUNTIME_DIR="$runtime" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" \
      systemctl --user start dory-clipboard.service || :
  done
fi
/usr/bin/udevadm control --reload-rules >/dev/null 2>&1 || :

%preun
if [ "$1" -eq 0 ] && command -v loginctl >/dev/null 2>&1; then
  for uid in $(loginctl list-users --no-legend --no-pager 2>/dev/null | awk '{ print $1 }'); do
    case "$uid" in ''|*[!0-9]*) continue ;; esac
    [ "$uid" -ge 1000 ] && [ "$uid" -lt 60000 ] || continue
    user="$(getent passwd "$uid" | cut -d: -f1)"
    [ -n "$user" ] || continue
    runtime="/run/user/$uid"
    if [ -S "$runtime/bus" ]; then
      runuser -u "$user" -- env XDG_RUNTIME_DIR="$runtime" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" \
        systemctl --user stop dory-clipboard.service || :
    fi
  done
fi
%systemd_preun dory-agent.service
%systemd_user_preun dory-clipboard.service
if [ "$1" -eq 0 ]; then
  systemctl --global disable dory-clipboard.service || :
fi

%postun
%systemd_postun_with_restart dory-agent.service
%systemd_user_postun_with_restart dory-clipboard.service
/usr/bin/udevadm control --reload-rules >/dev/null 2>&1 || :
if [ "$1" -eq 0 ]; then
  # Preserve the optional administrator-authored account restriction on uninstall.
  rmdir /var/lib/dory >/dev/null 2>&1 || :
fi

%files
%license %{_licensedir}/dory-guest-tools/GPL-3.0.txt
%license %{_licensedir}/dory-guest-tools/MIT.txt
/usr/lib/dory/dory-agent
/usr/lib/dory/clipboard
/usr/lib/dory/clipboard-session
/usr/lib/dory/display-resize
/usr/lib/dory/active-desktop-session
%{_unitdir}/dory-agent.service
%{_userunitdir}/dory-clipboard.service
%{_udevrulesdir}/90-dory-display-resize.rules
%{_tmpfilesdir}/dory-guest-tools.conf

%changelog
* Sun Sep 20 2026 Dory <support@usedory.com> - 0.1.0-1
- Initial stock Fedora guest-tools package.
