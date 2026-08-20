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
        environment: [String: String] = [:]
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
            environment: try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        )
    }
}

public enum DoryMachineState: String, Sendable, Equatable {
    case created
    case starting
    case running
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

    public init(
        id: String,
        state: DoryMachineState,
        pid: Int32? = nil,
        lastError: String? = nil,
        handoffSocketPath: String? = nil,
        agentBuild: String? = nil,
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
        environment: [String: String] = [:]
    ) {
        self.id = id
        self.state = state
        self.pid = pid
        self.lastError = lastError
        self.handoffSocketPath = handoffSocketPath
        self.agentBuild = agentBuild
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
    public var bootMode: DoryMachineBootMode
    public var machineIdentifierPath: String?
    public var nvramPath: String?

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
        bootMode: DoryMachineBootMode = .linuxKernel,
        machineIdentifierPath: String? = nil,
        nvramPath: String? = nil
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
        self.bootMode = bootMode
        self.machineIdentifierPath = machineIdentifierPath
        self.nvramPath = nvramPath
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
        case bootMode
        case machineIdentifierPath
        case nvramPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
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
            bootMode: try container.decodeIfPresent(DoryMachineBootMode.self, forKey: .bootMode) ?? .linuxKernel,
            machineIdentifierPath: try container.decodeIfPresent(String.self, forKey: .machineIdentifierPath),
            nvramPath: try container.decodeIfPresent(String.self, forKey: .nvramPath)
        )
    }
}

public struct DoryDesktopUpdateRequest: Sendable, Equatable {
    public var distro: String
    public var version: String
    public var bundlePath: String
    public var kernelPath: String

    public init(distro: String, version: String, bundlePath: String, kernelPath: String) {
        self.distro = distro
        self.version = version
        self.bundlePath = bundlePath
        self.kernelPath = kernelPath
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

private struct DesktopUpdateJournal: Codable, Sendable, Equatable {
    var schema: Int
    var machineID: String
    var distro: String
    var version: String
    var snapshotID: String
    var originalWasRunning: Bool
    var stage: String
}

public enum MachineManagerError: Error, Sendable, Equatable, CustomStringConvertible {
    case duplicateMachine(String)
    case invalidID(String)
    case unknownMachine(String)
    case duplicateSnapshot(String)
    case unknownSnapshot(String)
    case alreadyRunning(String)
    case agentUnavailable(String)
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

public final class MachineManager: @unchecked Sendable {
    public typealias AgentConnector = @Sendable (String) throws -> any AgentControlClient
    public typealias ProcessStarter = @Sendable (HvProcess) throws -> Void

    private static let deletionQuarantinePrefix = ".dory-machine-delete-"
    private static let machineDiskTemporaryPrefix = ".rootfs.ext4.tmp-"
    private static let machineKernelTemporaryPrefix = ".kernel.tmp-"
    private static let installedLinuxKernelName = "direct-kernel"
    private static let installedLinuxInitrdName = "direct-initrd"
    private static let machineMetadataTemporaryPrefix = ".dory-machine-metadata-"
    private static let machineRestoreBackupMarker = ".restore-"
    private static let snapshotDeletionQuarantinePrefix = ".dory-snapshot-delete-"
    private static let snapshotDiskTemporaryMarker = ".ext4.tmp-"
    private static let snapshotKernelTemporaryMarker = ".kernel.tmp-"
    private static let snapshotMachineIdentifierTemporaryMarker = ".machine-identifier.tmp-"
    private static let snapshotNVRAMTemporaryMarker = ".nvram.tmp-"
    private static let snapshotMetadataTemporaryPrefix = ".dory-snapshot-metadata-"
    private static let desktopUpdateJournalName = "desktop-update.json"
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
    private let operationLock = NSRecursiveLock()
    private let lock = NSLock()
    private var machines: [String: MachineEntry] = [:]
    private var deletingMachineIDs: Set<String> = []

    public init(
        configuration: MachineManagerConfiguration,
        balloonController: any MachineBalloonControlling = UnixMachineBalloonController(),
        agentConnector: @escaping AgentConnector = { socketPath in
            try LocalAgentControl.connect(socketPath: socketPath)
        },
        processStarter: @escaping ProcessStarter = { process in try process.start() }
    ) {
        self.configuration = configuration
        self.balloonController = balloonController
        self.agentConnector = agentConnector
        self.processStarter = processStarter
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
        Self.removeStaleDeletionQuarantines(stateDirectory: configuration.stateDirectory)
        Self.removeStaleMachineMetadataArtifacts(stateDirectory: configuration.stateDirectory)
        Self.removeStaleSnapshotArtifacts(stateDirectory: configuration.stateDirectory)
        self.machines = Self.loadPersistedMachines(configuration: configuration)
        recoverInterruptedDesktopUpdates()
    }

    @discardableResult
    public func create(_ machine: DoryMachineConfiguration) throws -> DoryMachineStatus {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard Self.isValidID(machine.id) else {
            throw MachineManagerError.invalidID(machine.id)
        }
        var machine = machine
        machine.address = try Self.normalizedAddress(machine.address)
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

        let preparedMachine = try prepareMachineArtifacts(machine)
        try validateManagedMachineArtifacts(preparedMachine)
        try persist(preparedMachine)
        lock.lock()
        machines[machine.id] = MachineEntry(configuration: preparedMachine, state: .created)
        lock.unlock()
        committed = true
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
            environment: preparedMachine.environment
        )
    }

    @discardableResult
    public func start(id: String) throws -> DoryMachineStatus {
        operationLock.lock()
        defer { operationLock.unlock() }
        lock.lock()
        guard var entry = machines[id] else {
            lock.unlock()
            throw MachineManagerError.unknownMachine(id)
        }
        if entry.process?.isRunning == true {
            lock.unlock()
            throw MachineManagerError.alreadyRunning(id)
        }
        lock.unlock()
        do {
            try ensureInstalledLinuxBootBundleIfNeeded(entry.configuration)
            try materializeInstalledLinuxBootRuntimeIfNeeded(entry.configuration)
            try Self.validateLaunchConfiguration(entry.configuration)
            try validateManagedMachineArtifacts(entry.configuration)
            try validateRuntimeAvailability(entry.configuration)
        } catch {
            throw error
        }
        lock.lock()
        guard let currentEntry = machines[id] else {
            lock.unlock()
            throw MachineManagerError.unknownMachine(id)
        }
        entry = currentEntry
        if entry.process?.isRunning == true {
            lock.unlock()
            throw MachineManagerError.alreadyRunning(id)
        }
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
            processConfiguration = try self.processConfiguration(
                for: entry.configuration,
                handoffPath: handoffPath
            )
        } catch {
            handoffServer?.stop()
            lock.unlock()
            throw error
        }
        let process = HvProcess(configuration: processConfiguration)
        let handoffReadyTimeout = handoffReadyTimeout(for: entry.configuration)
        entry.process = process
        entry.handoffServer = handoffServer
        entry.handoff = nil
        entry.launchID = launchID
        entry.runtimeAddress = nil
        entry.currentBalloonTargetMB = nil
        entry.state = configuration.requiresReadyHandoff ? .starting : .running
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
            machines[id]?.state = .failed
            machines[id]?.lastError = "\(error)"
            lock.unlock()
            throw error
        }
        if configuration.requiresReadyHandoff {
            scheduleHandoffTimeout(id: id, process: process, timeout: handoffReadyTimeout)
        }
        return status(id: id) ?? DoryMachineStatus(id: id, state: .running)
    }

    private func startAndWaitUntilReady(id: String) throws -> DoryMachineStatus {
        let started = try start(id: id)
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
            self.machines[id] = entry
            self.lock.unlock()
            process.stop(timeout: DoryEngineShutdownTiming.hostTerminationSeconds)
        }
    }

    public func stop(id: String) throws -> DoryMachineStatus {
        operationLock.lock()
        defer { operationLock.unlock() }
        lock.lock()
        guard var entry = machines[id] else {
            lock.unlock()
            throw MachineManagerError.unknownMachine(id)
        }
        let process = entry.process
        let handoffServer = entry.handoffServer
        entry.process = nil
        entry.handoffServer = nil
        entry.handoff = nil
        entry.launchID = nil
        entry.runtimeAddress = nil
        entry.currentBalloonTargetMB = nil
        entry.state = .stopped
        machines[id] = entry
        lock.unlock()

        handoffServer?.stop()
        process?.stop(timeout: DoryEngineShutdownTiming.hostTerminationSeconds)
        return status(id: id) ?? DoryMachineStatus(id: id, state: .stopped)
    }

    public func stopAll() {
        operationLock.lock()
        defer { operationLock.unlock() }
        lock.lock()
        let runningEntries = machines.map { id, entry in
            (id: id, process: entry.process, handoffServer: entry.handoffServer)
        }
        for id in machines.keys {
            machines[id]?.process = nil
            machines[id]?.handoffServer = nil
            machines[id]?.handoff = nil
            machines[id]?.launchID = nil
            machines[id]?.runtimeAddress = nil
            machines[id]?.currentBalloonTargetMB = nil
            machines[id]?.state = .stopped
        }
        lock.unlock()

        for entry in runningEntries {
            entry.handoffServer?.stop()
            entry.process?.stop(timeout: DoryEngineShutdownTiming.hostTerminationSeconds)
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
        lock.lock()
        guard let entry = machines.removeValue(forKey: id) else {
            lock.unlock()
            throw MachineManagerError.unknownMachine(id)
        }
        deletingMachineIDs.insert(id)
        lock.unlock()

        entry.handoffServer?.stop()
        entry.process?.stop(timeout: DoryEngineShutdownTiming.hostTerminationSeconds)

        let fileManager = FileManager.default
        let statePath = machineStateDirectory(id: id)
        var quarantinePath: String?
        if fileManager.fileExists(atPath: statePath) {
            let quarantine = "\(configuration.stateDirectory)/\(Self.deletionQuarantinePrefix)\(id)-\(UUID().uuidString)"
            do {
                try fileManager.moveItem(atPath: statePath, toPath: quarantine)
                quarantinePath = quarantine
            } catch {
                var restored = entry
                restored.process = nil
                restored.handoffServer = nil
                restored.handoff = nil
                restored.currentBalloonTargetMB = nil
                restored.state = .stopped
                restored.lastError = "delete failed: \(error)"
                lock.lock()
                deletingMachineIDs.remove(id)
                if machines[id] == nil {
                    machines[id] = restored
                }
                lock.unlock()
                throw MachineManagerError.persistence("could not delete \(id): \(error)")
            }
        }

        lock.lock()
        deletingMachineIDs.remove(id)
        lock.unlock()

        try? FileManager.default.removeItem(atPath: machineRuntimeDirectory(id: id))
        if let quarantinePath {
            try? fileManager.removeItem(atPath: quarantinePath)
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
        installerMediaAttached: Bool? = nil
    ) throws -> DoryMachineStatus {
        operationLock.lock()
        defer { operationLock.unlock() }
        let (current, wasRunning) = try configurationAndRunningState(id: id)
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
        guard updated != current else {
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
            _ = try stop(id: id)
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
                    _ = try startAndWaitUntilReady(id: id)
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
            return try startAndWaitUntilReady(id: id)
        } catch {
            let updateError = error
            _ = try? stop(id: id)
            do {
                try persist(current)
                try publishConfiguration(current)
            } catch {
                throw MachineManagerError.persistence(
                    "could not start updated \(id): \(updateError); configuration rollback failed: \(error)"
                )
            }
            do {
                _ = try startAndWaitUntilReady(id: id)
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
        let snapshotID = explicitSnapshotID ?? Self.generatedSnapshotID()
        guard Self.isValidID(snapshotID) else {
            throw MachineManagerError.invalidID(snapshotID)
        }
        let (machine, wasRunning) = try configurationAndRunningState(id: id)
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

        if wasRunning {
            _ = try stop(id: id)
        }
        let snapshot: DoryMachineSnapshot
        var publishedRootfs = false
        var publishedKernel = false
        var publishedMachineIdentifier = false
        var publishedNVRAM = false
        do {
            try Self.cloneOrCopyFile(source: machine.rootfsPath, destination: rootfsPath)
            publishedRootfs = true
            try Self.cloneOrCopyFile(source: machine.kernelPath, destination: kernelPath)
            publishedKernel = true
            if machine.bootMode == .efi {
                let liveMachineIdentifierPath = machineFirmwareIdentifierPath(id: id)
                let liveNVRAMPath = machineFirmwareNVRAMPath(id: id)
                guard Self.isPrivateRegularFile(path: liveMachineIdentifierPath),
                      Self.isPrivateRegularFile(path: liveNVRAMPath) else {
                    throw MachineManagerError.persistence(
                        "EFI firmware state is unavailable; start the machine once before taking a snapshot"
                    )
                }
                try Self.cloneOrCopyFile(
                    source: liveMachineIdentifierPath,
                    destination: machineIdentifierPath
                )
                publishedMachineIdentifier = true
                try Self.cloneOrCopyFile(source: liveNVRAMPath, destination: nvramPath)
                publishedNVRAM = true
            }
            snapshot = DoryMachineSnapshot(
                id: snapshotID,
                machineID: id,
                note: note,
                createdISO: createdISO,
                rootfsPath: rootfsPath,
                sizeBytes: Self.fileSize(path: rootfsPath),
                kernelPath: kernelPath,
                architecture: configuration.guestArchitecture,
                memoryMB: machine.memoryMB,
                cpuCount: machine.cpuCount,
                displayMode: machine.displayMode,
                address: machine.address,
                shares: machine.shares,
                environment: machine.environment,
                bootMode: machine.bootMode,
                machineIdentifierPath: machine.bootMode == .efi ? machineIdentifierPath : nil,
                nvramPath: machine.bootMode == .efi ? nvramPath : nil
            )
            try persistSnapshot(snapshot)
        } catch {
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
            if wasRunning {
                _ = try? start(id: id)
            }
            if let error = error as? MachineManagerError {
                throw error
            }
            throw MachineManagerError.persistence("could not snapshot \(id): \(error)")
        }

        if wasRunning {
            do {
                _ = try start(id: id)
            } catch let firstError {
                do {
                    _ = try start(id: id)
                } catch {
                    throw MachineManagerError.persistence(
                        "snapshot \(snapshotID) was created, but \(id) could not restart: \(firstError); retry: \(error)"
                    )
                }
            }
        }
        return snapshot
    }

    /// Applies a signed desktop component to an existing persistent guest. The caller provides
    /// component-store paths, but doryd owns the entire transaction: a last-good disk/kernel
    /// snapshot is durable before the guest is mutated, and any failed install or post-reboot
    /// qualification restores that snapshot and the machine's original running state.
    public func updateDesktop(
        id: String,
        request: DoryDesktopUpdateRequest
    ) throws -> DoryDesktopUpdateResult {
        operationLock.lock()
        defer { operationLock.unlock() }

        let (original, originallyRunning) = try configurationAndRunningState(id: id)
        guard original.bootMode == .linuxKernel else {
            throw MachineManagerError.persistence("managed desktop updates do not apply to custom EFI machines")
        }
        guard original.displayMode == .desktop else {
            throw MachineManagerError.persistence("desktop updates require a graphical machine")
        }
        guard ["debian", "ubuntu", "kali"].contains(request.distro),
              original.environment["DORY_DESKTOP_DISTRO"] == request.distro else {
            throw MachineManagerError.persistence("desktop update distribution does not match " + id)
        }
        guard request.version.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._+-]{0,127}/) != nil else {
            throw MachineManagerError.persistence("desktop update version is invalid")
        }
        guard Self.isRegularNonemptyFile(path: request.bundlePath),
              Self.isRegularNonemptyFile(path: request.kernelPath) else {
            throw MachineManagerError.persistence("desktop update assets are missing or invalid")
        }
        let bundleURL = URL(fileURLWithPath: request.bundlePath).standardizedFileURL
        let bundleDirectory = bundleURL.deletingLastPathComponent().path
        guard Self.isDirectory(path: bundleDirectory), bundleURL.lastPathComponent != "." else {
            throw MachineManagerError.persistence("desktop update bundle directory is invalid")
        }
        let bundleSHA256 = try Self.sha256(path: request.bundlePath)
        let snapshotID = Self.generatedSnapshotID(prefix: "du")
        let snapshot = try snapshot(
            id: id,
            note: "Automatic last-good snapshot before " + request.distro + " " + request.version + " desktop update",
            snapshotID: snapshotID
        )
        var journal = DesktopUpdateJournal(
            schema: 1,
            machineID: id,
            distro: request.distro,
            version: request.version,
            snapshotID: snapshot.id,
            originalWasRunning: originallyRunning,
            stage: "snapshot-ready"
        )
        try persistDesktopUpdateJournal(journal)

        let token = String(bundleSHA256.prefix(12))
        let mountPath = "/mnt/dory-update-" + token
        let guestStage = "/var/lib/dory/update-" + token
        let updateShare = DoryMachineShareConfiguration(
            tag: "dory-update-" + token,
            hostPath: bundleDirectory,
            guestPath: mountPath,
            readOnly: true
        )
        let bundleGuestPath = mountPath + "/" + bundleURL.lastPathComponent

        do {
            var transientShares = original.shares.filter { $0.tag != updateShare.tag }
            transientShares.append(updateShare)
            _ = try update(id: id, shares: transientShares, updatesShares: true)
            if status(id: id)?.state != .running {
                _ = try startAndWaitUntilReady(id: id)
            }
            journal.stage = "installing"
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
            var updatedEnvironment = original.environment
            updatedEnvironment["DORY_DESKTOP_RELEASE_VERSION"] = request.version
            updatedEnvironment["DORY_DESKTOP_INPUT_SHA256"] = inputSHA256
            _ = try update(
                id: id,
                shares: original.shares,
                updatesShares: true,
                environment: updatedEnvironment,
                updatesEnvironment: true
            )
            try Self.cloneOrCopyFile(
                source: request.kernelPath,
                destination: original.kernelPath,
                replaceExisting: true
            )
            journal.stage = "qualifying"
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
            journal.stage = "committed"
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
            environment: snapshot.environment
        )
        _ = try create(machine)
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
        let snapshot = try loadSnapshot(machineID: machineID, snapshotID: snapshotID)
        let (machine, wasRunning) = try configurationAndRunningState(id: machineID)
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
        if wasRunning {
            _ = try stop(id: machineID)
        }
        do {
            try restoreManagedArtifacts(machine: machine, snapshot: snapshot) {
                try persist(restoredMachine)
                lock.lock()
                if var entry = machines[machineID] {
                    entry.configuration = restoredMachine
                    entry.currentBalloonTargetMB = nil
                    machines[machineID] = entry
                }
                lock.unlock()
            }
            let status = wasRunning
                ? try start(id: machineID)
                : (status(id: machineID) ?? DoryMachineStatus(id: machineID, state: .stopped))
            return status
        } catch let error as MachineManagerError {
            if wasRunning {
                _ = try? start(id: machineID)
            }
            throw error
        } catch {
            if wasRunning {
                _ = try? start(id: machineID)
            }
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
        let snapshot = try loadSnapshot(machineID: machineID, snapshotID: snapshotID)
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

    public func list() -> [DoryMachineStatus] {
        lock.lock()
        let statuses = machines.keys.sorted().compactMap { id in
            machines[id].map { statusLocked(id: id, entry: $0) }
        }
        lock.unlock()
        return statuses
    }

    private func statusLocked(id: String, entry: MachineEntry) -> DoryMachineStatus {
        if [.starting, .running].contains(entry.state), entry.process?.isRunningOrRestarting != true {
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
                environment: entry.configuration.environment
            )
        }
        return DoryMachineStatus(
            id: id,
            state: entry.state,
            pid: entry.process?.pid,
            lastError: entry.lastError,
            handoffSocketPath: entry.handoffServer?.path,
            agentBuild: entry.handoff?.ready.agentBuild,
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
            environment: entry.configuration.environment
        )
    }

    private func processConfiguration(
        for machine: DoryMachineConfiguration,
        handoffPath: String?
    ) throws -> HvProcessConfiguration {
        let target = processTarget(for: machine)
        return HvProcessConfiguration(
            executablePath: target.executablePath,
            arguments: try processArguments(
                for: machine,
                handoffPath: handoffPath,
                baseArguments: target.baseArguments,
                acceleratedDesktop: target.acceleratedDesktop
            ),
            logPath: "\(configuration.logDirectory)/\(machine.id).log",
            restartPolicy: configuration.requiresReadyHandoff
                ? configuration.startupRestartPolicy
                : .none
        )
    }

    private func processTarget(for machine: DoryMachineConfiguration) -> (
        executablePath: String,
        baseArguments: [String],
        acceleratedDesktop: Bool
    ) {
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
        acceleratedDesktop: Bool
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
        for share in machine.shares {
            arguments.append(contentsOf: ["--share", share.argumentValue])
        }
        for (key, value) in machine.environment.sorted(by: { $0.key < $1.key }) {
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

    private func persistDesktopUpdateJournal(_ journal: DesktopUpdateJournal) throws {
        let directory = machineStateDirectory(id: journal.machineID)
        guard Self.isPrivateDirectory(path: directory) else {
            throw MachineManagerError.persistence("desktop update journal owner is not private")
        }
        let temporaryPath = "\(directory)/.desktop-update.tmp-\(UUID().uuidString)"
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(journal)
            try data.write(to: URL(fileURLWithPath: temporaryPath), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryPath)
            guard rename(temporaryPath, desktopUpdateJournalPath(machineID: journal.machineID)) == 0 else {
                throw MachineManagerError.persistence(
                    "could not publish desktop update journal: \(String(cString: strerror(errno)))"
                )
            }
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
        } catch {
            throw MachineManagerError.persistence("could not remove desktop update journal: \(error)")
        }
    }

    private func recoverInterruptedDesktopUpdates() {
        lock.lock()
        let machineIDs = Array(machines.keys)
        lock.unlock()
        for machineID in machineIDs {
            let path = desktopUpdateJournalPath(machineID: machineID)
            guard let data = Self.readPrivateMetadata(path: path),
                  let journal = try? JSONDecoder().decode(DesktopUpdateJournal.self, from: data),
                  journal.schema == 1,
                  journal.machineID == machineID,
                  Self.isValidID(journal.snapshotID) else {
                continue
            }
            if journal.stage == "committed" {
                try? removeDesktopUpdateJournal(machineID: machineID)
                continue
            }
            do {
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
        try withAgentClient(id: id) { client in
            try client.telemetry()
        }
    }

    public func memorySnapshots() -> [GuestMemorySnapshot] {
        list().compactMap { status in
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
        return try withAgentClient(id: id) { client in
            try client.exec(
                argv: argv,
                cwd: cwd,
                env: env,
                timeoutMs: timeoutMs,
                outputLimitBytes: outputLimitBytes
            )
        }
    }

    private func withAgentClient<T>(
        id: String,
        _ operation: (any AgentControlClient) throws -> T
    ) throws -> T {
        guard let status = status(id: id) else {
            throw MachineManagerError.unknownMachine(id)
        }
        guard status.state == .running, let socketPath = status.agentSocketPath else {
            throw MachineManagerError.agentUnavailable(id)
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
        let active = [.starting, .running].contains(entry.state) && entry.process != nil
        return (entry.configuration, active)
    }

    private func publishConfiguration(_ configuration: DoryMachineConfiguration) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = machines[configuration.id] else {
            throw MachineManagerError.unknownMachine(configuration.id)
        }
        entry.configuration = configuration
        entry.currentBalloonTargetMB = nil
        machines[configuration.id] = entry
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
        commit: () throws -> Void
    ) throws {
        let directory = machineStateDirectory(id: machine.id)
        let token = UUID().uuidString
        let rootfsBackup = "\(directory)/.restore-rootfs-\(token)"
        let kernelBackup = "\(directory)/.restore-kernel-\(token)"
        let machineIdentifierBackup = "\(directory)/.restore-machine-identifier-\(token)"
        let nvramBackup = "\(directory)/.restore-nvram-\(token)"
        defer {
            try? FileManager.default.removeItem(atPath: rootfsBackup)
            try? FileManager.default.removeItem(atPath: kernelBackup)
            try? FileManager.default.removeItem(atPath: machineIdentifierBackup)
            try? FileManager.default.removeItem(atPath: nvramBackup)
        }
        try Self.cloneOrCopyFile(source: machine.rootfsPath, destination: rootfsBackup)
        do {
            try Self.cloneOrCopyFile(source: machine.kernelPath, destination: kernelBackup)
        } catch {
            throw MachineManagerError.persistence("could not preserve live kernel before restore: \(error)")
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

    private func persist(_ machine: DoryMachineConfiguration) throws {
        let fileManager = FileManager.default
        let directory = machineStateDirectory(id: machine.id)
        let temporaryPath = "\(directory)/\(Self.machineMetadataTemporaryPrefix)\(UUID().uuidString)"
        do {
            try fileManager.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(machine)
            let path = machineConfigPath(id: machine.id)
            try data.write(to: URL(fileURLWithPath: temporaryPath), options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryPath)
            guard rename(temporaryPath, path) == 0 else {
                throw MachineManagerError.persistence(
                    "could not publish machine metadata: \(String(cString: strerror(errno)))"
                )
            }
        } catch let error as MachineManagerError {
            try? fileManager.removeItem(atPath: temporaryPath)
            throw error
        } catch {
            try? fileManager.removeItem(atPath: temporaryPath)
            throw MachineManagerError.persistence("\(error)")
        }
    }

    private func persistSnapshot(_ snapshot: DoryMachineSnapshot) throws {
        let fileManager = FileManager.default
        let directory = snapshotDirectory(machineID: snapshot.machineID)
        let temporaryPath = "\(directory)/\(Self.snapshotMetadataTemporaryPrefix)\(snapshot.id)-\(UUID().uuidString)"
        do {
            guard Self.isPrivateDirectory(path: directory) else {
                throw MachineManagerError.persistence("machine snapshot path is not a private directory")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
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
        var validated = snapshot
        validated.sizeBytes = Self.fileSize(path: expectedRootfsPath)
        return validated
    }

    private func handleHandoff(
        machineID: String,
        launchID: UUID,
        result: Result<VmmHandoff, Error>
    ) {
        var handoffServer: VmmHandoffServer?
        var processToStop: HvProcess?
        var agentSocketPath: String?
        lock.lock()
        guard var entry = machines[machineID], entry.launchID == launchID else {
            lock.unlock()
            return
        }
        handoffServer = entry.handoffServer
        entry.handoffServer = nil
        switch result {
        case let .success(handoff):
            guard handoff.ready.machineID == machineID else {
                entry.state = .failed
                entry.lastError = "handoff machine id mismatch: \(handoff.ready.machineID)"
                entry.launchID = nil
                entry.runtimeAddress = nil
                processToStop = entry.process
                break
            }
            entry.handoff = handoff
            entry.state = .running
            entry.lastError = nil
            entry.process?.disableRestarts()
            agentSocketPath = handoff.ready.agentSocketPath
        case let .failure(error):
            entry.state = .failed
            entry.lastError = "\(error)"
            entry.launchID = nil
            entry.runtimeAddress = nil
            processToStop = entry.process
        }
        machines[machineID] = entry
        lock.unlock()

        handoffServer?.stop()
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

    private static func loadPersistedMachines(configuration: MachineManagerConfiguration) -> [String: MachineEntry] {
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
            loaded[id] = MachineEntry(configuration: machine, state: .stopped)
        }
        return loaded
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
        guard snapshot.sizeBytes == Int64(rootfsLength) else {
            throw MachineManagerError.persistence("machine bundle rootfs size does not match metadata")
        }
        guard (snapshot.bootMode == .efi) == includesFirmware else {
            throw MachineManagerError.persistence("machine bundle boot mode does not match its artifacts")
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
}

extension MachineManager: WakeClockSyncing {
    public func syncAgentClock(now: Date) -> AgentClockSyncResult {
        let runningAgents = list().compactMap { status -> (id: String, socketPath: String)? in
            guard status.state == .running, let socketPath = status.agentSocketPath else {
                return nil
            }
            return (status.id, socketPath)
        }
        guard !runningAgents.isEmpty else {
            return AgentClockSyncResult(name: "machines", attempted: false, synced: false)
        }

        let hostEpochNs = Int64((now.timeIntervalSince1970 * 1_000_000_000).rounded())
        var failures: [String] = []
        var syncedCount = 0
        for agent in runningAgents {
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
