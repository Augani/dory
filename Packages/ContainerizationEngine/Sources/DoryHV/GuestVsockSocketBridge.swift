import Darwin
import Foundation

/// Publishes one private host Unix socket and relays each accepted connection to a fixed guest
/// vsock port. Desktop machines use it for the agent control and shell endpoints expected by doryd.
public final class GuestVsockSocketBridge: @unchecked Sendable {
    private let socketPath: String
    private let guestPort: UInt32
    private let log: @Sendable (String) -> Void

    public init(
        socketPath: String,
        guestPort: UInt32,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.socketPath = socketPath
        self.guestPort = guestPort
        self.log = log
    }

    public static func validateSocketPath(_ socketPath: String) throws {
        try VsockUnixRelay.validateSocketPath(socketPath)
    }

    public func attach(to vsock: VirtioVsock) throws {
        let listener = try VsockUnixRelay.makeListener(socketPath: socketPath, mode: 0o600)
        let path = socketPath
        let port = guestPort
        let log = log
        let box = VsockBox(vsock)
        Thread.detachNewThread {
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else {
                    if errno == EINTR { continue }
                    log("vsock bridge accept failed on \(path): errno \(errno)")
                    break
                }
                var noSigpipe: Int32 = 1
                _ = setsockopt(
                    client,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    &noSigpipe,
                    socklen_t(MemoryLayout<Int32>.size)
                )
                let connection = ConnectionBox(box.vsock.connect(port: port))
                Thread.detachNewThread {
                    VsockUnixRelay.serve(client: client, connection: connection.value)
                }
            }
            close(listener)
        }
        log("vsock bridge serving \(socketPath) over guest port \(guestPort)")
    }

    private final class VsockBox: @unchecked Sendable {
        let vsock: VirtioVsock
        init(_ vsock: VirtioVsock) { self.vsock = vsock }
    }

    private final class ConnectionBox: @unchecked Sendable {
        let value: VsockConnection
        init(_ value: VsockConnection) { self.value = value }
    }
}
