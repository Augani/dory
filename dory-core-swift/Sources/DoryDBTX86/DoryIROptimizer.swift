import Foundation

public struct DoryIROptimizationMetrics: Codable, Sendable, Hashable {
  public let eliminatedStatements: UInt32
  public let propagatedConstants: UInt32

  public init(eliminatedStatements: UInt32, propagatedConstants: UInt32) {
    self.eliminatedStatements = eliminatedStatements
    self.propagatedConstants = propagatedConstants
  }
}

public struct DoryIROptimizationResult: Codable, Sendable, Hashable {
  public let block: DoryIRBasicBlock
  public let metrics: DoryIROptimizationMetrics

  public init(block: DoryIRBasicBlock, metrics: DoryIROptimizationMetrics) {
    self.block = block
    self.metrics = metrics
  }
}

/// A deliberately local optimizer. It never moves a statement across an architectural
/// instruction boundary, a memory access, or a helper, so precise faults and replay boundaries
/// remain identical to the interpreter while register constants avoid redundant host loads.
public struct DoryIROptimizer: Sendable {
  private struct RegisterIdentity: Hashable {
    let bank: String
    let index: UInt16
  }

  public init() {}

  public func optimize(_ block: DoryIRBasicBlock) -> DoryIROptimizationResult {
    var knownConstants: [RegisterIdentity: UInt64] = [:]
    var statements: [DoryIRStatement] = []
    statements.reserveCapacity(block.statements.count)
    var eliminated: UInt32 = 0
    var propagated: UInt32 = 0

    for statement in block.statements {
      switch statement {
      case .copy(let destination, let source):
        let optimizedSource = substitute(source, knownConstants: knownConstants)
        if optimizedSource != source { propagated &+= 1 }
        if case .register(let target) = destination,
          case .register(let origin) = optimizedSource,
          target == origin,
          target.width == .i64
        {
          eliminated &+= 1
          continue
        }
        statements.append(.copy(destination: destination, source: optimizedSource))
        updateKnownConstant(
          writtenOperand: destination,
          source: optimizedSource,
          knownConstants: &knownConstants
        )

      case .binary(let operation, let destination, let source, let writesDestination):
        let optimizedSource = substitute(source, knownConstants: knownConstants)
        if optimizedSource != source { propagated &+= 1 }
        statements.append(
          .binary(
            operation,
            destination: destination,
            source: optimizedSource,
            writesDestination: writesDestination
          )
        )
        if writesDestination { invalidate(destination, knownConstants: &knownConstants) }

      case .unary(_, let operand):
        statements.append(statement)
        invalidate(operand, knownConstants: &knownConstants)

      case .shift(_, let destination, _):
        statements.append(statement)
        invalidate(destination, knownConstants: &knownConstants)

      case .conditionalMove(_, let destination, _):
        statements.append(statement)
        invalidate(destination, knownConstants: &knownConstants)

      case .setCondition(_, let destination):
        statements.append(statement)
        invalidate(destination, knownConstants: &knownConstants)

      case .bitScan(_, let destination, _):
        statements.append(statement)
        invalidate(destination, knownConstants: &knownConstants)

      case .byteSwap(let operand):
        statements.append(statement)
        invalidate(operand, knownConstants: &knownConstants)

      case .stackPush, .stackPushFlags:
        statements.append(statement)
        invalidateStackPointer(knownConstants: &knownConstants)

      case .stackPop(let destination):
        statements.append(statement)
        invalidate(destination, knownConstants: &knownConstants)
        invalidateStackPointer(knownConstants: &knownConstants)

      case .signedMultiply(let destination, _, _):
        statements.append(statement)
        invalidate(destination, knownConstants: &knownConstants)

      case .unsignedAccumulatorMultiply, .unsignedAccumulatorDivide:
        statements.append(statement)
        invalidate(.register(.init(bank: "x86.gpr", index: 0, width: .i64)), knownConstants: &knownConstants)
        invalidate(.register(.init(bank: "x86.gpr", index: 2, width: .i64)), knownConstants: &knownConstants)

      case .doubleShiftRightCL(let destination, _):
        statements.append(statement)
        invalidate(destination, knownConstants: &knownConstants)

      case .extendMove(let destination, _, _):
        statements.append(statement)
        invalidate(destination, knownConstants: &knownConstants)

      case .effectiveAddress(let destination, _):
        statements.append(statement)
        invalidate(destination, knownConstants: &knownConstants)

      case .clearInterruptFlag, .setDirectionFlag:
        statements.append(statement)

      case .bitTestRegister(let operation, let base, _):
        statements.append(statement)
        if operation != .test {
          invalidate(base, knownConstants: &knownConstants)
        }

      case .readTimestampCounter:
        statements.append(statement)
        invalidate(.register(.init(bank: "x86.gpr", index: 0, width: .i64)), knownConstants: &knownConstants)
        invalidate(.register(.init(bank: "x86.gpr", index: 2, width: .i64)), knownConstants: &knownConstants)

      case .compareExchange:
        statements.append(statement)
        knownConstants.removeAll(keepingCapacity: true)

      case .helper:
        statements.append(statement)
        knownConstants.removeAll(keepingCapacity: true)
      }
    }

    return .init(
      block: .init(
        guestStart: block.guestStart,
        guestByteCount: block.guestByteCount,
        guestInstructionCount: block.guestInstructionCount,
        statements: statements,
        terminator: block.terminator
      ),
      metrics: .init(
        eliminatedStatements: eliminated,
        propagatedConstants: propagated
      )
    )
  }

  private func substitute(
    _ operand: DoryIROperand,
    knownConstants: [RegisterIdentity: UInt64]
  ) -> DoryIROperand {
    guard case .register(let register) = operand,
      let value = knownConstants[.init(bank: register.bank, index: register.index)]
    else { return operand }
    return .immediate(mask(value, to: register.width), width: register.width)
  }

  private func updateKnownConstant(
    writtenOperand: DoryIROperand,
    source: DoryIROperand,
    knownConstants: inout [RegisterIdentity: UInt64]
  ) {
    guard case .register(let target) = writtenOperand else { return }
    let identity = RegisterIdentity(bank: target.bank, index: target.index)
    guard target.bank == "x86.gpr",
      target.width == .i32 || target.width == .i64,
      case .immediate(let value, let width) = source,
      width == target.width
    else {
      knownConstants.removeValue(forKey: identity)
      return
    }
    knownConstants[identity] = mask(value, to: target.width)
  }

  private func invalidate(
    _ operand: DoryIROperand,
    knownConstants: inout [RegisterIdentity: UInt64]
  ) {
    guard case .register(let register) = operand else { return }
    knownConstants.removeValue(
      forKey: .init(bank: register.bank, index: register.index)
    )
  }

  private func invalidateStackPointer(
    knownConstants: inout [RegisterIdentity: UInt64]
  ) {
    knownConstants.removeValue(forKey: .init(bank: "x86.gpr", index: 4))
  }

  private func mask(_ value: UInt64, to width: DoryIRIntegerWidth) -> UInt64 {
    switch width {
    case .i8: value & 0xff
    case .i16: value & 0xffff
    case .i32: value & 0xffff_ffff
    case .i64: value
    }
  }
}
