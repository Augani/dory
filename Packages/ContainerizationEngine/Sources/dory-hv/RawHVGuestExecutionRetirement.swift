import Foundation

/// Transfers a retired guest's execution owner off the main actor until its native join finishes.
///
/// A runner also retains the VM through its operation closure. Keeping even a joined runner in
/// the reset worker or controller therefore prevents destruction of the old Hypervisor VM. This
/// boundary releases that owner before publishing success to any waiter; a failed join retains
/// it instead of making guest memory eligible for teardown under an unjoined execution thread.
final class RawHVGuestExecutionRetirement<Owner: AnyObject & Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private let join: @Sendable (Owner) throws -> Void
    private var owner: Owner?
    private var joining = false
    private var result: Result<Void, any Error>?

    init(owner: Owner, join: @escaping @Sendable (Owner) throws -> Void) {
        self.owner = owner
        self.join = join
    }

    /// Concurrent cleanup/reset observers share one join and its replayable outcome.
    func wait() throws {
        condition.lock()
        while joining { condition.wait() }
        if let result {
            condition.unlock()
            return try result.get()
        }
        joining = true
        condition.unlock()

        // Keep the join's local strong reference in a separate scope. It must be gone before
        // publishing success, including to another waiter that can immediately recreate a VM.
        let completed = Result { try joinAndReleaseOwner() }

        condition.lock()
        result = completed
        joining = false
        condition.broadcast()
        condition.unlock()
        try completed.get()
    }

    private func joinAndReleaseOwner() throws {
        let currentOwner = condition.withLock { owner! }
        try join(currentOwner)
        condition.withLock { owner = nil }
    }
}
