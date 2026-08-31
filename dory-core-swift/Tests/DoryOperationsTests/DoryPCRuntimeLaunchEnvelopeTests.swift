import CryptoKit
import DoryFirmware
import DoryMachinePC
import DoryVMContracts
import Foundation
@testable import DoryOperations
import XCTest

final class DoryPCRuntimeLaunchEnvelopeTests: XCTestCase {
    private let diskID = try! DoryVirtualDeviceID("system-disk")
    private let installerID = try! DoryVirtualDeviceID("installer-iso")

    func testCanonicalRoundTripPinsPCDBTFirmwareAndPCIStorage() throws {
        let envelope = try makeEnvelope(installer: true)
        let argument = try envelope.encodedArgument()
        let decoded = try DoryPCRuntimeLaunchEnvelope.decodeArgument(argument)
        let resources = try decoded.validatedResources()

        XCTAssertEqual(decoded.platform, .x86_64LinuxV1)
        XCTAssertEqual(decoded.executionResources.tier, .baselineJIT)
        XCTAssertEqual(decoded.executionResources.memoryMB, 4_096)
        XCTAssertEqual(decoded.executionResources.virtualCPUCount, 4)
        XCTAssertEqual(resources.systemDisk.logicalDeviceID, diskID)
        XCTAssertEqual(resources.installerMedia?.logicalDeviceID, installerID)
        XCTAssertEqual(
            decoded.launchPlan.bootDevices.first { $0.kind == .systemDisk }?.pciAddress,
            DoryPCV1ABI.systemDiskPCIAddress
        )
        XCTAssertEqual(
            decoded.launchPlan.bootDevices.first { $0.kind == .removableMedia }?.pciAddress,
            DoryPCV1ABI.removableMediaPCIAddress
        )
        XCTAssertEqual(decoded.inheritedFileDescriptors.map(\.descriptor), [3, 4, 5, 6, 7])
        XCTAssertEqual(resources.variableStoreDirectory.descriptor, 8)
    }

    func testInstalledDiskEnvelopeOmitsInstallerAuthority() throws {
        let envelope = try makeEnvelope(installer: false)
        let resources = try envelope.validatedResources()

        XCTAssertNil(resources.installerMedia)
        XCTAssertEqual(envelope.launchPlan.bootOrder, [diskID.rawValue])
        XCTAssertEqual(envelope.inheritedFileDescriptors.map(\.name), [
            RuntimeLaunchEnvelope.systemDiskSlotName,
            RuntimeLaunchEnvelope.firmwareCodeSlotName,
            RuntimeLaunchEnvelope.variableStoreTemplateSlotName,
            RuntimeLaunchEnvelope.firmwareSBOMSlotName,
        ])
    }

    func testDirectorySharingIsAnAdmittedDoryPCDeviceContract() throws {
        let envelope = try makeEnvelope(directorySharing: true)
        XCTAssertTrue(envelope.devices.directorySharing)
        XCTAssertNoThrow(try envelope.validatedResources())
        XCTAssertEqual(
            try DoryPCRuntimeLaunchEnvelope.decodeArgument(envelope.encodedArgument()).devices
                .directorySharing,
            true
        )
    }

    func testPlatformAndDescriptorSubstitutionFailClosed() throws {
        let envelope = try makeEnvelope(installer: true)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope))
                as? [String: Any]
        )
        var platform = try XCTUnwrap(object["platform"] as? [String: Any])
        platform["machineModel"] = DoryMachineModelIdentity.armVirtV1.rawValue
        object["platform"] = platform
        let substitutedPlatform = try JSONDecoder().decode(
            DoryPCRuntimeLaunchEnvelope.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertThrowsError(try substitutedPlatform.validatedResources()) { error in
            XCTAssertEqual(error as? DoryPCRuntimeLaunchEnvelopeError, .invalidIdentity)
        }

        object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope))
                as? [String: Any]
        )
        var descriptors = try XCTUnwrap(
            object["inheritedFileDescriptors"] as? [[String: Any]]
        )
        descriptors[4]["descriptor"] = RuntimeLaunchEnvelope.systemDiskDescriptor
        object["inheritedFileDescriptors"] = descriptors
        let duplicateDescriptor = try JSONDecoder().decode(
            DoryPCRuntimeLaunchEnvelope.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertThrowsError(try duplicateDescriptor.validatedResources()) { error in
            XCTAssertEqual(
                error as? DoryPCRuntimeLaunchEnvelopeError,
                .invalidDescriptorLayout
            )
        }
    }

    func testInvalidResourcesAndNoncanonicalJSONAreRejected() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(try makeEnvelope()))
                as? [String: Any]
        )
        var resources = try XCTUnwrap(object["executionResources"] as? [String: Any])
        resources["memoryMB"] = 513
        object["executionResources"] = resources
        let invalidResources = try JSONDecoder().decode(
            DoryPCRuntimeLaunchEnvelope.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertThrowsError(try invalidResources.validatedResources()) { error in
            XCTAssertEqual(error as? DoryPCRuntimeLaunchEnvelopeError, .invalidIdentity)
        }

        let canonical = try makeEnvelope().encodedArgument()
        XCTAssertThrowsError(try DoryPCRuntimeLaunchEnvelope.decodeArgument(" \(canonical)")) {
            error in
            XCTAssertEqual(
                error as? DoryPCRuntimeLaunchEnvelopeError,
                .nonCanonicalEncoding
            )
        }
    }

    private func makeEnvelope(
        installer: Bool = false,
        directorySharing: Bool = false
    ) throws -> DoryPCRuntimeLaunchEnvelope {
        let firmware = Data(repeating: 0xA5, count: 4_096)
        let variables = Data("variables".utf8)
        let sbom = Data("sbom".utf8)
        let installerBytes = Data("installer".utf8)
        let manifest = try DoryFirmwareArtifactManifest(
            platform: .pcV1,
            buildIdentifier: "dory-pc-test.1",
            source: DoryFirmwareSourcePin(
                repository: "https://github.com/tianocore/edk2.git",
                revision: String(repeating: "a", count: 40)
            ),
            sourceDateEpoch: 1,
            platformConfigurationSHA256: digest(Data("platform".utf8)),
            toolchainSHA256: digest(Data("toolchain".utf8)),
            firmwareCodeSHA256: digest(firmware),
            firmwareCodeByteCount: UInt64(firmware.count),
            variableStoreTemplateSHA256: digest(variables),
            variableStoreTemplateByteCount: UInt64(variables.count),
            sbomSHA256: digest(sbom),
            secureBootPolicy: .disabled,
            reproducible: true
        )
        let system = try DoryPCUEFIBootDevice(
            logicalID: diskID.rawValue,
            kind: .systemDisk,
            pciAddress: DoryPCV1ABI.systemDiskPCIAddress,
            readOnly: false
        )
        let removable = try DoryPCUEFIBootDevice(
            logicalID: installerID.rawValue,
            kind: .removableMedia,
            pciAddress: DoryPCV1ABI.removableMediaPCIAddress,
            readOnly: true
        )
        let devices = installer ? [system, removable] : [system]
        let plan = try DoryPCUEFILaunchPlan(
            firmware: manifest,
            variableStoreGeneration: 1,
            bootDevices: devices,
            bootOrder: installer ? [installerID.rawValue, diskID.rawValue] : [diskID.rawValue]
        )
        return .resolvedUEFI(
            machineID: "x86-linux",
            operationID: UUID(uuidString: "7ca00e75-0430-4aae-b13f-9c30b3d36389")!,
            resolvedPlanSHA256: String(repeating: "b", count: 64),
            planRevision: 1,
            executionComponentBuildIdentifier: "dory-dbt-test.1",
            virtualHardwareABIVersion: 1,
            graphics: .software,
            devices: DoryVirtualMachineDeviceCapabilityRequest(
                networkInterface: .stable(machineID: "x86-linux"),
                display: .init(widthPixels: 1_280, heightPixels: 800),
                keyboard: true,
                pointer: true,
                directorySharing: directorySharing
            ),
            portForwards: [],
            executionResources: .init(
                memoryMB: 4_096,
                virtualCPUCount: 4,
                tier: .baselineJIT
            ),
            systemDiskCapacityBytes: 16 * 1_024 * 1_024 * 1_024,
            systemDiskLogicalID: diskID,
            launchPlan: plan,
            firmwareSBOMByteCount: UInt64(sbom.count),
            installerMediaByteCount: installer ? UInt64(installerBytes.count) : nil,
            installerMediaSHA256: installer ? digest(installerBytes) : nil,
            installerMediaLogicalID: installer ? installerID : nil
        )
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
