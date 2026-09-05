import Foundation

@testable import DoryMachinePC

extension DoryPCDirectKernelMachine {
  func runOnDedicatedStack(
    maximumInstructions: UInt64,
    exceptionPolicy: DoryPCExceptionPolicy = .stop
  ) throws -> DoryPCMachineStop {
    let result = DoryPCDedicatedStackRunResult()
    let finished = DispatchSemaphore(value: 0)
    let thread = Thread {
      result.store(
        Result {
          try self.run(maximumInstructions: maximumInstructions, exceptionPolicy: exceptionPolicy)
        })
      finished.signal()
    }
    thread.name = "dev.dory.tests.pc-direct-kernel-run"
    thread.stackSize = 2 * 1024 * 1024
    thread.start()
    finished.wait()
    return try result.get()
  }
}

private final class DoryPCDedicatedStackRunResult: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<DoryPCMachineStop, any Error>?

  func store(_ result: Result<DoryPCMachineStop, any Error>) {
    lock.withLock { self.result = result }
  }

  func get() throws -> DoryPCMachineStop {
    try lock.withLock {
      guard let result else { throw DoryPCDedicatedStackRunError.missingResult }
      return try result.get()
    }
  }
}

private enum DoryPCDedicatedStackRunError: Error {
  case missingResult
}
