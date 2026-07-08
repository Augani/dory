import Darwin
@testable import DorydKit
import XCTest

final class DoryTLSProxyServerTests: XCTestCase {
    func testTerminatesTLSAndProxiesHostHeaderToMatchingRoute() throws {
        let base = NSTemporaryDirectory() + "doryd-tls-\(getpid())-\(UUID().uuidString)"
        let ca = DoryLocalCA(directory: URL(fileURLWithPath: base).appendingPathComponent("ca"))
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/curl") else {
            throw XCTSkip("/usr/bin/curl unavailable")
        }
        defer { try? FileManager.default.removeItem(atPath: base) }

        let backend = TinyTLSHTTPBackend(responseBody: "hello over tls")
        try backend.start()
        defer { backend.stop() }

        let p12 = try ca.issuePKCS12(domain: "dory.local", password: "test-password")
        let proxy = try DoryTLSProxyServer(
            port: 0,
            p12Path: p12.path,
            password: "test-password",
            routes: [
                DomainRoute(hostname: "web.dory.local", address: "127.0.0.1", port: backend.port),
            ]
        )
        try proxy.start()
        defer { proxy.stop() }

        let response = try DoryShell.run("/usr/bin/curl", [
            "-kfsS",
            "--max-time", "5",
            "--noproxy", "*",
            "--resolve", "web.dory.local:\(proxy.port):127.0.0.1",
            "https://web.dory.local:\(proxy.port)/",
        ])

        XCTAssertEqual(response, "hello over tls")
        XCTAssertTrue(backend.lastRequest.contains("Host: web.dory.local"))
    }
}

private final class TinyTLSHTTPBackend: @unchecked Sendable {
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
        guard socketFD >= 0 else { throw TLSProxyTestError.syscall("socket", errno) }
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
            throw TLSProxyTestError.syscall("bind/listen", errno)
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
            throw TLSProxyTestError.syscall("getsockname", errno)
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

private enum TLSProxyTestError: Error {
    case syscall(String, Int32)
}
