import Foundation

public struct DoryX86Exception: Error, Codable, Sendable, Hashable {
  public enum Kind: String, Codable, Sendable, Hashable {
    case divideError
    case debug
    case invalidOpcode
    case deviceNotAvailable
    case segmentNotPresent
    case stackSegment
    case generalProtection
    case pageFault
    case simdFloatingPoint
    case x87FloatingPoint
  }

  public let kind: Kind
  public let vector: UInt8
  public let errorCode: UInt32?
  public let instructionPointer: UInt64
  public let linearAddress: UInt64?
  /// True only for restartable multi-iteration instructions whose completed iterations are visible.
  public let commitsPartialProgress: Bool

  public init(
    kind: Kind,
    vector: UInt8,
    errorCode: UInt32? = nil,
    instructionPointer: UInt64,
    linearAddress: UInt64? = nil,
    commitsPartialProgress: Bool = false
  ) {
    self.kind = kind
    self.vector = vector
    self.errorCode = errorCode
    self.instructionPointer = instructionPointer
    self.linearAddress = linearAddress
    self.commitsPartialProgress = commitsPartialProgress
  }
}

public enum DoryX86InterpreterResult: Codable, Sendable, Hashable {
  case retired(DoryX86DecodedInstruction)
  /// A restartable instruction made bounded progress and deliberately returned to the vCPU loop.
  case yielded(DoryX86DecodedInstruction)
  case halted(DoryX86DecodedInstruction)
  case exception(DoryX86Exception)
}

public struct DoryX86Interpreter: Sendable {
  public let profile: DoryX86CPUProfile
  public let decoder: DoryX86Decoder
  public let processorID: UInt32
  public let logicalProcessorCount: UInt16

  public init(
    profile: DoryX86CPUProfile = .compatibleV1,
    decoder: DoryX86Decoder = .init(),
    processorID: UInt32 = 0,
    logicalProcessorCount: UInt16 = 1
  ) {
    self.profile = profile
    self.decoder = decoder
    self.processorID = processorID
    self.logicalProcessorCount = max(1, logicalProcessorCount)
  }

  public func step(
    state: inout DoryX86ArchitecturalState,
    memory: any DoryX86Memory,
    mode: DoryX86ExecutionMode,
    pagingUnit: DoryX86PagingUnit? = nil,
    translatedMemory: DoryX86TranslatedMemory? = nil,
    ioBus: (any DoryX86IOBus)? = nil
  ) -> DoryX86InterpreterResult {
    var candidate = state
    let result = executeStep(
      state: &candidate,
      memory: memory,
      mode: mode,
      pagingUnit: pagingUnit,
      translatedMemory: translatedMemory,
      ioBus: ioBus
    )
    switch result {
    case .retired, .yielded, .halted:
      state = candidate
    case .exception(let exception):
      if exception.commitsPartialProgress { state = candidate }
      // A general-detect #DB is fault-like, but its debug-status effects survive.
      // Do not publish the candidate RIP, operands, or ordinary instruction state.
      if exception.kind == .debug { state.debug = candidate.debug }
      // Intel SDM Vol. 1 §11.5.3.2 sets numeric status before selecting #XM or
      // #UD (CR4.OSXMMEXCPT=0). Only sticky status survives, not the destination
      // or MXCSR controls. Other #UD paths do not produce candidate status bits.
      if exception.kind == .simdFloatingPoint || exception.kind == .invalidOpcode {
        state.floatingPoint.mxcsr |= candidate.floatingPoint.mxcsr & 0x3F
      }
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
    pagingUnit: DoryX86PagingUnit?,
    translatedMemory: DoryX86TranslatedMemory?,
    ioBus: (any DoryX86IOBus)?
  ) -> DoryX86InterpreterResult {
    let originalRIP = state.rip
    do {
      try state.control.validateLegacyPAEPDPTEs(physicalAddressBits: profile.physicalAddressBits)
    } catch {
      return generalProtection(at: originalRIP)
    }
    let executionMemory: any DoryX86Memory
    if let translatedMemory {
      translatedMemory.updateContext(.init(state: state, mode: mode, profile: profile))
      executionMemory = translatedMemory
    } else if let pagingUnit {
      executionMemory =
        DoryX86TranslatedMemory(
          physicalMemory: memory,
          pagingUnit: pagingUnit,
          context: .init(state: state, mode: mode, profile: profile)
        )
    } else {
      executionMemory = memory
    }
    let instruction: DoryX86DecodedInstruction
    let originalCodeSegment = state.cs
    do {
      let maximumFetchByteCount = try instructionFetchByteCount(
        state: state,
        mode: mode,
        instructionPointer: originalRIP
      )
      instruction = try decodeInstruction(
        at: originalRIP,
        memoryAddress: instructionFetchAddress(state: state, mode: mode),
        memory: executionMemory,
        mode: mode,
        maximumByteCount: maximumFetchByteCount
      )
    } catch let error as DoryX86MemoryError {
      let fault = pageFault(for: error, instructionPointer: originalRIP)
      if fault.kind == .pageFault { state.control.cr2 = fault.linearAddress ?? 0 }
      return .exception(fault)
    } catch let exception as DoryX86Exception {
      return .exception(exception)
    } catch DoryX86DecodeError.instructionTooLong {
      // Intel SDM Vol. 3A, Event 13 and Table 7-2: length >15 is #GP(0).
      // Earlier instruction-byte fetch faults have already taken precedence.
      return generalProtection(at: originalRIP)
    } catch {
      return .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: originalRIP))
    }

    if let fault = DoryX86InstructionFeaturePolicy.executionFault(instruction, profile: profile) {
      return .exception(fault)
    }
    if let fault = DoryX86LegacyFloatingPointPolicy.executionFault(instruction, state: state) {
      return .exception(fault)
    }
    if let fault = simdExecutionStateFault(instruction, state: state, mode: mode) {
      return fault
    }

    do {
      var nextRIP = instruction.nextInstructionAddress & instructionPointerMask(mode)
      switch instruction.operation {
      case .noOperation:
        break
      case .undefinedInstruction, .unsupportedSystemInstruction:
        return invalidOpcode(at: originalRIP)
      case .halt:
        guard mode == .real16
          || (currentPrivilegeLevel(state, mode: mode) == 0 && !state.rflags.contains(.virtual8086))
        else { return generalProtection(at: originalRIP) }
        state.rip = nextRIP
        return .halted(instruction)
      case .move(let destination, let source):
        let value = try read(
          source, instruction: instruction, state: state, memory: executionMemory)
        try write(
          value, to: destination, instruction: instruction, state: &state, memory: executionMemory)
      case .loadEffectiveAddress(let destination, let source):
        let address = effectiveOffset(source, instruction: instruction, state: state)
        try write(
          address, to: destination, instruction: instruction, state: &state, memory: executionMemory
        )
      case .alu(let operation, let destination, let source):
        let execute = { (operationState: inout DoryX86ArchitecturalState) in
          let lhs = try read(
            destination, instruction: instruction, state: operationState, memory: executionMemory)
          let rhs = try read(
            source, instruction: instruction, state: operationState, memory: executionMemory)
          let width = operandWidth(destination)
          let result = executeALU(
            operation, lhs: lhs, rhs: rhs, width: width, flags: &operationState.rflags)
          if operation != .compare, operation != .test {
            try preflightWrite(
              to: destination,
              instruction: instruction,
              state: operationState,
              memory: executionMemory
            )
            try write(
              result, to: destination, instruction: instruction, state: &operationState,
              memory: executionMemory)
          }
        }
        if instruction.prefixes.lock {
          try DoryX86AtomicGate.shared.withLock(state: &state, execute)
        } else {
          try execute(&state)
        }
      case .unary(let operation, let operand):
        let execute = { (operationState: inout DoryX86ArchitecturalState) in
          let value = try read(
            operand, instruction: instruction, state: operationState, memory: executionMemory)
          let width = operandWidth(operand)
          let result: UInt64
          switch operation {
          case .increment:
            let carry = operationState.rflags.contains(.carry)
            result = executeALU(
              .add, lhs: value, rhs: 1, width: width, flags: &operationState.rflags)
            setFlag(.carry, carry, in: &operationState.rflags)
          case .decrement:
            let carry = operationState.rflags.contains(.carry)
            result = executeALU(
              .subtract, lhs: value, rhs: 1, width: width, flags: &operationState.rflags)
            setFlag(.carry, carry, in: &operationState.rflags)
          case .bitwiseNot:
            result = ~value & mask(width)
          case .negate:
            result = executeALU(
              .subtract, lhs: 0, rhs: value, width: width, flags: &operationState.rflags)
          }
          try preflightWrite(
            to: operand,
            instruction: instruction,
            state: operationState,
            memory: executionMemory
          )
          try write(
            result,
            to: operand,
            instruction: instruction,
            state: &operationState,
            memory: executionMemory
          )
        }
        if instruction.prefixes.lock {
          try DoryX86AtomicGate.shared.withLock(state: &state, execute)
        } else {
          try execute(&state)
        }
      case .shift(let operation, let destination, let countSource):
        let value = try read(
          destination, instruction: instruction, state: state, memory: executionMemory)
        try preflightWrite(
          to: destination, instruction: instruction, state: state, memory: executionMemory)
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
      case .flaglessShift(let operation, let destination, let source, let countOperand):
        // BMI1 SHRX/SARX/SHLX: shift source by count, no flags modified.
        let value = try read(
          source, instruction: instruction, state: state, memory: executionMemory)
        let countValue = try read(
          countOperand, instruction: instruction, state: state, memory: executionMemory)
        let width = operandWidth(destination)
        let count = UInt8(truncatingIfNeeded: countValue)
        let bitCount = Int(width.rawValue)
        let countMask: UInt8 = width == .quadword ? 0x3f : 0x1f
        let maskedCount = Int(count & countMask)
        let widthMask = mask(width)
        let maskedValue = value & widthMask
        let result: UInt64
        switch operation {
        case .shiftLeft:
          result = maskedCount < bitCount
            ? (maskedValue << maskedCount) & widthMask : 0
        case .shiftRight:
          result = maskedCount < bitCount
            ? maskedValue >> maskedCount : 0
        case .arithmeticShiftRight:
          let signed = signExtendedInt64(maskedValue, width: width)
          result = maskedCount < bitCount
            ? UInt64(bitPattern: signed >> maskedCount) & widthMask
            : UInt64(bitPattern: signed >> (bitCount - 1)) & widthMask
        case .rotateLeft, .rotateRight, .rotateCarryLeft, .rotateCarryRight:
          preconditionFailure("BMI1 flagless shift cannot be a rotate")
        }
        try write(
          result,
          to: destination,
          instruction: instruction,
          state: &state,
          memory: executionMemory
        )
      case .doubleShift(let operation, let destination, let source, let countSource):
        let destinationValue = try read(
          destination, instruction: instruction, state: state, memory: executionMemory)
        let sourceValue = try read(
          source, instruction: instruction, state: state, memory: executionMemory)
        try preflightWrite(
          to: destination, instruction: instruction, state: state, memory: executionMemory)
        let count: UInt8 =
          switch countSource {
          case .immediate(let value): value
          case .cl: UInt8(truncatingIfNeeded: state.registers.rcx)
          }
        let result = executeDoubleShift(
          operation,
          destination: destinationValue,
          source: sourceValue,
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
        } else if mode == .long64,
          case .register(let register, .doubleword) = destination
        {
          state.registers[register] &= 0xffff_ffff
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
      case .exchange(let lhs, let rhs):
        let execute = { (operationState: inout DoryX86ArchitecturalState) in
          let left = try read(
            lhs, instruction: instruction, state: operationState, memory: executionMemory)
          let right = try read(
            rhs, instruction: instruction, state: operationState, memory: executionMemory)
          try preflightWrite(
            to: lhs, instruction: instruction, state: operationState, memory: executionMemory)
          try preflightWrite(
            to: rhs, instruction: instruction, state: operationState, memory: executionMemory)
          try write(
            right,
            to: lhs,
            instruction: instruction,
            state: &operationState,
            memory: executionMemory
          )
          try write(
            left,
            to: rhs,
            instruction: instruction,
            state: &operationState,
            memory: executionMemory
          )
        }
        if isMemory(lhs) || isMemory(rhs) {
          try DoryX86AtomicGate.shared.withLock(state: &state, execute)
        } else {
          try execute(&state)
        }
      case .compareExchange(let destination, let source):
        let execute = { (operationState: inout DoryX86ArchitecturalState) in
          // CMPXCHG performs a destination write cycle even on mismatch. Check
          // the whole memory write range before any read/flags/register effects.
          if case .memory(let operand) = destination {
            try validateCompareExchangeMemory(operand, byteCount: operand.width.byteCount,
              instruction: instruction, state: operationState)
          }
          try preflightWrite(
            to: destination, instruction: instruction, state: operationState,
            memory: executionMemory)
          let destinationValue = try read(
            destination,
            instruction: instruction,
            state: operationState,
            memory: executionMemory
          )
          let sourceValue = try read(
            source, instruction: instruction, state: operationState, memory: executionMemory)
          let width = operandWidth(destination)
          let accumulator = operationState.registers.rax & mask(width)
          _ = executeALU(
            .compare,
            lhs: accumulator,
            rhs: destinationValue,
            width: width,
            flags: &operationState.rflags
          )
          if accumulator == destinationValue & mask(width) {
            try write(
              sourceValue,
              to: destination,
              instruction: instruction,
              state: &operationState,
              memory: executionMemory
            )
          } else {
            if isMemory(destination) {
              try write(destinationValue, to: destination, instruction: instruction,
                state: &operationState, memory: executionMemory)
            }
            try writeAccumulator(
              destinationValue,
              width: width,
              instruction: instruction,
              state: &operationState,
              memory: executionMemory
            )
          }
        }
        if instruction.prefixes.lock {
          try DoryX86AtomicGate.shared.withLock(state: &state, execute)
        } else {
          try execute(&state)
        }
      case .exchangeAdd(let destination, let source):
        let execute = { (operationState: inout DoryX86ArchitecturalState) in
          let destinationValue = try read(
            destination,
            instruction: instruction,
            state: operationState,
            memory: executionMemory
          )
          let sourceValue = try read(
            source, instruction: instruction, state: operationState, memory: executionMemory)
          let result = executeALU(
            .add,
            lhs: destinationValue,
            rhs: sourceValue,
            width: operandWidth(destination),
            flags: &operationState.rflags
          )
          try preflightWrite(
            to: destination,
            instruction: instruction,
            state: operationState,
            memory: executionMemory
          )
          try write(
            destinationValue, to: source, instruction: instruction, state: &operationState,
            memory: executionMemory)
          try write(
            result, to: destination, instruction: instruction, state: &operationState,
            memory: executionMemory)
        }
        if instruction.prefixes.lock {
          try DoryX86AtomicGate.shared.withLock(state: &state, execute)
        } else {
          try execute(&state)
        }
      case .bitTest(let operation, let base, let index):
        let execute = { (operationState: inout DoryX86ArchitecturalState) in
          try executeBitTest(
            operation,
            base: base,
            index: index,
            instruction: instruction,
            state: &operationState,
            memory: executionMemory
          )
        }
        if instruction.prefixes.lock {
          try DoryX86AtomicGate.shared.withLock(state: &state, execute)
        } else {
          try execute(&state)
        }
      case .bitScan(let reverse, let destination, let source):
        let value = try read(
          source, instruction: instruction, state: state, memory: executionMemory)
        let width = operandWidth(destination)
        let masked = value & mask(width)
        setFlag(.zero, masked == 0, in: &state.rflags)
        if masked != 0 {
          let index =
            reverse
            ? 63 - masked.leadingZeroBitCount
            : masked.trailingZeroBitCount
          try write(
            UInt64(index),
            to: destination,
            instruction: instruction,
            state: &state,
            memory: executionMemory
          )
        }
      case .byteSwap(let operand):
        let value = try read(
          operand, instruction: instruction, state: state, memory: executionMemory)
        let width = operandWidth(operand)
        let swapped =
          width == .quadword
          ? value.byteSwapped
          : UInt64(UInt32(truncatingIfNeeded: value).byteSwapped)
        try write(
          swapped,
          to: operand,
          instruction: instruction,
          state: &state,
          memory: executionMemory
        )
      case .compareExchangePair(let destination, let doubleQuadword):
        let execute = { (operationState: inout DoryX86ArchitecturalState) in
          try executeCompareExchangePair(
            destination: destination,
            doubleQuadword: doubleQuadword,
            instruction: instruction,
            state: &operationState,
            memory: executionMemory
          )
        }
        if instruction.prefixes.lock {
          try DoryX86AtomicGate.shared.withLock(state: &state, execute)
        } else {
          try execute(&state)
        }
      case .memoryFence:
        executionMemory.synchronize()
      case .cacheLineFlush(let operand):
        try validateSegmentAccess(
          operand,
          byteCount: 1,
          write: false,
          instruction: instruction,
          state: state
        )
        let address = effectiveAddress(operand, instruction: instruction, state: state)
        _ = try executionMemory.read(at: address, byteCount: 1)
        // Guest memory is coherent and has no separately observable interpreter cache. The
        // architectural memory-access check above is the only visible effect required here.
      case .waitForCoprocessor:
        break
      case .initializeFloatingPoint:
        // Intel SDM Vol. 2A FINIT/FNINIT preserves the physical data registers
        // (including their MMX aliases) while marking every tag empty. The x87
        // instruction/data pointers and last opcode are not yet modeled here.
        state.floatingPoint.x87ControlWord = 0x037F
        state.floatingPoint.x87StatusWord = 0
        state.floatingPoint.x87TagWord = 0xFFFF
      case .loadX87ControlWord(let source):
        state.floatingPoint.x87ControlWord = UInt16(
          truncatingIfNeeded: try read(
            source, instruction: instruction, state: state, memory: executionMemory)
        )
        DoryX86LegacyFloatingPointPolicy.updateExceptionSummary(state: &state.floatingPoint)
      case .storeX87ControlWord(let destination):
        try write(
          UInt64(state.floatingPoint.x87ControlWord),
          to: destination,
          instruction: instruction,
          state: &state,
          memory: executionMemory
        )
      case .loadX87(let source):
        let value = try readX87(
          source,
          instruction: instruction,
          state: state,
          memory: executionMemory
        )
        pushX87(value, state: &state.floatingPoint)
      case .storeX87(let destination, let format, let pop, let truncate):
        let value = readX87Register(0, state: state.floatingPoint)
        let bytes = storeX87Bytes(
          value,
          format: format,
          truncate: truncate,
          floatingPoint: &state.floatingPoint
        )
        try writeX87Memory(
          bytes,
          to: destination,
          instruction: instruction,
          state: state,
          memory: executionMemory
        )
        if pop { popX87(state: &state.floatingPoint) }
      case .exchangeX87(let register):
        let first = physicalX87Register(0, state: state.floatingPoint)
        let second = physicalX87Register(register, state: state.floatingPoint)
        state.floatingPoint.x87.swapAt(first, second)
        let firstTag = x87Tag(first, state: state.floatingPoint)
        let secondTag = x87Tag(second, state: state.floatingPoint)
        setX87Tag(first, secondTag, state: &state.floatingPoint)
        setX87Tag(second, firstTag, state: &state.floatingPoint)
      case .x87Binary(let operation, let destination, let source, let pop):
        let lhs = readX87Register(destination, state: state.floatingPoint)
        let rhs = try readX87(
          source,
          instruction: instruction,
          state: state,
          memory: executionMemory
        )
        let rounding = x87Rounding(state.floatingPoint)
        let precision = x87Precision(state.floatingPoint)
        let result: DoryX86ExtendedFloat =
          switch operation {
          case .add: lhs.adding(rhs, rounding: rounding, precision: precision)
          case .multiply: lhs.multiplied(by: rhs, rounding: rounding, precision: precision)
          case .subtract: lhs.subtracting(rhs, rounding: rounding, precision: precision)
          case .subtractReverse: rhs.subtracting(lhs, rounding: rounding, precision: precision)
          case .divide: lhs.divided(by: rhs, rounding: rounding, precision: precision)
          case .divideReverse: rhs.divided(by: lhs, rounding: rounding, precision: precision)
          }
        updateX87ArithmeticStatus(
          operation: operation,
          lhs: lhs,
          rhs: rhs,
          result: result,
          state: &state.floatingPoint
        )
        writeX87Register(destination, value: result, state: &state.floatingPoint)
        if pop { popX87(state: &state.floatingPoint) }
      case .compareX87(let source, let popCount, let ordered, let setIntegerFlags):
        let lhs = readX87Register(0, state: state.floatingPoint)
        let rhs = try readX87(
          source,
          instruction: instruction,
          state: state,
          memory: executionMemory
        )
        let relation = x87FloatingComparison(lhs, rhs)
        if relation == .unordered, ordered { state.floatingPoint.x87StatusWord |= 1 }
        if setIntegerFlags {
          state.rflags.remove([.overflow, .sign, .zero, .auxiliaryCarry, .parity, .carry])
          switch relation {
          case .greater:
            break
          case .less:
            state.rflags.insert(.carry)
          case .equal:
            state.rflags.insert(.zero)
          case .unordered:
            state.rflags.insert([.zero, .parity, .carry])
          }
        } else {
          state.floatingPoint.x87StatusWord &= ~UInt16(0x4500)
          switch relation {
          case .greater:
            break
          case .less:
            state.floatingPoint.x87StatusWord |= 0x0100
          case .equal:
            state.floatingPoint.x87StatusWord |= 0x4000
          case .unordered:
            state.floatingPoint.x87StatusWord |= 0x4500
          }
        }
        for _ in 0..<popCount { popX87(state: &state.floatingPoint) }
      case .x87Special(let operation):
        executeX87Special(operation, state: &state.floatingPoint)
      case .loadX87Environment(let source):
        let byteCount = mode == .real16 || mode == .protected16 ? 14 : 28
        try validateSegmentAccess(
          source,
          byteCount: byteCount,
          write: false,
          instruction: instruction,
          state: state
        )
        let bytes = try executionMemory.read(
          at: effectiveAddress(source, instruction: instruction, state: state),
          byteCount: byteCount
        )
        state.floatingPoint.x87ControlWord = UInt16(fromLittleEndian(Array(bytes[0..<2])))
        state.floatingPoint.x87StatusWord = UInt16(fromLittleEndian(Array(bytes[2..<4])))
        state.floatingPoint.x87TagWord = UInt16(fromLittleEndian(Array(bytes[4..<6])))
        DoryX86LegacyFloatingPointPolicy.updateExceptionSummary(state: &state.floatingPoint)
      case .storeX87Environment(let destination):
        let byteCount = mode == .real16 || mode == .protected16 ? 14 : 28
        var bytes = [UInt8](repeating: 0, count: byteCount)
        replaceLittleEndian(state.floatingPoint.x87ControlWord, in: &bytes, at: 0)
        replaceLittleEndian(state.floatingPoint.x87StatusWord, in: &bytes, at: 2)
        replaceLittleEndian(state.floatingPoint.x87TagWord, in: &bytes, at: 4)
        try writeX87Memory(
          bytes,
          to: destination,
          instruction: instruction,
          state: state,
          memory: executionMemory
        )
        state.floatingPoint.x87ControlWord |= 0x003F
        DoryX86LegacyFloatingPointPolicy.updateExceptionSummary(state: &state.floatingPoint)
      case .loadX87PackedBCD(let source):
        try validateSegmentAccess(
          source,
          byteCount: 10,
          write: false,
          instruction: instruction,
          state: state
        )
        let bytes = try executionMemory.read(
          at: effectiveAddress(source, instruction: instruction, state: state),
          byteCount: 10
        )
        pushX87(decodeX87PackedBCD(bytes, state: &state.floatingPoint), state: &state.floatingPoint)
      case .storeX87PackedBCD(let destination, let pop):
        let bytes = encodeX87PackedBCD(
          readX87Register(0, state: state.floatingPoint).doubleValue,
          state: &state.floatingPoint
        )
        try writeX87Memory(
          bytes,
          to: destination,
          instruction: instruction,
          state: state,
          memory: executionMemory
        )
        if pop { popX87(state: &state.floatingPoint) }
      case .moveX87(let destination, let source, let pop):
        writeX87Register(
          destination,
          value: readX87Register(source, state: state.floatingPoint),
          state: &state.floatingPoint
        )
        if pop { popX87(state: &state.floatingPoint) }
      case .freeX87(let register, let pop):
        setX87Tag(
          physicalX87Register(register, state: state.floatingPoint),
          3,
          state: &state.floatingPoint
        )
        if pop { popX87(state: &state.floatingPoint) }
      case .conditionalMoveX87(let condition, let source):
        if evaluate(condition, flags: state.rflags) {
          writeX87Register(
            0,
            value: readX87Register(source, state: state.floatingPoint),
            state: &state.floatingPoint
          )
        }
      case .clearX87Exceptions:
        // FNCLEX clears exception flags, SF, ES and B. TOP remains unchanged;
        // condition codes are architecturally undefined and are retained here.
        state.floatingPoint.x87StatusWord &= 0x7F00
      case .storeX87StatusWord(let destination):
        try write(
          UInt64(state.floatingPoint.x87StatusWord),
          to: destination,
          instruction: instruction,
          state: &state,
          memory: executionMemory
        )
      case .saveFloatingPointState(let destination):
        let address = effectiveAddress(destination, instruction: instruction, state: state)
        guard address & 0xF == 0 else { return generalProtection(at: originalRIP) }
        try validateSegmentAccess(
          destination,
          byteCount: 512,
          write: true,
          instruction: instruction,
          state: state
        )
        let bytes = floatingPointSaveArea(state.floatingPoint, mode: mode)
        try executionMemory.validateWrite(at: address, byteCount: bytes.count)
        try executionMemory.write(
          at: address,
          bytes: bytes
        )
      case .restoreFloatingPointState(let source):
        let address = effectiveAddress(source, instruction: instruction, state: state)
        guard address & 0xF == 0 else { return generalProtection(at: originalRIP) }
        try validateSegmentAccess(
          source,
          byteCount: 512,
          write: false,
          instruction: instruction,
          state: state
        )
        let bytes = try executionMemory.read(
          at: address, byteCount: floatingPointTransferByteCount(mode: mode))
        guard
          let restored = try restoredFloatingPointState(
            from: bytes,
            mode: mode,
            preserving: state.floatingPoint
          )
        else { return generalProtection(at: originalRIP) }
        state.floatingPoint = restored
      case .loadMXCSR(let source):
        let value = UInt32(
          truncatingIfNeeded: try read(
            source, instruction: instruction, state: state, memory: executionMemory)
        )
        guard value & ~state.floatingPoint.mxcsrMask == 0 else {
          return generalProtection(at: originalRIP)
        }
        state.floatingPoint.mxcsr = value
      case .storeMXCSR(let destination):
        try write(
          UInt64(state.floatingPoint.mxcsr),
          to: destination,
          instruction: instruction,
          state: &state,
          memory: executionMemory
        )
      case .moveMMX(let destination, let source, let byteCount):
        let bytes = try readMMXBytes(
          source,
          byteCount: Int(byteCount),
          instruction: instruction,
          state: state,
          memory: executionMemory
        )
        try writeMMXBytes(
          bytes,
          to: destination,
          instruction: instruction,
          state: &state,
          memory: executionMemory
        )
      case .moveIntegerToMMX(let destination, let source):
        let width = operandWidth(source)
        let value = try read(
          source, instruction: instruction, state: state, memory: executionMemory)
        var bytes = littleEndian(value, width: width)
        bytes += [UInt8](repeating: 0, count: 8 - bytes.count)
        writeMMXRegister(destination, bytes: bytes, state: &state.floatingPoint)
      case .moveMMXToInteger(let destination, let source):
        let width = operandWidth(destination)
        let bytes = Array(state.floatingPoint.x87[Int(source)].bytes.prefix(width.byteCount))
        try write(
          fromLittleEndian(bytes),
          to: destination,
          instruction: instruction,
          state: &state,
          memory: executionMemory
        )
      case .mmxBitwise(let operation, let destination, let source):
        let rhs = try readMMXBytes(
          source,
          byteCount: 8,
          instruction: instruction,
          state: state,
          memory: executionMemory
        )
        var bytes = Array(state.floatingPoint.x87[Int(destination)].bytes.prefix(8))
        for index in bytes.indices {
          let lhs = bytes[index]
          bytes[index] =
            switch operation {
            case .and: lhs & rhs[index]
            case .andNot: ~lhs & rhs[index]
            case .or: lhs | rhs[index]
            case .xor: lhs ^ rhs[index]
            }
        }
        writeMMXRegister(destination, bytes: bytes, state: &state.floatingPoint)
      case .mmxIntegerBinary(let operation, let laneWidth, let destination, let source):
        let rhs = try readMMXBytes(
          source,
          byteCount: 8,
          instruction: instruction,
          state: state,
          memory: executionMemory
        )
        var bytes = Array(state.floatingPoint.x87[Int(destination)].bytes.prefix(8))
        executeVectorIntegerBinary(
          operation,
          laneWidth: laneWidth,
          destination: &bytes,
          source: rhs,
          vectorByteCount: 8
        )
        writeMMXRegister(destination, bytes: bytes, state: &state.floatingPoint)
      case .mmxIntegerShift(let operation, let laneWidth, let destination, let countSource):
        let count: UInt64
        switch countSource {
        case .immediate(let immediate):
          count = UInt64(immediate)
        case .vector(let source):
          count = fromLittleEndian(
            try readMMXBytes(
              source,
              byteCount: 8,
              instruction: instruction,
              state: state,
              memory: executionMemory
            ))
        }
        var bytes = Array(state.floatingPoint.x87[Int(destination)].bytes.prefix(8))
        executeVectorIntegerShift(
          operation,
          laneWidth: laneWidth,
          destination: &bytes,
          count: count,
          vectorByteCount: 8
        )
        writeMMXRegister(destination, bytes: bytes, state: &state.floatingPoint)
      case .mmxIntegerInterleave(let high, let laneWidth, let destination, let source):
        let rhs = try readMMXBytes(
          source,
          byteCount: 8,
          instruction: instruction,
          state: state,
          memory: executionMemory
        )
        let lhs = Array(state.floatingPoint.x87[Int(destination)].bytes.prefix(8))
        let laneBytes = Int(laneWidth.rawValue)
        let lanesPerInput = 4 / laneBytes
        let inputOffset = high ? 4 : 0
        var bytes: [UInt8] = []
        for lane in 0..<lanesPerInput {
          let offset = inputOffset + lane * laneBytes
          bytes += lhs[offset..<offset + laneBytes]
          bytes += rhs[offset..<offset + laneBytes]
        }
        writeMMXRegister(destination, bytes: bytes, state: &state.floatingPoint)
      case .mmxIntegerPack(let operation, let sourceLaneWidth, let destination, let source):
        let rhs = try readMMXBytes(
          source,
          byteCount: 8,
          instruction: instruction,
          state: state,
          memory: executionMemory
        )
        let lhs = Array(state.floatingPoint.x87[Int(destination)].bytes.prefix(8))
        writeMMXRegister(
          destination,
          bytes: packVectorIntegers(
            operation,
            sourceLaneWidth: sourceLaneWidth,
            lhs: lhs,
            rhs: rhs
          ),
          state: &state.floatingPoint
        )
      case .emptyMMXState:
        break // The common retirement effect updates tags and TOP.
      case .moveVector128(let destination, let source, let requiresAlignment):
        let bytes: [UInt8]
        switch source {
        case .register(let register):
          precondition(state.floatingPoint.ymm.indices.contains(Int(register)))
          bytes = Array(state.floatingPoint.ymm[Int(register)].bytes.prefix(16))
        case .memory(let memoryOperand):
          try validateSegmentAccess(
            memoryOperand,
            byteCount: 16,
            write: false,
            instruction: instruction,
            state: state
          )
          let address = effectiveAddress(memoryOperand, instruction: instruction, state: state)
          if requiresAlignment, address & 0xF != 0 {
            return generalProtection(at: originalRIP)
          }
          bytes = try executionMemory.read(at: address, byteCount: 16)
        }

        switch destination {
        case .register(let register):
          precondition(state.floatingPoint.ymm.indices.contains(Int(register)))
          var registerBytes = state.floatingPoint.ymm[Int(register)].bytes
          registerBytes.replaceSubrange(0..<16, with: bytes)
          state.floatingPoint.ymm[Int(register)] = try .init(
            bytes: registerBytes,
            expectedByteCount: 32
          )
        case .memory(let memoryOperand):
          try validateSegmentAccess(
            memoryOperand,
            byteCount: 16,
            write: true,
            instruction: instruction,
            state: state
          )
          let address = effectiveAddress(memoryOperand, instruction: instruction, state: state)
          if requiresAlignment, address & 0xF != 0 {
            return generalProtection(at: originalRIP)
          }
          try executionMemory.validateWrite(at: address, byteCount: 16)
          try executionMemory.write(at: address, bytes: bytes)
        }
      case .moveVectorScalar(let destination, let source, let byteCount, let upperPolicy):
        let count = Int(byteCount)
        let bytes = try readVectorBytes(
          source,
          byteCount: count,
          instruction: instruction,
          state: state,
          memory: executionMemory
        )
        switch destination {
        case .register(let register):
          var registerBytes = state.floatingPoint.ymm[Int(register)].bytes
          let clearsUpper =
            upperPolicy == .zero
            || (upperPolicy == .zeroOnMemorySource && isVectorMemory(source))
          if clearsUpper {
            registerBytes.replaceSubrange(count..<16, with: repeatElement(0, count: 16 - count))
          }
          registerBytes.replaceSubrange(0..<count, with: bytes)
          state.floatingPoint.ymm[Int(register)] = try .init(
            bytes: registerBytes, expectedByteCount: 32)
        case .memory(let memoryOperand):
          try writeVectorBytes(
            bytes,
            to: memoryOperand,
            instruction: instruction,
            state: state,
            memory: executionMemory
          )
        }
      case .moveVectorQwordHalf(let destination, let source, let sourceHigh, let destinationHigh):
        // MOVLPS/MOVHLPS/MOVHPS/MOVLHPS move a 64-bit half between the low 128
        // bits, preserving the untouched destination half and the upper YMM half.
        let half: [UInt8]
        switch source {
        case .register(let register):
          let full = state.floatingPoint.ymm[Int(register)].bytes
          half = Array(sourceHigh ? full[8..<16] : full[0..<8])
        case .memory(let memoryOperand):
          try validateSegmentAccess(
            memoryOperand,
            byteCount: 8,
            write: false,
            instruction: instruction,
            state: state
          )
          let address = effectiveAddress(memoryOperand, instruction: instruction, state: state)
          half = try executionMemory.read(at: address, byteCount: 8)
        }
        switch destination {
        case .register(let register):
          var registerBytes = state.floatingPoint.ymm[Int(register)].bytes
          let range = destinationHigh ? 8..<16 : 0..<8
          registerBytes.replaceSubrange(range, with: half)
          state.floatingPoint.ymm[Int(register)] = try .init(
            bytes: registerBytes, expectedByteCount: 32)
        case .memory(let memoryOperand):
          try writeVectorBytes(
            half,
            to: memoryOperand,
            instruction: instruction,
            state: state,
            memory: executionMemory
          )
        }
      case .duplicateVectorScalar(let destination, let source, let mode):
        // MOVDDUP/MOVSLDUP/MOVSHDUP broadcast source elements into the low 128
        // bits, preserving the upper YMM half.
        let sourceByteCount = mode == .doubleLow64 ? 8 : 16
        let sourceBytes = try readVectorBytes(
          source,
          byteCount: sourceByteCount,
          instruction: instruction,
          state: state,
          memory: executionMemory
        )
        var result = [UInt8](repeating: 0, count: 16)
        switch mode {
        case .doubleLow64:
          let low = Array(sourceBytes.prefix(8))
          result.replaceSubrange(0..<8, with: low)
          result.replaceSubrange(8..<16, with: low)
        case .singleLow32:
          for pair in 0..<2 {
            let lowDword = Array(sourceBytes[(pair * 2) * 4..<(pair * 2) * 4 + 4])
            result.replaceSubrange((pair * 2) * 4..<(pair * 2) * 4 + 4, with: lowDword)
            result.replaceSubrange((pair * 2 + 1) * 4..<(pair * 2 + 1) * 4 + 4, with: lowDword)
          }
        case .singleHigh32:
          for pair in 0..<2 {
            let highDword = Array(sourceBytes[(pair * 2 + 1) * 4..<(pair * 2 + 1) * 4 + 4])
            result.replaceSubrange((pair * 2) * 4..<(pair * 2) * 4 + 4, with: highDword)
            result.replaceSubrange((pair * 2 + 1) * 4..<(pair * 2 + 1) * 4 + 4, with: highDword)
          }
        }
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        registerBytes.replaceSubrange(0..<16, with: result)
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .shufflePackedBytes(let destination, let source):
        // PSHUFB: each source byte selects a destination lane (high bit zeroes).
        let indices = try readVectorBytes(
          source, byteCount: 16, instruction: instruction, state: state, memory: executionMemory)
        var table = state.floatingPoint.ymm[Int(destination)].bytes
        var result = [UInt8](repeating: 0, count: 16)
        for lane in 0..<16 {
          let index = indices[lane]
          if index & 0x80 != 0 {
            result[lane] = 0
          } else {
            result[lane] = table[Int(index & 0x0F)]
          }
        }
        table.replaceSubrange(0..<16, with: result)
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: table, expectedByteCount: 32)
      case .alignPackedBytes(let destination, let source, let count):
        // PALIGNR: concatenate source:destination (source low) and extract 16
        // bytes starting at `count`, zero-filling beyond the 32-byte window.
        let sourceBytes = try readVectorBytes(
          source, byteCount: 16, instruction: instruction, state: state, memory: executionMemory)
        var destinationBytes = state.floatingPoint.ymm[Int(destination)].bytes
        let combined = sourceBytes + Array(destinationBytes.prefix(16))
        var result = [UInt8](repeating: 0, count: 16)
        for lane in 0..<16 {
          let index = Int(count) + lane
          if index < combined.count { result[lane] = combined[index] }
        }
        destinationBytes.replaceSubrange(0..<16, with: result)
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: destinationBytes, expectedByteCount: 32)
      case .testPackedBits(let destination, let source):
        // PTEST: ZF = (DEST AND SRC) == 0; CF = ((NOT DEST) AND SRC) == 0.
        let sourceBytes = try readVectorBytes(
          source, byteCount: 16, instruction: instruction, state: state, memory: executionMemory)
        let destinationBytes = state.floatingPoint.ymm[Int(destination)].bytes
        var andResult: UInt8 = 0
        var andNotResult: UInt8 = 0
        for lane in 0..<16 {
          andResult |= destinationBytes[lane] & sourceBytes[lane]
          andNotResult |= (~destinationBytes[lane]) & sourceBytes[lane]
        }
        state.rflags.remove([.zero, .carry, .auxiliaryCarry, .overflow, .sign, .parity])
        if andResult == 0 { state.rflags.insert(.zero) }
        if andNotResult == 0 { state.rflags.insert(.carry) }
      case .extendPackedDwordToQword(let destination, let source, let signed):
        // PMOVZXDQ/PMOVSXDQ: extend two low doublewords to two quadwords.
        let sourceBytes = try readVectorBytes(
          source, byteCount: 8, instruction: instruction, state: state, memory: executionMemory)
        var result = [UInt8](repeating: 0, count: 16)
        for lane in 0..<2 {
          let dword = Array(sourceBytes[lane * 4..<lane * 4 + 4])
          let extensionBytes: [UInt8]
          if signed && (dword[3] & 0x80 != 0) {
            extensionBytes = [0xFF, 0xFF, 0xFF, 0xFF]
          } else {
            extensionBytes = [0, 0, 0, 0]
          }
          result.replaceSubrange(lane * 8..<lane * 8 + 4, with: dword)
          result.replaceSubrange(lane * 8 + 4..<lane * 8 + 8, with: extensionBytes)
        }
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        registerBytes.replaceSubrange(0..<16, with: result)
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .extendPackedByteToQword(let destination, let source, let signed):
        // PMOVSXBQ/PMOVZXBQ: extend two low bytes to two quadwords. SSE4.1.
        let sourceBytes = try readVectorBytes(
          source, byteCount: 2, instruction: instruction, state: state, memory: executionMemory)
        var result = [UInt8](repeating: 0, count: 16)
        for lane in 0..<2 {
          let byte = sourceBytes[lane]
          let extensionBytes: [UInt8]
          if signed && (byte & 0x80 != 0) {
            extensionBytes = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
          } else {
            extensionBytes = [0, 0, 0, 0, 0, 0, 0]
          }
          result[lane * 8] = byte
          result.replaceSubrange(lane * 8 + 1..<lane * 8 + 8, with: extensionBytes)
        }
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        registerBytes.replaceSubrange(0..<16, with: result)
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .comparePackedQwords(let destination, let source):
        // PCMPEQQ: compare packed quadwords for equality. SSE4.1.
        let sourceBytes = try readVectorBytes(
          source, byteCount: 16, instruction: instruction, state: state, memory: executionMemory)
        let destinationBytes = state.floatingPoint.ymm[Int(destination)].bytes
        var result = [UInt8](repeating: 0, count: 16)
        for lane in 0..<2 {
          let lhs = Array(destinationBytes[lane * 8..<lane * 8 + 8])
          let rhs = Array(sourceBytes[lane * 8..<lane * 8 + 8])
          if lhs == rhs {
            result.replaceSubrange(lane * 8..<lane * 8 + 8, with: repeatElement(0xFF, count: 8))
          }
        }
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        registerBytes.replaceSubrange(0..<16, with: result)
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .insertPackedQword(let destination, let source, let index):
        // PINSRQ: insert a qword from GPR/memory into selected XMM lane. SSE4.1.
        let value = try read(
          source, instruction: instruction, state: state, memory: executionMemory)
        let qwordBytes = littleEndian(value, width: .quadword)
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        let offset = Int(index) * 8
        registerBytes.replaceSubrange(offset..<offset + 8, with: qwordBytes)
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .insertPackedWord(let destination, let source, let index, let mmx):
        let value = try read(
          source, instruction: instruction, state: state, memory: executionMemory)
        let wordBytes = littleEndian(value, width: .word)
        var registerBytes = mmx
          ? Array(state.floatingPoint.x87[Int(destination)].bytes.prefix(8))
          : state.floatingPoint.ymm[Int(destination)].bytes
        let offset = Int(index & (mmx ? 3 : 7)) * 2
        registerBytes.replaceSubrange(offset..<offset + 2, with: wordBytes)
        if mmx {
          writeMMXRegister(destination, bytes: registerBytes, state: &state.floatingPoint)
        } else {
          state.floatingPoint.ymm[Int(destination)] = try .init(
            bytes: registerBytes, expectedByteCount: 32)
        }
      case .unpackVector(let high, let doublePrecision, let destination, let source):
        let lhs = Array(state.floatingPoint.ymm[Int(destination)].bytes.prefix(16))
        let rhs = try readVectorBytes(
          source, byteCount: 16, instruction: instruction,
          state: state, memory: executionMemory)
        var result = [UInt8](repeating: 0, count: 16)
        if doublePrecision {
          if high {
            result.replaceSubrange(0..<8, with: lhs[8..<16])
            result.replaceSubrange(8..<16, with: rhs[8..<16])
          } else {
            result.replaceSubrange(0..<8, with: lhs[0..<8])
            result.replaceSubrange(8..<16, with: rhs[0..<8])
          }
        } else {
          if high {
            result.replaceSubrange(0..<4, with: lhs[8..<12])
            result.replaceSubrange(4..<8, with: rhs[8..<12])
            result.replaceSubrange(8..<12, with: lhs[12..<16])
            result.replaceSubrange(12..<16, with: rhs[12..<16])
          } else {
            result.replaceSubrange(0..<4, with: lhs[0..<4])
            result.replaceSubrange(4..<8, with: rhs[0..<4])
            result.replaceSubrange(8..<12, with: lhs[4..<8])
            result.replaceSubrange(12..<16, with: rhs[4..<8])
          }
        }
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        registerBytes.replaceSubrange(0..<16, with: result)
        registerBytes.replaceSubrange(16..<32, with: repeatElement(0, count: 16))
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .convertPackedDoubleToDword(let truncated, let destination, let source):
        if case .memory(let operand) = source {
          try validateSegmentAccess(
            operand, byteCount: 16, write: false, instruction: instruction, state: state)
          guard effectiveAddress(operand, instruction: instruction, state: state) & 0xF == 0 else {
            return generalProtection(at: originalRIP)
          }
        }
        let sourceBytes = try readVectorBytes(
          source, byteCount: 16, instruction: instruction,
          state: state, memory: executionMemory)
        var result = [UInt8](repeating: 0, count: 16)
        var exceptions: UInt32 = 0
        for lane in 0..<2 {
          let offset = lane * 8
          let converted = packedDoubleToDwordResult(
            fromLittleEndian(Array(sourceBytes[offset..<offset + 8])),
            truncated: truncated, mxcsr: state.floatingPoint.mxcsr)
          replaceLittleEndian(converted.value, in: &result, at: lane * 4)
          exceptions |= converted.exceptions
        }
        // Invalid is pre-computation; an unmasked invalid lane prevents the
        // packed instruction from reaching another lane's precision phase.
        let masks = (state.floatingPoint.mxcsr >> 7) & 0x3F
        if exceptions & 1 != 0, masks & 1 == 0 { exceptions &= ~UInt32(1 << 5) }
        state.floatingPoint.mxcsr |= exceptions
        if exceptions & ~masks != 0 {
          if state.control.cr4 & (1 << 10) == 0 { return invalidOpcode(at: originalRIP) }
          return .exception(.init(kind: .simdFloatingPoint, vector: 19, instructionPointer: originalRIP))
        }
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        // Legacy SSE clears XMM[127:64] and preserves YMM[255:128].
        registerBytes.replaceSubrange(0..<16, with: result)
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .convertPackedDwordToDouble(let destination, let source):
        let sourceBytes = try readVectorBytes(
          source, byteCount: 8, instruction: instruction, state: state, memory: executionMemory)
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        for lane in 0..<2 {
          let offset = lane * 4
          let value = Int32(bitPattern: UInt32(fromLittleEndian(Array(sourceBytes[offset..<offset + 4]))))
          replaceLittleEndian(Double(value).bitPattern, in: &registerBytes, at: lane * 8)
        }
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .packedCompareStringIndex(let destination, let source, let immediate):
        // PCMPISTRI: SSE4.2 packed compare implicit-length strings.
        // Produces an index in ECX. The immediate encodes:
        //   bits 0: data size (0=byte, 1=word)
        //   bits 2:1: aggregation (0=equal any, 1=ranges, 2=equal each, 3=equal ordered)
        //   bits 4:3: polarity (0=positive, 1=negative, 2=masked positive)
        //   bit 5: output (0=index, 1=mask)
        let lhs = Array(state.floatingPoint.ymm[Int(destination)].bytes.prefix(16))
        let rhs = try readVectorBytes(
          source, byteCount: 16, instruction: instruction,
          state: state, memory: executionMemory)
        let isWord = immediate & 1 != 0
        let aggregation = (immediate >> 1) & 3
        let polarity = (immediate >> 3) & 3
        let outputMask = immediate & 0x20 != 0
        let elementSize = isWord ? 2 : 1
        let elementCount = 16 / elementSize
        // Find null terminators (implicit length)
        var lhsLen = elementCount
        var rhsLen = elementCount
        for i in 0..<elementCount {
          let offset = i * elementSize
          if isWord {
            if lhs[offset] == 0 && lhs[offset + 1] == 0 { lhsLen = i; break }
          } else {
            if lhs[offset] == 0 { lhsLen = i; break }
          }
        }
        for i in 0..<elementCount {
          let offset = i * elementSize
          if isWord {
            if rhs[offset] == 0 && rhs[offset + 1] == 0 { rhsLen = i; break }
          } else {
            if rhs[offset] == 0 { rhsLen = i; break }
          }
        }
        // Build string comparison result
        var intRes: UInt32 = 0
        switch aggregation {
        case 0: // Equal Any: OR of all pairwise equals
          for i in 0..<lhsLen {
            for j in 0..<rhsLen {
              let li = i * elementSize
              let rj = j * elementSize
              let equal = isWord
                ? (lhs[li] == rhs[rj] && lhs[li + 1] == rhs[rj + 1])
                : (lhs[li] == rhs[rj])
              if equal { intRes |= 1 << i; break }
            }
          }
        case 2: // Equal Each: pairwise equals
          for i in 0..<min(lhsLen, rhsLen) {
            let li = i * elementSize
            let rj = i * elementSize
            let equal = isWord
              ? (lhs[li] == rhs[rj] && lhs[li + 1] == rhs[rj + 1])
              : (lhs[li] == rhs[rj])
            if equal { intRes |= 1 << i }
          }
        case 1, 3: // Ranges / Equal Ordered: simplified
          for i in 0..<lhsLen {
            intRes |= 1 << i
          }
        default:
          break
        }
        // Apply polarity
        switch polarity {
        case 1: intRes = ~intRes & ((1 << elementCount) - 1)
        case 2:
          // Masked positive: use valid bits only
          let valid = UInt32((1 << min(lhsLen, rhsLen)) - 1)
          intRes &= valid
        default: break
        }
        // Set flags
        state.rflags.remove([.overflow, .carry, .zero, .sign])
        if intRes == 0 { state.rflags.insert(.zero) }
        // Output: index or mask in ECX
        if outputMask {
          try write(
            UInt64(intRes), to: .register(.rcx, width: .doubleword),
            instruction: instruction, state: &state, memory: executionMemory)
        } else {
          // Find index of least significant set bit (or elementCount if none)
          var index: UInt64 = UInt64(elementCount)
          for i in 0..<elementCount {
            if intRes & (1 << i) != 0 { index = UInt64(i); break }
          }
          try write(
            index, to: .register(.rcx, width: .doubleword),
            instruction: instruction, state: &state, memory: executionMemory)
        }
      // MARK: - VEX (AVX/AVX2) execution
      case .vexZeroUpper:
        // VZEROUPPER: zero the upper 128 bits of all 16 YMM registers.
        for index in state.floatingPoint.ymm.indices {
          var bytes = state.floatingPoint.ymm[index].bytes
          bytes.replaceSubrange(16..<32, with: repeatElement(0, count: 16))
          state.floatingPoint.ymm[index] = try .init(
            bytes: bytes, expectedByteCount: 32)
        }
      case .vexMoveVector(let destination, let source, let length, let requiresAlignment):
        let byteCount = Int(length.rawValue)
        let bytes: [UInt8]
        switch source {
        case .register(let register):
          bytes = Array(state.floatingPoint.ymm[Int(register)].bytes.prefix(byteCount))
        case .memory(let memoryOperand):
          try validateSegmentAccess(
            memoryOperand, byteCount: byteCount, write: false,
            instruction: instruction, state: state)
          let address = effectiveAddress(memoryOperand, instruction: instruction, state: state)
          if requiresAlignment, address & (byteCount == 32 ? 0x1F : 0xF) != 0 {
            return generalProtection(at: originalRIP)
          }
          bytes = try executionMemory.read(at: address, byteCount: byteCount)
        }
        switch destination {
        case .register(let register):
          var registerBytes = state.floatingPoint.ymm[Int(register)].bytes
          registerBytes.replaceSubrange(0..<byteCount, with: bytes)
          if length == .xmm128 {
            registerBytes.replaceSubrange(
              byteCount..<32, with: repeatElement(0, count: 32 - byteCount))
          }
          state.floatingPoint.ymm[Int(register)] = try .init(
            bytes: registerBytes, expectedByteCount: 32)
        case .memory(let memoryOperand):
          try writeVectorBytes(
            bytes, to: memoryOperand, instruction: instruction,
            state: state, memory: executionMemory)
        }
      case .vexVectorBinary(let operation, let destination, let firstSource, let secondSource, let length):
        let byteCount = Int(length.rawValue)
        let lhs = Array(state.floatingPoint.ymm[Int(firstSource)].bytes.prefix(byteCount))
        let rhs = try readVectorBytes(
          secondSource, byteCount: byteCount, instruction: instruction,
          state: state, memory: executionMemory)
        var result = [UInt8](repeating: 0, count: byteCount)
        for i in 0..<byteCount {
          switch operation {
          case .and: result[i] = lhs[i] & rhs[i]
          case .andNot: result[i] = lhs[i] & ~rhs[i]
          case .or: result[i] = lhs[i] | rhs[i]
          case .xor: result[i] = lhs[i] ^ rhs[i]
          }
        }
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        registerBytes.replaceSubrange(0..<byteCount, with: result)
        if length == .xmm128 {
          registerBytes.replaceSubrange(
            byteCount..<32, with: repeatElement(0, count: 32 - byteCount))
        }
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .vexVectorFloatingBinary(let operation, let format, let destination, let firstSource, let secondSource, let length):
        let byteCount = Int(length.rawValue)
        var lhs = Array(state.floatingPoint.ymm[Int(firstSource)].bytes.prefix(byteCount))
        let rhs = try readVectorBytes(
          secondSource, byteCount: byteCount, instruction: instruction,
          state: state, memory: executionMemory)
        executeVectorFloatingBinary(operation, format: format, destination: &lhs, source: rhs)
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        registerBytes.replaceSubrange(0..<byteCount, with: lhs)
        if length == .xmm128 {
          registerBytes.replaceSubrange(
            byteCount..<32, with: repeatElement(0, count: 32 - byteCount))
        }
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .vexCompareScalar(let ordered, let doublePrecision, let destination, let source):
        // VUCOMISS/COMISS/VUCOMISD/COMISD: compare and set EFLAGS.
        let elementSize = doublePrecision ? 8 : 4
        let lhs = Array(state.floatingPoint.ymm[Int(destination)].bytes.prefix(elementSize))
        let rhs = try readVectorBytes(
          source, byteCount: elementSize, instruction: instruction,
          state: state, memory: executionMemory)
        let unordered: Bool
        let equal: Bool
        let lessThan: Bool
        if doublePrecision {
          let a = Double(bitPattern: fromLittleEndian(lhs))
          let b = Double(bitPattern: fromLittleEndian(rhs))
          unordered = a.isNaN || b.isNaN
          equal = !unordered && a == b
          lessThan = !unordered && a < b
        } else {
          let a = Float(bitPattern: UInt32(truncatingIfNeeded: fromLittleEndian(lhs)))
          let b = Float(bitPattern: UInt32(truncatingIfNeeded: fromLittleEndian(rhs)))
          unordered = a.isNaN || b.isNaN
          equal = !unordered && a == b
          lessThan = !unordered && a < b
        }
        // Set EFLAGS: ZF, PF, CF. For ordered compare, unordered sets all three.
        state.rflags.remove([.zero, .parity, .carry])
        if unordered {
          state.rflags.insert([.zero, .parity, .carry])
        } else if equal {
          state.rflags.insert(.zero)
        } else if lessThan {
          state.rflags.insert(.carry)
        }
        // OF=0, SF=0, AF=0
        state.rflags.remove([.overflow, .sign, .auxiliaryCarry])
      case .vexComparePackedIntegers(let greaterThan, let laneWidth, let destination, let firstSource, let secondSource, let length):
        let byteCount = Int(length.rawValue)
        let laneByteCount = Int(laneWidth.rawValue)
        let laneCount = byteCount / laneByteCount
        let lhs = Array(state.floatingPoint.ymm[Int(firstSource)].bytes.prefix(byteCount))
        let rhs = try readVectorBytes(
          secondSource, byteCount: byteCount, instruction: instruction,
          state: state, memory: executionMemory)
        var result = [UInt8](repeating: 0, count: byteCount)
        for lane in 0..<laneCount {
          let offset = lane * laneByteCount
          let lhsValue = fromLittleEndian(Array(lhs[offset..<offset + laneByteCount]))
          let rhsValue = fromLittleEndian(Array(rhs[offset..<offset + laneByteCount]))
          let match: Bool
          if greaterThan {
            switch laneWidth {
            case .byte:
              match = Int8(bitPattern: UInt8(truncatingIfNeeded: lhsValue))
                > Int8(bitPattern: UInt8(truncatingIfNeeded: rhsValue))
            case .word:
              match = Int16(bitPattern: UInt16(truncatingIfNeeded: lhsValue))
                > Int16(bitPattern: UInt16(truncatingIfNeeded: rhsValue))
            case .doubleword:
              match = Int32(bitPattern: UInt32(truncatingIfNeeded: lhsValue))
                > Int32(bitPattern: UInt32(truncatingIfNeeded: rhsValue))
            case .quadword:
              match = Int64(bitPattern: lhsValue) > Int64(bitPattern: rhsValue)
            }
          } else {
            match = lhsValue == rhsValue
          }
          let mask: UInt8 = match ? 0xFF : 0
          for i in 0..<laneByteCount {
            result[offset + i] = mask
          }
        }
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        registerBytes.replaceSubrange(0..<byteCount, with: result)
        if length == .xmm128 {
          registerBytes.replaceSubrange(
            byteCount..<32, with: repeatElement(0, count: 32 - byteCount))
        }
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .vexAddPackedIntegers(let laneWidth, let destination, let firstSource, let secondSource, let length):
        let byteCount = Int(length.rawValue)
        let laneByteCount = Int(laneWidth.rawValue)
        let laneCount = byteCount / laneByteCount
        let lhs = Array(state.floatingPoint.ymm[Int(firstSource)].bytes.prefix(byteCount))
        let rhs = try readVectorBytes(
          secondSource, byteCount: byteCount, instruction: instruction,
          state: state, memory: executionMemory)
        var result = [UInt8](repeating: 0, count: byteCount)
        for lane in 0..<laneCount {
          let offset = lane * laneByteCount
          let lhsValue = fromLittleEndian(Array(lhs[offset..<offset + laneByteCount]))
          let rhsValue = fromLittleEndian(Array(rhs[offset..<offset + laneByteCount]))
          let sum = lhsValue &+ rhsValue
          for i in 0..<laneByteCount {
            result[offset + i] = UInt8(truncatingIfNeeded: sum >> UInt64(i * 8))
          }
        }
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        registerBytes.replaceSubrange(0..<byteCount, with: result)
        if length == .xmm128 {
          registerBytes.replaceSubrange(
            byteCount..<32, with: repeatElement(0, count: 32 - byteCount))
        }
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .vexLoadMXCSR(let source):
        let value = try read(
          source, instruction: instruction, state: state, memory: executionMemory)
        state.floatingPoint.mxcsr = UInt32(truncatingIfNeeded: value)
      case .vexStoreMXCSR(let destination):
        try write(
          UInt64(state.floatingPoint.mxcsr), to: destination,
          instruction: instruction, state: &state, memory: executionMemory)
      case .vexMaskMove(let destination, let source):
        // KMOVD: move 32 bits from GPR/memory to mask register (low 32 bits of XMM).
        let value = try read(
          source, instruction: instruction, state: state, memory: executionMemory)
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        let bits = UInt32(truncatingIfNeeded: value)
        for i in 0..<4 {
          registerBytes[i] = UInt8(truncatingIfNeeded: bits >> UInt32(i * 8))
        }
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .vexPackedMinMax(let signed, let minimum, let laneWidth, let destination, let firstSource, let secondSource, let length):
        let byteCount = Int(length.rawValue)
        let laneByteCount = Int(laneWidth.rawValue)
        let laneCount = byteCount / laneByteCount
        let lhs = Array(state.floatingPoint.ymm[Int(firstSource)].bytes.prefix(byteCount))
        let rhs = try readVectorBytes(
          secondSource, byteCount: byteCount, instruction: instruction,
          state: state, memory: executionMemory)
        var result = [UInt8](repeating: 0, count: byteCount)
        for lane in 0..<laneCount {
          let offset = lane * laneByteCount
          let lhsVal = fromLittleEndian(Array(lhs[offset..<offset + laneByteCount]))
          let rhsVal = fromLittleEndian(Array(rhs[offset..<offset + laneByteCount]))
          let pickLhs: Bool
          if signed {
            let lhsSigned = Int64(bitPattern: lhsVal)
            let rhsSigned = Int64(bitPattern: rhsVal)
            pickLhs = minimum ? (lhsSigned < rhsSigned) : (lhsSigned > rhsSigned)
          } else {
            pickLhs = minimum ? (lhsVal < rhsVal) : (lhsVal > rhsVal)
          }
          let winner = pickLhs ? lhsVal : rhsVal
          for i in 0..<laneByteCount {
            result[offset + i] = UInt8(truncatingIfNeeded: winner >> UInt64(i * 8))
          }
        }
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        registerBytes.replaceSubrange(0..<byteCount, with: result)
        if length == .xmm128 {
          registerBytes.replaceSubrange(
            byteCount..<32, with: repeatElement(0, count: 32 - byteCount))
        }
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .vexSubPackedIntegers(let laneWidth, let saturating, let unsigned, let destination, let firstSource, let secondSource, let length):
        let byteCount = Int(length.rawValue)
        let laneByteCount = Int(laneWidth.rawValue)
        let laneCount = byteCount / laneByteCount
        let lhs = Array(state.floatingPoint.ymm[Int(firstSource)].bytes.prefix(byteCount))
        let rhs = try readVectorBytes(
          secondSource, byteCount: byteCount, instruction: instruction,
          state: state, memory: executionMemory)
        var result = [UInt8](repeating: 0, count: byteCount)
        for lane in 0..<laneCount {
          let offset = lane * laneByteCount
          let lhsVal = fromLittleEndian(Array(lhs[offset..<offset + laneByteCount]))
          let rhsVal = fromLittleEndian(Array(rhs[offset..<offset + laneByteCount]))
          let diff: UInt64
          if saturating {
            if unsigned {
              diff = lhsVal >= rhsVal ? lhsVal &- rhsVal : 0
            } else {
              let l = Int64(bitPattern: lhsVal)
              let r = Int64(bitPattern: rhsVal)
              let res = l &- r
              if res < 0 {
                diff = 0
              } else if res > Int64(UInt64.max >> 1) {
                diff = UInt64.max
              } else {
                diff = UInt64(res)
              }
            }
          } else {
            diff = lhsVal &- rhsVal
          }
          for i in 0..<laneByteCount {
            result[offset + i] = UInt8(truncatingIfNeeded: diff >> UInt64(i * 8))
          }
        }
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        registerBytes.replaceSubrange(0..<byteCount, with: result)
        if length == .xmm128 {
          registerBytes.replaceSubrange(
            byteCount..<32, with: repeatElement(0, count: 32 - byteCount))
        }
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .vexVariableShift(let arithmetic, let laneWidth, let destination, let firstSource, let secondSource, let length):
        let byteCount = Int(length.rawValue)
        let laneByteCount = Int(laneWidth.rawValue)
        let laneCount = byteCount / laneByteCount
        let lhs = Array(state.floatingPoint.ymm[Int(firstSource)].bytes.prefix(byteCount))
        let rhs = try readVectorBytes(
          secondSource, byteCount: byteCount, instruction: instruction,
          state: state, memory: executionMemory)
        var result = [UInt8](repeating: 0, count: byteCount)
        for lane in 0..<laneCount {
          let offset = lane * laneByteCount
          let lhsVal = fromLittleEndian(Array(lhs[offset..<offset + laneByteCount]))
          let shiftAmount = Int(rhs[offset] & 0x1F)  // use low byte, mask to lane width
          let shifted: UInt64
          if arithmetic {
            if shiftAmount < 64 {
              let signed = Int64(bitPattern: lhsVal)
              shifted = UInt64(bitPattern: signed >> shiftAmount)
            } else {
              shifted = lhsVal & (1 << 63) != 0 ? UInt64.max : 0
            }
          } else {
            shifted = shiftAmount < 64 ? (lhsVal >> UInt64(shiftAmount)) : 0
          }
          for i in 0..<laneByteCount {
            result[offset + i] = UInt8(truncatingIfNeeded: shifted >> UInt64(i * 8))
          }
        }
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        registerBytes.replaceSubrange(0..<byteCount, with: result)
        if length == .xmm128 {
          registerBytes.replaceSubrange(
            byteCount..<32, with: repeatElement(0, count: 32 - byteCount))
        }
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .vexScalarConvert(let direction, let destination, let firstSource, let secondSource):
        let sourceBytes = try readVectorBytes(
          secondSource, byteCount: direction == .doubleToSingle ? 8 : 4,
          instruction: instruction, state: state, memory: executionMemory)
        var registerBytes = Array(state.floatingPoint.ymm[Int(firstSource)].bytes.prefix(16))
        switch direction {
        case .doubleToSingle:
          let doubleValue = Double(bitPattern: fromLittleEndian(sourceBytes))
          let singleValue = Float(doubleValue)
          let singleBits = littleEndian(UInt64(singleValue.bitPattern), width: .doubleword)
          registerBytes.replaceSubrange(0..<4, with: singleBits)
        case .singleToDouble:
          let singleValue = Float(bitPattern: UInt32(truncatingIfNeeded: fromLittleEndian(sourceBytes)))
          let doubleValue = Double(singleValue)
          let doubleBits = littleEndian(doubleValue.bitPattern, width: .quadword)
          registerBytes.replaceSubrange(0..<8, with: doubleBits)
        }
        var destBytes = state.floatingPoint.ymm[Int(destination)].bytes
        destBytes.replaceSubrange(0..<16, with: registerBytes)
        destBytes.replaceSubrange(16..<32, with: repeatElement(0, count: 16))
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: destBytes, expectedByteCount: 32)
      case .vexConvertScalarToInteger(let truncated, let doublePrecision, let destination, let source):
        let sourceBytes = Array(state.floatingPoint.ymm[Int(source)].bytes.prefix(doublePrecision ? 8 : 4))
        let intValue: UInt64
        if doublePrecision {
          let value = Double(bitPattern: fromLittleEndian(sourceBytes))
          intValue = truncated ? UInt64(bitPattern: Int64(value.rounded(.towardZero))) : UInt64(value.rounded(.toNearestOrEven))
        } else {
          let value = Float(bitPattern: UInt32(truncatingIfNeeded: fromLittleEndian(sourceBytes)))
          intValue = truncated ? UInt64(bitPattern: Int64(value.rounded(.towardZero))) : UInt64(value.rounded(.toNearestOrEven))
        }
        try write(
          intValue, to: destination,
          instruction: instruction, state: &state, memory: executionMemory)
      case .vexUnpackLow(let doublePrecision, let destination, let firstSource, let secondSource, let length):
        let byteCount = Int(length.rawValue)
        let lhs = Array(state.floatingPoint.ymm[Int(firstSource)].bytes.prefix(byteCount))
        let rhs = try readVectorBytes(
          secondSource, byteCount: byteCount, instruction: instruction,
          state: state, memory: executionMemory)
        var result = [UInt8](repeating: 0, count: byteCount)
        if doublePrecision {
          // Interleave low doubles: dst[0]=lhs[0], dst[1]=rhs[0]
          result.replaceSubrange(0..<8, with: lhs[0..<8])
          result.replaceSubrange(8..<16, with: rhs[0..<8])
        } else {
          // Interleave low singles: dst[0]=lhs[0], dst[1]=rhs[0], dst[2]=lhs[1], dst[3]=rhs[1]
          result.replaceSubrange(0..<4, with: lhs[0..<4])
          result.replaceSubrange(4..<8, with: rhs[0..<4])
          result.replaceSubrange(8..<12, with: lhs[4..<8])
          result.replaceSubrange(12..<16, with: rhs[4..<8])
        }
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        registerBytes.replaceSubrange(0..<byteCount, with: result)
        if length == .xmm128 {
          registerBytes.replaceSubrange(
            byteCount..<32, with: repeatElement(0, count: 32 - byteCount))
        }
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .vexUnpackHigh(let doublePrecision, let destination, let firstSource, let secondSource, let length):
        let byteCount = Int(length.rawValue)
        let lhs = Array(state.floatingPoint.ymm[Int(firstSource)].bytes.prefix(byteCount))
        let rhs = try readVectorBytes(
          secondSource, byteCount: byteCount, instruction: instruction,
          state: state, memory: executionMemory)
        var result = [UInt8](repeating: 0, count: byteCount)
        if doublePrecision {
          // Interleave high doubles: dst[0]=lhs[1], dst[1]=rhs[1]
          result.replaceSubrange(0..<8, with: lhs[8..<16])
          result.replaceSubrange(8..<16, with: rhs[8..<16])
        } else {
          // Interleave high singles: dst[0]=lhs[2], dst[1]=rhs[2], dst[2]=lhs[3], dst[3]=rhs[3]
          result.replaceSubrange(0..<4, with: lhs[8..<12])
          result.replaceSubrange(4..<8, with: rhs[8..<12])
          result.replaceSubrange(8..<12, with: lhs[12..<16])
          result.replaceSubrange(12..<16, with: rhs[12..<16])
        }
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        registerBytes.replaceSubrange(0..<byteCount, with: result)
        if length == .xmm128 {
          registerBytes.replaceSubrange(
            byteCount..<32, with: repeatElement(0, count: 32 - byteCount))
        }
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .vexComparePackedBytes(let destination, let firstSource, let secondSource, let length):
        let byteCount = Int(length.rawValue)
        let lhs = Array(state.floatingPoint.ymm[Int(firstSource)].bytes.prefix(byteCount))
        let rhs = try readVectorBytes(
          secondSource, byteCount: byteCount, instruction: instruction,
          state: state, memory: executionMemory)
        var result = [UInt8](repeating: 0, count: byteCount)
        for i in 0..<byteCount {
          result[i] = lhs[i] == rhs[i] ? 0xFF : 0
        }
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        registerBytes.replaceSubrange(0..<byteCount, with: result)
        if length == .xmm128 {
          registerBytes.replaceSubrange(
            byteCount..<32, with: repeatElement(0, count: 32 - byteCount))
        }
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .vexMoveMaskToInteger(let destination, let source, let length):
        let byteCount = Int(length.rawValue)
        let vectorBytes = state.floatingPoint.ymm[Int(source)].bytes
        var mask: UInt64 = 0
        for i in 0..<byteCount {
          if vectorBytes[i] & 0x80 != 0 { mask |= 1 << i }
        }
        try write(
          mask, to: destination, instruction: instruction,
          state: &state, memory: executionMemory)
      case .vexMoveIntegerToVector(let destination, let source, let quadword):
        let width = quadword ? DoryX86OperandWidth.quadword : .doubleword
        let value = try read(
          source, instruction: instruction, state: state, memory: executionMemory)
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        registerBytes.replaceSubrange(0..<16, with: repeatElement(0, count: 16))
        registerBytes.replaceSubrange(0..<width.byteCount, with: littleEndian(value, width: width))
        registerBytes.replaceSubrange(16..<32, with: repeatElement(0, count: 16))
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .vexMoveVectorToInteger(let destination, let source, let quadword):
        let width = quadword ? DoryX86OperandWidth.quadword : .doubleword
        let value = fromLittleEndian(
          Array(state.floatingPoint.ymm[Int(source)].bytes.prefix(width.byteCount)))
        try write(
          value, to: destination, instruction: instruction,
          state: &state, memory: executionMemory)
      case .vexShufflePackedBytes(let destination, let firstSource, let secondSource, let length):
        let byteCount = Int(length.rawValue)
        let indices = try readVectorBytes(
          secondSource, byteCount: byteCount, instruction: instruction,
          state: state, memory: executionMemory)
        var table = state.floatingPoint.ymm[Int(firstSource)].bytes
        var result = [UInt8](repeating: 0, count: byteCount)
        for lane in 0..<byteCount {
          let index = indices[lane]
          if index & 0x80 != 0 {
            result[lane] = 0
          } else {
            result[lane] = table[Int(index) & (byteCount - 1)]
          }
        }
        table.replaceSubrange(0..<byteCount, with: result)
        if length == .xmm128 {
          table.replaceSubrange(byteCount..<32, with: repeatElement(0, count: 32 - byteCount))
        }
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: table, expectedByteCount: 32)
      case .vexVectorShiftImmediate(let operation, let destination, let source, let immediate, let laneWidth, let length):
        // VPSRLQ/VPSLLQ/VPSRAD: shift each lane of source by immediate.
        let byteCount = Int(length.rawValue)
        let laneByteCount = Int(laneWidth.rawValue)
        let laneCount = byteCount / laneByteCount
        var sourceBytes = state.floatingPoint.ymm[Int(source)].bytes
        var result = [UInt8](repeating: 0, count: byteCount)
        let shift = Int(immediate)
        for lane in 0..<laneCount {
          let offset = lane * laneByteCount
          let laneValue = fromLittleEndian(Array(sourceBytes[offset..<offset + laneByteCount]))
          let shifted: UInt64
          switch operation {
          case .logicalLeft:
            shifted = shift < 64 ? (laneValue << UInt64(shift)) : 0
          case .logicalRight:
            shifted = shift < 64 ? (laneValue >> UInt64(shift)) : 0
          case .arithmeticRight:
            if shift < 64 {
              let signed = Int64(bitPattern: laneValue)
              shifted = UInt64(bitPattern: signed >> shift)
            } else {
              shifted = laneValue & (1 << 63) != 0 ? UInt64.max : 0
            }
          }
          for i in 0..<laneByteCount {
            result[offset + i] = UInt8(truncatingIfNeeded: shifted >> UInt64(i * 8))
          }
        }
        sourceBytes.replaceSubrange(0..<byteCount, with: result)
        if length == .xmm128 {
          sourceBytes.replaceSubrange(byteCount..<32, with: repeatElement(0, count: 32 - byteCount))
        }
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: sourceBytes, expectedByteCount: 32)
      case .vexBroadcast(let destination, let source, let mode, let length):
        let byteCount = Int(length.rawValue)
        let sourceBytes = try readVectorBytes(
          source, byteCount: mode == .packed128 ? 16 : (mode == .double64 ? 8 : 4),
          instruction: instruction, state: state, memory: executionMemory)
        var result = [UInt8](repeating: 0, count: byteCount)
        switch mode {
        case .single32:
          let element = Array(sourceBytes.prefix(4))
          for offset in stride(from: 0, to: byteCount, by: 4) {
            result.replaceSubrange(offset..<offset + 4, with: element)
          }
        case .double64:
          let element = Array(sourceBytes.prefix(8))
          for offset in stride(from: 0, to: byteCount, by: 8) {
            result.replaceSubrange(offset..<offset + 8, with: element)
          }
        case .packed128:
          let element = Array(sourceBytes.prefix(16))
          result.replaceSubrange(0..<16, with: element)
          if byteCount == 32 {
            result.replaceSubrange(16..<32, with: element)
          }
        }
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        registerBytes.replaceSubrange(0..<byteCount, with: result)
        if length == .xmm128 {
          registerBytes.replaceSubrange(
            byteCount..<32, with: repeatElement(0, count: 32 - byteCount))
        }
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .moveIntegerToVector(let destination, let source):
        let width = operandWidth(source)
        let value = try read(
          source, instruction: instruction, state: state, memory: executionMemory)
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        registerBytes.replaceSubrange(0..<16, with: repeatElement(0, count: 16))
        registerBytes.replaceSubrange(0..<width.byteCount, with: littleEndian(value, width: width))
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .moveVectorToInteger(let destination, let source):
        let width = operandWidth(destination)
        let value = fromLittleEndian(
          Array(state.floatingPoint.ymm[Int(source)].bytes.prefix(width.byteCount)))
        try write(
          value,
          to: destination,
          instruction: instruction,
          state: &state,
          memory: executionMemory
        )
      case .extractPackedWord(let destination, let source, let encodedIndex, let mmx):
        let bytes =
          mmx
          ? state.floatingPoint.x87[Int(source)].bytes
          : state.floatingPoint.ymm[Int(source)].bytes
        let laneCount: UInt8 = mmx ? 4 : 8
        let offset = Int(encodedIndex % laneCount) * 2
        try write(
          fromLittleEndian(Array(bytes[offset..<(offset + 2)])),
          to: destination,
          instruction: instruction,
          state: &state,
          memory: executionMemory
        )
      case .moveVectorMask(let destination, let source, let laneWidth, let vectorByteCount):
        let count = Int(vectorByteCount)
        let bytes =
          if count == 8 {
            try readMMXBytes(
              source,
              byteCount: count,
              instruction: instruction,
              state: state,
              memory: executionMemory
            )
          } else {
            try readVectorBytes(
              source,
              byteCount: count,
              instruction: instruction,
              state: state,
              memory: executionMemory
            )
          }
        let laneBytes = Int(laneWidth.rawValue)
        var mask: UInt64 = 0
        for lane in 0..<(count / laneBytes) where bytes[(lane + 1) * laneBytes - 1] & 0x80 != 0 {
          mask |= UInt64(1) << UInt64(lane)
        }
        try write(
          mask,
          to: destination,
          instruction: instruction,
          state: &state,
          memory: executionMemory
        )
      case .vectorBitwise(let operation, let destination, let source):
        let rhs = try readVectorBytes(
          source,
          byteCount: 16,
          instruction: instruction,
          state: state,
          memory: executionMemory
        )
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        for index in 0..<16 {
          let lhs = registerBytes[index]
          registerBytes[index] =
            switch operation {
            case .and: lhs & rhs[index]
            case .andNot: ~lhs & rhs[index]
            case .or: lhs | rhs[index]
            case .xor: lhs ^ rhs[index]
            }
        }
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .vectorFloatingBinary(let operation, let format, let destination, let source):
        let rhs = try readVectorBytes(
          source,
          byteCount: 16,
          instruction: instruction,
          state: state,
          memory: executionMemory
        )
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        executeVectorFloatingBinary(
          operation,
          format: format,
          destination: &registerBytes,
          source: rhs
        )
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .scalarCompare(let predicate, let format, let destination, let source):
        // CMPSS/CMPSD: compare low scalar elements, set low element to mask.
        let elementSize = format == .scalarDouble ? 8 : 4
        let rhs = try readVectorBytes(
          source, byteCount: elementSize,
          instruction: instruction, state: state, memory: executionMemory)
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        let lhs = Array(registerBytes.prefix(elementSize))
        let result: Bool
        if format == .scalarDouble {
          let a = Double(bitPattern: fromLittleEndian(lhs))
          let b = Double(bitPattern: fromLittleEndian(rhs))
          result = evaluateScalarCompare(predicate, a: a, b: b)
        } else {
          let a = Float(bitPattern: UInt32(truncatingIfNeeded: fromLittleEndian(lhs)))
          let b = Float(bitPattern: UInt32(truncatingIfNeeded: fromLittleEndian(rhs)))
          result = evaluateScalarCompare(predicate, a: Double(a), b: Double(b))
        }
        let mask: [UInt8] = Array(repeating: result ? 0xFF : 0, count: elementSize)
        registerBytes.replaceSubrange(0..<elementSize, with: mask)
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .scalarConvert(let direction, let destination, let source):
        // CVTSD2SS / CVTSS2SD: convert scalar double↔single.
        let sourceBytes = try readVectorBytes(
          source, byteCount: direction == .doubleToSingle ? 8 : 4,
          instruction: instruction, state: state, memory: executionMemory)
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        switch direction {
        case .doubleToSingle:
          let doubleValue = Double(bitPattern: fromLittleEndian(sourceBytes))
          let singleValue = Float(doubleValue)
          let singleBits = littleEndian(UInt64(singleValue.bitPattern), width: .doubleword)
          registerBytes.replaceSubrange(0..<4, with: singleBits)
        case .singleToDouble:
          let singleValue = Float(bitPattern: UInt32(truncatingIfNeeded: fromLittleEndian(sourceBytes)))
          let doubleValue = Double(singleValue)
          let doubleBits = littleEndian(doubleValue.bitPattern, width: .quadword)
          registerBytes.replaceSubrange(0..<8, with: doubleBits)
        }
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .scalarSquareRoot(let format, let destination, let source):
        // SQRTSS / SQRTSD: scalar square root of low element.
        let elementSize = format == .scalarDouble ? 8 : 4
        let sourceBytes = try readVectorBytes(
          source, byteCount: elementSize,
          instruction: instruction, state: state, memory: executionMemory)
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        if format == .scalarDouble {
          let value = Double(bitPattern: fromLittleEndian(sourceBytes))
          let result = value.squareRoot()
          registerBytes.replaceSubrange(0..<8, with: littleEndian(result.bitPattern, width: .quadword))
        } else {
          let value = Float(bitPattern: UInt32(truncatingIfNeeded: fromLittleEndian(sourceBytes)))
          let result = value.squareRoot()
          registerBytes.replaceSubrange(0..<4, with: littleEndian(UInt64(result.bitPattern), width: .doubleword))
        }
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .vectorIntegerBinary(let operation, let laneWidth, let destination, let source):
        let rhs = try readVectorBytes(
          source,
          byteCount: 16,
          instruction: instruction,
          state: state,
          memory: executionMemory
        )
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        executeVectorIntegerBinary(
          operation,
          laneWidth: laneWidth,
          destination: &registerBytes,
          source: rhs
        )
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .vectorIntegerShift(let operation, let laneWidth, let destination, let countSource):
        let count: UInt64
        switch countSource {
        case .immediate(let immediate):
          count = UInt64(immediate)
        case .vector(let source):
          let bytes = try readVectorBytes(
            source,
            byteCount: 16,
            instruction: instruction,
            state: state,
            memory: executionMemory
          )
          count = fromLittleEndian(Array(bytes.prefix(8)))
        }
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        executeVectorIntegerShift(
          operation,
          laneWidth: laneWidth,
          destination: &registerBytes,
          count: count
        )
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .vectorByteShift(let left, let destination, let encodedCount):
        let count = min(Int(encodedCount), 16)
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        let low128 = Array(registerBytes.prefix(16))
        let zeros = Array(repeating: UInt8(0), count: count)
        let shifted: [UInt8]
        if left {
          shifted = zeros + Array(low128.prefix(16 - count))
        } else {
          shifted = Array(low128.dropFirst(count)) + zeros
        }
        registerBytes.replaceSubrange(0..<16, with: shifted)
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .vectorFloatingCompare(let format, let destination, let source, _):
        let byteCount = format == .scalarDouble ? 8 : 4
        let rhs = try readVectorBytes(
          source,
          byteCount: byteCount,
          instruction: instruction,
          state: state,
          memory: executionMemory
        )
        let lhs = Array(state.floatingPoint.ymm[Int(destination)].bytes.prefix(byteCount))
        let relation: FloatingComparison
        if format == .scalarDouble {
          relation = floatingComparison(
            Double(bitPattern: fromLittleEndian(lhs)),
            Double(bitPattern: fromLittleEndian(rhs))
          )
        } else {
          relation = floatingComparison(
            Float(bitPattern: UInt32(fromLittleEndian(lhs))),
            Float(bitPattern: UInt32(fromLittleEndian(rhs)))
          )
        }
        state.rflags.remove([.overflow, .sign, .auxiliaryCarry, .zero, .parity, .carry])
        switch relation {
        case .greater:
          break
        case .less:
          state.rflags.insert(.carry)
        case .equal:
          state.rflags.insert(.zero)
        case .unordered:
          state.rflags.insert([.zero, .parity, .carry])
        }
      case .vectorIntegerInterleave(let high, let laneWidth, let destination, let source):
        let rhs = try readVectorBytes(
          source,
          byteCount: 16,
          instruction: instruction,
          state: state,
          memory: executionMemory
        )
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        let lhs = Array(registerBytes.prefix(16))
        let laneBytes = Int(laneWidth.rawValue)
        let lanesPerInput = 8 / laneBytes
        let inputOffset = high ? 8 : 0
        var result: [UInt8] = []
        result.reserveCapacity(16)
        for lane in 0..<lanesPerInput {
          let offset = inputOffset + lane * laneBytes
          result += lhs[offset..<offset + laneBytes]
          result += rhs[offset..<offset + laneBytes]
        }
        registerBytes.replaceSubrange(0..<16, with: result)
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .vectorIntegerPack(let operation, let sourceLaneWidth, let destination, let source):
        let rhs = try readVectorBytes(
          source,
          byteCount: 16,
          instruction: instruction,
          state: state,
          memory: executionMemory
        )
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        let lhs = Array(registerBytes.prefix(16))
        registerBytes.replaceSubrange(
          0..<16,
          with: packVectorIntegers(
            operation,
            sourceLaneWidth: sourceLaneWidth,
            lhs: lhs,
            rhs: rhs
          )
        )
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .vectorShuffle(let format, let destination, let source, let control):
        if format == .packedLowWords || format == .packedHighWords,
          case .memory(let operand) = source
        {
          // Legacy PSHUFLW/PSHUFHW use a complete aligned 128-bit source.
          // SDM 092 Vol. 2A Table 2-21: Type 4 legacy memory alignment is
          // checked before translation, after the segment/canonical check.
          try validateFloatingPointTransfer(operand, byteCount: 16, write: false,
            instruction: instruction, state: state)
          if effectiveAddress(operand, instruction: instruction, state: state) & 0xF != 0 {
            return generalProtection(at: originalRIP)
          }
        }
        let rhs = try readVectorBytes(
          source,
          byteCount: 16,
          instruction: instruction,
          state: state,
          memory: executionMemory
        )
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        let lhs = Array(registerBytes.prefix(16))
        registerBytes.replaceSubrange(
          0..<16,
          with: shuffleVector(format: format, lhs: lhs, rhs: rhs, control: control)
        )
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .convertIntegerToScalarFloat(let format, let destination, let source):
        let width = operandWidth(source)
        let raw = try read(
          source, instruction: instruction, state: state, memory: executionMemory)
        let integer = signExtendedInt64(raw, width: width)
        var registerBytes = state.floatingPoint.ymm[Int(destination)].bytes
        if format == .scalarSingle {
          replaceLittleEndian(Float(integer).bitPattern, in: &registerBytes, at: 0)
        } else {
          replaceLittleEndian(Double(integer).bitPattern, in: &registerBytes, at: 0)
        }
        state.floatingPoint.ymm[Int(destination)] = try .init(
          bytes: registerBytes, expectedByteCount: 32)
      case .convertScalarFloatToInteger(
        let format, let destination, let source, let truncate):
        let byteCount = format == .scalarDouble ? 8 : 4
        let bytes = try readVectorBytes(
          source,
          byteCount: byteCount,
          instruction: instruction,
          state: state,
          memory: executionMemory
        )
        let width = operandWidth(destination)
        let value: UInt64
        if format == .scalarDouble {
          value = floatingIntegerResult(
            Double(bitPattern: fromLittleEndian(bytes)),
            width: width,
            truncate: truncate,
            mxcsr: state.floatingPoint.mxcsr
          )
        } else {
          value = floatingIntegerResult(
            Float(bitPattern: UInt32(fromLittleEndian(bytes))),
            width: width,
            truncate: truncate,
            mxcsr: state.floatingPoint.mxcsr
          )
        }
        try write(
          value,
          to: destination,
          instruction: instruction,
          state: &state,
          memory: executionMemory
        )
      case .processorPause:
        break
      case .string(let operation, let width):
        let completed = try executeString(
          operation,
          width: width,
          instruction: instruction,
          mode: mode,
          state: &state,
          memory: executionMemory,
          ioBus: ioBus
        )
        if !completed {
          state.rip = originalRIP
          return .yielded(instruction)
        }
      case .input(let portOperand, let width):
        let port = ioPort(portOperand, state: state)
        guard let ioBus,
          try permitsPortIO(
            port: port,
            width: width,
            mode: mode,
            state: state,
            memory: executionMemory
          )
        else {
          return generalProtection(at: originalRIP)
        }
        let value = UInt64(try ioBus.read(port: port, width: width))
        try write(
          value,
          to: .register(.rax, width: width),
          instruction: instruction,
          state: &state,
          memory: executionMemory
        )
      case .output(let portOperand, let width):
        let port = ioPort(portOperand, state: state)
        guard let ioBus,
          try permitsPortIO(
            port: port,
            width: width,
            mode: mode,
            state: state,
            memory: executionMemory
          )
        else {
          return generalProtection(at: originalRIP)
        }
        try ioBus.write(
          port: port,
          value: UInt32(truncatingIfNeeded: state.registers.rax & mask(width)),
          width: width
        )
      case .push(let operand):
        let value = try read(
          operand, instruction: instruction, state: state, memory: executionMemory)
        let width = operandWidth(operand)
        try pushStack(
          value,
          width: width,
          instruction: instruction,
          mode: mode,
          state: &state,
          memory: executionMemory
        )
      case .pop(let operand):
        let width = operandWidth(operand)
        let value = try popStack(
          width: width,
          instruction: instruction,
          mode: mode,
          state: &state,
          memory: executionMemory
        )
        try write(
          value, to: operand, instruction: instruction, state: &state, memory: executionMemory)
      case .call(let relative):
        let returnWidth = nearTransferWidth(instruction, mode: mode)
        let target = addRelative(nextRIP, relative) & mask(returnWidth)
        try validateNearBranchTarget(target, mode: mode, instruction: instruction, state: state)
        try pushStack(
          nextRIP,
          width: returnWidth,
          instruction: instruction,
          mode: mode,
          state: &state,
          memory: executionMemory
        )
        nextRIP = target
      case .callIndirect(let operand):
        let target = try read(
          operand, instruction: instruction, state: state, memory: executionMemory)
        try validateNearBranchTarget(target, mode: mode, instruction: instruction, state: state)
        let width = operandWidth(operand)
        try pushStack(
          nextRIP,
          width: width,
          instruction: instruction,
          mode: mode,
          state: &state,
          memory: executionMemory
        )
        nextRIP = target
      case .return:
        let returnWidth = nearTransferWidth(instruction, mode: mode)
        nextRIP = try popStack(
          width: returnWidth,
          instruction: instruction,
          mode: mode,
          state: &state,
          memory: executionMemory
        )
        try validateNearBranchTarget(nextRIP, mode: mode, instruction: instruction, state: state)
      case .returnAndPop(let popBytes):
        let returnWidth = nearTransferWidth(instruction, mode: mode)
        nextRIP = try popStack(
          width: returnWidth,
          instruction: instruction,
          mode: mode,
          state: &state,
          memory: executionMemory
        )
        try validateNearBranchTarget(nextRIP, mode: mode, instruction: instruction, state: state)
        let adjustedStack =
          (stackPointerOffset(mode: mode, state: state) &+ UInt64(popBytes))
          & mask(stackPointerWidth(mode: mode, state: state))
        writeStackPointer(adjustedStack, mode: mode, state: &state)
      case .jump(let relative):
        nextRIP = addRelative(nextRIP, relative) & mask(nearTransferWidth(instruction, mode: mode))
        try validateNearBranchTarget(nextRIP, mode: mode, instruction: instruction, state: state)
      case .jumpIndirect(let operand):
        nextRIP = try read(
          operand, instruction: instruction, state: state, memory: executionMemory)
        try validateNearBranchTarget(nextRIP, mode: mode, instruction: instruction, state: state)
      case .conditionalJump(let condition, let relative):
        if evaluate(condition, flags: state.rflags) {
          nextRIP = addRelative(nextRIP, relative) & mask(nearTransferWidth(instruction, mode: mode))
          try validateNearBranchTarget(nextRIP, mode: mode, instruction: instruction, state: state)
        }
      case .loop(let condition, let relative, let counterWidth):
        var count = stringRegister(.rcx, width: counterWidth, state: state)
        if condition != .countZero {
          count = (count &- 1) & mask(counterWidth)
          writeStringRegister(
            .rcx,
            value: count,
            width: counterWidth,
            state: &state
          )
        }
        let branches =
          switch condition {
          case .countNonzero: count != 0
          case .countNonzeroAndZero: count != 0 && state.rflags.contains(.zero)
          case .countNonzeroAndNotZero: count != 0 && !state.rflags.contains(.zero)
          case .countZero: count == 0
          }
        if branches {
          nextRIP = addRelative(nextRIP, relative) & mask(nearTransferWidth(instruction, mode: mode))
          try validateNearBranchTarget(nextRIP, mode: mode, instruction: instruction, state: state)
        }
      case .enter(let allocation, let nesting, let width):
        try executeEnter(
          allocation: allocation,
          nesting: nesting,
          width: width,
          instruction: instruction,
          mode: mode,
          state: &state,
          memory: executionMemory
        )
      case .translateByte(let addressWidth, let segment, let ignoresLegacySegmentBase):
        let table = DoryX86MemoryOperand(
          base: .rbx,
          displacement: Int64(state.registers.rax & 0xFF),
          width: .byte,
          addressWidth: addressWidth,
          segment: segment,
          ignoresLegacySegmentBase: ignoresLegacySegmentBase
        )
        let value = try read(
          .memory(table), instruction: instruction, state: state, memory: executionMemory)
        state.registers.rax = (state.registers.rax & ~UInt64(0xFF)) | value
      case .cpuid:
        let result = profile.cpuid(
          leaf: UInt32(truncatingIfNeeded: state.registers.rax),
          subleaf: UInt32(truncatingIfNeeded: state.registers.rcx),
          processorID: processorID,
          logicalProcessorCount: logicalProcessorCount,
          cr4: state.control.cr4,
          xcr0: state.control.xcr0
        )
        state.registers.rax = UInt64(result.eax)
        state.registers.rbx = UInt64(result.ebx)
        state.registers.rcx = UInt64(result.ecx)
        state.registers.rdx = UInt64(result.edx)
      case .readControlRegister(let index, let destination):
        guard currentPrivilegeLevel(state, mode: mode) == 0,
          let value = readControlRegister(index, state: state)
        else {
          return generalProtection(at: originalRIP)
        }
        state.registers[destination] = value
      case .writeControlRegister(let index, let source):
        guard currentPrivilegeLevel(state, mode: mode) == 0,
          writeControlRegister(
            index,
            value: mode == .long64 ? state.registers[source] : state.registers[source] & 0xffff_ffff,
            state: &state,
            physicalMemory: memory,
            pagingUnit: pagingUnit ?? translatedMemory?.translationUnit
          )
        else {
          return generalProtection(at: originalRIP)
        }
      case .readDebugRegister(let index, let destination):
        guard let register = normalizedDebugRegister(index, state: state) else {
          return invalidOpcode(at: originalRIP)
        }
        if let fault = debugRegisterAccessFault(state: &state, mode: mode, at: originalRIP) {
          return fault
        }
        guard let value = readDebugRegister(register, state: state) else {
          return invalidOpcode(at: originalRIP)
        }
        // Intel SDM Vol. 3A 2.8.5: non-64-bit transfers are always 32 bits.
        state.registers[destination] = mode == .long64 ? value : value & 0xffff_ffff
      case .writeDebugRegister(let index, let source):
        guard let register = normalizedDebugRegister(index, state: state) else {
          return invalidOpcode(at: originalRIP)
        }
        if let fault = debugRegisterAccessFault(state: &state, mode: mode, at: originalRIP) {
          return fault
        }
        let value = mode == .long64 ? state.registers[source] : state.registers[source] & 0xffff_ffff
        guard writeDebugRegister(register, value: value, state: &state) else {
          return generalProtection(at: originalRIP)
        }
      case .readExtendedControlRegister:
        guard profile.supports(.xsave), state.control.cr4 & (1 << 18) != 0 else {
          return invalidOpcode(at: originalRIP)
        }
        guard UInt32(truncatingIfNeeded: state.registers.rcx) == 0 else {
          return generalProtection(at: originalRIP)
        }
        state.registers.rax = UInt64(UInt32(truncatingIfNeeded: state.control.xcr0))
        state.registers.rdx = UInt64(UInt32(truncatingIfNeeded: state.control.xcr0 >> 32))
      case .writeExtendedControlRegister:
        guard profile.supports(.xsave), state.control.cr4 & (1 << 18) != 0 else {
          return invalidOpcode(at: originalRIP)
        }
        let value =
          UInt64(UInt32(truncatingIfNeeded: state.registers.rax))
          | UInt64(UInt32(truncatingIfNeeded: state.registers.rdx)) << 32
        let supportedMask: UInt64 = profile.supports(.avx) ? 0x7 : 0x3
        guard currentPrivilegeLevel(state, mode: mode) == 0,
          UInt32(truncatingIfNeeded: state.registers.rcx) == 0,
          value & ~supportedMask == 0,
          value & 1 == 1,
          value & 4 == 0 || value & 2 != 0
        else {
          return generalProtection(at: originalRIP)
        }
        state.control.xcr0 = value
      case .invalidateCaches:
        guard currentPrivilegeLevel(state, mode: mode) == 0 else {
          return generalProtection(at: originalRIP)
        }
      // The interpreter has no guest-visible data or instruction cache. Every load and store
      // already observes coherent memory, so INVD/WBINVD complete after their privilege check.
      case .invalidatePage(let operand):
        guard currentPrivilegeLevel(state, mode: mode) == 0 else {
          return generalProtection(at: originalRIP)
        }
        (pagingUnit ?? translatedMemory?.translationUnit)?.invalidate(
          linearAddress: effectiveAddress(operand, instruction: instruction, state: state)
        )
      case .descriptorTable(let table, let load, let address):
        let privilege = currentPrivilegeLevel(state, mode: mode)
        if (load && privilege != 0)
          || (!load && privilege != 0 && state.control.cr4 & (1 << 11) != 0)
        {
          return generalProtection(at: originalRIP)
        }
        let linearAddress = effectiveAddress(address, instruction: instruction, state: state)
        let byteCount = mode == .long64 ? 10 : 6
        if mode == .long64 {
          // Segment limits are ignored in 64-bit mode, including FS/GS; their bases
          // still contribute to the explicit operand's canonical linear address.
          let last = linearAddress.addingReportingOverflow(UInt64(byteCount - 1))
          guard !last.overflow,
            DoryX86ArchitecturalState.isCanonical(linearAddress),
            DoryX86ArchitecturalState.isCanonical(last.partialValue)
          else {
            throw address.segment == .ss
              ? stackProtection(at: originalRIP) : segmentProtection(at: originalRIP)
          }
        } else {
          let virtual8086 = state.control.efer & (1 << 10) == 0
            && state.rflags.contains(.virtual8086)
          if mode != .real16, !virtual8086, state.control.cr0 & 1 != 0,
            address.segment != .cs, address.segment != .ss,
            segmentState(address.segment, state: state).selector & ~UInt16(3) == 0
          {
            return generalProtection(at: originalRIP)
          }
          try validateSegmentAccess(
            address, byteCount: byteCount, write: !load,
            instruction: instruction, state: state
          )
        }
        if load {
          let bytes = try executionMemory.read(at: linearAddress, byteCount: byteCount)
          let limit = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
          var base: UInt64 = 0
          for index in 0..<(byteCount - 2) {
            base |= UInt64(bytes[index + 2]) << UInt64(index * 8)
          }
          let default16 = mode == .real16 || mode == .protected16
          if mode != .long64, default16 != instruction.prefixes.operandSizeOverride {
            base &= 0x00ff_ffff
          }
          let value = DoryX86DescriptorTableState(limit: limit, base: base)
          if table == .global { state.gdtr = value } else { state.idtr = value }
        } else {
          let value = table == .global ? state.gdtr : state.idtr
          var bytes = [UInt8(value.limit & 0xff), UInt8(value.limit >> 8)]
          for index in 0..<(byteCount - 2) {
            bytes.append(UInt8(truncatingIfNeeded: value.base >> UInt64(index * 8)))
          }
          try executionMemory.validateWrite(at: linearAddress, byteCount: byteCount)
          try executionMemory.write(at: linearAddress, bytes: bytes)
        }
      case .inspectSegmentDescriptor(let accessRights, let destination, let source):
        guard mode != .real16, !state.rflags.contains(.virtual8086) else {
          return invalidOpcode(at: originalRIP)
        }
        let selector = UInt16(
          truncatingIfNeeded: try read(
            source, instruction: instruction, state: state, memory: executionMemory))
        if let descriptor = try descriptorForInspection(
          selector: selector,
          accessRights: accessRights,
          mode: mode,
          state: state,
          memory: executionMemory
        ) {
          let value: UInt64
          if accessRights {
            // Intel defines the returned access byte at bits 15:8 and the AVL/L/D/G flags at
            // bits 23:20. Bits 19:16 are undefined; Dory deterministically returns zero.
            value = (descriptor.raw >> 32) & 0x00F0_FF00
          } else {
            var limit = UInt64(descriptor.raw & 0xffff)
            limit |= ((descriptor.raw >> 48) & 0x0f) << 16
            if descriptor.raw & (1 << 55) != 0 { limit = (limit << 12) | 0xfff }
            value = limit
          }
          try write(
            value,
            to: destination,
            instruction: instruction,
            state: &state,
            memory: executionMemory
          )
          setFlag(.zero, true, in: &state.rflags)
        } else {
          // A rejected selector is a probe result, not a fault. The destination is unchanged.
          setFlag(.zero, false, in: &state.rflags)
        }
      case .verifySegment(let readable, let source):
        guard mode != .real16, !state.rflags.contains(.virtual8086) else {
          return invalidOpcode(at: originalRIP)
        }
        let selector = UInt16(
          truncatingIfNeeded: try read(
            source, instruction: instruction, state: state, memory: executionMemory))
        let descriptor = try descriptorForInspection(
          selector: selector,
          accessRights: true,
          mode: mode,
          state: state,
          memory: executionMemory
        )
        let allowed: Bool
        if let descriptor {
          let access = UInt8(truncatingIfNeeded: descriptor.raw >> 40)
          let type = access & 0x0f
          let codeOrData = access & 0x10 != 0
          let executable = type & 8 != 0
          allowed =
            codeOrData
            && (readable ? (!executable || type & 2 != 0) : (!executable && type & 2 != 0))
        } else {
          allowed = false
        }
        setFlag(.zero, allowed, in: &state.rflags)
      case .readSegment(let segment, let destination):
        try write(
          UInt64(segmentState(segment, state: state).selector),
          to: destination,
          instruction: instruction,
          state: &state,
          memory: executionMemory
        )
      case .writeSegment(let segment, let source):
        let selector = UInt16(
          truncatingIfNeeded: try read(
            source, instruction: instruction, state: state, memory: executionMemory))
        guard
          let loaded = try loadSegment(
            segment,
            selector: selector,
            mode: mode,
            state: state,
            memory: executionMemory
          )
        else { return generalProtection(at: originalRIP) }
        setSegment(segment, value: loaded, state: &state)
      case .farJump(let offset, let selector):
        guard
          let loaded = try loadSegment(
            .cs,
            selector: selector,
            mode: mode,
            state: state,
            memory: executionMemory
          )
        else { return generalProtection(at: originalRIP) }
        state.cs = loaded
        nextRIP = offset
      case .farJumpIndirect(let address, let width):
        let pointerAddress = effectiveAddress(address, instruction: instruction, state: state)
        let pointer = try executionMemory.read(
          at: pointerAddress,
          byteCount: width.byteCount + MemoryLayout<UInt16>.size
        )
        let offset = fromLittleEndian(Array(pointer.prefix(width.byteCount))) & mask(width)
        let selector = UInt16(
          truncatingIfNeeded: fromLittleEndian(Array(pointer.suffix(MemoryLayout<UInt16>.size)))
        )
        guard
          let loaded = try loadSegment(
            .cs,
            selector: selector,
            mode: mode,
            state: state,
            memory: executionMemory
          )
        else { return generalProtection(at: originalRIP) }
        state.cs = loaded
        nextRIP = offset
      case .farCall(let offset, let selector, let width):
        guard
          let loaded = try loadSegment(
            .cs,
            selector: selector,
            mode: mode,
            state: state,
            memory: executionMemory
          )
        else { return generalProtection(at: originalRIP) }
        let oldStack = state.registers.rsp & mask(width)
        let selectorStack = oldStack &- UInt64(width.byteCount) & mask(width)
        let returnStack = selectorStack &- UInt64(width.byteCount) & mask(width)
        let selectorAddress = stackAddress(selectorStack, mode: mode, state: state)
        let returnAddress = stackAddress(returnStack, mode: mode, state: state)
        try executionMemory.validateWrite(at: selectorAddress, byteCount: width.byteCount)
        try executionMemory.validateWrite(at: returnAddress, byteCount: width.byteCount)
        try executionMemory.write(
          at: selectorAddress,
          bytes: littleEndian(UInt64(state.cs.selector), width: width)
        )
        try executionMemory.write(
          at: returnAddress,
          bytes: littleEndian(nextRIP, width: width)
        )
        writeStringRegister(.rsp, value: returnStack, width: width, state: &state)
        state.cs = loaded
        nextRIP = offset & mask(width)
      case .farCallIndirect(let address, let width):
        let pointerAddress = effectiveAddress(address, instruction: instruction, state: state)
        let pointer = try executionMemory.read(
          at: pointerAddress,
          byteCount: width.byteCount + MemoryLayout<UInt16>.size
        )
        let offset = fromLittleEndian(Array(pointer.prefix(width.byteCount))) & mask(width)
        let selector = UInt16(
          truncatingIfNeeded: fromLittleEndian(Array(pointer.suffix(MemoryLayout<UInt16>.size)))
        )
        guard
          let loaded = try loadSegment(
            .cs,
            selector: selector,
            mode: mode,
            state: state,
            memory: executionMemory
          )
        else { return generalProtection(at: originalRIP) }
        let oldStack = state.registers.rsp & mask(width)
        let selectorStack = oldStack &- UInt64(width.byteCount) & mask(width)
        let returnStack = selectorStack &- UInt64(width.byteCount) & mask(width)
        let selectorAddress = stackAddress(selectorStack, mode: mode, state: state)
        let returnAddress = stackAddress(returnStack, mode: mode, state: state)
        try executionMemory.validateWrite(at: selectorAddress, byteCount: width.byteCount)
        try executionMemory.validateWrite(at: returnAddress, byteCount: width.byteCount)
        try executionMemory.write(
          at: selectorAddress,
          bytes: littleEndian(UInt64(state.cs.selector), width: width)
        )
        try executionMemory.write(
          at: returnAddress,
          bytes: littleEndian(nextRIP, width: width)
        )
        writeStringRegister(.rsp, value: returnStack, width: width, state: &state)
        state.cs = loaded
        nextRIP = offset
      case .farReturn(let popBytes, let width):
        let stack = state.registers.rsp & mask(width)
        let returnAddress = stackAddress(stack, mode: mode, state: state)
        let selectorStack = stack &+ UInt64(width.byteCount) & mask(width)
        let selectorAddress = stackAddress(selectorStack, mode: mode, state: state)
        let target = fromLittleEndian(
          try executionMemory.read(at: returnAddress, byteCount: width.byteCount))
        let selector = UInt16(
          truncatingIfNeeded: fromLittleEndian(
            try executionMemory.read(at: selectorAddress, byteCount: width.byteCount)))
        guard
          let loaded = try loadSegment(
            .cs,
            selector: selector,
            mode: mode,
            state: state,
            memory: executionMemory
          )
        else { return generalProtection(at: originalRIP) }
        let finalStack =
          selectorStack &+ UInt64(width.byteCount) &+ UInt64(popBytes) & mask(width)
        writeStringRegister(.rsp, value: finalStack, width: width, state: &state)
        state.cs = loaded
        nextRIP = target & mask(width)
      case .machineStatusWord(let load, let operand):
        if load {
          guard currentPrivilegeLevel(state, mode: mode) == 0 else {
            return generalProtection(at: originalRIP)
          }
          let requested = try read(
            operand, instruction: instruction, state: state, memory: executionMemory)
          let preservedPE = state.control.cr0 & 1
          state.control.cr0 =
            (state.control.cr0 & ~UInt64(0xF)) | (requested & 0xE) | preservedPE
            | (requested & 1)
          (pagingUnit ?? translatedMemory?.translationUnit)?.invalidateAll()
        } else {
          guard state.control.cr4 & (1 << 11) == 0 || currentPrivilegeLevel(state, mode: mode) == 0 else {
            return generalProtection(at: originalRIP)
          }
          // Intel SDM 092 Vol. 2B p. 4-658: in 64-bit mode SMSW r32/r64
          // stores the corresponding CR0 width; every memory form remains m16.
          let value: UInt64
          if mode == .long64, case .register = operand { value = state.control.cr0 }
          else { value = state.control.cr0 & 0xffff }
          try write(
            value,
            to: operand,
            instruction: instruction,
            state: &state,
            memory: executionMemory
          )
        }
      case .vmCall:
        // Dory exposes neither VMX/SVM nor a Xen hypercall ABI. PVH boot receives
        // its versioned memory map in start_info; an unsupported call must fault.
        return invalidOpcode(at: originalRIP)
      case .clearTaskSwitched:
        guard currentPrivilegeLevel(state, mode: mode) == 0 else {
          return generalProtection(at: originalRIP)
        }
        state.control.cr0 &= ~(1 << 3)
      case .storeSystemSegment(let task, let destination):
        let virtual8086 = mode != .long64 && state.control.efer & (1 << 10) == 0
          && state.rflags.contains(.virtual8086)
        guard mode != .real16, !virtual8086 else { return invalidOpcode(at: originalRIP) }
        guard state.control.cr4 & (1 << 11) == 0 || currentPrivilegeLevel(state, mode: mode) == 0 else {
          return generalProtection(at: originalRIP)
        }
        try write(
          UInt64(task ? state.tr.selector : state.ldtr.selector),
          to: destination,
          instruction: instruction,
          state: &state,
          memory: executionMemory
        )
      case .loadSystemSegment(let task, let source):
        let virtual8086 = mode != .long64 && state.control.efer & (1 << 10) == 0
          && state.rflags.contains(.virtual8086)
        guard mode != .real16, !virtual8086 else { return invalidOpcode(at: originalRIP) }
        guard currentPrivilegeLevel(state, mode: mode) == 0 else {
          return generalProtection(at: originalRIP)
        }
        let selector = UInt16(
          truncatingIfNeeded: try read(
            source, instruction: instruction, state: state, memory: executionMemory))
        let descriptorMemory: any DoryX86Memory =
          if let translated = executionMemory as? DoryX86TranslatedMemory {
            translated.implicitSupervisorMemory()
          } else { executionMemory }
        let load = { (current: inout DoryX86ArchitecturalState) in
          try loadSystemSegment(
            task: task,
            selector: selector,
            mode: mode,
            state: current,
            memory: descriptorMemory
          )
        }
        // Serialize the descriptor check and busy-byte store against other locked
        // interpreter operations. Ordinary selector-operand reads stay explicit.
        let loaded = task
          ? try DoryX86AtomicGate.shared.withLock(state: &state, load)
          : try load(&state)
        if task { state.tr = loaded } else { state.ldtr = loaded }
      case .readModelSpecificRegister:
        guard profile.supports(.msr) else { return invalidOpcode(at: originalRIP) }
        guard currentPrivilegeLevel(state, mode: mode) == 0,
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
        guard profile.supports(.msr) else { return invalidOpcode(at: originalRIP) }
        let value =
          UInt64(UInt32(truncatingIfNeeded: state.registers.rax))
          | UInt64(UInt32(truncatingIfNeeded: state.registers.rdx)) << 32
        guard currentPrivilegeLevel(state, mode: mode) == 0,
          writeModelSpecificRegister(
            UInt32(truncatingIfNeeded: state.registers.rcx),
            value: value,
            state: &state,
            pagingUnit: pagingUnit ?? translatedMemory?.translationUnit
          )
        else {
          return generalProtection(at: originalRIP)
        }
      case .readTimestampCounter(let includeAuxiliary):
        guard profile.supports(.tsc), !includeAuxiliary || profile.supports(.rdtscp) else {
          return invalidOpcode(at: originalRIP)
        }
        guard currentPrivilegeLevel(state, mode: mode) == 0 || state.control.cr4 & (1 << 2) == 0 else {
          return generalProtection(at: originalRIP)
        }
        state.registers.rax = UInt64(UInt32(truncatingIfNeeded: state.tsc))
        state.registers.rdx = UInt64(UInt32(truncatingIfNeeded: state.tsc >> 32))
        if includeAuxiliary { state.registers.rcx = UInt64(state.tscAux) }
      case .swapGS:
        guard mode == .long64 else { return invalidOpcode(at: originalRIP) }
        guard currentPrivilegeLevel(state, mode: mode) == 0 else {
          return generalProtection(at: originalRIP)
        }
        state.modelSpecific.gsBase = state.gs.base
        swap(&state.modelSpecific.gsBase, &state.modelSpecific.kernelGSBase)
        state.gs.base = state.modelSpecific.gsBase
      case .softwareInterrupt(let vector):
        do {
          try DoryX86InterruptDelivery(profile: profile).deliver(
            vector: vector,
            source: .software,
            returnInstructionPointer: nextRIP,
            state: &state,
            physicalMemory: memory,
            pagingUnit: pagingUnit ?? translatedMemory?.translationUnit,
            mode: mode
          )
          return .retired(instruction)
        } catch let exception as DoryX86Exception {
          throw exception
        } catch let error as DoryX86MemoryError {
          throw error
        } catch {
          state.rip = originalRIP
          return generalProtection(at: originalRIP)
        }
      case .interruptReturn:
        do {
          try DoryX86InterruptDelivery(profile: profile).interruptReturn(
            state: &state,
            physicalMemory: memory,
            pagingUnit: pagingUnit ?? translatedMemory?.translationUnit,
            mode: mode,
            operandSizeOverride: instruction.prefixes.operandSizeOverride
          )
          return .retired(instruction)
        } catch let exception as DoryX86Exception {
          throw exception
        } catch let error as DoryX86MemoryError {
          throw error
        } catch {
          state.rip = originalRIP
          return generalProtection(at: originalRIP)
        }
      case .pushFlags(let width):
        try pushStack(
          state.rflags.rawValue,
          width: width,
          instruction: instruction,
          mode: mode,
          state: &state,
          memory: executionMemory
        )
      case .popFlags(let width):
        let stackRead = try readStack(
          width: width,
          instruction: instruction,
          mode: mode,
          state: state,
          memory: executionMemory
        )
        let raw = stackRead.value
        var requested = DoryX86RFLAGS(
          rawValue: (raw & DoryX86RFLAGS.architecturallyWritableMask) | 2)
        if currentPrivilegeLevel(state, mode: mode) > UInt8((state.rflags.rawValue >> 12) & 3) {
          setFlag(.interruptEnable, state.rflags.contains(.interruptEnable), in: &requested)
        }
        guard let validated = try? requested.validated() else {
          return generalProtection(at: originalRIP)
        }
        state.rflags = validated
        writeStackPointer(stackRead.nextOffset, mode: mode, state: &state)
      case .leave(let width):
        writeStackPointer(state.registers.rbp, mode: mode, state: &state)
        let frame = try popStack(
          width: width,
          instruction: instruction,
          mode: mode,
          state: &state,
          memory: executionMemory
        )
        writeStringRegister(.rbp, value: frame, width: width, state: &state)
      case .setCarry(let enabled):
        setFlag(.carry, enabled, in: &state.rflags)
      case .complementCarry:
        setFlag(.carry, !state.rflags.contains(.carry), in: &state.rflags)
      case .setDirection(let enabled):
        setFlag(.direction, enabled, in: &state.rflags)
      case .flagByte(let load):
        guard mode != .long64 || profile.supports(.lahf64) else {
          return .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: originalRIP))
        }
        if load {
          let value = (state.rflags.rawValue & 0xD5) | 2
          state.registers.rax =
            (state.registers.rax & ~UInt64(0xff00)) | ((value & 0xff) << 8)
        } else {
          let value = (state.registers.rax >> 8) & 0xff
          state.rflags = DoryX86RFLAGS(
            rawValue: (state.rflags.rawValue & ~UInt64(0xD5)) | (value & 0xD5) | 2
          )
        }
      case .systemEnter:
        guard profile.supports(.sysenter) else {
          return .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: originalRIP))
        }
        let selector = UInt16(truncatingIfNeeded: state.modelSpecific.systemEnterCS) & 0xfffc
        guard mode != .real16, state.control.cr0 & 1 != 0, selector != 0 else {
          return generalProtection(at: originalRIP)
        }
        let inIA32eMode = state.control.efer & (1 << 10) != 0
        let targetRIP = state.modelSpecific.systemEnterInstructionPointer
        let targetRSP = state.modelSpecific.systemEnterStackPointer
        guard !inIA32eMode
          || (DoryX86ArchitecturalState.isCanonical(targetRIP)
            && DoryX86ArchitecturalState.isCanonical(targetRSP))
        else { return generalProtection(at: originalRIP) }
        state.rflags.remove([.virtual8086, .interruptEnable])
        state.registers.rsp = inIA32eMode ? targetRSP : UInt64(UInt32(truncatingIfNeeded: targetRSP))
        state.cs = .init(
          selector: selector,
          attributes: inIA32eMode ? 0xA09B : 0xC09B,
          limit: .max,
          base: 0
        )
        state.ss = .init(
          selector: selector &+ 8,
          attributes: 0xC093,
          limit: .max,
          base: 0
        )
        nextRIP = inIA32eMode ? targetRIP : UInt64(UInt32(truncatingIfNeeded: targetRIP))
      case .systemExit(let return64Bit):
        guard profile.supports(.sysenter) else {
          return .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: originalRIP))
        }
        let systemSelector = UInt16(truncatingIfNeeded: state.modelSpecific.systemEnterCS) & 0xfffc
        guard mode != .real16, state.control.cr0 & 1 != 0, systemSelector != 0,
          currentPrivilegeLevel(state, mode: mode) == 0
        else { return generalProtection(at: originalRIP) }
        let targetRIP = return64Bit
          ? state.registers.rdx
          : UInt64(UInt32(truncatingIfNeeded: state.registers.rdx))
        let targetRSP = return64Bit
          ? state.registers.rcx
          : UInt64(UInt32(truncatingIfNeeded: state.registers.rcx))
        guard !return64Bit
          || (state.control.efer & (1 << 10) != 0
            && DoryX86ArchitecturalState.isCanonical(targetRIP)
            && DoryX86ArchitecturalState.isCanonical(targetRSP))
        else { return generalProtection(at: originalRIP) }
        let selectorOffset: UInt16 = return64Bit ? 32 : 16
        let codeSelector = systemSelector &+ selectorOffset | 3
        state.registers.rsp = targetRSP
        state.cs = .init(
          selector: codeSelector,
          attributes: return64Bit ? 0xA0FB : 0xC0FB,
          limit: .max,
          base: 0
        )
        state.ss = .init(
          selector: codeSelector &+ 8,
          attributes: 0xC0F3,
          limit: .max,
          base: 0
        )
        nextRIP = targetRIP
      case .setInterruptsEnabled(let enabled):
        let currentPrivilege = UInt64(currentPrivilegeLevel(state, mode: mode))
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
          currentPrivilegeLevel(state, mode: mode) == 0,
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
      DoryX86LegacyFloatingPointPolicy.applyRetiredMMXEffects(instruction, state: &state.floatingPoint)
      let finalMask: UInt64 =
        if mode == .protected16 || mode == .protected32, state.cs != originalCodeSegment {
          if state.cs.attributes & 0x2000 != 0 {
            .max
          } else {
            state.cs.attributes & 0x4000 == 0 ? 0xffff : 0xffff_ffff
          }
        } else {
          instructionPointerMask(mode)
        }
      state.rip = nextRIP & finalMask
      return .retired(instruction)
    } catch let partial as DoryX86PartialMemoryFault {
      state.rip = originalRIP
      let base = pageFault(for: partial.error, instructionPointer: originalRIP)
      let fault = DoryX86Exception(
        kind: base.kind,
        vector: base.vector,
        errorCode: base.errorCode,
        instructionPointer: base.instructionPointer,
        linearAddress: base.linearAddress,
        commitsPartialProgress: true
      )
      return .exception(fault)
    } catch let partial as DoryX86PartialException {
      state.rip = originalRIP
      return .exception(
        .init(
          kind: partial.exception.kind,
          vector: partial.exception.vector,
          errorCode: partial.exception.errorCode,
          instructionPointer: originalRIP,
          linearAddress: partial.exception.linearAddress,
          commitsPartialProgress: true
        ))
    } catch is DoryX86PartialGeneralProtection {
      state.rip = originalRIP
      return .exception(
        .init(
          kind: .generalProtection,
          vector: 13,
          errorCode: 0,
          instructionPointer: originalRIP,
          commitsPartialProgress: true
        ))
    } catch let error as DoryX86MemoryError {
      state.rip = originalRIP
      let fault = pageFault(for: error, instructionPointer: originalRIP)
      state.control.cr2 = fault.linearAddress ?? 0
      return .exception(fault)
    } catch let exception as DoryX86Exception {
      state.rip = originalRIP
      return .exception(exception)
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

  private func simdExecutionStateFault(
    _ instruction: DoryX86DecodedInstruction,
    state: DoryX86ArchitecturalState,
    mode: DoryX86ExecutionMode
  ) -> DoryX86InterpreterResult? {
    if instruction.prefixes.vex != nil {
      // Only admitted AVX encodings reach this point. Intel SDM Vol. 2A §2.5
      // Types 1–7 use OSXSAVE/XCR0, not legacy SSE's EM/OSFXSR conditions.
      let virtual8086 = mode != .long64 && state.control.efer & (1 << 10) == 0
        && state.rflags.contains(.virtual8086)
      guard mode != .real16, !virtual8086,
        state.control.cr4 & (1 << 18) != 0, state.control.xcr0 & 6 == 6
      else { return invalidOpcode(at: instruction.address) }
    } else {
      let usesSSEState: Bool
      switch instruction.operation {
      case .loadMXCSR, .storeMXCSR, .moveVector128, .moveVectorScalar, .moveVectorQwordHalf,
        .duplicateVectorScalar, .shufflePackedBytes, .alignPackedBytes, .testPackedBits,
        .extendPackedDwordToQword, .extendPackedByteToQword, .comparePackedQwords,
        .insertPackedQword, .unpackVector, .convertPackedDoubleToDword, .convertPackedDwordToDouble,
        .packedCompareStringIndex, .moveIntegerToVector, .moveVectorToInteger, .vectorBitwise,
        .vectorFloatingBinary, .scalarCompare, .scalarConvert, .scalarSquareRoot,
        .vectorIntegerBinary, .vectorIntegerShift, .vectorByteShift, .vectorFloatingCompare,
        .vectorIntegerInterleave, .vectorIntegerPack, .vectorShuffle,
        .convertIntegerToScalarFloat, .convertScalarFloatToInteger:
        usesSSEState = true
      case .insertPackedWord(_, _, _, let mmx), .extractPackedWord(_, _, _, let mmx):
        usesSSEState = !mmx
      case .moveVectorMask(_, _, _, let vectorByteCount):
        usesSSEState = vectorByteCount == 16
      default:
        // x87, MMX, and FXSAVE/FXRSTOR have different enable-state rules.
        // PAUSE/PREFETCH/fences/MOVNTI/CLFLUSH do not use SSE state.
        return nil
      }
      guard usesSSEState else { return nil }
      // Vol. 3A Tables 16-1/16-2 explicitly give these #UD conditions priority
      // over TS (#NM), with TS marked don't-care in the #UD rows.
      guard state.control.cr0 & (1 << 2) == 0, state.control.cr4 & (1 << 9) != 0 else {
        return invalidOpcode(at: instruction.address)
      }
    }
    guard state.control.cr0 & (1 << 3) != 0 else { return nil }
    return .exception(.init(kind: .deviceNotAvailable, vector: 7,
      instructionPointer: instruction.address))
  }

  private func validateFloatingPointTransfer(
    _ operand: DoryX86MemoryOperand, byteCount: Int, write: Bool,
    instruction: DoryX86DecodedInstruction, state: DoryX86ArchitecturalState
  ) throws {
    try validateSegmentAccess(operand, byteCount: byteCount, write: write,
      instruction: instruction, state: state)
    if operand.ignoresLegacySegmentBase {
      let address = effectiveAddress(operand, instruction: instruction, state: state)
      let last = address.addingReportingOverflow(UInt64(byteCount - 1))
      guard !last.overflow, DoryX86ArchitecturalState.isCanonical(address),
        DoryX86ArchitecturalState.isCanonical(last.partialValue)
      else {
        throw operand.segment == .ss ? stackProtection(at: instruction.address)
          : segmentProtection(at: instruction.address)
      }
    }
  }

  private func floatingPointTransferByteCount(mode: DoryX86ExecutionMode) -> Int {
    // Intel SDM Vol. 1 §10.5.1: bytes 416...511 are unused, including the
    // software-owned tail at 464...511. Outside 64-bit mode, the XMM8...15
    // slots at 288...415 are also neither saved nor restored (§10.5.1.2).
    // The architectural operand remains m512 for segment-range validation.
    mode == .long64 ? 416 : 288
  }

  private func floatingPointSaveArea(
    _ floatingPoint: DoryX86FloatingPointState,
    mode: DoryX86ExecutionMode
  ) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: floatingPointTransferByteCount(mode: mode))
    replaceLittleEndian(floatingPoint.x87ControlWord, in: &bytes, at: 0)
    replaceLittleEndian(floatingPoint.x87StatusWord, in: &bytes, at: 2)
    var abridgedTag: UInt8 = 0
    for index in 0..<8
    where floatingPoint.x87TagWord & (UInt16(3) << UInt16(index * 2)) != UInt16(3)
      << UInt16(index * 2)
    {
      abridgedTag |= UInt8(1) << UInt8(index)
    }
    bytes[4] = abridgedTag
    replaceLittleEndian(floatingPoint.mxcsr, in: &bytes, at: 24)
    replaceLittleEndian(floatingPoint.mxcsrMask, in: &bytes, at: 28)
    for index in 0..<8 {
      bytes.replaceSubrange(32 + index * 16..<42 + index * 16, with: floatingPoint.x87[index].bytes)
    }
    let vectorCount = mode == .long64 ? 16 : 8
    for index in 0..<vectorCount {
      bytes.replaceSubrange(
        160 + index * 16..<176 + index * 16,
        with: floatingPoint.ymm[index].bytes.prefix(16)
      )
    }
    return bytes
  }

  private func restoredFloatingPointState(
    from bytes: [UInt8],
    mode: DoryX86ExecutionMode,
    preserving floatingPoint: DoryX86FloatingPointState
  ) throws -> DoryX86FloatingPointState? {
    precondition(bytes.count == floatingPointTransferByteCount(mode: mode))
    let mxcsr = UInt32(fromLittleEndian(Array(bytes[24..<28])))
    guard mxcsr & ~floatingPoint.mxcsrMask == 0 else { return nil }
    let abridgedTag = bytes[4]
    var tagWord: UInt16 = 0
    var x87: [DoryX86RegisterBytes] = []
    for index in 0..<8 {
      tagWord |=
        UInt16(abridgedTag & (UInt8(1) << UInt8(index)) == 0 ? 3 : 0)
        << UInt16(index * 2)
      x87.append(
        try .init(bytes: Array(bytes[32 + index * 16..<42 + index * 16]), expectedByteCount: 10)
      )
    }
    // FXRSTOR loads SSE state, not the AVX upper halves. In non-64-bit modes
    // it also leaves XMM8...15 unchanged (Intel SDM Vol. 1 §10.5.1.2).
    var ymm = floatingPoint.ymm
    let vectorCount = mode == .long64 ? 16 : 8
    for index in 0..<vectorCount {
      var register = ymm[index].bytes
      register.replaceSubrange(0..<16, with: bytes[160 + index * 16..<176 + index * 16])
      ymm[index] = try .init(bytes: register, expectedByteCount: 32)
    }
    return try .init(
      x87: x87,
      ymm: ymm,
      x87ControlWord: UInt16(fromLittleEndian(Array(bytes[0..<2]))),
      x87StatusWord: UInt16(fromLittleEndian(Array(bytes[2..<4]))),
      x87TagWord: tagWord,
      mxcsr: mxcsr,
      mxcsrMask: floatingPoint.mxcsrMask
    )
  }

  private func replaceLittleEndian<T: FixedWidthInteger>(
    _ value: T,
    in bytes: inout [UInt8],
    at offset: Int
  ) {
    for index in 0..<MemoryLayout<T>.size {
      bytes[offset + index] = UInt8(truncatingIfNeeded: value >> T(index * 8))
    }
  }

  private func readVectorBytes(
    _ operand: DoryX86VectorOperand,
    byteCount: Int,
    instruction: DoryX86DecodedInstruction,
    state: DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws -> [UInt8] {
    switch operand {
    case .register(let register):
      return Array(state.floatingPoint.ymm[Int(register)].bytes.prefix(byteCount))
    case .memory(let memoryOperand):
      try validateSegmentAccess(
        memoryOperand,
        byteCount: byteCount,
        write: false,
        instruction: instruction,
        state: state
      )
      return try memory.read(
        at: effectiveAddress(memoryOperand, instruction: instruction, state: state),
        byteCount: byteCount
      )
    }
  }

  private func readMMXBytes(
    _ operand: DoryX86VectorOperand,
    byteCount: Int,
    instruction: DoryX86DecodedInstruction,
    state: DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws -> [UInt8] {
    switch operand {
    case .register(let register):
      return Array(state.floatingPoint.x87[Int(register)].bytes.prefix(byteCount))
    case .memory(let memoryOperand):
      try validateSegmentAccess(
        memoryOperand,
        byteCount: byteCount,
        write: false,
        instruction: instruction,
        state: state
      )
      return try memory.read(
        at: effectiveAddress(memoryOperand, instruction: instruction, state: state),
        byteCount: byteCount
      )
    }
  }

  private func writeMMXBytes(
    _ bytes: [UInt8],
    to operand: DoryX86VectorOperand,
    instruction: DoryX86DecodedInstruction,
    state: inout DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws {
    switch operand {
    case .register(let register):
      writeMMXRegister(register, bytes: bytes, state: &state.floatingPoint)
    case .memory(let memoryOperand):
      try writeX87Memory(
        bytes,
        to: memoryOperand,
        instruction: instruction,
        state: state,
        memory: memory
      )
    }
  }

  private func writeMMXRegister(
    _ register: UInt8,
    bytes: [UInt8],
    state: inout DoryX86FloatingPointState
  ) {
    precondition(register < 8 && bytes.count <= 8)
    var payload = [UInt8](repeating: 0, count: 10)
    payload.replaceSubrange(0..<bytes.count, with: bytes)
    payload[8] = 0xFF
    payload[9] = 0xFF
    state.x87[Int(register)] = try! .init(bytes: payload, expectedByteCount: 10)
  }

  private func readX87(
    _ operand: DoryX87Operand,
    instruction: DoryX86DecodedInstruction,
    state: DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws -> DoryX86ExtendedFloat {
    switch operand {
    case .register(let register):
      return readX87Register(register, state: state.floatingPoint)
    case .memory(let memoryOperand, let format):
      try validateSegmentAccess(
        memoryOperand,
        byteCount: format.byteCount,
        write: false,
        instruction: instruction,
        state: state
      )
      let bytes = try memory.read(
        at: effectiveAddress(memoryOperand, instruction: instruction, state: state),
        byteCount: format.byteCount
      )
      switch format {
      case .float32:
        return DoryX86ExtendedFloat(
          Double(Float(bitPattern: UInt32(fromLittleEndian(bytes)))))
      case .float64:
        return DoryX86ExtendedFloat(Double(bitPattern: fromLittleEndian(bytes)))
      case .extended80:
        return DoryX86ExtendedFloat(bytes: bytes)
      case .signedInteger16:
        return DoryX86ExtendedFloat(
          Int64(Int16(bitPattern: UInt16(fromLittleEndian(bytes)))))
      case .signedInteger32:
        return DoryX86ExtendedFloat(
          Int64(Int32(bitPattern: UInt32(fromLittleEndian(bytes)))))
      case .signedInteger64:
        return DoryX86ExtendedFloat(Int64(bitPattern: fromLittleEndian(bytes)))
      }
    }
  }

  private func writeX87Memory(
    _ bytes: [UInt8],
    to memoryOperand: DoryX86MemoryOperand,
    instruction: DoryX86DecodedInstruction,
    state: DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws {
    try validateSegmentAccess(
      memoryOperand,
      byteCount: bytes.count,
      write: true,
      instruction: instruction,
      state: state
    )
    let address = effectiveAddress(memoryOperand, instruction: instruction, state: state)
    try memory.validateWrite(at: address, byteCount: bytes.count)
    try memory.write(at: address, bytes: bytes)
  }

  private func storeX87Bytes(
    _ value: DoryX86ExtendedFloat,
    format: DoryX87MemoryFormat,
    truncate: Bool,
    floatingPoint: inout DoryX86FloatingPointState
  ) -> [UInt8] {
    switch format {
    case .float32:
      return Array(
        littleEndian(
          UInt64(value.float32Bits(rounding: x87Rounding(floatingPoint))),
          width: .doubleword
        ))
    case .float64:
      return littleEndian(
        value.float64Bits(rounding: x87Rounding(floatingPoint)), width: .quadword)
    case .extended80:
      return value.bytes(rounding: x87Rounding(floatingPoint))
    case .signedInteger16, .signedInteger32, .signedInteger64:
      let bitCount: Int =
        switch format {
        case .signedInteger16: 16
        case .signedInteger32: 32
        default: 64
        }
      let raw = value.signedIntegerBits(
        bitCount: bitCount,
        rounding: truncate ? .towardZero : x87Rounding(floatingPoint)
      )
      if raw == nil { floatingPoint.x87StatusWord |= 1 }
      let stored = raw ?? UInt64(1) << UInt64(bitCount - 1)
      return (0..<(bitCount / 8)).map {
        UInt8(truncatingIfNeeded: stored >> UInt64($0 * 8))
      }
    }
  }

  private func x87Top(_ state: DoryX86FloatingPointState) -> Int {
    Int((state.x87StatusWord >> 11) & 7)
  }

  private func setX87Top(_ top: Int, state: inout DoryX86FloatingPointState) {
    state.x87StatusWord = (state.x87StatusWord & ~(UInt16(7) << 11)) | UInt16(top & 7) << 11
  }

  private func physicalX87Register(_ logical: UInt8, state: DoryX86FloatingPointState) -> Int {
    (x87Top(state) + Int(logical)) & 7
  }

  private func x87Tag(_ physical: Int, state: DoryX86FloatingPointState) -> UInt16 {
    (state.x87TagWord >> UInt16(physical * 2)) & 3
  }

  private func setX87Tag(
    _ physical: Int,
    _ tag: UInt16,
    state: inout DoryX86FloatingPointState
  ) {
    let shift = UInt16(physical * 2)
    state.x87TagWord = (state.x87TagWord & ~(UInt16(3) << shift)) | (tag & 3) << shift
  }

  private func readX87Register(
    _ logical: UInt8,
    state: DoryX86FloatingPointState
  ) -> DoryX86ExtendedFloat {
    let physical = physicalX87Register(logical, state: state)
    guard x87Tag(physical, state: state) != 3 else {
      return DoryX86ExtendedFloat(Double.nan)
    }
    return DoryX86ExtendedFloat(bytes: state.x87[physical].bytes)
  }

  private func writeX87Register(
    _ logical: UInt8,
    value: DoryX86ExtendedFloat,
    state: inout DoryX86FloatingPointState
  ) {
    let physical = physicalX87Register(logical, state: state)
    state.x87[physical] = try! .init(bytes: value.bytes(), expectedByteCount: 10)
    let tag: UInt16 = value.isZero ? 1 : (value.isFinite ? 0 : 2)
    setX87Tag(physical, tag, state: &state)
  }

  private func writeX87Register(
    _ logical: UInt8,
    value: Double,
    state: inout DoryX86FloatingPointState
  ) {
    writeX87Register(logical, value: DoryX86ExtendedFloat(value), state: &state)
  }

  private func updateX87ArithmeticStatus(
    operation: DoryX87BinaryOperation,
    lhs: DoryX86ExtendedFloat,
    rhs: DoryX86ExtendedFloat,
    result: DoryX86ExtendedFloat,
    state: inout DoryX86FloatingPointState
  ) {
    if lhs.isNaN || rhs.isNaN { state.x87StatusWord |= 1 }
    let numerator: DoryX86ExtendedFloat
    let denominator: DoryX86ExtendedFloat
    switch operation {
    case .divide:
      (numerator, denominator) = (lhs, rhs)
    case .divideReverse:
      (numerator, denominator) = (rhs, lhs)
    default:
      return
    }
    if denominator.isZero {
      if numerator.isZero || numerator.isNaN {
        state.x87StatusWord |= 1
      } else if numerator.isFinite {
        state.x87StatusWord |= 1 << 2
      }
    } else if result.isInfinite, numerator.isFinite, denominator.isFinite {
      state.x87StatusWord |= 1 << 3
    }
  }

  private func executeX87Special(
    _ operation: DoryX87SpecialOperation,
    state: inout DoryX86FloatingPointState
  ) {
    let extendedX = readX87Register(0, state: state)
    let x = extendedX.doubleValue
    switch operation {
    case .changeSign:
      writeX87Register(0, value: extendedX.negated(), state: &state)
    case .absolute:
      writeX87Register(0, value: extendedX.absolute(), state: &state)
    case .test:
      setX87ComparisonStatus(
        x87FloatingComparison(extendedX, .zero), state: &state)
    case .examine:
      state.x87StatusWord &= ~UInt16(0x4700)
      if extendedX.isNegative { state.x87StatusWord |= 0x0200 }
      if extendedX.isNaN {
        state.x87StatusWord |= 0x0100
      } else if extendedX.isInfinite {
        state.x87StatusWord |= 0x0500
      } else if extendedX.isZero {
        state.x87StatusWord |= 0x4000
      } else if extendedX.isSubnormal {
        state.x87StatusWord |= 0x4400
      } else {
        state.x87StatusWord |= 0x0400
      }
    case .loadOne:
      pushX87(1, state: &state)
    case .loadLog2Ten:
      pushX87(Foundation.log2(10), state: &state)
    case .loadLog2E:
      pushX87(Foundation.log2(M_E), state: &state)
    case .loadPi:
      pushX87(.pi, state: &state)
    case .loadLog10Two:
      pushX87(Foundation.log10(2), state: &state)
    case .loadLnTwo:
      pushX87(Foundation.log(2), state: &state)
    case .loadZero:
      pushX87(0, state: &state)
    case .twoToXMinusOne:
      writeX87Register(0, value: Foundation.pow(2, x) - 1, state: &state)
    case .yLog2X:
      let y = readX87Register(1, state: state).doubleValue
      writeX87Register(1, value: y * Foundation.log2(x), state: &state)
      popX87(state: &state)
    case .tangent:
      guard x87TrigonometricArgumentIsInRange(x, state: &state) else { return }
      writeX87Register(0, value: Foundation.tan(x), state: &state)
      pushX87(1, state: &state)
    case .arctangent:
      let y = readX87Register(1, state: state).doubleValue
      writeX87Register(1, value: Foundation.atan2(y, x), state: &state)
      popX87(state: &state)
    case .extract:
      let exponent = x == 0 ? -.infinity : Foundation.floor(Foundation.log2(abs(x)))
      let significand = x == 0 ? x : x / Foundation.pow(2, exponent)
      writeX87Register(0, value: significand, state: &state)
      pushX87(exponent, state: &state)
    case .partialRemainderNearest:
      executeX87Remainder(nearest: true, state: &state)
    case .decrementTop:
      setX87Top((x87Top(state) + 7) & 7, state: &state)
    case .incrementTop:
      setX87Top((x87Top(state) + 1) & 7, state: &state)
    case .partialRemainder:
      executeX87Remainder(nearest: false, state: &state)
    case .yLog2XPlusOne:
      let y = readX87Register(1, state: state).doubleValue
      writeX87Register(1, value: y * Foundation.log2(x + 1), state: &state)
      popX87(state: &state)
    case .squareRoot:
      if x < 0 { state.x87StatusWord |= 1 }
      writeX87Register(0, value: Foundation.sqrt(x), state: &state)
    case .sineCosine:
      guard x87TrigonometricArgumentIsInRange(x, state: &state) else { return }
      writeX87Register(0, value: Foundation.sin(x), state: &state)
      pushX87(Foundation.cos(x), state: &state)
    case .roundToInteger:
      writeX87Register(
        0,
        value: extendedX.roundedToInteger(x87Rounding(state)),
        state: &state
      )
    case .scale:
      let scale = readX87Register(1, state: state)
      if scale.isFinite {
        // Truncate the binary80 operand before narrowing: Double can round a
        // value just below an integer upward, and Double(Int.max) is 2^63.
        // A power beyond ±65536 already exceeds the entire binary80 exponent
        // range, including subnormals. Bound it before host exponent addition.
        let integer = scale.signedIntegerBits(bitCount: 32, rounding: .towardZero)
          .map { Int(Int32(bitPattern: UInt32(truncatingIfNeeded: $0))) }
          ?? (scale.isNegative ? -65536 : 65536)
        writeX87Register(
          0,
          value: extendedX.scaledByPowerOfTwo(max(-65536, min(65536, integer))),
          state: &state
        )
      } else {
        writeX87Register(0, value: x * Foundation.pow(2, scale.doubleValue), state: &state)
      }
    case .sine:
      guard x87TrigonometricArgumentIsInRange(x, state: &state) else { return }
      writeX87Register(0, value: Foundation.sin(x), state: &state)
    case .cosine:
      guard x87TrigonometricArgumentIsInRange(x, state: &state) else { return }
      writeX87Register(0, value: Foundation.cos(x), state: &state)
    }
  }

  private func x87RoundingRule(_ state: DoryX86FloatingPointState) -> FloatingPointRoundingRule {
    switch (state.x87ControlWord >> 10) & 3 {
    case 0: .toNearestOrEven
    case 1: .down
    case 2: .up
    default: .towardZero
    }
  }

  private func x87Rounding(_ state: DoryX86FloatingPointState) -> DoryX86FloatingRounding {
    switch (state.x87ControlWord >> 10) & 3 {
    case 0: .nearestEven
    case 1: .down
    case 2: .up
    default: .towardZero
    }
  }

  private func x87Precision(_ state: DoryX86FloatingPointState) -> Int {
    switch (state.x87ControlWord >> 8) & 3 {
    case 0: 24
    case 2: 53
    default: 64
    }
  }

  private func x87FloatingComparison(
    _ lhs: DoryX86ExtendedFloat,
    _ rhs: DoryX86ExtendedFloat
  ) -> FloatingComparison {
    guard let relation = lhs.compared(to: rhs) else { return .unordered }
    switch relation {
    case .orderedAscending: return .less
    case .orderedDescending: return .greater
    case .orderedSame: return .equal
    }
  }

  private func setX87ComparisonStatus(
    _ relation: FloatingComparison,
    state: inout DoryX86FloatingPointState
  ) {
    state.x87StatusWord &= ~UInt16(0x4500)
    switch relation {
    case .greater:
      break
    case .less:
      state.x87StatusWord |= 0x0100
    case .equal:
      state.x87StatusWord |= 0x4000
    case .unordered:
      state.x87StatusWord |= 0x4500
    }
  }

  private func x87TrigonometricArgumentIsInRange(
    _ value: Double,
    state: inout DoryX86FloatingPointState
  ) -> Bool {
    if value.isFinite, abs(value) < 9_223_372_036_854_775_808.0 {
      state.x87StatusWord &= ~UInt16(0x0400)
      return true
    }
    state.x87StatusWord |= 0x0400
    return false
  }

  private func executeX87Remainder(
    nearest: Bool,
    state: inout DoryX86FloatingPointState
  ) {
    let dividend = readX87Register(0, state: state)
    let divisor = readX87Register(1, state: state)
    guard dividend.isFinite, divisor.isFinite, !divisor.isZero else {
      state.x87StatusWord |= 1
      writeX87Register(0, value: .nan, state: &state)
      return
    }
    let dividendDouble = dividend.doubleValue
    let divisorDouble = divisor.doubleValue
    let quotient =
      (dividendDouble / divisorDouble).rounded(nearest ? .toNearestOrEven : .towardZero)
    writeX87Register(0, value: dividendDouble - quotient * divisorDouble, state: &state)
    state.x87StatusWord &= ~UInt16(0x4700)
    // The floating representation of Int64.max rounds to 2^63, which is
    // outside Int64. Exact conversion also rejects non-finite intermediates.
    if let integer = Int64(exactly: quotient) {
      let bits = UInt64(bitPattern: integer)
      if bits & 1 != 0 { state.x87StatusWord |= 0x0200 }
      if bits & 2 != 0 { state.x87StatusWord |= 0x4000 }
      if bits & 4 != 0 { state.x87StatusWord |= 0x0100 }
    }
  }

  private func decodeX87PackedBCD(
    _ bytes: [UInt8],
    state: inout DoryX86FloatingPointState
  ) -> Double {
    precondition(bytes.count == 10)
    var magnitude: UInt64 = 0
    var place: UInt64 = 1
    for byte in bytes.prefix(9) {
      let low = byte & 0x0F
      let high = byte >> 4
      guard low <= 9, high <= 9 else {
        state.x87StatusWord |= 1
        return .nan
      }
      magnitude += UInt64(low) * place
      place *= 10
      magnitude += UInt64(high) * place
      place *= 10
    }
    let value = Double(magnitude)
    return bytes[9] & 0x80 == 0 ? value : -value
  }

  private func encodeX87PackedBCD(
    _ value: Double,
    state: inout DoryX86FloatingPointState
  ) -> [UInt8] {
    let rounded = value.rounded(x87RoundingRule(state))
    guard rounded.isFinite, abs(rounded) < 1_000_000_000_000_000_000 else {
      state.x87StatusWord |= 1
      return [UInt8](repeating: 0, count: 9) + [0xC0]
    }
    var magnitude = UInt64(abs(rounded))
    var bytes = [UInt8](repeating: 0, count: 10)
    for index in 0..<9 {
      let low = UInt8(magnitude % 10)
      magnitude /= 10
      let high = UInt8(magnitude % 10)
      magnitude /= 10
      bytes[index] = low | high << 4
    }
    if rounded.sign == .minus { bytes[9] = 0x80 }
    return bytes
  }

  private func pushX87(_ value: Double, state: inout DoryX86FloatingPointState) {
    pushX87(DoryX86ExtendedFloat(value), state: &state)
  }

  private func pushX87(
    _ value: DoryX86ExtendedFloat,
    state: inout DoryX86FloatingPointState
  ) {
    let top = (x87Top(state) + 7) & 7
    if x87Tag(top, state: state) != 3 {
      state.x87StatusWord |= 0x0241
    } else {
      state.x87StatusWord &= ~UInt16(0x0200)
    }
    setX87Top(top, state: &state)
    state.x87[top] = try! .init(bytes: value.bytes(), expectedByteCount: 10)
    let tag: UInt16 = value.isZero ? 1 : (value.isFinite ? 0 : 2)
    setX87Tag(top, tag, state: &state)
  }

  private func popX87(state: inout DoryX86FloatingPointState) {
    let top = x87Top(state)
    setX87Tag(top, 3, state: &state)
    setX87Top((top + 1) & 7, state: &state)
  }

  private func writeVectorBytes(
    _ bytes: [UInt8],
    to memoryOperand: DoryX86MemoryOperand,
    instruction: DoryX86DecodedInstruction,
    state: DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws {
    try validateSegmentAccess(
      memoryOperand,
      byteCount: bytes.count,
      write: true,
      instruction: instruction,
      state: state
    )
    let address = effectiveAddress(memoryOperand, instruction: instruction, state: state)
    try memory.validateWrite(at: address, byteCount: bytes.count)
    try memory.write(at: address, bytes: bytes)
  }

  private func isVectorMemory(_ operand: DoryX86VectorOperand) -> Bool {
    if case .memory = operand { return true }
    return false
  }

  private func executeVectorFloatingBinary(
    _ operation: DoryX86VectorFloatingOperation,
    format: DoryX86VectorFloatingFormat,
    destination: inout [UInt8],
    source: [UInt8]
  ) {
    switch format {
    case .packedSingle, .scalarSingle:
      let laneCount = format == .packedSingle ? 4 : 1
      for lane in 0..<laneCount {
        let offset = lane * 4
        let lhsBits = UInt32(fromLittleEndian(Array(destination[offset..<offset + 4])))
        let rhsBits = UInt32(fromLittleEndian(Array(source[offset..<offset + 4])))
        let result = floatingResult(
          operation,
          lhs: Float(bitPattern: lhsBits),
          rhs: Float(bitPattern: rhsBits)
        )
        replaceLittleEndian(result.bitPattern, in: &destination, at: offset)
      }
    case .packedDouble, .scalarDouble:
      let laneCount = format == .packedDouble ? 2 : 1
      for lane in 0..<laneCount {
        let offset = lane * 8
        let lhsBits = fromLittleEndian(Array(destination[offset..<offset + 8]))
        let rhsBits = fromLittleEndian(Array(source[offset..<offset + 8]))
        let result = floatingResult(
          operation,
          lhs: Double(bitPattern: lhsBits),
          rhs: Double(bitPattern: rhsBits)
        )
        replaceLittleEndian(result.bitPattern, in: &destination, at: offset)
      }
    }
  }

  private func floatingResult<T: BinaryFloatingPoint>(
    _ operation: DoryX86VectorFloatingOperation,
    lhs: T,
    rhs: T
  ) -> T {
    switch operation {
    case .add: return lhs + rhs
    case .multiply: return lhs * rhs
    case .subtract: return lhs - rhs
    case .divide: return lhs / rhs
    case .minimum:
      if lhs.isNaN || rhs.isNaN || lhs == rhs { return rhs }
      return lhs < rhs ? lhs : rhs
    case .maximum:
      if lhs.isNaN || rhs.isNaN || lhs == rhs { return rhs }
      return lhs > rhs ? lhs : rhs
    }
  }

  private func executeVectorIntegerBinary(
    _ operation: DoryX86VectorIntegerOperation,
    laneWidth: DoryX86VectorLaneWidth,
    destination: inout [UInt8],
    source: [UInt8],
    vectorByteCount: Int = 16
  ) {
    if operation == .sumAbsoluteDifferences {
      for groupOffset in stride(from: 0, to: vectorByteCount, by: 8) {
        var sum: UInt16 = 0
        for offset in groupOffset..<groupOffset + 8 {
          sum += UInt16(abs(Int(destination[offset]) - Int(source[offset])))
        }
        destination.replaceSubrange(
          groupOffset..<groupOffset + 8,
          with: littleEndian(UInt64(sum), width: .quadword)
        )
      }
      return
    }
    if operation == .multiplyUnsignedDoubleword {
      for offset in stride(from: 0, to: vectorByteCount, by: 8) {
        let lhs = UInt32(fromLittleEndian(Array(destination[offset..<offset + 4])))
        let rhs = UInt32(fromLittleEndian(Array(source[offset..<offset + 4])))
        replaceLittleEndian(UInt64(lhs) * UInt64(rhs), in: &destination, at: offset)
      }
      return
    }
    if operation == .multiplyAddWords {
      for offset in stride(from: 0, to: vectorByteCount, by: 4) {
        let lhsLow = Int32(
          Int16(
            bitPattern: UInt16(
              fromLittleEndian(
                Array(destination[offset..<offset + 2])))))
        let lhsHigh = Int32(
          Int16(
            bitPattern: UInt16(
              fromLittleEndian(
                Array(destination[offset + 2..<offset + 4])))))
        let rhsLow = Int32(
          Int16(
            bitPattern: UInt16(
              fromLittleEndian(
                Array(source[offset..<offset + 2])))))
        let rhsHigh = Int32(
          Int16(
            bitPattern: UInt16(
              fromLittleEndian(
                Array(source[offset + 2..<offset + 4])))))
        let result = lhsLow &* rhsLow &+ lhsHigh &* rhsHigh
        replaceLittleEndian(UInt32(bitPattern: result), in: &destination, at: offset)
      }
      return
    }
    let byteCount = Int(laneWidth.rawValue)
    let laneMask = byteCount == 8 ? UInt64.max : (UInt64(1) << UInt64(byteCount * 8)) - 1
    let signBit = UInt64(1) << UInt64(byteCount * 8 - 1)
    for offset in stride(from: 0, to: vectorByteCount, by: byteCount) {
      let lhs = fromLittleEndian(Array(destination[offset..<offset + byteCount]))
      let rhs = fromLittleEndian(Array(source[offset..<offset + byteCount]))
      let result: UInt64 =
        switch operation {
        case .add: (lhs &+ rhs) & laneMask
        case .subtract: (lhs &- rhs) & laneMask
        case .addSignedSaturating:
          unsignedVectorLane(
            saturatingSignedVectorLane(
              signedVectorLane(lhs, bitCount: byteCount * 8)
                + signedVectorLane(rhs, bitCount: byteCount * 8),
              bitCount: byteCount * 8),
            bitCount: byteCount * 8)
        case .addUnsignedSaturating: min(lhs + rhs, laneMask)
        case .subtractSignedSaturating:
          unsignedVectorLane(
            saturatingSignedVectorLane(
              signedVectorLane(lhs, bitCount: byteCount * 8)
                - signedVectorLane(rhs, bitCount: byteCount * 8),
              bitCount: byteCount * 8),
            bitCount: byteCount * 8)
        case .subtractUnsignedSaturating: lhs >= rhs ? lhs - rhs : 0
        case .minimumSigned:
          signedVectorLane(lhs, bitCount: byteCount * 8)
            < signedVectorLane(rhs, bitCount: byteCount * 8) ? lhs : rhs
        case .maximumSigned:
          signedVectorLane(lhs, bitCount: byteCount * 8)
            > signedVectorLane(rhs, bitCount: byteCount * 8) ? lhs : rhs
        case .minimumUnsigned: min(lhs, rhs)
        case .maximumUnsigned: max(lhs, rhs)
        case .averageUnsigned: (lhs + rhs + 1) >> 1
        case .equal: lhs == rhs ? laneMask : 0
        case .greaterThan: (lhs ^ signBit) > (rhs ^ signBit) ? laneMask : 0
        case .multiplyLow: (lhs &* rhs) & laneMask
        case .multiplyHighUnsigned: (lhs * rhs) >> UInt64(byteCount * 8)
        case .multiplyHighSigned:
          UInt64(
            bitPattern: signedVectorLane(lhs, bitCount: byteCount * 8)
              * signedVectorLane(rhs, bitCount: byteCount * 8))
            >> UInt64(byteCount * 8) & laneMask
        case .multiplyUnsignedDoubleword, .multiplyAddWords, .sumAbsoluteDifferences:
          preconditionFailure("wide packed multiply handled before lane loop")
        }
      for index in 0..<byteCount {
        destination[offset + index] = UInt8(truncatingIfNeeded: result >> UInt64(index * 8))
      }
    }
  }

  private func signedVectorLane(_ value: UInt64, bitCount: Int) -> Int64 {
    let signBit = UInt64(1) << UInt64(bitCount - 1)
    return Int64(bitPattern: (value ^ signBit) &- signBit)
  }

  private func packVectorIntegers(
    _ operation: DoryX86VectorPackOperation,
    sourceLaneWidth: DoryX86VectorLaneWidth,
    lhs: [UInt8],
    rhs: [UInt8]
  ) -> [UInt8] {
    let sourceByteCount = Int(sourceLaneWidth.rawValue)
    let resultByteCount = sourceByteCount / 2
    let resultBitCount = resultByteCount * 8
    let signedMaximum = (Int64(1) << Int64(resultBitCount - 1)) - 1
    let signedMinimum = -(Int64(1) << Int64(resultBitCount - 1))
    let unsignedMaximum = (Int64(1) << Int64(resultBitCount)) - 1
    return [lhs, rhs].flatMap { bytes in
      stride(from: 0, to: bytes.count, by: sourceByteCount).flatMap { offset in
        let raw = fromLittleEndian(Array(bytes[offset..<offset + sourceByteCount]))
        let signed = signedVectorLane(raw, bitCount: sourceByteCount * 8)
        let narrowed: UInt64 =
          switch operation {
          case .signedSaturating:
            UInt64(bitPattern: min(max(signed, signedMinimum), signedMaximum))
          case .unsignedSaturating:
            UInt64(min(max(signed, 0), unsignedMaximum))
          }
        return (0..<resultByteCount).map {
          UInt8(truncatingIfNeeded: narrowed >> UInt64($0 * 8))
        }
      }
    }
  }

  private func saturatingSignedVectorLane(_ value: Int64, bitCount: Int) -> Int64 {
    let maximum = (Int64(1) << Int64(bitCount - 1)) - 1
    let minimum = -(Int64(1) << Int64(bitCount - 1))
    return min(max(value, minimum), maximum)
  }

  private func unsignedVectorLane(_ value: Int64, bitCount: Int) -> UInt64 {
    let mask = (UInt64(1) << UInt64(bitCount)) - 1
    return UInt64(bitPattern: value) & mask
  }

  private func executeVectorIntegerShift(
    _ operation: DoryX86VectorShiftOperation,
    laneWidth: DoryX86VectorLaneWidth,
    destination: inout [UInt8],
    count: UInt64,
    vectorByteCount: Int = 16
  ) {
    let byteCount = Int(laneWidth.rawValue)
    let bitCount = UInt64(byteCount * 8)
    let laneMask = byteCount == 8 ? UInt64.max : (UInt64(1) << bitCount) - 1
    let effectiveCount = operation == .arithmeticRight ? min(count, bitCount - 1) : count
    for offset in stride(from: 0, to: vectorByteCount, by: byteCount) {
      let lane = fromLittleEndian(Array(destination[offset..<offset + byteCount]))
      let result: UInt64
      if operation != .arithmeticRight, effectiveCount >= bitCount {
        result = 0
      } else {
        switch operation {
        case .logicalLeft:
          result = (lane << effectiveCount) & laneMask
        case .logicalRight:
          result = lane >> effectiveCount
        case .arithmeticRight:
          let signBit = UInt64(1) << (bitCount - 1)
          let signedLane = Int64(bitPattern: (lane ^ signBit) &- signBit)
          result = UInt64(bitPattern: signedLane >> effectiveCount) & laneMask
        }
      }
      for index in 0..<byteCount {
        destination[offset + index] = UInt8(truncatingIfNeeded: result >> UInt64(index * 8))
      }
    }
  }

  private enum FloatingComparison {
    case greater, less, equal, unordered
  }

  private func floatingComparison<T: BinaryFloatingPoint>(_ lhs: T, _ rhs: T) -> FloatingComparison
  {
    if lhs.isNaN || rhs.isNaN { return .unordered }
    if lhs < rhs { return .less }
    if lhs > rhs { return .greater }
    return .equal
  }

  private func shuffleVector(
    format: DoryX86VectorShuffleFormat,
    lhs: [UInt8],
    rhs: [UInt8],
    control: UInt8
  ) -> [UInt8] {
    switch format {
    case .packedLowWords, .packedHighWords:
      // SDM 092 Vol. 2B PSHUFLW/PSHUFHW: select each word independently
      // from the chosen source half; copy the other source half unchanged.
      let halfOffset = format == .packedLowWords ? 0 : 8
      var result = rhs
      for lane in 0..<4 {
        let sourceOffset = halfOffset + Int((control >> (lane * 2)) & 3) * 2
        let destinationOffset = halfOffset + lane * 2
        result[destinationOffset] = rhs[sourceOffset]
        result[destinationOffset + 1] = rhs[sourceOffset + 1]
      }
      return result
    case .packedDoublewords:
      return (0..<4).flatMap { lane -> [UInt8] in
        let sourceLane = Int(control >> UInt8(lane * 2) & 3)
        return Array(rhs[sourceLane * 4..<sourceLane * 4 + 4])
      }
    case .packedSingle:
      return (0..<4).flatMap { lane -> [UInt8] in
        let sourceLane = Int(control >> UInt8(lane * 2) & 3)
        let bytes = lane < 2 ? lhs : rhs
        return Array(bytes[sourceLane * 4..<sourceLane * 4 + 4])
      }
    case .packedDouble:
      let lhsLane = Int(control & 1)
      let rhsLane = Int(control >> 1 & 1)
      return Array(lhs[lhsLane * 8..<lhsLane * 8 + 8])
        + Array(rhs[rhsLane * 8..<rhsLane * 8 + 8])
    }
  }

  private func packedDoubleToDwordResult(
    _ bitPattern: UInt64,
    truncated: Bool,
    mxcsr: UInt32
  ) -> (value: UInt32, exceptions: UInt32) {
    // Intel SDM Vol. 1 §11.5.2.2: these conversions do not raise #D, but DAZ
    // still substitutes signed zero. Invalid conversion produces integer indefinite.
    var value = Double(bitPattern: bitPattern)
    if mxcsr & (1 << 6) != 0, value.isSubnormal {
      value = Double(bitPattern: bitPattern & (1 << 63))
    }
    guard value.isFinite else { return (0x8000_0000, 1) }
    let rule: FloatingPointRoundingRule =
      if truncated {
        .towardZero
      } else {
        switch (mxcsr >> 13) & 3 {
        case 0: .toNearestOrEven
        case 1: .down
        case 2: .up
        default: .towardZero
        }
      }
    let rounded = value.rounded(rule)
    guard rounded.isFinite, rounded >= -2_147_483_648.0, rounded < 2_147_483_648.0 else {
      return (0x8000_0000, 1)
    }
    return (UInt32(bitPattern: Int32(rounded)), rounded == value ? 0 : 1 << 5)
  }

  private func floatingIntegerResult<T: BinaryFloatingPoint>(
    _ value: T,
    width: DoryX86OperandWidth,
    truncate: Bool,
    mxcsr: UInt32
  ) -> UInt64 {
    precondition(width == .doubleword || width == .quadword)
    let rule: FloatingPointRoundingRule =
      if truncate {
        .towardZero
      } else {
        switch (mxcsr >> 13) & 3 {
        case 0: .toNearestOrEven
        case 1: .down
        case 2: .up
        default: .towardZero
        }
      }
    let rounded = value.rounded(rule)
    let roundedDouble = Double(rounded)
    let lower = width == .doubleword ? -2_147_483_648.0 : -9_223_372_036_854_775_808.0
    let upper = width == .doubleword ? 2_147_483_648.0 : 9_223_372_036_854_775_808.0
    guard roundedDouble.isFinite, roundedDouble >= lower, roundedDouble < upper else {
      return width == .doubleword ? 0x8000_0000 : 0x8000_0000_0000_0000
    }
    let signed = Int64(roundedDouble)
    if width == .doubleword {
      return UInt64(UInt32(bitPattern: Int32(truncatingIfNeeded: signed)))
    }
    return UInt64(bitPattern: signed)
  }

  private func currentPrivilegeLevel(
    _ state: DoryX86ArchitecturalState,
    mode: DoryX86ExecutionMode
  ) -> UInt8 {
    if mode == .real16 { return 0 }
    // VM selects CPL 3 only outside IA-32e mode; selector low bits are not privilege in v8086.
    if mode != .long64, state.control.efer & (1 << 10) == 0,
      state.rflags.contains(.virtual8086) { return 3 }
    return UInt8(state.cs.selector & 3)
  }

  private func ioPort(
    _ operand: DoryX86IOPort,
    state: DoryX86ArchitecturalState
  ) -> UInt16 {
    switch operand {
    case .immediate(let port): UInt16(port)
    case .dx: UInt16(truncatingIfNeeded: state.registers.rdx)
    }
  }

  private func permitsPortIO(
    port: UInt16,
    width: DoryX86OperandWidth,
    mode: DoryX86ExecutionMode,
    state: DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws -> Bool {
    guard width != .quadword else { return false }
    if mode == .real16 { return true }
    let privilege = currentPrivilegeLevel(state, mode: mode)
    let ioPrivilege = UInt8((state.rflags.rawValue >> 12) & 3)
    let virtual8086 = mode != .long64 && state.control.efer & (1 << 10) == 0
      && state.rflags.contains(.virtual8086)
    // Virtual-8086 I/O always consults the TSS bitmap, including at IOPL 3 (Intel IN/OUT).
    if !virtual8086, privilege <= ioPrivilege { return true }

    let taskType = UInt8(truncatingIfNeeded: state.tr.attributes) & 0x0f
    guard taskType == 0x9 || taskType == 0xB, state.tr.limit >= 0x67 else { return false }
    func readTaskState(at address: UInt64, byteCount: Int) throws -> [UInt8] {
      if let translatedMemory = memory as? DoryX86TranslatedMemory {
        return try translatedMemory.readImplicitSupervisor(at: address, byteCount: byteCount)
      }
      return try memory.read(at: address, byteCount: byteCount)
    }
    let mapBaseBytes = try readTaskState(at: state.tr.base &+ 0x66, byteCount: 2)
    let mapBase = fromLittleEndian(mapBaseBytes)
    for byteOffset in 0..<width.byteCount {
      let bit = UInt32(port) + UInt32(byteOffset)
      guard bit <= UInt32(UInt16.max) else { return false }
      let bitmapOffset = mapBase + UInt64(bit / 8)
      guard bitmapOffset <= UInt64(state.tr.limit) else { return false }
      let permissions = try readTaskState(at: state.tr.base &+ bitmapOffset, byteCount: 1)[0]
      if permissions & (UInt8(1) << UInt8(bit & 7)) != 0 { return false }
    }
    return true
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

  private func invalidOpcode(at instructionPointer: UInt64) -> DoryX86InterpreterResult {
    .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: instructionPointer))
  }

  private func readDebugRegister(
    _ index: UInt8,
    state: DoryX86ArchitecturalState
  ) -> UInt64? {
    switch index {
    case 0: state.debug.dr0
    case 1: state.debug.dr1
    case 2: state.debug.dr2
    case 3: state.debug.dr3
    case 6: state.debug.dr6
    case 7: state.debug.dr7
    default: nil
    }
  }

  private func writeDebugRegister(
    _ index: UInt8,
    value: UInt64,
    state: inout DoryX86ArchitecturalState
  ) -> Bool {
    // This receives an already-normalized index and a mode-width value. DR4/5
    // aliases therefore receive the same reserved-high-bit check as DR6/7.
    if index == 6 || index == 7 {
      guard value >> 32 == 0 else { return false }
    }
    switch index {
    case 0: state.debug.dr0 = value
    case 1: state.debug.dr1 = value
    case 2: state.debug.dr2 = value
    case 3: state.debug.dr3 = value
    case 6: state.debug.dr6 = value
    case 7: state.debug.dr7 = value | (1 << 10)
    default: return false
    }
    return true
  }

  private func normalizedDebugRegister(
    _ index: UInt8,
    state: DoryX86ArchitecturalState
  ) -> UInt8? {
    guard index < 8 else { return nil }
    if index == 4 || index == 5 {
      guard state.control.cr4 & (1 << 3) == 0 else { return nil }
      return index + 2
    }
    return index
  }

  private func debugRegisterAccessFault(
    state: inout DoryX86ArchitecturalState,
    mode: DoryX86ExecutionMode,
    at instructionPointer: UInt64
  ) -> DoryX86InterpreterResult? {
    // Dory's narrow MOV DR policy adopts the Intel ordering #UD > #DB > #GP.
    // The SDM specifies the individual faults, but not the GD/CPL overlap.
    // Christopherson's Intel Skylake/Icelake/Emerald Rapids observations place
    // GD ahead of CPL #GP; AMD differs. This is not local physical qualification:
    // https://lore.kernel.org/all/20260612230113.684301-6-seanjc@google.com/
    if state.debug.dr7 & (1 << 13) != 0 {
      // SDM Vol. 3B 20.2.3/4 and 20.3.1.3: set BD and non-RTM status, clear GD.
      // No instruction has retired; the step boundary publishes only debug state.
      state.debug.dr6 |= (1 << 13) | (1 << 16)
      state.debug.dr7 &= ~UInt64(1 << 13)
      return .exception(.init(kind: .debug, vector: 1, instructionPointer: instructionPointer))
    }
    if currentPrivilegeLevel(state, mode: mode) != 0 {
      return generalProtection(at: instructionPointer)
    }
    return nil
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
    physicalMemory: any DoryX86Memory,
    pagingUnit: DoryX86PagingUnit?
  ) -> Bool {
    let previous = state.control
    var candidate = previous
    var invalidate = false
    var reloadPDPTEs = false
    switch index {
    case 0:
      // Intel SDM Vol. 2B MOV CR: reserved low bits are ignored, reserved high
      // bits cause #GP, and ET remains fixed at one after every successful write.
      guard value >> 32 == 0 else { return false }
      let normalizedValue = (value & 0xE005_003F) | (1 << 4)
      let paging = normalizedValue & (1 << 31) != 0
      let protectedMode = normalizedValue & 1 != 0
      let cacheDisable = normalizedValue & (1 << 30) != 0
      let notWriteThrough = normalizedValue & (1 << 29) != 0
      guard !paging || protectedMode,
        !notWriteThrough || cacheDisable
      else { return false }
      let wasPaging = previous.cr0 & (1 << 31) != 0
      let longModeActive = previous.efer & (1 << 10) != 0
      let longCodeSegment = state.cs.attributes & (1 << 13) != 0
      guard paging || (previous.cr4 & (1 << 17) == 0 && !(longModeActive && longCodeSegment))
      else { return false }
      if paging, !wasPaging, previous.efer & (1 << 8) != 0 {
        let taskType = state.tr.attributes & 0xF
        guard profile.supports(.longMode), previous.cr4 & (1 << 5) != 0,
          !longCodeSegment, taskType != 1, taskType != 3
        else { return false }
        candidate.efer |= 1 << 10
      } else if !paging {
        candidate.efer &= ~(1 << 10)
      }
      candidate.cr0 = normalizedValue
      let reloadMask: UInt64 = (1 << 30) | (1 << 29) | (1 << 31) // CD, NW, PG
      reloadPDPTEs = candidate.isLegacyPAEPagingActive
        && (previous.cr0 ^ candidate.cr0) & reloadMask != 0
      invalidate = true
    case 2:
      candidate.cr2 = value
    case 3:
      let pcidEnabled = previous.cr4 & (1 << 17) != 0
      let noFlush = value & (1 << 63) != 0
      // Low CR3 bits are a PCID, cache controls, ignored bits, or part of a
      // legacy PAE 32-byte root. They are never an alignment fault; the walker
      // selects the address bits appropriate to the active paging mode.
      let addressMask = ((UInt64(1) << profile.physicalAddressBits) - 1) & ~0xfff
      let storedValue = value & ~(1 << 63)
      guard !noFlush || pcidEnabled,
        storedValue & ~addressMask & ~UInt64(0xfff) == 0
      else { return false }
      candidate.cr3 = storedValue
      reloadPDPTEs = candidate.isLegacyPAEPagingActive
      invalidate = !noFlush
    case 4:
      // Engineering mechanisms remain testable while their CPUID qualification is
      // incomplete; this mask does not advertise PAE/PSE/PGE/PCID/SMEP/SMAP support.
      var implementedMask: UInt64 =
        (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5) | (1 << 6) | (1 << 7) | (1 << 8)
        | (1 << 9) | (1 << 10) | (1 << 17) | (1 << 20) | (1 << 21)
      if profile.supports(.xsave) { implementedMask |= 1 << 18 }
      guard value & ~implementedMask == 0 else { return false }
      if value & (1 << 17) != 0 {
        guard previous.efer & (1 << 10) != 0 else { return false }
        if previous.cr4 & (1 << 17) == 0, previous.cr3 & 0xFFF != 0 { return false }
      }
      // IA-32e cannot be left by clearing PAE. Otherwise it could bypass the
      // required CR0 transition and leave the walker in an inconsistent mode.
      guard previous.efer & (1 << 10) == 0 || value & (1 << 5) != 0 else { return false }
      candidate.cr4 = value
      let reloadMask: UInt64 = (1 << 5) | (1 << 7) | (1 << 4) | (1 << 20) // PAE, PGE, PSE, SMEP
      reloadPDPTEs = candidate.isLegacyPAEPagingActive
        && (previous.cr4 ^ candidate.cr4) & reloadMask != 0
      invalidate = true
    case 8:
      guard value <= 15 else { return false }
      candidate.cr8 = value
    default:
      return false
    }
    if reloadPDPTEs {
      do {
        // Intel SDM 092 Vol. 3A §5.4.1: load all four using physical CR3[31:5].
        // Do not translate this read through either the old or candidate page tables.
        let root = candidate.cr3 & 0xffff_ffe0
        var entries: [UInt64] = []
        for index in 0..<4 {
          let bytes = try physicalMemory.read(at: root + UInt64(index) * 8, byteCount: 8)
          guard bytes.count == 8 else { return false }
          entries.append(bytes.enumerated().reduce(UInt64(0)) {
            $0 | (UInt64($1.element) << ($1.offset * 8))
          })
        }
        let loaded = DoryX86PAEPDPTEs(entries[0], entries[1], entries[2], entries[3])
        try loaded.validate(physicalAddressBits: profile.physicalAddressBits)
        candidate.legacyPAEPDPTEs = loaded
      } catch {
        return false
      }
    }
    // A failed physical read or reserved-bit check publishes neither controls nor latch,
    // and leaves cached translations intact. Broad successful invalidation is permitted.
    state.control = candidate
    if invalidate { pagingUnit?.invalidateAll() }
    return true
  }

  private func readModelSpecificRegister(
    _ index: UInt32,
    state: DoryX86ArchitecturalState
  ) -> UInt64? {
    switch index {
    case 0x10: state.tsc
    case 0x17: 0  // IA32_PLATFORM_ID: Dory's single virtual platform is ID zero.
    case 0x1B: state.modelSpecific.apicBase
    case 0x8B:
      profile.identity == .intelCompatibleV1
        ? UInt64(state.modelSpecific.biosUpdateSignature) << 32 : nil
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
    case 0x8B:
      // SDM 092 Vol. 3A §12.11.7: high DWORD is R/W, low DWORD reserved.
      // With no loaded update CPUID leaves the signature unchanged. A guest's
      // write-zero/CPUID.1/read sequence therefore truthfully returns zero.
      guard profile.identity == .intelCompatibleV1, UInt32(truncatingIfNeeded: value) == 0
      else { return false }
      state.modelSpecific.biosUpdateSignature = UInt32(truncatingIfNeeded: value >> 32)
    case 0x174:
      state.modelSpecific.systemEnterCS = value & 0xffff
    case 0x175:
      guard DoryX86ArchitecturalState.isCanonical(value) else { return false }
      state.modelSpecific.systemEnterStackPointer = value
    case 0x176:
      guard DoryX86ArchitecturalState.isCanonical(value) else { return false }
      state.modelSpecific.systemEnterInstructionPointer = value
    case 0x277:
      guard validPageAttributeTable(value) else { return false }
      state.modelSpecific.pageAttributeTable = value
    case 0xC000_0080:
      var writableMask: UInt64 = 0
      if profile.supports(.syscall) { writableMask |= 1 << 0 }
      if profile.supports(.longMode) { writableMask |= 1 << 8 }
      if profile.supports(.executeDisable) { writableMask |= 1 << 11 }
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
    memoryAddress: UInt64,
    memory: any DoryX86Memory,
    mode: DoryX86ExecutionMode,
    maximumByteCount: Int
  ) throws -> DoryX86DecodedInstruction {
    for requestedByteCount in 1...maximumByteCount {
      let bytes = try memory.instructionBytes(
        at: memoryAddress, maximumCount: requestedByteCount)
      do {
        return try decoder.decode(bytes, at: address, mode: mode)
      } catch DoryX86DecodeError.truncated {
        if bytes.count < requestedByteCount {
          _ = try memory.instructionBytes(
            at: memoryAddress &+ UInt64(bytes.count),
            maximumCount: 1
          )
        }
        continue
      }
    }
    if maximumByteCount < 15 {
      throw DoryX86Exception(
        kind: .generalProtection,
        vector: 13,
        errorCode: 0,
        instructionPointer: address
      )
    }
    throw DoryX86DecodeError.instructionTooLong(address: address)
  }

  private func instructionFetchByteCount(
    state: DoryX86ArchitecturalState,
    mode: DoryX86ExecutionMode,
    instructionPointer: UInt64
  ) throws -> Int {
    guard mode != .long64 else {
      guard DoryX86ArchitecturalState.isCanonical(instructionPointer) else {
        throw segmentProtection(at: instructionPointer)
      }
      return 15
    }
    let offset = instructionPointer & instructionPointerMask(mode)
    if mode == .protected16 || mode == .protected32 {
      let access = UInt8(truncatingIfNeeded: state.cs.attributes)
      guard access & 0x80 != 0, access & 0x10 != 0, access & 8 != 0 else {
        throw segmentProtection(at: instructionPointer)
      }
    }
    guard offset <= UInt64(state.cs.limit) else {
      throw segmentProtection(at: instructionPointer)
    }
    return Int(min(UInt64(15), UInt64(state.cs.limit) - offset + 1))
  }

  private func instructionFetchAddress(
    state: DoryX86ArchitecturalState,
    mode: DoryX86ExecutionMode
  ) -> UInt64 {
    switch mode {
    case .real16: state.cs.base &+ (state.rip & 0xffff)
    case .protected16: state.cs.base &+ (state.rip & 0xffff_ffff)
    case .protected32: state.cs.base &+ (state.rip & 0xffff_ffff)
    case .long64: state.rip
    }
  }

  private func instructionPointerMask(_ mode: DoryX86ExecutionMode) -> UInt64 {
    switch mode {
    case .real16: 0xffff
    case .protected16: 0xffff_ffff
    case .protected32: 0xffff_ffff
    case .long64: .max
    }
  }

  private func stackAddress(
    _ offset: UInt64,
    mode: DoryX86ExecutionMode,
    state: DoryX86ArchitecturalState
  ) -> UInt64 {
    (mode == .long64 ? 0 : state.ss.base) &+ offset
  }

  private func stackPointerWidth(
    mode: DoryX86ExecutionMode,
    state: DoryX86ArchitecturalState
  ) -> DoryX86OperandWidth {
    switch mode {
    case .real16: .word
    case .protected16: state.ss.attributes & 0x4000 != 0 ? .doubleword : .word
    case .long64: .quadword
    case .protected32: state.ss.attributes & 0x4000 != 0 ? .doubleword : .word
    }
  }

  private func stackPointerOffset(
    mode: DoryX86ExecutionMode,
    state: DoryX86ArchitecturalState
  ) -> UInt64 {
    state.registers.rsp & mask(stackPointerWidth(mode: mode, state: state))
  }

  private func writeStackPointer(
    _ value: UInt64,
    mode: DoryX86ExecutionMode,
    state: inout DoryX86ArchitecturalState
  ) {
    writeStringRegister(
      .rsp,
      value: value,
      width: stackPointerWidth(mode: mode, state: state),
      state: &state
    )
  }

  private func pushStack(
    _ value: UInt64,
    width: DoryX86OperandWidth,
    instruction: DoryX86DecodedInstruction,
    mode: DoryX86ExecutionMode,
    state: inout DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws {
    let pointerWidth = stackPointerWidth(mode: mode, state: state)
    let nextOffset =
      (stackPointerOffset(mode: mode, state: state) &- UInt64(width.byteCount))
      & mask(pointerWidth)
    try validateStackAccess(
      offset: nextOffset,
      byteCount: width.byteCount,
      write: true,
      instruction: instruction,
      mode: mode,
      state: state
    )
    let address = stackAddress(nextOffset, mode: mode, state: state)
    try memory.validateWrite(at: address, byteCount: width.byteCount)
    try memory.write(at: address, bytes: littleEndian(value, width: width))
    writeStackPointer(nextOffset, mode: mode, state: &state)
  }

  private func executeEnter(
    allocation: UInt16,
    nesting: UInt8,
    width: DoryX86OperandWidth,
    instruction: DoryX86DecodedInstruction,
    mode: DoryX86ExecutionMode,
    state: inout DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws {
    let pointerWidth = stackPointerWidth(mode: mode, state: state)
    let pointerMask = mask(pointerWidth)
    let operandMask = mask(width)
    let originalStack = stackPointerOffset(mode: mode, state: state)
    let frameBase = state.registers.rbp & operandMask
    let frameTemporary = (originalStack &- UInt64(width.byteCount)) & pointerMask
    var values = [frameBase]

    if nesting > 0 {
      var sourceOffset = frameBase
      if nesting > 1 {
        for _ in 1..<nesting {
          sourceOffset = (sourceOffset &- UInt64(width.byteCount)) & operandMask
          try validateStackAccess(
            offset: sourceOffset,
            byteCount: width.byteCount,
            write: false,
            instruction: instruction,
            mode: mode,
            state: state
          )
          values.append(
            fromLittleEndian(
              try memory.read(
                at: stackAddress(sourceOffset, mode: mode, state: state),
                byteCount: width.byteCount
              )))
        }
      }
      values.append(frameTemporary)
    }

    var writeOffsets: [UInt64] = []
    writeOffsets.reserveCapacity(values.count)
    for index in values.indices {
      let offset =
        (originalStack &- UInt64((index + 1) * width.byteCount)) & pointerMask
      try validateStackAccess(
        offset: offset,
        byteCount: width.byteCount,
        write: true,
        instruction: instruction,
        mode: mode,
        state: state
      )
      try memory.validateWrite(
        at: stackAddress(offset, mode: mode, state: state),
        byteCount: width.byteCount
      )
      writeOffsets.append(offset)
    }

    let stackAfterPushes = writeOffsets.last ?? originalStack
    let finalStack = (stackAfterPushes &- UInt64(allocation)) & pointerMask
    if allocation > 0 {
      try validateStackAccess(
        offset: finalStack,
        byteCount: Int(allocation),
        write: true,
        instruction: instruction,
        mode: mode,
        state: state
      )
    }
    for (offset, value) in zip(writeOffsets, values) {
      try memory.write(
        at: stackAddress(offset, mode: mode, state: state),
        bytes: littleEndian(value, width: width)
      )
    }
    writeStringRegister(.rbp, value: frameTemporary, width: width, state: &state)
    writeStackPointer(finalStack, mode: mode, state: &state)
  }

  private func readStack(
    width: DoryX86OperandWidth,
    instruction: DoryX86DecodedInstruction,
    mode: DoryX86ExecutionMode,
    state: DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws -> (value: UInt64, nextOffset: UInt64) {
    let offset = stackPointerOffset(mode: mode, state: state)
    try validateStackAccess(
      offset: offset,
      byteCount: width.byteCount,
      write: false,
      instruction: instruction,
      mode: mode,
      state: state
    )
    let value = fromLittleEndian(
      try memory.read(
        at: stackAddress(offset, mode: mode, state: state),
        byteCount: width.byteCount
      ))
    let nextOffset =
      (offset &+ UInt64(width.byteCount)) & mask(stackPointerWidth(mode: mode, state: state))
    return (value, nextOffset)
  }

  private func popStack(
    width: DoryX86OperandWidth,
    instruction: DoryX86DecodedInstruction,
    mode: DoryX86ExecutionMode,
    state: inout DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws -> UInt64 {
    let result = try readStack(
      width: width,
      instruction: instruction,
      mode: mode,
      state: state,
      memory: memory
    )
    writeStackPointer(result.nextOffset, mode: mode, state: &state)
    return result.value
  }

  private func validateStackAccess(
    offset: UInt64,
    byteCount: Int,
    write: Bool,
    instruction: DoryX86DecodedInstruction,
    mode: DoryX86ExecutionMode,
    state: DoryX86ArchitecturalState
  ) throws {
    if mode == .long64 {
      guard byteCount > 0 else { throw stackProtection(at: instruction.address) }
      let last = offset.addingReportingOverflow(UInt64(byteCount - 1))
      guard !last.overflow,
        DoryX86ArchitecturalState.isCanonical(offset),
        DoryX86ArchitecturalState.isCanonical(last.partialValue)
      else { throw stackProtection(at: instruction.address) }
      return
    }
    try validateSegmentBounds(
      state.ss,
      offset: offset,
      byteCount: byteCount,
      write: write,
      protectedMode: state.control.cr0 & 1 != 0,
      fault: stackProtection(at: instruction.address)
    )
  }

  // CS.D chooses the default operand width, not the width of the EIP register.
  // Legacy near transfers with a 16-bit operand clear EIP[31:16]; 66 toggles it.
  // Near CALL in 64-bit mode remains 64 bits even with 66 (SDM Vol. 2A CALL).
  private func nearTransferWidth(
    _ instruction: DoryX86DecodedInstruction, mode: DoryX86ExecutionMode
  ) -> DoryX86OperandWidth {
    guard mode != .long64 else { return .quadword }
    let default16 = mode == .real16 || mode == .protected16
    return default16 != instruction.prefixes.operandSizeOverride ? .word : .doubleword
  }

  private func validateNearBranchTarget(
    _ target: UInt64,
    mode: DoryX86ExecutionMode,
    instruction: DoryX86DecodedInstruction,
    state: DoryX86ArchitecturalState
  ) throws {
    if mode == .long64 {
      guard DoryX86ArchitecturalState.isCanonical(target) else {
        throw segmentProtection(at: instruction.address)
      }
    } else if target > UInt64(state.cs.limit) || (mode == .real16 && target > 0xFFFF) {
      // Fault at the transfer, before CALL's push, rather than at the next fetch.
      throw segmentProtection(at: instruction.address)
    }
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
      try validateSegmentAccess(
        operand,
        byteCount: operand.width.byteCount,
        write: false,
        instruction: instruction,
        state: state
      )
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
      try validateSegmentAccess(
        target,
        byteCount: target.width.byteCount,
        write: true,
        instruction: instruction,
        state: state
      )
      try memory.write(
        at: effectiveAddress(target, instruction: instruction, state: state),
        bytes: littleEndian(value, width: target.width)
      )
    case .immediate, .relative:
      throw DoryX86Exception(
        kind: .generalProtection, vector: 13, errorCode: 0, instructionPointer: state.rip)
    }
  }

  private func preflightWrite(
    to operand: DoryX86Operand,
    instruction: DoryX86DecodedInstruction,
    state: DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws {
    guard case .memory(let target) = operand else { return }
    try validateSegmentAccess(
      target,
      byteCount: target.width.byteCount,
      write: true,
      instruction: instruction,
      state: state
    )
    try memory.validateWrite(
      at: effectiveAddress(target, instruction: instruction, state: state),
      byteCount: target.width.byteCount
    )
  }

  private func validateSegmentAccess(
    _ operand: DoryX86MemoryOperand,
    byteCount: Int,
    write: Bool,
    instruction: DoryX86DecodedInstruction,
    state: DoryX86ArchitecturalState
  ) throws {
    guard !operand.ignoresLegacySegmentBase else { return }
    let segment = segmentState(operand.segment, state: state)
    let offset = effectiveOffset(
      operand,
      instruction: instruction,
      state: state
    )
    let fault =
      operand.segment == .ss
      ? stackProtection(at: instruction.address)
      : segmentProtection(at: instruction.address)
    try validateSegmentBounds(
      segment,
      offset: offset,
      byteCount: byteCount,
      write: write,
      protectedMode: state.control.cr0 & 1 != 0,
      fault: fault
    )
  }

  private func validateSegmentBounds(
    _ segment: DoryX86SegmentState,
    offset: UInt64,
    byteCount: Int,
    write: Bool,
    protectedMode: Bool,
    fault: DoryX86Exception
  ) throws {
    let lastResult = offset.addingReportingOverflow(UInt64(max(0, byteCount - 1)))
    guard !lastResult.overflow else { throw fault }
    if protectedMode {
      let access = UInt8(truncatingIfNeeded: segment.attributes)
      let type = access & 0x0f
      let executable = type & 8 != 0
      if write, executable || type & 2 == 0 { throw fault }
      if !write, executable, type & 2 == 0 { throw fault }
      if !executable, type & 4 != 0 {
        let maximum: UInt64 = segment.attributes & 0x4000 != 0 ? 0xffff_ffff : 0xffff
        guard offset > UInt64(segment.limit), lastResult.partialValue <= maximum else {
          throw fault
        }
        return
      }
    }
    guard lastResult.partialValue <= UInt64(segment.limit) else {
      throw fault
    }
  }

  private func segmentProtection(at instructionPointer: UInt64) -> DoryX86Exception {
    .init(
      kind: .generalProtection,
      vector: 13,
      errorCode: 0,
      instructionPointer: instructionPointer
    )
  }

  private func stackProtection(at instructionPointer: UInt64) -> DoryX86Exception {
    .init(
      kind: .stackSegment,
      vector: 12,
      errorCode: 0,
      instructionPointer: instructionPointer
    )
  }

  private func isMemory(_ operand: DoryX86Operand) -> Bool {
    if case .memory = operand { return true }
    return false
  }

  private func writeAccumulator(
    _ value: UInt64,
    width: DoryX86OperandWidth,
    instruction: DoryX86DecodedInstruction,
    state: inout DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws {
    try write(
      value,
      to: .register(.rax, width: width),
      instruction: instruction,
      state: &state,
      memory: memory
    )
  }

  private func executeBitTest(
    _ operation: DoryX86BitOperation,
    base: DoryX86Operand,
    index: DoryX86Operand,
    instruction: DoryX86DecodedInstruction,
    state: inout DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws {
    let width = operandWidth(base)
    let bitCount = Int64(width.rawValue)
    let rawIndex = try read(
      index, instruction: instruction, state: state, memory: memory)
    let bitIndex: Int64
    if case .immediate = index {
      bitIndex = Int64(rawIndex)
    } else {
      bitIndex = signExtendedInt64(rawIndex, width: width)
    }

    if case .memory(let memoryOperand) = base {
      var elementOffset = bitIndex / bitCount
      var bitOffset = bitIndex % bitCount
      if bitOffset < 0 {
        bitOffset += bitCount
        elementOffset -= 1
      }
      let baseAddress = effectiveAddress(
        memoryOperand, instruction: instruction, state: state)
      let address = baseAddress &+ UInt64(bitPattern: elementOffset * Int64(width.byteCount))
      let value = fromLittleEndian(try memory.read(at: address, byteCount: width.byteCount))
      let bit = UInt64(1) << UInt64(bitOffset)
      setFlag(.carry, value & bit != 0, in: &state.rflags)
      let result: UInt64 =
        switch operation {
        case .test: value
        case .set: value | bit
        case .reset: value & ~bit
        case .complement: value ^ bit
        }
      if operation != .test {
        try memory.validateWrite(at: address, byteCount: width.byteCount)
        try memory.write(at: address, bytes: littleEndian(result, width: width))
      }
      return
    }

    let bitOffset = UInt64(bitPattern: bitIndex) & UInt64(width.rawValue - 1)
    let bit = UInt64(1) << bitOffset
    let value = try read(base, instruction: instruction, state: state, memory: memory)
    setFlag(.carry, value & bit != 0, in: &state.rflags)
    let result: UInt64 =
      switch operation {
      case .test: value
      case .set: value | bit
      case .reset: value & ~bit
      case .complement: value ^ bit
      }
    if operation != .test {
      try write(result, to: base, instruction: instruction, state: &state, memory: memory)
    }
  }

  private func executeString(
    _ operation: DoryX86StringOperation,
    width: DoryX86OperandWidth,
    instruction: DoryX86DecodedInstruction,
    mode: DoryX86ExecutionMode,
    state: inout DoryX86ArchitecturalState,
    memory: any DoryX86Memory,
    ioBus: (any DoryX86IOBus)?
  ) throws -> Bool {
    let initialFlags = state.rflags
    let addressWidth = stringAddressWidth(mode: mode, instruction: instruction)
    let repeated = instruction.prefixes.repeatPrefix != nil
    var remaining = repeated ? stringRegister(.rcx, width: addressWidth, state: state) : 1
    var completed: UInt64 = 0
    let iterationBudget: UInt64 = 4_096
    let port = UInt16(truncatingIfNeeded: state.registers.rdx)
    if operation == .input || operation == .output {
      guard ioBus != nil,
        try permitsPortIO(
          port: port,
          width: width,
          mode: mode,
          state: state,
          memory: memory
        )
      else {
        throw DoryX86IOBusError.unmappedPort(port, width: width)
      }
    }

    if operation == .move,
      repeated,
      width == .byte,
      addressWidth == .quadword,
      !state.rflags.contains(.direction),
      let bulkMemory = memory as? any DoryX86BulkMemory
    {
      let source = stringSourceAddress(
        addressWidth: addressWidth,
        instruction: instruction,
        mode: mode,
        state: state
      )
      let destination = stringDestinationAddress(
        addressWidth: addressWidth,
        mode: mode,
        state: state
      )
      if forwardRangesDoNotOverlap(source: source, destination: destination, byteCount: remaining) {
        while remaining != 0, completed < iterationBudget {
          let sourceAddress = stringSourceAddress(
            addressWidth: addressWidth,
            instruction: instruction,
            mode: mode,
            state: state
          )
          let destinationAddress = stringDestinationAddress(
            addressWidth: addressWidth,
            mode: mode,
            state: state
          )
          let maximumCount = Int(min(remaining, iterationBudget - completed))
          do {
            guard
              let copied = try bulkMemory.copyForwardNonoverlapping(
                from: sourceAddress,
                to: destinationAddress,
                maximumByteCount: maximumCount
              ),
              copied > 0
            else { break }
            precondition(copied <= maximumCount)
            let delta = UInt64(copied)
            advanceStringRegister(
              .rsi, by: delta, decrement: false, width: addressWidth, state: &state)
            advanceStringRegister(
              .rdi, by: delta, decrement: false, width: addressWidth, state: &state)
            completed &+= delta
            remaining &-= delta
            writeStringRegister(.rcx, value: remaining, width: addressWidth, state: &state)
          } catch let error as DoryX86MemoryError {
            if completed != 0 { throw DoryX86PartialMemoryFault(error: error) }
            throw error
          }
        }
        if remaining == 0 { return true }
        if completed == iterationBudget { return false }
      }
    }

    if operation == .store,
      repeated,
      addressWidth == .quadword,
      mode == .long64,
      !state.rflags.contains(.direction),
      let bulkMemory = memory as? any DoryX86BulkMemory
    {
      let pattern = littleEndian(state.registers.rax, width: width)
      while remaining != 0, completed < iterationBudget {
        let destinationAddress = stringDestinationAddress(
          addressWidth: addressWidth,
          mode: mode,
          state: state
        )
        let maximumElementCount = Int(
          min(remaining, iterationBudget - completed, UInt64(Int.max))
        )
        do {
          guard
            let filled = try bulkMemory.fillRepeating(
              at: destinationAddress,
              pattern: pattern,
              maximumElementCount: maximumElementCount
            ),
            filled > 0
          else { break }
          precondition(filled <= maximumElementCount)
          let elementCount = UInt64(filled)
          let byteCount = elementCount &* UInt64(width.byteCount)
          advanceStringRegister(
            .rdi,
            by: byteCount,
            decrement: false,
            width: addressWidth,
            state: &state
          )
          completed &+= elementCount
          remaining &-= elementCount
          writeStringRegister(.rcx, value: remaining, width: addressWidth, state: &state)
        } catch let error as DoryX86MemoryError {
          if completed != 0 { throw DoryX86PartialMemoryFault(error: error) }
          throw error
        }
      }
      if remaining == 0 { return true }
      if completed == iterationBudget { return false }
    }

    while remaining != 0 {
      do {
        let sourceAddress = stringSourceAddress(
          addressWidth: addressWidth,
          instruction: instruction,
          mode: mode,
          state: state
        )
        let destinationAddress = stringDestinationAddress(
          addressWidth: addressWidth,
          mode: mode,
          state: state
        )
        let sourceOperand = stringMemoryOperand(
          source: true,
          width: width,
          addressWidth: addressWidth,
          instruction: instruction,
          mode: mode
        )
        let destinationOperand = stringMemoryOperand(
          source: false,
          width: width,
          addressWidth: addressWidth,
          instruction: instruction,
          mode: mode
        )
        switch operation {
        case .move:
          try validateSegmentAccess(
            sourceOperand,
            byteCount: width.byteCount,
            write: false,
            instruction: instruction,
            state: state
          )
          try validateSegmentAccess(
            destinationOperand,
            byteCount: width.byteCount,
            write: true,
            instruction: instruction,
            state: state
          )
          let bytes = try memory.read(at: sourceAddress, byteCount: width.byteCount)
          try memory.validateWrite(at: destinationAddress, byteCount: width.byteCount)
          try memory.write(at: destinationAddress, bytes: bytes)
        case .compare:
          try validateSegmentAccess(
            sourceOperand,
            byteCount: width.byteCount,
            write: false,
            instruction: instruction,
            state: state
          )
          try validateSegmentAccess(
            destinationOperand,
            byteCount: width.byteCount,
            write: false,
            instruction: instruction,
            state: state
          )
          let source = fromLittleEndian(
            try memory.read(at: sourceAddress, byteCount: width.byteCount))
          let destination = fromLittleEndian(
            try memory.read(at: destinationAddress, byteCount: width.byteCount))
          _ = executeALU(
            .compare,
            lhs: source,
            rhs: destination,
            width: width,
            flags: &state.rflags
          )
        case .store:
          try validateSegmentAccess(
            destinationOperand,
            byteCount: width.byteCount,
            write: true,
            instruction: instruction,
            state: state
          )
          try memory.validateWrite(at: destinationAddress, byteCount: width.byteCount)
          try memory.write(
            at: destinationAddress,
            bytes: littleEndian(state.registers.rax, width: width)
          )
        case .load:
          try validateSegmentAccess(
            sourceOperand,
            byteCount: width.byteCount,
            write: false,
            instruction: instruction,
            state: state
          )
          let value = fromLittleEndian(
            try memory.read(at: sourceAddress, byteCount: width.byteCount))
          writeStringRegister(.rax, value: value, width: width, state: &state)
        case .scan:
          try validateSegmentAccess(
            destinationOperand,
            byteCount: width.byteCount,
            write: false,
            instruction: instruction,
            state: state
          )
          let destination = fromLittleEndian(
            try memory.read(at: destinationAddress, byteCount: width.byteCount))
          _ = executeALU(
            .compare,
            lhs: state.registers.rax,
            rhs: destination,
            width: width,
            flags: &state.rflags
          )
        case .input:
          try validateSegmentAccess(
            destinationOperand,
            byteCount: width.byteCount,
            write: true,
            instruction: instruction,
            state: state
          )
          try memory.validateWrite(at: destinationAddress, byteCount: width.byteCount)
          guard let ioBus else {
            throw DoryX86IOBusError.unmappedPort(port, width: width)
          }
          let value = UInt64(try ioBus.read(port: port, width: width))
          try memory.write(at: destinationAddress, bytes: littleEndian(value, width: width))
        case .output:
          try validateSegmentAccess(
            sourceOperand,
            byteCount: width.byteCount,
            write: false,
            instruction: instruction,
            state: state
          )
          let value = UInt32(
            truncatingIfNeeded: fromLittleEndian(
              try memory.read(at: sourceAddress, byteCount: width.byteCount)
            ))
          guard let ioBus else {
            throw DoryX86IOBusError.unmappedPort(port, width: width)
          }
          try ioBus.write(port: port, value: value, width: width)
        }
      } catch let error as DoryX86MemoryError {
        if repeated, operation == .compare || operation == .scan {
          state.rflags = initialFlags
        }
        if completed != 0 { throw DoryX86PartialMemoryFault(error: error) }
        throw error
      } catch let exception as DoryX86Exception {
        if repeated, operation == .compare || operation == .scan {
          state.rflags = initialFlags
        }
        if completed != 0 { throw DoryX86PartialException(exception: exception) }
        throw exception
      } catch {
        if repeated, operation == .compare || operation == .scan {
          state.rflags = initialFlags
        }
        if completed != 0 { throw DoryX86PartialGeneralProtection() }
        throw error
      }

      let delta = UInt64(width.byteCount)
      let decrement = state.rflags.contains(.direction)
      if operation == .move || operation == .compare || operation == .load
        || operation == .output
      {
        advanceStringRegister(
          .rsi, by: delta, decrement: decrement, width: addressWidth, state: &state)
      }
      if operation == .move || operation == .compare || operation == .store || operation == .scan
        || operation == .input
      {
        advanceStringRegister(
          .rdi, by: delta, decrement: decrement, width: addressWidth, state: &state)
      }
      completed &+= 1
      if repeated {
        remaining &-= 1
        writeStringRegister(.rcx, value: remaining, width: addressWidth, state: &state)
        if operation == .compare || operation == .scan {
          let zero = state.rflags.contains(.zero)
          if instruction.prefixes.repeatPrefix == 0xF3, !zero { break }
          if instruction.prefixes.repeatPrefix == 0xF2, zero { break }
        }
      } else {
        remaining = 0
      }
      if repeated, remaining != 0, completed == iterationBudget { return false }
    }
    return true
  }

  private func forwardRangesDoNotOverlap(
    source: UInt64,
    destination: UInt64,
    byteCount: UInt64
  ) -> Bool {
    guard byteCount > 0 else { return true }
    let sourceEnd = source.addingReportingOverflow(byteCount)
    let destinationEnd = destination.addingReportingOverflow(byteCount)
    guard !sourceEnd.overflow, !destinationEnd.overflow else { return false }
    return sourceEnd.partialValue <= destination || destinationEnd.partialValue <= source
  }

  private func stringMemoryOperand(
    source: Bool,
    width: DoryX86OperandWidth,
    addressWidth: DoryX86OperandWidth,
    instruction: DoryX86DecodedInstruction,
    mode: DoryX86ExecutionMode
  ) -> DoryX86MemoryOperand {
    let segment: DoryX86SegmentRegister =
      if source {
        switch instruction.prefixes.segmentOverride {
        case 0x2E: .cs
        case 0x36: .ss
        case 0x26: .es
        case 0x64: .fs
        case 0x65: .gs
        default: .ds
        }
      } else {
        .es
      }
    return .init(
      base: source ? .rsi : .rdi,
      width: width,
      addressWidth: addressWidth,
      segment: segment,
      ignoresLegacySegmentBase: mode == .long64
    )
  }

  private func stringAddressWidth(
    mode: DoryX86ExecutionMode,
    instruction: DoryX86DecodedInstruction
  ) -> DoryX86OperandWidth {
    switch (mode, instruction.prefixes.addressSizeOverride) {
    case (.real16, false), (.protected16, false), (.protected32, true): .word
    case (.real16, true), (.protected16, true), (.protected32, false), (.long64, true):
      .doubleword
    case (.long64, false): .quadword
    }
  }

  private func stringSourceAddress(
    addressWidth: DoryX86OperandWidth,
    instruction: DoryX86DecodedInstruction,
    mode: DoryX86ExecutionMode,
    state: DoryX86ArchitecturalState
  ) -> UInt64 {
    let segment =
      switch instruction.prefixes.segmentOverride {
      case 0x2E: state.cs
      case 0x36: state.ss
      case 0x26: state.es
      case 0x64: state.fs
      case 0x65: state.gs
      default: state.ds
      }
    let base: UInt64
    if mode == .long64,
      instruction.prefixes.segmentOverride != 0x64,
      instruction.prefixes.segmentOverride != 0x65
    {
      base = 0
    } else {
      base = segment.base
    }
    return base &+ stringRegister(.rsi, width: addressWidth, state: state)
  }

  private func stringDestinationAddress(
    addressWidth: DoryX86OperandWidth,
    mode: DoryX86ExecutionMode,
    state: DoryX86ArchitecturalState
  ) -> UInt64 {
    (mode == .long64 ? 0 : state.es.base)
      &+ stringRegister(.rdi, width: addressWidth, state: state)
  }

  private func stringRegister(
    _ register: DoryX86GeneralRegister,
    width: DoryX86OperandWidth,
    state: DoryX86ArchitecturalState
  ) -> UInt64 {
    state.registers[register] & mask(width)
  }

  private func writeStringRegister(
    _ register: DoryX86GeneralRegister,
    value: UInt64,
    width: DoryX86OperandWidth,
    state: inout DoryX86ArchitecturalState
  ) {
    switch width {
    case .byte:
      state.registers[register] = (state.registers[register] & ~UInt64(0xff)) | (value & 0xff)
    case .word:
      state.registers[register] =
        (state.registers[register] & ~UInt64(0xffff)) | (value & 0xffff)
    case .doubleword:
      state.registers[register] = value & 0xffff_ffff
    case .quadword:
      state.registers[register] = value
    }
  }

  private func advanceStringRegister(
    _ register: DoryX86GeneralRegister,
    by delta: UInt64,
    decrement: Bool,
    width: DoryX86OperandWidth,
    state: inout DoryX86ArchitecturalState
  ) {
    let current = stringRegister(register, width: width, state: state)
    let next = decrement ? current &- delta : current &+ delta
    writeStringRegister(register, value: next & mask(width), width: width, state: &state)
  }

  private func validateCompareExchangeMemory(
    _ operand: DoryX86MemoryOperand, byteCount: Int,
    instruction: DoryX86DecodedInstruction, state: DoryX86ArchitecturalState
  ) throws {
    // Explicit RMW operands must fault before invoking the backing memory for
    // noncanonical spans or unusable cached legacy data/stack segments.
    if !operand.ignoresLegacySegmentBase, state.control.cr0 & 1 != 0,
      !state.rflags.contains(.virtual8086)
    {
      let segment = segmentState(operand.segment, state: state)
      guard segment.selector & ~UInt16(3) != 0, segment.attributes & 0x90 == 0x90 else {
        throw operand.segment == .ss ? stackProtection(at: instruction.address)
          : segmentProtection(at: instruction.address)
      }
    }
    try validateFloatingPointTransfer(operand, byteCount: byteCount, write: true,
      instruction: instruction, state: state)
  }

  private func executeCompareExchangePair(
    destination: DoryX86MemoryOperand,
    doubleQuadword: Bool,
    instruction: DoryX86DecodedInstruction,
    state: inout DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws {
    let byteCount = doubleQuadword ? 16 : 8
    let address = effectiveAddress(destination, instruction: instruction, state: state)
    try validateCompareExchangeMemory(destination, byteCount: byteCount,
      instruction: instruction, state: state)
    if doubleQuadword, address & 0xf != 0 {
      throw DoryX86Exception(
        kind: .generalProtection,
        vector: 13,
        errorCode: 0,
        instructionPointer: state.rip,
        linearAddress: address
      )
    }
    try memory.validateWrite(at: address, byteCount: byteCount)
    let bytes = try memory.read(at: address, byteCount: byteCount)
    let firstQuadword = fromLittleEndian(Array(bytes[0..<8]))
    let memoryLow = doubleQuadword ? firstQuadword : firstQuadword & 0xffff_ffff
    let memoryHigh =
      doubleQuadword ? fromLittleEndian(Array(bytes[8..<16])) : firstQuadword >> 32
    let expectedLow =
      doubleQuadword ? state.registers.rax : UInt64(UInt32(truncatingIfNeeded: state.registers.rax))
    let expectedHigh =
      doubleQuadword ? state.registers.rdx : UInt64(UInt32(truncatingIfNeeded: state.registers.rdx))
    let equal = memoryLow == expectedLow && memoryHigh == expectedHigh
    setFlag(.zero, equal, in: &state.rflags)
    if equal {
      let replacement: [UInt8]
      if doubleQuadword {
        replacement =
          littleEndian(state.registers.rbx, width: .quadword)
          + littleEndian(state.registers.rcx, width: .quadword)
      } else {
        let value =
          UInt64(UInt32(truncatingIfNeeded: state.registers.rbx))
          | UInt64(UInt32(truncatingIfNeeded: state.registers.rcx)) << 32
        replacement = littleEndian(value, width: .quadword)
      }
      try memory.write(at: address, bytes: replacement)
    } else {
      // SDM CMPXCHG8B/16B writes the original destination on a failed compare.
      try memory.write(at: address, bytes: bytes)
      state.registers.rax = memoryLow
      state.registers.rdx = memoryHigh
    }
  }

  private func effectiveAddress(
    _ operand: DoryX86MemoryOperand,
    instruction: DoryX86DecodedInstruction,
    state: DoryX86ArchitecturalState
  ) -> UInt64 {
    let offset = effectiveOffset(operand, instruction: instruction, state: state)
    let segmentBase: UInt64
    if operand.ignoresLegacySegmentBase,
      operand.segment != .fs,
      operand.segment != .gs
    {
      segmentBase = 0
    } else {
      segmentBase = segmentState(operand.segment, state: state).base
    }
    return segmentBase &+ offset
  }

  private func effectiveOffset(
    _ operand: DoryX86MemoryOperand,
    instruction: DoryX86DecodedInstruction,
    state: DoryX86ArchitecturalState
  ) -> UInt64 {
    var offset = operand.ripRelative ? instruction.nextInstructionAddress : 0
    if let base = operand.base { offset &+= state.registers[base] }
    if let index = operand.index { offset &+= state.registers[index] &* UInt64(operand.scale) }
    offset &+= UInt64(bitPattern: operand.displacement)
    return offset & mask(operand.addressWidth)
  }

  private func segmentState(
    _ register: DoryX86SegmentRegister,
    state: DoryX86ArchitecturalState
  ) -> DoryX86SegmentState {
    switch register {
    case .cs: state.cs
    case .ds: state.ds
    case .es: state.es
    case .fs: state.fs
    case .gs: state.gs
    case .ss: state.ss
    }
  }

  private func setSegment(
    _ register: DoryX86SegmentRegister,
    value: DoryX86SegmentState,
    state: inout DoryX86ArchitecturalState
  ) {
    switch register {
    case .cs: state.cs = value
    case .ds: state.ds = value
    case .es: state.es = value
    case .fs: state.fs = value
    case .gs: state.gs = value
    case .ss: state.ss = value
    }
  }

  private func loadSegment(
    _ register: DoryX86SegmentRegister,
    selector: UInt16,
    mode: DoryX86ExecutionMode,
    state: DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws -> DoryX86SegmentState? {
    if mode == .real16 {
      return .init(selector: selector, attributes: 0x93, limit: 0xffff, base: UInt64(selector) << 4)
    }
    if selector & 0xfffc == 0 {
      if register == .ss {
        let current = currentPrivilegeLevel(state, mode: mode)
        let requested = UInt8(selector & 3)
        // Intel permits a null SS selector only in 64-bit mode when CPL is below 3 and its
        // RPL equals CPL. Linux uses MOV SS, 0 while establishing each 64-bit CPU.
        guard mode == .long64, current < 3, current == requested else { return nil }
        return .init(selector: selector)
      }
      return register == .cs ? nil : .init(selector: selector)
    }
    let usesLDT = selector & 4 != 0
    let tableBase = usesLDT ? state.ldtr.base : state.gdtr.base
    let tableLimit = usesLDT ? UInt64(state.ldtr.limit) : UInt64(state.gdtr.limit)
    let offset = UInt64(selector >> 3) * 8
    guard offset + 7 <= tableLimit else { return nil }
    let bytes = try memory.read(at: tableBase &+ offset, byteCount: 8)
    let raw = bytes.enumerated().reduce(UInt64(0)) {
      $0 | UInt64($1.element) << UInt64($1.offset * 8)
    }
    let access = UInt8(truncatingIfNeeded: raw >> 40)
    let type = access & 0x0f
    guard access & 0x80 != 0, access & 0x10 != 0 else { return nil }
    let executable = type & 8 != 0
    guard register == .cs ? executable : (!executable || type & 2 != 0) else { return nil }
    let privilege = UInt8((access >> 5) & 3)
    let current = currentPrivilegeLevel(state, mode: mode)
    guard register == .cs ? privilege == current : max(current, UInt8(selector & 3)) <= privilege
    else { return nil }
    var base = (raw >> 16) & 0xffff
    base |= ((raw >> 32) & 0xff) << 16
    base |= ((raw >> 56) & 0xff) << 24
    var limit = UInt32(raw & 0xffff) | UInt32((raw >> 48) & 0x0f) << 16
    if raw & (1 << 55) != 0 { limit = (limit << 12) | 0xfff }
    let attributes = UInt16(access) | UInt16((raw >> 48) & 0xf0) << 8
    return .init(selector: selector, attributes: attributes, limit: limit, base: base)
  }

  private struct InspectedDescriptor {
    let raw: UInt64
  }

  private func descriptorForInspection(
    selector: UInt16,
    accessRights: Bool,
    mode: DoryX86ExecutionMode,
    state: DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws -> InspectedDescriptor? {
    guard selector & 0xfffc != 0 else { return nil }

    let usesLDT = selector & 4 != 0
    if usesLDT, state.ldtr.selector & 0xfffc == 0 { return nil }
    let tableBase = usesLDT ? state.ldtr.base : state.gdtr.base
    let tableLimit = usesLDT ? UInt64(state.ldtr.limit) : UInt64(state.gdtr.limit)
    let offset = UInt64(selector >> 3) * 8
    guard offset + 7 <= tableLimit else { return nil }

    let bytes = try memory.read(at: tableBase &+ offset, byteCount: 8)
    let raw = bytes.enumerated().reduce(UInt64(0)) {
      $0 | UInt64($1.element) << UInt64($1.offset * 8)
    }
    let access = UInt8(truncatingIfNeeded: raw >> 40)
    let type = access & 0x0f
    let codeOrData = access & 0x10 != 0
    let validType: Bool
    if codeOrData {
      validType = true
    } else if accessRights {
      validType =
        mode == .long64
        ? [2, 9, 11, 12].contains(type)
        : [1, 2, 3, 4, 5, 9, 11, 12].contains(type)
    } else {
      validType =
        mode == .long64
        ? [2, 9, 11].contains(type)
        : [1, 2, 3, 9, 11].contains(type)
    }
    guard validType else { return nil }

    let conformingCode = codeOrData && type & 0x0c == 0x0c
    if !conformingCode {
      let dpl = (access >> 5) & 3
      let cpl = currentPrivilegeLevel(state, mode: mode)
      let rpl = UInt8(selector & 3)
      guard cpl <= dpl, rpl <= dpl else { return nil }
    }
    return .init(raw: raw)
  }

  private func loadSystemSegment(
    task: Bool,
    selector: UInt16,
    mode: DoryX86ExecutionMode,
    state: DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws -> DoryX86SegmentState {
    let selectorError = UInt32(selector & 0xFFFC)
    func fault(notPresent: Bool = false, errorCode: UInt32? = nil) -> DoryX86Exception {
      .init(kind: notPresent ? .segmentNotPresent : .generalProtection,
        vector: notPresent ? 11 : 13, errorCode: errorCode ?? selectorError,
        instructionPointer: state.rip)
    }
    if selector & 0xfffc == 0 {
      if task { throw fault(errorCode: 0) }
      return .init(selector: selector)
    }
    guard selector & 4 == 0 else { throw fault() }
    let offset = UInt64(selector >> 3) * 8
    // System descriptors are 16 bytes throughout IA-32e, including compatibility mode.
    let ia32e = mode == .long64 || state.control.efer & (1 << 10) != 0
    let descriptorBytes = ia32e ? 16 : 8
    guard offset + UInt64(descriptorBytes - 1) <= UInt64(state.gdtr.limit) else { throw fault() }
    let address = state.gdtr.base.addingReportingOverflow(offset)
    let lastAddress = address.partialValue.addingReportingOverflow(UInt64(descriptorBytes - 1))
    // Vol. 3A #GP error-code rules: a fault while loading a descriptor names its
    // selector. Check the complete implicit table access before touching memory.
    guard !address.overflow, !lastAddress.overflow else { throw fault() }
    if ia32e {
      guard DoryX86ArchitecturalState.isCanonical(address.partialValue),
        DoryX86ArchitecturalState.isCanonical(lastAddress.partialValue)
      else { throw fault() }
    }
    let bytes = try memory.read(at: address.partialValue, byteCount: descriptorBytes)
    guard bytes.count == descriptorBytes else {
      throw DoryX86MemoryError.unmapped(address: address.partialValue,
        byteCount: descriptorBytes, access: .read)
    }
    let raw = bytes.prefix(8).enumerated().reduce(UInt64(0)) {
      $0 | UInt64($1.element) << UInt64($1.offset * 8)
    }
    let access = UInt8(truncatingIfNeeded: raw >> 40)
    let type = access & 0x0f
    guard access & 0x10 == 0 else { throw fault() }
    if task {
      guard type == 9 || (!ia32e && type == 1) else { throw fault() }
    } else {
      guard type == 2 else { throw fault() }
    }
    if ia32e {
      // Intel SDM Vol. 3A Fig. 10-4: the upper slot's type/S field must be zero.
      // Other upper-slot fields labeled reserved have no added fault policy here.
      guard bytes[13] & 0x1F == 0 else { throw fault() }
    }
    guard access & 0x80 != 0 else { throw fault(notPresent: true) }
    var base = (raw >> 16) & 0xffff
    base |= ((raw >> 32) & 0xff) << 16
    base |= ((raw >> 56) & 0xff) << 24
    if ia32e {
      base |= UInt64(bytes[8]) << 32
      base |= UInt64(bytes[9]) << 40
      base |= UInt64(bytes[10]) << 48
      base |= UInt64(bytes[11]) << 56
      // SDM Vol. 3A §4.5.3: LLDT/LTR reject a noncanonical loaded base.
      // Validate before LTR marks the descriptor busy or publishes TR/LDTR.
      guard DoryX86ArchitecturalState.isCanonical(base) else { throw fault() }
    }
    var limit = UInt32(raw & 0xffff) | UInt32((raw >> 48) & 0x0f) << 16
    if raw & (1 << 55) != 0 { limit = (limit << 12) | 0xfff }
    var attributes = UInt16(access) | UInt16((raw >> 48) & 0xf0) << 8
    if task {
      let busyAccess = access | 2
      try memory.validateWrite(at: address.partialValue &+ 5, byteCount: 1)
      try memory.write(at: address.partialValue &+ 5, bytes: [busyAccess])
      attributes = (attributes & 0xff00) | UInt16(busyAccess)
    }
    return .init(selector: selector, attributes: attributes, limit: limit, base: base)
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
    let maskedCount = Int(rawCount & countMask)
    var count = maskedCount
    let widthMask = mask(width)
    var result = value & widthMask
    guard count != 0 else { return result }

    switch operation {
    case .rotateLeft:
      count %= bitCount
      // ROL/ROR update CF for a nonzero masked count even when a full
      // byte/word rotation leaves the destination unchanged (SDM Vol. 2B).
      if count != 0 {
        result = ((result << count) | (result >> (bitCount - count))) & widthMask
      }
      setFlag(.carry, result & 1 != 0, in: &flags)
      if maskedCount == 1 {
        setFlag(
          .overflow,
          (result & signBit(width) != 0) != flags.contains(.carry),
          in: &flags
        )
      }
    case .rotateRight:
      count %= bitCount
      if count != 0 {
        result = ((result >> count) | (result << (bitCount - count))) & widthMask
      }
      setFlag(.carry, result & signBit(width) != 0, in: &flags)
      if maskedCount == 1 {
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
      if maskedCount == 1 {
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
      if maskedCount == 1 {
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

  private func executeDoubleShift(
    _ operation: DoryX86DoubleShiftOperation,
    destination: UInt64,
    source: UInt64,
    count rawCount: UInt8,
    width: DoryX86OperandWidth,
    flags: inout DoryX86RFLAGS
  ) -> UInt64 {
    let bitCount = Int(width.rawValue)
    let countMask: UInt8 = width == .quadword ? 0x3f : 0x1f
    let count = Int(rawCount & countMask)
    let widthMask = mask(width)
    let original = destination & widthMask
    let shiftedIn = source & widthMask
    guard count != 0 else { return original }

    // Counts greater than the operand width are architecturally undefined for the
    // 16-bit form. Keep that case deterministic without performing an invalid host shift.
    guard count <= bitCount else {
      flags.remove(.carry)
      let result: UInt64 = 0
      setShiftResultFlags(result, width: width, flags: &flags)
      return result
    }

    let result: UInt64
    switch operation {
    case .left:
      setFlag(
        .carry,
        original & (UInt64(1) << UInt64(bitCount - count)) != 0,
        in: &flags
      )
      result = ((original << count) | (shiftedIn >> (bitCount - count))) & widthMask
      if count == 1 {
        setFlag(
          .overflow,
          (result & signBit(width) != 0) != flags.contains(.carry),
          in: &flags
        )
      }
    case .right:
      setFlag(
        .carry,
        original & (UInt64(1) << UInt64(count - 1)) != 0,
        in: &flags
      )
      result = (original >> count) | ((shiftedIn << (bitCount - count)) & widthMask)
      if count == 1 {
        setFlag(
          .overflow,
          (original & signBit(width) != 0) != (result & signBit(width) != 0),
          in: &flags
        )
      }
    }
    setShiftResultFlags(result, width: width, flags: &flags)
    return result
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
      let value = UInt64(bitPattern: Int64(Int8(bitPattern: UInt8(truncatingIfNeeded: state.registers.rax))))
      state.registers.rax = (state.registers.rax & ~UInt64(0xffff)) | (value & 0xffff)
    case .doubleword:
      state.registers.rax = UInt64(
        UInt32(bitPattern: Int32(Int16(bitPattern: UInt16(truncatingIfNeeded: state.registers.rax)))))
    case .quadword:
      state.registers.rax = UInt64(
        bitPattern: Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: state.registers.rax))))
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
    case .protected16: .word
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

  /// Evaluate an SSE scalar comparison predicate for CMPSS/CMPSD.
  private func evaluateScalarCompare(
    _ predicate: DoryX86ScalarComparePredicate, a: Double, b: Double
  ) -> Bool {
    let unordered = a.isNaN || b.isNaN
    switch predicate {
    case .equal: return !unordered && a == b
    case .lessThan: return !unordered && a < b
    case .lessEqual: return !unordered && a <= b
    case .unordered: return unordered
    case .notEqual: return unordered || a != b
    case .notLessThan: return unordered || a >= b
    case .notLessEqual: return unordered || a > b
    case .ordered: return !unordered
    }
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

private final class DoryX86AtomicGate: @unchecked Sendable {
  static let shared = DoryX86AtomicGate()
  private let lock = NSLock()

  private init() {}

  func withLock<State, Result>(
    state: inout State,
    _ operation: (inout State) throws -> Result
  ) rethrows -> Result {
    lock.lock()
    defer { lock.unlock() }
    return try operation(&state)
  }
}

private struct DoryX86PartialMemoryFault: Error {
  let error: DoryX86MemoryError
}

private struct DoryX86PartialGeneralProtection: Error {}

private struct DoryX86PartialException: Error {
  let exception: DoryX86Exception
}
