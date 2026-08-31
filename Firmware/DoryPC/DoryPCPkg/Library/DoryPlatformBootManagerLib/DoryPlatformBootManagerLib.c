// SPDX-License-Identifier: BSD-2-Clause-Patent

#include <Uefi.h>
#include <DoryPCFirmwareConfiguration.h>
#include <Guid/EventGroup.h>
#include <Guid/SerialPortLibVendor.h>
#include <Library/IoLib.h>
#include <Library/PcdLib.h>
#include <Library/PlatformBootManagerLib.h>
#include <Library/UefiBootManagerLib.h>
#include <Library/UefiLib.h>

#define DP_NODE_LEN(Type)  { (UINT8)sizeof (Type), (UINT8)(sizeof (Type) >> 8) }
#define DORY_PC_PM1_CONTROL_PORT  0x0604
#define DORY_PC_SERIAL_PORT       0x03F8
#define DORY_PC_SOFT_OFF_TYPE     5

STATIC CONST CHAR8  mDoryBootMarker[] = "DORY-PC-UEFI-BOOT\r\n";

STATIC
BOOLEAN
DoryBootProbeRequested (
  VOID
  )
{
  UINTN  Base;

  Base = (UINTN)FixedPcdGet64 (PcdFirmwareConfigurationBase);
  return (MmioRead64 (Base + DORY_PC_CONFIGURATION_MAGIC_OFFSET) == DORY_PC_CONFIGURATION_MAGIC) &&
         (MmioRead32 (Base + DORY_PC_CONFIGURATION_VERSION_OFFSET) == DORY_PC_CONFIGURATION_VERSION) &&
         (MmioRead32 (Base + DORY_PC_CONFIGURATION_HEADER_SIZE_OFFSET) >= DORY_PC_CONFIGURATION_HEADER_SIZE) &&
         ((MmioRead32 (Base + DORY_PC_CONFIGURATION_FLAGS_OFFSET) &
           DORY_PC_CONFIGURATION_FLAG_BOOT_PROBE) != 0);
}

STATIC
VOID
DoryRunBootProbe (
  VOID
  )
{
  UINTN  Index;

  for (Index = 0; Index < sizeof (mDoryBootMarker) - 1; Index++) {
    IoWrite8 (DORY_PC_SERIAL_PORT, mDoryBootMarker[Index]);
  }

  IoWrite16 (
    DORY_PC_PM1_CONTROL_PORT,
    (DORY_PC_SOFT_OFF_TYPE << 10) | BIT13
    );
  CpuDeadLoop ();
}

#pragma pack (1)
typedef struct {
  VENDOR_DEVICE_PATH        SerialDxe;
  UART_DEVICE_PATH          Uart;
  EFI_DEVICE_PATH_PROTOCOL  End;
} DORY_SERIAL_CONSOLE;
#pragma pack ()

STATIC DORY_SERIAL_CONSOLE mSerialConsole = {
  {
    { HARDWARE_DEVICE_PATH, HW_VENDOR_DP, DP_NODE_LEN (VENDOR_DEVICE_PATH) },
    EDKII_SERIAL_PORT_LIB_VENDOR_GUID
  },
  {
    { MESSAGING_DEVICE_PATH, MSG_UART_DP, DP_NODE_LEN (UART_DEVICE_PATH) },
    0,
    FixedPcdGet64 (PcdUartDefaultBaudRate),
    FixedPcdGet8 (PcdUartDefaultDataBits),
    FixedPcdGet8 (PcdUartDefaultParity),
    FixedPcdGet8 (PcdUartDefaultStopBits)
  },
  {
    END_DEVICE_PATH_TYPE,
    END_ENTIRE_DEVICE_PATH_SUBTYPE,
    DP_NODE_LEN (EFI_DEVICE_PATH_PROTOCOL)
  }
};

VOID
EFIAPI
PlatformBootManagerBeforeConsole (
  VOID
  )
{
  // External boot images must not be dispatched until DXE construction is complete. SecurityStub
  // intentionally rejects non-FV images before this event, even when Secure Boot is disabled.
  EfiEventGroupSignal (&gEfiEndOfDxeEventGroupGuid);
  EfiBootManagerDispatchDeferredImages ();

  EfiBootManagerUpdateConsoleVariable (ConOut, (EFI_DEVICE_PATH_PROTOCOL *)&mSerialConsole, NULL);
  EfiBootManagerUpdateConsoleVariable (ErrOut, (EFI_DEVICE_PATH_PROTOCOL *)&mSerialConsole, NULL);
}
VOID
EFIAPI
PlatformBootManagerAfterConsole (
  VOID
  )
{
  EfiBootManagerConnectAll ();
  // Refresh guest-created file-specific options while retaining the host-published DoryPC
  // physical-device fallbacks and their launch-plan order in BootOrder.
  EfiBootManagerRefreshAllBootOption ();

  // The production image contains a dormant BDS probe so the exact shipped firmware can be
  // qualified under every execution tier. The immutable flag defaults to zero, and the hook does
  // not create a boot option or touch persistent NVRAM during a normal VM launch.
  if (DoryBootProbeRequested ()) {
    DoryRunBootProbe ();
  }
}

VOID
EFIAPI
PlatformBootManagerWaitCallback (
  UINT16 TimeoutRemain
  )
{
  (VOID)TimeoutRemain;
}

VOID
EFIAPI
PlatformBootManagerUnableToBoot (
  VOID
  )
{
}
