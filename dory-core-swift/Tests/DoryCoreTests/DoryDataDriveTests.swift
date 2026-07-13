@testable import DoryCore
import Foundation
import XCTest

final class DoryDataDriveTests: XCTestCase {
    func testDefaultLayoutKeepsDurableDataOutOfTransientRuntimeState() throws {
        let drive = try DoryDataDrive(home: "/Users/test")

        XCTAssertEqual(drive.root, "/Users/test/Library/Application Support/Dory/Dory.dorydrive")
        XCTAssertEqual(drive.engineDataDiskPath, drive.root + "/engine/docker-data.ext4")
        XCTAssertEqual(drive.machinesDirectory, drive.root + "/machines")
        XCTAssertEqual(drive.backupsDirectory, drive.root + "/backups")
        XCTAssertEqual(drive.legacyEngineDataDiskPaths, [
            "/Users/test/.dory/hv/docker-data.ext4",
            "/Users/test/Library/Application Support/com.apple.container/volumes/dory-engine-data/volume.img",
        ])
    }

    func testExplicitExternalDriveIsStandardized() throws {
        let drive = try DoryDataDrive(
            home: "/Users/test",
            overrideRoot: "/Volumes/Work/Storage/../Dory.dorydrive"
        )
        XCTAssertEqual(drive.root, "/Volumes/Work/Dory.dorydrive")
    }

    func testExistingPrivateTmpHomeAndMissingDescendantShareOneCanonicalSpelling() throws {
        let privateHome = "/private/tmp/dory-data-drive-alias-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: privateHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: privateHome) }

        let requested = privateHome + "/Library/Application Support/Dory/Dory.dorydrive"
        let drive = try DoryDataDrive(home: privateHome, overrideRoot: requested)

        XCTAssertEqual(drive.home, privateHome.replacingOccurrences(of: "/private/tmp/", with: "/tmp/"))
        XCTAssertEqual(drive.root, drive.home + "/Library/Application Support/Dory/Dory.dorydrive")
        XCTAssertNoThrow(try drive.prepare())
    }

    func testSymlinkedHomeAndOverrideResolveToPhysicalApplicationSupportRoot() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-data-drive-symlink-\(UUID().uuidString)", isDirectory: true)
        let physicalHome = base.appendingPathComponent("physical", isDirectory: true)
        let aliasHome = base.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: physicalHome, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: aliasHome.path,
            withDestinationPath: physicalHome.path
        )
        defer { try? FileManager.default.removeItem(at: base) }

        let drive = try DoryDataDrive(
            home: aliasHome.path,
            overrideRoot: aliasHome.appendingPathComponent(
                "Library/Application Support/Dory/Dory.dorydrive",
                isDirectory: true
            ).path
        )

        XCTAssertEqual(drive.home, physicalHome.path)
        XCTAssertEqual(
            drive.root,
            physicalHome.appendingPathComponent(
                "Library/Application Support/Dory/Dory.dorydrive",
                isDirectory: true
            ).path
        )
    }

    func testProcessHomePrefersAbsoluteEnvironmentValue() {
        XCTAssertEqual(
            DoryDataDrive.processHome(environment: ["HOME": "/private/tmp/isolated-home"]),
            "/private/tmp/isolated-home"
        )
        XCTAssertEqual(
            DoryDataDrive.processHome(environment: ["HOME": "relative-home"]),
            NSHomeDirectory()
        )
    }

    func testRejectsRelativeNonBundleAndTransientRoots() {
        XCTAssertThrowsError(try DoryDataDrive(home: "/Users/test", overrideRoot: "relative.dorydrive"))
        XCTAssertThrowsError(try DoryDataDrive(home: "/Users/test", overrideRoot: "/Volumes/Work/Dory"))
        XCTAssertThrowsError(try DoryDataDrive(home: "/Users/test", overrideRoot: "/Users/test/.dory/data.dorydrive"))
        XCTAssertThrowsError(try DoryDataDrive(home: "/Users/test", overrideRoot: "/Users/test/Storage/Dory.dorydrive")) { error in
            XCTAssertEqual(
                error as? DoryDataDriveError,
                .unsupportedLocation("/Users/test/Storage/Dory.dorydrive")
            )
        }
    }

    func testRejectsPrivacyProtectedHomeLocationsThatLaunchAgentCannotReauthorize() {
        for directory in [
            "Desktop",
            "Documents/Projects",
            "Downloads",
            "Library/CloudStorage/Provider",
            "Library/Mobile Documents/com~apple~CloudDocs",
        ] {
            let root = "/Users/test/\(directory)/Dory.dorydrive"
            XCTAssertThrowsError(try DoryDataDrive(home: "/Users/test", overrideRoot: root)) { error in
                XCTAssertEqual(error as? DoryDataDriveError, .protectedLocation(root))
            }
        }
    }

    func testPrepareCreatesPrivateStableBundleContract() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-data-drive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let drive = try DoryDataDrive(home: base.path)

        try drive.prepare()
        try drive.prepare()

        XCTAssertTrue(FileManager.default.fileExists(atPath: drive.engineDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: drive.machinesDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: drive.backupsDirectory))
        XCTAssertNoThrow(try drive.validateManifest())
        let attributes = try FileManager.default.attributesOfItem(atPath: drive.root)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try drive.inspect(), .ready)
    }

    func testReadOnlyInspectionReportsAbsentWithoutCreatingBundle() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-data-drive-inspect-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let drive = try DoryDataDrive(home: base.path)
        let root = URL(fileURLWithPath: drive.root)

        XCTAssertEqual(try drive.inspect(), .absent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testOrdinaryDirectoryIsNotMistakenForMountedVolumeRoot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-not-a-volume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertFalse(DoryDataDrive.isMountedVolumeRoot(directory.path))
    }

    func testPrepareRejectsForeignBundleManifest() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-data-drive-foreign-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Library/Application Support/Dory/Dory.dorydrive", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{\"kind\":\"other\",\"schemaVersion\":1}\n".utf8)
            .write(to: root.appendingPathComponent("drive.json"))
        let drive = try DoryDataDrive(home: base.path, overrideRoot: root.path)

        XCTAssertThrowsError(try drive.prepare()) { error in
            XCTAssertEqual(error as? DoryDataDriveError, .invalidManifest(drive.manifestPath))
        }
    }

    func testPrepareRejectsPopulatedUnmarkedBundle() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-data-drive-unmarked-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Library/Application Support/Dory/Dory.dorydrive", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("foreign".utf8).write(to: root.appendingPathComponent("data.bin"))
        let drive = try DoryDataDrive(home: base.path, overrideRoot: root.path)

        XCTAssertThrowsError(try drive.prepare()) { error in
            XCTAssertEqual(error as? DoryDataDriveError, .populatedUnmarkedBundle(root.path))
        }
    }

    func testPrepareRejectsUnwritableParentCleanlyWithoutCreatingPartialBundle() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-data-drive-unwritable-\(UUID().uuidString)", isDirectory: true)
        let parent = base.appendingPathComponent("Library/Application Support/Dory", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            try? FileManager.default.removeItem(at: base)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        let drive = try DoryDataDrive(home: base.path)

        XCTAssertThrowsError(try drive.prepare()) { error in
            guard case let DoryDataDriveError.filesystem(message) = error else {
                return XCTFail("expected a clean filesystem error, got \(error)")
            }
            XCTAssertTrue(message.contains("prepare Dory data drive"))
            XCTAssertTrue(message.contains(drive.root))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: drive.root))
    }

    func testMissingExternalVolumeFailsInsteadOfCreatingAReplacementMountPoint() throws {
        let volume = "DoryMissing-\(UUID().uuidString)"
        let drive = try DoryDataDrive(
            home: "/Users/test",
            overrideRoot: "/Volumes/\(volume)/Dory.dorydrive"
        )
        XCTAssertThrowsError(try drive.prepare()) { error in
            XCTAssertEqual(error as? DoryDataDriveError, .unavailableVolume("/Volumes/\(volume)"))
        }
    }

    func testAdoptsLegacyMachineDisksWithoutChangingRollbackSource() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-data-drive-machines-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let legacy = base.appendingPathComponent(".dory/machines/dev", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let sourceDisk = legacy.appendingPathComponent("rootfs.ext4")
        let sourceConfig = legacy.appendingPathComponent("machine.json")
        let diskBytes = Data("durable-machine-disk".utf8)
        try diskBytes.write(to: sourceDisk)
        try Data("{\"id\":\"dev\"}\n".utf8).write(to: sourceConfig)
        try FileManager.default.createSymbolicLink(
            atPath: legacy.appendingPathComponent("current-rootfs").path,
            withDestinationPath: "rootfs.ext4"
        )
        let drive = try DoryDataDrive(home: base.path)

        XCTAssertEqual(
            try drive.adoptLegacyMachinesIfNeeded(),
            .adopted(source: base.path + "/.dory/machines")
        )
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: drive.machinesDirectory + "/dev/rootfs.ext4")),
            diskBytes
        )
        XCTAssertEqual(try Data(contentsOf: sourceDisk), diskBytes)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: drive.machinesDirectory + "/dev/current-rootfs"
            ),
            "rootfs.ext4"
        )
        XCTAssertEqual(try drive.adoptLegacyMachinesIfNeeded(), .destinationAlreadyPopulated)
    }
}
