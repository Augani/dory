import DoryOperations
import Foundation
import Testing
@testable import DorydKit

@Suite("Production planning backing ownership boundary")
struct DoryPlanningBackingOwnershipTests {
    @Test("production controller accepts workload writes but cannot refresh start evidence")
    func liveWritesRemainBoundToPublishedBacking() throws {
        let fixture = try ControllerBackingFixture()
        defer { fixture.cleanup() }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: fixture.path))
        try handle.write(contentsOf: Data("guest workload".utf8))
        try handle.synchronize()
        try handle.close()
        let controller: any DoryDaemonVirtualMachineProductionPlanningControlling = fixture.controller
        try controller.validateBackingOwnership(of: fixture.artifact, atPath: fixture.path)
        #expect(throws: DoryVirtualMachineArtifactAuthorityError.artifactChanged) {
            try fixture.authority.resolve(reference: fixture.artifact.resolverReference,
                                          kind: .virtualDisk, source: .userProvided)
        }
        #expect(try controller.authorityRevision(for: fixture.artifact.resolverReference) == 1)
    }

    @Test("controller forwards exact publication evidence and private path",
          arguments: ["revision", "reference", "media", "evidence", "path"])
    func mismatchedPublicationRejects(change: String) throws {
        let fixture = try ControllerBackingFixture()
        defer { fixture.cleanup() }
        var artifact = fixture.artifact
        switch change {
        case "revision": artifact.authorityRevision += 1
        case "reference": artifact.resolverReference.identifier = "other"
        case "media": artifact.media.source = .bundledByDory
        case "evidence": artifact.mutableProvenanceEvidence = nil
        default: break
        }
        let controller: any DoryDaemonVirtualMachineProductionPlanningControlling = fixture.controller
        #expect(throws: DoryVirtualMachineArtifactAuthorityError.self) {
            try controller.validateBackingOwnership(
                of: artifact, atPath: change == "path" ? fixture.path + "-other" : fixture.path
            )
        }
    }

    @Test("injected planning controllers without a backing authority fail closed")
    func injectedDefaultCannotAuthorizeBacking() throws {
        let fixture = try ControllerBackingFixture()
        defer { fixture.cleanup() }
        let injected: any DoryDaemonVirtualMachineProductionPlanningControlling = MissingBackingController()
        #expect(throws: DoryDaemonVirtualMachineProductionPlanningControllerFailure.self) {
            try injected.validateBackingOwnership(of: fixture.artifact, atPath: fixture.path)
        }
    }
}

private struct ControllerBackingFixture {
    let root: URL
    let path: String
    let artifact: DoryResolvedMachineLaunchArtifact
    let authority: DoryVirtualMachineArtifactAuthority
    let controller: DoryDaemonVirtualMachineProductionPlanningController

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-controller-backing-\(UUID())").standardizedFileURL
        path = root.appendingPathComponent("disk").path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data(repeating: 0x41, count: 4_096).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        authority = DoryVirtualMachineArtifactAuthority(root: root.appendingPathComponent("authority").path)
        let published = try authority.publishMutable(
            reference: DoryVMResolverReference(namespace: "backing", identifier: "system"),
            path: path, source: .userProvided
        )
        artifact = .init(resolverReference: published.reference, media: published.media,
                         authorityRevision: published.authorityRevision,
                         usages: [.init(kind: .storage, identifier: "system", readOnly: false)],
                         mutableProvenanceEvidence: published.mutableProvenance?.persistedAuditEvidence)
        controller = .init(
            artifactAuthority: authority, coordinator: BackingRejectingCoordinator(),
            workspaces: DoryWorkspaceRepository(root: root.appendingPathComponent("machines").path),
            plans: DoryResolvedMachinePlanRepository(root: root.appendingPathComponent("machines").path)
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private enum BackingTestError: Error { case unexpectedPlanning }

private struct BackingRejectingCoordinator: DoryDaemonVirtualMachinePlanningTransactionCoordinating {
    func resolveReserveAndPublish(_ request: DoryDaemonVirtualMachinePlanningTransactionRequest) throws
        -> DoryDaemonVirtualMachinePlanningTransactionResult {
        throw BackingTestError.unexpectedPlanning
    }
}

private struct MissingBackingController: DoryDaemonVirtualMachineProductionPlanningControlling {
    func authorityRevision(for reference: DoryVMResolverReference) throws -> UInt64? { nil }
    func publishResolvedPlan(_ request: DoryDaemonVirtualMachinePlanningTransactionRequest,
                             artifacts: [DoryDaemonVirtualMachinePlanningArtifactPublication]) throws {
        throw BackingTestError.unexpectedPlanning
    }
}
