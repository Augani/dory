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
        case disconnected

        init(resolvedDevices: DoryVirtualMachineDeviceCapabilityRequest?) throws {
            switch resolvedDevices?.networkAttachment ?? .sharedNAT {
            case .sharedNAT:
                self = .sharedNAT
            case .disconnected:
                self = .disconnected
            case .bridged, .isolated:
                throw VMError.bootFailure(
                    "resolved device contract contains a network mode not implemented by raw-HV"
                )
            }
        }

        var startsGVProxy: Bool { self == .sharedNAT }
        var attachesNetworkDevice: Bool { self == .sharedNAT }
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
        private var signalSources = [DispatchSourceSignal]()
        private var stopError: Error?
        private var stopping = false

        init(configuration: Configuration) throws {
            self.configuration = configuration
            try FileManager.default.createDirectory(
                atPath: configuration.stateDirectory,
                withIntermediateDirectories: true
            )
            self.stateLock = try EngineStateDirectoryLock(stateDirectory: configuration.stateDirectory)
            self.serialLog = try Self.openAppendLog("\(configuration.stateDirectory)/serial.log")
            let resolvedGraphics = try Self.resolveGraphics(
                environment: configuration.environment,
                requireVulkan: configuration.genericGuest,
                exactLevel: configuration.resolvedGraphics
            )
            self.graphicsBackend = resolvedGraphics.backend
            let networkPlan = try NetworkPlan(resolvedDevices: configuration.resolvedDevices)
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
            let firstFrame = FirstFrameGate()
            self.firstFrame = firstFrame
            self.display = try DesktopMetalView(
                frame: NSRect(x: 0, y: 0, width: 1_280, height: 800),
                input: input
            )
            mailbox.view = display

            let renderer = resolvedGraphics.renderer
            let hostVisibleMemory = try renderer.map { _ in
                try VirtioGPUHostVisibleMemory(guestBase: GuestLayout.daxWindowBase)
            }
            let gpu = VirtioGPU(
                hostMemoryBase: GuestLayout.daxWindowBase,
                scanoutCount: 1,
                scanoutWidth: 2_560,
                scanoutHeight: 1_600,
                renderer: renderer,
                hostVisibleMemory: hostVisibleMemory,
                traceResourceLifecycle: configuration.environment["DORY_GPU_TRACE_RESOURCES"] == "1",
                onScanoutFrame: { [mailbox, firstFrame] frame in
                    mailbox.submit(frame)
                    firstFrame.signal()
                },
                onScanoutResourceReleased: { [mailbox] resourceID in
                    mailbox.release(resourceID: resourceID)
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
                contentRect: NSRect(x: 0, y: 0, width: 1_280, height: 800),
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
            application.setActivationPolicy(.regular)
            application.delegate = self
            installSignalHandlers()
            window.makeKeyAndOrderFront(nil)
            application.activate()
            startMachine()
            application.run()
            cleanup()
            if let stopError { throw stopError }
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
                                agentBuild: "dory-hv/generic-linux",
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
                            agentBuild: info.agentBuild,
                            agentProtocolVersion: info.protocolVersion,
                            agentCapabilities: info.capabilities,
                            agentSocketPath: configuration.agentSocketPath,
                            shellSocketPath: configuration.shellSocketPath,
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
                    try requireSuccess(control.exec(
                        argv: ["/usr/lib/dory/configure-machine"],
                        env: configuration.environment.sorted(by: { $0.key < $1.key }).map {
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
            let backend: VirtioNet?
        }

        private static func prepareNetwork(
            plan: NetworkPlan,
            gvproxyPath: String,
            runtimeDirectory: String,
            token: String
        ) throws -> NetworkRuntime {
            guard plan.startsGVProxy, plan.attachesNetworkDevice else {
                return NetworkRuntime(process: nil, socketPaths: [], backend: nil)
            }
            let gvproxySocket = "\(runtimeDirectory)/\(token)-gv.sock"
            let vmNetworkSocket = "\(runtimeDirectory)/\(token)-vm.sock"
            let apiSocket = "\(runtimeDirectory)/\(token)-api.sock"
            let socketPaths = [gvproxySocket, vmNetworkSocket, apiSocket]
            for path in socketPaths { unlink(path) }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: gvproxyPath)
            process.arguments = GVProxyDesktopLaunchPlan.arguments(
                mtu: DoryNetworkMTU.resolved(),
                datapathSocket: gvproxySocket,
                apiSocket: apiSocket
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
                        remotePath: gvproxySocket
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
