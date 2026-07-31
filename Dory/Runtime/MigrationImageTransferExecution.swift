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
    static let schemaVersion = 2

    let schemaVersion: Int
    let operationID: UUID
    let sourceImageID: String
    let loadedTargetImageID: String
    let targetInventoryEntryAfterLoad: MigrationImageTargetInventory.Entry
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
        targetInventoryEntryAfterLoad: MigrationImageTargetInventory.Entry,
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
        self.targetInventoryEntryAfterLoad = targetInventoryEntryAfterLoad
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
    let targetInventoryEntryAfterLoad: MigrationImageTargetInventory.Entry
}

nonisolated struct MigrationImageTransferExecution {
    let request: MigrationImageTransferRequest
    let source: any ContainerRuntime
    let target: any ContainerRuntime
    var targetBefore: MigrationImageTargetInventory?
    var loadedTargetEntry: MigrationImageTargetInventory.Entry?
    var loadAttempted = false
    var cleanupRequired = false

    mutating func execute() async throws -> MigrationImageTransferReceipt {
        let sourceReference = try sourceReference()
        let sourceBefore = try await fingerprint(source, reference: sourceReference)
        guard sourceBefore.supportsImageID(sourceReference) else {
            throw MigrationImageTransferError.sourceDrift
        }
        try await prepareTarget()
        let loaded = try await loadSource(reference: sourceReference)
        let loadReceipt = loaded.receipt
        try await recordLoadedTarget(
            expectedSemanticIdentity: sourceReference,
            actualID: loadReceipt.loadedImageID
        )
        let sourceDuring = loaded.sourceFingerprint
        guard sourceDuring.supportsImageID(sourceReference),
              Self.sameImageContent(sourceBefore, sourceDuring) else {
            throw MigrationImageTransferError.sourceDrift
        }
        let sourceAfter = try await fingerprint(source, reference: sourceReference)
        guard sourceAfter.supportsImageID(sourceReference),
              Self.sameImageContent(sourceBefore, sourceAfter) else {
            throw MigrationImageTransferError.sourceDrift
        }
        let verifiedTarget = try await fingerprint(target, reference: loadReceipt.loadedImageID)
        guard verifiedTarget.supportsImageID(loadReceipt.loadedImageID),
              Self.sameImageContent(sourceBefore, verifiedTarget) else {
            throw MigrationImageTransferError.targetMismatch
        }
        guard let loadedTargetEntry else {
            throw MigrationImageTransferError.targetInventory(
                "loaded image inventory entry disappeared"
            )
        }
        return try makeReceipt(MigrationVerifiedImageTransfer(
            sourceReference: sourceReference,
            sourceBefore: sourceBefore,
            sourceDuring: sourceDuring,
            sourceAfter: sourceAfter,
            verifiedTarget: verifiedTarget,
            loaded: loaded,
            targetInventoryEntryAfterLoad: loadedTargetEntry
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
            targetInventoryEntryAfterLoad: evidence.targetInventoryEntryAfterLoad,
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
            targetInventoryEntryAfterLoad: evidence.targetInventoryEntryAfterLoad,
            targetImageWasPreexisting: !cleanupRequired,
            loadResponseSha256: responseDigest,
            verificationManifest: manifestData,
            verificationManifestSha256: Self.sha256(manifestData)
        )
    }
}

extension MigrationImageTransferExecution {
    nonisolated static func verifiesImageEvidence(
        sourceImageID: String,
        loadedTargetImageID: String,
        sourceBefore: MigrationImageArchiveFingerprint,
        sourceDuring: MigrationImageArchiveFingerprint,
        sourceAfter: MigrationImageArchiveFingerprint,
        verifiedTarget: MigrationImageArchiveFingerprint
    ) -> Bool {
        guard let sourceID = canonicalImageID(sourceImageID),
              let targetID = canonicalImageID(loadedTargetImageID),
              [sourceBefore, sourceDuring, sourceAfter, verifiedTarget].allSatisfy({
                  $0.schemaVersion == MigrationImageArchiveFingerprint.schemaVersion
              }),
              sourceBefore.supportsImageID(sourceID),
              sourceDuring.supportsImageID(sourceID),
              sourceAfter.supportsImageID(sourceID),
              verifiedTarget.supportsImageID(targetID) else { return false }
        return sameImageContent(sourceBefore, sourceDuring)
            && sameImageContent(sourceBefore, sourceAfter)
            && sameImageContent(sourceBefore, verifiedTarget)
    }

    nonisolated static func sameImageContent(
        _ first: MigrationImageArchiveFingerprint,
        _ second: MigrationImageArchiveFingerprint
    ) -> Bool {
        first.semanticIdentity == second.semanticIdentity
            && first.archiveContractSha256 == second.archiveContractSha256
    }

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

    nonisolated static func targetInventory(
        images: [DockerImage]
    ) throws -> MigrationImageTargetInventory {
        var seen = Set<String>()
        let entries = try images.map { image -> MigrationImageTargetInventory.Entry in
            guard let id = canonicalImageID(image.imageID), seen.insert(id).inserted else {
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

    mutating func cleanup() async -> [String] {
        guard loadAttempted else { return [] }
        var failures: [String] = []
        guard let targetBefore else {
            failures.append("target inventory baseline disappeared")
            return failures
        }
        let candidate: MigrationImageTargetInventory.Entry
        do {
            let current = try await targetInventory()
            if let loadedTargetEntry {
                guard !targetBefore.contains(loadedTargetEntry.id) else { return [] }
                guard current.entries.first(where: { $0.id == loadedTargetEntry.id })
                        == loadedTargetEntry else {
                    failures.append(
                        "staged target image ownership changed after load: \(loadedTargetEntry.id)"
                    )
                    return failures
                }
                candidate = loadedTargetEntry
            } else {
                // A malformed/truncated load response can hide the receipt. Only the expected,
                // newly-created, untagged content ID is attributable to this transfer. Every other
                // concurrent addition belongs to another client and must remain untouched.
                guard let expectedID = Self.canonicalImageID(request.sourceImageID),
                      !targetBefore.contains(expectedID),
                      let inferred = current.entries.first(where: { $0.id == expectedID }) else {
                    return []
                }
                guard inferred.references.isEmpty else {
                    failures.append(
                        "staged target image gained an external reference: \(expectedID)"
                    )
                    return failures
                }
                candidate = inferred
            }
            guard candidate.references.isEmpty else {
                failures.append(
                    "staged target image is no longer unreferenced: \(candidate.id)"
                )
                return failures
            }
            try await target.removeImageForRollback(id: candidate.id)
            let after = try await targetInventory()
            if after.contains(candidate.id) {
                failures.append("staged target image survived rollback: \(candidate.id)")
            }
        } catch {
            let imageID = loadedTargetEntry?.id ?? request.sourceImageID
            failures.append("remove staged target image \(imageID): \(error)")
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

    mutating func prepareTarget() async throws {
        let initialTarget = try await targetInventory()
        targetBefore = initialTarget
    }

    mutating func recordLoadedTarget(
        expectedSemanticIdentity: String,
        actualID: String
    ) async throws {
        guard let targetBefore else {
            throw MigrationImageTransferError.targetInventory("image baseline disappeared")
        }
        let current = try await targetInventory()
        guard let entry = current.entries.first(where: { $0.id == actualID }) else {
            throw MigrationImageTransferError.loadIdentityMismatch(
                expected: expectedSemanticIdentity,
                actual: actualID
            )
        }
        loadedTargetEntry = entry
        cleanupRequired = !targetBefore.contains(actualID)
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

    func targetInventory() async throws -> MigrationImageTargetInventory {
        let snapshot = try await target.migrationSnapshot()
        return try Self.targetInventory(images: snapshot.images)
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
    private var tagStripper = MigrationImageArchiveTagStripper()
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
        while let chunk = try await iterator.next() {
            try reader.feed(chunk)
            let sanitized = try tagStripper.feed(chunk)
            if !sanitized.isEmpty { return sanitized }
        }
        try tagStripper.finish()
        reachedEnd = true
        return nil
    }

    func finish() throws -> MigrationImageArchiveFingerprint {
        guard reachedEnd else { throw MigrationImageTransferError.sourceStreamIncomplete }
        if let completedFingerprint { return completedFingerprint }
        let fingerprint = try reader.finish()
        completedFingerprint = fingerprint
        return fingerprint
    }
}

/// Rewrites mutable image aliases while preserving every tar header, byte count, and padding byte.
/// Other payloads are forwarded as soon as they arrive; at most one qualified 8 MiB metadata entry
/// is buffered. The independent archive reader fingerprints and validates the exact source bytes,
/// while the target receives equivalent content with no mutable RepoTags or OCI tag annotations.
private nonisolated struct MigrationImageArchiveTagStripper {
    private enum EntryRole {
        case regular
        case directory
        case pax
        case longName
    }

    private enum MetadataRewrite {
        case manifest
        case ociIndex
    }

    private struct ActiveEntry {
        let role: EntryRole
        let path: String
        let logicalBytes: UInt64
        var remainingBytes: UInt64
        var capture: Data?
        let rewrite: MetadataRewrite?
    }

    private var buffer = Data()
    private var cursor = 0
    private var active: ActiveEntry?
    private var paddingBytes: UInt64 = 0
    private var pending = MigrationImageTarPendingMetadata()
    private var zeroBlocks = 0
    private var terminated = false

    mutating func feed(_ data: Data) throws -> Data {
        if !data.isEmpty { buffer.append(data) }
        var output = Data()
        while true {
            if terminated {
                let trailing = buffer[cursor...]
                guard trailing.allSatisfy({ $0 == 0 }) else {
                    throw MigrationImageArchiveError.invalid("archive has data after its terminator")
                }
                output.append(contentsOf: trailing)
                cursor = buffer.count
                break
            }
            if active != nil {
                guard try consumeActive(into: &output) else { break }
                continue
            }
            if paddingBytes > 0 {
                guard try consumePadding(into: &output) else { break }
                continue
            }
            guard try consumeHeader(into: &output) else { break }
        }
        compactBuffer()
        return output
    }

    mutating func finish() throws {
        let output = try feed(Data())
        guard output.isEmpty,
              terminated,
              active == nil,
              paddingBytes == 0,
              pending.isEmpty,
              cursor == buffer.count else {
            throw MigrationImageArchiveError.invalid("archive is truncated while removing RepoTags")
        }
    }

    private mutating func consumeHeader(into output: inout Data) throws -> Bool {
        let blockBytes = MigrationImageTarHeaderDecoder.blockBytes
        guard buffer.count - cursor >= blockBytes else { return false }
        let end = cursor + blockBytes
        let bytes = buffer[cursor..<end]
        if bytes.allSatisfy({ $0 == 0 }) {
            output.append(contentsOf: bytes)
            cursor = end
            zeroBlocks += 1
            if zeroBlocks == 2 { terminated = true }
            return true
        }
        guard zeroBlocks == 0 else {
            throw MigrationImageArchiveError.invalid("tar terminator is incomplete")
        }
        let header = try MigrationImageTarHeaderDecoder.decode(bytes)
        let role = try role(for: header.type)
        let path: String
        let logicalBytes: UInt64
        if role == .pax || role == .longName {
            path = header.path
            logicalBytes = header.size
        } else {
            path = pending.path ?? header.path
            logicalBytes = pending.size ?? header.size
            pending.reset()
        }
        let rewrite: MetadataRewrite?
        if role == .regular, path == "manifest.json" {
            rewrite = .manifest
        } else if role == .regular, path == "index.json" {
            rewrite = .ociIndex
        } else {
            rewrite = nil
        }
        output.append(contentsOf: bytes)
        cursor = end
        active = ActiveEntry(
            role: role,
            path: path,
            logicalBytes: logicalBytes,
            remainingBytes: logicalBytes,
            capture: rewrite != nil || role == .pax || role == .longName ? Data() : nil,
            rewrite: rewrite
        )
        if logicalBytes == 0 { try finalizeActive(into: &output) }
        return true
    }

    private func role(for type: UInt8) throws -> EntryRole {
        switch type {
        case 0, UInt8(ascii: "0"): return .regular
        case UInt8(ascii: "5"): return .directory
        case UInt8(ascii: "x"): return .pax
        case UInt8(ascii: "L"): return .longName
        case UInt8(ascii: "g"):
            throw MigrationImageArchiveError.invalid("global PAX metadata is not accepted")
        default:
            throw MigrationImageArchiveError.invalid("unsupported outer tar entry type \(type)")
        }
    }

    private mutating func consumeActive(into output: inout Data) throws -> Bool {
        guard var entry = active else { return true }
        if entry.remainingBytes == 0 {
            try finalizeActive(into: &output)
            return true
        }
        let available = buffer.count - cursor
        guard available > 0 else { return false }
        let count = entry.remainingBytes > UInt64(available)
            ? available
            : Int(entry.remainingBytes)
        let end = cursor + count
        let bytes = buffer[cursor..<end]
        entry.capture?.append(contentsOf: bytes)
        if entry.rewrite == nil { output.append(contentsOf: bytes) }
        entry.remainingBytes -= UInt64(count)
        cursor = end
        active = entry
        if entry.remainingBytes == 0 { try finalizeActive(into: &output) }
        return true
    }

    private mutating func finalizeActive(into output: inout Data) throws {
        guard let entry = active else { return }
        if let rewrite = entry.rewrite {
            guard let metadata = entry.capture,
                  UInt64(metadata.count) == entry.logicalBytes else {
                throw MigrationImageArchiveError.invalid(
                    "image archive metadata disappeared while removing aliases"
                )
            }
            switch rewrite {
            case .manifest:
                output.append(try MigrationImageArchiveManifest.strippingRepoTags(metadata))
            case .ociIndex:
                output.append(try MigrationImageOCIArchiveIdentity.strippingAliases(metadata))
            }
        } else if entry.role == .pax {
            guard let payload = entry.capture else {
                throw MigrationImageArchiveError.invalid("PAX metadata disappeared")
            }
            pending = try MigrationImageTarHeaderDecoder.parsePAX(payload)
        } else if entry.role == .longName {
            guard let payload = entry.capture else {
                throw MigrationImageArchiveError.invalid("GNU long name disappeared")
            }
            pending.path = try MigrationImageTarHeaderDecoder.parseLongName(payload)
        }
        let remainder = entry.logicalBytes % UInt64(MigrationImageTarHeaderDecoder.blockBytes)
        paddingBytes = remainder == 0
            ? 0
            : UInt64(MigrationImageTarHeaderDecoder.blockBytes) - remainder
        active = nil
    }

    private mutating func consumePadding(into output: inout Data) throws -> Bool {
        let available = buffer.count - cursor
        guard available > 0 else { return false }
        let count = paddingBytes > UInt64(available) ? available : Int(paddingBytes)
        let end = cursor + count
        let bytes = buffer[cursor..<end]
        guard bytes.allSatisfy({ $0 == 0 }) else {
            throw MigrationImageArchiveError.invalid("tar entry padding is not zero-filled")
        }
        output.append(contentsOf: bytes)
        cursor = end
        paddingBytes -= UInt64(count)
        return true
    }

    private mutating func compactBuffer() {
        guard cursor > 0 else { return }
        buffer.removeSubrange(buffer.startIndex..<cursor)
        cursor = 0
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
