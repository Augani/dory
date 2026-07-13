import CryptoKit
import Foundation

nonisolated struct MigrationImageTargetInventory: Codable, Sendable, Equatable {
    struct Entry: Codable, Sendable, Equatable {
        let id: String
        let references: [String]
        let labels: [String: String]
        let sizeBytes: Int64
        let createdEpoch: Int
    }

    let entries: [Entry]
}

nonisolated struct MigrationImageVerificationManifest: Codable, Sendable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let operationID: UUID
    let sourceImageID: String
    let loadedTargetImageID: String
    let targetImageWasPreexisting: Bool
    let loadResponseSha256: String
    let sourceBeforeTransfer: MigrationImageArchiveFingerprint
    let sourceDuringTransfer: MigrationImageArchiveFingerprint
    let sourceAfterTransfer: MigrationImageArchiveFingerprint
    let verifiedTarget: MigrationImageArchiveFingerprint

    init(
        operationID: UUID,
        sourceImageID: String,
        loadedTargetImageID: String,
        targetImageWasPreexisting: Bool,
        loadResponseSha256: String,
        sourceBeforeTransfer: MigrationImageArchiveFingerprint,
        sourceDuringTransfer: MigrationImageArchiveFingerprint,
        sourceAfterTransfer: MigrationImageArchiveFingerprint,
        verifiedTarget: MigrationImageArchiveFingerprint
    ) {
        schemaVersion = Self.schemaVersion
        self.operationID = operationID
        self.sourceImageID = sourceImageID
        self.loadedTargetImageID = loadedTargetImageID
        self.targetImageWasPreexisting = targetImageWasPreexisting
        self.loadResponseSha256 = loadResponseSha256
        self.sourceBeforeTransfer = sourceBeforeTransfer
        self.sourceDuringTransfer = sourceDuringTransfer
        self.sourceAfterTransfer = sourceAfterTransfer
        self.verifiedTarget = verifiedTarget
    }
}

private nonisolated struct MigrationLoadedImageArchive {
    let response: Data
    let receipt: MigrationImageLoadReceipt
    let sourceFingerprint: MigrationImageArchiveFingerprint
}

private nonisolated struct MigrationVerifiedImageTransfer {
    let sourceReference: String
    let sourceBefore: MigrationImageArchiveFingerprint
    let sourceDuring: MigrationImageArchiveFingerprint
    let sourceAfter: MigrationImageArchiveFingerprint
    let verifiedTarget: MigrationImageArchiveFingerprint
    let loaded: MigrationLoadedImageArchive
}

nonisolated struct MigrationImageTransferExecution {
    let request: MigrationImageTransferRequest
    let source: any ContainerRuntime
    let target: any ContainerRuntime
    var targetBefore: MigrationImageTargetInventory?
    var cleanupImageID: String?
    var loadAttempted = false
    var cleanupRequired = false

    mutating func execute() async throws -> MigrationImageTransferReceipt {
        let sourceReference = try sourceReference()
        let sourceBefore = try await fingerprint(source, reference: sourceReference)
        let expectedImageID = sourceBefore.semanticIdentity
        guard expectedImageID == sourceReference else {
            throw MigrationImageTransferError.sourceDrift
        }
        try await prepareTarget(expectedImageID: expectedImageID)
        let loaded = try await loadSource(reference: sourceReference)
        let loadReceipt = loaded.receipt
        guard loadReceipt.loadedImageID == expectedImageID else {
            throw MigrationImageTransferError.loadIdentityMismatch(
                expected: expectedImageID,
                actual: loadReceipt.loadedImageID
            )
        }
        let sourceDuring = loaded.sourceFingerprint
        guard sameSourceContent(sourceBefore, sourceDuring) else {
            throw MigrationImageTransferError.sourceDrift
        }
        let sourceAfter = try await fingerprint(source, reference: sourceReference)
        guard sameSourceContent(sourceBefore, sourceAfter) else {
            throw MigrationImageTransferError.sourceDrift
        }
        let verifiedTarget = try await fingerprint(target, reference: loadReceipt.loadedImageID)
        guard verifiedTarget.semanticIdentity == sourceBefore.semanticIdentity else {
            throw MigrationImageTransferError.targetMismatch
        }
        return try makeReceipt(MigrationVerifiedImageTransfer(
            sourceReference: sourceReference,
            sourceBefore: sourceBefore,
            sourceDuring: sourceDuring,
            sourceAfter: sourceAfter,
            verifiedTarget: verifiedTarget,
            loaded: loaded
        ))
    }

    private mutating func makeReceipt(
        _ evidence: MigrationVerifiedImageTransfer
    ) throws -> MigrationImageTransferReceipt {
        let responseDigest = Self.sha256(evidence.loaded.response)
        let manifest = MigrationImageVerificationManifest(
            operationID: request.operationID,
            sourceImageID: evidence.sourceReference,
            loadedTargetImageID: evidence.loaded.receipt.loadedImageID,
            targetImageWasPreexisting: !cleanupRequired,
            loadResponseSha256: responseDigest,
            sourceBeforeTransfer: evidence.sourceBefore,
            sourceDuringTransfer: evidence.sourceDuring,
            sourceAfterTransfer: evidence.sourceAfter,
            verifiedTarget: evidence.verifiedTarget
        )
        let manifestData = try Self.encode(manifest)
        return MigrationImageTransferReceipt(
            sourceBeforeTransfer: evidence.sourceBefore,
            sourceDuringTransfer: evidence.sourceDuring,
            sourceAfterTransfer: evidence.sourceAfter,
            verifiedTarget: evidence.verifiedTarget,
            loadedTargetImageID: evidence.loaded.receipt.loadedImageID,
            targetImageWasPreexisting: !cleanupRequired,
            loadResponseSha256: responseDigest,
            verificationManifest: manifestData,
            verificationManifestSha256: Self.sha256(manifestData)
        )
    }
}

extension MigrationImageTransferExecution {
    nonisolated static func canonicalImageID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = trimmed.hasPrefix("sha256:")
            ? String(trimmed.dropFirst("sha256:".count))
            : trimmed
        guard digest.utf8.count == 64,
              digest.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }) else { return nil }
        return "sha256:\(digest)"
    }

    mutating func cleanup() async -> [String] {
        guard loadAttempted, cleanupRequired, let cleanupImageID else { return [] }
        var failures: [String] = []
        do {
            try await target.removeImage(id: cleanupImageID)
        } catch {
            failures.append("remove staged target image \(cleanupImageID): \(error)")
        }
        guard let targetBefore else {
            failures.append("target inventory baseline disappeared")
            return failures
        }
        do {
            let after = try await targetInventory()
            if after != targetBefore {
                failures.append("target image inventory was not restored")
            }
        } catch {
            failures.append("verify restored target image inventory: \(error)")
        }
        return failures
    }
}

private extension MigrationImageTransferExecution {
    nonisolated func sourceReference() throws -> String {
        guard let reference = Self.canonicalImageID(request.sourceImageID) else {
            throw MigrationImageTransferError.invalidRequest("source image ID is invalid")
        }
        return reference
    }

    mutating func prepareTarget(
        expectedImageID: String
    ) async throws {
        let initialTarget = try await targetInventory()
        targetBefore = initialTarget
        cleanupImageID = expectedImageID
        cleanupRequired = !initialTarget.contains(expectedImageID)
    }

    mutating func loadSource(
        reference: String
    ) async throws -> MigrationLoadedImageArchive {
        let observed = MigrationObservedImageStream(
            source.saveImageThrowing(reference: reference)
        )
        let transferStream = AsyncThrowingStream<Data, Error>(unfolding: {
            try await observed.next()
        })
        loadAttempted = true
        let response = try await target.loadImageThrowingWithResponse(stream: transferStream)
        let receipt = try MigrationImageLoadReceipt.parse(response)
        return MigrationLoadedImageArchive(
            response: response,
            receipt: receipt,
            sourceFingerprint: try await observed.finish()
        )
    }

    func fingerprint(
        _ runtime: any ContainerRuntime,
        reference: String
    ) async throws -> MigrationImageArchiveFingerprint {
        try await MigrationImageArchiveReader.fingerprint(
            runtime.saveImageThrowing(reference: reference)
        )
    }

    nonisolated func sameSourceContent(
        _ first: MigrationImageArchiveFingerprint,
        _ second: MigrationImageArchiveFingerprint
    ) -> Bool {
        first.semanticIdentity == second.semanticIdentity
            && first.archiveContractSha256 == second.archiveContractSha256
    }

    func targetInventory() async throws -> MigrationImageTargetInventory {
        let snapshot = try await target.migrationSnapshot()
        var seen = Set<String>()
        let entries = try snapshot.images.map { image -> MigrationImageTargetInventory.Entry in
            guard let id = Self.canonicalImageID(image.imageID), seen.insert(id).inserted else {
                throw MigrationImageTransferError.targetInventory(
                    "image IDs must be unique complete lowercase sha256 digests"
                )
            }
            return MigrationImageTargetInventory.Entry(
                id: id,
                references: MigrationOperationPlanBuilder.imageReferences(image).sorted(),
                labels: image.labels,
                sizeBytes: image.sizeBytes,
                createdEpoch: image.createdEpoch
            )
        }.sorted { $0.id < $1.id }
        return MigrationImageTargetInventory(entries: entries)
    }

    nonisolated static func encode(_ manifest: MigrationImageVerificationManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(manifest)
        } catch {
            throw MigrationImageTransferError.targetInventory(
                "verification manifest could not be encoded"
            )
        }
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension MigrationImageTargetInventory {
    nonisolated func contains(_ imageID: String) -> Bool {
        entries.contains { $0.id == imageID }
    }
}

private actor MigrationObservedImageStream {
    private let iterator: MigrationImageStreamIterator
    private var reader = MigrationImageArchiveReader()
    private var reachedEnd = false
    private var readInProgress = false
    private var completedFingerprint: MigrationImageArchiveFingerprint?

    init(_ stream: AsyncThrowingStream<Data, Error>) {
        iterator = MigrationImageStreamIterator(stream)
    }

    func next() async throws -> Data? {
        guard !reachedEnd else { return nil }
        guard !readInProgress else {
            throw MigrationImageTransferError.unsupported(
                "target attempted concurrent source archive reads"
            )
        }
        readInProgress = true
        defer { readInProgress = false }
        guard let chunk = try await iterator.next() else {
            reachedEnd = true
            return nil
        }
        try reader.feed(chunk)
        return chunk
    }

    func finish() throws -> MigrationImageArchiveFingerprint {
        guard reachedEnd else { throw MigrationImageTransferError.sourceStreamIncomplete }
        if let completedFingerprint { return completedFingerprint }
        let fingerprint = try reader.finish()
        completedFingerprint = fingerprint
        return fingerprint
    }
}

private nonisolated final class MigrationImageStreamIterator: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<Data, Error>.Iterator

    init(_ stream: AsyncThrowingStream<Data, Error>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> Data? {
        try await iterator.next()
    }
}
