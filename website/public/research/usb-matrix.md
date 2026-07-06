# Dory USB/IP Passthrough Matrix

Date: 2026-07-04

Track 3 ships USB/IP over vsock, not XHCI emulation. The guest side uses `vhci_hcd`; the host side exports one USB/IP stream per attached device. This document is the hardware smoke matrix required before claiming USB passthrough.

## Implementation Status

- Protocol codec: implemented in `Packages/ContainerizationEngine/Sources/DoryHV/Usb/UsbipProtocol.swift`.
- Server dispatch core: implemented in `Packages/ContainerizationEngine/Sources/DoryHV/Usb/UsbipServer.swift`.
- Host discovery: implemented in `HostUsbDiscovery`; `dory-hv usb list` emits JSON USB/IP descriptors from IORegistry.
- Host transfer bridge: implemented for usbip request mapping, endpoint-zero device control through a tiny Objective-C IOUSBHost shim, and bulk/interrupt IOUSBHost pipes. Isochronous transfers remain intentionally unsupported in v1.
- Agent `usb.attach` / `usb.detach` sysfs wiring: implemented in `guest/agent/usb.go`.
- CLI attach/detach contract: implemented in `scripts/dory`, gated on `DORY_USB_AGENT_SOCK`; `usb ls` prefers `dory-hv usb list` when the helper is available.
- UI picker and persistence: implemented in `Dory/Features/Settings/UsbDevicesView.swift` and `UsbAttachmentStore`; hardware reattach is still gated on the live agent/USB smoke.

## Ground Rules

- Driverless devices should open through IOUSBHost authorization without a special entitlement.
- Devices already claimed by a macOS kernel driver need either a privileged helper or the restricted `com.apple.vm.device-access` entitlement.
- Apple-internal devices are out of scope for v1.
- Isochronous endpoints are unsupported in v1; the USB/IP server returns `EPIPE`.
- USB3 UAS storage must be treated as experimental until proven stable.

## Smoke Matrix

| Device class | Example | Host capture expectation | Guest validation | Status |
|---|---|---|---|---|
| CDC-ACM serial | USB UART adapter | Usually driverless or lightly claimed | `dmesg`, `/dev/ttyACM*`, loopback bytes | Pending hardware |
| DFU microcontroller | RP2040 / STM32 bootloader | Usually driverless | `lsusb`, `dfu-util -l`, flash sample firmware | Pending hardware |
| Android phone | adb device | May need host-side user authorization | `adb devices` inside machine | Pending hardware |
| USB flash drive | Mass storage | Usually claimed by macOS, needs helper/entitlement | `lsblk`, mount read-only first | Pending hardware |

## Manual Smoke Commands

The `--usb` readiness track is CI-skipped: it requires `DORY_USB_TEST_BUSID` and the agent socket settings, and is skipped with a clear reason when they are unset (`RUN_USB` defaults to 0). When enabled, the track first asserts the device is enumerable via `dory usb ls`, then exercises attach and detach, failing loudly on any non-zero step.

```sh
export DORY_USB_TEST_BUSID=3-2
scripts/readiness.sh --engines dory --usb
```

Expected final gate after CLI wiring:

```sh
scripts/dory usb ls
scripts/dory usb attach "$DORY_USB_TEST_BUSID" --machine dev
scripts/dory ssh dev -- lsusb
scripts/dory usb detach "$DORY_USB_TEST_BUSID" --machine dev
```

## Notes

The protocol fixture tests are grounded in the Linux kernel USB/IP protocol documentation, including the HID `USBIP_CMD_SUBMIT` examples and `USBIP_RET_UNLINK` status behavior.
