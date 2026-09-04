import Foundation

public enum DoryX86InterruptSource: String, Codable, Sendable, Hashable {
  case externalMaskable
  case nonMaskable
  case hardwareException
  case software
}

public enum DoryX86InterruptDeliveryError: Error, Sendable, Equatable {
  case invalidIDTLimit(vector: UInt8)
  case invalidGate(vector: UInt8)
  case gateNotPresent(vector: UInt8)
  case privilegeViolation(vector: UInt8)
  case generalProtectionZero
  case generalProtectionExternal
  case invalidCodeSegment(selector: UInt16)
  case codeSegmentNotPresent(selector: UInt16)
  case invalidTaskState
  case invalidTaskStateSelector(UInt16)
  case stackAddress
  case stackSegment(UInt16)
  case invalidReturnFrame
  @available(*, deprecated, renamed: "processorShutdown")
  case tripleFault
  case processorShutdown
}

enum DoryX86ExceptionDeliveryClass: Sendable, Hashable {
  case benign
  case contributory
  case pageFault
  case doubleFault
}

enum DoryX86ExceptionDeliveryAction: Sendable, Hashable {
  case serial
  case doubleFault
  case processorShutdown
}

public struct DoryX86InterruptDelivery: Sendable {
  private let profile: DoryX86CPUProfile

  public init(profile: DoryX86CPUProfile = .compatibleV1) {
    self.profile = profile
  }

  public func deliver(
    vector: UInt8,
    source: DoryX86InterruptSource,
    errorCode: UInt32? = nil,
    returnInstructionPointer: UInt64? = nil,
    state: inout DoryX86ArchitecturalState,
    physicalMemory: any DoryX86Memory,
    pagingUnit: DoryX86PagingUnit? = nil,
    mode: DoryX86ExecutionMode
  ) throws {
    if source == .nonMaskable {
      // Intel SDM Vol. 3A §7.7.2: NMI blocking is established before the
      // processor commences delivery, and therefore survives a nested fault.
      // MOV/POP SS inhibition also blocks NMI recognition for the protected
      // following instruction; STI inhibition applies only to maskable events.
      guard !state.nmiBlocked, state.interruptShadow != .movSS else { return }
    }
    if source == .externalMaskable {
      guard state.interruptShadow == nil,
        state.rflags.contains(.interruptEnable), UInt64(vector >> 4) > state.control.cr8
      else {
        return
      }
    }
    // Recognition of any accepted event ends STI/MOV SS inhibition. Clear the
    // state before gate or frame access so a nested delivery fault cannot keep
    // an expired shadow alive.
    state.interruptShadow = nil
    if source == .nonMaskable { state.nmiBlocked = true }
    if mode == .real16 {
      try deliverRealMode(
        vector: vector,
        returnInstructionPointer: returnInstructionPointer,
        state: &state,
        memory: physicalMemory
      )
      return
    }
    if mode == .protected16 || mode == .protected32 {
      try deliverProtectedMode(
        vector: vector,
        source: source,
        errorCode: errorCode,
        returnInstructionPointer: returnInstructionPointer,
        state: &state,
        physicalMemory: physicalMemory,
        pagingUnit: pagingUnit,
        mode: mode
      )
      return
    }
    guard mode == .long64 else {
      throw DoryX86InterruptDeliveryError.invalidGate(vector: vector)
    }

    let original = state
    let systemMemory = translatedMemory(
      physicalMemory: physicalMemory,
      pagingUnit: pagingUnit,
      state: state,
      mode: mode,
      cpl: 0,
      isImplicitSupervisorAccess: true
    )
    let gate = try readGate(vector: vector, state: state, memory: systemMemory)
    let currentCPL = UInt8(state.cs.selector & 3)
    if source == .software, currentCPL > gate.descriptorPrivilegeLevel {
      throw DoryX86InterruptDeliveryError.privilegeViolation(vector: vector)
    }
    let code = try readCodeSegment(
      selector: gate.selector,
      state: state,
      memory: systemMemory
    )
    let targetCPL = code.descriptorPrivilegeLevel
    guard targetCPL <= currentCPL else {
      throw DoryX86InterruptDeliveryError.invalidCodeSegment(selector: gate.selector)
    }
    guard DoryX86ArchitecturalState.isCanonical(gate.offset) else {
      throw DoryX86InterruptDeliveryError.generalProtectionExternal
    }

    let switchesPrivilege = targetCPL < currentCPL
    let usesIST = gate.interruptStackTable != 0
    let targetStack: UInt64
    if usesIST {
      targetStack = try readTaskStack(
        offset: 36 + (Int(gate.interruptStackTable) - 1) * 8,
        state: state,
        memory: systemMemory
      )
    } else if switchesPrivilege {
      targetStack = try readTaskStack(
        offset: 4 + Int(targetCPL) * 8,
        state: state,
        memory: systemMemory
      )
    } else {
      targetStack = state.registers.rsp
    }
    guard DoryX86ArchitecturalState.isCanonical(targetStack) else {
      throw DoryX86InterruptDeliveryError.stackAddress
    }

    var targetState = state
    targetState.cs.selector = (gate.selector & 0xfffc) | UInt16(targetCPL)
    let stackMemory = translatedMemory(
      physicalMemory: physicalMemory,
      pagingUnit: pagingUnit,
      state: targetState,
      mode: mode,
      cpl: targetCPL
    )
    let alignedTargetStack = targetStack & ~0xF
    var stack = alignedTargetStack
    var frame: [UInt64] = []
    frame.append(UInt64(original.ss.selector))
    frame.append(original.registers.rsp)
    frame.append(original.rflags.rawValue)
    frame.append(UInt64(original.cs.selector))
    frame.append(returnInstructionPointer ?? original.rip)
    if let errorCode { frame.append(UInt64(errorCode)) }

    let addresses = frame.indices.map { alignedTargetStack &- UInt64(($0 + 1) * 8) }
    for address in addresses {
      try stackMemory.validateWrite(at: address, byteCount: 8)
    }
    for value in frame {
      stack &-= 8
      try stackMemory.write(at: stack, bytes: littleEndian(value))
    }

    state.registers.rsp = stack
    state.rip = gate.offset
    state.cs = code.segment
    state.cs.selector = (gate.selector & 0xfffc) | UInt16(targetCPL)
    if switchesPrivilege {
      state.ss = .init(
        selector: UInt16(targetCPL),
        attributes: 0xC093,
        limit: .max,
        base: 0
      )
    }
    state.rflags.remove([.trap, .nestedTask, .resume])
    if gate.isInterruptGate { state.rflags.remove(.interruptEnable) }
  }

  public func deliverException(
    _ exception: DoryX86Exception,
    state: inout DoryX86ArchitecturalState,
    physicalMemory: any DoryX86Memory,
    pagingUnit: DoryX86PagingUnit? = nil,
    mode: DoryX86ExecutionMode
  ) throws {
    var pending = exception
    if pending.kind == .pageFault, let address = pending.linearAddress {
      state.control.cr2 = address
    }
    while true {
      do {
        try deliver(
          vector: pending.vector,
          source: .hardwareException,
          errorCode: pending.errorCode,
          returnInstructionPointer: pending.instructionPointer,
          state: &state,
          physicalMemory: physicalMemory,
          pagingUnit: pagingUnit,
          mode: mode
        )
        return
      } catch {
        guard let nested = architecturalException(
          from: error,
          source: .hardwareException,
          instructionPointer: pending.instructionPointer,
          state: state
        ) else {
          throw error
        }
        if nested.kind == .pageFault, let address = nested.linearAddress {
          // Intel SDM Vol. 3A, Event 14: a page fault detected while
          // delivering another event updates CR2 even if it becomes #DF or
          // occurs while #DF itself is being delivered.
          state.control.cr2 = address
        }
        switch Self.exceptionDeliveryAction(
          firstVector: pending.vector,
          secondVector: nested.vector
        ) {
        case .serial:
          pending = nested
        case .doubleFault:
          // The saved CS:RIP for #DF are architecturally undefined. Keep the
          // original restart address as a deterministic diagnostic choice;
          // callers and tests must not treat it as resumable state.
          pending = .init(
            kind: .doubleFault,
            vector: 8,
            errorCode: 0,
            instructionPointer: pending.instructionPointer
          )
        case .processorShutdown:
          throw DoryX86InterruptDeliveryError.processorShutdown
        }
      }
    }
  }

  /// Delivers an accepted interrupt/NMI and handles a fault encountered while
  /// entering it as a serial nested exception. INTR and NMI are benign first
  /// events in Intel SDM Vol. 3A Table 7-4, so the nested exception itself is
  /// the first exception considered by the double-fault state machine.
  public func deliverEvent(
    vector: UInt8,
    source: DoryX86InterruptSource,
    state: inout DoryX86ArchitecturalState,
    physicalMemory: any DoryX86Memory,
    pagingUnit: DoryX86PagingUnit? = nil,
    mode: DoryX86ExecutionMode
  ) throws {
    do {
      try deliver(
        vector: vector,
        source: source,
        state: &state,
        physicalMemory: physicalMemory,
        pagingUnit: pagingUnit,
        mode: mode
      )
    } catch {
      guard let nested = architecturalException(
        from: error,
        source: source,
        instructionPointer: state.rip,
        state: state
      ) else {
        throw error
      }
      if nested.kind == .pageFault, let address = nested.linearAddress {
        state.control.cr2 = address
      }
      try deliverException(
        nested,
        state: &state,
        physicalMemory: physicalMemory,
        pagingUnit: pagingUnit,
        mode: mode
      )
    }
  }

  static func exceptionDeliveryClass(for vector: UInt8) -> DoryX86ExceptionDeliveryClass {
    return switch vector {
    case 0, 10, 11, 12, 13, 21: .contributory
    case 14, 20: .pageFault
    case 8: .doubleFault
    default: .benign
    }
  }

  static func exceptionDeliveryAction(
    firstVector: UInt8,
    secondVector: UInt8
  ) -> DoryX86ExceptionDeliveryAction {
    let first = exceptionDeliveryClass(for: firstVector)
    let second = exceptionDeliveryClass(for: secondVector)
    return switch (first, second) {
    case (.contributory, .contributory),
      (.pageFault, .contributory),
      (.pageFault, .pageFault):
      .doubleFault
    case (.doubleFault, .contributory), (.doubleFault, .pageFault):
      .processorShutdown
    default:
      .serial
    }
  }

  private func architecturalException(
    from error: any Error,
    source: DoryX86InterruptSource,
    instructionPointer: UInt64,
    state: DoryX86ArchitecturalState
  ) -> DoryX86Exception? {
    if let exception = error as? DoryX86Exception { return exception }
    if let memory = error as? DoryX86MemoryError {
      guard case .pageFault(let address, let errorCode) = memory else { return nil }
      return .init(
        kind: .pageFault,
        vector: 14,
        errorCode: errorCode,
        instructionPointer: instructionPointer,
        linearAddress: address
      )
    }
    guard let delivery = error as? DoryX86InterruptDeliveryError else { return nil }
    switch delivery {
    case .invalidIDTLimit(let vector), .invalidGate(let vector),
      .privilegeViolation(let vector):
      return .init(
        kind: .generalProtection,
        vector: 13,
        errorCode: idtErrorCode(vector: vector, source: source),
        instructionPointer: instructionPointer
      )
    case .gateNotPresent(let vector):
      return .init(
        kind: .segmentNotPresent,
        vector: 11,
        errorCode: idtErrorCode(vector: vector, source: source),
        instructionPointer: instructionPointer
      )
    case .generalProtectionZero:
      return .init(
        kind: .generalProtection,
        vector: 13,
        errorCode: 0,
        instructionPointer: instructionPointer
      )
    case .generalProtectionExternal:
      return .init(
        kind: .generalProtection,
        vector: 13,
        errorCode: externalErrorCodeBit(source),
        instructionPointer: instructionPointer
      )
    case .invalidCodeSegment(let selector):
      return .init(
        kind: .generalProtection,
        vector: 13,
        errorCode: selectorErrorCode(selector, source: source),
        instructionPointer: instructionPointer
      )
    case .codeSegmentNotPresent(let selector):
      return .init(
        kind: .segmentNotPresent,
        vector: 11,
        errorCode: selectorErrorCode(selector, source: source),
        instructionPointer: instructionPointer
      )
    case .invalidTaskState:
      return .init(
        kind: .invalidTaskState,
        vector: 10,
        errorCode: selectorErrorCode(state.tr.selector, source: source),
        instructionPointer: instructionPointer
      )
    case .invalidTaskStateSelector(let selector):
      return .init(
        kind: .invalidTaskState,
        vector: 10,
        errorCode: selectorErrorCode(selector, source: source),
        instructionPointer: instructionPointer
      )
    case .stackSegment(let selector):
      return .init(
        kind: .stackSegment,
        vector: 12,
        errorCode: selector == 0 ? 0 : selectorErrorCode(selector, source: source),
        instructionPointer: instructionPointer
      )
    case .stackAddress:
      return .init(
        kind: .stackSegment,
        vector: 12,
        errorCode: externalErrorCodeBit(source),
        instructionPointer: instructionPointer
      )
    case .invalidReturnFrame, .tripleFault, .processorShutdown:
      return nil
    }
  }

  private func idtErrorCode(vector: UInt8, source: DoryX86InterruptSource) -> UInt32 {
    UInt32(vector) << 3 | 1 << 1 | externalErrorCodeBit(source)
  }

  private func selectorErrorCode(
    _ selector: UInt16,
    source: DoryX86InterruptSource
  ) -> UInt32 {
    UInt32(selector & 0xFFFC) | externalErrorCodeBit(source)
  }

  private func externalErrorCodeBit(_ source: DoryX86InterruptSource) -> UInt32 {
    source == .software ? 0 : 1
  }

  public func interruptReturn(
    state: inout DoryX86ArchitecturalState,
    physicalMemory: any DoryX86Memory,
    pagingUnit: DoryX86PagingUnit? = nil,
    mode: DoryX86ExecutionMode,
    operandSizeOverride: Bool = false
  ) throws {
    // Intel unblocks NMI on the attempted IRET boundary, including when frame
    // validation later faults. The interpreter preserves this one transition.
    state.nmiBlocked = false
    if mode == .real16 {
      try interruptReturnRealMode(state: &state, memory: physicalMemory,
        width: operandSizeOverride ? .doubleword : .word)
      return
    }
    if mode == .protected16 || mode == .protected32 {
      let width: DoryX86OperandWidth =
        (mode == .protected16) != operandSizeOverride ? .word : .doubleword
      try interruptReturnProtectedMode(state: &state, physicalMemory: physicalMemory,
        pagingUnit: pagingUnit, mode: mode, width: width)
      return
    }
    guard mode == .long64 else { throw DoryX86InterruptDeliveryError.invalidReturnFrame }
    let memory = translatedMemory(
      physicalMemory: physicalMemory,
      pagingUnit: pagingUnit,
      state: state,
      mode: mode,
      cpl: UInt8(state.cs.selector & 3)
    )
    let stack = state.registers.rsp
    let instructionPointer = try read64(memory, stack)
    let codeSelector = UInt16(truncatingIfNeeded: try read64(memory, stack + 8))
    let flagsValue = try read64(memory, stack + 16)
    let targetCPL = UInt8(codeSelector & 3)
    let currentCPL = UInt8(state.cs.selector & 3)
    guard targetCPL >= currentCPL,
      DoryX86ArchitecturalState.isCanonical(instructionPointer)
    else {
      throw DoryX86InterruptDeliveryError.invalidReturnFrame
    }
    let systemMemory = translatedMemory(
      physicalMemory: physicalMemory,
      pagingUnit: pagingUnit,
      state: state,
      mode: mode,
      cpl: 0,
      isImplicitSupervisorAccess: true
    )
    let code = try readCodeSegment(selector: codeSelector, state: state, memory: systemMemory)
    guard code.descriptorPrivilegeLevel == targetCPL else {
      throw DoryX86InterruptDeliveryError.invalidReturnFrame
    }
    let requestedFlags = DoryX86RFLAGS(
      rawValue: (flagsValue & DoryX86RFLAGS.architecturallyWritableMask) | 2
    )
    guard let validatedFlags = try? requestedFlags.validated() else {
      throw DoryX86InterruptDeliveryError.invalidReturnFrame
    }

    let restoredStack = try read64(memory, stack + 24)
    let stackSelector = UInt16(truncatingIfNeeded: try read64(memory, stack + 32))
    guard DoryX86ArchitecturalState.isCanonical(restoredStack),
      (stackSelector == 0 && targetCPL == 0) || stackSelector & 3 == targetCPL
    else {
      throw DoryX86InterruptDeliveryError.invalidReturnFrame
    }
    state.registers.rsp = restoredStack
    state.ss = .init(
      selector: stackSelector,
      attributes: targetCPL == 3 ? 0xC0F3 : 0xC093,
      limit: .max,
      base: 0
    )
    state.rip = instructionPointer
    state.cs = code.segment
    state.cs.selector = codeSelector
    state.rflags = validatedFlags
  }

  private struct Gate {
    let offset: UInt64
    let selector: UInt16
    let interruptStackTable: UInt8
    let descriptorPrivilegeLevel: UInt8
    let isInterruptGate: Bool
  }

  private func deliverRealMode(
    vector: UInt8,
    returnInstructionPointer: UInt64?,
    state: inout DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws {
    let gateOffset = Int(vector) * 4
    guard gateOffset + 3 <= Int(state.idtr.limit) else {
      throw DoryX86InterruptDeliveryError.invalidIDTLimit(vector: vector)
    }
    let gate = try memory.read(at: state.idtr.base &+ UInt64(gateOffset), byteCount: 4)
    let targetOffset = UInt16(gate[0]) | UInt16(gate[1]) << 8
    let targetSegment = UInt16(gate[2]) | UInt16(gate[3]) << 8

    let oldStack = UInt16(truncatingIfNeeded: state.registers.rsp)
    let flagsStack = oldStack &- 2
    let codeStack = flagsStack &- 2
    let instructionStack = codeStack &- 2
    let stackOffsets = [flagsStack, codeStack, instructionStack]
    for offset in stackOffsets {
      guard UInt32(offset) + 1 <= state.ss.limit else {
        throw DoryX86InterruptDeliveryError.stackSegment(0)
      }
      try memory.validateWrite(at: state.ss.base &+ UInt64(offset), byteCount: 2)
    }
    try memory.write(
      at: state.ss.base &+ UInt64(flagsStack),
      bytes: littleEndian16(UInt16(truncatingIfNeeded: state.rflags.rawValue))
    )
    try memory.write(
      at: state.ss.base &+ UInt64(codeStack),
      bytes: littleEndian16(state.cs.selector)
    )
    try memory.write(
      at: state.ss.base &+ UInt64(instructionStack),
      bytes: littleEndian16(
        UInt16(truncatingIfNeeded: returnInstructionPointer ?? state.rip)
      )
    )

    state.registers.rsp =
      (state.registers.rsp & ~UInt64(0xffff)) | UInt64(instructionStack)
    state.cs = .init(
      selector: targetSegment,
      attributes: 0x009B,
      limit: 0xffff,
      base: UInt64(targetSegment) << 4
    )
    state.rip = UInt64(targetOffset)
    state.rflags.remove([.interruptEnable, .trap])
  }

  private func interruptReturnRealMode(
    state: inout DoryX86ArchitecturalState,
    memory: any DoryX86Memory,
    width: DoryX86OperandWidth
  ) throws {
    // The implicit stack address comes from SS.B, independently of the IRET
    // operand width and the 67H prefix (Intel SDM Vol. 1 §6.2.3).
    let pointerWidth = state.ss.attributes & 0x4000 != 0 ? 32 : 16
    let pointerMask: UInt64 = pointerWidth == 32 ? 0xFFFF_FFFF : 0xFFFF
    let stack = state.registers.rsp & pointerMask
    let slotBytes = UInt64(width.byteCount)
    let frameBytes = 3 * slotBytes
    let frameEnd = stack &+ frameBytes &- 1
    // Check the complete frame before reading any slot: the top 6 or 12 bytes
    // must be within the stack, rather than wrapping individual slot addresses.
    guard frameEnd >= stack, frameEnd <= pointerMask, frameEnd <= UInt64(state.ss.limit) else {
      throw DoryX86Exception(kind: .stackSegment, vector: 12, errorCode: 0,
        instructionPointer: state.rip)
    }
    func readSlot(_ index: UInt64) throws -> UInt64 {
      fromLittleEndian(try memory.read(at: state.ss.base &+ stack &+ index * slotBytes,
        byteCount: width.byteCount))
    }
    let instructionPointer = try readSlot(0)
    let codeSelector = UInt16(truncatingIfNeeded: try readSlot(1))
    let flags = try readSlot(2)
    // Keep the existing ordinary real-mode CS reload contract. IRETD does not
    // truncate an out-of-range EIP to IP; it faults before publishing the frame.
    guard instructionPointer <= 0xFFFF else {
      throw DoryX86Exception(kind: .generalProtection, vector: 13, errorCode: 0,
        instructionPointer: state.rip)
    }
    // SDM Vol. 2A, IRET REAL-ADDRESS-MODE: VM/VIF/VIP survive IRETD;
    // IRET16 preserves all upper EFLAGS bits. Reserved popped bits are ignored.
    let restoredFlags: UInt64 = width == .doubleword
      ? (flags & 0x257FD5) | (state.rflags.rawValue & 0x1A0000) | 2
      : (flags & 0x7FD5) | (state.rflags.rawValue & ~UInt64(0xFFFF)) | 2

    writeProtectedStackPointer((stack &+ frameBytes) & pointerMask,
      pointerWidth: pointerWidth, state: &state)
    state.rip = instructionPointer
    state.cs = .init(
      selector: codeSelector,
      attributes: 0x009B,
      limit: 0xffff,
      base: UInt64(codeSelector) << 4
    )
    state.rflags = .init(rawValue: restoredFlags)
  }

  private struct CodeSegment {
    let segment: DoryX86SegmentState
    let descriptorPrivilegeLevel: UInt8
  }

  private struct ProtectedGate {
    let offset: UInt32
    let selector: UInt16
    let width: DoryX86OperandWidth
    let descriptorPrivilegeLevel: UInt8
    let isInterruptGate: Bool
  }

  private struct LegacySegment {
    let segment: DoryX86SegmentState
    let descriptorPrivilegeLevel: UInt8
    let type: UInt8
  }

  private func deliverProtectedMode(
    vector: UInt8,
    source: DoryX86InterruptSource,
    errorCode: UInt32?,
    returnInstructionPointer: UInt64?,
    state: inout DoryX86ArchitecturalState,
    physicalMemory: any DoryX86Memory,
    pagingUnit: DoryX86PagingUnit?,
    mode: DoryX86ExecutionMode
  ) throws {
    // Intel SDM Vol. 3A §5.6.1: IDT, segment-descriptor and TSS accesses
    // are implicit supervisor accesses, including while the interrupted CPL is 3.
    let systemMemory = translatedMemory(physicalMemory: physicalMemory,
      pagingUnit: pagingUnit, state: state, mode: mode, cpl: 0,
      isImplicitSupervisorAccess: true)
    let gate = try readProtectedGate(vector: vector, state: state, memory: systemMemory)
    let currentCPL = UInt8(state.cs.selector & 3)
    if source == .software, currentCPL > gate.descriptorPrivilegeLevel {
      throw DoryX86InterruptDeliveryError.privilegeViolation(vector: vector)
    }
    let code = try readLegacySegment(selector: gate.selector, state: state, memory: systemMemory)
    let conforming = code.type & 4 != 0
    let targetCPL = conforming ? currentCPL : code.descriptorPrivilegeLevel
    guard code.type & 8 != 0,
      code.descriptorPrivilegeLevel <= currentCPL
    else {
      throw DoryX86InterruptDeliveryError.invalidCodeSegment(selector: gate.selector)
    }
    guard UInt64(gate.offset) <= UInt64(code.segment.limit) else {
      throw DoryX86InterruptDeliveryError.generalProtectionExternal
    }

    let switchesPrivilege = targetCPL < currentCPL
    let targetStack: UInt64
    let targetStackSegment: DoryX86SegmentState
    if switchesPrivilege {
      (targetStack, targetStackSegment) = try readProtectedTaskStack(
        privilege: targetCPL,
        state: state,
        memory: systemMemory
      )
    } else {
      targetStack = state.registers.rsp
      targetStackSegment = state.ss
    }
    let pointerWidth = targetStackSegment.attributes & 0x4000 != 0 ? 32 : 16
    let pointerMask: UInt64 = pointerWidth == 32 ? 0xffff_ffff : 0xffff
    var values: [UInt64] = []
    if switchesPrivilege {
      values.append(UInt64(state.ss.selector))
      values.append(state.registers.rsp)
    }
    values.append(state.rflags.rawValue)
    values.append(UInt64(state.cs.selector))
    values.append(returnInstructionPointer ?? state.rip)
    if let errorCode { values.append(UInt64(errorCode)) }
    // The stack remains an ordinary data access. An inner-privilege stack uses
    // supervisor paging rights (§6.11.5); a same-CPL3 stack remains a user access.
    let stackMemory = translatedMemory(physicalMemory: physicalMemory,
      pagingUnit: pagingUnit, state: state, mode: mode, cpl: targetCPL)
    let finalStack = try writeProtectedFrame(
      values,
      width: gate.width,
      stack: targetStack & pointerMask,
      pointerMask: pointerMask,
      segment: targetStackSegment,
      memory: stackMemory
    )

    if switchesPrivilege { state.ss = targetStackSegment }
    writeProtectedStackPointer(finalStack, pointerWidth: pointerWidth, state: &state)
    state.cs = code.segment
    state.cs.selector = (gate.selector & 0xfffc) | UInt16(targetCPL)
    state.rip = UInt64(gate.offset)
    state.rflags.remove([.trap, .nestedTask, .resume])
    if gate.isInterruptGate { state.rflags.remove(.interruptEnable) }
  }

  private func interruptReturnProtectedMode(
    state: inout DoryX86ArchitecturalState,
    physicalMemory: any DoryX86Memory,
    pagingUnit: DoryX86PagingUnit?,
    mode: DoryX86ExecutionMode,
    width: DoryX86OperandWidth
  ) throws {
    let currentCPL = UInt8(state.cs.selector & 3)
    let memory = translatedMemory(physicalMemory: physicalMemory,
      pagingUnit: pagingUnit, state: state, mode: mode, cpl: currentCPL)
    let systemMemory = translatedMemory(physicalMemory: physicalMemory,
      pagingUnit: pagingUnit, state: state, mode: mode, cpl: 0,
      isImplicitSupervisorAccess: true)
    let pointerWidth = state.ss.attributes & 0x4000 != 0 ? 32 : 16
    let pointerMask: UInt64 = pointerWidth == 32 ? 0xffff_ffff : 0xffff
    let stack = state.registers.rsp & pointerMask
    let frameBytes = UInt64(width.byteCount)
    try validateProtectedReturnStack(stack, byteCount: 3 * width.byteCount,
      segment: state.ss, instructionPointer: state.rip)
    let stackBase = state.ss.base
    func readFrameValue(_ offset: UInt64) throws -> UInt64 {
      fromLittleEndian(try memory.read(at: stackBase &+ offset, byteCount: width.byteCount))
    }
    let instructionPointer = try readFrameValue(stack)
    let codeSelector = UInt16(truncatingIfNeeded: try readFrameValue((stack &+ frameBytes) & pointerMask))
    let flagsValue = try readFrameValue((stack &+ 2 * frameBytes) & pointerMask)
    let targetCPL = UInt8(codeSelector & 3)
    guard targetCPL >= currentCPL else {
      throw DoryX86InterruptDeliveryError.invalidReturnFrame
    }
    let code = try readLegacySegment(selector: codeSelector, state: state, memory: systemMemory)
    guard code.type & 8 != 0,
      code.descriptorPrivilegeLevel == targetCPL,
      instructionPointer <= code.segment.limit
    else {
      throw DoryX86InterruptDeliveryError.invalidReturnFrame
    }
    // Intel SDM Vol. 2A IRET: word operands preserve RF/AC/ID/VIF/VIP.
    // IF and IOPL permissions use the executing CPL and the old IOPL.
    var flagsMask: UInt64 = 0x4DD5 // CF/PF/AF/ZF/SF/TF/DF/OF/NT.
    if width == .doubleword { flagsMask |= (1 << 16) | (1 << 18) | (1 << 21) }
    let oldIOPL = UInt8((state.rflags.rawValue >> 12) & 3)
    if currentCPL <= oldIOPL { flagsMask |= 1 << 9 }
    if currentCPL == 0 {
      flagsMask |= 3 << 12
      if width == .doubleword { flagsMask |= (1 << 19) | (1 << 20) }
    }
    let requestedFlags = DoryX86RFLAGS(rawValue:
      (state.rflags.rawValue & ~flagsMask) | (flagsValue & flagsMask) | 2)
    guard let validatedFlags = try? requestedFlags.validated() else {
      throw DoryX86InterruptDeliveryError.invalidReturnFrame
    }

    if targetCPL > currentCPL {
      let outerStackAddress = (stack &+ 3 * frameBytes) & pointerMask
      try validateProtectedReturnStack(outerStackAddress,
        byteCount: 2 * width.byteCount, segment: state.ss, instructionPointer: state.rip)
      let outerStack = try readFrameValue(outerStackAddress)
      let outerSelector = UInt16(truncatingIfNeeded:
        try readFrameValue((outerStackAddress &+ frameBytes) & pointerMask))
      let stackSegment = try readLegacySegment(
        selector: outerSelector,
        state: state,
        memory: systemMemory
      )
      guard outerSelector & 3 == targetCPL,
        stackSegment.descriptorPrivilegeLevel == targetCPL,
        stackSegment.type & 8 == 0,
        stackSegment.type & 2 != 0
      else {
        throw DoryX86InterruptDeliveryError.invalidReturnFrame
      }
      state.ss = stackSegment.segment
      state.ss.selector = outerSelector
      // SDM Vol. 3B §25.31.4: a word pop zero-extends ESP when the returned
      // stack is 32-bit. Preserve the existing 16-bit-stack high-word behavior
      // (the Intel IRET behavior for which Linux uses ESPFIX).
      let outerPointerWidth = state.ss.attributes & 0x4000 != 0 ? 32 : 16
      writeProtectedStackPointer(outerStack, pointerWidth: outerPointerWidth, state: &state)
    } else {
      let nextStack = (stack &+ 3 * frameBytes) & pointerMask
      writeProtectedStackPointer(nextStack, pointerWidth: pointerWidth, state: &state)
    }
    state.rip = instructionPointer
    state.cs = code.segment
    state.cs.selector = codeSelector
    state.rflags = validatedFlags
  }

  private func validateProtectedReturnStack(
    _ offset: UInt64,
    byteCount: Int,
    segment: DoryX86SegmentState,
    instructionPointer: UInt64
  ) throws {
    let end = offset &+ UInt64(byteCount - 1)
    let expandDown = segment.attributes & 0xC == 4
    let upperBound: UInt64 = expandDown
      ? (segment.attributes & 0x4000 == 0 ? 0xFFFF : 0xFFFF_FFFF)
      : UInt64(segment.limit)
    guard end >= offset, end <= upperBound,
      !expandDown || offset > UInt64(segment.limit)
    else {
      throw DoryX86Exception(kind: .stackSegment, vector: 12, errorCode: 0,
        instructionPointer: instructionPointer)
    }
  }

  private func readProtectedGate(
    vector: UInt8,
    state: DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws -> ProtectedGate {
    let offset = Int(vector) * 8
    guard offset + 7 <= Int(state.idtr.limit) else {
      throw DoryX86InterruptDeliveryError.invalidIDTLimit(vector: vector)
    }
    let raw = try read64(memory, state.idtr.base &+ UInt64(offset))
    let attributes = UInt8(truncatingIfNeeded: raw >> 40)
    let type = attributes & 0x0f
    guard attributes & 0x10 == 0,
      type == 0x6 || type == 0x7 || type == 0xE || type == 0xF
    else {
      throw DoryX86InterruptDeliveryError.invalidGate(vector: vector)
    }
    guard attributes & 0x80 != 0 else {
      throw DoryX86InterruptDeliveryError.gateNotPresent(vector: vector)
    }
    let target = UInt32(raw & 0xffff) | UInt32((raw >> 48) & 0xffff) << 16
    return .init(
      offset: target,
      selector: UInt16(truncatingIfNeeded: raw >> 16),
      width: type == 0x6 || type == 0x7 ? .word : .doubleword,
      descriptorPrivilegeLevel: (attributes >> 5) & 3,
      isInterruptGate: type == 0x6 || type == 0xE
    )
  }

  private func readProtectedTaskStack(
    privilege: UInt8,
    state: DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws -> (stack: UInt64, segment: DoryX86SegmentState) {
    let taskType = UInt8(truncatingIfNeeded: state.tr.attributes) & 0x0f
    let stackOffset = 4 + Int(privilege) * 8
    let selectorOffset = stackOffset + 4
    guard taskType == 0x9 || taskType == 0xB,
      selectorOffset + 1 <= Int(state.tr.limit)
    else {
      throw DoryX86InterruptDeliveryError.invalidTaskStateSelector(state.tr.selector)
    }
    let stack = try read32(memory, state.tr.base &+ UInt64(stackOffset))
    let selector = try read16(memory, state.tr.base &+ UInt64(selectorOffset))
    let segment: LegacySegment
    do {
      segment = try readLegacySegment(selector: selector, state: state, memory: memory)
    } catch DoryX86InterruptDeliveryError.codeSegmentNotPresent {
      throw DoryX86InterruptDeliveryError.stackSegment(selector)
    } catch DoryX86InterruptDeliveryError.invalidCodeSegment {
      throw DoryX86InterruptDeliveryError.invalidTaskStateSelector(selector)
    }
    guard selector & 3 == privilege,
      segment.descriptorPrivilegeLevel == privilege,
      segment.type & 8 == 0,
      segment.type & 2 != 0
    else {
      throw DoryX86InterruptDeliveryError.invalidTaskStateSelector(selector)
    }
    var loaded = segment.segment
    loaded.selector = selector
    return (UInt64(stack), loaded)
  }

  private func readLegacySegment(
    selector: UInt16,
    state: DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws -> LegacySegment {
    guard selector & 0xfff8 != 0 else {
      throw DoryX86InterruptDeliveryError.invalidCodeSegment(selector: selector)
    }
    // A cached LDT segment limit is 32 bits after granularity expansion;
    // representing it as a GDTR-style 16-bit limit can reject valid selectors.
    let tableBase = selector & 4 == 0 ? state.gdtr.base : state.ldtr.base
    let tableLimit = selector & 4 == 0 ? UInt64(state.gdtr.limit) : UInt64(state.ldtr.limit)
    let offset = UInt64(selector & 0xfff8)
    guard offset + 7 <= tableLimit else {
      throw DoryX86InterruptDeliveryError.invalidCodeSegment(selector: selector)
    }
    let raw = try read64(memory, tableBase &+ offset)
    let access = UInt8(truncatingIfNeeded: raw >> 40)
    let flags = UInt8(truncatingIfNeeded: raw >> 52) & 0x0f
    guard access & 0x10 != 0 else {
      throw DoryX86InterruptDeliveryError.invalidCodeSegment(selector: selector)
    }
    guard access & 0x80 != 0 else {
      throw DoryX86InterruptDeliveryError.codeSegmentNotPresent(selector: selector)
    }
    let base =
      ((raw >> 16) & 0xffff)
      | ((raw >> 32) & 0xff) << 16
      | ((raw >> 56) & 0xff) << 24
    var limit = UInt32(raw & 0xffff) | UInt32((raw >> 48) & 0x0f) << 16
    if flags & 8 != 0 { limit = (limit << 12) | 0xfff }
    return .init(
      segment: .init(
        selector: selector,
        attributes: UInt16(access) | UInt16(flags) << 12,
        limit: limit,
        base: base
      ),
      descriptorPrivilegeLevel: (access >> 5) & 3,
      type: access & 0x0f
    )
  }

  private func writeProtectedFrame(
    _ values: [UInt64],
    width: DoryX86OperandWidth,
    stack: UInt64,
    pointerMask: UInt64,
    segment: DoryX86SegmentState,
    memory: any DoryX86Memory
  ) throws -> UInt64 {
    var offsets: [UInt64] = []
    var next = stack
    for _ in values {
      next = (next &- UInt64(width.byteCount)) & pointerMask
      guard next + UInt64(width.byteCount - 1) <= UInt64(segment.limit) else {
        throw DoryX86InterruptDeliveryError.stackSegment(segment.selector)
      }
      offsets.append(next)
      try memory.validateWrite(at: segment.base &+ next, byteCount: width.byteCount)
    }
    for (value, offset) in zip(values, offsets) {
      try memory.write(
        at: segment.base &+ offset,
        bytes: littleEndian(value, byteCount: width.byteCount)
      )
    }
    return next
  }

  private func writeProtectedStackPointer(
    _ value: UInt64,
    pointerWidth: Int,
    state: inout DoryX86ArchitecturalState
  ) {
    if pointerWidth == 32 {
      state.registers.rsp = value & 0xffff_ffff
    } else {
      state.registers.rsp = (state.registers.rsp & ~UInt64(0xffff)) | (value & 0xffff)
    }
  }

  private func readGate(
    vector: UInt8,
    state: DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws -> Gate {
    let offset = Int(vector) * 16
    guard offset + 15 <= Int(state.idtr.limit) else {
      throw DoryX86InterruptDeliveryError.invalidIDTLimit(vector: vector)
    }
    let bytes = try memory.read(at: state.idtr.base + UInt64(offset), byteCount: 16)
    let low = fromLittleEndian(Array(bytes[0..<8]))
    let high = fromLittleEndian(Array(bytes[8..<16]))
    let attributes = UInt8(truncatingIfNeeded: low >> 40)
    let type = attributes & 0x0f
    guard type != 0x6, type != 0x7 else {
      // Intel SDM Vol. 3A §7.14.1: legacy 16-bit gates in IA-32e mode
      // generate #GP(0), rather than an IDT-selector error code.
      throw DoryX86InterruptDeliveryError.generalProtectionZero
    }
    guard type == 0xE || type == 0xF,
      high >> 32 == 0
    else {
      throw DoryX86InterruptDeliveryError.invalidGate(vector: vector)
    }
    guard attributes & 0x80 != 0 else {
      throw DoryX86InterruptDeliveryError.gateNotPresent(vector: vector)
    }
    let target =
      (low & 0xffff)
      | ((low >> 48) & 0xffff) << 16
      | (high & 0xffff_ffff) << 32
    return .init(
      offset: target,
      selector: UInt16(truncatingIfNeeded: low >> 16),
      interruptStackTable: UInt8(truncatingIfNeeded: low >> 32) & 7,
      descriptorPrivilegeLevel: (attributes >> 5) & 3,
      isInterruptGate: type == 0xE
    )
  }

  private func readCodeSegment(
    selector: UInt16,
    state: DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws -> CodeSegment {
    guard selector & 0xfff8 != 0, selector & 4 == 0 else {
      throw DoryX86InterruptDeliveryError.invalidCodeSegment(selector: selector)
    }
    let offset = Int(selector & 0xfff8)
    guard offset + 7 <= Int(state.gdtr.limit) else {
      throw DoryX86InterruptDeliveryError.invalidCodeSegment(selector: selector)
    }
    let raw = try read64(memory, state.gdtr.base + UInt64(offset))
    let access = UInt8(truncatingIfNeeded: raw >> 40)
    let flags = UInt8(truncatingIfNeeded: raw >> 52) & 0x0f
    guard access & 0x10 != 0,
      access & 0x08 != 0,
      flags & 0x2 != 0
    else {
      throw DoryX86InterruptDeliveryError.invalidCodeSegment(selector: selector)
    }
    guard access & 0x80 != 0 else {
      throw DoryX86InterruptDeliveryError.codeSegmentNotPresent(selector: selector)
    }
    let dpl = (access >> 5) & 3
    let base =
      ((raw >> 16) & 0xffff)
      | ((raw >> 32) & 0xff) << 16
      | ((raw >> 56) & 0xff) << 24
    let limit = UInt32(raw & 0xffff) | UInt32((raw >> 48) & 0x0f) << 16
    let attributes = UInt16(access) | UInt16(flags) << 12
    return .init(
      segment: .init(
        selector: selector,
        attributes: attributes,
        limit: flags & 0x8 != 0 ? .max : limit,
        base: base
      ),
      descriptorPrivilegeLevel: dpl
    )
  }

  private func readTaskStack(
    offset: Int,
    state: DoryX86ArchitecturalState,
    memory: any DoryX86Memory
  ) throws -> UInt64 {
    guard state.tr.base != 0, offset + 7 <= Int(state.tr.limit) else {
      throw DoryX86InterruptDeliveryError.invalidTaskStateSelector(state.tr.selector)
    }
    return try read64(memory, state.tr.base + UInt64(offset))
  }

  private func translatedMemory(
    physicalMemory: any DoryX86Memory,
    pagingUnit: DoryX86PagingUnit?,
    state: DoryX86ArchitecturalState,
    mode: DoryX86ExecutionMode,
    cpl: UInt8,
    isImplicitSupervisorAccess: Bool = false
  ) -> any DoryX86Memory {
    guard let pagingUnit else { return physicalMemory }
    return DoryX86TranslatedMemory(
      physicalMemory: physicalMemory,
      pagingUnit: pagingUnit,
      context: .init(
        control: state.control,
        rflags: state.rflags,
        currentPrivilegeLevel: cpl,
        mode: mode,
        isImplicitSupervisorAccess: isImplicitSupervisorAccess,
        supportsOneGiBPages: profile.supports(.oneGiBPages),
        supportsPAT: profile.cpuid(leaf: 1).edx & (1 << 16) != 0
      )
    )
  }

  private func read64(_ memory: any DoryX86Memory, _ address: UInt64) throws -> UInt64 {
    fromLittleEndian(try memory.read(at: address, byteCount: 8))
  }

  private func read16(_ memory: any DoryX86Memory, _ address: UInt64) throws -> UInt16 {
    let bytes = try memory.read(at: address, byteCount: 2)
    return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
  }

  private func read32(_ memory: any DoryX86Memory, _ address: UInt64) throws -> UInt32 {
    UInt32(truncatingIfNeeded: fromLittleEndian(try memory.read(at: address, byteCount: 4)))
  }

  private func littleEndian16(_ value: UInt16) -> [UInt8] {
    [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
  }

  private func littleEndian(_ value: UInt64) -> [UInt8] {
    (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
  }

  private func littleEndian(_ value: UInt64, byteCount: Int) -> [UInt8] {
    (0..<byteCount).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
  }

  private func fromLittleEndian(_ bytes: [UInt8]) -> UInt64 {
    bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << UInt64($1.offset * 8) }
  }
}
