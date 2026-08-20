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

    @Test("schema v2 importing persists an explicit absent-condition discriminator")
    func importingAbsentConditionJournalRoundTrip() throws {
        let operation = DoryWorkspaceLifecycleOperation(
            operationID: UUID(uuidString: "c4cf98dc-c476-40c6-b5e9-f05f460b465f")!,
            kind: .importing,
            source: DoryWorkspaceLifecycleCondition(
                workspaceID: "workspace-import",
                state: .absent
            ),
            target: condition(
                .defined,
                workspaceID: "workspace-import",
                resolved: nil
            ),
            createdAtUnixMilliseconds: 1_700_000_000_000,
            deadlineUnixMilliseconds: 1_700_000_060_000,
            steps: [step("import", 50_000)],
            cancellationPolicy: .beforePublish,
            recovery: .init(disposition: .rollback, stepIDs: ["import"])
        )
        #expect(operation.validate().isEmpty)
        let binding = try operation.journalBinding(
            dependencyClosureDigest: String(repeating: "b", count: 64)
        )
        #expect(binding.specification.data.range(of: Data("conditionSchemaVersion".utf8)) != nil)

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-workspace-import-v2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try DoryOperationJournalStore(home: home.path)
        var lease: DoryOperationLease? = try store.begin(binding)
        #expect(try lease?.readWorkspaceLifecycleOperation() == operation)
        lease = nil
        let recovered = try store.acquire(operation.operationID)
        #expect(try recovered.readWorkspaceLifecycleOperation() == operation)
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
        operation.source.runtime = nil
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
            targetResourceID: "workspace-copy",
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
            target: condition(.stopped, resolved: nil, requiresReplanning: true),
            targetResourceID: "snapshot-one",
            targetSnapshotAuthority: snapshotAuthority(),
            createdAtUnixMilliseconds: 1_700_000_000_000,
            deadlineUnixMilliseconds: 1_700_000_060_000,
            steps: [step("restore", 50_000)],
            cancellationPolicy: .rollbackRequired,
            recovery: .init(disposition: .rollback, stepIDs: ["restore"])
        )
        #expect(restoreStopped.validate().isEmpty)

        var missingSnapshotAuthority = restoreStopped
        missingSnapshotAuthority.targetSnapshotAuthority = nil
        #expect(has(.invalidCondition, "targetSnapshotAuthority", missingSnapshotAuthority))

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

    @Test("schema v1 resolved journals migrate into strict tagged runtime bindings")
    func schemaV1GoldenMigration() throws {
        let json = """
        {
          "schemaVersion": 1,
          "operationID": "8F9F5B13-77EE-4F59-8A13-1704147C7F00",
          "kind": "starting",
          "source": {
            "workspaceID": "workspace-one", "state": "stopped", "definitionRevision": 3,
            "resolved": {
              "planRevision": 4,
              "planDigest": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "backendID": "dory-hv-linux", "backendRuntimeBuildID": "dory-hv-1.0.0",
              "virtualHardwareABIVersion": 1
            }
          },
          "target": {
            "workspaceID": "workspace-one", "state": "running", "definitionRevision": 3,
            "resolved": {
              "planRevision": 4,
              "planDigest": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "backendID": "dory-hv-linux", "backendRuntimeBuildID": "dory-hv-1.0.0",
              "virtualHardwareABIVersion": 1
            }
          },
          "createdAtUnixMilliseconds": 1700000000000,
          "deadlineUnixMilliseconds": 1700000060000,
          "steps": [
            {"id":"launch","stage":"launch","deadlineOffsetMilliseconds":20000},
            {"id":"ready","stage":"readiness","deadlineOffsetMilliseconds":55000}
          ],
          "readinessGates": [
            {"kind":"backendRunning","required":true,"deadlineOffsetMilliseconds":20000}
          ],
          "retryBudgets": [],
          "cancellationPolicy": "beforeGuestMutation",
          "recovery": {"disposition":"rollback","stepIDs":["launch"]}
        }
        """
        let migrated = try JSONDecoder().decode(
            DoryWorkspaceLifecycleOperation.self,
            from: Data(json.utf8)
        )
        #expect(migrated.schemaVersion == 1)
        #expect(migrated.sourceSchemaVersion == 1)
        #expect(migrated.source.runtime?.policy == .requireResolvedPlan)
        #expect(migrated.source.runtime?.authorizationState == .resolvedPlan)
        #expect(migrated.source.runtime?.resolved?.planRevision == 4)
        #expect(migrated.source.runtime?.runtimeIdentityDigest == String(repeating: "a", count: 64))
        #expect(migrated.validate().isEmpty)

        let reencoded = try JSONEncoder().encode(migrated)
        let current = try JSONDecoder().decode(
            DoryWorkspaceLifecycleOperation.self,
            from: reencoded
        )
        #expect(current == migrated)

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-workspace-lifecycle-v1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }
        let binding = try migrated.journalBinding(
            dependencyClosureDigest: String(repeating: "b", count: 64)
        )
        #expect(binding.specification.data.range(of: Data("sourceSchemaVersion".utf8)) == nil)
        #expect(binding.specification.data.range(of: Data("runtimeIdentityDigest".utf8)) == nil)
        #expect(binding.specification.data.range(of: Data("resolved".utf8)) != nil)
        let store = try DoryOperationJournalStore(home: home.path)
        var lease: DoryOperationLease? = try store.begin(binding)
        #expect(try lease?.readWorkspaceLifecycleOperation() == migrated)
        lease = nil
        let recovered = try store.acquire(migrated.operationID)
        #expect(try recovered.readWorkspaceLifecycleOperation() == migrated)

        let legacyRestoreData = Data(
            json.replacingOccurrences(of: "\"kind\": \"starting\"", with: "\"kind\": \"restoring\"")
                .replacingOccurrences(of: "\"state\": \"running\"", with: "\"state\": \"stopped\"")
                .utf8
        )
        let legacyRestore = try JSONDecoder().decode(
            DoryWorkspaceLifecycleOperation.self,
            from: legacyRestoreData
        )
        #expect(legacyRestore.targetSnapshotAuthority == nil)
        #expect(legacyRestore.validate().isEmpty)
        #expect(legacyRestore.target.runtime?.authorizationState == .resolvedPlan)
    }

    @Test("schema v2 cannot claim v1 authority and exact runtime identity cannot drift")
    func schemaAndRuntimeAuthorityAreExact() throws {
        let dishonest = """
        {
          "schemaVersion": 2, "sourceSchemaVersion": 1,
          "operationID": "8F9F5B13-77EE-4F59-8A13-1704147C7F00",
          "kind": "starting", "source": {}, "target": {},
          "createdAtUnixMilliseconds": 1700000000000,
          "deadlineUnixMilliseconds": 1700000060000,
          "steps": [], "readinessGates": [], "retryBudgets": [],
          "cancellationPolicy": "prohibited",
          "recovery": {"disposition":"rollback","stepIDs":[]}
        }
        """
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                DoryWorkspaceLifecycleOperation.self,
                from: Data(dishonest.utf8)
            )
        }

        var operation = makeOperation()
        operation.target.runtime?.runtimeIdentityDigest = String(repeating: "f", count: 64)
        #expect(has(.invalidCondition, "target.runtime", operation))
    }

    @Test("legacy compatibility is an explicit ABI and identity binding, never a plan claim")
    func legacyCompatibilityBindingIsExplicit() {
        var operation = makeOperation()
        let legacy = DoryWorkspaceRuntimeBinding.legacyCompatibility(
            virtualHardwareABIVersion: 1,
            runtimeIdentityDigest: String(repeating: "9", count: 64)
        )
        operation.source.runtime = legacy
        operation.target.runtime = legacy
        #expect(operation.validate().isEmpty)

        operation.target.runtime = DoryWorkspaceRuntimeBinding(
            policy: .legacyCompatibility,
            authorizationState: .legacyCompatibility,
            virtualHardwareABIVersion: 1,
            runtimeIdentityDigest: String(repeating: "9", count: 64),
            resolved: resolvedCondition()
        )
        #expect(has(.invalidCondition, "target", operation))
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
        resolved: DoryWorkspaceResolvedCondition?,
        requiresReplanning: Bool = false
    ) -> DoryWorkspaceLifecycleCondition {
        let runtime: DoryWorkspaceRuntimeBinding?
        if let resolved {
            runtime = .resolvedPlan(
                resolved,
                runtimeIdentityDigest: String(repeating: "e", count: 64)
            )
        } else if requiresReplanning {
            runtime = .requiresReplanning(
                virtualHardwareABIVersion: 1,
                runtimeIdentityDigest: String(repeating: "f", count: 64)
            )
        } else {
            runtime = nil
        }
        return DoryWorkspaceLifecycleCondition(
            workspaceID: workspaceID,
            state: state,
            definitionRevision: 3,
            runtime: runtime,
            configurationAuthority: DoryWorkspaceConfigurationAuthority(
                legacyConfigurationSHA256: String(repeating: "c", count: 64),
                canonicalDefinitionSHA256: String(repeating: "d", count: 64)
            )
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

    private func snapshotAuthority() -> DoryWorkspaceSnapshotAuthority {
        DoryWorkspaceSnapshotAuthority(
            descriptorSHA256: String(repeating: "6", count: 64),
            artifactEvidenceSHA256: String(repeating: "7", count: 64)
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
