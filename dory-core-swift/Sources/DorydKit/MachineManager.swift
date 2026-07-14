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
        "\(tag)=\(hostPath):\(guestPath):\(readOnly ? "ro" : "rw")"
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
    private static let snapshotDeletionQuarantinePrefix = ".dory-snapshot-delete-"
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
        let preparedMachine = try prepareMachineDisk(machine)
        lock.lock()
        defer { lock.unlock() }
        guard machines[machine.id] == nil, !deletingMachineIDs.contains(machine.id) else {
            throw MachineManagerError.duplicateMachine(machine.id)
        }
        try persist(preparedMachine)
        machines[machine.id] = MachineEntry(configuration: preparedMachine, state: .created)
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
        return try start(id: newID)
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
            var snapshot = try MachineSnapshotBundle.readMetadata(fromPath: path)
            guard Self.isValidID(snapshot.machineID), Self.isValidID(snapshot.id) else {
                throw MachineManagerError.persistence("invalid snapshot metadata")
            }
            try Self.validateResources(memoryMB: snapshot.memoryMB, cpuCount: snapshot.cpuCount)
            if FileManager.default.fileExists(atPath: snapshotMetadataPath(machineID: snapshot.machineID, snapshotID: snapshot.id)) ||
                FileManager.default.fileExists(atPath: snapshotRootfsPath(machineID: snapshot.machineID, snapshotID: snapshot.id)) {
                snapshot.id = Self.generatedSnapshotID(prefix: "import")
            }
            snapshot.rootfsPath = snapshotRootfsPath(machineID: snapshot.machineID, snapshotID: snapshot.id)
            extractedRootfsPath = snapshot.rootfsPath
            try MachineSnapshotBundle.extractRootfs(fromPath: path, toPath: snapshot.rootfsPath)
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
        return (entry.configuration, entry.process?.isRunning == true)
    }

    private func prepareMachineDisk(_ machine: DoryMachineConfiguration) throws -> DoryMachineConfiguration {
        let source = machine.rootfsPath
        let destination = machineRootfsPath(id: machine.id)
        guard FileManager.default.fileExists(atPath: source),
              source != destination else {
            return machine
        }
        do {
            try FileManager.default.createDirectory(
                atPath: machineStateDirectory(id: machine.id),
                withIntermediateDirectories: true
            )
            try Self.cloneOrCopyFile(source: source, destination: destination)
            var copy = machine
            copy.rootfsPath = destination
            return copy
        } catch {
            throw MachineManagerError.persistence("could not prepare rootfs for \(machine.id): \(error)")
        }
    }

    private func persist(_ machine: DoryMachineConfiguration) throws {
        do {
            try FileManager.default.createDirectory(
                atPath: machineStateDirectory(id: machine.id),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(machine)
            let path = machineConfigPath(id: machine.id)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch let error as MachineManagerError {
            throw error
        } catch {
            throw MachineManagerError.persistence("\(error)")
        }
    }

    private func persistSnapshot(_ snapshot: DoryMachineSnapshot) throws {
        let fileManager = FileManager.default
        let directory = snapshotDirectory(machineID: snapshot.machineID)
        let temporaryPath = "\(directory)/\(Self.snapshotMetadataTemporaryPrefix)\(snapshot.id)-\(UUID().uuidString)"
        do {
            try fileManager.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true
            )
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
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
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
        // Clone/copy into a sibling temp path first, then atomically rename over the
        // destination. If the clone and the copy fallback both fail we throw before the
        // rename, so an existing destination (e.g. a machine's live rootfs) is never lost.
        let destinationURL = URL(fileURLWithPath: destination)
        let parent = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent
            .appendingPathComponent(".\(destinationURL.lastPathComponent).tmp-\(UUID().uuidString)")
            .path
        try? FileManager.default.removeItem(atPath: temporary)
        do {
            if clonefile(source, temporary, 0) != 0 {
                try FileManager.default.copyItem(atPath: source, toPath: temporary)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary)
            guard rename(temporary, destination) == 0 else {
                throw MachineManagerError.persistence(
                    "could not replace \(destination): \(String(cString: strerror(errno)))"
                )
            }
        } catch {
            try? FileManager.default.removeItem(atPath: temporary)
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
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1 else {
            return false
        }
        return (info.st_mode & 0o077) == 0
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
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let machine = try? decoder.decode(DoryMachineConfiguration.self, from: data),
                  machine.id == id,
                  isValidID(machine.id) else {
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

    private static func removeStaleSnapshotArtifacts(stateDirectory: String) {
        let fileManager = FileManager.default
        guard let machineIDs = try? fileManager.contentsOfDirectory(atPath: stateDirectory) else {
            return
        }
        for machineID in machineIDs where isValidID(machineID) {
            let directory = "\(stateDirectory)/\(machineID)/snapshots"
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else {
                continue
            }
            for entry in entries where entry.hasPrefix(snapshotDeletionQuarantinePrefix)
                || entry.hasPrefix(snapshotMetadataTemporaryPrefix) {
                try? fileManager.removeItem(atPath: "\(directory)/\(entry)")
            }
        }
    }

    deinit {
        stopAll()
    }
}

private enum MachineSnapshotBundle {
    private static let magic = Data("DORYMACHINE1\n".utf8)
    private static let lengthByteCount = 8

    static func write(snapshot: DoryMachineSnapshot, toPath path: String) throws {
        let outputURL = URL(fileURLWithPath: path)
        let parent = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryURL = parent.appendingPathComponent(".\(outputURL.lastPathComponent).tmp-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: temporaryURL)
        do {
            let metadata = try JSONEncoder().encode(snapshot)
            try output.write(contentsOf: magic)
            try output.write(contentsOf: bigEndianBytes(UInt64(metadata.count)))
            try output.write(contentsOf: metadata)
            try appendFile(path: snapshot.rootfsPath, to: output)
            try output.close()
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    static func readMetadata(fromPath path: String) throws -> DoryMachineSnapshot {
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? input.close() }
        return try readHeader(from: input).snapshot
    }

    static func extractRootfs(fromPath path: String, toPath destination: String) throws {
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        let outputURL = URL(fileURLWithPath: destination)
        let parent = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryURL = parent.appendingPathComponent(".\(outputURL.lastPathComponent).tmp-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: temporaryURL)
        do {
            let header = try readHeader(from: input)
            try input.seek(toOffset: header.payloadOffset)
            try copyRemaining(from: input, to: output)
            try input.close()
            try output.close()
            if FileManager.default.fileExists(atPath: destination) {
                try FileManager.default.removeItem(atPath: destination)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination)
        } catch {
            try? input.close()
            try? output.close()
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func readHeader(from input: FileHandle) throws -> (snapshot: DoryMachineSnapshot, payloadOffset: UInt64) {
        let gotMagic = try input.read(upToCount: magic.count) ?? Data()
        guard gotMagic == magic else {
            throw MachineManagerError.persistence("not a dory machine bundle")
        }
        let lengthData = try input.read(upToCount: lengthByteCount) ?? Data()
        guard lengthData.count == lengthByteCount else {
            throw MachineManagerError.persistence("truncated dory machine bundle")
        }
        let metadataLength = lengthData.reduce(UInt64(0)) { partial, byte in
            (partial << 8) | UInt64(byte)
        }
        guard metadataLength > 0, metadataLength <= 16 * 1024 * 1024 else {
            throw MachineManagerError.persistence("invalid dory machine bundle metadata")
        }
        let metadata = try input.read(upToCount: Int(metadataLength)) ?? Data()
        guard metadata.count == Int(metadataLength) else {
            throw MachineManagerError.persistence("truncated dory machine bundle metadata")
        }
        let snapshot = try JSONDecoder().decode(DoryMachineSnapshot.self, from: metadata)
        let payloadOffset = UInt64(magic.count + lengthByteCount) + metadataLength
        return (snapshot, payloadOffset)
    }

    private static func appendFile(path: String, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? input.close() }
        try copyRemaining(from: input, to: output)
    }

    private static func copyRemaining(from input: FileHandle, to output: FileHandle) throws {
        while true {
            let chunk = try input.read(upToCount: 4 * 1024 * 1024) ?? Data()
            guard !chunk.isEmpty else { return }
            try output.write(contentsOf: chunk)
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
