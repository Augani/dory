import Darwin
import Foundation

/// Crash-safe control-plane storage shared by import, backup/restore, relocation, and upgrade.
///
/// Journals deliberately live outside both ~/.dory and the drive being moved. `begin` and
/// `acquire` return a lease holding the one mutation lock for this Dory home; read-only inspection
/// remains available while an operation is active.
public struct DoryOperationJournalStore: Sendable, Equatable {
    public static let schemaVersion = 1

    public let home: String
    public let controlDirectory: String
    public let root: String

    public init(home: String = DoryDataDrive.processHome()) throws {
        let canonicalHome = try DoryDataDrive.canonicalPath(home)
        let requestedControl = canonicalHome + "/Library/Application Support/Dory"
        let requestedRoot = requestedControl + "/operations"
        self.home = canonicalHome
        controlDirectory = try DoryDataDrive.canonicalPath(requestedControl)
        root = try DoryDataDrive.canonicalPath(requestedRoot)
    }

    public func operationDirectory(for id: UUID) -> String {
        root + "/" + id.uuidString.lowercased() + ".doryop"
    }

    public func begin(
        _ plan: DoryOperationPlan,
        at date: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> DoryOperationLease {
        guard plan.isValid else {
            throw DoryOperationJournalError.invalidPlan(plan.id.uuidString.lowercased())
        }
        try prepareRoot(fileManager: fileManager)
        let lock = try acquireMutationLock()
        let destination = operationDirectory(for: plan.id)
        guard !Self.pathEntryExists(destination) else {
            throw DoryOperationJournalError.operationExists(plan.id)
        }

        let partial = root + "/." + plan.id.uuidString.lowercased() + "."
            + UUID().uuidString.lowercased() + ".partial"
        do {
            try Self.createPrivateDirectory(partial)
            for component in ["specs", "manifests", "logs"] {
                try Self.createPrivateDirectory(partial + "/" + component)
            }

            let planData = try Self.encoded(plan, pretty: true)
            let initial = Self.initialState(plan: plan, planData: planData, date: date)
            try Self.publish(planData, to: partial + "/plan.json")
            try Self.publish(try Self.encoded(initial.state, pretty: true), to: partial + "/state.json")
            try Self.publish(try Self.encoded(initial.event, pretty: false), to: partial + "/events.ndjson")
            try Self.syncDirectory(partial)
            guard Darwin.rename(partial, destination) == 0 else {
                throw DoryOperationJournalError.filesystem(
                    "publish Dory operation journal at \(destination): errno \(errno)"
                )
            }
            try Self.syncDirectory(root)
            return DoryOperationLease(store: self, operationID: plan.id, lock: lock)
        } catch {
            try? fileManager.removeItem(atPath: partial)
            throw error
        }
    }

    public func acquire(
        _ id: UUID,
        fileManager: FileManager = .default
    ) throws -> DoryOperationLease {
        guard Self.pathEntryExists(root) else {
            throw DoryOperationJournalError.operationNotFound(id)
        }
        try validateRoot()
        let lock = try acquireMutationLock()
        let lease = DoryOperationLease(store: self, operationID: id, lock: lock)
        _ = try lease.read()
        try lease.reconcileAuditLog()
        return lease
    }

    public func read(_ id: UUID) throws -> DoryOperationRecord {
        guard Self.pathEntryExists(root) else {
            throw DoryOperationJournalError.operationNotFound(id)
        }
        try validateRoot()
        return try readRecord(id)
    }

    public func list() throws -> [DoryOperationRecord] {
        guard Self.pathEntryExists(root) else { return [] }
        try validateRoot()
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: root)
        } catch {
            throw DoryOperationJournalError.filesystem(
                "list Dory operation journals at \(root): \(error)"
            )
        }
        var records: [DoryOperationRecord] = []
        for entry in entries.sorted() {
            if entry == ".mutation.lock" || Self.isUnpublishedPartial(entry) { continue }
            guard entry.hasSuffix(".doryop"),
                  let id = UUID(uuidString: String(entry.dropLast(".doryop".count))) else {
                throw DoryOperationJournalError.invalidRecord(root + "/" + entry)
            }
            records.append(try readRecord(id))
        }
        return records.sorted { $0.plan.createdAt < $1.plan.createdAt }
    }

    func readRecord(_ id: UUID) throws -> DoryOperationRecord {
        let directory = operationDirectory(for: id)
        guard Self.pathEntryExists(directory) else {
            throw DoryOperationJournalError.operationNotFound(id)
        }
        try Self.validatePrivateDirectory(directory)
        let planPath = directory + "/plan.json"
        let statePath = directory + "/state.json"
        let planData = try Self.secureRead(planPath, maximumBytes: 16 * 1_024 * 1_024)
        let stateData = try Self.secureRead(statePath, maximumBytes: 1_024 * 1_024)
        guard let plan = try? JSONDecoder().decode(DoryOperationPlan.self, from: planData),
              plan.isValid,
              plan.id == id,
              let state = try? JSONDecoder().decode(DoryOperationState.self, from: stateData),
              state.isStructurallyValid,
              state.operationID == id,
              state.planDigest == Self.digest(planData) else {
            throw DoryOperationJournalError.invalidRecord(directory)
        }
        return DoryOperationRecord(plan: plan, state: state)
    }

    fileprivate func validateRoot() throws {
        try Self.validatePrivateDirectory(controlDirectory)
        try Self.validatePrivateDirectory(root)
    }

    fileprivate func prepareRoot(fileManager: FileManager) throws {
        do {
            try fileManager.createDirectory(
                atPath: controlDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Self.securePrivateDirectory(controlDirectory)
            if !Self.pathEntryExists(root) {
                try fileManager.createDirectory(
                    atPath: root,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            try Self.securePrivateDirectory(root)
        } catch let error as DoryOperationJournalError {
            throw error
        } catch {
            throw DoryOperationJournalError.filesystem(
                "prepare Dory operation directory at \(root): \(error)"
            )
        }
    }

    fileprivate func acquireMutationLock() throws -> EngineStateDirectoryLock {
        do {
            return try EngineStateDirectoryLock(
                stateDirectory: root,
                lockFileName: ".mutation.lock"
            )
        } catch let error as EngineStateDirectoryLockError {
            switch error {
            case .alreadyInUse:
                throw DoryOperationJournalError.operationInUse(error.description)
            case .cannotOpen:
                throw DoryOperationJournalError.filesystem(error.description)
            }
        }
    }

    private static func isUnpublishedPartial(_ name: String) -> Bool {
        let components = name.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4,
              components[0].isEmpty,
              components[3] == "partial" else {
            return false
        }
        return UUID(uuidString: String(components[1])) != nil
            && UUID(uuidString: String(components[2])) != nil
    }

    static func legalTransition(
        from current: DoryOperationState,
        to phase: DoryOperationPhase,
        status: DoryOperationStatus
    ) -> Bool {
        guard current.phase != .completed,
              current.status != .completed,
              current.status != .failed,
              (phase == .completed) == (status == .completed) else {
            return false
        }

        let delta = phase.index - current.phase.index
        guard delta == 0 || delta == 1 else { return false }
        if delta == 1 {
            guard current.status == .running else { return false }
            if phase == .completed {
                return current.phase == .validating && status == .completed
            }
            return status == .running
        }

        switch current.status {
        case .running:
            return status != .completed
        case .interrupted, .blocked, .needsRecovery:
            return status == .running
                || status == .rollingBack
                || status == .failed
                || status == current.status
        case .rollingBack:
            return status == .rollingBack || status == .needsRecovery || status == .failed
        case .failed, .completed:
            return false
        }
    }

    private static func initialState(
        plan: DoryOperationPlan,
        planData: Data,
        date: Date
    ) -> (event: DoryOperationEvent, state: DoryOperationState) {
        let event = DoryOperationEvent(
            operationID: plan.id,
            revision: 0,
            timestamp: date,
            phase: .planned,
            status: .running,
            result: nil,
            stepID: "operation.created",
            recoveryAction: nil
        )
        return (
            event,
            DoryOperationState(
                operationID: plan.id,
                planDigest: digest(planData),
                revision: 0,
                phase: .planned,
                status: .running,
                event: event
            )
        )
    }

}
