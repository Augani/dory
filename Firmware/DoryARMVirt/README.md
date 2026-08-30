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
