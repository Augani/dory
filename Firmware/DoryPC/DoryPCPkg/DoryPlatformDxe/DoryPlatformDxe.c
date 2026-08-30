// SPDX-License-Identifier: BSD-2-Clause-Patent

#include <Uefi.h>
#include <DoryPCFirmwareConfiguration.h>
#include <Guid/Acpi.h>
#include <Guid/SmBios.h>
#include <Library/IoLib.h>
#include <Library/PcdLib.h>
#include <Library/UefiBootServicesTableLib.h>

EFI_STATUS
EFIAPI
DoryPlatformDxeEntryPoint (
  IN EFI_HANDLE ImageHandle,
  IN EFI_SYSTEM_TABLE *SystemTable
  )
{
  EFI_STATUS Status;
  UINTN      Base;
  UINT64     Rsdp;
  UINT64     Smbios;

  Base = (UINTN)FixedPcdGet64 (PcdFirmwareConfigurationBase);
  if ((MmioRead64 (Base + DORY_PC_CONFIGURATION_MAGIC_OFFSET) != DORY_PC_CONFIGURATION_MAGIC) ||
      (MmioRead32 (Base + DORY_PC_CONFIGURATION_VERSION_OFFSET) != DORY_PC_CONFIGURATION_VERSION))
  {
    return EFI_COMPROMISED_DATA;
  }

  Rsdp   = MmioRead64 (Base + DORY_PC_CONFIGURATION_RSDP_OFFSET);
  Smbios = MmioRead64 (Base + DORY_PC_CONFIGURATION_SMBIOS_OFFSET);
  Status = gBS->InstallConfigurationTable (&gEfiAcpi20TableGuid, (VOID *)(UINTN)Rsdp);
  if (EFI_ERROR (Status)) {
    return Status;
  }
  return gBS->InstallConfigurationTable (&gEfiSmbios3TableGuid, (VOID *)(UINTN)Smbios);
}
