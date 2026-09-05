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
