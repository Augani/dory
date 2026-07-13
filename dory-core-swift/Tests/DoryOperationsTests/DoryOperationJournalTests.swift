@testable import DoryOperations
import Foundation
import XCTest

// The journal's security, durability, recovery, and state-machine cases intentionally share one
// fixture/helper set so every test exercises the same on-disk contract.
// swiftlint:disable file_length
// swiftlint:disable:next type_body_length
final class DoryOperationJournalTests: XCTestCase {
    func testBeginPublishesPrivateImmutablePlanAndInitialAuditEvent() throws {
        let home = try temporaryHome(named: "begin")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try DoryOperationJournalStore(home: home.path)
        let plan = operationPlan(kind: .competitorImport)

        let lease = try store.begin(plan, at: Date(timeIntervalSince1970: 1_700_000_000))
        let record = try lease.read()
        let events = try lease.events()

        XCTAssertEqual(record.plan, plan)
        XCTAssertEqual(record.state.operationID, plan.id)
        XCTAssertEqual(record.state.revision, 0)
        XCTAssertEqual(record.state.phase, .planned)
        XCTAssertEqual(record.state.status, .running)
        XCTAssertEqual(record.state.lastEvent.stepID, "operation.created")
        XCTAssertEqual(events, [record.state.lastEvent])
        XCTAssertEqual(try store.list(), [record])

        let operationDirectory = store.operationDirectory(for: plan.id)
        for path in [
            store.controlDirectory,
            store.root,
            operationDirectory,
            operationDirectory + "/specs",
            operationDirectory + "/manifests",
            operationDirectory + "/logs"
        ] {
            XCTAssertEqual(permissions(path), 0o700, path)
        }
        for path in [
            operationDirectory + "/plan.json",
            operationDirectory + "/state.json",
            operationDirectory + "/events.ndjson"
        ] {
            XCTAssertEqual(permissions(path), 0o600, path)
        }
        withExtendedLifetime(lease) {}
    }

    func testLegalPhaseSequenceCompletesWithoutSkippingAStage() throws {
        let home = try temporaryHome(named: "sequence")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try DoryOperationJournalStore(home: home.path)
        let lease = try store.begin(operationPlan(kind: .driveRelocation))
        let phases: [DoryOperationPhase] = [
            .quiescing,
            .staging,
            .verifying,
            .readyToPublish,
            .publishing,
            .validating,
            .completed
        ]

        for (offset, phase) in phases.enumerated() {
            let revision = UInt64(offset)
            let state = try lease.transition(
                to: phase,
                status: phase == .completed ? .completed : .running,
                expectedRevision: revision,
                stepID: "phase.\(phase.rawValue)"
            )
            XCTAssertEqual(state.revision, revision + 1)
            XCTAssertEqual(state.phase, phase)
        }

        let record = try lease.read()
        XCTAssertEqual(record.state.revision, 7)
        XCTAssertEqual(record.state.phase, .completed)
        XCTAssertEqual(record.state.status, .completed)
        XCTAssertEqual(record.state.result, .succeeded)
        XCTAssertEqual(try lease.events().map(\.revision), Array(0 ... 7))
        XCTAssertThrowsError(try lease.transition(
            to: .completed,
            status: .completed,
            expectedRevision: 7,
            stepID: "completed.again"
        )) { error in
            guard case DoryOperationJournalError.illegalTransition = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testRejectsSkippedRegressedAndStaleTransitions() throws {
        let home = try temporaryHome(named: "illegal")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try DoryOperationJournalStore(home: home.path)
        let lease = try store.begin(operationPlan(kind: .driveBackup))

        XCTAssertThrowsError(try lease.transition(
            to: .staging,
            status: .running,
            expectedRevision: 0,
            stepID: "skip.quiesce"
        )) { error in
            guard case DoryOperationJournalError.illegalTransition = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        _ = try lease.transition(
            to: .quiescing,
            status: .running,
            expectedRevision: 0,
            stepID: "quiesce.begin"
        )
        XCTAssertThrowsError(try lease.transition(
            to: .staging,
            status: .running,
            expectedRevision: 0,
            stepID: "stale.writer"
        )) { error in
            XCTAssertEqual(error as? DoryOperationJournalError, .staleRevision(expected: 0, actual: 1))
        }
        XCTAssertThrowsError(try lease.transition(
            to: .planned,
            status: .running,
            expectedRevision: 1,
            stepID: "regress.plan"
        )) { error in
            guard case DoryOperationJournalError.illegalTransition = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testInterruptedAndBlockedWorkMustResumeBeforeAdvancing() throws {
        let home = try temporaryHome(named: "resume")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try DoryOperationJournalStore(home: home.path)
        let lease = try store.begin(operationPlan(kind: .driveRestore))

        _ = try lease.transition(
            to: .planned,
            status: .interrupted,
            expectedRevision: 0,
            stepID: "owner.exited",
            recoveryAction: "resume.plan"
        )
        XCTAssertThrowsError(try lease.transition(
            to: .quiescing,
            status: .running,
            expectedRevision: 1,
            stepID: "advance.while.interrupted"
        ))
        _ = try lease.transition(
            to: .planned,
            status: .running,
            expectedRevision: 1,
            stepID: "resume.plan"
        )
        _ = try lease.transition(
            to: .quiescing,
            status: .running,
            expectedRevision: 2,
            stepID: "quiesce.begin"
        )
        _ = try lease.transition(
            to: .quiescing,
            status: .blocked,
            expectedRevision: 3,
            stepID: "source.drift",
            recoveryAction: "replan.source"
        )
        XCTAssertEqual(try lease.read().state.lastEvent.recoveryAction, "replan.source")
    }

    func testCancellationIsTerminalOnlyAfterRollback() throws {
        let home = try temporaryHome(named: "cancel")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try DoryOperationJournalStore(home: home.path)
        let lease = try store.begin(operationPlan(kind: .competitorImport))
        _ = try lease.transition(
            to: .planned,
            status: .rollingBack,
            expectedRevision: 0,
            stepID: "rollback.begin"
        )

        let cancelled = try lease.cancelAfterRollback(expectedRevision: 1)

        XCTAssertEqual(cancelled.status, .failed)
        XCTAssertEqual(cancelled.result, .cancelled)
        XCTAssertThrowsError(try lease.transition(
            to: .planned,
            status: .running,
            expectedRevision: 2,
            stepID: "resume.cancelled"
        ))
    }

    func testOneLeaseBlocksEveryOtherMutatingOperationForTheHome() throws {
        let home = try temporaryHome(named: "lock")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try DoryOperationJournalStore(home: home.path)
        let firstPlan = operationPlan(kind: .competitorImport)
        let first = try store.begin(firstPlan)

        XCTAssertThrowsError(try store.acquire(firstPlan.id)) { error in
            guard case DoryOperationJournalError.operationInUse = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try store.begin(operationPlan(kind: .driveBackup))) { error in
            guard case DoryOperationJournalError.operationInUse = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try store.read(firstPlan.id).plan.id, firstPlan.id)
        withExtendedLifetime(first) {}
    }

    func testDuplicateOperationIDCannotReplaceImmutablePlan() throws {
        let home = try temporaryHome(named: "duplicate")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try DoryOperationJournalStore(home: home.path)
        let plan = operationPlan(kind: .driveUpgrade)
        do {
            let lease = try store.begin(plan)
            withExtendedLifetime(lease) {}
        }

        XCTAssertThrowsError(try store.begin(plan)) { error in
            XCTAssertEqual(error as? DoryOperationJournalError, .operationExists(plan.id))
        }
        XCTAssertEqual(try store.read(plan.id).plan, plan)
    }

    func testPlanSymlinkAndHardLinkAreRejectedWithoutChangingTargets() throws {
        for linkKind in ["symlink", "hardlink"] {
            let home = try temporaryHome(named: linkKind)
            defer { try? FileManager.default.removeItem(at: home) }
            let store = try DoryOperationJournalStore(home: home.path)
            let plan = operationPlan(kind: .competitorImport)
            do {
                let lease = try store.begin(plan)
                withExtendedLifetime(lease) {}
            }
            let planPath = store.operationDirectory(for: plan.id) + "/plan.json"
            let target = home.appendingPathComponent("foreign-\(linkKind).json")
            let original = try Data(contentsOf: URL(fileURLWithPath: planPath))

            if linkKind == "symlink" {
                try original.write(to: target)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: target.path
                )
                try FileManager.default.removeItem(atPath: planPath)
                try FileManager.default.createSymbolicLink(
                    atPath: planPath,
                    withDestinationPath: target.path
                )
            } else {
                try FileManager.default.linkItem(atPath: planPath, toPath: target.path)
            }

            XCTAssertThrowsError(try store.read(plan.id)) { error in
                XCTAssertEqual(error as? DoryOperationJournalError, .invalidRecord(planPath))
            }
            XCTAssertEqual(try Data(contentsOf: target), original)
        }
    }

    func testModifiedPlanIsRejectedByStateDigest() throws {
        let home = try temporaryHome(named: "digest")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try DoryOperationJournalStore(home: home.path)
        let plan = operationPlan(kind: .driveRelocation)
        do {
            let lease = try store.begin(plan)
            withExtendedLifetime(lease) {}
        }
        let path = store.operationDirectory(for: plan.id) + "/plan.json"
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
                as? [String: Any]
        )
        object["selectionDigest"] = String(repeating: "f", count: 64)
        let modified = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try modified.write(to: URL(fileURLWithPath: path), options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

        XCTAssertThrowsError(try store.read(plan.id)) { error in
            XCTAssertEqual(
                error as? DoryOperationJournalError,
                .invalidRecord(store.operationDirectory(for: plan.id))
            )
        }
    }

    func testAcquireRepairsInterruptedAuditAppendFromEmbeddedStateEvent() throws {
        let home = try temporaryHome(named: "audit-repair")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try DoryOperationJournalStore(home: home.path)
        let plan = operationPlan(kind: .driveBackup)
        do {
            let lease = try store.begin(plan)
            _ = try lease.transition(
                to: .quiescing,
                status: .running,
                expectedRevision: 0,
                stepID: "quiesce.begin"
            )
            withExtendedLifetime(lease) {}
        }
        let eventsPath = store.operationDirectory(for: plan.id) + "/events.ndjson"
        let eventLines = try String(contentsOfFile: eventsPath, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(eventLines.count, 2)
        let interruptedLog = Data((String(eventLines[0]) + "\n{\"schemaVersion\":").utf8)
        try interruptedLog.write(to: URL(fileURLWithPath: eventsPath), options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: eventsPath)

        let recovered = try store.acquire(plan.id)

        XCTAssertEqual(try recovered.events().map(\.revision), [0, 1])
        XCTAssertEqual(try recovered.events().last?.stepID, "quiesce.begin")
    }

    func testStatePublishedBeforeAuditAppendRecoversAfterLeaseOwnerExits() throws {
        let home = try temporaryHome(named: "state-before-audit")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try DoryOperationJournalStore(home: home.path)
        let plan = operationPlan(kind: .driveUpgrade)
        do {
            let lease = try store.begin(plan)
            XCTAssertThrowsError(try lease.transitionForCrashRecoveryTest(
                to: .quiescing,
                status: .running,
                expectedRevision: 0,
                stepID: "quiesce.persisted"
            )) { error in
                guard case DoryOperationJournalError.filesystem = error else {
                    return XCTFail("unexpected injected interruption: \(error)")
                }
            }
            XCTAssertEqual(try lease.read().state.revision, 1)
            XCTAssertEqual(try lease.events().map(\.revision), [0])
            withExtendedLifetime(lease) {}
        }

        let recovered = try store.acquire(plan.id)

        XCTAssertEqual(try recovered.events().map(\.revision), [0, 1])
        XCTAssertEqual(try recovered.events().last?.stepID, "quiesce.persisted")
    }

    func testDriveMirrorIsAReadOnlySummaryOfTheAuthoritativeJournal() throws {
        let home = try temporaryHome(named: "mirror")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try DoryOperationJournalStore(home: home.path)
        let plan = operationPlan(kind: .driveRelocation)
        let lease = try store.begin(plan)
        _ = try lease.transition(
            to: .quiescing,
            status: .running,
            expectedRevision: 0,
            stepID: "drive.quiesced"
        )
        let drive = try DoryDataDrive(home: home.path)
        try drive.prepare()

        try lease.mirrorSummary(to: drive)

        let path = drive.operationsDirectory + "/" + plan.id.uuidString.lowercased() + ".json"
        let summary = try JSONDecoder().decode(
            DoryOperationSummary.self,
            from: Data(contentsOf: URL(fileURLWithPath: path))
        )
        XCTAssertEqual(summary.operationID, plan.id)
        XCTAssertEqual(summary.kind, .driveRelocation)
        XCTAssertEqual(summary.revision, 1)
        XCTAssertEqual(summary.phase, .quiescing)
        XCTAssertEqual(permissions(path), 0o600)
        XCTAssertFalse(path.hasPrefix(store.root + "/"))
    }

    func testListIgnoresUnpublishedPartialsButRejectsUnknownPublishedEntries() throws {
        let home = try temporaryHome(named: "list")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try DoryOperationJournalStore(home: home.path)
        let plan = operationPlan(kind: .driveRestore)
        do {
            let lease = try store.begin(plan)
            withExtendedLifetime(lease) {}
        }
        try FileManager.default.createDirectory(
            atPath: store.root + "/.\(UUID().uuidString).\(UUID().uuidString).partial",
            withIntermediateDirectories: false
        )
        XCTAssertEqual(try store.list().map(\.plan.id), [plan.id])

        try Data().write(to: URL(fileURLWithPath: store.root + "/.foreign"))
        XCTAssertThrowsError(try store.list()) { error in
            XCTAssertEqual(
                error as? DoryOperationJournalError,
                .invalidRecord(store.root + "/.foreign")
            )
        }
    }

    private func operationPlan(kind: DoryOperationKind) -> DoryOperationPlan {
        DoryOperationPlan(
            kind: kind,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: DoryOperationAuthority(
                kind: kind == .competitorImport ? .dockerEngine : .dataDrive,
                id: "source-authority",
                fingerprint: String(repeating: "1", count: 64)
            ),
            target: DoryOperationAuthority(
                kind: kind == .driveBackup ? .backupArchive : .dataDrive,
                id: "target-authority",
                fingerprint: String(repeating: "2", count: 64)
            ),
            selectionDigest: String(repeating: "3", count: 64),
            dependencyClosureDigest: String(repeating: "4", count: 64),
            successCriteriaDigest: String(repeating: "5", count: 64)
        )
    }

    private func temporaryHome(named name: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-operation-journal-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func permissions(_ path: String) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
// swiftlint:enable file_length
