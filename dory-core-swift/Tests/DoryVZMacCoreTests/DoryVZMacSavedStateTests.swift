import Foundation
import XCTest
@testable import DoryVZMacCore

final class DoryVZMacSavedStateTests: XCTestCase {
    func testSavedStateArtifactBindsHostMachineIdentityAndContent() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-vzmac-saved-state-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let artifactRoot = temporaryRoot.appendingPathComponent("suspended-state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: artifactRoot,
            withIntermediateDirectories: true
        )
        let stateURL = artifactRoot.appendingPathComponent(DoryVZMacSavedStateArtifact.stateName)
        try Data("saved-state-a".utf8).write(to: stateURL)
        let bundle = DoryVZMacMachineBundle(
            rootURL: temporaryRoot,
            manifest: try manifest()
        )
        let configurationSHA256 = String(repeating: "d", count: 64)
        let receipt = try makeSavedStateReceipt(
            stateURL: stateURL,
            bundle: bundle,
            configurationSHA256: configurationSHA256
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(
            to: artifactRoot.appendingPathComponent(DoryVZMacSavedStateArtifact.receiptName)
        )

        let loaded = try DoryVZMacSavedStateArtifact.load(
            from: artifactRoot,
            for: bundle,
            expectedConfigurationSHA256: configurationSHA256
        )
        XCTAssertEqual(loaded.receipt, receipt)
        XCTAssertThrowsError(
            try DoryVZMacSavedStateArtifact.load(
                from: artifactRoot,
                for: bundle,
                expectedConfigurationSHA256: String(repeating: "e", count: 64)
            )
        )

        try Data("saved-state-b".utf8).write(to: stateURL)
        XCTAssertThrowsError(
            try DoryVZMacSavedStateArtifact.load(from: artifactRoot, for: bundle)
        )
    }

    func testReceiptRejectsUnknownSchemaAndEmptyState() throws {
        let valid = try receipt()
        try valid.validate()
        XCTAssertNoThrow(try receipt(schema: "dory.vzmac-saved-state@3").validate())
        XCTAssertThrowsError(try receipt(schema: "dory.vzmac-saved-state@1").validate())
        XCTAssertThrowsError(try receipt(stateBytes: 0).validate())
    }

    func testVersionedSamplerBindsConfigurationAndPreservesLegacyDigest() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-vzmac-sampler-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let stateURL = temporaryRoot.appendingPathComponent("state.bin")
        try Data(repeating: 0x5a, count: 2 * 1_024 * 1_024).write(to: stateURL)

        let configurationA = String(repeating: "a", count: 64)
        let configurationB = String(repeating: "b", count: 64)
        let samplerA = try savedStateSHA256(
            of: stateURL,
            schema: DoryVZMacSavedStateReceipt.schema,
            configurationSHA256: configurationA
        )
        let samplerB = try savedStateSHA256(
            of: stateURL,
            schema: DoryVZMacSavedStateReceipt.schema,
            configurationSHA256: configurationB
        )
        XCTAssertNotEqual(samplerA, samplerB)
        XCTAssertEqual(
            try savedStateSHA256(
                of: stateURL,
                schema: "dory.vzmac-saved-state@3",
                configurationSHA256: configurationA
            ),
            try legacySavedStateSHA256(of: stateURL)
        )

        try Data(repeating: 0x33, count: 2 * 1_024 * 1_024).write(to: stateURL)
        XCTAssertNotEqual(
            samplerA,
            try savedStateSHA256(
                of: stateURL,
                schema: DoryVZMacSavedStateReceipt.schema,
                configurationSHA256: configurationA
            )
        )
    }

    func testVersionedSamplerHasBoundedDistinctLargeStateCoverage() {
        let mebibyte = UInt64(1_024 * 1_024)
        let fileSize = 80 * mebibyte
        let regions = savedStateSampleRegions(
            fileSize: fileSize,
            configurationSHA256: String(repeating: "a", count: 64)
        )

        XCTAssertEqual(regions.count, 66)
        XCTAssertEqual(regions.first, .init(offset: 0, byteCount: 4 * mebibyte))
        XCTAssertEqual(
            regions[1],
            .init(offset: fileSize - 4 * mebibyte, byteCount: 4 * mebibyte)
        )
        XCTAssertEqual(Set(regions.map(\.offset)).count, regions.count)
        XCTAssertTrue(regions.dropFirst(2).allSatisfy { $0.byteCount == mebibyte })
        XCTAssertLessThanOrEqual(
            regions.reduce(UInt64(0)) { $0 + $1.byteCount },
            72 * mebibyte
        )
    }

    func testHostCompatibilityPreflightRejectsVersionAndBuildBeforeRestore() throws {
        let saved = try receipt()
        let matching = DoryVZMacSavedStateHostFacts(
            identifierSHA256: String(repeating: "a", count: 64),
            operatingSystemVersion: "27.0.0",
            buildVersion: "26A5421a"
        )
        XCTAssertNoThrow(
            try DoryVZMacSavedStateArtifact.validateHostCompatibility(saved, host: matching)
        )

        XCTAssertThrowsError(
            try DoryVZMacSavedStateArtifact.validateHostCompatibility(
                saved,
                host: .init(
                    identifierSHA256: matching.identifierSHA256,
                    operatingSystemVersion: "27.1.0",
                    buildVersion: matching.buildVersion
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? DoryVZMacSavedStateError,
                .hostOperatingSystemVersionMismatch(saved: "27.0.0", current: "27.1.0")
            )
        }

        XCTAssertThrowsError(
            try DoryVZMacSavedStateArtifact.validateHostCompatibility(
                saved,
                host: .init(
                    identifierSHA256: matching.identifierSHA256,
                    operatingSystemVersion: matching.operatingSystemVersion,
                    buildVersion: "26A5421b"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? DoryVZMacSavedStateError,
                .hostBuildMismatch(saved: "26A5421a", current: "26A5421b")
            )
        }
    }

    private func receipt(
        schema: String = DoryVZMacSavedStateReceipt.schema,
        stateBytes: UInt64 = 12
    ) throws -> DoryVZMacSavedStateReceipt {
        DoryVZMacSavedStateReceipt(
            schema: schema,
            createdAt: "2026-08-30T14:00:00Z",
            hostIdentifierSHA256: String(repeating: "a", count: 64),
            hostOperatingSystemVersion: "27.0.0",
            hostBuildVersion: "26A5421a",
            hardwareModelSHA256: String(repeating: "b", count: 64),
            machineIdentifierSHA256: String(repeating: "c", count: 64),
            configurationSHA256: String(repeating: "d", count: 64),
            stateBytes: stateBytes,
            stateSHA256: String(repeating: "d", count: 64)
        )
    }

    private func manifest() throws -> DoryVZMacMachineManifest {
        DoryVZMacMachineManifest(
            createdAt: "2026-08-30T14:00:00Z",
            installationState: .suspended,
            origin: .created,
            parentMachineIdentifierSHA256: nil,
            restoreImageBuild: "25G83",
            restoreImageVersion: "26.6.2",
            restoreImageSourceURL: "https://updates.cdn-apple.com/restore.ipsw",
            restoreImageBytes: 1,
            restoreImageSHA256: String(repeating: "a", count: 64),
            hardwareModelSHA256: String(repeating: "b", count: 64),
            machineIdentifierSHA256: String(repeating: "c", count: 64),
            macAddress: "02:11:22:33:44:55",
            resources: try DoryVZMacResourcePlan(
                requestedCPUCount: 4,
                requestedMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
                requestedDiskBytes: 80 * DoryVZMacResourcePlan.gibibyte,
                requestedDisplays: nil,
                minimumCPUCount: 4,
                minimumMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
                maximumCPUCount: 12,
                maximumMemoryBytes: 64 * DoryVZMacResourcePlan.gibibyte
            )
        )
    }
}
