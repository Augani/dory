import Foundation
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCRunCommandBusTests {
  @Test func validatesLanesAndFailsClosedInsteadOfOverwriting() throws {
    let bus = DoryPCRunCommandBus(processorCount: 2, runGeneration: 41)

    #expect(
      throws: DoryPCRunCommandBus.CommandError.invalidProcessor(-1)
    ) {
      try bus.publishExecution(forProcessor: -1, maximumInstructions: 1)
    }
    #expect(
      throws: DoryPCRunCommandBus.CommandError.invalidProcessor(2)
    ) {
      try bus.nextCommand(forProcessor: 2)
    }
    #expect(
      throws: DoryPCRunCommandBus.CommandError.invalidMaximumInstructions(0)
    ) {
      try bus.publishExecution(forProcessor: 0, maximumInstructions: 0)
    }

    let first = try bus.publishExecution(forProcessor: 0, maximumInstructions: 7)
    #expect(first == .init(runGeneration: 41, processor: 0, sequence: 1, maximumInstructions: 7))
    #expect(
      throws: DoryPCRunCommandBus.CommandError.outstandingCommand(0)
    ) {
      try bus.publishExecution(forProcessor: 0, maximumInstructions: 9)
    }

    // Lanes are independent; an unread command for one owner cannot block another owner.
    let secondProcessor = try bus.publishExecution(forProcessor: 1, maximumInstructions: 11)
    #expect(try bus.nextCommand(forProcessor: 1) == secondProcessor)
    #expect(try bus.nextCommand(forProcessor: 0) == first)
  }

  @Test func closeCancelsUnreadCommandsAndWakesParkedOwners() throws {
    let bus = DoryPCRunCommandBus(processorCount: 2, runGeneration: 2)
    _ = try bus.publishExecution(forProcessor: 0, maximumInstructions: 1)
    let parkedResult = CommandBusLockedValue<DoryPCRunCommandBus.Envelope?>(
      .init(runGeneration: 0, processor: 0, sequence: 0, maximumInstructions: 0)
    )
    let parked = DispatchGroup()
    parked.enter()
    DispatchQueue.global().async {
      defer { parked.leave() }
      parkedResult.set(try? bus.nextCommand(forProcessor: 1))
    }

    bus.close()
    #expect(try bus.nextCommand(forProcessor: 0) == nil)
    #expect(parked.wait(timeout: .now() + 1) == .success)
    #expect(parkedResult.value == nil)
    #expect(throws: DoryPCRunCommandBus.CommandError.closed) {
      try bus.publishExecution(forProcessor: 0, maximumInstructions: 1)
    }
    bus.close()
  }

  @Test func sequenceWrapSkipsZero() throws {
    let bus = DoryPCRunCommandBus(
      processorCount: 1,
      runGeneration: .max,
      initialSequence: .max
    )
    let command = try bus.publishExecution(forProcessor: 0, maximumInstructions: 1)
    #expect(command.sequence == 1)
    #expect(command.runGeneration == .max)
    #expect(try bus.nextCommand(forProcessor: 0) == command)
  }

  @Test func tenThousandCrossLaneHandoffsAreExactAndLossless() {
    let processorCount = 4
    let commandsPerProcessor = 2_500
    let bus = DoryPCRunCommandBus(processorCount: processorCount, runGeneration: 73)
    let acknowledgements = (0..<processorCount).map { _ in DispatchSemaphore(value: 0) }
    let received = CommandBusLockedValue(
      Array(repeating: [DoryPCRunCommandBus.Envelope](), count: processorCount)
    )
    let failures = CommandBusLockedValue<[String]>([])
    let consumers = DispatchGroup()

    for processor in 0..<processorCount {
      consumers.enter()
      DispatchQueue.global().async {
        defer { consumers.leave() }
        do {
          for _ in 0..<commandsPerProcessor {
            guard let command = try bus.nextCommand(forProcessor: processor) else {
              failures.mutate { $0.append("processor \(processor) closed early") }
              return
            }
            received.mutate { $0[processor].append(command) }
            acknowledgements[processor].signal()
          }
        } catch {
          failures.mutate { $0.append("processor \(processor): \(error)") }
        }
      }
    }

    DispatchQueue.concurrentPerform(iterations: processorCount) { processor in
      do {
        for index in 1...commandsPerProcessor {
          let command = try bus.publishExecution(
            forProcessor: processor,
            maximumInstructions: UInt64(index)
          )
          guard command.sequence == UInt64(index) else {
            failures.mutate {
              $0.append("processor \(processor) sequence \(command.sequence) at \(index)")
            }
            return
          }
          guard acknowledgements[processor].wait(timeout: .now() + 5) == .success else {
            failures.mutate { $0.append("processor \(processor) acknowledgement timeout") }
            return
          }
        }
      } catch {
        failures.mutate { $0.append("processor \(processor) publisher: \(error)") }
      }
    }

    #expect(consumers.wait(timeout: .now() + 5) == .success)
    bus.close()
    #expect(failures.value.isEmpty)
    for processor in 0..<processorCount {
      let lane = received.value[processor]
      #expect(lane.count == commandsPerProcessor)
      #expect(lane.map(\.processor).allSatisfy { $0 == processor })
      #expect(lane.map(\.runGeneration).allSatisfy { $0 == 73 })
      #expect(lane.map(\.sequence) == (1...commandsPerProcessor).map(UInt64.init))
      #expect(lane.map(\.maximumInstructions) == (1...commandsPerProcessor).map(UInt64.init))
    }
  }
}

private final class CommandBusLockedValue<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Value

  init(_ value: Value) { storage = value }

  var value: Value { lock.withLock { storage } }

  func set(_ value: Value) { lock.withLock { storage = value } }

  func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&storage) } }
}
