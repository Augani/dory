// SPDX-License-Identifier: BSD-2-Clause-Patent

#include <Uefi.h>
#include <Guid/SerialPortLibVendor.h>
#include <Library/PcdLib.h>
#include <Library/PlatformBootManagerLib.h>
#include <Library/UefiBootManagerLib.h>

#define DP_NODE_LEN(Type)  { (UINT8)sizeof (Type), (UINT8)(sizeof (Type) >> 8) }

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
  // The generic UEFI rule is exactly Dory's policy: removable Block I/O first, fixed Block I/O
  // second. Persistent Boot####/BootOrder variables override this default on later boots.
  EfiBootManagerRefreshAllBootOption ();
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
