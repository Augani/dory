import Foundation

public struct DoryX86Exception: Error, Codable, Sendable, Hashable {
  public enum Kind: String, Codable, Sendable, Hashable {
    case invalidOpcode
    case generalProtection
    case pageFault
  }

  public let kind: Kind
  public let vector: UInt8
  public let errorCode: UInt32?
  public let instructionPointer: UInt64
  public let linearAddress: UInt64?

  public init(
    kind: Kind,
    vector: UInt8,
    errorCode: UInt32? = nil,
    instructionPointer: UInt64,
    linearAddress: UInt64? = nil
  ) {
    self.kind = kind
    self.vector = vector
    self.errorCode = errorCode
    self.instructionPointer = instructionPointer
    self.linearAddress = linearAddress
  }
}

public enum DoryX86InterpreterResult: Sendable, Hashable {
  case retired(DoryX86DecodedInstruction)
  case halted(DoryX86DecodedInstruction)
  case exception(DoryX86Exception)
}

public struct DoryX86Interpreter: Sendable {
  public let profile: DoryX86CPUProfile
  public let decoder: DoryX86Decoder

  public init(
    profile: DoryX86CPUProfile = .compatibleV1,
    decoder: DoryX86Decoder = .init()
  ) {
    self.profile = profile
    self.decoder = decoder
  }

  public func step(
    state: inout DoryX86ArchitecturalState,
    memory: any DoryX86Memory,
    mode: DoryX86ExecutionMode,
    pagingUnit: DoryX86PagingUnit? = nil
  ) -> DoryX86InterpreterResult {
    let originalRIP = state.rip
    let executionMemory: any DoryX86Memory =
      if let pagingUnit {
        DoryX86TranslatedMemory(
          physicalMemory: memory,
          pagingUnit: pagingUnit,
          context: .init(state: state, mode: mode)
        )
      } else {
        memory
      }
    let instruction: DoryX86DecodedInstruction
    do {
      instruction = try decodeInstruction(at: originalRIP, memory: executionMemory, mode: mode)
    } catch let error as DoryX86MemoryError {
      let fault = pageFault(for: error, instructionPointer: originalRIP)
      if fault.kind == .pageFault { state.control.cr2 = fault.linearAddress ?? 0 }
      return .exception(fault)
    } catch {
      return .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: originalRIP))
    }

    do {
      var nextRIP = instruction.nextInstructionAddress
      switch instruction.operation {
      case .noOperation:
        break
      case .halt:
        state.rip = nextRIP
        return .halted(instruction)
      case .move(let destination, let source):
        let value = try read(
          source, instruction: instruction, state: state, memory: executionMemory)
        try write(
          value, to: destination, instruction: instruction, state: &state, memory: executionMemory)
      case .loadEffectiveAddress(let destination, let source):
        let address = effectiveAddress(source, instruction: instruction, state: state)
        try write(
          address, to: destination, instruction: instruction, state: &state, memory: executionMemory
        )
      case .alu(let operation, let destination, let source):
        let lhs = try read(
          destination, instruction: instruction, state: state, memory: executionMemory)
        let rhs = try read(source, instruction: instruction, state: state, memory: executionMemory)
        let width = operandWidth(destination)
        let result = executeALU(operation, lhs: lhs, rhs: rhs, width: width, flags: &state.rflags)
        if operation != .compare, operation != .test {
          try write(
            result, to: destination, instruction: instruction, state: &state,
            memory: executionMemory)
        }
      case .push(let operand):
        let value = try read(
          operand, instruction: instruction, state: state, memory: executionMemory)
        let width = operandWidth(operand)
        state.registers.rsp &-= UInt64(width.byteCount)
        try executionMemory.write(at: state.registers.rsp, bytes: littleEndian(value, width: width))
      case .pop(let operand):
        let width = operandWidth(operand)
        let value = fromLittleEndian(
          try executionMemory.read(at: state.registers.rsp, byteCount: width.byteCount))
        try write(
          value, to: operand, instruction: instruction, state: &state, memory: executionMemory)
        state.registers.rsp &+= UInt64(width.byteCount)
      case .call(let relative):
        let stackWidth: DoryX86OperandWidth =
          mode == .long64 ? .quadword : (mode == .real16 ? .word : .doubleword)
        state.registers.rsp &-= UInt64(stackWidth.byteCount)
        try executionMemory.write(
          at: state.registers.rsp, bytes: littleEndian(nextRIP, width: stackWidth))
        nextRIP = addRelative(nextRIP, relative)
      case .return:
        let stackWidth: DoryX86OperandWidth =
          mode == .long64 ? .quadword : (mode == .real16 ? .word : .doubleword)
        nextRIP = fromLittleEndian(
          try executionMemory.read(at: state.registers.rsp, byteCount: stackWidth.byteCount))
        state.registers.rsp &+= UInt64(stackWidth.byteCount)
      case .jump(let relative):
        nextRIP = addRelative(nextRIP, relative)
      case .conditionalJump(let condition, let relative):
        if evaluate(condition, flags: state.rflags) { nextRIP = addRelative(nextRIP, relative) }
      case .cpuid:
        let result = profile.cpuid(
          leaf: UInt32(truncatingIfNeeded: state.registers.rax),
          subleaf: UInt32(truncatingIfNeeded: state.registers.rcx)
        )
        state.registers.rax = UInt64(result.eax)
        state.registers.rbx = UInt64(result.ebx)
        state.registers.rcx = UInt64(result.ecx)
        state.registers.rdx = UInt64(result.edx)
      case .setInterruptsEnabled(let enabled):
        let currentPrivilege = UInt64(state.cs.selector & 3)
        let ioPrivilege = (state.rflags.rawValue >> 12) & 3
        guard currentPrivilege <= ioPrivilege else {
          return .exception(
            .init(
              kind: .generalProtection,
              vector: 13,
              errorCode: 0,
              instructionPointer: originalRIP
            ))
        }
        if enabled {
          state.rflags.insert(.interruptEnable)
        } else {
          state.rflags.remove(.interruptEnable)
        }
      case .syscall:
        return .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: originalRIP))
      }
      state.rip = nextRIP
      return .retired(instruction)
    } catch let error as DoryX86MemoryError {
      state.rip = originalRIP
      let fault = pageFault(for: error, instructionPointer: originalRIP)
      state.control.cr2 = fault.linearAddress ?? 0
      return .exception(fault)
    } catch {
      state.rip = originalRIP
      return .exception(
        .init(
          kind: .generalProtection,
          vector: 13,
          errorCode: 0,
          instructionPointer: originalRIP
        ))
    }
  }

  private func decodeInstruction(
    at address: UInt64,
    memory: any DoryX86Memory,
    mode: DoryX86ExecutionMode
  ) throws -> DoryX86DecodedInstruction {
    for requestedByteCount in 1...15 {
      let bytes = try memory.instructionBytes(at: address, maximumCount: requestedByteCount)
      do {
        return try decoder.decode(bytes, at: address, mode: mode)
      } catch DoryX86DecodeError.truncated {
        if bytes.count < requestedByteCount {
          _ = try memory.instructionBytes(
            at: address &+ UInt64(bytes.count),
            maximumCount: 1
          )
        }
        continue
      }
    }
    throw DoryX86DecodeError.instructionTooLong(address: address)
  }

  private func read(
    _ operand: DoryX86Operand,
    instruction: DoryX86DecodedInstruction,
    state: DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws -> UInt64 {
    switch operand {
    case .register(let register, let width):
      return state.registers[register] & mask(width)
    case .memory(let operand):
      return fromLittleEndian(
        try memory.read(
          at: effectiveAddress(operand, instruction: instruction, state: state),
          byteCount: operand.width.byteCount
        ))
    case .immediate(let value, let width):
      return value & mask(width)
    case .relative(let value, _):
      return UInt64(bitPattern: value)
    }
  }

  private func write(
    _ value: UInt64,
    to operand: DoryX86Operand,
    instruction: DoryX86DecodedInstruction,
    state: inout DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws {
    switch operand {
    case .register(let register, let width):
      switch width {
      case .byte:
        state.registers[register] = (state.registers[register] & ~0xff) | (value & 0xff)
      case .word:
        state.registers[register] = (state.registers[register] & ~0xffff) | (value & 0xffff)
      case .doubleword:
        state.registers[register] = value & 0xffff_ffff
      case .quadword:
        state.registers[register] = value
      }
    case .memory(let target):
      try memory.write(
        at: effectiveAddress(target, instruction: instruction, state: state),
        bytes: littleEndian(value, width: target.width)
      )
    case .immediate, .relative:
      throw DoryX86Exception(
        kind: .generalProtection, vector: 13, errorCode: 0, instructionPointer: state.rip)
    }
  }

  private func effectiveAddress(
    _ operand: DoryX86MemoryOperand,
    instruction: DoryX86DecodedInstruction,
    state: DoryX86ArchitecturalState
  ) -> UInt64 {
    var address = operand.ripRelative ? instruction.nextInstructionAddress : 0
    if let base = operand.base { address &+= state.registers[base] }
    if let index = operand.index { address &+= state.registers[index] &* UInt64(operand.scale) }
    address &+= UInt64(bitPattern: operand.displacement)
    if instruction.prefixes.addressSizeOverride { address &= 0xffff_ffff }
    return address
  }

  private func executeALU(
    _ operation: DoryX86ALUOperation,
    lhs: UInt64,
    rhs: UInt64,
    width: DoryX86OperandWidth,
    flags: inout DoryX86RFLAGS
  ) -> UInt64 {
    let widthMask = mask(width)
    let left = lhs & widthMask
    let right = rhs & widthMask
    let result: UInt64
    switch operation {
    case .add:
      result = (left &+ right) & widthMask
      setFlag(.carry, left > widthMask &- right, in: &flags)
      setFlag(.overflow, ((~(left ^ right) & (left ^ result)) & signBit(width)) != 0, in: &flags)
      setFlag(.auxiliaryCarry, ((left ^ right ^ result) & 0x10) != 0, in: &flags)
    case .subtract, .compare:
      result = (left &- right) & widthMask
      setFlag(.carry, left < right, in: &flags)
      setFlag(.overflow, (((left ^ right) & (left ^ result)) & signBit(width)) != 0, in: &flags)
      setFlag(.auxiliaryCarry, ((left ^ right ^ result) & 0x10) != 0, in: &flags)
    case .and, .test:
      result = left & right
      clearLogicalArithmeticFlags(&flags)
    case .or:
      result = left | right
      clearLogicalArithmeticFlags(&flags)
    case .xor:
      result = left ^ right
      clearLogicalArithmeticFlags(&flags)
    }
    setFlag(.zero, result == 0, in: &flags)
    setFlag(.sign, result & signBit(width) != 0, in: &flags)
    setFlag(.parity, (result & 0xff).nonzeroBitCount.isMultiple(of: 2), in: &flags)
    flags.insert(.reservedOne)
    return result
  }

  private func evaluate(_ condition: DoryX86Condition, flags: DoryX86RFLAGS) -> Bool {
    let overflow = flags.contains(.overflow)
    let carry = flags.contains(.carry)
    let zero = flags.contains(.zero)
    let sign = flags.contains(.sign)
    let parity = flags.contains(.parity)
    return switch condition {
    case .overflow: overflow
    case .notOverflow: !overflow
    case .below: carry
    case .aboveOrEqual: !carry
    case .equal: zero
    case .notEqual: !zero
    case .belowOrEqual: carry || zero
    case .above: !carry && !zero
    case .sign: sign
    case .notSign: !sign
    case .parity: parity
    case .notParity: !parity
    case .less: sign != overflow
    case .greaterOrEqual: sign == overflow
    case .lessOrEqual: zero || sign != overflow
    case .greater: !zero && sign == overflow
    }
  }

  private func operandWidth(_ operand: DoryX86Operand) -> DoryX86OperandWidth {
    switch operand {
    case .register(_, let width), .immediate(_, let width), .relative(_, let width): width
    case .memory(let memory): memory.width
    }
  }

  private func mask(_ width: DoryX86OperandWidth) -> UInt64 {
    width == .quadword ? .max : (UInt64(1) << width.rawValue) - 1
  }

  private func signBit(_ width: DoryX86OperandWidth) -> UInt64 { UInt64(1) << (width.rawValue - 1) }

  private func littleEndian(_ value: UInt64, width: DoryX86OperandWidth) -> [UInt8] {
    (0..<width.byteCount).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
  }

  private func fromLittleEndian(_ bytes: [UInt8]) -> UInt64 {
    bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << UInt64($1.offset * 8) }
  }

  private func addRelative(_ address: UInt64, _ displacement: Int64) -> UInt64 {
    address &+ UInt64(bitPattern: displacement)
  }

  private func setFlag(_ flag: DoryX86RFLAGS, _ enabled: Bool, in flags: inout DoryX86RFLAGS) {
    if enabled { flags.insert(flag) } else { flags.remove(flag) }
  }

  private func clearLogicalArithmeticFlags(_ flags: inout DoryX86RFLAGS) {
    flags.remove([.carry, .overflow, .auxiliaryCarry])
  }

  private func pageFault(
    for error: DoryX86MemoryError,
    instructionPointer: UInt64
  ) -> DoryX86Exception {
    switch error {
    case .unmapped(let address, _, let access):
      var code: UInt32 = 0
      if access == .write { code |= 1 << 1 }
      if access == .instructionFetch { code |= 1 << 4 }
      return .init(
        kind: .pageFault,
        vector: 14,
        errorCode: code,
        instructionPointer: instructionPointer,
        linearAddress: address
      )
    case .addressOverflow(let address, _):
      return .init(
        kind: .generalProtection,
        vector: 13,
        errorCode: 0,
        instructionPointer: instructionPointer,
        linearAddress: address
      )
    case .pageFault(let address, let errorCode):
      return .init(
        kind: .pageFault,
        vector: 14,
        errorCode: errorCode,
        instructionPointer: instructionPointer,
        linearAddress: address
      )
    }
  }
}
