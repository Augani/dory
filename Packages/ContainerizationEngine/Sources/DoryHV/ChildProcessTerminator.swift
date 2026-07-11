import Darwin
import Foundation

package enum ChildProcessTerminationOutcome: Equatable, Sendable {
    case alreadyExited
    case terminated
    case killed
}

/// Terminates a Foundation `Process` without leaving a live child or zombie behind. The graceful
/// wait is bounded; a child that ignores SIGTERM is killed, then `waitUntilExit` reaps it before the
/// caller continues.
package enum ChildProcessTerminator {
    @discardableResult
    package static func terminateAndReap(
        _ process: Process,
        gracePeriod: TimeInterval = 2,
        pollInterval: TimeInterval = 0.01
    ) -> ChildProcessTerminationOutcome {
        let pid = process.processIdentifier
        guard pid > 0 else { return .alreadyExited }

        guard process.isRunning else {
            process.waitUntilExit()
            return .alreadyExited
        }

        process.terminate()
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, gracePeriod)
        let sleepInterval = max(0.001, pollInterval)
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: min(sleepInterval, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
        }

        var killed = false
        if process.isRunning {
            killed = Darwin.kill(pid, SIGKILL) == 0
        }
        process.waitUntilExit()
        return killed ? .killed : .terminated
    }
}
