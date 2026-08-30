import CryptoKit
import Darwin
import DoryFirmware
import DoryOperations
import DoryVMContracts
import Foundation
@testable import DorydKit
import XCTest

final class RuntimeUEFIAuthorityIntegrationTests: XCTestCase {
    func testInstallerAdmissionPinsFirmwareMediaAndVariableDirectory() throws {
        let fixture = try makeFixture(includeInstaller: true)
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        defer { try? FileManager.default.removeItem(atPath: fixture.firmwareDirectory) }

        let admitted = try fixture.lease.withBorrowedDescriptor { descriptor in
            try MachineManager.admitResolvedARMVirtUEFIResources(
                machineDirectoryDescriptor: descriptor,
                machineDirectoryGeneration: fixture.lease.generation,
                expectedDiskCapacityBytes: UInt64(fixture.disk.count),
                firmwareBundlePath: fixture.firmwareDirectory,
                topology: fixture.topology,
                mediaKind: .installerISO,
                expectedInstallerSHA256: digest(fixture.installer!)
            )
        }
        defer { admitted.close() }

        XCTAssertEqual(
            [admitted.disk.authority.childDescriptor]
                + admitted.boot.authorities.map(\.childDescriptor),
            [3, 4, 5, 6, 7, 8]
        )
        XCTAssertEqual(admitted.boot.launchPlan.firmware, fixture.manifest)
        XCTAssertEqual(admitted.boot.launchPlan.variableStoreGeneration, 1)
        XCTAssertEqual(
            admitted.boot.launchPlan.bootOrder,
            ["installer-media", "system-disk"]
        )
        try assertImmutable(
            admitted.boot.firmwareCode.authority,
            expected: fixture.firmware
        )
        try assertImmutable(
            admitted.boot.variableStoreTemplate.authority,
            expected: fixture.variables
        )
        try assertImmutable(admitted.boot.firmwareSBOM.authority, expected: fixture.sbom)
        try assertImmutable(
            XCTUnwrap(admitted.boot.installerMedia).authority,
            expected: XCTUnwrap(fixture.installer)
        )
        try admitted.boot.variableStoreDirectory.withBorrowedDescriptor { descriptor in
            var info = stat()
            XCTAssertEqual(fstat(descriptor, &info), 0)
            XCTAssertEqual(info.st_mode & S_IFMT, S_IFDIR)
            XCTAssertEqual(info.st_mode & mode_t(0o7777), mode_t(0o700))
            let store = try DoryUEFIVariableStoreDirectoryDescriptor(
                inheritedDescriptor: descriptor
            )
            let loaded = try store.load()
            XCTAssertEqual(loaded.source, .primary)
            XCTAssertEqual(loaded.snapshot.generation, 1)
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(
            atPath: fixture.directory
        ).contains { $0.hasPrefix(".rawhv-") })
    }

    func testAdmissionRejectsSubstitutedFirmwareBeforeLeasingDisk() throws {
        let fixture = try makeFixture(includeInstaller: false)
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        defer { try? FileManager.default.removeItem(atPath: fixture.firmwareDirectory) }
        let sbomPath = fixture.firmwareDirectory + "/" + DoryARMVirtFirmwareBundleLayout.sbom
        try Data("substituted".utf8).write(to: URL(fileURLWithPath: sbomPath))
        XCTAssertEqual(chmod(sbomPath, 0o644), 0)

        XCTAssertThrowsError(try fixture.lease.withBorrowedDescriptor { descriptor in
            try MachineManager.admitResolvedARMVirtUEFIResources(
                machineDirectoryDescriptor: descriptor,
                machineDirectoryGeneration: fixture.lease.generation,
                expectedDiskCapacityBytes: UInt64(fixture.disk.count),
                firmwareBundlePath: fixture.firmwareDirectory,
                topology: fixture.topology,
                mediaKind: .virtualDisk,
                expectedInstallerSHA256: nil
            )
        }) { error in
            XCTAssertTrue("\(error)".contains("firmware bundle admission failed"), "\(error)")
        }

        let disk = try fixture.lease.withBorrowedDescriptor { descriptor in
            try MachineManager.admitResolvedRawHVSystemDisk(
                machineDirectoryDescriptor: descriptor,
                machineDirectoryGeneration: fixture.lease.generation,
                expectedCapacityBytes: UInt64(fixture.disk.count)
            )
        }
        disk.authority.close()
    }

    private func makeFixture(includeInstaller: Bool) throws -> (
        root: String,
        directory: String,
        lease: DoryMachineDirectoryLease,
        disk: Data,
        installer: Data?,
        firmwareDirectory: String,
        firmware: Data,
        variables: Data,
        sbom: Data,
        manifest: DoryFirmwareArtifactManifest,
        topology: DoryARMVirtV1Topology
    ) {
        let root = "/private/tmp/dory-uefi-authority-\(getpid())-\(UUID().uuidString)"
        let directory = root + "/machine"
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(root, 0o700), 0)
        XCTAssertEqual(chmod(directory, 0o700), 0)
        let disk = Data(repeating: 0xd1, count: 4_096)
        try writePrivate(disk, to: directory + "/rootfs.ext4")
        let installer = includeInstaller ? Data(repeating: 0xcd, count: 8_192) : nil
        if let installer {
            try writePrivate(installer, to: directory + "/installer.iso")
        }

        let firmwareDirectory = "/tmp/dory-uefi-firmware-\(getpid())-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: firmwareDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        XCTAssertEqual(chmod(firmwareDirectory, 0o755), 0)
        let firmware = Data(repeating: 0xa5, count: 4_096)
        let variables = try DoryUEFIVariableStoreSnapshot().canonicalData()
        let sbom = Data(#"{"bomFormat":"CycloneDX","specVersion":"1.6"}"#.utf8)
        let manifest = try DoryFirmwareArtifactManifest(
            buildIdentifier: "dory-armvirt-fw-admission-test.1",
            source: DoryFirmwareSourcePin(
                repository: "https://github.com/tianocore/edk2.git",
                revision: String(repeating: "a", count: 40)
            ),
            sourceDateEpoch: 1_788_048_000,
            platformConfigurationSHA256: digest(Data("DoryARMVirt.dsc".utf8)),
            toolchainSHA256: digest(Data("clang-17F109".utf8)),
            firmwareCodeSHA256: digest(firmware),
            firmwareCodeByteCount: UInt64(firmware.count),
            variableStoreTemplateSHA256: digest(variables),
            variableStoreTemplateByteCount: UInt64(variables.count),
            sbomSHA256: digest(sbom),
            secureBootPolicy: .userManagedKeys,
            reproducible: true
        )
        for (name, data) in [
            (DoryARMVirtFirmwareBundleLayout.manifest, try JSONEncoder().encode(manifest)),
            (DoryARMVirtFirmwareBundleLayout.firmwareCode, firmware),
            (DoryARMVirtFirmwareBundleLayout.variableStoreTemplate, variables),
            (DoryARMVirtFirmwareBundleLayout.sbom, sbom),
        ] {
            let path = firmwareDirectory + "/" + name
            try data.write(to: URL(fileURLWithPath: path))
            XCTAssertEqual(chmod(path, 0o644), 0)
        }

        var devices = [
            try DoryARMVirtV1DeviceRequest(logicalID: "system-disk", role: .systemDisk),
        ]
        if includeInstaller {
            devices.append(try DoryARMVirtV1DeviceRequest(
                logicalID: "installer-media",
                role: .removableStorage
            ))
        }
        let topology = try DoryARMVirtV1TopologyReconciler.reconcile(
            requestedDevices: devices
        )
        let broker = try DoryMachineStateBroker(canonicalStateRootPath: root)
        return (
            root,
            directory,
            try broker.acquireMachineDirectoryLease(machineID: "machine"),
            disk,
            installer,
            firmwareDirectory,
            firmware,
            variables,
            sbom,
            manifest,
            topology
        )
    }

    private func assertImmutable(
        _ authority: HvProcessInheritedFileDescriptor,
        expected: Data
    ) throws {
        try authority.withBorrowedDescriptor { descriptor in
            var info = stat()
            XCTAssertEqual(fstat(descriptor, &info), 0)
            XCTAssertEqual(info.st_mode & S_IFMT, S_IFREG)
            XCTAssertEqual(info.st_nlink, 0)
            XCTAssertEqual(UInt64(info.st_size), UInt64(expected.count))
            XCTAssertEqual(fcntl(descriptor, F_GETFL) & O_ACCMODE, O_RDONLY)
            var actual = Data(count: expected.count)
            let count = actual.withUnsafeMutableBytes { bytes in
                pread(descriptor, bytes.baseAddress, bytes.count, 0)
            }
            XCTAssertEqual(count, expected.count)
            XCTAssertEqual(actual, expected)
        }
    }

    private func writePrivate(_ data: Data, to path: String) throws {
        try data.write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(chmod(path, 0o600), 0)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
