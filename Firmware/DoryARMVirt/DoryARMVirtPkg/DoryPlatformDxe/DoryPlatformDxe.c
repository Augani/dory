// SPDX-License-Identifier: BSD-2-Clause-Patent

#include <Uefi.h>
#include <Guid/NvVarStoreFormatted.h>
#include <Guid/PlatformHasDeviceTree.h>
#include <Library/UefiBootServicesTableLib.h>

EFI_STATUS
EFIAPI
DoryPlatformDxeEntryPoint (
  IN EFI_HANDLE        ImageHandle,
  IN EFI_SYSTEM_TABLE  *SystemTable
  )
{
  EFI_STATUS  Status;

  Status = gBS->InstallProtocolInterface (
                  &ImageHandle,
                  &gEdkiiNvVarStoreFormattedGuid,
                  EFI_NATIVE_INTERFACE,
                  NULL
                  );
  if (EFI_ERROR (Status)) {
    return Status;
  }

  return gBS->InstallProtocolInterface (
                &ImageHandle,
                &gEdkiiPlatformHasDeviceTreeGuid,
                EFI_NATIVE_INTERFACE,
                NULL
                );
}
