import Darwin
import Foundation

/// Serves the engine's docker socket (`engine.sock`) from dory-hv itself, relaying every connection
/// to the guest agent's docker proxy over vsock — with full half-close fidelity in both directions.
///
/// This replaces the gvproxy unix-socket forward, which tears the whole stream down when the client
/// half-closes. The docker CLI half-closes the hijacked connection as soon as it has sent an
/// attach/exec request without stdin, so through gvproxy every `docker run` returned an empty
/// output stream. Here a client SHUT_WR becomes a vsock SEND-only shutdown (the agent CloseWrites
/// to dockerd), and dockerd's response EOF becomes a SHUT_WR back to the client.
public final class DockerSocketBridge: @unchecked Sendable {
    private let socketPath: String
    private let log: @Sendable (String) -> Void

    public init(socketPath: String, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.socketPath = socketPath
        self.log = log
    }

    private final class VsockBox: @unchecked Sendable {
        let vsock: VirtioVsock
        init(_ vsock: VirtioVsock) { self.vsock = vsock }
    }

    private final class ConnectionBox: @unchecked Sendable {
        let connection: VsockConnection
        init(_ connection: VsockConnection) { self.connection = connection }
    }

    public func attach(to vsock: VirtioVsock) {
        guard let listener = makeListener() else {
            log("docker socket bridge could not listen on \(socketPath)")
            return
        }
        let box = VsockBox(vsock)
        let path = socketPath
        let log = log
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else {
                    if errno == EINTR { continue }
                    log("docker socket bridge accept failed on \(path): errno \(errno)")
                    break
                }
                var noSigpipe: Int32 = 1
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
                let connection = ConnectionBox(box.vsock.connect(port: VsockPorts.docker))
                Thread.detachNewThread {
                    self.serve(client: client, connection: connection.connection)
                }
            }
            close(listener)
        }
        log("docker socket bridge serving \(socketPath) over vsock:\(VsockPorts.docker)")
    }

    private func makeListener() -> Int32? {
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
        return fd
    }

    private func serve(client: Int32, connection: VsockConnection) {
        defer {
            connection.close()
            close(client)
        }
        let group = DispatchGroup()
        group.enter()
        let box = ConnectionBox(connection)
        Thread.detachNewThread {
            Self.pumpVsockToClient(from: box.connection, to: client)
            group.leave()
        }
        Self.pumpClientToVsock(from: client, to: connection)
        group.wait()
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
        var pollInterval: useconds_t = 500
        let maxPollInterval: useconds_t = 16_000
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
                usleep(pollInterval)
                pollInterval = min(pollInterval * 2, maxPollInterval)
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
            pollInterval = 500
        }
    }
}
