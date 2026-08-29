import DoryOperations
import DoryVMContracts
import Testing
@testable import dory_hv

@Suite struct RawHVVirtualHardwareAttachmentPlanTests {
    @Test func assignmentsFollowAuthorizedSlotsNotMaterializationOrder() throws {
        let topology = try DoryRawHVVirtualHardwareTopology(occupiedSlots: [
            try .init(logicalID: "system", role: .systemDisk, mmioSlot: 0),
            try .init(logicalID: "graphics", role: .graphics, mmioSlot: 1),
            try .init(logicalID: "share-b", role: .directoryShare, mmioSlot: 23),
            try .init(logicalID: "share-a", role: .directoryShare, mmioSlot: 27),
        ])
        let materialized = topology.occupiedSlots.reversed().map {
            DoryRawHVVirtualDeviceRequest(logicalID: $0.logicalID, role: $0.role)
        }

        let assignments = try RawHVVirtualHardwareAttachmentPlan.assignments(
            topology: topology,
            materializedDevices: materialized
        )

        #expect(assignments.map(\.mmioSlot) == [0, 1, 23, 27])
        #expect(assignments.map(\.request.logicalID.rawValue)
            == ["system", "graphics", "share-b", "share-a"])
    }

    @Test func missingSubstitutedAndDuplicateFunctionsFailClosed() throws {
        let topology = try DoryRawHVVirtualHardwareTopology(occupiedSlots: [
            try .init(logicalID: "system", role: .systemDisk, mmioSlot: 0),
            try .init(logicalID: "network", role: .network, mmioSlot: 8),
        ])
        let system = DoryRawHVVirtualDeviceRequest(
            logicalID: try DoryVirtualDeviceID("system"),
            role: .systemDisk
        )
        let network = DoryRawHVVirtualDeviceRequest(
            logicalID: try DoryVirtualDeviceID("network"),
            role: .network
        )
        #expect(throws: RawHVVirtualHardwareAttachmentPlanError.self) {
            _ = try RawHVVirtualHardwareAttachmentPlan.assignments(
                topology: topology,
                materializedDevices: [system]
            )
        }
        #expect(throws: RawHVVirtualHardwareAttachmentPlanError.self) {
            _ = try RawHVVirtualHardwareAttachmentPlan.assignments(
                topology: topology,
                materializedDevices: [system, system, network]
            )
        }
        #expect(throws: RawHVVirtualHardwareAttachmentPlanError.self) {
            _ = try RawHVVirtualHardwareAttachmentPlan.assignments(
                topology: topology,
                materializedDevices: [
                    system,
                    DoryRawHVVirtualDeviceRequest(
                        logicalID: network.logicalID,
                        role: .directoryShare
                    ),
                ]
            )
        }
    }

    @Test func resolvedPreflightDerivesCanonicalIdentitiesWithoutConsultingTopology() throws {
        let devices = resolvedDevices()
        let systemDiskID = try DoryVirtualDeviceID("system-disk-v2")
        let expected = try RawHVVirtualHardwareAttachmentPlan.expectedResolvedDevices(
            systemDiskLogicalID: systemDiskID,
            resolvedDevices: devices,
            networkStableID: try #require(devices.networkInterface).id,
            directoryShareStableIDs: ["workspace"]
        )
        let topology = try DoryRawHVVirtualHardwareTopologyReconciler.reconcile(
            requestedDevices: expected
        )

        let mode = try RawHVVirtualHardwareAttachmentPlan.launchMode(
            diskAuthority: .resolvedDescriptor,
            bootAuthority: .resolvedImmutableBytes,
            topology: topology,
            resolvedGraphics: .software,
            resolvedDevices: devices,
            resolvedPortForwards: [],
            resolvedSystemDiskLogicalID: systemDiskID,
            directoryShareStableIDs: ["workspace"]
        )
        guard case .resolved(let assignments) = mode else {
            Issue.record("resolved authority must produce resolved assignments")
            return
        }
        #expect(Set(assignments.map(\.request)) == Set(expected))
        for role in [
            DoryVirtualDeviceRole.graphics,
            .entropy,
            .balloon,
            .vsock,
            .keyboard,
            .pointer,
            .audio,
        ] {
            let request = try RawHVVirtualHardwareAttachmentPlan.canonicalFixedRequest(role)
            #expect(request.logicalID.rawValue == "rawhv-\(role.rawValue)")
            #expect(assignments.contains(where: { $0.request == request }))
        }
    }

    @Test func substitutedSingletonIdentityCannotSelfCertifyThroughTopology() throws {
        let devices = resolvedDevices(directorySharing: false)
        let expectedDiskID = try DoryVirtualDeviceID("expected-system-disk")
        let staleDiskDevices = try RawHVVirtualHardwareAttachmentPlan.expectedResolvedDevices(
            systemDiskLogicalID: try DoryVirtualDeviceID("stale-system-disk"),
            resolvedDevices: devices,
            networkStableID: try #require(devices.networkInterface).id,
            directoryShareStableIDs: []
        )
        let staleDiskTopology = try DoryRawHVVirtualHardwareTopologyReconciler.reconcile(
            requestedDevices: staleDiskDevices
        )
        #expect(throws: RawHVVirtualHardwareAttachmentPlanError.materializedDeviceSetMismatch) {
            _ = try RawHVVirtualHardwareAttachmentPlan.launchMode(
                diskAuthority: .resolvedDescriptor,
                bootAuthority: .resolvedImmutableBytes,
                topology: staleDiskTopology,
                resolvedGraphics: .software,
                resolvedDevices: devices,
                resolvedPortForwards: [],
                resolvedSystemDiskLogicalID: expectedDiskID,
                directoryShareStableIDs: []
            )
        }

        var substitutedFixedDevices = try RawHVVirtualHardwareAttachmentPlan.expectedResolvedDevices(
            systemDiskLogicalID: expectedDiskID,
            resolvedDevices: devices,
            networkStableID: try #require(devices.networkInterface).id,
            directoryShareStableIDs: []
        )
        let graphicsIndex = try #require(
            substitutedFixedDevices.firstIndex(where: { $0.role == .graphics })
        )
        substitutedFixedDevices[graphicsIndex] = try DoryRawHVVirtualDeviceRequest(
            logicalID: "substituted-graphics",
            role: .graphics
        )
        let substitutedFixedTopology = try DoryRawHVVirtualHardwareTopologyReconciler.reconcile(
            requestedDevices: substitutedFixedDevices
        )
        #expect(throws: RawHVVirtualHardwareAttachmentPlanError.materializedDeviceSetMismatch) {
            _ = try RawHVVirtualHardwareAttachmentPlan.launchMode(
                diskAuthority: .resolvedDescriptor,
                bootAuthority: .resolvedImmutableBytes,
                topology: substitutedFixedTopology,
                resolvedGraphics: .software,
                resolvedDevices: devices,
                resolvedPortForwards: [],
                resolvedSystemDiskLogicalID: expectedDiskID,
                directoryShareStableIDs: []
            )
        }
    }

    @Test func completeResolvedAndLegacyAuthorityTuplesAreMutuallyExclusive() throws {
        #expect(try RawHVVirtualHardwareAttachmentPlan.launchMode(
            diskAuthority: .legacyPath,
            bootAuthority: .legacyPaths,
            topology: nil,
            resolvedGraphics: nil,
            resolvedDevices: nil,
            resolvedPortForwards: nil,
            resolvedSystemDiskLogicalID: nil,
            directoryShareStableIDs: []
        ) == .legacy)

        let devices = resolvedDevices(directorySharing: false)
        let diskID = try DoryVirtualDeviceID("system-disk")
        let expected = try RawHVVirtualHardwareAttachmentPlan.expectedResolvedDevices(
            systemDiskLogicalID: diskID,
            resolvedDevices: devices,
            networkStableID: try #require(devices.networkInterface).id,
            directoryShareStableIDs: []
        )
        let topology = try DoryRawHVVirtualHardwareTopologyReconciler.reconcile(
            requestedDevices: expected
        )
        #expect(throws: RawHVVirtualHardwareAttachmentPlanError.incompleteLaunchAuthority) {
            _ = try RawHVVirtualHardwareAttachmentPlan.launchMode(
                diskAuthority: .legacyPath,
                bootAuthority: .resolvedImmutableBytes,
                topology: topology,
                resolvedGraphics: .software,
                resolvedDevices: devices,
                resolvedPortForwards: [],
                resolvedSystemDiskLogicalID: diskID,
                directoryShareStableIDs: []
            )
        }
        #expect(throws: RawHVVirtualHardwareAttachmentPlanError.incompleteLaunchAuthority) {
            _ = try RawHVVirtualHardwareAttachmentPlan.launchMode(
                diskAuthority: .resolvedDescriptor,
                bootAuthority: .legacyPaths,
                topology: topology,
                resolvedGraphics: .software,
                resolvedDevices: devices,
                resolvedPortForwards: [],
                resolvedSystemDiskLogicalID: diskID,
                directoryShareStableIDs: []
            )
        }
        #expect(throws: RawHVVirtualHardwareAttachmentPlanError.incompleteLaunchAuthority) {
            _ = try RawHVVirtualHardwareAttachmentPlan.launchMode(
                diskAuthority: .resolvedDescriptor,
                bootAuthority: .resolvedImmutableBytes,
                topology: topology,
                resolvedGraphics: .software,
                resolvedDevices: devices,
                resolvedPortForwards: [],
                resolvedSystemDiskLogicalID: nil,
                directoryShareStableIDs: []
            )
        }
        #expect(throws: RawHVVirtualHardwareAttachmentPlanError.incompleteLaunchAuthority) {
            _ = try RawHVVirtualHardwareAttachmentPlan.launchMode(
                diskAuthority: .resolvedDescriptor,
                bootAuthority: .resolvedImmutableBytes,
                topology: nil,
                resolvedGraphics: nil,
                resolvedDevices: nil,
                resolvedPortForwards: nil,
                resolvedSystemDiskLogicalID: nil,
                directoryShareStableIDs: []
            )
        }
        #expect(throws: RawHVVirtualHardwareAttachmentPlanError.resolvedDeviceContractMismatch) {
            _ = try RawHVVirtualHardwareAttachmentPlan.launchMode(
                diskAuthority: .resolvedDescriptor,
                bootAuthority: .resolvedImmutableBytes,
                topology: topology,
                resolvedGraphics: DoryGraphicsAccelerationLevel.none,
                resolvedDevices: devices,
                resolvedPortForwards: [],
                resolvedSystemDiskLogicalID: diskID,
                directoryShareStableIDs: []
            )
        }
    }

    @Test func resolvedPreflightRejectsShareContractBeforeMaterialization() throws {
        let devices = resolvedDevices(directorySharing: false)
        let diskID = try DoryVirtualDeviceID("system-disk")
        let expected = try RawHVVirtualHardwareAttachmentPlan.expectedResolvedDevices(
            systemDiskLogicalID: diskID,
            resolvedDevices: devices,
            networkStableID: try #require(devices.networkInterface).id,
            directoryShareStableIDs: []
        )
        let topology = try DoryRawHVVirtualHardwareTopologyReconciler.reconcile(
            requestedDevices: expected
        )

        #expect(throws: RawHVVirtualHardwareAttachmentPlanError.resolvedDeviceContractMismatch) {
            _ = try RawHVVirtualHardwareAttachmentPlan.launchMode(
                diskAuthority: .resolvedDescriptor,
                bootAuthority: .resolvedImmutableBytes,
                topology: topology,
                resolvedGraphics: .software,
                resolvedDevices: devices,
                resolvedPortForwards: [],
                resolvedSystemDiskLogicalID: diskID,
                directoryShareStableIDs: ["unauthorized-share"]
            )
        }
    }

    private func resolvedDevices(
        directorySharing: Bool = true
    ) -> DoryVirtualMachineDeviceCapabilityRequest {
        DoryVirtualMachineDeviceCapabilityRequest(
            networkInterface: .stable(machineID: "attachment-plan-tests"),
            displays: [.init(widthPixels: 1_920, heightPixels: 1_080)],
            audioInput: true,
            audioOutput: true,
            keyboard: true,
            pointer: true,
            directorySharing: directorySharing
        )
    }
}
