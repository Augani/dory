import XCTest
@testable import DoryVZMacCore

final class DoryVZMacMachineManifestTests: XCTestCase {
    func testAcceptsCanonicalPersistentIdentity() throws {
        try manifest().validate()
    }

    func testRejectsUnknownSchemaAndMalformedDigest() throws {
        XCTAssertThrowsError(try manifest(schema: "dory.vzmac-machine@2").validate())
        XCTAssertThrowsError(try manifest(restoreDigest: String(repeating: "A", count: 64)).validate())
        XCTAssertThrowsError(try manifest(restoreDigest: "abc").validate())
    }

    func testRejectsNonLocalOrMulticastMACAddress() throws {
        XCTAssertThrowsError(try manifest(macAddress: "00:11:22:33:44:55").validate())
        XCTAssertThrowsError(try manifest(macAddress: "03:11:22:33:44:55").validate())
    }

    func testPreparationMACSelectionPreservesDaemonIdentityAndRejectsInvalidInput() throws {
        XCTAssertEqual(
            try DoryVZMacMachineBundle.selectedMACAddress("02:11:22:33:44:55"),
            "02:11:22:33:44:55"
        )
        XCTAssertThrowsError(
            try DoryVZMacMachineBundle.selectedMACAddress("00:11:22:33:44:55")
        ) { error in
            XCTAssertEqual(
                error as? DoryVZMacMachineBundleError,
                .invalidNetworkAddress("00:11:22:33:44:55")
            )
        }
    }

    func testDiskResizeRecoveryCommitsACompletedBackingImage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-vzmac-resize-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let oldBytes = 64 * DoryVZMacResourcePlan.gibibyte
        let newBytes = 96 * DoryVZMacResourcePlan.gibibyte
        let disk = root.appendingPathComponent(DoryVZMacMachineBundle.diskName)
        FileManager.default.createFile(atPath: disk.path, contents: Data())
        let diskHandle = try FileHandle(forWritingTo: disk)
        try diskHandle.truncate(atOffset: newBytes)
        try diskHandle.close()
        let original = try manifest(resources: try resourcePlan(diskBytes: oldBytes))
        let encoder = JSONEncoder()
        try encoder.encode(original).write(
            to: root.appendingPathComponent(DoryVZMacMachineBundle.manifestName)
        )
        try Data("{\"previousBytes\":\(oldBytes),\"requestedBytes\":\(newBytes)}".utf8).write(
            to: root.appendingPathComponent("system-disk-resize.json")
        )

        let recovered = try DoryVZMacMachineBundle.recoverPendingSystemDiskResize(
            at: root,
            manifest: original
        )
        XCTAssertEqual(recovered.resources.diskBytes, newBytes)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("system-disk-resize.json").path
        ))
        let persisted = try JSONDecoder().decode(
            DoryVZMacMachineManifest.self,
            from: Data(contentsOf: root.appendingPathComponent(DoryVZMacMachineBundle.manifestName))
        )
        XCTAssertEqual(persisted.resources.diskBytes, newBytes)
    }

    func testDataDiskResizeRecoveryCommitsOnlyTheMatchingDataImage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-vzmac-data-resize-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let oldBytes = 8 * DoryVZMacResourcePlan.gibibyte
        let newBytes = 12 * DoryVZMacResourcePlan.gibibyte
        let dataDirectory = root.appendingPathComponent(
            DoryVZMacMachineBundle.dataDisksDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: false)
        let disk = dataDirectory.appendingPathComponent("data-01.img")
        FileManager.default.createFile(atPath: disk.path, contents: Data())
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: newBytes)
        try handle.close()
        let original = try manifest(resources: try DoryVZMacResourcePlan(
            requestedCPUCount: 4,
            requestedMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
            requestedDiskBytes: 64 * DoryVZMacResourcePlan.gibibyte,
            requestedDisplays: nil,
            requestedDataDiskBytes: [oldBytes],
            minimumCPUCount: 2,
            minimumMemoryBytes: 4 * DoryVZMacResourcePlan.gibibyte,
            maximumCPUCount: 8,
            maximumMemoryBytes: 32 * DoryVZMacResourcePlan.gibibyte
        ))
        try Data("{\"index\":0,\"fileName\":\"data-01.img\",\"previousBytes\":\(oldBytes),\"requestedBytes\":\(newBytes)}".utf8).write(
            to: root.appendingPathComponent("data-disk-1-resize.json")
        )

        let recovered = try DoryVZMacMachineBundle.recoverPendingDataDiskResize(
            at: root,
            manifest: original,
            index: 0
        )
        XCTAssertEqual(recovered.resources.dataDisks.map(\.byteCount), [newBytes])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("data-disk-1-resize.json").path
        ))
    }

    func testRejectsInvalidRestoreSourceAndEmptyArtifact() throws {
        XCTAssertThrowsError(try manifest(sourceURL: "http://example.com/restore.ipsw").validate())
        XCTAssertThrowsError(try manifest(restoreBytes: 0).validate())
    }

    func testRequiresConsistentCloneLineage() throws {
        XCTAssertThrowsError(
            try manifest(origin: .created, parentDigest: String(repeating: "d", count: 64)).validate()
        )
        XCTAssertThrowsError(try manifest(origin: .cloned, parentDigest: nil).validate())
        try manifest(
            origin: .cloned,
            parentDigest: String(repeating: "d", count: 64)
        ).validate()
    }

    func testColdCloneRejectsNonStoppedSource() throws {
        let source = DoryVZMacMachineBundle(
            rootURL: FileManager.default.temporaryDirectory,
            manifest: try manifest()
        )
        XCTAssertThrowsError(
            try source.clone(
                to: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "dory-clone-\(UUID().uuidString)"
                )
            )
        ) { error in
            XCTAssertEqual(error as? DoryVZMacMachineBundleError, .cloneRequiresStoppedMachine)
        }
    }

    private func manifest(
        schema: String = DoryVZMacMachineManifest.schema,
        restoreDigest: String = String(repeating: "a", count: 64),
        sourceURL: String = "https://updates.cdn-apple.com/restore.ipsw",
        restoreBytes: UInt64 = 1,
        origin: DoryVZMacMachineOrigin = .created,
        parentDigest: String? = nil,
        macAddress: String = "02:11:22:33:44:55",
        resources: DoryVZMacResourcePlan? = nil
    ) throws -> DoryVZMacMachineManifest {
        DoryVZMacMachineManifest(
            schema: schema,
            createdAt: "2026-08-30T14:00:00Z",
            installationState: .prepared,
            origin: origin,
            parentMachineIdentifierSHA256: parentDigest,
            restoreImageBuild: "25A1",
            restoreImageVersion: "26.0.0",
            restoreImageSourceURL: sourceURL,
            restoreImageBytes: restoreBytes,
            restoreImageSHA256: restoreDigest,
            hardwareModelSHA256: String(repeating: "b", count: 64),
            machineIdentifierSHA256: String(repeating: "c", count: 64),
            macAddress: macAddress,
            resources: try resources ?? resourcePlan()
        )
    }

    private func resourcePlan(
        diskBytes: UInt64 = 80 * DoryVZMacResourcePlan.gibibyte
    ) throws -> DoryVZMacResourcePlan {
        try DoryVZMacResourcePlan(
            requestedCPUCount: 4,
            requestedMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
            requestedDiskBytes: diskBytes,
            requestedDisplays: nil,
            minimumCPUCount: 4,
            minimumMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
            maximumCPUCount: 12,
            maximumMemoryBytes: 64 * DoryVZMacResourcePlan.gibibyte
        )
    }
}
