import DoryVMContracts
import Foundation
@testable import DoryOperations
import XCTest

final class RuntimeLaunchEnvelopeTests: XCTestCase {
    private static let machineID = "linux-workspace"
    private static let topologySystemDiskID = try! DoryVirtualDeviceID("topology-root-alpha")
    private static let planDigest = String(repeating: "b", count: 64)
    private static let kernelDigest = String(repeating: "c", count: 64)
    private static let initrdDigest = String(repeating: "d", count: 64)
    private static let rendererBootstrapDigest = String(repeating: "e", count: 64)
    private static let kernelByteCount: UInt64 = 16 * 1_024 * 1_024
    private static let initrdByteCount: UInt64 = 32 * 1_024 * 1_024
    private static let diskByteCount: UInt64 = 8_589_934_592

    func testCanonicalTwoSlotRoundTripUsesFixedAuthorityLayout() throws {
        let envelope = makeEnvelope()
        let decoded = try canonicalRoundTrip(envelope)
        let resources = try decoded.validatedResolvedRawHVResources()

        XCTAssertEqual(decoded.schemaVersion, RuntimeLaunchEnvelope.currentSchemaVersion)
        XCTAssertEqual(decoded.schemaVersion, 5)
        XCTAssertEqual(decoded.executionResources.memoryMB, 8_192)
        XCTAssertEqual(decoded.executionResources.virtualCPUCount, 4)
        XCTAssertEqual(decoded.executionResources.systemDiskQueueCount, 4)
        XCTAssertEqual(decoded.executionResources.schedulingPolicyRevision, 1)
        XCTAssertEqual(decoded.inheritedFileDescriptors.map(\.name), [
            RuntimeLaunchEnvelope.systemDiskSlotName,
            RuntimeLaunchEnvelope.linuxKernelSlotName,
        ])
        XCTAssertEqual(decoded.inheritedFileDescriptors.map(\.descriptor), [
            RuntimeLaunchEnvelope.systemDiskDescriptor,
            RuntimeLaunchEnvelope.linuxKernelDescriptor,
        ])
        XCTAssertEqual(decoded.inheritedFileDescriptors.map(\.access), [
            .readWrite,
            .readOnly,
        ])
        XCTAssertEqual(resources.systemDisk.byteCount, Self.diskByteCount)
        XCTAssertEqual(resources.systemDisk.contentSHA256, nil)
        XCTAssertEqual(resources.systemDisk.logicalDeviceID, Self.topologySystemDiskID)
        XCTAssertEqual(resources.linuxKernel.byteCount, Self.kernelByteCount)
        XCTAssertEqual(resources.linuxKernel.contentSHA256, Self.kernelDigest)
        XCTAssertEqual(resources.linuxKernel.logicalDeviceID, nil)
        XCTAssertNil(resources.linuxInitrd)
        XCTAssertNil(resources.rendererBootstrap)
        XCTAssertEqual(decoded.linuxDirectBoot.profile, .managedKernel)
        XCTAssertEqual(decoded.linuxDirectBoot.rootDevice, "/dev/vda")
    }

    func testCanonicalThreeSlotRoundTripUsesFixedAuthorityLayout() throws {
        let envelope = makeEnvelope(
            genericGuest: true,
            initrdByteCount: Self.initrdByteCount,
            initrdDigest: Self.initrdDigest
        )
        let decoded = try canonicalRoundTrip(envelope)
        let resources = try decoded.validatedResolvedRawHVResources()

        XCTAssertEqual(decoded.inheritedFileDescriptors.map(\.name), [
            RuntimeLaunchEnvelope.systemDiskSlotName,
            RuntimeLaunchEnvelope.linuxKernelSlotName,
            RuntimeLaunchEnvelope.linuxInitrdSlotName,
        ])
        XCTAssertEqual(decoded.inheritedFileDescriptors.map(\.descriptor), [
            RuntimeLaunchEnvelope.systemDiskDescriptor,
            RuntimeLaunchEnvelope.linuxKernelDescriptor,
            RuntimeLaunchEnvelope.linuxInitrdDescriptor,
        ])
        XCTAssertEqual(decoded.inheritedFileDescriptors.map(\.access), [
            .readWrite,
            .readOnly,
            .readOnly,
        ])
        XCTAssertEqual(resources.linuxInitrd?.byteCount, Self.initrdByteCount)
        XCTAssertEqual(resources.linuxInitrd?.contentSHA256, Self.initrdDigest)
        XCTAssertEqual(resources.linuxInitrd?.logicalDeviceID, nil)
        XCTAssertEqual(decoded.linuxDirectBoot.profile, .installedLinuxBundle)
        XCTAssertEqual(decoded.linuxDirectBoot.rootDevice, "/dev/vda2")
        XCTAssertTrue(decoded.linuxDirectBoot.genericGuest)
        XCTAssertNil(resources.rendererBootstrap)
    }

    func testHardware3DRequiresOneExactRendererBootstrapAuthority() throws {
        let envelope = makeEnvelope(
            graphics: .hardwareAccelerated3D,
            rendererBootstrapByteCount: 336,
            rendererBootstrapDigest: Self.rendererBootstrapDigest
        )
        let decoded = try canonicalRoundTrip(envelope)
        let resources = try decoded.validatedResolvedRawHVResources()

        XCTAssertEqual(decoded.inheritedFileDescriptors.map(\.name), [
            RuntimeLaunchEnvelope.systemDiskSlotName,
            RuntimeLaunchEnvelope.linuxKernelSlotName,
            RuntimeLaunchEnvelope.rendererBootstrapSlotName,
        ])
        XCTAssertEqual(
            resources.rendererBootstrap?.descriptor,
            RuntimeLaunchEnvelope.rendererBootstrapDescriptor
        )
        XCTAssertEqual(resources.rendererBootstrap?.byteCount, 336)
        XCTAssertEqual(
            resources.rendererBootstrap?.contentSHA256,
            Self.rendererBootstrapDigest
        )
        XCTAssertEqual(resources.rendererBootstrap?.access, .readOnly)
        XCTAssertNil(resources.rendererBootstrap?.logicalDeviceID)

        assertValidationError(
            makeEnvelope(graphics: .hardwareAccelerated3D),
            .invalidRendererBootstrapAuthority
        )
        assertValidationError(
            makeEnvelope(
                graphics: .hardwareAccelerated3D,
                rendererBootstrapByteCount: 335,
                rendererBootstrapDigest: Self.rendererBootstrapDigest
            ),
            .invalidRendererBootstrapAuthority
        )
        assertValidationError(
            makeEnvelope(
                rendererBootstrapByteCount: 336,
                rendererBootstrapDigest: Self.rendererBootstrapDigest
            ),
            .invalidRendererBootstrapAuthority
        )
    }

    func testSystemDiskLogicalIDMustMatchIndependentTopologyIdentity() throws {
        let envelope = makeEnvelope()
        let topologyDisk = try XCTUnwrap(
            envelope.rawHVVirtualHardwareTopology.occupiedSlots.first {
                $0.role == .systemDisk
            }
        )
        XCTAssertEqual(topologyDisk.logicalID, Self.topologySystemDiskID)
        XCTAssertNotEqual(topologyDisk.logicalID.rawValue, Self.machineID)
        XCTAssertNotEqual(
            topologyDisk.logicalID.rawValue,
            RuntimeLaunchEnvelope.systemDiskSlotName
        )
        XCTAssertNoThrow(try envelope.validatedResolvedRawHVResources())

        assertValidationError(
            makeEnvelope(
                systemDiskLogicalID: try! DoryVirtualDeviceID("different-root-id")
            ),
            .invalidSystemDiskAccess
        )

        let slots = envelope.inheritedFileDescriptors
        let diskWithoutIdentity = RuntimeLaunchEnvelope.InheritedFileDescriptorSlot(
            name: RuntimeLaunchEnvelope.systemDiskSlotName,
            descriptor: RuntimeLaunchEnvelope.systemDiskDescriptor,
            access: .readWrite,
            byteCount: Self.diskByteCount
        )
        assertValidationError(
            replacingSlots(in: envelope, with: [diskWithoutIdentity, slots[1]]),
            .invalidSystemDiskAccess
        )
    }

    func testRejectsStaleFixedAndNetworkTopologyLogicalIDs() {
        assertValidationError(
            makeEnvelope(
                topologyGraphicsLogicalID: try! DoryVirtualDeviceID("graphics")
            ),
            .invalidVirtualHardwareTopology
        )
        assertValidationError(
            makeEnvelope(
                topologyNetworkLogicalID: try! DoryVirtualDeviceID("network")
            ),
            .invalidVirtualHardwareTopology
        )
    }

    func testRejectsMissingExtraAndDuplicateSlots() {
        let twoSlot = makeEnvelope()
        let disk = twoSlot.inheritedFileDescriptors[0]
        let kernel = twoSlot.inheritedFileDescriptors[1]

        assertValidationError(
            replacingSlots(in: twoSlot, with: [disk]),
            .invalidResolvedRawHVSlots
        )

        let threeSlot = makeEnvelope(
            initrdByteCount: Self.initrdByteCount,
            initrdDigest: Self.initrdDigest
        )
        let extra = RuntimeLaunchEnvelope.InheritedFileDescriptorSlot(
            name: "extraAuthority",
            descriptor: 6,
            access: .readOnly,
            byteCount: 1,
            contentSHA256: String(repeating: "e", count: 64)
        )
        assertValidationError(
            replacingSlots(
                in: threeSlot,
                with: threeSlot.inheritedFileDescriptors + [extra]
            ),
            .invalidResolvedRawHVSlots
        )

        let duplicateName = RuntimeLaunchEnvelope.InheritedFileDescriptorSlot(
            name: RuntimeLaunchEnvelope.systemDiskSlotName,
            descriptor: RuntimeLaunchEnvelope.linuxKernelDescriptor,
            access: .readOnly,
            byteCount: Self.kernelByteCount,
            contentSHA256: Self.kernelDigest
        )
        assertValidationError(
            replacingSlots(in: twoSlot, with: [disk, duplicateName]),
            .duplicateSlotName(RuntimeLaunchEnvelope.systemDiskSlotName)
        )

        let duplicateDescriptor = RuntimeLaunchEnvelope.InheritedFileDescriptorSlot(
            name: RuntimeLaunchEnvelope.linuxKernelSlotName,
            descriptor: RuntimeLaunchEnvelope.systemDiskDescriptor,
            access: .readOnly,
            byteCount: Self.kernelByteCount,
            contentSHA256: Self.kernelDigest
        )
        assertValidationError(
            replacingSlots(in: twoSlot, with: [disk, duplicateDescriptor]),
            .duplicateDescriptor(RuntimeLaunchEnvelope.systemDiskDescriptor)
        )

        assertValidationError(
            replacingSlots(in: twoSlot, with: [kernel, disk]),
            .invalidResolvedRawHVSlots
        )
    }

    func testRejectsWrongFixedNamesDescriptorsAndAccess() {
        let envelope = makeEnvelope()
        let disk = envelope.inheritedFileDescriptors[0]
        let kernel = envelope.inheritedFileDescriptors[1]

        let renamedKernel = RuntimeLaunchEnvelope.InheritedFileDescriptorSlot(
            name: "renamedKernel",
            descriptor: RuntimeLaunchEnvelope.linuxKernelDescriptor,
            access: .readOnly,
            byteCount: Self.kernelByteCount,
            contentSHA256: Self.kernelDigest
        )
        assertValidationError(
            replacingSlots(in: envelope, with: [disk, renamedKernel]),
            .invalidResolvedRawHVSlots
        )

        let wrongDiskDescriptor = RuntimeLaunchEnvelope.InheritedFileDescriptorSlot(
            name: RuntimeLaunchEnvelope.systemDiskSlotName,
            descriptor: 6,
            access: .readWrite,
            byteCount: Self.diskByteCount,
            logicalDeviceID: Self.topologySystemDiskID
        )
        assertValidationError(
            replacingSlots(in: envelope, with: [wrongDiskDescriptor, kernel]),
            .invalidDescriptor(6)
        )

        let readOnlyDisk = RuntimeLaunchEnvelope.InheritedFileDescriptorSlot(
            name: RuntimeLaunchEnvelope.systemDiskSlotName,
            descriptor: RuntimeLaunchEnvelope.systemDiskDescriptor,
            access: .readOnly,
            byteCount: Self.diskByteCount,
            logicalDeviceID: Self.topologySystemDiskID
        )
        assertValidationError(
            replacingSlots(in: envelope, with: [readOnlyDisk, kernel]),
            .invalidSystemDiskAccess
        )

        let writableKernel = RuntimeLaunchEnvelope.InheritedFileDescriptorSlot(
            name: RuntimeLaunchEnvelope.linuxKernelSlotName,
            descriptor: RuntimeLaunchEnvelope.linuxKernelDescriptor,
            access: .readWrite,
            byteCount: Self.kernelByteCount,
            contentSHA256: Self.kernelDigest
        )
        assertValidationError(
            replacingSlots(in: envelope, with: [disk, writableKernel]),
            .invalidLinuxKernelAuthority
        )
    }

    func testRequiresValidLowercasePlanAndBootBlobDigests() throws {
        XCTAssertNoThrow(try makeEnvelope().validatedResolvedRawHVResources())
        XCTAssertNoThrow(try makeEnvelope(
            genericGuest: true,
            initrdByteCount: Self.initrdByteCount,
            initrdDigest: Self.initrdDigest
        ).validatedResolvedRawHVResources())

        assertValidationError(
            replacingPlanDigest(
                in: makeEnvelope(),
                with: String(repeating: "A", count: 64)
            ),
            .invalidPlanSHA256
        )
        assertValidationError(
            replacingPlanDigest(in: makeEnvelope(), with: String(repeating: "a", count: 63)),
            .invalidPlanSHA256
        )
        assertValidationError(
            makeEnvelope(kernelDigest: String(repeating: "C", count: 64)),
            .invalidLinuxKernelAuthority
        )
        assertValidationError(
            makeEnvelope(
                initrdByteCount: Self.initrdByteCount,
                initrdDigest: String(repeating: "D", count: 64)
            ),
            .invalidLinuxInitrdAuthority
        )
    }

    func testRejectsInvalidComputeAndSystemDiskQueueAuthority() {
        for executionResources in [
            RuntimeLaunchEnvelope.RawHVExecutionResources(
                memoryMB: 1_023,
                virtualCPUCount: 4,
                systemDiskQueueCount: 4
            ),
            RuntimeLaunchEnvelope.RawHVExecutionResources(
                memoryMB: 8_192,
                virtualCPUCount: 0,
                systemDiskQueueCount: 1
            ),
            RuntimeLaunchEnvelope.RawHVExecutionResources(
                memoryMB: 8_192,
                virtualCPUCount: 4,
                systemDiskQueueCount: 0
            ),
            RuntimeLaunchEnvelope.RawHVExecutionResources(
                memoryMB: 8_192,
                virtualCPUCount: 4,
                systemDiskQueueCount: 5
            ),
            RuntimeLaunchEnvelope.RawHVExecutionResources(
                memoryMB: 8_192,
                virtualCPUCount: 4,
                systemDiskQueueCount: 4,
                schedulingPolicyRevision: 2
            ),
        ] {
            assertValidationError(
                makeEnvelope(executionResources: executionResources),
                .invalidExecutionResources
            )
        }
    }

    func testRejectsZeroAndOversizedKernelOrInitrd() {
        assertValidationError(
            makeEnvelope(kernelByteCount: 0),
            .invalidCapacity(RuntimeLaunchEnvelope.linuxKernelSlotName)
        )
        assertValidationError(
            makeEnvelope(
                kernelByteCount: RuntimeLaunchEnvelope.maximumLinuxKernelBytes + 1
            ),
            .invalidLinuxKernelAuthority
        )
        assertValidationError(
            makeEnvelope(initrdByteCount: 0, initrdDigest: Self.initrdDigest),
            .invalidCapacity(RuntimeLaunchEnvelope.linuxInitrdSlotName)
        )
        assertValidationError(
            makeEnvelope(
                initrdByteCount: RuntimeLaunchEnvelope.maximumLinuxInitrdBytes + 1,
                initrdDigest: Self.initrdDigest
            ),
            .invalidLinuxInitrdAuthority
        )
    }

    func testDirectBootProfileRequiresMatchingRootAndInitrd() throws {
        assertValidationError(
            makeEnvelope(genericGuest: true),
            .invalidLinuxDirectBoot
        )
        let installedBundle = makeEnvelope(
            genericGuest: true,
            initrdByteCount: Self.initrdByteCount,
            initrdDigest: Self.initrdDigest
        )
        XCTAssertEqual(installedBundle.linuxDirectBoot.profile, .installedLinuxBundle)
        XCTAssertEqual(installedBundle.linuxDirectBoot.rootDevice, "/dev/vda2")
        XCTAssertNoThrow(try installedBundle.validatedResolvedRawHVResources())

        assertValidationError(
            makeEnvelope(rootDevice: "/dev/vda2"),
            .invalidLinuxDirectBoot
        )
        assertValidationError(
            makeEnvelope(
                rootDevice: "/dev/vda",
                genericGuest: true,
                initrdByteCount: Self.initrdByteCount,
                initrdDigest: Self.initrdDigest
            ),
            .invalidLinuxDirectBoot
        )
        assertValidationError(
            makeEnvelope(
                initrdByteCount: Self.initrdByteCount,
                initrdDigest: Self.initrdDigest
            ),
            .invalidLinuxDirectBoot
        )
    }

    func testRejectsInvalidLinuxRootDevice() throws {
        XCTAssertNoThrow(try makeEnvelope(rootDevice: "/dev/vda").validatedResolvedRawHVResources())
        XCTAssertNoThrow(try makeEnvelope(
            rootDevice: "/dev/vdz123",
            genericGuest: true,
            initrdByteCount: Self.initrdByteCount,
            initrdDigest: Self.initrdDigest
        ).validatedResolvedRawHVResources())

        for rootDevice in [
            "", "/dev/sda2", "/dev/vdA2", "/dev/vda0", "/dev/vda01", "/dev/vda-1",
        ] {
            assertValidationError(
                makeEnvelope(rootDevice: rootDevice),
                .invalidLinuxDirectBoot
            )
        }
    }

    func testDecodeRejectsUnknownAndNoncanonicalJSON() throws {
        let canonical = try makeEnvelope().encodedArgument()
        let data = try XCTUnwrap(canonical.data(using: .utf8))
        var unknownRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        unknownRoot["unexpectedAuthority"] = true
        let unknownRootJSON = try canonicalJSONString(unknownRoot)

        var unknownNested = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var directBoot = try XCTUnwrap(unknownNested["linuxDirectBoot"] as? [String: Any])
        directBoot["unexpectedAuthority"] = true
        unknownNested["linuxDirectBoot"] = directBoot
        let unknownNestedJSON = try canonicalJSONString(unknownNested)

        let prettyData = try JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: data),
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let pretty = try XCTUnwrap(String(data: prettyData, encoding: .utf8))

        for value in [" \(canonical)", unknownRootJSON, unknownNestedJSON, pretty] {
            XCTAssertThrowsError(
                try RuntimeLaunchEnvelope.decodeResolvedRawHVArgument(value)
            ) { error in
                XCTAssertEqual(error as? RuntimeLaunchEnvelopeError, .nonCanonicalEncoding)
            }
        }
    }

    func testDecodeRejectsOversizedArgumentBeforeJSONParsing() {
        let oversized = String(
            repeating: "x",
            count: RuntimeLaunchEnvelope.maximumEncodedArgumentBytes + 1
        )
        XCTAssertThrowsError(
            try RuntimeLaunchEnvelope.decodeResolvedRawHVArgument(oversized)
        ) { error in
            XCTAssertEqual(
                error as? RuntimeLaunchEnvelopeError,
                .argumentTooLarge(RuntimeLaunchEnvelope.maximumEncodedArgumentBytes + 1)
            )
        }
    }

    func testRejectsUnsafeIdentityAndZeroOperationSentinel() {
        assertValidationError(
            makeEnvelope(machineID: "unsafe\nmachine"),
            .invalidIdentity
        )
        assertValidationError(
            makeEnvelope(buildIdentifier: "runtime build"),
            .invalidIdentity
        )
        assertValidationError(
            makeEnvelope(
                operationID: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000000"
                )!
            ),
            .invalidIdentity
        )
    }

    private func canonicalRoundTrip(
        _ envelope: RuntimeLaunchEnvelope
    ) throws -> RuntimeLaunchEnvelope {
        let encoded = try envelope.encodedArgument()
        XCTAssertFalse(encoded.contains("\n"))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(encoded.data(using: .utf8), try encoder.encode(envelope))

        let decoded = try RuntimeLaunchEnvelope.decodeResolvedRawHVArgument(encoded)
        XCTAssertEqual(decoded, envelope)
        return decoded
    }

    private func makeEnvelope(
        machineID: String = RuntimeLaunchEnvelopeTests.machineID,
        operationID: UUID = UUID(
            uuidString: "22222222-2222-2222-2222-222222222222"
        )!,
        buildIdentifier: String = "raw-runtime-1",
        topologySystemDiskLogicalID: DoryVirtualDeviceID = RuntimeLaunchEnvelopeTests.topologySystemDiskID,
        systemDiskLogicalID: DoryVirtualDeviceID = RuntimeLaunchEnvelopeTests.topologySystemDiskID,
        topologyGraphicsLogicalID: DoryVirtualDeviceID? = nil,
        topologyNetworkLogicalID: DoryVirtualDeviceID? = nil,
        rootDevice: String? = nil,
        genericGuest: Bool = false,
        kernelByteCount: UInt64 = RuntimeLaunchEnvelopeTests.kernelByteCount,
        kernelDigest: String = RuntimeLaunchEnvelopeTests.kernelDigest,
        initrdByteCount: UInt64? = nil,
        initrdDigest: String? = nil,
        graphics: DoryGraphicsAccelerationLevel = .software,
        rendererBootstrapByteCount: UInt64? = nil,
        rendererBootstrapDigest: String? = nil,
        executionResources: RuntimeLaunchEnvelope.RawHVExecutionResources = .production(
            memoryMB: 8_192,
            virtualCPUCount: 4
        )
    ) -> RuntimeLaunchEnvelope {
        let devices = makeDevices()
        return RuntimeLaunchEnvelope.resolvedRawHV(
            machineID: machineID,
            operationID: operationID,
            resolvedPlanSHA256: Self.planDigest,
            planRevision: 9,
            backendRuntimeBuildIdentifier: buildIdentifier,
            virtualHardwareABIVersion: 1,
            rawHVVirtualHardwareTopology: makeTopology(
                systemDiskLogicalID: topologySystemDiskLogicalID,
                networkInterface: devices.networkInterface!,
                graphicsLogicalID: topologyGraphicsLogicalID,
                networkLogicalID: topologyNetworkLogicalID
            ),
            graphics: graphics,
            devices: devices,
            portForwards: [],
            executionResources: executionResources,
            systemDiskCapacityBytes: Self.diskByteCount,
            systemDiskLogicalID: systemDiskLogicalID,
            linuxRootDevice: rootDevice ?? (genericGuest ? "/dev/vda2" : "/dev/vda"),
            genericGuest: genericGuest,
            linuxKernelByteCount: kernelByteCount,
            linuxKernelSHA256: kernelDigest,
            linuxInitrdByteCount: initrdByteCount,
            linuxInitrdSHA256: initrdDigest,
            rendererBootstrapByteCount: rendererBootstrapByteCount,
            rendererBootstrapSHA256: rendererBootstrapDigest
        )
    }

    private func replacingSlots(
        in envelope: RuntimeLaunchEnvelope,
        with slots: [RuntimeLaunchEnvelope.InheritedFileDescriptorSlot]
    ) -> RuntimeLaunchEnvelope {
        RuntimeLaunchEnvelope(
            kind: envelope.kind,
            schemaVersion: envelope.schemaVersion,
            machineID: envelope.machineID,
            operationID: envelope.operationID,
            resolvedPlanSHA256: envelope.resolvedPlanSHA256,
            planRevision: envelope.planRevision,
            backendIdentity: envelope.backendIdentity,
            backendRuntimeBuildIdentifier: envelope.backendRuntimeBuildIdentifier,
            virtualHardwareABIVersion: envelope.virtualHardwareABIVersion,
            rawHVVirtualHardwareTopology: envelope.rawHVVirtualHardwareTopology,
            graphics: envelope.graphics,
            devices: envelope.devices,
            portForwards: envelope.portForwards,
            executionResources: envelope.executionResources,
            linuxDirectBoot: envelope.linuxDirectBoot,
            inheritedFileDescriptors: slots
        )
    }

    private func replacingPlanDigest(
        in envelope: RuntimeLaunchEnvelope,
        with digest: String
    ) -> RuntimeLaunchEnvelope {
        RuntimeLaunchEnvelope(
            kind: envelope.kind,
            schemaVersion: envelope.schemaVersion,
            machineID: envelope.machineID,
            operationID: envelope.operationID,
            resolvedPlanSHA256: digest,
            planRevision: envelope.planRevision,
            backendIdentity: envelope.backendIdentity,
            backendRuntimeBuildIdentifier: envelope.backendRuntimeBuildIdentifier,
            virtualHardwareABIVersion: envelope.virtualHardwareABIVersion,
            rawHVVirtualHardwareTopology: envelope.rawHVVirtualHardwareTopology,
            graphics: envelope.graphics,
            devices: envelope.devices,
            portForwards: envelope.portForwards,
            executionResources: envelope.executionResources,
            linuxDirectBoot: envelope.linuxDirectBoot,
            inheritedFileDescriptors: envelope.inheritedFileDescriptors
        )
    }

    private func makeTopology(
        systemDiskLogicalID: DoryVirtualDeviceID,
        networkInterface: DoryVirtualMachineNetworkInterfaceCapabilityRequest,
        graphicsLogicalID: DoryVirtualDeviceID?,
        networkLogicalID: DoryVirtualDeviceID?
    ) -> DoryRawHVVirtualHardwareTopology {
        let canonicalNetworkLogicalID = try! DoryVirtualDeviceID.derived(
            namespace: .network,
            stableID: networkInterface.id
        )
        return try! DoryRawHVVirtualHardwareTopologyReconciler.reconcile(
            requestedDevices: [
                DoryRawHVVirtualDeviceRequest(
                    logicalID: systemDiskLogicalID,
                    role: .systemDisk
                ),
                DoryRawHVVirtualDeviceRequest(
                    logicalID: graphicsLogicalID ?? fixedLogicalID(for: .graphics),
                    role: .graphics
                ),
                DoryRawHVVirtualDeviceRequest(
                    logicalID: fixedLogicalID(for: .entropy),
                    role: .entropy
                ),
                DoryRawHVVirtualDeviceRequest(
                    logicalID: fixedLogicalID(for: .balloon),
                    role: .balloon
                ),
                DoryRawHVVirtualDeviceRequest(
                    logicalID: fixedLogicalID(for: .vsock),
                    role: .vsock
                ),
                DoryRawHVVirtualDeviceRequest(
                    logicalID: networkLogicalID ?? canonicalNetworkLogicalID,
                    role: .network
                ),
            ]
        )
    }

    private func fixedLogicalID(
        for role: DoryVirtualDeviceRole
    ) -> DoryVirtualDeviceID {
        try! DoryVirtualDeviceID("rawhv-\(role.rawValue)")
    }

    private func makeDevices() -> DoryVirtualMachineDeviceCapabilityRequest {
        DoryVirtualMachineDeviceCapabilityRequest(
            networkInterface: .stable(machineID: Self.machineID),
            displays: [
                DoryVirtualMachineDisplayCapabilityRequest(
                    widthPixels: 1_920,
                    heightPixels: 1_080
                ),
            ]
        )
    }

    private func canonicalJSONString(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func assertValidationError(
        _ envelope: RuntimeLaunchEnvelope,
        _ expected: RuntimeLaunchEnvelopeError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try envelope.validatedResolvedRawHVResources(),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? RuntimeLaunchEnvelopeError,
                expected,
                file: file,
                line: line
            )
        }
    }
}
