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
                state = .sleeping
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
        state = .starting
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
            state = .sleeping
            wakeTask = nil
            activeHelperGeneration = nil
            helperStartedAt = nil
            lastError = nil
            idleController?.setSleeping(true)
            lock.unlock()
        } catch {
            lock.lock()
            let terminallyCancelled = terminalShutdown
            let ownsLifecycle = !terminallyCancelled
                && lifecycleEpoch == armEpoch
                && state == .starting
            if ownsLifecycle {
                state = .failed
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
        state = .starting
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
                break
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
            Thread.sleep(forTimeInterval: 0.05)
        }
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

            if configuration.hasManagedHelper {
                let ready = dockerReadyWaiter(configuration, Self.freshStartReadyTimeout) {
                    self.freshLaunchIsActive(epoch: epoch, helper: helper)
                        && helper?.isRunning == true
                }
                guard freshLaunchIsActive(epoch: epoch, helper: helper) else {
                    throw TierError.startCancelled
                }
                guard helper?.isRunning == true else {
                    throw TierError.helperExited("exited during startup")
                }
                guard ready else {
                    throw TierError.readyTimeout
                }
            }

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
            state = .running
            lastError = nil
            idleController?.setSleeping(false)
            lock.unlock()
            startedResources = nil
        } catch {
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
                state = publishFailure ? .failed : .starting
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
        tearDown(markStopped: true)
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
        state = .stopped
        lastError = nil
        lock.unlock()

        queuedRestart.cancel()
        removeRuntimeSockets()
        do {
            try armSleeping()
            return true
        } catch {
            lock.lock()
            state = .failed
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
        state = .sleeping
        wakeTask = nil

        switch activity {
        case .empty:
            helperProcess = nil
            activeHelperGeneration = nil
            helperStartedAt = nil
            lastError = nil
            agentControl?.disconnect()
            currentHelper.stop()
            lock.unlock()
            return true
        case .active, .unknown:
            agentControl?.disconnect()
            guard currentHelper.suspend() else {
                state = .running
                lastError = TierError.suspendFailed(pid: currentHelper.pid).description
                lock.unlock()
                idleController.setSleeping(false)
                return false
            }
            lastError = nil
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

    public func telemetry() throws -> DoryTelemetry? {
        guard let agentControl else { return nil }
        lock.lock()
        let currentState = state
        lock.unlock()
        guard currentState == .running else { return nil }
        return try agentControl.telemetry()
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
        guard let task = wakeTaskForEnsureAwake() else { return }
        await task.value
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
            state = .starting
            lastError = nil
            lock.unlock()

            let ready = dockerReadyWaiter(configuration, Self.resumeReadyTimeout) {
                self.freshLaunchIsActive(epoch: resumeEpoch, helper: currentHelper)
                    && currentHelper.isRunning
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
            if ready, currentHelper.isRunning {
                state = .running
                helperStartedAt = Date()
                lastError = nil
                wakeTask = nil
                lock.unlock()
                idleController?.setSleeping(false)
                idleController?.touch()
                shouldSyncClock = true
                if shouldSyncClock {
                    _ = syncAgentClockAfterWake()
                }
                return
            }
            lastError = ready
                ? TierError.helperExited("exited while resuming").description
                : TierError.readyTimeout.description
            state = .sleeping
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
        state = .starting
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

            let ready = dockerReadyWaiter(configuration, Self.freshStartReadyTimeout) {
                self.freshLaunchIsActive(epoch: wakeEpoch, helper: helper)
                    && helper?.isRunning == true
            }

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
            if ready, helper?.isRunning == true {
                helperProcess = helper
                state = .running
                helperStartedAt = Date()
                lastError = nil
                wakeTask = nil
                lock.unlock()
                idleController?.setSleeping(false)
                idleController?.touch()
                shouldSyncClock = true
                if shouldSyncClock {
                    _ = syncAgentClockAfterWake()
                }
            } else {
                helperProcess = nil
                activeHelperGeneration = nil
                helperStartedAt = nil
                state = .sleeping
                lastError = ready
                    ? TierError.helperExited("exited while waking").description
                    : TierError.readyTimeout.description
                wakeTask = nil
                lock.unlock()
                helper?.stop()
                idleController?.setSleeping(true)
            }
        } catch {
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
                state = .sleeping
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
            state = .starting
            lastError = "managed helper \(detail); restart attempt \(attempt)/\(policy.maxRestarts) queued"
        } else {
            restart = nil
            restartWorkItem = nil
            restartDelay = 0
            state = .failed
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
            state = .starting
            lastError = "restart attempt \(attempt - 1) failed: \(error); attempt \(attempt)/\(policy.maxRestarts) queued"
        } else {
            restart = nil
            restartWorkItem = nil
            delay = 0
            state = .failed
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

    private func tearDown(markStopped: Bool, extraHelper: (any DockerManagedProcess)? = nil) {
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
            state = .stopped
            unexpectedRestartCount = 0
            lastError = nil
            idleController?.setSleeping(false)
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
    }

    deinit {
        stop()
    }
}

extension DockerTier: HostSleepHandling, WakeClockSyncing {}
