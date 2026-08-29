import Darwin
import Foundation

/// Lifecycle failures for the dedicated RawHV owner thread.
///
/// A runner is deliberately single-use. Hypervisor.framework vCPUs cannot migrate between host
/// threads, so retrying the same closure on another thread would turn a failed launch into an
/// ambiguous ownership transfer.
public enum RawHVMachineRunnerError: Error, Equatable, Sendable, CustomStringConvertible {
    case alreadyStarted
    case notStarted
    case waitFromOwnerThread
    case threadCreationFailed(Int32)
    case threadJoinFailed(Int32)

    public var description: String {
        switch self {
        case .alreadyStarted:
            return "RawHV machine runner is single-use and has already started"
        case .notStarted:
            return "RawHV machine runner has not started"
        case .waitFromOwnerThread:
            return "RawHV machine owner thread cannot join itself"
        case .threadCreationFailed(let code):
            return "cannot create RawHV machine owner thread: pthread error \(code)"
        case .threadJoinFailed(let code):
            return "cannot join RawHV machine owner thread: pthread error \(code)"
        }
    }
}

private final class RawHVOwnerThreadBootstrap: @unchecked Sendable {
    private let body: @Sendable () -> Void

    init(body: @escaping @Sendable () -> Void) {
        self.body = body
    }

    func run() {
        body()
    }
}

/// A single-use pthread lifecycle with exactly one operation owner and exactly one native join.
///
/// This is internal so focused tests can prove the threading contract without creating a live
/// Hypervisor.framework VM. Production callers use `RawHVMachineRunner` below.
final class RawHVOwnerThread<Output: Sendable>: @unchecked Sendable {
    typealias Completion = @Sendable (Result<Output, any Error>) -> Void

    private enum Phase {
        case ready
        case running
        case finished
        case joining
        case joined
        case startFailed(Int32)
        case joinFailed(Int32)
    }

    private let condition = NSCondition()
    private let name: String
    private let stackSize: Int
    private let operation: @Sendable () throws -> Output

    private var phase = Phase.ready
    private var nativeThread: pthread_t?
    private var ownerThread: pthread_t?
    private var result: Result<Output, any Error>?
    private var completion: Completion?

    init(
        name: String,
        stackSize: Int = RawHVSchedulingPolicy.machineOwnerThreadStackSize,
        operation: @escaping @Sendable () throws -> Output
    ) {
        precondition(!name.isEmpty)
        precondition(stackSize >= PTHREAD_STACK_MIN)
        self.name = String(name.prefix(63))
        self.stackSize = stackSize
        self.operation = operation
    }

    func start(completion: Completion? = nil) throws {
        var attributes = pthread_attr_t()
        let attributeResult = pthread_attr_init(&attributes)
        guard attributeResult == 0 else {
            throw RawHVMachineRunnerError.threadCreationFailed(attributeResult)
        }
        defer { pthread_attr_destroy(&attributes) }

        let stackResult = pthread_attr_setstacksize(&attributes, stackSize)
        guard stackResult == 0 else {
            throw RawHVMachineRunnerError.threadCreationFailed(stackResult)
        }

        condition.lock()
        guard case .ready = phase else {
            condition.unlock()
            throw RawHVMachineRunnerError.alreadyStarted
        }
        self.completion = completion

        // Keep this owner alive independently of its caller until the native entry point returns.
        // Holding `condition` across pthread_create closes the race where a very short operation
        // could publish `.finished` before the creator stores the pthread handle.
        let bootstrap = RawHVOwnerThreadBootstrap { [self] in threadMain() }
        let context = Unmanaged.passRetained(bootstrap).toOpaque()
        var createdThread: pthread_t?
        let createResult = pthread_create(
            &createdThread,
            &attributes,
            { rawContext -> UnsafeMutableRawPointer? in
                let bootstrap = Unmanaged<RawHVOwnerThreadBootstrap>
                    .fromOpaque(rawContext)
                    .takeRetainedValue()
                bootstrap.run()
                return nil
            },
            context
        )
        guard createResult == 0, let createdThread else {
            Unmanaged<RawHVOwnerThreadBootstrap>.fromOpaque(context).release()
            phase = .startFailed(createResult == 0 ? EINVAL : createResult)
            self.completion = nil
            condition.broadcast()
            condition.unlock()
            throw RawHVMachineRunnerError.threadCreationFailed(
                createResult == 0 ? EINVAL : createResult
            )
        }
        nativeThread = createdThread
        phase = .running
        condition.unlock()
    }

    /// Waits for the operation and performs the one native `pthread_join`.
    ///
    /// Concurrent waiters are allowed: one performs the join and all others observe the identical
    /// result after that join completes. The operation error itself is also replayable, so a second
    /// lifecycle observer cannot accidentally consume it.
    func wait() throws -> Output {
        condition.lock()
        if let ownerThread, pthread_equal(pthread_self(), ownerThread) != 0 {
            condition.unlock()
            throw RawHVMachineRunnerError.waitFromOwnerThread
        }

        while true {
            switch phase {
            case .ready:
                condition.unlock()
                throw RawHVMachineRunnerError.notStarted
            case .startFailed(let code):
                condition.unlock()
                throw RawHVMachineRunnerError.threadCreationFailed(code)
            case .running:
                condition.wait()
            case .joining:
                condition.wait()
            case .joinFailed(let code):
                condition.unlock()
                throw RawHVMachineRunnerError.threadJoinFailed(code)
            case .joined:
                let result = self.result
                condition.unlock()
                return try requiredResult(result).get()
            case .finished:
                guard let nativeThread else {
                    phase = .joinFailed(EINVAL)
                    condition.broadcast()
                    condition.unlock()
                    throw RawHVMachineRunnerError.threadJoinFailed(EINVAL)
                }
                phase = .joining
                condition.unlock()

                let joinResult = pthread_join(nativeThread, nil)

                condition.lock()
                if joinResult == 0 {
                    phase = .joined
                    self.nativeThread = nil
                } else {
                    phase = .joinFailed(joinResult)
                }
                condition.broadcast()
                if joinResult != 0 {
                    condition.unlock()
                    throw RawHVMachineRunnerError.threadJoinFailed(joinResult)
                }
                let result = self.result
                condition.unlock()
                return try requiredResult(result).get()
            }
        }
    }

    private func threadMain() {
        RawHVSchedulingPolicy.applyToCurrentMachineOwnerThread()
        pthread_setname_np(name)

        condition.lock()
        ownerThread = pthread_self()
        condition.unlock()

        let completed = Result { try operation() }

        condition.lock()
        result = completed
        phase = .finished
        let completion = self.completion
        self.completion = nil
        condition.broadcast()
        condition.unlock()

        // Completion may only publish onto another executor; lifecycle destruction still waits for
        // `pthread_join`, which does not complete until this callback and the entry point return.
        completion?(completed)
    }

    private func requiredResult(
        _ result: Result<Output, any Error>?
    ) -> Result<Output, any Error> {
        guard let result else {
            preconditionFailure("joined RawHV owner thread did not publish a result")
        }
        return result
    }
}

/// Runs `Machine.run()` on a dedicated, non-libdispatch pthread.
///
/// `Machine.run()` makes the owner thread the boot vCPU. Secondary vCPUs already have one
/// Foundation thread each and are joined by `Machine.run()` before it returns. Joining this runner
/// therefore establishes the final boundary before device and VM teardown.
public final class RawHVMachineRunner: @unchecked Sendable {
    public typealias Completion = @Sendable (Result<GuestStopReason, any Error>) -> Void

    private let machine: Machine
    private let owner: RawHVOwnerThread<GuestStopReason>

    public init(machine: Machine, threadName: String) {
        self.machine = machine
        owner = RawHVOwnerThread(name: threadName) {
            try machine.run()
        }
    }

    public func start(completion: Completion? = nil) throws {
        try owner.start(completion: completion)
    }

    @discardableResult
    public func wait() throws -> GuestStopReason {
        try owner.wait()
    }

    @discardableResult
    public func runToCompletion() throws -> GuestStopReason {
        try start()
        return try wait()
    }

    /// Publishes the terminal reason, exits every live vCPU, and joins the owner thread.
    @discardableResult
    public func stopAndWait(_ reason: GuestStopReason) throws -> GuestStopReason {
        machine.requestStop(reason)
        return try wait()
    }
}
