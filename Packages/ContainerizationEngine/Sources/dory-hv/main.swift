import DoryHV
import Foundation

signal(SIGPIPE, SIG_IGN)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("dory-hv: \(message)\n".utf8))
    exit(1)
}

struct Options {
    var kernel: String?
    var memoryMB: UInt64 = 2048
    var cpus: Int = 1
    var commandLine = "console=ttyAMA0 earlycon=pl011,mmio32,0x0c000000 panic=0"
    var disks: [String] = []
    var gvproxy: String?
    var exposePort: UInt16 = 0
}

func parseOptions(_ arguments: ArraySlice<String>) -> Options {
    var options = Options()
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--kernel": options.kernel = iterator.next()
        case "--mem-mb": options.memoryMB = iterator.next().flatMap(UInt64.init) ?? options.memoryMB
        case "--cpus": options.cpus = iterator.next().flatMap(Int.init) ?? options.cpus
        case "--cmdline": options.commandLine = iterator.next() ?? options.commandLine
        case "--disk": if let disk = iterator.next() { options.disks.append(disk) }
        case "--gvproxy": options.gvproxy = iterator.next()
        case "--expose-docker": options.exposePort = iterator.next().flatMap(UInt16.init) ?? 0
        default: fail("unknown option \(argument)")
        }
    }
    return options
}

func exposeDockerPort(apiSocket: String, hostPort: UInt16) {
    // gvproxy's forwarder API: expose host 127.0.0.1:hostPort -> guest dockerd tcp 2375.
    let body = "{\"local\":\"127.0.0.1:\(hostPort)\",\"remote\":\"192.168.127.2:2375\"}"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    task.arguments = [
        "-s", "--unix-socket", apiSocket,
        "-X", "POST", "-d", body,
        "http://gvproxy/services/forwarder/expose",
    ]
    task.standardOutput = FileHandle.standardError
    task.standardError = FileHandle.standardError
    try? task.run()
    task.waitUntilExit()
    FileHandle.standardError.write(Data("dory-hv: docker api exposed on 127.0.0.1:\(hostPort)\n".utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("usage: dory-hv <smoke|boot|engine> [--kernel path] [--mem-mb N] [--cpus N] [--cmdline s]")
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
        machine.attachConsole(PL011(baseAddress: GuestLayout.uartBase) { byte in
            console.write(Data([byte]))
        })
        machine.bus.attach(PL031(baseAddress: GuestLayout.rtcBase))
        var backends: [VirtioDeviceBackend] = []
        for (slot, diskPath) in options.disks.enumerated() {
            backends.append(try VirtioBlk(path: diskPath, identity: "dory-blk\(slot)"))
        }
        backends.append(VirtioRng())
        backends.append(VirtioBalloon(memory: machine.memory) { message in
            FileHandle.standardError.write(Data("dory-hv: \(message)\n".utf8))
        })
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
                "-mtu", "1500",
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

            if options.exposePort > 0 {
                let port = options.exposePort
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    exposeDockerPort(apiSocket: apiSocket, hostPort: port)
                }
            }
        }
        defer { gvproxyProcess?.terminate() }
        for (slot, backend) in backends.enumerated() {
            let spi = GuestLayout.virtioFirstIRQ + UInt32(slot)
            let transport = VirtioMMIOTransport(
                baseAddress: GuestLayout.virtioBase + UInt64(slot) * GuestLayout.virtioSlotSize,
                backend: backend,
                memory: machine.memory
            ) { [weak machine] in
                machine?.raiseSPI(spi)
            }
            machine.attachVirtioSlot(transport)
        }
        try machine.loadBootPayload()
        let stop = try machine.runBootCPU()
        print("\ndory-hv: guest stopped: \(stop)")
    } catch {
        fail("\(error)")
    }
case "engine":
    var engineSocket = "\(NSHomeDirectory())/.dory/engine.sock"
    var kernel: String?
    var gvproxy: String?
    var memoryMB: UInt64 = 2048
    var cpus = 4
    var iterator = arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--engine-sock": engineSocket = iterator.next() ?? engineSocket
        case "--kernel": kernel = iterator.next()
        case "--gvproxy": gvproxy = iterator.next()
        case "--mem-mb": memoryMB = iterator.next().flatMap(UInt64.init) ?? memoryMB
        case "--cpus": cpus = iterator.next().flatMap(Int.init) ?? cpus
        default: fail("unknown option \(argument)")
        }
    }
    guard let kernel else { fail("engine requires --kernel") }
    guard let gvproxy else { fail("engine requires --gvproxy") }
    EngineMode.installSignalTeardown()
    let configuration = EngineMode.Configuration(
        engineSocket: engineSocket,
        kernelPath: kernel,
        gvproxyPath: gvproxy,
        memoryMB: memoryMB,
        cpus: cpus,
        stateDirectory: "\(NSHomeDirectory())/.dory/hv"
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
