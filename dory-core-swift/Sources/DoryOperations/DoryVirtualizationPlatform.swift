import Foundation

/// The physical host ISA admitted by the four-cell virtualization product.
public enum DoryHostArchitecture: String, Codable, Sendable, CaseIterable, Hashable {
    case arm64
    case x86_64
    case unsupported
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
    case translationConsentRequired(DoryGuestArchitecture)

    public var reasonCode: DoryCapabilityReasonCode {
        switch self {
        case .unsupportedHostArchitecture:
            .unsupportedHostArchitecture
        case .unsupportedGuestFamily:
            .backendDoesNotSupportGuest
        case .translationConsentRequired:
            .translationConsentRequired
        }
    }
}

/// Pure, deterministic four-cell resolver. It performs no downloads, allocation, conversion,
/// persistence, or runner launch, so the host boundary is enforced before all mutation.
public enum DoryVirtualizationPlatformResolver {
    public static func resolve(
        _ request: DoryVirtualizationResolutionRequest
    ) -> Result<DoryVirtualizationResolution, DoryVirtualizationResolutionError> {
        guard request.hostArchitecture == .arm64 else {
            return .failure(.unsupportedHostArchitecture(request.hostArchitecture))
        }
        guard request.guest.family == .linux || request.guest.family == .macOS else {
            return .failure(.unsupportedGuestFamily(request.guest.family))
        }
        if request.guest.architecture == .x86_64,
           request.translationConsent != .explicit {
            return .failure(.translationConsentRequired(.x86_64))
        }

        let route = route(for: request.guest)
        let missing = route.requiredComponents.filter {
            !request.readyComponents.contains($0)
        }
        return .success(DoryVirtualizationResolution(
            guest: request.guest,
            platform: route.platform,
            executionClass: request.guest.architecture == .arm64 ? .native : .translated,
            // All four new platform ABIs remain research until their phase gates pass.
            supportState: .research,
            requiredComponents: route.requiredComponents,
            missingComponents: missing
        ))
    }

    private static func route(
        for guest: DoryGuestPlatform
    ) -> (
        platform: DoryVirtualizationPlatformComposition,
        requiredComponents: [DoryVirtualizationComponentIdentity]
    ) {
        switch (guest.family, guest.architecture) {
        case (.linux, .arm64):
            return (
                .arm64LinuxV1,
                [.nativeARM64Engine, .armVirtFirmware]
            )
        case (.linux, .x86_64):
            return (
                .x86_64LinuxV1,
                [.x86ToARM64Translator, .pcFirmware]
            )
        case (.macOS, .arm64):
            return (
                .arm64MacOSV1,
                []
            )
        case (.macOS, .x86_64):
            return (
                .x86_64MacOSV1,
                [.x86ToARM64Translator, .intelMacFirmware]
            )
        case (.windows, _):
            preconditionFailure("Unsupported families are rejected before route selection.")
        }
    }
}
