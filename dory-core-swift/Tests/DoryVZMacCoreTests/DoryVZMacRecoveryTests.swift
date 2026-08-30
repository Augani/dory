import XCTest
@testable import DoryVZMacCore

final class DoryVZMacRecoveryTests: XCTestCase {
    func testRequiresExplicitDiscardAfterInterruptedRestore() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = DoryVZMacMachineBundle(
            rootURL: root,
            manifest: try manifest(state: .restoring)
        )
        XCTAssertThrowsError(
            try DoryVZMacRecovery.recoverInterruptedOperation(in: bundle)
        ) { error in
            XCTAssertEqual(
                error as? DoryVZMacRecoveryError,
                .explicitSavedStateDiscardRequired
            )
        }
    }

    func testRejectsRecoveryForStableStateBeforeFilesystemMutation() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = DoryVZMacMachineBundle(
            rootURL: root,
            manifest: try manifest(state: .stopped)
        )
        XCTAssertThrowsError(
            try DoryVZMacRecovery.recoverInterruptedOperation(in: bundle)
        ) { error in
            XCTAssertEqual(
                error as? DoryVZMacRecoveryError,
                .noInterruptedOperation(.stopped)
            )
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-vzmac-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func manifest(
        state: DoryVZMacMachineInstallationState
    ) throws -> DoryVZMacMachineManifest {
        DoryVZMacMachineManifest(
            createdAt: "2026-08-30T14:00:00Z",
            installationState: state,
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
