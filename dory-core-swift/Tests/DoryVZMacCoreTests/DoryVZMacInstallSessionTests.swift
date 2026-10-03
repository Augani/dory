import Foundation
import XCTest
@testable import DoryVZMacCore

final class DoryVZMacInstallSessionTests: XCTestCase {
    @MainActor
    func testSuccessfulSynchronousCallbackSettlesOnce() async throws {
        let fixture = InstallSessionFixture()
        fixture.immediateResult = .success(())
        let session = fixture.session()
        try await session.run()
        XCTAssertEqual(fixture.events, ["start", "start-returned"])
        XCTAssertFalse(session.isInstalling)
        session.cancel()
        XCTAssertEqual(fixture.cancelCount, 0)
    }

    @MainActor
    func testInstallerFailureIsPreserved() async {
        let fixture = InstallSessionFixture()
        fixture.immediateResult = .failure(InstallFixtureError.failed)
        do { try await fixture.session().run(); XCTFail("expected installer failure") }
        catch { XCTAssertEqual(error as? InstallFixtureError, .failed) }
    }

    @MainActor
    func testPrecancelledTaskNeverStartsOrCancelsAppleProgress() async {
        let fixture = InstallSessionFixture()
        let session = fixture.session()
        let task = Task { @MainActor in try await session.run() }
        task.cancel()
        await assertCancellation(task)
        XCTAssertEqual(fixture.startCount, 0)
        XCTAssertEqual(fixture.cancelCount, 0)
    }

    @MainActor
    func testExplicitCancellationBeforeRunNeverTouchesAppleProgress() async {
        let fixture = InstallSessionFixture()
        let session = fixture.session()
        session.cancel()
        do { try await session.run(); XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.startCount, 0)
        XCTAssertEqual(fixture.cancelCount, 0)
    }

    @MainActor
    func testCancellationWaitsForInstallerCleanupAndRejectsLateSuccess() async throws {
        let fixture = InstallSessionFixture()
        let session = fixture.session()
        let task = Task { @MainActor in
            defer { fixture.taskFinished = true }
            try await session.run()
        }
        try await waitUntil { fixture.startCount == 1 }
        task.cancel()
        try await waitUntil { fixture.cancelCount == 1 }
        session.cancel()
        XCTAssertEqual(fixture.cancelCount, 1)
        XCTAssertFalse(fixture.taskFinished, "must join Apple's callback before releasing VM ownership")
        XCTAssertTrue(session.isInstalling)
        fixture.complete(.success(()))
        await assertCancellation(task)
        XCTAssertTrue(fixture.taskFinished)
        XCTAssertFalse(session.isInstalling)
    }

    @MainActor
    func testCancellationRetainsMeaningWhenAppleReportsAnotherFailure() async throws {
        let fixture = InstallSessionFixture()
        let session = fixture.session()
        let task = Task { @MainActor in try await session.run() }
        try await waitUntil { fixture.startCount == 1 }
        task.cancel()
        try await waitUntil { fixture.cancelCount == 1 }
        fixture.complete(.failure(InstallFixtureError.failed))
        await assertCancellation(task)
    }

    @MainActor
    func testProgressJournalFailureCancelsAndPreservesItsCause() async throws {
        let fixture = InstallSessionFixture()
        let session = fixture.session()
        let task = Task { @MainActor in try await session.run() }
        try await waitUntil { fixture.startCount == 1 }
        session.cancel(error: InstallFixtureError.diskFull)
        session.cancel(error: InstallFixtureError.failed)
        XCTAssertEqual(fixture.cancelCount, 1)
        fixture.complete(.success(()))
        do { try await task.value; XCTFail("expected journal failure, not late success") }
        catch { XCTAssertEqual(error as? InstallFixtureError, .diskFull) }
    }

    @MainActor
    func testReentrantCancellationIsSentOnlyAfterStartReturns() async throws {
        let fixture = InstallSessionFixture()
        let session = fixture.session()
        fixture.onStart = { session.cancel() }
        let task = Task { @MainActor in try await session.run() }
        try await waitUntil { fixture.cancelCount == 1 }
        XCTAssertEqual(fixture.events, ["start", "start-returned", "cancel"])
        fixture.complete(.success(()))
        await assertCancellation(task)
    }

    @MainActor
    func testDuplicateCallbacksCannotResumeTwiceOrOverwriteSuccess() async throws {
        let fixture = InstallSessionFixture()
        let session = fixture.session()
        let task = Task { @MainActor in try await session.run() }
        try await waitUntil { fixture.startCount == 1 }
        fixture.complete(.success(()))
        fixture.complete(.failure(InstallFixtureError.failed))
        try await task.value
        await Task.yield()
        XCTAssertFalse(session.isInstalling)
        XCTAssertEqual(fixture.cancelCount, 0)
    }

    @MainActor
    func testCallbackFromAnotherQueueHopsToVMActor() async throws {
        let fixture = InstallSessionFixture()
        let session = fixture.session()
        let task = Task { @MainActor in try await session.run() }
        try await waitUntil { fixture.startCount == 1 }
        let completion = try XCTUnwrap(fixture.completion)
        DispatchQueue.global().async { completion(.success(())) }
        try await task.value
        XCTAssertFalse(session.isInstalling)
    }

    @MainActor
    func testCompletedSessionCannotStartTheSameInstallerAgain() async throws {
        let fixture = InstallSessionFixture()
        fixture.immediateResult = .success(())
        let session = fixture.session()
        try await session.run()
        do { try await session.run(); XCTFail("Apple installers are single-use") }
        catch { XCTAssertTrue(error is DoryVZMacInstallJournalError) }
        XCTAssertEqual(fixture.startCount, 1)
    }

    @MainActor
    func testConcurrentRunIsRejectedWithoutReplacingOriginalContinuation() async throws {
        let fixture = InstallSessionFixture()
        let session = fixture.session()
        let first = Task { @MainActor in try await session.run() }
        try await waitUntil { fixture.startCount == 1 }
        do { try await session.run(); XCTFail("expected concurrent install rejection") }
        catch { XCTAssertTrue(error is DoryVZMacInstallJournalError) }
        fixture.complete(.success(()))
        try await first.value
        XCTAssertEqual(fixture.startCount, 1)
    }

    @MainActor
    func testTaskCancellationFencesSuccessEvenWhenCallbackWasQueuedFirst() async throws {
        let fixture = InstallSessionFixture()
        let session = fixture.session()
        let task = Task { @MainActor in try await session.run() }
        try await waitUntil { fixture.startCount == 1 }
        fixture.complete(.success(()))
        task.cancel()
        await assertCancellation(task)
        XCTAssertLessThanOrEqual(fixture.cancelCount, 1)
        XCTAssertFalse(session.isInstalling)
    }

    @MainActor
    func testCancellationHookMaySynchronouslyCompleteWithoutReentryOrEarlyRelease() async throws {
        let fixture = InstallSessionFixture()
        let session = fixture.session()
        fixture.onCancel = { fixture.complete(.failure(InstallFixtureError.failed)) }
        let task = Task { @MainActor in try await session.run() }
        try await waitUntil { fixture.startCount == 1 }
        session.cancel()
        await assertCancellation(task)
        XCTAssertEqual(fixture.cancelCount, 1)
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
        guard predicate() else { throw InstallFixtureError.timedOut }
    }

    @MainActor
    private func assertCancellation(_ task: Task<Void, Error>) async {
        do { try await task.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "received \(error)") }
    }
}

private enum InstallFixtureError: Error { case failed, diskFull, timedOut }

@MainActor
private final class InstallSessionFixture {
    var completion: DoryVZMacInstallSession.Completion?
    var immediateResult: Result<Void, Error>?
    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?
    var events: [String] = []
    var startCount = 0
    var cancelCount = 0
    var taskFinished = false

    func session() -> DoryVZMacInstallSession {
        DoryVZMacInstallSession { completion in
            self.startCount += 1
            self.events.append("start")
            self.completion = completion
            let onStart = self.onStart
            self.onStart = nil
            onStart?()
            if let immediateResult = self.immediateResult { completion(immediateResult) }
            self.events.append("start-returned")
        } cancel: {
            self.cancelCount += 1
            self.events.append("cancel")
            let onCancel = self.onCancel
            self.onCancel = nil
            onCancel?()
        }
    }

    func complete(_ result: Result<Void, Error>) { completion?(result) }
}
