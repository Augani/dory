import Darwin
@testable import DorydKit
import XCTest

final class DataplaneActivityServerTests: XCTestCase {
    func testActivityEventsUpdateIdleControllerAndTriggerWake() throws {
        let base = "/tmp/dory-activity-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let idle = IdleController()
        idle.setSleeping(true)
        let wake = expectation(description: "wake requested")
        let server = DataplaneActivityServer(path: base + "/activity.sock", idle: idle) {
            wake.fulfill()
        }
        try server.start()
        defer { server.stop() }

        try writeActivity("begin\tGET\t/_ping\n", to: base + "/activity.sock")
        XCTAssertEqual(idle.snapshot.activeRequests, 0)

        try writeActivity("begin\tGET\t/version\n", to: base + "/activity.sock")
        wait(for: [wake], timeout: 2)
        XCTAssertEqual(idle.snapshot.activeRequests, 1)

        try writeActivity("end\n", to: base + "/activity.sock")
        let deadline = Date().addingTimeInterval(2)
        while idle.snapshot.activeRequests != 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(idle.snapshot.activeRequests, 0)
    }
}

private func writeActivity(_ line: String, to path: String) throws {
    let fd = try connectActivity(path: path)
    defer { close(fd) }
    var bytes = Array(line.utf8)
    try bytes.withUnsafeMutableBytes { raw in
        guard Darwin.write(fd, raw.baseAddress!, raw.count) == raw.count else {
            throw ActivityTestError.write(errno)
        }
    }
    shutdown(fd, SHUT_WR)
    var ack = [UInt8](repeating: 0, count: 8)
    _ = ack.withUnsafeMutableBytes { raw in
        Darwin.read(fd, raw.baseAddress!, raw.count)
    }
}

private enum ActivityTestError: Error {
    case pathTooLong
    case socket(Int32)
    case connect(Int32)
    case write(Int32)
}

private func connectActivity(path: String) throws -> Int32 {
    var lastErrno: Int32 = 0
    for _ in 0..<100 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ActivityTestError.socket(errno) }
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout.size(ofValue: noSigpipe)))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw ActivityTestError.pathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: bytes.count)
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                connect(fd, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return fd }
        lastErrno = errno
        close(fd)
        usleep(10_000)
    }
    throw ActivityTestError.connect(lastErrno)
}
