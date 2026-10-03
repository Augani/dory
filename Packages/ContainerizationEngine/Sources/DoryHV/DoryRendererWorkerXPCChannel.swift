import DoryRendererWorkerContracts
import DoryRendererWorkerMetalTransport
import Foundation
import Metal

public enum DoryRendererWorkerChannelEvent: Equatable, Sendable {
    case interrupted
    case invalidated
}

public enum DoryRendererWorkerChannelFailure: Error, Equatable, Sendable {
    case unavailable
    case interrupted
    case invalidated
    case serviceFailure(DoryRendererWorkerRPCFailureCode)
    case malformedResult(DoryRendererWorkerContractError)
    case descriptorCountMismatch(expected: Int, actual: Int)
}

public struct DoryRendererWorkerChannelReply: @unchecked Sendable {
    public let payload: Data
    public let descriptors: [FileHandle]
    public let sharedTextureHandle: MTLSharedTextureHandle?

    public init(
        payload: Data,
        descriptors: [FileHandle],
        sharedTextureHandle: MTLSharedTextureHandle? = nil
    ) {
        self.payload = payload
        self.descriptors = descriptors
        self.sharedTextureHandle = sharedTextureHandle
    }
}

/// Transport seam for one authenticated renderer-worker generation. An interruption is terminal:
/// callers must bootstrap a new signed worker and generation instead of reconnecting to an
/// unknown foreign-renderer state.
public protocol DoryRendererWorkerChannel: AnyObject, Sendable {
    func installLifecycleHandler(
        _ handler: @escaping @Sendable (DoryRendererWorkerChannelEvent) -> Void
    )
    func bootstrap(
        exactBytes: Data,
        completion: @escaping @Sendable (
            Result<DoryRendererWorkerChannelReply, DoryRendererWorkerChannelFailure>
        ) -> Void
    )
    func exchange(
        frame: Data,
        descriptors: [FileHandle],
        completion: @escaping @Sendable (
            Result<DoryRendererWorkerChannelReply, DoryRendererWorkerChannelFailure>
        ) -> Void
    )
    func invalidate()
    /// Delivers only positive exit evidence for a peer observed after authenticated bootstrap.
    /// Local invalidation, proxy failure, and interruption are never retirement proof.
    func installRetirementHandler(_ handler: @escaping @Sendable (Int32) -> Void)
    func qualificationCrash(
        exactBytes: Data,
        acknowledgement: @escaping @Sendable (Bool, UInt32) -> Void,
        interrupted: @escaping @Sendable () -> Void
    )
}

public extension DoryRendererWorkerChannel {
    func installRetirementHandler(_ handler: @escaping @Sendable (Int32) -> Void) {
        // A transport without an exact process-exit observer must fail closed.
    }
    func qualificationCrash(exactBytes: Data, acknowledgement: @escaping @Sendable (Bool, UInt32) -> Void,
                            interrupted: @escaping @Sendable () -> Void) {
        // Non-XPC transports must opt in explicitly; fixtures cannot silently simulate a crash.
        acknowledgement(false, 0)
    }
}

/// Separate from ordinary channel failure: proxy errors may conservatively retire a generation,
/// but only NSXPCConnection's interruption callback can prove the qualification fault occurred.
final class DoryRendererWorkerConnectionInterruptionRelay: @unchecked Sendable {
    private enum State { case waiting, interrupted, locallyInvalidated }
    private let lock = NSLock()
    private var state: State = .waiting
    private var handlers = [@Sendable () -> Void]()

    func install(_ handler: @escaping @Sendable () -> Void) {
        let immediate = lock.withLock {
            switch state {
            case .waiting: handlers.append(handler); return false
            case .interrupted: return true
            case .locallyInvalidated: return false
            }
        }
        if immediate { handler() }
    }

    func connectionInterrupted() {
        let delivery: [@Sendable () -> Void] = lock.withLock {
            guard case .waiting = state else { return [] }
            state = .interrupted
            let delivery = handlers
            handlers.removeAll()
            return delivery
        }
        for handler in delivery { handler() }
    }

    func invalidateLocally() {
        lock.withLock {
            guard case .waiting = state else { return }
            state = .locallyInvalidated
            handlers.removeAll()
        }
    }
}

/// One kernel process watch, armed before the authenticated bootstrap is handed to the broker.
/// The PID is selected only from that accepted XPC peer, never an executable name or PID lookup.
/// Cancellation is not exit evidence. Tests may watch only a Process child they own.
final class DoryRendererWorkerProcessExitMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let source: DispatchSourceProcess
    private var stopped = false
    private var started = false
    private let exited: @Sendable () -> Void

    init?(processIdentifier: Int32, queue: DispatchQueue, exited: @escaping @Sendable () -> Void) {
        guard processIdentifier > 0 else { return nil }
        source = DispatchSource.makeProcessSource(
            identifier: processIdentifier, eventMask: .exit, queue: queue)
        self.exited = exited
        source.setEventHandler { [weak self] in self?.processExited() }
    }

    func start(registered: @escaping @Sendable () -> Void) {
        let shouldStart = lock.withLock { () -> Bool in
            guard !started, !stopped else { return false }
            started = true
            source.setRegistrationHandler { [weak self] in
                guard let self, !self.lock.withLock({ self.stopped }) else { return }
                registered()
            }
            return true
        }
        if shouldStart { source.resume() }
    }

    func cancel() {
        let shouldResume = lock.withLock { () -> Bool in
            stopped = true
            let shouldResume = !started
            started = true
            return shouldResume
        }
        source.cancel()
        if shouldResume { source.resume() }
    }

    private func processExited() {
        guard source.data.contains(.exit) else { return }
        let deliver = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            return true
        }
        source.cancel()
        if deliver { exited() }
    }

    deinit { cancel() }
}

/// Runner-local NSXPC adapter. The service name selects a launchd endpoint; the worker's audit
/// token code requirement is the peer authentication authority. No PID, path, environment value,
/// or reconnect heuristic participates in that decision.
public final class DoryRendererWorkerXPCChannel:
    NSObject,
    DoryRendererWorkerChannel,
    @unchecked Sendable
{
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

    private let connection: NSXPCConnection
    private let stateLock = NSLock()
    private var state: State = .active
    private var lifecycleHandlers = [@Sendable (DoryRendererWorkerChannelEvent) -> Void]()
    private var retirementHandlers = [@Sendable (Int32) -> Void]()
    private var exitedPeer: Int32?
    private var peerExitMonitor: DoryRendererWorkerProcessExitMonitor?
    private var pendingBootstrapRegistrations = [UUID: @Sendable (Bool) -> Void]()
    private let peerExitQueue = DispatchQueue(label: "dev.dory.renderer-worker.peer-exit")
    private let connectionInterruptionRelay = DoryRendererWorkerConnectionInterruptionRelay()

    public init(codeDirectoryHash: DoryCodeDirectoryHash) {
        connection = NSXPCConnection(serviceName: DoryRendererWorkerIdentity.serviceName)
        super.init()
        connection.remoteObjectInterface = DoryRendererWorkerXPCInterface.make()
        connection.interruptionHandler = { [weak self] in
            self?.connectionInterruptionRelay.connectionInterrupted()
            self?.transition(to: .interrupted)
        }
        connection.invalidationHandler = { [weak self] in
            self?.connectionInterruptionRelay.invalidateLocally()
            self?.transition(to: .invalidated)
        }
        connection.setCodeSigningRequirement(
            DoryRendererWorkerIdentity.exactWorkerCodeSigningRequirement(
                codeDirectoryHash: codeDirectoryHash
            )
        )
        connection.activate()
    }

    public func installLifecycleHandler(
        _ handler: @escaping @Sendable (DoryRendererWorkerChannelEvent) -> Void
    ) {
        let immediate: DoryRendererWorkerChannelEvent? = stateLock.withLock {
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

    public func installRetirementHandler(_ handler: @escaping @Sendable (Int32) -> Void) {
        let immediate = stateLock.withLock { () -> Int32? in
            if let exitedPeer { return exitedPeer }
            retirementHandlers.append(handler)
            return nil
        }
        if let immediate { handler(immediate) }
    }

    public func bootstrap(
        exactBytes: Data,
        completion: @escaping @Sendable (
            Result<DoryRendererWorkerChannelReply, DoryRendererWorkerChannelFailure>
        ) -> Void
    ) {
        guard isActive else {
            completion(.failure(.unavailable))
            return
        }
        let once = ReplyOnce()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            guard once.claim() else { return }
            completion(.failure(.interrupted))
            self?.transition(to: .interrupted)
        }) as? DoryRendererWorkerXPCProtocol else {
            completion(.failure(.unavailable))
            transition(to: .interrupted)
            return
        }
        proxy.bootstrap(exactBytes) { [weak self] bytes, descriptors in
            guard once.claim() else { Self.close(descriptors); return }
            do {
                switch try DoryRendererWorkerRPCResultCodec.decode(bytes) {
                case let .success(payload, descriptorCount):
                    guard Int(descriptorCount) == descriptors.count else {
                        Self.close(descriptors)
                        completion(.failure(.descriptorCountMismatch(
                            expected: Int(descriptorCount),
                            actual: descriptors.count
                        )))
                        self?.invalidate()
                        return
                    }
                    guard let self else {
                        Self.close(descriptors)
                        completion(.failure(.unavailable))
                        return
                    }
                    // Do not admit the first command until the exact authenticated peer's exit
                    // source is registered. The source survives local connection invalidation.
                    let publication = ReplyOnce()
                    let registrationID = UUID()
                    let finish: @Sendable (Bool) -> Void = { active in
                        guard publication.claim() else { return }
                        if active {
                            completion(.success(DoryRendererWorkerChannelReply(
                                payload: payload, descriptors: descriptors)))
                        } else {
                            Self.close(descriptors)
                            completion(.failure(.unavailable))
                        }
                    }
                    let admitted = self.stateLock.withLock {
                        guard case .active = self.state else { return false }
                        self.pendingBootstrapRegistrations[registrationID] = finish
                        return true
                    }
                    guard admitted else { finish(false); return }
                    guard self.observeAuthenticatedPeerExit({ [weak self] in
                        self?.completeBootstrapRegistration(registrationID)
                    }) else {
                        self.completeBootstrapRegistration(registrationID, forceFailure: true)
                        self.invalidate()
                        return
                    }
                case .failure(let code):
                    Self.close(descriptors)
                    completion(.failure(.serviceFailure(code)))
                }
            } catch let error as DoryRendererWorkerContractError {
                Self.close(descriptors)
                completion(.failure(.malformedResult(error)))
                self?.invalidate()
            } catch {
                Self.close(descriptors)
                completion(.failure(.unavailable))
                self?.invalidate()
            }
        }
    }

    public func exchange(
        frame: Data,
        descriptors: [FileHandle],
        completion: @escaping @Sendable (
            Result<DoryRendererWorkerChannelReply, DoryRendererWorkerChannelFailure>
        ) -> Void
    ) {
        guard isActive else {
            completion(.failure(.unavailable))
            return
        }
        let once = ReplyOnce()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            guard once.claim() else { return }
            completion(.failure(.interrupted))
            self?.transition(to: .interrupted)
        }) as? DoryRendererWorkerXPCProtocol else {
            completion(.failure(.unavailable))
            transition(to: .interrupted)
            return
        }
        proxy.exchange(frame, descriptors: descriptors) {
            [weak self] bytes, replyDescriptors, sharedTextureHandle in
            guard once.claim() else {
                Self.close(replyDescriptors)
                return
            }
            do {
                switch try DoryRendererWorkerRPCResultCodec.decode(bytes) {
                case let .success(payload, descriptorCount):
                    guard Int(descriptorCount) == replyDescriptors.count else {
                        Self.close(replyDescriptors)
                        completion(.failure(.descriptorCountMismatch(
                            expected: Int(descriptorCount),
                            actual: replyDescriptors.count
                        )))
                        self?.invalidate()
                        return
                    }
                    completion(.success(DoryRendererWorkerChannelReply(
                        payload: payload,
                        descriptors: replyDescriptors,
                        sharedTextureHandle: sharedTextureHandle
                    )))
                case .failure(let code):
                    guard replyDescriptors.isEmpty, sharedTextureHandle == nil else {
                        Self.close(replyDescriptors)
                        completion(.failure(.descriptorCountMismatch(
                            expected: 0,
                            actual: replyDescriptors.count
                        )))
                        self?.invalidate()
                        return
                    }
                    completion(.failure(.serviceFailure(code)))
                }
            } catch let error as DoryRendererWorkerContractError {
                Self.close(replyDescriptors)
                completion(.failure(.malformedResult(error)))
                self?.invalidate()
            } catch {
                Self.close(replyDescriptors)
                completion(.failure(.unavailable))
                self?.invalidate()
            }
        }
    }

    public func invalidate() {
        connectionInterruptionRelay.invalidateLocally()
        transition(to: .invalidated)
        connection.invalidate()
    }

    public func qualificationCrash(
        exactBytes: Data, acknowledgement: @escaping @Sendable (Bool, UInt32) -> Void,
        interrupted: @escaping @Sendable () -> Void
    ) {
        guard isActive,
              (try? DoryRendererWorkerQualificationCrashRequest.decode(exactBytes)) != nil else {
            acknowledgement(false, 0)
            return
        }
        connectionInterruptionRelay.install(interrupted)
        let once = ReplyOnce()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            // A crash can overtake its ACK. Without that ACK, qualification remains unproven;
            // do not invent an acceptance or treat proxy failure as a confirmed SIGKILL.
        }) as? DoryRendererWorkerXPCProtocol else {
            acknowledgement(false, 0)
            return
        }
        proxy.qualificationCrash(exactBytes) { accepted, count in
            guard once.claim() else { return }
            acknowledgement(accepted, count)
        }
    }

    private var isActive: Bool {
        stateLock.withLock {
            if case .active = state { return true }
            return false
        }
    }

    private func observeAuthenticatedPeerExit(_ registered: @escaping @Sendable () -> Void) -> Bool {
        let processIdentifier = connection.processIdentifier
        guard processIdentifier > 0 else { return false }
        let monitor = stateLock.withLock { () -> DoryRendererWorkerProcessExitMonitor? in
            guard case .active = state, peerExitMonitor == nil, exitedPeer == nil else { return nil }
            let monitor = DoryRendererWorkerProcessExitMonitor(
                processIdentifier: processIdentifier, queue: peerExitQueue,
                exited: { [weak self] in self?.authenticatedPeerExited(processIdentifier) })
            peerExitMonitor = monitor
            return monitor
        }
        guard let monitor else { return false }
        monitor.start(registered: registered)
        return true
    }

    private func completeBootstrapRegistration(_ identity: UUID, forceFailure: Bool = false) {
        let delivery = stateLock.withLock { () -> ((@Sendable (Bool) -> Void), Bool)? in
            guard let finish = pendingBootstrapRegistrations.removeValue(forKey: identity) else { return nil }
            if case .active = state { return (finish, !forceFailure) }
            return (finish, false)
        }
        if let delivery { delivery.0(delivery.1) }
    }

    private func authenticatedPeerExited(_ processIdentifier: Int32) {
        let delivery = stateLock.withLock { () -> [@Sendable (Int32) -> Void] in
            guard exitedPeer == nil else { return [] }
            exitedPeer = processIdentifier
            peerExitMonitor = nil
            let handlers = retirementHandlers
            retirementHandlers.removeAll(keepingCapacity: false)
            return handlers
        }
        for handler in delivery { handler(processIdentifier) }
    }

    private func transition(to requested: State) {
        let delivery: (
            handlers: [@Sendable (DoryRendererWorkerChannelEvent) -> Void],
            bootstrapRegistrations: [@Sendable (Bool) -> Void],
            event: DoryRendererWorkerChannelEvent
        )? = stateLock.withLock {
            guard case .active = state else { return nil }
            state = requested
            let handlers = lifecycleHandlers
            lifecycleHandlers.removeAll(keepingCapacity: false)
            let registrations = Array(pendingBootstrapRegistrations.values)
            pendingBootstrapRegistrations.removeAll(keepingCapacity: false)
            switch requested {
            case .active:
                return nil
            case .interrupted:
                return (handlers, registrations, .interrupted)
            case .invalidated:
                return (handlers, registrations, .invalidated)
            }
        }
        guard let delivery else { return }
        for finish in delivery.bootstrapRegistrations { finish(false) }
        for handler in delivery.handlers { handler(delivery.event) }
    }

    private static func close(_ descriptors: [FileHandle]) {
        for descriptor in descriptors { try? descriptor.close() }
    }
}
