import AppKit
import Darwin
import DoryFirmware
import DoryHV
import DoryMachinePC
import DoryOperations
import DoryVirtio
import DorydKit
import DoryVMMKit
import Foundation

enum DoryPCMode {
    /// A resolved device contract is launch authority, not a best-effort preference. Once a host
    /// device is requested, construction or attachment failure must abort the launch instead of
    /// publishing a VM whose actual device graph no longer matches its immutable envelope.
    static func admitRequiredHostDevice<Device>(
        requested: Bool,
        make: () throws -> Device
    ) throws -> Device? {
        guard requested else { return nil }
        return try make()
    }

    /// DoryPC accelerated graphics is a signed renderer-worker contract, not a fallback hint. The
    /// runner may build a VirGL authority only for hardware-3D launches that also have a display;
    /// software/no-graphics launches must leave the renderer path unobserved so stale descriptors
    /// cannot widen authority after admission.
    static func admitRequiredGPUAcceleration<Authority>(
        graphics: DoryGraphicsAccelerationLevel,
        hasDisplay: Bool,
        make: () throws -> Authority
    ) throws -> Authority? {
        switch graphics {
        case .none, .software:
            return nil
        case .hostAcceleratedDisplay:
            throw VMError.invalidConfiguration(
                "DoryPC host-accelerated display requires a separate admitted graphics contract"
            )
        case .hardwareAccelerated3D:
            guard hasDisplay else {
                throw VMError.invalidConfiguration(
                    "DoryPC accelerated graphics requires an admitted display"
                )
            }
            return try make()
        }
    }

    /// DoryPC's gvproxy sockets are ephemeral runtime endpoints. Derive their directory from the
    /// already-admitted lifecycle socket rather than the persistent machine bundle, whose path can
    /// legitimately exceed Darwin's `sockaddr_un.sun_path` limit.
    static func ephemeralRuntimeDirectory(controlSocketPath: String) -> String? {
        guard controlSocketPath.hasPrefix("/"),
              !controlSocketPath.utf8.contains(0) else { return nil }
        let directory = URL(fileURLWithPath: controlSocketPath)
            .deletingLastPathComponent().standardizedFileURL.path
        guard directory != "/", !directory.isEmpty else { return nil }
        return directory
    }

    struct Configuration {
        let envelope: DoryPCRuntimeLaunchEnvelope
        let authority: DoryPCUEFIRuntimeAuthority
        let stateDirectory: String
        let handoffSocketPath: String
        let agentSocketPath: String
        let shellSocketPath: String
        let consoleSocketPath: String
        let controlSocketPath: String
        let usbControlSocketPath: String?
        let sshAgentSocketPath: String?
        let gvproxyPath: String
        let shares: [DoryMachineShareConfiguration]
        let displayPresentation: DoryMachineDisplayPresentation
        let reconnectIdentity: DoryRuntimeReconnectLaunchIdentity
        var rendererWorkerLaunch: DesktopRendererWorkerLaunch? = nil
    }

    @MainActor
    static func run(_ configuration: Configuration) throws {
        let controller = try Controller(configuration: configuration)
        try controller.run()
    }

    @MainActor
    private final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate {
        private final class FirstFrameRelay: @unchecked Sendable {
            private let lock = NSLock()
            private var delivered = false
            private var operation: (@Sendable () -> Void)?

            func install(_ operation: @escaping @Sendable () -> Void) {
                let deliverNow = lock.withLock { () -> Bool in
                    self.operation = operation
                    return delivered
                }
                if deliverNow { operation() }
            }

            func deliver() {
                let operation = lock.withLock { () -> (@Sendable () -> Void)? in
                    guard !delivered else { return nil }
                    delivered = true
                    return self.operation
                }
                operation?()
            }
        }

        private class FailureRelay: @unchecked Sendable {
            private let lock = NSLock()
            private var failureStorage: String?
            private var stop: (@Sendable () -> Void)?

            var failure: String? { lock.withLock { failureStorage } }

            func installStop(_ operation: @escaping @Sendable () -> Void) {
                let shouldStop = lock.withLock { () -> Bool in
                    stop = operation
                    return failureStorage != nil
                }
                if shouldStop { operation() }
            }

            func report(_ reason: String) {
                let operation = lock.withLock { () -> (@Sendable () -> Void)? in
                    if failureStorage == nil { failureStorage = reason }
                    return stop
                }
                operation?()
            }
        }

        private final class FilesystemFailureRelay: FailureRelay, @unchecked Sendable {
            func report(_ event: VirtioFSWorkerLifecycleEvent) {
                guard case .failure(let reason) = event else { return }
                report(reason)
            }
        }

        private final class MachineState: @unchecked Sendable {
            private let lock = NSLock()
            let executionPause = GuestExecutionPauseCoordinator()
            private var machine: DoryPCUEFIMachine
            private var dynamicDisplaySize: (width: UInt32, height: UInt32)?
            private var stopping = false

            init(
                machine: DoryPCUEFIMachine,
                dynamicDisplaySize: (width: UInt32, height: UInt32)?
            ) {
                self.machine = machine
                self.dynamicDisplaySize = dynamicDisplaySize
            }

            func current() -> DoryPCUEFIMachine { lock.withLock { machine } }

            func replace(_ replacement: DoryPCUEFIMachine) -> Bool {
                lock.withLock {
                    guard !stopping else { return false }
                    if let dynamicDisplaySize {
                        _ = replacement.displayDevice.updateScanoutSize(
                            scanoutID: 0,
                            width: dynamicDisplaySize.width,
                            height: dynamicDisplaySize.height
                        )
                    }
                    machine = replacement
                    return true
                }
            }

            func updateDisplaySize(width: UInt32, height: UInt32) {
                lock.withLock {
                    guard dynamicDisplaySize != nil,
                          machine.displayDevice.updateScanoutSize(
                            scanoutID: 0,
                            width: width,
                            height: height
                          ) else { return }
                    dynamicDisplaySize = (width, height)
                }
            }

            func requestStop() {
                executionPause.stop()
                let current = lock.withLock { () -> DoryPCUEFIMachine? in
                    guard !stopping else { return nil }
                    stopping = true
                    return machine
                }
                current?.machine.powerController.request(.powerOff)
            }

            func requestGuestShutdown(
                graceful: Bool,
                agentSocketPath: String,
                keyboardInput: DoryPCDesktopInputSink,
                log: @escaping @Sendable (String) -> Void
            ) {
                let current = lock.withLock { () -> DoryPCUEFIMachine? in
                    guard !stopping else { return nil }
                    stopping = true
                    return machine
                }
                guard let current else { return }
                // Graceful shutdown must be able to execute the guest's shutdown request.
                try? executionPause.resume()
                guard graceful else {
                    current.machine.powerController.request(.powerOff)
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let control = DorydKit.AgentControl(configuration: .init(
                            directSocketPath: agentSocketPath
                        ))
                        defer { control.disconnect() }
                        let result = try control.exec(
                            argv: [
                                "/bin/sh", "-c",
                                GuestShutdownCommand.detachedDesktopRequest(),
                            ],
                            timeoutMs: 5_000,
                            outputLimitBytes: 64 * 1_024
                        )
                        guard result.exitCode == 0, !result.timedOut else {
                            throw VMError.bootFailure(
                                "guest shutdown request exited \(result.exitCode)"
                            )
                        }
                    } catch {
                        log("graceful shutdown RPC failed; sending ACPI power key: \(error)")
                        keyboardInput.send(frame: [
                            .init(type: 1, code: 116, value: 1),
                            .init(type: 1, code: 116, value: 0),
                        ])
                    }
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(
                        deadline: .now() + DoryEngineShutdownTiming.helperWatchdogSeconds
                    ) {
                        log("graceful guest shutdown timed out; forcing power off")
                        current.machine.powerController.request(.powerOff)
                    }
                }
            }

            var isStopping: Bool { lock.withLock { stopping } }
        }

        private final class ReadyPublisher: @unchecked Sendable {
            private let lock = NSLock()
            private var published = false
            private var presentationReady = false
            private var rendererPresentationReady: Bool
            private var guestServicesReady: Bool
            private let publishOperation: @Sendable () throws -> Void

            init(
                requiresGuestServices: Bool,
                requiresRendererPresentation: Bool = false,
                _ publishOperation: @escaping @Sendable () throws -> Void
            ) {
                rendererPresentationReady = !requiresRendererPresentation
                guestServicesReady = !requiresGuestServices
                self.publishOperation = publishOperation
            }

            func markPresentationReady() throws {
                try markReady { presentationReady = true }
            }

            func markRendererPresentationReady() throws {
                try markReady { rendererPresentationReady = true }
            }

            func markGuestServicesReady() throws {
                try markReady { guestServicesReady = true }
            }

            private func markReady(_ mutation: () -> Void) throws {
                let shouldPublish = lock.withLock { () -> Bool in
                    mutation()
                    guard !published else { return false }
                    guard presentationReady, rendererPresentationReady, guestServicesReady else {
                        return false
                    }
                    published = true
                    return true
                }
                guard shouldPublish else { return }
                do {
                    try publishOperation()
                } catch {
                    lock.withLock { published = false }
                    throw error
                }
            }
        }

        private let configuration: Configuration
        private let application = NSApplication.shared
        private let stateLock: EngineStateDirectoryLock
        private let serialLog: FileHandle
        private let serialOutput: BoundedSerialConsolePublisher
        private let serialInput: RawHVSerialConsoleInput
        private let lifecycleServer: VmmLifecycleReceiptServer
        private let networkBackend: any DoryVirtioNetworkBackend
        private let networkRuntime: DoryPCGVProxyNetworkBackend?
        private let vsock: VirtioVsock
        private let agentBridge: GuestVsockSocketBridge
        private let shellBridge: GuestVsockSocketBridge
        private let sshAgentBridge: HostSSHAgentBridge?
        private let filesystemRuntime: DoryPCFilesystemRuntime?
        private let filesystemFailureRelay: FilesystemFailureRelay
        private let rendererFailureRelay: FailureRelay
        private let clipboard: DoryDesktopClipboardCoordinator?
        private let machineState: MachineState
        private let keyboardInput: DoryPCDesktopInputSink
        private let pointerInput: DoryPCDesktopInputSink
        private let displaySink: DoryPCSoftwareDisplaySink?
        private let gpuAccelerationAuthority: DoryPCVirGLRendererAuthority?
        private let rendererWorkerLaunch: DesktopRendererWorkerLaunch?
        private let cameraBridge: DoryPCCameraBridge?
        private let audioBackend: DoryPCMacAudioBackend?
        private let usbControlHandler: DoryPCUSBControlHandler?
        private let usbControlServer: UsbControlServer?
        private let mailbox: DesktopFrameMailbox?
        private let window: NSWindow?
        private let readyPublisher: ReadyPublisher
        private let executionQueue = DispatchQueue(
            label: "dev.dory.dory-hv.dorypc.execution",
            qos: .userInitiated
        )
        private let signalQueue = DispatchQueue(
            label: "dev.dory.dory-hv.dorypc.signals",
            qos: .userInitiated
        )
        private let guestServiceQueue = DispatchQueue(
            label: "dev.dory.dory-hv.dorypc.guest-services",
            qos: .userInitiated
        )
        private var signalSources = [DispatchSourceSignal]()
        private var stopError: Error?

        init(configuration: Configuration) throws {
            let envelope = configuration.envelope
            let rendererWorkerLaunch = configuration.rendererWorkerLaunch
            switch (envelope.graphics, rendererWorkerLaunch) {
            case (.none, nil), (.software, nil), (.hardwareAccelerated3D, .some):
                break
            case (.hostAcceleratedDisplay, _):
                throw VMError.invalidConfiguration(
                    "DoryPC host-accelerated display requires a separate admitted graphics contract"
                )
            case (.hardwareAccelerated3D, nil):
                throw VMError.invalidConfiguration(
                    "DoryPC accelerated graphics requires the signed renderer authority"
                )
            case (.none, .some), (.software, .some):
                throw VMError.invalidConfiguration(
                    "DoryPC software graphics must not receive renderer authority"
                )
            }
            self.rendererWorkerLaunch = rendererWorkerLaunch
            let devices = envelope.devices
            guard devices.networkAttachment != .bridged else {
                throw VMError.invalidConfiguration(
                    "DoryPC launch requested a host device backend that is not admitted by this runner"
                )
            }
            let clipboardPolicy: DoryVMClipboardPolicy?
            if devices.clipboard {
                guard let policy = devices.clipboardPolicy, policy.isEnabled else {
                    throw VMError.invalidConfiguration(
                        "DoryPC clipboard requires an explicit enabled transfer policy"
                    )
                }
                clipboardPolicy = policy
            } else {
                clipboardPolicy = nil
            }
            self.configuration = configuration
            guard devices.directorySharing == !configuration.shares.isEmpty else {
                throw VMError.invalidConfiguration(
                    "DoryPC directory-sharing contract does not match launch shares"
                )
            }
            let rawShares = try configuration.shares.map { share in
                try VirtioFSShareConfiguration(
                    tag: share.tag,
                    path: share.hostPath,
                    readOnly: share.readOnly,
                    guestMountPoint: share.guestPath
                )
            }
            let filesystemFailureRelay = FilesystemFailureRelay()
            self.filesystemFailureRelay = filesystemFailureRelay
            let rendererFailureRelay = FailureRelay()
            self.rendererFailureRelay = rendererFailureRelay
            let filesystemRuntime = rawShares.isEmpty ? nil : try DoryPCFilesystemRuntime(
                shares: rawShares,
                virtualCPUCount: Int(envelope.executionResources.virtualCPUCount),
                onWorkerLifecycle: { [filesystemFailureRelay] event in
                    filesystemFailureRelay.report(event)
                }
            )
            self.filesystemRuntime = filesystemRuntime
            try FileManager.default.createDirectory(
                atPath: configuration.stateDirectory,
                withIntermediateDirectories: true
            )
            stateLock = try EngineStateDirectoryLock(stateDirectory: configuration.stateDirectory)
            serialLog = try Self.openSerialLog(configuration.stateDirectory + "/serial.log")
            serialOutput = try BoundedSerialConsolePublisher(destinations: [
                .init(fileHandle: FileHandle.standardError),
                .init(fileHandle: serialLog, synchronizeOnStop: true),
            ])

            let networkRuntime: DoryPCGVProxyNetworkBackend?
            let networkBackend: any DoryVirtioNetworkBackend
            switch devices.networkAttachment {
            case .disconnected:
                networkRuntime = nil
                networkBackend = DoryVirtioInMemoryNetworkBackend()
            case .sharedNAT, .isolated:
                guard let interface = devices.networkInterface else {
                    throw VMError.invalidConfiguration("DoryPC network identity is missing")
                }
                guard let runtimeDirectory = DoryPCMode.ephemeralRuntimeDirectory(
                    controlSocketPath: configuration.controlSocketPath
                ) else {
                    throw VMError.invalidConfiguration(
                        "DoryPC lifecycle socket does not identify a runtime directory"
                    )
                }
                let connected = try DoryPCGVProxyNetworkBackend(
                    gvproxyPath: configuration.gvproxyPath,
                    stateDirectory: runtimeDirectory,
                    attachment: devices.networkAttachment,
                    interface: interface,
                    portForwards: envelope.portForwards
                )
                networkRuntime = connected
                networkBackend = connected
            case .bridged:
                throw VMError.invalidConfiguration("DoryPC bridged networking is not admitted")
            }
            self.networkRuntime = networkRuntime
            self.networkBackend = networkBackend

            let mailbox = devices.displays.isEmpty ? nil : DesktopFrameMailbox(scanoutID: 0)
            self.mailbox = mailbox
            let readyPublisher = ReadyPublisher(
                // DoryPC-v1 boots user-supplied Linux media. The VirtIO display is part of the
                // machine contract, but a Dory guest agent is not. Agent-backed conveniences may
                // come online after boot; they cannot prevent a valid generic installation from
                // publishing readiness or completing its first disk-boot proof.
                requiresGuestServices: false,
                requiresRendererPresentation: rendererWorkerLaunch != nil
            ) {
                let graphics: DoryRuntimeGraphicsSelection?
                switch envelope.graphics {
                case .software:
                    graphics = DoryRuntimeGraphicsSelection.resolvedSoftware(
                        operationID: envelope.operationID,
                        resolvedPlanSHA256: envelope.resolvedPlanSHA256,
                        planRevision: envelope.planRevision
                    )
                case .hardwareAccelerated3D:
                    guard let rendererWorkerLaunch else {
                        throw VMError.invalidConfiguration(
                            "DoryPC accelerated readiness is missing renderer authority"
                        )
                    }
                    graphics = DoryRuntimeGraphicsSelection(
                        operationID: DoryOperationIdentity.canonical(envelope.operationID),
                        resolvedPlanSHA256: envelope.resolvedPlanSHA256,
                        planRevision: envelope.planRevision,
                        accelerationLevel: .hardwareAccelerated3D,
                        backend: .virgl,
                        rendererGeneration: rendererWorkerLaunch.workerGeneration.rawValue,
                        rendererWorkerReceiptSHA256:
                            rendererWorkerLaunch.rendererWorkerReceiptSHA256,
                        guestProducerFenceProofSHA256:
                            rendererWorkerLaunch.qualifiedProducerFenceAuthoritySHA256
                    )
                case .none:
                    graphics = nil
                case .hostAcceleratedDisplay:
                    throw VMError.invalidConfiguration(
                        "DoryPC host-accelerated display is not admitted"
                    )
                }
                try VmmHandoffClient.send(
                    path: configuration.handoffSocketPath,
                    ready: VmmReadyMessage(
                        machineID: envelope.machineID,
                        operationID: DoryOperationIdentity.canonical(envelope.operationID),
                        controlSocketPath: configuration.controlSocketPath,
                        graphicsSelection: graphics,
                        detail: "DoryPC-v1 x86_64 Linux firmware has begun executing through DoryDBT"
                    )
                )
            }
            self.readyPublisher = readyPublisher
            let firstFrameRelay = FirstFrameRelay()
            let displaySink = mailbox.map { mailbox in
                DoryPCSoftwareDisplaySink(mailbox: mailbox) { firstFrameRelay.deliver() }
            }
            self.displaySink = displaySink
            if let mailbox, let displaySink {
                mailbox.installCPUFramePresentationObserver { [weak displaySink] frame in
                    displaySink?.hostDidPresent(frame)
                }
            }
            let gpuAccelerationAuthority = try DoryPCMode.admitRequiredGPUAcceleration(
                graphics: envelope.graphics,
                hasDisplay: mailbox != nil
            ) { () -> DoryPCVirGLRendererAuthority in
                guard let rendererWorkerLaunch, let mailbox else {
                    throw VMError.invalidConfiguration(
                        "DoryPC accelerated graphics requires the signed renderer authority"
                    )
                }
                return try DoryPCVirGLRendererAuthority(
                    lane: rendererWorkerLaunch.commandLane,
                    deviceGeneration: DesktopRendererWorkerLaunch.initialDeviceGeneration,
                    scanoutSink: { [mailbox, firstFrameRelay] update in
                        guard mailbox.submit(update) else { return false }
                        firstFrameRelay.deliver()
                        return true
                    }
                )
            }
            self.gpuAccelerationAuthority = gpuAccelerationAuthority
            let audioBackend = devices.audioInput || devices.audioOutput
                ? DoryPCMacAudioBackend { message in
                    FileHandle.standardError.write(
                        Data("dory-hv DoryPC audio: \(message)\n".utf8)
                    )
                } : nil
            self.audioBackend = audioBackend
            let vsock = VirtioVsock(guestCID: 3)
            self.vsock = vsock
            let vsockPCI = try DoryPCVirtioVsockPCIDevice(
                address: DoryPCV1ABI.vsockPCIAddress,
                initialBARAddress: DoryPCV1ABI.vsockBARAddress,
                vsock: vsock
            )
            let filesystemFunctions = try filesystemRuntime?.start() ?? []
            let machine = try configuration.authority.makeMachine(
                displaySink: displaySink,
                gpuAccelerationAuthority: gpuAccelerationAuthority,
                soundBackend: audioBackend ?? DoryVirtioInMemorySoundBackend(),
                networkBackend: networkBackend,
                additionalPCIFunctions: [vsockPCI] + filesystemFunctions
            )
            if devices.networkAttachment == .disconnected {
                _ = machine.networkDevice.setLinkUp(false)
            }
            let dynamicDisplaySize = devices.dynamicDisplay
                ? devices.displays.first.map {
                    (width: $0.widthPixels, height: $0.heightPixels)
                }
                : nil
            machineState = MachineState(
                machine: machine,
                dynamicDisplaySize: dynamicDisplaySize
            )
            filesystemFailureRelay.installStop { [machineState] in
                machineState.current().machine.powerController.request(.powerOff)
            }
            rendererFailureRelay.installStop { [machineState] in
                machineState.current().machine.powerController.request(.powerOff)
            }
            let keyboardInput = DoryPCDesktopInputSink(device: machine.keyboardDevice)
            self.keyboardInput = keyboardInput
            pointerInput = DoryPCDesktopInputSink(device: machine.tabletDevice)
            let agentBridge = GuestVsockSocketBridge(
                socketPath: configuration.agentSocketPath,
                guestPort: VsockPorts.agent,
                service: .agentSocket,
                log: Self.log
            )
            let shellBridge = GuestVsockSocketBridge(
                socketPath: configuration.shellSocketPath,
                guestPort: 1_027,
                service: .shell,
                log: Self.log
            )
            try agentBridge.attach(to: vsock)
            do {
                try shellBridge.attach(to: vsock)
            } catch {
                agentBridge.stop()
                throw error
            }
            self.agentBridge = agentBridge
            self.shellBridge = shellBridge
            if let socketPath = configuration.sshAgentSocketPath {
                do {
                    let bridge = try HostSSHAgentBridge(socketPath: socketPath, log: Self.log)
                    try bridge.attach(to: vsock)
                    sshAgentBridge = bridge
                } catch {
                    agentBridge.stop()
                    shellBridge.stop()
                    throw error
                }
            } else {
                sshAgentBridge = nil
            }
            clipboard = clipboardPolicy.map { policy in
                DoryDesktopClipboardCoordinator(
                    policy: policy,
                    execute: { argv, stdin, timeoutMs, outputLimitBytes in
                        let control = DorydKit.AgentControl(configuration: .init(
                            directSocketPath: configuration.agentSocketPath
                        ))
                        defer { control.disconnect() }
                        return try control.execWithInput(
                            argv: argv,
                            stdin: stdin,
                            timeoutMs: timeoutMs,
                            outputLimitBytes: outputLimitBytes
                        )
                    },
                    sendShortcut: { keyCode in
                        keyboardInput.send(frame: [
                            .init(type: 1, code: 125, value: 0),
                            .init(type: 1, code: 126, value: 0),
                            .init(type: 1, code: 29, value: 1),
                            .init(type: 1, code: keyCode, value: 1),
                            .init(type: 1, code: keyCode, value: 0),
                            .init(type: 1, code: 29, value: 0),
                        ])
                    },
                    log: Self.log
                )
            }
            if devices.removableUSBHotplug {
                guard let socketPath = configuration.usbControlSocketPath else {
                    throw VMError.invalidConfiguration(
                        "DoryPC removable USB hotplug requires an admitted control socket"
                    )
                }
                let handler = DoryPCUSBControlHandler(
                    controller: machine.xhciController,
                    machineID: envelope.machineID
                )
                usbControlHandler = handler
                usbControlServer = UsbControlServer(path: socketPath, handler: handler)
            } else {
                guard configuration.usbControlSocketPath == nil else {
                    throw VMError.invalidConfiguration(
                        "DoryPC USB control socket is not authorized by the device contract"
                    )
                }
                usbControlHandler = nil
                usbControlServer = nil
            }
            cameraBridge = try DoryPCMode.admitRequiredHostDevice(
                requested: devices.cameraInput
            ) {
                let bridge = try DoryPCCameraBridge { message in
                    FileHandle.standardError.write(
                        Data("dory-hv DoryPC camera: \(message)\n".utf8)
                    )
                }
                try bridge.attach(to: machine.xhciController)
                return bridge
            }
            serialInput = try RawHVSerialConsoleInput(
                socketPath: configuration.consoleSocketPath,
                receive: { [machineState] bytes in
                    machineState.current().machine.serial.enqueueReceivedBytes(bytes)
                    return true
                }
            )
            let telemetrySampler = DoryPCDeviceTelemetrySampler(
                machineID: envelope.machineID,
                operationID: envelope.operationID
            ) { [machineState, displaySink] in
                let current = machineState.current()
                return .init(
                    execution: current.machine.executionStatistics,
                    graphics: current.displayDevice.gpuDevice.commandDiagnostics,
                    display: displaySink?.metrics
                )
            }
            lifecycleServer = VmmLifecycleReceiptServer(
                socketPath: configuration.controlSocketPath,
                deviceTelemetryProvider: { telemetrySampler.snapshot() },
                lifecycleHandler: { [networkRuntime] action in
                    if action == .prepareStop {
                        networkRuntime?.stop()
                    }
                },
                reconnectIdentity: configuration.reconnectIdentity,
                executionStateProvider: { [machineState] in machineState.executionPause.state },
                executionLifecycleHandler: { [machineState] action in
                    if action == .preparePause { try machineState.executionPause.pause() }
                    else { try machineState.executionPause.resume() }
                }
            )

            if let display = devices.displays.first, let mailbox {
                let scale = max(1, CGFloat(display.backingScaleFactor))
                let size = NSSize(
                    width: CGFloat(display.widthPixels) / scale,
                    height: CGFloat(display.heightPixels) / scale
                )
                let view = try DesktopMetalView(
                    frame: NSRect(origin: .zero, size: size),
                    keyboardInput: keyboardInput,
                    pointerInput: pointerInput,
                    guestBackingScaleFactor: scale,
                    scanoutID: 0
                )
                if devices.dynamicDisplay {
                    view.onDrawableSizeChange = { [machineState] width, height in
                        machineState.updateDisplaySize(width: width, height: height)
                    }
                }
                view.onMacShortcut = { [weak clipboard] event in
                    clipboard?.handleMacShortcut(event) ?? false
                }
                if let rendererWorkerLaunch {
                    view.onDeviceFailure = {
                        [
                            rendererFailureRelay,
                            weak machineState,
                            weak rendererWorkerLaunch,
                        ] reason in
                        rendererWorkerLaunch?.failSynchronizedPresentation(reason)
                        rendererWorkerLaunch?.teardown(reason: reason)
                        rendererFailureRelay.report("Metal display failed closed: \(reason)")
                        machineState?.current().machine.powerController.request(.powerOff)
                    }
                    view.onWorkerPresentationCompleted = {
                        [
                            rendererFailureRelay,
                            readyPublisher,
                            weak machineState,
                            weak rendererWorkerLaunch,
                        ] workerGeneration in
                        do {
                            rendererWorkerLaunch?.recordSynchronizedPresentation(
                                workerGeneration: workerGeneration
                            )
                            try rendererWorkerLaunch?
                                .claimSynchronizedPresentationForPublication()
                            try readyPublisher.markRendererPresentationReady()
                        } catch {
                            let reason = "renderer presentation failed closed: \(error)"
                            rendererWorkerLaunch?.failSynchronizedPresentation(reason)
                            rendererWorkerLaunch?.teardown(reason: reason)
                            rendererFailureRelay.report(reason)
                            machineState?.current().machine.powerController.request(.powerOff)
                        }
                    }
                }
                mailbox.view = view
                let window = NSWindow(
                    contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.title = "\(envelope.machineID) — Dory Desktop"
                let content = NSView(frame: NSRect(origin: .zero, size: size))
                content.autoresizesSubviews = true
                view.frame = content.bounds
                view.autoresizingMask = [.width, .height]
                content.addSubview(view)

                let startup = Self.makeStartupOverlay(frame: content.bounds)
                content.addSubview(startup)
                firstFrameRelay.install { [weak startup, weak window] in
                    DesktopAppRunLoop.perform {
                        startup?.removeFromSuperview()
                        window?.title = "\(envelope.machineID) — Dory Desktop"
                    }
                }
                window.title = "\(envelope.machineID) — Starting x86_64 Linux"
                window.contentView = content
                window.minSize = NSSize(width: 640, height: 400)
                window.collectionBehavior.insert(.fullScreenPrimary)
                window.tabbingMode = .disallowed
                window.center()
                self.window = window
            } else {
                window = nil
            }
            super.init()
            window?.delegate = self
            clipboard?.start()
        }

        func run() throws {
            defer { cleanup() }
            try usbControlServer?.start()
            try lifecycleServer.start()
            DoryDesktopApplicationIdentity.install(on: application)
            application.setActivationPolicy(window == nil ? .accessory : .regular)
            application.delegate = self
            try installSignals()
            window?.makeKeyAndOrderFront(nil)
            if window != nil { application.activate() }
            startExecution()
            startGuestServicePreparation()
            application.run()
            if let stopError { throw stopError }
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            requestGuestShutdown()
            return false
        }

        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            // On hosts where audit-token Unix signalling is unavailable, daemon termination
            // reaches an admitted desktop runner through NSRunningApplication.terminate(). AppKit
            // invokes this delegate instead of the DispatchSource SIGTERM path, then the daemon's
            // bounded stop eventually force-terminates the app. Retire the runner-owned child now
            // so that cancellation of the AppKit quit cannot strand gvproxy under launchd.
            networkRuntime?.stop()
            requestGuestShutdown()
            return .terminateCancel
        }

        private func startExecution() {
            executionQueue.async { [weak self] in self?.execute() }
        }

        private func startGuestServicePreparation() {
            let devices = configuration.envelope.devices
            guard devices.clipboard || devices.clockSynchronization || devices.directorySharing
            else { return }
            let installerIsFirst = configuration.envelope.launchPlan.bootOrder.first.flatMap {
                firstID in
                configuration.envelope.launchPlan.bootDevices.first {
                    $0.logicalID == firstID
                }?.kind
            } == .removableMedia
            guard !installerIsFirst else {
                Self.log("installer guest services are deferred until the installed guest boots")
                return
            }
            let agentSocketPath = configuration.agentSocketPath
            let readyPublisher = self.readyPublisher
            let clipboard = self.clipboard
            let machineState = self.machineState
            let directoryShares = configuration.shares
            guestServiceQueue.async {
                let clock = ContinuousClock()
                let startedAt = clock.now
                var reportedUnavailable = false
                while !machineState.isStopping {
                    do {
                        let control = DorydKit.AgentControl(configuration: .init(
                            directSocketPath: agentSocketPath
                        ))
                        defer { control.disconnect() }
                        let info = try control.info()
                        guard info.protocolVersion == DoryCore.protocolVersion(),
                              info.capabilitiesAreCanonical else {
                            throw VMError.bootFailure(
                                "DoryPC guest agent protocol identity is incompatible"
                            )
                        }
                        if devices.clockSynchronization {
                            guard info.supports("clock-sync", minimumVersion: 1),
                                  try control.clockSync() else {
                                throw VMError.bootFailure(
                                    "DoryPC guest declined clock synchronization"
                                )
                            }
                        }
                        if devices.clipboard {
                            guard info.supports("exec", minimumVersion: 1),
                                  info.supports("exec-stdin", minimumVersion: 1) else {
                                throw VMError.bootFailure(
                                    "DoryPC guest lacks clipboard RPC capabilities"
                                )
                            }
                            let probe = try control.exec(
                                argv: ["/usr/bin/test", "-x", "/usr/lib/dory/clipboard"],
                                timeoutMs: 5_000,
                                outputLimitBytes: 4_096
                            )
                            guard probe.exitCode == 0, !probe.timedOut else {
                                throw VMError.bootFailure(
                                    "DoryPC guest clipboard helper is unavailable"
                                )
                            }
                        }
                        if devices.directorySharing {
                            guard info.supports("virtiofs-mount", minimumVersion: 1) else {
                                throw VMError.bootFailure(
                                    "DoryPC guest lacks virtio-fs mount capability"
                                )
                            }
                            for share in directoryShares {
                                _ = try control.virtioFSMount(
                                    tag: share.tag,
                                    mountPath: share.guestPath,
                                    readOnly: share.readOnly
                                )
                            }
                        }
                        if let clipboard {
                            DesktopAppRunLoop.perform { clipboard.markGuestReady() }
                        }
                        try readyPublisher.markGuestServicesReady()
                        Self.log("requested guest services are ready")
                        return
                    } catch {
                        guard !machineState.isStopping else { return }
                        if !reportedUnavailable, clock.now - startedAt >= .seconds(90) {
                            reportedUnavailable = true
                            Self.log(
                                "optional guest services are unavailable; retrying while the VM runs: \(error)"
                            )
                        }
                        // Translated kernels and freshly installed tools can become ready well
                        // after the initial boot window. Back off without abandoning integration,
                        // and let shutdown interrupt the wait between RPC attempts.
                        let retryAt = clock.now.advanced(
                            by: reportedUnavailable ? .seconds(5) : .milliseconds(250)
                        )
                        while !machineState.isStopping, clock.now < retryAt {
                            Thread.sleep(forTimeInterval: 0.25)
                        }
                    }
                }
            }
        }

        private nonisolated func execute() {
            let progressLogIntervalNanoseconds: UInt64 = 30_000_000_000
            var nextProgressLogNanoseconds = DispatchTime.now().uptimeNanoseconds
                &+ progressLogIntervalNanoseconds
            var publishedExecutionReadiness = false
            do {
                while try machineState.executionPause.enter(participant: 0) {
                    defer { machineState.executionPause.leave(participant: 0) }
                    let composed = machineState.current()
                    let stop = try composed.machine.run(
                        maximumInstructions: 250_000,
                        exceptionPolicy: .deliver
                    )
                    if !publishedExecutionReadiness {
                        // Runner admission alone is not guest readiness. Publish only after the
                        // machine has completed an execution slice, proving that reset-state,
                        // firmware fetch, translation, and lifecycle supervision are live. Pixel
                        // readiness remains a separate host-presentation boundary.
                        try readyPublisher.markPresentationReady()
                        publishedExecutionReadiness = true
                    }
                    for byte in composed.machine.serial.drainTransmittedBytes() {
                        serialOutput.enqueue(byte)
                    }
                    let now = DispatchTime.now().uptimeNanoseconds
                    if now >= nextProgressLogNanoseconds {
                        let statistics = composed.machine.executionStatistics
                        Self.log(
                            "execution progress interpreter=\(statistics.interpreterInstructions) "
                                + "baseline=\(statistics.baselineJITInstructions) "
                                + "optimizing=\(statistics.optimizingJITInstructions)"
                        )
                        if let diagnostics = composed.machine.baselineJITDiagnostics {
                            Self.log(Self.jitProgress("baseline", diagnostics))
                        }
                        if let diagnostics = composed.machine.optimizingJITDiagnostics {
                            Self.log(Self.jitProgress("optimizing", diagnostics))
                        }
                        Self.log(Self.blockDeviceProgress(composed))
                        nextProgressLogNanoseconds = now &+ progressLogIntervalNanoseconds
                    }
                    switch stop {
                    case .instructionBudget:
                        continue
                    case .reset:
                        guard !machineState.isStopping else {
                            finish(nil)
                            return
                        }
                        audioBackend?.reset()
                        vsock.resetTransportNeutralDevice()
                        let vsockPCI = try DoryPCVirtioVsockPCIDevice(
                            address: DoryPCV1ABI.vsockPCIAddress,
                            initialBARAddress: DoryPCV1ABI.vsockBARAddress,
                            vsock: vsock
                        )
                        let filesystemFunctions = try filesystemRuntime?
                            .replaceAfterMachineReset() ?? []
                        let replacement = try configuration.authority.makeMachine(
                            displaySink: displaySink,
                            gpuAccelerationAuthority: gpuAccelerationAuthority,
                            soundBackend: audioBackend
                                ?? DoryVirtioInMemorySoundBackend(),
                            networkBackend: networkBackend,
                            additionalPCIFunctions: [vsockPCI] + filesystemFunctions
                        )
                        try usbControlHandler?.replaceController(replacement.xhciController)
                        try cameraBridge?.attach(to: replacement.xhciController)
                        if configuration.envelope.devices.networkAttachment == .disconnected {
                            _ = replacement.networkDevice.setLinkUp(false)
                        }
                        keyboardInput.replaceDevice(replacement.keyboardDevice)
                        pointerInput.replaceDevice(replacement.tabletDevice)
                        guard machineState.replace(replacement) else {
                            finish(nil)
                            return
                        }
                    case .poweredOff:
                        if let failure = filesystemFailureRelay.failure
                            ?? rendererFailureRelay.failure {
                            throw VMError.bootFailure(failure)
                        }
                        finish(nil)
                        return
                    case .halted(let count):
                        throw VMError.bootFailure(
                            "DoryPC halted without a pending wake source after \(count) instructions"
                        )
                    case .exception(let exception, let count):
                        throw VMError.bootFailure(
                            "DoryPC stopped on unhandled \(exception) after \(count) instructions"
                        )
                    case .tripleFault(let source, let count):
                        let sourceDetail: String
                        switch source {
                        case .exception(let evidence):
                            let state = evidence.state
                            let faultLinearRIP = evidence.executionMode == .long64
                                ? evidence.exception.instructionPointer
                                : state.cs.base &+ evidence.exception.instructionPointer
                            let faultRIP = String(faultLinearRIP, radix: 16)
                            let codeSegment = String(state.cs.selector, radix: 16)
                            let bytes = evidence.instructionBytes.map {
                                String(format: "%02x", $0)
                            }.joined(separator: " ")
                            sourceDetail = "exception=\(evidence.exception.kind) "
                                + "vector=\(evidence.exception.vector) "
                                + "processor=\(evidence.processor) "
                                + "mode=\(evidence.executionMode.rawValue) "
                                + "fault-rip=0x\(faultRIP) cs=0x\(codeSegment) "
                                + "bytes=[\(bytes)]"
                        case .interrupt(let vector, let interruptSource, let processor):
                            sourceDetail = "interrupt=\(vector) source=\(interruptSource) "
                                + "processor=\(processor)"
                        }
                        let state = composed.machine.state
                        let statistics = composed.machine.executionStatistics
                        let detail = state.map {
                            let rip = String($0.cs.base &+ $0.rip, radix: 16)
                            let cr0 = String($0.control.cr0, radix: 16)
                            let cr3 = String($0.control.cr3, radix: 16)
                            let cr4 = String($0.control.cr4, radix: 16)
                            let efer = String($0.control.efer, radix: 16)
                            return "rip=0x\(rip) cr0=0x\(cr0) cr3=0x\(cr3) "
                                + "cr4=0x\(cr4) efer=0x\(efer)"
                        } ?? "architectural-state=unavailable"
                        throw VMError.bootFailure(
                            "DoryPC triple-faulted from \(sourceDetail) "
                                + "after \(count) instructions; "
                                + "\(detail); interpreter=\(statistics.interpreterInstructions) "
                                + "baseline=\(statistics.baselineJITInstructions) "
                                + "optimizing=\(statistics.optimizingJITInstructions)"
                        )
                    }
                }
                finish(nil)
            } catch {
                finish(error)
            }
        }

        private nonisolated func finish(_ error: Error?) {
            DesktopAppRunLoop.perform { [weak self] in
                guard let self else { return }
                if self.stopError == nil { self.stopError = error }
                self.application.stop(nil)
                if let event = NSEvent.otherEvent(
                    with: .applicationDefined,
                    location: .zero,
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: 0,
                    context: nil,
                    subtype: 0,
                    data1: 0,
                    data2: 0
                ) {
                    self.application.postEvent(event, atStart: false)
                }
            }
        }

        private func installSignals() throws {
            guard DoryPCClockSource.installProcessResumeTracking() else {
                throw VMError.invalidConfiguration(
                    "could not install DoryPC resume clock tracking: errno \(errno)"
                )
            }
            let graceful = configuration.envelope.devices.gracefulShutdown
            let agentSocketPath = configuration.agentSocketPath
            let keyboardInput = self.keyboardInput
            let machineState = self.machineState
            let networkRuntime = self.networkRuntime
            for number in [SIGTERM, SIGINT] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
                source.setEventHandler {
                    // The daemon's bounded stop may ultimately SIGKILL this runner if an
                    // installer has no guest agent and ignores the ACPI power key. Retire the
                    // runner-owned sidecar at the first host termination signal so that forced
                    // runner exit cannot orphan gvproxy under launchd or leak its stale sockets
                    // into the next start. Guest shutdown control uses the independent vsock
                    // bridge, so network teardown does not prevent the graceful request.
                    networkRuntime?.stop()
                    machineState.requestGuestShutdown(
                        graceful: graceful,
                        agentSocketPath: agentSocketPath,
                        keyboardInput: keyboardInput,
                        log: Self.log
                    )
                }
                source.resume()
                signalSources.append(source)
            }
        }

        private func cleanup() {
            machineState.requestStop()
            signalSources.forEach { $0.cancel() }
            signalSources.removeAll()
            lifecycleServer.stop()
            clipboard?.stop()
            agentBridge.stop()
            shellBridge.stop()
            sshAgentBridge?.stop()
            filesystemRuntime?.stop()
            _ = vsock.quiesce()
            _ = usbControlServer?.stop()
            usbControlHandler?.stop()
            networkRuntime?.stop()
            cameraBridge?.stop()
            audioBackend?.reset()
            serialInput.stop()
            _ = serialOutput.stop()
            try? serialLog.close()
            mailbox?.disable()
        }

        private static func openSerialLog(_ path: String) throws -> FileHandle {
            let descriptor = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else {
                throw VMError.invalidConfiguration(
                    "could not open DoryPC serial log: errno \(errno)"
                )
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_uid == geteuid(),
                  status.st_mode & 0o077 == 0 else {
                let code = errno
                Darwin.close(descriptor)
                throw VMError.invalidConfiguration(
                    "DoryPC serial log is not an owner-private regular file: errno \(code)"
                )
            }
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }

        private static func makeStartupOverlay(frame: NSRect) -> NSView {
            let overlay = NSVisualEffectView(frame: frame)
            overlay.autoresizingMask = [.width, .height]
            overlay.blendingMode = .withinWindow
            overlay.material = .underWindowBackground
            overlay.state = .active

            let progress = NSProgressIndicator()
            progress.style = .spinning
            progress.controlSize = .regular
            progress.startAnimation(nil)

            let title = NSTextField(labelWithString: "Starting x86_64 Linux")
            title.font = .systemFont(ofSize: 17, weight: .semibold)
            title.textColor = .labelColor
            title.alignment = .center

            let detail = NSTextField(
                wrappingLabelWithString:
                    "Translating UEFI firmware. The installer will appear automatically."
            )
            detail.font = .systemFont(ofSize: 13)
            detail.textColor = .secondaryLabelColor
            detail.alignment = .center
            detail.maximumNumberOfLines = 2
            detail.preferredMaxLayoutWidth = 420

            let stack = NSStackView(views: [progress, title, detail])
            stack.orientation = .vertical
            stack.alignment = .centerX
            stack.spacing = 10
            stack.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
                stack.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 32),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -32),
            ])
            return overlay
        }

        private nonisolated static func log(_ message: String) {
            FileHandle.standardError.write(Data("dory-hv DoryPC: \(message)\n".utf8))
        }

        private nonisolated static func blockDeviceProgress(
            _ composed: DoryPCUEFIMachine
        ) -> String {
            let devices = zip(composed.plan.bootDevices, composed.blockDevices).map {
                planned, attached in
                let state = attached.transport.deviceState.snapshot()
                let queue = try? attached.transport.queueSnapshot(at: 0)
                let registers = attached.transport.registerDiagnostics
                let requests = attached.blockDevice.diagnostics
                let ranges = requests.recentReadRanges.suffix(4).map {
                    "\($0.offset)+\($0.byteCount)"
                }.joined(separator: ",")
                return "\(planned.logicalID){kind=\(planned.kind),status=\(state.status.rawValue),"
                    + "queue-enabled=\(queue?.enabled == true),register-reads=\(registers.readCount),"
                    + "register-writes=\(registers.writeCount),requests=\(requests.requestCount),"
                    + "reads=\(requests.readRequestCount),read-bytes=\(requests.readByteCount),"
                    + "writes=\(requests.writeRequestCount),write-bytes=\(requests.writeByteCount),"
                    + "flushes=\(requests.flushRequestCount),failures=\(requests.failedRequestCount),"
                    + "unsupported=\(requests.unsupportedRequestCount),recent-reads=[\(ranges)]}"
            }
            return "block progress " + devices.joined(separator: " ")
        }

        private nonisolated static func jitProgress(
            _ tier: String,
            _ diagnostics: DoryPCJITCacheStatistics
        ) -> String {
            "jit progress tier=\(tier) "
                + "recent-hits=\(diagnostics.recentLookupHits) "
                + "dictionary-hits=\(diagnostics.dictionaryLookupHits) "
                + "misses=\(diagnostics.lookupMisses) "
                + "generation-hits=\(diagnostics.memoryGenerationHits) "
                + "byte-hits=\(diagnostics.byteValidationHits) "
                + "shared-hits=\(diagnostics.sharedCodeHits) "
                + "compiled=\(diagnostics.compiledBlocks) "
                + "declined=\(diagnostics.declinedCompilations) "
                + "negative-hits=\(diagnostics.negativeCacheHits) "
                + "negative-misses=\(diagnostics.negativeCacheMisses) "
                + "negative-generation-mismatches="
                + "\(diagnostics.negativeGenerationMismatches) "
                + "negative-entries=\(diagnostics.negativeEntryCount) "
                + "wraps=\(diagnostics.codeCacheWraps) "
                + "trace-attempts=\(diagnostics.nativeTraceAttempts) "
                + "trace-replays=\(diagnostics.nativeTraceReplays) "
                + "generation-checks=\(diagnostics.codeGenerationChecks) "
                + "generation-mismatches=\(diagnostics.codeGenerationMismatches) "
                + "chain-calls=\(diagnostics.chainedExecutionCalls) "
                + "chain-requested=\(diagnostics.chainedRequestedInstructions) "
                + "chain-retired=\(diagnostics.chainedRetiredInstructions)"
        }

        private func requestGuestShutdown() {
            window?.orderOut(nil)
            machineState.requestGuestShutdown(
                graceful: configuration.envelope.devices.gracefulShutdown,
                agentSocketPath: configuration.agentSocketPath,
                keyboardInput: keyboardInput,
                log: Self.log
            )
        }
    }
}
