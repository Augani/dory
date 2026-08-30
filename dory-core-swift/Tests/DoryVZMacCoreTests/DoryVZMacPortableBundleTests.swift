import XCTest
@testable import DoryVZMacCore

final class DoryVZMacPortableBundleTests: XCTestCase {
    func testAcceptsExactColdPortableArtifactSet() throws {
        try manifest().validate()
    }

    func testRejectsUnknownSchemaAndNonColdConsistency() throws {
        XCTAssertThrowsError(try manifest(schema: "dory.vzmac-portable@2").validate())
        XCTAssertThrowsError(try manifest(consistency: "live").validate())
    }

    func testRejectsMissingDuplicateAndTraversalPaths() throws {
        let valid = files()
        XCTAssertThrowsError(try manifest(files: Array(valid.dropLast())).validate())
        XCTAssertThrowsError(try manifest(files: valid + [valid[0]]).validate())
        var traversal = valid
        traversal[0] = DoryVZMacPortableFile(
            relativePath: "../disk.img",
            bytes: 1,
            sha256: String(repeating: "a", count: 64)
        )
        XCTAssertThrowsError(try manifest(files: traversal).validate())
    }

    func testRejectsMalformedArtifactMetadataAndIdentity() throws {
        var invalidBytes = files()
        invalidBytes[0] = DoryVZMacPortableFile(
            relativePath: invalidBytes[0].relativePath,
            bytes: 0,
            sha256: invalidBytes[0].sha256
        )
        XCTAssertThrowsError(try manifest(files: invalidBytes).validate())
        XCTAssertThrowsError(try manifest(identity: "ABC").validate())
    }

    private func manifest(
        schema: String = DoryVZMacPortableManifest.schema,
        identity: String = String(repeating: "b", count: 64),
        consistency: String = "cold-stopped",
        files: [DoryVZMacPortableFile]? = nil
    ) -> DoryVZMacPortableManifest {
        DoryVZMacPortableManifest(
            schema: schema,
            createdAt: "2026-08-30T18:00:00Z",
            sourceMachineIdentifierSHA256: identity,
            consistency: consistency,
            files: files ?? self.files()
        )
    }

    private func files() -> [DoryVZMacPortableFile] {
        [
            DoryVZMacMachineBundle.manifestName,
            DoryVZMacMachineBundle.diskName,
            DoryVZMacMachineBundle.auxiliaryStorageName,
            DoryVZMacMachineBundle.hardwareModelName,
            DoryVZMacMachineBundle.machineIdentifierName,
        ].map {
            DoryVZMacPortableFile(
                relativePath: $0,
                bytes: 1,
                sha256: String(repeating: "a", count: 64)
            )
        }
    }
}
