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

    func testManagedRestoreReportsAlreadyRunningWhenMetadataCommitFails() async throws {
        let box = ManagedSavedStateHookBox(runtimeState: .stopped)
        box.updateErrorForState = .stopped
        let stateURL = URL(fileURLWithPath: "/private/tmp/state.bin")

        do {
            try await DoryVZMacManagedSavedStateOperation.restore(
                from: stateURL,
                hooks: box.hooks()
            )
            XCTFail("restore should fail")
        } catch let error as DoryVZMacSavedStateError {
            guard case .invalidVirtualMachineState(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("already running"))
        }

        XCTAssertEqual(box.events, [
            "secure:\(stateURL.lastPathComponent)",
            "update:restoring",
            "restore:\(stateURL.lastPathComponent)",
            "resume",
            "update:stopped",
        ])
        XCTAssertEqual(box.installationStates, [.restoring])
        XCTAssertEqual(box.runtimeState, .running)
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
}

private enum TestSavedStateError: Error {
    case saveFailed
    case restoreFailed
    case resumeFailed
    case updateFailed
}

private final class ManagedSavedStateHookBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [String] = []
    private var storedRuntimeState: DoryVZMacManagedRuntimeState
    private var storedInstallationStates: [DoryVZMacMachineInstallationState] = []

    var saveError: TestSavedStateError?
    var restoreError: TestSavedStateError?
    var resumeError: TestSavedStateError?
    var updateErrorForState: DoryVZMacMachineInstallationState?

    init(runtimeState: DoryVZMacManagedRuntimeState = .running) {
        storedRuntimeState = runtimeState
    }

    var events: [String] {
        lock.withLock { storedEvents }
    }

    var installationStates: [DoryVZMacMachineInstallationState] {
        lock.withLock { storedInstallationStates }
    }

    var runtimeState: DoryVZMacManagedRuntimeState {
        get { lock.withLock { storedRuntimeState } }
        set { lock.withLock { storedRuntimeState = newValue } }
    }

    func hooks() -> DoryVZMacManagedSavedStateHooks {
        DoryVZMacManagedSavedStateHooks(
            runtimeState: { self.runtimeState },
            updateInstallationState: { state in
                self.append("update:\(state.rawValue)")
                if self.updateErrorForState == state {
                    throw TestSavedStateError.updateFailed
                }
                self.lock.withLock { self.storedInstallationStates.append(state) }
            },
            pause: {
                self.append("pause")
                self.runtimeState = .paused
            },
            resume: {
                self.append("resume")
                if let resumeError = self.resumeError { throw resumeError }
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
            },
            secureSavedState: { url in
                self.append("secure:\(url.lastPathComponent)")
            },
            removeSavedState: { url in
                self.append("remove:\(url.lastPathComponent)")
            }
        )
    }

    private func append(_ event: String) {
        lock.withLock { storedEvents.append(event) }
    }
}
