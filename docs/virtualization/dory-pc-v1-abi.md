# DoryPC-v1 ABI

Identity: `dory.pc@1`

This file is the checked-in projection of `DoryPCV1ABI`. Guest-visible changes require a new machine identity. The x86 interpreter, baseline ARM64 JIT, and optimizing JIT use this same contract.

## Physical address map

| Region | Base | Reserved bytes |
|---|---:|---:|
| PVH handoff | `0x00090000` | `0x00004000` |
| ACPI tables | `0x0009e000` | `0x00002000` |
| SMBIOS discovery | `0x000f0000` | `0x00010000` |
| RAM above low reservations | `0x00100000` | to the PCI MMIO hole |
| PCIe MMIO | `0xd0000000` | `0x10000000` |
| PCIe ECAM | `0xe0000000` | `0x10000000` |
| Firmware configuration | `0xfe900000` | `0x00001000` |
| Firmware-variable bridge | `0xfea00000` | `0x00200000` |
| IOAPIC | `0xfec00000` | `0x00001000` |
| HPET | `0xfed00000` | `0x00000400` |
| Local APIC | `0xfee00000` | `0x00001000` |
| Firmware code | `0xff000000` | `0x01000000` |
| RAM remapped above 4 GiB | `0x0000000100000000` | variable |

UEFI resets at `0xfffffff0`, uses firmware ABI `dory.edk2.pc@1`, and persists variables as `dory.uefi.variables.pc@1`. Product launches accept 512 MiB through 512 GiB in 2 MiB increments and 1...255 logical processors.

## Interrupt and PCI contract

The IOAPIC exposes GSIs 0...23. PCI INTx uses level-triggered, active-low GSIs 16...23 with standard device/pin swizzling. MSI and MSI-X target the local APIC window. PCIe ECAM covers segment 0, buses 0...255. BAR MMIO is allocated from the frozen 256 MiB PCIe aperture.

| Boot device | PCI address | BAR 0 |
|---|---:|---:|
| System disk | `0000:00:01.0` | `0xd0000000` |
| Removable installer media | `0000:00:0c.0` | `0xd0001000` |
| VirtIO GPU | `0000:00:02.0` | `0xd0002000` |
| VirtIO keyboard | `0000:00:03.0` | `0xd0003000` |
| VirtIO relative pointer | `0000:00:04.0` | `0xd0004000` |
| VirtIO absolute tablet | `0000:00:05.0` | `0xd0005000` |
| VirtIO sound | `0000:00:06.0` | `0xd0006000` |
| xHCI USB controller | `0000:00:07.0` | `0xd0008000` |
| VirtIO network | `0000:00:08.0` | `0xd000c000` |
| VirtIO entropy | `0000:00:09.0` | `0xd000d000` |
| VirtIO socket | `0000:00:0a.0` | `0xd000e000` |

## Boot contract

Direct-kernel PVH remains an engineering and managed-image profile. Product installation starts at the UEFI reset vector, discovers ACPI/SMBIOS, boots removable media according to persistent UEFI boot variables, and then boots the installed system disk. Firmware code is immutable per launch; each VM owns an atomic variable store.

Before UEFI executes, the launch authority atomically projects the validated device order into
standard `Boot####` and `BootOrder` variables under the EFI global-variable GUID. Dory-owned load
options contain an active whole-device path of `ACPI(PNP0A03,0)/PCI(function,device)` and private
optional-data marker `DORYPC1\0<logical-id>`. New Dory options allocate from `BootD000` through
`BootDFFF` without replacing an occupied guest option. Existing Dory options are reused by marker;
stale or duplicate Dory-owned options are removed. Guest-created options and their relative
`BootOrder` are retained after the launch plan's physical-device fallbacks. An unchanged projection
does not advance the variable-store generation, and a store requiring backup recovery cannot boot
until recovery is explicitly completed.
