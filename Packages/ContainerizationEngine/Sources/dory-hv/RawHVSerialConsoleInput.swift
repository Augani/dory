import Darwin
import DoryHV
import Foundation

enum RawHVSerialConsoleInputError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidConfiguration(String)
    case invalidSocketPath(String)
    case untrustedSocketPath(String)
    case systemCall(operation: String, path: String, code: Int32)

    var description: String {
        switch self {
        case .invalidConfiguration(let detail):
            return "invalid raw-HV serial console configuration: \(detail)"
        case .invalidSocketPath(let detail):
            return "invalid raw-HV serial console socket path: \(detail)"
        case .untrustedSocketPath(let detail):
            return "untrusted raw-HV serial console socket path: \(detail)"
        case let .systemCall(operation, path, code):
            return "could not \(operation) raw-HV serial console socket \(path): "
                + "errno \(code) (\(String(cString: strerror(code))))"
        }
    }
}

/// Private Unix-socket input side of raw-HV's durable serial console.
///
/// Output continues to flow directly into `serial.log`. Each admitted client writes one frame and
/// half-closes its write side. The complete frame is bounded and deadline-governed before any byte
/// reaches the UART, so a slow, oversized, or abandoned peer cannot partially inject a command or
/// retain an admission slot indefinitely.
final class RawHVSerialConsoleInput: @unchecked Sendable {
    struct Metrics: Equatable, Sendable {
        var activeClientCount = 0
        var acceptedFrameCount: UInt64 = 0
        var acceptedByteCount: UInt64 = 0
        var rejectedPeerCount: UInt64 = 0
        var rejectedCapacityCount: UInt64 = 0
        var rejectedEmptyFrameCount: UInt64 = 0
        var rejectedOversizedFrameCount: UInt64 = 0
        var timedOutFrameCount: UInt64 = 0
        var uartBackpressureCount: UInt64 = 0
        var clientIOFailureCount: UInt64 = 0
        var listenerFailureCount: UInt64 = 0
    }

    /// Deterministic lifecycle observation points for race regression tests. Production uses the
    /// no-op defaults; callbacks never make ownership decisions or replace the lifetime lock.
    struct LifecycleHooks: Sendable {
        var beforeListenerShutdown: @Sendable () -> Void
        var beforeListenerRetire: @Sendable () -> Void

        init(
            beforeListenerShutdown: @escaping @Sendable () -> Void = {},
            beforeListenerRetire: @escaping @Sendable () -> Void = {}
        ) {
            self.beforeListenerShutdown = beforeListenerShutdown
            self.beforeListenerRetire = beforeListenerRetire
        }
    }

    static let productionMaximumFrameBytes = 4 * 1_024
    static let productionMaximumConcurrentClients = 8
    static let productionFrameTimeout: TimeInterval = 1

    private static let maximumConfiguredFrameBytes = 64 * 1_024
    private static let maximumConfiguredClients = 64
    private static let maximumConfiguredTimeout: TimeInterval = 60
    private static let maximumStopWait: TimeInterval = 5
    private static let listenerPollMilliseconds: Int32 = 100
    private static let socketPathMutationLock = NSLock()

    private let lifetime: Lifetime

    init(
        socketPath: String,
        uart: PL011,
        maximumConcurrentClients: Int = productionMaximumConcurrentClients,
        maximumFrameBytes: Int = productionMaximumFrameBytes,
        frameTimeout: TimeInterval = productionFrameTimeout,
        expectedPeerUID: uid_t = geteuid(),
        lifecycleHooks: LifecycleHooks = LifecycleHooks(),
        log: @escaping @Sendable (String) -> Void = { message in
            FileHandle.standardError.write(
                Data("dory-hv desktop serial console: \(message)\n".utf8)
            )
        }
    ) throws {
        guard (1...Self.maximumConfiguredClients).contains(maximumConcurrentClients) else {
            throw RawHVSerialConsoleInputError.invalidConfiguration(
                "maximumConcurrentClients must be in 1...\(Self.maximumConfiguredClients)"
            )
        }
        guard (1...Self.maximumConfiguredFrameBytes).contains(maximumFrameBytes) else {
            throw RawHVSerialConsoleInputError.invalidConfiguration(
                "maximumFrameBytes must be in 1...\(Self.maximumConfiguredFrameBytes)"
            )
        }
        guard frameTimeout.isFinite,
              frameTimeout > 0,
              frameTimeout <= Self.maximumConfiguredTimeout else {
            throw RawHVSerialConsoleInputError.invalidConfiguration(
                "frameTimeout must be finite and in (0, \(Self.maximumConfiguredTimeout)]"
            )
        }

        let listener = try Self.makeOwnedListener(
            socketPath: socketPath,
            backlog: maximumConcurrentClients
        )
        let lifetime = Lifetime(
            listener: listener,
            socketPath: socketPath,
            uart: uart,
            maximumConcurrentClients: maximumConcurrentClients,
            maximumFrameBytes: maximumFrameBytes,
            frameTimeout: frameTimeout,
            expectedPeerUID: expectedPeerUID,
            lifecycleHooks: lifecycleHooks,
            log: log
        )
        self.lifetime = lifetime

        let listenerQueue = DispatchQueue(
            label: "dev.dory.dory-hv.serial-console-input.listener.\(listener.descriptor)"
        )
        let clientQueue = DispatchQueue(
            label: "dev.dory.dory-hv.serial-console-input.clients.\(listener.descriptor)",
            attributes: .concurrent
        )
        listenerQueue.async {
            Self.runListener(
                listener,
                lifetime: lifetime,
                clientQueue: clientQueue
            )
        }
    }

    var metrics: Metrics { lifetime.metrics }

    /// Wakes the listener and every admitted client, then waits against one bounded teardown
    /// deadline. Listener/client worker threads remain the sole owners that close their descriptor.
    func stop(timeout: TimeInterval = 1) {
        let boundedTimeout = timeout.isFinite
            ? min(max(0, timeout), Self.maximumStopWait)
            : 1
        guard lifetime.stop(timeout: boundedTimeout) else {
            lifetime.log(
                "raw-HV serial console teardown did not drain within "
                    + "\(boundedTimeout) seconds on \(lifetime.socketPath)"
            )
            return
        }
    }

    deinit {
        stop()
    }

    private static func runListener(
        _ listener: OwnedListener,
        lifetime: Lifetime,
        clientQueue: DispatchQueue
    ) {
        defer { lifetime.finishListener(listener) }
        while !lifetime.isStopping {
            var readiness = pollfd(
                fd: listener.descriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let result = poll(&readiness, 1, listenerPollMilliseconds)
            if result == 0 { continue }
            if result < 0 {
                if errno == EINTR { continue }
                if !lifetime.isStopping {
                    lifetime.recordListenerFailure(
                        "listener poll failed with errno \(errno)"
                    )
                }
                return
            }
            if lifetime.isStopping { return }
            if readiness.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                lifetime.recordListenerFailure("listener became unavailable")
                return
            }
            guard readiness.revents & Int16(POLLIN) != 0 else { continue }

            while !lifetime.isStopping {
                let client = accept(listener.descriptor, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    if !lifetime.isStopping {
                        lifetime.recordListenerFailure(
                            "accept failed with errno \(errno)"
                        )
                    }
                    return
                }
                if let failure = configureAcceptedClient(client) {
                    close(client)
                    lifetime.recordClientIOFailure(
                        "could not \(failure.operation) for accepted serial console client: "
                            + "errno \(failure.code)"
                    )
                    continue
                }
                var peerUID: uid_t = 0
                var peerGID: gid_t = 0
                guard getpeereid(client, &peerUID, &peerGID) == 0 else {
                    let code = errno
                    close(client)
                    lifetime.recordClientIOFailure(
                        "could not authenticate serial console peer: errno \(code)"
                    )
                    continue
                }
                guard peerUID == lifetime.expectedPeerUID else {
                    close(client)
                    lifetime.recordRejectedPeer(peerUID: peerUID)
                    continue
                }
                switch lifetime.admit(client) {
                case .stopping:
                    close(client)
                case .atCapacity:
                    close(client)
                    lifetime.recordRejectedCapacity()
                case .admitted(let admission):
                    clientQueue.async {
                        let outcome = admission.session.run()
                        lifetime.finishClient(token: admission.token, outcome: outcome)
                    }
                }
            }
        }
    }

    private struct ClientConfigurationFailure {
        var operation: String
        var code: Int32
    }

    private static func configureAcceptedClient(
        _ descriptor: Int32
    ) -> ClientConfigurationFailure? {
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            return ClientConfigurationFailure(operation: "set close-on-exec", code: errno)
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0 else {
            return ClientConfigurationFailure(operation: "read descriptor flags", code: errno)
        }
        guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return ClientConfigurationFailure(operation: "make descriptor nonblocking", code: errno)
        }
        // Darwin inherits SO_NOSIGPIPE from the listener. Re-setting it after a peer has already
        // closed returns EINVAL, so verify the inherited protection instead of rejecting a valid
        // one-frame client that disconnected immediately after SHUT_WR.
        var noSigpipe: Int32 = 0
        var noSigpipeLength = socklen_t(MemoryLayout<Int32>.size)
        let noSigpipeResult = getsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigpipe,
            &noSigpipeLength
        )
        guard noSigpipeResult == 0 else {
            return ClientConfigurationFailure(
                operation: "verify inherited SIGPIPE protection",
                code: errno
            )
        }
        guard noSigpipe == 1 else {
            return ClientConfigurationFailure(
                operation: "verify inherited SIGPIPE protection",
                code: ENOTSUP
            )
        }
        return nil
    }

    private struct SocketPathIdentity: Equatable, Sendable {
        var device: dev_t
        var inode: ino_t
        var generation: UInt32
        var birthSeconds: Int64
        var birthNanoseconds: Int64

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            generation = info.st_gen
            birthSeconds = Int64(info.st_birthtimespec.tv_sec)
            birthNanoseconds = Int64(info.st_birthtimespec.tv_nsec)
        }
    }

    private struct OwnedListener: Sendable {
        var descriptor: Int32
        var identity: SocketPathIdentity
    }

    private enum ExistingSocketProbe {
        case live
        case refused
        case missing
        case indeterminate(Int32)
    }

    private static func makeOwnedListener(
        socketPath: String,
        backlog: Int
    ) throws -> OwnedListener {
        socketPathMutationLock.lock()
        defer { socketPathMutationLock.unlock() }
        try validate(socketPath: socketPath)

        let parent = (socketPath as NSString).deletingLastPathComponent
        var parentInfo = stat()
        guard lstat(parent, &parentInfo) == 0,
              parentInfo.st_mode & S_IFMT == S_IFDIR,
              parentInfo.st_uid == geteuid(),
              parentInfo.st_mode & 0o022 == 0 else {
            throw RawHVSerialConsoleInputError.untrustedSocketPath(
                "parent directory must be owned by the engine effective uid and not writable "
                    + "by group/other: \(parent)"
            )
        }

        var staleIdentity: SocketPathIdentity?
        var stale = stat()
        if lstat(socketPath, &stale) == 0 {
            guard stale.st_mode & S_IFMT == S_IFSOCK,
                  stale.st_uid == geteuid(),
                  stale.st_nlink == 1 else {
                throw RawHVSerialConsoleInputError.untrustedSocketPath(
                    "refusing to replace a non-socket, multiply-linked, or differently-owned "
                        + "node: \(socketPath)"
                )
            }
            staleIdentity = SocketPathIdentity(stale)
        } else if errno != ENOENT {
            throw systemCall("inspect", path: socketPath)
        }

        if staleIdentity != nil {
            switch probeExistingSocket(socketPath) {
            case .refused, .missing:
                break
            case .live:
                throw RawHVSerialConsoleInputError.untrustedSocketPath(
                    "refusing to replace a live serial console listener: \(socketPath)"
                )
            case .indeterminate(let code):
                throw RawHVSerialConsoleInputError.untrustedSocketPath(
                    "could not prove serial console socket stale (errno \(code)): \(socketPath)"
                )
            }
        }

        // Allocate and secure the descriptor before removing a trusted stale node. Resource or
        // descriptor-configuration failure must not unnecessarily destroy the last endpoint.
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw systemCall("create", path: socketPath) }
        var identity: SocketPathIdentity?
        do {
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw systemCall("set close-on-exec for", path: socketPath)
            }
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0,
                  fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw systemCall("make nonblocking", path: socketPath)
            }
            var noSigpipe: Int32 = 1
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigpipe,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                throw systemCall("disable SIGPIPE for", path: socketPath)
            }
            if let staleIdentity {
                try removeStaleSocketIfUnchanged(
                    socketPath,
                    expectedIdentity: staleIdentity
                )
            }

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(socketPath.utf8)
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                bytes.withUnsafeBytes { source in
                    destination.baseAddress!.copyMemory(
                        from: source.baseAddress!,
                        byteCount: bytes.count
                    )
                }
            }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard bound == 0 else { throw systemCall("bind", path: socketPath) }
            guard let boundIdentity = socketIdentity(at: socketPath),
                  boundIdentity.owner == geteuid(),
                  boundIdentity.linkCount == 1 else {
                throw RawHVSerialConsoleInputError.untrustedSocketPath(
                    "bound node did not retain a single owner socket identity: \(socketPath)"
                )
            }
            identity = boundIdentity.identity
            guard chmod(socketPath, 0o600) == 0 else {
                throw systemCall("set owner-only mode on", path: socketPath)
            }
            guard let captured = socketIdentity(at: socketPath),
                  captured.identity == boundIdentity.identity,
                  captured.owner == geteuid(),
                  captured.linkCount == 1,
                  captured.mode & 0o777 == 0o600 else {
                throw RawHVSerialConsoleInputError.untrustedSocketPath(
                    "bound node did not retain owner-only socket identity: \(socketPath)"
                )
            }
            guard listen(descriptor, Int32(backlog)) == 0 else {
                throw systemCall("listen on", path: socketPath)
            }
            return OwnedListener(descriptor: descriptor, identity: captured.identity)
        } catch {
            if let identity {
                unlinkIfOwned(socketPath, identity: identity)
            }
            close(descriptor)
            throw error
        }
    }

    /// A same-uid socket is not necessarily stale. Probe without blocking and fail closed for every
    /// outcome except the kernel's explicit "no listener" results. In particular, EINPROGRESS and
    /// EAGAIN can mean a live listener or full backlog and must never authorize unlink.
    private static func probeExistingSocket(_ socketPath: String) -> ExistingSocketProbe {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .indeterminate(errno) }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            return .indeterminate(errno)
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return .indeterminate(errno)
        }
        var noSigpipe: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigpipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            return .indeterminate(errno)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                destination.baseAddress!.copyMemory(
                    from: source.baseAddress!,
                    byteCount: bytes.count
                )
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        if result == 0 { return .live }
        switch errno {
        case ECONNREFUSED: return .refused
        case ENOENT: return .missing
        default: return .indeterminate(errno)
        }
    }

    private static func removeStaleSocketIfUnchanged(
        _ socketPath: String,
        expectedIdentity: SocketPathIdentity
    ) throws {
        var current = stat()
        if lstat(socketPath, &current) != 0 {
            guard errno == ENOENT else { throw systemCall("reinspect", path: socketPath) }
            return
        }
        guard current.st_mode & S_IFMT == S_IFSOCK,
              current.st_uid == geteuid(),
              current.st_nlink == 1,
              SocketPathIdentity(current) == expectedIdentity else {
            throw RawHVSerialConsoleInputError.untrustedSocketPath(
                "stale socket identity changed before replacement: \(socketPath)"
            )
        }
        guard unlink(socketPath) == 0 else {
            throw systemCall("remove stale", path: socketPath)
        }
    }

    private static func validate(socketPath: String) throws {
        let bytes = Array(socketPath.utf8)
        let address = sockaddr_un()
        let maximum = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard socketPath.first == "/" else {
            throw RawHVSerialConsoleInputError.invalidSocketPath("path must be absolute")
        }
        guard !bytes.contains(0) else {
            throw RawHVSerialConsoleInputError.invalidSocketPath("path contains a NUL byte")
        }
        guard !bytes.isEmpty, bytes.count <= maximum else {
            throw RawHVSerialConsoleInputError.invalidSocketPath(
                "path is \(bytes.count) UTF-8 bytes; maximum is \(maximum)"
            )
        }
        guard (socketPath as NSString).standardizingPath == socketPath else {
            throw RawHVSerialConsoleInputError.invalidSocketPath(
                "path must not contain redundant or parent components"
            )
        }
    }

    private static func retire(_ listener: OwnedListener, socketPath: String) {
        socketPathMutationLock.lock()
        unlinkIfOwned(socketPath, identity: listener.identity)
        socketPathMutationLock.unlock()
        close(listener.descriptor)
    }

    @discardableResult
    private static func unlinkIfOwned(
        _ socketPath: String,
        identity: SocketPathIdentity
    ) -> Bool {
        guard socketIdentity(at: socketPath)?.identity == identity else { return false }
        return unlink(socketPath) == 0 || errno == ENOENT
    }

    private static func socketIdentity(
        at socketPath: String
    ) -> (identity: SocketPathIdentity, owner: uid_t, mode: mode_t, linkCount: nlink_t)? {
        var info = stat()
        guard lstat(socketPath, &info) == 0,
              info.st_mode & S_IFMT == S_IFSOCK else {
            return nil
        }
        return (
            SocketPathIdentity(info),
            info.st_uid,
            info.st_mode,
            info.st_nlink
        )
    }

    private static func systemCall(
        _ operation: String,
        path: String
    ) -> RawHVSerialConsoleInputError {
        .systemCall(operation: operation, path: path, code: errno)
    }

    private final class ClientSession: @unchecked Sendable {
        enum Outcome: Sendable {
            case frame([UInt8])
            case empty
            case oversized
            case timedOut
            case ioFailure(Int32)
            case stopped
        }

        private let lock = NSLock()
        private let maximumFrameBytes: Int
        private let deadline: TimeInterval
        private var descriptor: Int32?
        private var started = false
        private var stopping = false

        init(
            descriptor: Int32,
            maximumFrameBytes: Int,
            frameTimeout: TimeInterval
        ) {
            self.descriptor = descriptor
            self.maximumFrameBytes = maximumFrameBytes
            self.deadline = ProcessInfo.processInfo.systemUptime + frameTimeout
        }

        func run() -> Outcome {
            let descriptor: Int32
            lock.lock()
            guard !started, let owned = self.descriptor else {
                lock.unlock()
                return .stopped
            }
            started = true
            descriptor = owned
            let shouldRead = !stopping
            lock.unlock()

            let outcome = shouldRead ? readFrame(from: descriptor) : .stopped
            let finalOutcome = isStopping ? .stopped : outcome
            finish()
            return finalOutcome
        }

        func requestStop() {
            lock.lock()
            stopping = true
            if let descriptor { _ = shutdown(descriptor, SHUT_RDWR) }
            lock.unlock()
        }

        private var isStopping: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopping
        }

        private func readFrame(from descriptor: Int32) -> Outcome {
            var frame = [UInt8]()
            frame.reserveCapacity(min(maximumFrameBytes, 4 * 1_024))
            var buffer = [UInt8](repeating: 0, count: min(maximumFrameBytes + 1, 4 * 1_024))
            while true {
                if isStopping { return .stopped }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { return .timedOut }
                let milliseconds = Int32(min(
                    Double(Int32.max),
                    max(1, ceil(remaining * 1_000))
                ))
                var readiness = pollfd(
                    fd: descriptor,
                    events: Int16(POLLIN),
                    revents: 0
                )
                let ready = poll(&readiness, 1, milliseconds)
                if ready == 0 { return .timedOut }
                if ready < 0 {
                    if errno == EINTR { continue }
                    return .ioFailure(errno)
                }
                if readiness.revents & Int16(POLLERR | POLLNVAL) != 0 {
                    return isStopping ? .stopped : .ioFailure(ECONNRESET)
                }

                let remainingCapacity = maximumFrameBytes - frame.count
                let requested = min(buffer.count, remainingCapacity + 1)
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress, requested)
                }
                if count > 0 {
                    frame.append(contentsOf: buffer.prefix(count))
                    if frame.count > maximumFrameBytes { return .oversized }
                    continue
                }
                if count == 0 {
                    return frame.isEmpty ? .empty : .frame(frame)
                }
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    continue
                }
                return isStopping ? .stopped : .ioFailure(errno)
            }
        }

        private func finish() {
            lock.lock()
            let descriptor = self.descriptor
            self.descriptor = nil
            if let descriptor { close(descriptor) }
            lock.unlock()
        }
    }

    private final class Lifetime: @unchecked Sendable {
        struct Admission: Sendable {
            var token: UUID
            var session: ClientSession
        }

        enum AdmissionDecision: Sendable {
            case admitted(Admission)
            case atCapacity
            case stopping
        }

        let socketPath: String
        let expectedPeerUID: uid_t
        let log: @Sendable (String) -> Void

        private let lock = NSLock()
        private let listenerCompletion = DispatchGroup()
        private let clientCompletion = DispatchGroup()
        private let uart: PL011
        private let maximumConcurrentClients: Int
        private let maximumFrameBytes: Int
        private let frameTimeout: TimeInterval
        private let lifecycleHooks: LifecycleHooks
        private var listener: OwnedListener?
        private var stopping = false
        private var clients = [UUID: ClientSession]()
        private var storedMetrics = Metrics()

        init(
            listener: OwnedListener,
            socketPath: String,
            uart: PL011,
            maximumConcurrentClients: Int,
            maximumFrameBytes: Int,
            frameTimeout: TimeInterval,
            expectedPeerUID: uid_t,
            lifecycleHooks: LifecycleHooks,
            log: @escaping @Sendable (String) -> Void
        ) {
            self.listener = listener
            self.socketPath = socketPath
            self.uart = uart
            self.maximumConcurrentClients = maximumConcurrentClients
            self.maximumFrameBytes = maximumFrameBytes
            self.frameTimeout = frameTimeout
            self.expectedPeerUID = expectedPeerUID
            self.lifecycleHooks = lifecycleHooks
            self.log = log
            listenerCompletion.enter()
        }

        var isStopping: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopping
        }

        var metrics: Metrics {
            lock.lock()
            defer { lock.unlock() }
            var result = storedMetrics
            result.activeClientCount = clients.count
            return result
        }

        func admit(_ descriptor: Int32) -> AdmissionDecision {
            lock.lock()
            defer { lock.unlock() }
            guard !stopping else { return .stopping }
            guard clients.count < maximumConcurrentClients else { return .atCapacity }
            let token = UUID()
            let session = ClientSession(
                descriptor: descriptor,
                maximumFrameBytes: maximumFrameBytes,
                frameTimeout: frameTimeout
            )
            clients[token] = session
            clientCompletion.enter()
            return .admitted(Admission(token: token, session: session))
        }

        func finishClient(token: UUID, outcome: ClientSession.Outcome) {
            var diagnostic: String?
            lock.lock()
            guard clients.removeValue(forKey: token) != nil else {
                lock.unlock()
                return
            }
            switch outcome {
            case .frame(let bytes) where !stopping:
                if uart.receive(bytes) {
                    increment(&storedMetrics.acceptedFrameCount)
                    add(UInt64(bytes.count), to: &storedMetrics.acceptedByteCount)
                } else {
                    increment(&storedMetrics.uartBackpressureCount)
                    diagnostic = "dropped a serial console frame because the UART input queue is full"
                }
            case .frame:
                break
            case .empty:
                increment(&storedMetrics.rejectedEmptyFrameCount)
                diagnostic = "dropped an empty serial console frame"
            case .oversized:
                increment(&storedMetrics.rejectedOversizedFrameCount)
                diagnostic = "dropped an oversized serial console frame"
            case .timedOut:
                increment(&storedMetrics.timedOutFrameCount)
                diagnostic = "dropped a serial console frame after its whole-frame deadline"
            case .ioFailure(let code):
                increment(&storedMetrics.clientIOFailureCount)
                diagnostic = "serial console client read failed with errno \(code)"
            case .stopped:
                break
            }
            lock.unlock()
            clientCompletion.leave()
            if let diagnostic { log(diagnostic) }
        }

        func recordRejectedPeer(peerUID: uid_t) {
            lock.lock()
            increment(&storedMetrics.rejectedPeerCount)
            lock.unlock()
            log(
                "rejected serial console peer uid \(peerUID); "
                    + "expected \(expectedPeerUID)"
            )
        }

        func recordRejectedCapacity() {
            lock.lock()
            increment(&storedMetrics.rejectedCapacityCount)
            lock.unlock()
            log("rejected serial console client because admission capacity is full")
        }

        func recordClientIOFailure(_ diagnostic: String) {
            lock.lock()
            increment(&storedMetrics.clientIOFailureCount)
            lock.unlock()
            log(diagnostic)
        }

        func recordListenerFailure(_ diagnostic: String) {
            let shouldLog: Bool
            lock.lock()
            if !stopping {
                increment(&storedMetrics.listenerFailureCount)
                shouldLog = true
            } else {
                shouldLog = false
            }
            lock.unlock()
            if shouldLog { log(diagnostic) }
        }

        func finishListener(_ owned: OwnedListener) {
            let sessions: [ClientSession]
            lock.lock()
            guard listener?.descriptor == owned.descriptor,
                  listener?.identity == owned.identity else {
                lock.unlock()
                return
            }
            listener = nil
            stopping = true
            sessions = Array(clients.values)
            lock.unlock()

            lifecycleHooks.beforeListenerRetire()
            RawHVSerialConsoleInput.retire(owned, socketPath: socketPath)
            for session in sessions { session.requestStop() }
            listenerCompletion.leave()
        }

        func stop(timeout: TimeInterval) -> Bool {
            let sessions: [ClientSession]
            lock.lock()
            stopping = true
            if let listener {
                // This is a descriptor borrow, not an integer snapshot. finishListener needs the
                // same lock before it can remove and retire the listener, so close/reuse cannot win
                // between selecting this descriptor and shutdown returning.
                lifecycleHooks.beforeListenerShutdown()
                _ = shutdown(listener.descriptor, SHUT_RDWR)
            }
            sessions = Array(clients.values)
            lock.unlock()
            for session in sessions { session.requestStop() }

            let deadline = DispatchTime.now() + timeout
            let listenerFinished = listenerCompletion.wait(timeout: deadline) == .success
            let clientsFinished = clientCompletion.wait(timeout: deadline) == .success
            return listenerFinished && clientsFinished
        }

        private func increment(_ value: inout UInt64) {
            if value < UInt64.max { value += 1 }
        }

        private func add(_ amount: UInt64, to value: inout UInt64) {
            let (result, overflow) = value.addingReportingOverflow(amount)
            value = overflow ? UInt64.max : result
        }
    }
}
