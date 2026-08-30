#include "DoryVZMacSDKInventory.h"

int32_t dory_vzmac_sdk_max_allowed(void) {
    return __MAC_OS_X_VERSION_MAX_ALLOWED;
}

bool dory_vzmac_accessory_access_declared(void) {
    return DORY_VZMAC_ACCESSORY_ACCESS_DECLARED;
}

bool dory_vzmac_physical_usb_declared(void) {
    return DORY_VZMAC_PHYSICAL_USB_DECLARED;
}

bool dory_vzmac_xhci_controller_declared(void) {
    return DORY_VZMAC_XHCI_CONTROLLER_DECLARED;
}

bool dory_vzmac_virtual_usb_mass_storage_declared(void) {
    return DORY_VZMAC_VIRTUAL_USB_MASS_STORAGE_DECLARED;
}

bool dory_vzmac_virtio_socket_declared(void) {
    return DORY_VZMAC_VIRTIO_SOCKET_DECLARED;
}

bool dory_vzmac_custom_virtio_declared(void) {
    return DORY_VZMAC_CUSTOM_VIRTIO_DECLARED;
}

bool dory_vzmac_camera_injection_declared(void) {
    return DORY_VZMAC_CAMERA_INJECTION_DECLARED;
}
