#ifndef DORY_VZMAC_SDK_INVENTORY_H
#define DORY_VZMAC_SDK_INVENTORY_H

#include <Availability.h>
#include <stdbool.h>
#include <stdint.h>

#if __has_include(<AccessoryAccess/AccessoryAccess.h>)
#define DORY_VZMAC_ACCESSORY_ACCESS_DECLARED 1
#else
#define DORY_VZMAC_ACCESSORY_ACCESS_DECLARED 0
#endif

#if __has_include(<Virtualization/VZUSBPassthroughDevice.h>) && \
    __has_include(<Virtualization/VZUSBPassthroughDeviceConfiguration.h>)
#define DORY_VZMAC_PHYSICAL_USB_DECLARED 1
#else
#define DORY_VZMAC_PHYSICAL_USB_DECLARED 0
#endif

#if __has_include(<Virtualization/VZXHCIControllerConfiguration.h>)
#define DORY_VZMAC_XHCI_CONTROLLER_DECLARED 1
#else
#define DORY_VZMAC_XHCI_CONTROLLER_DECLARED 0
#endif

#if __has_include(<Virtualization/VZUSBMassStorageDevice.h>) && \
    __has_include(<Virtualization/VZUSBMassStorageDeviceConfiguration.h>)
#define DORY_VZMAC_VIRTUAL_USB_MASS_STORAGE_DECLARED 1
#else
#define DORY_VZMAC_VIRTUAL_USB_MASS_STORAGE_DECLARED 0
#endif

#if __has_include(<Virtualization/VZCameraDeviceConfiguration.h>) || \
    __has_include(<Virtualization/VZMacCameraDeviceConfiguration.h>) || \
    __has_include(<Virtualization/VZVirtioCameraDeviceConfiguration.h>)
#define DORY_VZMAC_CAMERA_INJECTION_DECLARED 1
#else
#define DORY_VZMAC_CAMERA_INJECTION_DECLARED 0
#endif

int32_t dory_vzmac_sdk_max_allowed(void);
bool dory_vzmac_accessory_access_declared(void);
bool dory_vzmac_physical_usb_declared(void);
bool dory_vzmac_xhci_controller_declared(void);
bool dory_vzmac_virtual_usb_mass_storage_declared(void);
bool dory_vzmac_camera_injection_declared(void);

#endif
