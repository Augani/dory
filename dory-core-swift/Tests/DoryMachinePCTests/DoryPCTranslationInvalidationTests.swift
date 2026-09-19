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
    #expect(machine.pagingUnits[1].diagnostics.globalInvalidations == remoteBefore.globalInvalidations)
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
