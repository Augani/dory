@testable import DoryOperations
import XCTest

final class DoryOperationCompletenessTests: XCTestCase {
    func testExactIdentityLedgerCompletes() throws {
        let plan = try OperationPlanningFixtures.plan()
        let ledger = try completeLedger(for: plan)
        let evaluation = try ledger.evaluate(against: plan)

        XCTAssertTrue(evaluation.isComplete)
        XCTAssertTrue(evaluation.issues.isEmpty)
    }

    func testImagesAloneCannotCompleteContainerVolumeAndNetworkPlan() throws {
        let plan = try OperationPlanningFixtures.plan()
        let imageOnly = OperationPlanningFixtures.evidence(for: plan).filter { $0.source.kind == .image }
        let ledger = DoryOperationCompletionLedger(
            planDigest: try plan.canonicalDigest(),
            evidence: imageOnly,
            unselectedSourceInventoryDigest: plan.unselectedSourceInventoryDigest,
            unownedTargetInventoryDigest: plan.context.unownedTargetInventoryDigest
        )
        let evaluation = try ledger.evaluate(against: plan)
        let missing = evaluation.issues.compactMap { issue -> DoryOperationObjectKey? in
            guard case let .missingEvidence(key) = issue else { return nil }
            return key
        }

        XCTAssertFalse(evaluation.isComplete)
        XCTAssertEqual(Set(missing), Set(plan.selectedObjectKeys.filter { $0.kind != .image }))
        XCTAssertTrue(missing.contains(OperationPlanningFixtures.volume))
        XCTAssertTrue(missing.contains(OperationPlanningFixtures.api))
    }

    func testChangedMappingsStatesAndInventoriesAllFailMechanicalEquation() throws {
        let plan = try OperationPlanningFixtures.plan()
        var evidence = OperationPlanningFixtures.evidence(for: plan)
        let apiIndex = try XCTUnwrap(evidence.firstIndex { $0.source == OperationPlanningFixtures.api })
        let apiEvidence = evidence[apiIndex]
        evidence[apiIndex] = DoryOperationObjectEvidence(
            source: apiEvidence.source,
            verifiedTarget: apiEvidence.verifiedTarget,
            postPublicationTarget: DoryOperationTargetIdentity(
                id: "different-target",
                fingerprint: apiEvidence.postPublicationTarget.fingerprint
            ),
            verificationManifestDigest: apiEvidence.verificationManifestDigest,
            finalState: .paused
        )
        let ledger = DoryOperationCompletionLedger(
            planDigest: try plan.canonicalDigest(),
            evidence: evidence,
            unselectedSourceInventoryDigest: OperationPlanningFixtures.digest("1"),
            unownedTargetInventoryDigest: OperationPlanningFixtures.digest("2")
        )
        let issues = try ledger.evaluate(against: plan).issues

        XCTAssertTrue(issues.contains(.targetMappingChanged(OperationPlanningFixtures.api)))
        XCTAssertTrue(issues.contains(.finalStateMismatch(
            OperationPlanningFixtures.api,
            expected: .running,
            actual: .paused
        )))
        XCTAssertTrue(issues.contains(.unselectedSourceInventoryChanged))
        XCTAssertTrue(issues.contains(.unownedTargetInventoryChanged))
    }

    func testDuplicateUnplannedAndInvalidEvidenceCannotHideMissingObject() throws {
        let plan = try OperationPlanningFixtures.plan()
        var evidence = OperationPlanningFixtures.evidence(for: plan)
        let removed = evidence.removeLast()
        evidence.append(evidence[0])
        evidence.append(DoryOperationObjectEvidence(
            source: OperationPlanningFixtures.unselectedImage,
            verifiedTarget: DoryOperationTargetIdentity(
                id: "unplanned",
                fingerprint: OperationPlanningFixtures.digest("1")
            ),
            postPublicationTarget: DoryOperationTargetIdentity(
                id: "unplanned",
                fingerprint: OperationPlanningFixtures.digest("1")
            ),
            verificationManifestDigest: OperationPlanningFixtures.digest("2"),
            finalState: .present
        ))
        let invalidKey = evidence[1].source
        let invalid = evidence[1]
        evidence[1] = DoryOperationObjectEvidence(
            source: invalid.source,
            verifiedTarget: DoryOperationTargetIdentity(id: "", fingerprint: invalid.verifiedTarget.fingerprint),
            postPublicationTarget: invalid.postPublicationTarget,
            verificationManifestDigest: invalid.verificationManifestDigest,
            finalState: invalid.finalState
        )
        let ledger = DoryOperationCompletionLedger(
            planDigest: try plan.canonicalDigest(),
            evidence: evidence,
            unselectedSourceInventoryDigest: plan.unselectedSourceInventoryDigest,
            unownedTargetInventoryDigest: plan.context.unownedTargetInventoryDigest
        )
        let issues = try ledger.evaluate(against: plan).issues

        XCTAssertTrue(issues.contains(.duplicateEvidence(evidence[0].source)))
        XCTAssertTrue(issues.contains(.unplannedEvidence(OperationPlanningFixtures.unselectedImage)))
        XCTAssertTrue(issues.contains(.invalidEvidence(invalidKey)))
        XCTAssertTrue(issues.contains(.missingEvidence(removed.source)))
    }

    func testLedgerIsBoundToOneImmutablePlan() throws {
        let plan = try OperationPlanningFixtures.plan()
        let ledger = DoryOperationCompletionLedger(
            planDigest: OperationPlanningFixtures.digest("0"),
            evidence: OperationPlanningFixtures.evidence(for: plan),
            unselectedSourceInventoryDigest: plan.unselectedSourceInventoryDigest,
            unownedTargetInventoryDigest: plan.context.unownedTargetInventoryDigest
        )
        let issues = try ledger.evaluate(against: plan).issues

        XCTAssertTrue(issues.contains(.planDigestMismatch(
            expected: try plan.canonicalDigest(),
            actual: OperationPlanningFixtures.digest("0")
        )))
    }

    private func completeLedger(
        for plan: DoryOperationCompletenessPlan
    ) throws -> DoryOperationCompletionLedger {
        DoryOperationCompletionLedger(
            planDigest: try plan.canonicalDigest(),
            evidence: OperationPlanningFixtures.evidence(for: plan),
            unselectedSourceInventoryDigest: plan.unselectedSourceInventoryDigest,
            unownedTargetInventoryDigest: plan.context.unownedTargetInventoryDigest
        )
    }
}
