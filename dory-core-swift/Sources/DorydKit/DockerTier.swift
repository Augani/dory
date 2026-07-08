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
    public var cid: UInt32
    public var dockerPort: UInt32
    public var gpuSupported: Bool
    public var activitySocketPath: String?
    public var hvProcess: HvProcessConfiguration?
    public var agentControl: AgentControlConfiguration?

    public init(
        home: String = NSHomeDirectory(),
        forwardSocketPath: String,
        cid: UInt32 = 3,
        dockerPort: UInt32 = 1026,
        gpuSupported: Bool = false,
        activitySocketPath: String? = nil,
        hvProcess: HvProcessConfiguration? = nil,
        agentControl: AgentControlConfiguration? = nil
    ) {
        self.home = home
        self.forwardSocketPath = forwardSocketPath
        self.cid = cid
        self.dockerPort = dockerPort
        self.gpuSupported = gpuSupported
        self.activitySocketPath = activitySocketPath
        self.hvProcess = hvProcess
        self.agentControl = agentControl
    }
}

public typealias DockerContainerActivityProbe = @Sendable (DockerTierConfiguration) -> DockerContainerActivity
public typealias DockerReadyWaiter = @Sendable (DockerTierConfiguration, TimeInterval) -> Bool

public final class DockerTier: @unchecked Sendable {
    public enum TierError: Error, CustomStringConvertible {
        case alreadyRunning
        case sleepingDataplaneRequiresWakeSupport
        case suspendFailed(pid: Int32?)
        case resumeFailed(pid: Int32?)
        case readyTimeout

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
            }
        }
    }

    private let configuration: DockerTierConfiguration
    private let containerActivityProbe: DockerContainerActivityProbe
    private let dockerReadyWaiter: DockerReadyWaiter
    private let socket: DorySocket
    private let idleController: IdleController?
    private let agentControl: AgentControl?
    private let portPublisher: PortPublisher?
    private let lock = NSLock()
    private var dataplane: DoryDataplaneHandle?
    private var activityServer: DataplaneActivityServer?
    private var hvProcess: HvProcess?
    private var state: DockerTierState = .stopped
    private var lastError: String?
    private var wakeTask: Task<Void, Never>?

    public init(
        configuration: DockerTierConfiguration,
        idleController: IdleController? = nil,
        agentControl injectedAgentControl: AgentControl? = nil,
        portPublisher injectedPortPublisher: PortPublisher? = nil,
        containerActivityProbe: @escaping DockerContainerActivityProbe = { configuration in
            DockerEngineProbe.containerActivity(
                forwardSocketPath: configuration.forwardSocketPath,
                cid: configuration.cid,
                dockerPort: configuration.dockerPort
            )
        },
        dockerReadyWaiter: @escaping DockerReadyWaiter = { configuration, timeout in
            DockerEngineProbe.waitUntilReady(
                forwardSocketPath: configuration.forwardSocketPath,
                cid: configuration.cid,
                dockerPort: configuration.dockerPort,
                timeout: timeout
            )
        }
    ) {
        self.configuration = configuration
        self.containerActivityProbe = containerActivityProbe
        self.dockerReadyWaiter = dockerReadyWaiter
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
        lock.lock()
        defer { lock.unlock() }
        return DockerTierStatus(
            state: state,
            socketPath: socket.path,
            hvPID: hvProcess?.pid,
            lastError: lastError
        )
    }

    /// Publish the Docker socket and activity listener without starting the heavy VM.
    ///
    /// This is doryd's default launch shape for auto-idle: Docker clients can connect to
    /// `dory.sock`, and the first meaningful request asks the activity server to wake a helper.
    public func armSleeping() throws {
        idleController?.beginControlOperation()
        defer { idleController?.endControlOperation() }

        lock.lock()
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
              configuration.hvProcess != nil else {
            lock.unlock()
            throw TierError.sleepingDataplaneRequiresWakeSupport
        }
        state = .starting
        lastError = nil
        lock.unlock()

        do {
            let resources = try startDataplane()
            lock.lock()
            dataplane = resources.handle
            activityServer = resources.activityServer
            hvProcess = nil
            state = .sleeping
            wakeTask = nil
            lastError = nil
            idleController?.setSleeping(true)
            lock.unlock()
        } catch {
            tearDown(markStopped: false)
            lock.lock()
            state = .failed
            lastError = "\(error)"
            lock.unlock()
            idleController?.setSleeping(false)
            throw error
        }
    }

    public func start() throws {
        idleController?.beginControlOperation()
        defer { idleController?.endControlOperation() }

        lock.lock()
        if dataplane != nil {
            if state == .sleeping {
                lock.unlock()
                wakeSynchronously()
                return
            }
            lock.unlock()
            throw TierError.alreadyRunning
        }
        state = .starting
        lastError = nil
        lock.unlock()

        var startedHv: HvProcess?
        do {
            let hv = configuration.hvProcess.map(HvProcess.init(configuration:))
            try hv?.start()
            startedHv = hv

            let resources = try startDataplane()

            lock.lock()
            hvProcess = hv
            activityServer = resources.activityServer
            dataplane = resources.handle
            state = .running
            idleController?.setSleeping(false)
            lock.unlock()
        } catch {
            tearDown(markStopped: false, extraHv: startedHv)
            lock.lock()
            state = .failed
            lastError = "\(error)"
            lock.unlock()
            throw error
        }
    }

    public func stop() {
        idleController?.beginControlOperation()
        defer { idleController?.endControlOperation() }
        tearDown(markStopped: true)
    }

    @discardableResult
    public func cleanupStaleHelpers() -> [Int32] {
        guard let hvConfiguration = configuration.hvProcess,
              let stateDirectory = HelperProcessJanitor.stateDirectoryArgument(
                in: ([hvConfiguration.executablePath] + hvConfiguration.arguments).joined(separator: " ")
              ) else {
            return []
        }
        return HelperProcessJanitor.terminateStaleHelpers(
            executablePath: hvConfiguration.executablePath,
            stateDirectory: stateDirectory
        )
    }

    public func sleepForIdle(idleAfter seconds: TimeInterval, now: Date = Date()) -> Bool {
        sleepForIdle(idleAfter: seconds, now: now, activity: containerActivityProbe(configuration))
    }

    private func sleepForIdle(
        idleAfter seconds: TimeInterval,
        now: Date,
        activity: DockerContainerActivity
    ) -> Bool {
        guard let idleController, configuration.hvProcess != nil else {
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
        guard state == .running, let currentHv = hvProcess else {
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
            hvProcess = nil
            lastError = nil
            agentControl?.disconnect()
            currentHv.stop()
            lock.unlock()
            return true
        case .active, .unknown:
            agentControl?.disconnect()
            guard currentHv.suspend() else {
                state = .running
                lastError = TierError.suspendFailed(pid: currentHv.pid).description
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

    public func currentPublishedPorts() -> [DoryListenPort]? {
        guard let portPublisher else { return nil }
        return portPublisher.current
    }

    public func currentDockerPublishedPorts() -> [DoryListenPort]? {
        lock.lock()
        let currentState = state
        lock.unlock()
        guard currentState == .running else { return [] }

        switch DockerEngineProbe.containerSummaries(
            forwardSocketPath: configuration.forwardSocketPath,
            cid: configuration.cid,
            dockerPort: configuration.dockerPort
        ) {
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
            canBalloon: configuration.hvProcess != nil
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
        if state != .sleeping {
            lock.unlock()
            return nil
        }
        if let wakeTask {
            lock.unlock()
            return wakeTask
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
        if state == .sleeping, let currentHv = hvProcess, currentHv.isRunning {
            guard currentHv.resume() else {
                lastError = TierError.resumeFailed(pid: currentHv.pid).description
                wakeTask = nil
                lock.unlock()
                idleController?.setSleeping(true)
                return
            }
            if dockerReadyWaiter(configuration, 10) {
                state = .running
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
            lastError = TierError.readyTimeout.description
            wakeTask = nil
            lock.unlock()
            idleController?.setSleeping(true)
            return
        }
        lock.unlock()

        do {
            let hv = try startFreshHvProcess()
            lock.lock()
            if dockerReadyWaiter(configuration, 45) {
                hvProcess = hv
                state = .running
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
                hvProcess = nil
                state = .sleeping
                lastError = TierError.readyTimeout.description
                wakeTask = nil
                hv?.stop()
                lock.unlock()
                idleController?.setSleeping(true)
            }
        } catch {
            lock.lock()
            state = .sleeping
            lastError = "\(error)"
            wakeTask = nil
            lock.unlock()
            idleController?.setSleeping(true)
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

    private func startFreshHvProcess() throws -> HvProcess? {
        guard let hvConfiguration = configuration.hvProcess else { return nil }
        let hv = HvProcess(configuration: hvConfiguration)
        try hv.start()
        return hv
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
        let server = try startActivityServerIfNeeded()
        do {
            let fd = try socket.bind()
            let handle: DoryDataplaneHandle
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
            return DataplaneResources(handle: handle, activityServer: server)
        } catch {
            server?.stop()
            throw error
        }
    }

    private func tearDown(markStopped: Bool, extraHv: HvProcess? = nil) {
        let currentDataplane: DoryDataplaneHandle?
        let currentHv: HvProcess?
        let currentActivityServer: DataplaneActivityServer?
        lock.lock()
        currentDataplane = dataplane
        currentHv = hvProcess ?? extraHv
        currentActivityServer = activityServer
        dataplane = nil
        hvProcess = nil
        activityServer = nil
        wakeTask = nil
        if markStopped {
            state = .stopped
            idleController?.setSleeping(false)
        }
        lock.unlock()

        currentDataplane?.shutdown()
        currentActivityServer?.stop()
        agentControl?.disconnect()
        currentHv?.stop()
        unlink(socket.path)
    }

    deinit {
        stop()
    }
}

extension DockerTier: HostSleepHandling, WakeClockSyncing {}
