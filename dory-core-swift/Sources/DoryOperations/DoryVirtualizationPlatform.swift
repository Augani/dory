import Foundation

/// The physical host ISA admitted by the three-cell virtualization product.
public enum DoryHostArchitecture: String, Codable, Sendable, CaseIterable, Hashable {
    case arm64
    case x86_64
    case unsupported

    /// ISA of the running Dory process. Apple Silicon product binaries are ARM64; an Intel
    /// host is rejected before inventory, download, or disk mutation.
    public static var current: DoryHostArchitecture {
#if arch(arm64)
        .arm64
#elseif arch(x86_64)
        .x86_64
#else
        .unsupported
#endif
    }
}

/// The three product cells this programme implements. Any other host/guest pair is rejected.
public enum DoryProductCell: String, Codable, Sendable, CaseIterable, Hashable {
    case linuxARM64Native = "linux-arm64-native"
    case linuxX86_64Translated = "linux-x86_64-translated"
    case macOSARM64VZMac = "macos-arm64-vzmac"

    public var platform: DoryVirtualizationPlatformComposition {
        switch self {
        case .linuxARM64Native: .arm64LinuxV1
        case .linuxX86_64Translated: .x86_64LinuxV1
        case .macOSARM64VZMac: .arm64MacOSV1
        }
    }

    public var executionClass: DoryExecutionClass {
        switch self {
        case .linuxARM64Native, .macOSARM64VZMac: .native
        case .linuxX86_64Translated: .translated
        }
    }

    /// Production backend identity for this cell. Linux ARM and Linux x86 share the Dory
    /// hypervisor helper; the cell/platform composition distinguishes ARMVirt from DoryPC.
    public var backendIdentity: DoryVirtualizationBackendIdentity {
        switch self {
        case .linuxARM64Native, .linuxX86_64Translated: .doryHypervisor
        case .macOSARM64VZMac: .appleVirtualizationFramework
        }
    }

    public var requiredComponents: [DoryVirtualizationComponentIdentity] {
        switch self {
        case .linuxARM64Native: [.nativeARM64Engine, .armVirtFirmware]
        case .linuxX86_64Translated: [.x86ToARM64Translator, .pcFirmware]
        case .macOSARM64VZMac: []
        }
    }
}

/// Requested guest ISA, inspected media ISA, host ISA, and the pinned execution composition.
/// A template label or filename is not a substitute for these fields.
public struct DoryVirtualMachineArchitectureFacts: Codable, Sendable, Equatable, Hashable {
    public var hostArchitecture: DoryHostArchitecture
    public var requestedGuestArchitecture: DoryGuestArchitecture
    public var detectedMediaArchitecture: DoryGuestArchitecture?
    public var cpuProfile: DoryCPUProfileIdentity
    public var machineABI: DoryMachineModelIdentity
    public var executionTier: DoryExecutionClass
    public var productCell: DoryProductCell

    public init(
        hostArchitecture: DoryHostArchitecture,
        requestedGuestArchitecture: DoryGuestArchitecture,
        detectedMediaArchitecture: DoryGuestArchitecture?,
        cpuProfile: DoryCPUProfileIdentity,
        machineABI: DoryMachineModelIdentity,
        executionTier: DoryExecutionClass,
        productCell: DoryProductCell
    ) {
        self.hostArchitecture = hostArchitecture
        self.requestedGuestArchitecture = requestedGuestArchitecture
        self.detectedMediaArchitecture = detectedMediaArchitecture
        self.cpuProfile = cpuProfile
        self.machineABI = machineABI
        self.executionTier = executionTier
        self.productCell = productCell
    }

    public static func resolving(
        hostArchitecture: DoryHostArchitecture,
        guest: DoryGuestPlatform,
        detectedMediaArchitecture: DoryGuestArchitecture?,
        cell: DoryProductCell
    ) -> Self {
        let platform = cell.platform
        return Self(
            hostArchitecture: hostArchitecture,
            requestedGuestArchitecture: guest.architecture,
            detectedMediaArchitecture: detectedMediaArchitecture,
            cpuProfile: platform.cpuProfile,
            machineABI: platform.machineModel,
            executionTier: cell.executionClass,
            productCell: cell
        )
    }
}

/// Single executable three-cell table. Call this before component download or disk mutation.
public enum DoryVirtualizationProductPolicy {
    public static func cell(
        hostArchitecture: DoryHostArchitecture,
        guest: DoryGuestPlatform
    ) -> Result<DoryProductCell, DoryVirtualizationResolutionError> {
        guard hostArchitecture == .arm64 else {
            return .failure(.unsupportedHostArchitecture(hostArchitecture))
        }
        switch (guest.family, guest.architecture) {
        case (.linux, .arm64):
            return .success(.linuxARM64Native)
        case (.linux, .x86_64):
            return .success(.linuxX86_64Translated)
        case (.macOS, .arm64):
            return .success(.macOSARM64VZMac)
        case (.macOS, .x86_64):
            return .failure(.unsupportedGuestArchitecture(.x86_64))
        case (.windows, _):
            return .failure(.unsupportedGuestFamily(.windows))
        }
    }

    public static func defaultBackends(
        hostArchitecture: DoryHostArchitecture,
        guest: DoryGuestPlatform
    ) -> [DoryVirtualizationBackendIdentity] {
        switch cell(hostArchitecture: hostArchitecture, guest: guest) {
        case let .success(cell):
            [cell.backendIdentity]
        case .failure:
            []
        }
    }
}

/// CPU execution is deliberately independent from the guest-visible machine model.
public enum DoryExecutionEngineIdentity: String, Codable, Sendable, CaseIterable, Hashable {
    case nativeARM64 = "dory.native-hv.arm64@1"
    case x86ToARM64 = "dory.dbt.x86-to-arm64@1"
    case vzMac = "dory.vzmac@1"
}

public enum DoryCPUProfileIdentity: String, Codable, Sendable, CaseIterable, Hashable {
    case genericARM64V1 = "dory.arm64.generic-v1"
    case compatibleX8664V1 = "dory.x86_64.compat-v1"
    case appleSiliconMacV1 = "apple.vzmac.arm64-v1"
    case intelMacV1 = "dory.x86_64.intel-mac-v1"
}

public enum DoryMachineModelIdentity: String, Codable, Sendable, CaseIterable, Hashable {
    case armVirtV1 = "dory.armvirt@1"
    case pcV1 = "dory.pc@1"
    case appleVZMacV1 = "apple.vzmac@1"
    case intelMacV1 = "dory.intelmac@1"
}

public enum DoryFirmwareABIIdentity: String, Codable, Sendable, CaseIterable, Hashable {
    case armVirtV1 = "dory.edk2.armvirt@1"
    case pcV1 = "dory.edk2.pc@1"
    case appleVZMacV1 = "apple.vzmac.platform@1"
    case intelMacV1 = "dory.edk2.intelmac@1"
}

public enum DoryDeviceABIIdentity: String, Codable, Sendable, CaseIterable, Hashable {
    case virtioV1 = "dory.virtio@1"
    case appleVZMacV1 = "apple.vzmac.devices@1"
    case intelMacV1 = "dory.intelmac.devices@1"
}

public enum DorySnapshotFormatIdentity: String, Codable, Sendable, CaseIterable, Hashable {
    case vmStateV1 = "dory.vmstate@1"
    case appleVZMacV1 = "apple.vzmac.vmstate@1"
}

public enum DoryTranslationConsent: String, Codable, Sendable, CaseIterable, Hashable {
    case notRequired = "not-required"
    case explicit
}

public enum DoryExecutionClass: String, Codable, Sendable, CaseIterable, Hashable {
    case native
    case translated
}

/// Stable optional-component identities. Absence is reported; it never changes the route.
public enum DoryVirtualizationComponentIdentity: String, Codable, Sendable, CaseIterable, Hashable {
    case nativeARM64Engine = "dory.component.native-hv.arm64@1"
    case x86ToARM64Translator = "dory.component.dbt.x86-to-arm64@1"
    case armVirtFirmware = "dory.component.firmware.armvirt@1"
    case pcFirmware = "dory.component.firmware.pc@1"
    case intelMacFirmware = "dory.component.firmware.intelmac@1"
}

public struct DoryVirtualizationPlatformComposition: Codable, Sendable, Equatable, Hashable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var executionEngine: DoryExecutionEngineIdentity
    public var cpuProfile: DoryCPUProfileIdentity
    public var machineModel: DoryMachineModelIdentity
    public var firmwareABI: DoryFirmwareABIIdentity
    public var deviceABI: DoryDeviceABIIdentity
    public var snapshotFormat: DorySnapshotFormatIdentity

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        executionEngine: DoryExecutionEngineIdentity,
        cpuProfile: DoryCPUProfileIdentity,
        machineModel: DoryMachineModelIdentity,
        firmwareABI: DoryFirmwareABIIdentity,
        deviceABI: DoryDeviceABIIdentity,
        snapshotFormat: DorySnapshotFormatIdentity
    ) {
        self.schemaVersion = schemaVersion
        self.executionEngine = executionEngine
        self.cpuProfile = cpuProfile
        self.machineModel = machineModel
        self.firmwareABI = firmwareABI
        self.deviceABI = deviceABI
        self.snapshotFormat = snapshotFormat
    }

    public static let arm64LinuxV1 = DoryVirtualizationPlatformComposition(
        executionEngine: .nativeARM64,
        cpuProfile: .genericARM64V1,
        machineModel: .armVirtV1,
        firmwareABI: .armVirtV1,
        deviceABI: .virtioV1,
        snapshotFormat: .vmStateV1
    )

    public static let x86_64LinuxV1 = DoryVirtualizationPlatformComposition(
        executionEngine: .x86ToARM64,
        cpuProfile: .compatibleX8664V1,
        machineModel: .pcV1,
        firmwareABI: .pcV1,
        deviceABI: .virtioV1,
        snapshotFormat: .vmStateV1
    )

    public static let arm64MacOSV1 = DoryVirtualizationPlatformComposition(
        executionEngine: .vzMac,
        cpuProfile: .appleSiliconMacV1,
        machineModel: .appleVZMacV1,
        firmwareABI: .appleVZMacV1,
        deviceABI: .appleVZMacV1,
        snapshotFormat: .appleVZMacV1
    )

    public static let x86_64MacOSV1 = DoryVirtualizationPlatformComposition(
        executionEngine: .x86ToARM64,
        cpuProfile: .intelMacV1,
        machineModel: .intelMacV1,
        firmwareABI: .intelMacV1,
        deviceABI: .intelMacV1,
        snapshotFormat: .vmStateV1
    )
}

public struct DoryVirtualizationResolutionRequest: Sendable, Equatable, Hashable {
    public var hostArchitecture: DoryHostArchitecture
    public var guest: DoryGuestPlatform
    public var translationConsent: DoryTranslationConsent
    public var readyComponents: Set<DoryVirtualizationComponentIdentity>

    public init(
        hostArchitecture: DoryHostArchitecture,
        guest: DoryGuestPlatform,
        translationConsent: DoryTranslationConsent = .notRequired,
        readyComponents: Set<DoryVirtualizationComponentIdentity> = []
    ) {
        self.hostArchitecture = hostArchitecture
        self.guest = guest
        self.translationConsent = translationConsent
        self.readyComponents = readyComponents
    }
}

public struct DoryVirtualizationResolution: Codable, Sendable, Equatable, Hashable {
    public var guest: DoryGuestPlatform
    public var platform: DoryVirtualizationPlatformComposition
    public var executionClass: DoryExecutionClass
    public var supportState: DoryCapabilitySupportTier
    public var requiredComponents: [DoryVirtualizationComponentIdentity]
    public var missingComponents: [DoryVirtualizationComponentIdentity]

    public init(
        guest: DoryGuestPlatform,
        platform: DoryVirtualizationPlatformComposition,
        executionClass: DoryExecutionClass,
        supportState: DoryCapabilitySupportTier,
        requiredComponents: [DoryVirtualizationComponentIdentity],
        missingComponents: [DoryVirtualizationComponentIdentity]
    ) {
        self.guest = guest
        self.platform = platform
        self.executionClass = executionClass
        self.supportState = supportState
        self.requiredComponents = requiredComponents
        self.missingComponents = missingComponents
    }
}

public enum DoryVirtualizationResolutionError: Error, Codable, Sendable, Equatable, Hashable {
    case unsupportedHostArchitecture(DoryHostArchitecture)
    case unsupportedGuestFamily(DoryGuestFamily)
    case unsupportedGuestArchitecture(DoryGuestArchitecture)
    case translationConsentRequired(DoryGuestArchitecture)

    public var reasonCode: DoryCapabilityReasonCode {
        switch self {
        case .unsupportedHostArchitecture:
            .unsupportedHostArchitecture
        case .unsupportedGuestFamily:
            .backendDoesNotSupportGuest
        case .unsupportedGuestArchitecture:
            .unsupportedGuestArchitecture
        case .translationConsentRequired:
            .translationConsentRequired
        }
    }
}

/// Pure, deterministic three-cell resolver. It performs no downloads, allocation, conversion,
/// persistence, or runner launch, so the host boundary is enforced before all mutation.
public enum DoryVirtualizationPlatformResolver {
    public static func resolve(
        _ request: DoryVirtualizationResolutionRequest
    ) -> Result<DoryVirtualizationResolution, DoryVirtualizationResolutionError> {
        switch DoryVirtualizationProductPolicy.cell(
            hostArchitecture: request.hostArchitecture,
            guest: request.guest
        ) {
        case let .failure(error):
            return .failure(error)
        case let .success(cell):
            if request.guest.architecture == .x86_64,
               request.translationConsent != .explicit {
                return .failure(.translationConsentRequired(.x86_64))
            }
            let missing = cell.requiredComponents.filter {
                !request.readyComponents.contains($0)
            }
            return .success(DoryVirtualizationResolution(
                guest: request.guest,
                platform: cell.platform,
                executionClass: cell.executionClass,
                supportState: .research,
                requiredComponents: cell.requiredComponents,
                missingComponents: missing
            ))
        }
    }
}
