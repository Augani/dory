import Foundation
import XCTest
@testable import DoryVZMacCore

final class DoryVZMacSharedDirectoryTests: XCTestCase {
    func testAcceptsBoundedDirectDirectory() throws {
        let share = try DoryVZMacSharedDirectory(
            name: "Dory Guest Tools",
            url: FileManager.default.temporaryDirectory,
            readOnly: true
        )
        XCTAssertTrue(share.readOnly)
    }

    func testRejectsUnsafeNameAndNonDirectory() throws {
        XCTAssertThrowsError(
            try DoryVZMacSharedDirectory(
                name: "../escape",
                url: FileManager.default.temporaryDirectory,
                readOnly: true
            )
        )
        XCTAssertThrowsError(
            try DoryVZMacSharedDirectory(
                name: "Dory",
                url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                readOnly: true
            )
        )
    }

    func testConfigurationFingerprintChangesWithSharePolicy() throws {
        let readOnly = try DoryVZMacSharedDirectory(
            name: "Dory Guest Tools",
            url: FileManager.default.temporaryDirectory,
            readOnly: true
        )
        let readWrite = try DoryVZMacSharedDirectory(
            name: "Dory Guest Tools",
            url: FileManager.default.temporaryDirectory,
            readOnly: false
        )
        let first = try DoryVZMacConfigurationBuilder.fingerprint(
            sharedDirectories: [readOnly]
        )
        XCTAssertEqual(first.count, 64)
        XCTAssertEqual(
            first,
            try DoryVZMacConfigurationBuilder.fingerprint(sharedDirectories: [readOnly])
        )
        XCTAssertNotEqual(
            first,
            try DoryVZMacConfigurationBuilder.fingerprint(sharedDirectories: [readWrite])
        )
    }
}
