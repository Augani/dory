import Darwin
import Foundation
import XCTest
@testable import DorydKit

final class DoryApplicationProcessMonitorTests: XCTestCase {
  func testInvalidPIDIsRejectedBeforeKernelRegistration() {
    for pid: pid_t in [.min, -1, 0, 1] {
      XCTAssertThrowsError(try DoryApplicationProcessMonitor(pid: pid)) {
        guard case .invalidProcessIdentifier = $0 as? DoryApplicationProcessLaunchError else {
          return XCTFail("invalid PID was not rejected: \($0)")
        }
      }
    }
  }

  func testOneShotExitProofAndStatusAreReplayedToEveryLaterWaiter() throws {
    let calls = MonitorCalls()
    let pid = getpid()
    let monitor = try DoryApplicationProcessMonitor(pid: pid, eventWaiter: { _, _ in
      calls.record()
      return monitorExit(pid: pid, status: 7 << 8)
    })
    let expected = HvProcessTermination(status: 7, wasUncaughtSignal: false)
    XCTAssertEqual(monitor.waitForTermination(timeout: 1), expected)
    XCTAssertEqual(monitor.waitForTermination(), expected)
    XCTAssertEqual(monitor.waitForTermination(timeout: 0), expected)
    XCTAssertEqual(monitor.waitForTermination(timeout: .nan), expected)
    XCTAssertEqual(calls.count, 1)
  }

  func testIndependentTerminationPreservesAlreadyQueuedKnownExitStatus() throws {
    let calls = MonitorCalls()
    let pid = getpid()
    let monitor = try DoryApplicationProcessMonitor(pid: pid,
      terminationObservedAfterRegistration: { true }, eventWaiter: { _, timeout in
        calls.record(remaining: timeout)
        return monitorExit(pid: pid, status: 7 << 8)
      })
    let expected = HvProcessTermination(status: 7, wasUncaughtSignal: false)
    XCTAssertEqual(monitor.waitForTermination(timeout: 0), expected)
    XCTAssertEqual(monitor.waitForTermination(), expected)
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.remaining, [0])
  }

  func testConcurrentWaitersShareExactlyOneKernelObservation() throws {
    let calls = MonitorCalls()
    let values = MonitorResults()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let pid = getpid()
    let monitor = try DoryApplicationProcessMonitor(pid: pid, eventWaiter: { _, _ in
      calls.record()
      entered.signal()
      _ = release.wait(timeout: .now() + 2)
      return monitorExit(pid: pid, status: SIGTERM)
    })
    defer { release.signal() }
    let waiters = DispatchGroup()
    for _ in 0..<8 {
      waiters.enter()
      DispatchQueue.global().async {
        values.append(monitor.waitForTermination(timeout: 2))
        waiters.leave()
      }
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(calls.count, 1)
    release.signal()
    XCTAssertEqual(waiters.wait(timeout: .now() + 2), .success)
    let expected = HvProcessTermination(status: SIGTERM, wasUncaughtSignal: true)
    XCTAssertEqual(values.snapshot.count, 8)
    XCTAssertTrue(values.snapshot.allSatisfy { $0 == expected })
    XCTAssertEqual(calls.count, 1)
  }

  func testJoiningWaiterKeepsItsOwnDeadlineWithoutCancellingObservation() throws {
    let calls = MonitorCalls()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let ownerFinished = DispatchSemaphore(value: 0)
    let pid = getpid()
    let monitor = try DoryApplicationProcessMonitor(pid: pid, eventWaiter: { _, _ in
      calls.record()
      entered.signal()
      _ = release.wait(timeout: .now() + 2)
      return monitorExit(pid: pid, status: 0)
    })
    defer { release.signal() }
    DispatchQueue.global().async {
      _ = monitor.waitForTermination()
      ownerFinished.signal()
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
    let started = ProcessInfo.processInfo.systemUptime
    XCTAssertNil(monitor.waitForTermination(timeout: 0.02))
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.5)
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(ownerFinished.wait(timeout: .now()), .timedOut)
    release.signal()
    XCTAssertEqual(ownerFinished.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(monitor.waitForTermination(timeout: 0)?.status, 0)
  }

  func testExpiredObservationDoesNotConsumeLaterProof() throws {
    let calls = MonitorCalls()
    let pid = getpid()
    let monitor = try DoryApplicationProcessMonitor(pid: pid, eventWaiter: { _, _ in
      calls.record()
      return calls.count == 1 ? .timedOut : monitorExit(pid: pid, status: 3 << 8)
    })
    XCTAssertNil(monitor.waitForTermination(timeout: 0.01))
    XCTAssertEqual(monitor.waitForTermination(timeout: 1)?.status, 3)
    XCTAssertEqual(monitor.waitForTermination(timeout: 0)?.status, 3)
    XCTAssertEqual(calls.count, 2)
  }

  func testInterruptRetriesShareOriginalMonotonicDeadline() throws {
    let calls = MonitorCalls()
    let monitor = try DoryApplicationProcessMonitor(pid: getpid(), eventWaiter: { _, remaining in
      calls.record(remaining: remaining)
      Thread.sleep(forTimeInterval: min(0.005, max(0, remaining ?? 0)))
      return .interrupted
    })
    let started = ProcessInfo.processInfo.systemUptime
    XCTAssertNil(monitor.waitForTermination(timeout: 0.03))
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.5)
    let limits = calls.remaining
    XCTAssertGreaterThan(limits.count, 1)
    XCTAssertTrue(zip(limits, limits.dropFirst()).allSatisfy { $0.0 >= $0.1 })
  }

  func testErrorAndWrongIdentityEventsNeverBecomeExitProof() throws {
    let pid = getpid()
    let observations: [DoryApplicationProcessMonitor.Observation] = [
      .event(identifier: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ERROR),
        filterFlags: NOTE_EXIT, data: Int(EIO)),
      .event(identifier: UInt(pid) + 1, filter: Int16(EVFILT_PROC), flags: 0,
        filterFlags: NOTE_EXIT, data: 0),
      .event(identifier: UInt(pid), filter: Int16(EVFILT_READ), flags: 0,
        filterFlags: NOTE_EXIT, data: 0),
      .event(identifier: UInt(pid), filter: Int16(EVFILT_PROC), flags: 0,
        filterFlags: 0, data: 0),
      .failed,
    ]
    for observation in observations {
      let calls = MonitorCalls()
      let monitor = try DoryApplicationProcessMonitor(pid: pid, eventWaiter: { _, _ in
        calls.record()
        return observation
      })
      XCTAssertNil(monitor.waitForTermination(timeout: 0.01))
      XCTAssertNil(monitor.waitForTermination(timeout: 0))
      XCTAssertEqual(calls.count, 1)
    }
  }

  func testIndependentExactTerminationAfterMonitorErrorDoesNotInventStatus() throws {
    let observed = MonitorTerminationFlag()
    let pid = getpid()
    let monitor = try DoryApplicationProcessMonitor(pid: pid,
      terminationObservedAfterRegistration: { observed.value }, eventWaiter: { _, _ in
        observed.set()
        return .event(identifier: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ERROR),
          filterFlags: NOTE_EXIT, data: Int(EIO))
      })
    let expected = HvProcessTermination(status: 0, wasUncaughtSignal: false, statusIsKnown: false)
    XCTAssertEqual(monitor.waitForTermination(timeout: 1), expected)
    XCTAssertEqual(monitor.waitForTermination(timeout: 0), expected)
  }

  func testFailedOneShotObservationKeepsExactTerminationFallbackAcrossWaiters() throws {
    let calls = MonitorCalls()
    let observed = MonitorTerminationFlag()
    let pid = getpid()
    let monitor = try DoryApplicationProcessMonitor(pid: pid,
      terminationObservedAfterRegistration: { observed.value }, eventWaiter: { _, _ in
        calls.record()
        return .event(identifier: UInt(pid) + 1, filter: Int16(EVFILT_PROC), flags: 0,
          filterFlags: NOTE_EXIT, data: 0)
      })
    XCTAssertNil(monitor.waitForTermination(timeout: 0.01))
    XCTAssertNil(monitor.waitForTermination(timeout: 0.01))
    XCTAssertEqual(calls.count, 1)
    observed.set()
    let expected = HvProcessTermination(status: 0, wasUncaughtSignal: false, statusIsKnown: false)
    XCTAssertEqual(monitor.waitForTermination(), expected)
    XCTAssertEqual(monitor.waitForTermination(timeout: 0), expected)
    XCTAssertEqual(calls.count, 1)
  }

  func testExactExitWithoutStatusIsReplayedWithoutInventingStatus() throws {
    let calls = MonitorCalls()
    let pid = getpid()
    let monitor = try DoryApplicationProcessMonitor(pid: pid, eventWaiter: { _, _ in
      calls.record()
      return .event(identifier: UInt(pid), filter: Int16(EVFILT_PROC), flags: 0,
        filterFlags: NOTE_EXIT, data: Int(EIO))
    })
    let expected = HvProcessTermination(status: 0, wasUncaughtSignal: false, statusIsKnown: false)
    XCTAssertEqual(monitor.waitForTermination(timeout: 1), expected)
    XCTAssertEqual(monitor.waitForTermination(), expected)
    XCTAssertEqual(calls.count, 1)
  }

  func testInvalidWaitDurationsDoNotEnterKernelOrTrap() throws {
    let calls = MonitorCalls()
    let monitor = try DoryApplicationProcessMonitor(pid: getpid(), eventWaiter: { _, _ in
      calls.record()
      return .timedOut
    })
    for duration: TimeInterval in [.nan, .infinity, -.infinity, -1, .greatestFiniteMagnitude] {
      XCTAssertNil(monitor.waitForTermination(timeout: duration))
    }
    XCTAssertEqual(calls.count, 0)
  }

  func testRealOwnedChildExitStatusIsRetainedAfterKnoteConsumption() throws {
    let child = Process()
    let input = Pipe()
    let joined = DispatchGroup()
    joined.enter()
    child.executableURL = URL(fileURLWithPath: "/bin/sh")
    child.arguments = ["-c", "read line; exit 7"]
    child.standardInput = input
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    child.terminationHandler = { _ in joined.leave() }
    try child.run()
    defer {
      try? input.fileHandleForWriting.close()
      if joined.wait(timeout: .now() + 2) != .success, child.isRunning {
        child.terminate()
        _ = joined.wait(timeout: .now() + 2)
      }
    }
    let monitor = try DoryApplicationProcessMonitor(pid: child.processIdentifier)
    try input.fileHandleForWriting.close()
    let expected = HvProcessTermination(status: 7, wasUncaughtSignal: false)
    XCTAssertEqual(monitor.waitForTermination(timeout: 2), expected)
    XCTAssertEqual(joined.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(monitor.waitForTermination(timeout: 0), expected)
    XCTAssertEqual(monitor.waitForTermination(), expected)
  }
}

private func monitorExit(pid: pid_t, status: Int32) -> DoryApplicationProcessMonitor.Observation {
  .event(identifier: UInt(pid), filter: Int16(EVFILT_PROC), flags: 0,
    filterFlags: NOTE_EXIT | UInt32(bitPattern: NOTE_EXITSTATUS), data: Int(status))
}

private final class MonitorCalls: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  private var deadlines: [TimeInterval] = []
  var count: Int { lock.withLock { calls } }
  var remaining: [TimeInterval] { lock.withLock { deadlines } }
  func record(remaining: TimeInterval? = nil) {
    lock.withLock {
      calls += 1
      if let remaining { deadlines.append(remaining) }
    }
  }
}

private final class MonitorResults: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [HvProcessTermination?] = []
  var snapshot: [HvProcessTermination?] { lock.withLock { values } }
  func append(_ value: HvProcessTermination?) { lock.withLock { values.append(value) } }
}

private final class MonitorTerminationFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var observed = false
  var value: Bool { lock.withLock { observed } }
  func set() { lock.withLock { observed = true } }
}
