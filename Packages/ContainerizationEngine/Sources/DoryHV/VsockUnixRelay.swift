import Darwin
import Foundation

/// The one unix⇄vsock byte relay, shared by every bridge that serves a unix socket in front of a
/// guest vsock stream (`DockerSocketBridge`, `AgentVsockForward`). Both directions preserve
/// half-close: a client SHUT_WR becomes a vsock SEND-only shutdown, and the guest's send-EOF
/// becomes a SHUT_WR back to the client — a full close in either spot truncates docker attach.
enum VsockUnixRelay {
    static func makeListener(socketPath: String, mode: mode_t? = nil) -> Int32? {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard pathBytes.count <= capacity else {
            close(fd)
            return nil
        }
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
        guard bound == 0, Darwin.listen(fd, 64) == 0 else {
            close(fd)
            return nil
        }
        if let mode, chmod(socketPath, mode) != 0 {
            close(fd)
            unlink(socketPath)
            return nil
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
