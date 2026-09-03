# DoryARMVirt-v1 ABI

Identity: `dory.armvirt@1`

This file is the checked-in projection of `DoryARMVirtV1ABI`. Changes are ABI changes and require a new machine identity.

## Physical address map

| Region | Base | Reserved bytes |
|---|---:|---:|
| Firmware code | `0x00000000` | `0x04000000` |
| Firmware variables | `0x04000000` | `0x04000000` |
| GICv3 distributor | `0x08000000` | `0x00010000` |
| GICv3 redistributors | `0x080a0000` | `0x02000000` |
| PL011 UART | `0x0c000000` | `0x00001000` |
| PL031 RTC | `0x0c090000` | `0x00001000` |
| Power/reset controller | `0x0c0a0000` | `0x00001000` |
| VirtIO MMIO slots | `0x0c100000` | `0x00004000` |
| PCIe ECAM | `0x10000000` | `0x10000000` |
| PCIe MMIO | `0x40000000` | `0x40000000` |
| RAM | `0x80000000` | `0x0000000b80000000` maximum before DAX |
| DAX window | `0x0000000c00000000` | variable, admitted separately |

Both boot protocols place the FDT at RAM + `0x10000000` and pass its address in `x0`. Direct Linux places the initrd at RAM + `0x14000000`. UEFI begins at `0x00000000`, uses firmware ABI `dory.edk2.armvirt@1`, and persists variables as `dory.uefi.variables.armvirt@1`. The minimum RAM size is `0x40000000` bytes. The machine exposes 1...256 vCPUs subject to host admission.

## Interrupt map

UART uses SPI 1 / INTID 33. VirtIO slots 0...31 use SPIs 16...47 / INTIDs 48...79. Architectural timer PPIs are secure physical 13, non-secure physical 14, virtual 11, and hypervisor physical 10.

## VirtIO MMIO slot roles

| Slots | Role |
|---|---|
| 0 | system disk |
| 1 | graphics |
| 2 | entropy |
| 3 | balloon |
| 4 | vsock |
| 5 | keyboard |
| 6 | pointer |
| 7 | audio |
| 8...11 | network |
| 12...19 | auxiliary/removable storage |
| 20...29 | directory sharing |
| 30 | USB controller |
| 31 | reserved; never allocatable in ABI v1 |

VirtIO MMIO is the compatibility transport. PCIe ECAM/MMIO, firmware flash, persistent variables, and power/reset addresses are frozen reservations in v1; exposing a device in one of those regions must preserve this map and the separately versioned firmware and device ABIs.
