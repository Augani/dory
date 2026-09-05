import Darwin
import Foundation
@testable import DorydKit
import XCTest

final class VmmHandoffDescriptorRejectionTests: XCTestCase {
    func testRejectedReadinessReleasesTransferredDescriptors() throws {
        try assertRejectionClosesDescriptors(operationID: "invalid", count: 1)
    }

    func testOversizedDescriptorTransferReleasesReceivedDescriptors() throws {
        for count in [9, 253] {
            try assertRejectionClosesDescriptors(operationID: UUID().uuidString.lowercased(), count: count)
        }
    }

    func testApplicationHandoffRejectsExcessRightsWithoutLeaking() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dory/qfd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = open(root.appendingPathComponent("owned").path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var identity = stat()
        XCTAssertEqual(fstat(descriptor, &identity), 0)
        for expectedCount in [0, 1, 16] {
            var pair: [Int32] = [-1, -1]
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
            defer { pair.forEach { close($0) } }
            try DoryApplicationLaunchHandoffProtocol.sendDescriptors(
                Array(repeating: descriptor, count: 17), to: pair[0]
            )
            XCTAssertThrowsError(try DoryApplicationLaunchHandoffProtocol.receiveDescriptors(
                from: pair[1], expectedCount: expectedCount
            ))
            let references = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd")
                .compactMap(Int32.init)
                .filter { candidate in
                    var info = stat()
                    return fstat(candidate, &info) == 0
                        && info.st_dev == identity.st_dev && info.st_ino == identity.st_ino
                }
            XCTAssertEqual(references, [descriptor])
        }
    }

    func testReadinessWaitsForCompleteStreamMessage() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dory/qfd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = VmmReadyMessage(machineID: "dev", operationID: UUID().uuidString.lowercased())
        let accepted = expectation(description: "complete fragmented message accepted")
        let server = VmmHandoffServer(path: root.appendingPathComponent("s").path) { result in
            switch result {
            case let .success(handoff): XCTAssertEqual(handoff.ready, ready)
            case let .failure(error): XCTFail("fragmented readiness rejected: \(error)")
            }
            accepted.fulfill()
        }
        try server.start()
        defer { server.stop() }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(server.path.utf8) + [0]
        XCTAssertLessThanOrEqual(pathBytes.count, MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            target.copyBytes(from: pathBytes)
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        let payload = try JSONEncoder().encode(ready)
        XCTAssertEqual(payload.prefix(1).withUnsafeBytes { send(fd, $0.baseAddress, $0.count, MSG_NOSIGNAL) }, 1)
        // The incomplete prefix must neither be rejected nor acknowledged before EOF.
        var pending = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&pending, 1, 50), 0)
        let remainder = payload.dropFirst()
        XCTAssertEqual(remainder.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, MSG_NOSIGNAL) }, remainder.count)
        XCTAssertEqual(shutdown(fd, SHUT_WR), 0)
        wait(for: [accepted], timeout: 5)
        var acknowledgment: UInt8 = 0
        XCTAssertEqual(read(fd, &acknowledgment, 1), 1)
        XCTAssertEqual(acknowledgment, 1)
    }

    private func assertRejectionClosesDescriptors(operationID: String, count: Int) throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dory/qfd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = open(root.appendingPathComponent("owned").path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var identity = stat()
        XCTAssertEqual(fstat(descriptor, &identity), 0)

        let rejected = expectation(description: "invalid readiness rejected")
        let server = VmmHandoffServer(path: root.appendingPathComponent("s").path) { result in
            if case .success = result { XCTFail("invalid or truncated readiness was accepted") }
            rejected.fulfill()
        }
        try server.start()
        defer { server.stop() }
        XCTAssertThrowsError(try VmmHandoffClient.send(
            path: server.path,
            ready: VmmReadyMessage(machineID: "dev", operationID: operationID),
            fileDescriptors: Array(repeating: descriptor, count: count)
        ))
        wait(for: [rejected], timeout: 5)

        // Count only references to this unique file, independent of unrelated test sockets.
        let references = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd")
            .compactMap(Int32.init)
            .filter { candidate in
                var info = stat()
                return fstat(candidate, &info) == 0
                    && info.st_dev == identity.st_dev && info.st_ino == identity.st_ino
            }
        XCTAssertEqual(references, [descriptor], "rejected SCM_RIGHTS descriptor leaked")
    }
}
