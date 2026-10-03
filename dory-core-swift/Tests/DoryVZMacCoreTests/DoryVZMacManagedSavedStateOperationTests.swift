import Foundation
import XCTest
@testable import DoryVZMacCore

@MainActor
final class DoryVZMacManagedSavedStateOperationTests: XCTestCase {
    func testManagedSuspendCallsAppleSaveBeforePublishingSuspended() async throws {
        let box = ManagedSavedStateHookBox()
        let stateURL = URL(fileURLWithPath: "/private/tmp/state.tmp-11111111-1111-4111-8111-111111111111")

        try await DoryVZMacManagedSavedStateOperation.suspend(
            to: stateURL,
            hooks: box.hooks()
        )

        XCTAssertEqual(box.events, [
            "update:suspending",
            "pause",
            "save:\(stateURL.lastPathComponent)",
            "secure:\(stateURL.lastPathComponent)",
            "update:suspended",
        ])
        XCTAssertEqual(box.runtimeState, .paused)
    }

    func testManagedSuspendFailureLeavesSuspendingWhenRollbackResumeFails() async throws {
        let box = ManagedSavedStateHookBox()
        box.saveError = TestSavedStateError.saveFailed
        box.resumeError = TestSavedStateError.resumeFailed
        let stateURL = URL(fileURLWithPath: "/private/tmp/state.tmp-22222222-2222-4222-8222-222222222222")

        do {
            try await DoryVZMacManagedSavedStateOperation.suspend(
                to: stateURL,
                hooks: box.hooks()
            )
            XCTFail("suspend should fail")
        } catch TestSavedStateError.saveFailed {
            // Preserve the original Apple save failure.
        }

        XCTAssertEqual(box.events, [
            "update:suspending",
            "pause",
            "save:\(stateURL.lastPathComponent)",
            "remove:\(stateURL.lastPathComponent)",
            "resume",
        ])
        XCTAssertEqual(box.installationStates, [.suspending])
        XCTAssertEqual(box.runtimeState, .paused)
    }

    func testFailedSaveCannotResumeWhenRAMRetirementFails() async throws {
        let box = ManagedSavedStateHookBox()
        box.saveError = .saveFailed
        box.removeError = .removeFailed
        do {
            try await DoryVZMacManagedSavedStateOperation.suspend(
                to: URL(fileURLWithPath: "/private/tmp/state.tmp"), hooks: box.hooks()
            )
            XCTFail("failed RAM retirement must prohibit resume")
        } catch let error as DoryVZMacSavedStateError {
            XCTAssertTrue(error.description.contains("saveFailed"))
            XCTAssertTrue(error.description.contains("removeFailed"))
            XCTAssertTrue(error.description.contains("cold recovery required"))
        }
        XCTAssertEqual(box.events, ["update:suspending", "pause", "save:state.tmp", "remove:state.tmp"])
        XCTAssertEqual(box.installationStates, [.suspending])
        XCTAssertEqual(box.runtimeState, .paused)
    }

    func testFailedSuspendedCommitCannotResumeWhenRAMRetirementFails() async throws {
        let box = ManagedSavedStateHookBox()
        box.updateErrorForState = .suspended
        box.removeError = .removeFailed
        do {
            try await DoryVZMacManagedSavedStateOperation.suspend(
                to: URL(fileURLWithPath: "/private/tmp/state.tmp"), hooks: box.hooks()
            )
            XCTFail("complete saved RAM must not survive a live resume")
        } catch let error as DoryVZMacSavedStateError {
            XCTAssertTrue(error.description.contains("updateFailed"))
            XCTAssertTrue(error.description.contains("removeFailed"))
        }
        XCTAssertEqual(box.events, [
            "update:suspending", "pause", "save:state.tmp", "secure:state.tmp",
            "update:suspended", "remove:state.tmp",
        ])
        XCTAssertEqual(box.installationStates, [.suspending])
        XCTAssertEqual(box.runtimeState, .paused)
    }

    func testManagedSuspendFailureRetiresRAMBeforeRecoveringRunningGuest() async throws {
        let box = ManagedSavedStateHookBox()
        box.saveError = .saveFailed
        do {
            try await DoryVZMacManagedSavedStateOperation.suspend(
                to: URL(fileURLWithPath: "/private/tmp/state.tmp"), hooks: box.hooks()
            )
            XCTFail("original save failure must be reported")
        } catch TestSavedStateError.saveFailed {}
        XCTAssertEqual(box.events, [
            "update:suspending", "pause", "save:state.tmp", "remove:state.tmp", "resume", "update:stopped",
        ])
        XCTAssertEqual(box.installationStates, [.suspending, .stopped])
        XCTAssertEqual(box.runtimeState, .running)
    }

    func testPreCancelledSuspendDoesNotTouchMetadataOrAppleAPI() async throws {
        let box = ManagedSavedStateHookBox()
        let task = Task { @MainActor in
            try await DoryVZMacManagedSavedStateOperation.suspend(
                to: URL(fileURLWithPath: "/private/tmp/state.tmp"), hooks: box.hooks()
            )
        }
        task.cancel()
        do { try await task.value; XCTFail("cancelled suspend must fail") }
        catch is CancellationError {}
        XCTAssertEqual(box.events, [])
    }

    func testSuspendCancellationRetiresRAMBeforeResumingAndNeverPublishesSuspended() async throws {
        for boundary in ["pause", "secure"] {
            let box = ManagedSavedStateHookBox()
            let holder = SavedStateTaskHolder()
            defer { holder.task = nil }
            if boundary == "pause" { box.onPause = { holder.task?.cancel() } }
            else { box.onSecure = { holder.task?.cancel() } }
            holder.task = Task { @MainActor in
                try await DoryVZMacManagedSavedStateOperation.suspend(
                    to: URL(fileURLWithPath: "/private/tmp/state.tmp"), hooks: box.hooks()
                )
            }
            do { try await holder.task?.value; XCTFail("cancelled suspend must fail") }
            catch is CancellationError {}
            let prefix = boundary == "pause"
                ? ["update:suspending", "pause"]
                : ["update:suspending", "pause", "save:state.tmp", "secure:state.tmp"]
            XCTAssertEqual(box.events, prefix + ["remove:state.tmp", "resume", "update:stopped"])
            XCTAssertEqual(box.installationStates, [.suspending, .stopped])
            XCTAssertEqual(box.runtimeState, .running)
        }
    }

    func testManagedRestoreCannotResumeWhenColdBootMetadataCommitFails() async throws {
        let box = ManagedSavedStateHookBox(runtimeState: .stopped)
        box.updateErrorForState = .stopped
        let stateURL = URL(fileURLWithPath: "/private/tmp/state.bin")

        do {
            try await DoryVZMacManagedSavedStateOperation.restore(
                from: stateURL,
                hooks: box.hooks()
            )
            XCTFail("restore should fail")
        } catch TestSavedStateError.updateFailed {
            // The first resume is fenced by a durable cold-boot manifest.
        }

        XCTAssertEqual(box.events, [
            "secure:\(stateURL.lastPathComponent)",
            "update:restoring",
            "restore:\(stateURL.lastPathComponent)",
            "consume:\(stateURL.lastPathComponent)",
            "update:stopped",
        ])
        XCTAssertEqual(box.installationStates, [.restoring])
        XCTAssertEqual(box.runtimeState, .paused)
        XCTAssertTrue(box.consumed)
    }

    func testManagedRestoreFailureBeforeRunningRollsBackToSuspended() async throws {
        let box = ManagedSavedStateHookBox(runtimeState: .stopped)
        box.restoreError = TestSavedStateError.restoreFailed
        let stateURL = URL(fileURLWithPath: "/private/tmp/state.bin")

        do {
            try await DoryVZMacManagedSavedStateOperation.restore(
                from: stateURL,
                hooks: box.hooks()
            )
            XCTFail("restore should fail")
        } catch TestSavedStateError.restoreFailed {
            // Expected.
        }

        XCTAssertEqual(box.events, [
            "secure:\(stateURL.lastPathComponent)",
            "update:restoring",
            "restore:\(stateURL.lastPathComponent)",
            "update:suspended",
        ])
        XCTAssertEqual(box.installationStates, [.restoring, .suspended])
        XCTAssertEqual(box.runtimeState, .stopped)
    }

    func testConsumptionAndColdBootManifestPrecedeFirstResume() async throws {
        let box = ManagedSavedStateHookBox(runtimeState: .stopped)
        let stateURL = URL(fileURLWithPath: "/private/tmp/state.bin")
        try await DoryVZMacManagedSavedStateOperation.restore(from: stateURL, hooks: box.hooks())
        XCTAssertEqual(box.events, [
            "secure:state.bin", "update:restoring", "restore:state.bin",
            "consume:state.bin", "update:stopped", "resume",
        ])
        XCTAssertEqual(box.installationStates, [.restoring, .stopped])
        XCTAssertTrue(box.consumed)
        XCTAssertEqual(box.runtimeState, .running)
    }

    func testConsumedStateRejectsRetryBeforeAppleRestoreOrMetadataMutation() async throws {
        let box = ManagedSavedStateHookBox(runtimeState: .stopped)
        box.consumed = true
        do {
            try await DoryVZMacManagedSavedStateOperation.restore(
                from: URL(fileURLWithPath: "/private/tmp/state.bin"), hooks: box.hooks()
            )
            XCTFail("consumed state must not replay")
        } catch {
            XCTAssertEqual(error as? DoryVZMacSavedStateError, .alreadyConsumed)
        }
        XCTAssertEqual(box.events, [])
    }

    func testConsumptionFailureBeforeOrAfterPublicationNeverResumes() async throws {
        for published in [false, true] {
            let box = ManagedSavedStateHookBox(runtimeState: .stopped)
            box.consumeError = .consumeFailed
            box.consumePublishesBeforeFailure = published
            do {
                try await DoryVZMacManagedSavedStateOperation.restore(
                    from: URL(fileURLWithPath: "/private/tmp/state.bin"), hooks: box.hooks()
                )
                XCTFail("consumption must fail")
            } catch TestSavedStateError.consumeFailed {}
            XCTAssertEqual(box.consumed, published)
            XCTAssertEqual(box.installationStates, [.restoring])
            XCTAssertEqual(box.runtimeState, .paused)
            XCTAssertFalse(box.events.contains("resume"))
        }
    }

    func testFailedResumeNeverRearmsRAMEvenIfRuntimeIsStoppedOrPaused() async throws {
        for runtimeState in [DoryVZMacManagedRuntimeState.stopped, .paused, .other] {
            let box = ManagedSavedStateHookBox(runtimeState: .stopped)
            box.resumeError = .resumeFailed
            box.resumeStateOnFailure = runtimeState
            do {
                try await DoryVZMacManagedSavedStateOperation.restore(
                    from: URL(fileURLWithPath: "/private/tmp/state.bin"), hooks: box.hooks()
                )
                XCTFail("resume must fail")
            } catch TestSavedStateError.resumeFailed {}
            XCTAssertTrue(box.consumed)
            XCTAssertEqual(box.installationStates, [.restoring, .stopped])
            XCTAssertFalse(box.events.contains("update:suspended"))
        }
    }

    func testResumeErrorAfterRunningReportsLiveGuestWithoutRearmingSnapshot() async throws {
        let box = ManagedSavedStateHookBox(runtimeState: .stopped)
        box.resumeError = .resumeFailed
        box.resumeStateOnFailure = .running
        do {
            try await DoryVZMacManagedSavedStateOperation.restore(
                from: URL(fileURLWithPath: "/private/tmp/state.bin"), hooks: box.hooks()
            )
            XCTFail("resume callback must fail")
        } catch let error as DoryVZMacSavedStateError {
            XCTAssertTrue(error.description.contains("already running"))
        }
        XCTAssertTrue(box.consumed)
        XCTAssertEqual(box.runtimeState, .running)
        XCTAssertEqual(box.installationStates, [.restoring, .stopped])
    }

    func testPreCancelledRestoreDoesNotTouchMetadataOrAppleAPI() async throws {
        let box = ManagedSavedStateHookBox(runtimeState: .stopped)
        let task = Task { @MainActor in
            try await DoryVZMacManagedSavedStateOperation.restore(
                from: URL(fileURLWithPath: "/private/tmp/state.bin"), hooks: box.hooks()
            )
        }
        task.cancel()
        do { try await task.value; XCTFail("cancelled restore must fail") }
        catch is CancellationError {}
        XCTAssertEqual(box.events, [])
    }

    func testCancellationAfterConsumptionDoesNotResumeOrRearmRAM() async throws {
        let box = ManagedSavedStateHookBox(runtimeState: .stopped)
        let holder = SavedStateTaskHolder()
        defer { holder.task = nil }
        box.onConsume = { holder.task?.cancel() }
        holder.task = Task { @MainActor in
            try await DoryVZMacManagedSavedStateOperation.restore(
                from: URL(fileURLWithPath: "/private/tmp/state.bin"), hooks: box.hooks()
            )
        }
        do { try await holder.task?.value; XCTFail("cancelled restore must fail") }
        catch is CancellationError {}
        XCTAssertTrue(box.consumed)
        XCTAssertEqual(box.installationStates, [.restoring, .stopped])
        XCTAssertFalse(box.events.contains("resume"))
    }

    func testCancellationAfterAppleRestoreBeforeConsumeDoesNotResume() async throws {
        let box = ManagedSavedStateHookBox(runtimeState: .stopped)
        let holder = SavedStateTaskHolder()
        defer { holder.task = nil }
        box.onRestore = { holder.task?.cancel() }
        holder.task = Task { @MainActor in
            try await DoryVZMacManagedSavedStateOperation.restore(
                from: URL(fileURLWithPath: "/private/tmp/state.bin"), hooks: box.hooks()
            )
        }
        do { try await holder.task?.value; XCTFail("cancelled restore must fail") }
        catch is CancellationError {}
        XCTAssertFalse(box.consumed)
        XCTAssertEqual(box.runtimeState, .paused)
        XCTAssertEqual(box.installationStates, [.restoring])
        XCTAssertFalse(box.events.contains("resume"))
    }
}

@MainActor
private final class SavedStateTaskHolder { var task: Task<Void, Error>? }

private enum TestSavedStateError: Error {
    case saveFailed
    case restoreFailed
    case resumeFailed
    case updateFailed
    case consumeFailed
    case removeFailed
}

@MainActor
private final class ManagedSavedStateHookBox {
    private var storedEvents: [String] = []
    private var storedRuntimeState: DoryVZMacManagedRuntimeState
    private var storedInstallationStates: [DoryVZMacMachineInstallationState] = []

    var saveError: TestSavedStateError?
    var removeError: TestSavedStateError?
    var restoreError: TestSavedStateError?
    var resumeError: TestSavedStateError?
    var updateErrorForState: DoryVZMacMachineInstallationState?
    var consumed = false
    var consumeError: TestSavedStateError?
    var consumePublishesBeforeFailure = false
    var resumeStateOnFailure: DoryVZMacManagedRuntimeState?
    var onConsume: (() -> Void)?
    var onRestore: (() -> Void)?
    var onPause: (() -> Void)?
    var onSecure: (() -> Void)?

    init(runtimeState: DoryVZMacManagedRuntimeState = .running) {
        storedRuntimeState = runtimeState
    }

    var events: [String] {
        storedEvents
    }

    var installationStates: [DoryVZMacMachineInstallationState] {
        storedInstallationStates
    }

    var runtimeState: DoryVZMacManagedRuntimeState {
        get { storedRuntimeState }
        set { storedRuntimeState = newValue }
    }

    @MainActor func hooks() -> DoryVZMacManagedSavedStateHooks {
        DoryVZMacManagedSavedStateHooks(
            runtimeState: { self.runtimeState },
            updateInstallationState: { state in
                self.append("update:\(state.rawValue)")
                if self.updateErrorForState == state {
                    throw TestSavedStateError.updateFailed
                }
                self.storedInstallationStates.append(state)
            },
            pause: {
                self.append("pause")
                self.runtimeState = .paused
                self.onPause?()
            },
            resume: {
                self.append("resume")
                if let resumeError = self.resumeError {
                    if let state = self.resumeStateOnFailure { self.runtimeState = state }
                    throw resumeError
                }
                self.runtimeState = .running
            },
            save: { url in
                self.append("save:\(url.lastPathComponent)")
                if let saveError = self.saveError { throw saveError }
            },
            restore: { url in
                self.append("restore:\(url.lastPathComponent)")
                if let restoreError = self.restoreError { throw restoreError }
                self.runtimeState = .paused
                self.onRestore?()
            },
            secureSavedState: { url in
                self.append("secure:\(url.lastPathComponent)")
                self.onSecure?()
            },
            removeSavedState: { url in
                self.append("remove:\(url.lastPathComponent)")
                if let removeError = self.removeError { throw removeError }
            },
            isSavedStateConsumed: { _ in self.consumed },
            consumeSavedState: { url in
                self.append("consume:\(url.lastPathComponent)")
                if let error = self.consumeError {
                    self.consumed = self.consumePublishesBeforeFailure
                    throw error
                }
                self.consumed = true
                self.onConsume?()
            }
        )
    }

    private func append(_ event: String) {
        storedEvents.append(event)
    }
}
