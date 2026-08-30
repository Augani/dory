# DoryPC firmware

This directory owns the native X64 UEFI firmware for the frozen `DoryPC-v1`
machine. It is built from the exact EDK II source revision in
`source.lock.json`, the verified macOS host tools in `toolchain.lock.json`, the
reviewed patch under `patches/`, and the Dory-owned platform package in
`DoryPCPkg/`.

The platform discovers RAM, CPU, PCI apertures, ACPI, SMBIOS, immutable flash,
and the persistent variable bridge through Dory's read-only firmware
configuration page. It does not consume QEMU fw_cfg or QEMU machine metadata.
The boot manager connects all Dory devices, enumerates removable block devices
before fixed disks on zero-state NVRAM, and thereafter honors persistent UEFI
`BootOrder`.

Build and atomically publish a four-file firmware bundle:

```sh
/usr/bin/python3 scripts/build-dory-armvirt-firmware.py --platform pc \
  --output /absolute/new/output/dory-pc-firmware
```

For an already verified checkout of the pinned source, add
`--edk2-source /absolute/path/to/edk2`. The builder rejects source, submodule,
toolchain, platform, artifact-size, or output-file-set drift and never replaces
an existing destination.

Require two independent clean builds to be byte-identical:

```sh
/usr/bin/python3 scripts/verify-dory-armvirt-firmware-reproducibility.py --platform pc \
  --edk2-source /absolute/path/to/edk2
```

The resulting `firmware-code.fd` is right-aligned below 4 GiB by the DoryPC
flash device. Its last 16 bytes contain the architectural x86 reset vector.
