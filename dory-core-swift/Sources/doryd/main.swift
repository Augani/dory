import DoryCore
import DorydKit
import Darwin
import Foundation

// doryd: bind ~/.dory/dory.sock (0600), serve the control XPC MachService,
// and run forever under launchd. Bind failure is fatal; launchd owns restart.
let machServiceName = "dev.dory.doryd"

// Docker clients routinely close request/attach streams as soon as they have enough response data.
// Treat those as ordinary EPIPEs in the Rust dataplane instead of letting SIGPIPE terminate doryd.
_ = signal(SIGPIPE, SIG_IGN)

let env = ProcessInfo.processInfo.environment
let dorydEnvironment = DorydEnvironment(values: env)
let dataDriveSelectionAuthority: DoryDataDriveSelectionAuthority
do {
    let requestedDrive = try dorydEnvironment.dataDriveConfiguration()
    let selectionStore = try DoryDataDriveSelectionStore(home: dorydEnvironment.home)
    dataDriveSelectionAuthority = try selectionStore.acquireAuthority()
    let drive = try selectionStore.prepareSelection(
        requestedRoot: requestedDrive.root,
        authority: dataDriveSelectionAuthority
    )
    let driveID = try drive.readManifest().id.uuidString.lowercased()
    FileHandle.standardError.write(
        Data("doryd: data drive \(driveID) ready at \(drive.root)\n".utf8)
    )
} catch {
    FileHandle.standardError.write(Data("doryd: data drive unavailable: \(error)\n".utf8))
    exit(1)
}
let socket = DorySocket(home: dorydEnvironment.home)
let hostCLIInstaller = HostCLIInstaller(environment: dorydEnvironment, dockerSocketPath: socket.path)
let hostCLIReconciler: HostCLIReconciler?
if dorydEnvironment.hostCLIEnabled {
    let reconciler = HostCLIReconciler(
        installer: hostCLIInstaller,
        interval: dorydEnvironment.hostCLIReconcileIntervalSeconds
    )
    let cliInstall = reconciler.reconcileNow()
    if cliInstall.dockerLinked {
        FileHandle.standardError.write(Data("doryd: host CLI ready in \(dorydEnvironment.home)/.dory/bin\n".utf8))
    } else if !cliInstall.missing.isEmpty {
        FileHandle.standardError.write(Data("doryd: host CLI incomplete, missing \(cliInstall.missing.joined(separator: ","))\n".utf8))
    }
    if let contextError = cliInstall.dockerContextError {
        FileHandle.standardError.write(Data("doryd: docker context not reconciled: \(contextError)\n".utf8))
    }
    reconciler.start()
    hostCLIReconciler = reconciler
} else {
    let removal = hostCLIInstaller.remove()
    if !removal.removed.isEmpty || removal.pathProfileChanged
        || removal.composePluginRemoved || removal.buildxPluginRemoved {
        FileHandle.standardError.write(Data("doryd: host CLI integration disabled and removed from \(dorydEnvironment.home)/.dory/bin\n".utf8))
    } else {
        FileHandle.standardError.write(Data("doryd: host CLI integration disabled by settings\n".utf8))
    }
    hostCLIReconciler = nil
}
let idleController = IdleController()
let dockerTier = dorydEnvironment.dockerTierConfiguration().map {
    DockerTier(configuration: $0, idleController: idleController)
}
let machineManager = dorydEnvironment.machineManagerConfiguration().map { MachineManager(configuration: $0) }
let remoteManager = RemoteMachineManager()
let networkingConfiguration = dorydEnvironment.networkingConfiguration()
let networkingController = networkingConfiguration.map(NetworkingController.init(configuration:))
let kubernetesRouteProvider = networkingController.map { _ in
    KubernetesServiceRouteProvider(configuration: dorydEnvironment.kubernetesServiceRouteProviderConfiguration())
}
let incidentPath = env["DORY_INCIDENTS"] ?? "\(dorydEnvironment.home)/.dory/incidents.jsonl"
let incidentWriter = IncidentWriter(path: incidentPath)
let networkRouteReconciler = networkingController.map { controller in
    NetworkRouteReconciler(
        networkingController: controller,
        suffix: networkingConfiguration?.suffix ?? "dory.local",
        containerProvider: {
            dockerTier?.containerSummariesForIdle() ?? .ok([])
        },
        machineProvider: {
            machineManager?.list() ?? []
        },
        additionalRouteProvider: { suffix in
            kubernetesRouteProvider?.routes(suffix: suffix) ?? []
        },
        interval: dorydEnvironment.networkRouteReconcileIntervalSeconds
    )
}
let dnsTargets = wakeDNSProbeTargets(env["DORYD_WAKE_DNS_PROBES"])
let idlePolicyStore = IdlePolicyStore(home: dorydEnvironment.home, environment: env) {
    dockerTier?.containerSummariesForIdle() ?? .ok([])
}
var sleepHandlers: [HostSleepHandling] = []
var clockSyncers: [WakeClockSyncing] = []
if let dockerTier {
    sleepHandlers.append(PolicyAwareHostSleepHandler(
        name: "docker",
        handler: dockerTier,
        shouldAttemptSleep: {
            idlePolicyStore.managedEngineSleepEnabled()
        }
    ))
    clockSyncers.append(dockerTier)
}
if let machineManager {
    clockSyncers.append(machineManager)
}
let wakeCoordinator = HostWakeCoordinator(
    sleepHandlers: sleepHandlers,
    clockSyncers: clockSyncers,
    dnsProbe: SystemDNSProbe(targets: dnsTargets),
    incidentWriter: incidentWriter
)
let socketPath = dockerTier?.socketPath ?? socket.path
let shouldAutostartDockerTier = DockerTierStartupPolicy.shouldAutostartDockerTier(
    environment: env,
    persistedRuntimeMode: idlePolicyStore.currentRuntimeMode(),
    persistedEngineDesiredState: idlePolicyStore.currentEngineDesiredState()
)
let idleSleepScheduler = dockerTier.flatMap { tier -> IdleSleepScheduler? in
    guard let baseConfiguration = dorydEnvironment.idleSleepConfiguration() else { return nil }
    return IdleSleepScheduler(
        dockerTier: tier,
        configuration: idlePolicyStore.schedulerConfiguration(base: baseConfiguration),
        canAttemptSleep: {
            idlePolicyStore.canSleepNow()
        },
        incidentWriter: incidentWriter
    )
}

let repairRoutes: (@Sendable () -> Int)?
if let networkRouteReconciler {
    repairRoutes = { networkRouteReconciler.reconcileNow().count }
} else {
    repairRoutes = nil
}
let service = DorydService(
    socketPath: socketPath,
    dockerTier: dockerTier,
    machineManager: machineManager,
    remoteManager: remoteManager,
    networkingController: networkingController,
    networkRouteRepair: repairRoutes,
    idlePolicyStore: idlePolicyStore,
    idleSleepScheduler: idleSleepScheduler,
    incidentWriter: incidentWriter
)
let delegate = DorydListenerDelegate(service: service)
let listener = NSXPCListener(machServiceName: machServiceName)
listener.delegate = delegate

private let shutdownCoordinator = DorydShutdownCoordinator(
    listener: listener,
    hostCLIReconciler: hostCLIReconciler,
    idleSleepScheduler: idleSleepScheduler,
    wakeCoordinator: wakeCoordinator,
    networkRouteReconciler: networkRouteReconciler,
    kubernetesRouteProvider: kubernetesRouteProvider,
    networkingController: networkingController,
    dockerTier: dockerTier,
    machineManager: machineManager,
    remoteManager: remoteManager,
    dataDriveSelectionAuthority: dataDriveSelectionAuthority
)
private let signalQueue = DispatchQueue(label: "dev.dory.doryd.signal-shutdown", qos: .userInitiated)
private let signalSources = installSignalHandlers(
    shutdownCoordinator: shutdownCoordinator,
    queue: signalQueue
)

// Install termination handling before the first managed helper is started. Docker boot and VMM
// handoff are deliberately synchronous, so a main-queue signal source would not run while either
// wait is blocked. The dedicated signal queue cancels that startup through DockerTier.stop(), and
// the tier publishes its in-flight helper early enough for the shutdown to reap it.
if dockerTier == nil {
    let socketFD: Int32
    do {
        socketFD = try socket.bind()
    } catch {
        shutdownCoordinator.run(reason: "could not bind \(socket.path): \(error)", exitCode: 1)
    }
    _ = socketFD
    FileHandle.standardError.write(Data("doryd: bound \(socket.path)\n".utf8))
} else if shouldAutostartDockerTier {
    do {
        try dockerTier?.start()
        FileHandle.standardError.write(Data("doryd: docker tier serving \(socketPath)\n".utf8))
    } catch {
        shutdownCoordinator.run(reason: "could not start docker tier: \(error)", exitCode: 1)
    }
} else {
    do {
        try dockerTier?.armSleeping()
        FileHandle.standardError.write(Data("doryd: docker tier sleeping at \(socketPath)\n".utf8))
    } catch {
        shutdownCoordinator.run(reason: "could not arm docker tier socket: \(error)", exitCode: 1)
    }
}

// If SIGTERM/SIGINT raced the final return from startup, wait for the signal queue's cleanup and
// exit instead of publishing XPC or starting another service after shutdown began.
shutdownCoordinator.exitIfRequested()

listener.resume()
FileHandle.standardError.write(Data("doryd: serving XPC \(machServiceName)\n".utf8))

if let idleSleepScheduler {
    idleSleepScheduler.start()
    let idleConfiguration = idleSleepScheduler.currentConfiguration
    if idleConfiguration.enabled {
        FileHandle.standardError.write(Data("doryd: idle sleep after \(Int(idleConfiguration.idleAfterSeconds))s\n".utf8))
    } else {
        FileHandle.standardError.write(Data("doryd: idle sleep disabled by policy\n".utf8))
    }
}

do {
    try wakeCoordinator.start()
    FileHandle.standardError.write(Data("doryd: observing host sleep/wake\n".utf8))
} catch {
    incidentWriter.record(type: "host.wake_observer_failed", detail: "\(error)")
    FileHandle.standardError.write(Data("doryd: host wake observer unavailable: \(error)\n".utf8))
}

if let networkingController {
    do {
        try networkingController.start()
        let routeCount = networkRouteReconciler?.reconcileNow().count ?? 0
        networkRouteReconciler?.start()
        let status = networkingController.status()
        FileHandle.standardError.write(Data("doryd: DNS serving \(status.suffix) on \(status.dnsBindAddress):\(status.dnsPort), \(routeCount) route(s)\n".utf8))
    } catch {
        incidentWriter.record(type: "network.dns_failed", detail: "\(error)")
        FileHandle.standardError.write(Data("doryd: DNS unavailable: \(error)\n".utf8))
    }
}

dispatchMain()

private final class DorydShutdownCoordinator {
    private let listener: NSXPCListener
    private let hostCLIReconciler: HostCLIReconciler?
    private let idleSleepScheduler: IdleSleepScheduler?
    private let wakeCoordinator: HostWakeCoordinator
    private let networkRouteReconciler: NetworkRouteReconciler?
    private let kubernetesRouteProvider: KubernetesServiceRouteProvider?
    private let networkingController: NetworkingController?
    private let dockerTier: DockerTier?
    private let machineManager: MachineManager?
    private let remoteManager: RemoteMachineManager
    private let dataDriveSelectionAuthority: DoryDataDriveSelectionAuthority
    private let condition = NSCondition()
    private enum State {
        case active
        case shuttingDown
        case finished
    }
    private var state: State = .active
    private var finalExitCode: Int32 = 0

    init(
        listener: NSXPCListener,
        hostCLIReconciler: HostCLIReconciler?,
        idleSleepScheduler: IdleSleepScheduler?,
        wakeCoordinator: HostWakeCoordinator,
        networkRouteReconciler: NetworkRouteReconciler?,
        kubernetesRouteProvider: KubernetesServiceRouteProvider?,
        networkingController: NetworkingController?,
        dockerTier: DockerTier?,
        machineManager: MachineManager?,
        remoteManager: RemoteMachineManager,
        dataDriveSelectionAuthority: DoryDataDriveSelectionAuthority
    ) {
        self.listener = listener
        self.hostCLIReconciler = hostCLIReconciler
        self.idleSleepScheduler = idleSleepScheduler
        self.wakeCoordinator = wakeCoordinator
        self.networkRouteReconciler = networkRouteReconciler
        self.kubernetesRouteProvider = kubernetesRouteProvider
        self.networkingController = networkingController
        self.dockerTier = dockerTier
        self.machineManager = machineManager
        self.remoteManager = remoteManager
        self.dataDriveSelectionAuthority = dataDriveSelectionAuthority
    }

    func run(reason: String, exitCode: Int32 = 0) -> Never {
        condition.lock()
        guard state == .active else {
            while state != .finished {
                condition.wait()
            }
            let completedExitCode = finalExitCode
            condition.unlock()
            exit(completedExitCode)
        }
        state = .shuttingDown
        finalExitCode = exitCode
        condition.unlock()

        FileHandle.standardError.write(Data("doryd: shutting down (\(reason))\n".utf8))
        // Set the one-way tier latch before listener invalidation. Already-accepted XPC work may
        // still be executing, but no engineStart/engineWake can spawn or resume a helper once this
        // call begins; ordinary engineStop continues to use the reversible stop() path.
        dockerTier?.shutdown()
        listener.invalidate()
        hostCLIReconciler?.stop()
        idleSleepScheduler?.stop()
        wakeCoordinator.stop()
        networkRouteReconciler?.stop()
        kubernetesRouteProvider?.stop()
        networkingController?.stop()
        remoteManager.disconnectAll()
        machineManager?.stopAll()
        FileHandle.standardError.write(Data("doryd: shutdown complete\n".utf8))

        condition.lock()
        state = .finished
        condition.broadcast()
        let completedExitCode = finalExitCode
        condition.unlock()
        exit(completedExitCode)
    }

    func exitIfRequested() {
        condition.lock()
        guard state != .active else {
            condition.unlock()
            return
        }
        while state != .finished {
            condition.wait()
        }
        let completedExitCode = finalExitCode
        condition.unlock()
        exit(completedExitCode)
    }
}

private func installSignalHandlers(
    shutdownCoordinator: DorydShutdownCoordinator,
    queue: DispatchQueue
) -> [DispatchSourceSignal] {
    [SIGTERM, SIGINT].map { signalNumber in
        _ = signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
        source.setEventHandler {
            shutdownCoordinator.run(reason: signalNumber == SIGTERM ? "SIGTERM" : "SIGINT")
        }
        source.resume()
        return source
    }
}

private func wakeDNSProbeTargets(_ raw: String?) -> [DNSProbeTarget] {
    guard let raw, !raw.isEmpty else {
        return [DNSProbeTarget(host: "registry-1.docker.io", port: 443)]
    }
    let parsed = raw
        .split(separator: ",")
        .compactMap { item -> DNSProbeTarget? in
            let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
            guard let host = parts.first, !host.isEmpty else { return nil }
            let port = parts.count == 2 ? UInt16(parts[1]) ?? 443 : 443
            return DNSProbeTarget(host: host, port: port)
        }
    return parsed.isEmpty ? [DNSProbeTarget(host: "registry-1.docker.io", port: 443)] : parsed
}
