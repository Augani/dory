import AppKit
import Darwin
import DoryCore
import DorydKit
@testable import DoryVMMKit
import Virtualization
import XCTest

final class DoryVMMKitTests: XCTestCase {
    @MainActor
    func testClipboardRetriesInitialHostPushUntilDesktopSessionIsReady() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("host clipboard before guest login", forType: .string)
        let recorder = ClipboardWriteRecorder()
        let coordinator = DoryDesktopClipboardCoordinator(
            policy: .hostToGuest,
            execute: { argv, stdin, _, _ in
                if argv == ["/usr/bin/test", "-x", "/usr/lib/dory/clipboard"] {
                    return Self.execResult(exitCode: 0)
                }
                XCTAssertEqual(argv, [
                    "/usr/lib/dory/clipboard", "set", "text/plain;charset=utf-8",
                ])
                let attempt = recorder.record(stdin)
                return Self.execResult(exitCode: attempt == 1 ? 1 : 0)
            },
            sendShortcut: { _ in },
            pasteboard: pasteboard,
            startupRetryDelay: 0.01,
            startupRetryLimit: 3,
            log: { _ in }
        )

        coordinator.start()
        coordinator.markGuestReady()
        defer { coordinator.stop() }

        let deadline = ContinuousClock.now + .seconds(2)
        while recorder.attemptCount < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(recorder.attemptCount, 2)
        XCTAssertEqual(recorder.lastPayload, Data("host clipboard before guest login".utf8))
    }

    @MainActor
    func testClipboardPullsGuestValueWhenDesktopResignsFocus() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("original host value", forType: .string)
        let recorder = ClipboardWriteRecorder()
        let coordinator = DoryDesktopClipboardCoordinator(
            policy: .guestToHost,
            execute: { argv, _, _, _ in
                if argv == ["/usr/bin/test", "-x", "/usr/lib/dory/clipboard"] {
                    recorder.recordCapabilityProbe()
                    return Self.execResult(exitCode: 0)
                }
                if argv == ["/usr/lib/dory/clipboard", "get", "image/png"] {
                    return Self.execResult(exitCode: 1)
                }
                XCTAssertEqual(argv, [
                    "/usr/lib/dory/clipboard", "get", "text/plain;charset=utf-8",
                ])
                return DoryExecResult(
                    exitCode: 0,
                    stdout: Data("guest clipboard after copy".utf8),
                    stderr: Data(),
                    timedOut: false,
                    stdoutTruncated: false,
                    stderrTruncated: false
                )
            },
            sendShortcut: { _ in },
            pasteboard: pasteboard,
            startupRetryDelay: 0.01,
            startupRetryLimit: 1,
            log: { _ in }
        )

        coordinator.start()
        coordinator.markGuestReady()
        defer { coordinator.stop() }

        let readyDeadline = ContinuousClock.now + .seconds(2)
        while recorder.capabilityProbeCount == 0, ContinuousClock.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(20))
        NotificationCenter.default.post(
            name: NSApplication.didResignActiveNotification,
            object: NSApplication.shared
        )

        let pullDeadline = ContinuousClock.now + .seconds(2)
        while pasteboard.string(forType: .string) != "guest clipboard after copy",
              ContinuousClock.now < pullDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "guest clipboard after copy")
    }

    private static func execResult(exitCode: Int32) -> DoryExecResult {
        DoryExecResult(
            exitCode: exitCode,
            stdout: Data(),
            stderr: Data(),
            timedOut: false,
            stdoutTruncated: false,
            stderrTruncated: false
        )
    }

    func testDesktopWindowUsesTheResolvedBackingScale() {
        XCTAssertEqual(
            DoryVMMDesktopApplication.targetPixelSize(
                viewSize: CGSize(width: 1_280, height: 800),
                backingScaleFactor: 2
            ),
            CGSize(width: 2_560, height: 1_600)
        )
        XCTAssertEqual(
            DoryVMMDesktopApplication.targetPixelSize(
                viewSize: CGSize(width: 1_024, height: 768),
                backingScaleFactor: 1
            ),
            CGSize(width: 1_024, height: 768)
        )
    }

    func testGuestUIScalePersistenceKeepsTheValueOutOfShellSource() throws {
        let command = try XCTUnwrap(
            DoryVMMGuestDisplayScale.persistenceCommand(scaleFactor: 1)
        )
        XCTAssertEqual(command[0...1], ["/bin/sh", "-c"])
        XCTAssertEqual(command[3], "dory-guest-display-scale")
        XCTAssertEqual(command[4], "1")
        XCTAssertFalse(command[2].contains("guest-ui-scale 1"))
        XCTAssertTrue(command[2].contains("\"$1\""))
        XCTAssertNil(DoryVMMGuestDisplayScale.persistenceCommand(scaleFactor: 0))
        XCTAssertNil(DoryVMMGuestDisplayScale.persistenceCommand(scaleFactor: 3))
    }

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
            "--boot-mode", "efi",
            "--installer-iso", "/tmp/ubuntu.iso",
            "--gvproxy", "/tmp/gvproxy",
            "--ssh-agent-socket", "/private/tmp/com.apple.launchd.fixture/Listeners",
            "--publish-host", "0.0.0.0",
            "--container-subnet", "10.44.16.0/20",
            "--memory-mb", "3072",
            "--cpus", "4",
            "--display-mode", "desktop",
            "--handoff-sock", "/tmp/handoff.sock",
            "--dockerd-sock", "/tmp/dockerd.sock",
            "--agent-sock", "/tmp/agent.sock",
            "--shell-sock", "/tmp/shell.sock",
            "--control-sock", "/tmp/control.sock",
            "--restore-state", "/tmp/dory-machine-dev/saved-state-v1/state.bin",
            "--share", "src=/tmp/src:/workspace/src:ro",
            "--env", "APP_ENV=dev",
        ])

        XCTAssertEqual(arguments.machineID, "dev")
        XCTAssertEqual(arguments.stateDirectory, "/tmp/dory-machine-dev")
        XCTAssertEqual(arguments.dataDriveRoot, "/Volumes/Work/Dory.dorydrive")
        XCTAssertEqual(arguments.kernelPath, "/tmp/vmlinux")
        XCTAssertEqual(arguments.rootfsPath, "/tmp/rootfs.raw")
        XCTAssertEqual(arguments.machineBootMode, .efi)
        XCTAssertEqual(arguments.installerISOPath, "/tmp/ubuntu.iso")
        XCTAssertEqual(arguments.gvproxyPath, "/tmp/gvproxy")
        XCTAssertEqual(
            arguments.sshAgentSocketPath,
            "/private/tmp/com.apple.launchd.fixture/Listeners"
        )
        XCTAssertEqual(arguments.publishHost, "0.0.0.0")
        XCTAssertEqual(arguments.bridgeSubnetCIDR, "10.44.16.0/20")
        XCTAssertEqual(arguments.memoryMB, 3072)
        XCTAssertEqual(arguments.cpuCount, 4)
        XCTAssertEqual(arguments.displayMode, .desktop)
        XCTAssertEqual(arguments.handoffSocketPath, "/tmp/handoff.sock")
        XCTAssertEqual(arguments.dockerdSocketPath, "/tmp/dockerd.sock")
        XCTAssertEqual(arguments.agentSocketPath, "/tmp/agent.sock")
        XCTAssertEqual(arguments.shellSocketPath, "/tmp/shell.sock")
        XCTAssertEqual(arguments.controlSocketPath, "/tmp/control.sock")
        XCTAssertEqual(
            arguments.restoreStatePath,
            "/tmp/dory-machine-dev/saved-state-v1/state.bin"
        )
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

    func testParsesExactResolvedLaunchContract() throws {
        let devices = DoryVirtualMachineDeviceCapabilityRequest(
            audioOutput: true,
            keyboard: true,
            pointer: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encodedDevices = String(decoding: try encoder.encode(devices), as: UTF8.self)
        let arguments = try parseDoryVMMArguments([
            "--resolved-graphics", "host-accelerated-display",
            "--resolved-devices", encodedDevices,
        ])

        XCTAssertEqual(arguments.resolvedGraphics, .hostAcceleratedDisplay)
        XCTAssertEqual(arguments.resolvedDevices, devices)
        XCTAssertThrowsError(try parseDoryVMMArguments([
            "--resolved-graphics", "auto",
        ]))
        XCTAssertThrowsError(try parseDoryVMMArguments([
            "--resolved-devices", "{}",
        ]))
    }

    func testRejectsInvalidDisplayModeArgument() throws {
        XCTAssertThrowsError(try parseDoryVMMArguments([
            "--display-mode", "gui",
        ])) { error in
            XCTAssertEqual(error as? DoryVMMArgumentError, .invalidDisplayMode("gui"))
        }
    }

    func testVMMResourcesAreNeverSilentlyClamped() throws {
        let arguments = try parseDoryVMMArguments([
            "--memory-mb", "0",
            "--cpus", "0",
        ])
        XCTAssertEqual(arguments.memoryMB, 0)
        XCTAssertEqual(arguments.cpuCount, 0)
        XCTAssertThrowsError(try parseDoryVMMArguments([
            "--cpus", "18446744073709551615",
        ])) { error in
            XCTAssertEqual(
                error as? DoryVMMArgumentError,
                .invalidInteger("--cpus", "18446744073709551615")
            )
        }

        let spec = DoryVZMachineSpec(
            machineID: "dev",
            stateDirectory: "/tmp/dev",
            kernelPath: "/tmp/kernel",
            rootfsPath: "/tmp/rootfs",
            memoryMB: 2048,
            cpuCount: 0
        )
        XCTAssertEqual(spec.cpuCount, 0)
        XCTAssertThrowsError(try DoryVZConfigurationBuilder.makeConfiguration(
            spec: spec,
            serialOutput: nil
        )) { error in
            XCTAssertTrue("\(error)".contains("unsupported cpuCount: 0"))
        }

        XCTAssertThrowsError(try DoryVZConfigurationBuilder.makeConfiguration(
            spec: DoryVZMachineSpec(
                machineID: "dev",
                stateDirectory: "/tmp/dev",
                kernelPath: "/tmp/kernel",
                rootfsPath: "/tmp/rootfs",
                memoryMB: 0,
                cpuCount: 1
            ),
            serialOutput: nil
        )) { error in
            XCTAssertTrue("\(error)".contains("unsupported memoryMB: 0"))
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

    func testGVProxyPlanPinsResolvedGuestMACLease() {
        let plan = DoryVMMNativeIPv6Plan(
            hostOnly: false,
            guestMAC: "02:11:22:33:44:55"
        )
        XCTAssertTrue(plan.gvproxyYAML.contains("dhcpStaticLeases:"))
        XCTAssertTrue(plan.gvproxyYAML.contains("192.168.127.2: 02:11:22:33:44:55"))
    }

    func testHostOnlyGVProxyPlanDisablesExternalConnectivity() {
        let plan = DoryVMMNativeIPv6Plan(hostOnly: true)
        XCTAssertTrue(plan.gvproxyYAML.contains("connectivity: host-only"))
        XCTAssertTrue(plan.gvproxyYAML.contains("192.168.127.254\": \"127.0.0.1"))
        XCTAssertTrue(plan.gvproxyYAML.contains("\"fd7d:6f72:7900::1\": \"::1\""))
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
        XCTAssertEqual(configuration.cpuCount, 2)
        XCTAssertEqual(configuration.memorySize, 2048 * 1024 * 1024)
        let network = try XCTUnwrap(configuration.networkDevices.first as? VZVirtioNetworkDeviceConfiguration)
        XCTAssertTrue(network.attachment is VZNATNetworkDeviceAttachment)
        XCTAssertEqual(
            network.macAddress.string,
            DoryVZConfigurationBuilder.stableNetworkMACAddress(machineID: "dev")
        )
        XCTAssertEqual(configuration.memoryBalloonDevices.count, 1)
        XCTAssertTrue(configuration.memoryBalloonDevices.first is VZVirtioTraditionalMemoryBalloonDeviceConfiguration)
        XCTAssertEqual(configuration.entropyDevices.count, 1)
        XCTAssertTrue(configuration.entropyDevices.first is VZVirtioEntropyDeviceConfiguration)
        XCTAssertEqual(configuration.serialPorts.count, 1)
        XCTAssertTrue(configuration.serialPorts.first is VZVirtioConsoleDeviceSerialPortConfiguration)
        XCTAssertTrue(configuration.graphicsDevices.isEmpty)
        XCTAssertTrue(configuration.keyboards.isEmpty)
        XCTAssertTrue(configuration.pointingDevices.isEmpty)
        XCTAssertTrue(configuration.audioDevices.isEmpty)
        XCTAssertTrue(configuration.consoleDevices.isEmpty)
        XCTAssertEqual(configuration.directorySharingDevices.count, 2)
        let tags = configuration.directorySharingDevices.compactMap { ($0 as? VZVirtioFileSystemDeviceConfiguration)?.tag }
        XCTAssertTrue(tags.contains("dorycfg"))
        XCTAssertTrue(tags.contains("src"))
        let shareDevice = try XCTUnwrap(configuration.directorySharingDevices.compactMap { $0 as? VZVirtioFileSystemDeviceConfiguration }.first { $0.tag == "src" })
        XCTAssertEqual(shareDevice.tag, "src")
        XCTAssertTrue(shareDevice.share is VZSingleDirectoryShare)
        let bootScript = try String(contentsOfFile: "\(base)/dorycfg/boot.sh", encoding: .utf8)
        XCTAssertTrue(bootScript.contains("export APP_ENV='dev build'"))
        XCTAssertTrue(bootScript.contains("/usr/lib/dory/configure-machine"))
        XCTAssertTrue(bootScript.contains("mount -t virtiofs -o 'ro' 'src' '/workspace/src'"))
        XCTAssertTrue(bootScript.contains("kill -TERM $DORY_DOCKERD_PID"))
        XCTAssertTrue(bootScript.contains("umount /var/lib/docker"))
        XCTAssertTrue(bootScript.contains("blockdev --getsize64 /dev/vdb"))
        XCTAssertTrue(bootScript.contains("dumpe2fs -h /dev/vdb"))
        XCTAssertTrue(bootScript.contains("ext4 already spans its block device"))
        XCTAssertTrue(bootScript.contains("DORY_DATA_FS_BYTES + DORY_DATA_FS_BLOCK_SIZE"))
        XCTAssertTrue(bootScript.contains("e2fsck -f -p /dev/vdb"))
        XCTAssertTrue(bootScript.contains("resize2fs /dev/vdb"))
        XCTAssertTrue(bootScript.contains("mkfs.ext4 -F"))
        XCTAssertTrue(bootScript.contains("DORY_ALLOW_DATA_FORMAT=0"))
        XCTAssertTrue(bootScript.contains("MOUNT-FAILED-EXISTING-EXT4"))
        XCTAssertTrue(bootScript.contains("UNKNOWN-FILESYSTEM-REFUSING-FORMAT"))
        XCTAssertTrue(bootScript.contains("fstrim -v /var/lib/docker"))
        XCTAssertTrue(bootScript.contains("sleep \(GuestStorageReclaimCommand.defaultIntervalSeconds)"))
        XCTAssertTrue(bootScript.contains("mountpoint -q /var/lib/docker"))
        XCTAssertTrue(bootScript.contains("defaultKeepStorage"))
        XCTAssertTrue(bootScript.contains(GuestBuildCacheGCCommand.defaultKeepStorage))
        XCTAssertTrue(bootScript.contains("echo +memory >/sys/fs/cgroup/cgroup.subtree_control"))
        XCTAssertTrue(bootScript.contains("mkdir -p /sys/fs/cgroup/dory-dockerd"))
        XCTAssertTrue(bootScript.contains("echo $$ >/sys/fs/cgroup/dory-dockerd/cgroup.procs"))
        XCTAssertTrue(bootScript.contains("/proc/sys/vm/max_map_count"))
        XCTAssertTrue(bootScript.contains(String(GuestContainerCompatibilityCommand.maximumMapCount)))
        XCTAssertTrue(bootScript.contains("\"default-ulimits\""))
        XCTAssertTrue(bootScript.contains("\"Hard\":65536"))
        XCTAssertTrue(bootScript.contains("\"Soft\":65536"))
        XCTAssertTrue(bootScript.contains("exec /usr/bin/dory-agent"))
        try assertShellSyntax("\(base)/dorycfg/boot.sh")
    }

    func testResolvedDisconnectedVZConfigurationRetainsAStableDetachedNetworkDevice() throws {
        let base = "/tmp/dory-vmm-disconnected-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let kernel = "\(base)/vmlinux"
        let rootfs = "\(base)/rootfs.raw"
        FileManager.default.createFile(
            atPath: kernel,
            contents: Data([0x7f, 0x45, 0x4c, 0x46])
        )
        FileManager.default.createFile(atPath: rootfs, contents: nil)
        XCTAssertEqual(truncate(rootfs, 1024 * 1024), 0)

        let configuration = try DoryVZConfigurationBuilder.makeConfiguration(
            spec: DoryVZMachineSpec(
                machineID: "offline",
                stateDirectory: base,
                kernelPath: kernel,
                rootfsPath: rootfs,
                memoryMB: 2048,
                cpuCount: 2,
                resolvedDevices: .init(networkAttachment: .disconnected)
            ),
            serialOutput: nil
        )

        XCTAssertEqual(configuration.networkDevices.count, 1)
        let network = try XCTUnwrap(
            configuration.networkDevices.first as? VZVirtioNetworkDeviceConfiguration
        )
        XCTAssertNil(network.attachment)
        XCTAssertEqual(
            network.macAddress.string,
            DoryVZConfigurationBuilder.stableNetworkMACAddress(machineID: "offline")
        )
        XCTAssertNotEqual(
            network.macAddress.string,
            DoryVZConfigurationBuilder.stableNetworkMACAddress(machineID: "other")
        )
        XCTAssertEqual(configuration.socketDevices.count, 1)
        XCTAssertEqual(configuration.storageDevices.count, 1)
    }

    func testResolvedVZConfigurationUsesPlanOwnedNICIdentity() throws {
        let base = "/tmp/dory-vmm-nic-contract-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let kernel = "\(base)/vmlinux"
        let rootfs = "\(base)/rootfs.raw"
        XCTAssertTrue(FileManager.default.createFile(
            atPath: kernel,
            contents: Data([0x7f, 0x45, 0x4c, 0x46])
        ))
        XCTAssertTrue(FileManager.default.createFile(atPath: rootfs, contents: nil))
        XCTAssertEqual(truncate(rootfs, 1_024 * 1_024), 0)
        let interface = DoryVirtualMachineNetworkInterfaceCapabilityRequest(
            macAddress: "02:11:22:33:44:55",
            maximumTransmissionUnit: 1_280
        )

        let configuration = try DoryVZConfigurationBuilder.makeConfiguration(
            spec: DoryVZMachineSpec(
                machineID: "resolved-nic",
                stateDirectory: base,
                kernelPath: kernel,
                rootfsPath: rootfs,
                memoryMB: 2_048,
                cpuCount: 2,
                resolvedDevices: .init(
                    networkAttachment: .disconnected,
                    networkInterface: interface
                )
            ),
            serialOutput: nil
        )

        let network = try XCTUnwrap(
            configuration.networkDevices.first as? VZVirtioNetworkDeviceConfiguration
        )
        XCTAssertEqual(network.macAddress.string, interface.macAddress)
        XCTAssertNil(network.attachment)
    }

    func testHostOnlyVZConfigurationRequiresFileHandleDatapath() throws {
        let base = "/tmp/dory-vmm-host-only-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let kernel = "\(base)/vmlinux"
        let rootfs = "\(base)/rootfs.raw"
        XCTAssertTrue(FileManager.default.createFile(
            atPath: kernel,
            contents: Data([0x7f, 0x45, 0x4c, 0x46])
        ))
        XCTAssertTrue(FileManager.default.createFile(atPath: rootfs, contents: nil))
        XCTAssertEqual(truncate(rootfs, 1_024 * 1_024), 0)
        let spec = DoryVZMachineSpec(
            machineID: "host-only",
            stateDirectory: base,
            kernelPath: kernel,
            rootfsPath: rootfs,
            memoryMB: 2_048,
            cpuCount: 2,
            resolvedDevices: .init(networkAttachment: .isolated),
            nativeIPv6: true
        )

        XCTAssertThrowsError(try DoryVZConfigurationBuilder.makeConfiguration(
            spec: spec,
            serialOutput: nil,
            networkAttachment: VZNATNetworkDeviceAttachment()
        )) { error in
            XCTAssertTrue("\(error)".contains("restricted gvproxy attachment"))
        }

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
            spec: spec,
            serialOutput: nil,
            networkAttachment: attachment
        )
        let network = try XCTUnwrap(
            configuration.networkDevices.first as? VZVirtioNetworkDeviceConfiguration
        )
        XCTAssertTrue(network.attachment is VZFileHandleNetworkDeviceAttachment)
        XCTAssertEqual(network.macAddress.string, DoryVMMNativeIPv6Plan.guestMAC)
    }

    func testEFIProfileSeparatesInstallerAndInstalledFirmwareAndAttachesISOReadOnly() throws {
        let base = "/tmp/dory-vmm-efi-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let rootfs = "\(base)/rootfs.raw"
        let installer = "\(base)/ubuntu-arm64.iso"
        let installerSource = "\(base)/installer-source"
        try FileManager.default.createDirectory(atPath: installerSource, withIntermediateDirectories: true)
        try Data("installer".utf8).write(to: URL(fileURLWithPath: "\(installerSource)/README"))
        FileManager.default.createFile(atPath: rootfs, contents: nil)
        XCTAssertEqual(truncate(rootfs, 1024 * 1024), 0)
        let isoBuilder = Process()
        isoBuilder.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        isoBuilder.arguments = ["makehybrid", "-iso", "-joliet", "-o", installer, installerSource]
        isoBuilder.standardOutput = FileHandle.nullDevice
        isoBuilder.standardError = FileHandle.nullDevice
        try isoBuilder.run()
        isoBuilder.waitUntilExit()
        XCTAssertEqual(isoBuilder.terminationStatus, 0)

        let spec = DoryVZMachineSpec(
            machineID: "ubuntu",
            stateDirectory: base,
            kernelPath: "\(base)/unused-kernel-marker",
            rootfsPath: rootfs,
            bootMode: .efi,
            installerISOPath: installer,
            memoryMB: 4096,
            cpuCount: 4,
            displayMode: .desktop
        )
        let configuration = try DoryVZConfigurationBuilder.makeConfiguration(
            spec: spec,
            serialOutput: nil
        )
        XCTAssertTrue(configuration.bootLoader is VZEFIBootLoader)
        XCTAssertTrue(configuration.platform is VZGenericPlatformConfiguration)
        XCTAssertEqual(configuration.storageDevices.count, 2)
        XCTAssertTrue(configuration.storageDevices[0] is VZUSBMassStorageDeviceConfiguration)
        let rootDevice = try XCTUnwrap(
            configuration.storageDevices[1] as? VZNVMExpressControllerDeviceConfiguration
        )
        let rootAttachment = try XCTUnwrap(
            rootDevice.attachment as? VZDiskImageStorageDeviceAttachment
        )
        XCTAssertEqual(rootAttachment.cachingMode, .cached)
        XCTAssertEqual(rootAttachment.synchronizationMode, .fsync)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(base)/MachineIdentifier"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(base)/NVRAM.installer"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(base)/NVRAM"))

        let identifierBefore = try Data(contentsOf: URL(fileURLWithPath: "\(base)/MachineIdentifier"))
        _ = try DoryVZConfigurationBuilder.makeConfiguration(spec: spec, serialOutput: nil)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: "\(base)/MachineIdentifier")),
            identifierBefore
        )

        var installedSpec = spec
        installedSpec.installerISOPath = nil
        _ = try DoryVZConfigurationBuilder.makeConfiguration(spec: installedSpec, serialOutput: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(base)/NVRAM"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(base)/NVRAM.installer"))
    }

    func testDesktopProfileAddsDisplayInputAudioAndClipboardDevices() throws {
        let base = "/tmp/dory-vmm-desktop-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let kernel = "\(base)/vmlinux"
        let rootfs = "\(base)/rootfs.raw"
        let share = "\(base)/shared"
        try FileManager.default.createDirectory(atPath: share, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: kernel, contents: Data([0x7f, 0x45, 0x4c, 0x46]))
        FileManager.default.createFile(atPath: rootfs, contents: nil)
        XCTAssertEqual(truncate(rootfs, 1024 * 1024), 0)

        let configuration = try DoryVZConfigurationBuilder.makeConfiguration(
            spec: DoryVZMachineSpec(
                machineID: "desktop",
                stateDirectory: base,
                kernelPath: kernel,
                rootfsPath: rootfs,
                memoryMB: 4096,
                cpuCount: 4,
                displayMode: .desktop,
                shares: [DoryMachineShareConfiguration(
                    tag: "desktop-share",
                    hostPath: share,
                    guestPath: "/mnt/shared",
                    readOnly: true
                )]
            ),
            serialOutput: nil
        )

        let graphics = try XCTUnwrap(configuration.graphicsDevices.first as? VZVirtioGraphicsDeviceConfiguration)
        let scanout = try XCTUnwrap(graphics.scanouts.first)
        XCTAssertEqual(scanout.widthInPixels, 2_560)
        XCTAssertEqual(scanout.heightInPixels, 1_600)
        XCTAssertEqual(configuration.keyboards.count, 1)
        XCTAssertTrue(configuration.keyboards.first is VZUSBKeyboardConfiguration)
        XCTAssertEqual(configuration.pointingDevices.count, 1)
        XCTAssertTrue(configuration.pointingDevices.first is VZUSBScreenCoordinatePointingDeviceConfiguration)
        XCTAssertEqual(configuration.audioDevices.count, 2)
        let outputSound = try XCTUnwrap(configuration.audioDevices.first as? VZVirtioSoundDeviceConfiguration)
        XCTAssertEqual(outputSound.streams.count, 1)
        XCTAssertTrue(outputSound.streams.first is VZVirtioSoundDeviceOutputStreamConfiguration)
        let inputSound = try XCTUnwrap(configuration.audioDevices.last as? VZVirtioSoundDeviceConfiguration)
        XCTAssertEqual(inputSound.streams.count, 1)
        XCTAssertTrue(inputSound.streams.first is VZVirtioSoundDeviceInputStreamConfiguration)
        XCTAssertEqual(configuration.consoleDevices.count, 1)
        let console = try XCTUnwrap(configuration.consoleDevices.first as? VZVirtioConsoleDeviceConfiguration)
        let spicePort = try XCTUnwrap(console.ports[0])
        let spiceAttachment = try XCTUnwrap(spicePort.attachment as? VZSpiceAgentPortAttachment)
        XCTAssertTrue(spiceAttachment.sharesClipboard)

        let directionalConfiguration = try DoryVZConfigurationBuilder.makeConfiguration(
            spec: DoryVZMachineSpec(
                machineID: "desktop",
                stateDirectory: base,
                kernelPath: kernel,
                rootfsPath: rootfs,
                memoryMB: 4096,
                cpuCount: 4,
                displayMode: .desktop,
                environment: ["DORY_CLIPBOARD_POLICY": "host-to-guest"]
            ),
            serialOutput: nil
        )
        let directionalConsole = try XCTUnwrap(
            directionalConfiguration.consoleDevices.first as? VZVirtioConsoleDeviceConfiguration
        )
        let directionalPort = try XCTUnwrap(directionalConsole.ports[0])
        let directionalAttachment = try XCTUnwrap(
            directionalPort.attachment as? VZSpiceAgentPortAttachment
        )
        XCTAssertFalse(directionalAttachment.sharesClipboard)
        XCTAssertEqual(configuration.directorySharingDevices.count, 1)
        let desktopShare = try XCTUnwrap(
            configuration.directorySharingDevices.first as? VZVirtioFileSystemDeviceConfiguration
        )
        XCTAssertEqual(desktopShare.tag, "desktop-share")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(base)/dorycfg"))
    }

    func testResolvedVZContractControlsAttachedDesktopDevices() throws {
        let base = "/tmp/dory-vmm-resolved-devices-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let kernel = "\(base)/vmlinux"
        let rootfs = "\(base)/rootfs.raw"
        FileManager.default.createFile(
            atPath: kernel,
            contents: Data([0x7f, 0x45, 0x4c, 0x46])
        )
        FileManager.default.createFile(atPath: rootfs, contents: nil)
        XCTAssertEqual(truncate(rootfs, 1024 * 1024), 0)
        let devices = DoryVirtualMachineDeviceCapabilityRequest(
            display: DoryVirtualMachineDisplayCapabilityRequest(
                widthPixels: 1_920,
                heightPixels: 1_080
            ),
            audioInput: false,
            audioOutput: true,
            keyboard: true,
            pointer: false,
            directorySharing: false,
            clipboard: false,
            clockSynchronization: false,
            dynamicDisplay: true,
            gracefulShutdown: false
        )
        let configuration = try DoryVZConfigurationBuilder.makeConfiguration(
            spec: DoryVZMachineSpec(
                machineID: "resolved-desktop",
                stateDirectory: base,
                kernelPath: kernel,
                rootfsPath: rootfs,
                memoryMB: 4096,
                cpuCount: 4,
                displayMode: .desktop,
                resolvedGraphics: .hostAcceleratedDisplay,
                resolvedDevices: devices
            ),
            serialOutput: nil
        )

        XCTAssertEqual(configuration.graphicsDevices.count, 1)
        let graphics = try XCTUnwrap(
            configuration.graphicsDevices.first as? VZVirtioGraphicsDeviceConfiguration
        )
        let scanout = try XCTUnwrap(graphics.scanouts.first)
        XCTAssertEqual(scanout.widthInPixels, 1_920)
        XCTAssertEqual(scanout.heightInPixels, 1_080)
        XCTAssertEqual(configuration.keyboards.count, 1)
        XCTAssertTrue(configuration.pointingDevices.isEmpty)
        XCTAssertEqual(configuration.audioDevices.count, 1)
        XCTAssertTrue(configuration.consoleDevices.isEmpty)
        XCTAssertTrue(configuration.directorySharingDevices.isEmpty)

        XCTAssertThrowsError(try DoryVZConfigurationBuilder.makeConfiguration(
            spec: DoryVZMachineSpec(
                machineID: "resolved-desktop",
                stateDirectory: base,
                kernelPath: kernel,
                rootfsPath: rootfs,
                memoryMB: 4096,
                cpuCount: 4,
                displayMode: .desktop,
                resolvedGraphics: .hardwareAccelerated3D,
                resolvedDevices: devices
            ),
            serialOutput: nil
        ))
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
                sourcePreservingLAN: true,
                bridgeSubnetCIDR: "10.44.16.0/20"
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
        XCTAssertTrue(bootScript.contains("--bip=10.44.16.1/20"))
        XCTAssertTrue(bootScript.contains("--fixed-cidr=10.44.16.0/21"))
        for command in try SourcePreservingLANPlan.guestSetupCommands(
            bridgeSubnetCIDR: "10.44.16.0/20"
        ) {
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
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dataDisk)

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

    func testSerialConsoleLogsGuestOutputAndForwardsInputBidirectionally() throws {
        let base = "/tmp/dory-vmm-serial-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let logPath = "\(base)/serial.log"
        XCTAssertTrue(FileManager.default.createFile(atPath: logPath, contents: nil))
        let log = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
        defer { try? log.close() }
        let socketPath = "\(base)/console.sock"
        let console = try DoryVMMSerialConsole(socketPath: socketPath, log: log)
        defer { console.stop() }

        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { close(client) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
        }
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.connect(client, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connectResult, 0)

        let hostInput = Data("ubuntu\n".utf8)
        XCTAssertEqual(hostInput.withUnsafeBytes { bytes in
            Darwin.send(client, bytes.baseAddress, bytes.count, MSG_NOSIGNAL)
        }, hostInput.count)
        var inputPoll = pollfd(
            fd: console.guestInput.fileDescriptor,
            events: Int16(POLLIN),
            revents: 0
        )
        XCTAssertEqual(poll(&inputPoll, 1, 2_000), 1)
        var inputBuffer = [UInt8](repeating: 0, count: 64)
        let inputCount = Darwin.read(
            console.guestInput.fileDescriptor,
            &inputBuffer,
            inputBuffer.count
        )
        XCTAssertEqual(Data(inputBuffer.prefix(inputCount)), hostInput)

        let guestOutput = Data("ubuntu login: ".utf8)
        try console.guestOutput.write(contentsOf: guestOutput)
        var outputPoll = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&outputPoll, 1, 2_000), 1)
        var outputBuffer = [UInt8](repeating: 0, count: 64)
        let outputCount = Darwin.read(client, &outputBuffer, outputBuffer.count)
        XCTAssertEqual(Data(outputBuffer.prefix(outputCount)), guestOutput)

        Thread.sleep(forTimeInterval: 0.05)
        try log.synchronize()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: logPath)), guestOutput)
        let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
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

private final class ClipboardWriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    private var payload = Data()
    private var capabilityProbes = 0

    func record(_ value: Data) -> Int {
        lock.lock()
        defer { lock.unlock() }
        attempts += 1
        payload = value
        return attempts
    }

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    var lastPayload: Data {
        lock.lock()
        defer { lock.unlock() }
        return payload
    }

    func recordCapabilityProbe() {
        lock.lock()
        capabilityProbes += 1
        lock.unlock()
    }

    var capabilityProbeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return capabilityProbes
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
