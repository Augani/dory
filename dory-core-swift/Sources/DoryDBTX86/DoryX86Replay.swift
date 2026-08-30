import Foundation

public enum DoryX86ReplayMemoryOutcome: Codable, Sendable, Hashable {
  case bytes([UInt8])
  case success
  case failure(DoryX86MemoryError)
}

public enum DoryX86ReplayMemoryEvent: Codable, Sendable, Hashable {
  case instruction(address: UInt64, maximumCount: Int, outcome: DoryX86ReplayMemoryOutcome)
  case read(address: UInt64, byteCount: Int, outcome: DoryX86ReplayMemoryOutcome)
  case write(address: UInt64, bytes: [UInt8], outcome: DoryX86ReplayMemoryOutcome)
  case validateWrite(address: UInt64, byteCount: Int, outcome: DoryX86ReplayMemoryOutcome)
  case synchronize
}

public enum DoryX86ReplayIOOutcome: Codable, Sendable, Hashable {
  case value(UInt32)
  case success
  case failure
}

public enum DoryX86ReplayIOEvent: Codable, Sendable, Hashable {
  case read(port: UInt16, width: DoryX86OperandWidth, outcome: DoryX86ReplayIOOutcome)
  case write(
    port: UInt16,
    value: UInt32,
    width: DoryX86OperandWidth,
    outcome: DoryX86ReplayIOOutcome
  )
}

public struct DoryX86ReplayRecord: Codable, Sendable, Hashable {
  public let mode: DoryX86ExecutionMode
  public let initialState: DoryX86ArchitecturalState
  public let finalState: DoryX86ArchitecturalState
  public let result: DoryX86InterpreterResult
  public let memoryEvents: [DoryX86ReplayMemoryEvent]
  public let ioEvents: [DoryX86ReplayIOEvent]
  public let hadIOBus: Bool
  public let pagingPhysicalAddressBits: UInt8?
  public let pagingMaximumEntryCount: Int?
}

public enum DoryX86ReplayError: Error, Sendable, Equatable {
  case eventMismatch
  case eventsRemain(memory: Int, io: Int)
  case resultMismatch
  case stateMismatch
}

public struct DoryX86ReplayRecorder: Sendable {
  public let interpreter: DoryX86Interpreter

  public init(interpreter: DoryX86Interpreter = .init()) {
    self.interpreter = interpreter
  }

  public func recordStep(
    initialState: DoryX86ArchitecturalState,
    memory: any DoryX86Memory,
    mode: DoryX86ExecutionMode,
    pagingUnit: DoryX86PagingUnit? = nil,
    ioBus: (any DoryX86IOBus)? = nil
  ) -> DoryX86ReplayRecord {
    let tracedMemory = DoryX86RecordingMemory(base: memory)
    let tracedIO = ioBus.map { DoryX86RecordingIOBus(base: $0) }
    var finalState = initialState
    let result = interpreter.step(
      state: &finalState,
      memory: tracedMemory,
      mode: mode,
      pagingUnit: pagingUnit,
      ioBus: tracedIO
    )
    return .init(
      mode: mode,
      initialState: initialState,
      finalState: finalState,
      result: result,
      memoryEvents: tracedMemory.snapshot(),
      ioEvents: tracedIO?.snapshot() ?? [],
      hadIOBus: ioBus != nil,
      pagingPhysicalAddressBits: pagingUnit?.physicalAddressBits,
      pagingMaximumEntryCount: pagingUnit?.maximumEntryCount
    )
  }

  public func replay(_ record: DoryX86ReplayRecord) throws {
    let memory = DoryX86ScriptedMemory(events: record.memoryEvents)
    let io = record.hadIOBus ? DoryX86ScriptedIOBus(events: record.ioEvents) : nil
    let pagingUnit = try replayPagingUnit(for: record)
    var state = record.initialState
    let result = interpreter.step(
      state: &state,
      memory: memory,
      mode: record.mode,
      pagingUnit: pagingUnit,
      ioBus: io
    )
    let memoryRemaining = memory.remainingEventCount
    let ioRemaining = io?.remainingEventCount ?? 0
    guard memoryRemaining == 0, ioRemaining == 0 else {
      throw DoryX86ReplayError.eventsRemain(memory: memoryRemaining, io: ioRemaining)
    }
    guard result == record.result else { throw DoryX86ReplayError.resultMismatch }
    guard state == record.finalState else { throw DoryX86ReplayError.stateMismatch }
  }

  private func replayPagingUnit(for record: DoryX86ReplayRecord) throws -> DoryX86PagingUnit? {
    switch (record.pagingPhysicalAddressBits, record.pagingMaximumEntryCount) {
    case (nil, nil): return nil
    case (.some(let bits), .some(let entryCount)):
      guard (32...52).contains(bits), entryCount > 0 else {
        throw DoryX86ReplayError.eventMismatch
      }
      return DoryX86PagingUnit(
        physicalAddressBits: bits,
        maximumEntryCount: entryCount
      )
    default: throw DoryX86ReplayError.eventMismatch
    }
  }
}

private final class DoryX86RecordingMemory: DoryX86Memory, @unchecked Sendable {
  private let base: any DoryX86Memory
  private let lock = NSLock()
  private var events: [DoryX86ReplayMemoryEvent] = []

  init(base: any DoryX86Memory) { self.base = base }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    do {
      let bytes = try base.instructionBytes(at: address, maximumCount: maximumCount)
      append(.instruction(address: address, maximumCount: maximumCount, outcome: .bytes(bytes)))
      return bytes
    } catch let error as DoryX86MemoryError {
      append(.instruction(address: address, maximumCount: maximumCount, outcome: .failure(error)))
      throw error
    }
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    do {
      let bytes = try base.read(at: address, byteCount: byteCount)
      append(.read(address: address, byteCount: byteCount, outcome: .bytes(bytes)))
      return bytes
    } catch let error as DoryX86MemoryError {
      append(.read(address: address, byteCount: byteCount, outcome: .failure(error)))
      throw error
    }
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    do {
      try base.write(at: address, bytes: bytes)
      append(.write(address: address, bytes: bytes, outcome: .success))
    } catch let error as DoryX86MemoryError {
      append(.write(address: address, bytes: bytes, outcome: .failure(error)))
      throw error
    }
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    do {
      try base.validateWrite(at: address, byteCount: byteCount)
      append(.validateWrite(address: address, byteCount: byteCount, outcome: .success))
    } catch let error as DoryX86MemoryError {
      append(.validateWrite(address: address, byteCount: byteCount, outcome: .failure(error)))
      throw error
    }
  }

  func synchronize() {
    base.synchronize()
    append(.synchronize)
  }

  func snapshot() -> [DoryX86ReplayMemoryEvent] { lock.withLock { events } }
  private func append(_ event: DoryX86ReplayMemoryEvent) {
    lock.withLock { events.append(event) }
  }
}

private final class DoryX86RecordingIOBus: DoryX86IOBus, @unchecked Sendable {
  private let base: any DoryX86IOBus
  private let lock = NSLock()
  private var events: [DoryX86ReplayIOEvent] = []

  init(base: any DoryX86IOBus) { self.base = base }

  func read(port: UInt16, width: DoryX86OperandWidth) throws -> UInt32 {
    do {
      let value = try base.read(port: port, width: width)
      append(.read(port: port, width: width, outcome: .value(value)))
      return value
    } catch {
      append(.read(port: port, width: width, outcome: .failure))
      throw error
    }
  }

  func write(port: UInt16, value: UInt32, width: DoryX86OperandWidth) throws {
    do {
      try base.write(port: port, value: value, width: width)
      append(.write(port: port, value: value, width: width, outcome: .success))
    } catch {
      append(.write(port: port, value: value, width: width, outcome: .failure))
      throw error
    }
  }

  func snapshot() -> [DoryX86ReplayIOEvent] { lock.withLock { events } }
  private func append(_ event: DoryX86ReplayIOEvent) {
    lock.withLock { events.append(event) }
  }
}

private final class DoryX86ScriptedMemory: DoryX86Memory, @unchecked Sendable {
  private let lock = NSLock()
  private var events: [DoryX86ReplayMemoryEvent]
  private var mismatchOccurred = false

  init(events: [DoryX86ReplayMemoryEvent]) { self.events = events }
  var remainingEventCount: Int { lock.withLock { events.count + (mismatchOccurred ? 1 : 0) } }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    let event = try take()
    guard
      case .instruction(
        address: let recordedAddress,
        maximumCount: let recordedMaximumCount,
        outcome: let outcome
      ) = event,
      recordedAddress == address,
      recordedMaximumCount == maximumCount
    else {
      throw DoryX86ReplayError.eventMismatch
    }
    return try bytes(from: outcome)
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    let event = try take()
    guard
      case .read(
        address: let recordedAddress,
        byteCount: let recordedByteCount,
        outcome: let outcome
      ) = event,
      recordedAddress == address,
      recordedByteCount == byteCount
    else {
      throw DoryX86ReplayError.eventMismatch
    }
    return try bytes(from: outcome)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    let event = try take()
    guard
      case .write(
        address: let recordedAddress,
        bytes: let recordedBytes,
        outcome: let outcome
      ) = event,
      recordedAddress == address,
      recordedBytes == bytes
    else {
      throw DoryX86ReplayError.eventMismatch
    }
    try success(from: outcome)
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    let event = try take()
    guard
      case .validateWrite(
        address: let recordedAddress,
        byteCount: let recordedByteCount,
        outcome: let outcome
      ) = event,
      recordedAddress == address,
      recordedByteCount == byteCount
    else {
      throw DoryX86ReplayError.eventMismatch
    }
    try success(from: outcome)
  }

  func synchronize() {
    do {
      _ = try take(expectedSynchronization: true)
    } catch {
      lock.withLock { mismatchOccurred = true }
    }
  }

  private func take() throws -> DoryX86ReplayMemoryEvent {
    try lock.withLock {
      guard !events.isEmpty else { throw DoryX86ReplayError.eventMismatch }
      return events.removeFirst()
    }
  }

  private func take(expectedSynchronization: Bool) throws -> DoryX86ReplayMemoryEvent {
    let event = try take()
    guard expectedSynchronization, event == .synchronize else {
      throw DoryX86ReplayError.eventMismatch
    }
    return event
  }

  private func bytes(from outcome: DoryX86ReplayMemoryOutcome) throws -> [UInt8] {
    switch outcome {
    case .bytes(let bytes): bytes
    case .failure(let error): throw error
    case .success: throw DoryX86ReplayError.eventMismatch
    }
  }

  private func success(from outcome: DoryX86ReplayMemoryOutcome) throws {
    switch outcome {
    case .success: return
    case .failure(let error): throw error
    case .bytes: throw DoryX86ReplayError.eventMismatch
    }
  }
}

private final class DoryX86ScriptedIOBus: DoryX86IOBus, @unchecked Sendable {
  private let lock = NSLock()
  private var events: [DoryX86ReplayIOEvent]

  init(events: [DoryX86ReplayIOEvent]) { self.events = events }
  var remainingEventCount: Int { lock.withLock { events.count } }

  func read(port: UInt16, width: DoryX86OperandWidth) throws -> UInt32 {
    let event = try take()
    guard
      case .read(
        port: let recordedPort,
        width: let recordedWidth,
        outcome: let outcome
      ) = event,
      recordedPort == port,
      recordedWidth == width
    else {
      throw DoryX86ReplayError.eventMismatch
    }
    switch outcome {
    case .value(let value): return value
    case .failure: throw DoryX86IOBusError.unmappedPort(port, width: width)
    case .success: throw DoryX86ReplayError.eventMismatch
    }
  }

  func write(port: UInt16, value: UInt32, width: DoryX86OperandWidth) throws {
    let event = try take()
    guard
      case .write(
        port: let recordedPort,
        value: let recordedValue,
        width: let recordedWidth,
        outcome: let outcome
      ) = event,
      recordedPort == port,
      recordedValue == value,
      recordedWidth == width
    else {
      throw DoryX86ReplayError.eventMismatch
    }
    switch outcome {
    case .success: return
    case .failure: throw DoryX86IOBusError.unmappedPort(port, width: width)
    case .value: throw DoryX86ReplayError.eventMismatch
    }
  }

  private func take() throws -> DoryX86ReplayIOEvent {
    try lock.withLock {
      guard !events.isEmpty else { throw DoryX86ReplayError.eventMismatch }
      return events.removeFirst()
    }
  }
}
