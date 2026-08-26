import CryptoKit
import Darwin
import DoryOperations
import DoryRendererWorkerWireContracts
import DoryVMContracts
import Foundation
@testable import DorydKit
import XCTest

final class RuntimeBootAuthorityIntegrationTests: XCTestCase {
    func testManagedKernelAdmissionProducesPinnedReadOnlyUnlinkedAuthority() throws {
        let fixture = try makeManagedMachineDirectory(
            prefix: "dory-runtime-kernel-authority"
        )
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let sourcePath = fixture.directory + "/kernel"
        let original = Data((0..<65_537).map { UInt8(truncatingIfNeeded: $0) })
        try writePrivateFile(original, path: sourcePath)

        let admitted = try fixture.lease.withBorrowedDescriptor { descriptor in
            try MachineManager.admitResolvedRawHVLinuxBoot(
                machineDirectoryDescriptor: descriptor,
                machineDirectoryGeneration: fixture.lease.generation,
                mediaKind: .linuxKernel,
                expectedArtifactSHA256: digest(original),
                machineBootMode: .linuxKernel,
                installerISOPath: nil
            )
        }
        defer { admitted.close() }

        XCTAssertEqual(admitted.rootDevice, "/dev/vda")
        XCTAssertFalse(admitted.genericGuest)
        XCTAssertNil(admitted.initrd)
        XCTAssertEqual(admitted.kernel.byteCount, UInt64(original.count))
        XCTAssertEqual(admitted.kernel.sha256, digest(original))
        try assertImmutableAuthority(admitted.kernel.authority, expected: original)

        let pinnedPath = fixture.directory + "/original-kernel"
        try FileManager.default.moveItem(atPath: sourcePath, toPath: pinnedPath)
        let replacement = Data(repeating: 0xee, count: original.count)
        try writePrivateFile(replacement, path: sourcePath)

        XCTAssertEqual(try contents(of: admitted.kernel.authority), original)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sourcePath)), replacement)
    }

    func testInstalledBundleAdmissionPinsVerifiedComponentsAndRemovesStagingNames() throws {
        let fixture = try makeManagedMachineDirectory(
            prefix: "dory-runtime-bundle-authority"
        )
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let sourcePath = fixture.directory + "/kernel"
        let kernel = Data(repeating: 0x31, count: 32_769)
        let initrd = Data(repeating: 0x41, count: 65_539)
        try writeBundle(kernel: kernel, initrd: initrd, rootDevice: "/dev/vda2", path: sourcePath)
        let bundleBytes = try Data(contentsOf: URL(fileURLWithPath: sourcePath))

        let admitted = try fixture.lease.withBorrowedDescriptor { descriptor in
            try MachineManager.admitResolvedRawHVLinuxBoot(
                machineDirectoryDescriptor: descriptor,
                machineDirectoryGeneration: fixture.lease.generation,
                mediaKind: .installedLinuxBootBundle,
                expectedArtifactSHA256: digest(bundleBytes),
                machineBootMode: .efi,
                installerISOPath: nil
            )
        }
        defer { admitted.close() }

        XCTAssertEqual(admitted.rootDevice, "/dev/vda2")
        XCTAssertTrue(admitted.genericGuest)
        XCTAssertEqual(admitted.authorities.count, 2)
        XCTAssertEqual(admitted.kernel.byteCount, UInt64(kernel.count))
        XCTAssertEqual(admitted.kernel.sha256, digest(kernel))
        XCTAssertEqual(admitted.initrd?.byteCount, UInt64(initrd.count))
        XCTAssertEqual(admitted.initrd?.sha256, digest(initrd))
        try assertImmutableAuthority(admitted.kernel.authority, expected: kernel)
        let admittedInitrd = try XCTUnwrap(admitted.initrd)
        try assertImmutableAuthority(admittedInitrd.authority, expected: initrd)
        XCTAssertFalse(try directoryEntries(fixture.directory).contains {
            $0.hasPrefix(".rawhv-")
        })

        let pinnedPath = fixture.directory + "/original-bundle"
        try FileManager.default.moveItem(atPath: sourcePath, toPath: pinnedPath)
        try writeBundle(
            kernel: Data(repeating: 0x51, count: 4_096),
            initrd: Data(repeating: 0x61, count: 8_192),
            rootDevice: "/dev/vda9",
            path: sourcePath
        )

        XCTAssertEqual(try contents(of: admitted.kernel.authority), kernel)
        XCTAssertEqual(try contents(of: admittedInitrd.authority), initrd)
    }

    func testBundleAdmissionRejectsWrongWholeArtifactDigestWithoutStagingResidue() throws {
        let fixture = try makeManagedMachineDirectory(
            prefix: "dory-runtime-bundle-rejection"
        )
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let sourcePath = fixture.directory + "/kernel"
        try writeBundle(
            kernel: Data(repeating: 0x71, count: 4_096),
            initrd: Data(repeating: 0x81, count: 8_192),
            rootDevice: "/dev/vda3",
            path: sourcePath
        )

        XCTAssertThrowsError(try fixture.lease.withBorrowedDescriptor { descriptor in
            try MachineManager.admitResolvedRawHVLinuxBoot(
                machineDirectoryDescriptor: descriptor,
                machineDirectoryGeneration: fixture.lease.generation,
                mediaKind: .installedLinuxBootBundle,
                expectedArtifactSHA256: String(repeating: "0", count: 64),
                machineBootMode: .efi,
                installerISOPath: nil
            )
        }) { error in
            XCTAssertEqual(
                error as? DoryInstalledLinuxBootBundleError,
                .artifactDigestMismatch
            )
        }
        XCTAssertFalse(try directoryEntries(fixture.directory).contains {
            $0.hasPrefix(".rawhv-")
        })
    }

    func testFixedKernelLeafRejectsSymlinkAndWrongMode() throws {
        let fixture = try makeManagedMachineDirectory(
            prefix: "dory-runtime-kernel-leaf-policy"
        )
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let bytes = Data("kernel-leaf".utf8)
        let target = fixture.directory + "/target-kernel"
        let kernelPath = fixture.directory + "/kernel"
        try writePrivateFile(bytes, path: target)
        XCTAssertEqual(symlink(target, kernelPath), 0)

        XCTAssertThrowsError(try fixture.lease.withBorrowedDescriptor { descriptor in
            try MachineManager.admitResolvedRawHVLinuxBoot(
                machineDirectoryDescriptor: descriptor,
                machineDirectoryGeneration: fixture.lease.generation,
                mediaKind: .linuxKernel,
                expectedArtifactSHA256: digest(bytes),
                machineBootMode: .linuxKernel,
                installerISOPath: nil
            )
        }) { error in
            XCTAssertTrue("\(error)".contains("could not open raw-HV boot artifact"))
        }

        try FileManager.default.removeItem(atPath: kernelPath)
        try writePrivateFile(bytes, path: kernelPath)
        XCTAssertEqual(chmod(kernelPath, 0o644), 0)
        XCTAssertThrowsError(try fixture.lease.withBorrowedDescriptor { descriptor in
            try MachineManager.admitResolvedRawHVLinuxBoot(
                machineDirectoryDescriptor: descriptor,
                machineDirectoryGeneration: fixture.lease.generation,
                mediaKind: .linuxKernel,
                expectedArtifactSHA256: digest(bytes),
                machineBootMode: .linuxKernel,
                installerISOPath: nil
            )
        }) { error in
            XCTAssertTrue("\(error)".contains("owner/link/mode/size"))
        }
    }

    func testRendererBootstrapBindsExactKernelAndUsesReadOnlyUnlinkedFD6() throws {
        let fixture = try makeManagedMachineDirectory(
            prefix: "dory-runtime-renderer-bootstrap"
        )
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let exactKernel = Data("exact-expanded-managed-kernel".utf8)
        let request = try rendererBootstrapRequest()

        let admitted = try fixture.lease.withBorrowedDescriptor { descriptor in
            try MachineManager.stageResolvedRawHVRendererBootstrap(
                machineDirectoryDescriptor: descriptor,
                machineDirectoryGeneration: fixture.lease.generation,
                exactKernelSHA256: digest(exactKernel),
                request: request
            )
        }
        defer { admitted.close() }

        XCTAssertEqual(DoryRendererWorkerBootstrapCodec.fixedByteCount, 228)
        XCTAssertEqual(admitted.byteCount, 228)
        XCTAssertEqual(admitted.authority.name, RuntimeLaunchEnvelope.rendererBootstrapSlotName)
        XCTAssertEqual(
            admitted.authority.childDescriptor,
            RuntimeLaunchEnvelope.rendererBootstrapDescriptor
        )
        let encoded = try contents(of: admitted.authority)
        XCTAssertEqual(admitted.sha256, digest(encoded))
        try assertImmutableAuthority(admitted.authority, expected: encoded)
        let bootstrap = try DoryRendererWorkerBootstrapCodec.decode(encoded)
        XCTAssertEqual(bootstrap.workspaceID.rawValue, request.workspaceID)
        XCTAssertEqual(bootstrap.generation.rawValue, request.generation)
        XCTAssertEqual(bootstrap.sourceTuple, .productionCandidate)
        XCTAssertEqual(
            bootstrap.producerFenceContract,
            .managedLinux61230PrepareFBV1
        )
        XCTAssertEqual(
            bootstrap.requestedCapabilities,
            .productionAcceleration
        )
        XCTAssertEqual(
            bootstrap.artifacts.managedGuestKernel.lowercaseSHA256,
            digest(exactKernel)
        )
        XCTAssertEqual(
            bootstrap.artifacts.rendererWorkerCodeDirectoryHash,
            request.rendererWorkerCodeDirectoryHash
        )
        XCTAssertFalse(try directoryEntries(fixture.directory).contains {
            $0.hasPrefix(".rawhv-renderer-bootstrap-")
        })
    }

    func testSupervisorRetainsAllBootAuthoritiesAcrossRestartThenClosesAtTerminalExit() throws {
        let fixture = try makeRuntimeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let resources = try fixture.lease.withBorrowedDescriptor { descriptor in
            try MachineManager.admitResolvedRawHVResources(
                machineDirectoryDescriptor: descriptor,
                machineDirectoryGeneration: fixture.lease.generation,
                expectedDiskCapacityBytes: UInt64(fixture.disk.count),
                mediaKind: .installedLinuxBootBundle,
                expectedArtifactSHA256: digest(fixture.bundle),
                machineBootMode: .efi,
                installerISOPath: nil
            )
        }
        let disk = resources.disk
        let boot = resources.boot
        let initrd = try XCTUnwrap(boot.initrd)
        let envelope = try makeEnvelope(
            diskByteCount: UInt64(fixture.disk.count),
            boot: boot
        )
        let marker = fixture.directory + "/runs"
        let kernelCapture = fixture.directory + "/kernel-capture"
        let initrdCapture = fixture.directory + "/initrd-capture"
        let script = fixture.directory + "/restart-reader.sh"
        try """
        #!/bin/sh
        printf 'run\n' >> "$1"
        run=$(/usr/bin/wc -l < "$1" | /usr/bin/tr -d ' ')
        /usr/bin/perl -e 'open(my $in, "<&=4") or die; seek($in, 0, 0) or die; open(my $out, ">", $ARGV[0]) or die; while (read($in, my $buffer, 4096)) { print $out $buffer; }' "$2.$run"
        /usr/bin/perl -e 'open(my $in, "<&=5") or die; seek($in, 0, 0) or die; open(my $out, ">", $ARGV[0]) or die; while (read($in, my $buffer, 4096)) { print $out $buffer; }' "$3.$run"
        test "$run" -ne 1 || exit 7
        exit 0
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script)

        let process = HvProcess(configuration: HvProcessConfiguration(
            executablePath: script,
            arguments: [marker, kernelCapture, initrdCapture],
            restartPolicy: HvRestartPolicy(maxRestarts: 1, delaySeconds: 0.01),
            runtimeLaunchEnvelope: envelope,
            inheritedFileDescriptors: [disk.authority] + boot.authorities
        ))
        defer { process.stop() }
        try process.start()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let runCount = (try? String(contentsOfFile: marker, encoding: .utf8))?
                .split(separator: "\n").count ?? 0
            if runCount == 2,
               !process.isRunningOrRestarting,
               descriptorIsClosed(disk.authority),
               descriptorIsClosed(boot.kernel.authority),
               descriptorIsClosed(initrd.authority) {
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        XCTAssertEqual(
            try String(contentsOfFile: marker, encoding: .utf8).split(separator: "\n").count,
            2
        )
        for run in 1...2 {
            XCTAssertEqual(
                try Data(contentsOf: URL(fileURLWithPath: "\(kernelCapture).\(run)")),
                fixture.kernel
            )
            XCTAssertEqual(
                try Data(contentsOf: URL(fileURLWithPath: "\(initrdCapture).\(run)")),
                fixture.initrd
            )
        }
        XCTAssertFalse(process.isRunningOrRestarting)
        XCTAssertTrue(descriptorIsClosed(disk.authority))
        XCTAssertTrue(descriptorIsClosed(boot.kernel.authority))
        XCTAssertTrue(descriptorIsClosed(initrd.authority))
    }

    func testSupervisorRejectsMissingInitrdAuthorityBeforeSpawn() throws {
        let fixture = try makeRuntimeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let resources = try fixture.lease.withBorrowedDescriptor { descriptor in
            try MachineManager.admitResolvedRawHVResources(
                machineDirectoryDescriptor: descriptor,
                machineDirectoryGeneration: fixture.lease.generation,
                expectedDiskCapacityBytes: UInt64(fixture.disk.count),
                mediaKind: .installedLinuxBootBundle,
                expectedArtifactSHA256: digest(fixture.bundle),
                machineBootMode: .efi,
                installerISOPath: nil
            )
        }
        let disk = resources.disk
        let boot = resources.boot
        defer {
            disk.authority.close()
            boot.close()
        }
        let envelope = try makeEnvelope(
            diskByteCount: UInt64(fixture.disk.count),
            boot: boot
        )
        let marker = fixture.directory + "/must-not-run"
        let process = HvProcess(configuration: HvProcessConfiguration(
            executablePath: "/bin/sh",
            arguments: ["-c", "touch \"$1\"", "dory-boot-authority-test", marker],
            runtimeLaunchEnvelope: envelope,
            inheritedFileDescriptors: [disk.authority, boot.kernel.authority]
        ))

        XCTAssertThrowsError(try process.start()) { error in
            guard case HvProcess.ProcessError.descriptorEnvelopeMismatch = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    private func makeEnvelope(
        diskByteCount: UInt64,
        boot: RawHVAdmittedLinuxBoot
    ) throws -> RuntimeLaunchEnvelope {
        let topology = makeTopology()
        let initrd = try XCTUnwrap(boot.initrd)
        let envelope = RuntimeLaunchEnvelope.resolvedRawHV(
            machineID: "boot-authority-test",
            operationID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            resolvedPlanSHA256: String(repeating: "a", count: 64),
            planRevision: 1,
            backendRuntimeBuildIdentifier: "test-runtime",
            virtualHardwareABIVersion: 1,
            rawHVVirtualHardwareTopology: topology,
            graphics: .software,
            devices: makeDevices(),
            portForwards: [],
            executionResources: .production(memoryMB: 4_096, virtualCPUCount: 4),
            systemDiskCapacityBytes: diskByteCount,
            systemDiskLogicalID: topology.occupiedSlots.first {
                $0.role == .systemDisk
            }!.logicalID,
            linuxRootDevice: boot.rootDevice,
            genericGuest: boot.genericGuest,
            linuxKernelByteCount: boot.kernel.byteCount,
            linuxKernelSHA256: boot.kernel.sha256,
            linuxInitrdByteCount: initrd.byteCount,
            linuxInitrdSHA256: initrd.sha256
        )
        _ = try envelope.validatedResolvedRawHVResources()
        return envelope
    }

    private func makeTopology() -> DoryRawHVVirtualHardwareTopology {
        let network = DoryVirtualMachineNetworkInterfaceCapabilityRequest.stable(
            machineID: "boot-authority-test"
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
            networkInterface: .stable(machineID: "boot-authority-test"),
            displays: [.init(widthPixels: 1_920, heightPixels: 1_080)]
        )
    }

    private func makeRuntimeFixture() throws -> (
        root: String,
        directory: String,
        lease: DoryMachineDirectoryLease,
        diskPath: String,
        disk: Data,
        bundlePath: String,
        bundle: Data,
        kernel: Data,
        initrd: Data
    ) {
        let managed = try makeManagedMachineDirectory(
            prefix: "dory-runtime-boot-supervisor"
        )
        let directory = managed.directory
        let diskPath = directory + "/rootfs.ext4"
        let disk = Data(repeating: 0xd1, count: 4_096)
        try writePrivateFile(disk, path: diskPath)
        let bundlePath = directory + "/kernel"
        let kernel = Data(repeating: 0x91, count: 32_769)
        let initrd = Data(repeating: 0xa1, count: 65_539)
        try writeBundle(
            kernel: kernel,
            initrd: initrd,
            rootDevice: "/dev/vda2",
            path: bundlePath
        )
        return (
            managed.root,
            directory,
            managed.lease,
            diskPath,
            disk,
            bundlePath,
            try Data(contentsOf: URL(fileURLWithPath: bundlePath)),
            kernel,
            initrd
        )
    }

    private func rendererBootstrapRequest() throws -> RawHVRendererBootstrapRequest {
        let runtimeDigest = String(repeating: "a", count: 64)
        let runtimeBuild = "sha256:\(runtimeDigest)"
        func artifact(_ nibble: Character) throws -> DoryRendererArtifactDigest {
            try DoryRendererArtifactDigest(
                lowercaseSHA256: String(repeating: nibble, count: 64),
                field: "test"
            )
        }
        let admission = DoryDaemonRendererAccelerationAdmission(
            runtimeBuildIdentifier: runtimeBuild,
            candidateInventory: try artifact("b"),
            guestMesa: try DoryRendererArtifactDigest(
                lowercaseSHA256: DoryRendererSourceTuple.guestMesaRuntimeSHA256,
                field: "guestMesa"
            ),
            rendererWorkerExecutable: try artifact("2"),
            bootstrapQualification: try artifact("3")
        )
        var components = admission.qualifiedComponents.map {
            DoryResolvedBackendComponentEvidence(
                componentIdentifier: $0.componentIdentifier,
                buildIdentifier: $0.buildIdentifier,
                artifactSHA256: $0.artifactSHA256
            )
        }
        components.append(DoryResolvedBackendComponentEvidence(
            componentIdentifier: "dory-hv",
            buildIdentifier: runtimeBuild,
            artifactSHA256: runtimeDigest
        ))
        return RawHVRendererBootstrapRequest(
            workspaceID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            generation: 7,
            runtimeBuildIdentifier: runtimeBuild,
            components: components,
            rendererWorkerCodeDirectoryHash: try DoryCodeDirectoryHash(
                lowercaseHexadecimal: String(repeating: "34", count: 20),
                field: "rendererWorkerCodeDirectoryHash"
            )
        )
    }

    private func makeManagedMachineDirectory(prefix: String) throws -> (
        root: String,
        directory: String,
        lease: DoryMachineDirectoryLease
    ) {
        let root = "/private/tmp/\(prefix)-\(getpid())-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(root, 0o700) == 0 else { throw POSIXError(.EACCES) }
        let directory = root + "/machine"
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(directory, 0o700) == 0 else { throw POSIXError(.EACCES) }
        let broker = try DoryMachineStateBroker(canonicalStateRootPath: root)
        return (
            root,
            directory,
            try broker.acquireMachineDirectoryLease(machineID: "machine")
        )
    }

    private func writeBundle(
        kernel: Data,
        initrd: Data,
        rootDevice: String,
        path: String
    ) throws {
        try DoryInstalledLinuxBootBundle.write(
            assets: .init(
                kernel: kernel,
                initrd: initrd,
                kernelISOPath: "kernel",
                initrdISOPath: "initrd"
            ),
            rootDevice: rootDevice,
            toPath: path
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    private func writePrivateFile(_ contents: Data, path: String) throws {
        try contents.write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    private func assertImmutableAuthority(
        _ authority: HvProcessInheritedFileDescriptor,
        expected: Data
    ) throws {
        try authority.withBorrowedDescriptor { descriptor in
            var info = stat()
            XCTAssertEqual(fstat(descriptor, &info), 0)
            XCTAssertEqual(info.st_mode & S_IFMT, S_IFREG)
            XCTAssertEqual(info.st_uid, geteuid())
            XCTAssertEqual(info.st_nlink, 0)
            XCTAssertEqual(UInt64(info.st_size), UInt64(expected.count))
            let flags = fcntl(descriptor, F_GETFL)
            XCTAssertGreaterThanOrEqual(flags, 0)
            XCTAssertEqual(flags & O_ACCMODE, O_RDONLY)
        }
        XCTAssertEqual(try contents(of: authority), expected)
    }

    private func contents(of authority: HvProcessInheritedFileDescriptor) throws -> Data {
        try authority.withBorrowedDescriptor { descriptor in
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_size >= 0 else {
                throw POSIXError(.EIO)
            }
            var bytes = Data(count: Int(info.st_size))
            let actual = bytes.withUnsafeMutableBytes { buffer -> Int in
                var completed = 0
                while completed < buffer.count {
                    let result = pread(
                        descriptor,
                        buffer.baseAddress!.advanced(by: completed),
                        buffer.count - completed,
                        off_t(completed)
                    )
                    if result < 0, errno == EINTR { continue }
                    if result <= 0 { return completed }
                    completed += result
                }
                return completed
            }
            guard actual == bytes.count else { throw POSIXError(.EIO) }
            return bytes
        }
    }

    private func descriptorIsClosed(_ authority: HvProcessInheritedFileDescriptor) -> Bool {
        do {
            _ = try authority.withBorrowedDescriptor { $0 }
            return false
        } catch {
            return true
        }
    }

    private func directoryEntries(_ path: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
