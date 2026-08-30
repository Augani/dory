import Darwin
import DoryFirmware
import DoryHV
import DoryMachineARMVirt
import DoryOperations
import DoryVMContracts
import Foundation

/// Fully admitted UEFI authority retained by the runner after immutable descriptor consumption.
struct ARMVirtUEFIRuntimeAuthority {
    let launchPlan: DoryARMVirtUEFILaunchPlan
    let artifacts: DoryVerifiedFirmwareArtifacts
    let variableStore: DoryUEFIVariableStoreAuthority
    let resources: RuntimeLaunchEnvelope.ResolvedARMVirtUEFIResources

    static func admit(envelope: RuntimeLaunchEnvelope) throws -> Self {
        guard case .uefi(let launchPlan) = envelope.boot else {
            throw VMError.invalidConfiguration("runtime envelope does not authorize UEFI boot")
        }
        return try admit(
            launchPlan: launchPlan,
            resources: envelope.validatedResolvedARMVirtUEFIResources()
        )
    }

    static func admit(
        launchPlan: DoryARMVirtUEFILaunchPlan,
        resources: RuntimeLaunchEnvelope.ResolvedARMVirtUEFIResources
    ) throws -> Self {
        defer { Darwin.close(resources.variableStoreDirectory.descriptor) }
        let immutable = try MachineInheritedImmutableBlobReader.readAndClose([
            try immutableBlob(
                resources.firmwareCode,
                maximumByteCount: DoryARMVirtV1ABI.firmwareCodeBytes
            ),
            try immutableBlob(
                resources.variableStoreTemplate,
                maximumByteCount: UInt64(DoryUEFIVariableStoreFile.maximumEncodedBytes)
            ),
            try immutableBlob(
                resources.firmwareSBOM,
                maximumByteCount: RuntimeLaunchEnvelope.maximumFirmwareSBOMBytes
            ),
        ])
        let artifacts = try DoryVerifiedFirmwareArtifacts(
            manifest: launchPlan.firmware,
            firmwareCode: immutable[0],
            variableStoreTemplate: immutable[1],
            sbom: immutable[2]
        )
        let template = try DoryUEFIVariableStoreSnapshot.decodeCanonicalTemplate(immutable[1])
        guard template.generation == 1 else {
            throw VMError.invalidConfiguration(
                "UEFI variable-store template must begin at generation 1"
            )
        }
        let descriptorStore = try DoryUEFIVariableStoreDirectoryDescriptor(
            inheritedDescriptor: resources.variableStoreDirectory.descriptor
        )
        do {
            _ = try descriptorStore.load()
        } catch DoryUEFIVariableStoreFileError.storeNotInitialized {
            try descriptorStore.initialize(template)
        }
        let load = try descriptorStore.load()
        guard load.source == .primary,
              load.snapshot.generation == launchPlan.variableStoreGeneration else {
            throw VMError.invalidConfiguration(
                "UEFI variable-store state does not match the immutable launch generation"
            )
        }
        return Self(
            launchPlan: launchPlan,
            artifacts: artifacts,
            variableStore: DoryUEFIVariableStoreAuthority(directoryDescriptor: descriptorStore),
            resources: resources
        )
    }

    func machineConfiguration(memoryMB: UInt64, cpuCount: Int) -> MachineConfiguration {
        MachineConfiguration(
            uefiLaunchPlan: launchPlan,
            artifacts: artifacts,
            variableStore: variableStore,
            memoryBytes: memoryMB << 20,
            cpuCount: cpuCount
        )
    }

    func installerDeviceRequest(
        topology: DoryARMVirtV1Topology?
    ) throws -> DoryARMVirtV1DeviceRequest? {
        guard let installer = resources.installerMedia,
              let logicalID = installer.logicalDeviceID else { return nil }
        guard let binding = topology?.occupiedSlots.first(where: {
            $0.logicalID == logicalID
        }), binding.role == .auxiliaryBlock || binding.role == .removableStorage,
              launchPlan.bootDevices.contains(where: {
                $0.kind == .removableMedia
                    && $0.logicalID == logicalID.rawValue
                    && $0.virtioSlot == binding.mmioSlot
              }) else {
            throw VMError.invalidConfiguration(
                "UEFI installer media is not bound to its frozen topology slot"
            )
        }
        return DoryARMVirtV1DeviceRequest(logicalID: logicalID, role: binding.role)
    }

    func consumeInstallerBackend() throws -> VirtioBlk? {
        guard let installer = resources.installerMedia else { return nil }
        let descriptor = installer.descriptor
        defer { Darwin.close(descriptor) }
        let accessFlags = fcntl(descriptor, F_GETFL)
        var status = stat()
        guard accessFlags >= 0,
              accessFlags & O_ACCMODE == O_RDONLY,
              fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 0,
              status.st_mode & 0o077 == 0,
              status.st_size > 0,
              UInt64(status.st_size) == installer.byteCount,
              installer.byteCount % 512 == 0 else {
            throw VMError.invalidConfiguration(
                "UEFI installer media is not the exact private read-only disk authority"
            )
        }
        return try VirtioBlk(
            fileDescriptor: descriptor,
            identity: "dory-installer-media",
            readOnly: true,
            queueCount: 1,
            discard: false
        )
    }

    private static func immutableBlob(
        _ slot: RuntimeLaunchEnvelope.InheritedFileDescriptorSlot,
        maximumByteCount: UInt64
    ) throws -> MachineInheritedImmutableBlob {
        guard slot.access == .readOnly, let sha256 = slot.contentSHA256 else {
            throw VMError.invalidConfiguration(
                "\(slot.name) is not an exact immutable descriptor authority"
            )
        }
        return MachineInheritedImmutableBlob(
            name: slot.name,
            descriptor: slot.descriptor,
            byteCount: slot.byteCount,
            sha256: sha256,
            maximumByteCount: maximumByteCount
        )
    }
}
