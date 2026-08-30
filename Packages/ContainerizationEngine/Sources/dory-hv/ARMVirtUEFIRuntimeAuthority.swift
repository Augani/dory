import Darwin
import DoryFirmware
import DoryHV
import DoryMachineARMVirt
import DoryOperations
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
