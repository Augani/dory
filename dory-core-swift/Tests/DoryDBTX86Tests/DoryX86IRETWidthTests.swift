import Testing

@testable import DoryDBTX86

// Intel SDM092 Vol. 2A IRET/IRETD, protected-mode operation and exceptions:
// https://cdrdv2-public.intel.com/922480/253666-092-sdm-vol-2a.pdf
// These tests cover ordinary protected-mode returns, with VM=NT=0 on entry.
@Suite struct DoryX86IRETWidthTests {
  @Test func decodedModeAndSizeOverrideSelectFrameWidthIndependentlyOfStackAddressSize() throws {
    for mode: DoryX86ExecutionMode in [.protected16, .protected32] {
      for override in [false, true] {
        for stack32 in [false, true] {
          for addressOverride in [false, true] {
            let width = frameWidth(mode, override)
            let memory = try memory()
            var state = try state(mode: mode, stack32: stack32)
            let code = (override ? [UInt8(0x66)] : [])
              + (addressOverride ? [UInt8(0x67)] : []) + [0xCF]
            try memory.write(at: state.rip, bytes: code)
            let target: UInt64 = width == 2 ? 0xABCD : 0x1234_ABCD
            try memory.write(at: 0x18000, bytes: words([target, 8, 3], width))
            state.ss.limit = UInt32(0x8000 + 3 * width - 1) // Exactly the required frame.
            let initial = state
            let decoded = try DoryX86Decoder().decode(code, at: state.rip, mode: mode)
            #expect(decoded.operation == .interruptReturn)
            #expect(decoded.prefixes.operandSizeOverride == override)
            let snapshot = memory.snapshot()
            #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode) == .retired(decoded))
            #expect(state.rip == target && state.cs.selector == 8)
            #expect(state.registers.rsp == initial.registers.rsp + UInt64(3 * width))
            #expect(state.rflags.contains(.carry))
            #expect(memory.snapshot() == snapshot)
          }
        }
      }
    }
  }

  @Test func outerFramesUseOperandWidthAndTheReturnedStackPointerRules() throws {
    for mode: DoryX86ExecutionMode in [.protected16, .protected32] {
      for override in [false, true] {
        for oldStack32 in [false, true] {
          for newStack32 in [false, true] {
            let width = frameWidth(mode, override)
            let memory = try memory(outerStack32: newStack32)
            var state = try state(mode: mode, stack32: oldStack32)
            let code: [UInt8] = override ? [0x66, 0xCF] : [0xCF]
            try memory.write(at: state.rip, bytes: code)
            let pointer: UInt64 = width == 2 ? 0x3456 : 0x89AB_3456
            // High selector halves in a dword frame are discarded.
            try memory.write(at: 0x18000,
              bytes: words([0x5678, 0xABCD_001B, 2, pointer, 0xBEEF_0023], width))
            let oldStack = state.registers.rsp
            let decoded = try DoryX86Decoder().decode(code, at: state.rip, mode: mode)
            #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode) == .retired(decoded))
            #expect(state.rip == 0x5678 && state.cs.selector == 0x1B)
            #expect(state.ss.selector == 0x23 && state.ss.base == 0x20000)
            let expectedStack = newStack32 ? pointer : (oldStack & ~UInt64(0xFFFF)) | (pointer & 0xFFFF)
            #expect(state.registers.rsp == expectedStack)
            #expect((state.ss.attributes & 0x4000 != 0) == newStack32)
          }
        }
      }
    }
  }

  @Test func wordInterruptEntryAndDecodedIRETRoundTripSameAndInnerPrivilegeFrames() throws {
    for changesPrivilege in [false, true] {
      let memory = try memory(code32: false, outerStack32: false)
      var state = try state(mode: .protected16, stack32: false, cpl: changesPrivilege ? 3 : 0)
      state.registers.rsp = 0x9000
      state.rip = 0x5678
      state.rflags = [.reservedOne, .interruptEnable, .carry, .identification]
      try memory.write(at: 0x1000, bytes: [0xCF])
      try memory.writeScalar(at: 0x3400, value: 0x0000_E600_0008_1000, byteCount: 8)
      try memory.writeScalar(at: 0x30004, value: 0x8000, byteCount: 4)
      try memory.writeScalar(at: 0x30008, value: 16, byteCount: 2)
      let initial = state
      try DoryX86InterruptDelivery().deliver(vector: 0x80, source: .software,
        state: &state, physicalMemory: memory, mode: .protected16)
      #expect(state.rip == 0x1000)
      #expect(state.registers.rsp == (changesPrivilege ? 0x7FF6 : 0x8FFA))
      let decoded = try DoryX86Decoder().decode([0xCF], at: 0x1000, mode: .protected16)
      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .protected16) == .retired(decoded))
      #expect(state.rip == initial.rip && state.registers == initial.registers)
      #expect(state.cs.selector == initial.cs.selector && state.ss.selector == initial.ss.selector)
      #expect(state.rflags == initial.rflags)
    }
  }

  @Test func protectedFrameBoundsProduceTypedSSBeforeReadsAndBeforeStateChanges() throws {
    for width in [2, 4] {
      for outer in [false, true] {
        let backing = try memory()
        var state = try state(mode: .protected32, stack32: true)
        let code: [UInt8] = width == 2 ? [0x66, 0xCF] : [0xCF]
        try backing.write(at: state.rip, bytes: code)
        try backing.write(at: 0x18000, bytes: words([0x5678, outer ? 0x1B : 8, 3, 0x3456, 0x23], width))
        state.ss.limit = UInt32(0x8000 + (outer ? 5 : 3) * width - 2)
        let initial = state
        let memory = IRETReadTrackingMemory(backing: backing)
        let fault = DoryX86Exception(kind: .stackSegment, vector: 12, errorCode: 0,
          instructionPointer: initial.rip)
        #expect(throws: fault) {
          try DoryX86InterruptDelivery().interruptReturn(state: &state, physicalMemory: memory,
            mode: .protected32, operandSizeOverride: width == 2)
        }
        #expect(state == initial)
        #expect(memory.stackReads.count == (outer ? 3 : 0))
        memory.clearReads()
        #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .protected32) == .exception(fault))
        #expect(state == initial)
        #expect(memory.stackReads.count == (outer ? 3 : 0))
      }
    }
  }

  @Test func wholeInitialFrameCannotWrapPastStackBoundsAndExpandDownBoundsAreRespected() throws {
    for stack32 in [false, true] {
      for valid in [false, true] {
        let memory = try memory()
        var state = try state(mode: .protected16, stack32: stack32)
        state.ss.attributes |= 4 // Expand-down writable data segment.
        state.ss.limit = valid ? 0x7FFF : 0x8000
        try memory.write(at: 0x18000, bytes: words([0x5678, 8, 2], 2))
        let initial = state
        if valid {
          try DoryX86InterruptDelivery().interruptReturn(state: &state,
            physicalMemory: memory, mode: .protected16)
          #expect(state.rip == 0x5678 && state.registers.rsp == initial.registers.rsp + 6)
        } else {
          #expect(throws: DoryX86Exception(kind: .stackSegment, vector: 12, errorCode: 0,
            instructionPointer: initial.rip)) {
            try DoryX86InterruptDelivery().interruptReturn(state: &state,
              physicalMemory: memory, mode: .protected16)
          }
          #expect(state == initial)
        }
      }
      let memory = try memory()
      var state = try state(mode: .protected16, stack32: stack32)
      state.registers.rsp = stack32 ? 0xFFFF_FFFC : 0xFFFC
      state.ss.limit = stack32 ? .max : 0xFFFF
      let initial = state
      #expect(throws: DoryX86Exception(kind: .stackSegment, vector: 12, errorCode: 0,
        instructionPointer: initial.rip)) {
        try DoryX86InterruptDelivery().interruptReturn(state: &state,
          physicalMemory: memory, mode: .protected16)
      }
      #expect(state == initial)
    }
  }

  @Test func flagMergingUsesExecutingCPLAndOldIOPLAndPreservesWordUpperFlags() throws {
    let upper: DoryX86RFLAGS = [.resume, .alignmentCheck, .identification, .virtualInterrupt, .virtualInterruptPending]
    for width in [2, 4] {
      for cpl: UInt8 in [0, 1, 3] {
        for oldIOPL: UInt64 in [0, 1, 3] {
          for requestedSet in [false, true] {
            let memory = try memory()
            var state = try state(mode: .protected32, stack32: true, cpl: cpl)
            let oldSet = !requestedSet
            state.rflags = .init(rawValue: 2 | oldIOPL << 12
              | (oldSet ? upper.rawValue | DoryX86RFLAGS.interruptEnable.rawValue : 0))
            let newIOPL: UInt64 = oldIOPL == 3 ? 0 : 3
            let image = UInt64(2) | newIOPL << 12 | 0xFFC0_8028 // Reserved bits ignored.
              | (requestedSet ? upper.rawValue | DoryX86RFLAGS.interruptEnable.rawValue
                  | DoryX86RFLAGS.carry.rawValue : 0)
            try memory.write(at: state.ss.base + 0x8000,
              bytes: words([0x5678, UInt64(state.cs.selector), image], width))
            try DoryX86InterruptDelivery().interruptReturn(state: &state, physicalMemory: memory,
              mode: .protected32, operandSizeOverride: width == 2)
            #expect(state.rflags.contains(.carry) == requestedSet)
            #expect(state.rflags.contains(.interruptEnable) == (UInt64(cpl) <= oldIOPL ? requestedSet : oldSet))
            #expect((state.rflags.rawValue >> 12) & 3 == (cpl == 0 ? newIOPL : oldIOPL))
            for flag: DoryX86RFLAGS in [.resume, .alignmentCheck, .identification] {
              #expect(state.rflags.contains(flag) == (width == 4 ? requestedSet : oldSet))
            }
            for flag: DoryX86RFLAGS in [.virtualInterrupt, .virtualInterruptPending] {
              #expect(state.rflags.contains(flag) == (width == 4 && cpl == 0 ? requestedSet : oldSet))
            }
            #expect(state.rflags.contains(.reservedOne) && !state.rflags.contains(.virtual8086))
            #expect(state.rflags.rawValue & ~DoryX86RFLAGS.architecturallyWritableMask == 0)
          }
        }
      }
    }
  }

  @Test func decodedIRETPageFaultsPreserveOriginalRIPAndPublishOnlyCR2() throws {
    for width in [2, 4] {
      for outerTail in [false, true] {
        let memory = try memory()
        let code: [UInt8] = width == 2 ? [0x66, 0xCF] : [0xCF]
        try memory.write(at: 0x1000, bytes: code)
        try installPaging(memory)
        var state = try state(mode: .protected32, stack32: true)
        state.ss.base = 0
        state.control.cr0 |= 1 << 31
        state.control.cr3 = 0x9000
        if outerTail {
          state.registers.rsp = 0x9000 - UInt64(4 * width)
          try memory.write(at: 0x19000 - UInt64(4 * width),
            bytes: words([0x5678, 0x1B, 3, 0x3456], width))
        } else {
          state.registers.rsp = 0x8FFF
          try memory.write(at: 0x18FFF, bytes: [0x34])
        }
        let initial = state
        let paging = DoryX86PagingUnit()
        let translated = DoryX86TranslatedMemory(physicalMemory: memory, pagingUnit: paging,
          context: .init(state: state, mode: .protected32))
        #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .protected32,
          translatedMemory: translated) == .exception(.init(kind: .pageFault, vector: 14,
            errorCode: 0, instructionPointer: initial.rip, linearAddress: 0x9000)))
        var expected = initial
        expected.control.cr2 = 0x9000
        #expect(state == expected)
      }
    }
  }

  @Test func decodedINTPreservesImplicitSupervisorPageFaultAndCR2() throws {
    let memory = try memory()
    try memory.write(at: 0x1000, bytes: [0xCD, 0x80])
    try installPaging(memory)
    var state = try state(mode: .protected32, stack32: true, cpl: 3)
    state.control.cr0 |= 1 << 31
    state.control.cr3 = 0x9000
    let initial = state
    let paging = DoryX86PagingUnit()
    let translated = DoryX86TranslatedMemory(physicalMemory: memory, pagingUnit: paging,
      context: .init(state: state, mode: .protected32))
    // Linear IDT page3 is absent. This is a supervisor read even from CPL3.
    #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .protected32,
      translatedMemory: translated) == .exception(.init(kind: .pageFault, vector: 14,
        errorCode: 0, instructionPointer: initial.rip, linearAddress: 0x3400)))
    var expected = initial
    expected.control.cr2 = 0x3400
    #expect(state == expected)
  }

  private func frameWidth(_ mode: DoryX86ExecutionMode, _ override: Bool) -> Int {
    (mode == .protected16) != override ? 2 : 4
  }

  private func memory(code32: Bool = true, outerStack32: Bool = true) throws -> DoryX86ByteArrayMemory {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x40000)
    for (selector, base, access, default32): (UInt64, UInt64, UInt64, Bool) in [
      (8, 0, 0x9B, code32), (16, 0x10000, 0x93, true),
      (24, 0, 0xFB, code32), (32, 0x20000, 0xF3, outerStack32),
      (40, 0, 0xBB, code32),
    ] {
      let flags: UInt64 = default32 ? 0xC : 8
      let descriptor = UInt64(0xFFFF) | (base & 0xFFFF) << 16 | (base >> 16 & 255) << 32
        | access << 40 | UInt64(15) << 48 | flags << 52 | (base >> 24 & 255) << 56
      try memory.writeScalar(at: 0x2000 + selector, value: descriptor, byteCount: 8)
    }
    return memory
  }

  private func state(mode: DoryX86ExecutionMode, stack32: Bool, cpl: UInt8 = 0) throws -> DoryX86ArchitecturalState {
    let codeSelector: UInt16 = cpl == 3 ? 0x1B : cpl == 1 ? 0x29 : 8
    let dataSelector: UInt16 = cpl == 3 ? 0x23 : 16 | UInt16(cpl)
    return try .init(registers: .init(rsp: stack32 ? 0x8000 : 0xCAFE_8000), rip: 0x1000,
      cs: .init(selector: codeSelector,
        attributes: (mode == .protected16 ? 0x809B : 0xC09B) | UInt16(cpl) << 5, limit: .max),
      ss: .init(selector: dataSelector,
        attributes: (stack32 ? 0xC093 : 0x8093) | UInt16(cpl) << 5,
        limit: .max, base: cpl == 3 ? 0x20000 : 0x10000),
      tr: .init(selector: 0x30, attributes: 0x8B, limit: 0x67, base: 0x30000),
      gdtr: .init(limit: 0x2F, base: 0x2000), idtr: .init(limit: 0xFFF, base: 0x3000),
      control: .init(cr0: 0x10011, cr2: 0xDEAD))
  }

  private func words(_ values: [UInt64], _ width: Int) -> [UInt8] {
    values.flatMap { value in (0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
  }

  private func installPaging(_ memory: DoryX86ByteArrayMemory) throws {
    try memory.writeScalar(at: 0x9000, value: 0xA007, byteCount: 4)
    try memory.writeScalar(at: 0xA004, value: 0x1007, byteCount: 4)
    try memory.writeScalar(at: 0xA008, value: 0x2003, byteCount: 4)
    try memory.writeScalar(at: 0xA020, value: 0x18003, byteCount: 4)
  }
}

private final class IRETReadTrackingMemory: DoryX86Memory, @unchecked Sendable {
  let backing: DoryX86ByteArrayMemory
  private(set) var stackReads: [UInt64] = []
  init(backing: DoryX86ByteArrayMemory) { self.backing = backing }
  func clearReads() { stackReads = [] }
  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try backing.instructionBytes(at: address, maximumCount: maximumCount)
  }
  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    if address >= 0x10000 { stackReads.append(address) }
    return try backing.read(at: address, byteCount: byteCount)
  }
  func write(at address: UInt64, bytes: [UInt8]) throws { try backing.write(at: address, bytes: bytes) }
}
