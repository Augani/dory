@testable import DoryOperations
import Foundation
import XCTest

final class DoryDataDriveSelectionStoreTests: XCTestCase {
    func testSelectionAuthorityExcludesConcurrentMutation() throws {
        let base = try temporaryHome(named: "authority")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try DoryDataDriveSelectionStore(home: base.path)
        let authority = try store.acquireAuthority()
        _ = try store.prepareSelection(authority: authority)

        XCTAssertThrowsError(try store.prepareSelection()) { error in
            guard case .selectionInUse = error as? DoryDataDriveSelectionError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testFirstSelectionRefusesToAdoptAnExistingUnselectedDrive() throws {
        let base = try temporaryHome(named: "unselected-existing")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try DoryDataDriveSelectionStore(home: base.path)
        let drive = try DoryDataDrive(home: base.path)
        try drive.prepare()
        let existingID = try drive.readManifest().id

        XCTAssertThrowsError(try store.prepareSelection()) { error in
            XCTAssertEqual(
                error as? DoryDataDriveSelectionError,
                .unselectedExistingDrive(drive.root)
            )
        }
        XCTAssertEqual(try drive.readManifest().id, existingID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
    }

    func testFirstSelectionSurvivesReplacementOfTransientRuntimeState() throws {
        let base = try temporaryHome(named: "runtime-reset")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try DoryDataDriveSelectionStore(home: base.path)
        let first = try store.prepareSelection()
        let firstID = try first.readManifest().id
        let runtime = base.appendingPathComponent(".dory", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try Data("replaceable-cache".utf8).write(to: runtime.appendingPathComponent("cache"))

        try FileManager.default.removeItem(at: runtime)
        let recovered = try store.prepareSelection()

        XCTAssertEqual(try recovered.readManifest().id, firstID)
        XCTAssertEqual(recovered.root, first.root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.path))
        XCTAssertFalse(store.path.hasPrefix(runtime.path + "/"))
        let attributes = try FileManager.default.attributesOfItem(atPath: store.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testMissingSelectedDriveFailsWithoutCreatingAReplacement() throws {
        let base = try temporaryHome(named: "missing")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try DoryDataDriveSelectionStore(home: base.path)
        let drive = try store.prepareSelection()
        let driveID = try drive.readManifest().id
        let parked = URL(fileURLWithPath: drive.root).deletingLastPathComponent()
            .appendingPathComponent("Parked.dorydrive", isDirectory: true)
        try FileManager.default.moveItem(atPath: drive.root, toPath: parked.path)

        XCTAssertThrowsError(try store.prepareSelection()) { error in
            XCTAssertEqual(
                error as? DoryDataDriveSelectionError,
                .selectedDriveUnavailable(path: drive.root, id: driveID)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: drive.root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: parked.path))
    }

    func testDifferentInitializedDriveIsRejectedAndSelectionIsUnchanged() throws {
        let base = try temporaryHome(named: "mismatch")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try DoryDataDriveSelectionStore(home: base.path)
        let selected = try store.prepareSelection()
        let selectedID = try selected.readManifest().id
        let otherRoot = base.appendingPathComponent(
            "Library/Application Support/Dory/Other.dorydrive",
            isDirectory: true
        ).path
        let other = try DoryDataDrive(home: base.path, overrideRoot: otherRoot)
        try other.prepare()
        let otherID = try other.readManifest().id

        XCTAssertThrowsError(try store.prepareSelection(requestedRoot: other.root)) { error in
            XCTAssertEqual(
                error as? DoryDataDriveSelectionError,
                .selectedDriveMismatch(expected: selectedID, actual: otherID, path: other.root)
            )
        }
        XCTAssertEqual(try store.read()?.driveID, selectedID)
        XCTAssertEqual(try store.selectedPath(), selected.root)
    }

    func testRelocatedSelectedDriveKeepsIdentityAndUpdatesRememberedPath() throws {
        let base = try temporaryHome(named: "relocated")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try DoryDataDriveSelectionStore(home: base.path)
        let original = try store.prepareSelection()
        let originalID = try original.readManifest().id
        let relocatedRoot = base.appendingPathComponent(
            "Library/Application Support/Dory/Relocated.dorydrive",
            isDirectory: true
        ).path
        try FileManager.default.moveItem(atPath: original.root, toPath: relocatedRoot)

        let relocated = try store.prepareSelection(requestedRoot: relocatedRoot)

        XCTAssertEqual(try relocated.readManifest().id, originalID)
        XCTAssertEqual(try store.read()?.canonicalPath, relocated.root)
        XCTAssertEqual(try store.selectedPath(), relocated.root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.root))
    }

    func testInspectionUsesSelectedDriveWithoutRepairingOrRewritingIt() throws {
        let base = try temporaryHome(named: "inspect-selected")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try DoryDataDriveSelectionStore(home: base.path)
        let root = base.appendingPathComponent(
            "Library/Application Support/Dory/Selected.dorydrive",
            isDirectory: true
        ).path
        let selected = try store.prepareSelection(requestedRoot: root)
        let recordBefore = try Data(contentsOf: URL(fileURLWithPath: store.path))
        try FileManager.default.removeItem(atPath: selected.exportsDirectory)

        let inspected = try XCTUnwrap(store.inspectSelection())

        XCTAssertEqual(inspected.root, selected.root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.exportsDirectory))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.path)), recordBefore)
    }

    func testSelectionRecordSymlinkIsRejectedWithoutFollowingOrChangingTarget() throws {
        let base = try temporaryHome(named: "symlink")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try DoryDataDriveSelectionStore(home: base.path)
        _ = try store.prepareSelection()
        let original = try Data(contentsOf: URL(fileURLWithPath: store.path))
        let target = base.appendingPathComponent("foreign-selection.json")
        try original.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.removeItem(atPath: store.path)
        try FileManager.default.createSymbolicLink(atPath: store.path, withDestinationPath: target.path)

        XCTAssertThrowsError(try store.read()) { error in
            XCTAssertEqual(error as? DoryDataDriveSelectionError, .invalidRecord(store.path))
        }
        XCTAssertThrowsError(try store.prepareSelection()) { error in
            XCTAssertEqual(error as? DoryDataDriveSelectionError, .invalidRecord(store.path))
        }
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testCorruptAndHardLinkedSelectionRecordsAreRejected() throws {
        let base = try temporaryHome(named: "corrupt")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try DoryDataDriveSelectionStore(home: base.path)
        _ = try store.prepareSelection()
        let hardLink = base.appendingPathComponent("selection-hard-link.json")
        try FileManager.default.linkItem(atPath: store.path, toPath: hardLink.path)

        XCTAssertThrowsError(try store.read()) { error in
            XCTAssertEqual(error as? DoryDataDriveSelectionError, .invalidRecord(store.path))
        }

        try FileManager.default.removeItem(atPath: hardLink.path)
        try Data("not-json\n".utf8).write(to: URL(fileURLWithPath: store.path), options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.path)
        XCTAssertThrowsError(try store.read()) { error in
            XCTAssertEqual(error as? DoryDataDriveSelectionError, .invalidRecord(store.path))
        }
    }

    func testBindExistingRefusesToInitializeAnAbsentDrive() throws {
        let base = try temporaryHome(named: "bind-absent")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try DoryDataDriveSelectionStore(home: base.path)
        let root = base.appendingPathComponent(
            "Library/Application Support/Dory/Absent.dorydrive",
            isDirectory: true
        ).path

        XCTAssertThrowsError(try store.bindExistingSelection(requestedRoot: root)) { error in
            XCTAssertEqual(error as? DoryDataDriveSelectionError, .uninitializedDrive(root))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
    }

    func testOrdinaryBindRequiresIdleDriveButLiveRecoveryCanVerifyIt() throws {
        let base = try temporaryHome(named: "bind-in-use")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = try DoryDataDriveSelectionStore(home: base.path)
        let drive = try store.prepareSelection()
        let driveLock = try EngineStateDirectoryLock(
            stateDirectory: drive.root,
            lockFileName: "drive.lock"
        )
        defer { withExtendedLifetime(driveLock) {} }

        XCTAssertThrowsError(try store.bindExistingSelection(requestedRoot: drive.root)) { error in
            guard case let .selectedDriveInUse(path, _) = error as? DoryDataDriveSelectionError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(path, drive.root)
        }

        let recovered = try store.recoverExistingSelection(requestedRoot: drive.root)
        XCTAssertEqual(recovered.root, drive.root)
        XCTAssertEqual(try recovered.readManifest().id, try drive.readManifest().id)
    }

    private func temporaryHome(named name: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-selection-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
