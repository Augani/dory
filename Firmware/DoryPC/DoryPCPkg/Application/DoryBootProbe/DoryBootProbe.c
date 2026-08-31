// SPDX-License-Identifier: BSD-2-Clause-Patent

#include <Base.h>
#include <Library/BaseLib.h>
#include <Library/IoLib.h>
#include <Uefi.h>

#define DORY_PC_PM1_CONTROL_PORT  0x0604
#define DORY_PC_SERIAL_PORT       0x03F8
#define DORY_PC_SOFT_OFF_TYPE     5

STATIC CONST CHAR8  mBootMarker[] = "DORY-PC-UEFI-BOOT\r\n";

EFI_STATUS
EFIAPI
DoryBootProbeMain (
  IN EFI_HANDLE        ImageHandle,
  IN EFI_SYSTEM_TABLE  *SystemTable
  )
{
  UINTN  Index;

  for (Index = 0; Index < sizeof (mBootMarker) - 1; Index++) {
    IoWrite8 (DORY_PC_SERIAL_PORT, mBootMarker[Index]);
  }

  IoWrite16 (
    DORY_PC_PM1_CONTROL_PORT,
    (DORY_PC_SOFT_OFF_TYPE << 10) | BIT13
    );
  CpuDeadLoop ();
  return EFI_SUCCESS;
}
