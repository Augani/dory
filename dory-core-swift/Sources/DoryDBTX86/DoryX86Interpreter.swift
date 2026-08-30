import Foundation

public struct DoryX86Exception: Error, Codable, Sendable, Hashable {
  public enum Kind: String, Codable, Sendable, Hashable {
    case divideError
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
      case .unary(let operation, let operand):
        let value = try read(
          operand, instruction: instruction, state: state, memory: executionMemory)
        let width = operandWidth(operand)
        let result: UInt64
        switch operation {
        case .increment:
          let carry = state.rflags.contains(.carry)
          result = executeALU(.add, lhs: value, rhs: 1, width: width, flags: &state.rflags)
          setFlag(.carry, carry, in: &state.rflags)
        case .decrement:
          let carry = state.rflags.contains(.carry)
          result = executeALU(
            .subtract, lhs: value, rhs: 1, width: width, flags: &state.rflags)
          setFlag(.carry, carry, in: &state.rflags)
        case .bitwiseNot:
          result = ~value & mask(width)
        case .negate:
          result = executeALU(
            .subtract, lhs: 0, rhs: value, width: width, flags: &state.rflags)
        }
        try write(
          result, to: operand, instruction: instruction, state: &state, memory: executionMemory)
      case .shift(let operation, let destination, let countSource):
        let value = try read(
          destination, instruction: instruction, state: state, memory: executionMemory)
        let count: UInt8 =
          switch countSource {
          case .immediate(let value): value
          case .cl: UInt8(truncatingIfNeeded: state.registers.rcx)
          }
        let result = executeShift(
          operation,
          value: value,
          count: count,
          width: operandWidth(destination),
          flags: &state.rflags
        )
        try write(
          result,
          to: destination,
          instruction: instruction,
          state: &state,
          memory: executionMemory
        )
      case .extendMove(let destination, let source, let signed):
        let value = try read(
          source, instruction: instruction, state: state, memory: executionMemory)
        let extended =
          signed
          ? UInt64(bitPattern: signExtendedInt64(value, width: operandWidth(source)))
          : value
        try write(
          extended,
          to: destination,
          instruction: instruction,
          state: &state,
          memory: executionMemory
        )
      case .conditionalMove(let condition, let destination, let source):
        let value = try read(
          source, instruction: instruction, state: state, memory: executionMemory)
        if evaluate(condition, flags: state.rflags) {
          try write(
            value,
            to: destination,
            instruction: instruction,
            state: &state,
            memory: executionMemory
          )
        }
      case .setCondition(let condition, let destination):
        try write(
          evaluate(condition, flags: state.rflags) ? 1 : 0,
          to: destination,
          instruction: instruction,
          state: &state,
          memory: executionMemory
        )
      case .signedMultiply(let destination, let lhs, let rhs):
        let left = try read(lhs, instruction: instruction, state: state, memory: executionMemory)
        let right = try read(rhs, instruction: instruction, state: state, memory: executionMemory)
        let width = operandWidth(destination)
        let multiply = signedMultiply(left, right, width: width)
        setFlag(.carry, multiply.overflow, in: &state.rflags)
        setFlag(.overflow, multiply.overflow, in: &state.rflags)
        try write(
          multiply.low,
          to: destination,
          instruction: instruction,
          state: &state,
          memory: executionMemory
        )
      case .accumulatorArithmetic(let operation, let source):
        let value = try read(
          source, instruction: instruction, state: state, memory: executionMemory)
        let succeeded = executeAccumulatorArithmetic(
          operation,
          source: value,
          width: operandWidth(source),
          state: &state
        )
        guard succeeded else {
          return .exception(
            .init(kind: .divideError, vector: 0, instructionPointer: originalRIP))
        }
      case .signExtendAccumulator(let width, let intoHighHalf):
        signExtendAccumulator(width: width, intoHighHalf: intoHighHalf, state: &state)
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
      case .callIndirect(let operand):
        let target = try read(
          operand, instruction: instruction, state: state, memory: executionMemory)
        let width = stackWidth(mode)
        state.registers.rsp &-= UInt64(width.byteCount)
        try executionMemory.write(
          at: state.registers.rsp, bytes: littleEndian(nextRIP, width: width))
        nextRIP = target
      case .return:
        let stackWidth: DoryX86OperandWidth =
          mode == .long64 ? .quadword : (mode == .real16 ? .word : .doubleword)
        nextRIP = fromLittleEndian(
          try executionMemory.read(at: state.registers.rsp, byteCount: stackWidth.byteCount))
        state.registers.rsp &+= UInt64(stackWidth.byteCount)
      case .jump(let relative):
        nextRIP = addRelative(nextRIP, relative)
      case .jumpIndirect(let operand):
        nextRIP = try read(
          operand, instruction: instruction, state: state, memory: executionMemory)
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
      case .pushFlags(let width):
        state.registers.rsp &-= UInt64(width.byteCount)
        try executionMemory.write(
          at: state.registers.rsp,
          bytes: littleEndian(state.rflags.rawValue, width: width)
        )
      case .popFlags(let width):
        let raw = fromLittleEndian(
          try executionMemory.read(at: state.registers.rsp, byteCount: width.byteCount))
        var requested = DoryX86RFLAGS(
          rawValue: (raw & DoryX86RFLAGS.architecturallyWritableMask) | 2)
        if currentPrivilegeLevel(state) > UInt8((state.rflags.rawValue >> 12) & 3) {
          setFlag(.interruptEnable, state.rflags.contains(.interruptEnable), in: &requested)
        }
        guard let validated = try? requested.validated() else {
          return generalProtection(at: originalRIP)
        }
        state.rflags = validated
        state.registers.rsp &+= UInt64(width.byteCount)
      case .leave(let width):
        state.registers.rsp = state.registers.rbp
        state.registers.rbp = fromLittleEndian(
          try executionMemory.read(at: state.registers.rsp, byteCount: width.byteCount))
        state.registers.rsp &+= UInt64(width.byteCount)
      case .setCarry(let enabled):
        setFlag(.carry, enabled, in: &state.rflags)
      case .complementCarry:
        setFlag(.carry, !state.rflags.contains(.carry), in: &state.rflags)
      case .setDirection(let enabled):
        setFlag(.direction, enabled, in: &state.rflags)
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
    case .highByteRegister(let register):
      return (state.registers[register] >> 8) & 0xff
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
    case .highByteRegister(let register):
      state.registers[register] =
        (state.registers[register] & ~UInt64(0xff00)) | ((value & 0xff) << 8)
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
    case .addWithCarry:
      let carry = flags.contains(.carry) ? UInt64(1) : 0
      let first = left.addingReportingOverflow(right)
      let second = first.partialValue.addingReportingOverflow(carry)
      result = second.partialValue & widthMask
      setFlag(
        .carry,
        first.overflow || second.overflow || first.partialValue > widthMask
          || second.partialValue > widthMask,
        in: &flags
      )
      setFlag(
        .overflow,
        ((~(left ^ right) & (left ^ result)) & signBit(width)) != 0,
        in: &flags
      )
      setFlag(
        .auxiliaryCarry,
        (left & 0xf) + (right & 0xf) + carry > 0xf,
        in: &flags
      )
    case .subtract, .compare:
      result = (left &- right) & widthMask
      setFlag(.carry, left < right, in: &flags)
      setFlag(.overflow, (((left ^ right) & (left ^ result)) & signBit(width)) != 0, in: &flags)
      setFlag(.auxiliaryCarry, ((left ^ right ^ result) & 0x10) != 0, in: &flags)
    case .subtractWithBorrow:
      let borrow = flags.contains(.carry) ? UInt64(1) : 0
      result = (left &- right &- borrow) & widthMask
      setFlag(.carry, left < right || (borrow == 1 && left == right), in: &flags)
      setFlag(
        .overflow,
        (((left ^ right) & (left ^ result)) & signBit(width)) != 0,
        in: &flags
      )
      setFlag(
        .auxiliaryCarry,
        (left & 0xf) < (right & 0xf) + borrow,
        in: &flags
      )
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

  private func executeShift(
    _ operation: DoryX86ShiftOperation,
    value: UInt64,
    count rawCount: UInt8,
    width: DoryX86OperandWidth,
    flags: inout DoryX86RFLAGS
  ) -> UInt64 {
    let bitCount = Int(width.rawValue)
    let countMask: UInt8 = width == .quadword ? 0x3f : 0x1f
    var count = Int(rawCount & countMask)
    let widthMask = mask(width)
    var result = value & widthMask
    guard count != 0 else { return result }

    switch operation {
    case .rotateLeft:
      count %= bitCount
      guard count != 0 else { return result }
      result = ((result << count) | (result >> (bitCount - count))) & widthMask
      setFlag(.carry, result & 1 != 0, in: &flags)
      if count == 1 {
        setFlag(
          .overflow,
          (result & signBit(width) != 0) != flags.contains(.carry),
          in: &flags
        )
      }
    case .rotateRight:
      count %= bitCount
      guard count != 0 else { return result }
      result = ((result >> count) | (result << (bitCount - count))) & widthMask
      setFlag(.carry, result & signBit(width) != 0, in: &flags)
      if count == 1 {
        let topTwo = (result >> UInt64(bitCount - 2)) & 3
        setFlag(.overflow, topTwo == 1 || topTwo == 2, in: &flags)
      }
    case .rotateCarryLeft:
      count %= bitCount + 1
      guard count != 0 else { return result }
      for _ in 0..<count {
        let outgoing = result & signBit(width) != 0
        result = ((result << 1) | (flags.contains(.carry) ? 1 : 0)) & widthMask
        setFlag(.carry, outgoing, in: &flags)
      }
      if count == 1 {
        setFlag(
          .overflow,
          (result & signBit(width) != 0) != flags.contains(.carry),
          in: &flags
        )
      }
    case .rotateCarryRight:
      count %= bitCount + 1
      guard count != 0 else { return result }
      for _ in 0..<count {
        let outgoing = result & 1 != 0
        result = (result >> 1) | (flags.contains(.carry) ? signBit(width) : 0)
        setFlag(.carry, outgoing, in: &flags)
      }
      if count == 1 {
        let topTwo = (result >> UInt64(bitCount - 2)) & 3
        setFlag(.overflow, topTwo == 1 || topTwo == 2, in: &flags)
      }
    case .shiftLeft:
      if count <= bitCount {
        setFlag(.carry, result & (UInt64(1) << UInt64(bitCount - count)) != 0, in: &flags)
      } else {
        flags.remove(.carry)
      }
      result = count < bitCount ? (result << count) & widthMask : 0
      if count == 1 {
        setFlag(
          .overflow,
          (result & signBit(width) != 0) != flags.contains(.carry),
          in: &flags
        )
      }
      setShiftResultFlags(result, width: width, flags: &flags)
    case .shiftRight:
      if count <= bitCount {
        setFlag(.carry, result & (UInt64(1) << UInt64(count - 1)) != 0, in: &flags)
      } else {
        flags.remove(.carry)
      }
      let originalSign = result & signBit(width) != 0
      result = count < bitCount ? result >> count : 0
      if count == 1 { setFlag(.overflow, originalSign, in: &flags) }
      setShiftResultFlags(result, width: width, flags: &flags)
    case .arithmeticShiftRight:
      if count <= bitCount {
        setFlag(.carry, result & (UInt64(1) << UInt64(count - 1)) != 0, in: &flags)
      } else {
        setFlag(.carry, result & signBit(width) != 0, in: &flags)
      }
      let signed = signExtendedInt64(result, width: width)
      result =
        UInt64(bitPattern: count < bitCount ? signed >> count : signed >> (bitCount - 1))
        & widthMask
      if count == 1 { flags.remove(.overflow) }
      setShiftResultFlags(result, width: width, flags: &flags)
    }
    return result
  }

  private func setShiftResultFlags(
    _ result: UInt64,
    width: DoryX86OperandWidth,
    flags: inout DoryX86RFLAGS
  ) {
    setFlag(.zero, result == 0, in: &flags)
    setFlag(.sign, result & signBit(width) != 0, in: &flags)
    setFlag(.parity, (result & 0xff).nonzeroBitCount.isMultiple(of: 2), in: &flags)
    flags.remove(.auxiliaryCarry)
    flags.insert(.reservedOne)
  }

  private func signedMultiply(
    _ lhs: UInt64,
    _ rhs: UInt64,
    width: DoryX86OperandWidth
  ) -> (low: UInt64, overflow: Bool) {
    let left = signExtendedInt64(lhs, width: width)
    let right = signExtendedInt64(rhs, width: width)
    if width == .quadword {
      let product = left.multipliedFullWidth(by: right)
      let expectedHigh: Int64 = product.low & (1 << 63) == 0 ? 0 : -1
      return (product.low, product.high != expectedHigh)
    }
    let product = left * right
    let low = UInt64(bitPattern: product) & mask(width)
    return (low, signExtendedInt64(low, width: width) != product)
  }

  private func executeAccumulatorArithmetic(
    _ operation: DoryX86AccumulatorArithmeticOperation,
    source: UInt64,
    width: DoryX86OperandWidth,
    state: inout DoryX86ArchitecturalState
  ) -> Bool {
    switch operation {
    case .unsignedMultiply:
      let lhs = accumulatorLow(width: width, state: state)
      let product: (high: UInt64, low: UInt64)
      if width == .quadword {
        product = lhs.multipliedFullWidth(by: source)
      } else {
        let full = lhs * (source & mask(width))
        product = (full >> UInt64(width.rawValue), full & mask(width))
      }
      writeAccumulatorProduct(low: product.low, high: product.high, width: width, state: &state)
      let overflow = product.high != 0
      setFlag(.carry, overflow, in: &state.rflags)
      setFlag(.overflow, overflow, in: &state.rflags)
      return true
    case .signedMultiply:
      let lhs = signExtendedInt64(accumulatorLow(width: width, state: state), width: width)
      let rhs = signExtendedInt64(source, width: width)
      let high: UInt64
      let low: UInt64
      let overflow: Bool
      if width == .quadword {
        let product = lhs.multipliedFullWidth(by: rhs)
        low = product.low
        high = UInt64(bitPattern: product.high)
        overflow = product.high != (product.low & (1 << 63) == 0 ? 0 : -1)
      } else {
        let product = lhs * rhs
        low = UInt64(bitPattern: product) & mask(width)
        high = UInt64(bitPattern: product >> Int64(width.rawValue)) & mask(width)
        overflow = signExtendedInt64(low, width: width) != product
      }
      writeAccumulatorProduct(low: low, high: high, width: width, state: &state)
      setFlag(.carry, overflow, in: &state.rflags)
      setFlag(.overflow, overflow, in: &state.rflags)
      return true
    case .unsignedDivide:
      return executeUnsignedDivide(source: source, width: width, state: &state)
    case .signedDivide:
      return executeSignedDivide(source: source, width: width, state: &state)
    }
  }

  private func executeUnsignedDivide(
    source: UInt64,
    width: DoryX86OperandWidth,
    state: inout DoryX86ArchitecturalState
  ) -> Bool {
    let divisor = source & mask(width)
    guard divisor != 0 else { return false }
    let low = accumulatorLow(width: width, state: state)
    let high = accumulatorHigh(width: width, state: state)
    let quotient: UInt64
    let remainder: UInt64
    if width == .quadword {
      guard high < divisor else { return false }
      let result = divisor.dividingFullWidth((high: high, low: low))
      quotient = result.quotient
      remainder = result.remainder
    } else {
      let dividend = (high << UInt64(width.rawValue)) | low
      quotient = dividend / divisor
      remainder = dividend % divisor
      guard quotient <= mask(width) else { return false }
    }
    writeAccumulatorDivision(
      quotient: quotient, remainder: remainder, width: width, state: &state)
    return true
  }

  private func executeSignedDivide(
    source: UInt64,
    width: DoryX86OperandWidth,
    state: inout DoryX86ArchitecturalState
  ) -> Bool {
    let divisor = signExtendedInt64(source, width: width)
    guard divisor != 0 else { return false }
    let quotient: Int64
    let remainder: Int64
    if width == .quadword {
      guard
        let result = signedDivide128(
          high: accumulatorHigh(width: width, state: state),
          low: accumulatorLow(width: width, state: state),
          divisor: divisor
        )
      else { return false }
      quotient = result.quotient
      remainder = result.remainder
    } else {
      let bits = Int(width.rawValue)
      let combined =
        (accumulatorHigh(width: width, state: state) << UInt64(bits))
        | accumulatorLow(width: width, state: state)
      let dividend: Int64 =
        switch width {
        case .byte: Int64(Int16(bitPattern: UInt16(truncatingIfNeeded: combined)))
        case .word: Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: combined)))
        case .doubleword: Int64(bitPattern: combined)
        case .quadword: preconditionFailure()
        }
      let division = dividend.dividedReportingOverflow(by: divisor)
      guard !division.overflow else { return false }
      quotient = division.partialValue
      remainder = dividend.remainderReportingOverflow(dividingBy: divisor).partialValue
      let minimum = -(Int64(1) << Int64(bits - 1))
      let maximum = (Int64(1) << Int64(bits - 1)) - 1
      guard (minimum...maximum).contains(quotient) else { return false }
    }
    writeAccumulatorDivision(
      quotient: UInt64(bitPattern: quotient),
      remainder: UInt64(bitPattern: remainder),
      width: width,
      state: &state
    )
    return true
  }

  private func signedDivide128(
    high: UInt64,
    low: UInt64,
    divisor: Int64
  ) -> (quotient: Int64, remainder: Int64)? {
    let dividendNegative = high & (1 << 63) != 0
    let divisorNegative = divisor < 0
    let magnitudeHigh: UInt64
    let magnitudeLow: UInt64
    if dividendNegative {
      magnitudeLow = ~low &+ 1
      magnitudeHigh = ~high &+ (magnitudeLow == 0 ? 1 : 0)
    } else {
      magnitudeHigh = high
      magnitudeLow = low
    }
    let divisorBits = UInt64(bitPattern: divisor)
    let divisorMagnitude = divisorNegative ? ~divisorBits &+ 1 : divisorBits
    guard divisorMagnitude != 0, magnitudeHigh < divisorMagnitude else { return nil }
    let result = divisorMagnitude.dividingFullWidth((high: magnitudeHigh, low: magnitudeLow))
    let quotientNegative = dividendNegative != divisorNegative
    let limit: UInt64 = quotientNegative ? 1 << 63 : UInt64(Int64.max)
    guard result.quotient <= limit else { return nil }
    let quotientBits = quotientNegative ? ~result.quotient &+ 1 : result.quotient
    let remainderBits = dividendNegative ? ~result.remainder &+ 1 : result.remainder
    return (Int64(bitPattern: quotientBits), Int64(bitPattern: remainderBits))
  }

  private func accumulatorLow(
    width: DoryX86OperandWidth,
    state: DoryX86ArchitecturalState
  ) -> UInt64 {
    state.registers.rax & mask(width)
  }

  private func accumulatorHigh(
    width: DoryX86OperandWidth,
    state: DoryX86ArchitecturalState
  ) -> UInt64 {
    if width == .byte { return (state.registers.rax >> 8) & 0xff }
    return state.registers.rdx & mask(width)
  }

  private func writeAccumulatorProduct(
    low: UInt64,
    high: UInt64,
    width: DoryX86OperandWidth,
    state: inout DoryX86ArchitecturalState
  ) {
    writeAccumulatorDivision(quotient: low, remainder: high, width: width, state: &state)
  }

  private func writeAccumulatorDivision(
    quotient: UInt64,
    remainder: UInt64,
    width: DoryX86OperandWidth,
    state: inout DoryX86ArchitecturalState
  ) {
    switch width {
    case .byte:
      state.registers.rax =
        (state.registers.rax & ~UInt64(0xffff))
        | (quotient & 0xff)
        | ((remainder & 0xff) << 8)
    case .word:
      state.registers.rax = (state.registers.rax & ~UInt64(0xffff)) | (quotient & 0xffff)
      state.registers.rdx = (state.registers.rdx & ~UInt64(0xffff)) | (remainder & 0xffff)
    case .doubleword:
      state.registers.rax = quotient & 0xffff_ffff
      state.registers.rdx = remainder & 0xffff_ffff
    case .quadword:
      state.registers.rax = quotient
      state.registers.rdx = remainder
    }
  }

  private func signExtendAccumulator(
    width: DoryX86OperandWidth,
    intoHighHalf: Bool,
    state: inout DoryX86ArchitecturalState
  ) {
    if intoHighHalf {
      let sign = accumulatorLow(width: width, state: state) & signBit(width) != 0
      let high = sign ? mask(width) : 0
      if width == .byte {
        state.registers.rax = (state.registers.rax & ~UInt64(0xff00)) | (high << 8)
      } else if width == .word {
        state.registers.rdx = (state.registers.rdx & ~UInt64(0xffff)) | high
      } else if width == .doubleword {
        state.registers.rdx = high
      } else {
        state.registers.rdx = high
      }
      return
    }
    switch width {
    case .byte:
      break
    case .word:
      let value = UInt64(bitPattern: Int64(Int8(bitPattern: UInt8(state.registers.rax))))
      state.registers.rax = (state.registers.rax & ~UInt64(0xffff)) | (value & 0xffff)
    case .doubleword:
      state.registers.rax = UInt64(
        UInt32(bitPattern: Int32(Int16(bitPattern: UInt16(state.registers.rax)))))
    case .quadword:
      state.registers.rax = UInt64(
        bitPattern: Int64(Int32(bitPattern: UInt32(state.registers.rax))))
    }
  }

  private func signExtendedInt64(_ value: UInt64, width: DoryX86OperandWidth) -> Int64 {
    switch width {
    case .byte: Int64(Int8(bitPattern: UInt8(truncatingIfNeeded: value)))
    case .word: Int64(Int16(bitPattern: UInt16(truncatingIfNeeded: value)))
    case .doubleword: Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: value)))
    case .quadword: Int64(bitPattern: value)
    }
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
    case .highByteRegister: .byte
    case .memory(let memory): memory.width
    }
  }

  private func stackWidth(_ mode: DoryX86ExecutionMode) -> DoryX86OperandWidth {
    switch mode {
    case .real16: .word
    case .protected32: .doubleword
    case .long64: .quadword
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
