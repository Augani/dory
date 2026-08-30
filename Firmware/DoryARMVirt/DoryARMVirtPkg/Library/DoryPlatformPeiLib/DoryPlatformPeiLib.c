// SPDX-License-Identifier: BSD-2-Clause-Patent

#include <PiPei.h>
#include <Guid/EarlyPL011BaseAddress.h>
#include <Guid/FdtHob.h>
#include <Library/BaseMemoryLib.h>
#include <Library/FdtLib.h>
#include <Library/FdtSerialPortAddressLib.h>
#include <Library/HobLib.h>
#include <Library/MemoryAllocationLib.h>
#include <Library/PcdLib.h>

EFI_STATUS
EFIAPI
PlatformPeim (
  VOID
  )
{
  VOID                      *Source;
  VOID                      *Destination;
  UINTN                     FdtSize;
  UINTN                     FdtPages;
  UINT64                    *FdtHobData;
  EARLY_PL011_BASE_ADDRESS  *UartHobData;
  FDT_SERIAL_PORTS          Ports;
  EFI_STATUS                Status;

  Source = (VOID *)(UINTN)FixedPcdGet64 (PcdDeviceTreeInitialBaseAddress);
  if ((Source == NULL) || (FdtCheckHeader (Source) != 0)) {
    return EFI_INVALID_PARAMETER;
  }

  FdtSize  = FdtTotalSize (Source) + PcdGet32 (PcdDeviceTreeAllocationPadding);
  FdtPages = EFI_SIZE_TO_PAGES (FdtSize);
  Destination = AllocatePages (FdtPages);
  if (Destination == NULL) {
    return EFI_OUT_OF_RESOURCES;
  }

  if (FdtOpenInto (Source, Destination, EFI_PAGES_TO_SIZE (FdtPages)) != 0) {
    return EFI_COMPROMISED_DATA;
  }

  FdtHobData = BuildGuidHob (&gFdtHobGuid, sizeof (*FdtHobData));
  if (FdtHobData == NULL) {
    return EFI_OUT_OF_RESOURCES;
  }

  *FdtHobData = (UINTN)Destination;

  UartHobData = BuildGuidHob (&gEarlyPL011BaseAddressGuid, sizeof (*UartHobData));
  if (UartHobData == NULL) {
    return EFI_OUT_OF_RESOURCES;
  }

  ZeroMem (UartHobData, sizeof (*UartHobData));
  Status = FdtSerialGetPorts (Source, "arm,pl011", &Ports);
  if (!EFI_ERROR (Status) && (Ports.NumberOfPorts > 0)) {
    UartHobData->ConsoleAddress = Ports.BaseAddress[0];
    UartHobData->DebugAddress   = Ports.BaseAddress[0];
  }

  BuildFvHob (FixedPcdGet64 (PcdFvBaseAddress), FixedPcdGet32 (PcdFvSize));
  return EFI_SUCCESS;
}
