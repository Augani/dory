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
        macAddress: String = "02:11:22:33:44:55"
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
            resources: try DoryVZMacResourcePlan(
                requestedCPUCount: 4,
                requestedMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
                requestedDiskBytes: 80 * DoryVZMacResourcePlan.gibibyte,
                minimumCPUCount: 4,
                minimumMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
                maximumCPUCount: 12,
                maximumMemoryBytes: 64 * DoryVZMacResourcePlan.gibibyte
            )
        )
    }
}
