// SPDX-License-Identifier: BSD-2-Clause-Patent

#include <PiPei.h>
#include <DoryPCFirmwareConfiguration.h>
#include <Library/BaseLib.h>
#include <Library/DebugLib.h>
#include <Library/HobLib.h>
#include <Library/IoLib.h>
#include <Library/PcdLib.h>
#include <Library/PeiServicesLib.h>
#include <Library/ResourcePublicationLib.h>

#define DORY_LEGACY_MEMORY_END  0x000A0000ULL
#define DORY_HIGH_MEMORY_BASE   0x00100000ULL
#define DORY_ACPI_BASE          0x0009E000ULL
#define DORY_ACPI_SIZE          0x00002000ULL
#define DORY_SMBIOS_BASE        0x000F0000ULL
#define DORY_SMBIOS_SIZE        0x00010000ULL
#define DORY_PEI_MEMORY_SIZE    0x04000000ULL

STATIC UINTN mConfigurationBase;

STATIC
UINT32
ConfigurationRead32 (
  IN UINTN Offset
  )
{
  return MmioRead32 (mConfigurationBase + Offset);
}

STATIC
UINT64
ConfigurationRead64 (
  IN UINTN Offset
  )
{
  return MmioRead64 (mConfigurationBase + Offset);
}

STATIC
VOID
DoryPublishSystemMemory (
  IN UINT64 LowRam,
  IN UINT64 HighRam,
  IN UINT64 HighRamBase
  )
{
  BuildResourceDescriptorHob (
    EFI_RESOURCE_SYSTEM_MEMORY,
    EFI_RESOURCE_ATTRIBUTE_PRESENT | EFI_RESOURCE_ATTRIBUTE_INITIALIZED |
      EFI_RESOURCE_ATTRIBUTE_TESTED | EFI_RESOURCE_ATTRIBUTE_UNCACHEABLE |
      EFI_RESOURCE_ATTRIBUTE_WRITE_COMBINEABLE | EFI_RESOURCE_ATTRIBUTE_WRITE_THROUGH_CACHEABLE |
      EFI_RESOURCE_ATTRIBUTE_WRITE_BACK_CACHEABLE,
    0,
    LowRam
    );
  if (HighRam != 0) {
    BuildResourceDescriptorHob (
      EFI_RESOURCE_SYSTEM_MEMORY,
      EFI_RESOURCE_ATTRIBUTE_PRESENT | EFI_RESOURCE_ATTRIBUTE_INITIALIZED |
        EFI_RESOURCE_ATTRIBUTE_TESTED | EFI_RESOURCE_ATTRIBUTE_UNCACHEABLE |
        EFI_RESOURCE_ATTRIBUTE_WRITE_COMBINEABLE | EFI_RESOURCE_ATTRIBUTE_WRITE_THROUGH_CACHEABLE |
        EFI_RESOURCE_ATTRIBUTE_WRITE_BACK_CACHEABLE,
      HighRamBase,
      HighRam
      );
  }

  BuildMemoryAllocationHob (DORY_ACPI_BASE, DORY_ACPI_SIZE, EfiACPIReclaimMemory);
  BuildMemoryAllocationHob (DORY_LEGACY_MEMORY_END, DORY_HIGH_MEMORY_BASE - DORY_LEGACY_MEMORY_END, EfiReservedMemoryType);
  BuildMemoryAllocationHob (DORY_SMBIOS_BASE, DORY_SMBIOS_SIZE, EfiReservedMemoryType);
}

STATIC
VOID
PublishFirmwareVolumes (
  VOID
  )
{
  BuildMemoryAllocationHob (
    PcdGet32 (PcdOvmfPeiMemFvBase),
    PcdGet32 (PcdOvmfPeiMemFvSize),
    EfiBootServicesData
    );
  BuildMemoryAllocationHob (
    PcdGet32 (PcdOvmfDxeMemFvBase),
    PcdGet32 (PcdOvmfDxeMemFvSize),
    EfiBootServicesData
    );
  BuildFvHob (PcdGet32 (PcdOvmfPeiMemFvBase), PcdGet32 (PcdOvmfPeiMemFvSize));
  BuildFvHob (PcdGet32 (PcdOvmfDxeMemFvBase), PcdGet32 (PcdOvmfDxeMemFvSize));
}

EFI_STATUS
EFIAPI
DoryPlatformPeiEntryPoint (
  IN EFI_PEI_FILE_HANDLE FileHandle,
  IN CONST EFI_PEI_SERVICES **PeiServices
  )
{
  EFI_STATUS Status;
  UINT64     LowRam;
  UINT64     HighRam;
  UINT64     HighRamBase;
  UINT64     PeiMemoryBase;
  UINT64     PeiMemorySize;

  mConfigurationBase = (UINTN)FixedPcdGet64 (PcdFirmwareConfigurationBase);
  if ((ConfigurationRead64 (DORY_PC_CONFIGURATION_MAGIC_OFFSET) != DORY_PC_CONFIGURATION_MAGIC) ||
      (ConfigurationRead32 (DORY_PC_CONFIGURATION_VERSION_OFFSET) != DORY_PC_CONFIGURATION_VERSION) ||
      (ConfigurationRead32 (DORY_PC_CONFIGURATION_HEADER_SIZE_OFFSET) < DORY_PC_CONFIGURATION_HEADER_SIZE))
  {
    return EFI_COMPROMISED_DATA;
  }

  LowRam      = ConfigurationRead64 (DORY_PC_CONFIGURATION_LOW_RAM_OFFSET);
  HighRam     = ConfigurationRead64 (DORY_PC_CONFIGURATION_HIGH_RAM_OFFSET);
  HighRamBase = ConfigurationRead64 (DORY_PC_CONFIGURATION_HIGH_RAM_BASE);
  if ((LowRam < SIZE_128MB) || (LowRam > ConfigurationRead64 (DORY_PC_CONFIGURATION_MMIO_BASE_OFFSET)) ||
      (HighRamBase < BASE_4GB))
  {
    return EFI_COMPROMISED_DATA;
  }

  Status = PeiServicesSetBootMode (BOOT_WITH_FULL_CONFIGURATION);
  if (EFI_ERROR (Status)) {
    return Status;
  }

  DoryPublishSystemMemory (LowRam, HighRam, HighRamBase);
  PublishFirmwareVolumes ();
  BuildCpuHob (40, 16);

  PeiMemorySize = MIN (DORY_PEI_MEMORY_SIZE, LowRam - SIZE_32MB);
  PeiMemoryBase = LowRam - PeiMemorySize;
  return PeiServicesInstallPeiMemory (PeiMemoryBase, PeiMemorySize);
}
