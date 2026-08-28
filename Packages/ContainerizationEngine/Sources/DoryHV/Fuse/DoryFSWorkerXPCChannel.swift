import DoryFSWorkerContracts
import Foundation

public enum DoryFSWorkerWorkspaceClientError: Error, Equatable, Sendable {
    case invalidBootstrap(DoryFSWorkerBootstrapError)
    case bootstrapRejected(DoryFSWorkerBootstrapRejectionReason)
    case channelFailure(DoryFSWorkerChannelFailure)
    case malformedResult(DoryFSWorkerRPCResultError)
    case receiptMismatch
    case unknownShare(DoryFSShareCapabilityID)
    case bootstrapTimedOut
    case coherenceStatusTimedOut
    case malformedCoherenceStatus
}

/// One authenticated connection to the runner-local signed filesystem service. The class unwraps
/// only the exact RPC-result envelope; `DoryFSWorkerBroker` remains responsible for validating the
/// inner service frame against its generation, capability, request, correlation, and limits.
public final class DoryFSWorkerXPCChannel:
    NSObject,
    DoryFSWorkerChannel,
    @unchecked Sendable
{
    private static let workerCodeSigningRequirement =
        #"anchor apple generic and identifier "com.pythonxi.Dory.HVRunner.FSWorker" and certificate leaf[subject.OU] = "864H636QW4""#

    private enum State {
        case active
        case interrupted
        case invalidated
    }

    private final class ReplyOnce: @unchecked Sendable {
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

    private final class CoherenceFailureRelay: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (@Sendable (DoryFSWorkerCoherenceSinkError) -> Void)?
        private var pending: DoryFSWorkerCoherenceSinkError?

        func install(
            _ handler: @escaping @Sendable (DoryFSWorkerCoherenceSinkError) -> Void
        ) {
            let immediate = lock.withLock { () -> DoryFSWorkerCoherenceSinkError? in
                self.handler = handler
                defer { pending = nil }
                return pending
            }
            if let immediate { handler(immediate) }
        }

        func report(_ error: DoryFSWorkerCoherenceSinkError) {
            let callback = lock.withLock { () -> (@Sendable (
                DoryFSWorkerCoherenceSinkError
            ) -> Void)? in
                guard pending == nil else { return nil }
                pending = error
                return handler
            }
            callback?(error)
        }
    }

    private let connection: NSXPCConnection
    private let coherenceSink: DoryFSWorkerCoherenceXPCSink
    private let coherenceFailureRelay: CoherenceFailureRelay
    private let stateLock = NSLock()
    private var state: State = .active
    private var lifecycleHandlers = [@Sendable (DoryFSWorkerChannelEvent) -> Void]()

    init(
        expectedGeneration: DoryFSWorkerGeneration,
        capabilities: Set<DoryFSShareCapabilityID>
    ) {
        let failureRelay = CoherenceFailureRelay()
        coherenceFailureRelay = failureRelay
        coherenceSink = DoryFSWorkerCoherenceXPCSink(
            expectedGeneration: expectedGeneration,
            capabilities: capabilities,
            onFailure: { failureRelay.report($0) }
        )
        connection = NSXPCConnection(serviceName: DoryFSWorkerXPC.serviceName)
        super.init()
        failureRelay.install { [weak self] _ in self?.invalidate() }
        connection.remoteObjectInterface = DoryFSWorkerXPCInterface.make()
        connection.exportedInterface = DoryFSWorkerXPCInterface.makeCoherenceSink()
        connection.exportedObject = coherenceSink
        connection.interruptionHandler = { [weak self] in
            self?.transition(to: .interrupted)
        }
        connection.invalidationHandler = { [weak self] in
            self?.transition(to: .invalidated)
        }
        connection.setCodeSigningRequirement(Self.workerCodeSigningRequirement)
        connection.resume()
    }

    @discardableResult
    public func installCoherenceHandler(
        _ handler: @escaping @Sendable (DoryFSWorkerCoherenceBatch) async throws -> Void
    ) -> Bool {
        coherenceSink.installHandler(handler)
    }

    public var coherenceStatistics: DoryFSWorkerCoherenceSinkStatistics {
        coherenceSink.statistics
    }

    public func coherenceStatus(
        timeout: TimeInterval = 1
    ) throws -> DoryFSWorkerCoherenceStatus {
        let state = BlockingCoherenceStatus()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            state.resolve(nil)
            self?.transition(to: .interrupted)
        }) as? DoryFSWorkerXPCProtocol else {
            throw DoryFSWorkerWorkspaceClientError.malformedCoherenceStatus
        }
        proxy.coherenceStatus { bytes in state.resolve(bytes) }
        let result = state.condition.withLock { () -> (Bool, Data?) in
            let deadline = Date(timeIntervalSinceNow: max(0, timeout))
            while !state.completed, state.condition.wait(until: deadline) {}
            return (state.completed, state.bytes)
        }
        guard result.0 else {
            throw DoryFSWorkerWorkspaceClientError.coherenceStatusTimedOut
        }
        guard let bytes = result.1,
              let status = try? DoryFSWorkerCoherenceStatusCodec.decode(bytes) else {
            throw DoryFSWorkerWorkspaceClientError.malformedCoherenceStatus
        }
        return status
    }

    public func activateCoherence(
        timeout: TimeInterval = 2
    ) throws -> DoryFSWorkerCoherenceStatus {
        let state = BlockingCoherenceStatus()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            state.resolve(nil)
            self?.transition(to: .interrupted)
        }) as? DoryFSWorkerXPCProtocol else {
            throw DoryFSWorkerWorkspaceClientError.malformedCoherenceStatus
        }
        proxy.activateCoherence { bytes in state.resolve(bytes) }
        let result = state.condition.withLock { () -> (Bool, Data?) in
            let deadline = Date(timeIntervalSinceNow: max(0, timeout))
            while !state.completed, state.condition.wait(until: deadline) {}
            return (state.completed, state.bytes)
        }
        guard result.0 else {
            invalidate()
            throw DoryFSWorkerWorkspaceClientError.coherenceStatusTimedOut
        }
        guard let bytes = result.1,
              let status = try? DoryFSWorkerCoherenceStatusCodec.decode(bytes) else {
            invalidate()
            throw DoryFSWorkerWorkspaceClientError.malformedCoherenceStatus
        }
        return status
    }

    private final class BlockingCoherenceStatus: @unchecked Sendable {
        let condition = NSCondition()
        var completed = false
        var bytes: Data?

        func resolve(_ bytes: Data?) {
            condition.withLock {
                guard !completed else { return }
                completed = true
                self.bytes = bytes
                condition.broadcast()
            }
        }
    }

    public func installLifecycleHandler(
        _ handler: @escaping @Sendable (DoryFSWorkerChannelEvent) -> Void
    ) {
        let immediate: DoryFSWorkerChannelEvent? = stateLock.withLock {
            switch state {
            case .active:
                lifecycleHandlers.append(handler)
                return nil
            case .interrupted:
                return .interrupted
            case .invalidated:
                return .invalidated
            }
        }
        if let immediate { handler(immediate) }
    }

    public func bootstrap(
        exactBytes: Data,
        rootDescriptors: [FileHandle],
        completion: @escaping @Sendable (
            Result<Data, DoryFSWorkerWorkspaceClientError>
        ) -> Void
    ) {
        guard stateLock.withLock({ if case .active = state { true } else { false } }) else {
            completion(.failure(.channelFailure(.unavailable)))
            return
        }
        let once = ReplyOnce()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            guard once.claim() else { return }
            completion(.failure(.channelFailure(.unavailable)))
            self?.transition(to: .interrupted)
        }) as? DoryFSWorkerXPCProtocol else {
            completion(.failure(.channelFailure(.unavailable)))
            transition(to: .interrupted)
            return
        }
        proxy.bootstrap(exactBytes, rootDescriptors: rootDescriptors) { [weak self] bytes in
            guard once.claim() else { return }
            switch Self.unwrapBootstrapResult(bytes) {
            case .success(let payload):
                completion(.success(payload))
            case .failure(let error):
                completion(.failure(error))
                self?.invalidate()
            }
        }
    }

    public func send(
        frame: Data,
        completion: @escaping @Sendable (
            Result<Data, DoryFSWorkerChannelFailure>
        ) -> Void
    ) {
        guard stateLock.withLock({ if case .active = state { true } else { false } }) else {
            completion(.failure(.unavailable))
            return
        }
        let once = ReplyOnce()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            guard once.claim() else { return }
            completion(.failure(.unavailable))
            self?.transition(to: .interrupted)
        }) as? DoryFSWorkerXPCProtocol else {
            completion(.failure(.unavailable))
            transition(to: .interrupted)
            return
        }
        proxy.exchange(frame) { [weak self] bytes in
            guard once.claim() else { return }
            do {
                switch try DoryFSWorkerRPCResultCodec.decode(bytes) {
                case .success(let payload):
                    completion(.success(payload))
                case .failure(let code):
                    completion(.failure(.serviceFailure(code)))
                }
            } catch {
                completion(.failure(.unavailable))
                self?.invalidate()
            }
        }
    }

    public func sendOneWay(frame: Data) {
        guard stateLock.withLock({ if case .active = state { true } else { false } }),
              let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
                  self?.transition(to: .interrupted)
              }) as? DoryFSWorkerXPCProtocol else { return }
        proxy.sendOneWay(frame)
    }

    public func invalidate() {
        transition(to: .invalidated)
        connection.invalidate()
    }

    private func transition(to requested: State) {
        let delivery: (
            handlers: [@Sendable (DoryFSWorkerChannelEvent) -> Void],
            event: DoryFSWorkerChannelEvent
        )? = stateLock.withLock {
            guard case .active = state else { return nil }
            state = requested
            let handlers = lifecycleHandlers
            lifecycleHandlers.removeAll(keepingCapacity: false)
            switch requested {
            case .active:
                return nil
            case .interrupted:
                return (handlers, .interrupted)
            case .invalidated:
                return (handlers, .invalidated)
            }
        }
        if let delivery {
            for handler in delivery.handlers { handler(delivery.event) }
        }
    }

    static func unwrapBootstrapResult(
        _ bytes: Data
    ) -> Result<Data, DoryFSWorkerWorkspaceClientError> {
        do {
            switch try DoryFSWorkerRPCResultCodec.decode(bytes) {
            case .success(let payload):
                return .success(payload)
            case .failure(let code):
                if let reason = code.bootstrapRejectionReason {
                    return .failure(.bootstrapRejected(reason))
                }
                return .failure(.channelFailure(.serviceFailure(code)))
            }
        } catch let error as DoryFSWorkerRPCResultError {
            return .failure(.malformedResult(error))
        } catch {
            return .failure(.channelFailure(.unavailable))
        }
    }
}

/// Validates a one-shot bootstrap receipt before exposing any share broker. All brokers retain the
/// same workspace channel, so interruption, malformed service data, or one share's fail-stop
/// invalidation tears down the complete worker authority generation.
public final class DoryFSWorkerWorkspaceClient: @unchecked Sendable {
    private final class BlockingBootstrap: @unchecked Sendable {
        let condition = NSCondition()
        var result: Result<Data, DoryFSWorkerWorkspaceClientError>?
    }
    public let bootstrap: DoryFSWorkerBootstrap
    private let channel: DoryFSWorkerXPCChannel
    private let admissionAuthority: DoryFSWorkerWorkspaceAdmissionAuthority

    private init(
        bootstrap: DoryFSWorkerBootstrap,
        channel: DoryFSWorkerXPCChannel
    ) {
        self.bootstrap = bootstrap
        self.channel = channel
        self.admissionAuthority = DoryFSWorkerWorkspaceAdmissionAuthority(
            workerLimits: bootstrap.workerLimits,
            shareLimits: Dictionary(
                uniqueKeysWithValues: bootstrap.shares.map {
                    ($0.capabilityID, $0.resourceLimits)
                }
            )
        )
    }

    public static func connect(
        exactBootstrapBytes: Data,
        rootDescriptors: [FileHandle]
    ) async throws -> Self {
        let bootstrap: DoryFSWorkerBootstrap
        do {
            bootstrap = try DoryFSWorkerBootstrapCodec.decode(exactBootstrapBytes)
        } catch let error as DoryFSWorkerBootstrapError {
            throw DoryFSWorkerWorkspaceClientError.invalidBootstrap(error)
        }
        let channel = DoryFSWorkerXPCChannel(
            expectedGeneration: bootstrap.generation,
            capabilities: Set(bootstrap.shares.map(\.capabilityID))
        )
        let receiptBytes: Data = try await withCheckedThrowingContinuation { continuation in
            channel.bootstrap(
                exactBytes: exactBootstrapBytes,
                rootDescriptors: rootDescriptors
            ) { result in
                continuation.resume(with: result)
            }
        }
        let receipt: DoryFSWorkerBootstrapReceipt
        do {
            receipt = try DoryFSWorkerBootstrapCodec.decodeReceipt(receiptBytes)
        } catch {
            channel.invalidate()
            throw DoryFSWorkerWorkspaceClientError.receiptMismatch
        }
        guard receipt == DoryFSWorkerBootstrapReceipt(accepting: bootstrap) else {
            channel.invalidate()
            throw DoryFSWorkerWorkspaceClientError.receiptMismatch
        }
        return Self(bootstrap: bootstrap, channel: channel)
    }

    public static func connectBlocking(
        exactBootstrapBytes: Data,
        rootDescriptors: [FileHandle],
        timeout: TimeInterval = 30
    ) throws -> Self {
        let bootstrap: DoryFSWorkerBootstrap
        do {
            bootstrap = try DoryFSWorkerBootstrapCodec.decode(exactBootstrapBytes)
        } catch let error as DoryFSWorkerBootstrapError {
            throw DoryFSWorkerWorkspaceClientError.invalidBootstrap(error)
        }
        let channel = DoryFSWorkerXPCChannel(
            expectedGeneration: bootstrap.generation,
            capabilities: Set(bootstrap.shares.map(\.capabilityID))
        )
        let blocking = BlockingBootstrap()
        channel.bootstrap(
            exactBytes: exactBootstrapBytes,
            rootDescriptors: rootDescriptors
        ) { result in
            blocking.condition.withLock {
                guard blocking.result == nil else { return }
                blocking.result = result
                blocking.condition.broadcast()
            }
        }
        let result: Result<Data, DoryFSWorkerWorkspaceClientError>? =
            blocking.condition.withLock {
                let deadline = Date(timeIntervalSinceNow: max(0, timeout))
                while blocking.result == nil, blocking.condition.wait(until: deadline) {}
                return blocking.result
            }
        guard let result else {
            channel.invalidate()
            throw DoryFSWorkerWorkspaceClientError.bootstrapTimedOut
        }
        let receiptBytes = try result.get()
        guard let receipt = try? DoryFSWorkerBootstrapCodec.decodeReceipt(receiptBytes),
              receipt == DoryFSWorkerBootstrapReceipt(accepting: bootstrap) else {
            channel.invalidate()
            throw DoryFSWorkerWorkspaceClientError.receiptMismatch
        }
        return Self(bootstrap: bootstrap, channel: channel)
    }

    public func broker(
        for capabilityID: DoryFSShareCapabilityID
    ) throws -> DoryFSWorkerBroker {
        guard let share = bootstrap.shares.first(where: { $0.capabilityID == capabilityID }) else {
            throw DoryFSWorkerWorkspaceClientError.unknownShare(capabilityID)
        }
        return DoryFSWorkerBroker(
            shareCapabilityID: capabilityID,
            generation: bootstrap.generation,
            limits: bootstrap.workerLimits,
            shareResourceLimits: share.resourceLimits,
            admissionAuthority: admissionAuthority,
            channel: channel
        )
    }

    @discardableResult
    public func installCoherenceHandler(
        _ handler: @escaping @Sendable (DoryFSWorkerCoherenceBatch) async throws -> Void
    ) -> Bool {
        channel.installCoherenceHandler(handler)
    }

    public func installLifecycleHandler(
        _ handler: @escaping @Sendable (DoryFSWorkerChannelEvent) -> Void
    ) {
        channel.installLifecycleHandler(handler)
    }

    public var coherenceStatistics: DoryFSWorkerCoherenceSinkStatistics {
        channel.coherenceStatistics
    }

    public func coherenceStatus(
        timeout: TimeInterval = 1
    ) throws -> DoryFSWorkerCoherenceStatus {
        try channel.coherenceStatus(timeout: timeout)
    }

    public func activateCoherence(timeout: TimeInterval = 2) throws {
        let status = try channel.activateCoherence(timeout: timeout)
        guard status.generation == bootstrap.generation,
              status.running,
              status.configuredShareCount == 0 || status.observationStreamCount > 0,
              status.requiredObservationShareCount == status.observedRequiredShareCount else {
            channel.invalidate()
            throw DoryFSWorkerWorkspaceClientError.malformedCoherenceStatus
        }
    }

    public func invalidate() {
        channel.invalidate()
    }
}
