import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 2A pp. 3-553–555; Vol. 2B pp. 4-628–629/4-654–655.
@Suite struct DoryX86DescriptorTableAccessTests {
  @Test func loadsUse24BitBaseOnlyForEffective16BitOperands() throws {
    for mode in modes {
      for override in [false, true] {
        for group in [2, 3] {
          let bytes = instruction(group: group, mode: mode, override: override)
          let memory = DescriptorOperandProbe(code: bytes)
          var state = try makeState(mode: mode)
          let before = state
          let decoded = try DoryX86Decoder().decode(bytes, at: 0x100, mode: mode)
          #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
            == .retired(decoded))
          let default16 = mode == .real16 || mode == .protected16
          let base: UInt64 = mode == .long64 ? 0x0123_4567_89AB_CDEF
            : default16 != override ? 0x00AB_CDEF : 0x89AB_CDEF
          let expected = DoryX86DescriptorTableState(limit: 0x1234, base: base)
          #expect((group == 2 ? state.gdtr : state.idtr) == expected)
          #expect((group == 2 ? state.idtr : state.gdtr) == (group == 2 ? before.idtr : before.gdtr))
          #expect(memory.readCounts == [mode == .long64 ? 10 : 6])
        }
      }
    }
  }

  @Test func storesPreserveFull32Or64BitBaseIndependentOfOperandOverride() throws {
    for mode in modes {
      for override in [false, true] {
        for group in [0, 1] {
          let bytes = instruction(group: group, mode: mode, override: override)
          let memory = DescriptorOperandProbe(code: bytes)
          var state = try makeState(mode: mode)
          let before = state
          let decoded = try DoryX86Decoder().decode(bytes, at: 0x100, mode: mode)
          #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
            == .retired(decoded))
          #expect(memory.writtenBytes == Array(memory.descriptor.prefix(mode == .long64 ? 10 : 6)))
          #expect(memory.validatedWriteCounts == [mode == .long64 ? 10 : 6])
          #expect(state.gdtr == before.gdtr)
          #expect(state.idtr == before.idtr)
        }
      }
    }
  }

  @Test func fullSegmentRangeIsCheckedWithTheCorrectSSOrGPFault() throws {
    for mode: DoryX86ExecutionMode in [.real16, .protected16, .protected32] {
      for group in 0...3 {
        for stack in [false, true] {
          for limit: UInt32 in [0x204, 0x205] {
            let bytes = instruction(group: group, mode: mode, prefix: stack ? [0x36] : [])
            let memory = DescriptorOperandProbe(code: bytes)
            var state = try makeState(mode: mode)
            state.ds.limit = limit
            state.ss.limit = limit
            let before = state
            let result = DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
            if limit == 0x204 {
              #expect(result == protectionFault(stack: stack))
              #expect(state == before)
              #expect(memory.operandAccessCount == 0)
            } else {
              let decoded = try DoryX86Decoder().decode(bytes, at: 0x100, mode: mode)
              #expect(result == .retired(decoded))
            }
          }
        }
      }
    }
  }

  @Test func protectedNullDataSelectorsAndReadOnlyStoreSegmentsFaultBeforeMemory() throws {
    for mode: DoryX86ExecutionMode in [.protected16, .protected32] {
      for group in 0...3 {
        for prefix: [UInt8] in [[], [0x26], [0x64], [0x65]] {
          let bytes = instruction(group: group, mode: mode, prefix: prefix)
          let memory = DescriptorOperandProbe(code: bytes)
          var state = try makeState(mode: mode)
          state.ds.selector = 0
          state.es.selector = 0
          state.fs.selector = 0
          state.gs.selector = 0
          let before = state
          #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
            == protectionFault())
          #expect(state == before)
          #expect(memory.operandAccessCount == 0)
        }
        let bytes = instruction(group: group, mode: mode)
        let memory = DescriptorOperandProbe(code: bytes)
        var state = try makeState(mode: mode)
        state.ds.attributes = 0x91
        let before = state
        let result = DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
        if group < 2 {
          #expect(result == protectionFault())
          #expect(state == before)
          #expect(memory.operandAccessCount == 0)
        } else {
          let decoded = try DoryX86Decoder().decode(bytes, at: 0x100, mode: mode)
          #expect(result == .retired(decoded))
        }
      }
    }
  }

  @Test func privilegeAndRepresentedUMIPPrecedeExplicitOperandAccess() throws {
    for mode in modes {
      for virtual in [false, true] where !virtual || mode == .protected16 {
        for selector: UInt16 in [0, 1, 2, 3] {
          for umip in [false, true] {
            for group in 0...3 {
              let bytes = instruction(group: group, mode: mode)
              let memory = DescriptorOperandProbe(code: bytes)
              var state = try makeState(mode: mode)
              state.cs.selector = selector
              if virtual { state.rflags.insert(.virtual8086) }
              if umip { state.control.cr4 |= 1 << 11 }
              let before = state
              let privilege: UInt16 = mode == .real16 ? 0 : virtual ? 3 : selector
              let denied = privilege != 0 && (group >= 2 || umip)
              let result = DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
              if denied {
                #expect(result == protectionFault())
                #expect(state == before)
                #expect(memory.operandAccessCount == 0)
              } else {
                let decoded = try DoryX86Decoder().decode(bytes, at: 0x100, mode: mode)
                #expect(result == .retired(decoded))
              }
            }
          }
        }
      }
    }
  }

  @Test func longModeValidatesWholeCanonicalSpanAndIgnoresLegacySegmentLimits() throws {
    for group in 0...3 {
      for stack in [false, true] {
        for address: UInt64 in [0x0000_8000_0000_0000, 0x0000_7FFF_FFFF_FFF8, .max - 4] {
          let bytes = instruction(group: group, mode: .long64, prefix: stack ? [0x36] : [])
          let memory = DescriptorOperandProbe(code: bytes)
          var state = try makeState(mode: .long64, operand: address)
          let before = state
          #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
            == protectionFault(stack: stack))
          #expect(state == before)
          #expect(memory.operandAccessCount == 0)
        }
      }
      for prefix: UInt8 in [0x64, 0x65] {
        let bytes = instruction(group: group, mode: .long64, prefix: [prefix])
        let memory = DescriptorOperandProbe(code: bytes)
        var state = try makeState(mode: .long64)
        state.fs = .init(base: 0x1000)
        state.gs = .init(base: 0x1000)
        let decoded = try DoryX86Decoder().decode(bytes, at: 0x100, mode: .long64)
        #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
          == .retired(decoded))
        #expect(memory.lastOperandAddress == 0x1200)
      }
    }
  }

  @Test func crossPageLoadsAndStoresFaultPreciselyWithoutPartialDescriptorChanges() throws {
    for mode: DoryX86ExecutionMode in [.protected32, .long64] {
      for group in 0...3 {
        let fixture = try pagedFixture(mode: mode, group: group, operand: 0x2FFC)
        var state = fixture.state
        let load = group >= 2
        state.cs.selector = load ? 0x8 : 0x1B
        let entrySize = mode == .long64 ? 8 : 4
        try fixture.memory.writeScalar(at: 0xB000 + UInt64(3 * entrySize),
          value: load ? 0 : 0x13005, byteCount: entrySize)
        let before = state
        let destination = try fixture.memory.read(at: 0x12FFC, byteCount: 10)
        #expect(DoryX86Interpreter().step(state: &state, memory: fixture.memory, mode: mode,
          pagingUnit: fixture.paging) == pageFault(0x3000, code: load ? 0 : 7))
        var expected = before
        expected.control.cr2 = 0x3000
        #expect(state == expected)
        #expect(try fixture.memory.read(at: 0x12FFC, byteCount: 10) == destination)
      }
    }
  }

  @Test func lgdtAndLidtOperandsRemainExplicitSupervisorAccessesUnderSMAP() throws {
    for mode: DoryX86ExecutionMode in [.protected32, .long64] {
      for group in [2, 3] {
        for ac in [false, true] {
          let fixture = try pagedFixture(mode: mode, group: group, operand: 0x2000)
          var state = fixture.state
          state.control.cr4 |= 1 << 21
          if ac { state.rflags.insert(.alignmentCheck) }
          let before = state
          let result = DoryX86Interpreter().step(state: &state, memory: fixture.memory,
            mode: mode, pagingUnit: fixture.paging)
          if ac {
            let decoded = try DoryX86Decoder().decode(instruction(group: group, mode: mode),
              at: 0x100, mode: mode)
            #expect(result == .retired(decoded))
          } else {
            #expect(result == pageFault(0x2000, code: 1))
            var expected = before
            expected.control.cr2 = 0x2000
            #expect(state == expected)
          }
        }
      }
    }
  }

  private var modes: [DoryX86ExecutionMode] { [.real16, .protected16, .protected32, .long64] }

  private func instruction(group: Int, mode: DoryX86ExecutionMode,
    override: Bool = false, prefix: [UInt8] = []) -> [UInt8] {
    let rm = mode == .real16 || mode == .protected16 ? 7 : 0 // [BX] or [E/RAX].
    return prefix + (override ? [0x66] : []) + [0x0F, 0x01, UInt8(group << 3 | rm)]
  }

  private func makeState(mode: DoryX86ExecutionMode, operand: UInt64 = 0x200)
    throws -> DoryX86ArchitecturalState {
    let data = DoryX86SegmentState(selector: 0x10, attributes: 0x93, limit: 0xFFFF)
    return try .init(registers: .init(rax: operand, rbx: operand), rip: 0x100,
      cs: .init(selector: 0x8,
        attributes: mode == .long64 ? 0xA09B : mode == .protected32 ? 0xC09B : 0x9B,
        limit: 0xFFFF),
      ds: data, es: data, fs: data, gs: data, ss: data,
      gdtr: .init(limit: 0x1234, base: 0x0123_4567_89AB_CDEF),
      idtr: .init(limit: 0x1234, base: 0x0123_4567_89AB_CDEF),
      control: .init(cr0: mode == .real16 ? 0x10 : mode == .long64 ? 0x8000_0011 : 0x11,
        cr4: mode == .long64 ? 1 << 5 : 0, efer: mode == .long64 ? 0x500 : 0))
  }

  private func protectionFault(stack: Bool = false) -> DoryX86InterpreterResult {
    .exception(.init(kind: stack ? .stackSegment : .generalProtection,
      vector: stack ? 12 : 13, errorCode: 0, instructionPointer: 0x100))
  }

  private func pageFault(_ address: UInt64, code: UInt32) -> DoryX86InterpreterResult {
    .exception(.init(kind: .pageFault, vector: 14, errorCode: code,
      instructionPointer: 0x100, linearAddress: address))
  }

  private func pagedFixture(mode: DoryX86ExecutionMode, group: Int, operand: UInt64) throws
    -> (state: DoryX86ArchitecturalState, memory: DoryX86ByteArrayMemory, paging: DoryX86PagingUnit) {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x20000)
    let long = mode == .long64
    let entrySize = long ? 8 : 4
    if long {
      try memory.writeScalar(at: 0x8000, value: 0x9007, byteCount: 8)
      try memory.writeScalar(at: 0x9000, value: 0xA007, byteCount: 8)
    }
    try memory.writeScalar(at: 0xA000, value: 0xB007, byteCount: entrySize)
    for page in [0, 2, 3] {
      try memory.writeScalar(at: 0xB000 + UInt64(page * entrySize),
        value: UInt64(0x10000 + page * 0x1000) | 7, byteCount: entrySize)
    }
    try memory.write(at: 0x10100, bytes: instruction(group: group, mode: mode))
    try memory.write(at: 0x12000, bytes: [0x34, 0x12, 0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01])
    try memory.write(at: 0x12FFC, bytes: [UInt8](repeating: 0xCC, count: 10))
    var state = try makeState(mode: mode, operand: operand)
    state.control.cr0 |= 1 << 31
    state.control.cr3 = long ? 0x8000 : 0xA000
    state.control.cr4 = long ? 1 << 5 : 0
    return (state, memory, DoryX86PagingUnit())
  }
}

private final class DescriptorOperandProbe: DoryX86Memory, @unchecked Sendable {
  let code: [UInt8]
  let descriptor: [UInt8] = [0x34, 0x12, 0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01]
  private(set) var readCounts: [Int] = []
  private(set) var validatedWriteCounts: [Int] = []
  private(set) var writtenBytes: [UInt8] = []
  private(set) var lastOperandAddress: UInt64?
  var operandAccessCount: Int {
    readCounts.count + validatedWriteCounts.count + (writtenBytes.isEmpty ? 0 : 1)
  }

  init(code: [UInt8]) { self.code = code }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    Array(code.prefix(maximumCount))
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    lastOperandAddress = address
    readCounts.append(byteCount)
    return Array(descriptor.prefix(byteCount))
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    lastOperandAddress = address
    validatedWriteCounts.append(byteCount)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    lastOperandAddress = address
    writtenBytes = bytes
  }
}
