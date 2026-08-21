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

public enum DoryMachineFileTransferPhase: String, Sendable, Equatable, Hashable {
    case preparing
    case transferring
    case finalizing
    case cancelling
    case completed
    case cancelled
    case failed

    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed:
            true
        case .preparing, .transferring, .finalizing, .cancelling:
            false
        }
    }
}

public enum DoryMachineFileTransferFailureCode: String, Sendable, Equatable, Hashable {
    case guestUnavailable = "guest-unavailable"
    case guestPreparationFailed = "guest-preparation-failed"
    case transferFailed = "transfer-failed"
    case guestFinalizationFailed = "guest-finalization-failed"
}

public struct DoryMachineFileTransferFailure: Sendable, Equatable, Hashable {
    public var code: DoryMachineFileTransferFailureCode
    public var message: String

    public init(code: DoryMachineFileTransferFailureCode, message: String) {
        self.code = code
        self.message = message
    }
}

/// A path-safe snapshot of one daemon-owned transfer operation. Host staging paths are never
/// included. Counters are absolute and may be polled at any cadence.
public struct DoryMachineFileTransferOperationStatus: Sendable, Equatable {
    public var operationID: String
    public var machineID: String
    public var phase: DoryMachineFileTransferPhase
    public var filesTotal: UInt64
    public var filesCompleted: UInt64
    public var bytesTotal: UInt64
    public var bytesCompleted: UInt64
    public var currentPath: String?
    public var guestDestination: String?
    public var result: DoryMachineFileTransferResult?
    public var failure: DoryMachineFileTransferFailure?

    public init(
        operationID: String,
        machineID: String,
        phase: DoryMachineFileTransferPhase,
        filesTotal: UInt64,
        filesCompleted: UInt64,
        bytesTotal: UInt64,
        bytesCompleted: UInt64,
        currentPath: String?,
        guestDestination: String?,
        result: DoryMachineFileTransferResult?,
        failure: DoryMachineFileTransferFailure?
    ) {
        self.operationID = operationID
        self.machineID = machineID
        self.phase = phase
        self.filesTotal = filesTotal
        self.filesCompleted = filesCompleted
        self.bytesTotal = bytesTotal
        self.bytesCompleted = bytesCompleted
        self.currentPath = currentPath
        self.guestDestination = guestDestination
        self.result = result
        self.failure = failure
    }

    public var fractionCompleted: Double {
        if phase == .completed {
            return 1
        }
        if bytesTotal > 0 {
            return min(1, Double(bytesCompleted) / Double(bytesTotal))
        }
        if filesTotal > 0 {
            return min(1, Double(filesCompleted) / Double(filesTotal))
        }
        return 0
    }
}

public enum DoryMachineFileTransferError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidPrivateStagingRoot
    case transferAlreadyInProgress(String)
    case unknownTransfer(String, String)
    case guestAccountUnavailable(String)
    case guestPreparationFailed(String)
    case transferFailed(String)
    case guestFinalizationFailed(String)

    public var description: String {
        switch self {
        case .invalidPrivateStagingRoot:
            "file transfer staging root is invalid or not private"
        case let .transferAlreadyInProgress(machineID):
            "a file transfer is already in progress for machine: \(machineID)"
        case let .unknownTransfer(machineID, operationID):
            "unknown file transfer \(operationID) for machine: \(machineID)"
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

final class MachineFileTransferOperation: @unchecked Sendable {
    let operationID: String
    let machineID: String
    let control = DoryPushControl()

    private let lock = NSLock()
    private var phase: DoryMachineFileTransferPhase = .preparing
    private var cancellationRequested = false
    private var guestDestination: String?
    private var result: DoryMachineFileTransferResult?
    private var failure: DoryMachineFileTransferFailure?
    private var finishedAt: Date?

    init(operationID: String, machineID: String) {
        self.operationID = operationID
        self.machineID = machineID
    }

    var isCancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }

    var isTerminal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return phase.isTerminal
    }

    var terminalDate: Date? {
        lock.lock()
        defer { lock.unlock() }
        return finishedAt
    }

    func requestCancellation() {
        lock.lock()
        if !phase.isTerminal {
            cancellationRequested = true
            phase = .cancelling
        }
        lock.unlock()
        control.cancel()
    }

    func setGuestDestination(_ guestDestination: String) {
        lock.lock()
        if !phase.isTerminal {
            self.guestDestination = guestDestination
        }
        lock.unlock()
    }

    func setTransferring() {
        lock.lock()
        if !phase.isTerminal {
            phase = cancellationRequested ? .cancelling : .transferring
        }
        lock.unlock()
    }

    func setFinalizing() {
        lock.lock()
        if !phase.isTerminal {
            phase = cancellationRequested ? .cancelling : .finalizing
        }
        lock.unlock()
    }

    func complete(_ result: DoryMachineFileTransferResult) {
        lock.lock()
        self.result = result
        guestDestination = result.guestDestination
        phase = .completed
        finishedAt = Date()
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        phase = .cancelled
        finishedAt = Date()
        lock.unlock()
    }

    func fail(_ failure: DoryMachineFileTransferFailure) {
        lock.lock()
        self.failure = failure
        phase = .failed
        finishedAt = Date()
        lock.unlock()
    }

    func status() -> DoryMachineFileTransferOperationStatus {
        let pushProgress = control.progress()
        lock.lock()
        defer { lock.unlock() }
        let filesCompleted = result?.filesSent ?? pushProgress.filesCompleted
        let bytesCompleted = result?.bytesSent ?? pushProgress.bytesCompleted
        return DoryMachineFileTransferOperationStatus(
            operationID: operationID,
            machineID: machineID,
            phase: phase,
            filesTotal: max(pushProgress.filesTotal, result?.filesSent ?? 0),
            filesCompleted: filesCompleted,
            bytesTotal: max(pushProgress.bytesTotal, result?.bytesSent ?? 0),
            bytesCompleted: bytesCompleted,
            currentPath: phase.isTerminal ? nil : pushProgress.currentPath,
            guestDestination: guestDestination,
            result: result,
            failure: failure
        )
    }
}

enum DoryMachineFileTransferCancellation: Error {
    case cancelled
}

enum MachineFileTransferTerminalOutcome {
    case completed(DoryMachineFileTransferResult)
    case cancelled
    case failed(DoryMachineFileTransferFailure)
}
