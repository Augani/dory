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
        guard let lengthBytes = readExactly(4, from: fd) else { return nil }
        let length = UInt32(lengthBytes[0]) | (UInt32(lengthBytes[1]) << 8)
            | (UInt32(lengthBytes[2]) << 16) | (UInt32(lengthBytes[3]) << 24)
        guard length == UInt32(bodyByteCount) else { return nil }
        guard let body = readExactly(bodyByteCount, from: fd) else { return nil }
        return decode(body)
    }

    private static func readExactly(_ count: Int, from fd: Int32) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
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

    /// A dialer that connects but never completes the preamble would otherwise pin a thread forever.
    private static let preambleTimeout = timeval(tv_sec: 10, tv_usec: 0)

    public init(socketPath: String, guestCID: UInt32, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.socketPath = socketPath
        self.guestCID = guestCID
        self.log = log
    }

    private final class VsockBox: @unchecked Sendable {
        let vsock: VirtioVsock
        init(_ vsock: VirtioVsock) { self.vsock = vsock }
    }

    public func attach(to vsock: VirtioVsock) {
        guard let listener = VsockUnixRelay.makeListener(socketPath: socketPath, mode: 0o600) else {
            log("agent vsock forward could not listen on \(socketPath)")
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
                    log("agent vsock forward accept failed on \(path): errno \(errno)")
                    break
                }
                var noSigpipe: Int32 = 1
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
                Thread.detachNewThread {
                    self.serve(client: client, box: box)
                }
            }
            close(listener)
        }
        log("agent vsock forward serving \(socketPath)")
    }

    private func serve(client: Int32, box: VsockBox) {
        guard let preamble = readPreamble(client: client) else {
            close(client)
            return
        }
        guard preamble.direction == .hostToGuest else {
            log("agent vsock forward rejected a non-host-to-guest preamble")
            close(client)
            return
        }
        guard preamble.cid == guestCID else {
            log("agent vsock forward rejected cid \(preamble.cid) (guest is \(guestCID))")
            close(client)
            return
        }
        VsockUnixRelay.serve(client: client, connection: box.vsock.connect(port: preamble.port))
    }

    private func readPreamble(client: Int32) -> ForwardPreamble? {
        var timeout = Self.preambleTimeout
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        defer {
            var forever = timeval(tv_sec: 0, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &forever, socklen_t(MemoryLayout<timeval>.size))
        }
        guard let preamble = ForwardPreamble.read(from: client) else {
            log("agent vsock forward dropped a connection with a malformed preamble")
            return nil
        }
        return preamble
    }
}
