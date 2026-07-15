import Foundation

nonisolated struct MigrationImageTransferRequest: Sendable, Equatable {
    let operationID: UUID
    let sourceImageID: String
}

nonisolated struct MigrationImageTransferReceipt: Sendable, Equatable {
    let sourceBeforeTransfer: MigrationImageArchiveFingerprint
    let sourceDuringTransfer: MigrationImageArchiveFingerprint
    let sourceAfterTransfer: MigrationImageArchiveFingerprint
    let verifiedTarget: MigrationImageArchiveFingerprint
    let loadedTargetImageID: String
    let targetInventoryEntryAfterLoad: MigrationImageTargetInventory.Entry
    let targetImageWasPreexisting: Bool
    let loadResponseSha256: String
    let verificationManifest: Data
    let verificationManifestSha256: String
}

nonisolated enum MigrationImageTransferError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidRequest(String)
    case unsupported(String)
    case sourceStreamIncomplete
    case sourceDrift
    case loadIdentityMismatch(expected: String, actual: String)
    case targetMismatch
    case targetInventory(String)
    case cleanup([String])
    case operationAndCleanup(operation: String, cleanup: [String])

    var description: String {
        switch self {
        case let .invalidRequest(detail): return "invalid image transfer request: \(detail)"
        case let .unsupported(detail): return "image transfer is unsupported: \(detail)"
        case .sourceStreamIncomplete: return "target stopped reading before the source image archive ended"
        case .sourceDrift: return "source image content changed while it was being transferred"
        case let .loadIdentityMismatch(expected, actual):
            return "target loaded image ID \(actual), expected \(expected)"
        case .targetMismatch: return "target image differs from the verified source image"
        case let .targetInventory(detail): return "target image inventory is invalid: \(detail)"
        case let .cleanup(details): return "image transfer cleanup failed: \(details.joined(separator: "; "))"
        case let .operationAndCleanup(operation, cleanup):
            return "image transfer failed (\(operation)); cleanup also failed: \(cleanup.joined(separator: "; "))"
        }
    }

    var leavesOwnedArtifacts: Bool {
        switch self {
        case .cleanup, .operationAndCleanup: true
        default: false
        }
    }
}

/// Stages one immutable, untagged linux/arm64 image without buffering its archive or publishing
/// mutable references. Publication and durable evidence belong to the journal executor.
nonisolated struct MigrationImageTransfer: Sendable {
    func transfer(
        _ request: MigrationImageTransferRequest,
        from source: any ContainerRuntime,
        to target: any ContainerRuntime
    ) async throws -> MigrationImageTransferReceipt {
        try Self.validate(request, source: source, target: target)
        var execution = MigrationImageTransferExecution(
            request: request,
            source: source,
            target: target
        )
        do {
            return try await execution.execute()
        } catch {
            let cleanup = await execution.cleanup()
            if cleanup.isEmpty { throw error }
            throw MigrationImageTransferError.operationAndCleanup(
                operation: String(describing: error),
                cleanup: cleanup
            )
        }
    }
}

private extension MigrationImageTransfer {
    nonisolated static func validate(
        _ request: MigrationImageTransferRequest,
        source: any ContainerRuntime,
        target: any ContainerRuntime
    ) throws {
        guard MigrationImageTransferExecution.canonicalImageID(request.sourceImageID) != nil else {
            throw MigrationImageTransferError.invalidRequest(
                "source image ID must be a complete lowercase sha256 digest"
            )
        }
        guard source.supportsImageArchiveTransfer, target.supportsImageArchiveTransfer else {
            throw MigrationImageTransferError.unsupported(
                "both engines must support streaming image archives"
            )
        }
        guard target.supportsImageLoadReceipt else {
            throw MigrationImageTransferError.unsupported(
                "target engine does not return immutable image-load receipts"
            )
        }
    }
}
