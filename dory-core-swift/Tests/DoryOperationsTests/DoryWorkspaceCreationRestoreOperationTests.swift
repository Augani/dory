import Foundation
import Testing
@testable import DoryOperations

@Suite("Creation and snapshot restore operation authority")
struct DoryWorkspaceCreationRestoreOperationTests {
    @Test("creation binds absent destination intent without inventing runtime authority")
    func creationRequirement() throws {
        let operation = creation()
        #expect(operation.validate().isEmpty)
        #expect(try JSONDecoder().decode(DoryWorkspaceLifecycleOperation.self, from: JSONEncoder().encode(operation)) == operation)
        for kind in [DoryWorkspaceMutationKind.starting, .restarting, .restoring, .resolving, .updating] {
            var substituted = operation
            substituted.kind = kind
            #expect(!substituted.validate().isEmpty)
        }
        for mutation in ["source-exists", "missing-spec", "invented-runtime", "revision", "source-requirement"] {
            var changed = operation
            switch mutation {
            case "source-exists": changed.source = source()
            case "missing-spec": changed.creationSpecificationDigest = nil
            case "invented-runtime": changed.target.runtime = source().runtime
            case "revision": changed.target.definitionRevision = 2
            default: changed.source.creation = changed.target.creation
            }
            #expect(!changed.validate().isEmpty)
        }
    }

    @Test("clone binds the existing source and a different new target without replacing source runtime",
          arguments: [DoryWorkspaceLifecycleState.created, .stopped, .running, .paused, .suspended])
    func cloneSource(sourceState: DoryWorkspaceLifecycleState) throws {
        var operation = creation()
        operation.kind = .cloning
        operation.source = source(state: sourceState)
        operation.target.workspaceID = "clone"
        operation.targetWorkspaceID = "clone"
        operation.targetResourceID = "snapshot"
        operation.targetSnapshotAuthority = .init(descriptorSHA256: digest("6"), artifactEvidenceSHA256: digest("7"))
        #expect(operation.validate().isEmpty)
        var migratedClone = operation
        migratedClone.source.runtime = .legacyCompatibility(virtualHardwareABIVersion: 1, runtimeIdentityDigest: digest("2"))
        #expect(migratedClone.validate().isEmpty)
        #expect(migratedClone.source.runtime?.policy == .legacyCompatibility)
        #expect(migratedClone.target.creation?.runtimePolicy == .requireResolvedPlan)
        for mutation in ["same-workspace", "missing-snapshot", "missing-authority", "abi", "runtime-policy"] {
            var changed = operation
            switch mutation {
            case "same-workspace": changed.target.workspaceID = changed.source.workspaceID
            case "missing-snapshot": changed.targetResourceID = nil
            case "missing-authority": changed.targetSnapshotAuthority = nil
            case "abi": changed.target.creation?.virtualHardwareABIVersion = 2
            default: changed.target.creation?.runtimePolicy = .legacyCompatibility
            }
            #expect(!changed.validate().isEmpty)
        }
    }

    @Test("restore binds exact future bytes and requires readiness only when restoring an active target",
          arguments: [DoryWorkspaceLifecycleState.created, .stopped, .running, .paused],
          [DoryWorkspaceLifecycleState.stopped, .running, .paused])
    func restoreStates(sourceState: DoryWorkspaceLifecycleState, targetState: DoryWorkspaceLifecycleState) throws {
        for revision in [UInt64(5), nil] {
            var operation = restore(sourceState: sourceState, targetState: targetState)
            operation.target.definitionRevision = revision
            #expect(operation.validate().isEmpty)
            #expect(try JSONDecoder().decode(DoryWorkspaceLifecycleOperation.self, from: JSONEncoder().encode(operation)) == operation)
            operation.readinessGates = []
            #expect(operation.validate().isEmpty == (targetState == .stopped))
        }
    }

    @Test("restore postconditions cannot substitute for launch authority or other private payloads",
          arguments: ["kind", "source-abi", "source-revision", "target-revision", "configuration-bytes", "runtime", "missing-spec", "missing-snapshot", "saved-state", "competing-spec", "inactive-helper", "missing-helper", "caller-helper"])
    func rejectsRestoreSubstitution(mutation: String) throws {
        var operation = restore()
        switch mutation {
        case "kind": operation.kind = .starting
        case "source-abi": operation.target.plannedRuntime?.virtualHardwareABIVersion = 2
        case "source-revision": operation.source.definitionRevision = nil
        case "target-revision": operation.target.definitionRevision = 7
        case "configuration-bytes": operation.target.configurationAuthority?.legacyConfigurationSHA256 = digest("b")
        case "runtime": operation.target.runtime = operation.source.runtime
        case "missing-spec": operation.snapshotRestoreSpecificationDigest = nil
        case "missing-snapshot": operation.targetSnapshotAuthority = nil
        case "saved-state": operation.targetResourceID = DoryWorkspaceLifecycleOperation.savedStateResourceID
        case "inactive-helper": operation.sourceRuntimeOperationID = UUID()
        case "missing-helper": operation.source.state = .running
        case "caller-helper":
            operation.source.state = .running
            operation.sourceRuntimeOperationID = operation.operationID
        default: operation.configurationUpdateSpecificationDigest = digest("c")
        }
        #expect(!operation.validate().isEmpty)
    }

    @Test("private creation and restore specifications are mandatory and content-bound on durable replay",
          arguments: [false, true])
    func privatePayload(restoreSnapshot: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dory-create-restore-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DoryOperationJournalStore(home: root.path)
        let payload = try DoryOperationSpecification(canonical: ["request": "exact private authority"])
        var operation = restoreSnapshot ? restore() : creation()
        if restoreSnapshot { operation.snapshotRestoreSpecificationDigest = payload.digest }
        else { operation.creationSpecificationDigest = payload.digest }
        let binding = try operation.journalBinding(dependencyClosureDigest: digest("d"))
        #expect(throws: DoryOperationJournalError.self) { _ = try store.begin(binding) }
        let lease = try store.begin(binding, snapshotRestoreSpecification: restoreSnapshot ? payload : nil,
                                    creationSpecification: restoreSnapshot ? nil : payload)
        #expect(try lease.readWorkspaceLifecycleOperation() == operation)
        let bytes = try lease.readSpecification(digest: payload.digest)
        #expect(bytes == payload.data)
        var competing = operation
        competing.desktopUpdateSpecificationDigest = digest("c")
        #expect(!competing.validate().isEmpty)
    }

    private func creation() -> DoryWorkspaceLifecycleOperation {
        .init(kind: .provisioning,
              source: .init(workspaceID: "machine", state: .absent),
              target: .init(workspaceID: "machine", state: .created, definitionRevision: 1,
                            creation: .init(requestSHA256: digest("8"), virtualHardwareABIVersion: 1, runtimePolicy: .requireResolvedPlan)),
              createdAtUnixMilliseconds: 1_000, deadlineUnixMilliseconds: 61_000,
              steps: [.init(id: "create", stage: .prepare, deadlineOffsetMilliseconds: 30_000)],
              cancellationPolicy: .rollbackRequired, recovery: .init(disposition: .rollback, stepIDs: ["create"]),
              creationSpecificationDigest: digest("9"))
    }

    private func source(state: DoryWorkspaceLifecycleState = .stopped) -> DoryWorkspaceLifecycleCondition {
        .init(workspaceID: "machine", state: state, definitionRevision: 4,
              runtime: .resolvedPlan(.init(planRevision: 2, planDigest: digest("1"), backendID: "native-hv-arm64",
                                          backendRuntimeBuildID: "runtime-v1", virtualHardwareABIVersion: 1), runtimeIdentityDigest: digest("2")),
              configurationAuthority: .init(legacyConfigurationSHA256: digest("3"), canonicalDefinitionSHA256: digest("4")))
    }

    private func restore(sourceState: DoryWorkspaceLifecycleState = .stopped,
                         targetState: DoryWorkspaceLifecycleState = .stopped) -> DoryWorkspaceLifecycleOperation {
        let active = [.running, .paused].contains(sourceState)
        return .init(kind: .restoring, source: source(state: sourceState),
              target: .init(workspaceID: "machine", state: targetState, definitionRevision: 5,
                            configurationAuthority: .init(legacyConfigurationSHA256: digest("5"), canonicalDefinitionSHA256: digest("6")),
                            plannedRuntime: .init(configurationSHA256: digest("5"), virtualHardwareABIVersion: 1)),
              targetResourceID: "snapshot", targetSnapshotAuthority: .init(descriptorSHA256: digest("7"), artifactEvidenceSHA256: digest("8")),
              createdAtUnixMilliseconds: 1_000, deadlineUnixMilliseconds: 61_000,
              steps: [.init(id: "restore", stage: .mutate, deadlineOffsetMilliseconds: 30_000)],
              readinessGates: targetState == .stopped ? [] : [.init(kind: .backendRunning, deadlineOffsetMilliseconds: 50_000)],
              cancellationPolicy: .rollbackRequired, recovery: .init(disposition: .rollback, stepIDs: ["restore"]),
              sourceRuntimeOperationID: active ? UUID(uuidString: "11111111-2222-3333-4444-555555555555") : nil,
              snapshotRestoreSpecificationDigest: digest("9"))
    }

    private func digest(_ value: Character) -> String { String(repeating: value, count: 64) }
}
