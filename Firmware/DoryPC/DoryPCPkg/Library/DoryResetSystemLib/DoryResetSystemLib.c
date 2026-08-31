// SPDX-License-Identifier: BSD-2-Clause-Patent

#include <Base.h>
#include <Library/BaseLib.h>
#include <Library/IoLib.h>
#include <Library/ResetSystemLib.h>

#define DORY_PC_PM1_CONTROL_PORT  0x0604
#define DORY_PC_RESET_PORT        0x0CF9
#define DORY_PC_RESET_VALUE       0x06
#define DORY_PC_SOFT_OFF_TYPE     5

STATIC
VOID
RequestReset (
  VOID
  )
{
  IoWrite8 (DORY_PC_RESET_PORT, DORY_PC_RESET_VALUE);
  CpuDeadLoop ();
}

VOID
EFIAPI
ResetCold (
  VOID
  )
{
  RequestReset ();
}

VOID
EFIAPI
ResetWarm (
  VOID
  )
{
  RequestReset ();
}

VOID
EFIAPI
ResetShutdown (
  VOID
  )
{
  IoWrite16 (
    DORY_PC_PM1_CONTROL_PORT,
    (DORY_PC_SOFT_OFF_TYPE << 10) | BIT13
    );
  CpuDeadLoop ();
}

VOID
EFIAPI
ResetPlatformSpecific (
  IN UINTN  DataSize,
  IN VOID   *ResetData
  )
{
  RequestReset ();
}

VOID
EFIAPI
ResetSystem (
  IN EFI_RESET_TYPE  ResetType,
  IN EFI_STATUS      ResetStatus,
  IN UINTN           DataSize,
  IN VOID            *ResetData OPTIONAL
  )
{
  switch (ResetType) {
    case EfiResetWarm:
      ResetWarm ();
      break;
    case EfiResetCold:
      ResetCold ();
      break;
    case EfiResetShutdown:
      ResetShutdown ();
      break;
    case EfiResetPlatformSpecific:
      ResetPlatformSpecific (DataSize, ResetData);
      break;
    default:
      break;
  }
}
