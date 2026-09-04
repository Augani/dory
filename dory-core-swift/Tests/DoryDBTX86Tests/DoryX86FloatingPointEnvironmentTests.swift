import Foundation
import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 1 §§8.1.7–8.1.10, Figures 8-9–8-12, §10.5.1;
// Vol. 2A FLDENV/FNSTENV/FXSAVE/FXRSTOR:
// https://cdrdv2-public.intel.com/922480/253666-092-sdm-vol-2a.pdf
// Golden fields exclude reserved bits and post-FNSTENV undefined condition codes.
// This is environment transfer/tracking coverage, not numeric exception qualification.
@Suite struct DoryX86FloatingPointEnvironmentTests {
  private let modes: [DoryX86ExecutionMode] = [.real16, .protected16, .protected32, .long64]

  @Test func fourEnvironmentImagesMatchIndependentLiteralBytesUnderDefinedMasks() throws {
    let fp = try makeState(mode: .long64).floatingPoint
    let fixtures: [(Bool, [UInt8], [UInt8])] = [
      (false,
        [0x7A, 2, 0, 0x45, 0xFF, 0xFF, 0xEF, 0xCD, 0x34, 0x12, 0x10, 0x32, 0x78, 0x56],
        Array(repeating: 0xFF, count: 14)),
      (true,
        [0x7A, 2, 0, 0x45, 0xFF, 0xFF, 0x2F, 0xF1, 0xA6, 0xC5, 0x90, 0x99, 0, 0x90],
        [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xF7, 0xFF, 0xFF, 0, 0xF0]),
      (false,
        [0x7A, 2, 0, 0, 0, 0x45, 0, 0, 0xFF, 0xFF, 0, 0, 0xEF, 0xCD, 0xAB, 0x89,
          0x34, 0x12, 0xA6, 5, 0x10, 0x32, 0x54, 0x76, 0x78, 0x56, 0, 0],
        [0xFF, 0xFF, 0, 0, 0xFF, 0xFF, 0, 0, 0xFF, 0xFF, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF,
          0xFF, 0xFF, 0xFF, 7, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0]),
      (true,
        [0x7A, 2, 0, 0, 0, 0x45, 0, 0, 0xFF, 0xFF, 0, 0, 0x2F, 0xF1, 0, 0,
          0xA6, 0xC5, 0x9A, 8, 0x90, 0x99, 0, 0, 0, 0x90, 0x65, 7],
        [0xFF, 0xFF, 0, 0, 0xFF, 0xFF, 0, 0, 0xFF, 0xFF, 0, 0, 0xFF, 0xFF, 0, 0,
          0xFF, 0xF7, 0xFF, 0x0F, 0xFF, 0xFF, 0, 0, 0, 0xF0, 0xFF, 0x0F]),
    ]
    for (real, expected, mask) in fixtures {
      let actual = DoryX86FloatingPointEnvironment.save(fp, byteCount: expected.count, realFormat: real)
      #expect(zip(actual, mask).map { $0 & $1 } == zip(expected, mask).map { $0 & $1 })
    }
  }

  @Test func protectedEnvironmentFieldsUseEffectiveOperandSizeIncluding66() throws {
    for mode in [DoryX86ExecutionMode.protected16, .protected32, .long64] {
      for override in [false, true] {
        let code = envCode(store: true, mode: mode, override: override)
        let memory = EnvironmentMemory(code: code)
        var state = try makeState(mode: mode)
        let before = state
        try retire(&state, memory: memory, mode: mode, code: code)
        let count = (mode == .protected16) != override ? 14 : 28
        let stride = count == 14 ? 2 : 4
        #expect(memory.writes == [count] && memory.writePreflights == [count])
        #expect(word(memory.image, 0) == 0x027A)
        #expect(word(memory.image, stride) == 0x4500)
        #expect(word(memory.image, stride * 2) == 0xFFFF)
        #expect(word(memory.image, stride * 4) == 0x1234)
        #expect(word(memory.image, stride * 6) == 0x5678)
        if count == 14 {
          #expect(word(memory.image, 6) == 0xCDEF && word(memory.image, 10) == 0x3210)
        } else {
          #expect(integer(memory.image, 12, 4) == 0x89AB_CDEF)
          #expect(integer(memory.image, 20, 4) == 0x7654_3210)
          #expect(word(memory.image, 18) & 0x7FF == 0x5A6)
        }
        #expect(memory.image[count...] == Array(repeating: UInt8(0xCC), count: 512 - count)[...])
        #expect(state.floatingPoint.x87ControlWord == before.floatingPoint.x87ControlWord | 0x3F)
        #expect(state.floatingPoint.x87StatusWord & 0x8080 == 0)
        #expect(state.floatingPoint.x87 == before.floatingPoint.x87)
        #expect(pointers(state.floatingPoint) == pointers(before.floatingPoint))
      }
    }
  }

  @Test func realAndVirtual8086ImagesPackLinearPointersAtBothSizes() throws {
    for virtual8086 in [false, true] {
      let mode: DoryX86ExecutionMode = virtual8086 ? .protected16 : .real16
      for override in [false, true] {
        let code = envCode(store: true, mode: mode, override: override)
        let memory = EnvironmentMemory(code: code)
        var state = try makeState(mode: mode)
        if virtual8086 { state.rflags.insert(.virtual8086) }
        try retire(&state, memory: memory, mode: mode, code: code)
        let stride = override ? 4 : 2
        // 89ABCDEF + 1234*16 = 89ACF12F; 76543210 + 5678*16 = 76599990.
        #expect(word(memory.image, 3 * stride) == 0xF12F)
        #expect(word(memory.image, 5 * stride) == 0x9990)
        if override {
          #expect(integer(memory.image, 16, 4) & 0x0FFF_F7FF == 0x089A_C5A6)
          #expect(integer(memory.image, 24, 4) & 0x0FFF_F000 == 0x0765_9000)
        } else {
          #expect(word(memory.image, 8) & 0xF7FF == 0xC5A6)
          #expect(word(memory.image, 12) & 0xF000 == 0x9000)
        }
      }
    }
  }

  @Test func retainedVMBitInIA32eDoesNotSelectRealEnvironmentLayouts() throws {
    for mode: DoryX86ExecutionMode in [.protected16, .protected32, .long64] {
      for override in [false, true] {
        let count = (mode == .protected16) != override ? 14 : 28
        let stride = count == 14 ? 2 : 4
        let save = envCode(store: true, mode: mode, override: override)
        let memory = EnvironmentMemory(code: save)
        var state = try makeState(mode: mode)
        state.control.efer |= 1 << 10
        state.rflags.insert(.virtual8086)
        try retire(&state, memory: memory, mode: mode, code: save)
        #expect(word(memory.image, stride * 3) == 0xCDEF)
        #expect(word(memory.image, stride * 4) == 0x1234)
        #expect(word(memory.image, stride * 5) == 0x3210)
        #expect(word(memory.image, stride * 6) == 0x5678)

        let load = envCode(store: false, mode: mode, override: override)
        memory.code = load; memory.image = protectedImage(count: count)
        state.rip = 0x1000
        try retire(&state, memory: memory, mode: mode, code: load)
        #expect(state.floatingPoint.x87InstructionSelector == 0x28)
        #expect(state.floatingPoint.x87DataSelector == 0x30)
        #expect(state.floatingPoint.x87InstructionPointer == (count == 14 ? 0x1357 : 0x2468_1357))
        #expect(state.floatingPoint.x87DataPointer == (count == 14 ? 0xABCD : 0x5678_ABCD))
      }
    }
  }

  @Test func longModeREXWOverrides66ForEnvironmentSizeButSelectsWideFXPointers() throws {
    for store in [false, true] {
      for prefixes: [UInt8] in [[], [0x66], [0x48], [0x66, 0x48]] {
        let wide = prefixes.last == 0x48
        let count = prefixes == [0x66] ? 14 : 28
        let code = prefixes + envCode(store: store, mode: .long64)
        let memory = EnvironmentMemory(code: code, image: protectedImage(count: count))
        var state = try makeState(mode: .long64)
        try retire(&state, memory: memory, mode: .long64, code: code)
        #expect(store ? memory.writes == [count] : memory.reads == [count])
        if !store { #expect(state.floatingPoint.x87InstructionPointer == (count == 14 ? 0x1357 : 0x2468_1357)) }

        // For FX images the transfer size is unchanged, but REX.W alone
        // chooses 64-bit FIP/FDP fields; 66 cannot truncate the pointers.
        let fx = prefixes + fxCode(restore: false, mode: .long64)
        let fxMemory = EnvironmentMemory(code: fx)
        state = try makeState(mode: .long64)
        try retire(&state, memory: fxMemory, mode: .long64, code: fx)
        #expect(fxMemory.writes == [416])
        #expect(integer(fxMemory.image, 8, wide ? 8 : 4)
          == (wide ? 0x1122_3344_89AB_CDEF : 0x89AB_CDEF))
      }
    }
  }

  @Test func fldenvLoadsGoldenProtectedFieldsClassifiesPhysicalTagsAndPreservesData() throws {
    for mode in [DoryX86ExecutionMode.protected16, .protected32, .long64] {
      for override in [false, true] {
        let count = (mode == .protected16) != override ? 14 : 28
        let image = protectedImage(count: count)
        let code = envCode(store: false, mode: mode, override: override)
        let memory = EnvironmentMemory(code: code, image: image)
        var state = try makeState(mode: mode)
        let before = state.floatingPoint
        try retire(&state, memory: memory, mode: mode, code: code)
        #expect(memory.reads == [count] && memory.writes.isEmpty)
        #expect(state.floatingPoint.x87ControlWord == 0x027E)
        #expect(state.floatingPoint.x87StatusWord == 0xAD81) // IE unmasked: ES and B recomputed.
        #expect(state.floatingPoint.x87TagWord == 0x1BA4)
        #expect(state.floatingPoint.x87 == before.x87 && state.floatingPoint.ymm == before.ymm)
        #expect(state.floatingPoint.mxcsr == before.mxcsr)
        #expect(state.floatingPoint.x87InstructionPointer == (count == 14 ? 0x1357 : 0x2468_1357))
        #expect(state.floatingPoint.x87DataPointer == (count == 14 ? 0xABCD : 0x5678_ABCD))
        #expect(state.floatingPoint.x87InstructionSelector == 0x28 && state.floatingPoint.x87DataSelector == 0x30)
        #expect(state.floatingPoint.x87Opcode == (count == 14 ? 0 : 0x321))
      }
    }
  }

  @Test func fldenvRealAndVirtualImagesRestorePackedPointersAndIgnoreReservedBits() throws {
    for virtual8086 in [false, true] {
      let mode: DoryX86ExecutionMode = virtual8086 ? .protected16 : .real16
      for override in [false, true] {
        let count = override ? 28 : 14
        let stride = override ? 4 : 2
        var image = [UInt8](repeating: 0xFF, count: 512)
        put(0x037F, at: 0, count: 2, into: &image)
        put(0x1800, at: stride, count: 2, into: &image)
        put(0xFFFF, at: stride * 2, count: 2, into: &image)
        put(0x1357, at: stride * 3, count: 2, into: &image)
        put(override ? 0xF123_4B21 : 0xBB21, at: stride * 4, count: stride, into: &image)
        put(0xABCD, at: stride * 5, count: 2, into: &image)
        put(override ? 0xF567_8FFF : 0x8FFF, at: stride * 6, count: stride, into: &image)
        let code = envCode(store: false, mode: mode, override: override)
        let memory = EnvironmentMemory(code: code, image: image)
        var state = try makeState(mode: mode)
        if virtual8086 { state.rflags.insert(.virtual8086) }
        try retire(&state, memory: memory, mode: mode, code: code)
        #expect(memory.reads == [count])
        #expect(state.floatingPoint.x87InstructionPointer == (override ? 0x1234_1357 : 0xB1357))
        #expect(state.floatingPoint.x87DataPointer == (override ? 0x5678_ABCD : 0x8ABCD))
        #expect(state.floatingPoint.x87InstructionSelector == 0 && state.floatingPoint.x87DataSelector == 0)
        #expect(state.floatingPoint.x87Opcode == 0x321)
      }
    }
  }

  @Test func fxImagesUseLogicalDataSlotsPhysicalTagsAndREXWPointerLayout() throws {
    for mode in modes {
      for wide in mode == .long64 ? [false, true] : [false] {
        for top: UInt16 in 0..<8 {
          var state = try makeState(mode: mode)
          state.floatingPoint.x87StatusWord = top << 11
          state.floatingPoint.x87TagWord = 0x0300 // Only physical R4 empty.
          let original = state.floatingPoint
          let save = fxCode(restore: false, mode: mode, wide: wide)
          let memory = EnvironmentMemory(code: save)
          try retire(&state, memory: memory, mode: mode, code: save)
          #expect(memory.image[4] == 0xEF)
          #expect(word(memory.image, 6) & 0x7FF == 0x5A6)
          #expect(integer(memory.image, 8, wide ? 8 : 4) == (wide ? 0x1122_3344_89AB_CDEF : 0x89AB_CDEF))
          #expect(integer(memory.image, 16, wide ? 8 : 4) == (wide ? 0x8877_6655_7654_3210 : 0x7654_3210))
          if !wide { #expect(word(memory.image, 12) == 0x1234 && word(memory.image, 20) == 0x5678) }
          for logical in 0..<8 {
            #expect(Array(memory.image[32 + 16 * logical..<42 + 16 * logical])
              == original.x87[(Int(top) + logical) & 7].bytes)
          }
          let restore = fxCode(restore: true, mode: mode, wide: wide)
          memory.code = restore
          memory.image[7] |= 0xF8 // Reserved opcode bits must not invent #GP.
          state.rip = 0x1000
          state.floatingPoint = try .init()
          try retire(&state, memory: memory, mode: mode, code: restore)
          #expect(state.floatingPoint.x87 == original.x87)
          #expect(state.floatingPoint.x87TagWord == 0x1BA4)
          #expect(state.floatingPoint.x87StatusWord == top << 11)
          #expect(state.floatingPoint.x87Opcode == 0x5A6)
          #expect(state.floatingPoint.x87InstructionPointer == (wide ? original.x87InstructionPointer : 0x89AB_CDEF))
          #expect(state.floatingPoint.x87DataPointer == (wide ? original.x87DataPointer : 0x7654_3210))
          #expect(state.floatingPoint.x87InstructionSelector == (wide ? 0 : 0x1234))
          #expect(state.floatingPoint.x87DataSelector == (wide ? 0 : 0x5678))
        }
      }
    }
  }

  @Test func fninitClearsPointersOpcodeAndFNCLEXPreservesThem() throws {
    for code: [UInt8] in [[0xDB, 0xE3], [0xDB, 0xE2]] {
      var state = try makeState(mode: .long64)
      let before = state.floatingPoint
      try retire(&state, memory: EnvironmentMemory(code: code), mode: .long64, code: code)
      #expect(pointers(state.floatingPoint) == (code[1] == 0xE3 ? [0, 0, 0, 0, 0] : pointers(before)))
      #expect(state.floatingPoint.x87 == before.x87 && state.floatingPoint.ymm == before.ymm)
    }
  }

  @Test func ordinaryX87TracksPrefixStartAndMemorySegmentButControlsAndMMXDoNot() throws {
    for mode in modes {
      var state = try makeState(mode: mode)
      let rm: UInt8 = mode == .real16 || mode == .protected16 ? 7 : 0
      let load: [UInt8] = [0x66, 0x64, 0xD9, rm] // FLD m32 via FS.
      state.fs = .init(selector: 0x58, attributes: 0x93, limit: .max, base: 0x100)
      state.registers.rax = 0x7F00; state.registers.rbx = 0x7F00
      let memory = EnvironmentMemory(code: load, image: [0, 0, 0x80, 0x3F])
      try retire(&state, memory: memory, mode: mode, code: load)
      #expect(state.floatingPoint.x87InstructionPointer == 0x1000)
      #expect(state.floatingPoint.x87InstructionSelector == 0x28)
      #expect(state.floatingPoint.x87DataPointer == (mode == .long64 ? 0x8000 : 0x7F00))
      #expect(state.floatingPoint.x87DataSelector == 0x58)
      #expect(state.floatingPoint.x87Opcode == 0x5A6) // No unmasked exception incurred.
      for code: [UInt8] in [[0x66, 0xD9, 0xD0], [0xDF, 0xE0], [0xDB, 0xE2], [0x9B], [0x0F, 0x77]] {
        let before = state.floatingPoint
        let address = state.rip
        memory.code = code; memory.codeAddress = address
        try retire(&state, memory: memory, mode: mode, code: code)
        if code[1...].elementsEqual([0xD9, 0xD0]) {
          #expect(state.floatingPoint.x87InstructionPointer == address)
          #expect(Array(pointers(state.floatingPoint).dropFirst()) == Array(pointers(before).dropFirst()))
        } else {
          #expect(pointers(state.floatingPoint) == pointers(before))
        }
      }
    }
  }

  @Test func environmentAndFXFaultsPreserveEntireStateAndDoNotPartiallyStore() throws {
    for mode in modes {
      for code in [envCode(store: true, mode: mode), envCode(store: false, mode: mode),
        fxCode(restore: false, mode: mode), fxCode(restore: true, mode: mode)] {
        let memory = EnvironmentMemory(code: code)
        memory.failTransfer = true
        var state = try makeState(mode: mode)
        let before = state
        guard case .exception(let fault) = DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
        else { Issue.record("Expected transfer page fault"); continue }
        #expect(fault.kind == .pageFault && fault.instructionPointer == 0x1000 && fault.linearAddress == 0x8010)
        var expected = before; expected.control.cr2 = 0x8010
        #expect(state == expected)
        #expect(memory.image == Array(repeating: 0xCC, count: 512) && memory.writes.isEmpty)
      }
    }
  }

  @Test func environmentSpanChecksPrecedeDataAccessAtSegmentAndCanonicalBoundaries() throws {
    for mode in modes {
      for store in [false, true] {
        let code = envCode(store: store, mode: mode)
        let memory = EnvironmentMemory(code: code)
        var state = try makeState(mode: mode)
        if mode == .long64 {
          state.registers.rax = 0x0000_7FFF_FFFF_FFF0 // First byte canonical, last byte not.
        } else {
          state.ds.limit = 0x800C // 14-byte operand extends one byte beyond limit.
        }
        let before = state
        #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
          == .exception(.init(kind: .generalProtection, vector: 13, errorCode: 0, instructionPointer: 0x1000)))
        #expect(state == before && memory.reads.isEmpty && memory.writePreflights.isEmpty && memory.writes.isEmpty)
      }
    }
  }

  @Test func x87DataFaultDoesNotOverwritePreviousInstructionOrOperandPointers() throws {
    for code: [UInt8] in [[0xD9, 0x00], [0xD9, 0x18]] { // FLD/FSTP m32 [RAX].
      let memory = EnvironmentMemory(code: code)
      memory.failTransfer = true
      var state = try makeState(mode: .long64)
      state.floatingPoint.x87TagWord = 0
      let before = state
      guard case .exception(let fault) = DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
      else { Issue.record("Expected operand page fault"); continue }
      #expect(fault.kind == .pageFault && fault.instructionPointer == 0x1000)
      #expect(state.floatingPoint == before.floatingPoint)
      #expect(memory.writes.isEmpty)
    }
  }

  @Test func opcodeTrackingUsesOnlyNewlyRepresentedUnmaskedExceptionAndStripsPrefixes() throws {
    let instruction = try DoryX86Decoder().decode([0x66, 0xD8, 0xC1], at: 0x1000, mode: .long64)
    for masked in [false, true] {
      for alreadyPending in [false, true] {
        var state = try DoryX86FloatingPointState(x87ControlWord: masked ? 0x37F : 0x37E,
          x87StatusWord: 1, x87Opcode: 0x456)
        DoryX86FloatingPointEnvironment.recordOpcodeIfNewUnmaskedException(instruction,
          previousStatus: alreadyPending ? 1 : 0, state: &state)
        #expect(state.x87Opcode == (!masked && !alreadyPending ? 0xC1 : 0x456))
      }
    }
  }

  @Test func pointerStateRoundTripsAndLegacyJSONDefaultsWithoutLosingStrictOpcodeValidation() throws {
    let reset = try DoryX86FloatingPointState()
    let resetJSON = try JSONEncoder().encode(reset)
    let object = try #require(try JSONSerialization.jsonObject(with: resetJSON) as? [String: Any])
    #expect(object.count == 7 && object["x87InstructionPointer"] == nil)
    #expect(try JSONDecoder().decode(DoryX86FloatingPointState.self, from: resetJSON) == reset)
    let populated = try makeState(mode: .long64).floatingPoint
    #expect(try JSONDecoder().decode(DoryX86FloatingPointState.self,
      from: JSONEncoder().encode(populated)) == populated)
    #expect(throws: DoryX86StateError.invalidX87Opcode(0x800)) {
      try DoryX86FloatingPointState(x87Opcode: 0x800)
    }
    var invalid = object; invalid["x87Opcode"] = 0xFFFF
    let invalidJSON = try JSONSerialization.data(withJSONObject: invalid)
    #expect(throws: DoryX86StateError.invalidX87Opcode(0xFFFF)) {
      try JSONDecoder().decode(DoryX86FloatingPointState.self, from: invalidJSON)
    }
  }

  private func envCode(store: Bool, mode: DoryX86ExecutionMode, override: Bool = false) -> [UInt8] {
    let rm: UInt8 = mode == .real16 || mode == .protected16 ? 7 : 0
    return (override ? [0x66] : []) + [0xD9, (store ? 0x30 : 0x20) | rm]
  }

  private func fxCode(restore: Bool, mode: DoryX86ExecutionMode, wide: Bool = false) -> [UInt8] {
    let rm: UInt8 = mode == .real16 || mode == .protected16 ? 7 : 0
    return (wide ? [0x48] : []) + [0x0F, 0xAE, (restore ? 8 : 0) | rm]
  }

  private func makeState(mode: DoryX86ExecutionMode) throws -> DoryX86ArchitecturalState {
    var fp = try DoryX86FloatingPointState(x87ControlWord: 0x027A, x87StatusWord: 0x4500,
      x87InstructionPointer: 0x1122_3344_89AB_CDEF, x87InstructionSelector: 0x1234,
      x87DataPointer: 0x8877_6655_7654_3210, x87DataSelector: 0x5678, x87Opcode: 0x5A6)
    let payloads: [(UInt64, UInt16)] = [(1 << 63, 0x3FFF), (0, 0), (1, 0),
      (1 << 63, 0x7FFF), (.max, 0x7FFF), (1, 0x3FFF), (0, 0x8000), (1 << 63, 0xBFFF)]
    for (index, value) in payloads.enumerated() {
      var bytes = [UInt8](repeating: 0, count: 10)
      put(value.0, at: 0, count: 8, into: &bytes); put(UInt64(value.1), at: 8, count: 2, into: &bytes)
      fp.x87[index] = try .init(bytes: bytes, expectedByteCount: 10)
    }
    let attributes: UInt16 = mode == .long64 ? 0xA09B : mode == .protected32 ? 0xC09B : 0x009B
    return try .init(registers: .init(rax: 0x8000, rbx: 0x8000), rip: 0x1000,
      cs: .init(selector: 0x28, attributes: attributes, limit: .max),
      ds: .init(selector: 0x30, attributes: 0x93, limit: .max),
      control: .init(cr0: mode == .real16 ? 0x30 : 0x31, cr4: 1 << 9), floatingPoint: fp)
  }

  private func protectedImage(count: Int) -> [UInt8] {
    var image = [UInt8](repeating: 0xAA, count: 512)
    let stride = count == 14 ? 2 : 4
    put(0x027E, at: 0, count: 2, into: &image)
    put(0x2D01, at: stride, count: 2, into: &image)
    put(0x0300, at: stride * 2, count: 2, into: &image)
    put(0x2468_1357, at: stride * 3, count: stride, into: &image)
    put(0x28, at: stride * 4, count: 2, into: &image)
    put(0x5678_ABCD, at: stride * 5, count: stride, into: &image)
    put(0x30, at: stride * 6, count: 2, into: &image)
    if count == 28 { put(0xFB21, at: 18, count: 2, into: &image) }
    return image
  }

  private func pointers(_ state: DoryX86FloatingPointState) -> [UInt64] {
    [state.x87InstructionPointer, UInt64(state.x87InstructionSelector), state.x87DataPointer,
      UInt64(state.x87DataSelector), UInt64(state.x87Opcode)]
  }

  private func retire(_ state: inout DoryX86ArchitecturalState, memory: EnvironmentMemory,
    mode: DoryX86ExecutionMode, code: [UInt8]) throws {
    let instruction = try DoryX86Decoder().decode(code, at: state.rip, mode: mode)
    #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode) == .retired(instruction))
  }

  private func word(_ bytes: [UInt8], _ offset: Int) -> UInt64 { integer(bytes, offset, 2) }
  private func integer(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
    (0..<count).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) }
  }
  private func put(_ value: UInt64, at offset: Int, count: Int, into bytes: inout [UInt8]) {
    for i in 0..<count { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
  }
}

private final class EnvironmentMemory: DoryX86Memory, @unchecked Sendable {
  var code: [UInt8]
  var codeAddress: UInt64 = 0x1000
  var image: [UInt8]
  var reads: [Int] = []
  var writes: [Int] = []
  var writePreflights: [Int] = []
  var failTransfer = false

  init(code: [UInt8], image: [UInt8] = Array(repeating: 0xCC, count: 512)) {
    self.code = code; self.image = image
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    guard address >= codeAddress, address - codeAddress < code.count else { return [] }
    return Array(code.dropFirst(Int(address - codeAddress)).prefix(maximumCount))
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    reads.append(byteCount)
    if failTransfer { throw DoryX86MemoryError.pageFault(address: 0x8010, errorCode: 4) }
    guard address == 0x8000, byteCount <= image.count else {
      throw DoryX86MemoryError.unmapped(address: address, byteCount: byteCount, access: .read)
    }
    return Array(image.prefix(byteCount))
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    writePreflights.append(byteCount)
    if failTransfer { throw DoryX86MemoryError.pageFault(address: 0x8010, errorCode: 6) }
    guard address == 0x8000, byteCount <= image.count else {
      throw DoryX86MemoryError.unmapped(address: address, byteCount: byteCount, access: .write)
    }
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    writes.append(bytes.count)
    image.replaceSubrange(0..<bytes.count, with: bytes)
  }
}
