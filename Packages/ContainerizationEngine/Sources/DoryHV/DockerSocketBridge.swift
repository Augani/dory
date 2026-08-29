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
    private let listener: BoundedVsockSocketListener

    public init(
        socketPath: String,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.socketPath = socketPath
        self.log = log
        self.listener = BoundedVsockSocketListener(
            socketPath: socketPath,
            mode: nil,
            endpointLabel: "docker socket bridge",
            log: log
        )
    }

    /// Lets the engine reject an impossible Docker endpoint before it creates disks or sidecars.
    public static func validateSocketPath(_ socketPath: String) throws {
        try VsockUnixRelay.validateSocketPath(socketPath)
    }

    public func attach(to vsock: VirtioVsock) throws {
        let logger = log
        try listener.attach(to: vsock, service: .docker) { _ in
            do {
                return try vsock.connectIfCapacity(port: VsockPorts.docker)
            } catch {
                logger("docker socket bridge rejected guest dial: \(error)")
                return nil
            }
        }
        log("docker socket bridge serving \(socketPath) over vsock:\(VsockPorts.docker)")
    }

    public func stop(timeout: TimeInterval = 1) {
        listener.stop(timeout: timeout)
    }

    var activeSessionCount: Int { listener.activeSessionCount }
    var serviceAdmissionSnapshot: VirtioVsockServiceAdmissionSnapshot? {
        listener.serviceAdmissionSnapshot
    }

    deinit {
        stop()
    }
}
