import Darwin
import DoryVMContracts
import Foundation

/// Serves the engine's USB control protocol on a unix socket. The engine owns the device claim, the
/// UsbipManager, and the guest agent channel. One request is accepted per connection.
public final class UsbControlServer: @unchecked Sendable {
    private static let endpointMutationLock = NSLock()
    private static let productionMaximumSessions = 8
    private static let maximumConfiguredSessions = 64
    private static let maximumConfiguredTimeout: TimeInterval = 30

    private let path: String
    private let handler: UsbControlHandler
    private let lock = NSLock()
    private let maximumSessions: Int
    private let frameTimeout: TimeInterval
    private let expectedPeerUID: uid_t
    private let peerUIDResolver: @Sendable (Int32) -> uid_t?
    private let beforeStaleEndpointUnlinkValidation: @Sendable () throws -> Void
    private let afterListenerBindValidation: @Sendable () throws -> Void
    private let log: @Sendable (String) -> Void
    private var currentRun: UsbControlServerRun?

    public convenience init(path: String, handler: UsbControlHandler) {
        self.init(
            path: path,
            handler: handler,
            maximumSessions: Self.productionMaximumSessions,
            frameTimeout: 5,
            expectedPeerUID: geteuid(),
            peerUIDResolver: UsbControlSocketIO.peerUID,
            beforeStaleEndpointUnlinkValidation: {},
            afterListenerBindValidation: {},
            log: { NSLog("%@", $0) }
        )
    }

    init(
        path: String,
        handler: UsbControlHandler,
        maximumSessions: Int,
        frameTimeout: TimeInterval,
        expectedPeerUID: uid_t,
        peerUIDResolver: @escaping @Sendable (Int32) -> uid_t?,
        beforeStaleEndpointUnlinkValidation: @escaping @Sendable () throws -> Void = {},
        afterListenerBindValidation: @escaping @Sendable () throws -> Void = {},
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        precondition((1...Self.maximumConfiguredSessions).contains(maximumSessions))
        precondition(
            frameTimeout.isFinite
                && frameTimeout > 0
                && frameTimeout <= Self.maximumConfiguredTimeout
        )
        self.path = path
        self.handler = handler
        self.maximumSessions = maximumSessions
        self.frameTimeout = frameTimeout
        self.expectedPeerUID = expectedPeerUID
        self.peerUIDResolver = peerUIDResolver
        self.beforeStaleEndpointUnlinkValidation = beforeStaleEndpointUnlinkValidation
        self.afterListenerBindValidation = afterListenerBindValidation
        self.log = log
    }

    public func start() throws {
        lock.lock()
        guard currentRun == nil else {
            lock.unlock()
            throw UsbControlServerError.alreadyStarted
        }
        let owned: UsbControlOwnedListener
        do {
            owned = try Self.makeOwnedListener(
                path: path,
                expectedUID: geteuid(),
                beforeStaleEndpointUnlinkValidation: beforeStaleEndpointUnlinkValidation,
                afterListenerBindValidation: afterListenerBindValidation
            )
        } catch {
            lock.unlock()
            throw error
        }
        let run = UsbControlServerRun(
            listener: owned,
            maximumSessions: maximumSessions,
            handler: handler,
            frameTimeout: frameTimeout,
            expectedPeerUID: expectedPeerUID,
            peerUIDResolver: peerUIDResolver,
            log: log
        )
        currentRun = run
        lock.unlock()
        Thread.detachNewThread { [path, log] in
            Self.acceptLoop(run: run, path: path, log: log)
        }
    }

    /// Stop never closes the listener or a client from the calling thread. It only issues shutdown
    /// to wake their owner threads, then waits to the supplied absolute bound.
    @discardableResult
    public func stop(timeout: TimeInterval = 5) -> Bool {
        lock.lock()
        guard let run = currentRun else {
            lock.unlock()
            return true
        }
        lock.unlock()
        run.requestStop()
        let bounded = timeout.isFinite
            ? min(max(0, timeout), Self.maximumConfiguredTimeout)
            : 5
        let drained = run.waitUntilDrained(timeout: bounded)
        if drained {
            lock.lock()
            if currentRun === run { currentRun = nil }
            lock.unlock()
        } else {
            log("USB control server did not drain within \(bounded) seconds")
        }
        return drained
    }

    var activeSessionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return currentRun?.activeSessionCount ?? 0
    }

    var rejectedSessionCount: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return currentRun?.rejectedSessionCount ?? 0
    }

    deinit {
        _ = stop()
    }

    private static func acceptLoop(
        run: UsbControlServerRun,
        path: String,
        log: @escaping @Sendable (String) -> Void
    ) {
        let descriptor = run.listener.descriptor
        defer {
            endpointMutationLock.lock()
            retireEndpointIfOwned(
                path: path,
                identity: run.listener.identity,
                parentIdentity: run.listener.parentIdentity
            )
            // The listener worker is the sole close owner. The lifetime object serializes this
            // close with stop's shutdown so a reused descriptor can never be targeted.
            run.listenerOwnerDidFinish()
            endpointMutationLock.unlock()
        }
        while true {
            if run.isStopping { return }
            var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let result = poll(&readiness, 1, 100)
            if result == 0 { continue }
            if result < 0 {
                if errno == EINTR { continue }
                if !run.isStopping { log("USB control listener poll failed: errno \(errno)") }
                return
            }
            if readiness.revents & Int16(POLLNVAL) != 0 {
                if !run.isStopping { log("USB control listener became invalid") }
                return
            }
            if readiness.revents & Int16(POLLIN) == 0 {
                if run.isStopping { return }
                continue
            }
            while true {
                let client = accept(descriptor, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    if !run.isStopping { log("USB control accept failed: errno \(errno)") }
                    return
                }
                guard UsbControlSocketIO.configureOwnedSocket(client, nonBlocking: true) else {
                    let code = errno
                    close(client)
                    log("USB control accepted socket setup failed: errno \(code)")
                    continue
                }
                if !run.admit(client) { close(client) }
            }
        }
    }

    private static func makeOwnedListener(
        path: String,
        expectedUID: uid_t,
        beforeStaleEndpointUnlinkValidation: @Sendable () throws -> Void,
        afterListenerBindValidation: @Sendable () throws -> Void
    ) throws -> UsbControlOwnedListener {
        try UsbControlSocketIO.validateAbsolutePath(path)
        endpointMutationLock.lock()
        defer { endpointMutationLock.unlock() }
        let parent = try UsbControlSocketIO.privateParentIdentity(
            forEndpointPath: path,
            expectedUID: expectedUID
        )

        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard existing.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
                  existing.st_uid == expectedUID else {
                throw UsbControlServerError.untrustedEndpoint(path)
            }
            let initialIdentity = UsbControlSocketIO.endpointIdentity(existing)
            guard !UsbControlSocketIO.endpointAcceptsConnections(path) else {
                throw UsbControlServerError.endpointInUse(path)
            }
            try beforeStaleEndpointUnlinkValidation()
            guard UsbControlSocketIO.privateDirectoryIdentity(parent.path) == parent.identity,
                  UsbControlSocketIO.endpointIdentity(path) == initialIdentity else {
                throw UsbControlServerError.untrustedEndpoint(path)
            }
            guard unlink(path) == 0 else {
                throw UsbControlServerError.systemCall(
                    operation: "remove stale USB control socket",
                    code: errno
                )
            }
        } else if errno != ENOENT {
            throw UsbControlServerError.systemCall(
                operation: "inspect USB control socket",
                code: errno
            )
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw UsbControlServerError.systemCall(operation: "create USB control socket", code: errno)
        }
        var publishedIdentity: UsbControlEndpointIdentity?
        do {
            guard UsbControlSocketIO.configureOwnedSocket(descriptor, nonBlocking: true) else {
                throw UsbControlServerError.systemCall(
                    operation: "configure USB control listener",
                    code: errno
                )
            }
            var address = try UsbControlSocketIO.address(for: path)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard bound == 0 else {
                throw UsbControlServerError.systemCall(operation: "bind USB control socket", code: errno)
            }
            guard let identity = UsbControlSocketIO.endpointIdentity(path),
                  identity.owner == expectedUID else {
                throw UsbControlServerError.untrustedEndpoint(path)
            }
            publishedIdentity = identity
            try afterListenerBindValidation()
            guard UsbControlSocketIO.privateDirectoryIdentity(parent.path) == parent.identity else {
                throw UsbControlServerError.untrustedParentDirectory(parent.path)
            }
            guard chmod(path, 0o600) == 0 else {
                throw UsbControlServerError.systemCall(operation: "chmod USB control socket", code: errno)
            }
            guard Darwin.listen(descriptor, Int32(maximumConfiguredSessions)) == 0 else {
                throw UsbControlServerError.systemCall(operation: "listen on USB control socket", code: errno)
            }
            guard UsbControlSocketIO.privateDirectoryIdentity(parent.path) == parent.identity,
                  UsbControlSocketIO.endpointIdentity(path) == identity else {
                throw UsbControlServerError.untrustedEndpoint(path)
            }
            return UsbControlOwnedListener(
                descriptor: descriptor,
                identity: identity,
                parentIdentity: parent.identity
            )
        } catch {
            if let publishedIdentity {
                retireEndpointIfOwned(
                    path: path,
                    identity: publishedIdentity,
                    parentIdentity: parent.identity
                )
            }
            close(descriptor)
            throw error
        }
    }

    private static func retireEndpointIfOwned(
        path: String,
        identity: UsbControlEndpointIdentity,
        parentIdentity: UsbControlDirectoryIdentity
    ) {
        let parentPath = (path as NSString).deletingLastPathComponent
        guard UsbControlSocketIO.privateDirectoryIdentity(parentPath) == parentIdentity,
              UsbControlSocketIO.endpointIdentity(path) == identity else { return }
        _ = unlink(path)
    }
}

public enum UsbControlServerError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidPath(String)
    case untrustedParentDirectory(String)
    case untrustedEndpoint(String)
    case endpointInUse(String)
    case alreadyStarted
    case frameTooLarge(limit: Int)
    case incompleteFrame
    case unexpectedTrailingBytes
    case timedOut(operation: String)
    case peerIdentity(expected: uid_t, actual: uid_t?)
    case systemCall(operation: String, code: Int32)

    public var description: String {
        switch self {
        case .invalidPath(let path): return "invalid absolute USB control socket path: \(path)"
        case .untrustedParentDirectory(let path):
            return "USB control socket parent is not an owner-private stable directory: \(path)"
        case .untrustedEndpoint(let path): return "refusing untrusted USB control endpoint: \(path)"
        case .endpointInUse(let path): return "USB control endpoint is already active: \(path)"
        case .alreadyStarted: return "USB control server is already started"
        case .frameTooLarge(let limit): return "USB control frame exceeds \(limit) bytes"
        case .incompleteFrame: return "USB control frame ended without a newline"
        case .unexpectedTrailingBytes: return "USB control frame contains bytes after its newline"
        case .timedOut(let operation): return "USB control \(operation) timed out"
        case let .peerIdentity(expected, actual):
            return "USB control peer UID mismatch (expected \(expected), got \(actual.map(String.init) ?? "unknown"))"
        case let .systemCall(operation, code):
            return "\(operation) failed: errno \(code) (\(String(cString: strerror(code))))"
        }
    }
}

private struct UsbControlEndpointIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let generation: UInt32
    let birthSeconds: Int64
    let birthNanoseconds: Int64
    let owner: uid_t
}

private struct UsbControlDirectoryIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let generation: UInt32
    let birthSeconds: Int64
    let birthNanoseconds: Int64
    let owner: uid_t
    let permissions: mode_t
}

private struct UsbControlOwnedListener: Sendable {
    let descriptor: Int32
    let identity: UsbControlEndpointIdentity
    let parentIdentity: UsbControlDirectoryIdentity
}

/// Serializes cancellation shutdown with the sole owner's final close. The descriptor value is
/// never used outside this lease for either operation, preventing shutdown-after-close FD reuse.
final class UsbControlDescriptorLifetime: @unchecked Sendable {
    typealias DescriptorOperation = @Sendable (Int32) -> Void

    private let lock = NSLock()
    private var descriptor: Int32?
    private let shutdownOperation: DescriptorOperation
    private let closeOperation: DescriptorOperation

    init(
        descriptor: Int32,
        shutdownOperation: @escaping DescriptorOperation = {
            _ = Darwin.shutdown($0, SHUT_RDWR)
        },
        closeOperation: @escaping DescriptorOperation = { _ = Darwin.close($0) }
    ) {
        self.descriptor = descriptor
        self.shutdownOperation = shutdownOperation
        self.closeOperation = closeOperation
    }

    /// A worker may borrow the stable value while it remains the sole close owner.
    var borrowedDescriptor: Int32? {
        lock.lock(); defer { lock.unlock() }
        return descriptor
    }

    func requestShutdown() {
        lock.lock()
        if let descriptor { shutdownOperation(descriptor) }
        lock.unlock()
    }

    func closeByOwner() {
        lock.lock()
        guard let descriptor else {
            lock.unlock()
            return
        }
        self.descriptor = nil
        closeOperation(descriptor)
        lock.unlock()
    }
}

private final class UsbControlServerRun: @unchecked Sendable {
    let listener: UsbControlOwnedListener

    private let condition = NSCondition()
    private let maximumSessions: Int
    private let handler: UsbControlHandler
    private let frameTimeout: TimeInterval
    private let expectedPeerUID: uid_t
    private let peerUIDResolver: @Sendable (Int32) -> uid_t?
    private let log: @Sendable (String) -> Void
    private let listenerDescriptorLifetime: UsbControlDescriptorLifetime
    private var sessions: [UUID: UsbControlServerSession] = [:]
    private var stopping = false
    private var listenerFinished = false
    private var rejectedSessions: UInt64 = 0

    init(
        listener: UsbControlOwnedListener,
        maximumSessions: Int,
        handler: UsbControlHandler,
        frameTimeout: TimeInterval,
        expectedPeerUID: uid_t,
        peerUIDResolver: @escaping @Sendable (Int32) -> uid_t?,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.listener = listener
        self.maximumSessions = maximumSessions
        self.handler = handler
        self.frameTimeout = frameTimeout
        self.expectedPeerUID = expectedPeerUID
        self.peerUIDResolver = peerUIDResolver
        self.log = log
        self.listenerDescriptorLifetime = UsbControlDescriptorLifetime(
            descriptor: listener.descriptor
        )
    }

    var isStopping: Bool {
        condition.lock(); defer { condition.unlock() }
        return stopping
    }

    var activeSessionCount: Int {
        condition.lock(); defer { condition.unlock() }
        return sessions.count
    }

    var rejectedSessionCount: UInt64 {
        condition.lock(); defer { condition.unlock() }
        return rejectedSessions
    }

    /// Returns false without taking ownership; the listener thread must close rejected descriptors.
    func admit(_ descriptor: Int32) -> Bool {
        condition.lock()
        guard !stopping, sessions.count < maximumSessions else {
            if rejectedSessions < UInt64.max { rejectedSessions += 1 }
            condition.unlock()
            return false
        }
        let token = UUID()
        let session = UsbControlServerSession(
            descriptor: descriptor,
            handler: handler,
            frameTimeout: frameTimeout,
            expectedPeerUID: expectedPeerUID,
            peerUIDResolver: peerUIDResolver,
            log: log,
            completion: { [weak self] in self?.sessionFinished(token) }
        )
        sessions[token] = session
        condition.unlock()
        Thread.detachNewThread { session.run() }
        return true
    }

    func requestStop() {
        condition.lock()
        if stopping {
            condition.unlock()
            return
        }
        stopping = true
        let active = Array(sessions.values)
        condition.broadcast()
        condition.unlock()

        // Keep descriptors allocated; shutdown only wakes the threads that remain sole close owners.
        listenerDescriptorLifetime.requestShutdown()
        for session in active { session.requestStop() }
    }

    func listenerOwnerDidFinish() {
        condition.lock()
        listenerDescriptorLifetime.closeByOwner()
        listenerFinished = true
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilDrained(timeout: TimeInterval) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        condition.lock()
        defer { condition.unlock() }
        while !listenerFinished || !sessions.isEmpty {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            _ = condition.wait(until: Date().addingTimeInterval(min(remaining, 0.05)))
        }
        return true
    }

    private func sessionFinished(_ token: UUID) {
        condition.lock()
        sessions.removeValue(forKey: token)
        condition.broadcast()
        condition.unlock()
    }
}

private final class UsbControlServerSession: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: UsbControlHandler
    private let frameTimeout: TimeInterval
    private let expectedPeerUID: uid_t
    private let peerUIDResolver: @Sendable (Int32) -> uid_t?
    private let log: @Sendable (String) -> Void
    private let descriptorLifetime: UsbControlDescriptorLifetime
    private var completion: (@Sendable () -> Void)?
    private var started = false
    private var stopRequested = false
    private var finished = false

    init(
        descriptor: Int32,
        handler: UsbControlHandler,
        frameTimeout: TimeInterval,
        expectedPeerUID: uid_t,
        peerUIDResolver: @escaping @Sendable (Int32) -> uid_t?,
        log: @escaping @Sendable (String) -> Void,
        completion: @escaping @Sendable () -> Void
    ) {
        self.descriptorLifetime = UsbControlDescriptorLifetime(descriptor: descriptor)
        self.handler = handler
        self.frameTimeout = frameTimeout
        self.expectedPeerUID = expectedPeerUID
        self.peerUIDResolver = peerUIDResolver
        self.log = log
        self.completion = completion
    }

    func run() {
        lock.lock()
        guard !started, let descriptor = descriptorLifetime.borrowedDescriptor else {
            lock.unlock()
            return
        }
        started = true
        let shouldRun = !stopRequested
        lock.unlock()
        guard shouldRun else {
            finish()
            return
        }
        defer { finish() }

        let actualUID = peerUIDResolver(descriptor)
        guard actualUID == expectedPeerUID else {
            log(UsbControlServerError.peerIdentity(expected: expectedPeerUID, actual: actualUID).description)
            return
        }

        let request: DoryUSBControlV1.Request
        do {
            let deadline = ProcessInfo.processInfo.systemUptime + frameTimeout
            let frame = try UsbControlSocketIO.readFrame(
                descriptor: descriptor,
                deadline: deadline
            )
            request = try DoryUSBControlV1.decodeRequest(frame)
        } catch {
            guard !isStopping else { return }
            writeFailure(
                "malformed control request: \(error)",
                disposition: .rejected,
                descriptor: descriptor
            )
            return
        }

        let result = UsbControlAsyncResult()
        let handler = self.handler
        // Reserve the mutation while holding the same lock used by requestStop. If stop wins first,
        // no new hardware/RPC operation starts; if this reservation wins, stop continues tracking
        // the session until the exact result arrives.
        lock.lock()
        guard !stopRequested, !finished else {
            lock.unlock()
            return
        }
        let operation = Task {
            let response: DoryUSBControlV1.Response
            do {
                switch request {
                case let .attach(busID, mode):
                    response = .attachSuccess(
                        try await handler.attach(
                            busID: busID.rawValue,
                            mode: Self.hostOpenMode(mode)
                        )
                    )
                case let .detach(busID):
                    try await handler.detach(busID: busID.rawValue)
                    response = .detachSuccess
                }
            } catch {
                let disposition = (error as? UsbControlError)?.failureDisposition ?? .rejected
                response = .failure(
                    disposition: disposition,
                    error: DoryUSBControlV1.sanitizedFailureMessage(String(describing: error))
                )
            }
            result.complete(response)
        }
        lock.unlock()

        // Deliberately no server-side operation timeout: the injected guest/hardware operations are
        // not generally cancellable. The session remains tracked until their exact result arrives.
        let response = withExtendedLifetime(operation) { result.wait() }
        lock.lock()
        let shouldReply = !stopRequested
        lock.unlock()
        guard shouldReply else { return }
        do {
            var payload = try DoryUSBControlV1.encodeResponse(response)
            payload.append(0x0a)
            try UsbControlSocketIO.writeAll(
                descriptor: descriptor,
                bytes: payload,
                deadline: ProcessInfo.processInfo.systemUptime + frameTimeout
            )
        } catch {
            if !isStopping { log("USB control response write failed: \(error)") }
        }
    }

    func requestStop() {
        lock.lock()
        guard !stopRequested, !finished else {
            lock.unlock()
            return
        }
        stopRequested = true
        lock.unlock()
        descriptorLifetime.requestShutdown()
    }

    private var isStopping: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopRequested || finished
    }

    private func writeFailure(
        _ message: String,
        disposition: DoryUSBControlV1.FailureDisposition,
        descriptor: Int32
    ) {
        do {
            var payload = try DoryUSBControlV1.encodeResponse(.failure(
                disposition: disposition,
                error: DoryUSBControlV1.sanitizedFailureMessage(message)
            ))
            payload.append(0x0a)
            try UsbControlSocketIO.writeAll(
                descriptor: descriptor,
                bytes: payload,
                deadline: ProcessInfo.processInfo.systemUptime + frameTimeout
            )
        } catch {
            log("USB control error response write failed: \(error)")
        }
    }

    private static func hostOpenMode(_ mode: DoryUSBControlV1.OpenMode) -> HostUsbOpenMode {
        switch mode {
        case .userAuthorized: .userAuthorized
        case .seize: .seize
        case .capture: .capture
        }
    }

    private func finish() {
        let callback: (@Sendable () -> Void)?
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        callback = completion
        completion = nil
        descriptorLifetime.closeByOwner()
        lock.unlock()
        callback?()
    }
}

private final class UsbControlAsyncResult: @unchecked Sendable {
    private let condition = NSCondition()
    private var response: DoryUSBControlV1.Response?

    func complete(_ response: DoryUSBControlV1.Response) {
        condition.lock()
        guard self.response == nil else {
            condition.unlock()
            return
        }
        self.response = response
        condition.broadcast()
        condition.unlock()
    }

    func wait() -> DoryUSBControlV1.Response {
        condition.lock()
        while true {
            if let response {
                condition.unlock()
                return response
            }
            condition.wait()
        }
    }
}

enum UsbControlSocketIO {
    static let maximumFrameBytes = DoryUSBControlV1.maximumFrameBytes
    typealias ReadOperation = (Int32, UnsafeMutableRawPointer?, Int) -> Int
    typealias WriteOperation = (Int32, UnsafeRawPointer?, Int) -> Int

    static var maximumSocketPathBytes: Int {
        let address = sockaddr_un()
        return MemoryLayout.size(ofValue: address.sun_path) - 1
    }

    static func validateAbsolutePath(_ path: String) throws {
        let bytes = Array(path.utf8)
        let standardized = (path as NSString).standardizingPath
        guard path.hasPrefix("/"), path == standardized,
              (path as NSString).lastPathComponent.isEmpty == false,
              !bytes.isEmpty, !bytes.contains(0),
              bytes.count <= maximumSocketPathBytes else {
            throw UsbControlServerError.invalidPath(path)
        }
    }

    fileprivate static func privateParentIdentity(
        forEndpointPath path: String,
        expectedUID: uid_t
    ) throws -> (path: String, identity: UsbControlDirectoryIdentity) {
        let parentPath = (path as NSString).deletingLastPathComponent
        guard let identity = privateDirectoryIdentity(parentPath),
              identity.owner == expectedUID,
              identity.permissions & 0o077 == 0,
              identity.permissions & 0o300 == 0o300 else {
            throw UsbControlServerError.untrustedParentDirectory(parentPath)
        }
        return (parentPath, identity)
    }

    static func address(for path: String) throws -> sockaddr_un {
        try validateAbsolutePath(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                destination.baseAddress!.copyMemory(
                    from: source.baseAddress!,
                    byteCount: bytes.count
                )
            }
        }
        return address
    }

    static func configureOwnedSocket(_ descriptor: Int32, nonBlocking: Bool) -> Bool {
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0,
              fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
            return false
        }
        var noSigpipe: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigpipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else { return false }
        guard nonBlocking else { return true }
        let statusFlags = fcntl(descriptor, F_GETFL)
        return statusFlags >= 0
            && fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) == 0
    }

    static func peerUID(_ descriptor: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(descriptor, &uid, &gid) == 0 ? uid : nil
    }

    fileprivate static func endpointIdentity(_ path: String) -> UsbControlEndpointIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else { return nil }
        return endpointIdentity(info)
    }

    fileprivate static func endpointIdentity(_ info: stat) -> UsbControlEndpointIdentity {
        return UsbControlEndpointIdentity(
            device: info.st_dev,
            inode: info.st_ino,
            generation: info.st_gen,
            birthSeconds: Int64(info.st_birthtimespec.tv_sec),
            birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec),
            owner: info.st_uid
        )
    }

    fileprivate static func privateDirectoryIdentity(
        _ path: String
    ) -> UsbControlDirectoryIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return nil }
        return UsbControlDirectoryIdentity(
            device: info.st_dev,
            inode: info.st_ino,
            generation: info.st_gen,
            birthSeconds: Int64(info.st_birthtimespec.tv_sec),
            birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec),
            owner: info.st_uid,
            permissions: info.st_mode & 0o777
        )
    }

    /// Fail safe: only ECONNREFUSED/ENOENT proves an owner-private socket is stale enough to remove.
    static func endpointAcceptsConnections(_ path: String) -> Bool {
        guard let address = try? address(for: path) else { return true }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return true }
        defer { close(descriptor) }
        guard configureOwnedSocket(descriptor, nonBlocking: true) else { return true }
        var mutableAddress = address
        let result = withUnsafePointer(to: &mutableAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return true }
        let code = errno
        if code == ECONNREFUSED || code == ENOENT { return false }
        guard code == EINPROGRESS || code == EAGAIN else { return true }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.1
        do {
            try wait(
                descriptor: descriptor,
                events: Int16(POLLOUT),
                deadline: deadline,
                operation: "probe endpoint"
            )
        } catch {
            return true
        }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(
            descriptor,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &length
        ) == 0 else { return true }
        return socketError != ECONNREFUSED && socketError != ENOENT
    }

    static func readFrame(
        descriptor: Int32,
        deadline: TimeInterval
    ) throws -> Data {
        try readFrame(
            descriptor: descriptor,
            deadline: deadline,
            readOperation: { Darwin.read($0, $1, $2) }
        )
    }

    static func readFrame(
        descriptor: Int32,
        deadline: TimeInterval,
        readOperation: ReadOperation
    ) throws -> Data {
        var frame = Data()
        var buffer = [UInt8](repeating: 0, count: 4 * 1024)
        while true {
            try requireTimeRemaining(deadline: deadline, operation: "request frame")
            let remainingCapacity = maximumFrameBytes - frame.count + 1
            guard remainingCapacity > 0 else {
                throw UsbControlServerError.frameTooLarge(limit: maximumFrameBytes)
            }
            let requested = min(buffer.count, remainingCapacity)
            let count = buffer.withUnsafeMutableBytes {
                readOperation(descriptor, $0.baseAddress, requested)
            }
            try requireTimeRemaining(deadline: deadline, operation: "request frame")
            if count > 0 {
                guard count <= requested else {
                    throw UsbControlServerError.systemCall(operation: "read USB control frame", code: EIO)
                }
                let bytes = buffer[0..<count]
                if let newline = bytes.firstIndex(of: 0x0a) {
                    guard newline == bytes.index(before: bytes.endIndex) else {
                        throw UsbControlServerError.unexpectedTrailingBytes
                    }
                    frame.append(contentsOf: bytes[..<newline])
                    guard frame.count <= maximumFrameBytes else {
                        throw UsbControlServerError.frameTooLarge(limit: maximumFrameBytes)
                    }
                    return frame
                }
                frame.append(contentsOf: bytes)
                guard frame.count <= maximumFrameBytes else {
                    throw UsbControlServerError.frameTooLarge(limit: maximumFrameBytes)
                }
                continue
            }
            if count == 0 { throw UsbControlServerError.incompleteFrame }
            let code = errno
            if code == EINTR { continue }
            if code == EAGAIN || code == EWOULDBLOCK {
                try wait(
                    descriptor: descriptor,
                    events: Int16(POLLIN),
                    deadline: deadline,
                    operation: "request frame"
                )
                continue
            }
            throw UsbControlServerError.systemCall(operation: "read USB control frame", code: code)
        }
    }

    static func writeAll(
        descriptor: Int32,
        bytes: Data,
        deadline: TimeInterval
    ) throws {
        try writeAll(
            descriptor: descriptor,
            bytes: bytes,
            deadline: deadline,
            writeOperation: { Darwin.write($0, $1, $2) }
        )
    }

    static func writeAll(
        descriptor: Int32,
        bytes: Data,
        deadline: TimeInterval,
        writeOperation: WriteOperation
    ) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try requireTimeRemaining(deadline: deadline, operation: "response frame")
                let count = writeOperation(
                    descriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    buffer.count - offset
                )
                try requireTimeRemaining(deadline: deadline, operation: "response frame")
                if count > 0 {
                    guard count <= buffer.count - offset else {
                        throw UsbControlServerError.systemCall(
                            operation: "write USB control frame",
                            code: EIO
                        )
                    }
                    offset += count
                    continue
                }
                if count == 0 {
                    throw UsbControlServerError.systemCall(
                        operation: "write USB control frame",
                        code: EPIPE
                    )
                }
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK {
                    try wait(
                        descriptor: descriptor,
                        events: Int16(POLLOUT),
                        deadline: deadline,
                        operation: "response frame"
                    )
                    continue
                }
                throw UsbControlServerError.systemCall(
                    operation: "write USB control frame",
                    code: code
                )
            }
        }
    }

    static func wait(
        descriptor: Int32,
        events: Int16,
        deadline: TimeInterval,
        operation: String
    ) throws {
        while true {
            let remaining = try requireTimeRemaining(deadline: deadline, operation: operation)
            var readiness = pollfd(fd: descriptor, events: events, revents: 0)
            let milliseconds = max(1, min(50, Int32(ceil(remaining * 1_000))))
            let result = poll(&readiness, 1, milliseconds)
            if result == 0 { continue }
            if result < 0 {
                if errno == EINTR { continue }
                throw UsbControlServerError.systemCall(operation: "poll USB control socket", code: errno)
            }
            if readiness.revents & Int16(POLLNVAL) != 0 {
                throw UsbControlServerError.systemCall(operation: "poll USB control socket", code: EBADF)
            }
            return
        }
    }

    @discardableResult
    private static func requireTimeRemaining(
        deadline: TimeInterval,
        operation: String
    ) throws -> TimeInterval {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else {
            throw UsbControlServerError.timedOut(operation: operation)
        }
        return remaining
    }
}
