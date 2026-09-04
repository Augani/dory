import Testing

@testable import DoryDBTX86

// Intel SDM Vol. 1 §§10.5.1–10.5.3, and Vol. 2A FXSAVE/FXRSTOR:
// https://cdrdv2-public.intel.com/843827/253665-sdm-vol-1-dec-24.pdf
// https://cdrdv2-public.intel.com/812383/253666-sdm-vol-2a.pdf
// These tests qualify the represented transfer fields and access boundaries, not
// the missing x87 pointers/opcode, full tag reconstruction, or task-switch rules.
@Suite struct DoryX86FXStateTransferTests {
  private let modes: [DoryX86ExecutionMode] = [.real16, .protected16, .protected32, .long64]

  @Test func savePreservesSoftwareTailAndModeExcludedSlotsWithoutReadingThem() throws {
    for mode in modes {
      for rexW in mode == .long64 ? [false, true] : [false] {
        let code = instruction(restore: false, mode: mode, rexW: rexW)
        let memory = try FXTransferMemory(code: code, bytes: Array(repeating: 0xE7, count: 512),
          accessibleCount: transferCount(mode))
        var state = try makeState(mode: mode)
        let before = state
        try retire(&state, memory: memory, mode: mode, code: code)

        #expect(memory.reads.isEmpty)
        #expect(memory.preflights == [0x2000..<UInt64(0x2000 + transferCount(mode))])
        #expect(memory.writes == memory.preflights)
        let saved = memory.bytes
        #expect(Array(saved[transferCount(mode)..<512]) == Array(repeating: 0xE7,
          count: 512 - transferCount(mode)))
        #expect(Array(saved[464..<512]) == Array(repeating: 0xE7, count: 48))
        #expect(Array(saved[0..<2]) == [0x7F, 0x02])
        #expect(Array(saved[24..<28]) == [0xA0, 0x1F, 0, 0])
        for index in 0..<(mode == .long64 ? 16 : 8) {
          #expect(Array(saved[160 + index * 16..<176 + index * 16])
            == Array(before.floatingPoint.ymm[index].bytes.prefix(16)))
        }
        var expected = before
        expected.rip += UInt64(code.count)
        #expect(state == expected)
      }
    }
  }

  @Test func restorePreservesAllYMMUpperHalvesAndInaccessibleXMMRegisters() throws {
    for mode in modes {
      for rexW in mode == .long64 ? [false, true] : [false] {
        let code = instruction(restore: true, mode: mode, rexW: rexW)
        let image = saveImage()
        let memory = try FXTransferMemory(code: code, bytes: image,
          accessibleCount: transferCount(mode))
        var state = try makeState(mode: mode)
        let before = state
        try retire(&state, memory: memory, mode: mode, code: code)
        #expect(memory.reads == [0x2000..<UInt64(0x2000 + transferCount(mode))])
        #expect(memory.preflights.isEmpty && memory.writes.isEmpty)
        #expect(memory.bytes == image)
        for index in 0..<16 {
          let old = before.floatingPoint.ymm[index].bytes
          let restoredLow = index < (mode == .long64 ? 16 : 8)
            ? Array(repeating: UInt8(0x10 + index), count: 16) : Array(old.prefix(16))
          #expect(state.floatingPoint.ymm[index].bytes == restoredLow + old.suffix(16))
        }
        #expect(state.floatingPoint.mxcsr == 0x3F80)
        #expect(state.floatingPoint.mxcsrMask == before.floatingPoint.mxcsrMask)
        #expect(state.floatingPoint.x87ControlWord == 0x037F)
        #expect(state.floatingPoint.x87TagWord == 0xFFFF)
        #expect(state.registers == before.registers && state.control == before.control)
        #expect(state.rflags == before.rflags)
      }
    }
  }

  @Test func failedCompleteSavePreflightCannotWriteAnyImageBytes() throws {
    for mode in modes {
      let code = instruction(restore: false, mode: mode)
      let faultAddress = UInt64(0x2000 + transferCount(mode) - 1)
      let memory = try FXTransferMemory(code: code, bytes: Array(repeating: 0xE7, count: 512),
        accessibleCount: transferCount(mode),
        preflightFailure: .pageFault(address: faultAddress, errorCode: 7))
      var state = try makeState(mode: mode)
      let before = state
      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode)
        == pageFault(address: faultAddress, code: 7))
      var expected = before
      expected.control.cr2 = faultAddress
      #expect(state == expected)
      #expect(memory.preflights.count == 1)
      #expect(memory.writes.isEmpty && memory.reads.isEmpty)
      #expect(memory.bytes == Array(repeating: 0xE7, count: 512))
    }
  }

  @Test func pagedTransferFaultsPreserveDestinationAndReportTheFaultingPage() throws {
    for restore in [false, true] {
      let code = instruction(restore: restore, mode: .long64)
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x10000)
      for (address, value): (UInt64, UInt64) in [
        (0x9000, 0xA007), (0xA000, 0xB007), (0xB000, 0xC007),
        (0xC008, 0x1007), (0xC010, 0x2007),
      ] { try memory.writeScalar(at: address, value: value, byteCount: 8) }
      try memory.write(at: 0x1000, bytes: code)
      try memory.write(at: 0x2F00, bytes: saveImage())
      var state = try makeState(mode: .long64, operandAddress: 0x2F00)
      state.cs = .init(selector: 3, attributes: 0xA0FB, limit: .max)
      state.control.cr0 |= 1 << 31
      state.control.cr3 = 0x9000
      state.control.cr4 |= 1 << 5
      state.control.efer = (1 << 10) | (1 << 11)
      let before = state
      let image = try memory.read(at: 0x2F00, byteCount: 512)
      let paging = DoryX86PagingUnit()
      let translated = DoryX86TranslatedMemory(physicalMemory: memory, pagingUnit: paging,
        context: .init(state: state, mode: .long64))
      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64,
        translatedMemory: translated) == pageFault(address: 0x3000, code: restore ? 4 : 6))
      var expected = before
      expected.control.cr2 = 0x3000
      #expect(state == expected)
      #expect(try memory.read(at: 0x2F00, byteCount: 512) == image)
    }
  }

  @Test func invalidMXCSRDoesNotPartiallyRestoreAnyStateOrTheImageMask() throws {
    for mode in modes {
      var image = saveImage()
      image[26] = 1 // Reserved MXCSR bit 16, even though the saved mask allows it.
      let code = instruction(restore: true, mode: mode)
      let memory = try FXTransferMemory(code: code, bytes: image,
        accessibleCount: transferCount(mode))
      var state = try makeState(mode: mode)
      let before = state
      #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode) == gp())
      #expect(state == before)
      #expect(memory.bytes == image)
      #expect(memory.reads.count == 1 && memory.writes.isEmpty)
    }
  }

  @Test func misalignmentAndSegmentLimitFailBeforeTransferEffects() throws {
    for mode in modes {
      for restore in [false, true] {
        let code = instruction(restore: restore, mode: mode)
        let memory = try FXTransferMemory(code: code, bytes: saveImage(),
          accessibleCount: transferCount(mode))
        var state = try makeState(mode: mode, operandAddress: 0x2001)
        let before = state
        #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode) == gp())
        #expect(state == before)
        #expect(memory.reads.isEmpty && memory.preflights.isEmpty && memory.writes.isEmpty)

        if mode != .long64 {
          state = try makeState(mode: mode)
          // m512 is the segment-checked operand even though fewer bytes transfer.
          state.ds.limit = 0x21FE
          let segmentBefore = state
          #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode) == gp())
          #expect(state == segmentBefore)
          #expect(memory.reads.isEmpty && memory.preflights.isEmpty && memory.writes.isEmpty)
        }
      }
    }
  }

  private func transferCount(_ mode: DoryX86ExecutionMode) -> Int { mode == .long64 ? 416 : 288 }

  private func instruction(restore: Bool, mode: DoryX86ExecutionMode, rexW: Bool = false) -> [UInt8] {
    let rm: UInt8 = mode == .real16 || mode == .protected16 ? 7 : 0 // [BX] or [E/RAX].
    return (rexW ? [0x48] : []) + [0x0F, 0xAE, rm | (restore ? 8 : 0)]
  }

  private func makeState(mode: DoryX86ExecutionMode, operandAddress: UInt64 = 0x2000) throws
    -> DoryX86ArchitecturalState {
    var floatingPoint = try DoryX86FloatingPointState(x87ControlWord: 0x027F, mxcsr: 0x1FA0)
    for index in 0..<16 {
      floatingPoint.ymm[index] = try .init(
        bytes: Array(repeating: UInt8(0x40 + index), count: 16)
          + Array(repeating: UInt8(0xA0 + index), count: 16), expectedByteCount: 32)
    }
    let attributes: UInt16 = mode == .long64 ? 0xA09B : mode == .protected32 ? 0xC09B : 0x009B
    return try .init(registers: .init(rax: operandAddress, rbx: operandAddress), rip: 0x1000,
      rflags: [.reservedOne, .carry, .overflow],
      cs: .init(attributes: attributes, limit: .max),
      control: .init(cr0: mode == .real16 ? 0x10 : 0x11, cr2: 0xABC0, cr4: 1 << 9),
      floatingPoint: floatingPoint)
  }

  private func saveImage() -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 512)
    bytes[0] = 0x7F; bytes[1] = 3
    bytes[24] = 0x80; bytes[25] = 0x3F
    bytes.replaceSubrange(28..<32, with: [0xFF, 0xFF, 0xFF, 0xFF]) // Ignored by FXRSTOR.
    for index in 0..<16 {
      bytes.replaceSubrange(160 + index * 16..<176 + index * 16,
        with: Array(repeating: UInt8(0x10 + index), count: 16))
    }
    bytes.replaceSubrange(416..<512, with: Array(repeating: 0xE7, count: 96))
    return bytes
  }

  private func retire(_ state: inout DoryX86ArchitecturalState, memory: any DoryX86Memory,
    mode: DoryX86ExecutionMode, code: [UInt8]) throws {
    let expected = try DoryX86Decoder().decode(code, at: state.rip, mode: mode)
    #expect(DoryX86Interpreter().step(state: &state, memory: memory, mode: mode) == .retired(expected))
  }

  private func gp() -> DoryX86InterpreterResult {
    .exception(.init(kind: .generalProtection, vector: 13, errorCode: 0, instructionPointer: 0x1000))
  }

  private func pageFault(address: UInt64, code: UInt32) -> DoryX86InterpreterResult {
    .exception(.init(kind: .pageFault, vector: 14, errorCode: code,
      instructionPointer: 0x1000, linearAddress: address))
  }
}

// A single-instruction test fixture: instruction fetches have a separate backing,
// and observation rejects any data access into an excluded save-area slot.
private final class FXTransferMemory: DoryX86Memory, @unchecked Sendable {
  private let code: DoryX86ByteArrayMemory
  private let image: DoryX86ByteArrayMemory
  private let accessibleCount: Int
  private let preflightFailure: DoryX86MemoryError?
  private(set) var reads: [Range<UInt64>] = []
  private(set) var preflights: [Range<UInt64>] = []
  private(set) var writes: [Range<UInt64>] = []
  var bytes: [UInt8] { image.snapshot() }

  init(code: [UInt8], bytes: [UInt8], accessibleCount: Int,
    preflightFailure: DoryX86MemoryError? = nil) throws {
    self.code = try .init(baseAddress: 0x1000, bytes: code)
    image = try .init(baseAddress: 0x2000, bytes: bytes)
    self.accessibleCount = accessibleCount
    self.preflightFailure = preflightFailure
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try code.instructionBytes(at: address, maximumCount: maximumCount)
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    reads.append(address..<address + UInt64(byteCount))
    try checkRange(address, byteCount, access: .read)
    return try image.read(at: address, byteCount: byteCount)
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    preflights.append(address..<address + UInt64(byteCount))
    try checkRange(address, byteCount, access: .write)
    if let preflightFailure { throw preflightFailure }
    try image.validateWrite(at: address, byteCount: byteCount)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    writes.append(address..<address + UInt64(bytes.count))
    try checkRange(address, bytes.count, access: .write)
    try image.write(at: address, bytes: bytes)
  }

  private func checkRange(_ address: UInt64, _ byteCount: Int, access: DoryX86MemoryAccessKind) throws {
    guard address >= 0x2000, address + UInt64(byteCount) <= 0x2000 + UInt64(accessibleCount) else {
      throw DoryX86MemoryError.unmapped(address: address, byteCount: byteCount, access: access)
    }
  }
}
