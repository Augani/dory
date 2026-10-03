import Darwin
import Foundation

/// Negative qualification cases, never runtime tuning or public capability admission.
public enum DoryRuntimeQualificationFaultKind: String, Codable, Sendable, CaseIterable, Hashable {
    case blockFullFlushNoSpace = "block-full-flush-enospc"
    case mappedPageRepeatedPermission = "mapped-page-repeated-permission"
    case rendererWorkerCrash = "renderer-worker-sigkill"
}

/// Exact scratch-page protocol shared by the guest probe and host. No caller supplies arbitrary
/// expected bytes: the whole 16 KiB host page must contain this challenge-derived pattern.
public enum DoryMappedPageQualificationChallenge {
    public static let pageBytes = 16_384
    public static func expectedPage(challenge: UUID) -> Data {
        var unit = Data(("dory-mapped-page-v1:" + challenge.uuidString.lowercased()).utf8)
        unit.append(Data(repeating: 10, count: 64 - unit.count))
        return (0..<(pageBytes / 64)).reduce(into: Data()) { bytes, _ in bytes.append(unit) }
    }
}

/// Optional signed cell policy. Existing authorities omit this field and grant no faults.
public struct DoryCandidateCampaignFaultPolicy: Codable, Sendable, Equatable, Hashable {
    public var permittedFaults: [DoryRuntimeQualificationFaultKind]
    public var maximumArmingCount: UInt16
    public var maximumArmedMilliseconds: UInt32

    public init(
        permittedFaults: [DoryRuntimeQualificationFaultKind],
        maximumArmingCount: UInt16 = 1,
        maximumArmedMilliseconds: UInt32 = 10_000
    ) {
        self.permittedFaults = permittedFaults.sorted { $0.rawValue < $1.rawValue }
        self.maximumArmingCount = maximumArmingCount
        self.maximumArmedMilliseconds = maximumArmedMilliseconds
    }

    public var isValid: Bool {
        !permittedFaults.isEmpty
            && Set(permittedFaults).count == permittedFaults.count
            && permittedFaults == permittedFaults.sorted { $0.rawValue < $1.rawValue }
            && (1...8).contains(maximumArmingCount)
            && (1...30_000).contains(maximumArmedMilliseconds)
    }

    /// PC fault admission covers only an accelerated renderer. ARM memory and block-device
    /// faults have backend-specific seams and must never transfer to a translated PC runtime.
    public var isRendererCrashOnly: Bool { isValid && permittedFaults == [.rendererWorkerCrash] }

    public func supportsRuntime(_ capability: DoryVirtualMachineCapabilityRequest) -> Bool {
        guard isValid, capability.backend == .doryHypervisor, capability.guest.family == .linux else { return false }
        switch capability.guest.architecture {
        case .arm64: return true
        case .x86_64: return isRendererCrashOnly && capability.graphics == .hardwareAccelerated3D
        }
    }
}

/// Opaque in-process grant from a freshly verified signed campaign authority. No public
/// initializer, decoder, process environment switch or ordinary VM setting can mint one.
/// Helper transfer is permitted only through the authenticated, one-shot daemon channel.
/// Reference ownership keeps the complete immutable grant off process-supervision worker stacks.
public final class DoryRuntimeQualificationFaultAuthority: Sendable, Equatable {
    public let machineID: String
    public let operationID: UUID
    public let resolvedPlanSHA256: String
    public let campaignManifestSHA256: String
    public let expiresAt: Date
    public let policy: DoryCandidateCampaignFaultPolicy

    init(
        machineID: String, operationID: UUID, resolvedPlanSHA256: String,
        campaignManifestSHA256: String, expiresAt: Date, policy: DoryCandidateCampaignFaultPolicy
    ) {
        self.machineID = machineID
        self.operationID = operationID
        self.resolvedPlanSHA256 = resolvedPlanSHA256
        self.campaignManifestSHA256 = campaignManifestSHA256
        self.expiresAt = expiresAt
        self.policy = policy
    }

    public static func == (lhs: DoryRuntimeQualificationFaultAuthority,
                           rhs: DoryRuntimeQualificationFaultAuthority) -> Bool {
        lhs.machineID == rhs.machineID && lhs.operationID == rhs.operationID
            && lhs.resolvedPlanSHA256 == rhs.resolvedPlanSHA256
            && lhs.campaignManifestSHA256 == rhs.campaignManifestSHA256
            && lhs.expiresAt == rhs.expiresAt && lhs.policy == rhs.policy
    }

    public func rendererCrashAdmission(challenge: UUID, workerGeneration: UInt64,
                                       now: Date = Date(),
                                       monotonicNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) throws -> DoryRendererCrashQualificationAdmission {
        guard policy.isValid, policy.permittedFaults.contains(.rendererWorkerCrash) else {
            throw DoryRuntimeQualificationFaultError.unauthorized
        }
        guard now < expiresAt else { throw DoryRuntimeQualificationFaultError.expired }
        guard workerGeneration > 0,
              challenge != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
            throw DoryRuntimeQualificationFaultError.invalidIdentity
        }
        // Pin the signed wall-clock expiry to a monotonic deadline before crossing XPC. A
        // subsequently adjusted wall clock must not extend the worker's delayed crash window.
        let duration = min(expiresAt.timeIntervalSince(now), Double(policy.maximumArmedMilliseconds) / 1_000) * 1_000_000_000
        guard duration.isFinite, duration >= 1 else { throw DoryRuntimeQualificationFaultError.expired }
        let (deadline, overflow) = monotonicNanoseconds.addingReportingOverflow(UInt64(duration.rounded(.down)))
        guard !overflow else { throw DoryRuntimeQualificationFaultError.invalidIdentity }
        return DoryRendererCrashQualificationAdmission(authority: self, challenge: challenge,
            workerGeneration: workerGeneration, dispatchDeadlineNanoseconds: deadline)
    }
}

/// Not Codable and not publicly constructible. Ordinary renderer commands cannot mint a crash
/// admission; its verified campaign grant remains bound to one operation and worker generation.
public struct DoryRendererCrashQualificationAdmission: Sendable, Equatable {
    public let authority: DoryRuntimeQualificationFaultAuthority
    public let challenge: UUID
    public let workerGeneration: UInt64
    public let dispatchDeadlineNanoseconds: UInt64
    private let dispatchGate = DispatchGate()

    private final class DispatchGate: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = true
        func claim() -> Bool { lock.withLock { guard pending else { return false }; pending = false; return true } }
        func cancel() { lock.withLock { pending = false } }
    }

    fileprivate init(authority: DoryRuntimeQualificationFaultAuthority, challenge: UUID,
                     workerGeneration: UInt64, dispatchDeadlineNanoseconds: UInt64) {
        self.authority = authority
        self.challenge = challenge
        self.workerGeneration = workerGeneration
        self.dispatchDeadlineNanoseconds = dispatchDeadlineNanoseconds
    }

    public func permits(workspaceID: UUID, workerGeneration: UInt64, now: Date = Date()) -> Bool {
        authority.operationID == workspaceID && self.workerGeneration == workerGeneration
            && authority.expiresAt > now && authority.policy.permittedFaults.contains(.rendererWorkerCrash)
    }

    /// Cancellation and dispatch linearize at this one-shot boundary. Copies share the gate.
    public func claimDispatchPermission(now: Date = Date(),
                                        monotonicNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Bool {
        guard now < authority.expiresAt, monotonicNanoseconds < dispatchDeadlineNanoseconds else { return false }
        return dispatchGate.claim()
    }
    public func cancelDispatch() { dispatchGate.cancel() }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.dispatchGate === rhs.dispatchGate }
}

/// Runtime control intent, not authority. Every field must match the inherited grant.
public struct DoryRuntimeQualificationFaultRequest: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable { case arm, observe, cancel }
    public let action: Action
    public let machineID: String
    public let operationID: UUID
    public let resolvedPlanSHA256: String
    public let campaignManifestSHA256: String
    public let challenge: UUID
    public let kind: DoryRuntimeQualificationFaultKind?
    public let guestPhysicalAddress: UInt64?
    public let rendererWorkerGeneration: UInt64?

    public init(action: Action, machineID: String, operationID: UUID,
                resolvedPlanSHA256: String, campaignManifestSHA256: String,
                challenge: UUID, kind: DoryRuntimeQualificationFaultKind? = nil,
                guestPhysicalAddress: UInt64? = nil, rendererWorkerGeneration: UInt64? = nil) {
        self.action = action
        self.machineID = machineID
        self.operationID = operationID
        self.resolvedPlanSHA256 = resolvedPlanSHA256
        self.campaignManifestSHA256 = campaignManifestSHA256
        self.challenge = challenge
        self.kind = kind
        self.guestPhysicalAddress = guestPhysicalAddress
        self.rendererWorkerGeneration = rendererWorkerGeneration
    }

    public func matches(_ authority: DoryRuntimeQualificationFaultAuthority) -> Bool {
        machineID == authority.machineID && operationID == authority.operationID
            && resolvedPlanSHA256 == authority.resolvedPlanSHA256
            && campaignManifestSHA256 == authority.campaignManifestSHA256
            && challenge != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            && ((action == .arm && kind != nil) || (action != .arm && kind == nil))
            && (action == .arm && kind == .mappedPageRepeatedPermission
                ? guestPhysicalAddress.map { $0 > 0 && $0.isMultiple(of: UInt64(DoryMappedPageQualificationChallenge.pageBytes)) } == true
                : guestPhysicalAddress == nil)
            && (action == .arm && kind == .rendererWorkerCrash
                ? rendererWorkerGeneration.map { $0 > 0 } == true : rendererWorkerGeneration == nil)
    }
}

/// `guestCompleted` records IOERR publication to the current queue's used ring; mapped-page
/// `retryEscalated` requires successful exception injection and permission restoration.
/// These runtime observations are not desktop qualification verdicts.
public struct DoryRuntimeQualificationFaultObservation: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case armed, consumed, guestCompleted, cancelled, expired, faulting, retryEscalated, restoreFailed
        case crashRequested, crashRejected, workerLost
    }
    public let challenge: UUID
    public let kind: DoryRuntimeQualificationFaultKind
    public let machineID: String
    public let operationID: UUID
    public let resolvedPlanSHA256: String
    public let campaignManifestSHA256: String
    public var state: State
    public var injectedErrno: Int32?
    public var guestStatus: UInt8?
    public var queueIndex: Int?
    public var queueGeneration: UInt64?
    public var guestPhysicalAddress: UInt64?
    public var virtualCPUIndex: Int?
    public var instructionAddress: UInt64?
    public var faultExitCount: UInt16?
    public var retryCount: UInt16?
    public var guestException: String?
    public var memoryProtectionRestored: Bool?
    public var rendererWorkerGeneration: UInt64?
    public var rendererCrashRequestNanoseconds: UInt64?
    public var rendererCrashAcknowledgedNanoseconds: UInt64?
    public var rendererWorkerInterruptedNanoseconds: UInt64?
    public var rendererInFlightCommandCount: UInt32?

    public init(challenge: UUID, kind: DoryRuntimeQualificationFaultKind, machineID: String,
                operationID: UUID, resolvedPlanSHA256: String, campaignManifestSHA256: String,
                state: State) {
        self.challenge = challenge
        self.kind = kind
        self.machineID = machineID
        self.operationID = operationID
        self.resolvedPlanSHA256 = resolvedPlanSHA256
        self.campaignManifestSHA256 = campaignManifestSHA256
        self.state = state
    }

    public func matches(_ request: DoryRuntimeQualificationFaultRequest) -> Bool {
        challenge == request.challenge && machineID == request.machineID && operationID == request.operationID
            && resolvedPlanSHA256 == request.resolvedPlanSHA256
            && campaignManifestSHA256 == request.campaignManifestSHA256
            && (request.kind == nil || kind == request.kind)
            && (request.guestPhysicalAddress == nil || guestPhysicalAddress == request.guestPhysicalAddress)
            && (request.rendererWorkerGeneration == nil || rendererWorkerGeneration == request.rendererWorkerGeneration)
    }

    public var isValidRuntimeObservation: Bool {
        if kind == .rendererWorkerCrash {
            guard injectedErrno == nil, guestStatus == nil, queueIndex == nil, queueGeneration == nil,
                  guestPhysicalAddress == nil, virtualCPUIndex == nil, instructionAddress == nil,
                  faultExitCount == nil, retryCount == nil, guestException == nil, memoryProtectionRestored == nil,
                  rendererWorkerGeneration.map({ $0 > 0 }) == true,
                  let requested = rendererCrashRequestNanoseconds, requested > 0 else { return false }
            let acknowledgementValid = (rendererCrashAcknowledgedNanoseconds == nil && rendererInFlightCommandCount == nil)
                || (rendererCrashAcknowledgedNanoseconds.map { $0 >= requested } == true
                    && rendererInFlightCommandCount.map { $0 <= UInt32(UInt16.max) } == true)
            guard acknowledgementValid,
                  rendererWorkerInterruptedNanoseconds.map({ $0 >= requested }) ?? true else { return false }
            switch state {
            case .crashRequested:
                return rendererCrashAcknowledgedNanoseconds == nil || rendererWorkerInterruptedNanoseconds == nil
            case .workerLost:
                return rendererCrashAcknowledgedNanoseconds != nil && rendererWorkerInterruptedNanoseconds != nil
            case .crashRejected:
                return rendererCrashAcknowledgedNanoseconds == nil && rendererInFlightCommandCount == nil
            case .cancelled, .expired: return true
            case .armed, .consumed, .guestCompleted, .faulting, .retryEscalated, .restoreFailed: return false
            }
        }
        guard rendererWorkerGeneration == nil, rendererCrashRequestNanoseconds == nil,
              rendererCrashAcknowledgedNanoseconds == nil, rendererWorkerInterruptedNanoseconds == nil,
              rendererInFlightCommandCount == nil else { return false }
        if kind == .mappedPageRepeatedPermission {
            guard injectedErrno == nil, guestStatus == nil, queueIndex == nil, queueGeneration == nil,
                  let page = guestPhysicalAddress, page > 0,
                  page.isMultiple(of: UInt64(DoryMappedPageQualificationChallenge.pageBytes)),
                  let faults = faultExitCount, let retries = retryCount,
                  let restored = memoryProtectionRestored else { return false }
            let episodeValid = faults == 0
                ? virtualCPUIndex == nil && instructionAddress == nil && retries == 0
                : virtualCPUIndex.map { (0..<8).contains($0) } == true && instructionAddress != nil
                    && faults <= 17 && retries == min(faults, 16)
            guard episodeValid else { return false }
            let exceptionValid = guestException == nil || (faults == 17 && retries == 16
                && ["synchronous-external-data-abort", "serror"].contains(guestException ?? ""))
            guard exceptionValid else { return false }
            switch state {
            case .armed: return !restored && faults == 0 && guestException == nil
            case .faulting:
                return !restored && (1...17).contains(faults) && retries == min(faults, 16) && guestException == nil
            case .retryEscalated:
                return restored && faults == 17 && retries == 16
                    && ["synchronous-external-data-abort", "serror"].contains(guestException ?? "")
            // Rollback can succeed after a failed post-injection restoration. Preserve the
            // injected-exception fact without promoting the cancelled case to a passing run.
            case .cancelled, .expired: return restored
            case .restoreFailed: return !restored
            case .consumed, .guestCompleted, .crashRequested, .crashRejected, .workerLost: return false
            }
        }
        guard guestPhysicalAddress == nil, virtualCPUIndex == nil, instructionAddress == nil,
              faultExitCount == nil, retryCount == nil, guestException == nil,
              memoryProtectionRestored == nil else { return false }
        switch state {
        case .armed, .cancelled, .expired:
            return injectedErrno == nil && guestStatus == nil && queueIndex == nil && queueGeneration == nil
        case .consumed, .guestCompleted:
            return injectedErrno == ENOSPC && queueIndex.map { (0..<16).contains($0) } == true
                && queueGeneration != nil && guestStatus == (state == .guestCompleted ? 1 : nil)
        case .faulting, .retryEscalated, .restoreFailed, .crashRequested, .crashRejected, .workerLost: return false
        }
    }
}

public enum DoryRuntimeQualificationFaultError: Error, Sendable, Equatable {
    case unauthorized
    case invalidIdentity
    case expired
    case alreadyArmed
    case armingBudgetExhausted
    case reusedChallenge
    case unknownChallenge
}
