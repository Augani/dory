import DoryOperations
import Foundation

/// Stops guest execution at the boundary of an instruction slice or hardware exit, while the
/// helper's control, networking and presentation threads remain available. A pause receipt is
/// issued only after every execution region has retired.
public final class GuestExecutionPauseCoordinator: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case transitionInProgress
        case stopped
        case timedOut
        case participantAlreadyExecuting
    }

    private let condition = NSCondition()
    private var executing: Set<Int> = []
    private var pauseRequested = false
    private var stopped = false
    private var completion: DispatchSemaphore?

    public init() {}

    public var state: DoryVirtualMachineState {
        condition.withLock {
            if stopped { return executing.isEmpty ? .stopped : .stopping }
            if pauseRequested, executing.isEmpty { return .paused }
            return .running
        }
    }

    public var isPauseRequested: Bool { condition.withLock { pauseRequested } }

    /// Called on the execution owner, before touching guest architectural state or memory.
    public func enter(participant: Int) throws -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while pauseRequested, !stopped { condition.wait() }
        guard !stopped else { return false }
        guard executing.insert(participant).inserted else {
            throw Failure.participantAlreadyExecuting
        }
        return true
    }

    public func leave(participant: Int) {
        condition.withLock {
            executing.remove(participant)
            if executing.isEmpty { completion?.signal() }
        }
    }

    public func pause(
        timeout: TimeInterval = 2,
        interrupt: () -> Void = {}
    ) throws {
        guard timeout.isFinite, timeout > 0 else { throw Failure.timedOut }
        let waiter: DispatchSemaphore? = try condition.withLock {
            guard !stopped else { throw Failure.stopped }
            guard completion == nil else { throw Failure.transitionInProgress }
            pauseRequested = true
            guard !executing.isEmpty else { return nil }
            let waiter = DispatchSemaphore(value: 0)
            completion = waiter
            return waiter
        }
        guard let waiter else { return }
        interrupt()
        _ = waiter.wait(timeout: .now() + timeout)
        try condition.withLock {
            completion = nil
            guard !stopped else { throw Failure.stopped }
            guard executing.isEmpty else {
                pauseRequested = false
                condition.broadcast()
                throw Failure.timedOut
            }
        }
    }

    public func resume() throws {
        try condition.withLock {
            guard !stopped else { throw Failure.stopped }
            guard completion == nil else { throw Failure.transitionInProgress }
            pauseRequested = false
            condition.broadcast()
        }
    }

    /// Wakes parked execution owners so they can perform teardown on their own threads.
    public func stop() {
        condition.withLock {
            stopped = true
            completion?.signal()
            condition.broadcast()
        }
    }
}
