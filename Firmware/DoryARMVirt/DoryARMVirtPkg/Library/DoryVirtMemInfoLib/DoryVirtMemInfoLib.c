// SPDX-License-Identifier: BSD-2-Clause-Patent

#include <PiPei.h>
#include <Library/ArmLib.h>
#include <Library/BaseLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/DebugLib.h>
#include <Library/FdtLib.h>
#include <Library/HobLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/PcdLib.h>

#define DORY_MEMORY_MAP_ENTRIES  5
#define DORY_PERIPHERAL_BASE     0x08000000
#define DORY_PERIPHERAL_SIZE     0x18000000

RETURN_STATUS
EFIAPI
DoryVirtMemInfoLibConstructor (
  VOID
  )
{
  VOID          *Fdt;
  INT32         Node;
  INT32         Length;
  CONST UINT64  *Reg;
  UINT64        MemoryBase;
  UINT64        MemorySize;
  VOID          *Hob;

  Fdt = (VOID *)(UINTN)FixedPcdGet64 (PcdDeviceTreeInitialBaseAddress);
  if ((Fdt == NULL) || (FdtCheckHeader (Fdt) != 0)) {
    return RETURN_COMPROMISED_DATA;
  }

  Node = FdtPathOffset (Fdt, "/memory@80000000");
  if (Node < 0) {
    Node = FdtPathOffset (Fdt, "/memory");
  }

  if (Node < 0) {
    return RETURN_COMPROMISED_DATA;
  }

  Reg = FdtGetProp (Fdt, Node, "reg", &Length);
  if ((Reg == NULL) || (Length != (2 * sizeof (UINT64)))) {
    return RETURN_COMPROMISED_DATA;
  }

  MemoryBase = Fdt64ToCpu (ReadUnaligned64 (Reg));
  MemorySize = Fdt64ToCpu (ReadUnaligned64 (Reg + 1));
  if ((MemoryBase != FixedPcdGet64 (PcdSystemMemoryBase)) ||
      (MemorySize < SIZE_1GB))
  {
    return RETURN_UNSUPPORTED;
  }

  Hob = BuildGuidDataHob (
          &gArmVirtSystemMemorySizeGuid,
          &MemorySize,
          sizeof (MemorySize)
          );
  return (Hob == NULL) ? RETURN_OUT_OF_RESOURCES : RETURN_SUCCESS;
}

VOID
ArmVirtGetMemoryMap (
  OUT ARM_MEMORY_REGION_DESCRIPTOR  **VirtualMemoryMap
  )
{
  ARM_MEMORY_REGION_DESCRIPTOR  *Map;
  VOID                          *MemorySizeHob;

  Map = AllocateZeroPool (
          sizeof (ARM_MEMORY_REGION_DESCRIPTOR) * DORY_MEMORY_MAP_ENTRIES
          );
  if (Map == NULL) {
    *VirtualMemoryMap = NULL;
    return;
  }

  MemorySizeHob = GetFirstGuidHob (&gArmVirtSystemMemorySizeGuid);
  ASSERT (MemorySizeHob != NULL);

  Map[0].PhysicalBase = FixedPcdGet64 (PcdSystemMemoryBase);
  Map[0].VirtualBase  = Map[0].PhysicalBase;
  Map[0].Length       = *(UINT64 *)GET_GUID_HOB_DATA (MemorySizeHob);
  Map[0].Attributes   = ARM_MEMORY_REGION_ATTRIBUTE_WRITE_BACK;

  Map[1].PhysicalBase = DORY_PERIPHERAL_BASE;
  Map[1].VirtualBase  = DORY_PERIPHERAL_BASE;
  Map[1].Length       = DORY_PERIPHERAL_SIZE;
  Map[1].Attributes   = ARM_MEMORY_REGION_ATTRIBUTE_DEVICE;

  Map[2].PhysicalBase = FixedPcdGet64 (PcdFvBaseAddress);
  Map[2].VirtualBase  = Map[2].PhysicalBase;
  Map[2].Length       = FixedPcdGet32 (PcdFvSize);
  Map[2].Attributes   = ARM_MEMORY_REGION_ATTRIBUTE_WRITE_BACK_RO;

  *VirtualMemoryMap = Map;
}
