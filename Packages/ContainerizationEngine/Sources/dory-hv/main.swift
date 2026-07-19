import DoryHV
import DoryCore
import Foundation

signal(SIGPIPE, SIG_IGN)

#if arch(arm64)
let defaultBootCommandLine = "console=ttyAMA0 earlycon=pl011,mmio32,0x0c000000 panic=0"
let defaultAgentPingCommandLine = "console=ttyAMA0 earlycon=pl011,mmio32,0x0c000000 root=/dev/vda rw panic=0"
#else
let defaultBootCommandLine = "console=ttyS0 earlyprintk=serial,ttyS0,115200 panic=0"
let defaultAgentPingCommandLine = "root=/dev/vda rw panic=0"
#endif

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("dory-hv: \(message)\n".utf8))
    exit(1)
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
    var disks: [String] = []
    var gvproxy: String?
    var timeoutSeconds: UInt64 = 30
    var shares: [VirtioFSShareConfiguration] = []
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
        case "--disk": if let disk = iterator.next() { options.disks.append(disk) }
        case "--gvproxy": options.gvproxy = iterator.next()
        case "--timeout-sec": options.timeoutSeconds = iterator.next().flatMap(UInt64.init) ?? options.timeoutSeconds
        case "--share":
            guard let value = iterator.next() else { fail("--share requires tag=/host/path[:ro|:rw][:safe][:at=/guest/path]; DAX host shares are disabled") }
            do {
                options.shares.append(try VirtioFSShareConfiguration(argument: value))
            } catch {
                fail("\(error)")
            }
        default: fail("unknown option \(argument)")
        }
    }
    return options
}

private final class AgentPingResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<AgentInfo, Error>?

    func set(_ result: Result<AgentInfo, Error>) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    func get() -> Result<AgentInfo, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

func attachBackend(_ backend: VirtioDeviceBackend, to machine: Machine, slot: Int) {
    let spi = GuestLayout.virtioFirstIRQ + UInt32(slot)
    let transport = VirtioMMIOTransport(
        baseAddress: GuestLayout.virtioBase + UInt64(slot) * GuestLayout.virtioSlotSize,
        backend: backend,
        memory: machine.memory
    ) { [weak machine] in
        machine?.raiseGSI(spi)
    }
    machine.attachVirtioSlot(transport)
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
            attachBackend(backend, to: machine, slot: slot)
        }
        try machine.loadBootPayload()

        let runThread = Thread {
            do {
                let stop = try machine.run()
                FileHandle.standardError.write(Data("dory-hv: guest stopped before agent answered: \(stop)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("dory-hv: guest failed before agent answered: \(error)\n".utf8))
            }
        }
        runThread.name = "dory-hv.agent-ping.vm"
        runThread.start()

        let deadline = DispatchTime.now().uptimeNanoseconds + options.timeoutSeconds * 1_000_000_000
        let semaphore = DispatchSemaphore(value: 0)
        let result = AgentPingResultBox()
        Task.detached {
            while DispatchTime.now().uptimeNanoseconds < deadline {
                let connection = vsock.connect(port: VsockPorts.agent)
                let channel = AgentChannel(connection: connection)
                do {
                    let info = try await channel.info()
                    result.set(.success(info))
                    semaphore.signal()
                    return
                } catch {
                    connection.close()
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            result.set(.failure(VMError.bootFailure("guest agent did not answer on vsock port 1024 within \(options.timeoutSeconds)s")))
            semaphore.signal()
        }
        semaphore.wait()
        switch result.get() {
        case .success(let info):
            let data = try JSONEncoder().encode(info)
            print(String(decoding: data, as: UTF8.self))
            exit(0)
        case .failure(let error):
            fail("\(error)")
        case nil:
            fail("agent-ping ended without a result")
        }
    } catch {
        fail("\(error)")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("usage: dory-hv <smoke|madvtest|daxprobe|boot|agent-ping|data-drive|engine|usb> [options]")
}

switch command {
case "data-drive":
    guard arguments.count >= 2 else {
        fail("usage: dory-hv data-drive <resolve|prepare|id|selected-path|select|bind-existing|recover-existing|capacity|grow|backup|verify-backup|restore> [paths]")
    }
    let operation = arguments[1]
    do {
        let home = DoryDataDrive.processHome()
        switch operation {
        case "selected-path":
            guard arguments.count == 2 else {
                fail("usage: dory-hv data-drive selected-path")
            }
            guard let path = try DoryDataDriveSelectionStore(home: home).selectedPath() else {
                exit(3)
            }
            print(path)
        case "select", "bind-existing":
            guard arguments.count == 3 else {
                fail("usage: dory-hv data-drive \(operation) <absolute .dorydrive path>")
            }
            let store = try DoryDataDriveSelectionStore(home: home)
            let drive = operation == "select"
                ? try store.prepareSelection(requestedRoot: arguments[2])
                : try store.bindExistingSelection(requestedRoot: arguments[2])
            print(try drive.readManifest().id.uuidString.lowercased())
        case "recover-existing":
            guard arguments.count == 3 else {
                fail("usage: dory-hv data-drive recover-existing <absolute .dorydrive path>")
            }
            let store = try DoryDataDriveSelectionStore(home: home)
            let drive = try store.recoverExistingSelection(requestedRoot: arguments[2])
            print(try drive.readManifest().id.uuidString.lowercased())
        case "resolve":
            guard arguments.count == 3 else {
                fail("usage: dory-hv data-drive resolve <absolute .dorydrive path>")
            }
            let drive = try DoryDataDrive(home: home, overrideRoot: arguments[2])
            print(drive.root)
        case "prepare":
            guard arguments.count == 3 else {
                fail("usage: dory-hv data-drive prepare <absolute .dorydrive path>")
            }
            let drive = try DoryDataDrive(home: home, overrideRoot: arguments[2])
            try drive.prepare()
            print(try drive.readManifest().id.uuidString.lowercased())
        case "id":
            guard arguments.count == 3 else {
                fail("usage: dory-hv data-drive id <absolute .dorydrive path>")
            }
            let drive = try DoryDataDrive(home: home, overrideRoot: arguments[2])
            try drive.validateManifest()
            print(try drive.readManifest().id.uuidString.lowercased())
        case "capacity", "grow":
            let store = try DoryDataDriveSelectionStore(home: home)
            guard let drive = try store.inspectSelection() else {
                fail("no Dory data drive is selected")
            }
            let usage: DockerDataDiskUsage
            if operation == "capacity" {
                guard arguments.count == 2 else {
                    fail("usage: dory-hv data-drive capacity")
                }
                usage = try DockerDataDisk.usage(at: drive.engineDataDiskPath)
            } else {
                guard arguments.count == 3, let capacityGiB = Int(arguments[2]) else {
                    fail("usage: dory-hv data-drive grow <capacity-gib>")
                }
                let driveLock = try EngineStateDirectoryLock(
                    stateDirectory: drive.root,
                    lockFileName: "drive.lock"
                )
                defer { withExtendedLifetime(driveLock) {} }
                usage = try DockerDataDisk.grow(
                    destination: drive.engineDataDiskPath,
                    capacityGiB: capacityGiB
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(usage), as: UTF8.self))
        case "backup":
            guard arguments.count == 4 else {
                fail("usage: dory-hv data-drive backup <source.dorydrive> <archive.dorybackup>")
            }
            let drive = try DoryDataDrive(home: home, overrideRoot: arguments[2])
            let result = try DoryDataDriveTransaction.backup(from: drive, to: arguments[3])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(result), as: UTF8.self))
        case "verify-backup":
            guard arguments.count == 3 else {
                fail("usage: dory-hv data-drive verify-backup <archive.dorybackup>")
            }
            let result = try DoryDataDriveArchive.verifyBackup(at: arguments[2])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(result), as: UTF8.self))
        case "restore":
            guard arguments.count == 4 else {
                fail("usage: dory-hv data-drive restore <archive.dorybackup> <target.dorydrive>")
            }
            let drive = try DoryDataDrive(home: home, overrideRoot: arguments[3])
            let result = try DoryDataDriveTransaction.restore(at: arguments[2], to: drive)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(result), as: UTF8.self))
        default:
            fail("usage: dory-hv data-drive <resolve|prepare|id|selected-path|select|bind-existing|recover-existing|capacity|grow|backup|verify-backup|restore> [paths]")
        }
    } catch {
        fail("data-drive \(operation) failed: \(error)")
    }
case "lzfse":
    let sub = arguments.dropFirst().first
    let paths = Array(arguments.dropFirst(2))
    guard let sub, paths.count == 2 else { fail("usage: dory-hv lzfse <compress|decompress> <in> <out>") }
    do {
        switch sub {
        case "compress": try LZFSE.compress(source: paths[0], destination: paths[1])
        case "decompress": try LZFSE.decompress(source: paths[0], destination: paths[1])
        default: fail("usage: dory-hv lzfse <compress|decompress> <in> <out>")
        }
    } catch {
        fail("lzfse \(sub) failed: \(error)")
    }
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
case "daxprobe":
    do {
        let arg = arguments.dropFirst(1).first
        let base = arg.flatMap { UInt64($0.hasPrefix("0x") ? String($0.dropFirst(2)) : $0, radix: 16) }
        let result = try DaxCoherenceProbe.run(daxGuestBase: base ?? GuestLayout.daxWindowBase)
        print("dory-hv: \(result)")
    } catch {
        fail("\(error)")
    }
case "boot":
    let options = parseOptions(arguments.dropFirst())
    guard let kernel = options.kernel else { fail("boot requires --kernel") }
    do {
        let configuration = MachineConfiguration(
            kernelPath: kernel,
            commandLine: options.commandLine,
            memoryBytes: options.memoryMB << 20,
            cpuCount: options.cpus
        )
        let machine = try Machine(configuration: configuration)
        let console = FileHandle.standardOutput
        attachPlatformDevices(to: machine, console: console)
        var backends: [VirtioDeviceBackend] = []
        for (slot, diskPath) in options.disks.enumerated() {
            backends.append(try VirtioBlk(path: diskPath, identity: "dory-blk\(slot)"))
        }
        var daxSlot: UInt64 = 0
        for share in options.shares {
            let daxBase = share.dax ? GuestLayout.daxWindowBase + daxSlot * DaxWindow.defaultSize : nil
            if share.dax { daxSlot += 1 }
            backends.append(try share.makeBackend(
                daxGuestBase: daxBase,
                requestQueueCount: min(8, max(1, options.cpus))
            ))
            FileHandle.standardError.write(Data("dory-hv: sharing \(share.path) as virtiofs tag \(share.tag)\(share.readOnly ? " (ro)" : "")\(share.dax ? " (dax)" : "")\n".utf8))
        }
        backends.append(VirtioRng())
        backends.append(VirtioBalloon(memory: machine.memory) { message in
            FileHandle.standardError.write(Data("dory-hv: \(message)\n".utf8))
        })
        backends.append(VirtioVsock(guestCID: 3))
        var gvproxyProcess: Process?
        if let gvproxyPath = options.gvproxy {
            let networkDirectory = NSHomeDirectory() + "/.dory/hv"
            try FileManager.default.createDirectory(atPath: networkDirectory, withIntermediateDirectories: true)
            let datapathSocket = networkDirectory + "/net.sock"
            let apiSocket = networkDirectory + "/gvproxy-api.sock"
            try? FileManager.default.removeItem(atPath: datapathSocket)
            try? FileManager.default.removeItem(atPath: apiSocket)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: gvproxyPath)
            process.arguments = [
                "-mtu", String(DoryNetworkMTU.resolved()),
                "-listen-vfkit", "unixgram://\(datapathSocket)",
                "-listen", "unix://\(apiSocket)",
            ]
            process.standardOutput = FileHandle.standardError
            process.standardError = FileHandle.standardError
            try process.run()
            gvproxyProcess = process
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: datapathSocket) { break }
                usleep(50_000)
            }
            let vmSocket = networkDirectory + "/vm-net.sock"
            backends.append(try VirtioNet(socketPath: vmSocket, remotePath: datapathSocket))
            FileHandle.standardError.write(Data("dory-hv: networking via gvproxy (\(datapathSocket))\n".utf8))

        }
        defer { gvproxyProcess?.terminate() }
        for (slot, backend) in backends.enumerated() {
            let spi = GuestLayout.virtioFirstIRQ + UInt32(slot)
            let transport = VirtioMMIOTransport(
                baseAddress: GuestLayout.virtioBase + UInt64(slot) * GuestLayout.virtioSlotSize,
                backend: backend,
                memory: machine.memory
            ) { [weak machine] in
                machine?.raiseGSI(spi)
            }
            machine.attachVirtioSlot(transport)
        }
        try machine.loadBootPayload()
        let stop = try machine.run()
        print("\ndory-hv: guest stopped: \(stop)")
    } catch {
        fail("\(error)")
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
    case "probe":
        // Claim a real host device and drive one GET_DESCRIPTOR control transfer through the exact
        // usbip submit path the guest would use — a host-side smoke test with no guest/VM required.
        let args = Array(arguments.dropFirst(2))
        guard let busID = args.first else { fail("usage: dory-hv usb probe <busid> [userAuthorized|seize|capture]") }
        let mode: HostUsbOpenMode
        switch args.dropFirst().first {
        case "seize": mode = .seize
        case "capture", nil: mode = .capture
        case "userAuthorized", "user": mode = .userAuthorized
        case let other?: fail("unknown mode \(other)")
        }
        do {
            FileHandle.standardError.write(Data("dory-hv: claiming \(busID) mode=\(mode)…\n".utf8))
            let device = try HostUsbDeviceFactory.open(busID: busID, mode: mode)
            let command = UsbipSubmitCommand(
                header: UsbipHeaderBasic(command: .cmdSubmit, sequenceNumber: 1, deviceID: 0, direction: .in, endpoint: 0),
                transferFlags: 0,
                transferBufferLength: 18,
                startFrame: 0,
                numberOfPackets: 0,
                interval: 0,
                setup: [0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x12, 0x00],  // GET_DESCRIPTOR(device, 18)
                transferBuffer: []
            )
            let reply = try device.submit(command)
            let bytes = reply.transferBuffer
            print("CLAIM OK. GET_DESCRIPTOR status=\(reply.status) actualLength=\(reply.actualLength) bytes=\(bytes.count)")
            if bytes.count >= 12 {
                let vid = UInt16(bytes[8]) | (UInt16(bytes[9]) << 8)
                let pid = UInt16(bytes[10]) | (UInt16(bytes[11]) << 8)
                print(String(format: "device descriptor: bLength=%d bDescriptorType=%d idVendor=0x%04x idProduct=0x%04x", bytes[0], bytes[1], vid, pid))
            }
        } catch {
            fail("usb probe failed: \(error)")
        }
    case "attach":
        let attachArgs = Array(arguments.dropFirst(2))
        guard let busID = attachArgs.first else { fail("usage: dory-hv usb attach <busid> [userAuthorized|seize|capture]") }
        let controlSocket = "\(NSHomeDirectory())/.dory/hv/usb-control.sock"
        do {
            let response = try UsbControlClient.send(UsbControlRequest(cmd: "attach", busid: busID, mode: attachArgs.dropFirst().first), socketPath: controlSocket)
            guard response.ok else { fail("usb attach failed: \(response.error ?? "unknown")") }
            print("attached \(busID) on vhci port \(response.port ?? -1)")
        } catch {
            fail("usb attach failed: \(error)")
        }
    case "detach":
        let detachArgs = Array(arguments.dropFirst(2))
        guard let busID = detachArgs.first else { fail("usage: dory-hv usb detach <busid>") }
        let controlSocket = "\(NSHomeDirectory())/.dory/hv/usb-control.sock"
        do {
            let response = try UsbControlClient.send(UsbControlRequest(cmd: "detach", busid: busID), socketPath: controlSocket)
            guard response.ok else { fail("usb detach failed: \(response.error ?? "unknown")") }
            print("detached \(busID)")
        } catch {
            fail("usb detach failed: \(error)")
        }
    default:
        fail("usage: dory-hv usb <list|probe|attach|detach>")
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
        amd64Emulation: amd64Emulation,
        publishHost: publishHost,
        agentVsockForward: agentVsockForward,
        sshAgentSocket: sshAgentSocket,
        guestAgentPath: guestAgent
    )
    // Top-level code is implicitly MainActor; a plain Task would inherit it and deadlock behind
    // the semaphore below. Detach so the engine runs on the concurrent pool.
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            try await EngineMode.run(configuration)
        } catch {
            FileHandle.standardError.write(Data("dory-hv: engine failed: \(error)\n".utf8))
            exit(1)
        }
        semaphore.signal()
    }
    semaphore.wait()
default:
    fail("unknown command \(command)")
}

private func parseGPUMode(_ value: String) -> EngineMode.GPUAccelerationMode {
    guard let mode = EngineMode.GPUAccelerationMode(rawValue: value) else {
        fail("unknown gpu mode \(value); expected off or venus")
    }
    return mode
}
