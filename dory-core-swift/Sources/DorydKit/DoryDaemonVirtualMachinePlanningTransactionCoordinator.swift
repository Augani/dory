import CryptoKit
import Darwin
import DoryOperations
import Foundation

public enum DoryDaemonVirtualMachineWorkspacePublication: Codable, Sendable, Equatable {
    case create
    case replace(expectedRevision: UInt64)
    /// The exact canonical definition is already authoritative (including a facts-bound legacy
    /// projection). Planning publishes only the resolved plan and never spuriously bumps it.
    case retainExistingExact
}

public struct DoryDaemonVirtualMachinePlanningTransactionRequest: Sendable {
    public var planning: DoryDaemonVirtualMachinePlanningRequest
    public var workspacePublication: DoryDaemonVirtualMachineWorkspacePublication
    public var resourceRequirements: [DoryVMResourceRequirement]
    public var startingLeaseDurationMilliseconds: Int64

    public init(
        planning: DoryDaemonVirtualMachinePlanningRequest,
        workspacePublication: DoryDaemonVirtualMachineWorkspacePublication,
        resourceRequirements: [DoryVMResourceRequirement] = [],
        startingLeaseDurationMilliseconds: Int64 = 120_000
    ) {
        self.planning = planning
        self.workspacePublication = workspacePublication
        self.resourceRequirements = resourceRequirements
        self.startingLeaseDurationMilliseconds = startingLeaseDurationMilliseconds
    }
}

/// One-use daemon authority. It re-resolves media, helper, host identity, and signed
/// qualification immediately before desired-state publication. Start obtains a separate token.
public final class DoryDaemonVirtualMachinePlanningPublicationAuthorization:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var consumed = false
    private let operation: @Sendable () throws -> Void

    init(operation: @escaping @Sendable () throws -> Void) {
        self.operation = operation
    }

    public func authorize() throws {
        try lock.withLock {
            guard !consumed else {
                throw DoryDaemonVirtualMachinePlanningTransactionFailure(
                    code: .publicationAuthorizationRejected,
                    message: "Planning publication authorization was already consumed."
                )
            }
            consumed = true
            try operation()
        }
    }
}

/// Daemon-owned, non-Codable resolution. API/UI callers cannot supply trusted facts or tokens.
public struct DoryDaemonVirtualMachinePlanningTrustPreparation: Sendable {
    public var hostResources: DoryVMHostResources
    public var snapshot: @Sendable (
        DoryResolvedMachineResourceAdmissionEvidence
    ) -> DoryDaemonVirtualMachineTrustedInventorySnapshot
    public var publicationAuthorization:
        DoryDaemonVirtualMachinePlanningPublicationAuthorization

    public init(
        hostResources: DoryVMHostResources,
        snapshot: @escaping @Sendable (
            DoryResolvedMachineResourceAdmissionEvidence
        ) -> DoryDaemonVirtualMachineTrustedInventorySnapshot,
        publicationAuthorization:
            DoryDaemonVirtualMachinePlanningPublicationAuthorization
    ) {
        self.hostResources = hostResources
        self.snapshot = snapshot
        self.publicationAuthorization = publicationAuthorization
    }
}

public protocol DoryDaemonVirtualMachinePlanningTrustPreparing: Sendable {
    func preparePlanningTrust(
        for request: DoryDaemonVirtualMachineInventoryRequest
    ) throws -> DoryDaemonVirtualMachinePlanningTrustPreparation
}

/// Content-only authority captured while the MachineManager owns the workspace mutation fence.
/// Raw legacy bytes, host paths, and migration inputs stay daemon-local; their exact digests bind
/// the planning request and durable transaction journal without persisting secrets.
public struct DoryDaemonVirtualMachinePlanningMachineAuthority:
    Codable, Sendable, Equatable
{
    public static let schemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var machineID: String
    public var legacyConfigurationSHA256: String
    public var migrationFactsSHA256: String
    public var sourceDefinitionRevision: UInt64
    public var sourceDefinitionSHA256: String
    public var runtimeIdentitySHA256: String

    public init(
        machineID: String,
        legacyConfigurationSHA256: String,
        migrationFactsSHA256: String,
        sourceDefinitionRevision: UInt64,
        sourceDefinitionSHA256: String,
        runtimeIdentitySHA256: String
    ) {
        schemaVersion = Self.schemaVersion
        self.machineID = machineID
        self.legacyConfigurationSHA256 = legacyConfigurationSHA256.lowercased()
        self.migrationFactsSHA256 = migrationFactsSHA256.lowercased()
        self.sourceDefinitionRevision = sourceDefinitionRevision
        self.sourceDefinitionSHA256 = sourceDefinitionSHA256.lowercased()
        self.runtimeIdentitySHA256 = runtimeIdentitySHA256.lowercased()
    }

    public var isValid: Bool {
        schemaVersion == Self.schemaVersion
            && machineID.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/) != nil
            && !machineID.hasPrefix(".")
            && sourceDefinitionRevision > 0
            && Self.isSHA256(legacyConfigurationSHA256)
            && Self.isSHA256(migrationFactsSHA256)
            && Self.isSHA256(sourceDefinitionSHA256)
            && Self.isSHA256(runtimeIdentitySHA256)
    }

    public var authoritySHA256: String {
        guard isValid else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

/// Held for the whole transaction. A MachineManager-backed implementation owns the lifecycle
/// operation fence and validates authoritative machine bytes/migration facts against `definition`.
/// The coordinator has no unsafe default: production composition must provide this authority.
public final class DoryDaemonVirtualMachinePlanningMutationFence: @unchecked Sendable {
    public let authority: DoryDaemonVirtualMachinePlanningMachineAuthority
    public var authoritySHA256: String { authority.authoritySHA256 }

    private let stateLock = NSLock()
    private var finalized = false
    private let validation: @Sendable () throws -> Void
    private let completion: @Sendable () throws -> Void
    private let recoveryRelease: @Sendable () -> Void
    private let retainedAuthority: any Sendable

    public init(
        authority: DoryDaemonVirtualMachinePlanningMachineAuthority,
        retainedAuthority: any Sendable,
        validation: @escaping @Sendable () throws -> Void,
        completion: @escaping @Sendable () throws -> Void = {},
        recoveryRelease: @escaping @Sendable () -> Void = {}
    ) {
        self.authority = authority
        self.retainedAuthority = retainedAuthority
        self.validation = validation
        self.completion = completion
        self.recoveryRelease = recoveryRelease
    }

    public func revalidate() throws {
        _ = retainedAuthority
        try validation()
    }

    /// Marks both planning publication and its retained MachineManager lifecycle authority
    /// complete. If this throws, the durable nonterminal lifecycle record remains recoverable.
    public func complete() throws {
        try stateLock.withLock {
            guard !finalized else { return }
            try completion()
            finalized = true
        }
    }

    /// Releases only the live lock. Durable state is intentionally left nonterminal so daemon
    /// restart can reacquire the exact transaction rather than fabricating completion.
    public func releaseForRecovery() {
        stateLock.withLock {
            guard !finalized else { return }
            finalized = true
            recoveryRelease()
        }
    }

    deinit { releaseForRecovery() }
}

public protocol DoryDaemonVirtualMachinePlanningMutationAuthorizing: Sendable {
    func acquirePlanningMutationFence(
        machine: DoryMachineConfiguration,
        definition: DoryVirtualMachineDefinition,
        canonicalDefinitionData: Data
    ) throws -> DoryDaemonVirtualMachinePlanningMutationFence
}

public enum DoryDaemonVirtualMachinePlanningTransactionFailureCode:
    String, Sendable, Equatable
{
    case invalidRequest = "invalid-request"
    case mutationAuthorityRejected = "mutation-authority-rejected"
    case transactionConflict = "transaction-conflict"
    case transactionAborted = "transaction-aborted"
    case recoveryRequired = "recovery-required"
    case trustUnavailable = "trust-unavailable"
    case resourceReservationRejected = "resource-reservation-rejected"
    case planConstructionRejected = "plan-construction-rejected"
    case planBindingRejected = "plan-binding-rejected"
    case publicationAuthorizationRejected = "publication-authorization-rejected"
    case workspacePublicationRejected = "workspace-publication-rejected"
    case planPublicationRejected = "plan-publication-rejected"
    case invalidJournal = "invalid-journal"
    case filesystem = "filesystem"
}

public struct DoryDaemonVirtualMachinePlanningTransactionFailure:
    Error, Sendable, Equatable
{
    public var code: DoryDaemonVirtualMachinePlanningTransactionFailureCode
    public var message: String

    public init(
        code: DoryDaemonVirtualMachinePlanningTransactionFailureCode,
        message: String
    ) {
        self.code = code
        self.message = message
    }
}

public struct DoryDaemonVirtualMachinePlanningTransactionResult: Sendable {
    public var planning: DoryDaemonVirtualMachinePlanningResult
    public var lease: DoryVirtualMachineResourceAdmissionLease
    public var transactionID: String

    public init(
        planning: DoryDaemonVirtualMachinePlanningResult,
        lease: DoryVirtualMachineResourceAdmissionLease,
        transactionID: String
    ) {
        self.planning = planning
        self.lease = lease
        self.transactionID = transactionID
    }
}

public protocol DoryWorkspaceDefinitionStoring: Sendable {
    func create(_ definition: DoryVirtualMachineDefinition) throws
    func replace(_ definition: DoryVirtualMachineDefinition, expectedRevision: UInt64) throws
    func read(id: String) throws -> DoryVirtualMachineDefinition
    func readIfPresent(id: String) throws -> DoryVirtualMachineDefinition?
    func readPersistedRecordIfPresent(id: String) throws -> DoryWorkspaceRepositoryRecord?
}

extension DoryWorkspaceRepository: DoryWorkspaceDefinitionStoring {
    public func readIfPresent(id: String) throws -> DoryVirtualMachineDefinition? {
        do { return try read(id: id) }
        catch DoryWorkspaceRepositoryError.workspaceNotFound { return nil }
    }

    public func readPersistedRecordIfPresent(
        id: String
    ) throws -> DoryWorkspaceRepositoryRecord? {
        do { return try readPersistedRecord(id: id) }
        catch DoryWorkspaceRepositoryError.workspaceNotFound { return nil }
    }
}

public protocol DoryPlanningTransactionResolvedPlanStoring:
    DoryResolvedMachinePlanStoring
{
    func readIfPresent(id: String) throws -> DoryResolvedMachinePlan?
}

extension DoryResolvedMachinePlanRepository: DoryPlanningTransactionResolvedPlanStoring {
    public func readIfPresent(id: String) throws -> DoryResolvedMachinePlan? {
        do { return try read(id: id) }
        catch DoryResolvedMachinePlanRepositoryError.planNotFound { return nil }
    }
}

/// Crash-safe reserve -> exact-plan-bind -> desired-state publication transaction.
///
/// `DoryWorkspaceRepository` and `DoryResolvedMachinePlanRepository` remain independently atomic.
/// This coordinator serializes all participating transaction writers with a per-workspace flock;
/// the durable journal makes the two publications recoverable and every intermediate state fails
/// closed because definition and plan digests/revisions cannot both match until completion.
public final class DoryDaemonVirtualMachinePlanningTransactionCoordinator:
    @unchecked Sendable
{
    public enum PublicationStage: Sendable, Equatable {
        case preparedJournalPublished
        case resourceReservationCommitted
        case reservedJournalPublished
        case candidateJournalPublished
        case planBindingCommitted
        case boundJournalPublished
        case publicationAuthorized
        case workspacePublished
        case workspaceJournalPublished
        case planPublished
        case planJournalPublished
        case completeJournalPublished
    }

    private enum Phase: String, Codable, Sendable {
        case prepared
        case reserved
        case candidatePrepared = "candidate-prepared"
        case bound
        case workspacePublished = "workspace-published"
        case planPublished = "plan-published"
        case complete
        case aborted
        case recoveryRequired = "recovery-required"
    }

    private struct Journal: Codable, Sendable, Equatable {
        static let schemaVersion: UInt16 = 1
        var schemaVersion: UInt16 = schemaVersion
        var transactionID: String
        var phase: Phase
        var requestSHA256: String
        var machineAuthoritySHA256: String
        var definition: DoryVirtualMachineDefinition
        var definitionSHA256: String
        var sourceDefinitionSHA256: String?
        var sourceDefinitionRevision: UInt64?
        var workspacePublication: DoryDaemonVirtualMachineWorkspacePublication
        var planPublication: PlanPublicationRecord
        var sourcePlanSHA256: String?
        var sourcePlanRevision: UInt64?
        var plannedAtUnixMilliseconds: Int64
        var leaseID: String?
        var leaseRevision: UInt64?
        /// Exact sorted-key plan bytes. Recovery publishes these bytes, never a live re-plan.
        var candidatePlanData: Data?
        var candidatePlanSHA256: String?
        var candidatePlannerRequest: DoryVirtualMachineBackendPlanRequest?
        var candidatePlannerResult: DoryVirtualMachineBackendPlanResult?
    }

    private enum PlanPublicationRecord: Codable, Sendable, Equatable {
        case create
        case replace(expectedRevision: UInt64)

        init(_ publication: DoryDaemonVirtualMachinePlanPublication) {
            switch publication {
            case .create: self = .create
            case let .replace(expected): self = .replace(expectedRevision: expected)
            }
        }
    }

    private struct JournalEnvelope: Codable {
        var journalSHA256: String
        var journal: Journal
    }

    private final class CapturePlanStore: DoryResolvedMachinePlanStoring,
        @unchecked Sendable
    {
        private let source: any DoryPlanningTransactionResolvedPlanStoring
        private(set) var captured: DoryResolvedMachinePlan?

        init(source: any DoryPlanningTransactionResolvedPlanStoring) { self.source = source }
        func create(_ plan: DoryResolvedMachinePlan) throws { captured = plan }
        func replace(_ plan: DoryResolvedMachinePlan, expectedPlanRevision: UInt64) throws {
            _ = expectedPlanRevision
            captured = plan
        }
        func read(id: String) throws -> DoryResolvedMachinePlan { try source.read(id: id) }
    }

    private struct FixedInventory: DoryDaemonVirtualMachineTrustInventory {
        var snapshot: DoryDaemonVirtualMachineTrustedInventorySnapshot
        func planningInventory(
            for request: DoryDaemonVirtualMachineInventoryRequest
        ) throws -> DoryDaemonVirtualMachineTrustedInventorySnapshot {
            _ = request
            return snapshot
        }
        func startInventory(
            for request: DoryDaemonVirtualMachineStartInventoryRequest
        ) throws -> DoryDaemonVirtualMachineTrustedInventorySnapshot {
            _ = request
            throw DoryDaemonVirtualMachinePlanningTransactionFailure(
                code: .invalidRequest,
                message: "Planning inventory cannot authorize start."
            )
        }
    }

    private static let journalFileName = "planning-transaction-v1.json"
    private static let lockFileName = ".planning-transaction.lock"
    private static let temporaryPrefix = ".planning-transaction."
    private static let maximumJournalBytes = 16 * 1_024 * 1_024

    private let stateDirectory: String
    private let registry: BackendRegistry
    private let trust: any DoryDaemonVirtualMachinePlanningTrustPreparing
    private let mutationAuthority: any DoryDaemonVirtualMachinePlanningMutationAuthorizing
    private let workspaces: any DoryWorkspaceDefinitionStoring
    private let plans: any DoryPlanningTransactionResolvedPlanStoring
    private let ledger: DoryVirtualMachineResourceAdmissionLedger
    private let capabilityPlanner: any DoryDaemonVirtualMachineCapabilityPlanning
    private let now: @Sendable () -> Int64
    private let faultInjector: (@Sendable (PublicationStage) throws -> Void)?
    private let instanceLock = NSLock()

    public init(
        stateDirectory: String,
        registry: BackendRegistry,
        trust: any DoryDaemonVirtualMachinePlanningTrustPreparing,
        mutationAuthority: any DoryDaemonVirtualMachinePlanningMutationAuthorizing,
        workspaces: any DoryWorkspaceDefinitionStoring,
        plans: any DoryPlanningTransactionResolvedPlanStoring,
        ledger: DoryVirtualMachineResourceAdmissionLedger,
        capabilityPlanner: any DoryDaemonVirtualMachineCapabilityPlanning =
            DoryAppleSiliconDaemonVirtualMachineCapabilityPlanner(),
        now: @escaping @Sendable () -> Int64 = {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded(.towardZero))
        }
    ) {
        self.stateDirectory = URL(fileURLWithPath: stateDirectory).standardizedFileURL.path
        self.registry = registry
        self.trust = trust
        self.mutationAuthority = mutationAuthority
        self.workspaces = workspaces
        self.plans = plans
        self.ledger = ledger
        self.capabilityPlanner = capabilityPlanner
        self.now = now
        faultInjector = nil
    }

    init(
        stateDirectory: String,
        registry: BackendRegistry,
        trust: any DoryDaemonVirtualMachinePlanningTrustPreparing,
        mutationAuthority: any DoryDaemonVirtualMachinePlanningMutationAuthorizing,
        workspaces: any DoryWorkspaceDefinitionStoring,
        plans: any DoryPlanningTransactionResolvedPlanStoring,
        ledger: DoryVirtualMachineResourceAdmissionLedger,
        capabilityPlanner: any DoryDaemonVirtualMachineCapabilityPlanning,
        now: @escaping @Sendable () -> Int64,
        faultInjector: @escaping @Sendable (PublicationStage) throws -> Void
    ) {
        self.stateDirectory = URL(fileURLWithPath: stateDirectory).standardizedFileURL.path
        self.registry = registry
        self.trust = trust
        self.mutationAuthority = mutationAuthority
        self.workspaces = workspaces
        self.plans = plans
        self.ledger = ledger
        self.capabilityPlanner = capabilityPlanner
        self.now = now
        self.faultInjector = faultInjector
    }

    public func resolveReserveAndPublish(
        _ request: DoryDaemonVirtualMachinePlanningTransactionRequest
    ) throws -> DoryDaemonVirtualMachinePlanningTransactionResult {
        try instanceLock.withLock {
            try withWorkspaceLock(machineID: request.planning.definition.identity.id) {
                try execute(request)
            }
        }
    }

    private func execute(
        _ request: DoryDaemonVirtualMachinePlanningTransactionRequest
    ) throws -> DoryDaemonVirtualMachinePlanningTransactionResult {
        try validate(request)
        let canonicalDefinition = DoryDaemonVirtualMachinePlanningCoordinator
            .canonicalDefinitionData(request.planning.definition)
        let mutationFence: DoryDaemonVirtualMachinePlanningMutationFence
        do {
            mutationFence = try mutationAuthority.acquirePlanningMutationFence(
                machine: request.planning.machine,
                definition: request.planning.definition,
                canonicalDefinitionData: canonicalDefinition
            )
            try mutationFence.revalidate()
        } catch {
            throw failure(
                .mutationAuthorityRejected,
                "Authoritative machine state is live, stale, or inconsistent with the workspace."
            )
        }
        defer { mutationFence.releaseForRecovery() }
        guard mutationFence.authority.isValid,
              mutationFence.authority.machineID == request.planning.definition.identity.id,
              mutationFence.authority.sourceDefinitionRevision
                == request.planning.definition.lifecycle.revision,
              mutationFence.authority.sourceDefinitionSHA256
                == Self.sha256(canonicalDefinition),
              Self.isSHA256(mutationFence.authoritySHA256) else {
            throw failure(.mutationAuthorityRejected, "Machine authority digest is invalid.")
        }
        let requestDigest = Self.requestDigest(
            request,
            canonicalDefinition: canonicalDefinition,
            machineAuthoritySHA256: mutationFence.authoritySHA256
        )
        var journal = try loadOrPrepare(
            request,
            requestDigest: requestDigest,
            machineAuthoritySHA256: mutationFence.authoritySHA256,
            canonicalDefinition: canonicalDefinition,
            mutationFence: mutationFence
        )
        switch journal.phase {
        case .aborted:
            throw failure(.transactionAborted, "The exact planning transaction was aborted.")
        case .recoveryRequired:
            try resumeRecoveryRequired(&journal, mutationFence: mutationFence)
        case .complete:
            let result = try completedResult(
                request,
                journal: journal,
                mutationFence: mutationFence
            )
            do { try mutationFence.complete() }
            catch {
                throw failure(
                    .recoveryRequired,
                    "Planning completed, but its workspace mutation journal requires recovery."
                )
            }
            return result
        default: break
        }

        let inventoryRequest = try makeInventoryRequest(request.planning.definition)
        let preparation: DoryDaemonVirtualMachinePlanningTrustPreparation
        do { preparation = try trust.preparePlanningTrust(for: inventoryRequest) }
        catch {
            try abortOrRetainAfterTrustFailure(&journal)
            throw failure(.trustUnavailable, "Exact daemon planning trust is unavailable.")
        }

        var lease = try reserveOrAdopt(
            request,
            journal: &journal,
            hostResources: preparation.hostResources,
            canonicalDefinition: canonicalDefinition,
            mutationFence: mutationFence
        )

        let planning: DoryDaemonVirtualMachinePlanningResult
        do {
            planning = try constructOrRecoverCandidate(
                request,
                journal: &journal,
                admission: lease.evidence,
                preparation: preparation
            )
        } catch {
            if lease.boundPlanSHA256 == nil { try? abortUnboundIfPresent(&journal) }
            throw error
        }
        try faultInjector?(.candidateJournalPublished)

        if lease.boundPlanSHA256 == nil {
            do {
                lease = try ledger.bind(
                    leaseID: lease.leaseID,
                    to: planning.resolvedPlan,
                    expectedLeaseRevision: lease.leaseRevision
                )
            } catch {
                try? abortUnboundIfPresent(&journal)
                throw failure(.planBindingRejected, "The resource lease could not bind exact plan bytes.")
            }
            try faultInjector?(.planBindingCommitted)
        } else if lease.boundPlanSHA256 != planning.resolvedPlanSHA256 {
            try markRecoveryRequired(&journal)
            throw failure(.recoveryRequired, "The resource lease is bound to different plan bytes.")
        }
        journal.leaseRevision = lease.leaseRevision
        journal.phase = .bound
        try publishJournal(journal)
        try faultInjector?(.boundJournalPublished)

        do {
            try preparation.publicationAuthorization.authorize()
            try mutationFence.revalidate()
        } catch {
            try markRecoveryRequired(&journal)
            throw failure(
                .publicationAuthorizationRejected,
                "Fresh media, runtime, host, or qualification evidence changed before publication."
            )
        }
        try faultInjector?(.publicationAuthorized)

        try publishWorkspace(request, journal: &journal, mutationFence: mutationFence)
        // Workspace publication is not the final machine-authority boundary. Re-prove the
        // exact legacy bytes, migration facts, projection, and runtime identity immediately
        // before publishing the independently durable plan record too.
        try revalidateMutationFence(
            mutationFence,
            journal: &journal,
            message: "Machine authority changed before resolved-plan publication."
        )
        try publishPlan(request, planning: planning, journal: &journal)
        journal.phase = .complete
        try publishJournal(journal)
        try faultInjector?(.completeJournalPublished)
        let result = DoryDaemonVirtualMachinePlanningTransactionResult(
            planning: planning,
            lease: lease,
            transactionID: journal.transactionID
        )
        do { try mutationFence.complete() }
        catch {
            throw failure(
                .recoveryRequired,
                "Planning completed, but its workspace mutation journal requires recovery."
            )
        }
        return result
    }

    private func loadOrPrepare(
        _ request: DoryDaemonVirtualMachinePlanningTransactionRequest,
        requestDigest: String,
        machineAuthoritySHA256: String,
        canonicalDefinition: Data,
        mutationFence: DoryDaemonVirtualMachinePlanningMutationFence
    ) throws -> Journal {
        if let existing = try readJournal(machineID: request.planning.definition.identity.id) {
            if existing.requestSHA256 == requestDigest { return existing }
            guard existing.phase == .complete || existing.phase == .aborted else {
                throw failure(.transactionConflict, "Another planning transaction is incomplete.")
            }
        }
        let timestamp = now()
        guard timestamp > 0 else { throw failure(.invalidRequest, "Planning time is invalid.") }
        let sourcePlan: DoryResolvedMachinePlan?
        let existingRecord = try workspaces.readPersistedRecordIfPresent(
            id: request.planning.definition.identity.id
        )
        let existingDefinition = existingRecord?.definition
        if request.workspacePublication == .retainExistingExact {
            guard mutationFence.authority.sourceDefinitionRevision
                    == request.planning.definition.lifecycle.revision,
                  mutationFence.authority.sourceDefinitionSHA256
                    == Self.sha256(canonicalDefinition),
                  let existingRecord,
                  retainedRecordMatchesMutationAuthority(
                    existingRecord,
                    target: request.planning.definition,
                    mutationFence: mutationFence
                  ) else {
                throw failure(
                    .mutationAuthorityRejected,
                    "Retained workspace source authority is not exact."
                )
            }
        }
        sourcePlan = try plans.readIfPresent(id: request.planning.definition.identity.id)
        switch request.workspacePublication {
        case .create:
            guard existingDefinition == nil else {
                throw failure(.transactionConflict, "Workspace already exists before create.")
            }
        case let .replace(expected):
            guard let existingDefinition,
                  existingDefinition.lifecycle.revision == expected else {
                throw failure(.transactionConflict, "Workspace replacement source is stale.")
            }
        case .retainExistingExact:
            guard let existingDefinition,
                  existingDefinition == request.planning.definition else {
                throw failure(.transactionConflict, "Retained workspace is not exact.")
            }
        }
        switch request.planning.publication {
        case .create:
            guard sourcePlan == nil else {
                throw failure(.transactionConflict, "Resolved plan already exists before create.")
            }
        case let .replace(expected):
            guard sourcePlan?.planRevision == expected else {
                throw failure(.transactionConflict, "Resolved-plan replacement source is stale.")
            }
        }
        let journal = Journal(
            transactionID: "planning-transaction-\(UUID().uuidString.lowercased())",
            phase: .prepared,
            requestSHA256: requestDigest,
            machineAuthoritySHA256: machineAuthoritySHA256,
            definition: request.planning.definition,
            definitionSHA256: Self.sha256(canonicalDefinition),
            sourceDefinitionSHA256: existingDefinition.map {
                Self.sha256(DoryDaemonVirtualMachinePlanningCoordinator.canonicalDefinitionData($0))
            },
            sourceDefinitionRevision: existingDefinition?.lifecycle.revision,
            workspacePublication: request.workspacePublication,
            planPublication: PlanPublicationRecord(request.planning.publication),
            sourcePlanSHA256: sourcePlan.map(DoryDaemonVirtualMachinePlanningCoordinator.planSHA256),
            sourcePlanRevision: sourcePlan?.planRevision,
            plannedAtUnixMilliseconds: timestamp,
            leaseID: nil,
            leaseRevision: nil,
            candidatePlanData: nil,
            candidatePlanSHA256: nil,
            candidatePlannerRequest: nil,
            candidatePlannerResult: nil
        )
        try publishJournal(journal)
        try faultInjector?(.preparedJournalPublished)
        return journal
    }

    private func reserveOrAdopt(
        _ request: DoryDaemonVirtualMachinePlanningTransactionRequest,
        journal: inout Journal,
        hostResources: DoryVMHostResources,
        canonicalDefinition: Data,
        mutationFence: DoryDaemonVirtualMachinePlanningMutationFence
    ) throws -> DoryVirtualMachineResourceAdmissionLease {
        let binding = DoryVirtualMachineResourceAdmissionPlanBinding(
            machineID: request.planning.definition.identity.id,
            definitionRevision: request.planning.definition.lifecycle.revision,
            definitionSHA256: Self.sha256(canonicalDefinition),
            plannedPlanRevision: Self.plannedPlanRevision(request.planning.publication)
        )
        if let leaseID = journal.leaseID {
            let candidates = try ledger.snapshot().leases.filter { $0.leaseID == leaseID }
            guard candidates.count == 1, let lease = candidates.first,
                  lease.binding == binding,
                  Self.sameStableAdmissionHost(lease.hostFacts, hostResources),
                  lease.resources == request.planning.definition.resources,
                  lease.workload == request.planning.definition.workload,
                  lease.requirements == request.resourceRequirements.sorted(by: Self.requirementOrder) else {
                throw failure(.recoveryRequired, "The journaled resource lease cannot be adopted exactly.")
            }
            if lease.state == .stopped, lease.boundPlanSHA256 == nil {
                let reactivated: DoryVirtualMachineResourceAdmissionLease
                do {
                    reactivated = try ledger.reserveStarting(
                        binding: binding,
                        hostFacts: hostResources,
                        workload: request.planning.definition.workload,
                        requirements: request.resourceRequirements,
                        resources: request.planning.definition.resources,
                        startingLeaseDurationMilliseconds:
                            request.startingLeaseDurationMilliseconds
                    )
                } catch {
                    throw failure(.resourceReservationRejected, "Stopped planning lease cannot be reactivated.")
                }
                guard reactivated.leaseID == leaseID,
                      reactivated.boundPlanSHA256 == nil else {
                    throw failure(.recoveryRequired, "Reactivated lease identity changed.")
                }
                journal.leaseRevision = reactivated.leaseRevision
                try publishJournal(journal)
                return reactivated
            }
            if lease.state == .recoveryRequired,
               let planData = journal.candidatePlanData,
               let planDigest = journal.candidatePlanSHA256,
               lease.boundPlanSHA256 == planDigest,
               let plan = try? JSONDecoder().decode(
                    DoryResolvedMachinePlan.self, from: planData
               ) {
                do {
                    try mutationFence.revalidate()
                    let recovered = try ledger.recoverBoundPlanningLease(
                        leaseID: leaseID,
                        plan: plan,
                        authorization:
                            DoryVirtualMachineBoundPlanningLeaseRecoveryAuthorization(
                                machineID: plan.machineID,
                                planSHA256: planDigest
                            ),
                        startingLeaseDurationMilliseconds:
                            request.startingLeaseDurationMilliseconds,
                        expectedLeaseRevision: lease.leaseRevision
                    )
                    journal.leaseRevision = recovered.leaseRevision
                    try publishJournal(journal)
                    return recovered
                } catch {
                    try markRecoveryRequired(&journal)
                    throw failure(.recoveryRequired, "Expired bound planning lease cannot be proven unlaunched.")
                }
            }
            guard lease.state == .starting else {
                try markRecoveryRequired(&journal)
                throw failure(.recoveryRequired, "The journaled resource lease is no longer starting.")
            }
            return lease
        }
        let existing = try ledger.snapshot().leases.filter {
            $0.binding == binding && $0.state == .starting
                && Self.sameStableAdmissionHost($0.hostFacts, hostResources)
                && $0.resources == request.planning.definition.resources
                && $0.workload == request.planning.definition.workload
                && $0.requirements == request.resourceRequirements.sorted(by: Self.requirementOrder)
        }
        let lease: DoryVirtualMachineResourceAdmissionLease
        if existing.count == 1, let adopted = existing.first {
            lease = adopted
        } else if existing.isEmpty {
            do {
                lease = try ledger.reserveStarting(
                    binding: binding,
                    hostFacts: hostResources,
                    workload: request.planning.definition.workload,
                    requirements: request.resourceRequirements,
                    resources: request.planning.definition.resources,
                    startingLeaseDurationMilliseconds:
                        request.startingLeaseDurationMilliseconds
                )
            } catch {
                throw failure(.resourceReservationRejected, "Resources could not be reserved atomically.")
            }
            try faultInjector?(.resourceReservationCommitted)
        } else {
            throw failure(.recoveryRequired, "Resource lease adoption is ambiguous.")
        }
        journal.leaseID = lease.leaseID
        journal.leaseRevision = lease.leaseRevision
        journal.phase = .reserved
        try publishJournal(journal)
        try faultInjector?(.reservedJournalPublished)
        return lease
    }

    private func constructOrRecoverCandidate(
        _ request: DoryDaemonVirtualMachinePlanningTransactionRequest,
        journal: inout Journal,
        admission: DoryResolvedMachineResourceAdmissionEvidence,
        preparation: DoryDaemonVirtualMachinePlanningTrustPreparation
    ) throws -> DoryDaemonVirtualMachinePlanningResult {
        if journal.candidatePlanData != nil {
            return try planningResultFromCandidate(request, journal: journal)
        }
        let capture = CapturePlanStore(source: plans)
        let plannedAt = journal.plannedAtUnixMilliseconds
        let coordinator = DoryDaemonVirtualMachinePlanningCoordinator(
            registry: registry,
            inventory: FixedInventory(snapshot: preparation.snapshot(admission)),
            plans: capture,
            capabilityPlanner: capabilityPlanner,
            now: { plannedAt }
        )
        let result: DoryDaemonVirtualMachinePlanningResult
        do { result = try coordinator.resolveAndPersist(request.planning) }
        catch {
            throw failure(.planConstructionRejected, "Exact trusted facts could not construct a plan.")
        }
        let candidateData = Self.canonicalData(result.resolvedPlan)
        guard !candidateData.isEmpty, Self.sha256(candidateData) == result.resolvedPlanSHA256 else {
            throw failure(.planConstructionRejected, "Candidate plan encoding is not deterministic.")
        }
        journal.candidatePlanData = candidateData
        journal.candidatePlanSHA256 = result.resolvedPlanSHA256
        journal.candidatePlannerRequest = result.plannerRequest
        journal.candidatePlannerResult = result.plannerResult
        journal.phase = .candidatePrepared
        try publishJournal(journal)
        return result
    }

    private func planningResultFromCandidate(
        _ request: DoryDaemonVirtualMachinePlanningTransactionRequest,
        journal: Journal
    ) throws -> DoryDaemonVirtualMachinePlanningResult {
        guard let data = journal.candidatePlanData,
              let digest = journal.candidatePlanSHA256,
              let plan = try? JSONDecoder().decode(DoryResolvedMachinePlan.self, from: data),
              let plannerRequest = journal.candidatePlannerRequest,
              let plannerResult = journal.candidatePlannerResult,
              let selected = plannerResult.selectedDescriptor else {
            throw failure(.invalidJournal, "Journaled plan selection is incomplete.")
        }
        let backendResult = registry.plan(MachineBackendPlanRequest(
            machine: request.planning.machine,
            capabilityPlan: plannerResult
        ))
        guard let backendPlan = backendResult.plan,
              backendResult.failure == nil,
              backendPlan.machine == request.planning.machine,
              backendPlan.capability == selected,
              backendPlan.backend.identity == plan.backend,
              backendPlan.backend.implementationIdentifier
                == plan.backendImplementationIdentifier else {
            throw failure(.planConstructionRejected, "Journaled plan no longer maps to its exact adapter.")
        }
        return DoryDaemonVirtualMachinePlanningResult(
            plannerRequest: plannerRequest,
            plannerResult: plannerResult,
            resolvedPlan: plan,
            resolvedPlanSHA256: digest,
            backendPlan: backendPlan
        )
    }

    private func publishWorkspace(
        _ request: DoryDaemonVirtualMachinePlanningTransactionRequest,
        journal: inout Journal,
        mutationFence: DoryDaemonVirtualMachinePlanningMutationFence
    ) throws {
        let target = request.planning.definition
        try revalidateMutationFence(
            mutationFence,
            journal: &journal,
            message: "Machine authority changed before workspace publication."
        )
        let currentRecord = try workspaces.readPersistedRecordIfPresent(id: target.identity.id)
        let current = currentRecord?.definition
        if request.workspacePublication == .retainExistingExact {
            guard let currentRecord,
                  retainedRecordMatchesMutationAuthority(
                    currentRecord,
                    target: target,
                    mutationFence: mutationFence
                  ) else {
                throw failure(.transactionConflict, "Retained workspace differs from target.")
            }
        }
        if current != target {
            do {
                switch request.workspacePublication {
                case .create:
                    guard current == nil else { throw failure(.transactionConflict, "Workspace differs from target.") }
                    try workspaces.create(target)
                case let .replace(expected):
                    guard let current,
                          Self.sha256(DoryDaemonVirtualMachinePlanningCoordinator
                            .canonicalDefinitionData(current)) == journal.sourceDefinitionSHA256 else {
                        throw failure(.transactionConflict, "Workspace source changed during planning.")
                    }
                    try workspaces.replace(target, expectedRevision: expected)
                case .retainExistingExact:
                    throw failure(.transactionConflict, "Retained workspace differs from target.")
                }
            } catch let error as DoryDaemonVirtualMachinePlanningTransactionFailure { throw error }
            catch { throw failure(.workspacePublicationRejected, "Workspace publication failed.") }
        }
        guard let published = try workspaces.readPersistedRecordIfPresent(id: target.identity.id),
              published.definition == target,
              request.workspacePublication != .retainExistingExact
                || retainedRecordMatchesMutationAuthority(
                    published,
                    target: target,
                    mutationFence: mutationFence
                ) else {
            throw failure(
                .workspacePublicationRejected,
                "Workspace publication did not persist the exact target."
            )
        }
        try faultInjector?(.workspacePublished)
        journal.phase = .workspacePublished
        try publishJournal(journal)
        try faultInjector?(.workspaceJournalPublished)
    }

    private func publishPlan(
        _ request: DoryDaemonVirtualMachinePlanningTransactionRequest,
        planning: DoryDaemonVirtualMachinePlanningResult,
        journal: inout Journal
    ) throws {
        let current = try plans.readIfPresent(id: planning.resolvedPlan.machineID)
        if current != planning.resolvedPlan {
            do {
                switch request.planning.publication {
                case .create:
                    guard current == nil else { throw failure(.transactionConflict, "Resolved plan differs from target.") }
                    try plans.create(planning.resolvedPlan)
                case let .replace(expected):
                    guard let current,
                          DoryDaemonVirtualMachinePlanningCoordinator.planSHA256(current)
                            == journal.sourcePlanSHA256 else {
                        throw failure(.transactionConflict, "Resolved plan source changed during planning.")
                    }
                    try plans.replace(planning.resolvedPlan, expectedPlanRevision: expected)
                }
            } catch let error as DoryDaemonVirtualMachinePlanningTransactionFailure { throw error }
            catch { throw failure(.planPublicationRejected, "Resolved-plan publication failed.") }
        }
        try faultInjector?(.planPublished)
        journal.phase = .planPublished
        try publishJournal(journal)
        try faultInjector?(.planJournalPublished)
    }

    private func completedResult(
        _ request: DoryDaemonVirtualMachinePlanningTransactionRequest,
        journal: Journal,
        mutationFence: DoryDaemonVirtualMachinePlanningMutationFence
    ) throws -> DoryDaemonVirtualMachinePlanningTransactionResult {
        let planning = try planningResultFromCandidate(request, journal: journal)
        let plan = planning.resolvedPlan
        do { try mutationFence.revalidate() }
        catch {
            throw failure(.recoveryRequired, "Completed machine authority no longer matches.")
        }
        let currentRecord = try workspaces.readPersistedRecordIfPresent(id: plan.machineID)
        let currentDefinition = currentRecord?.definition
        if request.workspacePublication == .retainExistingExact {
            guard let currentRecord,
                  retainedRecordMatchesMutationAuthority(
                    currentRecord,
                    target: journal.definition,
                    mutationFence: mutationFence
                  ) else {
                throw failure(.recoveryRequired, "Completed retained workspace is not exact.")
            }
        }
        guard let currentDefinition,
              currentDefinition == journal.definition,
              let currentPlan = try plans.readIfPresent(id: plan.machineID),
              currentPlan == plan,
              let leaseID = journal.leaseID,
              let lease = try ledger.snapshot().leases.first(where: { $0.leaseID == leaseID }),
              lease.boundPlanSHA256 == journal.candidatePlanSHA256 else {
            throw failure(.recoveryRequired, "Completed transaction authorities no longer match.")
        }
        return DoryDaemonVirtualMachinePlanningTransactionResult(
            planning: planning,
            lease: lease,
            transactionID: journal.transactionID
        )
    }

    /// A post-bind failure is retained, never aborted. Retrying through this coordinator is the
    /// explicit daemon recovery operation: it reacquires the mutation fence in `execute`, proves
    /// the same exact bound lease/candidate and source-or-target publication authorities here,
    /// then obtains a newly collected, single-use publication authorization before resuming.
    private func resumeRecoveryRequired(
        _ journal: inout Journal,
        mutationFence: DoryDaemonVirtualMachinePlanningMutationFence
    ) throws {
        guard let leaseID = journal.leaseID,
              let candidateDigest = journal.candidatePlanSHA256,
              let lease = try ledger.snapshot().leases.first(where: { $0.leaseID == leaseID }),
              lease.binding.machineID == journal.definition.identity.id,
              lease.boundPlanSHA256 == candidateDigest,
              lease.state == .starting || lease.state == .recoveryRequired else {
            throw failure(.recoveryRequired, "The retained bound lease cannot be recovered exactly.")
        }

        do { try mutationFence.revalidate() }
        catch {
            throw failure(.recoveryRequired, "Machine authority changed during bound recovery.")
        }
        let currentRecord = try workspaces.readPersistedRecordIfPresent(
            id: journal.definition.identity.id
        )
        let currentDefinition = currentRecord?.definition
        if journal.workspacePublication == .retainExistingExact {
            guard let currentRecord,
                  retainedRecordMatchesMutationAuthority(
                    currentRecord,
                    target: journal.definition,
                    mutationFence: mutationFence
                  ) else {
                throw failure(.recoveryRequired, "Retained workspace is missing or substituted.")
            }
        }
        let definitionIsTarget = currentDefinition == journal.definition
        let definitionIsSource: Bool
        switch journal.workspacePublication {
        case .create:
            definitionIsSource = currentDefinition == nil
        case .replace:
            definitionIsSource = currentDefinition.map {
                Self.sha256(DoryDaemonVirtualMachinePlanningCoordinator
                    .canonicalDefinitionData($0)) == journal.sourceDefinitionSHA256
            } ?? false
        case .retainExistingExact:
            definitionIsSource = definitionIsTarget
        }
        guard definitionIsSource || definitionIsTarget else {
            throw failure(.recoveryRequired, "Workspace authority changed during bound recovery.")
        }

        let currentPlan = try plans.readIfPresent(id: journal.definition.identity.id)
        let planIsTarget = currentPlan.map {
            DoryDaemonVirtualMachinePlanningCoordinator.planSHA256($0) == candidateDigest
        } ?? false
        let planIsSource: Bool
        switch journal.planPublication {
        case .create:
            planIsSource = currentPlan == nil
        case .replace:
            planIsSource = currentPlan.map {
                DoryDaemonVirtualMachinePlanningCoordinator.planSHA256($0)
                    == journal.sourcePlanSHA256
            } ?? false
        }
        guard planIsSource || planIsTarget,
              !planIsTarget || definitionIsTarget else {
            throw failure(.recoveryRequired, "Publication authorities cannot be resumed safely.")
        }

        journal.leaseRevision = lease.leaseRevision
        journal.phase = .bound
        try publishJournal(journal)
    }

    private func retainedRecordMatchesMutationAuthority(
        _ record: DoryWorkspaceRepositoryRecord,
        target: DoryVirtualMachineDefinition,
        mutationFence: DoryDaemonVirtualMachinePlanningMutationFence
    ) -> Bool {
        guard record.definition == target else { return false }
        switch (record.legacyConfigurationSHA256, record.legacyMigrationFactsSHA256) {
        case (nil, nil):
            return true
        case let (legacyDigest?, factsDigest?):
            return legacyDigest == mutationFence.authority.legacyConfigurationSHA256
                && factsDigest == mutationFence.authority.migrationFactsSHA256
        default:
            return false
        }
    }

    private func revalidateMutationFence(
        _ mutationFence: DoryDaemonVirtualMachinePlanningMutationFence,
        journal: inout Journal,
        message: String
    ) throws {
        do { try mutationFence.revalidate() }
        catch {
            try? markRecoveryRequired(&journal)
            throw failure(.mutationAuthorityRejected, message)
        }
    }

    private func abortUnboundIfPresent(_ journal: inout Journal) throws {
        if let leaseID = journal.leaseID,
           let lease = try ledger.snapshot().leases.first(where: { $0.leaseID == leaseID }),
           lease.state == .starting, lease.boundPlanSHA256 == nil {
            _ = try ledger.cancelUnboundStarting(
                leaseID: leaseID,
                expectedLeaseRevision: lease.leaseRevision
            )
        }
        journal.phase = .aborted
        try publishJournal(journal)
    }

    private func abortOrRetainAfterTrustFailure(_ journal: inout Journal) throws {
        guard let leaseID = journal.leaseID,
              let lease = try ledger.snapshot().leases.first(where: { $0.leaseID == leaseID }) else {
            journal.phase = .aborted
            try publishJournal(journal)
            return
        }
        if lease.state == .starting, lease.boundPlanSHA256 == nil {
            _ = try ledger.cancelUnboundStarting(
                leaseID: leaseID,
                expectedLeaseRevision: lease.leaseRevision
            )
            journal.phase = .aborted
        } else if lease.boundPlanSHA256 != nil {
            journal.phase = .recoveryRequired
        } else {
            journal.phase = .aborted
        }
        try publishJournal(journal)
    }

    private func markRecoveryRequired(_ journal: inout Journal) throws {
        journal.phase = .recoveryRequired
        try publishJournal(journal)
    }

    private func validate(
        _ request: DoryDaemonVirtualMachinePlanningTransactionRequest
    ) throws {
        guard request.planning.canonicalDefinitionData
                == DoryDaemonVirtualMachinePlanningCoordinator
                    .canonicalDefinitionData(request.planning.definition),
              request.planning.machine.id == request.planning.definition.identity.id,
              request.startingLeaseDurationMilliseconds > 0 else {
            throw failure(.invalidRequest, "Planning transaction request is inconsistent.")
        }
        switch request.workspacePublication {
        case .create:
            guard request.planning.definition.lifecycle.revision == 1 else {
                throw failure(.invalidRequest, "Created workspace must start at revision one.")
            }
        case let .replace(expected):
            guard expected < .max,
                  request.planning.definition.lifecycle.revision == expected + 1 else {
                throw failure(.invalidRequest, "Workspace replacement revision is invalid.")
            }
        case .retainExistingExact: break
        }
    }

    private func makeInventoryRequest(
        _ definition: DoryVirtualMachineDefinition
    ) throws -> DoryDaemonVirtualMachineInventoryRequest {
        guard let boot = DoryDaemonVirtualMachinePlanningCoordinator
            .primaryBootMedia(in: definition) else {
            throw failure(.invalidRequest, "Workspace has no primary boot media.")
        }
        return DoryDaemonVirtualMachineInventoryRequest(
            machineID: definition.identity.id,
            definitionRevision: definition.lifecycle.revision,
            guest: definition.guest,
            bootMedia: boot,
            resources: definition.resources,
            devices: DoryDaemonVirtualMachinePlanningCoordinator.devices(for: definition),
            acceptableGraphics: definition.graphics.acceptableLevels,
            virtualHardwareABIVersion: definition.virtualHardwareABIVersion
        )
    }

    private static func plannedPlanRevision(
        _ publication: DoryDaemonVirtualMachinePlanPublication
    ) -> UInt64 {
        switch publication {
        case .create: 1
        case let .replace(expected): expected == .max ? .max : expected + 1
        }
    }

    private static func requestDigest(
        _ request: DoryDaemonVirtualMachinePlanningTransactionRequest,
        canonicalDefinition: Data,
        machineAuthoritySHA256: String
    ) -> String {
        struct DigestInput: Codable {
            var definitionSHA256: String
            var machineSHA256: String
            var machineAuthoritySHA256: String
            var workspacePublication: DoryDaemonVirtualMachineWorkspacePublication
            var planPublication: PlanPublicationRecord
            var requirements: [DoryVMResourceRequirement]
            var leaseDurationMilliseconds: Int64
            var fallbackAuthorization: DoryResolvedMachineFallbackAuthorization?
            var experimentalAuthorization: DoryResolvedExperimentalSupportAuthorization?
        }
        return sha256(canonicalData(DigestInput(
            definitionSHA256: sha256(canonicalDefinition),
            machineSHA256: sha256(canonicalData(request.planning.machine)),
            machineAuthoritySHA256: machineAuthoritySHA256,
            workspacePublication: request.workspacePublication,
            planPublication: PlanPublicationRecord(request.planning.publication),
            requirements: request.resourceRequirements.sorted(by: requirementOrder),
            leaseDurationMilliseconds: request.startingLeaseDurationMilliseconds,
            fallbackAuthorization: request.planning.fallbackAuthorization,
            experimentalAuthorization: request.planning.experimentalAuthorization
        )))
    }

    private static func requirementOrder(
        _ lhs: DoryVMResourceRequirement,
        _ rhs: DoryVMResourceRequirement
    ) -> Bool {
        canonicalData(lhs).lexicographicallyPrecedes(canonicalData(rhs))
    }

    private func journalDirectory(machineID: String) -> String {
        stateDirectory + "/" + machineID
    }

    private func journalPath(machineID: String) -> String {
        journalDirectory(machineID: machineID) + "/" + Self.journalFileName
    }

    private func withWorkspaceLock<T>(
        machineID: String,
        _ operation: () throws -> T
    ) throws -> T {
        guard Self.isValidMachineID(machineID) else {
            throw failure(.invalidRequest, "Machine identifier is invalid.")
        }
        try ensurePrivateDirectory(stateDirectory)
        let directory = journalDirectory(machineID: machineID)
        try ensurePrivateDirectory(directory)
        let path = directory + "/" + Self.lockFileName
        let descriptor = open(
            path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw failure(.filesystem, "Planning transaction lock cannot be opened.")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & 0o077 == 0 else {
            throw failure(.filesystem, "Planning transaction lock is insecure.")
        }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw failure(.filesystem, "Planning transaction lock cannot be acquired.")
            }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func readJournal(machineID: String) throws -> Journal? {
        let path = journalPath(machineID: machineID)
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw failure(.filesystem, "Planning journal cannot be opened.")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & 0o077 == 0,
              info.st_size > 0, info.st_size <= Self.maximumJournalBytes else {
            throw failure(.invalidJournal, "Planning journal metadata is invalid.")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0, data.count + count <= Self.maximumJournalBytes else {
                throw failure(.invalidJournal, "Planning journal cannot be read safely.")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let envelope = try? JSONDecoder().decode(JournalEnvelope.self, from: data),
              data == Self.canonicalData(envelope) + Data("\n".utf8),
              envelope.journalSHA256 == Self.sha256(Self.canonicalData(envelope.journal)) else {
            throw failure(.invalidJournal, "Planning journal integrity check failed.")
        }
        try validate(envelope.journal)
        return envelope.journal
    }

    private func publishJournal(_ journal: Journal) throws {
        try validate(journal)
        let directory = journalDirectory(machineID: journal.definition.identity.id)
        let envelope = JournalEnvelope(
            journalSHA256: Self.sha256(Self.canonicalData(journal)),
            journal: journal
        )
        let data = Self.canonicalData(envelope) + Data("\n".utf8)
        guard data.count <= Self.maximumJournalBytes else {
            throw failure(.invalidJournal, "Planning journal is too large.")
        }
        let temporary = directory + "/\(Self.temporaryPrefix)\(UUID().uuidString)"
        let descriptor = open(
            temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw failure(.filesystem, "Planning journal cannot be created.") }
        var openDescriptor = true
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(
                        descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset
                    )
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw failure(.filesystem, "Planning journal cannot be written.") }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else { throw failure(.filesystem, "Planning journal cannot be synced.") }
            close(descriptor)
            openDescriptor = false
            guard rename(temporary, journalPath(machineID: journal.definition.identity.id)) == 0 else {
                throw failure(.filesystem, "Planning journal cannot be published.")
            }
            try syncDirectory(directory)
        } catch {
            if openDescriptor { close(descriptor) }
            unlink(temporary)
            throw error
        }
    }

    private func validate(_ journal: Journal) throws {
        guard journal.schemaVersion == Journal.schemaVersion,
              Self.isValidMachineID(journal.definition.identity.id),
              journal.transactionID.wholeMatch(
                of: /planning-transaction-[0-9a-f-]{36}/
              ) != nil,
              Self.isSHA256(journal.requestSHA256),
              Self.isSHA256(journal.machineAuthoritySHA256),
              Self.isSHA256(journal.definitionSHA256),
              journal.definitionSHA256 == Self.sha256(
                DoryDaemonVirtualMachinePlanningCoordinator
                    .canonicalDefinitionData(journal.definition)
              ),
              journal.plannedAtUnixMilliseconds > 0,
              (journal.leaseID == nil) == (journal.leaseRevision == nil),
              (journal.candidatePlanData == nil) == (journal.candidatePlanSHA256 == nil),
              (journal.candidatePlanData == nil)
                == (journal.candidatePlannerRequest == nil),
              (journal.candidatePlanData == nil)
                == (journal.candidatePlannerResult == nil) else {
            throw failure(.invalidJournal, "Planning journal fields are invalid.")
        }
        if let data = journal.candidatePlanData,
           let digest = journal.candidatePlanSHA256 {
            guard Self.isSHA256(digest), Self.sha256(data) == digest,
                  let plan = try? JSONDecoder().decode(DoryResolvedMachinePlan.self, from: data),
                  Self.canonicalData(plan) == data,
                  plan.machineID == journal.definition.identity.id,
                  plan.definitionSHA256 == journal.definitionSHA256,
                  plan.planRevision == Self.plannedPlanRevision(
                    Self.planPublication(from: journal.planPublication)
                  ),
                  plan.validate().isEmpty else {
                throw failure(.invalidJournal, "Journaled candidate plan is invalid.")
            }
        }
        switch journal.workspacePublication {
        case .create:
            guard journal.sourceDefinitionSHA256 == nil,
                  journal.sourceDefinitionRevision == nil else {
                throw failure(.invalidJournal, "Workspace create has a source authority.")
            }
        case let .replace(expected):
            guard Self.optionalSHA256IsValid(journal.sourceDefinitionSHA256),
                  journal.sourceDefinitionRevision == expected else {
                throw failure(.invalidJournal, "Workspace replacement source is invalid.")
            }
        case .retainExistingExact:
            guard journal.sourceDefinitionSHA256 == journal.definitionSHA256,
                  journal.sourceDefinitionRevision
                    == journal.definition.lifecycle.revision else {
                throw failure(.invalidJournal, "Retained workspace authority is not exact.")
            }
        }
        switch journal.planPublication {
        case .create:
            guard journal.sourcePlanSHA256 == nil, journal.sourcePlanRevision == nil else {
                throw failure(.invalidJournal, "Resolved-plan create has a source authority.")
            }
        case let .replace(expected):
            guard Self.optionalSHA256IsValid(journal.sourcePlanSHA256),
                  journal.sourcePlanRevision == expected else {
                throw failure(.invalidJournal, "Resolved-plan replacement source is invalid.")
            }
        }
        switch journal.phase {
        case .prepared:
            guard journal.leaseID == nil, journal.candidatePlanData == nil else {
                throw failure(.invalidJournal, "Prepared journal contains later-phase authority.")
            }
        case .reserved:
            guard journal.leaseID != nil, journal.candidatePlanData == nil else {
                throw failure(.invalidJournal, "Reserved journal fields are inconsistent.")
            }
        case .candidatePrepared, .bound, .workspacePublished, .planPublished, .complete,
             .recoveryRequired:
            guard journal.leaseID != nil, journal.candidatePlanData != nil else {
                throw failure(.invalidJournal, "Plan-bearing journal fields are incomplete.")
            }
        case .aborted: break
        }
    }

    private func ensurePrivateDirectory(_ path: String) throws {
        if mkdir(path, mode_t(0o700)) != 0, errno != EEXIST {
            throw failure(.filesystem, "Planning transaction directory cannot be created.")
        }
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0 else {
            throw failure(.filesystem, "Planning transaction directory is insecure.")
        }
    }

    private func syncDirectory(_ path: String) throws {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure(.filesystem, "Planning directory cannot be opened.") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw failure(.filesystem, "Planning directory cannot be synced.") }
    }

    private static func canonicalData<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// CPU and physical memory describe the capacity model under which a lease was admitted.
    /// Free disk space and existing commitments are volatile observations; the durable ledger's
    /// exact reservation is their authority after reserve commits and transaction recovery must
    /// not attempt a second admission from a later free-space sample.
    private static func sameStableAdmissionHost(
        _ lhs: DoryVMHostResources,
        _ rhs: DoryVMHostResources
    ) -> Bool {
        lhs.logicalCPUCount == rhs.logicalCPUCount
            && lhs.physicalMemoryBytes == rhs.physicalMemoryBytes
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func optionalSHA256IsValid(_ value: String?) -> Bool {
        value.map(isSHA256) ?? false
    }

    private static func planPublication(
        from record: PlanPublicationRecord
    ) -> DoryDaemonVirtualMachinePlanPublication {
        switch record {
        case .create: .create
        case let .replace(expected): .replace(expectedPlanRevision: expected)
        }
    }

    private static func isValidMachineID(_ value: String) -> Bool {
        value.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/) != nil
            && !value.hasPrefix(".")
    }

    private func failure(
        _ code: DoryDaemonVirtualMachinePlanningTransactionFailureCode,
        _ message: String
    ) -> DoryDaemonVirtualMachinePlanningTransactionFailure {
        DoryDaemonVirtualMachinePlanningTransactionFailure(code: code, message: message)
    }
}
