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
            Result<Data, DoryRendererWorkerChannelFailure>
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

    public init(codeDirectoryHash: DoryCodeDirectoryHash) {
        connection = NSXPCConnection(serviceName: DoryRendererWorkerIdentity.serviceName)
        super.init()
        connection.remoteObjectInterface = DoryRendererWorkerXPCInterface.make()
        connection.interruptionHandler = { [weak self] in
            self?.transition(to: .interrupted)
        }
        connection.invalidationHandler = { [weak self] in
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

    public func bootstrap(
        exactBytes: Data,
        completion: @escaping @Sendable (
            Result<Data, DoryRendererWorkerChannelFailure>
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
        proxy.bootstrap(exactBytes) { [weak self] bytes in
            guard once.claim() else { return }
            do {
                switch try DoryRendererWorkerRPCResultCodec.decode(bytes) {
                case let .success(payload, descriptorCount):
                    guard descriptorCount == 0 else {
                        completion(.failure(.descriptorCountMismatch(
                            expected: 0,
                            actual: Int(descriptorCount)
                        )))
                        self?.invalidate()
                        return
                    }
                    completion(.success(payload))
                case .failure(let code):
                    completion(.failure(.serviceFailure(code)))
                }
            } catch let error as DoryRendererWorkerContractError {
                completion(.failure(.malformedResult(error)))
                self?.invalidate()
            } catch {
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
        transition(to: .invalidated)
        connection.invalidate()
    }

    private var isActive: Bool {
        stateLock.withLock {
            if case .active = state { return true }
            return false
        }
    }

    private func transition(to requested: State) {
        let delivery: (
            handlers: [@Sendable (DoryRendererWorkerChannelEvent) -> Void],
            event: DoryRendererWorkerChannelEvent
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
        guard let delivery else { return }
        for handler in delivery.handlers { handler(delivery.event) }
    }

    private static func close(_ descriptors: [FileHandle]) {
        for descriptor in descriptors { try? descriptor.close() }
    }
}
