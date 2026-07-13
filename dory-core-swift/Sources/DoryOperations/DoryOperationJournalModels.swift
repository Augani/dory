import Foundation

public enum DoryOperationKind: String, Codable, CaseIterable, Sendable {
    case competitorImport
    case driveBackup
    case driveRestore
    case driveRelocation
    case driveUpgrade
}

public enum DoryOperationAuthorityKind: String, Codable, CaseIterable, Sendable {
    case dockerEngine
    case dataDrive
    case backupArchive
    case filesystem
}

public enum DoryOperationPhase: String, Codable, CaseIterable, Sendable {
    case planned
    case quiescing
    case staging
    case verifying
    case readyToPublish
    case publishing
    case validating
    case completed

    var index: Int {
        Self.allCases.firstIndex(of: self)!
    }
}

public enum DoryOperationStatus: String, Codable, CaseIterable, Sendable {
    case running
    case interrupted
    case blocked
    case rollingBack
    case needsRecovery
    case failed
    case completed
}

public enum DoryOperationResult: String, Codable, CaseIterable, Sendable {
    case succeeded
    case failed
    case cancelled
}

public enum DoryOperationJournalError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidPlan(String)
    case invalidRecord(String)
    case operationExists(UUID)
    case operationNotFound(UUID)
    case operationInUse(String)
    case staleRevision(expected: UInt64, actual: UInt64)
    case illegalTransition(
        fromPhase: DoryOperationPhase,
        fromStatus: DoryOperationStatus,
        toPhase: DoryOperationPhase,
        toStatus: DoryOperationStatus
    )
    case filesystem(String)

    public var description: String {
        switch self {
        case let .invalidPlan(message):
            return "invalid Dory operation plan: \(message)"
        case let .invalidRecord(path):
            return "invalid Dory operation journal: \(path)"
        case let .operationExists(id):
            return "Dory operation already exists: \(id.uuidString.lowercased())"
        case let .operationNotFound(id):
            return "Dory operation does not exist: \(id.uuidString.lowercased())"
        case let .operationInUse(message):
            return message
        case let .staleRevision(expected, actual):
            return "stale Dory operation revision: expected \(expected), found \(actual)"
        case let .illegalTransition(fromPhase, fromStatus, toPhase, toStatus):
            return "illegal Dory operation transition from \(fromPhase.rawValue)/\(fromStatus.rawValue) "
                + "to \(toPhase.rawValue)/\(toStatus.rawValue)"
        case let .filesystem(message):
            return message
        }
    }
}

public struct DoryOperationAuthority: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let kind: DoryOperationAuthorityKind
    public let id: String
    public let fingerprint: String

    public init(kind: DoryOperationAuthorityKind, id: String, fingerprint: String) {
        schemaVersion = Self.schemaVersion
        self.kind = kind
        self.id = id
        self.fingerprint = fingerprint
    }

    var isValid: Bool {
        schemaVersion == Self.schemaVersion
            && DoryOperationJournalStore.isPrivateText(id, maximumLength: 512)
            && DoryOperationJournalStore.isDigest(fingerprint)
    }
}

/// Immutable authority and completeness fingerprints for one data operation.
///
/// Object specifications and manifests live in private content-addressed files below the operation
/// directory. Their digests are bound here so a resumed operation cannot silently mix plans.
public struct DoryOperationPlan: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let kind: DoryOperationKind
    public let createdAt: String
    public let source: DoryOperationAuthority
    public let target: DoryOperationAuthority
    public let selectionDigest: String
    public let dependencyClosureDigest: String
    public let successCriteriaDigest: String

    public init(
        id: UUID = UUID(),
        kind: DoryOperationKind,
        createdAt: Date = Date(),
        source: DoryOperationAuthority,
        target: DoryOperationAuthority,
        selectionDigest: String,
        dependencyClosureDigest: String,
        successCriteriaDigest: String
    ) {
        schemaVersion = Self.schemaVersion
        self.id = id
        self.kind = kind
        self.createdAt = DoryOperationJournalStore.timestamp(createdAt)
        self.source = source
        self.target = target
        self.selectionDigest = selectionDigest
        self.dependencyClosureDigest = dependencyClosureDigest
        self.successCriteriaDigest = successCriteriaDigest
    }

    var isValid: Bool {
        schemaVersion == Self.schemaVersion
            && DoryOperationJournalStore.isTimestamp(createdAt)
            && source.isValid
            && target.isValid
            && DoryOperationJournalStore.isDigest(selectionDigest)
            && DoryOperationJournalStore.isDigest(dependencyClosureDigest)
            && DoryOperationJournalStore.isDigest(successCriteriaDigest)
    }
}

public struct DoryOperationEvent: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let operationID: UUID
    public let revision: UInt64
    public let timestamp: String
    public let phase: DoryOperationPhase
    public let status: DoryOperationStatus
    public let result: DoryOperationResult?
    public let stepID: String
    public let recoveryAction: String?

    init(
        operationID: UUID,
        revision: UInt64,
        timestamp: Date,
        phase: DoryOperationPhase,
        status: DoryOperationStatus,
        result: DoryOperationResult?,
        stepID: String,
        recoveryAction: String?
    ) {
        schemaVersion = Self.schemaVersion
        self.operationID = operationID
        self.revision = revision
        self.timestamp = DoryOperationJournalStore.timestamp(timestamp)
        self.phase = phase
        self.status = status
        self.result = result
        self.stepID = stepID
        self.recoveryAction = recoveryAction
    }

    var isValid: Bool {
        schemaVersion == Self.schemaVersion
            && DoryOperationJournalStore.isTimestamp(timestamp)
            && DoryOperationJournalStore.isToken(stepID)
            && (recoveryAction.map(DoryOperationJournalStore.isToken) ?? true)
    }
}

public struct DoryOperationState: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let operationID: UUID
    public let planDigest: String
    public let revision: UInt64
    public let phase: DoryOperationPhase
    public let status: DoryOperationStatus
    public let result: DoryOperationResult?
    public let updatedAt: String
    public let lastEvent: DoryOperationEvent

    init(
        operationID: UUID,
        planDigest: String,
        revision: UInt64,
        phase: DoryOperationPhase,
        status: DoryOperationStatus,
        event: DoryOperationEvent
    ) {
        schemaVersion = Self.schemaVersion
        self.operationID = operationID
        self.planDigest = planDigest
        self.revision = revision
        self.phase = phase
        self.status = status
        result = event.result
        updatedAt = event.timestamp
        lastEvent = event
    }

    var isStructurallyValid: Bool {
        schemaVersion == Self.schemaVersion
            && DoryOperationJournalStore.isDigest(planDigest)
            && DoryOperationJournalStore.isTimestamp(updatedAt)
            && lastEvent.isValid
            && lastEvent.operationID == operationID
            && lastEvent.revision == revision
            && lastEvent.phase == phase
            && lastEvent.status == status
            && lastEvent.result == result
            && lastEvent.timestamp == updatedAt
            && ((phase == .completed) == (status == .completed))
            && Self.validResult(status: status, result: result)
    }

    static func validResult(
        status: DoryOperationStatus,
        result: DoryOperationResult?
    ) -> Bool {
        switch (status, result) {
        case (.completed, .succeeded), (.failed, .failed), (.failed, .cancelled):
            return true
        case (_, nil) where status != .completed && status != .failed:
            return true
        default:
            return false
        }
    }
}

public struct DoryOperationRecord: Sendable, Equatable {
    public let plan: DoryOperationPlan
    public let state: DoryOperationState
}

public struct DoryOperationSummary: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let operationID: UUID
    public let kind: DoryOperationKind
    public let planDigest: String
    public let revision: UInt64
    public let phase: DoryOperationPhase
    public let status: DoryOperationStatus
    public let result: DoryOperationResult?
    public let updatedAt: String

    init(record: DoryOperationRecord) {
        schemaVersion = Self.schemaVersion
        operationID = record.plan.id
        kind = record.plan.kind
        planDigest = record.state.planDigest
        revision = record.state.revision
        phase = record.state.phase
        status = record.state.status
        result = record.state.result
        updatedAt = record.state.updatedAt
    }
}
