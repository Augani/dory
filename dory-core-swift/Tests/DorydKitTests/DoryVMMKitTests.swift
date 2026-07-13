import Darwin
import DoryCore
import DorydKit
@testable import DoryVMMKit
import Virtualization
import XCTest

final class DoryVMMKitTests: XCTestCase {
    func testVZSSHAgentBridgeRejectsNonSocketSymlinkAndWrongOwner() throws {
        let root = "/tmp/dory-vz-ssh-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let socketPath = root + "/agent.sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { if listener >= 0 { close(listener) } }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: bytes.count)
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 4), 0)

        let client = try XCTUnwrap(DoryVZHostSSHAgentBridge.connectSameUserSocket(
            path: socketPath,
            expectedUID: getuid()
        ))
        XCTAssertEqual(fcntl(client, F_GETFL, 0) & O_NONBLOCK, 0)
        close(client)
        XCTAssertNil(DoryVZHostSSHAgentBridge.connectSameUserSocket(
            path: socketPath,
            expectedUID: getuid() &+ 1
        ))
        let symlink = root + "/symlink.sock"
        try FileManager.default.createSymbolicLink(
            atPath: symlink,
            withDestinationPath: socketPath
        )
        XCTAssertNil(DoryVZHostSSHAgentBridge.connectSameUserSocket(
            path: symlink,
            expectedUID: getuid()
        ))
    }

    func testParsesDorydMachineArgumentsAsVirtualMachineMode() throws {
        let arguments = try parseDoryVMMArguments([
            "--machine-id", "dev",
            "--state-dir", "/tmp/dory-machine-dev",
            "--data-drive", "/Volumes/Work/Dory.dorydrive",
            "--kernel", "/tmp/vmlinux",
            "--rootfs", "/tmp/rootfs.raw",
            "--gvproxy", "/tmp/gvproxy",
            "--ssh-agent-socket", "/private/tmp/com.apple.launchd.fixture/Listeners",
            "--publish-host", "0.0.0.0",
            "--memory-mb", "3072",
            "--cpus", "4",
            "--handoff-sock", "/tmp/handoff.sock",
            "--agent-sock", "/tmp/agent.sock",
            "--shell-sock", "/tmp/shell.sock",
            "--share", "src=/tmp/src:/workspace/src:ro",
            "--env", "APP_ENV=dev",
        ])

        XCTAssertEqual(arguments.machineID, "dev")
        XCTAssertEqual(arguments.stateDirectory, "/tmp/dory-machine-dev")
        XCTAssertEqual(arguments.dataDriveRoot, "/Volumes/Work/Dory.dorydrive")
        XCTAssertEqual(arguments.kernelPath, "/tmp/vmlinux")
        XCTAssertEqual(arguments.rootfsPath, "/tmp/rootfs.raw")
        XCTAssertEqual(arguments.gvproxyPath, "/tmp/gvproxy")
        XCTAssertEqual(
            arguments.sshAgentSocketPath,
            "/private/tmp/com.apple.launchd.fixture/Listeners"
        )
        XCTAssertEqual(arguments.publishHost, "0.0.0.0")
        XCTAssertEqual(arguments.memoryMB, 3072)
        XCTAssertEqual(arguments.cpuCount, 4)
        XCTAssertEqual(arguments.handoffSocketPath, "/tmp/handoff.sock")
        XCTAssertEqual(arguments.agentSocketPath, "/tmp/agent.sock")
        XCTAssertEqual(arguments.shellSocketPath, "/tmp/shell.sock")
        XCTAssertEqual(arguments.shares, [
            DoryMachineShareConfiguration(tag: "src", hostPath: "/tmp/src", guestPath: "/workspace/src", readOnly: true),
        ])
        XCTAssertEqual(arguments.environment, ["APP_ENV": "dev"])
        XCTAssertEqual(arguments.bootMode, .virtualMachine)
    }

    func testRejectsInvalidEnvironmentArgument() throws {
        XCTAssertThrowsError(try parseDoryVMMArguments([
            "--machine-id", "dev",
            "--handoff-sock", "/tmp/handoff.sock",
            "--env", "1BAD=value",
        ])) { error in
            XCTAssertEqual(error as? DoryVMMArgumentError, .invalidEnvironment("1BAD"))
        }
    }

    func testSonomaGVProxyPlanIsNativeIPv6AndDockerDualStack() {
        let plan = DoryVMMNativeIPv6Plan()
        XCTAssertTrue(plan.gvproxyYAML.contains("ipv6Subnet: fd7d:6f72:7900::/64"))
        XCTAssertTrue(plan.gvproxyYAML.contains("ipv6GatewayIP: fd7d:6f72:7900::1"))
        XCTAssertTrue(plan.gvproxyYAML.contains("\"fd7d:6f72:7900::1\": \"::1\""))
        XCTAssertEqual(plan.guestSetupCommands, [
            "ip -6 addr replace fd7d:6f72:7900::2/64 dev eth0",
            "ip -6 route replace default via fd7d:6f72:7900::1 dev eth0",
            "sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null",
        ])
        XCTAssertEqual(
            plan.dockerDaemonArguments,
            "--ipv6=true --fixed-cidr-v6=fd7d:6f72:7901::/64 --ip6tables=true"
        )
    }

    func testExitAfterHandoffKeepsContractShimMode() throws {
        let arguments = try parseDoryVMMArguments([
            "--machine-id", "dev",
            "--handoff-sock", "/tmp/handoff.sock",
            "--exit-after-handoff",
        ])

        XCTAssertEqual(arguments.bootMode, .immediateHandoff)
    }

    func testMissingKernelAndRootfsDoesNotImplicitlyEnterShimMode() throws {
        let arguments = try parseDoryVMMArguments([
            "--machine-id", "dev",
            "--state-dir", "/tmp/dory-machine-dev",
            "--handoff-sock", "/tmp/handoff.sock",
        ])

        XCTAssertEqual(arguments.bootMode, .virtualMachine)
        XCTAssertThrowsError(try DoryVMMMain.run(arguments)) { error in
            XCTAssertEqual(error as? DoryVMMArgumentError, .missingKernel)
        }
    }

    func testBuildsVZConfigurationWithRootfsVsockBalloonNetworkAndSerial() throws {
        let base = "/tmp/dory-vmm-config-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let kernel = "\(base)/vmlinux"
        let rootfs = "\(base)/rootfs.raw"
        let serial = "\(base)/serial.log"
        let share = "\(base)/share"
        try FileManager.default.createDirectory(atPath: share, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: kernel, contents: Data([0x7f, 0x45, 0x4c, 0x46]))
        FileManager.default.createFile(atPath: rootfs, contents: nil)
        XCTAssertEqual(truncate(rootfs, 1024 * 1024), 0)
        FileManager.default.createFile(atPath: serial, contents: nil)
        let serialHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: serial))
        defer { try? serialHandle.close() }

        let configuration = try DoryVZConfigurationBuilder.makeConfiguration(
            spec: DoryVZMachineSpec(
                machineID: "dev",
                stateDirectory: base,
                kernelPath: kernel,
                rootfsPath: rootfs,
                memoryMB: 2048,
                cpuCount: 2,
                shares: [
                    DoryMachineShareConfiguration(tag: "src", hostPath: share, guestPath: "/workspace/src", readOnly: true),
                ],
                environment: ["APP_ENV": "dev build"]
            ),
            serialOutput: serialHandle
        )

        let bootLoader = try XCTUnwrap(configuration.bootLoader as? VZLinuxBootLoader)
        XCTAssertEqual(bootLoader.kernelURL.path, kernel)
        XCTAssertTrue(bootLoader.commandLine.contains("root=/dev/vda"))
        XCTAssertTrue(bootLoader.commandLine.contains("dory.machine_id=dev"))
        XCTAssertEqual(configuration.storageDevices.count, 1)
        XCTAssertTrue(configuration.storageDevices.first is VZVirtioBlockDeviceConfiguration)
        XCTAssertEqual(configuration.socketDevices.count, 1)
        XCTAssertTrue(configuration.socketDevices.first is VZVirtioSocketDeviceConfiguration)
        XCTAssertEqual(configuration.networkDevices.count, 1)
        let network = try XCTUnwrap(configuration.networkDevices.first as? VZVirtioNetworkDeviceConfiguration)
        XCTAssertTrue(network.attachment is VZNATNetworkDeviceAttachment)
        XCTAssertEqual(configuration.memoryBalloonDevices.count, 1)
        XCTAssertTrue(configuration.memoryBalloonDevices.first is VZVirtioTraditionalMemoryBalloonDeviceConfiguration)
        XCTAssertEqual(configuration.entropyDevices.count, 1)
        XCTAssertTrue(configuration.entropyDevices.first is VZVirtioEntropyDeviceConfiguration)
        XCTAssertEqual(configuration.serialPorts.count, 1)
        XCTAssertTrue(configuration.serialPorts.first is VZVirtioConsoleDeviceSerialPortConfiguration)
        XCTAssertEqual(configuration.directorySharingDevices.count, 2)
        let tags = configuration.directorySharingDevices.compactMap { ($0 as? VZVirtioFileSystemDeviceConfiguration)?.tag }
        XCTAssertTrue(tags.contains("dorycfg"))
        XCTAssertTrue(tags.contains("src"))
        let shareDevice = try XCTUnwrap(configuration.directorySharingDevices.compactMap { $0 as? VZVirtioFileSystemDeviceConfiguration }.first { $0.tag == "src" })
        XCTAssertEqual(shareDevice.tag, "src")
        XCTAssertTrue(shareDevice.share is VZSingleDirectoryShare)
        let bootScript = try String(contentsOfFile: "\(base)/dorycfg/boot.sh", encoding: .utf8)
        XCTAssertTrue(bootScript.contains("export APP_ENV='dev build'"))
        XCTAssertTrue(bootScript.contains("mount -t virtiofs -o 'ro' 'src' '/workspace/src'"))
        XCTAssertTrue(bootScript.contains("kill -TERM $DORY_DOCKERD_PID"))
        XCTAssertTrue(bootScript.contains("umount /var/lib/docker"))
        XCTAssertTrue(bootScript.contains("blockdev --getsize64 /dev/vdb"))
        XCTAssertTrue(bootScript.contains("dumpe2fs -h /dev/vdb"))
        XCTAssertTrue(bootScript.contains("ext4 already spans its block device"))
        XCTAssertTrue(bootScript.contains("DORY_DATA_FS_BYTES + DORY_DATA_FS_BLOCK_SIZE"))
        XCTAssertTrue(bootScript.contains("e2fsck -p /dev/vdb"))
        XCTAssertTrue(bootScript.contains("resize2fs /dev/vdb"))
        XCTAssertTrue(bootScript.contains("mkfs.ext4 -F"))
        XCTAssertTrue(bootScript.contains("DORY_ALLOW_DATA_FORMAT=0"))
        XCTAssertTrue(bootScript.contains("MOUNT-FAILED-EXISTING-EXT4"))
        XCTAssertTrue(bootScript.contains("UNKNOWN-FILESYSTEM-REFUSING-FORMAT"))
        XCTAssertTrue(bootScript.contains("fstrim -v /var/lib/docker"))
        XCTAssertTrue(bootScript.contains("exec /usr/bin/dory-agent"))
        try assertShellSyntax("\(base)/dorycfg/boot.sh")
    }

    func testDockerVZConfigurationAttachesPersistentDataDisk() throws {
        let base = "/tmp/dory-vmm-docker-data-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let kernel = "\(base)/vmlinux"
        let rootfs = "\(base)/rootfs.raw"
        let driveDisk = "\(base)/Dory.dorydrive/engine/docker-data.ext4"
        FileManager.default.createFile(atPath: kernel, contents: Data([0x7f, 0x45, 0x4c, 0x46]))
        FileManager.default.createFile(atPath: rootfs, contents: nil)
        XCTAssertEqual(truncate(rootfs, 1024 * 1024), 0)

        let configuration = try DoryVZConfigurationBuilder.makeConfiguration(
            spec: DoryVZMachineSpec(
                machineID: "docker",
                stateDirectory: base,
                kernelPath: kernel,
                rootfsPath: rootfs,
                memoryMB: 2048,
                cpuCount: 2,
                dockerDataDiskPath: driveDisk
            ),
            serialOutput: nil
        )

        XCTAssertEqual(configuration.storageDevices.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: driveDisk))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(base)/docker-data.ext4"))
        let bootScript = try String(contentsOfFile: "\(base)/dorycfg/boot.sh", encoding: .utf8)
        XCTAssertTrue(bootScript.contains("DORY_ALLOW_DATA_FORMAT=1"))
        XCTAssertTrue(bootScript.contains("FORMAT-PROVEN-BLANK"))
        try assertShellSyntax("\(base)/dorycfg/boot.sh")
        let dataDevice = try XCTUnwrap(configuration.storageDevices.last as? VZVirtioBlockDeviceConfiguration)
        XCTAssertEqual(dataDevice.blockDeviceIdentifier, "dory-data")
    }

    func testVZFileHandleNetworkWritesNativeIPv6BootContract() throws {
        let base = "/tmp/dory-vmm-ipv6-config-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let kernel = "\(base)/vmlinux"
        let rootfs = "\(base)/rootfs.raw"
        FileManager.default.createFile(atPath: kernel, contents: Data([0x7f, 0x45, 0x4c, 0x46]))
        FileManager.default.createFile(atPath: rootfs, contents: nil)
        XCTAssertEqual(truncate(rootfs, 1024 * 1024), 0)

        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_DGRAM, 0, &descriptors), 0)
        let guestNetworkHandle = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        let peerHandle = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        defer {
            try? guestNetworkHandle.close()
            try? peerHandle.close()
        }
        let attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: guestNetworkHandle)
        let configuration = try DoryVZConfigurationBuilder.makeConfiguration(
            spec: DoryVZMachineSpec(
                machineID: "dev",
                stateDirectory: base,
                kernelPath: kernel,
                rootfsPath: rootfs,
                memoryMB: 2048,
                cpuCount: 2,
                nativeIPv6: true,
                sourcePreservingLAN: true
            ),
            serialOutput: nil,
            networkAttachment: attachment
        )

        let network = try XCTUnwrap(configuration.networkDevices.first as? VZVirtioNetworkDeviceConfiguration)
        XCTAssertTrue(network.attachment is VZFileHandleNetworkDeviceAttachment)
        XCTAssertEqual(network.macAddress.string, DoryVMMNativeIPv6Plan.guestMAC)
        let bootScript = try String(contentsOfFile: "\(base)/dorycfg/boot.sh", encoding: .utf8)
        XCTAssertTrue(bootScript.contains("ip -6 addr replace fd7d:6f72:7900::2/64 dev eth0"))
        XCTAssertTrue(bootScript.contains("ip -6 route replace default via fd7d:6f72:7900::1 dev eth0"))
        XCTAssertTrue(bootScript.contains("--fixed-cidr-v6=fd7d:6f72:7901::/64"))
        for command in SourcePreservingLANPlan.guestSetupCommands {
            XCTAssertTrue(bootScript.contains(command), "missing source-preserving LAN command: \(command)")
        }
        try assertShellSyntax("\(base)/dorycfg/boot.sh")
    }

    func testNativeIPv6ConfigurationRejectsNATFallback() throws {
        let base = "/tmp/dory-vmm-ipv6-reject-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let kernel = "\(base)/vmlinux"
        let rootfs = "\(base)/rootfs.raw"
        FileManager.default.createFile(atPath: kernel, contents: Data([0x7f, 0x45, 0x4c, 0x46]))
        FileManager.default.createFile(atPath: rootfs, contents: nil)
        XCTAssertEqual(truncate(rootfs, 1024 * 1024), 0)

        XCTAssertThrowsError(try DoryVZConfigurationBuilder.makeConfiguration(
            spec: DoryVZMachineSpec(
                machineID: "dev",
                stateDirectory: base,
                kernelPath: kernel,
                rootfsPath: rootfs,
                memoryMB: 2048,
                cpuCount: 2,
                nativeIPv6: true
            ),
            serialOutput: nil
        )) { error in
            XCTAssertTrue("\(error)".contains("file-handle network attachment"))
        }
    }

    func testExistingExt4DockerDiskNeverEnablesFormattingFallback() throws {
        let base = "/tmp/dory-vmm-existing-ext4-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let kernel = "\(base)/vmlinux"
        let rootfs = "\(base)/rootfs.raw"
        let dataDisk = "\(base)/docker-data.ext4"
        FileManager.default.createFile(atPath: kernel, contents: Data([0x7f, 0x45, 0x4c, 0x46]))
        FileManager.default.createFile(atPath: rootfs, contents: nil)
        XCTAssertEqual(truncate(rootfs, 1024 * 1024), 0)
        var ext4 = Data(repeating: 0, count: 4096)
        ext4[1024 + 0x04] = 1 // one 4096-byte block
        ext4[1024 + 0x18] = 2 // log2(4096 / 1024)
        ext4[1024 + 0x38] = 0x53
        ext4[1024 + 0x39] = 0xEF
        try ext4.write(to: URL(fileURLWithPath: dataDisk))

        _ = try DoryVZConfigurationBuilder.makeConfiguration(
            spec: DoryVZMachineSpec(
                machineID: "docker",
                stateDirectory: base,
                kernelPath: kernel,
                rootfsPath: rootfs,
                memoryMB: 2048,
                cpuCount: 2
            ),
            serialOutput: nil
        )

        let bootPath = "\(base)/dorycfg/boot.sh"
        let bootScript = try String(contentsOfFile: bootPath, encoding: .utf8)
        XCTAssertTrue(bootScript.contains("DORY_ALLOW_DATA_FORMAT=0"))
        XCTAssertTrue(bootScript.contains("MOUNT-FAILED-EXISTING-EXT4"))
        try assertShellSyntax(bootPath)
    }

    private func assertShellSyntax(
        _ path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, file: file, line: line)
    }

    func testRejectsReservedBootConfigShareTag() throws {
        let base = "/tmp/dory-vmm-reserved-share-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        let kernel = "\(base)/vmlinux"
        let rootfs = "\(base)/rootfs.raw"
        let share = "\(base)/share"
        try FileManager.default.createDirectory(atPath: share, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: kernel, contents: Data([0x7f, 0x45, 0x4c, 0x46]))
        FileManager.default.createFile(atPath: rootfs, contents: nil)
        XCTAssertEqual(truncate(rootfs, 1024 * 1024), 0)

        XCTAssertThrowsError(try DoryVZConfigurationBuilder.makeConfiguration(
            spec: DoryVZMachineSpec(
                machineID: "dev",
                stateDirectory: base,
                kernelPath: kernel,
                rootfsPath: rootfs,
                memoryMB: 2048,
                cpuCount: 2,
                shares: [
                    DoryMachineShareConfiguration(tag: "dorycfg", hostPath: share, guestPath: "/workspace/src"),
                ]
            ),
            serialOutput: nil
        )) { error in
            XCTAssertTrue("\(error)".contains("reserved"))
        }
    }

    func testDeferredVMMShutdownRequestIsDeliveredExactlyOnceAfterRuntimeAttach() {
        let watchdog = ShutdownWatchdogRecorder()
        let forcedExit = ForcedExitRecorder()
        let coordinator = DoryVMMShutdownCoordinator(
            watchdogSeconds: 25,
            scheduleWatchdog: { watchdog.schedule(delay: $0, action: $1) },
            forceExit: { forcedExit.record($0) }
        )
        let target = FakeVMMShutdownTarget()

        coordinator.request(reason: "SIGTERM before VM handoff")
        coordinator.attach(target)
        XCTAssertTrue(target.waitForRequest())
        coordinator.request(reason: "duplicate SIGINT")
        Thread.sleep(forTimeInterval: 0.02)

        XCTAssertEqual(target.requestCount, 1)
        XCTAssertEqual(watchdog.delays, [25])
        target.markStopped()
        watchdog.fireAll()
        XCTAssertEqual(forcedExit.codes, [])
    }

    func testVMMShutdownWatchdogForcesExitWhenGuestNeverStops() {
        let watchdog = ShutdownWatchdogRecorder()
        let forcedExit = ForcedExitRecorder()
        let coordinator = DoryVMMShutdownCoordinator(
            watchdogSeconds: 0.01,
            scheduleWatchdog: { watchdog.schedule(delay: $0, action: $1) },
            forceExit: { forcedExit.record($0) }
        )
        let target = FakeVMMShutdownTarget()

        coordinator.attach(target)
        coordinator.request(reason: "SIGTERM")
        XCTAssertTrue(target.waitForRequest())
        watchdog.fireAll()

        XCTAssertEqual(forcedExit.codes, [1])
    }
}

private final class FakeVMMShutdownTarget: DoryVMMGuestShutdownHandling, @unchecked Sendable {
    private let lock = NSLock()
    private let requested = DispatchSemaphore(value: 0)
    private var stopped = false
    private var requests = 0

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    func requestGuestShutdown() throws {
        lock.lock()
        requests += 1
        lock.unlock()
        requested.signal()
    }

    func waitForRequest() -> Bool {
        requested.wait(timeout: .now() + 1) == .success
    }

    func markStopped() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}

private final class ShutdownWatchdogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedDelays: [TimeInterval] = []
    private var actions: [@Sendable () -> Void] = []

    var delays: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return recordedDelays
    }

    func schedule(delay: TimeInterval, action: @escaping @Sendable () -> Void) {
        lock.lock()
        recordedDelays.append(delay)
        actions.append(action)
        lock.unlock()
    }

    func fireAll() {
        lock.lock()
        let pending = actions
        actions = []
        lock.unlock()
        pending.forEach { $0() }
    }
}

private final class ForcedExitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCodes: [Int32] = []

    var codes: [Int32] {
        lock.lock(); defer { lock.unlock() }
        return recordedCodes
    }

    func record(_ code: Int32) {
        lock.lock()
        recordedCodes.append(code)
        lock.unlock()
    }
}
