import Darwin
import DoryOperations
import DoryVMContracts
import Foundation
@testable import DorydKit
import XCTest

final class RuntimeDiskAuthorityIntegrationTests: XCTestCase {
    private typealias DiskFixture = (
        root: String,
        directory: String,
        path: String,
        contents: Data,
        lease: DoryMachineDirectoryLease
    )

    func testPathReplacementAfterAdmissionStillLaunchesPinnedInode() throws {
        let fixture = try makeDiskFixture(contents: Data("daemon-authorized-inode".utf8))
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let admitted = try admitDisk(fixture)

        let pinnedPath = fixture.directory + "/admitted-inode"
        try FileManager.default.moveItem(atPath: fixture.path, toPath: pinnedPath)
        let replacement = paddedDisk(contents: Data("pathname-replacement".utf8))
        try writePrivateFile(replacement, path: fixture.path)

        let output = fixture.directory + "/child-read"
        let terminated = expectation(description: "descriptor-backed child exits")
        let launch = try makeLaunchAuthority(capacityBytes: UInt64(fixture.contents.count))
        let process = HvProcess(
            configuration: HvProcessConfiguration(
                executablePath: "/bin/sh",
                arguments: [
                    "-c",
                    "dd if=/dev/fd/3 of=\"$1\" bs=4096 count=1 2>/dev/null",
                    "dory-authority-test",
                    output,
                ],
                runtimeLaunchEnvelope: launch.envelope,
                inheritedFileDescriptors: [admitted.authority, launch.kernel]
            ),
            unexpectedTerminationHandler: { _ in terminated.fulfill() }
        )
        try process.start()
        wait(for: [terminated], timeout: 2)

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: output)), fixture.contents)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.path)), replacement)
    }

    func testAdmittedDescriptorSurvivesOneBoundedStartupRestart() throws {
        let fixture = try makeDiskFixture(contents: Data("restart-pinned-authority".utf8))
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let admitted = try admitDisk(fixture)
        let marker = fixture.directory + "/runs"
        let capturePrefix = fixture.directory + "/capture"
        let script = fixture.directory + "/restart-reader.sh"
        try """
        #!/bin/sh
        printf 'run\n' >> "$1"
        run=$(wc -l < "$1" | tr -d ' ')
        /usr/bin/perl -e 'open(my $in, "<&=3") or die; seek($in, 0, 0) or die; open(my $out, ">", $ARGV[0]) or die; while (read($in, my $buffer, 4096)) { print $out $buffer; }' "$2.$run"
        test "$run" -ne 1 || exit 7
        exit 0
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script)

        let launch = try makeLaunchAuthority(capacityBytes: UInt64(fixture.contents.count))
        let process = HvProcess(configuration: HvProcessConfiguration(
            executablePath: script,
            arguments: [marker, capturePrefix],
            restartPolicy: HvRestartPolicy(maxRestarts: 1, delaySeconds: 0.01),
            runtimeLaunchEnvelope: launch.envelope,
            inheritedFileDescriptors: [admitted.authority, launch.kernel]
        ))
        try process.start()

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let runs = (try? String(contentsOfFile: marker, encoding: .utf8))?
                .split(separator: "\n").count ?? 0
            if runs == 2, !process.isRunningOrRestarting { break }
            Thread.sleep(forTimeInterval: 0.01)
        }

        XCTAssertEqual(
            try String(contentsOfFile: marker, encoding: .utf8).split(separator: "\n").count,
            2
        )
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: capturePrefix + ".1")), fixture.contents)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: capturePrefix + ".2")), fixture.contents)
        XCTAssertFalse(process.isRunningOrRestarting)
    }

    func testFinalAdmissionRejectsCapacityMismatch() throws {
        let fixture = try makeDiskFixture(contents: Data("capacity".utf8))
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }

        XCTAssertThrowsError(try fixture.lease.withBorrowedDescriptor { descriptor in
            try MachineManager.admitResolvedRawHVSystemDisk(
                machineDirectoryDescriptor: descriptor,
                machineDirectoryGeneration: fixture.lease.generation,
                expectedCapacityBytes: UInt64(fixture.contents.count + 512)
            )
        }) { error in
            XCTAssertTrue("\(error)".contains("capacity validation"), "\(error)")
        }
    }

    func testFixedSystemDiskLeafRejectsSymlinkAndWrongMode() throws {
        let fixture = try makeDiskFixture(contents: Data("unsafe-leaf".utf8))
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let target = fixture.directory + "/target-disk"
        try writePrivateFile(fixture.contents, path: target)
        try FileManager.default.removeItem(atPath: fixture.path)
        XCTAssertEqual(symlink(target, fixture.path), 0)

        XCTAssertThrowsError(try admitDisk(fixture)) { error in
            XCTAssertTrue("\(error)".contains("could not open managed system disk"))
        }

        try FileManager.default.removeItem(atPath: fixture.path)
        try writePrivateFile(fixture.contents, path: fixture.path)
        XCTAssertEqual(chmod(fixture.path, 0o644), 0)
        XCTAssertThrowsError(try admitDisk(fixture)) { error in
            XCTAssertTrue("\(error)".contains("owner/link/mode/capacity"))
        }
    }

    func testExclusiveLeaseRejectsSecondAdmissionUntilAuthorityCloses() throws {
        let fixture = try makeDiskFixture(contents: Data("exclusive-lease".utf8))
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let first = try admitDisk(fixture)

        XCTAssertThrowsError(try admitDisk(fixture)) { error in
            XCTAssertTrue("\(error)".contains("already leased"), "\(error)")
        }

        first.authority.close()
        let next = try admitDisk(fixture)
        next.authority.close()
    }

    func testResolvedLaunchGetsEOFStdinAndTerminalExitReleasesLease() throws {
        let fixture = try makeDiskFixture(contents: Data("stdin-and-terminal-close".utf8))
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let admitted = try admitDisk(fixture)
        let terminated = expectation(description: "resolved child gets EOF and exits")
        let captured = LockedRuntimeTermination()
        let launch = try makeLaunchAuthority(capacityBytes: UInt64(fixture.contents.count))
        let process = HvProcess(
            configuration: HvProcessConfiguration(
                executablePath: "/bin/sh",
                arguments: ["-c", "if IFS= read -r ignored; then exit 9; else exit 0; fi"],
                runtimeLaunchEnvelope: launch.envelope,
                inheritedFileDescriptors: [admitted.authority, launch.kernel]
            ),
            unexpectedTerminationHandler: { termination in
                captured.set(termination)
                terminated.fulfill()
            }
        )
        try process.start()
        wait(for: [terminated], timeout: 2)
        XCTAssertEqual(captured.value?.status, 0)

        let deadline = Date().addingTimeInterval(2)
        var next: RawHVAdmittedSystemDisk?
        while Date() < deadline, next == nil {
            next = try? admitDisk(fixture)
            if next == nil { Thread.sleep(forTimeInterval: 0.01) }
        }
        XCTAssertNotNil(next, "terminal launch must release the daemon-owned disk lease")
        next?.authority.close()
    }

    private func makeLaunchAuthority(
        capacityBytes: UInt64
    ) throws -> (envelope: RuntimeLaunchEnvelope, kernel: HvProcessInheritedFileDescriptor) {
        let topology = makeTopology()
        let kernelDescriptor = open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard kernelDescriptor >= 0 else { throw POSIXError(.EIO) }
        let kernel = HvProcessInheritedFileDescriptor(
            name: RuntimeLaunchEnvelope.linuxKernelSlotName,
            takingOwnershipOf: kernelDescriptor,
            childDescriptor: RuntimeLaunchEnvelope.linuxKernelDescriptor
        )
        let envelope = RuntimeLaunchEnvelope.resolvedRawHV(
            machineID: "authority-test",
            operationID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            resolvedPlanSHA256: String(repeating: "a", count: 64),
            planRevision: 1,
            backendRuntimeBuildIdentifier: "test-runtime",
            virtualHardwareABIVersion: 1,
            rawHVVirtualHardwareTopology: topology,
            graphics: .software,
            devices: makeDevices(),
            portForwards: [],
            executionResources: .production(memoryMB: 4_096, virtualCPUCount: 4),
            systemDiskCapacityBytes: capacityBytes,
            systemDiskLogicalID: topology.occupiedSlots.first {
                $0.role == .systemDisk
            }!.logicalID,
            linuxRootDevice: "/dev/vda",
            genericGuest: false,
            linuxKernelByteCount: 1,
            linuxKernelSHA256: String(repeating: "0", count: 64)
        )
        _ = try envelope.validatedResolvedRawHVResources()
        return (envelope, kernel)
    }

    private func makeTopology() -> DoryRawHVVirtualHardwareTopology {
        let network = DoryVirtualMachineNetworkInterfaceCapabilityRequest.stable(
            machineID: "authority-test"
        )
        let networkLogicalID = try! DoryVirtualDeviceID.derived(
            namespace: .network,
            stableID: network.id
        )
        return try! DoryRawHVVirtualHardwareTopologyReconciler.reconcile(
            requestedDevices: [
                try! .init(logicalID: "system-disk", role: .systemDisk),
                try! .init(logicalID: "rawhv-graphics", role: .graphics),
                try! .init(logicalID: "rawhv-entropy", role: .entropy),
                try! .init(logicalID: "rawhv-balloon", role: .balloon),
                try! .init(logicalID: "rawhv-vsock", role: .vsock),
                .init(logicalID: networkLogicalID, role: .network),
            ]
        )
    }

    private func makeDevices() -> DoryVirtualMachineDeviceCapabilityRequest {
        DoryVirtualMachineDeviceCapabilityRequest(
            networkInterface: .stable(machineID: "authority-test"),
            displays: [
                .init(widthPixels: 1_920, heightPixels: 1_080),
            ]
        )
    }

    private func admitDisk(_ fixture: DiskFixture) throws -> RawHVAdmittedSystemDisk {
        try fixture.lease.withBorrowedDescriptor { descriptor in
            try MachineManager.admitResolvedRawHVSystemDisk(
                machineDirectoryDescriptor: descriptor,
                machineDirectoryGeneration: fixture.lease.generation,
                expectedCapacityBytes: UInt64(fixture.contents.count)
            )
        }
    }

    private func makeDiskFixture(contents: Data) throws -> DiskFixture {
        let root = "/private/tmp/dory-runtime-disk-authority-\(getpid())-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(root, 0o700), 0)
        let directory = root + "/authority-test"
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(directory, 0o700), 0)
        let disk = paddedDisk(contents: contents)
        let path = directory + "/rootfs.ext4"
        try writePrivateFile(disk, path: path)
        let broker = try DoryMachineStateBroker(canonicalStateRootPath: root)
        return (
            root,
            directory,
            path,
            disk,
            try broker.acquireMachineDirectoryLease(machineID: "authority-test")
        )
    }

    private func paddedDisk(contents: Data) -> Data {
        var result = contents
        result.append(Data(repeating: 0, count: 4096 - contents.count))
        return result
    }

    private func writePrivateFile(_ contents: Data, path: String) throws {
        try contents.write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}

private final class LockedRuntimeTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: HvProcessTermination?

    var value: HvProcessTermination? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: HvProcessTermination) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}
