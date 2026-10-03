import CryptoKit
import Darwin
import DoryFirmware
import DoryMachinePC
import DoryRendererWorkerWireContracts
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

    func testOrderedMultipleDisplaysSurviveTheLaunchEnvelope() throws {
        let displays: [DoryVirtualMachineDisplayCapabilityRequest] = [
            .init(id: "display-0", widthPixels: 1_280, heightPixels: 800),
            .init(id: "display-1", widthPixels: 1_920, heightPixels: 1_080),
        ]
        let envelope = try makeEnvelope(displays: displays)

        XCTAssertNoThrow(try envelope.validatedResources())
        XCTAssertEqual(
            try DoryPCRuntimeLaunchEnvelope.decodeArgument(envelope.encodedArgument())
                .devices.displays,
            displays
        )
    }

    func testSparseAndExcessDisplayTopologiesAreRejected() throws {
        let first = DoryVirtualMachineDisplayCapabilityRequest(
            id: "display-0", widthPixels: 1_280, heightPixels: 800
        )
        let sparse = try makeEnvelope(displays: [
            first,
            .init(id: "display-2", widthPixels: 1_920, heightPixels: 1_080),
        ])
        XCTAssertThrowsError(try sparse.validatedResources()) { error in
            XCTAssertEqual(error as? DoryPCRuntimeLaunchEnvelopeError, .invalidDeviceContract)
        }

        let excess = try makeEnvelope(displays: (0...16).map {
            .init(id: "display-\($0)", widthPixels: 1_280, heightPixels: 800)
        })
        XCTAssertThrowsError(try excess.validatedResources()) { error in
            XCTAssertEqual(error as? DoryPCRuntimeLaunchEnvelopeError, .invalidDeviceContract)
        }
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

    func testPCFaultHandoffAdmitsOnlyAuthenticatedRendererScopeAndClosesDescriptor() throws {
        let envelope = try makeEnvelope(accelerated: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let grant = DoryRuntimeQualificationFaultAuthority(
            machineID: envelope.machineID, operationID: envelope.operationID,
            resolvedPlanSHA256: envelope.resolvedPlanSHA256,
            campaignManifestSHA256: String(repeating: "d", count: 64),
            expiresAt: now.addingTimeInterval(60),
            policy: .init(permittedFaults: [.rendererWorkerCrash])
        )
        let channel = try DoryRuntimeQualificationFaultHandoff.makeChannel(authority: grant)
        defer { withExtendedLifetime(channel) {} }
        let fd = try channel.takeDescriptor()
        var authenticated = false
        let received = try DoryRuntimeQualificationFaultHandoff.receive(
            descriptor: fd, envelope: envelope, now: now, authenticate: { _ in authenticated = true }
        )
        XCTAssertTrue(authenticated)
        XCTAssertEqual(received, grant)
        XCTAssertEqual(fcntl(fd, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
    }

    func testPCFaultHandoffRejectsUnsignedSenderSoftwareGraphicsAndBroaderARMGrants() throws {
        let envelope = try makeEnvelope(accelerated: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for variant in ["unsigned", "software", "block", "memory", "mixed", "machine", "operation", "plan", "expired"] {
            let faults: [DoryRuntimeQualificationFaultKind]
            switch variant {
            case "block": faults = [.blockFullFlushNoSpace]
            case "memory": faults = [.mappedPageRepeatedPermission]
            case "mixed": faults = [.blockFullFlushNoSpace, .rendererWorkerCrash]
            default: faults = [.rendererWorkerCrash]
            }
            let grant = DoryRuntimeQualificationFaultAuthority(
                machineID: variant == "machine" ? "other-pc" : envelope.machineID,
                operationID: variant == "operation" ? UUID() : envelope.operationID,
                resolvedPlanSHA256: variant == "plan" ? String(repeating: "e", count: 64) : envelope.resolvedPlanSHA256,
                campaignManifestSHA256: String(repeating: "d", count: 64),
                expiresAt: variant == "expired" ? now : now.addingTimeInterval(60),
                policy: .init(permittedFaults: faults)
            )
            let channel = try DoryRuntimeQualificationFaultHandoff.makeChannel(authority: grant)
            defer { withExtendedLifetime(channel) {} }
            let fd = try channel.takeDescriptor()
            XCTAssertThrowsError(try DoryRuntimeQualificationFaultHandoff.receive(
                descriptor: fd, envelope: variant == "software" ? makeEnvelope() : envelope, now: now,
                authenticate: { descriptor in
                    if variant == "unsigned" {
                        try DoryRuntimeQualificationFaultHandoff.authenticateDaemon(descriptor: descriptor)
                    }
                }
            ), variant) { error in
                XCTAssertEqual(error as? DoryRuntimeQualificationFaultError,
                               variant == "expired" ? .expired : .unauthorized, variant)
            }
            XCTAssertEqual(fcntl(fd, F_GETFD), -1, variant)
            XCTAssertEqual(errno, EBADF, variant)
        }
    }

    private func makeEnvelope(
        installer: Bool = false,
        directorySharing: Bool = false,
        displays: [DoryVirtualMachineDisplayCapabilityRequest]? = nil,
        accelerated: Bool = false
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
            graphics: accelerated ? .hardwareAccelerated3D : .software,
            rendererProducerFenceContract: accelerated ? .doryPCX8664LinuxVirGL2PrepareFBV1 : nil,
            devices: DoryVirtualMachineDeviceCapabilityRequest(
                networkInterface: .stable(machineID: "x86-linux"),
                displays: displays ?? [.init(widthPixels: 1_280, heightPixels: 800)],
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
            installerMediaLogicalID: installer ? installerID : nil,
            rendererBootstrapByteCount: accelerated ? UInt64(DoryRendererWorkerBootstrapCodec.fixedByteCount) : nil,
            rendererBootstrapSHA256: accelerated ? String(repeating: "f", count: 64) : nil
        )
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
