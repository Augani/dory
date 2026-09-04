import Foundation
import Testing
@testable import DoryOperations

@Suite("Compound desktop update lifecycle authority")
struct DoryDesktopUpdateOperationTests {
    @Test("component postconditions preserve source power intent without pretending to be launch authority",
          arguments: [DoryWorkspaceLifecycleState.created, .stopped, .running, .paused])
    func componentRequirement(sourceState: DoryWorkspaceLifecycleState) throws {
        let operation = makeOperation(sourceState: sourceState)
        #expect(operation.validate().isEmpty)
        #expect(operation.target.runtime == nil)
        #expect(operation.target.plannedRuntime == nil)
        #expect(operation.target.configurationAuthority == nil)
        #expect(operation.target.state == (sourceState == .created ? .stopped : sourceState))
        #expect(try JSONDecoder().decode(
            DoryWorkspaceLifecycleOperation.self, from: JSONEncoder().encode(operation)
        ) == operation)
        for kind in [DoryWorkspaceMutationKind.starting, .restarting, .resuming, .restoring, .snapshotting] {
            var substituted = operation
            substituted.kind = kind
            #expect(!substituted.validate().isEmpty)
        }
    }

    @Test("desktop postconditions reject incomplete source and competing future authorities",
          arguments: [
            "configuration-spec", "runtime-target", "configuration-target", "planned-target",
            "source-postcondition", "source-replanning", "abi", "missing-spec", "missing-readiness",
            "optional-readiness", "revision-exhaustion", "target-revision",
          ])
    func rejectsAuthoritySubstitution(mutation: String) throws {
        var operation = makeOperation(sourceState: .stopped)
        switch mutation {
        case "configuration-spec":
            operation.configurationUpdateSpecificationDigest = digest("6")
        case "runtime-target":
            operation.target.runtime = operation.source.runtime
        case "configuration-target":
            operation.target.configurationAuthority = operation.source.configurationAuthority
        case "planned-target":
            operation.target.plannedRuntime = .init(configurationSHA256: digest("4"), virtualHardwareABIVersion: 1)
        case "source-postcondition":
            operation.source.desktopUpdate = operation.target.desktopUpdate
        case "source-replanning":
            operation.source.runtime = .requiresReplanning(virtualHardwareABIVersion: 1, runtimeIdentityDigest: digest("3"))
        case "abi":
            operation.target.desktopUpdate?.virtualHardwareABIVersion = 2
        case "missing-spec":
            operation.desktopUpdateSpecificationDigest = nil
        case "missing-readiness":
            operation.readinessGates = []
        case "optional-readiness":
            operation.readinessGates[0].required = false
        case "revision-exhaustion":
            operation.source.definitionRevision = UInt64.max - 1
            operation.target.definitionRevision = UInt64.max
        case "target-revision":
            operation.target.definitionRevision = 100
        default:
            Issue.record("unknown test mutation")
        }
        #expect(!operation.validate().isEmpty)
        #expect(throws: DoryOperationJournalError.self) {
            try operation.journalSpecification()
        }
    }

    @Test("the private desktop specification is required and content-bound before journal publication")
    func privateSpecificationCannotBeSubstituted() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-operation-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try DoryOperationJournalStore(home: home.path)
        let specification = try DoryOperationSpecification(data: Data("private desktop recovery authority".utf8))
        var operation = makeOperation(sourceState: .running)
        operation.desktopUpdateSpecificationDigest = specification.digest
        let binding = try operation.journalBinding(dependencyClosureDigest: digest("9"))
        #expect(throws: DoryOperationJournalError.self) { try store.begin(binding) }
        #expect(throws: DoryOperationJournalError.self) {
            try store.begin(
                binding,
                desktopUpdateSpecification: DoryOperationSpecification(data: Data("substitution".utf8))
            )
        }
        #expect(!FileManager.default.fileExists(atPath: store.operationDirectory(for: operation.operationID)))
        var lease: DoryOperationLease? = try store.begin(binding, desktopUpdateSpecification: specification)
        #expect(try lease?.readWorkspaceLifecycleOperation() == operation)
        lease = nil
        let reacquired = try store.acquire(operation.operationID)
        #expect(try reacquired.readSpecification(digest: specification.digest) == specification.data)
        let object = store.operationDirectory(for: operation.operationID) + "/specs/objects/" + specification.digest
        try Data("changed private recovery authority".utf8).write(to: URL(fileURLWithPath: object))
        #expect(throws: DoryOperationJournalError.self) { try reacquired.readWorkspaceLifecycleOperation() }
    }

    private func makeOperation(sourceState: DoryWorkspaceLifecycleState) -> DoryWorkspaceLifecycleOperation {
        DoryWorkspaceLifecycleOperation(
            kind: .updating,
            source: .init(
                workspaceID: "desktop",
                state: sourceState,
                definitionRevision: 3,
                runtime: .resolvedPlan(
                    .init(planRevision: 2, planDigest: digest("1"), backendID: "dory-hypervisor",
                          backendRuntimeBuildID: "runtime-1", virtualHardwareABIVersion: 1),
                    runtimeIdentityDigest: digest("3")
                ),
                configurationAuthority: .init(legacyConfigurationSHA256: digest("4"), canonicalDefinitionSHA256: digest("5"))
            ),
            target: .init(
                workspaceID: "desktop",
                state: sourceState == .created ? .stopped : sourceState,
                definitionRevision: 4,
                desktopUpdate: .init(authoritySHA256: digest("7"), virtualHardwareABIVersion: 1)
            ),
            createdAtUnixMilliseconds: 1_700_000_000_000,
            deadlineUnixMilliseconds: 1_700_000_060_000,
            steps: [.init(id: "update", stage: .mutate, deadlineOffsetMilliseconds: 30_000)],
            readinessGates: [.init(kind: .backendRunning, deadlineOffsetMilliseconds: 50_000)],
            cancellationPolicy: .rollbackRequired,
            recovery: .init(disposition: .rollback, stepIDs: ["update"]),
            desktopUpdateSpecificationDigest: digest("8")
        )
    }

    private func digest(_ character: Character) -> String { String(repeating: character, count: 64) }
}
