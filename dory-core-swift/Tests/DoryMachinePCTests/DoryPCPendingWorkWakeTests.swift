import Foundation
import Testing

@testable import DoryMachinePC

@Suite(.serialized) struct DoryPCPendingWorkWakeTests {
  @Test func publicationBeforeAcknowledgementPreventsTheClear() {
    let wake = DoryPCPendingWorkWake()
    let pending = LockedPendingByte()
    let observed = wake.snapshot(forProcessor: 0)

    wake.signal(forProcessor: 0) { pending.store(true) }

    #expect(
      !wake.acknowledge(forProcessor: 0, after: observed) { pending.store(false) })
    #expect(pending.load())
    #expect(wake.snapshot(forProcessor: 0) != observed)
  }

  @Test func publicationAfterAcknowledgementRestoresTheByte() {
    let wake = DoryPCPendingWorkWake()
    let pending = LockedPendingByte(initialValue: true)
    let clearEntered = DispatchSemaphore(value: 0)
    let allowClearToReturn = DispatchSemaphore(value: 0)
    let publicationReturned = DispatchSemaphore(value: 0)
    let observed = wake.snapshot(forProcessor: 0)

    DispatchQueue.global().async {
      #expect(
        wake.acknowledge(forProcessor: 0, after: observed) {
          pending.store(false)
          clearEntered.signal()
          allowClearToReturn.wait()
        })
    }
    #expect(clearEntered.wait(timeout: .now() + 2) == .success)
    DispatchQueue.global().async {
      wake.signal(forProcessor: 0) { pending.store(true) }
      publicationReturned.signal()
    }
    #expect(publicationReturned.wait(timeout: .now() + .milliseconds(25)) == .timedOut)
    allowClearToReturn.signal()
    #expect(publicationReturned.wait(timeout: .now() + 2) == .success)

    #expect(pending.load())
    #expect(wake.snapshot(forProcessor: 0) != observed)
  }

  @Test func acknowledgementRacingAnInFlightPublicationCannotEraseIt() {
    let wake = DoryPCPendingWorkWake()
    let pending = LockedPendingByte()
    let publicationEntered = DispatchSemaphore(value: 0)
    let allowPublicationToReturn = DispatchSemaphore(value: 0)
    let acknowledgementReturned = DispatchSemaphore(value: 0)
    let observed = wake.snapshot(forProcessor: 0)

    DispatchQueue.global().async {
      wake.signal(forProcessor: 0) {
        pending.store(true)
        publicationEntered.signal()
        allowPublicationToReturn.wait()
      }
    }
    #expect(publicationEntered.wait(timeout: .now() + 2) == .success)
    DispatchQueue.global().async {
      #expect(
        !wake.acknowledge(forProcessor: 0, after: observed) { pending.store(false) })
      acknowledgementReturned.signal()
    }
    #expect(acknowledgementReturned.wait(timeout: .now() + .milliseconds(25)) == .timedOut)
    allowPublicationToReturn.signal()
    #expect(acknowledgementReturned.wait(timeout: .now() + 2) == .success)

    #expect(pending.load())
    #expect(wake.snapshot(forProcessor: 0) != observed)
  }

  @Test func synchronousDispatchPublicationCanBeConsumedWithoutInventingAnEdge() {
    let wake = DoryPCPendingWorkWake()
    let pending = LockedPendingByte()
    let observed = wake.snapshot(forProcessor: 0)
    wake.setDispatchThread(Thread.current, forProcessor: 0)
    defer { wake.setDispatchThread(nil, forProcessor: 0) }

    wake.signal(forProcessor: 0) { pending.store(true) }

    #expect(wake.snapshot(forProcessor: 0) == observed)
    #expect(
      wake.acknowledge(forProcessor: 0, after: observed) { pending.store(false) })
    #expect(!pending.load())
  }

  @Test func targetedPublicationAdvancesOnlyTheRequestedProcessor() {
    let wake = DoryPCPendingWorkWake(processorCount: 2)
    let processor0 = wake.snapshot(forProcessor: 0)
    let processor1 = wake.snapshot(forProcessor: 1)

    wake.signal(forProcessor: 1) {}

    #expect(wake.snapshot(forProcessor: 0) == processor0)
    #expect(wake.snapshot(forProcessor: 1) != processor1)
  }

  @Test func synchronousBroadcastIsConsumedLocallyButRemainsPendingRemotely() {
    let wake = DoryPCPendingWorkWake(processorCount: 2)
    let pending = [LockedPendingByte(), LockedPendingByte()]
    let processor0 = wake.snapshot(forProcessor: 0)
    let processor1 = wake.snapshot(forProcessor: 1)
    wake.setDispatchThread(Thread.current, forProcessor: 0)
    defer { wake.setDispatchThread(nil, forProcessor: 0) }

    wake.signalAll {
      for byte in pending { byte.store(true) }
    }

    #expect(wake.snapshot(forProcessor: 0) == processor0)
    #expect(wake.snapshot(forProcessor: 1) != processor1)
    #expect(
      wake.acknowledge(forProcessor: 0, after: processor0) { pending[0].store(false) })
    #expect(
      !wake.acknowledge(forProcessor: 1, after: processor1) { pending[1].store(false) })
    #expect(!pending[0].load())
    #expect(pending[1].load())
  }

  @Test func maintenanceWaitDoesNotAdvertiseArchitecturalIdleness() {
    let wake = DoryPCPendingWorkWake()
    let entered = DispatchSemaphore(value: 0)
    let returned = DispatchSemaphore(value: 0)
    let observed = wake.snapshot(forProcessor: 0)

    DispatchQueue.global().async {
      entered.signal()
      wake.waitForMaintenance(forProcessor: 0, after: observed)
      returned.signal()
    }

    #expect(entered.wait(timeout: .now() + 2) == .success)
    #expect(!wake.waitUntilWaiting(until: Date(timeIntervalSinceNow: 0.025)))
    wake.notify(forProcessor: 0)
    #expect(returned.wait(timeout: .now() + 2) == .success)
  }
}

private final class LockedPendingByte: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Bool

  init(initialValue: Bool = false) { value = initialValue }

  func load() -> Bool { lock.withLock { value } }

  func store(_ value: Bool) { lock.withLock { self.value = value } }
}
