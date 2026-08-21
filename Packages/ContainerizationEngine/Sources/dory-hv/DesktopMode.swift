import AppKit
import Darwin
import DoryCore
import DoryHV
import DoryOperations
import DorydKit
import DoryVMMKit
import Foundation

enum DesktopMode {
    struct Configuration {
        var machineID: String
        var operationID: UUID
        var stateDirectory: String
        var kernelPath: String
        var initrdPath: String?
        var rootfsPath: String
        var rootDevice: String
        var genericGuest: Bool
        var gvproxyPath: String
        var handoffSocketPath: String
        var agentSocketPath: String
        var shellSocketPath: String
        var controlSocketPath: String
        var sshAgentSocketPath: String?
        var memoryMB: UInt64
        var cpuCount: Int
        var shares: [DoryMachineShareConfiguration]
        var environment: [String: String]
        var resolvedGraphics: DoryGraphicsAccelerationLevel?
        var resolvedDevices: DoryVirtualMachineDeviceCapabilityRequest?
    }

    enum NetworkPlan: Equatable {
        case sharedNAT
        case hostOnly
        case disconnected

        init(resolvedDevices: DoryVirtualMachineDeviceCapabilityRequest?) throws {
            switch resolvedDevices?.networkAttachment ?? .sharedNAT {
            case .sharedNAT:
                self = .sharedNAT
            case .disconnected:
                self = .disconnected
            case .isolated:
                self = .hostOnly
            case .bridged:
                throw VMError.bootFailure(
                    "resolved device contract contains a network mode not implemented by raw-HV"
                )
            }
        }

        var startsGVProxy: Bool { self != .disconnected }
        var attachesNetworkDevice: Bool { true }
        var gvproxyConfigurationYAML: String? {
            self == .hostOnly ? GVProxyDesktopLaunchPlan.hostOnlyConfigurationYAML : nil
        }
    }

    struct DisplayPlan: Equatable {
        var widthPixels: UInt32
        var heightPixels: UInt32
        var backingScaleFactor: UInt8
        var guestUIScaleFactor: UInt8

        init(resolvedDevices: DoryVirtualMachineDeviceCapabilityRequest?) throws {
            let display = resolvedDevices?.display ?? DoryVMMDisplayDefaults.capability
            guard display.isValid else {
                throw VMError.bootFailure(
                    "resolved display geometry is outside the supported pixel bounds"
                )
            }
            widthPixels = display.widthPixels
            heightPixels = display.heightPixels
            backingScaleFactor = display.backingScaleFactor
            guestUIScaleFactor = display.guestUIScaleFactor
        }

        var windowSize: NSSize {
            NSSize(
                width: max(1, CGFloat(widthPixels) / CGFloat(backingScaleFactor)),
                height: max(1, CGFloat(heightPixels) / CGFloat(backingScaleFactor))
            )
        }
    }

    private struct ResolvedGraphics {
        var backend: DoryDesktopGraphicsBackend
        var renderer: VirglRenderer?
    }

    @MainActor
    static func run(_ configuration: Configuration) throws {
        let controller = try Controller(configuration: configuration)
        try controller.run()
    }

    @MainActor
    private final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate {
        private let configuration: Configuration
        private let application = NSApplication.shared
        private let stateLock: EngineStateDirectoryLock
        private let serialLog: FileHandle
        private let machine: Machine
        private let graphicsBackend: DoryDesktopGraphicsBackend
        private let input: VirtioInput
        private let mailbox: DesktopFrameMailbox
        private let display: DesktopMetalView
        private let window: NSWindow
        private let vsock: VirtioVsock
        private let audio: DoryMacAudioBackend
        private let gvproxy: Process?
        private let networkSocketPaths: [String]
        private let agentBridge: GuestVsockSocketBridge
        private let shellBridge: GuestVsockSocketBridge
        private let sshAgentBridge: HostSSHAgentBridge?
        private let clipboard: DoryDesktopClipboardCoordinator?
        private let firstFrame: FirstFrameGate
        private let lifecycleReceiptServer: VmmLifecycleReceiptServer
        private var signalSources = [DispatchSourceSignal]()
        private var stopError: Error?
        private var stopping = false

        init(configuration: Configuration) throws {
            self.configuration = configuration
            self.lifecycleReceiptServer = VmmLifecycleReceiptServer(
                socketPath: configuration.controlSocketPath
            )
            try FileManager.default.createDirectory(
                atPath: configuration.stateDirectory,
                withIntermediateDirectories: true
            )
            self.stateLock = try EngineStateDirectoryLock(stateDirectory: configuration.stateDirectory)
            self.serialLog = try Self.openAppendLog("\(configuration.stateDirectory)/serial.log")
            try Self.appendBootSessionMarker(
                to: serialLog,
                machineID: configuration.machineID,
                operationID: configuration.operationID
            )
            let resolvedGraphics = try Self.resolveGraphics(
                environment: configuration.environment,
                requireVulkan: configuration.genericGuest,
                exactLevel: configuration.resolvedGraphics
            )
            self.graphicsBackend = resolvedGraphics.backend
            let networkPlan = try NetworkPlan(resolvedDevices: configuration.resolvedDevices)
            let networkInterface = configuration.resolvedDevices?.networkInterface
            if let networkInterface, !networkInterface.isValid {
                throw VMError.bootFailure(
                    "resolved network interface identity or MTU is invalid"
                )
            }
            let displayPlan = try DisplayPlan(resolvedDevices: configuration.resolvedDevices)
            if let devices = configuration.resolvedDevices {
                guard devices.keyboard == devices.pointer else {
                    throw VMError.bootFailure(
                        "raw-HV input is a combined keyboard/pointer device"
                    )
                }
                guard devices.audioInput == devices.audioOutput else {
                    throw VMError.bootFailure(
                        "raw-HV audio is a combined input/output device"
                    )
                }
                guard devices.directorySharing == !configuration.shares.isEmpty else {
                    throw VMError.bootFailure(
                        "resolved directory-sharing contract does not match the launch shares"
                    )
                }
            }
            self.machine = try Machine(configuration: MachineConfiguration(
                kernelPath: configuration.kernelPath,
                initrdPath: configuration.initrdPath,
                commandLine: Self.kernelCommandLine(
                    machineID: configuration.machineID,
                    operationID: configuration.operationID,
                    rootDevice: configuration.rootDevice,
                    graphicsBackend: resolvedGraphics.backend,
                    genericGuest: configuration.genericGuest
                ),
                memoryBytes: configuration.memoryMB << 20,
                cpuCount: configuration.cpuCount
            ))
            Self.attachPlatformDevices(to: machine, serialLog: serialLog)

            self.input = VirtioInput()
            self.mailbox = DesktopFrameMailbox()
            let cursorMailbox = DesktopCursorMailbox()
            let firstFrame = FirstFrameGate()
            self.firstFrame = firstFrame
            self.display = try DesktopMetalView(
                frame: NSRect(origin: .zero, size: displayPlan.windowSize),
                input: input,
                guestBackingScaleFactor: CGFloat(displayPlan.backingScaleFactor)
            )
            mailbox.view = display
            cursorMailbox.view = display

            let renderer = resolvedGraphics.renderer
            let hostVisibleMemory = try renderer.map { _ in
                try VirtioGPUHostVisibleMemory(guestBase: GuestLayout.daxWindowBase)
            }
            let gpu = VirtioGPU(
                hostMemoryBase: GuestLayout.daxWindowBase,
                scanoutCount: 1,
                scanoutWidth: displayPlan.widthPixels,
                scanoutHeight: displayPlan.heightPixels,
                renderer: renderer,
                hostVisibleMemory: hostVisibleMemory,
                traceResourceLifecycle: configuration.environment["DORY_GPU_TRACE_RESOURCES"] == "1",
                onScanoutFrame: { [mailbox, firstFrame] frame in
                    mailbox.submit(frame)
                    firstFrame.signal()
                },
                onScanoutResourceReleased: { [mailbox] resourceID in
                    mailbox.release(resourceID: resourceID)
                },
                onCursorUpdate: { [cursorMailbox] update in
                    cursorMailbox.submit(update)
                }
            )
            self.vsock = VirtioVsock(guestCID: 3)
            self.audio = DoryMacAudioBackend(log: Self.log)
            let sound = VirtioSound(host: audio, log: Self.log)
            let balloon = VirtioBalloon(memory: machine.memory) { message in
                Self.log(message)
            }

            let runtimeDirectory = (configuration.agentSocketPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: runtimeDirectory, withIntermediateDirectories: true)
            let token = String(configuration.machineID.prefix(12))
            let networkRuntime = try Self.prepareNetwork(
                plan: networkPlan,
                networkInterface: networkInterface,
                gvproxyPath: configuration.gvproxyPath,
                runtimeDirectory: runtimeDirectory,
                token: token
            )
            self.gvproxy = networkRuntime.process
            self.networkSocketPaths = networkRuntime.socketPaths
            do {
                var backends: [VirtioDeviceBackend] = [
                    try VirtioBlk(path: configuration.rootfsPath, identity: "dory-rootfs"),
                    gpu,
                    VirtioRng(),
                    balloon,
                    vsock,
                ]
                if configuration.resolvedDevices?.keyboard != false {
                    backends.append(input)
                }
                if configuration.resolvedDevices?.audioInput != false {
                    backends.append(sound)
                }
                let attachedShares = configuration.resolvedDevices?.directorySharing == false
                    ? [] : configuration.shares
                for share in attachedShares {
                    let rawShare = try VirtioFSShareConfiguration(
                        tag: share.tag,
                        path: share.hostPath,
                        readOnly: share.readOnly,
                        guestMountPoint: share.guestPath
                    )
                    backends.append(try rawShare.makeBackend(
                        requestQueueCount: min(8, max(1, configuration.cpuCount))
                    ))
                }
                if let network = networkRuntime.backend {
                    backends.append(network)
                }
                for (slot, backend) in backends.enumerated() {
                    let transport = Self.attachBackend(backend, to: machine, slot: slot)
                    if backend === gpu, configuration.resolvedDevices?.dynamicDisplay != false {
                        display.onDrawableSizeChange = { [weak gpu, weak transport] width, height in
                            guard let gpu, let transport else { return }
                            gpu.updateScanoutSize(width: width, height: height, transport: transport)
                        }
                    }
                }
                try machine.loadBootPayload()
            } catch {
                if let gvproxy = networkRuntime.process {
                    ChildProcessTerminator.terminateAndReap(gvproxy)
                }
                for path in networkSocketPaths { unlink(path) }
                throw error
            }

            self.agentBridge = GuestVsockSocketBridge(
                socketPath: configuration.agentSocketPath,
                guestPort: VsockPorts.agent,
                log: Self.log
            )
            self.shellBridge = GuestVsockSocketBridge(
                socketPath: configuration.shellSocketPath,
                guestPort: 1027,
                log: Self.log
            )
            try agentBridge.attach(to: vsock)
            try shellBridge.attach(to: vsock)
            if let sshAgentSocketPath = configuration.sshAgentSocketPath {
                let bridge = try HostSSHAgentBridge(
                    socketPath: sshAgentSocketPath,
                    log: Self.log
                )
                bridge.attach(to: vsock)
                self.sshAgentBridge = bridge
            } else {
                self.sshAgentBridge = nil
            }
            if configuration.resolvedDevices?.clipboard == false
                || (configuration.resolvedDevices == nil && configuration.genericGuest) {
                self.clipboard = nil
            } else {
                let clipboardControl = DorydKit.AgentControl(configuration: .init(
                    directSocketPath: configuration.agentSocketPath
                ))
                let clipboardInput = self.input
                self.clipboard = DoryDesktopClipboardCoordinator(
                    policy: DoryDesktopClipboardPolicy(environment: configuration.environment),
                    execute: { argv, stdin, timeoutMs, outputLimitBytes in
                        try clipboardControl.execWithInput(
                            argv: argv,
                            stdin: stdin,
                            timeoutMs: timeoutMs,
                            outputLimitBytes: outputLimitBytes
                        )
                    },
                    sendShortcut: { keyCode in
                        clipboardInput.send(frame: [
                            VirtioInputEvent(type: 1, code: 125, value: 0),
                            VirtioInputEvent(type: 1, code: 126, value: 0),
                            VirtioInputEvent(type: 1, code: 29, value: 1),
                            VirtioInputEvent(type: 1, code: keyCode, value: 1),
                            VirtioInputEvent(type: 1, code: keyCode, value: 0),
                            VirtioInputEvent(type: 1, code: 29, value: 0),
                        ])
                    },
                    log: Self.log
                )
            }

            self.window = NSWindow(
                contentRect: NSRect(origin: .zero, size: displayPlan.windowSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "\(configuration.machineID) — Dory Linux"
            window.contentView = display
            window.minSize = NSSize(width: 640, height: 400)
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.tabbingMode = .disallowed
            window.center()
            super.init()
            window.delegate = self
            display.onMacShortcut = { [weak clipboard] event in
                clipboard?.handleMacShortcut(event) ?? false
            }
            clipboard?.start()
        }

        func run() throws {
            try lifecycleReceiptServer.start()
            application.setActivationPolicy(.regular)
            application.delegate = self
            installApplicationMenu()
            installSignalHandlers()
            window.makeKeyAndOrderFront(nil)
            application.activate()
            startMachine()
            application.run()
            cleanup()
            if let stopError { throw stopError }
        }

        private func installApplicationMenu() {
            let mainMenu = NSMenu()

            let applicationItem = NSMenuItem(title: "Dory Linux", action: nil, keyEquivalent: "")
            let applicationMenu = NSMenu(title: "Dory Linux")
            applicationMenu.addItem(
                withTitle: "Quit Dory Linux",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
            applicationItem.submenu = applicationMenu
            mainMenu.addItem(applicationItem)

            let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
            let viewMenu = NSMenu(title: "View")
            let fullScreenItem = NSMenuItem(
                title: "Enter Full Screen",
                action: #selector(NSWindow.toggleFullScreen(_:)),
                keyEquivalent: "f"
            )
            fullScreenItem.keyEquivalentModifierMask = [.command, .control]
            fullScreenItem.target = window
            viewMenu.addItem(fullScreenItem)
            viewItem.submenu = viewMenu
            mainMenu.addItem(viewItem)

            application.mainMenu = mainMenu
        }

        func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
            window.makeKeyAndOrderFront(nil)
            return true
        }

        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            requestGuestShutdown()
            return .terminateCancel
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            sender.orderOut(nil)
            return false
        }

        func windowDidResignKey(_ notification: Notification) {
            display.releasePressedInput()
        }

        func applicationDidResignActive(_ notification: Notification) {
            display.releasePressedInput()
        }

        private func startMachine() {
            let machine = self.machine
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                do {
                    let reason = try machine.run()
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self?.finish(error: Self.error(for: reason))
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.finish(error: error) }
                    }
                }
            }

            let configuration = self.configuration
            let graphicsDisplayName = graphicsBackend.displayName
            let firstFrame = self.firstFrame
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    if configuration.genericGuest {
                        guard firstFrame.wait(timeout: 90) else {
                            throw VMError.bootFailure(
                                "generic Linux guest did not publish a graphics frame within 90s"
                            )
                        }
                        try VmmHandoffClient.send(
                            path: configuration.handoffSocketPath,
                            ready: VmmReadyMessage(
                                machineID: configuration.machineID,
                                operationID: DoryOperationIdentity.canonical(
                                    configuration.operationID
                                ),
                                agentBuild: "dory-hv/generic-linux",
                                controlSocketPath: configuration.controlSocketPath,
                                detail: "raw-HV generic Linux running with \(graphicsDisplayName) graphics; guest tools are not installed"
                            )
                        )
                        return
                    }
                    let info = try Self.prepareGuest(configuration: configuration)
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated { self?.clipboard?.markGuestReady() }
                    }
                    try VmmHandoffClient.send(
                        path: configuration.handoffSocketPath,
                        ready: VmmReadyMessage(
                            machineID: configuration.machineID,
                            operationID: DoryOperationIdentity.canonical(
                                configuration.operationID
                            ),
                            agentBuild: info.agentBuild,
                            agentProtocolVersion: info.protocolVersion,
                            agentCapabilities: info.capabilities,
                            agentSocketPath: configuration.agentSocketPath,
                            shellSocketPath: configuration.shellSocketPath,
                            controlSocketPath: configuration.controlSocketPath,
                            detail: "raw-HV desktop running with \(graphicsDisplayName) graphics; dory-agent answered protocol \(info.protocolVersion)"
                        )
                    )
                } catch {
                    machine.requestStop(.crash("desktop readiness failed: \(error)"))
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.finish(error: error) }
                    }
                }
            }
        }

        private func requestGuestShutdown() {
            guard !stopping else { return }
            stopping = true
            window.orderOut(nil)
            let machine = self.machine
            if configuration.genericGuest {
                // Linux maps KEY_POWER to logind's normal power-button action. This provides a
                // clean integration-free shutdown path until Dory guest tools are installed.
                input.send(frame: [
                    VirtioInputEvent(type: 1, code: 116, value: 1),
                    VirtioInputEvent(type: 1, code: 116, value: 0),
                ])
            } else {
                do {
                    let control = AgentControl(configuration: .init(
                        directSocketPath: configuration.agentSocketPath
                    ))
                    defer { control.disconnect() }
                    try Self.requireSuccess(control.exec(
                        argv: ["/bin/sh", "-c", GuestShutdownCommand.detachedDesktopRequest()],
                        timeoutMs: 5_000,
                        outputLimitBytes: 64 * 1024
                    ), operation: "desktop guest shutdown request")
                } catch {
                    Self.log("dory-hv desktop: graceful guest shutdown request failed: \(error)")
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + DoryEngineShutdownTiming.helperWatchdogSeconds
            ) {
                machine.requestStop(.crash("guest shutdown timed out"))
            }
        }

        private func finish(error: Error?) {
            if stopError == nil { stopError = error }
            application.stop(nil)
            if let wakeEvent = NSEvent.otherEvent(
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
                application.postEvent(wakeEvent, atStart: false)
            }
        }

        private func cleanup() {
            lifecycleReceiptServer.stop()
            clipboard?.stop()
            signalSources.forEach { $0.cancel() }
            signalSources.removeAll()
            if let gvproxy {
                ChildProcessTerminator.terminateAndReap(gvproxy)
            }
            unlink(configuration.agentSocketPath)
            unlink(configuration.shellSocketPath)
            for path in networkSocketPaths { unlink(path) }
            try? serialLog.close()
        }

        private func installSignalHandlers() {
            for number in [SIGTERM, SIGINT] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { [weak self] in
                    MainActor.assumeIsolated { self?.requestGuestShutdown() }
                }
                source.resume()
                signalSources.append(source)
            }

            // dory-hv is a command-line helper rather than an app bundle, so LaunchServices cannot
            // reliably activate it from Dory.app. Give the UI a narrow same-user signal that asks
            // the helper itself to raise its hidden or covered display window.
            signal(SIGUSR1, SIG_IGN)
            let raiseSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
            raiseSource.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.window.makeKeyAndOrderFront(nil)
                    self.application.activate()
                }
            }
            raiseSource.resume()
            signalSources.append(raiseSource)
        }

        private nonisolated static func prepareGuest(configuration: Configuration) throws -> DoryAgentInfo {
            let deadline = Date().addingTimeInterval(90)
            var lastError: Error?
            while Date() < deadline {
                do {
                    let control = AgentControl(configuration: .init(
                        directSocketPath: configuration.agentSocketPath
                    ))
                    let info = try control.info()
                    let operationToken = DoryOperationIdentity.canonical(
                        configuration.operationID
                    )
                    try requireSuccess(control.exec(
                        argv: [
                            "/bin/sh", "-c",
                            "mkdir -p /run/dory && chmod 700 /run/dory && umask 077 && printf '%s\\n' \"$DORY_OPERATION_ID\" > /run/dory/operation-id",
                        ],
                        env: [DoryExecEnvironment(
                            key: "DORY_OPERATION_ID",
                            value: operationToken
                        )],
                        timeoutMs: 10_000,
                        outputLimitBytes: 16 * 1_024
                    ), operation: "bind lifecycle operation")
                    if let display = configuration.resolvedDevices?.display {
                        guard let command = DoryVMMGuestDisplayScale.persistenceCommand(
                            scaleFactor: display.guestUIScaleFactor
                        ) else {
                            throw VMError.bootFailure(
                                "resolved guest UI scale is not supported by Dory Tools"
                            )
                        }
                        try requireSuccess(control.exec(
                            argv: command,
                            timeoutMs: 10_000,
                            outputLimitBytes: 64 * 1_024
                        ), operation: "persist guest UI scale")
                    }
                    var guestEnvironment = configuration.environment
                    guestEnvironment["DORY_OPERATION_ID"] = operationToken
                    try requireSuccess(control.exec(
                        argv: ["/usr/lib/dory/configure-machine"],
                        env: guestEnvironment.sorted(by: { $0.key < $1.key }).map {
                            DoryExecEnvironment(key: $0.key, value: $0.value)
                        },
                        timeoutMs: 30_000,
                        outputLimitBytes: 64 * 1024
                    ), operation: "guest account configuration")
                    for share in configuration.shares {
                        try requireSuccess(control.exec(
                            argv: ["/bin/mkdir", "-p", share.guestPath],
                            timeoutMs: 10_000,
                            outputLimitBytes: 64 * 1024
                        ), operation: "create share mount point \(share.guestPath)")
                        try requireSuccess(control.exec(
                            argv: [
                                "/bin/mount", "-t", "virtiofs", "-o",
                                share.readOnly ? "ro" : "rw",
                                share.tag, share.guestPath,
                            ],
                            timeoutMs: 30_000,
                            outputLimitBytes: 64 * 1024
                        ), operation: "mount share \(share.tag)")
                    }
                    try requireSuccess(control.exec(
                        argv: ["/usr/bin/touch", "/var/lib/dory/host-configured"],
                        timeoutMs: 10_000,
                        outputLimitBytes: 64 * 1024
                    ), operation: "complete desktop configuration")
                    return info
                } catch {
                    lastError = error
                    Thread.sleep(forTimeInterval: 0.25)
                }
            }
            throw lastError ?? VMError.bootFailure("desktop agent did not become ready")
        }

        private nonisolated static func requireSuccess(_ result: DoryExecResult, operation: String) throws {
            guard !result.timedOut, result.exitCode == 0 else {
                let stderr = String(decoding: result.stderr.prefix(4_096), as: UTF8.self)
                throw VMError.bootFailure(
                    "\(operation) failed (exit=\(result.exitCode), timedOut=\(result.timedOut)): \(stderr)"
                )
            }
        }

        private static func waitForSocket(path: String, process: Process) throws {
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: path) { return }
                guard process.isRunning else {
                    throw VMError.bootFailure("gvproxy exited before publishing its network socket")
                }
                usleep(50_000)
            }
            throw VMError.bootFailure("gvproxy did not publish its network socket")
        }

        private struct NetworkRuntime {
            let process: Process?
            let socketPaths: [String]
            let backend: (any VirtioDeviceBackend)?
        }

        private static func prepareNetwork(
            plan: NetworkPlan,
            networkInterface: DoryVirtualMachineNetworkInterfaceCapabilityRequest?,
            gvproxyPath: String,
            runtimeDirectory: String,
            token: String
        ) throws -> NetworkRuntime {
            if plan == .disconnected {
                let mac = networkInterface?.macAddressOctets ?? VirtioNet.guestMAC
                return NetworkRuntime(
                    process: nil,
                    socketPaths: [],
                    backend: VirtioDisconnectedNet(
                        macAddress: mac,
                        maximumTransmissionUnit: networkInterface?.maximumTransmissionUnit
                    )
                )
            }
            guard plan.startsGVProxy, plan.attachesNetworkDevice else {
                return NetworkRuntime(process: nil, socketPaths: [], backend: nil)
            }
            let gvproxySocket = "\(runtimeDirectory)/\(token)-gv.sock"
            let vmNetworkSocket = "\(runtimeDirectory)/\(token)-vm.sock"
            let apiSocket = "\(runtimeDirectory)/\(token)-api.sock"
            let configurationYAML: String?
            if let networkInterface {
                configurationYAML = GVProxyDesktopLaunchPlan.configurationYAML(
                    hostOnly: plan == .hostOnly,
                    guestMAC: networkInterface.macAddress
                )
            } else {
                configurationYAML = plan.gvproxyConfigurationYAML
            }
            let configurationPath = configurationYAML.map { _ in
                "\(runtimeDirectory)/\(token)-network.yaml"
            }
            let socketPaths = [gvproxySocket, vmNetworkSocket, apiSocket]
                + [configurationPath].compactMap { $0 }
            for path in socketPaths { unlink(path) }
            if let configurationPath, let yaml = configurationYAML {
                try yaml.write(toFile: configurationPath, atomically: true, encoding: .utf8)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: gvproxyPath)
            process.arguments = GVProxyDesktopLaunchPlan.arguments(
                mtu: networkInterface.map { Int($0.maximumTransmissionUnit) }
                    ?? DoryNetworkMTU.resolved(),
                datapathSocket: gvproxySocket,
                apiSocket: apiSocket,
                configurationPath: configurationPath
            )
            process.standardOutput = FileHandle.standardError
            process.standardError = FileHandle.standardError
            do {
                try process.run()
                try waitForSocket(path: gvproxySocket, process: process)
                return NetworkRuntime(
                    process: process,
                    socketPaths: socketPaths,
                    backend: try VirtioNet(
                        socketPath: vmNetworkSocket,
                        remotePath: gvproxySocket,
                        macAddress: networkInterface?.macAddressOctets ?? VirtioNet.guestMAC,
                        maximumTransmissionUnit: networkInterface?.maximumTransmissionUnit
                    )
                )
            } catch {
                ChildProcessTerminator.terminateAndReap(process)
                for path in socketPaths { unlink(path) }
                throw error
            }
        }

        @discardableResult
        private static func attachBackend(
            _ backend: VirtioDeviceBackend,
            to machine: Machine,
            slot: Int
        ) -> VirtioMMIOTransport {
            let interrupt = GuestLayout.virtioFirstIRQ + UInt32(slot)
            let transport = VirtioMMIOTransport(
                baseAddress: GuestLayout.virtioBase + UInt64(slot) * GuestLayout.virtioSlotSize,
                backend: backend,
                memory: machine.memory
            ) { [weak machine] in
                machine?.raiseGSI(interrupt)
            }
            machine.attachVirtioSlot(transport)
            return transport
        }

        private static func attachPlatformDevices(to machine: Machine, serialLog: FileHandle) {
            #if arch(arm64)
            machine.bus.attach(PL031(baseAddress: GuestLayout.rtcBase))
            machine.attachConsole(PL011(baseAddress: GuestLayout.uartBase) { byte in
                FileHandle.standardError.write(Data([byte]))
                try? serialLog.write(contentsOf: Data([byte]))
            })
            #endif
        }

        private static func resolveGraphics(
            environment: [String: String],
            requireVulkan: Bool,
            exactLevel: DoryGraphicsAccelerationLevel?
        ) throws -> ResolvedGraphics {
            let preference = try DoryDesktopGraphicsPreference(environment: environment)
            var rendererEnvironment = ProcessInfo.processInfo.environment
            for key in [
                DoryDesktopGraphicsPreference.legacyClassicOnlyEnvironmentKey,
                "DORY_VIRGL_SYNC_MODE",
                "DORY_VIRGLRENDERER_PATH",
                "DORY_MOLTENVK_ICD",
            ] {
                if let value = environment[key] {
                    rendererEnvironment[key] = value
                }
            }

            func accelerated(classicOnly: Bool) throws -> ResolvedGraphics {
                rendererEnvironment[DoryDesktopGraphicsPreference.legacyClassicOnlyEnvironmentKey] =
                    classicOnly ? "1" : "0"
                let renderer = try VirglRenderer.discover(environment: rendererEnvironment)
                return ResolvedGraphics(
                    backend: classicOnly ? .virgl : .virglVenus,
                    renderer: renderer
                )
            }

            if let exactLevel {
                switch exactLevel {
                case .hardwareAccelerated3D:
                    return try accelerated(classicOnly: false)
                case .hostAcceleratedDisplay:
                    return try accelerated(classicOnly: true)
                case .software:
                    return ResolvedGraphics(backend: .software, renderer: nil)
                case .none:
                    throw VMError.bootFailure(
                        "raw-HV desktop cannot satisfy a no-graphics resolved plan"
                    )
                }
            }

            switch preference {
            case .automatic:
                if requireVulkan {
                    do {
                        return try accelerated(classicOnly: false)
                    } catch {
                        throw VMError.bootFailure(
                            "generic Linux desktop requires Dory's Vulkan-capable Venus renderer; \(error)"
                        )
                    }
                }
                do {
                    return try accelerated(classicOnly: false)
                } catch let venusError {
                    log("VirGL2 + Venus unavailable; trying classic VirGL2: \(venusError)")
                    do {
                        return try accelerated(classicOnly: true)
                    } catch let virglError {
                        log("accelerated graphics unavailable; using software scanout: \(virglError)")
                        return ResolvedGraphics(backend: .software, renderer: nil)
                    }
                }
            case .virgl:
                return try accelerated(classicOnly: true)
            case .virglVenus:
                return try accelerated(classicOnly: false)
            case .software:
                return ResolvedGraphics(backend: .software, renderer: nil)
            }
        }

        private static func kernelCommandLine(
            machineID: String,
            operationID: UUID,
            rootDevice: String,
            graphicsBackend: DoryDesktopGraphicsBackend,
            genericGuest: Bool
        ) -> String {
            var arguments = [
                "console=ttyAMA0",
                "earlycon=pl011,mmio32,0x0c000000",
                "root=\(rootDevice)",
                "rw",
                "rootwait",
                "panic=1",
                "dory.machine_id=\(machineID)",
                "dory.operation_id=\(DoryOperationIdentity.canonical(operationID))",
                graphicsBackend.kernelArgument,
            ]
            if genericGuest {
                // Installer initramfs images commonly default to their live-media boot path
                // (Ubuntu's casper is one example). The same kernel/initramfs can boot the
                // installed root directly when the local-root path is selected explicitly.
                arguments.append("boot=local")
                // Direct-kernel boot does not consume the EFI System Partition. Installer
                // kernels can omit optional FAT/NLS modules that a distro's installed fstab
                // expects for /boot/efi, so keep that nonessential mount out of the boot
                // transaction without modifying the guest filesystem.
                arguments.append("systemd.mask=boot-efi.mount")
            }
            if let legacy = graphicsBackend.legacyKernelArgument {
                arguments.append(legacy)
            }
            return arguments.joined(separator: " ")
        }

        private static func openAppendLog(_ path: String) throws -> FileHandle {
            if !FileManager.default.fileExists(atPath: path) {
                guard FileManager.default.createFile(atPath: path, contents: nil) else {
                    throw VMError.bootFailure("could not create serial log: \(path)")
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try handle.seekToEnd()
            return handle
        }

        private static func appendBootSessionMarker(
            to log: FileHandle,
            machineID: String,
            operationID: UUID
        ) throws {
            let marker = "\n--- DORY BOOT \(Date().formatted(.iso8601)) machine=\(machineID) operation=\(DoryOperationIdentity.canonical(operationID)) runtime=raw-hv-desktop ---\n"
            try log.write(contentsOf: Data(marker.utf8))
            try log.synchronize()
        }

        private static func error(for reason: GuestStopReason) -> Error? {
            switch reason {
            case .powerOff: nil
            case .reset: VMError.unexpectedExit("desktop guest requested reset")
            case let .crash(detail): VMError.unexpectedExit(detail)
            }
        }

        private nonisolated static func log(_ message: String) {
            FileHandle.standardError.write(Data("dory-hv desktop: \(message)\n".utf8))
        }
    }
}

private final class FirstFrameGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var ready = false

    func signal() {
        condition.lock()
        ready = true
        condition.broadcast()
        condition.unlock()
    }

    func wait(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        while !ready {
            if !condition.wait(until: deadline) { break }
        }
        let result = ready
        condition.unlock()
        return result
    }
}
