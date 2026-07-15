import CryptoKit
import DoryCore
import Foundation

public struct MachineManagerConfiguration: Sendable, Equatable {
    public var vmmExecutablePath: String
    public var stateDirectory: String
    public var runtimeDirectory: String
    public var baseArguments: [String]
    public var passMachineArguments: Bool
    public var logDirectory: String
    public var requiresReadyHandoff: Bool

    public init(
        vmmExecutablePath: String,
        stateDirectory: String,
        runtimeDirectory: String? = nil,
        baseArguments: [String] = [],
        passMachineArguments: Bool = true,
        logDirectory: String? = nil,
        requiresReadyHandoff: Bool = true
    ) {
        self.vmmExecutablePath = vmmExecutablePath
        self.stateDirectory = stateDirectory
        self.runtimeDirectory = runtimeDirectory ?? stateDirectory
        self.baseArguments = baseArguments
        self.passMachineArguments = passMachineArguments
        self.logDirectory = logDirectory ?? "\(stateDirectory)/logs"
        self.requiresReadyHandoff = requiresReadyHandoff
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

public struct DoryMachineConfiguration: Sendable, Equatable, Hashable, Codable {
    public var id: String
    public var kernelPath: String
    public var rootfsPath: String
    public var memoryMB: UInt64
    public var cpuCount: Int
    public var address: String?
    public var shares: [DoryMachineShareConfiguration]
    public var environment: [String: String]

    public init(
        id: String,
        kernelPath: String,
        rootfsPath: String,
        memoryMB: UInt64 = 2048,
        cpuCount: Int = 2,
        address: String? = nil,
        shares: [DoryMachineShareConfiguration] = [],
        environment: [String: String] = [:]
    ) {
        self.id = id
        self.kernelPath = kernelPath
        self.rootfsPath = rootfsPath
        self.memoryMB = memoryMB
        self.cpuCount = cpuCount
        self.address = address
        self.shares = shares
        self.environment = environment
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kernelPath
        case rootfsPath
        case memoryMB
        case cpuCount
        case address
        case shares
        case environment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            kernelPath: try container.decode(String.self, forKey: .kernelPath),
            rootfsPath: try container.decode(String.self, forKey: .rootfsPath),
            memoryMB: try container.decodeIfPresent(UInt64.self, forKey: .memoryMB) ?? 2048,
            cpuCount: try container.decodeIfPresent(Int.self, forKey: .cpuCount) ?? 2,
            address: try container.decodeIfPresent(String.self, forKey: .address),
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
    public var address: String?
    public var handoffFDCount: Int
    public var memoryMB: UInt64
    public var currentBalloonTargetMB: UInt64
    public var cpuCount: Int
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
        handoffFDCount: Int = 0,
        memoryMB: UInt64 = 0,
        currentBalloonTargetMB: UInt64? = nil,
        cpuCount: Int = 0,
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
        self.handoffFDCount = handoffFDCount
        self.memoryMB = memoryMB
        self.currentBalloonTargetMB = currentBalloonTargetMB ?? memoryMB
        self.cpuCount = cpuCount
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
    public var memoryMB: UInt64
    public var cpuCount: Int

    public init(
        id: String,
        machineID: String,
        note: String,
        createdISO: String,
        rootfsPath: String,
        sizeBytes: Int64,
        kernelPath: String,
        memoryMB: UInt64,
        cpuCount: Int
    ) {
        self.id = id
        self.machineID = machineID
        self.note = note
        self.createdISO = createdISO
        self.rootfsPath = rootfsPath
        self.sizeBytes = sizeBytes
        self.kernelPath = kernelPath
        self.memoryMB = memoryMB
        self.cpuCount = cpuCount
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

    private static let handoffReadyTimeoutSeconds: TimeInterval = 60
    private static let deletionQuarantinePrefix = ".dory-machine-delete-"
    private static let machineDiskTemporaryPrefix = ".rootfs.ext4.tmp-"
    private static let machineMetadataTemporaryPrefix = ".dory-machine-metadata-"
    private static let snapshotDeletionQuarantinePrefix = ".dory-snapshot-delete-"
    private static let snapshotDiskTemporaryMarker = ".ext4.tmp-"
    private static let snapshotMetadataTemporaryPrefix = ".dory-snapshot-metadata-"
    /// Public Apple-Silicon machine resource contract. These match the app's steppers; enforcing
    /// them again in doryd prevents CLI/XPC callers from persisting values that the VMM would later
    /// clamp silently, which would make status disagree with the running guest.
    public static let minimumMachineMemoryMB: UInt64 = 1024
    public static let maximumMachineMemoryMB: UInt64 = 16 * 1024
    public static let minimumMachineCPUCount = 1
    public static let maximumMachineCPUCount = 8

    private let configuration: MachineManagerConfiguration
    private let agentConnector: AgentConnector
    private let balloonController: any MachineBalloonControlling
    private let operationLock = NSRecursiveLock()
    private let lock = NSLock()
    private var machines: [String: MachineEntry] = [:]
    private var deletingMachineIDs: Set<String> = []

    public init(
        configuration: MachineManagerConfiguration,
        balloonController: any MachineBalloonControlling = UnixMachineBalloonController(),
        agentConnector: @escaping AgentConnector = { socketPath in
            try LocalAgentControl.connect(socketPath: socketPath)
        }
    ) {
        self.configuration = configuration
        self.balloonController = balloonController
        self.agentConnector = agentConnector
        _ = HelperProcessJanitor.terminateStaleHelpers(
            executablePath: configuration.vmmExecutablePath,
            stateDirectory: configuration.stateDirectory,
            includeDescendants: true
        )
        Self.removeStaleDeletionQuarantines(stateDirectory: configuration.stateDirectory)
        Self.removeStaleMachineMetadataArtifacts(stateDirectory: configuration.stateDirectory)
        Self.removeStaleSnapshotArtifacts(stateDirectory: configuration.stateDirectory)
        self.machines = Self.loadPersistedMachines(configuration: configuration)
    }

    @discardableResult
    public func create(_ machine: DoryMachineConfiguration) throws -> DoryMachineStatus {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard Self.isValidID(machine.id) else {
            throw MachineManagerError.invalidID(machine.id)
        }
        var machine = machine
        try Self.validateResources(memoryMB: machine.memoryMB, cpuCount: machine.cpuCount)
        machine.address = try Self.normalizedAddress(machine.address)
        try Self.validateShares(machine.shares)
        try Self.validateEnvironment(machine.environment)
        lock.lock()
        let exists = machines[machine.id] != nil || deletingMachineIDs.contains(machine.id)
        lock.unlock()
        guard !exists else {
            throw MachineManagerError.duplicateMachine(machine.id)
        }
        guard Self.isRegularNonemptyFile(path: machine.kernelPath) else {
            throw MachineManagerError.persistence("machine kernel is missing or invalid: \(machine.kernelPath)")
        }
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

        let preparedMachine = try prepareMachineDisk(machine)
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
            memoryMB: preparedMachine.memoryMB,
            cpuCount: preparedMachine.cpuCount,
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
        do {
            try Self.validateResources(
                memoryMB: entry.configuration.memoryMB,
                cpuCount: entry.configuration.cpuCount
            )
            try validateManagedMachineArtifacts(entry.configuration)
        } catch {
            lock.unlock()
            throw error
        }
        if entry.process?.isRunning == true {
            lock.unlock()
            throw MachineManagerError.alreadyRunning(id)
        }
        let handoffPath = configuration.requiresReadyHandoff ? handoffSocketPath(id: id) : nil
        let handoffServer: VmmHandoffServer?
        do {
            handoffServer = try handoffPath.map { path in
                let server = VmmHandoffServer(path: path) { [weak self] result in
                    self?.handleHandoff(machineID: id, result: result)
                }
                try server.start()
                return server
            }
        } catch {
            lock.unlock()
            throw error
        }
        let process = HvProcess(configuration: processConfiguration(for: entry.configuration, handoffPath: handoffPath))
        entry.process = process
        entry.handoffServer = handoffServer
        entry.handoff = nil
        entry.currentBalloonTargetMB = nil
        entry.state = configuration.requiresReadyHandoff ? .starting : .running
        entry.lastError = nil
        machines[id] = entry
        lock.unlock()

        do {
            try process.start()
        } catch {
            lock.lock()
            machines[id]?.handoffServer?.stop()
            machines[id]?.handoffServer = nil
            machines[id]?.state = .failed
            machines[id]?.lastError = "\(error)"
            lock.unlock()
            throw error
        }
        if configuration.requiresReadyHandoff {
            scheduleHandoffTimeout(id: id, process: process)
        }
        return status(id: id) ?? DoryMachineStatus(id: id, state: .running)
    }

    private func scheduleHandoffTimeout(id: String, process: HvProcess) {
        // A VMM that boots but never completes the ready handoff would otherwise leave the
        // machine `.starting` forever. Bound the wait: if this exact launch is still starting
        // when the deadline passes, mark it failed and tear the helper down.
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.handoffReadyTimeoutSeconds) { [weak self] in
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
            entry.currentBalloonTargetMB = nil
            entry.state = .failed
            entry.lastError = "vmm ready handoff timed out after \(Int(Self.handoffReadyTimeoutSeconds))s"
            self.machines[id] = entry
            self.lock.unlock()
            process.stop()
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
        entry.currentBalloonTargetMB = nil
        entry.state = .stopped
        machines[id] = entry
        lock.unlock()

        handoffServer?.stop()
        process?.stop()
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
            machines[id]?.currentBalloonTargetMB = nil
            machines[id]?.state = .stopped
        }
        lock.unlock()

        for entry in runningEntries {
            entry.handoffServer?.stop()
            entry.process?.stop()
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
        entry.process?.stop()

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
        updatesEnvironment: Bool = false
    ) throws -> DoryMachineStatus {
        operationLock.lock()
        defer { operationLock.unlock() }
        if memoryMB != nil || cpuCount != nil {
            let current = try configurationAndRunningState(id: id).0
            try Self.validateResources(
                memoryMB: memoryMB ?? current.memoryMB,
                cpuCount: cpuCount ?? current.cpuCount
            )
        }
        if let shares {
            try Self.validateShares(shares)
        }
        if let environment {
            try Self.validateEnvironment(environment)
        }
        let normalizedAddress = try Self.normalizedAddress(address)
        let needsRestart = memoryMB != nil || cpuCount != nil || updatesShares || updatesEnvironment
        let (current, wasRunning) = try configurationAndRunningState(id: id)
        if wasRunning && needsRestart {
            _ = try stop(id: id)
        }
        var updated = current
        if let memoryMB {
            updated.memoryMB = memoryMB
        }
        if let cpuCount {
            updated.cpuCount = cpuCount
        }
        if updatesAddress {
            updated.address = normalizedAddress
        }
        if updatesShares {
            updated.shares = shares ?? []
        }
        if updatesEnvironment {
            updated.environment = environment ?? [:]
        }
        do {
            try persist(updated)
            lock.lock()
            guard var entry = machines[id] else {
                lock.unlock()
                throw MachineManagerError.unknownMachine(id)
            }
            entry.configuration = updated
            machines[id] = entry
            lock.unlock()
            return wasRunning && needsRestart
                ? try start(id: id)
                : (status(id: id) ?? DoryMachineStatus(id: id, state: .stopped))
        } catch let error as MachineManagerError {
            if wasRunning && needsRestart {
                _ = try? start(id: id)
            }
            throw error
        } catch {
            if wasRunning && needsRestart {
                _ = try? start(id: id)
            }
            throw MachineManagerError.persistence("could not update \(id): \(error)")
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
        try ensurePrivateSnapshotDirectory(machineID: id)
        let rootfsPath = snapshotRootfsPath(machineID: id, snapshotID: snapshotID)
        guard !FileManager.default.fileExists(atPath: snapshotMetadataPath(machineID: id, snapshotID: snapshotID)),
              !FileManager.default.fileExists(atPath: rootfsPath) else {
            throw MachineManagerError.duplicateSnapshot(snapshotID)
        }

        if wasRunning {
            _ = try stop(id: id)
        }
        let snapshot: DoryMachineSnapshot
        do {
            try Self.cloneOrCopyFile(source: machine.rootfsPath, destination: rootfsPath)
            snapshot = DoryMachineSnapshot(
                id: snapshotID,
                machineID: id,
                note: note,
                createdISO: createdISO,
                rootfsPath: rootfsPath,
                sizeBytes: Self.fileSize(path: rootfsPath),
                kernelPath: machine.kernelPath,
                memoryMB: machine.memoryMB,
                cpuCount: machine.cpuCount
            )
            try persistSnapshot(snapshot)
        } catch {
            try? FileManager.default.removeItem(atPath: rootfsPath)
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
            memoryMB: snapshot.memoryMB,
            cpuCount: snapshot.cpuCount
        )
        _ = try create(machine)
        do {
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
        if wasRunning {
            _ = try stop(id: machineID)
        }
        do {
            try Self.cloneOrCopyFile(source: snapshot.rootfsPath, destination: machine.rootfsPath)
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
        _ = try loadSnapshot(machineID: machineID, snapshotID: snapshotID)
        let metadataPath = snapshotMetadataPath(machineID: machineID, snapshotID: snapshotID)
        let rootfsPath = snapshotRootfsPath(machineID: machineID, snapshotID: snapshotID)
        let token = "\(Self.snapshotDeletionQuarantinePrefix)\(snapshotID)-\(UUID().uuidString)"
        let directory = snapshotDirectory(machineID: machineID)
        let quarantinedMetadataPath = "\(directory)/\(token).json"
        let quarantinedRootfsPath = "\(directory)/\(token).ext4"
        do {
            try FileManager.default.moveItem(atPath: rootfsPath, toPath: quarantinedRootfsPath)
        } catch {
            throw MachineManagerError.persistence("could not delete snapshot \(snapshotID): \(error)")
        }
        do {
            try FileManager.default.moveItem(atPath: metadataPath, toPath: quarantinedMetadataPath)
        } catch {
            do {
                try FileManager.default.moveItem(atPath: quarantinedRootfsPath, toPath: rootfsPath)
            } catch let rollbackError {
                throw MachineManagerError.persistence(
                    "could not delete snapshot \(snapshotID): \(error); rootfs rollback failed: \(rollbackError)"
                )
            }
            throw MachineManagerError.persistence("could not delete snapshot \(snapshotID): \(error)")
        }
        try? FileManager.default.removeItem(atPath: quarantinedMetadataPath)
        try? FileManager.default.removeItem(atPath: quarantinedRootfsPath)
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
        do {
            let bundle = try MachineSnapshotBundle.readDescriptor(fromPath: path)
            var snapshot = bundle.snapshot
            guard Self.isValidID(snapshot.machineID), Self.isValidID(snapshot.id) else {
                throw MachineManagerError.persistence("invalid snapshot metadata")
            }
            try Self.validateResources(memoryMB: snapshot.memoryMB, cpuCount: snapshot.cpuCount)
            try ensurePrivateSnapshotDirectory(machineID: snapshot.machineID)
            if FileManager.default.fileExists(atPath: snapshotMetadataPath(machineID: snapshot.machineID, snapshotID: snapshot.id)) ||
                FileManager.default.fileExists(atPath: snapshotRootfsPath(machineID: snapshot.machineID, snapshotID: snapshot.id)) {
                snapshot.id = Self.generatedSnapshotID(prefix: "import")
            }
            snapshot.rootfsPath = snapshotRootfsPath(machineID: snapshot.machineID, snapshotID: snapshot.id)
            extractedRootfsPath = snapshot.rootfsPath
            try MachineSnapshotBundle.extractRootfs(
                fromPath: path,
                expectedContentID: bundle.contentID,
                toPath: snapshot.rootfsPath
            )
            snapshot.sizeBytes = Self.fileSize(path: snapshot.rootfsPath)
            try persistSnapshot(snapshot)
            return snapshot
        } catch let error as MachineManagerError {
            if let extractedRootfsPath {
                try? FileManager.default.removeItem(atPath: extractedRootfsPath)
            }
            throw error
        } catch {
            if let extractedRootfsPath {
                try? FileManager.default.removeItem(atPath: extractedRootfsPath)
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
        if [.starting, .running].contains(entry.state), entry.process?.isRunning != true {
            return DoryMachineStatus(
                id: id,
                state: .failed,
                lastError: entry.lastError ?? "dory-vmm process exited",
                address: entry.configuration.address,
                memoryMB: entry.configuration.memoryMB,
                cpuCount: entry.configuration.cpuCount,
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
            address: entry.configuration.address,
            handoffFDCount: entry.handoff?.fileDescriptors.count ?? 0,
            memoryMB: entry.configuration.memoryMB,
            currentBalloonTargetMB: entry.currentBalloonTargetMB ?? entry.configuration.memoryMB,
            cpuCount: entry.configuration.cpuCount,
            shares: entry.configuration.shares,
            environment: entry.configuration.environment
        )
    }

    private func processConfiguration(
        for machine: DoryMachineConfiguration,
        handoffPath: String?
    ) -> HvProcessConfiguration {
        HvProcessConfiguration(
            executablePath: configuration.vmmExecutablePath,
            arguments: processArguments(for: machine, handoffPath: handoffPath),
            logPath: "\(configuration.logDirectory)/\(machine.id).log"
        )
    }

    private func processArguments(for machine: DoryMachineConfiguration, handoffPath: String?) -> [String] {
        guard configuration.passMachineArguments else {
            return configuration.baseArguments
        }
        var arguments = configuration.baseArguments + [
            "--machine-id", machine.id,
            "--state-dir", machineStateDirectory(id: machine.id),
            "--dockerd-sock", "\(machineRuntimeDirectory(id: machine.id))/d.sock",
            "--agent-sock", "\(machineRuntimeDirectory(id: machine.id))/a.sock",
            "--shell-sock", "\(machineRuntimeDirectory(id: machine.id))/s.sock",
            "--control-sock", "\(machineRuntimeDirectory(id: machine.id))/c.sock",
            "--kernel", machine.kernelPath,
            "--rootfs", machine.rootfsPath,
            "--memory-mb", String(machine.memoryMB),
            "--cpus", String(machine.cpuCount),
        ]
        if let handoffPath {
            arguments.append(contentsOf: ["--handoff-sock", handoffPath])
        }
        for share in machine.shares {
            arguments.append(contentsOf: ["--share", share.argumentValue])
        }
        for (key, value) in machine.environment.sorted(by: { $0.key < $1.key }) {
            arguments.append(contentsOf: ["--env", "\(key)=\(value)"])
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

    private func snapshotDirectory(machineID: String) -> String {
        "\(machineStateDirectory(id: machineID))/snapshots"
    }

    private func snapshotMetadataPath(machineID: String, snapshotID: String) -> String {
        "\(snapshotDirectory(machineID: machineID))/\(snapshotID).json"
    }

    private func snapshotRootfsPath(machineID: String, snapshotID: String) -> String {
        "\(snapshotDirectory(machineID: machineID))/\(snapshotID).ext4"
    }

    private func configurationAndRunningState(id: String) throws -> (DoryMachineConfiguration, Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = machines[id] else {
            throw MachineManagerError.unknownMachine(id)
        }
        try validateManagedMachineArtifacts(entry.configuration)
        return (entry.configuration, entry.process?.isRunning == true)
    }

    private func prepareMachineDisk(_ machine: DoryMachineConfiguration) throws -> DoryMachineConfiguration {
        let source = machine.rootfsPath
        let destination = machineRootfsPath(id: machine.id)
        guard source != destination else {
            throw MachineManagerError.persistence("machine rootfs must be imported into managed storage")
        }
        do {
            try Self.cloneOrCopyFile(source: source, destination: destination)
            var copy = machine
            copy.rootfsPath = destination
            return copy
        } catch {
            throw MachineManagerError.persistence("could not prepare rootfs for \(machine.id): \(error)")
        }
    }

    private func validateManagedMachineArtifacts(_ machine: DoryMachineConfiguration) throws {
        guard Self.isRegularNonemptyFile(path: machine.kernelPath) else {
            throw MachineManagerError.persistence("machine kernel is missing or invalid: \(machine.kernelPath)")
        }
        guard Self.isPrivateDirectory(path: machineStateDirectory(id: machine.id)) else {
            throw MachineManagerError.persistence("machine state directory failed managed-storage validation")
        }
        let expectedRootfsPath = machineRootfsPath(id: machine.id)
        guard machine.rootfsPath == expectedRootfsPath,
              Self.isPrivateRegularFile(path: expectedRootfsPath) else {
            throw MachineManagerError.persistence("machine rootfs failed managed-storage validation")
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
        guard Self.isPrivateDirectory(path: snapshotDirectory(machineID: machineID)),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let snapshot = try? JSONDecoder().decode(DoryMachineSnapshot.self, from: data),
              snapshot.machineID == machineID,
              snapshot.id == snapshotID,
              snapshot.rootfsPath == expectedRootfsPath,
              (try? Self.validateResources(memoryMB: snapshot.memoryMB, cpuCount: snapshot.cpuCount)) != nil,
              Self.isPrivateRegularFile(path: expectedRootfsPath) else {
            throw MachineManagerError.unknownSnapshot(snapshotID)
        }
        var validated = snapshot
        validated.sizeBytes = Self.fileSize(path: expectedRootfsPath)
        return validated
    }

    private func handleHandoff(machineID: String, result: Result<VmmHandoff, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = machines[machineID] else { return }
        entry.handoffServer?.stop()
        entry.handoffServer = nil
        switch result {
        case let .success(handoff):
            guard handoff.ready.machineID == machineID else {
                entry.state = .failed
                entry.lastError = "handoff machine id mismatch: \(handoff.ready.machineID)"
                entry.process?.stop()
                break
            }
            entry.handoff = handoff
            entry.state = .running
            entry.lastError = nil
        case let .failure(error):
            entry.state = .failed
            entry.lastError = "\(error)"
            entry.process?.stop()
        }
        machines[machineID] = entry
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
        return "\(prefix)\(stamp)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    private static func cloneOrCopyFile(source: String, destination: String) throws {
        let destinationURL = URL(fileURLWithPath: destination)
        let parent = destinationURL.deletingLastPathComponent()
        let parentDescriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parentDescriptor >= 0 else {
            throw MachineManagerError.persistence(
                "could not open managed rootfs directory: \(String(cString: strerror(errno)))"
            )
        }
        defer { close(parentDescriptor) }
        var parentInfo = stat()
        guard fstat(parentDescriptor, &parentInfo) == 0,
              isPrivateDirectory(info: parentInfo) else {
            throw MachineManagerError.persistence("managed rootfs directory is not private")
        }
        let destinationName = destinationURL.lastPathComponent
        let temporaryName = ".\(destinationName).tmp-\(UUID().uuidString)"
        _ = unlinkat(parentDescriptor, temporaryName, 0)
        let sourceDescriptor = open(source, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard sourceDescriptor >= 0 else {
            throw MachineManagerError.persistence(
                "could not open rootfs source: \(String(cString: strerror(errno)))"
            )
        }
        defer { close(sourceDescriptor) }
        var sourceInfo = stat()
        guard fstat(sourceDescriptor, &sourceInfo) == 0,
              (sourceInfo.st_mode & S_IFMT) == S_IFREG,
              sourceInfo.st_size > 0 else {
            throw MachineManagerError.persistence("rootfs source is not a nonempty regular file")
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
                        "could not create rootfs copy: \(String(cString: strerror(errno)))"
                    )
                }
                defer { close(destinationDescriptor) }
                guard lseek(sourceDescriptor, 0, SEEK_SET) == 0,
                      fcopyfile(sourceDescriptor, destinationDescriptor, nil, copyfile_flags_t(COPYFILE_DATA)) == 0,
                      fchmod(destinationDescriptor, mode_t(0o600)) == 0,
                      isPrivateRegularFile(descriptor: destinationDescriptor),
                      fsync(destinationDescriptor) == 0 else {
                    throw MachineManagerError.persistence(
                        "could not copy rootfs: \(String(cString: strerror(errno)))"
                    )
                }
            } else {
                let clonedDescriptor = openat(parentDescriptor, temporaryName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                guard clonedDescriptor >= 0 else {
                    throw MachineManagerError.persistence("could not reopen cloned rootfs")
                }
                defer { close(clonedDescriptor) }
                guard fchmod(clonedDescriptor, mode_t(0o600)) == 0,
                      isPrivateRegularFile(descriptor: clonedDescriptor),
                      fsync(clonedDescriptor) == 0 else {
                    throw MachineManagerError.persistence(
                        "could not synchronize cloned rootfs: \(String(cString: strerror(errno)))"
                    )
                }
            }
            guard renameat(parentDescriptor, temporaryName, parentDescriptor, destinationName) == 0 else {
                throw MachineManagerError.persistence(
                    "could not replace \(destination): \(String(cString: strerror(errno)))"
                )
            }
        } catch {
            _ = unlinkat(parentDescriptor, temporaryName, 0)
            throw error
        }
    }

    private static func fileSize(path: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        if let number = attrs?[.size] as? NSNumber {
            return number.int64Value
        }
        return 0
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

    private static func isPrivateDirectory(path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && isPrivateDirectory(info: info)
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
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let machine = try? decoder.decode(DoryMachineConfiguration.self, from: data),
                  machine.id == id,
                  isValidID(machine.id),
                  isPrivateDirectory(path: "\(root)/\(id)"),
                  machine.rootfsPath == rootfsPath,
                  isPrivateRegularFile(path: rootfsPath),
                  isRegularNonemptyFile(path: machine.kernelPath) else {
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
                || entry.hasPrefix(machineDiskTemporaryPrefix) {
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
                || (entry.hasPrefix(".") && entry.contains(snapshotDiskTemporaryMarker)) {
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
        var payloadOffset: UInt64
        var payloadLength: UInt64
        var payloadDigest: Data
        var contentID: Data
    }

    private static let magic = Data("DORYMACHINE2\n".utf8)
    private static let lengthByteCount = 8
    private static let digestByteCount = 32
    private static let maximumMetadataLength: UInt64 = 16 * 1024 * 1024
    private static let copyChunkSize = 4 * 1024 * 1024

    static func write(snapshot: DoryMachineSnapshot, toPath path: String) throws {
        let input = try openRegularFileForReading(path: snapshot.rootfsPath, requirePrivateOwnership: true)
        defer { try? input.close() }
        let payloadLength = try input.seekToEnd()
        guard payloadLength > 0, payloadLength <= UInt64(Int64.max) else {
            throw MachineManagerError.persistence("invalid machine snapshot payload size")
        }
        try input.seek(toOffset: 0)

        var exportedSnapshot = snapshot
        exportedSnapshot.sizeBytes = Int64(payloadLength)
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
            try output.write(contentsOf: magic)
            try output.write(contentsOf: bigEndianBytes(UInt64(metadata.count)))
            try output.write(contentsOf: bigEndianBytes(payloadLength))
            try output.write(contentsOf: metadataDigest)
            let payloadDigestOffset = try output.offset()
            try output.write(contentsOf: Data(repeating: 0, count: digestByteCount))
            try output.write(contentsOf: metadata)
            let payloadDigest = try copyExactly(
                from: input,
                to: output,
                byteCount: payloadLength,
                rejectTrailingInput: true
            )
            try output.seek(toOffset: payloadDigestOffset)
            try output.write(contentsOf: payloadDigest)
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

    static func extractRootfs(fromPath path: String, expectedContentID: Data, toPath destination: String) throws {
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
        let outputURL = URL(fileURLWithPath: destination)
        let parent = outputURL.deletingLastPathComponent()
        guard isPrivateDirectory(path: parent.path) else {
            throw MachineManagerError.persistence("machine snapshot destination is not private")
        }
        let temporaryURL = parent.appendingPathComponent(".\(outputURL.lastPathComponent).tmp-\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            try? input.close()
            throw MachineManagerError.persistence("could not create temporary machine snapshot rootfs")
        }
        let output = try FileHandle(forWritingTo: temporaryURL)
        var outputIsOpen = true
        defer {
            if outputIsOpen {
                try? output.close()
            }
        }
        do {
            try input.seek(toOffset: header.payloadOffset)
            let payloadDigest = try copyExactly(
                from: input,
                to: output,
                byteCount: header.payloadLength
            )
            guard payloadDigest == header.payloadDigest else {
                throw MachineManagerError.persistence("corrupt dory machine bundle payload")
            }
            try output.synchronize()
            try input.close()
            inputIsOpen = false
            try output.close()
            outputIsOpen = false
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporaryURL.path
            )
            guard rename(temporaryURL.path, outputURL.path) == 0 else {
                throw MachineManagerError.persistence(
                    "could not publish machine snapshot rootfs: \(String(cString: strerror(errno)))"
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func readHeader(from input: FileHandle) throws -> Header {
        try input.seek(toOffset: 0)
        let gotMagic = try readExactly(from: input, count: magic.count)
        guard gotMagic == magic else {
            throw MachineManagerError.persistence("not a dory machine bundle")
        }
        let metadataLength = decodeUInt64(try readExactly(from: input, count: lengthByteCount))
        let payloadLength = decodeUInt64(try readExactly(from: input, count: lengthByteCount))
        guard metadataLength > 0, metadataLength <= maximumMetadataLength else {
            throw MachineManagerError.persistence("invalid dory machine bundle metadata")
        }
        guard payloadLength > 0, payloadLength <= UInt64(Int64.max) else {
            throw MachineManagerError.persistence("invalid dory machine bundle payload size")
        }
        let metadataDigest = try readExactly(from: input, count: digestByteCount)
        let payloadDigest = try readExactly(from: input, count: digestByteCount)
        let metadata = try readExactly(from: input, count: Int(metadataLength))
        guard Data(SHA256.hash(data: metadata)) == metadataDigest else {
            throw MachineManagerError.persistence("corrupt dory machine bundle metadata")
        }
        let snapshot = try JSONDecoder().decode(DoryMachineSnapshot.self, from: metadata)
        guard snapshot.sizeBytes == Int64(payloadLength) else {
            throw MachineManagerError.persistence("machine bundle payload size does not match metadata")
        }
        let fixedHeaderLength = UInt64(magic.count + (lengthByteCount * 2) + (digestByteCount * 2))
        let (payloadOffset, offsetOverflow) = fixedHeaderLength.addingReportingOverflow(metadataLength)
        let (expectedFileLength, lengthOverflow) = payloadOffset.addingReportingOverflow(payloadLength)
        guard !offsetOverflow, !lengthOverflow, try input.seekToEnd() == expectedFileLength else {
            throw MachineManagerError.persistence("truncated or trailing dory machine bundle payload")
        }
        var identity = Data()
        identity.append(bigEndianBytes(metadataLength))
        identity.append(bigEndianBytes(payloadLength))
        identity.append(metadataDigest)
        identity.append(payloadDigest)
        return Header(
            snapshot: snapshot,
            payloadOffset: payloadOffset,
            payloadLength: payloadLength,
            payloadDigest: payloadDigest,
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
