import CryptoKit
import Darwin
import DoryCore
import Foundation

public enum DockerTierState: String, Sendable {
    case stopped
    case starting
    case running
    case sleeping
    case failed
}

public struct DockerTierStatus: Sendable {
    public var state: DockerTierState
    public var socketPath: String
    public var hvPID: Int32?
    public var lastError: String?
}

public struct DoryGuestResourceSnapshot: Sendable, Equatable {
    public var memoryCeilingBytes: UInt64
    public var memoryUsedBytes: UInt64
    public var memoryCacheBytes: UInt64
    public var memoryReclaimableBytes: UInt64
    public var memoryFreeBytes: UInt64
    public var dataDiskTotalBytes: UInt64
    public var dataDiskUsedBytes: UInt64
    public var dataDiskAvailableBytes: UInt64
}

public struct DoryHostShareResourceSnapshot: Codable, Sendable, Equatable {
    public struct Batcher: Codable, Sendable, Equatable {
        public var pendingCount: Int
        public var pendingLimit: Int
        public var pendingRequiresRescan: Bool
        public var receivedEventCount: UInt64
        public var deliveredBatchCount: UInt64
        public var failedBatchCount: UInt64
        public var rescanCollapseCount: UInt64
    }

    public var schema: String
    public var version: Int
    public var generatedAt: Date
    public var configuredRoots: [String]
    public var observationRoots: [String]
    public var running: Bool
    public var flushScheduled: Bool
    public var consecutiveFailures: Int
    public var batcher: Batcher
}

public struct DockerTierConfiguration: Sendable {
    public var home: String
    public var forwardSocketPath: String
    public var dockerdSocketPath: String?
    public var cid: UInt32
    public var dockerPort: UInt32
    public var gpuSupported: Bool
    public var activitySocketPath: String?
    public var hvProcess: HvProcessConfiguration?
    public var vmmProcess: VmmDockerProcessConfiguration?
    public var agentControl: AgentControlConfiguration?

    public init(
        home: String = NSHomeDirectory(),
        forwardSocketPath: String,
        dockerdSocketPath: String? = nil,
        cid: UInt32 = 3,
        dockerPort: UInt32 = 1026,
        gpuSupported: Bool = false,
        activitySocketPath: String? = nil,
        hvProcess: HvProcessConfiguration? = nil,
        vmmProcess: VmmDockerProcessConfiguration? = nil,
        agentControl: AgentControlConfiguration? = nil
    ) {
        self.home = home
        self.forwardSocketPath = forwardSocketPath
        self.dockerdSocketPath = dockerdSocketPath
        self.cid = cid
        self.dockerPort = dockerPort
        self.gpuSupported = gpuSupported
        self.activitySocketPath = activitySocketPath
        self.hvProcess = hvProcess
        self.vmmProcess = vmmProcess
        self.agentControl = agentControl
    }

    public var hasManagedHelper: Bool {
        hvProcess != nil || vmmProcess != nil
    }
}

public typealias DockerContainerActivityProbe = @Sendable (DockerTierConfiguration) -> DockerContainerActivity
public typealias DockerReadyWaiter = @Sendable (
    DockerTierConfiguration,
    TimeInterval,
    @escaping @Sendable () -> Bool
) -> Bool

private protocol DockerManagedProcess: AnyObject, Sendable {
    var pid: Int32? { get }
    var isRunning: Bool { get }
    func start() throws
    func suspend() -> Bool
    func resume() -> Bool
    func stop()
}

extension HvProcess: DockerManagedProcess {
    public func stop() {
        stop(signal: SIGTERM, timeout: DoryEngineShutdownTiming.hostTerminationSeconds)
    }
}

extension VmmDockerProcess: DockerManagedProcess {
    public func stop() {
        stop(signal: SIGTERM, timeout: DoryEngineShutdownTiming.hostTerminationSeconds)
    }
}

public final class DockerTier: @unchecked Sendable {
    public enum TierError: Error, CustomStringConvertible {
        case alreadyRunning
        case sleepingDataplaneRequiresWakeSupport
        case suspendFailed(pid: Int32?)
        case resumeFailed(pid: Int32?)
        case readyTimeout
        case helperExited(String)
        case promotionTimeout
        case startCancelled
        case daemonShuttingDown
        case wakeFailed(String)
        case repairUnavailable(String)
        case readinessStageFailed(stage: DoryReadinessStageID, detail: String)

        public var description: String {
            switch self {
            case .alreadyRunning:
                return "docker tier is already running"
            case .sleepingDataplaneRequiresWakeSupport:
                return "sleeping docker dataplane requires an idle controller, activity socket, and managed dory-hv process"
            case .suspendFailed(let pid):
                return "failed to suspend dory-hv\(pid.map { " pid \($0)" } ?? "")"
            case .resumeFailed(let pid):
                return "failed to resume dory-hv\(pid.map { " pid \($0)" } ?? "")"
            case .readyTimeout:
                return "docker tier did not become ready after wake"
            case .helperExited(let detail):
                return "docker tier helper \(detail)"
            case .promotionTimeout:
                return "docker tier did not reach running state before the promotion deadline"
            case .startCancelled:
                return "docker tier start was cancelled"
            case .daemonShuttingDown:
                return "docker tier cannot start while doryd is shutting down"
            case .wakeFailed(let message):
                return message.isEmpty ? "docker tier did not wake" : message
            case .repairUnavailable(let message):
                return message
            case let .readinessStageFailed(stage, detail):
                return "\(stage.title) readiness failed: \(detail)"
            }
        }
    }

    // A cold fresh-start boots the kernel, mounts the rootfs, initializes the docker data disk on
    // first use, and starts dockerd/containerd — legitimately tens of seconds. Too short a ready
    // window tears the engine down mid-boot; the next request restarts the cold boot, so an empty
    // engine never comes up (boot loop). Resume from a suspended helper is near-instant, so it keeps
    // a short window.
    private static let freshStartReadyTimeout: TimeInterval = 180
    private static let resumeReadyTimeout: TimeInterval = 10

    private let configuration: DockerTierConfiguration
    private let containerActivityProbe: DockerContainerActivityProbe
    private let dockerReadyWaiter: DockerReadyWaiter
    private let beforeDataplaneStart: @Sendable () -> Void
    private let socket: DorySocket
    private let idleController: IdleController?
    private let agentControl: AgentControl?
    private let portPublisher: PortPublisher?
    private let readinessTracker = EngineReadinessTracker()
    private let supervisorQueue = DispatchQueue(label: "dev.dory.doryd.docker-tier-supervisor")
    private let lock = NSLock()
    private var dataplane: DoryDataplaneHandle?
    private var activityServer: DataplaneActivityServer?
    private var helperProcess: (any DockerManagedProcess)?
    private var state: DockerTierState = .stopped
    private var lastError: String?
    private var wakeTask: Task<Void, Never>?
    private var activeHelperGeneration: UUID?
    private var helperStartedAt: Date?
    private var unexpectedRestartCount = 0
    private var lifecycleEpoch: UInt64 = 0
    private var restartWorkItem: DispatchWorkItem?
    private var terminalShutdown = false
    private var lifecycleStateObserver: @Sendable (DockerTierState) -> Void = { _ in }
    private var promotionWaiters: [UUID: DispatchSemaphore] = [:]

    public init(
        configuration: DockerTierConfiguration,
        idleController: IdleController? = nil,
        agentControl injectedAgentControl: AgentControl? = nil,
        portPublisher injectedPortPublisher: PortPublisher? = nil,
        containerActivityProbe: @escaping DockerContainerActivityProbe = { configuration in
            if let dockerdSocketPath = configuration.dockerdSocketPath {
                return DockerEngineProbe.containerActivity(socketPath: dockerdSocketPath)
            }
            return DockerEngineProbe.containerActivity(
                    forwardSocketPath: configuration.forwardSocketPath,
                    cid: configuration.cid,
                    dockerPort: configuration.dockerPort
                )
        },
        dockerReadyWaiter: @escaping DockerReadyWaiter = { configuration, timeout, shouldContinue in
            if let dockerdSocketPath = configuration.dockerdSocketPath {
                return DockerEngineProbe.waitUntilReady(
                    socketPath: dockerdSocketPath,
                    timeout: timeout,
                    shouldContinue: shouldContinue
                )
            }
            return DockerEngineProbe.waitUntilReady(
                forwardSocketPath: configuration.forwardSocketPath,
                cid: configuration.cid,
                dockerPort: configuration.dockerPort,
                timeout: timeout,
                shouldContinue: shouldContinue
            )
        },
        beforeDataplaneStart: @escaping @Sendable () -> Void = {}
    ) {
        self.configuration = configuration
        self.containerActivityProbe = containerActivityProbe
        self.dockerReadyWaiter = dockerReadyWaiter
        self.beforeDataplaneStart = beforeDataplaneStart
        self.idleController = idleController
        self.socket = DorySocket(home: configuration.home)
        if let injectedAgentControl {
            self.agentControl = injectedAgentControl
            self.portPublisher = injectedPortPublisher ?? PortPublisher()
        } else if let agentConfiguration = configuration.agentControl {
            self.agentControl = AgentControl(configuration: agentConfiguration)
            self.portPublisher = PortPublisher()
        } else {
            self.agentControl = nil
            self.portPublisher = nil
        }
        cleanupStaleHelpers()
    }

    /// Called in lifecycle order while the tier lock is held. The observer must not call back into
    /// DockerTier; doryd uses it only to persist the confirmed running/sleeping intent.
    public func setLifecycleStateObserver(
        _ observer: @escaping @Sendable (DockerTierState) -> Void
    ) {
        lock.lock()
        lifecycleStateObserver = observer
        lock.unlock()
    }

    public var socketPath: String {
        socket.path
    }

    public func status() -> DockerTierStatus {
        reconcileManagedHelperLiveness()
        lock.lock()
        defer { lock.unlock() }
        let helperPID = helperProcess?.pid
        let reportedState: DockerTierState
        let reportedError: String?
        if state == .running, configuration.hasManagedHelper, helperPID == nil {
            // A child can cross the exit boundary between the liveness reconciliation above and
            // this snapshot. Never publish a logically impossible `running` + no-child status.
            reportedState = .failed
            reportedError = lastError ?? "managed helper is no longer running"
        } else {
            reportedState = state
            reportedError = lastError
        }
        return DockerTierStatus(
            state: reportedState,
            socketPath: socket.path,
            hvPID: helperPID,
            lastError: reportedError
        )
    }

    public func readinessSnapshot(now: Date = Date()) -> DoryReadinessSnapshot {
        readinessTracker.snapshot(now: now)
    }

    /// Publish the Docker socket and activity listener without starting the heavy VM.
    ///
    /// This is doryd's lightweight launch shape: Docker clients can connect to `dory.sock`
    /// immediately, and the app or the first meaningful Docker request promotes it to a live helper.
    public func armSleeping() throws {
        idleController?.beginControlOperation()
        defer { idleController?.endControlOperation() }

        lock.lock()
        guard !terminalShutdown else {
            lock.unlock()
            throw TierError.daemonShuttingDown
        }
        if dataplane != nil {
            if state == .stopped {
                setStateLocked(.sleeping)
                idleController?.setSleeping(true)
            }
            lock.unlock()
            return
        }
        guard idleController != nil,
              configuration.activitySocketPath != nil,
              configuration.hasManagedHelper else {
            lock.unlock()
            throw TierError.sleepingDataplaneRequiresWakeSupport
        }
        restartWorkItem?.cancel()
        restartWorkItem = nil
        lifecycleEpoch &+= 1
        let armEpoch = lifecycleEpoch
        unexpectedRestartCount = 0
        activeHelperGeneration = nil
        helperStartedAt = nil
        setStateLocked(.starting)
        lastError = nil
        lock.unlock()

        do {
            let resources = try startDataplane()
            lock.lock()
            guard !terminalShutdown,
                  lifecycleEpoch == armEpoch,
                  state == .starting else {
                lock.unlock()
                resources.handle.shutdown()
                resources.activityServer?.stop()
                // Terminal shutdown forbids any newer lifecycle, so it is safe and necessary to
                // remove paths that this late dataplane bind may have recreated after tearDown.
                removeRuntimeSockets()
                throw TierError.startCancelled
            }
            dataplane = resources.handle
            activityServer = resources.activityServer
            helperProcess = nil
            setStateLocked(.sleeping)
            wakeTask = nil
            activeHelperGeneration = nil
            helperStartedAt = nil
            lastError = nil
            idleController?.setSleeping(true)
            lock.unlock()
            readinessTracker.markStopped(detail: "engine is idle-sleeping; host socket remains armed")
        } catch {
            lock.lock()
            let terminallyCancelled = terminalShutdown
            let ownsLifecycle = !terminallyCancelled
                && lifecycleEpoch == armEpoch
                && state == .starting
            if ownsLifecycle {
                setStateLocked(.failed)
                lastError = "\(error)"
            }
            lock.unlock()
            if ownsLifecycle || terminallyCancelled {
                removeRuntimeSockets()
            }
            if ownsLifecycle {
                idleController?.setSleeping(false)
            }
            throw error
        }
    }

    public func start() throws {
        idleController?.beginControlOperation()
        defer { idleController?.endControlOperation() }

        lock.lock()
        guard !terminalShutdown else {
            lock.unlock()
            throw TierError.daemonShuttingDown
        }
        if state == .starting {
            // A manual start during supervised backoff promotes the queued recovery to an
            // immediate foreground start. A helper that is already launching remains exclusive.
            guard helperProcess == nil, let queuedRestart = restartWorkItem else {
                lock.unlock()
                throw TierError.alreadyRunning
            }
            queuedRestart.cancel()
            restartWorkItem = nil
        }
        if dataplane != nil {
            if state == .sleeping {
                unexpectedRestartCount = 0
                lock.unlock()
                wakeSynchronously()
                try requireRunningAfterWake()
                return
            }
            lock.unlock()
            throw TierError.alreadyRunning
        }
        restartWorkItem?.cancel()
        restartWorkItem = nil
        lifecycleEpoch &+= 1
        let startEpoch = lifecycleEpoch
        unexpectedRestartCount = 0
        activeHelperGeneration = nil
        helperStartedAt = nil
        readinessTracker.beginCycle(trigger: "cold-start")
        setStateLocked(.starting)
        lastError = nil
        lock.unlock()

        try launchFreshTier(epoch: startEpoch)
    }

    /// Promote every recoverable lifecycle shape to one confirmed running state.
    ///
    /// App opens, explicit XPC start/wake calls, and runtime-mode changes all use this operation.
    /// It waits behind an in-flight cold wake instead of racing a second helper launch, and it can
    /// restart a tier that an explicit engine stop left fully stopped.
    public func promoteToRunning(timeout: TimeInterval = 240) throws {
        let deadline = Date().addingTimeInterval(max(1, timeout))
        var attemptedPromotion = false

        while true {
            let snapshot = status()
            switch snapshot.state {
            case .running:
                return
            case .starting:
                guard waitForPromotionStateChange(until: deadline) else {
                    throw TierError.promotionTimeout
                }
                continue
            case .sleeping, .stopped, .failed:
                guard !attemptedPromotion else {
                    throw TierError.wakeFailed(
                        snapshot.lastError ?? "docker tier stopped before promotion completed"
                    )
                }
                attemptedPromotion = true
                do {
                    try start()
                } catch {
                    let afterStart = status()
                    guard afterStart.state == .starting else { throw error }
                }
            }
            guard Date() < deadline else { throw TierError.promotionTimeout }
        }
    }

    /// Must be called with `lock` held. Promotion waiters are one-shot: every terminal transition
    /// wakes all callers, which then inspect the authoritative state and either return or register
    /// for the next lifecycle. This removes the old 50 ms state-promotion poll without coupling
    /// clients to the helper implementation.
    private func setStateLocked(_ newState: DockerTierState) {
        state = newState
        guard newState != .starting, !promotionWaiters.isEmpty else { return }
        let waiters = promotionWaiters.values
        promotionWaiters.removeAll()
        for waiter in waiters { waiter.signal() }
    }

    private func waitForPromotionStateChange(until deadline: Date) -> Bool {
        lock.lock()
        guard state == .starting else {
            lock.unlock()
            return true
        }
        let id = UUID()
        let waiter = DispatchSemaphore(value: 0)
        promotionWaiters[id] = waiter
        lock.unlock()

        let remaining = max(0, deadline.timeIntervalSinceNow)
        let result = waiter.wait(timeout: .now() + remaining)
        if result == .timedOut {
            lock.lock()
            promotionWaiters.removeValue(forKey: id)
            let changed = state != .starting
            lock.unlock()
            return changed
        }
        return true
    }

    private func validateGuestPrerequisites(helper: (any DockerManagedProcess)?) throws {
        guard configuration.hasManagedHelper else {
            for stage in [DoryReadinessStageID.guestAgent, .mountsDataDisk, .network] {
                readinessTracker.inactive(
                    stage,
                    code: "\(stage.rawValue).external_backend",
                    detail: "No managed guest is configured"
                )
            }
            return
        }
        guard let agentControl else {
            // Development/test configurations can deliberately omit the agent endpoint. Shipping
            // configurations always provide one; keep the test backend explicit instead of
            // fabricating active probe evidence.
            for stage in [DoryReadinessStageID.guestAgent, .mountsDataDisk, .network] {
                readinessTracker.inactive(
                    stage,
                    code: "\(stage.rawValue).probe_unconfigured",
                    detail: "Guest readiness probe endpoint is not configured"
                )
            }
            return
        }

        readinessTracker.begin(.guestAgent, deadlineSeconds: 30)
        let agentDeadline = Date().addingTimeInterval(30)
        var lastAgentError = "guest agent did not answer"
        while Date() < agentDeadline {
            guard helper?.isRunning != false else {
                throw TierError.helperExited("exited before the guest agent became ready")
            }
            do {
                let info = try agentControl.info()
                readinessTracker.ready(
                    .guestAgent,
                    code: "guestAgent.rpc_ready",
                    detail: "agent protocol \(info.protocolVersion), build \(info.agentBuild)"
                )
                lastAgentError = ""
                break
            } catch {
                lastAgentError = "\(error)"
                agentControl.disconnect()
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        guard lastAgentError.isEmpty else {
            throw TierError.readinessStageFailed(stage: .guestAgent, detail: lastAgentError)
        }

        readinessTracker.begin(.mountsDataDisk, deadlineSeconds: 10)
        let mounts = try agentControl.exec(
            argv: [
                "/bin/sh", "-eu", "-c",
                "awk '$2 == \"/var/lib/docker\" { found=1 } END { exit(found ? 0 : 1) }' /proc/mounts && test -b /dev/vdb",
            ],
            timeoutMs: 10_000,
            outputLimitBytes: 64 * 1024
        )
        guard mounts.exitCode == 0 else {
            throw TierError.readinessStageFailed(
                stage: .mountsDataDisk,
                detail: Self.execFailureDetail(mounts)
            )
        }
        readinessTracker.ready(
            .mountsDataDisk,
            code: "mounts.data_disk_ready",
            detail: "verified /dev/vdb mounted at /var/lib/docker"
        )

        readinessTracker.begin(.network, deadlineSeconds: 10)
        let network = try agentControl.exec(
            argv: [
                "/bin/sh", "-eu", "-c",
                "ip route show default | grep -q . && test -s /etc/resolv.conf",
            ],
            timeoutMs: 10_000,
            outputLimitBytes: 64 * 1024
        )
        guard network.exitCode == 0 else {
            throw TierError.readinessStageFailed(
                stage: .network,
                detail: Self.execFailureDetail(network)
            )
        }
        readinessTracker.ready(
            .network,
            code: "network.route_resolver_ready",
            detail: "guest default route and resolver configuration are present"
        )
    }

    private static func execFailureDetail(_ result: DoryExecResult) -> String {
        let stderr = String(decoding: result.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let output = stderr.isEmpty ? stdout : stderr
        return output.isEmpty ? "guest probe exited \(result.exitCode)" : String(output.prefix(500))
    }

    private func readinessReasonCode(for error: Error) -> String {
        if case let TierError.readinessStageFailed(stage, _) = error {
            return "\(stage.rawValue).probe_failed"
        }
        switch error {
        case TierError.readyTimeout:
            return "dockerd.deadline_exceeded"
        case TierError.startCancelled:
            return "engine.start_cancelled"
        case TierError.helperExited:
            return "vmProcess.exited"
        default:
            return "engine.start_failed"
        }
    }

    private func validateDockerBackend(
        helper: (any DockerManagedProcess)?,
        epoch: UInt64,
        timeout: TimeInterval
    ) throws {
        readinessTracker.begin(.dockerd, deadlineSeconds: timeout)
        let ready = dockerReadyWaiter(configuration, timeout) {
            self.freshLaunchIsActive(epoch: epoch, helper: helper)
                && helper?.isRunning == true
        }
        guard freshLaunchIsActive(epoch: epoch, helper: helper) else {
            throw TierError.startCancelled
        }
        guard helper?.isRunning == true else {
            throw TierError.helperExited("exited during Docker readiness")
        }
        guard ready else { throw TierError.readyTimeout }
        readinessTracker.ready(
            .dockerd,
            code: "dockerd.version_ready",
            detail: "Docker /version returned a Linux server response"
        )
    }

    private func launchFreshTier(epoch: UInt64, publishFailure: Bool = true) throws {
        var startedHelper: (any DockerManagedProcess)?
        var startedResources: DataplaneResources?
        do {
            let helperGeneration = UUID()
            let helper = makeManagedProcess(generation: helperGeneration)
            startedHelper = helper

            // Publish the in-flight helper before start(), because VMM startup can block waiting
            // for its handoff and raw-HV startup immediately enters the Docker readiness wait.
            // A concurrent daemon shutdown must be able to find and stop either shape instead of
            // leaving a child behind until the startup call eventually returns.
            lock.lock()
            guard !terminalShutdown, lifecycleEpoch == epoch, state == .starting else {
                lock.unlock()
                throw TierError.startCancelled
            }
            helperProcess = helper
            activeHelperGeneration = helper == nil ? nil : helperGeneration
            lock.unlock()

            try helper?.start()

            guard freshLaunchIsActive(epoch: epoch, helper: helper) else {
                throw TierError.startCancelled
            }

            readinessTracker.ready(
                .vmProcess,
                code: "vm.process_ready",
                detail: helper?.pid.map { "managed helper pid \($0) is running" } ?? "in-process backend is running"
            )
            try validateGuestPrerequisites(helper: helper)

            if configuration.hasManagedHelper {
                try validateDockerBackend(
                    helper: helper,
                    epoch: epoch,
                    timeout: Self.freshStartReadyTimeout
                )
            } else {
                readinessTracker.inactive(
                    .dockerd,
                    code: "dockerd.external_backend",
                    detail: "No managed Docker helper is configured"
                )
            }

            readinessTracker.begin(.hostSocketContext, deadlineSeconds: 10)
            let resources = try startDataplane()
            startedResources = resources

            lock.lock()
            let ownsHelper = helper.map { helperProcess === $0 } ?? (helperProcess == nil)
            guard !terminalShutdown,
                  lifecycleEpoch == epoch,
                  state == .starting,
                  ownsHelper else {
                lock.unlock()
                throw TierError.startCancelled
            }
            if configuration.hasManagedHelper, helper?.isRunning != true {
                lock.unlock()
                throw TierError.helperExited("exited while publishing the Docker socket")
            }
            activityServer = resources.activityServer
            dataplane = resources.handle
            helperStartedAt = helper == nil ? nil : Date()
            setStateLocked(.running)
            lastError = nil
            idleController?.setSleeping(false)
            lifecycleStateObserver(.running)
            lock.unlock()
            readinessTracker.ready(
                .hostSocketContext,
                code: "socket.forwarder_ready",
                detail: "Dory's same-user Docker socket is bound; host context is verified separately"
            )
            startedResources = nil
        } catch {
            readinessTracker.blockCurrent(
                code: readinessReasonCode(for: error),
                detail: "\(error)"
            )
            startedResources?.handle.shutdown()
            startedResources?.activityServer?.stop()
            startedHelper?.stop()

            let ownsLifecycle: Bool
            let terminallyCancelled: Bool
            lock.lock()
            terminallyCancelled = terminalShutdown
            if lifecycleEpoch == epoch {
                ownsLifecycle = true
                if let startedHelper, helperProcess === startedHelper {
                    helperProcess = nil
                }
                activeHelperGeneration = nil
                helperStartedAt = nil
                setStateLocked(publishFailure ? .failed : .starting)
                lastError = "\(error)"
            } else {
                ownsLifecycle = false
            }
            lock.unlock()
            if ownsLifecycle || terminallyCancelled {
                // A terminally-cancelled launch may have bound its dataplane after shutdown's
                // tearDown already unlinked the old paths. No newer lifecycle can exist once the
                // latch is set, so removing those late paths cannot unlink a replacement server.
                removeRuntimeSockets()
            }
            throw error
        }
    }

    private func freshLaunchIsActive(
        epoch: UInt64,
        helper: (any DockerManagedProcess)?
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let ownsHelper = helper.map { helperProcess === $0 } ?? (helperProcess == nil)
        return !terminalShutdown
            && lifecycleEpoch == epoch
            && state == .starting
            && ownsHelper
    }

    private func requireRunningAfterWake() throws {
        lock.lock()
        let currentState = state
        let currentError = lastError
        let isTerminalShutdown = terminalShutdown
        lock.unlock()

        guard currentState == .running else {
            if isTerminalShutdown {
                throw TierError.daemonShuttingDown
            }
            if currentError == TierError.readyTimeout.description {
                throw TierError.readyTimeout
            }
            throw TierError.wakeFailed(currentError ?? "docker tier is \(currentState.rawValue)")
        }
    }

    public func stop() {
        idleController?.beginControlOperation()
        defer { idleController?.endControlOperation() }
        tearDown(markStopped: true, publishStoppedIntent: true)
    }

    /// Permanently close this tier for daemon process shutdown.
    ///
    /// Unlike ordinary engineStop/stop(), this is a one-way latch. Any XPC request that was
    /// accepted before listener invalidation, or races cleanup afterward, is prevented from
    /// spawning/resuming a helper once terminal shutdown begins.
    public func shutdown() {
        idleController?.beginControlOperation()
        defer { idleController?.endControlOperation() }

        lock.lock()
        terminalShutdown = true
        lock.unlock()
        tearDown(markStopped: true)
    }

    @discardableResult
    public func cleanupStaleHelpers() -> [Int32] {
        var killed: [Int32] = []
        if let hvConfiguration = configuration.hvProcess,
           let stateDirectory = HelperProcessJanitor.stateDirectoryArgument(
            in: ([hvConfiguration.executablePath] + hvConfiguration.arguments).joined(separator: " ")
           ) {
            killed.append(contentsOf: HelperProcessJanitor.terminateStaleHelpers(
                executablePath: hvConfiguration.executablePath,
                stateDirectory: stateDirectory,
                timeout: DoryEngineShutdownTiming.hostTerminationSeconds
            ))
        }
        if let vmmConfiguration = configuration.vmmProcess {
            killed.append(contentsOf: HelperProcessJanitor.terminateStaleHelpers(
                executablePath: vmmConfiguration.executablePath,
                stateDirectory: vmmConfiguration.stateDirectory
            ))
        }
        return killed
    }

    public func sleepForIdle(idleAfter seconds: TimeInterval, now: Date = Date()) -> Bool {
        lock.lock()
        let isTerminalShutdown = terminalShutdown
        lock.unlock()
        guard !isTerminalShutdown else { return false }

        if let sleptQueuedRecovery = sleepQueuedRecoveryIfPresent() {
            return sleptQueuedRecovery
        }
        return sleepForIdle(idleAfter: seconds, now: now, activity: containerActivityProbe(configuration))
    }

    /// An explicit sleep can race an unexpected-exit backoff. Convert the queued recovery into the
    /// ordinary lightweight sleeping dataplane; otherwise the delayed work item would violate the
    /// user's sleep decision by relaunching the VM moments later.
    private func sleepQueuedRecoveryIfPresent() -> Bool? {
        let queuedRestart: DispatchWorkItem
        lock.lock()
        guard state == .starting,
              helperProcess == nil,
              dataplane == nil,
              let queued = restartWorkItem else {
            lock.unlock()
            return nil
        }
        queuedRestart = queued
        restartWorkItem = nil
        lifecycleEpoch &+= 1
        activeHelperGeneration = nil
        helperStartedAt = nil
        setStateLocked(.stopped)
        lastError = nil
        lock.unlock()

        queuedRestart.cancel()
        removeRuntimeSockets()
        do {
            try armSleeping()
            return true
        } catch {
            lock.lock()
            setStateLocked(.failed)
            lastError = "could not arm sleeping tier after cancelling recovery: \(error)"
            lock.unlock()
            return false
        }
    }

    private func sleepForIdle(
        idleAfter seconds: TimeInterval,
        now: Date,
        activity: DockerContainerActivity
    ) -> Bool {
        guard let idleController, configuration.hasManagedHelper else {
            return false
        }

        let claimedSleep: Bool
        switch activity {
        case .empty:
            claimedSleep = idleController.claimSleepForEmptyEngine(idleAfter: seconds, now: now)
        case .active, .unknown:
            claimedSleep = idleController.claimSleepIfIdle(idleAfter: seconds, now: now)
        }
        guard claimedSleep else {
            return false
        }

        lock.lock()
        guard state == .running, let currentHelper = helperProcess else {
            lock.unlock()
            idleController.setSleeping(false)
            return false
        }
        let idleSnapshot = idleController.snapshot
        let staleRequestAllowed = activity == .empty
        guard (idleSnapshot.activeRequests == 0 || staleRequestAllowed),
              idleSnapshot.controlOperations == 0 else {
            lock.unlock()
            idleController.setSleeping(false)
            return false
        }
        setStateLocked(.sleeping)
        wakeTask = nil

        switch activity {
        case .empty:
            helperProcess = nil
            activeHelperGeneration = nil
            helperStartedAt = nil
            lastError = nil
            agentControl?.disconnect()
            currentHelper.stop()
            lifecycleStateObserver(.sleeping)
            lock.unlock()
            return true
        case .active, .unknown:
            agentControl?.disconnect()
            guard currentHelper.suspend() else {
                setStateLocked(.running)
                lastError = TierError.suspendFailed(pid: currentHelper.pid).description
                lock.unlock()
                idleController.setSleeping(false)
                return false
            }
            lastError = nil
            lifecycleStateObserver(.sleeping)
            lock.unlock()
            return true
        }
    }

    public func prepareForHostSleep(now: Date = Date()) -> HostSleepActionResult {
        lock.lock()
        let currentState = state
        lock.unlock()
        guard currentState == .running else {
            return HostSleepActionResult(
                name: "docker",
                attempted: false,
                slept: false,
                detail: "docker state=\(currentState.rawValue)"
            )
        }

        let activity = containerActivityProbe(configuration)
        switch activity {
        case .empty:
            let slept = sleepForIdle(idleAfter: 0, now: now, activity: activity)
            return HostSleepActionResult(
                name: "docker",
                attempted: true,
                slept: slept,
                detail: slept ? "docker engine empty; helper stopped for host sleep" : "docker engine empty; sleep claim rejected"
            )
        case .active(let count):
            return HostSleepActionResult(
                name: "docker",
                attempted: false,
                slept: false,
                detail: "docker has \(count) active container(s)"
            )
        case .unknown(let reason):
            return HostSleepActionResult(
                name: "docker",
                attempted: false,
                slept: false,
                detail: "docker activity unknown: \(reason)"
            )
        }
    }

    public func refreshPublishedPorts() throws -> PortPublishDiff? {
        guard let agentControl, let portPublisher else { return nil }
        lock.lock()
        let currentState = state
        lock.unlock()
        guard currentState == .running else { return nil }
        return try portPublisher.refresh(from: agentControl)
    }

    /// Forces dory-hv's gvproxy publisher to reconcile immediately, then validates the guest-agent
    /// port snapshot used by privileged and diagnostic surfaces. The VMM helper path has no gvproxy
    /// publisher and therefore fails closed instead of delivering SIGUSR2 to an unrelated process.
    public func repairPublishedPorts() throws -> PortPublishDiff? {
        lock.lock()
        let currentState = state
        let helperPID = helperProcess?.pid
        let supportsSignal = configuration.hvProcess != nil
        lock.unlock()
        guard currentState == .running else {
            throw TierError.repairUnavailable("docker tier is \(currentState.rawValue)")
        }
        guard supportsSignal, let helperPID else {
            throw TierError.repairUnavailable("dory-hv port reconciliation is unavailable")
        }
        guard kill(helperPID, SIGUSR2) == 0 else {
            throw TierError.repairUnavailable("could not signal dory-hv pid \(helperPID): \(String(cString: strerror(errno)))")
        }
        return try refreshPublishedPorts()
    }

    public func currentPublishedPorts() -> [DoryListenPort]? {
        guard let portPublisher else { return nil }
        return portPublisher.current
    }

    public func currentDockerPublishedPorts() -> [DoryListenPort]? {
        lock.lock()
        let currentState = state
        lock.unlock()
        guard currentState == .running else { return [] }

        let summaries: DockerContainerList
        if let dockerdSocketPath = configuration.dockerdSocketPath {
            summaries = DockerEngineProbe.containerSummaries(socketPath: dockerdSocketPath)
        } else {
            summaries = DockerEngineProbe.containerSummaries(
                forwardSocketPath: configuration.forwardSocketPath,
                cid: configuration.cid,
                dockerPort: configuration.dockerPort
            )
        }
        switch summaries {
        case let .ok(containers):
            var ports = Set<DoryListenPort>()
            for container in containers where container.isRunning {
                for port in container.ports {
                    guard let listenPort = Self.dockerPublishedPort(port) else { continue }
                    ports.insert(listenPort)
                }
            }
            return ports.sorted {
                if $0.port == $1.port { return $0.protocol < $1.protocol }
                return $0.port < $1.port
            }
        case .unavailable:
            return nil
        }
    }

    public func containerSummariesForIdle() -> DockerContainerList {
        lock.lock()
        let currentState = state
        let currentError = lastError
        lock.unlock()
        switch currentState {
        case .running:
            if let dockerdSocketPath = configuration.dockerdSocketPath {
                return DockerEngineProbe.containerSummaries(socketPath: dockerdSocketPath)
            }
            return DockerEngineProbe.containerSummaries(
                    forwardSocketPath: configuration.forwardSocketPath,
                    cid: configuration.cid,
                    dockerPort: configuration.dockerPort
                )
        case .failed:
            return .unavailable(currentError ?? "docker tier failed")
        case .stopped, .starting, .sleeping:
            return .ok([])
        }
    }

    public func agentInfo() throws -> DoryAgentInfo? {
        guard let agentControl else { return nil }
        lock.lock()
        let currentState = state
        lock.unlock()
        guard currentState == .running else { return nil }
        return try agentControl.info()
    }

    /// Drops only the cached RPC transport and proves a fresh guest-agent request. The VM,
    /// containers, mounts, and Docker daemon remain untouched.
    public func reconnectAgent() throws -> DoryAgentInfo {
        guard let agentControl else {
            throw TierError.repairUnavailable("guest agent control is not configured")
        }
        lock.lock()
        let currentState = state
        lock.unlock()
        guard currentState == .running else {
            throw TierError.repairUnavailable("docker tier is \(currentState.rawValue)")
        }
        agentControl.disconnect()
        do {
            let info = try agentControl.info()
            readinessTracker.ready(
                .guestAgent,
                code: "guestAgent.reconnected",
                detail: "fresh RPC reached agent build \(info.agentBuild)"
            )
            return info
        } catch {
            readinessTracker.blocked(
                .guestAgent,
                code: "guestAgent.reconnect_failed",
                detail: "\(error)"
            )
            throw error
        }
    }

    /// Replaces only the host forwarding socket. This is safe for running workloads because the
    /// guest VM and dockerd socket are retained; clients with an already-open broken connection may
    /// retry against the newly-bound same-user socket.
    public func repairSocketForwarder() throws -> String {
        if DockerEngineProbe.waitUntilReady(socketPath: socket.path, timeout: 1, pollInterval: 0.25) {
            return "Docker host socket is already healthy; no mutation applied"
        }

        lock.lock()
        guard state == .running else {
            let current = state
            lock.unlock()
            throw TierError.repairUnavailable("docker tier is \(current.rawValue)")
        }
        let previousDataplane = dataplane
        let previousActivityServer = activityServer
        dataplane = nil
        activityServer = nil
        readinessTracker.begin(.hostSocketContext, deadlineSeconds: 10)
        removeHostDataplaneSockets()
        previousDataplane?.shutdown()
        previousActivityServer?.stop()
        do {
            let replacement = try startDataplane()
            dataplane = replacement.handle
            activityServer = replacement.activityServer
            lock.unlock()
        } catch {
            lastError = "host socket forwarder repair failed: \(error)"
            lock.unlock()
            readinessTracker.blocked(
                .hostSocketContext,
                code: "socket.forwarder_rebind_failed",
                detail: "\(error)"
            )
            throw error
        }

        guard DockerEngineProbe.waitUntilReady(socketPath: socket.path, timeout: 5, pollInterval: 0.25) else {
            readinessTracker.blocked(
                .hostSocketContext,
                code: "socket.forwarder_probe_failed",
                detail: "replacement socket bound, but Docker /version did not pass"
            )
            throw TierError.repairUnavailable("replacement Docker socket did not pass /version")
        }
        readinessTracker.ready(
            .hostSocketContext,
            code: "socket.forwarder_replaced",
            detail: "replaced only the host dataplane socket; VM and workloads were retained"
        )
        return "replaced the host Docker socket/forwarder without restarting the VM or dockerd"
    }

    /// Restarts only a confirmed-dead dockerd using the root-only command captured during guest
    /// boot. A healthy API is never restarted, and the persistent data mount/VM stay in place.
    public func repairDockerDaemon(timeout: TimeInterval = 45) throws -> String {
        switch containerSummariesForIdle() {
        case .ok(let containers):
            return "Docker API is already healthy; \(containers.count) container(s) visible and no mutation applied"
        case .unavailable:
            break
        }
        guard let agentControl else {
            throw TierError.repairUnavailable("guest agent control is not configured")
        }
        lock.lock()
        let currentState = state
        let currentHelper = helperProcess
        lock.unlock()
        guard currentState == .running, currentHelper?.isRunning == true else {
            throw TierError.repairUnavailable("VM helper is not running; dockerd-only repair is unavailable")
        }

        readinessTracker.begin(.dockerd, deadlineSeconds: timeout)
        _ = try reconnectAgent()
        let restart = try agentControl.exec(
            argv: [
                "/bin/sh", "-eu", "-c",
                "test -x /run/dory-restart-dockerd; pids=$(pidof dockerd 2>/dev/null || true); [ -z \"$pids\" ] || kill -TERM $pids 2>/dev/null || true; n=0; while [ -n \"$(pidof dockerd 2>/dev/null || true)\" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n+1)); done; [ -z \"$(pidof dockerd 2>/dev/null || true)\" ] || exit 70; nohup /run/dory-restart-dockerd </dev/null >/var/log/dockerd.log 2>&1 &",
            ],
            timeoutMs: 15_000,
            outputLimitBytes: 64 * 1024
        )
        guard restart.exitCode == 0 else {
            let detail = Self.execFailureDetail(restart)
            readinessTracker.blocked(.dockerd, code: "dockerd.restart_failed", detail: detail)
            throw TierError.repairUnavailable(detail)
        }
        let ready = dockerReadyWaiter(configuration, timeout) { [weak self] in
            guard let self, let currentHelper else { return false }
            self.lock.lock()
            let active = self.state == .running && self.helperProcess === currentHelper
            self.lock.unlock()
            return active && currentHelper.isRunning
        }
        guard ready else {
            readinessTracker.blocked(
                .dockerd,
                code: "dockerd.restart_deadline_exceeded",
                detail: "dockerd-only restart did not restore /version before \(Int(timeout)) seconds"
            )
            throw TierError.repairUnavailable("dockerd-only restart did not restore the Docker API")
        }
        readinessTracker.ready(
            .dockerd,
            code: "dockerd.restarted_in_place",
            detail: "dockerd restarted in the existing VM with the existing data mount"
        )
        return "restarted only dockerd in the existing VM; data disk and VM were retained"
    }

    /// Reconciles the validated corporate pull/registry/CA contract inside the managed guest.
    /// Material lives only on guest tmpfs and is re-sent after every boot, so durable Docker data
    /// can never become a root-sourced configuration channel. A changed effective digest restarts
    /// dockerd with live-restore; an identical digest performs no mutation.
    public func applyCorporateConnectivity(
        profile: CorporateConnectivityProfile,
        validation: CorporateConnectivityValidation,
        profileDigest: String,
        timeout: TimeInterval = 45
    ) throws -> CorporateGuestApplyResult {
        guard validation.valid else {
            throw TierError.repairUnavailable("corporate connectivity profile is invalid")
        }
        guard let agentControl else {
            return CorporateGuestApplyResult(
                state: "guest agent is not configured; no guest mutation applied",
                changed: false,
                dockerdRestarted: false
            )
        }
        lock.lock()
        let currentState = state
        let currentHelper = helperProcess
        lock.unlock()
        guard currentState == .running, currentHelper?.isRunning == true else {
            return CorporateGuestApplyResult(
                state: "managed guest is \(currentState.rawValue); profile will reconcile on wake/start",
                changed: false,
                dockerdRestarted: false
            )
        }

        let rendered = try Self.renderCorporateGuestFiles(profile: profile, validation: validation)
        let script = Self.corporateGuestApplyScript(
            enabled: profile.enabled,
            profileDigest: profileDigest,
            effectiveDigest: rendered.digest,
            environmentBase64: rendered.environment.base64EncodedString(),
            argumentsBase64: rendered.arguments.base64EncodedString(),
            certificates: rendered.certificates
        )
        let result = try agentControl.exec(
            argv: ["/bin/sh", "-eu", "-c", script],
            timeoutMs: 20_000,
            outputLimitBytes: 128 * 1024
        )
        guard result.exitCode == 0 else {
            throw TierError.repairUnavailable(
                "guest corporate connectivity reconcile failed: \(Self.execFailureDetail(result))"
            )
        }
        let output = String(decoding: result.stdout, as: UTF8.self)
        guard output.contains("DORY_CORPORATE_CHANGED=1") else {
            return CorporateGuestApplyResult(
                state: "guest dockerd proxy, registry and CA digest already matched",
                changed: false,
                dockerdRestarted: false
            )
        }

        readinessTracker.begin(.dockerd, deadlineSeconds: timeout)
        let ready = dockerReadyWaiter(configuration, timeout) { [weak self] in
            guard let self, let currentHelper else { return false }
            self.lock.lock()
            let active = self.state == .running && self.helperProcess === currentHelper
            self.lock.unlock()
            return active && currentHelper.isRunning
        }
        guard ready else {
            readinessTracker.blocked(
                .dockerd,
                code: "dockerd.corporate_reconfigure_failed",
                detail: "dockerd did not restore /version after corporate settings changed"
            )
            throw TierError.repairUnavailable("dockerd did not become ready after corporate connectivity reconcile")
        }
        readinessTracker.ready(
            .dockerd,
            code: "dockerd.corporate_reconfigured",
            detail: "applied a changed corporate proxy/registry/CA digest with live-restore"
        )
        return CorporateGuestApplyResult(
            state: profile.enabled
                ? "guest proxy, registry and CA contract applied"
                : "Dory-owned guest corporate settings removed",
            changed: true,
            dockerdRestarted: true
        )
    }

    private struct RenderedCorporateGuestFiles {
        var environment: Data
        var arguments: Data
        var certificates: [(id: String, base64: String)]
        var digest: String
    }

    private static func renderCorporateGuestFiles(
        profile: CorporateConnectivityProfile,
        validation: CorporateConnectivityValidation
    ) throws -> RenderedCorporateGuestFiles {
        guard profile.enabled else {
            return RenderedCorporateGuestFiles(
                environment: Data(), arguments: Data(), certificates: [], digest: "disabled"
            )
        }
        let proxy = validation.effectiveDockerd
        var environmentLines: [String] = []
        if let value = proxy.httpProxy {
            environmentLines.append("export HTTP_PROXY=\(shellQuote(value))")
            environmentLines.append("export http_proxy=\(shellQuote(value))")
        }
        if let value = proxy.httpsProxy {
            environmentLines.append("export HTTPS_PROXY=\(shellQuote(value))")
            environmentLines.append("export https_proxy=\(shellQuote(value))")
        }
        let safeBypass = CorporateConnectivityValidator.normalizedNoProxy(
            proxy.noProxy + [
                "localhost", "127.0.0.1", "::1", ".dory.local", "host.dory.internal",
                "169.254.0.0/16", profile.bridgeSubnet,
            ]
        ).joined(separator: ",")
        if !safeBypass.isEmpty {
            environmentLines.append("export NO_PROXY=\(shellQuote(safeBypass))")
            environmentLines.append("export no_proxy=\(shellQuote(safeBypass))")
        }
        let environment = Data((environmentLines.joined(separator: "\n") + "\n").utf8)

        let arguments = profile.registries.mirrors.map { "--registry-mirror=\($0)" }
            + profile.registries.insecureRegistries.map { "--insecure-registry=\($0)" }
        let argumentData = Data((arguments.joined(separator: "\n") + (arguments.isEmpty ? "" : "\n")).utf8)

        var certificates: [(id: String, base64: String)] = []
        for ca in profile.certificateAuthorities
        where ca.scopes.contains(.dockerdRegistry) || ca.scopes.contains(.buildKit) {
            let data = try CorporateConnectivityValidator.safeCAData(path: ca.path)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == ca.sha256.lowercased() else {
                throw TierError.repairUnavailable("CA \(ca.id) changed after profile validation")
            }
            certificates.append((ca.id, data.base64EncodedString()))
        }
        certificates.sort { $0.id < $1.id }
        var digestInput = environment + argumentData
        for certificate in certificates {
            digestInput.append(Data(certificate.id.utf8))
            digestInput.append(Data(certificate.base64.utf8))
        }
        let digest = SHA256.hash(data: digestInput).map { String(format: "%02x", $0) }.joined()
        return RenderedCorporateGuestFiles(
            environment: environment,
            arguments: argumentData,
            certificates: certificates,
            digest: digest
        )
    }

    private static func corporateGuestApplyScript(
        enabled: Bool,
        profileDigest: String,
        effectiveDigest: String,
        environmentBase64: String,
        argumentsBase64: String,
        certificates: [(id: String, base64: String)]
    ) -> String {
        var lines = [
            "umask 077",
            "test -x /run/dory-restart-dockerd",
            "mkdir -p /run/dory-corporate /run/dory-corporate/ca",
            "chmod 0700 /run/dory-corporate /run/dory-corporate/ca",
            "DORY_OLD_DIGEST=$(cat /run/dory-corporate/effective.sha256 2>/dev/null || true)",
            "if [ \"$DORY_OLD_DIGEST\" = \(shellQuote(effectiveDigest)) ]; then echo DORY_CORPORATE_CHANGED=0; exit 0; fi",
        ]
        if !enabled {
            lines.append("if [ -z \"$DORY_OLD_DIGEST\" ]; then echo DORY_CORPORATE_CHANGED=0; exit 0; fi")
        }
        if enabled {
            lines += [
                "printf %s \(shellQuote(environmentBase64)) | base64 -d >/run/dory-corporate/dockerd.env.tmp",
                "printf %s \(shellQuote(argumentsBase64)) | base64 -d >/run/dory-corporate/dockerd.args.tmp",
                "chmod 0600 /run/dory-corporate/dockerd.env.tmp /run/dory-corporate/dockerd.args.tmp",
                "mv /run/dory-corporate/dockerd.env.tmp /run/dory-corporate/dockerd.env",
                "mv /run/dory-corporate/dockerd.args.tmp /run/dory-corporate/dockerd.args",
                "rm -f /run/dory-corporate/ca/*.crt /usr/local/share/ca-certificates/dory-corporate-*.crt",
            ]
            for certificate in certificates {
                let safeID = certificate.id
                lines.append("printf %s \(shellQuote(certificate.base64)) | base64 -d >/run/dory-corporate/ca/\(safeID).crt")
                lines.append("chmod 0600 /run/dory-corporate/ca/\(safeID).crt")
                lines.append("cp /run/dory-corporate/ca/\(safeID).crt /usr/local/share/ca-certificates/dory-corporate-\(safeID).crt")
            }
        } else {
            lines += [
                "rm -f /run/dory-corporate/dockerd.env /run/dory-corporate/dockerd.args /run/dory-corporate/ca/*.crt",
                "rm -f /usr/local/share/ca-certificates/dory-corporate-*.crt",
            ]
        }
        lines += [
            "if command -v update-ca-certificates >/dev/null 2>&1; then update-ca-certificates >/var/log/dory-corporate-ca.log 2>&1; elif ls /usr/local/share/ca-certificates/dory-corporate-*.crt >/dev/null 2>&1; then echo update-ca-certificates-missing >&2; exit 72; fi",
            "printf '%s\\n' \(shellQuote(profileDigest)) >/run/dory-corporate/profile.sha256",
            "printf '%s\\n' \(shellQuote(effectiveDigest)) >/run/dory-corporate/effective.sha256",
            "pids=$(pidof dockerd 2>/dev/null || true)",
            "[ -z \"$pids\" ] || kill -TERM $pids 2>/dev/null || true",
            "n=0; while [ -n \"$(pidof dockerd 2>/dev/null || true)\" ] && [ $n -lt 100 ]; do sleep 0.1; n=$((n+1)); done",
            "[ -z \"$(pidof dockerd 2>/dev/null || true)\" ] || exit 70",
            "nohup /run/dory-restart-dockerd </dev/null >/var/log/dockerd.log 2>&1 &",
            "echo DORY_CORPORATE_CHANGED=1",
        ]
        return lines.joined(separator: "\n")
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    public func telemetry() throws -> DoryTelemetry? {
        guard let agentControl else { return nil }
        lock.lock()
        let currentState = state
        lock.unlock()
        guard currentState == .running else { return nil }
        return try agentControl.telemetry()
    }

    /// Returns composition-level guest memory and data-disk facts from one bounded agent command.
    /// These values are diagnostic only; balloon policy continues to use the versioned telemetry RPC.
    public func guestResourceSnapshot() throws -> DoryGuestResourceSnapshot? {
        guard let agentControl else { return nil }
        lock.lock()
        let currentState = state
        lock.unlock()
        guard currentState == .running else { return nil }

        let script = #"""
        awk '
          /^MemTotal:/ { total=$2 }
          /^MemAvailable:/ { available=$2 }
          /^MemFree:/ { free=$2 }
          /^Buffers:/ { buffers=$2 }
          /^Cached:/ { cached=$2 }
          /^SReclaimable:/ { sreclaimable=$2 }
          /^Shmem:/ { shmem=$2 }
          END {
            printf "mem_total_kb=%d\nmem_available_kb=%d\nmem_free_kb=%d\nbuffers_kb=%d\ncached_kb=%d\nsreclaimable_kb=%d\nshmem_kb=%d\n", total, available, free, buffers, cached, sreclaimable, shmem
          }
        ' /proc/meminfo
        df -Pk /var/lib/docker | awk 'NR == 2 { printf "disk_total_bytes=%.0f\ndisk_used_bytes=%.0f\ndisk_available_bytes=%.0f\n", $2 * 1024, $3 * 1024, $4 * 1024 }'
        """#
        let result = try agentControl.exec(
            argv: ["/bin/sh", "-c", script],
            timeoutMs: 3_000,
            outputLimitBytes: 16 * 1024
        )
        guard result.exitCode == 0 else {
            throw TierError.repairUnavailable("guest resource probe failed: \(Self.execFailureDetail(result))")
        }
        let values = Self.parseUnsignedKeyValues(result.stdout)
        guard let totalKB = values["mem_total_kb"],
              let availableKB = values["mem_available_kb"],
              let freeKB = values["mem_free_kb"],
              let diskTotal = values["disk_total_bytes"],
              let diskUsed = values["disk_used_bytes"],
              let diskAvailable = values["disk_available_bytes"] else {
            throw TierError.repairUnavailable("guest resource probe returned an incomplete record")
        }
        let buffersKB = values["buffers_kb"] ?? 0
        let cachedKB = values["cached_kb"] ?? 0
        let slabReclaimableKB = values["sreclaimable_kb"] ?? 0
        let sharedKB = values["shmem_kb"] ?? 0
        let cacheKB = buffersKB
            .saturatingAdding(cachedKB)
            .saturatingAdding(slabReclaimableKB)
            .saturatingSubtracting(sharedKB)
        let reclaimableKB = availableKB.saturatingSubtracting(freeKB)
        return DoryGuestResourceSnapshot(
            memoryCeilingBytes: totalKB.saturatingMultiplying(by: 1024),
            memoryUsedBytes: totalKB.saturatingSubtracting(availableKB).saturatingMultiplying(by: 1024),
            memoryCacheBytes: cacheKB.saturatingMultiplying(by: 1024),
            memoryReclaimableBytes: reclaimableKB.saturatingMultiplying(by: 1024),
            memoryFreeBytes: freeKB.saturatingMultiplying(by: 1024),
            dataDiskTotalBytes: diskTotal,
            dataDiskUsedBytes: diskUsed,
            dataDiskAvailableBytes: diskAvailable
        )
    }

    public func hostShareResourceSnapshot(now: Date = Date()) -> DoryHostShareResourceSnapshot? {
        guard let directory = managedHelperStateDirectory() else { return nil }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("host-share-resources.json")
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(DoryHostShareResourceSnapshot.self, from: data),
              snapshot.schema == "dev.dory.host-share.resources",
              snapshot.version == 1,
              abs(now.timeIntervalSince(snapshot.generatedAt)) <= 30 else {
            return nil
        }
        return snapshot
    }

    private func managedHelperStateDirectory() -> String? {
        if let directory = configuration.vmmProcess?.stateDirectory { return directory }
        guard let arguments = configuration.hvProcess?.arguments,
              let index = arguments.firstIndex(of: "--state-dir"),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func parseUnsignedKeyValues(_ data: Data) -> [String: UInt64] {
        guard let output = String(data: data, encoding: .utf8) else { return [:] }
        return output.split(whereSeparator: { $0.isNewline }).reduce(into: [:]) { values, line in
            let fields = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, let value = UInt64(fields[1]) else { return }
            values[String(fields[0])] = value
        }
    }

    public func memorySnapshot(
        id: String = "docker",
        minimumTargetMB: UInt64 = 512,
        maximumTargetMB: UInt64? = nil
    ) throws -> GuestMemorySnapshot? {
        guard let telemetry = try telemetry() else { return nil }
        return GuestMemorySnapshot(
            id: id,
            kind: .docker,
            telemetry: telemetry,
            minimumTargetMB: minimumTargetMB,
            maximumTargetMB: maximumTargetMB,
            canBalloon: false
        )
    }

    private static func dockerPublishedPort(_ port: DockerContainerPort) -> DoryListenPort? {
        guard let publicPort = port.publicPort,
              (1...65_535).contains(publicPort),
              let portNumber = UInt32(exactly: publicPort) else {
            return nil
        }
        switch (port.type ?? "tcp").lowercased() {
        case "tcp", "tcp6":
            return DoryListenPort(protocol: "tcp", port: portNumber)
        case "udp", "udp6":
            return DoryListenPort(protocol: "udp", port: portNumber)
        default:
            return nil
        }
    }

    public func syncAgentClock(now: Date = Date()) -> AgentClockSyncResult {
        // Reached on host wake via the wake coordinator's clock syncers. Reset the idle
        // clock the way the engine-wake path does: a long host sleep otherwise leaves
        // lastActivity far in the past, so the idle scheduler would sleep a just-woken
        // engine almost immediately.
        idleController?.touch(now: now)
        guard let agentControl else {
            return AgentClockSyncResult(name: "docker", attempted: false, synced: false)
        }
        lock.lock()
        let currentState = state
        lock.unlock()
        guard currentState == .running else {
            return AgentClockSyncResult(name: "docker", attempted: false, synced: false)
        }
        do {
            let synced = try agentControl.clockSync(now: now)
            if synced {
                lock.lock()
                lastError = nil
                lock.unlock()
            }
            return AgentClockSyncResult(name: "docker", attempted: true, synced: synced)
        } catch {
            lock.lock()
            lastError = "agent clock sync failed: \(error)"
            lock.unlock()
            return AgentClockSyncResult(
                name: "docker",
                attempted: true,
                synced: false,
                error: "\(error)"
            )
        }
    }

    public func ensureAwake() async {
        if let task = wakeTaskForEnsureAwake() {
            await task.value
            return
        }

        // An explicit start can promote an armed dataplane synchronously, without installing a
        // wakeTask. Hold a request that arrives in that window until the same promotion finishes;
        // otherwise the activity acknowledgement lets it dial a guest whose dockerd is still booting.
        guard promotionIsStarting(), !Task.isCancelled else { return }
        _ = await Task.detached { [weak self] in
            self?.waitForPromotionStateChange(until: Date().addingTimeInterval(240)) ?? false
        }.value
    }

    private func promotionIsStarting() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !terminalShutdown && state == .starting
    }

    private func wakeTaskForEnsureAwake() -> Task<Void, Never>? {
        lock.lock()
        if terminalShutdown {
            lock.unlock()
            return nil
        }
        // A request that arrives after the first wake has changed the tier to `starting` must
        // still await that exact promotion. Acknowledging it early makes the dataplane connect to
        // a backend that is not ready yet and turns a healthy cold boot into a client-visible EOF.
        if let wakeTask {
            lock.unlock()
            return wakeTask
        }
        if state != .sleeping {
            lock.unlock()
            return nil
        }
        let task = Task.detached { [weak self] in
            if let self {
                self.wakeSynchronously()
            }
        }
        wakeTask = task
        lock.unlock()
        return task
    }

    private func wakeSynchronously() {
        idleController?.beginControlOperation()
        defer { idleController?.endControlOperation() }

        var shouldSyncClock = false
        lock.lock()
        guard !terminalShutdown else {
            wakeTask = nil
            lock.unlock()
            return
        }
        if state == .sleeping, let currentHelper = helperProcess, currentHelper.isRunning {
            guard currentHelper.resume() else {
                lastError = TierError.resumeFailed(pid: currentHelper.pid).description
                wakeTask = nil
                lock.unlock()
                idleController?.setSleeping(true)
                return
            }
            lifecycleEpoch &+= 1
            let resumeEpoch = lifecycleEpoch
            readinessTracker.beginCycle(trigger: "resume")
            setStateLocked(.starting)
            lastError = nil
            lock.unlock()

            var readinessFailure: Error?
            do {
                readinessTracker.ready(
                    .vmProcess,
                    code: "vm.process_resumed",
                    detail: "resumed managed helper pid \(currentHelper.pid ?? 0)"
                )
                try validateGuestPrerequisites(helper: currentHelper)
                try validateDockerBackend(
                    helper: currentHelper,
                    epoch: resumeEpoch,
                    timeout: Self.resumeReadyTimeout
                )
                readinessTracker.begin(.hostSocketContext, deadlineSeconds: 2)
                readinessTracker.ready(
                    .hostSocketContext,
                    code: "socket.forwarder_retained",
                    detail: "existing wake-on-demand Docker socket remained bound"
                )
            } catch {
                readinessFailure = error
                readinessTracker.blockCurrent(
                    code: readinessReasonCode(for: error),
                    detail: "\(error)"
                )
            }

            lock.lock()
            let ownsCurrentHelper = helperProcess === currentHelper
            guard !terminalShutdown,
                  lifecycleEpoch == resumeEpoch,
                  state == .starting,
                  ownsCurrentHelper else {
                wakeTask = nil
                lock.unlock()
                return
            }
            if readinessFailure == nil, currentHelper.isRunning {
                setStateLocked(.running)
                helperStartedAt = Date()
                lastError = nil
                wakeTask = nil
                lifecycleStateObserver(.running)
                lock.unlock()
                idleController?.setSleeping(false)
                idleController?.touch()
                shouldSyncClock = true
                if shouldSyncClock {
                    _ = syncAgentClockAfterWake()
                }
                return
            }
            lastError = readinessFailure.map(String.init(describing:))
                ?? TierError.helperExited("exited while resuming").description
            setStateLocked(.sleeping)
            if !currentHelper.isRunning {
                helperProcess = nil
                activeHelperGeneration = nil
                helperStartedAt = nil
            }
            wakeTask = nil
            lock.unlock()
            idleController?.setSleeping(true)
            return
        }
        guard state == .sleeping else {
            wakeTask = nil
            lock.unlock()
            return
        }
        lifecycleEpoch &+= 1
        let wakeEpoch = lifecycleEpoch
        readinessTracker.beginCycle(trigger: "cold-wake")
        setStateLocked(.starting)
        lastError = nil
        lock.unlock()

        let (helper, helperGeneration) = makeFreshManagedProcess()
        do {
            lock.lock()
            guard !terminalShutdown,
                  lifecycleEpoch == wakeEpoch,
                  state == .starting else {
                wakeTask = nil
                lock.unlock()
                helper?.stop()
                return
            }
            // Publish before start(): daemon shutdown must be able to cancel the exact window
            // between an accepted engineWake and the helper's blocking handoff/readiness wait.
            helperProcess = helper
            activeHelperGeneration = helper == nil ? nil : helperGeneration
            lock.unlock()

            try helper?.start()
            guard freshLaunchIsActive(epoch: wakeEpoch, helper: helper) else {
                helper?.stop()
                return
            }

            readinessTracker.ready(
                .vmProcess,
                code: "vm.process_ready",
                detail: helper?.pid.map { "managed helper pid \($0) is running" } ?? "in-process backend is running"
            )
            try validateGuestPrerequisites(helper: helper)
            try validateDockerBackend(
                helper: helper,
                epoch: wakeEpoch,
                timeout: Self.freshStartReadyTimeout
            )
            readinessTracker.begin(.hostSocketContext, deadlineSeconds: 2)
            readinessTracker.ready(
                .hostSocketContext,
                code: "socket.forwarder_retained",
                detail: "existing wake-on-demand Docker socket remained bound"
            )

            lock.lock()
            let ownsHelper = helper.map { helperProcess === $0 } ?? (helperProcess == nil)
            guard !terminalShutdown,
                  lifecycleEpoch == wakeEpoch,
                  state == .starting,
                  ownsHelper else {
                wakeTask = nil
                lock.unlock()
                helper?.stop()
                return
            }
            if helper?.isRunning == true {
                helperProcess = helper
                setStateLocked(.running)
                helperStartedAt = Date()
                lastError = nil
                wakeTask = nil
                lifecycleStateObserver(.running)
                lock.unlock()
                idleController?.setSleeping(false)
                idleController?.touch()
                shouldSyncClock = true
                if shouldSyncClock {
                    _ = syncAgentClockAfterWake()
                }
            } else {
                lock.unlock()
                throw TierError.helperExited("exited while waking")
            }
        } catch {
            readinessTracker.blockCurrent(
                code: readinessReasonCode(for: error),
                detail: "\(error)"
            )
            helper?.stop()
            lock.lock()
            let ownsHelper = helper.map { helperProcess === $0 } ?? (helperProcess == nil)
            let ownsLifecycle = !terminalShutdown
                && lifecycleEpoch == wakeEpoch
                && state == .starting
                && ownsHelper
            if ownsLifecycle {
                helperProcess = nil
                activeHelperGeneration = nil
                helperStartedAt = nil
                setStateLocked(.sleeping)
                lastError = "\(error)"
                wakeTask = nil
            }
            lock.unlock()
            if ownsLifecycle {
                idleController?.setSleeping(true)
            }
        }
    }

    private func syncAgentClockAfterWake(timeout: TimeInterval = 5) -> AgentClockSyncResult {
        let deadline = Date().addingTimeInterval(timeout)
        var result = syncAgentClock()
        while result.attempted, !result.synced, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            result = syncAgentClock()
        }
        return result
    }

    private func makeFreshManagedProcess() -> ((any DockerManagedProcess)?, UUID) {
        let generation = UUID()
        let helper = makeManagedProcess(generation: generation)
        return (helper, generation)
    }

    private func makeManagedProcess(generation: UUID) -> (any DockerManagedProcess)? {
        let onUnexpectedTermination: HvProcessUnexpectedTerminationHandler = { [weak self] termination in
            self?.managedHelperExited(generation: generation, termination: termination)
        }
        if let vmmConfiguration = configuration.vmmProcess {
            return VmmDockerProcess(
                configuration: vmmConfiguration,
                unexpectedTerminationHandler: onUnexpectedTermination
            )
        }
        if var hvConfiguration = configuration.hvProcess {
            // The tier must rebuild the full helper + dataplane graph after a VM exit. Disable
            // HvProcess's local child-only retry so it cannot resurrect behind stale proxies.
            hvConfiguration.restartPolicy = .none
            return HvProcess(
                configuration: hvConfiguration,
                unexpectedTerminationHandler: onUnexpectedTermination
            )
        }
        return nil
    }

    private var managedRestartPolicy: HvRestartPolicy {
        configuration.hvProcess?.restartPolicy
            ?? configuration.vmmProcess?.restartPolicy
            ?? .none
    }

    private func reconcileManagedHelperLiveness() {
        guard configuration.hasManagedHelper else { return }
        let generation: UUID?
        let helper: (any DockerManagedProcess)?
        lock.lock()
        if state == .running {
            generation = activeHelperGeneration
            helper = helperProcess
        } else {
            generation = nil
            helper = nil
        }
        lock.unlock()

        guard let generation, helper?.isRunning != true else { return }
        handleManagedHelperLoss(
            generation: generation,
            detail: "is no longer running"
        )
    }

    private func managedHelperExited(generation: UUID, termination: HvProcessTermination) {
        handleManagedHelperLoss(
            generation: generation,
            detail: termination.description
        )
    }

    private func handleManagedHelperLoss(generation: UUID, detail: String) {
        let currentDataplane: DoryDataplaneHandle?
        let currentHelper: (any DockerManagedProcess)?
        let currentActivityServer: DataplaneActivityServer?
        let inFlightWake: Task<Void, Never>?
        let restart: DispatchWorkItem?
        let restartDelay: TimeInterval

        lock.lock()
        guard !terminalShutdown,
              state == .running,
              activeHelperGeneration == generation else {
            lock.unlock()
            return
        }

        let policy = managedRestartPolicy
        if policy.stableRunSeconds > 0,
           let helperStartedAt,
           Date().timeIntervalSince(helperStartedAt) >= policy.stableRunSeconds {
            unexpectedRestartCount = 0
        }
        unexpectedRestartCount += 1
        let attempt = unexpectedRestartCount
        let canRestart = attempt <= policy.maxRestarts

        lifecycleEpoch &+= 1
        let restartEpoch = lifecycleEpoch
        restartWorkItem?.cancel()
        currentDataplane = dataplane
        currentHelper = helperProcess
        currentActivityServer = activityServer
        inFlightWake = wakeTask
        dataplane = nil
        helperProcess = nil
        activityServer = nil
        wakeTask = nil
        activeHelperGeneration = nil
        helperStartedAt = nil
        idleController?.setSleeping(false)

        if canRestart {
            let item = DispatchWorkItem { [weak self] in
                self?.performScheduledRestart(epoch: restartEpoch)
            }
            restart = item
            restartWorkItem = item
            restartDelay = policy.delay(forAttempt: attempt)
            setStateLocked(.starting)
            lastError = "managed helper \(detail); restart attempt \(attempt)/\(policy.maxRestarts) queued"
        } else {
            restart = nil
            restartWorkItem = nil
            restartDelay = 0
            setStateLocked(.failed)
            lastError = "managed helper \(detail); automatic restart limit (\(policy.maxRestarts)) exhausted"
        }

        // Tear down every endpoint that could still accept a client before publishing a retry.
        // Keep the lifecycle lock through endpoint teardown so an explicit start cannot bind a new
        // socket that an old server's cleanup subsequently removes.
        inFlightWake?.cancel()
        removeRuntimeSockets()
        currentDataplane?.shutdown()
        currentActivityServer?.stop()
        agentControl?.disconnect()
        currentHelper?.stop()
        lock.unlock()

        if let restart {
            supervisorQueue.asyncAfter(deadline: .now() + restartDelay, execute: restart)
        }
    }

    private func performScheduledRestart(epoch: UInt64) {
        idleController?.beginControlOperation()
        defer { idleController?.endControlOperation() }

        lock.lock()
        guard lifecycleEpoch == epoch,
              !terminalShutdown,
              state == .starting,
              helperProcess == nil,
              restartWorkItem != nil else {
            lock.unlock()
            return
        }
        restartWorkItem = nil
        lock.unlock()

        do {
            cleanupStaleHelpers()
            readinessTracker.beginCycle(trigger: "automatic-recovery")
            try launchFreshTier(epoch: epoch, publishFailure: false)
        } catch TierError.startCancelled {
            return
        } catch {
            scheduleRecoveryAfterLaunchFailure(epoch: epoch, error: error)
        }
    }

    private func scheduleRecoveryAfterLaunchFailure(epoch: UInt64, error: Error) {
        let restart: DispatchWorkItem?
        let delay: TimeInterval

        lock.lock()
        guard !terminalShutdown,
              lifecycleEpoch == epoch,
              state == .starting else {
            lock.unlock()
            return
        }
        let policy = managedRestartPolicy
        if unexpectedRestartCount < policy.maxRestarts {
            unexpectedRestartCount += 1
            lifecycleEpoch &+= 1
            let nextEpoch = lifecycleEpoch
            let attempt = unexpectedRestartCount
            let item = DispatchWorkItem { [weak self] in
                self?.performScheduledRestart(epoch: nextEpoch)
            }
            restart = item
            restartWorkItem = item
            delay = policy.delay(forAttempt: attempt)
            setStateLocked(.starting)
            lastError = "restart attempt \(attempt - 1) failed: \(error); attempt \(attempt)/\(policy.maxRestarts) queued"
        } else {
            restart = nil
            restartWorkItem = nil
            delay = 0
            setStateLocked(.failed)
            lastError = "automatic restart limit (\(policy.maxRestarts)) exhausted after launch failure: \(error)"
        }
        lock.unlock()

        if let restart {
            supervisorQueue.asyncAfter(deadline: .now() + delay, execute: restart)
        }
    }

    private func removeRuntimeSockets() {
        unlink(socket.path)
        guard configuration.hasManagedHelper else { return }
        unlink(configuration.forwardSocketPath)
        if let dockerdSocketPath = configuration.dockerdSocketPath {
            unlink(dockerdSocketPath)
        }
        if let activitySocketPath = configuration.activitySocketPath {
            unlink(activitySocketPath)
        }
        if let handoffSocketPath = configuration.vmmProcess?.handoffSocketPath {
            unlink(handoffSocketPath)
        }
    }

    private func removeHostDataplaneSockets() {
        unlink(socket.path)
        if let activitySocketPath = configuration.activitySocketPath {
            unlink(activitySocketPath)
        }
    }

    private func startActivityServerIfNeeded() throws -> DataplaneActivityServer? {
        guard let idleController, let path = configuration.activitySocketPath else { return nil }
        let server = DataplaneActivityServer(path: path, idle: idleController) { [weak self] in
            await self?.ensureAwake()
        }
        try server.start()
        return server
    }

    private struct DataplaneResources {
        var handle: DoryDataplaneHandle
        var activityServer: DataplaneActivityServer?
    }

    private func startDataplane() throws -> DataplaneResources {
        beforeDataplaneStart()
        let server = try startActivityServerIfNeeded()
        do {
            let fd = try socket.bind()
            let handle: DoryDataplaneHandle
            if let dockerdSocketPath = configuration.dockerdSocketPath {
                if let activitySocketPath = configuration.activitySocketPath, idleController != nil {
                    handle = DoryCore.startDockerDataplane(
                        listenFD: fd,
                        dockerdSocketPath: dockerdSocketPath,
                        gpuSupported: configuration.gpuSupported,
                        activitySocketPath: activitySocketPath
                    )
                } else {
                    handle = DoryCore.startDockerDataplane(
                        listenFD: fd,
                        dockerdSocketPath: dockerdSocketPath,
                        gpuSupported: configuration.gpuSupported
                    )
                }
            } else {
                if let activitySocketPath = configuration.activitySocketPath, idleController != nil {
                    handle = DoryCore.startDockerForwardDataplane(
                        listenFD: fd,
                        forwardSocketPath: configuration.forwardSocketPath,
                        cid: configuration.cid,
                        port: configuration.dockerPort,
                        gpuSupported: configuration.gpuSupported,
                        activitySocketPath: activitySocketPath
                    )
                } else {
                    handle = DoryCore.startDockerForwardDataplane(
                        listenFD: fd,
                        forwardSocketPath: configuration.forwardSocketPath,
                        cid: configuration.cid,
                        port: configuration.dockerPort,
                        gpuSupported: configuration.gpuSupported
                    )
                }
            }
            return DataplaneResources(handle: handle, activityServer: server)
        } catch {
            server?.stop()
            throw error
        }
    }

    private func tearDown(
        markStopped: Bool,
        publishStoppedIntent: Bool = false,
        extraHelper: (any DockerManagedProcess)? = nil
    ) {
        let currentDataplane: DoryDataplaneHandle?
        let currentHelper: (any DockerManagedProcess)?
        let currentActivityServer: DataplaneActivityServer?
        let inFlightWake: Task<Void, Never>?
        let queuedRestart: DispatchWorkItem?
        lock.lock()
        lifecycleEpoch &+= 1
        currentDataplane = dataplane
        currentHelper = helperProcess ?? extraHelper
        currentActivityServer = activityServer
        inFlightWake = wakeTask
        queuedRestart = restartWorkItem
        dataplane = nil
        helperProcess = nil
        activityServer = nil
        wakeTask = nil
        restartWorkItem = nil
        activeHelperGeneration = nil
        helperStartedAt = nil
        if markStopped {
            setStateLocked(.stopped)
            unexpectedRestartCount = 0
            lastError = nil
            idleController?.setSleeping(false)
            if publishStoppedIntent, !terminalShutdown {
                lifecycleStateObserver(.stopped)
            }
        }

        // Cancel any in-flight wake so it stops resuming; it also re-checks state under
        // the lock and discards a freshly started helper now that state != .sleeping.
        inFlightWake?.cancel()
        queuedRestart?.cancel()

        // Keep lifecycle ownership until every old endpoint is gone. Releasing this lock after
        // publishing `.stopped` would let a concurrent start bind replacement sockets that this
        // older teardown could subsequently unlink.
        removeRuntimeSockets()
        currentDataplane?.shutdown()
        currentActivityServer?.stop()
        agentControl?.disconnect()
        currentHelper?.stop()
        lock.unlock()
        if markStopped {
            readinessTracker.markStopped(detail: "engine was explicitly stopped")
        }
    }

    deinit {
        stop()
    }
}

extension DockerTier: HostSleepHandling, WakeClockSyncing {}

private extension UInt64 {
    func saturatingAdding(_ other: UInt64) -> UInt64 {
        let result = addingReportingOverflow(other)
        return result.overflow ? .max : result.partialValue
    }

    func saturatingSubtracting(_ other: UInt64) -> UInt64 {
        self > other ? self - other : 0
    }

    func saturatingMultiplying(by other: UInt64) -> UInt64 {
        let result = multipliedReportingOverflow(by: other)
        return result.overflow ? .max : result.partialValue
    }
}
