import Darwin
import DoryOperations
import Foundation

/// A semaphore-backed lifecycle mutex whose timed acquisition uses Dispatch's monotonic clock.
/// Process stop paths use the timed form so a concurrent launch cannot consume an unbounded part
/// of the caller's shutdown budget before terminal cleanup even begins.
final class DoryProcessLifecycleMutex: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 1)

    func lock() {
        semaphore.wait()
    }

    func lock(until deadline: DispatchTime) -> Bool {
        semaphore.wait(timeout: deadline) == .success
    }

    func unlock() {
        semaphore.signal()
    }
}

/// Coalesces stop requests that could not acquire a supervisor's launch mutex before the caller's
/// absolute deadline. The operation is deliberately independent from that mutex: recording the
/// request cannot be delayed by a LaunchServices or `posix_spawn` handoff, and the private worker
/// retains the supervisor until it has acquired the mutex and applied the stop to the exact
/// supervised generation. Callers never wait on this worker after their own deadline expires.
final class DoryDeferredProcessStopCoordinator: @unchecked Sendable {
    private final class Operation: @unchecked Sendable {
        let signal: Int32
        let gracefulTimeout: TimeInterval
        let forcedTimeout: TimeInterval
        let completion = DispatchGroup()

        init(signal: Int32, gracefulTimeout: TimeInterval, forcedTimeout: TimeInterval) {
            self.signal = signal
            self.gracefulTimeout = gracefulTimeout
            self.forcedTimeout = forcedTimeout
            completion.enter()
        }
    }

    private let lock = NSLock()
    private let queue: DispatchQueue
    private var operation: Operation?

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .utility)
    }

    var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return operation != nil
    }

    /// Joins the exact deferred operation that was pending at entry. A later operation cannot be
    /// substituted underneath the waiter, and the caller supplies the complete monotonic budget.
    func wait(until deadline: DispatchTime) -> Bool {
        lock.lock()
        let pending = operation
        lock.unlock()
        guard let pending else { return true }
        return pending.completion.wait(timeout: deadline) == .success
    }

    /// Returns `true` only for the caller that created the one pending operation. Later callers
    /// join that retained operation by leaving it installed; they do not enqueue duplicate signals.
    @discardableResult
    func schedule(
        signal: Int32,
        gracefulTimeout: TimeInterval,
        forcedTimeout: TimeInterval,
        perform: @escaping @Sendable (Int32, TimeInterval, TimeInterval) -> Void
    ) -> Bool {
        lock.lock()
        guard operation == nil else {
            lock.unlock()
            return false
        }
        let operation = Operation(
            signal: signal,
            gracefulTimeout: gracefulTimeout.isFinite ? max(0, gracefulTimeout) : 5,
            forcedTimeout: forcedTimeout.isFinite ? max(0, forcedTimeout) : 2
        )
        self.operation = operation
        lock.unlock()

        queue.async { [self, operation] in
            perform(
                operation.signal,
                operation.gracefulTimeout,
                operation.forcedTimeout
            )
            lock.lock()
            if self.operation === operation {
                self.operation = nil
            }
            operation.completion.leave()
            lock.unlock()
        }
        return true
    }
}

/// One absolute stop budget, measured from public API entry. The graceful and forced phases never
/// manufacture fresh relative timeouts after waiting for another lifecycle operation's mutex.
struct DoryProcessStopDeadline: Sendable, Equatable {
    let graceful: DispatchTime
    let final: DispatchTime

    init(
        gracefulTimeout: TimeInterval,
        forcedTimeout: TimeInterval,
        startedAt: DispatchTime = .now()
    ) {
        let boundedGraceful = gracefulTimeout.isFinite ? max(0, gracefulTimeout) : 5
        let boundedForced = forcedTimeout.isFinite ? max(0, forcedTimeout) : 2
        graceful = Self.adding(boundedGraceful, to: startedAt)
        final = Self.adding(boundedForced, to: graceful)
    }

    private static func adding(_ seconds: TimeInterval, to time: DispatchTime) -> DispatchTime {
        let maximumSeconds = Double(UInt64.max) / 1_000_000_000
        let nanoseconds = seconds >= maximumSeconds
            ? UInt64.max
            : UInt64(seconds * 1_000_000_000)
        let sum = time.uptimeNanoseconds.addingReportingOverflow(nanoseconds)
        return DispatchTime(uptimeNanoseconds: sum.overflow ? UInt64.max : sum.partialValue)
    }
}

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
    public var statusIsKnown: Bool

    public init(
        status: Int32,
        wasUncaughtSignal: Bool,
        statusIsKnown: Bool = true
    ) {
        self.status = status
        self.wasUncaughtSignal = wasUncaughtSignal
        self.statusIsKnown = statusIsKnown
    }

    public var description: String {
        guard statusIsKnown else { return "exited; status unavailable" }
        return wasUncaughtSignal
            ? "terminated by signal \(status)"
            : "exited with status \(status)"
    }
}

public typealias HvProcessUnexpectedTerminationHandler = @Sendable (HvProcessTermination) -> Void

public enum HvProcessLaunchStyle: Sendable, Equatable {
    /// Ordinary CLI helpers remain direct daemon children and retain waitpid supervision.
    case directExecutable
    /// A signed `.app` is launched by LaunchServices so TCC attributes protected devices to the
    /// application itself. Runtime descriptors arrive through the authenticated launch gate.
    case applicationBundle
}

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
    public var launchStyle: HvProcessLaunchStyle
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
        inheritedFileDescriptors: [HvProcessInheritedFileDescriptor] = [],
        launchStyle: HvProcessLaunchStyle = .directExecutable
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.logPath = logPath
        self.restartPolicy = restartPolicy
        self.runtimeLaunchEnvelope = runtimeLaunchEnvelope
        self.inheritedFileDescriptors = inheritedFileDescriptors
        self.launchStyle = launchStyle
        rendererReleaseIdentity = nil
    }
}

public final class HvProcess: @unchecked Sendable {
    static let applicationLaunchCleanupTimeoutSeconds: TimeInterval = 2
    static let unpublishedChildCleanupTimeoutSeconds: TimeInterval = 0.25
    static let forcedTerminationGraceSeconds: TimeInterval = 2
    static let maximumInterruptedWaitAttempts = 8

    public enum ProcessError: Error, CustomStringConvertible {
        case alreadyRunning
        case executableMissing(String)
        case startCancelled
        case descriptorUnavailable(String)
        case descriptorEnvelopeMismatch
        case disallowedResolvedEnvironmentKey(String)
        case rendererRunnerIdentityRejected(String)
        case rendererRunnerResumeFailed(Int32)
        case applicationRunnerLaunchFailed(String)

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
                return "launch-gated renderer runner identity was rejected: \(detail)"
            case .rendererRunnerResumeFailed(let code):
                return "validated renderer runner could not be resumed: \(String(cString: strerror(code)))"
            case .applicationRunnerLaunchFailed(let detail):
                return "Dory desktop helper application launch failed: \(detail)"
            }
        }
    }

    private final class SupervisedChild: @unchecked Sendable {
        let pid: pid_t
        let applicationMonitor: DoryApplicationProcessMonitor?
        /// Retains the exact LaunchServices process object for the complete supervision window.
        /// The peer audit token, rather than this object's numeric PID, authorizes every signal.
        let applicationLaunch: DoryWorkspaceApplicationLaunch?
        let applicationAuditToken: audit_token_t?
        let terminationWaiter = DispatchGroup()
        private let lifecycleLock = NSLock()
        private var terminationObserved = false

        init(
            pid: pid_t,
            applicationMonitor: DoryApplicationProcessMonitor? = nil,
            applicationLaunch: DoryWorkspaceApplicationLaunch? = nil,
            applicationAuditToken: audit_token_t? = nil
        ) {
            self.pid = pid
            self.applicationMonitor = applicationMonitor
            self.applicationLaunch = applicationLaunch
            self.applicationAuditToken = applicationAuditToken
            terminationWaiter.enter()
        }

        /// Serializes every signal decision with terminal observation. Direct children remain
        /// reserved by waitid(WNOWAIT); application helpers use their immutable audit token.
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
            if let applicationAuditToken {
                switch DoryApplicationLaunchHandoffProtocol.signal(
                    signal,
                    auditToken: applicationAuditToken
                ) {
                case .delivered:
                    return true
                case .failed:
                    return false
                case .unavailable:
                    // Early Sonoma lacks the audit-token signal syscall. AppKit termination is
                    // still bound to this retained launch instance; other signals fail closed.
                    switch signal {
                    case SIGTERM:
                        return applicationLaunch?.terminate() == true
                    case SIGKILL:
                        return applicationLaunch?.forceTerminate() == true
                    default:
                        return false
                    }
                }
            }
            return HvProcess.signalErrorWithBoundedRetries {
                let result = kill(pid, signal)
                return (result == 0, result == 0 ? 0 : errno)
            } == nil
        }
    }

    enum UnpublishedChildWaitObservation: Equatable {
        case reaped
        case running
        case failed(Int32)
    }

    enum DirectChildTerminalObservation: Equatable {
        case exited
        case noChild
    }

    /// Retains the exact, still-unreaped direct child after bounded synchronous cleanup expires.
    /// The child PID remains kernel-reserved until waitpid succeeds, and this private queue keeps
    /// retrying SIGKILL plus nonblocking reap without holding the daemon launch or machine lock.
    private final class UnpublishedChildTerminalRetirement: @unchecked Sendable {
        private let pid: pid_t
        private let retryDelay: TimeInterval
        private let queue: DispatchQueue
        private let onRetired: @Sendable () -> Void
        private let completion = DispatchGroup()

        private init(
            pid: pid_t,
            retryDelay: TimeInterval,
            onRetired: @escaping @Sendable () -> Void
        ) {
            self.pid = pid
            self.retryDelay = max(0.001, retryDelay)
            queue = DispatchQueue(
                label: "dev.dory.unpublished-child-terminal-retirement",
                qos: .utility
            )
            self.onRetired = onRetired
            completion.enter()
        }

        static func begin(
            pid: pid_t,
            retryDelay: TimeInterval = 0.05,
            onRetired: @escaping @Sendable () -> Void
        ) -> UnpublishedChildTerminalRetirement {
            let retirement = UnpublishedChildTerminalRetirement(
                pid: pid,
                retryDelay: retryDelay,
                onRetired: onRetired
            )
            retirement.queue.async { retirement.attempt() }
            return retirement
        }

        func waitForTermination(timeout: TimeInterval) -> Bool {
            completion.wait(timeout: .now() + max(0, timeout)) == .success
        }

        func waitForTermination() {
            completion.wait()
        }

        private func attempt() {
            _ = HvProcess.sendSignal(SIGKILL, to: pid)
            var status: Int32 = 0
            let observation = HvProcess.observeUnpublishedChild(pid: pid) {
                let result = waitpid(pid, &status, WNOHANG)
                return (result, result < 0 ? errno : 0)
            }
            switch observation {
            case .reaped:
                onRetired()
                completion.leave()
            case .running, .failed:
                queue.asyncAfter(deadline: .now() + retryDelay) { [self] in
                    attempt()
                }
            }
        }
    }

    private let configuration: HvProcessConfiguration
    private let launchGatedChildCodeValidator: any DoryLaunchGatedChildCodeValidating
    private let applicationLauncher: DoryWorkspaceApplicationLauncher
    private let unexpectedTerminationHandler: HvProcessUnexpectedTerminationHandler?
    private let lock = DoryProcessLifecycleMutex()
    private let deferredStop = DoryDeferredProcessStopCoordinator(
        label: "dev.dory.hv-process.deferred-stop"
    )
    private var process: SupervisedChild?
    /// A launch can fail after LaunchServices created the exact application but before it became a
    /// published `SupervisedChild`. Keep that terminal cleanup represented in this supervisor so
    /// callers cannot mistake an asynchronously retiring runner for a fully stopped generation.
    private var terminalRetirement: DoryApplicationTerminalRetirement?
    private var unpublishedChildRetirement: UnpublishedChildTerminalRetirement?
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
    private var postPublicationLifecycleGateForTesting: (@Sendable (Int32) -> Void)?

    public init(
        configuration: HvProcessConfiguration,
        unexpectedTerminationHandler: HvProcessUnexpectedTerminationHandler? = nil
    ) {
        self.configuration = configuration
        launchGatedChildCodeValidator = DorySecurityLaunchGatedChildCodeValidator()
        applicationLauncher = DoryWorkspaceApplicationLauncher()
        self.unexpectedTerminationHandler = unexpectedTerminationHandler
    }

    /// Internal injection seam for deterministic lifecycle tests. Production always uses the
    /// Security.framework-backed validator selected by the public initializer.
    init(
        configuration: HvProcessConfiguration,
        suspendedChildCodeValidator: any DoryLaunchGatedChildCodeValidating,
        unexpectedTerminationHandler: HvProcessUnexpectedTerminationHandler? = nil
    ) {
        self.configuration = configuration
        launchGatedChildCodeValidator = suspendedChildCodeValidator
        applicationLauncher = DoryWorkspaceApplicationLauncher()
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
            || terminalRetirement != nil
            || unpublishedChildRetirement != nil
            || deferredStop.isPending
    }

    func lifecycleObservation(
        until deadline: DispatchTime
    ) -> DockerManagedProcessObservation? {
        guard lock.lock(until: deadline) else { return nil }
        let childPID = process?.pid
        let ownsRuntimeAuthority = process != nil
            || terminalRetirement != nil
            || unpublishedChildRetirement != nil
            || deferredStop.isPending
        lock.unlock()
        return DockerManagedProcessObservation(
            pid: childPID,
            isRunning: ownsRuntimeAuthority
        )
    }

    /// True while a helper is running or a bounded restart has already been scheduled.
    /// Callers use this to distinguish a transient startup handoff from a terminal exit.
    public var isRunningOrRestarting: Bool {
        lock.lock()
        defer { lock.unlock() }
        // Keep the launch active while the reaper is between observing child exit and deciding
        // whether a retry is permitted.
        return (!stopping && process != nil)
            || (!stopping && terminalRetirement != nil)
            || (!stopping && unpublishedChildRetirement != nil)
            || (!stopping && restartsEnabled && restartPending)
    }

    public var terminationStatus: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return lastTerminationStatus
    }

    /// Internal lifecycle seam used to prove that callers retain launch authority when an app was
    /// created but failed before `SupervisedChild` publication. Production enters the identical
    /// state through `beginTerminalRetirement(application:)` in the LaunchServices failure paths.
    func installPrepublicationTerminalRetirement(
        application: any DoryApplicationTerminationControlling,
        retryDelay: TimeInterval = 0.01
    ) {
        lock.lock()
        precondition(
            process == nil
                && terminalRetirement == nil
                && unpublishedChildRetirement == nil
        )
        terminalRetirement = DoryApplicationTerminalRetirement.begin(
            application: application,
            retryDelay: retryDelay
        ) { [self] in
            lock.lock()
            terminalRetirement = nil
            lock.unlock()
            closeInheritedDescriptors()
        }
        lock.unlock()
    }

    public var launchError: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastLaunchError
    }

    /// Internal deterministic race seam. The callback runs with the lifecycle reservation held
    /// after the exact child is published and before `start()` can return. Production never sets it.
    func installPostPublicationLifecycleGateForTesting(
        _ gate: @escaping @Sendable (Int32) -> Void
    ) {
        lock.lock()
        precondition(!hasStarted && process == nil)
        postPublicationLifecycleGateForTesting = gate
        lock.unlock()
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        if process != nil
            || terminalRetirement != nil
            || unpublishedChildRetirement != nil {
            throw ProcessError.alreadyRunning
        }
        // A DockerTier shutdown can publish and stop this newly-created process object just
        // before the startup thread enters start(). Do not erase that cancellation and spawn a
        // child after the shutdown caller has already returned.
        if stopping, !hasStarted {
            throw ProcessError.startCancelled
        }
        if deferredStop.isPending {
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
        // A bounded stop can lose the mutex race at the exact end of a long application handoff.
        // Its independent coordinator already owns a deferred exact stop; never report that late
        // launch as an accepted generation while the stop is pending.
        if deferredStop.isPending {
            throw ProcessError.startCancelled
        }
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
        let exactRunnerIdentity = configuration.rendererReleaseIdentity.map {
            DoryLiveRunnerCodeIdentity(codeDirectoryHash: $0.runnerCodeDirectoryHash)
        }
        let child: SupervisedChild
        switch configuration.launchStyle {
        case .directExecutable:
            let childPID: pid_t
            do {
                childPID = try InheritedDescriptorSpawner.spawn(
                    executablePath: configuration.executablePath,
                    arguments: configuration.arguments,
                    environment: environment,
                    inheritParentEnvironment: inheritParentEnvironment,
                    startSuspended: exactRunnerIdentity != nil,
                    descriptorMappings: mappings,
                    standardInputDescriptor: standardInput,
                    standardOutputDescriptor: outputDescriptor,
                    standardErrorDescriptor: errorDescriptor
                )
            } catch {
                if let log { Darwin.close(log) }
                throw error
            }
            if let exactRunnerIdentity {
                do {
                    try launchGatedChildCodeValidator.validateLaunchGatedChild(
                        pid: childPID,
                        expectedIdentity: exactRunnerIdentity
                    )
                } catch {
                    killAndReapUnpublishedChild(childPID)
                    if let log { Darwin.close(log) }
                    throw terminalIdentityLaunchError(error)
                }
                if let resumeError = Self.sendSignal(SIGCONT, to: childPID) {
                    killAndReapUnpublishedChild(childPID)
                    if let log { Darwin.close(log) }
                    restartsEnabled = false
                    restartPending = false
                    if unpublishedChildRetirement == nil {
                        closeInheritedDescriptors()
                    }
                    let wrapped = ProcessError.rendererRunnerResumeFailed(resumeError)
                    lastLaunchError = wrapped.description
                    throw wrapped
                }
            }
            child = SupervisedChild(pid: childPID)

        case .applicationBundle:
            let handoff: DoryApplicationLaunchHandoffServer
            let bundle: DoryRunnerApplicationBundle
            do {
                bundle = try DoryRunnerApplicationBundle(
                    executablePath: configuration.executablePath
                )
                handoff = try DoryApplicationLaunchHandoffServer()
            } catch {
                if let log { Darwin.close(log) }
                throw ProcessError.applicationRunnerLaunchFailed("\(error)")
            }
            defer { handoff.cleanup() }
            let expectedIdentity: DoryLiveRunnerCodeIdentity
            switch bundle.kind {
            case .rawHVRunner:
                expectedIdentity = exactRunnerIdentity ?? bundle.kind.signedIdentity
            case .virtualizationVMM:
                guard exactRunnerIdentity == nil else {
                    if let log { Darwin.close(log) }
                    restartsEnabled = false
                    restartPending = false
                    closeInheritedDescriptors()
                    throw ProcessError.applicationRunnerLaunchFailed(
                        "renderer release identity cannot authorize DoryVMM"
                    )
                }
                expectedIdentity = bundle.kind.signedIdentity
            }
            let launchArguments = configuration.arguments + [
                DoryApplicationLaunchHandoffClient.socketArgument,
                handoff.path,
                DoryApplicationLaunchHandoffClient.tokenArgument,
                handoff.token,
            ]
            let launchEnvironment = inheritParentEnvironment
                ? ProcessInfo.processInfo.environment.merging(environment) { _, explicit in explicit }
                : environment
            let applicationLaunch: DoryWorkspaceApplicationLaunch
            do {
                applicationLaunch = try applicationLauncher.launch(
                    bundle: bundle,
                    arguments: launchArguments,
                    environment: launchEnvironment
                )
            } catch {
                if let log { Darwin.close(log) }
                throw ProcessError.applicationRunnerLaunchFailed("\(error)")
            }
            let childPID = applicationLaunch.processIdentifier
            let monitor: DoryApplicationProcessMonitor
            do {
                monitor = try DoryApplicationProcessMonitor(pid: childPID) {
                    applicationLaunch.isTerminated
                }
            } catch {
                _ = applicationLaunch.forceTerminate()
                beginTerminalRetirement(application: applicationLaunch)
                if let log { Darwin.close(log) }
                throw ProcessError.applicationRunnerLaunchFailed("\(error)")
            }
            var launchMappings = mappings
            launchMappings.append(InheritedDescriptorMapping(
                parentDescriptor: standardInput,
                childDescriptor: STDIN_FILENO
            ))
            launchMappings.append(InheritedDescriptorMapping(
                parentDescriptor: outputDescriptor,
                childDescriptor: STDOUT_FILENO
            ))
            launchMappings.append(InheritedDescriptorMapping(
                parentDescriptor: errorDescriptor,
                childDescriptor: STDERR_FILENO
            ))
            var identityFailure: Error?
            let applicationAuditToken: audit_token_t
            do {
                applicationAuditToken = try handoff.transfer(
                    toExpectedPID: childPID,
                    mappings: launchMappings
                ) {
                    do {
                        try launchGatedChildCodeValidator.validateLaunchGatedChild(
                            pid: childPID,
                            expectedIdentity: expectedIdentity
                        )
                    } catch {
                        identityFailure = error
                        throw error
                    }
                }
            } catch {
                _ = applicationLaunch.forceTerminate()
                if monitor.waitForTermination(
                    timeout: Self.applicationLaunchCleanupTimeoutSeconds
                ) == nil {
                    beginTerminalRetirement(application: applicationLaunch)
                }
                if let log { Darwin.close(log) }
                if let identityFailure {
                    throw terminalIdentityLaunchError(identityFailure)
                }
                restartsEnabled = false
                restartPending = false
                if terminalRetirement == nil {
                    closeInheritedDescriptors()
                }
                let wrapped = ProcessError.applicationRunnerLaunchFailed("\(error)")
                lastLaunchError = wrapped.description
                throw wrapped
            }
            child = SupervisedChild(
                pid: childPID,
                applicationMonitor: monitor,
                applicationLaunch: applicationLaunch,
                applicationAuditToken: applicationAuditToken
            )
        }

        // Do not publish the PID until the exact live code object has passed validation and the
        // same direct child was resumed or the same application acknowledged descriptor install.
        process = child
        logDescriptor = log
        postPublicationLifecycleGateForTesting?(child.pid)
        // The reaper intentionally retains this supervisor until the exact process is terminal.
        // A bounded stop may return while a kernel-stuck process is still alive; retaining `self`
        // preserves its descriptors and application identity without holding a daemon request lock.
        DispatchQueue.global(qos: .utility).async { [self, child] in
            let termination = Self.waitForTermination(of: child)
            handleTermination(child, termination: termination)
            child.terminationWaiter.leave()
        }
    }

    private func terminalIdentityLaunchError(_ error: Error) -> ProcessError {
        // Identity rejection is terminal for this supervised launch generation. In particular,
        // a startup restart must not turn a rejected live image into a path-based retry loop.
        restartsEnabled = false
        restartPending = false
        if terminalRetirement == nil, unpublishedChildRetirement == nil {
            closeInheritedDescriptors()
        }
        let wrapped = ProcessError.rendererRunnerIdentityRejected("\(error)")
        lastLaunchError = wrapped.description
        return wrapped
    }

    /// Called only while `lock` is already held by launchLocked(). The retirement callback retains
    /// this supervisor until exact terminal observation, then releases its launch-failure authority.
    private func beginTerminalRetirement(application: DoryWorkspaceApplicationLaunch) {
        terminalRetirement = DoryApplicationTerminalRetirement.begin(
            application: application
        ) { [self] in
            lock.lock()
            terminalRetirement = nil
            lock.unlock()
            closeInheritedDescriptors()
        }
    }

    private static func sendSignal(_ signal: Int32, to pid: pid_t) -> Int32? {
        signalErrorWithBoundedRetries {
            let result = kill(pid, signal)
            return (result == 0, result == 0 ? 0 : errno)
        }
    }

    static func signalErrorWithBoundedRetries(
        operation: () -> (succeeded: Bool, error: Int32)
    ) -> Int32? {
        for attempt in 1...8 {
            let outcome = operation()
            if outcome.succeeded { return nil }
            if outcome.error != EINTR || attempt == 8 { return outcome.error }
        }
        return EINTR
    }

    /// Exact cleanup for a child that has not entered supervised state. The synchronous launch
    /// path is hard-bounded; if SIGKILL cannot be reaped promptly, an exact retained retirement
    /// owns the PID and inherited descriptors until background terminal observation.
    private func killAndReapUnpublishedChild(_ pid: pid_t) {
        _ = Self.sendSignal(SIGKILL, to: pid)
        let reaped = Self.waitForUnpublishedChildTermination(
            pid: pid,
            timeout: Self.unpublishedChildCleanupTimeoutSeconds
        )
        guard !reaped else { return }
        unpublishedChildRetirement = UnpublishedChildTerminalRetirement.begin(
            pid: pid
        ) { [self] in
            lock.lock()
            unpublishedChildRetirement = nil
            lock.unlock()
            closeInheritedDescriptors()
        }
    }

    static func observeUnpublishedChild(
        pid: pid_t,
        wait: () -> (result: pid_t, error: Int32)
    ) -> UnpublishedChildWaitObservation {
        for attempt in 1...maximumInterruptedWaitAttempts {
            let outcome = wait()
            if outcome.result == pid { return .reaped }
            if outcome.result == 0 { return .running }
            if outcome.result < 0, outcome.error == ECHILD { return .reaped }
            if outcome.result < 0,
               outcome.error == EINTR,
               attempt < maximumInterruptedWaitAttempts {
                continue
            }
            return .failed(outcome.error == 0 ? EIO : outcome.error)
        }
        return .failed(EINTR)
    }

    static func waitForUnpublishedChildTermination(
        pid: pid_t,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.005,
        monotonicNow: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        wait: ((pid_t) -> UnpublishedChildWaitObservation)? = nil
    ) -> Bool {
        let started = monotonicNow()
        let timeoutNanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
        let deadline = started.addingReportingOverflow(timeoutNanoseconds)
        let deadlineNanoseconds = deadline.overflow ? UInt64.max : deadline.partialValue
        while true {
            let observation: UnpublishedChildWaitObservation
            if let wait {
                observation = wait(pid)
            } else {
                var status: Int32 = 0
                observation = observeUnpublishedChild(pid: pid) {
                    let result = waitpid(pid, &status, WNOHANG)
                    return (result, result < 0 ? errno : 0)
                }
            }
            switch observation {
            case .reaped:
                return true
            case .running, .failed:
                guard monotonicNow() < deadlineNanoseconds else { return false }
                pause(max(0.001, pollInterval))
            }
        }
    }

    private func validateDescriptorEnvelope(mappings: [InheritedDescriptorMapping]) throws {
        let dockerDiskIndex = try validatedDockerDataDiskDescriptorIndex(mappings: mappings)
        guard let envelope = configuration.runtimeLaunchEnvelope else {
            guard mappings.count == (dockerDiskIndex == nil ? 0 : 1) else {
                throw ProcessError.descriptorEnvelopeMismatch
            }
            return
        }
        let slots = envelope.inheritedFileDescriptors
        let envelopeAuthorities = configuration.inheritedFileDescriptors.enumerated().compactMap {
            index, authority in
            index == dockerDiskIndex ? nil : authority
        }
        guard slots.count == envelopeAuthorities.count,
              zip(slots, envelopeAuthorities).allSatisfy({ slot, authority in
                  slot.name == authority.name && slot.descriptor == authority.childDescriptor
              }) else {
            throw ProcessError.descriptorEnvelopeMismatch
        }
        _ = try envelope.validatedResolvedRawHVResources()
    }

    /// The Docker engine disk is a daemon-admitted supplemental resource, not part of the signed
    /// renderer payload envelope. It is accepted only at one fixed child slot with one canonical
    /// UUID argument; every partial, duplicated, renamed, or argument-shadowed shape fails closed.
    private func validatedDockerDataDiskDescriptorIndex(
        mappings: [InheritedDescriptorMapping]
    ) throws -> Int? {
        let name = DockerDataDiskLaunchContract.authorityName
        let childDescriptor = DockerDataDiskLaunchContract.childFileDescriptor
        let descriptorFlag = DockerDataDiskLaunchContract.fileDescriptorArgument
        let uuidFlag = DockerDataDiskLaunchContract.filesystemUUIDArgument
        let candidates = configuration.inheritedFileDescriptors.indices.filter { index in
            let authority = configuration.inheritedFileDescriptors[index]
            return authority.name == name || authority.childDescriptor == childDescriptor
        }
        let hasDiskArgument = configuration.arguments.contains { argument in
            argument == descriptorFlag
                || argument.hasPrefix(descriptorFlag + "=")
                || argument == uuidFlag
                || argument.hasPrefix(uuidFlag + "=")
        }
        guard !candidates.isEmpty || hasDiskArgument else { return nil }
        guard candidates.count == 1,
              let index = candidates.first,
              mappings.indices.contains(index) else {
            throw ProcessError.descriptorEnvelopeMismatch
        }
        let authority = configuration.inheritedFileDescriptors[index]
        guard authority.name == name,
              authority.childDescriptor == childDescriptor,
              mappings[index].childDescriptor == childDescriptor else {
            throw ProcessError.descriptorEnvelopeMismatch
        }

        func exactArgumentValue(_ flag: String) throws -> String {
            guard !configuration.arguments.contains(where: { $0.hasPrefix(flag + "=") }) else {
                throw ProcessError.descriptorEnvelopeMismatch
            }
            let indices = configuration.arguments.indices.filter {
                configuration.arguments[$0] == flag
            }
            guard indices.count == 1,
                  let index = indices.first,
                  configuration.arguments.indices.contains(index + 1) else {
                throw ProcessError.descriptorEnvelopeMismatch
            }
            return configuration.arguments[index + 1]
        }

        let descriptorValue = try exactArgumentValue(descriptorFlag)
        let uuidValue = try exactArgumentValue(uuidFlag)
        guard descriptorValue == String(childDescriptor),
              let uuid = UUID(uuidString: uuidValue),
              uuidValue == uuid.uuidString.lowercased() else {
            throw ProcessError.descriptorEnvelopeMismatch
        }
        return index
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
        if let applicationMonitor = child.applicationMonitor {
            let termination = applicationMonitor.waitForTermination()
            child.markTerminationObserved()
            return termination
        }
        var terminalInfo = siginfo_t()
        let terminalObservation = waitForDirectChildTerminalObservation(
            waitidOperation: {
                let result = waitid(
                    P_PID,
                    id_t(child.pid),
                    &terminalInfo,
                    WEXITED | WNOWAIT
                )
                return (
                    result,
                    result < 0 ? errno : 0,
                    terminalInfo.si_code
                )
            },
            consumeNonterminalObservation: {
                // Darwin can surface a pending stop/continue notification here even when only
                // WEXITED was requested. Consume that state change without ever marking it as an
                // exit; bounded EINTR attempts fall back to the outer retained retry.
                var stateChange: Int32 = 0
                for attempt in 1...maximumInterruptedWaitAttempts {
                    let result = waitpid(
                        child.pid,
                        &stateChange,
                        WUNTRACED | WCONTINUED
                    )
                    if result >= 0 { return }
                    if errno != EINTR || attempt == maximumInterruptedWaitAttempts {
                        return
                    }
                }
            }
        )
        if terminalObservation == .noChild {
            child.markTerminationObserved()
            return HvProcessTermination(
                status: ECHILD,
                wasUncaughtSignal: false,
                statusIsKnown: false
            )
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
            if result < 0, errno == ECHILD {
                return HvProcessTermination(
                    status: ECHILD,
                    wasUncaughtSignal: false,
                    statusIsKnown: false
                )
            }
            // Exit was proven by waitid(WNOWAIT), but keep the exact child/reaper authority until
            // the zombie is actually consumed. Persistent waitpid errors must not publish a
            // terminal manager state or spin a utility thread hot.
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    static func waitForDirectChildTerminalObservation(
        retryDelay: TimeInterval = 0.01,
        waitidOperation: () -> (result: Int32, error: Int32, code: Int32),
        consumeNonterminalObservation: () -> Void,
        pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> DirectChildTerminalObservation {
        var interruptedAttempts = 0
        while true {
            let outcome = waitidOperation()
            if outcome.result == 0 {
                interruptedAttempts = 0
                if [CLD_EXITED, CLD_KILLED, CLD_DUMPED].contains(outcome.code) {
                    return .exited
                }
                consumeNonterminalObservation()
                pause(max(0.001, retryDelay))
                continue
            }
            let code = outcome.error == 0 ? EIO : outcome.error
            if code == ECHILD { return .noChild }
            if code == EINTR {
                interruptedAttempts += 1
                if interruptedAttempts >= maximumInterruptedWaitAttempts {
                    interruptedAttempts = 0
                    pause(max(0.001, retryDelay))
                }
                continue
            }
            interruptedAttempts = 0
            pause(max(0.001, retryDelay))
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
        lastTerminationStatus = termination.statusIsKnown ? termination.status : nil
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
            let retainsTerminalAuthority = terminalRetirement != nil
                || unpublishedChildRetirement != nil
            lock.unlock()
            if shouldRetry {
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.restartAfterUnexpectedExit()
                }
            } else if !retainsTerminalAuthority {
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

    private struct StopClaim {
        let child: SupervisedChild?
        let retirement: DoryApplicationTerminalRetirement?
        let unpublishedRetirement: UnpublishedChildTerminalRetirement?
        let terminationWaiter: DispatchGroup?
        let oldLog: Int32?
        let wasSuspended: Bool
    }

    /// Must be called with `lock` held. Claiming is deliberately small; all process signalling,
    /// terminal waits, descriptor closes, and application retirement waits happen after unlock.
    private func claimStopLocked() -> StopClaim {
        stopping = true
        restartsEnabled = false
        restartPending = false
        let child = process
        let claim = StopClaim(
            child: child,
            retirement: terminalRetirement,
            unpublishedRetirement: unpublishedChildRetirement,
            terminationWaiter: child?.terminationWaiter,
            oldLog: logDescriptor,
            wasSuspended: suspended
        )
        // Take-and-null the handle so exactly one of stop()/handleTermination closes it; a double
        // close could otherwise land on a recycled descriptor.
        logDescriptor = nil
        suspended = false
        return claim
    }

    private func completeStop(
        _ claim: StopClaim,
        signal: Int32,
        deadline: DoryProcessStopDeadline
    ) -> Bool {
        guard let child = claim.child else {
            let retired: Bool
            if let retirement = claim.retirement {
                retired = retirement.waitForTermination(
                    timeout: Self.remainingTime(until: deadline.final)
                )
            } else if let retirement = claim.unpublishedRetirement {
                retired = retirement.waitForTermination(
                    timeout: Self.remainingTime(until: deadline.final)
                )
            } else {
                retired = true
            }
            if let oldLog = claim.oldLog { Darwin.close(oldLog) }
            if retired { closeInheritedDescriptors() }
            return retired
        }

        if claim.wasSuspended {
            _ = child.send(SIGCONT)
        }
        // Direct children are PID-reserved by WNOWAIT. LaunchServices helpers are signalled by
        // immutable audit token, so launchd reaping and PID reuse cannot redirect this request.
        _ = child.send(signal)

        // Wait for the exact child's termination handler so a replacement cannot reuse VM disks
        // or inherited authority early. If the forced phase cannot finish, the strongly retained
        // background reaper keeps every authority until terminal observation.
        let terminated = Self.waitForTermination(
            waiter: claim.terminationWaiter,
            deadline: deadline,
            sendForcedTermination: { _ = child.send(SIGKILL) }
        )

        if let oldLog = claim.oldLog { Darwin.close(oldLog) }
        if terminated { closeInheritedDescriptors() }
        return terminated
    }

    private func scheduleDeferredStop(
        signal: Int32,
        gracefulTimeout: TimeInterval,
        forcedTimeout: TimeInterval
    ) {
        deferredStop.schedule(
            signal: signal,
            gracefulTimeout: gracefulTimeout,
            forcedTimeout: forcedTimeout
        ) { [self] signal, gracefulTimeout, forcedTimeout in
            // This utility worker is the retained authority after the public deadline. It may wait
            // for a launch handoff's mutex, but no daemon request, tier lock, or XPC reply waits here.
            lock.lock()
            let claim = claimStopLocked()
            lock.unlock()
            _ = completeStop(
                claim,
                signal: signal,
                deadline: DoryProcessStopDeadline(
                    gracefulTimeout: gracefulTimeout,
                    forcedTimeout: forcedTimeout
                )
            )
        }
    }

    @discardableResult
    public func stop(signal: Int32 = SIGTERM, timeout: TimeInterval = 5) -> Bool {
        stop(
            signal: signal,
            timeout: timeout,
            forcedTimeout: Self.forcedTerminationGraceSeconds
        )
    }

    /// Internal timing seam for adversarial tests. Production uses the fixed forced grace above.
    @discardableResult
    func stopForTesting(
        signal: Int32 = SIGTERM,
        timeout: TimeInterval,
        forcedTimeout: TimeInterval
    ) -> Bool {
        stop(signal: signal, timeout: timeout, forcedTimeout: forcedTimeout)
    }

    private func stop(
        signal: Int32,
        timeout: TimeInterval,
        forcedTimeout: TimeInterval
    ) -> Bool {
        let deadline = DoryProcessStopDeadline(
            gracefulTimeout: timeout,
            forcedTimeout: forcedTimeout
        )
        guard lock.lock(until: deadline.final) else {
            scheduleDeferredStop(
                signal: signal,
                gracefulTimeout: timeout,
                forcedTimeout: forcedTimeout
            )
            return false
        }
        if deferredStop.isPending {
            lock.unlock()
            guard deferredStop.wait(until: deadline.final),
                  let observation = lifecycleObservation(until: deadline.final) else {
                return false
            }
            return !observation.isRunning
        }
        let claim = claimStopLocked()
        lock.unlock()
        return completeStop(claim, signal: signal, deadline: deadline)
    }

    /// Waits for the exact retained helper generation without creating a fresh termination or
    /// signaling authority. The caller's monotonic budget includes lifecycle-lock acquisition.
    public func waitForTermination(timeout: TimeInterval) -> Bool {
        let deadline = DoryProcessStopDeadline(
            gracefulTimeout: timeout,
            forcedTimeout: 0
        )
        guard lock.lock(until: deadline.final) else { return false }
        let waiter = process?.terminationWaiter
        let retirement = terminalRetirement
        let unpublishedRetirement = unpublishedChildRetirement
        let deferredPending = deferredStop.isPending
        lock.unlock()
        if let waiter {
            guard waiter.wait(timeout: deadline.final) == .success else { return false }
        } else if let retirement {
            guard retirement.waitForTermination(
                timeout: Self.remainingTime(until: deadline.final)
            ) else { return false }
        } else if let unpublishedRetirement {
            guard unpublishedRetirement.waitForTermination(
                timeout: Self.remainingTime(until: deadline.final)
            ) else { return false }
        }
        if deferredPending,
           !deferredStop.wait(until: deadline.final) {
            return false
        }
        return lifecycleObservation(until: deadline.final)?.isRunning == false
    }

    static func waitForTermination(
        waiter: DispatchGroup?,
        gracefulTimeout: TimeInterval,
        forcedTimeout: TimeInterval,
        sendForcedTermination: () -> Void
    ) -> Bool {
        waitForTermination(
            waiter: waiter,
            deadline: DoryProcessStopDeadline(
                gracefulTimeout: gracefulTimeout,
                forcedTimeout: forcedTimeout
            ),
            sendForcedTermination: sendForcedTermination
        )
    }

    static func waitForTermination(
        waiter: DispatchGroup?,
        deadline: DoryProcessStopDeadline,
        waitUntil: ((DispatchTime) -> DispatchTimeoutResult)? = nil,
        sendForcedTermination: () -> Void
    ) -> Bool {
        guard let waiter else { return true }
        let boundedWait = waitUntil ?? { waiter.wait(timeout: $0) }
        if boundedWait(deadline.graceful) == .success {
            return true
        }
        sendForcedTermination()
        return boundedWait(deadline.final) == .success
    }

    private static func remainingTime(until deadline: DispatchTime) -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline.uptimeNanoseconds > now else { return 0 }
        return Double(deadline.uptimeNanoseconds - now) / 1_000_000_000
    }

    /// Used only from a background retirement task after a bounded public stop returned false.
    /// This is deliberately not called under a daemon request or workspace mutation lock.
    func waitUntilTerminated() {
        while true {
            lock.lock()
            let waiter = process?.terminationWaiter
            let retirement = terminalRetirement
            let unpublishedRetirement = unpublishedChildRetirement
            lock.unlock()
            if let waiter {
                waiter.wait()
                continue
            }
            if let retirement {
                retirement.waitForTermination()
                continue
            }
            if let unpublishedRetirement {
                unpublishedRetirement.waitForTermination()
                continue
            }
            return
        }
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
