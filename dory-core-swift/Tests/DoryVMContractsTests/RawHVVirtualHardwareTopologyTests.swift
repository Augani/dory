import Foundation
import Testing
@testable import DoryVMContracts

@Suite struct RawHVVirtualHardwareTopologyTests {
    @Test func canonicalFingerprintHasGoldenVersionedBytesAndDigest() throws {
        let topology = try goldenTopology()
        let canonicalJSON = String(decoding: try topology.canonicalJSONData(), as: UTF8.self)

        #expect(topology.occupiedSlots.map(\.mmioSlot) == [0, 1, 2, 8, 9, 12, 20, 30])
        #expect(topology.canonicalFingerprintInput().hexString == Self.goldenFingerprintInputHex)
        #expect(topology.canonicalSHA256Fingerprint() == Self.goldenFingerprintSHA256)
        #expect(canonicalJSON == Self.goldenJSON)
    }

    @Test func inputOrderCannotChangeCanonicalEncodingOrFingerprint() throws {
        let expected = try goldenTopology()
        let reversed = try DoryRawHVVirtualHardwareTopology(
            occupiedSlots: expected.occupiedSlots.reversed()
        )

        #expect(reversed == expected)
        #expect(try reversed.canonicalJSONData() == expected.canonicalJSONData())
        #expect(reversed.canonicalFingerprintInput() == expected.canonicalFingerprintInput())
        #expect(reversed.canonicalSHA256Fingerprint() == expected.canonicalSHA256Fingerprint())
    }

    @Test func JSONRoundTripPreservesCanonicalTopology() throws {
        let expected = try goldenTopology()
        let decoded = try JSONDecoder().decode(
            DoryRawHVVirtualHardwareTopology.self,
            from: expected.canonicalJSONData()
        )

        #expect(decoded == expected)
        #expect(decoded.canonicalFingerprintInput() == expected.canonicalFingerprintInput())
    }

    @Test func logicalIDsAreBoundedASCIIAndPathSafe() throws {
        #expect(try DoryVirtualDeviceID("a") == DoryVirtualDeviceID("a"))
        #expect(try DoryVirtualDeviceID(String(repeating: "a", count: 64)).rawValue.count == 64)

        for invalid in [
            "",
            "UPPERCASE",
            "-leading",
            ".leading",
            "has/slash",
            "has space",
            "café",
            String(repeating: "a", count: 65),
        ] {
            #expect(throws: DoryVMContractError.invalidLogicalDeviceID(invalid)) {
                try DoryVirtualDeviceID(invalid)
            }
        }
    }

    @Test func derivedLogicalIDsHaveGoldenBytesAndRoleSeparatedCollisionDomains() throws {
        let derivationInput = try DoryVirtualDeviceID.canonicalDerivationInput(
            namespace: .directoryShare,
            stableID: "workspace/main"
        )
        let derivedShare = try DoryVirtualDeviceID.derived(
            namespace: .directoryShare,
            stableID: "workspace/main"
        )
        let sameShare = try DoryVirtualDeviceID.derived(
            namespace: .directoryShare,
            stableID: "workspace/main"
        )
        let derivedNetwork = try DoryVirtualDeviceID.derived(
            namespace: .network,
            stableID: "workspace/main"
        )

        #expect(
            derivationInput.hexString
                == "444f52595649440000010c0000000e776f726b73706163652f6d61696e"
        )
        #expect(
            derivedShare.rawValue
                == "dv1-a5c2235ec9ef6cc6b8fc3a23902af50baceb1c3694edd2c80f677c10a5fb"
        )
        #expect(derivedShare.rawValue.utf8.count == DoryVirtualDeviceID.maximumUTF8Length)
        #expect(sameShare == derivedShare)
        #expect(derivedNetwork != derivedShare)
    }

    @Test func derivedLogicalIDsRejectEmptyAndUnboundedStableInputs() {
        #expect(throws: DoryVMContractError.invalidDerivationStableIDLength(
            actual: 0,
            maximum: DoryVirtualDeviceID.maximumDerivationStableIDUTF8Length
        )) {
            try DoryVirtualDeviceID.derived(namespace: .network, stableID: "")
        }

        let oversized = String(
            repeating: "a",
            count: DoryVirtualDeviceID.maximumDerivationStableIDUTF8Length + 1
        )
        #expect(throws: DoryVMContractError.invalidDerivationStableIDLength(
            actual: DoryVirtualDeviceID.maximumDerivationStableIDUTF8Length + 1,
            maximum: DoryVirtualDeviceID.maximumDerivationStableIDUTF8Length
        )) {
            try DoryVirtualDeviceID.derived(namespace: .network, stableID: oversized)
        }
    }

    @Test func rejectsDuplicateLogicalIDsAndMMIOSlots() throws {
        let duplicatedID = try DoryVirtualDeviceID("net.same")
        let first = try DoryRawHVVirtualDeviceSlot(
            logicalID: duplicatedID,
            role: .network,
            mmioSlot: 8
        )
        let secondID = try DoryRawHVVirtualDeviceSlot(
            logicalID: duplicatedID,
            role: .network,
            mmioSlot: 9
        )
        #expect(throws: DoryVMContractError.duplicateLogicalDeviceID(duplicatedID)) {
            try DoryRawHVVirtualHardwareTopology(occupiedSlots: [first, secondID])
        }

        let secondSlot = try DoryRawHVVirtualDeviceSlot(
            logicalID: "net.other",
            role: .network,
            mmioSlot: 8
        )
        #expect(throws: DoryVMContractError.duplicateMMIOSlot(8)) {
            try DoryRawHVVirtualHardwareTopology(occupiedSlots: [first, secondSlot])
        }
    }

    @Test func rejectsOutOfRangeReservedAndRoleMismatchedSlots() throws {
        #expect(throws: DoryVMContractError.mmioSlotOutOfRange(-1)) {
            try DoryRawHVVirtualDeviceSlot(logicalID: "net.low", role: .network, mmioSlot: -1)
        }
        #expect(throws: DoryVMContractError.mmioSlotOutOfRange(32)) {
            try DoryRawHVVirtualDeviceSlot(logicalID: "net.high", role: .network, mmioSlot: 32)
        }
        #expect(throws: DoryVMContractError.reservedMMIOSlot(31)) {
            try DoryRawHVVirtualDeviceSlot(logicalID: "net.reserved", role: .network, mmioSlot: 31)
        }
        #expect(throws: DoryVMContractError.roleSlotMismatch(role: .graphics, slot: 2)) {
            try DoryRawHVVirtualDeviceSlot(logicalID: "graphics.primary", role: .graphics, mmioSlot: 2)
        }
        #expect(throws: DoryVMContractError.roleSlotMismatch(role: .network, slot: 12)) {
            try DoryRawHVVirtualDeviceSlot(logicalID: "net.wrong-range", role: .network, mmioSlot: 12)
        }
    }

    @Test func rejectsWrongSchemaBackendAndArchitecture() throws {
        #expect(throws: DoryVMContractError.unsupportedSchemaVersion(2)) {
            try DoryRawHVVirtualHardwareTopology(schemaVersion: 2, occupiedSlots: [])
        }
        #expect(throws: DoryVMContractError.incompatibleBackend(.virtualizationFramework)) {
            try DoryRawHVVirtualHardwareTopology(
                backend: .virtualizationFramework,
                occupiedSlots: []
            )
        }
        #expect(throws: DoryVMContractError.incompatibleArchitecture(.x86_64)) {
            try DoryRawHVVirtualHardwareTopology(architecture: .x86_64, occupiedSlots: [])
        }
    }

    @Test func rejectsPerRoleAndSharedStorageCapacityOverflow() throws {
        let graphics = try DoryRawHVVirtualDeviceSlot(
            logicalID: "graphics.one",
            role: .graphics,
            mmioSlot: 1
        )
        let secondGraphics = try DoryRawHVVirtualDeviceSlot(
            logicalID: "graphics.two",
            role: .graphics,
            mmioSlot: 1
        )
        #expect(throws: DoryVMContractError.roleCapacityExceeded(role: .graphics, maximum: 1)) {
            try DoryRawHVVirtualHardwareTopology(occupiedSlots: [graphics, secondGraphics])
        }

        var storage = [DoryRawHVVirtualDeviceSlot]()
        for index in 0..<9 {
            storage.append(try DoryRawHVVirtualDeviceSlot(
                logicalID: "storage.\(index)",
                role: index.isMultiple(of: 2) ? .auxiliaryBlock : .removableStorage,
                mmioSlot: 12 + (index % 8)
            ))
        }
        #expect(throws: DoryVMContractError.auxiliaryStorageCapacityExceeded(maximum: 8)) {
            try DoryRawHVVirtualHardwareTopology(occupiedSlots: storage)
        }

        let repeated = Array(repeating: graphics, count: 32)
        #expect(throws: DoryVMContractError.tooManyDevices(actual: 32, maximum: 31)) {
            try DoryRawHVVirtualHardwareTopology(occupiedSlots: repeated)
        }
    }

    @Test func strictDecodeRejectsUnknownFieldsAndUnknownEnums() throws {
        let unknownTopologyField = Data(#"""
        {
          "schemaVersion": 1,
          "abiVersion": "raw-hv-arm64-v1",
          "backend": "raw-hv",
          "architecture": "arm64",
          "occupiedSlots": [],
          "future": true
        }
        """#.utf8)
        #expect(throws: DoryVMContractError.unknownFields(
            type: "DoryRawHVVirtualHardwareTopology",
            fields: ["future"]
        )) {
            try JSONDecoder().decode(
                DoryRawHVVirtualHardwareTopology.self,
                from: unknownTopologyField
            )
        }

        let unknownSlotField = Data(#"""
        {
          "schemaVersion": 1,
          "abiVersion": "raw-hv-arm64-v1",
          "backend": "raw-hv",
          "architecture": "arm64",
          "occupiedSlots": [{
            "logicalID": "net.primary",
            "role": "network",
            "mmioSlot": 8,
            "future": true
          }]
        }
        """#.utf8)
        #expect(throws: DoryVMContractError.unknownFields(
            type: "DoryRawHVVirtualDeviceSlot",
            fields: ["future"]
        )) {
            try JSONDecoder().decode(
                DoryRawHVVirtualHardwareTopology.self,
                from: unknownSlotField
            )
        }

        let unknownRole = Data(#"""
        {
          "logicalID": "net.primary",
          "role": "future-network"
        }
        """#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DoryRawHVVirtualDeviceRequest.self, from: unknownRole)
        }

        let unknownRequestField = Data(#"""
        {
          "logicalID": "net.primary",
          "role": "network",
          "future": true
        }
        """#.utf8)
        #expect(throws: DoryVMContractError.unknownFields(
            type: "DoryRawHVVirtualDeviceRequest",
            fields: ["future"]
        )) {
            try JSONDecoder().decode(DoryRawHVVirtualDeviceRequest.self, from: unknownRequestField)
        }
    }

    @Test func strictDecodeRejectsNonCanonicalSlotOrder() {
        let reorderedSlots = Data(#"""
        {
          "schemaVersion": 1,
          "abiVersion": "raw-hv-arm64-v1",
          "backend": "raw-hv",
          "architecture": "arm64",
          "occupiedSlots": [
            {"logicalID": "net.second", "role": "network", "mmioSlot": 9},
            {"logicalID": "net.first", "role": "network", "mmioSlot": 8}
          ]
        }
        """#.utf8)

        #expect(throws: DoryVMContractError.nonCanonicalOccupiedSlotOrder) {
            try JSONDecoder().decode(
                DoryRawHVVirtualHardwareTopology.self,
                from: reorderedSlots
            )
        }
    }

    private func goldenTopology() throws -> DoryRawHVVirtualHardwareTopology {
        try DoryRawHVVirtualHardwareTopology(occupiedSlots: [
            slot("usb.primary", .usbController, 30),
            slot("share.workspace", .directoryShare, 20),
            slot("disk.data", .auxiliaryBlock, 12),
            slot("net.workspace", .network, 9),
            slot("net.management", .network, 8),
            slot("entropy.primary", .entropy, 2),
            slot("graphics.primary", .graphics, 1),
            slot("system.root", .systemDisk, 0),
        ])
    }

    private func slot(
        _ logicalID: String,
        _ role: DoryVirtualDeviceRole,
        _ mmioSlot: Int
    ) throws -> DoryRawHVVirtualDeviceSlot {
        try DoryRawHVVirtualDeviceSlot(logicalID: logicalID, role: role, mmioSlot: mmioSlot)
    }

    private static let goldenFingerprintInputHex = "444f5259564857000001000000010101010800010b73797374656d2e726f6f7401021067726170686963732e7072696d61727902030f656e74726f70792e7072696d61727908090e6e65742e6d616e6167656d656e7409090d6e65742e776f726b73706163650c0a096469736b2e64617461140c0f73686172652e776f726b73706163651e0d0b7573622e7072696d617279"
    private static let goldenFingerprintSHA256 = "7e91e1f8e863c41d33a27577814d730316848a795b672d6ec9176f6f0266f1ce"
    private static let goldenJSON = #"{"abiVersion":"raw-hv-arm64-v1","architecture":"arm64","backend":"raw-hv","occupiedSlots":[{"logicalID":"system.root","mmioSlot":0,"role":"system-disk"},{"logicalID":"graphics.primary","mmioSlot":1,"role":"graphics"},{"logicalID":"entropy.primary","mmioSlot":2,"role":"entropy"},{"logicalID":"net.management","mmioSlot":8,"role":"network"},{"logicalID":"net.workspace","mmioSlot":9,"role":"network"},{"logicalID":"disk.data","mmioSlot":12,"role":"auxiliary-block"},{"logicalID":"share.workspace","mmioSlot":20,"role":"directory-share"},{"logicalID":"usb.primary","mmioSlot":30,"role":"usb-controller"}],"schemaVersion":1}"#
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
