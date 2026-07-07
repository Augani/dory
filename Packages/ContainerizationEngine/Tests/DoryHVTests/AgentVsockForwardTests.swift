import Darwin
import Foundation
import Testing
@testable import DoryHV

@Suite struct AgentVsockForwardTests {
    @Test func preambleDecodesTheRustWireShape() {
        // direction(1) + cid(4 LE) + port(4 LE), exactly what dory-proto's Preamble::encode emits.
        let bytes: [UInt8] = [1, 3, 0, 0, 0, 0x02, 0x04, 0, 0]
        let preamble = ForwardPreamble.decode(bytes)
        #expect(preamble == ForwardPreamble(direction: .hostToGuest, cid: 3, port: 1026))
    }

    @Test func preambleRejectsWrongLengthAndUnknownDirection() {
        #expect(ForwardPreamble.decode([1, 3, 0, 0]) == nil)
        #expect(ForwardPreamble.decode([1, 3, 0, 0, 0, 0x02, 0x04, 0, 0, 0]) == nil)
        #expect(ForwardPreamble.decode([7, 3, 0, 0, 0, 0x02, 0x04, 0, 0]) == nil)
    }

    @Test func preambleReadsAFramedMessageFromAnFd() {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }

        let frame: [UInt8] = [9, 0, 0, 0] + [1, 3, 0, 0, 0, 0x02, 0x04, 0, 0]
        #expect(frame.withUnsafeBytes { write(fds[0], $0.baseAddress, $0.count) } == frame.count)
        #expect(ForwardPreamble.read(from: fds[1]) == ForwardPreamble(direction: .hostToGuest, cid: 3, port: 1026))
    }

    @Test func preambleReadRejectsAWrongLengthFrame() {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }

        let frame: [UInt8] = [3, 0, 0, 0] + [1, 3, 0]
        _ = frame.withUnsafeBytes { write(fds[0], $0.baseAddress, $0.count) }
        shutdown(fds[0], SHUT_WR)
        #expect(ForwardPreamble.read(from: fds[1]) == nil)
    }

    /// The full docker-tier relay in-process: a client dials the forward socket, sends the preamble
    /// plus a request and half-closes; a fake guest dockerd (driving VirtioVsock's guest side)
    /// receives the request bytes after the host's SEND-only shutdown, streams a reply, and
    /// full-closes — the client must read the entire reply then see EOF.
    @Test func forwardRelaysPreambleNamedStreamWithHalfClose() throws {
        let device = VirtioVsock(guestCID: 3)
        let path = temporarySocketPath()
        defer { unlink(path) }
        AgentVsockForward(socketPath: path, guestCID: 3).attach(to: device)

        let guest = FakeGuestEcho(device: device, expect: [UInt8]("ping".utf8), reply: [UInt8]("pong".utf8))
        guest.start()
        defer { guest.stop() }

        let client = try connectUnix(path)
        defer { close(client) }
        let preambleFrame: [UInt8] = [9, 0, 0, 0] + [1, 3, 0, 0, 0, 0x02, 0x04, 0, 0]
        #expect(writeAll(client, preambleFrame + [UInt8]("ping".utf8)))
        shutdown(client, SHUT_WR)

        let received = readToEOF(client)
        #expect(received == [UInt8]("pong".utf8))
        #expect(guest.observedPort == 1026)
        #expect(guest.sawHostSendShutdown)
    }

    @Test func forwardRefusesAPreambleForAnotherGuest() throws {
        let device = VirtioVsock(guestCID: 3)
        let path = temporarySocketPath()
        defer { unlink(path) }
        AgentVsockForward(socketPath: path, guestCID: 3).attach(to: device)

        let client = try connectUnix(path)
        defer { close(client) }
        let preambleFrame: [UInt8] = [9, 0, 0, 0] + [1, 9, 0, 0, 0, 0x02, 0x04, 0, 0]
        #expect(writeAll(client, preambleFrame))

        #expect(readToEOF(client).isEmpty)
        #expect(device.drainPendingGuestPackets().isEmpty)
    }

    @Test func forwardRefusesAGuestToHostPreamble() throws {
        let device = VirtioVsock(guestCID: 3)
        let path = temporarySocketPath()
        defer { unlink(path) }
        AgentVsockForward(socketPath: path, guestCID: 3).attach(to: device)

        let client = try connectUnix(path)
        defer { close(client) }
        let preambleFrame: [UInt8] = [9, 0, 0, 0] + [0, 3, 0, 0, 0, 0x02, 0x04, 0, 0]
        #expect(writeAll(client, preambleFrame))

        #expect(readToEOF(client).isEmpty)
        #expect(device.drainPendingGuestPackets().isEmpty)
    }
}

/// Drives the guest half of a VirtioVsock in-process: answers the host's connection request,
/// collects request bytes, and once the host half-closes with the expected payload received,
/// streams the reply and full-closes — the shape of dockerd answering a docker CLI request.
private final class FakeGuestEcho: @unchecked Sendable {
    private let device: VirtioVsock
    private let expect: [UInt8]
    private let reply: [UInt8]
    private let lock = NSLock()
    private var stopped = false
    private var port: UInt32 = 0
    private var sawSendShutdown = false

    init(device: VirtioVsock, expect: [UInt8], reply: [UInt8]) {
        self.device = device
        self.expect = expect
        self.reply = reply
    }

    var observedPort: UInt32 { lock.lock(); defer { lock.unlock() }; return port }
    var sawHostSendShutdown: Bool { lock.lock(); defer { lock.unlock() }; return sawSendShutdown }

    func start() {
        Thread.detachNewThread { [self] in
            var collected = [UInt8]()
            var hostPort: UInt32 = 0
            var guestPort: UInt32 = 0
            var hostDoneSending = false
            var replied = false
            while !isStopped() {
                for packet in device.drainPendingGuestPackets() {
                    guard let header = try? VirtioVsockHeader(decoding: packet.prefix(VirtioVsockHeader.byteCount)) else { continue }
                    let payload = Array(packet.dropFirst(VirtioVsockHeader.byteCount))
                    switch header.operation {
                    case .request:
                        hostPort = header.sourcePort
                        guestPort = header.destinationPort
                        lock.lock(); port = guestPort; lock.unlock()
                        inject(operation: .response, guestPort: guestPort, hostPort: hostPort)
                    case .readWrite:
                        collected.append(contentsOf: payload)
                    case .shutdown:
                        if header.flags & 2 != 0 {
                            hostDoneSending = true
                            lock.lock(); sawSendShutdown = true; lock.unlock()
                        }
                    default:
                        break
                    }
                }
                if hostDoneSending && collected == expect && !replied {
                    replied = true
                    inject(operation: .readWrite, guestPort: guestPort, hostPort: hostPort, payload: reply)
                    inject(operation: .shutdown, guestPort: guestPort, hostPort: hostPort, flags: 3)
                }
                usleep(1000)
            }
        }
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    private func isStopped() -> Bool {
        lock.lock(); defer { lock.unlock() }; return stopped
    }

    private func inject(
        operation: VirtioVsockHeader.Operation,
        guestPort: UInt32,
        hostPort: UInt32,
        payload: [UInt8] = [],
        flags: UInt32 = 0
    ) {
        let header = VirtioVsockHeader(
            sourceCID: 3,
            destinationCID: 2,
            sourcePort: guestPort,
            destinationPort: hostPort,
            length: UInt32(payload.count),
            operation: operation,
            flags: flags
        )
        _ = try? device.receive(packet: header.encoded() + payload)
    }
}

private func temporarySocketPath() -> String {
    "\(NSTemporaryDirectory())fwd-\(getpid())-\(UInt32.random(in: 0..<UInt32.max)).sock"
}

private func connectUnix(_ path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(fd >= 0)
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSigpipe: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        let bytes = [UInt8](path.utf8.prefix(destination.count - 1))
        destination.copyBytes(from: bytes)
    }
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else {
        close(fd)
        try #require(Bool(false), "connect to \(path) failed: errno \(errno)")
        fatalError()
    }
    return fd
}

private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeBytes {
            write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset)
        }
        if written <= 0 {
            if written < 0 && errno == EINTR { continue }
            return false
        }
        offset += written
    }
    return true
}

private func readToEOF(_ fd: Int32) -> [UInt8] {
    var collected = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let capacity = buffer.count
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, capacity) }
        if count > 0 {
            collected.append(contentsOf: buffer.prefix(count))
            continue
        }
        if count < 0 && errno == EINTR { continue }
        return collected
    }
}
