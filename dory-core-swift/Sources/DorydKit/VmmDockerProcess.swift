import Darwin
import DoryOperations
import Foundation

public struct VmmDockerProcessConfiguration: Sendable {
    /// The Docker data disk is always inherited into the VMM helper at one non-ambient slot.
    /// Keeping the slot fixed lets the child reject an argument that attempts to redirect its
    /// storage attachment to some unrelated descriptor inherited from its launch environment.
    public static let dockerDataDiskChildDescriptor: Int32 =
        DockerDataDiskLaunchContract.childFileDescriptor

    public var executablePath: String
    public var arguments: [String]
    public var stateDirectory: String
    public var handoffSocketPath: String
    public var logPath: String?
    public var readyTimeoutSeconds: TimeInterval
    public var restartPolicy: HvRestartPolicy
    public var inheritedDockerDataDisk: HvProcessInheritedFileDescriptor?
    public var dockerDataDiskFilesystemUUID: UUID?

    public init(
        executablePath: String,
        arguments: [String],
        stateDirectory: String,
        handoffSocketPath: String,
        logPath: String? = nil,
        readyTimeoutSeconds: TimeInterval = 90,
        restartPolicy: HvRestartPolicy = HvRestartPolicy(maxRestarts: 3, delaySeconds: 0.5),
        inheritedDockerDataDisk: HvProcessInheritedFileDescriptor? = nil,
        dockerDataDiskFilesystemUUID: UUID? = nil
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.stateDirectory = stateDirectory
        self.handoffSocketPath = handoffSocketPath
        self.logPath = logPath
        self.readyTimeoutSeconds = readyTimeoutSeconds
        self.restartPolicy = restartPolicy
        self.inheritedDockerDataDisk = inheritedDockerDataDisk
        self.dockerDataDiskFilesystemUUID = dockerDataDiskFilesystemUUID
    }
}

/// Retains the kernel identity of one direct child until terminal observation and reap complete.
/// `waitid(WNOWAIT)` prevents PID reuse before `markTerminationObserved`, while the lifecycle
/// mutex serializes that observation with every signal decision.
final class VmmSupervisedChild: @unchecked Sendable {
    typealias SignalOperation = @Sendable (pid_t, Int32) -> Bool

    let pid: pid_t
    let terminationWaiter = DispatchGroup()
    private let lifecycleLock = DoryProcessLifecycleMutex()
    private let signalOperation: SignalOperation
    private var terminationObserved = false

    init(
        pid: pid_t,
        signalOperation: @escaping SignalOperation = VmmSupervisedChild.sendSystemSignal
    ) {
        self.pid = pid
        self.signalOperation = signalOperation
        terminationWaiter.enter()
    }

    var isTerminationObserved: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return terminationObserved
    }

    @discardableResult
    func send(_ signal: Int32) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !terminationObserved else { return false }
        return signalOperation(pid, signal)
    }

    /// Internal for deterministic authority tests; production calls it only after waitid has
    /// proven terminal state while the direct-child PID remains reserved as an unreaped zombie.
    func markTerminationObserved() {
        lifecycleLock.lock()
        terminationObserved = true
        lifecycleLock.unlock()
    }

    func beginMonitoring(
        onTermination: @escaping @Sendable (HvProcessTermination) -> Void
    ) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let termination = Self.waitForTermination(pid: pid) {
                markTerminationObserved()
            }
            onTermination(termination)
            terminationWaiter.leave()
        }
    }

    private static func waitForTermination(
        pid: pid_t,
        markTerminationObserved: () -> Void
    ) -> HvProcessTermination {
        var terminalInfo = siginfo_t()
        let observation = HvProcess.waitForDirectChildTerminalObservation(
            waitidOperation: {
                let result = waitid(P_PID, id_t(pid), &terminalInfo, WEXITED | WNOWAIT)
                return (result, result < 0 ? errno : 0, terminalInfo.si_code)
            },
            consumeNonterminalObservation: {
                var stateChange: Int32 = 0
                for attempt in 1...HvProcess.maximumInterruptedWaitAttempts {
                    let result = waitpid(pid, &stateChange, WUNTRACED | WCONTINUED)
                    if result >= 0 { return }
                    if errno != EINTR || attempt == HvProcess.maximumInterruptedWaitAttempts {
                        return
                    }
                }
            }
        )
        markTerminationObserved()
        guard observation == .exited else {
            return HvProcessTermination(
                status: ECHILD,
                wasUncaughtSignal: false,
                statusIsKnown: false
            )
        }

        var rawStatus: Int32 = 0
        while true {
            let result = waitpid(pid, &rawStatus, 0)
            if result == pid {
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
            // Terminal state is already published to the exact target, so signals fail closed.
            // Keep retrying the reap off-request without spinning if Darwin reports a transient
            // non-EINTR failure.
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private static func sendSystemSignal(_ pid: pid_t, _ signal: Int32) -> Bool {
        for attempt in 1...HvProcess.maximumInterruptedWaitAttempts {
            if kill(pid, signal) == 0 { return true }
            if errno != EINTR || attempt == HvProcess.maximumInterruptedWaitAttempts {
                return false
            }
        }
        return false
    }
}

public final class VmmDockerProcess: @unchecked Sendable {
    static let forcedTerminationGraceSeconds: TimeInterval = 2

    public enum ProcessError: Error, CustomStringConvertible {
        case alreadyRunning
        case executableMissing(String)
        case startCancelled
        case handoffTimeout
        case handoffFailed(String)
        case invalidDockerDataDiskContract(String)
        case conflictingDockerDataDiskArgument(String)

        public var description: String {
            switch self {
            case .alreadyRunning:
                return "dory-vmm docker helper is already running"
            case .executableMissing(let path):
                return "dory-vmm executable missing: \(path)"
            case .startCancelled:
                return "dory-vmm docker helper start was cancelled"
            case .handoffTimeout:
                return "dory-vmm docker helper did not become ready before timeout"
            case .handoffFailed(let message):
                return "dory-vmm docker handoff failed: \(message)"
            case .invalidDockerDataDiskContract(let message):
                return "invalid dory-vmm Docker data-disk descriptor contract: \(message)"
            case .conflictingDockerDataDiskArgument(let flag):
                return "dory-vmm Docker data-disk argument is supervisor-owned: \(flag)"
            }
        }
    }

    private let configuration: VmmDockerProcessConfiguration
    private let unexpectedTerminationHandler: HvProcessUnexpectedTerminationHandler?
    private let lock = DoryProcessLifecycleMutex()
    private let deferredStop = DoryDeferredProcessStopCoordinator(
        label: "dev.dory.vmm-docker-process.deferred-stop"
    )
    private var process: VmmSupervisedChild?
    private var handoffServer: VmmHandoffServer?
    private var handoffWaiter: DispatchSemaphore?
    private var logHandle: FileHandle?
    private var suspended = false
    private var starting = false
    private var stopping = false
    private var hasStarted = false
    private var lastReady: VmmReadyMessage?
    private var postDescriptorDuplicationGateForTesting: (@Sendable () -> Void)?
    private var postPublicationLifecycleGateForTesting: (@Sendable (Int32) -> Void)?

    public init(
        configuration: VmmDockerProcessConfiguration,
        unexpectedTerminationHandler: HvProcessUnexpectedTerminationHandler? = nil
    ) {
        self.configuration = configuration
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
        // Retain/publish the generation until its exact direct child is reaped and the termination
        // callback has cleared it. A zombie in the narrow callback window is still owned authority.
        return process != nil || starting || deferredStop.isPending
    }

    func lifecycleObservation(
        until deadline: DispatchTime
    ) -> DockerManagedProcessObservation? {
        guard lock.lock(until: deadline) else { return nil }
        let observation = DockerManagedProcessObservation(
            pid: process?.pid,
            isRunning: process != nil || starting || deferredStop.isPending
        )
        lock.unlock()
        return observation
    }

    public var readyMessage: VmmReadyMessage? {
        lock.lock()
        defer { lock.unlock() }
        return lastReady
    }

    /// Internal deterministic race seam. The callback runs with the lifecycle reservation held
    /// after the exact child is published and before startup waits for handoff.
    func installPostPublicationLifecycleGateForTesting(
        _ gate: @escaping @Sendable (Int32) -> Void
    ) {
        lock.lock()
        precondition(!hasStarted && process == nil)
        postPublicationLifecycleGateForTesting = gate
        lock.unlock()
    }

    /// Internal deterministic race seam. The callback runs after the launch owns a private
    /// duplicate of the disk authority and before the spawner consumes that duplicate.
    func installPostDescriptorDuplicationGateForTesting(
        _ gate: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        precondition(!hasStarted && process == nil)
        postDescriptorDuplicationGateForTesting = gate
        lock.unlock()
    }

    public func start() throws {
        lock.lock()
        // Hold the reservation under the lock across check + spawn so two concurrent starts
        // can't both bind the handoff socket and double-launch the helper.
        if process != nil || starting {
            lock.unlock()
            throw ProcessError.alreadyRunning
        }
        // Preserve a stop that won the race before this first start. Clearing it here would let
        // the VMM spawn after DockerTier.stop() had already completed, recreating the launchd
        // orphan window this class is responsible for closing.
        if stopping, !hasStarted {
            lock.unlock()
            throw ProcessError.startCancelled
        }
        if deferredStop.isPending {
            lock.unlock()
            throw ProcessError.startCancelled
        }
        hasStarted = true
        starting = true
        stopping = false
        lock.unlock()

        do {
            try launch()
        } catch {
            lock.lock()
            starting = false
            lock.unlock()
            throw error
        }
        lock.lock()
        guard !stopping, !deferredStop.isPending, process != nil else {
            starting = false
            lock.unlock()
            throw ProcessError.startCancelled
        }
        starting = false
        lock.unlock()
    }

    private func launch() throws {
        let descriptorContract = try dockerDataDiskDescriptorContract()
        defer {
            for descriptor in descriptorContract.ownedParentDescriptors {
                Darwin.close(descriptor)
            }
        }
        postDescriptorDuplicationGateForTesting?()
        guard FileManager.default.isExecutableFile(atPath: configuration.executablePath) else {
            throw ProcessError.executableMissing(configuration.executablePath)
        }
        try FileManager.default.createDirectory(atPath: configuration.stateDirectory, withIntermediateDirectories: true)
        let standardInput = open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard standardInput >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(standardInput) }

        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedResultBox<VmmHandoff>()
        let server = VmmHandoffServer(path: configuration.handoffSocketPath) { handoff in
            result.set(handoff)
            semaphore.signal()
        }
        try server.start()

        lock.lock()
        guard starting, !stopping else {
            lock.unlock()
            server.stop()
            throw ProcessError.startCancelled
        }
        handoffServer = server
        handoffWaiter = semaphore
        lock.unlock()

        let log = Self.openAppendLog(configuration.logPath)
        let outputDescriptor = log?.fileDescriptor ?? FileHandle.standardError.fileDescriptor

        // Spawn and publish under one lifecycle reservation. The retained direct-child target owns
        // waitid(WNOWAIT) reaping, so Foundation cannot reap the PID between an isRunning probe and
        // a suspend/resume/termination signal.
        lock.lock()
        guard starting, !stopping else {
            if handoffServer === server {
                handoffServer = nil
            }
            if handoffWaiter === semaphore {
                handoffWaiter = nil
            }
            lock.unlock()
            server.stop()
            try? log?.close()
            throw ProcessError.startCancelled
        }
        logHandle = log
        let childPID: pid_t
        do {
            childPID = try InheritedDescriptorSpawner.spawn(
                executablePath: configuration.executablePath,
                arguments: descriptorContract.arguments,
                descriptorMappings: descriptorContract.mappings,
                standardInputDescriptor: standardInput,
                standardOutputDescriptor: outputDescriptor,
                standardErrorDescriptor: outputDescriptor
            )
        } catch {
            if handoffServer === server {
                handoffServer = nil
            }
            if handoffWaiter === semaphore {
                handoffWaiter = nil
            }
            logHandle = nil
            lock.unlock()
            server.stop()
            try? log?.close()
            throw error
        }
        let child = VmmSupervisedChild(pid: childPID)
        process = child
        suspended = false
        postPublicationLifecycleGateForTesting?(child.pid)
        lock.unlock()
        child.beginMonitoring { [weak self, child] termination in
            self?.handleTermination(child, termination: termination)
        }

        let timeoutMilliseconds = Int(configuration.readyTimeoutSeconds * 1000)
        let deadline = DispatchTime.now() + .milliseconds(max(1, timeoutMilliseconds))
        let waitResult = semaphore.wait(timeout: deadline)
        lock.lock()
        if handoffWaiter === semaphore {
            handoffWaiter = nil
        }
        let startWasCancelled = stopping || !starting
        lock.unlock()
        guard !startWasCancelled else {
            server.stop()
            throw ProcessError.startCancelled
        }
        guard waitResult == .success else {
            stop(signal: SIGTERM, timeout: 5)
            throw ProcessError.handoffTimeout
        }
        switch result.value {
        case .success(let handoff)?:
            lock.lock()
            guard !stopping,
                  starting,
                  process === child,
                  !child.isTerminationObserved else {
                lastReady = nil
                let cancelled = stopping || !starting
                lock.unlock()
                if cancelled {
                    throw ProcessError.startCancelled
                }
                throw ProcessError.handoffFailed("helper exited immediately after handoff")
            }
            lastReady = handoff.ready
            lock.unlock()
            return
        case .failure(let error)?:
            stop(signal: SIGTERM, timeout: 5)
            throw ProcessError.handoffFailed("\(error)")
        case nil:
            stop(signal: SIGTERM, timeout: 5)
            throw ProcessError.handoffTimeout
        }
    }

    private func handleTermination(
        _ child: VmmSupervisedChild,
        termination: HvProcessTermination
    ) {
        let oldLog: FileHandle?
        let server: VmmHandoffServer?
        let waiter: DispatchSemaphore?
        let wasUnexpected: Bool
        lock.lock()
        guard process === child else {
            lock.unlock()
            return
        }
        process = nil
        suspended = false
        oldLog = logHandle
        logHandle = nil
        server = handoffServer
        handoffServer = nil
        waiter = handoffWaiter
        handoffWaiter = nil
        lastReady = nil
        wasUnexpected = !stopping
        lock.unlock()
        server?.stop()
        waiter?.signal()
        try? oldLog?.close()
        configuration.inheritedDockerDataDisk?.close()
        if wasUnexpected {
            unexpectedTerminationHandler?(termination)
        }
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
        let child: VmmSupervisedChild?
        let server: VmmHandoffServer?
        let log: FileHandle?
        let wasSuspended: Bool
        let handoffWaiter: DispatchSemaphore?
    }

    /// Must be called with `lock` held. External server shutdown, descriptor close, signalling, and
    /// exact child waits all occur after the claim releases the supervisor mutex.
    private func claimStopLocked() -> StopClaim {
        stopping = true
        let claim = StopClaim(
            child: process,
            server: handoffServer,
            log: logHandle,
            wasSuspended: suspended,
            handoffWaiter: handoffWaiter
        )
        handoffServer = nil
        handoffWaiter = nil
        logHandle = nil
        suspended = false
        lastReady = nil
        return claim
    }

    private func completeStop(
        _ claim: StopClaim,
        signal: Int32,
        deadline: DoryProcessStopDeadline
    ) -> Bool {
        claim.server?.stop()
        claim.handoffWaiter?.signal()
        defer { try? claim.log?.close() }
        guard let child = claim.child else {
            configuration.inheritedDockerDataDisk?.close()
            return true
        }
        if claim.wasSuspended {
            _ = child.send(SIGCONT)
        }
        _ = child.send(signal)
        return HvProcess.waitForTermination(
            waiter: child.terminationWaiter,
            deadline: deadline,
            sendForcedTermination: { _ = child.send(SIGKILL) }
        )
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

    public func waitForTermination(timeout: TimeInterval) -> Bool {
        let deadline = DoryProcessStopDeadline(
            gracefulTimeout: timeout,
            forcedTimeout: 0
        )
        guard lock.lock(until: deadline.final) else { return false }
        let waiter = process?.terminationWaiter
        let deferredPending = deferredStop.isPending
        lock.unlock()
        if let waiter,
           waiter.wait(timeout: deadline.final) != .success {
            return false
        }
        if deferredPending,
           !deferredStop.wait(until: deadline.final) {
            return false
        }
        return lifecycleObservation(until: deadline.final)?.isRunning == false
    }

    private static func openAppendLog(_ path: String?) -> FileHandle? {
        guard let path else { return nil }
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private func dockerDataDiskDescriptorContract() throws -> (
        arguments: [String],
        mappings: [InheritedDescriptorMapping],
        ownedParentDescriptors: [Int32]
    ) {
        let descriptorFlag = DockerDataDiskLaunchContract.fileDescriptorArgument
        let uuidFlag = DockerDataDiskLaunchContract.filesystemUUIDArgument
        for flag in [descriptorFlag, uuidFlag] {
            if configuration.arguments.contains(where: {
                $0 == flag || $0.hasPrefix(flag + "=")
            }) {
                throw ProcessError.conflictingDockerDataDiskArgument(flag)
            }
        }

        switch (
            configuration.inheritedDockerDataDisk,
            configuration.dockerDataDiskFilesystemUUID
        ) {
        case (nil, nil):
            return (configuration.arguments, [], [])
        case let (authority?, filesystemUUID?):
            let expectedDescriptor = VmmDockerProcessConfiguration
                .dockerDataDiskChildDescriptor
            guard authority.childDescriptor == expectedDescriptor else {
                throw ProcessError.invalidDockerDataDiskContract(
                    "expected child descriptor \(expectedDescriptor), got \(authority.childDescriptor)"
                )
            }
            let launchDescriptor = try authority.withBorrowedDescriptor { descriptor in
                let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
                guard duplicate >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                return duplicate
            }
            let mapping = InheritedDescriptorMapping(
                parentDescriptor: launchDescriptor,
                childDescriptor: expectedDescriptor
            )
            return (
                configuration.arguments + [
                    descriptorFlag, String(expectedDescriptor),
                    uuidFlag, filesystemUUID.uuidString.lowercased(),
                ],
                [mapping],
                [launchDescriptor]
            )
        case (nil, _?):
            throw ProcessError.invalidDockerDataDiskContract(
                "filesystem UUID was supplied without an inherited descriptor"
            )
        case (_?, nil):
            throw ProcessError.invalidDockerDataDiskContract(
                "inherited descriptor was supplied without a filesystem UUID"
            )
        }
    }

    deinit {
        stop()
    }
}

private final class LockedResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<T, Error>?

    var value: Result<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Result<T, Error>) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}
