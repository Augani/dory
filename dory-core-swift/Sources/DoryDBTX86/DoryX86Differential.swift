import Foundation

public enum DoryX86DifferentialError: Error, Sendable, Equatable {
  case requiresBaselineJIT
  case interpreterDidNotRetire
  case unsupportedHost
  case invalidContextWordCount(Int)
}

public struct DoryX86DifferentialResult: Sendable, Hashable {
  public let block: DoryIRBasicBlock
  public let compiled: DoryARM64CompiledBlock
  public let interpreterState: DoryX86ArchitecturalState
  public let jitState: DoryX86ArchitecturalState
  public let jitExit: DoryJITExitCode

  public var agrees: Bool {
    interpreterState.registers == jitState.registers
      && interpreterState.rip == jitState.rip
      && interpreterState.rflags == jitState.rflags
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
    #if !arch(arm64)
      throw DoryX86DifferentialError.unsupportedHost
    #else
      let block = try translator.translate(bytes, at: initialState.rip, mode: mode)
      let compiled = emitter.compile(block)
      guard compiled.tier == .baseline else {
        throw DoryX86DifferentialError.requiresBaselineJIT
      }

      var interpreterState = initialState
      for _ in 0..<block.guestInstructionCount {
        let result = interpreter.step(
          state: &interpreterState,
          memory: memory,
          mode: mode
        )
        guard case .retired = result else {
          throw DoryX86DifferentialError.interpreterDidNotRetire
        }
      }

      var context = executionContext(from: initialState)
      let region = try DoryJITExecutableRegion(
        minimumCapacity: max(4096, compiled.machineBytes.count)
      )
      try region.publish(compiled, at: 0)
      let jitExit = try region.execute(at: 0, context: &context, memory: memory)
      var jitState = initialState
      try apply(context: context, to: &jitState)
      return .init(
        block: block,
        compiled: compiled,
        interpreterState: interpreterState,
        jitState: jitState,
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
