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
install -Dm644 %{_sourcedir}/GuestTools/Linux/payload/usr/lib/systemd/system/dory-agent.service \
  %{buildroot}%{_unitdir}/dory-agent.service
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

%preun
%systemd_preun dory-agent.service

%postun
%systemd_postun_with_restart dory-agent.service

%files
%license %{_licensedir}/dory-guest-tools/GPL-3.0.txt
%license %{_licensedir}/dory-guest-tools/MIT.txt
/usr/lib/dory/dory-agent
/usr/lib/dory/clipboard
%{_unitdir}/dory-agent.service
%{_tmpfilesdir}/dory-guest-tools.conf

%changelog
* Sun Sep 20 2026 Dory <support@usedory.com> - 0.1.0-1
- Initial stock Fedora guest-tools package.
