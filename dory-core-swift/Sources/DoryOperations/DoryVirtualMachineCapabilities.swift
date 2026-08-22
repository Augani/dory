/// The operating-system family installed in a virtual machine.
public enum DoryGuestFamily: String, Codable, Sendable, CaseIterable, Hashable {
    case linux
    case windows
    case macOS = "macos"
}

/// The instruction-set architecture executed by the guest kernel.
public enum DoryGuestArchitecture: String, Codable, Sendable, CaseIterable, Hashable {
    case arm64
    case x86_64
}

public struct DoryGuestPlatform: Codable, Sendable, Equatable, Hashable {
    public var family: DoryGuestFamily
    public var architecture: DoryGuestArchitecture

    public init(family: DoryGuestFamily, architecture: DoryGuestArchitecture) {
        self.family = family
        self.architecture = architecture
    }
}

/// The format presented to the virtual machine's firmware or boot loader.
public enum DoryBootMediaKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// One immutable Linux kernel image used by the existing direct-kernel launch path. This is
    /// distinct from the portable kernel+initrd+root-device bundle created after an EFI install.
    case linuxKernel = "linux-kernel"
    case installerISO = "installer-iso"
    case virtualDisk = "virtual-disk"
    case installedLinuxBootBundle = "installed-linux-boot-bundle"
    case macOSRestoreImage = "macos-restore-image"
}

/// Where boot media originates. This is part of capability negotiation because some operating
/// systems may be virtualized but cannot be redistributed as a Dory-managed image.
public enum DoryBootMediaSource: String, Codable, Sendable, CaseIterable, Hashable {
    case bundledByDory = "dory-bundled"
    case vendorDownload = "vendor-download"
    case userProvided = "user-provided"
}

/// Resolver identity for mutable media. A revision is stable across planning but changes whenever
/// the daemon publishes a new disk state; it is not a caller assertion of disk contents.
public struct DoryMutableBootMediaProvenanceReference: Codable, Sendable, Equatable, Hashable {
    public var repositoryIdentity: String
    public var mediaIdentity: String
    public var revision: UInt64

    public init(repositoryIdentity: String, mediaIdentity: String, revision: UInt64) {
        self.repositoryIdentity = repositoryIdentity
        self.mediaIdentity = mediaIdentity
        self.revision = revision
    }
}

public struct DoryBootMedia: Codable, Sendable, Equatable, Hashable {
    public var kind: DoryBootMediaKind
    public var source: DoryBootMediaSource
    /// SHA-256 of the selected artifact, when content-addressed identity has been resolved.
    public var artifactSHA256: String?
    /// Resolver-owned identity requested for mutable virtual disks. Authority comes from the
    /// daemon's trusted provenance receipt, not this wire reference.
    public var mutableProvenance: DoryMutableBootMediaProvenanceReference?

    public init(
        kind: DoryBootMediaKind,
        source: DoryBootMediaSource,
        artifactSHA256: String? = nil,
        mutableProvenance: DoryMutableBootMediaProvenanceReference? = nil
    ) {
        self.kind = kind
        self.source = source
        self.artifactSHA256 = artifactSHA256
        self.mutableProvenance = mutableProvenance
    }
}

/// A stable backend identifier shared by the daemon, app, and external API.
public enum DoryVirtualizationBackendIdentity: String, Codable, Sendable, CaseIterable, Hashable {
    /// Dory's native Hypervisor.framework virtual machine monitor.
    case doryHypervisor = "dory-hypervisor"
    /// Apple's higher-level Virtualization.framework runtime.
    case appleVirtualizationFramework = "apple-virtualization-framework"
    /// QEMU using Hypervisor.framework for same-architecture CPU virtualization.
    case qemuHypervisorFramework = "qemu-hvf"
}

/// The graphics guarantee made to the guest. Higher cases are not implied by lower cases; callers
/// must negotiate the exact level they require.
public enum DoryGraphicsAccelerationLevel: String, Codable, Sendable, CaseIterable, Hashable {
    case none
    case software
    /// The host compositor presents a guest framebuffer efficiently. This does not promise a
    /// guest-visible 3D API or driver.
    case hostAcceleratedDisplay = "host-accelerated-display"
    /// A qualified guest driver exposes hardware-backed 3D APIs inside the virtual machine.
    case hardwareAccelerated3D = "hardware-accelerated-3d"
}

/// Exact virtual-device contract requested by a definition or API client. Features are booleans
/// rather than inferred from "desktop" so a backend cannot silently omit hardware or guest tools.
public enum DoryVirtualMachineNetworkAttachmentMode: String, Codable, Sendable, CaseIterable, Hashable {
    case disconnected
    case sharedNAT = "shared-nat"
    case bridged
    case isolated
}

/// Exact guest-visible identity for the primary network function.
///
/// The value is persisted in the resolved device contract rather than inferred by a backend, so
/// changing adapters cannot silently change the guest's interface identity or effective MTU.
/// Historical plans decode this value as `nil` and retain their adapter-specific ABI.
public struct DoryVirtualMachineNetworkInterfaceCapabilityRequest:
    Codable, Sendable, Equatable, Hashable
{
    public static let minimumMTU: UInt16 = 1_280
    public static let maximumMTU: UInt16 = 9_000
    public static let defaultMTU: UInt16 = 1_280

    public var id: String
    public var macAddress: String
    public var maximumTransmissionUnit: UInt16

    public init(
        id: String = "nic0",
        macAddress: String,
        maximumTransmissionUnit: UInt16 = Self.defaultMTU
    ) {
        self.id = id
        self.macAddress = macAddress.lowercased()
        self.maximumTransmissionUnit = maximumTransmissionUnit
    }

    public var macAddressOctets: [UInt8]? {
        let components = macAddress.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 6 else { return nil }
        let octets = components.compactMap { component -> UInt8? in
            guard component.utf8.count == 2 else { return nil }
            return UInt8(component, radix: 16)
        }
        return octets.count == 6 ? octets : nil
    }

    public var isValid: Bool {
        guard id == "nic0",
              macAddress == macAddress.lowercased(),
              let octets = macAddressOctets,
              (Self.minimumMTU...Self.maximumMTU).contains(maximumTransmissionUnit) else {
            return false
        }
        return octets[0] & 0x01 == 0
            && octets[0] & 0x02 == 0x02
            && octets.contains(where: { $0 != 0 })
            && octets.contains(where: { $0 != 0xFF })
    }

    /// Derives a stable locally administered unicast address without making a cryptographic trust
    /// claim. The same identity is consumed by every backend and by gvproxy's exact DHCP lease.
    public static func stable(machineID: String) -> Self {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in machineID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        var octets = (0..<6).map { UInt8(truncatingIfNeeded: hash >> UInt64($0 * 8)) }
        octets[0] = (octets[0] | 0x02) & 0xFE
        let mac = octets.map { String(format: "%02x", $0) }.joined(separator: ":")
        return Self(macAddress: mac)
    }
}

public struct DoryVirtualMachineDisplayCapabilityRequest: Codable, Sendable, Equatable, Hashable {
    public static let maximumDimensionPixels: UInt32 = 16_384

    public var widthPixels: UInt32
    public var heightPixels: UInt32
    public var backingScaleFactor: UInt8
    public var guestUIScaleFactor: UInt8

    public init(
        widthPixels: UInt32,
        heightPixels: UInt32,
        backingScaleFactor: UInt8 = 2,
        guestUIScaleFactor: UInt8 = 2
    ) {
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.backingScaleFactor = backingScaleFactor
        self.guestUIScaleFactor = guestUIScaleFactor
    }

    public var isValid: Bool {
        (1...Self.maximumDimensionPixels).contains(widthPixels)
            && (1...Self.maximumDimensionPixels).contains(heightPixels)
            && (1...4).contains(backingScaleFactor)
            && (1...2).contains(guestUIScaleFactor)
    }

    private enum CodingKeys: String, CodingKey {
        case widthPixels
        case heightPixels
        case backingScaleFactor
        case guestUIScaleFactor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        widthPixels = try container.decode(UInt32.self, forKey: .widthPixels)
        heightPixels = try container.decode(UInt32.self, forKey: .heightPixels)
        backingScaleFactor = try container.decodeIfPresent(
            UInt8.self,
            forKey: .backingScaleFactor
        ) ?? 2
        guestUIScaleFactor = try container.decodeIfPresent(
            UInt8.self,
            forKey: .guestUIScaleFactor
        ) ?? 2
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(widthPixels, forKey: .widthPixels)
        try container.encode(heightPixels, forKey: .heightPixels)
        try container.encode(backingScaleFactor, forKey: .backingScaleFactor)
        try container.encode(guestUIScaleFactor, forKey: .guestUIScaleFactor)
    }
}

public struct DoryVirtualMachineDeviceCapabilityRequest: Codable, Sendable, Equatable, Hashable {
    public var networkAttachment: DoryVirtualMachineNetworkAttachmentMode
    /// `nil` is compatibility-only for resolved plans authored before stable NIC identity was
    /// introduced. New production planning always supplies this exact contract.
    public var networkInterface: DoryVirtualMachineNetworkInterfaceCapabilityRequest?
    /// Exact initial display geometry. `nil` is retained only for historical capability records
    /// that predate display binding; newly planned desktop workspaces always carry this value.
    public var display: DoryVirtualMachineDisplayCapabilityRequest?
    public var audioInput: Bool
    public var audioOutput: Bool
    public var keyboard: Bool
    public var pointer: Bool
    public var directorySharing: Bool
    public var clipboard: Bool
    /// Exact per-content clipboard boundary selected by native planning. `nil` is retained only
    /// for historical capability records that predate directional clipboard binding.
    public var clipboardPolicy: DoryVMClipboardPolicy?
    public var clockSynchronization: Bool
    public var dynamicDisplay: Bool
    public var gracefulShutdown: Bool
    /// Exact authorization to expose the host's installed Intel Linux translation runtime.
    public var intelApplicationTranslation: Bool
    /// Exact permission for user-approved removable USB hotplug. Host bus identifiers are
    /// deliberately excluded because they are ephemeral runtime selections.
    public var removableUSBHotplug: Bool

    public init(
        networkAttachment: DoryVirtualMachineNetworkAttachmentMode = .sharedNAT,
        networkInterface: DoryVirtualMachineNetworkInterfaceCapabilityRequest? = nil,
        display: DoryVirtualMachineDisplayCapabilityRequest? = nil,
        audioInput: Bool = false,
        audioOutput: Bool = false,
        keyboard: Bool = false,
        pointer: Bool = false,
        directorySharing: Bool = false,
        clipboard: Bool = false,
        clipboardPolicy: DoryVMClipboardPolicy? = nil,
        clockSynchronization: Bool = false,
        dynamicDisplay: Bool = false,
        gracefulShutdown: Bool = false,
        intelApplicationTranslation: Bool = false,
        removableUSBHotplug: Bool = false
    ) {
        self.networkAttachment = networkAttachment
        self.networkInterface = networkInterface
        self.display = display
        self.audioInput = audioInput
        self.audioOutput = audioOutput
        self.keyboard = keyboard
        self.pointer = pointer
        self.directorySharing = directorySharing
        self.clipboard = clipboard
        self.clipboardPolicy = clipboardPolicy
        self.clockSynchronization = clockSynchronization
        self.dynamicDisplay = dynamicDisplay
        self.gracefulShutdown = gracefulShutdown
        self.intelApplicationTranslation = intelApplicationTranslation
        self.removableUSBHotplug = removableUSBHotplug
    }

    private enum CodingKeys: String, CodingKey {
        case networkAttachment
        case networkInterface
        case display
        case audioInput
        case audioOutput
        case keyboard
        case pointer
        case directorySharing
        case clipboard
        case clipboardPolicy
        case clockSynchronization
        case dynamicDisplay
        case gracefulShutdown
        case intelApplicationTranslation
        case removableUSBHotplug
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        networkAttachment = try container.decode(
            DoryVirtualMachineNetworkAttachmentMode.self,
            forKey: .networkAttachment
        )
        networkInterface = try container.decodeIfPresent(
            DoryVirtualMachineNetworkInterfaceCapabilityRequest.self,
            forKey: .networkInterface
        )
        display = try container.decodeIfPresent(
            DoryVirtualMachineDisplayCapabilityRequest.self,
            forKey: .display
        )
        audioInput = try container.decode(Bool.self, forKey: .audioInput)
        audioOutput = try container.decode(Bool.self, forKey: .audioOutput)
        keyboard = try container.decode(Bool.self, forKey: .keyboard)
        pointer = try container.decode(Bool.self, forKey: .pointer)
        directorySharing = try container.decode(Bool.self, forKey: .directorySharing)
        clipboard = try container.decode(Bool.self, forKey: .clipboard)
        clipboardPolicy = try container.decodeIfPresent(
            DoryVMClipboardPolicy.self,
            forKey: .clipboardPolicy
        )
        clockSynchronization = try container.decode(Bool.self, forKey: .clockSynchronization)
        dynamicDisplay = try container.decode(Bool.self, forKey: .dynamicDisplay)
        gracefulShutdown = try container.decode(Bool.self, forKey: .gracefulShutdown)
        intelApplicationTranslation = try container.decodeIfPresent(
            Bool.self,
            forKey: .intelApplicationTranslation
        ) ?? false
        removableUSBHotplug = try container.decodeIfPresent(
            Bool.self,
            forKey: .removableUSBHotplug
        ) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(networkAttachment, forKey: .networkAttachment)
        try container.encodeIfPresent(networkInterface, forKey: .networkInterface)
        try container.encodeIfPresent(display, forKey: .display)
        try container.encode(audioInput, forKey: .audioInput)
        try container.encode(audioOutput, forKey: .audioOutput)
        try container.encode(keyboard, forKey: .keyboard)
        try container.encode(pointer, forKey: .pointer)
        try container.encode(directorySharing, forKey: .directorySharing)
        try container.encode(clipboard, forKey: .clipboard)
        try container.encodeIfPresent(clipboardPolicy, forKey: .clipboardPolicy)
        try container.encode(clockSynchronization, forKey: .clockSynchronization)
        try container.encode(dynamicDisplay, forKey: .dynamicDisplay)
        try container.encode(gracefulShutdown, forKey: .gracefulShutdown)
        if intelApplicationTranslation {
            try container.encode(true, forKey: .intelApplicationTranslation)
        }
        if removableUSBHotplug {
            try container.encode(true, forKey: .removableUSBHotplug)
        }
    }

    /// Compares the device ABI covered by a signed runtime qualification.
    ///
    /// A qualification record binds the NIC identifier and MTU, while the resolved machine plan
    /// owns the per-machine locally administered MAC. This prevents a catalog from having to
    /// enumerate every workspace identity without weakening the plan's exact MAC binding.
    public func matchesRuntimeQualificationContract(
        _ other: DoryVirtualMachineDeviceCapabilityRequest
    ) -> Bool {
        var lhs = self
        var rhs = other
        let lhsNetwork = lhs.networkInterface
        let rhsNetwork = rhs.networkInterface
        lhs.networkInterface = nil
        rhs.networkInterface = nil
        guard lhs == rhs else { return false }
        switch (lhsNetwork, rhsNetwork) {
        case (nil, nil):
            return true
        case let (.some(lhs), .some(rhs)):
            return lhs.isValid
                && rhs.isValid
                && lhs.id == rhs.id
                && lhs.maximumTransmissionUnit == rhs.maximumTransmissionUnit
        default:
            return false
        }
    }

    /// The smallest currently implemented cross-backend device contract.
    public static let minimumBootable = DoryVirtualMachineDeviceCapabilityRequest()
}

/// Product maturity is independent of whether the required host component is installed.
public enum DoryCapabilitySupportTier: String, Codable, Sendable, CaseIterable, Hashable {
    case supported
    case experimental
    case unsupported
}

public enum DoryCapabilityAvailabilityState: String, Codable, Sendable, CaseIterable, Hashable {
    case available
    case unavailable
}

public enum DoryCapabilityReasonCode: String, Codable, Sendable, CaseIterable, Hashable {
    case hostOperatingSystemUnsupported = "host-os-unsupported"
    case guestArchitectureRequiresEmulation = "guest-architecture-requires-emulation"
    case backendDoesNotSupportGuest = "backend-does-not-support-guest"
    case bootMediaDoesNotSupportGuest = "boot-media-does-not-support-guest"
    case bootMediaDoesNotSupportBackend = "boot-media-does-not-support-backend"
    case guestMediaRedistributionUnavailable = "guest-media-redistribution-unavailable"
    case graphicsModeUnsupported = "graphics-mode-unsupported"
    case windows3DAccelerationUnsupported = "windows-3d-acceleration-unsupported"
    case metalUnavailable = "metal-unavailable"
    case acceleratedRendererUnavailable = "accelerated-renderer-unavailable"
    case bootMediaArtifactDigestUnavailable = "boot-media-artifact-digest-unavailable"
    case bootMediaArtifactDigestInvalid = "boot-media-artifact-digest-invalid"
    case mutableBootMediaProvenanceUnavailable = "mutable-boot-media-provenance-unavailable"
    case mutableBootMediaProvenanceInvalid = "mutable-boot-media-provenance-invalid"
    case trustedMutableBootMediaProvenanceUnavailable = "trusted-mutable-boot-media-provenance-unavailable"
    case mutableBootMediaProvenanceMismatch = "mutable-boot-media-provenance-mismatch"
    case trustedBootMediaInspectionUnavailable = "trusted-boot-media-inspection-unavailable"
    case bootMediaInspectionEvidenceInvalid = "boot-media-inspection-evidence-invalid"
    case bootMediaArtifactInspectionMismatch = "boot-media-artifact-inspection-mismatch"
    case bootMediaKindInspectionMismatch = "boot-media-kind-inspection-mismatch"
    case bootMediaGuestInspectionMismatch = "boot-media-guest-inspection-mismatch"
    case bootMediaArchitectureInspectionMismatch = "boot-media-architecture-inspection-mismatch"
    case bootMediaNotEFIBootable = "boot-media-not-efi-bootable"
    case macOSRestoreBuildIdentityUnavailable = "macos-restore-build-identity-unavailable"
    case macOSRestoreHardwareModelIncompatible = "macos-restore-hardware-model-incompatible"
    case macOSRestoreAuxiliaryStorageIncompatible = "macos-restore-auxiliary-storage-incompatible"
    case guestImageArtifactDigestUnavailable = "guest-image-artifact-digest-unavailable"
    case trustedGuestImageGraphicsQualificationUnavailable = "trusted-guest-image-graphics-qualification-unavailable"
    case guestImageArtifactDigestInvalid = "guest-image-artifact-digest-invalid"
    case guestImageQualificationManifestIdentityInvalid = "guest-image-qualification-manifest-identity-invalid"
    case guestImageQualificationAuditEvidenceInvalid = "guest-image-qualification-audit-evidence-invalid"
    case guestImageArtifactQualificationMismatch = "guest-image-artifact-qualification-mismatch"
    case linuxVirtioGPUKernelDeviceUnqualified = "linux-virtio-gpu-kernel-device-unqualified"
    case linuxVenusVulkanRuntimeUnqualified = "linux-venus-vulkan-runtime-unqualified"
    case virtualizationFrameworkUnavailable = "virtualization-framework-unavailable"
    case hypervisorFrameworkUnavailable = "hypervisor-framework-unavailable"
    case backendComponentUnavailable = "backend-component-unavailable"
    case backendComponentUnqualified = "backend-component-unqualified"
    case windowsUEFIFirmwareUnavailable = "windows-uefi-firmware-unavailable"
    case windowsSecureBootUnavailable = "windows-secure-boot-unavailable"
    case windowsSBSADeviceModelUnavailable = "windows-sbsa-device-model-unavailable"
    case virtualTPM20Unavailable = "virtual-tpm-2-unavailable"
    case windowsStorageDriverUnavailable = "windows-storage-driver-unavailable"
    case windowsNetworkDriverUnavailable = "windows-network-driver-unavailable"
    case windowsDisplayDriverUnavailable = "windows-display-driver-unavailable"
    case windowsInputDriverUnavailable = "windows-input-driver-unavailable"
    case macOSGuestVirtualizationUnavailable = "macos-guest-virtualization-unavailable"
    case macOSRestoreImageUnsupported = "macos-restore-image-unsupported"
    case networkAttachmentUnsupported = "network-attachment-unsupported"
    case audioInputUnsupported = "audio-input-unsupported"
    case audioOutputUnsupported = "audio-output-unsupported"
    case keyboardInputUnsupported = "keyboard-input-unsupported"
    case pointerInputUnsupported = "pointer-input-unsupported"
    case directorySharingUnsupported = "directory-sharing-unsupported"
    case clipboardIntegrationUnsupported = "clipboard-integration-unsupported"
    case clipboardPolicyInvalid = "clipboard-policy-invalid"
    case clipboardFileTransferUnsupported = "clipboard-file-transfer-unsupported"
    case clockSynchronizationUnsupported = "clock-synchronization-unsupported"
    case dynamicDisplayUnsupported = "dynamic-display-unsupported"
    case gracefulShutdownUnsupported = "graceful-shutdown-unsupported"
    case intelApplicationTranslationUnavailable = "intel-application-translation-unavailable"
    case removableUSBHotplugUnsupported = "removable-usb-hotplug-unsupported"
    case runtimeQualificationUnavailable = "runtime-qualification-unavailable"
    case runtimeQualificationEvidenceInvalid = "runtime-qualification-evidence-invalid"
    case runtimeQualificationRequestMismatch = "runtime-qualification-request-mismatch"
    case runtimeQualificationHostMismatch = "runtime-qualification-host-mismatch"
    case backendSupportIsExperimental = "backend-support-is-experimental"
    case windowsSupportIsExperimental = "windows-support-is-experimental"
}

public struct DoryCapabilityReason: Codable, Sendable, Equatable, Hashable {
    public var code: DoryCapabilityReasonCode
    public var message: String

    public init(code: DoryCapabilityReasonCode, message: String) {
        self.code = code
        self.message = message
    }
}

public struct DoryCapabilityAvailability: Codable, Sendable, Equatable, Hashable {
    public var supportTier: DoryCapabilitySupportTier
    public var state: DoryCapabilityAvailabilityState
    public var reason: DoryCapabilityReason?

    public var isUsable: Bool {
        supportTier != .unsupported && state == .available
    }

    public init(
        supportTier: DoryCapabilitySupportTier,
        state: DoryCapabilityAvailabilityState,
        reason: DoryCapabilityReason? = nil
    ) {
        self.supportTier = supportTier
        self.state = state
        self.reason = reason
    }
}

/// Driver qualification is explicit so the presence of a QEMU executable alone can never make a
/// Windows VM appear runnable. Each fact represents a tested ARM64 guest driver, not merely a file.
public struct DoryWindowsGuestDriverFacts: Codable, Sendable, Equatable, Hashable {
    public var storageAvailable: Bool
    public var networkAvailable: Bool
    public var displayAvailable: Bool
    public var inputAvailable: Bool

    public init(
        storageAvailable: Bool,
        networkAvailable: Bool,
        displayAvailable: Bool,
        inputAvailable: Bool
    ) {
        self.storageAvailable = storageAvailable
        self.networkAvailable = networkAvailable
        self.displayAvailable = displayAvailable
        self.inputAvailable = inputAvailable
    }
}

/// Non-secret evidence persisted with a plan so the daemon can re-resolve and revalidate the exact
/// signed manifest that authorized an artifact. It is audit evidence, never a trust decision.
public struct DorySignedArtifactQualificationEvidence: Codable, Sendable, Equatable, Hashable {
    public var manifestIdentity: String
    public var artifactSHA256: String
    public var manifestSHA256: String
    public var signingKeyID: String
    public var manifestFormatVersion: UInt16

    public init(
        manifestIdentity: String,
        artifactSHA256: String,
        manifestSHA256: String,
        signingKeyID: String,
        manifestFormatVersion: UInt16
    ) {
        self.manifestIdentity = manifestIdentity
        self.artifactSHA256 = artifactSHA256
        self.manifestSHA256 = manifestSHA256
        self.signingKeyID = signingKeyID
        self.manifestFormatVersion = manifestFormatVersion
    }
}

/// Daemon inspection receipt for arbitrary boot media. User-provided ISOs do not need a Dory
/// signature; the receipt pins the inspected bytes and deterministic inspector report instead.
/// Catalog media may additionally retain its signed manifest reference.
public struct DoryBootMediaInspectionAuditEvidence: Codable, Sendable, Equatable, Hashable {
    public var inspectionIdentity: String
    public var artifactSHA256: String
    public var inspectionReportSHA256: String
    public var inspectorID: String
    public var inspectorVersion: UInt16
    public var catalogManifestEvidence: DorySignedArtifactQualificationEvidence?

    public init(
        inspectionIdentity: String,
        artifactSHA256: String,
        inspectionReportSHA256: String,
        inspectorID: String,
        inspectorVersion: UInt16,
        catalogManifestEvidence: DorySignedArtifactQualificationEvidence? = nil
    ) {
        self.inspectionIdentity = inspectionIdentity
        self.artifactSHA256 = artifactSHA256
        self.inspectionReportSHA256 = inspectionReportSHA256
        self.inspectorID = inspectorID
        self.inspectorVersion = inspectorVersion
        self.catalogManifestEvidence = catalogManifestEvidence
    }
}

/// Resolver-owned qualification for an exact guest artifact. It is intentionally not Codable and
/// has no public initializer or public trust facts: UI/API intent cannot manufacture signature or
/// driver qualification. A signed-manifest resolver in DoryOperations creates these records.
public struct DoryTrustedGuestImageGraphicsQualification: Sendable, Equatable, Hashable {
    let auditEvidence: DorySignedArtifactQualificationEvidence
    let virtioGPUKernelAndDeviceSupportQualified: Bool
    let venusVulkanGuestRuntimeQualified: Bool

    init(
        auditEvidence: DorySignedArtifactQualificationEvidence,
        virtioGPUKernelAndDeviceSupportQualified: Bool,
        venusVulkanGuestRuntimeQualified: Bool
    ) {
        self.auditEvidence = auditEvidence
        self.virtioGPUKernelAndDeviceSupportQualified = virtioGPUKernelAndDeviceSupportQualified
        self.venusVulkanGuestRuntimeQualified = venusVulkanGuestRuntimeQualified
    }
}

/// Daemon-owned inspection of exact boot media. Detected format/architecture and compatibility
/// results are deliberately neither Codable nor publicly constructible; only the audit reference
/// is copied into a successful descriptor.
public struct DoryTrustedBootMediaInspection: Sendable, Equatable, Hashable {
    let auditEvidence: DoryBootMediaInspectionAuditEvidence
    let detectedKind: DoryBootMediaKind
    let detectedGuestFamily: DoryGuestFamily
    let detectedArchitecture: DoryGuestArchitecture
    let isEFIBootable: Bool
    let macOSBuildIdentifier: String?
    let macOSHardwareModelCompatible: Bool
    let macOSAuxiliaryStorageCompatible: Bool

    init(
        auditEvidence: DoryBootMediaInspectionAuditEvidence,
        detectedKind: DoryBootMediaKind,
        detectedGuestFamily: DoryGuestFamily,
        detectedArchitecture: DoryGuestArchitecture,
        isEFIBootable: Bool,
        macOSBuildIdentifier: String? = nil,
        macOSHardwareModelCompatible: Bool = false,
        macOSAuxiliaryStorageCompatible: Bool = false
    ) {
        self.auditEvidence = auditEvidence
        self.detectedKind = detectedKind
        self.detectedGuestFamily = detectedGuestFamily
        self.detectedArchitecture = detectedArchitecture
        self.isEFIBootable = isEFIBootable
        self.macOSBuildIdentifier = macOSBuildIdentifier
        self.macOSHardwareModelCompatible = macOSHardwareModelCompatible
        self.macOSAuxiliaryStorageCompatible = macOSAuxiliaryStorageCompatible
    }
}

/// Codable receipt reference emitted by the daemon after it resolves an exact mutable disk
/// revision. The receipt can be revalidated without treating request fields as authority.
public struct DoryMutableBootMediaProvenanceAuditEvidence: Codable, Sendable, Equatable, Hashable {
    public var receiptIdentity: String
    public var provenance: DoryMutableBootMediaProvenanceReference
    public var receiptSHA256: String
    public var resolverID: String
    public var resolverVersion: UInt16

    public init(
        receiptIdentity: String,
        provenance: DoryMutableBootMediaProvenanceReference,
        receiptSHA256: String,
        resolverID: String,
        resolverVersion: UInt16
    ) {
        self.receiptIdentity = receiptIdentity
        self.provenance = provenance
        self.receiptSHA256 = receiptSHA256
        self.resolverID = resolverID
        self.resolverVersion = resolverVersion
    }
}

public struct DoryTrustedMutableBootMediaProvenance: Sendable, Equatable, Hashable {
    let auditEvidence: DoryMutableBootMediaProvenanceAuditEvidence

    /// Non-secret durable receipt reference. The opaque trusted wrapper remains daemon-owned;
    /// persisted plans carry only this audit evidence and must resolve it again before launch.
    public var persistedAuditEvidence: DoryMutableBootMediaProvenanceAuditEvidence {
        auditEvidence
    }

    init(auditEvidence: DoryMutableBootMediaProvenanceAuditEvidence) {
        self.auditEvidence = auditEvidence
    }
}

/// Host runtime identities used to prevent a qualification for one adapter or virtual-device ABI
/// from authorizing a different installed runtime.
public struct DoryVirtualMachineRuntimeQualificationHostContext: Codable, Sendable, Equatable, Hashable {
    public var virtualHardwareABIVersion: UInt16
    public var doryHypervisorRuntimeBuildID: String
    public var virtualizationFrameworkAdapterBuildID: String
    public var qemuRuntimeBuildID: String

    public init(
        virtualHardwareABIVersion: UInt16,
        doryHypervisorRuntimeBuildID: String,
        virtualizationFrameworkAdapterBuildID: String,
        qemuRuntimeBuildID: String
    ) {
        self.virtualHardwareABIVersion = virtualHardwareABIVersion
        self.doryHypervisorRuntimeBuildID = doryHypervisorRuntimeBuildID
        self.virtualizationFrameworkAdapterBuildID = virtualizationFrameworkAdapterBuildID
        self.qemuRuntimeBuildID = qemuRuntimeBuildID
    }

    func runtimeBuildID(for backend: DoryVirtualizationBackendIdentity) -> String {
        switch backend {
        case .doryHypervisor:
            doryHypervisorRuntimeBuildID
        case .appleVirtualizationFramework:
            virtualizationFrameworkAdapterBuildID
        case .qemuHypervisorFramework:
            qemuRuntimeBuildID
        }
    }
}

/// Non-secret audit reference for exact runtime qualification. Exactly one media binding is used:
/// an immutable artifact digest or a mutable daemon provenance revision.
public struct DoryVirtualMachineRuntimeQualificationEvidence: Codable, Sendable, Equatable, Hashable {
    public var qualificationIdentity: String
    public var qualificationReportSHA256: String
    public var signingKeyID: String
    public var qualificationFormatVersion: UInt16
    public var guest: DoryGuestPlatform
    public var bootMediaKind: DoryBootMediaKind
    public var immutableArtifactSHA256: String?
    public var mutableProvenance: DoryMutableBootMediaProvenanceReference?
    public var backend: DoryVirtualizationBackendIdentity
    public var backendRuntimeBuildID: String
    public var virtualHardwareABIVersion: UInt16
    public var graphics: DoryGraphicsAccelerationLevel
    public var devices: DoryVirtualMachineDeviceCapabilityRequest

    public init(
        qualificationIdentity: String,
        qualificationReportSHA256: String,
        signingKeyID: String,
        qualificationFormatVersion: UInt16,
        guest: DoryGuestPlatform,
        bootMediaKind: DoryBootMediaKind,
        immutableArtifactSHA256: String? = nil,
        mutableProvenance: DoryMutableBootMediaProvenanceReference? = nil,
        backend: DoryVirtualizationBackendIdentity,
        backendRuntimeBuildID: String,
        virtualHardwareABIVersion: UInt16,
        graphics: DoryGraphicsAccelerationLevel,
        devices: DoryVirtualMachineDeviceCapabilityRequest
    ) {
        self.qualificationIdentity = qualificationIdentity
        self.qualificationReportSHA256 = qualificationReportSHA256
        self.signingKeyID = signingKeyID
        self.qualificationFormatVersion = qualificationFormatVersion
        self.guest = guest
        self.bootMediaKind = bootMediaKind
        self.immutableArtifactSHA256 = immutableArtifactSHA256
        self.mutableProvenance = mutableProvenance
        self.backend = backend
        self.backendRuntimeBuildID = backendRuntimeBuildID
        self.virtualHardwareABIVersion = virtualHardwareABIVersion
        self.graphics = graphics
        self.devices = devices
    }
}

/// Signature verification and the qualification decision remain daemon-owned and non-Codable.
public struct DoryTrustedVirtualMachineRuntimeQualification: Sendable, Equatable, Hashable {
    let auditEvidence: DoryVirtualMachineRuntimeQualificationEvidence
    let runtimeQualified: Bool

    init(
        auditEvidence: DoryVirtualMachineRuntimeQualificationEvidence,
        runtimeQualified: Bool
    ) {
        self.auditEvidence = auditEvidence
        self.runtimeQualified = runtimeQualified
    }
}

/// Opaque authority bundle for one exact capability request. Keeping runtime and guest-graphics
/// facts paired prevents inventory order from applying one signed image qualification to a
/// different backend, graphics level, device contract, or runtime build.
public struct DoryTrustedVirtualMachineCapabilityQualification:
    Sendable, Equatable, Hashable
{
    let request: DoryVirtualMachineCapabilityRequest
    let runtime: DoryTrustedVirtualMachineRuntimeQualification
    let graphics: DoryTrustedGuestImageGraphicsQualification?

    init(
        request: DoryVirtualMachineCapabilityRequest,
        runtime: DoryTrustedVirtualMachineRuntimeQualification,
        graphics: DoryTrustedGuestImageGraphicsQualification?
    ) {
        self.request = request
        self.runtime = runtime
        self.graphics = graphics
    }
}

/// A request is deliberately free of detected host state so it can cross process and API
/// boundaries and be evaluated by the daemon that owns the virtualization components.
public struct DoryVirtualMachineCapabilityRequest: Codable, Sendable, Equatable, Hashable {
    public var guest: DoryGuestPlatform
    public var bootMedia: DoryBootMedia
    public var backend: DoryVirtualizationBackendIdentity
    public var graphics: DoryGraphicsAccelerationLevel
    public var devices: DoryVirtualMachineDeviceCapabilityRequest
    public var virtualHardwareABIVersion: UInt16

    public init(
        guest: DoryGuestPlatform,
        bootMedia: DoryBootMedia,
        backend: DoryVirtualizationBackendIdentity,
        graphics: DoryGraphicsAccelerationLevel,
        devices: DoryVirtualMachineDeviceCapabilityRequest = .minimumBootable,
        virtualHardwareABIVersion: UInt16 = 1
    ) {
        self.guest = guest
        self.bootMedia = bootMedia
        self.backend = backend
        self.graphics = graphics
        self.devices = devices
        self.virtualHardwareABIVersion = virtualHardwareABIVersion
    }

    public static func == (
        lhs: DoryVirtualMachineCapabilityRequest,
        rhs: DoryVirtualMachineCapabilityRequest
    ) -> Bool {
        guard equalGuest(lhs, rhs) else { return false }
        guard equalBootMedia(lhs, rhs) else { return false }
        guard equalBackend(lhs, rhs) else { return false }
        guard equalGraphics(lhs, rhs) else { return false }
        guard equalDevices(lhs, rhs) else { return false }
        return equalVirtualHardwareABI(lhs, rhs)
    }

    // Keep each comparison in a separate frame. In unoptimized builds Swift otherwise retains
    // temporaries for every nested enum/collection in this value at once; the resulting frame can
    // exhaust the bounded stack used by Swift Testing's cooperative tasks.
    @inline(never)
    private static func equalGuest(_ lhs: borrowing Self, _ rhs: borrowing Self) -> Bool {
        lhs.guest == rhs.guest
    }

    @inline(never)
    private static func equalBootMedia(_ lhs: borrowing Self, _ rhs: borrowing Self) -> Bool {
        lhs.bootMedia == rhs.bootMedia
    }

    @inline(never)
    private static func equalBackend(_ lhs: borrowing Self, _ rhs: borrowing Self) -> Bool {
        lhs.backend == rhs.backend
    }

    @inline(never)
    private static func equalGraphics(_ lhs: borrowing Self, _ rhs: borrowing Self) -> Bool {
        lhs.graphics == rhs.graphics
    }

    @inline(never)
    private static func equalDevices(_ lhs: borrowing Self, _ rhs: borrowing Self) -> Bool {
        lhs.devices == rhs.devices
    }

    @inline(never)
    private static func equalVirtualHardwareABI(
        _ lhs: borrowing Self,
        _ rhs: borrowing Self
    ) -> Bool {
        lhs.virtualHardwareABIVersion == rhs.virtualHardwareABIVersion
    }

    private enum CodingKeys: String, CodingKey {
        case guest
        case bootMedia
        case backend
        case graphics
        case devices
        case virtualHardwareABIVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guest = try container.decode(DoryGuestPlatform.self, forKey: .guest)
        bootMedia = try container.decode(DoryBootMedia.self, forKey: .bootMedia)
        backend = try container.decode(DoryVirtualizationBackendIdentity.self, forKey: .backend)
        graphics = try container.decode(DoryGraphicsAccelerationLevel.self, forKey: .graphics)
        devices = try container.decodeIfPresent(
            DoryVirtualMachineDeviceCapabilityRequest.self,
            forKey: .devices
        ) ?? .minimumBootable
        virtualHardwareABIVersion = try container.decodeIfPresent(
            UInt16.self,
            forKey: .virtualHardwareABIVersion
        ) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(guest, forKey: .guest)
        try container.encode(bootMedia, forKey: .bootMedia)
        try container.encode(backend, forKey: .backend)
        try container.encode(graphics, forKey: .graphics)
        try container.encode(devices, forKey: .devices)
        try container.encode(virtualHardwareABIVersion, forKey: .virtualHardwareABIVersion)
    }
}

/// The daemon's immutable answer to a capability request. `schemaVersion` versions the wire shape,
/// while the evaluator version identifies the support policy used to produce the answer.
public struct DoryVirtualMachineCapabilityDescriptor: Codable, Sendable, Equatable, Hashable {
    public static let currentSchemaVersion: UInt16 = 2
    public static let appleSiliconEvaluatorVersion: UInt16 = 2

    public var schemaVersion: UInt16
    public var evaluatorVersion: UInt16
    public var request: DoryVirtualMachineCapabilityRequest
    public var availability: DoryCapabilityAvailability
    /// Exact device contract selected for a usable descriptor. No partial device downgrade occurs.
    public var resolvedDevices: DoryVirtualMachineDeviceCapabilityRequest?
    public var graphicsQualificationEvidence: DorySignedArtifactQualificationEvidence?
    public var bootMediaInspectionEvidence: DoryBootMediaInspectionAuditEvidence?
    public var mutableBootMediaProvenanceEvidence: DoryMutableBootMediaProvenanceAuditEvidence?
    public var runtimeQualificationEvidence: DoryVirtualMachineRuntimeQualificationEvidence?

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        evaluatorVersion: UInt16,
        request: DoryVirtualMachineCapabilityRequest,
        availability: DoryCapabilityAvailability,
        resolvedDevices: DoryVirtualMachineDeviceCapabilityRequest? = nil,
        graphicsQualificationEvidence: DorySignedArtifactQualificationEvidence? = nil,
        bootMediaInspectionEvidence: DoryBootMediaInspectionAuditEvidence? = nil,
        mutableBootMediaProvenanceEvidence: DoryMutableBootMediaProvenanceAuditEvidence? = nil,
        runtimeQualificationEvidence: DoryVirtualMachineRuntimeQualificationEvidence? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.evaluatorVersion = evaluatorVersion
        self.request = request
        self.availability = availability
        self.resolvedDevices = resolvedDevices
        self.graphicsQualificationEvidence = graphicsQualificationEvidence
        self.bootMediaInspectionEvidence = bootMediaInspectionEvidence
        self.mutableBootMediaProvenanceEvidence = mutableBootMediaProvenanceEvidence
        self.runtimeQualificationEvidence = runtimeQualificationEvidence
    }

    public static func == (
        lhs: DoryVirtualMachineCapabilityDescriptor,
        rhs: DoryVirtualMachineCapabilityDescriptor
    ) -> Bool {
        guard equalSchemaVersion(lhs, rhs) else { return false }
        guard equalEvaluatorVersion(lhs, rhs) else { return false }
        guard equalRequest(lhs, rhs) else { return false }
        guard equalAvailability(lhs, rhs) else { return false }
        guard equalResolvedDevices(lhs, rhs) else { return false }
        guard equalGraphicsQualificationEvidence(lhs, rhs) else { return false }
        guard equalBootMediaInspectionEvidence(lhs, rhs) else { return false }
        guard equalMutableBootMediaProvenanceEvidence(lhs, rhs) else { return false }
        return equalRuntimeQualificationEvidence(lhs, rhs)
    }

    @inline(never)
    private static func equalSchemaVersion(_ lhs: borrowing Self, _ rhs: borrowing Self) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
    }

    @inline(never)
    private static func equalEvaluatorVersion(
        _ lhs: borrowing Self,
        _ rhs: borrowing Self
    ) -> Bool {
        lhs.evaluatorVersion == rhs.evaluatorVersion
    }

    @inline(never)
    private static func equalRequest(_ lhs: borrowing Self, _ rhs: borrowing Self) -> Bool {
        lhs.request == rhs.request
    }

    @inline(never)
    private static func equalAvailability(_ lhs: borrowing Self, _ rhs: borrowing Self) -> Bool {
        lhs.availability == rhs.availability
    }

    @inline(never)
    private static func equalResolvedDevices(_ lhs: borrowing Self, _ rhs: borrowing Self) -> Bool {
        lhs.resolvedDevices == rhs.resolvedDevices
    }

    @inline(never)
    private static func equalGraphicsQualificationEvidence(
        _ lhs: borrowing Self,
        _ rhs: borrowing Self
    ) -> Bool {
        lhs.graphicsQualificationEvidence == rhs.graphicsQualificationEvidence
    }

    @inline(never)
    private static func equalBootMediaInspectionEvidence(
        _ lhs: borrowing Self,
        _ rhs: borrowing Self
    ) -> Bool {
        lhs.bootMediaInspectionEvidence == rhs.bootMediaInspectionEvidence
    }

    @inline(never)
    private static func equalMutableBootMediaProvenanceEvidence(
        _ lhs: borrowing Self,
        _ rhs: borrowing Self
    ) -> Bool {
        lhs.mutableBootMediaProvenanceEvidence == rhs.mutableBootMediaProvenanceEvidence
    }

    @inline(never)
    private static func equalRuntimeQualificationEvidence(
        _ lhs: borrowing Self,
        _ rhs: borrowing Self
    ) -> Bool {
        lhs.runtimeQualificationEvidence == rhs.runtimeQualificationEvidence
    }

}

/// Host observations used by the Apple Silicon policy. No global process or framework probing is
/// performed here, keeping evaluation deterministic and making stale daemon/UI state detectable.
public struct DoryAppleSiliconHostFacts: Codable, Sendable, Equatable, Hashable {
    public var macOSMajorVersion: Int
    public var virtualizationFrameworkAvailable: Bool
    public var hypervisorFrameworkAvailable: Bool
    public var doryHypervisorAvailable: Bool
    public var qemuHypervisorFrameworkAvailable: Bool
    public var windowsUEFIFirmwareAvailable: Bool
    public var windowsSecureBootAvailable: Bool
    public var windowsSBSADeviceModelAvailable: Bool
    public var virtualTPM20Available: Bool
    public var windowsGuestDrivers: DoryWindowsGuestDriverFacts
    public var macOSGuestVirtualizationSupported: Bool
    public var macOSRestoreImageInstallationSupported: Bool
    public var doryMacOSBackendAvailable: Bool
    public var doryMacOSBackendQualified: Bool
    public var metalAvailable: Bool
    public var doryAcceleratedRendererAvailable: Bool
    /// `nil` means the host observation predates explicit Rosetta-for-Linux probing and is
    /// therefore not sufficient to authorize application translation.
    public var linuxIntelApplicationTranslationAvailable: Bool?
    public var runtimeQualificationContext: DoryVirtualMachineRuntimeQualificationHostContext?

    public init(
        macOSMajorVersion: Int,
        virtualizationFrameworkAvailable: Bool,
        hypervisorFrameworkAvailable: Bool,
        doryHypervisorAvailable: Bool,
        qemuHypervisorFrameworkAvailable: Bool,
        windowsUEFIFirmwareAvailable: Bool,
        windowsSecureBootAvailable: Bool,
        windowsSBSADeviceModelAvailable: Bool,
        virtualTPM20Available: Bool,
        windowsGuestDrivers: DoryWindowsGuestDriverFacts,
        macOSGuestVirtualizationSupported: Bool,
        macOSRestoreImageInstallationSupported: Bool,
        doryMacOSBackendAvailable: Bool,
        doryMacOSBackendQualified: Bool,
        metalAvailable: Bool,
        doryAcceleratedRendererAvailable: Bool,
        linuxIntelApplicationTranslationAvailable: Bool? = nil,
        runtimeQualificationContext: DoryVirtualMachineRuntimeQualificationHostContext? = nil
    ) {
        self.macOSMajorVersion = macOSMajorVersion
        self.virtualizationFrameworkAvailable = virtualizationFrameworkAvailable
        self.hypervisorFrameworkAvailable = hypervisorFrameworkAvailable
        self.doryHypervisorAvailable = doryHypervisorAvailable
        self.qemuHypervisorFrameworkAvailable = qemuHypervisorFrameworkAvailable
        self.windowsUEFIFirmwareAvailable = windowsUEFIFirmwareAvailable
        self.windowsSecureBootAvailable = windowsSecureBootAvailable
        self.windowsSBSADeviceModelAvailable = windowsSBSADeviceModelAvailable
        self.virtualTPM20Available = virtualTPM20Available
        self.windowsGuestDrivers = windowsGuestDrivers
        self.macOSGuestVirtualizationSupported = macOSGuestVirtualizationSupported
        self.macOSRestoreImageInstallationSupported = macOSRestoreImageInstallationSupported
        self.doryMacOSBackendAvailable = doryMacOSBackendAvailable
        self.doryMacOSBackendQualified = doryMacOSBackendQualified
        self.metalAvailable = metalAvailable
        self.doryAcceleratedRendererAvailable = doryAcceleratedRendererAvailable
        self.linuxIntelApplicationTranslationAvailable =
            linuxIntelApplicationTranslationAvailable
        self.runtimeQualificationContext = runtimeQualificationContext
    }
}

/// Conservative Apple Silicon capability policy. It only reports a configuration as usable after
/// the guest/backend contract and the supplied host facts both satisfy the request.
public enum DoryAppleSiliconCapabilityEvaluator {
    public static func evaluate(
        _ request: DoryVirtualMachineCapabilityRequest,
        host: DoryAppleSiliconHostFacts,
        trustedGuestImageGraphicsQualification: DoryTrustedGuestImageGraphicsQualification? = nil,
        trustedBootMediaInspection: DoryTrustedBootMediaInspection? = nil,
        trustedMutableBootMediaProvenance: DoryTrustedMutableBootMediaProvenance? = nil,
        trustedRuntimeQualification: DoryTrustedVirtualMachineRuntimeQualification? = nil
    ) -> DoryVirtualMachineCapabilityDescriptor {
        let availability = evaluateAvailability(
            request,
            host: host,
            trustedGuestImageGraphicsQualification: trustedGuestImageGraphicsQualification,
            trustedBootMediaInspection: trustedBootMediaInspection,
            trustedMutableBootMediaProvenance: trustedMutableBootMediaProvenance,
            trustedRuntimeQualification: trustedRuntimeQualification
        )
        return DoryVirtualMachineCapabilityDescriptor(
            evaluatorVersion: DoryVirtualMachineCapabilityDescriptor.appleSiliconEvaluatorVersion,
            request: request,
            availability: availability,
            resolvedDevices: availability.isUsable ? request.devices : nil,
            graphicsQualificationEvidence: availability.isUsable
                ? graphicsAuditEvidence(
                    for: request,
                    trustedQualification: trustedGuestImageGraphicsQualification
                )
                : nil,
            bootMediaInspectionEvidence: availability.isUsable
                ? bootMediaAuditEvidence(
                    for: request,
                    trustedInspection: trustedBootMediaInspection
                )
                : nil,
            mutableBootMediaProvenanceEvidence: availability.isUsable
                ? mutableBootMediaProvenanceAuditEvidence(
                    for: request,
                    trustedProvenance: trustedMutableBootMediaProvenance
                )
                : nil,
            runtimeQualificationEvidence: availability.supportTier == .supported
                    && availability.isUsable
                ? trustedRuntimeQualification?.auditEvidence
                : nil
        )
    }

    private static func evaluateAvailability(
        _ request: DoryVirtualMachineCapabilityRequest,
        host: DoryAppleSiliconHostFacts,
        trustedGuestImageGraphicsQualification: DoryTrustedGuestImageGraphicsQualification?,
        trustedBootMediaInspection: DoryTrustedBootMediaInspection?,
        trustedMutableBootMediaProvenance: DoryTrustedMutableBootMediaProvenance?,
        trustedRuntimeQualification: DoryTrustedVirtualMachineRuntimeQualification?
    ) -> DoryCapabilityAvailability {
        if let artifactSHA256 = request.bootMedia.artifactSHA256,
           !isSHA256(artifactSHA256) {
            return unsupported(
                .bootMediaArtifactDigestInvalid,
                "The selected boot-media artifact identity is not a valid SHA-256 digest."
            )
        }

        guard request.guest.architecture == .arm64 else {
            return unsupported(
                .guestArchitectureRequiresEmulation,
                "Apple Silicon can virtualize ARM64 guests; x86_64 guests require a CPU emulation backend."
            )
        }

        guard let supportTier = supportTier(for: request) else {
            return unsupported(
                .backendDoesNotSupportGuest,
                "The selected virtualization backend does not support this guest family."
            )
        }

        guard bootMediaIsCompatible(request.bootMedia.kind, with: request.guest.family) else {
            return unsupported(
                .bootMediaDoesNotSupportGuest,
                "The selected boot-media format is not supported for this guest family."
            )
        }

        guard bootMediaIsCompatibleWithBackend(request) else {
            return unsupported(
                .bootMediaDoesNotSupportBackend,
                "The selected backend cannot boot this media format for the requested guest."
            )
        }

        if request.guest.family == .macOS || request.guest.family == .windows,
           request.bootMedia.source == .bundledByDory {
            return unsupported(
                .guestMediaRedistributionUnavailable,
                "This guest's installation media must come from its vendor or the user; Dory does not redistribute it."
            )
        }

        if let unavailable = mutableBootMediaProvenanceFailure(
            for: request,
            trustedProvenance: trustedMutableBootMediaProvenance,
            tier: supportTier
        ) {
            return unavailable
        }

        if let unavailable = bootMediaInspectionFailure(
            for: request,
            trustedInspection: trustedBootMediaInspection,
            tier: supportTier
        ) {
            return unavailable
        }

        if request.guest.family == .windows, request.graphics == .hardwareAccelerated3D {
            return unsupported(
                .windows3DAccelerationUnsupported,
                "Windows 3D acceleration is not currently supported on Apple Silicon."
            )
        }

        guard graphicsContractIsSupported(for: request) else {
            return unsupported(
                .graphicsModeUnsupported,
                "The selected backend cannot provide the requested graphics acceleration level for this guest."
            )
        }

        if let unavailable = guestImageGraphicsQualificationFailure(
            for: request,
            trustedQualification: trustedGuestImageGraphicsQualification
        ) {
            return unavailable
        }
        if let unavailable = deviceCapabilityFailure(
            for: request,
            host: host,
            tier: supportTier
        ) {
            return unavailable
        }

        if let unavailable = backendAvailabilityFailure(request, host: host, tier: supportTier) {
            return unavailable
        }

        if request.graphics == .hostAcceleratedDisplay || request.graphics == .hardwareAccelerated3D {
            guard host.metalAvailable else {
                return unavailable(
                    tier: supportTier,
                    code: .metalUnavailable,
                    message: "The requested graphics mode requires Metal on the host."
                )
            }
        }

        if request.backend == .doryHypervisor,
           request.graphics == .hostAcceleratedDisplay || request.graphics == .hardwareAccelerated3D,
           !host.doryAcceleratedRendererAvailable {
            return unavailable(
                tier: supportTier,
                code: .acceleratedRendererUnavailable,
                message: "Dory's accelerated graphics renderer is not installed or failed validation."
            )
        }

        if supportTier == .supported,
           let runtimeDecision = runtimeQualificationDecision(
                for: request,
                host: host,
                trustedQualification: trustedRuntimeQualification
           ) {
            return runtimeDecision
        }

        if supportTier == .experimental, request.guest.family == .windows {
            return DoryCapabilityAvailability(
                supportTier: .experimental,
                state: .available,
                reason: DoryCapabilityReason(
                    code: .windowsSupportIsExperimental,
                    message: "Windows virtualization is experimental and does not include 3D acceleration."
                )
            )
        }
        if supportTier == .experimental {
            return DoryCapabilityAvailability(
                supportTier: .experimental,
                state: .available,
                reason: DoryCapabilityReason(
                    code: .backendSupportIsExperimental,
                    message: "This virtualization backend is experimental for the requested guest."
                )
            )
        }

        return DoryCapabilityAvailability(supportTier: .supported, state: .available)
    }

    private static func supportTier(
        for request: DoryVirtualMachineCapabilityRequest
    ) -> DoryCapabilitySupportTier? {
        switch (request.guest.family, request.backend) {
        case (.linux, .doryHypervisor),
             (.linux, .appleVirtualizationFramework):
            return .supported
        case (.linux, .qemuHypervisorFramework),
             (.macOS, .appleVirtualizationFramework),
             (.windows, .qemuHypervisorFramework):
            return .experimental
        default:
            return nil
        }
    }

    private static func bootMediaIsCompatible(
        _ media: DoryBootMediaKind,
        with family: DoryGuestFamily
    ) -> Bool {
        switch family {
        case .linux:
            media == .linuxKernel || media == .installerISO || media == .virtualDisk
                || media == .installedLinuxBootBundle
        case .windows:
            media == .installerISO || media == .virtualDisk
        case .macOS:
            media == .macOSRestoreImage || media == .virtualDisk
        }
    }

    private static func bootMediaIsCompatibleWithBackend(
        _ request: DoryVirtualMachineCapabilityRequest
    ) -> Bool {
        switch (request.guest.family, request.backend) {
        case (.linux, .doryHypervisor):
            return request.bootMedia.kind == .linuxKernel
                || request.bootMedia.kind == .installedLinuxBootBundle
        case (.linux, .appleVirtualizationFramework):
            return request.bootMedia.kind == .linuxKernel
                || request.bootMedia.kind == .installerISO
                || request.bootMedia.kind == .virtualDisk
                || request.bootMedia.kind == .installedLinuxBootBundle
        case (.linux, .qemuHypervisorFramework),
             (.windows, .qemuHypervisorFramework):
            return request.bootMedia.kind == .installerISO || request.bootMedia.kind == .virtualDisk
        case (.macOS, .appleVirtualizationFramework):
            return request.bootMedia.kind == .macOSRestoreImage || request.bootMedia.kind == .virtualDisk
        default:
            return false
        }
    }

    private static func graphicsContractIsSupported(
        for request: DoryVirtualMachineCapabilityRequest
    ) -> Bool {
        switch request.graphics {
        case .none, .software:
            return true
        case .hostAcceleratedDisplay:
            return true
        case .hardwareAccelerated3D:
            return (request.guest.family == .linux && request.backend == .doryHypervisor)
                || (request.guest.family == .macOS && request.backend == .appleVirtualizationFramework)
        }
    }

    private static func backendAvailabilityFailure(
        _ request: DoryVirtualMachineCapabilityRequest,
        host: DoryAppleSiliconHostFacts,
        tier: DoryCapabilitySupportTier
    ) -> DoryCapabilityAvailability? {
        switch request.backend {
        case .doryHypervisor:
            guard host.macOSMajorVersion >= 15 else {
                return unavailable(
                    tier: tier,
                    code: .hostOperatingSystemUnsupported,
                    message: "Dory's native hypervisor backend requires macOS 15 or newer."
                )
            }
            guard host.hypervisorFrameworkAvailable else {
                return unavailable(
                    tier: tier,
                    code: .hypervisorFrameworkUnavailable,
                    message: "Hypervisor.framework is unavailable on this host."
                )
            }
            guard host.doryHypervisorAvailable else {
                return unavailable(
                    tier: tier,
                    code: .backendComponentUnavailable,
                    message: "Dory's native hypervisor component is not installed or failed validation."
                )
            }
        case .appleVirtualizationFramework:
            guard host.macOSMajorVersion >= 14 else {
                return unavailable(
                    tier: tier,
                    code: .hostOperatingSystemUnsupported,
                    message: "This Dory runtime requires macOS 14 or newer."
                )
            }
            guard host.virtualizationFrameworkAvailable else {
                return unavailable(
                    tier: tier,
                    code: .virtualizationFrameworkUnavailable,
                    message: "Virtualization.framework is unavailable on this host."
                )
            }
            if request.guest.family == .macOS {
                guard host.macOSGuestVirtualizationSupported else {
                    return unavailable(
                        tier: tier,
                        code: .macOSGuestVirtualizationUnavailable,
                        message: "This Apple Silicon host does not report support for macOS guests."
                    )
                }
                guard host.doryMacOSBackendAvailable else {
                    return unavailable(
                        tier: tier,
                        code: .backendComponentUnavailable,
                        message: "Dory's VZMac backend adapter is not installed or failed validation."
                    )
                }
                guard host.doryMacOSBackendQualified else {
                    return unavailable(
                        tier: tier,
                        code: .backendComponentUnqualified,
                        message: "Dory's VZMac backend adapter has not passed signed runtime qualification."
                    )
                }
                if request.bootMedia.kind == .macOSRestoreImage,
                   !host.macOSRestoreImageInstallationSupported {
                    return unavailable(
                        tier: tier,
                        code: .macOSRestoreImageUnsupported,
                        message: "The selected Apple restore image cannot be installed on this host."
                    )
                }
            }
        case .qemuHypervisorFramework:
            guard host.macOSMajorVersion >= 14 else {
                return unavailable(
                    tier: tier,
                    code: .hostOperatingSystemUnsupported,
                    message: "This Dory runtime requires macOS 14 or newer."
                )
            }
            guard host.hypervisorFrameworkAvailable else {
                return unavailable(
                    tier: tier,
                    code: .hypervisorFrameworkUnavailable,
                    message: "Hypervisor.framework is unavailable on this host."
                )
            }
            guard host.qemuHypervisorFrameworkAvailable else {
                return unavailable(
                    tier: tier,
                    code: .backendComponentUnavailable,
                    message: "The QEMU Hypervisor.framework component is not installed or failed validation."
                )
            }
            if request.guest.family == .windows {
                guard host.windowsUEFIFirmwareAvailable else {
                    return unavailable(
                        tier: tier,
                        code: .windowsUEFIFirmwareUnavailable,
                        message: "Qualified ARM64 UEFI firmware is required to boot this Windows guest."
                    )
                }
                guard host.windowsSecureBootAvailable else {
                    return unavailable(
                        tier: tier,
                        code: .windowsSecureBootUnavailable,
                        message: "A qualified Secure Boot implementation is required for this Windows guest."
                    )
                }
                guard host.windowsSBSADeviceModelAvailable else {
                    return unavailable(
                        tier: tier,
                        code: .windowsSBSADeviceModelUnavailable,
                        message: "A qualified SBSA virtual device model is required for this Windows guest."
                    )
                }
                guard host.virtualTPM20Available else {
                    return unavailable(
                        tier: tier,
                        code: .virtualTPM20Unavailable,
                        message: "A compatible virtual TPM 2.0 device is required for this Windows guest."
                    )
                }
                if let driverFailure = windowsDriverAvailabilityFailure(host.windowsGuestDrivers, tier: tier) {
                    return driverFailure
                }
            }
        }
        return nil
    }

    private static func mutableBootMediaProvenanceFailure(
        for request: DoryVirtualMachineCapabilityRequest,
        trustedProvenance: DoryTrustedMutableBootMediaProvenance?,
        tier: DoryCapabilitySupportTier
    ) -> DoryCapabilityAvailability? {
        guard request.bootMedia.kind == .virtualDisk else {
            guard request.bootMedia.mutableProvenance == nil else {
                return unavailable(
                    tier: tier,
                    code: .mutableBootMediaProvenanceInvalid,
                    message: "Mutable provenance is only valid for virtual-disk boot media."
                )
            }
            return nil
        }
        guard let requested = request.bootMedia.mutableProvenance else {
            return unavailable(
                tier: tier,
                code: .mutableBootMediaProvenanceUnavailable,
                message: "A mutable virtual disk requires a daemon-resolved provenance revision."
            )
        }
        guard mutableProvenanceIsValid(requested) else {
            return unavailable(
                tier: tier,
                code: .mutableBootMediaProvenanceInvalid,
                message: "The requested mutable-disk provenance reference is malformed."
            )
        }
        guard let trustedProvenance else {
            return unavailable(
                tier: tier,
                code: .trustedMutableBootMediaProvenanceUnavailable,
                message: "The daemon has not resolved the requested mutable-disk revision."
            )
        }
        guard mutableProvenanceEvidenceIsValid(trustedProvenance.auditEvidence) else {
            return unavailable(
                tier: tier,
                code: .mutableBootMediaProvenanceInvalid,
                message: "The daemon's mutable-disk provenance receipt is invalid."
            )
        }
        guard trustedProvenance.auditEvidence.provenance == requested else {
            return unavailable(
                tier: tier,
                code: .mutableBootMediaProvenanceMismatch,
                message: "The trusted provenance receipt describes a different mutable-disk revision."
            )
        }
        return nil
    }

    private static func runtimeQualificationDecision(
        for request: DoryVirtualMachineCapabilityRequest,
        host: DoryAppleSiliconHostFacts,
        trustedQualification: DoryTrustedVirtualMachineRuntimeQualification?
    ) -> DoryCapabilityAvailability? {
        guard let trustedQualification else {
            return DoryCapabilityAvailability(
                supportTier: .experimental,
                state: .available,
                reason: DoryCapabilityReason(
                    code: .runtimeQualificationUnavailable,
                    message: "The media is structurally bootable, but this exact backend, "
                        + "device ABI, and runtime combination is not qualified."
                )
            )
        }
        guard trustedQualification.runtimeQualified else {
            return unavailable(
                tier: .experimental,
                code: .runtimeQualificationUnavailable,
                message: "This exact media, backend, device ABI, and runtime combination failed qualification."
            )
        }
        let evidence = trustedQualification.auditEvidence
        guard runtimeQualificationEvidenceIsValid(evidence) else {
            return unavailable(
                tier: .supported,
                code: .runtimeQualificationEvidenceInvalid,
                message: "The runtime qualification has incomplete or invalid audit evidence."
            )
        }
        guard evidence.guest == request.guest,
              evidence.bootMediaKind == request.bootMedia.kind,
              evidence.backend == request.backend,
              evidence.graphics == request.graphics,
              evidence.devices.matchesRuntimeQualificationContract(request.devices),
              evidence.virtualHardwareABIVersion == request.virtualHardwareABIVersion else {
            return unavailable(
                tier: .supported,
                code: .runtimeQualificationRequestMismatch,
                message: "The runtime qualification does not match the requested guest, backend, "
                    + "graphics, devices, or virtual-hardware ABI."
            )
        }
        guard let hostContext = host.runtimeQualificationContext,
              hostContext.virtualHardwareABIVersion == request.virtualHardwareABIVersion,
              evidence.backendRuntimeBuildID == hostContext.runtimeBuildID(for: request.backend) else {
            return unavailable(
                tier: .supported,
                code: .runtimeQualificationHostMismatch,
                message: "The runtime qualification does not match the installed backend build or device ABI."
            )
        }

        if request.bootMedia.kind == .virtualDisk {
            guard evidence.immutableArtifactSHA256 == nil,
                  evidence.mutableProvenance == request.bootMedia.mutableProvenance else {
                return unavailable(
                    tier: .supported,
                    code: .runtimeQualificationRequestMismatch,
                    message: "The runtime qualification describes a different mutable-disk revision."
                )
            }
        } else {
            guard let artifactSHA256 = request.bootMedia.artifactSHA256,
                  evidence.mutableProvenance == nil,
                  evidence.immutableArtifactSHA256?.lowercased()
                    == artifactSHA256.lowercased() else {
                return unavailable(
                    tier: .supported,
                    code: .runtimeQualificationRequestMismatch,
                    message: "The runtime qualification describes a different immutable media artifact."
                )
            }
        }
        return nil
    }

    private static func bootMediaInspectionFailure(
        for request: DoryVirtualMachineCapabilityRequest,
        trustedInspection: DoryTrustedBootMediaInspection?,
        tier: DoryCapabilitySupportTier
    ) -> DoryCapabilityAvailability? {
        guard request.bootMedia.kind == .installerISO
                || request.bootMedia.kind == .macOSRestoreImage else {
            return nil
        }
        guard let selectedArtifactSHA256 = request.bootMedia.artifactSHA256 else {
            return unavailable(
                tier: tier,
                code: .bootMediaArtifactDigestUnavailable,
                message: "Installer and restore media must have a daemon-resolved SHA-256 identity."
            )
        }
        guard let inspection = trustedInspection else {
            return unavailable(
                tier: tier,
                code: .trustedBootMediaInspectionUnavailable,
                message: "The daemon has not inspected this exact boot-media artifact."
            )
        }
        guard bootMediaInspectionEvidenceIsValid(inspection.auditEvidence) else {
            return unavailable(
                tier: tier,
                code: .bootMediaInspectionEvidenceInvalid,
                message: "The boot-media inspection has an incomplete or invalid audit receipt."
            )
        }
        guard inspection.auditEvidence.artifactSHA256.lowercased()
                == selectedArtifactSHA256.lowercased() else {
            return unavailable(
                tier: tier,
                code: .bootMediaArtifactInspectionMismatch,
                message: "The trusted inspection does not describe the selected boot-media artifact."
            )
        }
        guard inspection.detectedKind == request.bootMedia.kind else {
            return unavailable(
                tier: tier,
                code: .bootMediaKindInspectionMismatch,
                message: "The inspected media format does not match the requested boot-media format."
            )
        }
        guard inspection.detectedGuestFamily == request.guest.family else {
            return unavailable(
                tier: tier,
                code: .bootMediaGuestInspectionMismatch,
                message: "The inspected media does not contain the requested guest operating-system family."
            )
        }
        guard inspection.detectedArchitecture == request.guest.architecture else {
            return unavailable(
                tier: tier,
                code: .bootMediaArchitectureInspectionMismatch,
                message: "The inspected media architecture does not match the requested guest architecture."
            )
        }
        guard request.bootMedia.kind != .installerISO || inspection.isEFIBootable else {
            return unavailable(
                tier: tier,
                code: .bootMediaNotEFIBootable,
                message: "The inspected media has no compatible ARM64 EFI boot path."
            )
        }

        if request.bootMedia.kind == .macOSRestoreImage {
            guard let build = inspection.macOSBuildIdentifier, !build.isEmpty else {
                return unavailable(
                    tier: tier,
                    code: .macOSRestoreBuildIdentityUnavailable,
                    message: "The inspected Apple restore image has no resolved build identity."
                )
            }
            guard inspection.macOSHardwareModelCompatible else {
                return unavailable(
                    tier: tier,
                    code: .macOSRestoreHardwareModelIncompatible,
                    message: "The exact Apple restore image is incompatible with the resolved virtual hardware model."
                )
            }
            guard inspection.macOSAuxiliaryStorageCompatible else {
                return unavailable(
                    tier: tier,
                    code: .macOSRestoreAuxiliaryStorageIncompatible,
                    message: "The exact Apple restore image is incompatible with the resolved auxiliary storage."
                )
            }
        }
        return nil
    }

    private static func deviceCapabilityFailure(
        for request: DoryVirtualMachineCapabilityRequest,
        host: DoryAppleSiliconHostFacts,
        tier: DoryCapabilitySupportTier
    ) -> DoryCapabilityAvailability? {
        let devices = request.devices
        if let networkInterface = devices.networkInterface, !networkInterface.isValid {
            return unavailable(
                tier: tier,
                code: .networkAttachmentUnsupported,
                message: "The resolved network interface identity or MTU is invalid."
            )
        }
        switch devices.networkAttachment {
        case .sharedNAT:
            break
        case .disconnected:
            guard request.guest.family == .linux,
                  request.backend == .appleVirtualizationFramework
                    || request.backend == .doryHypervisor else {
                return unavailable(
                    tier: tier,
                    code: .networkAttachmentUnsupported,
                    message: "The selected backend does not implement disconnected networking."
                )
            }
        case .isolated:
            guard request.guest.family == .linux,
                  request.backend == .appleVirtualizationFramework
                    || request.backend == .doryHypervisor else {
                return unavailable(
                    tier: tier,
                    code: .networkAttachmentUnsupported,
                    message: "The selected backend does not implement host-only networking."
                )
            }
        case .bridged:
            return unavailable(
                tier: tier,
                code: .networkAttachmentUnsupported,
                message: "The selected backend does not implement the requested network attachment mode."
            )
        }

        let isGraphical = request.graphics != .none
        let isLinuxVZ = request.guest.family == .linux
            && request.backend == .appleVirtualizationFramework
        let isLinuxRawHV = request.guest.family == .linux
            && request.backend == .doryHypervisor
        let isLinuxDesktopRuntime = isGraphical && (isLinuxVZ || isLinuxRawHV)
        let audioIsImplemented = isLinuxVZ && isGraphical
            || isLinuxRawHV && isGraphical && devices.audioInput == devices.audioOutput
        if devices.audioInput, !audioIsImplemented {
            return unavailable(
                tier: tier,
                code: .audioInputUnsupported,
                message: "The selected guest/backend contract does not implement host audio input."
            )
        }
        if devices.audioOutput, !audioIsImplemented {
            return unavailable(
                tier: tier,
                code: .audioOutputUnsupported,
                message: "The selected guest/backend contract does not implement host audio output."
            )
        }

        let hasImplementedInput = isGraphical && (
            (request.guest.family == .linux
                && (request.backend == .doryHypervisor
                    || request.backend == .appleVirtualizationFramework))
                || (request.guest.family == .macOS
                    && request.backend == .appleVirtualizationFramework)
                || (request.guest.family == .windows
                    && request.backend == .qemuHypervisorFramework)
        )
        if devices.keyboard, !hasImplementedInput {
            return unavailable(
                tier: tier,
                code: .keyboardInputUnsupported,
                message: "The selected guest/backend contract does not implement keyboard input."
            )
        }
        if devices.pointer, !hasImplementedInput {
            return unavailable(
                tier: tier,
                code: .pointerInputUnsupported,
                message: "The selected guest/backend contract does not implement pointer input."
            )
        }

        if devices.directorySharing,
           !(request.guest.family == .linux
                && (request.backend == .doryHypervisor
                    || request.backend == .appleVirtualizationFramework)) {
            return unavailable(
                tier: tier,
                code: .directorySharingUnsupported,
                message: "The selected guest/backend contract does not implement directory sharing."
            )
        }
        if devices.clipboard, !isLinuxDesktopRuntime {
            return unavailable(
                tier: tier,
                code: .clipboardIntegrationUnsupported,
                message: "The selected guest/backend contract does not implement clipboard integration."
            )
        }
        if let clipboardPolicy = devices.clipboardPolicy {
            guard devices.clipboard == clipboardPolicy.isEnabled else {
                return unavailable(
                    tier: tier,
                    code: .clipboardPolicyInvalid,
                    message: "The resolved clipboard device and directional policy disagree."
                )
            }
            // File transfer is implemented by the authenticated Dory Tools sync channel rather
            // than the display helper's clipboard transport. The exact directional policy still
            // belongs to this resolved device contract and is enforced by the daemon at each
            // push/pull operation boundary.
        }
        if devices.clockSynchronization {
            guard request.guest.family == .linux,
                  request.backend == .doryHypervisor
                    || request.backend == .appleVirtualizationFramework else {
                return unavailable(
                    tier: tier,
                    code: .clockSynchronizationUnsupported,
                    message: "The selected guest/backend contract does not implement clock synchronization."
                )
            }
        }
        if devices.dynamicDisplay, !isLinuxDesktopRuntime {
            return unavailable(
                tier: tier,
                code: .dynamicDisplayUnsupported,
                message: "The selected guest/backend contract does not implement dynamic display resizing."
            )
        }
        if devices.gracefulShutdown {
            guard request.guest.family == .linux,
                  request.backend == .doryHypervisor
                    || request.backend == .appleVirtualizationFramework else {
                return unavailable(
                    tier: tier,
                    code: .gracefulShutdownUnsupported,
                    message: "The selected guest/backend contract does not implement graceful shutdown."
                )
            }
        }
        if devices.intelApplicationTranslation {
            guard request.guest.family == .linux,
                  request.backend == .appleVirtualizationFramework,
                  host.linuxIntelApplicationTranslationAvailable == true else {
                return unavailable(
                    tier: tier,
                    code: .intelApplicationTranslationUnavailable,
                    message: "Intel Linux application translation is not installed or is unavailable for the selected guest/backend contract."
                )
            }
        }
        if devices.removableUSBHotplug,
           !(request.guest.family == .linux && request.backend == .doryHypervisor) {
            return unavailable(
                tier: tier,
                code: .removableUSBHotplugUnsupported,
                message: "The selected guest/backend contract does not implement removable USB hotplug."
            )
        }
        return nil
    }

    private static func guestImageGraphicsQualificationFailure(
        for request: DoryVirtualMachineCapabilityRequest,
        trustedQualification: DoryTrustedGuestImageGraphicsQualification?
    ) -> DoryCapabilityAvailability? {
        guard request.guest.family == .linux,
              request.backend == .doryHypervisor,
              request.graphics != .none else {
            return nil
        }
        guard let selectedArtifactSHA256 = request.bootMedia.artifactSHA256 else {
            return unavailable(
                tier: .supported,
                code: .guestImageArtifactDigestUnavailable,
                message: "The selected Linux guest artifact has no content-addressed SHA-256 identity."
            )
        }
        guard let qualification = trustedQualification else {
            return unavailable(
                tier: .supported,
                code: .trustedGuestImageGraphicsQualificationUnavailable,
                message: "The daemon has no trusted signed graphics qualification for this Linux guest artifact."
            )
        }
        guard signedEvidenceIsValid(qualification.auditEvidence) else {
            return unavailable(
                tier: .supported,
                code: .guestImageQualificationAuditEvidenceInvalid,
                message: "The guest graphics qualification has incomplete signed-manifest audit evidence."
            )
        }
        guard qualification.auditEvidence.artifactSHA256.lowercased()
                == selectedArtifactSHA256.lowercased() else {
            return unavailable(
                tier: .supported,
                code: .guestImageArtifactQualificationMismatch,
                message: "The signed graphics qualification does not match the selected guest artifact."
            )
        }
        guard qualification.virtioGPUKernelAndDeviceSupportQualified else {
            return unavailable(
                tier: .supported,
                code: .linuxVirtioGPUKernelDeviceUnqualified,
                message: "The Linux kernel and image are not qualified for Dory's virtio-gpu device contract."
            )
        }
        guard request.graphics != .hardwareAccelerated3D
                || qualification.venusVulkanGuestRuntimeQualified else {
            return unavailable(
                tier: .supported,
                code: .linuxVenusVulkanRuntimeUnqualified,
                message: "The Linux image's Venus and Vulkan guest runtime has not passed qualification."
            )
        }
        return nil
    }

    private static func graphicsAuditEvidence(
        for request: DoryVirtualMachineCapabilityRequest,
        trustedQualification: DoryTrustedGuestImageGraphicsQualification?
    ) -> DorySignedArtifactQualificationEvidence? {
        guard request.guest.family == .linux,
              request.backend == .doryHypervisor,
              request.graphics != .none else {
            return nil
        }
        return trustedQualification?.auditEvidence
    }

    private static func bootMediaAuditEvidence(
        for request: DoryVirtualMachineCapabilityRequest,
        trustedInspection: DoryTrustedBootMediaInspection?
    ) -> DoryBootMediaInspectionAuditEvidence? {
        guard request.bootMedia.kind == .installerISO
                || request.bootMedia.kind == .macOSRestoreImage else {
            return nil
        }
        return trustedInspection?.auditEvidence
    }

    private static func mutableBootMediaProvenanceAuditEvidence(
        for request: DoryVirtualMachineCapabilityRequest,
        trustedProvenance: DoryTrustedMutableBootMediaProvenance?
    ) -> DoryMutableBootMediaProvenanceAuditEvidence? {
        guard request.bootMedia.kind == .virtualDisk else { return nil }
        return trustedProvenance?.auditEvidence
    }

    private static func signedEvidenceIsValid(
        _ evidence: DorySignedArtifactQualificationEvidence
    ) -> Bool {
        !evidence.manifestIdentity.isEmpty
            && isSHA256(evidence.artifactSHA256)
            && isSHA256(evidence.manifestSHA256)
            && !evidence.signingKeyID.isEmpty
            && evidence.manifestFormatVersion > 0
    }

    private static func bootMediaInspectionEvidenceIsValid(
        _ evidence: DoryBootMediaInspectionAuditEvidence
    ) -> Bool {
        guard !evidence.inspectionIdentity.isEmpty,
              isSHA256(evidence.artifactSHA256),
              isSHA256(evidence.inspectionReportSHA256),
              !evidence.inspectorID.isEmpty,
              evidence.inspectorVersion > 0 else {
            return false
        }
        guard let manifest = evidence.catalogManifestEvidence else { return true }
        return signedEvidenceIsValid(manifest)
            && manifest.artifactSHA256.lowercased() == evidence.artifactSHA256.lowercased()
    }

    private static func mutableProvenanceIsValid(
        _ provenance: DoryMutableBootMediaProvenanceReference
    ) -> Bool {
        !provenance.repositoryIdentity.isEmpty
            && !provenance.mediaIdentity.isEmpty
            && provenance.revision > 0
    }

    private static func mutableProvenanceEvidenceIsValid(
        _ evidence: DoryMutableBootMediaProvenanceAuditEvidence
    ) -> Bool {
        !evidence.receiptIdentity.isEmpty
            && mutableProvenanceIsValid(evidence.provenance)
            && isSHA256(evidence.receiptSHA256)
            && !evidence.resolverID.isEmpty
            && evidence.resolverVersion > 0
    }

    private static func runtimeQualificationEvidenceIsValid(
        _ evidence: DoryVirtualMachineRuntimeQualificationEvidence
    ) -> Bool {
        let mediaBindingCount = (evidence.immutableArtifactSHA256 == nil ? 0 : 1)
            + (evidence.mutableProvenance == nil ? 0 : 1)
        let immutableArtifactIsValid = evidence.immutableArtifactSHA256.map(isSHA256) ?? true
        let mutableProvenanceIsValid = evidence.mutableProvenance.map(Self.mutableProvenanceIsValid)
            ?? true
        return !evidence.qualificationIdentity.isEmpty
            && isSHA256(evidence.qualificationReportSHA256)
            && !evidence.signingKeyID.isEmpty
            && evidence.qualificationFormatVersion > 0
            && mediaBindingCount == 1
            && immutableArtifactIsValid
            && mutableProvenanceIsValid
            && !evidence.backendRuntimeBuildID.isEmpty
            && evidence.virtualHardwareABIVersion > 0
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func windowsDriverAvailabilityFailure(
        _ drivers: DoryWindowsGuestDriverFacts,
        tier: DoryCapabilitySupportTier
    ) -> DoryCapabilityAvailability? {
        guard drivers.storageAvailable else {
            return unavailable(
                tier: tier,
                code: .windowsStorageDriverUnavailable,
                message: "A qualified Windows ARM64 storage driver is required."
            )
        }
        guard drivers.networkAvailable else {
            return unavailable(
                tier: tier,
                code: .windowsNetworkDriverUnavailable,
                message: "A qualified Windows ARM64 network driver is required."
            )
        }
        guard drivers.displayAvailable else {
            return unavailable(
                tier: tier,
                code: .windowsDisplayDriverUnavailable,
                message: "A qualified Windows ARM64 display driver is required."
            )
        }
        guard drivers.inputAvailable else {
            return unavailable(
                tier: tier,
                code: .windowsInputDriverUnavailable,
                message: "Qualified Windows ARM64 input drivers are required."
            )
        }
        return nil
    }

    private static func unsupported(
        _ code: DoryCapabilityReasonCode,
        _ message: String
    ) -> DoryCapabilityAvailability {
        DoryCapabilityAvailability(
            supportTier: .unsupported,
            state: .unavailable,
            reason: DoryCapabilityReason(code: code, message: message)
        )
    }

    private static func unavailable(
        tier: DoryCapabilitySupportTier,
        code: DoryCapabilityReasonCode,
        message: String
    ) -> DoryCapabilityAvailability {
        DoryCapabilityAvailability(
            supportTier: tier,
            state: .unavailable,
            reason: DoryCapabilityReason(code: code, message: message)
        )
    }
}
