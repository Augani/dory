import Darwin
import DoryFSWorkerContracts
import Foundation

/// Data-only execution boundary embedded by the signed XPC service target. This type owns the
/// complete HostFS/FuseServer graph; callers can bootstrap, exchange exact frames, or send
/// priority one-way control frames, but can never obtain a path, descriptor, or server object.
public final class DoryFSWorkerService: @unchecked Sendable {
    public typealias CoherenceExchange = @Sendable (Data) throws -> Data
    public typealias CoherenceFailureHandler = @Sendable (
        DoryFSWorkerHostCoherenceError
    ) -> Void

    private enum Lifecycle {
        case awaitingBootstrap
        case active(Workspace)
        case failed
    }

    private final class Workspace: @unchecked Sendable {
        let generation: DoryFSWorkerGeneration
        let limits: DoryFSWorkerLimits
        let shares: [DoryFSShareCapabilityID: Share]
        let hostCoherence: DoryFSWorkerHostCoherence?

        init(
            generation: DoryFSWorkerGeneration,
            limits: DoryFSWorkerLimits,
            shares: [DoryFSShareCapabilityID: Share],
            hostCoherence: DoryFSWorkerHostCoherence?
        ) {
            self.generation = generation
            self.limits = limits
            self.shares = shares
            self.hostCoherence = hostCoherence
        }
    }

    private final class Share: @unchecked Sendable {
        private enum State {
            case active
            case draining
            case drained
            case invalidated
        }

        private struct Reservation {
            let request: DoryFSWorkerRequest
            let requestBytes: Int
            let responseBytes: Int
        }

        private struct PendingPublication {
            let reservation: Reservation
            let opcode: FuseOpcode?
            let response: [UInt8]
        }

        let capabilityID: DoryFSShareCapabilityID
        let generation: DoryFSWorkerGeneration
        let workerLimits: DoryFSWorkerLimits
        let shareLimits: DoryFSShareResourceLimits
        let hostFS: HostFS
        let server: FuseServer

        private let lock = NSLock()
        private var state: State = .active
        private var activeByRequestID = [UInt64: Reservation]()
        private var requestIDByCorrelationID = [UInt64: UInt64]()
        private var pendingByRequestID = [UInt64: PendingPublication]()
        private var aggregateRequestBytes = 0
        private var aggregateResponseBytes = 0
        private var destroyPublicationCommitted = false
        private var resetCompleted = false

        init(
            authority: DoryFSShareBootstrapAuthority,
            generation: DoryFSWorkerGeneration,
            workerLimits: DoryFSWorkerLimits,
            hostFS: HostFS,
            server: FuseServer
        ) {
            capabilityID = authority.capabilityID
            self.generation = generation
            self.workerLimits = workerLimits
            shareLimits = authority.resourceLimits
            self.hostFS = hostFS
            self.server = server
        }

        func execute(_ request: DoryFSWorkerRequest) -> DoryFSWorkerServiceFrame {
            // Materialize the bounded FUSE payload once. Validation and execution consume the same
            // immutable bytes; the former implementation rebuilt a second payload-sized Array for
            // every admitted request.
            let requestBytes = [UInt8](request.payload)
            guard let opcode = validatedFUSEOpcode(request, bytes: requestBytes) else {
                return reply(to: request, outcome: .rejected(.invalidRequest))
            }
            let rejection = admit(request, opcode: opcode)
            if let rejection {
                return reply(to: request, outcome: .rejected(rejection))
            }

            let response = server.handle(request: requestBytes)

            let completion = finishExecution(
                request: request,
                opcode: opcode,
                response: response
            )
            switch completion {
            case .accepted(let response):
                return reply(to: request, outcome: .completed(Data(response)))
            case .rejected(let code):
                return reply(to: request, outcome: .rejected(code))
            }
        }

        func interrupt(_ interrupt: DoryFSWorkerInterrupt) {
            let admitted = lock.withLock {
                guard state == .active || state == .draining,
                      interrupt.generation == generation,
                      interrupt.shareCapabilityID == capabilityID,
                      let requestID = requestIDByCorrelationID[interrupt.targetCorrelationID],
                      requestID == interrupt.targetRequestID else { return false }
                return true
            }
            if admitted {
                server.interrupt(requestUnique: interrupt.targetCorrelationID)
            }
        }

        func acknowledge(
            _ publication: DoryFSWorkerPublication,
            committed: Bool
        ) {
            var shouldReset = false
            let pending: PendingPublication? = lock.withLock {
                guard state == .active || state == .draining,
                      publication.generation == generation,
                      publication.shareCapabilityID == capabilityID,
                      let pending = pendingByRequestID[publication.requestID],
                      pending.reservation.request.correlationID == publication.correlationID else {
                    return nil
                }
                pendingByRequestID.removeValue(forKey: publication.requestID)
                releaseReservationLocked(pending.reservation)
                if committed, pending.opcode == .destroy {
                    destroyPublicationCommitted = true
                }
                shouldReset = completeDestroyIfQuiescentLocked()
                return pending
            }
            guard let pending else { return }
            if committed {
                if pending.opcode == .initOp,
                   let header = try? FuseProtocol.decodeOutHeader(pending.response),
                   header.error == 0 {
                    server.markFuseInitCompleted()
                }
            } else if let opcode = pending.opcode {
                server.rollbackUnpublishedResponse(opcode: opcode, response: pending.response)
            }
            if shouldReset { resetIfNeeded() }
        }

        func drain(_ drain: DoryFSWorkerDrain) -> DoryFSWorkerServiceFrame? {
            let accepted = lock.withLock {
                guard state == .active,
                      drain.generation == generation,
                      drain.shareCapabilityID == capabilityID,
                      DispatchTime.now().uptimeNanoseconds < drain.deadlineUptimeNanoseconds,
                      activeByRequestID.isEmpty,
                      pendingByRequestID.isEmpty else { return false }
                state = .drained
                return true
            }
            guard accepted else { return nil }
            resetIfNeeded()
            return .drained(DoryFSWorkerDrained(
                generation: generation,
                shareCapabilityID: capabilityID
            ))
        }

        func invalidate(_ invalidation: DoryFSWorkerInvalidation) {
            guard invalidation.generation == generation,
                  invalidation.shareCapabilityID == capabilityID else { return }
            let pending: [PendingPublication] = lock.withLock {
                guard state != .invalidated else { return [] }
                state = .invalidated
                let values = Array(pendingByRequestID.values)
                pendingByRequestID.removeAll(keepingCapacity: false)
                for value in values {
                    releaseReservationLocked(value.reservation)
                }
                return values
            }
            server.cancelAllRequests()
            for value in pending {
                if let opcode = value.opcode {
                    server.rollbackUnpublishedResponse(opcode: opcode, response: value.response)
                }
            }
            resetIfQuiescent()
        }

        private enum Completion {
            case accepted([UInt8])
            case rejected(DoryFSWorkerRejectionCode)
        }

        private func admit(
            _ request: DoryFSWorkerRequest,
            opcode: FuseOpcode
        ) -> DoryFSWorkerRejectionCode? {
            let now = DispatchTime.now().uptimeNanoseconds
            guard request.generation == generation else { return .staleGeneration }
            guard request.shareCapabilityID == capabilityID else { return .unknownShare }
            guard request.deadlineUptimeNanoseconds > now,
                  request.deadlineUptimeNanoseconds - now
                    <= workerLimits.maximumOperationNanoseconds else {
                return .deadlineExpired
            }
            guard request.payload.count <= workerLimits.maximumRequestBytes,
                  Int(request.responseCapacity) <= workerLimits.maximumResponseBytes,
                  request.payload.count <= shareLimits.maximumAggregateRequestBytes,
                  Int(request.responseCapacity) <= shareLimits.maximumAggregateResponseBytes else {
                return .resourceExhausted
            }
            return lock.withLock {
                switch state {
                case .active:
                    break
                case .draining, .drained:
                    return .connectionTeardown
                case .invalidated:
                    return .shuttingDown
                }
                guard activeByRequestID.count + pendingByRequestID.count
                        < min(
                            workerLimits.maximumInFlightRequests,
                            shareLimits.maximumInFlightRequests
                        ) else { return .resourceExhausted }
                guard activeByRequestID[request.requestID] == nil,
                      pendingByRequestID[request.requestID] == nil,
                      requestIDByCorrelationID[request.correlationID] == nil else {
                    return .invalidRequest
                }
                let (requestTotal, requestOverflow) = aggregateRequestBytes
                    .addingReportingOverflow(request.payload.count)
                let (responseTotal, responseOverflow) = aggregateResponseBytes
                    .addingReportingOverflow(Int(request.responseCapacity))
                guard !requestOverflow,
                      !responseOverflow,
                      requestTotal <= min(
                        workerLimits.maximumAggregateRequestBytes,
                        shareLimits.maximumAggregateRequestBytes
                      ),
                      responseTotal <= min(
                        workerLimits.maximumAggregateResponseBytes,
                        shareLimits.maximumAggregateResponseBytes
                      ) else { return .resourceExhausted }
                let reservation = Reservation(
                    request: request,
                    requestBytes: request.payload.count,
                    responseBytes: Int(request.responseCapacity)
                )
                activeByRequestID[request.requestID] = reservation
                requestIDByCorrelationID[request.correlationID] = request.requestID
                aggregateRequestBytes = requestTotal
                aggregateResponseBytes = responseTotal
                if opcode == .destroy {
                    // No request arriving after DESTROY may acquire new host authority. Work that
                    // was already admitted is allowed to publish before the committed teardown
                    // resets every FUSE node/handle owned by this share.
                    state = .draining
                }
                return nil
            }
        }

        private func validatedFUSEOpcode(
            _ request: DoryFSWorkerRequest,
            bytes: [UInt8]
        ) -> FuseOpcode? {
            guard let header = try? FuseProtocol.decodeInHeader(bytes),
                  header.unique == request.correlationID,
                  header.length >= UInt32(FuseInHeader.byteCount),
                  Int(header.length) == bytes.count,
                  let opcode = FuseOpcode(rawValue: header.opcode),
                  opcode.workerOpcodeClass == request.opcodeClass else { return nil }
            return opcode
        }

        private func finishExecution(
            request: DoryFSWorkerRequest,
            opcode: FuseOpcode?,
            response: [UInt8]
        ) -> Completion {
            var shouldReset = false
            let result: Completion = lock.withLock {
                guard let reservation = activeByRequestID.removeValue(
                    forKey: request.requestID
                ) else {
                    return .rejected(.shuttingDown)
                }
                guard state == .active || state == .draining,
                      DispatchTime.now().uptimeNanoseconds
                        < request.deadlineUptimeNanoseconds else {
                    releaseReservationLocked(reservation)
                    shouldReset = state == .invalidated && activeByRequestID.isEmpty
                    return .rejected(
                        state == .invalidated ? .shuttingDown : .deadlineExpired
                    )
                }
                guard response.count <= Int(request.responseCapacity),
                      response.count <= workerLimits.maximumResponseBytes else {
                    state = .invalidated
                    releaseReservationLocked(reservation)
                    shouldReset = activeByRequestID.isEmpty
                    return .rejected(.internalFailure)
                }
                pendingByRequestID[request.requestID] = PendingPublication(
                    reservation: reservation,
                    opcode: opcode,
                    response: response
                )
                return .accepted(response)
            }
            if case .rejected = result, let opcode {
                server.rollbackUnpublishedResponse(opcode: opcode, response: response)
            }
            if shouldReset { resetIfNeeded() }
            return result
        }

        private func completeDestroyIfQuiescentLocked() -> Bool {
            guard state == .draining,
                  destroyPublicationCommitted,
                  activeByRequestID.isEmpty,
                  pendingByRequestID.isEmpty else { return false }
            state = .drained
            return true
        }

        private func releaseReservationLocked(_ reservation: Reservation) {
            requestIDByCorrelationID.removeValue(
                forKey: reservation.request.correlationID
            )
            precondition(aggregateRequestBytes >= reservation.requestBytes)
            precondition(aggregateResponseBytes >= reservation.responseBytes)
            aggregateRequestBytes -= reservation.requestBytes
            aggregateResponseBytes -= reservation.responseBytes
        }

        private func resetIfQuiescent() {
            let ready = lock.withLock {
                state == .invalidated
                    && activeByRequestID.isEmpty
                    && pendingByRequestID.isEmpty
            }
            if ready { resetIfNeeded() }
        }

        private func resetIfNeeded() {
            let shouldReset = lock.withLock {
                guard !resetCompleted else { return false }
                resetCompleted = true
                return true
            }
            if shouldReset { server.resetConnection() }
        }

        private func reply(
            to request: DoryFSWorkerRequest,
            outcome: DoryFSWorkerReplyOutcome
        ) -> DoryFSWorkerServiceFrame {
            .reply(try! DoryFSWorkerReply(
                generation: request.generation,
                shareCapabilityID: request.shareCapabilityID,
                requestID: request.requestID,
                correlationID: request.correlationID,
                outcome: outcome
            ))
        }
    }

    private let rootAuthority: DoryFSWorkerRootAuthority
    private let coherenceExchange: CoherenceExchange?
    private let coherenceFailureHandler: CoherenceFailureHandler
    private let lifecycleLock = NSLock()
    private var lifecycle: Lifecycle = .awaitingBootstrap

    public init() {
        rootAuthority = DoryFSWorkerRootAuthority()
        coherenceExchange = nil
        coherenceFailureHandler = { _ in }
    }

    /// Production XPC adapter initializer. Host-change observation is deliberately opt-in at this
    /// composition boundary so pure service-core fixtures cannot accidentally acquire FSEvents
    /// authority. The signed worker always supplies both callbacks and exits on any failure.
    public init(
        coherenceExchange: @escaping CoherenceExchange,
        onCoherenceFailure: @escaping CoherenceFailureHandler
    ) {
        rootAuthority = DoryFSWorkerRootAuthority()
        self.coherenceExchange = coherenceExchange
        coherenceFailureHandler = onCoherenceFailure
    }

    init(rootAuthority: DoryFSWorkerRootAuthority) {
        self.rootAuthority = rootAuthority
        coherenceExchange = nil
        coherenceFailureHandler = { _ in }
    }

    public func bootstrap(
        exactBytes: Data,
        rootDescriptors: [FileHandle]
    ) -> Data {
        let claimed = lifecycleLock.withLock { () -> Bool in
            guard case .awaitingBootstrap = lifecycle else { return false }
            lifecycle = .failed
            return true
        }
        guard claimed else {
            return encodeRPC(.failure(.bootstrapAlreadyAttempted))
        }

        do {
            let bootstrap = try DoryFSWorkerBootstrapCodec.decode(exactBytes)
            guard coherenceExchange != nil || bootstrap.shares.allSatisfy({
                $0.coherencePolicy == .disabled
            }) else {
                // A non-disabled policy is a correctness contract, not an advisory setting. Never
                // accept the workspace unless this service composition can carry the worker's
                // retained batches to the runner for invalidation and acknowledgement.
                return encodeRPC(.failure(.bootstrapRejected))
            }
            let receipt = try rootAuthority.bootstrap(
                exactBytes: exactBytes,
                rootDescriptors: rootDescriptors
            )
            var shares = [DoryFSShareCapabilityID: Share](
                minimumCapacity: bootstrap.shares.count
            )
            for authority in bootstrap.shares {
                let pair = try rootAuthority.withBorrowedRootFileDescriptor(
                    for: authority.capabilityID
                ) { descriptor in
                    let hostFS = try HostFS(
                        rootDirectoryFileDescriptor: descriptor,
                        guestUID: authority.guestIdentity.uid,
                        guestGID: authority.guestIdentity.gid,
                        readOnly: authority.readOnly,
                        hiddenNames: Set(authority.hiddenComponents),
                        rootHiddenNames: Set(authority.rootHiddenComponents),
                        resourceLimits: FuseResourceLimits(authority.resourceLimits)
                    )
                    return (hostFS, FuseServer(hostFS: hostFS))
                }
                shares[authority.capabilityID] = Share(
                    authority: authority,
                    generation: bootstrap.generation,
                    workerLimits: bootstrap.workerLimits,
                    hostFS: pair.0,
                    server: pair.1
                )
            }
            let coherenceShares: [(
                DoryFSShareCapabilityID,
                HostFS,
                DoryFSShareCoherencePolicy
            )] = bootstrap.shares.compactMap { authority in
                guard authority.coherencePolicy != .disabled else { return nil }
                return shares[authority.capabilityID].map {
                    (authority.capabilityID, $0.hostFS, authority.coherencePolicy)
                }
            }
            let hostCoherence: DoryFSWorkerHostCoherence?
            if let exchange = coherenceExchange, !coherenceShares.isEmpty {
                hostCoherence = try DoryFSWorkerHostCoherence(
                    generation: bootstrap.generation,
                    shares: coherenceShares,
                    exchange: exchange,
                    onFailure: { [weak self] error in
                        self?.lifecycleLock.withLock { self?.lifecycle = .failed }
                        self?.coherenceFailureHandler(error)
                    }
                )
            } else {
                hostCoherence = nil
            }
            let workspace = Workspace(
                generation: bootstrap.generation,
                limits: bootstrap.workerLimits,
                shares: shares,
                hostCoherence: hostCoherence
            )
            lifecycleLock.withLock { lifecycle = .active(workspace) }
            return encodeRPC(.success(receipt))
        } catch let error as DoryFSWorkerRootAuthorityError {
            return encodeRPC(.failure(error.bootstrapFailureCode))
        } catch {
            return encodeRPC(.failure(.bootstrapRejected))
        }
    }

    public func exchange(exactFrame: Data) -> Data {
        guard let workspace = activeWorkspace() else {
            return encodeRPC(.failure(.bootstrapRequired))
        }
        let frame: DoryFSWorkerClientFrame
        do {
            frame = try DoryFSWorkerFrameCodec.decodeClientFrame(
                exactFrame,
                maximumFrameBytes: workspace.limits.maximumFrameBytes
            )
        } catch {
            return encodeRPC(.failure(.invalidEnvelope))
        }

        switch frame {
        case .execute(let request):
            guard let share = workspace.shares[request.shareCapabilityID] else {
                return encodeRPC(.failure(.unknownShare))
            }
            return encodeServiceFrame(share.execute(request), limits: workspace.limits)
        case .drain(let drain):
            guard let share = workspace.shares[drain.shareCapabilityID] else {
                return encodeRPC(.failure(.unknownShare))
            }
            guard let reply = share.drain(drain) else {
                return encodeRPC(.failure(.shuttingDown))
            }
            return encodeServiceFrame(reply, limits: workspace.limits)
        case .interrupt, .invalidate, .commitPublication, .discardPublication:
            return encodeRPC(.failure(.protocolViolation))
        }
    }

    public func sendOneWay(exactFrame: Data) {
        guard let workspace = activeWorkspace(),
              let frame = try? DoryFSWorkerFrameCodec.decodeClientFrame(
                exactFrame,
                maximumFrameBytes: workspace.limits.maximumFrameBytes
              ) else { return }
        switch frame {
        case .interrupt(let interrupt):
            workspace.shares[interrupt.shareCapabilityID]?.interrupt(interrupt)
        case .invalidate(let invalidation):
            workspace.shares[invalidation.shareCapabilityID]?.invalidate(invalidation)
        case .commitPublication(let publication):
            workspace.shares[publication.shareCapabilityID]?.acknowledge(
                publication,
                committed: true
            )
        case .discardPublication(let publication):
            workspace.shares[publication.shareCapabilityID]?.acknowledge(
                publication,
                committed: false
            )
        case .execute, .drain:
            break
        }
    }

    public var hostCoherenceStatistics: DoryFSWorkerHostCoherenceStatistics? {
        activeWorkspace()?.hostCoherence?.statistics
    }

    public func coherenceStatusExactBytes() -> Data {
        guard let workspace = activeWorkspace() else { return Data() }
        let statistics = workspace.hostCoherence?.statistics
        let status = try! DoryFSWorkerCoherenceStatus(
            generation: workspace.generation,
            running: statistics?.running ?? true,
            configuredShareCount: UInt32(statistics?.configuredShareCount ?? 0),
            invalidationOnlyShareCount: UInt32(
                statistics?.invalidationOnlyShareCount ?? 0
            ),
            watcherNudgeShareCount: UInt32(statistics?.watcherNudgeShareCount ?? 0),
            requiredObservationShareCount: UInt32(
                statistics?.requiredObservationShareCount ?? 0
            ),
            observedRequiredShareCount: UInt32(
                statistics?.observedRequiredShareCount ?? 0
            ),
            observationStreamCount: UInt32(statistics?.observationStreamCount ?? 0),
            pendingEventCount: UInt32(statistics?.pendingEventCount ?? 0),
            pendingEventLimit: UInt32(
                statistics?.pendingEventLimit ?? DoryFSWorkerHostCoherence.pendingEventLimit
            ),
            receivedEventCount: statistics?.receivedEventCount ?? 0,
            deliveredBatchCount: statistics?.deliveredBatchCount ?? 0,
            failedBatchCount: statistics?.failedBatchCount ?? 0,
            eventLossCount: statistics?.eventLossCount ?? 0
        )
        return DoryFSWorkerCoherenceStatusCodec.encode(status)
    }

    public func activateCoherenceExactBytes() -> Data {
        guard let workspace = activeWorkspace() else { return Data() }
        do {
            try workspace.hostCoherence?.activateDelivery()
            return coherenceStatusExactBytes()
        } catch {
            lifecycleLock.withLock { lifecycle = .failed }
            return Data()
        }
    }

    public func prepareCoherenceExactBytes() -> Data {
        guard let workspace = activeWorkspace() else { return Data() }
        do {
            try workspace.hostCoherence?.prepare()
            return coherenceStatusExactBytes()
        } catch {
            lifecycleLock.withLock { lifecycle = .failed }
            return Data()
        }
    }

    private func activeWorkspace() -> Workspace? {
        lifecycleLock.withLock {
            guard case .active(let workspace) = lifecycle else { return nil }
            return workspace
        }
    }

    private func encodeServiceFrame(
        _ frame: DoryFSWorkerServiceFrame,
        limits: DoryFSWorkerLimits
    ) -> Data {
        do {
            return encodeRPC(.success(try DoryFSWorkerFrameCodec.encode(
                frame,
                maximumFrameBytes: limits.maximumFrameBytes
            )))
        } catch {
            return encodeRPC(.failure(.internalFailure))
        }
    }

    private func encodeRPC(_ result: DoryFSWorkerRPCResult) -> Data {
        // Every locally-constructed result is within an absolute compile-time envelope.
        (try? DoryFSWorkerRPCResultCodec.encode(result)) ?? Data()
    }
}

extension DoryFSWorkerRootAuthorityError {
    var bootstrapFailureCode: DoryFSWorkerRPCFailureCode {
        switch self {
        case .bootstrapAlreadyAttempted:
            .bootstrapAlreadyAttempted
        case .descriptorCountMismatch, .rootDescriptorUnavailable:
            .bootstrapDescriptorTransferFailed
        case .rootInspectionFailed, .rootIsNotDirectory, .descriptorBorrowFailed:
            .bootstrapRootOpenFailed
        case .rootIdentityMismatch:
            .bootstrapRootIdentityMismatch
        case .bootstrapNotAccepted, .unknownCapability:
            .bootstrapRejected
        }
    }
}

private extension FuseResourceLimits {
    init(_ limits: DoryFSShareResourceLimits) {
        self.init(
            maximumLiveNonRootNodes: limits.maximumLiveNonRootNodes,
            maximumFileHandles: limits.maximumFileHandles,
            maximumDirectoryHandles: limits.maximumDirectoryHandles,
            maximumDirectoryCursorEntries: limits.maximumDirectoryCursorEntries,
            maximumDirectoryCursorNameBytes: limits.maximumDirectoryCursorNameBytes,
            maximumAdvisoryLockOwners: limits.maximumAdvisoryLockOwners,
            maximumPendingBlockingLocks: limits.maximumPendingBlockingLocks
        )
    }
}
