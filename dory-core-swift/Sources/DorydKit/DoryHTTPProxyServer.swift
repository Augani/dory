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
    private let lock = NSLock()
    private var routes: [DomainRoute]
    private var fd: Int32 = -1
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
                if errno == EINTR { continue }
                return
            }
            Thread.detachNewThread { [weak self] in
                self?.handle(client)
            }
        }
    }

    private func handle(_ client: Int32) {
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
        guard (try? DoryTCP.writeAll(upstream, buffer)) != nil else {
            shutdown(upstream, SHUT_RDWR)
            close(upstream)
            writeBadGateway(client, body: "Dory: backend unavailable\n")
            return
        }
        DoryTCP.bidirectionalCopy(client: client, upstream: upstream)
    }

    private func route(for host: String) -> DomainRoute? {
        let normalized = DomainRouter.normalize(host)
        lock.lock()
        let currentRoutes = routes
        lock.unlock()
        return currentRoutes.first { route in
            let hostname = DomainRouter.normalize(route.hostname)
            return hostname == normalized && router.owns(hostname) && IPv4Address(route.address) != nil
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
    static func connect(host: String, port: UInt16) -> Int32? {
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
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.connect(fd, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
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
        private var finished = 0
        private var closed = false

        init(client: Int32, upstream: Int32) {
            self.client = client
            self.upstream = upstream
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
            defer { lock.unlock() }
            finished += 1
            if finished >= 2, !closed {
                closed = true
                close(client)
                close(upstream)
            }
        }
    }

    static func bidirectionalCopy(client: Int32, upstream: Int32) {
        let connection = ProxyConnection(client: client, upstream: upstream)
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
