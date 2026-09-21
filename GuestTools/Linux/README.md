# Dory Guest Tools for Linux

This directory is the stock-distribution package source for `dory-guest-tools`. It installs the
Rust `dory-agent` as a system service plus the bounded clipboard bridge used by Dory's desktop
coordinator. It does not build a guest image, kernel, or Mesa and it has no Docker/QEMU path.

The package also installs `dory-clipboard.service` into the graphical user manager. Its live
session marker prevents the root agent from addressing a logged-out desktop. A DRM hotplug udev
rule observes every Dory scanout change and refreshes Xorg with `xrandr --auto`; GNOME and KDE on
Wayland consume the same kernel hotplug event directly.

Build packages inside the target distribution VM so the package manager and Rust target match the
guest:

```sh
# Ubuntu / Debian, from the repository root
sudo apt install build-essential cargo rustc protobuf-compiler debhelper devscripts \
  wl-clipboard xclip
cd GuestTools/Linux
dpkg-buildpackage --build=binary --no-sign

# Fedora, from the repository root
sudo dnf install cargo rust protobuf-compiler rpm-build wl-clipboard xclip
rpmbuild -bb GuestTools/Linux/rpm/dory-guest-tools.spec \
  --define "_sourcedir $(pwd)" --define "_topdir $HOME/rpmbuild"
```

The package chooses the first normal login user only when `/var/lib/dory/username` is absent.
Administrators may write that file before installation to bind clipboard access to another account.

After building both native packages, assemble the signed offline tools image on a machine with the
apt and RPM repository utilities plus the release GPG secret key:

```sh
GuestTools/Linux/build-tools-iso.sh \
  --deb /absolute/path/dory-guest-tools_0.1.0_arm64.deb \
  --rpm /absolute/path/dory-guest-tools-0.1.0-1.aarch64.rpm \
  --gpg-key FULL_RELEASE_KEY_FINGERPRINT \
  --output /absolute/path/dory-guest-tools-arm64.iso
```

The ISO contains signed apt and dnf repository metadata, an individually signed RPM, the public
key, a signed SHA-256 inventory, and a single offline `install.sh` entry point.
