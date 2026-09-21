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
if [ ! -s /var/lib/dory/username ]; then
  user="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 && $7 !~ /(nologin|false)$/ { print $1; exit }')"
  if [ -n "$user" ]; then
    printf '%s\n' "$user" > /var/lib/dory/username
    chmod 0644 /var/lib/dory/username
  fi
fi
%systemd_post dory-agent.service
%systemd_user_post dory-clipboard.service
/usr/bin/udevadm control --reload-rules >/dev/null 2>&1 || :

%preun
%systemd_preun dory-agent.service
%systemd_user_preun dory-clipboard.service

%postun
%systemd_postun_with_restart dory-agent.service
%systemd_user_postun_with_restart dory-clipboard.service
/usr/bin/udevadm control --reload-rules >/dev/null 2>&1 || :
if [ "$1" -eq 0 ]; then
  rm -f /var/lib/dory/username
  rmdir /var/lib/dory >/dev/null 2>&1 || :
fi

%files
%license %{_licensedir}/dory-guest-tools/GPL-3.0.txt
%license %{_licensedir}/dory-guest-tools/MIT.txt
/usr/lib/dory/dory-agent
/usr/lib/dory/clipboard
/usr/lib/dory/clipboard-session
/usr/lib/dory/display-resize
%{_unitdir}/dory-agent.service
%{_userunitdir}/dory-clipboard.service
%{_udevrulesdir}/90-dory-display-resize.rules
%{_tmpfilesdir}/dory-guest-tools.conf

%changelog
* Sun Sep 20 2026 Dory <support@usedory.com> - 0.1.0-1
- Initial stock Fedora guest-tools package.
