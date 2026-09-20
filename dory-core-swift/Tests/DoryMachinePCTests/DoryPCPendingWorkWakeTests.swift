import Foundation
import Testing

@testable import DoryMachinePC

@Suite(.serialized) struct DoryPCPendingWorkWakeTests {
  @Test func publicationBeforeAcknowledgementPreventsTheClear() {
    let wake = DoryPCPendingWorkWake()
    let pending = LockedPendingByte()
    let observed = wake.snapshot()

    wake.signal { pending.store(true) }

    #expect(!wake.acknowledge(after: observed) { pending.store(false) })
    #expect(pending.load())
    #expect(wake.snapshot() != observed)
  }

  @Test func publicationAfterAcknowledgementRestoresTheByte() {
    let wake = DoryPCPendingWorkWake()
    let pending = LockedPendingByte(initialValue: true)
    let clearEntered = DispatchSemaphore(value: 0)
    let allowClearToReturn = DispatchSemaphore(value: 0)
    let publicationReturned = DispatchSemaphore(value: 0)
    let observed = wake.snapshot()

    DispatchQueue.global().async {
      #expect(
        wake.acknowledge(after: observed) {
          pending.store(false)
          clearEntered.signal()
          allowClearToReturn.wait()
        })
    }
    #expect(clearEntered.wait(timeout: .now() + 2) == .success)
    DispatchQueue.global().async {
      wake.signal { pending.store(true) }
      publicationReturned.signal()
    }
    #expect(publicationReturned.wait(timeout: .now() + .milliseconds(25)) == .timedOut)
    allowClearToReturn.signal()
    #expect(publicationReturned.wait(timeout: .now() + 2) == .success)

    #expect(pending.load())
    #expect(wake.snapshot() != observed)
  }

  @Test func acknowledgementRacingAnInFlightPublicationCannotEraseIt() {
    let wake = DoryPCPendingWorkWake()
    let pending = LockedPendingByte()
    let publicationEntered = DispatchSemaphore(value: 0)
    let allowPublicationToReturn = DispatchSemaphore(value: 0)
    let acknowledgementReturned = DispatchSemaphore(value: 0)
    let observed = wake.snapshot()

    DispatchQueue.global().async {
      wake.signal {
        pending.store(true)
        publicationEntered.signal()
        allowPublicationToReturn.wait()
      }
    }
    #expect(publicationEntered.wait(timeout: .now() + 2) == .success)
    DispatchQueue.global().async {
      #expect(!wake.acknowledge(after: observed) { pending.store(false) })
      acknowledgementReturned.signal()
    }
    #expect(acknowledgementReturned.wait(timeout: .now() + .milliseconds(25)) == .timedOut)
    allowPublicationToReturn.signal()
    #expect(acknowledgementReturned.wait(timeout: .now() + 2) == .success)

    #expect(pending.load())
    #expect(wake.snapshot() != observed)
  }

  @Test func synchronousDispatchPublicationCanBeConsumedWithoutInventingAnEdge() {
    let wake = DoryPCPendingWorkWake()
    let pending = LockedPendingByte()
    let observed = wake.snapshot()
    wake.setDispatchThread(Thread.current)
    defer { wake.setDispatchThread(nil) }

    wake.signal { pending.store(true) }

    #expect(wake.snapshot() == observed)
    #expect(wake.acknowledge(after: observed) { pending.store(false) })
    #expect(!pending.load())
  }
}

private final class LockedPendingByte: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Bool

  init(initialValue: Bool = false) { value = initialValue }

  func load() -> Bool { lock.withLock { value } }

  func store(_ value: Bool) { lock.withLock { self.value = value } }
}
