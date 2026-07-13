import CryptoKit
import DoryOperations
import Foundation

enum MigrationImportAssetStagingError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidSession(String)
    case invalidSpecification(DoryOperationObjectKey)
    case targetDrift(DoryOperationObjectKey)
    case operationAndRollback(operation: String, rollback: [String])
    case operationAndJournal(operation: String, journal: String)

    var description: String {
        switch self {
        case let .invalidSession(detail):
            return "migration asset staging session is invalid: \(detail)"
        case let .invalidSpecification(key):
            return "migration asset specification is invalid for \(key)"
        case let .targetDrift(key):
            return "migration target changed before staging \(key)"
        case let .operationAndRollback(operation, rollback):
            return "asset staging failed (\(operation)); rollback also failed: "
                + rollback.joined(separator: "; ")
        case let .operationAndJournal(operation, journal):
            return "asset staging failed (\(operation)); recording recovery state also failed: \(journal)"
        }
    }
}

protocol MigrationImportAssetTransfers: Sendable {
    func transferImage(
        _ request: MigrationImageTransferRequest,
        from source: any ContainerRuntime,
        to target: any ContainerRuntime
    ) async throws -> MigrationImageTransferReceipt

    func transferVolume(
        _ request: MigrationVolumeTransferRequest,
        from source: any ContainerRuntime,
        to target: any ContainerRuntime
    ) async throws -> MigrationVolumeTransferReceipt
}

struct MigrationImportLiveAssetTransfers: MigrationImportAssetTransfers {
    let helperAsset: MigrationTransferHelperAsset

    func transferImage(
        _ request: MigrationImageTransferRequest,
        from source: any ContainerRuntime,
        to target: any ContainerRuntime
    ) async throws -> MigrationImageTransferReceipt {
        try await MigrationImageTransfer().transfer(request, from: source, to: target)
    }

    func transferVolume(
        _ request: MigrationVolumeTransferRequest,
        from source: any ContainerRuntime,
        to target: any ContainerRuntime
    ) async throws -> MigrationVolumeTransferReceipt {
        try await MigrationVolumeTransfer(helperAsset: helperAsset).transfer(
            request,
            from: source,
            to: target
        )
    }
}

struct MigrationImportAssetStagingEnvironment: Sendable {
    let source: any ContainerRuntime
    let target: any ContainerRuntime
    let transfers: any MigrationImportAssetTransfers
}

struct MigrationVolumeVerificationManifest: Codable, Sendable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let operationID: UUID
    let sourceVolume: String
    let targetVolume: String
    let specificationDigest: String
    let sourceManifestDigest: String
    let targetManifestDigest: String
    let targetFingerprint: String
    let sourceEntryCount: Int
    let targetEntryCount: Int
    let excludedSocketCount: Int
    let containsDeviceNodes: Bool

    init(
        operationID: UUID,
        object: DoryOperationPlannedObject,
        receipt: MigrationVolumeTransferReceipt,
        targetFingerprint: String
    ) {
        schemaVersion = Self.schemaVersion
        self.operationID = operationID
        sourceVolume = object.source.sourceID
        targetVolume = object.normalizedTargetName
        specificationDigest = object.specificationDigest
        sourceManifestDigest = receipt.sourceManifestSha256
        targetManifestDigest = receipt.targetManifestSha256
        self.targetFingerprint = targetFingerprint
        sourceEntryCount = receipt.sourceEntryCount
        targetEntryCount = receipt.verifiedTargetEntryCount
        excludedSocketCount = receipt.excludedSocketCount
        containsDeviceNodes = receipt.containsDeviceNodes
    }
}

enum MigrationImportAssetCanonical {
    static func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func targetFingerprint(
        specificationDigest: String,
        targetManifestDigest: String
    ) throws -> String {
        try digest(data([
            "specificationDigest": specificationDigest,
            "targetManifestDigest": targetManifestDigest
        ]))
    }
}
