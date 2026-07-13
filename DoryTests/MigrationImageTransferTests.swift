import Foundation
import Testing
@testable import Dory

// The adversarial matrix and its stateful Docker double intentionally live together so every
// failure assertion is auditable against the simulated target effects.
// swiftlint:disable file_length

@MainActor
struct MigrationImageTransferTests {
    @Test func streamsVerifiesAndProducesDurableEvidenceWithoutPublishingTags() async throws {
        let fixture = ImageTransferFixture()
        let source = fixture.sourceRuntime()
        let target = fixture.targetRuntime()

        let receipt = try await MigrationImageTransfer().transfer(
            fixture.request,
            from: source,
            to: target
        )

        #expect(receipt.loadedTargetImageID == fixture.imageID)
        #expect(!receipt.targetImageWasPreexisting)
        #expect(receipt.sourceBeforeTransfer.archiveContractSha256
            == receipt.sourceDuringTransfer.archiveContractSha256)
        #expect(receipt.sourceBeforeTransfer.archiveContractSha256
            == receipt.sourceAfterTransfer.archiveContractSha256)
        #expect(receipt.verifiedTarget.semanticIdentity == fixture.imageID)
        #expect(receipt.loadResponseSha256
            == MigrationImageArchiveTestSupport.sha256(target.loadResponse))
        #expect(receipt.verificationManifestSha256
            == MigrationImageArchiveTestSupport.sha256(receipt.verificationManifest))
        let manifest = try JSONDecoder().decode(
            MigrationImageVerificationManifest.self,
            from: receipt.verificationManifest
        )
        #expect(manifest.operationID == fixture.request.operationID)
        #expect(manifest.loadedTargetImageID == fixture.imageID)
        #expect(source.savedReferences == [fixture.imageID, fixture.imageID, fixture.imageID])
        #expect(target.savedReferences == [fixture.imageID])
        #expect(target.receivedChunks.count > 1)
        #expect(target.removedImages.isEmpty)
        #expect(target.taggedReferences.isEmpty)
    }

    @Test func acceptsDifferentOuterTarSerializationForIdenticalSourceContent() async throws {
        let fixture = ImageTransferFixture(contentAddressed: true)
        let changedOuterArchive = fixture.archiveWithChangedOCILayoutVersion()
        let source = fixture.sourceRuntime(archives: [
            fixture.sourceFixture.archive,
            changedOuterArchive,
            fixture.sourceFixture.archive
        ])
        let target = fixture.targetRuntime()

        let receipt = try await MigrationImageTransfer().transfer(
            fixture.request,
            from: source,
            to: target
        )

        #expect(receipt.sourceBeforeTransfer.archiveSha256
            != receipt.sourceDuringTransfer.archiveSha256)
        #expect(receipt.sourceBeforeTransfer.archiveContractSha256
            == receipt.sourceDuringTransfer.archiveContractSha256)
    }

    @Test func sourceDriftDuringTransferRollsBackTheNewTargetImage() async throws {
        let fixture = ImageTransferFixture()
        let changed = fixture.changedContentFixture()
        let source = fixture.sourceRuntime(archives: [
            fixture.sourceFixture.archive,
            changed.archive,
            fixture.sourceFixture.archive
        ])
        let target = fixture.targetRuntime()

        await #expect(throws: MigrationImageTransferError.sourceDrift) {
            try await MigrationImageTransfer().transfer(fixture.request, from: source, to: target)
        }

        #expect(target.removedImages == [fixture.imageID])
        #expect(!target.imagePresent)
    }

    @Test func sourceDriftAfterTransferRollsBackTheNewTargetImage() async throws {
        let fixture = ImageTransferFixture()
        let changed = fixture.changedContentFixture()
        let source = fixture.sourceRuntime(archives: [
            fixture.sourceFixture.archive,
            fixture.sourceFixture.archive,
            changed.archive
        ])
        let target = fixture.targetRuntime()

        await #expect(throws: MigrationImageTransferError.sourceDrift) {
            try await MigrationImageTransfer().transfer(fixture.request, from: source, to: target)
        }

        #expect(target.removedImages == [fixture.imageID])
        #expect(!target.imagePresent)
    }

    @Test func independentTargetReadbackMismatchRollsBack() async throws {
        let fixture = ImageTransferFixture()
        let target = fixture.targetRuntime(targetArchive: fixture.changedContentFixture().archive)

        await #expect(throws: MigrationImageTransferError.targetMismatch) {
            try await MigrationImageTransfer().transfer(
                fixture.request,
                from: fixture.sourceRuntime(),
                to: target
            )
        }

        #expect(target.removedImages == [fixture.imageID])
        #expect(!target.imagePresent)
    }

    @Test func malformedOrEmptyLoadReceiptsRollBackByExpectedContentIdentity() async throws {
        let fixture = ImageTransferFixture()
        let responses = [Data(), Data(#"{"stream":"Loaded image\n"}"#.utf8)]

        for response in responses {
            let target = fixture.targetRuntime(loadResponse: response)
            await #expect(throws: MigrationImageLoadReceiptError.self) {
                try await MigrationImageTransfer().transfer(
                    fixture.request,
                    from: fixture.sourceRuntime(),
                    to: target
                )
            }
            #expect(target.removedImages == [fixture.imageID])
            #expect(!target.imagePresent)
        }
    }

    @Test func mismatchedLoadIdentityFailsAndRemovesOnlyTheExpectedContent() async throws {
        let fixture = ImageTransferFixture()
        let wrongID = "sha256:" + String(repeating: "e", count: 64)
        let target = fixture.targetRuntime(loadResponse: ImageTransferRuntime.response(for: wrongID))

        await #expect(throws: MigrationImageTransferError.loadIdentityMismatch(
            expected: fixture.imageID,
            actual: wrongID
        )) {
            try await MigrationImageTransfer().transfer(
                fixture.request,
                from: fixture.sourceRuntime(),
                to: target
            )
        }

        #expect(target.removedImages == [fixture.imageID])
        #expect(!target.imagePresent)
    }

    @Test func targetThatStopsReadingEarlyCannotTurnATruncatedArchiveIntoSuccess() async throws {
        let fixture = ImageTransferFixture()
        let target = fixture.targetRuntime()
        target.maximumConsumedChunks = 1

        await #expect(throws: MigrationImageTransferError.sourceStreamIncomplete) {
            try await MigrationImageTransfer().transfer(
                fixture.request,
                from: fixture.sourceRuntime(),
                to: target
            )
        }

        #expect(target.receivedChunks.count == 1)
        #expect(target.removedImages == [fixture.imageID])
    }

    @Test func sourceStreamFailurePropagatesAndRestoresTargetInventory() async throws {
        let fixture = ImageTransferFixture()
        let source = fixture.sourceRuntime(emissions: [
            ImageArchiveEmission(data: fixture.sourceFixture.archive),
            ImageArchiveEmission(data: fixture.sourceFixture.archive, failsAfterFirstChunk: true)
        ])
        let target = fixture.targetRuntime()

        await #expect(throws: ImageTransferRuntime.Failure.injected) {
            try await MigrationImageTransfer().transfer(fixture.request, from: source, to: target)
        }

        #expect(target.removedImages == [fixture.imageID])
        #expect(!target.imagePresent)
    }

    @Test func failedVerificationNeverDeletesAPreexistingTargetImage() async throws {
        let fixture = ImageTransferFixture()
        let target = fixture.targetRuntime(
            targetArchive: fixture.changedContentFixture().archive,
            preexisting: true
        )

        await #expect(throws: MigrationImageTransferError.targetMismatch) {
            try await MigrationImageTransfer().transfer(
                fixture.request,
                from: fixture.sourceRuntime(),
                to: target
            )
        }

        #expect(target.removedImages.isEmpty)
        #expect(target.imagePresent)
    }

    @Test func cleanupFailureIsPartOfTheOperationFailure() async throws {
        let fixture = ImageTransferFixture()
        let target = fixture.targetRuntime(targetArchive: fixture.changedContentFixture().archive)
        target.failRemoval = true

        await #expect(throws: MigrationImageTransferError.self) {
            try await MigrationImageTransfer().transfer(
                fixture.request,
                from: fixture.sourceRuntime(),
                to: target
            )
        }

        #expect(target.imagePresent)
        #expect(target.removedImages == [fixture.imageID])
    }

    @Test func rejectsMutableOrUnsupportedTransferRequestsBeforeReadingSource() async throws {
        let fixture = ImageTransferFixture()
        let source = fixture.sourceRuntime()
        let target = fixture.targetRuntime(supportsReceipts: false)

        await #expect(throws: MigrationImageTransferError.unsupported(
            "target engine does not return immutable image-load receipts"
        )) {
            try await MigrationImageTransfer().transfer(fixture.request, from: source, to: target)
        }
        await #expect(throws: MigrationImageTransferError.invalidRequest(
            "source image ID must be a complete lowercase sha256 digest"
        )) {
            try await MigrationImageTransfer().transfer(
                MigrationImageTransferRequest(
                    operationID: fixture.request.operationID,
                    sourceImageID: "example/app:latest"
                ),
                from: source,
                to: fixture.targetRuntime()
            )
        }

        #expect(source.savedReferences.isEmpty)
    }
}

@MainActor
private struct ImageTransferFixture {
    let sourceFixture: MigrationImageArchiveTestFixture
    let request: MigrationImageTransferRequest

    init(contentAddressed: Bool = false) {
        sourceFixture = contentAddressed
            ? MigrationImageArchiveTestSupport.contentAddressedFixture()
            : MigrationImageArchiveTestSupport.fixture()
        request = MigrationImageTransferRequest(
            operationID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            sourceImageID: "sha256:\(sourceFixture.configDigest)"
        )
    }

    var imageID: String { "sha256:\(sourceFixture.configDigest)" }

    func sourceRuntime(
        archives: [Data]? = nil,
        emissions: [ImageArchiveEmission]? = nil
    ) -> ImageTransferRuntime {
        ImageTransferRuntime(
            side: .source,
            imageID: imageID,
            sourceEmissions: emissions ?? (archives ?? Array(repeating: sourceFixture.archive, count: 3))
                .map { ImageArchiveEmission(data: $0) },
            targetArchive: sourceFixture.archive
        )
    }

    func targetRuntime(
        targetArchive: Data? = nil,
        loadResponse: Data? = nil,
        preexisting: Bool = false,
        supportsReceipts: Bool = true
    ) -> ImageTransferRuntime {
        ImageTransferRuntime(
            side: .target,
            imageID: imageID,
            sourceEmissions: [],
            targetArchive: targetArchive ?? sourceFixture.archive,
            loadResponse: loadResponse,
            preexisting: preexisting,
            supportsReceipts: supportsReceipts
        )
    }

    func changedContentFixture() -> MigrationImageArchiveTestFixture {
        MigrationImageArchiveTestSupport.fixture(layerPayloads: [
            Data("changed first rootfs layer".utf8),
            Data("changed second rootfs layer".utf8)
        ])
    }

    func archiveWithChangedOCILayoutVersion() -> Data {
        MigrationImageArchiveTestSupport.archive(sourceFixture.entries.map { entry in
            entry.path == "oci-layout"
                ? MigrationImageTarTestEntry(
                    path: entry.path,
                    payload: MigrationImageArchiveTestSupport.json([
                        "imageLayoutVersion": "1.0.1"
                    ])
                )
                : entry
        })
    }
}

private struct ImageArchiveEmission {
    let data: Data
    var failsAfterFirstChunk = false
}

@MainActor
private final class ImageTransferRuntime: ContainerRuntime {
    enum Side { case source, target }
    enum Failure: Error { case injected }

    let kind: RuntimeKind = .docker
    nonisolated let supportsImageArchiveTransfer = true
    nonisolated let supportsImageLoadReceipt: Bool
    let side: Side
    let imageID: String
    let targetArchive: Data
    let preexisting: Bool
    var sourceEmissions: [ImageArchiveEmission]
    var loadResponse: Data
    var maximumConsumedChunks: Int?
    var failRemoval = false
    var imagePresent: Bool
    var savedReferences: [String] = []
    var receivedChunks: [Data] = []
    var removedImages: [String] = []
    var taggedReferences: [String] = []

    init(
        side: Side,
        imageID: String,
        sourceEmissions: [ImageArchiveEmission],
        targetArchive: Data,
        loadResponse: Data? = nil,
        preexisting: Bool = false,
        supportsReceipts: Bool = true
    ) {
        self.side = side
        self.imageID = imageID
        self.sourceEmissions = sourceEmissions
        self.targetArchive = targetArchive
        self.preexisting = preexisting
        supportsImageLoadReceipt = supportsReceipts
        self.loadResponse = loadResponse ?? Self.response(for: imageID)
        imagePresent = preexisting
    }

    func snapshot() async throws -> RuntimeSnapshot {
        guard side == .target, imagePresent else { return RuntimeSnapshot() }
        return RuntimeSnapshot(images: [DockerImage(
            repository: "<none>",
            tag: "<none>",
            imageID: imageID,
            size: "1 KB",
            created: "now",
            usedByCount: 0,
            sizeBytes: 1_024,
            createdEpoch: 1
        )])
    }

    func start(containerID: String) async throws {}
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func create(_ spec: ContainerSpec) async throws -> String { "created" }
    func exec(containerID: String, command: [String]) async throws -> ExecResult {
        ExecResult(exitCode: 0, output: "")
    }

    func saveImageThrowing(reference: String) -> AsyncThrowingStream<Data, Error> {
        savedReferences.append(reference)
        let emission: ImageArchiveEmission
        if side == .source {
            guard !sourceEmissions.isEmpty else {
                return AsyncThrowingStream { $0.finish(throwing: Failure.injected) }
            }
            emission = sourceEmissions.removeFirst()
        } else {
            emission = ImageArchiveEmission(data: targetArchive)
        }
        return Self.stream(emission)
    }

    func loadImageThrowingWithResponse(
        stream: AsyncThrowingStream<Data, Error>
    ) async throws -> Data {
        for try await chunk in stream {
            receivedChunks.append(chunk)
            if let maximumConsumedChunks,
               receivedChunks.count >= maximumConsumedChunks {
                imagePresent = true
                return loadResponse
            }
        }
        imagePresent = true
        return loadResponse
    }

    func removeImage(id: String) async throws {
        removedImages.append(id)
        if failRemoval { throw Failure.injected }
        if id == imageID, !preexisting { imagePresent = false }
    }

    func tagImage(source: String, repo: String, tag: String) async throws {
        taggedReferences.append("\(repo):\(tag)")
    }

    nonisolated static func response(for imageID: String) -> Data {
        Data((#"{"stream":"Loaded image ID: \#(imageID)\n"}"# + "\r\n").utf8)
    }

    private static func stream(
        _ emission: ImageArchiveEmission
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let chunkBytes = 257
            var offset = 0
            var chunkCount = 0
            while offset < emission.data.count {
                let end = min(offset + chunkBytes, emission.data.count)
                continuation.yield(emission.data.subdata(in: offset..<end))
                offset = end
                chunkCount += 1
                if emission.failsAfterFirstChunk, chunkCount == 1 {
                    continuation.finish(throwing: Failure.injected)
                    return
                }
            }
            continuation.finish()
        }
    }
}
