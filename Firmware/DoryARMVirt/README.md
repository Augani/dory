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
  --expect "GNU GRUB" \
  --timeout-sec 60
```

The resulting receipt also binds the installer byte count and SHA-256. This
gate proves immutable-media admission, UEFI enumeration, and execution of the
image's own AArch64 bootloader; distribution install and reboot qualification
remain separate gates.
