import Foundation
import Testing
@testable import DoryOperations

@Suite("Workspace lifecycle operation contract")
struct DoryWorkspaceLifecycleOperationTests {
    @Test("start binds exact state plan ABI deadlines readiness and recovery into journal bytes")
    func validStartContract() throws {
        let operation = makeOperation()
        #expect(operation.validate().isEmpty)
        #expect(operation.kind.journalKind == .workspaceStart)

        let specification = try operation.journalSpecification()
        #expect(DoryOperationJournalStore.isDigest(specification.digest))
        let decoded = try JSONDecoder().decode(
            DoryWorkspaceLifecycleOperation.self,
            from: specification.data
        )
        #expect(decoded == operation)
        #expect(decoded.target.resolved?.backendRuntimeBuildID == "dory-hv-1.0.0")
        #expect(decoded.target.resolved?.virtualHardwareABIVersion == 1)

        let binding = try operation.journalBinding(
            dependencyClosureDigest: String(repeating: "b", count: 64)
        )
        #expect(binding.plan.id == operation.operationID)
        #expect(binding.plan.kind == .workspaceStart)
        #expect(binding.plan.selectionDigest == binding.specification.digest)
        #expect(binding.plan.source.id == "workspace-one")
        #expect(binding.plan.target.id == "workspace-one")
        #expect(binding.plan.dependencyClosureDigest == String(repeating: "b", count: 64))
        #expect(binding.plan.successCriteriaDigest == binding.plan.target.fingerprint)
    }

    @Test("journal atomically persists and restart rebinds the exact lifecycle contract")
    func journalPersistenceAndTamperDetection() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-workspace-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }

        let operation = makeOperation()
        let binding = try operation.journalBinding(
            dependencyClosureDigest: String(repeating: "b", count: 64)
        )
        let store = try DoryOperationJournalStore(home: home.path)
        var lease: DoryOperationLease? = try store.begin(binding)
        #expect(try lease?.readWorkspaceLifecycleOperation() == operation)
        lease = nil

        let acquired = try store.acquire(operation.operationID)
        #expect(try acquired.readWorkspaceLifecycleOperation() == operation)
        let specificationPath = store.operationDirectory(for: operation.operationID)
            + "/specs/objects/" + binding.specification.digest
        var tampered = binding.specification.data
        tampered.append(Data("tampered".utf8))
        try tampered.write(to: URL(fileURLWithPath: specificationPath))
        #expect(throws: DoryOperationJournalError.self) {
            _ = try acquired.readWorkspaceLifecycleOperation()
        }
    }

    @Test("all lifecycle mutation kinds have stable journal kinds")
    func journalKinds() {
        #expect(Set(DoryWorkspaceMutationKind.allCases.map(\.journalKind.rawValue)).count
            == DoryWorkspaceMutationKind.allCases.count)
        #expect(DoryWorkspaceMutationKind.deleting.journalKind == .workspaceDelete)
        #expect(DoryWorkspaceMutationKind.snapshotting.journalKind == .workspaceSnapshot)
    }

    @Test("start requires exact resolved source target and backend readiness")
    func startRequirements() {
        var operation = makeOperation()
        operation.source.resolved = nil
        #expect(has(.invalidCondition, "source", operation))

        operation = makeOperation()
        operation.readinessGates = []
        #expect(has(.invalidReadinessGates, "readinessGates", operation))

        operation = makeOperation()
        operation.target.state = .paused
        #expect(has(.invalidTransition, "target.state", operation))
    }

    @Test("deadlines steps retry budgets and recovery are deterministic and bounded")
    func executionContractValidation() {
        var operation = makeOperation()
        operation.steps.swapAt(0, 1)
        #expect(has(.invalidSteps, "steps", operation))

        operation = makeOperation()
        operation.steps[1].id = operation.steps[0].id
        #expect(has(.invalidSteps, "steps", operation))

        operation = makeOperation()
        operation.retryBudgets.append(operation.retryBudgets[0])
        #expect(has(.invalidRetryBudgets, "retryBudgets", operation))

        operation = makeOperation()
        operation.recovery.stepIDs = ["not-in-plan"]
        #expect(has(.invalidRecoveryRecipe, "recovery", operation))

        operation = makeOperation()
        operation.deadlineUnixMilliseconds = operation.createdAtUnixMilliseconds
        #expect(has(.invalidDeadline, "deadlineUnixMilliseconds", operation))
    }

    @Test("clone requires a distinct target workspace and delete enters tombstone state")
    func targetRules() {
        let resolved = resolvedCondition()
        var clone = DoryWorkspaceLifecycleOperation(
            kind: .cloning,
            source: condition(.stopped, resolved: resolved),
            target: condition(.stopped, workspaceID: "workspace-copy", resolved: resolved),
            createdAtUnixMilliseconds: 1_700_000_000_000,
            deadlineUnixMilliseconds: 1_700_000_060_000,
            steps: [step("clone", 30_000)],
            cancellationPolicy: .beforePublish,
            recovery: .init(disposition: .rollback, stepIDs: ["clone"])
        )
        #expect(has(.invalidTargetWorkspace, "targetWorkspaceID", clone))
        clone.targetWorkspaceID = "workspace-copy"
        #expect(clone.validate().isEmpty)

        let deletion = DoryWorkspaceLifecycleOperation(
            kind: .deleting,
            source: condition(.stopped, resolved: resolved),
            target: condition(.deleting, resolved: resolved),
            createdAtUnixMilliseconds: 1_700_000_000_000,
            deadlineUnixMilliseconds: 1_700_000_060_000,
            steps: [step("tombstone", 10_000), step("release-artifacts", 50_000)],
            cancellationPolicy: .prohibited,
            recovery: .init(disposition: .repair, stepIDs: ["tombstone"])
        )
        #expect(deletion.validate().isEmpty)
    }

    @Test("restore readiness follows the target and an unresolved definition can be deleted")
    func targetSensitiveRequirements() {
        let resolved = resolvedCondition()
        let restoreStopped = DoryWorkspaceLifecycleOperation(
            kind: .restoring,
            source: condition(.stopped, resolved: resolved),
            target: condition(.stopped, resolved: resolved),
            createdAtUnixMilliseconds: 1_700_000_000_000,
            deadlineUnixMilliseconds: 1_700_000_060_000,
            steps: [step("restore", 50_000)],
            cancellationPolicy: .rollbackRequired,
            recovery: .init(disposition: .rollback, stepIDs: ["restore"])
        )
        #expect(restoreStopped.validate().isEmpty)

        var restoreRunning = restoreStopped
        restoreRunning.target.state = .running
        #expect(has(.invalidReadinessGates, "readinessGates", restoreRunning))

        let deleteDefined = DoryWorkspaceLifecycleOperation(
            kind: .deleting,
            source: condition(.defined, resolved: nil),
            target: condition(.deleting, resolved: nil),
            createdAtUnixMilliseconds: 1_700_000_000_000,
            deadlineUnixMilliseconds: 1_700_000_060_000,
            steps: [step("tombstone", 10_000)],
            cancellationPolicy: .prohibited,
            recovery: .init(disposition: .repair, stepIDs: ["tombstone"])
        )
        #expect(deleteDefined.validate().isEmpty)
    }

    @Test("operation identifiers reject path secret and control-like values")
    func identifierSafety() {
        var operation = makeOperation()
        operation.source.workspaceID = "../workspace"
        operation.target.workspaceID = "../workspace"
        #expect(has(.invalidCondition, "source", operation))
        #expect(has(.invalidCondition, "target", operation))

        operation = makeOperation()
        operation.retryBudgets[0].failureClass = "token=secret"
        #expect(has(.invalidRetryBudgets, "retryBudgets", operation))
    }

    @Test("zero UUID and absent condition payloads fail closed")
    func identityAndAbsentCondition() {
        var operation = makeOperation()
        operation.operationID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        #expect(has(.invalidOperationID, "operationID", operation))

        operation = makeOperation()
        operation.source = DoryWorkspaceLifecycleCondition(
            workspaceID: "workspace-one",
            state: .absent,
            definitionRevision: 1
        )
        #expect(has(.invalidCondition, "source", operation))
    }

    private func makeOperation() -> DoryWorkspaceLifecycleOperation {
        let resolved = resolvedCondition()
        return DoryWorkspaceLifecycleOperation(
            operationID: UUID(uuidString: "8f9f5b13-77ee-4f59-8a13-1704147c7f00")!,
            kind: .starting,
            source: condition(.stopped, resolved: resolved),
            target: condition(.running, resolved: resolved),
            createdAtUnixMilliseconds: 1_700_000_000_000,
            deadlineUnixMilliseconds: 1_700_000_060_000,
            steps: [step("validate-plan", 5_000), step("launch", 20_000), step("ready", 55_000)],
            readinessGates: [
                .init(kind: .backendRunning, deadlineOffsetMilliseconds: 20_000),
                .init(kind: .firstDisplayFrame, deadlineOffsetMilliseconds: 40_000),
                .init(kind: .guestAgent, deadlineOffsetMilliseconds: 55_000)
            ],
            retryBudgets: [
                .init(failureClass: "helper-crash", maximumAttempts: 2),
                .init(failureClass: "agent-timeout", maximumAttempts: 1)
            ],
            cancellationPolicy: .beforeGuestMutation,
            recovery: .init(disposition: .rollback, stepIDs: ["validate-plan", "launch"])
        )
    }

    private func condition(
        _ state: DoryWorkspaceLifecycleState,
        workspaceID: String = "workspace-one",
        resolved: DoryWorkspaceResolvedCondition?
    ) -> DoryWorkspaceLifecycleCondition {
        DoryWorkspaceLifecycleCondition(
            workspaceID: workspaceID,
            state: state,
            definitionRevision: 3,
            resolved: resolved
        )
    }

    private func resolvedCondition() -> DoryWorkspaceResolvedCondition {
        DoryWorkspaceResolvedCondition(
            planRevision: 4,
            planDigest: String(repeating: "a", count: 64),
            backendID: "dory-hv-linux",
            backendRuntimeBuildID: "dory-hv-1.0.0",
            virtualHardwareABIVersion: 1
        )
    }

    private func step(_ id: String, _ deadline: UInt64) -> DoryWorkspaceOperationStep {
        DoryWorkspaceOperationStep(
            id: id,
            stage: id == "ready" ? .readiness : .mutate,
            deadlineOffsetMilliseconds: deadline
        )
    }

    private func has(
        _ code: DoryWorkspaceOperationValidationCode,
        _ field: String,
        _ operation: DoryWorkspaceLifecycleOperation
    ) -> Bool {
        operation.validate().contains { $0.code == code && $0.field == field }
    }
}
