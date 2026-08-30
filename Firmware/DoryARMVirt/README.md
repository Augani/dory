# Dory ARMVirt firmware

This directory owns Dory's AArch64 UEFI platform. The release input is the
exact EDK II revision in `source.lock.json`, the host toolchain in
`toolchain.lock.json`, the `DoryARMVirtPkg` platform, and the reviewed patches
under `patches/`.

Build a four-file, atomically published firmware bundle:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.6.0-Release.Candidate.app/Contents/Developer \
  /usr/bin/python3 scripts/build-dory-armvirt-firmware.py \
  --output /absolute/new/output/dory-armvirt-firmware
```

For an already verified checkout of the pinned source, add
`--edk2-source /absolute/path/to/edk2`. The builder refuses an unpinned source,
an incomplete submodule set, toolchain drift, an unexpected artifact set, a
non-4 MiB code image, or replacement of an existing output.

Qualify reproducibility with two independent clean builds:

```sh
/usr/bin/python3 scripts/verify-dory-armvirt-firmware-reproducibility.py \
  --edk2-source /absolute/path/to/edk2
```

EDK II normally embeds absolute debug paths and generates a fresh stack-cookie
pool for each clean build. The reviewed patch uses EDK's own debug-zeroing
operation, while the builder supplies EDK's supported pre-generated cookie
pools derived from all pinned inputs. Stack protection remains enabled and the
release bundle is byte-for-byte reproducible.

On an Apple-silicon development Mac, qualify the resulting bundle with the
Hypervisor.framework smoke runner. SwiftPM does not apply executable
entitlements, so the development runner is deliberately signed before launch:

```sh
export DEVELOPER_DIR=/Applications/Xcode-26.6.0-Release.Candidate.app/Contents/Developer
swift build \
  --package-path Packages/ContainerizationEngine \
  --product dory-armvirt-uefi-smoke
runner="$(swift build \
  --package-path Packages/ContainerizationEngine \
  --show-bin-path)/dory-armvirt-uefi-smoke"
codesign --force --sign - \
  --entitlements Packages/ContainerizationEngine/dory-armvirt-uefi-smoke.entitlements \
  "$runner"
"$runner" \
  --firmware-bundle /absolute/path/to/dory-armvirt-firmware
```

The runner creates private zero-state NVRAM and disk resources, preserves them
across firmware-requested resets, and requires the serial console to reach the
embedded UEFI interactive shell. Console output is written to standard error;
a successful run writes one canonical JSON receipt to standard output with the
machine and firmware ABI identities, build identifier, firmware SHA-256, boot
attempt count, variable-store generation, and final stop reason.

To qualify an exact, private, read-only installer image through the removable
VirtIO block path, add the media and a console marker owned by that image:

```sh
chmod 600 /absolute/path/to/installer.iso
"$runner" \
  --firmware-bundle /absolute/path/to/dory-armvirt-firmware \
  --installer-media /absolute/path/to/installer.iso \
  --expect "localhost login:" \
  --timeout-sec 60
```

The resulting receipt also binds the installer byte count and SHA-256. This
gate proves immutable-media admission, UEFI enumeration, execution of the
image's own AArch64 bootloader, Linux kernel and initramfs bring-up, VirtIO disk
discovery, and arrival at the distribution's login prompt. Distribution install
and reboot qualification remain separate gates.

Qualify an installer-driven persistent-disk boot and firmware reset with a
private, bounded console-interaction document. The checked-in Alpine fixture
uses the distribution's own installer, requests network packages through
Dory's pinned gvproxy payload, marks the exact command after which removable
media must detach, and emits its final marker only from the installed guest:

```sh
gvproxy_root="$(mktemp -d /tmp/dory-gvproxy.XXXXXX)"
scripts/build-gvproxy.sh \
  --output "$gvproxy_root/gvproxy" \
  --provenance "$gvproxy_root/provenance.txt"
install_script="$gvproxy_root/alpine-3.24-install.json"
cp Firmware/DoryARMVirt/qualification/alpine-3.24-install.json "$install_script"
chmod 600 "$install_script"
chmod 600 /absolute/path/to/alpine-standard-aarch64.iso
"$runner" \
  --firmware-bundle /absolute/path/to/dory-armvirt-firmware \
  --installer-media /absolute/path/to/alpine-standard-aarch64.iso \
  --console-script "$install_script" \
  --gvproxy "$gvproxy_root/gvproxy" \
  --memory-bytes 4294967296 \
  --system-disk-bytes 4294967296 \
  --expect DORY_INSTALLED_DISK_READY \
  --timeout-sec 300
```

The runner accepts only an owned, private console document with bounded steps,
wait markers, and inputs. It refuses a success marker present in guest input so
terminal echo cannot forge qualification. Receipt schema 4 binds memory and
disk sizes, completed step count, console-document SHA-256, applied installer
media transitions, final-boot media state, cold-snapshot actions and authority,
and the admitted gvproxy SHA-256.
The documented install qualification
succeeds only after a guest reset and a second UEFI boot with the installer
absent.

The adjacent `alpine-3.24-install-update.json` fixture extends the same gate
through `apk update`, a system upgrade, a second firmware reset, and a third
UEFI boot from the updated persistent disk. Run the same command with that
fixture and `--expect DORY_UPDATED_DISK_READY`; its qualifying receipt must
report three boot attempts and all eight interaction steps complete.

`alpine-3.24-recovery.json` proves recovery-media reattachment rather than
another ordinary installed boot. It installs and boots the system disk, writes
a durable sentinel, explicitly reattaches the immutable ISO for the next reset,
selects that media through UEFI's serial boot manager, rejects an installed-root
mount, mounts the persistent root read-only from the live environment, and
verifies the sentinel. Run it with
`--expect DORY_RECOVERY_READY`; its receipt must report three boot attempts,
two applied media transitions, installer media attached for the final boot,
and all ten steps complete.

`alpine-3.24-cold-snapshot.json` exercises the mandatory stopped-VM snapshot
baseline. After installation it writes a base sentinel and powers off, captures
the disk plus canonical NVRAM generation, boots and replaces that sentinel with
post-snapshot state, powers off again, restores into fresh storage authority,
and performs a fourth UEFI boot. Run it with
`--expect DORY_COLD_SNAPSHOT_RESTORED`; success requires all nine interaction
steps, both host actions, the pre-snapshot sentinel present, and the
post-snapshot sentinel absent.

`alpine-3.24-device-baseline.json` installs from the same immutable media and
proves that the installed stock kernel discovers the UEFI environment, system
block device, DoryARMVirt-v1 entropy slot, platform RTC, and network interface.
It reads 32 bytes from VirtIO RNG and binds the guest-visible MAC before
emitting `DORY_DEVICE_BASELINE_READY`. This is the minimum generic-device gate;
desktop display, input, sound, camera, USB, sharing, and clipboard remain
separate physical/device-matrix qualifications.

`debian-13.6-installer-boot.json` is the first independent distribution-family
cell. It admits Debian's official `debian-13.6.0-arm64-netinst.iso` unchanged,
selects the stock text installer from its own GRUB menu, and requires the
installer's `Select a language` screen. The qualified image is 735,358,976
bytes with SHA-256
`ffa590beb3ae9158c354e00ebc4bf45421f4720bb3a8ddf2db3cbfc0374cf480`;
the digest must match Debian's signed `SHA256SUMS` before the private local file
is passed to the runner. Run this gate with
`--expect "Select a language"` and an 8 GiB system disk.
