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

    /// Lets the engine reject an impossible Docker endpoint before it creates disks or sidecars.
    public static func validateSocketPath(_ socketPath: String) throws {
        try VsockUnixRelay.validateSocketPath(socketPath)
    }

    private final class VsockBox: @unchecked Sendable {
        let vsock: VirtioVsock
        init(_ vsock: VirtioVsock) { self.vsock = vsock }
    }

    private final class ConnectionBox: @unchecked Sendable {
        let connection: VsockConnection
        init(_ connection: VsockConnection) { self.connection = connection }
    }

    public func attach(to vsock: VirtioVsock) throws {
        let listener = try VsockUnixRelay.makeListener(socketPath: socketPath)
        let box = VsockBox(vsock)
        let path = socketPath
        let log = log
        Thread.detachNewThread {
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
                    VsockUnixRelay.serve(client: client, connection: connection.connection)
                }
            }
            close(listener)
        }
        log("docker socket bridge serving \(socketPath) over vsock:\(VsockPorts.docker)")
    }
}
