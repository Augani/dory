@testable import DoryOperations
import Foundation
import XCTest

final class DoryOperationEvidenceTests: XCTestCase {
    func testDurableEvidenceAndLedgerAuthorizeSemanticCompletion() throws {
        let fixture = try makeFixture(name: "complete")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let manifest = Data("{\"verified\":true}\n".utf8)
        let digest = try fixture.lease.publishManifest(manifest)
        try advance(fixture.lease, to: .staging)
        let staged = makeStaged(key: fixture.key, manifestDigest: digest)
        try fixture.lease.publishStagedObject(staged)
        try advance(fixture.lease, to: .publishing)
        let evidence = makeEvidence(key: fixture.key, manifestDigest: digest)
        try fixture.lease.publishObjectEvidence(evidence)
        try advance(fixture.lease, to: .validating)
        let ledger = try makeLedger(plan: fixture.plan, evidence: [evidence])

        try fixture.lease.publishCompletionLedger(ledger)

        XCTAssertEqual(try fixture.lease.readManifest(digest: digest), manifest)
        XCTAssertEqual(try fixture.lease.readStagedObjects(), [staged])
        XCTAssertEqual(try fixture.lease.readObjectEvidence(), [evidence])
        XCTAssertEqual(try fixture.lease.readCompletionLedger(), ledger)
        let completed = try fixture.lease.transition(
            to: .completed,
            status: .completed,
            expectedRevision: 6,
            stepID: "operation.completed"
        )
        XCTAssertEqual(completed.result, .succeeded)
    }

    func testSemanticCompletionRequiresCompleteDurableLedger() throws {
        let fixture = try makeFixture(name: "missing-ledger")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        try advance(fixture.lease, to: .validating)

        XCTAssertThrowsError(try fixture.lease.transition(
            to: .completed,
            status: .completed,
            expectedRevision: 6,
            stepID: "operation.completed"
        )) { error in
            guard case DoryOperationJournalError.invalidRecord = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try fixture.lease.read().state.phase, .validating)
    }

    func testLedgerCannotClaimEvidenceThatWasNotDurablyPublished() throws {
        let fixture = try makeFixture(name: "missing-evidence")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let digest = try fixture.lease.publishManifest(Data("manifest\n".utf8))
        let evidence = makeEvidence(key: fixture.key, manifestDigest: digest)
        let ledger = try makeLedger(plan: fixture.plan, evidence: [evidence])
        try advance(fixture.lease, to: .validating)

        XCTAssertThrowsError(try fixture.lease.publishCompletionLedger(ledger)) { error in
            guard case DoryOperationJournalError.invalidRecord = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testManifestTamperingInvalidatesEvidenceAndLedgerReadBack() throws {
        let fixture = try makeFixture(name: "tamper")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let digest = try fixture.lease.publishManifest(Data("original\n".utf8))
        try advance(fixture.lease, to: .staging)
        try fixture.lease.publishStagedObject(makeStaged(key: fixture.key, manifestDigest: digest))
        try advance(fixture.lease, to: .publishing)
        let evidence = makeEvidence(key: fixture.key, manifestDigest: digest)
        try fixture.lease.publishObjectEvidence(evidence)
        try advance(fixture.lease, to: .validating)
        try fixture.lease.publishCompletionLedger(try makeLedger(plan: fixture.plan, evidence: [evidence]))
        let path = fixture.store.operationDirectory(for: fixture.operationID)
            + "/manifests/objects/" + digest
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("tampered\n".utf8))
        try handle.close()

        XCTAssertThrowsError(try fixture.lease.readManifest(digest: digest))
        XCTAssertThrowsError(try fixture.lease.readObjectEvidence())
        XCTAssertThrowsError(try fixture.lease.readCompletionLedger())
    }

    func testPublishedLedgerFreezesPerObjectEvidence() throws {
        let fixture = try makeFixture(name: "frozen")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let digest = try fixture.lease.publishManifest(Data("manifest\n".utf8))
        try advance(fixture.lease, to: .staging)
        try fixture.lease.publishStagedObject(makeStaged(key: fixture.key, manifestDigest: digest))
        try advance(fixture.lease, to: .publishing)
        let evidence = makeEvidence(key: fixture.key, manifestDigest: digest)
        try fixture.lease.publishObjectEvidence(evidence)
        try advance(fixture.lease, to: .validating)
        try fixture.lease.publishCompletionLedger(try makeLedger(plan: fixture.plan, evidence: [evidence]))

        XCTAssertThrowsError(try fixture.lease.publishObjectEvidence(evidence)) { error in
            guard case DoryOperationJournalError.invalidRecord = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testStagingAndFinalEvidenceAreDistinctAndPhaseBound() throws {
        let fixture = try makeFixture(name: "staging-phase")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let manifestDigest = try fixture.lease.publishManifest(Data("manifest\n".utf8))
        let staged = makeStaged(key: fixture.key, manifestDigest: manifestDigest)

        XCTAssertThrowsError(try fixture.lease.publishStagedObject(staged))
        try advance(fixture.lease, to: .staging)
        try fixture.lease.publishStagedObject(staged)
        try fixture.lease.publishStagedObject(staged)
        XCTAssertEqual(try fixture.lease.readStagedObjects(), [staged])

        XCTAssertThrowsError(try fixture.lease.publishObjectEvidence(
            makeEvidence(key: fixture.key, manifestDigest: manifestDigest)
        ))
        try advance(fixture.lease, to: .publishing)
        let mismatched = DoryOperationObjectEvidence(
            source: fixture.key,
            verifiedTarget: DoryOperationTargetIdentity(id: "other", fingerprint: digest("a")),
            postPublicationTarget: DoryOperationTargetIdentity(id: "other", fingerprint: digest("a")),
            verificationManifestDigest: manifestDigest,
            finalState: .present
        )
        XCTAssertThrowsError(try fixture.lease.publishObjectEvidence(mismatched))
    }
}

private extension DoryOperationEvidenceTests {
    struct Fixture {
        let home: URL
        let store: DoryOperationJournalStore
        let lease: DoryOperationLease
        let plan: DoryOperationCompletenessPlan
        let operationID: UUID
        let key: DoryOperationObjectKey
    }

    func makeFixture(name: String) throws -> Fixture {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-evidence-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = try DoryOperationJournalStore(home: home.path)
        let key = DoryOperationObjectKey(kind: .image, sourceID: "sha256:source-image")
        let specification = try DoryOperationSpecification(canonical: ["id": key.sourceID])
        let plan = try makePlan(key: key, specification: specification)
        let operationID = UUID()
        let journalPlan = try makeJournalPlan(
            operationID: operationID,
            completenessPlan: plan
        )
        let lease = try store.begin(
            journalPlan,
            completenessPlan: plan,
            specifications: [specification]
        )
        return Fixture(
            home: home,
            store: store,
            lease: lease,
            plan: plan,
            operationID: operationID,
            key: key
        )
    }

    func makePlan(
        key: DoryOperationObjectKey,
        specification: DoryOperationSpecification
    ) throws -> DoryOperationCompletenessPlan {
        let context = DoryOperationPlanningContext(
            targetInventoryDigest: digest("1"),
            unownedTargetInventoryDigest: digest("2"),
            capabilitiesDigest: digest("3"),
            capacityDigest: digest("4"),
            quiescenceDigest: digest("5")
        )
        return try DoryOperationPlanner.plan(
            inventory: [DoryOperationInventoryObject(
                key: key,
                sourceFingerprint: digest("6"),
                specificationDigest: specification.digest
            )],
            intents: [DoryOperationObjectIntent(
                source: key,
                normalizedTargetName: "example/image:latest",
                acceptedFinalState: .present
            )],
            userSelection: [key],
            context: context
        )
    }

    func makeJournalPlan(
        operationID: UUID,
        completenessPlan: DoryOperationCompletenessPlan
    ) throws -> DoryOperationPlan {
        try DoryOperationPlan(
            id: operationID,
            kind: .competitorImport,
            source: DoryOperationAuthority(
                kind: .dockerEngine,
                id: "source",
                fingerprint: digest("7")
            ),
            target: DoryOperationAuthority(
                kind: .dockerEngine,
                id: "target",
                fingerprint: digest("8")
            ),
            completenessPlan: completenessPlan
        )
    }

    func makeEvidence(
        key: DoryOperationObjectKey,
        manifestDigest: String
    ) -> DoryOperationObjectEvidence {
        let identity = DoryOperationTargetIdentity(id: "target-image", fingerprint: digest("9"))
        return DoryOperationObjectEvidence(
            source: key,
            verifiedTarget: identity,
            postPublicationTarget: identity,
            verificationManifestDigest: manifestDigest,
            finalState: .present
        )
    }

    func makeStaged(
        key: DoryOperationObjectKey,
        manifestDigest: String
    ) -> DoryOperationStagedObject {
        DoryOperationStagedObject(
            source: key,
            verifiedTarget: DoryOperationTargetIdentity(id: "target-image", fingerprint: digest("9")),
            verificationManifestDigest: manifestDigest,
            disposition: .createdOperationOwned
        )
    }

    func makeLedger(
        plan: DoryOperationCompletenessPlan,
        evidence: [DoryOperationObjectEvidence]
    ) throws -> DoryOperationCompletionLedger {
        DoryOperationCompletionLedger(
            planDigest: try plan.canonicalDigest(),
            evidence: evidence,
            unselectedSourceInventoryDigest: plan.unselectedSourceInventoryDigest,
            unownedTargetInventoryDigest: plan.context.unownedTargetInventoryDigest
        )
    }

    func advance(
        _ lease: DoryOperationLease,
        to destination: DoryOperationPhase
    ) throws {
        let phases: [DoryOperationPhase] = [
            .planned,
            .quiescing,
            .staging,
            .verifying,
            .readyToPublish,
            .publishing,
            .validating
        ]
        var state = try lease.read().state
        guard let start = phases.firstIndex(of: state.phase),
              let end = phases.firstIndex(of: destination), start <= end else {
            return XCTFail("invalid test phase transition")
        }
        for phase in phases.dropFirst(start + 1).prefix(end - start) {
            state = try lease.transition(
                to: phase,
                status: .running,
                expectedRevision: state.revision,
                stepID: "phase.\(phase.rawValue)"
            )
        }
    }

    func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }
}
