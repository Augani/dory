// SPDX-License-Identifier: BSD-2-Clause-Patent

#include <Uefi.h>
#include <Guid/PlatformHasDeviceTree.h>
#include <Library/UefiBootServicesTableLib.h>

EFI_STATUS
EFIAPI
DoryPlatformDxeEntryPoint (
  IN EFI_HANDLE        ImageHandle,
  IN EFI_SYSTEM_TABLE  *SystemTable
  )
{
  return gBS->InstallProtocolInterface (
                &ImageHandle,
                &gEdkiiPlatformHasDeviceTreeGuid,
                EFI_NATIVE_INTERFACE,
                NULL
                );
}
