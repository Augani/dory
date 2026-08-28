import DoryHV
import DoryCore
import DorydKit
import DoryOperations
import DoryVMContracts
import Foundation

signal(SIGPIPE, SIG_IGN)

#if arch(arm64)
let defaultBootCommandLine = "console=ttyAMA0 earlycon=pl011,mmio32,0x0c000000 panic=0"
let defaultAgentPingCommandLine = "console=ttyAMA0 earlycon=pl011,mmio32,0x0c000000 root=/dev/vda rw panic=0"
#else
let defaultBootCommandLine = "console=ttyS0 earlyprintk=serial,ttyS0,115200 panic=0"
let defaultAgentPingCommandLine = "root=/dev/vda rw panic=0"
#endif

func fail(
    _ message: String,
    status: DoryDesktopHelperExitStatus = .generalFailure
) -> Never {
    FileHandle.standardError.write(Data("dory-hv: \(message)\n".utf8))
    exit(status.rawValue)
}

do {
    try HostFileDescriptorLimit.raiseSoftLimit()
} catch {
    fail("raise file-descriptor limit: \(error)")
}

struct Options {
    var kernel: String?
    var initfs: String?
    var memoryMB: UInt64 = 2048
    var cpus: Int = 1
    var commandLine = defaultBootCommandLine
    var timeoutSeconds: UInt64 = 30
}

func parseOptions(_ arguments: ArraySlice<String>) -> Options {
    var options = Options()
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--kernel": options.kernel = iterator.next()
        case "--initfs": options.initfs = iterator.next()
        case "--mem-mb": options.memoryMB = iterator.next().flatMap(UInt64.init) ?? options.memoryMB
        case "--cpus": options.cpus = iterator.next().flatMap(Int.init) ?? options.cpus
        case "--cmdline": options.commandLine = iterator.next() ?? options.commandLine
        case "--timeout-sec": options.timeoutSeconds = iterator.next().flatMap(UInt64.init) ?? options.timeoutSeconds
        default: fail("unknown option \(argument)")
        }
    }
    return options
}

private final class AgentPingResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<AgentInfo, Error>?

    @discardableResult
    func setIfEmpty(_ result: Result<AgentInfo, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stored == nil else { return false }
        stored = result
        return true
    }

    func get() -> Result<AgentInfo, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

func attachBackend(_ backend: VirtioDeviceBackend, to machine: Machine, slot: Int) throws {
    let spi = GuestLayout.virtioFirstIRQ + UInt32(slot)
    let transport = VirtioMMIOTransport(
        baseAddress: GuestLayout.virtioBase + UInt64(slot) * GuestLayout.virtioSlotSize,
        backend: backend,
        memory: machine.memory
    ) { [weak machine] in
        machine?.raiseGSI(spi)
    }
    try machine.attachVirtioSlot(transport, at: slot)
}

func attachPlatformDevices(to machine: Machine, console: FileHandle) {
    #if arch(arm64)
    machine.attachConsole(PL011(baseAddress: GuestLayout.uartBase) { byte in
        console.write(Data([byte]))
    })
    machine.bus.attach(PL031(baseAddress: GuestLayout.rtcBase))
    #else
    machine.attachConsole(UART16550(basePort: UInt16(truncatingIfNeeded: GuestLayout.uartBase)) { byte in
        console.write(Data([byte]))
    })
    machine.attachRTC(CMOSRTC(basePort: UInt16(truncatingIfNeeded: GuestLayout.rtcBase)))
    machine.attachResetController(I8042 { [weak machine] in
        FileHandle.standardError.write(Data("dory-hv: guest requested i8042 reset\n".utf8))
        machine?.requestStop(.reset)
    })
    #endif
}

func runAgentPing(_ options: Options) {
    guard let kernel = options.kernel else { fail("agent-ping requires --kernel") }
    guard let initfs = options.initfs else { fail("agent-ping requires --initfs") }
    guard FileManager.default.fileExists(atPath: kernel) else { fail("kernel not found: \(kernel)") }
    guard FileManager.default.fileExists(atPath: initfs) else { fail("initfs not found: \(initfs)") }

    do {
        let commandLine = options.commandLine == Options().commandLine
            ? defaultAgentPingCommandLine
            : options.commandLine
        let machine = try Machine(configuration: MachineConfiguration(
            kernelPath: kernel,
            commandLine: commandLine,
            memoryBytes: options.memoryMB << 20,
            cpuCount: options.cpus
        ))
        attachPlatformDevices(to: machine, console: FileHandle.standardError)
        let vsock = VirtioVsock(guestCID: 3)
        let backends: [VirtioDeviceBackend] = [
            try VirtioBlk(path: initfs, identity: "dory-initfs"),
            VirtioRng(),
            VirtioBalloon(memory: machine.memory) { message in
                FileHandle.standardError.write(Data("dory-hv: \(message)\n".utf8))
            },
            vsock,
        ]
        for (slot, backend) in backends.enumerated() {
            try attachBackend(backend, to: machine, slot: slot)
        }
        try machine.loadBootPayload()

        let deadline = DispatchTime.now().uptimeNanoseconds + options.timeoutSeconds * 1_000_000_000
        let semaphore = DispatchSemaphore(value: 0)
        let probeFinished = DispatchSemaphore(value: 0)
        let result = AgentPingResultBox()
        let machineRunner = RawHVMachineRunner(
            machine: machine,
            threadName: "dory-hv.agent-ping.vcpu0"
        )
        try machineRunner.start { machineResult in
            let failure: any Error
            switch machineResult {
            case .success(let reason):
                failure = VMError.bootFailure(
                    "guest stopped before agent answered: \(reason)"
                )
            case .failure(let error):
                failure = error
            }
            if result.setIfEmpty(.failure(failure)) {
                semaphore.signal()
            }
        }

        let probeTask = Task.detached {
            defer { probeFinished.signal() }
            while !Task.isCancelled,
                  DispatchTime.now().uptimeNanoseconds < deadline {
                var connection: VsockConnection?
                do {
                    let admitted = try vsock.connectForServiceIfCapacity(
                        port: VsockPorts.agent,
                        service: .agentRPC
                    )
                    connection = admitted
                    let channel = AgentChannel(connection: admitted)
                    let info = try await channel.info()
                    if result.setIfEmpty(.success(info)) {
                        semaphore.signal()
                    }
                    return
                } catch {
                    connection?.close()
                    do {
                        try await Task.sleep(nanoseconds: 500_000_000)
                    } catch {
                        return
                    }
                }
            }
            guard !Task.isCancelled else { return }
            if result.setIfEmpty(.failure(VMError.bootFailure(
                "guest agent did not answer on vsock port 1024 within \(options.timeoutSeconds)s"
            ))) {
                semaphore.signal()
            }
        }
        semaphore.wait()
        probeTask.cancel()
        probeFinished.wait()
        switch result.get() {
        case .success(let info):
            _ = try machineRunner.stopAndWait(.powerOff)
            let data = try JSONEncoder().encode(info)
            print(String(decoding: data, as: UTF8.self))
        case .failure(let error):
            _ = try? machineRunner.stopAndWait(.crash("agent-ping failed: \(error)"))
            throw error
        case nil:
            _ = try? machineRunner.stopAndWait(
                .crash("agent-ping ended without a result")
            )
            throw VMError.bootFailure("agent-ping ended without a result")
        }
    } catch {
        fail("\(error)")
    }
}

let arguments: [String]
do {
    arguments = try DoryApplicationLaunchHandoffClient.receiveIfRequested(
        arguments: Array(CommandLine.arguments.dropFirst())
    )
} catch {
    fail("application launch authority handoff failed: \(error)")
}
guard let command = arguments.first else {
    fail("usage: dory-hv <smoke|madvtest|desktop|agent-ping|engine|usb|renderer-qualify> [options]")
}

switch command {
case "smoke":
    do {
        let result = try HVSmoke.run()
        print("dory-hv: \(result)")
    } catch {
        fail("\(error)")
    }
case "madvtest":
    do {
        try MadviseProbe.run()
    } catch {
        fail("\(error)")
    }
case "renderer-qualify":
    do {
        try RendererBootstrapQualificationCommand.run(arguments.dropFirst())
    } catch {
        fail("renderer qualification failed: \(error)")
    }
case "desktop":
    var machineID: String?
    var operationID: UUID?
    var stateDirectory: String?
    var kernel: String?
    var initrd: String?
    var rootfs: String?
    var runtimeLaunchEnvelope: RuntimeLaunchEnvelope?
    var legacyGraphicsBackend: DoryDesktopGraphicsBackend?
    var rootDevice = "/dev/vda"
    var rootDeviceWasSpecified = false
    var genericGuest = false
    var bootMode: String?
    var gvproxy: String?
    var handoffSocket: String?
    var agentSocket: String?
    var shellSocket: String?
    var consoleSocket: String?
    var controlSocket: String?
    var usbControlSocket: String?
    var sshAgentSocket: String?
    var memoryMB: UInt64 = 6_144
    var memoryWasSpecified = false
    var cpus = 6
    var cpusWereSpecified = false
    var shares = [DoryMachineShareConfiguration]()
    var environment = [String: String]()
    var displayPresentation: DoryMachineDisplayPresentation = .windowed
    var iterator = arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--machine-id": machineID = iterator.next()
        case "--operation-id":
            guard let value = iterator.next(),
                  let parsed = DoryOperationIdentity.parseCanonical(value) else {
                fail("desktop --operation-id requires a canonical lowercase UUID")
            }
            operationID = parsed
        case "--state-dir": stateDirectory = iterator.next()
        case "--kernel": kernel = iterator.next()
        case "--initrd": initrd = iterator.next()
        case "--rootfs": rootfs = iterator.next()
        case "--runtime-launch-envelope":
            guard let value = iterator.next() else {
                fail("desktop --runtime-launch-envelope requires a value")
            }
            do {
                runtimeLaunchEnvelope = try RuntimeLaunchEnvelope.decodeResolvedRawHVArgument(value)
            } catch {
                fail("invalid desktop runtime launch envelope: \(error)")
            }
        case "--legacy-graphics":
            guard let value = iterator.next(),
                  let backend = DoryDesktopGraphicsBackend(rawValue: value) else {
                fail("desktop --legacy-graphics requires software, virgl, or virgl-venus")
            }
            legacyGraphicsBackend = backend
        case "--root-device":
            rootDeviceWasSpecified = true
            rootDevice = iterator.next() ?? rootDevice
        case "--generic-guest": genericGuest = true
        case "--gvproxy": gvproxy = iterator.next()
        case "--handoff-sock": handoffSocket = iterator.next()
        case "--agent-sock": agentSocket = iterator.next()
        case "--shell-sock": shellSocket = iterator.next()
        case "--console-sock": consoleSocket = iterator.next()
        case "--ssh-agent-socket": sshAgentSocket = iterator.next()
        case "--memory-mb", "--mem-mb":
            guard let value = iterator.next(), let parsed = UInt64(value), parsed > 0 else {
                fail("desktop --memory-mb requires a positive integer")
            }
            memoryMB = parsed
            memoryWasSpecified = true
        case "--cpus":
            guard let value = iterator.next(), let parsed = Int(value), parsed > 0 else {
                fail("desktop --cpus requires a positive integer")
            }
            cpus = parsed
            cpusWereSpecified = true
        case "--share":
            guard let value = iterator.next() else { fail("desktop --share requires a value") }
            do { shares.append(try DoryMachineShareConfiguration(argument: value)) }
            catch { fail("invalid desktop share: \(error)") }
        case "--env":
            guard let value = iterator.next(), let equals = value.firstIndex(of: "=") else {
                fail("desktop --env requires KEY=VALUE")
            }
            environment[String(value[..<equals])] = String(value[value.index(after: equals)...])
        case "--display-presentation":
            guard let value = iterator.next(),
                  let data = value.data(using: .utf8),
                  let presentation = try? JSONDecoder().decode(
                      DoryMachineDisplayPresentation.self,
                      from: data
                  ), presentation.isValid else {
                fail("desktop --display-presentation requires a valid host presentation contract")
            }
            displayPresentation = presentation.canonicalized
        case "--display-mode":
            guard iterator.next() == "desktop" else { fail("raw-HV desktop requires --display-mode desktop") }
        case "--boot-mode":
            guard let mode = iterator.next(), ["linux-kernel", "efi-installed"].contains(mode) else {
                fail("raw-HV desktop requires --boot-mode linux-kernel or efi-installed")
            }
            bootMode = mode
        case "--control-sock": controlSocket = iterator.next()
        case "--usb-control-sock": usbControlSocket = iterator.next()
        default:
            fail("unknown desktop option \(argument)")
        }
    }
    guard let machineID, !machineID.isEmpty else { fail("desktop requires --machine-id") }
    guard let operationID else { fail("desktop requires --operation-id") }
    guard let stateDirectory, !stateDirectory.isEmpty else { fail("desktop requires --state-dir") }
    if let runtimeLaunchEnvelope {
        guard runtimeLaunchEnvelope.machineID == machineID,
              runtimeLaunchEnvelope.operationID == operationID,
              legacyGraphicsBackend == nil,
              !memoryWasSpecified,
              !cpusWereSpecified,
              runtimeLaunchEnvelope.executionResources.schedulingPolicyRevision
                == RawHVSchedulingPolicy.revision else {
            fail("desktop invocation identity does not match the immutable runtime launch envelope")
        }
    } else if legacyGraphicsBackend == nil {
        fail("desktop legacy launch requires one typed --legacy-graphics selection")
    }
    // Decoding the envelope performs canonical schema-v5 validation. Legacy pathname mode has no
    // resolved graphics/device/forward authority and deliberately passes nil to DesktopMode.
    let resolvedGraphics = runtimeLaunchEnvelope?.graphics
    let resolvedDevices = runtimeLaunchEnvelope?.devices
    let resolvedPortForwards = runtimeLaunchEnvelope?.portForwards
    let effectiveMemoryMB = runtimeLaunchEnvelope?.executionResources.memoryMB ?? memoryMB
    let effectiveCPUCount = runtimeLaunchEnvelope.map {
        Int($0.executionResources.virtualCPUCount)
    } ?? cpus
    let systemDiskQueueCount = runtimeLaunchEnvelope.map {
        Int($0.executionResources.systemDiskQueueCount)
    } ?? 1
    let bootPayload: MachineBootPayload
    let effectiveRootDevice: String
    let effectiveGenericGuest: Bool
    let resolvedSystemDiskLogicalID: DoryVirtualDeviceID?
    var resolvedRawHVResources: RuntimeLaunchEnvelope.ResolvedRawHVResources?
    if let runtimeLaunchEnvelope {
        guard kernel == nil,
              initrd == nil,
              rootfs == nil,
              !rootDeviceWasSpecified,
              !genericGuest,
              bootMode == nil else {
            fail("desktop resolved launch rejects pathname or split boot authority")
        }
        do {
            let resources = try runtimeLaunchEnvelope.validatedResolvedRawHVResources()
            resolvedRawHVResources = resources
            guard let systemDiskLogicalID = resources.systemDisk.logicalDeviceID,
                  let kernelSHA256 = resources.linuxKernel.contentSHA256 else {
                fail("desktop resolved launch envelope lost required resource identity")
            }
            let initrdAuthority = try resources.linuxInitrd.map { slot in
                guard let sha256 = slot.contentSHA256 else {
                    throw VMError.invalidConfiguration(
                        "resolved linuxInitrd is missing exact digest authority"
                    )
                }
                return MachineInheritedBootBlob(
                    descriptor: slot.descriptor,
                    byteCount: slot.byteCount,
                    sha256: sha256,
                    maximumByteCount: RuntimeLaunchEnvelope.maximumLinuxInitrdBytes
                )
            }
            bootPayload = try MachineBootPayload.inheritedReadOnlyDescriptors(
                kernel: MachineInheritedBootBlob(
                    descriptor: resources.linuxKernel.descriptor,
                    byteCount: resources.linuxKernel.byteCount,
                    sha256: kernelSHA256,
                    maximumByteCount: RuntimeLaunchEnvelope.maximumLinuxKernelBytes
                ),
                initrd: initrdAuthority
            )
            effectiveRootDevice = runtimeLaunchEnvelope.linuxDirectBoot.rootDevice
            effectiveGenericGuest = runtimeLaunchEnvelope.linuxDirectBoot.genericGuest
            resolvedSystemDiskLogicalID = systemDiskLogicalID
        } catch {
            fail("desktop inherited boot authority is invalid: \(error)")
        }
    } else {
        resolvedRawHVResources = nil
        guard let kernel else { fail("desktop legacy launch requires --kernel") }
        if genericGuest, initrd == nil {
            fail("desktop --generic-guest requires --initrd")
        }
        bootPayload = .legacyPaths(kernel: kernel, initrd: initrd)
        effectiveRootDevice = rootDevice
        effectiveGenericGuest = genericGuest
        resolvedSystemDiskLogicalID = nil
    }
    let rootDisk: DesktopMode.RootDiskBacking
    do {
        rootDisk = try DesktopMode.RootDiskBacking.resolve(
            legacyPath: rootfs,
            runtimeLaunchEnvelope: runtimeLaunchEnvelope
        )
    } catch {
        fail("desktop root-disk authority is invalid: \(error)")
    }
    guard let gvproxy else { fail("desktop requires --gvproxy") }
    guard let handoffSocket else { fail("desktop requires --handoff-sock") }
    guard let agentSocket else { fail("desktop requires --agent-sock") }
    guard let shellSocket else { fail("desktop requires --shell-sock") }
    guard let consoleSocket else { fail("desktop requires --console-sock") }
    guard let controlSocket else { fail("desktop requires --control-sock") }
    if let envelopeDevices = runtimeLaunchEnvelope?.devices {
        if envelopeDevices.removableUSBHotplug, usbControlSocket == nil {
            fail("desktop resolved removable USB hotplug requires --usb-control-sock")
        }
        if !envelopeDevices.removableUSBHotplug, usbControlSocket != nil {
            fail("desktop --usb-control-sock is not authorized by the resolved device contract")
        }
    }
    let rendererWorkerLaunch: DesktopRendererWorkerLaunch?
    do {
        rendererWorkerLaunch = try await DesktopRendererWorkerLaunch.prepare(
            resolvedGraphics: resolvedGraphics,
            rendererBootstrapAuthority: resolvedRawHVResources?.rendererBootstrap,
            exactManagedKernelSHA256:
                resolvedRawHVResources?.linuxKernel.contentSHA256
        )
    } catch {
        fail("desktop renderer-worker launch authority is invalid: \(error)")
    }
    defer { rendererWorkerLaunch?.teardown() }
    do {
        try DesktopMode.run(.init(
            machineID: machineID,
            operationID: operationID,
            stateDirectory: stateDirectory,
            bootPayload: bootPayload,
            rootDisk: rootDisk,
            rootDevice: effectiveRootDevice,
            genericGuest: effectiveGenericGuest,
            gvproxyPath: gvproxy,
            handoffSocketPath: handoffSocket,
            agentSocketPath: agentSocket,
            shellSocketPath: shellSocket,
            consoleSocketPath: consoleSocket,
            controlSocketPath: controlSocket,
            usbControlSocketPath: usbControlSocket,
            sshAgentSocketPath: sshAgentSocket,
            memoryMB: effectiveMemoryMB,
            cpuCount: effectiveCPUCount,
            systemDiskQueueCount: systemDiskQueueCount,
            shares: shares,
            environment: environment,
            legacyGraphicsBackend: legacyGraphicsBackend,
            resolvedGraphics: resolvedGraphics,
            rendererWorkerLaunch: rendererWorkerLaunch,
            resolvedPlanSHA256: runtimeLaunchEnvelope?.resolvedPlanSHA256,
            resolvedPlanRevision: runtimeLaunchEnvelope?.planRevision,
            resolvedDevices: resolvedDevices,
            resolvedPortForwards: resolvedPortForwards,
            rawHVVirtualHardwareTopology:
                runtimeLaunchEnvelope?.rawHVVirtualHardwareTopology,
            resolvedSystemDiskLogicalID: resolvedSystemDiskLogicalID,
            displayPresentation: displayPresentation
        ))
    } catch {
        let status = desktopHelperExitStatus(for: error)
        let failureKind = status == .rendererCandidateFailure
            ? "desktop renderer candidate failed"
            : "desktop failed"
        fail("\(failureKind): \(error)", status: status)
    }
case "agent-ping":
    runAgentPing(parseOptions(arguments.dropFirst()))
case "usb":
    let subcommand = arguments.dropFirst().first ?? "list"
    switch subcommand {
    case "list", "ls":
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(HostUsbDiscovery.list())
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fail("usb list failed: \(error)")
        }
    default:
        fail("usage: dory-hv usb list")
    }
case "engine":
    var engineSocket = "\(NSHomeDirectory())/.dory/engine.sock"
    var kernel: String?
    var gvproxy: String?
    var memoryMB: UInt64 = 2048
    var cpus = 4
    var rootfs: String?
    var stateDirectory: String?
    var dockerDataDisk: String?
    var dataDriveRoot: String?
    var shares: [VirtioFSShareConfiguration] = []
    var directIPRequested = false
    var directIPSubnet: String?
    var directIPGateway = "192.168.127.2"
    var directIPv6Subnet: String?
    var directIPv6Guest = "fd7d:6f72:7900::2"
    var directIPv6VirtualNetwork = "fd7d:6f72:7900::/64"
    var directIPv6HostGateway = "fd7d:6f72:7900::1"
    var gpuMode = EngineMode.GPUAccelerationMode.off
    var reclaimPolicy = EngineMode.ReclaimPolicy.dropCaches
    var fuseRequestQueuePolicy = EngineMode.FuseRequestQueuePolicy.automatic
    var amd64Emulation = false
    var publishHost = "127.0.0.1"
    var agentVsockForward: String?
    var sshAgentSocket: String?
    var guestAgent: String?
    var iterator = arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--engine-sock": engineSocket = iterator.next() ?? engineSocket
        case "--agent-vsock-forward": agentVsockForward = iterator.next()
        case "--ssh-agent-socket": sshAgentSocket = iterator.next()
        case "--kernel": kernel = iterator.next()
        case "--gvproxy": gvproxy = iterator.next()
        case "--rootfs": rootfs = iterator.next()
        case "--state-dir":
            guard let value = iterator.next(), !value.isEmpty else {
                fail("engine --state-dir requires a non-empty path")
            }
            stateDirectory = value
        case "--data-disk":
            guard let value = iterator.next(), !value.isEmpty else {
                fail("engine --data-disk requires a non-empty absolute path")
            }
            guard value.hasPrefix("/") else { fail("engine --data-disk requires an absolute path") }
            dockerDataDisk = value
        case "--data-drive":
            guard let value = iterator.next(), !value.isEmpty else {
                fail("engine --data-drive requires a non-empty absolute .dorydrive path")
            }
            do {
                let environmentHome = DoryDataDrive.processHome()
                let drive = try DoryDataDrive(home: environmentHome, overrideRoot: value)
                try drive.prepare()
                dockerDataDisk = drive.engineDataDiskPath
                dataDriveRoot = drive.root
            } catch {
                fail("invalid Dory data drive: \(error)")
            }
        case "--mem-mb": memoryMB = iterator.next().flatMap(UInt64.init) ?? memoryMB
        case "--cpus": cpus = iterator.next().flatMap(Int.init) ?? cpus
        case "--direct-ip":
            directIPRequested = true
            directIPSubnet = directIPSubnet ?? "192.168.215.0/24"
        case "--container-subnet": directIPSubnet = iterator.next()
        case "--guest-gateway": directIPGateway = iterator.next() ?? directIPGateway
        case "--direct-ipv6":
            directIPSubnet = directIPSubnet ?? "192.168.215.0/24"
            directIPv6Subnet = directIPv6Subnet ?? "fd7d:6f72:7901::/64"
        case "--container-subnet-v6": directIPv6Subnet = iterator.next()
        case "--guest-ipv6": directIPv6Guest = iterator.next() ?? directIPv6Guest
        case "--virtual-network-v6": directIPv6VirtualNetwork = iterator.next() ?? directIPv6VirtualNetwork
        case "--host-gateway-v6": directIPv6HostGateway = iterator.next() ?? directIPv6HostGateway
        case "--gpu":
            gpuMode = parseGPUMode(iterator.next() ?? "")
        case let value where value.hasPrefix("--gpu="):
            gpuMode = parseGPUMode(String(value.dropFirst("--gpu=".count)))
        case "--memory-reclaim":
            guard let value = iterator.next(),
                  let parsed = EngineMode.ReclaimPolicy(rawValue: value) else {
                fail("engine --memory-reclaim requires drop-caches or senpai")
            }
            reclaimPolicy = parsed
        case "--fuse-request-queues":
            guard let value = iterator.next(), let count = Int(value) else {
                fail("engine --fuse-request-queues requires an integer from 1 through 8")
            }
            do {
                fuseRequestQueuePolicy = try EngineMode.FuseRequestQueuePolicy(
                    fixedCount: count
                )
            } catch {
                fail("\(error)")
            }
        case "--amd64":
            amd64Emulation = true
        case "--publish-host":
            // Fail safe: only the two well-known bind addresses are honored; anything else stays
            // loopback-only so a malformed value can never silently expose ports to the LAN.
            publishHost = iterator.next() == "0.0.0.0" ? "0.0.0.0" : "127.0.0.1"
        case "--guest-agent":
            guestAgent = iterator.next()
        case "--share":
            guard let value = iterator.next() else { fail("--share requires tag=/host/path[:ro|:rw][:safe][:at=/guest/path]; DAX host shares are disabled") }
            do {
                shares.append(try VirtioFSShareConfiguration(argument: value))
            } catch {
                fail("\(error)")
            }
        default: fail("unknown option \(argument)")
        }
    }
    guard let kernel else { fail("engine requires --kernel") }
    guard let gvproxy else { fail("engine requires --gvproxy") }
    guard let stateDirectory else {
        fail("engine requires explicit --state-dir; refusing to select persistent Docker state implicitly")
    }
    let configuration = EngineMode.Configuration(
        engineSocket: engineSocket,
        kernelPath: kernel,
        gvproxyPath: gvproxy,
        memoryMB: memoryMB,
        cpus: cpus,
        stateDirectory: stateDirectory,
        dockerDataDiskPath: dockerDataDisk,
        dataDriveRoot: dataDriveRoot,
        bundledRootfs: rootfs,
        shares: shares,
        directIP: directIPSubnet.map { subnet in
            let bridgeNetwork: DoryIPv4BridgeNetwork
            do {
                bridgeNetwork = try DoryIPv4BridgeNetwork(subnet)
            } catch {
                fail("invalid --container-subnet: \(error)")
            }
            return DirectIPBridgeConfiguration(
                subnetCIDR: bridgeNetwork.cidr,
                gateway: directIPGateway,
                tunnelEnabled: directIPRequested,
                ipv6SubnetCIDR: directIPv6Subnet,
                ipv6Gateway: directIPv6Subnet == nil ? nil : directIPv6Guest,
                ipv6VirtualNetworkCIDR: directIPv6Subnet == nil ? nil : directIPv6VirtualNetwork,
                ipv6HostGateway: directIPv6Subnet == nil ? nil : directIPv6HostGateway,
                gvproxySocketPath: "",
                localSocketPath: "\(stateDirectory)/direct-ip.sock",
                interfaceNamePath: "\(stateDirectory)/direct-ip.interface"
            )
        },
        gpuMode: gpuMode,
        reclaimPolicy: reclaimPolicy,
        fuseRequestQueuePolicy: fuseRequestQueuePolicy,
        amd64Emulation: amd64Emulation,
        publishHost: publishHost,
        agentVsockForward: agentVsockForward,
        sshAgentSocket: sshAgentSocket,
        guestAgentPath: guestAgent
    )
    do {
        try EngineMode.run(configuration)
    } catch {
        fail("engine failed: \(error)")
    }
default:
    fail("unknown command \(command)")
}

private func parseGPUMode(_ value: String) -> EngineMode.GPUAccelerationMode {
    guard let mode = EngineMode.GPUAccelerationMode(rawValue: value) else {
        fail("unknown gpu mode \(value); expected off or venus")
    }
    return mode
}
