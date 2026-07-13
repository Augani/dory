@testable import DoryCore
import Foundation
import XCTest

final class EngineStateDirectoryLockTests: XCTestCase {
    func testRejectsASecondOwnerForTheSameStateDirectory() throws {
        let state = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(atPath: state) }

        let first = try EngineStateDirectoryLock(stateDirectory: state)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))

        XCTAssertThrowsError(try EngineStateDirectoryLock(stateDirectory: state + "/./")) { error in
            guard case let EngineStateDirectoryLockError.alreadyInUse(_, _, owner, _) = error else {
                return XCTFail("unexpected state-lock error: \(error)")
            }
            XCTAssertTrue(owner.contains("pid="))
        }
        withExtendedLifetime(first) {}
    }

    func testReleasesOwnershipWhenTheEngineOwnerExits() throws {
        let state = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(atPath: state) }

        do {
            let first = try EngineStateDirectoryLock(stateDirectory: state)
            withExtendedLifetime(first) {}
        }

        let replacement = try EngineStateDirectoryLock(stateDirectory: state)
        withExtendedLifetime(replacement) {}
    }

    func testAllowsIndependentStateDirectories() throws {
        let firstState = temporaryStateDirectory()
        let secondState = temporaryStateDirectory()
        defer {
            try? FileManager.default.removeItem(atPath: firstState)
            try? FileManager.default.removeItem(atPath: secondState)
        }

        let first = try EngineStateDirectoryLock(stateDirectory: firstState)
        let second = try EngineStateDirectoryLock(stateDirectory: secondState)
        withExtendedLifetime((first, second)) {}
    }

    func testSupportsASeparateDriveLifetimeLockInTheBundleRoot() throws {
        let drive = temporaryStateDirectory() + ".dorydrive"
        defer { try? FileManager.default.removeItem(atPath: drive) }

        let first = try EngineStateDirectoryLock(
            stateDirectory: drive,
            lockFileName: "drive.lock"
        )
        XCTAssertEqual(first.path, drive + "/drive.lock")
        XCTAssertThrowsError(try EngineStateDirectoryLock(
            stateDirectory: drive + "/./",
            lockFileName: "drive.lock"
        ))
        withExtendedLifetime(first) {}
    }

    private func temporaryStateDirectory() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-engine-lock-\(UUID().uuidString)", isDirectory: true)
            .path
    }
}
