import Darwin
@testable import DorydKit
import XCTest

final class DockerAPIProbeTests: XCTestCase {
    func testDockerEngineReadinessRequiresLinuxVersionResponse() throws {
        let body = #"{"Version":"28.5.1","ApiVersion":"1.51","Os":"linux","Arch":"arm64"}"#
        let server = try FakeDockerAPIServer(
            response: "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        )
        defer { server.stop() }

        XCTAssertTrue(DockerEngineProbe.waitUntilReady(
            socketPath: server.path,
            timeout: 1,
            pollInterval: 0.01
        ))
        XCTAssertTrue(server.wait())
        XCTAssertTrue(server.request.contains("GET /version HTTP/1.1"))
    }

    func testDockerEngineReadinessRejectsIncompleteVersionResponse() throws {
        let body = #"{"Version":"","Os":""}"#
        let server = try FakeDockerAPIServer(
            response: "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        )
        defer { server.stop() }

        XCTAssertFalse(DockerEngineProbe.waitUntilReady(
            socketPath: server.path,
            timeout: 0.1,
            pollInterval: 0.01
        ))
        XCTAssertTrue(server.wait())
        XCTAssertTrue(server.request.contains("GET /version HTTP/1.1"))
    }

    func testUnixDockerAPIProbePassesWhenPingReturnsOK() throws {
        let server = try FakeDockerAPIServer(response: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
        defer { server.stop() }

        XCTAssertEqual(UnixDockerAPIProbe(timeout: 1).ping(socketPath: server.path), .ok)
        XCTAssertTrue(server.wait())
        XCTAssertTrue(server.request.contains("GET /_ping HTTP/1.1"))
    }

    func testUnixDockerAPIProbeReportsBadPing() throws {
        let server = try FakeDockerAPIServer(response: "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 4\r\nConnection: close\r\n\r\nnope")
        defer { server.stop() }

        XCTAssertEqual(
            UnixDockerAPIProbe(timeout: 1).ping(socketPath: server.path),
            .badPing(statusCode: 503, body: "nope")
        )
        XCTAssertTrue(server.wait())
    }

    func testUnixDockerAPIProbeRequestsSystemDiskInventory() throws {
        let server = try FakeDockerAPIServer(
            response: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
        )
        defer { server.stop() }

        XCTAssertEqual(UnixDockerAPIProbe(timeout: 1).systemDF(socketPath: server.path), .ok)
        XCTAssertTrue(server.wait())
        XCTAssertTrue(server.request.contains("GET /system/df?type=container HTTP/1.1"))
    }

    func testUnixDockerAPIProbeDrainsContainerInventoryLargerThanLegacy64KiBLimit() throws {
        let body = String(repeating: "x", count: 128 * 1024)
        let server = try FakeDockerAPIServer(
            response: "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        )
        defer { server.stop() }

        XCTAssertEqual(UnixDockerAPIProbe(timeout: 1).systemDF(socketPath: server.path), .ok)
        XCTAssertTrue(server.wait())
    }

    func testUnixDockerAPIProbePreservesSystemDiskFailureBody() throws {
        let body = #"{"message":"rw layer snapshot not found"}"#
        let server = try FakeDockerAPIServer(
            response: "HTTP/1.1 500 Internal Server Error\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        )
        defer { server.stop() }

        XCTAssertEqual(
            UnixDockerAPIProbe(timeout: 1).systemDF(socketPath: server.path),
            .badResponse(statusCode: 500, body: body)
        )
        XCTAssertTrue(server.wait())
    }
}

private final class FakeDockerAPIServer: @unchecked Sendable {
    let path: String
    private let fd: Int32
    private let response: String
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedRequest = ""

    var request: String {
        lock.lock()
        defer { lock.unlock() }
        return storedRequest
    }

    init(response: String) throws {
        let base = "/tmp/dory-api-probe-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        self.path = base + "/docker.sock"
        self.fd = try bindUnixListener(path: path)
        self.response = response
        DispatchQueue.global().async { [self] in serveOne() }
    }

    func wait() -> Bool {
        done.wait(timeout: .now() + 2) == .success
    }

    func stop() {
        close(fd)
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    private func serveOne() {
        let accepted = accept(fd, nil, nil)
        guard accepted >= 0 else {
            done.signal()
            return
        }
        defer {
            close(accepted)
            done.signal()
        }
        let request = readUntilHeaderEnd(from: accepted) ?? ""
        lock.lock()
        storedRequest = request
        lock.unlock()
        _ = writeAll(Array(response.utf8), to: accepted)
        shutdown(accepted, SHUT_WR)
    }
}

private enum ProbeSocketTestError: Error {
    case pathTooLong
    case syscall(String, Int32)
}

private func bindUnixListener(path: String) throws -> Int32 {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ProbeSocketTestError.syscall("socket", errno) }

    var address = try unixAddress(path: path)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
            Darwin.bind(fd, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        let error = errno
        close(fd)
        throw ProbeSocketTestError.syscall("bind", error)
    }
    guard listen(fd, 1) == 0 else {
        let error = errno
        close(fd)
        throw ProbeSocketTestError.syscall("listen", error)
    }
    return fd
}

private func unixAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw ProbeSocketTestError.pathTooLong
    }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        bytes.withUnsafeBytes { source in
            destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: bytes.count)
        }
    }
    return address
}

private func readUntilHeaderEnd(from fd: Int32) -> String? {
    var bytes: [UInt8] = []
    var byte = UInt8(0)
    while bytes.count < 8192 {
        let got = Darwin.read(fd, &byte, 1)
        if got == 1 {
            bytes.append(byte)
            if bytes.suffix(4) == [13, 10, 13, 10] {
                return String(decoding: bytes, as: UTF8.self)
            }
            continue
        }
        if got < 0 && errno == EINTR { continue }
        return nil
    }
    return nil
}

@discardableResult
private func writeAll(_ bytes: [UInt8], to fd: Int32) -> Bool {
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeBytes { raw in
            Darwin.write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
        }
        if written < 0 {
            if errno == EINTR { continue }
            return false
        }
        offset += written
    }
    return true
}
