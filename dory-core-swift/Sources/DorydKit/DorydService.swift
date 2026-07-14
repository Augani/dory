import DoryCore
import Foundation
import ObjectiveC

/// The exported XPC object. Stateless beyond the socket path; every reply is total.
public final class DorydService: NSObject, DorydControl {
    private let socketPath: String
    private let dockerTier: DockerTier?
    private let machineManager: MachineManager?
    private let remoteManager: RemoteMachineManager?
    private let networkingController: NetworkingController?
    private let networkRouteRepair: (@Sendable () -> Int)?
    private let balloonController: BalloonController
    private let idlePolicyStore: IdlePolicyStore
    private let idleSleepScheduler: IdleSleepScheduler?
    private let healthReporter: HealthReporter
    private let incidentWriter: IncidentWriter?
    private let runtimeModeLock = NSLock()

    public init(
        socketPath: String,
        dockerTier: DockerTier? = nil,
        machineManager: MachineManager? = nil,
        remoteManager: RemoteMachineManager? = nil,
        networkingController: NetworkingController? = nil,
        networkRouteRepair: (@Sendable () -> Int)? = nil,
        balloonController: BalloonController? = nil,
        idlePolicyStore: IdlePolicyStore? = nil,
        idleSleepScheduler: IdleSleepScheduler? = nil,
        healthReporter: HealthReporter? = nil,
        incidentWriter: IncidentWriter? = nil
    ) {
        self.socketPath = socketPath
        self.dockerTier = dockerTier
        self.machineManager = machineManager
        self.remoteManager = remoteManager
        self.networkingController = networkingController
        self.networkRouteRepair = networkRouteRepair
        self.balloonController = balloonController ?? BalloonController(
            actuator: DorydBalloonActuator(machineManager: machineManager)
        )
        let resolvedIdlePolicyStore = idlePolicyStore ?? IdlePolicyStore(dockerContainers: {
            dockerTier?.containerSummariesForIdle() ?? .ok([])
        })
        self.idlePolicyStore = resolvedIdlePolicyStore
        self.idleSleepScheduler = idleSleepScheduler
        self.healthReporter = healthReporter ?? HealthReporter(
            socketPath: socketPath,
            dockerTier: dockerTier,
            machineManager: machineManager,
            remoteManager: remoteManager
        )
        self.incidentWriter = incidentWriter
        if let idlePolicyStore {
            dockerTier?.setLifecycleStateObserver { state in
                let desiredState: String
                switch state {
                case .running:
                    desiredState = "running"
                case .sleeping, .stopped:
                    desiredState = "sleeping"
                case .starting, .failed:
                    return
                }
                do {
                    try idlePolicyStore.setEngineDesiredState(desiredState)
                    incidentWriter?.record(
                        type: "engine.lifecycle",
                        detail: "docker tier \(state.rawValue)"
                    )
                } catch {
                    incidentWriter?.record(
                        type: "engine.desired_state_failed",
                        detail: "\(desiredState): \(error)"
                    )
                }
            }
        }
    }

    public func protocolVersion(reply: @escaping (UInt32) -> Void) {
        reply(DoryCore.protocolVersion())
    }

    public func dorySocketPath(reply: @escaping (String) -> Void) {
        reply(socketPath)
    }

    public func engineStatus(reply: @escaping (String, String) -> Void) {
        guard let dockerTier else {
            reply("unconfigured", "docker tier is not configured")
            return
        }
        let status = dockerTier.status()
        reply(status.state.rawValue, status.lastError ?? "")
    }

    public func engineStart(reply: @escaping (Bool, String) -> Void) {
        promoteEngine(event: "start", reply: reply)
    }

    public func engineStop(reply: @escaping (Bool, String) -> Void) {
        guard let dockerTier else {
            reply(false, "docker tier is not configured")
            return
        }
        dockerTier.stop()
        incidentWriter?.record(type: "engine.stop", detail: "docker tier stopped")
        reply(true, "")
    }

    public func engineSleep(reply: @escaping (Bool, String) -> Void) {
        guard let dockerTier else {
            reply(false, "docker tier is not configured")
            return
        }
        let status = dockerTier.status()
        switch status.state {
        case .sleeping:
            reply(true, "docker tier is already sleeping")
            return
        case .stopped:
            reply(true, "docker tier is already stopped")
            return
        case .starting, .running, .failed:
            break
        }
        let slept = dockerTier.sleepForIdle(idleAfter: 0)
        if slept {
            incidentWriter?.record(type: "engine.sleep", detail: "manual XPC sleep")
        }
        reply(slept, slept ? "" : "docker tier is not idle-sleepable")
    }

    public func engineWake(reply: @escaping (Bool, String) -> Void) {
        promoteEngine(event: "wake", reply: reply)
    }

    public func dockerAgentInfo(reply: @escaping (NSDictionary, String) -> Void) {
        guard let dockerTier else {
            reply([:], "docker tier is not configured")
            return
        }
        do {
            guard let info = try dockerTier.agentInfo() else {
                reply([:], "docker agent is not available")
                return
            }
            reply(info.xpcDictionary, "")
        } catch {
            reply([:], "\(error)")
        }
    }

    public func dockerAgentPorts(reply: @escaping (NSDictionary, String) -> Void) {
        guard let dockerTier else {
            reply([:], "docker tier is not configured")
            return
        }
        do {
            guard let diff = try dockerTier.refreshPublishedPorts(),
                  let ports = dockerTier.currentPublishedPorts() else {
                reply([:], "docker agent is not available")
                return
            }
            reply(diff.xpcDictionary(current: ports), "")
        } catch {
            reply([:], "\(error)")
        }
    }

    public func dockerAgentTelemetry(reply: @escaping (NSDictionary, String) -> Void) {
        guard let dockerTier else {
            reply([:], "docker tier is not configured")
            return
        }
        do {
            guard let telemetry = try dockerTier.telemetry() else {
                reply([:], "docker agent is not available")
                return
            }
            reply(telemetry.xpcDictionary, "")
        } catch {
            reply([:], "\(error)")
        }
    }

    public func dockerAgentClockSync(reply: @escaping (NSDictionary, String) -> Void) {
        guard let dockerTier else {
            reply([:], "docker tier is not configured")
            return
        }
        let result = dockerTier.syncAgentClock(now: Date())
        let body: NSDictionary = [
            "name": result.name,
            "attempted": result.attempted,
            "synced": result.synced,
            "error": result.error ?? "",
        ]
        if let error = result.error {
            reply(body, error)
        } else if !result.attempted {
            reply(body, "docker agent is not available or the docker tier is not running")
        } else if !result.synced {
            reply(body, "docker agent declined clock synchronization")
        } else {
            reply(body, "")
        }
    }

    public func machineCreate(
        _ config: NSDictionary,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, [:], "machine manager is not configured")
            return
        }
        do {
            let machine = try DoryMachineConfiguration(xpcDictionary: config)
            let status = try machineManager.create(machine)
            incidentWriter?.record(type: "machine.create", detail: machine.id)
            reply(true, status.xpcDictionary, "")
        } catch {
            incidentWriter?.record(type: "machine.create_failed", detail: "\(error)")
            reply(false, [:], "\(error)")
        }
    }

    public func machineStart(
        _ machineID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        machineControl(machineID, action: "start", reply: reply) { manager, id in
            try manager.start(id: id)
        }
    }

    public func machineStop(
        _ machineID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        machineControl(machineID, action: "stop", reply: reply) { manager, id in
            try manager.stop(id: id)
        }
    }

    public func machineUpdate(
        _ machineID: String,
        config: NSDictionary,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, [:], "machine manager is not configured")
            return
        }
        do {
            let update = try MachineUpdateRequest(xpcDictionary: config)
            let status = try machineManager.update(
                id: machineID,
                memoryMB: update.memoryMB,
                cpuCount: update.cpuCount,
                address: update.address,
                updatesAddress: update.updatesAddress,
                shares: update.shares,
                updatesShares: update.updatesShares,
                environment: update.environment,
                updatesEnvironment: update.updatesEnvironment
            )
            incidentWriter?.record(type: "machine.update", detail: machineID)
            reply(true, status.xpcDictionary, "")
        } catch {
            incidentWriter?.record(type: "machine.update_failed", detail: "\(machineID): \(error)")
            reply(false, [:], "\(error)")
        }
    }

    public func machineDelete(_ machineID: String, reply: @escaping (Bool, String) -> Void) {
        guard let machineManager else {
            reply(false, "machine manager is not configured")
            return
        }
        do {
            try machineManager.delete(id: machineID)
            incidentWriter?.record(type: "machine.delete", detail: machineID)
            reply(true, "")
        } catch {
            incidentWriter?.record(type: "machine.delete_failed", detail: "\(error)")
            reply(false, "\(error)")
        }
    }

    public func machineList(reply: @escaping (NSArray, String) -> Void) {
        guard let machineManager else {
            reply([], "machine manager is not configured")
            return
        }
        reply(machineManager.list().map(\.xpcDictionary) as NSArray, "")
    }

    public func machineStats(
        _ machineID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, [:], "machine manager is not configured")
            return
        }
        do {
            let stats = try machineManager.stats(id: machineID)
            reply(true, stats.xpcDictionary, "")
        } catch {
            reply(false, [:], "\(error)")
        }
    }

    public func machineExec(
        _ machineID: String,
        request: NSDictionary,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, [:], "machine manager is not configured")
            return
        }
        do {
            let execRequest = try MachineExecRequest(xpcDictionary: request)
            let result = try machineManager.exec(
                id: machineID,
                argv: execRequest.argv,
                cwd: execRequest.cwd,
                env: execRequest.env,
                timeoutMs: execRequest.timeoutMs,
                outputLimitBytes: execRequest.outputLimitBytes
            )
            incidentWriter?.record(type: "machine.exec", detail: "\(machineID) \(execRequest.argv.first ?? "")")
            reply(true, result.xpcDictionary, "")
        } catch {
            incidentWriter?.record(type: "machine.exec_failed", detail: "\(machineID): \(error)")
            reply(false, [:], "\(error)")
        }
    }

    public func machineProvision(
        _ machineID: String,
        request: NSDictionary,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, [:], "machine manager is not configured")
            return
        }
        do {
            let provisionRequest = try MachineProvisionRequest(xpcDictionary: request)
            let result = try MachineRecipeProvisioner.provision(
                machineID: machineID,
                recipeID: provisionRequest.recipeID,
                manager: machineManager
            )
            incidentWriter?.record(type: "machine.provision", detail: "\(machineID) \(result.recipeID)")
            reply(true, result.xpcDictionary, "")
        } catch {
            incidentWriter?.record(type: "machine.provision_failed", detail: "\(machineID): \(error)")
            reply(false, [:], "\(error)")
        }
    }

    public func machineSnapshot(
        _ machineID: String,
        request: NSDictionary,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, [:], "machine manager is not configured")
            return
        }
        do {
            let snapshotRequest = try MachineSnapshotRequest(xpcDictionary: request)
            let snapshot = try machineManager.snapshot(
                id: machineID,
                note: snapshotRequest.note,
                createdISO: snapshotRequest.createdISO,
                snapshotID: snapshotRequest.snapshotID
            )
            incidentWriter?.record(type: "machine.snapshot", detail: "\(machineID) \(snapshot.id)")
            reply(true, snapshot.xpcDictionary, "")
        } catch {
            incidentWriter?.record(type: "machine.snapshot_failed", detail: "\(machineID): \(error)")
            reply(false, [:], "\(error)")
        }
    }

    public func machineSnapshots(_ machineID: String, reply: @escaping (NSArray, String) -> Void) {
        guard let machineManager else {
            reply([], "machine manager is not configured")
            return
        }
        do {
            let machine = machineID.isEmpty ? nil : machineID
            reply(try machineManager.listSnapshots(machineID: machine).map(\.xpcDictionary) as NSArray, "")
        } catch {
            reply([], "\(error)")
        }
    }

    public func machineCloneSnapshot(
        _ machineID: String,
        snapshotID: String,
        newID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        machineControl("\(machineID)/\(snapshotID)", action: "clone_snapshot", reply: reply) { manager, _ in
            try manager.cloneSnapshot(machineID: machineID, snapshotID: snapshotID, newID: newID)
        }
    }

    public func machineRestoreSnapshot(
        _ machineID: String,
        snapshotID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        machineControl("\(machineID)/\(snapshotID)", action: "restore_snapshot", reply: reply) { manager, _ in
            try manager.restoreSnapshot(machineID: machineID, snapshotID: snapshotID)
        }
    }

    public func machineDeleteSnapshot(_ machineID: String, snapshotID: String, reply: @escaping (Bool, String) -> Void) {
        guard let machineManager else {
            reply(false, "machine manager is not configured")
            return
        }
        do {
            try machineManager.deleteSnapshot(machineID: machineID, snapshotID: snapshotID)
            incidentWriter?.record(type: "machine.delete_snapshot", detail: "\(machineID) \(snapshotID)")
            reply(true, "")
        } catch {
            incidentWriter?.record(type: "machine.delete_snapshot_failed", detail: "\(machineID): \(error)")
            reply(false, "\(error)")
        }
    }

    public func machineExportSnapshot(
        _ machineID: String,
        snapshotID: String,
        path: String,
        reply: @escaping (Bool, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, "machine manager is not configured")
            return
        }
        do {
            try machineManager.exportSnapshot(machineID: machineID, snapshotID: snapshotID, toPath: path)
            incidentWriter?.record(type: "machine.export_snapshot", detail: "\(machineID) \(snapshotID)")
            reply(true, "")
        } catch {
            incidentWriter?.record(type: "machine.export_snapshot_failed", detail: "\(machineID): \(error)")
            reply(false, "\(error)")
        }
    }

    public func machineImportSnapshot(
        _ path: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, [:], "machine manager is not configured")
            return
        }
        do {
            let snapshot = try machineManager.importSnapshot(fromPath: path)
            incidentWriter?.record(type: "machine.import_snapshot", detail: "\(snapshot.machineID) \(snapshot.id)")
            reply(true, snapshot.xpcDictionary, "")
        } catch {
            incidentWriter?.record(type: "machine.import_snapshot_failed", detail: "\(error)")
            reply(false, [:], "\(error)")
        }
    }

    public func remoteConnect(
        _ config: NSDictionary,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let remoteManager else {
            reply(false, [:], "remote manager is not configured")
            return
        }
        do {
            let machine = try RemoteMachineConfiguration(xpcDictionary: config)
            let info = try remoteManager.connect(machine)
            incidentWriter?.record(type: "remote.connect", detail: machine.id)
            reply(true, info.xpcDictionary, "")
        } catch {
            incidentWriter?.record(type: "remote.connect_failed", detail: "\(error)")
            reply(false, [:], "\(error)")
        }
    }

    private func machineControl(
        _ machineID: String,
        action: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void,
        operation: (MachineManager, String) throws -> DoryMachineStatus
    ) {
        guard let machineManager else {
            reply(false, [:], "machine manager is not configured")
            return
        }
        do {
            let status = try operation(machineManager, machineID)
            incidentWriter?.record(type: "machine.\(action)", detail: machineID)
            reply(true, status.xpcDictionary, "")
        } catch {
            incidentWriter?.record(type: "machine.\(action)_failed", detail: "\(error)")
            reply(false, [:], "\(error)")
        }
    }

    public func remotePush(
        _ machineID: String,
        localRoot: String,
        remoteRoot: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let remoteManager else {
            reply(false, [:], "remote manager is not configured")
            return
        }
        do {
            let root = remoteRoot.isEmpty ? nil : remoteRoot
            let stats = try remoteManager.push(id: machineID, localRoot: localRoot, remoteRoot: root)
            incidentWriter?.record(type: "remote.push", detail: machineID)
            reply(true, stats.xpcDictionary, "")
        } catch {
            incidentWriter?.record(type: "remote.push_failed", detail: "\(error)")
            reply(false, [:], "\(error)")
        }
    }

    public func remoteStatus(
        _ machineID: String,
        reply: @escaping (NSDictionary, String) -> Void
    ) {
        guard let remoteManager else {
            reply([:], "remote manager is not configured")
            return
        }
        guard let status = remoteManager.status(id: machineID) else {
            reply([:], "unknown remote machine: \(machineID)")
            return
        }
        reply(status.xpcDictionary, "")
    }

    public func networkReplaceRoutes(_ routes: NSArray, reply: @escaping (Bool, String) -> Void) {
        guard let networkingController else {
            reply(false, "networking is not configured")
            return
        }
        do {
            networkingController.replaceRoutes(try routes.compactMap { item in
                guard let dictionary = item as? NSDictionary else {
                    throw XPCNetworkRouteError.invalid("route")
                }
                return try DomainRoute(xpcDictionary: dictionary)
            })
            incidentWriter?.record(type: "network.routes", detail: "\(routes.count) routes")
            reply(true, "")
        } catch {
            reply(false, "\(error)")
        }
    }

    public func networkStatus(reply: @escaping (NSDictionary, String) -> Void) {
        guard let networkingController else {
            reply([:], "networking is not configured")
            return
        }
        reply(networkingController.status().xpcDictionary, "")
    }

    public func networkAuthorizationPlan(reply: @escaping (NSDictionary, String) -> Void) {
        guard let networkingController else {
            reply([:], "networking is not configured")
            return
        }
        do {
            let publishedPorts = currentPublishedPorts()
            let autoForwards = PrivilegedPortMapping.forwards(from: publishedPorts)
            reply(try networkingController.authorizationPlan(
                additionalPrivilegedTCPForwards: autoForwards
            ).xpcDictionary, "")
        } catch {
            reply([:], "\(error)")
        }
    }

    public func repairSubsystem(_ target: String, reply: @escaping (Bool, String) -> Void) {
        do {
            let detail: String
            switch target {
            case "dns":
                _ = networkRouteRepair?()
                guard let networkingController else { throw SubsystemRepairError.unavailable("networking is not configured") }
                let status = try networkingController.repair(.dns)
                detail = "DNS listener restarted on \(status.dnsBindAddress):\(status.dnsPort) with \(status.routes.count) route(s)"
            case "domains":
                let routeCount = networkRouteRepair?()
                guard let networkingController else { throw SubsystemRepairError.unavailable("networking is not configured") }
                let status = try networkingController.repair(.domains)
                detail = "domain proxies restarted with \(routeCount ?? status.routes.count) route(s)"
            case "routes":
                guard let networkRouteRepair else { throw SubsystemRepairError.unavailable("route reconciler is not configured") }
                let routeCount = networkRouteRepair()
                guard let networkingController else { throw SubsystemRepairError.unavailable("networking is not configured") }
                _ = try networkingController.repair(.routes)
                detail = "reconciled \(routeCount) domain route(s)"
            case "ports":
                guard let dockerTier else { throw SubsystemRepairError.unavailable("docker tier is not configured") }
                let diff = try dockerTier.repairPublishedPorts()
                let count = dockerTier.currentPublishedPorts()?.count ?? 0
                detail = "requested immediate gvproxy reconciliation; validated \(count) published port(s), added \(diff?.added.count ?? 0), removed \(diff?.removed.count ?? 0)"
            case "guest-agent":
                guard let dockerTier else { throw SubsystemRepairError.unavailable("docker tier is not configured") }
                let result = dockerTier.syncAgentClock(now: Date())
                guard result.attempted, result.synced else {
                    throw SubsystemRepairError.unavailable(result.error ?? "guest agent did not acknowledge a fresh RPC")
                }
                detail = "guest agent reconnected and acknowledged clock synchronization"
            case "dockerd", "docker-api":
                guard let dockerTier else { throw SubsystemRepairError.unavailable("docker tier is not configured") }
                switch dockerTier.containerSummariesForIdle() {
                case .ok(let containers):
                    detail = "Docker API is reachable; \(containers.count) container(s) visible"
                case .unavailable(let reason):
                    throw SubsystemRepairError.unavailable("Docker API remains unreachable: \(reason). Use the explicit workload-aware engine restart.")
                }
            default:
                throw SubsystemRepairError.invalidTarget(target)
            }
            incidentWriter?.record(type: "repair.\(target)", detail: detail)
            reply(true, detail)
        } catch {
            let detail = "\(error)"
            incidentWriter?.record(type: "repair.\(target)_failed", detail: detail)
            reply(false, detail)
        }
    }

    public func balloonStatus(reply: @escaping (NSDictionary, String) -> Void) {
        do {
            reply(try balloonController.currentPlan(guests: memoryGuests()).xpcDictionary, "")
        } catch {
            reply([:], "\(error)")
        }
    }

    public func balloonReconcile(reply: @escaping (NSDictionary, String) -> Void) {
        do {
            let plan = try balloonController.reconcile(guests: memoryGuests())
            incidentWriter?.record(
                type: "balloon.reconcile",
                detail: "\(plan.applicableTargets.count) applicable targets"
            )
            reply(plan.xpcDictionary, "")
        } catch {
            incidentWriter?.record(type: "balloon.reconcile_failed", detail: "\(error)")
            reply([:], "\(error)")
        }
    }

    public func idleStatus(reply: @escaping (NSDictionary, String) -> Void) {
        reply(idlePolicyStore.status(), "")
    }

    public func idleHistory(_ limit: Int, reply: @escaping (NSArray, String) -> Void) {
        reply(idlePolicyStore.history(limit: limit), "")
    }

    public func idleSetMode(_ mode: String, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        runtimeModeLock.lock()
        defer { runtimeModeLock.unlock() }
        let previousMode = idlePolicyStore.currentRuntimeMode()
        do {
            _ = try idlePolicyStore.setRuntimeMode(mode)
            updateIdleSleepScheduler()
            let appliedMode = idlePolicyStore.currentRuntimeMode()
            if Self.runtimeModeKeepsEngineAwake(appliedMode) {
                guard let dockerTier else {
                    throw DockerTier.TierError.wakeFailed("docker tier is not configured")
                }
                try dockerTier.promoteToRunning()
            }
            let status = idlePolicyStore.status()
            incidentWriter?.record(type: "idle.mode", detail: appliedMode)
            reply(true, status, "")
        } catch {
            if idlePolicyStore.currentRuntimeMode() != previousMode {
                do {
                    _ = try idlePolicyStore.setRuntimeMode(previousMode)
                    updateIdleSleepScheduler()
                } catch {
                    incidentWriter?.record(
                        type: "idle.mode_rollback_failed",
                        detail: "requested=\(mode) previous=\(previousMode): \(error)"
                    )
                    reply(false, idlePolicyStore.status(), "idle mode failed and its previous value could not be restored: \(error)")
                    return
                }
            }
            incidentWriter?.record(type: "idle.mode_failed", detail: "\(error)")
            reply(false, idlePolicyStore.status(), "\(error)")
        }
    }

    public func idleSetPolicy(_ key: String, value: String, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        runtimeModeLock.lock()
        defer { runtimeModeLock.unlock() }
        do {
            let status = try idlePolicyStore.setPolicy(key: key, value: value)
            updateIdleSleepScheduler()
            incidentWriter?.record(type: "idle.policy", detail: "\(key)=\(value)")
            reply(true, status, "")
        } catch {
            incidentWriter?.record(type: "idle.policy_failed", detail: "\(key): \(error)")
            reply(false, [:], "\(error)")
        }
    }

    public func health(reply: @escaping (NSDictionary, String) -> Void) {
        reply(healthReporter.report().xpcDictionary, "")
    }

    public func doctorJSON(reply: @escaping (String, String) -> Void) {
        do {
            reply(try healthReporter.doctorReport().jsonString(), "")
        } catch {
            reply("", "\(error)")
        }
    }

    public func incidents(_ limit: Int, reply: @escaping (NSArray, String) -> Void) {
        guard let incidentWriter else {
            reply([], "")
            return
        }
        reply(incidentWriter.read(limit: limit).map(\.xpcDictionary) as NSArray, "")
    }

    private func memoryGuests() throws -> [GuestMemorySnapshot] {
        var guests: [GuestMemorySnapshot] = []
        if let local = try dockerTier?.memorySnapshot() {
            guests.append(local)
        }
        if let machineManager {
            guests.append(contentsOf: machineManager.memorySnapshots())
        }
        if let remoteManager {
            guests.append(contentsOf: remoteManager.list().compactMap { status in
                guard let telemetry = status.telemetry else { return nil }
                return GuestMemorySnapshot(
                    id: "remote.\(status.id)",
                    kind: .remote,
                    telemetry: telemetry,
                    canBalloon: false
                )
            })
        }
        return guests
    }

    private func updateIdleSleepScheduler() {
        guard let idleSleepScheduler else { return }
        let configuration = idlePolicyStore.schedulerConfiguration(base: idleSleepScheduler.currentConfiguration)
        idleSleepScheduler.update(configuration: configuration)
    }

    private func promoteEngine(event: String, reply: @escaping (Bool, String) -> Void) {
        guard let dockerTier else {
            reply(false, "docker tier is not configured")
            return
        }
        let replyBox = EngineReply(reply)
        let incidentWriter = incidentWriter
        Task.detached {
            do {
                try dockerTier.promoteToRunning()
                incidentWriter?.record(type: "engine.\(event)", detail: "docker tier running")
                replyBox.reply(true, "")
            } catch {
                incidentWriter?.record(type: "engine.\(event)_failed", detail: "\(error)")
                replyBox.reply(false, "\(error)")
            }
        }
    }

    private static func runtimeModeKeepsEngineAwake(_ mode: String) -> Bool {
        mode == "always-on" || mode == "manual"
    }

    private func currentPublishedPorts() -> [DoryListenPort] {
        if let dockerPorts = dockerTier?.currentDockerPublishedPorts() {
            return dockerPorts
        }
        do {
            _ = try dockerTier?.refreshPublishedPorts()
        } catch {
            incidentWriter?.record(type: "network.ports_failed", detail: "\(error)")
        }
        return dockerTier?.currentPublishedPorts() ?? []
    }
}

private final class EngineReply: @unchecked Sendable {
    let reply: (Bool, String) -> Void

    init(_ reply: @escaping (Bool, String) -> Void) {
        self.reply = reply
    }
}

private final class DorydBalloonActuator: BalloonActuator, @unchecked Sendable {
    private let machineManager: MachineManager?

    init(machineManager: MachineManager?) {
        self.machineManager = machineManager
    }

    func apply(targets: [BalloonTarget]) throws {
        try machineManager?.applyBalloonTargets(targets)
    }
}

private enum SubsystemRepairError: Error, CustomStringConvertible {
    case invalidTarget(String)
    case unavailable(String)

    var description: String {
        switch self {
        case .invalidTarget(let target):
            return "unsupported repair target: \(target)"
        case .unavailable(let detail):
            return detail
        }
    }
}

private enum XPCRemoteConfigError: Error, CustomStringConvertible {
    case missing(String)
    case invalid(String)

    var description: String {
        switch self {
        case let .missing(key):
            return "missing remote config field: \(key)"
        case let .invalid(key):
            return "invalid remote config field: \(key)"
        }
    }
}

private enum XPCNetworkRouteError: Error, CustomStringConvertible {
    case missing(String)
    case invalid(String)

    var description: String {
        switch self {
        case let .missing(key):
            return "missing network route field: \(key)"
        case let .invalid(key):
            return "invalid network route field: \(key)"
        }
    }
}

private struct MachineExecRequest {
    var argv: [String]
    var cwd: String
    var env: [DoryExecEnvironment]
    var timeoutMs: UInt64
    var outputLimitBytes: UInt64

    init(xpcDictionary dictionary: NSDictionary) throws {
        self.argv = try dictionary.requiredStringArray("argv")
        guard !argv.isEmpty else {
            throw XPCRemoteConfigError.invalid("argv")
        }
        self.cwd = dictionary.optionalString("cwd") ?? ""
        self.env = try dictionary.optionalEnv("env")
        self.timeoutMs = try dictionary.optionalUInt64("timeoutMs") ?? 30_000
        self.outputLimitBytes = try dictionary.optionalUInt64("outputLimitBytes") ?? 1024 * 1024
    }
}

private struct MachineProvisionRequest {
    var recipeID: String

    init(xpcDictionary dictionary: NSDictionary) throws {
        self.recipeID = dictionary.optionalString("recipe") ?? "rust"
        guard !recipeID.isEmpty else {
            throw XPCRemoteConfigError.invalid("recipe")
        }
    }
}

private struct MachineUpdateRequest {
    var memoryMB: UInt64?
    var cpuCount: Int?
    var address: String?
    var updatesAddress: Bool
    var shares: [DoryMachineShareConfiguration]?
    var updatesShares: Bool
    var environment: [String: String]?
    var updatesEnvironment: Bool

    init(xpcDictionary dictionary: NSDictionary) throws {
        self.memoryMB = try dictionary.optionalUInt64("memoryMB")
        self.cpuCount = try dictionary.optionalInt("cpuCount")
        self.updatesAddress = dictionary["address"] != nil
        if updatesAddress {
            let trimmedAddress = dictionary.optionalString("address")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.address = trimmedAddress.isEmpty ? nil : trimmedAddress
        } else {
            self.address = nil
        }
        self.shares = dictionary["shares"] == nil ? nil : try dictionary.optionalMachineShares("shares")
        self.updatesShares = dictionary["shares"] != nil
        self.environment = dictionary["env"] == nil ? nil : try dictionary.optionalEnvironmentDictionary("env")
        self.updatesEnvironment = dictionary["env"] != nil
        if memoryMB == nil, cpuCount == nil, !updatesAddress, !updatesShares, !updatesEnvironment {
            throw XPCRemoteConfigError.invalid("config")
        }
    }
}

private struct MachineSnapshotRequest {
    var note: String
    var createdISO: String
    var snapshotID: String?

    init(xpcDictionary dictionary: NSDictionary) throws {
        self.note = dictionary.optionalString("note") ?? ""
        self.createdISO = dictionary.optionalString("createdISO") ?? ISO8601DateFormatter().string(from: Date())
        self.snapshotID = dictionary.optionalString("snapshotID")
        if let snapshotID, snapshotID.isEmpty {
            throw XPCRemoteConfigError.invalid("snapshotID")
        }
    }
}

private extension RemoteMachineConfiguration {
    init(xpcDictionary dictionary: NSDictionary) throws {
        let id = try dictionary.requiredString("id")
        let host = try dictionary.requiredString("host")
        let user = try dictionary.requiredString("user")
        let privateKeyID = try dictionary.requiredString("privateKeyID")
        let remoteRoot = try dictionary.requiredString("remoteRoot")
        let port = try dictionary.optionalUInt16("port") ?? 22
        let build = dictionary.optionalString("build") ?? "doryd"
        let hostKey = try dictionary.remoteHostKey(defaultHost: host, defaultPort: port)
        let endpoint = try dictionary.remoteEndpoint()
        self.init(
            id: id,
            host: host,
            port: port,
            user: user,
            privateKeyID: privateKeyID,
            hostKey: hostKey,
            endpoint: endpoint,
            remoteRoot: remoteRoot,
            build: build
        )
    }
}

private extension DoryMachineConfiguration {
    init(xpcDictionary dictionary: NSDictionary) throws {
        self.init(
            id: try dictionary.requiredString("id"),
            kernelPath: try dictionary.requiredString("kernelPath"),
            rootfsPath: try dictionary.requiredString("rootfsPath"),
            memoryMB: try dictionary.optionalUInt64("memoryMB") ?? 2048,
            cpuCount: try dictionary.optionalInt("cpuCount") ?? 2,
            address: dictionary.optionalString("address"),
            shares: try dictionary.optionalMachineShares("shares"),
            environment: try dictionary.optionalEnvironmentDictionary("env")
        )
    }
}

private extension DomainRoute {
    init(xpcDictionary dictionary: NSDictionary) throws {
        guard let hostname = dictionary["hostname"] as? String, !hostname.isEmpty else {
            throw XPCNetworkRouteError.missing("hostname")
        }
        guard let address = dictionary["address"] as? String, IPv4Address(address) != nil else {
            throw XPCNetworkRouteError.invalid("address")
        }
        self.init(
            hostname: hostname,
            address: address,
            port: try dictionary.optionalUInt16("port") ?? 80,
            pathPrefix: dictionary.optionalString("pathPrefix") ?? ""
        )
    }

    var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "hostname": hostname,
            "address": address,
            "port": port,
        ]
        if !pathPrefix.isEmpty {
            dictionary["pathPrefix"] = pathPrefix
        }
        return dictionary as NSDictionary
    }
}

private extension NetworkingStatus {
    var xpcDictionary: NSDictionary {
        [
            "mode": mode,
            "suffix": suffix,
            "dnsBindAddress": dnsBindAddress,
            "dnsPort": dnsPort,
            "dnsRunning": dnsRunning,
            "httpProxyPort": httpProxyPort,
            "httpProxyRunning": httpProxyRunning,
            "httpsProxyPort": httpsProxyPort,
            "httpsProxyRunning": httpsProxyRunning,
            "routes": routes.map(\.xpcDictionary),
        ]
    }
}

private extension NetworkingAuthorizationRequest {
    var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "id": id,
            "kind": kind.rawValue,
            "title": title,
            "reason": reason,
            "requiresAdmin": requiresAdmin,
            "command": command,
        ]
        if let filePath {
            dictionary["filePath"] = filePath
        }
        if let fileContents {
            dictionary["fileContents"] = fileContents
        }
        return dictionary as NSDictionary
    }
}

private extension NetworkingAuthorizationPlan {
    var xpcDictionary: NSDictionary {
        [
            "degradedMode": degradedMode,
            "authorizedMode": authorizedMode,
            "suffix": suffix,
            "dnsBindAddress": dnsBindAddress,
            "dnsPort": dnsPort,
            "httpProxyPort": httpProxyPort,
            "httpsProxyPort": httpsProxyPort,
            "privilegedTCPForwards": privilegedTCPForwards.map(\.xpcDictionary),
            "requests": requests.map(\.xpcDictionary),
        ]
    }
}

private extension PrivilegedTCPForward {
    var xpcDictionary: NSDictionary {
        [
            "listenPort": listenPort,
            "targetPort": targetPort,
        ]
    }
}

private extension NSDictionary {
    func requiredString(_ key: String) throws -> String {
        guard let value = optionalString(key), !value.isEmpty else {
            throw XPCRemoteConfigError.missing(key)
        }
        return value
    }

    func requiredStringArray(_ key: String) throws -> [String] {
        guard let raw = self[key] as? [String], !raw.isEmpty, raw.allSatisfy({ !$0.isEmpty }) else {
            throw XPCRemoteConfigError.invalid(key)
        }
        return raw
    }

    func optionalEnv(_ key: String) throws -> [DoryExecEnvironment] {
        guard let raw = self[key] else { return [] }
        guard let rows = raw as? [NSDictionary] else {
            throw XPCRemoteConfigError.invalid(key)
        }
        return try rows.map { row in
            let key = try row.requiredString("key")
            let value = row.optionalString("value") ?? ""
            return DoryExecEnvironment(key: key, value: value)
        }
    }

    func optionalMachineShares(_ key: String) throws -> [DoryMachineShareConfiguration] {
        guard let raw = self[key] else { return [] }
        guard let rows = raw as? [NSDictionary] else {
            throw XPCRemoteConfigError.invalid(key)
        }
        return try rows.map { row in
            let share = DoryMachineShareConfiguration(
                tag: try row.requiredString("tag"),
                hostPath: try row.requiredString("hostPath"),
                guestPath: try row.requiredString("guestPath"),
                readOnly: row.optionalBool("readOnly") ?? false
            )
            try share.validate()
            return share
        }
    }

    func optionalEnvironmentDictionary(_ key: String) throws -> [String: String] {
        guard let raw = self[key] else { return [:] }
        guard let rows = raw as? [NSDictionary] else {
            throw XPCRemoteConfigError.invalid(key)
        }
        var result: [String: String] = [:]
        for row in rows {
            let key = try row.requiredString("key")
            guard key.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil else {
                throw XPCRemoteConfigError.invalid("env")
            }
            let value = row.optionalString("value") ?? ""
            guard !value.contains("\0") else {
                throw XPCRemoteConfigError.invalid("env")
            }
            result[key] = value
        }
        return result
    }

    func optionalString(_ key: String) -> String? {
        self[key] as? String
    }

    func optionalBool(_ key: String) -> Bool? {
        if let value = self[key] as? Bool {
            return value
        }
        if let number = self[key] as? NSNumber {
            return number.boolValue
        }
        if let string = self[key] as? String {
            switch string.lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    func optionalUInt16(_ key: String) throws -> UInt16? {
        guard let value = self[key] else { return nil }
        if let number = value as? NSNumber {
            let int = number.intValue
            guard int >= 0, int <= Int(UInt16.max) else {
                throw XPCRemoteConfigError.invalid(key)
            }
            return UInt16(int)
        }
        if let string = value as? String, let int = UInt16(string) {
            return int
        }
        throw XPCRemoteConfigError.invalid(key)
    }

    func optionalUInt64(_ key: String) throws -> UInt64? {
        guard let value = self[key] else { return nil }
        if let number = value as? NSNumber {
            let int = number.int64Value
            guard int >= 0 else {
                throw XPCRemoteConfigError.invalid(key)
            }
            return UInt64(int)
        }
        if let string = value as? String, let int = UInt64(string) {
            return int
        }
        throw XPCRemoteConfigError.invalid(key)
    }

    func optionalInt(_ key: String) throws -> Int? {
        guard let value = self[key] else { return nil }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String, let int = Int(string) {
            return int
        }
        throw XPCRemoteConfigError.invalid(key)
    }

    func remoteHostKey(defaultHost: String, defaultPort: UInt16) throws -> DoryRemoteHostKey {
        switch optionalString("hostKeyType") ?? "pinned" {
        case "pinned":
            return .pinned(opensshPublicKey: try requiredString("hostKey"))
        case "knownHosts":
            return .knownHosts(
                path: try requiredString("knownHostsPath"),
                host: optionalString("knownHostsHost") ?? defaultHost,
                port: try optionalUInt16("knownHostsPort") ?? defaultPort
            )
        default:
            throw XPCRemoteConfigError.invalid("hostKeyType")
        }
    }

    func remoteEndpoint() throws -> DoryRemoteEndpoint {
        switch optionalString("endpointType") ?? "unix" {
        case "unix":
            return .unixSocket(path: try requiredString("endpointPath"))
        case "tcp":
            guard let port = try optionalUInt16("endpointPort") else {
                throw XPCRemoteConfigError.missing("endpointPort")
            }
            return .tcp(
                host: try requiredString("endpointHost"),
                port: port
            )
        default:
            throw XPCRemoteConfigError.invalid("endpointType")
        }
    }
}

private extension DoryMachineStatus {
    var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "id": id,
            "state": state.rawValue,
            "lastError": lastError ?? "",
        ]
        if let pid {
            dictionary["pid"] = pid
        }
        if let handoffSocketPath {
            dictionary["handoffSocketPath"] = handoffSocketPath
        }
        if let agentBuild {
            dictionary["agentBuild"] = agentBuild
        }
        if let agentSocketPath {
            dictionary["agentSocketPath"] = agentSocketPath
        }
        if let dockerdSocketPath {
            dictionary["dockerdSocketPath"] = dockerdSocketPath
        }
        if let shellSocketPath {
            dictionary["shellSocketPath"] = shellSocketPath
        }
        if let controlSocketPath {
            dictionary["controlSocketPath"] = controlSocketPath
        }
        if let address {
            dictionary["address"] = address
        }
        dictionary["shares"] = shares.map(\.xpcDictionary)
        dictionary["env"] = environment.sorted(by: { $0.key < $1.key }).map { key, value in
            [
                "key": key,
                "value": value,
            ] as NSDictionary
        }
        dictionary["handoffFDCount"] = handoffFDCount
        dictionary["memoryMB"] = memoryMB
        dictionary["currentBalloonTargetMB"] = currentBalloonTargetMB
        dictionary["cpuCount"] = cpuCount
        return dictionary as NSDictionary
    }
}

private extension DoryMachineShareConfiguration {
    var xpcDictionary: NSDictionary {
        [
            "tag": tag,
            "hostPath": hostPath,
            "guestPath": guestPath,
            "readOnly": readOnly,
            "mode": readOnly ? "ro" : "rw",
        ]
    }
}

private extension DoryAgentInfo {
    var xpcDictionary: NSDictionary {
        [
            "protocolVersion": protocolVersion,
            "kernel": kernel,
            "agentBuild": agentBuild,
            "uptimeSeconds": uptimeSeconds,
        ]
    }
}

private extension DoryTelemetry {
    var xpcDictionary: NSDictionary {
        [
            "memTotalKB": memTotalKB,
            "memAvailableKB": memAvailableKB,
            "psiSomeAvg10": psiSomeAvg10,
            "psiFullAvg10": psiFullAvg10,
        ]
    }
}

private extension DoryMachineStats {
    var xpcDictionary: NSDictionary {
        [
            "schema": "dev.dory.machine.stats",
            "version": 1,
            "cpuPercent": cpuPercent,
            "memoryUsedBytes": memoryUsedBytes,
            "memoryTotalBytes": memoryTotalBytes,
            "networkReceiveBytes": networkReceiveBytes,
            "networkTransmitBytes": networkTransmitBytes,
            "blockReadBytes": blockReadBytes,
            "blockWriteBytes": blockWriteBytes,
            "processCount": processCount,
            "uptimeSeconds": uptimeSeconds,
        ]
    }
}

private extension DoryExecResult {
    var xpcDictionary: NSDictionary {
        [
            "exitCode": exitCode,
            "stdout": stdout,
            "stderr": stderr,
            "timedOut": timedOut,
            "stdoutTruncated": stdoutTruncated,
            "stderrTruncated": stderrTruncated,
        ]
    }
}

private extension MachineRecipeProvisionResult {
    var xpcDictionary: NSDictionary {
        [
            "recipe": recipeID,
            "recipeID": recipeID,
            "install": install.provisionDictionary,
            "verify": verify.provisionDictionary,
        ]
    }
}

private extension DoryMachineSnapshot {
    var xpcDictionary: NSDictionary {
        [
            "id": id,
            "machineID": machineID,
            "note": note,
            "createdISO": createdISO,
            "rootfsPath": rootfsPath,
            "sizeBytes": sizeBytes,
            "kernelPath": kernelPath,
            "memoryMB": memoryMB,
            "cpuCount": cpuCount,
        ]
    }
}

private extension DoryExecResult {
    var provisionDictionary: NSDictionary {
        [
            "exitCode": exitCode,
            "stdout": String(decoding: stdout, as: UTF8.self),
            "stderr": String(decoding: stderr, as: UTF8.self),
            "timedOut": timedOut,
            "stdoutTruncated": stdoutTruncated,
            "stderrTruncated": stderrTruncated,
        ]
    }
}

private extension DoryListenPort {
    var xpcDictionary: NSDictionary {
        [
            "protocol": `protocol`,
            "port": port,
        ]
    }
}

private extension PortPublishDiff {
    func xpcDictionary(current: [DoryListenPort]) -> NSDictionary {
        [
            "ports": current.map(\.xpcDictionary),
            "added": added.map(\.xpcDictionary),
            "removed": removed.map(\.xpcDictionary),
        ]
    }
}

private extension HostMemorySnapshot {
    var xpcDictionary: NSDictionary {
        [
            "totalBytes": totalBytes,
            "availableBytes": availableBytes,
            "freeBytes": freeBytes,
            "availableRatio": availableRatio,
            "pressure": pressure.rawValue,
        ]
    }
}

private extension BalloonTarget {
    var xpcDictionary: NSDictionary {
        [
            "id": id,
            "kind": kind.rawValue,
            "currentTargetMB": currentTargetMB,
            "targetMB": targetMB,
            "reason": reason.rawValue,
            "canApply": canApply,
        ]
    }
}

private extension BalloonPlan {
    var xpcDictionary: NSDictionary {
        [
            "host": host.xpcDictionary,
            "targets": targets.map(\.xpcDictionary),
            "applicableTargets": applicableTargets.map(\.xpcDictionary),
        ]
    }
}

private extension DoryPushStats {
    var xpcDictionary: NSDictionary {
        [
            "filesSent": filesSent,
            "bytesSent": bytesSent,
            "filesDeleted": filesDeleted,
        ]
    }
}

private extension RemoteMachineStatus {
    var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "id": id,
            "state": state.rawValue,
            "lastError": lastError ?? "",
        ]
        if let info {
            dictionary["info"] = info.xpcDictionary
        }
        if let telemetry {
            dictionary["telemetry"] = telemetry.xpcDictionary
        }
        return dictionary as NSDictionary
    }
}

/// Configures each inbound connection with the DorydControl interface and the shared service.
public final class DorydListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: DorydService

    public init(service: DorydService) {
        self.service = service
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: DorydControl.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

/// An in-process anonymous listener used by tests to exercise XPC without launchd.
public func makeAnonymousListener(service: DorydService) -> NSXPCListener {
    let listener = NSXPCListener.anonymous()
    let delegate = DorydListenerDelegate(service: service)
    let retainKey = Unmanaged.passUnretained(listener).toOpaque()
    objc_setAssociatedObject(listener, retainKey, delegate, .OBJC_ASSOCIATION_RETAIN)
    listener.delegate = delegate
    return listener
}
