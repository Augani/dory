import CryptoKit
import DoryCore
import DoryOperations
import Foundation

public struct MachineManagerConfiguration: Sendable, Equatable {
    public var vmmExecutablePath: String
    /// Raw-Hypervisor helper used only for accelerated Linux desktops. EFI installers and
    /// headless machines retain the established Virtualization.framework helper.
    public var acceleratedDesktopExecutablePath: String?
    public var stateDirectory: String
    public var runtimeDirectory: String
    /// Durable mutation authority kept outside individual machine directories so interrupted
    /// deletion can recover without deleting its own journal.
    public var lifecycleJournalHome: String
    public var baseArguments: [String]
    public var acceleratedDesktopBaseArguments: [String]
    public var passMachineArguments: Bool
    public var logDirectory: String
    public var requiresReadyHandoff: Bool
    /// Headless Linux guests should publish the agent handoff promptly. Keep this bounded so a
    /// helper that is alive but unable to boot does not remain in the starting state.
    public var handoffReadyTimeoutSeconds: TimeInterval
    /// Full desktop first boots perform account, display-manager, graphics, and share setup before
    /// the helper can publish readiness. This must exceed the desktop helper's own preparation
    /// budget, while still remaining bounded.
    public var desktopHandoffReadyTimeoutSeconds: TimeInterval
    /// Bounded helper retries are active only until the ready handoff. This absorbs transient
    /// Virtualization.framework resource release races without masking a later VM crash.
    public var startupRestartPolicy: HvRestartPolicy
    public var guestArchitecture: String
    /// Host SSH agent made available to ordinary machines. Sandboxes only receive it when their
    /// persisted policy contains the explicit DORY_SANDBOX_SSH_AGENT=1 grant.
    public var sshAgentSocketPath: String?

    public init(
        vmmExecutablePath: String,
        acceleratedDesktopExecutablePath: String? = nil,
        stateDirectory: String,
        runtimeDirectory: String? = nil,
        lifecycleJournalHome: String? = nil,
        baseArguments: [String] = [],
        acceleratedDesktopBaseArguments: [String] = [],
        passMachineArguments: Bool = true,
        logDirectory: String? = nil,
        requiresReadyHandoff: Bool = true,
        handoffReadyTimeoutSeconds: TimeInterval = 60,
        desktopHandoffReadyTimeoutSeconds: TimeInterval = 180,
        startupRestartPolicy: HvRestartPolicy = HvRestartPolicy(
            maxRestarts: 4,
            delaySeconds: 0.25,
            maximumDelaySeconds: 2,
            stableRunSeconds: 0
        ),
        guestArchitecture: String? = nil,
        sshAgentSocketPath: String? = nil
    ) {
        self.vmmExecutablePath = vmmExecutablePath
        self.acceleratedDesktopExecutablePath = acceleratedDesktopExecutablePath
        self.stateDirectory = stateDirectory
        self.runtimeDirectory = runtimeDirectory ?? stateDirectory
        self.lifecycleJournalHome = lifecycleJournalHome
            ?? "\(self.runtimeDirectory)/.lifecycle-journal"
        self.baseArguments = baseArguments
        self.acceleratedDesktopBaseArguments = acceleratedDesktopBaseArguments
        self.passMachineArguments = passMachineArguments
        self.logDirectory = logDirectory ?? "\(stateDirectory)/logs"
        self.requiresReadyHandoff = requiresReadyHandoff
        self.handoffReadyTimeoutSeconds = handoffReadyTimeoutSeconds
        self.desktopHandoffReadyTimeoutSeconds = desktopHandoffReadyTimeoutSeconds
        self.startupRestartPolicy = startupRestartPolicy
        self.guestArchitecture = guestArchitecture ?? Self.currentGuestArchitecture
        self.sshAgentSocketPath = sshAgentSocketPath
    }

    private static var currentGuestArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "amd64"
        #else
        "unsupported"
        #endif
    }
}

public struct DoryMachineShareConfiguration: Sendable, Equatable, Hashable, Codable {
    private static let wirePrefix = "dory-share-v1"

    public var tag: String
    public var hostPath: String
    public var guestPath: String
    public var readOnly: Bool

    public init(
        tag: String,
        hostPath: String,
        guestPath: String,
        readOnly: Bool = false
    ) {
        self.tag = tag
        self.hostPath = hostPath
        self.guestPath = guestPath
        self.readOnly = readOnly
    }

    public init(argument: String) throws {
        if argument.hasPrefix("\(Self.wirePrefix).") {
            let components = argument.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard components.count == 5,
                  components[0] == Self.wirePrefix,
                  let tag = Self.decodeWireField(components[1]),
                  let hostPath = Self.decodeWireField(components[2]),
                  let guestPath = Self.decodeWireField(components[3]),
                  ["ro", "rw"].contains(components[4]) else {
                throw MachineManagerError.invalidShare(argument)
            }
            self.init(
                tag: tag,
                hostPath: hostPath,
                guestPath: guestPath,
                readOnly: components[4] == "ro"
            )
            try validate()
            return
        }
        if argument.first == "{" {
            guard let data = argument.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
                throw MachineManagerError.invalidShare(argument)
            }
            self = decoded
            try validate()
            return
        }
        guard let equals = argument.firstIndex(of: "="), equals != argument.startIndex else {
            throw MachineManagerError.invalidShare(argument)
        }
        let tag = String(argument[..<equals])
        var components = argument[argument.index(after: equals)...].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 2 else {
            throw MachineManagerError.invalidShare(argument)
        }
        let readOnly: Bool
        switch components.last {
        case "ro":
            readOnly = true
            components.removeLast()
        case "rw":
            readOnly = false
            components.removeLast()
        default:
            readOnly = false
        }
        guard components.count >= 2 else {
            throw MachineManagerError.invalidShare(argument)
        }
        let guestPath = components.removeLast()
        let hostPath = components.joined(separator: ":")
        self.init(tag: tag, hostPath: hostPath, guestPath: guestPath, readOnly: readOnly)
        try validate()
    }

    public var argumentValue: String {
        [
            Self.wirePrefix,
            Self.encodeWireField(tag),
            Self.encodeWireField(hostPath),
            Self.encodeWireField(guestPath),
            readOnly ? "ro" : "rw",
        ].joined(separator: ".")
    }

    public func validate() throws {
        guard !tag.isEmpty,
              tag.utf8.count < 36,
              tag.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) else {
            throw MachineManagerError.invalidShare(tag)
        }
        guard hostPath.hasPrefix("/"), !hostPath.contains("\0") else {
            throw MachineManagerError.invalidShare(hostPath)
        }
        guard guestPath.hasPrefix("/"), guestPath != "/", !guestPath.contains("\0") else {
            throw MachineManagerError.invalidShare(guestPath)
        }
    }

    private static func encodeWireField(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    private static func decodeWireField(_ value: String) -> String? {
        guard let data = Data(base64Encoded: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public enum DoryMachineDisplayMode: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case headless
    case desktop
}

public enum DoryMachineBootMode: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case linuxKernel = "linux-kernel"
    case efi
}

public struct DoryMachineConfiguration: Sendable, Equatable, Hashable, Codable {
    public var id: String
    public var kernelPath: String
    public var rootfsPath: String
    public var bootMode: DoryMachineBootMode
    public var installerISOPath: String?
    public var diskSizeBytes: UInt64?
    public var memoryMB: UInt64
    public var cpuCount: Int
    public var address: String?
    public var displayMode: DoryMachineDisplayMode
    public var shares: [DoryMachineShareConfiguration]
    public var environment: [String: String]
    public var installedDesktopPayloadReceipt: DoryInstalledDesktopPayloadReceipt?

    public init(
        id: String,
        kernelPath: String,
        rootfsPath: String,
        bootMode: DoryMachineBootMode = .linuxKernel,
        installerISOPath: String? = nil,
        diskSizeBytes: UInt64? = nil,
        memoryMB: UInt64 = 2048,
        cpuCount: Int = 2,
        address: String? = nil,
        displayMode: DoryMachineDisplayMode = .headless,
        shares: [DoryMachineShareConfiguration] = [],
        environment: [String: String] = [:],
        installedDesktopPayloadReceipt: DoryInstalledDesktopPayloadReceipt? = nil
    ) {
        self.id = id
        self.kernelPath = kernelPath
        self.rootfsPath = rootfsPath
        self.bootMode = bootMode
        self.installerISOPath = installerISOPath
        self.diskSizeBytes = diskSizeBytes
        self.memoryMB = memoryMB
        self.cpuCount = cpuCount
        self.address = address
        self.displayMode = displayMode
        self.shares = shares
        self.environment = environment
        self.installedDesktopPayloadReceipt = installedDesktopPayloadReceipt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kernelPath
        case rootfsPath
        case bootMode
        case installerISOPath
        case diskSizeBytes
        case memoryMB
        case cpuCount
        case address
        case displayMode
        case shares
        case environment
        case installedDesktopPayloadReceipt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            kernelPath: try container.decode(String.self, forKey: .kernelPath),
            rootfsPath: try container.decode(String.self, forKey: .rootfsPath),
            bootMode: try container.decodeIfPresent(DoryMachineBootMode.self, forKey: .bootMode) ?? .linuxKernel,
            installerISOPath: try container.decodeIfPresent(String.self, forKey: .installerISOPath),
            diskSizeBytes: try container.decodeIfPresent(UInt64.self, forKey: .diskSizeBytes),
            memoryMB: try container.decodeIfPresent(UInt64.self, forKey: .memoryMB) ?? 2048,
            cpuCount: try container.decodeIfPresent(Int.self, forKey: .cpuCount) ?? 2,
            address: try container.decodeIfPresent(String.self, forKey: .address),
            displayMode: try container.decodeIfPresent(DoryMachineDisplayMode.self, forKey: .displayMode) ?? .headless,
            shares: try container.decodeIfPresent([DoryMachineShareConfiguration].self, forKey: .shares) ?? [],
            environment: try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:],
            installedDesktopPayloadReceipt: try container.decodeIfPresent(
                DoryInstalledDesktopPayloadReceipt.self,
                forKey: .installedDesktopPayloadReceipt
            )
        )
    }

    public var effectiveInstalledDesktopPayloadReceipt: DoryInstalledDesktopPayloadReceipt? {
        installedDesktopPayloadReceipt
            ?? DoryInstalledDesktopPayloadReceipt.legacyEnvironment(environment)
    }
}

public enum DoryMachineState: String, Sendable, Equatable {
    case created
    case starting
    case running
    case paused
    case stopped
    case failed
}

public struct DoryMachineStatus: Sendable, Equatable {
    public var id: String
    public var state: DoryMachineState
    public var pid: Int32?
    public var lastError: String?
    public var handoffSocketPath: String?
    public var agentBuild: String?
    public var agentProtocolVersion: UInt32?
    public var agentCapabilities: [DoryAgentCapability]
    public var agentSocketPath: String?
    public var dockerdSocketPath: String?
    public var shellSocketPath: String?
    public var controlSocketPath: String?
    /// Address used by host-side DNS and HTTP routing. A configured override wins over the
    /// address reported by the running guest.
    public var address: String?
    public var configuredAddress: String?
    public var runtimeAddress: String?
    public var handoffFDCount: Int
    public var memoryMB: UInt64
    public var currentBalloonTargetMB: UInt64
    public var cpuCount: Int
    public var displayMode: DoryMachineDisplayMode
    public var bootMode: DoryMachineBootMode
    public var installerMediaAttached: Bool
    public var shares: [DoryMachineShareConfiguration]
    public var environment: [String: String]
    public var typedSettings: DoryMachineTypedSettingsSnapshot?
    public var runtimeIdentity: DoryMachineRuntimeIdentity
    public var installedDesktopPayloadReceipt: DoryInstalledDesktopPayloadReceipt?

    public init(
        id: String,
        state: DoryMachineState,
        pid: Int32? = nil,
        lastError: String? = nil,
        handoffSocketPath: String? = nil,
        agentBuild: String? = nil,
        agentProtocolVersion: UInt32? = nil,
        agentCapabilities: [DoryAgentCapability] = [],
        agentSocketPath: String? = nil,
        dockerdSocketPath: String? = nil,
        shellSocketPath: String? = nil,
        controlSocketPath: String? = nil,
        address: String? = nil,
        configuredAddress: String? = nil,
        runtimeAddress: String? = nil,
        handoffFDCount: Int = 0,
        memoryMB: UInt64 = 0,
        currentBalloonTargetMB: UInt64? = nil,
        cpuCount: Int = 0,
        displayMode: DoryMachineDisplayMode = .headless,
        bootMode: DoryMachineBootMode = .linuxKernel,
        installerMediaAttached: Bool = false,
        shares: [DoryMachineShareConfiguration] = [],
        environment: [String: String] = [:],
        typedSettings: DoryMachineTypedSettingsSnapshot? = nil,
        runtimeIdentity: DoryMachineRuntimeIdentity = .legacyCompatibility(
            virtualHardwareABIVersion:
                DoryVirtualMachineDefinition.currentVirtualHardwareABIVersion
        ),
        installedDesktopPayloadReceipt: DoryInstalledDesktopPayloadReceipt? = nil
    ) {
        self.id = id
        self.state = state
        self.pid = pid
        self.lastError = lastError
        self.handoffSocketPath = handoffSocketPath
        self.agentBuild = agentBuild
        self.agentProtocolVersion = agentProtocolVersion
        self.agentCapabilities = agentCapabilities
        self.agentSocketPath = agentSocketPath
        self.dockerdSocketPath = dockerdSocketPath
        self.shellSocketPath = shellSocketPath
        self.controlSocketPath = controlSocketPath
        self.address = address
        self.configuredAddress = configuredAddress
        self.runtimeAddress = runtimeAddress
        self.handoffFDCount = handoffFDCount
        self.memoryMB = memoryMB
        self.currentBalloonTargetMB = currentBalloonTargetMB ?? memoryMB
        self.cpuCount = cpuCount
        self.displayMode = displayMode
        self.bootMode = bootMode
        self.installerMediaAttached = installerMediaAttached
        self.shares = shares
        self.environment = environment
        self.typedSettings = typedSettings
        self.runtimeIdentity = runtimeIdentity
        self.installedDesktopPayloadReceipt = installedDesktopPayloadReceipt
    }
}

public enum DoryMachineSnapshotConsistency: String, Sendable, Equatable, Hashable, Codable {
    case coldStopped = "cold-stopped"
    case guestQuiesced = "guest-quiesced"
}

public struct DoryMachineSnapshotQuiesceReceipt: Sendable, Equatable, Hashable, Codable {
    public var schemaVersion: UInt16
    public var receiptID: String
    public var agentBuild: String
    public var agentProtocolVersion: UInt32
    public var capabilityVersion: UInt32

    public init(
        schemaVersion: UInt16 = 1,
        receiptID: String,
        agentBuild: String,
        agentProtocolVersion: UInt32,
        capabilityVersion: UInt32
    ) {
        self.schemaVersion = schemaVersion
        self.receiptID = receiptID
        self.agentBuild = agentBuild
        self.agentProtocolVersion = agentProtocolVersion
        self.capabilityVersion = capabilityVersion
    }

    public var isValid: Bool {
        schemaVersion == 1
            && receiptID.utf8.count == 32
            && receiptID.utf8.allSatisfy {
                ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
            }
            && !agentBuild.isEmpty
            && agentBuild.utf8.count <= 128
            && agentBuild.utf8.allSatisfy { $0 >= 0x20 && $0 <= 0x7e }
            && agentProtocolVersion == DoryCore.protocolVersion()
            && capabilityVersion >= 2
    }
}

public struct DoryMachineSnapshot: Sendable, Equatable, Hashable, Codable {
    public var id: String
    public var machineID: String
    public var note: String
    public var createdISO: String
    public var rootfsPath: String
    public var sizeBytes: Int64
    public var kernelPath: String
    public var architecture: String
    public var memoryMB: UInt64
    public var cpuCount: Int
    public var displayMode: DoryMachineDisplayMode
    public var address: String?
    public var shares: [DoryMachineShareConfiguration]
    public var environment: [String: String]
    public var typedSettings: DoryMachineTypedSettingsSnapshot?
    public var bootMode: DoryMachineBootMode
    public var machineIdentifierPath: String?
    public var nvramPath: String?
    public var runtimeIdentity: DoryMachineRuntimeIdentity
    public var artifactEvidence: DoryMachineSnapshotArtifactEvidence?
    public var installedDesktopPayloadReceipt: DoryInstalledDesktopPayloadReceipt?
    public var consistency: DoryMachineSnapshotConsistency
    public var guestQuiesceReceipt: DoryMachineSnapshotQuiesceReceipt?

    public init(
        id: String,
        machineID: String,
        note: String,
        createdISO: String,
        rootfsPath: String,
        sizeBytes: Int64,
        kernelPath: String,
        architecture: String,
        memoryMB: UInt64,
        cpuCount: Int,
        displayMode: DoryMachineDisplayMode = .headless,
        address: String? = nil,
        shares: [DoryMachineShareConfiguration] = [],
        environment: [String: String] = [:],
        typedSettings: DoryMachineTypedSettingsSnapshot? = nil,
        bootMode: DoryMachineBootMode = .linuxKernel,
        machineIdentifierPath: String? = nil,
        nvramPath: String? = nil,
        runtimeIdentity: DoryMachineRuntimeIdentity = .legacyCompatibility(
            virtualHardwareABIVersion:
                DoryVirtualMachineDefinition.currentVirtualHardwareABIVersion
        ),
        artifactEvidence: DoryMachineSnapshotArtifactEvidence? = nil,
        installedDesktopPayloadReceipt: DoryInstalledDesktopPayloadReceipt? = nil,
        consistency: DoryMachineSnapshotConsistency = .coldStopped,
        guestQuiesceReceipt: DoryMachineSnapshotQuiesceReceipt? = nil
    ) {
        self.id = id
        self.machineID = machineID
        self.note = note
        self.createdISO = createdISO
        self.rootfsPath = rootfsPath
        self.sizeBytes = sizeBytes
        self.kernelPath = kernelPath
        self.architecture = architecture
        self.memoryMB = memoryMB
        self.cpuCount = cpuCount
        self.displayMode = displayMode
        self.address = address
        self.shares = shares
        self.environment = environment
        self.typedSettings = typedSettings
        self.bootMode = bootMode
        self.machineIdentifierPath = machineIdentifierPath
        self.nvramPath = nvramPath
        self.runtimeIdentity = runtimeIdentity
        self.artifactEvidence = artifactEvidence
        self.installedDesktopPayloadReceipt = installedDesktopPayloadReceipt
        self.consistency = consistency
        self.guestQuiesceReceipt = guestQuiesceReceipt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case machineID
        case note
        case createdISO
        case rootfsPath
        case sizeBytes
        case kernelPath
        case architecture
        case memoryMB
        case cpuCount
        case displayMode
        case address
        case shares
        case environment
        case typedSettings
        case bootMode
        case machineIdentifierPath
        case nvramPath
        case runtimeIdentity
        case artifactEvidence
        case installedDesktopPayloadReceipt
        case consistency
        case guestQuiesceReceipt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let consistency = try container.decodeIfPresent(
            DoryMachineSnapshotConsistency.self,
            forKey: .consistency
        ) ?? .coldStopped
        let guestQuiesceReceipt = try container.decodeIfPresent(
            DoryMachineSnapshotQuiesceReceipt.self,
            forKey: .guestQuiesceReceipt
        )
        guard guestQuiesceReceipt?.isValid ?? true,
              (consistency == .guestQuiesced) == (guestQuiesceReceipt != nil) else {
            throw DecodingError.dataCorruptedError(
                forKey: .guestQuiesceReceipt,
                in: container,
                debugDescription: "snapshot consistency and guest quiesce receipt disagree"
            )
        }
        self.init(
            id: try container.decode(String.self, forKey: .id),
            machineID: try container.decode(String.self, forKey: .machineID),
            note: try container.decode(String.self, forKey: .note),
            createdISO: try container.decode(String.self, forKey: .createdISO),
            rootfsPath: try container.decode(String.self, forKey: .rootfsPath),
            sizeBytes: try container.decode(Int64.self, forKey: .sizeBytes),
            kernelPath: try container.decode(String.self, forKey: .kernelPath),
            architecture: try container.decode(String.self, forKey: .architecture),
            memoryMB: try container.decode(UInt64.self, forKey: .memoryMB),
            cpuCount: try container.decode(Int.self, forKey: .cpuCount),
            displayMode: try container.decodeIfPresent(DoryMachineDisplayMode.self, forKey: .displayMode) ?? .headless,
            address: try container.decodeIfPresent(String.self, forKey: .address),
            shares: try container.decodeIfPresent([DoryMachineShareConfiguration].self, forKey: .shares) ?? [],
            environment: try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:],
            typedSettings: try container.decodeIfPresent(
                DoryMachineTypedSettingsSnapshot.self,
                forKey: .typedSettings
            ),
            bootMode: try container.decodeIfPresent(DoryMachineBootMode.self, forKey: .bootMode) ?? .linuxKernel,
            machineIdentifierPath: try container.decodeIfPresent(String.self, forKey: .machineIdentifierPath),
            nvramPath: try container.decodeIfPresent(String.self, forKey: .nvramPath),
            runtimeIdentity: try container.decodeIfPresent(
                DoryMachineRuntimeIdentity.self,
                forKey: .runtimeIdentity
            ) ?? .legacyCompatibility(
                virtualHardwareABIVersion:
                    DoryMachineRuntimeIdentity.oldestLegacyVirtualHardwareABIVersion
            ),
            artifactEvidence: try container.decodeIfPresent(
                DoryMachineSnapshotArtifactEvidence.self,
                forKey: .artifactEvidence
            ),
            installedDesktopPayloadReceipt: try container.decodeIfPresent(
                DoryInstalledDesktopPayloadReceipt.self,
                forKey: .installedDesktopPayloadReceipt
            ),
            consistency: consistency,
            guestQuiesceReceipt: guestQuiesceReceipt
        )
    }
}

public struct DoryDesktopUpdateResult: Sendable, Equatable {
    public var machineID: String
    public var distro: String
    public var version: String
    public var inputSHA256: String
    public var bundleSHA256: String
    public var snapshotID: String
    public var status: DoryMachineStatus
    public var restoredRunningState: Bool

    public init(
        machineID: String,
        distro: String,
        version: String,
        inputSHA256: String,
        bundleSHA256: String,
        snapshotID: String,
        status: DoryMachineStatus,
        restoredRunningState: Bool
    ) {
        self.machineID = machineID
        self.distro = distro
        self.version = version
        self.inputSHA256 = inputSHA256
        self.bundleSHA256 = bundleSHA256
        self.snapshotID = snapshotID
        self.status = status
        self.restoredRunningState = restoredRunningState
    }
}

private enum DesktopUpdateJournalStage: String, Codable, Sendable {
    case snapshotReady = "snapshot-ready"
    case installing
    case qualifying
    case committed
}

private struct DesktopUpdateJournal: Codable, Sendable, Equatable {
    var schema: Int
    var machineID: String
    var distro: String
    var version: String
    var snapshotID: String
    var originalWasRunning: Bool
    var stage: DesktopUpdateJournalStage
    var sourceConfigurationSHA256: String?
    var updateAuthority: DoryInstalledDesktopPayloadReceipt?

    var isValid: Bool {
        guard [1, 2].contains(schema),
              Self.isValidIdentifier(machineID),
              Self.isValidIdentifier(snapshotID),
              ["debian", "kali", "ubuntu"].contains(distro),
              version.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._+-]{0,127}/) != nil else {
            return false
        }
        if schema == 1 {
            return sourceConfigurationSHA256 == nil && updateAuthority == nil
        }
        return sourceConfigurationSHA256.map(Self.isLowercaseSHA256) == true
            && updateAuthority?.isValid == true
            && updateAuthority?.provenance == .verifiedUpdateBundle
            && updateAuthority?.distributionIdentifier == distro
            && updateAuthority?.releaseVersion == version
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        value.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/) != nil
    }
}

public enum MachineManagerError: Error, Sendable, Equatable, CustomStringConvertible {
    case duplicateMachine(String)
    case invalidID(String)
    case unknownMachine(String)
    case duplicateSnapshot(String)
    case unknownSnapshot(String)
    case alreadyRunning(String)
    case agentUnavailable(String)
    case agentCapabilityUnavailable(String, String)
    case balloonUnavailable(String)
    case balloonApplyFailed(String, String)
    case invalidAddress(String)
    case invalidShare(String)
    case invalidEnvironment(String)
    case persistence(String)

    public var description: String {
        switch self {
        case let .duplicateMachine(id):
            return "machine already exists: \(id)"
        case let .invalidID(id):
            return "invalid machine id: \(id)"
        case let .unknownMachine(id):
            return "unknown machine: \(id)"
        case let .duplicateSnapshot(id):
            return "machine snapshot already exists: \(id)"
        case let .unknownSnapshot(id):
            return "unknown machine snapshot: \(id)"
        case let .alreadyRunning(id):
            return "machine is already running: \(id)"
        case let .agentUnavailable(id):
            return "machine agent is unavailable: \(id)"
        case let .agentCapabilityUnavailable(id, capability):
            return "machine agent capability is unavailable for \(id): \(capability)"
        case let .balloonUnavailable(id):
            return "machine balloon control is unavailable: \(id)"
        case let .balloonApplyFailed(id, message):
            return "machine balloon control failed for \(id): \(message)"
        case let .invalidAddress(address):
            return "invalid machine address: \(address)"
        case let .invalidShare(share):
            return "invalid machine share: \(share)"
        case let .invalidEnvironment(key):
            return "invalid machine environment variable: \(key)"
        case let .persistence(message):
            return "machine state persistence failed: \(message)"
        }
    }
}

public enum DoryWorkspaceProjectionState: String, Sendable, Equatable {
    case current
    case regenerated
    case unavailable
}

public enum DoryWorkspaceProjectionFailureCode: String, Sendable, Equatable {
    case unsupportedLegacyConfiguration = "unsupported-legacy-configuration"
    case repositoryFailure = "repository-failure"
}

/// Non-fatal migration status. Legacy `machine.json` remains runnable when a projection cannot
/// be produced; callers can surface this diagnostic without treating the VM itself as corrupt.
public struct DoryWorkspaceProjectionDiagnostic: Sendable, Equatable {
    public var state: DoryWorkspaceProjectionState
    public var failureCode: DoryWorkspaceProjectionFailureCode?
    public var message: String?

    public init(
        state: DoryWorkspaceProjectionState,
        failureCode: DoryWorkspaceProjectionFailureCode? = nil,
        message: String? = nil
    ) {
        self.state = state
        self.failureCode = failureCode
        self.message = message
    }
}

public struct DoryMachineResolvedLaunchIdentity: Sendable, Equatable {
    public var planRevision: UInt64
    public var planSHA256: String
    public var definitionRevision: UInt64
    public var backend: DoryVirtualizationBackendIdentity
    public var backendRuntimeBuildIdentifier: String
    public var virtualHardwareABIVersion: UInt16

    public init(plan: DoryResolvedMachinePlan, planSHA256: String) {
        planRevision = plan.planRevision
        self.planSHA256 = planSHA256
        definitionRevision = plan.definitionRevision
        backend = plan.backend
        backendRuntimeBuildIdentifier = plan.backendRuntimeBuildIdentifier
        virtualHardwareABIVersion = plan.virtualHardwareABIVersion
    }
}

public enum DoryMachineLaunchPolicy: String, Sendable, Equatable {
    /// Explicit transition mode for machines that predate durable workspace plans.
    case legacyCompatibility
    /// A start is rejected unless the complete persisted-plan trust path is installed.
    case requireResolvedPlan
    /// Each workspace is dispatched solely from its durable runtime identity. Existing machines
    /// may retain explicit legacy compatibility while new and invalidated machines require a plan.
    case perWorkspaceAuthority
}

public final class MachineManager: @unchecked Sendable {
    public typealias AgentConnector = @Sendable (String) throws -> any AgentControlClient
    public typealias ProcessStarter = @Sendable (HvProcess) throws -> Void
    public typealias ResolvedPlanRevisionProvider = @Sendable (_ machineID: String) -> UInt64?

    private static let deletionQuarantinePrefix = ".dory-machine-delete-"
    private static let machineDiskTemporaryPrefix = ".rootfs.ext4.tmp-"
    private static let machineKernelTemporaryPrefix = ".kernel.tmp-"
    private static let installedLinuxKernelName = "direct-kernel"
    private static let installedLinuxInitrdName = "direct-initrd"
    private static let machineMetadataTemporaryPrefix = ".dory-machine-metadata-"
    private static let interruptedNativeCreationQuarantinePrefix =
        ".dory-native-create-recovery-"
    private static let nativeCreationPrecommitMarkerName =
        ".dory-native-create-precommit-v1"
    private static let nativeCreationCommittedMarkerName =
        ".dory-native-create-committed-v1"
    private static let machineRestoreBackupMarker = ".restore-"
    private static let snapshotDeletionQuarantinePrefix = ".dory-snapshot-delete-"
    private static let snapshotDiskTemporaryMarker = ".ext4.tmp-"
    private static let snapshotKernelTemporaryMarker = ".kernel.tmp-"
    private static let snapshotMachineIdentifierTemporaryMarker = ".machine-identifier.tmp-"
    private static let snapshotNVRAMTemporaryMarker = ".nvram.tmp-"
    private static let snapshotMetadataTemporaryPrefix = ".dory-snapshot-metadata-"
    private static let desktopUpdateJournalName = "desktop-update.json"
    private static let desktopUpdateStagingPrefix = ".desktop-update-stage-"
    private static let maximumPersistedMetadataBytes: Int64 = 16 * 1024 * 1024
    /// Public Apple-Silicon machine resource contract. These match the app's steppers; enforcing
    /// them again in doryd prevents CLI/XPC callers from persisting values that the VMM would later
    /// clamp silently, which would make status disagree with the running guest.
    public static let minimumMachineMemoryMB: UInt64 = 1024
    public static let maximumMachineMemoryMB: UInt64 = 16 * 1024
    public static let minimumMachineCPUCount = 1
    public static let maximumMachineCPUCount = 8
    public static let minimumEFIDiskSizeBytes: UInt64 = 8 * 1024 * 1024 * 1024
    public static let maximumEFIDiskSizeBytes: UInt64 = 2 * 1024 * 1024 * 1024 * 1024

    private let configuration: MachineManagerConfiguration
    private let agentConnector: AgentConnector
    private let balloonController: any MachineBalloonControlling
    private let processStarter: ProcessStarter
    private let workspaceRepository: DoryWorkspaceRepository
    private let runtimeIdentityStore: DoryMachineRuntimeIdentityStore
    private let launchPolicy: DoryMachineLaunchPolicy
    private let lifecycleJournalStore: DoryOperationJournalStore?
    private let lifecycleJournalInitializationError: String?
    private let operationLock = NSRecursiveLock()
    private let lock = NSLock()
    private let fileTransferLock = NSLock()
    private let fileTransferQueue = DispatchQueue(
        label: "dev.dory.machine-file-transfer",
        qos: .utility,
        attributes: .concurrent
    )
    private var machines: [String: MachineEntry] = [:]
    private var fileTransferOperations: [String: MachineFileTransferOperation] = [:]
    private var activeFileTransferByMachine: [String: String] = [:]
    private var deletingMachineIDs: Set<String> = []
    private var workspaceProjectionDiagnostics: [String: DoryWorkspaceProjectionDiagnostic] = [:]
    private var resolvedLaunchRegistry: BackendRegistry?
    private var resolvedLaunchPlanResolver: (any DoryDaemonVirtualMachineLaunchPlanResolving)?
    private var resolvedLaunchPlanStore: (any DoryResolvedMachinePlanStoring)?
    private var resolvedPlanRevisionProvider: ResolvedPlanRevisionProvider?
    private var productionPlanningController:
        (any DoryDaemonVirtualMachineProductionPlanningControlling)?
    private var productionResourceAdmissionLedger:
        DoryVirtualMachineResourceAdmissionLedger?
    private var pendingResolvedStart: PendingResolvedMachineStart?
    private var resolvedLaunchIdentities: [String: DoryMachineResolvedLaunchIdentity] = [:]
    private var activeLifecycleOperations: [String: MachineLifecycleJournalContext] = [:]
    private var activePlanningMutationIDs: Set<String> = []
    private var activeDirectWorkspaceMutationLocks:
        [String: MachineManagerDirectMutationRetention] = [:]
    private var desktopUpdateArtifactResolver: (any DoryDesktopUpdateArtifactResolving)?
#if DEBUG
    private var lifecycleFaultInjector: (@Sendable (MachineLifecycleFaultPoint) throws -> Void)?
#endif

    public init(
        configuration: MachineManagerConfiguration,
        launchPolicy: DoryMachineLaunchPolicy = .legacyCompatibility,
        balloonController: any MachineBalloonControlling = UnixMachineBalloonController(),
        agentConnector: @escaping AgentConnector = { socketPath in
            try LocalAgentControl.connect(socketPath: socketPath)
        },
        processStarter: @escaping ProcessStarter = { process in try process.start() }
    ) {
        self.configuration = configuration
        self.launchPolicy = launchPolicy
        self.balloonController = balloonController
        self.agentConnector = agentConnector
        self.processStarter = processStarter
        self.workspaceRepository = DoryWorkspaceRepository(root: configuration.stateDirectory)
        self.runtimeIdentityStore = DoryMachineRuntimeIdentityStore(
            root: configuration.stateDirectory
        )
        do {
            let store = try DoryOperationJournalStore(
                home: configuration.lifecycleJournalHome
            )
            try store.prepare()
            lifecycleJournalStore = store
            lifecycleJournalInitializationError = nil
        } catch {
            lifecycleJournalStore = nil
            lifecycleJournalInitializationError = String(describing: error)
        }
        _ = HelperProcessJanitor.terminateStaleHelpers(
            executablePath: configuration.vmmExecutablePath,
            stateDirectory: configuration.stateDirectory,
            includeDescendants: true
        )
        if let acceleratedDesktopExecutablePath = configuration.acceleratedDesktopExecutablePath,
           acceleratedDesktopExecutablePath != configuration.vmmExecutablePath {
            _ = HelperProcessJanitor.terminateStaleHelpers(
                executablePath: acceleratedDesktopExecutablePath,
                stateDirectory: configuration.stateDirectory,
                includeDescendants: true
            )
        }
        DoryMachineFileTransferStager.removeAbandonedDaemonStages()
        let lifecycleRecoveryDiagnostics = Self.recoverInterruptedLifecycleOperations(
            store: lifecycleJournalStore,
            configuration: configuration
        )
        Self.removeStaleDeletionQuarantines(stateDirectory: configuration.stateDirectory)
        Self.removeStaleMachineMetadataArtifacts(stateDirectory: configuration.stateDirectory)
        Self.removeStaleSnapshotArtifacts(stateDirectory: configuration.stateDirectory)
        Self.restrictWorkspaceProjectionRootIfOwned(configuration.stateDirectory)
        Self.recoverCompletedNativeCreationMarkers(
            stateDirectory: configuration.stateDirectory,
            runtimeIdentityStore: runtimeIdentityStore
        )
        Self.removeInterruptedNativeCreations(
            stateDirectory: configuration.stateDirectory
        )
        self.machines = Self.loadPersistedMachines(
            configuration: configuration,
            launchPolicy: launchPolicy,
            runtimeIdentityStore: runtimeIdentityStore
        )
        for (machineID, diagnostic) in lifecycleRecoveryDiagnostics {
            machines[machineID]?.lastError = diagnostic
        }
        reconcileLoadedWorkspaceProjections()
        recoverInterruptedDesktopUpdates()
    }

    public var configuredLaunchPolicy: DoryMachineLaunchPolicy { launchPolicy }

    public var managedStateDirectory: String { configuration.stateDirectory }

    /// Installs the daemon-owned active-component resolver. Desktop update writes fail closed until
    /// this is installed; caller-supplied filesystem paths are never accepted as update authority.
    public func installDesktopUpdateArtifactResolver(
        _ resolver: any DoryDesktopUpdateArtifactResolving
    ) {
        operationLock.lock()
        desktopUpdateArtifactResolver = resolver
        operationLock.unlock()
    }

    /// Enables the explicit plan-driven launch path exactly once. Machines keep using the
    /// labeled legacy compatibility path until this production trust infrastructure is injected;
    /// once installed, a start never falls back when plan validation or adapter dispatch fails.
    public func installResolvedLaunchInfrastructure(
        registry: BackendRegistry,
        resolver: any DoryDaemonVirtualMachineLaunchPlanResolving,
        plans: any DoryResolvedMachinePlanStoring,
        expectedPlanRevision: @escaping ResolvedPlanRevisionProvider,
        productionPlanningController:
            (any DoryDaemonVirtualMachineProductionPlanningControlling)? = nil,
        resourceAdmissionLedger: DoryVirtualMachineResourceAdmissionLedger? = nil
    ) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard launchPolicy == .requireResolvedPlan
                || launchPolicy == .perWorkspaceAuthority else {
            throw MachineManagerError.persistence(
                "resolved launch infrastructure requires a resolved-plan-capable policy"
            )
        }
        guard (productionPlanningController == nil) == (resourceAdmissionLedger == nil) else {
            throw MachineManagerError.persistence(
                "production planning and resource-admission lifecycle must be installed together"
            )
        }
        guard resolvedLaunchRegistry == nil, resolvedLaunchPlanResolver == nil,
              resolvedLaunchPlanStore == nil,
              resolvedPlanRevisionProvider == nil,
              self.productionPlanningController == nil,
              productionResourceAdmissionLedger == nil,
              pendingResolvedStart == nil else {
            throw MachineManagerError.persistence(
                "resolved launch infrastructure is already installed"
            )
        }
        resolvedLaunchRegistry = registry
        resolvedLaunchPlanResolver = resolver
        resolvedLaunchPlanStore = plans
        resolvedPlanRevisionProvider = expectedPlanRevision
        self.productionPlanningController = productionPlanningController
        productionResourceAdmissionLedger = resourceAdmissionLedger
        recoverResolvedRuntimeIdentities(
            plans: plans,
            expectedPlanRevision: expectedPlanRevision
        )
        try reconcileResourceAdmissionsAfterDaemonRestart()
    }

    /// Operations for the current Linux compatibility adapters. Start is protected by a
    /// single-use authorization installed only after persisted-plan revalidation; calling the
    /// returned operation directly cannot bypass the plan-driven public start path.
    public func resolvedLaunchCompatibilityOperations(
        for backend: DoryVirtualizationBackendIdentity
    ) -> MachineBackendCompatibilityOperations {
        MachineBackendCompatibilityOperations(
            authorizedStart: { [weak self] binding in
                guard let self else {
                    throw MachineManagerError.persistence("machine manager is unavailable")
                }
                return try self.performAuthorizedResolvedBackendStart(
                    binding: binding,
                    expectedBackend: backend
                )
            },
            stop: { [weak self] id in
                guard let self else {
                    throw MachineManagerError.persistence("machine manager is unavailable")
                }
                return MachineBackendRuntimeObservation(try self.stop(id: id))
            },
            pause: { [weak self] id in
                guard let self else {
                    throw MachineManagerError.persistence("machine manager is unavailable")
                }
                return MachineBackendRuntimeObservation(
                    try self.performAuthorizedResolvedBackendPause(
                        id: id,
                        expectedBackend: backend
                    )
                )
            },
            resume: { [weak self] id in
                guard let self else {
                    throw MachineManagerError.persistence("machine manager is unavailable")
                }
                return MachineBackendRuntimeObservation(
                    try self.performAuthorizedResolvedBackendResume(
                        id: id,
                        expectedBackend: backend
                    )
                )
            }
        )
    }

    @discardableResult
    public func create(
        _ machine: DoryMachineConfiguration,
        typedSettings: DoryMachineTypedSettingsPatch? = nil
    ) throws -> DoryMachineStatus {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard Self.isValidID(machine.id) else {
            throw MachineManagerError.invalidID(machine.id)
        }
        var machine = machine
        machine.address = try Self.normalizedAddress(machine.address)
        if launchPolicy == .perWorkspaceAuthority {
            guard machine.environment.isEmpty else {
                throw MachineManagerError.persistence(
                    "native workspace creation does not accept persisted environment values"
                )
            }
        } else if let typedSettings {
            machine.environment = try typedSettings.applying(
                to: machine.environment,
                displayMode: machine.displayMode
            )
        }
        try Self.validateLaunchConfiguration(machine)
        lock.lock()
        let exists = machines[machine.id] != nil || deletingMachineIDs.contains(machine.id)
        lock.unlock()
        guard !exists else {
            throw MachineManagerError.duplicateMachine(machine.id)
        }
        switch machine.bootMode {
        case .linuxKernel:
            guard Self.isRegularNonemptyFile(path: machine.kernelPath) else {
                throw MachineManagerError.persistence("machine kernel is missing or invalid: \(machine.kernelPath)")
            }
            guard Self.isRegularNonemptyFile(path: machine.rootfsPath) else {
                throw MachineManagerError.persistence("machine rootfs is missing or invalid: \(machine.rootfsPath)")
            }
        case .efi:
            guard machine.displayMode == .desktop else {
                throw MachineManagerError.persistence("EFI installer machines require desktop display mode")
            }
            if let installerISOPath = machine.installerISOPath {
                guard Self.isRegularNonemptyFile(path: installerISOPath) else {
                    throw MachineManagerError.persistence("installer ISO is missing or invalid: \(installerISOPath)")
                }
            }
            if Self.isRegularNonemptyFile(path: machine.rootfsPath) {
                guard machine.diskSizeBytes == nil else {
                    throw MachineManagerError.persistence("EFI disk imports cannot also specify diskSizeBytes")
                }
            } else {
                guard machine.installerISOPath != nil else {
                    throw MachineManagerError.persistence("a new EFI machine requires an installer ISO")
                }
                guard let diskSizeBytes = machine.diskSizeBytes,
                      (Self.minimumEFIDiskSizeBytes...Self.maximumEFIDiskSizeBytes).contains(diskSizeBytes) else {
                    throw MachineManagerError.persistence(
                        "EFI disk size must be between \(Self.minimumEFIDiskSizeBytes) and \(Self.maximumEFIDiskSizeBytes) bytes"
                    )
                }
            }
        }
        // Reject incompatible media before allocating a virtual disk or importing a potentially
        // multi-gigabyte ISO. The managed copy is created only after this preflight succeeds.
        try validateInstallerArchitecture(machine)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(atPath: configuration.stateDirectory, withIntermediateDirectories: true)
            Self.restrictWorkspaceProjectionRootIfOwned(configuration.stateDirectory)
        } catch {
            throw MachineManagerError.persistence("could not create machine state root: \(error)")
        }
        let statePath = machineStateDirectory(id: machine.id)
        guard mkdir(statePath, 0o700) == 0 else {
            if errno == EEXIST {
                throw MachineManagerError.duplicateMachine(machine.id)
            }
            throw MachineManagerError.persistence(
                "could not create state for \(machine.id): \(String(cString: strerror(errno)))"
            )
        }
        var committed = false
        defer {
            if !committed {
                try? fileManager.removeItem(atPath: statePath)
            }
        }

        let nativeCreationMarker = statePath + "/"
            + Self.nativeCreationPrecommitMarkerName
        try Self.writeDurablePrivateData(
            Self.nativeCreationPrecommitMarkerData(machineID: machine.id),
            toPath: nativeCreationMarker
        )
        try Self.syncDirectory(path: statePath)

        let preparedMachine = try prepareMachineArtifacts(machine)
        try validateManagedMachineArtifacts(preparedMachine)
        let initialRuntimeIdentity = runtimeIdentityForUnplannedMachine()
        let authoritativeLegacyData = try DoryMachineConfigurationMigrationBridge
            .encodeLegacy(preparedMachine)
        var nativeDefinition: DoryVirtualMachineDefinition?
        if launchPolicy == .perWorkspaceAuthority {
            let facts = try workspaceMigrationFacts(for: preparedMachine)
            let migration = try DoryMachineConfigurationMigrationBridge.migrate(
                preparedMachine,
                facts: facts
            )
            let definition = try (typedSettings ?? DoryMachineTypedSettingsPatch()).applying(
                to: migration.definition,
                displayMode: preparedMachine.displayMode
            )
            try workspaceRepository.create(definition)
            nativeDefinition = definition
        }
        // The launch authority is durable before machine.json becomes discoverable. A crash in
        // this window leaves an incomplete, non-loadable directory, never a newly created VM that
        // startup can mistake for pre-companion legacy state.
        try runtimeIdentityStore.publish(
            initialRuntimeIdentity,
            machineID: preparedMachine.id,
            authoritativeLegacyData: authoritativeLegacyData
        )
        try persist(
            preparedMachine,
            reconcilesLegacyProjection: launchPolicy != .perWorkspaceAuthority
        )
        // machine.json is now durable. Preserve this exact state on a marker-transition error so
        // restart can complete it; never report success until the committed marker is directory-
        // durable. Keeping the committed marker also distinguishes later metadata loss from an
        // interrupted precommit and prevents destructive cleanup.
        committed = true
        let committedMarker = statePath + "/"
            + Self.nativeCreationCommittedMarkerName
        guard rename(nativeCreationMarker, committedMarker) == 0 else {
            throw MachineManagerError.persistence(
                "could not commit native creation authority marker"
            )
        }
        try Self.syncDirectory(path: statePath)
        lock.lock()
        machines[machine.id] = MachineEntry(
            configuration: preparedMachine,
            state: .created,
            runtimeIdentity: initialRuntimeIdentity
        )
        lock.unlock()
        let typedSettingsSnapshot = try nativeDefinition.map(
            DoryMachineTypedSettingsSnapshot.init
        ) ?? DoryMachineTypedSettingsSnapshot(
            legacyEnvironment: preparedMachine.environment,
            displayMode: preparedMachine.displayMode
        )
        return DoryMachineStatus(
            id: preparedMachine.id,
            state: .created,
            address: preparedMachine.address,
            configuredAddress: preparedMachine.address,
            memoryMB: preparedMachine.memoryMB,
            cpuCount: preparedMachine.cpuCount,
            displayMode: preparedMachine.displayMode,
            bootMode: preparedMachine.bootMode,
            installerMediaAttached: preparedMachine.installerISOPath != nil,
            shares: preparedMachine.shares,
            environment: preparedMachine.environment,
            typedSettings: typedSettingsSnapshot,
            runtimeIdentity: initialRuntimeIdentity
        )
    }

    /// Resolves and publishes the exact current compatibility projection through the production
    /// planning transaction. This is invoked by the product create/update boundary only after
    /// machine metadata and managed artifacts are durable. Starts remain fail-closed throughout:
    /// the workspace is `requires-replanning` until the coordinator completes its mutation fence
    /// and publishes the matching runtime identity.
    @discardableResult
    public func resolveAndPublishProductionPlan(
        id: String,
        controller: any DoryDaemonVirtualMachineProductionPlanningControlling
    ) throws -> DoryMachineStatus {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard launchPolicy == .perWorkspaceAuthority else {
            guard let current = status(id: id) else {
                throw MachineManagerError.unknownMachine(id)
            }
            return current
        }
        try requireNoActivePlanningMutation(id: id)

        let entry: MachineEntry
        lock.lock()
        guard let current = machines[id], !deletingMachineIDs.contains(id) else {
            lock.unlock()
            throw MachineManagerError.unknownMachine(id)
        }
        entry = current
        lock.unlock()
        guard entry.process == nil, entry.handoffServer == nil,
              entry.state == .created || entry.state == .stopped else {
            throw MachineManagerError.persistence(
                "machine \(id) must be stopped before production planning"
            )
        }
        switch entry.runtimeIdentity.mode {
        case .legacyCompatibility:
            guard let current = status(id: id) else {
                throw MachineManagerError.unknownMachine(id)
            }
            return current
        case .requiresReplanning:
            break
        case .resolvedPlan:
            guard let plan = entry.runtimeIdentity.resolvedPlan else {
                throw MachineManagerError.persistence(
                    "resolved runtime identity has no exact plan"
                )
            }
            guard let ledger = productionResourceAdmissionLedger else {
                guard let current = status(id: id) else {
                    throw MachineManagerError.unknownMachine(id)
                }
                return current
            }
            switch try exactResourceAdmissionLease(for: plan, ledger: ledger).state {
            case .starting, .running:
                guard let current = status(id: id) else {
                    throw MachineManagerError.unknownMachine(id)
                }
                return current
            case .stopped:
                break
            case .recoveryRequired:
                throw MachineManagerError.persistence(
                    "machine \(id) resource admission requires restart reconciliation"
                )
            }
        }

        guard let legacyData = Self.readPrivateMetadata(path: machineConfigPath(id: id)),
              let decoded = try? JSONDecoder().decode(
                DoryMachineConfiguration.self,
                from: legacyData
              ), decoded == entry.configuration else {
            throw MachineManagerError.persistence(
                "authoritative machine metadata is unavailable for production planning"
            )
        }
        let authority: MachineWorkspaceAuthority
        do {
            authority = try workspaceAuthority(
                machine: entry.configuration,
                authoritativeLegacyData: legacyData
            )
        } catch {
            throw MachineManagerError.persistence(
                "workspace authority is unavailable for production planning: \(error)"
            )
        }
        let definition = authority.definition
        let canonicalDefinitionData = try Self.canonicalDefinitionData(definition)

        let plans: any DoryResolvedMachinePlanStoring = resolvedLaunchPlanStore
            ?? DoryResolvedMachinePlanRepository(root: configuration.stateDirectory)
        let planPublication: DoryDaemonVirtualMachinePlanPublication
        do {
            let existing = try plans.read(id: id)
            planPublication = .replace(expectedPlanRevision: existing.planRevision)
        } catch let error as DoryResolvedMachinePlanRepositoryError {
            switch error {
            case .planNotFound:
                planPublication = .create
            default:
                throw MachineManagerError.persistence(
                    "resolved-plan authority cannot be inspected: \(error)"
                )
            }
        } catch {
            throw MachineManagerError.persistence(
                "resolved-plan authority cannot be inspected: \(error)"
            )
        }

        guard let requirements = DoryDaemonVirtualMachinePlanningCoordinator
            .launchArtifactRequirements(for: definition) else {
            throw MachineManagerError.persistence(
                "workspace launch artifacts are not representable"
            )
        }
        let bindings = Dictionary(grouping: authority.migration.artifactBindings, by: \.reference)
        var publications: [DoryDaemonVirtualMachinePlanningArtifactPublication] = []
        publications.reserveCapacity(requirements.count)
        for requirement in requirements {
            guard let matches = bindings[requirement.reference], matches.count == 1,
                  let binding = matches.first else {
                throw MachineManagerError.persistence(
                    "workspace launch artifact has no exact managed path"
                )
            }
            let revision: UInt64?
            do { revision = try controller.authorityRevision(for: requirement.reference) }
            catch {
                throw MachineManagerError.persistence(
                    "workspace artifact authority cannot be inspected: \(error)"
                )
            }
            publications.append(DoryDaemonVirtualMachinePlanningArtifactPublication(
                reference: requirement.reference,
                path: binding.path,
                kind: requirement.kind,
                source: requirement.source,
                mutability: requirement.mutable ? .mutable : .immutable,
                expectedAuthorityRevision: revision
            ))
        }

        let request = DoryDaemonVirtualMachinePlanningTransactionRequest(
            planning: DoryDaemonVirtualMachinePlanningRequest(
                definition: definition,
                canonicalDefinitionData: canonicalDefinitionData,
                machine: authority.runtimeMachine,
                publication: planPublication
            ),
            workspacePublication: .retainExistingExact
        )
        do {
            try controller.publishResolvedPlan(
                request,
                artifacts: publications
            )
        } catch {
            throw MachineManagerError.persistence(
                "production planning failed closed: \(error)"
            )
        }
        guard let current = status(id: id),
              current.runtimeIdentity.mode == .resolvedPlan else {
            throw MachineManagerError.persistence(
                "production planning did not publish resolved runtime authority"
            )
        }
        return current
    }

    @discardableResult
    public func start(id: String) throws -> DoryMachineStatus {
        operationLock.lock()
        defer { operationLock.unlock() }
        try requireNoActivePlanningMutation(id: id)
        try refreshResolvedAdmissionForStartIfNeeded(id: id)
        let directMutation = try retainDirectWorkspaceMutationLock(id: id)
        defer { releaseDirectWorkspaceMutationLock(id: id, retention: directMutation) }
        return try startImplementation(id: id, journalLifecycle: true)
    }

    private func startImplementation(
        id: String,
        journalLifecycle: Bool
    ) throws -> DoryMachineStatus {
        switch launchPolicy {
        case .legacyCompatibility:
            return try startLegacyMachine(
                id: id,
                journalLifecycle: journalLifecycle,
                expectedDurableIdentity: nil
            )
        case .requireResolvedPlan:
            guard let registry = resolvedLaunchRegistry,
                  let resolver = resolvedLaunchPlanResolver,
                  let planStore = resolvedLaunchPlanStore,
                  let revisionProvider = resolvedPlanRevisionProvider else {
                throw MachineManagerError.persistence(
                    "resolved launch infrastructure is not installed"
                )
            }
            return try startResolvedMachine(
                id: id,
                registry: registry,
                resolver: resolver,
                planStore: planStore,
                revisionProvider: revisionProvider,
                journalLifecycle: journalLifecycle,
                expectedRuntimeIdentity: nil
            )
        case .perWorkspaceAuthority:
            let identity = try currentDurableRuntimeIdentity(id: id)
            switch identity.mode {
            case .legacyCompatibility:
                return try startLegacyMachine(
                    id: id,
                    journalLifecycle: journalLifecycle,
                    expectedDurableIdentity: identity
                )
            case .requiresReplanning:
                throw MachineManagerError.persistence(
                    "machine \(id) requires a resolved plan before launch"
                )
            case .resolvedPlan:
                guard let registry = resolvedLaunchRegistry,
                      let resolver = resolvedLaunchPlanResolver,
                      let planStore = resolvedLaunchPlanStore,
                      let revisionProvider = resolvedPlanRevisionProvider else {
                    throw MachineManagerError.persistence(
                        "resolved launch infrastructure is not installed"
                    )
                }
                return try startResolvedMachine(
                    id: id,
                    registry: registry,
                    resolver: resolver,
                    planStore: planStore,
                    revisionProvider: revisionProvider,
                    journalLifecycle: journalLifecycle,
                    expectedRuntimeIdentity: identity
                )
            }
        }
    }

    private func startLegacyMachine(
        id: String,
        journalLifecycle: Bool,
        expectedDurableIdentity: DoryMachineRuntimeIdentity?
    ) throws -> DoryMachineStatus {
        let prepared = try prepareMachineStartWithLifecycle(
            id: id,
            requiresAuthoritativeDefinition: false,
            journalLifecycle: journalLifecycle
        )
        let identity = try currentRuntimeIdentity(id: id)
        guard identity.mode == .legacyCompatibility else {
            throw MachineManagerError.persistence(
                "legacy launch requires explicit compatibility authority"
            )
        }
        if let expectedDurableIdentity {
            try revalidateDurableRuntimeIdentity(
                id: id,
                expected: expectedDurableIdentity,
                expectedMachine: prepared.authoritativeMachine
            )
        }
        let lifecycle = try journalLifecycle
            ? beginLifecycleStart(
                machine: prepared.authoritativeMachine,
                targetIdentity: identity
            )
            : nil
        do {
            if let lifecycle { try advanceLifecycleToPublishing(lifecycle) }
            let status = try spawnPreparedMachine(prepared.machine, launchBinding: nil)
            if let lifecycle, status.state != .starting {
                _ = completeCommittedLifecycle(
                    lifecycle,
                    diagnostic: "running machine has an unfinished start journal"
                )
            }
            return status
        } catch {
            if let lifecycle { failLifecycle(lifecycle, stepID: "start.failed") }
            throw error
        }
    }

    private func startResolvedMachine(
        id: String,
        registry: BackendRegistry,
        resolver: any DoryDaemonVirtualMachineLaunchPlanResolving,
        planStore: any DoryResolvedMachinePlanStoring,
        revisionProvider: ResolvedPlanRevisionProvider,
        journalLifecycle: Bool,
        expectedRuntimeIdentity: DoryMachineRuntimeIdentity?
    ) throws -> DoryMachineStatus {
        let prepared = try prepareMachineStartWithLifecycle(
            id: id,
            requiresAuthoritativeDefinition: true,
            journalLifecycle: journalLifecycle
        )
        guard let definition = prepared.definition,
              let definitionData = prepared.canonicalDefinitionData else {
            throw MachineManagerError.persistence(
                "authoritative workspace definition is unavailable for resolved launch"
            )
        }
        guard let expectedPlanRevision = revisionProvider(id), expectedPlanRevision > 0 else {
            throw MachineManagerError.persistence(
                "no resolved-plan revision is pinned for machine \(id)"
            )
        }
        let resolved: DoryDaemonVirtualMachineLaunchPlanResolution
        do {
            resolved = try resolver.resolve(DoryDaemonVirtualMachineLaunchPlanRequest(
                definition: definition,
                canonicalDefinitionData: definitionData,
                machine: prepared.machine,
                expectedPlanRevision: expectedPlanRevision
            ))
        } catch {
            throw MachineManagerError.persistence("resolved launch rejected: \(error)")
        }
        try validateResolvedLaunch(
            resolved,
            machine: prepared.machine,
            definition: definition,
            canonicalDefinitionData: definitionData
        )
        try revalidatePreparedAuthorityImmediatelyBeforeSpawn(
            prepared,
            expectedDefinition: definition,
            expectedCanonicalDefinitionData: definitionData
        )
        try revalidateResolvedPlanAuthorityImmediatelyBeforeSpawn(
            resolved,
            planStore: planStore
        )
        guard let preSpawnAuthorization = resolved.preSpawnAuthorization else {
            throw MachineManagerError.persistence(
                "resolved launch is missing final pre-spawn authorization"
            )
        }
        let runtimeIdentity = try DoryMachineRuntimeIdentity(
            resolvedPlan: resolved.resolvedPlan,
            planSHA256: resolved.resolvedPlanSHA256
        )
        if let expectedRuntimeIdentity, runtimeIdentity != expectedRuntimeIdentity {
            throw MachineManagerError.persistence(
                "resolved launch does not match the workspace's durable runtime authority"
            )
        }
        if let expectedRuntimeIdentity {
            try revalidateDurableRuntimeIdentity(
                id: id,
                expected: expectedRuntimeIdentity,
                expectedMachine: prepared.authoritativeMachine
            )
        }
        let lifecycle = try journalLifecycle
            ? beginLifecycleStart(
                machine: prepared.authoritativeMachine,
                targetIdentity: runtimeIdentity
            )
            : nil

        do {
            if let lifecycle { try advanceLifecycleToPublishing(lifecycle) }
            pendingResolvedStart = PendingResolvedMachineStart(
                machine: prepared.machine,
                plan: resolved.resolvedPlan,
                backend: resolved.backendPlan.backend,
                runtimeBuildIdentifier: resolved.resolvedPlan.backendRuntimeBuildIdentifier,
                runtimeComponents: resolved.resolvedPlan.components,
                graphics: resolved.resolvedPlan.graphics,
                devices: resolved.resolvedPlan.devices,
                planRevision: resolved.resolvedPlan.planRevision,
                planSHA256: resolved.resolvedPlanSHA256,
                preSpawnAuthorization: preSpawnAuthorization
            )
            defer { pendingResolvedStart = nil }
            let operation = registry.start(resolved.backendPlan)
            guard operation.isSuccess,
                  operation.backend == resolved.resolvedPlan.backend,
                  operation.observation?.machineID == id else {
                let failure = operation.failure?.message ?? "backend adapter returned no observation"
                throw MachineManagerError.persistence("resolved backend start failed: \(failure)")
            }
            lock.lock()
            if var entry = machines[id] {
                entry.runtimeIdentity = runtimeIdentity
                machines[id] = entry
            }
            lock.unlock()
            guard let status = status(id: id), [.starting, .running].contains(status.state) else {
                throw MachineManagerError.persistence(
                    "resolved backend did not enter MachineManager's prepared spawn path"
                )
            }
            resolvedLaunchIdentities[id] = DoryMachineResolvedLaunchIdentity(
                plan: resolved.resolvedPlan,
                planSHA256: resolved.resolvedPlanSHA256
            )
            if let lifecycle, status.state != .starting {
                _ = completeCommittedLifecycle(
                    lifecycle,
                    diagnostic: "running machine has an unfinished resolved-start journal"
                )
            }
            return status
        } catch {
            if let lifecycle { failLifecycle(lifecycle, stepID: "start.failed") }
            throw error
        }
    }

    private func revalidateResolvedPlanAuthorityImmediatelyBeforeSpawn(
        _ resolved: DoryDaemonVirtualMachineLaunchPlanResolution,
        planStore: any DoryResolvedMachinePlanStoring
    ) throws {
        let current: DoryResolvedMachinePlan
        do {
            current = try planStore.read(id: resolved.resolvedPlan.machineID)
        } catch {
            throw MachineManagerError.persistence(
                "resolved-plan authority changed during launch validation: \(error)"
            )
        }
        guard current.planRevision == resolved.resolvedPlan.planRevision,
              current == resolved.resolvedPlan,
              try Self.canonicalResolvedPlanSHA256(current)
                == resolved.resolvedPlanSHA256.lowercased() else {
            throw MachineManagerError.persistence(
                "resolved-plan authority changed during launch validation"
            )
        }
    }

    private func revalidatePreparedAuthorityImmediatelyBeforeSpawn(
        _ prepared: PreparedMachineStart,
        expectedDefinition: DoryVirtualMachineDefinition,
        expectedCanonicalDefinitionData: Data
    ) throws {
        guard let preparedLegacyData = prepared.authoritativeLegacyData,
              let currentLegacyData = Self.readPrivateMetadata(
                path: machineConfigPath(id: prepared.authoritativeMachine.id)
              ),
              currentLegacyData == preparedLegacyData,
              let decoded = try? JSONDecoder().decode(
                DoryMachineConfiguration.self,
                from: currentLegacyData
              ),
              decoded == prepared.authoritativeMachine,
              let currentDefinition = reconcileWorkspaceProjection(
                machine: prepared.authoritativeMachine,
                authoritativeLegacyData: currentLegacyData
              ),
              currentDefinition == expectedDefinition,
              try Self.canonicalDefinitionData(currentDefinition)
                == expectedCanonicalDefinitionData else {
            throw MachineManagerError.persistence(
                "machine authority changed during resolved launch validation"
            )
        }
    }

    private func performAuthorizedResolvedBackendStart(
        binding: MachineBackendLaunchBinding,
        expectedBackend: DoryVirtualizationBackendIdentity
    ) throws -> MachineBackendRuntimeObservation {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard let authorization = pendingResolvedStart,
              authorization.machine.id == binding.machineID,
              authorization.backend == binding.backend,
              binding.backend.identity == expectedBackend,
              authorization.graphics == binding.graphics,
              authorization.devices == binding.devices,
              !binding.executablePath.isEmpty else {
            pendingResolvedStart = nil
            throw MachineManagerError.persistence(
                "backend start does not match the exact resolved-plan launch contract"
            )
        }
        let executableSHA256: String
        do {
            executableSHA256 = try Self.fileSHA256(path: binding.executablePath)
        } catch {
            pendingResolvedStart = nil
            throw MachineManagerError.persistence(
                "resolved backend executable could not be verified: \(error)"
            )
        }
        let matchingComponents = authorization.runtimeComponents.filter {
            $0.componentIdentifier == binding.componentIdentifier
                && $0.buildIdentifier == authorization.runtimeBuildIdentifier
                && $0.artifactSHA256.lowercased() == executableSHA256
        }
        guard matchingComponents.count == 1 else {
            pendingResolvedStart = nil
            throw MachineManagerError.persistence(
                "resolved backend executable does not match qualified runtime evidence"
            )
        }
        // Consume before process construction so a second or delayed adapter callback cannot
        // reuse the validated context, including after a spawn failure.
        pendingResolvedStart = nil
        return MachineBackendRuntimeObservation(try spawnPreparedMachine(
            authorization.machine,
            launchBinding: binding,
            preSpawnAuthorization: authorization.preSpawnAuthorization,
            resolvedPlan: authorization.plan
        ))
    }

    private func validateResolvedLaunch(
        _ resolved: DoryDaemonVirtualMachineLaunchPlanResolution,
        machine: DoryMachineConfiguration,
        definition: DoryVirtualMachineDefinition,
        canonicalDefinitionData: Data
    ) throws {
        let plan = resolved.resolvedPlan
        let capability = resolved.backendPlan.capability
        let definitionDigest = SHA256.hash(data: canonicalDefinitionData)
            .map { String(format: "%02x", $0) }.joined()
        let canonicalPlanDigest = try Self.canonicalResolvedPlanSHA256(plan)
        let expectedMemoryBytes = machine.memoryMB.multipliedReportingOverflow(by: 1_048_576)
        guard !expectedMemoryBytes.overflow,
              resolved.revalidation.mayStart,
              plan.validate().isEmpty,
              plan.machineID == machine.id,
              plan.definitionRevision == definition.lifecycle.revision,
              plan.definitionSHA256?.lowercased() == definitionDigest,
              resolved.resolvedPlanSHA256.lowercased() == canonicalPlanDigest,
              plan.resourceAdmission?.admittedVirtualCPUCount == UInt64(machine.cpuCount),
              plan.resourceAdmission?.admittedMemoryBytes == expectedMemoryBytes.partialValue,
              plan.resourceAdmission?.admittedStorageBytes == definition.resources.diskBytes,
              resolved.backendPlan.machine == machine,
              resolved.backendPlan.backend.identity == plan.backend,
              resolved.backendPlan.backend.implementationIdentifier
                == plan.backendImplementationIdentifier,
              capability.request.guest == plan.guest,
              capability.request.backend == plan.backend,
              capability.request.bootMedia == plan.bootMedia.media,
              capability.request.devices == plan.devices,
              capability.request.graphics == plan.graphics,
              capability.request.virtualHardwareABIVersion == plan.virtualHardwareABIVersion,
              capability.availability.supportTier == plan.supportTier,
              capability.availability.isUsable,
              capability.resolvedDevices == plan.devices else {
            throw MachineManagerError.persistence(
                "resolved plan does not exactly match current definition and adapter evidence"
            )
        }
    }

    private static func canonicalResolvedPlanSHA256(
        _ plan: DoryResolvedMachinePlan
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(plan)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func exactResourceAdmissionLease(
        for plan: DoryResolvedMachinePlan,
        ledger: DoryVirtualMachineResourceAdmissionLedger
    ) throws -> DoryVirtualMachineResourceAdmissionLease {
        guard let admission = plan.resourceAdmission,
              let definitionSHA256 = plan.definitionSHA256 else {
            throw MachineManagerError.persistence(
                "resolved plan has no exact resource-admission authority"
            )
        }
        let snapshot: DoryVirtualMachineResourceAdmissionLedgerSnapshot
        do { snapshot = try ledger.snapshot() }
        catch {
            throw MachineManagerError.persistence(
                "resource-admission ledger cannot be inspected: \(error)"
            )
        }
        let matches = snapshot.leases.filter { $0.leaseID == admission.admissionIdentity }
        guard matches.count == 1, let lease = matches.first,
              lease.binding.machineID == plan.machineID,
              lease.binding.definitionRevision == plan.definitionRevision,
              lease.binding.definitionSHA256.lowercased() == definitionSHA256.lowercased(),
              lease.binding.plannedPlanRevision == plan.planRevision,
              lease.boundPlanSHA256?.lowercased()
                == (try Self.canonicalResolvedPlanSHA256(plan)),
              lease.evidence == admission else {
            throw MachineManagerError.persistence(
                "resolved plan does not match its durable resource-admission lease"
            )
        }
        return lease
    }

    private func refreshResolvedAdmissionForStartIfNeeded(id: String) throws {
        guard launchPolicy == .perWorkspaceAuthority,
              let controller = productionPlanningController,
              let ledger = productionResourceAdmissionLedger else { return }
        let identity = try currentDurableRuntimeIdentity(id: id)
        guard identity.mode == .resolvedPlan, let plan = identity.resolvedPlan else { return }
        var lease = try exactResourceAdmissionLease(for: plan, ledger: ledger)
        switch lease.state {
        case .starting:
            return
        case .running:
            guard status(id: id)?.state != .running else { return }
            do {
                lease = try ledger.markStopped(
                    leaseID: lease.leaseID,
                    expectedLeaseRevision: lease.leaseRevision
                )
            } catch {
                throw MachineManagerError.persistence(
                    "stale running resource admission could not be reconciled: \(error)"
                )
            }
        case .recoveryRequired:
            guard status(id: id)?.state != .running else {
                throw MachineManagerError.persistence(
                    "running machine has an ambiguous expired resource admission"
                )
            }
            do {
                lease = try ledger.reconcileExpiredStart(
                    leaseID: lease.leaseID,
                    observedRuntimeState: .stopped,
                    expectedLeaseRevision: lease.leaseRevision
                )
            } catch {
                throw MachineManagerError.persistence(
                    "expired resource admission could not be reconciled: \(error)"
                )
            }
        case .stopped:
            break
        }
        guard lease.state == .stopped else {
            throw MachineManagerError.persistence(
                "resource admission did not settle to stopped before replanning"
            )
        }
        _ = try resolveAndPublishProductionPlan(id: id, controller: controller)
    }

    private func reconcileResourceAdmissionsAfterDaemonRestart() throws {
        guard let ledger = productionResourceAdmissionLedger else { return }
        let snapshot: DoryVirtualMachineResourceAdmissionLedgerSnapshot
        do { snapshot = try ledger.snapshot() }
        catch {
            throw MachineManagerError.persistence(
                "resource-admission restart reconciliation failed: \(error)"
            )
        }
        let loadedMachineIDs: Set<String>
        lock.lock()
        loadedMachineIDs = Set(machines.keys)
        lock.unlock()
        for lease in snapshot.leases {
            let machineIsLoaded = loadedMachineIDs.contains(lease.binding.machineID)
            let machinePathExists = Self.pathEntryExists(
                machineStateDirectory(id: lease.binding.machineID)
            )
            do {
                if !machineIsLoaded, !machinePathExists, lease.state == .stopped {
                    try ledger.releaseStorageReservation(
                        leaseID: lease.leaseID,
                        expectedLeaseRevision: lease.leaseRevision
                    )
                    continue
                }
                guard machineIsLoaded else { continue }
                switch lease.state {
                case .running:
                    _ = try ledger.markStopped(
                        leaseID: lease.leaseID,
                        expectedLeaseRevision: lease.leaseRevision
                    )
                case .recoveryRequired:
                    _ = try ledger.reconcileExpiredStart(
                        leaseID: lease.leaseID,
                        observedRuntimeState: .stopped,
                        expectedLeaseRevision: lease.leaseRevision
                    )
                case .starting, .stopped:
                    break
                }
            } catch {
                throw MachineManagerError.persistence(
                    "resource admission for \(lease.binding.machineID) could not be reconciled: \(error)"
                )
            }
        }
    }

    private func markResolvedAdmissionRunning(
        plan: DoryResolvedMachinePlan
    ) throws {
        guard let ledger = productionResourceAdmissionLedger else { return }
        let lease = try exactResourceAdmissionLease(for: plan, ledger: ledger)
        guard lease.state == .starting else {
            throw MachineManagerError.persistence(
                "resolved start requires a starting resource-admission lease"
            )
        }
        do {
            _ = try ledger.markRunning(
                leaseID: lease.leaseID,
                plan: plan,
                hostFacts: lease.hostFacts,
                expectedLeaseRevision: lease.leaseRevision
            )
        } catch {
            throw MachineManagerError.persistence(
                "resource admission could not commit running state: \(error)"
            )
        }
    }

    private func markResolvedAdmissionStopped(
        plan: DoryResolvedMachinePlan?
    ) throws {
        guard let plan, let ledger = productionResourceAdmissionLedger else { return }
        let lease = try exactResourceAdmissionLease(for: plan, ledger: ledger)
        do {
            switch lease.state {
            case .starting, .running:
                _ = try ledger.markStopped(
                    leaseID: lease.leaseID,
                    expectedLeaseRevision: lease.leaseRevision
                )
            case .recoveryRequired:
                _ = try ledger.reconcileExpiredStart(
                    leaseID: lease.leaseID,
                    observedRuntimeState: .stopped,
                    expectedLeaseRevision: lease.leaseRevision
                )
            case .stopped:
                break
            }
        } catch {
            throw MachineManagerError.persistence(
                "resource admission could not commit stopped state: \(error)"
            )
        }
    }

    private func prepareRetainedResolvedAdmissionForRestart(
        plan: DoryResolvedMachinePlan?
    ) throws {
        guard let plan, let ledger = productionResourceAdmissionLedger else { return }
        let lease = try exactResourceAdmissionLease(for: plan, ledger: ledger)
        switch lease.state {
        case .running:
            do {
                _ = try ledger.prepareRetainedRunningForRestart(
                    leaseID: lease.leaseID,
                    plan: plan,
                    expectedLeaseRevision: lease.leaseRevision
                )
            } catch {
                throw MachineManagerError.persistence(
                    "retained resource admission could not authorize restart: \(error)"
                )
            }
        case .starting:
            return
        case .stopped, .recoveryRequired:
            throw MachineManagerError.persistence(
                "retained resource admission is unavailable for restart"
            )
        }
    }

    private func releaseResolvedAdmissionStorage(
        machineID: String,
        plan: DoryResolvedMachinePlan?
    ) throws {
        guard let ledger = productionResourceAdmissionLedger else { return }
        let lease: DoryVirtualMachineResourceAdmissionLease
        if let plan {
            lease = try exactResourceAdmissionLease(for: plan, ledger: ledger)
        } else {
            let matches = try ledger.snapshot().leases.filter {
                $0.binding.machineID == machineID
            }
            guard matches.count <= 1 else {
                throw MachineManagerError.persistence(
                    "machine has ambiguous resource storage reservations"
                )
            }
            guard let retained = matches.first else { return }
            lease = retained
        }
        guard lease.state == .stopped else {
            throw MachineManagerError.persistence(
                "resource storage can be released only after the machine is stopped"
            )
        }
        do {
            try ledger.releaseStorageReservation(
                leaseID: lease.leaseID,
                expectedLeaseRevision: lease.leaseRevision
            )
        } catch {
            throw MachineManagerError.persistence(
                "resource storage reservation could not be released: \(error)"
            )
        }
    }

    private static func fileSHA256(path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw MachineManagerError.persistence("cannot open runtime executable at \(path)")
        }
        defer { _ = try? handle.close() }
        var hash = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func prepareMachineStart(
        id: String,
        requiresAuthoritativeDefinition: Bool
    ) throws -> PreparedMachineStart {
        lock.lock()
        guard let entry = machines[id] else {
            lock.unlock()
            throw MachineManagerError.unknownMachine(id)
        }
        if entry.process?.isRunning == true {
            lock.unlock()
            throw MachineManagerError.alreadyRunning(id)
        }
        lock.unlock()

        let authoritativeMachine = entry.configuration
        try ensureInstalledLinuxBootBundleIfNeeded(authoritativeMachine)
        try materializeInstalledLinuxBootRuntimeIfNeeded(authoritativeMachine)
        let authoritativeLegacyData = Self.readPrivateMetadata(
            path: machineConfigPath(id: authoritativeMachine.id)
        )
        var authoritativeDefinition: DoryVirtualMachineDefinition?
        var runtimeMachine = authoritativeMachine
        if let authoritativeLegacyData {
            if requiresAuthoritativeDefinition {
                guard let decoded = try? JSONDecoder().decode(
                    DoryMachineConfiguration.self,
                    from: authoritativeLegacyData
                ), decoded == authoritativeMachine else {
                    throw MachineManagerError.persistence(
                        "authoritative machine metadata changed before resolved launch"
                    )
                }
            }
            // Boot-bundle materialization can change authoritative inspection facts without
            // changing machine.json. Reconcile those facts immediately before launch.
            authoritativeDefinition = reconcileWorkspaceProjection(
                machine: authoritativeMachine,
                authoritativeLegacyData: authoritativeLegacyData
            )
            if authoritativeDefinition != nil {
                do {
                    runtimeMachine = try workspaceAuthority(
                        machine: authoritativeMachine,
                        authoritativeLegacyData: authoritativeLegacyData
                    ).runtimeMachine
                } catch {
                    throw MachineManagerError.persistence(
                        "workspace runtime projection is unavailable: \(error)"
                    )
                }
            }
        } else if requiresAuthoritativeDefinition {
            throw MachineManagerError.persistence(
                "authoritative machine metadata is unavailable for resolved launch"
            )
        }
        try Self.validateLaunchConfiguration(runtimeMachine)
        try validateManagedMachineArtifacts(runtimeMachine)
        if !requiresAuthoritativeDefinition {
            try validateRuntimeAvailability(runtimeMachine)
        }
        if requiresAuthoritativeDefinition, authoritativeDefinition == nil {
            throw MachineManagerError.persistence(
                "authoritative workspace projection is unavailable for resolved launch"
            )
        }
        let definitionData = try authoritativeDefinition.map(Self.canonicalDefinitionData)
        return PreparedMachineStart(
            machine: runtimeMachine,
            authoritativeMachine: authoritativeMachine,
            definition: authoritativeDefinition,
            canonicalDefinitionData: definitionData,
            authoritativeLegacyData: authoritativeLegacyData
        )
    }

    private func prepareMachineStartWithLifecycle(
        id: String,
        requiresAuthoritativeDefinition: Bool,
        journalLifecycle: Bool
    ) throws -> PreparedMachineStart {
        guard journalLifecycle else {
            return try prepareMachineStart(
                id: id,
                requiresAuthoritativeDefinition: requiresAuthoritativeDefinition
            )
        }
        let lifecycle = try beginLifecycleStartPreparation(id: id)
        do {
            try advanceLifecycleToPublishing(lifecycle)
            let prepared = try prepareMachineStart(
                id: id,
                requiresAuthoritativeDefinition: requiresAuthoritativeDefinition
            )
#if DEBUG
            try injectLifecycleFault(.startAfterPreparation)
#endif
            guard completeCommittedLifecycle(
                lifecycle,
                diagnostic: "start preparation committed; journal completion requires recovery"
            ) else {
                throw MachineLifecycleJournalCompletionPending()
            }
            return prepared
        } catch {
#if DEBUG
            if error is MachineLifecycleInjectedCrash { throw error }
#endif
            if error is MachineLifecycleJournalCompletionPending {
                throw MachineManagerError.persistence(
                    "start preparation committed but journal completion requires recovery"
                )
            }
            failLifecycle(lifecycle, stepID: "start-preparation.failed")
            throw error
        }
    }

    private func spawnPreparedMachine(
        _ preparedMachine: DoryMachineConfiguration,
        launchBinding: MachineBackendLaunchBinding?,
        preSpawnAuthorization: DoryDaemonVirtualMachinePreSpawnAuthorization? = nil,
        resolvedPlan: DoryResolvedMachinePlan? = nil
    ) throws -> DoryMachineStatus {
        lock.lock()
        guard var entry = machines[preparedMachine.id] else {
            lock.unlock()
            throw MachineManagerError.unknownMachine(preparedMachine.id)
        }
        guard entry.configuration == preparedMachine else {
            lock.unlock()
            throw MachineManagerError.persistence(
                "machine configuration changed after launch validation"
            )
        }
        if entry.process?.isRunning == true {
            lock.unlock()
            throw MachineManagerError.alreadyRunning(preparedMachine.id)
        }
        let id = preparedMachine.id
        let handoffPath = configuration.requiresReadyHandoff ? handoffSocketPath(id: id) : nil
        let launchID = UUID()
        let handoffServer: VmmHandoffServer?
        do {
            handoffServer = try handoffPath.map { path in
                let server = VmmHandoffServer(path: path) { [weak self] result in
                    self?.handleHandoff(machineID: id, launchID: launchID, result: result)
                }
                try server.start()
                return server
            }
        } catch {
            lock.unlock()
            throw error
        }
        let processConfiguration: HvProcessConfiguration
        do {
            // This single-use daemon-owned check deliberately sits after all persisted
            // machine/plan validation and immediately before any path-derived launch arguments
            // are read. Failure consumes the token and cannot reach processStarter.
            if let launchBinding {
                guard let preSpawnAuthorization else {
                    throw MachineManagerError.persistence(
                        "resolved launch is missing final pre-spawn authorization"
                    )
                }
                try preSpawnAuthorization.authorize()
                try revalidateMaterializedInstalledLinuxBootRuntimeImmediatelyBeforeSpawn(
                    entry.configuration,
                    launchBinding: launchBinding
                )
            }
            processConfiguration = try self.processConfiguration(
                for: entry.configuration,
                handoffPath: handoffPath,
                resolvedLaunchBinding: launchBinding
            )
        } catch {
            handoffServer?.stop()
            lock.unlock()
            do { try markResolvedAdmissionStopped(plan: resolvedPlan) }
            catch let settlementError {
                throw MachineManagerError.persistence(
                    "resolved launch failed before spawn: \(error); "
                        + "resource settlement failed: \(settlementError)"
                )
            }
            throw error
        }
        let process = HvProcess(
            configuration: processConfiguration,
            unexpectedTerminationHandler: { [weak self] termination in
                self?.handleUnexpectedMachineProcessTermination(
                    machineID: id,
                    launchID: launchID,
                    termination: termination
                )
            }
        )
        let handoffReadyTimeout = handoffReadyTimeout(for: entry.configuration)
        entry.process = process
        entry.handoffServer = handoffServer
        entry.handoff = nil
        entry.launchID = launchID
        entry.runtimeAddress = nil
        entry.currentBalloonTargetMB = nil
        entry.activeResolvedPlan = resolvedPlan
        let requiresAdmissionCommit = resolvedPlan != nil
            && productionResourceAdmissionLedger != nil
        entry.state = configuration.requiresReadyHandoff || requiresAdmissionCommit
            ? .starting : .running
        entry.lastError = nil
        machines[id] = entry
        lock.unlock()

        do {
            try processStarter(process)
        } catch {
            lock.lock()
            machines[id]?.handoffServer?.stop()
            machines[id]?.handoffServer = nil
            machines[id]?.launchID = nil
            machines[id]?.runtimeAddress = nil
            machines[id]?.activeResolvedPlan = nil
            machines[id]?.state = .failed
            machines[id]?.lastError = "\(error)"
            lock.unlock()
            process.stop(timeout: DoryEngineShutdownTiming.hostTerminationSeconds)
            do { try markResolvedAdmissionStopped(plan: resolvedPlan) }
            catch let settlementError {
                throw MachineManagerError.persistence(
                    "resolved process start failed: \(error); "
                        + "resource settlement failed: \(settlementError)"
                )
            }
            throw error
        }
        if configuration.requiresReadyHandoff {
            scheduleHandoffTimeout(id: id, process: process, timeout: handoffReadyTimeout)
        } else if requiresAdmissionCommit, let resolvedPlan {
            do {
                try markResolvedAdmissionRunning(plan: resolvedPlan)
                lock.lock()
                if machines[id]?.launchID == launchID {
                    machines[id]?.state = .running
                }
                lock.unlock()
            } catch {
                process.stop(timeout: DoryEngineShutdownTiming.hostTerminationSeconds)
                lock.lock()
                if machines[id]?.launchID == launchID {
                    machines[id]?.state = .failed
                    machines[id]?.lastError = "\(error)"
                    machines[id]?.activeResolvedPlan = nil
                }
                lock.unlock()
                try? markResolvedAdmissionStopped(plan: resolvedPlan)
                throw error
            }
        }
        return status(id: id) ?? DoryMachineStatus(id: id, state: .running)
    }

    private func startAndWaitUntilReady(id: String) throws -> DoryMachineStatus {
        try startAndWaitUntilReady(id: id, journalLifecycle: true)
    }

    private func startAndWaitUntilReady(
        id: String,
        journalLifecycle: Bool
    ) throws -> DoryMachineStatus {
        let started = try startImplementation(id: id, journalLifecycle: journalLifecycle)
        guard started.state == .starting else { return started }

        let handoffReadyTimeout = handoffReadyTimeout(
            displayMode: started.displayMode,
            bootMode: started.bootMode
        )
        let deadline = Date().addingTimeInterval(handoffReadyTimeout + 1)
        while Date() < deadline {
            guard let current = status(id: id) else {
                throw MachineManagerError.unknownMachine(id)
            }
            switch current.state {
            case .running:
                return current
            case .failed:
                throw MachineManagerError.persistence(
                    "vmm ready handoff failed for \(id): \(current.lastError ?? "unknown error")"
                )
            case .starting:
                Thread.sleep(forTimeInterval: 0.01)
            default:
                throw MachineManagerError.persistence(
                    "vmm ready handoff for \(id) ended in unexpected state \(current.state.rawValue)"
                )
            }
        }
        throw MachineManagerError.persistence("vmm ready handoff timed out for \(id)")
    }

    private func handoffReadyTimeout(for machine: DoryMachineConfiguration) -> TimeInterval {
        handoffReadyTimeout(displayMode: machine.displayMode, bootMode: machine.bootMode)
    }

    private func handoffReadyTimeout(
        displayMode: DoryMachineDisplayMode,
        bootMode: DoryMachineBootMode
    ) -> TimeInterval {
        if displayMode == .desktop {
            return configuration.desktopHandoffReadyTimeoutSeconds
        }
        return configuration.handoffReadyTimeoutSeconds
    }

    private func scheduleHandoffTimeout(id: String, process: HvProcess, timeout: TimeInterval) {
        // A VMM that boots but never completes the ready handoff would otherwise leave the
        // machine `.starting` forever. Bound the wait: if this exact launch is still starting
        // when the deadline passes, mark it failed and tear the helper down.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard var entry = self.machines[id],
                  entry.state == .starting,
                  entry.process === process else {
                self.lock.unlock()
                return
            }
            entry.handoffServer?.stop()
            entry.handoffServer = nil
            entry.handoff = nil
            entry.launchID = nil
            entry.runtimeAddress = nil
            entry.currentBalloonTargetMB = nil
            entry.state = .failed
            entry.lastError = "vmm ready handoff timed out after \(Int(timeout))s"
            let admissionPlan = entry.activeResolvedPlan
            entry.activeResolvedPlan = nil
            self.machines[id] = entry
            self.lock.unlock()
            process.stop(timeout: DoryEngineShutdownTiming.hostTerminationSeconds)
            self.operationLock.lock()
            try? self.markResolvedAdmissionStopped(plan: admissionPlan)
            self.failActiveStartLifecycle(id: id, stepID: "start.readiness-timeout")
            self.operationLock.unlock()
        }
    }

    private func handleUnexpectedMachineProcessTermination(
        machineID: String,
        launchID: UUID,
        termination: HvProcessTermination
    ) {
        var handoffServer: VmmHandoffServer?
        var admissionPlan: DoryResolvedMachinePlan?
        lock.lock()
        guard var entry = machines[machineID],
              entry.launchID == launchID,
              [.starting, .running, .paused].contains(entry.state),
              entry.process?.isRunningOrRestarting != true else {
            lock.unlock()
            return
        }
        handoffServer = entry.handoffServer
        admissionPlan = entry.activeResolvedPlan
        entry.handoffServer = nil
        entry.handoff = nil
        entry.launchID = nil
        entry.runtimeAddress = nil
        entry.currentBalloonTargetMB = nil
        entry.activeResolvedPlan = nil
        entry.state = .failed
        entry.lastError = "dory-vmm \(termination.description)"
        machines[machineID] = entry
        lock.unlock()

        operationLock.lock()
        try? markResolvedAdmissionStopped(plan: admissionPlan)
        failActiveStartLifecycle(id: machineID, stepID: "start.helper-exited")
        operationLock.unlock()
        handoffServer?.stop()
    }

    public func stop(id: String) throws -> DoryMachineStatus {
        operationLock.lock()
        defer { operationLock.unlock() }
        try requireNoActivePlanningMutation(id: id)
        try cancelActiveStartLifecycleIfNeeded(id: id, reason: "start.cancelled-by-stop")
        let directMutation = try retainDirectWorkspaceMutationLock(id: id)
        defer { releaseDirectWorkspaceMutationLock(id: id, retention: directMutation) }
        return try stopImplementation(id: id, journalLifecycle: true)
    }

    public func pause(id: String) throws -> DoryMachineStatus {
        operationLock.lock()
        defer { operationLock.unlock() }
        try requireNoActivePlanningMutation(id: id)
        let directMutation = try retainDirectWorkspaceMutationLock(id: id)
        defer { releaseDirectWorkspaceMutationLock(id: id, retention: directMutation) }
        let identity = try currentRuntimeIdentity(id: id)
        switch identity.mode {
        case .legacyCompatibility:
            return try pauseImplementation(id: id, journalLifecycle: true)
        case .requiresReplanning:
            throw MachineManagerError.persistence(
                "machine \(id) requires replanning and cannot be paused"
            )
        case .resolvedPlan:
            guard let backend = identity.resolvedPlan?.backend,
                  let registry = resolvedLaunchRegistry else {
                throw MachineManagerError.persistence(
                    "resolved pause infrastructure is not installed"
                )
            }
            let result = registry.pause(.init(machineID: id, backend: backend))
            guard result.isSuccess, result.observation?.machineID == id,
                  result.observation?.state == .paused else {
                throw MachineManagerError.persistence(
                    "resolved backend pause failed: "
                        + (result.failure?.message ?? "backend returned no paused observation")
                )
            }
            return status(id: id) ?? DoryMachineStatus(id: id, state: .paused)
        }
    }

    public func resume(id: String) throws -> DoryMachineStatus {
        operationLock.lock()
        defer { operationLock.unlock() }
        try requireNoActivePlanningMutation(id: id)
        let directMutation = try retainDirectWorkspaceMutationLock(id: id)
        defer { releaseDirectWorkspaceMutationLock(id: id, retention: directMutation) }
        let identity = try currentRuntimeIdentity(id: id)
        switch identity.mode {
        case .legacyCompatibility:
            return try resumeImplementation(id: id, journalLifecycle: true)
        case .requiresReplanning:
            throw MachineManagerError.persistence(
                "machine \(id) requires replanning and cannot be resumed"
            )
        case .resolvedPlan:
            guard let backend = identity.resolvedPlan?.backend,
                  let registry = resolvedLaunchRegistry else {
                throw MachineManagerError.persistence(
                    "resolved resume infrastructure is not installed"
                )
            }
            let result = registry.resume(.init(machineID: id, backend: backend))
            guard result.isSuccess, result.observation?.machineID == id,
                  result.observation?.state == .running else {
                throw MachineManagerError.persistence(
                    "resolved backend resume failed: "
                        + (result.failure?.message ?? "backend returned no running observation")
                )
            }
            return status(id: id) ?? DoryMachineStatus(id: id, state: .running)
        }
    }

    public func restart(id: String) throws -> DoryMachineStatus {
        operationLock.lock()
        defer { operationLock.unlock() }
        try requireNoActivePlanningMutation(id: id)
        let directMutation = try retainDirectWorkspaceMutationLock(id: id)
        defer { releaseDirectWorkspaceMutationLock(id: id, retention: directMutation) }

        lock.lock()
        guard let entry = machines[id] else {
            lock.unlock()
            throw MachineManagerError.unknownMachine(id)
        }
        guard [.running, .paused].contains(entry.state), entry.process != nil else {
            lock.unlock()
            throw MachineManagerError.persistence(
                "machine \(id) must be running or paused before restart"
            )
        }
        lock.unlock()

        _ = try stopImplementation(id: id, journalLifecycle: true)
        try refreshResolvedAdmissionForStartIfNeeded(id: id)
        return try startImplementation(id: id, journalLifecycle: true)
    }

    private func performAuthorizedResolvedBackendPause(
        id: String,
        expectedBackend: DoryVirtualizationBackendIdentity
    ) throws -> DoryMachineStatus {
        let identity = try currentRuntimeIdentity(id: id)
        guard identity.mode == .resolvedPlan,
              identity.resolvedPlan?.backend == expectedBackend else {
            throw MachineManagerError.persistence(
                "resolved pause adapter does not match durable runtime authority"
            )
        }
        return try pauseImplementation(id: id, journalLifecycle: true)
    }

    private func performAuthorizedResolvedBackendResume(
        id: String,
        expectedBackend: DoryVirtualizationBackendIdentity
    ) throws -> DoryMachineStatus {
        let identity = try currentRuntimeIdentity(id: id)
        guard identity.mode == .resolvedPlan,
              identity.resolvedPlan?.backend == expectedBackend else {
            throw MachineManagerError.persistence(
                "resolved resume adapter does not match durable runtime authority"
            )
        }
        return try resumeImplementation(id: id, journalLifecycle: true)
    }

    private func pauseImplementation(
        id: String,
        journalLifecycle: Bool
    ) throws -> DoryMachineStatus {
        lock.lock()
        guard let entry = machines[id] else {
            lock.unlock()
            throw MachineManagerError.unknownMachine(id)
        }
        guard entry.state == .running, let process = entry.process else {
            lock.unlock()
            throw MachineManagerError.persistence("machine \(id) is not running")
        }
        let machine = entry.configuration
        let runtimeIdentity = entry.runtimeIdentity
        lock.unlock()
        let lifecycle = try journalLifecycle
            ? beginLifecyclePause(machine: machine, runtimeIdentity: runtimeIdentity)
            : nil
        do {
            if let lifecycle { try advanceLifecycleToPublishing(lifecycle) }
            guard process.suspend() else {
                throw MachineManagerError.persistence("could not pause machine \(id)")
            }
            lock.lock()
            guard var current = machines[id], current.process === process,
                  current.state == .running else {
                lock.unlock()
                _ = process.resume()
                throw MachineManagerError.persistence(
                    "machine \(id) changed while pause was being committed"
                )
            }
            current.state = .paused
            current.lastError = nil
            machines[id] = current
            lock.unlock()
            if let lifecycle {
                _ = completeCommittedLifecycle(
                    lifecycle,
                    diagnostic: "paused machine has an unfinished pause journal"
                )
            }
            return status(id: id) ?? DoryMachineStatus(id: id, state: .paused)
        } catch {
            if let lifecycle { failLifecycle(lifecycle, stepID: "pause.failed") }
            throw error
        }
    }

    private func resumeImplementation(
        id: String,
        journalLifecycle: Bool
    ) throws -> DoryMachineStatus {
        lock.lock()
        guard let entry = machines[id] else {
            lock.unlock()
            throw MachineManagerError.unknownMachine(id)
        }
        guard entry.state == .paused, let process = entry.process else {
            lock.unlock()
            throw MachineManagerError.persistence("machine \(id) is not paused")
        }
        let machine = entry.configuration
        let runtimeIdentity = entry.runtimeIdentity
        lock.unlock()
        let lifecycle = try journalLifecycle
            ? beginLifecycleResume(machine: machine, runtimeIdentity: runtimeIdentity)
            : nil
        do {
            if let lifecycle { try advanceLifecycleToPublishing(lifecycle) }
            guard process.resume() else {
                throw MachineManagerError.persistence("could not resume machine \(id)")
            }
            lock.lock()
            guard var current = machines[id], current.process === process,
                  current.state == .paused else {
                lock.unlock()
                _ = process.suspend()
                throw MachineManagerError.persistence(
                    "machine \(id) changed while resume was being committed"
                )
            }
            current.state = .running
            current.lastError = nil
            machines[id] = current
            lock.unlock()
            if let lifecycle {
                _ = completeCommittedLifecycle(
                    lifecycle,
                    diagnostic: "resumed machine has an unfinished resume journal"
                )
            }
            return status(id: id) ?? DoryMachineStatus(id: id, state: .running)
        } catch {
            if let lifecycle { failLifecycle(lifecycle, stepID: "resume.failed") }
            throw error
        }
    }

    private func stopImplementation(
        id: String,
        journalLifecycle: Bool,
        preserveResolvedAdmissionForRestart: Bool = false
    ) throws -> DoryMachineStatus {
        lock.lock()
        guard var entry = machines[id] else {
            lock.unlock()
            throw MachineManagerError.unknownMachine(id)
        }
        let sourceState = lifecycleState(for: entry.state)
        let wasActive = [.starting, .running, .paused].contains(entry.state)
            && entry.process != nil
        let machine = entry.configuration
        let runtimeIdentity = entry.runtimeIdentity
        let admissionPlan = entry.activeResolvedPlan ?? runtimeIdentity.resolvedPlan
        lock.unlock()
        let lifecycle = try journalLifecycle && wasActive
            ? beginLifecycleStop(
                machine: machine,
                runtimeIdentity: runtimeIdentity,
                sourceState: sourceState
            )
            : nil
        var stopCommitted = false
        do {
            if let lifecycle { try advanceLifecycleToPublishing(lifecycle) }
            lock.lock()
            guard let current = machines[id] else {
                lock.unlock()
                throw MachineManagerError.unknownMachine(id)
            }
            entry = current
            let process = entry.process
            let handoffServer = entry.handoffServer
            entry.process = nil
            entry.handoffServer = nil
            entry.handoff = nil
            entry.launchID = nil
            entry.runtimeAddress = nil
            entry.currentBalloonTargetMB = nil
            entry.activeResolvedPlan = nil
            entry.state = .stopped
            machines[id] = entry
            lock.unlock()

            handoffServer?.stop()
            process?.stop(timeout: DoryEngineShutdownTiming.hostTerminationSeconds)
            stopCommitted = true
            if !preserveResolvedAdmissionForRestart {
                try markResolvedAdmissionStopped(plan: admissionPlan)
            }
#if DEBUG
            try injectLifecycleFault(.stopAfterProcessStop)
#endif
            if let lifecycle {
                _ = completeCommittedLifecycle(
                    lifecycle,
                    diagnostic: "stopped machine has an unfinished stop journal"
                )
            }
            return status(id: id) ?? DoryMachineStatus(id: id, state: .stopped)
        } catch {
#if DEBUG
            if error is MachineLifecycleInjectedCrash { throw error }
#endif
            if stopCommitted {
                if let lifecycle {
                    activeLifecycleOperations.removeValue(forKey: id)
                    lifecycle.releaseLease()
                }
                lock.lock()
                machines[id]?.lastError = "machine stopped but resource settlement requires recovery: \(error)"
                lock.unlock()
                throw error
            }
            if let lifecycle { failLifecycle(lifecycle, stepID: "stop.failed") }
            throw error
        }
    }

    public func stopAll() {
        operationLock.lock()
        defer { operationLock.unlock() }
        lock.lock()
        let runningEntries = machines.map { id, entry in
            (
                id: id,
                process: entry.process,
                handoffServer: entry.handoffServer,
                admissionPlan: entry.activeResolvedPlan ?? entry.runtimeIdentity.resolvedPlan
            )
        }
        for id in machines.keys {
            machines[id]?.process = nil
            machines[id]?.handoffServer = nil
            machines[id]?.handoff = nil
            machines[id]?.launchID = nil
            machines[id]?.runtimeAddress = nil
            machines[id]?.currentBalloonTargetMB = nil
            machines[id]?.activeResolvedPlan = nil
            machines[id]?.state = .stopped
        }
        lock.unlock()

        for entry in runningEntries {
            entry.handoffServer?.stop()
            entry.process?.stop(timeout: DoryEngineShutdownTiming.hostTerminationSeconds)
            try? markResolvedAdmissionStopped(plan: entry.admissionPlan)
        }
    }

    public func delete(id: String) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        // Reject traversal ids before any path is derived: delete() removes the machine's
        // state directory, so a "." / ".." id must never reach machineStateDirectory(id:).
        guard Self.isValidID(id) else {
            throw MachineManagerError.invalidID(id)
        }
        try requireNoActivePlanningMutation(id: id)
        try cancelActiveStartLifecycleIfNeeded(id: id, reason: "start.cancelled-by-delete")
        let directMutation = try retainDirectWorkspaceMutationLock(id: id)
        defer { releaseDirectWorkspaceMutationLock(id: id, retention: directMutation) }
        lock.lock()
        guard let sourceEntry = machines[id] else {
            lock.unlock()
            throw MachineManagerError.unknownMachine(id)
        }
        lock.unlock()
        let lifecycle = try beginLifecycleDelete(
            machine: sourceEntry.configuration,
            runtimeIdentity: sourceEntry.runtimeIdentity,
            sourceState: lifecycleState(for: sourceEntry.state)
        )
        var deletionCommitted = false

        do {
            try advanceLifecycleToPublishing(lifecycle)
            _ = try stopImplementation(id: id, journalLifecycle: false)
            lock.lock()
            guard machines.removeValue(forKey: id) != nil else {
                lock.unlock()
                throw MachineManagerError.unknownMachine(id)
            }
            deletingMachineIDs.insert(id)
            lock.unlock()

            let fileManager = FileManager.default
            let statePath = machineStateDirectory(id: id)
            var quarantinePath: String?
            if fileManager.fileExists(atPath: statePath) {
                let quarantine = lifecycleDeletionQuarantinePath(
                    machineID: id,
                    operationID: lifecycle.operation.operationID
                )
                try fileManager.moveItem(atPath: statePath, toPath: quarantine)
                quarantinePath = quarantine
#if DEBUG
                try injectLifecycleFault(.deleteAfterQuarantine)
#endif
            }

            lock.lock()
            deletingMachineIDs.remove(id)
            workspaceProjectionDiagnostics.removeValue(forKey: id)
            lock.unlock()
            resolvedLaunchIdentities.removeValue(forKey: id)

            try? FileManager.default.removeItem(atPath: machineRuntimeDirectory(id: id))
            if let quarantinePath {
                try fileManager.removeItem(atPath: quarantinePath)
            }
            // Once both the authoritative state and its quarantine are gone, deletion is
            // committed. A later journal fsync/transition failure must not resurrect an
            // in-memory entry whose storage no longer exists. Recovery can deterministically
            // finish the still-durable deleting operation on the next daemon start.
            deletionCommitted = true
            try releaseResolvedAdmissionStorage(
                machineID: id,
                plan: sourceEntry.runtimeIdentity.resolvedPlan
            )
            do {
                try completeLifecycle(lifecycle)
            } catch {
                activeLifecycleOperations.removeValue(forKey: id)
                lifecycle.releaseLease()
            }
        } catch {
#if DEBUG
            if error is MachineLifecycleInjectedCrash { throw error }
#endif
            if deletionCommitted {
                activeLifecycleOperations.removeValue(forKey: id)
                lifecycle.releaseLease()
                return
            }
            let quarantine = lifecycleDeletionQuarantinePath(
                machineID: id,
                operationID: lifecycle.operation.operationID
            )
            let statePath = machineStateDirectory(id: id)
            if Self.pathEntryExists(quarantine), !Self.pathEntryExists(statePath) {
                try? FileManager.default.moveItem(atPath: quarantine, toPath: statePath)
            }
            var restored = sourceEntry
            restored.process = nil
            restored.handoffServer = nil
            restored.handoff = nil
            restored.currentBalloonTargetMB = nil
            restored.state = .stopped
            restored.lastError = "delete failed: \(error)"
            lock.lock()
            deletingMachineIDs.remove(id)
            if machines[id] == nil { machines[id] = restored }
            lock.unlock()
            failLifecycle(lifecycle, stepID: "delete.failed", rolledBack: true)
            if let error = error as? MachineManagerError { throw error }
            throw MachineManagerError.persistence("could not delete \(id): \(error)")
        }
    }

    public func update(
        id: String,
        memoryMB: UInt64? = nil,
        cpuCount: Int? = nil,
        address: String? = nil,
        updatesAddress: Bool = false,
        shares: [DoryMachineShareConfiguration]? = nil,
        updatesShares: Bool = false,
        environment: [String: String]? = nil,
        updatesEnvironment: Bool = false,
        typedSettingsPatch: DoryMachineTypedSettingsPatch? = nil,
        installerMediaAttached: Bool? = nil
    ) throws -> DoryMachineStatus {
        operationLock.lock()
        defer { operationLock.unlock() }
        try requireNoActivePlanningMutation(id: id)
        let directMutation = try retainDirectWorkspaceMutationLock(id: id)
        defer { releaseDirectWorkspaceMutationLock(id: id, retention: directMutation) }
        guard !(updatesEnvironment && typedSettingsPatch != nil) else {
            throw MachineManagerError.persistence(
                "raw environment replacement and typed machine settings are mutually exclusive"
            )
        }
        let (current, wasRunning) = try configurationAndRunningState(id: id)
        let nativeRecord: DoryWorkspaceRepositoryRecord?
        if launchPolicy == .perWorkspaceAuthority {
            let record = try workspaceRepository.readPersistedRecord(id: id)
            nativeRecord = record.legacyConfigurationSHA256 == nil
                && record.legacyMigrationFactsSHA256 == nil ? record : nil
        } else {
            nativeRecord = nil
        }
        if nativeRecord != nil, updatesEnvironment {
            throw MachineManagerError.persistence(
                "native workspace updates do not accept persisted environment values"
            )
        }
        var updated = current
        if let memoryMB {
            updated.memoryMB = memoryMB
        }
        if let cpuCount {
            updated.cpuCount = cpuCount
        }
        if updatesAddress {
            updated.address = try Self.normalizedAddress(address)
        }
        if updatesShares {
            updated.shares = shares ?? []
        }
        if updatesEnvironment {
            updated.environment = environment ?? [:]
        }
        if let typedSettingsPatch, nativeRecord == nil {
            updated.environment = try typedSettingsPatch.applying(
                to: current.environment,
                displayMode: updated.displayMode
            )
        }
        if let installerMediaAttached {
            guard updated.bootMode == .efi else {
                throw MachineManagerError.persistence("installer media is only available for EFI machines")
            }
            if installerMediaAttached {
                let managedInstaller = machineInstallerISOPath(id: id)
                guard Self.isPrivateRegularFile(path: managedInstaller) else {
                    throw MachineManagerError.persistence("managed installer ISO is unavailable")
                }
                updated.installerISOPath = managedInstaller
            } else {
                updated.installerISOPath = nil
            }
        }
        try Self.validateLaunchConfiguration(updated)
        var nativeDefinition: DoryVirtualMachineDefinition?
        if let nativeRecord {
            let facts = try workspaceMigrationFacts(for: updated)
            var migration = try DoryMachineConfigurationMigrationBridge.migrate(
                updated,
                facts: facts
            )
            var candidate = migration.definition
            candidate.lifecycle = nativeRecord.definition.lifecycle
            candidate.backendPreference = nativeRecord.definition.backendPreference
            candidate.graphics = nativeRecord.definition.graphics
            candidate.guestIdentityIntent = nativeRecord.definition.guestIdentityIntent
            candidate.clipboardPolicy = nativeRecord.definition.clipboardPolicy
            if let typedSettingsPatch {
                candidate = try typedSettingsPatch.applying(
                    to: candidate,
                    displayMode: updated.displayMode
                )
            }
            if updated == current, candidate == nativeRecord.definition {
                return status(id: id) ?? DoryMachineStatus(id: id, state: .stopped)
            }
            guard nativeRecord.definition.lifecycle.revision < UInt64.max else {
                throw MachineManagerError.persistence("workspace revision is exhausted")
            }
            guard nativeRecord.definition.lifecycle.updatedAtUnixMilliseconds < Int64.max else {
                throw MachineManagerError.persistence("workspace timestamp is exhausted")
            }
            let now = Int64(max(0, Date().timeIntervalSince1970 * 1_000))
            candidate.lifecycle = DoryVMLifecycleMetadata(
                revision: nativeRecord.definition.lifecycle.revision + 1,
                createdAtUnixMilliseconds:
                    nativeRecord.definition.lifecycle.createdAtUnixMilliseconds,
                updatedAtUnixMilliseconds: max(
                    now,
                    nativeRecord.definition.lifecycle.updatedAtUnixMilliseconds + 1
                )
            )
            guard Self.nativeDefinition(candidate, isCompatibleWith: migration.definition) else {
                throw MachineManagerError.persistence(
                    "native workspace update is not representable by the compatibility runtime"
                )
            }
            migration.definition = candidate
            _ = try migration.legacyConfiguration()
            nativeDefinition = candidate
        }
        guard updated != current || nativeDefinition != nil else {
            return status(id: id) ?? DoryMachineStatus(id: id, state: .stopped)
        }
        if launchPolicy == .perWorkspaceAuthority {
            if wasRunning {
                _ = try stopImplementation(id: id, journalLifecycle: true)
            }
            if current.bootMode == .efi,
               current.installerISOPath != nil,
               updated.installerISOPath == nil {
                try ensureInstalledLinuxBootBundleIfNeeded(updated)
            }
            try persist(
                updated,
                reconcilesLegacyProjection: nativeRecord == nil
            )
            if let nativeRecord, let nativeDefinition {
                do {
                    try workspaceRepository.replace(
                        nativeDefinition,
                        expectedRevision: nativeRecord.definition.lifecycle.revision
                    )
                } catch {
                    try? persist(current, reconcilesLegacyProjection: false)
                    throw error
                }
            }
            try publishConfiguration(updated)
            // Every desired-state mutation invalidates the former plan. The workspace remains
            // stopped until planning publishes a replacement exact runtime identity.
            return status(id: id) ?? DoryMachineStatus(id: id, state: .stopped)
        }
        let requiresRestart = updated.memoryMB != current.memoryMB
            || updated.cpuCount != current.cpuCount
            || updated.shares != current.shares
            || updated.environment != current.environment
            || updated.installerISOPath != current.installerISOPath
        if !requiresRestart {
            do {
                try persist(updated)
                try publishConfiguration(updated)
            } catch {
                if let error = error as? MachineManagerError { throw error }
                throw MachineManagerError.persistence("could not update \(id): \(error)")
            }
            return status(id: id) ?? DoryMachineStatus(id: id, state: .stopped)
        }
        if wasRunning {
            _ = try stopImplementation(id: id, journalLifecycle: true)
        }
        do {
            if current.bootMode == .efi,
               current.installerISOPath != nil,
               updated.installerISOPath == nil {
                try ensureInstalledLinuxBootBundleIfNeeded(updated)
            }
            try persist(updated)
            try publishConfiguration(updated)
        } catch {
            if wasRunning {
                do {
                    _ = try startAndWaitUntilReady(id: id, journalLifecycle: true)
                } catch let restartError {
                    throw MachineManagerError.persistence(
                        "could not update \(id): \(error); original configuration restart failed: \(restartError)"
                    )
                }
            }
            if let error = error as? MachineManagerError { throw error }
            throw MachineManagerError.persistence("could not update \(id): \(error)")
        }
        guard wasRunning else {
            return status(id: id) ?? DoryMachineStatus(id: id, state: .stopped)
        }
        do {
            return try startAndWaitUntilReady(id: id, journalLifecycle: true)
        } catch {
            let updateError = error
            // The handoff callback publishes `.failed` before it can acquire operationLock to
            // terminalize the readiness journal. update() already owns operationLock here, so it
            // must settle that failed start before opening the rollback stop/start transaction.
            failActiveStartLifecycle(id: id, stepID: "start.readiness-failed")
            _ = try? stopImplementation(id: id, journalLifecycle: true)
            do {
                try persist(current)
                try publishConfiguration(current)
            } catch {
                throw MachineManagerError.persistence(
                    "could not start updated \(id): \(updateError); configuration rollback failed: \(error)"
                )
            }
            do {
                _ = try startAndWaitUntilReady(id: id, journalLifecycle: true)
            } catch {
                throw MachineManagerError.persistence(
                    "could not start updated \(id): \(updateError); original configuration was restored but restart failed: \(error)"
                )
            }
            throw MachineManagerError.persistence(
                "could not start updated \(id): \(updateError); original configuration was restored"
            )
        }
    }

    public func snapshot(
        id: String,
        note: String = "",
        createdISO: String = ISO8601DateFormatter().string(from: Date()),
        snapshotID explicitSnapshotID: String? = nil
    ) throws -> DoryMachineSnapshot {
        operationLock.lock()
        defer { operationLock.unlock() }
        try requireNoActivePlanningMutation(id: id)
        let directMutation = try retainDirectWorkspaceMutationLock(id: id)
        defer { releaseDirectWorkspaceMutationLock(id: id, retention: directMutation) }
        let snapshotID = explicitSnapshotID ?? Self.generatedSnapshotID()
        guard Self.isValidID(snapshotID) else {
            throw MachineManagerError.invalidID(snapshotID)
        }
        let (machine, sourceMachineState) = try configurationAndPowerState(id: id)
        let wasRunning = [.starting, .running].contains(sourceMachineState)
        let wasPaused = sourceMachineState == .paused
        let wasResident = wasRunning || wasPaused
        let snapshotRuntimeIdentity = try currentRuntimeIdentity(id: id)
        try Self.validateLaunchConfiguration(machine)
        try ensurePrivateSnapshotDirectory(machineID: id)
        let rootfsPath = snapshotRootfsPath(machineID: id, snapshotID: snapshotID)
        let kernelPath = snapshotKernelPath(machineID: id, snapshotID: snapshotID)
        let machineIdentifierPath = snapshotMachineIdentifierPath(machineID: id, snapshotID: snapshotID)
        let nvramPath = snapshotNVRAMPath(machineID: id, snapshotID: snapshotID)
        guard !Self.pathEntryExists(snapshotMetadataPath(machineID: id, snapshotID: snapshotID)),
              !Self.pathEntryExists(rootfsPath),
              !Self.pathEntryExists(kernelPath),
              !Self.pathEntryExists(machineIdentifierPath),
              !Self.pathEntryExists(nvramPath) else {
            throw MachineManagerError.duplicateSnapshot(snapshotID)
        }
        // Prefer a negotiated guest freeze before the durable cold-stop boundary. A missing tools
        // capability degrades to the existing cold snapshot; an advertised capability that fails
        // is not silently ignored because the guest may already be partially frozen.
        let guestQuiesceReceipt = sourceMachineState == .running
            ? try freezeGuestForSnapshotIfSupported(
                id: id,
                resolvedPlan: snapshotRuntimeIdentity.resolvedPlan
            ) : nil
        if wasResident {
            do {
                _ = try stopImplementation(
                    id: id,
                    journalLifecycle: true,
                    preserveResolvedAdmissionForRestart: true
                )
            } catch {
                if let guestQuiesceReceipt {
                    do {
                        try thawGuestAfterFailedSnapshotStop(
                            id: id,
                            receiptID: guestQuiesceReceipt.receiptID
                        )
                    }
                    catch let thawError {
                        throw MachineManagerError.persistence(
                            "could not stop \(id) for snapshot: \(error); guest thaw failed: \(thawError)"
                        )
                    }
                }
                throw error
            }
        }
        var snapshotLifecycleStarted = false
        defer {
            if wasResident, !snapshotLifecycleStarted {
                try? restoreSnapshotSourcePowerState(
                    id: id,
                    wasPaused: wasPaused,
                    resolvedPlan: snapshotRuntimeIdentity.resolvedPlan
                )
            }
        }
        let liveMachineIdentifierPath = machine.bootMode == .efi
            ? machineFirmwareIdentifierPath(id: id) : nil
        let liveNVRAMPath = machine.bootMode == .efi
            ? machineFirmwareNVRAMPath(id: id) : nil
        if machine.bootMode == .efi {
            guard let liveMachineIdentifierPath, let liveNVRAMPath,
                  Self.isPrivateRegularFile(path: liveMachineIdentifierPath),
                  Self.isPrivateRegularFile(path: liveNVRAMPath) else {
                throw MachineManagerError.persistence(
                    "EFI firmware state is unavailable; start the machine once before taking a snapshot"
                )
            }
        }
        let artifactEvidence = try Self.snapshotArtifactEvidence(
            rootfsPath: machine.rootfsPath,
            kernelPath: machine.kernelPath,
            machineIdentifierPath: liveMachineIdentifierPath,
            nvramPath: liveNVRAMPath
        )
        guard let snapshotSize = Int64(exactly: artifactEvidence.rootfs.byteCount) else {
            throw MachineManagerError.persistence("machine snapshot disk is too large")
        }
        let snapshot = DoryMachineSnapshot(
            id: snapshotID,
            machineID: id,
            note: note,
            createdISO: createdISO,
            rootfsPath: rootfsPath,
            sizeBytes: snapshotSize,
            kernelPath: kernelPath,
            architecture: configuration.guestArchitecture,
            memoryMB: machine.memoryMB,
            cpuCount: machine.cpuCount,
            displayMode: machine.displayMode,
            address: machine.address,
            shares: machine.shares,
            environment: machine.environment,
            typedSettings: nativeTypedSettingsSnapshot(id: id),
            bootMode: machine.bootMode,
            machineIdentifierPath: machine.bootMode == .efi ? machineIdentifierPath : nil,
            nvramPath: machine.bootMode == .efi ? nvramPath : nil,
            runtimeIdentity: snapshotRuntimeIdentity,
            artifactEvidence: artifactEvidence,
            installedDesktopPayloadReceipt:
                machine.effectiveInstalledDesktopPayloadReceipt,
            consistency: guestQuiesceReceipt == nil ? .coldStopped : .guestQuiesced,
            guestQuiesceReceipt: guestQuiesceReceipt
        )
        let snapshotAuthority = try Self.lifecycleSnapshotAuthority(snapshot)
        let lifecycle = try beginLifecycleSnapshot(
            machine: machine,
            runtimeIdentity: snapshotRuntimeIdentity,
            sourceState: wasPaused ? .paused : .stopped,
            snapshotID: snapshotID,
            snapshotAuthority: snapshotAuthority
        )
        snapshotLifecycleStarted = true

        var publishedRootfs = false
        var publishedKernel = false
        var publishedMachineIdentifier = false
        var publishedNVRAM = false
        do {
            try advanceLifecycleToPublishing(lifecycle)
            try Self.cloneOrCopyFile(source: machine.rootfsPath, destination: rootfsPath)
            publishedRootfs = true
#if DEBUG
            try injectLifecycleFault(.snapshotAfterRootfs)
#endif
            try Self.cloneOrCopyFile(source: machine.kernelPath, destination: kernelPath)
            publishedKernel = true
            if machine.bootMode == .efi {
                guard let liveMachineIdentifierPath, let liveNVRAMPath else {
                    throw MachineManagerError.persistence("EFI firmware state is unavailable")
                }
                try Self.cloneOrCopyFile(
                    source: liveMachineIdentifierPath,
                    destination: machineIdentifierPath
                )
                publishedMachineIdentifier = true
                try Self.cloneOrCopyFile(source: liveNVRAMPath, destination: nvramPath)
                publishedNVRAM = true
            }
            // Validate the copies against the pre-publish authority before publishing metadata.
            try Self.validateSnapshotArtifactEvidence(snapshot)
            try persistSnapshot(snapshot)
        } catch {
#if DEBUG
            if error is MachineLifecycleInjectedCrash { throw error }
#endif
            if publishedRootfs {
                try? FileManager.default.removeItem(atPath: rootfsPath)
            }
            if publishedKernel {
                try? FileManager.default.removeItem(atPath: kernelPath)
            }
            if publishedMachineIdentifier {
                try? FileManager.default.removeItem(atPath: machineIdentifierPath)
            }
            if publishedNVRAM {
                try? FileManager.default.removeItem(atPath: nvramPath)
            }
            failLifecycle(lifecycle, stepID: "snapshot.failed", rolledBack: true)
            if wasResident {
                try? restoreSnapshotSourcePowerState(
                    id: id,
                    wasPaused: wasPaused,
                    resolvedPlan: snapshotRuntimeIdentity.resolvedPlan
                )
            }
            if let error = error as? MachineManagerError {
                throw error
            }
            throw MachineManagerError.persistence("could not snapshot \(id): \(error)")
        }

        let journalCompleted = completeCommittedLifecycle(
            lifecycle,
            diagnostic: "published snapshot has an unfinished snapshot journal"
        )
        if wasResident, journalCompleted {
            do {
                try restoreSnapshotSourcePowerState(
                    id: id,
                    wasPaused: wasPaused,
                    resolvedPlan: snapshotRuntimeIdentity.resolvedPlan
                )
            } catch let firstError {
                do {
                    try restoreSnapshotSourcePowerState(
                        id: id,
                        wasPaused: wasPaused,
                        resolvedPlan: snapshotRuntimeIdentity.resolvedPlan
                    )
                } catch {
                    throw MachineManagerError.persistence(
                        "snapshot \(snapshotID) was created, but \(id) could not restart: \(firstError); retry: \(error)"
                    )
                }
            }
        }
        return snapshot
    }

    private func freezeGuestForSnapshotIfSupported(
        id: String,
        resolvedPlan: DoryResolvedMachinePlan?
    ) throws -> DoryMachineSnapshotQuiesceReceipt? {
        guard let status = status(id: id),
              status.supportsAgentCapability("snapshot-quiesce", minimumVersion: 2),
              let agentBuild = status.agentBuild,
              let protocolVersion = status.agentProtocolVersion,
              let capabilityVersion = status.agentCapabilities.first(where: {
                  $0.id == "snapshot-quiesce"
              })?.version else {
            return nil
        }
        let requestedReceiptID = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        do {
            let receiptID = try withAgentClient(
                id: id,
                requiredCapability: "snapshot-quiesce",
                minimumCapabilityVersion: 2
            ) { client in
                try client.snapshotFreeze(receiptID: requestedReceiptID)
            }
            let receipt = DoryMachineSnapshotQuiesceReceipt(
                receiptID: receiptID,
                agentBuild: agentBuild,
                agentProtocolVersion: protocolVersion,
                capabilityVersion: capabilityVersion
            )
            guard receipt.isValid, receiptID == requestedReceiptID else {
                throw MachineManagerError.persistence(
                    "guest snapshot freeze returned an invalid receipt for \(id)"
                )
            }
            return receipt
        } catch {
            let freezeError = error
            do {
                try thawGuestAfterFailedSnapshotStop(
                    id: id,
                    receiptID: requestedReceiptID
                )
            } catch let thawError {
                do {
                    _ = try stopImplementation(
                        id: id,
                        journalLifecycle: true,
                        preserveResolvedAdmissionForRestart: true
                    )
                    try restoreSnapshotSourcePowerState(
                        id: id,
                        wasPaused: false,
                        resolvedPlan: resolvedPlan
                    )
                } catch let recoveryError {
                    throw MachineManagerError.persistence(
                        "guest snapshot freeze failed for \(id): \(freezeError); recovery thaw failed: \(thawError); forced restart failed: \(recoveryError)"
                    )
                }
                throw MachineManagerError.persistence(
                    "guest snapshot freeze failed for \(id): \(freezeError); recovery thaw failed: \(thawError); the guest was restarted"
                )
            }
            throw MachineManagerError.persistence(
                "guest snapshot freeze failed for \(id): \(freezeError)"
            )
        }
    }

    private func thawGuestAfterFailedSnapshotStop(id: String, receiptID: String) throws {
        try withAgentClient(
            id: id,
            requiredCapability: "snapshot-quiesce",
            minimumCapabilityVersion: 2
        ) { client in
            try client.snapshotThaw(receiptID: receiptID)
        }
    }

    private func restoreSnapshotSourcePowerState(
        id: String,
        wasPaused: Bool,
        resolvedPlan: DoryResolvedMachinePlan?
    ) throws {
        try prepareRetainedResolvedAdmissionForRestart(plan: resolvedPlan)
        _ = try startAndWaitUntilReady(id: id, journalLifecycle: true)
        if wasPaused {
            // Readiness publishes `.running` before its callback can reacquire operationLock to
            // terminalize the start journal. snapshot() already owns that recursive lock, so
            // settle the committed start here before opening the pause lifecycle transaction.
            completeActiveStartLifecycle(id: id)
            _ = try pauseImplementation(id: id, journalLifecycle: true)
        }
    }

    /// Applies a signed desktop component to an existing persistent guest. The caller provides
    /// only stable active-component generation identifiers; doryd resolves and re-verifies the
    /// exact component-store bytes and owns the entire transaction: a last-good disk/kernel
    /// snapshot is durable before the guest is mutated, and any failed install or post-reboot
    /// qualification restores that snapshot and the machine's original running state.
    public func updateDesktop(
        id: String,
        request: DoryDesktopUpdateRequest
    ) throws -> DoryDesktopUpdateResult {
        operationLock.lock()
        defer { operationLock.unlock() }
        try requireNoActivePlanningMutation(id: id)
        let directMutation = try retainDirectWorkspaceMutationLock(id: id)
        defer { releaseDirectWorkspaceMutationLock(id: id, retention: directMutation) }

        let (original, originallyRunning) = try configurationAndRunningState(id: id)
        guard original.bootMode == .linuxKernel else {
            throw MachineManagerError.persistence("managed desktop updates do not apply to custom EFI machines")
        }
        guard original.displayMode == .desktop else {
            throw MachineManagerError.persistence("desktop updates require a graphical machine")
        }
        let persistedDistro = original.environment["DORY_DESKTOP_DISTRO"]
            ?? original.effectiveInstalledDesktopPayloadReceipt?.distributionIdentifier
        guard ["debian", "ubuntu", "kali"].contains(request.distro),
              persistedDistro == request.distro else {
            throw MachineManagerError.persistence("desktop update distribution does not match " + id)
        }
        guard request.version.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._+-]{0,127}/) != nil else {
            throw MachineManagerError.persistence("desktop update version is invalid")
        }
        guard let desktopUpdateArtifactResolver else {
            throw MachineManagerError.persistence(
                "desktop updates require daemon component-store authority"
            )
        }
        let authority = try desktopUpdateArtifactResolver.resolve(
            request,
            guestArchitecture: configuration.guestArchitecture
        )
        guard authority.receipt.isValid,
              authority.receipt.provenance == .verifiedUpdateBundle,
              authority.receipt.distributionIdentifier == request.distro,
              authority.receipt.releaseVersion == request.version,
              authority.receipt.distributionInstallationName
                == request.distributionInstallationName,
              authority.receipt.runtimeInstallationName == request.runtimeInstallationName,
              let bundleSHA256 = authority.receipt.bundleSHA256,
              let kernelSHA256 = authority.receipt.kernelSHA256 else {
            throw MachineManagerError.persistence("desktop update authority is inconsistent")
        }
        let staged = try stageDesktopUpdateAuthority(authority, machineID: id)
        defer { try? FileManager.default.removeItem(atPath: staged.directory) }
        let snapshotID = Self.generatedSnapshotID(prefix: "du")
        let snapshot = try snapshot(
            id: id,
            note: "Automatic last-good snapshot before " + request.distro + " " + request.version + " desktop update",
            snapshotID: snapshotID
        )
        var journal = DesktopUpdateJournal(
            schema: 2,
            machineID: id,
            distro: request.distro,
            version: request.version,
            snapshotID: snapshot.id,
            originalWasRunning: originallyRunning,
            stage: .snapshotReady,
            sourceConfigurationSHA256: Self.sha256(
                data: try DoryMachineConfigurationMigrationBridge.encodeLegacy(original)
            ),
            updateAuthority: authority.receipt
        )
        try persistDesktopUpdateJournal(journal)

        let token = String(bundleSHA256.prefix(12))
        let mountPath = "/mnt/dory-update-" + token
        let guestStage = "/var/lib/dory/update-" + token
        let updateShare = DoryMachineShareConfiguration(
            tag: "dory-update-" + token,
            hostPath: staged.directory,
            guestPath: mountPath,
            readOnly: true
        )
        let bundleGuestPath = mountPath + "/payload.tar"

        do {
            var transientShares = original.shares.filter { $0.tag != updateShare.tag }
            transientShares.append(updateShare)
            _ = try update(id: id, shares: transientShares, updatesShares: true)
            if status(id: id)?.state != .running {
                _ = try startAndWaitUntilReady(id: id)
            }
            journal.stage = .installing
            try persistDesktopUpdateJournal(journal)

            try requireSuccessfulDesktopUpdateExec(
                id: id,
                argv: ["/bin/rm", "-rf", guestStage],
                stage: "clear guest staging"
            )
            try requireSuccessfulDesktopUpdateExec(
                id: id,
                argv: ["/bin/mkdir", "-p", guestStage],
                stage: "create guest staging"
            )
            try requireSuccessfulDesktopUpdateExec(
                id: id,
                argv: ["/bin/tar", "-xf", bundleGuestPath, "-C", guestStage],
                timeoutMs: 120_000,
                stage: "extract signed payload"
            )
            guard try Self.sha256(path: staged.bundlePath) == bundleSHA256 else {
                throw MachineManagerError.persistence(
                    "desktop update staged bundle changed while the guest read it"
                )
            }
            let install = try requireSuccessfulDesktopUpdateExec(
                id: id,
                argv: [guestStage + "/apply.sh", request.distro, request.version],
                timeoutMs: 3_600_000,
                outputLimitBytes: 16 * 1024 * 1024,
                stage: "install guest update"
            )
            var inputSHA256 = Self.desktopUpdateInputSHA256(from: install)
            if inputSHA256 == nil {
                // Package managers can emit more than the bounded exec output and displace the
                // final success line. The update writes this receipt atomically before exiting,
                // so read it directly instead of rolling back a successfully applied payload.
                let receipt = try requireSuccessfulDesktopUpdateExec(
                    id: id,
                    argv: ["/bin/cat", "/var/lib/dory/desktop-update.env"],
                    outputLimitBytes: 16 * 1024,
                    stage: "read the installed desktop update receipt"
                )
                inputSHA256 = Self.desktopUpdateReceiptInputSHA256(
                    from: receipt,
                    distro: request.distro,
                    version: request.version
                )
            }
            guard let inputSHA256 else {
                throw MachineManagerError.persistence("desktop update did not return its input fingerprint")
            }

            _ = try? requireSuccessfulDesktopUpdateExec(
                id: id,
                argv: ["/bin/rm", "-rf", guestStage],
                stage: "clear applied payload"
            )
            _ = try stop(id: id)
            var installedReceipt = authority.receipt
            installedReceipt.inputSHA256 = inputSHA256
            try publishInstalledDesktopPayloadReceipt(
                original: original,
                receipt: installedReceipt
            )
            try Self.cloneOrCopyFile(
                source: staged.kernelPath,
                destination: original.kernelPath,
                replaceExisting: true
            )
            guard try Self.sha256(path: staged.kernelPath) == kernelSHA256,
                  try Self.sha256(path: original.kernelPath) == kernelSHA256 else {
                throw MachineManagerError.persistence(
                    "desktop update kernel authority changed before commit"
                )
            }
            journal.stage = .qualifying
            try persistDesktopUpdateJournal(journal)
            _ = try startAndWaitUntilReady(id: id)
            try qualifyUpdatedDesktop(
                id: id,
                distro: request.distro,
                version: request.version,
                inputSHA256: inputSHA256
            )

            let finalStatus: DoryMachineStatus
            if originallyRunning {
                finalStatus = status(id: id) ?? DoryMachineStatus(id: id, state: .running)
            } else {
                finalStatus = try stop(id: id)
            }
            journal.stage = .committed
            try persistDesktopUpdateJournal(journal)
            try removeDesktopUpdateJournal(machineID: id)
            return DoryDesktopUpdateResult(
                machineID: id,
                distro: request.distro,
                version: request.version,
                inputSHA256: inputSHA256,
                bundleSHA256: bundleSHA256,
                snapshotID: snapshot.id,
                status: finalStatus,
                restoredRunningState: originallyRunning
            )
        } catch {
            let updateError = error
            do {
                _ = try? stop(id: id)
                _ = try restoreSnapshot(machineID: id, snapshotID: snapshot.id)
                if originallyRunning, status(id: id)?.state != .running {
                    _ = try startAndWaitUntilReady(id: id)
                } else if !originallyRunning, status(id: id)?.state == .running {
                    _ = try stop(id: id)
                }
                try removeDesktopUpdateJournal(machineID: id)
            } catch {
                throw MachineManagerError.persistence(
                    "desktop update " + request.version + " failed: " + String(describing: updateError)
                        + "; automatic rollback failed: " + String(describing: error)
                )
            }
            throw MachineManagerError.persistence(
                "desktop update " + request.version + " failed: " + String(describing: updateError)
                    + "; last-good snapshot " + snapshot.id + " was restored"
            )
        }
    }

    public func listSnapshots(machineID: String? = nil) throws -> [DoryMachineSnapshot] {
        operationLock.lock()
        defer { operationLock.unlock() }
        let ids: [String]
        if let machineID {
            guard Self.isValidID(machineID) else {
                throw MachineManagerError.invalidID(machineID)
            }
            ids = [machineID]
        } else {
            let persisted = (try? FileManager.default.contentsOfDirectory(atPath: configuration.stateDirectory)) ?? []
            ids = persisted.filter(Self.isValidID(_:))
        }
        let snapshots = ids.flatMap { id -> [DoryMachineSnapshot] in
            let directory = snapshotDirectory(machineID: id)
            guard Self.isPrivateDirectory(path: directory) else {
                return []
            }
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
                return []
            }
            return files
                .filter { $0.hasSuffix(".json") }
                .compactMap { file in
                    let snapshotID = String(file.dropLast(".json".count))
                    return try? loadSnapshot(machineID: id, snapshotID: snapshotID)
                }
        }
        return snapshots.sorted { lhs, rhs in
            if lhs.createdISO == rhs.createdISO {
                return lhs.id > rhs.id
            }
            return lhs.createdISO > rhs.createdISO
        }
    }

    public func cloneSnapshot(machineID: String, snapshotID: String, newID: String) throws -> DoryMachineStatus {
        operationLock.lock()
        defer { operationLock.unlock() }
        let snapshot = try loadSnapshot(machineID: machineID, snapshotID: snapshotID)
        try validateSnapshotRuntimeCompatibility(snapshot, machine: nil, cloning: true)
        let machine = DoryMachineConfiguration(
            id: newID,
            kernelPath: snapshot.kernelPath,
            rootfsPath: snapshot.rootfsPath,
            bootMode: snapshot.bootMode,
            memoryMB: snapshot.memoryMB,
            cpuCount: snapshot.cpuCount,
            address: nil,
            displayMode: snapshot.displayMode,
            shares: snapshot.shares,
            environment: snapshot.environment,
            installedDesktopPayloadReceipt:
                Self.configurationReceipt(restoring: snapshot)
        )
        let created = try create(
            machine,
            typedSettings: snapshot.typedSettings?.replacementPatch
        )
        do {
            if snapshot.bootMode == .efi {
                guard let snapshotNVRAMPath = snapshot.nvramPath else {
                    throw MachineManagerError.persistence("EFI snapshot is missing NVRAM state")
                }
                // A clone gets a new Virtualization.framework machine identifier, but retains
                // the guest's EFI variables (including its installed boot entries).
                try Self.cloneOrCopyFile(
                    source: snapshotNVRAMPath,
                    destination: machineFirmwareNVRAMPath(id: newID)
                )
            }
            if launchPolicy == .perWorkspaceAuthority {
                // A clone has new mutable storage and a new machine identity. Its source runtime
                // evidence remains useful history, but can never authorize the clone's launch.
                return status(id: newID) ?? created
            }
            return try start(id: newID)
        } catch {
            do {
                try delete(id: newID)
            } catch let cleanupError {
                throw MachineManagerError.persistence(
                    "could not start cloned machine \(newID): \(error); cleanup failed: \(cleanupError)"
                )
            }
            throw error
        }
    }

    public func restoreSnapshot(machineID: String, snapshotID: String) throws -> DoryMachineStatus {
        operationLock.lock()
        defer { operationLock.unlock() }
        try requireNoActivePlanningMutation(id: machineID)
        let directMutation = try retainDirectWorkspaceMutationLock(id: machineID)
        defer {
            releaseDirectWorkspaceMutationLock(
                id: machineID,
                retention: directMutation
            )
        }
        let snapshot = try loadSnapshot(machineID: machineID, snapshotID: snapshotID)
        let (machine, wasRunning) = try configurationAndRunningState(id: machineID)
        try validateSnapshotRuntimeCompatibility(snapshot, machine: machine, cloning: false)
        guard machine.bootMode == snapshot.bootMode else {
            throw MachineManagerError.persistence("snapshot boot mode does not match the machine")
        }
        let address = try Self.normalizedAddress(snapshot.address)
        try Self.validateShares(snapshot.shares)
        try Self.validateEnvironment(snapshot.environment)
        var restoredMachine = machine
        restoredMachine.memoryMB = snapshot.memoryMB
        restoredMachine.cpuCount = snapshot.cpuCount
        restoredMachine.displayMode = snapshot.displayMode
        restoredMachine.bootMode = snapshot.bootMode
        restoredMachine.address = address
        restoredMachine.shares = snapshot.shares
        restoredMachine.environment = snapshot.environment
        restoredMachine.installedDesktopPayloadReceipt =
            Self.configurationReceipt(restoring: snapshot)
        let restoredNativeWorkspace: (
            definition: DoryVirtualMachineDefinition,
            expectedRevision: UInt64
        )?
        if launchPolicy == .perWorkspaceAuthority {
            let record = try workspaceRepository.readPersistedRecord(id: machineID)
            if record.legacyConfigurationSHA256 == nil,
               record.legacyMigrationFactsSHA256 == nil {
                // A native workspace never regains the legacy environment as desired-state
                // authority. Older or imported snapshot metadata may still contain compatibility
                // keys (or secrets); typed snapshot intent is restored through the definition
                // below and the raw dictionary remains read-only historical evidence.
                restoredMachine.environment = [:]
                let facts = try workspaceMigrationFacts(for: restoredMachine)
                let migration = try DoryMachineConfigurationMigrationBridge.migrate(
                    restoredMachine,
                    facts: facts
                )
                var candidate = migration.definition
                candidate.lifecycle = record.definition.lifecycle
                candidate.backendPreference = record.definition.backendPreference
                candidate.graphics = record.definition.graphics
                candidate.guestIdentityIntent = record.definition.guestIdentityIntent
                candidate.clipboardPolicy = record.definition.clipboardPolicy
                if let typedSettings = snapshot.typedSettings {
                    candidate = try typedSettings.applyingAsReplacement(
                        to: candidate,
                        displayMode: restoredMachine.displayMode
                    )
                }
                guard record.definition.lifecycle.revision < UInt64.max,
                      record.definition.lifecycle.updatedAtUnixMilliseconds < Int64.max else {
                    throw MachineManagerError.persistence(
                        "workspace lifecycle authority is exhausted"
                    )
                }
                let now = Int64(max(0, Date().timeIntervalSince1970 * 1_000))
                candidate.lifecycle = DoryVMLifecycleMetadata(
                    revision: record.definition.lifecycle.revision + 1,
                    createdAtUnixMilliseconds:
                        record.definition.lifecycle.createdAtUnixMilliseconds,
                    updatedAtUnixMilliseconds: max(
                        now,
                        record.definition.lifecycle.updatedAtUnixMilliseconds + 1
                    )
                )
                guard Self.nativeDefinition(
                    candidate,
                    isCompatibleWith: migration.definition
                ) else {
                    throw MachineManagerError.persistence(
                        "snapshot typed settings do not match the restored machine"
                    )
                }
                restoredNativeWorkspace = (
                    candidate,
                    record.definition.lifecycle.revision
                )
            } else {
                restoredNativeWorkspace = nil
            }
        } else {
            restoredNativeWorkspace = nil
        }
        let sourceIdentity = try currentRuntimeIdentity(id: machineID)
        let targetIdentity = runtimeIdentityAfterSnapshotRestore(
            snapshot.runtimeIdentity,
            sourceIdentity: sourceIdentity
        )
        let snapshotAuthority = try Self.lifecycleSnapshotAuthority(snapshot)
        let lifecycle = try beginLifecycleRestore(
            sourceMachine: machine,
            targetMachine: restoredMachine,
            sourceIdentity: sourceIdentity,
            targetIdentity: targetIdentity,
            sourceState: wasRunning ? .running : .stopped,
            targetState: wasRunning && shouldRestartAfterSnapshotRestore(targetIdentity)
                ? .running : .stopped,
            snapshotID: snapshotID,
            snapshotAuthority: snapshotAuthority
        )
        do {
            try advanceLifecycleToPublishing(lifecycle)
            if wasRunning {
                _ = try stopImplementation(
                    id: machineID,
                    journalLifecycle: false,
                    preserveResolvedAdmissionForRestart: true
                )
            }
            try restoreManagedArtifacts(
                machine: machine,
                snapshot: snapshot,
                operationID: lifecycle.operation.operationID
            ) {
                try persist(
                    restoredMachine,
                    reconcilesLegacyProjection: restoredNativeWorkspace == nil
                )
                if let restoredNativeWorkspace {
                    do {
                        try workspaceRepository.replace(
                            restoredNativeWorkspace.definition,
                            expectedRevision: restoredNativeWorkspace.expectedRevision
                        )
                    } catch {
                        try? persist(machine, reconcilesLegacyProjection: false)
                        throw error
                    }
                }
                try persistRuntimeIdentity(
                    targetIdentity,
                    configuration: restoredMachine
                )
                lock.lock()
                if var entry = machines[machineID] {
                    entry.configuration = restoredMachine
                    entry.currentBalloonTargetMB = nil
                    entry.runtimeIdentity = targetIdentity
                    machines[machineID] = entry
                }
                lock.unlock()
            }
            let status: DoryMachineStatus
            if wasRunning, shouldRestartAfterSnapshotRestore(targetIdentity) {
                try prepareRetainedResolvedAdmissionForRestart(
                    plan: sourceIdentity.resolvedPlan
                )
                status = try startAndWaitUntilReady(id: machineID, journalLifecycle: false)
            } else {
                if wasRunning {
                    do {
                        try markResolvedAdmissionStopped(plan: sourceIdentity.resolvedPlan)
                    } catch {
                        // The restored target is already committed and its old plan is no longer
                        // launch authority. Keep the conservative running reservation for daemon
                        // restart reconciliation instead of falsely rolling back the restore.
                        lock.lock()
                        machines[machineID]?.lastError =
                            "snapshot restored; resource settlement requires recovery: \(error)"
                        lock.unlock()
                    }
                }
                status = self.status(id: machineID)
                    ?? DoryMachineStatus(id: machineID, state: .stopped)
            }
            _ = completeCommittedLifecycle(
                lifecycle,
                diagnostic: "restored machine has an unfinished restore journal"
            )
            return status
        } catch let error as MachineManagerError {
            if wasRunning {
                try? prepareRetainedResolvedAdmissionForRestart(
                    plan: sourceIdentity.resolvedPlan
                )
                _ = try? startImplementation(id: machineID, journalLifecycle: false)
            }
            failLifecycle(lifecycle, stepID: "restore.failed", rolledBack: true)
            throw error
        } catch {
#if DEBUG
            if error is MachineLifecycleInjectedCrash { throw error }
#endif
            if wasRunning {
                try? prepareRetainedResolvedAdmissionForRestart(
                    plan: sourceIdentity.resolvedPlan
                )
                _ = try? startImplementation(id: machineID, journalLifecycle: false)
            }
            failLifecycle(lifecycle, stepID: "restore.failed", rolledBack: true)
            throw MachineManagerError.persistence("could not restore snapshot \(snapshotID): \(error)")
        }
    }

    public func deleteSnapshot(machineID: String, snapshotID: String) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        let snapshot = try loadSnapshot(machineID: machineID, snapshotID: snapshotID)
        let metadataPath = snapshotMetadataPath(machineID: machineID, snapshotID: snapshotID)
        let rootfsPath = snapshotRootfsPath(machineID: machineID, snapshotID: snapshotID)
        let kernelPath = snapshotKernelPath(machineID: machineID, snapshotID: snapshotID)
        let token = "\(Self.snapshotDeletionQuarantinePrefix)\(snapshotID)-\(UUID().uuidString)"
        let directory = snapshotDirectory(machineID: machineID)
        var artifacts: [(label: String, source: String, quarantine: String)] = [
            ("rootfs", rootfsPath, "\(directory)/\(token).ext4"),
            ("kernel", kernelPath, "\(directory)/\(token).kernel"),
        ]
        if snapshot.bootMode == .efi {
            artifacts.append((
                "machine identifier",
                snapshotMachineIdentifierPath(machineID: machineID, snapshotID: snapshotID),
                "\(directory)/\(token).machine-identifier"
            ))
            artifacts.append((
                "NVRAM",
                snapshotNVRAMPath(machineID: machineID, snapshotID: snapshotID),
                "\(directory)/\(token).nvram"
            ))
        }
        artifacts.append(("metadata", metadataPath, "\(directory)/\(token).json"))

        var quarantined: [(label: String, source: String, quarantine: String)] = []
        do {
            for artifact in artifacts {
                try FileManager.default.moveItem(atPath: artifact.source, toPath: artifact.quarantine)
                quarantined.append(artifact)
            }
        } catch {
            var rollbackFailures: [String] = []
            for artifact in quarantined.reversed() {
                do {
                    try FileManager.default.moveItem(atPath: artifact.quarantine, toPath: artifact.source)
                } catch {
                    rollbackFailures.append("\(artifact.label) rollback failed: \(error)")
                }
            }
            let suffix = rollbackFailures.isEmpty ? "" : "; \(rollbackFailures.joined(separator: "; "))"
            throw MachineManagerError.persistence("could not delete snapshot \(snapshotID): \(error)\(suffix)")
        }
        for artifact in quarantined {
            try? FileManager.default.removeItem(atPath: artifact.quarantine)
        }
        removeEmptyImportedSnapshotNamespace(machineID: machineID)
    }

    public func exportSnapshot(machineID: String, snapshotID: String, toPath path: String) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        var snapshot = try loadSnapshot(machineID: machineID, snapshotID: snapshotID)
        if snapshot.installedDesktopPayloadReceipt == nil {
            snapshot.installedDesktopPayloadReceipt =
                DoryInstalledDesktopPayloadReceipt.legacyEnvironment(snapshot.environment)
        }
        if let portable = snapshot.installedDesktopPayloadReceipt?.portableSnapshotReceipt {
            snapshot.installedDesktopPayloadReceipt = portable
            snapshot.environment.removeValue(
                forKey: DoryInstalledDesktopPayloadReceipt.legacyReleaseVersionEnvironmentKey
            )
            snapshot.environment.removeValue(
                forKey: DoryInstalledDesktopPayloadReceipt.legacyInputSHA256EnvironmentKey
            )
        }
        do {
            try MachineSnapshotBundle.write(snapshot: snapshot, toPath: path)
        } catch let error as MachineManagerError {
            throw error
        } catch {
            throw MachineManagerError.persistence("could not export snapshot \(snapshotID): \(error)")
        }
    }

    public func importSnapshot(fromPath path: String) throws -> DoryMachineSnapshot {
        operationLock.lock()
        defer { operationLock.unlock() }
        var extractedRootfsPath: String?
        var extractedKernelPath: String?
        var extractedMachineIdentifierPath: String?
        var extractedNVRAMPath: String?
        var importedMachineID: String?
        do {
            let bundle = try MachineSnapshotBundle.readDescriptor(fromPath: path)
            var snapshot = bundle.snapshot
            guard Self.isValidID(snapshot.machineID), Self.isValidID(snapshot.id) else {
                throw MachineManagerError.persistence("invalid snapshot metadata")
            }
            guard snapshot.architecture == configuration.guestArchitecture else {
                throw MachineManagerError.persistence(
                    "machine snapshot architecture \(snapshot.architecture) is incompatible with \(configuration.guestArchitecture)"
                )
            }
            try Self.validateResources(memoryMB: snapshot.memoryMB, cpuCount: snapshot.cpuCount)
            try Self.validateSnapshotRuntimeIdentity(snapshot)
            if launchPolicy == .perWorkspaceAuthority {
                snapshot.runtimeIdentity = .requiresReplanning(
                    virtualHardwareABIVersion:
                        snapshot.runtimeIdentity.virtualHardwareABIVersion,
                    reason: .importedSnapshot
                )
            }
            snapshot.installedDesktopPayloadReceipt =
                snapshot.installedDesktopPayloadReceipt?.portableSnapshotReceipt
            snapshot.address = nil
            snapshot.shares = []
            snapshot.environment = [:]
            importedMachineID = snapshot.machineID
            try ensurePrivateSnapshotDirectory(machineID: snapshot.machineID)
            snapshot.id = try availableImportedSnapshotID(
                machineID: snapshot.machineID,
                preferredID: snapshot.id
            )
            snapshot.rootfsPath = snapshotRootfsPath(machineID: snapshot.machineID, snapshotID: snapshot.id)
            snapshot.kernelPath = snapshotKernelPath(machineID: snapshot.machineID, snapshotID: snapshot.id)
            if snapshot.bootMode == .efi {
                snapshot.machineIdentifierPath = snapshotMachineIdentifierPath(
                    machineID: snapshot.machineID,
                    snapshotID: snapshot.id
                )
                snapshot.nvramPath = snapshotNVRAMPath(machineID: snapshot.machineID, snapshotID: snapshot.id)
            } else {
                snapshot.machineIdentifierPath = nil
                snapshot.nvramPath = nil
            }
            try MachineSnapshotBundle.extractArtifacts(
                fromPath: path,
                expectedContentID: bundle.contentID,
                rootfsPath: snapshot.rootfsPath,
                kernelPath: snapshot.kernelPath,
                machineIdentifierPath: snapshot.machineIdentifierPath,
                nvramPath: snapshot.nvramPath
            )
            extractedRootfsPath = snapshot.rootfsPath
            extractedKernelPath = snapshot.kernelPath
            extractedMachineIdentifierPath = snapshot.machineIdentifierPath
            extractedNVRAMPath = snapshot.nvramPath
            snapshot.sizeBytes = Self.fileSize(path: snapshot.rootfsPath)
            try persistSnapshot(snapshot)
            return snapshot
        } catch let error as MachineManagerError {
            if let extractedRootfsPath {
                try? FileManager.default.removeItem(atPath: extractedRootfsPath)
            }
            if let extractedKernelPath {
                try? FileManager.default.removeItem(atPath: extractedKernelPath)
            }
            if let extractedMachineIdentifierPath {
                try? FileManager.default.removeItem(atPath: extractedMachineIdentifierPath)
            }
            if let extractedNVRAMPath {
                try? FileManager.default.removeItem(atPath: extractedNVRAMPath)
            }
            if let importedMachineID {
                removeEmptyImportedSnapshotNamespace(machineID: importedMachineID)
            }
            throw error
        } catch {
            if let extractedRootfsPath {
                try? FileManager.default.removeItem(atPath: extractedRootfsPath)
            }
            if let extractedKernelPath {
                try? FileManager.default.removeItem(atPath: extractedKernelPath)
            }
            if let extractedMachineIdentifierPath {
                try? FileManager.default.removeItem(atPath: extractedMachineIdentifierPath)
            }
            if let extractedNVRAMPath {
                try? FileManager.default.removeItem(atPath: extractedNVRAMPath)
            }
            if let importedMachineID {
                removeEmptyImportedSnapshotNamespace(machineID: importedMachineID)
            }
            throw MachineManagerError.persistence("could not import machine snapshot: \(error)")
        }
    }

    public func status(id: String) -> DoryMachineStatus? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = machines[id] else { return nil }
        return statusLocked(id: id, entry: entry)
    }

    public func runtimeIdentity(id: String) -> DoryMachineRuntimeIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return machines[id]?.runtimeIdentity
    }

    public func list() -> [DoryMachineStatus] {
        lock.lock()
        let statuses = machines.keys.sorted().compactMap { id in
            machines[id].map { statusLocked(id: id, entry: $0) }
        }
        lock.unlock()
        return statuses
    }

    public func workspaceProjectionDiagnostic(
        id: String
    ) -> DoryWorkspaceProjectionDiagnostic? {
        lock.lock()
        defer { lock.unlock() }
        guard machines[id] != nil else { return nil }
        return workspaceProjectionDiagnostics[id]
    }

    /// Immutable identity of the last plan-driven launch accepted for this machine. Runtime
    /// status/snapshot/export can consume this hook without copying the full trust evidence yet.
    public func resolvedLaunchIdentity(id: String) -> DoryMachineResolvedLaunchIdentity? {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard machines[id] != nil else { return nil }
        return resolvedLaunchIdentities[id]
    }

    private func statusLocked(id: String, entry: MachineEntry) -> DoryMachineStatus {
        let typedSettings = nativeTypedSettingsSnapshot(id: id)
            ?? DoryMachineTypedSettingsSnapshot(
                legacyEnvironment: entry.configuration.environment,
                displayMode: entry.configuration.displayMode
            )
        if [.starting, .running, .paused].contains(entry.state),
           entry.process?.isRunningOrRestarting != true {
            return DoryMachineStatus(
                id: id,
                state: .failed,
                lastError: entry.lastError ?? "dory-vmm process exited",
                address: entry.configuration.address,
                configuredAddress: entry.configuration.address,
                memoryMB: entry.configuration.memoryMB,
                cpuCount: entry.configuration.cpuCount,
                displayMode: entry.configuration.displayMode,
                bootMode: entry.configuration.bootMode,
                installerMediaAttached: entry.configuration.installerISOPath != nil,
                shares: entry.configuration.shares,
                environment: entry.configuration.environment,
                typedSettings: typedSettings,
                runtimeIdentity: entry.runtimeIdentity,
                installedDesktopPayloadReceipt:
                    entry.configuration.effectiveInstalledDesktopPayloadReceipt
            )
        }
        return DoryMachineStatus(
            id: id,
            state: entry.state,
            pid: entry.process?.pid,
            lastError: entry.lastError,
            handoffSocketPath: entry.handoffServer?.path,
            agentBuild: entry.handoff?.ready.agentBuild,
            agentProtocolVersion: entry.handoff?.ready.agentProtocolVersion,
            agentCapabilities: entry.handoff?.ready.agentCapabilities ?? [],
            agentSocketPath: entry.handoff?.ready.agentSocketPath,
            dockerdSocketPath: entry.handoff?.ready.dockerdSocketPath,
            shellSocketPath: entry.handoff?.ready.shellSocketPath,
            controlSocketPath: entry.handoff?.ready.controlSocketPath,
            address: entry.configuration.address ?? entry.runtimeAddress,
            configuredAddress: entry.configuration.address,
            runtimeAddress: entry.runtimeAddress,
            handoffFDCount: entry.handoff?.fileDescriptors.count ?? 0,
            memoryMB: entry.configuration.memoryMB,
            currentBalloonTargetMB: entry.currentBalloonTargetMB ?? entry.configuration.memoryMB,
            cpuCount: entry.configuration.cpuCount,
            displayMode: entry.configuration.displayMode,
            bootMode: entry.configuration.bootMode,
            installerMediaAttached: entry.configuration.installerISOPath != nil,
            shares: entry.configuration.shares,
            environment: entry.configuration.environment,
            typedSettings: typedSettings,
            runtimeIdentity: entry.runtimeIdentity,
            installedDesktopPayloadReceipt:
                entry.configuration.effectiveInstalledDesktopPayloadReceipt
        )
    }

    private func nativeTypedSettingsSnapshot(
        id: String
    ) -> DoryMachineTypedSettingsSnapshot? {
        guard launchPolicy == .perWorkspaceAuthority,
              let record = try? workspaceRepository.readPersistedRecord(id: id),
              record.legacyConfigurationSHA256 == nil,
              record.legacyMigrationFactsSHA256 == nil else {
            return nil
        }
        return try? DoryMachineTypedSettingsSnapshot(definition: record.definition)
    }

    private func processConfiguration(
        for machine: DoryMachineConfiguration,
        handoffPath: String?,
        resolvedLaunchBinding: MachineBackendLaunchBinding?
    ) throws -> HvProcessConfiguration {
        let target = try processTarget(
            for: machine,
            resolvedLaunchBinding: resolvedLaunchBinding
        )
        return HvProcessConfiguration(
            executablePath: target.executablePath,
            arguments: try processArguments(
                for: machine,
                handoffPath: handoffPath,
                baseArguments: target.baseArguments,
                acceleratedDesktop: target.acceleratedDesktop,
                resolvedLaunchBinding: resolvedLaunchBinding
            ),
            logPath: "\(configuration.logDirectory)/\(machine.id).log",
            restartPolicy: configuration.requiresReadyHandoff
                ? configuration.startupRestartPolicy
                : .none
        )
    }

    private func processTarget(
        for machine: DoryMachineConfiguration,
        resolvedLaunchBinding: MachineBackendLaunchBinding?
    ) throws -> (
        executablePath: String,
        baseArguments: [String],
        acceleratedDesktop: Bool
    ) {
        if let binding = resolvedLaunchBinding {
            switch binding.backend.identity {
            case .doryHypervisor:
                return (
                    binding.executablePath,
                    configuration.acceleratedDesktopBaseArguments,
                    true
                )
            case .appleVirtualizationFramework:
                return (binding.executablePath, configuration.baseArguments, false)
            default:
                throw MachineManagerError.persistence(
                    "resolved backend \(binding.backend.identity.rawValue) has no MachineManager launcher"
                )
            }
        }
        let desktopPreference = try? DoryDesktopVMMPreference(environment: machine.environment)
        let supportsAcceleratedBoot = machine.bootMode == .linuxKernel
            || (machine.bootMode == .efi
                && machine.installerISOPath == nil
                && DoryInstalledLinuxBootBundle.isBundle(atPath: machine.kernelPath))
        if configuration.passMachineArguments,
           machine.displayMode == .desktop,
           supportsAcceleratedBoot,
           machine.installerISOPath == nil,
           desktopPreference != .compatible,
           let executablePath = configuration.acceleratedDesktopExecutablePath {
            return (executablePath, configuration.acceleratedDesktopBaseArguments, true)
        }
        return (configuration.vmmExecutablePath, configuration.baseArguments, false)
    }

    private func validateRuntimeAvailability(_ machine: DoryMachineConfiguration) throws {
        guard machine.displayMode == .desktop,
              machine.installerISOPath == nil else {
            return
        }
        let preference = try DoryDesktopVMMPreference(environment: machine.environment)
        let installedEFIDesktop = machine.bootMode == .efi
            && DoryInstalledLinuxBootBundle.isBundle(atPath: machine.kernelPath)
        if machine.bootMode == .efi,
           preference == .accelerated,
           !installedEFIDesktop {
            throw MachineManagerError.persistence(
                "accelerated installed-Linux runtime is unavailable; reattach and eject the installer media to derive its boot assets"
            )
        }
        guard preference == .accelerated || (installedEFIDesktop && preference != .compatible) else {
            return
        }
        guard let executablePath = configuration.acceleratedDesktopExecutablePath,
              FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw MachineManagerError.persistence(
                "accelerated desktop runtime was required but is unavailable"
            )
        }
    }

    private func validateInstallerArchitecture(_ machine: DoryMachineConfiguration) throws {
        guard machine.bootMode == .efi, let installerISOPath = machine.installerISOPath else {
            return
        }
        let detected: DoryInstallerISOArchitecture
        do {
            detected = try DoryInstallerISOInspector.architecture(atPath: installerISOPath)
        } catch {
            throw MachineManagerError.persistence("could not inspect installer ISO: \(error)")
        }
        switch DoryInstallerISOInspector.compatibility(
            of: detected,
            hostArchitecture: configuration.guestArchitecture
        ) {
        case let .incompatible(message):
            throw MachineManagerError.persistence(message)
        case .compatible, .unknown:
            return
        }
    }

    private func processArguments(
        for machine: DoryMachineConfiguration,
        handoffPath: String?,
        baseArguments: [String],
        acceleratedDesktop: Bool,
        resolvedLaunchBinding: MachineBackendLaunchBinding?
    ) throws -> [String] {
        guard configuration.passMachineArguments else {
            return baseArguments
        }
        let acceleratedInstalledLinux = acceleratedDesktop
            && machine.bootMode == .efi
            && machine.installerISOPath == nil
        let bootDescriptor = acceleratedInstalledLinux
            ? try DoryInstalledLinuxBootBundle.descriptor(atPath: machine.kernelPath)
            : nil
        var arguments = baseArguments + [
            "--machine-id", machine.id,
            "--state-dir", machineStateDirectory(id: machine.id),
            "--dockerd-sock", "\(machineRuntimeDirectory(id: machine.id))/d.sock",
            "--agent-sock", "\(machineRuntimeDirectory(id: machine.id))/a.sock",
            "--shell-sock", "\(machineRuntimeDirectory(id: machine.id))/s.sock",
            "--control-sock", "\(machineRuntimeDirectory(id: machine.id))/c.sock",
            "--kernel", acceleratedInstalledLinux
                ? machineInstalledLinuxKernelPath(id: machine.id)
                : machine.kernelPath,
            "--rootfs", machine.rootfsPath,
            "--boot-mode", acceleratedInstalledLinux ? "efi-installed" : machine.bootMode.rawValue,
            "--memory-mb", String(machine.memoryMB),
            "--cpus", String(machine.cpuCount),
            "--display-mode", machine.displayMode.rawValue,
        ]
        if let bootDescriptor {
            arguments.append(contentsOf: [
                "--initrd", machineInstalledLinuxInitrdPath(id: machine.id),
                "--root-device", bootDescriptor.rootDevice,
                "--generic-guest",
            ])
        }
        if let installerISOPath = machine.installerISOPath {
            arguments.append(contentsOf: ["--installer-iso", installerISOPath])
        }
        if let handoffPath {
            arguments.append(contentsOf: ["--handoff-sock", handoffPath])
        }
        if let resolvedLaunchBinding {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let deviceContract = String(
                decoding: try encoder.encode(resolvedLaunchBinding.devices),
                as: UTF8.self
            )
            arguments.append(contentsOf: [
                "--resolved-graphics", resolvedLaunchBinding.graphics.rawValue,
                "--resolved-devices", deviceContract,
            ])
        }
        for share in machine.shares {
            arguments.append(contentsOf: ["--share", share.argumentValue])
        }
        var launchEnvironment = machine.environment
        if let resolvedLaunchBinding {
            launchEnvironment.removeValue(forKey: DoryDesktopVMMPreference.environmentKey)
            launchEnvironment.removeValue(forKey: DoryDesktopGraphicsPreference.environmentKey)
            launchEnvironment.removeValue(
                forKey: DoryDesktopGraphicsPreference.legacyClassicOnlyEnvironmentKey
            )
            switch resolvedLaunchBinding.backend.identity {
            case .doryHypervisor:
                let preference: DoryDesktopGraphicsPreference
                switch resolvedLaunchBinding.graphics {
                case .hardwareAccelerated3D:
                    preference = .virglVenus
                case .hostAcceleratedDisplay:
                    preference = .virgl
                case .software:
                    preference = .software
                case .none:
                    throw MachineManagerError.persistence(
                        "raw-Hypervisor desktop cannot satisfy a no-graphics resolved plan"
                    )
                }
                launchEnvironment[DoryDesktopGraphicsPreference.environmentKey]
                    = preference.rawValue
                launchEnvironment[DoryDesktopVMMPreference.environmentKey]
                    = DoryDesktopVMMPreference.accelerated.rawValue
            case .appleVirtualizationFramework:
                guard resolvedLaunchBinding.graphics == .hostAcceleratedDisplay
                        || (machine.displayMode == .headless
                            && resolvedLaunchBinding.graphics == .none) else {
                    throw MachineManagerError.persistence(
                        "Virtualization.framework cannot satisfy the exact resolved graphics contract"
                    )
                }
                launchEnvironment[DoryDesktopVMMPreference.environmentKey]
                    = DoryDesktopVMMPreference.compatible.rawValue
            default:
                throw MachineManagerError.persistence(
                    "resolved backend has no exact graphics argument contract"
                )
            }
        }
        for (key, value) in launchEnvironment.sorted(by: { $0.key < $1.key }) {
            arguments.append(contentsOf: ["--env", "\(key)=\(value)"])
        }
        let isSandbox = machine.environment["DORY_SANDBOX"] == "1"
        let sandboxSSHAgentGranted = machine.environment["DORY_SANDBOX_SSH_AGENT"] == "1"
        if let sshAgentSocketPath = configuration.sshAgentSocketPath,
           !sshAgentSocketPath.isEmpty,
           !isSandbox || sandboxSSHAgentGranted {
            arguments.append(contentsOf: ["--ssh-agent-socket", sshAgentSocketPath])
        }
        return arguments
    }

    private func machineStateDirectory(id: String) -> String {
        "\(configuration.stateDirectory)/\(id)"
    }

    private func machineRuntimeDirectory(id: String) -> String {
        let material = Data("\(configuration.stateDirectory)\0\(id)".utf8)
        let token = SHA256.hash(data: material).prefix(12).map {
            String(format: "%02x", $0)
        }.joined()
        return "\(configuration.runtimeDirectory)/\(token)"
    }

    private func handoffSocketPath(id: String) -> String {
        "\(machineRuntimeDirectory(id: id))/h.sock"
    }

    private func desktopUpdateJournalPath(machineID: String) -> String {
        "\(machineStateDirectory(id: machineID))/\(Self.desktopUpdateJournalName)"
    }

    private struct StagedDesktopUpdateAuthority {
        var directory: String
        var bundlePath: String
        var kernelPath: String
    }

    private func stageDesktopUpdateAuthority(
        _ authority: DoryDesktopUpdateArtifactAuthority,
        machineID: String
    ) throws -> StagedDesktopUpdateAuthority {
        guard let bundleSHA256 = authority.receipt.bundleSHA256,
              let kernelSHA256 = authority.receipt.kernelSHA256 else {
            throw MachineManagerError.persistence("desktop update authority lacks artifact digests")
        }
        let directory = machineStateDirectory(id: machineID)
            + "/" + Self.desktopUpdateStagingPrefix + UUID().uuidString.lowercased()
        guard mkdir(directory, 0o700) == 0 else {
            throw MachineManagerError.persistence("could not create private desktop update staging")
        }
        let bundlePath = directory + "/payload.tar"
        let kernelPath = directory + "/kernel"
        do {
            try Self.copyExactDesktopUpdateArtifact(
                source: authority.bundlePath,
                destination: bundlePath,
                expectedByteCount: authority.bundleByteCount,
                expectedSHA256: bundleSHA256
            )
            try Self.copyExactDesktopUpdateArtifact(
                source: authority.kernelPath,
                destination: kernelPath,
                expectedByteCount: authority.kernelByteCount,
                expectedSHA256: kernelSHA256
            )
            try Self.syncDirectory(path: directory)
            return StagedDesktopUpdateAuthority(
                directory: directory,
                bundlePath: bundlePath,
                kernelPath: kernelPath
            )
        } catch {
            try? FileManager.default.removeItem(atPath: directory)
            throw error
        }
    }

    private static func copyExactDesktopUpdateArtifact(
        source: String,
        destination: String,
        expectedByteCount: UInt64,
        expectedSHA256: String
    ) throws {
        let sourceFD = open(source, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard sourceFD >= 0 else {
            throw MachineManagerError.persistence("could not open verified desktop update artifact")
        }
        defer { close(sourceFD) }
        var before = stat()
        guard fstat(sourceFD, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size > 0,
              UInt64(before.st_size) == expectedByteCount else {
            throw MachineManagerError.persistence("verified desktop update artifact identity is invalid")
        }
        let destinationFD = open(
            destination,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o400)
        )
        guard destinationFD >= 0 else {
            throw MachineManagerError.persistence("could not create private desktop update artifact")
        }
        var copied: UInt64 = 0
        var hasher = SHA256()
        var copyError: Error?
        do {
            let input = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: false)
            let output = FileHandle(fileDescriptor: destinationFD, closeOnDealloc: false)
            while true {
                let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
                if chunk.isEmpty { break }
                copied = copied.addingReportingOverflow(UInt64(chunk.count)).partialValue
                guard copied <= expectedByteCount else {
                    throw MachineManagerError.persistence("verified desktop update artifact grew while staging")
                }
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
            }
            guard fsync(destinationFD) == 0 else {
                throw MachineManagerError.persistence("could not sync private desktop update artifact")
            }
        } catch {
            copyError = error
        }
        close(destinationFD)
        if let copyError {
            try? FileManager.default.removeItem(atPath: destination)
            throw copyError
        }
        var after = stat()
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard fstat(sourceFD, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              copied == expectedByteCount,
              digest == expectedSHA256 else {
            try? FileManager.default.removeItem(atPath: destination)
            throw MachineManagerError.persistence("verified desktop update artifact changed while staging")
        }
    }

    private func persistDesktopUpdateJournal(_ journal: DesktopUpdateJournal) throws {
        guard journal.isValid else {
            throw MachineManagerError.persistence("invalid desktop update journal")
        }
        let directory = machineStateDirectory(id: journal.machineID)
        guard Self.isPrivateDirectory(path: directory) else {
            throw MachineManagerError.persistence("desktop update journal owner is not private")
        }
        let temporaryPath = "\(directory)/.desktop-update.tmp-\(UUID().uuidString)"
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(journal)
            try Self.writeDurablePrivateData(data, toPath: temporaryPath)
            guard rename(temporaryPath, desktopUpdateJournalPath(machineID: journal.machineID)) == 0 else {
                throw MachineManagerError.persistence(
                    "could not publish desktop update journal: \(String(cString: strerror(errno)))"
                )
            }
            try Self.syncDirectory(path: directory)
        } catch {
            try? FileManager.default.removeItem(atPath: temporaryPath)
            if let error = error as? MachineManagerError { throw error }
            throw MachineManagerError.persistence("could not persist desktop update journal: \(error)")
        }
    }

    private func removeDesktopUpdateJournal(machineID: String) throws {
        let path = desktopUpdateJournalPath(machineID: machineID)
        guard Self.pathEntryExists(path) else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
            try Self.syncDirectory(path: machineStateDirectory(id: machineID))
        } catch {
            throw MachineManagerError.persistence("could not remove desktop update journal: \(error)")
        }
    }

    /// Commits the verified installed-state receipt and removes only its two superseded legacy
    /// fields. The update transaction's last-good snapshot owns rollback of this exact change.
    private func publishInstalledDesktopPayloadReceipt(
        original: DoryMachineConfiguration,
        receipt: DoryInstalledDesktopPayloadReceipt
    ) throws {
        guard receipt.isValid, receipt.provenance == .verifiedUpdateBundle else {
            throw MachineManagerError.persistence(
                "desktop update produced an invalid installed payload receipt"
            )
        }
        var updated = original
        updated.shares = original.shares
        updated.environment.removeValue(
            forKey: DoryInstalledDesktopPayloadReceipt.legacyReleaseVersionEnvironmentKey
        )
        updated.environment.removeValue(
            forKey: DoryInstalledDesktopPayloadReceipt.legacyInputSHA256EnvironmentKey
        )
        updated.installedDesktopPayloadReceipt = receipt
        try Self.validateLaunchConfiguration(updated)
        try persist(updated)
        try publishConfiguration(updated)
    }

    private func recoverInterruptedDesktopUpdates() {
        lock.lock()
        let machineIDs = Array(machines.keys)
        lock.unlock()
        for machineID in machineIDs {
            let path = desktopUpdateJournalPath(machineID: machineID)
            guard Self.pathEntryExists(path) else {
                continue
            }
            guard let data = Self.readPrivateMetadata(path: path),
                  let journal = try? JSONDecoder().decode(DesktopUpdateJournal.self, from: data),
                  journal.machineID == machineID,
                  journal.isValid else {
                lock.lock()
                if var entry = machines[machineID] {
                    entry.state = .failed
                    entry.lastError = "Desktop update recovery is required: the durable update journal is invalid."
                    machines[machineID] = entry
                }
                lock.unlock()
                continue
            }
            if journal.stage == .committed {
                // Schema 1 was authored by the pre-receipt updater after its machine.json write
                // had committed. It carried no component authority to revalidate, and historical
                // recovery semantics treated this marker as cleanup-only. Preserve that exact
                // upgrade behavior instead of relabeling a working legacy machine as failed.
                if journal.schema == 1 {
                    do {
                        try removeDesktopUpdateJournal(machineID: machineID)
                    } catch {
                        lock.lock()
                        machines[machineID]?.lastError = "Legacy desktop update committed, but journal cleanup requires retry: \(error)"
                        lock.unlock()
                    }
                    continue
                }
                lock.lock()
                let receipt = machines[machineID]?.configuration.installedDesktopPayloadReceipt
                let environment = machines[machineID]?.configuration.environment
                lock.unlock()
                var expectedReceipt = journal.updateAuthority
                expectedReceipt?.inputSHA256 = receipt?.inputSHA256 ?? ""
                guard let receipt,
                      let environment,
                      receipt.provenance == .verifiedUpdateBundle,
                      receipt.hasCoherentAuthority(environment: environment),
                      receipt == expectedReceipt else {
                    lock.lock()
                    if var entry = machines[machineID] {
                        entry.state = .failed
                        entry.lastError = "Desktop update recovery is required: committed component evidence does not match machine state."
                        machines[machineID] = entry
                    }
                    lock.unlock()
                    continue
                }
                do {
                    try removeDesktopUpdateJournal(machineID: machineID)
                } catch {
                    lock.lock()
                    machines[machineID]?.lastError = "Desktop update committed, but journal cleanup requires retry: \(error)"
                    lock.unlock()
                }
                continue
            }
            do {
                if journal.schema == 2 {
                    let snapshot = try loadSnapshot(
                        machineID: machineID,
                        snapshotID: journal.snapshotID
                    )
                    lock.lock()
                    let current = machines[machineID]?.configuration
                    lock.unlock()
                    guard let current,
                          let expectedSourceSHA256 = journal.sourceConfigurationSHA256 else {
                        throw MachineManagerError.persistence(
                            "desktop update journal source authority is unavailable"
                        )
                    }
                    let source = DoryMachineConfiguration(
                        id: current.id,
                        kernelPath: current.kernelPath,
                        rootfsPath: current.rootfsPath,
                        bootMode: snapshot.bootMode,
                        memoryMB: snapshot.memoryMB,
                        cpuCount: snapshot.cpuCount,
                        address: snapshot.address,
                        displayMode: snapshot.displayMode,
                        shares: snapshot.shares,
                        environment: snapshot.environment,
                        installedDesktopPayloadReceipt:
                            Self.configurationReceipt(restoring: snapshot)
                    )
                    let actualSourceSHA256 = Self.sha256(
                        data: try DoryMachineConfigurationMigrationBridge.encodeLegacy(source)
                    )
                    guard actualSourceSHA256 == expectedSourceSHA256 else {
                        throw MachineManagerError.persistence(
                            "desktop update journal does not match its last-good snapshot"
                        )
                    }
                }
                _ = try restoreSnapshot(machineID: machineID, snapshotID: journal.snapshotID)
                try removeDesktopUpdateJournal(machineID: machineID)
                lock.lock()
                if var entry = machines[machineID] {
                    entry.lastError = "An interrupted desktop update was rolled back to \(journal.snapshotID). Start the machine when ready."
                    machines[machineID] = entry
                }
                lock.unlock()
            } catch {
                lock.lock()
                if var entry = machines[machineID] {
                    entry.state = .failed
                    entry.lastError = "Interrupted desktop update recovery failed: \(error)"
                    machines[machineID] = entry
                }
                lock.unlock()
            }
        }
    }

    @discardableResult
    private func requireSuccessfulDesktopUpdateExec(
        id: String,
        argv: [String],
        env: [DoryExecEnvironment] = [],
        timeoutMs: UInt64 = 30_000,
        outputLimitBytes: UInt64 = 1024 * 1024,
        stage: String
    ) throws -> DoryExecResult {
        let result = try exec(
            id: id,
            argv: argv,
            env: env,
            timeoutMs: timeoutMs,
            outputLimitBytes: outputLimitBytes
        )
        guard result.exitCode == 0, !result.timedOut else {
            let stderr = String(decoding: result.stderr.suffix(4096), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw MachineManagerError.persistence(
                "desktop update could not \(stage) (exit \(result.timedOut ? 124 : result.exitCode))\(stderr.isEmpty ? "" : ": \(stderr)")"
            )
        }
        return result
    }

    private func qualifyUpdatedDesktop(
        id: String,
        distro: String,
        version: String,
        inputSHA256: String
    ) throws {
        let script = """
        set -euo pipefail
        . /etc/os-release
        [ "$ID" = "$DORY_EXPECTED_DISTRO" ]
        grep -Fqx "version=$DORY_EXPECTED_VERSION" /var/lib/dory/desktop-update.env
        grep -Fqx "input_sha256=$DORY_EXPECTED_INPUT" /var/lib/dory/desktop-update.env
        [ "$(systemctl get-default)" = graphical.target ]
        for _ in $(seq 1 180); do
          if systemctl is-active --quiet NetworkManager.service \
              && systemctl is-active --quiet display-manager.service \
              && systemctl is-active --quiet dory-boot.service \
              && systemctl is-active --quiet dory-zram.service \
              && grep -q '^/dev/zram0 ' /proc/swaps; then
            break
          fi
          sleep 1
        done
        systemctl is-active --quiet NetworkManager.service
        systemctl is-active --quiet display-manager.service
        systemctl is-active --quiet dory-boot.service
        systemctl is-active --quiet dory-zram.service
        grep -q '^/dev/zram0 ' /proc/swaps
        user="$(cat /var/lib/dory/username 2>/dev/null || printf 'dory')"
        id "$user" >/dev/null
        for _ in $(seq 1 120); do
          if pgrep -u "$user" -f 'gnome-shell|xfce4-session' >/dev/null; then break; fi
          sleep 1
        done
        pgrep -u "$user" -f 'gnome-shell|xfce4-session' >/dev/null
        case "$DORY_EXPECTED_DISTRO" in
          debian) command -v firefox-esr >/dev/null ;;
          ubuntu) command -v firefox >/dev/null ;;
          kali) command -v firefox-esr >/dev/null || command -v firefox >/dev/null ;;
        esac
        for _ in $(seq 1 120); do
          if getent ahosts example.com >/dev/null; then break; fi
          sleep 1
        done
        getent ahosts example.com >/dev/null
        """
        _ = try requireSuccessfulDesktopUpdateExec(
            id: id,
            argv: ["/bin/bash", "-lc", script],
            env: [
                DoryExecEnvironment(key: "DORY_EXPECTED_DISTRO", value: distro),
                DoryExecEnvironment(key: "DORY_EXPECTED_VERSION", value: version),
                DoryExecEnvironment(key: "DORY_EXPECTED_INPUT", value: inputSHA256),
            ],
            timeoutMs: 480_000,
            outputLimitBytes: 4 * 1024 * 1024,
            stage: "qualify the updated desktop"
        )
    }

    private static func desktopUpdateInputSHA256(from result: DoryExecResult) -> String? {
        let output = String(decoding: result.stdout, as: UTF8.self)
        for line in output.split(separator: "\n").reversed() {
            let fields = line.split(separator: " ")
            guard fields.count == 7,
                  fields[0] == "Dory",
                  fields[1] == "desktop",
                  fields[2] == "update",
                  fields[3] == "applied:" else { continue }
            let digest = String(fields[6])
            if digest.count == 64, digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) {
                return digest
            }
        }
        return nil
    }

    private static func desktopUpdateReceiptInputSHA256(
        from result: DoryExecResult,
        distro: String,
        version: String
    ) -> String? {
        guard !result.stdoutTruncated else { return nil }
        let fields = Dictionary(uniqueKeysWithValues: String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line -> (String, String)? in
                guard let separator = line.firstIndex(of: "=") else { return nil }
                return (String(line[..<separator]), String(line[line.index(after: separator)...]))
            })
        guard fields["schema"] == "1",
              fields["distro"] == distro,
              fields["version"] == version,
              let digest = fields["input_sha256"],
              digest.count == 64,
              digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            return nil
        }
        return digest
    }

    public func agentInfo(id: String) throws -> DoryAgentInfo {
        try withAgentClient(id: id) { client in
            try client.info()
        }
    }

    public func telemetry(id: String) throws -> DoryTelemetry {
        try withAgentClient(id: id, requiredCapability: "telemetry") { client in
            try client.telemetry()
        }
    }

    public func memorySnapshots() -> [GuestMemorySnapshot] {
        list().compactMap { status in
            if status.state == .paused {
                let residentMB = max(1, status.currentBalloonTargetMB)
                return GuestMemorySnapshot(
                    id: "machine.\(status.id)",
                    kind: .virtualMachine,
                    telemetry: DoryTelemetry(
                        memTotalKB: residentMB * 1024,
                        memAvailableKB: 0,
                        psiSomeAvg10: 0,
                        psiFullAvg10: 0
                    ),
                    currentTargetMB: residentMB,
                    maximumTargetMB: status.memoryMB,
                    canBalloon: false
                )
            }
            guard status.state == .running, status.agentSocketPath != nil else {
                return nil
            }
            guard let telemetry = try? telemetry(id: status.id) else {
                return nil
            }
            return GuestMemorySnapshot(
                id: "machine.\(status.id)",
                kind: .virtualMachine,
                telemetry: telemetry,
                currentTargetMB: status.currentBalloonTargetMB,
                maximumTargetMB: status.memoryMB,
                canBalloon: status.controlSocketPath != nil
            )
        }
    }

    public func applyBalloonTargets(_ targets: [BalloonTarget]) throws {
        for target in targets where target.kind == .virtualMachine {
            guard target.id.hasPrefix("machine.") else { continue }
            let machineID = String(target.id.dropFirst("machine.".count))
            try applyBalloonTarget(machineID: machineID, targetMB: target.targetMB)
        }
    }

    public func applyBalloonTarget(machineID: String, targetMB: UInt64) throws {
        let socketPath: String
        let clampedTargetMB: UInt64
        lock.lock()
        if let entry = machines[machineID],
           entry.state == .running,
           entry.process?.isRunning == true,
           let path = entry.handoff?.ready.controlSocketPath {
            socketPath = path
            clampedTargetMB = min(max(targetMB, 1), entry.configuration.memoryMB)
        } else {
            lock.unlock()
            throw MachineManagerError.balloonUnavailable(machineID)
        }
        lock.unlock()

        do {
            try balloonController.setBalloonTarget(socketPath: socketPath, targetMB: clampedTargetMB)
        } catch {
            throw MachineManagerError.balloonApplyFailed(machineID, "\(error)")
        }

        lock.lock()
        if var entry = machines[machineID],
           entry.state == .running,
           entry.handoff?.ready.controlSocketPath == socketPath {
            entry.currentBalloonTargetMB = clampedTargetMB
            machines[machineID] = entry
        }
        lock.unlock()
    }

    public func exec(
        id: String,
        argv: [String],
        cwd: String = "",
        env: [DoryExecEnvironment] = [],
        timeoutMs: UInt64 = 30_000,
        outputLimitBytes: UInt64 = 1024 * 1024
    ) throws -> DoryExecResult {
        guard !argv.isEmpty else {
            throw MachineManagerError.agentUnavailable(id)
        }
        return try withAgentClient(id: id, requiredCapability: "exec") { client in
            try client.exec(
                argv: argv,
                cwd: cwd,
                env: env,
                timeoutMs: timeoutMs,
                outputLimitBytes: outputLimitBytes
            )
        }
    }

    /// Copies a daemon-private staging tree into a fresh guest-owned Downloads subdirectory.
    /// The destination is intentionally derived here rather than accepted from XPC: `sync-push`
    /// makes its target an exact replica, so pointing it at an existing user directory could erase
    /// unrelated files. Synchronous compatibility callers remain responsible for deleting their
    /// staging root afterwards.
    public func transferStagedFiles(
        id: String,
        privateStagingRoot: String
    ) throws -> DoryMachineFileTransferResult {
        let transferID = Self.makeMachineFileTransferID()
        fileTransferLock.lock()
        pruneFileTransferOperationsLocked(now: Date())
        if activeFileTransferByMachine[id] != nil {
            fileTransferLock.unlock()
            throw DoryMachineFileTransferError.transferAlreadyInProgress(id)
        }
        activeFileTransferByMachine[id] = transferID
        fileTransferLock.unlock()
        defer {
            fileTransferLock.lock()
            if activeFileTransferByMachine[id] == transferID {
                activeFileTransferByMachine.removeValue(forKey: id)
            }
            fileTransferLock.unlock()
        }
        guard DoryMachineFileTransferStager.isClientStagingRoot(privateStagingRoot) else {
            throw DoryMachineFileTransferError.invalidPrivateStagingRoot
        }
        return try performStagedFileTransfer(
            id: id,
            privateStagingRoot: privateStagingRoot,
            transferID: transferID,
            operation: nil
        )
    }

    /// Starts a cancellable transfer without retaining an XPC reply block for the duration of the
    /// data-plane operation. Only one active transfer per machine is allowed; terminal records are
    /// retained briefly for polling and bounded globally.
    public func beginStagedFileTransfer(
        id: String,
        privateStagingRoot: String
    ) throws -> DoryMachineFileTransferOperationStatus {
        guard let machineStatus = status(id: id) else {
            throw MachineManagerError.unknownMachine(id)
        }
        guard machineStatus.state == .running,
              machineStatus.agentSocketPath != nil else {
            throw MachineManagerError.agentUnavailable(id)
        }
        for capability in ["exec", "sync-push"] where
            !machineStatus.supportsAgentCapability(capability) {
            throw MachineManagerError.agentCapabilityUnavailable(id, capability)
        }

        let transferID = Self.makeMachineFileTransferID()
        fileTransferLock.lock()
        pruneFileTransferOperationsLocked(now: Date())
        if activeFileTransferByMachine[id] != nil {
            fileTransferLock.unlock()
            throw DoryMachineFileTransferError.transferAlreadyInProgress(id)
        }
        let claimedStagingRoot: String
        do {
            claimedStagingRoot = try DoryMachineFileTransferStager.claimForDaemon(
                privateStagingRoot,
                operationID: transferID
            )
        } catch {
            fileTransferLock.unlock()
            throw DoryMachineFileTransferError.invalidPrivateStagingRoot
        }
        let operation = MachineFileTransferOperation(
            operationID: transferID,
            machineID: id
        )
        fileTransferOperations[transferID] = operation
        activeFileTransferByMachine[id] = transferID
        fileTransferLock.unlock()

        fileTransferQueue.async { [self, operation] in
            var outcome: MachineFileTransferTerminalOutcome
            do {
                let result = try performStagedFileTransfer(
                    id: id,
                    privateStagingRoot: claimedStagingRoot,
                    transferID: transferID,
                    operation: operation
                )
                if operation.isCancellationRequested {
                    outcome = .cancelled
                } else {
                    outcome = .completed(result)
                }
            } catch {
                if operation.isCancellationRequested {
                    outcome = .cancelled
                } else {
                    outcome = .failed(Self.fileTransferFailure(error, machineID: id))
                }
            }
            do {
                try DoryMachineFileTransferStager.removeManagedStagingRoot(
                    claimedStagingRoot
                )
            } catch {
                outcome = .failed(.init(
                    code: .transferFailed,
                    message: "File transfer cleanup failed for \(id)."
                ))
            }
            fileTransferLock.lock()
            switch outcome {
            case let .completed(result):
                operation.complete(result)
            case .cancelled:
                operation.cancel()
            case let .failed(failure):
                operation.fail(failure)
            }
            if activeFileTransferByMachine[id] == transferID {
                activeFileTransferByMachine.removeValue(forKey: id)
            }
            fileTransferLock.unlock()
        }
        return operation.status()
    }

    public func stagedFileTransferStatus(
        id: String,
        operationID: String
    ) throws -> DoryMachineFileTransferOperationStatus {
        fileTransferLock.lock()
        pruneFileTransferOperationsLocked(now: Date())
        let operation = fileTransferOperations[operationID]
        fileTransferLock.unlock()
        guard let operation, operation.machineID == id else {
            throw DoryMachineFileTransferError.unknownTransfer(id, operationID)
        }
        return operation.status()
    }

    /// Returns the one active transfer for a machine so a reconnecting app can resume polling
    /// without retaining an operation identifier across process lifetime. Terminal history is not
    /// rediscovered: it remains available only through the exact operation-ID status endpoint.
    public func currentStagedFileTransferStatus(
        id: String
    ) -> DoryMachineFileTransferOperationStatus? {
        fileTransferLock.lock()
        pruneFileTransferOperationsLocked(now: Date())
        guard let operationID = activeFileTransferByMachine[id],
              let operation = fileTransferOperations[operationID] else {
            activeFileTransferByMachine.removeValue(forKey: id)
            fileTransferLock.unlock()
            return nil
        }
        fileTransferLock.unlock()
        return operation.status()
    }

    public func cancelStagedFileTransfer(
        id: String,
        operationID: String
    ) throws -> DoryMachineFileTransferOperationStatus {
        fileTransferLock.lock()
        let operation = fileTransferOperations[operationID]
        fileTransferLock.unlock()
        guard let operation, operation.machineID == id else {
            throw DoryMachineFileTransferError.unknownTransfer(id, operationID)
        }
        operation.requestCancellation()
        return operation.status()
    }

    private func performStagedFileTransfer(
        id: String,
        privateStagingRoot: String,
        transferID: String,
        operation: MachineFileTransferOperation?
    ) throws -> DoryMachineFileTransferResult {
        guard DoryMachineFileTransferStager.isManagedStagingRoot(privateStagingRoot) else {
            throw DoryMachineFileTransferError.invalidPrivateStagingRoot
        }
        guard let machineStatus = status(id: id) else {
            throw MachineManagerError.unknownMachine(id)
        }
        guard machineStatus.state == .running,
              machineStatus.agentSocketPath != nil else {
            throw MachineManagerError.agentUnavailable(id)
        }
        for capability in ["exec", "sync-push"] where
            !machineStatus.supportsAgentCapability(capability) {
            throw MachineManagerError.agentCapabilityUnavailable(id, capability)
        }

        guard let account = machineStatus.typedSettings?.guestIdentityIntent.account,
              let username = account.username,
              DoryVMGuestAccountIntent.isValidUsername(username),
              username != "root" else {
            throw DoryMachineFileTransferError.guestAccountUnavailable(id)
        }

        let guestHome = "/home/\(username)"
        let downloads = guestHome + "/Downloads"
        let guestDestination = downloads + "/Dory Transfer " + transferID
        operation?.setGuestDestination(guestDestination)
        try Self.requireTransferNotCancelled(operation)

        return try withAgentClient(id: id) { client in
            try Self.requireTransferNotCancelled(operation)
            let uid = try Self.guestNumericIdentity(
                client: client,
                program: "/usr/bin/id",
                argument: "-u",
                username: username,
                machineID: id
            )
            let gid = try Self.guestNumericIdentity(
                client: client,
                program: "/usr/bin/id",
                argument: "-g",
                username: username,
                machineID: id
            )
            if let expectedUID = account.numericUserID, expectedUID != uid {
                throw DoryMachineFileTransferError.guestAccountUnavailable(id)
            }
            let guestIdentityEnvironment = [
                DoryExecEnvironment(key: "DORY_AGENT_RUN_UID", value: String(uid)),
                DoryExecEnvironment(key: "DORY_AGENT_RUN_GID", value: String(gid)),
            ]
            try Self.requireTransferNotCancelled(operation)
            try Self.requireSuccessfulTransferCommand(
                client.exec(
                    argv: ["/bin/mkdir", "-p", "--", downloads],
                    cwd: guestHome,
                    env: guestIdentityEnvironment,
                    timeoutMs: 30_000,
                    outputLimitBytes: 64 * 1024
                ),
                error: .guestPreparationFailed(id)
            )
            try Self.requireTransferNotCancelled(operation)
            // No `-p`: a collision or pre-existing attacker-controlled directory must fail rather
            // than becoming the exact-replica target.
            try Self.requireSuccessfulTransferCommand(
                client.exec(
                    argv: ["/bin/mkdir", "--", guestDestination],
                    cwd: downloads,
                    env: guestIdentityEnvironment,
                    timeoutMs: 30_000,
                    outputLimitBytes: 64 * 1024
                ),
                error: .guestPreparationFailed(id)
            )

            var completed = false
            defer {
                if !completed {
                    _ = try? client.exec(
                        argv: ["/bin/rm", "-rf", "--", guestDestination],
                        cwd: downloads,
                        env: [],
                        timeoutMs: 30_000,
                        outputLimitBytes: 64 * 1024
                    )
                }
            }
            let stats: DoryPushStats
            do {
                if let operation {
                    operation.setTransferring()
                    stats = try client.push(
                        localRoot: privateStagingRoot,
                        remoteRoot: guestDestination,
                        control: operation.control
                    )
                } else {
                    stats = try client.push(
                        localRoot: privateStagingRoot,
                        remoteRoot: guestDestination
                    )
                }
            } catch {
                throw DoryMachineFileTransferError.transferFailed(id)
            }
            try Self.requireTransferNotCancelled(operation)
            guard stats.filesDeleted == 0 else {
                throw DoryMachineFileTransferError.transferFailed(id)
            }
            operation?.setFinalizing()
            try Self.requireSuccessfulTransferCommand(
                client.exec(
                    argv: [
                        "/bin/chown", "-R", "--", "\(uid):\(gid)", guestDestination,
                    ],
                    cwd: downloads,
                    env: [],
                    timeoutMs: 30_000,
                    outputLimitBytes: 64 * 1024
                ),
                error: .guestFinalizationFailed(id)
            )
            try Self.requireTransferNotCancelled(operation)
            completed = true
            return DoryMachineFileTransferResult(
                transferID: transferID,
                guestDestination: guestDestination,
                stats: stats
            )
        }
    }

    private static func makeMachineFileTransferID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func requireTransferNotCancelled(
        _ operation: MachineFileTransferOperation?
    ) throws {
        if operation?.isCancellationRequested == true {
            throw DoryMachineFileTransferCancellation.cancelled
        }
    }

    private static func fileTransferFailure(
        _ error: Error,
        machineID: String
    ) -> DoryMachineFileTransferFailure {
        let transferError = error as? DoryMachineFileTransferError
        switch transferError {
        case .guestAccountUnavailable:
            return .init(code: .guestUnavailable, message: "Guest account is unavailable.")
        case .guestPreparationFailed:
            return .init(code: .guestPreparationFailed, message: "Could not prepare the guest destination.")
        case .guestFinalizationFailed:
            return .init(code: .guestFinalizationFailed, message: "Could not finalize guest file ownership.")
        case .invalidPrivateStagingRoot, .transferAlreadyInProgress, .unknownTransfer,
             .transferFailed, nil:
            return .init(code: .transferFailed, message: "File transfer failed for \(machineID).")
        }
    }

    private func pruneFileTransferOperationsLocked(now: Date) {
        let expiration = now.addingTimeInterval(-60 * 60)
        fileTransferOperations = fileTransferOperations.filter { _, operation in
            guard let finishedAt = operation.terminalDate else { return true }
            return finishedAt >= expiration
        }
        if fileTransferOperations.count <= 128 { return }
        let removable = fileTransferOperations
            .filter { $0.value.isTerminal }
            .sorted { ($0.value.terminalDate ?? .distantFuture) < ($1.value.terminalDate ?? .distantFuture) }
        for (operationID, _) in removable.prefix(fileTransferOperations.count - 128) {
            fileTransferOperations.removeValue(forKey: operationID)
        }
    }

    private static func guestNumericIdentity(
        client: any AgentControlClient,
        program: String,
        argument: String,
        username: String,
        machineID: String
    ) throws -> UInt32 {
        let result = try client.exec(
            argv: [program, argument, "--", username],
            cwd: "/",
            env: [],
            timeoutMs: 10_000,
            outputLimitBytes: 4 * 1024
        )
        guard result.exitCode == 0,
              !result.timedOut,
              !result.stdoutTruncated,
              !result.stderrTruncated,
              let value = UInt32(
                  String(decoding: result.stdout, as: UTF8.self)
                      .trimmingCharacters(in: .whitespacesAndNewlines)
              ),
              DoryVMGuestAccountIntent.isValidNumericUserID(value) else {
            throw DoryMachineFileTransferError.guestAccountUnavailable(machineID)
        }
        return value
    }

    private static func requireSuccessfulTransferCommand(
        _ result: DoryExecResult,
        error: DoryMachineFileTransferError
    ) throws {
        guard result.exitCode == 0, !result.timedOut else { throw error }
    }

    private func withAgentClient<T>(
        id: String,
        requiredCapability: String? = nil,
        minimumCapabilityVersion: UInt32 = 1,
        _ operation: (any AgentControlClient) throws -> T
    ) throws -> T {
        guard let status = status(id: id) else {
            throw MachineManagerError.unknownMachine(id)
        }
        guard status.state == .running, let socketPath = status.agentSocketPath else {
            throw MachineManagerError.agentUnavailable(id)
        }
        if let requiredCapability,
           !status.supportsAgentCapability(
               requiredCapability,
               minimumVersion: minimumCapabilityVersion
           ) {
            throw MachineManagerError.agentCapabilityUnavailable(id, requiredCapability)
        }
        let client = try agentConnector(socketPath)
        defer { client.close() }
        return try operation(client)
    }

    private func machineConfigPath(id: String) -> String {
        "\(machineStateDirectory(id: id))/machine.json"
    }

    private func machineRootfsPath(id: String) -> String {
        "\(machineStateDirectory(id: id))/rootfs.ext4"
    }

    private func machineKernelPath(id: String) -> String {
        "\(machineStateDirectory(id: id))/kernel"
    }

    private func machineInstalledLinuxKernelPath(id: String) -> String {
        "\(machineStateDirectory(id: id))/\(Self.installedLinuxKernelName)"
    }

    private func machineInstalledLinuxInitrdPath(id: String) -> String {
        "\(machineStateDirectory(id: id))/\(Self.installedLinuxInitrdName)"
    }

    private func machineInstallerISOPath(id: String) -> String {
        "\(machineStateDirectory(id: id))/installer.iso"
    }

    private func ensureInstalledLinuxBootBundleIfNeeded(
        _ machine: DoryMachineConfiguration
    ) throws {
        guard machine.bootMode == .efi,
              machine.displayMode == .desktop,
              machine.installerISOPath == nil,
              try DoryDesktopVMMPreference(environment: machine.environment) != .compatible,
              configuration.acceleratedDesktopExecutablePath != nil,
              !DoryInstalledLinuxBootBundle.isBundle(atPath: machine.kernelPath) else {
            return
        }
        let installerPath = machineInstallerISOPath(id: machine.id)
        guard Self.isPrivateRegularFile(path: installerPath) else {
            throw MachineManagerError.persistence(
                "installed Linux acceleration requires the managed installer ISO to derive a kernel and initrd"
            )
        }
        do {
            let assets = try DoryLinuxInstallerBootAssetExtractor.extract(atPath: installerPath)
            let rootDevice = try DoryLinuxInstalledDiskInspector.rootDevice(atPath: machine.rootfsPath)
            try DoryInstalledLinuxBootBundle.write(
                assets: assets,
                rootDevice: rootDevice,
                toPath: machine.kernelPath
            )
        } catch {
            throw MachineManagerError.persistence(
                "could not prepare the installed Linux accelerated runtime: \(error.localizedDescription)"
            )
        }
    }

    private func materializeInstalledLinuxBootRuntimeIfNeeded(
        _ machine: DoryMachineConfiguration
    ) throws {
        guard machine.bootMode == .efi,
              machine.installerISOPath == nil,
              try DoryDesktopVMMPreference(environment: machine.environment) != .compatible,
              DoryInstalledLinuxBootBundle.isBundle(atPath: machine.kernelPath) else {
            return
        }
        do {
            try DoryInstalledLinuxBootBundle.materialize(
                fromPath: machine.kernelPath,
                kernelPath: machineInstalledLinuxKernelPath(id: machine.id),
                initrdPath: machineInstalledLinuxInitrdPath(id: machine.id)
            )
        } catch {
            throw MachineManagerError.persistence(
                "could not verify the installed Linux accelerated runtime: \(error.localizedDescription)"
            )
        }
    }

    /// Installed-Linux acceleration launches materialized kernel/initrd paths rather than the
    /// authority-bound bundle itself. Re-materialize from the fully verified bundle only after
    /// the single-use pre-spawn authorization has succeeded so stale or replaced derived files
    /// can never reach process construction.
    private func revalidateMaterializedInstalledLinuxBootRuntimeImmediatelyBeforeSpawn(
        _ machine: DoryMachineConfiguration,
        launchBinding: MachineBackendLaunchBinding
    ) throws {
        guard launchBinding.backend.identity == .doryHypervisor,
              machine.bootMode == .efi,
              machine.installerISOPath == nil,
              DoryInstalledLinuxBootBundle.isBundle(atPath: machine.kernelPath) else {
            return
        }
        do {
            try DoryInstalledLinuxBootBundle.materialize(
                fromPath: machine.kernelPath,
                kernelPath: machineInstalledLinuxKernelPath(id: machine.id),
                initrdPath: machineInstalledLinuxInitrdPath(id: machine.id)
            )
            guard Self.isPrivateRegularFile(
                path: machineInstalledLinuxKernelPath(id: machine.id)
            ), Self.isPrivateRegularFile(
                path: machineInstalledLinuxInitrdPath(id: machine.id)
            ) else {
                throw MachineManagerError.persistence(
                    "materialized installed-Linux launch artifacts are not private regular files"
                )
            }
        } catch let error as MachineManagerError {
            throw error
        } catch {
            throw MachineManagerError.persistence(
                "installed-Linux launch artifacts failed final verification: \(error)"
            )
        }
    }

    private func machineFirmwareIdentifierPath(id: String) -> String {
        "\(machineStateDirectory(id: id))/MachineIdentifier"
    }

    private func machineFirmwareNVRAMPath(id: String) -> String {
        "\(machineStateDirectory(id: id))/NVRAM"
    }

    private func snapshotDirectory(machineID: String) -> String {
        "\(machineStateDirectory(id: machineID))/snapshots"
    }

    private func snapshotMetadataPath(machineID: String, snapshotID: String) -> String {
        "\(snapshotDirectory(machineID: machineID))/\(snapshotID).json"
    }

    private func snapshotRootfsPath(machineID: String, snapshotID: String) -> String {
        "\(snapshotDirectory(machineID: machineID))/\(snapshotID).ext4"
    }

    private func snapshotKernelPath(machineID: String, snapshotID: String) -> String {
        "\(snapshotDirectory(machineID: machineID))/\(snapshotID).kernel"
    }

    private func snapshotMachineIdentifierPath(machineID: String, snapshotID: String) -> String {
        "\(snapshotDirectory(machineID: machineID))/\(snapshotID).machine-identifier"
    }

    private func snapshotNVRAMPath(machineID: String, snapshotID: String) -> String {
        "\(snapshotDirectory(machineID: machineID))/\(snapshotID).nvram"
    }

    private func availableImportedSnapshotID(machineID: String, preferredID: String) throws -> String {
        if !snapshotArtifactsExist(machineID: machineID, snapshotID: preferredID) {
            return preferredID
        }
        for _ in 0..<64 {
            let candidate = Self.generatedSnapshotID(prefix: "import")
            if !snapshotArtifactsExist(machineID: machineID, snapshotID: candidate) {
                return candidate
            }
        }
        throw MachineManagerError.persistence("could not allocate a unique imported snapshot id")
    }

    private func snapshotArtifactsExist(machineID: String, snapshotID: String) -> Bool {
        Self.pathEntryExists(snapshotMetadataPath(machineID: machineID, snapshotID: snapshotID))
            || Self.pathEntryExists(snapshotRootfsPath(machineID: machineID, snapshotID: snapshotID))
            || Self.pathEntryExists(snapshotKernelPath(machineID: machineID, snapshotID: snapshotID))
            || Self.pathEntryExists(snapshotMachineIdentifierPath(machineID: machineID, snapshotID: snapshotID))
            || Self.pathEntryExists(snapshotNVRAMPath(machineID: machineID, snapshotID: snapshotID))
    }

    private func configurationAndRunningState(id: String) throws -> (DoryMachineConfiguration, Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = machines[id] else {
            throw MachineManagerError.unknownMachine(id)
        }
        try validateManagedMachineArtifacts(entry.configuration)
        // Process.isRunning can briefly read false at the spawn/termination callback boundary.
        // The supervisor lifecycle is authoritative: a running/starting entry with an active or
        // scheduled helper must be stopped and restarted for a configuration transaction.
        guard entry.state != .paused else {
            throw MachineManagerError.persistence(
                "machine \(id) must be resumed or stopped before this mutation"
            )
        }
        let active = [.starting, .running].contains(entry.state) && entry.process != nil
        return (entry.configuration, active)
    }

    private func configurationAndPowerState(
        id: String
    ) throws -> (DoryMachineConfiguration, DoryMachineState) {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = machines[id] else {
            throw MachineManagerError.unknownMachine(id)
        }
        try validateManagedMachineArtifacts(entry.configuration)
        return (entry.configuration, entry.state)
    }

    private func publishConfiguration(_ configuration: DoryMachineConfiguration) throws {
        let identity = runtimeIdentityForUnplannedMachine(reason: .definitionChanged)
        var identityPersistenceError: String?
        do {
            try persistRuntimeIdentity(identity, configuration: configuration)
        } catch {
            // machine.json is already the durable authority at every call site. Never leave the
            // in-memory configuration behind that commit; a missing/stale companion fails closed
            // to requires-replanning on the next restart.
            identityPersistenceError = "runtime identity publication requires recovery: \(error)"
        }
        lock.lock()
        defer { lock.unlock() }
        guard var entry = machines[configuration.id] else {
            throw MachineManagerError.unknownMachine(configuration.id)
        }
        entry.configuration = configuration
        entry.currentBalloonTargetMB = nil
        entry.runtimeIdentity = identity
        if let identityPersistenceError { entry.lastError = identityPersistenceError }
        machines[configuration.id] = entry
    }

    private func runtimeIdentityForUnplannedMachine(
        reason: DoryMachineRuntimeIdentityInvalidationReason = .planNotInstalled
    ) -> DoryMachineRuntimeIdentity {
        switch launchPolicy {
        case .legacyCompatibility:
            return .legacyCompatibility(
                virtualHardwareABIVersion:
                    DoryVirtualMachineDefinition.currentVirtualHardwareABIVersion
            )
        case .requireResolvedPlan, .perWorkspaceAuthority:
            return .requiresReplanning(
                virtualHardwareABIVersion:
                    DoryVirtualMachineDefinition.currentVirtualHardwareABIVersion,
                reason: reason
            )
        }
    }

    private func runtimeIdentityAfterSnapshotRestore(
        _ snapshotIdentity: DoryMachineRuntimeIdentity,
        sourceIdentity: DoryMachineRuntimeIdentity
    ) -> DoryMachineRuntimeIdentity {
        switch launchPolicy {
        case .legacyCompatibility:
            return .legacyCompatibility(
                virtualHardwareABIVersion: snapshotIdentity.virtualHardwareABIVersion
            )
        case .requireResolvedPlan:
            return .requiresReplanning(
                virtualHardwareABIVersion: snapshotIdentity.virtualHardwareABIVersion,
                reason: .restoredSnapshot
            )
        case .perWorkspaceAuthority:
            if sourceIdentity.mode == .legacyCompatibility,
               snapshotIdentity.mode == .legacyCompatibility {
                return .legacyCompatibility(
                    virtualHardwareABIVersion: snapshotIdentity.virtualHardwareABIVersion
                )
            }
            return .requiresReplanning(
                virtualHardwareABIVersion: snapshotIdentity.virtualHardwareABIVersion,
                reason: .restoredSnapshot
            )
        }
    }

    private func shouldRestartAfterSnapshotRestore(
        _ targetIdentity: DoryMachineRuntimeIdentity
    ) -> Bool {
        switch launchPolicy {
        case .legacyCompatibility:
            return true
        case .requireResolvedPlan:
            return false
        case .perWorkspaceAuthority:
            return targetIdentity.mode == .legacyCompatibility
        }
    }

    /// Reconstructs durable identity only when the persisted plan still binds the exact current
    /// authoritative definition. Missing, stale, or migration-only plans remain visibly blocked
    /// instead of being mislabeled as legacy compatibility after a daemon restart.
    private func recoverResolvedRuntimeIdentities(
        plans: any DoryResolvedMachinePlanStoring,
        expectedPlanRevision: ResolvedPlanRevisionProvider
    ) {
        let entries: [(String, DoryMachineConfiguration, DoryMachineRuntimeIdentity)] = {
            lock.lock()
            defer { lock.unlock() }
            return machines.map {
                ($0.key, $0.value.configuration, $0.value.runtimeIdentity)
            }
        }()
        for (id, machine, existingIdentity) in entries {
            if launchPolicy == .perWorkspaceAuthority {
                switch existingIdentity.mode {
                case .legacyCompatibility, .requiresReplanning:
                    // Only an acquired planning mutation fence may cross either authority
                    // boundary. An old definition-exact plan cannot cover a restored/imported or
                    // otherwise changed mutable disk.
                    continue
                case .resolvedPlan:
                    break
                }
            }
            var recovered = exactResolvedRuntimeIdentity(
                machine: machine,
                plans: plans,
                expectedPlanRevision: expectedPlanRevision
            ) ?? .requiresReplanning(
                virtualHardwareABIVersion:
                    existingIdentity.virtualHardwareABIVersion,
                reason: .planRecoveryFailed
            )
            if launchPolicy == .perWorkspaceAuthority,
               recovered != existingIdentity {
                recovered = .requiresReplanning(
                    virtualHardwareABIVersion: existingIdentity.virtualHardwareABIVersion,
                    reason: .planRecoveryFailed
                )
            }
            var persistenceError: String?
            var effectiveIdentity = recovered
            if launchPolicy == .perWorkspaceAuthority {
                do {
                    if recovered != existingIdentity {
                        try persistRuntimeIdentity(recovered, configuration: machine)
                    }
                }
                catch {
                    persistenceError = "runtime identity recovery could not be persisted: \(error)"
                    effectiveIdentity = .requiresReplanning(
                        virtualHardwareABIVersion: recovered.virtualHardwareABIVersion,
                        reason: .planRecoveryFailed
                    )
                }
            }
            lock.lock()
            if var entry = machines[id] {
                entry.runtimeIdentity = effectiveIdentity
                if let persistenceError { entry.lastError = persistenceError }
                machines[id] = entry
            }
            lock.unlock()
        }
    }

    private func exactResolvedRuntimeIdentity(
        machine: DoryMachineConfiguration,
        plans: any DoryResolvedMachinePlanStoring,
        expectedPlanRevision: ResolvedPlanRevisionProvider
    ) -> DoryMachineRuntimeIdentity? {
        guard let legacyData = Self.readPrivateMetadata(path: machineConfigPath(id: machine.id)),
              let definition = reconcileWorkspaceProjection(
                machine: machine,
                authoritativeLegacyData: legacyData
              ),
              let canonicalData = try? Self.canonicalDefinitionData(definition),
              let plan = try? plans.read(id: machine.id),
              expectedPlanRevision(machine.id) == plan.planRevision,
              plan.machineID == machine.id,
              plan.definitionRevision == definition.lifecycle.revision,
              plan.definitionSHA256 == Self.sha256(data: canonicalData),
              plan.migrationDisposition == .current,
              plan.validate().isEmpty else {
            return nil
        }
        return try? DoryMachineRuntimeIdentity(
            resolvedPlan: plan,
            planSHA256: DoryMachineRuntimeIdentity.planSHA256(plan)
        )
    }

    private func completePlanningRuntimeIdentity(machineID: String) throws {
        // Recovery completes planning before production activation installs the launch graph.
        // Both planning and start deliberately use the canonical manager state root, so reading
        // the exact durable plan here does not invent evidence or select a backend.
        let plans: any DoryResolvedMachinePlanStoring = resolvedLaunchPlanStore
            ?? DoryResolvedMachinePlanRepository(root: configuration.stateDirectory)
        let expectedPlanRevision: ResolvedPlanRevisionProvider =
            resolvedPlanRevisionProvider ?? { machineID in
                try? plans.read(id: machineID).planRevision
            }
        lock.lock()
        let machine = machines[machineID]?.configuration
        lock.unlock()
        guard let machine,
              let identity = exactResolvedRuntimeIdentity(
                machine: machine,
                plans: plans,
                expectedPlanRevision: expectedPlanRevision
              ) else {
            throw MachineManagerError.persistence(
                "published plan does not match current workspace authority"
            )
        }
        try persistRuntimeIdentity(identity, configuration: machine)
        lock.lock()
        guard var entry = machines[machineID], entry.configuration == machine else {
            lock.unlock()
            throw MachineManagerError.persistence(
                "machine authority changed while completing planning"
            )
        }
        entry.runtimeIdentity = identity
        entry.lastError = nil
        machines[machineID] = entry
        lock.unlock()
    }

    private func prepareMachineArtifacts(_ machine: DoryMachineConfiguration) throws -> DoryMachineConfiguration {
        let rootfsDestination = machineRootfsPath(id: machine.id)
        let kernelDestination = machineKernelPath(id: machine.id)
        let installerDestination = machineInstallerISOPath(id: machine.id)
        guard machine.rootfsPath != rootfsDestination, machine.kernelPath != kernelDestination,
              machine.installerISOPath != installerDestination else {
            throw MachineManagerError.persistence("machine artifacts must be imported into managed storage")
        }
        do {
            var copy = machine
            switch machine.bootMode {
            case .linuxKernel:
                try Self.cloneOrCopyFile(source: machine.rootfsPath, destination: rootfsDestination)
                try Self.cloneOrCopyFile(source: machine.kernelPath, destination: kernelDestination)
            case .efi:
                if Self.isRegularNonemptyFile(path: machine.rootfsPath) {
                    try Self.cloneOrCopyFile(source: machine.rootfsPath, destination: rootfsDestination)
                } else if let diskSizeBytes = machine.diskSizeBytes {
                    try Self.createPrivateSparseFile(path: rootfsDestination, sizeBytes: diskSizeBytes)
                } else {
                    throw MachineManagerError.persistence("EFI machine is missing its disk source or size")
                }
                if DoryInstalledLinuxBootBundle.isBundle(atPath: machine.kernelPath) {
                    // EFI snapshot clones carry this opaque, verified bundle in the existing
                    // kernel artifact, so acceleration survives the full machine lifecycle.
                    try Self.cloneOrCopyFile(source: machine.kernelPath, destination: kernelDestination)
                } else {
                    try Self.createPrivateFile(path: kernelDestination, contents: Data("DORY-EFI\n".utf8))
                }
                if let installerISOPath = machine.installerISOPath {
                    try Self.cloneOrCopyFile(source: installerISOPath, destination: installerDestination)
                    copy.installerISOPath = installerDestination
                }
            }
            copy.rootfsPath = rootfsDestination
            copy.kernelPath = kernelDestination
            copy.diskSizeBytes = nil
            return copy
        } catch {
            throw MachineManagerError.persistence("could not prepare artifacts for \(machine.id): \(error)")
        }
    }

    private func validateManagedMachineArtifacts(_ machine: DoryMachineConfiguration) throws {
        guard Self.isPrivateDirectory(path: machineStateDirectory(id: machine.id)) else {
            throw MachineManagerError.persistence("machine state directory failed managed-storage validation")
        }
        let expectedRootfsPath = machineRootfsPath(id: machine.id)
        let expectedKernelPath = machineKernelPath(id: machine.id)
        guard machine.rootfsPath == expectedRootfsPath,
              Self.isPrivateRegularFile(path: expectedRootfsPath) else {
            throw MachineManagerError.persistence("machine rootfs failed managed-storage validation")
        }
        guard machine.kernelPath == expectedKernelPath,
              Self.isPrivateRegularFile(path: expectedKernelPath) else {
            throw MachineManagerError.persistence("machine kernel failed managed-storage validation")
        }
        if let installerISOPath = machine.installerISOPath {
            let expectedInstallerISOPath = machineInstallerISOPath(id: machine.id)
            guard machine.bootMode == .efi,
                  installerISOPath == expectedInstallerISOPath,
                  Self.isPrivateRegularFile(path: expectedInstallerISOPath) else {
                throw MachineManagerError.persistence("machine installer ISO failed managed-storage validation")
            }
        }
    }

    private func restoreManagedArtifacts(
        machine: DoryMachineConfiguration,
        snapshot: DoryMachineSnapshot,
        operationID: UUID,
        commit: () throws -> Void
    ) throws {
        let directory = machineStateDirectory(id: machine.id)
        let token = operationID.uuidString.lowercased()
        let rootfsBackup = "\(directory)/.restore-\(token)-rootfs"
        let kernelBackup = "\(directory)/.restore-\(token)-kernel"
        let machineIdentifierBackup = "\(directory)/.restore-\(token)-machine-identifier"
        let nvramBackup = "\(directory)/.restore-\(token)-nvram"
        let configurationBackup = "\(directory)/.restore-\(token)-machine-json"
        var preserveBackupsForRecovery = false
        defer {
            if !preserveBackupsForRecovery {
                try? FileManager.default.removeItem(atPath: rootfsBackup)
                try? FileManager.default.removeItem(atPath: kernelBackup)
                try? FileManager.default.removeItem(atPath: machineIdentifierBackup)
                try? FileManager.default.removeItem(atPath: nvramBackup)
                try? FileManager.default.removeItem(atPath: configurationBackup)
            }
        }
        try Self.cloneOrCopyFile(source: machine.rootfsPath, destination: rootfsBackup)
        do {
            try Self.cloneOrCopyFile(source: machine.kernelPath, destination: kernelBackup)
        } catch {
            throw MachineManagerError.persistence("could not preserve live kernel before restore: \(error)")
        }
        do {
            try Self.cloneOrCopyFile(
                source: machineConfigPath(id: machine.id),
                destination: configurationBackup
            )
        } catch {
            throw MachineManagerError.persistence(
                "could not preserve machine metadata before restore: \(error)"
            )
        }
        let firmwareRestore: (identifier: String, nvram: String, snapshotIdentifier: String, snapshotNVRAM: String)?
        if snapshot.bootMode == .efi {
            let identifier = machineFirmwareIdentifierPath(id: machine.id)
            let nvram = machineFirmwareNVRAMPath(id: machine.id)
            guard let snapshotIdentifier = snapshot.machineIdentifierPath,
                  let snapshotNVRAM = snapshot.nvramPath,
                  Self.isPrivateRegularFile(path: identifier),
                  Self.isPrivateRegularFile(path: nvram) else {
                throw MachineManagerError.persistence("could not preserve live EFI firmware before restore")
            }
            do {
                try Self.cloneOrCopyFile(source: identifier, destination: machineIdentifierBackup)
                try Self.cloneOrCopyFile(source: nvram, destination: nvramBackup)
            } catch {
                throw MachineManagerError.persistence("could not preserve live EFI firmware before restore: \(error)")
            }
            firmwareRestore = (identifier, nvram, snapshotIdentifier, snapshotNVRAM)
        } else {
            firmwareRestore = nil
        }
#if DEBUG
        do {
            try injectLifecycleFault(.restoreAfterBackups)
        } catch {
            preserveBackupsForRecovery = true
            throw error
        }
#endif
        do {
            try Self.cloneOrCopyFile(
                source: snapshot.rootfsPath,
                destination: machine.rootfsPath,
                replaceExisting: true
            )
            try Self.cloneOrCopyFile(
                source: snapshot.kernelPath,
                destination: machine.kernelPath,
                replaceExisting: true
            )
            if let firmwareRestore {
                try Self.cloneOrCopyFile(
                    source: firmwareRestore.snapshotIdentifier,
                    destination: firmwareRestore.identifier,
                    replaceExisting: true
                )
                try Self.cloneOrCopyFile(
                    source: firmwareRestore.snapshotNVRAM,
                    destination: firmwareRestore.nvram,
                    replaceExisting: true
                )
            }
            guard Self.recoveredLiveArtifactsMatch(
                snapshot: snapshot,
                machineID: machine.id,
                configuration: configuration
            ) else {
                throw MachineManagerError.persistence(
                    "restored machine artifacts do not match bound snapshot evidence"
                )
            }
            try commit()
        } catch {
            var rollbackFailures: [String] = []
            do {
                try Self.cloneOrCopyFile(
                    source: rootfsBackup,
                    destination: machine.rootfsPath,
                    replaceExisting: true
                )
            } catch {
                rollbackFailures.append("rootfs rollback failed: \(error)")
            }
            do {
                try Self.cloneOrCopyFile(
                    source: kernelBackup,
                    destination: machine.kernelPath,
                    replaceExisting: true
                )
            } catch {
                rollbackFailures.append("kernel rollback failed: \(error)")
            }
            do {
                try Self.cloneOrCopyFile(
                    source: configurationBackup,
                    destination: machineConfigPath(id: machine.id),
                    replaceExisting: true
                )
            } catch {
                rollbackFailures.append("machine metadata rollback failed: \(error)")
            }
            if let firmwareRestore {
                do {
                    try Self.cloneOrCopyFile(
                        source: machineIdentifierBackup,
                        destination: firmwareRestore.identifier,
                        replaceExisting: true
                    )
                } catch {
                    rollbackFailures.append("machine identifier rollback failed: \(error)")
                }
                do {
                    try Self.cloneOrCopyFile(
                        source: nvramBackup,
                        destination: firmwareRestore.nvram,
                        replaceExisting: true
                    )
                } catch {
                    rollbackFailures.append("NVRAM rollback failed: \(error)")
                }
            }
            guard rollbackFailures.isEmpty else {
                throw MachineManagerError.persistence(
                    "could not restore machine artifacts: \(error); \(rollbackFailures.joined(separator: "; "))"
                )
            }
            throw error
        }
    }

    @discardableResult
    private func ensurePrivateSnapshotDirectory(machineID: String) throws -> String {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                atPath: configuration.stateDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw MachineManagerError.persistence("could not create machine state root: \(error)")
        }
        let machineDirectory = machineStateDirectory(id: machineID)
        if mkdir(machineDirectory, 0o700) != 0, errno != EEXIST {
            throw MachineManagerError.persistence(
                "could not create machine snapshot owner: \(String(cString: strerror(errno)))"
            )
        }
        guard Self.isPrivateDirectory(path: machineDirectory) else {
            throw MachineManagerError.persistence("machine snapshot owner is not a private directory")
        }
        let directory = snapshotDirectory(machineID: machineID)
        if mkdir(directory, 0o700) != 0, errno != EEXIST {
            throw MachineManagerError.persistence(
                "could not create machine snapshot directory: \(String(cString: strerror(errno)))"
            )
        }
        guard Self.isPrivateDirectory(path: directory) else {
            throw MachineManagerError.persistence("machine snapshot path is not a private directory")
        }
        return directory
    }

    private func removeEmptyImportedSnapshotNamespace(machineID: String) {
        lock.lock()
        let hasMachine = machines[machineID] != nil
        lock.unlock()
        guard !hasMachine else { return }
        let directory = snapshotDirectory(machineID: machineID)
        guard Self.isPrivateDirectory(path: directory),
              ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).isEmpty,
              rmdir(directory) == 0 else {
            return
        }
        let owner = machineStateDirectory(id: machineID)
        guard Self.isPrivateDirectory(path: owner),
              ((try? FileManager.default.contentsOfDirectory(atPath: owner)) ?? []).isEmpty else {
            return
        }
        _ = rmdir(owner)
    }

    private func persist(
        _ machine: DoryMachineConfiguration,
        reconcilesLegacyProjection: Bool = true
    ) throws {
        let fileManager = FileManager.default
        let directory = machineStateDirectory(id: machine.id)
        let temporaryPath = "\(directory)/\(Self.machineMetadataTemporaryPrefix)\(UUID().uuidString)"
        var authoritativeLegacyData: Data?
        do {
            try fileManager.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true
            )
            let data = try DoryMachineConfigurationMigrationBridge.encodeLegacy(machine)
            let path = machineConfigPath(id: machine.id)
            try Self.writeDurablePrivateData(data, toPath: temporaryPath)
            guard rename(temporaryPath, path) == 0 else {
                throw MachineManagerError.persistence(
                    "could not publish machine metadata: \(String(cString: strerror(errno)))"
                )
            }
            try Self.syncDirectory(path: directory)
            authoritativeLegacyData = data
        } catch let error as MachineManagerError {
            try? fileManager.removeItem(atPath: temporaryPath)
            throw error
        } catch {
            try? fileManager.removeItem(atPath: temporaryPath)
            throw MachineManagerError.persistence("\(error)")
        }
        // The rename above is the commit point. Projection is intentionally best-effort and
        // ordered afterwards: a v2 failure must never roll back or hide working legacy metadata.
        resolvedLaunchIdentities.removeValue(forKey: machine.id)
        if reconcilesLegacyProjection, let authoritativeLegacyData {
            _ = reconcileWorkspaceProjection(
                machine: machine,
                authoritativeLegacyData: authoritativeLegacyData
            )
        }
    }

    private func persistRuntimeIdentity(
        _ identity: DoryMachineRuntimeIdentity,
        configuration machine: DoryMachineConfiguration
    ) throws {
        guard identity.validate().isEmpty,
              let authoritativeLegacyData = Self.readPrivateMetadata(
                path: machineConfigPath(id: machine.id)
              ),
              let decoded = try? JSONDecoder().decode(
                DoryMachineConfiguration.self,
                from: authoritativeLegacyData
              ),
              decoded == machine else {
            throw MachineManagerError.persistence(
                "runtime identity does not match authoritative machine metadata"
            )
        }
        do {
            try runtimeIdentityStore.publish(
                identity,
                machineID: machine.id,
                authoritativeLegacyData: authoritativeLegacyData
            )
        } catch {
            throw MachineManagerError.persistence(
                "could not publish runtime identity for \(machine.id): \(error)"
            )
        }
    }

    private func reconcileLoadedWorkspaceProjections() {
        let configurations = machines.values.map(\.configuration)
            .sorted { $0.id < $1.id }
        for machine in configurations {
            guard let data = Self.readPrivateMetadata(path: machineConfigPath(id: machine.id)) else {
                setWorkspaceProjectionDiagnostic(
                    DoryWorkspaceProjectionDiagnostic(
                        state: .unavailable,
                        failureCode: .repositoryFailure,
                        message: "authoritative legacy metadata could not be reread"
                    ),
                    id: machine.id
                )
                continue
            }
            _ = reconcileWorkspaceProjection(machine: machine, authoritativeLegacyData: data)
        }
    }

    private func reconcileWorkspaceProjection(
        machine: DoryMachineConfiguration,
        authoritativeLegacyData: Data
    ) -> DoryVirtualMachineDefinition? {
        do {
            let authority = try workspaceAuthority(
                machine: machine,
                authoritativeLegacyData: authoritativeLegacyData
            )
            setWorkspaceProjectionDiagnostic(
                DoryWorkspaceProjectionDiagnostic(
                    state: authority.reconcileState == .unchanged
                        ? .current : .regenerated
                ),
                id: machine.id
            )
            return authority.definition
        } catch let error as DoryMachineConfigurationMigrationError {
            setWorkspaceProjectionDiagnostic(
                DoryWorkspaceProjectionDiagnostic(
                    state: .unavailable,
                    failureCode: .unsupportedLegacyConfiguration,
                    message: error.localizedDescription
                ),
                id: machine.id
            )
            return nil
        } catch let error as DoryWorkspaceRepositoryError {
            setWorkspaceProjectionDiagnostic(
                DoryWorkspaceProjectionDiagnostic(
                    state: .unavailable,
                    failureCode: .repositoryFailure,
                    message: error.description
                ),
                id: machine.id
            )
            return nil
        } catch {
            setWorkspaceProjectionDiagnostic(
                DoryWorkspaceProjectionDiagnostic(
                    state: .unavailable,
                    failureCode: .repositoryFailure,
                    message: String(describing: error)
                ),
                id: machine.id
            )
            return nil
        }
    }

    private func workspaceAuthority(
        machine: DoryMachineConfiguration,
        authoritativeLegacyData: Data
    ) throws -> MachineWorkspaceAuthority {
        let facts = try workspaceMigrationFacts(for: machine)
        var migration = try DoryMachineConfigurationMigrationBridge.migrate(
            machine,
            facts: facts
        )
        let factsData = try Self.workspaceMigrationAuthorityData(facts)
        let currentRecord: DoryWorkspaceRepositoryRecord?
        do {
            currentRecord = try workspaceRepository.readPersistedRecord(id: machine.id)
        } catch let error as DoryWorkspaceRepositoryError {
            if case .workspaceNotFound = error {
                currentRecord = nil
            } else {
                throw error
            }
        }

        let definition: DoryVirtualMachineDefinition
        let isNative: Bool
        let reconcileState: DoryWorkspaceLegacyProjectionReconcileState
        if let currentRecord,
           currentRecord.legacyConfigurationSHA256 == nil,
           currentRecord.legacyMigrationFactsSHA256 == nil {
            let nativeDefinition: DoryVirtualMachineDefinition
            if let migrated = try migrateNativeDirectKernelMediaIfNeeded(
                currentRecord.definition,
                compatibility: migration.definition
            ) {
                try workspaceRepository.replace(
                    migrated,
                    expectedRevision: currentRecord.definition.lifecycle.revision
                )
                nativeDefinition = migrated
                reconcileState = .published
            } else {
                nativeDefinition = currentRecord.definition
                reconcileState = .unchanged
            }
            guard Self.nativeDefinition(
                nativeDefinition,
                isCompatibleWith: migration.definition
            ) else {
                throw DoryWorkspaceRepositoryError.staleLegacyProjection(machine.id)
            }
            definition = nativeDefinition
            isNative = true
        } else {
            let result = try workspaceRepository.reconcileLegacyProjection(
                migration.definition,
                authoritativeLegacyData: authoritativeLegacyData,
                authoritativeMigrationFactsData: factsData
            )
            let persisted = try workspaceRepository.readLegacyProjection(
                id: machine.id,
                authoritativeLegacyData: authoritativeLegacyData,
                authoritativeMigrationFactsData: factsData
            )
            guard result.definition == persisted else {
                throw DoryWorkspaceRepositoryError.staleLegacyProjection(machine.id)
            }
            definition = persisted
            isNative = false
            reconcileState = result.state
        }
        migration.definition = definition
        return MachineWorkspaceAuthority(
            definition: definition,
            migration: migration,
            migrationFactsData: factsData,
            runtimeMachine: try migration.legacyConfiguration(),
            isNative: isNative,
            reconcileState: reconcileState
        )
    }

    /// Native records written before the raw direct-kernel media kind existed used the portable
    /// installed-bundle label for both shapes. The compatibility machine still proves which bytes
    /// are actually launched, so upgrade only that one exact alias and advance desired-state
    /// authority instead of continuing to misclassify a raw kernel at production trust time.
    private func migrateNativeDirectKernelMediaIfNeeded(
        _ definition: DoryVirtualMachineDefinition,
        compatibility: DoryVirtualMachineDefinition
    ) throws -> DoryVirtualMachineDefinition? {
        guard compatibility.boot.devices.count == 1,
              compatibility.boot.devices[0].kind == .linuxKernel,
              definition.boot.devices.count == 1,
              definition.boot.devices[0].kind == .installedLinuxBootBundle else {
            return nil
        }
        var legacyCompatibility = compatibility
        legacyCompatibility.boot.devices[0].kind = .installedLinuxBootBundle
        guard Self.nativeDefinition(
            definition,
            isCompatibleWith: legacyCompatibility
        ), definition.lifecycle.revision < UInt64.max,
           definition.lifecycle.updatedAtUnixMilliseconds < Int64.max else {
            return nil
        }
        var migrated = definition
        migrated.boot = compatibility.boot
        migrated.lifecycle = DoryVMLifecycleMetadata(
            revision: definition.lifecycle.revision + 1,
            createdAtUnixMilliseconds: definition.lifecycle.createdAtUnixMilliseconds,
            updatedAtUnixMilliseconds: definition.lifecycle.updatedAtUnixMilliseconds + 1
        )
        guard migrated.validate().isEmpty else {
            throw DoryWorkspaceRepositoryError.staleLegacyProjection(
                definition.identity.id
            )
        }
        return migrated
    }

    private static func nativeDefinition(
        _ definition: DoryVirtualMachineDefinition,
        isCompatibleWith compatibility: DoryVirtualMachineDefinition
    ) -> Bool {
        var expected = compatibility
        expected.lifecycle = definition.lifecycle
        expected.backendPreference = definition.backendPreference
        expected.graphics = definition.graphics
        expected.guestIdentityIntent = definition.guestIdentityIntent
        expected.clipboardPolicy = definition.clipboardPolicy
        return expected == definition && definition.validate().isEmpty
    }

    private static func canonicalDefinitionData(
        _ definition: DoryVirtualMachineDefinition
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(definition)
    }

    private func workspaceMigrationFacts(
        for machine: DoryMachineConfiguration
    ) throws -> DoryMachineConfigurationMigrationFacts {
        let architecture: DoryGuestArchitecture
        switch configuration.guestArchitecture.lowercased() {
        case "arm64", "aarch64":
            architecture = .arm64
        case "amd64", "x86_64":
            architecture = .x86_64
        default:
            throw DoryMachineConfigurationMigrationError.invalidLegacyConfiguration(
                "unsupported guest architecture \(configuration.guestArchitecture)"
            )
        }

        var diskInfo = stat()
        guard lstat(machine.rootfsPath, &diskInfo) == 0,
              (diskInfo.st_mode & S_IFMT) == S_IFREG,
              diskInfo.st_size > 0 else {
            throw DoryMachineConfigurationMigrationError.missingSystemDiskCapacity
        }
        let diskCapacity = UInt64(diskInfo.st_size)

        let installedEFIBoot: DoryMachineConfigurationInstalledEFIBoot?
        if machine.bootMode == .efi, machine.installerISOPath == nil {
            installedEFIBoot = DoryInstalledLinuxBootBundle.isBundle(atPath: machine.kernelPath)
                ? .installedLinuxBootBundle : .firmwareDisk
        } else {
            installedEFIBoot = nil
        }

        return DoryMachineConfigurationMigrationFacts(
            guestArchitecture: architecture,
            systemDiskCapacityBytes: diskCapacity,
            installedEFIBoot: installedEFIBoot,
            lifecycle: DoryVMLifecycleMetadata(
                revision: 1,
                createdAtUnixMilliseconds: workspaceCreationTimestamp(id: machine.id),
                updatedAtUnixMilliseconds: workspaceCreationTimestamp(id: machine.id)
            )
        )
    }

    private func workspaceCreationTimestamp(id: String) -> Int64 {
        var info = stat()
        guard lstat(machineStateDirectory(id: id), &info) == 0 else { return 1 }
        let time = info.st_birthtimespec.tv_sec > 0
            ? info.st_birthtimespec : info.st_ctimespec
        guard time.tv_sec > 0 else { return 1 }
        let seconds = Int64(time.tv_sec)
        let (milliseconds, overflow) = seconds.multipliedReportingOverflow(by: 1_000)
        guard !overflow else { return Int64.max }
        let nanos = max(Int64(0), Int64(time.tv_nsec)) / 1_000_000
        let (result, additionOverflow) = milliseconds.addingReportingOverflow(nanos)
        return additionOverflow ? Int64.max : max(1, result)
    }

    private static func workspaceMigrationAuthorityData(
        _ facts: DoryMachineConfigurationMigrationFacts
    ) throws -> Data {
        let authority = WorkspaceMigrationAuthorityFacts(
            guestArchitecture: facts.guestArchitecture,
            systemDiskCapacityBytes: facts.systemDiskCapacityBytes,
            installedEFIBoot: facts.installedEFIBoot,
            lifecycle: facts.lifecycle
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(authority)
    }

    private func setWorkspaceProjectionDiagnostic(
        _ diagnostic: DoryWorkspaceProjectionDiagnostic,
        id: String
    ) {
        lock.lock()
        workspaceProjectionDiagnostics[id] = diagnostic
        lock.unlock()
    }

    private func persistSnapshot(_ snapshot: DoryMachineSnapshot) throws {
        let fileManager = FileManager.default
        let directory = snapshotDirectory(machineID: snapshot.machineID)
        let temporaryPath = "\(directory)/\(Self.snapshotMetadataTemporaryPrefix)\(snapshot.id)-\(UUID().uuidString)"
        do {
            try Self.validateSnapshotRuntimeIdentity(snapshot)
            try Self.validateSnapshotArtifactEvidence(snapshot)
            guard Self.isPrivateDirectory(path: directory) else {
                throw MachineManagerError.persistence("machine snapshot path is not a private directory")
            }
            let data = try Self.snapshotDescriptorData(snapshot)
            let path = snapshotMetadataPath(machineID: snapshot.machineID, snapshotID: snapshot.id)
            try data.write(to: URL(fileURLWithPath: temporaryPath), options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryPath)
            guard link(temporaryPath, path) == 0 else {
                throw MachineManagerError.persistence(
                    "could not publish snapshot metadata: \(String(cString: strerror(errno)))"
                )
            }
            try? fileManager.removeItem(atPath: temporaryPath)
        } catch let error as MachineManagerError {
            try? fileManager.removeItem(atPath: temporaryPath)
            throw error
        } catch {
            try? fileManager.removeItem(atPath: temporaryPath)
            throw MachineManagerError.persistence("\(error)")
        }
    }

    private func loadSnapshot(machineID: String, snapshotID: String) throws -> DoryMachineSnapshot {
        guard Self.isValidID(machineID) else {
            throw MachineManagerError.invalidID(machineID)
        }
        guard Self.isValidID(snapshotID) else {
            throw MachineManagerError.invalidID(snapshotID)
        }
        let path = snapshotMetadataPath(machineID: machineID, snapshotID: snapshotID)
        let expectedRootfsPath = snapshotRootfsPath(machineID: machineID, snapshotID: snapshotID)
        let expectedKernelPath = snapshotKernelPath(machineID: machineID, snapshotID: snapshotID)
        let expectedMachineIdentifierPath = snapshotMachineIdentifierPath(machineID: machineID, snapshotID: snapshotID)
        let expectedNVRAMPath = snapshotNVRAMPath(machineID: machineID, snapshotID: snapshotID)
        guard Self.isPrivateDirectory(path: snapshotDirectory(machineID: machineID)),
              let data = Self.readPrivateMetadata(path: path),
              let snapshot = try? JSONDecoder().decode(DoryMachineSnapshot.self, from: data),
              snapshot.machineID == machineID,
              snapshot.id == snapshotID,
              snapshot.rootfsPath == expectedRootfsPath,
              snapshot.kernelPath == expectedKernelPath,
              snapshot.architecture == configuration.guestArchitecture,
              snapshot.runtimeIdentity.validate().isEmpty,
              (try? Self.validateResources(memoryMB: snapshot.memoryMB, cpuCount: snapshot.cpuCount)) != nil,
              Self.isPrivateRegularFile(path: expectedRootfsPath),
              Self.isPrivateRegularFile(path: expectedKernelPath) else {
            throw MachineManagerError.unknownSnapshot(snapshotID)
        }
        switch snapshot.bootMode {
        case .linuxKernel:
            guard snapshot.machineIdentifierPath == nil, snapshot.nvramPath == nil else {
                throw MachineManagerError.unknownSnapshot(snapshotID)
            }
        case .efi:
            guard snapshot.machineIdentifierPath == expectedMachineIdentifierPath,
                  snapshot.nvramPath == expectedNVRAMPath,
                  Self.isPrivateRegularFile(path: expectedMachineIdentifierPath),
                  Self.isPrivateRegularFile(path: expectedNVRAMPath) else {
                throw MachineManagerError.unknownSnapshot(snapshotID)
            }
        }
        try Self.validateSnapshotArtifactEvidence(snapshot)
        var validated = snapshot
        validated.sizeBytes = Self.fileSize(path: expectedRootfsPath)
        return validated
    }

    private static func snapshotDescriptorData(_ snapshot: DoryMachineSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }

    private static func snapshotEvidenceData(
        _ evidence: DoryMachineSnapshotArtifactEvidence
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(evidence)
    }

    private static func lifecycleSnapshotAuthority(
        _ snapshot: DoryMachineSnapshot
    ) throws -> DoryWorkspaceSnapshotAuthority {
        guard let evidence = snapshot.artifactEvidence, evidence.isValid else {
            throw MachineManagerError.persistence(
                "machine snapshot lacks immutable lifecycle artifact evidence"
            )
        }
        return DoryWorkspaceSnapshotAuthority(
            descriptorSHA256: sha256(data: try snapshotDescriptorData(snapshot)),
            artifactEvidenceSHA256: sha256(data: try snapshotEvidenceData(evidence))
        )
    }

    fileprivate static func validateSnapshotRuntimeIdentity(
        _ snapshot: DoryMachineSnapshot
    ) throws {
        guard snapshot.installedDesktopPayloadReceipt?.hasCoherentAuthority(
            environment: snapshot.environment
        ) ?? true else {
            throw MachineManagerError.persistence(
                "invalid installed desktop payload receipt"
            )
        }
        if let receipt = snapshot.installedDesktopPayloadReceipt,
           receipt.provenance == .verifiedUpdateBundle {
            guard let artifactEvidence = snapshot.artifactEvidence,
                  receipt.kernelSHA256 == artifactEvidence.kernel.sha256 else {
                throw MachineManagerError.persistence(
                    "installed desktop kernel receipt does not match snapshot evidence"
                )
            }
        }
        guard snapshot.runtimeIdentity.validate().isEmpty,
              snapshot.runtimeIdentity.virtualHardwareABIVersion
                == DoryVirtualMachineDefinition.currentVirtualHardwareABIVersion else {
            throw MachineManagerError.persistence("invalid machine snapshot runtime identity")
        }
        if snapshot.runtimeIdentity.mode == .resolvedPlan,
           snapshot.artifactEvidence == nil {
            throw MachineManagerError.persistence(
                "resolved machine snapshot is missing mutable artifact evidence"
            )
        }
        guard let plan = snapshot.runtimeIdentity.resolvedPlan else {
            return
        }
        let memoryBytes = snapshot.memoryMB.multipliedReportingOverflow(by: 1_048_576)
        guard let artifactEvidence = snapshot.artifactEvidence,
              snapshot.sizeBytes > 0,
              let snapshotSizeBytes = UInt64(exactly: snapshot.sizeBytes),
              !memoryBytes.overflow,
              plan.machineID == snapshot.machineID,
              plan.guest.architecture.rawValue == snapshot.architecture,
              plan.resourceAdmission?.admittedVirtualCPUCount == UInt64(snapshot.cpuCount),
              plan.resourceAdmission?.admittedMemoryBytes == memoryBytes.partialValue,
              plan.resourceAdmission?.admittedStorageBytes == snapshotSizeBytes,
              artifactEvidence.rootfs.byteCount == snapshotSizeBytes else {
            throw MachineManagerError.persistence(
                "machine snapshot resources do not match immutable runtime evidence"
            )
        }
    }

    private static func snapshotArtifactEvidence(
        rootfsPath: String,
        kernelPath: String,
        machineIdentifierPath: String?,
        nvramPath: String?
    ) throws -> DoryMachineSnapshotArtifactEvidence {
        DoryMachineSnapshotArtifactEvidence(
            rootfs: try snapshotArtifact(path: rootfsPath),
            kernel: try snapshotArtifact(path: kernelPath),
            machineIdentifier: try machineIdentifierPath.map(snapshotArtifact(path:)),
            nvram: try nvramPath.map(snapshotArtifact(path:))
        )
    }

    private static func snapshotArtifact(path: String) throws -> DoryMachineSnapshotArtifact {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw MachineManagerError.persistence("could not open machine snapshot artifact")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let byteCount = try handle.seekToEnd()
        guard byteCount > 0 else {
            throw MachineManagerError.persistence("machine snapshot artifact is empty")
        }
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return DoryMachineSnapshotArtifact(
            byteCount: byteCount,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    fileprivate static func validateSnapshotArtifactEvidence(
        _ snapshot: DoryMachineSnapshot
    ) throws {
        guard let expected = snapshot.artifactEvidence else {
            // Old legacy snapshots remain decodable and usable under the explicitly selected
            // compatibility policy. New snapshots always persist evidence.
            guard snapshot.runtimeIdentity.mode == .legacyCompatibility else {
                throw MachineManagerError.persistence(
                    "machine snapshot artifact evidence requires migration"
                )
            }
            return
        }
        guard expected.isValid,
              (snapshot.bootMode == .efi) == (expected.machineIdentifier != nil) else {
            throw MachineManagerError.persistence("invalid machine snapshot artifact evidence")
        }
        let actual = try snapshotArtifactEvidence(
            rootfsPath: snapshot.rootfsPath,
            kernelPath: snapshot.kernelPath,
            machineIdentifierPath: snapshot.machineIdentifierPath,
            nvramPath: snapshot.nvramPath
        )
        guard actual == expected else {
            throw MachineManagerError.persistence(
                "machine snapshot artifacts do not match immutable evidence"
            )
        }
    }

    private func validateSnapshotRuntimeCompatibility(
        _ snapshot: DoryMachineSnapshot,
        machine: DoryMachineConfiguration?,
        cloning: Bool
    ) throws {
        try Self.validateSnapshotRuntimeIdentity(snapshot)
        switch snapshot.runtimeIdentity.mode {
        case .legacyCompatibility:
            guard launchPolicy == .legacyCompatibility
                    || launchPolicy == .perWorkspaceAuthority else {
                throw MachineManagerError.persistence(
                    "legacy snapshot requires explicit legacy compatibility launch policy"
                )
            }
        case .resolvedPlan:
            guard !cloning || launchPolicy == .perWorkspaceAuthority else {
                throw MachineManagerError.persistence(
                    "resolved snapshot identity is machine-bound and must be replanned before cloning"
                )
            }
            if cloning, launchPolicy == .perWorkspaceAuthority { return }
            guard launchPolicy == .requireResolvedPlan
                    || launchPolicy == .perWorkspaceAuthority,
                  let plan = snapshot.runtimeIdentity.resolvedPlan,
                  let registry = resolvedLaunchRegistry,
                  let planStore = resolvedLaunchPlanStore,
                  let descriptor = registry.backend(for: plan.backend)?.descriptor,
                  descriptor.identity == plan.backend,
                  descriptor.implementationIdentifier == plan.backendImplementationIdentifier,
                  let machine,
                  machine.id == plan.machineID else {
                throw MachineManagerError.persistence(
                    "snapshot runtime is incompatible with installed resolved-launch infrastructure"
                )
            }
            let currentPlan: DoryResolvedMachinePlan
            do {
                currentPlan = try planStore.read(id: machine.id)
            } catch {
                throw MachineManagerError.persistence(
                    "snapshot resolved plan is unavailable: \(error)"
                )
            }
            guard currentPlan == plan,
                  snapshot.runtimeIdentity.resolvedPlanSHA256
                    == DoryMachineRuntimeIdentity.planSHA256(currentPlan) else {
                throw MachineManagerError.persistence(
                    "snapshot resolved plan no longer matches durable launch authority"
                )
            }
        case .requiresReplanning:
            guard (launchPolicy == .requireResolvedPlan && !cloning)
                    || launchPolicy == .perWorkspaceAuthority else {
                throw MachineManagerError.persistence(
                    "snapshot requires a new resolved plan before it can launch"
                )
            }
        }
    }

    private func handleHandoff(
        machineID: String,
        launchID: UUID,
        result: Result<VmmHandoff, Error>
    ) {
        var handoffServer: VmmHandoffServer?
        var processToStop: HvProcess?
        var agentSocketPath: String?
        var lifecycleReadinessSucceeded = false
        var admissionPlan: DoryResolvedMachinePlan?
        var requiresAdmissionCommit = false
        lock.lock()
        guard var entry = machines[machineID], entry.launchID == launchID else {
            lock.unlock()
            return
        }
        handoffServer = entry.handoffServer
        entry.handoffServer = nil
        admissionPlan = entry.activeResolvedPlan
        switch result {
        case let .success(handoff):
            guard handoff.ready.machineID == machineID else {
                entry.state = .failed
                entry.lastError = "handoff machine id mismatch: \(handoff.ready.machineID)"
                entry.launchID = nil
                entry.runtimeAddress = nil
                entry.activeResolvedPlan = nil
                processToStop = entry.process
                break
            }
            entry.handoff = handoff
            entry.lastError = nil
            requiresAdmissionCommit = admissionPlan != nil
                && productionResourceAdmissionLedger != nil
            if requiresAdmissionCommit {
                entry.state = .starting
            } else {
                entry.state = .running
                entry.process?.disableRestarts()
                agentSocketPath = handoff.ready.agentSocketPath
                lifecycleReadinessSucceeded = true
            }
        case let .failure(error):
            entry.state = .failed
            entry.lastError = "\(error)"
            entry.launchID = nil
            entry.runtimeAddress = nil
            entry.activeResolvedPlan = nil
            processToStop = entry.process
        }
        machines[machineID] = entry
        lock.unlock()

        handoffServer?.stop()
        processToStop?.stop()

        operationLock.lock()
        if requiresAdmissionCommit, let admissionPlan {
            do {
                try markResolvedAdmissionRunning(plan: admissionPlan)
                lock.lock()
                if var current = machines[machineID], current.launchID == launchID,
                   current.state == .starting {
                    current.state = .running
                    current.lastError = nil
                    current.process?.disableRestarts()
                    agentSocketPath = current.handoff?.ready.agentSocketPath
                    machines[machineID] = current
                    lifecycleReadinessSucceeded = true
                }
                lock.unlock()
                if lifecycleReadinessSucceeded {
                    completeActiveStartLifecycle(id: machineID)
                } else {
                    try markResolvedAdmissionStopped(plan: admissionPlan)
                    failActiveStartLifecycle(
                        id: machineID,
                        stepID: "start.readiness-state-changed"
                    )
                }
            } catch {
                lock.lock()
                if var current = machines[machineID], current.launchID == launchID {
                    processToStop = current.process
                    current.state = .failed
                    current.lastError = "resource admission rejected readiness: \(error)"
                    current.handoff = nil
                    current.launchID = nil
                    current.runtimeAddress = nil
                    current.activeResolvedPlan = nil
                    machines[machineID] = current
                }
                lock.unlock()
                try? markResolvedAdmissionStopped(plan: admissionPlan)
                failActiveStartLifecycle(id: machineID, stepID: "start.admission-failed")
            }
        } else if lifecycleReadinessSucceeded {
            completeActiveStartLifecycle(id: machineID)
        } else {
            try? markResolvedAdmissionStopped(plan: admissionPlan)
            failActiveStartLifecycle(id: machineID, stepID: "start.readiness-failed")
        }
        operationLock.unlock()

        processToStop?.stop()
        if let agentSocketPath {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.discoverRuntimeAddress(
                    machineID: machineID,
                    launchID: launchID,
                    agentSocketPath: agentSocketPath
                )
            }
        }
    }

    private func discoverRuntimeAddress(
        machineID: String,
        launchID: UUID,
        agentSocketPath: String
    ) {
        lock.lock()
        let mayExecute = machines[machineID].map { entry in
            entry.launchID == launchID
                && entry.state == .running
                && entry.handoff?.ready.agentSocketPath == agentSocketPath
                && entry.handoff?.ready.supportsAgentCapability("exec") == true
        } ?? false
        lock.unlock()
        guard mayExecute else { return }

        let address: String
        do {
            let client = try agentConnector(agentSocketPath)
            defer { client.close() }
            let result = try client.exec(
                argv: ["/sbin/ip", "-o", "-4", "addr", "show", "scope", "global"],
                cwd: "",
                env: [],
                timeoutMs: 5_000,
                outputLimitBytes: 16 * 1024
            )
            guard let discovered = Self.runtimeIPv4Address(from: result) else { return }
            address = discovered
        } catch {
            return
        }

        lock.lock()
        if var entry = machines[machineID],
           entry.launchID == launchID,
           entry.state == .running,
           entry.handoff?.ready.agentSocketPath == agentSocketPath,
           entry.process?.isRunning == true {
            entry.runtimeAddress = address
            machines[machineID] = entry
        }
        lock.unlock()
    }

    static func runtimeIPv4Address(from result: DoryExecResult) -> String? {
        guard result.exitCode == 0,
              !result.timedOut,
              !result.stdoutTruncated,
              let output = String(data: result.stdout, encoding: .utf8) else {
            return nil
        }
        let tokens = output.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for index in tokens.indices where tokens[index] == "inet" {
            let candidateIndex = tokens.index(after: index)
            guard candidateIndex < tokens.endIndex else { continue }
            let candidate = String(tokens[candidateIndex].split(separator: "/", maxSplits: 1)[0])
            guard let parsed = IPv4Address(candidate), parsed.bytes.count == 4 else { continue }
            let first = parsed.bytes[0]
            guard first != 0,
                  first != 127,
                  first < 224,
                  !(first == 169 && parsed.bytes[1] == 254) else {
                continue
            }
            return candidate
        }
        return nil
    }

    private static func isValidID(_ id: String) -> Bool {
        id.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/) != nil
    }

    private static func normalizedAddress(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard IPv4Address(trimmed) != nil else {
            throw MachineManagerError.invalidAddress(raw)
        }
        return trimmed
    }

    private static func validateShares(_ shares: [DoryMachineShareConfiguration]) throws {
        var tags = Set<String>()
        for share in shares {
            try share.validate()
            guard tags.insert(share.tag).inserted else {
                throw MachineManagerError.invalidShare(share.tag)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: share.hostPath, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw MachineManagerError.invalidShare(share.hostPath)
            }
        }
    }

    private static func validateEnvironment(_ environment: [String: String]) throws {
        for (key, value) in environment {
            guard isValidEnvironmentKey(key) else {
                throw MachineManagerError.invalidEnvironment(key)
            }
            guard !value.contains("\0") else {
                throw MachineManagerError.invalidEnvironment(key)
            }
        }
        do {
            _ = try DoryDesktopVMMPreference(environment: environment)
        } catch {
            throw MachineManagerError.invalidEnvironment(DoryDesktopVMMPreference.environmentKey)
        }
        do {
            _ = try DoryDesktopGraphicsPreference(environment: environment)
        } catch {
            throw MachineManagerError.invalidEnvironment(DoryDesktopGraphicsPreference.environmentKey)
        }
    }

    private static func validateLaunchConfiguration(_ machine: DoryMachineConfiguration) throws {
        try validateResources(memoryMB: machine.memoryMB, cpuCount: machine.cpuCount)
        if machine.bootMode == .efi, machine.displayMode != .desktop {
            throw MachineManagerError.persistence("EFI machines require desktop display mode")
        }
        if machine.bootMode == .linuxKernel, machine.installerISOPath != nil {
            throw MachineManagerError.persistence("installer ISO requires EFI boot mode")
        }
        let normalizedAddress = try normalizedAddress(machine.address)
        guard normalizedAddress == machine.address else {
            throw MachineManagerError.invalidAddress(machine.address ?? "")
        }
        try validateShares(machine.shares)
        try validateEnvironment(machine.environment)
        guard machine.installedDesktopPayloadReceipt?.hasCoherentAuthority(
            environment: machine.environment
        ) ?? true else {
            throw MachineManagerError.persistence(
                "installed desktop payload receipt is invalid"
            )
        }
    }

    /// A local legacy snapshot retains the original raw receipt fields byte-for-byte. Imported
    /// snapshots have no environment authority, so their typed receipt becomes authoritative.
    private static func configurationReceipt(
        restoring snapshot: DoryMachineSnapshot
    ) -> DoryInstalledDesktopPayloadReceipt? {
        guard let receipt = snapshot.installedDesktopPayloadReceipt else { return nil }
        return receipt.matchesLegacyEnvironment(snapshot.environment) ? nil : receipt
    }

    private static func validateResources(memoryMB: UInt64, cpuCount: Int) throws {
        guard (minimumMachineMemoryMB...maximumMachineMemoryMB).contains(memoryMB) else {
            throw MachineManagerError.persistence(
                "memoryMB must be between \(minimumMachineMemoryMB) and \(maximumMachineMemoryMB)"
            )
        }
        guard (minimumMachineCPUCount...maximumMachineCPUCount).contains(cpuCount) else {
            throw MachineManagerError.persistence(
                "cpuCount must be between \(minimumMachineCPUCount) and \(maximumMachineCPUCount)"
            )
        }
    }

    private static func isValidEnvironmentKey(_ key: String) -> Bool {
        key.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil
    }

    private static func generatedSnapshotID(prefix: String = "s") -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "Z", with: "z")
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "\(prefix)\(stamp)-\(token)"
    }

    private static func cloneOrCopyFile(
        source: String,
        destination: String,
        replaceExisting: Bool = false
    ) throws {
        let destinationURL = URL(fileURLWithPath: destination)
        let parent = destinationURL.deletingLastPathComponent()
        let parentDescriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parentDescriptor >= 0 else {
            throw MachineManagerError.persistence(
                "could not open managed artifact directory: \(String(cString: strerror(errno)))"
            )
        }
        defer { close(parentDescriptor) }
        var parentInfo = stat()
        guard fstat(parentDescriptor, &parentInfo) == 0,
              isPrivateDirectory(info: parentInfo) else {
            throw MachineManagerError.persistence("managed artifact directory is not private")
        }
        let destinationName = destinationURL.lastPathComponent
        let temporaryName = ".\(destinationName).tmp-\(UUID().uuidString)"
        _ = unlinkat(parentDescriptor, temporaryName, 0)
        let sourceDescriptor = open(source, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard sourceDescriptor >= 0 else {
            throw MachineManagerError.persistence(
                "could not open artifact source: \(String(cString: strerror(errno)))"
            )
        }
        defer { close(sourceDescriptor) }
        var sourceInfo = stat()
        guard fstat(sourceDescriptor, &sourceInfo) == 0,
              (sourceInfo.st_mode & S_IFMT) == S_IFREG,
              sourceInfo.st_size > 0 else {
            throw MachineManagerError.persistence("artifact source is not a nonempty regular file")
        }
        do {
            if fclonefileat(sourceDescriptor, parentDescriptor, temporaryName, 0) != 0 {
                _ = unlinkat(parentDescriptor, temporaryName, 0)
                let destinationDescriptor = openat(
                    parentDescriptor,
                    temporaryName,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                    mode_t(0o600)
                )
                guard destinationDescriptor >= 0 else {
                    throw MachineManagerError.persistence(
                        "could not create artifact copy: \(String(cString: strerror(errno)))"
                    )
                }
                defer { close(destinationDescriptor) }
                guard lseek(sourceDescriptor, 0, SEEK_SET) == 0,
                      fcopyfile(sourceDescriptor, destinationDescriptor, nil, copyfile_flags_t(COPYFILE_DATA)) == 0,
                      fchmod(destinationDescriptor, mode_t(0o600)) == 0,
                      isPrivateRegularFile(descriptor: destinationDescriptor),
                      fsync(destinationDescriptor) == 0 else {
                    throw MachineManagerError.persistence(
                        "could not copy artifact: \(String(cString: strerror(errno)))"
                    )
                }
            } else {
                let clonedDescriptor = openat(parentDescriptor, temporaryName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                guard clonedDescriptor >= 0 else {
                    throw MachineManagerError.persistence("could not reopen cloned artifact")
                }
                defer { close(clonedDescriptor) }
                guard fchmod(clonedDescriptor, mode_t(0o600)) == 0,
                      isPrivateRegularFile(descriptor: clonedDescriptor),
                      fsync(clonedDescriptor) == 0 else {
                    throw MachineManagerError.persistence(
                        "could not synchronize cloned artifact: \(String(cString: strerror(errno)))"
                    )
                }
            }
            if replaceExisting {
                guard renameat(parentDescriptor, temporaryName, parentDescriptor, destinationName) == 0 else {
                    throw MachineManagerError.persistence(
                        "could not replace \(destination): \(String(cString: strerror(errno)))"
                    )
                }
            } else {
                guard linkat(parentDescriptor, temporaryName, parentDescriptor, destinationName, 0) == 0 else {
                    throw MachineManagerError.persistence(
                        "could not publish \(destination): \(String(cString: strerror(errno)))"
                    )
                }
                guard unlinkat(parentDescriptor, temporaryName, 0) == 0 else {
                    _ = unlinkat(parentDescriptor, destinationName, 0)
                    throw MachineManagerError.persistence(
                        "could not finalize \(destination): \(String(cString: strerror(errno)))"
                    )
                }
            }
        } catch {
            _ = unlinkat(parentDescriptor, temporaryName, 0)
            throw error
        }
    }

    private static func createPrivateSparseFile(path: String, sizeBytes: UInt64) throws {
        guard sizeBytes <= UInt64(Int64.max) else {
            throw MachineManagerError.persistence("managed disk size is too large")
        }
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw MachineManagerError.persistence(
                "could not create managed disk: \(String(cString: strerror(errno)))"
            )
        }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(sizeBytes)) == 0,
              fsync(descriptor) == 0,
              isPrivateRegularFile(descriptor: descriptor) else {
            let code = errno
            _ = unlink(path)
            throw MachineManagerError.persistence(
                "could not size managed disk: \(String(cString: strerror(code)))"
            )
        }
    }

    private static func createPrivateFile(path: String, contents: Data) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw MachineManagerError.persistence(
                "could not create managed file: \(String(cString: strerror(errno)))"
            )
        }
        defer { close(descriptor) }
        let wrote = contents.withUnsafeBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return contents.isEmpty }
            var offset = 0
            while offset < buffer.count {
                let result = write(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                if result > 0 {
                    offset += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        guard wrote, fsync(descriptor) == 0, isPrivateRegularFile(descriptor: descriptor) else {
            let code = errno
            _ = unlink(path)
            throw MachineManagerError.persistence(
                "could not write managed file: \(String(cString: strerror(code)))"
            )
        }
    }

    private static func fileSize(path: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        if let number = attrs?[.size] as? NSNumber {
            return number.int64Value
        }
        return 0
    }

    private static func pathEntryExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func isPrivateRegularFile(path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && isPrivateRegularFile(info: info)
    }

    private static func isPrivateRegularFile(descriptor: Int32) -> Bool {
        var info = stat()
        return fstat(descriptor, &info) == 0 && isPrivateRegularFile(info: info)
    }

    private static func isPrivateRegularFile(info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG
            && info.st_uid == getuid()
            && info.st_nlink == 1
            && info.st_size > 0
            && (info.st_mode & 0o077) == 0
    }

    private static func readPrivateMetadata(path: String) -> Data? {
        let url = URL(fileURLWithPath: path)
        let parentDescriptor = open(
            url.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard parentDescriptor >= 0 else {
            return nil
        }
        defer { close(parentDescriptor) }
        var parentInfo = stat()
        guard fstat(parentDescriptor, &parentInfo) == 0,
              isPrivateDirectory(info: parentInfo) else {
            return nil
        }

        let descriptor = openat(
            parentDescriptor,
            url.lastPathComponent,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            return nil
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              isPrivateRegularFile(info: info),
              info.st_size <= maximumPersistedMetadataBytes else {
            return nil
        }

        var data = Data(count: Int(info.st_size))
        let readComplete = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else {
                return false
            }
            var offset = 0
            while offset < buffer.count {
                let result = read(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                if result > 0 {
                    offset += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        guard readComplete else {
            return nil
        }

        var extraByte: UInt8 = 0
        var extraResult: Int
        repeat {
            extraResult = read(descriptor, &extraByte, 1)
        } while extraResult < 0 && errno == EINTR
        guard extraResult == 0 else {
            return nil
        }
        return data
    }

    private static func isPrivateDirectory(path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && isPrivateDirectory(info: info)
    }

    /// Workspace records share MachineManager's state root. Tighten an existing owned directory
    /// without following links; failure merely leaves projection publishing unavailable.
    private static func restrictWorkspaceProjectionRootIfOwned(_ path: String) {
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid() else {
            return
        }
        _ = chmod(path, mode_t(0o700))
    }

    private static func isDirectory(path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func sha256(path: String) throws -> String {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw MachineManagerError.persistence("could not open desktop update bundle")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func syncDirectory(path: String) throws {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw MachineManagerError.persistence("could not open metadata directory for sync")
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw MachineManagerError.persistence("could not sync metadata directory")
        }
    }

    private static func writeDurablePrivateData(_ data: Data, toPath path: String) throws {
        let descriptor = open(
            path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw MachineManagerError.persistence("could not create durable private metadata")
        }
        var succeeded = false
        defer {
            close(descriptor)
            if !succeeded { _ = unlink(path) }
        }
        try data.withUnsafeBytes { raw in
            guard var address = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, address, remaining)
                if written > 0 {
                    remaining -= written
                    address = address.advanced(by: written)
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw MachineManagerError.persistence("could not write durable private metadata")
                }
            }
        }
        guard fsync(descriptor) == 0 else {
            throw MachineManagerError.persistence("could not sync durable private metadata")
        }
        succeeded = true
    }

    private static func isPrivateDirectory(info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == getuid()
            && (info.st_mode & 0o077) == 0
    }

    private static func isRegularNonemptyFile(path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFREG
            && info.st_size > 0
    }

    private static func loadPersistedMachines(
        configuration: MachineManagerConfiguration,
        launchPolicy: DoryMachineLaunchPolicy,
        runtimeIdentityStore: DoryMachineRuntimeIdentityStore
    ) -> [String: MachineEntry] {
        let root = configuration.stateDirectory
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            return [:]
        }
        let decoder = JSONDecoder()
        var loaded: [String: MachineEntry] = [:]
        for id in ids where isValidID(id) {
            let path = "\(root)/\(id)/machine.json"
            let rootfsPath = "\(root)/\(id)/rootfs.ext4"
            let kernelPath = "\(root)/\(id)/kernel"
            let installerISOPath = "\(root)/\(id)/installer.iso"
            guard let data = readPrivateMetadata(path: path),
                  let machine = try? decoder.decode(DoryMachineConfiguration.self, from: data),
                  machine.id == id,
                  isValidID(machine.id),
                  machine.installedDesktopPayloadReceipt?.hasCoherentAuthority(
                    environment: machine.environment
                  ) ?? true,
                  isPrivateDirectory(path: "\(root)/\(id)"),
                  machine.rootfsPath == rootfsPath,
                  machine.kernelPath == kernelPath,
                  isPrivateRegularFile(path: rootfsPath),
                  isPrivateRegularFile(path: kernelPath),
                  machine.installerISOPath == nil || (
                    machine.bootMode == .efi
                        && machine.installerISOPath == installerISOPath
                        && isPrivateRegularFile(path: installerISOPath)
                  ) else {
                continue
            }
            let identity: DoryMachineRuntimeIdentity = switch launchPolicy {
            case .legacyCompatibility:
                .legacyCompatibility(
                    virtualHardwareABIVersion:
                        DoryVirtualMachineDefinition.currentVirtualHardwareABIVersion
                )
            case .requireResolvedPlan:
                .requiresReplanning(
                    virtualHardwareABIVersion:
                        DoryVirtualMachineDefinition.currentVirtualHardwareABIVersion,
                    reason: .planRecoveryFailed
                )
            case .perWorkspaceAuthority:
                loadOrMigratePerWorkspaceRuntimeIdentity(
                    machine: machine,
                    authoritativeLegacyData: data,
                    store: runtimeIdentityStore
                )
            }
            loaded[id] = MachineEntry(
                configuration: machine,
                state: .stopped,
                runtimeIdentity: identity
            )
        }
        return loaded
    }

    private static func removeInterruptedNativeCreations(
        stateDirectory: String
    ) {
        guard let ids = try? FileManager.default.contentsOfDirectory(
            atPath: stateDirectory
        ) else { return }
        let allowed = Set([
            "rootfs.ext4",
            "kernel",
            "installer.iso",
            Self.nativeCreationPrecommitMarkerName,
            DoryMachineRuntimeIdentityStore.recordFileName,
            DoryMachineRuntimeIdentityStore.headFileName,
            DoryWorkspaceRepository.recordFileName,
        ])
        for id in ids where Self.isValidID(id) {
            let directory = stateDirectory + "/" + id
            let markerPath = directory + "/" + Self.nativeCreationPrecommitMarkerName
            guard Self.isPrivateDirectory(path: directory),
                  !Self.pathEntryExists(directory + "/machine.json"),
                  let entries = try? FileManager.default.contentsOfDirectory(
                    atPath: directory
                  ) else {
                continue
            }
            let expectedMarker = Self.nativeCreationPrecommitMarkerData(machineID: id)
            let isMarkerInitializationCrash = entries.isEmpty
                || (entries.count == 1
                    && entries[0] == Self.nativeCreationPrecommitMarkerName
                    && Self.isPrivatePartialNativeCreationMarker(
                        path: markerPath,
                        expectedByteCount: expectedMarker.count
                    ))
            let containsOnlyCreationEntries = entries.allSatisfy { entry in
                allowed.contains(entry)
                    || entry.hasPrefix(
                        DoryMachineRuntimeIdentityStore.recordTemporaryPrefix
                    )
                    || entry.hasPrefix(
                        DoryMachineRuntimeIdentityStore.headTemporaryPrefix
                    )
                    || entry.hasPrefix(DoryWorkspaceRepository.recordTemporaryPrefix)
            }
            let containsOnlyPrivateRuntimeTemporaries = entries.filter { entry in
                entry.hasPrefix(
                    DoryMachineRuntimeIdentityStore.recordTemporaryPrefix
                ) || entry.hasPrefix(
                    DoryMachineRuntimeIdentityStore.headTemporaryPrefix
                )
                    || entry.hasPrefix(DoryWorkspaceRepository.recordTemporaryPrefix)
            }.allSatisfy { entry in
                Self.isPrivateRegularFile(path: directory + "/" + entry)
            }
            let hasValidWorkspaceAuthority = !entries.contains(
                DoryWorkspaceRepository.recordFileName
            ) || Self.isPrivateRegularFile(
                path: directory + "/" + DoryWorkspaceRepository.recordFileName
            )
            let hasValidManagedArtifacts =
                (!entries.contains("rootfs.ext4")
                    || Self.isPrivateRegularFile(path: directory + "/rootfs.ext4"))
                && (!entries.contains("kernel")
                    || Self.isPrivateRegularFile(path: directory + "/kernel"))
                && (!entries.contains("installer.iso")
                    || Self.isPrivateRegularFile(path: directory + "/installer.iso"))
            let isAuthenticatedInterruptedCreation =
                Self.readPrivateMetadata(path: markerPath) == expectedMarker
                && containsOnlyCreationEntries
                && containsOnlyPrivateRuntimeTemporaries
                && hasValidManagedArtifacts
                && hasValidWorkspaceAuthority
            guard isMarkerInitializationCrash || isAuthenticatedInterruptedCreation else {
                continue
            }
            let quarantine = stateDirectory + "/"
                + Self.interruptedNativeCreationQuarantinePrefix
                + id + "-" + UUID().uuidString.lowercased()
            guard rename(directory, quarantine) == 0 else { continue }
            try? FileManager.default.removeItem(atPath: quarantine)
        }
    }

    private static func isPrivatePartialNativeCreationMarker(
        path: String,
        expectedByteCount: Int
    ) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFREG
            && info.st_uid == getuid()
            && info.st_nlink == 1
            && (info.st_mode & 0o077) == 0
            && info.st_size >= 0
            && info.st_size < Int64(expectedByteCount)
    }

    private static func recoverCompletedNativeCreationMarkers(
        stateDirectory: String,
        runtimeIdentityStore: DoryMachineRuntimeIdentityStore
    ) {
        guard let ids = try? FileManager.default.contentsOfDirectory(
            atPath: stateDirectory
        ) else { return }
        for id in ids where Self.isValidID(id) {
            let directory = stateDirectory + "/" + id
            let preparing = directory + "/" + Self.nativeCreationPrecommitMarkerName
            let committed = directory + "/" + Self.nativeCreationCommittedMarkerName
            guard Self.isPrivateDirectory(path: directory),
                  !Self.pathEntryExists(committed),
                  Self.readPrivateMetadata(path: preparing)
                    == Self.nativeCreationPrecommitMarkerData(machineID: id),
                  let legacyData = Self.readPrivateMetadata(
                    path: directory + "/machine.json"
                  ),
                  let machine = try? JSONDecoder().decode(
                    DoryMachineConfiguration.self,
                    from: legacyData
                  ), machine.id == id,
                  (try? runtimeIdentityStore.readIfPresent(
                    machineID: id,
                    authoritativeLegacyData: legacyData
                  )) != nil else {
                continue
            }
            guard rename(preparing, committed) == 0 else { continue }
            try? Self.syncDirectory(path: directory)
        }
    }

    private static func nativeCreationPrecommitMarkerData(machineID: String) -> Data {
        Data("DORY-NATIVE-CREATE-PRECOMMIT-V1:\(machineID)\n".utf8)
    }

    private static func loadOrMigratePerWorkspaceRuntimeIdentity(
        machine: DoryMachineConfiguration,
        authoritativeLegacyData: Data,
        store: DoryMachineRuntimeIdentityStore
    ) -> DoryMachineRuntimeIdentity {
        do {
            if let persisted = try store.readIfPresent(
                machineID: machine.id,
                authoritativeLegacyData: authoritativeLegacyData
            ) {
                return persisted
            }
            let machineDirectory = store.root + "/" + machine.id
            if Self.readPrivateMetadata(
                path: machineDirectory + "/" + Self.nativeCreationCommittedMarkerName
            ) == Self.nativeCreationPrecommitMarkerData(machineID: machine.id) {
                let unresolved = DoryMachineRuntimeIdentity.requiresReplanning(
                    virtualHardwareABIVersion:
                        DoryVirtualMachineDefinition.currentVirtualHardwareABIVersion,
                    reason: .planRecoveryFailed
                )
                try store.publish(
                    unresolved,
                    machineID: machine.id,
                    authoritativeLegacyData: authoritativeLegacyData
                )
                return unresolved
            }
            if Self.pathEntryExists(
                machineDirectory + "/" + DoryResolvedMachinePlanRepository.recordFileName
            ) || Self.pathEntryExists(
                machineDirectory + "/planning-transaction-v1.json"
            ) {
                let unresolved = DoryMachineRuntimeIdentity.requiresReplanning(
                    virtualHardwareABIVersion:
                        DoryVirtualMachineDefinition.currentVirtualHardwareABIVersion,
                    reason: .planRecoveryFailed
                )
                try store.publish(
                    unresolved,
                    machineID: machine.id,
                    authoritativeLegacyData: authoritativeLegacyData
                )
                return unresolved
            }
            // Absence is the one compatibility migration case: this exact machine predates the
            // per-workspace authority record. Persist the migration decision before allowing a
            // compatibility launch; malformed or stale records never receive this fallback.
            let migrated = DoryMachineRuntimeIdentity.legacyCompatibility(
                virtualHardwareABIVersion:
                    DoryVirtualMachineDefinition.currentVirtualHardwareABIVersion
            )
            try store.publish(
                migrated,
                machineID: machine.id,
                authoritativeLegacyData: authoritativeLegacyData
            )
            return migrated
        } catch {
            return .requiresReplanning(
                virtualHardwareABIVersion:
                    DoryVirtualMachineDefinition.currentVirtualHardwareABIVersion,
                reason: .planRecoveryFailed
            )
        }
    }

    private func currentRuntimeIdentity(id: String) throws -> DoryMachineRuntimeIdentity {
        lock.lock()
        guard let entry = machines[id] else {
            lock.unlock()
            throw MachineManagerError.unknownMachine(id)
        }
        let identity = entry.runtimeIdentity
        let machine = entry.configuration
        lock.unlock()
        guard identity.validate().isEmpty else {
            throw MachineManagerError.persistence("machine runtime identity is invalid")
        }
        if launchPolicy == .perWorkspaceAuthority {
            try revalidateDurableRuntimeIdentity(
                id: id,
                expected: identity,
                expectedMachine: machine
            )
        }
        return identity
    }

    private func currentDurableRuntimeIdentity(id: String) throws -> DoryMachineRuntimeIdentity {
        try currentRuntimeIdentity(id: id)
    }

    private func revalidateDurableRuntimeIdentity(
        id: String,
        expected: DoryMachineRuntimeIdentity,
        expectedMachine: DoryMachineConfiguration
    ) throws {
        guard expected.validate().isEmpty,
              let authoritativeLegacyData = Self.readPrivateMetadata(
                path: machineConfigPath(id: id)
              ),
              let decoded = try? JSONDecoder().decode(
                DoryMachineConfiguration.self,
                from: authoritativeLegacyData
              ), decoded == expectedMachine else {
            throw MachineManagerError.persistence(
                "durable machine authority changed before launch"
            )
        }
        let durable: DoryMachineRuntimeIdentity?
        do {
            durable = try runtimeIdentityStore.readIfPresent(
                machineID: id,
                authoritativeLegacyData: authoritativeLegacyData
            )
        } catch {
            throw MachineManagerError.persistence(
                "durable runtime identity is unavailable before launch: \(error)"
            )
        }
        guard durable == expected else {
            throw MachineManagerError.persistence(
                "durable runtime identity changed before launch"
            )
        }
    }

    /// Acquires the same per-workspace cross-process mutation lock used by lifecycle operations,
    /// then derives planning authority only from the exact persisted legacy bytes and migration
    /// facts observed under that lock. This path never starts a helper or mutates guest state.
    public func acquirePlanningMutationFence(
        machine: DoryMachineConfiguration,
        definition: DoryVirtualMachineDefinition,
        canonicalDefinitionData: Data
    ) throws -> DoryDaemonVirtualMachinePlanningMutationFence {
        operationLock.lock()
        defer { operationLock.unlock() }

        guard launchPolicy == .requireResolvedPlan
                || launchPolicy == .perWorkspaceAuthority else {
            throw MachineManagerError.persistence(
                "planning promotion requires the resolved-plan launch policy"
            )
        }
        guard Self.isValidID(machine.id), machine.id == definition.identity.id,
              canonicalDefinitionData == (try Self.canonicalDefinitionData(definition)) else {
            throw MachineManagerError.persistence("planning request identity is inconsistent")
        }
        guard activePlanningMutationIDs.insert(machine.id).inserted else {
            throw MachineManagerError.persistence(
                "machine \(machine.id) already has an active planning mutation"
            )
        }
        var shouldRemoveActiveID = true
        defer {
            if shouldRemoveActiveID { activePlanningMutationIDs.remove(machine.id) }
        }
        guard activeLifecycleOperations[machine.id] == nil else {
            throw MachineManagerError.persistence(
                "machine \(machine.id) already has an active lifecycle mutation"
            )
        }
        guard let store = lifecycleJournalStore else {
            throw MachineManagerError.persistence(
                "lifecycle journal is unavailable: "
                    + (lifecycleJournalInitializationError ?? "unknown error")
            )
        }

        let workspaceLock: EngineStateDirectoryLock
        do {
            workspaceLock = try EngineStateDirectoryLock(
                stateDirectory: store.root,
                lockFileName: ".mutation.\(machine.id).lock"
            )
        } catch {
            throw MachineManagerError.persistence(
                "machine \(machine.id) mutation authority is busy: \(error)"
            )
        }
        if let unfinished = try store.list().first(where: {
            $0.state.status != .completed && $0.state.status != .failed
                && ($0.plan.source.id == machine.id || $0.plan.target.id == machine.id)
        }) {
            throw MachineManagerError.persistence(
                "machine \(machine.id) lifecycle operation "
                    + unfinished.plan.id.uuidString.lowercased() + " requires recovery"
            )
        }

        let entry: MachineEntry
        lock.lock()
        guard let current = machines[machine.id],
              !deletingMachineIDs.contains(machine.id) else {
            lock.unlock()
            throw MachineManagerError.unknownMachine(machine.id)
        }
        entry = current
        lock.unlock()
        let authoritativeMachine = entry.configuration
        guard entry.process == nil, entry.handoffServer == nil,
              entry.state == .created || entry.state == .stopped else {
            throw MachineManagerError.persistence(
                "machine \(machine.id) must be exactly stopped before planning"
            )
        }
        guard entry.runtimeIdentity.validate().isEmpty,
              entry.runtimeIdentity.mode != .legacyCompatibility else {
            throw MachineManagerError.persistence(
                "machine \(machine.id) has no resolved-policy migration authority"
            )
        }

        guard let legacyData = Self.readPrivateMetadata(path: machineConfigPath(id: machine.id)),
              let decoded = try? JSONDecoder().decode(
                DoryMachineConfiguration.self,
                from: legacyData
              ), decoded == authoritativeMachine else {
            throw MachineManagerError.persistence(
                "authoritative machine metadata changed before planning"
            )
        }
        let workspace = try workspaceAuthority(
            machine: authoritativeMachine,
            authoritativeLegacyData: legacyData
        )
        guard workspace.runtimeMachine == machine,
              workspace.definition == definition,
              try Self.canonicalDefinitionData(workspace.definition)
                == canonicalDefinitionData else {
            throw MachineManagerError.persistence(
                "planning request does not match authoritative workspace state"
            )
        }

        let runtimeIdentityData = try Self.canonicalPlanningRuntimeAuthorityData(
            entry.runtimeIdentity
        )
        let authority = DoryDaemonVirtualMachinePlanningMachineAuthority(
            machineID: machine.id,
            legacyConfigurationSHA256: Self.sha256(data: legacyData),
            migrationFactsSHA256: Self.sha256(data: workspace.migrationFactsData),
            sourceDefinitionRevision: workspace.definition.lifecycle.revision,
            sourceDefinitionSHA256: Self.sha256(data: canonicalDefinitionData),
            runtimeIdentitySHA256: Self.sha256(data: runtimeIdentityData)
        )
        guard authority.isValid else {
            throw MachineManagerError.persistence("planning mutation authority is invalid")
        }

        let retention = MachineManagerPlanningMutationRetention(
            manager: self,
            machineID: machine.id,
            workspaceLock: workspaceLock
        )
        shouldRemoveActiveID = false
        return DoryDaemonVirtualMachinePlanningMutationFence(
            authority: authority,
            retainedAuthority: retention,
            validation: { [weak self] in
                guard let self else {
                    throw MachineManagerError.persistence("machine manager is unavailable")
                }
                try self.revalidatePlanningMutationAuthority(
                    authoritativeMachine: authoritativeMachine,
                    runtimeMachine: machine,
                    definition: definition,
                    canonicalDefinitionData: canonicalDefinitionData,
                    legacyData: legacyData,
                    migrationFactsData: workspace.migrationFactsData,
                    runtimeIdentitySHA256: authority.runtimeIdentitySHA256
                )
            },
            completion: { [weak self] in
                guard let self else {
                    throw MachineManagerError.persistence("machine manager is unavailable")
                }
                if self.launchPolicy == .perWorkspaceAuthority {
                    try self.completePlanningRuntimeIdentity(machineID: machine.id)
                }
                retention.release()
            },
            recoveryRelease: { retention.release() }
        )
    }

    private func revalidatePlanningMutationAuthority(
        authoritativeMachine: DoryMachineConfiguration,
        runtimeMachine: DoryMachineConfiguration,
        definition: DoryVirtualMachineDefinition,
        canonicalDefinitionData: Data,
        legacyData: Data,
        migrationFactsData: Data,
        runtimeIdentitySHA256: String
    ) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard activePlanningMutationIDs.contains(authoritativeMachine.id) else {
            throw MachineManagerError.persistence("planning mutation authority was released")
        }
        let entry: MachineEntry
        lock.lock()
        guard let current = machines[authoritativeMachine.id],
              !deletingMachineIDs.contains(authoritativeMachine.id) else {
            lock.unlock()
            throw MachineManagerError.unknownMachine(authoritativeMachine.id)
        }
        entry = current
        lock.unlock()
        guard entry.configuration == authoritativeMachine,
              entry.process == nil, entry.handoffServer == nil,
              entry.state == .created || entry.state == .stopped,
              entry.runtimeIdentity.validate().isEmpty,
              Self.sha256(
                data: try Self.canonicalPlanningRuntimeAuthorityData(entry.runtimeIdentity)
              )
                == runtimeIdentitySHA256,
              let currentLegacyData = Self.readPrivateMetadata(
                path: machineConfigPath(id: authoritativeMachine.id)
              ), currentLegacyData == legacyData,
              let decoded = try? JSONDecoder().decode(
                DoryMachineConfiguration.self,
                from: currentLegacyData
              ), decoded == authoritativeMachine else {
            throw MachineManagerError.persistence(
                "authoritative machine state changed during planning"
            )
        }
        let currentWorkspace = try workspaceAuthority(
            machine: authoritativeMachine,
            authoritativeLegacyData: currentLegacyData
        )
        guard currentWorkspace.migrationFactsData == migrationFactsData else {
            throw MachineManagerError.persistence(
                "authoritative migration facts changed during planning"
            )
        }
        guard currentWorkspace.runtimeMachine == runtimeMachine else {
            throw MachineManagerError.persistence(
                "authoritative machine projection changed during planning"
            )
        }
        guard currentWorkspace.definition == definition,
              try Self.canonicalDefinitionData(currentWorkspace.definition)
                == canonicalDefinitionData else {
            throw MachineManagerError.persistence(
                "authoritative workspace projection changed during planning"
            )
        }
    }

    private static func canonicalPlanningRuntimeAuthorityData(
        _ identity: DoryMachineRuntimeIdentity
    ) throws -> Data {
        let authority = MachinePlanningRuntimeAuthority(identity: identity)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(authority)
    }

    private func requireNoActivePlanningMutation(id: String) throws {
        guard !activePlanningMutationIDs.contains(id) else {
            throw MachineManagerError.persistence(
                "machine \(id) already has an active planning mutation"
            )
        }
    }

    private func acquireDirectWorkspaceMutationLock(
        id: String
    ) throws -> EngineStateDirectoryLock {
        guard let store = lifecycleJournalStore else {
            throw MachineManagerError.persistence(
                "lifecycle journal is unavailable: "
                    + (lifecycleJournalInitializationError ?? "unknown error")
            )
        }
        let workspaceLock: EngineStateDirectoryLock
        do {
            workspaceLock = try EngineStateDirectoryLock(
                stateDirectory: store.root,
                lockFileName: ".mutation.\(id).lock"
            )
        } catch {
            throw MachineManagerError.persistence(
                "machine \(id) mutation authority is busy: \(error)"
            )
        }
        if let unfinished = try store.list().first(where: {
            $0.state.status != .completed && $0.state.status != .failed
                && ($0.plan.source.id == id || $0.plan.target.id == id)
        }) {
            throw MachineManagerError.persistence(
                "machine \(id) lifecycle operation "
                    + unfinished.plan.id.uuidString.lowercased() + " requires recovery"
            )
        }
        return workspaceLock
    }

    private func retainDirectWorkspaceMutationLock(
        id: String
    ) throws -> MachineManagerDirectMutationRetention {
        if let existing = activeDirectWorkspaceMutationLocks[id] {
            existing.depth += 1
            return existing
        }
        // A handoff publishes the runtime state before its callback can acquire operationLock to
        // settle the readiness journal. If the very next user mutation wins that race, it owns
        // operationLock already and can deterministically finish the committed start itself
        // instead of rejecting a healthy running machine as an active lifecycle conflict.
        if activeLifecycleOperations[id]?.operation.kind == .starting {
            lock.lock()
            let readinessCommitted = machines[id]?.state == .running
            lock.unlock()
            if readinessCommitted { completeActiveStartLifecycle(id: id) }
        }
        guard activeLifecycleOperations[id] == nil else {
            throw MachineManagerError.persistence(
                "machine \(id) already has an active lifecycle mutation"
            )
        }
        let retention = MachineManagerDirectMutationRetention(
            workspaceLock: try acquireDirectWorkspaceMutationLock(id: id)
        )
        activeDirectWorkspaceMutationLocks[id] = retention
        return retention
    }

    private func releaseDirectWorkspaceMutationLock(
        id: String,
        retention: MachineManagerDirectMutationRetention
    ) {
        guard activeDirectWorkspaceMutationLocks[id] === retention,
              retention.depth > 0 else { return }
        retention.depth -= 1
        if retention.depth == 0 {
            activeDirectWorkspaceMutationLocks.removeValue(forKey: id)
        }
    }

    fileprivate func releasePlanningMutation(
        machineID: String,
        releaseWorkspaceLock: () -> Void
    ) {
        operationLock.lock()
        releaseWorkspaceLock()
        activePlanningMutationIDs.remove(machineID)
        operationLock.unlock()
    }

    private func lifecycleState(for state: DoryMachineState) -> DoryWorkspaceLifecycleState {
        switch state {
        case .starting, .running: .running
        case .paused: .paused
        case .created, .stopped: .stopped
        case .failed: .failed
        }
    }

    private func lifecycleCondition(
        machine: DoryMachineConfiguration,
        state: DoryWorkspaceLifecycleState,
        runtimeIdentity: DoryMachineRuntimeIdentity
    ) throws -> DoryWorkspaceLifecycleCondition {
        let legacyData: Data
        if let current = Self.readPrivateMetadata(path: machineConfigPath(id: machine.id)),
           let decoded = try? JSONDecoder().decode(DoryMachineConfiguration.self, from: current),
           decoded == machine {
            legacyData = current
        } else {
            legacyData = try DoryMachineConfigurationMigrationBridge.encodeLegacy(machine)
        }
        let facts = try workspaceMigrationFacts(for: machine)
        let definition = try DoryMachineConfigurationMigrationBridge.migrate(
            machine,
            facts: facts
        ).definition
        let definitionData = try Self.canonicalDefinitionData(definition)
        return DoryWorkspaceLifecycleCondition(
            workspaceID: machine.id,
            state: state,
            definitionRevision: definition.lifecycle.revision,
            runtime: try lifecycleRuntimeBinding(runtimeIdentity),
            configurationAuthority: DoryWorkspaceConfigurationAuthority(
                legacyConfigurationSHA256: Self.sha256(data: legacyData),
                canonicalDefinitionSHA256: Self.sha256(data: definitionData)
            )
        )
    }

    private func lifecycleRuntimeBinding(
        _ identity: DoryMachineRuntimeIdentity
    ) throws -> DoryWorkspaceRuntimeBinding {
        guard identity.validate().isEmpty else {
            throw MachineManagerError.persistence("machine runtime identity is invalid")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = Self.sha256(data: try encoder.encode(identity))
        switch identity.mode {
        case .legacyCompatibility:
            return .legacyCompatibility(
                virtualHardwareABIVersion: identity.virtualHardwareABIVersion,
                runtimeIdentityDigest: digest
            )
        case .requiresReplanning:
            return .requiresReplanning(
                virtualHardwareABIVersion: identity.virtualHardwareABIVersion,
                runtimeIdentityDigest: digest
            )
        case .resolvedPlan:
            guard let plan = identity.resolvedPlan,
                  let planDigest = identity.resolvedPlanSHA256 else {
                throw MachineManagerError.persistence("resolved runtime identity is incomplete")
            }
            return .resolvedPlan(
                DoryWorkspaceResolvedCondition(
                    planRevision: plan.planRevision,
                    planDigest: planDigest,
                    backendID: plan.backend.rawValue,
                    backendRuntimeBuildID: plan.backendRuntimeBuildIdentifier,
                    virtualHardwareABIVersion: plan.virtualHardwareABIVersion
                ),
                runtimeIdentityDigest: digest
            )
        }
    }

    private func beginLifecycleStart(
        machine: DoryMachineConfiguration,
        targetIdentity: DoryMachineRuntimeIdentity
    ) throws -> MachineLifecycleJournalContext {
        let sourceIdentity = try currentRuntimeIdentity(id: machine.id)
        return try beginLifecycleOperation(
            kind: .starting,
            source: lifecycleCondition(
                machine: machine,
                state: .stopped,
                runtimeIdentity: sourceIdentity
            ),
            target: lifecycleCondition(
                machine: machine,
                state: .running,
                runtimeIdentity: targetIdentity
            ),
            targetResourceID: nil,
            readiness: true
        )
    }

    private func beginLifecycleStartPreparation(
        id: String
    ) throws -> MachineLifecycleJournalContext {
        lock.lock()
        guard let entry = machines[id] else {
            lock.unlock()
            throw MachineManagerError.unknownMachine(id)
        }
        let machine = entry.configuration
        let runtimeIdentity = entry.runtimeIdentity
        lock.unlock()

        var condition = try lifecycleCondition(
            machine: machine,
            state: .stopped,
            runtimeIdentity: runtimeIdentity
        )
        // Boot-bundle and direct-boot materialization are derived from the unchanged authoritative
        // legacy configuration. Their projection facts may legitimately become more specific, so
        // this preparation boundary binds the exact raw authority and runtime identity while the
        // subsequent start journal binds the reconciled canonical definition.
        condition.configurationAuthority?.canonicalDefinitionSHA256 = nil
        return try beginLifecycleOperation(
            kind: .resolving,
            source: condition,
            target: condition,
            targetResourceID: nil,
            readiness: false
        )
    }

    private func beginLifecycleStop(
        machine: DoryMachineConfiguration,
        runtimeIdentity: DoryMachineRuntimeIdentity,
        sourceState: DoryWorkspaceLifecycleState
    ) throws -> MachineLifecycleJournalContext {
        try beginLifecycleOperation(
            kind: .stopping,
            source: lifecycleCondition(
                machine: machine,
                state: sourceState,
                runtimeIdentity: runtimeIdentity
            ),
            target: lifecycleCondition(
                machine: machine,
                state: .stopped,
                runtimeIdentity: runtimeIdentity
            ),
            targetResourceID: nil,
            readiness: false
        )
    }

    private func beginLifecyclePause(
        machine: DoryMachineConfiguration,
        runtimeIdentity: DoryMachineRuntimeIdentity
    ) throws -> MachineLifecycleJournalContext {
        try beginLifecycleOperation(
            kind: .pausing,
            source: lifecycleCondition(
                machine: machine,
                state: .running,
                runtimeIdentity: runtimeIdentity
            ),
            target: lifecycleCondition(
                machine: machine,
                state: .paused,
                runtimeIdentity: runtimeIdentity
            ),
            targetResourceID: nil,
            readiness: false
        )
    }

    private func beginLifecycleResume(
        machine: DoryMachineConfiguration,
        runtimeIdentity: DoryMachineRuntimeIdentity
    ) throws -> MachineLifecycleJournalContext {
        try beginLifecycleOperation(
            kind: .resuming,
            source: lifecycleCondition(
                machine: machine,
                state: .paused,
                runtimeIdentity: runtimeIdentity
            ),
            target: lifecycleCondition(
                machine: machine,
                state: .running,
                runtimeIdentity: runtimeIdentity
            ),
            targetResourceID: nil,
            readiness: true
        )
    }

    private func beginLifecycleSnapshot(
        machine: DoryMachineConfiguration,
        runtimeIdentity: DoryMachineRuntimeIdentity,
        sourceState: DoryWorkspaceLifecycleState,
        snapshotID: String,
        snapshotAuthority: DoryWorkspaceSnapshotAuthority
    ) throws -> MachineLifecycleJournalContext {
        let condition = try lifecycleCondition(
            machine: machine,
            state: sourceState,
            runtimeIdentity: runtimeIdentity
        )
        return try beginLifecycleOperation(
            kind: .snapshotting,
            source: condition,
            target: condition,
            targetResourceID: snapshotID,
            targetSnapshotAuthority: snapshotAuthority,
            readiness: false
        )
    }

    private func beginLifecycleRestore(
        sourceMachine: DoryMachineConfiguration,
        targetMachine: DoryMachineConfiguration,
        sourceIdentity: DoryMachineRuntimeIdentity,
        targetIdentity: DoryMachineRuntimeIdentity,
        sourceState: DoryWorkspaceLifecycleState,
        targetState: DoryWorkspaceLifecycleState,
        snapshotID: String,
        snapshotAuthority: DoryWorkspaceSnapshotAuthority
    ) throws -> MachineLifecycleJournalContext {
        try beginLifecycleOperation(
            kind: .restoring,
            source: lifecycleCondition(
                machine: sourceMachine,
                state: sourceState,
                runtimeIdentity: sourceIdentity
            ),
            target: lifecycleCondition(
                machine: targetMachine,
                state: targetState,
                runtimeIdentity: targetIdentity
            ),
            targetResourceID: snapshotID,
            targetSnapshotAuthority: snapshotAuthority,
            readiness: targetState == .running
        )
    }

    private func beginLifecycleDelete(
        machine: DoryMachineConfiguration,
        runtimeIdentity: DoryMachineRuntimeIdentity,
        sourceState: DoryWorkspaceLifecycleState
    ) throws -> MachineLifecycleJournalContext {
        try beginLifecycleOperation(
            kind: .deleting,
            source: lifecycleCondition(
                machine: machine,
                state: sourceState,
                runtimeIdentity: runtimeIdentity
            ),
            target: lifecycleCondition(
                machine: machine,
                state: .deleting,
                runtimeIdentity: runtimeIdentity
            ),
            targetResourceID: nil,
            readiness: false
        )
    }

    private func beginLifecycleOperation(
        kind: DoryWorkspaceMutationKind,
        source: DoryWorkspaceLifecycleCondition,
        target: DoryWorkspaceLifecycleCondition,
        targetResourceID: String?,
        targetSnapshotAuthority: DoryWorkspaceSnapshotAuthority? = nil,
        readiness: Bool
    ) throws -> MachineLifecycleJournalContext {
        let machineID = source.workspaceID
        if kind == .snapshotting || kind == .restoring {
            guard targetSnapshotAuthority != nil else {
                throw MachineManagerError.persistence(
                    "snapshot lifecycle operation is missing immutable artifact authority"
                )
            }
        }
        guard activeLifecycleOperations[machineID] == nil else {
            throw MachineManagerError.persistence(
                "machine \(machineID) already has an active lifecycle mutation"
            )
        }
        guard let store = lifecycleJournalStore else {
            throw MachineManagerError.persistence(
                "lifecycle journal is unavailable: \(lifecycleJournalInitializationError ?? "unknown error")"
            )
        }
        let now = Date()
        let created = Int64(max(0, (now.timeIntervalSince1970 * 1_000).rounded()))
        let deadlineDelta: Int64 = 15 * 60 * 1_000
        let deadline = created > Int64.max - deadlineDelta ? Int64.max : created + deadlineDelta
        let operation = DoryWorkspaceLifecycleOperation(
            kind: kind,
            source: source,
            target: target,
            targetResourceID: targetResourceID,
            targetSnapshotAuthority: targetSnapshotAuthority,
            createdAtUnixMilliseconds: created,
            deadlineUnixMilliseconds: deadline,
            steps: [
                .init(id: "quiesce", stage: .quiesce, deadlineOffsetMilliseconds: 60_000),
                .init(id: "stage", stage: .prepare, deadlineOffsetMilliseconds: 120_000),
                .init(id: "verify", stage: .mutate, deadlineOffsetMilliseconds: 300_000),
                .init(id: "publish", stage: .publish, deadlineOffsetMilliseconds: 600_000),
                .init(id: "validate", stage: readiness ? .readiness : .cleanup,
                      deadlineOffsetMilliseconds: 840_000),
            ],
            readinessGates: readiness
                ? [.init(kind: .backendRunning, deadlineOffsetMilliseconds: 840_000)] : [],
            retryBudgets: [],
            cancellationPolicy: kind == .deleting ? .prohibited : .rollbackRequired,
            recovery: .init(disposition: .rollback, stepIDs: ["stage", "publish"])
        )
        let dependency = MachineLifecycleDependencyAuthority(
            mutationKind: kind.rawValue,
            workspaceID: machineID,
            sourceLegacyConfigurationSHA256:
                source.configurationAuthority?.legacyConfigurationSHA256,
            sourceDefinitionSHA256: source.configurationAuthority?.canonicalDefinitionSHA256,
            sourceRuntimeIdentitySHA256: source.runtime?.runtimeIdentityDigest,
            targetLegacyConfigurationSHA256:
                target.configurationAuthority?.legacyConfigurationSHA256,
            targetDefinitionSHA256: target.configurationAuthority?.canonicalDefinitionSHA256,
            targetRuntimeIdentitySHA256: target.runtime?.runtimeIdentityDigest,
            targetResourceID: targetResourceID,
            targetSnapshotDescriptorSHA256:
                targetSnapshotAuthority?.descriptorSHA256,
            targetSnapshotArtifactEvidenceSHA256:
                targetSnapshotAuthority?.artifactEvidenceSHA256
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let binding = try operation.journalBinding(
            dependencyClosureDigest: Self.sha256(data: try encoder.encode(dependency))
        )
        let lease: DoryOperationLease
        if let retained = activeDirectWorkspaceMutationLocks[machineID] {
            lease = try store.begin(
                binding,
                holdingMutationLock: retained.workspaceLock
            )
        } else {
            lease = try store.begin(binding)
        }
        let context = MachineLifecycleJournalContext(operation: operation, lease: lease)
        activeLifecycleOperations[machineID] = context
        return context
    }

    private func advanceLifecycleToPublishing(
        _ context: MachineLifecycleJournalContext
    ) throws {
        for phase in [
            DoryOperationPhase.quiescing,
            .staging,
            .verifying,
            .readyToPublish,
            .publishing,
        ] {
            let current = try context.lease.read().state
            if current.phase.indexForMachineLifecycle >= phase.indexForMachineLifecycle { continue }
            _ = try context.lease.transition(
                to: phase,
                status: .running,
                expectedRevision: current.revision,
                stepID: "lifecycle.\(phase.rawValue)"
            )
        }
    }

    private func completeLifecycle(_ context: MachineLifecycleJournalContext) throws {
        var current = try context.lease.read().state
        if current.phase.indexForMachineLifecycle < DoryOperationPhase.validating.indexForMachineLifecycle {
            current = try context.lease.transition(
                to: .validating,
                status: .running,
                expectedRevision: current.revision,
                stepID: "lifecycle.validated"
            )
        }
#if DEBUG
        // Persist the post-commit boundary before exercising the terminal journal write. Recovery
        // can then distinguish a committed target from a pre-commit interruption even when the
        // source and target machine.json bytes happen to be identical.
        try injectLifecycleFault(.completionBeforeJournalWrite(context.operation.kind))
#endif
        if current.phase.indexForMachineLifecycle < DoryOperationPhase.completed.indexForMachineLifecycle {
            _ = try context.lease.transition(
                to: .completed,
                status: .completed,
                expectedRevision: current.revision,
                stepID: "lifecycle.completed"
            )
        }
        activeLifecycleOperations.removeValue(forKey: context.operation.source.workspaceID)
        context.releaseLease()
    }

    @discardableResult
    private func completeCommittedLifecycle(
        _ context: MachineLifecycleJournalContext,
        diagnostic: String
    ) -> Bool {
        do {
            try completeLifecycle(context)
            return true
        } catch {
            // The target side effect is already durable. Preserve the journal's last valid,
            // nonterminal state so restart recovery can verify and finish it; claiming rollback
            // or terminal failure here would contradict the machine/snapshot authority on disk.
            activeLifecycleOperations.removeValue(forKey: context.operation.source.workspaceID)
            context.releaseLease()
            lock.lock()
            if machines[context.operation.source.workspaceID] != nil {
                machines[context.operation.source.workspaceID]?.lastError =
                    "\(diagnostic): \(error)"
            }
            lock.unlock()
            return false
        }
    }

    private func failLifecycle(
        _ context: MachineLifecycleJournalContext,
        stepID: String,
        rolledBack: Bool = false
    ) {
        defer {
            activeLifecycleOperations.removeValue(forKey: context.operation.source.workspaceID)
            context.releaseLease()
        }
        guard var current = try? context.lease.read().state,
              current.status != .failed, current.status != .completed else { return }
        if rolledBack,
           let rollingBack = try? context.lease.transition(
               to: current.phase,
               status: .rollingBack,
               expectedRevision: current.revision,
               stepID: "lifecycle.rolling-back",
               recoveryAction: "rollback"
           ) {
            current = rollingBack
        }
        _ = try? context.lease.transition(
            to: current.phase,
            status: .failed,
            expectedRevision: current.revision,
            stepID: stepID,
            recoveryAction: rolledBack ? "rollback" : nil
        )
    }

    private func completeActiveStartLifecycle(id: String) {
        guard let context = activeLifecycleOperations[id], context.operation.kind == .starting else {
            return
        }
        _ = completeCommittedLifecycle(
            context,
            diagnostic: "running machine has an unfinished readiness journal"
        )
    }

    private func failActiveStartLifecycle(id: String, stepID: String) {
        guard let context = activeLifecycleOperations[id], context.operation.kind == .starting else {
            return
        }
        failLifecycle(context, stepID: stepID)
    }

    private func cancelActiveStartLifecycleIfNeeded(id: String, reason: String) throws {
        guard let context = activeLifecycleOperations[id] else { return }
        guard context.operation.kind == .starting else {
            throw MachineManagerError.persistence(
                "machine \(id) already has an active lifecycle mutation"
            )
        }
        failLifecycle(context, stepID: reason)
    }

    private func lifecycleDeletionQuarantinePath(
        machineID: String,
        operationID: UUID
    ) -> String {
        Self.lifecycleDeletionQuarantinePath(
            configuration: configuration,
            machineID: machineID,
            operationID: operationID
        )
    }

    private static func lifecycleDeletionQuarantinePath(
        configuration: MachineManagerConfiguration,
        machineID: String,
        operationID: UUID
    ) -> String {
        "\(configuration.stateDirectory)/\(deletionQuarantinePrefix)\(machineID)-"
            + operationID.uuidString.lowercased()
    }

#if DEBUG
    func installLifecycleFaultInjectorForTesting(
        _ injector: @escaping @Sendable (MachineLifecycleFaultPoint) throws -> Void
    ) {
        operationLock.lock()
        lifecycleFaultInjector = injector
        operationLock.unlock()
    }

    private func injectLifecycleFault(_ point: MachineLifecycleFaultPoint) throws {
        try lifecycleFaultInjector?(point)
    }
#endif

    private static func recoverInterruptedLifecycleOperations(
        store: DoryOperationJournalStore?,
        configuration: MachineManagerConfiguration
    ) -> [String: String] {
        guard let store, let records = try? store.list() else { return [:] }
        var diagnostics: [String: String] = [:]
        for record in records where record.state.status != .completed
            && record.state.status != .failed {
            var lease: DoryOperationLease?
            do {
                guard Self.isValidID(record.plan.source.id) else { continue }
                lease = try store.acquire(record.plan.id)
                guard let lease else { continue }
                let operation = try lease.readWorkspaceLifecycleOperation()
                guard operation.source.workspaceID == record.plan.source.id,
                      operation.target.workspaceID == record.plan.source.id else {
                    throw MachineManagerError.persistence(
                        "lifecycle journal mutation scope changed during recovery"
                    )
                }
                let id = operation.source.workspaceID
                let recoveryState = try lease.read().state
                switch operation.kind {
                case .resolving:
                    if lifecycleConfigurationMatches(
                        operation.target.configurationAuthority,
                        machineID: id,
                        configuration: configuration
                    ) {
                        try completeRecoveredLifecycle(lease)
                        diagnostics[id] =
                            "interrupted start preparation was recovered; machine remains stopped"
                    } else {
                        try failRecoveredLifecycle(lease, rolledBack: false)
                        diagnostics[id] =
                            "interrupted start preparation authority changed; recovery failed closed"
                    }
                case .starting:
                    try failRecoveredLifecycle(lease, rolledBack: true)
                    diagnostics[id] = "interrupted start was recovered as stopped"
                case .stopping:
                    if lifecycleConfigurationMatches(
                        operation.target.configurationAuthority,
                        machineID: id,
                        configuration: configuration
                    ) {
                        try completeRecoveredLifecycle(lease)
                        diagnostics[id] = "interrupted stop completed during daemon recovery"
                    } else {
                        try failRecoveredLifecycle(lease, rolledBack: false)
                        diagnostics[id] = "interrupted stop authority changed; recovery failed closed"
                    }
                case .snapshotting:
                    if recoveryState.phase.indexForMachineLifecycle
                        >= DoryOperationPhase.validating.indexForMachineLifecycle,
                       recoveredSnapshot(
                           machineID: id,
                           operation: operation,
                           configuration: configuration
                       ) != nil,
                       lifecycleConfigurationMatches(
                           operation.target.configurationAuthority,
                           machineID: id,
                           configuration: configuration
                       ) {
                        try completeRecoveredLifecycle(lease)
                        diagnostics[id] =
                            "published snapshot journal completed during daemon recovery"
                    } else {
                        if let snapshotID = operation.targetResourceID {
                            removeRecoveredSnapshot(
                                machineID: id,
                                snapshotID: snapshotID,
                                configuration: configuration
                            )
                        }
                        try failRecoveredLifecycle(lease, rolledBack: true)
                        diagnostics[id] = "interrupted snapshot was rolled back"
                    }
                case .restoring:
                    if recoveryState.phase.indexForMachineLifecycle
                        >= DoryOperationPhase.validating.indexForMachineLifecycle {
                        if let snapshot = recoveredSnapshot(
                            machineID: id,
                            operation: operation,
                            configuration: configuration
                        ), lifecycleConfigurationMatches(
                                operation.target.configurationAuthority,
                                machineID: id,
                                configuration: configuration
                           ), recoveredLiveArtifactsMatch(
                                snapshot: snapshot,
                                machineID: id,
                                configuration: configuration
                           ) {
                            try completeRecoveredLifecycle(lease)
                            diagnostics[id] =
                                "interrupted snapshot restore completed before daemon restart"
                        } else {
                            try failRecoveredLifecycle(lease, rolledBack: false)
                            diagnostics[id] = "committed snapshot restore authority requires repair"
                        }
                    } else {
                        let restored = restoreRecoveredMachineBackups(
                            machineID: id,
                            operationID: operation.operationID,
                            configuration: configuration
                        )
                        if restored || lifecycleConfigurationMatches(
                            operation.source.configurationAuthority,
                            machineID: id,
                            configuration: configuration
                        ) {
                            try failRecoveredLifecycle(lease, rolledBack: true)
                            diagnostics[id] = "interrupted snapshot restore was rolled back"
                        } else if lifecycleConfigurationMatches(
                            operation.target.configurationAuthority,
                            machineID: id,
                            configuration: configuration
                        ) {
                            try completeRecoveredLifecycle(lease)
                            diagnostics[id] =
                                "interrupted snapshot restore completed before daemon restart"
                        } else {
                            try failRecoveredLifecycle(lease, rolledBack: false)
                            diagnostics[id] = "interrupted snapshot restore requires repair"
                        }
                    }
                case .deleting:
                    let state = "\(configuration.stateDirectory)/\(id)"
                    let quarantine = lifecycleDeletionQuarantinePath(
                        configuration: configuration,
                        machineID: id,
                        operationID: operation.operationID
                    )
                    if pathEntryExists(quarantine), !pathEntryExists(state) {
                        guard rename(quarantine, state) == 0 else {
                            throw MachineManagerError.persistence(
                                "could not roll back interrupted machine deletion"
                            )
                        }
                        try failRecoveredLifecycle(lease, rolledBack: true)
                        diagnostics[id] = "interrupted deletion was rolled back"
                    } else if !pathEntryExists(quarantine), !pathEntryExists(state) {
                        try completeRecoveredLifecycle(lease)
                    } else {
                        try failRecoveredLifecycle(lease, rolledBack: false)
                        diagnostics[id] = "interrupted deletion preserved existing machine data"
                    }
                case .pausing:
                    try failRecoveredLifecycle(lease, rolledBack: false)
                    diagnostics[id] =
                        "interrupted pause was recovered as stopped after helper cleanup"
                case .resuming:
                    try failRecoveredLifecycle(lease, rolledBack: false)
                    diagnostics[id] =
                        "interrupted resume was recovered as stopped after helper cleanup"
                case .importing, .provisioning, .suspending, .cloning, .updating, .repairing:
                    try failRecoveredLifecycle(lease, rolledBack: false)
                    diagnostics[id] = "unsupported interrupted lifecycle mutation requires repair"
                }
            } catch {
                if let id = try? lease?.readWorkspaceLifecycleOperation().source.workspaceID {
                    diagnostics[id] = "lifecycle recovery failed closed: \(error)"
                }
            }
            lease = nil
        }
        return diagnostics
    }

    private static func lifecycleConfigurationMatches(
        _ authority: DoryWorkspaceConfigurationAuthority?,
        machineID: String,
        configuration: MachineManagerConfiguration
    ) -> Bool {
        guard let expected = authority?.legacyConfigurationSHA256,
              let data = readPrivateMetadata(
                  path: "\(configuration.stateDirectory)/\(machineID)/machine.json"
              ) else { return false }
        return sha256(data: data) == expected
    }

    private static func completeRecoveredLifecycle(_ lease: DoryOperationLease) throws {
        var current = try lease.read().state
        if current.status != .running {
            current = try lease.transition(
                to: current.phase,
                status: .running,
                expectedRevision: current.revision,
                stepID: "recovery.resumed"
            )
        }
        for phase in DoryOperationPhase.allCases
            where phase.indexForMachineLifecycle > current.phase.indexForMachineLifecycle {
            current = try lease.transition(
                to: phase,
                status: phase == .completed ? .completed : .running,
                expectedRevision: current.revision,
                stepID: phase == .completed ? "recovery.completed" : "recovery.\(phase.rawValue)"
            )
        }
    }

    private static func failRecoveredLifecycle(
        _ lease: DoryOperationLease,
        rolledBack: Bool
    ) throws {
        var current = try lease.read().state
        if rolledBack, current.status != .rollingBack {
            current = try lease.transition(
                to: current.phase,
                status: .rollingBack,
                expectedRevision: current.revision,
                stepID: "recovery.rolling-back",
                recoveryAction: "rollback"
            )
        }
        _ = try lease.transition(
            to: current.phase,
            status: .failed,
            expectedRevision: current.revision,
            stepID: "recovery.failed",
            recoveryAction: rolledBack ? "rollback" : nil
        )
    }

    private static func removeRecoveredSnapshot(
        machineID: String,
        snapshotID: String,
        configuration: MachineManagerConfiguration
    ) {
        let directory = "\(configuration.stateDirectory)/\(machineID)/snapshots"
        for suffix in ["json", "ext4", "kernel", "machine-identifier", "nvram"] {
            try? FileManager.default.removeItem(
                atPath: "\(directory)/\(snapshotID).\(suffix)"
            )
        }
    }

    private static func recoveredSnapshot(
        machineID: String,
        operation: DoryWorkspaceLifecycleOperation,
        configuration: MachineManagerConfiguration
    ) -> DoryMachineSnapshot? {
        guard let snapshotID = operation.targetResourceID,
              let authority = operation.targetSnapshotAuthority,
              isValidID(machineID), isValidID(snapshotID) else { return nil }
        let directory = "\(configuration.stateDirectory)/\(machineID)/snapshots"
        let metadataPath = "\(directory)/\(snapshotID).json"
        let rootfsPath = "\(directory)/\(snapshotID).ext4"
        let kernelPath = "\(directory)/\(snapshotID).kernel"
        let machineIdentifierPath = "\(directory)/\(snapshotID).machine-identifier"
        let nvramPath = "\(directory)/\(snapshotID).nvram"
        guard isPrivateDirectory(path: directory),
              let metadata = readPrivateMetadata(path: metadataPath),
              sha256(data: metadata) == authority.descriptorSHA256,
              let snapshot = try? JSONDecoder().decode(DoryMachineSnapshot.self, from: metadata),
              snapshot.id == snapshotID,
              snapshot.machineID == machineID,
              snapshot.rootfsPath == rootfsPath,
              snapshot.kernelPath == kernelPath,
              snapshot.architecture == configuration.guestArchitecture,
              snapshot.sizeBytes > 0,
              snapshot.runtimeIdentity.validate().isEmpty,
              (try? validateResources(
                  memoryMB: snapshot.memoryMB,
                  cpuCount: snapshot.cpuCount
              )) != nil,
              let evidence = snapshot.artifactEvidence,
              evidence.isValid,
              (try? snapshotEvidenceData(evidence)).map(sha256(data:))
                == authority.artifactEvidenceSHA256,
              isPrivateRegularFile(path: rootfsPath),
              isPrivateRegularFile(path: kernelPath) else { return nil }
        switch snapshot.bootMode {
        case .linuxKernel:
            guard snapshot.machineIdentifierPath == nil,
                  snapshot.nvramPath == nil else { return nil }
        case .efi:
            guard snapshot.machineIdentifierPath == machineIdentifierPath,
                  snapshot.nvramPath == nvramPath,
                  isPrivateRegularFile(path: machineIdentifierPath),
                  isPrivateRegularFile(path: nvramPath) else { return nil }
        }
        guard (try? validateSnapshotRuntimeIdentity(snapshot)) != nil,
              (try? validateSnapshotArtifactEvidence(snapshot)) != nil else { return nil }
        return snapshot
    }

    private static func recoveredLiveArtifactsMatch(
        snapshot: DoryMachineSnapshot,
        machineID: String,
        configuration: MachineManagerConfiguration
    ) -> Bool {
        guard let expected = snapshot.artifactEvidence else { return false }
        let directory = "\(configuration.stateDirectory)/\(machineID)"
        let rootfsPath = "\(directory)/rootfs.ext4"
        let kernelPath = "\(directory)/kernel"
        let machineIdentifierPath = snapshot.bootMode == .efi
            ? "\(directory)/MachineIdentifier" : nil
        let nvramPath = snapshot.bootMode == .efi ? "\(directory)/NVRAM" : nil
        guard isPrivateDirectory(path: directory),
              isPrivateRegularFile(path: rootfsPath),
              isPrivateRegularFile(path: kernelPath),
              machineIdentifierPath.map(isPrivateRegularFile(path:)) ?? true,
              nvramPath.map(isPrivateRegularFile(path:)) ?? true,
              let actual = try? snapshotArtifactEvidence(
                  rootfsPath: rootfsPath,
                  kernelPath: kernelPath,
                  machineIdentifierPath: machineIdentifierPath,
                  nvramPath: nvramPath
              ) else { return false }
        return actual == expected
    }

    private static func restoreRecoveredMachineBackups(
        machineID: String,
        operationID: UUID,
        configuration: MachineManagerConfiguration
    ) -> Bool {
        let directory = "\(configuration.stateDirectory)/\(machineID)"
        let token = operationID.uuidString.lowercased()
        let pairs = [
            (".restore-\(token)-rootfs", "rootfs.ext4"),
            (".restore-\(token)-kernel", "kernel"),
            (".restore-\(token)-machine-json", "machine.json"),
            (".restore-\(token)-machine-identifier", "MachineIdentifier"),
            (".restore-\(token)-nvram", "NVRAM"),
        ]
        let required = Array(pairs.prefix(3))
        guard required.allSatisfy({ pathEntryExists("\(directory)/\($0.0)") }) else {
            return false
        }
        do {
            for (backup, destination) in pairs where pathEntryExists("\(directory)/\(backup)") {
                try cloneOrCopyFile(
                    source: "\(directory)/\(backup)",
                    destination: "\(directory)/\(destination)",
                    replaceExisting: true
                )
            }
            for (backup, _) in pairs {
                try? FileManager.default.removeItem(atPath: "\(directory)/\(backup)")
            }
            return true
        } catch {
            return false
        }
    }

    private static func removeStaleDeletionQuarantines(stateDirectory: String) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: stateDirectory) else {
            return
        }
        for entry in entries where entry.hasPrefix(deletionQuarantinePrefix) {
            try? fileManager.removeItem(atPath: "\(stateDirectory)/\(entry)")
        }
    }

    private static func removeStaleMachineMetadataArtifacts(stateDirectory: String) {
        let fileManager = FileManager.default
        guard let machineIDs = try? fileManager.contentsOfDirectory(atPath: stateDirectory) else {
            return
        }
        for machineID in machineIDs where isValidID(machineID) {
            let directory = "\(stateDirectory)/\(machineID)"
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else {
                continue
            }
            for entry in entries where entry.hasPrefix(machineMetadataTemporaryPrefix)
                || entry.hasPrefix(machineDiskTemporaryPrefix)
                || entry.hasPrefix(machineKernelTemporaryPrefix)
                || entry.hasPrefix(desktopUpdateStagingPrefix)
                || (entry.hasPrefix(".") && entry.contains(machineRestoreBackupMarker)) {
                try? fileManager.removeItem(atPath: "\(directory)/\(entry)")
            }
        }
    }

    private static func removeStaleSnapshotArtifacts(stateDirectory: String) {
        let fileManager = FileManager.default
        guard let machineIDs = try? fileManager.contentsOfDirectory(atPath: stateDirectory) else {
            return
        }
        for machineID in machineIDs where isValidID(machineID) {
            let directory = "\(stateDirectory)/\(machineID)/snapshots"
            guard isPrivateDirectory(path: directory) else {
                continue
            }
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else {
                continue
            }
            for entry in entries where entry.hasPrefix(snapshotDeletionQuarantinePrefix)
                || entry.hasPrefix(snapshotMetadataTemporaryPrefix)
                || (entry.hasPrefix(".") && (
                    entry.contains(snapshotDiskTemporaryMarker)
                        || entry.contains(snapshotKernelTemporaryMarker)
                        || entry.contains(snapshotMachineIdentifierTemporaryMarker)
                        || entry.contains(snapshotNVRAMTemporaryMarker)
                )) {
                try? fileManager.removeItem(atPath: "\(directory)/\(entry)")
            }
        }
    }

    deinit {
        stopAll()
    }
}

private enum MachineSnapshotBundle {
    private struct Header {
        var snapshot: DoryMachineSnapshot
        var rootfsOffset: UInt64
        var rootfsLength: UInt64
        var rootfsDigest: Data
        var kernelOffset: UInt64
        var kernelLength: UInt64
        var kernelDigest: Data
        var machineIdentifierOffset: UInt64?
        var machineIdentifierLength: UInt64?
        var machineIdentifierDigest: Data?
        var nvramOffset: UInt64?
        var nvramLength: UInt64?
        var nvramDigest: Data?
        var contentID: Data
    }

    private static let v3Magic = Data("DORYMACHINE3\n".utf8)
    private static let v4Magic = Data("DORYMACHINE4\n".utf8)
    private static let lengthByteCount = 8
    private static let digestByteCount = 32
    private static let maximumMetadataLength: UInt64 = 16 * 1024 * 1024
    private static let copyChunkSize = 4 * 1024 * 1024

    static func write(snapshot: DoryMachineSnapshot, toPath path: String) throws {
        try MachineManager.validateSnapshotRuntimeIdentity(snapshot)
        try MachineManager.validateSnapshotArtifactEvidence(snapshot)
        let rootfs = try openRegularFileForReading(path: snapshot.rootfsPath, requirePrivateOwnership: true)
        defer { try? rootfs.close() }
        let kernel = try openRegularFileForReading(path: snapshot.kernelPath, requirePrivateOwnership: true)
        defer { try? kernel.close() }
        let machineIdentifier: FileHandle?
        let nvram: FileHandle?
        if snapshot.bootMode == .efi {
            guard let machineIdentifierPath = snapshot.machineIdentifierPath,
                  let nvramPath = snapshot.nvramPath else {
                throw MachineManagerError.persistence("EFI snapshot is missing firmware state")
            }
            machineIdentifier = try openRegularFileForReading(
                path: machineIdentifierPath,
                requirePrivateOwnership: true
            )
            nvram = try openRegularFileForReading(path: nvramPath, requirePrivateOwnership: true)
        } else {
            machineIdentifier = nil
            nvram = nil
        }
        defer {
            try? machineIdentifier?.close()
            try? nvram?.close()
        }
        let rootfsLength = try rootfs.seekToEnd()
        let kernelLength = try kernel.seekToEnd()
        let machineIdentifierLength = try machineIdentifier?.seekToEnd()
        let nvramLength = try nvram?.seekToEnd()
        guard rootfsLength > 0, rootfsLength <= UInt64(Int64.max) else {
            throw MachineManagerError.persistence("invalid machine snapshot rootfs size")
        }
        guard kernelLength > 0, kernelLength <= UInt64(Int64.max) else {
            throw MachineManagerError.persistence("invalid machine snapshot kernel size")
        }
        if snapshot.bootMode == .efi {
            guard let machineIdentifierLength, machineIdentifierLength > 0,
                  let nvramLength, nvramLength > 0 else {
                throw MachineManagerError.persistence("invalid EFI snapshot firmware size")
            }
        }
        try rootfs.seek(toOffset: 0)
        try kernel.seek(toOffset: 0)
        try machineIdentifier?.seek(toOffset: 0)
        try nvram?.seek(toOffset: 0)

        var exportedSnapshot = snapshot
        exportedSnapshot.rootfsPath = ""
        exportedSnapshot.kernelPath = ""
        exportedSnapshot.machineIdentifierPath = nil
        exportedSnapshot.nvramPath = nil
        exportedSnapshot.address = nil
        exportedSnapshot.shares = []
        exportedSnapshot.environment = [:]
        exportedSnapshot.sizeBytes = Int64(rootfsLength)
        let metadata = try JSONEncoder().encode(exportedSnapshot)
        guard !metadata.isEmpty, UInt64(metadata.count) <= maximumMetadataLength else {
            throw MachineManagerError.persistence("invalid dory machine bundle metadata")
        }
        let metadataDigest = Data(SHA256.hash(data: metadata))

        let outputURL = URL(fileURLWithPath: path)
        let parent = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryURL = parent.appendingPathComponent(".\(outputURL.lastPathComponent).tmp-\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw MachineManagerError.persistence("could not create temporary machine bundle")
        }
        let output = try FileHandle(forWritingTo: temporaryURL)
        var outputIsOpen = true
        defer {
            if outputIsOpen {
                try? output.close()
            }
        }
        do {
            let includesFirmware = snapshot.bootMode == .efi
            try output.write(contentsOf: includesFirmware ? v4Magic : v3Magic)
            try output.write(contentsOf: bigEndianBytes(UInt64(metadata.count)))
            try output.write(contentsOf: bigEndianBytes(rootfsLength))
            try output.write(contentsOf: bigEndianBytes(kernelLength))
            if includesFirmware {
                try output.write(contentsOf: bigEndianBytes(machineIdentifierLength!))
                try output.write(contentsOf: bigEndianBytes(nvramLength!))
            }
            try output.write(contentsOf: metadataDigest)
            let rootfsDigestOffset = try output.offset()
            try output.write(contentsOf: Data(repeating: 0, count: digestByteCount))
            let kernelDigestOffset = try output.offset()
            try output.write(contentsOf: Data(repeating: 0, count: digestByteCount))
            let machineIdentifierDigestOffset: UInt64?
            let nvramDigestOffset: UInt64?
            if includesFirmware {
                machineIdentifierDigestOffset = try output.offset()
                try output.write(contentsOf: Data(repeating: 0, count: digestByteCount))
                nvramDigestOffset = try output.offset()
                try output.write(contentsOf: Data(repeating: 0, count: digestByteCount))
            } else {
                machineIdentifierDigestOffset = nil
                nvramDigestOffset = nil
            }
            try output.write(contentsOf: metadata)
            let rootfsDigest = try copyExactly(
                from: rootfs,
                to: output,
                byteCount: rootfsLength,
                rejectTrailingInput: true
            )
            let kernelDigest = try copyExactly(
                from: kernel,
                to: output,
                byteCount: kernelLength,
                rejectTrailingInput: true
            )
            let machineIdentifierDigest: Data?
            let nvramDigest: Data?
            if let machineIdentifier, let machineIdentifierLength, let nvram, let nvramLength {
                machineIdentifierDigest = try copyExactly(
                    from: machineIdentifier,
                    to: output,
                    byteCount: machineIdentifierLength,
                    rejectTrailingInput: true
                )
                nvramDigest = try copyExactly(
                    from: nvram,
                    to: output,
                    byteCount: nvramLength,
                    rejectTrailingInput: true
                )
            } else {
                machineIdentifierDigest = nil
                nvramDigest = nil
            }
            try output.seek(toOffset: rootfsDigestOffset)
            try output.write(contentsOf: rootfsDigest)
            try output.seek(toOffset: kernelDigestOffset)
            try output.write(contentsOf: kernelDigest)
            if let machineIdentifierDigestOffset, let machineIdentifierDigest,
               let nvramDigestOffset, let nvramDigest {
                try output.seek(toOffset: machineIdentifierDigestOffset)
                try output.write(contentsOf: machineIdentifierDigest)
                try output.seek(toOffset: nvramDigestOffset)
                try output.write(contentsOf: nvramDigest)
            }
            try output.synchronize()
            try output.close()
            outputIsOpen = false
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporaryURL.path
            )
            guard rename(temporaryURL.path, outputURL.path) == 0 else {
                throw MachineManagerError.persistence(
                    "could not publish machine bundle: \(String(cString: strerror(errno)))"
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    static func readDescriptor(fromPath path: String) throws -> (snapshot: DoryMachineSnapshot, contentID: Data) {
        let input = try openRegularFileForReading(path: path)
        defer { try? input.close() }
        let header = try readHeader(from: input)
        return (header.snapshot, header.contentID)
    }

    static func extractArtifacts(
        fromPath path: String,
        expectedContentID: Data,
        rootfsPath: String,
        kernelPath: String,
        machineIdentifierPath: String?,
        nvramPath: String?
    ) throws {
        let input = try openRegularFileForReading(path: path)
        var inputIsOpen = true
        defer {
            if inputIsOpen {
                try? input.close()
            }
        }
        let header = try readHeader(from: input)
        guard header.contentID == expectedContentID else {
            throw MachineManagerError.persistence("machine bundle changed during import")
        }
        var artifacts: [(offset: UInt64, length: UInt64, digest: Data, destination: URL)] = [
            (header.rootfsOffset, header.rootfsLength, header.rootfsDigest, URL(fileURLWithPath: rootfsPath)),
            (header.kernelOffset, header.kernelLength, header.kernelDigest, URL(fileURLWithPath: kernelPath)),
        ]
        if let offset = header.machineIdentifierOffset,
           let length = header.machineIdentifierLength,
           let digest = header.machineIdentifierDigest,
           let nvramOffset = header.nvramOffset,
           let nvramLength = header.nvramLength,
           let nvramDigest = header.nvramDigest,
           let machineIdentifierPath,
           let nvramPath {
            artifacts.append((offset, length, digest, URL(fileURLWithPath: machineIdentifierPath)))
            artifacts.append((nvramOffset, nvramLength, nvramDigest, URL(fileURLWithPath: nvramPath)))
        } else if header.machineIdentifierOffset != nil
            || machineIdentifierPath != nil
            || nvramPath != nil {
            throw MachineManagerError.persistence("EFI machine bundle firmware destinations are incomplete")
        }

        let parent = artifacts[0].destination.deletingLastPathComponent()
        guard artifacts.allSatisfy({ $0.destination.deletingLastPathComponent() == parent }),
              isPrivateDirectory(path: parent.path) else {
            throw MachineManagerError.persistence("machine snapshot destination is not private")
        }
        let token = UUID().uuidString
        let temporaryURLs = artifacts.map {
            parent.appendingPathComponent(".\($0.destination.lastPathComponent).tmp-\(token)")
        }
        var createdTemporaryURLs: [URL] = []
        for temporaryURL in temporaryURLs {
            guard FileManager.default.createFile(
                atPath: temporaryURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                for created in createdTemporaryURLs {
                    try? FileManager.default.removeItem(at: created)
                }
                throw MachineManagerError.persistence("could not create temporary machine snapshot artifact")
            }
            createdTemporaryURLs.append(temporaryURL)
        }
        var outputs: [FileHandle] = []
        do {
            for temporaryURL in temporaryURLs {
                outputs.append(try FileHandle(forWritingTo: temporaryURL))
            }
        } catch {
            for output in outputs { try? output.close() }
            for temporaryURL in temporaryURLs { try? FileManager.default.removeItem(at: temporaryURL) }
            throw error
        }
        var outputsAreOpen = true
        defer {
            if outputsAreOpen {
                for output in outputs { try? output.close() }
            }
        }
        var publishedDestinations: [URL] = []
        do {
            for (index, artifact) in artifacts.enumerated() {
                try input.seek(toOffset: artifact.offset)
                let digest = try copyExactly(
                    from: input,
                    to: outputs[index],
                    byteCount: artifact.length
                )
                guard digest == artifact.digest else {
                    throw MachineManagerError.persistence("corrupt dory machine bundle artifact")
                }
            }
            for output in outputs { try output.synchronize() }
            try input.close()
            inputIsOpen = false
            for output in outputs { try output.close() }
            outputsAreOpen = false
            for temporaryURL in temporaryURLs {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: temporaryURL.path
                )
            }
            for (temporaryURL, artifact) in zip(temporaryURLs, artifacts) {
                guard link(temporaryURL.path, artifact.destination.path) == 0 else {
                    throw MachineManagerError.persistence(
                        "could not publish machine snapshot artifact: \(String(cString: strerror(errno)))"
                    )
                }
                publishedDestinations.append(artifact.destination)
            }
            for temporaryURL in temporaryURLs { try FileManager.default.removeItem(at: temporaryURL) }
            publishedDestinations.removeAll()
        } catch {
            for destination in publishedDestinations {
                try? FileManager.default.removeItem(at: destination)
            }
            for temporaryURL in temporaryURLs { try? FileManager.default.removeItem(at: temporaryURL) }
            throw error
        }
    }

    private static func readHeader(from input: FileHandle) throws -> Header {
        try input.seek(toOffset: 0)
        let gotMagic = try readExactly(from: input, count: v3Magic.count)
        let includesFirmware: Bool
        if gotMagic == v3Magic {
            includesFirmware = false
        } else if gotMagic == v4Magic {
            includesFirmware = true
        } else {
            throw MachineManagerError.persistence("not a dory machine bundle")
        }
        let metadataLength = decodeUInt64(try readExactly(from: input, count: lengthByteCount))
        let rootfsLength = decodeUInt64(try readExactly(from: input, count: lengthByteCount))
        let kernelLength = decodeUInt64(try readExactly(from: input, count: lengthByteCount))
        let machineIdentifierLength = includesFirmware
            ? decodeUInt64(try readExactly(from: input, count: lengthByteCount))
            : nil
        let nvramLength = includesFirmware
            ? decodeUInt64(try readExactly(from: input, count: lengthByteCount))
            : nil
        guard metadataLength > 0, metadataLength <= maximumMetadataLength else {
            throw MachineManagerError.persistence("invalid dory machine bundle metadata")
        }
        guard rootfsLength > 0, rootfsLength <= UInt64(Int64.max) else {
            throw MachineManagerError.persistence("invalid dory machine bundle rootfs size")
        }
        guard kernelLength > 0, kernelLength <= UInt64(Int64.max) else {
            throw MachineManagerError.persistence("invalid dory machine bundle kernel size")
        }
        if includesFirmware {
            guard let machineIdentifierLength, machineIdentifierLength > 0,
                  let nvramLength, nvramLength > 0 else {
                throw MachineManagerError.persistence("invalid dory machine bundle firmware size")
            }
        }
        let metadataDigest = try readExactly(from: input, count: digestByteCount)
        let rootfsDigest = try readExactly(from: input, count: digestByteCount)
        let kernelDigest = try readExactly(from: input, count: digestByteCount)
        let machineIdentifierDigest = includesFirmware
            ? try readExactly(from: input, count: digestByteCount)
            : nil
        let nvramDigest = includesFirmware
            ? try readExactly(from: input, count: digestByteCount)
            : nil
        let metadata = try readExactly(from: input, count: Int(metadataLength))
        guard Data(SHA256.hash(data: metadata)) == metadataDigest else {
            throw MachineManagerError.persistence("corrupt dory machine bundle metadata")
        }
        let snapshot = try JSONDecoder().decode(DoryMachineSnapshot.self, from: metadata)
        try MachineManager.validateSnapshotRuntimeIdentity(snapshot)
        guard snapshot.sizeBytes == Int64(rootfsLength) else {
            throw MachineManagerError.persistence("machine bundle rootfs size does not match metadata")
        }
        guard (snapshot.bootMode == .efi) == includesFirmware else {
            throw MachineManagerError.persistence("machine bundle boot mode does not match its artifacts")
        }
        if let evidence = snapshot.artifactEvidence {
            guard evidence.isValid,
                  evidence.rootfs.byteCount == rootfsLength,
                  evidence.rootfs.sha256 == digestHex(rootfsDigest),
                  evidence.kernel.byteCount == kernelLength,
                  evidence.kernel.sha256 == digestHex(kernelDigest),
                  evidence.machineIdentifier?.byteCount == machineIdentifierLength,
                  evidence.machineIdentifier?.sha256 == machineIdentifierDigest.map(digestHex),
                  evidence.nvram?.byteCount == nvramLength,
                  evidence.nvram?.sha256 == nvramDigest.map(digestHex) else {
                throw MachineManagerError.persistence(
                    "machine bundle artifacts do not match immutable snapshot evidence"
                )
            }
        } else if snapshot.runtimeIdentity.mode != .legacyCompatibility {
            throw MachineManagerError.persistence(
                "machine bundle artifact evidence requires migration"
            )
        }
        let artifactCount = includesFirmware ? 5 : 3
        let fixedHeaderLength = UInt64(
            v3Magic.count + (lengthByteCount * artifactCount) + (digestByteCount * artifactCount)
        )
        let (rootfsOffset, metadataOverflow) = fixedHeaderLength.addingReportingOverflow(metadataLength)
        let (kernelOffset, rootfsOverflow) = rootfsOffset.addingReportingOverflow(rootfsLength)
        let (afterKernelOffset, kernelOverflow) = kernelOffset.addingReportingOverflow(kernelLength)
        var machineIdentifierOffset: UInt64?
        var nvramOffset: UInt64?
        let expectedFileLength: UInt64
        var firmwareOverflow = false
        if let machineIdentifierLength, let nvramLength {
            machineIdentifierOffset = afterKernelOffset
            let (computedNVRAMOffset, identifierOverflow) = afterKernelOffset.addingReportingOverflow(machineIdentifierLength)
            nvramOffset = computedNVRAMOffset
            let (computedFileLength, nvramOverflow) = computedNVRAMOffset.addingReportingOverflow(nvramLength)
            expectedFileLength = computedFileLength
            firmwareOverflow = identifierOverflow || nvramOverflow
        } else {
            expectedFileLength = afterKernelOffset
        }
        guard !metadataOverflow, !rootfsOverflow, !kernelOverflow, !firmwareOverflow,
              try input.seekToEnd() == expectedFileLength else {
            throw MachineManagerError.persistence("truncated or trailing dory machine bundle artifacts")
        }
        var identity = Data()
        identity.append(bigEndianBytes(metadataLength))
        identity.append(bigEndianBytes(rootfsLength))
        identity.append(bigEndianBytes(kernelLength))
        if let machineIdentifierLength, let nvramLength {
            identity.append(bigEndianBytes(machineIdentifierLength))
            identity.append(bigEndianBytes(nvramLength))
        }
        identity.append(metadataDigest)
        identity.append(rootfsDigest)
        identity.append(kernelDigest)
        if let machineIdentifierDigest, let nvramDigest {
            identity.append(machineIdentifierDigest)
            identity.append(nvramDigest)
        }
        return Header(
            snapshot: snapshot,
            rootfsOffset: rootfsOffset,
            rootfsLength: rootfsLength,
            rootfsDigest: rootfsDigest,
            kernelOffset: kernelOffset,
            kernelLength: kernelLength,
            kernelDigest: kernelDigest,
            machineIdentifierOffset: machineIdentifierOffset,
            machineIdentifierLength: machineIdentifierLength,
            machineIdentifierDigest: machineIdentifierDigest,
            nvramOffset: nvramOffset,
            nvramLength: nvramLength,
            nvramDigest: nvramDigest,
            contentID: Data(SHA256.hash(data: identity))
        )
    }

    private static func digestHex(_ digest: Data) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func openRegularFileForReading(
        path: String,
        requirePrivateOwnership: Bool = false
    ) throws -> FileHandle {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw MachineManagerError.persistence(
                "could not open machine bundle file: \(String(cString: strerror(errno)))"
            )
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            close(descriptor)
            throw MachineManagerError.persistence(
                "could not inspect machine bundle file: \(String(cString: strerror(code)))"
            )
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            throw MachineManagerError.persistence("machine bundle input is not a regular file")
        }
        if requirePrivateOwnership {
            guard info.st_uid == getuid(), info.st_nlink == 1, (info.st_mode & 0o077) == 0 else {
                close(descriptor)
                throw MachineManagerError.persistence("machine snapshot rootfs is not private")
            }
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func isPrivateDirectory(path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == getuid()
            && (info.st_mode & 0o077) == 0
    }

    private static func copyExactly(
        from input: FileHandle,
        to output: FileHandle,
        byteCount: UInt64,
        rejectTrailingInput: Bool = false
    ) throws -> Data {
        var remaining = byteCount
        var hasher = SHA256()
        while remaining > 0 {
            let requested = Int(min(remaining, UInt64(copyChunkSize)))
            let chunk = try input.read(upToCount: requested) ?? Data()
            guard !chunk.isEmpty else {
                throw MachineManagerError.persistence("truncated dory machine bundle payload")
            }
            try output.write(contentsOf: chunk)
            hasher.update(data: chunk)
            remaining -= UInt64(chunk.count)
        }
        if rejectTrailingInput {
            let extra = try input.read(upToCount: 1) ?? Data()
            guard extra.isEmpty else {
                throw MachineManagerError.persistence("machine snapshot changed while exporting")
            }
        }
        return Data(hasher.finalize())
    }

    private static func readExactly(from input: FileHandle, count: Int) throws -> Data {
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            let chunk = try input.read(upToCount: count - result.count) ?? Data()
            guard !chunk.isEmpty else {
                throw MachineManagerError.persistence("truncated dory machine bundle")
            }
            result.append(chunk)
        }
        return result
    }

    private static func decodeUInt64(_ data: Data) -> UInt64 {
        data.reduce(UInt64(0)) { partial, byte in
            (partial << 8) | UInt64(byte)
        }
    }

    private static func bigEndianBytes(_ value: UInt64) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(lengthByteCount)
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((value >> UInt64(shift)) & 0xff))
        }
        return Data(bytes)
    }
}

private struct WorkspaceMigrationAuthorityFacts: Codable {
    var guestArchitecture: DoryGuestArchitecture
    var systemDiskCapacityBytes: UInt64?
    var installedEFIBoot: DoryMachineConfigurationInstalledEFIBoot?
    var lifecycle: DoryVMLifecycleMetadata
}

private final class MachineLifecycleJournalContext: @unchecked Sendable {
    let operation: DoryWorkspaceLifecycleOperation
    private(set) var lease: DoryOperationLease!

    init(operation: DoryWorkspaceLifecycleOperation, lease: DoryOperationLease) {
        self.operation = operation
        self.lease = lease
    }

    func releaseLease() {
        lease = nil
    }
}

private final class MachineManagerPlanningMutationRetention: @unchecked Sendable {
    private let stateLock = NSLock()
    private let manager: MachineManager
    private let machineID: String
    private var workspaceLock: EngineStateDirectoryLock?

    init(
        manager: MachineManager,
        machineID: String,
        workspaceLock: EngineStateDirectoryLock
    ) {
        self.manager = manager
        self.machineID = machineID
        self.workspaceLock = workspaceLock
    }

    func release() {
        stateLock.withLock {
            guard workspaceLock != nil else { return }
            manager.releasePlanningMutation(machineID: machineID) {
                workspaceLock = nil
            }
        }
    }

    deinit { release() }
}

private final class MachineManagerDirectMutationRetention: @unchecked Sendable {
    let workspaceLock: EngineStateDirectoryLock
    var depth = 1

    init(workspaceLock: EngineStateDirectoryLock) {
        self.workspaceLock = workspaceLock
    }
}

/// Planning recovery binds launch-relevant runtime authority, not the transient explanation for
/// why an unplanned machine needs a plan. This stays stable across daemon restart while resolved
/// identities retain the exact immutable plan digest and backend/runtime tuple.
private struct MachinePlanningRuntimeAuthority: Codable {
    var schemaVersion: UInt16
    var mode: DoryMachineRuntimeIdentityMode
    var virtualHardwareABIVersion: UInt16
    var resolvedPlanSHA256: String?
    var planRevision: UInt64?
    var definitionRevision: UInt64?
    var definitionSHA256: String?
    var backend: DoryVirtualizationBackendIdentity?
    var backendImplementationIdentifier: String?
    var backendRuntimeBuildIdentifier: String?

    init(identity: DoryMachineRuntimeIdentity) {
        schemaVersion = identity.schemaVersion
        mode = identity.mode
        virtualHardwareABIVersion = identity.virtualHardwareABIVersion
        resolvedPlanSHA256 = identity.resolvedPlanSHA256
        planRevision = identity.planRevision
        definitionRevision = identity.definitionRevision
        definitionSHA256 = identity.definitionSHA256
        backend = identity.backend
        backendImplementationIdentifier = identity.backendImplementationIdentifier
        backendRuntimeBuildIdentifier = identity.backendRuntimeBuildIdentifier
    }
}

private struct MachineLifecycleDependencyAuthority: Codable {
    var schemaVersion: UInt16 = 2
    var mutationKind: String
    var workspaceID: String
    var sourceLegacyConfigurationSHA256: String?
    var sourceDefinitionSHA256: String?
    var sourceRuntimeIdentitySHA256: String?
    var targetLegacyConfigurationSHA256: String?
    var targetDefinitionSHA256: String?
    var targetRuntimeIdentitySHA256: String?
    var targetResourceID: String?
    var targetSnapshotDescriptorSHA256: String?
    var targetSnapshotArtifactEvidenceSHA256: String?
}

extension MachineManager: DoryDaemonVirtualMachinePlanningMutationAuthorizing {}

private extension DoryOperationPhase {
    var indexForMachineLifecycle: Int {
        switch self {
        case .planned: 0
        case .quiescing: 1
        case .staging: 2
        case .verifying: 3
        case .readyToPublish: 4
        case .publishing: 5
        case .validating: 6
        case .completed: 7
        }
    }
}

#if DEBUG
enum MachineLifecycleFaultPoint: Sendable, Equatable {
    case startAfterPreparation
    case completionBeforeJournalWrite(DoryWorkspaceMutationKind)
    case stopAfterProcessStop
    case snapshotAfterRootfs
    case restoreAfterBackups
    case deleteAfterQuarantine
}

struct MachineLifecycleInjectedCrash: Error, Sendable {}
#endif

private struct MachineLifecycleJournalCompletionPending: Error, Sendable {}

private struct PreparedMachineStart {
    var machine: DoryMachineConfiguration
    var authoritativeMachine: DoryMachineConfiguration
    var definition: DoryVirtualMachineDefinition?
    var canonicalDefinitionData: Data?
    var authoritativeLegacyData: Data?
}

private struct MachineWorkspaceAuthority {
    var definition: DoryVirtualMachineDefinition
    var migration: DoryMachineConfigurationMigrationResult
    var migrationFactsData: Data
    var runtimeMachine: DoryMachineConfiguration
    var isNative: Bool
    var reconcileState: DoryWorkspaceLegacyProjectionReconcileState
}

private struct PendingResolvedMachineStart {
    var machine: DoryMachineConfiguration
    var plan: DoryResolvedMachinePlan
    var backend: MachineBackendDescriptor
    var runtimeBuildIdentifier: String
    var runtimeComponents: [DoryResolvedBackendComponentEvidence]
    var graphics: DoryGraphicsAccelerationLevel
    var devices: DoryVirtualMachineDeviceCapabilityRequest
    var planRevision: UInt64
    var planSHA256: String
    var preSpawnAuthorization: DoryDaemonVirtualMachinePreSpawnAuthorization
}

private struct MachineEntry {
    var configuration: DoryMachineConfiguration
    var state: DoryMachineState
    var process: HvProcess?
    var handoffServer: VmmHandoffServer?
    var handoff: VmmHandoff?
    var launchID: UUID?
    var runtimeAddress: String?
    var currentBalloonTargetMB: UInt64?
    var lastError: String?
    var activeResolvedPlan: DoryResolvedMachinePlan?
    var runtimeIdentity: DoryMachineRuntimeIdentity = .legacyCompatibility(
        virtualHardwareABIVersion:
            DoryVirtualMachineDefinition.currentVirtualHardwareABIVersion
    )
}

extension MachineManager: WakeClockSyncing {
    public func syncAgentClock(now: Date) -> AgentClockSyncResult {
        let runningAgents = list().compactMap { status -> (id: String, socketPath: String, supported: Bool)? in
            guard status.state == .running, let socketPath = status.agentSocketPath else {
                return nil
            }
            return (status.id, socketPath, status.supportsAgentCapability("clock-sync"))
        }
        guard !runningAgents.isEmpty else {
            return AgentClockSyncResult(name: "machines", attempted: false, synced: false)
        }

        let hostEpochNs = Int64((now.timeIntervalSince1970 * 1_000_000_000).rounded())
        var failures: [String] = []
        var syncedCount = 0
        for agent in runningAgents {
            guard agent.supported else {
                failures.append("\(agent.id): clock-sync capability unavailable")
                continue
            }
            do {
                let client = try agentConnector(agent.socketPath)
                defer { client.close() }
                if try client.clockSync(hostEpochNs: hostEpochNs) {
                    syncedCount += 1
                } else {
                    failures.append("\(agent.id): agent declined clock sync")
                }
            } catch {
                failures.append("\(agent.id): \(error)")
            }
        }

        return AgentClockSyncResult(
            name: "machines",
            attempted: true,
            synced: failures.isEmpty && syncedCount == runningAgents.count,
            error: failures.isEmpty ? nil : failures.joined(separator: "; ")
        )
    }
}

private extension DoryMachineStatus {
    func supportsAgentCapability(_ id: String, minimumVersion: UInt32 = 1) -> Bool {
        guard agentBuild?.isEmpty == false,
              agentProtocolVersion == DoryCore.protocolVersion(),
              agentCapabilities.allSatisfy(\.isValid),
              agentCapabilities == agentCapabilities.sorted(by: { $0.id < $1.id }),
              Set(agentCapabilities.map(\.id)).count == agentCapabilities.count else {
            return false
        }
        return agentCapabilities.contains { $0.id == id && $0.version >= minimumVersion }
    }
}

private extension VmmReadyMessage {
    func supportsAgentCapability(_ id: String, minimumVersion: UInt32 = 1) -> Bool {
        guard agentBuild?.isEmpty == false,
              agentProtocolVersion == DoryCore.protocolVersion(),
              agentCapabilities.allSatisfy(\.isValid),
              agentCapabilities == agentCapabilities.sorted(by: { $0.id < $1.id }),
              Set(agentCapabilities.map(\.id)).count == agentCapabilities.count else {
            return false
        }
        return agentCapabilities.contains { $0.id == id && $0.version >= minimumVersion }
    }
}
