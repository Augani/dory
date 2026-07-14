import Darwin
import Foundation

public enum DoryHTTPProxyServerError: Error, Sendable, CustomStringConvertible {
    case invalidBindAddress(String)
    case syscall(String, Int32)

    public var description: String {
        switch self {
        case let .invalidBindAddress(address):
            return "invalid HTTP proxy bind address: \(address)"
        case let .syscall(name, code):
            return "\(name): \(String(cString: strerror(code)))"
        }
    }
}

public final class DoryHTTPProxyServer: @unchecked Sendable {
    private let bindAddress: String
    private let requestedPort: UInt16
    private let router: DomainRouter
    private let connectionBudget: DoryConnectionBudget
    private let lock = NSLock()
    private var routes: [DomainRoute]
    private var fd: Int32 = -1
    private var activePort: UInt16 = 0

    public init(
        bindAddress: String = "127.0.0.1",
        port: UInt16,
        router: DomainRouter = DomainRouter(),
        routes: [DomainRoute] = [],
        maximumConnections: Int = 256
    ) {
        self.bindAddress = bindAddress
        self.requestedPort = port
        self.router = router
        self.routes = routes
        self.connectionBudget = DoryConnectionBudget(limit: maximumConnections)
    }

    public var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return activePort
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fd >= 0
    }

    var activeConnectionCount: Int {
        connectionBudget.activeCount
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
        lock.lock()
        guard fd < 0 else {
            lock.unlock()
            return
        }
        lock.unlock()

        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw DoryHTTPProxyServerError.syscall("socket", errno)
        }

        do {
            var yes: Int32 = 1
            setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var address = try httpProxyIPv4SocketAddress(bindAddress: bindAddress, port: requestedPort)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                    Darwin.bind(socketFD, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else {
                throw DoryHTTPProxyServerError.syscall("bind", errno)
            }
            guard listen(socketFD, 64) == 0 else {
                throw DoryHTTPProxyServerError.syscall("listen", errno)
            }

            var actual = sockaddr_in()
            var actualLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let gotName = withUnsafeMutablePointer(to: &actual) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                    getsockname(socketFD, raw, &actualLength)
                }
            }
            guard gotName == 0 else {
                throw DoryHTTPProxyServerError.syscall("getsockname", errno)
            }

            lock.lock()
            fd = socketFD
            activePort = UInt16(bigEndian: actual.sin_port)
            lock.unlock()

            Thread.detachNewThread { [weak self] in
                self?.acceptLoop(socketFD)
            }
        } catch {
            close(socketFD)
            throw error
        }
    }

    public func stop() {
        lock.lock()
        let currentFD = fd
        fd = -1
        activePort = 0
        lock.unlock()
        if currentFD >= 0 {
            shutdown(currentFD, SHUT_RDWR)
            close(currentFD)
        }
    }

    private func acceptLoop(_ socketFD: Int32) {
        while true {
            lock.lock()
            let running = fd == socketFD
            lock.unlock()
            guard running else { return }

            let client = accept(socketFD, nil, nil)
            if client < 0 {
                switch errno {
                case EINTR, ECONNABORTED, EAGAIN, EWOULDBLOCK:
                    continue
                case EMFILE, ENFILE:
                    // fd table exhausted: back off rather than tearing down the listener.
                    usleep(50_000)
                    continue
                default:
                    return
                }
            }
            guard let lease = connectionBudget.tryAcquire() else {
                shutdown(client, SHUT_RDWR)
                close(client)
                continue
            }
            // Bound the header read so a client that connects and never speaks cannot
            // pin a handler thread forever.
            var headerTimeout = timeval(tv_sec: 15, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &headerTimeout, socklen_t(MemoryLayout<timeval>.size))
            Thread.detachNewThread { [weak self, lease] in
                guard let self else {
                    shutdown(client, SHUT_RDWR)
                    close(client)
                    lease.release()
                    return
                }
                self.handle(client, lease: lease)
            }
        }
    }

    private func handle(_ client: Int32, lease: DoryConnectionLease) {
        var relayOwnsLease = false
        defer {
            if !relayOwnsLease {
                lease.release()
            }
        }
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        for _ in 0..<64 {
            if Self.headerRange(in: buffer) != nil { break }
            if buffer.count > 65_536 { break }
            let count = bytes.withUnsafeMutableBytes { read(client, $0.baseAddress, 16 * 1024) }
            if count <= 0 { break }
            buffer.append(contentsOf: bytes[0..<count])
        }

        guard let host = Self.hostHeader(buffer), let route = route(for: host) else {
            writeBadGateway(client, body: "Dory: no backend for that domain\n")
            return
        }
        guard let upstream = DoryTCP.connect(host: route.address, port: route.port) else {
            writeBadGateway(client, body: "Dory: backend unavailable\n")
            return
        }
        let request = route.pathPrefix.isEmpty ? buffer : Self.rewriteRequest(buffer, pathPrefix: route.pathPrefix)
        guard (try? DoryTCP.writeAll(upstream, request)) != nil else {
            shutdown(upstream, SHUT_RDWR)
            close(upstream)
            writeBadGateway(client, body: "Dory: backend unavailable\n")
            return
        }
        // Relays get a generous idle timeout on both ends so a wedged connection is
        // eventually reclaimed instead of leaking a pump thread and its fds forever.
        DoryTCP.configureRelayTimeout(client)
        DoryTCP.configureRelayTimeout(upstream)
        DoryTCP.bidirectionalCopy(
            client: client,
            upstream: upstream,
            onClose: { lease.release() }
        )
        relayOwnsLease = true
    }

    private func route(for host: String) -> DomainRoute? {
        let normalized = DomainRouter.normalize(host)
        lock.lock()
        let currentRoutes = routes
        lock.unlock()
        return currentRoutes.first { route in
            let hostname = DomainRouter.normalize(route.hostname)
            return hostname == normalized
                && (router.owns(hostname) || Self.isLoopbackHost(hostname))
                && IPv4Address(route.address) != nil
        }
    }

    private func writeBadGateway(_ client: Int32, body: String) {
        let data = Data(("HTTP/1.1 502 Bad Gateway\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)").utf8)
        try? DoryTCP.writeAll(client, data)
        shutdown(client, SHUT_RDWR)
        close(client)
    }

    public static func hostHeader(_ data: Data) -> String? {
        guard let range = headerRange(in: data),
              let text = String(data: data.subdata(in: data.startIndex..<range.lowerBound), encoding: .utf8) else {
            return nil
        }
        for line in text.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "host" else {
                continue
            }
            let value = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            if value.hasPrefix("[") {
                return value
            }
            return value.split(separator: ":").first.map(String.init) ?? value
        }
        return nil
    }

    public static func rewriteRequest(_ data: Data, pathPrefix: String) -> Data {
        guard !pathPrefix.isEmpty,
              let range = headerRange(in: data) else {
            return data
        }
        let head = data.subdata(in: data.startIndex..<range.lowerBound)
        let rest = data.subdata(in: range.lowerBound..<data.endIndex)
        guard let text = String(data: head, encoding: .utf8) else { return data }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return data }
        let parts = lines[0].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return data }
        let path = String(parts[1])
        lines[0] = "\(parts[0]) \(pathPrefix)\(path) \(parts[2])"
        var output = Data(lines.joined(separator: "\r\n").utf8)
        output.append(rest)
        return output
    }

    public static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = DomainRouter.normalize(host)
        return normalized == "localhost"
            || normalized == "127.0.0.1"
            || normalized == "::1"
            || normalized == "[::1]"
    }

    private static func headerRange(in data: Data) -> Range<Data.Index>? {
        data.range(of: Data([13, 10, 13, 10]))
    }

    deinit {
        stop()
    }
}

private func httpProxyIPv4SocketAddress(bindAddress: String, port: UInt16) throws -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    guard inet_pton(AF_INET, bindAddress, &address.sin_addr) == 1 else {
        throw DoryHTTPProxyServerError.invalidBindAddress(bindAddress)
    }
    return address
}

enum DoryTCP {
    static func configureRelayTimeout(_ fd: Int32, seconds: Int = 300) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    static func connect(host: String, port: UInt16, timeout: TimeInterval = 10) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            close(fd)
            return nil
        }
        // Non-blocking connect with a deadline so an unresponsive backend cannot hang
        // the handler indefinitely.
        let originalFlags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.connect(fd, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else {
                close(fd)
                return nil
            }
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let milliseconds = Int32(max(0, min(timeout, 86_400)) * 1000)
            let ready = poll(&pollDescriptor, 1, milliseconds)
            guard ready > 0 else {
                close(fd)
                return nil
            }
            var socketError: Int32 = 0
            var errorLength = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) == 0,
                  socketError == 0 else {
                close(fd)
                return nil
            }
        }
        _ = fcntl(fd, F_SETFL, originalFlags)
        return fd
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base.advanced(by: offset), raw.count - offset)
                if written <= 0 {
                    throw DoryHTTPProxyServerError.syscall("write", errno)
                }
                offset += written
            }
        }
    }

    private final class ProxyConnection: @unchecked Sendable {
        private let lock = NSLock()
        private let client: Int32
        private let upstream: Int32
        private let onClose: @Sendable () -> Void
        private var finished = 0
        private var closed = false

        init(client: Int32, upstream: Int32, onClose: @escaping @Sendable () -> Void) {
            self.client = client
            self.upstream = upstream
            self.onClose = onClose
        }

        func clientPumpFinished() {
            shutdown(upstream, SHUT_WR)
            settle()
        }

        func upstreamPumpFinished() {
            shutdown(client, SHUT_RDWR)
            shutdown(upstream, SHUT_RDWR)
            settle()
        }

        private func settle() {
            lock.lock()
            finished += 1
            let shouldClose = finished >= 2 && !closed
            if shouldClose {
                closed = true
            }
            lock.unlock()
            if shouldClose {
                close(client)
                close(upstream)
                onClose()
            }
        }
    }

    static func bidirectionalCopy(
        client: Int32,
        upstream: Int32,
        onClose: @escaping @Sendable () -> Void = {}
    ) {
        let connection = ProxyConnection(client: client, upstream: upstream, onClose: onClose)
        func pump(_ from: Int32, _ to: Int32, onFinish: @escaping @Sendable () -> Void) {
            Thread.detachNewThread {
                var buffer = [UInt8](repeating: 0, count: 32 * 1024)
                while true {
                    let count = buffer.withUnsafeMutableBytes { read(from, $0.baseAddress, 32 * 1024) }
                    if count <= 0 { break }
                    var offset = 0
                    var ok = true
                    while offset < count {
                        let written = buffer.withUnsafeBytes {
                            write(to, $0.baseAddress!.advanced(by: offset), count - offset)
                        }
                        if written <= 0 {
                            ok = false
                            break
                        }
                        offset += written
                    }
                    if !ok { break }
                }
                onFinish()
            }
        }
        pump(client, upstream, onFinish: { connection.clientPumpFinished() })
        pump(upstream, client, onFinish: { connection.upstreamPumpFinished() })
    }
}

final class DoryConnectionBudget: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var count = 0

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func tryAcquire() -> DoryConnectionLease? {
        lock.lock()
        guard count < limit else {
            lock.unlock()
            return nil
        }
        count += 1
        lock.unlock()
        return DoryConnectionLease(budget: self)
    }

    fileprivate func release() {
        lock.lock()
        count = max(0, count - 1)
        lock.unlock()
    }
}

final class DoryConnectionLease: @unchecked Sendable {
    private let lock = NSLock()
    private weak var budget: DoryConnectionBudget?
    private var released = false

    fileprivate init(budget: DoryConnectionBudget) {
        self.budget = budget
    }

    func release() {
        lock.lock()
        let shouldRelease = !released
        released = true
        let budget = shouldRelease ? budget : nil
        lock.unlock()
        budget?.release()
    }

    deinit {
        release()
    }
}
