import Testing

@testable import DoryDBTX86

// Intel SDM092 Vol. 1 Tables4-3/4-5, §§4.9.2/8.5.1.1/8.7.1, and
// Vol. 2A FLD/FILD/FST/FIST/FISTTP/FBLD/FBSTP/FXCH/load-constant entries.
// https://cdrdv2-public.intel.com/922480/253666-092-sdm-vol-2a.pdf
// These qualify transfer/constant stack responses only. Arithmetic, comparison,
// conditional-move and transcendental exception generation remain separate.
@Suite struct DoryX86X87TransferStackTests {
  private let modes: [DoryX86ExecutionMode] = [.real16, .protected16, .protected32, .long64]
  private let fpIndefinite: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0xC0, 0xFF, 0xFF]

  @Test func fullStackRegisterLoadsReturnMaskedIndefiniteOrSuppressUnmaskedPush() throws {
    for mode in modes {
      for top in 0..<8 {
        for masked in [false, true] {
          var state = try makeState(mode: mode, top: top, masked: masked)
          let before = state.floatingPoint
          let code: [UInt8] = [0x66, 0xD9, 0xC0]
          let memory = StackMemory(code: code)
          try retire(&state, memory: memory, mode: mode)
          expectFault(state.floatingPoint, overflow: true, masked: masked)
          expectPush(state.floatingPoint, before: before, top: top, masked: masked)
          #expect(state.floatingPoint.x87InstructionPointer == 0x1000)
          #expect(state.floatingPoint.x87Opcode == (masked ? 0x456 : 0x1C0))
          #expect(memory.reads == 0 && memory.writes == 0)
        }
      }
    }
  }

  @Test func emptyRegisterSourceHasPriorityOverFullPushDestination() throws {
    for top in 0..<8 {
      for fullDestination in [false, true] {
        for masked in [false, true] {
          var state = try makeState(top: top, masked: masked)
          empty(0, in: &state.floatingPoint)
          if !fullDestination { empty(7, in: &state.floatingPoint) }
          let before = state.floatingPoint
          try retire(&state, memory: StackMemory(code: [0xD9, 0xC0]), mode: .long64)
          expectFault(state.floatingPoint, overflow: false, masked: masked)
          expectPush(state.floatingPoint, before: before, top: top, masked: masked)
          #expect(tag(top, in: state.floatingPoint) == 3)
        }
      }
    }
  }

  @Test func allMemoryLoadFormatsReadOnceBeforeFullStackFaultPublication() throws {
    let forms: [(UInt8, UInt8, Int)] = [
      (0xD9, 0, 4), (0xDD, 0, 8), (0xDB, 5, 10),
      (0xDF, 0, 2), (0xDB, 0, 4), (0xDF, 5, 8), (0xDF, 4, 10),
    ]
    for mode in modes {
      for (opcode, group, count) in forms {
        for masked in [false, true] {
          let code = memoryCode(opcode, group: group, mode: mode)
          let memory = StackMemory(code: code)
          var state = try makeState(mode: mode, top: 3, masked: masked)
          let before = state.floatingPoint
          try retire(&state, memory: memory, mode: mode)
          #expect(memory.reads == 1 && memory.readByteCounts == [count])
          expectFault(state.floatingPoint, overflow: true, masked: masked)
          expectPush(state.floatingPoint, before: before, top: 3, masked: masked)

          let badMemory = StackMemory(code: code); badMemory.fail = true
          state = try makeState(mode: mode, top: 3, masked: masked)
          let original = state
          expectPageFault(&state, memory: badMemory, mode: mode)
          #expect(state.floatingPoint == original.floatingPoint && state.rip == original.rip)
          #expect(badMemory.reads == 1 && badMemory.writes == 0)
        }
      }
    }
  }

  @Test func sevenConstantLoadsHavePreciseOverflowAtEveryTop() throws {
    for opcode: UInt8 in 0xE8...0xEE {
      for top in 0..<8 {
        for masked in [false, true] {
          var state = try makeState(top: top, masked: masked)
          let before = state.floatingPoint
          try retire(&state, memory: StackMemory(code: [0xD9, opcode]), mode: .long64)
          expectFault(state.floatingPoint, overflow: true, masked: masked)
          expectPush(state.floatingPoint, before: before, top: top, masked: masked)
        }
      }
    }
  }

  @Test func maskedMemoryStoresUseExactIndefiniteBytesAndOnlyRequestedPop() throws {
    for mode in modes {
      for form in stores {
        let memory = StackMemory(code: memoryCode(form.opcode, group: form.group, mode: mode))
        var state = try makeState(mode: mode, top: 5, masked: true)
        empty(0, in: &state.floatingPoint)
        let before = state.floatingPoint
        try retire(&state, memory: memory, mode: mode)
        expectFault(state.floatingPoint, overflow: false, masked: true)
        #expect(memory.reads == 0 && memory.preflights == [form.bytes.count] && memory.writes == 1)
        #expect(Array(memory.image.prefix(form.bytes.count)) == form.bytes)
        #expect(memory.image.dropFirst(form.bytes.count).allSatisfy { $0 == 0xA5 })
        #expect(Int((state.floatingPoint.x87StatusWord >> 11) & 7) == (form.pop ? 6 : 5))
        #expect(state.floatingPoint.x87 == before.x87 && state.floatingPoint.x87TagWord == before.x87TagWord)
      }
    }
  }

  @Test func unmaskedStoresSuppressMemoryAndPopThenFaultAtNextWaitingInstruction() throws {
    for form in stores {
      let code = memoryCode(form.opcode, group: form.group, mode: .long64)
      let memory = StackMemory(code: code + [0x9B]); memory.fail = true
      var state = try makeState(top: 4, masked: false)
      empty(0, in: &state.floatingPoint)
      // Deliberately inaccessible destination: the suppressed-store ordering is
      // a Dory compatibility choice correlated with Bochs fpu_load_store.cc.
      state.registers.rax = 0x0000_8000_0000_0000
      let before = state.floatingPoint
      try retire(&state, memory: memory, mode: .long64)
      expectFault(state.floatingPoint, overflow: false, masked: false)
      #expect(state.floatingPoint.x87 == before.x87 && state.floatingPoint.x87TagWord == before.x87TagWord)
      #expect(state.floatingPoint.x87StatusWord & 0x3800 == before.x87StatusWord & 0x3800)
      #expect(memory.reads == 0 && memory.preflights.isEmpty && memory.writes == 0)
      #expect(state.floatingPoint.x87InstructionPointer == 0x1000)
      #expect(state.floatingPoint.x87DataPointer == 0x0000_8000_0000_0000)
      let atWait = state
      #expect(interpreter.step(state: &state, memory: memory, mode: .long64)
        == .exception(.init(kind: .x87FloatingPoint, vector: 16,
          instructionPointer: 0x1000 + UInt64(code.count))))
      #expect(state == atWait)
    }
  }

  @Test func maskedStorePreflightFaultPreservesOriginalStatusPointersTagsAndDestination() throws {
    for mode in modes {
      for form in stores {
        let memory = StackMemory(code: memoryCode(form.opcode, group: form.group, mode: mode))
        memory.fail = true
        var state = try makeState(mode: mode, top: 7, masked: true)
        empty(0, in: &state.floatingPoint)
        let before = state
        expectPageFault(&state, memory: memory, mode: mode)
        var expected = before; expected.control.cr2 = 0x8001
        #expect(state == expected)
        #expect(memory.preflights == [form.bytes.count] && memory.writes == 0 && memory.reads == 0)
        #expect(memory.image == Array(repeating: 0xA5, count: 32))
      }
    }
  }

  @Test func canonicalSpanFaultsPrecedeMaskedStackEffectsAndUseTheOperandSegment() throws {
    for stackSegment in [false, true] {
      for store in [false, true] {
        let code: [UInt8] = (stackSegment ? [0x36] : []) + [0xDB, store ? 0x38 : 0x28]
        let memory = StackMemory(code: code)
        var state = try makeState(top: 0, masked: true)
        if store { empty(0, in: &state.floatingPoint) }
        state.registers.rax = 0x0000_7FFF_FFFF_FFF8 // m80 crosses the canonical endpoint.
        let before = state
        #expect(interpreter.step(state: &state, memory: memory, mode: .long64)
          == .exception(.init(kind: stackSegment ? .stackSegment : .generalProtection,
            vector: stackSegment ? 12 : 13, errorCode: 0, instructionPointer: 0x1000)))
        #expect(state == before)
        #expect(memory.reads == 0 && memory.preflights.isEmpty && memory.writes == 0)
      }
    }
  }

  @Test func registerStoresDoNotTreatEmptyDestinationsAsOverflowAndSuppressUnmaskedUnderflow() throws {
    for top in 0..<8 {
      for pop in [false, true] {
        for masked in [false, true] {
          for sourceEmpty in [false, true] {
            var state = try makeState(top: top, masked: masked)
            empty(2, in: &state.floatingPoint)
            if sourceEmpty { empty(0, in: &state.floatingPoint) }
            let before = state.floatingPoint
            let destination = (top + 2) & 7
            try retire(&state, memory: StackMemory(code: [0xDD, pop ? 0xDA : 0xD2]), mode: .long64)
            if sourceEmpty { expectFault(state.floatingPoint, overflow: false, masked: masked) }
            else { #expect(state.floatingPoint.x87StatusWord & 0x0241 == 0) }
            if !sourceEmpty || masked {
              #expect(state.floatingPoint.x87[destination].bytes == (sourceEmpty ? fpIndefinite : before.x87[top].bytes))
              #expect(Int((state.floatingPoint.x87StatusWord >> 11) & 7) == (pop ? (top + 1) & 7 : top))
              #expect(tag(destination, in: state.floatingPoint) == (sourceEmpty ? 2 : 0))
            } else {
              #expect(state.floatingPoint.x87 == before.x87 && state.floatingPoint.x87TagWord == before.x87TagWord)
              #expect(state.floatingPoint.x87StatusWord & 0x3800 == before.x87StatusWord & 0x3800)
            }
          }
        }
      }
    }
  }

  @Test func maskedExchangeFillsOnlyEmptyOperandsBeforeSwappingAndUnmaskedDoesNotSwap() throws {
    for top in 0..<8 {
      for emptyMask in 1...3 {
        for masked in [false, true] {
          var state = try makeState(top: top, masked: masked)
          if emptyMask & 1 != 0 { empty(0, in: &state.floatingPoint) }
          if emptyMask & 2 != 0 { empty(3, in: &state.floatingPoint) }
          let before = state.floatingPoint
          try retire(&state, memory: StackMemory(code: [0xD9, 0xCB]), mode: .long64)
          expectFault(state.floatingPoint, overflow: false, masked: masked)
          #expect(state.floatingPoint.x87StatusWord & 0x3800 == before.x87StatusWord & 0x3800)
          if masked {
            #expect(state.floatingPoint.x87[top].bytes == (emptyMask & 2 != 0 ? fpIndefinite : before.x87[(top + 3) & 7].bytes))
            #expect(state.floatingPoint.x87[(top + 3) & 7].bytes == (emptyMask & 1 != 0 ? fpIndefinite : before.x87[top].bytes))
            for physical in 0..<8 where physical != top && physical != (top + 3) & 7 {
              #expect(state.floatingPoint.x87[physical] == before.x87[physical])
            }
          } else {
            #expect(state.floatingPoint.x87 == before.x87 && state.floatingPoint.x87TagWord == before.x87TagWord)
          }
        }
      }
    }
  }

  @Test func successfulPushClearsC1ButRetainsStickyStackExceptionFlags() throws {
    for code: [UInt8] in [[0xD9, 0xC0], [0xD9, 0xE8]] {
      var state = try makeState(top: 0, masked: true)
      empty(7, in: &state.floatingPoint)
      state.floatingPoint.x87StatusWord |= 0x0241
      let before = state.floatingPoint
      try retire(&state, memory: StackMemory(code: code), mode: .long64)
      #expect(state.floatingPoint.x87StatusWord & 0x0241 == 0x0041)
      #expect(state.floatingPoint.x87StatusWord & 0x3800 == 7 << 11)
      #expect(state.floatingPoint.x87[7].bytes == before.x87[0].bytes)
      #expect(tag(7, in: state.floatingPoint) == 0)
    }
  }

  @Test func unmaskedNewStackFaultRefreshesOpcodeEvenWhenIEWasAlreadySticky() throws {
    var state = try makeState(top: 0, masked: false)
    state.floatingPoint.x87StatusWord |= 1
    try retire(&state, memory: StackMemory(code: [0x66, 0xD9, 0xEB]), mode: .long64)
    #expect(state.floatingPoint.x87Opcode == 0x1EB)
    #expect(state.floatingPoint.x87InstructionPointer == 0x1000)
    expectFault(state.floatingPoint, overflow: true, masked: false)
  }

  @Test func invalidBCDConversionUsesTheSameArchitecturalIndefiniteEncoding() throws {
    var state = try makeState(top: 0, masked: true)
    state.floatingPoint.x87[0] = try .init(bytes: fpIndefinite, expectedByteCount: 10)
    let memory = StackMemory(code: [0xDF, 0x30])
    try retire(&state, memory: memory, mode: .long64)
    #expect(Array(memory.image.prefix(10)) == [0, 0, 0, 0, 0, 0, 0, 0xC0, 0xFF, 0xFF])
    #expect(state.floatingPoint.x87StatusWord & 1 == 1)
    #expect(state.floatingPoint.x87StatusWord & 0x3800 == 1 << 11)
  }

  @Test func bothNativeTiersFallBackWithoutRepeatingPrefixOrPartiallyPublishingStackState() throws {
    #if os(macOS) && arch(arm64)
      let code: [UInt8] = [0x48, 0xFF, 0xC1, 0xD9, 0xE8, 0x9B]
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        let executor = try DoryARM64BaselineExecutor(maximumCodeBytes: 16384, optimization: optimization)
        let memory = StackMemory(code: code)
        var state = try makeState(top: 6, masked: false)
        let initial = state.floatingPoint
        let prefix = try #require(try executor.executeChainedSummary(
          byteProvider: { try memory.instructionBytes(at: $0, maximumCount: $1) },
          codeGenerationProvider: { _, _ in 1 }, at: state.rip, mode: .long64,
          addressSpaceID: 0, maximumInstructions: 3, state: &state, memory: memory))
        #expect(prefix.guestInstructionCount == 1 && state.rip == 0x1003 && state.registers.rcx == 1)
        #expect(state.floatingPoint == initial)
        let before = state
        #expect(try executor.executeChainedSummary(
          byteProvider: { try memory.instructionBytes(at: $0, maximumCount: $1) },
          codeGenerationProvider: { _, _ in 1 }, at: state.rip, mode: .long64,
          addressSpaceID: 0, maximumInstructions: 2, state: &state, memory: memory) == nil)
        #expect(state == before)
        try retire(&state, memory: memory, mode: .long64)
        #expect(state.rip == 0x1005 && state.registers.rcx == 1 && state.floatingPoint.x87 == initial.x87)
        let atWait = state
        for _ in 0..<2 {
          #expect(interpreter.step(state: &state, memory: memory, mode: .long64)
            == .exception(.init(kind: .x87FloatingPoint, vector: 16, instructionPointer: 0x1005)))
          #expect(state == atWait)
        }
      }
    #endif
  }

  private struct StoreForm {
    let opcode: UInt8
    let group: UInt8
    let bytes: [UInt8]
    let pop: Bool
  }
  private var stores: [StoreForm] {
    [
      .init(opcode: 0xD9, group: 2, bytes: [0, 0, 0xC0, 0xFF], pop: false),
      .init(opcode: 0xD9, group: 3, bytes: [0, 0, 0xC0, 0xFF], pop: true),
      .init(opcode: 0xDD, group: 2, bytes: [0, 0, 0, 0, 0, 0, 0xF8, 0xFF], pop: false),
      .init(opcode: 0xDD, group: 3, bytes: [0, 0, 0, 0, 0, 0, 0xF8, 0xFF], pop: true),
      .init(opcode: 0xDB, group: 7, bytes: fpIndefinite, pop: true),
      .init(opcode: 0xDF, group: 2, bytes: [0, 0x80], pop: false),
      .init(opcode: 0xDF, group: 3, bytes: [0, 0x80], pop: true),
      .init(opcode: 0xDB, group: 2, bytes: [0, 0, 0, 0x80], pop: false),
      .init(opcode: 0xDB, group: 3, bytes: [0, 0, 0, 0x80], pop: true),
      .init(opcode: 0xDF, group: 7, bytes: [0, 0, 0, 0, 0, 0, 0, 0x80], pop: true),
      .init(opcode: 0xDF, group: 1, bytes: [0, 0x80], pop: true),
      .init(opcode: 0xDB, group: 1, bytes: [0, 0, 0, 0x80], pop: true),
      .init(opcode: 0xDD, group: 1, bytes: [0, 0, 0, 0, 0, 0, 0, 0x80], pop: true),
      .init(opcode: 0xDF, group: 6, bytes: fpIndefinite, pop: true),
    ]
  }

  private var interpreter: DoryX86Interpreter {
    // FISTTP tests require an explicit synthetic SSE3 opt-in profile.
    .init(profile: .init(identifier: "test-only.x87-stack-transfers",
      features: DoryX86CPUProfile.compatibleV1.features.union([.sse3]),
      physicalAddressBits: 40, linearAddressBits: 48, virtualTSCFrequencyHz: 1_000_000_000))
  }

  private func makeState(mode: DoryX86ExecutionMode = .long64, top: Int, masked: Bool) throws
    -> DoryX86ArchitecturalState {
    var fp = try DoryX86FloatingPointState(x87ControlWord: masked ? 0x037F : 0x037E,
      x87StatusWord: 0x4700 | UInt16(top << 11), x87TagWord: 0,
      x87InstructionPointer: 0xABCD, x87InstructionSelector: 0x1234,
      x87DataPointer: 0xDCBA, x87DataSelector: 0x5678, x87Opcode: 0x456)
    for index in 0..<8 {
      fp.x87[index] = try .init(bytes: DoryX86ExtendedFloat(Double(index + 1)).bytes(), expectedByteCount: 10)
    }
    let attributes: UInt16 = mode == .long64 ? 0xA09B : mode == .protected32 ? 0xC09B : 0x009B
    return try .init(registers: .init(rax: 0x8000, rbx: 0x8000), rip: 0x1000,
      cs: .init(selector: 0x28, attributes: attributes, limit: .max),
      ds: .init(selector: 0x30, attributes: 0x93, limit: .max),
      control: .init(cr0: mode == .real16 ? 0x30 : 0x31), floatingPoint: fp)
  }

  private func empty(_ logical: Int, in fp: inout DoryX86FloatingPointState) {
    let physical = (Int(fp.x87StatusWord >> 11) + logical) & 7
    fp.x87TagWord |= UInt16(3) << UInt16(physical * 2)
  }
  private func tag(_ physical: Int, in fp: DoryX86FloatingPointState) -> UInt16 {
    fp.x87TagWord >> UInt16(physical * 2) & 3
  }
  private func expectFault(_ fp: DoryX86FloatingPointState, overflow: Bool, masked: Bool) {
    #expect(fp.x87StatusWord & 0x82C1 == (overflow ? 0x0241 : 0x0041) | (masked ? 0 : 0x8080))
  }
  private func expectPush(_ fp: DoryX86FloatingPointState, before: DoryX86FloatingPointState,
    top: Int, masked: Bool) {
    if masked {
      let destination = (top + 7) & 7
      #expect(fp.x87StatusWord & 0x3800 == UInt16(destination << 11))
      #expect(fp.x87[destination].bytes == fpIndefinite && tag(destination, in: fp) == 2)
      for physical in 0..<8 where physical != destination { #expect(fp.x87[physical] == before.x87[physical]) }
    } else {
      #expect(fp.x87 == before.x87 && fp.x87TagWord == before.x87TagWord)
      #expect(fp.x87StatusWord & 0x3800 == before.x87StatusWord & 0x3800)
    }
    #expect(fp.ymm == before.ymm && fp.mxcsr == before.mxcsr && fp.mxcsrMask == before.mxcsrMask)
  }
  private func memoryCode(_ opcode: UInt8, group: UInt8, mode: DoryX86ExecutionMode) -> [UInt8] {
    [opcode, group << 3 | (mode == .real16 || mode == .protected16 ? 7 : 0)]
  }
  private func retire(_ state: inout DoryX86ArchitecturalState, memory: StackMemory,
    mode: DoryX86ExecutionMode) throws {
    let instruction = try DoryX86Decoder().decode(
      memory.instructionBytes(at: state.rip, maximumCount: 15), at: state.rip, mode: mode)
    #expect(interpreter.step(state: &state, memory: memory, mode: mode) == .retired(instruction))
  }
  private func expectPageFault(_ state: inout DoryX86ArchitecturalState, memory: StackMemory,
    mode: DoryX86ExecutionMode) {
    guard case .exception(let fault) = interpreter.step(state: &state, memory: memory, mode: mode)
    else { Issue.record("Expected operand page fault"); return }
    #expect(fault.kind == .pageFault && fault.linearAddress == 0x8001 && fault.instructionPointer == 0x1000)
  }
}

private final class StackMemory: DoryX86Memory, @unchecked Sendable {
  let code: [UInt8]
  var image = [UInt8](repeating: 0xA5, count: 32)
  var reads = 0
  var readByteCounts: [Int] = []
  var writes = 0
  var preflights: [Int] = []
  var fail = false

  init(code: [UInt8]) { self.code = code }
  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    guard address >= 0x1000, address - 0x1000 < code.count else { return [] }
    return Array(code.dropFirst(Int(address - 0x1000)).prefix(maximumCount))
  }
  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    reads += 1; readByteCounts.append(byteCount)
    if fail { throw DoryX86MemoryError.pageFault(address: 0x8001, errorCode: 4) }
    return Array(image.prefix(byteCount))
  }
  func validateWrite(at address: UInt64, byteCount: Int) throws {
    preflights.append(byteCount)
    if fail { throw DoryX86MemoryError.pageFault(address: 0x8001, errorCode: 6) }
  }
  func write(at address: UInt64, bytes: [UInt8]) throws {
    writes += 1; image.replaceSubrange(0..<bytes.count, with: bytes)
  }
}
