import Darwin
import Foundation

/// A Unix-domain listener failed before it could be published. Keep the syscall and errno in the
/// error so required engine endpoints can fail startup with an actionable reason instead of
/// degrading into a later timeout.
public enum UnixSocketListenerError: Error, Equatable, CustomStringConvertible, Sendable {
    case pathTooLong(path: String, utf8ByteCount: Int, maximumUTF8ByteCount: Int)
    case embeddedNull(path: String)
    case systemCall(operation: String, path: String, code: Int32)

    public var description: String {
        switch self {
        case let .pathTooLong(path, actual, maximum):
            return "unix socket path is \(actual) UTF-8 bytes (maximum \(maximum)): \(path)"
        case let .embeddedNull(path):
            return "unix socket path contains a NUL byte: \(path)"
        case let .systemCall(operation, path, code):
            let reason = String(cString: strerror(code))
            return "cannot \(operation) unix socket \(path): errno \(code) (\(reason))"
        }
    }
}

/// The one unix⇄vsock byte relay, shared by every bridge that serves a unix socket in front of a
/// guest vsock stream (`DockerSocketBridge`, `AgentVsockForward`). Both directions preserve
/// half-close: a client SHUT_WR becomes a vsock SEND-only shutdown, and the guest's send-EOF
/// becomes a SHUT_WR back to the client — a full close in either spot truncates docker attach.
enum VsockUnixRelay {
    /// Darwin's `sockaddr_un.sun_path` includes its trailing NUL. Validate UTF-8 bytes rather than
    /// Swift characters: a multibyte path that looks short can still overflow the kernel field.
    static let maximumSocketPathByteCount: Int = {
        var address = sockaddr_un()
        return MemoryLayout.size(ofValue: address.sun_path) - 1
    }()

    static func validateSocketPath(_ socketPath: String) throws {
        let pathBytes = Array(socketPath.utf8)
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

    static func makeListener(socketPath: String, mode: mode_t? = nil) throws -> Int32 {
        try validateSocketPath(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw UnixSocketListenerError.systemCall(operation: "create", path: socketPath, code: errno)
        }
        guard unlink(socketPath) == 0 || errno == ENOENT else {
            let code = errno
            close(fd)
            throw UnixSocketListenerError.systemCall(operation: "remove stale", path: socketPath, code: code)
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
        guard Darwin.listen(fd, 64) == 0 else {
            let code = errno
            // Remove our pathname while the descriptor still owns the bound socket. Closing first
            // would let another process bind a replacement that this cleanup could then unlink.
            unlink(socketPath)
            close(fd)
            throw UnixSocketListenerError.systemCall(operation: "listen on", path: socketPath, code: code)
        }
        if let mode, chmod(socketPath, mode) != 0 {
            let code = errno
            // As above, retire the pathname before releasing the descriptor to avoid deleting a
            // replacement socket in the close-to-unlink window.
            unlink(socketPath)
            close(fd)
            throw UnixSocketListenerError.systemCall(operation: "chmod", path: socketPath, code: code)
        }
        return fd
    }

    /// Relays until both directions finish, then tears everything down. Takes ownership of both ends.
    static func serve(client: Int32, connection: VsockConnection) {
        defer {
            connection.close()
            close(client)
        }
        let group = DispatchGroup()
        group.enter()
        let box = ConnectionBox(connection)
        Thread.detachNewThread {
            pumpVsockToClient(from: box.connection, to: client)
            group.leave()
        }
        pumpClientToVsock(from: client, to: connection)
        group.wait()
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
