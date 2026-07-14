import Darwin
@testable import DorydKit
import XCTest

final class DoryHTTPProxyServerTests: XCTestCase {
    func testConnectionBudgetRejectsOverflowAndReleasesExactlyOnce() throws {
        let budget = DoryConnectionBudget(limit: 2)
        let first = try XCTUnwrap(budget.tryAcquire())
        let second = try XCTUnwrap(budget.tryAcquire())

        XCTAssertEqual(budget.activeCount, 2)
        XCTAssertNil(budget.tryAcquire())

        first.release()
        first.release()
        XCTAssertEqual(budget.activeCount, 1)

        let replacement = try XCTUnwrap(budget.tryAcquire())
        XCTAssertEqual(budget.activeCount, 2)
        second.release()
        replacement.release()
        XCTAssertEqual(budget.activeCount, 0)
    }

    func testProxiesHostHeaderToMatchingRoute() throws {
        let backend = TinyHTTPBackend(responseBody: "hello from backend")
        try backend.start()
        defer { backend.stop() }

        let proxy = DoryHTTPProxyServer(port: 0, routes: [
            DomainRoute(hostname: "web.dory.local", address: "127.0.0.1", port: backend.port),
        ])
        try proxy.start()
        defer { proxy.stop() }

        let response = try sendHTTP(port: proxy.port, host: "web.dory.local")

        XCTAssertTrue(response.contains("HTTP/1.1 200 OK"))
        XCTAssertTrue(response.contains("hello from backend"))
        XCTAssertTrue(backend.lastRequest.contains("Host: web.dory.local"))
    }

    func testUnknownHostReturnsBadGateway() throws {
        let proxy = DoryHTTPProxyServer(port: 0, routes: [])
        try proxy.start()
        defer { proxy.stop() }

        let response = try sendHTTP(port: proxy.port, host: "missing.dory.local")

        XCTAssertTrue(response.contains("HTTP/1.1 502 Bad Gateway"))
        XCTAssertTrue(response.contains("no backend"))
    }

    func testExplicitLocalhostRouteIsAllowedForLowPortFallbacks() throws {
        let backend = TinyHTTPBackend(responseBody: "hello from low port backend")
        try backend.start()
        defer { backend.stop() }

        let proxy = DoryHTTPProxyServer(port: 0, routes: [
            DomainRoute(hostname: "localhost", address: "127.0.0.1", port: backend.port),
        ])
        try proxy.start()
        defer { proxy.stop() }

        let response = try sendHTTP(port: proxy.port, host: "localhost")

        XCTAssertTrue(response.contains("HTTP/1.1 200 OK"))
        XCTAssertTrue(response.contains("hello from low port backend"))
    }

    func testHostHeaderParsingStripsPort() {
        let request = Data("GET / HTTP/1.1\r\nHost: Web.Dory.Local:8080\r\n\r\n".utf8)
        XCTAssertEqual(DoryHTTPProxyServer.hostHeader(request), "web.dory.local")
    }

    func testRewriteRequestPrependsPathPrefix() {
        let request = Data("GET /healthz HTTP/1.1\r\nHost: web.default.k8s.dory.local\r\n\r\n".utf8)
        let rewritten = DoryHTTPProxyServer.rewriteRequest(
            request,
            pathPrefix: "/api/v1/namespaces/default/services/web:80/proxy"
        )
        let text = String(data: rewritten, encoding: .utf8) ?? ""
        XCTAssertTrue(text.hasPrefix("GET /api/v1/namespaces/default/services/web:80/proxy/healthz HTTP/1.1\r\n"))
        XCTAssertTrue(text.contains("Host: web.default.k8s.dory.local"))
    }

    func testPathPrefixRouteRewritesBeforeProxying() throws {
        let backend = TinyHTTPBackend(responseBody: "hello from kube proxy")
        try backend.start()
        defer { backend.stop() }

        let proxy = DoryHTTPProxyServer(port: 0, routes: [
            DomainRoute(
                hostname: "web.default.k8s.dory.local",
                address: "127.0.0.1",
                port: backend.port,
                pathPrefix: "/api/v1/namespaces/default/services/web:80/proxy"
            ),
        ])
        try proxy.start()
        defer { proxy.stop() }

        let response = try sendHTTP(port: proxy.port, host: "web.default.k8s.dory.local", path: "/healthz")

        XCTAssertTrue(response.contains("HTTP/1.1 200 OK"))
        XCTAssertTrue(response.contains("hello from kube proxy"))
        XCTAssertTrue(backend.lastRequest.hasPrefix("GET /api/v1/namespaces/default/services/web:80/proxy/healthz HTTP/1.1\r\n"))
    }
}

private final class TinyHTTPBackend: @unchecked Sendable {
    private let responseBody: String
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var activePort: UInt16 = 0
    private var request = ""

    init(responseBody: String) {
        self.responseBody = responseBody
    }

    var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return activePort
    }

    var lastRequest: String {
        lock.lock()
        defer { lock.unlock() }
        return request
    }

    func start() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw ProxyTestError.syscall("socket", errno) }
        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(0).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.bind(socketFD, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(socketFD, 8) == 0 else {
            close(socketFD)
            throw ProxyTestError.syscall("bind/listen", errno)
        }
        var actual = sockaddr_in()
        var actualLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gotName = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                getsockname(socketFD, raw, &actualLength)
            }
        }
        guard gotName == 0 else {
            close(socketFD)
            throw ProxyTestError.syscall("getsockname", errno)
        }
        lock.lock()
        fd = socketFD
        activePort = UInt16(bigEndian: actual.sin_port)
        lock.unlock()
        Thread.detachNewThread { [weak self] in
            self?.acceptOnce(socketFD)
        }
    }

    func stop() {
        lock.lock()
        let current = fd
        fd = -1
        activePort = 0
        lock.unlock()
        if current >= 0 {
            shutdown(current, SHUT_RDWR)
            close(current)
        }
    }

    private func acceptOnce(_ socketFD: Int32) {
        let client = accept(socketFD, nil, nil)
        guard client >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let capacity = buffer.count
        let count = buffer.withUnsafeMutableBytes { read(client, $0.baseAddress, capacity) }
        if count > 0 {
            lock.lock()
            request = String(decoding: buffer.prefix(count), as: UTF8.self)
            lock.unlock()
        }
        let response = "HTTP/1.1 200 OK\r\nContent-Length: \(responseBody.utf8.count)\r\nConnection: close\r\n\r\n\(responseBody)"
        _ = response.withCString { pointer in
            write(client, pointer, strlen(pointer))
        }
        shutdown(client, SHUT_RDWR)
        close(client)
    }
}

private enum ProxyTestError: Error {
    case syscall(String, Int32)
    case shortRead
}

private func sendHTTP(port: UInt16, host: String, path: String = "/") throws -> String {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ProxyTestError.syscall("socket", errno) }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
            connect(fd, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { throw ProxyTestError.syscall("connect", errno) }
    let request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
    _ = request.withCString { pointer in
        write(fd, pointer, strlen(pointer))
    }
    var out = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let capacity = buffer.count
    while true {
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, capacity) }
        if count < 0 {
            throw ProxyTestError.syscall("read", errno)
        }
        if count == 0 { break }
        out.append(contentsOf: buffer.prefix(count))
    }
    guard !out.isEmpty else { throw ProxyTestError.shortRead }
    return String(decoding: out, as: UTF8.self)
}
