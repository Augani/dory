import DoryDBTX86
import DoryPlatformC
import Foundation

/// Serializes public machine operations without holding a mutex during guest execution.
/// The coordinator transfers exclusive access to workers and rendezvous before releasing it.
final class DoryPCExecutionGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var occupied = false

  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    condition.lock()
    while occupied { condition.wait() }
    occupied = true
    condition.unlock()
    defer {
      condition.lock()
      occupied = false
      condition.broadcast()
      condition.unlock()
    }
    return try body()
  }
}

/// A single-slot mailbox for a single vCPU. The condition protects all mailbox/lifetime state;
/// guest work runs outside it. Only the run coordinator submits work. Completion transfers
/// ownership back to that coordinator, including on throwing paths.
final class DoryPCHostWorker: @unchecked Sendable {
  final class Completion<T: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<T, any Error>?

    func finish(_ result: Result<T, any Error>) {
      condition.lock()
      self.result = result
      condition.broadcast()
      condition.unlock()
    }

    func wait() throws -> T {
      condition.lock()
      defer { condition.unlock() }
      while result == nil { condition.wait() }
      return try result!.get()
    }
  }

  enum WorkKind: Sendable { case execution, processorEvent }

  private let condition = NSCondition()
  private var job: (kind: WorkKind, body: @Sendable () -> Void)?
  private var stopping = false
  private var exited = false
  private let onExit: @Sendable () -> Void
  private let instrumentationEnabled: Bool
  // Read only after stopAndJoin has acquired the exit acknowledgement.
  private(set) var executionCPUNanoseconds: UInt64 = 0
  private(set) var eventCPUNanoseconds: UInt64 = 0

  init(processor: Int, instrumentationEnabled: Bool = false,
    onExit: @escaping @Sendable () -> Void) {
    self.onExit = onExit
    self.instrumentationEnabled = instrumentationEnabled
    let thread = Thread { [self] in loop() }
    thread.name = "dev.dory.pc.vcpu.\(processor)"
    thread.stackSize = 2 * 1024 * 1024
    thread.start()
  }

  func submit<T: Sendable>(
    kind: WorkKind = .execution,
    _ body: @escaping @Sendable () throws -> T
  ) -> Completion<T> {
    let completion = Completion<T>()
    condition.lock()
    precondition(!stopping && job == nil)
    job = (kind, { completion.finish(Result { try body() }) })
    condition.signal()
    condition.unlock()
    return completion
  }

  func perform<T: Sendable>(
    kind: WorkKind = .execution, _ body: @escaping @Sendable () throws -> T
  ) throws -> T {
    try submit(kind: kind, body).wait()
  }

  /// Stop is sticky and checked under the same condition as wait. A signal sent before a
  /// worker parks cannot be lost. Exit acknowledgement follows the last guest access/callback.
  func requestStop() {
    condition.lock()
    stopping = true
    condition.broadcast()
    condition.unlock()
  }

  func stopAndJoin() {
    requestStop()
    condition.lock()
    while !exited { condition.wait() }
    condition.unlock()
  }

  private func loop() {
    while true {
      condition.lock()
      while job == nil && !stopping { condition.wait() }
      guard let work = job else {
        condition.unlock()
        break
      }
      job = nil
      condition.unlock()
      let started = instrumentationEnabled ? dory_thread_cpu_time_nanoseconds() : 0
      work.body()
      if instrumentationEnabled {
        let elapsed = dory_thread_cpu_time_nanoseconds() &- started
        switch work.kind {
        case .execution:
          let (sum, overflow) = executionCPUNanoseconds.addingReportingOverflow(elapsed)
          executionCPUNanoseconds = overflow ? .max : sum
        case .processorEvent:
          let (sum, overflow) = eventCPUNanoseconds.addingReportingOverflow(elapsed)
          eventCPUNanoseconds = overflow ? .max : sum
        }
      }
    }
    onExit()
    condition.lock()
    exited = true
    condition.broadcast()
    condition.unlock()
  }
}

/// Immutable fetch-only memory. Parallel instructions cannot reach shared RAM, translation
/// metadata, or devices, even if a future whitelist change accidentally admits an operand read.
final class DoryPCFrozenInstructionMemory: DoryX86Memory {
  let address: UInt64
  let bytes: [UInt8]
  private let onFirstFetch: (@Sendable () -> Void)?

  init(address: UInt64, bytes: [UInt8], onFirstFetch: (@Sendable () -> Void)? = nil) {
    self.address = address
    self.bytes = bytes
    self.onFirstFetch = onFirstFetch
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    guard address >= self.address, maximumCount >= 0,
      address - self.address < UInt64(bytes.count)
    else {
      throw DoryX86MemoryError.unmapped(
        address: address, byteCount: maximumCount, access: .instructionFetch)
    }
    // The interpreter starts incremental decoding with one byte. This internal observation
    // point lets tests rendezvous while both interpreter steps are actually on their stacks.
    if address == self.address, maximumCount == 1 { onFirstFetch?() }
    let offset = Int(address - self.address)
    return Array(bytes[offset..<min(bytes.count, offset + maximumCount)])
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    throw DoryX86MemoryError.unmapped(address: address, byteCount: byteCount, access: .read)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    throw DoryX86MemoryError.unmapped(address: address, byteCount: bytes.count, access: .write)
  }
}
