import Darwin
import DoryGuestMemoryShim
import DoryRendererWorkerContracts
import Foundation
import Metal

public enum DoryRendererWorkerBrokerState: Equatable, Sendable {
    case active
    case interrupted
    case invalidated
    case protocolViolation
    case outcomeUnknown
}

/// Closed, non-sensitive location at which a command's foreign-renderer outcome became unknown.
/// These values are safe to surface in runner diagnostics: they contain no renderer-provided text,
/// host path, artifact identity, or guest-controlled payload bytes.
public enum DoryRendererWorkerCommandDiagnosticStage: Equatable, Sendable {
    case workerServiceReply
    case brokerCommandDeadline
}

/// Closed terminal result paired with ``DoryRendererWorkerCommandDiagnosticStage``.
public enum DoryRendererWorkerCommandDiagnosticStatus: Equatable, Sendable {
    case backendOutcomeUnknown
    case deadlineExpired
}

/// Minimal audit record for an uncertain command. Operation and request identity come from the
/// command admitted by this broker; elapsed time comes from the local monotonic clock. Deliberately
/// do not add arbitrary worker/foreign-library strings to this boundary.
public struct DoryRendererWorkerCommandDiagnostic: Equatable, Sendable {
    public let operation: DoryRendererWorkerOperation
    public let requestID: UInt64
    public let stage: DoryRendererWorkerCommandDiagnosticStage
    public let status: DoryRendererWorkerCommandDiagnosticStatus
    public let elapsedNanoseconds: UInt64

    public init(
        operation: DoryRendererWorkerOperation,
        requestID: UInt64,
        stage: DoryRendererWorkerCommandDiagnosticStage,
        status: DoryRendererWorkerCommandDiagnosticStatus,
        elapsedNanoseconds: UInt64
    ) {
        self.operation = operation
        self.requestID = requestID
        self.stage = stage
        self.status = status
        self.elapsedNanoseconds = elapsedNanoseconds
    }
}

public enum DoryRendererWorkerBrokerError: Error, Equatable, Sendable {
    case invalidBootstrap(DoryRendererWorkerContractError)
    case invalidCommand(DoryRendererWorkerContractError)
    case incompleteCapabilityReceipt
    case notActive(DoryRendererWorkerBrokerState)
    case requestIDExhausted
    case inFlightLimit(limit: Int)
    case aggregateReferencedBytesLimit(limit: UInt64, requested: UInt64)
    case deadlineExpired
    case deadlineTooDistant(limitNanoseconds: UInt64, actualNanoseconds: UInt64)
    case inputDescriptorCountMismatch(expected: Int, actual: Int)
    case invalidInputDescriptor(index: Int)
    case workerRejected(DoryRendererWorkerRPCFailureCode)
    case channelFailure(DoryRendererWorkerChannelFailure)
    case channelFailureDuring(
        requestID: UInt64,
        operation: DoryRendererWorkerOperation,
        failure: DoryRendererWorkerChannelFailure
    )
    case malformedReply(DoryRendererWorkerContractError)
    case replyIdentityMismatch
    case invalidReplyDescriptor(index: Int)
    case workerOutcomeUnknown(DoryRendererWorkerCommandDiagnostic)
}

public struct DoryRendererWorkerFenceReceipt: @unchecked Sendable {
    public let workerGeneration: DoryRendererWorkerGeneration
    public let contextID: UInt32
    public let flags: UInt32
    public let ringIndex: UInt32
    public let fenceID: UInt64
    public let completionDescriptor: FileHandle
}

public struct DoryRendererWorkerBlobMapping: @unchecked Sendable {
    public let lease: DoryRendererBlobMappingLease
    public let sharedMemoryDescriptor: FileHandle
}

public struct DoryRendererWorkerScanout: @unchecked Sendable {
    public let lease: DoryRendererScanoutLease
    public let sharedMemoryDescriptor: FileHandle
}

public struct DoryRendererWorkerSharedTextureScanout: @unchecked Sendable {
    public let lease: DoryRendererSharedTextureScanoutLease
    public let sharedTextureHandle: MTLSharedTextureHandle
}

public enum DoryRendererWorkerCommandResult: @unchecked Sendable {
    case acknowledged
    case resourceCreated(generation: UInt64)
    case blobMapping(DoryRendererWorkerBlobMapping)
    case fence(DoryRendererWorkerFenceReceipt)
    case scanout(DoryRendererWorkerScanout)
    case sharedTextureScanout(DoryRendererWorkerSharedTextureScanout)
    case reset(successorGeneration: UInt64)
}

public struct DoryRendererWorkerBrokerSnapshot: Equatable, Sendable {
    public let state: DoryRendererWorkerBrokerState
    public let generation: DoryRendererWorkerGeneration
    public let inFlightCommands: Int
    public let maximumObservedInFlightCommands: Int
    public let aggregateReferencedBytes: UInt64
    public let submittedBatches: UInt64
    public let controlBytes: UInt64
    public let descriptorBackedCommandBytes: UInt64
    public let rejectedAdmissions: UInt64
    public let protocolViolations: UInt64
    public let lateReplies: UInt64
    /// Accelerated presentation has no byte-copy API. This remains zero by construction.
    public let scanoutCopyBytes: UInt64
}

private final class DoryRendererWorkerBrokerTerminalRelay: @unchecked Sendable {
    typealias Handler = @Sendable (
        DoryRendererWorkerBrokerState,
        DoryRendererWorkerBrokerError
    ) -> Void

    private let lock = NSLock()
    private var terminal: (DoryRendererWorkerBrokerState, DoryRendererWorkerBrokerError)?
    private var handlers = [Handler]()

    func install(_ handler: @escaping Handler) {
        let immediate = lock.withLock { () -> (
            DoryRendererWorkerBrokerState,
            DoryRendererWorkerBrokerError
        )? in
            if let terminal { return terminal }
            handlers.append(handler)
            return nil
        }
        if let immediate { handler(immediate.0, immediate.1) }
    }

    func publish(
        state: DoryRendererWorkerBrokerState,
        error: DoryRendererWorkerBrokerError
    ) {
        let delivery = lock.withLock { () -> [Handler] in
            guard terminal == nil else { return [] }
            terminal = (state, error)
            let delivery = handlers
            handlers.removeAll(keepingCapacity: false)
            return delivery
        }
        for handler in delivery { handler(state, error) }
    }
}

private final class DoryRendererWorkerBootstrapReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func claim() -> Bool {
        lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
    }
}

/// VMM-side owner of one authenticated renderer-worker generation.
///
/// Admission is asynchronous and bounded; the vCPU never performs a synchronous XPC round trip or
/// waits for GPU completion. `submit3D` bytes exist only in descriptor-backed regions. A command
/// deadline, malformed reply, helper interruption, or uncertain foreign outcome revokes the whole
/// generation because the broker cannot prove what renderer state the worker reached.
public actor DoryRendererWorkerBroker {
    public static let maximumAdmissionDeadlineNanoseconds: UInt64 = 30_000_000_000
    public static let productionBootstrapTimeoutNanoseconds: UInt64 = 10_000_000_000

    private struct PendingCommand {
        let command: DoryRendererWorkerCommand
        let admittedUptimeNanoseconds: UInt64
        let inputDescriptors: [FileHandle]
        let referencedBytes: UInt64
        let continuation: CheckedContinuation<DoryRendererWorkerCommandResult, any Error>
        var timeoutTask: Task<Void, Never>?
    }

    /// Immutable bootstrap/receipt authority is safe to inspect without an actor hop. Mutable
    /// command admission and channel lifecycle remain actor-isolated.
    public nonisolated let bootstrap: DoryRendererWorkerBootstrap
    public nonisolated let capabilityReceipt: DoryRendererCapabilityReceipt

    private let channel: any DoryRendererWorkerChannel
    private nonisolated let terminalRelay = DoryRendererWorkerBrokerTerminalRelay()
    private var state: DoryRendererWorkerBrokerState = .active
    private var nextRequestID: UInt64 = 1
    private var pendingByRequestID = [UInt64: PendingCommand]()
    private var aggregateReferencedBytes: UInt64 = 0
    private var maximumObservedInFlightCommands = 0
    private var submittedBatches: UInt64 = 0
    private var controlBytes: UInt64 = 0
    private var descriptorBackedCommandBytes: UInt64 = 0
    private var rejectedAdmissions: UInt64 = 0
    private var protocolViolations: UInt64 = 0
    private var lateReplies: UInt64 = 0

    public init(
        bootstrap: DoryRendererWorkerBootstrap,
        capabilityReceipt: DoryRendererCapabilityReceipt,
        channel: any DoryRendererWorkerChannel
    ) throws {
        guard capabilityReceipt.productionAccelerationIsAdmissible,
              capabilityReceipt.workspaceID == bootstrap.workspaceID,
              capabilityReceipt.generation == bootstrap.generation,
              capabilityReceipt.sourceTuple == bootstrap.sourceTuple,
              capabilityReceipt.producerFenceContract == bootstrap.producerFenceContract,
              capabilityReceipt.candidateInventory == bootstrap.artifacts.candidateInventory,
              capabilityReceipt.rendererWorkerExecutable
                == bootstrap.artifacts.rendererWorkerExecutable else {
            channel.invalidate()
            throw DoryRendererWorkerBrokerError.incompleteCapabilityReceipt
        }
        self.bootstrap = bootstrap
        self.capabilityReceipt = capabilityReceipt
        self.channel = channel
        channel.installLifecycleHandler { [weak self] event in
            guard let self else { return }
            Task { await self.receiveChannelEvent(event) }
        }
    }

    /// Performs one one-shot bootstrap and returns a broker only for a complete production receipt.
    /// The exact bytes originate in the operation-bound launch authority; this method never derives
    /// artifact identity from paths or environment variables.
    public static func connect(
        exactBootstrapBytes: Data,
        timeoutNanoseconds: UInt64 = productionBootstrapTimeoutNanoseconds
    ) async throws -> Self {
        let bootstrap: DoryRendererWorkerBootstrap
        do {
            bootstrap = try DoryRendererWorkerBootstrapCodec.decode(exactBootstrapBytes)
        } catch let error as DoryRendererWorkerContractError {
            throw DoryRendererWorkerBrokerError.invalidBootstrap(error)
        }
        // Decode before endpoint activation so the exact signed worker slice in this generation
        // becomes the audit-token requirement. The stable service identifier is discovery only.
        let channel = DoryRendererWorkerXPCChannel(
            codeDirectoryHash: bootstrap.artifacts.rendererWorkerCodeDirectoryHash
        )
        let receiptBytes: Data
        do {
            receiptBytes = try await performBootstrap(
                channel: channel,
                exactBytes: exactBootstrapBytes,
                timeoutNanoseconds: timeoutNanoseconds
            )
        } catch let failure as DoryRendererWorkerChannelFailure {
            channel.invalidate()
            throw DoryRendererWorkerBrokerError.channelFailure(failure)
        }
        let receipt: DoryRendererCapabilityReceipt
        do {
            receipt = try DoryRendererCapabilityReceiptCodec.decode(
                receiptBytes,
                accepting: bootstrap
            )
        } catch let error as DoryRendererWorkerContractError {
            channel.invalidate()
            throw DoryRendererWorkerBrokerError.invalidBootstrap(error)
        }
        return try Self(
            bootstrap: bootstrap,
            capabilityReceipt: receipt,
            channel: channel
        )
    }

    static func performBootstrap(
        channel: any DoryRendererWorkerChannel,
        exactBytes: Data,
        timeoutNanoseconds: UInt64
    ) async throws -> Data {
        guard timeoutNanoseconds > 0 else {
            channel.invalidate()
            throw DoryRendererWorkerBrokerError.deadlineExpired
        }
        guard timeoutNanoseconds <= maximumAdmissionDeadlineNanoseconds else {
            channel.invalidate()
            throw DoryRendererWorkerBrokerError.deadlineTooDistant(
                limitNanoseconds: maximumAdmissionDeadlineNanoseconds,
                actualNanoseconds: timeoutNanoseconds
            )
        }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = DoryRendererWorkerBootstrapReplyGate()
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                // Cancellation is also a terminal startup result. A completed reply has already
                // claimed the gate, so its cancellation wakes this task harmlessly; inherited
                // caller cancellation must not leave the checked continuation suspended forever.
                guard gate.claim() else { return }
                channel.invalidate()
                continuation.resume(
                    throwing: DoryRendererWorkerBrokerError.deadlineExpired
                )
            }
            channel.bootstrap(exactBytes: exactBytes) { result in
                guard gate.claim() else { return }
                timeoutTask.cancel()
                continuation.resume(with: result)
            }
        }
    }

    /// Sends one typed operation. Shared region descriptors are duplicated at admission and kept
    /// alive through the XPC reply, so caller-side close/reuse cannot change an admitted command.
    public func execute(
        operation: DoryRendererWorkerOperation,
        contextID: UInt32 = 0,
        resourceID: UInt32 = 0,
        resourceGeneration: UInt64 = 0,
        sharedRegions: [DoryRendererSharedRegionReference] = [],
        descriptors: [FileHandle] = [],
        payload: Data = Data(),
        deadlineUptimeNanoseconds: UInt64
    ) async throws -> DoryRendererWorkerCommandResult {
        guard state == .active else { throw reject(.notActive(state)) }
        guard pendingByRequestID.count < bootstrap.limits.maximumInFlightCommands else {
            throw reject(.inFlightLimit(limit: bootstrap.limits.maximumInFlightCommands))
        }
        guard nextRequestID != 0 else { throw reject(.requestIDExhausted) }
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadlineUptimeNanoseconds > now else { throw reject(.deadlineExpired) }
        let remaining = deadlineUptimeNanoseconds - now
        guard remaining <= Self.maximumAdmissionDeadlineNanoseconds else {
            throw reject(.deadlineTooDistant(
                limitNanoseconds: Self.maximumAdmissionDeadlineNanoseconds,
                actualNanoseconds: remaining
            ))
        }
        let requiredDescriptorCount = sharedRegions.isEmpty
            ? 0
            : Int(sharedRegions.map(\.descriptorIndex).max()!) + 1
        guard descriptors.count == requiredDescriptorCount else {
            throw reject(.inputDescriptorCountMismatch(
                expected: requiredDescriptorCount,
                actual: descriptors.count
            ))
        }
        let referencedBytes = try Self.sumReferencedBytes(sharedRegions)
        let (newAggregate, aggregateOverflow) = aggregateReferencedBytes
            .addingReportingOverflow(referencedBytes)
        guard !aggregateOverflow,
              newAggregate <= bootstrap.limits.maximumReferencedBytes else {
            throw reject(.aggregateReferencedBytesLimit(
                limit: bootstrap.limits.maximumReferencedBytes,
                requested: aggregateOverflow ? UInt64.max : newAggregate
            ))
        }

        let requestID = nextRequestID
        let command: DoryRendererWorkerCommand
        do {
            command = try DoryRendererWorkerCommand(
                generation: bootstrap.generation,
                requestID: requestID,
                operation: operation,
                contextID: contextID,
                resourceID: resourceID,
                resourceGeneration: resourceGeneration,
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
                sharedRegions: sharedRegions,
                payload: payload,
                limits: bootstrap.limits
            )
        } catch let error as DoryRendererWorkerContractError {
            throw reject(.invalidCommand(error))
        }
        let ownedDescriptors: [FileHandle]
        do {
            ownedDescriptors = try Self.duplicateAndValidate(
                descriptors,
                references: command.sharedRegions
            )
        } catch let error as DoryRendererWorkerBrokerError {
            throw reject(error)
        }
        let frame: Data
        do {
            frame = try DoryRendererWorkerCommandCodec.encode(
                command,
                limits: bootstrap.limits
            )
        } catch let error as DoryRendererWorkerContractError {
            Self.close(ownedDescriptors)
            throw reject(.invalidCommand(error))
        }

        nextRequestID = requestID == UInt64.max ? 0 : requestID + 1
        aggregateReferencedBytes = newAggregate
        submittedBatches = Self.saturatingAdd(submittedBatches, 1)
        controlBytes = Self.saturatingAdd(controlBytes, UInt64(frame.count))
        if operation == .submit3D {
            descriptorBackedCommandBytes = Self.saturatingAdd(
                descriptorBackedCommandBytes,
                referencedBytes
            )
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingByRequestID[requestID] = PendingCommand(
                command: command,
                admittedUptimeNanoseconds: now,
                inputDescriptors: ownedDescriptors,
                referencedBytes: referencedBytes,
                continuation: continuation,
                timeoutTask: nil
            )
            maximumObservedInFlightCommands = max(
                maximumObservedInFlightCommands,
                pendingByRequestID.count
            )
            channel.exchange(frame: frame, descriptors: ownedDescriptors) { [weak self] result in
                guard let self else {
                    if case .success(let reply) = result { Self.close(reply.descriptors) }
                    return
                }
                Task { await self.receiveReply(result, requestID: requestID) }
            }
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: remaining)
                guard let self else { return }
                await self.expire(requestID: requestID)
            }
            pendingByRequestID[requestID]?.timeoutTask = timeoutTask
        }
    }

    public func invalidate() {
        transitionToTerminal(.invalidated, error: .notActive(.invalidated))
        channel.invalidate()
    }

    /// Installs a one-shot terminal-generation observer without an actor hop. This is required by
    /// fence owners: helper death must revoke already-armed descriptors even when no command is
    /// currently awaiting an XPC reply. Installation after failure delivers the stored terminal
    /// state immediately, so a worker restart cannot miss the edge.
    public nonisolated func installTerminalHandler(
        _ handler: @escaping @Sendable (
            DoryRendererWorkerBrokerState,
            DoryRendererWorkerBrokerError
        ) -> Void
    ) {
        terminalRelay.install(handler)
    }

    public func snapshot() -> DoryRendererWorkerBrokerSnapshot {
        DoryRendererWorkerBrokerSnapshot(
            state: state,
            generation: bootstrap.generation,
            inFlightCommands: pendingByRequestID.count,
            maximumObservedInFlightCommands: maximumObservedInFlightCommands,
            aggregateReferencedBytes: aggregateReferencedBytes,
            submittedBatches: submittedBatches,
            controlBytes: controlBytes,
            descriptorBackedCommandBytes: descriptorBackedCommandBytes,
            rejectedAdmissions: rejectedAdmissions,
            protocolViolations: protocolViolations,
            lateReplies: lateReplies,
            scanoutCopyBytes: 0
        )
    }

    private func receiveReply(
        _ result: Result<DoryRendererWorkerChannelReply, DoryRendererWorkerChannelFailure>,
        requestID: UInt64
    ) {
        guard let pending = pendingByRequestID[requestID] else {
            lateReplies = Self.saturatingAdd(lateReplies, 1)
            if case .success(let reply) = result { Self.close(reply.descriptors) }
            return
        }
        guard DispatchTime.now().uptimeNanoseconds < pending.command.deadlineUptimeNanoseconds else {
            if case .success(let reply) = result { Self.close(reply.descriptors) }
            expire(requestID: requestID)
            return
        }
        switch result {
        case .failure(.serviceFailure(let code)) where Self.isProvenRejection(code):
            let removed = removePending(requestID)
            removed?.continuation.resume(throwing: DoryRendererWorkerBrokerError.workerRejected(code))
        case .failure(.serviceFailure(.outcomeUnknown)):
            transitionToTerminal(
                .outcomeUnknown,
                error: .workerOutcomeUnknown(commandDiagnostic(
                    for: pending,
                    stage: .workerServiceReply,
                    status: .backendOutcomeUnknown
                ))
            )
            channel.invalidate()
        case .failure(let failure):
            let terminal: DoryRendererWorkerBrokerState = switch failure {
            case .interrupted: .interrupted
            case .invalidated: .invalidated
            case .malformedResult, .descriptorCountMismatch: .protocolViolation
            case .unavailable, .serviceFailure: .outcomeUnknown
            }
            if terminal == .protocolViolation {
                protocolViolations = Self.saturatingAdd(protocolViolations, 1)
            }
            transitionToTerminal(
                terminal,
                error: .channelFailureDuring(
                    requestID: requestID,
                    operation: pending.command.operation,
                    failure: failure
                )
            )
            channel.invalidate()
        case .success(let reply):
            do {
                let decoded = try decodeReply(reply, accepting: pending.command)
                let removed = removePending(requestID)
                removed?.continuation.resume(returning: decoded)
            } catch let error as DoryRendererWorkerBrokerError {
                Self.close(reply.descriptors)
                protocolViolations = Self.saturatingAdd(protocolViolations, 1)
                transitionToTerminal(.protocolViolation, error: error)
                channel.invalidate()
            } catch {
                Self.close(reply.descriptors)
                protocolViolations = Self.saturatingAdd(protocolViolations, 1)
                transitionToTerminal(.protocolViolation, error: .replyIdentityMismatch)
                channel.invalidate()
            }
        }
    }

    private func decodeReply(
        _ reply: DoryRendererWorkerChannelReply,
        accepting command: DoryRendererWorkerCommand
    ) throws -> DoryRendererWorkerCommandResult {
        guard command.operation == .acquireScanoutLease
                || reply.sharedTextureHandle == nil else {
            throw replyMismatch()
        }
        switch command.operation {
        case .createResource3D, .createBlob:
            try Self.requireDescriptorCount(reply.descriptors, expected: 0)
            guard reply.payload.count == 8 else { throw replyMismatch() }
            let generation = Self.decodeUInt64(reply.payload)
            guard generation != 0 else { throw replyMismatch() }
            return .resourceCreated(generation: generation)

        case .mapBlob:
            let lease: DoryRendererBlobMappingLease
            do {
                lease = try DoryRendererBlobMappingLeaseCodec.decode(
                    reply.payload,
                    limits: bootstrap.limits
                )
            } catch let error as DoryRendererWorkerContractError {
                throw DoryRendererWorkerBrokerError.malformedReply(error)
            }
            try lease.validateOutOfBandDescriptorCount(reply.descriptors.count)
            guard lease.workerGeneration == bootstrap.generation,
                  lease.resourceID == command.resourceID,
                  lease.resourceGeneration == command.resourceGeneration else {
                throw replyMismatch()
            }
            try Self.validateReturnedSharedMemory(
                reply.descriptors[0],
                declaredFileSize: lease.declaredFileSize,
                minimumByteCount: lease.mappingByteCount,
                index: 0
            )
            return .blobMapping(DoryRendererWorkerBlobMapping(
                lease: lease,
                sharedMemoryDescriptor: reply.descriptors[0]
            ))

        case .createFence:
            try Self.requireDescriptorCount(reply.descriptors, expected: 1)
            let expected: DoryRendererFencePayload
            let received: DoryRendererFencePayload
            do {
                expected = try DoryRendererFencePayload.decode(command.payload)
                received = try DoryRendererFencePayload.decode(reply.payload)
            } catch let error as DoryRendererWorkerContractError {
                throw DoryRendererWorkerBrokerError.malformedReply(error)
            }
            guard received == expected else { throw replyMismatch() }
            try Self.validateReturnedFence(reply.descriptors[0], index: 0)
            return .fence(DoryRendererWorkerFenceReceipt(
                workerGeneration: bootstrap.generation,
                contextID: command.contextID,
                flags: received.flags,
                ringIndex: received.ringIndex,
                fenceID: received.fenceID,
                completionDescriptor: reply.descriptors[0]
            ))

        case .acquireScanoutLease:
            if let sharedTextureHandle = reply.sharedTextureHandle {
                try Self.requireDescriptorCount(reply.descriptors, expected: 0)
                let lease: DoryRendererSharedTextureScanoutLease
                do {
                    lease = try DoryRendererSharedTextureScanoutLeaseCodec.decode(
                        reply.payload,
                        limits: bootstrap.limits
                    )
                } catch let error as DoryRendererWorkerContractError {
                    throw DoryRendererWorkerBrokerError.malformedReply(error)
                }
                guard lease.workerGeneration == bootstrap.generation,
                      lease.resourceID == command.resourceID,
                      lease.resourceGeneration == command.resourceGeneration else {
                    throw replyMismatch()
                }
                return .sharedTextureScanout(DoryRendererWorkerSharedTextureScanout(
                    lease: lease,
                    sharedTextureHandle: sharedTextureHandle
                ))
            }
            let lease: DoryRendererScanoutLease
            do {
                lease = try DoryRendererScanoutLeaseCodec.decode(
                    reply.payload,
                    limits: bootstrap.limits
                )
            } catch let error as DoryRendererWorkerContractError {
                throw DoryRendererWorkerBrokerError.malformedReply(error)
            }
            try lease.validateOutOfBandDescriptorCount(reply.descriptors.count)
            guard lease.workerGeneration == bootstrap.generation,
                  lease.resourceID == command.resourceID,
                  lease.resourceGeneration == command.resourceGeneration else {
                throw replyMismatch()
            }
            try Self.validateReturnedSharedMemory(
                reply.descriptors[0],
                declaredFileSize: lease.declaredFileSize,
                minimumByteCount: lease.storageOffset + lease.leaseByteCount,
                index: 0
            )
            return .scanout(DoryRendererWorkerScanout(
                lease: lease,
                sharedMemoryDescriptor: reply.descriptors[0]
            ))

        case .resetAfterDeviceQuiesce:
            try Self.requireDescriptorCount(reply.descriptors, expected: 0)
            let expected: DoryRendererResetPayload
            let received: DoryRendererResetPayload
            do {
                expected = try DoryRendererResetPayload.decode(command.payload)
                received = try DoryRendererResetPayload.decode(reply.payload)
            } catch let error as DoryRendererWorkerContractError {
                throw DoryRendererWorkerBrokerError.malformedReply(error)
            }
            guard expected == received else { throw replyMismatch() }
            return .reset(successorGeneration: received.successorGeneration)

        case .createContext, .destroyContext, .attachResource, .detachResource,
             .submit3D, .attachBacking, .detachBacking, .unrefResource, .unmapBlob,
             .transferToHost3D, .transferFromHost3D, .releaseScanoutLease:
            try Self.requireDescriptorCount(reply.descriptors, expected: 0)
            guard reply.payload.isEmpty else { throw replyMismatch() }
            return .acknowledged
        }
    }

    private func expire(requestID: UInt64) {
        guard let pending = pendingByRequestID[requestID] else { return }
        transitionToTerminal(
            .outcomeUnknown,
            error: .workerOutcomeUnknown(commandDiagnostic(
                for: pending,
                stage: .brokerCommandDeadline,
                status: .deadlineExpired
            ))
        )
        channel.invalidate()
    }

    private func commandDiagnostic(
        for pending: PendingCommand,
        stage: DoryRendererWorkerCommandDiagnosticStage,
        status: DoryRendererWorkerCommandDiagnosticStatus
    ) -> DoryRendererWorkerCommandDiagnostic {
        let now = DispatchTime.now().uptimeNanoseconds
        return DoryRendererWorkerCommandDiagnostic(
            operation: pending.command.operation,
            requestID: pending.command.requestID,
            stage: stage,
            status: status,
            elapsedNanoseconds: now >= pending.admittedUptimeNanoseconds
                ? now - pending.admittedUptimeNanoseconds
                : 0
        )
    }

    private func receiveChannelEvent(_ event: DoryRendererWorkerChannelEvent) {
        let (terminal, failure): (
            DoryRendererWorkerBrokerState,
            DoryRendererWorkerChannelFailure
        ) = switch event {
        case .interrupted: (.interrupted, .interrupted)
        case .invalidated: (.invalidated, .invalidated)
        }
        let error: DoryRendererWorkerBrokerError
        if let requestID = pendingByRequestID.keys.min(),
           let pending = pendingByRequestID[requestID] {
            error = .channelFailureDuring(
                requestID: requestID,
                operation: pending.command.operation,
                failure: failure
            )
        } else {
            error = .notActive(terminal)
        }
        transitionToTerminal(terminal, error: error)
    }

    private func transitionToTerminal(
        _ requestedState: DoryRendererWorkerBrokerState,
        error: DoryRendererWorkerBrokerError
    ) {
        guard state == .active else { return }
        state = requestedState
        terminalRelay.publish(state: requestedState, error: error)
        let pending = pendingByRequestID
        pendingByRequestID.removeAll(keepingCapacity: false)
        aggregateReferencedBytes = 0
        for command in pending.values {
            command.timeoutTask?.cancel()
            Self.close(command.inputDescriptors)
            command.continuation.resume(throwing: error)
        }
    }

    private func removePending(_ requestID: UInt64) -> PendingCommand? {
        guard let pending = pendingByRequestID.removeValue(forKey: requestID) else { return nil }
        pending.timeoutTask?.cancel()
        Self.close(pending.inputDescriptors)
        aggregateReferencedBytes = aggregateReferencedBytes >= pending.referencedBytes
            ? aggregateReferencedBytes - pending.referencedBytes
            : 0
        return pending
    }

    private func reject(
        _ error: DoryRendererWorkerBrokerError
    ) -> DoryRendererWorkerBrokerError {
        rejectedAdmissions = Self.saturatingAdd(rejectedAdmissions, 1)
        return error
    }

    private func replyMismatch() -> DoryRendererWorkerBrokerError {
        .replyIdentityMismatch
    }

    private static func isProvenRejection(_ code: DoryRendererWorkerRPCFailureCode) -> Bool {
        switch code {
        case .deadlineExpired, .resourceExhausted, .commandRejected:
            true
        case .invalidEnvelope, .bootstrapRejected, .bootstrapAlreadyAttempted,
             .bootstrapRequired, .capabilityUnavailable, .staleGeneration, .outcomeUnknown,
             .protocolViolation, .internalFailure, .bootstrapArtifactAuthorityFailed,
             .bootstrapRendererInitializationFailed, .bootstrapVenusCapabilityFailed,
             .bootstrapVenusContextFailed, .bootstrapSharedMemoryExportFailed,
             .bootstrapFenceExportFailed, .bootstrapCapabilityReceiptFailed,
             .bootstrapVirgl2CapabilityFailed, .bootstrapVirgl2ContextFailed:
            false
        }
    }

    private static func sumReferencedBytes(
        _ regions: [DoryRendererSharedRegionReference]
    ) throws -> UInt64 {
        var total: UInt64 = 0
        for region in regions {
            let (next, overflow) = total.addingReportingOverflow(region.length)
            guard !overflow else {
                throw DoryRendererWorkerBrokerError.aggregateReferencedBytesLimit(
                    limit: UInt64.max,
                    requested: UInt64.max
                )
            }
            total = next
        }
        return total
    }

    private static func duplicateAndValidate(
        _ descriptors: [FileHandle],
        references: [DoryRendererSharedRegionReference]
    ) throws -> [FileHandle] {
        var owned = [FileHandle]()
        owned.reserveCapacity(descriptors.count)
        var identities = Set<DescriptorIdentity>()
        do {
            let metadata = Dictionary(grouping: references, by: \.descriptorIndex)
            for (index, descriptor) in descriptors.enumerated() {
                guard let descriptorReferences = metadata[UInt16(index)],
                      let reference = descriptorReferences.first,
                      descriptorReferences.allSatisfy({
                          $0.declaredFileSize == reference.declaredFileSize
                      }) else {
                    throw DoryRendererWorkerBrokerError.invalidInputDescriptor(index: index)
                }
                let source = descriptor.fileDescriptor
                var status = stat()
                guard source >= 0,
                      fstat(source, &status) == 0,
                      status.st_nlink == 0,
                      status.st_size >= 0,
                      UInt64(status.st_size) == reference.declaredFileSize else {
                    throw DoryRendererWorkerBrokerError.invalidInputDescriptor(index: index)
                }
                let descriptorIdentity: DescriptorIdentity
                switch status.st_mode & S_IFMT {
                case S_IFREG:
                    descriptorIdentity = .filesystem(
                        device: UInt64(status.st_dev),
                        inode: UInt64(status.st_ino)
                    )
                case 0:
                    guard descriptorReferences.allSatisfy({
                        $0.offset >= DoryGuestMemoryBackingDataOffset()
                    }) else {
                        throw DoryRendererWorkerBrokerError.invalidInputDescriptor(index: index)
                    }
                    var identity = DoryGuestMemoryBackingIdentity()
                    guard DoryReadGuestMemoryBackingIdentity(
                        source,
                        reference.declaredFileSize,
                        &identity
                    ) == 1 else {
                        throw DoryRendererWorkerBrokerError.invalidInputDescriptor(index: index)
                    }
                    descriptorIdentity = .guestMemory(
                        withUnsafeBytes(of: &identity) { Data($0) }
                    )
                default:
                    throw DoryRendererWorkerBrokerError.invalidInputDescriptor(index: index)
                }
                let accessMode = fcntl(source, F_GETFL) & O_ACCMODE
                guard (reference.access == .readOnly && accessMode == O_RDONLY)
                        || (reference.access == .readWrite && accessMode == O_RDWR) else {
                    throw DoryRendererWorkerBrokerError.invalidInputDescriptor(index: index)
                }
                guard identities.insert(descriptorIdentity).inserted else {
                    throw DoryRendererWorkerBrokerError.invalidInputDescriptor(index: index)
                }
                let duplicate = fcntl(source, F_DUPFD_CLOEXEC, 0)
                guard duplicate >= 0 else {
                    throw DoryRendererWorkerBrokerError.invalidInputDescriptor(index: index)
                }
                owned.append(FileHandle(fileDescriptor: duplicate, closeOnDealloc: true))
            }
            return owned
        } catch {
            close(owned)
            throw error
        }
    }

    private enum DescriptorIdentity: Hashable {
        case filesystem(device: UInt64, inode: UInt64)
        case guestMemory(Data)
    }

    private static func requireDescriptorCount(
        _ descriptors: [FileHandle],
        expected: Int
    ) throws {
        guard descriptors.count == expected else {
            throw DoryRendererWorkerBrokerError.replyIdentityMismatch
        }
    }

    private static func validateReturnedSharedMemory(
        _ descriptor: FileHandle,
        declaredFileSize: UInt64,
        minimumByteCount: UInt64,
        index: Int
    ) throws {
        let fd = descriptor.fileDescriptor
        var status = stat()
        guard fd >= 0,
              fstat(fd, &status) == 0,
              DoryRendererSharedMemoryDescriptorPolicy.accepts(mode: status.st_mode),
              status.st_nlink == 0,
              status.st_size >= 0,
              UInt64(status.st_size) == declaredFileSize,
              minimumByteCount <= declaredFileSize,
              fcntl(fd, F_GETFL) & O_ACCMODE == O_RDWR else {
            throw DoryRendererWorkerBrokerError.invalidReplyDescriptor(index: index)
        }
        try setCloseOnExec(fd, index: index)
    }

    private static func validateReturnedFence(_ descriptor: FileHandle, index: Int) throws {
        let fd = descriptor.fileDescriptor
        var status = stat()
        guard fd >= 0,
              fstat(fd, &status) == 0,
              (status.st_mode & S_IFMT) != S_IFDIR else {
            throw DoryRendererWorkerBrokerError.invalidReplyDescriptor(index: index)
        }
        try setCloseOnExec(fd, index: index)
    }

    private static func requireDistinctDescriptors(
        _ first: FileHandle,
        _ second: FileHandle
    ) throws {
        var firstStatus = stat()
        var secondStatus = stat()
        guard fstat(first.fileDescriptor, &firstStatus) == 0,
              fstat(second.fileDescriptor, &secondStatus) == 0,
              firstStatus.st_dev != secondStatus.st_dev
                || firstStatus.st_ino != secondStatus.st_ino else {
            throw DoryRendererWorkerBrokerError.replyIdentityMismatch
        }
    }

    private static func setCloseOnExec(_ fd: Int32, index: Int) throws {
        let flags = fcntl(fd, F_GETFD)
        guard flags >= 0, fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            throw DoryRendererWorkerBrokerError.invalidReplyDescriptor(index: index)
        }
    }

    private static func decodeUInt64(_ data: Data) -> UInt64 {
        data.withUnsafeBytes { bytes in
            UInt64(littleEndian: bytes.loadUnaligned(as: UInt64.self))
        }
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }

    private static func close(_ descriptors: [FileHandle]) {
        for descriptor in descriptors { try? descriptor.close() }
    }
}
