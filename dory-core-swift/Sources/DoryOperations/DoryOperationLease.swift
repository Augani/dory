import Foundation

private struct DoryOperationTransitionRequest {
    let phase: DoryOperationPhase
    let status: DoryOperationStatus
    let requestedResult: DoryOperationResult?
    let expectedRevision: UInt64
    let stepID: String
    let recoveryAction: String?
    let date: Date
    let failAfterStatePublish: Bool
}

private struct DoryOperationPreparedTransition {
    let record: DoryOperationRecord
    let result: DoryOperationResult?
}

private struct DoryOperationAuditLog {
    let events: [DoryOperationEvent]
    let completeLength: Int
    let trailingBytes: Int
}

// swiftlint:disable type_body_length
/// Exclusive mutation authority for one Dory home. Keep this object alive for the complete
/// operation attempt. Dropping it releases the advisory lock but does not alter durable state.
public final class DoryOperationLease: @unchecked Sendable {
    public let operationID: UUID

    private let store: DoryOperationJournalStore
    private let lock: EngineStateDirectoryLock
    private let transitionLock = NSLock()

    init(
        store: DoryOperationJournalStore,
        operationID: UUID,
        lock: EngineStateDirectoryLock
    ) {
        self.store = store
        self.operationID = operationID
        self.lock = lock
    }

    public func read() throws -> DoryOperationRecord {
        withExtendedLifetime(lock) {}
        return try store.readRecord(operationID)
    }

    @discardableResult
    public func transition(
        to phase: DoryOperationPhase,
        status: DoryOperationStatus,
        expectedRevision: UInt64,
        stepID: String,
        recoveryAction: String? = nil,
        at date: Date = Date()
    ) throws -> DoryOperationState {
        try transitionImpl(DoryOperationTransitionRequest(
            phase: phase,
            status: status,
            requestedResult: nil,
            expectedRevision: expectedRevision,
            stepID: stepID,
            recoveryAction: recoveryAction,
            date: date,
            failAfterStatePublish: false
        ))
    }

    /// Records cancellation only after operation-owned effects have been rolled back. The failed
    /// status is terminal; the distinct result prevents UI and recovery from calling cancellation
    /// a data-transfer failure.
    @discardableResult
    public func cancelAfterRollback(
        expectedRevision: UInt64,
        stepID: String = "rollback.cancelled",
        at date: Date = Date()
    ) throws -> DoryOperationState {
        let record = try read()
        return try transitionImpl(DoryOperationTransitionRequest(
            phase: record.state.phase,
            status: .failed,
            requestedResult: .cancelled,
            expectedRevision: expectedRevision,
            stepID: stepID,
            recoveryAction: nil,
            date: date,
            failAfterStatePublish: false
        ))
    }

#if DEBUG
    @discardableResult
    func transitionForCrashRecoveryTest(
        to phase: DoryOperationPhase,
        status: DoryOperationStatus,
        expectedRevision: UInt64,
        stepID: String
    ) throws -> DoryOperationState {
        try transitionImpl(DoryOperationTransitionRequest(
            phase: phase,
            status: status,
            requestedResult: nil,
            expectedRevision: expectedRevision,
            stepID: stepID,
            recoveryAction: nil,
            date: Date(),
            failAfterStatePublish: true
        ))
    }
#endif

    public func events() throws -> [DoryOperationEvent] {
        let path = store.operationDirectory(for: operationID) + "/events.ndjson"
        let parsed = try parseAuditLog(path: path, repairTrailingWrite: false)
        guard parsed.trailingBytes == 0 else {
            throw DoryOperationJournalError.invalidRecord(path)
        }
        return parsed.events
    }

    public func mirrorSummary(to drive: DoryDataDrive) throws {
        try drive.validateManifest()
        let record = try read()
        let directory = drive.operationsDirectory
        if !DoryOperationJournalStore.pathEntryExists(directory) {
            try DoryOperationJournalStore.createPrivateDirectory(directory)
            try DoryOperationJournalStore.syncDirectory(drive.root)
        } else {
            try DoryOperationJournalStore.validatePrivateDirectory(directory)
        }
        let path = directory + "/" + operationID.uuidString.lowercased() + ".json"
        try DoryOperationJournalStore.publish(
            try DoryOperationJournalStore.encoded(DoryOperationSummary(record: record), pretty: true),
            to: path
        )
    }

    func reconcileAuditLog() throws {
        let record = try read()
        let path = store.operationDirectory(for: operationID) + "/events.ndjson"
        var parsed = try parseAuditLog(path: path, repairTrailingWrite: true)
        if parsed.trailingBytes > 0 {
            try DoryOperationJournalStore.truncate(path, to: parsed.completeLength)
            parsed = try parseAuditLog(path: path, repairTrailingWrite: false)
        }

        if try auditContainsCurrentState(parsed.events, record: record, path: path) {
            return
        }
        try DoryOperationJournalStore.append(
            try DoryOperationJournalStore.encoded(record.state.lastEvent, pretty: false),
            to: path
        )
    }

    private func transitionImpl(
        _ request: DoryOperationTransitionRequest
    ) throws -> DoryOperationState {
        transitionLock.lock()
        defer { transitionLock.unlock() }
        let prepared = try prepareTransition(request)
        let event = DoryOperationEvent(
            operationID: operationID,
            revision: request.expectedRevision + 1,
            timestamp: request.date,
            phase: request.phase,
            status: request.status,
            result: prepared.result,
            stepID: request.stepID,
            recoveryAction: request.recoveryAction
        )
        let next = DoryOperationState(
            operationID: operationID,
            planDigest: prepared.record.state.planDigest,
            revision: event.revision,
            phase: request.phase,
            status: request.status,
            event: event
        )
        let directory = store.operationDirectory(for: operationID)
        try DoryOperationJournalStore.publish(
            try DoryOperationJournalStore.encoded(next, pretty: true),
            to: directory + "/state.json"
        )
        if request.failAfterStatePublish {
            throw DoryOperationJournalError.filesystem(
                "injected interruption after state publication"
            )
        }
        try DoryOperationJournalStore.append(
            try DoryOperationJournalStore.encoded(event, pretty: false),
            to: directory + "/events.ndjson"
        )
        return next
    }

    private func prepareTransition(
        _ request: DoryOperationTransitionRequest
    ) throws -> DoryOperationPreparedTransition {
        let journalPath = store.operationDirectory(for: operationID)
        guard DoryOperationJournalStore.isToken(request.stepID),
              request.recoveryAction.map(DoryOperationJournalStore.isToken) ?? true else {
            throw DoryOperationJournalError.invalidRecord(journalPath)
        }
        try reconcileAuditLog()
        let record = try read()
        guard record.state.revision == request.expectedRevision else {
            throw DoryOperationJournalError.staleRevision(
                expected: request.expectedRevision,
                actual: record.state.revision
            )
        }
        guard DoryOperationJournalStore.legalTransition(
            from: record.state,
            to: request.phase,
            status: request.status
        ) else {
            throw DoryOperationJournalError.illegalTransition(
                fromPhase: record.state.phase,
                fromStatus: record.state.status,
                toPhase: request.phase,
                toStatus: request.status
            )
        }
        guard request.expectedRevision < UInt64.max else {
            throw DoryOperationJournalError.invalidRecord(journalPath)
        }
        return DoryOperationPreparedTransition(
            record: record,
            result: try terminalResult(for: request, journalPath: journalPath)
        )
    }

    private func terminalResult(
        for request: DoryOperationTransitionRequest,
        journalPath: String
    ) throws -> DoryOperationResult? {
        switch request.status {
        case .completed:
            return .succeeded
        case .failed:
            return request.requestedResult ?? .failed
        default:
            guard request.requestedResult == nil else {
                throw DoryOperationJournalError.invalidRecord(journalPath)
            }
            return nil
        }
    }

    private func auditContainsCurrentState(
        _ events: [DoryOperationEvent],
        record: DoryOperationRecord,
        path: String
    ) throws -> Bool {
        guard let last = events.last else {
            guard record.state.revision == 0 else {
                throw DoryOperationJournalError.invalidRecord(path)
            }
            return false
        }
        guard last.operationID == operationID,
              last.revision <= record.state.revision else {
            throw DoryOperationJournalError.invalidRecord(path)
        }
        if last.revision == record.state.revision {
            guard last == record.state.lastEvent else {
                throw DoryOperationJournalError.invalidRecord(path)
            }
            return true
        }
        guard last.revision + 1 == record.state.revision else {
            throw DoryOperationJournalError.invalidRecord(path)
        }
        return false
    }

    private func parseAuditLog(
        path: String,
        repairTrailingWrite: Bool
    ) throws -> DoryOperationAuditLog {
        let data = try DoryOperationJournalStore.secureRead(
            path,
            maximumBytes: 64 * 1_024 * 1_024
        )
        let completeLength: Int
        if data.isEmpty {
            completeLength = 0
        } else if data.last == 0x0a {
            completeLength = data.count
        } else if let newline = data.lastIndex(of: 0x0a) {
            completeLength = data.distance(from: data.startIndex, to: newline) + 1
        } else {
            completeLength = 0
        }
        let trailingBytes = data.count - completeLength
        if trailingBytes > 0, !repairTrailingWrite {
            return DoryOperationAuditLog(
                events: [],
                completeLength: completeLength,
                trailingBytes: trailingBytes
            )
        }

        let complete = data.prefix(completeLength)
        var events: [DoryOperationEvent] = []
        for line in complete.split(separator: 0x0a, omittingEmptySubsequences: true) {
            guard let event = try? JSONDecoder().decode(DoryOperationEvent.self, from: Data(line)),
                  event.isValid,
                  event.operationID == operationID,
                  event.revision == UInt64(events.count) else {
                throw DoryOperationJournalError.invalidRecord(path)
            }
            events.append(event)
        }
        return DoryOperationAuditLog(
            events: events,
            completeLength: completeLength,
            trailingBytes: trailingBytes
        )
    }
}
// swiftlint:enable type_body_length
