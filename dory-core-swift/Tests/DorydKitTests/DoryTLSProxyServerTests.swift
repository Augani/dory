import Darwin
import Network
import Security
@testable import DorydKit
import XCTest

final class DoryTLSProxyServerTests: XCTestCase {
    func testStopRevokesEstablishedTLSUpstreamAndRetainsBudgetUntilPumpsExit() throws {
        try withLifetimeProxy { proxy, backend, route in
            let client = try lifetimeClient(port: proxy.port)
            defer { client.cancel() }
            try primeRelay(client)
            XCTAssertEqual(proxy.activeConnectionCount, 1)
            proxy.updateRoutes([route])
            XCTAssertEqual(proxy.activeConnectionCount, 1)
            proxy.stop()
            wait(for: [backend.closed], timeout: 2)
            awaitClientEOF(client)
            try awaitNoConnections(proxy)
        }
    }

    func testRouteRemovalRevokesEstablishedTLSUpstreamWithoutStoppingListener() throws {
        try withLifetimeProxy { proxy, backend, _ in
            let client = try lifetimeClient(port: proxy.port)
            defer { client.cancel() }
            try primeRelay(client)
            proxy.updateRoutes([])
            wait(for: [backend.closed], timeout: 2)
            awaitClientEOF(client)
            try awaitNoConnections(proxy)
            XCTAssertTrue(proxy.isRunning)
        }
    }

    func testStopRevokesTLSClientStillAwaitingItsHeader() throws {
        try withLifetimeProxy { proxy, _, _ in
            let client = try lifetimeClient(port: proxy.port)
            defer { client.cancel() }
            XCTAssertEqual(proxy.activeConnectionCount, 1)
            proxy.stop()
            awaitClientEOF(client)
            try awaitNoConnections(proxy)
        }
    }

    private func withLifetimeProxy(
        _ body: (DoryTLSProxyServer, HeldRelayBackend, DomainRoute) throws -> Void
    ) throws {
        let base = NSTemporaryDirectory() + "doryd-tls-lifetime-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let ca = DoryLocalCA(directory: URL(fileURLWithPath: base).appendingPathComponent("ca"))
        let p12 = try ca.issuePKCS12(domain: "dory.local", password: "test-password")
        let backend = try HeldRelayBackend()
        defer { backend.stop() }
        let route = DomainRoute(hostname: "web.dory.local", address: "127.0.0.1", port: backend.port)
        let proxy = try DoryTLSProxyServer(port: 0, p12Path: p12.path,
                                           password: "test-password", routes: [route])
        try proxy.start()
        defer { proxy.stop() }
        try body(proxy, backend, route)
    }

    private func lifetimeClient(port: UInt16) throws -> NWConnection {
        let ready = expectation(description: "TLS client ready")
        let options = NWProtocolTLS.Options()
        let queue = DispatchQueue(label: "dory.tls-lifetime-test")
        // Skip certificate validation only on this isolated temporary-CA test connection.
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, queue)
        let client = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: port)),
                                  using: NWParameters(tls: options))
        client.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        client.start(queue: queue)
        wait(for: [ready], timeout: 3)
        return client
    }

    private func primeRelay(_ client: NWConnection) throws {
        client.send(content: Data("GET / HTTP/1.1\r\nHost: web.dory.local\r\n\r\n".utf8),
                    completion: .contentProcessed { _ in })
        let received = expectation(description: "TLS relay returned upstream marker")
        client.receive(minimumIncompleteLength: 5, maximumLength: 5) { data, _, _, error in
            XCTAssertNil(error)
            XCTAssertEqual(data, Data("ready".utf8))
            received.fulfill()
        }
        wait(for: [received], timeout: 3)
    }

    private func awaitClientEOF(_ client: NWConnection) {
        let ended = expectation(description: "TLS client ended after revoke")
        client.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { data, _, complete, error in
            XCTAssertTrue(complete || error != nil)
            XCTAssertTrue(data?.isEmpty != false)
            ended.fulfill()
        }
        wait(for: [ended], timeout: 3)
    }

    private func awaitNoConnections(_ proxy: DoryTLSProxyServer) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while proxy.activeConnectionCount != 0 {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                XCTFail("TLS relay retained connection budget after cancellation")
                return
            }
            usleep(1_000)
        }
    }

    func testTemporaryKeychainFallbackUsesPrivateFileAndDeletesIt() throws {
        let base = NSTemporaryDirectory() + "doryd-tls-keychain-\(getpid())-\(UUID().uuidString)"
        let ca = DoryLocalCA(directory: URL(fileURLWithPath: base).appendingPathComponent("ca"))
        defer { try? FileManager.default.removeItem(atPath: base) }

        let p12 = try ca.issuePKCS12(domain: "dory.local", password: "test-password")
        var storage: DoryTLSIdentityStorage? = try XCTUnwrap(DoryTLSProxyServer.loadIdentity(
            p12Path: p12.path,
            password: "test-password",
            forceTemporaryKeychain: true
        ))
        let keychainPath = try XCTUnwrap(storage?.temporaryKeychainPath)

        XCTAssertTrue(FileManager.default.fileExists(atPath: keychainPath))

        storage = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: keychainPath))
    }

    func testCanRestartFixedPortWithoutAddressInUse() throws {
        let base = NSTemporaryDirectory() + "doryd-tls-restart-\(getpid())-\(UUID().uuidString)"
        let ca = DoryLocalCA(directory: URL(fileURLWithPath: base).appendingPathComponent("ca"))
        defer { try? FileManager.default.removeItem(atPath: base) }

        let p12 = try ca.issuePKCS12(domain: "dory.local", password: "test-password")
        let fixedPort = try availableTCPPort()
        let proxy = try DoryTLSProxyServer(
            port: fixedPort,
            p12Path: p12.path,
            password: "test-password"
        )
        defer { proxy.stop() }

        for attempt in 1...20 {
            XCTAssertNoThrow(try proxy.start(), "restart \(attempt) failed")
            XCTAssertEqual(proxy.port, fixedPort)
            proxy.stop()
        }
    }

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
        ], timeout: 10)

        XCTAssertEqual(response, "hello over tls")
        XCTAssertTrue(backend.lastRequest.contains("Host: web.dory.local"))
    }

    func testTerminatesTLSForExplicitCustomDomainSANAndRoute() throws {
        let base = NSTemporaryDirectory() + "doryd-custom-tls-\(getpid())-\(UUID().uuidString)"
        let ca = DoryLocalCA(directory: URL(fileURLWithPath: base).appendingPathComponent("ca"))
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/curl") else {
            throw XCTSkip("/usr/bin/curl unavailable")
        }
        defer { try? FileManager.default.removeItem(atPath: base) }

        let backend = TinyTLSHTTPBackend(responseBody: "hello custom tls")
        try backend.start()
        defer { backend.stop() }

        let p12 = try ca.issuePKCS12(
            domain: "dory.local",
            password: "test-password",
            extraSANs: ["admin.myproject.local"]
        )
        let proxy = try DoryTLSProxyServer(
            port: 0,
            p12Path: p12.path,
            password: "test-password",
            routes: [
                DomainRoute(hostname: "admin.myproject.local", address: "127.0.0.1", port: backend.port),
            ]
        )
        try proxy.start()
        defer { proxy.stop() }

        let response = try DoryShell.run("/usr/bin/curl", [
            "-kfsS",
            "--max-time", "5",
            "--noproxy", "*",
            "--resolve", "admin.myproject.local:\(proxy.port):127.0.0.1",
            "https://admin.myproject.local:\(proxy.port)/",
        ], timeout: 10)

        XCTAssertEqual(response, "hello custom tls")
        XCTAssertTrue(backend.lastRequest.contains("Host: admin.myproject.local"))
    }
}

private func availableTCPPort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw TLSProxyTestError.syscall("socket", errno) }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(0).bigEndian
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
            Darwin.bind(fd, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { throw TLSProxyTestError.syscall("bind", errno) }
    var actual = sockaddr_in()
    var actualLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let gotName = withUnsafeMutablePointer(to: &actual) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
            getsockname(fd, raw, &actualLength)
        }
    }
    guard gotName == 0 else { throw TLSProxyTestError.syscall("getsockname", errno) }
    return UInt16(bigEndian: actual.sin_port)
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
