import DoryVZMacCore
@testable import DorydKit
@testable import DoryVMMKit
import Foundation
import XCTest

final class DoryVZMacAdapterTests: XCTestCase {
    @MainActor
    func testInstallStopUsesCancellationEvenForIntermediateVMStoppedNotifications() async throws {
        let lifecycle = DoryVZMacDesktopInstallLifecycle()
        try await lifecycle.installThenStart {
            for state: DoryVZMacAdapterState in [.installing, .stopped, .failed, .running] {
                XCTAssertEqual(lifecycle.stopAction(state: state), .cancelInstall)
            }
        } start: {
            XCTAssertEqual(lifecycle.stopAction(state: .starting), .waitForTransition)
            XCTAssertEqual(lifecycle.stopAction(state: .running), .requestGuestShutdown)
        }
        XCTAssertEqual(lifecycle.stopAction(state: .stopped), .finish)
    }

    @MainActor
    func testEarlyDaemonTerminationCancelsPreparedInstallAndWaitsForStartTransitions() {
        let lifecycle = DoryVZMacDesktopInstallLifecycle()
        XCTAssertEqual(lifecycle.stopAction(state: .prepared), .cancelInstall)
        for state: DoryVZMacAdapterState in [.installing, .starting, .restoring, .pausing, .suspending] {
            XCTAssertEqual(lifecycle.stopAction(state: state), .waitForTransition)
        }
        XCTAssertEqual(lifecycle.stopAction(state: .running), .requestGuestShutdown)
        XCTAssertEqual(lifecycle.stopAction(state: .installFailed), .finish)
    }
    func testInstallerOwnsStopAndFailureUntilItsCallbackCompletes() {
        XCTAssertFalse(DoryVZMacAdapter.acceptsDelegateStop(state: .installing, transitionInProgress: true))
        XCTAssertTrue(DoryVZMacAdapter.acceptsDelegateStop(state: .installing, transitionInProgress: false))
        for state: DoryVZMacAdapterState in [.running, .starting, .paused, .stopping, .stopped, .failed] {
            XCTAssertTrue(DoryVZMacAdapter.acceptsDelegateStop(state: state, transitionInProgress: true))
        }
    }

    @MainActor
    func testCancelledInstallerSuccessCannotStartFirstBoot() async {
        let lifecycle = DoryVZMacDesktopInstallLifecycle()
        let holder = InstallLifecycleTaskHolder()
        var starts = 0
        let task = Task { @MainActor in
            try await lifecycle.installThenStart {
                XCTAssertTrue(lifecycle.isInstallingRestore)
                holder.task?.cancel()
                // Model an Apple install callback that returns success despite cancellation.
            } start: { starts += 1 }
        }
        holder.task = task
        do { try await task.value; XCTFail("expected cancellation before first boot") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(starts, 0)
        XCTAssertFalse(lifecycle.isInstallingRestore)
        XCTAssertTrue(lifecycle.shouldFinishStoppedObservation(operation: .install))
        holder.task = nil
    }

    @MainActor
    func testPrecancelledInstallLifecycleDoesNotCallInstaller() async {
        let lifecycle = DoryVZMacDesktopInstallLifecycle()
        var installs = 0
        var starts = 0
        let task = Task { @MainActor in
            try await lifecycle.installThenStart { installs += 1 } start: { starts += 1 }
        }
        task.cancel()
        do { try await task.value; XCTFail("expected pre-start cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(installs, 0)
        XCTAssertEqual(starts, 0)
        XCTAssertFalse(lifecycle.isInstallingRestore)
    }
    func testProjectsEveryDurableMachineStateTruthfully() {
        let cases: [(DoryVZMacMachineInstallationState, DoryVZMacAdapterState)] = [
            (.prepared, .prepared),
            (.installing, .installing),
            (.installFailed, .installFailed),
            (.stopped, .stopped),
            (.suspending, .suspending),
            (.suspended, .suspended),
            (.restoring, .restoring),
        ]

        for (durable, projected) in cases {
            XCTAssertEqual(DoryVZMacAdapter.initialState(for: durable), projected)
        }
    }


    func testObservedRuntimeStateProjection() {
        XCTAssertEqual(
            DoryVZMacAdapter.observedState(runtimeState: .running),
            .running
        )
        XCTAssertEqual(
            DoryVZMacAdapter.observedState(runtimeState: .paused),
            .paused
        )
        XCTAssertEqual(
            DoryVZMacAdapter.observedState(runtimeState: .stopped),
            .stopped
        )
        XCTAssertEqual(
            DoryVZMacAdapter.observedState(runtimeState: .other),
            .failed
        )
    }

    func testFailedRestoreReportsAlreadyRunningRuntimeState() {
        XCTAssertEqual(
            DoryVZMacAdapter.stateAfterFailedRestore(runtimeState: .running, installationState: .stopped),
            .running
        )
        XCTAssertEqual(
            DoryVZMacAdapter.stateAfterFailedRestore(runtimeState: .paused, installationState: .stopped),
            .paused
        )
        XCTAssertEqual(
            DoryVZMacAdapter.stateAfterFailedRestore(runtimeState: .stopped, installationState: .suspended),
            .suspended
        )
        XCTAssertEqual(
            DoryVZMacAdapter.stateAfterFailedRestore(runtimeState: .other, installationState: .restoring),
            .failed
        )
    }

    func testFailedRestoreCannotAdvertiseSuspendedOrResumableBeforeCommit() {
        XCTAssertEqual(DoryVZMacAdapter.stateAfterFailedRestore(
            runtimeState: .stopped, installationState: .restoring), .failed)
        XCTAssertEqual(DoryVZMacAdapter.stateAfterFailedRestore(
            runtimeState: .stopped, installationState: .stopped), .failed)
        XCTAssertEqual(DoryVZMacAdapter.stateAfterFailedRestore(
            runtimeState: .paused, installationState: .restoring), .failed)
        XCTAssertEqual(DoryVZMacAdapter.stateAfterFailedRestore(
            runtimeState: .paused, installationState: .suspended), .failed)
    }

    func testConfigurationStandardizesAllLocalArtifactPaths() {
        let configuration = DoryVZMacAdapterConfiguration(
            machineBundleURL: URL(fileURLWithPath: "/tmp/machines/../mac.doryvm"),
            guestToolsURL: URL(fileURLWithPath: "/tmp/tools/../guest-tools"),
            usbDiskURL: URL(fileURLWithPath: "/tmp/disks/../removable.img"),
            usbDiskReadOnly: false,
            shares: [DoryMachineShareConfiguration(
                tag: "project",
                hostPath: "/tmp/shares/../project",
                guestPath: "/Users/dory/project"
            )]
        )

        XCTAssertEqual(configuration.machineBundleURL.path, "/tmp/mac.doryvm")
        XCTAssertEqual(configuration.guestToolsURL?.path, "/tmp/guest-tools")
        XCTAssertEqual(configuration.usbDiskURL?.path, "/tmp/removable.img")
        XCTAssertFalse(configuration.usbDiskReadOnly)
        XCTAssertEqual(configuration.shares.first?.hostPath, "/tmp/project")
        XCTAssertEqual(
            DoryVZMacAdapter.maximumGuestDisplayCount,
            DoryVZMacResourcePlan.maximumDisplayCount
        )
    }

    func testInvalidStateErrorNamesExpectedAndActualStates() {
        let error = DoryVZMacAdapterError.invalidState(
            expected: [.stopped, .suspended],
            actual: .running
        )

        XCTAssertEqual(
            error.description,
            "VZMac is running; expected stopped or suspended"
        )
    }


    @MainActor
    func testInstallLifecycleSkipsFirstBootStartWhenInstallerLeavesGuestRunning() async throws {
        let lifecycle = DoryVZMacDesktopInstallLifecycle()
        var startCount = 0

        try await lifecycle.installThenStart {
        } alreadyRunning: {
            true
        } start: {
            startCount += 1
        }

        XCTAssertEqual(startCount, 0)
        XCTAssertTrue(lifecycle.shouldFinishStoppedObservation(operation: .install))
    }

    @MainActor
    func testInstallLifecycleIgnoresInstallerStoppedAndStartsFirstBoot() async throws {
        let lifecycle = DoryVZMacDesktopInstallLifecycle()
        var finishCount = 0
        var startCount = 0

        try await lifecycle.installThenStart {
            if lifecycle.shouldFinishStoppedObservation(operation: .install) {
                finishCount += 1
            }
        } start: {
            startCount += 1
        }

        XCTAssertEqual(finishCount, 0)
        XCTAssertEqual(startCount, 1)
        XCTAssertTrue(lifecycle.shouldFinishStoppedObservation(operation: .install))
    }

    @MainActor
    func testInstallLifecycleDoesNotConsumeFirstBootOnDuplicateInstallerStops() async throws {
        let lifecycle = DoryVZMacDesktopInstallLifecycle()
        var finishCount = 0
        var startCount = 0

        try await lifecycle.installThenStart {
            for _ in 0..<2 {
                if lifecycle.shouldFinishStoppedObservation(operation: .install) {
                    finishCount += 1
                }
            }
        } start: {
            startCount += 1
        }

        XCTAssertEqual(finishCount, 0)
        XCTAssertEqual(startCount, 1)
        XCTAssertTrue(lifecycle.shouldFinishStoppedObservation(operation: .install))
    }

    @MainActor
    func testInstallLifecycleResetsAfterStartFailure() async {
        struct StartFailure: Error, Equatable {}
        let lifecycle = DoryVZMacDesktopInstallLifecycle()
        var finishCount = 0
        var startCount = 0

        do {
            try await lifecycle.installThenStart {
                if lifecycle.shouldFinishStoppedObservation(operation: .install) {
                    finishCount += 1
                }
            } start: {
                startCount += 1
                throw StartFailure()
            }
            XCTFail("expected first boot start failure")
        } catch is StartFailure {
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(finishCount, 0)
        XCTAssertEqual(startCount, 1)
        XCTAssertTrue(lifecycle.shouldFinishStoppedObservation(operation: .install))
    }

    @MainActor
    func testInstallLifecycleFinishesRealPostbootStoppedObservation() async throws {
        let lifecycle = DoryVZMacDesktopInstallLifecycle()

        try await lifecycle.installThenStart {
            XCTAssertFalse(lifecycle.shouldFinishStoppedObservation(operation: .install))
        } start: {}

        XCTAssertTrue(lifecycle.shouldFinishStoppedObservation(operation: .install))
        XCTAssertTrue(lifecycle.shouldFinishStoppedObservation(operation: .run))
        XCTAssertTrue(lifecycle.shouldFinishStoppedObservation(operation: .resume))
    }
}

@MainActor
private final class InstallLifecycleTaskHolder {
    var task: Task<Void, Error>?
}
