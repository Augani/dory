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
    var candidate = state
    let result = executeStep(
      state: &candidate,
      memory: memory,
      mode: mode,
      pagingUnit: pagingUnit
    )
    switch result {
    case .retired, .halted:
      state = candidate
    case .exception(let exception):
      if exception.kind == .pageFault {
        state.control.cr2 = exception.linearAddress ?? 0
      }
    }
    return result
  }

  private func executeStep(
    state: inout DoryX86ArchitecturalState,
    memory: any DoryX86Memory,
    mode: DoryX86ExecutionMode,
    pagingUnit: DoryX86PagingUnit?
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
      case .readControlRegister(let index, let destination):
        guard currentPrivilegeLevel(state) == 0,
          let value = readControlRegister(index, state: state)
        else {
          return generalProtection(at: originalRIP)
        }
        state.registers[destination] = value
      case .writeControlRegister(let index, let source):
        guard currentPrivilegeLevel(state) == 0,
          writeControlRegister(
            index,
            value: state.registers[source],
            state: &state,
            pagingUnit: pagingUnit
          )
        else {
          return generalProtection(at: originalRIP)
        }
      case .invalidatePage(let operand):
        guard currentPrivilegeLevel(state) == 0 else {
          return generalProtection(at: originalRIP)
        }
        pagingUnit?.invalidate(
          linearAddress: effectiveAddress(operand, instruction: instruction, state: state)
        )
      case .readModelSpecificRegister:
        guard currentPrivilegeLevel(state) == 0,
          let value = readModelSpecificRegister(
            UInt32(truncatingIfNeeded: state.registers.rcx),
            state: state
          )
        else {
          return generalProtection(at: originalRIP)
        }
        state.registers.rax = UInt64(UInt32(truncatingIfNeeded: value))
        state.registers.rdx = UInt64(UInt32(truncatingIfNeeded: value >> 32))
      case .writeModelSpecificRegister:
        let value =
          UInt64(UInt32(truncatingIfNeeded: state.registers.rax))
          | UInt64(UInt32(truncatingIfNeeded: state.registers.rdx)) << 32
        guard currentPrivilegeLevel(state) == 0,
          writeModelSpecificRegister(
            UInt32(truncatingIfNeeded: state.registers.rcx),
            value: value,
            state: &state,
            pagingUnit: pagingUnit
          )
        else {
          return generalProtection(at: originalRIP)
        }
      case .readTimestampCounter(let includeAuxiliary):
        guard currentPrivilegeLevel(state) == 0 || state.control.cr4 & (1 << 2) == 0 else {
          return generalProtection(at: originalRIP)
        }
        state.registers.rax = UInt64(UInt32(truncatingIfNeeded: state.tsc))
        state.registers.rdx = UInt64(UInt32(truncatingIfNeeded: state.tsc >> 32))
        if includeAuxiliary { state.registers.rcx = UInt64(state.tscAux) }
      case .swapGS:
        guard currentPrivilegeLevel(state) == 0 else {
          return generalProtection(at: originalRIP)
        }
        state.modelSpecific.gsBase = state.gs.base
        swap(&state.modelSpecific.gsBase, &state.modelSpecific.kernelGSBase)
        state.gs.base = state.modelSpecific.gsBase
      case .softwareInterrupt(let vector):
        do {
          try DoryX86InterruptDelivery().deliver(
            vector: vector,
            source: .software,
            returnInstructionPointer: nextRIP,
            state: &state,
            physicalMemory: memory,
            pagingUnit: pagingUnit,
            mode: mode
          )
          return .retired(instruction)
        } catch {
          state.rip = originalRIP
          return generalProtection(at: originalRIP)
        }
      case .interruptReturn:
        do {
          try DoryX86InterruptDelivery().interruptReturn(
            state: &state,
            physicalMemory: memory,
            pagingUnit: pagingUnit,
            mode: mode
          )
          return .retired(instruction)
        } catch {
          state.rip = originalRIP
          return generalProtection(at: originalRIP)
        }
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
        guard profile.supports(.syscall),
          mode == .long64,
          state.control.efer & 1 != 0,
          DoryX86ArchitecturalState.isCanonical(state.modelSpecific.longStar)
        else {
          return .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: originalRIP))
        }
        state.registers.rcx = nextRIP
        state.registers.r11 = state.rflags.rawValue
        state.rflags = DoryX86RFLAGS(
          rawValue: (state.rflags.rawValue & ~state.modelSpecific.syscallFlagMask) | 2
        )
        let selector = UInt16(truncatingIfNeeded: state.modelSpecific.star >> 32) & 0xfffc
        state.cs = .init(selector: selector, attributes: 0xA09B, limit: .max, base: 0)
        state.ss = .init(selector: selector &+ 8, attributes: 0xC093, limit: .max, base: 0)
        nextRIP = state.modelSpecific.longStar
      case .sysret:
        guard profile.supports(.syscall),
          mode == .long64,
          currentPrivilegeLevel(state) == 0,
          state.control.efer & 1 != 0,
          DoryX86ArchitecturalState.isCanonical(state.registers.rcx)
        else {
          return generalProtection(at: originalRIP)
        }
        let requestedFlags = DoryX86RFLAGS(
          rawValue: (state.registers.r11 & DoryX86RFLAGS.architecturallyWritableMask) | 2
        )
        guard let validatedFlags = try? requestedFlags.validated() else {
          return generalProtection(at: originalRIP)
        }
        state.rflags = validatedFlags
        let selector = UInt16(truncatingIfNeeded: state.modelSpecific.star >> 48) & 0xfffc
        state.cs = .init(selector: (selector &+ 16) | 3, attributes: 0xA0FB, limit: .max, base: 0)
        state.ss = .init(selector: (selector &+ 8) | 3, attributes: 0xC0F3, limit: .max, base: 0)
        nextRIP = state.registers.rcx
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

  private func currentPrivilegeLevel(_ state: DoryX86ArchitecturalState) -> UInt8 {
    UInt8(state.cs.selector & 3)
  }

  private func generalProtection(at instructionPointer: UInt64) -> DoryX86InterpreterResult {
    .exception(
      .init(
        kind: .generalProtection,
        vector: 13,
        errorCode: 0,
        instructionPointer: instructionPointer
      )
    )
  }

  private func readControlRegister(
    _ index: UInt8,
    state: DoryX86ArchitecturalState
  ) -> UInt64? {
    switch index {
    case 0: state.control.cr0
    case 2: state.control.cr2
    case 3: state.control.cr3
    case 4: state.control.cr4
    case 8: state.control.cr8
    default: nil
    }
  }

  private func writeControlRegister(
    _ index: UInt8,
    value: UInt64,
    state: inout DoryX86ArchitecturalState,
    pagingUnit: DoryX86PagingUnit?
  ) -> Bool {
    switch index {
    case 0:
      let paging = value & (1 << 31) != 0
      let protectedMode = value & 1 != 0
      let cacheDisable = value & (1 << 30) != 0
      let notWriteThrough = value & (1 << 29) != 0
      guard value & (1 << 4) != 0,
        !paging || protectedMode,
        !notWriteThrough || cacheDisable
      else { return false }
      let wasPaging = state.control.cr0 & (1 << 31) != 0
      if paging, !wasPaging, state.control.efer & (1 << 8) != 0 {
        guard state.control.cr4 & (1 << 5) != 0 else { return false }
        state.control.efer |= 1 << 10
      } else if !paging {
        state.control.efer &= ~(1 << 10)
      }
      state.control.cr0 = value
      pagingUnit?.invalidateAll()
      return true
    case 2:
      state.control.cr2 = value
      return true
    case 3:
      let pcidEnabled = state.control.cr4 & (1 << 17) != 0
      let allowedLowMask: UInt64 = pcidEnabled ? 0xfff : 0x18
      let noFlush = value & (1 << 63) != 0
      let addressMask = ((UInt64(1) << profile.physicalAddressBits) - 1) & ~0xfff
      let storedValue = value & ~(1 << 63)
      guard !noFlush || pcidEnabled,
        storedValue & ~addressMask & ~allowedLowMask == 0,
        storedValue & 0xfff & ~allowedLowMask == 0
      else { return false }
      state.control.cr3 = storedValue
      if !noFlush { pagingUnit?.invalidateAll() }
      return true
    case 4:
      let supportedMask: UInt64 =
        (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5) | (1 << 7) | (1 << 8)
        | (1 << 17) | (1 << 20) | (1 << 21)
      guard value & ~supportedMask == 0 else { return false }
      state.control.cr4 = value
      pagingUnit?.invalidateAll()
      return true
    case 8:
      guard value <= 15 else { return false }
      state.control.cr8 = value
      return true
    default:
      return false
    }
  }

  private func readModelSpecificRegister(
    _ index: UInt32,
    state: DoryX86ArchitecturalState
  ) -> UInt64? {
    switch index {
    case 0x10: state.tsc
    case 0x1B: state.modelSpecific.apicBase
    case 0x174: state.modelSpecific.systemEnterCS
    case 0x175: state.modelSpecific.systemEnterStackPointer
    case 0x176: state.modelSpecific.systemEnterInstructionPointer
    case 0x277: state.modelSpecific.pageAttributeTable
    case 0xC000_0080: state.control.efer
    case 0xC000_0081: state.modelSpecific.star
    case 0xC000_0082: state.modelSpecific.longStar
    case 0xC000_0083: state.modelSpecific.compatibilityStar
    case 0xC000_0084: state.modelSpecific.syscallFlagMask
    case 0xC000_0100: state.modelSpecific.fsBase
    case 0xC000_0101: state.modelSpecific.gsBase
    case 0xC000_0102: state.modelSpecific.kernelGSBase
    case 0xC000_0103: UInt64(state.tscAux)
    default: nil
    }
  }

  private func writeModelSpecificRegister(
    _ index: UInt32,
    value: UInt64,
    state: inout DoryX86ArchitecturalState,
    pagingUnit: DoryX86PagingUnit?
  ) -> Bool {
    switch index {
    case 0x10:
      state.tsc = value
    case 0x1B:
      guard value & 0xfff & ~0x900 == 0 else { return false }
      state.modelSpecific.apicBase = value
    case 0x174:
      state.modelSpecific.systemEnterCS = value & 0xffff
    case 0x175:
      state.modelSpecific.systemEnterStackPointer = value
    case 0x176:
      state.modelSpecific.systemEnterInstructionPointer = value
    case 0x277:
      guard validPageAttributeTable(value) else { return false }
      state.modelSpecific.pageAttributeTable = value
    case 0xC000_0080:
      let writableMask: UInt64 = (1 << 0) | (1 << 8) | (1 << 11)
      guard value & ~(writableMask | (1 << 10)) == 0,
        value & (1 << 10) == state.control.efer & (1 << 10),
        state.control.cr0 & (1 << 31) == 0
          || value & (1 << 8) == state.control.efer & (1 << 8)
      else { return false }
      state.control.efer = (state.control.efer & (1 << 10)) | (value & writableMask)
      pagingUnit?.invalidateAll()
    case 0xC000_0081:
      state.modelSpecific.star = value
    case 0xC000_0082:
      guard DoryX86ArchitecturalState.isCanonical(value) else { return false }
      state.modelSpecific.longStar = value
    case 0xC000_0083:
      guard DoryX86ArchitecturalState.isCanonical(value) else { return false }
      state.modelSpecific.compatibilityStar = value
    case 0xC000_0084:
      state.modelSpecific.syscallFlagMask = value & DoryX86RFLAGS.architecturallyWritableMask
    case 0xC000_0100:
      guard DoryX86ArchitecturalState.isCanonical(value) else { return false }
      state.modelSpecific.fsBase = value
      state.fs.base = value
    case 0xC000_0101:
      guard DoryX86ArchitecturalState.isCanonical(value) else { return false }
      state.modelSpecific.gsBase = value
      state.gs.base = value
    case 0xC000_0102:
      guard DoryX86ArchitecturalState.isCanonical(value) else { return false }
      state.modelSpecific.kernelGSBase = value
    case 0xC000_0103:
      state.tscAux = UInt32(truncatingIfNeeded: value)
    default:
      return false
    }
    return true
  }

  private func validPageAttributeTable(_ value: UInt64) -> Bool {
    (0..<8).allSatisfy { index in
      let memoryType = UInt8(truncatingIfNeeded: value >> UInt64(index * 8))
      return [0, 1, 4, 5, 6, 7].contains(memoryType)
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
