import DoryDBTX86
import Foundation

public enum DoryPCMachineError: Error, Sendable, Equatable {
  case invalidMemorySize(Int)
  case alreadyLoaded
  case notLoaded
}

public enum DoryPCMachineStop: Sendable, Hashable {
  case halted(instructionCount: UInt64)
  case exception(DoryX86Exception, instructionCount: UInt64)
  case instructionBudget(UInt64)
}

/// Phase-4 uniprocessor direct-kernel machine. It deliberately exposes only the PVH boot and
/// serial-console surface required to bring the interpreter to Linux; the Phase-5 PC devices are
/// added behind the same sealed buses rather than hidden in this loop.
public final class DoryPCDirectKernelMachine: @unchecked Sendable {
  public let memory: DoryX86ByteArrayMemory
  public let ioBus: DoryPCPortIOBus
  public let serial: DoryPCUART16550
  public let pagingUnit: DoryX86PagingUnit
  public let interpreter: DoryX86Interpreter
  public let bootLayout: DoryPCPVHBootLayout
  public let memoryByteCount: Int

  private let lock = NSLock()
  private var loadedState: DoryX86ArchitecturalState?
  private var consumedPayload = false

  public init(
    memoryBytes: Int,
    bootLayout: DoryPCPVHBootLayout = .init(),
    interpreter: DoryX86Interpreter = .init()
  ) throws {
    guard memoryBytes >= 1024 * 1024 else {
      throw DoryPCMachineError.invalidMemorySize(memoryBytes)
    }
    memory = DoryX86ByteArrayMemory(byteCount: memoryBytes)
    memoryByteCount = memoryBytes
    ioBus = DoryPCPortIOBus()
    serial = DoryPCUART16550()
    try ioBus.attach(serial)
    ioBus.seal()
    pagingUnit = DoryX86PagingUnit()
    self.interpreter = interpreter
    self.bootLayout = bootLayout
  }

  public func load(
    kernel: Data,
    initrd: [UInt8] = [],
    commandLine: String = "console=ttyS0 earlyprintk=serial,ttyS0,115200"
  ) throws {
    try lock.withLock {
      guard !consumedPayload else { throw DoryPCMachineError.alreadyLoaded }
      let kernelImage = try DoryPCPVHKernelImage(data: kernel)
      let bootImage = try DoryPCPVHBootBuilder.build(
        commandLine: commandLine,
        initrd: initrd,
        memoryMap: DoryPCPVHBootBuilder.memoryMap(memoryBytes: UInt64(memoryByteCount)),
        layout: bootLayout
      )
      consumedPayload = true
      try kernelImage.load(into: memory)
      do {
        try bootImage.install(into: memory)
      } catch {
        // The machine cannot safely retry a partially loaded kernel with another payload.
        throw error
      }
      loadedState = try bootImage.initialState(entryPoint: kernelImage.physicalEntryPoint)
    }
  }

  public var state: DoryX86ArchitecturalState? { lock.withLock { loadedState } }

  public func run(maximumInstructions: UInt64) throws -> DoryPCMachineStop {
    guard maximumInstructions > 0 else { return .instructionBudget(0) }
    return try lock.withLock {
      guard var state = loadedState else { throw DoryPCMachineError.notLoaded }
      for completed in 0..<maximumInstructions {
        let result = interpreter.step(
          state: &state,
          memory: memory,
          mode: executionMode(state),
          pagingUnit: pagingUnit,
          ioBus: ioBus
        )
        loadedState = state
        switch result {
        case .retired, .yielded:
          continue
        case .halted:
          return .halted(instructionCount: completed + 1)
        case .exception(let exception):
          return .exception(exception, instructionCount: completed)
        }
      }
      return .instructionBudget(maximumInstructions)
    }
  }

  private func executionMode(_ state: DoryX86ArchitecturalState) -> DoryX86ExecutionMode {
    guard state.control.cr0 & 1 != 0 else { return .real16 }
    if state.control.efer & (1 << 10) != 0, state.cs.attributes & 0x2000 != 0 {
      return .long64
    }
    return .protected32
  }
}
