import DoryOperations
import DoryVMContracts
import DoryFirmware
import CryptoKit
import Foundation
@testable import DorydKit

/// Structurally verified synthetic firmware for process/descriptor tests; never guest evidence.
func resolvedFirmwareTestArtifacts(
    platform: DoryFirmwarePlatform = .armVirtV1,
    fill: UInt8 = 0xa5
) throws -> DoryVerifiedFirmwareArtifacts {
    let firmware = Data(repeating: fill, count: 4_096)
    let variables = try DoryUEFIVariableStoreSnapshot(platform: platform).canonicalData()
    let sbom = Data(#"{"bomFormat":"CycloneDX","specVersion":"1.6"}"#.utf8)
    func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    let manifest = try DoryFirmwareArtifactManifest(
        platform: platform,
        buildIdentifier: "dory-firmware-test.1",
        source: DoryFirmwareSourcePin(
            repository: "https://github.com/tianocore/edk2.git",
            revision: String(repeating: "a", count: 40)
        ),
        sourceDateEpoch: 1_788_048_000,
        platformConfigurationSHA256: digest(Data(platform.rawValue.utf8)),
        toolchainSHA256: digest(Data("test-toolchain".utf8)),
        firmwareCodeSHA256: digest(firmware), firmwareCodeByteCount: UInt64(firmware.count),
        variableStoreTemplateSHA256: digest(variables),
        variableStoreTemplateByteCount: UInt64(variables.count),
        sbomSHA256: digest(sbom), secureBootPolicy: .userManagedKeys, reproducible: true
    )
    return try DoryVerifiedFirmwareArtifacts(
        manifest: manifest, firmwareCode: firmware, variableStoreTemplate: variables, sbom: sbom
    )
}

func makeARMVirtFirmwareTestBundle(at directory: String, fill: UInt8 = 0xa5) throws {
    try FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    let artifacts = try resolvedFirmwareTestArtifacts(fill: fill)
    for (name, data) in [
        (DoryARMVirtFirmwareBundleLayout.manifest, try JSONEncoder().encode(artifacts.manifest)),
        (DoryARMVirtFirmwareBundleLayout.firmwareCode, artifacts.firmwareCode),
        (DoryARMVirtFirmwareBundleLayout.variableStoreTemplate, artifacts.variableStoreTemplate),
        (DoryARMVirtFirmwareBundleLayout.sbom, artifacts.sbom),
    ] {
        let path = directory + "/" + name
        try data.write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}

func resolvedPersistenceTestBinding(
    machineID: String = "workspace-one",
    stateDirectory: String = "/fixture/machines"
) -> DoryResolvedMachinePersistence {
    try! DoryResolvedMachinePersistence(stateDirectory: stateDirectory, machineID: machineID)
}

func resolvedARMVirtTestTopology(
    devices: DoryVirtualMachineDeviceCapabilityRequest,
    installerID: String? = nil
) -> DoryARMVirtV1Topology {
    var roles: [DoryVirtualDeviceRole] = [.systemDisk, .entropy, .balloon, .vsock, .network]
    if !devices.displays.isEmpty { roles.append(.graphics) }
    if devices.keyboard { roles.append(.keyboard) }
    if devices.pointer { roles.append(.pointer) }
    if devices.audioInput || devices.audioOutput { roles.append(.audio) }
    var slots = roles.map { role in
        try! DoryARMVirtV1DeviceSlot(
            logicalID: DoryVirtualDeviceID.derived(namespace: role, stableID: "fixture"),
            role: role,
            mmioSlot: DoryARMVirtV1SlotPolicy.allowedSlots(for: role).lowerBound
        )
    }
    if let installerID {
        slots.append(try! DoryARMVirtV1DeviceSlot(
            logicalID: DoryVirtualDeviceID.derived(namespace: .removableStorage, stableID: installerID),
            role: .removableStorage,
            mmioSlot: 12
        ))
    }
    return try! DoryARMVirtV1Topology(occupiedSlots: slots)
}

func resolvedBootLaunchArtifacts(
    reference: DoryVMResolverReference,
    media: DoryBootMedia,
    mutableEvidence: DoryMutableBootMediaProvenanceAuditEvidence? = nil,
    identifier: String = "primary"
) -> [DoryResolvedMachineLaunchArtifact] {
    [DoryResolvedMachineLaunchArtifact(
        resolverReference: reference,
        media: media,
        authorityRevision: 1,
        usages: [DoryResolvedMachineLaunchArtifactUsage(
            kind: .boot,
            identifier: identifier,
            readOnly: media.mutableProvenance == nil
        )],
        mutableProvenanceEvidence: mutableEvidence
    )]
}

func resolvedMutableStorageLaunchArtifact(
    reference: DoryVMResolverReference,
    source: DoryBootMediaSource,
    identifier: String,
    digestCharacter: Character = "9"
) -> DoryResolvedMachineLaunchArtifact {
    let provenance = DoryMutableBootMediaProvenanceReference(
        repositoryIdentity: "fixture-artifact-authority",
        mediaIdentity: reference.namespace + "-" + reference.identifier,
        revision: 1
    )
    return DoryResolvedMachineLaunchArtifact(
        resolverReference: reference,
        media: DoryBootMedia(
            kind: .virtualDisk,
            source: source,
            mutableProvenance: provenance
        ),
        authorityRevision: 1,
        usages: [DoryResolvedMachineLaunchArtifactUsage(
            kind: .storage,
            identifier: identifier,
            readOnly: false
        )],
        mutableProvenanceEvidence: DoryMutableBootMediaProvenanceAuditEvidence(
            receiptIdentity: "fixture-storage-receipt-1",
            provenance: provenance,
            receiptSHA256: String(repeating: String(digestCharacter), count: 64),
            resolverID: "fixture-artifact-authority",
            resolverVersion: 1
        )
    )
}
