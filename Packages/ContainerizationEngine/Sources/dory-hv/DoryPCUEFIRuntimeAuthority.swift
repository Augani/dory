import Darwin
import DoryFirmware
import DoryHV
import DoryMachinePC
import DoryOperations
import DoryVirtio
import Foundation

/// Fully admitted DoryPC-v1 authority. Immutable firmware is consumed into memory; block devices
/// retain duplicates of the daemon-opened objects, and the NVRAM store retains directory authority.
struct DoryPCUEFIRuntimeAuthority {
    private final class VariableGenerationState: @unchecked Sendable {
        private let lock = NSLock()
        private var expected: UInt64

        init(expected: UInt64) { self.expected = expected }

        func authorize(_ actual: UInt64) throws {
            try lock.withLock {
                guard actual == expected else {
                    throw VMError.invalidConfiguration(
                        "DoryPC NVRAM changed outside the admitted runtime generation"
                    )
                }
            }
        }

        func advance(to generation: UInt64) {
            lock.withLock { expected = generation }
        }
    }

    let envelope: DoryPCRuntimeLaunchEnvelope
    let resources: DoryPCRuntimeLaunchEnvelope.ResolvedResources
    let artifacts: DoryVerifiedFirmwareArtifacts
    let variableStore: DoryUEFIVariableStoreAuthority
    let bootStorage: [DoryPCUEFIBootStorage]
    private let variableGeneration: VariableGenerationState

    static func admit(envelope: DoryPCRuntimeLaunchEnvelope) throws -> Self {
        let resources = try envelope.validatedResources()
        defer {
            Darwin.close(resources.systemDisk.descriptor)
            if let installer = resources.installerMedia {
                Darwin.close(installer.descriptor)
            }
            Darwin.close(resources.variableStoreDirectory.descriptor)
        }
        let immutable = try MachineInheritedImmutableBlobReader.readAndClose([
            try immutableBlob(
                resources.firmwareCode,
                maximumByteCount: DoryPCV1ABI.firmwareCodeBytes
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
            manifest: envelope.launchPlan.firmware,
            firmwareCode: immutable[0],
            variableStoreTemplate: immutable[1],
            sbom: immutable[2]
        )
        let template = try DoryUEFIVariableStoreSnapshot.decodeCanonicalTemplate(immutable[1])
        guard template.platform == .pcV1, template.generation == 1 else {
            throw VMError.invalidConfiguration(
                "DoryPC variable-store template must be a generation-one PC template"
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
              load.snapshot.platform == .pcV1,
              load.snapshot.generation == envelope.launchPlan.variableStoreGeneration else {
            throw VMError.invalidConfiguration(
                "DoryPC variable-store state does not match the immutable launch generation"
            )
        }

        let systemStorage = try admittedStorage(
            resources.systemDisk,
            readOnly: false,
            requiresUnlinkedObject: false
        )
        var storage = [
            DoryPCUEFIBootStorage(
                logicalID: resources.systemDisk.logicalDeviceID!.rawValue,
                storage: systemStorage
            )
        ]
        if let installer = resources.installerMedia {
            storage.append(DoryPCUEFIBootStorage(
                logicalID: installer.logicalDeviceID!.rawValue,
                storage: try admittedStorage(
                    installer,
                    readOnly: true,
                    requiresUnlinkedObject: true
                )
            ))
        }
        return Self(
            envelope: envelope,
            resources: resources,
            artifacts: artifacts,
            variableStore: DoryUEFIVariableStoreAuthority(directoryDescriptor: descriptorStore),
            bootStorage: storage,
            variableGeneration: VariableGenerationState(
                expected: envelope.launchPlan.variableStoreGeneration
            )
        )
    }

    func makeMachine(
        displaySink: (any DoryVirtioGPUDisplaySink)? = nil,
        gpuAccelerationAuthority: (any DoryVirtioGPUAccelerationAuthority)? = nil,
        soundBackend: any DoryVirtioSoundBackend = DoryVirtioInMemorySoundBackend(),
        networkBackend: any DoryVirtioNetworkBackend = DoryVirtioInMemoryNetworkBackend()
    ) throws -> DoryPCUEFIMachine {
        guard let networkInterface = envelope.devices.networkInterface else {
            throw VMError.invalidConfiguration("DoryPC network identity is missing")
        }
        let tier: DoryPCExecutionTier = switch envelope.executionResources.tier {
        case .interpreter: .interpreter
        case .baselineJIT: .baselineJIT
        case .optimizingJIT: .optimizingJIT
        }
        let current = try variableStore.load()
        guard current.source == .primary, current.snapshot.platform == .pcV1 else {
            throw VMError.invalidConfiguration("DoryPC NVRAM recovery is required")
        }
        try variableGeneration.authorize(current.snapshot.generation)
        let plan = try DoryPCUEFILaunchPlan(
            firmware: envelope.launchPlan.firmware,
            variableStoreGeneration: current.snapshot.generation,
            bootDevices: envelope.launchPlan.bootDevices,
            bootOrder: envelope.launchPlan.bootOrder
        )
        let machine = try DoryPCUEFIMachine(
            plan: plan,
            firmware: artifacts,
            variableStore: variableStore,
            bootStorage: bootStorage,
            memoryBytes: Int(envelope.executionResources.memoryMB) * 1_024 * 1_024,
            processorCount: Int(envelope.executionResources.virtualCPUCount),
            displaySink: displaySink,
            gpuAccelerationAuthority: gpuAccelerationAuthority,
            soundBackend: soundBackend,
            networkBackend: networkBackend,
            networkMACAddress: networkInterface.macAddressOctets!,
            networkMTU: networkInterface.maximumTransmissionUnit,
            executionTier: tier
        )
        variableGeneration.advance(to: machine.effectiveVariableStoreGeneration)
        return machine
    }

    private static func admittedStorage(
        _ slot: RuntimeLaunchEnvelope.InheritedFileDescriptorSlot,
        readOnly: Bool,
        requiresUnlinkedObject: Bool
    ) throws -> DoryVirtioFileBlockStorage {
        let descriptor = slot.descriptor
        let flags = fcntl(descriptor, F_GETFL)
        var status = stat()
        guard flags >= 0,
              (readOnly ? flags & O_ACCMODE == O_RDONLY : flags & O_ACCMODE == O_RDWR),
              fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_mode & 0o077 == 0,
              status.st_size > 0,
              UInt64(status.st_size) == slot.byteCount,
              status.st_nlink == (requiresUnlinkedObject ? 0 : 1),
              slot.byteCount % DoryVirtioBlockDevice.sectorSize == 0 else {
            throw VMError.invalidConfiguration(
                "\(slot.name) is not the exact private DoryPC block authority"
            )
        }
        return try DoryVirtioFileBlockStorage(
            duplicatingFileDescriptor: descriptor,
            expectedCapacityBytes: slot.byteCount,
            readOnly: readOnly
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
