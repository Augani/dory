import DoryCore
import Foundation

/// Safe evidence returned after doryd has copied one private staging tree into a managed guest.
/// Host source paths are deliberately absent from this public/status-safe result.
public struct DoryMachineFileTransferResult: Sendable, Equatable {
    public var transferID: String
    public var guestDestination: String
    public var filesSent: UInt64
    public var bytesSent: UInt64

    public init(
        transferID: String,
        guestDestination: String,
        filesSent: UInt64,
        bytesSent: UInt64
    ) {
        self.transferID = transferID
        self.guestDestination = guestDestination
        self.filesSent = filesSent
        self.bytesSent = bytesSent
    }
}

public enum DoryMachineFileTransferError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidPrivateStagingRoot
    case guestAccountUnavailable(String)
    case guestPreparationFailed(String)
    case transferFailed(String)
    case guestFinalizationFailed(String)

    public var description: String {
        switch self {
        case .invalidPrivateStagingRoot:
            "file transfer staging root is invalid or not private"
        case let .guestAccountUnavailable(machineID):
            "managed guest account is unavailable for machine: \(machineID)"
        case let .guestPreparationFailed(machineID):
            "could not prepare the guest transfer directory for machine: \(machineID)"
        case let .transferFailed(machineID):
            "file transfer failed for machine: \(machineID)"
        case let .guestFinalizationFailed(machineID):
            "could not finalize guest file ownership for machine: \(machineID)"
        }
    }
}

extension DoryMachineFileTransferResult {
    init(transferID: String, guestDestination: String, stats: DoryPushStats) {
        self.init(
            transferID: transferID,
            guestDestination: guestDestination,
            filesSent: stats.filesSent,
            bytesSent: stats.bytesSent
        )
    }
}
