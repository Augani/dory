import Darwin
@testable import DorydKit
import XCTest

final class DoryTCPConnectionLifetimeTests: XCTestCase {
    func testCancellationRetainsDescriptorsAndBudgetUntilEveryWorkerExits() throws {
        let client = try socketPair()
        let upstream = try socketPair()
        defer { close(client.1); close(upstream.1) }
        let budget = DoryConnectionBudget(limit: 1)
        let lease = try XCTUnwrap(budget.tryAcquire())
        let closed = expectation(description: "closed once after join")
        closed.assertForOverFulfill = true
        let connection = DoryTCPConnection(client: client.0) { _ in
            lease.release()
            closed.fulfill()
        }
        XCTAssertTrue(connection.adoptUpstream(upstream.0))
        XCTAssertNotNil(connection.beginRelay())
        connection.cancel()
        connection.cancel()
        XCTAssertFalse(connection.isActive)
        XCTAssertNotEqual(fcntl(client.0, F_GETFD), -1)
        XCTAssertNotEqual(fcntl(upstream.0, F_GETFD), -1)
        XCTAssertEqual(budget.activeCount, 1)
        XCTAssertNil(budget.tryAcquire())
        connection.workerFinished()
        connection.clientPumpFinished()
        XCTAssertNotEqual(fcntl(client.0, F_GETFD), -1)
        XCTAssertEqual(budget.activeCount, 1)
        connection.upstreamPumpFinished()
        wait(for: [closed], timeout: 1)
        XCTAssertEqual(budget.activeCount, 0)
        XCTAssertEqual(fcntl(client.0, F_GETFD), -1)
        XCTAssertEqual(fcntl(upstream.0, F_GETFD), -1)
    }

    func testCancelledConnectionRejectsLateUpstreamWithoutTakingItsOwnership() throws {
        let client = try socketPair()
        let upstream = try socketPair()
        defer { close(client.1); close(upstream.0); close(upstream.1) }
        let connection = DoryTCPConnection(client: client.0) { _ in }
        connection.cancel()
        XCTAssertFalse(connection.adoptUpstream(upstream.0))
        XCTAssertNil(connection.beginRelay())
        connection.workerFinished()
        XCTAssertNotEqual(fcntl(upstream.0, F_GETFD), -1)
    }

    func testListenerCancellationDoesNotCloseDescriptorBeforeAcceptJoin() throws {
        let sockets = try socketPair()
        defer { close(sockets.1) }
        let listener = DoryTCPListener(sockets.0)
        listener.cancel()
        XCTAssertNotEqual(fcntl(sockets.0, F_GETFD), -1)
        listener.acceptWorkerFinished()
        listener.acceptWorkerFinished()
        XCTAssertEqual(fcntl(sockets.0, F_GETFD), -1)
    }

    func testRevokedConnectAdmissionNeverInvokesTheSocketSyscall() throws {
        let client = try socketPair()
        let upstream = try socketPair()
        defer { close(client.1); close(upstream.1) }
        let connection = DoryTCPConnection(client: client.0) { _ in }
        XCTAssertTrue(connection.adoptUpstream(upstream.0))
        XCTAssertEqual(connection.performConnect { 7 }, 7)
        connection.cancel()
        var invoked = false
        XCTAssertNil(connection.performConnect { invoked = true; return 0 })
        XCTAssertFalse(invoked)
        connection.workerFinished()
    }

    func testHTTPStopRevokesIdleHeadersAndAllowsRestart() throws {
        let proxy = DoryHTTPProxyServer(port: 0, maximumConnections: 1)
        defer { proxy.stop() }
        for _ in 0..<5 {
            try proxy.start()
            let client = try XCTUnwrap(DoryTCP.connect(host: "127.0.0.1", port: proxy.port))
            defer { close(client) }
            try eventually { proxy.activeConnectionCount == 1 }
            proxy.stop()
            XCTAssertFalse(proxy.isRunning)
            XCTAssertEqual(try readOnce(client), Data())
            try eventually { proxy.activeConnectionCount == 0 }
        }
    }

    func testHTTPStopRevokesBothSidesOfEstablishedRelay() throws {
        let backend = try HeldRelayBackend()
        defer { backend.stop() }
        let proxy = DoryHTTPProxyServer(port: 0, routes: [
            DomainRoute(hostname: "web.dory.local", address: "127.0.0.1", port: backend.port),
        ])
        try proxy.start()
        defer { proxy.stop() }
        let client = try XCTUnwrap(DoryTCP.connect(host: "127.0.0.1", port: proxy.port))
        defer { close(client) }
        try DoryTCP.writeAll(client, Data("GET / HTTP/1.1\r\nHost: web.dory.local\r\n\r\n".utf8))
        XCTAssertEqual(try readOnce(client), Data("ready".utf8))
        proxy.stop()
        XCTAssertEqual(try readOnce(client), Data())
        wait(for: [backend.closed], timeout: 2)
        try eventually { proxy.activeConnectionCount == 0 }
    }

    func testLoopbackStopRevokesBothSidesOfEstablishedRelay() throws {
        let backend = try HeldRelayBackend()
        defer { backend.stop() }
        let forwarder = LoopbackTCPForwarder(listenPort: try unusedPort(), targetPort: backend.port)
        try forwarder.start()
        defer { forwarder.stop() }
        let client = try XCTUnwrap(DoryTCP.connect(host: "127.0.0.1", port: forwarder.listenPort))
        defer { close(client) }
        XCTAssertEqual(try readOnce(client), Data("ready".utf8))
        forwarder.stop()
        XCTAssertEqual(try readOnce(client), Data())
        wait(for: [backend.closed], timeout: 2)
        try eventually { forwarder.activeConnectionCount == 0 }
    }

    func testHTTPRouteRemovalRevokesOnlyTheRemovedBackend() throws {
        let backend = try HeldRelayBackend()
        defer { backend.stop() }
        let route = DomainRoute(hostname: "web.dory.local", address: "127.0.0.1", port: backend.port)
        let proxy = DoryHTTPProxyServer(port: 0, routes: [route])
        try proxy.start()
        defer { proxy.stop() }
        let client = try XCTUnwrap(DoryTCP.connect(host: "127.0.0.1", port: proxy.port))
        defer { close(client) }
        try DoryTCP.writeAll(client, Data("GET / HTTP/1.1\r\nHost: web.dory.local\r\n\r\n".utf8))
        XCTAssertEqual(try readOnce(client), Data("ready".utf8))
        // Unchanged and unrelated route refreshes must not cut off a live workload.
        proxy.updateRoutes([route, DomainRoute(hostname: "other.dory.local", address: "127.0.0.1", port: 60_080)])
        XCTAssertEqual(proxy.activeConnectionCount, 1)
        proxy.updateRoutes([])
        XCTAssertEqual(try readOnce(client), Data())
        wait(for: [backend.closed], timeout: 2)
        try eventually { proxy.activeConnectionCount == 0 }
        XCTAssertTrue(proxy.isRunning)
    }

    func testHTTPMoreSpecificRouteReplacementRevokesTheWildcardRelay() throws {
        let backend = try HeldRelayBackend()
        defer { backend.stop() }
        let wildcard = DomainRoute(hostname: "*.dory.local", address: "127.0.0.1", port: backend.port)
        let proxy = DoryHTTPProxyServer(port: 0, routes: [wildcard])
        try proxy.start()
        defer { proxy.stop() }
        let client = try XCTUnwrap(DoryTCP.connect(host: "127.0.0.1", port: proxy.port))
        defer { close(client) }
        try DoryTCP.writeAll(client, Data("GET / HTTP/1.1\r\nHost: web.dory.local\r\n\r\n".utf8))
        XCTAssertEqual(try readOnce(client), Data("ready".utf8))
        proxy.updateRoutes([wildcard,
            DomainRoute(hostname: "web.dory.local", address: "127.0.0.1", port: 60_080),
        ])
        XCTAssertEqual(try readOnce(client), Data())
        wait(for: [backend.closed], timeout: 2)
        try eventually { proxy.activeConnectionCount == 0 }
    }

    func testLoopbackTargetReplacementRevokesOldRelayAndAdmitsNewTarget() throws {
        let first = try HeldRelayBackend()
        let second = try HeldRelayBackend()
        defer { first.stop(); second.stop() }
        let forwarder = LoopbackTCPForwarder(listenPort: try unusedPort(), targetPort: first.port)
        try forwarder.start()
        defer { forwarder.stop() }
        let oldClient = try XCTUnwrap(DoryTCP.connect(host: "127.0.0.1", port: forwarder.listenPort))
        defer { close(oldClient) }
        XCTAssertEqual(try readOnce(oldClient), Data("ready".utf8))
        forwarder.updateTargetPort(second.port)
        XCTAssertEqual(try readOnce(oldClient), Data())
        wait(for: [first.closed], timeout: 2)
        let newClient = try XCTUnwrap(DoryTCP.connect(host: "127.0.0.1", port: forwarder.listenPort))
        defer { close(newClient) }
        XCTAssertEqual(try readOnce(newClient), Data("ready".utf8))
        XCTAssertTrue(forwarder.isRunning)
        forwarder.stop()
        wait(for: [second.closed], timeout: 2)
        try eventually { forwarder.activeConnectionCount == 0 }
    }
}

private enum LifetimeTestError: Error { case syscall(Int32); case timedOut }

private func socketPair() throws -> (Int32, Int32) {
    var descriptors = [Int32](repeating: -1, count: 2)
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
        throw LifetimeTestError.syscall(errno)
    }
    return (descriptors[0], descriptors[1])
}

private func readOnce(_ descriptor: Int32) throws -> Data {
    var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    guard poll(&event, 1, 2_000) > 0 else { throw LifetimeTestError.timedOut }
    var bytes = [UInt8](repeating: 0, count: 1_024)
    let count = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
    guard count >= 0 else { throw LifetimeTestError.syscall(errno) }
    return Data(bytes.prefix(count))
}

private func eventually(_ condition: () -> Bool) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while !condition() {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw LifetimeTestError.timedOut }
        usleep(1_000)
    }
}

private func makeListener() throws -> (Int32, UInt16) {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw LifetimeTestError.syscall(errno) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
    }
    guard bound == 0, named == 0, listen(descriptor, 8) == 0 else {
        let code = errno
        close(descriptor)
        throw LifetimeTestError.syscall(code)
    }
    return (descriptor, UInt16(bigEndian: address.sin_port))
}

private func unusedPort() throws -> UInt16 {
    let (descriptor, port) = try makeListener()
    close(descriptor)
    return port
}

/// One connected upstream, held open until the relay revokes it. Listener and connection workers
/// retain their own descriptors, including during test failure cleanup.
final class HeldRelayBackend: @unchecked Sendable {
    let port: UInt16
    let closed = XCTestExpectation(description: "upstream observed EOF")
    private let listener: DoryTCPListener
    private let lock = NSLock()
    private var connection: DoryTCPConnection?
    private var stopped = false

    init() throws {
        let (descriptor, port) = try makeListener()
        self.port = port
        listener = DoryTCPListener(descriptor)
        let listener = self.listener
        Thread.detachNewThread { [weak self, listener] in
            defer { listener.acceptWorkerFinished() }
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            let connection = DoryTCPConnection(client: client) { _ in }
            defer { connection.workerFinished() }
            guard let self else { connection.cancel(); return }
            let admitted = self.lock.withLock {
                guard !self.stopped else { return false }
                self.connection = connection
                return true
            }
            guard admitted else { connection.cancel(); return }
            try? DoryTCP.writeAll(client, Data("ready".utf8))
            var bytes = [UInt8](repeating: 0, count: 1_024)
            while connection.isActive {
                let count = bytes.withUnsafeMutableBytes { read(client, $0.baseAddress, $0.count) }
                if count <= 0 { break }
            }
            self.closed.fulfill()
        }
    }

    func stop() {
        let connection = lock.withLock { stopped = true; return self.connection }
        listener.cancel()
        connection?.cancel()
    }
    deinit { stop() }
}
