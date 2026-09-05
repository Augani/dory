import DoryVZMacCore
@testable import DoryVMMKit
import Foundation
import XCTest

final class DoryVZMacAdapterTests: XCTestCase {
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

    func testFailedSuspendProjectsObservedRuntimeState() {
        XCTAssertEqual(
            DoryVZMacAdapter.stateAfterFailedSuspend(runtimeState: .paused),
            .paused
        )
        XCTAssertEqual(
            DoryVZMacAdapter.stateAfterFailedSuspend(runtimeState: .running),
            .running
        )
        XCTAssertEqual(
            DoryVZMacAdapter.stateAfterFailedSuspend(runtimeState: .stopped),
            .stopped
        )
        XCTAssertEqual(
            DoryVZMacAdapter.stateAfterFailedSuspend(runtimeState: .other),
            .failed
        )
    }

    func testFailedRestoreReportsAlreadyRunningRuntimeState() {
        XCTAssertEqual(
            DoryVZMacAdapter.stateAfterFailedRestore(runtimeState: .running),
            .running
        )
        XCTAssertEqual(
            DoryVZMacAdapter.stateAfterFailedRestore(runtimeState: .paused),
            .paused
        )
        XCTAssertEqual(
            DoryVZMacAdapter.stateAfterFailedRestore(runtimeState: .stopped),
            .suspended
        )
        XCTAssertEqual(
            DoryVZMacAdapter.stateAfterFailedRestore(runtimeState: .other),
            .failed
        )
    }

    func testConfigurationStandardizesAllLocalArtifactPaths() {
        let configuration = DoryVZMacAdapterConfiguration(
            machineBundleURL: URL(fileURLWithPath: "/tmp/machines/../mac.doryvm"),
            guestToolsURL: URL(fileURLWithPath: "/tmp/tools/../guest-tools"),
            usbDiskURL: URL(fileURLWithPath: "/tmp/disks/../removable.img"),
            usbDiskReadOnly: false
        )

        XCTAssertEqual(configuration.machineBundleURL.path, "/tmp/mac.doryvm")
        XCTAssertEqual(configuration.guestToolsURL?.path, "/tmp/guest-tools")
        XCTAssertEqual(configuration.usbDiskURL?.path, "/tmp/removable.img")
        XCTAssertFalse(configuration.usbDiskReadOnly)
        XCTAssertEqual(DoryVZMacAdapter.maximumGuestDisplayCount, 1)
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
