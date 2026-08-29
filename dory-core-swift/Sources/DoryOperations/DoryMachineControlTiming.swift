import Foundation

/// Client-side XPC budgets for machine operations whose daemon work is deliberately synchronous.
///
/// These values are longer than the corresponding daemon bounds. A client timeout invalidates its
/// XPC connection but does not cancel the daemon mutation, so an undersized budget can report a
/// failure after create, stop, restart, or delete has actually committed.
public enum DoryMachineControlTiming {
    /// A first desktop boot may consume the daemon's full 180-second readiness window.
    public static let startSeconds: TimeInterval = 240

    /// Stop serializes a guest handshake/receipt, helper acknowledgement, and the 30-second host
    /// termination bound. Ninety seconds preserves a scheduling margin around that full path.
    public static let stopSeconds: TimeInterval = 90

    /// Restart performs the complete stop and start paths in sequence.
    public static let restartSeconds: TimeInterval = stopSeconds + startSeconds

    /// Create/delete can copy, quarantine, or remove multi-gigabyte machine storage.
    public static let fileMutationSeconds: TimeInterval = 15 * 60
}
