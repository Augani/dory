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
        let receipt = try makeSavedStateReceipt(stateURL: stateURL, bundle: bundle)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(
            to: artifactRoot.appendingPathComponent(DoryVZMacSavedStateArtifact.receiptName)
        )

        let loaded = try DoryVZMacSavedStateArtifact.load(from: artifactRoot, for: bundle)
        XCTAssertEqual(loaded.receipt, receipt)

        try Data("saved-state-b".utf8).write(to: stateURL)
        XCTAssertThrowsError(
            try DoryVZMacSavedStateArtifact.load(from: artifactRoot, for: bundle)
        )
    }

    func testReceiptRejectsUnknownSchemaAndEmptyState() throws {
        let valid = try receipt()
        try valid.validate()
        XCTAssertThrowsError(try receipt(schema: "dory.vzmac-saved-state@2").validate())
        XCTAssertThrowsError(try receipt(stateBytes: 0).validate())
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
                minimumCPUCount: 4,
                minimumMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
                maximumCPUCount: 12,
                maximumMemoryBytes: 64 * DoryVZMacResourcePlan.gibibyte
            )
        )
    }
}
