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

    /// Creates and validates the private journal root before a later mutation needs to publish.
    /// Daemons use this during startup so a transiently read-only managed-data directory cannot
    /// strand an otherwise recoverable operation before its journal is written.
    public func prepare(fileManager: FileManager = .default) throws {
        try prepareRoot(fileManager: fileManager)
    }

    public func begin(
        _ plan: DoryOperationPlan,
        at date: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> DoryOperationLease {
        try begin(
            plan,
            completenessPlanData: nil,
            specifications: [],
            at: date,
            fileManager: fileManager
        )
    }

    public func acquire(
        _ id: UUID,
        fileManager: FileManager = .default
    ) throws -> DoryOperationLease {
        try acquireVerified(id, requestedMutationScope: nil, fileManager: fileManager)
    }

    /// Reacquires a scoped operation only when the caller's expectation matches the scope
    /// authenticated by the immutable journal plan. This overload is useful for callers that
    /// already know which workspace they are recovering; it cannot select a different lock.
    public func acquire(
        _ id: UUID,
        mutationScope: String,
        fileManager: FileManager = .default
    ) throws -> DoryOperationLease {
        try acquireVerified(
            id,
            requestedMutationScope: mutationScope,
            fileManager: fileManager
        )
    }

    private func acquireVerified(
        _ id: UUID,
        requestedMutationScope: String?,
        fileManager: FileManager
    ) throws -> DoryOperationLease {
        guard Self.pathEntryExists(root) else {
            throw DoryOperationJournalError.operationNotFound(id)
        }
        try validateRoot()
        let before = try readRecord(id)
        let authenticatedScope = authenticatedMutationScope(for: before.plan)
        if let requestedMutationScope, requestedMutationScope != authenticatedScope {
            throw DoryOperationJournalError.invalidPlan("mutation scope mismatch")
        }
        let lock = try acquireMutationLock(scope: authenticatedScope)
        let lease = DoryOperationLease(store: self, operationID: id, lock: lock)
        let after = try lease.read()
        guard after.plan == before.plan,
              authenticatedMutationScope(for: after.plan) == authenticatedScope else {
            throw DoryOperationJournalError.invalidRecord(operationDirectory(for: id))
        }
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
            if entry == ".mutation.lock"
                || (entry.hasPrefix(".mutation.") && entry.hasSuffix(".lock"))
                || Self.isUnpublishedPartial(entry) { continue }
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

    func prepareRoot(fileManager: FileManager) throws {
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

    func acquireMutationLock(scope: String? = nil) throws -> EngineStateDirectoryLock {
        if let scope, !Self.isToken(scope) {
            throw DoryOperationJournalError.invalidPlan("mutation scope")
        }
        do {
            return try EngineStateDirectoryLock(
                stateDirectory: root,
                lockFileName: scope.map { ".mutation.\($0).lock" } ?? ".mutation.lock"
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

    /// A same-workspace lifecycle journal has one deterministic lock scope. Multi-workspace
    /// operations (currently clone) retain the established global mutation fence.
    func authenticatedMutationScope(for plan: DoryOperationPlan) -> String? {
        guard Self.isWorkspaceLifecycleKind(plan.kind),
              plan.source.kind == .workspace,
              plan.target.kind == .workspace,
              plan.source.id == plan.target.id,
              Self.isToken(plan.source.id) else {
            return nil
        }
        return plan.source.id
    }

    private static func isWorkspaceLifecycleKind(_ kind: DoryOperationKind) -> Bool {
        switch kind {
        case .workspaceImport, .workspaceProvision, .workspaceResolve, .workspaceStart,
             .workspaceStop, .workspacePause, .workspaceResume, .workspaceSuspend,
             .workspaceRestore, .workspaceSnapshot, .workspaceClone, .workspaceUpdate,
             .workspaceRepair, .workspaceDelete:
            true
        case .competitorImport, .driveBackup, .driveRestore, .driveRelocation, .driveUpgrade:
            false
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

}
