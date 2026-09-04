import Foundation

public enum DoryX86DifferentialError: Error, Sendable, Equatable {
  case requiresBaselineJIT
  case unsupportedHost
  case invalidContextWordCount(Int)
  case memoryDoesNotSupportIndependentCopies
  case sharedMemoryInstance
  case sharedMemoryBacking
  case unequalInitialMemoryState
  case instructionBytesDoNotMatchMemory
}

/// A fixture must include every mutable RAM and device field that can affect execution. Device
/// bytes are an exact deterministic encoding, not a digest or a list of selected registers.
public struct DoryX86DifferentialMemoryState: Sendable, Hashable {
  public let memory: [UInt8]
  public let devices: [UInt8]

  public init(memory: [UInt8], devices: [UInt8] = []) {
    self.memory = memory
    self.devices = devices
  }
}

/// Explicit opt-in: copies must have independent backing RAM and independent devices, initialized
/// from one quiescent snapshot. Sharing an external I/O endpoint is not a differential fixture.
public protocol DoryX86DifferentialMemory: DoryX86Memory {
  func makeDifferentialCopy() throws -> any DoryX86DifferentialMemory
  func differentialState() throws -> DoryX86DifferentialMemoryState
}

extension DoryX86ByteArrayMemory: DoryX86DifferentialMemory {
  public func makeDifferentialCopy() throws -> any DoryX86DifferentialMemory {
    try DoryX86ByteArrayMemory(baseAddress: baseAddress, bytes: snapshot())
  }

  public func differentialState() throws -> DoryX86DifferentialMemoryState {
    .init(memory: snapshot())
  }
}

public struct DoryX86DifferentialResult: Sendable, Hashable {
  public let block: DoryIRBasicBlock
  public let compiled: DoryARM64CompiledBlock
  public let interpreterState: DoryX86ArchitecturalState
  public let jitState: DoryX86ArchitecturalState
  public let interpreterResult: DoryX86InterpreterResult?
  public let interpreterRetiredInstructionCount: Int
  public let interpreterMemory: DoryX86DifferentialMemoryState
  public let jitMemory: DoryX86DifferentialMemoryState
  public let interpreterMemoryFault: DoryX86MemoryError?
  public let jitMemoryFault: DoryX86MemoryError?
  public let jitExit: DoryJITExitCode

  public var agrees: Bool {
    guard interpreterState == jitState,
      interpreterMemory == jitMemory,
      interpreterMemoryFault == jitMemoryFault
    else { return false }
    switch interpreterResult {
    case .retired:
      return interpreterRetiredInstructionCount == block.guestInstructionCount
        && jitExit == .dispatch && jitMemoryFault == nil
    case .halted:
      return jitExit == .halt && jitMemoryFault == nil
    default:
      // A JIT memory callback currently reports fallback rather than an architectural exception.
      // Retain its exact fault and state for diagnosis, but never count fallback as native parity.
      return false
    }
  }
}

public struct DoryX86DifferentialHarness: Sendable {
  public let translator: DoryX86IRTranslator
  public let emitter: DoryARM64BaselineEmitter
  public let interpreter: DoryX86Interpreter

  public init(
    translator: DoryX86IRTranslator = .init(),
    emitter: DoryARM64BaselineEmitter = .init(),
    interpreter: DoryX86Interpreter = .init()
  ) {
    self.translator = translator
    self.emitter = emitter
    self.interpreter = interpreter
  }

  public func compare(
    bytes: [UInt8],
    initialState: DoryX86ArchitecturalState,
    memory: any DoryX86Memory,
    mode: DoryX86ExecutionMode
  ) throws -> DoryX86DifferentialResult {
    guard let source = memory as? any DoryX86DifferentialMemory else {
      throw DoryX86DifferentialError.memoryDoesNotSupportIndependentCopies
    }
    let sourceState = try source.differentialState()
    let interpreterMemory = try source.makeDifferentialCopy()
    let jitMemory = try source.makeDifferentialCopy()
    guard ObjectIdentifier(interpreterMemory) != ObjectIdentifier(jitMemory),
      ObjectIdentifier(source) != ObjectIdentifier(interpreterMemory),
      ObjectIdentifier(source) != ObjectIdentifier(jitMemory)
    else { throw DoryX86DifferentialError.sharedMemoryInstance }
    guard try interpreterMemory.differentialState() == sourceState,
      try jitMemory.differentialState() == sourceState,
      try source.differentialState() == sourceState
    else { throw DoryX86DifferentialError.unequalInitialMemoryState }

    #if !arch(arm64)
      throw DoryX86DifferentialError.unsupportedHost
    #else
      // The interpreter fetches from memory, while translation consumes the supplied bytes.
      // Comparing different programs would otherwise produce misleading results.
      guard
        try interpreterMemory.instructionBytes(at: initialState.rip, maximumCount: bytes.count)
          == bytes,
        try jitMemory.instructionBytes(at: initialState.rip, maximumCount: bytes.count) == bytes
      else { throw DoryX86DifferentialError.instructionBytesDoNotMatchMemory }
      let block = try translator.translate(bytes, at: initialState.rip, mode: mode)
      let compiled = emitter.compile(block)
      guard compiled.tier == .baseline else {
        throw DoryX86DifferentialError.requiresBaselineJIT
      }
      let interpreterAccess = DoryX86DifferentialAccess(memory: interpreterMemory)
      let jitAccess = DoryX86DifferentialAccess(memory: jitMemory)
      var interpreterState = initialState
      var interpreterResult: DoryX86InterpreterResult?
      var retired = 0
      for _ in 0..<block.guestInstructionCount {
        let result = interpreter.step(
          state: &interpreterState, memory: interpreterAccess, mode: mode)
        interpreterResult = result
        guard case .retired = result else { break }
        retired += 1
      }
      // Object identity cannot prove that wrapper objects own independent backing.
      // Freeze the interpreter result before the other engine can overwrite it.
      let interpreterSnapshot = try interpreterMemory.differentialState()
      guard try jitMemory.differentialState() == sourceState,
        try source.differentialState() == sourceState
      else { throw DoryX86DifferentialError.sharedMemoryBacking }

      var context = executionContext(from: initialState)
      let region = try DoryJITExecutableRegion(
        minimumCapacity: max(4096, compiled.machineBytes.count))
      try region.publish(compiled, at: 0)
      let jitExit = try region.execute(
        at: 0, context: &context, memory: jitAccess,
        requiresRestartableReads: compiled.requiresRestartableMemoryReads)
      var jitState = initialState
      if jitExit != .interpreter
        || (!compiled.requiresMemoryCallbacks && !compiled.mayExitToInterpreter)
      {
        try apply(context: context, to: &jitState)
      }
      let jitSnapshot = try jitMemory.differentialState()
      guard try interpreterMemory.differentialState() == interpreterSnapshot,
        try source.differentialState() == sourceState
      else { throw DoryX86DifferentialError.sharedMemoryBacking }
      return .init(
        block: block,
        compiled: compiled,
        interpreterState: interpreterState,
        jitState: jitState,
        interpreterResult: interpreterResult,
        interpreterRetiredInstructionCount: retired,
        interpreterMemory: interpreterSnapshot,
        jitMemory: jitSnapshot,
        interpreterMemoryFault: interpreterAccess.firstFault,
        jitMemoryFault: jitAccess.firstFault,
        jitExit: jitExit
      )
    #endif
  }

  public func executionContext(from state: DoryX86ArchitecturalState) -> [UInt64] {
    var context = DoryX86GeneralRegister.allCases.map { state.registers[$0] }
    context.append(state.rip)
    context.append(state.rflags.rawValue)
    return context
  }

  public func apply(
    context: [UInt64],
    to state: inout DoryX86ArchitecturalState
  ) throws {
    guard context.count == DoryJITExecutableRegion.contextWordCount else {
      throw DoryX86DifferentialError.invalidContextWordCount(context.count)
    }
    for (index, register) in DoryX86GeneralRegister.allCases.enumerated() {
      state.registers[register] = context[index]
    }
    state.rip = context[16]
    state.rflags = DoryX86RFLAGS(rawValue: context[17])
  }
}

/// Captures precise callback errors before the native runtime reduces them to a fallback exit.
/// This wrapper never turns an ordinary or device read into a restartability proof.
private final class DoryX86DifferentialAccess:
  DoryX86ScalarMemory, DoryX86RestartableScalarMemory, @unchecked Sendable
{
  let memory: any DoryX86Memory
  private let lock = NSLock()
  private var recordedFault: DoryX86MemoryError?
  var firstFault: DoryX86MemoryError? { lock.withLock { recordedFault } }

  init(memory: any DoryX86Memory) { self.memory = memory }

  private func record<T>(_ body: () throws -> T) throws -> T {
    do { return try body() } catch {
      if let fault = error as? DoryX86MemoryError {
        lock.withLock { if recordedFault == nil { recordedFault = fault } }
      }
      throw error
    }
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try record { try memory.instructionBytes(at: address, maximumCount: maximumCount) }
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    try record { try memory.read(at: address, byteCount: byteCount) }
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    try record { try memory.write(at: address, bytes: bytes) }
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    try record { try memory.validateWrite(at: address, byteCount: byteCount) }
  }

  func readScalar(at address: UInt64, byteCount: Int) throws -> UInt64 {
    try record {
      if let scalar = memory as? any DoryX86ScalarMemory {
        return try scalar.readScalar(at: address, byteCount: byteCount)
      }
      guard [1, 2, 4, 8].contains(byteCount) else {
        throw DoryX86ScalarMemoryError.invalidByteCount(byteCount)
      }
      return try memory.read(at: address, byteCount: byteCount).enumerated().reduce(0) {
        $0 | UInt64($1.element) << UInt64($1.offset * 8)
      }
    }
  }

  func writeScalar(at address: UInt64, value: UInt64, byteCount: Int) throws {
    try record {
      if let scalar = memory as? any DoryX86ScalarMemory {
        try scalar.writeScalar(at: address, value: value, byteCount: byteCount)
        return
      }
      guard [1, 2, 4, 8].contains(byteCount) else {
        throw DoryX86ScalarMemoryError.invalidByteCount(byteCount)
      }
      let bytes = (0..<byteCount).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
      try memory.validateWrite(at: address, byteCount: byteCount)
      try memory.write(at: address, bytes: bytes)
    }
  }

  func readRestartableScalar(at address: UInt64, byteCount: Int) throws -> UInt64? {
    try record {
      try (memory as? any DoryX86RestartableScalarMemory)?.readRestartableScalar(
        at: address, byteCount: byteCount)
    }
  }

  func synchronize() { memory.synchronize() }
}
