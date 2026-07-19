import DoryOperations
import Foundation

nonisolated enum MigrationImportTransactionError: Error, Sendable, Equatable, CustomStringConvertible {
    case planDrift
    case insufficientHostStorage(required: Int64, available: Int64)
    case unfinishedOperation(UUID, DoryOperationPhase, DoryOperationStatus)
    case operationAndJournal(operation: String, journal: String)

    var description: String {
        switch self {
        case .planDrift:
            return "source, target, capability, or capacity inventory changed after planning"
        case let .insufficientHostStorage(required, available):
            return "host storage changed after planning: \(required) bytes required, \(available) available"
        case let .unfinishedOperation(id, phase, status):
            return "migration operation \(id.uuidString.lowercased()) is still "
                + "\(phase.rawValue)/\(status.rawValue); recover it before starting another import"
        case let .operationAndJournal(operation, journal):
            return "migration preflight failed (\(operation)); recording terminal state also failed: \(journal)"
        }
    }
}

/// A journal lease that has passed the second strict inventory read and may begin target staging.
/// No Docker mutation is permitted before this value exists.
nonisolated struct MigrationImportStagingSession: Sendable {
    let prepared: PreparedMigrationExecution
    let lease: DoryOperationLease
    let state: DoryOperationState
}

nonisolated struct MigrationImportTransactionEnvironment: Sendable {
    let source: any ContainerRuntime
    let target: any ContainerRuntime
    let journalStore: DoryOperationJournalStore
    let currentAvailableHostBytes: Int64
    let transferHelper: MigrationTransferHelperContract?
    let sharedHome: String
    let hostArchitecture: String
}

/// Publishes the immutable plan, reacquires every authority and inventory contract, then advances
/// the operation to staging. This is the only entry point the semantic executor may use.
nonisolated enum MigrationImportTransaction {
    static func requireNoUnfinishedOperation(
        in store: DoryOperationJournalStore
    ) throws {
        if let record = try store.list().first(where: {
            $0.state.status != .completed && $0.state.status != .failed
        }) {
            throw MigrationImportTransactionError.unfinishedOperation(
                record.plan.id,
                record.state.phase,
                record.state.status
            )
        }
    }

    static func openStagingSession(
        prepared: PreparedMigrationExecution,
        environment: MigrationImportTransactionEnvironment
    ) async throws -> MigrationImportStagingSession {
        try requireNoUnfinishedOperation(in: environment.journalStore)
        let lease = try prepared.operation.begin(in: environment.journalStore)
        var state = try lease.read().state
        do {
            try publishBaselines(prepared, lease: lease)
            state = try lease.transition(
                to: .planned,
                status: .running,
                expectedRevision: state.revision,
                stepID: "preflight.baselines-published"
            )
            state = try lease.transition(
                to: .quiescing,
                status: .running,
                expectedRevision: state.revision,
                stepID: "preflight.revalidate"
            )
            try await revalidate(prepared, environment: environment)
            try Task.checkCancellation()
            state = try lease.transition(
                to: .staging,
                status: .running,
                expectedRevision: state.revision,
                stepID: "staging.begin"
            )
            return MigrationImportStagingSession(
                prepared: prepared,
                lease: lease,
                state: state
            )
        } catch is CancellationError {
            try recordCancellation(lease: lease, state: state)
            throw CancellationError()
        } catch {
            let operation = error
            try recordFailure(lease: lease, state: state, operation: operation)
            throw operation
        }
    }
}

private extension MigrationImportTransaction {
    nonisolated static func publishBaselines(
        _ prepared: PreparedMigrationExecution,
        lease: DoryOperationLease
    ) throws {
        let manifests = prepared.operation.baselineManifests
        let plan = prepared.operation.completenessPlan
        let publications = [
            (manifests.sourceInventory, plan.sourceInventoryDigest),
            (manifests.unselectedSourceInventory, plan.unselectedSourceInventoryDigest),
            (manifests.targetInventory, plan.context.targetInventoryDigest),
            (manifests.unownedTargetInventory, plan.context.unownedTargetInventoryDigest)
        ]
        for (data, expectedDigest) in publications {
            guard try lease.publishManifest(data) == expectedDigest else {
                throw MigrationImportTransactionError.planDrift
            }
        }
    }

    static func revalidate(
        _ prepared: PreparedMigrationExecution,
        environment: MigrationImportTransactionEnvironment
    ) async throws {
        try Task.checkCancellation()
        let refreshed = try await MigrationStrictInventoryCollector.collect(
            from: environment.source,
            to: environment.target,
            availableHostBytes: prepared.capacity.availableHostBytes,
            sharedHome: environment.sharedHome,
            transferHelper: environment.transferHelper,
            identity: prepared.identity,
            hostArchitecture: environment.hostArchitecture,
            engineCapacity: MigrationEngineCapacity(
                logicalBytes: prepared.capacity.engineLogicalBytes,
                usableBytes: prepared.capacity.engineUsableBytes
            ),
            userSelection: prepared.operation.completenessPlan.userSelection
        )
        guard prepared.matches(refreshed) else {
            throw MigrationImportTransactionError.planDrift
        }
        guard environment.currentAvailableHostBytes >= prepared.capacity.requiredHostBytes else {
            throw MigrationImportTransactionError.insufficientHostStorage(
                required: prepared.capacity.requiredHostBytes,
                available: environment.currentAvailableHostBytes
            )
        }
    }

    nonisolated static func recordCancellation(
        lease: DoryOperationLease,
        state: DoryOperationState
    ) throws {
        do {
            _ = try lease.cancelAfterRollback(
                expectedRevision: state.revision,
                stepID: "preflight.cancelled"
            )
        } catch {
            throw MigrationImportTransactionError.operationAndJournal(
                operation: "cancelled before target mutation",
                journal: String(describing: error)
            )
        }
    }

    nonisolated static func recordFailure(
        lease: DoryOperationLease,
        state: DoryOperationState,
        operation: Error
    ) throws {
        do {
            _ = try lease.transition(
                to: state.phase,
                status: .failed,
                expectedRevision: state.revision,
                stepID: "preflight.failed"
            )
        } catch {
            throw MigrationImportTransactionError.operationAndJournal(
                operation: String(describing: operation),
                journal: String(describing: error)
            )
        }
    }
}

private extension PreparedMigrationExecution {
    nonisolated func matches(_ other: PreparedMigrationExecution) -> Bool {
        identity.id == other.identity.id
            && identity.createdAt == other.identity.createdAt
            && operation.completenessPlan == other.operation.completenessPlan
            && operation.journalPlan == other.operation.journalPlan
            && operation.specifications == other.operation.specifications
            && operation.baselineManifests == other.operation.baselineManifests
            && sourceAuthority == other.sourceAuthority
            && targetAuthority == other.targetAuthority
            && capacity == other.capacity
            && sourceVolumeBytes == other.sourceVolumeBytes
    }
}
