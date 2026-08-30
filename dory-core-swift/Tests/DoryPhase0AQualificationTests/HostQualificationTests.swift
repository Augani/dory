import Foundation
import Testing

@testable import DoryPhase0AQualification

@Suite("Phase 0A physical host qualification receipt")
struct HostQualificationTests {
    @Test("complete Apple-silicon inventory stays unqualified until campaigns and matrix complete")
    func completeInventoryDoesNotCloseMatrix() throws {
        let receipt = Phase0AHostQualificationReceipt(
            collectedAt: "2026-08-30T12:00:00Z",
            host: completeHost(),
            rootStorage: completeStorage(),
            displays: [completeDisplay()]
        )

        #expect(receipt.schema == Phase0AHostQualificationReceipt.schema)
        #expect(receipt.referenceMatrix.inventoryComplete)
        #expect(!receipt.referenceMatrix.baselinesComplete)
        #expect(!receipt.referenceMatrix.physicalMatrixComplete)
        #expect(receipt.referenceMatrix.candidateTier == "unassigned")
        #expect(receipt.referenceMatrix.blockers.count == 3)

        let encoded = try JSONEncoder().encode(receipt)
        #expect(!encoded.isEmpty)
    }

    @Test("missing evidence is named and fails inventory completeness")
    func missingEvidenceIsFailClosed() {
        var host = completeHost()
        host.architecture = "x86_64"
        host.firmwareVersion = ""
        host.bootSessionIdentifier = ""

        let receipt = Phase0AHostQualificationReceipt(
            collectedAt: "2026-08-30T12:00:00Z",
            host: host,
            rootStorage: Phase0AStorageContext(
                totalBytes: 0,
                freeBytes: 0,
                deviceIdentifier: "",
                busProtocol: "",
                internalDevice: nil,
                solidState: nil
            ),
            displays: []
        )

        #expect(!receipt.referenceMatrix.inventoryComplete)
        #expect(receipt.referenceMatrix.blockers.contains("host is not Apple silicon"))
        #expect(receipt.referenceMatrix.blockers.contains("firmware identity is unavailable"))
        #expect(receipt.referenceMatrix.blockers.contains("boot session identity is unavailable"))
        #expect(receipt.referenceMatrix.blockers.contains("root storage capacity is unavailable"))
        #expect(receipt.referenceMatrix.blockers.contains("no active physical display was observed"))
    }

    private func completeHost() -> Phase0AHostIdentity {
        Phase0AHostIdentity(
            architecture: "arm64",
            hardwareModel: "Mac14,10",
            marketingModel: "MacBook Pro",
            chip: "Apple M2 Pro",
            firmwareVersion: "20457.1.29",
            osLoaderVersion: "20457.1.29",
            physicalMemoryBytes: 17_179_869_184,
            physicalProcessorCount: 12,
            logicalProcessorCount: 12,
            performanceCoreCount: 8,
            efficiencyCoreCount: 4,
            osProductVersion: "27.0",
            osBuildVersion: "26A5421a",
            bootSessionIdentifier: "test-boot-session",
            powerSource: "ac",
            lowPowerModeEnabled: false,
            thermalState: "nominal"
        )
    }

    private func completeStorage() -> Phase0AStorageContext {
        Phase0AStorageContext(
            totalBytes: 1_000_000_000_000,
            freeBytes: 500_000_000_000,
            deviceIdentifier: "disk3s1s1",
            busProtocol: "Apple Fabric",
            internalDevice: true,
            solidState: true
        )
    }

    private func completeDisplay() -> Phase0ADisplayContext {
        Phase0ADisplayContext(
            ordinal: 0,
            isMain: true,
            isBuiltIn: true,
            pixelWidth: 3_456,
            pixelHeight: 2_234,
            refreshRateHz: 120,
            rotationDegrees: 0
        )
    }
}
