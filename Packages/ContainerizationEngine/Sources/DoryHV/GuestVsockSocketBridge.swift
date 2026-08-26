import Foundation

/// Publishes one private host Unix socket and relays each accepted connection to a fixed guest
/// vsock port. Desktop machines use it for the agent control and shell endpoints expected by doryd.
public final class GuestVsockSocketBridge: @unchecked Sendable {
    private let socketPath: String
    private let guestPort: UInt32
    private let service: VirtioVsockService
    private let log: @Sendable (String) -> Void
    private let listener: BoundedVsockSocketListener

    public init(
        socketPath: String,
        guestPort: UInt32,
        service: VirtioVsockService,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.socketPath = socketPath
        self.guestPort = guestPort
        self.service = service
        self.log = log
        self.listener = BoundedVsockSocketListener(
            socketPath: socketPath,
            mode: 0o600,
            endpointLabel: "vsock bridge",
            log: log
        )
    }

    public static func validateSocketPath(_ socketPath: String) throws {
        try VsockUnixRelay.validateSocketPath(socketPath)
    }

    public func attach(to vsock: VirtioVsock) throws {
        let port = guestPort
        let logger = log
        try listener.attach(to: vsock, service: service) { _ in
            do {
                return try vsock.connectIfCapacity(port: port)
            } catch {
                logger("vsock bridge rejected guest port \(port): \(error)")
                return nil
            }
        }
        log("vsock bridge serving \(socketPath) over guest port \(guestPort)")
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
