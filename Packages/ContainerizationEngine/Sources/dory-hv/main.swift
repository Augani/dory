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
        default: fail("unknown option \(argument)")
        }
    }
    return options
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("usage: dory-hv <smoke|boot> [--kernel path] [--mem-mb N] [--cpus N] [--cmdline s]")
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
default:
    fail("unknown command \(command)")
}
