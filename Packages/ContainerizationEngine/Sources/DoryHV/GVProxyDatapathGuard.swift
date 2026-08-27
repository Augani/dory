/// Conservative recovery policy for a gvproxy process that is alive but has stopped forwarding.
///
/// The inert canary reaches the guest agent's HTTP witness through a private gvproxy unix forward;
/// the independent witness reaches dockerd's Unix socket through engine.sock -> in-process vsock ->
/// guest agent. A failed canary alone is never enough to restart the VM. It counts only when the
/// Docker witness answers at the same time, isolating the sidecar without treating host network
/// loss, guest startup, or guest overload as a gvproxy fault.
public struct GVProxyDatapathGuard: Sendable {
    public enum Decision: Equatable, Sendable {
        case healthy
        case recovered(previousFailures: Int)
        case inconclusive
        case suspected(consecutiveFailures: Int)
        case restartRequired(consecutiveFailures: Int)
        case restartAlreadyRequested
    }

    public let failureThreshold: Int
    private var consecutiveFailures = 0
    private var restartRequested = false

    public init(failureThreshold: Int = 3) {
        self.failureThreshold = max(2, failureThreshold)
    }

    public mutating func observe(
        gvproxyCanaryReachable: Bool,
        dockerAPIReachable: Bool
    ) -> Decision {
        if restartRequested {
            return .restartAlreadyRequested
        }

        if gvproxyCanaryReachable {
            let previous = consecutiveFailures
            consecutiveFailures = 0
            return previous > 0 ? .recovered(previousFailures: previous) : .healthy
        }

        guard dockerAPIReachable else {
            // Do not carry suspicion across an interval where the independent guest witness is
            // unavailable. A later differential failure must establish a fresh consecutive run.
            consecutiveFailures = 0
            return .inconclusive
        }

        consecutiveFailures += 1
        guard consecutiveFailures >= failureThreshold else {
            return .suspected(consecutiveFailures: consecutiveFailures)
        }
        restartRequested = true
        return .restartRequired(consecutiveFailures: consecutiveFailures)
    }
}
