# Dory Guest Tools for Linux

This directory is the stock-distribution package source for `dory-guest-tools`. It installs the
Rust `dory-agent` as a system service plus the bounded clipboard bridge used by Dory's desktop
coordinator. It does not build a guest image, kernel, or Mesa and it has no Docker/QEMU path.

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
