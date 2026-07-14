import Foundation

struct MigrationImageReadbackRequest: Sendable, Equatable {
    let sourceImageID: String?
    let targetImageID: String
}

struct MigrationImageReadbackReceipt: Sendable, Equatable {
    let source: MigrationImageArchiveFingerprint?
    let target: MigrationImageArchiveFingerprint
}

enum MigrationImageReadback {
    static func verify(
        _ request: MigrationImageReadbackRequest,
        from source: any ContainerRuntime,
        to target: any ContainerRuntime
    ) async throws -> MigrationImageReadbackReceipt {
        let sourceReference = request.sourceImageID.flatMap(
            MigrationImageTransferExecution.canonicalImageID
        )
        guard request.sourceImageID == nil || sourceReference != nil,
              let targetReference = MigrationImageTransferExecution.canonicalImageID(
                request.targetImageID
              ) else {
            throw MigrationImageTransferError.invalidRequest(
                "read-back image IDs must be complete lowercase sha256 digests"
            )
        }
        async let sourceFingerprint = fingerprint(sourceReference, on: source)
        async let targetFingerprint = MigrationImageArchiveReader.fingerprint(
            target.saveImageThrowing(reference: targetReference)
        )
        return try await MigrationImageReadbackReceipt(
            source: sourceFingerprint,
            target: targetFingerprint
        )
    }

    private static func fingerprint(
        _ reference: String?,
        on runtime: any ContainerRuntime
    ) async throws -> MigrationImageArchiveFingerprint? {
        guard let reference else { return nil }
        return try await MigrationImageArchiveReader.fingerprint(
            runtime.saveImageThrowing(reference: reference)
        )
    }
}
