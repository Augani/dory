import CryptoKit
import Darwin
import DoryOperations
import Foundation

public enum DoryVirtualMachineResourceLeaseState: String, Codable, Sendable, CaseIterable {
    case starting
    case running
    /// A bound start lease expired across a daemon outage. Capacity remains reserved until the
    /// daemon proves whether the exact VM process is running or stopped.
    case recoveryRequired = "recovery-required"
    /// CPU and memory are released. The disk growth reservation remains durable until deletion.
    case stopped
}

public enum DoryVirtualMachineObservedRuntimeState: String, Sendable, CaseIterable {
    case running
    case stopped
}

public struct DoryVirtualMachineResourceAdmissionPlanBinding:
    Codable, Sendable, Equatable, Hashable
{
    public var machineID: String
    public var definitionRevision: UInt64
    public var definitionSHA256: String
    public var plannedPlanRevision: UInt64

    public init(
        machineID: String,
        definitionRevision: UInt64,
        definitionSHA256: String,
        plannedPlanRevision: UInt64
    ) {
        self.machineID = machineID
        self.definitionRevision = definitionRevision
        self.definitionSHA256 = definitionSHA256
        self.plannedPlanRevision = plannedPlanRevision
    }
}

public struct DoryVirtualMachineResourceAdmissionLease: Codable, Sendable, Equatable {
    public static let schemaVersion: UInt16 = 2

    public var schemaVersion: UInt16
    public var leaseID: String
    public var leaseRevision: UInt64
    public var binding: DoryVirtualMachineResourceAdmissionPlanBinding
    public var boundPlanSHA256: String?
    public var hostFacts: DoryVMHostResources
    public var hostFactsSHA256: String
    public var workload: DoryVMWorkloadProfile
    public var requirements: [DoryVMResourceRequirement]
    public var resources: DoryVMResourceRequest
    public var portForwards: [DoryVMPortForward]
    public var state: DoryVirtualMachineResourceLeaseState
    public var startingExpiresAtUnixMilliseconds: Int64?
    public var createdAtUnixMilliseconds: Int64
    public var updatedAtUnixMilliseconds: Int64
    public var evidence: DoryResolvedMachineResourceAdmissionEvidence

    fileprivate init(
        leaseID: String,
        binding: DoryVirtualMachineResourceAdmissionPlanBinding,
        hostFacts: DoryVMHostResources,
        workload: DoryVMWorkloadProfile,
        requirements: [DoryVMResourceRequirement],
        resources: DoryVMResourceRequest,
        portForwards: [DoryVMPortForward],
        startingExpiresAtUnixMilliseconds: Int64,
        createdAtUnixMilliseconds: Int64,
        evidence: DoryResolvedMachineResourceAdmissionEvidence
    ) {
        schemaVersion = Self.schemaVersion
        self.leaseID = leaseID
        leaseRevision = 1
        self.binding = binding
        boundPlanSHA256 = nil
        self.hostFacts = hostFacts
        hostFactsSHA256 = Self.digest(hostFacts)
        self.workload = workload
        self.requirements = requirements
        self.resources = resources
        self.portForwards = portForwards
        state = .starting
        self.startingExpiresAtUnixMilliseconds = startingExpiresAtUnixMilliseconds
        self.createdAtUnixMilliseconds = createdAtUnixMilliseconds
        updatedAtUnixMilliseconds = createdAtUnixMilliseconds
        self.evidence = evidence
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case leaseID
        case leaseRevision
        case binding
        case boundPlanSHA256
        case hostFacts
        case hostFactsSHA256
        case workload
        case requirements
        case resources
        case portForwards
        case state
        case startingExpiresAtUnixMilliseconds
        case createdAtUnixMilliseconds
        case updatedAtUnixMilliseconds
        case evidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(UInt16.self, forKey: .schemaVersion)
        guard schemaVersion == 1 || schemaVersion == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported resource admission lease schema."
            )
        }
        leaseID = try container.decode(String.self, forKey: .leaseID)
        leaseRevision = try container.decode(UInt64.self, forKey: .leaseRevision)
        binding = try container.decode(
            DoryVirtualMachineResourceAdmissionPlanBinding.self,
            forKey: .binding
        )
        boundPlanSHA256 = try container.decodeIfPresent(String.self, forKey: .boundPlanSHA256)
        hostFacts = try container.decode(DoryVMHostResources.self, forKey: .hostFacts)
        hostFactsSHA256 = try container.decode(String.self, forKey: .hostFactsSHA256)
        workload = try container.decode(DoryVMWorkloadProfile.self, forKey: .workload)
        requirements = try container.decode(
            [DoryVMResourceRequirement].self,
            forKey: .requirements
        )
        resources = try container.decode(DoryVMResourceRequest.self, forKey: .resources)
        if schemaVersion == 1 {
            guard !container.contains(.portForwards) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .portForwards,
                    in: container,
                    debugDescription: "Schema-1 leases cannot contain port-forward authority."
                )
            }
            portForwards = []
        } else {
            portForwards = try container.decode(
                [DoryVMPortForward].self,
                forKey: .portForwards
            )
        }
        state = try container.decode(
            DoryVirtualMachineResourceLeaseState.self,
            forKey: .state
        )
        startingExpiresAtUnixMilliseconds = try container.decodeIfPresent(
            Int64.self,
            forKey: .startingExpiresAtUnixMilliseconds
        )
        createdAtUnixMilliseconds = try container.decode(
            Int64.self,
            forKey: .createdAtUnixMilliseconds
        )
        updatedAtUnixMilliseconds = try container.decode(
            Int64.self,
            forKey: .updatedAtUnixMilliseconds
        )
        evidence = try container.decode(
            DoryResolvedMachineResourceAdmissionEvidence.self,
            forKey: .evidence
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(leaseID, forKey: .leaseID)
        try container.encode(leaseRevision, forKey: .leaseRevision)
        try container.encode(binding, forKey: .binding)
        try container.encodeIfPresent(boundPlanSHA256, forKey: .boundPlanSHA256)
        try container.encode(hostFacts, forKey: .hostFacts)
        try container.encode(hostFactsSHA256, forKey: .hostFactsSHA256)
        try container.encode(workload, forKey: .workload)
        try container.encode(requirements, forKey: .requirements)
        try container.encode(resources, forKey: .resources)
        if schemaVersion >= 2 {
            try container.encode(portForwards, forKey: .portForwards)
        }
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(
            startingExpiresAtUnixMilliseconds,
            forKey: .startingExpiresAtUnixMilliseconds
        )
        try container.encode(createdAtUnixMilliseconds, forKey: .createdAtUnixMilliseconds)
        try container.encode(updatedAtUnixMilliseconds, forKey: .updatedAtUnixMilliseconds)
        try container.encode(evidence, forKey: .evidence)
    }

    fileprivate static func digest<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct DoryVirtualMachineResourceAdmissionLedgerSnapshot: Sendable, Equatable {
    public var ledgerRevision: UInt64
    public var leases: [DoryVirtualMachineResourceAdmissionLease]

    public init(
        ledgerRevision: UInt64,
        leases: [DoryVirtualMachineResourceAdmissionLease]
    ) {
        self.ledgerRevision = ledgerRevision
        self.leases = leases
    }
}

/// Opaque daemon-only proof that a lifecycle fence observed no process using a bound planning
/// lease. It is not Codable and has no public initializer, so API/UI callers cannot recover an
/// ambiguous lease.
public struct DoryVirtualMachineBoundPlanningLeaseRecoveryAuthorization: Sendable {
    let machineID: String
    let planSHA256: String

    init(machineID: String, planSHA256: String) {
        self.machineID = machineID
        self.planSHA256 = planSHA256
    }
}

public enum DoryVirtualMachineResourceAdmissionLedgerError:
    Error, Sendable, Equatable, CustomStringConvertible
{
    case invalidBinding
    case invalidHostFacts
    case invalidPortForwardContract
    case invalidLeaseDuration
    case capacityUnavailable([DoryVMResourceValidationIssue])
    case machineAlreadyReserved(String)
    case leaseNotFound(String)
    case staleLedgerRevision(expected: UInt64, actual: UInt64)
    case staleLeaseRevision(expected: UInt64, actual: UInt64)
    case invalidLeaseState(DoryVirtualMachineResourceLeaseState)
    case storageReservationCannotShrink(existing: UInt64, requested: UInt64)
    case portBindingUnavailable(
        transport: DoryVMPortForwardTransport,
        hostPort: UInt16,
        machineID: String
    )
    case planAlreadyBound
    case planMismatch
    case hostFactsMismatch
    case arithmeticOverflow
    case invalidRecord
    case filesystem(String)

    public var description: String {
        switch self {
        case .invalidBinding: "resource admission plan binding is invalid"
        case .invalidHostFacts: "host resource facts are invalid"
        case .invalidPortForwardContract: "port-forward admission contract is invalid"
        case .invalidLeaseDuration: "starting lease duration is invalid"
        case .capacityUnavailable: "host capacity cannot admit the requested virtual machine"
        case let .machineAlreadyReserved(machineID):
            "machine already has a resource reservation: \(machineID)"
        case let .leaseNotFound(leaseID): "resource admission lease not found: \(leaseID)"
        case let .staleLedgerRevision(expected, actual):
            "stale resource ledger revision: expected \(expected), found \(actual)"
        case let .staleLeaseRevision(expected, actual):
            "stale resource lease revision: expected \(expected), found \(actual)"
        case let .invalidLeaseState(state):
            "resource lease has invalid state: \(state.rawValue)"
        case let .storageReservationCannotShrink(existing, requested):
            "storage reservation cannot shrink from \(existing) to \(requested) bytes"
        case let .portBindingUnavailable(transport, hostPort, machineID):
            "host \(transport.rawValue) port \(hostPort) is reserved by machine \(machineID)"
        case .planAlreadyBound: "resource admission lease is already bound to a plan"
        case .planMismatch: "resolved plan does not match the admitted resource lease"
        case .hostFactsMismatch: "current host facts do not match the admitted snapshot"
        case .arithmeticOverflow: "resource commitment arithmetic overflow"
        case .invalidRecord: "resource admission ledger record is invalid or tampered"
        case let .filesystem(message): message
        }
    }
}

private final class DoryVirtualMachineResourceAdmissionProcessLockRegistry:
    @unchecked Sendable
{
    private let registryLock = NSLock()
    private var locks: [String: NSLock] = [:]

    func lock(for root: String) -> NSLock {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = locks[root] { return existing }
        let created = NSLock()
        locks[root] = created
        return created
    }
}

/// Durable admission authority for VM starts. Callers provide host facts excluding leases owned by
/// this ledger; the ledger composes those facts with all starting/running CPU and RAM commitments
/// and every durable disk reservation under one cross-process lock.
public final class DoryVirtualMachineResourceAdmissionLedger: @unchecked Sendable {
    public static let assessorIdentifier = "dory.resource-admission-ledger"
    public static let assessorVersion: UInt16 = 1

    private static let recordFilename = "resource-admissions.json"
    private static let lockFilename = ".resource-admissions.lock"
    private static let temporaryPrefix = ".resource-admissions."
    private static let maximumRecordBytes = 4 * 1_024 * 1_024
    private static let maximumStartingLeaseDurationMilliseconds: Int64 = 86_400_000
    private static let processLockRegistry =
        DoryVirtualMachineResourceAdmissionProcessLockRegistry()

    public let root: String
    private let processLock: NSLock
    private let now: @Sendable () -> Int64

    public init(root: String) {
        let standardizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        self.root = standardizedRoot
        processLock = Self.processLockRegistry.lock(for: standardizedRoot)
        now = { Int64(Date().timeIntervalSince1970 * 1_000) }
    }

    init(root: String, now: @escaping @Sendable () -> Int64) {
        let standardizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        self.root = standardizedRoot
        processLock = Self.processLockRegistry.lock(for: standardizedRoot)
        self.now = now
    }

    /// Atomically reserves a starting slot. The returned evidence is the only admission evidence
    /// that should be embedded in the plan subsequently bound with `bind`.
    public func reserveStarting(
        binding: DoryVirtualMachineResourceAdmissionPlanBinding,
        hostFacts: DoryVMHostResources,
        workload: DoryVMWorkloadProfile,
        requirements: [DoryVMResourceRequirement] = [],
        resources: DoryVMResourceRequest,
        portForwards: [DoryVMPortForward] = [],
        startingLeaseDurationMilliseconds: Int64 = 120_000,
        expectedLedgerRevision: UInt64? = nil
    ) throws -> DoryVirtualMachineResourceAdmissionLease {
        try withExclusiveAccess {
            let timestamp = now()
            var record = try readRecord()
            let recovered = try recoverExpired(in: &record, at: timestamp)
            try validateExpectedLedgerRevision(expectedLedgerRevision, actual: record.ledgerRevision)
            try Self.validate(binding)
            try Self.validate(hostFacts)
            try Self.validate(portForwards)
            guard startingLeaseDurationMilliseconds > 0,
                  startingLeaseDurationMilliseconds
                    <= Self.maximumStartingLeaseDurationMilliseconds,
                  timestamp > 0,
                  timestamp <= Int64.max - startingLeaseDurationMilliseconds else {
                throw DoryVirtualMachineResourceAdmissionLedgerError.invalidLeaseDuration
            }
            let stoppedLeaseIndex = record.leases.firstIndex {
                $0.binding.machineID == binding.machineID && $0.state == .stopped
            }
            let stoppedLease = stoppedLeaseIndex.map { record.leases[$0] }
            guard !record.leases.contains(where: {
                $0.binding.machineID == binding.machineID && $0.state != .stopped
            }) else {
                throw DoryVirtualMachineResourceAdmissionLedgerError.machineAlreadyReserved(
                    binding.machineID
                )
            }
            if let stoppedLease,
               resources.diskBytes < stoppedLease.resources.diskBytes {
                if recovered { try persistRecoveredRecord(&record) }
                throw DoryVirtualMachineResourceAdmissionLedgerError
                    .storageReservationCannotShrink(
                        existing: stoppedLease.resources.diskBytes,
                        requested: resources.diskBytes
                    )
            }
            // A restart atomically replaces the stopped reservation. Excluding that lease from
            // assessment prevents double-counting its disk while the lock prevents any interval
            // in which another admission could consume the released capacity.
            let leasesBeingRetained = record.leases.enumerated().compactMap { index, lease in
                index == stoppedLeaseIndex ? nil : lease
            }
            do {
                try Self.validatePortAvailability(
                    portForwards,
                    for: binding.machineID,
                    among: leasesBeingRetained
                )
            } catch {
                if recovered { try persistRecoveredRecord(&record) }
                throw error
            }
            let commitments = try Self.commitments(in: leasesBeingRetained)
            let assessedHost = try Self.composing(
                hostFacts,
                runtime: commitments.runtime,
                storage: commitments.storage
            )
            let sortedRequirements = requirements.sorted(by: Self.requirementOrder)
            let assessment = DoryVMResourcePolicy.assess(
                host: assessedHost,
                workload: workload,
                requirements: sortedRequirements,
                request: resources
            )
            let errors = assessment.issues.filter { $0.severity == .error }
            guard errors.isEmpty else {
                if recovered { try persistRecoveredRecord(&record) }
                throw DoryVirtualMachineResourceAdmissionLedgerError.capacityUnavailable(errors)
            }
            let leaseID = stoppedLease?.leaseID
                ?? "resource-lease-\(UUID().uuidString.lowercased())"
            let evidence = Self.makeEvidence(
                leaseID: leaseID,
                binding: binding,
                hostFacts: hostFacts,
                assessedHost: assessedHost,
                workload: workload,
                requirements: sortedRequirements,
                resources: resources,
                reserve: assessment.recommendation.hostReserve
            )
            var lease = DoryVirtualMachineResourceAdmissionLease(
                leaseID: leaseID,
                binding: binding,
                hostFacts: hostFacts,
                workload: workload,
                requirements: sortedRequirements,
                resources: resources,
                portForwards: portForwards,
                startingExpiresAtUnixMilliseconds: timestamp
                    + startingLeaseDurationMilliseconds,
                createdAtUnixMilliseconds: timestamp,
                evidence: evidence
            )
            if let stoppedLeaseIndex, let stoppedLease {
                lease.leaseRevision = try Self.incrementing(stoppedLease.leaseRevision)
                record.leases[stoppedLeaseIndex] = lease
            } else {
                record.leases.append(lease)
            }
            try advanceAndPublish(&record)
            return lease
        }
    }

    /// Completes the two-phase admission by pinning the exact canonical plan bytes. This closes
    /// the circular dependency between admission evidence embedded in a plan and the final digest.
    public func bind(
        leaseID: String,
        to plan: DoryResolvedMachinePlan,
        expectedLeaseRevision: UInt64
    ) throws -> DoryVirtualMachineResourceAdmissionLease {
        try withExclusiveAccess {
            let timestamp = now()
            var record = try readRecord()
            _ = try recoverExpired(in: &record, at: timestamp)
            let index = try leaseIndex(leaseID, in: record)
            var lease = record.leases[index]
            try Self.validateLeaseRevision(expectedLeaseRevision, lease)
            guard lease.state == .starting else {
                throw DoryVirtualMachineResourceAdmissionLedgerError.invalidLeaseState(lease.state)
            }
            guard lease.boundPlanSHA256 == nil else {
                throw DoryVirtualMachineResourceAdmissionLedgerError.planAlreadyBound
            }
            try Self.validate(plan, against: lease, requireBoundDigest: false)
            lease.boundPlanSHA256 = Self.planSHA256(plan)
            lease.leaseRevision = try Self.incrementing(lease.leaseRevision)
            lease.updatedAtUnixMilliseconds = timestamp
            record.leases[index] = lease
            try advanceAndPublish(&record)
            return lease
        }
    }

    /// Compensates a planning attempt that failed before its lease was bound to exact plan bytes.
    /// CPU and memory are released, while the durable storage reservation is retained. A bound
    /// lease is never cancelled here because a process may already have consumed its authority.
    public func cancelUnboundStarting(
        leaseID: String,
        expectedLeaseRevision: UInt64
    ) throws -> DoryVirtualMachineResourceAdmissionLease {
        try withExclusiveAccess {
            let timestamp = now()
            var record = try readRecord()
            _ = try recoverExpired(in: &record, at: timestamp)
            let index = try leaseIndex(leaseID, in: record)
            var lease = record.leases[index]
            try Self.validateLeaseRevision(expectedLeaseRevision, lease)
            guard lease.state == .starting, lease.boundPlanSHA256 == nil else {
                throw DoryVirtualMachineResourceAdmissionLedgerError.invalidLeaseState(lease.state)
            }
            lease.state = .stopped
            lease.startingExpiresAtUnixMilliseconds = nil
            lease.leaseRevision = try Self.incrementing(lease.leaseRevision)
            lease.updatedAtUnixMilliseconds = timestamp
            record.leases[index] = lease
            try advanceAndPublish(&record)
            return lease
        }
    }

    /// Revalidates an already bound starting lease against exact plan bytes and the same daemon
    /// host snapshot. It never replans or silently refreshes evidence.
    public func revalidateForStart(
        leaseID: String,
        plan: DoryResolvedMachinePlan,
        hostFacts: DoryVMHostResources
    ) throws -> DoryResolvedMachineResourceAdmissionEvidence {
        try withExclusiveAccess {
            let timestamp = now()
            var record = try readRecord()
            let recovered = try recoverExpired(in: &record, at: timestamp)
            if recovered { try persistRecoveredRecord(&record) }
            let index = try leaseIndex(leaseID, in: record)
            let lease = record.leases[index]
            guard lease.state == .starting else {
                throw DoryVirtualMachineResourceAdmissionLedgerError.invalidLeaseState(lease.state)
            }
            guard hostFacts == lease.hostFacts,
                  DoryVirtualMachineResourceAdmissionLease.digest(hostFacts)
                    == lease.hostFactsSHA256 else {
                throw DoryVirtualMachineResourceAdmissionLedgerError.hostFactsMismatch
            }
            try Self.validate(plan, against: lease, requireBoundDigest: true)
            try Self.validateCapacity(record.leases, hostFacts: hostFacts)
            return lease.evidence
        }
    }

    /// Renews a bound planning lease that expired before definition/plan publication. The caller
    /// must hold a daemon lifecycle fence proving the exact plan never launched. Admission facts,
    /// evidence, and bound plan bytes remain unchanged; no capacity is released or re-granted.
    public func recoverBoundPlanningLease(
        leaseID: String,
        plan: DoryResolvedMachinePlan,
        authorization: DoryVirtualMachineBoundPlanningLeaseRecoveryAuthorization,
        startingLeaseDurationMilliseconds: Int64,
        expectedLeaseRevision: UInt64
    ) throws -> DoryVirtualMachineResourceAdmissionLease {
        try withExclusiveAccess {
            let timestamp = now()
            guard startingLeaseDurationMilliseconds > 0,
                  startingLeaseDurationMilliseconds
                    <= Self.maximumStartingLeaseDurationMilliseconds,
                  timestamp > 0,
                  timestamp <= Int64.max - startingLeaseDurationMilliseconds else {
                throw DoryVirtualMachineResourceAdmissionLedgerError.invalidLeaseDuration
            }
            var record = try readRecord()
            _ = try recoverExpired(in: &record, at: timestamp)
            let index = try leaseIndex(leaseID, in: record)
            var lease = record.leases[index]
            try Self.validateLeaseRevision(expectedLeaseRevision, lease)
            guard lease.state == .recoveryRequired else {
                throw DoryVirtualMachineResourceAdmissionLedgerError.invalidLeaseState(lease.state)
            }
            let digest = Self.planSHA256(plan)
            guard authorization.machineID == lease.binding.machineID,
                  authorization.machineID == plan.machineID,
                  authorization.planSHA256 == digest,
                  lease.boundPlanSHA256 == digest else {
                throw DoryVirtualMachineResourceAdmissionLedgerError.planMismatch
            }
            try Self.validate(plan, against: lease, requireBoundDigest: true)
            try Self.validateCapacity(record.leases, hostFacts: lease.hostFacts)
            lease.state = .starting
            lease.startingExpiresAtUnixMilliseconds = timestamp
                + startingLeaseDurationMilliseconds
            lease.leaseRevision = try Self.incrementing(lease.leaseRevision)
            lease.updatedAtUnixMilliseconds = timestamp
            record.leases[index] = lease
            try advanceAndPublish(&record)
            return lease
        }
    }

    public func markRunning(
        leaseID: String,
        plan: DoryResolvedMachinePlan,
        hostFacts: DoryVMHostResources,
        expectedLeaseRevision: UInt64
    ) throws -> DoryVirtualMachineResourceAdmissionLease {
        try withExclusiveAccess {
            let timestamp = now()
            var record = try readRecord()
            _ = try recoverExpired(in: &record, at: timestamp)
            let index = try leaseIndex(leaseID, in: record)
            var lease = record.leases[index]
            try Self.validateLeaseRevision(expectedLeaseRevision, lease)
            guard lease.state == .starting else {
                throw DoryVirtualMachineResourceAdmissionLedgerError.invalidLeaseState(lease.state)
            }
            guard hostFacts == lease.hostFacts,
                  DoryVirtualMachineResourceAdmissionLease.digest(hostFacts)
                    == lease.hostFactsSHA256 else {
                throw DoryVirtualMachineResourceAdmissionLedgerError.hostFactsMismatch
            }
            try Self.validate(plan, against: lease, requireBoundDigest: true)
            try Self.validateCapacity(record.leases, hostFacts: hostFacts)
            lease.state = .running
            lease.startingExpiresAtUnixMilliseconds = nil
            lease.leaseRevision = try Self.incrementing(lease.leaseRevision)
            lease.updatedAtUnixMilliseconds = timestamp
            record.leases[index] = lease
            try advanceAndPublish(&record)
            return lease
        }
    }

    /// Reopens the same exact running admission for a daemon-controlled restart that did not
    /// change guest or plan authority (for example, quiescing a VM to take a snapshot). Runtime
    /// capacity remains reserved throughout the stop/restart window; this does not re-admit a
    /// stopped VM or authorize a changed plan.
    func prepareRetainedRunningForRestart(
        leaseID: String,
        plan: DoryResolvedMachinePlan,
        startingLeaseDurationMilliseconds: Int64 = 120_000,
        expectedLeaseRevision: UInt64
    ) throws -> DoryVirtualMachineResourceAdmissionLease {
        try withExclusiveAccess {
            let timestamp = now()
            guard startingLeaseDurationMilliseconds > 0,
                  startingLeaseDurationMilliseconds
                    <= Self.maximumStartingLeaseDurationMilliseconds,
                  timestamp > 0,
                  timestamp <= Int64.max - startingLeaseDurationMilliseconds else {
                throw DoryVirtualMachineResourceAdmissionLedgerError.invalidLeaseDuration
            }
            var record = try readRecord()
            _ = try recoverExpired(in: &record, at: timestamp)
            let index = try leaseIndex(leaseID, in: record)
            var lease = record.leases[index]
            try Self.validateLeaseRevision(expectedLeaseRevision, lease)
            guard lease.state == .running else {
                throw DoryVirtualMachineResourceAdmissionLedgerError.invalidLeaseState(lease.state)
            }
            try Self.validate(plan, against: lease, requireBoundDigest: true)
            try Self.validateCapacity(record.leases, hostFacts: lease.hostFacts)
            lease.state = .starting
            lease.startingExpiresAtUnixMilliseconds = timestamp
                + startingLeaseDurationMilliseconds
            lease.leaseRevision = try Self.incrementing(lease.leaseRevision)
            lease.updatedAtUnixMilliseconds = timestamp
            record.leases[index] = lease
            try advanceAndPublish(&record)
            return lease
        }
    }

    /// Releases CPU and RAM after stop while intentionally retaining the disk reservation.
    public func markStopped(
        leaseID: String,
        expectedLeaseRevision: UInt64
    ) throws -> DoryVirtualMachineResourceAdmissionLease {
        try withExclusiveAccess {
            let timestamp = now()
            var record = try readRecord()
            _ = try recoverExpired(in: &record, at: timestamp)
            let index = try leaseIndex(leaseID, in: record)
            var lease = record.leases[index]
            try Self.validateLeaseRevision(expectedLeaseRevision, lease)
            guard lease.state == .starting || lease.state == .running,
                  lease.boundPlanSHA256 != nil else {
                throw DoryVirtualMachineResourceAdmissionLedgerError.invalidLeaseState(lease.state)
            }
            lease.state = .stopped
            lease.startingExpiresAtUnixMilliseconds = nil
            lease.leaseRevision = try Self.incrementing(lease.leaseRevision)
            lease.updatedAtUnixMilliseconds = timestamp
            record.leases[index] = lease
            try advanceAndPublish(&record)
            return lease
        }
    }

    /// Resolves an expired bound start using daemon-observed runtime state. Until this explicit
    /// reconciliation, recovery-required leases retain CPU, memory, and storage reservations.
    public func reconcileExpiredStart(
        leaseID: String,
        observedRuntimeState: DoryVirtualMachineObservedRuntimeState,
        expectedLeaseRevision: UInt64
    ) throws -> DoryVirtualMachineResourceAdmissionLease {
        try withExclusiveAccess {
            let timestamp = now()
            var record = try readRecord()
            _ = try recoverExpired(in: &record, at: timestamp)
            let index = try leaseIndex(leaseID, in: record)
            var lease = record.leases[index]
            try Self.validateLeaseRevision(expectedLeaseRevision, lease)
            guard lease.state == .recoveryRequired else {
                throw DoryVirtualMachineResourceAdmissionLedgerError.invalidLeaseState(lease.state)
            }
            lease.state = observedRuntimeState == .running ? .running : .stopped
            lease.startingExpiresAtUnixMilliseconds = nil
            lease.leaseRevision = try Self.incrementing(lease.leaseRevision)
            lease.updatedAtUnixMilliseconds = timestamp
            record.leases[index] = lease
            try advanceAndPublish(&record)
            return lease
        }
    }

    /// Deletes the durable disk reservation. This belongs on machine/storage deletion, not stop.
    public func releaseStorageReservation(
        leaseID: String,
        expectedLeaseRevision: UInt64
    ) throws {
        try withExclusiveAccess {
            var record = try readRecord()
            _ = try recoverExpired(in: &record, at: now())
            let index = try leaseIndex(leaseID, in: record)
            try Self.validateLeaseRevision(expectedLeaseRevision, record.leases[index])
            guard record.leases[index].state == .stopped else {
                throw DoryVirtualMachineResourceAdmissionLedgerError.invalidLeaseState(
                    record.leases[index].state
                )
            }
            record.leases.remove(at: index)
            try advanceAndPublish(&record)
        }
    }

    /// Reading also performs deterministic expiry recovery under the ledger lock.
    public func snapshot() throws -> DoryVirtualMachineResourceAdmissionLedgerSnapshot {
        try withExclusiveAccess {
            var record = try readRecord()
            if try recoverExpired(in: &record, at: now()) {
                try persistRecoveredRecord(&record)
            }
            return DoryVirtualMachineResourceAdmissionLedgerSnapshot(
                ledgerRevision: record.ledgerRevision,
                leases: record.leases.sorted { $0.binding.machineID < $1.binding.machineID }
            )
        }
    }

    private struct LedgerRecord: Codable, Sendable, Equatable {
        static let schemaVersion: UInt16 = 1
        var schemaVersion: UInt16 = schemaVersion
        var ledgerRevision: UInt64 = 0
        var leases: [DoryVirtualMachineResourceAdmissionLease] = []
    }

    private struct LedgerEnvelope: Codable, Sendable, Equatable {
        var recordSHA256: String
        var record: LedgerRecord
    }

    private struct Commitments {
        var runtime: DoryVMResourceRequest
        var storage: UInt64
    }

    private struct AdmissionReport: Codable {
        var leaseID: String
        var binding: DoryVirtualMachineResourceAdmissionPlanBinding
        var hostFactsSHA256: String
        var workload: DoryVMWorkloadProfile
        var requirements: [DoryVMResourceRequirement]
        var resources: DoryVMResourceRequest
        var hostReserve: DoryVMHostReserve
        var existingVirtualCPUCommitment: UInt64
        var existingMemoryCommitmentBytes: UInt64
        var existingStorageReservationBytes: UInt64
        var assessorIdentifier: String
        var assessorVersion: UInt16
    }

    private func withExclusiveAccess<T>(_ body: () throws -> T) throws -> T {
        try processLock.withLock {
            try Self.ensurePrivateDirectory(root)
            let path = root + "/" + Self.lockFilename
            let descriptor = path.withCString {
                open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
            }
            guard descriptor >= 0 else { throw filesystem("open resource admission lock") }
            defer { close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_uid == geteuid(),
                  status.st_nlink == 1,
                  status.st_mode & 0o077 == 0 else {
                throw DoryVirtualMachineResourceAdmissionLedgerError.invalidRecord
            }
            while flock(descriptor, LOCK_EX) != 0 {
                guard errno == EINTR else { throw filesystem("lock resource admission ledger") }
            }
            defer { _ = flock(descriptor, LOCK_UN) }
            try cleanupTemporaryFiles()
            return try body()
        }
    }

    private func readRecord() throws -> LedgerRecord {
        let path = root + "/" + Self.recordFilename
        var initial = stat()
        guard lstat(path, &initial) == 0 else {
            if errno == ENOENT { return LedgerRecord() }
            throw filesystem("inspect resource admission ledger")
        }
        let descriptor = path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw DoryVirtualMachineResourceAdmissionLedgerError.invalidRecord
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_mode & 0o077 == 0,
              status.st_size > 0,
              status.st_size <= Self.maximumRecordBytes else {
            throw DoryVirtualMachineResourceAdmissionLedgerError.invalidRecord
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0, data.count + count <= Self.maximumRecordBytes else {
                throw DoryVirtualMachineResourceAdmissionLedgerError.invalidRecord
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let envelope = try? JSONDecoder().decode(LedgerEnvelope.self, from: data),
              data == Self.canonicalData(envelope) + Data("\n".utf8),
              envelope.recordSHA256 == Self.digest(Self.canonicalData(envelope.record)) else {
            throw DoryVirtualMachineResourceAdmissionLedgerError.invalidRecord
        }
        try Self.validate(envelope.record)
        return envelope.record
    }

    private func advanceAndPublish(_ record: inout LedgerRecord) throws {
        record.ledgerRevision = try Self.incrementing(record.ledgerRevision)
        record.leases.sort { $0.binding.machineID < $1.binding.machineID }
        try publish(record)
    }

    private func persistRecoveredRecord(_ record: inout LedgerRecord) throws {
        try advanceAndPublish(&record)
    }

    private func publish(_ record: LedgerRecord) throws {
        try Self.validate(record)
        let envelope = LedgerEnvelope(
            recordSHA256: Self.digest(Self.canonicalData(record)),
            record: record
        )
        let data = Self.canonicalData(envelope) + Data("\n".utf8)
        let temporary = root + "/\(Self.temporaryPrefix)\(UUID().uuidString)"
        let descriptor = temporary.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw filesystem("create resource admission record") }
        var isOpen = true
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(
                        descriptor,
                        bytes.baseAddress!.advanced(by: offset),
                        bytes.count - offset
                    )
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw filesystem("write resource admission record") }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else { throw filesystem("sync resource admission record") }
            close(descriptor)
            isOpen = false
            guard rename(temporary, root + "/" + Self.recordFilename) == 0 else {
                throw filesystem("publish resource admission record")
            }
            try Self.syncDirectory(root)
        } catch {
            if isOpen { close(descriptor) }
            unlink(temporary)
            throw error
        }
    }

    private func cleanupTemporaryFiles() throws {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: root)
        } catch {
            throw filesystem("enumerate resource admission directory")
        }
        for name in names where name.hasPrefix(Self.temporaryPrefix) {
            let path = root + "/" + name
            var status = stat()
            guard lstat(path, &status) == 0 else { continue }
            guard status.st_uid == geteuid() else {
                throw DoryVirtualMachineResourceAdmissionLedgerError.invalidRecord
            }
            guard unlink(path) == 0 || errno == ENOENT else {
                throw filesystem("remove stale resource admission temporary file")
            }
        }
    }

    private func recoverExpired(
        in record: inout LedgerRecord,
        at timestamp: Int64
    ) throws -> Bool {
        guard timestamp > 0 else {
            throw DoryVirtualMachineResourceAdmissionLedgerError.invalidLeaseDuration
        }
        var changed = false
        var recovered: [DoryVirtualMachineResourceAdmissionLease] = []
        for var lease in record.leases {
            guard lease.state == .starting,
                  let expiry = lease.startingExpiresAtUnixMilliseconds,
                  expiry <= timestamp else {
                recovered.append(lease)
                continue
            }
            changed = true
            // Binding is the launch boundary. An unbound start cannot have launched, so CPU and
            // memory are released, but storage is always durable and requires explicit release.
            // A bound start may have launched before daemon failure and retains every commitment
            // until a daemon-owned process observation resolves that ambiguity.
            lease.state = lease.boundPlanSHA256 == nil ? .stopped : .recoveryRequired
            lease.startingExpiresAtUnixMilliseconds = nil
            lease.leaseRevision = try Self.incrementing(lease.leaseRevision)
            lease.updatedAtUnixMilliseconds = timestamp
            recovered.append(lease)
        }
        if changed { record.leases = recovered }
        return changed
    }

    private func leaseIndex(_ leaseID: String, in record: LedgerRecord) throws -> Int {
        guard let index = record.leases.firstIndex(where: { $0.leaseID == leaseID }) else {
            throw DoryVirtualMachineResourceAdmissionLedgerError.leaseNotFound(leaseID)
        }
        return index
    }

    private func validateExpectedLedgerRevision(_ expected: UInt64?, actual: UInt64) throws {
        guard let expected else { return }
        guard expected == actual else {
            throw DoryVirtualMachineResourceAdmissionLedgerError.staleLedgerRevision(
                expected: expected,
                actual: actual
            )
        }
    }

    private static func validateLeaseRevision(
        _ expected: UInt64,
        _ lease: DoryVirtualMachineResourceAdmissionLease
    ) throws {
        guard expected == lease.leaseRevision else {
            throw DoryVirtualMachineResourceAdmissionLedgerError.staleLeaseRevision(
                expected: expected,
                actual: lease.leaseRevision
            )
        }
    }

    private static func validate(
        _ plan: DoryResolvedMachinePlan,
        against lease: DoryVirtualMachineResourceAdmissionLease,
        requireBoundDigest: Bool
    ) throws {
        guard plan.validate().isEmpty,
              plan.machineID == lease.binding.machineID,
              plan.definitionRevision == lease.binding.definitionRevision,
              plan.definitionSHA256?.lowercased() == lease.binding.definitionSHA256.lowercased(),
              plan.planRevision == lease.binding.plannedPlanRevision,
              plan.portForwards == lease.portForwards,
              plan.resourceAdmission == lease.evidence else {
            throw DoryVirtualMachineResourceAdmissionLedgerError.planMismatch
        }
        if requireBoundDigest {
            guard let bound = lease.boundPlanSHA256,
                  bound == planSHA256(plan) else {
                throw DoryVirtualMachineResourceAdmissionLedgerError.planMismatch
            }
        }
    }

    private static func validate(_ binding: DoryVirtualMachineResourceAdmissionPlanBinding) throws {
        let machine = Array(binding.machineID.utf8)
        guard (1...63).contains(machine.count),
              let first = machine.first,
              isAlphaNumeric(first),
              machine.dropFirst().allSatisfy({ isAlphaNumeric($0) || $0 == 45 || $0 == 46 || $0 == 95 }),
              binding.definitionRevision > 0,
              DoryResolvedMachinePlan.isSHA256(binding.definitionSHA256),
              binding.plannedPlanRevision > 0 else {
            throw DoryVirtualMachineResourceAdmissionLedgerError.invalidBinding
        }
    }

    private static func validate(_ host: DoryVMHostResources) throws {
        guard host.logicalCPUCount > 0,
              host.physicalMemoryBytes > 0,
              host.freeStorageBytes > 0,
              host.admittedVirtualCPUCount <= host.logicalCPUCount,
              host.admittedMemoryBytes <= host.physicalMemoryBytes,
              host.reservedStorageBytes <= host.freeStorageBytes else {
            throw DoryVirtualMachineResourceAdmissionLedgerError.invalidHostFacts
        }
    }

    private static func validate(_ portForwards: [DoryVMPortForward]) throws {
        guard portForwards.count <= DoryVMPortForward.maximumCount else {
            throw DoryVirtualMachineResourceAdmissionLedgerError.invalidPortForwardContract
        }
        var identifiers: Set<String> = []
        var bindings: Set<String> = []
        for forward in portForwards {
            let identifier = Array(forward.id.utf8)
            guard (1...63).contains(identifier.count),
                  identifier.first.map(isAlphaNumeric) == true,
                  identifier.dropFirst().allSatisfy({
                      isAlphaNumeric($0) || $0 == 45 || $0 == 46 || $0 == 95
                  }),
                  identifiers.insert(forward.id).inserted,
                  forward.hostPort >= 1_024,
                  forward.guestPort > 0,
                  bindings.insert(Self.portBindingKey(forward)).inserted else {
                throw DoryVirtualMachineResourceAdmissionLedgerError.invalidPortForwardContract
            }
        }
    }

    private static func validatePortAvailability(
        _ requested: [DoryVMPortForward],
        for machineID: String,
        among leases: [DoryVirtualMachineResourceAdmissionLease]
    ) throws {
        let active = leases.filter {
            $0.state == .starting || $0.state == .running || $0.state == .recoveryRequired
        }
        for forward in requested {
            let key = portBindingKey(forward)
            if let owner = active.first(where: { lease in
                lease.binding.machineID != machineID
                    && lease.portForwards.contains(where: { portBindingKey($0) == key })
            }) {
                throw DoryVirtualMachineResourceAdmissionLedgerError.portBindingUnavailable(
                    transport: forward.transport,
                    hostPort: forward.hostPort,
                    machineID: owner.binding.machineID
                )
            }
        }
    }

    private static func portBindingKey(_ forward: DoryVMPortForward) -> String {
        "\(forward.transport.rawValue):\(forward.hostPort)"
    }

    private static func validate(_ record: LedgerRecord) throws {
        guard record.schemaVersion == LedgerRecord.schemaVersion,
              record.ledgerRevision > 0,
              Set(record.leases.map(\.leaseID)).count == record.leases.count,
              Set(record.leases.map { $0.binding.machineID }).count == record.leases.count else {
            throw DoryVirtualMachineResourceAdmissionLedgerError.invalidRecord
        }
        for lease in record.leases {
            do {
                try validate(lease.binding)
                try validate(lease.hostFacts)
            } catch {
                throw DoryVirtualMachineResourceAdmissionLedgerError.invalidRecord
            }
            guard (lease.schemaVersion == 1
                    || lease.schemaVersion
                        == DoryVirtualMachineResourceAdmissionLease.schemaVersion),
                  isSafeIdentifier(lease.leaseID),
                  lease.leaseRevision > 0,
                  lease.createdAtUnixMilliseconds > 0,
                  lease.updatedAtUnixMilliseconds >= lease.createdAtUnixMilliseconds,
                  lease.hostFactsSHA256
                    == DoryVirtualMachineResourceAdmissionLease.digest(lease.hostFacts),
                  lease.resources.virtualCPUCount > 0,
                  lease.resources.memoryBytes > 0,
                  lease.resources.diskBytes > 0,
                  lease.requirements == lease.requirements.sorted(by: requirementOrder),
                  lease.evidence.admittedVirtualCPUCount == lease.resources.virtualCPUCount,
                  lease.evidence.admittedMemoryBytes == lease.resources.memoryBytes,
                  lease.evidence.admittedStorageBytes == lease.resources.diskBytes,
                  lease.evidence.hostLogicalCPUCount == lease.hostFacts.logicalCPUCount,
                  lease.evidence.hostPhysicalMemoryBytes == lease.hostFacts.physicalMemoryBytes,
                  lease.evidence.hostFreeStorageBytes == lease.hostFacts.freeStorageBytes,
                  lease.evidence.existingVirtualCPUCommitment
                    >= lease.hostFacts.admittedVirtualCPUCount,
                  lease.evidence.existingMemoryCommitmentBytes
                    >= lease.hostFacts.admittedMemoryBytes,
                  lease.evidence.existingStorageReservationBytes
                    >= lease.hostFacts.reservedStorageBytes,
                  lease.evidence.assessorIdentifier == assessorIdentifier,
                  lease.evidence.assessorVersion == assessorVersion,
                  lease.evidence.admissionIdentity == lease.leaseID,
                  lease.evidence.admissionReportSHA256 == admissionReportSHA256(lease),
                  lease.boundPlanSHA256.map(DoryResolvedMachinePlan.isSHA256) ?? true else {
                throw DoryVirtualMachineResourceAdmissionLedgerError.invalidRecord
            }
            do {
                try validate(lease.portForwards)
                guard lease.schemaVersion >= 2 || lease.portForwards.isEmpty else {
                    throw DoryVirtualMachineResourceAdmissionLedgerError.invalidRecord
                }
            } catch {
                throw DoryVirtualMachineResourceAdmissionLedgerError.invalidRecord
            }
            let reserve = DoryVMResourcePolicy.recommend(
                host: lease.hostFacts,
                workload: lease.workload,
                requirements: lease.requirements
            ).hostReserve
            guard lease.evidence.hostReservedLogicalCPUCount == reserve.logicalCPUCount,
                  lease.evidence.hostReservedMemoryBytes == reserve.memoryBytes,
                  lease.evidence.hostReservedStorageBytes == reserve.storageBytes else {
                throw DoryVirtualMachineResourceAdmissionLedgerError.invalidRecord
            }
            switch lease.state {
            case .starting:
                guard let expiry = lease.startingExpiresAtUnixMilliseconds,
                      expiry > lease.createdAtUnixMilliseconds else {
                    throw DoryVirtualMachineResourceAdmissionLedgerError.invalidRecord
                }
            case .running:
                guard lease.boundPlanSHA256 != nil,
                      lease.startingExpiresAtUnixMilliseconds == nil else {
                    throw DoryVirtualMachineResourceAdmissionLedgerError.invalidRecord
                }
            case .recoveryRequired:
                guard lease.boundPlanSHA256 != nil,
                      lease.startingExpiresAtUnixMilliseconds == nil else {
                    throw DoryVirtualMachineResourceAdmissionLedgerError.invalidRecord
                }
            case .stopped:
                guard lease.startingExpiresAtUnixMilliseconds == nil else {
                    throw DoryVirtualMachineResourceAdmissionLedgerError.invalidRecord
                }
            }
        }
        var activeBindings: Set<String> = []
        for lease in record.leases where lease.state != .stopped {
            for forward in lease.portForwards {
                guard activeBindings.insert(portBindingKey(forward)).inserted else {
                    throw DoryVirtualMachineResourceAdmissionLedgerError.invalidRecord
                }
            }
        }
    }

    private static func admissionReportSHA256(
        _ lease: DoryVirtualMachineResourceAdmissionLease
    ) -> String {
        digest(canonicalData(AdmissionReport(
            leaseID: lease.leaseID,
            binding: lease.binding,
            hostFactsSHA256: lease.hostFactsSHA256,
            workload: lease.workload,
            requirements: lease.requirements,
            resources: lease.resources,
            hostReserve: DoryVMHostReserve(
                logicalCPUCount: lease.evidence.hostReservedLogicalCPUCount,
                memoryBytes: lease.evidence.hostReservedMemoryBytes,
                storageBytes: lease.evidence.hostReservedStorageBytes
            ),
            existingVirtualCPUCommitment: lease.evidence.existingVirtualCPUCommitment,
            existingMemoryCommitmentBytes: lease.evidence.existingMemoryCommitmentBytes,
            existingStorageReservationBytes: lease.evidence.existingStorageReservationBytes,
            assessorIdentifier: assessorIdentifier,
            assessorVersion: assessorVersion
        )))
    }

    private static func makeEvidence(
        leaseID: String,
        binding: DoryVirtualMachineResourceAdmissionPlanBinding,
        hostFacts: DoryVMHostResources,
        assessedHost: DoryVMHostResources,
        workload: DoryVMWorkloadProfile,
        requirements: [DoryVMResourceRequirement],
        resources: DoryVMResourceRequest,
        reserve: DoryVMHostReserve
    ) -> DoryResolvedMachineResourceAdmissionEvidence {
        let report = AdmissionReport(
            leaseID: leaseID,
            binding: binding,
            hostFactsSHA256: DoryVirtualMachineResourceAdmissionLease.digest(hostFacts),
            workload: workload,
            requirements: requirements,
            resources: resources,
            hostReserve: reserve,
            existingVirtualCPUCommitment: assessedHost.admittedVirtualCPUCount,
            existingMemoryCommitmentBytes: assessedHost.admittedMemoryBytes,
            existingStorageReservationBytes: assessedHost.reservedStorageBytes,
            assessorIdentifier: assessorIdentifier,
            assessorVersion: assessorVersion
        )
        return DoryResolvedMachineResourceAdmissionEvidence(
            admittedVirtualCPUCount: resources.virtualCPUCount,
            admittedMemoryBytes: resources.memoryBytes,
            admittedStorageBytes: resources.diskBytes,
            hostLogicalCPUCount: assessedHost.logicalCPUCount,
            hostPhysicalMemoryBytes: assessedHost.physicalMemoryBytes,
            hostFreeStorageBytes: assessedHost.freeStorageBytes,
            existingVirtualCPUCommitment: assessedHost.admittedVirtualCPUCount,
            existingMemoryCommitmentBytes: assessedHost.admittedMemoryBytes,
            existingStorageReservationBytes: assessedHost.reservedStorageBytes,
            hostReservedLogicalCPUCount: reserve.logicalCPUCount,
            hostReservedMemoryBytes: reserve.memoryBytes,
            hostReservedStorageBytes: reserve.storageBytes,
            admissionIdentity: leaseID,
            admissionReportSHA256: digest(canonicalData(report)),
            assessorIdentifier: assessorIdentifier,
            assessorVersion: assessorVersion
        )
    }

    private static func commitments(
        in leases: [DoryVirtualMachineResourceAdmissionLease]
    ) throws -> Commitments {
        var cpu: UInt64 = 0
        var memory: UInt64 = 0
        var storage: UInt64 = 0
        for lease in leases {
            storage = try adding(storage, lease.resources.diskBytes)
            if lease.state == .starting || lease.state == .running
                || lease.state == .recoveryRequired {
                cpu = try adding(cpu, lease.resources.virtualCPUCount)
                memory = try adding(memory, lease.resources.memoryBytes)
            }
        }
        return Commitments(
            runtime: DoryVMResourceRequest(
                virtualCPUCount: cpu,
                memoryBytes: memory,
                diskBytes: 0
            ),
            storage: storage
        )
    }

    private static func composing(
        _ host: DoryVMHostResources,
        runtime: DoryVMResourceRequest,
        storage: UInt64
    ) throws -> DoryVMHostResources {
        DoryVMHostResources(
            logicalCPUCount: host.logicalCPUCount,
            physicalMemoryBytes: host.physicalMemoryBytes,
            freeStorageBytes: host.freeStorageBytes,
            admittedVirtualCPUCount: try adding(
                host.admittedVirtualCPUCount,
                runtime.virtualCPUCount
            ),
            admittedMemoryBytes: try adding(host.admittedMemoryBytes, runtime.memoryBytes),
            reservedStorageBytes: try adding(host.reservedStorageBytes, storage)
        )
    }

    private static func validateCapacity(
        _ leases: [DoryVirtualMachineResourceAdmissionLease],
        hostFacts: DoryVMHostResources
    ) throws {
        let total = try commitments(in: leases)
        let composed = try composing(hostFacts, runtime: total.runtime, storage: total.storage)
        let reserve = DoryVMResourcePolicy.recommend(
            host: hostFacts,
            workload: .server
        ).hostReserve
        guard sumFits(
                total: composed.logicalCPUCount,
                composed.admittedVirtualCPUCount,
                reserve.logicalCPUCount
              ),
              sumFits(
                total: composed.physicalMemoryBytes,
                composed.admittedMemoryBytes,
                reserve.memoryBytes
              ),
              sumFits(
                total: composed.freeStorageBytes,
                composed.reservedStorageBytes,
                reserve.storageBytes
              ) else {
            throw DoryVirtualMachineResourceAdmissionLedgerError.capacityUnavailable([])
        }
    }

    private static func sumFits(total: UInt64, _ values: UInt64...) -> Bool {
        var sum: UInt64 = 0
        for value in values {
            let (next, overflow) = sum.addingReportingOverflow(value)
            if overflow { return false }
            sum = next
        }
        return sum <= total
    }

    private static func requirementOrder(
        _ lhs: DoryVMResourceRequirement,
        _ rhs: DoryVMResourceRequirement
    ) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.identifier < rhs.identifier
    }

    private static func adding(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw DoryVirtualMachineResourceAdmissionLedgerError.arithmeticOverflow
        }
        return value
    }

    private static func incrementing(_ value: UInt64) throws -> UInt64 {
        try adding(value, 1)
    }

    private static func planSHA256(_ plan: DoryResolvedMachinePlan) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(plan)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalData<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data()
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...256).contains(bytes.count) && bytes.allSatisfy {
            isAlphaNumeric($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
    }

    private static func ensurePrivateDirectory(_ path: String) throws {
        if mkdir(path, mode_t(0o700)) != 0, errno != EEXIST {
            throw filesystem("create resource admission directory")
        }
        var status = stat()
        guard lstat(path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0 else {
            throw DoryVirtualMachineResourceAdmissionLedgerError.invalidRecord
        }
    }

    private static func syncDirectory(_ path: String) throws {
        let descriptor = path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw filesystem("open resource admission directory") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw filesystem("sync resource admission directory") }
    }

    private static func filesystem(_ operation: String)
        -> DoryVirtualMachineResourceAdmissionLedgerError
    {
        .filesystem("\(operation): errno \(errno)")
    }

    private func filesystem(_ operation: String)
        -> DoryVirtualMachineResourceAdmissionLedgerError
    {
        Self.filesystem(operation)
    }
}
