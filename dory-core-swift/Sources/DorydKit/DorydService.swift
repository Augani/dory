import DoryCore
import DoryOperations
import Foundation
import ObjectiveC

/// The exported XPC object. Stateless beyond the socket path; every reply is total.
public final class DorydService: NSObject, DorydControl {
    private let socketPath: String
    private let home: String
    private let dockerTier: DockerTier?
    private let machineManager: MachineManager?
    private let productionPlanningController:
        (any DoryDaemonVirtualMachineProductionPlanningControlling)?
    private let machineImportEnvironment: DoryMachineImportEnvironment
    private let machineEventStore: DoryMachineEventStore?
    private let machineBackupScheduler: MachineBackupScheduler?
    private let hostUSBDiscovery: any DoryHostUSBDiscovering
    private let remoteManager: RemoteMachineManager?
    private let networkingController: NetworkingController?
    private let networkRouteRepair: (@Sendable () -> Int)?
    private let customDomainRouteStore: CustomDomainRouteStore?
    private let corporateConnectivity: CorporateConnectivityReconciler?
    private let balloonController: BalloonController
    private let idlePolicyStore: IdlePolicyStore
    private let idleSleepScheduler: IdleSleepScheduler?
    private let healthReporter: HealthReporter
    private let incidentWriter: IncidentWriter?
    private let runtimeModeLock = NSLock()
    private let machineEventQueryLock = NSLock()

    public init(
        socketPath: String,
        home: String = NSHomeDirectory(),
        dockerTier: DockerTier? = nil,
        machineManager: MachineManager? = nil,
        productionPlanningController:
            (any DoryDaemonVirtualMachineProductionPlanningControlling)? = nil,
        machineImportEnvironment: DoryMachineImportEnvironment = .unverified,
        machineBackupScheduler: MachineBackupScheduler? = nil,
        hostUSBDiscovery: any DoryHostUSBDiscovering = IOKitDoryHostUSBDiscovery(),
        remoteManager: RemoteMachineManager? = nil,
        networkingController: NetworkingController? = nil,
        networkRouteRepair: (@Sendable () -> Int)? = nil,
        customDomainRouteStore: CustomDomainRouteStore? = nil,
        corporateConnectivity: CorporateConnectivityReconciler? = nil,
        balloonController: BalloonController? = nil,
        idlePolicyStore: IdlePolicyStore? = nil,
        idleSleepScheduler: IdleSleepScheduler? = nil,
        healthReporter: HealthReporter? = nil,
        incidentWriter: IncidentWriter? = nil
    ) {
        self.socketPath = socketPath
        self.home = home
        self.dockerTier = dockerTier
        self.machineManager = machineManager
        self.productionPlanningController = productionPlanningController
        self.machineImportEnvironment = machineImportEnvironment
        self.machineEventStore = machineManager.map {
            DoryMachineEventStore(root: $0.managedStateDirectory)
        }
        self.machineBackupScheduler = machineBackupScheduler
        self.hostUSBDiscovery = hostUSBDiscovery
        self.remoteManager = remoteManager
        self.networkingController = networkingController
        self.networkRouteRepair = networkRouteRepair
        self.customDomainRouteStore = customDomainRouteStore
        self.corporateConnectivity = corporateConnectivity
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
            remoteManager: remoteManager,
            networkingController: networkingController,
            corporateConnectivity: corporateConnectivity,
            home: home
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

    public func engineDashboardSnapshot(reply: @escaping (NSDictionary, String) -> Void) {
        guard let dockerTier else {
            reply([:], "docker tier is not configured")
            return
        }
        do {
            let snapshot = try dockerTier.dashboardSnapshot()
            reply(snapshot.mapValues { $0 as NSData } as NSDictionary, "")
        } catch {
            reply([:], "dashboard observation failed: \(error)")
        }
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
        var createdMachineID: String?
        do {
            let typedSettings = try DoryMachineTypedSettingsPatch(
                xpcDictionary: config,
                allowsClears: false
            )
            let sandboxPolicy = try DoryMachineSandboxPolicyWriteAuthority.decodeXPC(
                config
            )
            let machine = try DoryMachineConfiguration(xpcDictionary: config)
            if machine.bootMode == .efi, let installerISOPath = machine.installerISOPath {
                do {
                    _ = try DoryQualifiedBootMediaInspector
                        .inspectPortableLinuxARM64InstallerISO(atPath: installerISOPath)
                } catch {
                    throw MachineManagerError.persistence(
                        "The selected installer is not a portable ARM64 EFI Linux ISO. "
                            + "Choose media with a standard EFI/BOOT/BOOTAA64.EFI loader."
                    )
                }
            }
            var status = try machineManager.create(
                machine,
                typedSettings: typedSettings.isEmpty ? nil : typedSettings,
                sandboxPolicy: sandboxPolicy
            )
            createdMachineID = machine.id
            if machineManager.configuredLaunchPolicy == .perWorkspaceAuthority {
                guard let productionPlanningController else {
                    throw MachineManagerError.persistence(
                        "production planning controller is not configured"
                    )
                }
                status = try machineManager.resolveAndPublishProductionPlan(
                    id: machine.id,
                    controller: productionPlanningController
                )
            }
            incidentWriter?.record(type: "machine.create", detail: machine.id)
            reply(true, status.xpcDictionary, "")
        } catch {
            var message = "\(error)"
            if let createdMachineID {
                do {
                    try machineManager.delete(id: createdMachineID)
                    incidentWriter?.record(
                        type: "machine.create_rolled_back",
                        detail: createdMachineID
                    )
                } catch let rollbackError {
                    message += "; failed to remove the incomplete machine: \(rollbackError)"
                    incidentWriter?.record(
                        type: "machine.create_rollback_failed",
                        detail: "\(createdMachineID): \(rollbackError)"
                    )
                }
            }
            incidentWriter?.record(type: "machine.create_failed", detail: message)
            reply(false, [:], message)
        }
    }

    public func machineStart(
        _ machineID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        machineStart(
            machineID,
            operationID: DoryOperationIdentity.canonical(UUID()),
            reply: reply
        )
    }

    public func machineStart(
        _ machineID: String,
        operationID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let parsedOperationID = DoryOperationIdentity.parseCanonical(operationID) else {
            reply(false, [:], "machine start requires a canonical operation ID")
            return
        }
        machineControl(machineID, action: "start", reply: reply) { manager, id in
            try manager.start(id: id, operationID: parsedOperationID)
        }
    }

    public func machineStop(
        _ machineID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        machineStop(
            machineID,
            operationID: DoryOperationIdentity.canonical(UUID()),
            reply: reply
        )
    }

    public func machineStop(
        _ machineID: String,
        operationID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let parsedOperationID = DoryOperationIdentity.parseCanonical(operationID) else {
            reply(false, [:], "machine stop requires a canonical operation ID")
            return
        }
        machineControl(machineID, action: "stop", reply: reply) { manager, id in
            try manager.stop(id: id, operationID: parsedOperationID)
        }
    }

    public func machinePause(
        _ machineID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        machinePause(
            machineID,
            operationID: DoryOperationIdentity.canonical(UUID()),
            reply: reply
        )
    }

    public func machinePause(
        _ machineID: String,
        operationID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let parsedOperationID = DoryOperationIdentity.parseCanonical(operationID) else {
            reply(false, [:], "machine pause requires a canonical operation ID")
            return
        }
        machineControl(machineID, action: "pause", reply: reply) { manager, id in
            try manager.pause(id: id, operationID: parsedOperationID)
        }
    }

    public func machineSuspend(
        _ machineID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        machineControl(machineID, action: "suspend", reply: reply) { manager, id in
            try manager.suspend(id: id)
        }
    }

    public func machineResume(
        _ machineID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        machineResume(
            machineID,
            operationID: DoryOperationIdentity.canonical(UUID()),
            reply: reply
        )
    }

    public func machineResume(
        _ machineID: String,
        operationID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let parsedOperationID = DoryOperationIdentity.parseCanonical(operationID) else {
            reply(false, [:], "machine resume requires a canonical operation ID")
            return
        }
        machineControl(machineID, action: "resume", reply: reply) { manager, id in
            try manager.resume(id: id, operationID: parsedOperationID)
        }
    }

    public func machineRestart(
        _ machineID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        machineControl(machineID, action: "restart", reply: reply) { manager, id in
            try manager.restart(id: id)
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
            let previousState = machineManager.status(id: machineID)?.state
            let restoresActiveInstallerSession = update.installerMediaAttached != nil
                && (previousState == .running || previousState == .paused)
            var status = try machineManager.update(
                id: machineID,
                memoryMB: update.memoryMB,
                cpuCount: update.cpuCount,
                address: update.address,
                updatesAddress: update.updatesAddress,
                shares: update.shares,
                updatesShares: update.updatesShares,
                typedSettingsPatch: update.typedSettings.isEmpty ? nil : update.typedSettings,
                installerMediaAttached: update.installerMediaAttached
            )
            if machineManager.configuredLaunchPolicy == .perWorkspaceAuthority {
                guard let productionPlanningController else {
                    throw MachineManagerError.persistence(
                        "production planning controller is not configured"
                    )
                }
                status = try machineManager.resolveAndPublishProductionPlan(
                    id: machineID,
                    controller: productionPlanningController
                )
                if restoresActiveInstallerSession {
                    status = try machineManager.start(id: machineID)
                }
            }
            incidentWriter?.record(type: "machine.update", detail: machineID)
            reply(true, status.xpcDictionary, "")
        } catch {
            incidentWriter?.record(type: "machine.update_failed", detail: "\(machineID): \(error)")
            reply(false, [:], "\(error)")
        }
    }

    public func machineDisplayPresentationSet(
        _ machineID: String,
        presentation: NSDictionary,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, [:], "machine manager is not configured")
            return
        }
        do {
            let decoded = try DoryMachineDisplayPresentation(
                xpcDictionary: presentation
            )
            let status = try machineManager.setDisplayPresentation(
                id: machineID,
                presentation: decoded
            )
            reply(true, status.xpcDictionary, "")
        } catch {
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

    public func machineEvents(
        _ afterSequence: UInt64,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineManager, let machineEventStore else {
            reply(false, [:], "machine event stream is not configured")
            return
        }
        machineEventQueryLock.lock()
        defer { machineEventQueryLock.unlock() }
        do {
            let batch = try machineEventStore.reconcile(
                statuses: machineManager.list(),
                afterSequence: afterSequence
            )
            reply(true, batch.xpcDictionary, "")
        } catch {
            reply(false, [:], "machine event stream is unavailable: \(error)")
        }
    }

    public func machineFlightRecorder(
        _ machineID: String,
        afterSequence: UInt64,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, [:], "machine flight recorder is not configured")
            return
        }
        do {
            let batch = try machineManager.flightRecorder(
                id: machineID,
                afterSequence: afterSequence
            )
            reply(true, batch.xpcDictionary, "")
        } catch {
            reply(false, [:], "machine flight recorder is unavailable: \(error)")
        }
    }

    public func machineSerialConsoleRead(
        _ machineID: String,
        cursor: NSDictionary,
        limit: UInt32,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, [:], "machine serial console is not configured")
            return
        }
        do {
            let request = try MachineSerialConsoleCursorRequest(xpcDictionary: cursor)
            guard limit > 0,
                  limit <= UInt32(DoryMachineSerialConsoleAuthority.maximumReadBytes) else {
                throw XPCRemoteConfigError.invalid("machineSerialConsole.limit")
            }
            let batch = try machineManager.serialConsole(
                id: machineID,
                cursor: request.cursor,
                limit: Int(limit)
            )
            reply(true, batch.xpcDictionary, "")
        } catch {
            reply(false, [:], "machine serial console is unavailable: \(error)")
        }
    }

    public func machineSerialConsoleWrite(
        _ machineID: String,
        data: NSData,
        reply: @escaping (Bool, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, "machine serial console is not configured")
            return
        }
        let bytes = data as Data
        guard !bytes.isEmpty,
              bytes.count <= DoryMachineSerialConsoleAuthority.maximumWriteBytes else {
            reply(false, "machine serial console input is invalid")
            return
        }
        do {
            try machineManager.writeSerialConsole(id: machineID, data: bytes)
            reply(true, "")
        } catch {
            reply(false, "machine serial console input is unavailable: \(error)")
        }
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

    public func machineDeviceTelemetry(
        _ machineID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, [:], "machine manager is not configured")
            return
        }
        do {
            let snapshot = try machineManager.deviceTelemetry(id: machineID)
            reply(true, snapshot.xpcDictionary, "")
        } catch {
            reply(false, [:], "\(error)")
        }
    }

    public func hostUSBDevices(reply: @escaping (Bool, NSArray, String) -> Void) {
        do {
            let devices = try DoryHostUSBProjection.validated(hostUSBDiscovery.devices())
            let rows = devices.map(\.xpcDictionary) as NSArray
            reply(true, rows, "")
        } catch {
            reply(false, [], "\(error)")
        }
    }

    public func machineUSBAttach(
        _ machineID: String,
        busID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, [:], "machine manager is not configured")
            return
        }
        do {
            let attachment = try machineManager.attachResolvedUSBDevice(
                id: machineID,
                busID: busID,
                mode: .userAuthorized
            )
            reply(true, attachment.xpcDictionary, "")
        } catch {
            reply(false, [:], "\(error)")
        }
    }

    public func machineUSBDetach(
        _ machineID: String,
        busID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, [:], "machine manager is not configured")
            return
        }
        do {
            try machineManager.detachResolvedUSBDevice(id: machineID, busID: busID)
            reply(true, ["machineID": machineID, "busID": busID], "")
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

    public func machineTransfer(
        _ machineID: String,
        request: NSDictionary,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, [:], "machine manager is not configured")
            return
        }
        let parsedRequest: MachineTransferRequest
        do {
            parsedRequest = try MachineTransferRequest(xpcDictionary: request)
        } catch {
            reply(false, [:], String(describing: error))
            return
        }
        let reply = StatusReply(reply)
        DispatchQueue.global(qos: .utility).async { [incidentWriter] in
            do {
                let result = try machineManager.transferStagedFiles(
                    id: machineID,
                    privateStagingRoot: parsedRequest.privateStagingRoot
                )
                incidentWriter?.record(
                    type: "machine.file_transfer",
                    detail: "\(machineID) \(result.transferID) files=\(result.filesSent) bytes=\(result.bytesSent)"
                )
                reply.reply(true, result.xpcDictionary, "")
            } catch {
                incidentWriter?.record(
                    type: "machine.file_transfer_failed",
                    detail: "\(machineID): \(error)"
                )
                reply.reply(false, [:], String(describing: error))
            }
        }
    }

    public func machineTransferStart(
        _ machineID: String,
        request: NSDictionary,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, [:], "machine manager is not configured")
            return
        }
        do {
            let parsedRequest = try MachineTransferRequest(
                xpcDictionary: request,
                expectedSchema: 2
            )
            let status = try machineManager.beginStagedFileTransfer(
                id: machineID,
                privateStagingRoot: parsedRequest.privateStagingRoot
            )
            incidentWriter?.record(
                type: "machine.file_transfer_started",
                detail: "\(machineID) \(status.operationID)"
            )
            reply(true, status.xpcDictionary, "")
        } catch {
            incidentWriter?.record(
                type: "machine.file_transfer_start_failed",
                detail: "\(machineID): \(error)"
            )
            reply(false, [:], String(describing: error))
        }
    }

    public func machineTransferStatus(
        _ machineID: String,
        operationID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, [:], "machine manager is not configured")
            return
        }
        guard MachineTransferRequest.isValidOperationID(operationID) else {
            reply(false, [:], "invalid machine transfer operation identifier")
            return
        }
        do {
            let status = try machineManager.stagedFileTransferStatus(
                id: machineID,
                operationID: operationID
            )
            reply(true, status.xpcDictionary, "")
        } catch {
            reply(false, [:], String(describing: error))
        }
    }

    public func machineTransferCurrent(
        _ machineID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, [:], "machine manager is not configured")
            return
        }
        let operation = machineManager.currentStagedFileTransferStatus(id: machineID)
        var body: [String: Any] = [
            "schema": UInt16(1),
            "active": operation != nil,
        ]
        if let operation {
            body["operation"] = operation.xpcDictionary
        }
        reply(true, body as NSDictionary, "")
    }

    public func machineTransferCancel(
        _ machineID: String,
        operationID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, [:], "machine manager is not configured")
            return
        }
        guard MachineTransferRequest.isValidOperationID(operationID) else {
            reply(false, [:], "invalid machine transfer operation identifier")
            return
        }
        do {
            let status = try machineManager.cancelStagedFileTransfer(
                id: machineID,
                operationID: operationID
            )
            incidentWriter?.record(
                type: "machine.file_transfer_cancel",
                detail: "\(machineID) \(operationID)"
            )
            reply(true, status.xpcDictionary, "")
        } catch {
            reply(false, [:], String(describing: error))
        }
    }

    public func machineGuestExportStart(
        _ machineID: String,
        request: NSDictionary,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, [:], "machine manager is not configured")
            return
        }
        do {
            let parsedRequest = try MachineGuestExportRequest(xpcDictionary: request)
            let status = try machineManager.beginGuestFileExport(
                id: machineID,
                guestSource: parsedRequest.guestSource
            )
            incidentWriter?.record(
                type: "machine.guest_file_export_started",
                detail: "\(machineID) \(status.operationID)"
            )
            reply(
                true,
                status.xpcDictionary(exposesCompletedResult: false),
                ""
            )
        } catch {
            incidentWriter?.record(
                type: "machine.guest_file_export_start_failed",
                detail: "\(machineID): \(error)"
            )
            reply(false, [:], String(describing: error))
        }
    }

    public func machineGuestExportStatus(
        _ machineID: String,
        operationID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, [:], "machine manager is not configured")
            return
        }
        guard MachineTransferRequest.isValidOperationID(operationID) else {
            reply(false, [:], "invalid guest file export operation identifier")
            return
        }
        do {
            let status = try machineManager.guestFileExportStatus(
                id: machineID,
                operationID: operationID
            )
            reply(true, status.xpcDictionary, "")
        } catch {
            reply(false, [:], String(describing: error))
        }
    }

    public func machineGuestExportCurrent(
        _ machineID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, [:], "machine manager is not configured")
            return
        }
        let operation = machineManager.currentGuestFileExportStatus(id: machineID)
        var body: [String: Any] = [
            "schema": UInt16(1),
            "active": operation != nil,
        ]
        if let operation {
            body["operation"] = operation.xpcDictionary
        }
        reply(true, body as NSDictionary, "")
    }

    public func machineGuestExportCancel(
        _ machineID: String,
        operationID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, [:], "machine manager is not configured")
            return
        }
        guard MachineTransferRequest.isValidOperationID(operationID) else {
            reply(false, [:], "invalid guest file export operation identifier")
            return
        }
        do {
            let status = try machineManager.cancelGuestFileExport(
                id: machineID,
                operationID: operationID
            )
            incidentWriter?.record(
                type: "machine.guest_file_export_cancel",
                detail: "\(machineID) \(operationID)"
            )
            reply(true, status.xpcDictionary, "")
        } catch {
            reply(false, [:], String(describing: error))
        }
    }

    public func machineGuestExportDiscard(
        _ machineID: String,
        operationID: String,
        reply: @escaping (Bool, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, "machine manager is not configured")
            return
        }
        guard MachineTransferRequest.isValidOperationID(operationID) else {
            reply(false, "invalid guest file export operation identifier")
            return
        }
        do {
            try machineManager.discardGuestFileExport(
                id: machineID,
                operationID: operationID
            )
            incidentWriter?.record(
                type: "machine.guest_file_export_discard",
                detail: "\(machineID) \(operationID)"
            )
            reply(true, "")
        } catch {
            reply(false, String(describing: error))
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
            _ = try machineManager.waitUntilAgentReady(id: machineID)
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

    public func machineDesktopUpdate(
        _ machineID: String,
        request: NSDictionary,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, [:], "machine manager is not configured")
            return
        }
        let parsedRequest: DoryDesktopUpdateRequest
        do {
            parsedRequest = try DoryDesktopUpdateRequest(xpcDictionary: request)
        } catch {
            reply(false, [:], String(describing: error))
            return
        }
        let reply = StatusReply(reply)
        DispatchQueue.global(qos: .utility).async { [incidentWriter] in
            do {
                let result = try machineManager.updateDesktop(id: machineID, request: parsedRequest)
                incidentWriter?.record(
                    type: "machine.desktop_update",
                    detail: machineID + " " + result.distro + " " + result.version
                        + " operation=" + result.operationID + " snapshot=" + result.snapshotID
                )
                reply.reply(true, result.xpcDictionary, "")
            } catch {
                incidentWriter?.record(
                    type: "machine.desktop_update_failed",
                    detail: machineID + " operation="
                        + parsedRequest.operationID.uuidString.lowercased()
                        + ": " + String(describing: error)
                )
                reply.reply(false, [:], String(describing: error))
            }
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
            guard let source = manager.status(id: machineID) else {
                throw MachineManagerError.unknownMachine(machineID)
            }
            let shouldRestart = source.state == .starting || source.state == .running
            var status = try manager.restoreSnapshot(
                machineID: machineID,
                snapshotID: snapshotID
            )
            if manager.configuredLaunchPolicy == .perWorkspaceAuthority {
                guard let productionPlanningController else {
                    throw MachineManagerError.persistence(
                        "production planning controller is not configured"
                    )
                }
                status = try manager.resolveAndPublishProductionPlan(
                    id: machineID,
                    controller: productionPlanningController
                )
                if shouldRestart {
                    status = try manager.start(id: machineID)
                }
            }
            return status
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

    public func machineAssessSnapshotImport(
        _ path: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, [:], "machine manager is not configured")
            return
        }
        do {
            let assessment = try machineManager.assessSnapshotImport(
                fromPath: path,
                environment: machineImportEnvironment
            )
            reply(true, assessment.xpcDictionary, "")
        } catch {
            reply(false, [:], "\(error)")
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
            let assessment = try machineManager.assessSnapshotImport(
                fromPath: path,
                environment: machineImportEnvironment
            )
            guard assessment.disposition == .ready
                    || assessment.disposition == .requiresReplanning else {
                throw MachineManagerError.persistence(
                    "machine import preflight rejected: \(assessment.issues.map(\.rawValue).joined(separator: ", "))"
                )
            }
            let snapshot = try machineManager.importSnapshot(
                fromPath: path,
                expectedContentID: assessment.contentID
            )
            incidentWriter?.record(type: "machine.import_snapshot", detail: "\(snapshot.machineID) \(snapshot.id)")
            reply(true, snapshot.xpcDictionary, "")
        } catch {
            incidentWriter?.record(type: "machine.import_snapshot_failed", detail: "\(error)")
            reply(false, [:], "\(error)")
        }
    }

    public func machineImportSnapshot(
        _ path: String,
        expectedContentID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineManager else {
            reply(false, [:], "machine manager is not configured")
            return
        }
        do {
            guard expectedContentID.count == 64,
                  expectedContentID.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw MachineManagerError.persistence("invalid machine import content identifier")
            }
            let assessment = try machineManager.assessSnapshotImport(
                fromPath: path,
                environment: machineImportEnvironment
            )
            guard assessment.contentID == expectedContentID else {
                throw MachineManagerError.persistence(
                    "machine bundle changed after import assessment"
                )
            }
            guard assessment.disposition == .ready
                    || assessment.disposition == .requiresReplanning else {
                throw MachineManagerError.persistence(
                    "machine import preflight rejected: \(assessment.issues.map(\.rawValue).joined(separator: ", "))"
                )
            }
            let snapshot = try machineManager.importSnapshot(
                fromPath: path,
                expectedContentID: expectedContentID
            )
            incidentWriter?.record(
                type: "machine.import_snapshot",
                detail: "\(snapshot.machineID) \(snapshot.id) \(expectedContentID)"
            )
            reply(true, snapshot.xpcDictionary, "")
        } catch {
            incidentWriter?.record(type: "machine.import_snapshot_failed", detail: "\(error)")
            reply(false, [:], "\(error)")
        }
    }

    public func machineBackupSchedules(reply: @escaping (NSArray, String) -> Void) {
        guard let machineBackupScheduler else {
            reply([], "machine backup scheduler is not configured")
            return
        }
        reply(machineBackupScheduler.list().map(\.xpcDictionary) as NSArray, "")
    }

    public func machineBackupSet(
        _ schedule: NSDictionary,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineBackupScheduler else {
            reply(false, [:], "machine backup scheduler is not configured")
            return
        }
        do {
            let status = try machineBackupScheduler.upsert(
                DoryMachineBackupSchedule(xpcDictionary: schedule)
            )
            incidentWriter?.record(
                type: "machine.backup_schedule_set",
                detail: status.schedule.machineID
            )
            reply(true, status.xpcDictionary, "")
        } catch {
            reply(false, [:], "\(error)")
        }
    }

    public func machineBackupRemove(
        _ machineID: String,
        reply: @escaping (Bool, String) -> Void
    ) {
        guard let machineBackupScheduler else {
            reply(false, "machine backup scheduler is not configured")
            return
        }
        do {
            try machineBackupScheduler.remove(machineID: machineID)
            incidentWriter?.record(type: "machine.backup_schedule_removed", detail: machineID)
            reply(true, "")
        } catch {
            reply(false, "\(error)")
        }
    }

    public func machineBackupRun(
        _ machineID: String,
        reply: @escaping (Bool, NSDictionary, String) -> Void
    ) {
        guard let machineBackupScheduler else {
            reply(false, [:], "machine backup scheduler is not configured")
            return
        }
        let reply = StatusReply(reply)
        DispatchQueue.global(qos: .utility).async {
            do {
                let status = try machineBackupScheduler.runNow(machineID: machineID)
                reply.reply(true, status.xpcDictionary, "")
            } catch {
                reply.reply(false, [:], "\(error)")
            }
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
            let decoded = try routes.compactMap { item in
                guard let dictionary = item as? NSDictionary else {
                    throw XPCNetworkRouteError.invalid("route")
                }
                return try DomainRoute(xpcDictionary: dictionary)
            }
            if let customDomainRouteStore {
                _ = try customDomainRouteStore.replace(
                    decoded,
                    automaticSuffix: networkingController.status().suffix
                )
                _ = networkRouteRepair?()
                incidentWriter?.record(type: "network.custom_domains", detail: "\(routes.count) routes")
            } else {
                networkingController.replaceRoutes(decoded)
                incidentWriter?.record(type: "network.routes", detail: "\(routes.count) routes")
            }
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
        let status = NSMutableDictionary(dictionary: networkingController.status().xpcDictionary)
        do {
            status["customRoutes"] = try customDomainRouteStore?.configuredRoutes().map(\.xpcDictionary) ?? []
            reply(status, "")
        } catch {
            reply([:], "\(error)")
        }
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

    public func corporateConnectivityStatus(
        _ runProbes: Bool,
        reply: @escaping (String, String) -> Void
    ) {
        guard let corporateConnectivity else {
            reply("", "corporate connectivity is not configured")
            return
        }
        do {
            reply(try Self.encodeCorporateStatus(corporateConnectivity.currentStatus(runProbes: runProbes)), "")
        } catch {
            reply("", "\(error)")
        }
    }

    public func corporateConnectivityApply(
        _ profileJSON: String,
        dryRun: Bool,
        reply: @escaping (String, String) -> Void
    ) {
        guard let corporateConnectivity else {
            reply("", "corporate connectivity is not configured")
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let profile = try decoder.decode(
                CorporateConnectivityProfile.self,
                from: Data(profileJSON.utf8)
            )
            let status = dryRun
                ? corporateConnectivity.plan(profile, runProbes: false)
                : corporateConnectivity.apply(profile, runProbes: true)
            if !dryRun, !status.valid {
                incidentWriter?.record(
                    type: "network.corporate_apply_failed",
                    detail: status.validationErrors.joined(separator: "; ")
                )
            }
            reply(try Self.encodeCorporateStatus(status), "")
        } catch {
            reply("", "\(error)")
        }
    }

    public func corporateConnectivityDisable(reply: @escaping (String, String) -> Void) {
        guard let corporateConnectivity else {
            reply("", "corporate connectivity is not configured")
            return
        }
        do {
            let status = corporateConnectivity.disable()
            reply(try Self.encodeCorporateStatus(status), "")
        } catch {
            reply("", "\(error)")
        }
    }

    public func repairSubsystem(_ target: String, reply: @escaping (Bool, String) -> Void) {
        do {
            let detail: String
            switch target {
            case "socket":
                guard let dockerTier else { throw SubsystemRepairError.unavailable("docker tier is not configured") }
                detail = try dockerTier.repairSocketForwarder()
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
                let receipt = try dockerTier.repairPublishedPorts()
                detail = Self.publishedPortRepairDetail(receipt)
            case "guest-agent":
                guard let dockerTier else { throw SubsystemRepairError.unavailable("docker tier is not configured") }
                let info = try dockerTier.reconnectAgent()
                detail = "dropped the stale RPC transport and reconnected to guest agent \(info.agentBuild)"
            case "dockerd", "docker-api":
                guard let dockerTier else { throw SubsystemRepairError.unavailable("docker tier is not configured") }
                detail = try dockerTier.repairDockerDaemon()
            case "data-drive":
                let store = try DoryDataDriveSelectionStore(home: home)
                guard let drive = try store.inspectSelection() else {
                    throw SubsystemRepairError.unavailable("no Dory data drive is selected")
                }
                guard try drive.inspect() == .ready else {
                    throw SubsystemRepairError.unavailable("selected data drive is not mounted at \(drive.root)")
                }
                let manifest = try drive.readManifest()
                detail = "revalidated selected drive \(manifest.id.uuidString.lowercased()) at \(drive.root); no data or selection was replaced"
            case "corporate-connectivity":
                guard let corporateConnectivity else {
                    throw SubsystemRepairError.unavailable("corporate connectivity is not configured")
                }
                let status = corporateConnectivity.reconcileCurrent(runProbes: true)
                guard status.valid else {
                    throw SubsystemRepairError.unavailable(status.validationErrors.joined(separator: "; "))
                }
                detail = "reconciled corporate connectivity; \(status.probes.filter(\.succeeded).count)/\(status.probes.count) probes passed"
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

    static func publishedPortRepairDetail(_ receipt: PublishedPortReconcileReceipt) -> String {
        "completed and validated gvproxy reconciliation for \(receipt.publishedPortCount) published port(s) across \(receipt.desiredForwardCount) forward(s), added \(receipt.addedForwardCount), removed \(receipt.removedForwardCount)"
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
        reply(idleStatusSnapshot(), "")
    }

    public func idleHistory(_ limit: Int, reply: @escaping (NSArray, String) -> Void) {
        guard limit > 0, let incidentWriter else {
            reply([], "")
            return
        }
        let rows = incidentWriter
            .read(limit: limit, matchingTypes: ["engine.lifecycle"])
            .reversed()
            .compactMap { incident -> NSDictionary? in
                guard let state = incident.detail,
                      let at = incident.xpcDictionary["at"] as? String else {
                    return nil
                }
                return [
                    "at": at,
                    "state": state,
                ] as NSDictionary
            }
        reply(rows as NSArray, "")
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
            let status = idleStatusSnapshot()
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
                    reply(false, idleStatusSnapshot(), "idle mode failed and its previous value could not be restored: \(error)")
                    return
                }
            }
            incidentWriter?.record(type: "idle.mode_failed", detail: "\(error)")
            reply(false, idleStatusSnapshot(), "\(error)")
        }
    }

    public func idleSetPolicy(_ key: String, value: String, reply: @escaping (Bool, NSDictionary, String) -> Void) {
        runtimeModeLock.lock()
        defer { runtimeModeLock.unlock() }
        do {
            _ = try idlePolicyStore.setPolicy(key: key, value: value)
            updateIdleSleepScheduler()
            incidentWriter?.record(type: "idle.policy", detail: "\(key)=\(value)")
            reply(true, idleStatusSnapshot(), "")
        } catch {
            incidentWriter?.record(type: "idle.policy_failed", detail: "\(key): \(error)")
            reply(false, idleStatusSnapshot(), "\(error)")
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

    private func idleStatusSnapshot() -> NSDictionary {
        var snapshot = idlePolicyStore.status() as? [String: Any] ?? [:]
        guard let dockerTier else {
            snapshot["engine_state"] = [
                "available": false,
                "owner": "doryd",
                "state": "unconfigured",
                "detail": "doryd has no Docker tier configuration",
            ] as NSDictionary
            return snapshot as NSDictionary
        }

        let status = dockerTier.status()
        let detail: String
        switch status.state {
        case .running:
            detail = "Docker API is available at \(status.socketPath)"
        case .sleeping:
            detail = "doryd owns \(status.socketPath); the next Docker request will wake the engine"
        case .starting:
            detail = "doryd is starting the Docker engine"
        case .stopped:
            detail = "the Docker engine is stopped; start it or choose Always On"
        case .failed:
            detail = status.lastError ?? "the Docker engine failed without an attributed error"
        }
        snapshot["engine_state"] = [
            "available": true,
            "owner": "doryd",
            "state": status.state.rawValue,
            "detail": detail,
            "socket_path": status.socketPath,
        ] as NSDictionary
        return snapshot as NSDictionary
    }

    private func promoteEngine(event: String, reply: @escaping (Bool, String) -> Void) {
        guard let dockerTier else {
            reply(false, "docker tier is not configured")
            return
        }
        let replyBox = EngineReply(reply)
        let incidentWriter = incidentWriter
        let corporateConnectivity = corporateConnectivity
        Task.detached {
            do {
                try dockerTier.promoteToRunning()
                _ = corporateConnectivity?.reconcileCurrent(runProbes: false)
                incidentWriter?.record(type: "engine.\(event)", detail: "docker tier running")
                replyBox.reply(true, "")
            } catch {
                incidentWriter?.record(type: "engine.\(event)_failed", detail: "\(error)")
                replyBox.reply(false, "\(error)")
            }
        }
    }

    private static func encodeCorporateStatus(_ status: CorporateConnectivityStatus) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(status), as: UTF8.self)
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

private final class StatusReply: @unchecked Sendable {
    let reply: (Bool, NSDictionary, String) -> Void

    init(_ reply: @escaping (Bool, NSDictionary, String) -> Void) {
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

private struct MachineSerialConsoleCursorRequest {
    var cursor: DoryMachineSerialConsoleCursor

    init(xpcDictionary dictionary: NSDictionary) throws {
        let required: Set<String> = ["schemaVersion", "offset"]
        let optional: Set<String> = ["generation"]
        guard let rawKeys = dictionary.allKeys as? [String] else {
            throw XPCRemoteConfigError.invalid("machineSerialConsole.cursor")
        }
        let keys = Set(rawKeys)
        guard rawKeys.count == keys.count,
              required.isSubset(of: keys),
              keys.subtracting(required).isSubset(of: optional),
              let schema = Self.strictUInt64(dictionary["schemaVersion"]), schema == 1,
              let offset = Self.strictUInt64(dictionary["offset"]),
              dictionary["generation"] == nil
                || dictionary["generation"] is String else {
            throw XPCRemoteConfigError.invalid("machineSerialConsole.cursor")
        }
        cursor = DoryMachineSerialConsoleCursor(
            generation: dictionary["generation"] as? String,
            offset: offset
        )
        guard cursor.isValid else {
            throw XPCRemoteConfigError.invalid("machineSerialConsole.cursor")
        }
    }

    private static func strictUInt64(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let type = String(cString: number.objCType)
        guard ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"]
            .contains(type) else { return nil }
        return UInt64(number.stringValue)
    }
}

private struct MachineTransferRequest: Sendable {
    var privateStagingRoot: String

    init(
        xpcDictionary dictionary: NSDictionary,
        expectedSchema: UInt16 = 1
    ) throws {
        guard let keys = dictionary.allKeys as? [String],
              Set(keys) == ["schema", "privateStagingRoot"],
              let schema = dictionary["schema"] as? NSNumber,
              CFGetTypeID(schema) != CFBooleanGetTypeID(),
              schema.uint16Value == expectedSchema,
              schema.doubleValue == Double(expectedSchema),
              let root = dictionary["privateStagingRoot"] as? String,
              root.hasPrefix("/"),
              !root.contains("\0") else {
            throw XPCRemoteConfigError.invalid("machineTransfer")
        }
        privateStagingRoot = root
    }

    static func isValidOperationID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }
}

private struct MachineGuestExportRequest: Sendable {
    var guestSource: String

    init(xpcDictionary dictionary: NSDictionary) throws {
        guard let keys = dictionary.allKeys as? [String],
              Set(keys) == ["schema", "guestSource"],
              let schema = dictionary["schema"] as? NSNumber,
              CFGetTypeID(schema) != CFBooleanGetTypeID(),
              schema.uint16Value == 1,
              schema.doubleValue == 1,
              let source = dictionary["guestSource"] as? String,
              source.hasPrefix("/"),
              source.utf8.count <= 4_096,
              !source.contains("\0") else {
            throw XPCRemoteConfigError.invalid("machineGuestExport")
        }
        guestSource = source
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

private extension DoryDesktopUpdateRequest {
    init(xpcDictionary dictionary: NSDictionary) throws {
        let legacyKeys: Set<String> = [
            "distro", "version", "distributionInstallationName", "runtimeInstallationName",
        ]
        let currentKeys = legacyKeys.union(["operationID"])
        guard let keys = dictionary.allKeys as? [String],
              Set(keys) == legacyKeys || Set(keys) == currentKeys else {
            throw XPCRemoteConfigError.invalid("desktopUpdateAuthority")
        }
        let operationID: UUID
        if let rawOperationID = dictionary["operationID"] as? String {
            guard let parsed = DoryOperationIdentity.parseCanonical(rawOperationID) else {
                throw XPCRemoteConfigError.invalid("desktopUpdateAuthority.operationID")
            }
            operationID = parsed
        } else {
            operationID = UUID()
        }
        self.init(
            operationID: operationID,
            distro: try dictionary.requiredString("distro"),
            version: try dictionary.requiredString("version"),
            distributionInstallationName: try dictionary.requiredString(
                "distributionInstallationName"
            ),
            runtimeInstallationName: try dictionary.requiredString("runtimeInstallationName")
        )
        guard ["debian", "kali", "ubuntu"].contains(distro),
              version.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._+-]{0,127}/) != nil,
              distributionInstallationName.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._+-]{0,254}/) != nil,
              runtimeInstallationName.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._+-]{0,254}/) != nil else {
            throw XPCRemoteConfigError.invalid("desktopUpdateAuthority")
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
    var typedSettings: DoryMachineTypedSettingsPatch
    var installerMediaAttached: Bool?

    init(xpcDictionary dictionary: NSDictionary) throws {
        guard dictionary[DoryMachineSandboxPolicyWriteAuthority.xpcKey] == nil else {
            throw XPCRemoteConfigError.invalid(
                DoryMachineSandboxPolicyWriteAuthority.xpcKey
            )
        }
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
        self.typedSettings = try DoryMachineTypedSettingsPatch(
            xpcDictionary: dictionary,
            allowsClears: true
        )
        self.installerMediaAttached = dictionary.optionalBool("installerMediaAttached")
        if memoryMB == nil, cpuCount == nil, !updatesAddress, !updatesShares, typedSettings.isEmpty,
           installerMediaAttached == nil {
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
        let rawDisplayMode = dictionary.optionalString("displayMode") ?? DoryMachineDisplayMode.headless.rawValue
        guard let displayMode = DoryMachineDisplayMode(rawValue: rawDisplayMode) else {
            throw MachineManagerError.persistence("unsupported machine display mode: \(rawDisplayMode)")
        }
        let rawBootMode = dictionary.optionalString("bootMode") ?? DoryMachineBootMode.linuxKernel.rawValue
        guard let bootMode = DoryMachineBootMode(rawValue: rawBootMode) else {
            throw MachineManagerError.persistence("unsupported machine boot mode: \(rawBootMode)")
        }
        self.init(
            id: try dictionary.requiredString("id"),
            kernelPath: dictionary.optionalString("kernelPath") ?? "",
            rootfsPath: dictionary.optionalString("rootfsPath") ?? "",
            bootMode: bootMode,
            installerISOPath: dictionary.optionalString("installerISOPath"),
            diskSizeBytes: try dictionary.optionalUInt64("diskSizeBytes"),
            memoryMB: try dictionary.optionalUInt64("memoryMB") ?? 2048,
            cpuCount: try dictionary.optionalInt("cpuCount") ?? 2,
            address: dictionary.optionalString("address"),
            displayMode: displayMode,
            shares: try dictionary.optionalMachineShares("shares"),
            environment: [:]
        )
    }
}

private extension DoryMachineFileTransferResult {
    var xpcDictionary: NSDictionary {
        [
            "schema": UInt16(1),
            "transferID": transferID,
            "guestDestination": guestDestination,
            "filesSent": filesSent,
            "bytesSent": bytesSent,
        ]
    }
}

private extension DoryMachineFileTransferOperationStatus {
    var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "schema": UInt16(1),
            "operationID": operationID,
            "machineID": machineID,
            "phase": phase.rawValue,
            "filesTotal": filesTotal,
            "filesCompleted": filesCompleted,
            "bytesTotal": bytesTotal,
            "bytesCompleted": bytesCompleted,
        ]
        if let currentPath {
            dictionary["currentPath"] = currentPath
        }
        if let guestDestination {
            dictionary["guestDestination"] = guestDestination
        }
        if let result {
            dictionary["result"] = result.xpcDictionary
        }
        if let failure {
            dictionary["failure"] = [
                "schema": UInt16(1),
                "code": failure.code.rawValue,
                "message": failure.message,
            ] as NSDictionary
        }
        return dictionary as NSDictionary
    }
}

private extension DoryMachineGuestFileExportResult {
    var xpcDictionary: NSDictionary {
        [
            "schema": UInt16(1),
            "exportID": exportID,
            "privateStagingRoot": privateStagingRoot,
            "filesReceived": filesReceived,
            "directoriesReceived": directoriesReceived,
            "bytesReceived": bytesReceived,
        ]
    }
}

private extension DoryMachineGuestFileExportOperationStatus {
    var xpcDictionary: NSDictionary {
        xpcDictionary(exposesCompletedResult: true)
    }

    func xpcDictionary(exposesCompletedResult: Bool) -> NSDictionary {
        var dictionary: [String: Any] = [
            "schema": UInt16(1),
            "operationID": operationID,
            "machineID": machineID,
            "phase": phase.rawValue,
            "filesTotal": filesTotal,
            "filesCompleted": filesCompleted,
            "bytesTotal": bytesTotal,
            "bytesCompleted": bytesCompleted,
        ]
        if let currentPath {
            dictionary["currentPath"] = currentPath
        }
        if exposesCompletedResult, let result {
            dictionary["result"] = result.xpcDictionary
        }
        if let failure {
            dictionary["failure"] = [
                "schema": UInt16(1),
                "code": failure.code.rawValue,
                "message": failure.message,
            ] as NSDictionary
        }
        return dictionary as NSDictionary
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
            "privilegedTCPForwards": privilegedTCPForwards.map(\.xpcDictionary),
            "privilegedTCPForwardFailures": privilegedTCPForwardFailures.map { port, detail in
                ["listenPort": port, "detail": detail] as NSDictionary
            },
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
                readOnly: row.optionalBool("readOnly") ?? false,
                authorizationBookmark: try row.optionalData(
                    "authorizationBookmark",
                    maximumBytes: 1_048_576
                )
            )
            guard share.authorizationBookmark != nil else {
                throw XPCRemoteConfigError.invalid("authorizationBookmark")
            }
            try share.validate()
            return share
        }
    }

    func optionalString(_ key: String) -> String? {
        self[key] as? String
    }

    func optionalData(_ key: String, maximumBytes: Int) throws -> Data? {
        guard let value = self[key] else { return nil }
        let data: Data
        if let swiftData = value as? Data {
            data = swiftData
        } else if let nsData = value as? NSData {
            data = nsData as Data
        } else {
            throw XPCRemoteConfigError.invalid(key)
        }
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw XPCRemoteConfigError.invalid(key)
        }
        return data
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
        if let failure, failure.isValid {
            dictionary["failure"] = failure.xpcDictionary
        }
        if let activeOperationID, let activeOperationKind {
            dictionary["activeOperation"] = [
                "operationID": activeOperationID,
                "kind": activeOperationKind,
            ] as NSDictionary
        }
        dictionary["flightRecorder"] = [
            "headSequence": flightRecorderHeadSequence,
            "available": flightRecorderAvailable,
        ] as NSDictionary
        if let handoffSocketPath {
            dictionary["handoffSocketPath"] = handoffSocketPath
        }
        if let agentBuild {
            dictionary["agentBuild"] = agentBuild
        }
        if let agentProtocolVersion {
            dictionary["agentProtocolVersion"] = agentProtocolVersion
        }
        if !agentCapabilities.isEmpty {
            dictionary["agentCapabilities"] = agentCapabilities.map {
                ["id": $0.id, "version": $0.version] as NSDictionary
            }
        }
        dictionary["integrationHealth"] = integrationHealth.xpcDictionary
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
        if let configuredAddress {
            dictionary["configuredAddress"] = configuredAddress
        }
        if let runtimeAddress {
            dictionary["runtimeAddress"] = runtimeAddress
        }
        dictionary["shares"] = shares.map(\.xpcDictionary)
        dictionary["handoffFDCount"] = handoffFDCount
        dictionary["memoryMB"] = memoryMB
        dictionary["currentBalloonTargetMB"] = currentBalloonTargetMB
        dictionary["cpuCount"] = cpuCount
        dictionary["displayMode"] = displayMode.rawValue
        dictionary["bootMode"] = bootMode.rawValue
        dictionary["installerMediaAttached"] = installerMediaAttached
        if let typedSettings {
            dictionary["typedSettings"] = typedSettings.xpcDictionary
        }
        if let sandboxPolicy,
           let encoded = try? DoryMachineSandboxPolicyWriteAuthority.xpcDictionary(
               sandboxPolicy
           ) {
            dictionary[DoryMachineSandboxPolicyWriteAuthority.xpcKey] = encoded
        }
        if !diagnosticOverrides.isEmpty {
            dictionary["diagnosticOverrides"] = diagnosticOverrides.map(\.rawValue)
        }
        dictionary["displayPresentation"] = displayPresentation.xpcDictionary
        dictionary["runtimeIdentity"] = runtimeIdentity.xpcDictionary
        if let runtimeGraphicsSelection, runtimeGraphicsSelection.isValid {
            dictionary["runtimeGraphicsSelection"] = runtimeGraphicsSelection.xpcDictionary
        }
        if let installedDesktopPayloadReceipt {
            dictionary["installedDesktopPayloadReceipt"] =
                installedDesktopPayloadReceipt.xpcDictionary
        }
        if let cloneReceipt, cloneReceipt.isValid {
            dictionary["cloneReceipt"] = [
                "schemaVersion": cloneReceipt.schemaVersion,
                "sourceMachineID": cloneReceipt.sourceMachineID,
                "sourceSnapshotID": cloneReceipt.sourceSnapshotID,
                "sourceRootfsSHA256": cloneReceipt.sourceRootfsSHA256,
                "sourceRootfsByteCount": cloneReceipt.sourceRootfsByteCount,
                "storageMode": cloneReceipt.storageMode.rawValue,
                "createdAtUnixMilliseconds": cloneReceipt.createdAtUnixMilliseconds,
            ] as NSDictionary
        }
        if let savedState {
            dictionary["savedState"] = [
                "schemaVersion": savedState.schemaVersion,
                "backend": savedState.backend.rawValue,
                "stateFileSHA256": savedState.stateFileSHA256,
                "stateFileByteCount": savedState.stateFileByteCount,
                "hostHardwareModel": savedState.hostHardwareModel,
                "hostOperatingSystemBuild": savedState.hostOperatingSystemBuild,
                "createdAtUnixMilliseconds": savedState.createdAtUnixMilliseconds,
                "portable": false,
            ] as NSDictionary
        }
        return dictionary as NSDictionary
    }
}

private extension DoryRuntimeGraphicsSelection {
    var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "schemaVersion": schemaVersion,
            "operationID": operationID,
            "resolvedPlanSHA256": resolvedPlanSHA256,
            "planRevision": planRevision,
            "accelerationLevel": accelerationLevel.rawValue,
            "backend": backend.rawValue,
        ]
        if let rendererGeneration {
            dictionary["rendererGeneration"] = rendererGeneration
        }
        if let rendererWorkerReceiptSHA256 {
            dictionary["rendererWorkerReceiptSHA256"] = rendererWorkerReceiptSHA256
        }
        if let guestProducerFenceProofSHA256 {
            dictionary["guestProducerFenceProofSHA256"] = guestProducerFenceProofSHA256
        }
        return dictionary as NSDictionary
    }
}

private extension DoryMachineFailure {
    var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "schemaVersion": schemaVersion,
            "code": code.rawValue,
            "occurredAtUnixMilliseconds": occurredAtUnixMilliseconds,
            "causalChain": causalChain.map(\.rawValue),
            "recoveryDisposition": recoveryDisposition.rawValue,
            "evidenceReferences": evidenceReferences.map { reference in
                [
                    "kind": reference.kind.rawValue,
                    "identifier": reference.identifier,
                ] as NSDictionary
            },
        ]
        if let operationID { dictionary["operationID"] = operationID }
        return dictionary as NSDictionary
    }
}

private extension DoryMachineImportAssessment {
    var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "schemaVersion": schemaVersion,
            "contentID": contentID,
            "sourceMachineID": sourceMachineID,
            "sourceSnapshotID": sourceSnapshotID,
            "architecture": architecture,
            "bootMode": bootMode.rawValue,
            "diskSizeBytes": diskSizeBytes,
            "virtualHardwareABIVersion": virtualHardwareABIVersion,
            "sourceRuntimeMode": sourceRuntimeMode.rawValue,
            "portable": portable,
            "disposition": disposition.rawValue,
            "issues": issues.map(\.rawValue),
            "components": components.map { component in
                [
                    "componentIdentifier": component.componentIdentifier,
                    "buildIdentifier": component.buildIdentifier,
                    "artifactSHA256": component.artifactSHA256,
                    "availability": component.availability.rawValue,
                ] as NSDictionary
            },
        ]
        if let sourceBackend { dictionary["sourceBackend"] = sourceBackend.rawValue }
        return dictionary as NSDictionary
    }
}

private extension DoryMachineEventBatch {
    var xpcDictionary: NSDictionary {
        [
            "schemaVersion": schemaVersion,
            "headSequence": headSequence,
            "snapshotRequired": snapshotRequired,
            "events": events.map(\.xpcDictionary),
        ]
    }
}

private extension DoryMachineFlightRecorderBatch {
    var xpcDictionary: NSDictionary {
        [
            "schemaVersion": schemaVersion,
            "machineID": machineID,
            "headSequence": headSequence,
            "snapshotRequired": snapshotRequired,
            "events": events.map(\.xpcDictionary),
        ]
    }
}

private extension DoryMachineSerialConsoleBatch {
    var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "schemaVersion": schemaVersion,
            "machineID": machineID,
            "startOffset": startOffset,
            "nextOffset": nextOffset,
            "totalBytes": totalBytes,
            "snapshotRequired": snapshotRequired,
            "inputAvailable": inputAvailable,
            "bytesBase64": bytes.base64EncodedString(),
        ]
        if let generation { dictionary["generation"] = generation }
        return dictionary as NSDictionary
    }
}

private extension DoryMachineFlightEvent {
    var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "schemaVersion": schemaVersion,
            "sequence": sequence,
            "occurredAtUnixMilliseconds": occurredAtUnixMilliseconds,
            "machineID": machineID,
            "kind": kind.rawValue,
            "evidenceReferences": evidenceReferences.map {
                ["kind": $0.kind.rawValue, "identifier": $0.identifier] as NSDictionary
            },
        ]
        if let operationID { dictionary["operationID"] = operationID }
        if let operationKind { dictionary["operationKind"] = operationKind }
        if let phase { dictionary["phase"] = phase }
        if let machineState { dictionary["machineState"] = machineState }
        if let failureCode { dictionary["failureCode"] = failureCode.rawValue }
        if let recoveryDisposition {
            dictionary["recoveryDisposition"] = recoveryDisposition.rawValue
        }
        if let backend { dictionary["backend"] = backend.rawValue }
        if let virtualHardwareABIVersion {
            dictionary["virtualHardwareABIVersion"] = virtualHardwareABIVersion
        }
        if let planSHA256 { dictionary["planSHA256"] = planSHA256 }
        if let durationMilliseconds {
            dictionary["durationMilliseconds"] = durationMilliseconds
        }
        if let deadlineUnixMilliseconds {
            dictionary["deadlineUnixMilliseconds"] = deadlineUnixMilliseconds
        }
        if let deviceID { dictionary["deviceID"] = deviceID }
        if let deviceEventKind { dictionary["deviceEventKind"] = deviceEventKind.rawValue }
        if let deviceEventSequence { dictionary["deviceEventSequence"] = deviceEventSequence }
        if let deviceEventOccurrences {
            dictionary["deviceEventOccurrences"] = deviceEventOccurrences
        }
        return dictionary as NSDictionary
    }
}

private extension DoryDeviceTelemetrySnapshot {
    var xpcDictionary: NSDictionary {
        [
            "schemaVersion": schemaVersion,
            "machineID": machineID,
            "operationID": operationID,
            "backend": backend.rawValue,
            "sampleSequence": sampleSequence,
            "sampledAtUnixMilliseconds": sampledAtUnixMilliseconds,
            "monotonicNanoseconds": monotonicNanoseconds,
            "devices": devices.map(\.xpcDictionary),
            "events": events.map(\.xpcDictionary),
        ]
    }
}

private extension DoryDeviceTelemetryDevice {
    var xpcDictionary: NSDictionary {
        [
            "id": id,
            "kind": kind.rawValue,
            "health": health.rawValue,
            "metrics": metrics.map(\.xpcDictionary),
        ]
    }
}

private extension DoryDeviceTelemetryMetric {
    var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "kind": kind.rawValue,
            "unit": unit.rawValue,
            "availability": availability.rawValue,
        ]
        if let value { dictionary["value"] = value }
        if let unavailableReason { dictionary["unavailableReason"] = unavailableReason }
        return dictionary as NSDictionary
    }
}

private extension DoryDeviceTelemetryEvent {
    var xpcDictionary: NSDictionary {
        [
            "sequence": sequence,
            "monotonicNanoseconds": monotonicNanoseconds,
            "deviceID": deviceID,
            "kind": kind.rawValue,
            "occurrences": occurrences,
        ]
    }
}

private extension DoryMachineEvent {
    var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "schemaVersion": schemaVersion,
            "sequence": sequence,
            "observedAtUnixMilliseconds": observedAtUnixMilliseconds,
            "machineID": machineID,
            "kind": kind.rawValue,
        ]
        if let status { dictionary["status"] = status.xpcDictionary }
        return dictionary as NSDictionary
    }
}

private extension DoryMachineEventStatus {
    var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "schemaVersion": schemaVersion,
            "machineID": machineID,
            "configurationRevision": configurationRevision,
            "observedRevision": observedRevision,
            "state": state,
            "hasFailure": hasFailure,
            "memoryMB": memoryMB,
            "cpuCount": cpuCount,
            "displayMode": displayMode,
            "bootMode": bootMode,
            "installerMediaAttached": installerMediaAttached,
            "shareCount": shareCount,
            "integrationHealth": integrationHealth,
            "runtimeMode": runtimeMode,
            "virtualHardwareABIVersion": virtualHardwareABIVersion,
        ]
        if let failureCode { dictionary["failureCode"] = failureCode }
        if let recoveryDisposition {
            dictionary["recoveryDisposition"] = recoveryDisposition
        }
        if let operationID { dictionary["operationID"] = operationID }
        if let operationKind { dictionary["operationKind"] = operationKind }
        if let planRevision { dictionary["planRevision"] = planRevision }
        if let planSHA256 { dictionary["planSHA256"] = planSHA256 }
        if let backend { dictionary["backend"] = backend }
        if let savedStateSHA256 { dictionary["savedStateSHA256"] = savedStateSHA256 }
        return dictionary as NSDictionary
    }
}

private extension DoryInstalledDesktopPayloadReceipt {
    var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "schemaVersion": schemaVersion,
            "provenance": provenance.rawValue,
            "distributionIdentifier": distributionIdentifier,
            "releaseVersion": releaseVersion,
            "inputSHA256": inputSHA256,
        ]
        if let bundleSHA256 {
            dictionary["bundleSHA256"] = bundleSHA256
        }
        if let distributionComponentIdentifier {
            dictionary["distributionComponentIdentifier"] = distributionComponentIdentifier
        }
        if let distributionInstallationName {
            dictionary["distributionInstallationName"] = distributionInstallationName
        }
        if let distributionCatalogSHA256 {
            dictionary["distributionCatalogSHA256"] = distributionCatalogSHA256
        }
        if let bundleAssetIdentifier {
            dictionary["bundleAssetIdentifier"] = bundleAssetIdentifier
        }
        if let runtimeComponentIdentifier {
            dictionary["runtimeComponentIdentifier"] = runtimeComponentIdentifier
        }
        if let runtimeInstallationName {
            dictionary["runtimeInstallationName"] = runtimeInstallationName
        }
        if let runtimeCatalogSHA256 {
            dictionary["runtimeCatalogSHA256"] = runtimeCatalogSHA256
        }
        if let kernelAssetIdentifier {
            dictionary["kernelAssetIdentifier"] = kernelAssetIdentifier
        }
        if let kernelSHA256 {
            dictionary["kernelSHA256"] = kernelSHA256
        }
        return dictionary as NSDictionary
    }
}

private extension DoryMachineRuntimeIdentity {
    var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "schemaVersion": schemaVersion,
            "mode": mode.rawValue,
            "virtualHardwareABIVersion": virtualHardwareABIVersion,
        ]
        if let invalidationReason {
            dictionary["invalidationReason"] = invalidationReason.rawValue
        }
        guard let plan = resolvedPlan, let resolvedPlanSHA256 else {
            return dictionary as NSDictionary
        }
        dictionary["definitionRevision"] = plan.definitionRevision
        if let definitionSHA256 = plan.definitionSHA256 {
            dictionary["definitionSHA256"] = definitionSHA256
        }
        dictionary["planRevision"] = plan.planRevision
        dictionary["planSHA256"] = resolvedPlanSHA256
        dictionary["backend"] = plan.backend.rawValue
        dictionary["backendImplementationIdentifier"] = plan.backendImplementationIdentifier
        dictionary["backendRuntimeBuildIdentifier"] = plan.backendRuntimeBuildIdentifier
        dictionary["supportTier"] = plan.supportTier.rawValue
        dictionary["graphics"] = plan.graphics.rawValue
        dictionary["removableUSBHotplug"] = plan.devices.removableUSBHotplug
        if let selectionDisposition = plan.selectionEvidence?.disposition {
            dictionary["selectionDisposition"] = selectionDisposition.rawValue
        }
        if let fallback = plan.selectionEvidence?.fallbackAuthorization {
            dictionary["fallbackAuthorizationIdentity"] = fallback.authorizationIdentity
        }
        if let experimental = plan.experimentalAuthorization {
            dictionary["experimentalAuthorizationIdentity"] = experimental.authorizationIdentity
        }
        if let graphics = plan.qualificationEvidence.graphics {
            dictionary["graphicsQualification"] = [
                "manifestIdentity": graphics.manifestIdentity,
                "artifactSHA256": graphics.artifactSHA256,
                "manifestSHA256": graphics.manifestSHA256,
                "signingKeyID": graphics.signingKeyID,
            ] as NSDictionary
        }
        if let runtime = plan.qualificationEvidence.runtime {
            dictionary["runtimeQualification"] = [
                "qualificationIdentity": runtime.qualificationIdentity,
                "qualificationReportSHA256": runtime.qualificationReportSHA256,
                "signingKeyID": runtime.signingKeyID,
            ] as NSDictionary
        }
        if let host = plan.hostQualification {
            dictionary["hostQualification"] = [
                "qualificationIdentity": host.qualificationIdentity,
                "qualificationReportSHA256": host.qualificationReportSHA256,
                "qualifierIdentifier": host.qualifierIdentifier,
            ] as NSDictionary
        }
        dictionary["components"] = plan.components.map { component in
            [
                "componentIdentifier": component.componentIdentifier,
                "buildIdentifier": component.buildIdentifier,
                "artifactSHA256": component.artifactSHA256,
            ] as NSDictionary
        }
        var media: [String: Any] = [
            "kind": plan.bootMedia.media.kind.rawValue,
            "source": plan.bootMedia.media.source.rawValue,
        ]
        if let digest = plan.bootMedia.media.artifactSHA256 {
            media["artifactSHA256"] = digest
        }
        if let reference = plan.bootMedia.resolverReference {
            media["resolverNamespace"] = reference.namespace
            media["resolverIdentifier"] = reference.identifier
        }
        if let inspection = plan.bootMedia.inspectionEvidence {
            media["inspectionIdentity"] = inspection.inspectionIdentity
            media["inspectionReportSHA256"] = inspection.inspectionReportSHA256
        }
        if let provenance = plan.bootMedia.mutableProvenanceEvidence {
            media["provenanceReceiptIdentity"] = provenance.receiptIdentity
            media["provenanceReceiptSHA256"] = provenance.receiptSHA256
            media["provenanceRevision"] = provenance.provenance.revision
        }
        dictionary["bootMedia"] = media as NSDictionary
        return dictionary as NSDictionary
    }
}

private extension DoryMachineSnapshotArtifactEvidence {
    var xpcDictionary: NSDictionary {
        func artifact(_ value: DoryMachineSnapshotArtifact) -> NSDictionary {
            ["byteCount": value.byteCount, "sha256": value.sha256]
        }
        var dictionary: [String: Any] = [
            "schemaVersion": schemaVersion,
            "rootfs": artifact(rootfs),
            "kernel": artifact(kernel),
        ]
        if let machineIdentifier { dictionary["machineIdentifier"] = artifact(machineIdentifier) }
        if let nvram { dictionary["nvram"] = artifact(nvram) }
        return dictionary as NSDictionary
    }
}

private extension DoryMachineSnapshotQuiesceReceipt {
    var xpcDictionary: NSDictionary {
        [
            "schemaVersion": schemaVersion,
            "receiptID": receiptID,
            "agentBuild": agentBuild,
            "agentProtocolVersion": agentProtocolVersion,
            "capabilityVersion": capabilityVersion,
        ]
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
            "capabilities": capabilities.map {
                ["id": $0.id, "version": $0.version] as NSDictionary
            },
        ]
    }
}

private extension DoryGuestIntegrationHealth {
    var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "schemaVersion": schemaVersion,
            "state": state.rawValue,
            "runtimeAuthority": runtimeAuthority.rawValue,
            "features": features.map(\.xpcDictionary),
        ]
        if let agentBuild { dictionary["agentBuild"] = agentBuild }
        if let agentProtocolVersion {
            dictionary["agentProtocolVersion"] = agentProtocolVersion
        }
        return dictionary as NSDictionary
    }
}

private extension DoryGuestIntegrationFeatureHealth {
    var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "id": id.rawValue,
            "provider": provider.rawValue,
            "required": required,
            "state": state.rawValue,
        ]
        if let minimumVersion { dictionary["minimumVersion"] = minimumVersion }
        if let negotiatedVersion { dictionary["negotiatedVersion"] = negotiatedVersion }
        return dictionary as NSDictionary
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
        var dictionary: [String: Any] = [
            "id": id,
            "machineID": machineID,
            "note": note,
            "createdISO": createdISO,
            "rootfsPath": rootfsPath,
            "sizeBytes": sizeBytes,
            "kernelPath": kernelPath,
            "architecture": architecture,
            "memoryMB": memoryMB,
            "cpuCount": cpuCount,
            "displayMode": displayMode.rawValue,
            "consistency": consistency.rawValue,
            "runtimeIdentity": runtimeIdentity.xpcDictionary,
        ]
        if let artifactEvidence {
            dictionary["artifactEvidence"] = artifactEvidence.xpcDictionary
        }
        if let guestQuiesceReceipt {
            dictionary["guestQuiesceReceipt"] = guestQuiesceReceipt.xpcDictionary
        }
        let receipt = installedDesktopPayloadReceipt
            ?? DoryInstalledDesktopPayloadReceipt.legacyEnvironment(environment)
        if let receipt {
            dictionary["installedDesktopPayloadReceipt"] = receipt.xpcDictionary
        }
        return dictionary as NSDictionary
    }
}

private extension DoryDesktopUpdateResult {
    var xpcDictionary: NSDictionary {
        [
            "operationID": operationID,
            "machineID": machineID,
            "distro": distro,
            "version": version,
            "inputSHA256": inputSHA256,
            "bundleSHA256": bundleSHA256,
            "snapshotID": snapshotID,
            "status": status.xpcDictionary,
            "restoredRunningState": restoredRunningState,
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
        guard DorydXPCSecurity.configureIncomingConnection(connection) else {
            return false
        }
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
