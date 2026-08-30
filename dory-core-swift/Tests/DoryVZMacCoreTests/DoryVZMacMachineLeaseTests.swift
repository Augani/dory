import Foundation
import XCTest
@testable import DoryVZMacCore

final class DoryVZMacMachineLeaseTests: XCTestCase {
    func testRejectsConcurrentExclusiveOwnerAndReleasesOnDeinit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-vzmac-lease-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        var first: DoryVZMacMachineLease? = try DoryVZMacMachineLease(rootURL: root)
        XCTAssertThrowsError(try DoryVZMacMachineLease(rootURL: root)) { error in
            XCTAssertEqual(
                error as? DoryVZMacMachineLeaseError,
                .alreadyInUse(root.path)
            )
        }
        first = nil
        XCTAssertNoThrow(try DoryVZMacMachineLease(rootURL: root))
        _ = first
    }

    func testRejectsMissingRoot() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try DoryVZMacMachineLease(rootURL: root))
    }
}
