import Darwin
import Foundation

/// The preamble the Rust dataplane writes on every connection to `--agent-vsock-forward`: one
/// length-prefixed frame (LE u32) whose 9-byte body is direction(1) + cid(4 LE) + port(4 LE) —
/// the exact wire shape of `dory-core/proto/src/preamble.rs`. It tells dory-hv which guest vsock
/// port to open without dory-hv parsing any application protocol.
public struct ForwardPreamble: Equatable, Sendable {
    public enum Direction: UInt8, Sendable {
        case guestToHost = 0
        case hostToGuest = 1
    }

    public var direction: Direction
    public var cid: UInt32
    public var port: UInt32

    static let bodyByteCount = 9

    public static func decode(_ bytes: [UInt8]) -> ForwardPreamble? {
        guard bytes.count == bodyByteCount, let direction = Direction(rawValue: bytes[0]) else {
            return nil
        }
        func le32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
        }
        return ForwardPreamble(direction: direction, cid: le32(1), port: le32(5))
    }

    /// Blocking read of the preamble frame from `fd`. Strict: the frame length must be exactly the
    /// preamble size — the only dialer is our own dataplane, so anything else is a protocol error,
    /// not something to tolerate.
    public static func read(from fd: Int32) -> ForwardPreamble? {
        read(from: fd, deadline: nil)
    }

    /// Applies one monotonic deadline to the complete length+body frame. A peer sending one byte
    /// before each socket receive timeout therefore cannot retain an admission slot indefinitely.
    static func read(from fd: Int32, timeout: TimeInterval) -> ForwardPreamble? {
        read(
            from: fd,
            deadline: ProcessInfo.processInfo.systemUptime + max(0, timeout)
        )
    }

    private static func read(from fd: Int32, deadline: TimeInterval?) -> ForwardPreamble? {
        guard let lengthBytes = readExactly(4, from: fd, deadline: deadline) else { return nil }
        let length = UInt32(lengthBytes[0]) | (UInt32(lengthBytes[1]) << 8)
            | (UInt32(lengthBytes[2]) << 16) | (UInt32(lengthBytes[3]) << 24)
        guard length == UInt32(bodyByteCount) else { return nil }
        guard let body = readExactly(bodyByteCount, from: fd, deadline: deadline) else { return nil }
        return decode(body)
    }

    private static func readExactly(
        _ count: Int,
        from fd: Int32,
        deadline: TimeInterval?
    ) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            if let deadline {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { return nil }
                let requestedMilliseconds = min(
                    ceil(remaining * 1_000),
                    Double(Int32.max)
                )
                var readiness = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(
                    &readiness,
                    1,
                    max(1, Int32(requestedMilliseconds))
                )
                if ready == 0 { return nil }
                if ready < 0 {
                    if errno == EINTR { continue }
                    return nil
                }
                if readiness.revents & Int16(POLLNVAL | POLLERR) != 0 { return nil }
            }
            let got = bytes.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
            }
            if got == 0 { return nil }
            if got < 0 {
                if errno == EINTR { continue }
                return nil
            }
            offset += got
        }
        return bytes
    }
}

/// Serves `--agent-vsock-forward`: the socket the Rust dataplane's `ForwardBackend` dials. Each
/// connection carries one `ForwardPreamble` naming the guest vsock port; dory-hv opens a fresh
/// guest stream to it and pumps raw bytes with full half-close fidelity. This is the docker-tier
/// half of the re-platform seam — dory-hv keeps the VMM and the vsock transport, the protocol
/// lives entirely in Rust on the other side of this socket.
public final class AgentVsockForward: @unchecked Sendable {
    private let socketPath: String
    private let guestCID: UInt32
    private let log: @Sendable (String) -> Void
    private let listener: BoundedVsockSocketListener

    /// A dialer that connects but never completes the preamble would otherwise pin a thread forever.
    private static let preambleTimeout: TimeInterval = 10

    public init(
        socketPath: String,
        guestCID: UInt32,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.socketPath = socketPath
        self.guestCID = guestCID
        self.log = log
        self.listener = BoundedVsockSocketListener(
            socketPath: socketPath,
            mode: 0o600,
            endpointLabel: "agent vsock forward",
            log: log
        )
    }

    /// The maximum UTF-8 byte length accepted by macOS for a filesystem Unix-domain socket path.
    public static let maximumSocketPathByteCount = VsockUnixRelay.maximumSocketPathByteCount

    /// Lets the engine reject an impossible configured path before it creates disks or sidecars.
    public static func validateSocketPath(_ socketPath: String) throws {
        try VsockUnixRelay.validateSocketPath(socketPath)
    }

    public func attach(to vsock: VirtioVsock) throws {
        let expectedCID = guestCID
        let logger = log
        try listener.attach(to: vsock, service: .agentForward) { client in
            guard let preamble = Self.readPreamble(client: client, log: logger) else {
                return nil
            }
            guard preamble.direction == .hostToGuest else {
                logger("agent vsock forward rejected a non-host-to-guest preamble")
                return nil
            }
            guard preamble.cid == expectedCID else {
                logger(
                    "agent vsock forward rejected cid \(preamble.cid) "
                        + "(guest is \(expectedCID))"
                )
                return nil
            }
            do {
                return try vsock.connectIfCapacity(port: preamble.port)
            } catch {
                logger(
                    "agent vsock forward rejected guest port \(preamble.port): \(error)"
                )
                return nil
            }
        }
        log("agent vsock forward serving \(socketPath)")
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

    private static func readPreamble(
        client: Int32,
        log: @Sendable (String) -> Void
    ) -> ForwardPreamble? {
        guard let preamble = ForwardPreamble.read(
            from: client,
            timeout: preambleTimeout
        ) else {
            log("agent vsock forward dropped a connection with a malformed preamble")
            return nil
        }
        return preamble
    }
}
