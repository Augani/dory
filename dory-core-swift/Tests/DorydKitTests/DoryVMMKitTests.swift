import Darwin
import DorydKit
import DoryVMMKit
import Virtualization
import XCTest

final class DoryVMMKitTests: XCTestCase {
    func testParsesDorydMachineArgumentsAsVirtualMachineMode() throws {
        let arguments = try parseDoryVMMArguments([
            "--machine-id", "dev",
            "--state-dir", "/tmp/dory-machine-dev",
            "--kernel", "/tmp/vmlinux",
            "--rootfs", "/tmp/rootfs.raw",
            "--memory-mb", "3072",
            "--cpus", "4",
            "--handoff-sock", "/tmp/handoff.sock",
            "--agent-sock", "/tmp/agent.sock",
            "--shell-sock", "/tmp/shell.sock",
            "--share", "src=/tmp/src:/workspace/src:ro",
        ])

        XCTAssertEqual(arguments.machineID, "dev")
        XCTAssertEqual(arguments.stateDirectory, "/tmp/dory-machine-dev")
        XCTAssertEqual(arguments.kernelPath, "/tmp/vmlinux")
        XCTAssertEqual(arguments.rootfsPath, "/tmp/rootfs.raw")
        XCTAssertEqual(arguments.memoryMB, 3072)
        XCTAssertEqual(arguments.cpuCount, 4)
        XCTAssertEqual(arguments.handoffSocketPath, "/tmp/handoff.sock")
        XCTAssertEqual(arguments.agentSocketPath, "/tmp/agent.sock")
        XCTAssertEqual(arguments.shellSocketPath, "/tmp/shell.sock")
        XCTAssertEqual(arguments.shares, [
            DoryMachineShareConfiguration(tag: "src", hostPath: "/tmp/src", guestPath: "/workspace/src", readOnly: true),
        ])
        XCTAssertEqual(arguments.bootMode, .virtualMachine)
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
                ]
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
        XCTAssertEqual(configuration.directorySharingDevices.count, 1)
        let shareDevice = try XCTUnwrap(configuration.directorySharingDevices.first as? VZVirtioFileSystemDeviceConfiguration)
        XCTAssertEqual(shareDevice.tag, "src")
        XCTAssertTrue(shareDevice.share is VZSingleDirectoryShare)
    }
}
