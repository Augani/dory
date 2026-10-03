import DoryRendererWorkerWireContracts
import DoryVMDisplayWireContracts
import Foundation
import XCTest
@testable import DorydKit

/// These tests model broker admission and runner delivery separately: accepting an input
/// request does not prove that a guest consumed it, and an application may disappear at either
/// boundary without sending a final key-up request.
final class DoryVMDisplayInputLifetimeTests: XCTestCase {
    func testDisconnectReleasesDeliveredKeysAndButtonsForEveryEndpointExactlyOnce() throws {
        let endpoints: [(DoryVMDisplayInputEndpoint, [UInt16])] = [
            (.keyboard, [30, 42]),
            (.absolutePointer, [272, 276]),
            (.relativePointer, [272, 276]),
        ]
        for (endpoint, codes) in endpoints {
            let fixture = try Fixture()
            let app = try fixture.application()
            try fixture.send(
                app: app, sequence: 1, endpoint: endpoint,
                events: codes.map { .init(type: 1, code: $0, value: 1) }
            )
            var after: UInt64 = 0
            XCTAssertNotNil(try fixture.next(after: &after))

            fixture.broker.invalidateApplication(sessionID: app)
            fixture.broker.invalidateApplication(sessionID: app)
            let cleanup = try fixture.drain(after: &after)
            XCTAssertEqual(cleanup.count, 1, "\(endpoint)")
            XCTAssertEqual(cleanup.first?.operationID, fixture.operationText)
            XCTAssertEqual(cleanup.first?.inputEndpoint, endpoint)
            XCTAssertEqual(cleanup.first?.inputEvents, codes.map {
                .init(type: 1, code: $0, value: 0)
            })
            XCTAssertNil(try fixture.next(after: &after))
        }
    }

    func testDisconnectDropsUndeliveredPressWithoutInventingGuestInput() throws {
        let fixture = try Fixture()
        let app = try fixture.application()
        try fixture.send(app: app, sequence: 1, events: [key(30, 1)])

        fixture.broker.invalidateApplication(sessionID: app)
        var after: UInt64 = 0
        XCTAssertNil(try fixture.next(after: &after))
    }

    func testQueuedReleaseDoesNotForgetDeliveredPressOnDisconnect() throws {
        let fixture = try Fixture()
        let app = try fixture.application()
        try fixture.send(app: app, sequence: 1, events: [key(30, 1)])
        var after: UInt64 = 0
        XCTAssertNotNil(try fixture.next(after: &after))
        try fixture.send(app: app, sequence: 2, events: [key(30, 0)])

        fixture.broker.invalidateApplication(sessionID: app)
        let cleanup = try fixture.drain(after: &after)
        XCTAssertEqual(cleanup.count, 1)
        XCTAssertEqual(cleanup.first?.inputEvents, [key(30, 0)])
    }

    func testDeliveredUnacknowledgedReleaseStillRequiresDisconnectCleanup() throws {
        let fixture = try Fixture()
        let app = try fixture.application()
        try fixture.send(app: app, sequence: 1, events: [key(30, 1)])
        var after: UInt64 = 0
        XCTAssertNotNil(try fixture.next(after: &after))
        try fixture.send(app: app, sequence: 2, events: [key(30, 0)])
        let release = try XCTUnwrap(fixture.next(after: &after, acknowledge: false))
        XCTAssertEqual(release.inputEvents, [key(30, 0)])

        fixture.broker.invalidateApplication(sessionID: app)
        XCTAssertEqual(try fixture.drain(after: &after).flatMap(\.inputEvents), [key(30, 0)])
    }

    func testLateReleaseAcknowledgementCannotDischargeANewerPress() throws {
        let fixture = try Fixture()
        let app = try fixture.application()
        var after: UInt64 = 0
        try fixture.send(app: app, sequence: 1, events: [key(30, 1)])
        XCTAssertNotNil(try fixture.next(after: &after))
        try fixture.send(app: app, sequence: 2, events: [key(30, 0)])
        let oldRelease = try XCTUnwrap(fixture.next(after: &after, acknowledge: false))
        try fixture.send(app: app, sequence: 3, events: [key(30, 1)])
        XCTAssertNotNil(try fixture.next(after: &after))

        try fixture.acknowledge(oldRelease)
        fixture.broker.invalidateApplication(sessionID: app)
        XCTAssertEqual(try fixture.drain(after: &after).flatMap(\.inputEvents), [key(30, 0)])
    }

    func testReleaseThenRepressWithinOneBatchRetainsFinalHeldState() throws {
        let fixture = try Fixture()
        let app = try fixture.application()
        let batch = [key(30, 1), key(30, 0), key(30, 1)]
        try fixture.send(app: app, sequence: 1, events: batch)
        var after: UInt64 = 0
        XCTAssertEqual(try fixture.next(after: &after)?.inputEvents, batch)

        fixture.broker.invalidateApplication(sessionID: app)
        XCTAssertEqual(try fixture.drain(after: &after).flatMap(\.inputEvents), [key(30, 0)])
    }

    func testUnacknowledgedOlderCleanupCannotBlockReleaseOfANewerPress() throws {
        let fixture = try Fixture()
        let first = try fixture.application()
        var after: UInt64 = 0
        try fixture.send(app: first, sequence: 1, events: [key(30, 1)])
        XCTAssertNotNil(try fixture.next(after: &after))
        fixture.broker.invalidateApplication(sessionID: first)
        let firstCleanup = try XCTUnwrap(fixture.next(after: &after, acknowledge: false))

        let second = try fixture.application()
        try fixture.send(app: second, sequence: 1, events: [key(30, 1)])
        XCTAssertNotNil(try fixture.next(after: &after))
        fixture.broker.invalidateApplication(sessionID: second)
        let secondCleanup = try XCTUnwrap(fixture.next(after: &after, acknowledge: false))
        XCTAssertEqual(secondCleanup.inputEvents, [key(30, 0)])
        try fixture.acknowledgeIfStillKnown(firstCleanup)

        let third = try fixture.application()
        try fixture.send(app: third, sequence: 1, events: [key(30, 1)])
        XCTAssertNotNil(try fixture.next(after: &after))
        fixture.broker.invalidateApplication(sessionID: third)
        let thirdCleanup = try XCTUnwrap(fixture.next(after: &after, acknowledge: false))
        XCTAssertEqual(thirdCleanup.inputEvents, [key(30, 0)])
        try fixture.acknowledgeIfStillKnown(secondCleanup)
        try fixture.acknowledge(thirdCleanup)
        XCTAssertNil(try fixture.next(after: &after))
    }

    func testPartiallySupersededCleanupRetainsOnlyItsOlderIndependentKeyDebt() throws {
        let fixture = try Fixture()
        let first = try fixture.application()
        var after: UInt64 = 0
        try fixture.send(app: first, sequence: 1, events: [key(30, 1), key(31, 1)])
        XCTAssertNotNil(try fixture.next(after: &after))
        fixture.broker.invalidateApplication(sessionID: first)
        let firstCleanup = try XCTUnwrap(fixture.next(after: &after, acknowledge: false))
        XCTAssertEqual(firstCleanup.inputEvents, [key(30, 0), key(31, 0)])

        let second = try fixture.application()
        try fixture.send(app: second, sequence: 1, events: [key(30, 1)])
        XCTAssertNotNil(try fixture.next(after: &after))
        fixture.broker.invalidateApplication(sessionID: second)
        let secondCleanup = try XCTUnwrap(fixture.next(after: &after, acknowledge: false))
        XCTAssertEqual(secondCleanup.inputEvents, [key(30, 0)])
        // The first cleanup still owns key31, so its ACK is valid; it must not erase the
        // newer key30 cleanup marker or cause a duplicate key30 retry before that ACK.
        try fixture.acknowledge(firstCleanup)
        XCTAssertNil(try fixture.next(after: &after))
        try fixture.acknowledge(secondCleanup)
        XCTAssertNil(try fixture.next(after: &after))
    }

    func testDisconnectKeepsAggregateKeyHeldUntilLastOfSixteenOwnersLeaves() throws {
        let fixture = try Fixture()
        let apps = try (0..<16).map { _ in try fixture.application() }
        var after: UInt64 = 0
        for app in apps {
            try fixture.send(app: app, sequence: 1, events: [key(30, 1)])
            // A redundant aggregate press may be suppressed or forwarded; either way the
            // runner must not receive an aggregate release until the final owner disappears.
            _ = try fixture.drain(after: &after)
        }
        for app in apps.dropLast() {
            fixture.broker.invalidateApplication(sessionID: app)
            XCTAssertTrue(try fixture.drain(after: &after).isEmpty)
        }
        fixture.broker.invalidateApplication(sessionID: try XCTUnwrap(apps.last))
        let cleanup = try fixture.drain(after: &after)
        XCTAssertEqual(cleanup.flatMap(\.inputEvents), [key(30, 0)])
    }

    func testOneApplicationNormalReleaseCannotReleaseAnotherApplicationsKey() throws {
        let fixture = try Fixture()
        let first = try fixture.application()
        let second = try fixture.application()
        var after: UInt64 = 0
        for app in [first, second] {
            try fixture.send(app: app, sequence: 1, events: [key(30, 1)])
            _ = try fixture.drain(after: &after)
        }
        try fixture.send(app: first, sequence: 2, events: [key(30, 0)])
        let firstRelease = try fixture.drain(after: &after)
        XCTAssertFalse(firstRelease.flatMap(\.inputEvents).contains(key(30, 0)))
        fixture.broker.invalidateApplication(sessionID: first)
        XCTAssertTrue(try fixture.drain(after: &after).isEmpty)

        fixture.broker.invalidateApplication(sessionID: second)
        XCTAssertEqual(try fixture.drain(after: &after).flatMap(\.inputEvents), [key(30, 0)])
    }

    func testFullOrdinaryQueueCannotPreventDisconnectCleanup() throws {
        let fixture = try Fixture()
        let inputApp = try fixture.application()
        let modeApp = try fixture.application()
        try fixture.send(app: inputApp, sequence: 1, events: [key(30, 1)])
        var after: UInt64 = 0
        XCTAssertNotNil(try fixture.next(after: &after))
        for sequence in 1...256 {
            try fixture.resize(app: modeApp, sequence: UInt64(sequence))
        }
        XCTAssertThrowsError(try fixture.resize(app: modeApp, sequence: 257)) { error in
            XCTAssertEqual(error as? DoryVMDisplayRelayError, .saturated)
        }

        fixture.broker.invalidateApplication(sessionID: inputApp)
        let remaining = try fixture.drain(after: &after)
        XCTAssertEqual(remaining.filter { $0.kind == .resize }.count, 256)
        XCTAssertEqual(remaining.filter { $0.kind == .input }.flatMap(\.inputEvents), [key(30, 0)])
        XCTAssertEqual(remaining.count, 257)
    }

    func testMaximumHeldInputSetIsReleasedInBoundedEndpointSpecificBatches() throws {
        let fixture = try Fixture()
        let app = try fixture.application()
        let keyboardCodes = Array(UInt16(1)...UInt16(255))
        let pointerCodes = Array(UInt16(272)...UInt16(276))
        var sequence: UInt64 = 1
        var after: UInt64 = 0
        // The production input endpoint appends SYN_REPORT inside its 64-event bound.
        for start in stride(from: 0, to: keyboardCodes.count, by: 63) {
            let end = min(start + 63, keyboardCodes.count)
            try fixture.send(
                app: app, sequence: sequence,
                events: keyboardCodes[start..<end].map { key($0, 1) }
            )
            sequence += 1
            _ = try fixture.drain(after: &after)
        }
        for endpoint in [DoryVMDisplayInputEndpoint.absolutePointer, .relativePointer] {
            try fixture.send(
                app: app, sequence: sequence, endpoint: endpoint,
                events: pointerCodes.map { key($0, 1) }
            )
            sequence += 1
            _ = try fixture.drain(after: &after)
        }

        fixture.broker.invalidateApplication(sessionID: app)
        let cleanup = try fixture.drain(after: &after)
        XCTAssertEqual(cleanup.count, 7)
        XCTAssertTrue(cleanup.allSatisfy {
            !$0.inputEvents.isEmpty && $0.inputEvents.count <= 63
                && $0.inputEvents.allSatisfy { $0.type == 1 && $0.value == 0 }
        })
        XCTAssertEqual(
            cleanup.filter { $0.inputEndpoint == .keyboard }.flatMap(\.inputEvents).map(\.code),
            keyboardCodes
        )
        for endpoint in [DoryVMDisplayInputEndpoint.absolutePointer, .relativePointer] {
            XCTAssertEqual(
                cleanup.filter { $0.inputEndpoint == endpoint }.flatMap(\.inputEvents).map(\.code),
                pointerCodes
            )
        }
    }

    func testDeliveredUnacknowledgedWorkRemainsPartOfAdmissionQuota() throws {
        let fixture = try Fixture()
        let app = try fixture.application()
        var after: UInt64 = 0
        for sequence in 1...256 {
            try fixture.resize(app: app, sequence: UInt64(sequence))
            XCTAssertNotNil(try fixture.next(after: &after, acknowledge: false))
        }
        XCTAssertThrowsError(try fixture.resize(app: app, sequence: 257)) { error in
            XCTAssertEqual(error as? DoryVMDisplayRelayError, .saturated)
        }
    }

    func testApplicationSequencesAreScopedAndRunnerSequencesRemainMonotonic() throws {
        let fixture = try Fixture()
        let first = try fixture.application()
        let second = try fixture.application()
        try fixture.send(app: first, sequence: .max, events: [key(30, 1)])
        var after: UInt64 = 0
        let firstDelivered = try XCTUnwrap(fixture.next(after: &after))
        XCTAssertLessThan(firstDelivered.sequence, UInt64.max)
        try fixture.send(app: second, sequence: 1, events: [key(31, 1)])
        let secondDelivered = try XCTUnwrap(fixture.next(after: &after))
        XCTAssertGreaterThan(secondDelivered.sequence, firstDelivered.sequence)
        XCTAssertThrowsError(try fixture.send(app: second, sequence: 1, events: [key(32, 1)])) {
            XCTAssertEqual($0 as? DoryVMDisplayRelayError, .nonMonotonicSequence)
        }
        XCTAssertTrue(fixture.broker.commandStatus(
            machineID: "ubuntu", operationID: fixture.operationText,
            sequence: .max, applicationSessionID: first
        ).applied)
        XCTAssertTrue(fixture.broker.commandStatus(
            machineID: "ubuntu", operationID: fixture.operationText,
            sequence: 1, applicationSessionID: second
        ).applied)
    }

    func testSameApplicationSequenceStatusCannotBeReadFromAnotherSession() throws {
        let fixture = try Fixture()
        let first = try fixture.application()
        let second = try fixture.application()
        try fixture.send(app: first, sequence: 1, events: [key(30, 1)])
        var after: UInt64 = 0
        XCTAssertNotNil(try fixture.next(after: &after))
        try fixture.resize(app: second, sequence: 1)
        XCTAssertNotNil(try fixture.next(after: &after, acknowledge: false))

        let firstStatus = fixture.broker.commandStatus(
            machineID: "ubuntu", operationID: fixture.operationText,
            sequence: 1, applicationSessionID: first
        )
        let secondStatus = fixture.broker.commandStatus(
            machineID: "ubuntu", operationID: fixture.operationText,
            sequence: 1, applicationSessionID: second
        )
        XCTAssertTrue(firstStatus.known)
        XCTAssertTrue(firstStatus.applied)
        XCTAssertTrue(secondStatus.known)
        XCTAssertFalse(secondStatus.applied)
        XCTAssertEqual(secondStatus.detail, "pending")
        XCTAssertFalse(fixture.broker.commandStatus(
            machineID: "ubuntu", operationID: fixture.operationText,
            sequence: 1, applicationSessionID: UUID()
        ).known)
    }

    func testInvalidatedApplicationCannotReadmitQueuedInput() throws {
        let fixture = try Fixture()
        let app = try fixture.application()
        fixture.broker.invalidateApplication(sessionID: app)

        XCTAssertThrowsError(try fixture.send(app: app, sequence: 1, events: [key(30, 1)]))
        var after: UInt64 = 0
        XCTAssertNil(try fixture.next(after: &after))
    }

    func testConnectionAdmissionIsBoundedAndDisconnectReturnsItsSlot() throws {
        let fixture = try Fixture()
        let applications = try (0..<256).map { _ in try fixture.application() }
        XCTAssertThrowsError(try fixture.application()) { error in
            XCTAssertEqual(error as? DoryVMDisplayRelayError, .saturated)
        }
        fixture.broker.invalidateApplication(sessionID: try XCTUnwrap(applications.first))
        XCTAssertNoThrow(try fixture.application())
    }

    func testDeliveredFocusLeaseIsRevokedExactlyOnceOnApplicationDisconnect() throws {
        let fixture = try Fixture()
        let app = try fixture.application()
        let lease = UUID()
        try fixture.focus(app: app, sequence: 1, lease: lease, active: true)
        var after: UInt64 = 0
        XCTAssertEqual(try fixture.next(after: &after)?.focused, true)

        fixture.broker.invalidateApplication(sessionID: app)
        fixture.broker.invalidateApplication(sessionID: app)
        let cleanup = try fixture.drain(after: &after)
        XCTAssertEqual(cleanup.count, 1)
        XCTAssertEqual(cleanup.first?.kind, .focus)
        XCTAssertEqual(cleanup.first?.focused, false)
        XCTAssertEqual(cleanup.first?.focusLeaseID, lease.uuidString.lowercased())
    }

    func testUndeliveredFocusLeaseIsDiscardedWithoutActivatingGuestClipboard() throws {
        let fixture = try Fixture()
        let app = try fixture.application()
        try fixture.focus(app: app, sequence: 1, lease: UUID(), active: true)

        fixture.broker.invalidateApplication(sessionID: app)
        var after: UInt64 = 0
        XCTAssertNil(try fixture.next(after: &after))
    }

    func testExpiredFocusGrantIsRejectedBeforeAdmission() throws {
        let fixture = try Fixture()
        let app = try fixture.application()
        let expired = DispatchTime.now().uptimeNanoseconds - 1
        XCTAssertThrowsError(try fixture.focus(
            app: app, sequence: 1, lease: UUID(), active: true,
            expiresAtUptimeNanoseconds: expired
        )) { error in
            XCTAssertEqual(error as? DoryVMDisplayWireError, .invalidCommand)
        }
        var after: UInt64 = 0
        XCTAssertNil(try fixture.next(after: &after))
    }

    func testUnboundedFutureFocusGrantIsRejectedBeforeAdmission() throws {
        let fixture = try Fixture()
        let app = try fixture.application()
        XCTAssertThrowsError(try fixture.focus(
            app: app, sequence: 1, lease: UUID(), active: true,
            expiresAtUptimeNanoseconds: .max
        )) { error in
            XCTAssertEqual(error as? DoryVMDisplayWireError, .invalidCommand)
        }
        var after: UInt64 = 0
        XCTAssertNil(try fixture.next(after: &after))
    }

    func testQueuedExpiredFocusGrantCannotTakeOverTheCurrentOwner() throws {
        let fixture = try Fixture()
        let currentApp = try fixture.application()
        let delayedApp = try fixture.application()
        let currentLease = UUID()
        var after: UInt64 = 0
        try fixture.focus(app: currentApp, sequence: 1, lease: currentLease, active: true)
        XCTAssertNotNil(try fixture.next(after: &after))
        try fixture.focus(
            app: delayedApp, sequence: 1, lease: UUID(), active: true,
            expiresAtUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 20_000_000
        )
        // The original absolute grant deadline must survive the wait in the broker queue.
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertNil(try fixture.next(after: &after))
        XCTAssertEqual(fixture.broker.commandStatus(
            machineID: "ubuntu", operationID: fixture.operationText,
            sequence: 1, applicationSessionID: delayedApp
        ).detail, "expired-focus-lease")
        fixture.broker.invalidateApplication(sessionID: delayedApp)
        XCTAssertNil(try fixture.next(after: &after))

        fixture.broker.invalidateApplication(sessionID: currentApp)
        let cleanup = try fixture.drain(after: &after)
        XCTAssertEqual(cleanup.count, 1)
        XCTAssertEqual(cleanup.first?.focusLeaseID, currentLease.uuidString.lowercased())
        XCTAssertEqual(cleanup.first?.focused, false)
    }

    func testFullOrdinaryQueuePreservesFocusRevocationCapacity() throws {
        let fixture = try Fixture()
        let focusApp = try fixture.application()
        let modeApp = try fixture.application()
        let lease = UUID()
        try fixture.focus(app: focusApp, sequence: 1, lease: lease, active: true)
        var after: UInt64 = 0
        XCTAssertNotNil(try fixture.next(after: &after))
        for sequence in 1...256 {
            try fixture.resize(app: modeApp, sequence: UInt64(sequence))
        }

        fixture.broker.invalidateApplication(sessionID: focusApp)
        let remaining = try fixture.drain(after: &after)
        let focusCleanup = remaining.filter { $0.kind == .focus }
        XCTAssertEqual(remaining.filter { $0.kind == .resize }.count, 256)
        XCTAssertEqual(focusCleanup.count, 1)
        XCTAssertEqual(focusCleanup.first?.focused, false)
        XCTAssertEqual(focusCleanup.first?.focusLeaseID, lease.uuidString.lowercased())
    }

    func testAnotherApplicationCannotReuseAnOwnedFocusLease() throws {
        let fixture = try Fixture()
        let first = try fixture.application()
        let second = try fixture.application()
        let lease = UUID()
        try fixture.focus(app: first, sequence: 1, lease: lease, active: true)
        var after: UInt64 = 0
        XCTAssertNotNil(try fixture.next(after: &after))

        XCTAssertThrowsError(try fixture.focus(app: second, sequence: 1, lease: lease, active: true))
        XCTAssertNil(try fixture.next(after: &after))
        fixture.broker.invalidateApplication(sessionID: first)
        XCTAssertEqual(try fixture.drain(after: &after).first?.focusLeaseID, lease.uuidString.lowercased())
    }

    func testOldApplicationFocusLossCannotRevokeReplacementFocusOwner() throws {
        let fixture = try Fixture()
        let first = try fixture.application()
        let second = try fixture.application()
        let oldLease = UUID()
        let currentLease = UUID()
        var after: UInt64 = 0
        try fixture.focus(app: first, sequence: 1, lease: oldLease, active: true)
        XCTAssertNotNil(try fixture.next(after: &after))
        try fixture.focus(app: second, sequence: 1, lease: currentLease, active: true)
        XCTAssertNotNil(try fixture.next(after: &after))
        try fixture.focus(app: first, sequence: 2, lease: oldLease, active: false)
        XCTAssertTrue(try fixture.drain(after: &after).isEmpty)
        fixture.broker.invalidateApplication(sessionID: first)
        XCTAssertTrue(try fixture.drain(after: &after).isEmpty)

        fixture.broker.invalidateApplication(sessionID: second)
        let cleanup = try fixture.drain(after: &after)
        XCTAssertEqual(cleanup.count, 1)
        XCTAssertEqual(cleanup.first?.focused, false)
        XCTAssertEqual(cleanup.first?.focusLeaseID, currentLease.uuidString.lowercased())
    }

    func testRevokedApplicationConnectionCannotAcquireANewFrameLease() throws {
        let fixture = try Fixture()
        let app = try fixture.application()
        let lifetime = DoryVMDisplayConnectionLifetime()
        lifetime.revoke()
        fixture.broker.invalidateApplication(sessionID: app)

        XCTAssertThrowsError(try fixture.broker.nextFrame(
            machineID: "ubuntu", scanoutID: 0, afterSequence: 0,
            applicationSessionID: app, connectionLifetime: lifetime
        ))
        let liveApp = try fixture.application()
        XCTAssertNotNil(try fixture.broker.nextFrame(
            machineID: "ubuntu", scanoutID: 0, afterSequence: 0,
            applicationSessionID: liveApp, connectionLifetime: DoryVMDisplayConnectionLifetime()
        ))
    }

    func testRevokedRunnerConnectionCannotRepublishAfterRetirement() throws {
        let fixture = try Fixture()
        let lifetime = DoryVMDisplayConnectionLifetime()
        lifetime.revoke()
        fixture.broker.invalidateRunner(sessionID: fixture.runner)
        let completion = FrameCompletion()
        try fixture.publish(connectionLifetime: lifetime, reply: completion.record)

        XCTAssertEqual(completion.values.count, 1)
        XCTAssertEqual(completion.values.first?.presented, false)
        XCTAssertFalse(completion.values.first?.detail.isEmpty ?? true)
        let app = try fixture.application()
        XCTAssertThrowsError(try fixture.send(app: app, sequence: 1, events: [key(30, 1)])) {
            XCTAssertEqual($0 as? DoryVMDisplayRelayError, .unknownMachine)
        }
    }

    func testOldApplicationDisconnectCannotReleaseReplacementRunnerInput() throws {
        let fixture = try Fixture()
        let oldApp = try fixture.application()
        try fixture.send(app: oldApp, sequence: 1, events: [key(30, 1)])
        var after: UInt64 = 0
        XCTAssertNotNil(try fixture.next(after: &after))
        fixture.broker.invalidateRunner(sessionID: fixture.runner)

        try fixture.replaceRunner()
        let newApp = try fixture.application()
        try fixture.send(app: newApp, sequence: 1, events: [key(30, 1)])
        after = 0
        XCTAssertNotNil(try fixture.next(after: &after))
        fixture.broker.invalidateApplication(sessionID: oldApp)
        XCTAssertNil(try fixture.next(after: &after))

        fixture.broker.invalidateApplication(sessionID: newApp)
        let cleanup = try fixture.drain(after: &after)
        XCTAssertEqual(cleanup.first?.operationID, fixture.operationText)
        XCTAssertEqual(cleanup.flatMap(\.inputEvents), [key(30, 0)])
    }

    func testOldRunnerHistoryCannotPruneFreshReplacementCommandStatus() throws {
        let fixture = try Fixture()
        let oldApp = try fixture.application()
        var after: UInt64 = 0
        for sequence in 1...900 {
            try fixture.resize(app: oldApp, sequence: UInt64(sequence))
            XCTAssertNotNil(try fixture.next(after: &after))
        }
        fixture.broker.invalidateRunner(sessionID: fixture.runner)
        try fixture.replaceRunner()

        let newApp = try fixture.application()
        after = 0
        try fixture.resize(app: newApp, sequence: 1)
        XCTAssertNotNil(try fixture.next(after: &after))
        try fixture.resize(app: newApp, sequence: 2)
        let firstStatus = fixture.broker.commandStatus(
            machineID: "ubuntu", operationID: fixture.operationText,
            sequence: 1, applicationSessionID: newApp
        )
        XCTAssertTrue(firstStatus.known)
        XCTAssertTrue(firstStatus.applied)
    }

    func testLateOlderTopologyAcknowledgementCannotRetireCurrentScanout() throws {
        let fixture = try Fixture()
        let app = try fixture.application()
        var after: UInt64 = 0
        try fixture.topology(app: app, sequence: 1, displayCount: 1)
        let oldTopology = try XCTUnwrap(fixture.next(after: &after, acknowledge: false))
        try fixture.topology(app: app, sequence: 2, displayCount: 2)
        XCTAssertNotNil(try fixture.next(after: &after))

        try fixture.acknowledge(oldTopology)
        try fixture.publish(scanoutID: 1)
        XCTAssertNotNil(try fixture.broker.nextFrame(
            machineID: "ubuntu", scanoutID: 1, afterSequence: 0,
            applicationSessionID: app
        ))
    }

    private func key(_ code: UInt16, _ value: Int32) -> DoryVMDisplayInputEvent {
        .init(type: 1, code: code, value: value)
    }

    private final class FrameCompletion {
        struct Value {
            let presented: Bool
            let detail: String
        }
        private let lock = NSLock()
        private var storage: [Value] = []
        var values: [Value] { lock.withLock { storage } }

        func record(presented: Bool, completionID: UInt64, detail: String) {
            lock.withLock { storage.append(.init(presented: presented, detail: detail)) }
        }
    }

    private final class Fixture {
        let broker = DoryVMDisplayBroker { machine, _, pid in machine == "ubuntu" && pid == 42 }
        private(set) var runner = UUID()
        private(set) var operation = UUID()
        var operationText: String { operation.uuidString.lowercased() }

        init() throws { try publish() }

        func application() throws -> UUID {
            let session = UUID()
            try broker.registerApplication(sessionID: session)
            return session
        }

        func send(
            app: UUID, sequence: UInt64,
            endpoint: DoryVMDisplayInputEndpoint = .keyboard,
            events: [DoryVMDisplayInputEvent]
        ) throws {
            try broker.send(
                commandData: DoryVMDisplayCommandCodec.encode(.input(
                    machineID: "ubuntu", operationID: operation,
                    sequence: sequence, endpoint: endpoint, events: events
                )),
                applicationSessionID: app
            )
        }

        func resize(app: UUID, sequence: UInt64) throws {
            try broker.send(
                commandData: DoryVMDisplayCommandCodec.encode(.resize(
                    machineID: "ubuntu", operationID: operation, sequence: sequence,
                    scanoutID: 0, width: 1_280, height: 800,
                    physicalWidthMillimeters: 203, physicalHeightMillimeters: 127
                )),
                applicationSessionID: app
            )
        }

        func focus(
            app: UUID, sequence: UInt64, lease: UUID, active: Bool,
            expiresAtUptimeNanoseconds: UInt64? = nil
        ) throws {
            try broker.send(
                commandData: DoryVMDisplayCommandCodec.encode(.focus(
                    machineID: "ubuntu", operationID: operation, sequence: sequence,
                    leaseID: lease, active: active,
                    expiresAtUptimeNanoseconds: expiresAtUptimeNanoseconds
                )),
                applicationSessionID: app
            )
        }

        func topology(app: UUID, sequence: UInt64, displayCount: Int) throws {
            try broker.send(
                commandData: DoryVMDisplayCommandCodec.encode(.topology(
                    machineID: "ubuntu", operationID: operation, sequence: sequence,
                    displays: Array(repeating: .init(
                        width: 1_280, height: 800,
                        physicalWidthMillimeters: 203, physicalHeightMillimeters: 127
                    ), count: displayCount)
                )),
                applicationSessionID: app
            )
        }

        func next(after: inout UInt64, acknowledge: Bool = true) throws -> DoryVMDisplayCommand? {
            guard let data = try broker.nextCommand(
                machineID: "ubuntu", operationID: operationText,
                afterSequence: after, runnerSessionID: runner, processIdentifier: 42
            ) else { return nil }
            let command = try DoryVMDisplayCommandCodec.decode(data)
            XCTAssertGreaterThan(command.sequence, after)
            after = command.sequence
            if acknowledge {
                try self.acknowledge(command)
            }
            return command
        }

        func acknowledge(_ command: DoryVMDisplayCommand) throws {
            try broker.acknowledgeCommand(
                machineID: "ubuntu", operationID: operationText,
                sequence: command.sequence, applied: true, detail: "",
                runnerSessionID: runner, processIdentifier: 42
            )
        }

        func acknowledgeIfStillKnown(_ command: DoryVMDisplayCommand) throws {
            do {
                try acknowledge(command)
            } catch let error as DoryVMDisplayRelayError where error == .unknownCommand {
                // A fully superseded cleanup may retire its broker record. Whether that old
                // callback is rejected or harmlessly accepted, it cannot affect a new press.
            }
        }

        func drain(after: inout UInt64) throws -> [DoryVMDisplayCommand] {
            var commands: [DoryVMDisplayCommand] = []
            for _ in 0..<600 {
                guard let command = try next(after: &after) else { return commands }
                commands.append(command)
            }
            XCTFail("Display command drain exceeded its fixed queue bound")
            return commands
        }

        func replaceRunner() throws {
            runner = UUID()
            operation = UUID()
            try publish()
        }

        func publish(
            scanoutID: UInt32 = 0,
            connectionLifetime: DoryVMDisplayConnectionLifetime? = nil,
            reply: @escaping (Bool, UInt64, String) -> Void = { _, _, _ in }
        ) throws {
            let lease = try DoryVMDisplayCPUFrameLease(
                leaseID: UUID(), releaseToken: UUID(), resourceID: 1,
                resourceGeneration: 1, cpuEpoch: 1,
                pixelFormat: DoryRendererScanoutPixelFormat.bgra8Unorm.rawValue,
                yOriginTop: true, width: 64, height: 64, stride: 256,
                declaredFileSize: 16_384
            )
            let frame = try DoryVMDisplayFrame(
                machineID: "ubuntu", operationID: operation, scanoutID: scanoutID,
                sequence: 1, displayResourceGeneration: 1, transport: .cpuCopy,
                leasePayload: DoryVMDisplayCPUFrameLeaseCodec.encode(lease),
                sourceRect: .init(x: 0, y: 0, width: 64, height: 64),
                dirtyRect: .init(x: 0, y: 0, width: 64, height: 64)
            )
            broker.publish(
                frameData: try DoryVMDisplayFrameCodec.encode(frame),
                descriptors: [Pipe().fileHandleForReading], sharedTextureHandle: nil,
                runnerSessionID: runner, processIdentifier: 42,
                connectionLifetime: connectionLifetime, reply: reply
            )
        }
    }
}
