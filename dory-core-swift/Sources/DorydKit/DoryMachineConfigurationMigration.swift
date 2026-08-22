import CryptoKit
import DoryOperations
import Foundation

/// Explicit evidence needed to project legacy machine metadata without consulting host globals
/// or guessing from mutable files while migration is in progress.
public struct DoryMachineConfigurationMigrationFacts: Sendable, Equatable {
    public var guestArchitecture: DoryGuestArchitecture
    /// Logical capacity of the legacy root disk. Persisted configurations normally no longer
    /// contain `diskSizeBytes`, so the repository or artifact inspector must supply this fact.
    public var systemDiskCapacityBytes: UInt64?
    /// Required only for an installed EFI machine whose installer is no longer attached.
    public var installedEFIBoot: DoryMachineConfigurationInstalledEFIBoot?
    public var lifecycle: DoryVMLifecycleMetadata

    public init(
        guestArchitecture: DoryGuestArchitecture,
        systemDiskCapacityBytes: UInt64? = nil,
        installedEFIBoot: DoryMachineConfigurationInstalledEFIBoot? = nil,
        lifecycle: DoryVMLifecycleMetadata
    ) {
        self.guestArchitecture = guestArchitecture
        self.systemDiskCapacityBytes = systemDiskCapacityBytes
        self.installedEFIBoot = installedEFIBoot
        self.lifecycle = lifecycle
    }
}

/// The two installed-EFI arrangements supported by today's MachineManager.
public enum DoryMachineConfigurationInstalledEFIBoot: String, Codable, Sendable, Equatable {
    /// UEFI loads the installed system directly from its virtual disk.
    case firmwareDisk = "firmware-disk"
    /// Dory's verified kernel/initrd/root-device bundle launches the installed disk directly.
    case installedLinuxBootBundle = "installed-linux-boot-bundle"
}

/// The exact legacy boot ABI represented by a migration result.
public enum DoryMachineConfigurationLegacyBootContract: String, Codable, Sendable, Equatable {
    case managedDirectKernel = "managed-direct-kernel"
    case efiInstaller = "efi-installer"
    case efiFirmwareDisk = "efi-firmware-disk"
    case efiInstalledDirectBoot = "efi-installed-direct-boot"
}

public enum DoryMachineConfigurationArtifactRole: String, Codable, Sendable, Equatable, Hashable {
    case kernel
    case systemDisk = "system-disk"
    case installerISO = "installer-iso"
}

/// Transitional resolver binding. It is intentionally not part of WorkspaceSpec persistence:
/// paths remain under the legacy metadata authority until an artifact repository owns them.
public struct DoryMachineConfigurationArtifactBinding: Sendable, Equatable {
    public var role: DoryMachineConfigurationArtifactRole
    public var reference: DoryVMResolverReference
    public var path: String

    public init(
        role: DoryMachineConfigurationArtifactRole,
        reference: DoryVMResolverReference,
        path: String
    ) {
        self.role = role
        self.reference = reference
        self.path = path
    }
}

/// Transitional host-share binding kept outside the path-hostile WorkspaceSpec.
public struct DoryMachineConfigurationShareBinding: Sendable, Equatable {
    public var reference: DoryVMResolverReference
    public var hostPath: String
    public var authorizationBookmark: Data?
    public var authorizationVolumeUUID: String?
    public var authorizationFileIdentifier: Data?

    public init(
        reference: DoryVMResolverReference,
        hostPath: String,
        authorizationBookmark: Data? = nil,
        authorizationVolumeUUID: String? = nil,
        authorizationFileIdentifier: Data? = nil
    ) {
        self.reference = reference
        self.hostPath = hostPath
        self.authorizationBookmark = authorizationBookmark
        self.authorizationVolumeUUID = authorizationVolumeUUID
        self.authorizationFileIdentifier = authorizationFileIdentifier
    }
}

public enum DoryMachineConfigurationMigrationError: Error, Sendable, Equatable, LocalizedError {
    case invalidLegacyPayload
    case invalidLegacyPreference(String)
    case invalidLegacyConfiguration(String)
    case missingSystemDiskCapacity
    case conflictingSystemDiskCapacity(configured: UInt64, inspected: UInt64)
    case missingInstalledEFIBootFact
    case invalidDefinition([DoryVMDefinitionValidationIssue])
    case unsupportedDefinitionChange(String)
    case resourceNotRepresentable(String)
    case unresolvedArtifact(DoryVMResolverReference)
    case unresolvedShare(DoryVMResolverReference)

    public var errorDescription: String? {
        switch self {
        case .invalidLegacyPayload:
            "Legacy machine configuration JSON is invalid."
        case let .invalidLegacyPreference(key):
            "Legacy runtime preference \(key) is invalid."
        case let .invalidLegacyConfiguration(reason):
            "Legacy machine configuration is not migration-safe: \(reason)"
        case .missingSystemDiskCapacity:
            "The legacy root disk capacity must be supplied explicitly."
        case let .conflictingSystemDiskCapacity(configured, inspected):
            "Configured disk capacity \(configured) does not match supplied capacity \(inspected)."
        case .missingInstalledEFIBootFact:
            "Installed EFI boot requires an explicit firmware-disk or direct-boot-bundle fact."
        case let .invalidDefinition(issues):
            "Projected workspace definition is invalid: "
                + issues.map { "\($0.code.rawValue) at \($0.field)" }.joined(separator: ", ")
        case let .unsupportedDefinitionChange(field):
            "The legacy machine format cannot represent the workspace change at \(field)."
        case let .resourceNotRepresentable(field):
            "The workspace resource cannot be represented by legacy field \(field)."
        case let .unresolvedArtifact(reference):
            "No legacy artifact binding exists for \(reference.namespace):\(reference.identifier)."
        case let .unresolvedShare(reference):
            "No legacy share binding exists for \(reference.namespace):\(reference.identifier)."
        }
    }
}

/// A lossless in-memory bridge while `machine.json` remains authoritative.
///
/// `definition` is safe for WorkspaceSpec persistence. The authoritative legacy configuration
/// and path bindings are deliberately non-Codable so a workspace record cannot accidentally copy
/// host paths, environment secrets, or other compatibility-only state.
public struct DoryMachineConfigurationMigrationResult: Sendable, Equatable {
    public var definition: DoryVirtualMachineDefinition
    public let bootContract: DoryMachineConfigurationLegacyBootContract
    public let artifactBindings: [DoryMachineConfigurationArtifactBinding]
    public let shareBindings: [DoryMachineConfigurationShareBinding]

    private let authoritativeLegacyConfiguration: DoryMachineConfiguration
    private let baselineDefinition: DoryVirtualMachineDefinition

    fileprivate init(
        definition: DoryVirtualMachineDefinition,
        bootContract: DoryMachineConfigurationLegacyBootContract,
        artifactBindings: [DoryMachineConfigurationArtifactBinding],
        shareBindings: [DoryMachineConfigurationShareBinding],
        authoritativeLegacyConfiguration: DoryMachineConfiguration
    ) {
        self.definition = definition
        self.bootContract = bootContract
        self.artifactBindings = artifactBindings
        self.shareBindings = shareBindings
        self.authoritativeLegacyConfiguration = authoritativeLegacyConfiguration
        baselineDefinition = definition
    }

    public func artifactPath(for reference: DoryVMResolverReference) -> String? {
        artifactBindings.first { $0.reference == reference }?.path
    }

    public func hostPath(for reference: DoryVMResolverReference) -> String? {
        shareBindings.first { $0.reference == reference }?.hostPath
    }

    public func shareBinding(
        for reference: DoryVMResolverReference
    ) -> DoryMachineConfigurationShareBinding? {
        shareBindings.first { $0.reference == reference }
    }

    /// Reconstruct the legacy projection. Unsupported v2-only changes fail rather than being
    /// silently dropped, while fields represented by both contracts are written from typed v2
    /// values. An untouched definition reconstructs an equal legacy value and canonical bytes.
    public func legacyConfiguration() throws -> DoryMachineConfiguration {
        let issues = definition.validate()
        guard issues.isEmpty else {
            throw DoryMachineConfigurationMigrationError.invalidDefinition(issues)
        }
        guard definition.identity.id == baselineDefinition.identity.id else {
            throw DoryMachineConfigurationMigrationError.unsupportedDefinitionChange("identity.id")
        }
        guard definition.identity.name == baselineDefinition.identity.name else {
            throw DoryMachineConfigurationMigrationError.unsupportedDefinitionChange("identity.name")
        }
        guard definition.guest == baselineDefinition.guest else {
            throw DoryMachineConfigurationMigrationError.unsupportedDefinitionChange("guest")
        }
        guard definition.workload == baselineDefinition.workload else {
            throw DoryMachineConfigurationMigrationError.unsupportedDefinitionChange("workload")
        }
        guard definition.boot == baselineDefinition.boot else {
            throw DoryMachineConfigurationMigrationError.unsupportedDefinitionChange("boot")
        }
        guard definition.networkMode == baselineDefinition.networkMode else {
            throw DoryMachineConfigurationMigrationError.unsupportedDefinitionChange("networkMode")
        }
        guard definition.display == baselineDefinition.display else {
            throw DoryMachineConfigurationMigrationError.unsupportedDefinitionChange("display")
        }
        guard definition.audio == baselineDefinition.audio else {
            throw DoryMachineConfigurationMigrationError.unsupportedDefinitionChange("audio")
        }
        guard definition.input == baselineDefinition.input else {
            throw DoryMachineConfigurationMigrationError.unsupportedDefinitionChange("input")
        }
        guard definition.integrations == baselineDefinition.integrations else {
            throw DoryMachineConfigurationMigrationError.unsupportedDefinitionChange("integrations")
        }
        guard definition.storage.count == 1,
              definition.storage[0].id == baselineDefinition.storage[0].id,
              definition.storage[0].role == .system,
              !definition.storage[0].readOnly,
              artifactPath(for: definition.storage[0].artifact) != nil else {
            if let attachment = definition.storage.first,
               artifactPath(for: attachment.artifact) == nil {
                throw DoryMachineConfigurationMigrationError.unresolvedArtifact(attachment.artifact)
            }
            throw DoryMachineConfigurationMigrationError.unsupportedDefinitionChange("storage")
        }

        guard definition.resources.virtualCPUCount <= UInt64(Int.max) else {
            throw DoryMachineConfigurationMigrationError.resourceNotRepresentable("cpuCount")
        }
        let mebibyte: UInt64 = 1_048_576
        guard definition.resources.memoryBytes > 0,
              definition.resources.memoryBytes % mebibyte == 0 else {
            throw DoryMachineConfigurationMigrationError.resourceNotRepresentable("memoryMB")
        }
        let memoryMB = definition.resources.memoryBytes / mebibyte
        let cpuCount = Int(definition.resources.virtualCPUCount)

        var diskSizeBytes = authoritativeLegacyConfiguration.diskSizeBytes
        if diskSizeBytes != nil {
            diskSizeBytes = definition.storage[0].capacityBytes
        } else if definition.storage[0].capacityBytes != baselineDefinition.storage[0].capacityBytes
                    || definition.resources.diskBytes != baselineDefinition.resources.diskBytes {
            throw DoryMachineConfigurationMigrationError.unsupportedDefinitionChange(
                "resources.diskBytes"
            )
        }
        guard definition.resources.diskBytes == definition.storage[0].capacityBytes else {
            throw DoryMachineConfigurationMigrationError.unsupportedDefinitionChange(
                "storage[0].capacityBytes"
            )
        }

        var environment = authoritativeLegacyConfiguration.environment
        try applyBackendPreference(to: &environment)
        try applyGraphicsPolicy(to: &environment)
        try applyGuestIdentityIntent(to: &environment)
        try applyClipboardPolicy(to: &environment)
        try applySandboxPolicy(to: &environment)

        let shares = try definition.shares.map { share -> DoryMachineShareConfiguration in
            guard let binding = shareBinding(for: share.hostLocation) else {
                throw DoryMachineConfigurationMigrationError.unresolvedShare(share.hostLocation)
            }
            let migrated = DoryMachineShareConfiguration(
                tag: share.id,
                hostPath: binding.hostPath,
                guestPath: share.guestMountPath,
                readOnly: share.readOnly,
                authorizationBookmark: binding.authorizationBookmark,
                authorizationVolumeUUID: binding.authorizationVolumeUUID,
                authorizationFileIdentifier: binding.authorizationFileIdentifier
            )
            do {
                try migrated.validate()
            } catch {
                throw DoryMachineConfigurationMigrationError.unsupportedDefinitionChange("shares")
            }
            return migrated
        }

        return DoryMachineConfiguration(
            id: definition.identity.id,
            kernelPath: authoritativeLegacyConfiguration.kernelPath,
            rootfsPath: authoritativeLegacyConfiguration.rootfsPath,
            bootMode: authoritativeLegacyConfiguration.bootMode,
            installerISOPath: authoritativeLegacyConfiguration.installerISOPath,
            diskSizeBytes: diskSizeBytes,
            memoryMB: memoryMB,
            cpuCount: cpuCount,
            address: authoritativeLegacyConfiguration.address,
            displayMode: authoritativeLegacyConfiguration.displayMode,
            shares: shares,
            environment: environment,
            installedDesktopPayloadReceipt:
                authoritativeLegacyConfiguration.installedDesktopPayloadReceipt,
            cloneReceipt: authoritativeLegacyConfiguration.cloneReceipt
        )
    }

    public func authoritativeLegacyData() throws -> Data {
        try DoryMachineConfigurationMigrationBridge.encodeLegacy(legacyConfiguration())
    }

    private func applyBackendPreference(to environment: inout [String: String]) throws {
        guard definition.backendPreference != baselineDefinition.backendPreference else { return }
        guard bootContract == .managedDirectKernel || bootContract == .efiInstalledDirectBoot,
              authoritativeLegacyConfiguration.displayMode == .desktop else {
            throw DoryMachineConfigurationMigrationError.unsupportedDefinitionChange(
                "backendPreference"
            )
        }
        let raw: String
        switch (definition.backendPreference.mode, definition.backendPreference.backend) {
        case (.automatic, nil):
            raw = DoryDesktopVMMPreference.automatic.rawValue
        case (.preferred, .doryHypervisor?):
            raw = DoryDesktopVMMPreference.accelerated.rawValue
        case (.preferred, .appleVirtualizationFramework?):
            raw = DoryDesktopVMMPreference.compatible.rawValue
        default:
            throw DoryMachineConfigurationMigrationError.unsupportedDefinitionChange(
                "backendPreference"
            )
        }
        environment[DoryDesktopVMMPreference.environmentKey] = raw
    }

    private func applyGraphicsPolicy(to environment: inout [String: String]) throws {
        guard definition.graphics != baselineDefinition.graphics else { return }
        guard bootContract == .managedDirectKernel || bootContract == .efiInstalledDirectBoot,
              authoritativeLegacyConfiguration.displayMode == .desktop else {
            throw DoryMachineConfigurationMigrationError.unsupportedDefinitionChange("graphics")
        }
        let preference: DoryDesktopGraphicsPreference
        switch definition.graphics.acceptableLevels {
        case [.hardwareAccelerated3D, .hostAcceleratedDisplay, .software]:
            preference = .automatic
        case [.hardwareAccelerated3D]:
            preference = .virglVenus
        case [.hostAcceleratedDisplay]:
            preference = .virgl
        case [.software]:
            preference = .software
        default:
            throw DoryMachineConfigurationMigrationError.unsupportedDefinitionChange("graphics")
        }
        environment[DoryDesktopGraphicsPreference.environmentKey] = preference.rawValue
        environment.removeValue(forKey: DoryDesktopGraphicsPreference.legacyClassicOnlyEnvironmentKey)
    }

    private func applyGuestIdentityIntent(to environment: inout [String: String]) throws {
        guard definition.guestIdentityIntent != baselineDefinition.guestIdentityIntent else {
            return
        }
        guard definition.guest.family == .linux else {
            throw DoryMachineConfigurationMigrationError.unsupportedDefinitionChange(
                "guestIdentityIntent"
            )
        }
        Self.assignIfChanged(
            definition.guestIdentityIntent.account?.username,
            baseline: baselineDefinition.guestIdentityIntent.account?.username,
            key: DoryVMGuestAccountIntent.legacyUsernameEnvironmentKey,
            to: &environment
        )
        Self.assignIfChanged(
            definition.guestIdentityIntent.account?.numericUserID.map(String.init),
            baseline: baselineDefinition.guestIdentityIntent.account?.numericUserID.map(String.init),
            key: DoryVMGuestAccountIntent.legacyNumericUserIDEnvironmentKey,
            to: &environment
        )
        Self.assignIfChanged(
            definition.guestIdentityIntent.desktop?.distributionIdentifier,
            baseline: baselineDefinition.guestIdentityIntent.desktop?.distributionIdentifier,
            key: DoryVMDesktopIdentityIntent.legacyDistributionEnvironmentKey,
            to: &environment
        )
        Self.assignIfChanged(
            definition.guestIdentityIntent.desktop?.displayName,
            baseline: baselineDefinition.guestIdentityIntent.desktop?.displayName,
            key: DoryVMDesktopIdentityIntent.legacyDisplayNameEnvironmentKey,
            to: &environment
        )
        Self.assignIfChanged(
            definition.guestIdentityIntent.desktop?.version,
            baseline: baselineDefinition.guestIdentityIntent.desktop?.version,
            key: DoryVMDesktopIdentityIntent.legacyVersionEnvironmentKey,
            to: &environment
        )
        Self.assignIfChanged(
            definition.guestIdentityIntent.desktop?.desktopEnvironment,
            baseline: baselineDefinition.guestIdentityIntent.desktop?.desktopEnvironment,
            key: DoryVMDesktopIdentityIntent.legacyDesktopEnvironmentKey,
            to: &environment
        )
    }

    private func applyClipboardPolicy(to environment: inout [String: String]) throws {
        guard definition.clipboardPolicy != baselineDefinition.clipboardPolicy else { return }
        guard definition.clipboardPolicy.text == definition.clipboardPolicy.image,
              definition.clipboardPolicy.files == .off else {
            throw DoryMachineConfigurationMigrationError.unsupportedDefinitionChange(
                "clipboardPolicy"
            )
        }
        environment[DoryDesktopClipboardPolicy.environmentKey]
            = definition.clipboardPolicy.text.rawValue
    }

    private func applySandboxPolicy(to environment: inout [String: String]) throws {
        guard definition.sandboxPolicy != baselineDefinition.sandboxPolicy else { return }
        guard definition.guest.family == .linux, !definition.display.enabled else {
            throw DoryMachineConfigurationMigrationError.unsupportedDefinitionChange(
                "sandboxPolicy"
            )
        }
        let keys = [
            DoryVMSandboxPolicy.legacyMarkerEnvironmentKey,
            DoryVMSandboxPolicy.legacyExpirationEnvironmentKey,
            DoryVMSandboxPolicy.legacySSHAgentEnvironmentKey,
            DoryVMSandboxPolicy.legacyProfileEnvironmentKey,
            DoryVMSandboxPolicy.legacyToolsEnvironmentKey,
            DoryVMSandboxPolicy.legacyBaselineEnvironmentKey,
        ]
        guard let policy = definition.sandboxPolicy else {
            for key in keys { environment.removeValue(forKey: key) }
            return
        }
        guard policy.isValidForPersistence else {
            throw DoryMachineConfigurationMigrationError.unsupportedDefinitionChange(
                "sandboxPolicy"
            )
        }
        environment[DoryVMSandboxPolicy.legacyMarkerEnvironmentKey] = "1"
        environment[DoryVMSandboxPolicy.legacyExpirationEnvironmentKey]
            = policy.expiresAtUnixSeconds.map(String.init) ?? "0"
        environment[DoryVMSandboxPolicy.legacySSHAgentEnvironmentKey]
            = policy.sshAgentAccess == .granted ? "1" : "0"
        switch policy.profile {
        case .standard:
            environment.removeValue(forKey: DoryVMSandboxPolicy.legacyProfileEnvironmentKey)
            environment.removeValue(forKey: DoryVMSandboxPolicy.legacyToolsEnvironmentKey)
            environment.removeValue(forKey: DoryVMSandboxPolicy.legacyBaselineEnvironmentKey)
        case .agentReady:
            environment[DoryVMSandboxPolicy.legacyProfileEnvironmentKey]
                = DoryVMSandboxProfile.agentReady.rawValue
            environment[DoryVMSandboxPolicy.legacyToolsEnvironmentKey]
                = policy.tools.map(\.rawValue).joined(separator: ",")
            environment[DoryVMSandboxPolicy.legacyBaselineEnvironmentKey]
                = policy.baselineSnapshotID
        }
    }

    private static func assignIfChanged(
        _ value: String?,
        baseline: String?,
        key: String,
        to environment: inout [String: String]
    ) {
        guard value != baseline else { return }
        if let value {
            environment[key] = value
        } else {
            environment.removeValue(forKey: key)
        }
    }
}

/// Pure migration entry points. MachineManager remains the legacy persistence owner; this bridge
/// neither writes files nor reads ProcessInfo or filesystem state.
public enum DoryMachineConfigurationMigrationBridge {
    private static let mebibyte: UInt64 = 1_048_576

    public static func decodeAndMigrate(
        _ legacyData: Data,
        facts: DoryMachineConfigurationMigrationFacts
    ) throws -> DoryMachineConfigurationMigrationResult {
        let configuration: DoryMachineConfiguration
        do {
            configuration = try JSONDecoder().decode(
                DoryMachineConfiguration.self,
                from: legacyData
            )
        } catch {
            throw DoryMachineConfigurationMigrationError.invalidLegacyPayload
        }
        return try migrate(configuration, facts: facts)
    }

    /// Canonical legacy bytes match MachineManager's existing persistence formatter and schema.
    public static func encodeLegacy(_ configuration: DoryMachineConfiguration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            return try encoder.encode(configuration)
        } catch {
            throw DoryMachineConfigurationMigrationError.invalidLegacyPayload
        }
    }

    public static func migrate(
        _ configuration: DoryMachineConfiguration,
        facts: DoryMachineConfigurationMigrationFacts
    ) throws -> DoryMachineConfigurationMigrationResult {
        guard configuration.cpuCount > 0 else {
            throw DoryMachineConfigurationMigrationError.invalidLegacyConfiguration(
                "cpuCount must be positive"
            )
        }
        let (memoryBytes, memoryOverflow) = configuration.memoryMB.multipliedReportingOverflow(
            by: mebibyte
        )
        guard !memoryOverflow, memoryBytes > 0 else {
            throw DoryMachineConfigurationMigrationError.resourceNotRepresentable("memoryMB")
        }
        let diskCapacity: UInt64
        if let configured = configuration.diskSizeBytes,
           let inspected = facts.systemDiskCapacityBytes,
           configured != inspected {
            throw DoryMachineConfigurationMigrationError.conflictingSystemDiskCapacity(
                configured: configured,
                inspected: inspected
            )
        } else if let supplied = facts.systemDiskCapacityBytes ?? configuration.diskSizeBytes,
                  supplied > 0 {
            diskCapacity = supplied
        } else {
            throw DoryMachineConfigurationMigrationError.missingSystemDiskCapacity
        }
        guard !configuration.kernelPath.isEmpty else {
            throw DoryMachineConfigurationMigrationError.invalidLegacyConfiguration(
                "kernelPath is empty"
            )
        }
        guard !configuration.rootfsPath.isEmpty else {
            throw DoryMachineConfigurationMigrationError.invalidLegacyConfiguration(
                "rootfsPath is empty"
            )
        }

        let bootContract = try legacyBootContract(configuration, facts: facts)
        let vmmPreference: DoryDesktopVMMPreference
        let graphicsPreference: DoryDesktopGraphicsPreference
        do {
            vmmPreference = try DoryDesktopVMMPreference(environment: configuration.environment)
        } catch {
            throw DoryMachineConfigurationMigrationError.invalidLegacyPreference(
                DoryDesktopVMMPreference.environmentKey
            )
        }
        do {
            graphicsPreference = try DoryDesktopGraphicsPreference(
                environment: configuration.environment
            )
        } catch {
            throw DoryMachineConfigurationMigrationError.invalidLegacyPreference(
                DoryDesktopGraphicsPreference.environmentKey
            )
        }

        let systemDiskReference = stableReference(
            namespace: "legacy-artifact",
            identity: configuration.id + "\u{0}system-disk\u{0}" + configuration.rootfsPath
        )
        let kernelReference = stableReference(
            namespace: "legacy-artifact",
            identity: configuration.id + "\u{0}kernel\u{0}" + configuration.kernelPath
        )
        var artifactBindings = [
            DoryMachineConfigurationArtifactBinding(
                role: .kernel,
                reference: kernelReference,
                path: configuration.kernelPath
            ),
            DoryMachineConfigurationArtifactBinding(
                role: .systemDisk,
                reference: systemDiskReference,
                path: configuration.rootfsPath
            ),
        ]

        let boot: DoryVMBootConfiguration
        switch bootContract {
        case .managedDirectKernel:
            boot = normalBoot(
                kind: .linuxKernel,
                source: configuration.environment["DORY_CUSTOM_LINUX"] == "1"
                    ? .userProvided : .bundledByDory,
                artifact: kernelReference
            )
        case .efiInstaller:
            guard let installerPath = configuration.installerISOPath,
                  !installerPath.isEmpty else {
                throw DoryMachineConfigurationMigrationError.invalidLegacyConfiguration(
                    "installerISOPath is empty"
                )
            }
            let installerReference = stableReference(
                namespace: "legacy-artifact",
                identity: configuration.id + "\u{0}installer-iso\u{0}" + installerPath
            )
            artifactBindings.append(DoryMachineConfigurationArtifactBinding(
                role: .installerISO,
                reference: installerReference,
                path: installerPath
            ))
            boot = DoryVMBootConfiguration(
                phase: .install,
                devices: [DoryVMBootMediaReference(
                    id: "installer",
                    role: .installer,
                    kind: .installerISO,
                    source: .userProvided,
                    artifact: installerReference,
                    removable: true
                )],
                order: ["installer"]
            )
        case .efiFirmwareDisk:
            boot = normalBoot(
                kind: .virtualDisk,
                source: .userProvided,
                artifact: systemDiskReference
            )
        case .efiInstalledDirectBoot:
            boot = normalBoot(
                kind: .installedLinuxBootBundle,
                source: .userProvided,
                artifact: kernelReference
            )
        }

        var shareBindings: [DoryMachineConfigurationShareBinding] = []
        let shares = configuration.shares.enumerated().map { index, share in
            let hostAuthorityIdentity: String
            if let volumeUUID = share.authorizationVolumeUUID,
               let fileIdentifier = share.authorizationFileIdentifier {
                hostAuthorityIdentity = volumeUUID.lowercased() + "\u{0}"
                    + fileIdentifier.map { String(format: "%02x", $0) }.joined()
            } else if let bookmark = share.authorizationBookmark {
                hostAuthorityIdentity = SHA256.hash(data: bookmark)
                    .map { String(format: "%02x", $0) }
                    .joined()
            } else {
                hostAuthorityIdentity = share.hostPath
            }
            let reference = stableReference(
                namespace: "legacy-share",
                identity: configuration.id + "\u{0}\(index)\u{0}" + share.tag + "\u{0}"
                    + hostAuthorityIdentity
            )
            shareBindings.append(DoryMachineConfigurationShareBinding(
                reference: reference,
                hostPath: share.hostPath,
                authorizationBookmark: share.authorizationBookmark,
                authorizationVolumeUUID: share.authorizationVolumeUUID,
                authorizationFileIdentifier: share.authorizationFileIdentifier
            ))
            return DoryVMShare(
                id: share.tag,
                hostLocation: reference,
                guestMountPath: share.guestPath,
                readOnly: share.readOnly
            )
        }

        let isDesktop = configuration.displayMode == .desktop
        let guestIdentityIntent = typedGuestIdentityIntent(
            configuration.environment,
            includeDesktop: isDesktop
        )
        let clipboardPolicy: DoryVMClipboardPolicy
        if isDesktop {
            let legacyDirection = DoryVMClipboardDirection(
                rawValue: configuration.environment[DoryDesktopClipboardPolicy.environmentKey]
                    ?? DoryVMClipboardDirection.bidirectional.rawValue
            ) ?? .off
            clipboardPolicy = .legacyDesktop(legacyDirection)
        } else {
            clipboardPolicy = .disabled
        }
        let sandboxPolicy = DoryVMSandboxPolicy.legacyEnvironment(
            configuration.environment
        )
        let acceleratedBoot = bootContract == .managedDirectKernel
            || bootContract == .efiInstalledDirectBoot
        let backendPreference: DoryVMBackendPreference
        if isDesktop, acceleratedBoot {
            backendPreference = typedBackendPreference(vmmPreference)
        } else {
            backendPreference = DoryVMBackendPreference(
                mode: .preferred,
                backend: .appleVirtualizationFramework
            )
        }
        let graphics: DoryVMGraphicsPolicy
        if !isDesktop {
            graphics = DoryVMGraphicsPolicy(acceptableLevels: [.none])
        } else if acceleratedBoot {
            graphics = typedGraphicsPolicy(graphicsPreference)
        } else {
            graphics = DoryVMGraphicsPolicy(
                acceptableLevels: [.hostAcceleratedDisplay, .software]
            )
        }

        let definition = DoryVirtualMachineDefinition(
            identity: DoryVirtualMachineIdentity(id: configuration.id, name: configuration.id),
            guest: DoryGuestPlatform(family: .linux, architecture: facts.guestArchitecture),
            workload: isDesktop ? .desktop : .server,
            boot: boot,
            backendPreference: backendPreference,
            graphics: graphics,
            resources: DoryVMResourceRequest(
                virtualCPUCount: UInt64(configuration.cpuCount),
                memoryBytes: memoryBytes,
                diskBytes: diskCapacity
            ),
            storage: [DoryVMStorageAttachment(
                id: "system",
                role: .system,
                artifact: systemDiskReference,
                capacityBytes: diskCapacity
            )],
            networkMode: .sharedNAT,
            display: isDesktop ? DoryVMDisplayConfiguration() : .disabled,
            audio: isDesktop
                ? DoryVMAudioConfiguration(inputEnabled: true, outputEnabled: true)
                : DoryVMAudioConfiguration(inputEnabled: false, outputEnabled: false),
            input: isDesktop
                ? DoryVMInputConfiguration()
                : DoryVMInputConfiguration(keyboardEnabled: false, pointerEnabled: false),
            shares: shares,
            integrations: isDesktop
                ? [.clipboard, .clockSynchronization, .dynamicDisplay, .gracefulShutdown]
                : [.clockSynchronization, .gracefulShutdown],
            guestIdentityIntent: guestIdentityIntent,
            clipboardPolicy: clipboardPolicy,
            sandboxPolicy: sandboxPolicy,
            lifecycle: facts.lifecycle
        )
        let issues = definition.validate()
        guard issues.isEmpty else {
            throw DoryMachineConfigurationMigrationError.invalidDefinition(issues)
        }
        return DoryMachineConfigurationMigrationResult(
            definition: definition,
            bootContract: bootContract,
            artifactBindings: artifactBindings,
            shareBindings: shareBindings,
            authoritativeLegacyConfiguration: configuration
        )
    }

    private static func typedGuestIdentityIntent(
        _ environment: [String: String],
        includeDesktop: Bool
    ) -> DoryVMGuestIdentityIntent {
        let username = environment[DoryVMGuestAccountIntent.legacyUsernameEnvironmentKey]
            .flatMap { DoryVMGuestAccountIntent.isValidUsername($0) ? $0 : nil }
        let numericUserID = environment[DoryVMGuestAccountIntent.legacyNumericUserIDEnvironmentKey]
            .flatMap(UInt32.init)
            .flatMap { DoryVMGuestAccountIntent.isValidNumericUserID($0) ? $0 : nil }
        let accountCandidate = DoryVMGuestAccountIntent(
            username: username,
            numericUserID: numericUserID
        )
        let account = accountCandidate.isValidForPersistence ? accountCandidate : nil

        let distributionIdentifier = environment[
            DoryVMDesktopIdentityIntent.legacyDistributionEnvironmentKey
        ].flatMap {
            DoryVMDesktopIdentityIntent.isValidDistributionIdentifier($0) ? $0 : nil
        }
        func safeLabel(_ key: String) -> String? {
            environment[key].flatMap { DoryVMDesktopIdentityIntent.isValidLabel($0) ? $0 : nil }
        }
        let desktopCandidate = DoryVMDesktopIdentityIntent(
            distributionIdentifier: distributionIdentifier,
            displayName: safeLabel(DoryVMDesktopIdentityIntent.legacyDisplayNameEnvironmentKey),
            version: safeLabel(DoryVMDesktopIdentityIntent.legacyVersionEnvironmentKey),
            desktopEnvironment: safeLabel(
                DoryVMDesktopIdentityIntent.legacyDesktopEnvironmentKey
            )
        )
        let desktop = includeDesktop && desktopCandidate.isValidForPersistence
            ? desktopCandidate : nil
        return DoryVMGuestIdentityIntent(account: account, desktop: desktop)
    }

    private static func legacyBootContract(
        _ configuration: DoryMachineConfiguration,
        facts: DoryMachineConfigurationMigrationFacts
    ) throws -> DoryMachineConfigurationLegacyBootContract {
        switch configuration.bootMode {
        case .linuxKernel:
            guard configuration.installerISOPath == nil else {
                throw DoryMachineConfigurationMigrationError.invalidLegacyConfiguration(
                    "linux-kernel boot cannot attach installer media"
                )
            }
            return .managedDirectKernel
        case .efi:
            guard configuration.displayMode == .desktop else {
                throw DoryMachineConfigurationMigrationError.invalidLegacyConfiguration(
                    "EFI headless mode is not supported by MachineManager"
                )
            }
            if configuration.installerISOPath != nil { return .efiInstaller }
            switch facts.installedEFIBoot {
            case .firmwareDisk?: return .efiFirmwareDisk
            case .installedLinuxBootBundle?: return .efiInstalledDirectBoot
            case nil: throw DoryMachineConfigurationMigrationError.missingInstalledEFIBootFact
            }
        }
    }

    private static func normalBoot(
        kind: DoryBootMediaKind,
        source: DoryBootMediaSource,
        artifact: DoryVMResolverReference
    ) -> DoryVMBootConfiguration {
        DoryVMBootConfiguration(
            phase: .normal,
            devices: [DoryVMBootMediaReference(
                id: "system",
                role: .system,
                kind: kind,
                source: source,
                artifact: artifact,
                removable: false
            )],
            order: ["system"]
        )
    }

    private static func typedBackendPreference(
        _ preference: DoryDesktopVMMPreference
    ) -> DoryVMBackendPreference {
        switch preference {
        case .automatic:
            DoryVMBackendPreference()
        case .accelerated:
            DoryVMBackendPreference(mode: .preferred, backend: .doryHypervisor)
        case .compatible:
            DoryVMBackendPreference(
                mode: .preferred,
                backend: .appleVirtualizationFramework
            )
        }
    }

    private static func typedGraphicsPolicy(
        _ preference: DoryDesktopGraphicsPreference
    ) -> DoryVMGraphicsPolicy {
        switch preference {
        case .automatic:
            DoryVMGraphicsPolicy(
                acceptableLevels: [.hardwareAccelerated3D, .hostAcceleratedDisplay, .software]
            )
        case .virgl:
            DoryVMGraphicsPolicy(acceptableLevels: [.hostAcceleratedDisplay])
        case .virglVenus:
            DoryVMGraphicsPolicy(acceptableLevels: [.hardwareAccelerated3D])
        case .software:
            DoryVMGraphicsPolicy(acceptableLevels: [.software])
        }
    }

    private static func stableReference(
        namespace: String,
        identity: String
    ) -> DoryVMResolverReference {
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return DoryVMResolverReference(namespace: namespace, identifier: digest)
    }
}
