// SPDX-License-Identifier: BSD-2-Clause-Patent

#include <IndustryStandard/Pci.h>
#include <Library/BaseMemoryLib.h>
#include <Library/PciHostBridgeLib.h>
#include <Library/PciHostBridgeUtilityLib.h>
#include <Protocol/PciHostBridgeResourceAllocation.h>
#include <Protocol/PciIo.h>
#include <Protocol/PciRootBridgeIo.h>

#define DORY_PCIE_MMIO_BASE  0xD0000000ULL
#define DORY_PCIE_MMIO_SIZE  0x10000000ULL
#define DORY_PC_IO_BASE      0x0000ULL
#define DORY_PC_IO_SIZE      0x10000ULL

STATIC PCI_ROOT_BRIDGE_APERTURE mAbsent = { MAX_UINT64, 0 };

PCI_ROOT_BRIDGE *
EFIAPI
PciHostBridgeGetRootBridges (
  UINTN *Count
  )
{
  PCI_ROOT_BRIDGE_APERTURE Io;
  PCI_ROOT_BRIDGE_APERTURE Memory;

  ZeroMem (&Io, sizeof (Io));
  Io.Base     = DORY_PC_IO_BASE;
  Io.Limit    = DORY_PC_IO_BASE + DORY_PC_IO_SIZE - 1;
  ZeroMem (&Memory, sizeof (Memory));
  Memory.Base  = DORY_PCIE_MMIO_BASE;
  Memory.Limit = DORY_PCIE_MMIO_BASE + DORY_PCIE_MMIO_SIZE - 1;
  return PciHostBridgeUtilityGetRootBridges (
           Count,
           EFI_PCI_IO_ATTRIBUTE_IO |
             EFI_PCI_IO_ATTRIBUTE_ISA_IO |
             EFI_PCI_IO_ATTRIBUTE_ISA_IO_16 |
             EFI_PCI_IO_ATTRIBUTE_ISA_MOTHERBOARD_IO,
           EFI_PCI_HOST_BRIDGE_COMBINE_MEM_PMEM,
           FALSE,
           FALSE,
           0,
           PCI_MAX_BUS,
           &Io,
           &Memory,
           &mAbsent,
           &mAbsent,
           &mAbsent
           );
}
VOID
EFIAPI
PciHostBridgeFreeRootBridges (
  PCI_ROOT_BRIDGE *Bridges,
  UINTN Count
  )
{
  PciHostBridgeUtilityFreeRootBridges (Bridges, Count);
}

VOID
EFIAPI
PciHostBridgeResourceConflict (
  EFI_HANDLE HostBridgeHandle,
  VOID       *Configuration
  )
{
  PciHostBridgeUtilityResourceConflict (Configuration);
}
