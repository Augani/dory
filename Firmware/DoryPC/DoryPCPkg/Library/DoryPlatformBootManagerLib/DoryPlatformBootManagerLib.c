// SPDX-License-Identifier: BSD-2-Clause-Patent

#include <Uefi.h>
#include <DoryPCFirmwareConfiguration.h>
#include <Guid/EventGroup.h>
#include <Guid/SerialPortLibVendor.h>
#include <Guid/TtyTerm.h>
#include <IndustryStandard/Pci.h>
#include <Library/IoLib.h>
#include <Library/PcdLib.h>
#include <Library/PlatformBootManagerLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiBootManagerLib.h>
#include <Library/UefiLib.h>
#include <Protocol/PciIo.h>

#define DP_NODE_LEN(Type)  { (UINT8)sizeof (Type), (UINT8)(sizeof (Type) >> 8) }
#define DORY_PC_PM1_CONTROL_PORT  0x0604
#define DORY_PC_SERIAL_PORT       0x03F8
#define DORY_PC_SOFT_OFF_TYPE     5
#define DORY_PC_VIRTIO_VENDOR_ID  0x1AF4
#define DORY_PC_GPU_DEVICE_ID     0x1050

STATIC CONST CHAR8  mDoryBootMarker[] = "DORY-PC-UEFI-BOOT\r\n";
STATIC CONST CHAR8  mDoryConsoleMissingMarker[] = "DORY-PC-UEFI-CONSOLE-MISSING\r\n";

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
  CONST CHAR8  *Marker;
  UINTN  Index;

  // External EFI applications are permitted to call ConOut unconditionally. Keep the raw UART
  // marker for host-side qualification, but only publish success after the console splitter has
  // installed a callable Simple Text Output protocol in the system table.
  Marker = mDoryBootMarker;
  if ((gST->ConOut == NULL) || (gST->ConOut->OutputString == NULL)) {
    Marker = mDoryConsoleMissingMarker;
  }

  for (Index = 0; Marker[Index] != '\0'; Index++) {
    IoWrite8 (DORY_PC_SERIAL_PORT, Marker[Index]);
  }

  IoWrite16 (
    DORY_PC_PM1_CONTROL_PORT,
    (DORY_PC_SOFT_OFF_TYPE << 10) | BIT13
    );
  CpuDeadLoop ();
}

#pragma pack (1)
typedef struct {
  VENDOR_DEVICE_PATH          SerialDxe;
  UART_DEVICE_PATH            Uart;
  VENDOR_DEFINED_DEVICE_PATH  TerminalType;
  EFI_DEVICE_PATH_PROTOCOL    End;
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
    { MESSAGING_DEVICE_PATH, MSG_VENDOR_DP, DP_NODE_LEN (VENDOR_DEFINED_DEVICE_PATH) },
    EFI_TTY_TERM_GUID
  },
  {
    END_DEVICE_PATH_TYPE,
    END_ENTIRE_DEVICE_PATH_SUBTYPE,
    DP_NODE_LEN (EFI_DEVICE_PATH_PROTOCOL)
  }
};

STATIC
VOID
DoryConnectDisplayConsole (
  VOID
  )
{
  EFI_HANDLE           *Handles;
  UINTN                HandleCount;
  UINTN                Index;
  EFI_STATUS           Status;
  EFI_PCI_IO_PROTOCOL  *PciIo;
  PCI_TYPE00           Pci;

  Handles = NULL;
  Status  = gBS->LocateHandleBuffer (
                   ByProtocol,
                   &gEfiPciIoProtocolGuid,
                   NULL,
                   &HandleCount,
                   &Handles
                   );
  if (EFI_ERROR (Status)) {
    return;
  }

  for (Index = 0; Index < HandleCount; Index++) {
    Status = gBS->HandleProtocol (
                    Handles[Index],
                    &gEfiPciIoProtocolGuid,
                    (VOID **)&PciIo
                    );
    if (EFI_ERROR (Status)) {
      continue;
    }

    Status = PciIo->Pci.Read (
                          PciIo,
                          EfiPciIoWidthUint32,
                          0,
                          sizeof (Pci) / sizeof (UINT32),
                          &Pci
                          );
    if (EFI_ERROR (Status) ||
        (Pci.Hdr.VendorId != DORY_PC_VIRTIO_VENDOR_ID) ||
        (Pci.Hdr.DeviceId != DORY_PC_GPU_DEVICE_ID) ||
        !IS_PCI_DISPLAY (&Pci))
    {
      continue;
    }

    // VirtioGpuDxe creates its GOP child only when the display controller is connected as video.
    // Register that GOP as an additional ConOut while retaining serial as the recovery console.
    if (!EFI_ERROR (EfiBootManagerConnectVideoController (Handles[Index]))) {
      break;
    }
  }

  gBS->FreePool (Handles);
}

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

  EfiBootManagerUpdateConsoleVariable (ConIn, (EFI_DEVICE_PATH_PROTOCOL *)&mSerialConsole, NULL);
  EfiBootManagerUpdateConsoleVariable (ConOut, (EFI_DEVICE_PATH_PROTOCOL *)&mSerialConsole, NULL);
  EfiBootManagerUpdateConsoleVariable (ErrOut, (EFI_DEVICE_PATH_PROTOCOL *)&mSerialConsole, NULL);
}
VOID
EFIAPI
PlatformBootManagerAfterConsole (
  VOID
  )
{
  // Some console bus drivers only publish their child text protocols while the recursive device
  // connection pass runs. Rescan those protocols afterwards so the standard console variables
  // and EFI_SYSTEM_TABLE pointers describe the devices that now exist.
  EfiBootManagerConnectAll ();
  // PCI I/O handles do not exist until the recursive connection pass enumerates the root bridge.
  // Connect the display here so VirtioGpuDxe can create its GOP child before the console splitter
  // resolves ConOut and publishes it through EFI_SYSTEM_TABLE.
  DoryConnectDisplayConsole ();
  EfiBootManagerUpdateConsoleVariable (ConIn, (EFI_DEVICE_PATH_PROTOCOL *)&mSerialConsole, NULL);
  EfiBootManagerUpdateConsoleVariable (ConOut, (EFI_DEVICE_PATH_PROTOCOL *)&mSerialConsole, NULL);
  EfiBootManagerUpdateConsoleVariable (ErrOut, (EFI_DEVICE_PATH_PROTOCOL *)&mSerialConsole, NULL);
  EfiBootManagerConnectAllDefaultConsoles ();
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
