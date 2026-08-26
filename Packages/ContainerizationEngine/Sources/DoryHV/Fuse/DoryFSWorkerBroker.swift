import DoryFSWorkerContracts
import Foundation

/// Events supplied by a future XPC adapter's `interruptionHandler` and `invalidationHandler`.
/// Either event is fail-stop for one broker generation; reconnection requires a new broker and a
/// newly bootstrapped worker authority rather than silently reusing lost handle identity.
public enum DoryFSWorkerChannelEvent: Equatable, Sendable {
    case interrupted
    case invalidated
}

public enum DoryFSWorkerChannelFailure: Error, Equatable, Sendable {
    case unavailable
    case interrupted
    case invalidated
    case serviceFailure(DoryFSWorkerRPCFailureCode)
}

/// Transport-neutral boundary implemented by a future signed NSXPC/App Sandbox adapter. Each call
/// carries one exact bounded frame. This protocol does not launch a process and an implementation
/// backed by an ordinary child process is not a security boundary.
public protocol DoryFSWorkerChannel: AnyObject, Sendable {
    func installLifecycleHandler(
        _ handler: @escaping @Sendable (DoryFSWorkerChannelEvent) -> Void
    )
    func send(
        frame: Data,
        completion: @escaping @Sendable (Result<Data, DoryFSWorkerChannelFailure>) -> Void
    )
    func sendOneWay(frame: Data)
    func invalidate()
}

public enum DoryFSWorkerBrokerState: Equatable, Sendable {
    case active
    case draining
    case drained
    case interrupted
    case invalidated
    case protocolViolation
}

public enum DoryFSWorkerBrokerError: Error, Equatable, Sendable {
    case notActive(DoryFSWorkerBrokerState)
    case requestTooLarge(limit: Int, actual: Int)
    case responseCapacityTooLarge(limit: Int, actual: Int)
    case operationDeadlineExpired
    case operationDeadlineTooDistant(limitNanoseconds: UInt64, actualNanoseconds: UInt64)
    case drainDeadlineExpired
    case drainDeadlineTooDistant(limitNanoseconds: UInt64, actualNanoseconds: UInt64)
    case inFlightLimit(limit: Int)
    case aggregateRequestLimit(limit: Int, requested: Int)
    case aggregateResponseLimit(limit: Int, requested: Int)
    case invalidAdmissionAuthority
    case duplicateCorrelationID(UInt64)
    case invalidCorrelationID
    case requestIDExhausted
    case unknownCorrelationID(UInt64)
    case requestDeadlineExpired(correlationID: UInt64)
    case channelFailure(DoryFSWorkerChannelFailure)
    case channelInterrupted
    case channelInvalidated
    case workerRejected(DoryFSWorkerRejectionCode)
    case malformedReply(DoryFSWorkerContractError)
    case replyIdentityMismatch
    case responseTooLarge(limit: Int, actual: Int)
    case drainReplyMismatch
    case connectionTeardownWithInFlight(
        inFlightRequests: Int,
        pendingPublications: Int
    )
}

public struct DoryFSWorkerBrokerSnapshot: Equatable, Sendable {
    public let state: DoryFSWorkerBrokerState
    public let generation: DoryFSWorkerGeneration
    public let inFlightRequests: Int
    public let pendingPublications: Int
    public let aggregateRequestBytes: Int
    public let aggregateResponseReservations: Int
    public let rejectedAdmissions: UInt64
    public let completedRequests: UInt64
    public let lateReplies: UInt64
    public let protocolViolations: UInt64
    public let sentInterrupts: UInt64
}

/// Host-owned response plus the exact acknowledgement token that retains worker-side grants.
/// The frontend must commit only after the used-ring publication succeeds, or discard on every
/// pre-publication failure. Dropping this value without either acknowledgement fail-stops the
/// broker at the original operation deadline.
public struct DoryFSWorkerExecution: Equatable, Sendable {
    public let response: Data
    public let publication: DoryFSWorkerPublication
    public let acknowledgementDeadlineUptimeNanoseconds: UInt64

    public init(
        response: Data,
        publication: DoryFSWorkerPublication,
        acknowledgementDeadlineUptimeNanoseconds: UInt64
    ) {
        self.response = response
        self.publication = publication
        self.acknowledgementDeadlineUptimeNanoseconds =
            acknowledgementDeadlineUptimeNanoseconds
    }
}

/// VMM-side authority for one immutable share capability and one worker generation.
///
/// The actor owns every in-flight reservation and validates a complete reply before returning it to
/// the frontend. A deadline does not reclaim capacity and continue using an unresponsive worker:
/// it invalidates the whole channel, because the abandoned worker may still hold descriptors or be
/// completing a mutation. The future supervisor must then terminate that signed worker process.
public actor DoryFSWorkerBroker {
    /// Minimal identity retained after the exact request frame has been sent. Keeping the complete
    /// `DoryFSWorkerRequest` here also retained its payload beside the encoded XPC frame until
    /// publication acknowledgement, doubling large-request residency for no authority benefit.
    private struct RequestIdentity {
        let requestID: UInt64
        let correlationID: UInt64
        let deadlineUptimeNanoseconds: UInt64
    }

    private struct PendingRequest {
        let identity: RequestIdentity
        let admissionLease: DoryFSWorkerAdmissionLease
        let continuation: CheckedContinuation<DoryFSWorkerExecution, any Error>
        var timeoutTask: Task<Void, Never>?
    }

    private struct PendingPublication {
        let identity: RequestIdentity
        let admissionLease: DoryFSWorkerAdmissionLease
        var timeoutTask: Task<Void, Never>?
    }

    private struct PendingDrain {
        let deadlineUptimeNanoseconds: UInt64
        let continuation: CheckedContinuation<Void, any Error>
        var requestSent: Bool
        var timeoutTask: Task<Void, Never>?
    }

    public nonisolated let limits: DoryFSWorkerLimits
    public nonisolated let shareResourceLimits: DoryFSShareResourceLimits
    public nonisolated let effectiveAdmissionLimits: DoryFSWorkerEffectiveAdmissionLimits
    public nonisolated let shareCapabilityID: DoryFSShareCapabilityID
    public nonisolated let generation: DoryFSWorkerGeneration

    private let channel: any DoryFSWorkerChannel
    private nonisolated let admissionAuthority: DoryFSWorkerWorkspaceAdmissionAuthority
    private var state: DoryFSWorkerBrokerState = .active
    private var nextRequestID: UInt64 = 1
    private var pendingByRequestID = [UInt64: PendingRequest]()
    private var pendingPublicationsByRequestID = [UInt64: PendingPublication]()
    private var requestIDByCorrelationID = [UInt64: UInt64]()
    private var pendingDrain: PendingDrain?
    private var rejectedAdmissions: UInt64 = 0
    private var completedRequests: UInt64 = 0
    private var lateReplies: UInt64 = 0
    private var protocolViolations: UInt64 = 0
    private var sentInterrupts: UInt64 = 0

    public init(
        shareCapabilityID: DoryFSShareCapabilityID,
        generation: DoryFSWorkerGeneration,
        limits: DoryFSWorkerLimits = .production,
        shareResourceLimits: DoryFSShareResourceLimits = .production,
        channel: any DoryFSWorkerChannel
    ) {
        let authority = DoryFSWorkerWorkspaceAdmissionAuthority(
            workerLimits: limits,
            shareLimits: [shareCapabilityID: shareResourceLimits]
        )
        self.shareCapabilityID = shareCapabilityID
        self.generation = generation
        self.limits = limits
        self.shareResourceLimits = shareResourceLimits
        self.effectiveAdmissionLimits = authority.effectiveLimits(for: shareCapabilityID)!
        self.admissionAuthority = authority
        self.channel = channel
        channel.installLifecycleHandler { [weak self] event in
            guard let self else { return }
            Task { await self.receiveChannelEvent(event) }
        }
    }

    init(
        shareCapabilityID: DoryFSShareCapabilityID,
        generation: DoryFSWorkerGeneration,
        limits: DoryFSWorkerLimits,
        shareResourceLimits: DoryFSShareResourceLimits,
        admissionAuthority: DoryFSWorkerWorkspaceAdmissionAuthority,
        channel: any DoryFSWorkerChannel
    ) {
        guard let effective = admissionAuthority.effectiveLimits(for: shareCapabilityID),
              admissionAuthority.resourceLimits(for: shareCapabilityID) == shareResourceLimits else {
            preconditionFailure("filesystem broker share is absent from admission authority")
        }
        self.shareCapabilityID = shareCapabilityID
        self.generation = generation
        self.limits = limits
        self.shareResourceLimits = shareResourceLimits
        self.effectiveAdmissionLimits = effective
        self.admissionAuthority = admissionAuthority
        self.channel = channel
        channel.installLifecycleHandler { [weak self] event in
            guard let self else { return }
            Task { await self.receiveChannelEvent(event) }
        }
    }

    nonisolated func requestFrontendAdmission(
        shape: DoryFSWorkerAdmissionShape,
        waiterID: DoryFSWorkerAdmissionWaiterID,
        onResolved: @escaping @Sendable (DoryFSWorkerFrontendAdmissionResolution) -> Void
    ) -> DoryFSWorkerFrontendAdmissionResult {
        admissionAuthority.request(
            shareCapabilityID: shareCapabilityID,
            shape: shape,
            waiterID: waiterID,
            onResolved: onResolved
        )
    }

    nonisolated func cancelFrontendAdmission(
        waiterID: DoryFSWorkerAdmissionWaiterID
    ) {
        admissionAuthority.cancel(waiterID: waiterID)
    }

    nonisolated var workspaceAdmissionSnapshot: DoryFSWorkerWorkspaceAdmissionSnapshot {
        admissionAuthority.snapshot()
    }

    /// Admits one immutable request frame. `correlationID` is the guest-visible FUSE unique value;
    /// the broker allocates a separate never-reused request ID so a late callback cannot alias a
    /// later FUSE request that happens to reuse its unique value.
    public func execute(
        correlationID: UInt64,
        opcodeClass: DoryFSWorkerOpcodeClass,
        request: Data,
        responseCapacity: Int,
        deadlineUptimeNanoseconds: UInt64
    ) async throws -> DoryFSWorkerExecution {
        try await executeAdmitted(
            correlationID: correlationID,
            opcodeClass: opcodeClass,
            request: request,
            responseCapacity: responseCapacity,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
            suppliedAdmissionLease: nil
        )
    }

    func execute(
        correlationID: UInt64,
        opcodeClass: DoryFSWorkerOpcodeClass,
        request: Data,
        responseCapacity: Int,
        deadlineUptimeNanoseconds: UInt64,
        admissionLease: DoryFSWorkerAdmissionLease
    ) async throws -> DoryFSWorkerExecution {
        try await executeAdmitted(
            correlationID: correlationID,
            opcodeClass: opcodeClass,
            request: request,
            responseCapacity: responseCapacity,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
            suppliedAdmissionLease: admissionLease
        )
    }

    private func executeAdmitted(
        correlationID: UInt64,
        opcodeClass: DoryFSWorkerOpcodeClass,
        request: Data,
        responseCapacity: Int,
        deadlineUptimeNanoseconds: UInt64,
        suppliedAdmissionLease: DoryFSWorkerAdmissionLease?
    ) async throws -> DoryFSWorkerExecution {
        // Preserve the broker's exact terminal cause. A terminal transition invalidates the
        // workspace authority as part of the same actor turn, so consulting that authority first
        // would collapse `.interrupted`, `.drained`, and protocol-failure states into the less
        // useful `invalidAdmissionAuthority` error.
        guard state == .active else {
            suppliedAdmissionLease?.release()
            throw reject(.notActive(state))
        }
        let shape = DoryFSWorkerAdmissionShape(
            requestBytes: request.count,
            responseBytes: responseCapacity
        )
        let admissionLease: DoryFSWorkerAdmissionLease
        if let suppliedAdmissionLease {
            admissionLease = suppliedAdmissionLease
        } else {
            switch admissionAuthority.acquireImmediately(
                shareCapabilityID: shareCapabilityID,
                shape: shape
            ) {
            case .success(let lease):
                admissionLease = lease
            case .failure(let error):
                throw reject(error)
            }
        }
        guard admissionAuthority.validates(
            admissionLease,
            shareCapabilityID: shareCapabilityID,
            shape: shape
        ) else {
            admissionLease.release()
            throw reject(.invalidAdmissionAuthority)
        }
        guard correlationID != 0 else {
            admissionLease.release()
            throw reject(.invalidCorrelationID)
        }
        guard request.count <= limits.maximumRequestBytes else {
            admissionLease.release()
            throw reject(.requestTooLarge(limit: limits.maximumRequestBytes, actual: request.count))
        }
        guard responseCapacity >= 0,
              responseCapacity <= limits.maximumResponseBytes,
              let responseCapacity32 = UInt32(exactly: responseCapacity) else {
            admissionLease.release()
            throw reject(.responseCapacityTooLarge(
                limit: limits.maximumResponseBytes,
                actual: responseCapacity
            ))
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let remaining: UInt64
        do {
            remaining = try validateOperationDeadline(deadlineUptimeNanoseconds, now: now)
        } catch {
            admissionLease.release()
            throw error
        }
        guard requestIDByCorrelationID[correlationID] == nil else {
            admissionLease.release()
            throw reject(.duplicateCorrelationID(correlationID))
        }
        guard nextRequestID != 0 else {
            admissionLease.release()
            throw reject(.requestIDExhausted)
        }

        let requestID = nextRequestID
        nextRequestID = requestID == UInt64.max ? 0 : requestID + 1
        let frame: Data
        do {
            let envelope = try DoryFSWorkerRequest(
                generation: generation,
                shareCapabilityID: shareCapabilityID,
                requestID: requestID,
                correlationID: correlationID,
                opcodeClass: opcodeClass,
                responseCapacity: responseCapacity32,
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
                payload: request
            )
            frame = try DoryFSWorkerFrameCodec.encode(
                .execute(envelope),
                maximumFrameBytes: limits.maximumFrameBytes
            )
        } catch {
            admissionLease.release()
            throw error
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingByRequestID[requestID] = PendingRequest(
                identity: RequestIdentity(
                    requestID: requestID,
                    correlationID: correlationID,
                    deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
                ),
                admissionLease: admissionLease,
                continuation: continuation,
                timeoutTask: nil
            )
            requestIDByCorrelationID[correlationID] = requestID

            channel.send(frame: frame) { [weak self] result in
                guard let self else { return }
                Task { await self.receiveReply(result, expectedRequestID: requestID) }
            }
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: remaining)
                guard let self else { return }
                await self.expireRequest(requestID)
            }
            pendingByRequestID[requestID]?.timeoutTask = timeoutTask
        }
    }

    /// Sends a priority cancellation for the request with the given guest correlation ID. The
    /// reservation remains owned until the worker replies or the channel is invalidated.
    @discardableResult
    public func interrupt(
        correlationID: UInt64,
        deadlineUptimeNanoseconds: UInt64
    ) throws -> Bool {
        guard state == .active || state == .draining else {
            throw DoryFSWorkerBrokerError.notActive(state)
        }
        let now = DispatchTime.now().uptimeNanoseconds
        _ = try validateOperationDeadline(deadlineUptimeNanoseconds, now: now)
        guard let requestID = requestIDByCorrelationID[correlationID],
              let pending = pendingByRequestID[requestID] else {
            return false
        }
        let interrupt = try DoryFSWorkerInterrupt(
            generation: generation,
            shareCapabilityID: shareCapabilityID,
            targetRequestID: requestID,
            targetCorrelationID: pending.identity.correlationID,
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
        )
        let frame = try DoryFSWorkerFrameCodec.encode(
            .interrupt(interrupt),
            maximumFrameBytes: limits.maximumFrameBytes
        )
        sentInterrupts = saturatingAdd(sentInterrupts, 1)
        channel.sendOneWay(frame: frame)
        return true
    }

    /// Commits worker-side lookup/handle grants only after the exact virtqueue chain has been
    /// published into the used ring.
    public func commitPublication(_ publication: DoryFSWorkerPublication) throws {
        try acknowledgePublication(publication, committed: true)
    }

    /// Rolls back worker-side grants when the host response never became guest-visible.
    public func discardPublication(_ publication: DoryFSWorkerPublication) throws {
        try acknowledgePublication(publication, committed: false)
    }

    /// Stops new admission, waits for all admitted work, then requires an authenticated drained
    /// acknowledgement for this exact share generation. Timeout is fail-stop.
    public func drain(deadlineUptimeNanoseconds: UInt64) async throws {
        guard state == .active else { throw DoryFSWorkerBrokerError.notActive(state) }
        let now = DispatchTime.now().uptimeNanoseconds
        let remaining = try validateDrainDeadline(deadlineUptimeNanoseconds, now: now)
        state = .draining
        try await withCheckedThrowingContinuation { continuation in
            pendingDrain = PendingDrain(
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
                continuation: continuation,
                requestSent: false,
                timeoutTask: nil
            )
            sendDrainIfReady()
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: remaining)
                guard let self else { return }
                await self.expireDrain()
            }
            pendingDrain?.timeoutTask = timeoutTask
        }
    }

    /// Invalidates this generation and its channel. The broker is deliberately not restartable;
    /// the supervisor must create a new worker, capability bootstrap, and broker generation.
    public func invalidate() {
        guard state != .invalidated else { return }
        sendInvalidationFrame()
        transitionToTerminal(.invalidated, error: .channelInvalidated)
        channel.invalidate()
    }

    /// Retires one share after its exact FUSE_DESTROY response was published and committed. The
    /// workspace channel is deliberately retained because sibling shares use the same signed XPC
    /// worker and may still be completing their own teardown. Any residual request/publication is
    /// an ordering violation and remains fail-stop for the complete channel.
    func completeConnectionTeardown() throws {
        guard state == .active else { throw DoryFSWorkerBrokerError.notActive(state) }
        guard pendingByRequestID.isEmpty, pendingPublicationsByRequestID.isEmpty else {
            let error = DoryFSWorkerBrokerError.connectionTeardownWithInFlight(
                inFlightRequests: pendingByRequestID.count,
                pendingPublications: pendingPublicationsByRequestID.count
            )
            sendInvalidationFrame()
            transitionToTerminal(.invalidated, error: error)
            channel.invalidate()
            throw error
        }
        state = .drained
    }

    public func snapshot() -> DoryFSWorkerBrokerSnapshot {
        let admission = admissionAuthority.snapshot(for: shareCapabilityID)
        return DoryFSWorkerBrokerSnapshot(
            state: state,
            generation: generation,
            inFlightRequests: admission.inFlightRequests,
            pendingPublications: pendingPublicationsByRequestID.count,
            aggregateRequestBytes: admission.aggregateRequestBytes,
            aggregateResponseReservations: admission.aggregateResponseBytes,
            rejectedAdmissions: rejectedAdmissions,
            completedRequests: completedRequests,
            lateReplies: lateReplies,
            protocolViolations: protocolViolations,
            sentInterrupts: sentInterrupts
        )
    }

    private func receiveReply(
        _ result: Result<Data, DoryFSWorkerChannelFailure>,
        expectedRequestID: UInt64
    ) {
        guard let pending = pendingByRequestID[expectedRequestID] else {
            lateReplies = saturatingAdd(lateReplies, 1)
            return
        }
        guard DispatchTime.now().uptimeNanoseconds
                < pending.identity.deadlineUptimeNanoseconds else {
            expireRequest(expectedRequestID)
            return
        }
        switch result {
        case .failure(.interrupted):
            transitionToTerminal(.interrupted, error: .channelInterrupted)
            channel.invalidate()
        case .failure(.invalidated):
            transitionToTerminal(.invalidated, error: .channelInvalidated)
        case .failure(let failure):
            let current = removePendingRequest(expectedRequestID)
            current?.continuation.resume(
                throwing: DoryFSWorkerBrokerError.channelFailure(failure)
            )
            transitionToTerminal(.invalidated, error: .channelInvalidated)
            channel.invalidate()
        case .success(let bytes):
            let serviceFrame: DoryFSWorkerServiceFrame
            do {
                serviceFrame = try DoryFSWorkerFrameCodec.decodeServiceFrame(
                    bytes,
                    maximumFrameBytes: limits.maximumFrameBytes
                )
            } catch let error as DoryFSWorkerContractError {
                failProtocolViolation(currentRequestID: expectedRequestID, error: .malformedReply(error))
                return
            } catch {
                failProtocolViolation(
                    currentRequestID: expectedRequestID,
                    error: .replyIdentityMismatch
                )
                return
            }
            guard case .reply(let reply) = serviceFrame,
                  reply.generation == generation,
                  reply.shareCapabilityID == shareCapabilityID,
                  reply.requestID == expectedRequestID,
                  reply.correlationID == pending.identity.correlationID else {
                failProtocolViolation(
                    currentRequestID: expectedRequestID,
                    error: .replyIdentityMismatch
                )
                return
            }
            switch reply.outcome {
            case .rejected(let rejection):
                finishRejectedRequest(
                    expectedRequestID,
                    error: .workerRejected(rejection)
                )
            case .completed(let response):
                let responseLimit = min(
                    pending.admissionLease.shape.responseBytes,
                    limits.maximumResponseBytes
                )
                guard response.count <= responseLimit else {
                    failProtocolViolation(
                        currentRequestID: expectedRequestID,
                        error: .responseTooLarge(limit: responseLimit, actual: response.count)
                    )
                    return
                }
                finishCompletedRequest(
                    expectedRequestID,
                    response: response
                )
            }
        }
    }

    private func finishRejectedRequest(
        _ requestID: UInt64,
        error: DoryFSWorkerBrokerError
    ) {
        guard let pending = removePendingRequest(requestID) else { return }
        pending.continuation.resume(throwing: error)
        sendDrainIfReady()
    }

    private func finishCompletedRequest(
        _ requestID: UInt64,
        response: Data
    ) {
        guard let pending = pendingByRequestID.removeValue(forKey: requestID) else { return }
        pending.timeoutTask?.cancel()
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < pending.identity.deadlineUptimeNanoseconds else {
            releaseReservation(
                identity: pending.identity,
                admissionLease: pending.admissionLease
            )
            pending.continuation.resume(
                throwing: DoryFSWorkerBrokerError.requestDeadlineExpired(
                    correlationID: pending.identity.correlationID
                )
            )
            sendInvalidationFrame()
            transitionToTerminal(.invalidated, error: .channelInvalidated)
            channel.invalidate()
            return
        }
        let publication: DoryFSWorkerPublication
        do {
            publication = try DoryFSWorkerPublication(
                generation: generation,
                shareCapabilityID: shareCapabilityID,
                requestID: pending.identity.requestID,
                correlationID: pending.identity.correlationID
            )
        } catch {
            releaseReservation(
                identity: pending.identity,
                admissionLease: pending.admissionLease
            )
            pending.continuation.resume(
                throwing: DoryFSWorkerBrokerError.replyIdentityMismatch
            )
            failProtocolViolation(currentRequestID: nil, error: .replyIdentityMismatch)
            return
        }
        let remaining = pending.identity.deadlineUptimeNanoseconds - now
        pendingPublicationsByRequestID[requestID] = PendingPublication(
            identity: pending.identity,
            admissionLease: pending.admissionLease,
            timeoutTask: nil
        )
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: remaining)
            guard let self else { return }
            await self.expirePublication(requestID)
        }
        pendingPublicationsByRequestID[requestID]?.timeoutTask = timeoutTask
        completedRequests = saturatingAdd(completedRequests, 1)
        pending.continuation.resume(returning: DoryFSWorkerExecution(
            response: response,
            publication: publication,
            acknowledgementDeadlineUptimeNanoseconds:
                pending.identity.deadlineUptimeNanoseconds
        ))
    }

    private func removePendingRequest(_ requestID: UInt64) -> PendingRequest? {
        guard let pending = pendingByRequestID.removeValue(forKey: requestID) else { return nil }
        pending.timeoutTask?.cancel()
        releaseReservation(
            identity: pending.identity,
            admissionLease: pending.admissionLease
        )
        return pending
    }

    private func releaseReservation(
        identity: RequestIdentity,
        admissionLease: DoryFSWorkerAdmissionLease
    ) {
        requestIDByCorrelationID.removeValue(forKey: identity.correlationID)
        admissionLease.release()
    }

    private func expireRequest(_ requestID: UInt64) {
        guard let pending = pendingByRequestID[requestID] else { return }
        if let interrupt = try? DoryFSWorkerInterrupt(
            generation: generation,
            shareCapabilityID: shareCapabilityID,
            targetRequestID: requestID,
            targetCorrelationID: pending.identity.correlationID,
            deadlineUptimeNanoseconds: pending.identity.deadlineUptimeNanoseconds
        ), let frame = try? DoryFSWorkerFrameCodec.encode(
            .interrupt(interrupt),
            maximumFrameBytes: limits.maximumFrameBytes
        ) {
            sentInterrupts = saturatingAdd(sentInterrupts, 1)
            channel.sendOneWay(frame: frame)
        }
        let expired = removePendingRequest(requestID)
        expired?.continuation.resume(throwing: DoryFSWorkerBrokerError.requestDeadlineExpired(
            correlationID: pending.identity.correlationID
        ))
        sendInvalidationFrame()
        transitionToTerminal(.invalidated, error: .channelInvalidated)
        channel.invalidate()
    }

    private func acknowledgePublication(
        _ publication: DoryFSWorkerPublication,
        committed: Bool
    ) throws {
        guard state == .active || state == .draining else {
            throw DoryFSWorkerBrokerError.notActive(state)
        }
        guard publication.generation == generation,
              publication.shareCapabilityID == shareCapabilityID,
              let pending = pendingPublicationsByRequestID[publication.requestID],
              pending.identity.correlationID == publication.correlationID else {
            throw DoryFSWorkerBrokerError.replyIdentityMismatch
        }
        guard DispatchTime.now().uptimeNanoseconds
                < pending.identity.deadlineUptimeNanoseconds else {
            expirePublication(publication.requestID)
            throw DoryFSWorkerBrokerError.requestDeadlineExpired(
                correlationID: publication.correlationID
            )
        }
        let frame = try DoryFSWorkerFrameCodec.encode(
            committed
                ? .commitPublication(publication)
                : .discardPublication(publication),
            maximumFrameBytes: limits.maximumFrameBytes
        )
        guard let removed = pendingPublicationsByRequestID.removeValue(
            forKey: publication.requestID
        ) else {
            throw DoryFSWorkerBrokerError.replyIdentityMismatch
        }
        removed.timeoutTask?.cancel()
        releaseReservation(
            identity: removed.identity,
            admissionLease: removed.admissionLease
        )
        channel.sendOneWay(frame: frame)
        sendDrainIfReady()
    }

    private func expirePublication(_ requestID: UInt64) {
        guard let pending = pendingPublicationsByRequestID.removeValue(
            forKey: requestID
        ) else { return }
        pending.timeoutTask?.cancel()
        releaseReservation(
            identity: pending.identity,
            admissionLease: pending.admissionLease
        )
        if let publication = try? DoryFSWorkerPublication(
            generation: generation,
            shareCapabilityID: shareCapabilityID,
            requestID: pending.identity.requestID,
            correlationID: pending.identity.correlationID
        ), let frame = try? DoryFSWorkerFrameCodec.encode(
            .discardPublication(publication),
            maximumFrameBytes: limits.maximumFrameBytes
        ) {
            channel.sendOneWay(frame: frame)
        }
        sendInvalidationFrame()
        transitionToTerminal(.invalidated, error: .channelInvalidated)
        channel.invalidate()
    }

    private func sendDrainIfReady() {
        guard state == .draining,
              pendingByRequestID.isEmpty,
              pendingPublicationsByRequestID.isEmpty,
              var drain = pendingDrain,
              !drain.requestSent else { return }
        drain.requestSent = true
        pendingDrain = drain
        do {
            let frame = try DoryFSWorkerFrameCodec.encode(
                .drain(try DoryFSWorkerDrain(
                    generation: generation,
                    shareCapabilityID: shareCapabilityID,
                    deadlineUptimeNanoseconds: drain.deadlineUptimeNanoseconds
                )),
                maximumFrameBytes: limits.maximumFrameBytes
            )
            channel.send(frame: frame) { [weak self] result in
                guard let self else { return }
                Task { await self.receiveDrainReply(result) }
            }
        } catch {
            failProtocolViolation(currentRequestID: nil, error: .drainReplyMismatch)
        }
    }

    private func receiveDrainReply(_ result: Result<Data, DoryFSWorkerChannelFailure>) {
        guard state == .draining, let drain = pendingDrain else {
            lateReplies = saturatingAdd(lateReplies, 1)
            return
        }
        guard DispatchTime.now().uptimeNanoseconds < drain.deadlineUptimeNanoseconds else {
            expireDrain()
            return
        }
        switch result {
        case .failure(.interrupted):
            transitionToTerminal(.interrupted, error: .channelInterrupted)
            channel.invalidate()
        case .failure(.invalidated):
            transitionToTerminal(.invalidated, error: .channelInvalidated)
        case .failure(let failure):
            pendingDrain = nil
            state = .invalidated
            admissionAuthority.invalidate(error: .channelFailure(failure))
            drain.timeoutTask?.cancel()
            drain.continuation.resume(throwing: DoryFSWorkerBrokerError.channelFailure(failure))
            sendInvalidationFrame()
            channel.invalidate()
        case .success(let bytes):
            do {
                let frame = try DoryFSWorkerFrameCodec.decodeServiceFrame(
                    bytes,
                    maximumFrameBytes: limits.maximumFrameBytes
                )
                guard case .drained(let ack) = frame,
                      ack.generation == generation,
                      ack.shareCapabilityID == shareCapabilityID else {
                    throw DoryFSWorkerBrokerError.drainReplyMismatch
                }
                pendingDrain = nil
                state = .drained
                drain.timeoutTask?.cancel()
                drain.continuation.resume()
            } catch {
                failProtocolViolation(currentRequestID: nil, error: .drainReplyMismatch)
            }
        }
    }

    private func expireDrain() {
        guard state == .draining, let drain = pendingDrain else { return }
        pendingDrain = nil
        state = .invalidated
        admissionAuthority.invalidate(error: .drainDeadlineExpired)
        drain.timeoutTask?.cancel()
        let requests = removeAllPendingRequests()
        removeAllPendingPublications()
        for pending in requests {
            pending.continuation.resume(throwing: DoryFSWorkerBrokerError.channelInvalidated)
        }
        drain.continuation.resume(throwing: DoryFSWorkerBrokerError.drainDeadlineExpired)
        sendInvalidationFrame()
        channel.invalidate()
    }

    private func receiveChannelEvent(_ event: DoryFSWorkerChannelEvent) {
        switch event {
        case .interrupted:
            transitionToTerminal(.interrupted, error: .channelInterrupted)
            channel.invalidate()
        case .invalidated:
            transitionToTerminal(.invalidated, error: .channelInvalidated)
        }
    }

    private func failProtocolViolation(
        currentRequestID: UInt64?,
        error: DoryFSWorkerBrokerError
    ) {
        protocolViolations = saturatingAdd(protocolViolations, 1)
        if let currentRequestID, let current = removePendingRequest(currentRequestID) {
            current.continuation.resume(throwing: error)
        }
        transitionToTerminal(.protocolViolation, error: .channelInvalidated)
        sendInvalidationFrame()
        channel.invalidate()
    }

    private func transitionToTerminal(
        _ newState: DoryFSWorkerBrokerState,
        error: DoryFSWorkerBrokerError
    ) {
        guard state == .active || state == .draining || state == .drained else { return }
        admissionAuthority.invalidate(error: error)
        state = newState
        let requests = removeAllPendingRequests()
        removeAllPendingPublications()
        let drain = pendingDrain
        pendingDrain = nil
        drain?.timeoutTask?.cancel()
        for pending in requests {
            pending.continuation.resume(throwing: error)
        }
        drain?.continuation.resume(throwing: error)
    }

    private func removeAllPendingRequests() -> [PendingRequest] {
        let requests = Array(pendingByRequestID.values)
        for request in requests {
            request.timeoutTask?.cancel()
            request.admissionLease.release()
        }
        pendingByRequestID.removeAll(keepingCapacity: true)
        requestIDByCorrelationID.removeAll(keepingCapacity: true)
        return requests
    }

    private func removeAllPendingPublications() {
        let publications = Array(pendingPublicationsByRequestID.values)
        for publication in publications {
            publication.timeoutTask?.cancel()
            publication.admissionLease.release()
        }
        pendingPublicationsByRequestID.removeAll(keepingCapacity: true)
        requestIDByCorrelationID.removeAll(keepingCapacity: true)
    }

    private func validateOperationDeadline(_ deadline: UInt64, now: UInt64) throws -> UInt64 {
        guard deadline > now else { throw reject(.operationDeadlineExpired) }
        let remaining = deadline - now
        guard remaining <= limits.maximumOperationNanoseconds else {
            throw reject(.operationDeadlineTooDistant(
                limitNanoseconds: limits.maximumOperationNanoseconds,
                actualNanoseconds: remaining
            ))
        }
        return remaining
    }

    private func sendInvalidationFrame() {
        let invalidation = DoryFSWorkerInvalidation(
            generation: generation,
            shareCapabilityID: shareCapabilityID
        )
        if let frame = try? DoryFSWorkerFrameCodec.encode(
            .invalidate(invalidation),
            maximumFrameBytes: limits.maximumFrameBytes
        ) {
            channel.sendOneWay(frame: frame)
        }
    }

    private func validateDrainDeadline(_ deadline: UInt64, now: UInt64) throws -> UInt64 {
        guard deadline > now else { throw DoryFSWorkerBrokerError.drainDeadlineExpired }
        let remaining = deadline - now
        guard remaining <= limits.maximumDrainNanoseconds else {
            throw DoryFSWorkerBrokerError.drainDeadlineTooDistant(
                limitNanoseconds: limits.maximumDrainNanoseconds,
                actualNanoseconds: remaining
            )
        }
        return remaining
    }

    private func reject(_ error: DoryFSWorkerBrokerError) -> DoryFSWorkerBrokerError {
        rejectedAdmissions = saturatingAdd(rejectedAdmissions, 1)
        return error
    }

    private func saturatingAdd(_ value: UInt64, _ increment: UInt64) -> UInt64 {
        let (sum, overflow) = value.addingReportingOverflow(increment)
        return overflow ? UInt64.max : sum
    }
}
