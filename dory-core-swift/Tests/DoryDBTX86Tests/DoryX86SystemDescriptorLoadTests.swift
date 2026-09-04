import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 2A LLDT pp.3-558–559, LTR pp.3-576–577;
// Vol. 3A §§3.5.2/4.2, Fig.10-4: IA-32e descriptor widths and supervisor access.
// https://cdrdv2-public.intel.com/922480/253666-092-sdm-vol-2a.pdf
// https://cdrdv2-public.intel.com/922487/253668-092-sdm-vol-3a.pdf
@Suite struct DoryX86SystemDescriptorLoadTests {
  private let configurations: [(DoryX86ExecutionMode, Bool)] = [
    (.protected16, false), (.protected32, false),
    (.protected16, true), (.protected32, true), (.long64, true),
  ]

  @Test func validTypesLoadAtIA32eWidthIncludingBothCompatibilityModes() throws {
    for (mode, ia32e) in configurations {
      for task in [false, true] {
        let types: [UInt8] = task ? (ia32e ? [9] : [1, 9]) : [2]
        for type in types {
          let base: UInt64 = ia32e ? 0xFFFF_8000_1234_5678 : 0x1234_5678
          let bytes = descriptor(type: type, base: base, dpl: 3)
          let memory = try fixture(task: task, descriptor: bytes)
          var state = try makeState(mode: mode, ia32e: ia32e)
          state.registers.rax = 0x23 // RPL and descriptor DPL do not restrict privileged loads.
          state.gdtr.limit = ia32e ? 0x2F : 0x27
          let before = state
          try retire(&state, memory: memory, mode: mode)
          let loaded = task ? state.tr : state.ldtr
          #expect(loaded.selector == 0x23)
          #expect(loaded.base == base)
          #expect(loaded.limit == 0x12345)
          #expect(loaded.attributes == UInt16(0xE0 | type | (task ? 2 : 0)))
          #expect((task ? state.ldtr : state.tr) == (task ? before.ldtr : before.tr))
          var expected = bytes
          if task { expected[5] |= 2 }
          #expect(try memory.read(at: 0x2020, byteCount: 16) == expected)
          #expect(state.rflags == before.rflags)
        }
      }
    }
  }

  @Test func wrongTypesAndNotPresentDescriptorsReportDistinctSelectorFaults() throws {
    for (mode, ia32e) in configurations {
      for task in [false, true] {
        for type: UInt8 in 0..<16 {
          for present in [false, true] {
            let validType = task ? type == 9 || (!ia32e && type == 1) : type == 2
            if validType && present { continue }
            let memory = try fixture(task: task, descriptor: descriptor(type: type, present: present))
            var state = try makeState(mode: mode, ia32e: ia32e)
            state.registers.rax = 0x23
            try expectFault(&state, memory: memory, mode: mode,
              notPresent: validType && !present, code: 0x20)
          }
        }
        var application = descriptor(type: task ? 9 : 2)
        application[5] |= 0x10
        let memory = try fixture(task: task, descriptor: application)
        var state = try makeState(mode: mode, ia32e: ia32e)
        try expectFault(&state, memory: memory, mode: mode, code: 0x20)
      }
    }
  }

  @Test func IA32eUpperTypeBitsFaultBeforeBusyOrRegisterChanges() throws {
    for (mode, ia32e) in configurations where ia32e {
      for task in [false, true] {
        for bit in 0..<5 {
          var bytes = descriptor(type: task ? 9 : 2)
          bytes[13] = 1 << bit
          let memory = try fixture(task: task, descriptor: bytes)
          var state = try makeState(mode: mode, ia32e: ia32e)
          try expectFault(&state, memory: memory, mode: mode, code: 0x20)
        }
      }
    }
  }

  @Test func nullSelectorsTableIndexAndFullDescriptorLimitUsePreciseCodes() throws {
    for (mode, ia32e) in configurations {
      for task in [false, true] {
        for selector: UInt64 in [0, 1, 2, 3, 0x24, 0x43] {
          let memory = try fixture(task: task, descriptor: descriptor(type: task ? 9 : 2))
          var state = try makeState(mode: mode, ia32e: ia32e)
          state.registers.rax = selector
          state.gdtr.limit = 0x2F
          if !task && selector < 4 {
            // Null LLDT invalidates without even consulting its now-unmapped table.
            state.gdtr.base = 0xFFFF_0000
            try retire(&state, memory: memory, mode: mode)
            #expect(state.ldtr == .init(selector: UInt16(selector)))
          } else {
            try expectFault(&state, memory: memory, mode: mode,
              code: selector < 4 ? 0 : UInt32(selector & ~3))
          }
        }
        let memory = try fixture(task: task, descriptor: descriptor(type: task ? 9 : 2))
        var state = try makeState(mode: mode, ia32e: ia32e)
        state.gdtr.limit = ia32e ? 0x2E : 0x26
        try expectFault(&state, memory: memory, mode: mode, code: 0x20)
      }
    }
  }

  @Test func implicitDescriptorReadsCannotReuseExplicitACEnabledSMAPTranslations() throws {
    for task in [false, true] {
      for userDescriptor in [false, true] {
        var state = try makeState(mode: .long64, ia32e: true)
        let (memory, _, translated) = try pagedFixture(task: task, state: &state,
          descriptorFlags: userDescriptor ? 7 : 3, selectorInMemory: true)
        // AC permits the explicit user-page selector operand and this warm read.
        #expect(try translated.read(at: 0x6020, byteCount: 16).count == 16)
        let before = state
        let originalDescriptor = try memory.read(at: 0x6020, byteCount: 16)
        let result = DoryX86Interpreter().step(state: &state, memory: memory,
          mode: .long64, translatedMemory: translated)
        if userDescriptor {
          #expect(result == pageFault(address: 0x6020, code: 1))
          var expected = before
          expected.control.cr2 = 0x6020
          #expect(state == expected)
          #expect(try memory.read(at: 0x6020, byteCount: 16) == originalDescriptor)
        } else {
          let code: [UInt8] = [0x0F, 0x00, task ? 0x18 : 0x10]
          let decoded = try DoryX86Decoder().decode(code, at: 0x1000, mode: .long64)
          #expect(result == .retired(decoded))
          #expect((task ? state.tr : state.ldtr).base == 0x1234_5678)
        }
        // The descriptor view must not permanently change ordinary operand access.
        #expect(try translated.read(at: 0x7000, byteCount: 2) == [0x20, 0])
      }
    }
  }

  @Test func noncanonicalOrOverflowingDescriptorAddressesFaultBeforeMemory() throws {
    for (mode, ia32e) in configurations where ia32e {
      for task in [false, true] {
        for tableBase: UInt64 in [0x0000_8000_0000_0000, 0x0000_7FFF_FFFF_FFD8,
          0xFFFF_FFFF_FFFF_FFE8] {
          let memory = try fixture(task: task, descriptor: descriptor(type: task ? 9 : 2))
          var state = try makeState(mode: mode, ia32e: ia32e)
          state.gdtr.base = tableBase
          try expectFault(&state, memory: memory, mode: mode, code: 0x20)
        }
      }
    }
  }

  @Test func busyByteWriteRespectsSupervisorWriteProtectionBeforePublishingTR() throws {
    for writeProtect in [false, true] {
      var state = try makeState(mode: .long64, ia32e: true)
      let (memory, _, translated) = try pagedFixture(task: true, state: &state,
        descriptorFlags: 1, writeProtect: writeProtect)
      let before = state
      let descriptorBefore = try memory.read(at: 0x6020, byteCount: 16)
      let result = DoryX86Interpreter().step(state: &state, memory: memory,
        mode: .long64, translatedMemory: translated)
      if writeProtect {
        #expect(result == pageFault(address: 0x6025, code: 3))
        var expected = before
        expected.control.cr2 = 0x6025
        #expect(state == expected)
        #expect(try memory.read(at: 0x6020, byteCount: 16) == descriptorBefore)
      } else {
        let decoded = try DoryX86Decoder().decode([0x0F, 0x00, 0xD8], at: 0x1000, mode: .long64)
        #expect(result == .retired(decoded))
        var expected = descriptorBefore
        expected[5] |= 2
        #expect(try memory.read(at: 0x6020, byteCount: 16) == expected)
        #expect(state.tr.attributes & 0xF == 11)
      }
    }
  }

  @Test func inaccessibleUpperDescriptorPageLeavesBusyBitAndRegistersUnchanged() throws {
    for task in [false, true] {
      var state = try makeState(mode: .long64, ia32e: true)
      let (memory, _, translated) = try pagedFixture(task: task, state: &state, descriptorFlags: 3)
      state.gdtr.base = 0x6FD8 // selector20 puts first eight bytes at6FF8, upper half at7000.
      let bytes = descriptor(type: task ? 9 : 2)
      try memory.write(at: 0x6FF8, bytes: bytes)
      try memory.writeScalar(at: 0x5038, value: 0, byteCount: 8)
      let before = state
      #expect(DoryX86Interpreter().step(state: &state, memory: memory,
        mode: .long64, translatedMemory: translated) == pageFault(address: 0x7000, code: 0))
      var expected = before
      expected.control.cr2 = 0x7000
      #expect(state == expected)
      #expect(try memory.read(at: 0x6FF8, byteCount: 16) == bytes)
    }
  }

  private func descriptor(type: UInt8, base: UInt64 = 0x1234_5678,
    present: Bool = true, dpl: UInt8 = 0) -> [UInt8] {
    let low = UInt64(0x2345) | ((base & 0xFFFF) << 16) | (((base >> 16) & 0xFF) << 32)
      | (UInt64((present ? 0x80 : 0) | (dpl << 5) | type) << 40)
      | (UInt64(1) << 48) | (((base >> 24) & 0xFF) << 56)
    return (0..<8).map { UInt8(truncatingIfNeeded: low >> ($0 * 8)) }
      + (0..<4).map { UInt8(truncatingIfNeeded: base >> (32 + $0 * 8)) } + [0, 0, 0, 0]
  }

  private func makeState(mode: DoryX86ExecutionMode, ia32e: Bool) throws -> DoryX86ArchitecturalState {
    try .init(registers: .init(rax: 0x20), rip: 0x1000,
      cs: .init(selector: 0, attributes: mode == .long64 ? 0xA09B : 0xC09B, limit: .max),
      ds: .init(selector: 0x10, attributes: 0xC093, limit: .max),
      tr: .init(selector: 0x40, attributes: 0x8B, limit: 0x67, base: 0x4000),
      ldtr: .init(selector: 0x50, attributes: 0x82, limit: 0x7F, base: 0x5000),
      gdtr: .init(limit: 0x2F, base: 0x2000),
      control: .init(cr0: 0x11, cr4: ia32e ? 1 << 5 : 0, efer: ia32e ? 0x500 : 0))
  }

  private func fixture(task: Bool, descriptor: [UInt8]) throws -> DoryX86ByteArrayMemory {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x8000)
    try memory.write(at: 0x1000, bytes: [0x0F, 0x00, task ? 0xD8 : 0xD0])
    try memory.write(at: 0x2020, bytes: descriptor)
    return memory
  }

  private func pagedFixture(task: Bool, state: inout DoryX86ArchitecturalState,
    descriptorFlags: UInt64, selectorInMemory: Bool = false, writeProtect: Bool = true) throws
    -> (DoryX86ByteArrayMemory, DoryX86PagingUnit, DoryX86TranslatedMemory) {
    let memory = try fixture(task: task, descriptor: descriptor(type: task ? 9 : 2))
    if selectorInMemory {
      try memory.write(at: 0x1000, bytes: [0x0F, 0x00, task ? 0x18 : 0x10])
      state.registers.rax = 0x7000
    }
    try memory.writeScalar(at: 0x2000, value: 0x3007, byteCount: 8)
    try memory.writeScalar(at: 0x3000, value: 0x4007, byteCount: 8)
    try memory.writeScalar(at: 0x4000, value: 0x5007, byteCount: 8)
    for page in 0..<8 {
      let flags: UInt64 = page == 6 ? descriptorFlags : page == 7 ? 7 : 3
      try memory.writeScalar(at: 0x5000 + UInt64(page * 8),
        value: UInt64(page * 0x1000) | flags, byteCount: 8)
    }
    try memory.write(at: 0x6020, bytes: descriptor(type: task ? 9 : 2))
    try memory.write(at: 0x7000, bytes: [0x20, 0])
    state.gdtr.base = 0x6000
    state.control = .init(cr0: 0x8000_0011 | (writeProtect ? 1 << 16 : 0),
      cr3: 0x2000, cr4: (1 << 5) | (1 << 21), efer: 0x500)
    state.rflags.insert(.alignmentCheck)
    let paging = DoryX86PagingUnit()
    return (memory, paging, .init(physicalMemory: memory, pagingUnit: paging,
      context: .init(state: state, mode: .long64)))
  }

  private func retire(_ state: inout DoryX86ArchitecturalState,
    memory: DoryX86ByteArrayMemory, mode: DoryX86ExecutionMode) throws {
    guard case .retired = DoryX86Interpreter().step(state: &state, memory: memory, mode: mode) else {
      Issue.record("Valid system descriptor load did not retire")
      return
    }
  }

  private func expectFault(_ state: inout DoryX86ArchitecturalState,
    memory: DoryX86ByteArrayMemory, mode: DoryX86ExecutionMode,
    notPresent: Bool = false, code: UInt32) throws {
    let before = state
    let bytes = memory.snapshot()
    #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
      == .exception(.init(kind: notPresent ? .segmentNotPresent : .generalProtection,
        vector: notPresent ? 11 : 13, errorCode: code, instructionPointer: 0x1000)))
    #expect(state == before)
    #expect(memory.snapshot() == bytes)
  }

  private func pageFault(address: UInt64, code: UInt32) -> DoryX86InterpreterResult {
    .exception(.init(kind: .pageFault, vector: 14, errorCode: code,
      instructionPointer: 0x1000, linearAddress: address))
  }
}
