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

/// A persistent single-slot mailbox for one vCPU. The condition protects all mailbox/lifetime
/// state; guest work runs outside it. The machine runtime owns this worker for its entire lifetime,
/// while each coordinator submission transfers exclusive vCPU ownership until completion.
final class DoryPCHostWorker: @unchecked Sendable {
  struct CPUTime: Sendable {
    let executionNanoseconds: UInt64
    let eventNanoseconds: UInt64
  }

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
  private let cpuTimeLock = NSLock()
  private var executionCPUNanoseconds: UInt64 = 0
  private var eventCPUNanoseconds: UInt64 = 0

  init(
    processor: Int, instrumentationEnabled: Bool = false,
    onExit: @escaping @Sendable () -> Void
  ) {
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
    job = (
      kind,
      { [self] in
        let started = instrumentationEnabled ? dory_thread_cpu_time_nanoseconds() : 0
        let result = Result { try body() }
        if instrumentationEnabled {
          let elapsed = dory_thread_cpu_time_nanoseconds() &- started
          cpuTimeLock.withLock {
            switch kind {
            case .execution:
              let (sum, overflow) = executionCPUNanoseconds.addingReportingOverflow(elapsed)
              executionCPUNanoseconds = overflow ? .max : sum
            case .processorEvent:
              let (sum, overflow) = eventCPUNanoseconds.addingReportingOverflow(elapsed)
              eventCPUNanoseconds = overflow ? .max : sum
            }
          }
        }
        // Publish completion only after instrumentation. A coordinator that has observed every
        // completion can therefore consume an exact per-run CPU-time delta without racing a worker.
        completion.finish(result)
      }
    )
    condition.signal()
    condition.unlock()
    return completion
  }

  func perform<T: Sendable>(
    kind: WorkKind = .execution, _ body: @escaping @Sendable () throws -> T
  ) throws -> T {
    try submit(kind: kind, body).wait()
  }

  /// Returns and clears CPU time accumulated since the last consume. The owning runtime calls this
  /// only after every submission in a run has completed, so one run cannot inherit another's time.
  func consumeCPUTime() -> CPUTime {
    cpuTimeLock.withLock {
      let snapshot = CPUTime(
        executionNanoseconds: executionCPUNanoseconds,
        eventNanoseconds: eventCPUNanoseconds
      )
      executionCPUNanoseconds = 0
      eventCPUNanoseconds = 0
      return snapshot
    }
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
      work.body()
    }
    onExit()
    condition.lock()
    exited = true
    condition.broadcast()
    condition.unlock()
  }
}

/// Machine-owned persistent worker set. Construction and teardown occur once per VM rather than
/// once per public `run` call. This is the lifetime foundation for a later long-running guest
/// dispatch protocol; today the coordinator still submits bounded slices and rendezvous with every
/// completion before mutating global machine state.
final class DoryPCVCPURuntime: @unchecked Sendable {
  let workers: [DoryPCHostWorker]

  private let lifecycleLock = NSLock()
  private var stopped = false

  init(processorCount: Int, instrumentationEnabled: Bool) {
    workers = (0..<processorCount).map { processor in
      DoryPCHostWorker(
        processor: processor,
        instrumentationEnabled: instrumentationEnabled,
        onExit: {}
      )
    }
  }

  func stopAndJoin() {
    let shouldStop = lifecycleLock.withLock {
      guard !stopped else { return false }
      stopped = true
      return true
    }
    guard shouldStop else { return }
    for worker in workers { worker.requestStop() }
    for worker in workers { worker.stopAndJoin() }
  }

  deinit { stopAndJoin() }
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
