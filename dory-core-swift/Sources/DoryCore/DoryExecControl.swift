import Foundation

public enum DoryExecControlError: Error, Sendable, Equatable {
    /// Only the host wait stopped. A mutating owner must stop and observe the VM before rollback.
    case cancelledGuestStateUnknown
    case alreadyUsed
}

/// Single-use cancellation for one guest exec wait. It never constitutes a guest stop receipt.
public final class DoryExecControl: @unchecked Sendable {
    let raw: ExecControl

    public init() {
        raw = newExecControl()
    }

    public func cancel() {
        raw.cancel()
    }

    public var isCancelled: Bool {
        raw.isCancelled()
    }
}
