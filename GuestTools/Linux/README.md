# Dory Guest Tools for Linux

This directory is the stock-distribution package source for `dory-guest-tools`. It installs the
Rust `dory-agent` as a system service plus the bounded clipboard bridge used by Dory's desktop
coordinator. It does not build a guest image, kernel, or Mesa and it has no Docker/QEMU path.

The package also installs `dory-clipboard.service` into the graphical user manager. Its live
session marker prevents the root agent from addressing a logged-out desktop. A DRM hotplug udev
rule observes every Dory scanout change and refreshes Xorg with `xrandr --auto`; GNOME and KDE on
Wayland consume the same kernel hotplug event directly.

Build each package inside its target stock distribution VM so the package manager and Rust target
match the guest. The native producer requires a clean checkout, stages tracked source from the
selected commit, verifies the host/package architecture, and emits a SHA-256 source receipt:

```sh
# Ubuntu / Debian ARM64 (repeat inside x86_64 Ubuntu for the amd64 package)
sudo apt install build-essential cargo rustc protobuf-compiler debhelper devscripts \
  wl-clipboard xclip
GuestTools/Linux/build-native-package.sh --format deb \
  --output-dir /absolute/path/to/native-packages

# Fedora ARM64 (repeat inside x86_64 Fedora for the x86_64 package)
sudo dnf install cargo rust protobuf-compiler rpm-build wl-clipboard xclip
GuestTools/Linux/build-native-package.sh --format rpm \
  --output-dir /absolute/path/to/native-packages
```

The `.build-receipt.json` beside each package records the source commit, native guest architecture
and package digest. Retain it with the signed candidate inventory. The ISO assembler signs the
`.deb` bytes with a detached signature and embeds a signature in the `.rpm`, then signs both
apt/dnf repository metadata sets. Apt uses the signed repository metadata at install time.
Neither package is release-qualified solely by a successful native build.

Inside a guest, mount the signed tools ISO and run `sudo ./install.sh install`. To return to an
older version, mount that version's signed ISO and run `sudo ./install.sh rollback`; use
`sudo ./install.sh uninstall` to remove the package. The installer uses a temporary apt/dnf
repository definition and removes it after the transaction, so ejecting the ISO does not leave
a stale package source. Debian pins `dory-guest-tools` to the signed Dory-origin ISO repository;
Fedora selects that repository explicitly for the Dory package. Distribution dependencies must
be present or reachable through ordinary distro repositories; the ISO contains only Dory's
package, not a mirror of Ubuntu or Fedora.
An installer-wide lock rejects a simultaneous install, rollback, or uninstall rather than letting
two mounted ISO repositories with the same temporary dnf ID race. The lock releases automatically
if the installer exits or crashes.
After verifying the exact installed package version, the installer enables and restarts the guest
agent in the running systemd guest; an offline chroot is not a supported interactive install
route. If service activation fails, the script reports failure while leaving the installed
package available for repair or rollback.
On upgrades from the earlier installer, a recognizable legacy Dory repository file is disabled
during the transaction and removed on success. A failed transaction restores it; a modified or
indirect legacy file is left untouched and reported for review.

The clipboard and Xorg-resize helpers select the one active local graphical logind session at
request time. They refuse remote, greeter, inactive and ambiguous sessions. Administrators can
write a root-owned `/var/lib/dory/username` (mode 0600, 0640 or 0644) to restrict access to one
account; package installation never guesses an account from passwd ordering. On systems upgraded
from an older package, remove an auto-generated `username` file to enable active-user selection.
Uninstall preserves this administrator-controlled file; remove it explicitly if the restriction is
no longer wanted. The empty `/var/lib/dory` directory is removed when possible.

After building both native packages, assemble the signed offline tools image on a machine with the
apt and RPM repository utilities plus the release GPG secret key:

```sh
GuestTools/Linux/build-tools-iso.sh \
  --deb /absolute/path/dory-guest-tools_0.1.0_arm64.deb \
  --rpm /absolute/path/dory-guest-tools-0.1.0-1.aarch64.rpm \
  --gpg-key FULL_RELEASE_KEY_FINGERPRINT \
  --expected-source-commit FULL_DORY_SOURCE_COMMIT \
  --expected-architecture arm64 \
  --output /absolute/path/dory-guest-tools-arm64.iso
```

The assembler requires both native build receipts to name the same source commit, guest ISA and
tools version, and rechecks the copied bytes before RPM signing. The ISO contains those retained
receipts and a native-build manifest, signed apt and dnf repository metadata, individually signed
DEB and RPM artifacts, the public key, a signed SHA-256 inventory, and a single offline `install.sh` entry
point. The RPM receipt hashes its native unsigned input; `SHA256SUMS` hashes the final signed RPM.
The unsigned RPM is retained under `native-inputs/` so the verifier can recompute its build
receipt and compare its payload with the signed installable RPM.
The assembler verifies the completed ISO before publishing it. For an independent repeat check,
run:

```sh
GuestTools/Linux/verify-tools-iso.sh \
  --iso /absolute/path/dory-guest-tools-arm64.iso \
  --expected-gpg-key FULL_RELEASE_KEY_FINGERPRINT \
  --expected-source-commit FULL_DORY_SOURCE_COMMIT \
  --expected-architecture arm64
```

A package pair or signature from another release cell is rejected.
Produce a separate `dory-guest-tools-x86_64.iso` from native amd64/x86_64 package inputs.
The daemon selects the ISO by the Linux guest's architecture, not the Apple Silicon host's.
When bundling either ISO in the macOS app, set
`DORY_LINUX_GUEST_TOOLS_GPG_FINGERPRINT` to the full expected release-key fingerprint.
The bundle step re-verifies the copied ISO's signature, complete inventory, package receipts,
source commit and guest architecture using `verify-tools-iso.sh --portable`; it cannot repeat
Linux-only package metadata and RPM payload inspection without `dpkg` and `rpm`.
Only a non-public development bundle may opt out with
`DORY_ALLOW_UNVERIFIED_GUEST_TOOLS_ISO=1`; public releases cannot.
