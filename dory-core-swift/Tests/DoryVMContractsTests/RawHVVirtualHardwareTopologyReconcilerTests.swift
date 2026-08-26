import Testing
@testable import DoryVMContracts

@Suite struct RawHVVirtualHardwareTopologyReconcilerTests {
    @Test func firstAllocationUsesFixedSlotsAndLowestFreeRangeSlotsDeterministically() throws {
        let requests = try [
            request("share.z", .directoryShare),
            request("storage.removable", .removableStorage),
            request("net.z", .network),
            request("graphics.primary", .graphics),
            request("net.a", .network),
            request("storage.aux", .auxiliaryBlock),
            request("system.root", .systemDisk),
            request("share.a", .directoryShare),
            request("usb.primary", .usbController),
        ]

        let topology = try DoryRawHVVirtualHardwareTopologyReconciler.reconcile(
            requestedDevices: requests
        )
        #expect(assignments(topology) == [
            "system.root": 0,
            "graphics.primary": 1,
            "net.a": 8,
            "net.z": 9,
            "storage.aux": 12,
            "storage.removable": 13,
            "share.a": 20,
            "share.z": 21,
            "usb.primary": 30,
        ])

        let reordered = try DoryRawHVVirtualHardwareTopologyReconciler.reconcile(
            requestedDevices: requests.reversed()
        )
        #expect(reordered == topology)
        #expect(reordered.canonicalSHA256Fingerprint() == topology.canonicalSHA256Fingerprint())
    }

    @Test func addAndRemoveNeverRenumberSurvivorsAndReuseOnlyVacatedSlots() throws {
        let previous = try DoryRawHVVirtualHardwareTopologyReconciler.reconcile(
            requestedDevices: [
                request("net.alpha", .network),
                request("net.beta", .network),
                request("share.alpha", .directoryShare),
                request("share.beta", .directoryShare),
                request("storage.alpha", .auxiliaryBlock),
                request("storage.beta", .removableStorage),
            ]
        )
        #expect(assignments(previous) == [
            "net.alpha": 8,
            "net.beta": 9,
            "storage.alpha": 12,
            "storage.beta": 13,
            "share.alpha": 20,
            "share.beta": 21,
        ])

        let reconciled = try DoryRawHVVirtualHardwareTopologyReconciler.reconcile(
            requestedDevices: [
                request("net.beta", .network),
                request("net.gamma", .network),
                request("storage.beta", .removableStorage),
                request("storage.gamma", .auxiliaryBlock),
                request("share.beta", .directoryShare),
                request("share.gamma", .directoryShare),
            ],
            previousTopology: previous
        )

        #expect(assignments(reconciled) == [
            "net.gamma": 8,
            "net.beta": 9,
            "storage.gamma": 12,
            "storage.beta": 13,
            "share.gamma": 20,
            "share.beta": 21,
        ])
        #expect(!reconciled.occupiedSlots.contains { $0.logicalID.rawValue == "net.alpha" })
        #expect(!reconciled.occupiedSlots.contains { $0.logicalID.rawValue == "storage.alpha" })
        #expect(!reconciled.occupiedSlots.contains { $0.logicalID.rawValue == "share.alpha" })
    }

    @Test func fixedSingletonReplacementUsesItsABIIdentityWithoutMovingOtherDevices() throws {
        let previous = try DoryRawHVVirtualHardwareTopologyReconciler.reconcile(
            requestedDevices: [
                request("graphics.old", .graphics),
                request("net.primary", .network),
            ]
        )
        let reconciled = try DoryRawHVVirtualHardwareTopologyReconciler.reconcile(
            requestedDevices: [
                request("graphics.new", .graphics),
                request("net.primary", .network),
            ],
            previousTopology: previous
        )

        #expect(assignments(reconciled) == ["graphics.new": 1, "net.primary": 8])
    }

    @Test func rejectsLogicalIDRoleMutation() throws {
        let logicalID = try DoryVirtualDeviceID("device.stable")
        let previous = try DoryRawHVVirtualHardwareTopologyReconciler.reconcile(
            requestedDevices: [DoryRawHVVirtualDeviceRequest(logicalID: logicalID, role: .network)]
        )

        #expect(throws: DoryVMContractError.roleMutation(
            logicalID: logicalID,
            previous: .network,
            requested: .directoryShare
        )) {
            try DoryRawHVVirtualHardwareTopologyReconciler.reconcile(
                requestedDevices: [
                    DoryRawHVVirtualDeviceRequest(logicalID: logicalID, role: .directoryShare),
                ],
                previousTopology: previous
            )
        }
    }

    @Test func rejectsDuplicateIDsAndEveryRoleCapacityOverflow() throws {
        let duplicate = try request("net.same", .network)
        #expect(throws: DoryVMContractError.duplicateLogicalDeviceID(duplicate.logicalID)) {
            try DoryRawHVVirtualHardwareTopologyReconciler.reconcile(
                requestedDevices: [duplicate, duplicate]
            )
        }

        let graphics = try (0..<2).map { try request("graphics.\($0)", .graphics) }
        #expect(throws: DoryVMContractError.roleCapacityExceeded(role: .graphics, maximum: 1)) {
            try DoryRawHVVirtualHardwareTopologyReconciler.reconcile(requestedDevices: graphics)
        }

        let networks = try (0..<5).map { try request("net.\($0)", .network) }
        #expect(throws: DoryVMContractError.roleCapacityExceeded(role: .network, maximum: 4)) {
            try DoryRawHVVirtualHardwareTopologyReconciler.reconcile(requestedDevices: networks)
        }

        let shares = try (0..<11).map { try request("share.\($0)", .directoryShare) }
        #expect(throws: DoryVMContractError.roleCapacityExceeded(role: .directoryShare, maximum: 10)) {
            try DoryRawHVVirtualHardwareTopologyReconciler.reconcile(requestedDevices: shares)
        }

        let storage = try (0..<9).map {
            try request(
                "storage.\($0)",
                $0.isMultiple(of: 2) ? .auxiliaryBlock : .removableStorage
            )
        }
        #expect(throws: DoryVMContractError.auxiliaryStorageCapacityExceeded(maximum: 8)) {
            try DoryRawHVVirtualHardwareTopologyReconciler.reconcile(requestedDevices: storage)
        }
    }

    private func request(
        _ logicalID: String,
        _ role: DoryVirtualDeviceRole
    ) throws -> DoryRawHVVirtualDeviceRequest {
        try DoryRawHVVirtualDeviceRequest(logicalID: logicalID, role: role)
    }

    private func assignments(
        _ topology: DoryRawHVVirtualHardwareTopology
    ) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: topology.occupiedSlots.map {
            ($0.logicalID.rawValue, $0.mmioSlot)
        })
    }
}
