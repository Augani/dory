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
    private let lifecycleLock = NSLock()
    private let lock = NSLock()
    private var routes: [DomainRoute]
    private var listener: DoryTCPListener?
    private var generation: UUID?
    private var connections: [UUID: DoryTCPConnection] = [:]
    private var connectionRoutes: [UUID: (hostname: String, route: DomainRoute)] = [:]
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
        return listener?.isActive == true
    }

    var activeConnectionCount: Int {
        connectionBudget.activeCount
    }

    public func updateRoutes(_ routes: [DomainRoute]) {
        lock.lock()
        self.routes = routes
        let revoked = connectionRoutes.compactMap { id, bound -> DoryTCPConnection? in
            routeLocked(for: bound.hostname) == bound.route ? nil : connections[id]
        }
        lock.unlock()
        for connection in revoked { connection.cancel() }
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

            let listener = DoryTCPListener(socketFD)
            let generation = UUID()
            lock.lock()
            self.listener = listener
            self.generation = generation
            activePort = UInt16(bigEndian: actual.sin_port)
            lock.unlock()

            Thread.detachNewThread { [weak self, listener] in
                defer { listener.acceptWorkerFinished() }
                while self?.accepts(listener, generation: generation) == true {
                    let client = accept(listener.descriptor, nil, nil)
                    if client < 0 {
                        switch errno {
                        case EINTR, ECONNABORTED, EAGAIN, EWOULDBLOCK: continue
                        case EMFILE, ENFILE: usleep(50_000); continue
                        default: return
                        }
                    }
                    guard let self else {
                        shutdown(client, SHUT_RDWR)
                        close(client)
                        return
                    }
                    self.admit(client, listener: listener, generation: generation)
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
        let active = Array(connections.values)
        listener = nil
        generation = nil
        activePort = 0
        lock.unlock()
        current?.cancel()
        for connection in active { connection.cancel() }
    }

    private func accepts(_ listener: DoryTCPListener, generation: UUID) -> Bool {
        lock.withLock { self.listener === listener && self.generation == generation }
    }

    private func admit(_ client: Int32, listener: DoryTCPListener, generation: UUID) {
        guard let lease = connectionBudget.tryAcquire() else {
            shutdown(client, SHUT_RDWR)
            close(client)
            return
        }
        let connection = DoryTCPConnection(client: client) { [weak self, lease] id in
            if let self {
                self.lock.withLock {
                    self.connections.removeValue(forKey: id)
                    self.connectionRoutes.removeValue(forKey: id)
                }
            }
            lease.release()
        }
        let admitted = lock.withLock {
            guard self.listener === listener, self.generation == generation else { return false }
            connections[connection.id] = connection
            return true
        }
        guard admitted else { connection.cancel(); connection.workerFinished(); return }
        var headerTimeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &headerTimeout, socklen_t(MemoryLayout<timeval>.size))
        Thread.detachNewThread { [weak self, connection] in
            defer { connection.workerFinished() }
            guard let self, connection.isActive else { return }
            self.handle(connection)
        }
    }

    private func handle(_ connection: DoryTCPConnection) {
        let client = connection.client
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        for _ in 0..<64 {
            guard connection.isActive else { return }
            if Self.headerRange(in: buffer) != nil { break }
            if buffer.count > 65_536 { break }
            let count = bytes.withUnsafeMutableBytes { read(client, $0.baseAddress, 16 * 1024) }
            if count <= 0 { break }
            buffer.append(contentsOf: bytes[0..<count])
        }

        guard let host = Self.hostHeader(buffer), let route = bindRoute(for: host, connection: connection) else {
            writeBadGateway(connection, body: "Dory: no backend for that domain\n")
            return
        }
        guard let upstream = DoryTCP.connect(
            host: route.address, port: route.port, connection: connection
        ) else {
            writeBadGateway(connection, body: "Dory: backend unavailable\n")
            return
        }
        DoryTCP.configureRelayTimeout(client)
        DoryTCP.configureRelayTimeout(upstream)
        let request = route.pathPrefix.isEmpty ? buffer : Self.rewriteRequest(buffer, pathPrefix: route.pathPrefix)
        guard (try? DoryTCP.writeAll(upstream, request)) != nil else {
            writeBadGateway(connection, body: "Dory: backend unavailable\n")
            return
        }
        DoryTCP.bidirectionalCopy(connection: connection)
    }

    private func bindRoute(for host: String, connection: DoryTCPConnection) -> DomainRoute? {
        lock.withLock {
            guard connections[connection.id] === connection, connection.isActive,
                  let route = routeLocked(for: host) else { return nil }
            connectionRoutes[connection.id] = (DomainRouter.normalize(host), route)
            return route
        }
    }

    /// Called only under the server state lock, including when checking a live route lease.
    private func routeLocked(for host: String) -> DomainRoute? {
        let normalized = DomainRouter.normalize(host)
        return routes.compactMap { route -> (specificity: Int, route: DomainRoute)? in
            let hostname = DomainRouter.normalize(route.hostname)
            guard let specificity = DomainRouter.matchSpecificity(pattern: hostname, hostname: normalized),
                  router.owns(hostname)
                    || Self.isLoopbackHost(hostname)
                    || DomainRouter.isValidHostnamePattern(hostname),
                  IPv4Address(route.address) != nil else {
                return nil
            }
            return (specificity, route)
        }.max { $0.specificity < $1.specificity }?.route
    }

    private func writeBadGateway(_ connection: DoryTCPConnection, body: String) {
        guard connection.isActive else { return }
        let data = Data(("HTTP/1.1 502 Bad Gateway\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)").utf8)
        try? DoryTCP.writeAll(connection.client, data)
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
    static func configureNoSignal(_ fd: Int32) {
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    static func configureRelayTimeout(_ fd: Int32, seconds: Int = 300) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    static func connect(
        host: String, port: UInt16, timeout: TimeInterval = 10,
        connection: (any DoryTCPUpstreamOwnership)? = nil
    ) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        if let connection, !connection.adoptUpstream(fd) {
            close(fd)
            return nil
        }
        configureNoSignal(fd)
        var connected = false
        defer { if !connected, connection == nil { close(fd) } }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            return nil
        }
        // Non-blocking connect with a deadline so an unresponsive backend cannot hang
        // the handler indefinitely.
        let originalFlags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)
        let connectSocket = {
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                    Darwin.connect(fd, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        let result: Int32
        if let connection {
            guard let admittedResult = connection.performConnect(connectSocket) else { return nil }
            result = admittedResult
        } else {
            result = connectSocket()
        }
        if result != 0 {
            guard errno == EINPROGRESS else {
                return nil
            }
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let milliseconds = Int32(max(0, min(timeout, 86_400)) * 1000)
            let ready = poll(&pollDescriptor, 1, milliseconds)
            guard ready > 0 else {
                return nil
            }
            var socketError: Int32 = 0
            var errorLength = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) == 0,
                  socketError == 0 else {
                return nil
            }
        }
        guard connection?.isActive != false else { return nil }
        _ = fcntl(fd, F_SETFL, originalFlags)
        connected = true
        return fd
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base.advanced(by: offset), raw.count - offset)
                if written < 0, errno == EINTR { continue }
                if written <= 0 {
                    throw DoryHTTPProxyServerError.syscall("write", errno)
                }
                offset += written
            }
        }
    }

    static func bidirectionalCopy(connection: DoryTCPConnection) {
        guard let sockets = connection.beginRelay() else { return }
        func pump(_ from: Int32, _ to: Int32, onFinish: @escaping @Sendable () -> Void) {
            Thread.detachNewThread {
                var buffer = [UInt8](repeating: 0, count: 32 * 1024)
                while connection.isActive {
                    let count = buffer.withUnsafeMutableBytes { read(from, $0.baseAddress, 32 * 1024) }
                    if count < 0, errno == EINTR { continue }
                    if count <= 0 { break }
                    var offset = 0
                    var ok = true
                    while offset < count, connection.isActive {
                        let written = buffer.withUnsafeBytes {
                            write(to, $0.baseAddress!.advanced(by: offset), count - offset)
                        }
                        if written < 0, errno == EINTR { continue }
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
        pump(sockets.client, sockets.upstream, onFinish: { connection.clientPumpFinished() })
        pump(sockets.upstream, sockets.client, onFinish: { connection.upstreamPumpFinished() })
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
