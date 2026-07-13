import CryptoKit
import DoryOperations
import Foundation

enum MigrationImportAssetStagingError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidSession(String)
    case invalidSpecification(DoryOperationObjectKey)
    case targetDrift(DoryOperationObjectKey)
    case targetRequest(String)
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
        case let .targetRequest(detail):
            return "migration target request failed: \(detail)"
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

struct MigrationNetworkVerificationManifest: Codable, Sendable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let operationID: UUID
    let sourceNetwork: String
    let targetNetwork: String
    let specificationDigest: String
    let inspectedContractDigest: String
    let targetFingerprint: String

    init(
        operationID: UUID,
        object: DoryOperationPlannedObject,
        inspectedContractDigest: String,
        targetFingerprint: String
    ) {
        schemaVersion = Self.schemaVersion
        self.operationID = operationID
        sourceNetwork = object.source.sourceID
        targetNetwork = object.normalizedTargetName
        specificationDigest = object.specificationDigest
        self.inspectedContractDigest = inspectedContractDigest
        self.targetFingerprint = targetFingerprint
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

    static func networkCreateBody(_ specification: MigrationNetworkContract) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(
            with: specification.portableCreateContract
        ) as? [String: Any] else {
            throw MigrationImportAssetStagingError.invalidSpecification(
                .init(kind: .network, sourceID: specification.name)
            )
        }
        object["Name"] = specification.name
        object["CheckDuplicate"] = true
        object["Labels"] = specification.labels
        guard JSONSerialization.isValidJSONObject(object) else {
            throw MigrationImportAssetStagingError.invalidSpecification(
                .init(kind: .network, sourceID: specification.name)
            )
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func jsonContains(expected: Any, actual: Any) -> Bool {
        if expected is NSNull { return actual is NSNull }
        if let expected = expected as? [String: Any] {
            guard let actual = actual as? [String: Any] else { return false }
            return expected.allSatisfy { key, value in
                guard let actualValue = actual[key] else { return false }
                return jsonContains(expected: value, actual: actualValue)
            }
        }
        if let expected = expected as? [Any] {
            guard let actual = actual as? [Any], expected.count == actual.count else { return false }
            return zip(expected, actual).allSatisfy {
                jsonContains(expected: $0.0, actual: $0.1)
            }
        }
        guard let expected = expected as? NSObject,
              let actual = actual as? NSObject else { return false }
        return expected.isEqual(actual)
    }
}
