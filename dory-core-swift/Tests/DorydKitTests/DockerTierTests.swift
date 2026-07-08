import Darwin
@testable import DorydKit
import Foundation
import XCTest

final class DockerTierTests: XCTestCase {
    func testStartServesDockerSocketThroughForwardDataplane() throws {
        let base = "/tmp/dory-tier-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let forwardPath = base + "/forward.sock"
        let listener = try bindUnixListener(path: forwardPath)
        defer { close(listener) }

        let capture = Capture()
        let serverDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let accepted = accept(listener, nil, nil)
            guard accepted >= 0 else {
                capture.setError("accept failed: \(errno)")
                serverDone.signal()
                return
            }
            defer {
                close(accepted)
                serverDone.signal()
            }

            guard let lengthBytes = readExactly(4, from: accepted) else {
                capture.setError("missing preamble length")
                return
            }
            let length = le32(lengthBytes)
            guard let preamble = readExactly(Int(length), from: accepted) else {
                capture.setError("missing preamble body")
                return
            }
            capture.setPreamble(preamble)

            guard let request = readUntilHeaderEnd(from: accepted), request.contains("GET /version") else {
                capture.setError("missing docker request")
                return
            }
            writeAll("HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\nhello dory\n", to: accepted)
            shutdown(accepted, SHUT_WR)
        }

        let tier = DockerTier(configuration: DockerTierConfiguration(
            home: base + "/home",
            forwardSocketPath: forwardPath,
            cid: 3,
            dockerPort: 1026,
            gpuSupported: false
        ))
        try tier.start()
        defer { tier.stop() }

        XCTAssertEqual(tier.status().state, .running)

        let client = try connectUnix(path: tier.socketPath)
        defer { close(client) }
        writeAll("GET /version HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n", to: client)
        shutdown(client, SHUT_WR)

        let response = readAvailableString(from: client)
        XCTAssertTrue(response.contains("hello dory"), response)
        XCTAssertEqual(serverDone.wait(timeout: .now() + 2), .success)
        XCTAssertNil(capture.error)
        XCTAssertEqual(capture.preamble, [1, 3, 0, 0, 0, 2, 4, 0, 0])
    }

    func testArmSleepingPublishesSocketWithoutStartingHelperUntilWake() throws {
        let base = "/tmp/dory-tier-armed-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let idle = IdleController(now: Date(timeIntervalSince1970: 0))
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"]
                )
            ),
            idleController: idle,
            dockerReadyWaiter: { _, _ in true }
        )

        try tier.armSleeping()
        defer { tier.stop() }

        XCTAssertEqual(tier.status().state, .sleeping)
        XCTAssertNil(tier.status().hvPID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tier.socketPath))
        XCTAssertTrue(idle.snapshot.sleeping)

        try tier.start()
        XCTAssertEqual(tier.status().state, .running)
        XCTAssertNotNil(tier.status().hvPID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tier.socketPath))
        XCTAssertFalse(idle.snapshot.sleeping)
    }

    func testIdleSleepSuspendsHelperAndWakeResumesSameProcess() async throws {
        let base = "/tmp/dory-tier-sleep-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let idle = IdleController(now: Date(timeIntervalSince1970: 0))
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"]
                )
            ),
            idleController: idle,
            containerActivityProbe: { _ in .active(1) },
            dockerReadyWaiter: { _, _ in true }
        )

        try tier.start()
        defer { tier.stop() }
        XCTAssertEqual(tier.status().state, .running)
        let originalPID = try XCTUnwrap(tier.status().hvPID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tier.socketPath))

        XCTAssertTrue(tier.sleepForIdle(idleAfter: 1, now: Date().addingTimeInterval(10)))
        XCTAssertEqual(tier.status().state, .sleeping)
        XCTAssertEqual(tier.status().hvPID, originalPID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tier.socketPath), "dataplane listener stays up for wake")

        await tier.ensureAwake()
        XCTAssertEqual(tier.status().state, .running)
        XCTAssertEqual(tier.status().hvPID, originalPID)
        XCTAssertFalse(idle.snapshot.sleeping)
    }

    func testIdleSleepStopsEmptyHelperAndWakeStartsFreshProcess() async throws {
        let base = "/tmp/dory-tier-empty-sleep-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let idle = IdleController(now: Date(timeIntervalSince1970: 0))
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"]
                )
            ),
            idleController: idle,
            containerActivityProbe: { _ in .empty },
            dockerReadyWaiter: { _, _ in true }
        )

        try tier.start()
        defer { tier.stop() }
        let originalPID = try XCTUnwrap(tier.status().hvPID)

        XCTAssertTrue(tier.sleepForIdle(idleAfter: 1, now: Date().addingTimeInterval(10)))
        XCTAssertEqual(tier.status().state, .sleeping)
        XCTAssertNil(tier.status().hvPID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tier.socketPath), "dataplane listener stays up for wake")

        await tier.ensureAwake()
        let freshPID = try XCTUnwrap(tier.status().hvPID)
        XCTAssertEqual(tier.status().state, .running)
        XCTAssertNotEqual(freshPID, originalPID)
        XCTAssertFalse(idle.snapshot.sleeping)
    }

    func testIdleSleepStopsEmptyHelperEvenWithStaleRequestCount() throws {
        let base = "/tmp/dory-tier-stale-empty-sleep-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let idle = IdleController(now: Date(timeIntervalSince1970: 0))
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"]
                )
            ),
            idleController: idle,
            containerActivityProbe: { _ in .empty },
            dockerReadyWaiter: { _, _ in true }
        )

        try tier.start()
        defer { tier.stop() }
        _ = idle.beginRequest(path: "/events", now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(idle.snapshot.activeRequests, 1)

        XCTAssertTrue(tier.sleepForIdle(idleAfter: 1, now: Date(timeIntervalSince1970: 10)))
        XCTAssertEqual(tier.status().state, .sleeping)
        XCTAssertNil(tier.status().hvPID)
    }

    func testHostSleepStopsEmptyHelper() throws {
        let base = "/tmp/dory-tier-host-sleep-empty-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let idle = IdleController(now: Date(timeIntervalSince1970: 0))
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"]
                )
            ),
            idleController: idle,
            containerActivityProbe: { _ in .empty },
            dockerReadyWaiter: { _, _ in true }
        )

        try tier.start()
        defer { tier.stop() }
        XCTAssertNotNil(tier.status().hvPID)

        let result = tier.prepareForHostSleep(now: idle.snapshot.lastActivity.addingTimeInterval(1))

        XCTAssertTrue(result.attempted)
        XCTAssertTrue(result.slept)
        XCTAssertEqual(tier.status().state, .sleeping)
        XCTAssertNil(tier.status().hvPID)
    }

    func testHostSleepLeavesActiveContainersRunning() throws {
        let base = "/tmp/dory-tier-host-sleep-active-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let idle = IdleController(now: Date(timeIntervalSince1970: 0))
        let tier = DockerTier(
            configuration: DockerTierConfiguration(
                home: base + "/home",
                forwardSocketPath: base + "/forward.sock",
                activitySocketPath: base + "/activity.sock",
                hvProcess: HvProcessConfiguration(
                    executablePath: "/bin/sleep",
                    arguments: ["30"]
                )
            ),
            idleController: idle,
            containerActivityProbe: { _ in .active(2) },
            dockerReadyWaiter: { _, _ in true }
        )

        try tier.start()
        defer { tier.stop() }
        let originalPID = try XCTUnwrap(tier.status().hvPID)

        let result = tier.prepareForHostSleep(now: idle.snapshot.lastActivity.addingTimeInterval(1))

        XCTAssertFalse(result.attempted)
        XCTAssertFalse(result.slept)
        XCTAssertEqual(tier.status().state, .running)
        XCTAssertEqual(tier.status().hvPID, originalPID)
        XCTAssertFalse(idle.snapshot.sleeping)
    }
}

private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPreamble: [UInt8]?
    private var storedError: String?

    var preamble: [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        return storedPreamble
    }

    var error: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func setPreamble(_ preamble: [UInt8]) {
        lock.lock()
        storedPreamble = preamble
        lock.unlock()
    }

    func setError(_ error: String) {
        lock.lock()
        storedError = error
        lock.unlock()
    }
}

private enum SocketTestError: Error {
    case pathTooLong
    case syscall(String, Int32)
    case connectTimedOut(String)
}

private func bindUnixListener(path: String) throws -> Int32 {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketTestError.syscall("socket", errno) }

    var address = try unixAddress(path: path)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
            Darwin.bind(fd, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        let error = errno
        close(fd)
        throw SocketTestError.syscall("bind", error)
    }
    guard listen(fd, 8) == 0 else {
        let error = errno
        close(fd)
        throw SocketTestError.syscall("listen", error)
    }
    return fd
}

private func connectUnix(path: String) throws -> Int32 {
    var lastErrno: Int32 = 0
    for _ in 0..<100 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketTestError.syscall("socket", errno) }
        var address = try unixAddress(path: path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                connect(fd, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 {
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            return fd
        }
        lastErrno = errno
        close(fd)
        usleep(20_000)
    }
    throw SocketTestError.connectTimedOut("\(path): \(lastErrno)")
}

private func unixAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw SocketTestError.pathTooLong
    }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        bytes.withUnsafeBytes { source in
            destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: bytes.count)
        }
    }
    return address
}

private func readExactly(_ count: Int, from fd: Int32) -> [UInt8]? {
    var bytes = [UInt8](repeating: 0, count: count)
    var offset = 0
    while offset < count {
        let got = bytes.withUnsafeMutableBytes { raw in
            Darwin.read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
        }
        if got == 0 { return nil }
        if got < 0 {
            if errno == EINTR { continue }
            return nil
        }
        offset += got
    }
    return bytes
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

private func readAvailableString(from fd: Int32) -> String {
    var output = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let capacity = buffer.count
        let got = buffer.withUnsafeMutableBytes { raw in
            Darwin.read(fd, raw.baseAddress!, capacity)
        }
        if got > 0 {
            output.append(contentsOf: buffer.prefix(got))
            continue
        }
        if got < 0 && errno == EINTR { continue }
        break
    }
    return String(decoding: output, as: UTF8.self)
}

@discardableResult
private func writeAll(_ string: String, to fd: Int32) -> Bool {
    writeAll(Array(string.utf8), to: fd)
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

private func le32(_ bytes: [UInt8]) -> UInt32 {
    UInt32(bytes[0])
        | UInt32(bytes[1]) << 8
        | UInt32(bytes[2]) << 16
        | UInt32(bytes[3]) << 24
}
