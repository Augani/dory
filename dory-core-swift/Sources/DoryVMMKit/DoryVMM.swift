import Darwin
import DoryCore
import DorydKit
import Foundation
@preconcurrency import Virtualization

public enum DoryVMMBootMode: Sendable, Equatable {
    case immediateHandoff
    case virtualMachine
}

public struct DoryVMMArguments: Sendable, Equatable {
    public var machineID: String?
    public var stateDirectory: String?
    public var kernelPath: String?
    public var rootfsPath: String?
    public var handoffSocketPath: String?
    public var dockerdSocketPath: String?
    public var agentSocketPath: String?
    public var shellSocketPath: String?
    public var controlSocketPath: String?
    public var agentBuild = "dory-vmm/handoff-shim"
    public var detail = "helper handoff ready"
    public var memoryMB: UInt64 = 2048
    public var cpuCount: Int = 2
    public var kernelCommandLine: String?
    public var readyTimeoutSeconds: TimeInterval = 60
    public var exitAfterHandoff = false
    public var handoffOnly = false
    public var holdSeconds: UInt32?
    public var shares: [DoryMachineShareConfiguration] = []
    public var environment: [String: String] = [:]

    public init() {}

    public var bootMode: DoryVMMBootMode {
        if handoffOnly || exitAfterHandoff || holdSeconds != nil {
            return .immediateHandoff
        }
        return .virtualMachine
    }
}

public enum DoryVMMArgumentError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingValue(String)
    case invalidInteger(String, String)
    case missingMachineID
    case missingHandoffSocket
    case missingStateDirectory
    case missingKernel
    case missingRootfs
    case invalidEnvironment(String)

    public var description: String {
        switch self {
        case let .missingValue(flag):
            return "missing value for \(flag)"
        case let .invalidInteger(flag, value):
            return "invalid integer for \(flag): \(value)"
        case .missingMachineID:
            return "missing --machine-id"
        case .missingHandoffSocket:
            return "missing --handoff-sock"
        case .missingStateDirectory:
            return "missing --state-dir"
        case .missingKernel:
            return "missing --kernel"
        case .missingRootfs:
            return "missing --rootfs"
        case let .invalidEnvironment(value):
            return "invalid --env value: \(value)"
        }
    }
}

public func parseDoryVMMArguments(_ raw: [String]) throws -> DoryVMMArguments {
    var parsed = DoryVMMArguments()
    var index = raw.startIndex
    while index < raw.endIndex {
        let argument = raw[index]
        index = raw.index(after: index)
        switch argument {
        case "--machine-id":
            parsed.machineID = try value(after: argument, from: raw, index: &index)
        case "--state-dir":
            parsed.stateDirectory = try value(after: argument, from: raw, index: &index)
        case "--kernel":
            parsed.kernelPath = try value(after: argument, from: raw, index: &index)
        case "--rootfs":
            parsed.rootfsPath = try value(after: argument, from: raw, index: &index)
        case "--memory-mb":
            parsed.memoryMB = try uint64Value(after: argument, from: raw, index: &index)
        case "--cpus":
            parsed.cpuCount = max(1, Int(try uint64Value(after: argument, from: raw, index: &index)))
        case "--cmdline":
            parsed.kernelCommandLine = try value(after: argument, from: raw, index: &index)
        case "--handoff-sock":
            parsed.handoffSocketPath = try value(after: argument, from: raw, index: &index)
        case "--dockerd-sock":
            parsed.dockerdSocketPath = try value(after: argument, from: raw, index: &index)
        case "--agent-sock":
            parsed.agentSocketPath = try value(after: argument, from: raw, index: &index)
        case "--shell-sock":
            parsed.shellSocketPath = try value(after: argument, from: raw, index: &index)
        case "--control-sock":
            parsed.controlSocketPath = try value(after: argument, from: raw, index: &index)
        case "--agent-build":
            parsed.agentBuild = try value(after: argument, from: raw, index: &index)
        case "--detail":
            parsed.detail = try value(after: argument, from: raw, index: &index)
        case "--ready-timeout-seconds":
            parsed.readyTimeoutSeconds = TimeInterval(try uint64Value(after: argument, from: raw, index: &index))
        case "--hold-seconds":
            parsed.holdSeconds = UInt32(try uint64Value(after: argument, from: raw, index: &index))
        case "--share":
            parsed.shares.append(try DoryMachineShareConfiguration(argument: value(after: argument, from: raw, index: &index)))
        case "--env":
            let rawValue = try value(after: argument, from: raw, index: &index)
            guard let equals = rawValue.firstIndex(of: "="), equals != rawValue.startIndex else {
                throw DoryVMMArgumentError.invalidEnvironment(rawValue)
            }
            let key = String(rawValue[..<equals])
            guard key.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil else {
                throw DoryVMMArgumentError.invalidEnvironment(key)
            }
            parsed.environment[key] = String(rawValue[rawValue.index(after: equals)...])
        case "--exit-after-handoff":
            parsed.exitAfterHandoff = true
        case "--handoff-only":
            parsed.handoffOnly = true
        default:
            break
        }
    }
    return parsed
}

private func value(after flag: String, from raw: [String], index: inout Array<String>.Index) throws -> String {
    guard index < raw.endIndex else {
        throw DoryVMMArgumentError.missingValue(flag)
    }
    let value = raw[index]
    index = raw.index(after: index)
    return value
}

private func uint64Value(after flag: String, from raw: [String], index: inout Array<String>.Index) throws -> UInt64 {
    let rawValue = try value(after: flag, from: raw, index: &index)
    guard let value = UInt64(rawValue) else {
        throw DoryVMMArgumentError.invalidInteger(flag, rawValue)
    }
    return value
}

public struct DoryVZMachineSpec: Sendable, Equatable {
    public var machineID: String
    public var stateDirectory: String
    public var kernelPath: String
    public var rootfsPath: String
    public var memoryMB: UInt64
    public var cpuCount: Int
    public var kernelCommandLine: String?
    public var shares: [DoryMachineShareConfiguration]
    public var environment: [String: String]

    public init(
        machineID: String,
        stateDirectory: String,
        kernelPath: String,
        rootfsPath: String,
        memoryMB: UInt64,
        cpuCount: Int,
        kernelCommandLine: String? = nil,
        shares: [DoryMachineShareConfiguration] = [],
        environment: [String: String] = [:]
    ) {
        self.machineID = machineID
        self.stateDirectory = stateDirectory
        self.kernelPath = kernelPath
        self.rootfsPath = rootfsPath
        self.memoryMB = memoryMB
        self.cpuCount = max(1, cpuCount)
        self.kernelCommandLine = kernelCommandLine
        self.shares = shares
        self.environment = environment
    }
}

public enum DoryVZMachineError: Error, Sendable, CustomStringConvertible {
    case missingFile(String)
    case storageAttachment(String)
    case validation(String)
    case missingSocketDevice
    case missingMemoryBalloonDevice
    case guestPortUnavailable(UInt32)
    case syscall(String, Int32)

    public var description: String {
        switch self {
        case let .missingFile(path):
            return "required VM file is missing: \(path)"
        case let .storageAttachment(message):
            return "rootfs storage attachment failed: \(message)"
        case let .validation(message):
            return "VZ VM configuration is invalid: \(message)"
        case .missingSocketDevice:
            return "VZ VM did not expose a virtio socket device"
        case .missingMemoryBalloonDevice:
            return "VZ VM did not expose a memory balloon device"
        case let .guestPortUnavailable(port):
            return "guest vsock port did not become reachable: \(port)"
        case let .syscall(name, code):
            return "\(name): \(String(cString: strerror(code)))"
        }
    }
}

public enum DoryVZConfigurationBuilder {
    private static let bootConfigTag = "dorycfg"
    private static let bootConfigGuestPath = "/mnt/dory-config"

    public static func makeConfiguration(
        spec: DoryVZMachineSpec,
        serialOutput: FileHandle?
    ) throws -> VZVirtualMachineConfiguration {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: spec.kernelPath) else {
            throw DoryVZMachineError.missingFile(spec.kernelPath)
        }
        guard fileManager.fileExists(atPath: spec.rootfsPath) else {
            throw DoryVZMachineError.missingFile(spec.rootfsPath)
        }

        let bootLoader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: spec.kernelPath))
        bootLoader.commandLine = spec.kernelCommandLine ?? defaultKernelCommandLine(machineID: spec.machineID)

        let configuration = VZVirtualMachineConfiguration()
        configuration.bootLoader = bootLoader
        configuration.cpuCount = clampedCPUCount(spec.cpuCount)
        configuration.memorySize = clampedMemorySize(megabytes: spec.memoryMB)
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        configuration.networkDevices = [network]

        let bootConfigShare = try prepareBootConfigShare(spec: spec)
        let directoryShares = [bootConfigShare] + spec.shares
        configuration.directorySharingDevices = try directoryShares.map { share in
            try share.validate()
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: share.hostPath, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw DoryVZMachineError.missingFile(share.hostPath)
            }
            do {
                try VZVirtioFileSystemDeviceConfiguration.validateTag(share.tag)
            } catch {
                throw DoryVZMachineError.validation("\(error)")
            }
            let directory = VZSharedDirectory(
                url: URL(fileURLWithPath: share.hostPath, isDirectory: true),
                readOnly: share.readOnly
            )
            let shareConfig = VZSingleDirectoryShare(directory: directory)
            let device = VZVirtioFileSystemDeviceConfiguration(tag: share.tag)
            device.share = shareConfig
            return device
        }

        do {
            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: URL(fileURLWithPath: spec.rootfsPath),
                readOnly: false
            )
            let block = VZVirtioBlockDeviceConfiguration(attachment: attachment)
            block.blockDeviceIdentifier = "dory-rootfs"
            configuration.storageDevices = [block]
        } catch {
            throw DoryVZMachineError.storageAttachment("\(error)")
        }

        if let serialOutput {
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: nil,
                fileHandleForWriting: serialOutput
            )
            configuration.serialPorts = [serial]
        }

        return configuration
    }

    public static func defaultKernelCommandLine(machineID: String) -> String {
        "console=hvc0 root=/dev/vda rw rootwait panic=1 dory.machine_id=\(machineID)"
    }

    private static func prepareBootConfigShare(spec: DoryVZMachineSpec) throws -> DoryMachineShareConfiguration {
        guard !spec.shares.contains(where: { $0.tag == bootConfigTag }) else {
            throw DoryVZMachineError.validation("machine share tag '\(bootConfigTag)' is reserved")
        }
        let directory = "\(spec.stateDirectory)/\(bootConfigTag)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let script = guestBootScript(shares: spec.shares, environment: spec.environment)
        try script.write(
            to: URL(fileURLWithPath: "\(directory)/boot.sh"),
            atomically: true,
            encoding: .utf8
        )
        return DoryMachineShareConfiguration(
            tag: bootConfigTag,
            hostPath: directory,
            guestPath: bootConfigGuestPath,
            readOnly: true
        )
    }

    private static func guestBootScript(shares: [DoryMachineShareConfiguration], environment: [String: String]) -> String {
        var lines = [
            "#!/bin/sh",
            "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "",
            "mountpoint() {",
            "  grep -q \" $1 \" /proc/mounts 2>/dev/null",
            "}",
            "",
            "mkdir -p /proc /sys /dev /dev/pts /run /tmp /var/log /var/run /var/lib/docker",
            "mountpoint /proc || mount -t proc proc /proc 2>/dev/null || true",
            "mountpoint /sys || mount -t sysfs sys /sys 2>/dev/null || true",
            "mountpoint /dev || mount -t devtmpfs devtmpfs /dev 2>/dev/null || true",
            "mountpoint /dev/pts || mount -t devpts devpts /dev/pts 2>/dev/null || true",
            "mountpoint /run || mount -t tmpfs tmpfs /run 2>/dev/null || true",
            "mountpoint /tmp || mount -t tmpfs tmpfs /tmp 2>/dev/null || true",
            "mkdir -p /sys/fs/cgroup",
            "mountpoint /sys/fs/cgroup || mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null || true",
            "",
            ": > /var/log/dory-mounts.log",
        ]
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            guard key.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil else { continue }
            lines.append("export \(key)=\(shellQuote(value))")
        }
        if !environment.isEmpty {
            lines.append("")
        }
        for share in shares {
            let options = share.readOnly ? "ro" : "rw"
            lines.append("mkdir -p \(shellQuote(share.guestPath))")
            lines.append(
                "if mountpoint \(shellQuote(share.guestPath)); then " +
                "echo \(shellQuote("DORY: \(share.tag) already mounted at \(share.guestPath)")) >>/var/log/dory-mounts.log; " +
                "elif mount -t virtiofs -o \(shellQuote(options)) \(shellQuote(share.tag)) \(shellQuote(share.guestPath)) 2>>/var/log/dory-mounts.log; then " +
                "echo \(shellQuote("DORY: mounted \(share.tag) at \(share.guestPath)")) >>/var/log/dory-mounts.log; " +
                "else echo \(shellQuote("DORY: failed to mount \(share.tag) at \(share.guestPath)")) >>/var/log/dory-mounts.log; fi"
            )
        }
        lines += [
            "",
            "ip link set lo up 2>/dev/null || true",
            "if ip link show eth0 >/dev/null 2>&1; then",
            "  ip link set eth0 up 2>/dev/null || true",
            "  udhcpc -i eth0 -q -n -t 5 -T 1 >/dev/null 2>&1 || true",
            "fi",
            "",
            "if [ -b /dev/vdb ]; then",
            "  mount -t ext4 /dev/vdb /var/lib/docker 2>/dev/null || {",
            "    echo \"DORY: failed to mount /dev/vdb at /var/lib/docker\"",
            "  }",
            "fi",
            "",
            "if [ -x /usr/local/bin/dockerd ]; then",
            "  /usr/local/bin/dockerd \\",
            "    -H unix:///var/run/docker.sock \\",
            "    -H tcp://0.0.0.0:2375 \\",
            "    --tls=false >/var/log/dockerd.log 2>&1 &",
            "fi",
            "",
            "( while true; do",
            "    nc -l -p 2377 >/dev/null 2>&1",
            "    echo \"DORY: shutdown requested\"",
            "    sync",
            "    umount /var/lib/docker 2>/dev/null || true",
            "    sync",
            "    poweroff -f",
            "  done ) &",
            "",
            "if [ -x /usr/bin/dory-agent ]; then",
            "  exec /usr/bin/dory-agent >/var/log/dory-agent.log 2>&1",
            "fi",
            "",
            "if [ -x /usr/local/bin/docker-init ]; then",
            "  exec /usr/local/bin/docker-init -s -- sleep 2147483647",
            "fi",
            "",
            "while true; do sleep 2147483647; done",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func clampedMemorySize(megabytes: UInt64) -> UInt64 {
        let bytes = megabytes * 1024 * 1024
        return min(
            max(bytes, VZVirtualMachineConfiguration.minimumAllowedMemorySize),
            VZVirtualMachineConfiguration.maximumAllowedMemorySize
        )
    }

    private static func clampedCPUCount(_ count: Int) -> Int {
        let minCount = Int(VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        let maxCount = Int(VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        return min(max(count, minCount), maxCount)
    }
}

public enum DoryVMMMain {
    public static func run(_ rawArguments: [String] = Array(CommandLine.arguments.dropFirst())) -> Int32 {
        do {
            let arguments = try parseDoryVMMArguments(rawArguments)
            try run(arguments)
            return 0
        } catch {
            FileHandle.standardError.write(Data("dory-vmm: \(error)\n".utf8))
            return 2
        }
    }

    public static func run(_ arguments: DoryVMMArguments) throws {
        guard let machineID = arguments.machineID else {
            throw DoryVMMArgumentError.missingMachineID
        }
        guard let handoffSocketPath = arguments.handoffSocketPath else {
            throw DoryVMMArgumentError.missingHandoffSocket
        }

        var runtime: DoryVMMRuntime?
        switch arguments.bootMode {
        case .immediateHandoff:
            try sendHandoff(
                machineID: machineID,
                handoffSocketPath: handoffSocketPath,
                agentBuild: arguments.agentBuild,
                agentSocketPath: arguments.agentSocketPath,
                dockerdSocketPath: arguments.dockerdSocketPath,
                shellSocketPath: arguments.shellSocketPath,
                controlSocketPath: arguments.controlSocketPath,
                detail: arguments.detail
            )
        case .virtualMachine:
            guard let stateDirectory = arguments.stateDirectory else {
                throw DoryVMMArgumentError.missingStateDirectory
            }
            guard let kernelPath = arguments.kernelPath else {
                throw DoryVMMArgumentError.missingKernel
            }
            guard let rootfsPath = arguments.rootfsPath else {
                throw DoryVMMArgumentError.missingRootfs
            }
            runtime = try runVirtualMachine(
                machineID: machineID,
                stateDirectory: stateDirectory,
                kernelPath: kernelPath,
                rootfsPath: rootfsPath,
                handoffSocketPath: handoffSocketPath,
                memoryMB: arguments.memoryMB,
                cpuCount: arguments.cpuCount,
                kernelCommandLine: arguments.kernelCommandLine,
                readyTimeoutSeconds: arguments.readyTimeoutSeconds,
                shares: arguments.shares,
                environment: arguments.environment
            )
        }

        if arguments.exitAfterHandoff {
            return
        }
        if let holdSeconds = arguments.holdSeconds {
            _ = withExtendedLifetime(runtime) {
                sleep(holdSeconds)
            }
            return
        }
        withExtendedLifetime(runtime) {
            while true {
                pause()
            }
        }
    }

    private static func sendHandoff(
        machineID: String,
        handoffSocketPath: String,
        agentBuild: String?,
        agentSocketPath: String?,
        dockerdSocketPath: String?,
        shellSocketPath: String?,
        controlSocketPath: String?,
        detail: String?
    ) throws {
        try VmmHandoffClient.send(
            path: handoffSocketPath,
            ready: VmmReadyMessage(
                machineID: machineID,
                agentBuild: agentBuild,
                agentSocketPath: agentSocketPath,
                dockerdSocketPath: dockerdSocketPath,
                shellSocketPath: shellSocketPath,
                controlSocketPath: controlSocketPath,
                detail: detail
            )
        )
    }

    private static func runVirtualMachine(
        machineID: String,
        stateDirectory: String,
        kernelPath: String,
        rootfsPath: String,
        handoffSocketPath: String,
        memoryMB: UInt64,
        cpuCount: Int,
        kernelCommandLine: String?,
        readyTimeoutSeconds: TimeInterval,
        shares: [DoryMachineShareConfiguration],
        environment: [String: String]
    ) throws -> DoryVMMRuntime {
        try FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true)
        let serialLog = try openAppendLog("\(stateDirectory)/serial.log")
        let spec = DoryVZMachineSpec(
            machineID: machineID,
            stateDirectory: stateDirectory,
            kernelPath: kernelPath,
            rootfsPath: rootfsPath,
            memoryMB: memoryMB,
            cpuCount: cpuCount,
            kernelCommandLine: kernelCommandLine,
            shares: shares,
            environment: environment
        )
        let configuration = try DoryVZConfigurationBuilder.makeConfiguration(spec: spec, serialOutput: serialLog)
        try validate(configuration: configuration)
        let machine = DoryVZMachine(configuration: configuration, label: machineID)
        try machine.start()

        let dockerdSocketPath = "\(stateDirectory)/dockerd.sock"
        let agentSocketPath = "\(stateDirectory)/agent.sock"
        let shellSocketPath = "\(stateDirectory)/shell.sock"
        let controlSocketPath = "\(stateDirectory)/control.sock"
        let controlServer = try DoryVMMControlServer(machine: machine, localSocketPath: controlSocketPath)
        let dockerdProxy = try DoryVZPortUnixProxy(
            machine: machine,
            guestPort: DoryGuestPorts.docker,
            localSocketPath: dockerdSocketPath
        )
        let agentProxy = try DoryVZPortUnixProxy(
            machine: machine,
            guestPort: DoryGuestPorts.control,
            localSocketPath: agentSocketPath
        )
        let shellProxy = try DoryVZPortUnixProxy(
            machine: machine,
            guestPort: DoryGuestPorts.shell,
            localSocketPath: shellSocketPath
        )
        do {
            try controlServer.start()
            try dockerdProxy.start()
            try agentProxy.start()
            try shellProxy.start()
        } catch {
            controlServer.stop()
            dockerdProxy.stop()
            agentProxy.stop()
            shellProxy.stop()
            throw error
        }

        let agentConnection = try machine.waitForConnection(toPort: DoryGuestPorts.control, timeout: readyTimeoutSeconds)
        defer { agentConnection.close() }
        let agentInfo = try agentInfo(from: agentConnection)
        try sendHandoff(
            machineID: machineID,
            handoffSocketPath: handoffSocketPath,
            agentBuild: agentInfo.agentBuild,
            agentSocketPath: agentSocketPath,
            dockerdSocketPath: dockerdSocketPath,
            shellSocketPath: shellSocketPath,
            controlSocketPath: controlSocketPath,
            detail: "VZ VM running; dory-agent answered protocol \(agentInfo.protocolVersion)"
        )
        return DoryVMMRuntime(
            machine: machine,
            controlServer: controlServer,
            proxies: [dockerdProxy, agentProxy, shellProxy],
            serialLog: serialLog
        )
    }

    private static func agentInfo(from connection: VZVirtioSocketConnection) throws -> DoryAgentInfo {
        let fd = dup(connection.fileDescriptor)
        guard fd >= 0 else {
            throw DoryVZMachineError.syscall("dup", errno)
        }
        let control = try DoryCore.connectAgentControlOverFD(fd)
        defer { control.close() }
        return try control.info()
    }

    private static func openAppendLog(_ path: String) throws -> FileHandle {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else {
            throw DoryVZMachineError.syscall("open", errno)
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static func validate(configuration: VZVirtualMachineConfiguration) throws {
        do {
            try configuration.validate()
        } catch {
            throw DoryVZMachineError.validation("\(error)")
        }
    }
}

private enum DoryGuestPorts {
    static let control: UInt32 = 1024
    static let docker: UInt32 = 1026
    static let shell: UInt32 = 1027
}

private final class DoryVMMRuntime {
    let machine: DoryVZMachine
    let controlServer: DoryVMMControlServer
    let proxies: [DoryVZPortUnixProxy]
    let serialLog: FileHandle

    init(
        machine: DoryVZMachine,
        controlServer: DoryVMMControlServer,
        proxies: [DoryVZPortUnixProxy],
        serialLog: FileHandle
    ) {
        self.machine = machine
        self.controlServer = controlServer
        self.proxies = proxies
        self.serialLog = serialLog
    }
}

public final class DoryVZMachine: @unchecked Sendable {
    private let queue: DispatchQueue
    private let virtualMachine: VZVirtualMachine

    public init(configuration: VZVirtualMachineConfiguration, label: String) {
        self.queue = DispatchQueue(label: "dev.dory.dory-vmm.\(label)")
        self.virtualMachine = VZVirtualMachine(configuration: configuration, queue: queue)
    }

    public func start() throws {
        let box = BlockingResultBox<Void>()
        queue.async { [self] in
            self.virtualMachine.start { result in
                box.complete(result.map { _ in () })
            }
        }
        try box.wait()
    }

    public func waitForConnection(toPort port: UInt32, timeout: TimeInterval) throws -> VZVirtioSocketConnection {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            do {
                return try connect(toPort: port)
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        if let lastError {
            FileHandle.standardError.write(Data("dory-vmm: last vsock \(port) error: \(lastError)\n".utf8))
        }
        throw DoryVZMachineError.guestPortUnavailable(port)
    }

    public func connect(toPort port: UInt32) throws -> VZVirtioSocketConnection {
        let box = BlockingResultBox<VZVirtioSocketConnection>()
        queue.async { [self] in
            let socketDevice: VZVirtioSocketDevice
            do {
                socketDevice = try self.firstSocketDeviceOnQueue()
            } catch {
                box.complete(.failure(error))
                return
            }
            socketDevice.connect(toPort: port) { result in
                box.complete(result)
            }
        }
        return try box.wait()
    }

    public func setBalloonTarget(memoryMB: UInt64) throws -> UInt64 {
        let target = memoryMB.multipliedReportingOverflow(by: 1024 * 1024)
        guard !target.overflow else {
            throw DoryVZMachineError.validation("balloon target is too large: \(memoryMB) MiB")
        }
        let targetBytes = target.partialValue
        let box = BlockingResultBox<UInt64>()
        queue.async { [self] in
            guard let balloon = self.virtualMachine.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice else {
                box.complete(.failure(DoryVZMachineError.missingMemoryBalloonDevice))
                return
            }
            balloon.targetVirtualMachineMemorySize = targetBytes
            box.complete(.success(balloon.targetVirtualMachineMemorySize / 1024 / 1024))
        }
        return try box.wait()
    }

    private func firstSocketDeviceOnQueue() throws -> VZVirtioSocketDevice {
        guard let device = virtualMachine.socketDevices.first as? VZVirtioSocketDevice else {
            throw DoryVZMachineError.missingSocketDevice
        }
        return device
    }
}

private final class DoryVMMControlServer: @unchecked Sendable {
    private let machine: DoryVZMachine
    private let localSocketPath: String
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var running = false

    init(machine: DoryVZMachine, localSocketPath: String) throws {
        self.machine = machine
        self.localSocketPath = localSocketPath
        self.queue = DispatchQueue(label: "dev.dory.dory-vmm.control")
    }

    func start() throws {
        try FileManager.default.createDirectory(
            atPath: (localSocketPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        unlink(localSocketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DoryVZMachineError.syscall("socket", errno) }

        do {
            var address = try unixAddress(path: localSocketPath)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                    Darwin.bind(fd, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw DoryVZMachineError.syscall("bind", errno) }
            chmod(localSocketPath, 0o600)
            guard listen(fd, 32) == 0 else { throw DoryVZMachineError.syscall("listen", errno) }

            lock.lock()
            listenerFD = fd
            running = true
            lock.unlock()
            queue.async { [weak self] in
                self?.acceptLoop(listenerFD: fd)
            }
        } catch {
            close(fd)
            unlink(localSocketPath)
            throw error
        }
    }

    func stop() {
        lock.lock()
        let fd = listenerFD
        listenerFD = -1
        running = false
        lock.unlock()
        if fd >= 0 {
            close(fd)
        }
        unlink(localSocketPath)
    }

    private func acceptLoop(listenerFD: Int32) {
        while isRunning(listenerFD: listenerFD) {
            let client = accept(listenerFD, nil, nil)
            if client < 0 {
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    close(client)
                    return
                }
                self.handle(clientFD: client)
            }
        }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }
        let response: VmmControlResponse
        do {
            let request = try readRequest(from: clientFD)
            response = try handle(request: request)
        } catch {
            response = VmmControlResponse(ok: false, message: "\(error)")
        }
        do {
            try writeResponse(response, to: clientFD)
        } catch {
            FileHandle.standardError.write(Data("dory-vmm: control response failed: \(error)\n".utf8))
        }
    }

    private func handle(request: VmmControlRequest) throws -> VmmControlResponse {
        switch request.command {
        case "setBalloonTarget":
            guard let targetMB = request.targetMB, targetMB > 0 else {
                return VmmControlResponse(ok: false, message: "missing positive targetMB")
            }
            let appliedMB = try machine.setBalloonTarget(memoryMB: targetMB)
            return VmmControlResponse(ok: true, targetMB: appliedMB)
        default:
            return VmmControlResponse(ok: false, message: "unknown VMM control command: \(request.command)")
        }
    }

    private func isRunning(listenerFD: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && self.listenerFD == listenerFD
    }

    deinit {
        stop()
    }
}

private func readRequest(from fd: Int32) throws -> VmmControlRequest {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { raw in
            read(fd, raw.baseAddress, raw.count)
        }
        if count == 0 {
            break
        }
        if count < 0 {
            if errno == EINTR { continue }
            throw DoryVZMachineError.syscall("read", errno)
        }
        data.append(contentsOf: buffer.prefix(count))
        if data.count > 1024 * 1024 {
            throw VmmControlError.invalidJSON("request exceeded 1 MiB")
        }
    }
    guard !data.isEmpty else {
        throw VmmControlError.invalidJSON("empty request")
    }
    do {
        return try JSONDecoder().decode(VmmControlRequest.self, from: data)
    } catch {
        throw VmmControlError.invalidJSON("\(error)")
    }
}

private func writeResponse(_ response: VmmControlResponse, to fd: Int32) throws {
    let data = try JSONEncoder().encode(response)
    try data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < data.count {
            let written = write(fd, base.advanced(by: offset), data.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                throw DoryVZMachineError.syscall("write", errno)
            }
            offset += written
        }
    }
}

private final class BlockingResultBox<T>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<T, Error>?

    func complete(_ result: Result<T, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
        semaphore.signal()
    }

    func wait() throws -> T {
        semaphore.wait()
        lock.lock()
        let result = self.result
        lock.unlock()
        return try result!.get()
    }
}

public final class DoryVZPortUnixProxy: @unchecked Sendable {
    private let machine: DoryVZMachine
    private let guestPort: UInt32
    public let localSocketPath: String
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var running = false

    public init(machine: DoryVZMachine, guestPort: UInt32, localSocketPath: String) throws {
        self.machine = machine
        self.guestPort = guestPort
        self.localSocketPath = localSocketPath
        self.queue = DispatchQueue(label: "dev.dory.dory-vmm.proxy.\(guestPort)")
    }

    public func start() throws {
        try FileManager.default.createDirectory(
            atPath: (localSocketPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        unlink(localSocketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DoryVZMachineError.syscall("socket", errno) }

        do {
            var address = try unixAddress(path: localSocketPath)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                    Darwin.bind(fd, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw DoryVZMachineError.syscall("bind", errno) }
            chmod(localSocketPath, 0o600)
            guard listen(fd, 128) == 0 else { throw DoryVZMachineError.syscall("listen", errno) }

            lock.lock()
            listenerFD = fd
            running = true
            lock.unlock()
            queue.async { [weak self] in
                self?.acceptLoop(listenerFD: fd)
            }
        } catch {
            close(fd)
            unlink(localSocketPath)
            throw error
        }
    }

    public func stop() {
        lock.lock()
        let fd = listenerFD
        listenerFD = -1
        running = false
        lock.unlock()
        if fd >= 0 {
            close(fd)
        }
        unlink(localSocketPath)
    }

    private func acceptLoop(listenerFD: Int32) {
        while isRunning(listenerFD: listenerFD) {
            let client = accept(listenerFD, nil, nil)
            if client < 0 {
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [machine, guestPort] in
                do {
                    let guest = try machine.connect(toPort: guestPort)
                    DoryFDSplice(clientFD: client, guestConnection: guest).start()
                } catch {
                    FileHandle.standardError.write(Data("dory-vmm: proxy connect failed: \(error)\n".utf8))
                    close(client)
                }
            }
        }
    }

    private func isRunning(listenerFD: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && self.listenerFD == listenerFD
    }

    deinit {
        stop()
    }
}

private final class DoryFDSplice: @unchecked Sendable {
    private let clientFD: Int32
    private let guestConnection: VZVirtioSocketConnection
    private let group = DispatchGroup()

    init(clientFD: Int32, guestConnection: VZVirtioSocketConnection) {
        self.clientFD = clientFD
        self.guestConnection = guestConnection
    }

    func start() {
        let guestFD = guestConnection.fileDescriptor
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            pump(from: clientFD, to: guestFD)
            shutdown(guestFD, SHUT_WR)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            pump(from: guestFD, to: clientFD)
            shutdown(clientFD, SHUT_WR)
            group.leave()
        }
        group.notify(queue: .global(qos: .utility)) { [self] in
            close(clientFD)
            guestConnection.close()
        }
    }
}

private func pump(from source: Int32, to destination: Int32) {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let readCount = buffer.withUnsafeMutableBytes { raw in
            read(source, raw.baseAddress, raw.count)
        }
        if readCount == 0 {
            return
        }
        if readCount < 0 {
            if errno == EINTR {
                continue
            }
            return
        }
        var offset = 0
        while offset < readCount {
            let written = buffer.withUnsafeBytes { raw in
                write(destination, raw.baseAddress!.advanced(by: offset), readCount - offset)
            }
            if written < 0 {
                if errno == EINTR {
                    continue
                }
                return
            }
            offset += written
        }
    }
}

private func unixAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw VmmHandoffError.pathTooLong(path)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        bytes.withUnsafeBytes { source in
            destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: bytes.count)
        }
    }
    return address
}
