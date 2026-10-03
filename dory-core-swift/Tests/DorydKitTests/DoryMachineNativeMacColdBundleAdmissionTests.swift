import Foundation
import XCTest
@testable import DorydKit
@testable import DoryVZMacCore

final class DoryMachineNativeMacColdBundleAdmissionTests: XCTestCase {
    func testVerifiedRepairAssessmentKeepsTheCandidateAndChoicesSeparateFromNormalLoad() throws {
        let candidate = try manifest()
        let assessment = DoryVZMacDisplayRepairAssessment(originalManifestSHA256: String(repeating: "a", count: 64),
            displays: [candidate.resources.displays[0], candidate.resources.displays[0]],
            pendingSelectedDisplayIndex: 1, preservesSavedState: true, bundleRepairCompleted: false,
            candidateManifest: candidate)
        var io = DoryMachineNativeMacColdBundleAdmission.IO()
        io.load = { _ in throw DoryVZMacMachineBundleError.invalidBundle("one-display repair required") }
        io.inspectRepair = { _ in assessment }
        let result = try DoryMachineNativeMacColdBundleAdmission.inspect(at: root, needsWorkspaceRepair: true, io: io)
        XCTAssertEqual(result.manifest, candidate)
        XCTAssertEqual(result.repair?.displays.count, 2)
        XCTAssertEqual(result.repair?.pendingSelectedDisplayIndex, 1)
        XCTAssertEqual(result.repair?.preservesSavedState, true)
        XCTAssertEqual(result.repair?.bundleRepairCompleted, false)
    }

    func testOrdinaryBundlesDoNotNeedRecoveryInspection() throws {
        let candidate = try manifest()
        var io = DoryMachineNativeMacColdBundleAdmission.IO()
        io.load = { DoryVZMacMachineBundle(rootURL: $0, manifest: candidate) }
        io.inspectRepair = { _ in XCTFail("ordinary load must not run display recovery inspection"); return nil }
        let result = try DoryMachineNativeMacColdBundleAdmission.inspect(at: root, needsWorkspaceRepair: false, io: io)
        XCTAssertEqual(result.manifest, candidate)
        XCTAssertNil(result.repair)
    }

    func testUnknownCorruptOrUnverifiedBundleCannotBecomeARepairCandidate() throws {
        for missing in [true, false] {
            var io = DoryMachineNativeMacColdBundleAdmission.IO()
            io.load = { _ in throw DoryVZMacMachineBundleError.invalidIdentity("foreign identity") }
            io.inspectRepair = { _ in
                if missing { return nil }
                throw DoryVZMacMachineBundleError.invalidBundle("unknown repair intent")
            }
            XCTAssertThrowsError(try DoryMachineNativeMacColdBundleAdmission.inspect(at: root, needsWorkspaceRepair: false, io: io))
        }
    }

    func testRepairedBundleWithUnrepairedWorkspaceRetainsVerifiedPendingOrCompletedRepair() throws {
        let candidate = try manifest()
        for completed in [false, true] {
            var io = DoryMachineNativeMacColdBundleAdmission.IO()
            io.load = { DoryVZMacMachineBundle(rootURL: $0, manifest: candidate) }
            io.inspectRepair = { _ in DoryVZMacDisplayRepairAssessment(originalManifestSHA256: String(repeating: "a", count: 64),
                displays: [candidate.resources.displays[0], candidate.resources.displays[0]],
                pendingSelectedDisplayIndex: 1, preservesSavedState: true, bundleRepairCompleted: completed,
                candidateManifest: candidate) }
            XCTAssertEqual(try DoryMachineNativeMacColdBundleAdmission.inspect(at: root, needsWorkspaceRepair: true, io: io).repair?.bundleRepairCompleted, completed)
        }
    }

    func testDefaultProductAdmissionDoesNotCreateAnyRecoveryFilesForIncompleteFixture() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("dory-cold-mac-admission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: container) }
        XCTAssertThrowsError(try DoryMachineNativeMacColdBundleAdmission.inspect(at: container, needsWorkspaceRepair: true))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: container.path), [])
    }

    private let root = URL(fileURLWithPath: "/owned-machine/Machine.dorymac")
    private func manifest() throws -> DoryVZMacMachineManifest {
        let resources = try DoryVZMacResourcePlan(requestedCPUCount: 4, requestedMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
            requestedDiskBytes: 80 * DoryVZMacResourcePlan.gibibyte, requestedDisplays: nil,
            minimumCPUCount: 2, minimumMemoryBytes: 4 * DoryVZMacResourcePlan.gibibyte,
            maximumCPUCount: 8, maximumMemoryBytes: 32 * DoryVZMacResourcePlan.gibibyte)
        return DoryVZMacMachineManifest(createdAt: "2026-09-22T00:00:00Z", installationState: .stopped, origin: .created,
            parentMachineIdentifierSHA256: nil, restoreImageBuild: "26A123", restoreImageVersion: "27.0",
            restoreImageSourceURL: "https://example.invalid/restore.ipsw", restoreImageBytes: 1,
            restoreImageSHA256: String(repeating: "a", count: 64), hardwareModelSHA256: String(repeating: "b", count: 64),
            machineIdentifierSHA256: String(repeating: "c", count: 64), macAddress: "02:11:22:33:44:55", resources: resources)
    }
}
