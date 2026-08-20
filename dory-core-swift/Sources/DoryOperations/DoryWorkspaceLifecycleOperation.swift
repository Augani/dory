import Foundation

public enum DoryWorkspaceLifecycleState: String, Codable, CaseIterable, Sendable {
    case absent
    case defined
    case stopped
    case running
    case paused
    case suspended
    case failed
    case deleting
}

public enum DoryWorkspaceMutationKind: String, Codable, CaseIterable, Sendable {
    case importing
    case provisioning
    case resolving
    case starting
    case stopping
    case pausing
    case resuming
    case suspending
    case restoring
    case snapshotting
    case cloning
    case updating
    case repairing
    case deleting

    public var journalKind: DoryOperationKind {
        switch self {
        case .importing: .workspaceImport
        case .provisioning: .workspaceProvision
        case .resolving: .workspaceResolve
        case .starting: .workspaceStart
        case .stopping: .workspaceStop
        case .pausing: .workspacePause
        case .resuming: .workspaceResume
        case .suspending: .workspaceSuspend
        case .restoring: .workspaceRestore
        case .snapshotting: .workspaceSnapshot
        case .cloning: .workspaceClone
        case .updating: .workspaceUpdate
        case .repairing: .workspaceRepair
        case .deleting: .workspaceDelete
        }
    }
}

public struct DoryWorkspaceResolvedCondition: Codable, Sendable, Equatable {
    public var planRevision: UInt64
    public var planDigest: String
    public var backendID: String
    public var backendRuntimeBuildID: String
    public var virtualHardwareABIVersion: UInt16

    public init(
        planRevision: UInt64,
        planDigest: String,
        backendID: String,
        backendRuntimeBuildID: String,
        virtualHardwareABIVersion: UInt16
    ) {
        self.planRevision = planRevision
        self.planDigest = planDigest
        self.backendID = backendID
        self.backendRuntimeBuildID = backendRuntimeBuildID
        self.virtualHardwareABIVersion = virtualHardwareABIVersion
    }

    fileprivate var isValid: Bool {
        planRevision > 0
            && DoryOperationJournalStore.isDigest(planDigest)
            && DoryOperationJournalStore.isToken(backendID)
            && DoryOperationJournalStore.isToken(backendRuntimeBuildID)
            && virtualHardwareABIVersion > 0
    }
}

public struct DoryWorkspaceLifecycleCondition: Codable, Sendable, Equatable {
    public var workspaceID: String
    public var state: DoryWorkspaceLifecycleState
    public var definitionRevision: UInt64?
    public var resolved: DoryWorkspaceResolvedCondition?

    public init(
        workspaceID: String,
        state: DoryWorkspaceLifecycleState,
        definitionRevision: UInt64? = nil,
        resolved: DoryWorkspaceResolvedCondition? = nil
    ) {
        self.workspaceID = workspaceID
        self.state = state
        self.definitionRevision = definitionRevision
        self.resolved = resolved
    }

    fileprivate var isValid: Bool {
        guard DoryOperationJournalStore.isToken(workspaceID) else { return false }
        if state == .absent {
            return definitionRevision == nil && resolved == nil
        }
        return definitionRevision.map { $0 > 0 } == true
            && (resolved?.isValid ?? true)
            && (!(state == .running || state == .paused || state == .suspended)
                || resolved != nil)
    }
}

public enum DoryWorkspaceOperationStage: String, Codable, CaseIterable, Sendable {
    case resolve
    case prepare
    case quiesce
    case mutate
    case launch
    case readiness
    case publish
    case cleanup
    case rollback
}

public struct DoryWorkspaceOperationStep: Codable, Sendable, Equatable {
    public var id: String
    public var stage: DoryWorkspaceOperationStage
    public var deadlineOffsetMilliseconds: UInt64

    public init(
        id: String,
        stage: DoryWorkspaceOperationStage,
        deadlineOffsetMilliseconds: UInt64
    ) {
        self.id = id
        self.stage = stage
        self.deadlineOffsetMilliseconds = deadlineOffsetMilliseconds
    }

    fileprivate var isValid: Bool {
        DoryOperationJournalStore.isToken(id) && deadlineOffsetMilliseconds > 0
    }
}

public enum DoryWorkspaceReadinessGateKind: String, Codable, CaseIterable, Sendable, Hashable {
    case backendRunning
    case firstDisplayFrame
    case guestAgent
    case network
    case storageFlush
}

public struct DoryWorkspaceReadinessGate: Codable, Sendable, Equatable {
    public var kind: DoryWorkspaceReadinessGateKind
    public var required: Bool
    public var deadlineOffsetMilliseconds: UInt64

    public init(
        kind: DoryWorkspaceReadinessGateKind,
        required: Bool = true,
        deadlineOffsetMilliseconds: UInt64
    ) {
        self.kind = kind
        self.required = required
        self.deadlineOffsetMilliseconds = deadlineOffsetMilliseconds
    }
}

public struct DoryWorkspaceRetryBudget: Codable, Sendable, Equatable {
    public var failureClass: String
    public var maximumAttempts: UInt8

    public init(failureClass: String, maximumAttempts: UInt8) {
        self.failureClass = failureClass
        self.maximumAttempts = maximumAttempts
    }

    fileprivate var isValid: Bool {
        DoryOperationJournalStore.isToken(failureClass) && maximumAttempts > 0
    }
}

public enum DoryWorkspaceCancellationPolicy: String, Codable, CaseIterable, Sendable {
    case prohibited
    case beforeGuestMutation
    case beforePublish
    case rollbackRequired
}

public enum DoryWorkspaceRecoveryDisposition: String, Codable, CaseIterable, Sendable {
    case retry
    case rollback
    case repair
    case manualIntervention
}

public struct DoryWorkspaceRecoveryRecipe: Codable, Sendable, Equatable {
    public var disposition: DoryWorkspaceRecoveryDisposition
    public var stepIDs: [String]

    public init(disposition: DoryWorkspaceRecoveryDisposition, stepIDs: [String]) {
        self.disposition = disposition
        self.stepIDs = stepIDs
    }

    fileprivate var isValid: Bool {
        !stepIDs.isEmpty
            && Set(stepIDs).count == stepIDs.count
            && stepIDs.allSatisfy(DoryOperationJournalStore.isToken)
    }
}

public enum DoryWorkspaceOperationValidationCode: String, Codable, Sendable {
    case invalidSchemaVersion
    case invalidOperationID
    case invalidCondition
    case invalidTransition
    case invalidTargetWorkspace
    case invalidDeadline
    case invalidSteps
    case invalidReadinessGates
    case invalidRetryBudgets
    case invalidRecoveryRecipe
}

public struct DoryWorkspaceOperationValidationIssue: Codable, Sendable, Equatable {
    public var code: DoryWorkspaceOperationValidationCode
    public var field: String

    public init(code: DoryWorkspaceOperationValidationCode, field: String) {
        self.code = code
        self.field = field
    }
}

public struct DoryWorkspaceLifecycleJournalBinding: Sendable, Equatable {
    public let plan: DoryOperationPlan
    public let specification: DoryOperationSpecification

    public init(plan: DoryOperationPlan, specification: DoryOperationSpecification) {
        self.plan = plan
        self.specification = specification
    }
}

/// Immutable lifecycle intent bound into the existing crash-safe operation journal.
///
/// This object contains no host paths, credentials, or mutable runtime handles. Executors append
/// actual progress to `DoryOperationJournalStore`; this specification is the exact transition,
/// deadline, retry, readiness, cancellation, and recovery contract they must follow.
public struct DoryWorkspaceLifecycleOperation: Codable, Sendable, Equatable {
    public static let schemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var operationID: UUID
    public var kind: DoryWorkspaceMutationKind
    public var source: DoryWorkspaceLifecycleCondition
    public var target: DoryWorkspaceLifecycleCondition
    public var targetWorkspaceID: String?
    public var createdAtUnixMilliseconds: Int64
    public var deadlineUnixMilliseconds: Int64
    public var steps: [DoryWorkspaceOperationStep]
    public var readinessGates: [DoryWorkspaceReadinessGate]
    public var retryBudgets: [DoryWorkspaceRetryBudget]
    public var cancellationPolicy: DoryWorkspaceCancellationPolicy
    public var recovery: DoryWorkspaceRecoveryRecipe

    public init(
        operationID: UUID = UUID(),
        kind: DoryWorkspaceMutationKind,
        source: DoryWorkspaceLifecycleCondition,
        target: DoryWorkspaceLifecycleCondition,
        targetWorkspaceID: String? = nil,
        createdAtUnixMilliseconds: Int64,
        deadlineUnixMilliseconds: Int64,
        steps: [DoryWorkspaceOperationStep],
        readinessGates: [DoryWorkspaceReadinessGate] = [],
        retryBudgets: [DoryWorkspaceRetryBudget] = [],
        cancellationPolicy: DoryWorkspaceCancellationPolicy,
        recovery: DoryWorkspaceRecoveryRecipe
    ) {
        schemaVersion = Self.schemaVersion
        self.operationID = operationID
        self.kind = kind
        self.source = source
        self.target = target
        self.targetWorkspaceID = targetWorkspaceID
        self.createdAtUnixMilliseconds = createdAtUnixMilliseconds
        self.deadlineUnixMilliseconds = deadlineUnixMilliseconds
        self.steps = steps
        self.readinessGates = readinessGates
        self.retryBudgets = retryBudgets
        self.cancellationPolicy = cancellationPolicy
        self.recovery = recovery
    }

    public func validate() -> [DoryWorkspaceOperationValidationIssue] {
        var issues: [DoryWorkspaceOperationValidationIssue] = []
        func add(_ code: DoryWorkspaceOperationValidationCode, _ field: String) {
            issues.append(DoryWorkspaceOperationValidationIssue(code: code, field: field))
        }

        if schemaVersion != Self.schemaVersion { add(.invalidSchemaVersion, "schemaVersion") }
        if operationID == UUID.zero { add(.invalidOperationID, "operationID") }
        if !source.isValid { add(.invalidCondition, "source") }
        if !target.isValid { add(.invalidCondition, "target") }
        if kind == .cloning {
            if targetWorkspaceID != target.workspaceID {
                add(.invalidTargetWorkspace, "targetWorkspaceID")
            }
        } else if source.workspaceID != target.workspaceID {
            add(.invalidCondition, "target.workspaceID")
        }
        if Self.requiresResolvedSource(kind), source.resolved == nil {
            add(.invalidCondition, "source")
        }
        if Self.requiresResolvedTarget(kind), target.resolved == nil {
            add(.invalidCondition, "target")
        }
        if Self.requiresUnchangedResolvedPlan(kind), source.resolved != target.resolved {
            add(.invalidCondition, "target.resolved")
        }
        if !Self.allows(kind: kind, source: source.state, target: target.state) {
            add(.invalidTransition, "target.state")
        }
        let validTargetWorkspace = targetWorkspaceID.map {
            DoryOperationJournalStore.isToken($0) && $0 != source.workspaceID
        }
        if kind == .cloning {
            if validTargetWorkspace != true { add(.invalidTargetWorkspace, "targetWorkspaceID") }
        } else if targetWorkspaceID != nil {
            add(.invalidTargetWorkspace, "targetWorkspaceID")
        }
        if createdAtUnixMilliseconds < 0
            || deadlineUnixMilliseconds <= createdAtUnixMilliseconds {
            add(.invalidDeadline, "deadlineUnixMilliseconds")
        }

        let stepIDs = steps.map(\.id)
        let stepDeadlines = steps.map(\.deadlineOffsetMilliseconds)
        if steps.isEmpty
            || !steps.allSatisfy(\.isValid)
            || Set(stepIDs).count != stepIDs.count
            || stepDeadlines != stepDeadlines.sorted()
            || stepDeadlines.last.map(deadlineContains(offset:)) != true {
            add(.invalidSteps, "steps")
        }

        let gateKinds = readinessGates.map(\.kind)
        if Set(gateKinds).count != gateKinds.count
            || readinessGates.contains(where: {
                $0.deadlineOffsetMilliseconds == 0
                    || !deadlineContains(offset: $0.deadlineOffsetMilliseconds)
            })
            || (Self.requiresBackendReadiness(kind, targetState: target.state)
                && !readinessGates.contains(where: { $0.kind == .backendRunning && $0.required })) {
            add(.invalidReadinessGates, "readinessGates")
        }

        let failureClasses = retryBudgets.map(\.failureClass)
        if Set(failureClasses).count != failureClasses.count
            || !retryBudgets.allSatisfy(\.isValid) {
            add(.invalidRetryBudgets, "retryBudgets")
        }
        if !recovery.isValid || !Set(recovery.stepIDs).isSubset(of: Set(stepIDs)) {
            add(.invalidRecoveryRecipe, "recovery")
        }
        return issues
    }

    public func journalSpecification() throws -> DoryOperationSpecification {
        let issues = validate()
        guard issues.isEmpty else {
            let fields = issues.map { "\($0.code.rawValue):\($0.field)" }.joined(separator: ",")
            throw DoryOperationJournalError.invalidPlan("workspace lifecycle contract \(fields)")
        }
        return try DoryOperationSpecification(canonical: self)
    }

    /// Creates the immutable journal plan and the exact specification bytes it selects.
    /// `dependencyClosureDigest` binds the separately resolved component/media closure.
    public func journalBinding(
        dependencyClosureDigest: String
    ) throws -> DoryWorkspaceLifecycleJournalBinding {
        guard DoryOperationJournalStore.isDigest(dependencyClosureDigest) else {
            throw DoryOperationJournalError.invalidPlan(
                "workspace lifecycle dependency closure digest"
            )
        }
        let specification = try journalSpecification()
        let sourceFingerprint = DoryOperationJournalStore.digest(
            try DoryOperationJournalStore.encoded(source, pretty: false)
        )
        let targetFingerprint = DoryOperationJournalStore.digest(
            try DoryOperationJournalStore.encoded(target, pretty: false)
        )
        let plan = DoryOperationPlan(
            id: operationID,
            kind: kind.journalKind,
            createdAt: Date(timeIntervalSince1970: Double(createdAtUnixMilliseconds) / 1_000),
            source: DoryOperationAuthority(
                kind: .workspace,
                id: source.workspaceID,
                fingerprint: sourceFingerprint
            ),
            target: DoryOperationAuthority(
                kind: .workspace,
                id: target.workspaceID,
                fingerprint: targetFingerprint
            ),
            selectionDigest: specification.digest,
            dependencyClosureDigest: dependencyClosureDigest,
            successCriteriaDigest: targetFingerprint
        )
        return DoryWorkspaceLifecycleJournalBinding(
            plan: plan,
            specification: specification
        )
    }

    private static func requiresBackendReadiness(
        _ kind: DoryWorkspaceMutationKind,
        targetState: DoryWorkspaceLifecycleState
    ) -> Bool {
        kind == .starting || kind == .resuming
            || (kind == .restoring && targetState == .running)
    }

    private static func requiresResolvedSource(_ kind: DoryWorkspaceMutationKind) -> Bool {
        switch kind {
        case .starting, .stopping, .pausing, .resuming, .suspending, .restoring,
             .snapshotting, .cloning, .updating:
            true
        case .importing, .provisioning, .resolving, .repairing, .deleting:
            false
        }
    }

    private static func requiresResolvedTarget(_ kind: DoryWorkspaceMutationKind) -> Bool {
        switch kind {
        case .provisioning, .resolving, .starting, .stopping, .pausing, .resuming,
             .suspending, .restoring, .snapshotting, .cloning, .updating, .repairing:
            true
        case .importing, .deleting:
            false
        }
    }

    private static func requiresUnchangedResolvedPlan(_ kind: DoryWorkspaceMutationKind) -> Bool {
        switch kind {
        case .starting, .stopping, .pausing, .resuming, .suspending, .snapshotting:
            true
        case .importing, .provisioning, .resolving, .restoring, .cloning, .updating,
             .repairing, .deleting:
            false
        }
    }

    private func deadlineContains(offset: UInt64) -> Bool {
        guard createdAtUnixMilliseconds >= 0,
              deadlineUnixMilliseconds > createdAtUnixMilliseconds,
              offset <= UInt64(Int64.max) else {
            return false
        }
        let signedOffset = Int64(offset)
        guard createdAtUnixMilliseconds <= Int64.max - signedOffset else { return false }
        return createdAtUnixMilliseconds + signedOffset <= deadlineUnixMilliseconds
    }

    private static func allows(
        kind: DoryWorkspaceMutationKind,
        source: DoryWorkspaceLifecycleState,
        target: DoryWorkspaceLifecycleState
    ) -> Bool {
        switch kind {
        case .importing: source == .absent && target == .defined
        case .provisioning: source == .defined && target == .stopped
        case .resolving:
            source != .absent && source != .deleting && target == source
        case .starting: source == .stopped && target == .running
        case .stopping: (source == .running || source == .paused) && target == .stopped
        case .pausing: source == .running && target == .paused
        case .resuming: source == .paused && target == .running
        case .suspending:
            (source == .running || source == .paused) && target == .suspended
        case .restoring:
            (source == .stopped || source == .suspended || source == .failed)
                && (target == .stopped || target == .running)
        case .snapshotting:
            (source == .stopped || source == .running || source == .paused)
                && target == source
        case .cloning:
            (source == .stopped || source == .suspended) && target == .stopped
        case .updating:
            (source == .stopped || source == .running) && target == source
        case .repairing: source == .failed && target == .stopped
        case .deleting:
            source != .absent && source != .deleting && target == .deleting
        }
    }
}

extension DoryOperationJournalStore {
    /// Atomically publishes a workspace lifecycle journal and its exact immutable contract.
    public func begin(
        _ binding: DoryWorkspaceLifecycleJournalBinding,
        fileManager: FileManager = .default
    ) throws -> DoryOperationLease {
        let operation: DoryWorkspaceLifecycleOperation
        do {
            operation = try JSONDecoder().decode(
                DoryWorkspaceLifecycleOperation.self,
                from: binding.specification.data
            )
        } catch {
            throw DoryOperationJournalError.invalidPlan(
                "workspace lifecycle specification decoding"
            )
        }
        let expected = try operation.journalBinding(
            dependencyClosureDigest: binding.plan.dependencyClosureDigest
        )
        guard expected == binding else {
            throw DoryOperationJournalError.invalidPlan(
                "workspace lifecycle journal binding mismatch"
            )
        }
        return try begin(
            binding.plan,
            completenessPlanData: nil,
            specifications: [binding.specification],
            at: Date(
                timeIntervalSince1970: Double(operation.createdAtUnixMilliseconds) / 1_000
            ),
            fileManager: fileManager
        )
    }
}

extension DoryOperationLease {
    /// Reloads and rebinds the immutable lifecycle contract after restart.
    public func readWorkspaceLifecycleOperation() throws -> DoryWorkspaceLifecycleOperation {
        let record = try read()
        let data = try readSpecification(digest: record.plan.selectionDigest)
        let operation: DoryWorkspaceLifecycleOperation
        do {
            operation = try JSONDecoder().decode(DoryWorkspaceLifecycleOperation.self, from: data)
        } catch {
            throw DoryOperationJournalError.invalidRecord(operationDirectory)
        }
        guard let expected = try? operation.journalBinding(
            dependencyClosureDigest: record.plan.dependencyClosureDigest
        ), expected.plan == record.plan, expected.specification.data == data else {
            throw DoryOperationJournalError.invalidRecord(operationDirectory)
        }
        return operation
    }
}

private extension UUID {
    static let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}
