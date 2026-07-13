@testable import DoryOperations
import XCTest

final class DoryOperationPlannerTests: XCTestCase {
    func testPlanIsDeterministicAndContainsCompleteTopologicalClosure() throws {
        let first = try DoryOperationPlanner.plan(
            inventory: OperationPlanningFixtures.inventory(),
            intents: OperationPlanningFixtures.intents(),
            userSelection: [OperationPlanningFixtures.api, OperationPlanningFixtures.image],
            context: OperationPlanningFixtures.context
        )
        let second = try DoryOperationPlanner.plan(
            inventory: OperationPlanningFixtures.inventory().reversed(),
            intents: OperationPlanningFixtures.intents().reversed(),
            userSelection: [OperationPlanningFixtures.image, OperationPlanningFixtures.api],
            context: OperationPlanningFixtures.context
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(try first.canonicalDigest(), try second.canonicalDigest())
        XCTAssertEqual(Set(first.selectedObjectKeys), Set([
            OperationPlanningFixtures.image,
            OperationPlanningFixtures.volume,
            OperationPlanningFixtures.network,
            OperationPlanningFixtures.writableLayer,
            OperationPlanningFixtures.database,
            OperationPlanningFixtures.api
        ]))
        assertDependenciesPrecedeDependents(first)
        XCTAssertEqual(first.objects.last?.source, OperationPlanningFixtures.api)
    }

    func testUnselectedInventoryIsBoundWithoutChangingSelectedClosure() throws {
        let first = try DoryOperationPlanner.plan(
            inventory: OperationPlanningFixtures.inventory(unselectedDigest: OperationPlanningFixtures.digest("7")),
            intents: OperationPlanningFixtures.intents(),
            userSelection: [OperationPlanningFixtures.api],
            context: OperationPlanningFixtures.context
        )
        let changed = try DoryOperationPlanner.plan(
            inventory: OperationPlanningFixtures.inventory(unselectedDigest: OperationPlanningFixtures.digest("8")),
            intents: OperationPlanningFixtures.intents(),
            userSelection: [OperationPlanningFixtures.api],
            context: OperationPlanningFixtures.context
        )

        XCTAssertEqual(first.objects, changed.objects)
        XCTAssertNotEqual(first.sourceInventoryDigest, changed.sourceInventoryDigest)
        XCTAssertNotEqual(first.unselectedSourceInventoryDigest, changed.unselectedSourceInventoryDigest)
        XCTAssertEqual(
            try first.journalBinding().dependencyClosureDigest,
            try changed.journalBinding().dependencyClosureDigest
        )
        XCTAssertNotEqual(
            try first.journalBinding().successCriteriaDigest,
            try changed.journalBinding().successCriteriaDigest
        )
    }

    func testMissingDependencyAndCycleBlockPlanning() {
        let missing = OperationPlanningFixtures.key(.volume, "missing")
        let container = DoryOperationInventoryObject(
            key: OperationPlanningFixtures.api,
            sourceFingerprint: OperationPlanningFixtures.digest("1"),
            specificationDigest: OperationPlanningFixtures.digest("2"),
            dependencies: [missing]
        )
        XCTAssertThrowsError(try DoryOperationPlanner.plan(
            inventory: [container],
            intents: [intent(for: OperationPlanningFixtures.api, state: .running)],
            userSelection: [OperationPlanningFixtures.api],
            context: OperationPlanningFixtures.context
        )) { error in
            XCTAssertEqual(
                error as? DoryOperationPlannerError,
                .missingDependency(object: OperationPlanningFixtures.api, dependency: missing)
            )
        }

        let first = OperationPlanningFixtures.key(.container, "first")
        let second = OperationPlanningFixtures.key(.container, "second")
        let cycle = [
            inventoryObject(first, dependency: second),
            inventoryObject(second, dependency: first)
        ]
        XCTAssertThrowsError(try DoryOperationPlanner.plan(
            inventory: cycle,
            intents: [intent(for: first, state: .exited), intent(for: second, state: .exited)],
            userSelection: [first],
            context: OperationPlanningFixtures.context
        )) { error in
            XCTAssertEqual(error as? DoryOperationPlannerError, .dependencyCycle([first, second]))
        }
    }

    func testEveryClosureObjectRequiresOneValidIntentAndUniqueTarget() {
        XCTAssertThrowsError(try DoryOperationPlanner.plan(
            inventory: OperationPlanningFixtures.inventory(),
            intents: OperationPlanningFixtures.intents().filter { $0.source != OperationPlanningFixtures.volume },
            userSelection: [OperationPlanningFixtures.api],
            context: OperationPlanningFixtures.context
        )) { error in
            XCTAssertEqual(error as? DoryOperationPlannerError, .missingIntent(OperationPlanningFixtures.volume))
        }

        var duplicateTarget = OperationPlanningFixtures.intents()
        duplicateTarget = duplicateTarget.map { value in
            guard value.source == OperationPlanningFixtures.database else { return value }
            return DoryOperationObjectIntent(
                source: value.source,
                normalizedTargetName: "project-api",
                acceptedFinalState: value.acceptedFinalState
            )
        }
        XCTAssertThrowsError(try DoryOperationPlanner.plan(
            inventory: OperationPlanningFixtures.inventory(),
            intents: duplicateTarget,
            userSelection: [OperationPlanningFixtures.api],
            context: OperationPlanningFixtures.context
        )) { error in
            XCTAssertEqual(
                error as? DoryOperationPlannerError,
                .duplicateTargetName(kind: .container, name: "project-api")
            )
        }
    }

    func testIntentStateAndCollisionPolicyMustMatchObjectKind() {
        var invalidState = OperationPlanningFixtures.intents()
        invalidState = invalidState.map { value in
            guard value.source == OperationPlanningFixtures.volume else { return value }
            return DoryOperationObjectIntent(
                source: value.source,
                normalizedTargetName: value.normalizedTargetName,
                acceptedFinalState: .running
            )
        }
        XCTAssertThrowsError(try DoryOperationPlanner.plan(
            inventory: OperationPlanningFixtures.inventory(),
            intents: invalidState,
            userSelection: [OperationPlanningFixtures.api],
            context: OperationPlanningFixtures.context
        )) { error in
            XCTAssertEqual(
                error as? DoryOperationPlannerError,
                .invalidIntent(OperationPlanningFixtures.volume, field: "accepted final state")
            )
        }

        var invalidReuse = OperationPlanningFixtures.intents()
        invalidReuse = invalidReuse.map { value in
            guard value.source == OperationPlanningFixtures.volume else { return value }
            return DoryOperationObjectIntent(
                source: value.source,
                normalizedTargetName: value.normalizedTargetName,
                collisionDecision: .reuseVerified,
                acceptedFinalState: value.acceptedFinalState
            )
        }
        XCTAssertThrowsError(try DoryOperationPlanner.plan(
            inventory: OperationPlanningFixtures.inventory(),
            intents: invalidReuse,
            userSelection: [OperationPlanningFixtures.api],
            context: OperationPlanningFixtures.context
        )) { error in
            XCTAssertEqual(
                error as? DoryOperationPlannerError,
                .invalidIntent(OperationPlanningFixtures.volume, field: "collision decision")
            )
        }
    }

    func testJournalPlanCanOnlyBindCanonicalCompletenessDigests() throws {
        let completeness = try OperationPlanningFixtures.plan()
        let binding = try completeness.journalBinding()
        let authority = DoryOperationAuthority(
            kind: .dockerEngine,
            id: "engine",
            fingerprint: OperationPlanningFixtures.digest("a")
        )
        let journalPlan = try DoryOperationPlan(
            kind: .competitorImport,
            source: authority,
            target: authority,
            completenessPlan: completeness
        )

        XCTAssertEqual(journalPlan.selectionDigest, binding.selectionDigest)
        XCTAssertEqual(journalPlan.dependencyClosureDigest, binding.dependencyClosureDigest)
        XCTAssertEqual(journalPlan.successCriteriaDigest, binding.successCriteriaDigest)
    }

    private func assertDependenciesPrecedeDependents(_ plan: DoryOperationCompletenessPlan) {
        let positions = Dictionary(uniqueKeysWithValues: plan.objects.enumerated().map { ($1.source, $0) })
        for object in plan.objects {
            for dependency in object.dependencies {
                XCTAssertLessThan(positions[dependency]!, positions[object.source]!)
            }
        }
    }

    private func inventoryObject(
        _ key: DoryOperationObjectKey,
        dependency: DoryOperationObjectKey
    ) -> DoryOperationInventoryObject {
        DoryOperationInventoryObject(
            key: key,
            sourceFingerprint: OperationPlanningFixtures.digest("1"),
            specificationDigest: OperationPlanningFixtures.digest("2"),
            dependencies: [dependency]
        )
    }

    private func intent(
        for key: DoryOperationObjectKey,
        state: DoryOperationAcceptedFinalState
    ) -> DoryOperationObjectIntent {
        DoryOperationObjectIntent(
            source: key,
            normalizedTargetName: key.sourceID,
            acceptedFinalState: state
        )
    }
}
