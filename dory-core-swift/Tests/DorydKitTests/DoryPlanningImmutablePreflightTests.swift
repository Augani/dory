import CryptoKit
import DoryOperations
import Foundation
import Testing
@testable import DorydKit

@Suite("Immutable planning preflight boundaries")
struct DoryPlanningImmutablePreflightTests {
    @Test("public planning rejects malformed intent before inventory, artifacts, locks or journals",
          arguments: ["unsupported", "definition", "canonical", "empty", "machine", "uuid", "duration", "revision"])
    func publicBoundariesRejectBeforeMutation(change: String) throws {
        let fixture = try ImmutablePreflightFixture()
        defer { fixture.cleanup() }
        var request = fixture.request
        switch change {
        case "unsupported": request.planning.definition.guest.family = .windows
        case "definition": request.planning.definition.resources = .init(
            virtualCPUCount: 0, memoryBytes: 2 << 30, diskBytes: 32 << 30
        )
        case "canonical": request.planning.canonicalDefinitionData = Data("different authority".utf8)
        case "empty": request.planning.canonicalDefinitionData = Data()
        case "machine": request.planning.machine.id = "another-machine"
        case "uuid": request.operationID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        case "duration": request.startingLeaseDurationMilliseconds = 0
        case "revision": request.workspacePublication = .replace(expectedRevision: 1)
        default: Issue.record("unknown mutation")
        }
        if ["unsupported", "definition"].contains(change) {
            request.planning.canonicalDefinitionData = DoryDaemonVirtualMachinePlanningCoordinator
                .canonicalDefinitionData(request.planning.definition)
        }
        let before = try fixture.files()
        #expect(throws: (any Error).self) {
            try fixture.controller.resolveReserveAndPublish(request, artifacts: fixture.publications)
        }
        #expect(throws: (any Error).self) { try fixture.transaction.resolveReserveAndPublish(request) }
        if !["uuid", "duration", "revision"].contains(change) {
            #expect(throws: (any Error).self) { try fixture.planner.resolveAndPersist(request.planning) }
        }
        #expect(fixture.probe.calls == [])
        #expect(try fixture.files() == before)
    }

    @Test("validated intent cannot be changed through the original request or a returned copy")
    func capturedIntentRemainsExactAtFreshBoundaries() throws {
        let fixture = try ImmutablePreflightFixture()
        defer { fixture.cleanup() }
        var caller = fixture.request
        let validated = try DoryDaemonValidatedPlanningTransaction(caller)
        let expectedDefinition = caller.planning.definition
        let expectedOperation = caller.operationID
        caller.planning.definition.guest.family = .windows
        caller.planning.canonicalDefinitionData = Data()
        caller.operationID = UUID()
        var exported = validated.request
        exported.planning.definition.resources = .init(
            virtualCPUCount: 0, memoryBytes: 2 << 30, diskBytes: 32 << 30
        )
        exported.planning.machine.id = "replaced"
        exported.startingLeaseDurationMilliseconds = 0
        #expect(validated.request.operationID == expectedOperation)
        #expect(validated.planning.request.definition == expectedDefinition)
        #expect(validated.planning.inventoryRequest.machineID == expectedDefinition.identity.id)
        #expect(validated.planning.inventoryRequest.resources == expectedDefinition.resources)
        #expect(Set(validated.planning.inventoryRequest.launchArtifacts.map(\.reference))
            == Set(fixture.publications.map(\.reference)))
        // The internal handoff skips only immutable validation. External inventory and the
        // current workspace fence are still consulted, and these rejecting probes stop it.
        #expect(throws: (any Error).self) { try fixture.planner.resolveAndPersist(validated.planning) }
        #expect(throws: (any Error).self) { try fixture.transaction.resolveReserveAndPublish(validated) }
        #expect(fixture.probe.calls == ["inventory", "workspace"])
    }

    @Test("an injected transaction coordinator retains its independently callable boundary")
    func injectedCoordinatorReceivesTheValidatedRawRequest() throws {
        let fixture = try ImmutablePreflightFixture()
        defer { fixture.cleanup() }
        #expect(throws: (any Error).self) {
            try fixture.controller.resolveReserveAndPublish(fixture.request, artifacts: fixture.publications)
        }
        #expect(fixture.probe.calls == ["transaction"])
        #expect(fixture.probe.operationID == fixture.request.operationID)
        #expect(try fixture.authority.authorityRecord(reference: fixture.publications[0].reference) != nil)
        #expect(try fixture.authority.authorityRecord(reference: fixture.publications[1].reference) != nil)
    }
}

@Suite("Checkpoint-bound immutable planning replacement")
struct DoryPlanningImmutableReplacementTests {
    @Test("ordinary replans and mismatched replacement proofs preserve prior authority",
          arguments: ["absent", "operation", "reference", "path", "revision", "expectedRevision",
                      "digest", "mutability", "source", "kind", "unchangedBytes"])
    func rejectsUnboundReplacement(change: String) throws {
        let fixture = try ImmutablePreflightFixture()
        defer { fixture.cleanup() }
        var publications = fixture.publications
        let original = try fixture.authority.publishImmutable(
            reference: publications[0].reference, path: publications[0].path,
            kind: publications[0].kind, source: publications[0].source
        )
        let originalRecord = try fixture.authority.authorityRecord(reference: publications[0].reference)
        let target = Data("qualified-replacement".utf8)
        if change != "unchangedBytes" {
            try target.write(to: URL(fileURLWithPath: publications[0].path))
        }
        publications[0].expectedAuthorityRevision = original.authorityRevision
        let proof = try DoryDaemonImmutableArtifactReplacementProof(
            operationID: change == "operation" ? UUID() : fixture.request.operationID,
            reference: change == "reference" ? .init(namespace: "artifact", identifier: "other") : publications[0].reference,
            path: change == "path" ? fixture.root + "/other" : publications[0].path,
            expectedAuthorityRevision: change == "revision" ? original.authorityRevision + 1 : original.authorityRevision,
            sha256: change == "digest" ? String(repeating: "0", count: 64) : Self.digest(target)
        )
        if change != "absent" { publications[0].immutableReplacementProof = proof }
        switch change {
        case "expectedRevision": publications[0].expectedAuthorityRevision = nil
        case "mutability": publications[0].mutability = .mutable
        case "source": publications[0].source = .userProvided
        case "kind": publications[0].kind = .installerISO
        default: break
        }
        let before = try fixture.files()
        #expect(throws: DoryDaemonVirtualMachineProductionPlanningControllerFailure.self) {
            try fixture.controller.resolveReserveAndPublish(fixture.request, artifacts: publications)
        }
        #expect(fixture.probe.calls.isEmpty)
        #expect(try fixture.authority.authorityRecord(reference: fixture.publications[0].reference) == originalRecord)
        #expect(try fixture.files() == before)
    }

    @Test("authorized target and rollback publish only pinned bytes and exact replay retains its revision")
    func targetRollbackAndReplay() throws {
        let fixture = try ImmutablePreflightFixture()
        defer { fixture.cleanup() }
        var publications = fixture.publications
        let sourceBytes = try Data(contentsOf: URL(fileURLWithPath: publications[0].path))
        let targetBytes = Data("qualified-replacement".utf8)
        _ = try fixture.authority.publishImmutable(
            reference: publications[0].reference, path: publications[0].path,
            kind: publications[0].kind, source: publications[0].source
        )
        for (bytes, expectedRevision) in [(targetBytes, UInt64(2)), (targetBytes, 2), (sourceBytes, 3)] {
            if try Data(contentsOf: URL(fileURLWithPath: publications[0].path)) != bytes {
                try bytes.write(to: URL(fileURLWithPath: publications[0].path))
            }
            let currentRecord = try fixture.authority.authorityRecord(reference: publications[0].reference)
            let current = try #require(currentRecord)
            publications[0].expectedAuthorityRevision = current.authorityRevision
            publications[0].immutableReplacementProof = try .init(
                operationID: fixture.request.operationID, reference: publications[0].reference,
                path: publications[0].path, expectedAuthorityRevision: current.authorityRevision,
                sha256: Self.digest(bytes)
            )
            // This isolated controller uses a rejecting coordinator: reaching it proves the
            // artifact boundary accepted only the exact replacement, without fabricating a plan.
            #expect(throws: DoryDaemonVirtualMachineProductionPlanningControllerFailure.self) {
                try fixture.controller.resolveReserveAndPublish(fixture.request, artifacts: publications)
            }
            let receipt = try fixture.authority.resolve(
                reference: publications[0].reference, kind: publications[0].kind, source: publications[0].source
            )
            #expect(receipt.authorityRevision == expectedRevision)
            #expect(receipt.media.artifactSHA256 == Self.digest(bytes))
        }
        #expect(fixture.probe.calls == ["transaction", "transaction", "transaction"])
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class ImmutablePreflightFixture {
    let root: String
    let request: DoryDaemonVirtualMachinePlanningTransactionRequest
    let publications: [DoryDaemonVirtualMachinePlanningArtifactPublication]
    let authority: DoryVirtualMachineArtifactAuthority
    let probe = ImmutablePreflightProbe()
    let controller: DoryDaemonVirtualMachineProductionPlanningController
    let transaction: DoryDaemonVirtualMachinePlanningTransactionCoordinator
    let planner: DoryDaemonVirtualMachinePlanningCoordinator

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dory-immutable-preflight-\(UUID())")
            .standardizedFileURL.path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let boot = DoryVMResolverReference(namespace: "artifact", identifier: "boot")
        let disk = DoryVMResolverReference(namespace: "artifact", identifier: "disk")
        let resources = DoryVMResourceRequest(virtualCPUCount: 2, memoryBytes: 2 << 30, diskBytes: 32 << 30)
        let definition = DoryVirtualMachineDefinition(
            identity: .init(id: "preflight", name: "Preflight"),
            guest: .init(family: .linux, architecture: .arm64), workload: .desktop,
            boot: .init(phase: .normal, devices: [
                .init(id: "system", role: .system, kind: .installedLinuxBootBundle,
                      source: .bundledByDory, artifact: boot, removable: false),
            ], order: ["system"]),
            platform: .arm64LinuxV1, graphics: .init(acceptableLevels: [.none]), resources: resources,
            storage: [.init(id: "disk", role: .system, artifact: disk, source: .userProvided,
                            capacityBytes: resources.diskBytes)],
            audio: .init(inputEnabled: false, outputEnabled: false),
            input: .init(keyboardEnabled: false, pointerEnabled: false),
            lifecycle: .init(revision: 1, createdAtUnixMilliseconds: 1_700_000_000_000,
                             updatedAtUnixMilliseconds: 1_700_000_000_000)
        )
        for name in ["kernel", "disk"] {
            let path = root + "/" + name
            try Data(name.utf8).write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        request = .init(planning: .init(
            definition: definition,
            canonicalDefinitionData: DoryDaemonVirtualMachinePlanningCoordinator.canonicalDefinitionData(definition),
            machine: .init(id: "preflight", kernelPath: root + "/kernel", rootfsPath: root + "/disk",
                           bootMode: .linuxKernel, displayMode: .desktop), publication: .create
        ), workspacePublication: .create)
        publications = [
            .init(reference: boot, path: root + "/kernel", kind: .installedLinuxBootBundle,
                  source: .bundledByDory, mutability: .immutable),
            .init(reference: disk, path: root + "/disk", kind: .virtualDisk,
                  source: .userProvided, mutability: .mutable),
        ]
        authority = DoryVirtualMachineArtifactAuthority(root: root + "/authority")
        let workspaces = DoryWorkspaceRepository(root: root + "/machines")
        let plans = DoryResolvedMachinePlanRepository(root: root + "/machines")
        let registry = try BackendRegistry(backends: [])
        planner = .init(registry: registry, inventory: probe, plans: plans)
        transaction = .init(stateDirectory: root + "/transactions", registry: registry,
                            trust: probe, mutationAuthority: probe, workspaces: workspaces, plans: plans,
                            ledger: DoryVirtualMachineResourceAdmissionLedger(root: root + "/ledger"))
        controller = .init(artifactAuthority: authority, coordinator: probe, workspaces: workspaces, plans: plans)
    }

    func files() throws -> [String: Data] {
        var result: [String: Data] = [:]
        for path in FileManager.default.enumerator(atPath: root)?.allObjects as? [String] ?? [] {
            var directory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: root + "/" + path, isDirectory: &directory)
            result[path] = directory.boolValue ? Data() : try Data(contentsOf: URL(fileURLWithPath: root + "/" + path))
        }
        return result
    }

    func cleanup() { try? FileManager.default.removeItem(atPath: root) }
}

private final class ImmutablePreflightProbe: DoryDaemonVirtualMachineTrustInventory,
    DoryDaemonVirtualMachinePlanningTrustPreparing, DoryDaemonVirtualMachinePlanningMutationAuthorizing,
    DoryDaemonVirtualMachinePlanningTransactionCoordinating, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var recordedOperationID: UUID?
    var calls: [String] { lock.withLock { recorded } }
    var operationID: UUID? { lock.withLock { recordedOperationID } }
    private enum Rejection: Error { case expected }
    func planningInventory(for request: DoryDaemonVirtualMachineInventoryRequest) throws -> DoryDaemonVirtualMachineTrustedInventorySnapshot {
        lock.withLock { recorded.append("inventory") }
        throw Rejection.expected
    }
    func startInventory(for request: DoryDaemonVirtualMachineStartInventoryRequest) throws -> DoryDaemonVirtualMachineTrustedInventorySnapshot {
        lock.withLock { recorded.append("start") }
        throw Rejection.expected
    }
    func preparePlanningTrust(for request: DoryDaemonVirtualMachineInventoryRequest) throws -> DoryDaemonVirtualMachinePlanningTrustPreparation {
        lock.withLock { recorded.append("trust") }
        throw Rejection.expected
    }
    func acquirePlanningMutationFence(operationID: UUID, machine: DoryMachineConfiguration,
                                     definition: DoryVirtualMachineDefinition,
                                     canonicalDefinitionData: Data) throws -> DoryDaemonVirtualMachinePlanningMutationFence {
        lock.withLock { recorded.append("workspace") }
        throw Rejection.expected
    }
    func resolveReserveAndPublish(_ request: DoryDaemonVirtualMachinePlanningTransactionRequest) throws -> DoryDaemonVirtualMachinePlanningTransactionResult {
        lock.withLock { recorded.append("transaction"); recordedOperationID = request.operationID }
        throw Rejection.expected
    }
}
