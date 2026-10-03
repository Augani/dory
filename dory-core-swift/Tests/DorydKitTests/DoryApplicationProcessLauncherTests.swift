import AppKit
import Foundation
import XCTest
@testable import DorydKit

/// These tests exercise launch ownership without asking LaunchServices to start an app. The
/// application objects below are in-memory fixtures; the injected retirer never signals a PID.
final class DoryApplicationProcessLauncherTests: XCTestCase {
  func testCancellationBeforeActorInvocationPreventsLaunch() throws {
    let request = DoryWorkspaceApplicationLauncher.Request()
    XCTAssertNil(request.cancel())
    XCTAssertFalse(request.claimInvocation())
    assertCancelled(request)
  }

  @MainActor
  func testQueuedMainActorInvocationDoesNotRunAfterCancellation() async {
    let request = DoryWorkspaceApplicationLauncher.Request()
    let observations = LauncherObservations()
    let invocation = Task { @MainActor in
      if request.claimInvocation() { observations.recordInvocation() }
    }
    XCTAssertNil(request.cancel())
    await invocation.value
    XCTAssertEqual(observations.invocationCount, 0)
    assertCancelled(request)
  }

  func testInvocationIsClaimedAtMostOnce() {
    let request = DoryWorkspaceApplicationLauncher.Request()
    XCTAssertTrue(request.claimInvocation())
    XCTAssertFalse(request.claimInvocation())
    XCTAssertNil(request.cancel())
    assertCancelled(request)
  }

  func testExpiredRequestDoesNotInvokeOrAcceptALateFailure() {
    let request = DoryWorkspaceApplicationLauncher.Request()
    assertTimedOut(request)
    XCTAssertFalse(request.claimInvocation())
    request.receive(application: nil, error: FixtureError.rejected)
    assertTimedOut(request)
  }

  func testLateApplicationIsRetiredOnceAndTimeoutRemainsTerminal() {
    let observations = LauncherObservations()
    let request = DoryWorkspaceApplicationLauncher.Request(retire: observations.retire)
    assertTimedOut(request)
    let application = DoryWorkspaceApplicationLaunch(application: LauncherFixtureApplication())
    request.receive(application: application, error: nil)
    request.receive(application: application, error: nil)
    XCTAssertEqual(observations.retirementCount, 1)
    assertTimedOut(request)
  }

  func testCancelledInFlightRequestRetiresLateApplicationOnce() {
    let observations = LauncherObservations()
    let request = DoryWorkspaceApplicationLauncher.Request(retire: observations.retire)
    XCTAssertTrue(request.claimInvocation())
    XCTAssertNil(request.cancel())
    let application = DoryWorkspaceApplicationLaunch(application: LauncherFixtureApplication())
    request.receive(application: application, error: nil)
    request.receive(application: application, error: FixtureError.rejected)
    XCTAssertEqual(observations.retirementCount, 1)
    assertCancelled(request)
  }

  func testSuccessfulCompletionCannotBeOverwrittenOrItsHandleRetired() throws {
    let observations = LauncherObservations()
    let request = DoryWorkspaceApplicationLauncher.Request(retire: observations.retire)
    let fixture = LauncherFixtureApplication()
    let application = DoryWorkspaceApplicationLaunch(application: fixture)
    request.receive(application: application, error: nil)
    request.receive(application: nil, error: FixtureError.rejected)
    request.receive(application: application, error: nil)
    let duplicateWrapper = LauncherFixtureApplication(identity: fixture.identity)
    XCTAssertFalse(duplicateWrapper === application.application)
    request.receive(
      application: DoryWorkspaceApplicationLaunch(application: duplicateWrapper), error: nil
    )
    let received = try request.finish(timeout: 0)
    XCTAssertTrue(received.application === application.application)
    XCTAssertTrue(try request.finish(timeout: 0).application === application.application)
    XCTAssertEqual(observations.retirementCount, 0)
  }

  func testFailedHandoffKeepsAlreadyCompletedHandleWithCaller() throws {
    let observations = LauncherObservations()
    let request = DoryWorkspaceApplicationLauncher.Request(retire: observations.retire)
    let application = DoryWorkspaceApplicationLaunch(application: LauncherFixtureApplication())
    request.receive(application: application, error: nil)
    let returned = try XCTUnwrap(request.cancel())
    XCTAssertTrue(returned.application === application.application)
    XCTAssertNil(request.cancel(), "failed-handoff cleanup transfers the exact handle once")
    XCTAssertEqual(observations.retirementCount, 0)
  }

  func testApplicationReturnedAlongsideErrorIsNotLeaked() {
    let observations = LauncherObservations()
    let request = DoryWorkspaceApplicationLauncher.Request(retire: observations.retire)
    let application = DoryWorkspaceApplicationLaunch(application: LauncherFixtureApplication())
    request.receive(application: application, error: FixtureError.rejected)
    request.receive(application: application, error: nil)
    XCTAssertThrowsError(try request.finish(timeout: 0)) {
      XCTAssertEqual($0 as? FixtureError, .rejected)
    }
    XCTAssertEqual(observations.retirementCount, 1)
  }

  func testConcurrentFailedHandoffCleanupClaimsCompletedHandleOnce() {
    let observations = LauncherObservations()
    let request = DoryWorkspaceApplicationLauncher.Request(retire: observations.retire)
    request.receive(application: DoryWorkspaceApplicationLaunch(application: LauncherFixtureApplication()), error: nil)
    DispatchQueue.concurrentPerform(iterations: 32) { _ in
      if request.cancel() != nil { observations.recordInvocation() }
    }
    XCTAssertEqual(observations.invocationCount, 1)
    XCTAssertEqual(observations.retirementCount, 0)
  }

  func testEmptyCompletionIsTerminalAndCannotBeReplaced() {
    let request = DoryWorkspaceApplicationLauncher.Request()
    request.receive(application: nil, error: nil)
    request.receive(application: nil, error: FixtureError.rejected)
    XCTAssertThrowsError(try request.finish(timeout: 0)) { error in
      guard case .launchFailed = error as? DoryApplicationProcessLaunchError else {
        return XCTFail("expected the original empty-completion failure, received \(error)")
      }
    }
  }

  func testRetirementRunsOutsideCompletionLock() {
    let observations = LauncherObservations()
    let holder = LauncherRequestHolder()
    let request = DoryWorkspaceApplicationLauncher.Request { _ in
      // Re-enter the exact request. This would deadlock if late cleanup held its state lock.
      _ = holder.request?.cancel()
      observations.recordRetirement()
    }
    holder.set(request)
    XCTAssertNil(request.cancel())
    request.receive(application: DoryWorkspaceApplicationLaunch(application: LauncherFixtureApplication()), error: nil)
    XCTAssertEqual(observations.retirementCount, 1)
    holder.set(nil)
  }

  func testConcurrentCancellationAndCallbackHaveOneTerminalOutcome() {
    for _ in 0..<100 {
      let request = DoryWorkspaceApplicationLauncher.Request()
      DispatchQueue.concurrentPerform(iterations: 2) { index in
        if index == 0 { _ = request.cancel() }
        else { request.receive(application: nil, error: FixtureError.rejected) }
      }
      XCTAssertThrowsError(try request.finish(timeout: 0)) { error in
        if error is FixtureError { return }
        guard case .launchCancelled = error as? DoryApplicationProcessLaunchError else {
          return XCTFail("unexpected terminal outcome: \(error)")
        }
      }
      XCTAssertFalse(request.claimInvocation())
    }
  }

  private func assertCancelled(
    _ request: DoryWorkspaceApplicationLauncher.Request,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertThrowsError(try request.finish(timeout: 0), file: file, line: line) { error in
      guard case .launchCancelled = error as? DoryApplicationProcessLaunchError else {
        return XCTFail("expected launch cancellation, received \(error)", file: file, line: line)
      }
    }
  }

  private func assertTimedOut(
    _ request: DoryWorkspaceApplicationLauncher.Request,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertThrowsError(try request.finish(timeout: 0), file: file, line: line) { error in
      guard case .launchTimedOut = error as? DoryApplicationProcessLaunchError else {
        return XCTFail("expected launch timeout, received \(error)", file: file, line: line)
      }
    }
  }
}

private enum FixtureError: Error { case rejected }

/// Immutable overrides preserve AppKit's inherited Sendable contract without consulting an app.
private final class LauncherFixtureApplication: NSRunningApplication, @unchecked Sendable {
  let identity: UUID
  private let fixturePID: pid_t
  init(pid: pid_t = 123_456, identity: UUID = UUID()) {
    self.identity = identity
    fixturePID = pid
    super.init()
  }
  override var processIdentifier: pid_t { fixturePID }
  override var isTerminated: Bool { false }
  override var hash: Int { identity.hashValue }
  override func isEqual(_ object: Any?) -> Bool {
    (object as? LauncherFixtureApplication)?.identity == identity
  }
  override func forceTerminate() -> Bool { fatalError("must never signal a fixture PID") }
}

private final class LauncherObservations: @unchecked Sendable {
  private let lock = NSLock()
  private var invocations = 0
  private var retirements = 0
  var invocationCount: Int { lock.withLock { invocations } }
  var retirementCount: Int { lock.withLock { retirements } }
  func recordInvocation() { lock.withLock { invocations += 1 } }
  func recordRetirement() { lock.withLock { retirements += 1 } }
  func retire(_ application: DoryWorkspaceApplicationLaunch) { recordRetirement() }
}

private final class LauncherRequestHolder: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: DoryWorkspaceApplicationLauncher.Request?
  var request: DoryWorkspaceApplicationLauncher.Request? { lock.withLock { stored } }
  func set(_ request: DoryWorkspaceApplicationLauncher.Request?) { lock.withLock { stored = request } }
}
