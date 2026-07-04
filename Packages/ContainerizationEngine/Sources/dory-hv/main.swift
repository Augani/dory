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
        FileHandle.standardError.write(Data("dory-hv: gicd size 0x\(String(try Machine.gicDistributorSize(), radix: 16)), gicr region 0x\(String(try Machine.gicRedistributorRegionSize(), radix: 16))\n".utf8))
        let console = FileHandle.standardOutput
        machine.attachConsole(PL011(baseAddress: GuestLayout.uartBase) { byte in
            console.write(Data([byte]))
        })
        try machine.loadBootPayload()
        let stop = try machine.runBootCPU()
        print("\ndory-hv: guest stopped: \(stop)")
    } catch {
        fail("\(error)")
    }
default:
    fail("unknown command \(command)")
}
