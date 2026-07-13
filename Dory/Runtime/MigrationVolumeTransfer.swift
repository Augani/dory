import Foundation

struct MigrationVolumeTransferRequest: Sendable, Equatable {
    let operationID: UUID
    let sourceAuthorityHash: String
    let sourceVolume: String
    let targetVolume: String
}

struct MigrationVolumeTransferReceipt: Sendable, Equatable {
    let sourceManifest: Data
    let targetManifest: Data
    let sourceManifestSha256: String
    let targetManifestSha256: String
    let sourceEntryCount: Int
    let verifiedTargetEntryCount: Int
    let excludedSocketCount: Int
    let containsDeviceNodes: Bool
}

enum MigrationVolumeTransferError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidRequest(String)
    case helper(String)
    case sourceDrift
    case targetMismatch
    case cleanup([String])
    case operationAndCleanup(operation: String, cleanup: [String])

    var description: String {
        switch self {
        case let .invalidRequest(detail): return "invalid volume transfer request: \(detail)"
        case let .helper(detail): return "volume transfer helper failed: \(detail)"
        case .sourceDrift: return "source volume changed while it was being transferred"
        case .targetMismatch: return "target volume differs from the independently scanned source"
        case let .cleanup(details): return "volume transfer cleanup failed: \(details.joined(separator: "; "))"
        case let .operationAndCleanup(operation, cleanup):
            return "volume transfer failed (\(operation)); cleanup also failed: \(cleanup.joined(separator: "; "))"
        }
    }
}

/// Executes the v1 named-volume contract through public Docker APIs only. The target volume must
/// already be a fresh operation-owned staging object; publication belongs to the journal executor.
struct MigrationVolumeTransfer: Sendable {
    let helperAsset: MigrationTransferHelperAsset

    func transfer(
        _ request: MigrationVolumeTransferRequest,
        from source: any ContainerRuntime,
        to target: any ContainerRuntime
    ) async throws -> MigrationVolumeTransferReceipt {
        try Self.validate(request)
        var execution = MigrationVolumeTransferExecution(
            helperAsset: helperAsset,
            request: request,
            source: source,
            target: target
        )
        var completedReceipt: MigrationVolumeTransferReceipt?
        var operationError: Error?
        do {
            completedReceipt = try await execution.execute()
        } catch {
            operationError = error
        }
        let cleanup = await execution.cleanup()
        if let operationError {
            if cleanup.isEmpty { throw operationError }
            throw MigrationVolumeTransferError.operationAndCleanup(
                operation: String(describing: operationError),
                cleanup: cleanup
            )
        }
        guard cleanup.isEmpty else { throw MigrationVolumeTransferError.cleanup(cleanup) }
        guard let completedReceipt else {
            throw MigrationVolumeTransferError.helper("verification receipt disappeared")
        }
        return completedReceipt
    }
}

private extension MigrationVolumeTransfer {
    static func validate(_ request: MigrationVolumeTransferRequest) throws {
        guard (try? MigrationVolumeManifest.decodeHex(
            request.sourceAuthorityHash,
            maximumBytes: 32
        ).count) == 32, request.sourceAuthorityHash.count == 64 else {
            throw MigrationVolumeTransferError.invalidRequest("source authority hash is invalid")
        }
        guard isDockerVolumeName(request.sourceVolume), isDockerVolumeName(request.targetVolume) else {
            throw MigrationVolumeTransferError.invalidRequest("volume identity is invalid")
        }
    }

    static func isDockerVolumeName(_ value: String) -> Bool {
        guard let first = value.utf8.first, value.utf8.count <= 255,
              isASCIIAlphaNumeric(first) else { return false }
        return value.utf8.dropFirst().allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == UInt8(ascii: "_")
                || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-")
        }
    }

    static func isASCIIAlphaNumeric(_ value: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(value)
            || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(value)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(value)
    }
}
