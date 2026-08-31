// SPDX-License-Identifier: BSD-2-Clause-Patent

#include <Uefi.h>
#include <DoryPCFirmwareConfiguration.h>
#include <Guid/Acpi.h>
#include <Guid/SmBios.h>
#include <Library/IoLib.h>
#include <Library/PcdLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Protocol/MpInitLibDepProtocols.h>

EFI_STATUS
EFIAPI
DoryPlatformDxeEntryPoint (
  IN EFI_HANDLE ImageHandle,
  IN EFI_SYSTEM_TABLE *SystemTable
  )
{
  EFI_STATUS Status;
  UINTN      Base;
  UINT32     CpuCount;
  EFI_GUID   *MpInitLibDepProtocol;
  UINT64     Rsdp;
  UINT64     Smbios;

  Base = (UINTN)FixedPcdGet64 (PcdFirmwareConfigurationBase);
  if ((MmioRead64 (Base + DORY_PC_CONFIGURATION_MAGIC_OFFSET) != DORY_PC_CONFIGURATION_MAGIC) ||
      (MmioRead32 (Base + DORY_PC_CONFIGURATION_VERSION_OFFSET) != DORY_PC_CONFIGURATION_VERSION) ||
      (MmioRead32 (Base + DORY_PC_CONFIGURATION_HEADER_SIZE_OFFSET) < DORY_PC_CONFIGURATION_HEADER_SIZE))
  {
    return EFI_COMPROMISED_DATA;
  }

  CpuCount = MmioRead32 (Base + DORY_PC_CONFIGURATION_CPU_COUNT_OFFSET);
  if ((CpuCount == 0) || (CpuCount > 255)) {
    return EFI_COMPROMISED_DATA;
  }

  Rsdp   = MmioRead64 (Base + DORY_PC_CONFIGURATION_RSDP_OFFSET);
  Smbios = MmioRead64 (Base + DORY_PC_CONFIGURATION_SMBIOS_OFFSET);
  Status = gBS->InstallConfigurationTable (&gEfiAcpi20TableGuid, (VOID *)(UINTN)Rsdp);
  if (EFI_ERROR (Status)) {
    return Status;
  }

  Status = gBS->InstallConfigurationTable (&gEfiSmbios3TableGuid, (VOID *)(UINTN)Smbios);
  if (EFI_ERROR (Status)) {
    return Status;
  }

  MpInitLibDepProtocol = (CpuCount == 1) ?
                         &gEfiMpInitLibUpDepProtocolGuid :
                         &gEfiMpInitLibMpDepProtocolGuid;
  return gBS->InstallMultipleProtocolInterfaces (
                &ImageHandle,
                MpInitLibDepProtocol,
                NULL,
                &gIoMmuAbsentProtocolGuid,
                NULL,
                NULL
                );
}
