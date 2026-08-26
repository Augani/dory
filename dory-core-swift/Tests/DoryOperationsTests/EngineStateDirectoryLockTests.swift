@testable import DoryOperations
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

    func testCanonicalizesASymlinkedParentBeforePublishingLockAuthority() throws {
        let lexicalState = "/tmp/dory-engine-lock-alias-\(UUID().uuidString)"
        let physicalState = try DoryDataDrive.canonicalPath(lexicalState)
        defer { try? FileManager.default.removeItem(atPath: physicalState) }

        let first = try EngineStateDirectoryLock(stateDirectory: lexicalState)
        XCTAssertEqual(first.path, physicalState + "/engine.lock")
        XCTAssertThrowsError(try EngineStateDirectoryLock(stateDirectory: physicalState))
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
        let physicalDrive = try DoryDataDrive.canonicalPath(drive)
        defer { try? FileManager.default.removeItem(atPath: drive) }

        let first = try EngineStateDirectoryLock(
            stateDirectory: drive,
            lockFileName: "drive.lock"
        )
        XCTAssertEqual(first.path, physicalDrive + "/drive.lock")
        XCTAssertThrowsError(try EngineStateDirectoryLock(
            stateDirectory: drive + "/./",
            lockFileName: "drive.lock"
        ))
        withExtendedLifetime(first) {}
    }

    func testRejectsHardLinkedLockFileWithoutChangingTheForeignLink() throws {
        let state = temporaryStateDirectory()
        let foreign = state + "-foreign"
        defer {
            try? FileManager.default.removeItem(atPath: state)
            try? FileManager.default.removeItem(atPath: foreign)
        }
        try FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        let physicalState = try DoryDataDrive.canonicalPath(state)
        try Data("foreign\n".utf8).write(to: URL(fileURLWithPath: foreign))
        try FileManager.default.linkItem(atPath: foreign, toPath: state + "/engine.lock")

        XCTAssertThrowsError(try EngineStateDirectoryLock(stateDirectory: state)) { error in
            guard case let EngineStateDirectoryLockError.cannotOpen(path, code) = error else {
                return XCTFail("unexpected state-lock error: \(error)")
            }
            XCTAssertEqual(path, physicalState + "/engine.lock")
            XCTAssertEqual(code, EINVAL)
        }
        XCTAssertEqual(try String(contentsOfFile: foreign, encoding: .utf8), "foreign\n")
    }

    private func temporaryStateDirectory() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-engine-lock-\(UUID().uuidString)", isDirectory: true)
            .path
    }
}
