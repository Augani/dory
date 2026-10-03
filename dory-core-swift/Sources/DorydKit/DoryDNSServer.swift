import Darwin
import Foundation

public enum DoryDNSServerError: Error, Sendable, CustomStringConvertible {
    case invalidBindAddress(String)
    case syscall(String, Int32)

    public var description: String {
        switch self {
        case let .invalidBindAddress(address):
            return "invalid DNS bind address: \(address)"
        case let .syscall(name, code):
            return "\(name): \(String(cString: strerror(code)))"
        }
    }
}

public final class DoryDNSServer: @unchecked Sendable {
    private let bindAddress: String
    private let requestedPort: UInt16
    private let router: DomainRouter
    private let lifecycleLock = NSLock()
    private let lock = NSLock()
    private var routes: [DomainRoute]
    private var listener: DoryDNSListener?
    private let queueKey = DispatchSpecificKey<UUID>()
    private var beforeResponsePublication: (@Sendable () -> Void)?
    private var activePort: UInt16 = 0

    public init(
        bindAddress: String = "127.0.0.1",
        port: UInt16,
        router: DomainRouter = DomainRouter(),
        routes: [DomainRoute] = []
    ) {
        self.bindAddress = bindAddress
        self.requestedPort = port
        self.router = router
        self.routes = routes
    }

    /// Isolated transport timing seam; public callers never supply a host callback.
    convenience init(
        bindAddress: String = "127.0.0.1",
        port: UInt16,
        router: DomainRouter = DomainRouter(),
        routes: [DomainRoute] = [],
        beforeResponsePublication: @escaping @Sendable () -> Void
    ) {
        self.init(bindAddress: bindAddress, port: port, router: router, routes: routes)
        self.beforeResponsePublication = beforeResponsePublication
    }

    public var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return activePort
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listener?.isActive == true
    }

    public func updateRoutes(_ routes: [DomainRoute]) {
        lock.lock()
        self.routes = routes
        lock.unlock()
    }

    public func currentRoutes() -> [DomainRoute] {
        lock.lock()
        defer { lock.unlock() }
        return routes
    }

    public func start() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        lock.lock()
        guard listener == nil else {
            lock.unlock()
            return
        }
        lock.unlock()

        let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard socketFD >= 0 else {
            throw DoryDNSServerError.syscall("socket", errno)
        }

        do {
            var yes: Int32 = 1
            setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var address = try ipv4SocketAddress(bindAddress: bindAddress, port: requestedPort)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                    Darwin.bind(socketFD, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else {
                throw DoryDNSServerError.syscall("bind", errno)
            }

            var actual = sockaddr_in()
            var actualLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let gotName = withUnsafeMutablePointer(to: &actual) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                    getsockname(socketFD, raw, &actualLength)
                }
            }
            guard gotName == 0 else {
                throw DoryDNSServerError.syscall("getsockname", errno)
            }
            let flags = fcntl(socketFD, F_GETFL, 0)
            guard flags >= 0, fcntl(socketFD, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw DoryDNSServerError.syscall("fcntl(O_NONBLOCK)", errno)
            }

            let listener = DoryDNSListener(socketFD)
            let queue = DispatchQueue(label: "dev.dory.doryd.dns.\(listener.id)")
            queue.setSpecific(key: queueKey, value: listener.id)
            lock.lock()
            self.listener = listener
            activePort = UInt16(bigEndian: actual.sin_port)
            lock.unlock()

            queue.async { [weak self, listener] in
                defer {
                    listener.workerFinished()
                    self?.listenerRetired(listener)
                }
                // Do not retain the server across an idle poll. Its deinit must be able to
                // revoke the worker even when nobody sends another DNS datagram.
                Self.serveLoop(listener) { [weak self] packet in
                    guard let self else { listener.cancel(); return nil }
                    let response = self.response(for: packet, listener: listener)
                    if response != nil { self.beforeResponsePublication?() }
                    return response
                }
            }
        } catch {
            close(socketFD)
            throw error
        }
    }

    public func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        lock.lock()
        let current = listener
        listener = nil
        activePort = 0
        lock.unlock()
        current?.cancel()
        // Cancellation-aware poll bounds the idle join; only the worker closes its fd.
        // A final server reference may be released inside its own response callback.
        if let current, DispatchQueue.getSpecific(key: queueKey) != current.id {
            current.waitForRetirement()
        }
    }

    private func listenerRetired(_ retired: DoryDNSListener) {
        lock.withLock {
            guard listener === retired else { return }
            listener = nil
            activePort = 0
        }
    }

    private static func serveLoop(
        _ listener: DoryDNSListener,
        response: ([UInt8]) -> [UInt8]?
    ) {
        let socketFD = listener.descriptor
        var buffer = [UInt8](repeating: 0, count: 512)
        while listener.isActive {
            var ready = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
            let polled = poll(&ready, 1, 50)
            guard listener.isActive else { return }
            if polled < 0 {
                if errno == EINTR { continue }
                return
            }
            guard polled > 0 else { continue }
            guard ready.revents & Int16(POLLIN | POLLERR) != 0 else {
                if ready.revents & Int16(POLLHUP | POLLNVAL) != 0 { return }
                continue
            }

            var peer = sockaddr_storage()
            var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rawPeer in
                    let capacity = buffer.count
                    return buffer.withUnsafeMutableBytes { rawBuffer in
                        recvfrom(socketFD, rawBuffer.baseAddress!, capacity, 0, rawPeer, &peerLength)
                    }
                }
            }
            if count < 0 {
                let code = errno
                switch code {
                case EINTR, EAGAIN, EWOULDBLOCK, ECONNREFUSED, ECONNABORTED:
                    // Transient: a prior sendto eliciting ICMP unreachable, or an
                    // interrupted/again read. Keep serving instead of dropping DNS.
                    continue
                case EMFILE, ENFILE:
                    // fd table exhausted: back off briefly rather than exit.
                    usleep(50_000)
                    continue
                default:
                    return
                }
            }
            guard count > 0 else { continue }
            let packet = Array(buffer.prefix(count))
            guard let reply = response(packet) else { continue }
            listener.withActiveDescriptor { descriptor in
                withUnsafePointer(to: &peer) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rawPeer in
                        reply.withUnsafeBytes { rawResponse in
                            _ = sendto(descriptor, rawResponse.baseAddress!, reply.count, 0, rawPeer, peerLength)
                        }
                    }
                }
            }
        }
    }

    private func response(for packet: [UInt8], listener: DoryDNSListener) -> [UInt8]? {
        guard let query = DNSQuery(packet) else { return nil }
        lock.lock()
        guard self.listener === listener, listener.isActive else { lock.unlock(); return nil }
        let currentRoutes = routes
        lock.unlock()
        let routeAddress = router.resolve(query.hostname, in: currentRoutes).flatMap(IPv4Address.init)
        let responseCode: UInt16
        if query.qclass != 1 {
            responseCode = 5
        } else {
            responseCode = routeAddress == nil ? 3 : 0
        }
        let answer = query.qclass == 1 && query.qtype == 1 ? routeAddress : nil
        return DNSResponse(query: query, address: answer, responseCode: responseCode).bytes
    }

    deinit {
        stop()
    }
}

/// A per-start UDP owner. Revocation never closes a descriptor underneath recvfrom/sendto;
/// worker retirement is the only close edge, and all stop callers can join the same owner.
final class DoryDNSListener: @unchecked Sendable {
    let id = UUID()
    let descriptor: Int32
    private let lock = NSLock()
    private let retired = DispatchGroup()
    private var cancelled = false
    private var closed = false

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
        retired.enter()
    }

    var isActive: Bool { lock.withLock { !cancelled && !closed } }

    func cancel() { lock.withLock { cancelled = true } }

    func withActiveDescriptor(_ operation: (Int32) -> Void) {
        lock.withLock {
            guard !cancelled, !closed else { return }
            operation(descriptor)
        }
    }

    func workerFinished() {
        let finished = lock.withLock {
            guard !closed else { return false }
            closed = true
            close(descriptor)
            return true
        }
        if finished { retired.leave() }
    }

    func waitForRetirement() { retired.wait() }

    deinit { workerFinished() }
}

private struct DNSQuery {
    var id: UInt16
    var flags: UInt16
    var question: [UInt8]
    var hostname: String
    var qtype: UInt16
    var qclass: UInt16

    init?(_ packet: [UInt8]) {
        guard packet.count >= 12 else { return nil }
        id = readUInt16(packet, 0)
        flags = readUInt16(packet, 2)
        guard flags & 0x8000 == 0,
              flags & 0x7800 == 0,
              readUInt16(packet, 4) == 1 else {
            return nil
        }

        var offset = 12
        var labels: [String] = []
        while offset < packet.count {
            let length = Int(packet[offset])
            offset += 1
            if length == 0 { break }
            guard length < 64, offset + length <= packet.count else { return nil }
            labels.append(String(decoding: packet[offset..<offset + length], as: UTF8.self))
            offset += length
        }
        guard offset + 4 <= packet.count else { return nil }
        qtype = readUInt16(packet, offset)
        qclass = readUInt16(packet, offset + 2)
        question = Array(packet[12..<offset + 4])
        hostname = labels.joined(separator: ".")
    }
}

private struct DNSResponse {
    var query: DNSQuery
    var address: IPv4Address?
    var responseCode: UInt16

    var bytes: [UInt8] {
        var out: [UInt8] = []
        appendUInt16(query.id, to: &out)
        appendUInt16(0x8000 | (query.flags & 0x0100) | 0x0080 | responseCode, to: &out)
        appendUInt16(1, to: &out)
        appendUInt16(address == nil ? 0 : 1, to: &out)
        appendUInt16(0, to: &out)
        appendUInt16(0, to: &out)
        out.append(contentsOf: query.question)

        if let address {
            appendUInt16(0xC00C, to: &out)
            appendUInt16(1, to: &out)
            appendUInt16(1, to: &out)
            appendUInt32(30, to: &out)
            appendUInt16(4, to: &out)
            out.append(contentsOf: address.bytes)
        }
        return out
    }
}

private func ipv4SocketAddress(bindAddress: String, port: UInt16) throws -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    guard inet_pton(AF_INET, bindAddress, &address.sin_addr) == 1 else {
        throw DoryDNSServerError.invalidBindAddress(bindAddress)
    }
    return address
}

private func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
}

private func appendUInt16(_ value: UInt16, to bytes: inout [UInt8]) {
    bytes.append(UInt8((value >> 8) & 0xff))
    bytes.append(UInt8(value & 0xff))
}

private func appendUInt32(_ value: UInt32, to bytes: inout [UInt8]) {
    bytes.append(UInt8((value >> 24) & 0xff))
    bytes.append(UInt8((value >> 16) & 0xff))
    bytes.append(UInt8((value >> 8) & 0xff))
    bytes.append(UInt8(value & 0xff))
}
