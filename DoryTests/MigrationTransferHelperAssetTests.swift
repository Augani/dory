import Foundation
import Testing
@testable import Dory

@MainActor
struct MigrationTransferHelperAssetTests {
    @Test func exactCanonicalMetadataAndArchiveAreAccepted() throws {
        let fixture = try makeFixture()

        #expect(fixture.asset.archive == fixture.archive)
        #expect(fixture.asset.metadata.archiveSha256 == fixture.pins.archiveSha256)
        #expect(fixture.asset.metadata.platform == "linux/arm64")
        #expect(String(decoding: fixture.metadataData, as: UTF8.self).contains(
            #""platform":"linux/arm64""#
        ))
    }

    @Test func archiveOrMetadataDriftFailsClosed() throws {
        let fixture = try makeFixture()
        var changedArchive = fixture.archive
        changedArchive[0] ^= 0xFF

        #expect(throws: MigrationTransferHelperError.self) {
            try MigrationTransferHelperAsset(
                archive: changedArchive,
                metadataData: fixture.metadataData,
                pins: fixture.pins
            )
        }

        var noncanonicalMetadata = fixture.metadataData
        noncanonicalMetadata.removeLast()
        #expect(throws: MigrationTransferHelperError.self) {
            try MigrationTransferHelperAsset(
                archive: fixture.archive,
                metadataData: noncanonicalMetadata,
                pins: fixture.pins
            )
        }
    }

    @Test func installationLoadsInspectsAndOperationTagsTheExactImage() async throws {
        let fixture = try makeFixture()
        let runtime = TransferHelperRuntime(metadata: fixture.asset.metadata)
        let operationID = try #require(
            UUID(uuidString: "22222222-2222-2222-2222-222222222222")
        )

        let installation = try await fixture.asset.install(on: runtime, operationID: operationID)

        #expect(runtime.loadedArchives == [fixture.archive])
        #expect(runtime.inspectedImageIDs == [fixture.asset.metadata.imageConfigDigest])
        #expect(runtime.tags.count == 1)
        #expect(runtime.tags.first?.source == fixture.asset.metadata.imageConfigDigest)
        #expect(installation.imageID == fixture.asset.metadata.imageConfigDigest)
        #expect(installation.ownershipReference == (
            "dory.internal/operation-22222222-2222-2222-2222-222222222222:transfer-helper"
        ))
    }

    @Test func installationUsesContainerdManifestReceiptAfterExactContentInspection() async throws {
        let fixture = try makeFixture()
        let manifestID = "sha256:" + String(repeating: "d", count: 64)
        let runtime = TransferHelperRuntime(metadata: fixture.asset.metadata, engineImageID: manifestID)

        let installation = try await fixture.asset.install(on: runtime, operationID: UUID())

        #expect(installation.imageID == manifestID)
        #expect(runtime.tags.map(\.source) == [manifestID])
        #expect(runtime.inspectedImageIDs == [manifestID])
    }

    @Test func installationRejectsEngineThatReportsDifferentImageBytes() async throws {
        let fixture = try makeFixture()
        let runtime = TransferHelperRuntime(metadata: fixture.asset.metadata)
        runtime.overrideArchitecture = "amd64"

        await #expect(throws: MigrationTransferHelperError.self) {
            try await fixture.asset.install(on: runtime, operationID: UUID())
        }
        #expect(runtime.tags.isEmpty)
    }

    @Test func cleanupRestoresHelperThatWasAlreadyDangling() async throws {
        let fixture = try makeFixture()
        let runtime = TransferHelperRuntime(metadata: fixture.asset.metadata)
        runtime.imagePresent = true
        let operationID = try #require(
            UUID(uuidString: "33333333-3333-3333-3333-333333333333")
        )

        let installation = try await fixture.asset.install(on: runtime, operationID: operationID)
        try await fixture.asset.removeInstallation(installation, from: runtime)

        #expect(installation.restoreDanglingImageAfterCleanup)
        #expect(runtime.removedImages == [installation.ownershipReference])
        #expect(runtime.loadedArchives == [fixture.archive, fixture.archive])
        #expect(runtime.imagePresent)
    }

    @Test func failedTagRollsBackAHelperImageThatWasNotPreviouslyPresent() async throws {
        let fixture = try makeFixture()
        let runtime = TransferHelperRuntime(metadata: fixture.asset.metadata)
        runtime.failTag = true
        let operationID = try #require(
            UUID(uuidString: "55555555-5555-5555-5555-555555555555")
        )

        await #expect(throws: Error.self) {
            try await fixture.asset.install(on: runtime, operationID: operationID)
        }

        #expect(runtime.removedImages == [
            "dory.internal/operation-55555555-5555-5555-5555-555555555555:transfer-helper"
        ])
        #expect(!runtime.imagePresent)
    }
}

@MainActor
private extension MigrationTransferHelperAssetTests {
    struct Fixture {
        let archive: Data
        let metadataData: Data
        let pins: MigrationTransferHelperPins
        let asset: MigrationTransferHelperAsset
    }

    func makeFixture() throws -> Fixture {
        let archive = Data("deterministic-test-helper-archive".utf8)
        let digest = MigrationTransferHelperAsset.sha256(archive)
        let pins = MigrationTransferHelperPins(
            archiveBytes: archive.count,
            archiveSha256: digest,
            helperBytes: 17,
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
        return Fixture(
            archive: archive,
            metadataData: metadataData,
            pins: pins,
            asset: try MigrationTransferHelperAsset(
                archive: archive,
                metadataData: metadataData,
                pins: pins
            )
        )
    }
}

@MainActor
private final class TransferHelperRuntime: ContainerRuntime {
    struct ImageTag {
        let source: String
        let repository: String
        let tag: String
    }

    let kind: RuntimeKind = .docker
    nonisolated let supportsImageArchiveTransfer = true
    nonisolated let supportsImageLoadReceipt = true
    nonisolated let supportsRawProxy = true

    let metadata: MigrationTransferHelperMetadata
    let engineImageID: String
    var loadedArchives: [Data] = []
    var inspectedImageIDs: [String] = []
    var tags: [ImageTag] = []
    var removedImages: [String] = []
    var overrideArchitecture: String?
    var imagePresent = false
    var failTag = false

    init(metadata: MigrationTransferHelperMetadata, engineImageID: String? = nil) {
        self.metadata = metadata
        self.engineImageID = engineImageID ?? metadata.imageConfigDigest
    }

    func loadImage(tar: Data) async throws {
        loadedArchives.append(tar)
        imagePresent = true
    }

    func loadImageThrowingWithResponse(
        stream: AsyncThrowingStream<Data, Error>
    ) async throws -> Data {
        var bytes = Data()
        for try await chunk in stream { bytes.append(chunk) }
        try await loadImage(tar: bytes)
        return Data((#"{"stream":"Loaded image ID: \#(engineImageID)\n"}"# + "\r\n").utf8)
    }

    func proxyRequest(
        method: String,
        path: String,
        headers: [(name: String, value: String)],
        body: Data
    ) async -> HTTPResponse? {
        guard method == "GET", path.hasPrefix("/images/"), imagePresent else { return nil }
        inspectedImageIDs.append(engineImageID)
        let object: [String: Any] = [
            "Id": engineImageID,
            "Architecture": overrideArchitecture ?? "arm64",
            "Os": "linux",
            "RepoTags": [],
            "Config": [
                "Entrypoint": ["/dory-transfer-helper"],
                "User": "0",
                "WorkingDir": "/",
                "Labels": [
                    "dev.dory.component": "transfer-helper",
                    "dev.dory.helper.sha256": metadata.helperSha256,
                    "dev.dory.manifest.schema": "1"
                ]
            ],
            "RootFS": ["Layers": [metadata.layerDiffId]]
        ]
        let responseBody = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return HTTPResponse(statusCode: 200, reason: "OK", headers: [:], body: responseBody ?? Data())
    }

    func tagImage(source: String, repo: String, tag: String) async throws {
        if failTag { throw RuntimeFeatureError.unsupported("injected tag failure") }
        tags.append(ImageTag(source: source, repository: repo, tag: tag))
    }

    func removeImage(id: String) async throws {
        removedImages.append(id)
        imagePresent = false
    }

    func snapshot() async throws -> RuntimeSnapshot {
        guard imagePresent else { return RuntimeSnapshot() }
        return RuntimeSnapshot(images: [DockerImage(
            repository: "<none>",
            tag: "<none>",
            imageID: engineImageID,
            size: "1 KB",
            created: "now",
            usedByCount: 0,
            sizeBytes: 1_024
        )])
    }
    func start(containerID: String) async throws {}
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func create(_ spec: ContainerSpec) async throws -> String { "unused" }
    func exec(containerID: String, command: [String]) async throws -> ExecResult {
        ExecResult(exitCode: 0, output: "")
    }
}
