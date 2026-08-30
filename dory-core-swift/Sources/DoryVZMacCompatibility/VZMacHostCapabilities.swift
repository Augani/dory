import DoryVZMacSDKInventory
import Foundation

public struct DoryVZMacSDKCapabilities: Equatable, Sendable {
    public var maximumAllowed: Int32
    public var accessoryAccessDeclared: Bool
    public var physicalUSBDeclared: Bool
    public var xhciControllerDeclared: Bool
    public var virtualUSBMassStorageDeclared: Bool
    public var virtioSocketDeclared: Bool
    public var customVirtioDeclared: Bool
    public var cameraInjectionDeclared: Bool

    public init(
        maximumAllowed: Int32,
        accessoryAccessDeclared: Bool,
        physicalUSBDeclared: Bool,
        xhciControllerDeclared: Bool,
        virtualUSBMassStorageDeclared: Bool,
        virtioSocketDeclared: Bool,
        customVirtioDeclared: Bool,
        cameraInjectionDeclared: Bool
    ) {
        self.maximumAllowed = maximumAllowed
        self.accessoryAccessDeclared = accessoryAccessDeclared
        self.physicalUSBDeclared = physicalUSBDeclared
        self.xhciControllerDeclared = xhciControllerDeclared
        self.virtualUSBMassStorageDeclared = virtualUSBMassStorageDeclared
        self.virtioSocketDeclared = virtioSocketDeclared
        self.customVirtioDeclared = customVirtioDeclared
        self.cameraInjectionDeclared = cameraInjectionDeclared
    }

    public static var compilingSDK: Self {
        Self(
            maximumAllowed: dory_vzmac_sdk_max_allowed(),
            accessoryAccessDeclared: dory_vzmac_accessory_access_declared(),
            physicalUSBDeclared: dory_vzmac_physical_usb_declared(),
            xhciControllerDeclared: dory_vzmac_xhci_controller_declared(),
            virtualUSBMassStorageDeclared:
                dory_vzmac_virtual_usb_mass_storage_declared(),
            virtioSocketDeclared: dory_vzmac_virtio_socket_declared(),
            customVirtioDeclared: dory_vzmac_custom_virtio_declared(),
            cameraInjectionDeclared: dory_vzmac_camera_injection_declared()
        )
    }
}

public enum DoryVZMacPhysicalUSBPath: String, Codable, Equatable, Sendable {
    case unavailable
    case accessoryAccessPassthrough
}

public enum DoryVZMacRemovableStoragePath: String, Codable, Equatable, Sendable {
    case unavailable
    /// A disk-image attachment presented to the guest as USB storage. This is not physical USB.
    case virtualUSBMassStorageAttachment
    case accessoryAccessPhysicalPassthrough
}

public enum DoryVZMacCameraInjectionPath: String, Codable, Equatable, Sendable {
    case unavailable
    case publicVirtualizationFramework
    case guestCoreMediaIOBridge
}

public struct DoryVZMacCameraBridgeQualification: Codable, Equatable, Sendable {
    public var guestMajorVersion: Int
    public var guestMinorVersion: Int
    public var guestExtensionInstalledAndAuthorized: Bool
    public var releaseQualificationPassed: Bool

    public init(
        guestMajorVersion: Int,
        guestMinorVersion: Int,
        guestExtensionInstalledAndAuthorized: Bool,
        releaseQualificationPassed: Bool
    ) {
        self.guestMajorVersion = guestMajorVersion
        self.guestMinorVersion = guestMinorVersion
        self.guestExtensionInstalledAndAuthorized = guestExtensionInstalledAndAuthorized
        self.releaseQualificationPassed = releaseQualificationPassed
    }

    var isUsable: Bool {
        let supportsCameraExtensions = guestMajorVersion > 12
            || (guestMajorVersion == 12 && guestMinorVersion >= 3)
        return supportsCameraExtensions
            && guestExtensionInstalledAndAuthorized
            && releaseQualificationPassed
    }
}

public enum DoryVZMacHostCapabilityBlocker: String, Codable, Equatable, Sendable {
    case unsupportedHostArchitecture
    case physicalUSBRequiresMacOS27
    case compilingSDKLacksPhysicalUSB
    case virtualUSBMassStorageRequiresMacOS15
    case compilingSDKLacksVirtualUSBMassStorage
    case publicCameraInjectionUnavailable
    case guestCameraBridgeQualificationPending
}

public struct DoryVZMacHostCapabilities: Codable, Equatable, Sendable {
    public var physicalUSB: DoryVZMacPhysicalUSBPath
    public var removableStorage: DoryVZMacRemovableStoragePath
    public var cameraInjection: DoryVZMacCameraInjectionPath
    public var blockers: [DoryVZMacHostCapabilityBlocker]

    public static func resolve(
        hostArchitecture: String,
        hostMajorVersion: Int,
        sdk: DoryVZMacSDKCapabilities = .compilingSDK,
        cameraBridgeQualification: DoryVZMacCameraBridgeQualification? = nil
    ) -> Self {
        guard hostArchitecture == "arm64" else {
            return Self(
                physicalUSB: .unavailable,
                removableStorage: .unavailable,
                cameraInjection: .unavailable,
                blockers: [.unsupportedHostArchitecture]
            )
        }

        let physicalUSB: DoryVZMacPhysicalUSBPath
        var blockers: [DoryVZMacHostCapabilityBlocker] = []
        if hostMajorVersion >= 27,
           sdk.accessoryAccessDeclared,
           sdk.physicalUSBDeclared {
            physicalUSB = .accessoryAccessPassthrough
        } else {
            physicalUSB = .unavailable
            if hostMajorVersion < 27 {
                blockers.append(.physicalUSBRequiresMacOS27)
            } else {
                blockers.append(.compilingSDKLacksPhysicalUSB)
            }
        }

        // Physical passthrough and virtual removable storage are separate capabilities. Never
        // substitute a disk-image attachment for a requested arbitrary host USB device.
        let removableStorage: DoryVZMacRemovableStoragePath
        if physicalUSB == .accessoryAccessPassthrough {
            removableStorage = .accessoryAccessPhysicalPassthrough
        } else if hostMajorVersion >= 15,
                  sdk.xhciControllerDeclared,
                  sdk.virtualUSBMassStorageDeclared {
            removableStorage = .virtualUSBMassStorageAttachment
        } else {
            removableStorage = .unavailable
            if hostMajorVersion < 15 {
                blockers.append(.virtualUSBMassStorageRequiresMacOS15)
            } else {
                blockers.append(.compilingSDKLacksVirtualUSBMassStorage)
            }
        }

        let cameraInjection: DoryVZMacCameraInjectionPath
        if sdk.cameraInjectionDeclared {
            cameraInjection = .publicVirtualizationFramework
        } else if sdk.virtioSocketDeclared,
                  cameraBridgeQualification?.isUsable == true {
            cameraInjection = .guestCoreMediaIOBridge
        } else {
            cameraInjection = .unavailable
            blockers.append(.publicCameraInjectionUnavailable)
            blockers.append(.guestCameraBridgeQualificationPending)
        }
        return Self(
            physicalUSB: physicalUSB,
            removableStorage: removableStorage,
            cameraInjection: cameraInjection,
            blockers: blockers
        )
    }
}
