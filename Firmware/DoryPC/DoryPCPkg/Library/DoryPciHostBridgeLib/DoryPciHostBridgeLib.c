// SPDX-License-Identifier: BSD-2-Clause-Patent

#include <IndustryStandard/Pci.h>
#include <DoryPCFirmwareConfiguration.h>
#include <Library/BaseMemoryLib.h>
#include <Library/IoLib.h>
#include <Library/PcdLib.h>
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
  PCI_ROOT_BRIDGE_APERTURE MemoryAbove4G;
  UINT64                   Mmio64Base;
  UINT64                   Mmio64Size;

  ZeroMem (&Io, sizeof (Io));
  Io.Base     = DORY_PC_IO_BASE;
  Io.Limit    = DORY_PC_IO_BASE + DORY_PC_IO_SIZE - 1;
  ZeroMem (&Memory, sizeof (Memory));
  Memory.Base  = DORY_PCIE_MMIO_BASE;
  Memory.Limit = DORY_PCIE_MMIO_BASE + DORY_PCIE_MMIO_SIZE - 1;
  Mmio64Base = MmioRead64 (
                 FixedPcdGet64 (PcdFirmwareConfigurationBase) +
                 DORY_PC_CONFIGURATION_MMIO64_BASE_OFFSET
                 );
  Mmio64Size = MmioRead64 (
                 FixedPcdGet64 (PcdFirmwareConfigurationBase) +
                 DORY_PC_CONFIGURATION_MMIO64_SIZE_OFFSET
                 );
  ZeroMem (&MemoryAbove4G, sizeof (MemoryAbove4G));
  if ((Mmio64Base < BASE_4GB) || (Mmio64Size == 0) ||
      ((Mmio64Size & (Mmio64Size - 1)) != 0) ||
      ((Mmio64Base & (Mmio64Size - 1)) != 0) ||
      (Mmio64Base > MAX_UINT64 - Mmio64Size))
  {
    return NULL;
  }
  MemoryAbove4G.Base  = Mmio64Base;
  MemoryAbove4G.Limit = Mmio64Base + Mmio64Size - 1;
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
           &MemoryAbove4G,
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
