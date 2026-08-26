import Darwin
import DoryOperations
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

/// Owns one daemon-admitted descriptor for the complete supervised launch, including bounded
/// startup restarts. Ownership is transferred at initialization and released exactly once.
public final class HvProcessInheritedFileDescriptor: @unchecked Sendable {
    public let name: String
    public let childDescriptor: Int32

    private let lock = NSLock()
    private var ownedDescriptor: Int32?

    public init(name: String, takingOwnershipOf descriptor: Int32, childDescriptor: Int32) {
        self.name = name
        self.childDescriptor = childDescriptor
        ownedDescriptor = descriptor
    }

    fileprivate func mapping() throws -> InheritedDescriptorMapping {
        try withBorrowedDescriptor { ownedDescriptor in
            InheritedDescriptorMapping(
                parentDescriptor: ownedDescriptor,
                childDescriptor: childDescriptor
            )
        }
    }

    /// Performs one bounded inspection while close/restart teardown cannot recycle the descriptor.
    /// This is intentionally internal: only the supervisor and daemon-side admission tests inspect
    /// parent descriptors; runtime consumers receive the fixed child slot from the envelope.
    func withBorrowedDescriptor<Result>(
        _ body: (Int32) throws -> Result
    ) throws -> Result {
        lock.lock()
        defer { lock.unlock() }
        guard let ownedDescriptor, fcntl(ownedDescriptor, F_GETFD) >= 0 else {
            throw HvProcess.ProcessError.descriptorUnavailable(name)
        }
        return try body(ownedDescriptor)
    }

    public func close() {
        let descriptor: Int32?
        lock.lock()
        descriptor = ownedDescriptor
        ownedDescriptor = nil
        lock.unlock()
        if let descriptor {
            Darwin.close(descriptor)
        }
    }

    deinit {
        close()
    }
}

public struct HvProcessConfiguration: Sendable {
    public var executablePath: String
    public var arguments: [String]
    public var environment: [String: String]
    public var logPath: String?
    public var restartPolicy: HvRestartPolicy
    public var runtimeLaunchEnvelope: RuntimeLaunchEnvelope?
    public var inheritedFileDescriptors: [HvProcessInheritedFileDescriptor]
    /// Populated only by the resolved production RawHV path after decoding the release identity
    /// from the live daemon. Legacy and test launches intentionally leave this unset.
    var rendererReleaseIdentity: DoryRendererReleaseIdentityV1?

    public init(
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        logPath: String? = nil,
        restartPolicy: HvRestartPolicy = .none,
        runtimeLaunchEnvelope: RuntimeLaunchEnvelope? = nil,
        inheritedFileDescriptors: [HvProcessInheritedFileDescriptor] = []
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.logPath = logPath
        self.restartPolicy = restartPolicy
        self.runtimeLaunchEnvelope = runtimeLaunchEnvelope
        self.inheritedFileDescriptors = inheritedFileDescriptors
        rendererReleaseIdentity = nil
    }
}

public final class HvProcess: @unchecked Sendable {
    public enum ProcessError: Error, CustomStringConvertible {
        case alreadyRunning
        case executableMissing(String)
        case startCancelled
        case descriptorUnavailable(String)
        case descriptorEnvelopeMismatch
        case disallowedResolvedEnvironmentKey(String)
        case rendererRunnerIdentityRejected(String)
        case rendererRunnerResumeFailed(Int32)

        public var description: String {
            switch self {
            case .alreadyRunning:
                return "dory-hv is already running"
            case .executableMissing(let path):
                return "dory-hv executable missing: \(path)"
            case .startCancelled:
                return "dory-hv start was cancelled"
            case .descriptorUnavailable(let name):
                return "inherited descriptor authority \(name) is unavailable"
            case .descriptorEnvelopeMismatch:
                return "inherited descriptors do not match the runtime launch envelope"
            case .disallowedResolvedEnvironmentKey(let key):
                return "resolved helper environment key \(key) is not allowlisted"
            case .rendererRunnerIdentityRejected(let detail):
                return "suspended renderer runner identity was rejected: \(detail)"
            case .rendererRunnerResumeFailed(let code):
                return "validated renderer runner could not be resumed: \(String(cString: strerror(code)))"
            }
        }
    }

    private final class SupervisedChild: @unchecked Sendable {
        let pid: pid_t
        let terminationWaiter = DispatchGroup()
        private let lifecycleLock = NSLock()
        private var terminationObserved = false

        init(pid: pid_t) {
            self.pid = pid
            terminationWaiter.enter()
        }

        /// Serializes every signal decision with the reaper's terminal observation. The reaper
        /// uses waitid(WNOWAIT), so the PID remains a non-reusable zombie until this state is set.
        func markTerminationObserved() {
            lifecycleLock.lock()
            terminationObserved = true
            lifecycleLock.unlock()
        }

        @discardableResult
        func send(_ signal: Int32) -> Bool {
            lifecycleLock.lock()
            defer { lifecycleLock.unlock() }
            guard !terminationObserved else { return false }
            return kill(pid, signal) == 0
        }
    }

    private let configuration: HvProcessConfiguration
    private let suspendedChildCodeValidator: any DorySuspendedChildCodeValidating
    private let unexpectedTerminationHandler: HvProcessUnexpectedTerminationHandler?
    private let lock = NSLock()
    private var process: SupervisedChild?
    private var logDescriptor: Int32?
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
        suspendedChildCodeValidator = DorySecuritySuspendedChildCodeValidator()
        self.unexpectedTerminationHandler = unexpectedTerminationHandler
    }

    /// Internal injection seam for deterministic lifecycle tests. Production always uses the
    /// Security.framework-backed validator selected by the public initializer.
    init(
        configuration: HvProcessConfiguration,
        suspendedChildCodeValidator: any DorySuspendedChildCodeValidating,
        unexpectedTerminationHandler: HvProcessUnexpectedTerminationHandler? = nil
    ) {
        self.configuration = configuration
        self.suspendedChildCodeValidator = suspendedChildCodeValidator
        self.unexpectedTerminationHandler = unexpectedTerminationHandler
    }

    public var pid: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return process?.pid
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process != nil
    }

    /// True while a helper is running or a bounded restart has already been scheduled.
    /// Callers use this to distinguish a transient startup handoff from a terminal exit.
    public var isRunningOrRestarting: Bool {
        lock.lock()
        defer { lock.unlock() }
        // Keep the launch active while the reaper is between observing child exit and deciding
        // whether a retry is permitted.
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
        if process != nil {
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
        let mappings = try configuration.inheritedFileDescriptors.map { try $0.mapping() }
        try validateDescriptorEnvelope(mappings: mappings)
        let log = Self.openAppendLog(configuration.logPath)
        let standardInput = open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard standardInput >= 0 else {
            if let log { Darwin.close(log) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(standardInput) }
        let outputDescriptor = log ?? STDERR_FILENO
        let errorDescriptor = log ?? STDERR_FILENO
        let (environment, inheritParentEnvironment) = try spawnEnvironment()
        let expectedRunnerIdentity = configuration.rendererReleaseIdentity.map {
            DoryLiveRunnerCodeIdentity(codeDirectoryHash: $0.runnerCodeDirectoryHash)
        }
        let childPID: pid_t
        do {
            childPID = try InheritedDescriptorSpawner.spawn(
                executablePath: configuration.executablePath,
                arguments: configuration.arguments,
                environment: environment,
                inheritParentEnvironment: inheritParentEnvironment,
                startSuspended: expectedRunnerIdentity != nil,
                descriptorMappings: mappings,
                standardInputDescriptor: standardInput,
                standardOutputDescriptor: outputDescriptor,
                standardErrorDescriptor: errorDescriptor
            )
        } catch {
            if let log { Darwin.close(log) }
            throw error
        }
        if let expectedRunnerIdentity {
            do {
                try suspendedChildCodeValidator.validateSuspendedChild(
                    pid: childPID,
                    expectedIdentity: expectedRunnerIdentity
                )
            } catch {
                Self.killAndReapUnpublishedChild(childPID)
                if let log { Darwin.close(log) }
                // Identity rejection is terminal for this supervised launch generation. In
                // particular, a startup restart must not turn a rejected live image into a
                // path-based retry loop.
                restartsEnabled = false
                restartPending = false
                closeInheritedDescriptors()
                let wrapped = ProcessError.rendererRunnerIdentityRejected("\(error)")
                lastLaunchError = wrapped.description
                throw wrapped
            }
            if let resumeError = Self.sendSignal(SIGCONT, to: childPID) {
                Self.killAndReapUnpublishedChild(childPID)
                if let log { Darwin.close(log) }
                restartsEnabled = false
                restartPending = false
                closeInheritedDescriptors()
                let wrapped = ProcessError.rendererRunnerResumeFailed(resumeError)
                lastLaunchError = wrapped.description
                throw wrapped
            }
        }

        // Do not publish the PID or start the supervised reaper until the exact live code object
        // has passed validation and the same suspended child has been resumed successfully.
        let child = SupervisedChild(pid: childPID)
        process = child
        logDescriptor = log
        DispatchQueue.global(qos: .utility).async { [weak self, child] in
            let termination = Self.waitForTermination(of: child)
            self?.handleTermination(child, termination: termination)
            child.terminationWaiter.leave()
        }
    }

    private static func sendSignal(_ signal: Int32, to pid: pid_t) -> Int32? {
        while true {
            if kill(pid, signal) == 0 { return nil }
            let code = errno
            if code == EINTR { continue }
            return code
        }
    }

    /// Exact cleanup for a child that has not entered supervised state. `waitpid` is deliberate:
    /// no asynchronous reaper exists before publication, and leaving this process as a zombie
    /// would also leave its PID/code identity ambiguous to later launch attempts.
    private static func killAndReapUnpublishedChild(_ pid: pid_t) {
        _ = sendSignal(SIGKILL, to: pid)
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, 0)
            if result == pid { return }
            if result < 0, errno == EINTR { continue }
            return
        }
    }

    private func validateDescriptorEnvelope(mappings: [InheritedDescriptorMapping]) throws {
        guard let envelope = configuration.runtimeLaunchEnvelope else {
            guard mappings.isEmpty else { throw ProcessError.descriptorEnvelopeMismatch }
            return
        }
        let slots = envelope.inheritedFileDescriptors
        guard slots.count == configuration.inheritedFileDescriptors.count,
              zip(slots, configuration.inheritedFileDescriptors).allSatisfy({ slot, authority in
                  slot.name == authority.name && slot.descriptor == authority.childDescriptor
              }) else {
            throw ProcessError.descriptorEnvelopeMismatch
        }
        _ = try envelope.validatedResolvedRawHVResources()
    }

    private func spawnEnvironment() throws -> ([String: String], Bool) {
        guard configuration.runtimeLaunchEnvelope != nil else {
            return (configuration.environment, true)
        }
        let allowed = Set([
            "HOME", "LANG", "LC_ALL", "LOGNAME", "PATH", "TMPDIR", "TZ", "USER",
        ])
        if let disallowed = configuration.environment.keys.first(where: { !allowed.contains($0) }) {
            throw ProcessError.disallowedResolvedEnvironmentKey(disallowed)
        }
        var environment: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C.UTF-8",
        ]
        for key in allowed {
            if let explicit = configuration.environment[key] {
                environment[key] = explicit
            } else if let inherited = ProcessInfo.processInfo.environment[key] {
                environment[key] = inherited
            }
        }
        return (environment, false)
    }

    private static func openAppendLog(_ path: String?) -> Int32? {
        guard let path else { return nil }
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        return fd
    }

    private static func waitForTermination(of child: SupervisedChild) -> HvProcessTermination {
        var terminalInfo = siginfo_t()
        while true {
            // Observe exit without reaping first. This keeps the PID reserved by the kernel while
            // markTerminationObserved closes the signal/PID-reuse race for stop/suspend/resume.
            let result = waitid(P_PID, id_t(child.pid), &terminalInfo, WEXITED | WNOWAIT)
            if result == 0 {
                if [CLD_EXITED, CLD_KILLED, CLD_DUMPED].contains(terminalInfo.si_code) {
                    break
                }
                // Darwin can surface a pending stop/continue notification here even when only
                // WEXITED was requested. Consume that nonterminal state change and keep waiting;
                // marking it terminal would prevent stop() from resuming a suspended child.
                var stateChange: Int32 = 0
                while waitpid(child.pid, &stateChange, WUNTRACED | WCONTINUED) < 0,
                      errno == EINTR {}
                continue
            }
            if errno == EINTR { continue }
            child.markTerminationObserved()
            return HvProcessTermination(status: errno, wasUncaughtSignal: false)
        }
        child.markTerminationObserved()

        var rawStatus: Int32 = 0
        while true {
            let result = waitpid(child.pid, &rawStatus, 0)
            if result == child.pid {
                let signal = rawStatus & 0x7f
                if signal == 0 {
                    return HvProcessTermination(
                        status: (rawStatus >> 8) & 0xff,
                        wasUncaughtSignal: false
                    )
                }
                return HvProcessTermination(status: signal, wasUncaughtSignal: true)
            }
            if result < 0, errno == EINTR { continue }
            return HvProcessTermination(status: errno, wasUncaughtSignal: false)
        }
    }

    private func handleTermination(
        _ child: SupervisedChild,
        termination: HvProcessTermination
    ) {
        let oldLog: Int32?
        let shouldRestart: Bool
        let delay: TimeInterval
        let wasUnexpected: Bool
        lock.lock()
        guard process === child else {
            lock.unlock()
            return
        }
        lastTerminationStatus = termination.status
        process = nil
        suspended = false
        oldLog = logDescriptor
        logDescriptor = nil
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
        if let oldLog { Darwin.close(oldLog) }

        if wasUnexpected {
            unexpectedTerminationHandler?(termination)
        }

        guard shouldRestart else {
            closeInheritedDescriptors()
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.restartAfterUnexpectedExit()
        }
    }

    private func restartAfterUnexpectedExit() {
        lock.lock()
        guard !stopping, restartsEnabled, restartPending, process == nil else {
            restartPending = false
            lock.unlock()
            closeInheritedDescriptors()
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
            } else {
                closeInheritedDescriptors()
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
        closeInheritedDescriptors()
    }

    /// Marks the next helper exit as an expected lifecycle transition without sending a signal.
    /// Used after a saved-state command has been accepted: dory-vmm exits itself only after the
    /// VZ payload is complete. The caller must cancel this expectation if the command fails.
    public func prepareForExpectedExit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard process != nil, !stopping else { return false }
        stopping = true
        expectedExitPreviousRestartsEnabled = nil
        expectedExitPreviousRestartsEnabled = restartsEnabled
        restartsEnabled = false
        restartPending = false
        return true
    }

    public func cancelExpectedExit() {
        lock.lock()
        if process != nil {
            stopping = false
            restartsEnabled = expectedExitPreviousRestartsEnabled ?? restartsEnabled
        }
        expectedExitPreviousRestartsEnabled = nil
        lock.unlock()
    }

    public func waitForExpectedExit(timeout: TimeInterval) -> Bool {
        lock.lock()
        let waiter = process?.terminationWaiter
        lock.unlock()
        guard let waiter else { return true }
        return waiter.wait(timeout: .now() + max(0, timeout)) == .success
    }

    public var isSuspended: Bool {
        lock.lock()
        defer { lock.unlock() }
        return suspended && process != nil
    }

    @discardableResult
    public func suspend() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let process else { return false }
        if suspended { return true }
        guard process.send(SIGSTOP) else { return false }
        suspended = true
        return true
    }

    @discardableResult
    public func resume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let process else { return false }
        if !suspended { return true }
        guard process.send(SIGCONT) else { return false }
        suspended = false
        return true
    }

    public func stop(signal: Int32 = SIGTERM, timeout: TimeInterval = 5) {
        let child: SupervisedChild?
        let terminationWaiter: DispatchGroup?
        let oldLog: Int32?
        let wasSuspended: Bool
        lock.lock()
        stopping = true
        restartsEnabled = false
        restartPending = false
        child = process
        terminationWaiter = child?.terminationWaiter
        // Take-and-null the handle so exactly one of stop()/handleTermination closes it; a
        // double close could otherwise land on a recycled fd.
        oldLog = logDescriptor
        logDescriptor = nil
        wasSuspended = suspended
        suspended = false
        lock.unlock()

        guard let child else {
            if let oldLog { Darwin.close(oldLog) }
            closeInheritedDescriptors()
            return
        }
        if wasSuspended {
            child.send(SIGCONT)
        }
        // The child lifecycle lock suppresses this signal once waitid has observed a terminal
        // state, while WNOWAIT keeps the PID reserved until the exact waitpid reap below.
        child.send(signal)

        // Wait for the exact child's termination handler so a replacement cannot reuse VM disks
        // or inherited authority early.
        let deadline = DispatchTime.now() + max(0, timeout)
        if terminationWaiter?.wait(timeout: deadline) == .timedOut {
            child.send(SIGKILL)
            terminationWaiter?.wait()
        }

        if let oldLog { Darwin.close(oldLog) }
        closeInheritedDescriptors()
    }

    private func closeInheritedDescriptors() {
        for authority in configuration.inheritedFileDescriptors {
            authority.close()
        }
    }

    deinit {
        stop()
    }
}
