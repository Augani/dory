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
    guard mode == .long64 else {
      throw DoryX86InterruptDeliveryError.invalidGate(vector: vector)
    }
    if source == .externalMaskable {
      guard state.rflags.contains(.interruptEnable), UInt64(vector >> 4) > state.control.cr8 else {
        return
      }
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

  private struct CodeSegment {
    let segment: DoryX86SegmentState
    let descriptorPrivilegeLevel: UInt8
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
    let attributes = UInt16(access) | UInt16(flags) << 8
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

  private func littleEndian(_ value: UInt64) -> [UInt8] {
    (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
  }

  private func fromLittleEndian(_ bytes: [UInt8]) -> UInt64 {
    bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << UInt64($1.offset * 8) }
  }
}
