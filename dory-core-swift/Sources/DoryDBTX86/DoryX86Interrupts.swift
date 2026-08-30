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
  case privilegeViolation(vector: UInt8)
  case invalidCodeSegment(selector: UInt16)
  case invalidTaskState
  case invalidReturnFrame
  case tripleFault
}

public struct DoryX86InterruptDelivery: Sendable {
  public init() {}

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
    if source == .externalMaskable {
      guard state.rflags.contains(.interruptEnable), UInt64(vector >> 4) > state.control.cr8 else {
        return
      }
    }
    if mode == .real16 {
      try deliverRealMode(
        vector: vector,
        returnInstructionPointer: returnInstructionPointer,
        state: &state,
        memory: physicalMemory
      )
      return
    }
    if mode == .protected32 {
      try deliverProtectedMode(
        vector: vector,
        source: source,
        errorCode: errorCode,
        returnInstructionPointer: returnInstructionPointer,
        state: &state,
        memory: physicalMemory
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
      cpl: 0
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
    guard targetCPL <= currentCPL,
      DoryX86ArchitecturalState.isCanonical(gate.offset)
    else {
      throw DoryX86InterruptDeliveryError.invalidCodeSegment(selector: gate.selector)
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
      throw DoryX86InterruptDeliveryError.invalidTaskState
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
      if let translated = stackMemory as? DoryX86TranslatedMemory {
        try translated.validateWrite(at: address, byteCount: 8)
      } else {
        _ = try stackMemory.read(at: address, byteCount: 8)
      }
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
    do {
      try deliver(
        vector: exception.vector,
        source: .hardwareException,
        errorCode: exception.errorCode,
        returnInstructionPointer: exception.instructionPointer,
        state: &state,
        physicalMemory: physicalMemory,
        pagingUnit: pagingUnit,
        mode: mode
      )
    } catch {
      guard exception.vector != 8 else { throw DoryX86InterruptDeliveryError.tripleFault }
      do {
        try deliver(
          vector: 8,
          source: .hardwareException,
          errorCode: 0,
          returnInstructionPointer: exception.instructionPointer,
          state: &state,
          physicalMemory: physicalMemory,
          pagingUnit: pagingUnit,
          mode: mode
        )
      } catch {
        throw DoryX86InterruptDeliveryError.tripleFault
      }
    }
  }

  public func interruptReturn(
    state: inout DoryX86ArchitecturalState,
    physicalMemory: any DoryX86Memory,
    pagingUnit: DoryX86PagingUnit? = nil,
    mode: DoryX86ExecutionMode
  ) throws {
    if mode == .real16 {
      try interruptReturnRealMode(state: &state, memory: physicalMemory)
      return
    }
    if mode == .protected32 {
      try interruptReturnProtectedMode(state: &state, memory: physicalMemory)
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
      cpl: 0
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
        throw DoryX86InterruptDeliveryError.invalidTaskState
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
    memory: any DoryX86Memory
  ) throws {
    let stack = UInt16(truncatingIfNeeded: state.registers.rsp)
    let codeStack = stack &+ 2
    let flagsStack = codeStack &+ 2
    for offset in [stack, codeStack, flagsStack] {
      guard UInt32(offset) + 1 <= state.ss.limit else {
        throw DoryX86InterruptDeliveryError.invalidReturnFrame
      }
    }
    let instructionPointer = try read16(memory, state.ss.base &+ UInt64(stack))
    let codeSelector = try read16(memory, state.ss.base &+ UInt64(codeStack))
    let flags = try read16(memory, state.ss.base &+ UInt64(flagsStack))
    let requestedFlags = DoryX86RFLAGS(
      rawValue: (state.rflags.rawValue & ~UInt64(0xffff)) | UInt64(flags) | 2
    )
    guard let validatedFlags = try? requestedFlags.validated() else {
      throw DoryX86InterruptDeliveryError.invalidReturnFrame
    }

    let nextStack = flagsStack &+ 2
    state.registers.rsp = (state.registers.rsp & ~UInt64(0xffff)) | UInt64(nextStack)
    state.rip = UInt64(instructionPointer)
    state.cs = .init(
      selector: codeSelector,
      attributes: 0x009B,
      limit: 0xffff,
      base: UInt64(codeSelector) << 4
    )
    state.rflags = validatedFlags
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
    memory: any DoryX86Memory
  ) throws {
    let gate = try readProtectedGate(vector: vector, state: state, memory: memory)
    let currentCPL = UInt8(state.cs.selector & 3)
    if source == .software, currentCPL > gate.descriptorPrivilegeLevel {
      throw DoryX86InterruptDeliveryError.privilegeViolation(vector: vector)
    }
    let code = try readLegacySegment(selector: gate.selector, state: state, memory: memory)
    let conforming = code.type & 4 != 0
    let targetCPL = conforming ? currentCPL : code.descriptorPrivilegeLevel
    guard code.type & 8 != 0,
      code.descriptorPrivilegeLevel <= currentCPL,
      UInt64(gate.offset) <= UInt64(code.segment.limit)
    else {
      throw DoryX86InterruptDeliveryError.invalidCodeSegment(selector: gate.selector)
    }

    let switchesPrivilege = targetCPL < currentCPL
    let targetStack: UInt64
    let targetStackSegment: DoryX86SegmentState
    if switchesPrivilege {
      (targetStack, targetStackSegment) = try readProtectedTaskStack(
        privilege: targetCPL,
        state: state,
        memory: memory
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
    let finalStack = try writeProtectedFrame(
      values,
      width: gate.width,
      stack: targetStack & pointerMask,
      pointerMask: pointerMask,
      segment: targetStackSegment,
      memory: memory
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
    memory: any DoryX86Memory
  ) throws {
    let pointerWidth = state.ss.attributes & 0x4000 != 0 ? 32 : 16
    let pointerMask: UInt64 = pointerWidth == 32 ? 0xffff_ffff : 0xffff
    let stack = state.registers.rsp & pointerMask
    let addresses = (0..<3).map { (stack &+ UInt64($0 * 4)) & pointerMask }
    for address in addresses {
      guard address + 3 <= UInt64(state.ss.limit) else {
        throw DoryX86InterruptDeliveryError.invalidReturnFrame
      }
    }
    let instructionPointer = try read32(memory, state.ss.base &+ addresses[0])
    let codeSelector = UInt16(
      truncatingIfNeeded: try read32(memory, state.ss.base &+ addresses[1]))
    let flagsValue = try read32(memory, state.ss.base &+ addresses[2])
    let targetCPL = UInt8(codeSelector & 3)
    let currentCPL = UInt8(state.cs.selector & 3)
    guard targetCPL >= currentCPL else {
      throw DoryX86InterruptDeliveryError.invalidReturnFrame
    }
    let code = try readLegacySegment(selector: codeSelector, state: state, memory: memory)
    guard code.type & 8 != 0,
      code.descriptorPrivilegeLevel == targetCPL,
      instructionPointer <= code.segment.limit
    else {
      throw DoryX86InterruptDeliveryError.invalidReturnFrame
    }
    let requestedFlags = DoryX86RFLAGS(
      rawValue: (state.rflags.rawValue & ~UInt64(0xffff_ffff)) | UInt64(flagsValue) | 2
    )
    guard let validatedFlags = try? requestedFlags.validated() else {
      throw DoryX86InterruptDeliveryError.invalidReturnFrame
    }

    if targetCPL > currentCPL {
      let outerStackAddress = (stack &+ 12) & pointerMask
      let outerSelectorAddress = (stack &+ 16) & pointerMask
      guard outerStackAddress + 3 <= UInt64(state.ss.limit),
        outerSelectorAddress + 3 <= UInt64(state.ss.limit)
      else {
        throw DoryX86InterruptDeliveryError.invalidReturnFrame
      }
      let outerStack = try read32(memory, state.ss.base &+ outerStackAddress)
      let outerSelector = UInt16(
        truncatingIfNeeded: try read32(memory, state.ss.base &+ outerSelectorAddress))
      let stackSegment = try readLegacySegment(
        selector: outerSelector,
        state: state,
        memory: memory
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
      let outerPointerWidth = state.ss.attributes & 0x4000 != 0 ? 32 : 16
      writeProtectedStackPointer(
        UInt64(outerStack),
        pointerWidth: outerPointerWidth,
        state: &state
      )
    } else {
      let nextStack = (stack &+ 12) & pointerMask
      writeProtectedStackPointer(nextStack, pointerWidth: pointerWidth, state: &state)
    }
    state.rip = UInt64(instructionPointer)
    state.cs = code.segment
    state.cs.selector = codeSelector
    state.rflags = validatedFlags
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
    guard attributes & 0x80 != 0,
      attributes & 0x10 == 0,
      type == 0x6 || type == 0x7 || type == 0xE || type == 0xF
    else {
      throw DoryX86InterruptDeliveryError.invalidGate(vector: vector)
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
      throw DoryX86InterruptDeliveryError.invalidTaskState
    }
    let stack = try read32(memory, state.tr.base &+ UInt64(stackOffset))
    let selector = try read16(memory, state.tr.base &+ UInt64(selectorOffset))
    let segment = try readLegacySegment(selector: selector, state: state, memory: memory)
    guard selector & 3 == privilege,
      segment.descriptorPrivilegeLevel == privilege,
      segment.type & 8 == 0,
      segment.type & 2 != 0
    else {
      throw DoryX86InterruptDeliveryError.invalidTaskState
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
    let table: DoryX86DescriptorTableState =
      selector & 4 == 0
      ? state.gdtr
      : .init(limit: UInt16(truncatingIfNeeded: state.ldtr.limit), base: state.ldtr.base)
    let offset = UInt64(selector & 0xfff8)
    guard offset + 7 <= UInt64(table.limit) else {
      throw DoryX86InterruptDeliveryError.invalidCodeSegment(selector: selector)
    }
    let raw = try read64(memory, table.base &+ offset)
    let access = UInt8(truncatingIfNeeded: raw >> 40)
    let flags = UInt8(truncatingIfNeeded: raw >> 52) & 0x0f
    guard access & 0x80 != 0, access & 0x10 != 0 else {
      throw DoryX86InterruptDeliveryError.invalidCodeSegment(selector: selector)
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
        throw DoryX86InterruptDeliveryError.invalidTaskState
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
    guard attributes & 0x80 != 0,
      type == 0xE || type == 0xF,
      high >> 32 == 0
    else {
      throw DoryX86InterruptDeliveryError.invalidGate(vector: vector)
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
    guard access & 0x80 != 0,
      access & 0x10 != 0,
      access & 0x08 != 0,
      flags & 0x2 != 0
    else {
      throw DoryX86InterruptDeliveryError.invalidCodeSegment(selector: selector)
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
      throw DoryX86InterruptDeliveryError.invalidTaskState
    }
    return try read64(memory, state.tr.base + UInt64(offset))
  }

  private func translatedMemory(
    physicalMemory: any DoryX86Memory,
    pagingUnit: DoryX86PagingUnit?,
    state: DoryX86ArchitecturalState,
    mode: DoryX86ExecutionMode,
    cpl: UInt8
  ) -> any DoryX86Memory {
    guard let pagingUnit else { return physicalMemory }
    return DoryX86TranslatedMemory(
      physicalMemory: physicalMemory,
      pagingUnit: pagingUnit,
      context: .init(
        control: state.control,
        rflags: state.rflags,
        currentPrivilegeLevel: cpl,
        mode: mode
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
