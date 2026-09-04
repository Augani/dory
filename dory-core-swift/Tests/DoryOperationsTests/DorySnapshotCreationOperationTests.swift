import Foundation
import Testing
@testable import DoryOperations

@Suite("Caller-root snapshot operation authority")
struct DorySnapshotCreationOperationTests {
    @Test("snapshot begins before artifact evidence exists but binds unchanged workspace authority",
          arguments: [DoryWorkspaceLifecycleState.created, .stopped, .running, .paused])
    func sourcePowerState(state: DoryWorkspaceLifecycleState) throws {
        let operation = snapshot(state: state)
        #expect(operation.validate().isEmpty)
        #expect(operation.targetSnapshotAuthority == nil)
        #expect(operation.target.runtime == nil)
        #expect(try JSONDecoder().decode(DoryWorkspaceLifecycleOperation.self, from: JSONEncoder().encode(operation)) == operation)
        var noReadiness = operation
        noReadiness.readinessGates = []
        #expect(noReadiness.validate().isEmpty == ![.running, .paused].contains(state))
    }

    @Test("snapshot requirements cannot authorize start or unrelated publication", arguments: [
        "start", "restart", "restore", "missing-spec", "another-spec", "revision", "configuration", "abi",
        "resource", "early-evidence", "helper", "runtime"
    ])
    func rejectsSubstitution(mutation: String) {
        var operation = snapshot(state: .running)
        switch mutation {
        case "start": operation.kind = .starting
        case "restart": operation.kind = .restarting
        case "restore": operation.kind = .restoring
        case "missing-spec": operation.snapshotSpecificationDigest = nil
        case "another-spec": operation.creationSpecificationDigest = digest("d")
        case "revision": operation.target.definitionRevision = 2
        case "configuration": operation.target.configurationAuthority?.legacyConfigurationSHA256 = digest("f")
        case "abi": operation.target.plannedRuntime?.virtualHardwareABIVersion = 2
        case "resource": operation.targetResourceID = nil
        case "early-evidence": operation.targetSnapshotAuthority = .init(descriptorSHA256: digest("e"), artifactEvidenceSHA256: digest("f"))
        case "helper": operation.sourceRuntimeOperationID = nil
        default: operation.target.runtime = operation.source.runtime
        }
        #expect(!operation.validate().isEmpty)
    }

    @Test("typed snapshot private specification is published and validated with its caller root")
    func privateSpecification() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-root-contract-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DoryOperationJournalStore(home: root.path)
        let specification = try DoryOperationSpecification(canonical: ["source": "immutable snapshot request"])
        var operation = snapshot(state: .stopped)
        operation.snapshotSpecificationDigest = specification.digest
        let binding = try operation.journalBinding(dependencyClosureDigest: digest("a"))
        #expect(throws: DoryOperationJournalError.self) { try store.begin(binding) }
        let lease = try store.begin(binding, snapshotSpecification: specification)
        #expect(try lease.readWorkspaceLifecycleOperation() == operation)
        #expect(try lease.readSpecification(digest: specification.digest) == specification.data)
    }

    private func snapshot(state: DoryWorkspaceLifecycleState) -> DoryWorkspaceLifecycleOperation {
        let source = DoryWorkspaceLifecycleCondition(workspaceID: "source", state: state, definitionRevision: 1,
            runtime: .resolvedPlan(.init(planRevision: 1, planDigest: digest("c"), backendID: "native-hv-arm64",
                backendRuntimeBuildID: "fixture", virtualHardwareABIVersion: 1), runtimeIdentityDigest: digest("e")),
            configurationAuthority: .init(legacyConfigurationSHA256: digest("a"), canonicalDefinitionSHA256: digest("b")))
        return .init(kind: .snapshotting, source: source,
            target: .init(workspaceID: "source", state: state == .created ? .stopped : state, definitionRevision: 1,
                configurationAuthority: source.configurationAuthority,
                plannedRuntime: .init(configurationSHA256: digest("a"), virtualHardwareABIVersion: 1)),
            targetResourceID: "snapshot", createdAtUnixMilliseconds: 1000, deadlineUnixMilliseconds: 6000,
            steps: [.init(id: "capture", stage: .mutate, deadlineOffsetMilliseconds: 3000)],
            readinessGates: [.running, .paused].contains(state) ? [.init(kind: .backendRunning, deadlineOffsetMilliseconds: 4000)] : [],
            cancellationPolicy: .rollbackRequired, recovery: .init(disposition: .retry, stepIDs: ["capture"]),
            sourceRuntimeOperationID: [.running, .paused].contains(state) ? UUID() : nil,
            snapshotSpecificationDigest: digest("d"))
    }

    private func digest(_ value: Character) -> String { String(repeating: value, count: 64) }
}
