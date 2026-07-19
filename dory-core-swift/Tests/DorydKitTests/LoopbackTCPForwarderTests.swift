import Darwin
@testable import DorydKit
import XCTest

final class LoopbackTCPForwarderTests: XCTestCase {
    func testLoopbackAddressClassificationIncludesIPv4MappedIPv6() {
        XCTAssertTrue(LoopbackTCPForwarder.isLoopbackAddress("127.0.0.1"))
        XCTAssertTrue(LoopbackTCPForwarder.isLoopbackAddress("127.42.0.9"))
        XCTAssertTrue(LoopbackTCPForwarder.isLoopbackAddress("::1"))
        XCTAssertTrue(LoopbackTCPForwarder.isLoopbackAddress("::ffff:127.0.0.1"))
        XCTAssertFalse(LoopbackTCPForwarder.isLoopbackAddress("0.0.0.0"))
        XCTAssertFalse(LoopbackTCPForwarder.isLoopbackAddress("192.168.1.20"))
        XCTAssertFalse(LoopbackTCPForwarder.isLoopbackAddress("fe80::1%en0"))
        XCTAssertFalse(LoopbackTCPForwarder.isLoopbackAddress("2001:db8::1"))
    }

    func testRelaysIPv4AndIPv6LoopbackToLocalBackend() throws {
        let backend = LoopbackEchoBackend(expectedConnections: 2)
        try backend.start()
        defer { backend.stop() }

        let listenPort = try availableDualStackTCPPort()
        let forwarders = LoopbackTCPForwarderSet()
        defer { forwarders.stop() }

        let result = forwarders.reconcile([
            PrivilegedTCPForward(listenPort: listenPort, targetPort: backend.port),
        ])
        XCTAssertEqual(result.failures, [:])
        XCTAssertEqual(result.active, [
            PrivilegedTCPForward(listenPort: listenPort, targetPort: backend.port),
        ])

        XCTAssertEqual(try roundTrip(host: "127.0.0.1", port: listenPort, payload: "ipv4"), "ipv4")
        XCTAssertEqual(try roundTrip(host: "::1", port: listenPort, payload: "ipv6"), "ipv6")
    }

    func testUnprivilegedWildcardLowPortRelayOnMacOS() throws {
        let backend = LoopbackEchoBackend(expectedConnections: 1)
        try backend.start()
        defer { backend.stop() }

        var selected: LoopbackTCPForwarder?
        for listenPort in UInt16(81)...UInt16(127) {
            let candidate = LoopbackTCPForwarder(
                listenPort: listenPort,
                targetPort: backend.port
            )
            do {
                try candidate.start()
                selected = candidate
                break
            } catch let LoopbackTCPForwarderError.syscall(_, code) where code == EADDRINUSE {
                continue
            }
        }
        let forwarder = try XCTUnwrap(selected, "no free low TCP port was available for the macOS bind contract")
        defer { forwarder.stop() }

        XCTAssertEqual(
            try roundTrip(host: "127.0.0.1", port: forwarder.listenPort, payload: "low-port"),
            "low-port"
        )
    }

    func testReconcileUpdatesTargetAndRemovesListener() throws {
        let first = LoopbackEchoBackend(expectedConnections: 1, prefix: "first:")
        let second = LoopbackEchoBackend(expectedConnections: 1, prefix: "second:")
        try first.start()
        try second.start()
        defer {
            first.stop()
            second.stop()
        }

        let listenPort = try availableDualStackTCPPort()
        let forwarders = LoopbackTCPForwarderSet()
        defer { forwarders.stop() }
        XCTAssertEqual(forwarders.reconcile([
            PrivilegedTCPForward(listenPort: listenPort, targetPort: first.port),
        ]).failures, [:])
        XCTAssertEqual(try roundTrip(host: "127.0.0.1", port: listenPort, payload: "one"), "first:one")

        XCTAssertEqual(forwarders.reconcile([
            PrivilegedTCPForward(listenPort: listenPort, targetPort: second.port),
        ]).failures, [:])
        XCTAssertEqual(try roundTrip(host: "127.0.0.1", port: listenPort, payload: "two"), "second:two")

        XCTAssertEqual(forwarders.reconcile([]).active, [])
        XCTAssertThrowsError(try roundTrip(host: "127.0.0.1", port: listenPort, payload: "gone"))
    }
}

private final class LoopbackEchoBackend: @unchecked Sendable {
    private let expectedConnections: Int
    private let prefix: String
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var activePort: UInt16 = 0

    init(expectedConnections: Int, prefix: String = "") {
        self.expectedConnections = expectedConnections
        self.prefix = prefix
    }

    var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return activePort
    }

    func start() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LoopbackForwarderTestError.syscall("socket", errno) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(0).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.bind(descriptor, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            let code = errno
            close(descriptor)
            throw LoopbackForwarderTestError.syscall("bind/listen", code)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gotName = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                getsockname(descriptor, raw, &length)
            }
        }
        guard gotName == 0 else {
            let code = errno
            close(descriptor)
            throw LoopbackForwarderTestError.syscall("getsockname", code)
        }
        lock.lock()
        fd = descriptor
        activePort = UInt16(bigEndian: actual.sin_port)
        lock.unlock()
        Thread.detachNewThread { [weak self] in
            self?.serve(descriptor)
        }
    }

    func stop() {
        lock.lock()
        let descriptor = fd
        fd = -1
        activePort = 0
        lock.unlock()
        if descriptor >= 0 {
            shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
        }
    }

    private func serve(_ descriptor: Int32) {
        for _ in 0..<expectedConnections {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let capacity = buffer.count
            let count = buffer.withUnsafeMutableBytes { read(client, $0.baseAddress, capacity) }
            if count > 0 {
                let response = Data(prefix.utf8) + Data(buffer.prefix(count))
                try? DoryTCP.writeAll(client, response)
            }
            shutdown(client, SHUT_RDWR)
            close(client)
        }
    }
}

private enum LoopbackForwarderTestError: Error {
    case syscall(String, Int32)
    case shortRead
}

private func availableDualStackTCPPort() throws -> UInt16 {
    for _ in 0..<50 {
        let ipv4 = socket(AF_INET, SOCK_STREAM, 0)
        guard ipv4 >= 0 else { throw LoopbackForwarderTestError.syscall("socket(AF_INET)", errno) }
        var address4 = sockaddr_in()
        address4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address4.sin_family = sa_family_t(AF_INET)
        address4.sin_port = UInt16(0).bigEndian
        address4.sin_addr.s_addr = in_addr_t(0)
        let bound4 = withUnsafePointer(to: &address4) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.bind(ipv4, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound4 == 0 else {
            let code = errno
            close(ipv4)
            throw LoopbackForwarderTestError.syscall("bind(AF_INET)", code)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                getsockname(ipv4, raw, &length)
            }
        }
        let port = UInt16(bigEndian: actual.sin_port)

        let ipv6 = socket(AF_INET6, SOCK_STREAM, 0)
        guard ipv6 >= 0 else {
            close(ipv4)
            throw LoopbackForwarderTestError.syscall("socket(AF_INET6)", errno)
        }
        var yes: Int32 = 1
        setsockopt(ipv6, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address6 = sockaddr_in6()
        address6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address6.sin6_family = sa_family_t(AF_INET6)
        address6.sin6_port = port.bigEndian
        address6.sin6_addr = in6addr_any
        let bound6 = withUnsafePointer(to: &address6) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.bind(ipv6, raw, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        close(ipv6)
        close(ipv4)
        if bound6 == 0 { return port }
    }
    throw LoopbackForwarderTestError.syscall("find dual-stack port", EADDRINUSE)
}

private func roundTrip(host: String, port: UInt16, payload: String) throws -> String {
    let family = host.contains(":") ? AF_INET6 : AF_INET
    let descriptor = socket(family, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw LoopbackForwarderTestError.syscall("socket", errno) }
    defer { close(descriptor) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    let connected: Int32
    if family == AF_INET6 {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        inet_pton(AF_INET6, host, &address.sin6_addr)
        connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                connect(descriptor, raw, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
    } else {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &address.sin_addr)
        connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                connect(descriptor, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
    guard connected == 0 else { throw LoopbackForwarderTestError.syscall("connect", errno) }
    try DoryTCP.writeAll(descriptor, Data(payload.utf8))
    shutdown(descriptor, SHUT_WR)
    var buffer = [UInt8](repeating: 0, count: 4096)
    let capacity = buffer.count
    let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, capacity) }
    guard count > 0 else {
        throw LoopbackForwarderTestError.shortRead
    }
    return String(decoding: buffer.prefix(count), as: UTF8.self)
}
