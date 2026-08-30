import CryptoKit
import Darwin
import DoryFirmware
import DoryVMContracts
import Foundation
import Testing
@testable import DoryHV
@testable import DoryOperations
@testable import dory_hv

@Suite struct ARMVirtUEFIRuntimeAuthorityTests {
    @Test func admitsVerifiedArtifactsAndInitializesPathFreeVariableState() throws {
        let firmware = Data(repeating: 0xa5, count: 4_096)
        let variableTemplate = try DoryUEFIVariableStoreSnapshot().canonicalData()
        let sbom = Data(#"{"bomFormat":"CycloneDX","specVersion":"1.6"}"#.utf8)
        let manifest = try makeManifest(
            firmware: firmware,
            variableTemplate: variableTemplate,
            sbom: sbom
        )
        let systemDisk = try DoryARMVirtUEFIBootDevice(
            logicalID: "system",
            kind: .systemDisk,
            virtioSlot: 0,
            readOnly: false
        )
        let launchPlan = try DoryARMVirtUEFILaunchPlan(
            firmware: manifest,
            variableStoreGeneration: 1,
            bootDevices: [systemDisk],
            bootOrder: [systemDisk.logicalID]
        )
        let firmwareDescriptor = try anonymousReadOnlyBlob(firmware)
        let templateDescriptor = try anonymousReadOnlyBlob(variableTemplate)
        let sbomDescriptor = try anonymousReadOnlyBlob(sbom)
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        #expect(chmod(directory, 0o700) == 0)
        let directoryDescriptor = directory.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        #expect(directoryDescriptor >= 3)

        let resources = RuntimeLaunchEnvelope.ResolvedARMVirtUEFIResources(
            systemDisk: .init(
                name: RuntimeLaunchEnvelope.systemDiskSlotName,
                descriptor: 100,
                access: .readWrite,
                byteCount: 8 << 30,
                logicalDeviceID: try DoryVirtualDeviceID("system")
            ),
            firmwareCode: immutableSlot(
                name: RuntimeLaunchEnvelope.firmwareCodeSlotName,
                descriptor: firmwareDescriptor,
                data: firmware
            ),
            variableStoreTemplate: immutableSlot(
                name: RuntimeLaunchEnvelope.variableStoreTemplateSlotName,
                descriptor: templateDescriptor,
                data: variableTemplate
            ),
            firmwareSBOM: immutableSlot(
                name: RuntimeLaunchEnvelope.firmwareSBOMSlotName,
                descriptor: sbomDescriptor,
                data: sbom
            ),
            installerMedia: nil,
            variableStoreDirectory: .init(
                name: RuntimeLaunchEnvelope.variableStoreDirectorySlotName,
                descriptor: directoryDescriptor,
                access: .readWrite
            ),
            rendererBootstrap: nil
        )

        let authority = try ARMVirtUEFIRuntimeAuthority.admit(
            launchPlan: launchPlan,
            resources: resources
        )
        // The store duplicates the directory after immutable descriptors are retired, so the
        // kernel may immediately reuse the lowest firmware descriptor number for that directory.
        var reused = stat()
        #expect(fstat(firmwareDescriptor, &reused) == 0)
        #expect(reused.st_mode & S_IFMT == S_IFDIR)
        #expect(fcntl(templateDescriptor, F_GETFD) == -1)
        #expect(fcntl(sbomDescriptor, F_GETFD) == -1)
        #expect(fcntl(directoryDescriptor, F_GETFD) == -1)
        #expect(try authority.variableStore.load().snapshot.generation == 1)
        try authority.machineConfiguration(memoryMB: 1_024, cpuCount: 1)
            .validateDoryARMVirtV1()
    }

    private func makeManifest(
        firmware: Data,
        variableTemplate: Data,
        sbom: Data
    ) throws -> DoryFirmwareArtifactManifest {
        try DoryFirmwareArtifactManifest(
            buildIdentifier: "dory-armvirt-fw-test.1",
            source: DoryFirmwareSourcePin(
                repository: "https://github.com/tianocore/edk2.git",
                revision: String(repeating: "a", count: 40)
            ),
            sourceDateEpoch: 1_788_048_000,
            platformConfigurationSHA256: digest(Data("DoryARMVirt.dsc".utf8)),
            toolchainSHA256: digest(Data("clang-17F109".utf8)),
            firmwareCodeSHA256: digest(firmware),
            firmwareCodeByteCount: UInt64(firmware.count),
            variableStoreTemplateSHA256: digest(variableTemplate),
            variableStoreTemplateByteCount: UInt64(variableTemplate.count),
            sbomSHA256: digest(sbom),
            secureBootPolicy: .userManagedKeys,
            reproducible: true
        )
    }

    private func immutableSlot(
        name: String,
        descriptor: Int32,
        data: Data
    ) -> RuntimeLaunchEnvelope.InheritedFileDescriptorSlot {
        .init(
            name: name,
            descriptor: descriptor,
            access: .readOnly,
            byteCount: UInt64(data.count),
            contentSHA256: digest(data)
        )
    }

    private func anonymousReadOnlyBlob(_ data: Data) throws -> Int32 {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        #expect(chmod(directory, 0o700) == 0)
        let path = directory + "/blob"
        try data.write(to: URL(fileURLWithPath: path))
        #expect(chmod(path, 0o600) == 0)
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        #expect(descriptor >= 3)
        #expect(unlink(path) == 0)
        try FileManager.default.removeItem(atPath: directory)
        return descriptor
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func temporaryDirectory() -> String {
        "/tmp/dory-uefi-runtime-authority-\(getpid())-\(UUID().uuidString)"
    }
}
