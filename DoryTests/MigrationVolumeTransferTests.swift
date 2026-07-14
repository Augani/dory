import Foundation
import Testing
@testable import Dory

@MainActor
struct MigrationVolumeTransferTests {
    @Test func transfersRepairsRescansAndCleansEveryOwnedArtifact() async throws {
        let fixture = try TransferFixture()
        let source = VolumeTransferRuntime(metadata: fixture.asset.metadata, side: .source)
        let target = VolumeTransferRuntime(metadata: fixture.asset.metadata, side: .target)
        source.initialManifest = fixture.sourceManifest
        source.sourceAfterManifest = fixture.sourceManifest
        target.targetManifest = fixture.targetManifest

        let receipt = try await MigrationVolumeTransfer(helperAsset: fixture.asset).transfer(
            fixture.request,
            from: source,
            to: target
        )

        #expect(receipt.sourceManifest == fixture.sourceManifest)
        #expect(receipt.targetManifest == fixture.targetManifest)
        #expect(receipt.sourceEntryCount == 2)
        #expect(receipt.verifiedTargetEntryCount == 1)
        #expect(receipt.excludedSocketCount == 1)
        #expect(!receipt.containsDeviceNodes)
        #expect(source.createdSpecs.count == 2)
        #expect(target.createdSpecs.count == 3)
        #expect(source.removedContainers == Array(source.createdIDs.reversed()))
        #expect(target.removedContainers == Array(target.createdIDs.reversed()))
        #expect(source.removedImages.count == 1)
        #expect(target.removedImages.count == 1)
        #expect(target.receivedDataArchive == source.dataArchive)
        #expect(target.receivedManifestArchive == MigrationTestTar.singleFile(
            name: "manifest.json",
            contents: fixture.sourceManifest
        ))

        let specs = source.createdSpecs + target.createdSpecs
        #expect(specs.allSatisfy { $0.image == fixture.asset.metadata.imageConfigDigest })
        #expect(specs.allSatisfy { $0.platform == "linux/arm64" })
        #expect(specs.allSatisfy { $0.networkMode == "none" && $0.networkDisabled == true })
        #expect(specs.allSatisfy { $0.labels["dev.dory.operation.state"] == "staging" })
        #expect(specs.allSatisfy {
            $0.labels["dev.dory.source.authority"] == fixture.request.sourceAuthorityHash
        })
        let sourceSpecs = source.createdSpecs
        #expect(sourceSpecs.allSatisfy { $0.mounts.first?.readOnly == true })
        let targetScan = try #require(target.createdSpecs.first {
            $0.labels["dev.dory.operation.role"] == "target-scan"
        })
        #expect(targetScan.mounts.first?.readOnly == true)
        let repair = try #require(target.createdSpecs.first {
            $0.labels["dev.dory.operation.role"] == "target-repair"
        })
        #expect(repair.command == [
            "repair", "--root", "/data", "--manifest", "/manifest.json"
        ])
    }

    @Test func sourceDriftFailsClosedAndStillCleansHelpers() async throws {
        let fixture = try TransferFixture()
        let source = VolumeTransferRuntime(metadata: fixture.asset.metadata, side: .source)
        let target = VolumeTransferRuntime(metadata: fixture.asset.metadata, side: .target)
        source.initialManifest = fixture.sourceManifest
        source.sourceAfterManifest = fixture.changedSourceManifest
        target.targetManifest = fixture.targetManifest

        await #expect(throws: MigrationVolumeTransferError.sourceDrift) {
            try await MigrationVolumeTransfer(helperAsset: fixture.asset).transfer(
                fixture.request,
                from: source,
                to: target
            )
        }

        #expect(source.liveContainers.isEmpty)
        #expect(target.liveContainers.isEmpty)
        #expect(target.createdSpecs.allSatisfy {
            $0.labels["dev.dory.operation.role"] != "target-scan"
        })
    }

    @Test func independentlyScannedTargetMismatchFailsClosed() async throws {
        let fixture = try TransferFixture()
        let source = VolumeTransferRuntime(metadata: fixture.asset.metadata, side: .source)
        let target = VolumeTransferRuntime(metadata: fixture.asset.metadata, side: .target)
        source.initialManifest = fixture.sourceManifest
        source.sourceAfterManifest = fixture.sourceManifest
        target.targetManifest = fixture.changedTargetManifest

        await #expect(throws: MigrationVolumeTransferError.targetMismatch) {
            try await MigrationVolumeTransfer(helperAsset: fixture.asset).transfer(
                fixture.request,
                from: source,
                to: target
            )
        }
        #expect(source.liveContainers.isEmpty)
        #expect(target.liveContainers.isEmpty)
    }

    @Test func repairFailureNeverRescansOrPublishesSuccess() async throws {
        let fixture = try TransferFixture()
        let source = VolumeTransferRuntime(metadata: fixture.asset.metadata, side: .source)
        let target = VolumeTransferRuntime(metadata: fixture.asset.metadata, side: .target)
        source.initialManifest = fixture.sourceManifest
        target.failingRole = "target-repair"

        await #expect(throws: MigrationVolumeTransferError.self) {
            try await MigrationVolumeTransfer(helperAsset: fixture.asset).transfer(
                fixture.request,
                from: source,
                to: target
            )
        }
        #expect(source.createdSpecs.count == 1)
        #expect(target.createdSpecs.count == 2)
        #expect(source.liveContainers.isEmpty)
        #expect(target.liveContainers.isEmpty)
    }

    @Test func archiveStreamingFailureIsNotConvertedIntoSuccess() async throws {
        let fixture = try TransferFixture()
        let source = VolumeTransferRuntime(metadata: fixture.asset.metadata, side: .source)
        let target = VolumeTransferRuntime(metadata: fixture.asset.metadata, side: .target)
        source.initialManifest = fixture.sourceManifest
        source.failDataArchiveStream = true

        await #expect(throws: Error.self) {
            try await MigrationVolumeTransfer(helperAsset: fixture.asset).transfer(
                fixture.request,
                from: source,
                to: target
            )
        }
        #expect(source.liveContainers.isEmpty)
        #expect(target.liveContainers.isEmpty)
        #expect(target.createdSpecs.count == 1)
    }

    @Test func cleanupFailureMakesAnOtherwiseVerifiedTransferFail() async throws {
        let fixture = try TransferFixture()
        let source = VolumeTransferRuntime(metadata: fixture.asset.metadata, side: .source)
        let target = VolumeTransferRuntime(metadata: fixture.asset.metadata, side: .target)
        source.initialManifest = fixture.sourceManifest
        source.sourceAfterManifest = fixture.sourceManifest
        target.targetManifest = fixture.targetManifest
        target.failImageCleanup = true

        await #expect(throws: MigrationVolumeTransferError.self) {
            try await MigrationVolumeTransfer(helperAsset: fixture.asset).transfer(
                fixture.request,
                from: source,
                to: target
            )
        }
        #expect(source.liveContainers.isEmpty)
        #expect(target.liveContainers.isEmpty)
    }
}

@MainActor
struct MigrationVolumeManifestTests {
    @Test func validatesAndNormalizesOnlySockets() throws {
        let fixture = try TransferFixture()
        let source = try MigrationVolumeManifest.decodeAndValidate(fixture.sourceManifest)
        let target = try MigrationVolumeManifest.decodeAndValidate(fixture.targetManifest)

        #expect(source.socketCount == 1)
        #expect(source.normalizedTarget == target)
    }

    @Test func rejectsUnsafePathsUnknownFieldsAndUppercaseHex() throws {
        let unsafe = try TransferManifestFixture.manifest(pathHex: "612f2e2e2f62")
        #expect(throws: MigrationVolumeManifestError.self) {
            try MigrationVolumeManifest.decodeAndValidate(unsafe)
        }

        var object = TransferManifestFixture.manifestObject(pathHex: "66696c65")
        object["unexpected"] = true
        let unknown = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        #expect(throws: MigrationVolumeManifestError.self) {
            try MigrationVolumeManifest.decodeAndValidate(unknown)
        }

        let uppercase = try TransferManifestFixture.manifest(pathHex: "4A")
        #expect(throws: MigrationVolumeManifestError.self) {
            try MigrationVolumeManifest.decodeAndValidate(uppercase)
        }
    }
}

@MainActor
struct MigrationTarArchiveTests {
    @Test func extractsOnlyTheExpectedChecksummedRegularFile() throws {
        let contents = Data("manifest".utf8)
        let archive = MigrationTestTar.singleFile(name: "manifest.json", contents: contents)

        #expect(try MigrationTarArchive.extractSingleRegularFile(
            named: "manifest.json",
            from: archive
        ) == contents)
    }

    @Test func rejectsChecksumDriftTraversalDuplicatesAndTruncation() throws {
        let contents = Data("manifest".utf8)
        var checksumDrift = MigrationTestTar.singleFile(
            name: "manifest.json",
            contents: contents
        )
        checksumDrift[0] ^= 1
        #expect(throws: MigrationTarArchiveError.self) {
            try MigrationTarArchive.extractSingleRegularFile(
                named: "manifest.json",
                from: checksumDrift
            )
        }

        let traversal = MigrationTestTar.singleFile(name: "../manifest.json", contents: contents)
        #expect(throws: MigrationTarArchiveError.self) {
            try MigrationTarArchive.extractSingleRegularFile(
                named: "manifest.json",
                from: traversal
            )
        }

        let duplicate = MigrationTestTar.files([
            ("manifest.json", contents), ("manifest.json", contents)
        ])
        #expect(throws: MigrationTarArchiveError.self) {
            try MigrationTarArchive.extractSingleRegularFile(
                named: "manifest.json",
                from: duplicate
            )
        }

        var truncated = MigrationTestTar.singleFile(name: "manifest.json", contents: contents)
        truncated.removeLast(1_025)
        #expect(throws: MigrationTarArchiveError.self) {
            try MigrationTarArchive.extractSingleRegularFile(
                named: "manifest.json",
                from: truncated
            )
        }
    }
}

@MainActor
struct TransferFixture {
    let asset: MigrationTransferHelperAsset
    let request: MigrationVolumeTransferRequest
    let sourceManifest: Data
    let targetManifest: Data
    let changedSourceManifest: Data
    let changedTargetManifest: Data

    init() throws {
        let archive = Data("volume-transfer-test-helper".utf8)
        let digest = MigrationTransferHelperAsset.sha256(archive)
        let pins = MigrationTransferHelperPins(
            archiveBytes: archive.count,
            archiveSha256: digest,
            helperBytes: 99,
            helperSha256: String(repeating: "a", count: 64),
            imageConfigDigest: "sha256:" + String(repeating: "b", count: 64),
            layerDiffId: "sha256:" + String(repeating: "c", count: 64)
        )
        let metadata = MigrationTransferHelperMetadata(
            archiveBytes: pins.archiveBytes,
            archiveSha256: pins.archiveSha256,
            helperBytes: pins.helperBytes,
            helperSha256: pins.helperSha256,
            imageConfigDigest: pins.imageConfigDigest,
            layerDiffId: pins.layerDiffId,
            platform: "linux/arm64",
            schemaVersion: 1
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var metadataData = try encoder.encode(metadata)
        metadataData.append(0x0A)
        asset = try MigrationTransferHelperAsset(
            archive: archive,
            metadataData: metadataData,
            pins: pins
        )
        request = MigrationVolumeTransferRequest(
            operationID: try #require(UUID(
                uuidString: "44444444-4444-4444-4444-444444444444"
            )),
            sourceAuthorityHash: String(repeating: "d", count: 64),
            sourceVolume: "orb-data",
            targetVolume: "dory-data"
        )
        sourceManifest = try TransferManifestFixture.manifest(includeSocket: true)
        targetManifest = try TransferManifestFixture.manifest(includeSocket: false)
        changedSourceManifest = try TransferManifestFixture.manifest(
            includeSocket: true,
            contentDigest: String(repeating: "e", count: 64)
        )
        changedTargetManifest = try TransferManifestFixture.manifest(
            includeSocket: false,
            contentDigest: String(repeating: "f", count: 64)
        )
    }
}

private enum TransferManifestFixture {
    static func manifest(
        includeSocket: Bool = false,
        contentDigest: String = String(repeating: "a", count: 64),
        pathHex: String = "66696c65"
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: manifestObject(
                includeSocket: includeSocket,
                contentDigest: contentDigest,
                pathHex: pathHex
            ),
            options: [.sortedKeys]
        )
    }

    static func manifestObject(
        includeSocket: Bool = false,
        contentDigest: String = String(repeating: "a", count: 64),
        pathHex: String = "66696c65"
    ) -> [String: Any] {
        var entries = [entry(
            pathHex: pathHex,
            kind: "regular_file",
            size: 4,
            contentDigest: contentDigest,
            extents: [["offset": 0, "length": 4]]
        )]
        if includeSocket {
            entries.append(entry(pathHex: "736f636b6574", kind: "socket"))
        }
        return [
            "schema_version": 1,
            "root": entry(pathHex: "", kind: "directory", mode: 0o751),
            "entries": entries
        ]
    }

    static func entry(
        pathHex: String,
        kind: String,
        mode: Int = 0o640,
        size: Int = 0,
        contentDigest: String? = nil,
        extents: [[String: Int]]? = nil
    ) -> [String: Any] {
        [
            "path_hex": pathHex,
            "kind": kind,
            "mode": mode,
            "uid": 111,
            "gid": 222,
            "size": size,
            "mtime_seconds": 1_712_345_678,
            "mtime_nanoseconds": 123_456_789,
            "content_sha256": contentDigest ?? NSNull(),
            "link_target_hex": NSNull(),
            "hard_link_target_hex": NSNull(),
            "sparse_data_extents": extents ?? NSNull(),
            "device_major": NSNull(),
            "device_minor": NSNull(),
            "xattrs": []
        ]
    }
}
