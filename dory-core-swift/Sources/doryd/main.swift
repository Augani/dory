import DorydKit
import Darwin
import Foundation

// doryd: bind ~/.dory/dory.sock (0600), serve the control XPC MachService,
// and run forever under launchd. Bind failure is fatal; launchd owns restart.
let machServiceName = "dev.dory.doryd"

// Docker clients routinely close request/attach streams as soon as they have enough response data.
// Treat those as ordinary EPIPEs in the Rust dataplane instead of letting SIGPIPE terminate doryd.
_ = signal(SIGPIPE, SIG_IGN)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("doryd: \(message)\n".utf8))
    exit(1)
}

let env = ProcessInfo.processInfo.environment
let dorydEnvironment = DorydEnvironment(values: env)
let socket = DorySocket(home: dorydEnvironment.home)
let idleController = IdleController()
let dockerTier = dorydEnvironment.dockerTierConfiguration().map {
    DockerTier(configuration: $0, idleController: idleController)
}
let machineManager = dorydEnvironment.machineManagerConfiguration().map { MachineManager(configuration: $0) }
let remoteManager = RemoteMachineManager()
let networkingController = dorydEnvironment.networkingConfiguration().map(NetworkingController.init(configuration:))
let incidentPath = env["DORY_INCIDENTS"] ?? "\(dorydEnvironment.home)/.dory/incidents.jsonl"
let incidentWriter = IncidentWriter(path: incidentPath)
let dnsTargets = wakeDNSProbeTargets(env["DORYD_WAKE_DNS_PROBES"])
var sleepHandlers: [HostSleepHandling] = []
var clockSyncers: [WakeClockSyncing] = []
if let dockerTier {
    sleepHandlers.append(dockerTier)
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
if dockerTier == nil {
    let socketFD: Int32
    do {
        socketFD = try socket.bind()
    } catch {
        fail("could not bind \(socket.path): \(error)")
    }
    _ = socketFD
    FileHandle.standardError.write(Data("doryd: bound \(socket.path)\n".utf8))
} else if env["DORYD_AUTOSTART_DOCKER_TIER"] == "1" {
    do {
        try dockerTier?.start()
        FileHandle.standardError.write(Data("doryd: docker tier serving \(socketPath)\n".utf8))
    } catch {
        fail("could not start docker tier: \(error)")
    }
} else {
    do {
        try dockerTier?.armSleeping()
        FileHandle.standardError.write(Data("doryd: docker tier sleeping at \(socketPath)\n".utf8))
    } catch {
        fail("could not arm docker tier socket: \(error)")
    }
}

let idlePolicyStore = IdlePolicyStore(home: dorydEnvironment.home, environment: env) {
    dockerTier?.containerSummariesForIdle() ?? .ok([])
}
let idleSleepScheduler = dockerTier.flatMap { tier -> IdleSleepScheduler? in
    guard let baseConfiguration = dorydEnvironment.idleSleepConfiguration() else { return nil }
    return IdleSleepScheduler(
        dockerTier: tier,
        configuration: idlePolicyStore.schedulerConfiguration(base: baseConfiguration),
        incidentWriter: incidentWriter
    )
}

let service = DorydService(
    socketPath: socketPath,
    dockerTier: dockerTier,
    machineManager: machineManager,
    remoteManager: remoteManager,
    networkingController: networkingController,
    idlePolicyStore: idlePolicyStore,
    idleSleepScheduler: idleSleepScheduler,
    incidentWriter: incidentWriter
)
let delegate = DorydListenerDelegate(service: service)
let listener = NSXPCListener(machServiceName: machServiceName)
listener.delegate = delegate
listener.resume()
FileHandle.standardError.write(Data("doryd: serving XPC \(machServiceName)\n".utf8))

private let shutdownCoordinator = DorydShutdownCoordinator(
    listener: listener,
    idleSleepScheduler: idleSleepScheduler,
    wakeCoordinator: wakeCoordinator,
    networkingController: networkingController,
    dockerTier: dockerTier,
    machineManager: machineManager,
    remoteManager: remoteManager
)
private let signalSources = installSignalHandlers(shutdownCoordinator: shutdownCoordinator)

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
        let status = networkingController.status()
        FileHandle.standardError.write(Data("doryd: DNS serving \(status.suffix) on \(status.dnsBindAddress):\(status.dnsPort)\n".utf8))
    } catch {
        incidentWriter.record(type: "network.dns_failed", detail: "\(error)")
        FileHandle.standardError.write(Data("doryd: DNS unavailable: \(error)\n".utf8))
    }
}

dispatchMain()

private final class DorydShutdownCoordinator {
    private let listener: NSXPCListener
    private let idleSleepScheduler: IdleSleepScheduler?
    private let wakeCoordinator: HostWakeCoordinator
    private let networkingController: NetworkingController?
    private let dockerTier: DockerTier?
    private let machineManager: MachineManager?
    private let remoteManager: RemoteMachineManager
    private let lock = NSLock()
    private var didRun = false

    init(
        listener: NSXPCListener,
        idleSleepScheduler: IdleSleepScheduler?,
        wakeCoordinator: HostWakeCoordinator,
        networkingController: NetworkingController?,
        dockerTier: DockerTier?,
        machineManager: MachineManager?,
        remoteManager: RemoteMachineManager
    ) {
        self.listener = listener
        self.idleSleepScheduler = idleSleepScheduler
        self.wakeCoordinator = wakeCoordinator
        self.networkingController = networkingController
        self.dockerTier = dockerTier
        self.machineManager = machineManager
        self.remoteManager = remoteManager
    }

    func run(reason: String) -> Never {
        lock.lock()
        guard !didRun else {
            lock.unlock()
            exit(0)
        }
        didRun = true
        lock.unlock()

        FileHandle.standardError.write(Data("doryd: shutting down (\(reason))\n".utf8))
        listener.invalidate()
        idleSleepScheduler?.stop()
        wakeCoordinator.stop()
        networkingController?.stop()
        remoteManager.disconnectAll()
        machineManager?.stopAll()
        dockerTier?.stop()
        FileHandle.standardError.write(Data("doryd: shutdown complete\n".utf8))
        exit(0)
    }
}

private func installSignalHandlers(
    shutdownCoordinator: DorydShutdownCoordinator
) -> [DispatchSourceSignal] {
    [SIGTERM, SIGINT].map { signalNumber in
        _ = signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
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
