import Darwin
import Foundation

/// A Unix-domain listener failed before it could be published. Keep the syscall and errno in the
/// error so required engine endpoints can fail startup with an actionable reason instead of
/// degrading into a later timeout.
public enum UnixSocketListenerError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidAbsolutePath(path: String)
    case pathTooLong(path: String, utf8ByteCount: Int, maximumUTF8ByteCount: Int)
    case embeddedNull(path: String)
    case untrustedExistingNode(path: String)
    case endpointInUse(path: String)
    case systemCall(operation: String, path: String, code: Int32)

    public var description: String {
        switch self {
        case let .invalidAbsolutePath(path):
            return "unix socket path must be absolute: \(path)"
        case let .pathTooLong(path, actual, maximum):
            return "unix socket path is \(actual) UTF-8 bytes (maximum \(maximum)): \(path)"
        case let .embeddedNull(path):
            return "unix socket path contains a NUL byte: \(path)"
        case let .untrustedExistingNode(path):
            return "refusing to replace a non-socket or non-owned unix endpoint: \(path)"
        case let .endpointInUse(path):
            return "refusing to replace a live unix endpoint: \(path)"
        case let .systemCall(operation, path, code):
            let reason = String(cString: strerror(code))
            return "cannot \(operation) unix socket \(path): errno \(code) (\(reason))"
        }
    }
}

/// The one unix⇄vsock byte relay, shared by every bridge that serves a unix socket in front of a
/// guest vsock stream (`GuestVsockSocketBridge`, `DockerSocketBridge`, `AgentVsockForward`).
/// Both directions preserve
/// half-close: a client SHUT_WR becomes a vsock SEND-only shutdown, and the guest's send-EOF
/// becomes a SHUT_WR back to the client — a full close in either spot truncates docker attach.
enum VsockUnixRelay {
    struct SocketPathIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let generation: UInt32
        let birthTimeSeconds: Int64
        let birthTimeNanoseconds: Int64
    }

    struct OwnedListener: Sendable {
        let descriptor: Int32
        let pathIdentity: SocketPathIdentity
    }

    private enum ExistingEndpointProbe {
        case live
        case stale
        case indeterminate(Int32)
    }

    /// Serializes Dory-owned pathname publication and retirement. Darwin has no conditional-unlink
    /// syscall, so the identity check and unlink must share this lock with every in-process bind to
    /// prevent one bridge's cleanup from racing another bridge's replacement publication.
    private static let socketPathMutationLock = NSLock()

    /// Darwin's `sockaddr_un.sun_path` includes its trailing NUL. Validate UTF-8 bytes rather than
    /// Swift characters: a multibyte path that looks short can still overflow the kernel field.
    static let maximumSocketPathByteCount: Int = {
        var address = sockaddr_un()
        return MemoryLayout.size(ofValue: address.sun_path) - 1
    }()

    static func validateSocketPath(_ socketPath: String) throws {
        let pathBytes = Array(socketPath.utf8)
        guard socketPath.hasPrefix("/") else {
            throw UnixSocketListenerError.invalidAbsolutePath(path: socketPath)
        }
        guard !pathBytes.contains(0) else {
            throw UnixSocketListenerError.embeddedNull(path: socketPath)
        }
        guard pathBytes.count <= maximumSocketPathByteCount else {
            throw UnixSocketListenerError.pathTooLong(
                path: socketPath,
                utf8ByteCount: pathBytes.count,
                maximumUTF8ByteCount: maximumSocketPathByteCount
            )
        }
    }

    /// Publishes a listener and captures the exact filesystem socket identity while the descriptor
    /// is still live. Owners use that identity to avoid deleting a replacement endpoint during
    /// asynchronous teardown.
    static func makeOwnedListener(
        socketPath: String,
        mode: mode_t? = nil
    ) throws -> OwnedListener {
        socketPathMutationLock.lock()
        defer { socketPathMutationLock.unlock() }
        try validateSocketPath(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw UnixSocketListenerError.systemCall(operation: "create", path: socketPath, code: errno)
        }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            let code = errno
            close(fd)
            throw UnixSocketListenerError.systemCall(
                operation: "set close-on-exec for",
                path: socketPath,
                code: code
            )
        }
        var stale = stat()
        if lstat(socketPath, &stale) == 0 {
            guard stale.st_mode & S_IFMT == S_IFSOCK,
                  stale.st_uid == geteuid(),
                  let staleIdentity = socketPathIdentity(at: socketPath) else {
                close(fd)
                throw UnixSocketListenerError.untrustedExistingNode(path: socketPath)
            }
            switch probeExistingListener(socketPath) {
            case .live:
                close(fd)
                throw UnixSocketListenerError.endpointInUse(path: socketPath)
            case .indeterminate(let code):
                close(fd)
                throw UnixSocketListenerError.systemCall(
                    operation: "prove stale",
                    path: socketPath,
                    code: code
                )
            case .stale:
                break
            }
            guard socketPathIdentity(at: socketPath) == staleIdentity else {
                close(fd)
                throw UnixSocketListenerError.untrustedExistingNode(path: socketPath)
            }
            guard unlink(socketPath) == 0 else {
                let code = errno
                close(fd)
                throw UnixSocketListenerError.systemCall(
                    operation: "remove stale",
                    path: socketPath,
                    code: code
                )
            }
        } else if errno != ENOENT {
            let code = errno
            close(fd)
            throw UnixSocketListenerError.systemCall(
                operation: "inspect stale",
                path: socketPath,
                code: code
            )
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: pathBytes.count)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, size)
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw UnixSocketListenerError.systemCall(operation: "bind", path: socketPath, code: code)
        }
        guard let pathIdentity = socketPathIdentity(at: socketPath) else {
            let code = errno == 0 ? EIO : errno
            close(fd)
            throw UnixSocketListenerError.systemCall(
                operation: "inspect bound",
                path: socketPath,
                code: code
            )
        }
        guard Darwin.listen(fd, 64) == 0 else {
            let code = errno
            unlinkSocketIfOwnedLocked(socketPath, identity: pathIdentity)
            close(fd)
            throw UnixSocketListenerError.systemCall(operation: "listen on", path: socketPath, code: code)
        }
        if let mode, chmod(socketPath, mode) != 0 {
            let code = errno
            unlinkSocketIfOwnedLocked(socketPath, identity: pathIdentity)
            close(fd)
            throw UnixSocketListenerError.systemCall(operation: "chmod", path: socketPath, code: code)
        }
        guard socketPathIdentity(at: socketPath) == pathIdentity else {
            unlinkSocketIfOwnedLocked(socketPath, identity: pathIdentity)
            close(fd)
            throw UnixSocketListenerError.systemCall(
                operation: "retain identity of",
                path: socketPath,
                code: ESTALE
            )
        }
        return OwnedListener(descriptor: fd, pathIdentity: pathIdentity)
    }

    /// A same-uid socket is not stale merely because a pathname already exists. Only the kernel's
    /// explicit no-listener outcomes authorize removal; a live listener, a full backlog, and every
    /// ambiguous probe result fail closed.
    private static func probeExistingListener(_ socketPath: String) -> ExistingEndpointProbe {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .indeterminate(errno) }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            return .indeterminate(errno)
        }
        let statusFlags = fcntl(descriptor, F_GETFL)
        guard statusFlags >= 0,
              fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) == 0 else {
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
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.baseAddress!.copyMemory(
                    from: source.baseAddress!,
                    byteCount: pathBytes.count
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
        case ECONNREFUSED, ENOENT:
            return .stale
        default:
            return .indeterminate(errno)
        }
    }

    @discardableResult
    static func makeNonBlocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    /// Removes only the filesystem node captured for this listener. The listener descriptor must
    /// remain open until after this call; that ordering narrows replacement races and ensures a
    /// completion signal means pathname ownership has already been surrendered.
    static func retireOwnedListener(_ listener: OwnedListener, socketPath: String) {
        socketPathMutationLock.lock()
        defer { socketPathMutationLock.unlock() }
        unlinkSocketIfOwnedLocked(socketPath, identity: listener.pathIdentity)
        close(listener.descriptor)
    }

    @discardableResult
    private static func unlinkSocketIfOwnedLocked(
        _ socketPath: String,
        identity: SocketPathIdentity
    ) -> Bool {
        guard let current = socketPathIdentity(at: socketPath) else {
            return errno == ENOENT
        }
        guard current == identity else { return false }
        return unlink(socketPath) == 0 || errno == ENOENT
    }

    private static func socketPathIdentity(at socketPath: String) -> SocketPathIdentity? {
        var info = stat()
        guard lstat(socketPath, &info) == 0,
              info.st_mode & S_IFMT == S_IFSOCK,
              info.st_uid == geteuid() else {
            return nil
        }
        return SocketPathIdentity(
            device: info.st_dev,
            inode: info.st_ino,
            generation: info.st_gen,
            birthTimeSeconds: Int64(info.st_birthtimespec.tv_sec),
            birthTimeNanoseconds: Int64(info.st_birthtimespec.tv_nsec)
        )
    }

    /// One cancel-safe relay. Normal execution keeps the established half-close contract; an
    /// explicit bridge stop uses full shutdown only to retire the session. The client descriptor is
    /// closed by the relay after both pumps finish, never by the stopping thread, so descriptor reuse
    /// cannot redirect a late close or shutdown to an unrelated file.
    final class RelaySession: @unchecked Sendable {
        private let lock = NSLock()
        private var client: Int32?
        private var connection: VsockConnection?
        private var prepareConnection: (@Sendable (Int32) -> VsockConnection?)?
        private var started = false
        private var stopRequested = false
        private var completion: (@Sendable () -> Void)?

        init(
            client: Int32,
            connection: VsockConnection,
            completion: @escaping @Sendable () -> Void = {}
        ) {
            self.client = client
            self.connection = connection
            self.prepareConnection = nil
            self.completion = completion
        }

        /// Owns an accepted descriptor before a guest connection necessarily exists. The bounded
        /// listener uses this for protocol admission (notably AgentVsockForward's preamble): stop()
        /// can shutdown the client and wake that preparation without racing its eventual close.
        /// `prepareConnection` borrows the descriptor; RelaySession remains its only close owner.
        init(
            client: Int32,
            prepareConnection: @escaping @Sendable (Int32) -> VsockConnection?,
            completion: @escaping @Sendable () -> Void = {}
        ) {
            self.client = client
            self.connection = nil
            self.prepareConnection = prepareConnection
            self.completion = completion
        }

        func run() {
            let descriptor: Int32
            let existingConnection: VsockConnection?
            let preparation: (@Sendable (Int32) -> VsockConnection?)?
            lock.lock()
            guard !started, let client else {
                lock.unlock()
                return
            }
            started = true
            descriptor = client
            existingConnection = connection
            preparation = prepareConnection
            prepareConnection = nil
            lock.unlock()

            guard let preparedConnection = existingConnection ?? preparation?(descriptor) else {
                finish()
                return
            }
            lock.lock()
            if connection == nil { connection = preparedConnection }
            let shouldRelay = !stopRequested
            lock.unlock()
            guard shouldRelay else {
                finish()
                return
            }

            let group = DispatchGroup()
            group.enter()
            let box = ConnectionBox(preparedConnection)
            Thread.detachNewThread {
                pumpVsockToClient(from: box.connection, to: descriptor)
                group.leave()
            }
            pumpClientToVsock(from: descriptor, to: preparedConnection)
            group.wait()
            finish()
        }

        func requestStop() {
            lock.lock()
            guard let client, !stopRequested else {
                lock.unlock()
                return
            }
            stopRequested = true
            // Keep the descriptor allocated until both pumps have observed shutdown. Holding the
            // lifecycle lock makes this syscall mutually exclusive with finish's final close.
            _ = shutdown(client, SHUT_RDWR)
            connection?.close()
            lock.unlock()
        }

        /// Used only when bridge shutdown wins the race before the relay thread is published.
        func discardBeforeStart() {
            let descriptor: Int32?
            let callback: (@Sendable () -> Void)?
            lock.lock()
            guard !started else {
                lock.unlock()
                requestStop()
                return
            }
            descriptor = client
            client = nil
            stopRequested = true
            callback = completion
            completion = nil
            prepareConnection = nil
            connection?.close()
            connection = nil
            if let descriptor { close(descriptor) }
            lock.unlock()
            callback?()
        }

        private func finish() {
            let descriptor: Int32?
            let callback: (@Sendable () -> Void)?
            lock.lock()
            descriptor = client
            client = nil
            callback = completion
            completion = nil
            prepareConnection = nil
            connection?.close()
            connection = nil
            if let descriptor { close(descriptor) }
            lock.unlock()
            callback?()
        }
    }

    private final class ConnectionBox: @unchecked Sendable {
        let connection: VsockConnection
        init(_ connection: VsockConnection) { self.connection = connection }
    }

    /// Client → guest. On client EOF (the docker CLI half-closes right after an attach/exec request
    /// without stdin, and `docker run -i` half-closes at stdin EOF) propagate a SEND-only shutdown so
    /// dockerd sees request-EOF while its response keeps streaming on the other pump.
    private static func pumpClientToVsock(from fd: Int32, to connection: VsockConnection) {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let capacity = buffer.count
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, capacity) }
            if count == 0 {
                connection.shutdownSend()
                return
            }
            if count < 0 {
                if errno == EINTR { continue }
                connection.close()
                return
            }
            do {
                try connection.write(Array(buffer.prefix(count)))
            } catch {
                return
            }
        }
    }

    /// Guest → client. When the guest is done sending (dockerd finished its response) half-close the
    /// client's write side so it sees EOF while it can still be sending late request bytes.
    private static func pumpVsockToClient(from connection: VsockConnection, to fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let capacity = buffer.count
            let count = (try? buffer.withUnsafeMutableBytes {
                try connection.read(into: UnsafeMutableRawBufferPointer(rebasing: $0[0..<capacity]))
            }) ?? 0
            if count == 0 {
                if connection.isPeerClosed {
                    shutdown(fd, SHUT_WR)
                    return
                }
                _ = connection.waitForReadable(timeoutNanoseconds: nil)
                continue
            }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes {
                    write(fd, $0.baseAddress!.advanced(by: offset), count - offset)
                }
                if written <= 0 {
                    if written < 0 && errno == EINTR { continue }
                    return
                }
                offset += written
            }
        }
    }
}
