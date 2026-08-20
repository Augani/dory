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

public enum DoryWorkspaceRuntimePolicy: String, Codable, CaseIterable, Sendable {
    case legacyCompatibility = "legacy-compatibility"
    case requireResolvedPlan = "require-resolved-plan"
}

public enum DoryWorkspaceRuntimeAuthorizationState: String, Codable, CaseIterable, Sendable {
    case legacyCompatibility = "legacy-compatibility"
    case resolvedPlan = "resolved-plan"
    case requiresReplanning = "requires-replanning"
}

/// Exact runtime-policy authority for a lifecycle transition. Legacy compatibility is explicit
/// and cannot carry plan claims; resolved operation bindings must carry the complete immutable
/// plan identity used by the executor. `runtimeIdentityDigest` binds the full status identity,
/// including a requires-replanning identity when a resolved-policy restore invalidates launch.
public struct DoryWorkspaceRuntimeBinding: Codable, Sendable, Equatable {
    public var policy: DoryWorkspaceRuntimePolicy
    public var authorizationState: DoryWorkspaceRuntimeAuthorizationState
    public var virtualHardwareABIVersion: UInt16
    public var runtimeIdentityDigest: String
    public var resolved: DoryWorkspaceResolvedCondition?

    public init(
        policy: DoryWorkspaceRuntimePolicy,
        authorizationState: DoryWorkspaceRuntimeAuthorizationState,
        virtualHardwareABIVersion: UInt16,
        runtimeIdentityDigest: String,
        resolved: DoryWorkspaceResolvedCondition? = nil
    ) {
        self.policy = policy
        self.authorizationState = authorizationState
        self.virtualHardwareABIVersion = virtualHardwareABIVersion
        self.runtimeIdentityDigest = runtimeIdentityDigest
        self.resolved = resolved
    }

    public static func legacyCompatibility(
        virtualHardwareABIVersion: UInt16,
        runtimeIdentityDigest: String
    ) -> Self {
        Self(
            policy: .legacyCompatibility,
            authorizationState: .legacyCompatibility,
            virtualHardwareABIVersion: virtualHardwareABIVersion,
            runtimeIdentityDigest: runtimeIdentityDigest
        )
    }

    public static func resolvedPlan(
        _ resolved: DoryWorkspaceResolvedCondition,
        runtimeIdentityDigest: String
    ) -> Self {
        Self(
            policy: .requireResolvedPlan,
            authorizationState: .resolvedPlan,
            virtualHardwareABIVersion: resolved.virtualHardwareABIVersion,
            runtimeIdentityDigest: runtimeIdentityDigest,
            resolved: resolved
        )
    }

    public static func requiresReplanning(
        virtualHardwareABIVersion: UInt16,
        runtimeIdentityDigest: String
    ) -> Self {
        Self(
            policy: .requireResolvedPlan,
            authorizationState: .requiresReplanning,
            virtualHardwareABIVersion: virtualHardwareABIVersion,
            runtimeIdentityDigest: runtimeIdentityDigest
        )
    }

    fileprivate var isValid: Bool {
        guard virtualHardwareABIVersion > 0,
              DoryOperationJournalStore.isDigest(runtimeIdentityDigest) else {
            return false
        }
        switch (policy, authorizationState) {
        case (.legacyCompatibility, .legacyCompatibility):
            return resolved == nil
        case (.requireResolvedPlan, .resolvedPlan):
            return resolved?.isValid == true
                && resolved?.virtualHardwareABIVersion == virtualHardwareABIVersion
        case (.requireResolvedPlan, .requiresReplanning):
            return resolved == nil
        default:
            return false
        }
    }
}

/// Content authority only; host paths and configuration values never enter the journal contract.
public struct DoryWorkspaceConfigurationAuthority: Codable, Sendable, Equatable {
    public var legacyConfigurationSHA256: String
    public var canonicalDefinitionSHA256: String?

    public init(
        legacyConfigurationSHA256: String,
        canonicalDefinitionSHA256: String? = nil
    ) {
        self.legacyConfigurationSHA256 = legacyConfigurationSHA256
        self.canonicalDefinitionSHA256 = canonicalDefinitionSHA256
    }

    fileprivate var isValid: Bool {
        DoryOperationJournalStore.isDigest(legacyConfigurationSHA256)
            && (canonicalDefinitionSHA256.map(DoryOperationJournalStore.isDigest) ?? true)
    }
}

public struct DoryWorkspaceLifecycleCondition: Codable, Sendable, Equatable {
    private var persistenceSchemaVersion: UInt16
    public var workspaceID: String
    public var state: DoryWorkspaceLifecycleState
    public var definitionRevision: UInt64?
    public var runtime: DoryWorkspaceRuntimeBinding?
    public var configurationAuthority: DoryWorkspaceConfigurationAuthority?

    /// Read-only source compatibility for schema-v1 inspection. New construction must provide an
    /// exact tagged runtime binding and cannot synthesize an identity digest from a plan digest.
    public var resolved: DoryWorkspaceResolvedCondition? { runtime?.resolved }

    public init(
        workspaceID: String,
        state: DoryWorkspaceLifecycleState,
        definitionRevision: UInt64? = nil,
        runtime: DoryWorkspaceRuntimeBinding? = nil,
        configurationAuthority: DoryWorkspaceConfigurationAuthority? = nil
    ) {
        persistenceSchemaVersion = DoryWorkspaceLifecycleOperation.schemaVersion
        self.workspaceID = workspaceID
        self.state = state
        self.definitionRevision = definitionRevision
        self.runtime = runtime
        self.configurationAuthority = configurationAuthority
    }

    fileprivate var isValid: Bool {
        guard DoryOperationJournalStore.isToken(workspaceID) else { return false }
        if state == .absent {
            return definitionRevision == nil && runtime == nil && configurationAuthority == nil
        }
        return definitionRevision.map { $0 > 0 } == true
            && (runtime?.isValid ?? true)
            && (configurationAuthority?.isValid ?? true)
            && (!(state == .running || state == .paused || state == .suspended)
                || (runtime != nil
                    && runtime?.authorizationState != .requiresReplanning))
    }

    private enum CodingKeys: String, CodingKey {
        case conditionSchemaVersion
        case workspaceID
        case state
        case definitionRevision
        case resolved
        case runtime
        case configurationAuthority
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        state = try container.decode(DoryWorkspaceLifecycleState.self, forKey: .state)
        definitionRevision = try container.decodeIfPresent(UInt64.self, forKey: .definitionRevision)
        if let conditionSchemaVersion = try container.decodeIfPresent(
            UInt16.self,
            forKey: .conditionSchemaVersion
        ) {
            guard conditionSchemaVersion == DoryWorkspaceLifecycleOperation.schemaVersion,
                  !container.contains(.resolved) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .conditionSchemaVersion,
                    in: container,
                    debugDescription: "unsupported workspace lifecycle condition schema"
                )
            }
            persistenceSchemaVersion = DoryWorkspaceLifecycleOperation.schemaVersion
            runtime = try container.decodeIfPresent(
                DoryWorkspaceRuntimeBinding.self,
                forKey: .runtime
            )
            configurationAuthority = try container.decodeIfPresent(
                DoryWorkspaceConfigurationAuthority.self,
                forKey: .configurationAuthority
            )
        } else {
            guard !container.contains(.runtime), !container.contains(.configurationAuthority) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .conditionSchemaVersion,
                    in: container,
                    debugDescription: "workspace lifecycle condition schema marker is required"
                )
            }
            persistenceSchemaVersion = DoryWorkspaceLifecycleOperation.oldestSupportedSchemaVersion
            configurationAuthority = nil
            if let legacyResolved = try container.decodeIfPresent(
                DoryWorkspaceResolvedCondition.self,
                forKey: .resolved
            ) {
                runtime = .resolvedPlan(
                    legacyResolved,
                    runtimeIdentityDigest: legacyResolved.planDigest
                )
            } else {
                runtime = nil
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workspaceID, forKey: .workspaceID)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(definitionRevision, forKey: .definitionRevision)
        if persistenceSchemaVersion == DoryWorkspaceLifecycleOperation.oldestSupportedSchemaVersion {
            try container.encodeIfPresent(runtime?.resolved, forKey: .resolved)
        } else {
            try container.encode(persistenceSchemaVersion, forKey: .conditionSchemaVersion)
            try container.encodeIfPresent(runtime, forKey: .runtime)
            try container.encodeIfPresent(configurationAuthority, forKey: .configurationAuthority)
        }
    }

    fileprivate var encodedSchemaVersion: UInt16 { persistenceSchemaVersion }
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
    public static let oldestSupportedSchemaVersion: UInt16 = 1
    public static let schemaVersion: UInt16 = 2

    public var schemaVersion: UInt16
    public var sourceSchemaVersion: UInt16
    public var operationID: UUID
    public var kind: DoryWorkspaceMutationKind
    public var source: DoryWorkspaceLifecycleCondition
    public var target: DoryWorkspaceLifecycleCondition
    public var targetWorkspaceID: String?
    /// Stable snapshot or clone identity needed for deterministic recovery; never a host path.
    public var targetResourceID: String?
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
        targetResourceID: String? = nil,
        createdAtUnixMilliseconds: Int64,
        deadlineUnixMilliseconds: Int64,
        steps: [DoryWorkspaceOperationStep],
        readinessGates: [DoryWorkspaceReadinessGate] = [],
        retryBudgets: [DoryWorkspaceRetryBudget] = [],
        cancellationPolicy: DoryWorkspaceCancellationPolicy,
        recovery: DoryWorkspaceRecoveryRecipe
    ) {
        schemaVersion = Self.schemaVersion
        sourceSchemaVersion = Self.schemaVersion
        self.operationID = operationID
        self.kind = kind
        self.source = source
        self.target = target
        self.targetWorkspaceID = targetWorkspaceID
        self.targetResourceID = targetResourceID
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

        if !(Self.oldestSupportedSchemaVersion...Self.schemaVersion).contains(schemaVersion)
            || sourceSchemaVersion != schemaVersion
            || source.encodedSchemaVersion != schemaVersion
            || target.encodedSchemaVersion != schemaVersion {
            add(.invalidSchemaVersion, "schemaVersion")
        }
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
        if Self.requiresRuntimeSource(kind), source.runtime == nil {
            add(.invalidCondition, "source")
        }
        if Self.requiresRuntimeTarget(kind), target.runtime == nil {
            add(.invalidCondition, "target")
        }
        if Self.requiresUnchangedRuntimePlan(kind),
           !Self.hasSameRuntimePlan(source.runtime, target.runtime) {
            add(.invalidCondition, "target.runtime")
        }
        if kind == .starting {
            if target.runtime?.authorizationState != .resolvedPlan
                && target.runtime?.authorizationState != .legacyCompatibility {
                add(.invalidCondition, "target.runtime.authorizationState")
            }
            if source.runtime?.policy != target.runtime?.policy {
                add(.invalidCondition, "target.runtime.policy")
            } else if source.runtime?.authorizationState != .requiresReplanning,
                      !Self.hasSameRuntimePlan(source.runtime, target.runtime) {
                add(.invalidCondition, "target.runtime")
            }
        }
        if sourceSchemaVersion == Self.schemaVersion,
           kind == .restoring,
           source.runtime?.policy == .requireResolvedPlan,
           target.runtime?.authorizationState != .requiresReplanning {
            add(.invalidCondition, "target.runtime.authorizationState")
        }
        if source.runtime?.policy != target.runtime?.policy,
           kind != .importing, kind != .provisioning, kind != .resolving {
            add(.invalidCondition, "target.runtime.policy")
        }
        if sourceSchemaVersion == Self.schemaVersion {
            if source.state != .absent, source.configurationAuthority == nil {
                add(.invalidCondition, "source.configurationAuthority")
            }
            if target.state != .absent, target.configurationAuthority == nil {
                add(.invalidCondition, "target.configurationAuthority")
            }
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
        let requiresResourceID = kind == .snapshotting || kind == .restoring || kind == .cloning
        if requiresResourceID {
            if sourceSchemaVersion == Self.schemaVersion,
               targetResourceID.map(DoryOperationJournalStore.isToken) != true {
                add(.invalidTargetWorkspace, "targetResourceID")
            }
        } else if targetResourceID != nil {
            add(.invalidTargetWorkspace, "targetResourceID")
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

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sourceSchemaVersion
        case operationID
        case kind
        case source
        case target
        case targetWorkspaceID
        case targetResourceID
        case createdAtUnixMilliseconds
        case deadlineUnixMilliseconds
        case steps
        case readinessGates
        case retryBudgets
        case cancellationPolicy
        case recovery
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let persistedSchema = try container.decode(UInt16.self, forKey: .schemaVersion)
        guard (Self.oldestSupportedSchemaVersion...Self.schemaVersion).contains(persistedSchema) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "unsupported workspace lifecycle schema"
            )
        }
        schemaVersion = persistedSchema
        sourceSchemaVersion = try container.decodeIfPresent(UInt16.self, forKey: .sourceSchemaVersion)
            ?? persistedSchema
        guard sourceSchemaVersion == persistedSchema else {
            throw DecodingError.dataCorruptedError(
                forKey: .sourceSchemaVersion,
                in: container,
                debugDescription: "workspace lifecycle source schema mismatch"
            )
        }
        operationID = try container.decode(UUID.self, forKey: .operationID)
        kind = try container.decode(DoryWorkspaceMutationKind.self, forKey: .kind)
        source = try container.decode(DoryWorkspaceLifecycleCondition.self, forKey: .source)
        target = try container.decode(DoryWorkspaceLifecycleCondition.self, forKey: .target)
        guard source.encodedSchemaVersion == persistedSchema,
              target.encodedSchemaVersion == persistedSchema else {
            throw DecodingError.dataCorruptedError(
                forKey: .source,
                in: container,
                debugDescription: "workspace lifecycle condition schema mismatch"
            )
        }
        targetWorkspaceID = try container.decodeIfPresent(String.self, forKey: .targetWorkspaceID)
        targetResourceID = try container.decodeIfPresent(String.self, forKey: .targetResourceID)
        createdAtUnixMilliseconds = try container.decode(Int64.self, forKey: .createdAtUnixMilliseconds)
        deadlineUnixMilliseconds = try container.decode(Int64.self, forKey: .deadlineUnixMilliseconds)
        steps = try container.decode([DoryWorkspaceOperationStep].self, forKey: .steps)
        readinessGates = try container.decodeIfPresent(
            [DoryWorkspaceReadinessGate].self,
            forKey: .readinessGates
        ) ?? []
        retryBudgets = try container.decodeIfPresent(
            [DoryWorkspaceRetryBudget].self,
            forKey: .retryBudgets
        ) ?? []
        cancellationPolicy = try container.decode(
            DoryWorkspaceCancellationPolicy.self,
            forKey: .cancellationPolicy
        )
        recovery = try container.decode(DoryWorkspaceRecoveryRecipe.self, forKey: .recovery)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        if schemaVersion == Self.schemaVersion {
            try container.encode(sourceSchemaVersion, forKey: .sourceSchemaVersion)
        }
        try container.encode(operationID, forKey: .operationID)
        try container.encode(kind, forKey: .kind)
        try container.encode(source, forKey: .source)
        try container.encode(target, forKey: .target)
        try container.encodeIfPresent(targetWorkspaceID, forKey: .targetWorkspaceID)
        try container.encodeIfPresent(targetResourceID, forKey: .targetResourceID)
        try container.encode(createdAtUnixMilliseconds, forKey: .createdAtUnixMilliseconds)
        try container.encode(deadlineUnixMilliseconds, forKey: .deadlineUnixMilliseconds)
        try container.encode(steps, forKey: .steps)
        try container.encode(readinessGates, forKey: .readinessGates)
        try container.encode(retryBudgets, forKey: .retryBudgets)
        try container.encode(cancellationPolicy, forKey: .cancellationPolicy)
        try container.encode(recovery, forKey: .recovery)
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

    private static func requiresRuntimeSource(_ kind: DoryWorkspaceMutationKind) -> Bool {
        switch kind {
        case .starting, .stopping, .pausing, .resuming, .suspending, .restoring,
             .snapshotting, .cloning, .updating:
            true
        case .importing, .provisioning, .resolving, .repairing, .deleting:
            false
        }
    }

    private static func requiresRuntimeTarget(_ kind: DoryWorkspaceMutationKind) -> Bool {
        switch kind {
        case .provisioning, .resolving, .starting, .stopping, .pausing, .resuming,
             .suspending, .restoring, .snapshotting, .cloning, .updating, .repairing:
            true
        case .importing, .deleting:
            false
        }
    }

    private static func requiresUnchangedRuntimePlan(_ kind: DoryWorkspaceMutationKind) -> Bool {
        switch kind {
        case .stopping, .pausing, .resuming, .suspending, .snapshotting:
            true
        case .importing, .provisioning, .resolving, .starting, .restoring, .cloning, .updating,
             .repairing, .deleting:
            false
        }
    }

    private static func hasSameRuntimePlan(
        _ source: DoryWorkspaceRuntimeBinding?,
        _ target: DoryWorkspaceRuntimeBinding?
    ) -> Bool {
        guard let source, let target, source.policy == target.policy,
              source.virtualHardwareABIVersion == target.virtualHardwareABIVersion else {
            return false
        }
        return source.authorizationState == target.authorizationState
            && source.runtimeIdentityDigest == target.runtimeIdentityDigest
            && source.resolved == target.resolved
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
            (source == .stopped || source == .suspended || source == .failed
                || source == .running || source == .paused)
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
