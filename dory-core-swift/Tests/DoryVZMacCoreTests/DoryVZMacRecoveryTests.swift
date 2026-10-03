import XCTest
import Darwin
@testable import DoryVZMacCore

final class DoryVZMacRecoveryTests: XCTestCase {
    func testRequiresExplicitDiscardAfterInterruptedRestore() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = DoryVZMacMachineBundle(
            rootURL: root,
            manifest: try manifest(state: .restoring)
        )
        XCTAssertThrowsError(
            try DoryVZMacRecovery.recoverInterruptedOperation(in: bundle)
        ) { error in
            XCTAssertEqual(
                error as? DoryVZMacRecoveryError,
                .explicitSavedStateDiscardRequired
            )
        }
    }

    func testRejectsRecoveryForStableStateBeforeFilesystemMutation() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = DoryVZMacMachineBundle(
            rootURL: root,
            manifest: try manifest(state: .stopped)
        )
        XCTAssertThrowsError(
            try DoryVZMacRecovery.recoverInterruptedOperation(in: bundle)
        ) { error in
            XCTAssertEqual(
                error as? DoryVZMacRecoveryError,
                .noInterruptedOperation(.stopped)
            )
        }
    }

    func testInterruptedInstallationRecordsFailureBeforeManifestAndKeepsOperationIdentity() throws {
        try withFixture(state: .installing) { fixture in
            let journal = installJournal(fixture)
            try journal.write(to: fixture.bundle.installJournalURL)
            var io = fixture.io
            io.checkpoint = { point in
                if point == .installationJournalCommitted {
                    XCTAssertEqual(try fixture.readManifest().installationState, .installing)
                    XCTAssertEqual(try DoryVZMacInstallJournal.load(from: fixture.bundle.installJournalURL).phase, .failed)
                }
            }
            let recovered = try recover(fixture, io: io)
            XCTAssertEqual(recovered.manifest.installationState, .installFailed)
            let failed = try DoryVZMacInstallJournal.load(from: fixture.bundle.installJournalURL)
            XCTAssertEqual(failed.operationID, journal.operationID)
            XCTAssertEqual(failed.progress, journal.progress)
            XCTAssertEqual(failed.startedAt, journal.startedAt)
            try fixture.assertPersistentArtifacts()
        }
    }

    func testFailedJournalDiagnosticSurvivesRepeatedRecoveryOfAnOldBundleValue() throws {
        try withFixture(state: .installing) { fixture in
            let failed = installJournal(fixture).updating(phase: .failed, progress: 0.5, error: "original installer failure")
            try failed.write(to: fixture.bundle.installJournalURL)
            _ = try recover(fixture)
            _ = try recover(fixture)
            XCTAssertEqual(try DoryVZMacInstallJournal.load(from: fixture.bundle.installJournalURL), failed)
            XCTAssertEqual(try fixture.readManifest().installationState, .installFailed)
            try fixture.assertPersistentArtifacts()
        }
    }

    func testMissingCorruptFutureOrForeignInstallJournalCannotBeReinvented() throws {
        for kind in ["missing", "corrupt", "future", "machine", "restore"] {
            try withFixture(state: .installing) { fixture in
                var journal = installJournal(fixture)
                if kind == "machine" || kind == "restore" {
                    journal = DoryVZMacInstallJournal(
                        operationID: journal.operationID, startedAt: journal.startedAt, updatedAt: journal.updatedAt,
                        phase: .installing, progress: 0.5,
                        restoreImageSHA256: kind == "restore" ? String(repeating: "f", count: 64) : journal.restoreImageSHA256,
                        machineIdentifierSHA256: kind == "machine" ? String(repeating: "f", count: 64) : journal.machineIdentifierSHA256,
                        error: nil
                    )
                }
                if kind == "corrupt" { try Data("bad-journal".utf8).write(to: fixture.bundle.installJournalURL) }
                else if kind == "future" { try Data("{\"schema\":\"future\"}".utf8).write(to: fixture.bundle.installJournalURL) }
                else if kind != "missing" { try journal.write(to: fixture.bundle.installJournalURL) }
                let before = try DoryVZMacMetadataFile.readIfPresent(from: fixture.bundle.installJournalURL)
                XCTAssertThrowsError(try recover(fixture))
                XCTAssertEqual(try DoryVZMacMetadataFile.readIfPresent(from: fixture.bundle.installJournalURL), before)
                XCTAssertEqual(try fixture.readManifest(), fixture.bundle.manifest)
                try fixture.assertPersistentArtifacts()
            }
        }
    }

    func testCompletedInstallerJournalRollsForwardWithoutChangingOperationOrDisks() throws {
        try withFixture(state: .installing) { fixture in
            let completed = installJournal(fixture).updating(phase: .completed, progress: 1)
            try completed.write(to: fixture.bundle.installJournalURL)
            var io = fixture.io
            io.checkpoint = { point in
                if point == .installationJournalCommitted {
                    XCTAssertEqual(try fixture.readManifest().installationState, .installing)
                    XCTAssertEqual(try DoryVZMacInstallJournal.load(from: fixture.bundle.installJournalURL), completed)
                }
            }
            XCTAssertEqual(try recover(fixture, io: io).manifest.installationState, .stopped)
            // Repeating with the pre-commit bundle value flushes the same terminal evidence.
            XCTAssertEqual(try recover(fixture).manifest.installationState, .stopped)
            XCTAssertEqual(try DoryVZMacInstallJournal.load(from: fixture.bundle.installJournalURL), completed)
            try fixture.assertPersistentArtifacts()
        }
        try withFixture(state: .installFailed) { fixture in
            let completed = installJournal(fixture).updating(phase: .completed, progress: 1)
            try completed.write(to: fixture.bundle.installJournalURL)
            XCTAssertThrowsError(try recover(fixture))
            XCTAssertEqual(try fixture.readManifest(), fixture.bundle.manifest)
            XCTAssertEqual(try DoryVZMacInstallJournal.load(from: fixture.bundle.installJournalURL), completed)
        }
    }

    func testSuccessfulCallbackCommitsCompletedJournalBeforeBootableManifest() throws {
        try withFixture(state: .installing) { fixture in
            let active = installJournal(fixture)
            try active.write(to: fixture.bundle.installJournalURL)
            let completed = active.updating(phase: .completed, progress: 1)
            let lease = try DoryVZMacMachineLease(rootURL: fixture.bundle.rootURL)
            var io = fixture.io
            io.checkpoint = { point in
                if point == .installationJournalCommitted {
                    XCTAssertEqual(try fixture.readManifest().installationState, .installing)
                    XCTAssertEqual(try DoryVZMacInstallJournal.load(from: fixture.bundle.installJournalURL), completed)
                }
            }
            let result = try DoryVZMacRecovery.commitInstallationOutcome(completed, in: fixture.bundle, holding: lease, io: io)
            XCTAssertEqual(result.manifest.installationState, .stopped)
            XCTAssertEqual(result.manifest.replacingInstallationState(.installing), fixture.bundle.manifest)
            try fixture.assertPersistentArtifacts()
        }
    }

    func testSuccessfulCallbackMetadataFaultsNeverPublishAFalseFailedJournal() throws {
        let points: [DoryVZMacMetadataFile.Checkpoint] = [.temporaryCreated, .bytesWritten, .fileSynced, .published, .directorySynced]
        for writer in 1...2 {
            for point in points {
                try withFixture(state: .installing) { fixture in
                    let active = installJournal(fixture)
                    try active.write(to: fixture.bundle.installJournalURL)
                    let completed = active.updating(phase: .completed, progress: 1)
                    let lease = try DoryVZMacMachineLease(rootURL: fixture.bundle.rootURL)
                    var matches = 0
                    var io = fixture.io
                    io.metadata.checkpoint = { current in
                        if current == point { matches += 1; if matches == writer { throw Interrupted.test } }
                    }
                    XCTAssertThrowsError(try DoryVZMacRecovery.commitInstallationOutcome(
                        completed, in: fixture.bundle, holding: lease, io: io))
                    XCTAssertEqual(matches, writer)
                    let observed = try DoryVZMacInstallJournal.load(from: fixture.bundle.installJournalURL)
                    XCTAssertNotEqual(observed.phase, .failed)
                    let hasSuccessEvidence = observed.phase == .completed
                    let recovered = try DoryVZMacRecovery.recoverInterruptedOperation(
                        in: fixture.bundle, holding: lease, io: fixture.io)
                    XCTAssertEqual(recovered.manifest.installationState, hasSuccessEvidence ? .stopped : .installFailed)
                    let terminal = try DoryVZMacInstallJournal.load(from: fixture.bundle.installJournalURL)
                    XCTAssertEqual(terminal.operationID, active.operationID)
                    if hasSuccessEvidence { XCTAssertEqual(terminal, completed) }
                    try fixture.assertPersistentArtifacts()
                }
            }
        }
    }

    func testRecordedSuccessCannotBeDemotedByFailureCommitOrRestartedInstaller() throws {
        try withFixture(state: .installing) { fixture in
            let active = installJournal(fixture)
            let completed = active.updating(phase: .completed, progress: 1)
            try completed.write(to: fixture.bundle.installJournalURL)
            let lease = try DoryVZMacMachineLease(rootURL: fixture.bundle.rootURL)
            let failure = active.updating(phase: .failed, progress: 0.5, error: "late metadata error")
            XCTAssertThrowsError(try DoryVZMacRecovery.commitInstallationOutcome(
                failure, in: fixture.bundle, holding: lease, io: fixture.io))
            let recovered = try DoryVZMacRecovery.recoverInterruptedOperation(in: fixture.bundle, holding: lease, io: fixture.io)
            XCTAssertThrowsError(try DoryVZMacRecovery.beginInstallation(
                active.updating(phase: .validatingRestore, progress: 0), in: recovered, holding: lease, io: fixture.io))
            XCTAssertEqual(try DoryVZMacInstallJournal.load(from: fixture.bundle.installJournalURL), completed)
            XCTAssertEqual(try fixture.readManifest().installationState, .stopped)
            try fixture.assertPersistentArtifacts()
        }
    }

    func testInstallerFailuresCommitDiagnosticBeforeFailedManifestIncludingValidationFailure() throws {
        for state in [DoryVZMacMachineInstallationState.prepared, .installing, .installFailed] {
            try withFixture(state: state) { fixture in
                let active = installJournal(fixture).updating(
                    phase: state == .installing ? .installing : .validatingRestore, progress: 0.5)
                try active.write(to: fixture.bundle.installJournalURL)
                let failed = active.updating(phase: .failed, progress: 0.5, error: "Apple installer failed")
                let lease = try DoryVZMacMachineLease(rootURL: fixture.bundle.rootURL)
                var io = fixture.io
                io.checkpoint = { point in
                    if point == .installationJournalCommitted {
                        XCTAssertEqual(try fixture.readManifest().installationState, state)
                        XCTAssertEqual(try DoryVZMacInstallJournal.load(from: fixture.bundle.installJournalURL), failed)
                    }
                }
                let result = try DoryVZMacRecovery.commitInstallationOutcome(failed, in: fixture.bundle, holding: lease, io: io)
                XCTAssertEqual(result.manifest.installationState, .installFailed)
                try fixture.assertPersistentArtifacts()
            }
        }
    }

    func testFailedOutcomeWriteAndFlushFailuresRetainTheRecoverableInstallingState() throws {
        for fullDisk in [false, true] {
            try withFixture(state: .installing) { fixture in
                let active = installJournal(fixture)
                try active.write(to: fixture.bundle.installJournalURL)
                let failed = active.updating(phase: .failed, progress: 0.5, error: "original failure")
                let lease = try DoryVZMacMachineLease(rootURL: fixture.bundle.rootURL)
                var io = fixture.io
                if fullDisk { io.metadata.write = { _, _, _ in errno = ENOSPC; return -1 } }
                else { io.metadata.sync = { _, _ in errno = EIO; return -1 } }
                XCTAssertThrowsError(try DoryVZMacRecovery.commitInstallationOutcome(failed, in: fixture.bundle, holding: lease, io: io))
                XCTAssertEqual(try fixture.readManifest().installationState, .installing)
                XCTAssertEqual(try DoryVZMacInstallJournal.load(from: fixture.bundle.installJournalURL), active)
                _ = try DoryVZMacRecovery.recoverInterruptedOperation(in: fixture.bundle, holding: lease, io: fixture.io)
                XCTAssertEqual(try fixture.readManifest().installationState, .installFailed)
                try fixture.assertPersistentArtifacts()
            }
        }
    }

    func testRecoveredFailureCanBeginANewAttemptWithoutCreatingOrReplacingBundleArtifacts() throws {
        try withFixture(state: .installing) { fixture in
            let active = installJournal(fixture)
            try active.write(to: fixture.bundle.installJournalURL)
            let lease = try DoryVZMacMachineLease(rootURL: fixture.bundle.rootURL)
            let recovered = try DoryVZMacRecovery.recoverInterruptedOperation(in: fixture.bundle, holding: lease, io: fixture.io)
            let originalFailure = try DoryVZMacInstallJournal.load(from: fixture.bundle.installJournalURL)
            XCTAssertEqual(originalFailure.operationID, active.operationID)
            let retry = DoryVZMacInstallJournal(operationID: UUID(), startedAt: active.startedAt, updatedAt: active.updatedAt,
                phase: .validatingRestore, progress: 0, restoreImageSHA256: active.restoreImageSHA256,
                machineIdentifierSHA256: active.machineIdentifierSHA256, error: nil)
            let result = try DoryVZMacRecovery.beginInstallation(retry, in: recovered, holding: lease, io: fixture.io)
            XCTAssertEqual(result.rootURL, recovered.rootURL)
            XCTAssertEqual(result.manifest, recovered.manifest)
            XCTAssertEqual(try DoryVZMacInstallJournal.load(from: fixture.bundle.installJournalURL), retry)
            XCTAssertEqual(try fixture.readManifest().machineIdentifierSHA256, fixture.bundle.manifest.machineIdentifierSHA256)
            try fixture.assertPersistentArtifacts()
        }
        try withFixture(state: .prepared) { fixture in
            let lease = try DoryVZMacMachineLease(rootURL: fixture.bundle.rootURL)
            let initial = installJournal(fixture).updating(phase: .validatingRestore, progress: 0)
            _ = try DoryVZMacRecovery.beginInstallation(initial, in: fixture.bundle, holding: lease, io: fixture.io)
            XCTAssertEqual(try fixture.readManifest().installationState, .prepared)
            try fixture.assertPersistentArtifacts()
        }
    }

    func testNewInstallationCannotOverwriteUnverifiablePriorAttempt() throws {
        for kind in ["missing", "corrupt", "future", "foreign", "completed", "active", "symlink", "hardlink"] {
            try withFixture(state: .installFailed) { fixture in
                let active = installJournal(fixture)
                let failed = active.updating(phase: .failed, progress: 0.5, error: "preserve original error")
                if kind == "corrupt" || kind == "future" {
                    try DoryVZMacMetadataFile.write(Data((kind == "future" ? "{\"schema\":\"future\"}" : "bad-journal").utf8), to: fixture.bundle.installJournalURL)
                } else if kind == "foreign" {
                    let foreign = DoryVZMacInstallJournal(operationID: failed.operationID, startedAt: failed.startedAt,
                        updatedAt: failed.updatedAt, phase: .failed, progress: 0.5,
                        restoreImageSHA256: String(repeating: "f", count: 64),
                        machineIdentifierSHA256: failed.machineIdentifierSHA256, error: failed.error)
                    try foreign.write(to: fixture.bundle.installJournalURL)
                } else if kind == "symlink" || kind == "hardlink" {
                    let target = fixture.bundle.rootURL.appendingPathComponent("preserved-journal")
                    try failed.write(to: target)
                    XCTAssertEqual(kind == "symlink" ? symlink(target.path, fixture.bundle.installJournalURL.path)
                        : link(target.path, fixture.bundle.installJournalURL.path), 0)
                } else if kind == "completed" { try active.updating(phase: .completed, progress: 1).write(to: fixture.bundle.installJournalURL) }
                else if kind == "active" { try active.write(to: fixture.bundle.installJournalURL) }
                let before = try? Data(contentsOf: fixture.bundle.installJournalURL)
                let lease = try DoryVZMacMachineLease(rootURL: fixture.bundle.rootURL)
                XCTAssertThrowsError(try DoryVZMacRecovery.beginInstallation(
                    active.updating(phase: .validatingRestore, progress: 0), in: fixture.bundle, holding: lease, io: fixture.io))
                XCTAssertEqual(try? Data(contentsOf: fixture.bundle.installJournalURL), before)
                XCTAssertEqual(try fixture.readManifest(), fixture.bundle.manifest)
                try fixture.assertPersistentArtifacts()
            }
        }
    }

    func testInstallRecoveryRequiresTheCorrectLeaseAndOutcomeOperation() throws {
        try withFixture(state: .installing) { fixture in
            let active = installJournal(fixture)
            try active.write(to: fixture.bundle.installJournalURL)
            let other = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: other) }
            let wrongLease = try DoryVZMacMachineLease(rootURL: other)
            XCTAssertThrowsError(try DoryVZMacRecovery.recoverInterruptedOperation(in: fixture.bundle, holding: wrongLease, io: fixture.io))
            let lease = try DoryVZMacMachineLease(rootURL: fixture.bundle.rootURL)
            let otherOperation = DoryVZMacInstallJournal(operationID: UUID(), startedAt: active.startedAt,
                updatedAt: active.updatedAt, phase: .completed, progress: 1, restoreImageSHA256: active.restoreImageSHA256,
                machineIdentifierSHA256: active.machineIdentifierSHA256, error: nil)
            XCTAssertThrowsError(try DoryVZMacRecovery.commitInstallationOutcome(otherOperation, in: fixture.bundle, holding: lease, io: fixture.io))
            XCTAssertThrowsError(try recover(fixture)) // An independent recovery cannot take the runtime's lease.
            XCTAssertEqual(try DoryVZMacInstallJournal.load(from: fixture.bundle.installJournalURL), active)
            XCTAssertEqual(try fixture.readManifest(), fixture.bundle.manifest)
            try fixture.assertPersistentArtifacts()
            withExtendedLifetime(lease) {}
        }
    }

    func testNewAttemptJournalPublicationFaultsCanRetryThroughTheSameLeaseOwner() throws {
        let points: [DoryVZMacMetadataFile.Checkpoint] = [.temporaryCreated, .bytesWritten, .fileSynced, .published, .directorySynced]
        for state in [DoryVZMacMachineInstallationState.prepared, .installFailed] {
            for point in points {
                try withFixture(state: state) { fixture in
                    if state == .installFailed {
                        try installJournal(fixture).updating(phase: .failed, progress: 0.5,
                            error: "previous installer failure").write(to: fixture.bundle.installJournalURL)
                    }
                    let attempt = installJournal(fixture).updating(phase: .validatingRestore, progress: 0)
                    let lease = try DoryVZMacMachineLease(rootURL: fixture.bundle.rootURL)
                    var io = fixture.io
                    io.metadata.checkpoint = { if $0 == point { throw Interrupted.test } }
                    XCTAssertThrowsError(try DoryVZMacRecovery.beginInstallation(attempt, in: fixture.bundle, holding: lease, io: io))
                    XCTAssertEqual(try fixture.readManifest().installationState, state)
                    let recovered: DoryVZMacMachineBundle
                    if state == .installFailed {
                        recovered = try DoryVZMacRecovery.recoverInterruptedOperation(in: fixture.bundle, holding: lease, io: fixture.io)
                    } else { recovered = fixture.bundle }
                    _ = try DoryVZMacRecovery.beginInstallation(attempt, in: recovered, holding: lease, io: fixture.io)
                    XCTAssertEqual(try DoryVZMacInstallJournal.load(from: fixture.bundle.installJournalURL), attempt)
                    try fixture.assertPersistentArtifacts()
                }
            }
        }
    }

    func testFailureAfterInstallJournalCommitRetriesTheSameOperation() throws {
        try withFixture(state: .installing) { fixture in
            let journal = installJournal(fixture)
            try journal.write(to: fixture.bundle.installJournalURL)
            var io = fixture.io
            io.checkpoint = { if $0 == .installationJournalCommitted { throw Interrupted.test } }
            XCTAssertThrowsError(try recover(fixture, io: io))
            let failed = try DoryVZMacInstallJournal.load(from: fixture.bundle.installJournalURL)
            XCTAssertEqual(failed.operationID, journal.operationID)
            XCTAssertEqual(try fixture.readManifest().installationState, .installing)
            _ = try recover(fixture)
            XCTAssertEqual(try DoryVZMacInstallJournal.load(from: fixture.bundle.installJournalURL), failed)
            try fixture.assertPersistentArtifacts()
        }
    }

    func testEveryInstallMetadataPublicationBoundaryIsRecoverable() throws {
        let points: [DoryVZMacMetadataFile.Checkpoint] = [.temporaryCreated, .bytesWritten, .fileSynced, .published, .directorySynced]
        for writer in 1...2 {
            for point in points {
                try withFixture(state: .installing) { fixture in
                    let journal = installJournal(fixture)
                    try journal.write(to: fixture.bundle.installJournalURL)
                    var matches = 0
                    var io = fixture.io
                    io.metadata.checkpoint = { current in
                        if current == point { matches += 1; if matches == writer { throw Interrupted.test } }
                    }
                    XCTAssertThrowsError(try recover(fixture, io: io))
                    XCTAssertEqual(matches, writer)
                    _ = try recover(fixture)
                    XCTAssertEqual(try fixture.readManifest().installationState, .installFailed)
                    XCTAssertEqual(try DoryVZMacInstallJournal.load(from: fixture.bundle.installJournalURL).operationID, journal.operationID)
                    try fixture.assertPersistentArtifacts()
                }
            }
        }
    }

    func testInstallJournalFullDiskAndFlushErrorsDoNotPretendRecoveryCompleted() throws {
        for fullDisk in [false, true] {
            try withFixture(state: .installing) { fixture in
                let journal = installJournal(fixture)
                try journal.write(to: fixture.bundle.installJournalURL)
                var io = fixture.io
                if fullDisk { io.metadata.write = { _, _, _ in errno = ENOSPC; return -1 } }
                else { io.metadata.sync = { _, _ in errno = EIO; return -1 } }
                XCTAssertThrowsError(try recover(fixture, io: io))
                XCTAssertEqual(try fixture.readManifest().installationState, .installing)
                XCTAssertEqual(try DoryVZMacInstallJournal.load(from: fixture.bundle.installJournalURL), journal)
                try fixture.assertPersistentArtifacts()
            }
        }
    }

    func testExplicitColdRecoveryRetiresRAMFromAllSavedStateLifecycleStatesWithoutTouchingDisks() throws {
        for state in [DoryVZMacMachineInstallationState.restoring, .suspending, .suspended, .stopped] {
            try withFixture(state: state, ram: true) { fixture in
                let recovered = try recover(fixture, discard: true)
                XCTAssertEqual(recovered.manifest.installationState, .stopped)
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.bundle.suspendedStateURL.path))
                try fixture.assertPersistentArtifacts()
                _ = try recover(fixture, discard: true)
                try fixture.assertPersistentArtifacts()
            }
        }
    }

    func testColdRecoveryCannotCommitUntilRAMRetirementAndItsFlushesFinish() throws {
        try withFixture(state: .restoring, ram: true) { fixture in
            var io = fixture.io
            io.retirement.checkpoint = { if $0 == .receiptInvalidationDurable { throw Interrupted.test } }
            XCTAssertThrowsError(try recover(fixture, discard: true, io: io))
            XCTAssertEqual(try fixture.readManifest().installationState, .restoring)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipt.path))
            XCTAssertEqual(try Data(contentsOf: fixture.state), fixture.ramBytes)
            _ = try recover(fixture, discard: true)
            XCTAssertEqual(try fixture.readManifest().installationState, .stopped)
            try fixture.assertPersistentArtifacts()
        }
    }

    func testFailureAfterRAMRetirementAndEachColdManifestBoundaryRetriesSafely() throws {
        try withFixture(state: .restoring, ram: true) { fixture in
            var io = fixture.io
            io.checkpoint = { if $0 == .savedStateRetired { throw Interrupted.test } }
            XCTAssertThrowsError(try recover(fixture, discard: true, io: io))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.bundle.suspendedStateURL.path))
            XCTAssertEqual(try fixture.readManifest().installationState, .restoring)
            _ = try recover(fixture, discard: true)
            try fixture.assertPersistentArtifacts()
        }
        for point in [DoryVZMacMetadataFile.Checkpoint.temporaryCreated, .bytesWritten, .fileSynced, .published, .directorySynced] {
            try withFixture(state: .restoring, ram: true) { fixture in
                var io = fixture.io
                io.metadata.checkpoint = { if $0 == point { throw Interrupted.test } }
                XCTAssertThrowsError(try recover(fixture, discard: true, io: io))
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.bundle.suspendedStateURL.path))
                _ = try recover(fixture, discard: true)
                XCTAssertEqual(try fixture.readManifest().installationState, .stopped)
                try fixture.assertPersistentArtifacts()
            }
        }
    }

    func testDefaultInterruptedSuspendRecoversOnlyValidatedUnconsumedRAM() throws {
        try withFixture(state: .suspending, ram: true) { fixture in
            let receipt = try makeSavedStateReceipt(stateURL: fixture.state, bundle: fixture.bundle,
                                                   configurationSHA256: String(repeating: "d", count: 64))
            try DoryVZMacMetadataFile.write(JSONEncoder().encode(receipt), to: fixture.receipt)
            let recovered = try recover(fixture)
            XCTAssertEqual(recovered.manifest.installationState, .suspended)
            XCTAssertEqual(try Data(contentsOf: fixture.state), fixture.ramBytes)
            try fixture.assertPersistentArtifacts()
        }
        try withFixture(state: .suspending, ram: true) { fixture in
            try DoryVZSavedStateConsumption.consume(stateURL: fixture.state)
            XCTAssertThrowsError(try recover(fixture)) { error in
                XCTAssertEqual(error as? DoryVZMacSavedStateError, .alreadyConsumed)
            }
            XCTAssertEqual(try fixture.readManifest().installationState, .suspending)
            _ = try recover(fixture, discard: true)
            try fixture.assertPersistentArtifacts()
        }
        try withFixture(state: .suspending) { fixture in
            XCTAssertEqual(try recover(fixture).manifest.installationState, .stopped)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.bundle.suspendedStateURL.path))
        }
    }

    func testNoImplicitDiscardForSuspendedStateAndLinkedArtifactsArePreserved() throws {
        try withFixture(state: .suspended, ram: true) { fixture in
            XCTAssertThrowsError(try recover(fixture)) { error in
                XCTAssertEqual(error as? DoryVZMacRecoveryError, .noInterruptedOperation(.suspended))
            }
            XCTAssertEqual(try Data(contentsOf: fixture.state), fixture.ramBytes)
        }
        try withFixture(state: .restoring) { fixture in
            XCTAssertEqual(symlink("absent-RAM", fixture.bundle.suspendedStateURL.path), 0)
            XCTAssertThrowsError(try recover(fixture, discard: true))
            var information = stat()
            XCTAssertEqual(lstat(fixture.bundle.suspendedStateURL.path, &information), 0)
            XCTAssertEqual(information.st_mode & S_IFMT, S_IFLNK)
            XCTAssertEqual(try fixture.readManifest().installationState, .restoring)
            try fixture.assertPersistentArtifacts()
        }
    }

    func testUnknownRAMFilesAndHeldLeasePreventRecoveryMutation() throws {
        try withFixture(state: .restoring, ram: true) { fixture in
            let unknown = fixture.bundle.suspendedStateURL.appendingPathComponent("future-data")
            try Data("preserve".utf8).write(to: unknown)
            XCTAssertThrowsError(try recover(fixture, discard: true))
            XCTAssertEqual(try Data(contentsOf: unknown), Data("preserve".utf8))
            XCTAssertEqual(try Data(contentsOf: fixture.receipt), Data("owned-receipt".utf8))
            XCTAssertEqual(try fixture.readManifest().installationState, .restoring)
        }
        try withFixture(state: .restoring, ram: true) { fixture in
            let lease = try DoryVZMacMachineLease(rootURL: fixture.bundle.rootURL)
            defer { withExtendedLifetime(lease) {} }
            XCTAssertThrowsError(try recover(fixture, discard: true))
            XCTAssertEqual(try Data(contentsOf: fixture.state), fixture.ramBytes)
            XCTAssertEqual(try fixture.readManifest().installationState, .restoring)
        }
    }

    func testStaleBundleOrConfigurationChangeCannotBeOverwrittenByRecovery() throws {
        try withFixture(state: .restoring, ram: true) { fixture in
            let changed = try manifest(state: .restoring).replacingInstallationState(.prepared)
            // Change a stable identity field, not merely a legitimately progressing phase.
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(changed)) as? [String: Any])
            object["macAddress"] = "02:66:77:88:99:aa"
            let bytes = try JSONSerialization.data(withJSONObject: object)
            try bytes.write(to: fixture.bundle.manifestURL)
            XCTAssertThrowsError(try recover(fixture, discard: true)) { error in
                XCTAssertEqual(error as? DoryVZMacRecoveryError, .bundleChanged)
            }
            XCTAssertEqual(try Data(contentsOf: fixture.bundle.manifestURL), bytes)
            XCTAssertEqual(try Data(contentsOf: fixture.state), fixture.ramBytes)
        }
        try withFixture(state: .restoring, ram: true) { fixture in
            var io = fixture.io
            io.checkpoint = { point in
                if point == .savedStateRetired {
                    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.bundle.manifest)) as? [String: Any])
                    object["macAddress"] = "02:66:77:88:99:aa"
                    try JSONSerialization.data(withJSONObject: object).write(to: fixture.bundle.manifestURL)
                }
            }
            XCTAssertThrowsError(try recover(fixture, discard: true, io: io)) { error in
                XCTAssertEqual(error as? DoryVZMacRecoveryError, .bundleChanged)
            }
            XCTAssertEqual(try fixture.readManifest().macAddress, "02:66:77:88:99:aa")
            try fixture.assertPersistentArtifacts()
        }
    }

    private enum Interrupted: Error { case test }

    private struct Fixture {
        let bundle: DoryVZMacMachineBundle
        let persistent: [URL: Data]
        let ramBytes = Data("saved application RAM".utf8)
        var state: URL { bundle.suspendedStateURL.appendingPathComponent(DoryVZMacSavedStateArtifact.stateName) }
        var receipt: URL { bundle.suspendedStateURL.appendingPathComponent(DoryVZMacSavedStateArtifact.receiptName) }
        var io: DoryVZMacRecovery.IO {
            var io = DoryVZMacRecovery.IO()
            // These tests exercise real recovery metadata/retirement I/O. Apple hardware
            // identity and large disk admission are covered by the separately gated VM fixture.
            io.loadBundle = { root in
                let manifest = try JSONDecoder().decode(DoryVZMacMachineManifest.self, from: DoryVZMacMetadataFile.read(
                    from: root.appendingPathComponent(DoryVZMacMachineBundle.manifestName)
                ))
                try manifest.validate()
                return DoryVZMacMachineBundle(rootURL: root, manifest: manifest)
            }
            return io
        }
        func readManifest() throws -> DoryVZMacMachineManifest { try io.loadBundle(bundle.rootURL).manifest }
        func assertPersistentArtifacts() throws {
            for (url, bytes) in persistent { XCTAssertEqual(try Data(contentsOf: url), bytes) }
        }
    }

    private func recover(_ fixture: Fixture, discard: Bool = false, io: DoryVZMacRecovery.IO? = nil) throws -> DoryVZMacMachineBundle {
        try DoryVZMacRecovery.recoverInterruptedOperation(in: fixture.bundle,
            discardSavedStateAfterInterruptedRestore: discard, io: io ?? fixture.io)
    }

    private func withFixture(state: DoryVZMacMachineInstallationState, ram: Bool = false,
                             _ body: (Fixture) throws -> Void) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = DoryVZMacMachineBundle(rootURL: root, manifest: try manifest(state: state))
        try DoryVZMacMetadataFile.write(JSONEncoder().encode(bundle.manifest), to: bundle.manifestURL)
        let persistent = Dictionary(uniqueKeysWithValues:
            [bundle.diskURL, bundle.auxiliaryStorageURL, bundle.hardwareModelURL, bundle.machineIdentifierURL].map {
                ($0, Data("untouched-\($0.lastPathComponent)".utf8))
            })
        for (url, bytes) in persistent { try bytes.write(to: url); XCTAssertEqual(chmod(url.path, 0o600), 0) }
        let fixture = Fixture(bundle: bundle, persistent: persistent)
        if ram {
            try FileManager.default.createDirectory(at: bundle.suspendedStateURL, withIntermediateDirectories: false)
            try fixture.ramBytes.write(to: fixture.state)
            XCTAssertEqual(chmod(fixture.state.path, 0o600), 0)
            try Data("owned-receipt".utf8).write(to: fixture.receipt)
        }
        try body(fixture)
    }

    private func installJournal(_ fixture: Fixture) -> DoryVZMacInstallJournal {
        DoryVZMacInstallJournal(operationID: UUID(), startedAt: "2026-10-02T00:00:00Z", updatedAt: "2026-10-02T00:00:00Z",
            phase: .installing, progress: 0.5, restoreImageSHA256: fixture.bundle.manifest.restoreImageSHA256,
            machineIdentifierSHA256: fixture.bundle.manifest.machineIdentifierSHA256, error: nil)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-vzmac-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func manifest(
        state: DoryVZMacMachineInstallationState
    ) throws -> DoryVZMacMachineManifest {
        DoryVZMacMachineManifest(
            createdAt: "2026-08-30T14:00:00Z",
            installationState: state,
            origin: .created,
            parentMachineIdentifierSHA256: nil,
            restoreImageBuild: "25G83",
            restoreImageVersion: "26.6.2",
            restoreImageSourceURL: "https://updates.cdn-apple.com/restore.ipsw",
            restoreImageBytes: 1,
            restoreImageSHA256: String(repeating: "a", count: 64),
            hardwareModelSHA256: String(repeating: "b", count: 64),
            machineIdentifierSHA256: String(repeating: "c", count: 64),
            macAddress: "02:11:22:33:44:55",
            resources: try DoryVZMacResourcePlan(
                requestedCPUCount: 4,
                requestedMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
                requestedDiskBytes: 80 * DoryVZMacResourcePlan.gibibyte,
                requestedDisplays: nil,
                minimumCPUCount: 4,
                minimumMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
                maximumCPUCount: 12,
                maximumMemoryBytes: 64 * DoryVZMacResourcePlan.gibibyte
            )
        )
    }
}
