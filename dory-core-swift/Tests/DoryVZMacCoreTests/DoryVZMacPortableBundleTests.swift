import XCTest
@testable import DoryVZMacCore

final class DoryVZMacPortableBundleTests: XCTestCase {
    func testAcceptsExactColdPortableArtifactSet() throws {
        try manifest().validate()
    }

    func testRejectsUnknownSchemaAndNonColdConsistency() throws {
        XCTAssertThrowsError(try manifest(schema: "dory.vzmac-portable@3").validate())
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

    func testLegacySingleDiskExportRemainsReadableWithoutReinterpretation() throws {
        let legacy = manifest(schema: DoryVZMacPortableManifest.legacySchema)
        let decoded = try JSONDecoder().decode(
            DoryVZMacPortableManifest.self, from: JSONEncoder().encode(legacy)
        )
        XCTAssertEqual(decoded.schema, DoryVZMacPortableManifest.legacySchema)
        try decoded.validateArtifacts(for: machine(dataDiskCount: 0))
        XCTAssertThrowsError(try legacy.validateArtifacts(for: machine(dataDiskCount: 1)))
        XCTAssertThrowsError(try manifest(
            schema: DoryVZMacPortableManifest.legacySchema,
            files: files() + [dataFile(1)]
        ).validate())
    }

    func testVersionTwoBindsAllManagedDataDisksToMachineResources() throws {
        for count in 0...DoryVZMacResourcePlan.maximumDataDiskCount {
            let disks = (0..<count).map { dataFile($0 + 1) }
            let portable = manifest(files: files() + disks)
            try portable.validateArtifacts(for: machine(dataDiskCount: count))
            if count < DoryVZMacResourcePlan.maximumDataDiskCount {
                XCTAssertThrowsError(try portable.validateArtifacts(for: machine(dataDiskCount: count + 1)))
            }
            if count > 0 {
                XCTAssertThrowsError(try portable.validateArtifacts(for: machine(dataDiskCount: count - 1)))
            }
        }
    }

    func testRejectsDataDiskHolesAliasesOverflowAndDuplicates() throws {
        XCTAssertThrowsError(try manifest(files: files() + [dataFile(2)]).validate())
        XCTAssertThrowsError(try manifest(files: files() + [dataFile(1), dataFile(1)]).validate())
        for path in ["data-disks/../disk.img", "data-disks/data-1.img", "data-disks/data-09.img",
                     "data-disks/data-01.img/extra", "data-disks/data-٠١.img", "/data-disks/data-01.img"] {
            let file = DoryVZMacPortableFile(relativePath: path, bytes: 1, sha256: String(repeating: "a", count: 64))
            XCTAssertThrowsError(try manifest(files: files() + [file]).validate())
        }
    }

    func testReceiptRejectsNonColdMachineAndWrongMachineIdentity() throws {
        let portable = manifest()
        XCTAssertThrowsError(try portable.validateArtifacts(for: machine(dataDiskCount: 0, state: .suspended)))
        XCTAssertThrowsError(try manifest(identity: String(repeating: "c", count: 64)).validateArtifacts(
            for: machine(dataDiskCount: 0)
        ))
    }

    func testReceiptRejectsDiskCapacitiesDifferentFromTheResourcePlan() throws {
        var wrongSystem = files()
        let index = try XCTUnwrap(wrongSystem.firstIndex { $0.relativePath == DoryVZMacMachineBundle.diskName })
        wrongSystem[index] = DoryVZMacPortableFile(
            relativePath: DoryVZMacMachineBundle.diskName, bytes: 1, sha256: String(repeating: "a", count: 64)
        )
        XCTAssertThrowsError(try manifest(files: wrongSystem).validateArtifacts(for: machine(dataDiskCount: 0)))
        let wrongData = DoryVZMacPortableFile(
            relativePath: "data-disks/data-01.img", bytes: 1, sha256: String(repeating: "a", count: 64)
        )
        XCTAssertThrowsError(try manifest(files: files() + [wrongData]).validateArtifacts(for: machine(dataDiskCount: 1)))
    }

    func testCopyIncludesIndependentDataDiskFilesAndPublishesCompleteTree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("data-disks", isDirectory: true),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        let paths = try DoryVZMacMachineBundle.artifactPaths(for: machine(dataDiskCount: 2).resources)
        for path in paths { try Data(path.utf8).write(to: source.appendingPathComponent(path)) }
        try DoryVZMacPortableBundle.copyArtifacts(from: source, to: staging, relativePaths: paths)
        let destination = root.appendingPathComponent("published", isDirectory: true)
        try DoryVZMacBundlePublication.publish(staging: staging, to: destination, relativeFiles: paths)
        for path in paths { XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(path)), Data(path.utf8)) }
        let dataPath = "data-disks/data-01.img"
        try Data("changed-copy".utf8).write(to: destination.appendingPathComponent(dataPath))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(dataPath)), Data(dataPath.utf8))
    }

    func testCopyRejectsTraversalBeforeAllocatingAnything() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try DoryVZMacPortableBundle.copyArtifacts(
            from: root, to: root, relativePaths: ["data-disks/data-01.img", "../external.img"]
        ))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    private func dataFile(_ index: Int) -> DoryVZMacPortableFile {
        DoryVZMacPortableFile(
            relativePath: "data-disks/\(String(format: "data-%02d.img", index))",
            bytes: DoryVZMacResourcePlan.gibibyte, sha256: String(repeating: "a", count: 64)
        )
    }

    private func machine(
        dataDiskCount: Int, state: DoryVZMacMachineInstallationState = .stopped
    ) throws -> DoryVZMacMachineManifest {
        let resources = try DoryVZMacResourcePlan(
            requestedCPUCount: 4, requestedMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
            requestedDiskBytes: 64 * DoryVZMacResourcePlan.gibibyte, requestedDisplays: nil,
            requestedDataDiskBytes: Array(repeating: DoryVZMacResourcePlan.gibibyte, count: dataDiskCount),
            minimumCPUCount: 2, minimumMemoryBytes: 4 * DoryVZMacResourcePlan.gibibyte,
            maximumCPUCount: 8, maximumMemoryBytes: 32 * DoryVZMacResourcePlan.gibibyte
        )
        return DoryVZMacMachineManifest(
            createdAt: "2026-10-02T00:00:00Z", installationState: state, origin: .created,
            parentMachineIdentifierSHA256: nil, restoreImageBuild: "27A266a", restoreImageVersion: "27.0",
            restoreImageSourceURL: "https://updates.cdn-apple.com/restore.ipsw", restoreImageBytes: 1,
            restoreImageSHA256: String(repeating: "a", count: 64), hardwareModelSHA256: String(repeating: "a", count: 64),
            machineIdentifierSHA256: String(repeating: "b", count: 64), macAddress: "02:11:22:33:44:55", resources: resources
        )
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
                bytes: $0 == DoryVZMacMachineBundle.diskName ? 64 * DoryVZMacResourcePlan.gibibyte : 1,
                sha256: String(repeating: "a", count: 64)
            )
        }
    }
}
