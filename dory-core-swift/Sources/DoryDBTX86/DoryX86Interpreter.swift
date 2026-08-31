import Foundation

public struct DoryX86Exception: Error, Codable, Sendable, Hashable {
  public enum Kind: String, Codable, Sendable, Hashable {
    case divideError
    case invalidOpcode
    case stackSegment
    case generalProtection
    case pageFault
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
    ioBus: (any DoryX86IOBus)? = nil
  ) -> DoryX86InterpreterResult {
    var candidate = state
    let result = executeStep(
      state: &candidate,
      memory: memory,
      mode: mode,
      pagingUnit: pagingUnit,
      ioBus: ioBus
    )
    switch result {
    case .retired, .yielded, .halted:
      state = candidate
    case .exception(let exception):
      if exception.commitsPartialProgress { state = candidate }
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
    ioBus: (any DoryX86IOBus)?
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
    } catch {
      return .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: originalRIP))
    }

    do {
      var nextRIP = instruction.nextInstructionAddress & instructionPointerMask(mode)
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
      case .doubleShift(let operation, let destination, let source, let countSource):
        let destinationValue = try read(
          destination, instruction: instruction, state: state, memory: executionMemory)
        let sourceValue = try read(
          source, instruction: instruction, state: state, memory: executionMemory)
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
            try preflightWrite(
              to: destination,
              instruction: instruction,
              state: operationState,
              memory: executionMemory
            )
            try write(
              sourceValue,
              to: destination,
              instruction: instruction,
              state: &operationState,
              memory: executionMemory
            )
          } else {
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
      case .waitForCoprocessor:
        break
      case .initializeFloatingPoint:
        state.floatingPoint.x87 = .init(repeating: .x87Zero(), count: 8)
        state.floatingPoint.x87ControlWord = 0x037F
        state.floatingPoint.x87StatusWord = 0
        state.floatingPoint.x87TagWord = 0xFFFF
      case .loadX87ControlWord(let source):
        state.floatingPoint.x87ControlWord = UInt16(
          truncatingIfNeeded: try read(
            source, instruction: instruction, state: state, memory: executionMemory)
        )
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
        let result: Double =
          switch operation {
          case .add: lhs + rhs
          case .multiply: lhs * rhs
          case .subtract: lhs - rhs
          case .subtractReverse: rhs - lhs
          case .divide: lhs / rhs
          case .divideReverse: rhs / lhs
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
        let relation = floatingComparison(lhs, rhs)
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
          readX87Register(0, state: state.floatingPoint),
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
        try executionMemory.validateWrite(at: address, byteCount: 512)
        try executionMemory.write(
          at: address,
          bytes: floatingPointSaveArea(state.floatingPoint, mode: mode)
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
        let bytes = try executionMemory.read(at: address, byteCount: 512)
        guard
          let restored = try restoredFloatingPointState(
            from: bytes,
            mode: mode,
            mxcsrMask: state.floatingPoint.mxcsrMask
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
      case .emptyMMXState:
        state.floatingPoint.x87TagWord = 0xFFFF
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
      case .vectorShuffle(let format, let destination, let source, let control):
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
        let returnWidth: DoryX86OperandWidth =
          mode == .long64
          ? .quadword : (mode == .real16 || mode == .protected16 ? .word : .doubleword)
        try pushStack(
          nextRIP,
          width: returnWidth,
          instruction: instruction,
          mode: mode,
          state: &state,
          memory: executionMemory
        )
        nextRIP = addRelative(nextRIP, relative)
      case .callIndirect(let operand):
        let target = try read(
          operand, instruction: instruction, state: state, memory: executionMemory)
        let width = stackWidth(mode)
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
        let returnWidth: DoryX86OperandWidth =
          mode == .long64
          ? .quadword : (mode == .real16 || mode == .protected16 ? .word : .doubleword)
        nextRIP = try popStack(
          width: returnWidth,
          instruction: instruction,
          mode: mode,
          state: &state,
          memory: executionMemory
        )
      case .returnAndPop(let popBytes):
        let returnWidth: DoryX86OperandWidth =
          mode == .long64
          ? .quadword : (mode == .real16 || mode == .protected16 ? .word : .doubleword)
        nextRIP = try popStack(
          width: returnWidth,
          instruction: instruction,
          mode: mode,
          state: &state,
          memory: executionMemory
        )
        let adjustedStack =
          (stackPointerOffset(mode: mode, state: state) &+ UInt64(popBytes))
          & mask(stackPointerWidth(mode: mode, state: state))
        writeStackPointer(adjustedStack, mode: mode, state: &state)
      case .jump(let relative):
        nextRIP = addRelative(nextRIP, relative)
      case .jumpIndirect(let operand):
        nextRIP = try read(
          operand, instruction: instruction, state: state, memory: executionMemory)
      case .conditionalJump(let condition, let relative):
        if evaluate(condition, flags: state.rflags) { nextRIP = addRelative(nextRIP, relative) }
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
        if branches { nextRIP = addRelative(nextRIP, relative) }
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
          logicalProcessorCount: logicalProcessorCount
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
      case .readDebugRegister(let index, let destination):
        guard currentPrivilegeLevel(state) == 0 else {
          return generalProtection(at: originalRIP)
        }
        guard let value = readDebugRegister(index, state: state) else {
          return invalidOpcode(at: originalRIP)
        }
        state.registers[destination] = value
      case .writeDebugRegister(let index, let source):
        guard currentPrivilegeLevel(state) == 0 else {
          return generalProtection(at: originalRIP)
        }
        guard writeDebugRegister(index, value: state.registers[source], state: &state) else {
          return invalidOpcode(at: originalRIP)
        }
      case .readExtendedControlRegister:
        guard profile.supports(.xsave), state.control.cr4 & (1 << 18) != 0 else {
          return invalidOpcode(at: originalRIP)
        }
        guard state.registers.rcx == 0 else { return generalProtection(at: originalRIP) }
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
        guard currentPrivilegeLevel(state) == 0,
          state.registers.rcx == 0,
          value & ~supportedMask == 0,
          value & 1 == 1,
          value & 4 == 0 || value & 2 != 0
        else {
          return generalProtection(at: originalRIP)
        }
        state.control.xcr0 = value
      case .invalidateCaches:
        guard currentPrivilegeLevel(state) == 0 else {
          return generalProtection(at: originalRIP)
        }
      // The interpreter has no guest-visible data or instruction cache. Every load and store
      // already observes coherent memory, so INVD/WBINVD complete after their privilege check.
      case .invalidatePage(let operand):
        guard currentPrivilegeLevel(state) == 0 else {
          return generalProtection(at: originalRIP)
        }
        pagingUnit?.invalidate(
          linearAddress: effectiveAddress(operand, instruction: instruction, state: state)
        )
      case .descriptorTable(let table, let load, let address):
        if load, currentPrivilegeLevel(state) != 0 {
          return generalProtection(at: originalRIP)
        }
        let linearAddress = effectiveAddress(address, instruction: instruction, state: state)
        let byteCount = mode == .long64 ? 10 : 6
        if load {
          let bytes = try executionMemory.read(at: linearAddress, byteCount: byteCount)
          let limit = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
          var base: UInt64 = 0
          for index in 0..<(byteCount - 2) {
            base |= UInt64(bytes[index + 2]) << UInt64(index * 8)
          }
          if mode == .real16, !instruction.prefixes.operandSizeOverride {
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
          guard currentPrivilegeLevel(state) == 0 else {
            return generalProtection(at: originalRIP)
          }
          let requested = try read(
            operand, instruction: instruction, state: state, memory: executionMemory)
          let preservedPE = state.control.cr0 & 1
          state.control.cr0 =
            (state.control.cr0 & ~UInt64(0xF)) | (requested & 0xE) | preservedPE
            | (requested & 1)
          pagingUnit?.invalidateAll()
        } else {
          try write(
            state.control.cr0 & 0xffff,
            to: operand,
            instruction: instruction,
            state: &state,
            memory: executionMemory
          )
        }
      case .clearTaskSwitched:
        guard currentPrivilegeLevel(state) == 0 else {
          return generalProtection(at: originalRIP)
        }
        state.control.cr0 &= ~(1 << 3)
      case .storeSystemSegment(let task, let destination):
        guard state.control.cr4 & (1 << 11) == 0 || currentPrivilegeLevel(state) == 0 else {
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
        guard currentPrivilegeLevel(state) == 0 else {
          return generalProtection(at: originalRIP)
        }
        let selector = UInt16(
          truncatingIfNeeded: try read(
            source, instruction: instruction, state: state, memory: executionMemory))
        guard
          let loaded = try loadSystemSegment(
            task: task,
            selector: selector,
            mode: mode,
            state: state,
            memory: executionMemory
          )
        else { return generalProtection(at: originalRIP) }
        if task { state.tr = loaded } else { state.ldtr = loaded }
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
        if currentPrivilegeLevel(state) > UInt8((state.rflags.rawValue >> 12) & 3) {
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
      let finalMask: UInt64 =
        if mode == .protected16 || mode == .protected32, state.cs != originalCodeSegment {
          if state.cs.attributes & 0x2000 != 0 {
            0xffff_ffff
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

  private func floatingPointSaveArea(
    _ floatingPoint: DoryX86FloatingPointState,
    mode: DoryX86ExecutionMode
  ) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 512)
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
    mxcsrMask: UInt32
  ) throws -> DoryX86FloatingPointState? {
    precondition(bytes.count == 512)
    let mxcsr = UInt32(fromLittleEndian(Array(bytes[24..<28])))
    guard mxcsr & ~mxcsrMask == 0 else { return nil }
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
    var ymm = [DoryX86RegisterBytes](repeating: .ymmZero(), count: 16)
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
      mxcsrMask: mxcsrMask
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
    state.x87TagWord = 0
  }

  private func readX87(
    _ operand: DoryX87Operand,
    instruction: DoryX86DecodedInstruction,
    state: DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws -> Double {
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
        return Double(Float(bitPattern: UInt32(fromLittleEndian(bytes))))
      case .float64:
        return Double(bitPattern: fromLittleEndian(bytes))
      case .extended80:
        return decodeX87Extended(bytes)
      case .signedInteger16:
        return Double(Int16(bitPattern: UInt16(fromLittleEndian(bytes))))
      case .signedInteger32:
        return Double(Int32(bitPattern: UInt32(fromLittleEndian(bytes))))
      case .signedInteger64:
        return Double(Int64(bitPattern: fromLittleEndian(bytes)))
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
    _ value: Double,
    format: DoryX87MemoryFormat,
    truncate: Bool,
    floatingPoint: inout DoryX86FloatingPointState
  ) -> [UInt8] {
    switch format {
    case .float32:
      return Array(littleEndian(UInt64(Float(value).bitPattern), width: .doubleword))
    case .float64:
      return littleEndian(value.bitPattern, width: .quadword)
    case .extended80:
      return encodeX87Extended(value)
    case .signedInteger16, .signedInteger32, .signedInteger64:
      let bitCount: Int =
        switch format {
        case .signedInteger16: 16
        case .signedInteger32: 32
        default: 64
        }
      let rule: FloatingPointRoundingRule =
        if truncate {
          .towardZero
        } else {
          switch (floatingPoint.x87ControlWord >> 10) & 3 {
          case 0: .toNearestOrEven
          case 1: .down
          case 2: .up
          default: .towardZero
          }
        }
      let rounded = value.rounded(rule)
      let lower = -Foundation.pow(2.0, Double(bitCount - 1))
      let upper = Foundation.pow(2.0, Double(bitCount - 1))
      let invalid = !rounded.isFinite || rounded < lower || rounded >= upper
      if invalid { floatingPoint.x87StatusWord |= 1 }
      let raw: UInt64
      if invalid {
        raw = UInt64(1) << UInt64(bitCount - 1)
      } else {
        raw = UInt64(bitPattern: Int64(rounded))
      }
      return (0..<(bitCount / 8)).map {
        UInt8(truncatingIfNeeded: raw >> UInt64($0 * 8))
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

  private func readX87Register(_ logical: UInt8, state: DoryX86FloatingPointState) -> Double {
    let physical = physicalX87Register(logical, state: state)
    guard x87Tag(physical, state: state) != 3 else { return .nan }
    return decodeX87Extended(state.x87[physical].bytes)
  }

  private func writeX87Register(
    _ logical: UInt8,
    value: Double,
    state: inout DoryX86FloatingPointState
  ) {
    let physical = physicalX87Register(logical, state: state)
    state.x87[physical] = try! .init(bytes: encodeX87Extended(value), expectedByteCount: 10)
    let tag: UInt16 = value == 0 ? 1 : (value.isFinite ? 0 : 2)
    setX87Tag(physical, tag, state: &state)
  }

  private func updateX87ArithmeticStatus(
    operation: DoryX87BinaryOperation,
    lhs: Double,
    rhs: Double,
    result: Double,
    state: inout DoryX86FloatingPointState
  ) {
    if lhs.isNaN || rhs.isNaN { state.x87StatusWord |= 1 }
    let numerator: Double
    let denominator: Double
    switch operation {
    case .divide:
      (numerator, denominator) = (lhs, rhs)
    case .divideReverse:
      (numerator, denominator) = (rhs, lhs)
    default:
      return
    }
    if denominator == 0 {
      if numerator == 0 || numerator.isNaN {
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
    let x = readX87Register(0, state: state)
    switch operation {
    case .changeSign:
      writeX87Register(0, value: -x, state: &state)
    case .absolute:
      writeX87Register(0, value: abs(x), state: &state)
    case .test:
      setX87ComparisonStatus(floatingComparison(x, 0), state: &state)
    case .examine:
      state.x87StatusWord &= ~UInt16(0x4700)
      if x.sign == .minus { state.x87StatusWord |= 0x0200 }
      if x.isNaN {
        state.x87StatusWord |= 0x0100
      } else if x.isInfinite {
        state.x87StatusWord |= 0x0500
      } else if x == 0 {
        state.x87StatusWord |= 0x4000
      } else if x.isSubnormal {
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
      let y = readX87Register(1, state: state)
      writeX87Register(1, value: y * Foundation.log2(x), state: &state)
      popX87(state: &state)
    case .tangent:
      guard x87TrigonometricArgumentIsInRange(x, state: &state) else { return }
      writeX87Register(0, value: Foundation.tan(x), state: &state)
      pushX87(1, state: &state)
    case .arctangent:
      let y = readX87Register(1, state: state)
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
      let y = readX87Register(1, state: state)
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
      writeX87Register(0, value: x.rounded(x87RoundingRule(state)), state: &state)
    case .scale:
      let scale = readX87Register(1, state: state).rounded(.towardZero)
      writeX87Register(0, value: x * Foundation.pow(2, scale), state: &state)
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
    guard dividend.isFinite, divisor.isFinite, divisor != 0 else {
      state.x87StatusWord |= 1
      writeX87Register(0, value: .nan, state: &state)
      return
    }
    let quotient = (dividend / divisor).rounded(nearest ? .toNearestOrEven : .towardZero)
    writeX87Register(0, value: dividend - quotient * divisor, state: &state)
    state.x87StatusWord &= ~UInt16(0x4700)
    if quotient >= Double(Int64.min), quotient <= Double(Int64.max) {
      let bits = UInt64(bitPattern: Int64(quotient))
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
    let top = (x87Top(state) + 7) & 7
    if x87Tag(top, state: state) != 3 {
      state.x87StatusWord |= 0x0241
    } else {
      state.x87StatusWord &= ~UInt16(0x0200)
    }
    setX87Top(top, state: &state)
    state.x87[top] = try! .init(bytes: encodeX87Extended(value), expectedByteCount: 10)
    let tag: UInt16 = value == 0 ? 1 : (value.isFinite ? 0 : 2)
    setX87Tag(top, tag, state: &state)
  }

  private func popX87(state: inout DoryX86FloatingPointState) {
    let top = x87Top(state)
    setX87Tag(top, 3, state: &state)
    setX87Top((top + 1) & 7, state: &state)
  }

  private func decodeX87Extended(_ bytes: [UInt8]) -> Double {
    precondition(bytes.count == 10)
    let significand = fromLittleEndian(Array(bytes[0..<8]))
    let signAndExponent = UInt16(bytes[8]) | UInt16(bytes[9]) << 8
    let negative = signAndExponent & 0x8000 != 0
    let exponent = Int(signAndExponent & 0x7FFF)
    if exponent == 0, significand == 0 { return negative ? -0.0 : 0.0 }
    if exponent == 0x7FFF {
      if significand == 0x8000_0000_0000_0000 {
        return negative ? -.infinity : .infinity
      }
      return .nan
    }
    let unbiased = exponent == 0 ? -16_382 : exponent - 16_383
    let magnitude = Double(significand) * Foundation.pow(2.0, Double(unbiased - 63))
    return negative ? -magnitude : magnitude
  }

  private func encodeX87Extended(_ value: Double) -> [UInt8] {
    let bits = value.bitPattern
    let sign = UInt16((bits >> 63) << 15)
    let doubleExponent = Int((bits >> 52) & 0x7FF)
    let fraction = bits & 0x000F_FFFF_FFFF_FFFF
    let significand: UInt64
    let exponent: UInt16
    if doubleExponent == 0x7FF {
      exponent = 0x7FFF
      significand = fraction == 0 ? 0x8000_0000_0000_0000 : 0xC000_0000_0000_0000
    } else if doubleExponent == 0, fraction == 0 {
      exponent = 0
      significand = 0
    } else if doubleExponent == 0 {
      let highestBit = 63 - fraction.leadingZeroBitCount
      significand = fraction << UInt64(63 - highestBit)
      exponent = UInt16(highestBit - 1_074 + 16_383)
    } else {
      significand = ((UInt64(1) << 52) | fraction) << 11
      exponent = UInt16(doubleExponent - 1_023 + 16_383)
    }
    var bytes = littleEndian(significand, width: .quadword)
    let signAndExponent = sign | exponent
    bytes.append(UInt8(truncatingIfNeeded: signAndExponent))
    bytes.append(UInt8(truncatingIfNeeded: signAndExponent >> 8))
    return bytes
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
        case .equal: lhs == rhs ? laneMask : 0
        case .greaterThan: (lhs ^ signBit) > (rhs ^ signBit) ? laneMask : 0
        case .multiplyLow: (lhs &* rhs) & laneMask
        case .multiplyHighUnsigned: (lhs * rhs) >> UInt64(byteCount * 8)
        case .multiplyHighSigned:
          UInt64(
            bitPattern: signedVectorLane(lhs, bitCount: byteCount * 8)
              * signedVectorLane(rhs, bitCount: byteCount * 8))
            >> UInt64(byteCount * 8) & laneMask
        case .multiplyUnsignedDoubleword, .multiplyAddWords:
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

  private func currentPrivilegeLevel(_ state: DoryX86ArchitecturalState) -> UInt8 {
    UInt8(state.cs.selector & 3)
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
    let privilege = currentPrivilegeLevel(state)
    let ioPrivilege = UInt8((state.rflags.rawValue >> 12) & 3)
    if privilege <= ioPrivilege { return true }

    let taskType = UInt8(truncatingIfNeeded: state.tr.attributes) & 0x0f
    guard taskType == 0x9 || taskType == 0xB, state.tr.limit >= 0x67 else { return false }
    let mapBaseBytes = try memory.read(at: state.tr.base &+ 0x66, byteCount: 2)
    let mapBase = fromLittleEndian(mapBaseBytes)
    for byteOffset in 0..<width.byteCount {
      let bit = UInt32(port) + UInt32(byteOffset)
      guard bit <= UInt32(UInt16.max) else { return false }
      let bitmapOffset = mapBase + UInt64(bit / 8)
      guard bitmapOffset <= UInt64(state.tr.limit) else { return false }
      let permissions = try memory.read(at: state.tr.base &+ bitmapOffset, byteCount: 1)[0]
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
    switch normalizedDebugRegister(index, state: state) {
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
    switch normalizedDebugRegister(index, state: state) {
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
    if index == 4 || index == 5 {
      guard state.control.cr4 & (1 << 3) == 0 else { return nil }
      return index + 2
    }
    return index
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
      // CR0.ET has been architecturally fixed at one since the 486. A MOV to
      // CR0 that supplies zero for ET succeeds and reads back as one.
      let normalizedValue = value | (1 << 4)
      let paging = normalizedValue & (1 << 31) != 0
      let protectedMode = normalizedValue & 1 != 0
      let cacheDisable = normalizedValue & (1 << 30) != 0
      let notWriteThrough = normalizedValue & (1 << 29) != 0
      guard !paging || protectedMode,
        !notWriteThrough || cacheDisable
      else { return false }
      let wasPaging = state.control.cr0 & (1 << 31) != 0
      if paging, !wasPaging, state.control.efer & (1 << 8) != 0 {
        guard state.control.cr4 & (1 << 5) != 0 else { return false }
        state.control.efer |= 1 << 10
      } else if !paging {
        state.control.efer &= ~(1 << 10)
      }
      state.control.cr0 = normalizedValue
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
      var supportedMask: UInt64 =
        (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5) | (1 << 6) | (1 << 7) | (1 << 8)
        | (1 << 9) | (1 << 10) | (1 << 17) | (1 << 20) | (1 << 21)
      if profile.supports(.xsave) { supportedMask |= 1 << 18 }
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
    case 0x17: 0  // IA32_PLATFORM_ID: Dory's single virtual platform is ID zero.
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
    case .protected16: state.cs.base &+ (state.rip & 0xffff)
    case .protected32: state.cs.base &+ (state.rip & 0xffff_ffff)
    case .long64: state.rip
    }
  }

  private func instructionPointerMask(_ mode: DoryX86ExecutionMode) -> UInt64 {
    switch mode {
    case .real16: 0xffff
    case .protected16: 0xffff
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
    guard mode != .long64 else { return }
    try validateSegmentBounds(
      state.ss,
      offset: offset,
      byteCount: byteCount,
      write: write,
      protectedMode: state.control.cr0 & 1 != 0,
      fault: stackProtection(at: instruction.address)
    )
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
        if completed != 0 { throw DoryX86PartialMemoryFault(error: error) }
        throw error
      } catch {
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

  private func executeCompareExchangePair(
    destination: DoryX86MemoryOperand,
    doubleQuadword: Bool,
    instruction: DoryX86DecodedInstruction,
    state: inout DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws {
    let byteCount = doubleQuadword ? 16 : 8
    let address = effectiveAddress(destination, instruction: instruction, state: state)
    if doubleQuadword, address & 0xf != 0 {
      throw DoryX86Exception(
        kind: .generalProtection,
        vector: 13,
        errorCode: 0,
        instructionPointer: state.rip,
        linearAddress: address
      )
    }
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
      try memory.validateWrite(at: address, byteCount: byteCount)
      try memory.write(at: address, bytes: replacement)
    } else if doubleQuadword {
      state.registers.rax = memoryLow
      state.registers.rdx = memoryHigh
    } else {
      state.registers.rax = UInt64(UInt32(truncatingIfNeeded: firstQuadword))
      state.registers.rdx = UInt64(UInt32(truncatingIfNeeded: firstQuadword >> 32))
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
      return register == .ss || register == .cs ? nil : .init(selector: selector)
    }
    let table =
      selector & 4 == 0 ? state.gdtr : .init(limit: UInt16(state.ldtr.limit), base: state.ldtr.base)
    let offset = UInt64(selector >> 3) * 8
    guard offset + 7 <= UInt64(table.limit) else { return nil }
    let bytes = try memory.read(at: table.base &+ offset, byteCount: 8)
    let raw = bytes.enumerated().reduce(UInt64(0)) {
      $0 | UInt64($1.element) << UInt64($1.offset * 8)
    }
    let access = UInt8(truncatingIfNeeded: raw >> 40)
    let type = access & 0x0f
    guard access & 0x80 != 0, access & 0x10 != 0 else { return nil }
    let executable = type & 8 != 0
    guard register == .cs ? executable : (!executable || type & 2 != 0) else { return nil }
    let privilege = UInt8((access >> 5) & 3)
    let current = UInt8(state.cs.selector & 3)
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

  private func loadSystemSegment(
    task: Bool,
    selector: UInt16,
    mode: DoryX86ExecutionMode,
    state: DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws -> DoryX86SegmentState? {
    if selector & 0xfffc == 0 {
      return task ? nil : .init(selector: 0)
    }
    guard selector & 4 == 0 else { return nil }
    let offset = UInt64(selector >> 3) * 8
    let descriptorBytes = mode == .long64 ? 16 : 8
    guard offset + UInt64(descriptorBytes - 1) <= UInt64(state.gdtr.limit) else { return nil }
    let bytes = try memory.read(at: state.gdtr.base &+ offset, byteCount: descriptorBytes)
    let raw = bytes.prefix(8).enumerated().reduce(UInt64(0)) {
      $0 | UInt64($1.element) << UInt64($1.offset * 8)
    }
    let access = UInt8(truncatingIfNeeded: raw >> 40)
    let type = access & 0x0f
    guard access & 0x80 != 0, access & 0x10 == 0 else { return nil }
    if task {
      guard type == 1 || type == 9 else { return nil }
    } else {
      guard type == 2 else { return nil }
    }
    var base = (raw >> 16) & 0xffff
    base |= ((raw >> 32) & 0xff) << 16
    base |= ((raw >> 56) & 0xff) << 24
    if mode == .long64 {
      base |= UInt64(bytes[8]) << 32
      base |= UInt64(bytes[9]) << 40
      base |= UInt64(bytes[10]) << 48
      base |= UInt64(bytes[11]) << 56
    }
    var limit = UInt32(raw & 0xffff) | UInt32((raw >> 48) & 0x0f) << 16
    if raw & (1 << 55) != 0 { limit = (limit << 12) | 0xfff }
    var attributes = UInt16(access) | UInt16((raw >> 48) & 0xf0) << 8
    if task {
      let busyAccess = access | 2
      try memory.validateWrite(at: state.gdtr.base &+ offset &+ 5, byteCount: 1)
      try memory.write(at: state.gdtr.base &+ offset &+ 5, bytes: [busyAccess])
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
