#if arch(arm64)
import CryptoKit
import DoryFirmware
import DoryMachineARMVirt
import Foundation
import Testing

@testable import DoryHV

@Suite struct ARMVirtFirmwareCodeMemoryTests {
    @Test func padsProtectsAndMapsTheExactFrozenWindow() throws {
        let recorder = MappingRecorder()
        let firmware = Data(repeating: 0xa5, count: 4_096)
        let memory = try ARMVirtFirmwareCodeMemory(
            artifacts: makeArtifacts(firmware: firmware),
            operations: recorder.operations
        )

        #expect(try memory.readBytes(at: 0, count: 4) == [0xa5, 0xa5, 0xa5, 0xa5])
        #expect(try memory.readBytes(at: firmware.count, count: 4) == [0xff, 0xff, 0xff, 0xff])
        #expect(recorder.protectedByteCount == Int(DoryARMVirtV1ABI.firmwareCodeBytes))

        try memory.mapIntoGuest()
        #expect(recorder.mappedGuestAddress == DoryARMVirtV1ABI.firmwareCodeBase)
        #expect(recorder.mappedByteCount == Int(DoryARMVirtV1ABI.firmwareCodeBytes))
        #expect(throws: VMError.self) { try memory.mapIntoGuest() }

        try memory.unmapFromGuest()
        #expect(recorder.unmappedGuestAddress == DoryARMVirtV1ABI.firmwareCodeBase)
        #expect(recorder.unmappedByteCount == Int(DoryARMVirtV1ABI.firmwareCodeBytes))
    }

    @Test func mappingFailureNeverClaimsGuestOwnership() throws {
        let recorder = MappingRecorder(mapSucceeds: false)
        let memory = try ARMVirtFirmwareCodeMemory(
            artifacts: makeArtifacts(firmware: Data(repeating: 0x5a, count: 4_096)),
            operations: recorder.operations
        )

        #expect(throws: VMError.self) { try memory.mapIntoGuest() }
        try memory.unmapFromGuest()
        #expect(recorder.unmappedGuestAddress == nil)
    }

    private func makeArtifacts(firmware: Data) throws -> DoryVerifiedFirmwareArtifacts {
        let variables = try DoryUEFIVariableStoreSnapshot(platform: .armVirtV1).canonicalData()
        let sbom = Data(#"{"bomFormat":"CycloneDX","specVersion":"1.6"}"#.utf8)
        let digest: (Data) -> String = { data in
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let manifest = try DoryFirmwareArtifactManifest(
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
            variableStoreTemplateSHA256: digest(variables),
            variableStoreTemplateByteCount: UInt64(variables.count),
            sbomSHA256: digest(sbom),
            secureBootPolicy: .userManagedKeys,
            reproducible: true
        )
        return try DoryVerifiedFirmwareArtifacts(
            manifest: manifest,
            firmwareCode: firmware,
            variableStoreTemplate: variables,
            sbom: sbom
        )
    }
}

private final class MappingRecorder: @unchecked Sendable {
    private let mapSucceeds: Bool
    var protectedByteCount: Int?
    var mappedGuestAddress: UInt64?
    var mappedByteCount: Int?
    var unmappedGuestAddress: UInt64?
    var unmappedByteCount: Int?

    init(mapSucceeds: Bool = true) {
        self.mapSucceeds = mapSucceeds
    }

    lazy var operations = ARMVirtFirmwareCodeMemoryOperations(
        allocate: { byteCount in
            UnsafeMutableRawPointer.allocate(
                byteCount: byteCount,
                alignment: Int(DoryARMVirtV1ABI.firmwareCodeBytes / 4_096)
            )
        },
        protectReadOnly: { [unowned self] _, byteCount in
            protectedByteCount = byteCount
            return true
        },
        mapReadExecute: { [unowned self] _, guestAddress, byteCount in
            mappedGuestAddress = guestAddress
            mappedByteCount = byteCount
            return mapSucceeds
        },
        unmap: { [unowned self] guestAddress, byteCount in
            unmappedGuestAddress = guestAddress
            unmappedByteCount = byteCount
            return true
        },
        deallocate: { pointer, _ in pointer.deallocate() }
    )
}
#endif
