import Foundation
import Testing
@testable import dory_hv

@Suite struct DesktopRendererWorkerRetirementTests {
  @Test func concurrentWaitersJoinOneExactRetirementOperation() async throws {
    let retirement = DesktopRendererWorkerRetirement<UInt64>()
    let barrier = RendererRetirementBarrier()
    let waiters = (0..<8).map { _ in
      Task.detached {
        let operation = retirement.start {
          await barrier.block()
          return UInt64(17)
        }
        return try await operation.value
      }
    }
    let entered = await barrier.waitUntilEntered()
    #expect(entered)
    await barrier.release()
    for waiter in waiters { #expect(try await waiter.value == 17) }
    #expect(await barrier.entryCount == 1)
  }

  @Test func cancellingOneWaiterCannotCancelForeignConsumerRetirement() async throws {
    let retirement = DesktopRendererWorkerRetirement<UInt64>()
    let barrier = RendererRetirementBarrier()
    let operation = retirement.start {
      await barrier.block()
      return UInt64(23)
    }
    let waiter = Task { try await operation.value }
    let entered = await barrier.waitUntilEntered()
    #expect(entered)
    waiter.cancel()
    #expect(!operation.isCancelled)
    await barrier.release()
    #expect(try await operation.value == 23)
    #expect(try await waiter.value == 23)
  }

  @Test func unknownRetirementCannotBeReplacedWithAnUnprovenSuccessfulRetry() async {
    let retirement = DesktopRendererWorkerRetirement<UInt64>()
    let calls = RendererRetirementCalls()
    let original = retirement.start {
      calls.increment()
      throw RetirementTestFailure.unconfirmed
    }
    await #expect(throws: RetirementTestFailure.unconfirmed) {
      _ = try await original.value
    }
    let retry = retirement.start {
      calls.increment()
      return UInt64(99)
    }
    await #expect(throws: RetirementTestFailure.unconfirmed) {
      _ = try await retry.value
    }
    #expect(calls.count == 1)
  }

  @Test func terminalStoreCannotAdmitReplacementWhileExactRetirementAwaits() async throws {
    let barrier = RendererRetirementBarrier()
    let original = RetirementTestLaunch(generation: 7) { await barrier.block() }
    let store = DoryPCRendererLaunchStore(original)
    let waiter = Task { try await store.teardownAndWait(reason: "terminal stop") }
    let entered = await barrier.waitUntilEntered()
    #expect(entered)
    #expect(store.current() == nil)
    #expect(store.replacementSource() == nil)
    let replacement = RetirementTestLaunch(generation: 8)
    #expect(!store.replace(replacement, replacing: original))
    #expect(store.retire(matchingWorkerGeneration: 7) == nil)
    await barrier.release()
    try await waiter.value
    try await store.teardownAndWait(reason: "repeated terminal stop")
    #expect(original.retirementWaitCount == 1)
    #expect(store.current() == nil)
  }

  @Test func terminalBackgroundWaitRetainsExactLaunchAfterStoreOwnerReleases() async {
    let barrier = RendererRetirementBarrier()
    var original: RetirementTestLaunch? = RetirementTestLaunch(generation: 9) {
      await barrier.block()
    }
    weak var retained = original
    var store: DoryPCRendererLaunchStore<RetirementTestLaunch>? = DoryPCRendererLaunchStore(original)
    original = nil
    store?.teardown(reason: "controller released")
    store = nil
    let entered = await barrier.waitUntilEntered()
    #expect(entered)
    #expect(retained != nil)
    await barrier.release()
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while retained != nil, ProcessInfo.processInfo.systemUptime < deadline {
      try? await Task.sleep(for: .milliseconds(1))
    }
    #expect(retained == nil)
  }

  @Test func staleReplacementIdentityAndOldTeardownCannotMutateSuccessor() {
    let original = RetirementTestLaunch(generation: 1)
    let successor = RetirementTestLaunch(generation: 2)
    let stale = RetirementTestLaunch(generation: 3)
    let store = DoryPCRendererLaunchStore(original)
    #expect(store.replace(successor, replacing: original))
    #expect(!store.replace(stale, replacing: original))
    original.teardown(reason: "late old worker completion")
    #expect(store.current() === successor)
    #expect(store.current(matchingWorkerGeneration: 1) == nil)
    #expect(successor.teardownCount == 0)
  }

  @Test func failedTerminalWaitRemainsClosedAndJoinsTheSameFailure() async {
    let original = RetirementTestLaunch(generation: 11) {
      throw RetirementTestFailure.unconfirmed
    }
    let store = DoryPCRendererLaunchStore(original)
    await #expect(throws: RetirementTestFailure.unconfirmed) {
      try await store.teardownAndWait(reason: "terminal stop")
    }
    await #expect(throws: RetirementTestFailure.unconfirmed) {
      try await store.teardownAndWait(reason: "repeated terminal stop")
    }
    #expect(original.retirementWaitCount == 1)
    #expect(!store.replace(RetirementTestLaunch(generation: 12), replacing: original))
    #expect(store.current() == nil)
  }
}

private enum RetirementTestFailure: Error, Equatable { case unconfirmed }

private actor RendererRetirementBarrier {
  private var released = false
  private var continuations = [CheckedContinuation<Void, Never>]()
  private(set) var entryCount = 0

  func block() async {
    entryCount += 1
    guard !released else { return }
    await withCheckedContinuation { continuations.append($0) }
  }

  func waitUntilEntered() async -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while entryCount == 0, ProcessInfo.processInfo.systemUptime < deadline {
      try? await Task.sleep(for: .milliseconds(1))
    }
    return entryCount > 0
  }

  func release() {
    released = true
    let pending = continuations
    continuations.removeAll()
    for continuation in pending { continuation.resume() }
  }
}

private final class RendererRetirementCalls: @unchecked Sendable {
  private let lock = NSLock()
  private var stored = 0
  var count: Int { lock.withLock { stored } }
  func increment() { lock.withLock { stored += 1 } }
}

private final class RetirementTestLaunch: DoryPCRendererGenerationLaunch, @unchecked Sendable {
  let doryPCWorkerGeneration: UInt64
  private let lock = NSLock()
  private let wait: @Sendable () async throws -> Void
  private var teardownCalls = 0
  private var waitCalls = 0

  init(generation: UInt64, wait: @escaping @Sendable () async throws -> Void = {}) {
    doryPCWorkerGeneration = generation
    self.wait = wait
  }

  var teardownCount: Int { lock.withLock { teardownCalls } }
  var retirementWaitCount: Int { lock.withLock { waitCalls } }
  func teardown(reason _: String) { lock.withLock { teardownCalls += 1 } }
  func waitForRetirement(reason _: String) async throws {
    lock.withLock { waitCalls += 1 }
    try await wait()
  }
}
