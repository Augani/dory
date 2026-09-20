import DoryDBTX86
import Foundation
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCTranslationInvalidationTests {
  @Test func publicationWaitsForEveryProcessorAcknowledgement() throws {
    let coordinator = DoryPCTranslationInvalidationCoordinator(processorCount: 2)
    let publication = coordinator.publish(linearAddress: 0x1234)
    #expect(coordinator.pending(for: 0) == publication)
    #expect(coordinator.pending(for: 1) == publication)

    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      coordinator.wait(for: publication)
      finished.signal()
    }
    #expect(finished.wait(timeout: .now() + .milliseconds(25)) == .timedOut)
    coordinator.acknowledge(processor: 0, generation: publication.generation)
    #expect(finished.wait(timeout: .now() + .milliseconds(25)) == .timedOut)
    coordinator.acknowledge(processor: 1, generation: publication.generation)
    #expect(finished.wait(timeout: .now() + 2) == .success)
    #expect(coordinator.pending(for: 0) == nil)
    #expect(coordinator.pending(for: 1) == nil)
    #expect(
      coordinator.diagnostics.requiredGenerations
        == coordinator.diagnostics.acknowledgedGenerations)
  }

  @Test func publisherMustDrainOrWaitBehindTheExactInflightPublication() {
    let coordinator = DoryPCTranslationInvalidationCoordinator(processorCount: 2)
    let first: DoryPCTranslationInvalidationCoordinator.Publication
    switch coordinator.attemptPublication(linearAddress: 0x1000, forProcessor: 0) {
    case .published(let publication):
      first = publication
    case .drain, .wait:
      Issue.record("the first request did not publish")
      return
    }

    #expect(
      coordinator.attemptPublication(linearAddress: 0x2000, forProcessor: 1)
        == .drain(first))
    coordinator.acknowledge(processor: 1, generation: first.generation)
    #expect(
      coordinator.attemptPublication(linearAddress: 0x2000, forProcessor: 1)
        == .wait(first))

    coordinator.acknowledge(processor: 0, generation: first.generation)
    switch coordinator.attemptPublication(linearAddress: 0x2000, forProcessor: 1) {
    case .published(let second):
      #expect(second.generation == first.generation + 1)
      #expect(second.linearAddress == 0x2000)
    case .drain, .wait:
      Issue.record("the second request did not publish after the first completed")
    }
  }

  @Test func concurrentPublishersDrainEachOtherBeforeWaiting() throws {
    let coordinator = DoryPCTranslationInvalidationCoordinator(processorCount: 2)
    let start = DispatchSemaphore(value: 0)
    let ready = DispatchGroup()
    let finishedPublishers = LockedCount()
    let group = DispatchGroup()
    var threads: [Thread] = []

    for processor in 0..<2 {
      ready.enter()
      group.enter()
      let thread = Thread {
        ready.leave()
        start.wait()
        var ownPublicationFinished = false
        while true {
          if !ownPublicationFinished {
            switch coordinator.attemptPublication(
              linearAddress: UInt64(0x1000 * (processor + 1)),
              forProcessor: processor
            ) {
            case .published(let publication):
              coordinator.acknowledge(processor: processor, generation: publication.generation)
              coordinator.wait(for: publication)
              ownPublicationFinished = true
              finishedPublishers.increment()
            case .drain(let publication):
              coordinator.acknowledge(processor: processor, generation: publication.generation)
            case .wait(let publication):
              coordinator.wait(for: publication)
            }
            continue
          }

          if let publication = coordinator.pending(for: processor) {
            coordinator.acknowledge(processor: processor, generation: publication.generation)
          } else if finishedPublishers.load() == 2 {
            break
          } else {
            Thread.sleep(forTimeInterval: 0.0001)
          }
        }
        group.leave()
      }
      thread.name = "dev.dory.tests.translation-publisher.\(processor)"
      threads.append(thread)
    }

    for thread in threads { thread.start() }
    try #require(ready.wait(timeout: .now() + 2) == .success)
    start.signal()
    start.signal()
    #expect(group.wait(timeout: .now() + 5) == .success)
    #expect(coordinator.diagnostics.requiredGenerations == [2, 2])
    #expect(coordinator.diagnostics.acknowledgedGenerations == [2, 2])
  }

  @Test func targetedInvalidationIsPublishedAndAcknowledgedByRemoteVCPU() throws {
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      processorCount: 2,
      executionTier: .baselineJIT,
      instrumentationEnabled: true)
    let remoteBefore = machine.pagingUnits[1].diagnostics
    machine.pagingUnits[0].invalidate(linearAddress: 0x8123)

    machine.reconcileTranslationInvalidations(afterExecuting: 0)

    #expect(machine.pagingUnits[0].diagnostics.linearInvalidations == 1)
    #expect(
      machine.pagingUnits[1].diagnostics.linearInvalidations
        == remoteBefore.linearInvalidations + 1)
    #expect(
      machine.pagingUnits[1].diagnostics.globalInvalidations == remoteBefore.globalInvalidations)
    let diagnostics = machine.translationInvalidationDiagnostics
    #expect(diagnostics.generation == 1)
    #expect(diagnostics.requiredGenerations == [1, 1])
    #expect(diagnostics.acknowledgedGenerations == [1, 1])
  }

  @Test func missedLocalInvalidationsConservativelyPublishGlobalFlush() throws {
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      processorCount: 2,
      executionTier: .baselineJIT,
      instrumentationEnabled: true)
    let remoteBefore = machine.pagingUnits[1].diagnostics
    machine.pagingUnits[0].invalidate(linearAddress: 0x1000)
    machine.pagingUnits[0].invalidate(linearAddress: 0x2000)

    machine.reconcileTranslationInvalidations(afterExecuting: 0)

    #expect(
      machine.pagingUnits[1].diagnostics.globalInvalidations
        == remoteBefore.globalInvalidations + 1)
    #expect(machine.translationInvalidationDiagnostics.acknowledgedGenerations == [1, 1])
  }

  @Test func pageTableWritePublishesGlobalFlushBeforeNextDispatch() throws {
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1024 * 1024,
      processorCount: 2,
      executionTier: .baselineJIT,
      instrumentationEnabled: true)
    machine.physicalMemory.trackPageTablePage(containing: 0x1000)
    try machine.physicalMemory.write(at: 0x1000, bytes: [1])
    let before = machine.pagingUnits.map(\.diagnostics.globalInvalidations)

    machine.reconcilePendingPageTableWrites()

    #expect(machine.pagingUnits[0].diagnostics.globalInvalidations == before[0] + 1)
    #expect(machine.pagingUnits[1].diagnostics.globalInvalidations == before[1] + 1)
    #expect(machine.translationInvalidationDiagnostics.acknowledgedGenerations == [1, 1])
  }
}

private final class LockedCount: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func increment() { lock.withLock { value += 1 } }

  func load() -> Int { lock.withLock { value } }
}
