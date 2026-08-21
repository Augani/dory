import Darwin
import Foundation

public struct HvRestartPolicy: Sendable, Equatable {
    public var maxRestarts: Int
    public var delaySeconds: TimeInterval
    public var maximumDelaySeconds: TimeInterval
    public var stableRunSeconds: TimeInterval

    public init(
        maxRestarts: Int = 0,
        delaySeconds: TimeInterval = 0.25,
        maximumDelaySeconds: TimeInterval = 5,
        stableRunSeconds: TimeInterval = 30
    ) {
        self.maxRestarts = max(0, maxRestarts)
        self.delaySeconds = max(0, delaySeconds)
        self.maximumDelaySeconds = max(self.delaySeconds, maximumDelaySeconds)
        self.stableRunSeconds = max(0, stableRunSeconds)
    }

    public static let none = HvRestartPolicy()

    public func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0, delaySeconds > 0 else { return 0 }
        let exponent = min(attempt - 1, 20)
        return min(maximumDelaySeconds, delaySeconds * pow(2, Double(exponent)))
    }
}

public struct HvProcessTermination: Sendable, Equatable {
    public var status: Int32
    public var wasUncaughtSignal: Bool

    public init(status: Int32, wasUncaughtSignal: Bool) {
        self.status = status
        self.wasUncaughtSignal = wasUncaughtSignal
    }

    public var description: String {
        wasUncaughtSignal ? "terminated by signal \(status)" : "exited with status \(status)"
    }
}

public typealias HvProcessUnexpectedTerminationHandler = @Sendable (HvProcessTermination) -> Void

public struct HvProcessConfiguration: Sendable {
    public var executablePath: String
    public var arguments: [String]
    public var environment: [String: String]
    public var logPath: String?
    public var restartPolicy: HvRestartPolicy

    public init(
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        logPath: String? = nil,
        restartPolicy: HvRestartPolicy = .none
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.logPath = logPath
        self.restartPolicy = restartPolicy
    }
}

public final class HvProcess: @unchecked Sendable {
    public enum ProcessError: Error, CustomStringConvertible {
        case alreadyRunning
        case executableMissing(String)
        case startCancelled

        public var description: String {
            switch self {
            case .alreadyRunning:
                return "dory-hv is already running"
            case .executableMissing(let path):
                return "dory-hv executable missing: \(path)"
            case .startCancelled:
                return "dory-hv start was cancelled"
            }
        }
    }

    private let configuration: HvProcessConfiguration
    private let unexpectedTerminationHandler: HvProcessUnexpectedTerminationHandler?
    private let lock = NSLock()
    private var process: Process?
    private var terminationWaiter: DispatchGroup?
    private var logHandle: FileHandle?
    private var stopping = false
    private var hasStarted = false
    private var suspended = false
    private var restartCount = 0
    private var restartPending = false
    private var restartsEnabled = true
    private var expectedExitPreviousRestartsEnabled: Bool?
    private var lastTerminationStatus: Int32?
    private var lastLaunchError: String?

    public init(
        configuration: HvProcessConfiguration,
        unexpectedTerminationHandler: HvProcessUnexpectedTerminationHandler? = nil
    ) {
        self.configuration = configuration
        self.unexpectedTerminationHandler = unexpectedTerminationHandler
    }

    public var pid: Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning == true
    }

    /// True while a helper is running or a bounded restart has already been scheduled.
    /// Callers use this to distinguish a transient startup handoff from a terminal exit.
    public var isRunningOrRestarting: Bool {
        lock.lock()
        defer { lock.unlock() }
        // Keep the launch active while Foundation is between observing child exit and invoking
        // its termination callback; that callback decides whether a retry is permitted.
        return (!stopping && process != nil) || (!stopping && restartsEnabled && restartPending)
    }

    public var terminationStatus: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return lastTerminationStatus
    }

    public var launchError: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastLaunchError
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        if process?.isRunning == true {
            throw ProcessError.alreadyRunning
        }
        // A DockerTier shutdown can publish and stop this newly-created process object just
        // before the startup thread enters start(). Do not erase that cancellation and spawn a
        // child after the shutdown caller has already returned.
        if stopping, !hasStarted {
            throw ProcessError.startCancelled
        }
        hasStarted = true
        stopping = false
        suspended = false
        restartCount = 0
        restartPending = false
        restartsEnabled = true
        expectedExitPreviousRestartsEnabled = nil
        lastTerminationStatus = nil
        lastLaunchError = nil
        try launchLocked()
    }

    private func launchLocked() throws {
        guard FileManager.default.isExecutableFile(atPath: configuration.executablePath) else {
            throw ProcessError.executableMissing(configuration.executablePath)
        }
        let task = Process()
        let terminationWaiter = DispatchGroup()
        terminationWaiter.enter()
        task.executableURL = URL(fileURLWithPath: configuration.executablePath)
        task.arguments = configuration.arguments
        if !configuration.environment.isEmpty {
            task.environment = ProcessInfo.processInfo.environment.merging(configuration.environment) { _, new in new }
        }
        let log = Self.openAppendLog(configuration.logPath)
        task.standardOutput = log ?? FileHandle.standardError
        task.standardError = log ?? FileHandle.standardError
        task.terminationHandler = { [weak self] task in
            self?.handleTermination(task)
            terminationWaiter.leave()
        }
        process = task
        self.terminationWaiter = terminationWaiter
        logHandle = log
        do {
            try task.run()
        } catch {
            process = nil
            self.terminationWaiter = nil
            logHandle = nil
            try? log?.close()
            throw error
        }
    }

    private static func openAppendLog(_ path: String?) -> FileHandle? {
        guard let path else { return nil }
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private func handleTermination(_ task: Process) {
        let oldLog: FileHandle?
        let shouldRestart: Bool
        let delay: TimeInterval
        let wasUnexpected: Bool
        let termination = HvProcessTermination(
            status: task.terminationStatus,
            wasUncaughtSignal: task.terminationReason == .uncaughtSignal
        )
        lock.lock()
        guard process === task else {
            lock.unlock()
            return
        }
        lastTerminationStatus = task.terminationStatus
        process = nil
        terminationWaiter = nil
        suspended = false
        oldLog = logHandle
        logHandle = nil
        wasUnexpected = !stopping
        shouldRestart = wasUnexpected
            && restartsEnabled
            && restartCount < configuration.restartPolicy.maxRestarts
        if shouldRestart {
            restartCount += 1
        }
        restartPending = shouldRestart
        expectedExitPreviousRestartsEnabled = nil
        delay = configuration.restartPolicy.delay(forAttempt: restartCount)
        lock.unlock()
        try? oldLog?.close()

        if wasUnexpected {
            unexpectedTerminationHandler?(termination)
        }

        guard shouldRestart else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.restartAfterUnexpectedExit()
        }
    }

    private func restartAfterUnexpectedExit() {
        lock.lock()
        guard !stopping, restartsEnabled, restartPending, process == nil else {
            restartPending = false
            lock.unlock()
            return
        }
        restartPending = false
        do {
            try launchLocked()
            lock.unlock()
        } catch {
            lastLaunchError = "\(error)"
            let shouldRetry = !stopping
                && restartsEnabled
                && restartCount < configuration.restartPolicy.maxRestarts
            if shouldRetry {
                restartCount += 1
                restartPending = true
            }
            let delay = configuration.restartPolicy.delay(forAttempt: restartCount)
            lock.unlock()
            if shouldRetry {
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.restartAfterUnexpectedExit()
                }
            }
        }
    }

    /// Startup retries are useful until the supervisor accepts the ready handoff. After that
    /// point an unexpected VMM exit is a real machine failure and must remain visible.
    public func disableRestarts() {
        lock.lock()
        restartsEnabled = false
        restartPending = false
        lock.unlock()
    }

    /// Marks the next helper exit as an expected lifecycle transition without sending a signal.
    /// Used after a saved-state command has been accepted: dory-vmm exits itself only after the
    /// VZ payload is complete. The caller must cancel this expectation if the command fails.
    public func prepareForExpectedExit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard process?.isRunning == true, !stopping else { return false }
        stopping = true
        expectedExitPreviousRestartsEnabled = nil
        expectedExitPreviousRestartsEnabled = restartsEnabled
        restartsEnabled = false
        restartPending = false
        return true
    }

    public func cancelExpectedExit() {
        lock.lock()
        if process?.isRunning == true {
            stopping = false
            restartsEnabled = expectedExitPreviousRestartsEnabled ?? restartsEnabled
        }
        expectedExitPreviousRestartsEnabled = nil
        lock.unlock()
    }

    public func waitForExpectedExit(timeout: TimeInterval) -> Bool {
        lock.lock()
        let waiter = terminationWaiter
        lock.unlock()
        guard let waiter else { return true }
        return waiter.wait(timeout: .now() + max(0, timeout)) == .success
    }

    public var isSuspended: Bool {
        lock.lock()
        defer { lock.unlock() }
        return suspended && process?.isRunning == true
    }

    @discardableResult
    public func suspend() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let process, process.isRunning else { return false }
        if suspended { return true }
        guard kill(process.processIdentifier, SIGSTOP) == 0 else { return false }
        suspended = true
        return true
    }

    @discardableResult
    public func resume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let process, process.isRunning else { return false }
        if !suspended { return true }
        guard kill(process.processIdentifier, SIGCONT) == 0 else { return false }
        suspended = false
        return true
    }

    public func stop(signal: Int32 = SIGTERM, timeout: TimeInterval = 5) {
        let task: Process?
        let terminationWaiter: DispatchGroup?
        let oldLog: FileHandle?
        let wasSuspended: Bool
        lock.lock()
        stopping = true
        restartsEnabled = false
        restartPending = false
        task = process
        terminationWaiter = self.terminationWaiter
        // Take-and-null the handle so exactly one of stop()/handleTermination closes it; a
        // double close could otherwise land on a recycled fd.
        oldLog = logHandle
        logHandle = nil
        wasSuspended = suspended
        suspended = false
        lock.unlock()

        guard let task else {
            try? oldLog?.close()
            return
        }
        if wasSuspended {
            kill(task.processIdentifier, SIGCONT)
        }
        // Process.isRunning may briefly read false before its termination callback fires. Send
        // the signal unconditionally; ESRCH is harmless and avoids waiting for a live child to
        // reach the timeout solely because Foundation exposed that transient state.
        kill(task.processIdentifier, signal)

        // Process.isRunning can flip to false when SIGTERM is delivered while the child is still
        // draining. Wait for its termination callback so a replacement cannot reuse VM disks early.
        let deadline = DispatchTime.now() + max(0, timeout)
        if terminationWaiter?.wait(timeout: deadline) == .timedOut {
            kill(task.processIdentifier, SIGKILL)
            task.waitUntilExit()
        }

        lock.lock()
        if process === task {
            process = nil
            self.terminationWaiter = nil
            logHandle = nil
            suspended = false
        }
        lock.unlock()
        try? oldLog?.close()
    }

    deinit {
        stop()
    }
}
